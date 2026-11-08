using System;
using System.IO;
using System.Linq;
using Ryujinx.Audio.Backends.Dummy;
using Ryujinx.Audio.Integration;
using Ryujinx.Audio.Common;
using Ryujinx.Memory;
using System.Threading;
using Ryujinx.HLE.HOS.SystemState;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private sealed class TrackingAudio : IHardwareDeviceDriver
        {
            private readonly DummyHardwareDeviceDriver _inner = new();
            internal int Disposals;
            internal bool FailDispose;
            public static bool IsSupported => true;
            public float Volume { get => _inner.Volume; set => _inner.Volume = value; }
            public IHardwareDeviceSession OpenDeviceSession(IHardwareDeviceDriver.Direction direction, IVirtualMemoryManager memory, SampleFormat format, uint rate, uint channels) => _inner.OpenDeviceSession(direction, memory, format, rate, channels);
            public ManualResetEvent GetUpdateRequiredEvent() => _inner.GetUpdateRequiredEvent();
            public ManualResetEvent GetPauseEvent() => _inner.GetPauseEvent();
            public bool SupportsDirection(IHardwareDeviceDriver.Direction direction) => _inner.SupportsDirection(direction);
            public bool SupportsSampleRate(uint rate) => _inner.SupportsSampleRate(rate);
            public bool SupportsSampleFormat(SampleFormat format) => _inner.SupportsSampleFormat(format);
            public bool SupportsChannelCount(uint count) => _inner.SupportsChannelCount(count);
            public void Dispose()
            {
                Disposals++;
                if (FailDispose) throw new InvalidOperationException("injected audio cleanup failure");
                _inner.Dispose();
            }
        }
        private static int RetryAudioCalls;
        private static TrackingAudio FirstAudio;
        private static bool FailFirstAudio;
        private static IHardwareDeviceDriver RetryAudio()
        {
            RetryAudioCalls++;
            var audio = new TrackingAudio { FailDispose = FailFirstAudio && RetryAudioCalls == 1 };
            if (RetryAudioCalls == 1) FirstAudio = audio;
            return audio;
        }
        private static ulong RetryProgramId() => 0x010000000000100D;

        private static int ExportsStartupRetryTest(bool zoneRace = false, bool cleanupFails = false)
        {
            string root = Path.Combine(Path.GetTempPath(), $"s2a_exports_retry_{Environment.ProcessId}");
            Directory.CreateDirectory(root);
            try
            {
                FakeNative.Install();
                FailFirstAudio = cleanupFails;
                Native.ScreenW = &TestScreenWidth; Native.ScreenH = &TestScreen1080; Native.ProgramId = &RetryProgramId;
                int rendererCalls = 0;
                string zoneLink = Path.Combine(root, "game", "systemdata", "010000000000080E");
                Exports.RendererFactory = () =>
                {
                    rendererCalls++;
                    if (zoneRace && rendererCalls == 1) Directory.Delete(zoneLink);
                    return new StubRenderer();
                };
                Exports.AudioFactory = &RetryAudio;
                Exports.AfterBoot = (_, _) => { };
                Exports.BeforeShutdown = () => { };
                Exports.ServiceFailure = _ => { };
                string game = Path.Combine(root, "game"), state = Path.Combine(root, "state");
                Directory.CreateDirectory(Path.Combine(game, "exefs"));
                Directory.CreateDirectory(Path.Combine(game, "ctl"));
                Directory.CreateDirectory(Path.Combine(game, "romfs"));
                AttachTestTimeZone(game);
                string fixture = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../compat/tree/src/Ryujinx.HLE/Homebrew.npdm"));
                File.Copy(fixture, Path.Combine(game, "exefs", "main.npdm"));
                File.WriteAllBytes(Path.Combine(game, "ctl", "control.nacp"), new byte[0x4000]);
                var invalid = new HostConfiguration(game, state, SystemLanguage.Japanese, RegionCode.Japan, zoneRace ? "Asia/Tokyo" : "NoSuchZone", false, new HostUi());
                var valid = new HostConfiguration(game, state, SystemLanguage.AmericanEnglish, RegionCode.USA, "UTC", false, new HostUi());
                bool failed = false, retry = false, aggregate = false;
                try { Exports.Initialize(invalid); }
                catch (InvalidOperationException e) when (e.Message.Contains("time zone", StringComparison.OrdinalIgnoreCase)) { failed = true; }
                catch (AggregateException e)
                {
                    aggregate = e.InnerExceptions.Any(x => x.Message.Contains("time zone", StringComparison.OrdinalIgnoreCase)) &&
                        e.InnerExceptions.Any(x => x.Message.Contains("injected audio cleanup failure", StringComparison.Ordinal));
                }
                if (cleanupFails)
                {
                    bool okFailure = aggregate && FirstAudio != null && FirstAudio.Disposals == 1 && Host.Device == null;
                    Console.WriteLine($"真实 Exports.Initialize：原时区错误及清理错误均保留，未启动服务 = {okFailure} {(okFailure ? "✓" : "✗")}");
                    return okFailure ? 0 : 1;
                }
                bool noEarlyFactories = rendererCalls == 0 && RetryAudioCalls == 0;
                bool failedAudioDisposed = !zoneRace || (FirstAudio != null && FirstAudio.Disposals == 1);
                if (zoneRace) AttachTestTimeZone(game);
                try { Exports.Initialize(valid); retry = Host.Device != null && ReferenceEquals(Host.Configuration, valid); }
                catch (Exception e) { Console.WriteLine($"实际入口重试抛出 {e.GetType().Name}: {e.Message}"); }
                if (retry) InputPump.Stop();
                bool ok = zoneRace
                    ? failed && failedAudioDisposed && retry && rendererCalls == 2 && RetryAudioCalls == 2
                    : failed && noEarlyFactories && retry && rendererCalls == 1 && RetryAudioCalls == 1;
                Console.WriteLine($"真实 Exports.Initialize：拒绝 / 未建资源 / 已建音频已释放 / 同进程重试 / 工厂数 = {failed} / {noEarlyFactories} / {failedAudioDisposed} / {retry} / {rendererCalls} / {RetryAudioCalls} {(ok ? "✓" : "✗")}");
                return ok ? 0 : 1;
            }
            finally { try { Directory.Delete(root, true); } catch { } }
        }
    }
}
