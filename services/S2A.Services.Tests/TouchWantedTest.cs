using System.Runtime.InteropServices;

namespace S2A.Services.Tests
{
    // 11-01 审计 P1-3：游戏启用了触屏（ActivateTouchScreen → Hid.Touchscreen.Active）时，HID 线程把这件事告诉 iOS 壳（ios/vpad.m s2a_vpad_touch_wanted），
    //   壳在按键方案下提示一次怎么切「仅触屏操作」。壳返回 0 = 还没出首帧（加载页挡着，提示看不见），下一拍再问；返回 1 = 收下了，之后不再问。
    //   期望（只看调用约定即可写出）：没启用触屏 → 不问（0 次）；启用后壳回 0 → 每拍都问（问 3 拍 = 3 次）；壳回 1 → 再问 1 次后清空，之后启用着也不再问（共 4 次）
    public static unsafe partial class Program
    {
        private static int _touchWantedCalls, _touchWantedReturn;
        [UnmanagedCallersOnly]
        private static int TouchWantedStub() { _touchWantedCalls++; return _touchWantedReturn; }

        [SoloTest("--touch-wanted")]
        private static int TouchWanted()
        {
            InputPump.VPadTouchWanted = &TouchWantedStub;
            InputPump.OfferTouchWanted(false);
            int inactive = _touchWantedCalls;
            _touchWantedReturn = 0;
            for (int i = 0; i < 3; i++) InputPump.OfferTouchWanted(true);
            int beforeFrame = _touchWantedCalls;
            _touchWantedReturn = 1;
            InputPump.OfferTouchWanted(true);
            InputPump.OfferTouchWanted(true);
            InputPump.OfferTouchWanted(true);
            bool cleared = InputPump.VPadTouchWanted == null;
            System.Console.WriteLine($"触屏启用告知 iOS 壳：未启用不问 / 首帧前每拍问 / 收下后不再问 期望 0 / 3 / 4 / True → 实际 {inactive} / {beforeFrame} / {_touchWantedCalls} / {cleared}");
            return inactive == 0 && beforeFrame == 3 && _touchWantedCalls == 4 && cleared ? 0 : 1;
        }
    }
}
