#include "native.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../native/runtime/platform/layout_android.inc"

int main(int argc, char **argv) {
    assert(argc == 6);
    const char *why = NULL;
    s2a_layout_requirements r;
    s2a_layout l;
    char note[256];
    assert(s2a_android_layout_requirements_read(argv[1], 0x0100000000abcdefull, &r, &why) == 0);
    assert(!s2a_android_layout_split(&r, 0, &why, note, sizeof note));
    if (atoi(argv[5])) {
        s2a_layout_requirements too_large = r;
        too_large.heap_size = 5ull << 30;
        assert(s2a_android_layout_split(&too_large, 0, &why, note, sizeof note) == -1);
        assert(too_large.heap_size == 5ull << 30); // 超预算不悄悄截堆
        assert(s2a_android_layout_compute(3, 16ull << 20, &r, 0x6000000000ull, 64ull << 30, &l) == -2);
    }
    assert(!s2a_android_layout_compute(3, 16ull << 20, &r, 0x6000000000ull, 68ull << 30, &l));
    const uint64_t gb = 1ull << 30;
    uint64_t start = (l.alias_base + 0x3fe00000ull + (gb | 0xfff)) & ~(gb - 1);
    int fits = start + 62 * gb <= l.alias_base + l.alias_size - 0x1000;
    printf("pack layout: alias=%uGiB heap=%lluMiB SDK62fit=%d\n", r.alias_gb, (unsigned long long)(l.heap_size >> 20), fits);
    assert(r.alias_gb == (unsigned)atoi(argv[2]));
    assert((l.heap_size >> 20) == strtoull(argv[3], NULL, 10));
    assert(fits == atoi(argv[4]));
    return 0;
}
