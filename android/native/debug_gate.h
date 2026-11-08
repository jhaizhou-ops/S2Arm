// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
// 调试入口两道门的原生侧（10-31 总指挥；Java 侧见 DebugGate.java）：
//   ① 调试构建：CMake Debug 配置才定义 S2A_ANDROID_DEBUG_ENV（正式构建的玩家包里这道门编译期就关着）；
//   ② 系统属性 debug.s2a.debug_env=1：普通 App 设不了 debug.* 属性，只有 adb shell 能开。
// 两道都开才为真。各调试配置入口在门关着时只放行缺省值，env 透传直接拒。
#if defined(__ANDROID__)
#include <sys/system_properties.h>
#endif

static inline bool s2a_debug_entries_open() {
#if defined(S2A_ANDROID_DEBUG_ENV) && defined(__ANDROID__)
    char value[PROP_VALUE_MAX] = {0};
    return __system_property_get("debug.s2a.debug_env", value) == 1 && value[0] == '1';
#else
    return false;
#endif
}
