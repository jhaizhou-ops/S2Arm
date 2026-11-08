// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
// 直连编译器描述符种类校验的开关（单变量排查用）：native 侧判定，编译请求 JSON 带 kindCheck=false。
// 必须过调试门（debug_gate.h 的两道门）：
//   - 门关着（正式构建没有 S2A_ANDROID_DEBUG_ENV，或运行期没有 debug.s2a.debug_env=1）恒为开，
//     只放行缺省值：玩家包里 adb 设 debug.s2a.kind_check=0 不会关掉校验；
//   - 门开着且 debug.s2a.kind_check=0 才关，由请求 JSON 的 `kindCheck:false` 交给编译器，不写环境变量。
#include <stdbool.h>
#include <stdlib.h>
#include "../debug_gate.h"

static inline bool s2a_direct_kind_check_enabled(void) {
    if (!s2a_debug_entries_open()) return true;
#if defined(__ANDROID__)
    char value[PROP_VALUE_MAX] = {0};
    if (__system_property_get("debug.s2a.kind_check", value) == 1 && value[0] && atoi(value) == 0) return false;
#endif
    return true;
}
