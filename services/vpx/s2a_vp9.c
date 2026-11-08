// libvpx VP9 解码的极小 C 接口（与 s2a_vp8.c 同形：调用方不用对 vpx_image_t 的结构布局）：
// 打开 / 解一帧并交出三个平面的指针、步长、宽高与色彩信息（指针在下次解码前有效）/ 关闭。
// 用方：Switch 2 直连档接管的 nn::codec VP9 解码器（graphics/nvn/gfx/nvn/nvn2_codec.c）；服务层 Nvdec 的 VP9 要改走原生时也调这一套（同源）。
#include <stdint.h>
#include <stdlib.h>
#include "vpx/vpx_decoder.h"
#include "vpx/vp8dx.h"

// threads：libvpx 解码线程数（≤ 1 = 单线程）；多线程时同时开 VP9 行级并行
void *s2a_vp9_open(int threads)
{
    vpx_codec_ctx_t *c = calloc(1, sizeof *c);
    vpx_codec_dec_cfg_t cfg = { 0 };

    cfg.threads = threads > 1 ? (unsigned)threads : 1;
    if (c != NULL && vpx_codec_dec_init(c, vpx_codec_vp9_dx(), &cfg, 0) != VPX_CODEC_OK)
    {
        free(c);
        return NULL;
    }

    if (c != NULL && threads > 1)
    {
        vpx_codec_control(c, VP9D_SET_ROW_MT, 1);
    }

    return c;
}

// 返回 0 = 出了一帧；1 = 解码成功但没有可显示的帧；-1 = 解码失败；-2 = 出了帧但不是 8 位 4:2:0（I420）
// info：[0] 宽 [1] 高 [2] 色彩矩阵（1 = BT.709，0 = BT.601 / 其它已声明，-1 = 未声明）[3] 全范围（1）/ 视频范围（0）
int s2a_vp9_decode(void *h, const uint8_t *data, uint32_t len, uint8_t **planes, int32_t *strides, int32_t *info)
{
    vpx_codec_ctx_t *c = h;

    if (vpx_codec_decode(c, data, len, NULL, 0) != VPX_CODEC_OK)
    {
        return -1;
    }

    vpx_codec_iter_t it = NULL;
    vpx_image_t *img = vpx_codec_get_frame(c, &it);

    if (img == NULL)
    {
        return 1;
    }

    if (img->fmt != VPX_IMG_FMT_I420)
    {
        return -2;
    }

    for (int i = 0; i < 3; i++)
    {
        planes[i] = img->planes[i];
        strides[i] = img->stride[i];
    }

    info[0] = (int32_t)img->d_w;
    info[1] = (int32_t)img->d_h;
    info[2] = img->cs == VPX_CS_BT_709 ? 1 : img->cs == VPX_CS_UNKNOWN ? -1 : 0;
    info[3] = img->range == VPX_CR_FULL_RANGE;
    return 0;
}

void s2a_vp9_close(void *h)
{
    if (h != NULL)
    {
        vpx_codec_destroy(h);
        free(h);
    }
}
