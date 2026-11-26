// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Audio.Backends.Apple;   // 平台例外：Mac 真 AudioQueue 回归
using Ryujinx.Audio.Backends.Common;
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;

namespace S2A.Services.Tests
{
    static unsafe class AppleAudioPcmContinuityTest
    {
        private const int RingFrames = 1 << 20;
        private const uint PreEffectsSiphon = 1 | 4;
        private const uint StartOfStream = 1 << 8;
        private static readonly int[] Ring = new int[RingFrames];
        private static long _written;
        private static int _overflow;
        private static int _starts;
        private static int _tapErrors;
        private static int _floatTap;
        private static int _attachRc;
        private static nint _tap;
        private static nint _tapQueue;
        private static nint _queue;
        private static readonly AudioQueueProcessingTapCallback TapCallback = OnTap;
        private static readonly FieldInfo QueueField = typeof(AppleHardwareDeviceSession).GetField("_audioQueue", BindingFlags.Instance | BindingFlags.NonPublic);   // 平台例外：取本平台真实队列

        [StructLayout(LayoutKind.Sequential)]
        private struct AudioStreamBasicDescription
        {
            public double SampleRate;
            public uint FormatId;
            public uint FormatFlags;
            public uint BytesPerPacket;
            public uint FramesPerPacket;
            public uint BytesPerFrame;
            public uint ChannelsPerFrame;
            public uint BitsPerChannel;
            public uint Reserved;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeAudioBuffer
        {
            public uint Channels;
            public uint DataByteSize;
            public nint Data;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeAudioBufferList
        {
            public uint BufferCount;
            public NativeAudioBuffer First;
        }

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private unsafe delegate void AudioQueueProcessingTapCallback(nint client, nint tap, uint frames, nint timestamp, uint* flags, uint* outputFrames, nint buffers);

        [DllImport("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")]   // 平台例外：Mac 真队列处理抽头
        private static extern int AudioQueueProcessingTapNew(nint queue, nint callback, nint client, uint flags, out uint maxFrames, out AudioStreamBasicDescription format, out nint tap);

        [DllImport("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")]   // 平台例外：Mac 真队列恢复
        private static extern int AudioQueueStart(nint queue, nint startTime);

        [DllImport("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")]   // 平台例外：Mac 真队列停止
        private static extern int AudioQueueStop(nint queue, [MarshalAs(UnmanagedType.I1)] bool immediate);

        private sealed class SequenceReader : HardwareDeviceSessionOutputBase
        {
            private long _next;

            public SequenceReader() : base(null, SampleFormat.PcmInt16, 48000, 2) { }

            public override void ReadSamples(AudioBuffer buffer, ulong offset, Span<byte> destination)
            {
                for (int i = 0; i < destination.Length; i += 4)
                {
                    int phase = (int)(_next++ % 1000);
                    short left = (short)(1000 + phase), right = (short)(2000 + phase);
                    BitConverter.TryWriteBytes(destination.Slice(i, 2), left);
                    BitConverter.TryWriteBytes(destination.Slice(i + 2, 2), right);
                }
            }

            public override void Dispose() { }
            public override void PrepareToClose() { }
            public override void QueueBuffer(AudioBuffer buffer) => throw new NotSupportedException();
            public override void SetVolume(float volume) { }
            public override float GetVolume() => 1f;
            public override void Start() { }
            public override void Stop() { }
            public override ulong GetPlayedSampleCount() => 0;
            public override bool WasBufferFullyConsumed(AudioBuffer buffer) => false;
        }

        private static unsafe void OnTap(nint client, nint tap, uint frames, nint timestamp, uint* flags, uint* outputFrames, nint buffers)
        {
            *outputFrames = frames;
            if ((*flags & StartOfStream) != 0)
            {
                Interlocked.Increment(ref _starts);
            }

            NativeAudioBufferList* list = (NativeAudioBufferList*)buffers;
            if (Volatile.Read(ref _floatTap) != 0)
            {
                if (list->BufferCount != 2 || list->First.Channels != 1 || list->First.DataByteSize < frames * 4 || list->First.Data == 0)
                {
                    Interlocked.Increment(ref _tapErrors);
                    return;
                }

                NativeAudioBuffer* second = &list->First + 1;
                if (second->Channels != 1 || second->DataByteSize < frames * 4 || second->Data == 0)
                {
                    Interlocked.Increment(ref _tapErrors);
                    return;
                }

                float* left = (float*)list->First.Data;
                float* right = (float*)second->Data;
                for (uint i = 0; i < frames; i++)
                {
                    int l = (int)MathF.Round(left[i] * 32768f), r = (int)MathF.Round(right[i] * 32768f);
                    l = Math.Clamp(l, short.MinValue, short.MaxValue);
                    r = Math.Clamp(r, short.MinValue, short.MaxValue);
                    long at = Interlocked.Increment(ref _written) - 1;
                    if (at < RingFrames) Ring[at] = (int)((uint)(ushort)l | ((uint)(ushort)r << 16));
                    else Interlocked.Exchange(ref _overflow, 1);
                }

                return;
            }

            if (list->BufferCount != 1 || list->First.Channels != 2 || list->First.DataByteSize < frames * 4 || list->First.Data == 0)
            {
                Interlocked.Increment(ref _tapErrors);
                return;
            }

            short* pcm = (short*)list->First.Data;
            for (uint i = 0; i < frames; i++)
            {
                long at = Interlocked.Increment(ref _written) - 1;
                if (at < RingFrames)
                {
                    Ring[at] = (int)((uint)(ushort)pcm[2 * i] | ((uint)(ushort)pcm[2 * i + 1] << 16));
                }
                else
                {
                    Interlocked.Exchange(ref _overflow, 1);
                }
            }
        }

        private static void ResetTap()
        {
            AudioQueueStop(_queue, true);
            Volatile.Write(ref _written, 0);
            Volatile.Write(ref _overflow, 0);
            Volatile.Write(ref _starts, 0);
            Volatile.Write(ref _tapErrors, 0);
            _attachRc = 0;
        }

        private static unsafe bool AttachTap()
        {
            _attachRc = AudioQueueProcessingTapNew(_queue, Marshal.GetFunctionPointerForDelegate(TapCallback), 0, PreEffectsSiphon, out _, out AudioStreamBasicDescription format, out _tap);
            bool pcm16 = format.SampleRate == 48000 && format.ChannelsPerFrame == 2 && format.BitsPerChannel == 16 && format.BytesPerFrame == 4;
            bool float32 = format.SampleRate == 48000 && format.ChannelsPerFrame == 2 && format.BitsPerChannel == 32 && format.BytesPerFrame == 4 && (format.FormatFlags & 1) != 0;
            Volatile.Write(ref _floatTap, float32 ? 1 : 0);
            if (_attachRc == 0 && (pcm16 || float32)) _tapQueue = _queue;
            return _attachRc == 0 && (pcm16 || float32);
        }

        private static (int Frames, int Mismatches, int ZeroFrames, int MaxZeroRun, int Starts, int Overflow, int Errors) Snapshot()
        {
            long written = Math.Min(Volatile.Read(ref _written), RingFrames);
            int mismatches = 0, zeroFrames = 0, maxZeroRun = 0, zeroRun = 0, expected = -1;
            for (long i = 0; i < written; i++)
            {
                uint packed = (uint)Ring[i];
                int left = (int)(packed & 0xffff), right = (int)(packed >> 16);
                if (left == 0 && right == 0)
                {
                    zeroFrames++;
                    zeroRun++;
                    maxZeroRun = Math.Max(maxZeroRun, zeroRun);
                    continue;
                }

                zeroRun = 0;
                int phase = left - 1000;
                if (phase < 0 || phase >= 1000 || right != 2000 + phase)
                {
                    mismatches++;
                }

                if (expected >= 0 && phase != (expected + 1) % 1000)
                {
                    mismatches++;
                }

                expected = phase;
            }

            return ((int)written, mismatches, zeroFrames, maxZeroRun, Volatile.Read(ref _starts), Volatile.Read(ref _overflow), Volatile.Read(ref _tapErrors));
        }

        [SoloTest("--apple-audio-pcm-continuity")]
        private static unsafe int Check()
        {
            if (!AppleHardwareDeviceDriver.IsSupported)   // 平台例外：Mac 真 AudioQueue 回归
            {
                Console.WriteLine("✗ 苹果音频 PCM 连续性：本机没有苹果音频后端");
                return 1;
            }

            Environment.SetEnvironmentVariable("S2A_AUDIO_TEST_STALL_AT", "1");
            var log = new StringWriter();
            TextWriter previous = Console.Error;
            Console.SetError(TextWriter.Synchronized(log));
            bool WaitLog(string text, int timeoutMs)
            {
                Stopwatch sw = Stopwatch.StartNew();
                while (sw.ElapsedMilliseconds < timeoutMs)
                {
                    if (log.ToString().Contains(text)) return true;
                    Thread.Sleep(5);
                }

                return log.ToString().Contains(text);
            }

            var reader = new SequenceReader();
            var driver = new AppleHardwareDeviceDriver();   // 平台例外：Mac 真 AudioQueue 回归
            IHardwareDeviceSession session = driver.OpenDeviceSession(IHardwareDeviceDriver.Direction.Output, null, SampleFormat.PcmInt16, 48000, 2);
            _queue = (nint)QueueField.GetValue(session);
            Volatile.Write(ref _written, 0);
            bool attached = AttachTap();
            int firstAttachRc = _attachRc;
            session.Start();

            const ulong Bytes = 4800 * 4;
            for (int i = 0; i < 240; i++)
            {
                var buffer = new AudioBuffer { DataPointer = 0x100000UL + (ulong)i * Bytes, DataSize = Bytes, BufferTag = (ulong)i, SampleReader = reader };
                session.RegisterBuffer(buffer);
                session.QueueBuffer(buffer);
            }

            bool stalled = WaitLog("外部暂停输出队列", 5000) && WaitLog("改走无设备播放", 3000);
            AudioQueueStop(_queue, true);
            var before = Snapshot();
            bool retried = WaitLog("试回设备", 5000);
            _queue = (nint)QueueField.GetValue(session);
            bool sameQueue = _tapQueue == _queue;
            ResetTap();
            bool reattached = sameQueue || AttachTap();
            int secondAttachRc = sameQueue ? 0 : _attachRc;
            int startRc = reattached ? AudioQueueStart(_queue, 0) : -1;
            Stopwatch sw = Stopwatch.StartNew();
            while (Volatile.Read(ref _written) < 24000 && sw.ElapsedMilliseconds < 10000)
            {
                Thread.Sleep(5);
            }

            AudioQueueStop(_queue, true);
            var after = Snapshot();
            session.Dispose();
            driver.Dispose();
            Console.SetError(previous);

            int bad = 0;
            void Row(string name, string expected, string actual, bool ok)
            {
                bad += ok ? 0 : 1;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 苹果音频 PCM 连续性 {name}：{expected} → {actual}");
            }

            Row("① 真队列抽头", "停播前可安装、48 kHz / 立体声 PCM", $"rc={firstAttachRc}、format={attached}", attached);
            Row("② 200 ms 停交还恢复", "进入无设备播放后试回设备", $"进入={stalled}、重试={retried}", stalled && retried);
            Row("③ 停播前 PCM", "≥24000 帧、0 错序/重复、0 格式错误、最长零run ≤16384", $"帧 {before.Frames}、错 {before.Mismatches}、零 {before.ZeroFrames}/{before.MaxZeroRun}、SOS {before.Starts}、溢 {before.Overflow}、错 {before.Errors}", before.Frames >= 24000 && before.Mismatches == 0 && before.MaxZeroRun <= 16384 && before.Starts <= 1 && before.Overflow == 0 && before.Errors == 0);
            Row("④ 重启后 PCM", "复用/重装抽头并播 ≥24000 帧、0 错序/重复、最长零run ≤16384", $"rc={secondAttachRc}/start={startRc}、帧 {after.Frames}、错 {after.Mismatches}、零 {after.ZeroFrames}/{after.MaxZeroRun}、SOS {after.Starts}、溢 {after.Overflow}、错 {after.Errors}", reattached && startRc == 0 && after.Frames >= 24000 && after.Mismatches == 0 && after.MaxZeroRun <= 16384 && after.Starts <= 1 && after.Overflow == 0 && after.Errors == 0);
            return bad == 0 ? 0 : 1;
        }
    }
}
