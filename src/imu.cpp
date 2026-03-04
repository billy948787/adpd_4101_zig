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

// ── LSM9DS0 I2C 位址 ──────────────────────────────────────────────────────
static constexpr uint8_t ADDR_XM = 0x1d; // Accel / Mag
static constexpr uint8_t ADDR_G = 0x6b;  // Gyro

// ── 通用暫存器 ────────────────────────────────────────────────────────────
static constexpr uint8_t WHO_AM_I = 0x0F;

// ── Accel (XM) 暫存器 ─────────────────────────────────────────────────────
static constexpr uint8_t CTRL_REG1_XM = 0x20; // ODR / 軸啟用
static constexpr uint8_t CTRL_REG4_XM = 0x23; // full-scale
static constexpr uint8_t STATUS_REG_A = 0x27; // bit3 = ZYXDA（新資料就緒）
static constexpr uint8_t OUT_X_L_A = 0x28;    // Accel 輸出起點

// ── Gyro (G) 暫存器 ───────────────────────────────────────────────────────
static constexpr uint8_t CTRL_REG1_G = 0x20;   // 電源 / ODR / 軸啟用
static constexpr uint8_t CTRL_REG4_G = 0x23;   // full-scale
static constexpr uint8_t CTRL_REG5_G = 0x24;   // bit6 = FIFO_EN
static constexpr uint8_t FIFO_CTRL_REG = 0x2E; // FIFO 模式設定
static constexpr uint8_t FIFO_SRC_REG = 0x2F;  // bit4:0 = FSS（已儲存筆數）
static constexpr uint8_t OUT_X_L_G = 0x28;     // Gyro 輸出起點

// FIFO Stream mode：bits[7:5] = 010 = 0x40；watermark = 31（bits[4:0]）
static constexpr uint8_t FIFO_MODE_STREAM = 0x40;
static constexpr uint8_t FIFO_WATERMARK = 0x1F; // 31

// ── 時間工具 ──────────────────────────────────────────────────────────────
static double now_s() {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return static_cast<double>(ts.tv_sec) + static_cast<double>(ts.tv_nsec) / 1e9;
}

// ── I2C 裝置封裝（僅供內部使用，不暴露給 Zig） ───────────────────────────
class I2CDevice {
public:
  explicit I2CDevice(const char *dev_path) {
    fd_ = ::open(dev_path, O_RDWR);
    if (fd_ < 0)
      throw std::runtime_error(std::string("open ") + dev_path +
                               " failed: " + std::strerror(errno));
  }

  ~I2CDevice() {
    if (fd_ >= 0)
      ::close(fd_);
  }

  void set_addr(uint8_t addr) {
    if (ioctl(fd_, I2C_SLAVE, addr) < 0)
      throw std::runtime_error("ioctl(I2C_SLAVE) failed: " +
                               std::string(std::strerror(errno)));
  }

  void write_reg(uint8_t addr, uint8_t reg, uint8_t val) {
    set_addr(addr);
    uint8_t buf[2] = {reg, val};
    if (::write(fd_, buf, 2) != 2)
      throw std::runtime_error("write_reg failed: " +
                               std::string(std::strerror(errno)));
  }

  uint8_t read_reg(uint8_t addr, uint8_t reg) {
    set_addr(addr);
    if (::write(fd_, &reg, 1) != 1)
      throw std::runtime_error("read_reg(write) failed: " +
                               std::string(std::strerror(errno)));
    uint8_t v = 0;
    if (::read(fd_, &v, 1) != 1)
      throw std::runtime_error("read_reg(read) failed: " +
                               std::string(std::strerror(errno)));
    return v;
  }

  void read_block(uint8_t addr, uint8_t reg, uint8_t *out, size_t n) {
    set_addr(addr);
    if (::write(fd_, &reg, 1) != 1)
      throw std::runtime_error("read_block(write) failed: " +
                               std::string(std::strerror(errno)));
    ssize_t got = ::read(fd_, out, n);
    if (got < 0 || static_cast<size_t>(got) != n)
      throw std::runtime_error("read_block(read) failed: " +
                               std::string(std::strerror(errno)));
  }

private:
  int fd_{-1};
};

// ── 小工具 ────────────────────────────────────────────────────────────────
static int16_t s16(uint8_t lo, uint8_t hi) {
  return static_cast<int16_t>((static_cast<uint16_t>(hi) << 8) |
                              static_cast<uint16_t>(lo));
}

// 填入「FIFO 無資料」sentinel
static void fill_no_data(ImuData &d) {
  d.timestamp_s = now_s();
  d.ax = d.ay = d.az = -1;
  d.gx = d.gy = d.gz = -1;
  d.status = -1;
}

// 全局 I2C 裝置指標（由 C 介面管理生命週期）
static I2CDevice *g_i2c = nullptr;

// =========================================================================
// C ABI 介面（供 Zig 呼叫）
// =========================================================================
extern "C" {

// ── imu_init ──────────────────────────────────────────────────────────────
int imu_init() {
  if (g_i2c != nullptr)
    return 0; // 已初始化

  try {
    g_i2c = new I2CDevice(DEV);

    // 確認設備身份（忽略回傳值，僅確保通訊正常）
    (void)g_i2c->read_reg(ADDR_XM, WHO_AM_I);
    (void)g_i2c->read_reg(ADDR_G, WHO_AM_I);

    // ── Accel 初始化 ──────────────────────────────────────────────────────
    // CTRL_REG1_XM = 0x57: ODR=100Hz，全軸啟用
    g_i2c->write_reg(ADDR_XM, CTRL_REG1_XM, 0x57);
    // CTRL_REG4_XM = 0x00: ±2g，高解析度
    g_i2c->write_reg(ADDR_XM, CTRL_REG4_XM, 0x00);

    // ── Gyro 初始化 ───────────────────────────────────────────────────────
    // CTRL_REG1_G = 0x0F: 正常模式，95Hz，全軸啟用
    g_i2c->write_reg(ADDR_G, CTRL_REG1_G, 0x0F);
    // CTRL_REG4_G = 0x00: ±245 dps
    g_i2c->write_reg(ADDR_G, CTRL_REG4_G, 0x00);

    // ── 啟用 Gyro FIFO ────────────────────────────────────────────────────
    // CTRL_REG5_G bit6 = FIFO_EN；保留其他位元
    uint8_t reg5 = g_i2c->read_reg(ADDR_G, CTRL_REG5_G);
    g_i2c->write_reg(ADDR_G, CTRL_REG5_G, static_cast<uint8_t>(reg5 | 0x40));

    // FIFO_CTRL_REG: Stream mode, watermark = 31
    g_i2c->write_reg(ADDR_G, FIFO_CTRL_REG,
                     static_cast<uint8_t>(FIFO_MODE_STREAM | FIFO_WATERMARK));

    return 0;
  } catch (const std::exception &e) {
    std::cerr << "imu_init error: " << e.what() << "\n";
    delete g_i2c;
    g_i2c = nullptr;
    return -1;
  }
}

// ── imu_deinit ────────────────────────────────────────────────────────────
void imu_deinit() {
  delete g_i2c;
  g_i2c = nullptr;
}

// ── imu_read_fifo ─────────────────────────────────────────────────────────
int imu_read_fifo(ImuData *out_buf, int buf_size, int *out_count) {
  *out_count = 0;

  // 參數保護
  if (out_buf == nullptr || buf_size <= 0 || out_count == nullptr)
    return -1;

  // 未初始化：回傳一筆全 -1
  if (g_i2c == nullptr) {
    fill_no_data(out_buf[0]);
    *out_count = 1;
    return -1;
  }

  try {
    // ── 查詢 Gyro FIFO 已儲存筆數 ────────────────────────────────────────
    // FIFO_SRC_REG bits[4:0] = FSS（Stored samples count）
    uint8_t fifo_src = g_i2c->read_reg(ADDR_G, FIFO_SRC_REG);
    int fss = static_cast<int>(fifo_src & 0x1F);

    // FIFO 空：回傳一筆全 -1
    if (fss == 0) {
      fill_no_data(out_buf[0]);
      *out_count = 1;
      return 0;
    }

    // 限制在緩衝區大小內
    int to_read = (fss < buf_size) ? fss : buf_size;

    // ── 讀取 Accel 當下最新一筆（Accel 無 FIFO，配對所有 Gyro 筆） ────────
    uint8_t a_buf[6]{};
    bool accel_ok = false;
    {
      uint8_t status_a = g_i2c->read_reg(ADDR_XM, STATUS_REG_A);
      if (status_a & 0x08) { // ZYXDA = 1：新資料就緒
        g_i2c->read_block(
            ADDR_XM, static_cast<uint8_t>((OUT_X_L_A | 0x80) & 0xFF), a_buf, 6);
        accel_ok = true;
      }
    }

    // ── 逐筆從 Gyro FIFO 讀出 ────────────────────────────────────────────
    for (int i = 0; i < to_read; ++i) {
      ImuData &d = out_buf[i];

      uint8_t g_buf[6]{};
      g_i2c->read_block(ADDR_G, static_cast<uint8_t>((OUT_X_L_G | 0x80) & 0xFF),
                        g_buf, 6);
      d.gx = s16(g_buf[0], g_buf[1]);
      d.gy = s16(g_buf[2], g_buf[3]);
      d.gz = s16(g_buf[4], g_buf[5]);

      // Accel 配對：有新資料就用，否則填 -1
      if (accel_ok) {
        d.ax = s16(a_buf[0], a_buf[1]);
        d.ay = s16(a_buf[2], a_buf[3]);
        d.az = s16(a_buf[4], a_buf[5]);
      } else {
        d.ax = d.ay = d.az = -1;
      }

      d.timestamp_s = now_s();
      d.status = 0;
    }

    *out_count = to_read;
    return 0;

  } catch (const std::exception &e) {
    std::cerr << "imu_read_fifo error: " << e.what() << "\n";
    *out_count = 0;
    return -1;
  } catch (...) {
    *out_count = 0;
    return -1;
  }
}

// ── imu_read（舊介面相容） ────────────────────────────────────────────────
// 內部呼叫 imu_read_fifo，只取第一筆。
// FIFO 空時：status=-1，所有感測值=-1。
ImuData imu_read() {
  ImuData buf[1];
  int count = 0;
  imu_read_fifo(buf, 1, &count);
  // count 必然 >= 1（fill_no_data 或正常資料），直接回傳
  return buf[0];
}

} // extern "C"
