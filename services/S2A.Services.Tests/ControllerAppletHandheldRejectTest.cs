using Ryujinx.HLE.HOS.Applets;
using Ryujinx.HLE.HOS.Services.Am.AppletAE;
using Ryujinx.HLE.HOS.Services.Hid;
using System;
using System.Runtime.InteropServices;

namespace S2A.Services.Tests
{
    // 手柄设置小程序：游戏紧接着用同样参数再拉起 = 上次答的掌机格游戏不收（11-05 普查 c1105_r4 超级舞动 瓦力欧制造 010045B018EC2000：
    //   样式 Handheld + JoyconPair、人数 1–1、接管连接 1，每帧重开一次、整局 14949 次，每次都答「1 人、掌机格 32」）。
    //   真机上这时玩家照游戏提示拆下两只 Joy-Con 分握（双 Joy-Con 接在 Player1），这里同样改接游戏收的非掌机样式。
    //   期望按 hid 语义手写：第一次 → 1 人、NpadId 0x20、掌机格样式 Handheld(2)；同参数第二次 → 1 人、NpadId 0（No1）、Player1 样式 JoyDual(4)、掌机格不再连着。
    //   修前：第二次仍是 1 人、0x20、Player1 样式 0
    public static unsafe partial class Program
    {
        private static (int count, uint id) ShowControllerSupport(uint styles)
        {
            var normal = new AppletSession();
            AppletSession game = normal.GetConsumer();
            game.Push(new byte[0x20]);   // 公共参数（本小程序不读内容）
            var priv = new ControllerSupportArgPrivate { PrivateSize = 20, ArgSize = 1072, Mode = ControllerSupportMode.ShowControllerSupport, NpadStyleSet = styles, NpadJoyHoldType = 1 };
            byte[] privBytes = new byte[Marshal.SizeOf<ControllerSupportArgPrivate>()];
            MemoryMarshal.Write(privBytes, in priv);
            game.Push(privBytes);
            byte[] arg = new byte[1072];
            arg[0] = 1; arg[1] = 1; arg[2] = 1;   // 人数下限 1、上限 1、接管连接 1（同瓦力欧日志「Arg 1 1 1 0」）
            game.Push(arg);

            new ControllerApplet(Host.Device.System).Start(normal, new AppletSession());

            byte[] res = game.TryPop(out byte[] r) ? r : new byte[12];
            return ((sbyte)res[0], BitConverter.ToUInt32(res, 4));
        }

        private static void ControllerAppletHandheldReject()
        {
            var npads = Host.Device.Hid.Npads;
            var system = Host.Device.System;
            npads.ClearSupportedPlayers();
            foreach (PlayerIndex p in new[] { PlayerIndex.Player1, PlayerIndex.Player2, PlayerIndex.Player3, PlayerIndex.Player4, PlayerIndex.Player5,
                                              PlayerIndex.Player6, PlayerIndex.Player7, PlayerIndex.Player8, PlayerIndex.Handheld })
                npads.SetSupportedPlayer(p);
            InputPump.SetPrimary(Host.Device, PlayerIndex.Handheld, ControllerType.Handheld);
            string Style(PlayerIndex i) => ((uint)Host.Device.Hid.SharedMemory.Npads[(int)i].InternalState.StyleSet).ToString();
            for (int i = 0; i < 20 && Style(PlayerIndex.Handheld) != "2"; i++) System.Threading.Thread.Sleep(10);

            const uint styles = (uint)(ControllerType.Handheld | ControllerType.JoyconPair);
            var (c1, id1) = ShowControllerSupport(styles);
            string hh1 = Style(PlayerIndex.Handheld);
            var (c2, id2) = ShowControllerSupport(styles);
            // 掌机格断开由采样泵下一拍的 Remap 写进共享内存（小程序重验只看配置表，不等这一拍）
            for (int i = 0; i < 20 && Style(PlayerIndex.Handheld) != "0"; i++) System.Threading.Thread.Sleep(10);
            string p1 = Style(PlayerIndex.Player1), hh2 = Style(PlayerIndex.Handheld);

            InputPump.SetPrimary(Host.Device, PlayerIndex.Handheld, ControllerType.Handheld);   // 还原，不影响后面的用例
            while (system.AppletState.Messages.TryDequeue(out _)) { }
            Check("手柄设置小程序：同参数重开 = 掌机格不收 → 改接 Player1 双 Joy-Con（人数 / NpadId / 样式）",
                  "1 0x20 掌机 2 / 1 0x0 Player1 4 掌机 0",
                  $"{c1} 0x{id1:X} 掌机 {hh1} / {c2} 0x{id2:X} Player1 {p1} 掌机 {hh2}");
        }
    }
}
