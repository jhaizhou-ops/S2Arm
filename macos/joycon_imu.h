// Mac Joy-Con / Pro：GameController 不暴露 GCMotion，六轴走 HID 标准全报告（0x30）。
// 与 front_mac.m 的 s2a_pad_read_motion 对接；单位同 s2a_pad_motion（g、度/秒，NS2 原始坐标约定由本文件按握持近似映射）。
#ifndef S2A_JOYCON_IMU_H
#define S2A_JOYCON_IMU_H
#include "../runtime/include/s2a_pad.h"

// 游戏要六轴时打开（发 enable IMU + input mode 0x30）；关掉恢复 0x3F。shared 打开，尽量不抢 GameController 按键。
void s2a_joycon_imu_set_enabled(int enabled);

// 读左右最新样本。返回位掩码：bit0=左、bit1=右（含 Pro 当「右」单源）。out_l / out_r 可为 NULL。
int s2a_joycon_imu_read(s2a_pad_motion *out_l, s2a_pad_motion *out_r);

#endif
