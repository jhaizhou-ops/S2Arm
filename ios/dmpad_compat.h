// MelonX 虚拟手柄移植的兼容层声明（新增文件）。
// 源文件 DmGamepad.m / DmSettings.m 依赖的宿主能力在 S2Arm 里换了实现，统一在这里声明。
#pragma once
#import <Foundation/Foundation.h>

// 按游戏隔离的 UserDefaults：多款游戏共用一个壳，DmPad 的全部键都落在
// "S2ArmDmPad.<游戏号>" 这个 suite（游戏号取环境变量 S2A_DOCS 末级目录，单款包为 default）。
NSUserDefaults *DmCfgDefaults(void);

// 游戏震动（实体手柄 / 手机马达 / NS2 Pro）的总开关与 0~4 档强度，实现在 ios/controller.m。
void s2a_rumble_set_enabled(int on);
void s2a_rumble_set_level(int lv);
