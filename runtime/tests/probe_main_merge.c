// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Actual rewritten modules and production native entry points; no guest starts.
#include "../src/native.h"

int svc_mem(int, uint64_t *, uint64_t);
int s2a_widen_session_reset(void);
void s2a_widen_start(void);
int main(int argc, char **argv) {
    if (argc < 3 || !s2a_window_ok()) return 2;
    if (getenv("S2A_WIDEN_VERIFIED") || getenv("S2A_WIDEN_NARROW")) return 2;
    load_modules(argv[1], (const char **)&argv[2], argc - 2);
    s2a_widen_start();
    // Join the real scanner before changing its table/settings state.
    if (s2a_widen_session_reset()) return 1;
    if (setenv("S2A_SCREEN_W", "2560", 1) || setenv("S2A_WIDESCREEN", "1", 1) ||
        setenv("S2A_WIDEN_CAPS", "0", 1)) return 1;
    int blocked = s2a_screen_w();
    const char *narrow = getenv("S2A_WIDEN_NARROW");
    if (blocked != 1920 || !narrow || strcmp(narrow, "1")) return 1;
    if (s2a_widen_session_reset() || getenv("S2A_WIDEN_NARROW")) return 1;
    if (setenv("S2A_WIDEN_CAPS", "1", 1)) return 1;
    int allowed = s2a_screen_w();
    if (allowed != 2560 || getenv("S2A_WIDEN_NARROW")) return 1;
    if (s2a_widen_session_reset() || setenv("S2A_WIDEN_NARROW", "launch", 1) ||
        setenv("S2A_WIDEN_CAPS", "0", 1)) return 1;
    if (s2a_screen_w() != 1920 || strcmp(getenv("S2A_WIDEN_NARROW"), "launch")) return 1;
    if (s2a_widen_session_reset() || strcmp(getenv("S2A_WIDEN_NARROW"), "launch")) return 1;
    uint64_t regs[31] = {0x80000003ull};
    int handled = svc_mem(0x26, regs, (uint64_t)g_mod[0].base);
    printf("widen blocked=%d allowed=%d; auto narrow cleared, launch value retained; Break notification handled=%d result=%llu\n",
           blocked, allowed, handled, (unsigned long long)regs[0]);
    return handled != 1 || regs[0] != 0;
}
