// 部分回写换算单测（Ryujinx.Graphics.Texture.S2APartialLayout）：期望值来自 Ryujinx 原版 LayoutConverter.ConvertLinearToBlockLinear（第 0 级、单层），
// 不来自被测实现。对每种（宽 × 高 × 每像素字节 × 块高）：随机线性源 → 原版整张转换进预填 0xEE 的输出（图像外填充字节保持 0xEE）；
// 再对每个 4 KB 子页：预填 0xEE、按 RowRange 取源行、Write 写这一页 → 必须与原版输出的同一段逐字节相同。覆盖小高度时块高减半、末页不满 4 KB、宽度不是 64 字节倍数。
// 反证：把块高故意传错（×2）时必须有不一致（判据活着）。用法：bash build_run.sh；退出码 0 = 全过
using Ryujinx.Graphics.Texture;
using System;

static class P
{
    static int fail, count;

    static bool Case(int w, int h, int bpp, int gobY, int gobYForWrite, bool expectSame)
    {
        int stride = S2APartialLayout.HostStride(w, bpp);
        var rnd = new Random(w * 31 + h * 7 + bpp + gobY);
        byte[] src = new byte[stride * h]; rnd.NextBytes(src);
        SizeInfo si = SizeCalculator.GetBlockLinearTextureSize(w, h, 1, 1, 1, 1, 1, bpp, gobY, 1, 1);
        byte[] reference = new byte[si.TotalSize]; Array.Fill(reference, (byte)0xEE);
        LayoutConverter.ConvertLinearToBlockLinear(reference, w, h, 1, 1, 1, 1, 1, 1, bpp, gobY, 1, 1, si, src);
        int bad = 0, pages = 0;
        for (int off = 0; off < reference.Length; off += 0x1000)
        {
            int len = Math.Min(0x1000, reference.Length - off);
            byte[] dst = new byte[len]; Array.Fill(dst, (byte)0xEE);
            if (S2APartialLayout.RowRange(off, len, w, h, bpp, gobYForWrite, out int r0, out int r1))
                S2APartialLayout.Write(dst, off, w, h, bpp, gobYForWrite, src.AsSpan(r0 * stride, (r1 - r0 + 1) * stride), r0, stride);
            if (!dst.AsSpan().SequenceEqual(reference.AsSpan(off, len))) bad++;
            pages++;
        }
        bool same = bad == 0;
        count++; if (same != expectSame) fail++;
        Console.WriteLine($"{w}x{h} bpp {bpp} 块高 {gobY}{(gobYForWrite != gobY ? $"（写入按 {gobYForWrite}，反证）" : "")}：{pages} 页、不一致 {bad} 页 → 期望 {(expectSame ? "全同" : "有差")} {(same == expectSame ? "✓" : "✗")}");
        return same;
    }

    static int Main()
    {
        Case(1920, 1080, 4, 16, 16, true);   // 塞尔达 / 动森的 1080p 渲染目标
        Case(256, 128, 4, 16, 16, true);     // R11G11B10 256×128：高度 128 → 块高不减
        Case(386, 386, 8, 16, 16, true);     // R16G16B16A16 386×386：宽度不是 64 字节倍数（3088）
        Case(512, 512, 8, 16, 16, true);
        Case(256, 256, 4, 1, 1, true);       // R32Float 块高 1
        Case(64, 64, 4, 16, 16, true);       // 小高度：块高 16 → 8
        Case(512, 8, 16, 16, 16, true);      // 高度 8：块高减到 1
        Case(1024, 300, 2, 4, 4, true);
        Case(2048, 64, 1, 8, 8, true);
        Case(1920, 1080, 4, 16, 32, false);  // 反证：块高传错必须不一致
        Console.WriteLine($"partial：{count} 项，失败 {fail}");
        return fail == 0 ? 0 : 1;
    }
}
