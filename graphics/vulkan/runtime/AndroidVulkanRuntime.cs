// GPU command order derives from graphics/loop/RenderLoop.cs and OhosGfx.cs at
// 73b0cee62ea0ea8da91888c3a51d0cfd76742dc7. Platform scheduling/Metal work stays there.
using NxGal;
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.GAL.Multithreading;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Engine.GPFifo;
using Ryujinx.Graphics.Gpu.Shader.DiskCache;
using Ryujinx.Graphics.Shader;
using Ryujinx.Memory.Tracking;
using S2Arm.Backends.Vulkan;
using S2Arm.Backends.Vulkan.ProgramCache;
using S2Arm.Backends.Vulkan.Wsi;
using S2A.Services;
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Runtime.ExceptionServices;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Switch = Ryujinx.HLE.Switch;

namespace S2Arm.Backends.Vulkan.Runtime;

// One game session. Start returns only after the real GPU thread, tracking and shader-cache
// consumer are ready. The caller must terminate the process if Stop cannot prove quiescence.
public sealed unsafe class AndroidVulkanRuntime
{
    private readonly AndroidVulkanSurface _surface;
    private readonly Action<Exception> _fatal;
    private readonly string _gameDataDirectory;
    // 游戏状态目录（存档同级，跨局保留）：拆线程 auto 的上局记录放这里；null = 宿主没给（auto 不可用，选 auto 直接报错）。
    private readonly string _stateDirectory;
    // 拆线程 GAL 卡住判据的生命周期钟：外壳 onResume / onPause 写进租约生产方的前后台与转换次数，任意线程可读，
    // 不靠渲染线程自己 Poll（渲染线程卡在长命令里时它不会 Poll）。≥ 0 = 前台（值 = 转换次数，变了 = 中间切过后台），< 0 = 后台 / 没有租约。
    private readonly Func<long> _lifecycle;
    [DllImport("s2arm_android")] private static extern int s2a_android_host_lifecycle(out ulong changes);
    [DllImport("s2arm_android")] private static extern void s2a_capacity_enter(int role);
    [DllImport("s2arm_android")] private static extern void s2a_capacity_leave(int role);
    [DllImport("s2arm_android")] private static extern void s2a_capacity_check();
    [DllImport("s2arm_android")] private static extern ulong s2a_android_host_backing_progress(ulong owner, int advance);
    [DllImport("s2arm_android")] private static extern void s2a_android_host_set_threaded(int on);

    // Native owns all backing deadlines; managed code reports work and obeys decisions.
    [DllImport("s2arm_android")] private static extern int s2a_android_host_backing_decision(ulong owner);
    internal Func<ulong, int> BackingDecision = s2a_android_host_backing_decision;
    internal Func<ulong, int, ulong> BackingProgress = s2a_android_host_backing_progress;
    internal Action<int> HostThreaded = s2a_android_host_set_threaded;

    private static long ProducerLifecycle()
    {
        int foreground = s2a_android_host_lifecycle(out ulong changes);
        return foreground == 1 ? (long)(changes & long.MaxValue) : -1;
    }
    private readonly ManualResetEventSlim _ready = new();
    private readonly ManualResetEventSlim _done = new();
    private readonly CancellationTokenSource _cancel = new();
    private IRenderer _renderer;
    private Switch _device;
    private MemoryTracking _tracking;
    private Thread _worker;
    private Exception _failure;
    private bool _gpuDisposed;
    private readonly object _backingGate = new();
    private BackingChange _backingChange;
    private long _backingSequence;
    private bool _gpuInitialized;
    private bool _backingClosed;
    private static AndroidVulkanRuntime _current;
    // Optional Android diagnostics. Observe only a successfully queued game present;
    // this is CPU QueuePresent cadence, not proof of actual display time.
    public Action<ulong> FramePresented { get; set; }

    // 拆线程（启动 extra s2arm.threaded_renderer → JNI → S2A_ANDROID_THREADED_RENDERER=0|1；外壳缺省见 ThreadedRendererConfig）。
    // 关（0 / 未设）：_threaded / _render 都为空，Run / DrainAndPoll / WaitPump / CopyGuestMemory 原样，S2A.GPU 一条线程独占 GPU（单线程基线）。
    // 开（1）：HLE 拿到 ThreadedRenderer（下层仍是同一个 VulkanRenderer）。S2A.GPU = GPU 模拟（GPFIFO 解码 / 状态 / 读 guest 内存 / 写跟踪排空 /
    // 换页事务所有者，RunThreaded）；S2A.GPU.Vk = 渲染线程（Vulkan 初始化与全部 GAL 命令执行、WSI 租约 / 出图 / 退休、出图计数，RenderMain）。
    private ThreadedRenderer _threaded;
    private Thread _render;
    private readonly ManualResetEventSlim _renderStarted = new();
    private ThreadClock _simClock;
    private long _simFifoWaitTicks;
    // 以下只在渲染线程上读写
    private bool _renderWsiClosed;
    private ulong _renderPresentsSeen;
    private ThreadSplitStats _split;
    // 渲染线程空等命令时多久轮询一次 WSI 租约：同上游 FIFO 空等的轮询间隔
    private const int RenderPollMilliseconds = 8;
    // 拆线程上限（README「拆线程」一节写依据）：
    // - 条数：命令环全部可用槽（9999）。命令环构造时预分配，条数上限不是内存口径；9000 Wonder 全窗口峰 4050–6514 条，压低会在重帧上让模拟线程等渲染线程。
    // - 在途载荷：64 MiB（贴图 SetData 数据 + 环形池放不下的新分配；预分配的 8 MiB 环形池与命令环不算）。单线程时这些数据当场消费，拆线程后最多多驻留这么多。
    // - 渲染线程卡住：前台连续 2000 ms 没有前进（执行完一条命令 / 轮询一次 WSI / 编译通道泵一次）再宽限 250 ms → 按失败处理。
    //   2000 > 渲染线程上有期限但不泵的单步（换页 marker fence 1000 ms、acquire 1000 ms）；2000 + 250 + 50（分片）< 换页回调前台 3000 ms 预算，
    //   换页时渲染线程卡住，先报出的是这里的精确诊断，guest 的 3 s 期限还有约 700 ms 余量。
    private const long ThreadedPayloadBytes = 64L << 20;
    private const int RenderStallMilliseconds = 2000, RenderStallGraceMilliseconds = 250;
    // 拆线程 auto（S2A_ANDROID_THREADED_RENDERER=auto）：本局按上局记录决定，本局测量写记录下局生效；0 / 1 显式覆盖时为空、不读不写记录。
    private ThreadedAuto _auto;
    // 本局游戏声明过的最高出图速率（最小交换间隔）；0 = 还没声明过
    private double _declaredHz;

    private sealed class BackingChange
    {
        public long Id;
        // Diagnostic state only. Keep the last attempted phase if an operation throws;
        // neither this field nor its log is a completion or permission signal.
        public string Phase = "accepted";
        public ulong Address, Size, Source;
        public int ThreadId, Mapped;
        public bool NeedsGpu, Direct;
        public BackingPublication Publication;
        public readonly ManualResetEventSlim Prepared = new();
        public readonly ManualResetEventSlim Replaced = new();
        public readonly ManualResetEventSlim Finished = new();
    }

    // Protocol and transition oracle: docs/换页等待状态机.md. One owner per transaction,
    // registered before the GPU can observe it. Phase numbers only increase; closing is final.
    private sealed class BackingPublication
    {
        private readonly Func<ulong, int, ulong> _publish;
        private ulong _owner;
        private int _stage;
        private bool _closed;
        private readonly Func<ulong, int> _decision;
        public BackingPublication(Func<ulong, int, ulong> publish, Func<ulong, int> decision)
        { _publish = publish; _decision = decision; }
        public int Decision() { lock (this) return _decision(_owner); }
        public void Enter(int stage)
        {
            lock (this)
            {
                if (_closed || stage <= _stage) return;
                _stage = stage;
                if (_owner == 0 && stage == 1)
                    _owner = _publish(0, 1);
                else if (_owner != 0)
                    _publish(_owner, 1);
            }
        }
        public void Pulse(int stage)
        {
            lock (this)
                if (!_closed && stage == _stage && _owner != 0)
                    _publish(_owner, 1);
        }
        public void Close()
        {
            lock (this)
            {
                if (_closed) return;
                _closed = true;
                if (_owner != 0) _publish(_owner, 0);
            }
        }
    }

    [DllImport("s2a_native")] private static extern int s2a_android_copy_guest_readonly(ulong address, void* destination, ulong size);

    private static void CopyGuestMemory(ulong address, Memory<byte> target)
    {
        fixed (byte* destination = target.Span)
        {
            int error = s2a_android_copy_guest_readonly(address, destination, (ulong)target.Length);
            if (error != 0)
                throw new InvalidOperationException($"Android guest read copy failed: {address:x}+{target.Length:x}, errno {error}.");
        }
    }

    [DllImport("s2arm_android", EntryPoint = "s2a_android_copy_asset")]
    private static extern long s2a_android_copy_asset(string name, string path);

    [DllImport("s2a_native")] private static extern int s2a_track_runtime_prepared();
    [DllImport("s2a_native")] private static extern int s2a_track_gpu_reserve(ulong address, ulong size);
    [DllImport("s2a_native")] private static extern void s2a_track_set_backing_callbacks(
        delegate* unmanaged<ulong, ulong, ulong, void> before, delegate* unmanaged<ulong, ulong, int, void> after);

    public AndroidVulkanRuntime(nint leaseApi, ulong session, Action<Exception> fatal, string gameDataDirectory = null,
        bool transferFullClears = false, string stateDirectory = null, Func<long> lifecycle = null)
    {
        _lifecycle = lifecycle ?? ProducerLifecycle;
        // The window's acquire wait budgets on the same producer epoch, not on the lease
        // owner thread's polled Foreground flag (which freezes with its owner).
        _surface = new AndroidVulkanSurface(leaseApi, session, transferFullClears, _lifecycle);
        _fatal = fatal ?? throw new ArgumentNullException(nameof(fatal));
        _gameDataDirectory = gameDataDirectory;
        _stateDirectory = stateDirectory;
    }

    /// <summary>
    /// 游戏声明的出图间隔（SurfaceFlinger 生效的交换间隔变化时调，秒/帧，0 = 不限）。拆线程 auto 用它判「呈现速率低于游戏请求」；
    /// 任意线程可调，无效值忽略。请求取本局声明过的最小间隔（最高速率），与局后判读 score.py 同口径：自适应的游戏跟不上时会临时退到间隔 2
    /// （9000 Wonder 间隔 1 / 2 交替，游戏要的是 60），按当前值取会把 52 Hz 判成「低于 30 Hz 请求」。没声明过按 60 Hz（交换间隔 1）。
    /// </summary>
    public void ObserveFrameInterval(float seconds)
    {
        if (!float.IsFinite(seconds) || seconds < 0) return;
        double hz = seconds == 0 ? double.PositiveInfinity : 1.0 / seconds;
        double seen;
        do
        {
            seen = Volatile.Read(ref _declaredHz);
            if (hz <= seen) return;
        }
        while (Interlocked.CompareExchange(ref _declaredHz, hz, seen) != seen);
    }

    /// <summary>拆线程 auto 判据用的请求速率：本局声明过的最高出图速率，没声明过 60 Hz</summary>
    internal double AutoRequestedHz
    {
        get
        {
            double declared = Volatile.Read(ref _declaredHz);
            return declared > 0 ? declared : 60;
        }
    }

    public IRenderer CreateRenderer()
    {
        if (_renderer != null) throw new InvalidOperationException("The game renderer already exists.");
        // NativeAOT may not run Reflection.Emit. This selects the existing MME AOT/interpreter.
        GraphicsConfig.EnableMacroJit = false;
        // Use the managed SPIR-V producer; the Android host does not supply a GLSL shaderc JIT.
        GraphicsConfig.EnableSpirvCompilationOnVulkan = true;
        GuestMemory.ReprotectHook = &NxTrack.Reprotect;
        GuestMemory.WriteUntrackedHook = &NxTrack.WriteUntracked;
        GuestMemory.WriteHook = &NxTrack.Write;
        GuestMemory.WriteQuietHook = &NxTrack.WriteQuiet;
        GuestMemory.GpuModifiedHook = &NxTrack.GpuModified;
        if (Interlocked.CompareExchange(ref _current, this, null) != null)
            throw new InvalidOperationException("Android GPU tracking already belongs to a session.");
        s2a_track_set_backing_callbacks(&BeforeBackingChange, &AfterBackingChange);
        _renderer = _surface.CreateRenderer();
        if (Environment.GetEnvironmentVariable("S2A_W9_PROFILE_FREEZE") == "1")
        {
            if (_renderer is not Ryujinx.Graphics.Vulkan.VulkanRenderer vulkan)
                throw new InvalidOperationException("Profile freeze requires the session's Vulkan renderer.");
            vulkan.S2AConfigureProgramProfileFreeze(GraphicsConfig.EnableSpirvCompilationOnVulkan,
                typeof(GpuContext).Assembly.ManifestModule.ModuleVersionId.ToString("N"));
            Console.Error.WriteLine("[s2a] Vulkan profile freeze opt-in enabled; selected after device initialization");
        }
        if (ThreadedRequested())
        {
            ComposeThreaded();
            return _renderer;
        }
        _surface.SetWaitPump(WaitPump);
        return _renderer;
    }

    // 拆线程的组装（CreateRenderer 与受控夹具共用这一处接线）：同一个下层渲染器套 ThreadedRenderer、设上限与卡住判据、
    // Vulkan 计数队列等待接入有界检查、登记宿主收局请求、驱动等待泵换成渲染线程版。
    private void ComposeThreaded()
    {
        HostThreaded(1);   // 原生收局据此把读 maps 的地址余量挪到 StopGpu 之后、有界，并起进度线程；单线程不设，保持基线
        _threaded = new ThreadedRenderer(_renderer) { S2ACollectStats = true };
        ConfigureThreadedBounds();
        // Vulkan 计数队列 FlushTo 里等计数结果（结果所在命令缓冲要靠渲染线程提交）：纳入有界等待与失败闩（复审 P1-5）
        if (_renderer is Ryujinx.Graphics.Vulkan.VulkanRenderer counters)
        {
            counters.S2ACounterLifetime = true;
            counters.S2AWaitCheck = () => _threaded.S2AWaitTick("Vulkan 计数队列结果（计数事件 Flush）");
        }
        // 宿主收局第一步（原生 lifecycle → S2A_CancelWaits → S2AShutdown.Request）就开始收局准备，不等 Stop：原生兜底 1.5 s 就结束进程
        Ryujinx.Common.S2AShutdown.OnRequest(OnHostShutdownRequested);
        _renderer = _threaded;
        _surface.SetWaitPump(RenderWaitPump);
        Console.Error.WriteLine("[s2a] 拆线程开（S2A_ANDROID_THREADED_RENDERER=1）：GAL 套 ThreadedRenderer；S2A.GPU = GPU 模拟，" +
            "S2A.GPU.Vk = Vulkan 录制 / 提交 / WSI；出图身份按渲染线程执行时取，SetBufferData 多一次环形池拷贝（Vulkan 无上传租约）；" +
            $"上限：已入队 {ThreadedRenderer.S2AQueueCapacity} 条、在途载荷 {ThreadedPayloadBytes >> 20} MiB，" +
            $"预分配 命令环 {(long)_threaded.S2ACommandSlotBytes * (ThreadedRenderer.S2AQueueCapacity + 1) / 1024} KiB + 环形池 {ThreadedRenderer.S2ASpanPoolBytes >> 20} MiB；" +
            $"渲染线程前台连续 {RenderStallMilliseconds} ms（宽限 {RenderStallGraceMilliseconds} ms）不前进按失败处理");
    }

    /// <summary>拆线程 auto 要游戏请求的出图间隔（宿主据此决定是否把 SurfaceFlinger 的回调接给 ObserveFrameInterval；0 / 1 时不接，与基线一致）</summary>
    public bool WantsFrameInterval => _auto != null;

    // 拆线程的条数 / 在途载荷上限与渲染线程卡住判据（依据见字段注释）。只在前台计时（生命周期钟 _lifecycle 由外壳写、任意线程可读）：
    // 后台 Android 可能冻结整个进程；判定为卡住时走 ThreadedStalled → Fail（首个异常锁存、fatal 回调），等待方抛 TimeoutException，不返回空结果。
    private void ConfigureThreadedBounds() =>
        _threaded.S2AConfigureBounds(ThreadedRenderer.S2AQueueCapacity, ThreadedPayloadBytes, RenderStallMilliseconds,
            RenderStallGraceMilliseconds, _lifecycle, ThreadedStalled);

    // 0 / 未设 = 单线程基线，1 = 拆线程，auto = 按本游戏上局记录（ThreadedAuto）；不认的值抛错，不按关处理。
    private bool ThreadedRequested()
    {
        switch (Environment.GetEnvironmentVariable("S2A_ANDROID_THREADED_RENDERER"))
        {
            case null or "0":
                return false;
            case "1":
                return true;
            case "auto":
                if (string.IsNullOrEmpty(_stateDirectory))
                    throw new InvalidOperationException("S2A_ANDROID_THREADED_RENDERER=auto requires the game state directory for its per-game record.");
                _auto = ThreadedAuto.Load(_stateDirectory);
                Console.Error.WriteLine($"[s2a] 拆线程 auto：本局{(_auto.Threaded ? "拆线程" : "单线程")}（{_auto.Basis}；记录 {_auto.Path}）");
                return _auto.Threaded;
            case string other:
                throw new InvalidOperationException($"S2A_ANDROID_THREADED_RENDERER must be 0, 1 or auto (got '{other}').");
        }
    }

    // 拆线程 auto：每个 5 s 循环窗口交给 ThreadedAuto。忙 = S2A.GPU 线程 CPU 时间 / 墙钟（等驱动 fence / acquire 时线程阻塞，不算忙；
    // 拆线程时就是模拟线程）；呈现 = 本窗出图次数 / 墙钟。第一窗只当起点。只在 GPU 线程上调（缺省钟取调用线程自己的 CPU 时钟）。
    private void RecordAutoWindow(long presents)
    {
        if (_auto == null) return;
        if (AutoCpuNanoseconds == null)
        {
            ThreadClock clock = ThreadClock.Current();
            AutoCpuNanoseconds = clock.Nanoseconds;
        }
        long cpu = AutoCpuNanoseconds(), wall = AutoWallTicks();
        if (cpu < 0)
        {
            if (!_autoCpuMissing) Console.Error.WriteLine("[s2a] 【红】拆线程 auto：读不到 S2A.GPU 线程 CPU 时钟，本局不评估、不写记录");
            _autoCpuMissing = true;
            return;
        }
        if (_autoLastCpu >= 0 && wall > _autoLastWall)
        {
            double seconds = (wall - _autoLastWall) / (double)System.Diagnostics.Stopwatch.Frequency;
            _auto.Window((cpu - _autoLastCpu) / 1e9 / seconds, presents / seconds, AutoRequestedHz);
        }
        _autoLastCpu = cpu;
        _autoLastWall = wall;
    }

    // 拆线程 auto 的时钟（夹具可换）：S2A.GPU 线程累计 CPU 纳秒（缺省在第一窗时取调用线程的 pthread CPU 时钟；读不到 = -1）与墙钟 tick。
    internal Func<long> AutoCpuNanoseconds;
    internal Func<long> AutoWallTicks = System.Diagnostics.Stopwatch.GetTimestamp;
    private long _autoLastCpu = -1, _autoLastWall;
    private bool _autoCpuMissing;

    // 拆线程收局（真机 9000：s2arm.finish 后原生兜底 1.5 s 结束进程；拆线程那局 Stop 晚到或收局慢，驱动管线缓存没落盘，下次冷启要重编）。
    // 宿主一发收局请求（S2AShutdown.Request，早于 Stop）就：停用卡住判据（收局只受宿主期限约束，复审 P1-6）、auto 不再评估 / 固定、
    // 把一次驱动管线缓存落盘排到编译通道（不等 Stop、不等后面的排空与退休），并在请求后每 250 ms 打一行进度（两条线程各自在哪一步 / 等什么 / 已等多久，
    // 等渲染线程的 guest 线程），1200 ms 起报红（赶在原生 1500 ms 兜底之前，不得静默丢缓存），收完打一行用时。只读状态、不阻塞，调用线程是原生收局线程。
    private long _shutdownRequestedAt;
    private Task<bool> _earlyPipelineSave;
    private Timer _shutdownProgress;
    private volatile string _threadedPhase = "启动";
    // 1200 ms 起进度行标黄（离原生 1500 ms 兜底不远）；成败交给原生兜底与局后判读，收完打完成耗时——收得慢但成功的局不出红（复审第 2 轮 P2-E）
    private const int ShutdownProgressMilliseconds = 250, ShutdownYellowMilliseconds = 1200;
    // 模拟线程主循环轮数（只模拟线程写）；收局进度据此看模拟线程是否还在转、渲染线程多久没执行完新命令
    private long _simLoops;
    private long _shutdownLastLoops = -1, _shutdownLastWork = -1, _shutdownLoopsAt, _shutdownWorkAt;
    private int _shutdownProgressBusy;

    private void OnHostShutdownRequested()
    {
        long requested = Environment.TickCount64;
        if (Interlocked.CompareExchange(ref _shutdownRequestedAt, requested, 0) != 0) return;
        _shutdownLastLoops = Volatile.Read(ref _simLoops);
        _shutdownLastWork = _threaded.S2AWorkProgress;
        _shutdownLoopsAt = _shutdownWorkAt = requested;
        _threaded.S2AShutdownBegun();
        _auto?.EndSession();
        try
        {
            if (VulkanBackend is Ryujinx.Graphics.Vulkan.VulkanRenderer vulkan) _earlyPipelineSave = vulkan.S2ASavePipelineCacheEarly();
        }
        catch (Exception error) when (error is InvalidOperationException or ObjectDisposedException)
        {
            LogOffThread($"[s2a] 【红】拆线程收局：提前落盘驱动管线缓存没排上（{error.GetType().Name}: {error.Message}）");
        }
        // 本回调跑在原生收局线程的 S2A_CancelWaits 里：日志交线程池写，不在这里同步写（stderr 管道满时会把收局第一步卡住，复审第 2 轮 P2-B）
        LogOffThread("[s2a] 拆线程收局请求：卡住判据停用（收局只受宿主期限约束），auto 不再评估；驱动管线缓存" +
            (_earlyPipelineSave != null ? "已排到编译通道提前落盘" : "没有可提前落盘的（无 Vulkan 编译通道）"));
        _shutdownProgress = new Timer(ShutdownProgress, null, ShutdownProgressMilliseconds, ShutdownProgressMilliseconds);
    }

    private static void LogOffThread(string line) => ThreadPool.UnsafeQueueUserWorkItem(static text => Console.Error.WriteLine(text), line, preferLocal: false);

    private string EarlyPipelineSaveState()
    {
        Task<bool> save = _earlyPipelineSave;
        if (save == null) return "没有提前落盘";
        if (!save.IsCompleted) return "提前落盘还在进行";
        return save.IsCompletedSuccessfully && save.Result ? "已提前落盘" : "提前落盘没写成";
    }

    // 收局进度（计时器线程）：Stop 有没有到；模拟线程在哪一步、主循环还转不转；渲染线程在干什么、多久没执行完新命令；
    // 等渲染线程已满 50 ms 的每个线程（模拟线程 / guest 写跟踪回调 / 计数线程）等什么、已等多久；换页事务；缓存落盘
    internal string ShutdownState()
    {
        BackingChange change = Volatile.Read(ref _backingChange);
        long now = Environment.TickCount64, loops = Volatile.Read(ref _simLoops), work = _threaded.S2AWorkProgress;
        if (loops != _shutdownLastLoops) { _shutdownLastLoops = loops; _shutdownLoopsAt = now; }
        if (work != _shutdownLastWork) { _shutdownLastWork = work; _shutdownWorkAt = now; }
        return $"Stop {(_cancel.IsCancellationRequested ? "已到" : "还没到（宿主还没进入 GPU 停止：原生收局还在前面的步骤，见「收局进度」行）")}；" +
            $"模拟线程 {_threadedPhase}（主循环第 {loops} 轮，{now - _shutdownLoopsAt} ms 没转）；渲染线程 {now - _shutdownWorkAt} ms 没执行完新命令；" +
            $"{_threaded.S2ADescribe()}；换页事务 {(change == null ? "无" : $"#{change.Id} {Volatile.Read(ref change.Phase)}")}；驱动管线缓存{EarlyPipelineSaveState()}";
    }

    private void ShutdownProgress(object state)
    {
        if (Interlocked.Exchange(ref _shutdownProgressBusy, 1) != 0) return;   // 上一行还没写完（日志管道满）就跳过这一拍
        try
        {
            long elapsed = Environment.TickCount64 - Interlocked.Read(ref _shutdownRequestedAt);
            if (_done.IsSet)
            {
                _shutdownProgress?.Dispose();
                return;
            }
            Console.Error.WriteLine(elapsed < ShutdownYellowMilliseconds
                ? $"[s2a] 拆线程收局 {elapsed} ms：{ShutdownState()}"
                : $"[s2a] 【黄】拆线程收局 {elapsed} ms 还没完成（原生收尾兜底 1500 ms 会直接结束进程）：{ShutdownState()}");
        }
        finally { Volatile.Write(ref _shutdownProgressBusy, 0); }
    }

    // 渲染线程卡住判定（ThreadedRenderer 的 onStall）：拆线程自身导致的失败，auto 选了拆线程时固定单线程；其余与 Fail 相同。
    private void ThreadedStalled(Exception error)
    {
        Fail(error);
        if (ReferenceEquals(Volatile.Read(ref _failure), error)) _auto?.Stalled(error);
    }

    // 设备身份 / 离线包 / profile 导出要的是下层 Vulkan 渲染器；单线程时就是 _renderer 本身。
    private IRenderer VulkanBackend => _threaded != null ? _threaded.BaseRenderer : _renderer;

    public void Start(Switch device, MemoryTracking tracking)
    {
        if (_worker != null || _renderer == null || !ReferenceEquals(device.Gpu.Renderer, _renderer))
            throw new InvalidOperationException("Start requires the session's unique unwrapped Vulkan renderer.");
        ArgumentNullException.ThrowIfNull(tracking);
        if (!device.Gpu.HostInitalized.WaitOne(0))
            throw new InvalidOperationException("Application registration has not published GPU host initialization.");
        string fifoWait = Environment.GetEnvironmentVariable("S2A_FIFO_WAIT_MS");
        if (fifoWait != null && (!int.TryParse(fifoWait, out int wait) || wait is < 1 or > 8))
            throw new InvalidOperationException("Android control polling requires S2A_FIFO_WAIT_MS in 1..8 ms.");
        _surface.SetPipelineCachePath(GetPipelineCachePath());
        _device = device;
        Console.Error.WriteLine($"[s2a] actual buffer read scratch={GpuContext.S2ABufferReadScratchEnabled}");
        _device.Gpu.S2AReadGuestMemory = CopyGuestMemory;
        if (_threaded != null) _device.Gpu.S2AReadGuestMemory = CopyGuestMemoryOffRenderThread;
        _tracking = tracking;
        _tracking.ReprotectOnActionRegistration = true;
        _tracking.BeforeTracking = ReserveGpuBacking;
        // The final fault-chain self-probe runs after managed initialization. Native guest
        // admission must still require runtime_ready before entering the SDK.
        if (s2a_track_runtime_prepared() != 1)
            throw new InvalidOperationException("Native Android tracking resources, installed dispatcher and VM provider are not prepared.");
        NxTrack.Init(tracking, BackingChanged, FailTracking);
        GPFifoDevice.S2ATrackSync = _threaded == null ? DrainAndPoll : DrainThreaded;
        _device.Gpu.GPFifo.S2AControlPoll = ProcessBackingChange;
        ThreadStart body = _threaded == null ? Run : RunThreaded;
        ThreadStart wrapped = () => { s2a_capacity_enter(1); try { body(); } finally { s2a_capacity_leave(1); } };
        _worker = new Thread(wrapped) { Name = "S2A.GPU", IsBackground = true };
        _worker.Start();
        if (!StartupWait.Wait(_ready, _lifecycle, 30_000))
        {
            Fail(new TimeoutException("Vulkan GPU startup did not complete within 30 foreground seconds."));
        }
        ThrowIfFailed();
        if (_done.IsSet) throw new InvalidOperationException("The GPU worker exited before guest admission.");
    }

    // S2 出包前置：把本机真实翻译 profile 导出给离线出包端（graphics/tools/shbake --vulkan-profile）。
    // 只有一个显式环境变量能触发；导出失败照报红，不改变游戏运行路径（包只是首启加速）。
    private void ExportProfileIfRequested()
    {
        string directory = Environment.GetEnvironmentVariable("S2A_SHADER_PROFILE_OUT");
        if (string.IsNullOrEmpty(directory))
            return;
        try
        {
            if (VulkanBackend is not Ryujinx.Graphics.Vulkan.VulkanRenderer renderer)
                throw new InvalidOperationException("The session renderer is not the shared Vulkan backend.");
            byte[] json = renderer.S2ASerializeProgramProfile();
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, "profile.json"), temporary = path + ".tmp";
            File.WriteAllBytes(temporary, json);
            File.Move(temporary, path, overwrite: true);
            Console.Error.WriteLine($"[s2a] Vulkan 翻译 profile 已导出：{path}");
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"[s2a] 【红】Vulkan 翻译 profile 导出失败：{e.GetType().Name}: {e.Message}");
        }
    }

    // S2 装包端：只在实际 device/profile 确定后、InitializeShaderCache 之前执行。包只做首启加速：
    // 校验不过就报红并继续按需翻译，不改渲染语义。内容根取自已安装的 revisions/<contentRoot>。
    private void MountShaderPack()
    {
        // 控制台/夹具没有游戏数据目录时这里没有包来源，不是错误。内容根取自已安装 revision 的
        // index.tsv（去掉 shaders/ 缓存行）：包随游戏包分发也不会改变它。
        string contentRoot = ShaderPackLayout.GameContentRoot(_gameDataDirectory);
        if (contentRoot == null)
        {
            if (!string.IsNullOrEmpty(_gameDataDirectory))
                Console.Error.WriteLine($"[s2a] 【黄】Vulkan 离线包：游戏数据目录没有 index.tsv（{_gameDataDirectory}），不装包；按需翻译");
            return;
        }

        if (!GraphicsConfig.EnableShaderCache)
        {
            Console.Error.WriteLine("[s2a] 【红】Vulkan 离线包：着色器磁盘缓存已关闭，不装包");
            return;
        }
        if (string.IsNullOrEmpty(GraphicsConfig.TitleId))
        {
            Console.Error.WriteLine("[s2a] 【红】Vulkan 离线包：程序号未登记，不装包");
            return;
        }

        try
        {
            if (VulkanBackend is not Ryujinx.Graphics.Vulkan.VulkanRenderer renderer)
            {
                Console.Error.WriteLine("[s2a] 【红】Vulkan 离线包：当前渲染器不是共用 Vulkan 后端，不装包");
                return;
            }

            VulkanProfile profile = VulkanProfile.Parse(renderer.S2ASerializeProgramProfile());
            string packRoot = ShaderPackLayout.PackageRoot(_gameDataDirectory, profile.Identity.ProfileKey);
            string assetPack = null;
            if (!Directory.Exists(packRoot))
                assetPack = ExtractAssetPack(profile.Identity.ProfileKey);
            if (assetPack == null && !Directory.Exists(packRoot))
            {
                // 出包端要的就是这两行：设备真实 profile（单行 JSON）与内容根，以后按同一身份出包。
                string profileJson = System.Text.Encoding.UTF8.GetString(profile.ToJson())
                    .Replace("\r", string.Empty).Replace("\n", string.Empty);
                Console.Error.WriteLine($"[s2a] 【黄】Vulkan 离线包：没有本设备 profile 的包（{packRoot}，内容根 {contentRoot}），首遇现翻");
                Console.Error.WriteLine("[s2a] vkpb-profile-json " + profileJson);
                return;
            }

            string source = assetPack ?? packRoot;
            if (assetPack != null) Console.Error.WriteLine($"[s2a] Vulkan 离线包：使用 APK 资产包（{source}）");
            string title = GraphicsConfig.TitleId.ToUpperInvariant();
            string cacheRoot = ShaderPackLayout.CacheRoot(AppDataManager.GamesDirPath, title);
            ShaderPackInstall result = ShaderPackInstaller.Install(source, cacheRoot, profile.Identity, title,
                contentRoot, typeof(ShaderProgram).Assembly.ManifestModule.ModuleVersionId.ToString("N"),
                profile.TranslatorClosure);

            // S2A：把包内程序数交给 ShaderCache，种入成功但 LoadShaders 读到 0 支时由它报红。
            S2AShaderCacheGuard.PackPrograms = result.Programs;
            if (result.Installed)
                Console.Error.WriteLine($"[s2a] Vulkan 离线包：{(result.Replaced ? "替换" : "种入")} {result.Files} 个文件 {result.Bytes >> 10} KB → {result.CacheRoot}（profile {profile.Identity.ProfileKey[..12]}）");
            else
                Console.WriteLine($"[s2a] Vulkan 离线包：已种（{result.PackKey[..12]}），保留本局学习结果");
            // S2A：包内 pso_warm.tsv 的加载屏预热清单；没有/读不了不假装成功。
            string warmList = Path.Combine(result.CacheRoot, "pso_warm.tsv");
            S2AShaderCacheGuard.WarmList = File.Exists(warmList) ? warmList : null;
            Console.Error.WriteLine($"[s2a] 加载屏预热清单：{(S2AShaderCacheGuard.WarmList == null ? "缺失" : warmList)}（包 {result.Programs} 程序）");

            if (result.Warning != null)
                Console.Error.WriteLine($"[s2a] 【红】Vulkan 离线包：{result.Warning}");
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"[s2a] 【红】Vulkan 离线包装包失败：{e.GetType().Name}: {e.Message}；按需翻译");
        }
    }

    // 随 per-game APK 分发的离线包（assets/game/shaders.zip，布局 vulkan/generic/<profileKey>/）。
    // 先复制到应用私有目录，再由同一条有界解压/校验实现处理；失败按红处理，不返回半成品。
    private static string ExtractAssetPack(string profileKey)
    {
        const string AssetName = "game/shaders.zip";
        string cache = Path.Combine(AppDataManager.GamesDirPath, "s2a-pack");
        try
        {
            Directory.CreateDirectory(cache);
            string zip = Path.Combine(cache, "shaders.zip");
            long length = s2a_android_copy_asset(AssetName, zip);
            if (length < 0)
            {
                if (length != -2) Console.Error.WriteLine($"[s2a] 【红】Vulkan 离线包：APK 资产取出失败（{length}）");
                return null;
            }
            if (length == 0 || length > ShaderPackArchive.MaximumBytes)
            {
                Console.Error.WriteLine($"[s2a] 【红】Vulkan 离线包：APK 资产包大小异常（{length}）");
                return null;
            }

            return ShaderPackArchive.Extract(zip, Path.Combine(cache, "unpacked"), profileKey);
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"[s2a] 【红】Vulkan 离线包：APK 资产包解压失败：{e.GetType().Name}: {e.Message}");
            return null;
        }
    }

    private static string GetPipelineCachePath()
    {
        if (!GraphicsConfig.EnableShaderCache || string.IsNullOrEmpty(GraphicsConfig.TitleId))
            return null;
        return Path.Combine(AppDataManager.GamesDirPath, GraphicsConfig.TitleId.ToLowerInvariant(),
            "cache", "pipeline", "vk-pipeline-cache.bin");
    }

    private long _s2aLoopPoll, _s2aLoopShade, _s2aLoopWait, _s2aLoopFrame, _s2aLoopPresent, _s2aLoopReported;
    private long _s2aLoopFrames, _s2aLoopPresents;

    // 定期落盘：崩溃 / 强杀不会走收局路径，最多丢一个周期的新管线。60 s 比一次 1.4 MB 写盘（几十 ms）大得多，
    //   且 S2ASavePipelineCachePeriodic 在没有新管线时不写盘；宿主收局路径仍保留提前 / 补存两次。
    private const int PeriodicPipelineSaveMilliseconds = 60_000;
    private long _s2aPeriodicPipelineSaveAt = -1;
    // 夹具注入（Control.Tests）：避免依赖真实 Vulkan 设备 / 60 s 钟。
    internal Func<Task<bool>> PeriodicPipelineSave;
    internal Func<long> PeriodicPipelineSaveClock = () => Environment.TickCount64;

    // S2A：启动期 GPU 线程几乎满用户态 CPU 但翻译/管线/模块都接近 0；按循环段落拆时间。
    private void S2AAccumulateLoop(long poll, long shade, long wait, long frame, long present, bool hadFifo, int presents)
    {
        _s2aLoopPoll += poll; _s2aLoopShade += shade; _s2aLoopWait += wait;
        _s2aLoopFrame += frame; _s2aLoopPresent += present;
        _s2aLoopFrames += hadFifo ? 1 : 0; _s2aLoopPresents += presents;
    }

    private void S2AReportLoop()
    {
        long now = Environment.TickCount64;
        S2APeriodicPipelineSave();
        if (now - _s2aLoopReported < 5000) return;
        s2a_capacity_check();
        double Ms(long t) => t * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
        Console.Error.WriteLine($"[s2a] GPU 循环 5s：poll {Ms(_s2aLoopPoll):0} ms、save {Ms(_s2aLoopShade):0}、wait {Ms(_s2aLoopWait):0}（fifo {_s2aLoopFrames}）、frame {Ms(_s2aLoopFrame):0}、present {Ms(_s2aLoopPresent):0}（{_s2aLoopPresents}）");
        RecordAutoWindow(_s2aLoopPresents);
        _s2aLoopPoll = _s2aLoopShade = _s2aLoopWait = _s2aLoopFrame = _s2aLoopPresent = 0;
        _s2aLoopFrames = _s2aLoopPresents = 0;
        _s2aLoopReported = now;
    }

    // S2A（11-03）：主循环定期把驱动管线缓存落到 App 私有目录；失败只记日志，渲染继续。夹具可注入时钟与落盘动作。
    private void S2APeriodicPipelineSave()
    {
        long now = PeriodicPipelineSaveClock();
        long last = Interlocked.Read(ref _s2aPeriodicPipelineSaveAt);
        if (last < 0)
        {
            Interlocked.Exchange(ref _s2aPeriodicPipelineSaveAt, now);
            return;
        }
        if (now - last < PeriodicPipelineSaveMilliseconds) return;
        Interlocked.Exchange(ref _s2aPeriodicPipelineSaveAt, now);

        Task<bool> save;
        try
        {
            save = PeriodicPipelineSave != null
                ? PeriodicPipelineSave()
                : VulkanBackend is Ryujinx.Graphics.Vulkan.VulkanRenderer vulkan ? vulkan.S2ASavePipelineCachePeriodic() : null;
        }
        catch (Exception e) when (e is InvalidOperationException or ObjectDisposedException)
        {
            Console.Error.WriteLine($"[s2a] 【红】定期落盘驱动管线缓存没排上（{e.GetType().Name}: {e.Message}）");
            return;
        }

        if (save == null) return;
        _ = save.ContinueWith(static task =>
        {
            if (task.IsCompletedSuccessfully && task.Result) return;
            string why = task.IsFaulted ? task.Exception?.GetBaseException().Message
                : task.IsCanceled ? "取消" : "没写成";
            Console.Error.WriteLine($"[s2a] 定期落盘驱动管线缓存未完成：{why}");
        }, TaskContinuationOptions.ExecuteSynchronously);
    }

    private void WaitPump()
    {
        // Stop requests do not abort an accepted draw's driver call. The session exits through
        // the existing bounded drain and the renderer's stop order; a hung driver call still
        // hits the host stop deadline and terminates instead of destroying objects in use.
        ThrowIfFailed();
        _surface.PollIfReady();
    }

    private void DrainAndPoll()
    {
        ThrowIfFailed();
        _device.Gpu.GPFifo.S2APollControl();
        NxTrack.Drain(_tracking);
        _surface.Poll(); // Also handles control events between long GPFIFO batches.
    }

    // 拆线程：同 DrainAndPoll，但 WSI 只归渲染线程（ThreadedRenderer 批间 / 空等超时回调 RenderPoll），模拟线程不碰 surface。
    // 租约 owner 是做 Vulkan 初始化的线程：模拟线程误碰会被 NativeLease 的线程检查直接拒绝。
    private void DrainThreaded()
    {
        ThrowIfFailed();
        _device.Gpu.GPFifo.S2APollControl();
        NxTrack.Drain(_tracking);
    }

    // 拆线程：渲染器等驱动调用时的泵（编译通道等有期限的等待）。泵在转 = 渲染器活着，报给 ThreadedRenderer 当前进（任意线程）；
    // WSI 只在渲染线程上轮询；其他线程（持渲染线程锁直调下层的非 GPU 线程）只查失败。
    private void RenderWaitPump()
    {
        ThrowIfFailed();
        _threaded.S2ANoteAlive();
        if (Thread.CurrentThread == _render && !_renderWsiClosed) _surface.PollIfReady();
    }

    // 拆线程反证：渲染线程只碰环形池里的拷贝和 Vulkan 自有内存（Android 没开 host-pointer import），不读 guest 内存，换页时不会有渲染线程读旧映射。
    private void CopyGuestMemoryOffRenderThread(ulong address, Memory<byte> target)
    {
        if (Thread.CurrentThread == _render)
            throw new InvalidOperationException("The render thread must not read guest memory; only the GPU emulation thread copies it.");
        CopyGuestMemory(address, target);
    }

    private static void ReserveGpuBacking(ulong address, ulong size)
    {
        int result = s2a_track_gpu_reserve(address, size);
        if (result != 0)
            throw new NotSupportedException($"Android GPU backing admission failed for {address:x}+{size:x}: errno {result}; persistent GPU aliases are unsupported.");
        // Reservations deliberately survive failed construction and handle disposal until
        // session end. This conservative bound avoids a second alias/lifetime registry.
    }

    private void BackingChanged(ulong address, ulong size)
    {
        // Android must use the two-phase callback. This old after-only notification cannot
        // prove old GPU writes were flushed before replacement.
        throw new InvalidOperationException($"Unpaired Vulkan backing replacement: {address:x}+{size:x}.");
    }

    [UnmanagedCallersOnly]
    private static void BeforeBackingChange(ulong address, ulong size, ulong source)
    {
        try { _current.BeginBackingChange(address, size, source); }
        catch (Exception error) { _current.FailTracking(error); }
    }

    [UnmanagedCallersOnly]
    private static void AfterBackingChange(ulong address, ulong size, int mapped)
    {
        try { _current.EndBackingChange(address, size, mapped); }
        catch (Exception error) { _current.FailTracking(error); }
    }

    private void BeginBackingChange(ulong address, ulong size, ulong source)
    {
        // 拆线程反证：渲染线程发起换页 = 它等模拟线程准备、模拟线程等它执行同步命令，互等。渲染线程不做 guest VM 操作，走到这里就是接线错了。
        if (_render != null && Thread.CurrentThread == _render)
            throw new InvalidOperationException("A backing change on the render thread would wait for the GPU emulation thread that waits for it.");
        ThrowIfFailed();
        if (size == 0 || address + size < address || source + size < source || ((address | size | source) & 0xfff) != 0)
            throw new ArgumentException("Backing replacement requires a non-empty aligned guest range.");
        BackingChange change;
        lock (_backingGate)
        {
            if (_backingChange != null || _backingClosed || _cancel.IsCancellationRequested)
                throw new InvalidOperationException("Backing replacement overlaps another operation or GPU shutdown.");
            change = new BackingChange { Id = ++_backingSequence, Address = address, Size = size, Source = source,
                ThreadId = Environment.CurrentManagedThreadId, NeedsGpu = _gpuInitialized,
                Direct = Thread.CurrentThread == _worker };
            if (_threaded != null && change.NeedsGpu && !change.Direct)
            {
                change.Publication = new BackingPublication(BackingProgress, BackingDecision);
                change.Publication.Enter(1);
            }
            _backingChange = change;
            if (!change.NeedsGpu)
            {
                Volatile.Write(ref change.Phase, "initial-unmap");
                _tracking?.Unmap(address, size);
                Volatile.Write(ref change.Phase, "await-native-replacement");
                return; // No renderer resources exist yet; initial native maps remain legal.
            }
            Volatile.Write(ref change.Phase, "await-gpu-prepare");
            if (!change.Direct) _device.Gpu.GPFifo.S2ASignalControl();
        }
        if (change.Direct) PrepareBackingChange(change);
        else
        {
            WaitForGpuStep(change.Prepared, "GPU did not prepare old backing within three seconds.", change.Publication, 1);
        }
        ThrowIfFailed();
    }

    // Android freezes the whole process while the activity is backgrounded; a wall-clock
    // deadline then expires during the freeze and turns a healthy resume into a fatal error.
    // The budget therefore runs on the producer lifecycle epoch — the same clock as the
    // startup wait: only continuous-foreground milliseconds on one unchanged epoch count,
    // so a background transition or a new window generation restarts the allowance, and a
    // transition sampled mid-wait takes effect immediately (not only at entry). The host
    // stop deadline still owns real hangs.
    private void WaitForGpuStep(ManualResetEventSlim signal, string failure, BackingPublication publication = null, int stage = 1)
    {
        if (_threaded != null)
        {
            WaitForGpuStepThreaded(signal, failure, publication, stage);
            return;
        }
        if (!StartupWait.Wait(signal, _lifecycle, 3000) && !signal.Wait(250))
            throw new TimeoutException(failure);
    }

    // Polling is only scheduling. All timeout/grace/lifecycle decisions come from
    // the native lease; a late managed observation never creates a fresh budget.
    private void WaitForGpuStepThreaded(ManualResetEventSlim signal, string failure, BackingPublication publication = null, int stage = 1)
    {
        long published = _threaded.S2AWorkProgress;
        bool localPublication = publication == null;
        publication ??= new BackingPublication(BackingProgress, BackingDecision);
        publication.Enter(stage);
        try
        {
            while (!signal.Wait(100))
            {
                long observed = _threaded.S2AWorkProgress;
                if (observed != published) { published = observed; publication.Pulse(stage); }
                int decision = publication.Decision();
                if (decision == 0) continue;
                if (decision == 3) throw new InvalidOperationException("Backing transaction revoked by native authority.");
                string emulation = $"; GPU emulation thread at '{_threadedPhase}', main loop {Volatile.Read(ref _simLoops)}, queued {_threaded.S2ADescribe()}";
                throw new TimeoutException(decision == 2
                    ? $"{failure} (threaded: native total budget 30000 ms exceeded{emulation})"
                    : $"{failure} (threaded: native no render-side work budget exceeded{emulation})");
            }
        }
        catch { publication.Close(); throw; }
        finally { if (localPublication) publication.Close(); }
    }

    private void EndBackingChange(ulong address, ulong size, int mapped)
    {
        BackingChange change;
        lock (_backingGate)
        {
            change = _backingChange;
            if (change == null || change.Address != address || change.Size != size ||
                change.ThreadId != Environment.CurrentManagedThreadId || mapped is not (0 or 1))
                throw new InvalidOperationException("Backing completion does not match its native transaction.");
            change.Mapped = mapped;
        }
        if (!change.NeedsGpu || change.Direct) FinishBackingChange(change);
        else
        {
            change.Replaced.Set();
            WaitForGpuStep(change.Finished, "GPU did not adopt new backing within three seconds.", change.Publication, 3);
            change.Publication?.Close();
        }
        ThrowIfFailed();
    }

    private long _s2aBcCount, _s2aBcMs, _s2aBcMax, _s2aBcPrepareMs, _s2aBcReported;
    private long _s2aBcDrainMs, _s2aBcGpuMs, _s2aBcCompleteMs, _s2aBcFlushMs;
    private long _s2aBcFlush2Ms, _s2aBcComplete2Ms, _s2aBcUnmapMs;
    private long _s2aBcSkippedMarkers;   // 拆线程省掉的第二条 marker（见 PrepareBackingChange）

    private void ProcessBackingChange()
    {
        BackingChange change;
        lock (_backingGate) change = _backingChange;
        if (change == null || !change.NeedsGpu || change.Direct) return;
        long s2aStart = System.Diagnostics.Stopwatch.GetTimestamp();
        long s2aPrepareStart = s2aStart;
        PrepareBackingChange(change);
        long s2aPrepareEnd = System.Diagnostics.Stopwatch.GetTimestamp();
        change.Prepared.Set();
        WaitForGpuStep(change.Replaced, "Native backing replacement did not finish within three seconds.", change.Publication, 2);
        FinishBackingChange(change);
        long s2aEnd = System.Diagnostics.Stopwatch.GetTimestamp();
        double Ms(long a, long b) => (b - a) * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
        _s2aBcCount++;
        _s2aBcMs += (long)Ms(s2aStart, s2aEnd);
        _s2aBcPrepareMs += (long)Ms(s2aPrepareStart, s2aPrepareEnd);
        long total = (long)Ms(s2aStart, s2aEnd);
        if (total > _s2aBcMax) _s2aBcMax = total;
        long now = Environment.TickCount64;
        if (now - _s2aBcReported >= 5000)
        {
            _s2aBcReported = now;
            Console.Error.WriteLine($"[s2a] backing 变更：{_s2aBcCount} 次、总 {_s2aBcMs} ms（prepare {_s2aBcPrepareMs}：drain {_s2aBcDrainMs}、gpu {_s2aBcGpuMs}、complete {_s2aBcCompleteMs}、flush {_s2aBcFlushMs}；complete2 {_s2aBcComplete2Ms}、unmap {_s2aBcUnmapMs}）、max {_s2aBcMax} ms" +
                (_threaded != null ? $"；拆线程省掉第二条 marker {_s2aBcSkippedMarkers} 次（旧 backing 无回写源、队列已空）" : ""));
            _s2aBcSkippedMarkers = 0;
            _s2aBcCount = _s2aBcMs = _s2aBcPrepareMs = _s2aBcMax = 0;
            _s2aBcDrainMs = _s2aBcGpuMs = _s2aBcCompleteMs = _s2aBcFlushMs = 0;
            _s2aBcFlush2Ms = _s2aBcComplete2Ms = _s2aBcUnmapMs = 0;
            _s2aFlushCalls = _s2aFlushRuns = 0;
        }
    }

    private void PrepareBackingChange(BackingChange change)
    {
        // Native calls before holding its VM/tracker locks. The GPU owns this entire sequence;
        // no worker command may run between this preparation and native completion.
        double BcMs(long a, long b) => (b - a) * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
        long t0 = System.Diagnostics.Stopwatch.GetTimestamp();
        Volatile.Write(ref change.Phase, "drain-tracking");
        NxTrack.Drain(_tracking);
        long t1 = System.Diagnostics.Stopwatch.GetTimestamp();
        Volatile.Write(ref change.Phase, "gpu-prepare");
        _device.Gpu.PrepareBackingChange();
        long t2 = System.Diagnostics.Stopwatch.GetTimestamp();
        Volatile.Write(ref change.Phase, "queue-marker-before-old-backing-flush");
        CompletePendingCommands();
        long t3 = System.Diagnostics.Stopwatch.GetTimestamp();
        long produced = _threaded?.S2AProducedCommands ?? 0;   // 拆线程：第一条 marker 之后的生产侧序号（见下，省第二条 marker）
        if (change.Source != 0)
        {
            Volatile.Write(ref change.Phase, "flush-source-backing");
            FlushOldBacking(change.Source, change.Size);
        }
        long t4 = System.Diagnostics.Stopwatch.GetTimestamp();
        _s2aBcDrainMs += (long)BcMs(t0, t1);
        _s2aBcGpuMs += (long)BcMs(t1, t2);
        _s2aBcCompleteMs += (long)BcMs(t2, t3);
        _s2aBcFlushMs += (long)BcMs(t3, t4);
        // 目标地址的 FlushOldBacking 已删除：实测 Perm==0、事件从不发出，只剩每次约 20 ms 的
        // Native.MemQuery；加载期每秒约 200 次 backing 变更，是启动期 GPU 线程的主要开销。
        Volatile.Write(ref change.Phase, "queue-marker-after-old-backing-flush");
        long t5 = System.Diagnostics.Stopwatch.GetTimestamp();
        // 拆线程：旧 backing 没有要回写的源（Source == 0）时，第一条 marker 之后模拟线程（唯一生产者）没再入队任何 GAL 命令、
        // GPU 也已按第一条 marker 等过 fence：第二条 marker 只会再排空一个空队列、再等一次空 fence。省掉它，每次换页少一次渲染线程往返
        // （9000 Wonder 冷启到首帧前两个 5 s 窗共约 1200 次换页，fc7cb6e6 拆线程第二条 marker 平均 0.49 ms、单线程 0.10 ms）。
        // 「中间没有新入队」用生产侧序号判断（本线程是唯一生产者，前后两次读数相等即可；不读消费侧计数——渲染线程先放开同步命令再减计数，会偶发读到 1）。单线程不变
        if (_threaded != null && change.Source == 0 && _threaded.S2AProducedCommands == produced) _s2aBcSkippedMarkers++;
        else CompletePendingCommands();
        long t6 = System.Diagnostics.Stopwatch.GetTimestamp();
        Volatile.Write(ref change.Phase, "unmap-old-tracking");
        _tracking.Unmap(change.Address, change.Size);
        long t7 = System.Diagnostics.Stopwatch.GetTimestamp();
        _s2aBcComplete2Ms += (long)BcMs(t5, t6);
        _s2aBcUnmapMs += (long)BcMs(t6, t7);
    }

    // 换页 / 收局的队列 marker。单线程直调。拆线程：一条同步命令（InvokeCommand）让渲染线程先把已入队的 GAL 命令全部执行完
    // （= 排空 GAL 队列），再在渲染线程上 flush + 有界 fence；返回时队列为空，模拟线程是唯一生产者且正在这里等，事务期间不会再有新命令。
    private void CompletePendingCommands()
    {
        if (_threaded == null) _surface.CompletePendingCommands(1000);
        else OnRenderThread(() => _surface.CompletePendingCommands(1000));
    }

    // 拆线程：模拟线程把一段工作交渲染线程同步执行（排在已入队命令之后）。它抛错 = 渲染线程失败：失败闩放开本线程并按原异常重抛。
    private void OnRenderThread(Action action)
    {
        if (Thread.CurrentThread != _worker)
            throw new InvalidOperationException("Only the GPU emulation thread may hand synchronous work to the render thread.");
        _threaded.S2AOnRenderThread(action);
    }

    private long _s2aFlushCalls, _s2aFlushRuns;

    private void FlushOldBacking(ulong address, ulong size)
    {
        if (Native.MemQuery == null) throw new InvalidOperationException("Backing replacement needs the native VM query provider.");
        ulong end = address + size;
        // 相邻且权限相同的映射合并成一次事件：200 次/秒的 backing 变更里逐页调用
        // VirtualMemoryEvent 会重复拿 TrackingLock、分配 overlaps 数组，是启动期热点。
        ulong runStart = 0, runEnd = 0;
        uint runPerm = uint.MaxValue;
        void EmitRun()
        {
            if (runPerm != 0 && runPerm != uint.MaxValue && runEnd > runStart)
            {
                _tracking.VirtualMemoryEvent(runStart, runEnd - runStart, true, precise: false, exemptId: null, guest: true);
                _s2aFlushRuns++;
            }
        }
        for (ulong cursor = address; cursor < end;)
        {
            MemInfo info;
            if (Native.MemQuery(cursor, &info) != 0 || info.Base > cursor ||
                info.Size == 0 || info.Base + info.Size <= cursor)
                throw new InvalidOperationException("Native VM query did not cover the old backing range.");
            ulong next = Math.Min(end, info.Base + info.Size);
            _s2aFlushCalls++;
            if (runPerm == info.Perm && cursor == runEnd)
            {
                runEnd = next;
            }
            else
            {
                EmitRun();
                runStart = cursor;
                runEnd = next;
                runPerm = info.Perm;
            }
            cursor = next;
        }
        EmitRun();
    }

    private void FinishBackingChange(BackingChange change)
    {
        Volatile.Write(ref change.Phase, "adopt-new-mapping");
        if (change.Mapped != 0 && _tracking != null)
        {
            _tracking.Map(change.Address, change.Size);
            // Unmap clears handle dirty state. Re-dirty the new mapping so cached GPU contents
            // cannot survive a replacement at the same virtual address.
            Volatile.Write(ref change.Phase, "notify-new-mapping");
            _tracking.VirtualMemoryEvent(change.Address, change.Size, true, precise: false, exemptId: null, guest: true);
        }
        Volatile.Write(ref change.Phase, "finish");
        lock (_backingGate) _backingChange = null;
        change.Finished.Set();
    }

    private void Run()
    {
        try
        {
            lock (_backingGate)
            {
                if (_backingChange != null) throw new InvalidOperationException("Native backing replacement overlaps GPU initialization.");
                _renderer.Initialize(GraphicsDebugLevel.None);
                _device.Gpu.SetGpuThread();
                // Device identity is only real after Initialize; both stay before the shader cache
                // reads its files and neither may change the on-demand path on failure.
                ExportProfileIfRequested();
                MountShaderPack();
                _device.Gpu.InitializeShaderCache(_cancel.Token);
                _gpuInitialized = true;
            }
            if (GraphicsConfig.EnableMacroJit || !GraphicsConfig.EnableSpirvCompilationOnVulkan)
                throw new InvalidOperationException("Android NativeAOT requires interpreted MME and managed SPIR-V compilation.");
            _surface.Poll();
            _ready.Set();
            while (!_cancel.IsCancellationRequested && !_surface.Stopping)
            {
                ThrowIfFailed();
                long s2aT0 = System.Diagnostics.Stopwatch.GetTimestamp();
                _device.Gpu.GPFifo.S2APollControl();
                long s2aT1 = System.Diagnostics.Stopwatch.GetTimestamp();
                _surface.Poll();
                // 首帧前的长时间翻译没有 FIFO 帧推进；磁盘缓存保存队列只在帧里排空会把
                // 翻译成果一直留在内存（真机 544 条只有 19 条宿主落盘）。这里每个控制轮次
                // 都排空一次，不依赖 guest 新帧。
                _device.Gpu.ProcessShaderCacheQueue();
                long s2aT2 = System.Diagnostics.Stopwatch.GetTimestamp();
                bool s2aHadFifo = _device.WaitFifo();
                long s2aT3 = System.Diagnostics.Stopwatch.GetTimestamp();
                if (s2aHadFifo)
                {
                    _device.Gpu.GPFifo.S2ASync();
                    _device.ProcessFrame();
                }
                long s2aT4 = System.Diagnostics.Stopwatch.GetTimestamp();
                int s2aPresents = 0;
                while (!_cancel.IsCancellationRequested && _device.ConsumeFrameAvailable())
                {
                    _device.Gpu.GPFifo.S2APollControl();
                    _surface.Poll();
                    Action<ulong> sample = FramePresented;
                    ulong previousPresents = sample != null ? _surface.QueuedGamePresents : 0;
                    _device.PresentFrame(null); // The real GAL texture from guest SurfaceFlinger.
                    if (sample != null)
                    {
                        ulong presents = _surface.QueuedGamePresents;
                        if (presents != previousPresents) sample(presents);
                    }
                    s2aPresents++;
                }
                long s2aT5 = System.Diagnostics.Stopwatch.GetTimestamp();
                S2AAccumulateLoop(s2aT1 - s2aT0, s2aT2 - s2aT1, s2aT3 - s2aT2, s2aT4 - s2aT3,
                    s2aT5 - s2aT4, s2aHadFifo, s2aPresents);
                S2AReportLoop();
            }
            // S2A 诊断：EXIT_SELF 时区分是我们请求停止还是租约停止，定位 Run 返回原因。
            Console.Error.WriteLine($"[s2a] GPU Run 退出：cancel={_cancel.IsCancellationRequested} leaseStopping={_surface.Stopping}");
            // The services/native caller has stopped guest producers before shutdown. Complete
            // already accepted FIFO work before disposing the context that owns its channels.
            // Pair with Begin's check/publication/signal. Cancellation remains outside this
            // gate so it can interrupt shader-cache initialization, which also holds the gate.
            lock (_backingGate) _backingClosed = true;
            _device.Gpu.GPFifo.S2APollControl();
            while (_device.WaitFifo())
            {
                _device.Gpu.GPFifo.S2ASync();
                _device.ProcessFrame();
            }
            _device.Gpu.PrepareBackingChange();
            // S2A（10-27）：驱动管线缓存先落盘，再排空待提交命令 / 停 WSI / 证明退休。原生 1.5 s 兜底不改。
            (bool _, bool wsiRetired) = S2AFinishSingleThreaded(
                SavePipelineCacheBeforeWsiRetire,
                () => _surface.CompletePendingCommands(1000),
                _surface.Stop,
                () => _surface.Retired,
                _surface.Poll,
                () => Thread.Sleep(1),
                1500,
                () => Environment.TickCount64);
            if (!wsiRetired)
                throw new TimeoutException("WSI retirement is unproven; retain GPU/lease and terminate the host process.");
            _device.DisposeGpu();
            _gpuDisposed = true;
            GPFifoDevice.S2ATrackSync = null;
            _device.Gpu.GPFifo.S2AControlPoll = null;
        }
        catch (Exception e) { Fail(e); }
        finally
        {
            try { WriteWsiExitSummary(); }
            finally { _ready.Set(); _done.Set(); }
        }
    }

    private void WriteWsiExitSummary()
    {
        // The fatal callback has already been delivered; a failed sink must not replace it.
        try { Console.Error.WriteLine($"[s2a] GPU Run 退出后：{_surface.RetirementSummary}"); }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }

    // 拆线程：GPU 模拟线程 S2A.GPU（Run 的对应物）。与 Run 的差别只在线程分工：
    // - 初始化：仍持 _backingGate 整段（替页请求照样等初始化完）；Vulkan 初始化 / profile 导出 / 离线包在渲染线程上做完、渲染循环跑起来，
    //   再在本线程 SetGpuThread + 着色器缓存装载（装载要发 GAL 命令，渲染循环必须已在跑）。
    // - 主循环：不碰 surface（不 Poll、不读出图计数）；PresentFrame 只入队，出图与 FramePresented 在渲染线程（RenderAfterPresent）。
    // - 收局：排空 FIFO → 渲染线程上排空 GAL 队列 + fence → 渲染线程上停 WSI 并证明退休 → 本线程 DisposeGpu
    //   （ThreadedRenderer 在渲染线程上释放 Vulkan、放倒并等渲染线程退出）。任一步抛错 → Fail，对象保留到进程结束（同 Run）。
    private void RunThreaded()
    {
        try
        {
            _simClock = ThreadClock.Current();
            lock (_backingGate)
            {
                if (_backingChange != null) throw new InvalidOperationException("Native backing replacement overlaps GPU initialization.");
                _render = new Thread(RenderMain) { Name = "S2A.GPU.Vk", IsBackground = true };
                _render.Start();
                WaitHandle.WaitAny([_renderStarted.WaitHandle, _cancel.Token.WaitHandle]);
                ThrowIfFailed();
                _cancel.Token.ThrowIfCancellationRequested();
                _threaded.S2ABindGpuThread();
                _device.Gpu.SetGpuThread();
                _device.Gpu.InitializeShaderCache(_cancel.Token);
                _gpuInitialized = true;
            }
            if (GraphicsConfig.EnableMacroJit || !GraphicsConfig.EnableSpirvCompilationOnVulkan)
                throw new InvalidOperationException("Android NativeAOT requires interpreted MME and managed SPIR-V compilation.");
            _ready.Set();
            _threadedPhase = "主循环";
            while (!_cancel.IsCancellationRequested && !_surface.Stopping)
            {
                Volatile.Write(ref _simLoops, _simLoops + 1);
                ThrowIfFailed();
                long s2aT0 = System.Diagnostics.Stopwatch.GetTimestamp();
                _device.Gpu.GPFifo.S2APollControl();
                long s2aT1 = System.Diagnostics.Stopwatch.GetTimestamp();
                _device.Gpu.ProcessShaderCacheQueue();
                long s2aT2 = System.Diagnostics.Stopwatch.GetTimestamp();
                bool s2aHadFifo = _device.WaitFifo();
                long s2aT3 = System.Diagnostics.Stopwatch.GetTimestamp();
                if (s2aHadFifo)
                {
                    _device.Gpu.GPFifo.S2ASync();
                    _device.ProcessFrame();
                }
                long s2aT4 = System.Diagnostics.Stopwatch.GetTimestamp();
                int s2aEnqueuedPresents = 0;
                while (!_cancel.IsCancellationRequested && _device.ConsumeFrameAvailable())
                {
                    _device.Gpu.GPFifo.S2APollControl();
                    // 只入队：ThreadedWindow 先等上一条出图命令开始执行（模拟线程最多领先一帧），出图 / 计数 / FramePresented 都在渲染线程。
                    _device.PresentFrame(null);
                    s2aEnqueuedPresents++;
                }
                long s2aT5 = System.Diagnostics.Stopwatch.GetTimestamp();
                Interlocked.Add(ref _simFifoWaitTicks, s2aT3 - s2aT2);
                S2AAccumulateLoop(s2aT1 - s2aT0, s2aT2 - s2aT1, s2aT3 - s2aT2, s2aT4 - s2aT3,
                    s2aT5 - s2aT4, s2aHadFifo, s2aEnqueuedPresents);
                S2AReportLoop();
            }
            Console.Error.WriteLine($"[s2a] GPU Run 退出（拆线程）：cancel={_cancel.IsCancellationRequested} leaseStopping={_surface.Stopping}");
            // 收局：卡住判据停用、auto 不再评估（没经宿主收局请求就停时也一样，例如租约 Stopping）
            _threaded.S2AShutdownBegun();
            _auto?.EndSession();
            lock (_backingGate) _backingClosed = true;
            long teardown = Environment.TickCount64;
            _threadedPhase = "收局：排空 FIFO";
            _device.Gpu.GPFifo.S2APollControl();
            while (_device.WaitFifo())
            {
                _device.Gpu.GPFifo.S2ASync();
                _device.ProcessFrame();
            }
            _device.Gpu.PrepareBackingChange();
            long fifo = Environment.TickCount64;
            _threadedPhase = "收局：渲染线程排空 GAL 队列 + marker";
            CompletePendingCommands();
            long drained = Environment.TickCount64;
            _threadedPhase = "收局：渲染线程停 WSI / 证明退休";
            OnRenderThread(RetireWsiOnRenderThread);
            long retired = Environment.TickCount64;
            // 宿主收局（Stop / 收局请求到了，进程马上 _exit）：GPU 层照常释放自己的账（写跟踪句柄等，之后服务层还会动 guest 内存），
            // 下层（Vulkan）对象不逐个释放、设备不销毁，渲染线程上只补存驱动管线缓存（WSI 已退休）。真机 9000 01a3af10：逐个释放走 GAL 队列，
            // 「释放 GPU」一段 1.0–1.2 s 还没到下层 Dispose 的末尾，收局完成行一局都没打出来就被原生 1.5 s 兜底结束。租约 Stopping（进程不退出）照原样全量释放
            bool exiting = _cancel.IsCancellationRequested || Interlocked.Read(ref _shutdownRequestedAt) != 0;
            if (exiting)
            {
                if (VulkanBackend is Ryujinx.Graphics.Vulkan.VulkanRenderer vulkan)
                {
                    bool joined = vulkan.S2AStopCountersForExit(100);
                    Console.Error.WriteLine($"[s2a] 拆线程收局：计数回调已关闭，消费线程{(joined ? "已停止" : "尚未退出（保留查询资源到进程结束）")}");
                }
                _threaded.S2ADiscardFrees = true;
                _threaded.S2AExitRelease = ExitReleaseOnRenderThread;
            }
            _threadedPhase = exiting ? "收局：释放 GPU 层（进程即将退出，下层不逐个释放）" : "收局：释放 GPU（编译通道停、驱动管线缓存落盘、Vulkan 释放）";
            _device.DisposeGpu();
            _gpuDisposed = true;
            _threadedPhase = "收局完成";
            long done = Environment.TickCount64;
            long requested = Interlocked.Read(ref _shutdownRequestedAt);
            long queryTimeouts = VulkanBackend is Ryujinx.Graphics.Vulkan.VulkanRenderer vk ? vk.QueryTimeouts : 0;
            long nullImageFallbacks = VulkanBackend is Ryujinx.Graphics.Vulkan.VulkanRenderer vkNullImage ? vkNullImage.S2ANullImageFallbacks : 0;
            long nullTexelFallbacks = VulkanBackend is Ryujinx.Graphics.Vulkan.VulkanRenderer vkNullTexel ? vkNullTexel.S2ANullTexelFallbacks : 0;
            string uniformRange = VulkanBackend is Ryujinx.Graphics.Vulkan.VulkanRenderer vkRange && vkRange.S2AUniformBufferRangeErrors > 0
                ? $"；{vkRange.S2AUniformBufferRangeSummary}" : "";
            string steps = $"GPU Run 退出后：排空 FIFO {fifo - teardown}、GAL 队列 {drained - fifo}、WSI 退休 {retired - drained}、" +
                $"{(exiting ? "GPU 层释放" : "GPU 释放")} {done - retired}（其中渲染线程上下层收尾 {Volatile.Read(ref _exitReleaseMilliseconds)}）ms" +
                $"{(queryTimeouts > 0 ? $"；查询超时 {queryTimeouts} 次" : "")}" +
                $"{(nullImageFallbacks > 0 ? $"；null storage image 回退 {nullImageFallbacks} 次" : "")}" +
                $"{(nullTexelFallbacks > 0 ? $"；null texel buffer view 回退 {nullTexelFallbacks} 次" : "")}{uniformRange}；{_surface.RetirementSummary}";
            if (requested != 0)
            {
                long took = done - requested;
                Console.Error.WriteLine($"[s2a] {(took >= ShutdownYellowMilliseconds ? "【黄】" : "")}拆线程收局完成：宿主收局请求后 {took} ms；{steps}");
            }
            else
            {
                Console.Error.WriteLine($"[s2a] 拆线程收局完成：{steps}");
            }
            GPFifoDevice.S2ATrackSync = null;
            _device.Gpu.GPFifo.S2AControlPoll = null;
        }
        catch (Exception e) { Fail(e); }
        finally
        {
            try { if (Volatile.Read(ref _failure) != null) WriteWsiExitSummary(); }
            finally { _ready.Set(); _done.Set(); }
        }
    }

    // 拆线程：渲染线程 S2A.GPU.Vk。下层 Vulkan 在本线程初始化，所以 WSI 租约 owner、窗口 / swapchain、主命令池都归本线程；
    // 之后跑 ThreadedRenderer 渲染循环，直到模拟线程收局放倒。失败：Fail 锁存，ThreadedRenderer 的失败闩放开在等本线程的模拟线程。
    private void RenderMain()
    {
        try
        {
            _threaded.Initialize(GraphicsDebugLevel.None);
            ExportProfileIfRequested();
            MountShaderPack();
            _split = new ThreadSplitStats(this, ThreadClock.Current());
            _threaded.S2AAfterPresent = RenderAfterPresent;
            _threaded.S2ARunBackend(_renderStarted.Set, RenderPoll, RenderPollMilliseconds);
        }
        catch (Exception e) { Fail(e); }
        finally { _renderStarted.Set(); }
    }

    // 拆线程：渲染线程上的宿主轮询（ThreadedRenderer 空等超时 / 批间调，持渲染线程锁）。会话已失败就抛错，让渲染线程退出。
    private void RenderPoll()
    {
        ThrowIfFailed();
        if (!_renderWsiClosed) _surface.Poll();
    }

    // 拆线程：出图计数与 FramePresented（metrics / 叠层计数）归渲染线程：下层 Present 正常返回且成功排队数增加才算一帧。
    private void RenderAfterPresent()
    {
        ulong presents = _surface.QueuedGamePresents;
        if (presents == _renderPresentsSeen) return;
        _renderPresentsSeen = presents;
        FramePresented?.Invoke(presents);
        _split.Present();
    }

    // 拆线程收局（渲染线程上，经 OnRenderThread 排在已入队命令之后）：先打收局累计行（两条线程都还活着、钟可读；放在 Vulkan 释放之前，
    // 进程随后被宿主结束也不丢这一行），再同 Run 停 WSI 并有界证明退休。退休等待自身有 1500 ms 期限，期间报活，不算渲染线程卡住。
    // 宿主收局、进程马上退出时代替下层渲染器的 Dispose（渲染线程上，WSI 已退休）：只把提前落盘之后新建的管线补存一次，最多等 ExitSaveMilliseconds，
    // 不停编译通道、不销毁设备与对象（随 _exit 回收）。补存走编译通道（与管线创建串行），超时不等、旧文件保留
    private const int ExitSaveMilliseconds = 300;
    private long _exitReleaseMilliseconds;
    internal Func<Task<bool>> ExitPipelineSave;

    private void ExitReleaseOnRenderThread()
    {
        long start = Environment.TickCount64;
        Task<bool> save = ExitPipelineSave != null ? ExitPipelineSave()
            : VulkanBackend is Ryujinx.Graphics.Vulkan.VulkanRenderer vulkan ? vulkan.S2ASavePipelineCacheForExit() : null;
        string saved = save == null ? "没有可补存的（无 Vulkan 编译通道）"
            : !save.Wait(ExitSaveMilliseconds) ? $"补存 {ExitSaveMilliseconds} ms 没写完（不等，旧文件保留）"
            : save.IsCompletedSuccessfully && save.Result ? "盘上是最新的" : "补存没写成（旧文件保留）";
        Volatile.Write(ref _exitReleaseMilliseconds, Environment.TickCount64 - start);
        Console.Error.WriteLine($"[s2a] 拆线程收局：进程即将退出，下层渲染器不逐个释放（WSI 已退休）；驱动管线缓存{saved}");
    }

    private void RetireWsiOnRenderThread()
    {
        _split?.Summary();
        _surface.Stop();
        long deadline = Environment.TickCount64 + 1500;
        while (!_surface.Retired && Environment.TickCount64 < deadline)
        {
            _surface.Poll();
            _threaded.S2ANoteAlive();
            Thread.Sleep(1);
        }
        if (!_surface.Retired)
            throw new TimeoutException("WSI retirement is unproven; retain GPU/lease and terminate the host process.");
        _renderWsiClosed = true;
    }

    // S2A（10-27，单线程收局）：驱动管线缓存在停 WSI / 证明退休之前落盘。原生兜底 1.5 s 内单线程要做完整释放，
    //   窗口 / WSI 退休可能吃掉大半预算（9000 r8 通过局总共 1.405 s，只剩 95 ms；18:02 局 GPU Run 退出 +0.670 s、
    //   Surface detached +1.029 s、1.509 s 被 _exit(124)，落盘排在 WSI 退休之后没赶上）。落盘只有几十毫秒，先做：
    //   后面退休 / 释放超时也不丢缓存。1500 ms 兜底与退休期限都不改。返回（是否落盘，是否证明退休）
    internal static (bool Saved, bool Retired) S2AFinishSingleThreaded(
        Func<bool> save, Action complete, Action stop, Func<bool> retired, Action poll, Action wait,
        int deadlineMs, Func<long> now)
    {
        complete();
        bool saved = save != null && save();
        stop();
        long deadline = now() + deadlineMs;
        while (!retired())
        {
            if (now() >= deadline) return (saved, false);
            poll();
            wait();
        }
        return (saved, true);
    }

    // 夹具注入：单线程收局 WSI 退休前的“落盘”动作（真机走 VulkanRenderer.S2ASavePipelineCacheBeforeWsiRetire）
    internal Func<bool> SavePipelineCacheBeforeWsi;

    private bool SavePipelineCacheBeforeWsiRetire()
    {
        long start = Environment.TickCount64;
        bool saved = false;
        try
        {
            saved = SavePipelineCacheBeforeWsi != null
                ? SavePipelineCacheBeforeWsi()
                : VulkanBackend is Ryujinx.Graphics.Vulkan.VulkanRenderer vulkan && vulkan.S2ASavePipelineCacheBeforeWsiRetire();
        }
        catch (Exception e) when (e is InvalidOperationException or ObjectDisposedException)
        {
            Console.Error.WriteLine($"[s2a] 【红】单线程收局：WSI 退休前落盘驱动管线缓存失败（{e.GetType().Name}: {e.Message}）");
        }
        Console.Error.WriteLine($"[s2a] 单线程收局：驱动管线缓存在 WSI 退休前{(saved ? "已落盘" : "没落盘（无通道 / 没写成，旧文件保留）")}（{Environment.TickCount64 - start} ms）");
        return saved;
    }

    public void Stop()
    {
        _cancel.Cancel();
        _surface.Wake();
        _device?.Gpu.GPFifo.SignalNewEntries();
        if (_worker == null)
        {
            ThrowIfFailed();
            if (_renderer != null)
                throw new InvalidOperationException("GPU startup did not reach its owner thread; retain partially composed HLE/GPU objects until host termination.");
            return;
        }
        if (Thread.CurrentThread == _worker || (_render != null && Thread.CurrentThread == _render))
            throw new InvalidOperationException("The GPU fatal callback must not synchronously join its own worker.");
        if (!_done.Wait(3000))
            throw new TimeoutException("GPU worker did not stop; its native code and lease must stay alive.");
        ThrowIfFailed();
        if (!_gpuDisposed) throw new InvalidOperationException("GPU ownership has not been retired.");
    }

    public void ThrowIfFailed()
    {
        Exception failure = Volatile.Read(ref _failure);
        if (failure != null) ExceptionDispatchInfo.Capture(failure).Throw();
    }

    private void Fail(Exception error)
    {
        if (Interlocked.CompareExchange(ref _failure, error, null) != null) return;
        _cancel.Cancel();
        _ready.Set();
        // #1456：真机 DEVICE_LOST 回写当前指纹的 capprobe 结果（source=runtime-lost，
        // 只记指纹不记游戏），下次启动直接走规避不再探；写回失败不影响 fatal 流程。
        if (GsOcclusionQuerySupport.IsDeviceLostError(error))
        {
            try { GsOcclusionQuerySupport.MarkRuntimeLost(); } catch { }
        }
        AttachBackingFailure(error);
        // This callback requests native guest stop; it does not destroy objects on this thread.
        _fatal(error);
    }

    private void AttachBackingFailure(Exception error)
    {
        // Failure-only metadata: no I/O before the existing fatal callback. Do not take
        // the transaction gate or wake its waiters. IDs are session-local; thread IDs
        // below are managed IDs, not native TIDs. Preserve the original exception.
        try
        {
            BackingChange change = Volatile.Read(ref _backingChange);
            if (change == null) return;
            error.Data[nameof(AndroidVulkanRuntime)] = $"[GPU backing-change failure] transaction={change.Id} phase={Volatile.Read(ref change.Phase)} callerManagedThread={change.ThreadId} observerManagedThread={Environment.CurrentManagedThreadId} target=0x{change.Address:x}+0x{change.Size:x} source=0x{change.Source:x} sourceSize=0x{(change.Source != 0 ? change.Size : 0):x} needsGpu={change.NeedsGpu} direct={change.Direct}";
        }
        catch { }
    }

    private void FailTracking(Exception error)
    {
        // These void callbacks must never return to a native fault/write path after a failed
        // flush. An asynchronous stop request alone does not make retrying that access safe.
        try { Fail(error); }
        finally { Environment.FailFast("Android GPU memory tracking failed; native access cannot resume.", error); }
    }

    // 线程 CPU 时钟（pthread_getcpuclockid）：每条线程在自己身上取一次时钟号，之后任一线程都能读它的累计 CPU 时间（被读线程须仍存活）。
    // 非 Linux 宿主（host 夹具）或符号缺：Available = false，读数记「读不到」。
    private readonly struct ThreadClock
    {
        private readonly int _id;
        public bool Available { get; }

        private ThreadClock(int id)
        {
            _id = id;
            Available = true;
        }

        [StructLayout(LayoutKind.Sequential)] private struct Timespec { public long Seconds, Nanoseconds; }
        [DllImport("libc")] private static extern nint pthread_self();
        [DllImport("libc")] private static extern int pthread_getcpuclockid(nint thread, out int clock);
        [DllImport("libc")] private static extern int clock_gettime(int clock, out Timespec value);

        public static ThreadClock Current()
        {
            if (!OperatingSystem.IsLinux() && !OperatingSystem.IsAndroid()) return default;
            try { return pthread_getcpuclockid(pthread_self(), out int id) == 0 ? new ThreadClock(id) : default; }
            catch (EntryPointNotFoundException) { return default; }
            catch (DllNotFoundException) { return default; }
        }

        // 累计 CPU 纳秒；读不到返回 -1。
        public long Nanoseconds() =>
            Available && clock_gettime(_id, out Timespec value) == 0 ? value.Seconds * 1_000_000_000 + value.Nanoseconds : -1;
    }

    // 拆线程每 60 帧一行（渲染线程上，每次成功出图后结一帧；第一次出图只当起点），收局一行累计（截至最后一个整窗口）：
    // 呈现速率；模拟线程 / 渲染线程各自 CPU ms/帧；模拟线程 FIFO 空等与出图节流等待；渲染线程空等与醒来批数；同步命令（InvokeCommand，
    // 每次都是整条流水排空）次数、等待与按类型拆（读回 缓冲 / 贴图、动作、程序、其他）；同步号可用等待；出图入队时的队列深度均值 / 窗口峰值；
    // SetBufferData 比单线程多的那次环形池拷贝（Vulkan 无上传租约）与放不下改新分配；非 GPU 线程直调下层次数；
    // 背压（已入队条数 / 在途载荷到上限时模拟线程等的次数与时长）；计入在途的载荷（贴图 SetData 数据 + 环形池放不下的新分配）MB/帧与在途峰值。
    // 全部只在渲染线程上读写（Present 在出图命令后、Summary 在收局的渲染线程动作里）。
    private sealed class ThreadSplitStats
    {
        private const int Frames = 60;
        private readonly AndroidVulkanRuntime _owner;
        private readonly ThreadClock _render;
        private ThreadedRenderer.S2ACounters _first, _last;
        private long _firstAt, _firstSimCpu, _firstRenderCpu, _firstSimFifo, _firstOffThread;
        private long _windowStart, _lastSimCpu, _lastRenderCpu, _lastSimFifo, _lastOffThread;
        private long _windowFrames, _queuePeak, _payloadPeak;
        private int _frames;

        public ThreadSplitStats(AndroidVulkanRuntime owner, ThreadClock render)
        {
            _owner = owner;
            _render = render;
        }

        private static double PerFrameMs(long ticks, long frames) => ticks * 1000.0 / System.Diagnostics.Stopwatch.Frequency / frames;

        private static string Cpu(long now, long before, long frames) =>
            now < 0 || before < 0 ? "读不到" : $"{(now - before) / 1e6 / frames:F2} ms/帧";

        public void Present()
        {
            long now = System.Diagnostics.Stopwatch.GetTimestamp();
            if (_windowStart == 0)
            {
                _last = _first = _owner._threaded.S2AReadCounters(resetMax: true);
                _lastSimCpu = _firstSimCpu = _owner._simClock.Nanoseconds();
                _lastRenderCpu = _firstRenderCpu = _render.Nanoseconds();
                _lastSimFifo = _firstSimFifo = Interlocked.Read(ref _owner._simFifoWaitTicks);
                _lastOffThread = _firstOffThread = Interlocked.Read(ref ThreadedRenderer.S2AOffThreadCalls);
                _windowStart = _firstAt = now;
                return;
            }
            if (++_frames < Frames) return;

            ThreadedRenderer.S2ACounters c = _owner._threaded.S2AReadCounters(resetMax: true);
            long simCpu = _owner._simClock.Nanoseconds(), renderCpu = _render.Nanoseconds();
            long simFifo = Interlocked.Read(ref _owner._simFifoWaitTicks);
            long offThread = Interlocked.Read(ref ThreadedRenderer.S2AOffThreadCalls);
            double seconds = (now - _windowStart) / (double)System.Diagnostics.Stopwatch.Frequency;
            long depthCount = c.PresentDepthCount - _last.PresentDepthCount;
            double depth = depthCount > 0 ? (c.PresentDepthSum - _last.PresentDepthSum) / (double)depthCount : 0;
            Console.Error.WriteLine($"[s2a] 拆线程 {_frames} 帧：呈现 {_frames / seconds:F2} 帧/s；" +
                $"模拟线程 CPU {Cpu(simCpu, _lastSimCpu, _frames)}（FIFO 空等 {PerFrameMs(simFifo - _lastSimFifo, _frames):F2}、" +
                $"出图节流等 {PerFrameMs(c.FrameWaitTicks - _last.FrameWaitTicks, _frames):F2} ms/帧）；" +
                $"渲染线程 CPU {Cpu(renderCpu, _lastRenderCpu, _frames)}（空等 {PerFrameMs(c.IdleTicks - _last.IdleTicks, _frames):F2} ms/帧，" +
                $"醒 {c.Batches - _last.Batches} 次）；" +
                $"同步命令 {c.InvokeCount - _last.InvokeCount} 次、等 {PerFrameMs(c.InvokeTicks - _last.InvokeTicks, _frames):F2} ms/帧" +
                $"（单次 max {c.InvokeMaxTicks * 1000.0 / System.Diagnostics.Stopwatch.Frequency:F2} ms；" +
                $"读回 缓冲 {c.ReadbackBuffer - _last.ReadbackBuffer} / 贴图 {c.ReadbackTexture - _last.ReadbackTexture}，" +
                $"动作 {c.InvokeAction - _last.InvokeAction}，程序 {c.InvokeProgram - _last.InvokeProgram}，其他 {c.InvokeOther - _last.InvokeOther}）；" +
                $"同步号等 {c.SyncWaitCount - _last.SyncWaitCount} 次 {PerFrameMs(c.SyncWaitTicks - _last.SyncWaitTicks, _frames):F2} ms/帧；" +
                $"队列深度 出图时均 {depth:F0} / 峰 {c.QueueDepthMax}；" +
                $"上传多一次拷贝 {(c.UploadBytes - _last.UploadBytes) / 1048576.0 / _frames:F2} MB/帧" +
                $"（环形池放不下 {c.UploadSpills - _last.UploadSpills} 次 {(c.UploadSpillBytes - _last.UploadSpillBytes) / 1048576.0:F2} MB）；" +
                $"非 GPU 线程直调 {offThread - _lastOffThread} 次；" +
                $"背压 条数 {c.QueueWaitCount - _last.QueueWaitCount} 次 {PerFrameMs(c.QueueWaitTicks - _last.QueueWaitTicks, _frames):F2} ms/帧、" +
                $"载荷 {c.PayloadWaitCount - _last.PayloadWaitCount} 次 {PerFrameMs(c.PayloadWaitTicks - _last.PayloadWaitTicks, _frames):F2} ms/帧；" +
                $"在途载荷 {(c.PayloadBytes - _last.PayloadBytes) / 1048576.0 / _frames:F2} MB/帧（峰 {c.PayloadInFlightMax / 1048576.0:F2} MB）");
            _queuePeak = Math.Max(_queuePeak, c.QueueDepthMax);
            _payloadPeak = Math.Max(_payloadPeak, c.PayloadInFlightMax);
            _windowFrames += _frames;
            _last = c;
            _lastSimCpu = simCpu;
            _lastRenderCpu = renderCpu;
            _lastSimFifo = simFifo;
            _lastOffThread = offThread;
            _windowStart = now;
            _frames = 0;
        }

        // 收局时在渲染线程上调（WSI 停止前），只累计到最后一个整窗口。
        public void Summary()
        {
            if (_windowFrames == 0)
            {
                Console.Error.WriteLine("[s2a] 拆线程收局：没有完整的 60 帧窗口");
                return;
            }
            long frames = _windowFrames;
            double seconds = (_windowStart - _firstAt) / (double)System.Diagnostics.Stopwatch.Frequency;
            Console.Error.WriteLine($"[s2a] 拆线程收局（截至最后一个整窗口）：{frames} 帧、{seconds:F1} s（{frames / seconds:F2} 帧/s）；" +
                $"模拟线程 CPU {Cpu(_lastSimCpu, _firstSimCpu, frames)}（FIFO 空等 {PerFrameMs(_lastSimFifo - _firstSimFifo, frames):F2}、" +
                $"出图节流等 {PerFrameMs(_last.FrameWaitTicks - _first.FrameWaitTicks, frames):F2} ms/帧）；" +
                $"渲染线程 CPU {Cpu(_lastRenderCpu, _firstRenderCpu, frames)}（空等 {PerFrameMs(_last.IdleTicks - _first.IdleTicks, frames):F2} ms/帧）；" +
                $"同步命令 {_last.InvokeCount - _first.InvokeCount} 次（读回 {_last.ReadbackBuffer + _last.ReadbackTexture - _first.ReadbackBuffer - _first.ReadbackTexture}）、" +
                $"等 {PerFrameMs(_last.InvokeTicks - _first.InvokeTicks, frames):F2} ms/帧；" +
                $"上传多一次拷贝共 {(_last.UploadBytes - _first.UploadBytes) / 1048576.0:F1} MB（环形池放不下 {_last.UploadSpills - _first.UploadSpills} 次）；" +
                $"非 GPU 线程直调 {_lastOffThread - _firstOffThread} 次；" +
                $"队列深度峰 {_queuePeak} 条；背压 条数 {_last.QueueWaitCount - _first.QueueWaitCount} 次、载荷 {_last.PayloadWaitCount - _first.PayloadWaitCount} 次" +
                $"（共 {(_last.QueueWaitTicks - _first.QueueWaitTicks + _last.PayloadWaitTicks - _first.PayloadWaitTicks) * 1000.0 / System.Diagnostics.Stopwatch.Frequency:F0} ms）；" +
                $"在途载荷共 {(_last.PayloadBytes - _first.PayloadBytes) / 1048576.0:F1} MB（峰 {_payloadPeak / 1048576.0:F2} MB）");
        }
    }
}

// 拆线程 auto（S2A_ANDROID_THREADED_RENDERER=auto）：按本游戏上局实测负载决定本局是否拆线程，本局的测量写进记录、下局生效。
// 不在运行中切换：HLE / GpuContext 的渲染器对象与全部 GPU 资源句柄在构造时按渲染器类型定型（单线程是 Vulkan 原对象，拆线程是 Threaded*
// 句柄 + 映射），WSI 租约 owner 是做 Vulkan 初始化的线程、合批语义（SetInterruptAction）只能构造时装，中途换没有安全点。
// 记录在游戏状态目录（每台设备、每款游戏各一份，跟负载走，不按设备 / GPU 写死）。判据（README「拆线程」写依据）：
// - 窗口 = S2A.GPU 主循环的 5 s 报告窗；忙 = 该线程 CPU 时间 / 墙钟（等驱动 fence / acquire 的阻塞不算忙）；呈现 < 10 Hz 的窗（加载无出图）
//   不计并打断连续计数。饱和窗 = 忙 ≥ 0.85 且呈现 < 0.95 × 游戏请求；饱和段 = 连续 6 个饱和窗（30 s）。
// - 评估覆盖整局，不锁死前 N 窗（9000 真机：前 12 个有效窗全在标题 / 菜单，忙 0.83、44.1 Hz，旧判据据此记了单线程；进关后 37.7 Hz、忙约 0.98）。
// - 单线程一局：任何时刻出现饱和段 → 记「拆线程」（本局结论定）。累计 36 个有效窗（180 s）仍没有饱和段 → 记「单线程」并继续评估，之后再出现
//   饱和段就改写为「拆线程」。不到 36 个有效窗就结束 / 被杀 → 不写，记录保持上局（没完成的评估不当结论）。
// - 拆线程一局：只拿同类窗比——本局饱和段（拆线程下 S2A.GPU 仍饱和、仍低于请求）的呈现中位 vs 单线程饱和段中位：≥ 1.05 × → 保持；
//   否则「没收益」计一次，连续 2 局没收益才固定单线程（只 1 次 → 记单线程，下局重新测）。36 个有效窗都没有饱和段（重场景也够得着请求）→ 保持。
// - 固定单线程 = 之后 10 局 auto 都单线程、不评估，用完自动重新评估。只有拆线程自身的卡住判定（渲染线程不前进）这一种失败会固定；
//   其他失败（DeviceLost、写跟踪、启动取消等，与模式无关）不写记录；收局阶段（EndSession 之后）不评估、不固定。
// - 记录 v2（key=value）：数值必须有限且在范围内、reason 最长 300 字；读不了 / 不合法报【红】按无记录（单线程基线）重新测；v1 旧记录按无记录重测。
//   写盘在线程池上做（不在 GPU 主循环、不在 Fail 路径上同步写），按决定顺序最后一份为准；写不了报【红】，只丢这份结论。
internal sealed class ThreadedAuto
{
    internal const string FileName = "threaded-renderer.auto";
    internal const double SaturatedBusy = 0.85, BelowRequest = 0.95, MinGameplayHz = 10, KeepGain = 1.05;
    internal const int SaturatedStreak = 6, SettledWindows = 36, NoGainToPin = 2, PinSessions = 10, MaxReason = 300;

    internal sealed record Record(string Verdict, int NoGain, int PinnedLeft, double SingleHz, double SingleBusy, double ThreadedHz,
        double RequestedHz, string Reason)
    {
        public bool Pinned => PinnedLeft > 0;

        public string Format() => string.Create(CultureInfo.InvariantCulture,
            $"version=2\nverdict={Verdict}\nno_gain={NoGain}\npinned_left={PinnedLeft}\nsingle_hz={SingleHz:R}\nsingle_busy={SingleBusy:R}\nthreaded_hz={ThreadedHz:R}\nrequested_hz={RequestedHz:R}\nreason={Reason}\n");

        public string Summary() => string.Create(CultureInfo.InvariantCulture,
            $"{(Verdict == "threaded" ? "拆线程" : Pinned ? $"单线程（固定，还剩 {PinnedLeft} 局）" : "单线程")}：{Reason}");

        public static Record Parse(string text)
        {
            Dictionary<string, string> values = new();
            foreach (string line in text.Split('\n'))
            {
                int equals = line.IndexOf('=');
                if (equals > 0) values[line[..equals]] = line[(equals + 1)..];
            }
            if (!values.TryGetValue("version", out string version)) throw new InvalidDataException("Threaded-renderer record has no version.");
            if (version == "1") throw new NotSupportedException("version 1");
            if (version != "2") throw new InvalidDataException("Unsupported threaded-renderer record version: " + version);
            string verdict = values["verdict"];
            if (verdict is not ("threaded" or "single")) throw new InvalidDataException("Unknown threaded-renderer verdict: " + verdict);
            int Count(string key, int max)
            {
                int value = int.Parse(values[key], NumberStyles.None, CultureInfo.InvariantCulture);
                return value <= max ? value : throw new InvalidDataException($"{key} out of range: {value}");
            }
            double Number(string key, double min, double max, bool infinity = false)
            {
                double value = double.Parse(values[key], NumberStyles.Float, CultureInfo.InvariantCulture);
                bool ok = (double.IsFinite(value) || (infinity && double.IsPositiveInfinity(value))) && value >= min && value <= max;
                return ok ? value : throw new InvalidDataException($"{key} out of range: {values[key]}");
            }
            string reason = values["reason"];
            if (reason.Length > MaxReason) throw new InvalidDataException("Threaded-renderer record reason is too long.");
            var record = new Record(verdict, Count("no_gain", NoGainToPin - 1), Count("pinned_left", PinSessions),
                Number("single_hz", 0, 1000), Number("single_busy", 0, 4), Number("threaded_hz", 0, 1000),
                Number("requested_hz", 1, double.PositiveInfinity, infinity: true), reason);
            if (verdict == "threaded" && (record.SingleHz <= 0 || record.Pinned))
                throw new InvalidDataException("A threaded verdict needs its single-thread saturated rate and cannot be pinned.");
            return record;
        }
    }

    private static string Clip(string reason) => reason.Length <= MaxReason ? reason : reason[..MaxReason];

    private readonly Record _previous;
    private readonly object _gate = new();
    private readonly List<double> _rates = new(), _busy = new(), _streakRates = new(), _streakBusy = new();
    private readonly ManualResetEventSlim _idle = new(true);
    private Record _pending;
    private int _eligible;
    private bool _done, _failed, _ending, _writing;

    public string Path { get; }
    public bool Threaded { get; }
    public string Basis { get; }

    private ThreadedAuto(string path, Record previous, string basis)
    {
        Path = path;
        _previous = previous;
        Threaded = previous?.Verdict == "threaded";
        Basis = basis;
        if (previous is { Pinned: true })
        {
            // 固定单线程：本局不评估，用掉一局
            _done = true;
            Schedule(previous with { PinnedLeft = previous.PinnedLeft - 1 });
        }
    }

    public static ThreadedAuto Load(string stateDirectory)
    {
        string path = System.IO.Path.Combine(stateDirectory, FileName);
        if (!File.Exists(path)) return new ThreadedAuto(path, null, "无记录：单线程基线测量");
        try
        {
            Record previous = Record.Parse(File.ReadAllText(path));
            return new ThreadedAuto(path, previous, $"上局记录 {previous.Summary()}");
        }
        catch (NotSupportedException)
        {
            return new ThreadedAuto(path, null, "旧版（v1）记录：按无记录单线程重新测量");
        }
        catch (Exception error) when (error is IOException or InvalidDataException or FormatException or OverflowException
            or KeyNotFoundException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine($"[s2a] 【红】拆线程 auto：记录读不了（{error.GetType().Name}: {error.Message}），按无记录单线程重新测量：{path}");
            return new ThreadedAuto(path, null, "记录读不了：单线程基线重新测量");
        }
    }

    private static double Median(List<double> values)
    {
        List<double> sorted = new(values);
        sorted.Sort();
        return sorted.Count == 0 ? 0 : sorted[sorted.Count / 2];
    }

    // 一个 5 s 窗口（busy = 线程 CPU / 墙钟）：有结论就排一次写盘并返回它；收局开始或失败之后不再评估。
    public Record Window(double busy, double hz, double requestedHz)
    {
        if (!double.IsFinite(busy) || !double.IsFinite(hz) || hz < 0 || !(requestedHz > 0)) return null;
        lock (_gate)
        {
            Record record = Evaluate(busy, hz, requestedHz);
            if (record != null) Schedule(record);
            return record;
        }
    }

    // 持 _gate 调
    private Record Evaluate(double busy, double hz, double requestedHz)
    {
        if (_done || _ending) return null;
        if (hz < MinGameplayHz)
        {
            _streakRates.Clear();
            _streakBusy.Clear();
            return null;
        }
        _eligible++;
        _rates.Add(hz);
        _busy.Add(busy);
        // 单线程：模拟线程饱和且呈现低于请求才算（够得着请求或不忙 = 不缺拆线程）。拆线程：只看呈现低于请求（复审第 2 轮 P1-B）——
        // 瓶颈移到渲染线程 / GPU 时模拟线程在出图节流、背压、同步命令上阻塞而不忙，按忙判会永远凑不出比较段、每局都「保持」
        bool limited = hz < BelowRequest * requestedHz && (Threaded || busy >= SaturatedBusy);
        if (limited)
        {
            _streakRates.Add(hz);
            _streakBusy.Add(busy);
        }
        else
        {
            _streakRates.Clear();
            _streakBusy.Clear();
        }
        bool saturatedSegment = _streakRates.Count >= SaturatedStreak;
        double segmentHz = saturatedSegment ? Median(_streakRates) : 0, segmentBusy = saturatedSegment ? Median(_streakBusy) : 0;
        int noGain = _previous?.NoGain ?? 0;
        if (!Threaded)
        {
            if (saturatedSegment)
            {
                _done = true;
                return new Record("threaded", noGain, 0, segmentHz, segmentBusy, 0, requestedHz, Clip(string.Create(CultureInfo.InvariantCulture,
                    $"单线程饱和段（第 {_eligible} 个有效窗止）：S2A.GPU 忙 {segmentBusy:F2} ≥ {SaturatedBusy:F2}、呈现 {segmentHz:F1} Hz < {BelowRequest:F2} × 请求 {requestedHz:F1} Hz")));
            }
            if (_eligible != SettledWindows) return null;
            double singleHz = Median(_rates), singleBusy = Median(_busy);
            return new Record("single", 0, 0, singleHz, singleBusy, 0, requestedHz, Clip(string.Create(CultureInfo.InvariantCulture,
                $"单线程 {SettledWindows} 个有效窗（{SettledWindows * 5} s）没有饱和段（忙中位 {singleBusy:F2}、呈现中位 {singleHz:F1} Hz、请求 {requestedHz:F1} Hz）")));
        }
        if (saturatedSegment)
        {
            _done = true;
            string measured = string.Create(CultureInfo.InvariantCulture,
                $"拆线程低于请求段呈现中位 {segmentHz:F1} Hz（S2A.GPU 忙 {segmentBusy:F2}）vs 单线程饱和段 {_previous.SingleHz:F1} Hz、请求 {requestedHz:F1} Hz");
            if (segmentHz >= KeepGain * _previous.SingleHz)
                return _previous with { NoGain = 0, ThreadedHz = segmentHz, RequestedHz = requestedHz, Reason = Clip(measured + $"，≥ {KeepGain:F2} ×，保持") };
            int misses = noGain + 1;
            return misses >= NoGainToPin
                ? new Record("single", 0, PinSessions, _previous.SingleHz, _previous.SingleBusy, segmentHz, requestedHz,
                    Clip(measured + $"，< {KeepGain:F2} ×，连续 {misses} 局没收益，固定单线程 {PinSessions} 局"))
                : new Record("single", misses, 0, _previous.SingleHz, _previous.SingleBusy, segmentHz, requestedHz,
                    Clip(measured + $"，< {KeepGain:F2} ×，第 {misses} 局没收益，下局单线程重新测"));
        }
        if (_eligible != SettledWindows) return null;
        double threadedHz = Median(_rates);
        return _previous with
        {
            NoGain = 0,
            ThreadedHz = threadedHz,
            RequestedHz = requestedHz,
            Reason = Clip(string.Create(CultureInfo.InvariantCulture,
                $"拆线程 {SettledWindows} 个有效窗（{SettledWindows * 5} s）没有连续低于请求的段（呈现中位 {threadedHz:F1} Hz、请求 {requestedHz:F1} Hz；单线程饱和段 {_previous.SingleHz:F1} Hz），保持")),
        };
    }

    // 收局开始：之后的窗口与失败都不再评估 / 固定（收局释放慢、宿主停机期限这类与模式收益无关）。
    public void EndSession()
    {
        lock (_gate) _ending = true;
    }

    // 本局（auto 选了拆线程）被渲染线程卡住判定失败：固定单线程 PinSessions 局并返回该记录，覆盖本局先排的结论；之后不再写。
    // 只由卡住判定调；其他失败与模式无关，不调。
    public Record Stalled(Exception error)
    {
        lock (_gate)
        {
            if (!Threaded || _failed || _ending) return null;
            _failed = _done = true;
            Record record = new("single", 0, PinSessions, _previous.SingleHz, _previous.SingleBusy, 0, _previous.RequestedHz,
                Clip($"拆线程的一局渲染线程卡住（{error.GetType().Name}），固定单线程 {PinSessions} 局"));
            Schedule(record);
            return record;
        }
    }

    /// <summary>等排好的写盘做完（夹具 / 收局用）。</summary>
    public bool WaitWritten(int milliseconds) => _idle.Wait(milliseconds);

    // 排一次写盘：线程池上按顺序写，最后排的那份为准。
    private void Schedule(Record record)
    {
        lock (_gate)
        {
            _pending = record;
            if (_writing) return;
            _writing = true;
            _idle.Reset();
        }
        ThreadPool.UnsafeQueueUserWorkItem(_ => WriteLoop(), null);
    }

    private void WriteLoop()
    {
        while (true)
        {
            Record record;
            lock (_gate)
            {
                record = _pending;
                _pending = null;
                if (record == null)
                {
                    _writing = false;
                    _idle.Set();
                    return;
                }
            }
            try
            {
                string temporary = Path + ".tmp";
                File.WriteAllText(temporary, record.Format());
                File.Move(temporary, Path, overwrite: true);
                Console.Error.WriteLine($"[s2a] 拆线程 auto：下局{(record.Verdict == "threaded" ? "拆线程" : "单线程")}（{record.Summary()}；记录 {Path}）");
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                Console.Error.WriteLine($"[s2a] 【红】拆线程 auto：记录写不了（{error.GetType().Name}: {error.Message}），这份结论丢弃：{Path}");
            }
        }
    }
}
