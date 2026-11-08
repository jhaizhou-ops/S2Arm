// 服务层单测专用的 libopus 编码垫片（只进 Mac 动态库 libs2a_opus.dylib，不进宿主 / App 静态库）：
// 单测用参考编码器出测试包，要按用例定应用类型 / 码率 / 带宽 / 复杂度 / 带内纠错，这些设置都走 opus_*_encoder_ctl，
// 而 ctl 是变参函数（arm64 苹果平台变参走栈，P/Invoke 不能直调），所以经这里转一道。单流 / 多流统一成一个句柄。
#include <stdint.h>
#include <stdlib.h>
#include "opus.h"
#include "opus_multistream.h"

typedef struct
{
    OpusEncoder *single;
    OpusMSEncoder *multi;
} s2at_handle;

// mapping == NULL：单流编码器；否则多流。bitrate / bandwidth 传 OPUS_AUTO（-1000）表示不设；失败返回 NULL，*err 为 libopus 错误码
void *s2at_enc_open(int32_t rate, int32_t channels, int32_t streams, int32_t coupled, const uint8_t *mapping, int32_t application,
    int32_t bitrate, int32_t bandwidth, int32_t complexity, int32_t fec, int32_t *err)
{
    s2at_handle *h = calloc(1, sizeof *h);
    int e = OPUS_ALLOC_FAIL;

    if (h != NULL)
    {
        if (mapping == NULL)
        {
            h->single = opus_encoder_create(rate, channels, application, &e);
        }
        else
        {
            h->multi = opus_multistream_encoder_create(rate, channels, streams, coupled, mapping, application, &e);
        }

        if (e != OPUS_OK)
        {
            free(h);
            h = NULL;
        }
    }

    if (h != NULL)
    {
        // 单流 / 多流的 ctl 请求号相同，按句柄类型分派
#define S2AT_CTL(req) (h->single != NULL ? opus_encoder_ctl(h->single, req) : opus_multistream_encoder_ctl(h->multi, req))
        S2AT_CTL(OPUS_SET_COMPLEXITY(complexity));
        S2AT_CTL(OPUS_SET_INBAND_FEC(fec));
        S2AT_CTL(OPUS_SET_PACKET_LOSS_PERC(fec ? 10 : 0));

        if (bitrate != OPUS_AUTO)
        {
            S2AT_CTL(OPUS_SET_BITRATE(bitrate));
        }

        if (bandwidth != OPUS_AUTO)
        {
            S2AT_CTL(OPUS_SET_BANDWIDTH(bandwidth));
        }
#undef S2AT_CTL
    }

    *err = e;
    return h;
}

// 返回包长（字节），或 libopus 负错误码
int32_t s2at_enc(void *p, const int16_t *pcm, int32_t frame_size, uint8_t *data, int32_t max_bytes)
{
    s2at_handle *h = p;

    return h->single != NULL
        ? opus_encode(h->single, pcm, frame_size, data, max_bytes)
        : opus_multistream_encode(h->multi, pcm, frame_size, data, max_bytes);
}

void s2at_enc_close(void *p)
{
    s2at_handle *h = p;

    if (h != NULL)
    {
        opus_encoder_destroy(h->single);
        opus_multistream_encoder_destroy(h->multi);
        free(h);
    }
}
