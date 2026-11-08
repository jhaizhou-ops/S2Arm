// 图形着色器垃圾代码防线单测（双人成行 t010092a0172e4000 10-29 mini 局 r1：GPU 取图形着色器时那段客体内存不是代码，
// 翻译器 SPIR-V 生成抛 ArgumentException「Invalid shader stage "15"」，GPU 模拟线程未捕获 → FailFast）。
// 全用真件：Ryujinx GpuContext / PhysicalMemory / MemoryManager / GpuChannel / ThreedClass 的 StateUpdater / ShaderCache、产品 GuestMemory；
// 渲染器是桩，只报 TargetApi.Vulkan（与产品同走 SPIR-V 生成）。走生产路径 StateUpdater.UpdateShaderState → ShaderCache.GetGraphicsShader。
// 构造：顶点着色器（阶段 1）所在 64 KB 整段填 0xFF——头 0x50 字节第一字 0xFFFFFFFF，阶段号 = (字0 >> 10) & 0xF = 15（非法）。
// 期望（不跑被测实现就能定）：
//   ① UpdateShaderState 不抛（修前抛 ArgumentException）；S2AShaderFault 为真（本组绘制跳过）
//   ② 同一组地址连取两次，红行恰 1 行；红行写明「翻译失败」与原异常类型 / 消息
//   ③ 红行带原生层要的现场字段：阶段 GPU 地址与读取长度、物理段（物理地址 = 映射时给的宿主地址）、宿主地址、写跟踪（查询未提供时写明）
//   ④ 写跟踪查询提供时（换一组地址，桩查询对该组首个宿主页回 state 1 / lastp 3 / act 0x2 / want 0xF / READFLUSH 1 / dirty 0，其余回 UINT64_MAX）：
//      红行按字段拆开打这一页；不在跟踪里的页写「未跟踪」
// 用法：bash tests/shader_garbage_guard_test.sh。退出码 0 = 全过
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using S2A.Services;
using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

namespace S2A.Services
{
    // GuestMemory 引用的产品原生入口与报红：单测不开确定性档、不接原生层（同 graphics/track/tests/vrcsplit）
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

// 渲染器桩（同 vrcsplit）：GPU 侧不落地
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
    static ulong _trackedPage;   // 桩写跟踪查询：只有这一页「在跟踪里」

    static ulong FakePageInfo(ulong addr) => addr == _trackedPage ? 0x0000_0001_0F02_0301UL : ulong.MaxValue;

    static int Main()
    {
        Assembly gpu = typeof(GpuContext).Assembly;
        Type tPhys = gpu.GetType("Ryujinx.Graphics.Gpu.Memory.PhysicalMemory", true);
        Type tMm = gpu.GetType("Ryujinx.Graphics.Gpu.Memory.MemoryManager", true);
        Type tKind = gpu.GetType("Ryujinx.Graphics.Gpu.Memory.PteKind", true);
        Type tTs = gpu.GetType("Ryujinx.Graphics.Gpu.Engine.Threed.ThreedClassState", true);
        const BindingFlags Any = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;

        ulong mem = (ulong)NativeMemory.AlignedAlloc((nuint)MemSize, 0x10000);
        new Span<byte>((void*)mem, (int)MemSize).Fill(0x11);

        var gm = new GuestMemory();
        var ctx = new GpuContext(new StubRenderer(), new DirtyHacks(Array.Empty<ulong>()));
        // 后端报 Vulkan：翻译走 SPIR-V 生成（崩溃现场的栈：CodeGen.Spirv.EnumConversion.Convert）
        FieldInfo capsF = typeof(GpuContext).GetField("Capabilities", Any);
        object caps = capsF.GetValue(ctx);
        typeof(Capabilities).GetField("Api").SetValue(caps, TargetApi.Vulkan);
        capsF.SetValue(ctx, caps);

        object phys = Activator.CreateInstance(tPhys, Any, null, [ctx, gm], null);
        object mm = Activator.CreateInstance(tMm, Any, null, [phys, MemSize], null);
        void Map(ulong pa, ulong va, ulong size) => tMm.GetMethod("Map", Any).Invoke(mm, [pa, va, size, Enum.ToObject(tKind, 0)]);

        // 两组着色器各占 64 KB，整段填 0xFF（头部阶段号非法 + 代码区不是代码）
        ulong physA = mem + 0x10000, physB = mem + 0x40000;
        const ulong VaA = 0x10000000, VaB = 0x20000000;
        Map(physA, VaA, 0x10000);
        Map(physB, VaB, 0x10000);
        // 头 0x50 字节 + 代码前 0x100 字节填 0xFF；其后整段填 EXIT（0xE30000000007000F），解码必在这里收尾（全 0xFF 会一路解到映射尽头、走取码越界那条）
        foreach (ulong p in new[] { physA, physB })
        {
            new Span<ulong>((void*)p, 0x10000 / 8).Fill(0xE30000000007000FUL);
            new Span<byte>((void*)p, 0x150).Fill(0xFF);
        }

        GpuChannel chan = ctx.CreateChannel();
        typeof(GpuChannel).GetMethod("BindMemory", Any).Invoke(chan, [mm]);
        object proc = typeof(GpuChannel).GetField("_processor", Any).GetValue(chan);
        object threed = proc.GetType().GetProperty("ThreedClass", Any).GetValue(proc);
        object su = threed.GetType().GetField("_stateUpdater", Any).GetValue(threed);
        MethodInfo update = su.GetType().GetMethod("UpdateShaderState", Any);
        FieldInfo fault = su.GetType().GetField("S2AShaderFault", Any);

        int baseOff = (int)Marshal.OffsetOf(tTs, "ShaderBaseAddress");   // GpuVa { High, Low }
        int vsOff = (int)Marshal.OffsetOf(tTs, "ShaderState") + 1 * 0x40;   // ShaderState[1]（顶点 B，恒开）：Control, Offset, …
        void SetBase(ulong va)
        {
            chan.Write(ClassId.Threed, baseOff, (uint)(va >> 32));
            chan.Write(ClassId.Threed, baseOff + 4, (uint)va);
        }
        chan.Write(ClassId.Threed, vsOff + 0, 1);
        chan.Write(ClassId.Threed, vsOff + 4, 0);

        int fail = 0, n = 0;
        void Check(string name, string want, string got) { bool ok = want == got; n++; fail += ok ? 0 : 1; Console.WriteLine($"{name}：期望 {want} → 真结果 {got} {(ok ? "✓" : "✗")}"); }
        TextWriter realErr = Console.Error;
        StringWriter err = new();

        // 跑一次 UpdateShaderState：返回「不抛」或抛出的异常类型 + 消息
        string Run()
        {
            Console.SetError(err);
            try { update.Invoke(su, null); return "不抛"; }
            catch (TargetInvocationException e) { return $"抛 {e.InnerException.GetType().FullName}: {e.InnerException.Message}"; }
            finally { Console.SetError(realErr); }
        }
        string[] RedLines(string text)
        {
            System.Collections.Generic.List<string> v = new();
            foreach (string l in text.Split('\n')) if (l.Contains("【红】") && l.Contains("着色器")) v.Add(l);
            return v.ToArray();
        }
        string Has(string line, string what) => line.Contains(what) ? "有" : $"没有（{what}）";

        // —— 组 A：写跟踪查询未提供 ——
        SetBase(VaA);
        string r1 = Run();
        bool f1 = (bool)fault.GetValue(su);
        string r2 = Run();
        Check("① 组 A 取两次：都不抛、本组绘制跳过（S2AShaderFault）", "不抛 / 不抛 / True", $"{r1} / {r2} / {f1}");
        string[] redA = RedLines(err.ToString());
        Check("② 组 A 同一组地址红行条数", "1", redA.Length.ToString());
        string a = redA.Length > 0 ? redA[0] : "";
        Check("② 红行写明分类与原异常", "有 / 有 / 有", $"{Has(a, "翻译失败")} / {Has(a, "System.ArgumentException")} / {Has(a, "Invalid shader stage \"15\"")}");
        string lenNonZero = a.Contains("读取长度 0x0；") ? "没有（长度为 0）" : "有";
        Check("③ 红行现场：阶段 GPU 地址 + 读取长度（非 0）", "有 / 有", $"{Has(a, $"阶段 1 GPU 地址 0x{VaA:X} 读取长度 0x")} / {lenNonZero}");
        Check("③ 红行现场：物理段 / 宿主地址（物理 = 映射时的宿主地址）", "有 / 有", $"{Has(a, $"物理段 0x{physA:X} 长 0x")} / {Has(a, $"宿主地址 0x{physA:X}")}");
        Check("③ 红行现场：写跟踪查询未提供时写明", "有", Has(a, "写跟踪查询未提供"));
        Check("③ 原有现场照留：程序区基址 / 头 0x50 字节 / 全零字比例", "有 / 有 / 有", $"{Has(a, $"程序区基址 0x{VaA:X}")} / {Has(a, "阶段 1 头 FFFF")} / {Has(a, "代码前 4 KB 全零字 0/512")}");

        // —— 组 B：写跟踪查询提供（桩） ——
        string b = "";
        FieldInfo hook = typeof(Ryujinx.Memory.Tracking.MemoryTracking).GetField("S2ATrackPageInfo", BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic);
        if (hook == null)
        {
            Check("④ Ryujinx.Memory 有写跟踪查询钩子 MemoryTracking.S2ATrackPageInfo", "有", "没有");
        }
        else
        {
            _trackedPage = physB & ~(ulong)(Environment.SystemPageSize - 1);
            hook.SetValue(null, (nint)(delegate*<ulong, ulong>)&FakePageInfo);
            err.GetStringBuilder().Clear();
            SetBase(VaB);
            string r3 = Run();
            hook.SetValue(null, (nint)0);
            string[] redB = RedLines(err.ToString());
            b = redB.Length > 0 ? redB[0] : "";
            Check("④ 组 B：不抛、红行 1 条", "不抛 / 1", $"{r3} / {redB.Length}");
            Check("④ 在跟踪里的页按字段拆开打", "有", Has(b, $"宿主页 0x{_trackedPage:X}：state 1 lastp 0x3 act 0x2 want 0xF READFLUSH 1 dirty 0x0"));
        }

        // —— ⑤ 审计 #1534 P1-10：一次取码 / 翻译失败只跳过这一笔，着色器组脏位留下、下一笔绘制重取 ——
        // 走绘制用的整表更新 StateUpdater.Update()（跟踪器在回调返回后清掉这一轮的脏位）。期望按「失败这笔跳过、脏位留下」写：
        //   连调两次 Update()：都不抛、S2AShaderFault 为真、调完着色器组（ShaderStateIndex）仍脏。旧代码第一次调完脏位就被清掉 → 着色器寄存器不再变就永不重取
        {
            object tracker = su.GetType().GetField("_updateTracker", Any).GetValue(su);
            MethodInfo isDirty = tracker.GetType().GetMethod("IsDirty", Any);
            MethodInfo full = su.GetType().GetMethod("Update", Any, Type.EmptyTypes);
            int shaderIdx = (int)su.GetType().GetField("ShaderStateIndex").GetValue(null);
            string Upd()
            {
                Console.SetError(err);
                try { full.Invoke(su, null); return "不抛"; }
                catch (TargetInvocationException e) { return $"抛 {e.InnerException.GetType().Name}: {e.InnerException.Message}"; }
                finally { Console.SetError(realErr); }
            }
            // 热身一次、结果不计：首次整表更新走到 CommitBindings 时，桩管线（DispatchProxy）收 ReadOnlySpan 参数的 SetUniformBuffers 会抛
            //   InvalidProgramException——那是桩的限制，在被测的着色器组脏位处理之后；热身后绑定已提交，后面两次不再碰它
            Upd();
            SetBase(VaA);
            su.GetType().GetMethod("ForceShaderUpdate", Any).Invoke(su, null);
            string u1 = Upd();
            string s1 = $"{u1} / {(bool)fault.GetValue(su)} / {(bool)isDirty.Invoke(tracker, [shaderIdx])}";
            string u2 = Upd();
            string s2 = $"{u2} / {(bool)fault.GetValue(su)} / {(bool)isDirty.Invoke(tracker, [shaderIdx])}";
            Check("⑤ P1-10 失败后整表更新：第 1 次 不抛 / 跳过 / 着色器组仍脏", "不抛 / True / True", s1);
            Check("⑤ P1-10 失败后整表更新：第 2 次（重取仍失败）不抛 / 跳过 / 着色器组仍脏", "不抛 / True / True", s2);
        }

        Console.WriteLine($"红行原文：组 A {a}\n组 B {b}");
        Console.WriteLine($"shader_garbage_guard：{n} 项，失败 {fail}");
        Console.Out.Flush();
        return fail == 0 ? 0 : 1;
    }
}
