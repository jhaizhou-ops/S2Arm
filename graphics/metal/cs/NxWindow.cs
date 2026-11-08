// IWindow（第 7 块）：出图交 C 端（gal_present.m）。
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using System;
using System.Runtime.InteropServices;

namespace NxGal
{
    static unsafe partial class N
    {
        [DllImport(Lib)] public static extern void nxgal_window_set_layer(void* layer);
        [DllImport(Lib)] public static extern void nxgal_present(uint tex, NCrop* crop);
        [DllImport(Lib)] public static extern void nxgal_pool_cycle();   // 本线程自动释放池轮换（gal_abi.h）
        [DllImport(Lib)] public static extern void nxgal_window_set_size(int w, int h);
        [DllImport(Lib)] public static extern void nxgal_window_set_vsync(int mode);
        [DllImport(Lib)] public static extern void nxgal_window_set_min_interval(float seconds);
        [DllImport(Lib)] public static extern void nxgal_window_set_scaling(int filter, float level);
        [DllImport(Lib)] public static extern void nxgal_window_set_antialiasing(int mode);
        [DllImport(Lib)] public static extern int nxgal_screenshot(void* outp, int cap, int* w, int* h);
    }

    // 按 QoS 起原生线程跑托管入口（gal_core.m nxgal_thread_start）：.NET 自己建的线程设不了 QoS
    public static unsafe class NxThread
    {
        [DllImport(N.Lib)] static extern int nxgal_thread_start(delegate* unmanaged<nint, void> fn, nint arg, int qos, byte* name);
        [DllImport(N.Lib)] static extern int nxgal_thread_start_joinable(delegate* unmanaged<nint, void> fn, nint arg, int qos, byte* name, out nint thread);
        [DllImport(N.Lib)] static extern int nxgal_thread_join(nint thread);
        public static int Start(delegate* unmanaged<nint, void> fn, nint arg, int qos, byte* name) => nxgal_thread_start(fn, arg, qos, name);
        public static int StartJoinable(delegate* unmanaged<nint, void> fn, nint arg, int qos, byte* name, out nint thread) => nxgal_thread_start_joinable(fn, arg, qos, name, out thread);
        public static void Join(ref nint thread)
        {
            if (thread == 0) return;
            int rc = nxgal_thread_join(thread);
            if (rc != 0) throw new InvalidOperationException($"图形线程 join 失败（{rc}）");
            thread = 0;
        }
    }

    // 出图最短显示间隔（宿主侧用：SurfaceFlinger 合成节拍变了时调，见 graphics/loop/RenderLoop.cs）
    public static class NxWindowPacing
    {
        public static void SetMinInterval(float seconds) => N.nxgal_window_set_min_interval(seconds);
        // 标称帧率报给原生层（自动玩家按它折算按 30 帧写的路线帧数）：同 NxFrames.OnPresent 的口径，没有原生层的进程（回放器 / 单测）跳过
        static bool _noNative;
        public static void SetNominalFps(int fps)
        {
            if (_noNative) return;
            try { N.s2a_nominal_fps_set(fps); }
            catch (Exception e) when (e is DllNotFoundException || e is EntryPointNotFoundException) { _noNative = true; }
        }
    }

    public sealed unsafe class NxWindow : IWindow
    {
        readonly NxRenderer _r;
        int _filter; float _level;
        public NxWindow(NxRenderer r) => _r = r;

        public void Present(ITexture texture, ImageCrop crop, Action swapBuffersCallback)
        {
            NCrop c = new()
            {
                Left = crop.Left, Right = crop.Right, Top = crop.Top, Bottom = crop.Bottom, FlipX = crop.FlipX ? 1 : 0, FlipY = crop.FlipY ? 1 : 0,
                Stretched = crop.IsStretched ? 1 : 0, AspectX = crop.AspectRatioX, AspectY = crop.AspectRatioY,
            };
            N.nxgal_present(texture is NxTexture t ? t.Id : 0, &c);
            NxFrames.OnPresent();
            swapBuffersCallback?.Invoke();
        }
        public void SetSize(int width, int height) => N.nxgal_window_set_size(width, height);
        public void ChangeVSyncMode(VSyncMode vSyncMode) => N.nxgal_window_set_vsync((int)vSyncMode);
        public void SetAntiAliasing(AntiAliasing antialiasing) => N.nxgal_window_set_antialiasing((int)antialiasing);
        public void SetScalingFilter(ScalingFilter type) { _filter = (int)type; N.nxgal_window_set_scaling(_filter, _level); }
        public void SetScalingFilterLevel(float level) { _level = level; N.nxgal_window_set_scaling(_filter, _level); }
        public void SetColorSpacePassthrough(bool colorSpacePassThroughEnabled) { }

        internal void Screenshot(EventHandler<ScreenCaptureImageInfo> h, object sender)
        {
            int w, ht; int n = N.nxgal_screenshot(null, 0, &w, &ht);
            if (n <= 0 || h == null) return;
            byte[] data = new byte[n];
            int n2; fixed (byte* p = data) n2 = N.nxgal_screenshot(p, n, &w, &ht);
            if (n2 != n) return;   // 两次调用之间换了不同尺寸的帧：没写入，丢弃这次（下次再截）
            // C 端截图 = 裁切 + 翻转后（同 Ryujinx Window.CaptureFrame 的区域；翻转已做好，故 flip 置 false）、BGRA8、alpha 255
            h(sender, new ScreenCaptureImageInfo(w, ht, isBgra: true, data, flipX: false, flipY: false));
        }
    }
}
