#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Bionic pthread key slots: the Android counterpart of Apple's tpidrro_el0 TSD,
// matching runtime/rewriter S2A_TARGET=android. Slot of key k =
// bionic_tls + table offset + 16 * index(k) + 8 (pthread_key_data_t = {seq, data}).
// The table offset is bionic-internal, so it is measured, never assumed.

// Bionic keys are int with KEY_VALID_FLAG (bit 31); pass them through uint32_t
// so they do not sign-extend.
uint64_t s2a_bionic_key_index(uint32_t key);
uint64_t s2a_bionic_slot_off(uint64_t table_off, uint32_t key);

// Finds the key table in a bionic_tls block where `key` was just set to `magic`
// by pthread_setspecific. The value must occur exactly once in [8, limit), at a
// position consistent with the key index, with an in-use (odd) seq beside it.
// Returns 0, ENOENT (not found), EEXIST (ambiguous) or EPROTO (layout mismatch).
int s2a_bionic_find_table(const uint8_t *tls, size_t limit, uint32_t key,
                          uint64_t magic, uint64_t *table_off);

// Bytes readable from p, up to max, by the mapping in /proc/self/maps that
// contains p. bionic_tls sits in its own guarded mapping that can end before
// 16 KB, so scans must stop there. Returns 0 if p is not in a readable mapping.
size_t s2a_readable_span(const void *p, size_t max);

#if defined(__ANDROID__) && defined(__aarch64__)
// tpidr_el0 -> TCB[-1] (TLS_SLOT_BIONIC_TLS) of the calling thread.
uint8_t *s2a_bionic_tls(void);

// Measures the table offset on the calling thread, re-checks it with a second
// key, checks that a direct slot write is what pthread_getspecific returns and
// that another thread's slot is independent. Keys are deleted afterwards.
int s2a_android_tsd_probe(uint64_t *table_off);
#endif

#ifdef __cplusplus
}
#endif
