using Ryujinx.Common.Memory;
using System.Runtime.CompilerServices;
using System.Runtime.Intrinsics;
using System.Runtime.Intrinsics.X86;

namespace Ryujinx.Graphics.Nvdec.Vp9.Dsp
{
    // S2Arm: portable 8-bit loop filter (Vector128, AdvSimd on ARM64). Upstream had only the SSE2 port and
    // ARM64 ran LoopFilterScalar one pixel at a time (P4G's 1080p VP9 cutscenes on Android: about 18% of the
    // game process in LoopFilterScalar). This is LoopFilterScalar with eight edge pixels per pass in int16
    // lanes: the same arithmetic, the signed-char clamps done with Min/Max, and the scalar branches (mask,
    // flat, flat2) turned into per-lane selects, so the output is bit-identical
    // (tests/vp9_loop_filter_simd compares every entry point against LoopFilterScalar).
    // Only the rows the scalar filter can change are stored: 4-tap p1..q1, 8-tap p2..q2, 16-tap p6..q6.
    internal static unsafe class LoopFilterVector
    {
        internal static bool Enabled = Vector128.IsHardwareAccelerated && !Sse2.IsSupported;

        // r[0..7] = p7..p0, r[8..15] = q0..q7, eight lanes each (pixel values 0..255).
        private struct Rows
        {
            public Vector128<short> R0, R1, R2, R3, R4, R5, R6, R7, R8, R9, R10, R11, R12, R13, R14, R15;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static Vector128<short> Load8(byte* p)
        {
            return Vector128.WidenLower(Vector128.CreateScalarUnsafe(Unsafe.ReadUnaligned<ulong>(p)).AsByte()).AsInt16();
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static void Store8(byte* p, Vector128<short> v)
        {
            Vector128<byte> b = Vector128.Narrow(v.AsUInt16(), v.AsUInt16());
            Unsafe.WriteUnaligned(p, b.AsUInt64().ToScalar());
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static Vector128<short> Gt(Vector128<short> a, Vector128<short> b) => Vector128.GreaterThan(a, b);

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static Vector128<short> AbsDiff(Vector128<short> a, Vector128<short> b) => Vector128.Abs(a - b);

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static Vector128<short> ClampS8(Vector128<short> v)
        {
            return Vector128.Min(Vector128.Max(v, Vector128.Create((short)-128)), Vector128.Create((short)127));
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static Vector128<short> Round(Vector128<short> sum, int n)
        {
            return Vector128.ShiftRightArithmetic(sum + Vector128.Create((short)(1 << (n - 1))), n);
        }

        // kind 4 / 8 / 16: which scalar filter (Filter4 / Filter8 / Filter16) this edge uses.
        private static void Run(ref Rows r, int kind, byte blimit, byte limit, byte thresh)
        {
            Vector128<short> p3 = r.R4, p2 = r.R5, p1 = r.R6, p0 = r.R7;
            Vector128<short> q0 = r.R8, q1 = r.R9, q2 = r.R10, q3 = r.R11;
            Vector128<short> vLimit = Vector128.Create((short)limit);
            Vector128<short> vBlimit = Vector128.Create((short)blimit);
            Vector128<short> vThresh = Vector128.Create((short)thresh);
            Vector128<short> one = Vector128.Create((short)1);

            // FilterMask: all ones where the edge is filtered at all.
            Vector128<short> notMask =
                Gt(AbsDiff(p3, p2), vLimit) | Gt(AbsDiff(p2, p1), vLimit) | Gt(AbsDiff(p1, p0), vLimit) |
                Gt(AbsDiff(q1, q0), vLimit) | Gt(AbsDiff(q2, q1), vLimit) | Gt(AbsDiff(q3, q2), vLimit) |
                Gt((AbsDiff(p0, q0) * 2) + Vector128.ShiftRightArithmetic(AbsDiff(p1, q1), 1), vBlimit);
            Vector128<short> mask = ~notMask;

            // Filter4 (always computed; the flat paths below replace it where they apply).
            Vector128<short> hev = Gt(AbsDiff(p1, p0), vThresh) | Gt(AbsDiff(q1, q0), vThresh);
            Vector128<short> bias = Vector128.Create((short)128);
            Vector128<short> ps1 = p1 - bias, ps0 = p0 - bias, qs0 = q0 - bias, qs1 = q1 - bias;
            Vector128<short> filter = ClampS8(ps1 - qs1) & hev;
            filter = ClampS8(filter + ((qs0 - ps0) * 3)) & mask;
            Vector128<short> filter1 = Vector128.ShiftRightArithmetic(ClampS8(filter + Vector128.Create((short)4)), 3);
            Vector128<short> filter2 = Vector128.ShiftRightArithmetic(ClampS8(filter + Vector128.Create((short)3)), 3);
            Vector128<short> f4q0 = ClampS8(qs0 - filter1) + bias;
            Vector128<short> f4p0 = ClampS8(ps0 + filter2) + bias;
            filter = Vector128.AndNot(Round(filter1, 1), hev);
            Vector128<short> f4q1 = ClampS8(qs1 - filter) + bias;
            Vector128<short> f4p1 = ClampS8(ps1 + filter) + bias;

            if (kind == 4)
            {
                r.R6 = f4p1; r.R7 = f4p0; r.R8 = f4q0; r.R9 = f4q1;
                return;
            }

            // FlatMask4(1, ...)
            Vector128<short> flat = ~(Gt(AbsDiff(p1, p0), one) | Gt(AbsDiff(q1, q0), one) | Gt(AbsDiff(p2, p0), one) |
                                      Gt(AbsDiff(q2, q0), one) | Gt(AbsDiff(p3, p0), one) | Gt(AbsDiff(q3, q0), one));
            Vector128<short> use8 = flat & mask;

            // 7-tap filter [1, 1, 1, 2, 1, 1, 1]
            Vector128<short> f8p2 = Round(p3 + p3 + p3 + (p2 * 2) + p1 + p0 + q0, 3);
            Vector128<short> f8p1 = Round(p3 + p3 + p2 + (p1 * 2) + p0 + q0 + q1, 3);
            Vector128<short> f8p0 = Round(p3 + p2 + p1 + (p0 * 2) + q0 + q1 + q2, 3);
            Vector128<short> f8q0 = Round(p2 + p1 + p0 + (q0 * 2) + q1 + q2 + q3, 3);
            Vector128<short> f8q1 = Round(p1 + p0 + q0 + (q1 * 2) + q2 + q3 + q3, 3);
            Vector128<short> f8q2 = Round(p0 + q0 + q1 + (q2 * 2) + q3 + q3 + q3, 3);

            Vector128<short> o8p2 = Vector128.ConditionalSelect(use8, f8p2, p2);
            Vector128<short> o8p1 = Vector128.ConditionalSelect(use8, f8p1, f4p1);
            Vector128<short> o8p0 = Vector128.ConditionalSelect(use8, f8p0, f4p0);
            Vector128<short> o8q0 = Vector128.ConditionalSelect(use8, f8q0, f4q0);
            Vector128<short> o8q1 = Vector128.ConditionalSelect(use8, f8q1, f4q1);
            Vector128<short> o8q2 = Vector128.ConditionalSelect(use8, f8q2, q2);

            if (kind == 8)
            {
                r.R5 = o8p2; r.R6 = o8p1; r.R7 = o8p0; r.R8 = o8q0; r.R9 = o8q1; r.R10 = o8q2;
                return;
            }

            Vector128<short> p7 = r.R0, p6 = r.R1, p5 = r.R2, p4 = r.R3;
            Vector128<short> q4 = r.R12, q5 = r.R13, q6 = r.R14, q7 = r.R15;

            // FlatMask5(1, p7, p6, p5, p4, p0, q0, q4, q5, q6, q7)
            Vector128<short> flat2 = ~(Gt(AbsDiff(p4, p0), one) | Gt(AbsDiff(q4, q0), one) | Gt(AbsDiff(p5, p0), one) |
                                       Gt(AbsDiff(q5, q0), one) | Gt(AbsDiff(p6, p0), one) | Gt(AbsDiff(q6, q0), one) |
                                       Gt(AbsDiff(p7, p0), one) | Gt(AbsDiff(q7, q0), one));
            Vector128<short> use16 = flat2 & use8;

            // 15-tap filter [1, 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1]
            Vector128<short> f16p6 = Round((p7 * 7) + (p6 * 2) + p5 + p4 + p3 + p2 + p1 + p0 + q0, 4);
            Vector128<short> f16p5 = Round((p7 * 6) + p6 + (p5 * 2) + p4 + p3 + p2 + p1 + p0 + q0 + q1, 4);
            Vector128<short> f16p4 = Round((p7 * 5) + p6 + p5 + (p4 * 2) + p3 + p2 + p1 + p0 + q0 + q1 + q2, 4);
            Vector128<short> f16p3 = Round((p7 * 4) + p6 + p5 + p4 + (p3 * 2) + p2 + p1 + p0 + q0 + q1 + q2 + q3, 4);
            Vector128<short> f16p2 = Round((p7 * 3) + p6 + p5 + p4 + p3 + (p2 * 2) + p1 + p0 + q0 + q1 + q2 + q3 + q4, 4);
            Vector128<short> f16p1 = Round((p7 * 2) + p6 + p5 + p4 + p3 + p2 + (p1 * 2) + p0 + q0 + q1 + q2 + q3 + q4 + q5, 4);
            Vector128<short> f16p0 = Round(p7 + p6 + p5 + p4 + p3 + p2 + p1 + (p0 * 2) + q0 + q1 + q2 + q3 + q4 + q5 + q6, 4);
            Vector128<short> f16q0 = Round(p6 + p5 + p4 + p3 + p2 + p1 + p0 + (q0 * 2) + q1 + q2 + q3 + q4 + q5 + q6 + q7, 4);
            Vector128<short> f16q1 = Round(p5 + p4 + p3 + p2 + p1 + p0 + q0 + (q1 * 2) + q2 + q3 + q4 + q5 + q6 + (q7 * 2), 4);
            Vector128<short> f16q2 = Round(p4 + p3 + p2 + p1 + p0 + q0 + q1 + (q2 * 2) + q3 + q4 + q5 + q6 + (q7 * 3), 4);
            Vector128<short> f16q3 = Round(p3 + p2 + p1 + p0 + q0 + q1 + q2 + (q3 * 2) + q4 + q5 + q6 + (q7 * 4), 4);
            Vector128<short> f16q4 = Round(p2 + p1 + p0 + q0 + q1 + q2 + q3 + (q4 * 2) + q5 + q6 + (q7 * 5), 4);
            Vector128<short> f16q5 = Round(p1 + p0 + q0 + q1 + q2 + q3 + q4 + (q5 * 2) + q6 + (q7 * 6), 4);
            Vector128<short> f16q6 = Round(p0 + q0 + q1 + q2 + q3 + q4 + q5 + (q6 * 2) + (q7 * 7), 4);

            r.R1 = Vector128.ConditionalSelect(use16, f16p6, p6);
            r.R2 = Vector128.ConditionalSelect(use16, f16p5, p5);
            r.R3 = Vector128.ConditionalSelect(use16, f16p4, p4);
            r.R4 = Vector128.ConditionalSelect(use16, f16p3, p3);
            r.R5 = Vector128.ConditionalSelect(use16, f16p2, o8p2);
            r.R6 = Vector128.ConditionalSelect(use16, f16p1, o8p1);
            r.R7 = Vector128.ConditionalSelect(use16, f16p0, o8p0);
            r.R8 = Vector128.ConditionalSelect(use16, f16q0, o8q0);
            r.R9 = Vector128.ConditionalSelect(use16, f16q1, o8q1);
            r.R10 = Vector128.ConditionalSelect(use16, f16q2, o8q2);
            r.R11 = Vector128.ConditionalSelect(use16, f16q3, q3);
            r.R12 = Vector128.ConditionalSelect(use16, f16q4, q4);
            r.R13 = Vector128.ConditionalSelect(use16, f16q5, q5);
            r.R14 = Vector128.ConditionalSelect(use16, f16q6, q6);
        }

        // Rows [first, last] of r (0 = p7 .. 15 = q7) that a filter reads, and the ones it may write.
        private static int ReadFirst(int kind) => kind == 16 ? 0 : 4;
        private static int WriteFirst(int kind) => kind == 4 ? 6 : kind == 8 ? 5 : 1;

        // Eight pixels along a horizontal edge: lane i is column i, row k is s + (k - 8) * pitch.
        private static void Horizontal8(byte* s, int pitch, int kind, byte blimit, byte limit, byte thresh)
        {
            Rows r = default;
            Span16 rows = new(ref r);
            int rf = ReadFirst(kind);
            for (int k = rf; k < 16 - rf; k++)
            {
                rows[k] = Load8(s + ((k - 8) * pitch));
            }

            Run(ref r, kind, blimit, limit, thresh);

            int wf = WriteFirst(kind);
            for (int k = wf; k < 16 - wf; k++)
            {
                Store8(s + ((k - 8) * pitch), rows[k]);
            }
        }

        // 8 x 8 byte transpose on eight 64-bit words (byte c of a[r] <-> byte r of a[c]): three rounds of masked
        // swaps of 1-, 2- and 4-byte blocks. It is its own inverse.
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static void Transpose8x8(ulong* a)
        {
            for (int i = 0; i < 8; i += 2)
            {
                ulong t = ((a[i] >> 8) ^ a[i + 1]) & 0x00FF00FF00FF00FFUL;
                a[i + 1] ^= t;
                a[i] ^= t << 8;
            }

            for (int i = 0; i < 8; i += 4)
            {
                for (int j = i; j < i + 2; j++)
                {
                    ulong t = ((a[j] >> 16) ^ a[j + 2]) & 0x0000FFFF0000FFFFUL;
                    a[j + 2] ^= t;
                    a[j] ^= t << 16;
                }
            }

            for (int j = 0; j < 4; j++)
            {
                ulong t = ((a[j] >> 32) ^ a[j + 4]) & 0x00000000FFFFFFFFUL;
                a[j + 4] ^= t;
                a[j] ^= t << 32;
            }
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static Vector128<short> Widen(ulong v) => Vector128.WidenLower(Vector128.CreateScalarUnsafe(v).AsByte()).AsInt16();

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static ulong Narrow(Vector128<short> v) => Vector128.Narrow(v.AsUInt16(), v.AsUInt16()).AsUInt64().ToScalar();

        // Bytes [first, last] of an 8-byte row segment at p, nothing else (the scalar filter writes exactly these).
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static void StoreBytes(byte* p, ulong v, int first, int last)
        {
            for (int b = first; b <= last; b++)
            {
                p[b] = (byte)(v >> (8 * b));
            }
        }

        // Eight pixels along a vertical edge: lane i is row i, row k of r is column s[i * pitch + k - 8].
        // Rows are read as 64-bit words and turned into columns with Transpose8x8, then back for the stores.
        private static void Vertical8(byte* s, int pitch, int kind, byte blimit, byte limit, byte thresh)
        {
            Rows r = default;
            Span16 rows = new(ref r);
            ulong* lo = stackalloc ulong[8];   // columns p7..p0 (k 0..7), or p3..q3 (k 4..11) for kind 4 / 8
            ulong* hi = stackalloc ulong[8];   // columns q0..q7 (k 8..15), kind 16 only
            bool wide = kind == 16;

            for (int i = 0; i < 8; i++)
            {
                byte* row = s + (i * pitch);
                if (wide)
                {
                    lo[i] = Unsafe.ReadUnaligned<ulong>(row - 8);
                    hi[i] = Unsafe.ReadUnaligned<ulong>(row);
                }
                else
                {
                    lo[i] = Unsafe.ReadUnaligned<ulong>(row - 4);
                }
            }

            Transpose8x8(lo);
            if (wide)
            {
                Transpose8x8(hi);
                for (int k = 0; k < 8; k++)
                {
                    rows[k] = Widen(lo[k]);
                    rows[k + 8] = Widen(hi[k]);
                }
            }
            else
            {
                for (int k = 0; k < 8; k++)
                {
                    rows[k + 4] = Widen(lo[k]);
                }
            }

            Run(ref r, kind, blimit, limit, thresh);

            if (wide)
            {
                for (int k = 0; k < 8; k++)
                {
                    lo[k] = Narrow(rows[k]);
                    hi[k] = Narrow(rows[k + 8]);
                }

                Transpose8x8(lo);
                Transpose8x8(hi);
                for (int i = 0; i < 8; i++)
                {
                    byte* row = s + (i * pitch);
                    StoreBytes(row - 8, lo[i], 1, 7);   // p6..p0
                    StoreBytes(row, hi[i], 0, 6);       // q0..q6
                }
            }
            else
            {
                for (int k = 0; k < 8; k++)
                {
                    lo[k] = Narrow(rows[k + 4]);
                }

                Transpose8x8(lo);
                int first = kind == 4 ? 2 : 1, last = kind == 4 ? 5 : 6;   // p1..q1 or p2..q2 within p3..q3
                for (int i = 0; i < 8; i++)
                {
                    StoreBytes(s + (i * pitch) - 4, lo[i], first, last);
                }
            }
        }

        private readonly ref struct Span16
        {
            private readonly ref Rows _r;

            public Span16(ref Rows r) { _r = ref r; }

            public ref Vector128<short> this[int k] => ref Unsafe.Add(ref _r.R0, k);
        }

        public static void LpfHorizontal4(ArrayPtr<byte> s, int pitch, byte blimit, byte limit, byte thresh)
            => Horizontal8(s.ToPointer(), pitch, 4, blimit, limit, thresh);

        public static void LpfHorizontal4Dual(ArrayPtr<byte> s, int pitch, byte blimit0, byte limit0, byte thresh0, byte blimit1, byte limit1, byte thresh1)
        {
            Horizontal8(s.ToPointer(), pitch, 4, blimit0, limit0, thresh0);
            Horizontal8(s.ToPointer() + 8, pitch, 4, blimit1, limit1, thresh1);
        }

        public static void LpfHorizontal8(ArrayPtr<byte> s, int pitch, byte blimit, byte limit, byte thresh)
            => Horizontal8(s.ToPointer(), pitch, 8, blimit, limit, thresh);

        public static void LpfHorizontal8Dual(ArrayPtr<byte> s, int pitch, byte blimit0, byte limit0, byte thresh0, byte blimit1, byte limit1, byte thresh1)
        {
            Horizontal8(s.ToPointer(), pitch, 8, blimit0, limit0, thresh0);
            Horizontal8(s.ToPointer() + 8, pitch, 8, blimit1, limit1, thresh1);
        }

        public static void LpfHorizontal16(ArrayPtr<byte> s, int pitch, byte blimit, byte limit, byte thresh)
            => Horizontal8(s.ToPointer(), pitch, 16, blimit, limit, thresh);

        public static void LpfHorizontal16Dual(ArrayPtr<byte> s, int pitch, byte blimit, byte limit, byte thresh)
        {
            Horizontal8(s.ToPointer(), pitch, 16, blimit, limit, thresh);
            Horizontal8(s.ToPointer() + 8, pitch, 16, blimit, limit, thresh);
        }

        public static void LpfVertical4(ArrayPtr<byte> s, int pitch, byte blimit, byte limit, byte thresh)
            => Vertical8(s.ToPointer(), pitch, 4, blimit, limit, thresh);

        public static void LpfVertical4Dual(ArrayPtr<byte> s, int pitch, byte blimit0, byte limit0, byte thresh0, byte blimit1, byte limit1, byte thresh1)
        {
            Vertical8(s.ToPointer(), pitch, 4, blimit0, limit0, thresh0);
            Vertical8(s.ToPointer() + (8 * pitch), pitch, 4, blimit1, limit1, thresh1);
        }

        public static void LpfVertical8(ArrayPtr<byte> s, int pitch, byte blimit, byte limit, byte thresh)
            => Vertical8(s.ToPointer(), pitch, 8, blimit, limit, thresh);

        public static void LpfVertical8Dual(ArrayPtr<byte> s, int pitch, byte blimit0, byte limit0, byte thresh0, byte blimit1, byte limit1, byte thresh1)
        {
            Vertical8(s.ToPointer(), pitch, 8, blimit0, limit0, thresh0);
            Vertical8(s.ToPointer() + (8 * pitch), pitch, 8, blimit1, limit1, thresh1);
        }

        public static void LpfVertical16(ArrayPtr<byte> s, int pitch, byte blimit, byte limit, byte thresh)
            => Vertical8(s.ToPointer(), pitch, 16, blimit, limit, thresh);

        public static void LpfVertical16Dual(ArrayPtr<byte> s, int pitch, byte blimit, byte limit, byte thresh)
        {
            Vertical8(s.ToPointer(), pitch, 16, blimit, limit, thresh);
            Vertical8(s.ToPointer() + (8 * pitch), pitch, 16, blimit, limit, thresh);
        }
    }
}
