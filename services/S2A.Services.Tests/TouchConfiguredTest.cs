using System;
using System.Text;
using System.Runtime.InteropServices;

namespace S2A.Services.Tests
{
    // 11-04 总指挥定（脑锻炼 010062200D392000 标题页只认触屏）：游戏经 hid 调 SetTouchScreenConfiguration（命令 1002，声明触屏 / 手写笔模式）
    //   → Ryujinx 记 Hid.Touchscreen.ConfiguredMode（补丁 hid-touch-config-mode）→ InputPump.OfferTouchConfigured 递给 iOS 壳 s2a_vpad_touch_configured 自动切仅触屏。
    //   期望（只看调用约定即可写出）：没调过 → 模式 -1、壳 0 次；经真 IPC 调 1002、配置首字节 2（Heat2 手写笔）→ 模式 2；
    //   壳回 0（首帧前）每拍都递（3 拍 = 3 次、每次递 2）；壳回 1 → 再递 1 次后清空，之后不再递（共 4 次）
    public static unsafe partial class Program
    {
        private static int _touchCfgCalls, _touchCfgReturn, _touchCfgLast = -99;
        [UnmanagedCallersOnly]
        private static int TouchConfiguredStub(int mode) { _touchCfgCalls++; _touchCfgLast = mode; return _touchCfgReturn; }

        [SoloTest("--touch-configured", Booted = true)]
        private static void TouchConfigured()
        {
            var ts = Host.Device.Hid.Touchscreen;
            InputPump.VPadTouchConfigured = &TouchConfiguredStub;
            int before = ts.ConfiguredMode;
            InputPump.OfferTouchConfigured(ts.ConfiguredMode);
            int undeclared = _touchCfgCalls;

            byte* port = _game;
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(port, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)port).Regs[1];
            Msg init = Msg.Cmif(0, Bytes(0L));
            init.SendPid = true;
            Call(sm, init);
            Reply gh = Call(sm, Msg.Cmif(1, Name8("hid")));
            uint hid = gh.Move.Count == 1 ? gh.Move[0] : 0;
            Reply r = Call(hid, Msg.Cmif(1002, Bytes(2L, 0L)));   // SetTouchScreenConfiguration：TouchScreenConfigurationForNx 首字节 = 模式 2（Heat2）
            int after = ts.ConfiguredMode;

            _touchCfgReturn = 0;
            for (int i = 0; i < 3; i++) InputPump.OfferTouchConfigured(ts.ConfiguredMode);
            int beforeFrame = _touchCfgCalls;
            _touchCfgReturn = 1;
            for (int i = 0; i < 3; i++) InputPump.OfferTouchConfigured(ts.ConfiguredMode);
            bool cleared = InputPump.VPadTouchConfigured == null;
            Check("游戏声明触屏配置 → 告知 iOS 壳（调前模式 / 没声明时壳次数 / IPC 结果 / 调后模式 / 首帧前次数 / 收下后总次数 / 递的模式 / 清空）",
                "-1 / 0 / 0 / 2 / 3 / 4 / 2 / True",
                $"{before} / {undeclared} / {r.Result} / {after} / {beforeFrame} / {_touchCfgCalls} / {_touchCfgLast} / {cleared}");
        }
    }
}
