// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#ifndef S2A_MAC_NS2_PARENT_WATCH_H
#define S2A_MAC_NS2_PARENT_WATCH_H
#include <sys/types.h>

// Blocks until parent exits. Returns 1 after the exit, 0 if the watch could not be installed.
int s2a_ns2_wait_for_parent_exit(pid_t parent);

#endif
