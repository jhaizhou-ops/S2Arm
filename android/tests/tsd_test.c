#include "tsd.h"
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static int failures;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static uint8_t tls[0x4100];
static const uint64_t magic = 0x5332415f4b455931ull;

static void put(size_t off, uint64_t v) { memcpy(tls + off, &v, sizeof v); }

// Lays out a fake bionic_tls: {seq, data} for `key` at table_off + 16 * index.
static void plant(uint64_t table_off, uint32_t key, uint64_t seq) {
    memset(tls, 0, sizeof tls);
    uint64_t slot = s2a_bionic_slot_off(table_off, key);
    put(slot - 8, seq);
    put(slot, magic);
}

int main(void) {
    // Valid bionic keys carry bit 31 and must not sign-extend into the index.
    CHECK(s2a_bionic_key_index(0x80000018u) == 0x18);
    CHECK(s2a_bionic_key_index((uint32_t)(int32_t)-2147483642) == 6);
    CHECK(s2a_bionic_slot_off(0, 0x80000018u) == 0x188);
    CHECK(s2a_bionic_slot_off(0x40, 3) == 0x78);

    uint64_t off = 1;
    plant(0, 0x80000018u, 3);   // measured on Android 15 / 17 (xbl-android)
    CHECK(s2a_bionic_find_table(tls, 0x4000, 0x80000018u, magic, &off) == 0 && off == 0);
    plant(0x40, 0x80000005u, 0x2b);
    CHECK(s2a_bionic_find_table(tls, 0x4000, 0x80000005u, magic, &off) == 0 && off == 0x40);

    // Wrong key / layout: the value sits before the key's own entry, or seq is not in use.
    CHECK(s2a_bionic_find_table(tls, 0x4000, 0x80000010u, magic, &off) == EPROTO);
    plant(0x40, 0x80000005u, 2);
    CHECK(s2a_bionic_find_table(tls, 0x4000, 0x80000005u, magic, &off) == EPROTO);

    // Absent, ambiguous, and the scan limit.
    memset(tls, 0, sizeof tls);
    CHECK(s2a_bionic_find_table(tls, 0x4000, 0x80000005u, magic, &off) == ENOENT);
    plant(0x40, 0x80000005u, 1);
    put(0x800, magic);
    CHECK(s2a_bionic_find_table(tls, 0x4000, 0x80000005u, magic, &off) == EEXIST);
    memset(tls, 0, sizeof tls);
    put(0x4000 - 16, 1); put(0x4000 - 8, magic);
    CHECK(s2a_bionic_find_table(tls, 0x4000, 0x80000000u | 0x3fd, magic, &off) == 0 && off == 0x4000 - 8 - 0x3fd * 16 - 8);
    memset(tls, 0, sizeof tls);
    put(0x4000 - 8, 1); put(0x4000, magic);
    CHECK(s2a_bionic_find_table(tls, 0x4000, 0x80000000u, magic, &off) == ENOENT);

    CHECK(s2a_bionic_find_table(NULL, 0x4000, 0, magic, &off) == EINVAL);
    CHECK(s2a_bionic_find_table(tls, 0x4000, 0, magic, NULL) == EINVAL);
    CHECK(s2a_bionic_find_table(tls, 0x4000, 0, 0, &off) == EINVAL);

    // The scan limit follows the readable end of the containing mapping.
    size_t pg = (size_t)sysconf(_SC_PAGESIZE);
    uint8_t *m = mmap(NULL, 3 * pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(m != MAP_FAILED);
    if (m != MAP_FAILED) {
        CHECK(mprotect(m + 2 * pg, pg, PROT_NONE) == 0);
        CHECK(s2a_readable_span(m, 0x100000) == 2 * pg);
        CHECK(s2a_readable_span(m + pg + 8, 0x100000) == pg - 8);
        CHECK(s2a_readable_span(m, 16) == 16);
        CHECK(s2a_readable_span(m + 2 * pg, 0x100000) == 0);
        munmap(m, 3 * pg);
    }

    if (failures) return 1;
    puts("bionic key table helpers: ok");
    return 0;
}
