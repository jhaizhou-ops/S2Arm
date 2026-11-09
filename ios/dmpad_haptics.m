// 虚拟手柄的按键轻震（新增文件，替代源项目 DmHaptics.m 的 HD 震动）。
// 源 DmHaptics.m 是给 Hades 的 hle_haptics 挂 Core Haptics 的；S2Arm 的游戏震动由 ios/controller.m /
// ios/phone_motion.m 自己的 s2a_pad_set_rumble 链路发到实体手柄，这里只做虚拟按键按下的本地轻震。
#import <UIKit/UIKit.h>
#include <stdatomic.h>
#include "dm_input.h"

static _Atomic int g_on = 1;    // 震动总开关（游戏本体）
static _Atomic int g_btn = 1;   // 虚拟按键轻震
static _Atomic int g_lv = 1;    // 0 弱 … 4 最强

void dm_haptics_set_enabled(int on) { atomic_store(&g_on, on ? 1 : 0); }
void dm_haptics_set_strength(int level) {
    if (level < 0) level = 0;
    if (level > 4) level = 4;
    atomic_store(&g_lv, level);
}
void dm_haptics_set_buttons(int on) { atomic_store(&g_btn, on ? 1 : 0); }

void dm_haptics_tap(void) {
    if (!atomic_load(&g_on) || !atomic_load(&g_btn)) return;
    int lv = atomic_load(&g_lv);
    dispatch_async(dispatch_get_main_queue(), ^{
        static UIImpactFeedbackGenerator *gen;
        if (!gen) gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        // 0 档也要有手感（最轻），不再直接吞掉这次轻震
        [gen impactOccurredWithIntensity:MIN(1.0, 0.2 + 0.2 * lv)];
    });
}
