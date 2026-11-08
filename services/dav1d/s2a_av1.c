// dav1d AV1 解码的极小 C 接口（与 services/vpx/s2a_vp9.c 同形：调用方不用对 Dav1dPicture 的结构布局）：
// 打开 / 送一个时间单元并交出（至多）一帧的三个平面指针、步长、宽高与色彩信息（指针在下次解码 / 关闭前有效）/ 关闭。
// 用方：Switch 2 直连档接管的 nn::codec AV1 解码器在 VideoToolbox 不支持 AV1 时（graphics/nvn/gfx/nvn/nvn2_codec.c）。
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "dav1d/dav1d.h"

typedef struct
{
    Dav1dContext *c;
    Dav1dPicture pic;
    int has_pic;
} s2a_av1;

// threads：dav1d 线程数（0 = 按核数）；最大帧延迟 1：送一个时间单元就出它的帧（游戏按包取帧，不能攒）
void *s2a_av1_open(int threads)
{
    s2a_av1 *h = calloc(1, sizeof *h);
    Dav1dSettings s;

    if (h == NULL)
    {
        return NULL;
    }

    dav1d_default_settings(&s);
    s.n_threads = threads > 0 ? threads : 0;
    s.max_frame_delay = 1;
    if (dav1d_open(&h->c, &s) < 0)
    {
        free(h);
        return NULL;
    }

    return h;
}

// 返回 0 = 出了一帧；1 = 送进去了但没有可显示的帧；-1 = 解码失败
// info：[0] 宽 [1] 高 [2] 每分量位数（8 / 10 / 12）[3] 色度布局（0 单色 1 4:2:0 2 4:2:2 3 4:4:4）[4] 色彩矩阵（1 = BT.709，0 = 其它已声明，-1 = 未声明）[5] 全范围（1）/ 视频范围（0）
int s2a_av1_decode(void *hv, const uint8_t *data, uint32_t len, uint8_t **planes, int32_t *strides, int32_t *info)
{
    s2a_av1 *h = hv;
    Dav1dData d = { 0 };
    int got = 0;

    if (h->has_pic)
    {
        dav1d_picture_unref(&h->pic);
        h->has_pic = 0;
    }

    uint8_t *buf = dav1d_data_create(&d, len);

    if (buf == NULL)
    {
        return -1;
    }

    memcpy(buf, data, len);
    while (d.sz > 0)
    {
        int r = dav1d_send_data(h->c, &d);

        if (r < 0 && r != DAV1D_ERR(EAGAIN))
        {
            dav1d_data_unref(&d);
            return -1;
        }

        // 送不进（EAGAIN）先取帧；取到的第一帧留给调用方，其余（最大帧延迟 1 时不会有）丢掉
        Dav1dPicture p = { 0 };
        int g = dav1d_get_picture(h->c, &p);

        if (g == 0)
        {
            if (!got)
            {
                h->pic = p;
                h->has_pic = got = 1;
            }
            else
            {
                dav1d_picture_unref(&p);
            }
        }
        else if (g < 0 && g != DAV1D_ERR(EAGAIN))
        {
            dav1d_data_unref(&d);
            return -1;
        }
        else if (r == DAV1D_ERR(EAGAIN))
        {
            // 送不进又没帧可取：解码器卡住，按失败报
            dav1d_data_unref(&d);
            return -1;
        }
    }

    if (!got)
    {
        Dav1dPicture p = { 0 };
        int g = dav1d_get_picture(h->c, &p);

        if (g == 0)
        {
            h->pic = p;
            h->has_pic = got = 1;
        }
        else if (g < 0 && g != DAV1D_ERR(EAGAIN))
        {
            return -1;
        }
    }

    if (!got)
    {
        return 1;
    }

    const Dav1dPicture *p = &h->pic;

    for (int i = 0; i < 3; i++)
    {
        planes[i] = p->data[i];
        strides[i] = (int32_t)p->stride[i ? 1 : 0];
    }

    info[0] = p->p.w;
    info[1] = p->p.h;
    info[2] = p->p.bpc;
    info[3] = (int32_t)p->p.layout;
    info[4] = p->seq_hdr == NULL || p->seq_hdr->mtrx == DAV1D_MC_UNKNOWN ? -1 : p->seq_hdr->mtrx == DAV1D_MC_BT709 ? 1 : 0;
    info[5] = p->seq_hdr != NULL && p->seq_hdr->color_range;
    return 0;
}

void s2a_av1_close(void *hv)
{
    s2a_av1 *h = hv;

    if (h == NULL)
    {
        return;
    }

    if (h->has_pic)
    {
        dav1d_picture_unref(&h->pic);
    }

    dav1d_close(&h->c);
    free(h);
}
