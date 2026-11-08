using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using Ryujinx.Common.Logging;
using Ryujinx.Memory;
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Threading;
using System.Runtime.Versioning;
using Ryujinx.Audio.Backends.Apple.Native;
using static Ryujinx.Audio.Backends.Apple.Native.AudioToolbox;
using static Ryujinx.Audio.Integration.IHardwareDeviceDriver;

namespace Ryujinx.Audio.Backends.Apple
{
    [SupportedOSPlatform("macos")]
    [SupportedOSPlatform("ios")]
    public sealed class AppleHardwareDeviceDriver : IHardwareDeviceDriver
    {
        private readonly ManualResetEvent _updateRequiredEvent;
        private readonly ManualResetEvent _pauseEvent;
        private readonly ConcurrentDictionary<AppleHardwareDeviceSession, byte> _sessions;
        private readonly bool _supportSurroundConfiguration;
        private readonly object _sessionLock = new();
        private bool _disposed;

        public float Volume { get; set; }

        public AppleHardwareDeviceDriver()
        {
            _updateRequiredEvent = new ManualResetEvent(false);
            _pauseEvent = new ManualResetEvent(true);
            _sessions = new ConcurrentDictionary<AppleHardwareDeviceSession, byte>();

            // S2A：能耗单变量开关（缺省全关，行为不变；同旧库 front_ios.m；10-20 动森新架构整机功率约为旧库 2 倍）：
            //   S2A_AUDIO_CH2=1 不试建 5.1、只报 2 声道（游戏自己出立体声，混音与系统降混都按 2 声道）
            //   S2A_AUDIO_SOLO=1 AVAudioSession 类别设 SoloAmbient；S2A_AUDIO_IO20=1 首选 IO 缓冲 20 ms
            //   S2A_AUDIO_STEREO=1 = 以上三项同开（减法实验拆项前的合并开关）
            bool all = Environment.GetEnvironmentVariable("S2A_AUDIO_STEREO") == "1";
            bool ch2 = all || Environment.GetEnvironmentVariable("S2A_AUDIO_CH2") == "1";
            bool solo = all || Environment.GetEnvironmentVariable("S2A_AUDIO_SOLO") == "1";
            bool io20 = all || Environment.GetEnvironmentVariable("S2A_AUDIO_IO20") == "1";
            _supportSurroundConfiguration = !ch2 && TestSurroundSupport();
            if (ch2) Console.Error.WriteLine("[S2A 声音] 只报 2 声道（S2A_AUDIO_CH2 / STEREO）");
            if (solo || io20) S2AConfigureSession(solo, io20);

            Volume = 1f;
        }

        private static unsafe void S2AConfigureSession(bool solo, bool io20)
        {
            if (!OperatingSystem.IsIOS())
            {
                Console.Error.WriteLine("[S2A 声音] 非 iOS，不设音频会话");
                return;
            }

            try
            {
                NativeLibrary.Load("/System/Library/Frameworks/AVFAudio.framework/AVFAudio");
                nint objc = NativeLibrary.Load("/usr/lib/libobjc.A.dylib");
                var getClass = (delegate* unmanaged<byte*, nint>)NativeLibrary.GetExport(objc, "objc_getClass");
                var selReg = (delegate* unmanaged<byte*, nint>)NativeLibrary.GetExport(objc, "sel_registerName");
                nint send = NativeLibrary.GetExport(objc, "objc_msgSend");
                nint Sel(string n) { byte[] b = System.Text.Encoding.UTF8.GetBytes(n + "\0"); fixed (byte* p = b) return selReg(p); }
                nint Cls(string n) { byte[] b = System.Text.Encoding.UTF8.GetBytes(n + "\0"); fixed (byte* p = b) return getClass(p); }
                nint session = ((delegate* unmanaged<nint, nint, nint>)send)(Cls("AVAudioSession"), Sel("sharedInstance"));
                byte[] cat = System.Text.Encoding.UTF8.GetBytes("AVAudioSessionCategorySoloAmbient\0");
                nint catStr;
                fixed (byte* p = cat) catStr = ((delegate* unmanaged<nint, nint, byte*, nint>)send)(Cls("NSString"), Sel("stringWithUTF8String:"), p);
                nint err = 0;
                byte okCat = solo ? ((delegate* unmanaged<nint, nint, nint, nint*, byte>)send)(session, Sel("setCategory:error:"), catStr, &err) : (byte)2;
                byte okIo = io20 ? ((delegate* unmanaged<nint, nint, double, nint*, byte>)send)(session, Sel("setPreferredIOBufferDuration:error:"), 0.020, &err) : (byte)2;
                byte okAct = ((delegate* unmanaged<nint, nint, byte, nint*, byte>)send)(session, Sel("setActive:error:"), 1, &err);
                double io = ((delegate* unmanaged<nint, nint, double>)send)(session, Sel("IOBufferDuration"));
                double rate = ((delegate* unmanaged<nint, nint, double>)send)(session, Sel("sampleRate"));
                Console.Error.WriteLine($"[S2A 声音] 会话：SoloAmbient {okCat}、首选 IO 20 ms {okIo}（1 成功 0 失败 2 未设）、激活 {okAct}；实际 IO 缓冲 {io * 1000:F1} ms、采样率 {rate:F0}");
            }
            catch (Exception e)
            {
                Console.Error.WriteLine($"[S2A 声音] 【红】音频会话设置失败：{e.Message}");
            }
        }

        // S2Arm (10-23 声音停了自愈): iOS 上重新激活音频会话（系统打断 / 路由切换后队列要在激活的会话上才能再开播）。
        //   AppleHardwareDeviceSession 的停播看门狗调；非 iOS 返回 true 不做事。objc 指针首次取后缓存，之后调用不分配
        private static nint _avSession, _selSetActive, _msgSend;

        internal unsafe bool S2AReactivateSession()
        {
            if (!OperatingSystem.IsIOS())
            {
                return true;
            }

            try
            {
                if (_avSession == 0)
                {
                    NativeLibrary.Load("/System/Library/Frameworks/AVFAudio.framework/AVFAudio");
                    nint objc = NativeLibrary.Load("/usr/lib/libobjc.A.dylib");
                    var getClass = (delegate* unmanaged<byte*, nint>)NativeLibrary.GetExport(objc, "objc_getClass");
                    var selReg = (delegate* unmanaged<byte*, nint>)NativeLibrary.GetExport(objc, "sel_registerName");
                    _msgSend = NativeLibrary.GetExport(objc, "objc_msgSend");
                    nint cls, selShared;

                    fixed (byte* p = "AVAudioSession\0"u8) cls = getClass(p);
                    fixed (byte* p = "sharedInstance\0"u8) selShared = selReg(p);
                    fixed (byte* p = "setActive:error:\0"u8) _selSetActive = selReg(p);

                    _avSession = ((delegate* unmanaged<nint, nint, nint>)_msgSend)(cls, selShared);
                }

                nint err = 0;

                return ((delegate* unmanaged<nint, nint, byte, nint*, byte>)_msgSend)(_avSession, _selSetActive, 1, &err) != 0;
            }
            catch (Exception e)
            {
                Console.Error.WriteLine($"[声] 【红】重新激活音频会话失败：{e.Message}");

                return false;
            }
        }

        private bool TestSurroundSupport()
        {
            try
            {
                AudioStreamBasicDescription format =
                    GetAudioFormat(SampleFormat.PcmFloat, Constants.TargetSampleRate, 6);

                int result = AudioQueueNewOutput(
                    ref format,
                    nint.Zero,
                    nint.Zero,
                    nint.Zero,
                    nint.Zero,
                    0,
                    out nint testQueue);

                if (result == 0)
                {
                    AudioChannelLayout layout = new AudioChannelLayout
                    {
                        AudioChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A,
                        AudioChannelBitmap = 0,
                        NumberChannelDescriptions = 0
                    };

                    int layoutResult = AudioQueueSetProperty(
                        testQueue,
                        kAudioQueueProperty_ChannelLayout,
                        ref layout,
                        (uint)Marshal.SizeOf<AudioChannelLayout>());

                    if (layoutResult == 0)
                    {
                        AudioQueueDispose(testQueue, true);
                        return true;
                    }

                    AudioQueueDispose(testQueue, true);
                }

                return false;
            }
            catch
            {
                return false;
            }
        }

        public static bool IsSupported => OperatingSystem.IsMacOSVersionAtLeast(10, 5) || OperatingSystem.IsIOS();

        public ManualResetEvent GetUpdateRequiredEvent()
            => _updateRequiredEvent;

        public ManualResetEvent GetPauseEvent()
            => _pauseEvent;

        public IHardwareDeviceSession OpenDeviceSession(Direction direction, IVirtualMemoryManager memoryManager,
            SampleFormat sampleFormat, uint sampleRate, uint channelCount)
        {
            lock (_sessionLock)
            {
                ObjectDisposedException.ThrowIf(_disposed, this);
                if (channelCount == 0)
                {
                    channelCount = 2;
                }

                if (sampleRate == 0)
                {
                    sampleRate = Constants.TargetSampleRate;
                }

                if (direction != Direction.Output)
                {
                    throw new NotImplementedException("Input direction is currently not implemented on Apple backend!");
                }

                AppleHardwareDeviceSession session = new(this, memoryManager, sampleFormat, sampleRate, channelCount);

                _sessions.TryAdd(session, 0);

                return session;
            }
        }

        internal bool Unregister(AppleHardwareDeviceSession session)
            => _sessions.TryRemove(session, out _);

        internal static AudioStreamBasicDescription GetAudioFormat(SampleFormat sampleFormat, uint sampleRate,
            uint channelCount)
        {
            uint formatFlags;
            uint bitsPerChannel;

            switch (sampleFormat)
            {
                case SampleFormat.PcmInt8:
                    formatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
                    bitsPerChannel = 8;
                    break;
                case SampleFormat.PcmInt16:
                    formatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
                    bitsPerChannel = 16;
                    break;
                case SampleFormat.PcmInt32:
                    formatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
                    bitsPerChannel = 32;
                    break;
                case SampleFormat.PcmFloat:
                    formatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
                    bitsPerChannel = 32;
                    break;
                default:
                    throw new ArgumentException($"Unsupported sample format {sampleFormat}");
            }

            uint bytesPerFrame = (bitsPerChannel / 8) * channelCount;

            return new AudioStreamBasicDescription
            {
                SampleRate = sampleRate,
                FormatID = kAudioFormatLinearPCM,
                FormatFlags = formatFlags,
                BytesPerPacket = bytesPerFrame,
                FramesPerPacket = 1,
                BytesPerFrame = bytesPerFrame,
                ChannelsPerFrame = channelCount,
                BitsPerChannel = bitsPerChannel,
                Reserved = 0
            };
        }

        public void Dispose()
        {
            GC.SuppressFinalize(this);
            Dispose(true);
        }

        private void Dispose(bool disposing)
        {
            if (disposing)
            {
                lock (_sessionLock)
                {
                    if (_disposed) return;
                    foreach (AppleHardwareDeviceSession session in _sessions.Keys)
                    {
                        session.Dispose();
                    }

                    _updateRequiredEvent.Dispose();
                    _pauseEvent.Dispose();
                    _disposed = true;
                }
            }
        }

        public bool SupportsDirection(Direction direction)
            => direction != Direction.Input;

        public bool SupportsSampleRate(uint sampleRate) => true;

        public bool SupportsSampleFormat(SampleFormat sampleFormat)
            => sampleFormat != SampleFormat.PcmInt24;

        public bool SupportsChannelCount(uint channelCount)
            => channelCount != 6 || _supportSurroundConfiguration;
    }
}
