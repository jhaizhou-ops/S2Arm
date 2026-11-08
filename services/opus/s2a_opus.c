// libopus 解码的极小 C 接口（给 Ryujinx.Horizon 的 HardwareOpusDecoder）：单流 / 多流解码器统一成一个句柄，
// 打开 / 解一包 / 复位 / 关闭，外加包内样本数。opus_*_ctl 是变参函数（arm64 苹果平台变参走栈，P/Invoke 不能直调），复位只能经这里。
// 解码全在 C 侧：每包零托管分配（原先 Concentus 托管实现每包分配 18–36 KB，暗黑3 稳态每秒 40 多包，是 iOS 阻塞式 gen0 回收的主因）。
#include <stdint.h>
#include <stdlib.h>
#include "opus.h"
#include "opus_multistream.h"

typedef struct
{
    OpusDecoder *single;
    OpusMSDecoder *multi;
} s2a_opus;

// mapping == NULL：单流解码器（opus_decoder）；否则多流（opus_multistream_decoder）。失败返回 NULL，*err 为 libopus 错误码
void *s2a_opus_open(int32_t rate, int32_t channels, int32_t streams, int32_t coupled, const uint8_t *mapping, int32_t *err)
{
    s2a_opus *h = calloc(1, sizeof *h);
    int e = OPUS_ALLOC_FAIL;

    if (h != NULL)
    {
        if (mapping == NULL)
        {
            h->single = opus_decoder_create(rate, channels, &e);
        }
        else
        {
            h->multi = opus_multistream_decoder_create(rate, channels, streams, coupled, mapping, &e);
        }

        if (e != OPUS_OK)
        {
            free(h);
            h = NULL;
        }
    }

    *err = e;
    return h;
}

// 返回每声道解出的样本数（≥0），或 libopus 负错误码
int32_t s2a_opus_decode(void *p, const uint8_t *data, int32_t len, int16_t *pcm, int32_t frame_size)
{
    s2a_opus *h = p;

    return h->single != NULL
        ? opus_decode(h->single, data, len, pcm, frame_size, 0)
        : opus_multistream_decode(h->multi, data, len, pcm, frame_size, 0);
}

void s2a_opus_reset(void *p)
{
    s2a_opus *h = p;

    if (h->single != NULL)
    {
        opus_decoder_ctl(h->single, OPUS_RESET_STATE);
    }
    else
    {
        opus_multistream_decoder_ctl(h->multi, OPUS_RESET_STATE);
    }
}

void s2a_opus_close(void *p)
{
    s2a_opus *h = p;

    if (h != NULL)
    {
        opus_decoder_destroy(h->single);
        opus_multistream_decoder_destroy(h->multi);
        free(h);
    }
}

// 包内每声道样本数（按采样率），或 libopus 负错误码（OPUS_BAD_ARG / OPUS_INVALID_PACKET）
int32_t s2a_opus_packet_samples(const uint8_t *data, int32_t len, int32_t rate)
{
    return opus_packet_get_nb_samples(data, len, rate);
}
