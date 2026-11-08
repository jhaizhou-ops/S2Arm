// IRenderer：资源工厂 + 同步 + 能力表。缓冲（第 2 块）直调 C；贴图 / 程序 / 计数 / 出图各在自己的文件。
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader.Translation;
using Ryujinx.Common.Configuration;
using System;
using System.Runtime.InteropServices;
using System.Runtime.CompilerServices;

namespace NxGal
{
    static unsafe partial class N
    {
        [DllImport(Lib)] public static extern uint nxgal_buf_create(int size, int access);
        [DllImport(Lib)] public static extern uint nxgal_buf_create_host(void* ptr, int size);
        [DllImport(Lib)] public static extern uint nxgal_buf_create_sparse(NBufRange* ranges, int n);
        [DllImport(Lib)] public static extern void nxgal_buf_delete(uint buf);
        [DllImport(Lib)] public static extern int nxgal_buf_get_data(uint buf, int offset, int size, void* outp);
        [DllImport(Lib)] public static extern int nxgal_buf_peek_cpu(uint buf, int offset, int size, void* outp);
        [DllImport(Lib)] public static extern void nxgal_buf_set_data(uint buf, int offset, void* data, int size);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_buf_clear(uint buf, int offset, int size, uint value);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_buf_copy(uint src, uint dst, int srcOffset, int dstOffset, int size);
        [DllImport(Lib)] public static extern int nxgal_prepare_host_mapping(void* addr, ulong size);
        [DllImport(Lib)] public static extern uint nxgal_upload_rent(ulong len, void** cpu);
        [DllImport(Lib)] public static extern void nxgal_upload_drop(uint lease);
        [DllImport(Lib)] public static extern void nxgal_buf_set_data_lease(uint buf, int offset, uint lease, int size);
        [DllImport(Lib)] public static extern int nxgal_hostmap_probe();
    }

    public sealed unsafe class NxRenderer : IRenderer
    {
        public event EventHandler<ScreenCaptureImageInfo> ScreenCaptured;
        public bool PreferThreading => false;   // Gpu 层直接在调用线程下发；后端不另起线程
        readonly NxPipeline _pipeline;
        readonly NxWindow _window;
        internal readonly NxCounters Counters;
        Action<Action> _interrupt;
        uint _programs;
        bool _initialized, _disposed;

        public IPipeline Pipeline => _pipeline;
        public IWindow Window => _window;
        public uint ProgramCount => _programs;

        public NxRenderer()
        {
            _pipeline = new NxPipeline(this);
            _window = new NxWindow(this);
            Counters = new NxCounters(this);
        }

        public void Initialize(GraphicsDebugLevel logLevel)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_initialized) return;
            ulong v = N.nxgal_abi_hash();   // 旧库没有这个导出：DllImport 直接抛 EntryPointNotFound，同样当场失败
            if (v != Abi.Hash) throw new InvalidOperationException($"nxgal ABI 指纹不符：C 端 {v:x16}，C# 端 {Abi.Hash:x16}——核心库与 libnxgal 不是同一份 gal_abi.h 编的，两样要同批换");
            NxColdStart.Run();   // 测试契约：任何 Metal 调用前清首启缓存
            if (N.nxgal_init((int)logLevel) != 0) throw new InvalidOperationException("nxgal 初始化失败（见 stderr [gal] 行）");
            _initialized = true;
            // 零拷贝宿主映射 iOS 可行性探针（帧率能耗线 10-22，缺省关）：读数进 [gal] 行，不影响之后的游戏
            if (Environment.GetEnvironmentVariable("NXGAL_HOSTMAP_PROBE") == "1") N.nxgal_hostmap_probe();
        }

        public void BackgroundContextAction(Action action, bool alwaysBackground = false) => action();

        // ---------- 缓冲（第 2 块）----------
        static BufferHandle H(uint id) { ulong v = id; return Unsafe.As<ulong, BufferHandle>(ref v); }
        public BufferHandle CreateBuffer(int size, BufferAccess access = BufferAccess.Default) => H(N.nxgal_buf_create(size, (int)access));
        public BufferHandle CreateBuffer(nint pointer, int size) => H(N.nxgal_buf_create_host((void*)pointer, size));
        public BufferHandle CreateBufferSparse(ReadOnlySpan<BufferRange> storageBuffers)
        {
            NBufRange* r = stackalloc NBufRange[storageBuffers.Length];
            for (int i = 0; i < storageBuffers.Length; i++) r[i] = Conv.Range(storageBuffers[i]);
            return H(N.nxgal_buf_create_sparse(r, storageBuffers.Length));
        }
        public void DeleteBuffer(BufferHandle buffer) => N.nxgal_buf_delete((uint)(int)buffer);
        /// <summary>不等 GPU 的读：CPU 侧此刻内容拿得准才拷出（返回 true），否则 false、不提交不等（宽屏层几何判定用，nxgal_buf_peek_cpu）。</summary>
        public bool S2APeekBufferCpu(BufferHandle buffer, int offset, Span<byte> dst)
        {
            fixed (byte* p = dst) return N.nxgal_buf_peek_cpu((uint)(int)buffer, offset, dst.Length, p) == 1;
        }
        public PinnedSpan<byte> GetBufferData(BufferHandle buffer, int offset, int size)
        {
            if (NxGetDataStat.On) NxGetDataStat.Note(false, $"缓冲 #{(int)buffer}", size);
            PinnedSpan<byte> r = NxPinPool.Rent(size, out byte* p);   // 原生块池，零托管分配（见 NxTexture.cs NxPinPool）
            // 读不出（编号无效 = 宿主缓冲已释放、区间越界）：同 Ryujinx Vulkan BufferManager.GetData，返回空。原先照样交回 size 字节的池块，
            //   内容是块里的旧数据，Gpu 层回写进客体内存（10-24 八方2 octopath2_1024193348_1「读缓冲：编号 18 无效」）
            if (N.nxgal_buf_get_data((uint)(int)buffer, offset, size, p) != 0) { r.Dispose(); return new PinnedSpan<byte>(); }
            return r;
        }
        public void SetBufferData(BufferHandle buffer, int offset, ReadOnlySpan<byte> data)
        {
            fixed (byte* p = data) N.nxgal_buf_set_data((uint)(int)buffer, offset, p, data.Length);
        }
        public bool PrepareHostMapping(nint address, ulong size) => N.nxgal_prepare_host_mapping((void*)address, size) != 0;

        // ---------- 上传租约（帧率能耗线 10-22，方案 B；gal_tex.m）：GPU 模拟线程上直接租原生共享缓冲，写完交给 SetData / SetBufferData ----------
        // S2A_UPLOAD_LEASE=0：一律租不到，贴图整张同步 / DMA 写贴图 / 线程化缓冲写入三处都照旧路（A/B 对照用）
        private static readonly bool _uploadLease = System.Environment.GetEnvironmentVariable("S2A_UPLOAD_LEASE") != "0";
        public bool S2ATryRentUpload(int size, out S2AUploadLease lease)
        {
            if (!_uploadLease)
            {
                lease = default;
                return false;
            }
            void* p;
            uint id = N.nxgal_upload_rent((ulong)size, &p);
            lease = new S2AUploadLease((nint)p, size, id);
            return id != 0;
        }
        public void S2ADropUpload(S2AUploadLease lease) => N.nxgal_upload_drop(lease.Id);
        public void S2ASetBufferData(BufferHandle buffer, int offset, S2AUploadLease lease) => N.nxgal_buf_set_data_lease((uint)(int)buffer, offset, lease.Id, lease.Size);

        // ---------- 贴图 / 采样器 / 数组（第 3 块，NxTexture.cs）----------
        public ITexture CreateTexture(TextureCreateInfo info) => NxTexture.Create(this, info);
        public ISampler CreateSampler(SamplerCreateInfo info) => new NxSampler(info);
        public ITextureArray CreateTextureArray(int size, bool isBuffer) => new NxTextureArray(size, isBuffer, false);
        public IImageArray CreateImageArray(int size, bool isBuffer) => new NxTextureArray(size, isBuffer, true);

        // ---------- 程序（第 4 块，NxProgram.cs）----------
        // CreatedN：从 SPIR-V 建的程序数（frames.tsv xlate_n）。着色器包装好后，运行时每多一个 = Ryujinx 磁盘缓存里没有、当场翻了 Maxwell（全量预编的漏网数）；包里的走 LoadProgramBinary
        internal static long CreatedN;
        public IProgram CreateProgram(ShaderSource[] shaders, ShaderInfo info) { _programs++; System.Threading.Interlocked.Increment(ref CreatedN); return NxProgram.Create(shaders, info); }
        public IProgram LoadProgramBinary(byte[] programBinary, bool hasFragmentShader, ShaderInfo info) { _programs++; return NxProgram.Load(programBinary, hasFragmentShader, info); }

        // ---------- 同步 ----------
        public void CreateSync(ulong id, bool strict) => N.nxgal_create_sync(id, strict ? 1 : 0);
        public void WaitSync(ulong id) => N.nxgal_wait_sync(id);
        public ulong GetCurrentSync() => N.nxgal_current_sync();

        // ---------- 计数（NxCounter.cs）----------
        public ICounterEvent ReportCounter(CounterType type, EventHandler<ulong> resultHandler, float divisor, bool hostReserved) => Counters.Report(type, resultHandler, divisor, hostReserved);
        public void ResetCounter(CounterType type) => Counters.Reset(type);
        // 渲染线程只叫醒计数线程，回调在计数线程上调（NxCounter.cs 头）
        public void UpdateCounters() => Counters.Kick();
        public void PreFrame() { N.nxgal_pre_frame(); Counters.Kick(); }

        public void SetInterruptAction(Action<Action> interruptAction) => _interrupt = interruptAction;
        public void Screenshot() => _window.Screenshot(ScreenCaptured, this);

        public HardwareInfo GetHardwareInfo() => new("Apple", "Metal", "S2A NxGal", "1");

        public Capabilities GetCapabilities()
        {
            // 能力表是设备能力位的纯函数，在 caps/NxCaps.cs（离线着色器烘焙器 graphics/tools/shbake 同一份：翻译结果依赖能力表，出包与运行时必须一致）
            ulong[] dc = new ulong[4]; N.nxgal_device_caps(dc);
            return NxCaps.Build(dc);
        }

        public void RequestStop() { Counters.RequestStop(); if (_initialized) N.nxgal_request_stop(); }
        public void StopCallbacks() => Counters.StopCallbacks();
        public void Dispose()
        {
            if (_disposed) return;
            Counters.Stop();
            if (_initialized)
            {
                int result = N.nxgal_shutdown_session();
                if (result != 0) throw new InvalidOperationException($"Metal 图形会话退休失败（返回码 {result}），保留资源");
            }
            _interrupt = null; ScreenCaptured = null; _disposed = true;
        }
    }
}
