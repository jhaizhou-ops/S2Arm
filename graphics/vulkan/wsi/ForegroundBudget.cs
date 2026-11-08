using System;

namespace S2Arm.Backends.Vulkan.Wsi;

// Continuous-foreground budget measured on the producer lifecycle epoch — the same clock
// model S2Arm.Backends.Vulkan.Runtime.StartupWait uses for its 25 ms event slices, split out
// for a caller that drives its own poll loop. The epoch is nonnegative while foreground and
// changes on every lifecycle transition; it is -1 while backgrounded. Only foreground
// milliseconds on one unchanged epoch charge the budget, so an Android process freeze or a
// pause/resume starts a fresh allowance instead of expiring a deadline armed before the freeze.
// The epoch is sampled on every Expired call: sampling once at Begin cannot observe a
// background transition or a new window generation that lands while waiting.
internal struct ForegroundBudget
{
    private long _previous, _epoch, _used;

    public void Begin(Func<long> lifecycle, long now)
    {
        _previous = now;
        _epoch = lifecycle();
        _used = 0;
    }

    public bool Expired(Func<long> lifecycle, long now, int budgetMilliseconds)
    {
        long current = lifecycle();
        if (current >= 0 && current == _epoch) _used += Math.Max(0, now - _previous);
        else _used = 0;
        _previous = now;
        _epoch = current;
        return _used >= budgetMilliseconds;
    }
}
