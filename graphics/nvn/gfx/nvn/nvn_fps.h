// 用户帧率设置只加上限；不改游戏的交换间隔，也不解除游戏原有的锁帧。
#pragma once
#include <stdint.h>

int nvn_fps_limit(void);   // S2A_FPS：0（不额外限帧）/ 30 / 60 / 120，进程启动设置
double nvn_fps_period(double period);   // 秒；取原周期与用户上限周期的较大值
uint64_t nvn_fps_period_ns(uint64_t period);   // 纳秒；0 上限逐值保持输入
