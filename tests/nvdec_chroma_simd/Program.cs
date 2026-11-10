// Nvdec NV12 chroma plane <-> block-linear guest memory (Ryujinx.Graphics.Nvdec Image/SurfaceReader.ReadChroma, SurfaceWriter.WriteChroma).
// On ARM64 these now take the 64-byte fast path (AdvSimd ZIP1/ZIP2) that upstream had only for SSE2.
// Expected placement, computed here independently with Ryujinx.Graphics.Texture.OffsetCalculator exactly as the scalar loop does
// (gobBlocksInY 2, 2 bytes per pixel): guest[calc.GetOffset(x)] = U[y, x], guest[... + 1] = V[y, x].
// Widths cover the 64-byte main loop, its remainder (width * 2 not a multiple of 64) and the 1080p chroma plane (960 x 540).
using System;
using System.Reflection;
using Ryujinx.Graphics.Texture;

static class P
{
    static int fails, cases;

    static int Main()
    {
        Console.WriteLine($"AdvSimd.Arm64: {System.Runtime.Intrinsics.Arm.AdvSimd.Arm64.IsSupported}, Sse2: {System.Runtime.Intrinsics.X86.Sse2.IsSupported}");
        Assembly nv = typeof(Ryujinx.Graphics.Nvdec.NvdecDevice).Assembly;
        MethodInfo read = nv.GetType("Ryujinx.Graphics.Nvdec.Image.SurfaceReader").GetMethod("ReadChroma", BindingFlags.NonPublic | BindingFlags.Static);
        MethodInfo write = nv.GetType("Ryujinx.Graphics.Nvdec.Image.SurfaceWriter").GetMethod("WriteChroma", BindingFlags.NonPublic | BindingFlags.Static);
        var readD = (ReadFn)Delegate.CreateDelegate(typeof(ReadFn), read);
        var writeD = (WriteFn)Delegate.CreateDelegate(typeof(WriteFn), write);

        var rnd = new Random(20261108);
        (int w, int h)[] sizes = [(960, 540), (32, 16), (40, 9), (64, 64), (100, 37), (352, 144), (640, 360), (17, 3)];
        foreach (var (w, h) in sizes)
        {
            int stride = w + rnd.Next(0, 48);
            int size = SizeCalculator.GetBlockLinearTextureSize(w, h, 1, 1, 1, 1, 1, 2, 2, 1, 1).TotalSize;
            var calc = new OffsetCalculator(w, h, 0, false, 2, 2);

            // Write: planes -> guest
            byte[] u = new byte[stride * h], v = new byte[stride * h];
            rnd.NextBytes(u); rnd.NextBytes(v);
            byte[] guest = new byte[size + 64], want = new byte[size + 64];
            for (int y = 0; y < h; y++) { calc.SetY(y); for (int x = 0; x < w; x++) { int o = calc.GetOffset(x); want[o] = u[(y * stride) + x]; want[o + 1] = v[(y * stride) + x]; } }
            writeD(guest, u, v, stride, w, h);
            cases++;
            for (int i = 0; i < size; i++) if (guest[i] != want[i]) { if (fails++ < 10) Console.WriteLine($"FAIL write {w}x{h} at byte {i}: want {want[i]}, got {guest[i]}"); break; }

            // Read: guest -> planes
            byte[] src = new byte[size + 64];
            rnd.NextBytes(src);
            byte[] gu = new byte[stride * h], gv = new byte[stride * h];
            readD(gu, gv, src, stride, w, h);
            cases++;
            bool bad = false;
            for (int y = 0; y < h && !bad; y++) { calc.SetY(y); for (int x = 0; x < w; x++) { int o = calc.GetOffset(x);
                if (gu[(y * stride) + x] != src[o] || gv[(y * stride) + x] != src[o + 1]) { if (fails++ < 10) Console.WriteLine($"FAIL read {w}x{h} at ({x},{y})"); bad = true; break; } } }
        }
        Console.WriteLine(fails == 0 ? $"nvdec_chroma_simd: all green ({cases} cases)" : $"nvdec_chroma_simd: {fails} red of {cases}");
        return fails == 0 ? 0 : 1;
    }

    delegate void ReadFn(Span<byte> dstU, Span<byte> dstV, ReadOnlySpan<byte> src, int dstStride, int width, int height);
    delegate void WriteFn(Span<byte> dst, ReadOnlySpan<byte> srcU, ReadOnlySpan<byte> srcV, int srcStride, int width, int height);
}
