// Decodes an IVF (VP8 or VP9) with libvpx's public API and prints one FNV-1a-64 per output frame over the visible I420 rows.
// tests/vpx_patch_identity_test.sh links it against the patched and the unpatched libvpx and compares the two outputs.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vpx/vp8dx.h"
#include "vpx/vpx_decoder.h"

static uint64_t fnv(uint64_t h, const uint8_t *p, size_t n)
{
    while (n--) h = (h ^ *p++) * 0x100000001b3ULL;
    return h;
}

int main(int argc, char **argv)
{
    if (argc != 3) return fprintf(stderr, "usage: hashdec <file.ivf> <threads>\n"), 2;
    FILE *f = fopen(argv[1], "rb");
    uint8_t hdr[32];
    if (f == NULL || fread(hdr, 1, 32, f) != 32 || memcmp(hdr, "DKIF", 4) != 0) return fprintf(stderr, "%s: not IVF\n", argv[1]), 2;
    const int vp8 = memcmp(hdr + 8, "VP80", 4) == 0;
    vpx_codec_ctx_t c;
    vpx_codec_dec_cfg_t cfg = { 0 };
    cfg.threads = (unsigned)atoi(argv[2]);
    if (vpx_codec_dec_init(&c, vp8 ? vpx_codec_vp8_dx() : vpx_codec_vp9_dx(), &cfg, 0)) return 1;
    if (!vp8 && cfg.threads > 1) vpx_codec_control(&c, VP9D_SET_ROW_MT, 1);
    fseek(f, hdr[6] | hdr[7] << 8, SEEK_SET);
    uint8_t fh[12], *buf = NULL;
    size_t cap = 0;
    long packet = 0, errors = 0;
    while (fread(fh, 1, 12, f) == 12)
    {
        uint32_t len = fh[0] | fh[1] << 8 | fh[2] << 16 | (uint32_t)fh[3] << 24;
        if (len > cap)
        {
            cap = len;
            buf = realloc(buf, cap);
        }
        if (fread(buf, 1, len, f) != len) break;
        if (vpx_codec_decode(&c, buf, len, NULL, 0))
        {
            errors++;
            printf("%ld error\n", packet);
        }
        vpx_codec_iter_t it = NULL;
        vpx_image_t *img;
        while ((img = vpx_codec_get_frame(&c, &it)) != NULL)
        {
            uint64_t h = 0xcbf29ce484222325ULL;
            for (int p = 0; p < 3; p++)
            {
                const unsigned w = p ? (img->d_w + 1) >> 1 : img->d_w, ht = p ? (img->d_h + 1) >> 1 : img->d_h;
                for (unsigned y = 0; y < ht; y++) h = fnv(h, img->planes[p] + (size_t)y * (size_t)img->stride[p], w);
            }
            printf("%ld %ux%u %016llx\n", packet, img->d_w, img->d_h, (unsigned long long)h);
        }
        packet++;
    }
    vpx_codec_destroy(&c);
    free(buf);
    fclose(f);
    return errors ? 1 : 0;
}
