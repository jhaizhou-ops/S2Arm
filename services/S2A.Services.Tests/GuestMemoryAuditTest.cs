using LibHac.Fs;
using Ryujinx.Memory;
using System;
using System.Collections.Generic;
using System.IO;
using Path = System.IO.Path;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace S2A.Services.Tests
{
    // 11-01 全量审计 N3（远端布局地址换算）的服务层两条，期望按接口约定手写、不调被测换算：
    //   P1-17 读盘目标在远端连续块（视图是影子页）且被写跟踪保护：pread 回 EFAULT 改中转读，写钩子收的必须是游戏地址（GuestMemory 约定「写跟踪钩子用游戏地址」）。
    //     游戏地址 lo = g，第 0 块影子在 sh；区域取 lo+0x4000 起 0x8000，影子那两页设只读 → 期望 钩子一次、游戏+0x4000 0x7000。旧代码交影子指针，判红
    //   P2-25 没有 MemMapped 时逐段查询：查询回的段在 va 之前（段尾 ≤ va）→ 期望判未映射、立即返回。旧代码 va 不前进、原地打转（这里 2 秒超时判红）
    public static unsafe partial class Program
    {
        private static readonly List<(ulong Va, ulong Size)> _bounceWrites = new();
        private static byte* _bounceShadow;

        private static void UnprotectShadow(ulong va, ulong size)
        {
            _bounceWrites.Add((va, size));
            mprotect((nint)(_bounceShadow + 0x4000), 0x8000, 3);
        }

        [SoloTest("--far-bounce-va")]
        private static int FarBounceVa()
        {
            const int Chunk = 2 << 20;
            byte* g = (byte*)NativeMemory.AlignedAlloc(Chunk, 0x4000), sh = (byte*)NativeMemory.AlignedAlloc(Chunk, 0x4000);
            long* dir = (long*)NativeMemory.AllocZeroed(1 << 15, sizeof(long));
            FarDesc* desc = (FarDesc*)NativeMemory.AllocZeroed((nuint)sizeof(FarDesc));
            FarDesc* farWas = Native.Far;
            string tf = Path.Combine(Path.GetTempPath(), $"s2a_farbounce_{Environment.ProcessId}.bin");
            byte[] data = new byte[0x8000];
            for (int i = 0; i < data.Length; i++) data[i] = (byte)(i * 5 + 1);
            File.WriteAllBytes(tf, data);
            ulong lo = (ulong)g;

            try
            {
                dir[0] = (long)((ulong)sh - lo);
                desc->Lo = lo;
                desc->Dir = (nint)dir;
                Native.Far = desc;
                GuestMemory.WriteHook = null;
                GuestMemory.WriteQuietHook = null;
                GuestMemory.GpuModifiedHook = null;
                GuestMemory gm = new();
                WritableRegion region = gm.GetWritableRegion(lo + 0x4000, 0x8000, tracked: true);
                Span<byte> dst = region.Memory.Span;
                bool shadowView = (ulong)Unsafe.AsPointer(ref MemoryMarshal.GetReference(dst)) == (ulong)sh + 0x4000;
                mprotect((nint)(sh + 0x4000), 0x8000, 1 /* READ */);
                _bounceShadow = sh;
                _bounceWrites.Clear();
                GuestMemory.WriteHook = &UnprotectShadow;
                var lf = new LazyHostFile(tf, data.Length);
                LibHac.Result lr = lf.Read(out long got, 0x10, dst[..0x7000], ReadOption.None);
                GuestMemory.WriteHook = null;
                bool same = new Span<byte>(sh + 0x4000, 0x7000).SequenceEqual(data.AsSpan(0x10, 0x7000));
                string hooks = string.Join("、", _bounceWrites.ConvertAll(w => w.Va - lo < Chunk ? $"游戏+0x{w.Va - lo:X} 0x{w.Size:X}" : w.Va - (ulong)sh < Chunk ? $"影子+0x{w.Va - (ulong)sh:X} 0x{w.Size:X}" : $"0x{w.Va:X} 0x{w.Size:X}"));
                lf.Dispose();
                region.Dispose();
                string expect = "True / 成功 / 0x7000 / 同文件 / 游戏+0x4000 0x7000";
                string actual = $"{shadowView} / {(lr.IsSuccess() ? "成功" : lr.ToString())} / 0x{got:X} / {(same ? "同文件" : "不同")} / {hooks}";
                bool ok = expect == actual;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 远端读盘中转（视图是影子页 / 结果 / 读到 / 内容 / 写钩子收到）：{expect} → {actual}");
                return ok ? 0 : 1;
            }
            finally
            {
                GuestMemory.WriteHook = null;
                Native.Far = farWas;
                mprotect((nint)(sh + 0x4000), 0x8000, 3);
                NativeMemory.AlignedFree(g);
                NativeMemory.AlignedFree(sh);
                NativeMemory.Free(dir);
                NativeMemory.Free(desc);
                File.Delete(tf);
            }
        }

        // 回的段永远是 [0, 0x1000)：不含 va
        private static int QueryBehind(ulong va, MemInfo* info)
        {
            *info = new MemInfo { Base = 0, Size = 0x1000, State = 5, Perm = 3 };
            return 0;
        }

        // 正对照：每 4 KB 一段、含 va
        private static int QueryPages(ulong va, MemInfo* info)
        {
            *info = new MemInfo { Base = va & ~0xFFFUL, Size = 0x1000, State = 5, Perm = 3 };
            return 0;
        }

        [SoloTest("--mapped-query-progress")]
        private static int MappedQueryProgress()
        {
            delegate*<ulong, ulong, int> mappedWas = Native.MemMapped;
            delegate*<ulong, MemInfo*, int> queryWas = Native.MemQuery;
            Native.MemMapped = null;

            try
            {
                GuestMemory gm = new();
                Native.MemQuery = &QueryPages;
                bool pages = gm.IsRangeMapped(0x10000, 0x3000);
                Native.MemQuery = &QueryBehind;
                Task<bool> t = Task.Run(() => gm.IsRangeMapped(0x10000, 0x2000));
                string behind = t.Wait(2000) ? t.Result.ToString() : "超时（原地打转）";
                string expect = "True / False", actual = $"{pages} / {behind}";
                bool ok = expect == actual;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 逐段映射查询（正对照每 4K 一段 / 查询回的段在 va 之前）：{expect} → {actual}");
                return ok ? 0 : 1;
            }
            finally
            {
                Native.MemQuery = queryWas;
                Native.MemMapped = mappedWas;
            }
        }
    }
}
