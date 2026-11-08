#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void s2a_android_input_set(uint32_t buttons, const int32_t sticks[4]);
void s2a_android_input_reset(void);
// The latest state and when it was set (CLOCK_MONOTONIC ns; 0 before the first set). Any thread.
uint32_t s2a_android_input_read(int32_t sticks[4], uint64_t *timestamp_ns);
// Same ABI as ios/vpad.m, for the existing InputPump hook.
uint32_t s2a_vpad_read(int32_t sticks[4]);
#ifdef __cplusplus
}
#endif

