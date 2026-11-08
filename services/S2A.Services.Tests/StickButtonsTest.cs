using System.Threading;
using Ryujinx.HLE.HOS.Services.Hid;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private static int _stickDx;
        private static void TiltLeft(ref GamepadInput input) => input.LStick.Dx = _stickDx;

        // 摇杆四向按键位：只给模拟摇杆（触屏 / 外接手柄 / 摇杆探测都是这样），共享内存里的按键也要有 StickLLeft（位 16）。
        //   期望照 Ryujinx Hid.UpdateStickButtons：|Dx| 超过 short.MaxValue / 2 才置位 —— 满偏左置位、三成偏不置、回中不置
        private static void StickButtonsTest()
        {
            ulong Bits() => (ulong)Host.Device.Hid.SharedMemory.Npads[(int)PlayerIndex.Player1].InternalState.FullKey.GetCurrentEntryRef().Buttons;
            ulong Settle(int dx)
            {
                _stickDx = dx;
                ulong want = dx < -short.MaxValue / 2 ? 1UL << 16 : 0;
                for (int k = 0; k < 100 && (Bits() & (1UL << 16)) != want; k++) Thread.Sleep(10);
                Thread.Sleep(50);
                return (Bits() >> 16) & 1;
            }

            InputPump.SetPrimary(Host.Device, PlayerIndex.Player1, ControllerType.ProController);
            InputPump.InputHook = &TiltLeft;
            string got = $"{Settle(-short.MaxValue)} / {Settle(-short.MaxValue * 3 / 10)} / {Settle(0)}";
            InputPump.InputHook = null;
            InputPump.SetPrimary(Host.Device, PlayerIndex.Handheld, ControllerType.Handheld);   // 还原，不影响后面的用例

            Check("摇杆四向按键位：只给左摇杆模拟量 → StickLLeft 位（满偏 / 三成偏 / 回中）", "1 / 0 / 0", got);
        }
    }
}
