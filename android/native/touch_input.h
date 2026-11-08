#pragma once
#include "s2a_hostapi.h"
#include "touch_contract.h"

#ifdef __cplusplus
extern "C" {
#endif
// Whole-contact-set publisher. Validation failures leave history unchanged.
// The shell excludes virtual-control fingers and maps the final game viewport.
// Disabled at process start. A future diagnostic shell may select either arm
// of a same-APK A/B run before guest startup; this is not a game profile knob.
int s2a_android_touch_enable(int enabled);
int s2a_android_touch_set(const s2a_host_touch_point *points, uint32_t count,
                          uint32_t flags);
// MotionEvent uptime milliseconds converted to nanoseconds shares CLOCK_MONOTONIC.
// Zero requests publication time (lifecycle cancellation, native callers).
int s2a_android_touch_set_at(const s2a_host_touch_point *points, uint32_t count,
                             uint32_t flags, uint64_t timestamp_ns);
int s2a_android_touch_read(void *host, uint64_t after_sequence,
                           s2a_host_touch_frame *out);
#ifdef __cplusplus
}
#endif
