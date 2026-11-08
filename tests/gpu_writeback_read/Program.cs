// GPU 回写 / DMA 保留读取的读取次序单测（审计 #1534 P1-7 / P1-17）。
// 全用真件：Ryujinx GpuContext / PhysicalMemory、产品 GuestMemory（游戏地址 = 宿主地址）与它的 MemoryTracking；渲染器是桩。
// 期望（不跑被测实现就能定）：
//   ① P1-17：有安全读提供者（跟踪器的无跟踪读 MemoryTracking.S2AReadUntracked）时，不跟踪的 GetWritableRegion 只经提供者取旧字节：
//      提供者被调 1 次、托管读（GuestMemory.GetSpan 不跟踪 → 「GPU 改过没回写」查询 GpuModifiedHook）0 次；区域内容 = 内存原值。
//      旧代码先对客内存 GetSpan 取一次跨度（用不到），查询被调 1 次 → 红
//   ② P1-7：DMA 部分矩形保留读取（PhysicalMemory.S2ACopyUntrackedForDma）读目标旧字节之前，先对目标区间发读跟踪事件（同源区 tracked 读、贴图读前回写）：
//      目标区间上登记了回写动作的跟踪句柄被触发 1 次，且触发在提供者拷贝之前（次序：回写 → 拷贝）。旧代码直接拷、回写 0 次 → 红
// 用法：bash tests/gpu_writeback_read_test.sh。退出码 0 = 全过
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Memory;
using Ryujinx.Memory.Range;
using Ryujinx.Memory.Tracking;
using S2A.Services;
using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.InteropServices;

namespace S2A.Services
{
    // GuestMemory 引用的产品原生入口与报红：单测不开确定性档、不接原生层（同 tests/shader_garbage_guard）
#pragma warning disable CS0649
    static unsafe class Native
    {
        public static delegate* unmanaged<int> DetMode;
        public static delegate* unmanaged<ulong, void*, ulong, void> DetHostWrite;
        public static delegate*<ulong, MemInfo*, int> MemQuery;
        public static delegate*<ulong, ulong, int> MemMapped;
        public static FarDesc* Far = (FarDesc*)NativeMemory.AllocZeroed((nuint)sizeof(FarDesc));
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
    protected override object Invoke(MethodInfo m, object[] a)
    {
        Type t = m.ReturnType;
        if (t == typeof(void)) return null;
        if (t.IsInterface) return Create(t, typeof(StubProxy));
        return t.IsValueType ? Activator.CreateInstance(t) : null;
    }

    public static T Of<T>() => (T)(object)Create(typeof(T), typeof(StubProxy));
}

sealed class StubRenderer : IRenderer
{
    ulong _next = 1;
    BufferHandle NewBuf() { ulong v = _next++; return System.Runtime.CompilerServices.Unsafe.As<ulong, BufferHandle>(ref v); }
    public event EventHandler<ScreenCaptureImageInfo> ScreenCaptured { add { } remove { } }
    public bool PreferThreading => false;
    public IPipeline Pipeline { get; } = StubProxy.Of<IPipeline>();
    public IWindow Window { get; } = StubProxy.Of<IWindow>();
    public uint ProgramCount => 0;
    public void BackgroundContextAction(Action action, bool alwaysBackground = false) => action();
    public BufferHandle CreateBuffer(int size, BufferAccess access = BufferAccess.Default) => NewBuf();
    public BufferHandle CreateBuffer(nint pointer, int size) => NewBuf();
    public BufferHandle CreateBufferSparse(ReadOnlySpan<BufferRange> storageBuffers) => NewBuf();
    public IImageArray CreateImageArray(int size, bool isBuffer) => StubProxy.Of<IImageArray>();
    public IProgram CreateProgram(ShaderSource[] shaders, ShaderInfo info) => StubProxy.Of<IProgram>();
    public ISampler CreateSampler(SamplerCreateInfo info) => StubProxy.Of<ISampler>();
    public ITexture CreateTexture(TextureCreateInfo info) => StubProxy.Of<ITexture>();
    public ITextureArray CreateTextureArray(int size, bool isBuffer) => StubProxy.Of<ITextureArray>();
    public bool PrepareHostMapping(nint address, ulong size) => false;
    public void CreateSync(ulong id, bool strict) { }
    public void DeleteBuffer(BufferHandle buffer) { }
    public PinnedSpan<byte> GetBufferData(BufferHandle buffer, int offset, int size) => default;
    public Capabilities GetCapabilities() => default;
    public ulong GetCurrentSync() => 0;
    public HardwareInfo GetHardwareInfo() => default;
    public IProgram LoadProgramBinary(byte[] programBinary, bool hasFragmentShader, ShaderInfo info) => StubProxy.Of<IProgram>();
    public void SetBufferData(BufferHandle buffer, int offset, ReadOnlySpan<byte> data) { }
    public void UpdateCounters() { }
    public void PreFrame() { }
    public ICounterEvent ReportCounter(CounterType type, EventHandler<ulong> resultHandler, float divisor, bool hostReserved) => StubProxy.Of<ICounterEvent>();
    public void ResetCounter(CounterType type) { }
    public void RunLoop(System.Threading.ThreadStart gpuLoop) => gpuLoop();
    public void WaitSync(ulong id) { }
    public void Initialize(GraphicsDebugLevel logLevel) { }
    public void SetInterruptAction(Action<Action> interruptAction) { }
    public void Screenshot() { }
    public void Dispose() { }
}

static unsafe class P
{
    const ulong MemSize = 0x100000;
    static int _gpuModifiedQueries, _untrackedReads;
    static readonly List<string> _order = new();

    static bool FakeGpuModified(ulong va, ulong size) { _gpuModifiedQueries++; return false; }

    static void FakeReadUntracked(ulong va, byte* dst, int n)
    {
        _untrackedReads++;
        _order.Add("拷贝");
        Buffer.MemoryCopy((void*)va, dst, n, n);
    }

    static int Main()
    {
        Assembly gpu = typeof(GpuContext).Assembly;
        Type tPhys = gpu.GetType("Ryujinx.Graphics.Gpu.Memory.PhysicalMemory", true);
        const BindingFlags Any = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;

        ulong mem = (ulong)NativeMemory.AlignedAlloc((nuint)MemSize, 0x10000);
        for (int i = 0; i < (int)MemSize; i++) ((byte*)mem)[i] = (byte)(i * 7 + 3);

        var gm = new GuestMemory();
        var ctx = new GpuContext(new StubRenderer(), new DirtyHacks(Array.Empty<ulong>()));
        object phys = Activator.CreateInstance(tPhys, Any, null, [ctx, gm], null);

        int fail = 0, n = 0;
        void Check(string name, string want, string got) { bool ok = want == got; n++; fail += ok ? 0 : 1; Console.WriteLine($"{name}：期望 {want} → 真结果 {got} {(ok ? "✓" : "✗")}"); }

        GuestMemory.GpuModifiedHook = &FakeGpuModified;
        MemoryTracking.S2AReadUntracked = &FakeReadUntracked;

        // —— ① P1-17：不跟踪回写区域，有提供者时只经提供者取旧字节 ——
        {
            ulong addr = mem + 0x20000;
            const int Size = 0x300;
            MethodInfo gwr = tPhys.GetMethod("GetWritableRegion", Any, [typeof(ulong), typeof(int), typeof(bool)]);
            _gpuModifiedQueries = 0; _untrackedReads = 0;
            WritableRegion region = (WritableRegion)gwr.Invoke(phys, [addr, Size, false]);
            int q = _gpuModifiedQueries, r = _untrackedReads;
            bool same = region.Memory.Span.SequenceEqual(new ReadOnlySpan<byte>((void*)addr, Size));
            Check("① P1-17 不跟踪回写区域：提供者读次数 / 托管读（GPU 改过查询）次数 / 内容 = 内存原值", "1 / 0 / True", $"{r} / {q} / {same}");
            region.Dispose();
        }

        // —— ② P1-7：DMA 保留读取先对目标发读跟踪（回写），再拷 ——
        {
            ulong dst = mem + 0x40000;
            const int Size = 0x2000;
            ctx.SetGpuThread();
            RegionHandle h = gm.BeginTracking(dst, 0x4000, 0);
            int flushed = 0;
            h.RegisterAction((a, s) => { flushed++; _order.Add("回写"); });
            _order.Clear(); _untrackedReads = 0;
            MethodInfo copy = tPhys.GetMethod("S2ACopyUntrackedForDma", Any);
            byte[] target = new byte[Size];
            string err = "不抛";
            try { copy.Invoke(phys, [new MultiRange(dst, Size), new Memory<byte>(target)]); }
            catch (TargetInvocationException e) { err = $"抛 {e.InnerException.GetType().Name}: {e.InnerException.Message}"; }
            bool same = target.AsSpan().SequenceEqual(new ReadOnlySpan<byte>((void*)dst, Size));
            Check("② P1-7 DMA 保留读取：不抛 / 目标区回写动作触发次数 / 次序 / 内容 = 内存原值", "不抛 / 1 / 回写,拷贝 / True",
                $"{err} / {flushed} / {string.Join(",", _order)} / {same}");
            h.Dispose();
        }

        GuestMemory.GpuModifiedHook = null;
        MemoryTracking.S2AReadUntracked = null;
        Console.WriteLine($"gpu_writeback_read：{n} 项，失败 {fail}");
        Console.Out.Flush();
        return fail == 0 ? 0 : 1;
    }
}
