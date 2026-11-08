// Controlled host boundary only; executes the production authority, never a C# timer.
// Layout: original 16-word handshake header + the native authority. Tests only.
#pragma once
#include "backing_wait.h"
#include <stdatomic.h>
#include <sched.h>
#include <string.h>
static inline void backing_test_lock(uint64_t *v) {
    while (atomic_exchange((_Atomic uint64_t *)&v[9], 1)) sched_yield();
}
static inline void backing_test_unlock(uint64_t *v) { atomic_store((_Atomic uint64_t *)&v[9], 0); }
static inline s2a_backing_wait *backing_test_state(uint64_t *v) { return (s2a_backing_wait *)&v[16]; }
static inline void backing_test_init(uint64_t *v) {
    if (!v[15]) {
        s2a_backing_wait *b = backing_test_state(v);
        memset(b, 0, sizeof *b);
        if (v[0]) s2a_backing_publish(b, 1, 0, 1, v[3]);
        v[15] = 1;
    }
}
static inline uint64_t backing_test_publish(uint64_t *v, uint64_t owner, int advance) {
    backing_test_lock(v); backing_test_init(v);
    uint64_t result = s2a_backing_publish(backing_test_state(v), 1, owner, advance, v[3]);
    if (result) { v[1] = advance ? 3000 : 0; v[2] = advance ? 30000 : 0; ++v[0]; }
    backing_test_unlock(v); return result;
}
static inline void backing_test_lifecycle(uint64_t *v, int foreground) {
    backing_test_lock(v); backing_test_init(v);
    if (!!v[3] != !!foreground) {
        if (foreground) s2a_backing_resumed(backing_test_state(v));
        v[3] = !!foreground; ++v[4];
    }
    backing_test_unlock(v);
}
static inline int backing_test_decision(uint64_t *v, uint64_t owner) {
    backing_test_lock(v); backing_test_init(v);
    int result = s2a_backing_decision(backing_test_state(v), owner, v[3]);
    backing_test_unlock(v); return result;
}
static inline int backing_test_admission(uint64_t *v, uint64_t *deadline) {
    backing_test_lock(v); backing_test_init(v);
    s2a_backing_wait *b = backing_test_state(v);
    int found = !!b->owner;
    if (found) *deadline = s2a_backing_deadline(b, v[3], S2A_BACKING_ADMISSION_MARGIN_MS);
    backing_test_unlock(v); return found;
}
