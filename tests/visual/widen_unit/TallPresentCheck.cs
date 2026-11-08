// 通用层高屏上屏走生产路径（审计 #1592 P1-118）：经 WidenRenderer.Window（生产的 WidenWindow.Present）上屏，核交给底层窗口的 ImageCrop 宽高比。
//   原先只锁计算函数 WidenFrame.GenericPresentAspectX，删掉 Present 里对它的调用单测照绿（P1-117 修法没被钉住）。
// 期望手算（同 Program.cs 原用例）：高屏 Ky = 1.25 → 屏幕比 16/9 ÷ 1.25 = 1.422222，ay = 9 时 ax = 12.8；16:9 贴图回到 ax 16；宽屏 Ky = 1 原样。
// 底层渲染器 / 窗口 / 贴图用 DispatchProxy 假的：窗口只记下 Present 收到的裁剪，贴图只给宽高（不是宽屏层自己包的贴图，走「没放宽登记」那条）。
using System;
using System.Reflection;
using Ryujinx.Graphics.GAL;
using S2Arm.Gfx.Widen.Gal;

static class TallPresentCheck
{
    public class FakeWindow : DispatchProxy
    {
        public ImageCrop? Got;
        protected override object Invoke(MethodInfo m, object[] a)
        {
            if (m.Name == nameof(IWindow.Present)) { Got = (ImageCrop)a[1]; return null; }
            return null;   // SetSize 等其余调用：本检查用不到
        }
    }
    public class FakeRenderer : DispatchProxy
    {
        public IWindow Win;
        protected override object Invoke(MethodInfo m, object[] a) => m.Name == "get_" + nameof(IRenderer.Window) ? Win : throw new NotSupportedException(m.Name);
    }
    public class FakeTexture : DispatchProxy
    {
        public int W, H;
        protected override object Invoke(MethodInfo m, object[] a) => m.Name switch { "get_Width" => W, "get_Height" => H, _ => throw new NotSupportedException(m.Name) };
    }

    // 经生产 Present 上屏一次，返回底层窗口收到的 ax（没收到返回 NaN）
    static float PresentAx(float screenAspect, float ax, float ay, int texW, int texH)
    {
        IWindow win = DispatchProxy.Create<IWindow, FakeWindow>();
        IRenderer inner = DispatchProxy.Create<IRenderer, FakeRenderer>(); ((FakeRenderer)(object)inner).Win = win;
        ITexture tex = DispatchProxy.Create<ITexture, FakeTexture>(); ((FakeTexture)(object)tex).W = texW; ((FakeTexture)(object)tex).H = texH;
        var widen = new WidenRenderer(inner, screenAspect);
        widen.Window.Present(tex, new ImageCrop(0, texW, 0, texH, false, false, false, ax, ay), null);
        return ((FakeWindow)(object)win).Got is { } c ? c.AspectRatioX : float.NaN;
    }

    public static void Run(Action<string, object, object> check)
    {
        const float Tall = 16f / 9f / 1.25f, Wide = 2346f / 1080f;
        check("生产上屏（WidenWindow.Present）高屏：游戏按加长分辨率出 1280×900 → 按屏幕比（ax 12.8）", "12.8000", PresentAx(Tall, 16f, 9f, 1280, 900).ToString("F4"));
        check("生产上屏高屏：16:9 贴图（1920×1080，上游给了 12.8）→ 回到 16:9（ax 16）", "16.0000", PresentAx(Tall, 12.8f, 9f, 1920, 1080).ToString("F4"));
        check("生产上屏高屏：16:9 贴图、ax 16 → 仍 16", "16.0000", PresentAx(Tall, 16f, 9f, 1280, 720).ToString("F4"));
        check("生产上屏宽屏（Ky = 1）：原样 21.7222", "21.7222", PresentAx(Wide, 21.7222f, 9f, 1564, 720).ToString("F4"));
    }
}
