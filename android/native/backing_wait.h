#pragma once
#include <stdint.h>
#include <time.h>

// Internal native authority. Every call is serialized with the shell lifecycle
// by the WSI lease mutex. No I/O, allocation, callbacks or waits under that lock.
enum { S2A_BACKING_CONTINUE, S2A_BACKING_IDLE, S2A_BACKING_TOTAL, S2A_BACKING_REVOKED };
enum { S2A_BACKING_IDLE_MS = 3000, S2A_BACKING_TOTAL_MS = 30000,
       S2A_BACKING_GRACE_MS = 250, S2A_BACKING_ADMISSION_MARGIN_MS = 1000 };
typedef struct {
    uint64_t owner, generation, start, progress;
    unsigned writer;
    int active;
} s2a_backing_wait;

static inline uint64_t s2a_backing_now(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) __builtin_trap();
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
static inline void s2a_backing_resumed(s2a_backing_wait *b) {
    b->start = b->progress = s2a_backing_now();
}
static inline uint64_t s2a_backing_deadline(const s2a_backing_wait *b, int foreground, int margin_ms) {
    if (!foreground) return UINT64_MAX;
    uint64_t idle = b->progress + (uint64_t)(S2A_BACKING_IDLE_MS + margin_ms) * 1000000ull;
    uint64_t cap = b->start + (uint64_t)(S2A_BACKING_TOTAL_MS + margin_ms) * 1000000ull;
    return idle < cap ? idle : cap;
}
static inline uint64_t s2a_backing_publish(s2a_backing_wait *b, unsigned writer, uint64_t owner, int advance, int foreground) {
    if (!writer || (owner ? !b->active || owner != b->owner || writer != b->writer
                                   : !advance || (b->active && writer == b->writer))) return 0;
    if (!owner) {
        owner = ++b->generation; if (!owner) owner = ++b->generation;
        b->owner = owner; b->writer = writer;
        s2a_backing_resumed(b);
    } else if (advance) {
        uint64_t now = s2a_backing_now();
        // A report arriving after admission has already expired cannot revive it.
        if (!foreground || now < s2a_backing_deadline(b, foreground, S2A_BACKING_ADMISSION_MARGIN_MS)) b->progress = now;
    }
    b->active = !!advance;
    // Close retains the epoch's native budget, without publishing new progress.
    return owner;
}
static inline int s2a_backing_decision(const s2a_backing_wait *b, uint64_t owner, int foreground) {
    if (!owner || owner != b->owner || !b->active) return S2A_BACKING_REVOKED;
    if (!foreground) return S2A_BACKING_CONTINUE;
    uint64_t now = s2a_backing_now();
    if (now >= b->start + (uint64_t)(S2A_BACKING_TOTAL_MS + S2A_BACKING_GRACE_MS) * 1000000ull) return S2A_BACKING_TOTAL;
    if (now >= b->progress + (uint64_t)(S2A_BACKING_IDLE_MS + S2A_BACKING_GRACE_MS) * 1000000ull) return S2A_BACKING_IDLE;
    return S2A_BACKING_CONTINUE;
}
