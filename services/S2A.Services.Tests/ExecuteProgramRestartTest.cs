using System;
using System.IO;
using Ryujinx.Audio.Backends.Dummy;
using Ryujinx.HLE.HOS;
using Ryujinx.HLE.HOS.Services.Am.AppletOE.ApplicationProxyService.ApplicationProxy.Types;
using Ryujinx.HLE.HOS.SystemState;

namespace S2A.Services.Tests
{
    // 同程序重启（普查 bug 总表 #23 刺客信条 艾吉奥合集：标题页按 A 后游戏调 ExecuteProgram(ExecuteProgram, 0) 要求用同一程序重启，我方只报红、卡住）。
    //   期望按 Ryujinx 真值手写（UserChannelPersistence.ExecuteProgram + 界面层停模拟、按 Index 重载同一文件、通道对象跨重启存活）：
    //   ① 同序号：PreviousIndex -1 → 0、Index 0、ShouldRestart 真，重启入口调 1 次，不报红；RestartProgram 同理；入口返回非 0 报红
    //   ② 别的序号（多程序合集）：报红 1 次、通道不变、不调重启入口
    //   ③ 会话退休后再 Boot：Device 用的通道还是同一个对象，GetPreviousProgramIndex 读的 PreviousIndex = 0（首启 -1），重启前 Unpop 的数据 Pop 得到
    public static unsafe partial class Program
    {
        [SoloTest("--execute-program-restart")]
        private static int ExecuteProgramRestartTest()
        {
            string root = Path.Combine(Path.GetTempPath(), $"s2a_exec_restart_{Environment.ProcessId}");
            Directory.CreateDirectory(root);
            int restarts = 0, restartRc = 0;
            bool ok = true;
            void Row(string what, string want, string got)
            {
                bool pass = want == got; ok &= pass;
                Console.WriteLine($"{what}：期望 {want} → 真结果 {got} {(pass ? "✓" : "✗")}");
            }
            try
            {
                FakeNative.Install();
                Host.RestartHook = () => { restarts++; return restartRc; };
                string game = Path.Combine(root, "game"); Directory.CreateDirectory(game);
                AttachTestTimeZone(game);
                string state = Path.Combine(root, "state");
                var ui = new HostUi();
                var config = new HostConfiguration(game, state, SystemLanguage.AmericanEnglish, RegionCode.USA, "UTC", false, ui);
                Host.Boot(new StubRenderer(), new DummyHardwareDeviceDriver(), state, config);
                UserChannelPersistence first = Host.Device.Configuration.UserChannelPersistence;
                Row("首启 GetPreviousProgramIndex / 当前序号", "-1 / 0", $"{first.PreviousIndex} / {first.Index}");

                byte[] saved = { 0x41, 0x43, 0x32 };
                first.Push(saved);   // = IApplicationFunctions.UnpopToUserChannel

                // ② 别的序号：多程序合集未支持
                long red0 = Red.Total;
                ui.ExecuteProgram(Host.Device, ProgramSpecifyKind.ExecuteProgram, 1);
                Row("② ExecuteProgram 序号 1：报红 / 重启调用 / Previous / Index", "+1 / 0 / -1 / 0",
                    $"+{Red.Total - red0} / {restarts} / {first.PreviousIndex} / {first.Index}");

                // ① 同序号：记通道 + 发起重启
                red0 = Red.Total;
                ui.ExecuteProgram(Host.Device, ProgramSpecifyKind.ExecuteProgram, 0);
                Row("① ExecuteProgram 序号 0：报红 / 重启调用 / Previous / Index / ShouldRestart", "+0 / 1 / 0 / 0 / True",
                    $"+{Red.Total - red0} / {restarts} / {first.PreviousIndex} / {first.Index} / {first.ShouldRestart}");

                // RestartProgram：序号不变，同样重启
                red0 = Red.Total;
                ui.ExecuteProgram(Host.Device, ProgramSpecifyKind.RestartProgram, 0);
                Row("① RestartProgram：报红 / 重启调用 / Index", "+0 / 2 / 0", $"+{Red.Total - red0} / {restarts} / {first.Index}");

                // 重启入口拒绝（-3 = 另一次重启在进行）：报红，不假装成功
                restartRc = -3; red0 = Red.Total;
                ui.ExecuteProgram(Host.Device, ProgramSpecifyKind.ExecuteProgram, 0);
                Row("① 重启入口返回 -3：报红 / 重启调用", "+1 / 3", $"+{Red.Total - red0} / {restarts}");

                // ③ 会话退休 → 同进程再 Boot（同 HostStartupRetryTest 的进程内重启路径）
                Host.ShutdownSessionServices();
                Host.FinishShutdownSession();
                Host.Boot(new StubRenderer(), new DummyHardwareDeviceDriver(), state, config);
                UserChannelPersistence second = Host.Device.Configuration.UserChannelPersistence;
                byte[] popped = second.Pop();   // = PopLaunchParameter(UserChannel)
                Row("③ 重启后：同一通道 / GetPreviousProgramIndex / Pop 到重启前数据", "True / 0 / 414332",
                    $"{ReferenceEquals(first, second)} / {second.PreviousIndex} / {(popped == null ? "空" : Convert.ToHexString(popped))}");
            }
            catch (Exception e) { ok = false; Console.WriteLine($"抛出 {e.GetType().Name}: {e.Message}"); }
            finally { Host.RestartHook = null; try { Directory.Delete(root, true); } catch { } }
            Console.WriteLine($"同程序重启：{(ok ? "全过 ✓" : "有不符 ✗")}");
            // 起过 Horizon 服务线程（前台线程），同 --host-startup-retry 显式退出，不然进程等到 test.sh 的 60 秒超时
            Environment.Exit(ok ? 0 : 1);
            return ok ? 0 : 1;
        }
    }
}
