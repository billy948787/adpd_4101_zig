#include <stdint.h>

extern "C" {
struct ImuData {
  double timestamp_s;
  int16_t ax, ay, az;
  int16_t gx, gy, gz;
  int status; // 0 = 成功, -1 = 未初始化, -2 = 讀取錯誤
};

int imu_init();

ImuData imu_read();

void imu_deinit();
}