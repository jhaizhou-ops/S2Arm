using Ryujinx.HLE.HOS.Services.SurfaceFlinger;
using S2A.Gfx;
using System;
using System.Reflection;

static class Program
{
    static readonly MethodInfo EffectiveSwapIntervalMethod = typeof(S2AFramePacing).Assembly
        .GetType("Ryujinx.HLE.HOS.Services.SurfaceFlinger.SurfaceFlinger")
        ?.GetMethod("S2AEffective", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("SurfaceFlinger.S2AEffective not found");

    static void Check(bool condition, string description)
    {
        if (!condition) throw new InvalidOperationException(description);
    }

    static void Equal(int expected, int actual, string description) =>
        Check(expected == actual, $"{description}: expected {expected}, got {actual}");

    static void Near(float expected, float actual, string description) =>
        Check(Math.Abs(expected - actual) < 0.000001f, $"{description}: expected {expected}, got {actual}");

    static int EffectiveSwapInterval(int minimum, int requested)
    {
        S2AFramePacing.MinSwapInterval = minimum;
        return (int)EffectiveSwapIntervalMethod.Invoke(null, [requested]);
    }

    static void Rejects(string value)
    {
        bool rejected = false;
        try { FramePacingPolicy.ParseLimit(value); }
        catch (ArgumentOutOfRangeException exception) { rejected = exception.ParamName == "configuredValue"; }
        Check(rejected, $"S2A_FPS={value} must be rejected");
    }

    static int Main()
    {
        Equal(0, FramePacingPolicy.ParseLimit(null), "unset S2A_FPS defaults to unlimited");
        Equal(0, FramePacingPolicy.ParseLimit("0"), "explicit unlimited setting");
        Equal(30, FramePacingPolicy.ParseLimit("30"), "30 FPS setting");
        Equal(60, FramePacingPolicy.ParseLimit("60"), "60 FPS setting");
        Equal(120, FramePacingPolicy.ParseLimit("120"), "120 FPS setting");
        Equal(24, FramePacingPolicy.ParseLimit("24"), "lowest accepted cap");
        Equal(144, FramePacingPolicy.ParseLimit("144"), "144 FPS setting");
        Equal(165, FramePacingPolicy.ParseLimit("165"), "165 FPS setting");
        Equal(240, FramePacingPolicy.ParseLimit("240"), "240 FPS setting");
        Equal(1000, FramePacingPolicy.ParseLimit("1000"), "highest accepted cap");
        Rejects("");
        Rejects("23");
        Rejects("1001");
        Rejects("-1");
        Rejects("+60");
        Rejects("60 ");
        Rejects("30abc");
        Rejects("display");
        Rejects("00000060");

        int min30 = FramePacingPolicy.SwapIntervalFloor(30, 60);
        int min60 = FramePacingPolicy.SwapIntervalFloor(60, 60);
        int min120 = FramePacingPolicy.SwapIntervalFloor(120, 60);
        int minUnlimited = FramePacingPolicy.SwapIntervalFloor(0, 60);
        Equal(2, min30, "30 FPS production swap interval floor");
        Equal(1, min60, "60 FPS production swap interval floor");
        Equal(1, min120, "120 FPS leaves 60 Hz guest timing unchanged");
        Equal(0, minUnlimited, "unlimited removes the extra production floor");
        Equal(1, FramePacingPolicy.SwapIntervalFloor(144, 60), "144 FPS leaves 60 Hz guest timing unchanged");
        Equal(1, FramePacingPolicy.SwapIntervalFloor(40, 60), "40 FPS floor is 1 (rounding 1.5 up to 2 would cap the producer at 30)");
        Equal(2, FramePacingPolicy.SwapIntervalFloor(24, 60), "24 FPS floor is 2 (30 FPS producer, presentation capped at 24)");
        Near(1f / 144, FramePacingPolicy.MinimumPresentationInterval(0f, 144), "144 FPS presentation floor for swapInterval=0");

        Equal(0, EffectiveSwapInterval(min30, 0), "30 FPS keeps guest swapInterval=0");
        Equal(2, EffectiveSwapInterval(min30, 1), "30 FPS throttles guest swapInterval=1 at production");
        Equal(3, EffectiveSwapInterval(min30, 3), "30 FPS preserves a slower guest interval");
        Equal(1, EffectiveSwapInterval(min60, 1), "60 FPS preserves guest 60 Hz timing");
        Equal(0, EffectiveSwapInterval(min120, 0), "120 FPS keeps guest swapInterval=0");
        Equal(1, EffectiveSwapInterval(min120, 1), "120 FPS does not speed up a 60 Hz guest");
        Equal(1, EffectiveSwapInterval(minUnlimited, 1), "unlimited preserves guest swapInterval=1");
        Equal(3, EffectiveSwapInterval(minUnlimited, 3), "unlimited preserves a slower guest interval");

        Near(1f / 30, FramePacingPolicy.MinimumPresentationInterval(0, 30), "30 FPS caps swapInterval=0 presentation");
        Near(1f / 30, FramePacingPolicy.MinimumPresentationInterval(2f / 60, 30), "30 FPS presentation interval");
        Near(3f / 60, FramePacingPolicy.MinimumPresentationInterval(3f / 60, 30), "30 FPS preserves slower guest timing");
        Near(1f / 60, FramePacingPolicy.MinimumPresentationInterval(0, 60), "60 FPS caps swapInterval=0 presentation");
        Near(1f / 120, FramePacingPolicy.MinimumPresentationInterval(0, 120), "120 FPS caps swapInterval=0 presentation");
        Near(1f / 60, FramePacingPolicy.MinimumPresentationInterval(1f / 60, 120), "120 FPS preserves 60 Hz guest timing");
        Near(0, FramePacingPolicy.MinimumPresentationInterval(0, 0), "unlimited preserves guest swapInterval=0");
        Near(3f / 60, FramePacingPolicy.MinimumPresentationInterval(3f / 60, 0), "unlimited preserves slower guest timing");

        Console.WriteLine("Frame pacing policy and SurfaceFlinger swap interval behavior passed.");
        return 0;
    }
}
