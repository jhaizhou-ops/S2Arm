/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 S2Arm contributors
 *
 * Yaz0 decompress. Written from the public layout and the in-tree decoder
 * (graphics/widen/scan/ui_lyt.py yaz0_dec).
 * Not derived from oead, syaz0, roead, sarc, or Switch-Toolbox.
 *
 * Layout: "Yaz0", big-endian uncompressed size at +4, 8 reserved bytes, then
 * groups. Each group is one flag byte and up to 8 items, high bit first.
 * Flag 1: one literal byte. Flag 0: a back-reference.
 *   dist = ((b1 & 0x0F) << 8 | b2) + 1
 *   if (b1 >> 4) == 0: length = next_byte + 0x12
 *   else:              length = (b1 >> 4) + 2
 * Copies are byte by byte so a reference may overlap itself.
 *
 * Returns the uncompressed size, or -1 on error.
 * dst == NULL only reports the size from a valid header.
 */
#include <stdint.h>

int64_t yaz0_decompress(const uint8_t *src, int64_t src_len, uint8_t *dst, int64_t dst_cap) {
    uint32_t n, o, dist, ln, from, k;
    int64_t i;
    int bit;
    uint8_t flags, b1, b2;

    if (!src || src_len < 16) return -1;
    if (src[0] != 'Y' || src[1] != 'a' || src[2] != 'z' || src[3] != '0') return -1;
    n = ((uint32_t)src[4] << 24) | ((uint32_t)src[5] << 16) | ((uint32_t)src[6] << 8) | src[7];
    if ((uint64_t)n > 0x7fffffff) return -1;
    if (!dst) return (int64_t)n;
    if (dst_cap < (int64_t)n) return -1;
    o = 0;
    i = 16;
    while (o < n) {
        if (i >= src_len) return -1;
        flags = src[i++];
        for (bit = 0; bit < 8 && o < n; bit++) {
            if (flags & (uint8_t)(0x80u >> bit)) {
                if (i >= src_len) return -1;
                dst[o++] = src[i++];
            } else {
                if (i + 1 >= src_len) return -1;
                b1 = src[i++];
                b2 = src[i++];
                dist = (((uint32_t)(b1 & 0x0Fu) << 8) | b2) + 1u;
                ln = (uint32_t)(b1 >> 4);
                if (ln == 0) {
                    if (i >= src_len) return -1;
                    ln = (uint32_t)src[i++] + 0x12u;
                } else {
                    ln += 2u;
                }
                if (dist == 0 || dist > o || (uint64_t)o + ln > n) return -1;
                from = o - dist;
                for (k = 0; k < ln; k++) dst[o++] = dst[from + k];
            }
        }
    }
    return (int64_t)n;
}
