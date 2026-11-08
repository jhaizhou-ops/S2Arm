// 通用宽屏 · 着色器改写的唯一入口：运行时（包装层建程序）与出包时（帧率能耗线离线预编）调同一份代码，两边改出的字节逐位相同，离线库才能命中。
// 所有程序一律改，与屏幕无关（不按机型、不按是否放宽）：
//   片元：x 读 render_scale、y 读独立 render_scale_y；包装层只组合 x 的分辨率倍率与目标 / 贴图放宽比，Y 保留 GPU 原倍率与逐纹理黑名单。
//         SpirvFragCoord / SpirvFetchScale 也兼容旧 1x 录像（旧布局的 y 不缩放）；新旧离线库由 Ryujinx CodeGenVersion 区分。
//         铺满画布的 2D / 全屏遍按原画框外推（SpirvExtrap）：片元坐标减 pad、插值按 (q, r) 外推、放宽贴图采样平移、整数取图 / 尺寸查询平移；s2a_widen.w = 0 时同值。
//   顶点：返回前按 support_buffer.s2a_widen 外推画布边外的顶点（SpirvEdgePush）；两个值由包装层逐次绘制写，平时为 0 = 原样；外推语义开时在 location 31 写 (q, r)。
// 改不了的（不是 SPIR-V、找不到 gl_Position、支持缓冲没有 s2a_widen 成员）原样返回。
using System;

namespace S2Arm.Gfx.Widen
{
    public static class WidenShaders
    {
        /// <summary>Ryujinx.Graphics.Shader 的 SupportBufferField.RenderScale（= SupportBuffer 结构第 6 个成员，序号 5）。</summary>
        public const int RenderScaleMember = 5;
        public const int RenderScaleYMember = 11;

        /// <summary>片元着色器：返回改后的字节（没改返回原数组）；yPatched = 片元 y 改了几处；scales / exact 见 SpirvFetchScale（exact = 能按客体坐标画）；
        /// allowExtrap = 本款会按原画框外推（整套放宽款；游戏自己出宽 / 16:9 款永远不开外推，不注入——10-23 塞尔达：分支里哪怕不执行的导数指令也让苹果编译器改了几何边缘像素，门禁 7051 像素差 7 级）；
        /// extrap = 能按原画框外推画（SpirvExtrap，只对 exact 的程序改），samples = 外推时归一化采样要写 off 的 (render_scale 下标, 绑定号)。</summary>
        public static byte[] Fragment(byte[] spv, bool allowExtrap, out int yPatched, out (int Index, int Binding, bool Image)[] scales, out bool exact, out bool extrap, out (int Index, int Binding)[] samples)
        {
            byte[] f = SpirvFragCoord.PatchY(spv, RenderScaleMember, out yPatched, out int xUses);
            yPatched = Math.Max(yPatched, xUses); // 只有 x 的片元也需要目标横向倍率。
            byte[] b = SpirvFetchScale.PatchY(f, RenderScaleMember, out scales, out _, out exact);
            samples = Array.Empty<(int, int)>();
            byte[] e = exact && allowExtrap ? SpirvExtrap.PatchFragment(b, RenderScaleMember, scales, out samples, out _) : null;
            extrap = e != null;
            return e ?? b;
        }

        /// <summary>顶点着色器：返回改后的字节（改不了返回原数组）；patched = 改没改。</summary>
        public static byte[] Vertex(byte[] spv, out bool patched)
        {
            byte[] o = SpirvEdgePush.Patch(spv, out _);
            patched = o != null;
            return o ?? spv;
        }
    }
}
