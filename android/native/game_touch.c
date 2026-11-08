#include "game_touch.h"
#include <pthread.h>
#include <string.h>
#include <stdatomic.h>
#include <time.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int64_t viewport[8];
static uint64_t last_generation, retired_generation, viewport_epoch = 1;
static _Atomic int trace_enabled;
int s2a_android_game_touch_trace(void) { return atomic_load(&trace_enabled); }
void s2a_android_game_touch_trace_set(int value) { atomic_store(&trace_enabled, !!value); }
uint64_t s2a_android_game_touch_now(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) return 0;
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void cancel(void) {
#ifdef S2A_ANDROID_EXPERIMENTAL_TOUCH
    (void)s2a_android_touch_set(NULL, 0, S2A_TOUCH_CANCEL);
#endif
}

static void advance_epoch(void) { if (viewport_epoch < UINT64_MAX) viewport_epoch++; }

void s2a_android_game_touch_offer(uint64_t generation) {
    pthread_mutex_lock(&lock);
    if (generation > last_generation && generation <= INT64_MAX) {
        cancel(); viewport[0] = 0; last_generation = generation; advance_epoch();
    }
    pthread_mutex_unlock(&lock);
}

uint64_t s2a_android_game_touch_epoch(void) {
    pthread_mutex_lock(&lock);
    uint64_t epoch = viewport_epoch == UINT64_MAX ? 0 : viewport_epoch;
    pthread_mutex_unlock(&lock);
    return epoch;
}

static void viewport_locked(uint64_t generation, int left, int top, int width, int height,
                            int buffer_width, int buffer_height) {
    if (!generation || generation > INT64_MAX || left < 0 || top < 0 || width <= 0 || height <= 0 ||
        buffer_width <= 0 || buffer_height <= 0 || left > buffer_width - width || top > buffer_height - height) {
        cancel(); viewport[0] = 0; advance_epoch(); return;
    }
    if (generation <= retired_generation || generation < last_generation) return;
    last_generation = generation;
    int64_t next[8] = {(int64_t)generation, viewport[1], left, top, width, height, buffer_width, buffer_height};
    if (memcmp(next, viewport, sizeof next)) {
        cancel();
        if (viewport[1] == INT64_MAX) { viewport[0] = 0; }
        else { next[1]++; memcpy(viewport, next, sizeof viewport); }
    }
}

void s2a_android_game_touch_viewport(uint64_t generation, int left, int top,
    int width, int height, int buffer_width, int buffer_height) {
    pthread_mutex_lock(&lock);
    viewport_locked(generation, left, top, width, height, buffer_width, buffer_height);
    pthread_mutex_unlock(&lock);
}

void s2a_android_game_touch_viewport_checked(uint64_t epoch, uint64_t generation, int left, int top,
    int width, int height, int buffer_width, int buffer_height) {
    pthread_mutex_lock(&lock);
    if (epoch && epoch == viewport_epoch)
        viewport_locked(generation, left, top, width, height, buffer_width, buffer_height);
    pthread_mutex_unlock(&lock);
}

void s2a_android_game_touch_revoke(void) {
    pthread_mutex_lock(&lock);
    cancel(); viewport[0] = 0; advance_epoch();
    pthread_mutex_unlock(&lock);
}

void s2a_android_game_touch_retire(void) {
    pthread_mutex_lock(&lock);
    cancel();
    if (last_generation > retired_generation) retired_generation = last_generation;
    viewport[0] = 0; advance_epoch();
    pthread_mutex_unlock(&lock);
}

int s2a_android_game_touch_viewport_read(int64_t out[8]) {
    if (!out) return S2A_HOST_E_ARGUMENT;
    pthread_mutex_lock(&lock);
    memcpy(out, viewport, sizeof viewport);
    int result = viewport[0] ? S2A_HOST_E_OK : S2A_HOST_E_UNSUPPORTED;
    pthread_mutex_unlock(&lock);
    return result;
}

int s2a_android_game_touch_set(const s2a_host_touch_point *points, uint32_t count,
    uint32_t flags, uint64_t ns, uint64_t generation, uint64_t revision) {
#ifdef S2A_ANDROID_EXPERIMENTAL_TOUCH
    if (count > S2A_TOUCH_MAX_POINTS || (count && !points)) return S2A_HOST_E_ARGUMENT;
    pthread_mutex_lock(&lock);
    int result;
    if (!flags && (!viewport[0] || generation != (uint64_t)viewport[0] || revision != (uint64_t)viewport[1])) {
        cancel();
        result = S2A_HOST_E_RANGE;
    } else {
        // HID is display-space input, not the source texture's memory origin.
        result = s2a_android_touch_set_at(points, count, flags, ns);
    }
    pthread_mutex_unlock(&lock);
    return result;
#else
    (void)points; (void)count; (void)flags; (void)ns; (void)generation; (void)revision;
    return S2A_HOST_E_UNSUPPORTED;
#endif
}

int s2a_android_game_touch_read(uint64_t after, s2a_host_touch_frame *out) {
#ifdef S2A_ANDROID_EXPERIMENTAL_TOUCH
    return s2a_android_touch_read(NULL, after, out);
#else
    (void)after; (void)out;
    return S2A_HOST_E_UNSUPPORTED;
#endif
}
