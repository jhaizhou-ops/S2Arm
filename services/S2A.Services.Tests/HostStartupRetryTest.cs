using System;
using System.IO;
using Ryujinx.Audio.Backends.Dummy;
using Ryujinx.HLE.HOS.SystemState;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private static int HostStartupRetryTest()
        {
            string root = Path.Combine(Path.GetTempPath(), $"s2a_host_retry_{Environment.ProcessId}");
            Directory.CreateDirectory(root);
            try
            {
                FakeNative.Install();
                string game = Path.Combine(root, "game"); Directory.CreateDirectory(game);
                AttachTestTimeZone(game);
                string state = Path.Combine(root, "state");
                var ui = new HostUi();
                var invalid = new HostConfiguration(game, state, SystemLanguage.Japanese, RegionCode.Japan, "NoSuchZone", false, ui);
                bool failed = false;
                try { Host.Boot(new StubRenderer(), new DummyHardwareDeviceDriver(), state, invalid); }
                catch (InvalidOperationException e) when (e.Message.Contains("time zone", StringComparison.OrdinalIgnoreCase)) { failed = true; }
                var valid = new HostConfiguration(game, state, SystemLanguage.AmericanEnglish, RegionCode.USA, "UTC", false, ui);
                bool retried = false;
                try
                {
                    Host.Boot(new StubRenderer(), new DummyHardwareDeviceDriver(), state, valid);
                    retried = Host.Device != null && ReferenceEquals(Host.Configuration, valid) && Host.Language == SystemLanguage.AmericanEnglish;
                }
                catch (Exception e) { Console.WriteLine($"重试抛出 {e.GetType().Name}: {e.Message}"); }
                Console.WriteLine($"真实 Host.Boot：无时区报错 / 同进程重试成功 = {failed} / {retried} {(failed && retried ? "✓" : "✗")}");
                // 进程内重启（11-02 测试机1 塞尔达：会话退休后第二次 Boot 抛「S2A 服务层已开始启动」）：会话退休走完，同进程再 Boot 一局要成功
                bool rebooted = false;
                if (retried)
                {
                    try
                    {
                        Host.ShutdownSessionServices();
                        Host.FinishShutdownSession();
                        bool released = !SaveTransfer.HostStarted && Host.Device == null;
                        Host.Boot(new StubRenderer(), new DummyHardwareDeviceDriver(), state, valid);
                        rebooted = released && Host.Device != null;
                        Console.WriteLine($"会话退休后：启动闸放开 = {released}，同进程第二局 Boot 成功 = {Host.Device != null}");
                    }
                    catch (Exception e) { Console.WriteLine($"会话退休后再 Boot 抛出 {e.GetType().Name}: {e.Message}"); }
                }
                Console.WriteLine($"进程内重启：退休后再 Boot {(rebooted ? "✓" : "✗")}");
                return failed && retried && rebooted ? 0 : 1;
            }
            finally { try { Directory.Delete(root, true); } catch { } }
        }
    }
}
