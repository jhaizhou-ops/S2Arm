using Ryujinx.HLE.HOS.Applets;
using Ryujinx.HLE.HOS.Applets.SoftwareKeyboard;
using Ryujinx.HLE.UI;
using S2A.Services;
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

// Android 宿主界面 = 生产装配（AndroidHostUi.Create）原样跑。断言「不停局（不抛、不走 fatal owner）、
//   按共用实现口径报红、返回值与 iOS 共用 HostUi 一致」；夹具不建 HLE / 小程序会话，Red 计数经 Red.Total。
//   - 错误小程序 / 消息框 / 截图：共用零配置或报红继续（本文件）
//   - 前台软键盘挂点：经 HostFixture(ui: true) 的 broker 回调走通 AndroidKeyboard → ExchangeUi 全程，
//     确认 / 用户取消 / 宿主撤销 / 应答异常四种结局逐条断言；撤挂点回落零配置应答（负控模式 hostui-nohook 同一条必红）
//   - 手柄设置 / 选用户：要活会话（Host.Device + HID 共享内存），由共用侧 --hostui-applets 用例覆盖；
//     双人手柄由共用侧 TwoPadsTest 覆盖。本套件断言「登记的就是 HostUi 本体」——同一实现，结论直接搬用
internal static unsafe class HostUiTests
{
    private static int _uiMode;           // 0 应答 Accepted、1 应答 cancel、2 宿主撤销（Wait 回 -4）、3 Begin 拒收
    private static string _uiReply = "";
    internal static string UiRequest;     // 最近一次发给 broker 的 JSON（只判协议字段）
    internal static int UiBegins, UiWaits, UiCancels;

    private static bool NoThrow(Action call)
    {
        try { call(); return true; }
        catch { return false; }
    }

    private static void CheckAsyncTextInput(Action<bool, string> check, IHostUIHandler android)
    {
        // 模拟 Android 未登记 native 文本框的返回值，以及 Apple 已登记的异步路径；
        // 这是宿主夹具，不等同于在两类设备上打开系统键盘。
        Type type = typeof(HostUi).Assembly.GetType("S2A.Services.TextInput", throwOnError: true);
        var flags = System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic;
        var begin = type.GetField("BeginHook", flags);
        var cancel = type.GetField("CancelHook", flags);
        object oldBegin = begin.GetValue(null), oldCancel = cancel.GetValue(null);
        try
        {
            begin.SetValue(null, (Func<long, string, int>)((_, _) => 0));
            var androidAsync = (IAsyncTextInput)android;
            check(androidAsync.BeginTextInput(default, (_, _) => { }) == null, "安卓：异步输入未登记时回落同步 broker");

            begin.SetValue(null, (Func<long, string, int>)((_, _) => 1));
            cancel.SetValue(null, (Action<long>)(_ => { }));
            using var answered = new System.Threading.ManualResetEventSlim();
            bool? accepted = null;
            var apple = (IAsyncTextInput)new HostUi();
            IDisposable handle = apple.BeginTextInput(default, (ok, _) => { accepted = ok; answered.Set(); });
            check(handle != null, "Apple 默认 HostUi：异步输入已登记时获得句柄");
            handle.Dispose();
            check(answered.Wait(TimeSpan.FromSeconds(2)) && accepted == false, "Apple 默认 HostUi：取消异步输入后回调 false");
        }
        finally { begin.SetValue(null, oldBegin); cancel.SetValue(null, oldCancel); }
    }

    // HostFixture(ui: true) 的三条 broker 回调：Begin 收请求发单号、Wait 按 _uiMode 给应答、Cancel 记收回。
    //   应答体即生产约定 {"version":1,"type":"software-keyboard","status":"ok|cancel","text":…}
    [UnmanagedCallersOnly] internal static int UiBegin(nint host, byte* data, ulong* id)
    {
        if (_uiMode == 3) return -7;
        UiBegins++;
        UiRequest = Marshal.PtrToStringUTF8((nint)data);
        *id = 42;
        return 0;
    }

    [UnmanagedCallersOnly] internal static int UiWait(nint host, ulong id, int timeout, byte* output, nuint cap, nuint* length)
    {
        UiWaits++;
        if (_uiMode == 2) return -4;
        byte[] reply = Encoding.UTF8.GetBytes(_uiReply + "\0");
        reply.AsSpan().CopyTo(new Span<byte>(output, (int)cap));
        *length = (nuint)(reply.Length - 1);
        return 0;
    }

    [UnmanagedCallersOnly] internal static int UiCancel(nint host, ulong id)
    {
        UiCancels++;
        return 0;
    }

    internal static void Run(Action<bool, string> check, Func<IHostUIHandler> create)
    {
        var red = new List<string>();
        bool strict = Red.Strict;
        Action<string> log = Red.Log;
        Red.Strict = false;
        Red.Reset();
        Red.Log = red.Add;
        try
        {
            IHostUIHandler ui = create();
            long total = Red.Total;
            bool result = true;
            int before = red.Count;

            // 错误小程序（游戏 nn::err::ShowError）：共用实现自动按确定 → false（没按「详情」），不报红、不停局
            check(NoThrow(() => result = ui.DisplayErrorAppletDialog("2168-0002", "游戏发生错误", new[] { "确定" }, null)),
                "错误小程序：应答不抛、不停局");
            check(!result && Red.Total == total && red.Count == before, "错误小程序：自动按确定（false）、不报红");

            // 消息框：宿主界面未接 → 报红一次 + false，不停局（回包语义同 iOS）
            check(NoThrow(() => result = ui.DisplayMessageDialog("标题", "内容")), "消息框：应答不抛、不停局");
            check(!result && Red.Total == total + 1 && red.Count == before + 1, "消息框：报红一次、返回 false");

            // 截图（am SaveCurrentScreenshot）：宿主界面未接 → 报红一次（void），不停局
            check(NoThrow(ui.TakeScreenshot), "截图：应答不抛、不停局");
            check(Red.Total == total + 2 && red.Count == before + 2, "截图：报红一次");

            // 装配与返回值都和 iOS 共用实现一致：登记的就是 HostUi 本体，逐条对照返回值
            check(ui.GetType() == typeof(HostUi), "Android 登记的宿主界面 = 共用 HostUi（与 iOS 同一实现）");
            var shared = new HostUi();
            check(ui.DisplayErrorAppletDialog("2168-0002", "游戏发生错误", new[] { "确定" }, null)
                    == shared.DisplayErrorAppletDialog("2168-0002", "游戏发生错误", new[] { "确定" }, null)
                && ui.DisplayMessageDialog("标题", "内容") == shared.DisplayMessageDialog("标题", "内容"),
                "返回值与 iOS 共用实现一致");

            CheckAsyncTextInput(check, ui);

            // 前台软键盘挂点（安卓装配把它接到 ExchangeUi broker）。四种结局逐条断言：
            _uiMode = 0;
            UiBegins = UiWaits = UiCancels = 0;
            var kbd = new SoftwareKeyboardUIArgs { KeyboardMode = KeyboardMode.Default, HeaderText = "标题", InitialText = "初字", StringLengthMax = 32 };
            check(ui is HostUi hooked && hooked.SoftwareKeyboard != null, "安卓装配登记前台软键盘挂点");
            _uiReply = "{\"version\":1,\"type\":\"software-keyboard\",\"status\":\"ok\",\"text\":\"玩家名\"}";
            check(ui.DisplayInputDialog(kbd, out string accepted) && accepted == "玩家名", "软键盘挂点：宿主确认 → 应答文本 + true");
            check(UiBegins == 1 && UiCancels == 1
                    && UiRequest.Contains("\"type\":\"software-keyboard\"") && UiRequest.Contains("\"max\":32"),
                "软键盘挂点：请求按协议进 broker、等完收回");

            _uiMode = 1;
            _uiReply = "{\"version\":1,\"type\":\"software-keyboard\",\"status\":\"cancel\"}";
            check(!ui.DisplayInputDialog(kbd, out string cancelled) && cancelled == null, "软键盘挂点：用户取消 → false");

            _uiMode = 2;
            check(!ui.DisplayInputDialog(kbd, out string revoked) && revoked == null, "软键盘挂点：宿主撤销 → false");

            long redKb = Red.Total;
            _uiMode = 3;
            result = true;
            string failed = "x";
            check(NoThrow(() => result = ui.DisplayInputDialog(kbd, out failed))
                    && !result && failed == null && Red.Total == redKb + 1 && red[^1].Contains("软键盘应答失败"),
                "软键盘挂点：ExchangeUi 抛异常 → 报红一次、false、不抛");
            _uiMode = 0;

            // 撤挂点负控（内联）：同一实例把挂点置空 → 回落共用零配置自动应答（交回游戏初字），请求不进 broker
            int begins = UiBegins;
            ((HostUi)ui).SoftwareKeyboard = null;
            check(ui.DisplayInputDialog(kbd, out string fallback) && fallback == "初字" && UiBegins == begins,
                "软键盘：撤挂点回落零配置自动应答、不进 broker");
        }
        finally
        {
            Red.Strict = strict;
            Red.Log = log;
        }
    }
}
