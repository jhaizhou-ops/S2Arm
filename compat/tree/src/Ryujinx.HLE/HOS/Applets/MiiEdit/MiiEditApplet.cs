using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS.Services.Am.AppletAE;
using System;

namespace Ryujinx.HLE.HOS.Applets.MiiEdit
{
    // Mii 编辑小程序（nn::mii 库小程序）的零界面应答：按用户在编辑器里直接返回处理，回「取消」。
    // 输入 = 公共参数（0x20）+ MiiLaAppletInput（0x100：版本 s32、模式 u32 …）；
    // 输出按模式取结构：新建 / 编辑 Mii（模式 4 / 5）回 AppletOutputForCharInfoEditing（0x80：结果 u32 + CharInfo 0x58 + 留空），
    // 其余模式回 AppletOutput（0x20：结果 u32 + 选中序号 s32 + 留空）。结果 1 = 取消（libnx mii_la.h 的 MiiLaAppletResult）。
    // 上游的 DummyApplet 只回 8 字节，游戏按结构读会越界（马车8 在此崩）
    internal class MiiEditApplet : IApplet
    {
        private const int CommonArgumentsSize = 0x20;
        private const uint ResultCancel = 1;

        private readonly Horizon _system;

        public event EventHandler AppletStateChanged;

        public MiiEditApplet(Horizon system)
        {
            _system = system;
        }

        public ResultCode Start(AppletSession normalSession, AppletSession interactiveSession)
        {
            uint mode = 0;
            int version = 0;
            int inputSize = 0;

            while (normalSession.TryPop(out byte[] item))
            {
                if (item.Length > CommonArgumentsSize && item.Length >= 8)
                {
                    version = BitConverter.ToInt32(item, 0);
                    mode = BitConverter.ToUInt32(item, 4);
                    inputSize = item.Length;
                }
            }

            byte[] output = new byte[mode is 4 or 5 ? 0x80 : 0x20];
            BitConverter.GetBytes(ResultCancel).CopyTo(output, 0);

            if (output.Length == 0x20)
            {
                BitConverter.GetBytes(-1).CopyTo(output, 4);   // 没选中任何 Mii
            }

            Logger.Info?.Print(LogClass.ServiceAm, $"MiiEdit 小程序自动应答：输入 {inputSize} 字节 版本 {version} 模式 {mode} → 回「取消」（{output.Length} 字节）");

            normalSession.Push(output);
            AppletStateChanged?.Invoke(this, null);
            _system.ReturnFocus();

            return ResultCode.Success;
        }
    }
}
