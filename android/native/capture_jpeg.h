// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#include <jni.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
// Initialize on Java's registration thread so class loading never depends on a guest thread's loader.
__attribute__((visibility("hidden"))) int s2a_android_capture_init(JNIEnv *env, jclass encoder);
__attribute__((visibility("hidden"))) int s2a_android_encode_jpeg(const uint8_t *rgba, uint64_t bytes,
    int32_t width, int32_t height, int32_t quality, uint8_t **jpeg, uint64_t *length);
__attribute__((visibility("hidden"))) void s2a_android_free_jpeg(void *jpeg);
#ifdef __cplusplus
}
#endif
