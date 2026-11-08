using Ryujinx.Common.Logging;
using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Sdk.Sf;
using Ryujinx.Horizon.Sdk.Sf.Hipc;
using System;
using System.Buffers.Binary;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Ryujinx.Horizon.Sdk.Codec.Detail
{
    // S2Arm：解码走 libopus（Xiph 参考实现，静态链进宿主，services/opus：libopus + C 垫片 s2a_opus.c），不用 Concentus 托管实现：
    // Concentus 每包托管分配 18–100 KB（单测：48 kHz 立体声 20 ms 25.9 KB、5.1 声道 101.6 KB；怪猎村子 22.7 KB / 包、200 秒 6736 包 149 MB；
    // 暗黑3 稳态每秒 40 多包），iOS NativeAOT 的 gen0 / gen1 回收是阻塞式的。
    // 解码在 C 侧完成，输入输出直接是游戏缓冲（Span 钉住传指针），每包零托管分配。
    unsafe partial class HardwareOpusDecoder : IHardwareOpusDecoder, IDisposable
    {
        private const string Lib = "s2a_opus";

        // libopus 错误码（opus_defines.h）
        private const int OpusBadArg = -1;
        private const int OpusBufferTooSmall = -2;
        private const int OpusInvalidPacket = -4;

        [LibraryImport(Lib)] private static partial nint s2a_opus_open(int rate, int channels, int streams, int coupled, byte* mapping, int* err);
        [LibraryImport(Lib)] private static partial int s2a_opus_decode(nint h, byte* data, int len, short* pcm, int frameSize);
        [LibraryImport(Lib)] private static partial void s2a_opus_reset(nint h);
        [LibraryImport(Lib)] private static partial void s2a_opus_close(nint h);
        [LibraryImport(Lib)] private static partial int s2a_opus_packet_samples(byte* data, int len, int rate);

        [StructLayout(LayoutKind.Sequential)]
        private struct OpusPacketHeader
        {
            public uint Length;
            public uint FinalRange;

            public static OpusPacketHeader FromSpan(ReadOnlySpan<byte> data)
            {
                return new()
                {
                    Length = BinaryPrimitives.ReadUInt32BigEndian(data),
                    FinalRange = BinaryPrimitives.ReadUInt32BigEndian(data[sizeof(uint)..]),
                };
            }
        }

        // 单流（mapping 为空）/ 多流解码器，句柄归 libopus（垫片里统一成一个句柄）
        private sealed class NativeDecoder : IDisposable
        {
            private nint _handle;

            public int SampleRate { get; }
            public int ChannelsCount { get; }

            public NativeDecoder(int sampleRate, int channelsCount, int streams, int coupledStreams, byte[] mapping)
            {
                int err;

                fixed (byte* m = mapping)
                {
                    _handle = s2a_opus_open(sampleRate, channelsCount, streams, coupledStreams, m, &err);
                }

                if (_handle == 0)
                {
                    throw new ArgumentException($"libopus: decoder create failed ({err}): {sampleRate} Hz, {channelsCount} ch, {streams} streams, {coupledStreams} coupled");
                }

                SampleRate = sampleRate;
                ChannelsCount = channelsCount;
            }

            // 返回每声道解出的样本数，或 libopus 负错误码
            public int Decode(ReadOnlySpan<byte> inData, Span<short> outPcm, int frameSize)
            {
                fixed (byte* src = inData)
                fixed (short* dst = outPcm)
                {
                    return s2a_opus_decode(_handle, src, inData.Length, dst, frameSize);
                }
            }

            public void ResetState() => s2a_opus_reset(_handle);

            public void Dispose()
            {
                s2a_opus_close(_handle);
                _handle = 0;
            }
        }

        private readonly NativeDecoder _decoder;
        private int _workBufferHandle;

        private HardwareOpusDecoder(int workBufferHandle)
        {
            _workBufferHandle = workBufferHandle;
        }

        public HardwareOpusDecoder(int sampleRate, int channelsCount, int workBufferHandle) : this(workBufferHandle)
        {
            _decoder = new NativeDecoder(sampleRate, channelsCount, 0, 0, null);
        }

        public HardwareOpusDecoder(int sampleRate, int channelsCount, int streams, int coupledStreams, byte[] mapping, int workBufferHandle) : this(workBufferHandle)
        {
            _decoder = new NativeDecoder(sampleRate, channelsCount, streams, coupledStreams, mapping);
        }

        [CmifCommand(0)]
        public Result DecodeInterleavedOld(
            out int outConsumed,
            out int outSamples,
            [Buffer(HipcBufferFlags.Out | HipcBufferFlags.MapAlias)] Span<byte> output,
            [Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias)] ReadOnlySpan<byte> input)
        {
            return DecodeInterleavedInternal(out outConsumed, out outSamples, out _, output, input, reset: false, withPerf: false);
        }

        [CmifCommand(1)]
        public Result SetContext(ReadOnlySpan<byte> context)
        {
            Logger.Stub?.PrintStub(LogClass.ServiceAudio);

            return Result.Success;
        }

        [CmifCommand(2)] // 3.0.0+
        public Result DecodeInterleavedForMultiStreamOld(
            out int outConsumed,
            out int outSamples,
            [Buffer(HipcBufferFlags.Out | HipcBufferFlags.MapAlias)] Span<byte> output,
            [Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias)] ReadOnlySpan<byte> input)
        {
            return DecodeInterleavedInternal(out outConsumed, out outSamples, out _, output, input, reset: false, withPerf: false);
        }

        [CmifCommand(3)] // 3.0.0+
        public Result SetContextForMultiStream(ReadOnlySpan<byte> arg0)
        {
            Logger.Stub?.PrintStub(LogClass.ServiceAudio);

            return Result.Success;
        }

        [CmifCommand(4)] // 4.0.0+
        public Result DecodeInterleavedWithPerfOld(
            out int outConsumed,
            out long timeTaken,
            out int outSamples,
            [Buffer(HipcBufferFlags.Out | HipcBufferFlags.MapAlias | HipcBufferFlags.MapTransferAllowsNonSecure)] Span<byte> output,
            [Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias)] ReadOnlySpan<byte> input)
        {
            return DecodeInterleavedInternal(out outConsumed, out outSamples, out timeTaken, output, input, reset: false, withPerf: true);
        }

        [CmifCommand(5)] // 4.0.0+
        public Result DecodeInterleavedForMultiStreamWithPerfOld(
            out int outConsumed,
            out long timeTaken,
            out int outSamples,
            [Buffer(HipcBufferFlags.Out | HipcBufferFlags.MapAlias | HipcBufferFlags.MapTransferAllowsNonSecure)] Span<byte> output,
            [Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias)] ReadOnlySpan<byte> input)
        {
            return DecodeInterleavedInternal(out outConsumed, out outSamples, out timeTaken, output, input, reset: false, withPerf: true);
        }

        [CmifCommand(6)] // 6.0.0+
        public Result DecodeInterleavedWithPerfAndResetOld(
            out int outConsumed,
            out long timeTaken,
            out int outSamples,
            [Buffer(HipcBufferFlags.Out | HipcBufferFlags.MapAlias | HipcBufferFlags.MapTransferAllowsNonSecure)] Span<byte> output,
            [Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias)] ReadOnlySpan<byte> input,
            bool reset)
        {
            return DecodeInterleavedInternal(out outConsumed, out outSamples, out timeTaken, output, input, reset, withPerf: true);
        }

        [CmifCommand(7)] // 6.0.0+
        public Result DecodeInterleavedForMultiStreamWithPerfAndResetOld(
            out int outConsumed,
            out long timeTaken,
            out int outSamples,
            [Buffer(HipcBufferFlags.Out | HipcBufferFlags.MapAlias | HipcBufferFlags.MapTransferAllowsNonSecure)] Span<byte> output,
            [Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias)] ReadOnlySpan<byte> input,
            bool reset)
        {
            return DecodeInterleavedInternal(out outConsumed, out outSamples, out timeTaken, output, input, reset, withPerf: true);
        }

        [CmifCommand(8)] // 7.0.0+
        public Result DecodeInterleaved(
            out int outConsumed,
            out long timeTaken,
            out int outSamples,
            [Buffer(HipcBufferFlags.Out | HipcBufferFlags.MapAlias | HipcBufferFlags.MapTransferAllowsNonSecure)] Span<byte> output,
            [Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias | HipcBufferFlags.MapTransferAllowsNonSecure)] ReadOnlySpan<byte> input,
            bool reset)
        {
            return DecodeInterleavedInternal(out outConsumed, out outSamples, out timeTaken, output, input, reset, withPerf: true);
        }

        [CmifCommand(9)] // 7.0.0+
        public Result DecodeInterleavedForMultiStream(
            out int outConsumed,
            out long timeTaken,
            out int outSamples,
            [Buffer(HipcBufferFlags.Out | HipcBufferFlags.MapAlias | HipcBufferFlags.MapTransferAllowsNonSecure)] Span<byte> output,
            [Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias | HipcBufferFlags.MapTransferAllowsNonSecure)] ReadOnlySpan<byte> input,
            bool reset)
        {
            return DecodeInterleavedInternal(out outConsumed, out outSamples, out timeTaken, output, input, reset, withPerf: true);
        }

        private Result DecodeInterleavedInternal(
            out int outConsumed,
            out int outSamples,
            out long timeTaken,
            Span<byte> output,
            ReadOnlySpan<byte> input,
            bool reset,
            bool withPerf)
        {
            timeTaken = 0;

            Span<short> outPcmSpace = MemoryMarshal.Cast<byte, short>(output);
            Result result = DecodeInterleaved(_decoder, reset, input, outPcmSpace, output.Length, out outConsumed, out outSamples);

            if (withPerf)
            {
                // This is the time the DSP took to process the request, TODO: fill this.
                timeTaken = 0;
            }

            return result;
        }

        private static Result GetPacketNumSamples(NativeDecoder decoder, out int numSamples, ReadOnlySpan<byte> packet)
        {
            int result;

            fixed (byte* p = packet)
            {
                result = s2a_opus_packet_samples(p, packet.Length, decoder.SampleRate);
            }

            numSamples = result;

            if (result == OpusInvalidPacket)
            {
                return CodecResult.OpusInvalidPacket;
            }
            else if (result == OpusBadArg)
            {
                return CodecResult.OpusBadArg;
            }

            return Result.Success;
        }

        private static Result DecodeInterleaved(
            NativeDecoder decoder,
            bool reset,
            ReadOnlySpan<byte> input,
            Span<short> outPcmData,
            int outputSize,
            out int outConsumed,
            out int outSamples)
        {
            outConsumed = 0;
            outSamples = 0;

            int streamSize = input.Length;

            if (streamSize < Unsafe.SizeOf<OpusPacketHeader>())
            {
                return CodecResult.InvalidLength;
            }

            OpusPacketHeader header = OpusPacketHeader.FromSpan(input);
            int headerSize = Unsafe.SizeOf<OpusPacketHeader>();
            uint totalSize = header.Length + (uint)headerSize;

            if (totalSize > streamSize)
            {
                return CodecResult.InvalidLength;
            }

            ReadOnlySpan<byte> opusData = input.Slice(headerSize, (int)header.Length);

            Result result = GetPacketNumSamples(decoder, out int numSamples, opusData);

            if (result.IsSuccess)
            {
                if ((uint)numSamples * (uint)decoder.ChannelsCount * sizeof(short) > outputSize)
                {
                    return CodecResult.InvalidLength;
                }

                if (reset)
                {
                    decoder.ResetState();
                }

                int decoded = decoder.Decode(opusData, outPcmData, numSamples);

                // 错误码对应同上游（Concentus 抛 OpusException 时的分支）
                switch (decoded)
                {
                    case OpusBufferTooSmall:
                        return CodecResult.InvalidLength;
                    case OpusBadArg:
                        return CodecResult.OpusBadArg;
                    case OpusInvalidPacket:
                        return CodecResult.OpusInvalidPacket;
                    case < 0:
                        return CodecResult.InvalidLength;
                }

                outSamples = decoded;
                outConsumed = (int)totalSize;
            }

            return Result.Success;
        }

        protected virtual void Dispose(bool disposing)
        {
            if (disposing)
            {
                if (_workBufferHandle != 0)
                {
                    HorizonStatic.Syscall.CloseHandle(_workBufferHandle);

                    _workBufferHandle = 0;
                }

                _decoder?.Dispose();
            }
        }

        public void Dispose()
        {
            Dispose(disposing: true);
            GC.SuppressFinalize(this);
        }
    }
}
