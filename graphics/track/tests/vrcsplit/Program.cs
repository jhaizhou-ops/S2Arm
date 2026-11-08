// 多段映射不压段单测（原生层 10-28 银河2 崩溃根修，补丁 0297）：GPU 虚拟区间跨两个映射、第二段物理起点不是 64 KB 对齐时，
// 上游 VirtualRangeCache 把它压成「第一段起点 + 总长」一段，缓冲间拷贝 / 清缓冲按单段线性写，跨映射那截写进第一段之后的内存
// ——我们的物理地址就是游戏真实内存，那里是别的游戏对象（银河2 subsdk4+0x16d8af8 崩）。全用真件：Ryujinx GpuContext / PhysicalMemory /
// MemoryManager / VirtualRangeCache / BufferCache、产品 GuestMemory；渲染器是桩（GPU 侧拷贝不落地，客体内存写走 WriteTrackedResource 真写）。
// 布局照银河2 崩溃现场：GPU 0x10a590000 起 64 KB → CPU A（A = 基址 + 0x7000，不 64 KB 对齐）；GPU 0x10a5a0000 起 128 KB → CPU B（B = 基址 + 0x96000）。
// 期望按布局直接算：0x10a59fc30 起 0x610 字节 = A+0xfc30 起 0x3d0 + B 起 0x240；A+0x10000 起是第一段之后的内存，一个字节都不许动。
//   ① 区间翻译给出真实两段；② 缓冲间拷贝两段各落对位置、第一段之后不动、全内存只变 0x610 字节；③ 清缓冲同理；
//   ④ 绑定取区间：拷贝式多段缓冲按真实分段对上请求（偏移 0、长 0x610）；⑤ 后端支持稀疏时不对齐多段也不建稀疏缓冲（稀疏只能映射 64 KB 对齐段）
// 用法：bash build_run.sh。退出码 0 = 全过
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Memory.Range;
using S2A.Services;
using System;
using System.Reflection;
using System.Runtime.InteropServices;

namespace S2A.Services
{
    // GuestMemory 引用的产品原生入口与报红：单测不开确定性档、不接原生层（同 zcpolicy）
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

// 渲染器桩：显式类（SetBufferData 等带 ReadOnlySpan 参数，DispatchProxy 装不进 object[]）；管线 / 窗口等没有 Span 参数的仍走代理。GPU 侧拷贝不落地
sealed class StubRenderer : IRenderer
{
    ulong _next = 1;
    public int SparseCreates;
    BufferHandle NewBuf() { ulong v = _next++; return System.Runtime.CompilerServices.Unsafe.As<ulong, BufferHandle>(ref v); }
    public event EventHandler<ScreenCaptureImageInfo> ScreenCaptured { add { } remove { } }
    public bool PreferThreading => false;
    public IPipeline Pipeline { get; } = StubProxy.Of<IPipeline>();
    public IWindow Window { get; } = StubProxy.Of<IWindow>();
    public uint ProgramCount => 0;
    public void BackgroundContextAction(Action action, bool alwaysBackground = false) => action();
    public BufferHandle CreateBuffer(int size, BufferAccess access = BufferAccess.Default) => NewBuf();
    public BufferHandle CreateBuffer(nint pointer, int size) => NewBuf();
    public BufferHandle CreateBufferSparse(ReadOnlySpan<BufferRange> storageBuffers) { SparseCreates++; return NewBuf(); }
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
    const ulong MemSize = 0x200000;

    static int Main()
    {
        Assembly gpu = typeof(GpuContext).Assembly;
        Type tPhys = gpu.GetType("Ryujinx.Graphics.Gpu.Memory.PhysicalMemory", true);
        Type tMm = gpu.GetType("Ryujinx.Graphics.Gpu.Memory.MemoryManager", true);
        Type tVrc = gpu.GetType("Ryujinx.Graphics.Gpu.Memory.VirtualRangeCache", true);
        Type tCache = gpu.GetType("Ryujinx.Graphics.Gpu.Memory.BufferCache", true);
        Type tStage = gpu.GetType("Ryujinx.Graphics.Gpu.Memory.BufferStage", true);
        Type tKind = gpu.GetType("Ryujinx.Graphics.Gpu.Memory.PteKind", true);
        const BindingFlags Any = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;

        ulong mem = (ulong)NativeMemory.AlignedAlloc((nuint)MemSize, 0x10000);
        byte* all = (byte*)mem;   // 指针而非 Span：局部函数里要用
        new Span<byte>(all, (int)MemSize).Fill(0x11);

        var gm = new GuestMemory();
        var rend = new StubRenderer();
        var ctx = new GpuContext(rend, new DirtyHacks(Array.Empty<ulong>()));
        object phys = Activator.CreateInstance(tPhys, Any, null, [ctx, gm], null);
        object cache = tPhys.GetProperty("BufferCache", Any).GetValue(phys);
        object mm = Activator.CreateInstance(tMm, Any, null, [phys, MemSize], null);
        object vrc = tMm.GetProperty("VirtualRangeCache", Any).GetValue(mm);
        object pitch = Enum.ToObject(tKind, 0);
        object copyStage = Enum.Parse(tStage, "Copy");
        void Map(ulong pa, ulong va, ulong size) => tMm.GetMethod("Map", Any).Invoke(mm, [pa, va, size, pitch]);
        MultiRange Translate(ulong va, ulong size)
        {
            object[] a = [va, size, null];
            tVrc.GetMethod("TryGetOrAddRange", Any, [typeof(ulong), typeof(ulong), typeof(MultiRange).MakeByRefType()]).Invoke(vrc, a);
            return (MultiRange)a[2];
        }

        int fail = 0, n = 0;
        void Check(string name, string want, string got) { bool ok = want == got; n++; fail += ok ? 0 : 1; Console.WriteLine($"{name}：期望 {want} → 真结果 {got} {(ok ? "✓" : "✗")}"); }
        string Segs(MultiRange r)
        {
            string s = "";
            for (int i = 0; i < r.Count; i++) { MemoryRange m = r.GetSubRange(i); s += $"{(i > 0 ? " + " : "")}基址+0x{m.Address - mem:x} 长 0x{m.Size:x}"; }
            return s;
        }
        // 逐字节对比整块内存：返回「变了的字节数 / 指定区间内与期望不符的字节数」
        byte[] snap = Snap();
        byte[] Snap() => new Span<byte>(all, (int)MemSize).ToArray();
        int Changed() { int c = 0; for (int i = 0; i < (int)MemSize; i++) c += all[i] != snap[i] ? 1 : 0; return c; }
        int Mismatch(ulong off, int len, Func<int, byte> want) { int c = 0; for (int i = 0; i < len; i++) c += all[(int)off + i] != want(i) ? 1 : 0; return c; }

        static byte Pat(int i) => (byte)(0x80 | ((i * 7 + 3) & 0x7f));   // 源花纹：最高位恒 1，不会与底色 0x11 撞（撞了「变了几字节」就少数）
        // 拷贝：A / B 照银河2 现场；源 S 是单段连续映射
        ulong A = mem + 0x07000, B = mem + 0x96000, S = mem + 0x140000;
        Map(A, 0x10a590000, 0x10000);
        Map(B, 0x10a5a0000, 0x20000);
        Map(S, 0x20000000, 0x10000);
        for (int i = 0; i < 0x610; i++) all[(int)(S - mem) + i] = Pat(i);
        snap = Snap();

        MultiRange r1 = Translate(0x10a59fc30, 0x610);
        Check("① 跨两映射的区间翻译成真实两段", "基址+0x16c30 长 0x3d0 + 基址+0x96000 长 0x240", Segs(r1));

        tCache.GetMethod("CopyBuffer", Any).Invoke(cache, [mm, 0x20000000UL, 0x10a59fc30UL, 0x610UL]);
        Check("② 拷贝：第一段 A+0xfc30 起 0x3d0 字节 = 源前 0x3d0", "0 字节不符", $"{Mismatch(A - mem + 0xfc30, 0x3d0, i => Pat(i))} 字节不符");
        Check("② 拷贝：第二段 B 起 0x240 字节 = 源后 0x240", "0 字节不符", $"{Mismatch(B - mem, 0x240, i => Pat(i + 0x3d0))} 字节不符");
        Check("② 拷贝：第一段之后 A+0x10000 起 0x240 字节不动（压段时这里被盖）", "0 字节不符", $"{Mismatch(A - mem + 0x10000, 0x240, _ => 0x11)} 字节不符");
        Check("② 拷贝：整块内存只变拷贝目标那 0x610 字节", "0x610", $"0x{Changed():x}");

        // 清缓冲：另一对映射，同样第二段不 64 KB 对齐
        ulong C = mem + 0xc7000, D = mem + 0x106000;
        Map(C, 0x30000000, 0x10000);
        Map(D, 0x30010000, 0x10000);
        snap = Snap();
        tCache.GetMethod("ClearBuffer", Any).Invoke(cache, [mm, 0x3000ff00UL, 0x200UL, 0xcdcdcdcdu]);
        Check("③ 清缓冲：C+0xff00 起 0x100 与 D 起 0x100 都是 0xcd", "0 字节不符", $"{Mismatch(C - mem + 0xff00, 0x100, _ => 0xcd) + Mismatch(D - mem, 0x100, _ => 0xcd)} 字节不符");
        Check("③ 清缓冲：第一段之后 C+0x10000 起不动、整块只变 0x200 字节", "不动 / 0x200", $"{(Mismatch(C - mem + 0x10000, 0x100, _ => 0x11) == 0 ? "不动" : "被盖")} / 0x{Changed():x}");

        // 绑定：拷贝式多段缓冲（桩渲染器不报稀疏能力）要能按真实分段对上请求区间
        MethodInfo bind = tCache.GetMethod("TranslateAndCreateMultiBuffers", Any);
        MethodInfo getRange = tCache.GetMethod("GetBufferRange", Any, [typeof(MultiRange), tStage, typeof(bool)]);
        object storage = Enum.Parse(tStage, "StorageWrite");
        MultiRange r4 = (MultiRange)bind.Invoke(cache, [mm, 0x10a59fc30UL, 0x610UL, storage]);
        BufferRange br = (BufferRange)getRange.Invoke(cache, [r4, storage, true]);
        Check("④ 绑定：两段、多段缓冲内偏移 0、长 0x610", "2 段 / 偏移 0 / 长 0x610", $"{r4.Count} 段 / 偏移 {br.Offset} / 长 0x{br.Size:x}");

        // 后端报稀疏能力：不对齐多段仍走拷贝式（稀疏只能映射 64 KB 对齐段，强建会错位）
        FieldInfo capsF = typeof(GpuContext).GetField("Capabilities", Any);
        object caps = capsF.GetValue(ctx);
        typeof(Capabilities).GetField("SupportsSparseBuffer").SetValue(caps, true);
        capsF.SetValue(ctx, caps);
        Map(mem + 0x187000, 0x40000000, 0x10000);
        Map(mem + 0x1c6000, 0x40010000, 0x10000);
        int before = rend.SparseCreates;
        MultiRange r5 = (MultiRange)bind.Invoke(cache, [mm, 0x4000fc00UL, 0x800UL, storage]);
        BufferRange br5 = (BufferRange)getRange.Invoke(cache, [r5, storage, true]);
        Check("⑤ 稀疏后端 + 不对齐两段：不建稀疏缓冲、偏移 0、长 0x800", "0 次 / 偏移 0 / 长 0x800", $"{rend.SparseCreates - before} 次 / 偏移 {br5.Offset} / 长 0x{br5.Size:x}");

        // 常量缓冲内联更新（ConstantBufferUpdater 攒批写回）：整批 0x400 字节跨 4 KB 页进另一个映射。
        // GPU 0x50000000 → 基址+0x1d0000、0x50001000 → 基址+0x1e8000（各 4 KB）；从 0x50000e00 起写 256 个 int → 前 0x200 落第一页尾、后 0x200 落第二个映射头
        Map(mem + 0x1d0000, 0x50000000, 0x1000);
        Map(mem + 0x1e8000, 0x50001000, 0x1000);
        object chan = typeof(GpuContext).GetMethod("CreateChannel").Invoke(ctx, null);
        chan.GetType().GetMethod("BindMemory", Any).Invoke(chan, [mm]);
        Type tTs = gpu.GetType("Ryujinx.Graphics.Gpu.Engine.Threed.ThreedClassState", true);
        Type tDs = gpu.GetType("Ryujinx.Graphics.Gpu.Engine.DeviceStateWithShadow`1", true).MakeGenericType(tTs);
        object ds = Activator.CreateInstance(tDs, Any, null, [null, null], null);
        MethodInfo reg = tDs.GetMethod("Write", Any, [typeof(int), typeof(int)]);
        int ub = (int)Marshal.OffsetOf(tTs, "UniformBufferState");   // Size, Address.High, Address.Low, Offset
        reg.Invoke(ds, [ub + 0, 0x2000]);
        reg.Invoke(ds, [ub + 4, 0]);
        reg.Invoke(ds, [ub + 8, 0x50000000]);
        reg.Invoke(ds, [ub + 12, 0xe00]);
        Type tCbu = gpu.GetType("Ryujinx.Graphics.Gpu.Engine.Threed.ConstantBufferUpdater", true);
        object cbu = Activator.CreateInstance(tCbu, Any, null, [chan, ds], null);
        MethodInfo upd = tCbu.GetMethod("Update", Any, [typeof(int)]);
        static int Word(int i) => unchecked((int)(0x80808080u | (uint)(i & 0x7f)));   // 每个字节最高位恒 1，不与底色 0x11 撞
        snap = Snap();
        for (int i = 0; i < 256; i++) upd.Invoke(cbu, [Word(i)]);
        tCbu.GetMethod("FlushUboDirty", Any).Invoke(cbu, null);
        int WordMismatch(ulong off, int first, int count) { int c = 0; for (int i = 0; i < count; i++) c += *(int*)(all + off + (ulong)i * 4) != Word(first + i) ? 1 : 0; return c; }
        Check("⑥ 常量缓冲更新：第一页尾 0x200 字节 = 前 128 个字、第二个映射头 0x200 字节 = 后 128 个字", "0 / 0 个字不符", $"{WordMismatch(0x1d0e00, 0, 128)} / {WordMismatch(0x1e8000, 128, 128)} 个字不符");
        Check("⑥ 常量缓冲更新：第一页之后 基址+0x1d1000 起不动、整块只变 0x400 字节", "不动 / 0x400", $"{(Mismatch(0x1d1000, 0x200, _ => 0x11) == 0 ? "不动" : "被盖")} / 0x{Changed():x}");

        // ⑦ 常量缓冲更新单段快路径用刷新时的翻译（审计 #876 F-ubo-count1-stale）：开批（第一条 Update）之后、刷新之前，这块 GPU 地址改映射到另一页 / 被卸掉。
        //   期望按「写进刷新这一刻这块 GPU 地址指向的页」定：改映射 → 16 个字落新页、旧页不动；卸掉 → 一个字节都不写（不写进开批时那一页）
        void Batch(ulong va, int seed) { reg.Invoke(ds, [ub + 8, (int)va]); reg.Invoke(ds, [ub + 12, 0x100]); for (int i = 0; i < 16; i++) upd.Invoke(cbu, [Word(seed + i)]); }
        int WordsAt(ulong off, int first) { int c = 0; for (int i = 0; i < 16; i++) c += *(int*)(all + off + (ulong)i * 4) == Word(first + i) ? 1 : 0; return c; }
        Map(mem + 0x1f0000, 0x60000000, 0x1000);
        snap = Snap();
        Batch(0x60000000, 0);
        Map(mem + 0x1f8000, 0x60000000, 0x1000);
        tCbu.GetMethod("FlushUboDirty", Any).Invoke(cbu, null);
        Check("⑦ 开批后改映射：新页 +0x100 起写对的字 / 旧页 +0x100 起被写的字 / 整块变了字节数", "16 / 0 / 0x40", $"{WordsAt(0x1f8100, 0)} / {WordsAt(0x1f0100, 0)} / 0x{Changed():x}");
        Map(mem + 0x1f4000, 0x61000000, 0x1000);
        snap = Snap();
        Batch(0x61000000, 32);
        tMm.GetMethod("Unmap", Any).Invoke(mm, [0x61000000UL, 0x1000UL]);
        tCbu.GetMethod("FlushUboDirty", Any).Invoke(cbu, null);
        Check("⑦ 开批后卸映射：旧页 +0x100 起被写的字 / 整块变了字节数", "0 / 0x0", $"{WordsAt(0x1f4100, 32)} / 0x{Changed():x}");

        Console.WriteLine($"vrcsplit：{n} 项，失败 {fail}");
        Console.Out.Flush();
        return fail == 0 ? 0 : 1;
    }
}
