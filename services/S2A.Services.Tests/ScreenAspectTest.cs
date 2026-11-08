using System;
using Ryujinx.HLE;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private static int TestScreen1080() => 1080;
        private static int TestScreenNegative() => -1;
        private static int ScreenAspectTest()
        {
            var oldW = Native.ScreenW;
            var oldH = Native.ScreenH;
            double oldAspect = S2ADisplay.Aspect;
            try
            {
                Native.ScreenW = &TestScreenWidth; Native.ScreenH = &TestScreenHeight;
                Exports.ApplyDisplayAspect(true);
                ulong fourThree = S2ADisplay.Width(720);
                Native.ScreenH = &TestScreen1080;
                Exports.ApplyDisplayAspect(true);
                ulong sixteenNine = S2ADisplay.Width(720);
                Native.ScreenH = &TestScreenHeight;
                Exports.ApplyDisplayAspect(false);
                ulong legacy = S2ADisplay.Width(720);
                Native.ScreenH = null;
                bool missingRejected = false;
                try { Exports.ApplyDisplayAspect(true); } catch (InvalidOperationException) { missingRejected = true; }
                Native.ScreenH = &TestScreenNegative;
                bool negativeRejected = false;
                try { Exports.ApplyDisplayAspect(true); } catch (InvalidOperationException) { negativeRejected = true; }
                Native.ScreenH = &TestScreenHeight;
                Native.ScreenW = null;
                bool missingWidthRejected = false;
                try { Exports.ApplyDisplayAspect(true); } catch (InvalidOperationException) { missingWidthRejected = true; }
                Native.ScreenW = &TestScreenNegative;
                bool negativeWidthRejected = false;
                try { Exports.ApplyDisplayAspect(true); } catch (InvalidOperationException) { negativeWidthRejected = true; }
                bool ok = fourThree == 1280 && sixteenNine == 1280 && legacy == 1280 && missingRejected && negativeRejected && missingWidthRejected && negativeWidthRejected;
                Console.WriteLine($"画面比例 4:3 / 16:9 / legacy / 缺高拒绝 / 负高拒绝 / 缺宽拒绝 / 负宽拒绝: {fourThree} / {sixteenNine} / {legacy} / {missingRejected} / {negativeRejected} / {missingWidthRejected} / {negativeWidthRejected} {(ok ? "✓" : "✗")}");
                return ok ? 0 : 1;
            }
            finally { Native.ScreenW = oldW; Native.ScreenH = oldH; S2ADisplay.Aspect = oldAspect; }
        }
    }
}
