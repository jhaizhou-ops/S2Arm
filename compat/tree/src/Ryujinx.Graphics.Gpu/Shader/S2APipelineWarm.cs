using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.GAL.Multithreading;
using System;
using System.Collections.Generic;
using System.Diagnostics;

namespace Ryujinx.Graphics.Gpu.Shader
{
    /// <summary>
    /// S2A: one shader cache group the loading-screen warm may materialize.
    /// </summary>
    internal interface IS2APipelineWarmGroup
    {
        /// <summary>
        /// True when the group still has a lazy program listed in the pack warm table.
        /// </summary>
        bool S2AContainsWarm(HashSet<int> warm);

        /// <summary>
        /// Materializes the group and returns the host programs whose background pipeline
        /// prebuild the warm waits for.
        /// </summary>
        IEnumerable<IProgram> S2AMaterializeHostPrograms();
    }

    /// <summary>
    /// S2A (loading-screen pipeline warm): materializes the route programs listed in the pack
    /// warm table and waits for their background pipelines before the first draw.
    /// It runs only on backends that disabled host program prefetch (Android Vulkan); the
    /// Apple generic path keeps its own warm start untouched and must not enter this path.
    /// The whole batch shares one wait budget, so a slow driver cannot turn the loading screen
    /// into "programs × per-program timeout".
    /// </summary>
    internal static class S2APipelineWarm
    {
        /// <summary>Per-program wait bound.</summary>
        internal const int PerProgramTimeoutMs = 10_000;

        /// <summary>
        /// Whole-batch wait bound. The measured 8E route warm was ~2 s for 200 programs; the
        /// budget leaves an order of magnitude of headroom and still stops a stuck driver.
        /// </summary>
        internal const int TotalBudgetMs = 30_000;

        internal sealed class Result
        {
            public bool Ran;
            public bool SkippedByBackend;
            public int Groups;
            public int Programs;
            public int Waited;
            public int Failed;
            public bool BudgetExhausted;
            public double Milliseconds;
        }

        /// <summary>
        /// Backend policy behind the threaded renderer wrapper; null when the backend has no policy.
        /// </summary>
        internal static IHostProgramCachePolicy S2APolicy(IRenderer renderer) =>
            (renderer is ThreadedRenderer threaded ? threaded.BaseRenderer : renderer) as IHostProgramCachePolicy;

        /// <summary>
        /// True only for backends that disabled host program prefetch (Android Vulkan). Apple's
        /// renderer has no policy and keeps the historical prefetch plus its own warm start.
        /// </summary>
        internal static bool S2AEnabled(IHostProgramCachePolicy policy) =>
            policy is { DisableHostProgramPrefetch: true };

        /// <summary>
        /// Runs the warm. The caller logs the returned counters; nothing here reports success for
        /// programs that were skipped, timed out or cut off by the budget.
        /// </summary>
        internal static Result Run(
            IHostProgramCachePolicy policy,
            HashSet<int> warm,
            IEnumerable<IS2APipelineWarmGroup> groups,
            int totalBudgetMs = TotalBudgetMs,
            int perProgramTimeoutMs = PerProgramTimeoutMs)
        {
            ArgumentNullException.ThrowIfNull(groups);
            ArgumentOutOfRangeException.ThrowIfLessThan(totalBudgetMs, 1);
            ArgumentOutOfRangeException.ThrowIfLessThan(perProgramTimeoutMs, 1);

            Result result = new();

            if (!S2AEnabled(policy))
            {
                result.SkippedByBackend = true;
                return result;
            }

            if (warm == null || warm.Count == 0)
            {
                return result;
            }

            result.Ran = true;

            long started = Stopwatch.GetTimestamp();
            long deadline = Environment.TickCount64 + totalBudgetMs;

            foreach (IS2APipelineWarmGroup group in groups)
            {
                if (Environment.TickCount64 >= deadline)
                {
                    result.BudgetExhausted = true;
                    break;
                }

                if (!group.S2AContainsWarm(warm))
                {
                    continue;
                }

                result.Groups++;

                foreach (IProgram program in group.S2AMaterializeHostPrograms())
                {
                    result.Programs++;

                    if (program is not IS2APipelineWarm warmable)
                    {
                        continue;
                    }

                    long remaining = deadline - Environment.TickCount64;
                    if (remaining <= 0)
                    {
                        result.BudgetExhausted = true;
                        break;
                    }

                    int timeout = (int)Math.Min(perProgramTimeoutMs, remaining);

                    if (warmable.S2AWaitForBackgroundPipeline(timeout))
                    {
                        result.Waited++;
                    }
                    else
                    {
                        result.Failed++;
                    }
                }

                if (result.BudgetExhausted)
                {
                    break;
                }
            }

            result.Milliseconds = Stopwatch.GetElapsedTime(started).TotalMilliseconds;
            return result;
        }
    }
}
