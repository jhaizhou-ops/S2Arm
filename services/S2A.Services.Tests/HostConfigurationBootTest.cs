using System;
using System.IO;
using Ryujinx.Audio.Backends.Dummy;
using Ryujinx.HLE.HOS.SystemState;
using Ryujinx.Memory;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private static void AttachTestTimeZone(string game)
        {
            string source = Environment.GetEnvironmentVariable("S2A_TZDATA");
            if (string.IsNullOrEmpty(source) || !File.Exists(Path.Combine(source, "binaryList.txt")))
                throw new InvalidOperationException("测试缺少宿主生成的 S2A_TZDATA");
            string systems = Path.Combine(game, "systemdata");
            Directory.CreateDirectory(systems);
            Directory.CreateSymbolicLink(Path.Combine(systems, "010000000000080E"), source);
        }

        private static int HostConfigurationBootTest()
        {
            string root = Path.Combine(Path.GetTempPath(), $"s2a_host_config_{Environment.ProcessId}");
            Directory.CreateDirectory(root);
            string oldSaveDir = Environment.GetEnvironmentVariable("S2A_SAVE_DIR");
            try
            {
                FakeNative.Install();
                string game = Path.Combine(root, "game"); Directory.CreateDirectory(game);
                AttachTestTimeZone(game);
                string state = Path.Combine(root, "state");
                var ui = new HostUi();
                ulong requested = 0;
                // #1073 平台字段：存档根与状态目录分开、系统语言标签与装配给的枚举不同、足迹读数是平台委托
                //   撤掉共享侧消费 → 语言回 Japanese、足迹走 libSystem（Linux -1 / Mac 真值）、数据根回 state，三项各自变红
                string save = Path.Combine(root, "save"); Directory.CreateDirectory(save);
                var config = new HostConfiguration(game, state, SystemLanguage.Japanese, RegionCode.Japan, "UTC", true, ui,
                    size => { requested = size; return new MemoryBlock(size, MemoryAllocationFlags.Reserve); },
                    saveDirectory: save, systemLanguageTag: () => "zh-Hans-CN", memoryFootprint: () => 28672);
                Host.Boot(new StubRenderer(), new DummyHardwareDeviceDriver(), state, config);
                // An inherited legacy seed path must not replace platform-owned persistent state.
                Environment.SetEnvironmentVariable("S2A_SAVE_DIR", Path.Combine(root, "seed"));
                bool seedDisabled = Saves.Dir() == null;
                Console.WriteLine($"显式配置忽略继承的旧存档种子路径：{seedDisabled} {(seedDisabled ? "✓" : "✗")}");
                bool platform = Host.Language == SystemLanguage.SimplifiedChinese && MemDiag.Footprint() == 28672 &&
                    Path.TrimEndingDirectorySeparator(Ryujinx.Common.Configuration.AppDataManager.BaseDirPath) == Path.GetFullPath(save);
                Console.WriteLine($"平台字段：语言跟系统标签 {Host.Language}、足迹走平台委托 {MemDiag.Footprint()}、数据根 {Ryujinx.Common.Configuration.AppDataManager.BaseDirPath} {(platform ? "✓" : "✗")}");
                bool ok = seedDisabled && platform && Host.Docked &&
                    Host.Device.Configuration.SystemLanguage == SystemLanguage.SimplifiedChinese &&
                    Host.Device.Configuration.Region == RegionCode.Japan && Host.Device.Configuration.EnableDockedMode &&
                    ReferenceEquals(Host.Device.UIHandler, ui) && requested > 0 && Host.Device.Memory.Size == requested &&
                    Ryujinx.HLE.S2AHooks.TimeZoneDataDir == Path.Combine(game, "systemdata", "010000000000080E");
                Console.WriteLine($"显式配置真实 Host.Boot：语言、地区、Docked、UI、服务内存工厂 {(ok ? "✓" : "✗")}");
                return ok ? 0 : 1;
            }
            finally { Environment.SetEnvironmentVariable("S2A_SAVE_DIR", oldSaveDir); try { Directory.Delete(root, true); } catch { } }
        }
    }
}
