// 回写锁顺序单测（帧率能耗线 10-23，原生层线 Mac 塞尔达卡死现场）：GPU 数据回写客体内存（Buffer.FlushImpl）是在
// BufferModifiedRangeList.WaitForAndFlushRanges 持区间表写锁时调的；回写若再发跟踪事件（MemoryTracking.VirtualMemoryEvent 要拿 TrackingLock），
// 就和 GPU 线程「持 TrackingLock → Buffer.PreciseAction → 区间表 Clear 等区间表写锁」成 ABBA 死锁（0163 / 0178 回写别名即此，0181 删掉）。
// 上游语义：回写走不触发跟踪的写，持区间表锁期间不碰 TrackingLock。
// 用例（期望按锁序直接定，不跑被测实现推）：线程 G 先拿 TrackingLock；线程 A 经区间表回写同一段；A 进入等待后 G 再清这段的修改区间（要区间表写锁）。
//   ① 3 秒内 A、G 都做完（不互等）；② 回写确实发生（客体内存变成 GPU 侧数据 0x5A）。旧代码（回写别名在）① 不成立 = 复现死锁。
// 全用真件：Ryujinx GpuContext / PhysicalMemory / Buffer / BufferModifiedRangeList / MemoryTracking、产品 GuestMemory；渲染器是桩（GetBufferData 回 0x5A）。
// 用法：bash build_run.sh。退出码 0 = 全过
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Memory.Tracking;
using S2A.Services;
using System;
using System.Reflection;
using System.Runtime.InteropServices;

namespace S2A.Services
{
    // GuestMemory 引用的产品原生入口与报红：单测不开确定性档、不接原生层（同产品单测「假原生层没有时退回」的路径）
#pragma warning disable CS0649
    static unsafe class Native
    {
        public static delegate* unmanaged<int> DetMode;
        public static delegate* unmanaged<ulong, void*, ulong, void> DetHostWrite;
        public static delegate*<ulong, MemInfo*, int> MemQuery;
        public static delegate*<ulong, ulong, int> MemMapped;
        public static FarDesc* Far = (FarDesc*)NativeMemory.AllocZeroed((nuint)sizeof(FarDesc));   // 远端没开（同产品 Native.Far 缺省）
    }
#pragma warning restore CS0649

    [StructLayout(LayoutKind.Sequential)]
    public struct MemInfo
    {
        public ulong Base, Size;
        public uint State, Attr, Perm, Pad;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct FarDesc
    {
        public ulong Lo;
        public nint Dir;
    }

    static class Red
    {
        public static void Report(string what, string detail) => Console.WriteLine($"【红】{what} {detail}");
    }
}

public unsafe class StubProxy : DispatchProxy
{
    public static readonly byte* Gpu = (byte*)NativeMemory.AllocZeroed(0x1000);

    protected override object Invoke(MethodInfo m, object[] a)
    {
        Type t = m.ReturnType;
        if (m.Name == "GetBufferData") return new Ryujinx.Graphics.GAL.PinnedSpan<byte>(Gpu, (int)a[2], null);
        if (t == typeof(void)) return null;
        if (t.IsInterface) return Create(t, typeof(StubProxy));
        return t.IsValueType ? Activator.CreateInstance(t) : null;
    }
}

static unsafe class P
{
    const ulong Size = 0x1000;

    static int Main()
    {
        Assembly gpu = typeof(GpuContext).Assembly;
        Type tPhys = gpu.GetType("Ryujinx.Graphics.Gpu.Memory.PhysicalMemory", true);
        Type tBuf = gpu.GetType("Ryujinx.Graphics.Gpu.Memory.Buffer", true);
        Type tStage = gpu.GetType("Ryujinx.Graphics.Gpu.Memory.BufferStage", true);
        const BindingFlags Any = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;

        ulong addr = (ulong)NativeMemory.AlignedAlloc(0x10000, 0x4000);
        new Span<byte>((void*)addr, 0x10000).Clear();
        new Span<byte>(StubProxy.Gpu, 0x1000).Fill(0x5a);

        var gm = new GuestMemory();
        var ctx = new GpuContext((IRenderer)DispatchProxy.Create(typeof(IRenderer), typeof(StubProxy)), new Ryujinx.Common.Configuration.DirtyHacks(Array.Empty<ulong>()));
        object phys = Activator.CreateInstance(tPhys, Any, null, [ctx, gm], null);
        object buf = Activator.CreateInstance(tBuf, Any, null, [ctx, phys, addr, Size, Enum.Parse(tStage, "None"), false, Array.CreateInstance(tBuf, 0)], null);

        // GPU 写了这段（同步号 N），之后推进到 N+1：WaitForAndFlushRanges 会等 N 再回写
        tBuf.GetMethod("SignalModified", Any).Invoke(buf, [addr, Size, Enum.Parse(tStage, "StorageWrite")]);
        PropertyInfo sync = typeof(GpuContext).GetProperty("SyncNumber", Any);
        sync.SetValue(ctx, (ulong)sync.GetValue(ctx) + 1);
        object ranges = tBuf.GetField("_modifiedRanges", Any).GetValue(buf);
        MethodInfo flush = ranges.GetType().GetMethod("WaitForAndFlushRanges", Any);
        object trackingLock = typeof(MemoryTracking).GetField("TrackingLock", Any).GetValue(gm.Tracking);

        var held = new System.Threading.ManualResetEventSlim();
        var go = new System.Threading.ManualResetEventSlim();
        var g = new System.Threading.Thread(() =>
        {
            lock (trackingLock)
            {
                held.Set();
                go.Wait();
                tBuf.GetMethod("ClearModified", Any).Invoke(buf, [addr, Size]);   // 同 GPU 线程 Drain → PreciseAction → 区间表 Clear
            }
        }) { IsBackground = true, Name = "G 持跟踪锁" };
        var a = new System.Threading.Thread(() => flush.Invoke(ranges, [addr, Size])) { IsBackground = true, Name = "A 区间表回写" };
        g.Start(); held.Wait();
        a.Start();
        System.Threading.Thread.Sleep(300);   // A 已拿区间表写锁、做完回写或卡在跟踪锁上
        go.Set();
        bool done = a.Join(3000) & g.Join(3000);

        int fail = 0;
        void Check(string name, bool want, bool got) { bool ok = want == got; fail += ok ? 0 : 1; Console.WriteLine($"{name}：期望 {want} → 真结果 {got} {(ok ? "✓" : "✗")}"); }
        Check("① 持跟踪锁的线程与区间表回写 3 秒内都做完（不互等）", true, done);
        Check("② 回写落到客体内存（0x5A）", true, done && *(byte*)addr == 0x5a);
        Console.WriteLine($"flushlock：2 项，失败 {fail}");
        Console.Out.Flush();
        return fail == 0 ? 0 : 1;
    }
}
