// 加载屏预热的后端门控与总等待预算单测（#1402 owner 第 2/3 条）。
// 被测：compat/tree/src/Ryujinx.Graphics.Gpu/Shader/S2APipelineWarm.cs（ShaderCache 调用同一入口）。
//   - 安卓 Vulkan 后端（IHostProgramCachePolicy.DisableHostProgramPrefetch = true）才实化热表分组并等待后台管线；
//   - 苹果通用路径（无策略 / 策略为 false）不实化、不等待——去掉后端判断时本用例必须红；
//   - 整批共用总预算：每个程序的等待不超过剩余预算，用尽后停止等待并标记（不假成功）。
// 渲染器 / 程序 / 分组都是桩，不建任何宿主资源；退出码 = 失败项数。
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu.Shader;
using System;
using System.Collections.Generic;
using System.Threading;

static class Program
{
    private static int _pass;
    private static int _fail;

    private static void Check(string name, bool ok, string detail = "")
    {
        if (ok) _pass++; else _fail++;
        Console.WriteLine($"{(ok ? "✓" : "✗")} {name}{(detail.Length > 0 ? "：" + detail : "")}");
    }

    private sealed class Policy : IHostProgramCachePolicy
    {
        public bool DisableHostProgramPrefetch { get; init; }

        public string HostProgramCacheDiscriminator => null;
    }

    private sealed class FakeProgram : IProgram, IS2APipelineWarm
    {
        private readonly bool _result;
        private readonly int _sleepMs;

        public int Waits;
        public int LastTimeoutMs;

        public FakeProgram(bool result = true, int sleepMs = 0)
        {
            _result = result;
            _sleepMs = sleepMs;
        }

        public bool S2AWaitForBackgroundPipeline(int timeoutMs)
        {
            Waits++;
            LastTimeoutMs = timeoutMs;
            if (_sleepMs > 0) Thread.Sleep(_sleepMs);
            return _result;
        }

        public ProgramLinkStatus CheckProgramLink(bool blocking) => ProgramLinkStatus.Success;

        public byte[] GetBinary() => null;

        public void Dispose() { }
    }

    // 不是 IS2APipelineWarm 的宿主程序：只计数，不等待。
    private sealed class PlainProgram : IProgram
    {
        public ProgramLinkStatus CheckProgramLink(bool blocking) => ProgramLinkStatus.Success;

        public byte[] GetBinary() => null;

        public void Dispose() { }
    }

    private sealed class Group : IS2APipelineWarmGroup
    {
        private readonly HashSet<int> _warm;
        private readonly IProgram[] _programs;

        public int Materialized;

        public Group(HashSet<int> warm, params IProgram[] programs)
        {
            _warm = warm;
            _programs = programs;
        }

        public bool S2AContainsWarm(HashSet<int> warm) => warm != null && _warm.Overlaps(warm);

        public IEnumerable<IProgram> S2AMaterializeHostPrograms()
        {
            Materialized++;
            return _programs;
        }
    }

    private static void AndroidBackendWarms()
    {
        Policy android = new() { DisableHostProgramPrefetch = true };
        HashSet<int> warm = [10, 11];
        FakeProgram warmable = new(result: true);
        Group hit = new([10], warmable, new PlainProgram());
        Group miss = new([20], new FakeProgram());

        S2APipelineWarm.Result r = S2APipelineWarm.Run(android, warm, [hit, miss]);

        Check("安卓后端：预热执行", r.Ran && !r.SkippedByBackend);
        Check("安卓后端：只实化命中热表的分组", r.Groups == 1 && hit.Materialized == 1 && miss.Materialized == 0,
            $"组 {r.Groups}、命中实化 {hit.Materialized}、未命中实化 {miss.Materialized}");
        Check("安卓后端：组内程序都计数、可等待的等一次", r.Programs == 2 && r.Waited == 1 && r.Failed == 0 && warmable.Waits == 1,
            $"程序 {r.Programs}、等待 {r.Waited}、失败 {r.Failed}");
    }

    private static void AppleBackendDoesNotWarm()
    {
        // 负控：苹果通用路径的后端没有 DisableHostProgramPrefetch（false / 无策略），预热必须完全不进入。
        foreach ((string name, IHostProgramCachePolicy policy) in new (string, IHostProgramCachePolicy)[]
        {
            ("策略为 false", new Policy { DisableHostProgramPrefetch = false }),
            ("无策略接口", null),
        })
        {
            FakeProgram warmable = new();
            Group hit = new([10], warmable);

            S2APipelineWarm.Result r = S2APipelineWarm.Run(policy, [10], [hit]);

            Check($"苹果后端（{name}）：不预热", !r.Ran && r.SkippedByBackend && r.Groups == 0 && r.Programs == 0,
                $"Ran {r.Ran}、跳过 {r.SkippedByBackend}、组 {r.Groups}、程序 {r.Programs}");
            Check($"苹果后端（{name}）：不实化、不等待", hit.Materialized == 0 && warmable.Waits == 0,
                $"实化 {hit.Materialized}、等待 {warmable.Waits}");
        }
    }

    private static void FailuresAreCounted()
    {
        Policy android = new() { DisableHostProgramPrefetch = true };
        FakeProgram failing = new(result: false);
        Group hit = new([10], failing);

        S2APipelineWarm.Result r = S2APipelineWarm.Run(android, [10], [hit]);

        Check("等待超时 / 失败单独计数，不记成功", r.Ran && r.Waited == 0 && r.Failed == 1 && !r.BudgetExhausted,
            $"等待 {r.Waited}、失败 {r.Failed}");
    }

    private static void PerProgramTimeoutIsCappedByBudget()
    {
        Policy android = new() { DisableHostProgramPrefetch = true };
        FakeProgram warmable = new(result: true);
        Group hit = new([10], warmable);

        S2APipelineWarm.Result r = S2APipelineWarm.Run(android, [10], [hit], totalBudgetMs: 100_000, perProgramTimeoutMs: 1234);

        Check("单程序等待不超过单程序上限", r.Waited == 1 && warmable.LastTimeoutMs == 1234, $"传入 {warmable.LastTimeoutMs} ms");
        Check("预算充足时不用尽", !r.BudgetExhausted);
    }

    private static void BudgetStopsTheBatch()
    {
        Policy android = new() { DisableHostProgramPrefetch = true };
        FakeProgram slow = new(result: true, sleepMs: 80);
        FakeProgram second = new(result: true);
        Group first = new([10], slow);
        Group next = new([20], second);

        S2APipelineWarm.Result r = S2APipelineWarm.Run(android, [10, 20], [first, next], totalBudgetMs: 50);

        Check("整批预算：首个等待按剩余预算封顶", slow.Waits == 1 && slow.LastTimeoutMs <= 50 && slow.LastTimeoutMs >= 1,
            $"传入 {slow.LastTimeoutMs} ms（总预算 50 ms）");
        Check("整批预算用尽后停止等待并标记", r.BudgetExhausted && second.Waits == 0 && r.Waited == 1,
            $"用尽 {r.BudgetExhausted}、后续等待 {second.Waits}、等待 {r.Waited}");
        Check("整批预算用尽后不再实化后续分组", next.Materialized == 0 && r.Groups == 1,
            $"后续实化 {next.Materialized}、组 {r.Groups}");
    }

    private static void MissingWarmListIsNotSuccess()
    {
        Policy android = new() { DisableHostProgramPrefetch = true };
        Group hit = new([10], new FakeProgram());

        S2APipelineWarm.Result r = S2APipelineWarm.Run(android, null, [hit]);

        Check("热表缺失：不执行、不实化", !r.Ran && !r.SkippedByBackend && hit.Materialized == 0);
    }

    private static int Main()
    {
        AndroidBackendWarms();
        AppleBackendDoesNotWarm();
        FailuresAreCounted();
        PerProgramTimeoutIsCappedByBudget();
        BudgetStopsTheBatch();
        MissingWarmListIsNotSuccess();

        Console.WriteLine($"pso_warm_gate：过 {_pass}、失败 {_fail}");
        return _fail;
    }
}
