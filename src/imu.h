#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ImuData {
  double timestamp_s;
  int16_t ax, ay, az;
  int16_t gx, gy, gz;
  // status:  0 = 成功
  //         -1 = 未初始化 / FIFO 無資料（所有感測值亦為 -1）
  //         -2 = 讀取錯誤
  int status;
} ImuData;

// LSM9DS0 Gyro FIFO 最大深度 32 筆
#define IMU_FIFO_MAX_SAMPLES 32

// 初始化：成功回傳 0，失敗回傳負數
int imu_init();

// 釋放資源
void imu_deinit();

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
