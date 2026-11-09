// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors

// 系统 Opus 解码（AudioToolbox AudioConverter）的 C 垫片，只给 48 kHz 单/双声道单流用。
// AudioConverter 默认会做 120 帧预卷（首包只出 840 帧）且输入 ASBD 的 mFramesPerPacket 固定时
// 短包解不出；PrimeInfo={0,0} + mFramesPerPacket=0 后逐包一进一出、帧数与 libopus 一致。
// 坏包在调用方（s2a_opus.c）先用 opus_packet_parse 校验：系统解码器对坏包会静默返回 0 帧。
#include "s2a_opus_apple.h"

#include <AudioToolbox/AudioToolbox.h>
#include <stdlib.h>

#include "opus_defines.h"

typedef struct
{
    AudioConverterRef converter;
    int32_t channels;
} s2a_apple;

typedef struct
{
    const uint8_t *data;
    int32_t length;
    int32_t frames;
    int32_t channels;
    int served;
} s2a_apple_feed;

static OSStatus s2a_apple_feed_cb(AudioConverterRef converter, UInt32 *ioNumberDataPackets,
                                  AudioBufferList *ioData, AudioStreamPacketDescription **outDataPacketDescription,
                                  void *userData)
{
    (void)converter;

    s2a_apple_feed *feed = userData;

    if (feed->served)
    {
        *ioNumberDataPackets = 0;
        return noErr;
    }

    if (outDataPacketDescription != NULL)
    {
        static AudioStreamPacketDescription packet;

        packet.mStartOffset = 0;
        packet.mVariableFramesInPacket = feed->frames;
        packet.mDataByteSize = feed->length;
        *outDataPacketDescription = &packet;
    }

    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = (UInt32)feed->channels;
    ioData->mBuffers[0].mDataByteSize = (UInt32)feed->length;
    ioData->mBuffers[0].mData = (void *)feed->data;
    *ioNumberDataPackets = 1;
    feed->served = 1;

    return noErr;
}

void *s2a_apple_open(int32_t rate, int32_t channels, int32_t *err)
{
    AudioStreamBasicDescription input = {0};
    AudioStreamBasicDescription output = {0};

    input.mSampleRate = rate;
    input.mFormatID = kAudioFormatOpus;
    input.mChannelsPerFrame = (UInt32)channels;
    input.mFramesPerPacket = 0;

    output.mSampleRate = rate;
    output.mFormatID = kAudioFormatLinearPCM;
    output.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
    output.mBytesPerPacket = (UInt32)channels * sizeof(int16_t);
    output.mFramesPerPacket = 1;
    output.mBytesPerFrame = (UInt32)channels * sizeof(int16_t);
    output.mChannelsPerFrame = (UInt32)channels;
    output.mBitsPerChannel = 16;

    AudioConverterRef converter = NULL;
    OSStatus status = AudioConverterNew(&input, &output, &converter);

    if (status == noErr)
    {
        // 只设 PrimeInfo：kAudioConverterPrimeMethod 在 Opus 解码链上会返回错误（实测），默认方法 + lead=0 已足够；
        // 不关掉预卷时首包只出 840 帧，hwopus 的 outSamples 会与包内样本数对不上
        AudioConverterPrimeInfo primeInfo = {0, 0};

        if (AudioConverterSetProperty(converter, kAudioConverterPrimeInfo, sizeof primeInfo, &primeInfo) != noErr)
        {
            AudioConverterDispose(converter);
            converter = NULL;
        }
    }

    if (converter == NULL)
    {
        *err = OPUS_INTERNAL_ERROR;
        return NULL;
    }

    s2a_apple *handle = calloc(1, sizeof *handle);

    if (handle == NULL)
    {
        AudioConverterDispose(converter);
        *err = OPUS_ALLOC_FAIL;
        return NULL;
    }

    handle->converter = converter;
    handle->channels = channels;
    *err = OPUS_OK;

    return handle;
}

int32_t s2a_apple_decode(void *p, const uint8_t *data, int32_t len, int16_t *pcm, int32_t frame_size)
{
    s2a_apple *handle = p;

    if (handle == NULL || data == NULL || pcm == NULL || len <= 0 || frame_size <= 0)
    {
        return OPUS_BAD_ARG;
    }

    s2a_apple_feed feed = {data, len, frame_size, handle->channels, 0};
    AudioBufferList output = {0};

    output.mNumberBuffers = 1;
    output.mBuffers[0].mNumberChannels = (UInt32)handle->channels;
    output.mBuffers[0].mDataByteSize = (UInt32)(frame_size * handle->channels * sizeof(int16_t));
    output.mBuffers[0].mData = pcm;

    UInt32 frames = (UInt32)frame_size;
    OSStatus status = AudioConverterFillComplexBuffer(handle->converter, s2a_apple_feed_cb, &feed, &frames, &output, NULL);

    if (status != noErr || frames != (UInt32)frame_size)
    {
        return OPUS_INTERNAL_ERROR;
    }

    return (int32_t)frames;
}

void s2a_apple_reset(void *p)
{
    s2a_apple *handle = p;

    if (handle != NULL)
    {
        AudioConverterReset(handle->converter);
    }
}

void s2a_apple_close(void *p)
{
    s2a_apple *handle = p;

    if (handle != NULL)
    {
        AudioConverterDispose(handle->converter);
        free(handle);
    }
}
