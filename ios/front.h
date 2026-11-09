// 兼容层（移植自 nxnative-hades1 的 dm/host/front.h）：触摸直通接口。
// 本阶段不做触屏直通（虚拟手柄只发按键），dm_touch_set_from / dm_touch_cancel_from 为空实现。
#pragma once
#include <stdint.h>

// 触摸来源编号（源 front.h 的枚举值；这里只保留 IOS 这一路占位）
enum { DM_CONTACT_IOS = 1 };

typedef struct {
    uint32_t id;
    float x, y;   // 画面归一化坐标
} dm_touch;

void dm_touch_set_from(const dm_touch *t, int n, int source);
void dm_touch_cancel_from(int source);

// 上屏帧数（性能叠层按它算 FPS）；S2Arm 侧接 runtime/src/ap_host.c 的 s2a_ap_frames
uint64_t dm_guest_frame(void);
