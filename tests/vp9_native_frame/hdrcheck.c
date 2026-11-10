// C side of tests/vp9_native_frame_test.sh: runs android/codecs/vpxbench/hdr.c (design_phase2_B.md §2-§3) over the job
// sequence the C# side generated, with the same native-active / fallback rules as Vp9NativePath, and writes per job:
// u8 status (0 decoded natively, 1 fallback, 2 waiting for a key frame); on 0 also i32 target, u32 length, frame bytes.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "hdr.h"

static uint32_t u32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

int main(int argc, char **argv)
{
    if (argc != 3) return fprintf(stderr, "usage: hdrcheck <in> <out>\n"), 2;
    FILE *in = fopen(argv[1], "rb"), *out = fopen(argv[2], "wb");
    if (!in || !out) return 2;
    static uint8_t frame[1 << 16];
    s2a_slots slots;
    s2a_slots_reset(&slots);
    int active = 0;
    uint8_t rec[256 + 32 + 4];
    while (fread(rec, 1, sizeof rec, in) == sizeof rec)
    {
        uint32_t n = u32(rec + 288);
        uint8_t *tiles = malloc(n ? n : 1);
        if (fread(tiles, 1, n, in) != n) return 2;
        s2a_pic p;
        s2a_surfaces sf;
        s2a_pic_parse(rec, &p);
        for (int i = 0; i < 4; i++)
        {
            sf.luma[i] = u32(rec + 256 + 8 * i);
            sf.chroma[i] = u32(rec + 260 + 8 * i);
        }
        const int key = (p.flags & S2A_KEY) != 0;
        uint8_t status;
        if (!active && !key)
            status = 2;
        else
        {
            if (!active)
            {
                active = 1;
                s2a_slots_reset(&slots);
            }
            int target = 0;
            size_t len = 0;
            if (s2a_build_frame(&p, &sf, &slots, tiles, n, frame, sizeof frame, &len, &target) == NULL)
            {
                status = 0;
                if (key) target = -1;
                s2a_slots_commit(&slots, &p, &sf, target);
                int32_t t = target;
                uint32_t l = (uint32_t)len;
                fwrite(&status, 1, 1, out);
                fwrite(&t, 4, 1, out);
                fwrite(&l, 4, 1, out);
                fwrite(frame, 1, len, out);
                free(tiles);
                continue;
            }
            status = 1;
            active = 0;
            s2a_slots_reset(&slots);
        }
        fwrite(&status, 1, 1, out);
        free(tiles);
    }
    fclose(out);
    return 0;
}
