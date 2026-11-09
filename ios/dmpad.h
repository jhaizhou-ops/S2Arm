// MelonX 风格虚拟手柄（移植自 nxnative-hades1 的 DmGamepad.m）对外入口。
#pragma once
#import <UIKit/UIKit.h>

// 把手柄挂到 App 根视图上。必须在主线程调用；旧 vpad 不再 attach（两套手柄会互相覆盖按键）。
void dm_pad_attach(UIView *root);
// 根控制器要的朝向掩码：锁定时只给菜单选中的方向（缺省横屏），未锁时横竖都收。齿轮菜单的「竖屏 / 横屏」用 dm_pad_rotate_to 转向。
unsigned dm_pad_supported_orientations(void);
void dm_pad_rotate_to(int portrait);
