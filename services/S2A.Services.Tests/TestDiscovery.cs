// 服务层单测自动发现（10-30 列车线：Program.cs 与 services/test.sh 的手登清单是列车冲突头号文件之一）。
// 新加单测不改 Program.cs、不改 test.sh：写在自己的文件里、标特性即可。
//   [SoloTest("--模式")]                 独立进程跑、在服务层启动（Host.Boot）之前：static int 方法，返回 0 = 通过；test.sh 按 --list-modes 逐个起进程
//   [SoloTest("--模式", Booted = true)]  独立进程跑、要服务层夹具（Boot、TLS、游戏内存已就绪）：static void 方法，用 Check(...) 记行，Program 统一打表判退出码
//   [SvcCase]                            默认整套里跑（Run() 与 LDN 用例之后、收局之前）：static void 方法，用 Check(...) 记行；按方法名排序执行
// 本工程在 NativeAOT 发布版下整程序集保留（S2A.Services.Tests.csproj 的 TrimmerRootAssembly），反射找得到这些方法。
using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;

namespace S2A.Services.Tests
{
    [AttributeUsage(AttributeTargets.Method)]
    public sealed class SoloTestAttribute(string mode) : Attribute
    {
        public string Mode { get; } = mode;
        public bool Booted { get; init; }
    }

    [AttributeUsage(AttributeTargets.Method)]
    public sealed class SvcCaseAttribute : Attribute { }

    static class TestDiscovery
    {
        // 10-30 前在 Program.Main / services/test.sh 里手登的独立模式（原样冻结，新的不要加这里，标 [SoloTest]）
        public static readonly string[] LegacyModes =
        [
            "--apple-shutdown-thread", "--horizon-merge-lifecycle", "--account-lifetime", "--audio-lifetime", "--arp-application", "--arp-capacity",
            "--configuration", "--legacy-environment", "--host-configuration", "--host-startup-retry", "--exports-startup-retry",
            "--exports-zone-race", "--exports-zone-cleanup-fail", "--romfs-symlink", "--screen-aspect", "--input-lifetime", "--inflight-close",
            "--ipc-allocation", "--domain-errors", "--bsd-poll", "--ldn-room-count", "--ldn-ip-wrap", "--nvas-initex", "--ldn-proxy-wake",
            "--ldn-synthetic-application",
        ];

        static readonly MethodInfo[] All = typeof(TestDiscovery).Assembly.GetTypes()
            .SelectMany(t => t.GetMethods(BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.DeclaredOnly)).ToArray();

        public static IEnumerable<(SoloTestAttribute A, MethodInfo M)> Solo() =>
            All.Select(m => (A: m.GetCustomAttribute<SoloTestAttribute>(), M: m)).Where(x => x.A != null).OrderBy(x => x.A.Mode, StringComparer.Ordinal);

        public static IEnumerable<MethodInfo> Cases() =>
            All.Where(m => m.GetCustomAttribute<SvcCaseAttribute>() != null).OrderBy(m => m.DeclaringType!.FullName + "." + m.Name, StringComparer.Ordinal);

        // test.sh 用：冻结的老模式 + 标了特性的新模式，一行一个
        public static IEnumerable<string> Modes() => LegacyModes.Concat(Solo().Select(x => x.A.Mode));

        // 启动前的独立模式：找到就跑并给退出码
        public static bool TryRunPreBoot(string mode, out int rc)
        {
            rc = 0;
            foreach ((SoloTestAttribute a, MethodInfo m) in Solo())
            {
                if (a.Booted || a.Mode != mode) continue;
                rc = (int)m.Invoke(null, null)!;
                return true;
            }
            return false;
        }

        // 要夹具的独立模式：找到就跑（记行由调用方统一打表）
        public static bool TryRunBooted(string mode)
        {
            foreach ((SoloTestAttribute a, MethodInfo m) in Solo())
            {
                if (!a.Booted || a.Mode != mode) continue;
                m.Invoke(null, null);
                return true;
            }
            return false;
        }

        public static bool IsBootedMode(string mode) => Solo().Any(x => x.A.Booted && x.A.Mode == mode);

        public static void RunCases()
        {
            foreach (MethodInfo m in Cases()) m.Invoke(null, null);
        }

        // 发现机制自检（默认整套里跑）：模式不重名（含与冻结清单）、签名合规
        [SvcCase]
        static void DiscoverySelfCheck()
        {
            List<string> modes = Modes().ToList();
            string dup = string.Join(" ", modes.GroupBy(x => x).Where(g => g.Count() > 1).Select(g => g.Key));
            Program.Check("单测自动发现：独立模式不重名（冻结清单 + [SoloTest]）", "无重名", dup.Length == 0 ? "无重名" : dup);
            string bad = string.Join(" ", Solo().Where(x => x.A.Booted ? x.M.ReturnType != typeof(void) : x.M.ReturnType != typeof(int))
                .Concat(Solo().Where(x => x.M.GetParameters().Length != 0)).Select(x => x.M.Name).Distinct());
            bad += string.Join(" ", Cases().Where(m => m.ReturnType != typeof(void) || m.GetParameters().Length != 0).Select(m => m.Name));
            Program.Check("单测自动发现：[SoloTest] 启动前 int()、要夹具 void()，[SvcCase] void()", "全部合规", bad.Length == 0 ? "全部合规" : bad);
        }

        // 发现机制自身的独立模式样例（也验证 test.sh 按 --list-modes 起进程这条路）
        [SoloTest("--discovery-selftest")]
        static int DiscoveryPreBootSelfTest()
        {
            int n = Solo().Count();
            Console.WriteLine($"单测自动发现：[SoloTest] {n} 个、[SvcCase] {Cases().Count()} 个、冻结老模式 {LegacyModes.Length} 个");
            return n >= 1 ? 0 : 1;
        }
    }
}
