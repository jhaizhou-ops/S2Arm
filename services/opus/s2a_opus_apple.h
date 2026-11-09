// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors

// macOS 系统 Opus 解码后端（AudioToolbox）：只接管 48 kHz 单/双声道单流，其余仍由 libopus 解。
// 编译开关 S2A_OPUS_SYSTEM=1；默认不编译本后端。
#ifndef S2A_OPUS_APPLE_H
#define S2A_OPUS_APPLE_H

#include <stdint.h>

void *s2a_apple_open(int32_t rate, int32_t channels, int32_t *err);
int32_t s2a_apple_decode(void *handle, const uint8_t *data, int32_t len, int16_t *pcm, int32_t frame_size);
void s2a_apple_reset(void *handle);
void s2a_apple_close(void *handle);

#endif
