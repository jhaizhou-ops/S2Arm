// 自动玩家缺省开不开（单独成头，单测直接包含：tests/autoplay_default_test.sh）。
// 玩家自己打开的入口缺省关：iPhone App、Mac 前端（S2A_MAC_FRONTEND=1 编的宿主，S2Arm.app 起游戏用的那份）——
//   人从桌面 / App 里点开，没有任何环境变量，缺省开会让自动玩家在人玩的时候替他按键（10-20 jhz 亲手试玩；10-24 Mac 前端同一缺陷）。
//   测试执行器显式给 S2A_AUTOPLAY=1 才开。
// 开发 / 测试用的 Mac 宿主（不带前端，run_mac.sh / 真值对拍）缺省照旧开，显式 S2A_AUTOPLAY=0 才关。
#pragma once
#include <stdlib.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

static inline int s2a_autoplay_default(const char *autoplay) {
#if (defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE) || defined(S2A_MAC_FRONTEND)
    return autoplay && atoi(autoplay) == 1;
#else
    return !(autoplay && *autoplay && atoi(autoplay) == 0);
#endif
}
