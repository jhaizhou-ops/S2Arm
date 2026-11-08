using System;
using System.Collections.Generic;
using System.IO;
using Ryujinx.Audio.Backends.Dummy;
using Ryujinx.HLE.HOS;
using Ryujinx.HLE.HOS.Services.Am.AppletOE.ApplicationProxyService.ApplicationProxy.Types;
using Ryujinx.HLE.HOS.SystemState;

namespace S2A.Services.Tests
{
    // 多程序合集切程序（普查 c1105_r4 索尼克×夏特 世代重启：主菜单选游戏后 ExecuteProgram(ExecuteProgram, 1)，我方只报红「多程序合集未支持」、停帧）。
    //   包内约定（Application.ProgramDir / runtime/include/s2a_programs.h）：序号 0 = 游戏数据根，序号 n 在 programs/<n>/，有 exefs/main.npdm 才算、只数连续段。
    //   期望按 Ryujinx 真值手写（UserChannelPersistence.ExecuteProgram：PreviousIndex = Index、Index = value；界面层按新 Index 重载同一个包；
    //   RegisterProgramMapInfo 只数连续序号；SubApplicationProgram 上游也未实现）：
    //   ① 目录与支数：根 + programs/1 + programs/3（缺 2）= 2 支；序号 1 目录 = 根/programs/1
    //   ② 包里没有的序号 2：报红 1、不调原生登记、不重启、通道 -1 / 0
    //   ③ 原生登记拒绝（-1）：报红 1、登记调 1 次（序号 1）、不重启、通道不变
    //   ④ 重启入口拒绝（-3）：报红 1、登记两次（1，再改回当前 0）、重启调 1 次、通道不变
    //   ⑤ 正常：不报红、登记 1、重启 1 次、通道 Previous 0 / Index 1 / ShouldRestart 真
    //   ⑥ SubApplicationProgram：报红 1、不登记、不重启
    public static unsafe partial class Program
    {
        [SoloTest("--multi-program")]
        private static int MultiProgramTest()
        {
            string root = Path.Combine(Path.GetTempPath(), $"s2a_multi_program_{Environment.ProcessId}");
            Directory.CreateDirectory(root);
            int restarts = 0, restartRc = 0, selectRc = 0;
            var selects = new List<int>();
            bool ok = true;
            void Row(string what, string want, string got)
            {
                bool pass = want == got; ok &= pass;
                Console.WriteLine($"{what}：期望 {want} → 真结果 {got} {(pass ? "✓" : "✗")}");
            }
            string Sel() => selects.Count == 0 ? "无" : string.Join(",", selects);
            try
            {
                FakeNative.Install();
                Host.RestartHook = () => { restarts++; return restartRc; };
                Host.SelectProgramHook = i => { selects.Add(i); return selectRc; };
                string game = Path.Combine(root, "game"); Directory.CreateDirectory(game);
                foreach (string d in new[] { game, Path.Combine(game, "programs", "1"), Path.Combine(game, "programs", "3") })
                {
                    Directory.CreateDirectory(Path.Combine(d, "exefs"));
                    File.WriteAllBytes(Path.Combine(d, "exefs", "main.npdm"), new byte[] { 0x4d, 0x45, 0x54, 0x41 });
                }
                AttachTestTimeZone(game);
                string state = Path.Combine(root, "state");
                var ui = new HostUi();
                var config = new HostConfiguration(game, state, SystemLanguage.AmericanEnglish, RegionCode.USA, "UTC", false, ui);
                Host.Boot(new StubRenderer(), new DummyHardwareDeviceDriver(), state, config);
                Application.GameDir = game;   // 生产由 Application.Register 记下（这里不起游戏进程）
                UserChannelPersistence ch = Host.Device.Configuration.UserChannelPersistence;

                Row("① 支数 / 序号 1 目录", $"2 / {Path.Combine(game, "programs", "1")}",
                    $"{Application.ProgramCount(game)} / {Application.ProgramDir(game, 1)}");

                long red0 = Red.Total;
                ui.ExecuteProgram(Host.Device, ProgramSpecifyKind.ExecuteProgram, 2);
                Row("② 序号 2（包里没有）：报红 / 登记 / 重启 / Previous / Index", "+1 / 无 / 0 / -1 / 0",
                    $"+{Red.Total - red0} / {Sel()} / {restarts} / {ch.PreviousIndex} / {ch.Index}");

                selectRc = -1; red0 = Red.Total; selects.Clear();
                ui.ExecuteProgram(Host.Device, ProgramSpecifyKind.ExecuteProgram, 1);
                Row("③ 原生登记 -1：报红 / 登记 / 重启 / Previous / Index", "+1 / 1 / 0 / -1 / 0",
                    $"+{Red.Total - red0} / {Sel()} / {restarts} / {ch.PreviousIndex} / {ch.Index}");

                selectRc = 0; restartRc = -3; red0 = Red.Total; selects.Clear();
                ui.ExecuteProgram(Host.Device, ProgramSpecifyKind.ExecuteProgram, 1);
                Row("④ 重启入口 -3：报红 / 登记 / 重启 / Previous / Index", "+1 / 1,0 / 1 / -1 / 0",
                    $"+{Red.Total - red0} / {Sel()} / {restarts} / {ch.PreviousIndex} / {ch.Index}");

                restartRc = 0; red0 = Red.Total; selects.Clear();
                ui.ExecuteProgram(Host.Device, ProgramSpecifyKind.ExecuteProgram, 1);
                Row("⑤ 正常切到序号 1：报红 / 登记 / 重启 / Previous / Index / ShouldRestart", "+0 / 1 / 2 / 0 / 1 / True",
                    $"+{Red.Total - red0} / {Sel()} / {restarts} / {ch.PreviousIndex} / {ch.Index} / {ch.ShouldRestart}");

                red0 = Red.Total; selects.Clear();
                ui.ExecuteProgram(Host.Device, ProgramSpecifyKind.SubApplicationProgram, 0);
                Row("⑥ SubApplicationProgram：报红 / 登记 / 重启 / Index", "+1 / 无 / 2 / 1",
                    $"+{Red.Total - red0} / {Sel()} / {restarts} / {ch.Index}");
            }
            catch (Exception e) { ok = false; Console.WriteLine($"抛出 {e.GetType().Name}: {e.Message}"); }
            finally { Host.RestartHook = null; Host.SelectProgramHook = null; Application.GameDir = null; try { Directory.Delete(root, true); } catch { } }
            Console.WriteLine($"多程序合集切程序：{(ok ? "全过 ✓" : "有不符 ✗")}");
            // 起过 Horizon 服务线程（前台线程），同 --execute-program-restart 显式退出
            Environment.Exit(ok ? 0 : 1);
            return ok ? 0 : 1;
        }
    }
}
