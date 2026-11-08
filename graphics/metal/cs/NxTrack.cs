// 写跟踪的 C# 一半（graphics/track/设计.md「C# 侧」）：服务接入线的 GuestMemory 挂这里——
//   GuestMemory.ReprotectHook = &NxTrack.Reprotect；WriteUntracked → NxTrack.WriteUntracked；每次 GPU 提交前 NxTrack.Drain(guestMemory.Tracking)。
// 16 KB 页保护 / 缺页 / 内容比对在 C 侧（graphics/track/track.c，静态链在宿主，DirectPInvoke s2a_native）。稳态零分配。
using Ryujinx.Memory;
using Ryujinx.Memory.Tracking;
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace NxGal
{
    public static unsafe class NxTrack
    {
        const string L = "s2a_native";
        [DllImport(L)] static extern void s2a_track_reprotect(ulong a, ulong n, int perm);
        [DllImport(L)] static extern void s2a_track_write_untracked(ulong a, byte* src, ulong n, int flush);
        [DllImport(L)] static extern void s2a_track_drain(Batch* b);
        [StructLayout(LayoutKind.Sequential)] struct Batch { public Precise* precise; public uint nprecise; public Range* ranges; public uint nranges; public int overflow; }
        [StructLayout(LayoutKind.Sequential)] struct Range { public ulong addr, size; }
        [StructLayout(LayoutKind.Sequential)] struct Precise { public ulong addr; public fixed ulong bits[64]; }
        const int SUB = 0x1000;
        static readonly Lock _drain = new();
        static int _ovRed;

        // TrackingReprotect(va, size, protection, guest)：Ryujinx 每个跟踪句柄有两套区域、两个保护域（照 Ryujinx.Cpu MemoryManager / MemoryManagerHostTracked）：
        //   guest = true：游戏代码直接访存的那份映射——对我们就是唯一那份真实映射，交 16 KB 页保护；
        //   guest = false：服务 / GPU 经内存管理器的托管访存，Ryujinx 用软件页表判要不要发事件、不碰页保护。我们的 GuestMemory 对托管写一律发事件
        //   （等价于这一域全程跟踪），所以这一域无需保护，忽略。（10-19 前两域都落到同一份页保护上、后到的覆盖先到的：M0 局报过红）
        public static void Reprotect(ulong va, ulong size, MemoryPermission protection, bool guest)
        {
            // 拦写模拟：缓冲登记回写动作期间（MemoryTracking.S2ABufferNone）的 None 带「缓冲担保」位（graphics/track/s2a_track.h S2A_TRACK_FROM_BUFFER）
            if (guest) s2a_track_reprotect(va, size, (int)protection | (MemoryTracking.S2ABufferNone && protection == MemoryPermission.None ? 0x100 : 0));
        }

        // 拦写模拟：GPU 改过的字节表（Ryujinx MemoryTracking.S2AModSet / S2AModClear 钩子；见 track.c s2a_track_mod_set）
        [DllImport(L)] static extern void s2a_track_mod_set(ulong a, ulong n);
        [DllImport(L)] static extern void s2a_track_mod_clear(ulong a, ulong n);
        [DllImport(L)] static extern void s2a_track_drain_done();
        static void ModSet(ulong va, ulong size) => s2a_track_mod_set(va, size);
        static void ModClear(ulong va, ulong size) => s2a_track_mod_clear(va, size);

        // 托管跟踪写（GuestMemory.Write / GetWritableRegion(tracked) / GetRef / Fill 等）真正写之前调：页若被游戏侧保护为只读，先按 CPU 写解开并记脏，
        // 否则托管代码写到只读页会在 C# 里缺页
        public static void Write(ulong va, ulong size) => s2a_track_write(va, size);
        [DllImport(L)] static extern void s2a_track_write(ulong a, ulong n);

        // 不跟踪托管写（GetWritableRegion(tracked: false)：服务写 IPC 缓冲等）真正写之前调：只解开只读页、报脏，不触发 GPU 改过子页的先回写（见 track.c s2a_track_write_quiet）
        public static void WriteQuiet(ulong va, ulong size) => s2a_track_write_quiet(va, size);
        [DllImport(L)] static extern void s2a_track_write_quiet(ulong a, ulong n);

        // 宿主读游戏内存、不经页保护（Ryujinx MemoryTracking.S2AReadUntracked 钩子；见 track.c s2a_track_read_untracked）
        static void ReadUntracked(ulong va, byte* dst, int len) => s2a_track_read_untracked(va, dst, (ulong)len);
        static void ReprotectRaw(ulong va, ulong size, int perm) => s2a_track_reprotect(va, size, perm);
        [DllImport(L)] static extern int s2a_track_read_untracked(ulong va, byte* dst, ulong n);
        [DllImport(L)] static extern int s2a_track_copy_precise(ulong va, byte* dst, ulong n);
        [DllImport(L)] static extern void s2a_track_restore_precise(ulong va, byte* src, ulong n);

        // 定向读时回写登记（Ryujinx MemoryTracking.S2AMarkReadFlush 钩子；见 track.c s2a_track_mark_readflush）
        public static void MarkReadFlush(ulong va, ulong size) => s2a_track_mark_readflush(va, size);
        [DllImport(L)] static extern void s2a_track_mark_readflush(ulong a, ulong n);

        // 宿主页写跟踪状态（诊断：着色器防线红行用，Ryujinx MemoryTracking.S2ATrackPageInfo 钩子；见 s2a_track.h s2a_track_page_info）。
        // 动态加载 s2a_native 而原生层没这个导出时 DllImport 抛 EntryPointNotFoundException → 钩子留空 = 未提供
        [DllImport(L)] static extern ulong s2a_track_page_info(ulong addr);
        static ulong PageInfo(ulong addr) => s2a_track_page_info(addr);
        static bool PageInfoProvided()
        {
            try { s2a_track_page_info(0); return true; }
            catch (EntryPointNotFoundException) { return false; }
        }

        // [va, va+size) 涉及的子页里有没有 GPU 改过、还没回写的（GuestMemory.GpuModifiedHook）
        public static bool GpuModified(ulong va, ulong size) => s2a_track_gpu_modified(va, size) != 0;
        [DllImport(L)] static extern int s2a_track_gpu_modified(ulong a, ulong n);

        // WriteUntracked（GPU 回写 Flush）：由 C 侧代为复制并记基线，回写写完放回 CPU 先写、还没报的字节
        public static void WriteUntracked(ulong va, ReadOnlySpan<byte> data, bool flush = true)
        {
            if (data.Length == 0) return;
            fixed (byte* p = data) s2a_track_write_untracked(va, p, (ulong)data.Length, flush ? 1 : 0);
        }

        // A 方案（graphics/track/track.c「GPU 改过页的 CPU 首写」）：游戏代码写到 GPU 改过的页时，原生层把线程改道到正常上下文回调这里——
        // 照 Ryujinx 原版缺页处理，对该子页发 VirtualMemoryEvent：Ryujinx 当场把 GPU 数据回写进游戏内存、改保护，回去再重执行 CPU 的写
        static MemoryTracking _touchTracking;
        static Action<ulong, ulong> _remapped;
        static Action<Exception> _failure;
        [DllImport(L)] static extern void s2a_track_set_touch(delegate* unmanaged<ulong, ulong, int, void> cb);
        public static void Init(MemoryTracking tracking, Action<ulong, ulong> remapped = null, Action<Exception> failure = null)
        {
            _touchTracking = tracking;
            _remapped = remapped;
            _failure = failure;
            MemoryTracking.S2AMarkReadFlush = MarkReadFlush;
            MemoryTracking.S2AReadUntracked = &ReadUntracked;
            MemoryTracking.S2AReprotect = &ReprotectRaw;
            MemoryTracking.S2AModSet = &ModSet;
            MemoryTracking.S2AModClear = &ModClear;
            MemoryTracking.S2ATrackPageInfo = PageInfoProvided() ? &PageInfo : null;
            s2a_track_set_touch(&Touch);
            s2a_track_set_remap_cb(&Remapped);
        }
        // Only after all guest/GPU/counter callbacks have joined and tracking handles were disposed.
        public static void ResetSession()
        {
            lock (_drain)
            {
                s2a_track_set_touch(null);
                s2a_track_set_remap_cb(null);
                MemoryTracking.S2AMarkReadFlush = null;
                MemoryTracking.S2AReadUntracked = null;
                MemoryTracking.S2AReprotect = null;
                MemoryTracking.S2AModSet = null;
                MemoryTracking.S2AModClear = null;
                MemoryTracking.S2ATrackPageInfo = null;
                _touchTracking = null; _remapped = null; _failure = null; _ovRed = 0; _staleLog = 0;
            }
        }
        // 原生层报游戏内存某段物理页被换掉（共享内存映射 / 解除）：渲染器零拷贝缓冲作废别名、对新页重建（缓冲零拷贝，10-23）
        [DllImport(L)] static extern void s2a_track_set_remap_cb(delegate* unmanaged<ulong, ulong, void> cb);
        [UnmanagedCallersOnly]
        static void Remapped(ulong va, ulong size)
        {
            if (_remapped == null) nxgal_host_remapped(va, size);
            else
            {
                try { _remapped(va, size); }
                catch (Exception e) { if (_failure != null) _failure(e); else throw; }
            }
        }
        // 渲染器入口（不经 NxRenderer 的 N：只编 NxTrack 的单测不带 NxRenderer.cs）
        [DllImport("nxgal")] static extern void nxgal_host_remapped(ulong addr, ulong size);

        [UnmanagedCallersOnly]
        static void Touch(ulong va, ulong size, int write)
        {
            // 读分支与 GuestMemory 的托管不跟踪读共用 S2AReadFlush：同一个读跟踪事件（S2AReadTouch 置位 =
            // 部分回写只回写所碰子页，见 MemoryTracking.S2AReadTouch），回写在正常上下文跑完再返回
            try
            {
                if (write == 0) _touchTracking.S2AReadFlush(va, size);
                else _touchTracking.VirtualMemoryEvent(va, size, true, precise: false, exemptId: null, guest: true);
            }
            catch (Exception e)
            {
                if (_failure != null) _failure(e);
                else Console.Error.WriteLine($"[gal] 【红】写跟踪：GPU 改过页先回写失败 {va:x}+{size:x}：{e}");
            }
        }

        // 提交前排空：先精确写（GPU 改过子页里 CPU 真写了的字节），再普通区间。
        // 精确写按位图里每段连续字节发 Ryujinx 精确事件：缓冲（Buffer.PreciseAction）只把这几段从「GPU 改过」里打穿、记脏，不回写、不等 GPU——
        // 段外 GPU 改过的字节留在 GPU 侧，结果与原版「先回写、再让 CPU 写」逐字节相同（设计.md「C# 侧」第 1 条）；没有精确动作的句柄（贴图）照旧回写，
        // 回写若盖掉了 CPU 的字节，按位图放回。段数超过 PreciseRunsMax 的子页整页按普通写事件发（回写 + 放回，修前做法），免得一页几千个事件。
        // 修前整子页一律按普通写事件发：每条都等 GPU 回写（10-21 怪猎 Mac 局排空精确写这一路占读回的约 1/6）
        const int PreciseRunsMax = 64;
        // 普通写事件：排空时记录可能已过期——游戏写完、排空之前就解除了这段映射（10-26 Torchlight III 010075400DDB8000：GPU 模拟线程崩在这里）。
        //   原版在写的当下发事件（那时还映射着），解除映射时区域与句柄一起拆掉；排空时整段已不在映射里，就没有任何区域要通知，跳过与原版结果相同。
        //   MemoryTracking 对「没区域、也没映射」抛 InvalidMemoryRegionException（原版那是真缺页、无法继续）；产品的 GuestMemory 建跟踪时没给无效访问回调，这里接住即可
        static int _staleLog;
        static void WriteEvent(MemoryTracking tracking, ulong va, ulong size)
        {
            try { tracking.VirtualMemoryEvent(va, size, true, precise: false, exemptId: null, guest: true); }
            catch (InvalidMemoryRegionException) { if (Interlocked.Exchange(ref _staleLog, 1) == 0) Console.Error.WriteLine($"[gal] 写跟踪：排空时 {va:x}+{size:x} 已不在映射里（游戏写后解除了映射），这条跳过（首例）"); }
        }
        public static void Drain(MemoryTracking tracking)
        {
            lock (_drain)
            {
                Batch b; s2a_track_drain(&b);
                byte* cpu = stackalloc byte[SUB], merged = stackalloc byte[SUB];
                // 排空期（drain → drain_done）：苹果上原生层换页事务等它结束才改保护 / 换页；中途抛错也必须收尾，否则改表系统调用永远等
                try
                {
                for (uint i = 0; i < b.nprecise; i++)
                {
                    Precise* r = &b.precise[i];
                    // READFLUSH may have rearmed this page PROT_NONE during
                    // drain. Use the existing read-only shared alias instead
                    // of weakening guest protection or reading it directly.
                    // 苹果同（10-28 审计 #806 第 5 条：原先苹果直接解引用客人页，不可读页缺页、被放成只读，客人之后的读不再先回写）
                    s2a_track_copy_precise(r->addr, cpu, SUB);
                    int runs = 0;
                    for (int k = 0; k < SUB; k++) if ((r->bits[k >> 6] >> (k & 63) & 1) != 0 && (k == 0 || (r->bits[(k - 1) >> 6] >> ((k - 1) & 63) & 1) == 0)) runs++;
                    if (runs > PreciseRunsMax)
                    {
                        // 游戏写：发给游戏侧区域
                        WriteEvent(tracking, r->addr, SUB);
                    }
                    else
                    {
                        for (int k = 0; k < SUB; )
                        {
                            if ((r->bits[k >> 6] >> (k & 63) & 1) == 0) { k++; continue; }
                            int k0 = k;
                            while (k < SUB && (r->bits[k >> 6] >> (k & 63) & 1) != 0) k++;
                            tracking.VirtualMemoryEvent(r->addr + (ulong)k0, (ulong)(k - k0), true, precise: true, exemptId: null, guest: true);
                        }
                    }
                    bool lost = false;
                    // The tracking callback may leave or make the page
                    // unreadable again; the post-callback comparison must use
                    // the same protected-safe read as the initial snapshot.
                    s2a_track_copy_precise(r->addr, merged, SUB);
                    for (int k = 0; k < SUB && !lost; k++) lost = (r->bits[k >> 6] >> (k & 63) & 1) != 0 && merged[k] != cpu[k];
                    if (!lost) continue;
                    for (int k = 0; k < SUB; k++) if ((r->bits[k >> 6] >> (k & 63) & 1) != 0) merged[k] = cpu[k];
                    s2a_track_restore_precise(r->addr, merged, SUB);
                }
                for (uint i = 0; i < b.nranges; i++) WriteEvent(tracking, b.ranges[i].addr, b.ranges[i].size);
                }
                finally
                {
                    s2a_track_drain_done();   // 拦写模拟：精确写处理完，模拟写恢复（排空开始到这里之间的写走老路）；苹果换页事务放行
                }
                if (b.overflow != 0 && Interlocked.Exchange(ref _ovRed, 1) == 0) Console.Error.WriteLine("[gal] 【红】写跟踪：脏页环溢出，本批已按全部跟踪区间通知（首例）");
            }
        }
    }
}
