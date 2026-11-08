using System;
using System.Threading;

namespace S2Arm.Backends.Vulkan.Runtime;

// Startup has a bounded continuous-foreground budget. Android may freeze the whole process in background;
// the producer epoch detects a pause/resume even if both samples happen after foregrounding.
internal static class StartupWait
{
    public static bool Wait(ManualResetEventSlim ready, Func<long> lifecycle, int budgetMilliseconds,
        Func<long> clock = null)
    {
        ArgumentNullException.ThrowIfNull(ready);
        ArgumentNullException.ThrowIfNull(lifecycle);
        if (budgetMilliseconds <= 0) throw new ArgumentOutOfRangeException(nameof(budgetMilliseconds));
        clock ??= () => Environment.TickCount64;
        long previous = clock(), epoch = lifecycle(), used = 0;
        while (!ready.Wait(25))
        {
            long now = clock(), current = lifecycle();
            if (current >= 0 && current == epoch) used += Math.Max(0, now - previous);
            else used = 0;
            if (used >= budgetMilliseconds) return false;
            previous = now; epoch = current;
        }
        return true;
    }
}
