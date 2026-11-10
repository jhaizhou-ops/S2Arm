// Encodes resize.ivf for tests/data/vp9_synth: a procedural pattern at 640x360 for 16 frames, then 480x272 for 16 frames
// without a key frame (vpx_codec_enc_config_set, the pattern of libvpx's test/resize_test.cc), so inter frames after the
// change use scaled references. One pass, no lag (libvpx refuses a size change with g_lag_in_frames > 1).
// Build (make.sh does it): cc resize_enc.c -I<libvpx src> -I<libvpx build> <libvpx build>/libvpx.a -lm
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vpx/vp8cx.h"
#include "vpx/vpx_encoder.h"

static void le16(uint8_t *p, unsigned v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void le32(uint8_t *p, uint32_t v) { le16(p, v & 0xffff); le16(p + 2, v >> 16); }

static void fill(vpx_image_t *img, int t)
{
    for (unsigned y = 0; y < img->d_h; y++)
        for (unsigned x = 0; x < img->d_w; x++)
        {
            int v = (int)((x * 3 + y * 2 + (unsigned)t * 7) & 0xff);
            if (((x + (unsigned)t * 5) / 40 + y / 40) % 2) v = 255 - v;
            img->planes[0][y * img->stride[0] + x] = (uint8_t)v;
        }
    for (unsigned y = 0; y < (img->d_h + 1) / 2; y++)
        for (unsigned x = 0; x < (img->d_w + 1) / 2; x++)
        {
            img->planes[1][y * img->stride[1] + x] = (uint8_t)(128 + ((x + (unsigned)t) & 63) - 32);
            img->planes[2][y * img->stride[2] + x] = (uint8_t)(128 + ((y + (unsigned)t * 2) & 63) - 32);
        }
}

int main(int argc, char **argv)
{
    if (argc != 2) return fprintf(stderr, "usage: resize_enc out.ivf\n"), 2;
    FILE *out = fopen(argv[1], "wb");
    vpx_codec_enc_cfg_t cfg;
    vpx_codec_ctx_t enc;
    if (!out || vpx_codec_enc_config_default(vpx_codec_vp9_cx(), &cfg, 0)) return 1;
    cfg.g_w = 640;
    cfg.g_h = 360;
    cfg.g_timebase.num = 1;
    cfg.g_timebase.den = 30;
    cfg.rc_target_bitrate = 400;
    cfg.g_lag_in_frames = 0;
    cfg.g_error_resilient = 0;
    cfg.kf_mode = VPX_KF_DISABLED;
    if (vpx_codec_enc_init(&enc, vpx_codec_vp9_cx(), &cfg, 0)) return 1;
    vpx_codec_control(&enc, VP9E_SET_FRAME_PARALLEL_DECODING, 0);
    vpx_codec_control(&enc, VP8E_SET_CPUUSED, 4);
    uint8_t hdr[32] = { 'D', 'K', 'I', 'F' };
    le16(hdr + 6, 32);
    memcpy(hdr + 8, "VP90", 4);
    le16(hdr + 12, 640);
    le16(hdr + 14, 360);
    le32(hdr + 16, 30);
    le32(hdr + 20, 1);
    fwrite(hdr, 1, 32, out);
    uint32_t frames = 0;
    for (int t = 0; t <= 32; t++)
    {
        vpx_image_t *img = NULL;
        if (t == 16)
        {
            cfg.g_w = 480;
            cfg.g_h = 272;
            if (vpx_codec_enc_config_set(&enc, &cfg)) return fprintf(stderr, "resize refused: %s\n", vpx_codec_error_detail(&enc)), 1;
        }
        if (t < 32)
        {
            img = vpx_img_alloc(NULL, VPX_IMG_FMT_I420, cfg.g_w, cfg.g_h, 16);
            fill(img, t);
        }
        if (vpx_codec_encode(&enc, img, t, 1, 0, VPX_DL_GOOD_QUALITY)) return fprintf(stderr, "encode failed\n"), 1;
        vpx_img_free(img);
        vpx_codec_iter_t it = NULL;
        const vpx_codec_cx_pkt_t *pkt;
        while ((pkt = vpx_codec_get_cx_data(&enc, &it)))
        {
            if (pkt->kind != VPX_CODEC_CX_FRAME_PKT) continue;
            uint8_t fh[12];
            le32(fh, (uint32_t)pkt->data.frame.sz);
            le32(fh + 4, (uint32_t)pkt->data.frame.pts);
            le32(fh + 8, 0);
            fwrite(fh, 1, 12, out);
            fwrite(pkt->data.frame.buf, 1, pkt->data.frame.sz, out);
            frames++;
        }
    }
    le32(hdr + 24, frames);
    fseek(out, 0, SEEK_SET);
    fwrite(hdr, 1, 32, out);
    fclose(out);
    vpx_codec_destroy(&enc);
    printf("resize.ivf: %u packets\n", frames);
    return 0;
}
