#include <cerrno>
#include <cstdint>
#include <cstring>
#include <ctime>
#include <iostream>
#include <stdexcept>

#include <fcntl.h>
#include <linux/i2c-dev.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "imu.h"

static constexpr const char *DEV = "/dev/i2c-2";

// LSM9DS0 I2C addresses
static constexpr uint8_t ADDR_XM = 0x1d; // Accel/Mag
static constexpr uint8_t ADDR_G = 0x6b;  // Gyro

// Common register
static constexpr uint8_t WHO_AM_I = 0x0F;

// Accel (XM)
static constexpr uint8_t CTRL_REG1_XM = 0x20;
static constexpr uint8_t CTRL_REG4_XM = 0x23;
static constexpr uint8_t OUT_X_L_A = 0x28;

// Gyro (G)
static constexpr uint8_t CTRL_REG1_G = 0x20;
static constexpr uint8_t CTRL_REG4_G = 0x23;
static constexpr uint8_t OUT_X_L_G = 0x28;

// ---------- time helpers ----------
static double now_s() {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return double(ts.tv_sec) + double(ts.tv_nsec) / 1e9;
}

// ---------- I2C Class (內部使用，不暴露給 Zig) ----------
class I2CDevice {
public:
  explicit I2CDevice(const char *dev_path) {
    fd_ = ::open(dev_path, O_RDWR);
    if (fd_ < 0) {
      throw std::runtime_error(std::string("open ") + dev_path +
                               " failed: " + std::strerror(errno));
    }
  }
  ~I2CDevice() {
    if (fd_ >= 0)
      ::close(fd_);
  }

  void set_addr(uint8_t addr) {
    if (ioctl(fd_, I2C_SLAVE, addr) < 0) {
      throw std::runtime_error("ioctl(I2C_SLAVE) failed: " +
                               std::string(std::strerror(errno)));
    }
  }

  void write_reg(uint8_t addr, uint8_t reg, uint8_t val) {
    set_addr(addr);
    uint8_t buf[2] = {uint8_t(reg & 0xFF), uint8_t(val & 0xFF)};
    if (::write(fd_, buf, 2) != 2) {
      throw std::runtime_error("write_reg failed: " +
                               std::string(std::strerror(errno)));
    }
  }

  uint8_t read_reg(uint8_t addr, uint8_t reg) {
    set_addr(addr);
    uint8_t r = uint8_t(reg & 0xFF);
    if (::write(fd_, &r, 1) != 1) {
      throw std::runtime_error("read_reg(write) failed: " +
                               std::string(std::strerror(errno)));
    }
    uint8_t v = 0;
    if (::read(fd_, &v, 1) != 1) {
      throw std::runtime_error("read_reg(read) failed: " +
                               std::string(std::strerror(errno)));
    }
    return v;
  }

  void read_block(uint8_t addr, uint8_t reg, uint8_t *out, size_t n) {
    set_addr(addr);
    uint8_t r = uint8_t(reg & 0xFF);
    if (::write(fd_, &r, 1) != 1) {
      throw std::runtime_error("read_block(write) failed: " +
                               std::string(std::strerror(errno)));
    }
    ssize_t got = ::read(fd_, out, n);
    if (got < 0 || size_t(got) != n) {
      throw std::runtime_error("read_block(read) failed: " +
                               std::string(std::strerror(errno)));
    }
  }

private:
  int fd_{-1};
};

static int16_t s16(uint8_t lo, uint8_t hi) {
  uint16_t v = (uint16_t(hi) << 8) | uint16_t(lo);
  return (v & 0x8000) ? int16_t(v - 65536) : int16_t(v);
}

// 全局 I2C 設備指標 (由 C 介面管理)
static I2CDevice *g_i2c = nullptr;

// =========================================================================
// 提供給 Zig (C ABI) 的介面
// =========================================================================
extern "C" {

// 初始化感測器
// 回傳 0 表示成功，負數表示失敗
int imu_init() {
  if (g_i2c != nullptr)
    return 0; // 已初始化

  try {
    g_i2c = new I2CDevice(DEV);

    // 檢查設備是否正確
    uint8_t who_xm = g_i2c->read_reg(ADDR_XM, WHO_AM_I);
    uint8_t who_g = g_i2c->read_reg(ADDR_G, WHO_AM_I);

    // 可選：列印 WHO_AM_I 用於除錯
    // std::cout << "WHO_AM_I XM=0x" << std::hex << int(who_xm) << " G=0x" <<
    // int(who_g) << std::dec << "\n";

    // Init Accel: 100Hz, XYZ enable; +/-2g
    g_i2c->write_reg(ADDR_XM, CTRL_REG1_XM, 0x57);
    g_i2c->write_reg(ADDR_XM, CTRL_REG4_XM, 0x00);

    // Init Gyro: power on + XYZ enable
    g_i2c->write_reg(ADDR_G, CTRL_REG1_G, 0x0F);
    g_i2c->write_reg(ADDR_G, CTRL_REG4_G, 0x00);

    return 0;
  } catch (const std::exception &e) {
    std::cerr << "imu_init Error: " << e.what() << "\n";
    if (g_i2c) {
      delete g_i2c;
      g_i2c = nullptr;
    }
    return -1;
  }
}

// 讀取一筆資料
ImuData imu_read() {
  ImuData data = {0}; // 初始化清空

  if (g_i2c == nullptr) {
    data.status = -1;
    return data;
  }

  try {
    // ---- Read Accel ----
    uint8_t a[6]{};
    g_i2c->read_block(ADDR_XM, uint8_t((OUT_X_L_A | 0x80) & 0xFF), a, 6);
    data.ax = s16(a[0], a[1]);
    data.ay = s16(a[2], a[3]);
    data.az = s16(a[4], a[5]);

    // ---- Read Gyro ----
    uint8_t g[6]{};
    g_i2c->read_block(ADDR_G, uint8_t((OUT_X_L_G | 0x80) & 0xFF), g, 6);
    data.gx = s16(g[0], g[1]);
    data.gy = s16(g[2], g[3]);
    data.gz = s16(g[4], g[5]);

    data.timestamp_s = now_s();
    data.status = 0; // 成功

  } catch (...) {
    // 捕捉 C++ 例外，避免異常洩漏到 C/Zig 導致崩潰
    data.status = -2;
  }

  return data;
}

// 釋放資源
void imu_deinit() {
  if (g_i2c != nullptr) {
    delete g_i2c;
    g_i2c = nullptr;
  }
}
}