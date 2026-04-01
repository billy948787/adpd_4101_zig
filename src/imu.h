#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ImuData {
  double timestamp_s;
  int16_t ax, ay, az;
  int16_t gx, gy, gz;
  int16_t mx, my, mz;
  // status:  0 = 成功
  //         -1 = 未初始化 / FIFO 無資料（所有感測值亦為 -1）
  //         -2 = 讀取錯誤
  int status;
} ImuData;

// LSM9DS0 Gyro FIFO 最大深度 32 筆
#define IMU_FIFO_MAX_SAMPLES 32

// 初始化 I2C，預設進入 disable 狀態（Gyro/Accel power down）
int imu_init();
void imu_deinit();

// 開啟感測器：Gyro/Accel power on + 清空並重啟 FIFO
// 藍芽連線建立後呼叫
int imu_enable();

// 關閉感測器：Gyro/Accel power down + FIFO bypass（停止累積舊資料）
// 藍芽斷線或等待連線時呼叫
void imu_disable();

// 舊介面（相容）：讀取一筆。FIFO 空時 status=-1，所有值=-1
ImuData imu_read();

// FIFO 批次讀取
//   out_buf   : 呼叫者提供的緩衝區（建議 >= IMU_FIFO_MAX_SAMPLES）
//   buf_size  : out_buf 容量（筆數）
//   out_count : 實際寫入筆數
//
//   FIFO 無資料 → out_count=1，out_buf[0].status=-1，所有感測值=-1
//   硬體錯誤   → 回傳 -1，out_count=0
//   正常       → 回傳  0，out_count >= 1
int imu_read_fifo(ImuData *out_buf, int buf_size, int *out_count);

#ifdef __cplusplus
}
#endif
