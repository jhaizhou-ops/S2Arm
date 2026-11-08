// 宽屏包装层给测试层（tests/autoplay/autoplay_host.h）的 C 导出：NativeAOT 库模式按 [UnmanagedCallersOnly] 导出（S2A.Aot.csproj 登记本程序集）
using System;
using System.Runtime.InteropServices;

namespace S2Arm.Gfx.Widen.Gal
{
    public static unsafe class WidenExports
    {
        /// <summary>int s2a_ap_cam(float pos[3], uint64_t *frame)：最近一帧透视主镜头位置。返回 1 = 有（pos 写入、*frame = 上屏帧号），0 = 没有（2D 款 / 菜单 / 还没出图，pos 不动）。任意线程可调、零分配。</summary>
        [UnmanagedCallersOnly(EntryPoint = "s2a_ap_cam")]
        public static int ApCam(float* pos, ulong* frame)
        {
            bool ok = CameraTrack.ReadCam(pos == null ? Span<float>.Empty : new Span<float>(pos, 3), out ulong f);
            if (frame != null) *frame = f;
            return ok && pos != null ? 1 : 0;
        }
    }
}
