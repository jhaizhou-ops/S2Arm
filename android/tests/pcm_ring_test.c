#define _POSIX_C_SOURCE 200809L
#include "pcm_ring.h"
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int failures;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

#define TOTAL_FRAMES 2000000u
static struct s2a_pcm_ring shared;
static struct timespec deadline;
static _Atomic int stop_writer, writer_done;
static int writer_complete;

static int before_deadline(void) {
    struct timespec now;
    return clock_gettime(CLOCK_MONOTONIC, &now) == 0 &&
        (now.tv_sec < deadline.tv_sec ||
         (now.tv_sec == deadline.tv_sec && now.tv_nsec < deadline.tv_nsec));
}

// Also bound a stuck ring call or pthread_join; ctest's 30 s limit is not our oracle.
static void timed_out(int sig) {
    (void)sig;
    // Even stderr may be blocked; the hard deadline must not perform I/O.
    _Exit(1);
}

// Stereo i16 frames carry a counter starting at 1 in both channels.
// A queued sample becoming 0 is corruption, not evidence that it was padding.
static void *writer(void *arg) {
    (void)arg;
    int16_t chunk[2 * 97];
    uint32_t next = 1;
    while (next <= TOTAL_FRAMES) {
        uint32_t frames = 0;
        for (; frames < 97 && next + frames <= TOTAL_FRAMES; frames++)
            chunk[2 * frames] = chunk[2 * frames + 1] = (int16_t)(((next + frames - 1) % 32767) + 1);
        uint32_t done = 0;
        while (done < frames * 4) {
            if (atomic_load_explicit(&stop_writer, memory_order_relaxed)) goto finished;
            if (!before_deadline()) {
                fputs("pcm ring: writer exceeded 5 s\n", stderr);
                goto finished;
            }
            uint32_t n = s2a_pcm_ring_write(&shared, (uint8_t *)chunk + done, frames * 4 - done);
            if (n > frames * 4 - done || n % 4) goto finished;
            done += n;
            if (!n) sched_yield();
        }
        next += frames;
    }
    writer_complete = 1;
finished:
    atomic_store_explicit(&writer_done, 1, memory_order_release);
    return NULL;
}

int main(void) {
    struct s2a_pcm_ring r;
    CHECK(s2a_pcm_ring_init(&r, S2A_PCM_I16, 2, 100) == 0 && r.capacity == 512 && s2a_pcm_ring_space(&r) == 512);
    CHECK(s2a_pcm_ring_init(&r, 3, 2, 100) != 0 && s2a_pcm_ring_init(&r, S2A_PCM_I16, 0, 100) != 0);
    CHECK(s2a_pcm_ring_init(&r, S2A_PCM_I16, 2, 100) == 0);

    // Whole frames only, padding counted, contents exact.
    uint8_t in[512], out[512];
    for (int i = 0; i < 512; i++) in[i] = (uint8_t)(i * 7 + 1);
    CHECK(s2a_pcm_ring_write(&r, in, 3) == 0);
    CHECK(s2a_pcm_ring_write(&r, in, 300) == 300 && s2a_pcm_ring_space(&r) == 212);
    s2a_pcm_ring_read(&r, out, 50);
    CHECK(!memcmp(out, in, 200));
    memset(out, 0xee, sizeof out);
    s2a_pcm_ring_read(&r, out, 50);
    CHECK(!memcmp(out, in + 200, 100));
    int zero = 1;
    for (int i = 100; i < 200; i++) zero &= out[i] == 0;
    CHECK(zero && r.frames_out == 75 && r.frames_padded == 25);

    // Wrap-around: positions are past 300 bytes, a 400-byte write crosses the end.
    CHECK(s2a_pcm_ring_write(&r, in, 400) == 400);
    CHECK(s2a_pcm_ring_write(&r, in, 400) == 112);   // only the remaining space
    s2a_pcm_ring_read(&r, out, 128);
    CHECK(!memcmp(out, in, 400) && !memcmp(out + 400, in, 112));

    // Volume, i16 and float.
    int16_t s[4] = {1000, -1000, 32767, -32768};
    s2a_pcm_ring_set_volume(&r, 0.5f);
    s2a_pcm_ring_write(&r, s, sizeof s);
    s2a_pcm_ring_read(&r, s, 2);
    CHECK(s[0] == 500 && s[1] == -500 && s[2] == 16383 && s[3] == -16384);
    s2a_pcm_ring_set_volume(&r, 7.0f);   // clamped to 1
    s2a_pcm_ring_free(&r);
    struct s2a_pcm_ring f;
    CHECK(s2a_pcm_ring_init(&f, S2A_PCM_F32, 1, 16) == 0 && f.frame_bytes == 4);
    float v[2] = {0.8f, -0.4f};
    s2a_pcm_ring_set_volume(&f, 0.25f);
    s2a_pcm_ring_write(&f, v, sizeof v);
    s2a_pcm_ring_read(&f, v, 2);
    CHECK(v[0] > 0.199f && v[0] < 0.201f && v[1] < -0.099f && v[1] > -0.101f);
    s2a_pcm_ring_free(&f);

    // One writer thread, this thread reading: every frame arrives once, in order.
    CHECK(s2a_pcm_ring_init(&shared, S2A_PCM_I16, 2, 256) == 0);
    CHECK(clock_gettime(CLOCK_MONOTONIC, &deadline) == 0);
    struct sigaction action = {0};
    action.sa_handler = timed_out;
    sigemptyset(&action.sa_mask);
    CHECK(sigaction(SIGALRM, &action, NULL) == 0);
    if (failures) return 1;
    deadline.tv_sec += 5;
    alarm(10);
    pthread_t t;
    int created = pthread_create(&t, NULL, writer, NULL);
    CHECK(created == 0);
    if (created) return 1;
    int16_t buf[2 * 61];
    uint32_t seen = 0;
    int ordered = 1;
    while (seen < TOTAL_FRAMES) {
        if (!before_deadline()) {
            fputs("pcm ring: reader exceeded 5 s\n", stderr);
            ordered = 0;
            break;
        }
        uint64_t out_before = atomic_load_explicit(&shared.frames_out, memory_order_relaxed);
        uint64_t pad_before = atomic_load_explicit(&shared.frames_padded, memory_order_relaxed);
        uint64_t read_before = atomic_load_explicit(&shared.read, memory_order_relaxed);
        s2a_pcm_ring_read(&shared, buf, 61);
        // Only this thread changes these counters. Their deltas delimit data/padding;
        // the independent sequence and total still decide whether the data is correct.
        uint64_t got = atomic_load_explicit(&shared.frames_out, memory_order_relaxed) - out_before;
        uint64_t pad = atomic_load_explicit(&shared.frames_padded, memory_order_relaxed) - pad_before;
        uint64_t bytes = atomic_load_explicit(&shared.read, memory_order_relaxed) - read_before;
        if (got > 61 || pad != 61 - got || bytes != got * 4 || got > TOTAL_FRAMES - seen) {
            fputs("pcm ring: inconsistent read accounting\n", stderr);
            ordered = 0;
            break;
        }
        for (uint32_t i = 0; i < 61; i++) {
            int16_t expected = i < got ? (int16_t)(((seen + i) % 32767) + 1) : 0;
            if (buf[2 * i] != expected || buf[2 * i + 1] != expected) {
                fprintf(stderr, "pcm ring: frame %u expected %d, got %d/%d (%s)\n",
                        seen + i, expected, buf[2 * i], buf[2 * i + 1], i < got ? "data" : "padding");
                ordered = 0;
                break;
            }
        }
        if (!ordered) break;
        seen += (uint32_t)got;
        // Acquire completion before checking the queue: a writer may have published
        // the final chunk after this read, so an earlier padded read alone is not EOF.
        if (seen < TOTAL_FRAMES && atomic_load_explicit(&writer_done, memory_order_acquire) &&
            atomic_load_explicit(&shared.read, memory_order_relaxed) ==
            atomic_load_explicit(&shared.written, memory_order_acquire)) {
            fprintf(stderr, "pcm ring: writer finished with only %u/%u frames\n", seen, TOTAL_FRAMES);
            ordered = 0;
            break;
        }
        if (!got) sched_yield();
    }
    atomic_store_explicit(&stop_writer, 1, memory_order_relaxed);
    int joined = pthread_join(t, NULL);
    CHECK(joined == 0);
    if (joined) return 1;
    alarm(0);
    CHECK(ordered && writer_complete && seen == TOTAL_FRAMES && shared.frames_out == TOTAL_FRAMES &&
          shared.read == (uint64_t)TOTAL_FRAMES * 4 && shared.written == shared.read);
    s2a_pcm_ring_free(&shared);

    if (failures) return 1;
    puts("pcm ring: ok");
    return 0;
}
