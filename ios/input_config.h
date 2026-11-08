// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#include "s2a_input_config.h"
// File access stays in the Apple shell. Relative import paths are under
// S2A_DOCS or the app Documents directory. No keyboard/mouse sampling here.
int s2a_ios_input_config_read(const char *path, s2a_input_config *out);
// Main thread, before starting host/input threads. A failed load exposes no
// current table; the caller must refuse this startup rather than use old input.
int s2a_ios_input_config_load(void);
const s2a_input_config *s2a_ios_input_config_current(void);
