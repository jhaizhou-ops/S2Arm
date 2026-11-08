#include "tsd.h"
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

uint64_t s2a_bionic_key_index(uint32_t key) { return key & 0x7fffffffu; }

uint64_t s2a_bionic_slot_off(uint64_t table_off, uint32_t key) {
    return table_off + s2a_bionic_key_index(key) * 16 + 8;
}

static uint64_t word(const uint8_t *p) { uint64_t v; memcpy(&v, p, sizeof v); return v; }

int s2a_bionic_find_table(const uint8_t *tls, size_t limit, uint32_t key,
                          uint64_t magic, uint64_t *table_off) {
    if (!tls || !table_off || !magic) return EINVAL;
    uint64_t at = 0;
    for (size_t o = 8; o + 8 <= limit; o += 8) {
        if (word(tls + o) != magic) continue;
        if (at) return EEXIST;
        at = o;
    }
    if (!at) return ENOENT;
    uint64_t rel = s2a_bionic_key_index(key) * 16 + 8;
    // pthread_setspecific stamps the key's in-use seq, which is odd.
    if (at < rel || !(word(tls + at - 8) & 1)) return EPROTO;
    *table_off = at - rel;
    return 0;
}

size_t s2a_readable_span(const void *p, size_t max) {
    FILE *f = fopen("/proc/self/maps", "re");
    if (!f) return 0;
    uintptr_t at = (uintptr_t)p, lo, hi;
    char perms[8], line[512];
    size_t span = 0;
    while (fgets(line, sizeof line, f)) {
        if (sscanf(line, "%" SCNxPTR "-%" SCNxPTR " %7s", &lo, &hi, perms) != 3) continue;
        if (at < lo || at >= hi) continue;
        if (perms[0] == 'r') span = hi - at < max ? hi - at : max;
        break;
    }
    fclose(f);
    return span;
}

#if defined(__ANDROID__) && defined(__aarch64__)
#include <pthread.h>

#define PROBE_LIMIT 0x4000

uint8_t *s2a_bionic_tls(void) {
    uint64_t tp;
    __asm__ volatile("mrs %0, tpidr_el0" : "=r"(tp));
    return ((uint8_t **)tp)[-1];
}

struct peer {
    pthread_key_t key;
    uint64_t table_off;
    uint8_t *tls;
    int error;
};

static void *peer_main(void *arg) {
    struct peer *p = arg;
    void *const magic = (void *)0x5032415f50454552ull;
    p->tls = s2a_bionic_tls();
    p->error = pthread_setspecific(p->key, magic);
    if (!p->error && word(p->tls + s2a_bionic_slot_off(p->table_off, (uint32_t)p->key)) != (uint64_t)(uintptr_t)magic)
        p->error = EPROTO;
    pthread_setspecific(p->key, NULL);
    return NULL;
}

static int probe(pthread_key_t k1, pthread_key_t k2, uint64_t *table_off) {
    void *const magic1 = (void *)0x5332415f4b455931ull, *const magic2 = (void *)0x5332415f4b455932ull;
    void *const direct = (void *)0x5332415f44495245ull;
    uint8_t *tls = s2a_bionic_tls();
    size_t limit = s2a_readable_span(tls, PROBE_LIMIT);
    int error = pthread_setspecific(k1, magic1);
    if (!error) error = s2a_bionic_find_table(tls, limit, (uint32_t)k1, (uint64_t)(uintptr_t)magic1, table_off);
    if (error) return error;
    if ((error = pthread_setspecific(k2, magic2))) return error;
    uint8_t *slot2 = tls + s2a_bionic_slot_off(*table_off, (uint32_t)k2);
    if (word(slot2) != (uint64_t)(uintptr_t)magic2) return EPROTO;
    // Rewritten guest code stores to the slot directly; host code must read it back.
    uint64_t v = (uint64_t)(uintptr_t)direct;
    memcpy(slot2, &v, sizeof v);
    if (pthread_getspecific(k2) != direct) return EPROTO;
    struct peer p = {k1, *table_off, NULL, 0};
    pthread_t thread;
    if ((error = pthread_create(&thread, NULL, peer_main, &p))) return error;
    pthread_join(thread, NULL);
    if (p.error) return p.error;
    if (p.tls == tls || pthread_getspecific(k1) != magic1) return EPROTO;
    return 0;
}

int s2a_android_tsd_probe(uint64_t *table_off) {
    if (!table_off) return EINVAL;
    pthread_key_t k1, k2;
    int error = pthread_key_create(&k1, NULL);
    if (error) return error;
    if ((error = pthread_key_create(&k2, NULL))) { pthread_key_delete(k1); return error; }
    error = probe(k1, k2, table_off);
    pthread_setspecific(k1, NULL);
    pthread_setspecific(k2, NULL);
    pthread_key_delete(k2);
    pthread_key_delete(k1);
    return error;
}
#endif
