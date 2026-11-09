// 兼容层（移植自 nxnative-hades1 的 dm/host/dm_input.h）：只保留 DmGamepad.m / DmSettings.m 需要的部分。
// S2Arm 的按键出口是 runtime/include/s2a_pad.h 的 s2a_pad_update，不再有 dm_input_set。
#pragma once
#include <stdint.h>

// 按键轻震：S2Arm 版由 ios/dmpad_haptics.m 本地实现（UIImpactFeedbackGenerator）。
// 游戏本体的 HD 震动归 S2Arm 的 ios/controller.m 管，这里只保存菜单开关状态。
void dm_haptics_set_enabled(int on);
void dm_haptics_set_strength(int level);   // 0..4
void dm_haptics_set_buttons(int on);
void dm_haptics_tap(void);

// 当前按住的键位掩码（位序 = H_A=bit0 … H_DOWN=bit15），ios/dmpad.m 实现；金手指的快捷键节用它。
uint64_t dm_input_held(void);
