using Ryujinx.HLE.HOS.Applets;
using Ryujinx.HLE.HOS.Services.Am.AppletAE;
using System;
using System.Runtime.InteropServices;

namespace S2A.Services.Tests
{
    // 手柄小程序非手柄设置模式结束时把焦点还给游戏（11-02 普查 Let's Get Fit：7 分钟处 ShowControllerStrapGuide 后不再有任何调用、
    //   「安全区」页任何键都没反应）。真机小程序结束游戏收到回到焦点的消息，同本小程序 ShowControllerSupport 路径与其余小程序（ReturnFocus）。
    //   期望按 am 语义手写：腕带说明 / 固件更新模式各拉起一次 → 游戏端读到一条结果、消息队列多出 FocusStateChanged(15) + ChangeIntoForeground(1)。
    //   修前：结果有、消息没有（这条路径没调 ReturnFocus）
    public static unsafe partial class Program
    {
        private static void ControllerAppletFocus()
        {
            var system = Host.Device.System;

            foreach (ControllerSupportMode mode in new[] { ControllerSupportMode.ShowControllerStrapGuide, ControllerSupportMode.ShowControllerFirmwareUpdate })
            {
                while (system.AppletState.Messages.TryDequeue(out _)) { }

                var normal = new AppletSession();
                AppletSession game = normal.GetConsumer();   // 游戏那一端：往小程序推参数、从这里取结果
                game.Push(new byte[0x20]);   // 公共参数（本小程序不读内容）
                var priv = new ControllerSupportArgPrivate { PrivateSize = 20, ArgSize = 1072, Mode = mode, NpadStyleSet = 4, NpadJoyHoldType = 0 };
                byte[] privBytes = new byte[Marshal.SizeOf<ControllerSupportArgPrivate>()];
                MemoryMarshal.Write(privBytes, in priv);
                game.Push(privBytes);

                new ControllerApplet(system).Start(normal, new AppletSession());

                string msgs = string.Join(",", system.AppletState.Messages.ToArray());
                Check($"手柄小程序 {mode} 结束 → 结果条数 / 焦点消息", "1 / FocusStateChanged,ChangeIntoForeground",
                      $"{(game.TryPop(out _) ? 1 : 0) + (game.TryPop(out _) ? 1 : 0)} / {msgs}");
            }

            while (system.AppletState.Messages.TryDequeue(out _)) { }
        }
    }
}
