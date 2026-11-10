// VP9 8-tap sub-pixel convolution (Ryujinx.Graphics.Nvdec.Vp9 Dsp/Convolve.cs): the portable Vector128 path (AdvSimd on ARM64) must be
// bit-identical to the scalar loops for the unscaled step (x/yStepQ4 == 16), the only case it takes.
// Expected values come from the scalar reference (upstream code, unchanged) and, independently, from a direct evaluation of the VP9 formula
//   dst = clip(round((sum_k src[i - 3 + k] * f[k]) / 128)) written here.
// Kernels: all four VP9 tables (regular, sharp, smooth, bilinear; every one of the 16 sub-pixel phases), the only kernels the decoder
// passes (Luts.FilterKernels). On ARM64 the vector path is libvpx's int16 NEON scheme, exact for these kernels only, so arbitrary kernels
// are out of scope. Sources: random bytes, all 0, all 255, and 0/255 stripes (by column, by row, checkerboard) and binary 0/255 noise that drive the int16
// sums to their largest positive and negative values. Widths 8..64 (the vector path's range), heights 1..64, random strides.
using System;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.Nvdec.Vp9.Dsp;

static unsafe class P
{
    static int fails, cases;

    static Array8<short> K(params short[] v) { var a = new Array8<short>(); for (int i = 0; i < 8; i++) a[i] = v[i]; return a; }

    static readonly Array8<short>[] Regular =
    [
        K(0, 0, 0, 128, 0, 0, 0, 0), K(0, 1, -5, 126, 8, -3, 1, 0), K(-1, 3, -10, 122, 18, -6, 2, 0), K(-1, 4, -13, 118, 27, -9, 3, -1),
        K(-1, 4, -16, 112, 37, -11, 4, -1), K(-1, 5, -18, 105, 48, -14, 4, -1), K(-1, 5, -19, 97, 58, -16, 5, -1), K(-1, 6, -19, 88, 68, -18, 5, -1),
        K(-1, 6, -19, 78, 78, -19, 6, -1), K(-1, 5, -18, 68, 88, -19, 6, -1), K(-1, 5, -16, 58, 97, -19, 5, -1), K(-1, 4, -14, 48, 105, -18, 5, -1),
        K(-1, 4, -11, 37, 112, -16, 4, -1), K(-1, 3, -9, 27, 118, -13, 4, -1), K(0, 2, -6, 18, 122, -10, 3, -1), K(0, 1, -3, 8, 126, -5, 1, 0),
    ];

    static readonly Array8<short>[] Sharp =
    [
        K(0, 0, 0, 128, 0, 0, 0, 0), K(-1, 3, -7, 127, 8, -3, 1, 0), K(-2, 5, -13, 125, 17, -6, 3, -1), K(-3, 7, -17, 121, 27, -10, 5, -2),
        K(-4, 9, -20, 115, 37, -13, 6, -2), K(-4, 10, -23, 108, 48, -16, 8, -3), K(-4, 10, -24, 100, 59, -19, 9, -3), K(-4, 11, -24, 90, 70, -21, 10, -4),
        K(-4, 11, -23, 80, 80, -23, 11, -4), K(-4, 10, -21, 70, 90, -24, 11, -4), K(-3, 9, -19, 59, 100, -24, 10, -4), K(-3, 8, -16, 48, 108, -23, 10, -4),
        K(-2, 6, -13, 37, 115, -20, 9, -4), K(-2, 5, -10, 27, 121, -17, 7, -3), K(-1, 3, -6, 17, 125, -13, 5, -2), K(0, 1, -3, 8, 127, -7, 3, -1),
    ];

    static readonly Array8<short>[] Smooth =
    [
        K(0, 0, 0, 128, 0, 0, 0, 0), K(-3, -1, 32, 64, 38, 1, -3, 0), K(-2, -2, 29, 63, 41, 2, -3, 0), K(-2, -2, 26, 63, 43, 4, -4, 0),
        K(-2, -3, 24, 62, 46, 5, -4, 0), K(-2, -3, 21, 60, 49, 7, -4, 0), K(-1, -4, 18, 59, 51, 9, -4, 0), K(-1, -4, 16, 57, 53, 12, -4, -1),
        K(-1, -4, 14, 55, 55, 14, -4, -1), K(-1, -4, 12, 53, 57, 16, -4, -1), K(0, -4, 9, 51, 59, 18, -4, -1), K(0, -4, 7, 49, 60, 21, -3, -2),
        K(0, -4, 5, 46, 62, 24, -3, -2), K(0, -4, 4, 43, 63, 26, -2, -2), K(0, -3, 2, 41, 63, 29, -2, -2), K(0, -3, 1, 38, 64, 32, -1, -3),
    ];

    static readonly Array8<short>[] Bilinear = Bil();

    static Array8<short>[] Bil()
    {
        var a = new Array8<short>[16];
        for (int i = 0; i < 16; i++) a[i] = K(0, 0, 0, (short)(128 - (8 * i)), (short)(8 * i), 0, 0, 0);
        return a;
    }

    static byte Formula(byte* p, nint step, in Array8<short> f)
    {
        int sum = 0;
        for (int k = 0; k < 8; k++) sum += p[k * step] * f[k];
        int v = (sum + 64) >> 7;
        return (byte)Math.Clamp(v, 0, 255);
    }

    static void Check(string what, byte[] want, byte[] got, int dstStride, int w, int h)
    {
        cases++;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                if (want[y * dstStride + x] != got[y * dstStride + x])
                {
                    if (fails++ < 10) Console.WriteLine($"FAIL {what} at ({x},{y}): want {want[y * dstStride + x]}, got {got[y * dstStride + x]}");
                    return;
                }
    }

    static int Main()
    {
        Console.WriteLine($"vector path: {(Convolve.UseVector128 ? "on" : "off (x86 SSE/AVX or no SIMD: nothing to compare)")}");
        if (!Convolve.UseVector128) return 0;

        var rnd = new Random(20261108);
        byte* temp = stackalloc byte[64 * 135];
        const int Pad = 80;
        int[] widths = [8, 16, 24, 32, 48, 64];

        for (int round = 0; round < 960; round++)
        {
            Array8<short>[][] tables = [Regular, Sharp, Smooth, Bilinear];
            Array8<short>[] kernels = tables[round % 4];

            int w = widths[rnd.Next(widths.Length)], h = rnd.Next(1, 65), phase = rnd.Next(16);
            int srcStride = w + (2 * Pad) + rnd.Next(0, 33), dstStride = w + rnd.Next(0, 17);
            byte[] src = new byte[srcStride * (h + (2 * Pad))];
            rnd.NextBytes(src);
            switch (round % 7)
            {
                case 1: Array.Fill(src, (byte)255); break;
                case 2: Array.Fill(src, (byte)0); break;
                case 3: for (int i = 0; i < src.Length; i++) src[i] = (byte)(((i % srcStride) & 1) * 255); break;                    // columns
                case 4: for (int i = 0; i < src.Length; i++) src[i] = (byte)(((i / srcStride) & 1) * 255); break;                    // rows
                case 5: for (int i = 0; i < src.Length; i++) src[i] = (byte)((((i % srcStride) + (i / srcStride)) & 1) * 255); break; // checker
                case 6: for (int i = 0; i < src.Length; i++) src[i] = (byte)(rnd.Next(2) * 255); break;                            // binary noise: worst-case tap patterns
            }

            byte[] a1 = new byte[dstStride * h], b1 = new byte[dstStride * h], f1 = new byte[dstStride * h];
            fixed (byte* s0 = src, pa = a1, pb = b1, pf = f1)
            {
                byte* s = s0 + (Pad * srcStride) + Pad;

                // Horizontal
                Convolve.Convolve8Horiz(s, srcStride, pa, dstStride, kernels, phase, 16, 0, 16, w, h);
                Convolve.ConvolveHorizScalar(s, srcStride, pb, dstStride, kernels, phase, 16, w, h);
                for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) pf[y * dstStride + x] = Formula(s + (y * srcStride) + x - 3, 1, kernels[phase]);
                Check($"horiz w={w} h={h} phase={phase} vs scalar", b1, a1, dstStride, w, h);
                Check($"horiz w={w} h={h} phase={phase} vs formula", f1, a1, dstStride, w, h);

                // Vertical
                Array.Clear(a1); Array.Clear(b1);
                Convolve.Convolve8Vert(s, srcStride, pa, dstStride, kernels, 0, 16, phase, 16, w, h);
                Convolve.ConvolveVertScalar(s, srcStride, pb, dstStride, kernels, phase, 16, w, h);
                for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) pf[y * dstStride + x] = Formula(s + ((y - 3) * srcStride) + x, srcStride, kernels[phase]);
                Check($"vert w={w} h={h} phase={phase} vs scalar", b1, a1, dstStride, w, h);
                Check($"vert w={w} h={h} phase={phase} vs formula", f1, a1, dstStride, w, h);

                // 2-D (horizontal into a 64-wide temp, then vertical), the inter-prediction path
                int phaseY = rnd.Next(16);
                Array.Clear(a1); Array.Clear(b1);
                Convolve.Convolve8(s, srcStride, pa, dstStride, kernels, phase, 16, phaseY, 16, w, h);
                int ih = (((h - 1) * 16 + phaseY) >> 4) + 8;
                Convolve.ConvolveHorizScalar(s - (3 * srcStride), srcStride, temp, 64, kernels, phase, 16, w, ih);
                Convolve.ConvolveVertScalar(temp + (64 * 3), 64, pb, dstStride, kernels, phaseY, 16, w, h);
                Check($"2d w={w} h={h} phase={phase}/{phaseY} vs scalar", b1, a1, dstStride, w, h);
            }
        }

        Console.WriteLine(fails == 0 ? $"vp9_convolve_simd: all green ({cases} comparisons)" : $"vp9_convolve_simd: {fails} red of {cases}");
        return fails == 0 ? 0 : 1;
    }
}
