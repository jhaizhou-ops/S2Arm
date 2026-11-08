// libvpx VP8 解码的极小 C 接口（给 Ryujinx Nvdec 的 VpxVp8Decoder，C# 侧不用对 vpx_image_t 的结构布局）：
// 打开 / 解一帧并交出三个平面的指针、步长与宽高（指针在下次解码前有效）/ 关闭。
#include <stdint.h>
#include <stdlib.h>
#include "vpx/vpx_decoder.h"
#include "vpx/vp8dx.h"

void *s2a_vp8_open(void)
{
    vpx_codec_ctx_t *c = calloc(1, sizeof *c);

    if (c != NULL && vpx_codec_dec_init(c, vpx_codec_vp8_dx(), NULL, 0) != VPX_CODEC_OK)
    {
        free(c);
        return NULL;
    }

    return c;
}

// 返回 0 = 出了一帧；1 = 解码成功但没有可显示的帧；-1 = 解码失败
int s2a_vp8_decode(void *h, const uint8_t *data, uint32_t len, uint8_t **planes, int32_t *strides, int32_t *wh)
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

    for (int i = 0; i < 3; i++)
    {
        planes[i] = img->planes[i];
        strides[i] = img->stride[i];
    }

    wh[0] = (int32_t)img->d_w;
    wh[1] = (int32_t)img->d_h;
    return 0;
}

void s2a_vp8_close(void *h)
{
    if (h != NULL)
    {
        vpx_codec_destroy(h);
        free(h);
    }
}
