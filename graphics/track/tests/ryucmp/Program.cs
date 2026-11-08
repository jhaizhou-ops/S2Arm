// 写跟踪对拍（graphics/track/设计.md「未做」第 1 条）：同一随机访存序列喂两份 Ryujinx 原版 MemoryTracking——
//   参照：内存管理器是 4 KB 权限模型（游戏侧保护域），CPU 写时按权限同步发 VirtualMemoryEvent(guest: true)（= Ryujinx 原版 CPU 侧行为）；
//   我方：TrackingReprotect 转 s2a_track_reprotect，CPU 写走真内存（只读页真缺页 → 信号 → s2a_track_fault），提交前 s2a_track_drain 一次，
//         精确写按 Buffer 合并语义处理（位图字节以 CPU 为准、其余字节用 GPU 数据），普通区间发 VirtualMemoryEvent。
// 每轮：CPU 阶段（随机跟踪写）→ 排空 → 比 → GPU 阶段（随机同步 / GPU 改写 / 信号量写）→ 比。比的是每个 4 KB 句柄的 Dirty 与整段内存逐字节。
// 用法：bash build_run.sh <种子> <轮数>（编 libcmp.dylib + 本工程并跑）。退出码 0 = 全一致。
using Ryujinx.Memory;
using Ryujinx.Memory.Range;
using Ryujinx.Memory.Tracking;
using System;
using System.Buffers;
using System.Collections.Generic;
using System.Runtime.InteropServices;

static unsafe class N {
    const string L = "libcmp";
    [DllImport(L)] public static extern void cmp_install();
    [DllImport(L)] public static extern ulong cmp_alloc(ulong n);
    [DllImport(L)] public static extern void cmp_write(ulong a, byte* v, int n);
    [DllImport(L)] public static extern void cmp_write_untracked(ulong a, byte* v, int n, int flush);
    [DllImport(L)] public static extern void s2a_track_reprotect(ulong a, ulong n, int perm);
    [DllImport(L)] public static extern void s2a_track_drain(Batch* b);
    [StructLayout(LayoutKind.Sequential)] public struct Batch { public Precise* precise; public uint nprecise; public Range* ranges; public uint nranges; public int overflow; }
    [StructLayout(LayoutKind.Sequential)] public struct Range { public ulong addr, size; }
    [StructLayout(LayoutKind.Sequential)] public struct Precise { public ulong addr; public fixed ulong bits[64]; }
}

// 只实现 MemoryTracking 用到的两个成员；其余调到即说明对拍工具写错，直接抛
abstract class VmmBase : IVirtualMemoryManager {
    public bool UsesPrivateAllocations => false;
    public void Map(ulong va, ulong pa, ulong size, MemoryMapFlags flags) => throw new NotSupportedException();
    public void MapForeign(ulong va, nuint hostPointer, ulong size) => throw new NotSupportedException();
    public void Unmap(ulong va, ulong size) => throw new NotSupportedException();
    public T Read<T>(ulong va) where T : unmanaged => throw new NotSupportedException();
    public void Read(ulong va, Span<byte> data) => throw new NotSupportedException();
    public bool TryReadUnsafe(ulong va, int length, out Span<byte> data) => throw new NotSupportedException();
    public void Write<T>(ulong va, T value) where T : unmanaged => throw new NotSupportedException();
    public void Write(ulong va, ReadOnlySpan<byte> data) => throw new NotSupportedException();
    public bool WriteWithRedundancyCheck(ulong va, ReadOnlySpan<byte> data) => throw new NotSupportedException();
    public ReadOnlySequence<byte> GetReadOnlySequence(ulong va, int size, bool tracked = false) => throw new NotSupportedException();
    public ReadOnlySpan<byte> GetSpan(ulong va, int size, bool tracked = false) => throw new NotSupportedException();
    public WritableRegion GetWritableRegion(ulong va, int size, bool tracked = false) => throw new NotSupportedException();
    public ref T GetRef<T>(ulong va) where T : unmanaged => throw new NotSupportedException();
    public IEnumerable<HostMemoryRange> GetHostRegions(ulong va, ulong size) => throw new NotSupportedException();
    public IEnumerable<MemoryRange> GetPhysicalRegions(ulong va, ulong size) => throw new NotSupportedException();
    public bool IsMapped(ulong va) => true;
    public bool IsRangeMapped(ulong va, ulong size) => true;
    public void SignalMemoryTracking(ulong va, ulong size, bool write, bool precise = false, int? exemptId = null) => throw new NotSupportedException();
    public void Reprotect(ulong va, ulong size, MemoryPermission protection) => throw new NotSupportedException();
    public abstract void TrackingReprotect(ulong va, ulong size, MemoryPermission protection, bool guest);
}
sealed class ModelVmm : VmmBase {   // 参照：只记每个 4 KB 的权限
    public readonly MemoryPermission[] Perm; readonly ulong _base;
    public ModelVmm(ulong b, int n) { _base = b; Perm = new MemoryPermission[n]; Array.Fill(Perm, MemoryPermission.ReadAndWrite); }
    public override void TrackingReprotect(ulong va, ulong size, MemoryPermission p, bool guest) { if (!guest) return; for (ulong a = va; a < va + size; a += 0x1000) Perm[(a - _base) / 0x1000] = p; }   // 游戏侧保护域（游戏 CPU 访存）
}
sealed class TrackVmm : VmmBase {   // 我方：权限交 16 KB 跟踪
    public override void TrackingReprotect(ulong va, ulong size, MemoryPermission p, bool guest) { if (guest) N.s2a_track_reprotect(va, size, (int)p); }   // 同 NxTrack.Reprotect
}

static unsafe class Program {
    const int SUB = 0x1000;
    static int Main(string[] args) {
        if (HostRead.Run() != 0) return 3;   // 宿主读 GPU 改过页先回写（HostRead.cs）
        int seed = args.Length > 0 ? int.Parse(args[0]) : 1, rounds = args.Length > 1 ? int.Parse(args[1]) : 2000, npg = 16, nsub = npg * 4;
        var rnd = new Random(seed);
        int tr = int.TryParse(Environment.GetEnvironmentVariable("CMP_TRACE"), out int t0) ? t0 : -1;   // 排查：打印碰到这个子页的每一步
        void T(string m) { if (tr >= 0) Console.WriteLine("  · " + m); }
        ulong bas = N.cmp_alloc((ulong)(npg * 0x4000)); byte* mem = (byte*)bas;
        byte[] refMem = new byte[nsub * SUB];
        var mv = new ModelVmm(bas, nsub); var rt = new MemoryTracking(mv, SUB); var ot = new MemoryTracking(new TrackVmm(), SUB);
        var rh = new RegionHandle[nsub]; var oh = new RegionHandle[nsub];
        byte[] gpu = new byte[nsub];        // 各子页 GPU 侧数据（整页同一值；GPU 改写一次换一个值）
        ulong[] mask = new ulong[64]; int maskSub = -1;   // 我方精确写合并时：位图字节保留 CPU 值
        for (int i = 0; i < nsub; i++) {
            int s = i;
            rh[i] = rt.BeginTracking(bas + (ulong)(i * SUB), SUB, 0); oh[i] = ot.BeginTracking(bas + (ulong)(i * SUB), SUB, 0);
            rh[i].Reprotect(); oh[i].Reprotect();
        }
        N.cmp_install();
        // GPU 回写（PreAction）：参照写模型内存；我方经不跟踪写写真内存（写完通知 → 放回 CPU 先写的字节）
        RegionSignal refFlush(int s) => (a, n) => { for (int k = 0; k < SUB; k++) refMem[s * SUB + k] = gpu[s]; };
        RegionSignal ourFlush(int s) => (a, n) => {
            byte* tmp = stackalloc byte[SUB];
            for (int k = 0; k < SUB; k++) tmp[k] = maskSub == s && (mask[k / 64] >> (k % 64) & 1) != 0 ? mem[s * SUB + k] : gpu[s];
            N.cmp_write_untracked(bas + (ulong)(s * SUB), tmp, SUB, 1);
        };
        long cpuW = 0, prec = 0, rng = 0, syncs = 0, mods = 0, sems = 0, cmps = 0, bad = 0;
        string Cmp(string when, int r) {
            cmps++;
            for (int i = 0; i < nsub; i++) if (rh[i].Dirty != oh[i].Dirty) return $"第 {r} 轮{when}：子页 {i} Dirty 参照 {rh[i].Dirty} 我方 {oh[i].Dirty}";
            for (int k = 0; k < nsub * SUB; k++) if (refMem[k] != mem[k]) return $"第 {r} 轮{when}：字节 +0x{k:x}（子页 {k / SUB}）参照 0x{refMem[k]:x2} 我方 0x{mem[k]:x2}";
            return null;
        }
        byte* v = stackalloc byte[8];
        for (int r = 0; r < rounds && bad == 0; r++) {
            // CPU 阶段：随机跟踪写（1–8 字节，可跨子页 / 跨宿主页；值与两边现内容都不同，避开已知盲区「写入值等于旧值」）
            int nw = rnd.Next(1, 12);
            for (int w = 0; w < nw; w++) {
                int len = rnd.Next(1, 9), off = rnd.Next(0, nsub * SUB - len);
                for (int k = 0; k < len; k++) { byte x; do x = (byte)rnd.Next(256); while (x == refMem[off + k] || x == mem[off + k]); v[k] = x; }
                bool trip = false; for (int s = off / SUB; s <= (off + len - 1) / SUB; s++) trip |= mv.Perm[s] != MemoryPermission.ReadAndWrite;
                if (trip) rt.VirtualMemoryEvent(bas + (ulong)off, (ulong)len, true, precise: false, exemptId: null, guest: true);   // 原版：保护触发即同步发事件（含 PreAction 回写）
                for (int k = 0; k < len; k++) refMem[off + k] = v[k];
                N.cmp_write(bas + (ulong)off, v, len); cpuW++;
                if (tr >= 0 && off / SUB <= tr && (off + len - 1) / SUB >= tr) T($"第 {r} 轮 CPU 写 +0x{off:x} 长 {len}（参照权限 {mv.Perm[tr]}，参照触发 {trip}）");
            }
            // 提交前排空：先精确写（位图字节保留 CPU 值、其余用 GPU 数据，再按原版发事件让句柄记脏 / 消费 PreAction），再普通区间
            N.Batch b; N.s2a_track_drain(&b);
            if (b.overflow != 0) { Console.WriteLine($"✗ 第 {r} 轮：脏页环溢出"); return 1; }
            for (uint i = 0; i < b.nprecise; i++) {
                int s = (int)((b.precise[i].addr - bas) / SUB); for (int k = 0; k < 64; k++) mask[k] = b.precise[i].bits[k]; maskSub = s;
                ot.VirtualMemoryEvent(b.precise[i].addr, SUB, true, precise: false, exemptId: null, guest: true); maskSub = -1; prec++;
                if (s == tr) T($"第 {r} 轮 排空：精确写子页 {s}");
            }
            for (uint i = 0; i < b.nranges; i++) { ot.VirtualMemoryEvent(b.ranges[i].addr, b.ranges[i].size, true, precise: false, exemptId: null, guest: true); rng++;
                if (tr >= 0 && b.ranges[i].addr <= bas + (ulong)(tr * SUB) && b.ranges[i].addr + b.ranges[i].size > bas + (ulong)(tr * SUB)) T($"第 {r} 轮 排空：区间 +0x{b.ranges[i].addr - bas:x} 长 0x{b.ranges[i].size:x}"); }
            string e = Cmp("排空后", r); if (e != null) { Console.WriteLine("✗ " + e); bad++; break; }
            // GPU 阶段：同步（脏 → 上传 → 重设保护）、GPU 改写（先同步，再登记回写 = Ryujinx 原版 NONE）、信号量写（不跟踪）
            int ng = rnd.Next(1, 8);
            for (int g = 0; g < ng; g++) {
                int s = rnd.Next(nsub), op = rnd.Next(10);
                if (s == tr) T($"第 {r} 轮 GPU 操作 {op}（参照 Dirty {rh[s].Dirty}）");
                if (op < 5) { if (rh[s].Dirty) { rh[s].Reprotect(); oh[s].Reprotect(); syncs++; } }
                else if (op < 8) {
                    if (rh[s].Dirty) { rh[s].Reprotect(); oh[s].Reprotect(); }
                    byte nv; do nv = (byte)rnd.Next(256); while (nv == gpu[s]); gpu[s] = nv;
                    rh[s].RegisterAction(refFlush(s)); oh[s].RegisterAction(ourFlush(s)); mods++;
                } else {
                    int off = s * SUB + rnd.Next(0, SUB - 4); for (int k = 0; k < 4; k++) v[k] = (byte)rnd.Next(256);
                    for (int k = 0; k < 4; k++) refMem[off + k] = v[k];
                    N.cmp_write_untracked(bas + (ulong)off, v, 4, 0); sems++;
                }
            }
            e = Cmp("GPU 阶段后", r); if (e != null) { Console.WriteLine("✗ " + e); bad++; break; }
        }
        Console.WriteLine($"{(bad == 0 ? "✓ 一致" : "✗ 不一致")}：种子 {seed}，{rounds} 轮，{nsub} 个 4 KB 句柄（{npg} 个 16 KB 页）；CPU 写 {cpuW}、精确写 {prec} 条、普通区间 {rng} 段、GPU 同步 {syncs}、GPU 改写 {mods}、信号量写 {sems}；比对 {cmps} 次");
        return bad == 0 ? 0 : 1;
    }
}
