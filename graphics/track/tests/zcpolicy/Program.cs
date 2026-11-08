// 零拷贝用法规则单测（帧率能耗线 10-23，缓冲零拷贝方案 A）：只给建时带存储写用途（GPU 输出）的缓冲开零拷贝；被模拟引擎在命令流里写到的
// （常量缓冲更新 / 内联上传 / DMA 经 PhysicalMemory 写入口）当场标降级、下次取用时变回普通缓冲。零拷贝缓冲被引擎写着不降级 = 宿主 GPU 读到命令流里
// 「将来」的值（塞尔达白屏），所以「引擎写过的缓冲绝不是零拷贝」是硬规则。全用真件：Ryujinx GpuContext / PhysicalMemory / BufferCache / Buffer、产品 GuestMemory；
// 渲染器是桩（CreateBuffer 回非空句柄）。期望按规则直接定：
//   ① 建时存储写 → 零拷贝；② 建时常量（片元阶段、非存储）→ 不是；③ ① 之后 GPU 线程上经 PhysicalMemory 引擎写入口写一次 → 取用后不是（降级）；
//   ④ 反证：同 ③ 但写不在 GPU 线程（引擎写钩子不生效）→ 仍是零拷贝——即钩子缺了，「引擎写过就不是零拷贝」就不成立（判据活着）
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
    static ulong _next = 1;

    protected override object Invoke(MethodInfo m, object[] a)
    {
        Type t = m.ReturnType;
        if (t == typeof(BufferHandle)) { ulong v = _next++; return System.Runtime.CompilerServices.Unsafe.As<ulong, BufferHandle>(ref v); }
        if (t == typeof(void)) return null;
        if (t.IsInterface) return Create(t, typeof(StubProxy));
        return t.IsValueType ? Activator.CreateInstance(t) : null;
    }
}

static unsafe class P
{
    static int Main()
    {
        Environment.SetEnvironmentVariable("S2A_ZEROCOPY", "1");
        Assembly gpu = typeof(GpuContext).Assembly;
        Type tPhys = gpu.GetType("Ryujinx.Graphics.Gpu.Memory.PhysicalMemory", true);
        Type tCache = gpu.GetType("Ryujinx.Graphics.Gpu.Memory.BufferCache", true);
        Type tBuf = gpu.GetType("Ryujinx.Graphics.Gpu.Memory.Buffer", true);
        Type tStage = gpu.GetType("Ryujinx.Graphics.Gpu.Memory.BufferStage", true);
        const BindingFlags Any = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;

        ulong mem = (ulong)NativeMemory.AlignedAlloc(0x100000, 0x4000);
        new Span<byte>((void*)mem, 0x100000).Clear();
        var gm = new GuestMemory();
        var ctx = new GpuContext((IRenderer)DispatchProxy.Create(typeof(IRenderer), typeof(StubProxy)), new Ryujinx.Common.Configuration.DirtyHacks(Array.Empty<ulong>()));
        object phys = Activator.CreateInstance(tPhys, Any, null, [ctx, gm], null);
        object cache = tPhys.GetProperty("BufferCache", Any).GetValue(phys);
        MethodInfo create = tCache.GetMethod("CreateBuffer", Any, [typeof(ulong), typeof(ulong), tStage]);
        MethodInfo get = tCache.GetMethod("GetBuffer", Any, [typeof(ulong), typeof(ulong), tStage, typeof(bool)]);
        PropertyInfo zc = tBuf.GetProperty("S2AIsZeroCopy", Any);
        MethodInfo engineWrite = tPhys.GetMethod("WriteWithRedundancyCheck", Any, [typeof(ulong), typeof(ReadOnlySpan<byte>)]);
        object Stage(string s) => Enum.Parse(tStage, s);
        bool Zc(ulong a, string stage) => (bool)zc.GetValue(get.Invoke(cache, [a, 0x1000UL, Stage(stage), false]));

        int fail = 0, n = 0;
        void Check(string name, bool want, bool got) { bool ok = want == got; n++; fail += ok ? 0 : 1; Console.WriteLine($"{name}：期望 {want} → 真结果 {got} {(ok ? "✓" : "✗")}"); }
        // ReadOnlySpan 不能装箱进反射参数：引擎写经 PhysicalMemory 的普通入口委托调用
        var ew = (EngineWrite)Delegate.CreateDelegate(typeof(EngineWrite), phys, engineWrite);
        byte[] data = { 1, 2, 3, 4 };

        ulong a1 = mem, a2 = mem + 0x40000, a3 = mem + 0x80000, a4 = mem + 0xC0000;
        create.Invoke(cache, [a1, 0x1000UL, Stage("StorageWrite")]);
        Check("① 建时存储写 → 零拷贝", true, Zc(a1, "StorageWrite"));
        create.Invoke(cache, [a2, 0x1000UL, Stage("Fragment")]);
        Check("② 建时常量（片元、非存储）→ 不是零拷贝", false, Zc(a2, "Fragment"));
        create.Invoke(cache, [a3, 0x1000UL, Stage("StorageWrite")]);
        ctx.SetGpuThread();
        ew(a3 + 0x10, data);
        Check("③ GPU 线程上被引擎写过 → 取用后不是零拷贝（降级）", false, Zc(a3, "StorageWrite"));
        create.Invoke(cache, [a4, 0x1000UL, Stage("StorageWrite")]);
        var t = new System.Threading.Thread(() => ew(a4 + 0x10, data)); t.Start(); t.Join();
        Check("④ 反证：写不在 GPU 线程（钩子不生效）→ 仍是零拷贝（引擎写过却没降级，判据能抓到）", true, Zc(a4, "StorageWrite"));
        Console.WriteLine($"zcpolicy：{n} 项，失败 {fail}");
        Console.Out.Flush();
        return fail == 0 ? 0 : 1;
    }

    delegate bool EngineWrite(ulong address, ReadOnlySpan<byte> data);
}
