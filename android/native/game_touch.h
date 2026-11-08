#pragma once
#include "touch_input.h"
#ifdef __cplusplus
extern "C" {
#endif
// Final compositor pixels, in the same surface-local space as the overlay.
void s2a_android_game_touch_viewport(uint64_t generation, int left, int top,
    int width, int height, int buffer_width, int buffer_height);
// Window-offer and an epoch prevent a late in-flight present from reviving
// a retired generation or a viewport revoked while that frame was in flight.
void s2a_android_game_touch_offer(uint64_t generation);
uint64_t s2a_android_game_touch_epoch(void);
void s2a_android_game_touch_viewport_checked(uint64_t epoch, uint64_t generation, int left, int top,
    int width, int height, int buffer_width, int buffer_height);
void s2a_android_game_touch_revoke(void);
void s2a_android_game_touch_retire(void);
int s2a_android_game_touch_viewport_read(int64_t out[8]);
int s2a_android_game_touch_set(const s2a_host_touch_point *points, uint32_t count,
    uint32_t flags, uint64_t ns, uint64_t generation, uint64_t revision);
int s2a_android_game_touch_read(uint64_t after, s2a_host_touch_frame *out);
int s2a_android_game_touch_trace(void);
void s2a_android_game_touch_trace_set(int enabled);
uint64_t s2a_android_game_touch_now(void);
#ifdef __cplusplus
}
#endif
