#ifndef S2A_MAC_RUMBLE_SESSION_H
#define S2A_MAC_RUMBLE_SESSION_H
#include <stdatomic.h>
#include <stdint.h>

static inline uint64_t s2a_mac_rumble_claim_epoch(_Atomic uint64_t *epoch, _Atomic uint64_t *counter, int has_pro, int off) {
    if (off) return 0;
    uint64_t e = atomic_load_explicit(epoch, memory_order_relaxed);
    if (!e && has_pro) {
        uint64_t next = atomic_fetch_add_explicit(counter, 1, memory_order_relaxed) + 1;
        uint64_t expected = 0;
        atomic_compare_exchange_strong_explicit(epoch, &expected, next, memory_order_release, memory_order_relaxed);
        e = atomic_load_explicit(epoch, memory_order_relaxed);
    }
    return e;
}

#endif
