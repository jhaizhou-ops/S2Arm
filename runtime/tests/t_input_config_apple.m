// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Reuse the real platform adapter fixture, but exit before any AppKit/Metal UI.
#define main s2a_mac_input_fixture_main
#include "../../launchers/macos/Tests/input_test.m"
#undef main
#include "s2a_t_result.h"
int main(void) {
    const char *args[] = {"input-config", "--input-config-only"};
    int rc = s2a_mac_input_fixture_main(2, args);
    return S2A_T_RESULT("t_input_config_apple", rc);
}
