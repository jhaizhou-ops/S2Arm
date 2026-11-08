// 参照端 D24 深度往返单测（galplay --selftest-ref-d24；10-23 画幅线）：MoltenVK 没有 D24S8，Ryujinx Vulkan 换成 D32FloatS8Uint，
// 上传 / 读回要在 D24S8 打包（d24 << 8 | s）与 Vulkan 按平面拷出的深度平面（紧排 float，4 字节 / 像素）之间转。
// 期望值手算：上传 d24 = 0x000000 / 0x7FFFFF / 0xFFFFFF / 0x123456 …，读回 d24 必须逐像素相同（双精度换算、就近取 float 时往返无损，见 FormatConverter）。
// 模板这里不比：深度平面拷贝不带模板（读回模板记 0），只报读数。
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using System;

static class RefD24Test
{
    public static int Run()
    {
        IRenderer r = RefVk.RefVkRenderer.Create();
        const int W = 64, H = 64;
        ITexture t = r.CreateTexture(new TextureCreateInfo(W, H, 1, 1, 1, 1, 1, 4, Format.D24UnormS8Uint, DepthStencilMode.Depth, Target.Texture2D,
            SwizzleComponent.Red, SwizzleComponent.Green, SwizzleComponent.Blue, SwizzleComponent.Alpha));
        uint[] d24 = new uint[W * H];
        for (int i = 0; i < d24.Length; i++) d24[i] = i switch { 0 => 0u, 1 => 0xFFFFFFu, 2 => 0x7FFFFFu, 3 => 0x123456u, _ => i < 2048 ? (uint)(0x800000 + i * 4093) & 0xFFFFFF : (uint)(i * 524287) & 0xFFFFFF };
        byte[] up = new byte[W * H * 4];
        for (int i = 0; i < d24.Length; i++) BitConverter.TryWriteBytes(up.AsSpan(i * 4), d24[i] << 8 | (uint)(i & 0xFF));
        var mo = MemoryOwner<byte>.Rent(up.Length); up.CopyTo(mo.Span); t.SetData(mo);
        byte[] got; using (var g = t.GetData(0, 0)) got = g.Get().ToArray();
        int n = 0, bad = 0; string first = "";
        for (int i = 0; i < d24.Length && (i + 1) * 4 <= got.Length; i++)
        {
            uint v = BitConverter.ToUInt32(got, i * 4) >> 8; n++;
            if (v != d24[i]) { if (bad++ == 0) first = $"像素 {i} 期望 0x{d24[i]:x6} 实得 0x{v:x6}"; }
        }
        bool ok = got.Length == W * H * 4 && n == d24.Length && bad == 0;
        Console.WriteLine($"{(ok ? "✓" : "✗")} 参照 D24S8 往返：读回长度 {got.Length}（期望 {W * H * 4}），深度 {n} 像素里不同 {bad}{(bad > 0 ? "，首个 " + first : "")}");
        t.Release(); r.Dispose();
        return ok ? 0 : 1;
    }
}
