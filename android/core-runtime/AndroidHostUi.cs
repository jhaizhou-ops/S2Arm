using Ryujinx.HLE.HOS.Applets;
using S2A.Services;
using System;

namespace S2A.Android.Aot
{
    // Android 宿主界面直接登记共用 HostUi（services/S2A.Services/Host.cs），与 iOS 同一套策略：
    // 错误提示 / 选用户 / 手柄设置 / 软键盘四个小程序零配置自动应答，其余未接界面报红一次后按契约回包、不停局。
    // 平台只注册真正平台相关的部分：前台软键盘经 HostApi 有界 broker 弹真实输入框
    // （AndroidKeyboard → ExchangeUi → HostKeyboard；取消 / 宿主撤销回 null = 不确认）。
    internal static class AndroidHostUi
    {
        internal static HostUi Create(AndroidHostApi host = null)
            => new() { SoftwareKeyboard = host == null ? null : args => Keyboard(host, args) };

        private static string Keyboard(AndroidHostApi host, SoftwareKeyboardUIArgs args)
        {
            try
            {
                AndroidKeyboard.Outcome outcome = AndroidKeyboard.Show(host.ExchangeUi, (uint)args.KeyboardMode, args.HeaderText,
                    args.SubtitleText, args.GuideText, args.InitialText, args.SubmitText,
                    args.StringLengthMin, args.StringLengthMax, out string text);
                Console.Error.WriteLine("[Android keyboard] outcome=" + outcome);
                return outcome == AndroidKeyboard.Outcome.Accepted ? text : null;
            }
            catch (Exception error)
            {
                Red.Report("Android 软键盘应答失败", error.Message);
                return null;
            }
        }
    }
}
