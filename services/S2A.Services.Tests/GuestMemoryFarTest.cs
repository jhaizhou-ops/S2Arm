using Ryujinx.Memory;
using Ryujinx.Memory.Range;
using System;
using System.Buffers;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace S2A.Services.Tests
{
    // GuestMemory 远端宿主侧翻译（地址空间线 10-27，接口 v2.13）：假原生层给一张远端描述符（Native.Far），
    //   游戏地址 [g, g+2M) 是近地址（远端之下），[g+2M, g+8M) 是远端第 0 / 1 / 2 块；游戏地址处填哨兵 0xEE（没换算的访问会读到 / 写坏它）。
    //   影子：第 0 块 → sh+4M，第 1 块 → sh，第 2 块 → sh+2M（0、1 两块差值不同、影子不相邻；1、2 两块差值相同、影子首尾相接）。
    //   期望全按这个放法直接写出（FarAt），不调被测换算。
    public static unsafe partial class Program
    {
        private const ulong FarM = 1UL << 20, FarC = 2 * FarM;

        // 游戏地址 x（远端内）按上面的放法应落在影子哪里
        private static byte* FarAt(byte* sh, ulong lo, ulong x) =>
            x - lo < FarC ? sh + 4 * FarM + (x - lo) : x - lo < 2 * FarC ? sh + (x - lo - FarC) : sh + 2 * FarM + (x - lo - 2 * FarC);

        // 影子里游戏地址 [x, x+n) 对应的字节（逐字节按 FarAt 取，跨块也对）
        private static byte[] FarShadow(byte* sh, ulong lo, ulong x, int n)
        {
            byte[] b = new byte[n];

            for (int i = 0; i < n; i++)
            {
                b[i] = *FarAt(sh, lo, x + (ulong)i);
            }

            return b;
        }

        private static byte[] FarSeq(int start, int n)
        {
            byte[] b = new byte[n];

            for (int i = 0; i < n; i++)
            {
                b[i] = (byte)(start + i);
            }

            return b;
        }

        private static string FarHex(ReadOnlySpan<byte> b)
        {
            StringBuilder sb = new();

            for (int i = 0; i < b.Length; i++)
            {
                sb.Append(i == 0 ? "" : " ").Append(b[i].ToString("X2"));
            }

            return sb.ToString();
        }

        private static string FarRanges(IEnumerable<HostMemoryRange> rs, byte* g, byte* sh)
        {
            List<string> s = new();

            foreach (HostMemoryRange r in rs)
            {
                ulong a = (ulong)r.Address;
                s.Add(a - (ulong)sh < 6 * FarM ? $"影子+0x{a - (ulong)sh:X} 0x{r.Size:X}" : $"游戏+0x{a - (ulong)g:X} 0x{r.Size:X}");
            }

            return string.Join("、", s);
        }

        private static void GuestMemoryFar()
        {
            byte* g = FakeNative.Alloc((int)(8 * FarM));
            byte* sh = FakeNative.Alloc((int)(6 * FarM));
            long* dir = (long*)NativeMemory.AllocZeroed(1 << 15, sizeof(long));
            FarDesc* desc = (FarDesc*)NativeMemory.AllocZeroed((nuint)sizeof(FarDesc));
            FarDesc* farWas = Native.Far;
            bool detWas = GuestMemory.Det;
            delegate*<ulong, ulong, void> whWas = GuestMemory.WriteHook, wqWas = GuestMemory.WriteQuietHook;
            delegate*<ulong, ReadOnlySpan<byte>, bool, void> wuWas = GuestMemory.WriteUntrackedHook;
            delegate*<ulong, ulong, bool> gmWas = GuestMemory.GpuModifiedHook;
            ulong gb = (ulong)g, lo = gb + FarC;

            try
            {
                new Span<byte>(g, (int)(8 * FarM)).Fill(0xEE);
                new Span<byte>(sh, (int)(6 * FarM)).Clear();
                dir[0] = (long)((ulong)sh + 4 * FarM - lo);
                dir[1] = (long)((ulong)sh - (lo + FarC));
                dir[2] = (long)((ulong)sh + 2 * FarM - (lo + 2 * FarC));
                desc->Lo = lo;
                Native.Far = desc;
                GuestMemory.Det = false;
                GuestMemory.WriteHook = null;
                GuestMemory.WriteQuietHook = null;
                GuestMemory.WriteUntrackedHook = null;
                GuestMemory.GpuModifiedHook = null;
                GuestMemory gm = new();
                IVirtualMemoryManager vm = gm;

                // ① 远端没开（目录空）：游戏地址原样
                gm.Write<uint>(lo + 0x10, 0x11223344);
                Check("远端没开：写落在游戏地址本身 / 影子不动 / 宿主区间原样", "11223344 / 0 / 游戏+0x200000 0x100",
                    $"{*(uint*)(g + FarC + 0x10):X} / {*(uint*)FarAt(sh, lo, lo + 0x10):X} / {FarRanges(gm.GetHostRegions(lo, 0x100), g, sh)}");

                desc->Dir = (nint)dir;

                // ② 远端开、近地址（远端之下）：原样；跨近 / 远端界的区间：近段原样、远端段换影子
                gm.Write<uint>(gb + 0x1000, 0xCAFEBABE);
                Check("远端开·近地址：写落在游戏地址本身 / 宿主区间原样", "CAFEBABE / 游戏+0x1000 0x100",
                    $"{*(uint*)(g + 0x1000):X} / {FarRanges(gm.GetHostRegions(gb + 0x1000, 0x100), g, sh)}");
                Check("远端开·跨近 / 远端界的宿主区间", "游戏+0x1FFF00 0x100、影子+0x400000 0x100", FarRanges(gm.GetHostRegions(lo - 0x100, 0x200), g, sh));

                // ③ 块内读写
                gm.Write<ulong>(lo + 0x20, 0x0102030405060708);
                *(uint*)FarAt(sh, lo, lo + FarC + 0x40) = 0x55667788;
                gm.GetRef<uint>(lo + 2 * FarC + 0x80) = 7;
                byte inView;

                using (WritableRegion wr = gm.GetWritableRegion(lo + 0x200, 16))
                {
                    wr.Memory.Span.Fill(0x33);
                    inView = *FarAt(sh, lo, lo + 0x20F);
                }

                Check("块内：Write<ulong> 落影子 / 游戏地址哨兵不动 / Read<uint> 读影子 / GetRef 写影子 / 区域即影子（释放前已写到）",
                    "102030405060708 / EEEEEEEEEEEEEEEE / 55667788 / 7 / 33",
                    $"{*(ulong*)FarAt(sh, lo, lo + 0x20):X} / {*(ulong*)(g + FarC + 0x20):X} / {gm.Read<uint>(lo + FarC + 0x40):X} / {*(uint*)FarAt(sh, lo, lo + 2 * FarC + 0x80)} / {inView:X2}");
                Check("块内宿主区间：一段、在影子上", "影子+0x400100 0x100", FarRanges(gm.GetHostRegions(lo + 0x100, 0x100), g, sh));

                // ④ 跨 0、1 两块（差值不同、影子不相邻）读
                ulong x = lo + FarC - 8;

                for (int i = 0; i < 16; i++)
                {
                    *FarAt(sh, lo, x + (ulong)i) = (byte)(i + 1);
                }

                string want16 = FarHex(FarSeq(1, 16));
                byte[] rd = new byte[16];
                gm.Read(x, rd);
                string spanHex = FarHex(gm.GetSpan(x, 16));
                string seqHex = FarHex(gm.GetReadOnlySequence(x, 16).ToArray());
                bool truCross = gm.TryReadUnsafe(x, 16, out _);
                bool truIn = gm.TryReadUnsafe(lo + 0x300, 16, out Span<byte> inSpan);
                ulong inPtr;

                fixed (byte* p = inSpan)
                {
                    inPtr = (ulong)p - (ulong)sh;
                }

                Check("跨块读：Read / GetSpan / GetReadOnlySequence", $"{want16} / {want16} / {want16}", $"{FarHex(rd)} / {spanHex} / {seqHex}");
                Check("跨块读：Read<ulong> 跨界 / TryReadUnsafe 跨块 / TryReadUnsafe 块内（指向影子）", "C0B0A0908070605 / False / True 影子+0x400300",
                    $"{gm.Read<ulong>(x + 4):X} / {truCross} / {truIn} 影子+0x{inPtr:X}");

                // ⑤ 跨 1、2 两块（差值相同、影子首尾相接）：一段连续视图
                bool truAdj = gm.TryReadUnsafe(lo + 2 * FarC - 8, 16, out Span<byte> adjSpan);
                ulong adjPtr;

                fixed (byte* p = adjSpan)
                {
                    adjPtr = (ulong)p - (ulong)sh;
                }

                Check("跨 1、2 块（差值相同）：TryReadUnsafe 给一段连续视图", "True 影子+0x1FFFF8", $"{truAdj} 影子+0x{adjPtr:X}");

                // ⑥ 跨 0、1 两块写
                gm.Write(x, FarSeq(0xA0, 16));
                string w1 = FarHex(FarShadow(sh, lo, x, 16));
                gm.Write<ulong>(x + 4, 0x1122334455667788);
                string w2 = FarHex(FarShadow(sh, lo, x + 4, 8));
                gm.WriteUntracked(x, FarSeq(0xB0, 16));
                string w3 = FarHex(FarShadow(sh, lo, x, 16));
                bool rcSame = gm.WriteWithRedundancyCheck(x, FarSeq(0xB0, 16));
                bool rcDiff = gm.WriteWithRedundancyCheck(x, FarSeq(0xC0, 16));
                string w4 = FarHex(FarShadow(sh, lo, x, 16));
                Check("跨块写：Write / Write<ulong> 跨界 / WriteUntracked", $"{FarHex(FarSeq(0xA0, 16))} / 88 77 66 55 44 33 22 11 / {FarHex(FarSeq(0xB0, 16))}", $"{w1} / {w2} / {w3}");
                Check("跨块冗余检查写：同值 / 变了、内容", $"False / True、{FarHex(FarSeq(0xC0, 16))}", $"{rcSame} / {rcDiff}、{w4}");

                // ⑦ 跨块 GetWritableRegion：副本、释放时分段写回；Fill 经它
                WritableRegion cr = gm.GetWritableRegion(x, 16);
                string copyIn = FarHex(cr.Memory.Span);
                cr.Memory.Span.Fill(0x5A);
                string before = FarHex(FarShadow(sh, lo, x, 16));
                cr.Dispose();
                string after = FarHex(FarShadow(sh, lo, x, 16));
                vm.Fill(x, 16, 0x6B);
                string filled = FarHex(FarShadow(sh, lo, x, 16));
                byte[] five = new byte[16], six = new byte[16];
                five.AsSpan().Fill(0x5A);
                six.AsSpan().Fill(0x6B);
                Check("跨块区域：副本初值 = 影子现值 / 释放前影子不变 / 释放后写回 / Fill",
                    $"{FarHex(FarSeq(0xC0, 16))} / {FarHex(FarSeq(0xC0, 16))} / {FarHex(five)} / {FarHex(six)}", $"{copyIn} / {before} / {after} / {filled}");

                // ⑧ 跨块 GetRef：报错
                bool thrown = false;

                try
                {
                    gm.GetRef<ulong>(x + 4);
                }
                catch (InvalidMemoryRegionException)
                {
                    thrown = true;
                }

                Check("跨块 GetRef<ulong>：抛 InvalidMemoryRegionException", "True", thrown.ToString());

                // ⑨ 跟踪钩子用游戏地址；写跟踪代写只收近地址，远端段直接写影子
                GuestMemory.WriteHook = &RecordWrite;
                _writes.Clear();
                gm.GetWritableRegion(x, 16, tracked: true).Dispose();
                GuestMemory.WriteHook = null;
                GuestMemory.WriteUntrackedHook = &RecordUntracked;
                _untracked.Clear();
                gm.Write(x, FarSeq(0xD0, 16));
                gm.Write(gb + 0x2000, new byte[] { 1, 2, 3, 4 });
                GuestMemory.WriteUntrackedHook = null;
                Check("钩子：跟踪区域 WriteHook 收游戏地址 / 代写钩子只收近地址的写 / 远端写落影子",
                    $"游戏+0x3FFFF8 16 / 游戏+0x2000 4 False / {FarHex(FarSeq(0xD0, 16))}",
                    $"{string.Join("、", _writes.ConvertAll(w => $"游戏+0x{w.Va - gb:X} {w.Size}"))} / {string.Join("、", _untracked.ConvertAll(w => $"游戏+0x{w.Va - gb:X} {w.Size} {w.Flush}"))} / {FarHex(FarShadow(sh, lo, x, 16))}");

                // ⑩ 跨块的宿主区间：0 块尾 0x100 一段；1 块整块 + 2 块头 0x100 影子首尾相接，并成一段
                Check("跨块宿主区间：按块切段、首尾相接的并段", "影子+0x5FFF00 0x100、影子+0x0 0x200100",
                    FarRanges(gm.GetHostRegions(lo + FarC - 0x100, FarC + 0x200), g, sh));

                // 远端内所有经 GuestMemory 的访问都不碰游戏地址：哨兵整段仍是 0xEE（①写过的 +0x10 4 字节、③GetRef 写的块 2 处除外的段：只核 ④–⑩ 用到的 [x, x+16)）
                Check("跨块访问不碰游戏地址：[x, x+16) 哨兵", "True", (new Span<byte>((void*)x, 16).IndexOfAnyExcept((byte)0xEE) < 0).ToString());
            }
            finally
            {
                Native.Far = farWas;
                GuestMemory.Det = detWas;
                GuestMemory.WriteHook = whWas;
                GuestMemory.WriteQuietHook = wqWas;
                GuestMemory.WriteUntrackedHook = wuWas;
                GuestMemory.GpuModifiedHook = gmWas;
                FakeNative.Free(g);
                FakeNative.Free(sh);
                NativeMemory.Free(dir);
                NativeMemory.Free(desc);
            }
        }
    }
}
