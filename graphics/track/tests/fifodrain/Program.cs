// 写跟踪 × GPFIFO 排空时机单测（graphics/track/设计.md 第 11 条「事件延后到提交前排空」的前提；守补丁 0122 GPFifoDevice.S2ATrackSync）。
// Ryujinx 原版：游戏 CPU 写被跟踪内存当场发事件；我方延后到排空。GPU 线程一次 DispatchCalls 会连续取走队列里的全部命令，
// 包括本轮排空之后游戏才提交的——游戏在提交前写的数据，处理到那条命令时必须已报给 MemoryTracking（句柄 Dirty），
// 否则缓冲缓存按「没变」用旧内容（10-21 暗黑2：计算着色器参数块读到旧的浮点数据，循环次数成乱值，GPU 跑到挂死；同日八方2 选项页屏闪同一机制）。
// 全用真件：Ryujinx GpuContext / GPFifoDevice / GpuChannel / MemoryTracking、track.c 真缺页、产品 NxTrack.cs；渲染器是空桩（这里不画）。
// 用例（期望值按 Ryujinx 原版「写即报脏」得出，不跑被测实现）：
//   ① 跨命令写：渲染循环排空后起 DispatchCalls；处理命令 A 时（同步点回调 = 游戏线程并发）游戏写被跟踪子页、提交命令 B → 处理 B 时句柄 Dirty = true
//   ② 正对照：写发生在渲染循环那次排空之前 → 处理时 Dirty = true（旧路径也覆盖，证明本工具认得出脏）
//   ③ 没写 → 处理时 Dirty = false（逐条排空不制造假脏）
//   ④ 写后解除映射（10-26 Torchlight III）：游戏写被跟踪子页，排空前这段的跟踪区域拆掉、内存管理器报未映射 → 排空不抛（原版在写的当下发事件，那时还映射着；拆掉后没有区域要通知）。
//      旧 NxTrack 照发 VirtualMemoryEvent，MemoryTracking 对「没区域、没映射」抛 InvalidMemoryRegionException，GPU 模拟线程整个退出
// 用法：bash build_run.sh（编 libs2a_native.dylib + 本工程并跑）。退出码 0 = 全过。
using NxGal;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Engine.GPFifo;
using Ryujinx.Memory;
using Ryujinx.Memory.Range;
using Ryujinx.Memory.Tracking;
using System;
using System.Buffers;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.InteropServices;

static unsafe class N {
    const string L = "s2a_native";
    [DllImport(L)] public static extern void cmp_install();
    [DllImport(L)] public static extern ulong cmp_alloc(ulong n);
    [DllImport(L)] public static extern void cmp_write(ulong a, byte* v, int n);
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
    public virtual bool IsRangeMapped(ulong va, ulong size) => true;
    public void SignalMemoryTracking(ulong va, ulong size, bool write, bool precise = false, int? exemptId = null) => throw new NotSupportedException();
    public void Reprotect(ulong va, ulong size, MemoryPermission protection) => throw new NotSupportedException();
    public abstract void TrackingReprotect(ulong va, ulong size, MemoryPermission protection, bool guest);
}
sealed class TrackVmm : VmmBase {   // 同产品 GuestMemory：保护交 NxTrack.Reprotect（游戏侧域交 16 KB 跟踪）
    public override void TrackingReprotect(ulong va, ulong size, MemoryPermission p, bool guest) => NxTrack.Reprotect(va, size, p, guest);
    public ulong UnmapLo, UnmapHi;   // ④：这段报未映射（游戏解除了映射）
    public override bool IsRangeMapped(ulong va, ulong size) => !(va < UnmapHi && va + size > UnmapLo);
}

// 渲染器空桩：接口方法一律返回缺省值（返回接口的给一个同样的空桩），GPFIFO 处理同步点命令时用不到真画
public class StubProxy : DispatchProxy {
    protected override object Invoke(MethodInfo m, object[] a) {
        Type t = m.ReturnType;
        if (t == typeof(void)) return null;
        if (t.IsInterface) return Create(t, typeof(StubProxy));
        return t.IsValueType ? Activator.CreateInstance(t) : null;
    }
}

static unsafe class P {
    const ulong SUB = 0x1000, PG = 0x4000;
    // 同步点 id 自增一次的主机命令缓冲（照 NvHostChannelDeviceFile.BuildIncrementCommandBuffer：SyncpointA = 0、SyncpointB = id << 8 | 自增）
    static int[] Incr(uint id) => [0x2001001C, 0, 0x2001001D, (int)(id << 8) | 1];

    static int Main() {
        N.cmp_install();
        ulong bas = N.cmp_alloc(4 * PG);
        var vmm = new TrackVmm(); var tracking = new MemoryTracking(vmm, (int)SUB);
        // 三个用例各占一个 16 KB 宿主页的首个 4 KB 子页（互不牵连）
        var h = new RegionHandle[3];
        for (int i = 0; i < 3; i++) { h[i] = tracking.BeginTracking(bas + (ulong)i * PG, SUB, 0); h[i].Reprotect(); }

        var ctx = new GpuContext((IRenderer)DispatchProxy.Create(typeof(IRenderer), typeof(StubProxy)), new Ryujinx.Common.Configuration.DirtyHacks(Array.Empty<ulong>()));
        var ch = ctx.CreateChannel();

        // 照产品渲染循环（graphics/loop/RenderLoop.cs Start）：登记写跟踪、装 GPFIFO 排空挂钩 GPFifoDevice.S2ATrackSync（补丁 0122：处理入队晚于上次排空的命令前先排空），
        // 渲染循环唤醒时那次排空走 GPFifo.S2ASync()（记下已入队序号再排空）。按名字找：旧代码没有挂钩时照常编译、渲染循环直接 NxTrack.Drain（反证用）
        NxTrack.Init(tracking);
        FieldInfo hook = typeof(GPFifoDevice).GetField("S2ATrackSync", BindingFlags.Public | BindingFlags.Static);
        MethodInfo sync = typeof(GPFifoDevice).GetMethod("S2ASync", BindingFlags.Public | BindingFlags.Instance);
        if (hook != null && sync != null) hook.SetValue(null, (Action)(() => NxTrack.Drain(tracking)));
        Console.WriteLine(hook != null && sync != null ? "GPFIFO 排空挂钩（S2ATrackSync）：已装" : "GPFIFO 排空挂钩：代码里没有（旧代码）");
        // 渲染循环 WaitFifo 返回后、ProcessFrame 前的那次排空（同产品 RenderLoop）
        Action loopDrain = hook != null && sync != null ? () => sync.Invoke(ctx.GPFifo, null) : () => NxTrack.Drain(tracking);

        byte* v = stackalloc byte[4]; v[0] = 0x11; v[1] = 0x22; v[2] = 0x33; v[3] = 0x44;
        bool[] got = new bool[3]; bool[] seen = new bool[3];

        // ① 命令 A（同步点 1）处理中：游戏写子页 0、提交命令 B（同步点 2）；B 处理时读句柄 0
        ctx.Synchronization.RegisterCallbackOnSyncpoint(1, 1, _ => { N.cmp_write(bas, v, 4); ch.PushHostCommandBuffer(Incr(2)); });
        ctx.Synchronization.RegisterCallbackOnSyncpoint(2, 1, _ => { got[0] = h[0].Dirty; seen[0] = true; });
        ch.PushHostCommandBuffer(Incr(1));
        loopDrain();   // 渲染循环：WaitFifo 返回后、ProcessFrame 前排空一次
        ctx.GPFifo.DispatchCalls();

        // ② 正对照：写在渲染循环那次排空之前
        ctx.Synchronization.RegisterCallbackOnSyncpoint(3, 1, _ => { got[1] = h[1].Dirty; seen[1] = true; });
        N.cmp_write(bas + PG, v, 4);
        ch.PushHostCommandBuffer(Incr(3));
        loopDrain();
        ctx.GPFifo.DispatchCalls();

        // ③ 没写
        ctx.Synchronization.RegisterCallbackOnSyncpoint(4, 1, _ => { got[2] = h[2].Dirty; seen[2] = true; });
        ch.PushHostCommandBuffer(Incr(4));
        loopDrain();
        ctx.GPFifo.DispatchCalls();

        // ④ 写后解除映射：第 4 个宿主页登记跟踪、游戏写，排空前拆掉区域并报未映射，再排空
        var h3 = tracking.BeginTracking(bas + 3 * PG, SUB, 0); h3.Reprotect();
        N.cmp_write(bas + 3 * PG, v, 4);
        h3.Dispose(); vmm.UnmapLo = bas + 3 * PG; vmm.UnmapHi = bas + 4 * PG;
        string drainErr = null;
        try { NxTrack.Drain(tracking); } catch (Exception e) { drainErr = e.GetType().Name; }

        string[] name = ["① 跨命令写（排空后、处理 A 时写并提交 B）", "② 正对照（写在排空前）", "③ 没写"];
        bool[] want = [true, true, false];
        int fail = drainErr == null ? 0 : 1;
        Console.WriteLine($"④ 写后解除映射再排空：期望 不抛 → 真结果 {(drainErr == null ? "不抛 ✓" : $"抛 {drainErr} ✗")}");
        for (int i = 0; i < 3; i++) {
            bool ok = seen[i] && got[i] == want[i]; fail += ok ? 0 : 1;
            Console.WriteLine($"{name[i]}：期望 处理时 Dirty={want[i]} → 真结果 {(seen[i] ? $"Dirty={got[i]}" : "命令没被处理")} {(ok ? "✓" : "✗")}");
        }
        Console.WriteLine($"fifodrain：4 项，失败 {fail}");
        return fail == 0 ? 0 : 1;
    }
}
