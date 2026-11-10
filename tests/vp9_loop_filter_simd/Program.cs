// VP9 8-bit loop filter (Ryujinx.Graphics.Nvdec.Vp9 Dsp): the portable Vector128 path (LoopFilterVector, AdvSimd on ARM64) must leave every
// byte of the frame exactly as LoopFilterScalar (upstream, unchanged) does, for all twelve entry points.
// Frames are built so each branch of the scalar filter is taken: flat regions (|diff| <= 1, the 15- and 7-tap paths), smooth ramps,
// sharp edges (filter4 with and without high edge variance), noise past the limits (mask off), and the thresholds a real stream uses
// (limit 0..63, blimit 2 * (level + 2) + limit, thresh = level >> 4) plus random extremes.
using System;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.Nvdec.Vp9.Dsp;

static unsafe class P
{
    static int fails, cases;
    const int W = 64, H = 64, Pitch = 96, Off = (16 * Pitch) + 16;

    delegate void F(ArrayPtr<byte> s, int pitch, byte b0, byte l0, byte t0, byte b1, byte l1, byte t1);

    static void Fill(Random rnd, byte[] buf, int kind)
    {
        int baseV = rnd.Next(0, 256);
        for (int y = 0; y < buf.Length / Pitch; y++)
            for (int x = 0; x < Pitch; x++)
            {
                int v = kind switch
                {
                    0 => baseV + rnd.Next(-1, 2),                                      // flat: 15-/7-tap
                    1 => baseV + ((x + y) / 3) + rnd.Next(-1, 2),                      // smooth ramp
                    2 => ((x < 40) == (y < 40) ? baseV : 255 - baseV) + rnd.Next(-3, 4), // hard step edge
                    3 => rnd.Next(0, 256),                                             // noise: mask mostly off
                    _ => (((x >> 3) + (y >> 3)) & 1) != 0 ? baseV + rnd.Next(-2, 3) : baseV + 6 + rnd.Next(-2, 3), // 8x8 blocking
                };
                buf[(y * Pitch) + x] = (byte)Math.Clamp(v, 0, 255);
            }
    }

    static void Thresholds(Random rnd, out byte blimit, out byte limit, out byte thresh)
    {
        if (rnd.Next(4) == 0) { blimit = (byte)rnd.Next(256); limit = (byte)rnd.Next(256); thresh = (byte)rnd.Next(256); return; }
        int level = rnd.Next(0, 64), sharp = rnd.Next(0, 8);
        int lim = level >> ((sharp > 0 ? 1 : 0) + (sharp > 4 ? 1 : 0));
        if (sharp > 0 && lim > 9 - sharp) lim = 9 - sharp;
        if (lim < 1) lim = 1;
        limit = (byte)lim; blimit = (byte)Math.Min(255, (2 * (level + 2)) + lim); thresh = (byte)(level >> 4);
    }

    static void Case(string name, Random rnd, F vec, F sca, int kind)
    {
        byte[] a = new byte[Pitch * (H + 32)], b = new byte[a.Length];
        Fill(rnd, a, kind);
        Array.Copy(a, b, a.Length);
        Thresholds(rnd, out byte b0, out byte l0, out byte t0);
        Thresholds(rnd, out byte b1, out byte l1, out byte t1);
        fixed (byte* pa = a, pb = b)
        {
            vec(new ArrayPtr<byte>(pa + Off, a.Length - Off), Pitch, b0, l0, t0, b1, l1, t1);
            sca(new ArrayPtr<byte>(pb + Off, b.Length - Off), Pitch, b0, l0, t0, b1, l1, t1);
        }
        cases++;
        for (int i = 0; i < a.Length; i++)
            if (a[i] != b[i])
            {
                if (fails++ < 10) Console.WriteLine($"FAIL {name} kind={kind} thr=({b0},{l0},{t0})/({b1},{l1},{t1}) at row {(i / Pitch) - 16} col {(i % Pitch) - 16}: scalar {b[i]}, vector {a[i]}");
                return;
            }
    }

    static int Main()
    {
        Console.WriteLine($"vector path: {(LoopFilterVector.Enabled ? "on" : "off (x86 SSE2 or no SIMD: nothing to compare)")}");
        if (!LoopFilterVector.Enabled) return 0;

        var tests = new (string, F, F)[]
        {
            ("LpfHorizontal4", (s, p, b, l, t, _, _, _) => LoopFilterVector.LpfHorizontal4(s, p, b, l, t), (s, p, b, l, t, _, _, _) => LoopFilterScalar.LpfHorizontal4(s, p, b, l, t)),
            ("LpfHorizontal4Dual", LoopFilterVector.LpfHorizontal4Dual, LoopFilterScalar.LpfHorizontal4Dual),
            ("LpfHorizontal8", (s, p, b, l, t, _, _, _) => LoopFilterVector.LpfHorizontal8(s, p, b, l, t), (s, p, b, l, t, _, _, _) => LoopFilterScalar.LpfHorizontal8(s, p, b, l, t)),
            ("LpfHorizontal8Dual", LoopFilterVector.LpfHorizontal8Dual, LoopFilterScalar.LpfHorizontal8Dual),
            ("LpfHorizontal16", (s, p, b, l, t, _, _, _) => LoopFilterVector.LpfHorizontal16(s, p, b, l, t), (s, p, b, l, t, _, _, _) => LoopFilterScalar.LpfHorizontal16(s, p, b, l, t)),
            ("LpfHorizontal16Dual", (s, p, b, l, t, _, _, _) => LoopFilterVector.LpfHorizontal16Dual(s, p, b, l, t), (s, p, b, l, t, _, _, _) => LoopFilterScalar.LpfHorizontal16Dual(s, p, b, l, t)),
            ("LpfVertical4", (s, p, b, l, t, _, _, _) => LoopFilterVector.LpfVertical4(s, p, b, l, t), (s, p, b, l, t, _, _, _) => LoopFilterScalar.LpfVertical4(s, p, b, l, t)),
            ("LpfVertical4Dual", LoopFilterVector.LpfVertical4Dual, LoopFilterScalar.LpfVertical4Dual),
            ("LpfVertical8", (s, p, b, l, t, _, _, _) => LoopFilterVector.LpfVertical8(s, p, b, l, t), (s, p, b, l, t, _, _, _) => LoopFilterScalar.LpfVertical8(s, p, b, l, t)),
            ("LpfVertical8Dual", LoopFilterVector.LpfVertical8Dual, LoopFilterScalar.LpfVertical8Dual),
            ("LpfVertical16", (s, p, b, l, t, _, _, _) => LoopFilterVector.LpfVertical16(s, p, b, l, t), (s, p, b, l, t, _, _, _) => LoopFilterScalar.LpfVertical16(s, p, b, l, t)),
            ("LpfVertical16Dual", (s, p, b, l, t, _, _, _) => LoopFilterVector.LpfVertical16Dual(s, p, b, l, t), (s, p, b, l, t, _, _, _) => LoopFilterScalar.LpfVertical16Dual(s, p, b, l, t)),
        };

        var rnd = new Random(20261108);
        foreach (var (name, vec, sca) in tests)
            for (int i = 0; i < 1000; i++)
                Case(name, rnd, vec, sca, i % 5);

        Console.WriteLine(fails == 0 ? $"vp9_loop_filter_simd: all green ({cases} frames, 12 entry points)" : $"vp9_loop_filter_simd: {fails} red of {cases}");
        return fails == 0 ? 0 : 1;
    }
}
