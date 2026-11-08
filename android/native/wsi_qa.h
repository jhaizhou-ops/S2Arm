// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <cerrno>
#include <cstring>

// Debug build + the host debug gate must both be enabled. Release ignores even a forged value.
static inline int s2a_wsi_qa_disable_maintenance(bool gate_open, const char *value) {
#if defined(S2A_ANDROID_DEBUG_ENV)
    if (!gate_open || value == nullptr || std::strcmp(value, "0") == 0) return 0;
    if (std::strcmp(value, "1") == 0) return 1;
    return -EINVAL;
#else
    (void)gate_open; (void)value;
    return 0;
#endif
}
