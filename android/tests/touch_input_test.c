#include "touch_input.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "touch:%d: %s\n", __LINE__, #x); return 1; } } while (0)
static atomic_int done;
static void *writer(void *unused) {
    (void)unused;
    for (uint32_t i = 0; i < 10000; ++i) {
        s2a_host_touch_point p = {.id = i, .x = i, .y = 65535 - i};
        if (s2a_android_touch_set(&p, 1, 0)) return (void *)1;
    }
    atomic_store(&done, 1);
    return NULL;
}

int main(void) {
    struct { s2a_host_touch_frame frame; uint64_t tail; } output = {
        .frame = {.size = sizeof output}, .tail = 0x12345678,
    };
    s2a_host_touch_frame *f = &output.frame;
    CHECK(s2a_android_touch_read(NULL, 0, f) == S2A_HOST_E_UNSUPPORTED);
    CHECK(s2a_android_touch_set(NULL, 0, 0) == S2A_HOST_E_UNSUPPORTED);
    CHECK(s2a_android_touch_enable(2) == S2A_HOST_E_ARGUMENT);
    CHECK(s2a_android_touch_enable(1) == 0);
    CHECK(s2a_android_touch_read(NULL, 0, f) == 0 && f->sequence == 0 && f->count == 0);
    s2a_host_touch_point p = {.id = 1234, .x = 32768, .y = 65535};
    CHECK(s2a_android_touch_set(&p, 1, 0) == 0);
    CHECK(s2a_android_touch_set(NULL, 0, 0) == 0); // Down/up before consumer's first poll.
    CHECK(s2a_android_touch_read(NULL, 0, f) == 0 && f->sequence == 1 && f->count == 1);
    CHECK(f->points[0].id == 1234 && f->points[0].x == 32768 && f->timestamp_ns > 0);
    s2a_host_touch_frame first = *f;
    CHECK(s2a_android_touch_read(NULL, 0, f) == 0 && !memcmp(f, &first, sizeof first));
    CHECK(s2a_android_touch_read(NULL, 1, f) == 0 && f->sequence == 2 && f->count == 0 && !f->flags);
    CHECK(s2a_android_touch_read(NULL, 2, f) == 0 && f->sequence == 2); // No new event.
    CHECK(output.tail == 0x12345678 && f->size == sizeof *f);
    CHECK(s2a_android_touch_read(NULL, 3, f) == S2A_HOST_E_ARGUMENT);
    f->size = 8;
    CHECK(s2a_android_touch_read(NULL, 0, f) == S2A_HOST_E_RANGE && f->size == 8);
    f->size = sizeof *f;
    p.x = 65536;
    CHECK(s2a_android_touch_set(&p, 1, 0) == S2A_HOST_E_ARGUMENT);
    p.x = 0;
    s2a_host_touch_point duplicates[2] = {p, p};
    CHECK(s2a_android_touch_set(duplicates, 2, 0) == S2A_HOST_E_ARGUMENT);
    CHECK(s2a_android_touch_set(&p, 1, S2A_TOUCH_CANCEL) == S2A_HOST_E_ARGUMENT);
    CHECK(s2a_android_touch_read(NULL, 2, f) == 0 && f->sequence == 2);
    CHECK(s2a_android_touch_set(NULL, 0, S2A_TOUCH_CANCEL) == 0);
    CHECK(s2a_android_touch_read(NULL, 2, f) == 0 && f->flags == S2A_TOUCH_CANCEL && f->count == 0);
    for (int i = 0; i < 65; ++i) CHECK(s2a_android_touch_set(&p, 1, 0) == 0);
    CHECK(s2a_android_touch_read(NULL, 0, f) == S2A_HOST_E_RANGE);
    CHECK(f->flags == S2A_TOUCH_CANCEL && !f->count && !f->points[0].id);
    uint64_t cursor = f->sequence;
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, writer, NULL) == 0);
    int coherent = 1;
    do {
        int result = s2a_android_touch_read(NULL, cursor, f);
        if (result == S2A_HOST_E_RANGE) {
            if (f->flags != S2A_TOUCH_CANCEL || f->count) coherent = 0;
        } else if (result || (f->count && f->points[0].x + f->points[0].y != 65535)) coherent = 0;
        cursor = f->sequence;
    } while (!atomic_load(&done));
    void *error;
    CHECK(pthread_join(thread, &error) == 0 && !error && coherent);
    CHECK(s2a_android_touch_enable(0) == 0);
    CHECK(s2a_android_touch_read(NULL, cursor, f) == S2A_HOST_E_UNSUPPORTED);
    CHECK(s2a_android_touch_enable(1) == 0);
    CHECK(s2a_android_touch_read(NULL, 0, f) == S2A_HOST_E_RANGE && f->flags == S2A_TOUCH_CANCEL);
    CHECK(s2a_android_touch_read(NULL, f->sequence, f) == 0 && f->flags == S2A_TOUCH_CANCEL);
    cursor = f->sequence;
    CHECK(s2a_android_touch_set_at(&p, 1, 0, 123000000) == 0);
    CHECK(s2a_android_touch_read(NULL, cursor, f) == 0 && f->timestamp_ns == 123000000);
    cursor = f->sequence;
    CHECK(s2a_android_touch_set_at(NULL, 0, 0, 124000000) == 0);
    CHECK(s2a_android_touch_read(NULL, cursor, f) == 0 && f->timestamp_ns == 124000000 && !f->count);
    // Switching arms between polls must not join gestures, even if a new DOWN
    // arrives before the consumer observes that input was disabled.
    CHECK(s2a_android_touch_set(&p, 1, 0) == 0);
    CHECK(s2a_android_touch_read(NULL, f->sequence, f) == 0 && f->count == 1);
    cursor = f->sequence;
    CHECK(s2a_android_touch_enable(0) == 0 && s2a_android_touch_enable(1) == 0);
    CHECK(s2a_android_touch_set(&p, 1, 0) == 0);
    CHECK(s2a_android_touch_read(NULL, cursor, f) == 0);
    CHECK(f->sequence == cursor + 1 && f->flags == S2A_TOUCH_CANCEL && f->count == 0);
    s2a_host_touch_frame barrier = *f;
    CHECK(s2a_android_touch_read(NULL, cursor, f) == 0 && !memcmp(f, &barrier, sizeof barrier));
    CHECK(s2a_android_touch_read(NULL, barrier.sequence, f) == 0);
    CHECK(f->sequence == cursor + 2 && f->flags == 0 && f->count == 1);
    puts("touch transport: short tap, replay, cancel, overflow, ABI tail and 10000 concurrent snapshots passed");
    return 0;
}
