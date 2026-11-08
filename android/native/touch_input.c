#include "touch_input.h"
#include <pthread.h>
#include <string.h>
#include <time.h>

enum { HISTORY = 64 };
static pthread_mutex_t touch_lock = PTHREAD_MUTEX_INITIALIZER;
static s2a_host_touch_frame frames[HISTORY];
static uint64_t latest;
static unsigned retained;
static int enabled;

_Static_assert(sizeof(s2a_host_touch_point) == 20, "touch point ABI");
_Static_assert(sizeof(s2a_host_touch_frame) == 352, "touch frame ABI");

int s2a_android_touch_enable(int value) {
    if (value != 0 && value != 1) return S2A_HOST_E_ARGUMENT;
    pthread_mutex_lock(&touch_lock);
    if (enabled != value) {
        struct timespec ts = {0};
        if (value && latest && (latest == UINT64_MAX || clock_gettime(CLOCK_MONOTONIC, &ts))) {
            pthread_mutex_unlock(&touch_lock);
            return S2A_HOST_E_INTERNAL;
        }
        enabled = value;
        retained = 0;
        memset(frames, 0, sizeof frames);
        // A disable/enable pair can occur entirely between consumer polls.
        // Publish a distinct cancellation before accepting new contacts so a
        // consumer cannot join the previous gesture to the next session.
        if (value && latest) {
            s2a_host_touch_frame *barrier = &frames[latest % HISTORY];
            barrier->size = sizeof *barrier;
            barrier->abi_version = S2A_HOST_API_ABI_VERSION;
            barrier->sequence = ++latest;
            barrier->timestamp_ns = (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
            barrier->flags = S2A_TOUCH_CANCEL;
            retained = 1;
        }
    }
    pthread_mutex_unlock(&touch_lock);
    return S2A_HOST_E_OK;
}

int s2a_android_touch_set(const s2a_host_touch_point *points, uint32_t count,
                          uint32_t flags) {
    return s2a_android_touch_set_at(points, count, flags, 0);
}

int s2a_android_touch_set_at(const s2a_host_touch_point *points, uint32_t count,
                             uint32_t flags, uint64_t timestamp_ns) {
    if (count > S2A_TOUCH_MAX_POINTS || (count && !points) ||
        (flags & ~S2A_TOUCH_CANCEL) || ((flags & S2A_TOUCH_CANCEL) && count))
        return S2A_HOST_E_ARGUMENT;
    s2a_host_touch_frame frame = {.size = sizeof frame,
        .abi_version = S2A_HOST_API_ABI_VERSION, .flags = flags, .count = count};
    for (uint32_t i = 0; i < count; ++i) {
        const s2a_host_touch_point *p = &points[i];
        if (p->x > S2A_TOUCH_COORD_MAX || p->y > S2A_TOUCH_COORD_MAX ||
            p->diameter_x > S2A_TOUCH_COORD_MAX || p->diameter_y > S2A_TOUCH_COORD_MAX)
            return S2A_HOST_E_ARGUMENT;
        for (uint32_t j = 0; j < i; ++j)
            if (frame.points[j].id == p->id) return S2A_HOST_E_ARGUMENT;
        frame.points[i] = *p;
    }
    pthread_mutex_lock(&touch_lock);
    if (!enabled) {
        pthread_mutex_unlock(&touch_lock);
        return S2A_HOST_E_UNSUPPORTED;
    }
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) || latest == UINT64_MAX) {
        pthread_mutex_unlock(&touch_lock);
        return S2A_HOST_E_INTERNAL;
    }
    frame.timestamp_ns = timestamp_ns ? timestamp_ns :
        (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
    frame.sequence = ++latest;
    frames[(latest - 1) % HISTORY] = frame;
    if (retained < HISTORY) ++retained;
    pthread_mutex_unlock(&touch_lock);
    return S2A_HOST_E_OK;
}

int s2a_android_touch_read(void *host, uint64_t after_sequence,
                           s2a_host_touch_frame *out) {
    (void)host;
    if (!out) return S2A_HOST_E_ARGUMENT;
    if (out->size < sizeof *out) return S2A_HOST_E_RANGE;
    pthread_mutex_lock(&touch_lock);
    if (!enabled) {
        pthread_mutex_unlock(&touch_lock);
        return S2A_HOST_E_UNSUPPORTED;
    }
    if (after_sequence > latest) {
        pthread_mutex_unlock(&touch_lock);
        return S2A_HOST_E_ARGUMENT;
    }
    int result = S2A_HOST_E_OK;
    if (!latest) {
        memset(out, 0, sizeof *out);
        out->size = sizeof *out;
        out->abi_version = S2A_HOST_API_ABI_VERSION;
    } else {
        uint64_t oldest = latest - retained + 1;
        if (after_sequence < oldest - 1) {
            memset(out, 0, sizeof *out);
            out->size = sizeof *out;
            out->abi_version = S2A_HOST_API_ABI_VERSION;
            out->sequence = latest;
            out->flags = S2A_TOUCH_CANCEL;
            out->count = 0;
            memset(out->points, 0, sizeof out->points);
            result = S2A_HOST_E_RANGE;
        } else if (!retained) {
            memset(out, 0, sizeof *out);
            out->size = sizeof *out;
            out->abi_version = S2A_HOST_API_ABI_VERSION;
            out->sequence = latest;
            out->flags = S2A_TOUCH_CANCEL;
        } else {
            uint64_t next = after_sequence < latest ? after_sequence + 1 : latest;
            *out = frames[(next - 1) % HISTORY];
        }
    }
    pthread_mutex_unlock(&touch_lock);
    return result;
}
