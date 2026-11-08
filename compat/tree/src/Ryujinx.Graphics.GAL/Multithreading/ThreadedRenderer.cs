using Ryujinx.Common;
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL.Multithreading.Commands;
using Ryujinx.Graphics.GAL.Multithreading.Commands.Buffer;
using Ryujinx.Graphics.GAL.Multithreading.Commands.Renderer;
using Ryujinx.Graphics.GAL.Multithreading.Model;
using Ryujinx.Graphics.GAL.Multithreading.Resources;
using Ryujinx.Graphics.GAL.Multithreading.Resources.Programs;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Threading;

namespace Ryujinx.Graphics.GAL.Multithreading
{
    /// <summary>
    /// The ThreadedRenderer is a layer that can be put in front of any Renderer backend to make
    /// its processing happen on a separate thread, rather than intertwined with the GPU emulation.
    /// A new thread is created to handle the GPU command processing, separate from the renderer thread.
    /// Calls to the renderer, pipeline and resources are queued to happen on the renderer thread.
    /// </summary>
    public class ThreadedRenderer : IRenderer
    {
        private const int SpanPoolBytes = 8 * 1024 * 1024;
        private const int MaxRefsPerCommand = 2;
        private const int QueueCount = 10000;

        private readonly int _elementSize;
        private readonly IRenderer _baseRenderer;
        private Thread _gpuThread;
        private Thread _backendThread;
        private bool _running;

        private readonly AutoResetEvent _frameComplete = new(true);

        private readonly ManualResetEventSlim _galWorkAvailable;
        private readonly CircularSpanPool _spanPool;

        private readonly ManualResetEventSlim _invokeRun;
        private readonly AutoResetEvent _interruptRun;

        private bool _lastSampleCounterClear = true;

        private readonly byte[] _commandQueue;
        private readonly object[] _refQueue;

        private int _consumerPtr;
        private int _commandCount;

        private int _producerPtr;
        private int _lastProducedPtr;
        private int _invokePtr;

        private int _refProducerPtr;
        private int _refConsumerPtr;

        public uint ProgramCount { get; set; } = 0;

        private Action _interruptAction;
        private readonly Lock _interruptLock = new();

        public event EventHandler<ScreenCaptureImageInfo> ScreenCaptured;

        internal BufferMap Buffers { get; }
        internal SyncMap Sync { get; }
        internal CircularSpanPool SpanPool { get; }
        internal ProgramQueue Programs { get; }

        public IPipeline Pipeline { get; }
        public IWindow Window { get; }

        public IRenderer BaseRenderer => _baseRenderer;

        /// <summary>S2A：起 GPU 线程的方式（名字, 线程体）。空 = Ryujinx 原样 new Thread。宿主设成「原生线程 + 调度档 USER_INTERACTIVE」：
        /// .NET 起的线程 QoS 未指定、之后再设返回 EPERM（旧库 10-19 实测），iPhone 上会约一半时间落能效核。</summary>
        public static Action<string, Action> S2AStartThread;

        private ManualResetEventSlim _s2aGpuDone, _s2aBackendDone;

        /// <summary>S2A：下层渲染器（录像 / 宽屏 / NxGal 的 C# 层）按单线程写，由渲染线程独占：渲染线程每批命令持这把锁执行（命令之间有人等就让）；
        /// 非 GPU 线程直调下层的分支（建贴图、读缓冲、贴图读回 / 缩放拷贝）先等对象建好（自旋在锁外，否则等的就是持锁的渲染线程），再持同一把锁调。
        /// GPU 线程直调的同步 / 计数入口不持锁：下层对它们是无状态透传，NxGal C 层有导出入口全局锁、计数表与录像器各自有锁。</summary>
        private readonly Lock _s2aBaseLock = new();
        private int _s2aWaiters;

        /// <summary>S2A：非 GPU 线程进下层前拿渲染线程锁。渲染线程每条命令之间看到有人在等就让出（S2AYieldBase），
        /// 等的时长 ≤ 一条命令，不是一整批（忙时一批能连着执行整帧的命令；10-21 动森 Mac 一局这条路走 4425 次，多是游戏线程读回 GPU 数据）</summary>
        internal void S2AEnterBase()
        {
            Interlocked.Increment(ref _s2aWaiters);

            if (!S2ABounded)
            {
                _s2aBaseLock.Enter();
                Interlocked.Decrement(ref _s2aWaiters);

                return;
            }

            // S2A（宿主自起线程、设了上限）：渲染线程卡在一条命令里不放锁时有界；失败也要把等待计数还回去，否则渲染线程让锁时会一直等它
            try
            {
                if (!_s2aBaseLock.TryEnter())
                {
                    S2AStallWatch watch = S2AWatch();

                    while (!_s2aBaseLock.TryEnter(S2AWaitSliceMs))
                    {
                        S2ACheckStall(ref watch, "渲染线程锁（非 GPU 线程直调下层）");
                    }
                }
            }
            finally
            {
                Interlocked.Decrement(ref _s2aWaiters);
            }
        }

        internal void S2AExitBase() => _s2aBaseLock.Exit();

        // 渲染线程（持锁、深度 1）在两条命令之间调：放锁，等在等的线程都拿到过锁，再拿回
        private void S2AYieldBase()
        {
            _s2aBaseLock.Exit();
            SpinWait wait = new();

            while (Volatile.Read(ref _s2aWaiters) != 0)
            {
                wait.SpinOnce();
            }

            _s2aBaseLock.Enter();
        }

        /// <summary>S2A：非 GPU 线程直调下层的次数（收局日志报，判这条路实际走没走）</summary>
        public static long S2AOffThreadCalls;

        /// <summary>S2A：收局停渲染线程。GPU 线程已退出、命令队列已排空（FlushThreadedCommands）之后调：放倒 RenderLoop，RunLoop 返回。
        /// 不释放下层渲染器（与不套本层时的收局一致）；之后照样可以 Dispose。</summary>
        public void S2AStopBackend()
        {
            _running = false;
            _galWorkAvailable.Set();
        }

        // ---- S2A（Android 拆线程）：GPU 模拟线程与渲染线程都由宿主自己起，不经 RunLoop / S2AStartThread ----
        // GPU 模拟线程调 S2ABindGpuThread 登记自己；渲染线程调 S2ARunBackend 跑 RenderLoop，批与批之间 / 空等超时在渲染线程上回调宿主轮询；
        // 收局由 GPU 模拟线程经 GpuContext.Dispose → Dispose（S2ADisposeOwnedThreads）。渲染线程执行命令抛错时置失败闩、放开所有等它的线程，
        // 等待方醒来按原异常重抛，不返回空结果。宿主在 S2ARunBackend 前调 S2AConfigureBounds 后：已入队命令条数与在途载荷字节有上限
        // （到上限生产线程背压等），等渲染线程的各处有界（渲染线程连续不前进 → 失败闩 + 宿主失败入口 + TimeoutException）。
        // Apple（RunLoop / S2AStartThread）不调这些入口：钩子为空、S2ACollectStats 关、上限未设、失败闩恒空，与原来相同。

        /// <summary>S2A：渲染线程上每条出图命令的下层 Present 正常返回后调（宿主在渲染线程上取出图计数）；空 = 不调</summary>
        public Action S2AAfterPresent;

        /// <summary>S2A：开了才记 S2ACounters（同步命令 / 出图节流 / 同步号 / 渲染线程空等 / 队列深度 / 背压 / 载荷 / 上传拷贝）；关着每处只多一次布尔判断</summary>
        public bool S2ACollectStats;

        /// <summary>S2A：命令环可用槽数（环 QueueCount 槽，生产指针不能追上消费指针，留一槽）。宿主条数上限不能超过它</summary>
        public const int S2AQueueCapacity = QueueCount - 1;

        /// <summary>S2A：环形池字节数（构造时预分配，SetBufferData 等变长数据先拷进这里）</summary>
        public const int S2ASpanPoolBytes = SpanPoolBytes;

        /// <summary>S2A：一条命令槽的字节数（命令环构造时预分配 QueueCount 槽，内存口径用）</summary>
        public int S2ACommandSlotBytes => _elementSize;

        // 有界等待每片等多久再查一次渲染线程有没有前进
        private const int S2AWaitSliceMs = 50;

        private Action _s2aPoll;
        private int _s2aPollMs;
        private long _s2aPollTicks, _s2aLastPoll;
        private int _s2aSincePoll;
        private bool _s2aOwned;
        private ManualResetEventSlim _s2aBackendExited;
        private Exception _s2aBackendFailure;
        private S2ACounters _s2aCounters;

        // 上限（S2AConfigureBounds）。_s2aStallTicks == 0 = 没设：等待与原来一样无界、载荷不计
        private int _s2aMaxQueued = S2AQueueCapacity;
        private long _s2aMaxPayload;
        private long _s2aStallTicks, _s2aGraceTicks;
        private Func<long> _s2aStallClock;
        private Action<Exception> _s2aOnStall;
        // 在途载荷字节（贴图 SetData 的数据、环形池放不下改新分配的数组）：生产线程计入，渲染线程开始消费时扣掉
        private long _s2aPayloadInFlight;
        // 只在生产线程上读写：正在组装、还没 QueueCommand 的那条命令已经计入的载荷（渲染线程执行不到它，背压不能等它）
        private long _s2aPayloadUnpublished;
        // 渲染线程前进的心跳：每执行完一条命令、每轮询一次宿主、每处理一次中断（只渲染线程写）；宿主报活（S2ANoteAlive，任意线程）
        private long _s2aRenderBeats, _s2aHostBeats;
        // 渲染线程实际干活的计数：每执行完一条命令（只渲染线程写）。空等轮询不算（见 S2AWorkProgress）
        private long _s2aCommandBeats;
        // 生产侧已发布的命令条数（只生产线程写，S2AProducedCommands）
        private long _s2aProduced;
        // 渲染线程正在执行的命令类型（诊断用；-1 = 不在命令里）
        private int _s2aRunning = -1;
        // 宿主收局开始（S2AShutdownBegun）：卡住判据停用，等待只受宿主自己的停机期限约束（收局释放下层、编译通道 Join 都是合法的长等待）
        private volatile bool _s2aShutdown;
        // 诊断：正在等渲染线程、已等满一片（50 ms）的线程（谁、等什么、从何时起、最近一次醒来查的时刻）。每片醒来更新一次（不到一片的等待不碰），
        // 8 格，满了只计数；收局进度 / 卡住诊断读（S2ADescribe）
        private sealed class S2AWaiterSlot
        {
            public Thread Thread;
            public string What;
            public long Start, Seen;
        }

        private readonly S2AWaiterSlot[] _s2aWaitSlots = [new(), new(), new(), new(), new(), new(), new(), new()];
        private readonly Lock _s2aWaitSlotLock = new();
        private long _s2aWaitSlotOverflow;

        /// <summary>S2A：累计读数（S2ACollectStats 开时记）。宿主取差值出每 60 帧一行；*Max 三项是自上次 resetMax 以来的最大值</summary>
        public struct S2ACounters
        {
            // 同步命令（InvokeCommand）：调用线程入队后等渲染线程执行到它，即整条流水排空；按命令类型拆
            public long InvokeCount, InvokeTicks, InvokeMaxTicks;
            public long ReadbackBuffer, ReadbackTexture, InvokeAction, InvokeProgram, InvokeOther;
            // ThreadedWindow.Present 入队前等上一条出图命令开始执行（模拟线程最多领先一帧的节流）；出图入队时队列里还排着几条命令
            public long FrameWaitCount, FrameWaitTicks, PresentDepthSum, PresentDepthCount;
            public long QueueDepthMax;
            // WaitSync 等同步号在渲染线程上登记
            public long SyncWaitCount, SyncWaitTicks;
            // 渲染线程等活的时长与醒来处理的批数
            public long IdleTicks, Batches;
            // SetBufferData 拷进环形池的字节（Vulkan 没实现上传租约，比单线程多一次拷贝）；环形池放不下改走新分配的次数 / 字节
            public long UploadBytes, UploadSpills, UploadSpillBytes;
            // 背压：条数到上限 / 在途载荷到上限时生产线程等的次数与时长
            public long QueueWaitCount, QueueWaitTicks, PayloadWaitCount, PayloadWaitTicks;
            // 计入在途的载荷字节（贴图 SetData 数据 + 环形池放不下的新分配）与在途峰值
            public long PayloadBytes, PayloadInFlightMax;
        }

        /// <summary>S2A：有界等待的计时状态（每次等待各自一份，值类型不分配）</summary>
        internal struct S2AStallWatch
        {
            // Start = 这次等待开始的时刻（诊断「已等多久」，重新计时不改它）；Since = 卡住判据的计时起点
            public long Beats, Since, GraceUntil, Epoch, Start;
        }

        /// <summary>S2A：GPU 模拟线程调，登记为 IsGpuThread 判据的线程（宿主自己起这条线程）</summary>
        public void S2ABindGpuThread()
        {
            _gpuThread = Thread.CurrentThread;
        }

        /// <summary>
        /// S2A：宿主自起线程模式的上限，在 S2ARunBackend 之前调（之后再改，载荷计入 / 扣除会不对称，直接拒绝）。
        /// maxQueuedCommands：已入队未执行完的命令条数上限（1..S2AQueueCapacity），到上限生产线程等渲染线程执行掉。
        /// maxPayloadBytes：在途载荷字节上限（贴图 SetData 的数据、环形池放不下改新分配的数组；预分配的环形池与命令环不算），
        ///   计入这块会超上限就等；已发布的在途载荷清零后一律放行，所以单块比上限大、或同一条命令的第二块，都不会永远等。
        /// stallMilliseconds / graceMilliseconds：等渲染线程的各处（同步命令、出图节流、条数 / 载荷背压、中断、同步号、排空、收局、
        ///   非 GPU 线程等对象建好 / 等渲染线程锁）计时：stallClock() 是宿主给的生命周期纪元（任意线程可读，不能依赖渲染线程自己更新）：
        ///   ≥ 0 = 前台、可计时，纪元变了 = 中间切过后台；&lt; 0 = 后台（进程可能被冻结），不计时。同一纪元内渲染线程连续 stall 毫秒没有前进
        ///   （执行完一条命令、轮询一次宿主、处理一次中断、宿主报活），再宽限 grace 毫秒仍不前进，就置失败闩（放开其他等待方）、
        ///   调 onStall（宿主失败入口，不阻塞），再抛 TimeoutException。成功语义不变：不返回空结果、不跳过命令。
        /// </summary>
        public void S2AConfigureBounds(int maxQueuedCommands, long maxPayloadBytes, int stallMilliseconds, int graceMilliseconds,
            Func<long> stallClock, Action<Exception> onStall)
        {
            ArgumentOutOfRangeException.ThrowIfLessThan(maxQueuedCommands, 1);
            ArgumentOutOfRangeException.ThrowIfGreaterThan(maxQueuedCommands, S2AQueueCapacity);
            ArgumentOutOfRangeException.ThrowIfLessThan(maxPayloadBytes, 1L);
            ArgumentOutOfRangeException.ThrowIfLessThan(stallMilliseconds, 1);
            ArgumentOutOfRangeException.ThrowIfLessThan(graceMilliseconds, 1);
            ArgumentNullException.ThrowIfNull(stallClock);
            ArgumentNullException.ThrowIfNull(onStall);

            if (_backendThread != null)
            {
                throw new InvalidOperationException("Threaded renderer bounds must be configured before the backend thread starts.");
            }

            _s2aMaxQueued = maxQueuedCommands;
            _s2aMaxPayload = maxPayloadBytes;
            _s2aGraceTicks = Stopwatch.Frequency * graceMilliseconds / 1000;
            _s2aStallClock = stallClock;
            _s2aOnStall = onStall;
            _s2aStallTicks = Stopwatch.Frequency * stallMilliseconds / 1000;
        }

        /// <summary>
        /// S2A：宿主自起线程时，GPU 模拟线程把一段工作交渲染线程同步执行（排在已入队命令之后，即先排空队列）：换页 / 收局 marker、
        /// WSI 退休、释放下层。动作抛错 = 渲染线程失败：失败闩放开本线程并按原异常重抛
        /// </summary>
        public unsafe void S2AOnRenderThread(Action action)
        {
            ArgumentNullException.ThrowIfNull(action);

            if (!_s2aOwned || !IsGpuThread())
            {
                throw new InvalidOperationException("Only the GPU emulation thread of a host-owned threaded renderer may hand work to its render thread.");
            }

            New<ActionCommand>()->Set(Ref(action));
            InvokeCommand();
        }

        /// <summary>S2A：宿主报活：渲染器在宿主的有界等待里泵着（编译通道等驱动调用，自身有期限），任意线程可调</summary>
        public void S2ANoteAlive() => Interlocked.Increment(ref _s2aHostBeats);

        [ThreadStatic] private static S2AStallWatch t_s2aTickWatch;
        [ThreadStatic] private static long t_s2aTickLast, t_s2aTickChecked;

        /// <summary>
        /// S2A：给下层渲染器里「等别的线程推进」的循环每次醒来调（如 Vulkan 计数队列 FlushTo 每 1 ms 一次）：设了上限时查失败闩，
        /// 并按约 50 ms 一片查渲染线程有没有前进，卡住按失败处理（抛异常）；与上次调用隔了 200 ms 以上视为新的一次等待、重新计时。没设上限 = 空操作
        /// </summary>
        public void S2AWaitTick(string what)
        {
            if (!S2ABounded)
            {
                return;
            }

            S2AThrowIfBackendFailed();

            long now = Stopwatch.GetTimestamp();
            long slice = Stopwatch.Frequency * S2AWaitSliceMs / 1000;

            if (now - t_s2aTickLast > 4 * slice)
            {
                t_s2aTickWatch = S2AWatch();
                t_s2aTickChecked = now;
            }

            t_s2aTickLast = now;

            if (now - t_s2aTickChecked < slice)
            {
                return;
            }

            t_s2aTickChecked = now;
            S2ACheckStall(ref t_s2aTickWatch, what);
        }

        /// <summary>S2A：宿主收局开始：之后不再判渲染线程卡住（失败闩照常），收局只受宿主停机期限约束。任意线程可调</summary>
        public void S2AShutdownBegun() => _s2aShutdown = true;

        /// <summary>
        /// S2A：诊断用的一行状态（队列、渲染线程正在执行什么、干活计数、此刻在等渲染线程且已等满 50 ms 的每个线程：等什么、已等多久），
        /// 任意线程可调（收局进度每 250 ms 一次；会分配）
        /// </summary>
        public string S2ADescribe()
        {
            int running = Volatile.Read(ref _s2aRunning);
            long now = Stopwatch.GetTimestamp();
            long fresh = Stopwatch.Frequency * S2AWaitSliceMs * 3 / 1000;
            System.Text.StringBuilder waits = new();

            lock (_s2aWaitSlotLock)
            {
                foreach (S2AWaiterSlot slot in _s2aWaitSlots)
                {
                    if (slot.Thread == null || now - slot.Seen > fresh)
                    {
                        continue;
                    }

                    waits.Append(waits.Length == 0 ? "" : "，")
                        .Append(slot.Thread.Name ?? $"线程 #{slot.Thread.ManagedThreadId}")
                        .Append(" 等").Append(slot.What)
                        .Append(" 已 ").Append((now - slot.Start) * 1000 / Stopwatch.Frequency).Append(" ms");
                }

                if (_s2aWaitSlotOverflow > 0)
                {
                    waits.Append($"（累计 {_s2aWaitSlotOverflow} 次登记没有空格）");
                }
            }

            return $"已入队未执行 {Volatile.Read(ref _commandCount)} 条，渲染线程{(running < 0 ? "不在命令里" : $"正在执行 {(CommandType)running}")}，" +
                $"干活计数 {S2AWorkProgress}；等渲染线程（≥ 50 ms）：{(waits.Length == 0 ? "无" : waits.ToString())}";
        }

        /// <summary>
        /// S2A：宿主进程收局、马上退出时设（只在宿主自起线程模式、GPU 模拟线程退出主循环且 GAL 队列排空之后）：之后 GPU 层释放资源
        /// （缓冲 / 贴图 / 程序 / 采样器 / 数组 / 计数事件）不再排下层释放命令——GPU 层自己的账（写跟踪句柄等）照常释放，下层对象随进程结束回收
        /// </summary>
        public volatile bool S2ADiscardFrees;

        /// <summary>
        /// S2A：设了（宿主进程收局、马上退出）时，收局在渲染线程上执行它代替下层渲染器的 Dispose（宿主在里面做必须的收尾，如补存驱动管线缓存），
        /// 下层设备与对象不逐个销毁。空 = 原样 Dispose
        /// </summary>
        public Action S2AExitRelease;

        /// <summary>S2A：生产侧已发布的命令条数（QueueCommand 每发布一条加一，只由生产线程写）。宿主在同一生产线程上前后两次读数相等 = 中间没有新入队</summary>
        public long S2AProducedCommands => Volatile.Read(ref _s2aProduced);

        /// <summary>S2A：当前在途载荷字节</summary>
        public long S2APayloadInFlight => Interlocked.Read(ref _s2aPayloadInFlight);

        /// <summary>
        /// S2A：渲染侧在干活的计数（执行完一条命令、宿主报活——编译通道等有期限的泵），不含空等轮询。宿主的换页等待用它区分
        /// 「排空慢但在前进」与「没人在干活」：渲染线程空闲时它不动
        /// </summary>
        public long S2AWorkProgress => Volatile.Read(ref _s2aCommandBeats) + Interlocked.Read(ref _s2aHostBeats);

        /// <summary>
        /// S2A：宿主的渲染线程调，登记本线程为渲染线程，started() 之后跑 RenderLoop，直到 GPU 模拟线程收局（Dispose）放倒。
        /// poll：渲染线程上的宿主轮询（WSI 租约等），持 _s2aBaseLock 调（与非 GPU 线程直调下层互斥）：空等 pollMilliseconds 超时一次、
        /// 批末与批内每 64 条命令看一次是否距上次 ≥ pollMilliseconds。poll 或命令抛错：置失败闩、放开等待者，再原样抛给宿主。
        /// </summary>
        public void S2ARunBackend(Action started, Action poll, int pollMilliseconds)
        {
            ArgumentNullException.ThrowIfNull(started);
            ArgumentNullException.ThrowIfNull(poll);
            ArgumentOutOfRangeException.ThrowIfLessThan(pollMilliseconds, 1);

            if (_backendThread != null)
            {
                throw new InvalidOperationException("The threaded renderer already has a backend thread.");
            }

            _backendThread = Thread.CurrentThread;
            _s2aPollMs = pollMilliseconds;
            _s2aPollTicks = Stopwatch.Frequency * pollMilliseconds / 1000;
            _s2aPoll = poll;
            _s2aOwned = true;
            _s2aBackendExited = new ManualResetEventSlim(false);
            _running = true;

            try
            {
                started();
                RenderLoop();
            }
            catch (Exception error)
            {
                S2AFailBackend(error);
                throw;
            }
            finally
            {
                _s2aBackendExited.Set();
            }
        }

        /// <summary>S2A：读累计读数；resetMax = 读后把三个最大值清零（只给一个读者用）</summary>
        public S2ACounters S2AReadCounters(bool resetMax)
        {
            S2ACounters c = default;
            c.InvokeCount = Interlocked.Read(ref _s2aCounters.InvokeCount);
            c.InvokeTicks = Interlocked.Read(ref _s2aCounters.InvokeTicks);
            c.InvokeMaxTicks = resetMax ? Interlocked.Exchange(ref _s2aCounters.InvokeMaxTicks, 0) : Interlocked.Read(ref _s2aCounters.InvokeMaxTicks);
            c.ReadbackBuffer = Interlocked.Read(ref _s2aCounters.ReadbackBuffer);
            c.ReadbackTexture = Interlocked.Read(ref _s2aCounters.ReadbackTexture);
            c.InvokeAction = Interlocked.Read(ref _s2aCounters.InvokeAction);
            c.InvokeProgram = Interlocked.Read(ref _s2aCounters.InvokeProgram);
            c.InvokeOther = Interlocked.Read(ref _s2aCounters.InvokeOther);
            c.FrameWaitCount = Interlocked.Read(ref _s2aCounters.FrameWaitCount);
            c.FrameWaitTicks = Interlocked.Read(ref _s2aCounters.FrameWaitTicks);
            c.PresentDepthSum = Interlocked.Read(ref _s2aCounters.PresentDepthSum);
            c.PresentDepthCount = Interlocked.Read(ref _s2aCounters.PresentDepthCount);
            c.QueueDepthMax = resetMax ? Interlocked.Exchange(ref _s2aCounters.QueueDepthMax, 0) : Interlocked.Read(ref _s2aCounters.QueueDepthMax);
            c.SyncWaitCount = Interlocked.Read(ref _s2aCounters.SyncWaitCount);
            c.SyncWaitTicks = Interlocked.Read(ref _s2aCounters.SyncWaitTicks);
            c.IdleTicks = Interlocked.Read(ref _s2aCounters.IdleTicks);
            c.Batches = Interlocked.Read(ref _s2aCounters.Batches);
            c.UploadBytes = Interlocked.Read(ref _s2aCounters.UploadBytes);
            c.UploadSpills = Interlocked.Read(ref _s2aCounters.UploadSpills);
            c.UploadSpillBytes = Interlocked.Read(ref _s2aCounters.UploadSpillBytes);
            c.QueueWaitCount = Interlocked.Read(ref _s2aCounters.QueueWaitCount);
            c.QueueWaitTicks = Interlocked.Read(ref _s2aCounters.QueueWaitTicks);
            c.PayloadWaitCount = Interlocked.Read(ref _s2aCounters.PayloadWaitCount);
            c.PayloadWaitTicks = Interlocked.Read(ref _s2aCounters.PayloadWaitTicks);
            c.PayloadBytes = Interlocked.Read(ref _s2aCounters.PayloadBytes);
            c.PayloadInFlightMax = resetMax ? Interlocked.Exchange(ref _s2aCounters.PayloadInFlightMax, 0) : Interlocked.Read(ref _s2aCounters.PayloadInFlightMax);

            return c;
        }

        // 先发布失败（先到的为准），再放开等渲染线程的各处（等待方醒来查到失败就按失败闩里的异常重抛）
        private void S2AFailBackend(Exception error)
        {
            Interlocked.CompareExchange(ref _s2aBackendFailure, error, null);
            _invokeRun.Set();
            _frameComplete.Set();
            _interruptRun.Set();
            Sync.S2AAbandon();
            Buffers.S2AAbandon();
        }

        internal void S2AThrowIfBackendFailed()
        {
            Exception failure = Volatile.Read(ref _s2aBackendFailure);

            if (failure != null)
            {
                ExceptionDispatchInfo.Capture(failure).Throw();
            }
        }

        /// <summary>S2A：设了上限（宿主自起线程）：等渲染线程的各处分片等、渲染线程卡住按失败处理</summary>
        internal bool S2ABounded => _s2aStallTicks != 0;

        private long S2ABeats() => Volatile.Read(ref _s2aRenderBeats) + Interlocked.Read(ref _s2aHostBeats);

        // 渲染线程前进一步（只渲染线程调）
        private void S2ABeat() => Volatile.Write(ref _s2aRenderBeats, _s2aRenderBeats + 1);

        internal S2AStallWatch S2AWatch()
        {
            long now = Stopwatch.GetTimestamp();

            return new() { Beats = S2ABeats(), Since = now, Epoch = _s2aStallClock(), Start = now };
        }

        /// <summary>
        /// S2A：一片等待过去还没等到时调。先查失败闩；渲染线程有前进、现在不计时（宿主在后台，Android 可能把整个进程冻结）、
        /// 或生命周期纪元变了（中间切过后台）就重新计时；连续 stall 不前进先宽限一次（解冻后渲染线程要先跑起来），宽限到了仍不前进 → 失败
        /// </summary>
        internal void S2ACheckStall(ref S2AStallWatch watch, string what)
        {
            S2AThrowIfBackendFailed();

            long now = Stopwatch.GetTimestamp();
            long beats = S2ABeats();
            long epoch = _s2aStallClock();

            if (now - watch.Start >= Stopwatch.Frequency * S2AWaitSliceMs / 1000)
            {
                S2ANoteWaiter(watch.Start, what, now);
            }

            if (beats != watch.Beats || epoch < 0 || epoch != watch.Epoch || _s2aShutdown)
            {
                watch = new S2AStallWatch { Beats = beats, Since = now, Epoch = epoch, Start = watch.Start };

                return;
            }

            if (now - watch.Since < _s2aStallTicks)
            {
                return;
            }

            if (watch.GraceUntil == 0)
            {
                watch.GraceUntil = now + _s2aGraceTicks;

                return;
            }

            if (now >= watch.GraceUntil)
            {
                S2AStall(what, now - watch.Since);
            }
        }

        // 登记 / 更新本线程的等待格（每片一次）。本线程已有格子就更新；否则取空格或 4 片没更新的旧格
        private void S2ANoteWaiter(long start, string what, long now)
        {
            Thread self = Thread.CurrentThread;
            long stale = Stopwatch.Frequency * S2AWaitSliceMs * 4 / 1000;

            lock (_s2aWaitSlotLock)
            {
                S2AWaiterSlot free = null;

                foreach (S2AWaiterSlot slot in _s2aWaitSlots)
                {
                    if (slot.Thread == self)
                    {
                        free = slot;
                        break;
                    }

                    if (free == null && (slot.Thread == null || now - slot.Seen > stale))
                    {
                        free = slot;
                    }
                }

                if (free == null)
                {
                    _s2aWaitSlotOverflow++;

                    return;
                }

                free.Thread = self;
                free.What = what;
                free.Start = start;
                free.Seen = now;
            }
        }

        // 渲染线程卡住：置失败闩、交宿主失败入口（不阻塞），本线程按失败闩里先到的异常抛。不写日志（宿主的失败出口统一写一次）
        private void S2AStall(string what, long ticks)
        {
            int running = Volatile.Read(ref _s2aRunning);
            string state = running < 0 ? "不在命令里" : $"正在执行 {(CommandType)running}";
            TimeoutException error = new(
                $"【红】拆线程：渲染线程连续 {ticks * 1000 / Stopwatch.Frequency} ms 没有前进（{Thread.CurrentThread.Name ?? "无名线程"} 在等{what}）；" +
                $"已入队未执行 {Volatile.Read(ref _commandCount)} 条，渲染线程{state}，在途载荷 {Interlocked.Read(ref _s2aPayloadInFlight)} B；" +
                "按失败处理，GPU / 租约对象保留到宿主结束进程");

            S2AFailBackend(error);

            Exception first = Volatile.Read(ref _s2aBackendFailure);
            _s2aOnStall(first);
            ExceptionDispatchInfo.Capture(first).Throw();
        }

        // 已入队条数到上限（环满也算）
        private bool S2AQueueFull() =>
            _producerPtr == (Volatile.Read(ref _consumerPtr) + QueueCount - 1) % QueueCount || Volatile.Read(ref _commandCount) >= _s2aMaxQueued;

        // 生产线程背压：等渲染线程执行掉命令腾出位置（前面的命令都已发布，渲染线程不等本线程，所以总能等到；渲染线程卡住按失败处理）
        private void S2AWaitQueueRoom()
        {
            if (!S2AQueueFull())
            {
                return;
            }

            long start = Stopwatch.GetTimestamp();
            S2AStallWatch watch = S2AWatch();

            do
            {
                Thread.Sleep(1);
                S2ACheckStall(ref watch, "命令队列背压（已入队条数到上限）");
            }
            while (S2AQueueFull());

            if (S2ACollectStats)
            {
                Interlocked.Increment(ref _s2aCounters.QueueWaitCount);
                Interlocked.Add(ref _s2aCounters.QueueWaitTicks, Stopwatch.GetTimestamp() - start);
            }
        }

        // 已发布（渲染线程能执行掉）的在途载荷 > 0，且计入这块会超上限
        private bool S2APayloadOver(long bytes)
        {
            long inFlight = Interlocked.Read(ref _s2aPayloadInFlight);

            return inFlight - _s2aPayloadUnpublished > 0 && inFlight + bytes > _s2aMaxPayload;
        }

        /// <summary>S2A：生产线程计入一块在途载荷（贴图 SetData 数据 / 环形池放不下的新分配），会超上限就先背压等。没设上限 = 不计</summary>
        internal void S2AAdmitPayload(long bytes)
        {
            if (_s2aMaxPayload == 0 || bytes <= 0)
            {
                return;
            }

            if (S2APayloadOver(bytes))
            {
                long start = Stopwatch.GetTimestamp();
                S2AStallWatch watch = S2AWatch();

                do
                {
                    Thread.Sleep(1);
                    S2ACheckStall(ref watch, "在途载荷背压（字节到上限）");
                }
                while (S2APayloadOver(bytes));

                if (S2ACollectStats)
                {
                    Interlocked.Increment(ref _s2aCounters.PayloadWaitCount);
                    Interlocked.Add(ref _s2aCounters.PayloadWaitTicks, Stopwatch.GetTimestamp() - start);
                }
            }

            _s2aPayloadUnpublished += bytes;
            long inFlight = Interlocked.Add(ref _s2aPayloadInFlight, bytes);

            if (S2ACollectStats)
            {
                Interlocked.Add(ref _s2aCounters.PayloadBytes, bytes);
                S2AMax(ref _s2aCounters.PayloadInFlightMax, inFlight);
            }
        }

        /// <summary>S2A：渲染线程开始消费一块计入过的载荷时扣掉（与 S2AAdmitPayload 同条件）</summary>
        internal void S2AReleasePayload(long bytes)
        {
            if (_s2aMaxPayload != 0 && bytes > 0)
            {
                Interlocked.Add(ref _s2aPayloadInFlight, -bytes);
            }
        }

        private static void S2AMax(ref long target, long value)
        {
            long current;

            while (value > (current = Volatile.Read(ref target)) && Interlocked.CompareExchange(ref target, value, current) != current)
            {
            }
        }

        private void S2ANoteInvoke(CommandType type, long ticks)
        {
            Interlocked.Increment(ref _s2aCounters.InvokeCount);
            Interlocked.Add(ref _s2aCounters.InvokeTicks, ticks);
            S2AMax(ref _s2aCounters.InvokeMaxTicks, ticks);

            switch (type)
            {
                case CommandType.BufferGetData:
                    Interlocked.Increment(ref _s2aCounters.ReadbackBuffer);
                    break;
                case CommandType.TextureGetData or CommandType.TextureGetDataSlice:
                    Interlocked.Increment(ref _s2aCounters.ReadbackTexture);
                    break;
                case CommandType.Action:
                    Interlocked.Increment(ref _s2aCounters.InvokeAction);
                    break;
                case CommandType.ProgramCheckLink or CommandType.ProgramGetBinary:
                    Interlocked.Increment(ref _s2aCounters.InvokeProgram);
                    break;
                default:
                    Interlocked.Increment(ref _s2aCounters.InvokeOther);
                    break;
            }
        }

        // 渲染线程等活（S2ARunBackend 模式）：有超时，超时在渲染线程上轮询一次宿主。返回是否有活
        private bool S2AWaitWork()
        {
            long start = S2ACollectStats ? Stopwatch.GetTimestamp() : 0;
            bool work = _galWorkAvailable.Wait(_s2aPollMs);

            if (S2ACollectStats)
            {
                Interlocked.Add(ref _s2aCounters.IdleTicks, Stopwatch.GetTimestamp() - start);

                if (work)
                {
                    Interlocked.Increment(ref _s2aCounters.Batches);
                }
            }

            if (!work)
            {
                lock (_s2aBaseLock)
                {
                    S2APollNow(Stopwatch.GetTimestamp());
                }
            }

            return work;
        }

        // 持 _s2aBaseLock（渲染线程批内）调
        private void S2APollIfDue()
        {
            long now = Stopwatch.GetTimestamp();

            if (now - _s2aLastPoll >= _s2aPollTicks)
            {
                S2APollNow(now);
            }
        }

        private void S2APollNow(long now)
        {
            _s2aLastPoll = now;
            _s2aPoll?.Invoke();
            S2ABeat();
        }

        // 有界地等一个事件（设了上限才分片；没设 = 原样无界）
        private void S2AWait(ManualResetEventSlim signal, string what)
        {
            if (!S2ABounded)
            {
                signal.Wait();

                return;
            }

            S2AStallWatch watch = S2AWatch();

            while (!signal.Wait(S2AWaitSliceMs))
            {
                S2ACheckStall(ref watch, what);
            }
        }

        private void S2AWait(WaitHandle signal, string what)
        {
            if (!S2ABounded)
            {
                signal.WaitOne();

                return;
            }

            S2AStallWatch watch = S2AWatch();

            while (!signal.WaitOne(S2AWaitSliceMs))
            {
                S2ACheckStall(ref watch, what);
            }
        }

        // S2A：宿主自起两条线程时的收局，GPU 模拟线程上经 GpuContext.Dispose → Dispose 调：一条同步命令在渲染线程上释放下层
        // （前面已入队的命令先全部执行完；Vulkan 与 WSI 只在渲染线程上碰，释放后不再轮询宿主），再放倒渲染线程、有界地等它退出 RenderLoop。
        // 不 Join 自己。下层释放抛错 = 渲染线程失败：经失败闩在本线程按原异常重抛（事件不释放，留给进程收尾）。
        private void S2ADisposeOwnedThreads()
        {
            if (!IsGpuThread())
            {
                throw new InvalidOperationException("A host-owned threaded renderer must be disposed on its GPU thread.");
            }

            Action exitRelease = S2AExitRelease;
            S2AOnRenderThread(() =>
            {
                _s2aPoll = null;
                if (exitRelease != null)
                {
                    exitRelease();
                }
                else
                {
                    _baseRenderer.Dispose();
                }
            });

            _running = false;
            _galWorkAvailable.Set();
            S2AWait(_s2aBackendExited, "渲染线程退出（收局）");

            _frameComplete.Dispose();
            _galWorkAvailable.Dispose();
            _invokeRun.Dispose();
            _interruptRun.Dispose();

            Sync.Dispose();
        }

        public bool PreferThreading => _baseRenderer.PreferThreading;

        public ThreadedRenderer(IRenderer renderer)
        {
            _baseRenderer = renderer;

            renderer.ScreenCaptured += (sender, info) => ScreenCaptured?.Invoke(this, info);
            renderer.SetInterruptAction(Interrupt);

            Pipeline = new ThreadedPipeline(this);
            Window = new ThreadedWindow(this, renderer);
            Buffers = new BufferMap(this);
            Sync = new SyncMap(this);
            Programs = new ProgramQueue(renderer);

            // S2A：两个等待事件不自旋（SpinCount 0，直接睡）。.NET 缺省阻塞前先自旋约 35 轮（Thread.Yield / Sleep(0)）：渲染线程每排空一次队列就空转一阵，
            // 10-21 Mac 暗黑3 采样渲染线程忙的时间里 36% 是这段自旋（2163 / 6627 ms）；手机上纯属能耗
            _galWorkAvailable = new ManualResetEventSlim(false, 0);
            _invokeRun = new ManualResetEventSlim(false, 0);
            _interruptRun = new AutoResetEvent(false);
            _spanPool = new CircularSpanPool(this, SpanPoolBytes);
            SpanPool = _spanPool;

            _elementSize = BitUtils.AlignUp(CommandHelper.GetMaxCommandSize(), 4);

            _commandQueue = new byte[_elementSize * QueueCount];
            _refQueue = new object[MaxRefsPerCommand * QueueCount];
        }

        public void RunLoop(ThreadStart gpuLoop)
        {
            _running = true;

            _backendThread = Thread.CurrentThread;

            if (S2AStartThread != null)
            {
                // S2A：线程体里取 Thread.CurrentThread（原生线程挂进运行时后同样有 Thread 对象，IsGpuThread 照用）
                // 原生线程不一定能被 Thread.Join（NativeAOT 外部挂入的线程），Dispose 改等这两个事件
                _s2aGpuDone = new ManualResetEventSlim(false);
                _s2aBackendDone = new ManualResetEventSlim(false);
                using ManualResetEventSlim started = new(false);
                S2AStartThread("GPU.MainThread", () =>
                {
                    _gpuThread = Thread.CurrentThread;
                    started.Set();
                    try
                    {
                        gpuLoop();
                    }
                    finally
                    {
                        _s2aGpuDone.Set();
                    }
                });
                started.Wait();

                try
                {
                    RenderLoop();
                }
                finally
                {
                    _s2aBackendDone.Set();
                }

                return;
            }
            else
            {
                _gpuThread = new Thread(gpuLoop)
                {
                    Name = "GPU.MainThread",
                };

                _gpuThread.Start();
            }

            RenderLoop();
        }

        // S2A：编码线程（本 RenderLoop 所在线程，渲染器 C# 全在这里跑）托管分配按命令类型拆账。S2A_ALLOC_TRACE=1 开，关着只多一次静态布尔判断；
        // 每 20 秒打一次前 20（[分配·编码线程]），按这段时间的上屏命令数折每帧。口径同 GPU 模拟线程的 S2AAllocTrace（Gpu 层，本层引用不到）
        private static readonly bool S2AAllocOn = Environment.GetEnvironmentVariable("S2A_ALLOC_TRACE") == "1";
        private readonly long[] _s2aAllocB = new long[256], _s2aAllocN = new long[256];
        private long _s2aAllocNext;

        private void S2AAllocDump()
        {
            long now = Stopwatch.GetTimestamp();
            if (_s2aAllocNext == 0) { _s2aAllocNext = now + Stopwatch.Frequency * 20; return; }
            if (now < _s2aAllocNext) return;
            _s2aAllocNext = now + Stopwatch.Frequency * 20;
            long frames = _s2aPresents, total = 0;
            _s2aPresents = 0;
            int[] idx = new int[256];
            for (int i = 0; i < 256; i++) { idx[i] = i; total += _s2aAllocB[i]; }
            Array.Sort(idx, (a, b) => _s2aAllocB[b].CompareTo(_s2aAllocB[a]));
            System.Text.StringBuilder sb = new();
            sb.Append($"[分配·编码线程] 近 20 秒 上屏 {frames} 次：合计 {total} B（每帧 {(frames > 0 ? total / frames : total)} B）");
            for (int k = 0; k < 20 && _s2aAllocB[idx[k]] > 0; k++)
            {
                int t = idx[k];
                sb.Append($"；{(CommandType)t} {_s2aAllocB[t]} B / {_s2aAllocN[t]} 次");
            }
            Console.Error.WriteLine(sb.ToString());
            Array.Clear(_s2aAllocB);
            Array.Clear(_s2aAllocN);
        }

        private long _s2aPresents;

        public void RenderLoop()
        {
            // Power through the render queue until the Gpu thread work is done.

            while (_running)
            {
                Ryujinx.Common.S2AThreadAlloc.Tick("渲染·编码"); // S2Arm: per-thread allocation accounting (Metal encoding thread, S2A.GPU)
                if (_s2aPoll == null)
                {
                    _galWorkAvailable.Wait();
                }
                else if (!S2AWaitWork())
                {
                    continue; // S2A：空等超时，S2AWaitWork 已在渲染线程上轮询过宿主
                }
                _galWorkAvailable.Reset();

                // S2A：一批命令持一次锁，命令之间有线程在等就让出（见 _s2aBaseLock、S2AEnterBase）
                lock (_s2aBaseLock)
                {
                    if (Volatile.Read(ref _interruptAction) != null)
                    {
                        _interruptAction();
                        _interruptRun.Set();

                        Interlocked.Exchange(ref _interruptAction, null);

                        if (_s2aOwned)
                        {
                            S2ABeat();
                        }
                    }

                    // The other thread can only increase the command count.
                    // We can assume that if it is above 0, it will stay there or get higher.

                    while (Volatile.Read(ref _commandCount) > 0 && Volatile.Read(ref _interruptAction) == null)
                    {
                        int commandPtr = _consumerPtr;

                        Span<byte> command = new(_commandQueue, commandPtr * _elementSize, _elementSize);

                        // Run the command.

                        if (_s2aOwned)
                        {
                            Volatile.Write(ref _s2aRunning, command[^1]); // S2A：诊断用，卡住时报正在执行哪类命令
                        }

                        if (S2AAllocOn)
                        {
                            int s2aType = command[^1];
                            long s2aA = GC.GetAllocatedBytesForCurrentThread();
                            CommandHelper.RunCommand(command, this, _baseRenderer);
                            long s2aD = GC.GetAllocatedBytesForCurrentThread() - s2aA;
                            if (s2aD > 0) { _s2aAllocB[s2aType] += s2aD; _s2aAllocN[s2aType]++; }
                            if (s2aType == (int)CommandType.WindowPresent) _s2aPresents++;
                            S2AAllocDump();
                        }
                        else
                        {
                            CommandHelper.RunCommand(command, this, _baseRenderer);
                        }

                        if (_s2aOwned)
                        {
                            Volatile.Write(ref _s2aRunning, -1);
                            S2ABeat();
                            Volatile.Write(ref _s2aCommandBeats, _s2aCommandBeats + 1);
                        }

                        if (Interlocked.CompareExchange(ref _invokePtr, -1, commandPtr) == commandPtr)
                        {
                            _invokeRun.Set();
                        }

                        _consumerPtr = (_consumerPtr + 1) % QueueCount;

                        Interlocked.Decrement(ref _commandCount);

                        if (Volatile.Read(ref _s2aWaiters) != 0)
                        {
                            S2AYieldBase();
                        }

                        // S2A：模拟线程持续供活时内层循环可以一直不退出，批内也要按时轮询宿主（每 64 条看一次钟）
                        if (_s2aPoll != null && (++_s2aSincePoll & 63) == 0)
                        {
                            S2APollIfDue();
                        }
                    }

                    if (_s2aPoll != null)
                    {
                        S2APollIfDue();
                    }
                }
            }
        }

        internal SpanRef<T> CopySpan<T>(ReadOnlySpan<T> data) where T : unmanaged
        {
            return _spanPool.Insert(data);
        }

        private TableRef<T> Ref<T>(T reference)
        {
            return new TableRef<T>(this, reference);
        }

        internal unsafe T* New<T>() where T : unmanaged, IGALCommand
        {
            if (S2ABounded)
            {
                S2AWaitQueueRoom(); // S2A：环满或已入队条数到宿主上限都背压等，有界
            }
            else
            {
                while (_producerPtr == (Volatile.Read(ref _consumerPtr) + QueueCount - 1) % QueueCount)
                {
                    // If incrementing the producer pointer would overflow, we need to wait.
                    // _consumerPtr can only move forward, so there's no race to worry about here.

                    S2AThrowIfBackendFailed(); // S2A：渲染线程已失败退出，队列不会再前进
                    Thread.Sleep(1);
                }
            }

            int taken = _producerPtr;
            _lastProducedPtr = taken;

            _producerPtr = (_producerPtr + 1) % QueueCount;

            Span<byte> memory = new(_commandQueue, taken * _elementSize, _elementSize);
            T* result = (T*)Unsafe.AsPointer(ref memory.GetPinnableReference());
            // ref T result = ref Unsafe.As<byte, T>(ref MemoryMarshal.GetReference(memory));

            memory[^1] = (byte)(result)->CommandType;

            return result;
        }

        internal int AddTableRef(object obj)
        {
            // The reference table is sized so that it will never overflow, so long as the references are taken after the command is allocated.

            // make sure increment is thread safe
            int index = Interlocked.Increment(ref _refProducerPtr) - 1;
            
            index %= _refQueue.Length;

            _refQueue[index] = obj;

            _refProducerPtr %= _refQueue.Length;

            return index;
        }

        internal object RemoveTableRef(int index)
        {
            Debug.Assert(index == _refConsumerPtr);

            object result = _refQueue[_refConsumerPtr];
            _refQueue[_refConsumerPtr] = null;

            _refConsumerPtr = (_refConsumerPtr + 1) % _refQueue.Length;

            return result;
        }

        internal void QueueCommand()
        {
            _s2aPayloadUnpublished = 0; // S2A：本条命令发布了，它计入的载荷渲染线程能消费掉
            Volatile.Write(ref _s2aProduced, _s2aProduced + 1);
            int result = Interlocked.Increment(ref _commandCount);

            if (S2ACollectStats)
            {
                S2AMax(ref _s2aCounters.QueueDepthMax, result);
            }

            if (result == 1)
            {
                _galWorkAvailable.Set();
            }
        }

        internal void InvokeCommand()
        {
            long s2aStart = S2ACollectStats ? Stopwatch.GetTimestamp() : 0;
            CommandType s2aType = S2ACollectStats ? (CommandType)_commandQueue[_lastProducedPtr * _elementSize + _elementSize - 1] : default;

            _invokeRun.Reset();
            _invokePtr = _lastProducedPtr;

            QueueCommand();

            // Wait for the command to complete.
            // S2A：Reset 之后查失败闩（渲染线程先发布失败再 Set，Set 若早于本次 Reset，这里一定看得到失败）；设了上限就有界
            S2AThrowIfBackendFailed();
            S2AWait(_invokeRun, "同步命令（入队后等渲染线程执行到它）");
            S2AThrowIfBackendFailed();

            if (S2ACollectStats)
            {
                S2ANoteInvoke(s2aType, Stopwatch.GetTimestamp() - s2aStart);
            }
        }

        internal void WaitForFrame()
        {
            long s2aStart = S2ACollectStats ? Stopwatch.GetTimestamp() : 0;

            S2AThrowIfBackendFailed();
            S2AWait(_frameComplete, "出图节流（上一条出图命令还没开始执行）");
            S2AThrowIfBackendFailed();

            if (S2ACollectStats)
            {
                Interlocked.Increment(ref _s2aCounters.FrameWaitCount);
                Interlocked.Add(ref _s2aCounters.FrameWaitTicks, Stopwatch.GetTimestamp() - s2aStart);
                Interlocked.Add(ref _s2aCounters.PresentDepthSum, Volatile.Read(ref _commandCount));
                Interlocked.Increment(ref _s2aCounters.PresentDepthCount);
            }
        }

        internal void SignalFrame()
        {
            _frameComplete.Set();
        }

        internal bool IsGpuThread()
        {
            return Thread.CurrentThread == _gpuThread;
        }

        public unsafe void BackgroundContextAction(Action action, bool alwaysBackground = false)
        {
            if (IsGpuThread() && !alwaysBackground)
            {
                if (_s2aOwned)
                {
                    // S2A（宿主自起线程，Vulkan）：GPU 层的后台动作（TextureGroup 回写等）就在 GPU 模拟线程上执行——Vulkan 没有 GL 那种上下文线程绑定，
                    // 单线程时它本来就在这条线程上跑；动作里对 Threaded* 的读回照常排队成同步命令。这样渲染线程不进 GPU 层锁、不写 guest 内存、
                    // 不进写跟踪原生层（等待图里没有「渲染线程 → GPU 层 / 写跟踪」这条边）。宿主要在渲染线程上执行的工作走 S2AOnRenderThread
                    action();

                    return;
                }

                // The action must be performed on the render thread.
                New<ActionCommand>()->Set(Ref(action));
                InvokeCommand();
            }
            else
            {
                // S2A：动作本身不持锁（里面经本层对象调下层，各自在等到对象建好后持锁）
                Interlocked.Increment(ref S2AOffThreadCalls);
                _baseRenderer.BackgroundContextAction(action, true);
            }
        }

        public unsafe BufferHandle CreateBuffer(int size, BufferAccess access)
        {
            BufferHandle handle = Buffers.CreateBufferHandle();
            New<CreateBufferAccessCommand>()->Set(handle, size, access);
            QueueCommand();

            return handle;
        }

        public unsafe BufferHandle CreateBuffer(nint pointer, int size)
        {
            BufferHandle handle = Buffers.CreateBufferHandle();
            New<CreateHostBufferCommand>()->Set(handle, pointer, size);
            QueueCommand();

            return handle;
        }

        public unsafe BufferHandle CreateBufferSparse(ReadOnlySpan<BufferRange> storageBuffers)
        {
            BufferHandle handle = Buffers.CreateBufferHandle();
            New<CreateBufferSparseCommand>()->Set(handle, CopySpan(storageBuffers));
            QueueCommand();

            return handle;
        }

        public unsafe IImageArray CreateImageArray(int size, bool isBuffer)
        {
            ThreadedImageArray imageArray = new(this);
            New<CreateImageArrayCommand>()->Set(Ref(imageArray), size, isBuffer);
            QueueCommand();

            return imageArray;
        }

        public unsafe IProgram CreateProgram(ShaderSource[] shaders, ShaderInfo info)
        {
            ThreadedProgram program = new(this);

            SourceProgramRequest request = new(program, shaders, info);

            Programs.Add(request);

            ProgramCount++;

            New<CreateProgramCommand>()->Set(Ref((IProgramRequest)request));
            QueueCommand();

            return program;
        }

        public unsafe ISampler CreateSampler(SamplerCreateInfo info)
        {
            ThreadedSampler sampler = new(this);
            New<CreateSamplerCommand>()->Set(Ref(sampler), info);
            QueueCommand();

            return sampler;
        }

        public unsafe void CreateSync(ulong id, bool strict)
        {
            Sync.CreateSyncHandle(id);
            New<CreateSyncCommand>()->Set(id, strict);
            QueueCommand();
        }

        public ITexture CreateTexture(TextureCreateInfo info) => CreateTexture(info, 1f);

        public unsafe ITexture CreateTexture(TextureCreateInfo info, float resolutionScale)
        {
            if (IsGpuThread())
            {
                ThreadedTexture texture = new(this, info);
                New<CreateTextureCommand>()->Set(Ref(texture), info, resolutionScale);
                QueueCommand();

                return texture;
            }
            else
            {
                ThreadedTexture texture = new(this, info);
                Interlocked.Increment(ref S2AOffThreadCalls);

                // S2A：持锁建（宽屏包装层建贴图时登记放宽表，与渲染线程同一份状态）
                S2AEnterBase();

                try
                {
                    texture.Base = _baseRenderer.CreateTexture(info, resolutionScale);
                }
                finally
                {
                    S2AExitBase();
                }

                return texture;
            }
        }
        public unsafe ITextureArray CreateTextureArray(int size, bool isBuffer)
        {
            ThreadedTextureArray textureArray = new(this);
            New<CreateTextureArrayCommand>()->Set(Ref(textureArray), size, isBuffer);
            QueueCommand();

            return textureArray;
        }

        public unsafe void DeleteBuffer(BufferHandle buffer)
        {
            if (S2ADiscardFrees)
            {
                return; // S2A：进程即将退出，下层缓冲不逐个释放
            }

            New<BufferDisposeCommand>()->Set(buffer);
            QueueCommand();
        }

        public unsafe PinnedSpan<byte> GetBufferData(BufferHandle buffer, int offset, int size)
        {
            if (IsGpuThread())
            {
                ResultBox<PinnedSpan<byte>> box = new();
                New<BufferGetDataCommand>()->Set(buffer, offset, size, Ref(box));
                InvokeCommand();

                return box.Result;
            }
            else
            {
                // S2A：先等缓冲在渲染线程上建好（锁外），再持锁读
                BufferHandle mapped = Buffers.MapBufferBlocking(buffer);
                Interlocked.Increment(ref S2AOffThreadCalls);

                S2AEnterBase();

                try
                {
                    return _baseRenderer.GetBufferData(mapped, offset, size);
                }
                finally
                {
                    S2AExitBase();
                }
            }
        }

        public unsafe Capabilities GetCapabilities()
        {
            ResultBox<Capabilities> box = new();
            New<GetCapabilitiesCommand>()->Set(Ref(box));
            InvokeCommand();

            return box.Result;
        }

        public ulong GetCurrentSync()
        {
            return _baseRenderer.GetCurrentSync();
        }

        public HardwareInfo GetHardwareInfo()
        {
            return _baseRenderer.GetHardwareInfo();
        }

        /// <summary>
        /// Initialize the base renderer. Must be called on the render thread.
        /// </summary>
        /// <param name="logLevel">Log level to use</param>
        public void Initialize(GraphicsDebugLevel logLevel)
        {
            _baseRenderer.Initialize(logLevel);
        }

        /// <summary>
        /// S2A（10-24）：不等渲染线程取链接结果。多线程渲染器的程序取渲染线程已得出的结果（还没得出 = Incomplete），不发命令；
        /// 别的程序直接非阻塞查。CheckProgramLink 哪怕非阻塞也是 InvokeCommand、要等渲染线程排空——渲染线程正等一支现编时，GPU 模拟线程就被拖住
        /// （10-24 测试机1 xc3 冷局第 703 帧停 12 秒：按需实化同步查链接，GPU 模拟线程等渲染线程、渲染线程等现编，编译串成一支一支）
        /// </summary>
        public static ProgramLinkStatus S2ALinkStatusNoWait(IProgram program)
        {
            if (program is ThreadedProgram threaded)
            {
                int s = threaded.S2AStatus;
                return s < 0 ? ProgramLinkStatus.Incomplete : (ProgramLinkStatus)s;
            }

            return program.CheckProgramLink(false);
        }

        /// <summary>S2A：程序编完后要取二进制（存磁盘缓存）：多线程渲染器的程序让渲染线程在得出链接结果时顺手取好（见 S2ABinary）</summary>
        public static void S2AWantBinary(IProgram program)
        {
            if (program is ThreadedProgram threaded)
            {
                threaded.S2AWantBinary = true;
            }
        }

        /// <summary>
        /// S2A：取已链接成功的程序的二进制。渲染线程已顺手取好就直接用、不发命令；否则照常 GetBinary（多线程渲染器里是 InvokeCommand，
        /// 只剩入队前就已编完的少数情况会走到）
        /// </summary>
        public static byte[] S2ABinary(IProgram program)
        {
            if (program is ThreadedProgram threaded && threaded.S2AStatus >= 0 && threaded.S2ABinary != null)
            {
                return threaded.S2ABinary;
            }

            return program.GetBinary();
        }

        public unsafe IProgram LoadProgramBinary(byte[] programBinary, bool hasFragmentShader, ShaderInfo info)
        {
            ThreadedProgram program = new(this);

            BinaryProgramRequest request = new(program, programBinary, hasFragmentShader, info);
            Programs.Add(request);

            New<CreateProgramCommand>()->Set(Ref((IProgramRequest)request));
            QueueCommand();

            return program;
        }

        public unsafe void PreFrame()
        {
            New<PreFrameCommand>();
            QueueCommand();
        }

        // S2Arm: counter event pool (see ThreadedCounterEvent): an event goes back once its result was forwarded and its dispose command ran,
        // whichever comes last (result on the backend or GPU emulation thread, dispose on the backend thread)
        private readonly Stack<ThreadedCounterEvent> _s2aCounterPool = new();

        internal void S2ACounterHandled(ThreadedCounterEvent evt)
        {
            lock (_s2aCounterPool)
            {
                evt.S2AHandled = true;

                if (evt.S2ADropped)
                {
                    _s2aCounterPool.Push(evt);
                }
            }
        }

        internal void S2ACounterDropped(ThreadedCounterEvent evt)
        {
            lock (_s2aCounterPool)
            {
                evt.S2ADropped = true;

                if (evt.S2AHandled)
                {
                    _s2aCounterPool.Push(evt);
                }
            }
        }

        public unsafe ICounterEvent ReportCounter(CounterType type, EventHandler<ulong> resultHandler, float divisor, bool hostReserved)
        {
            ThreadedCounterEvent evt;

            lock (_s2aCounterPool)
            {
                evt = _s2aCounterPool.Count != 0 ? _s2aCounterPool.Pop() : new ThreadedCounterEvent(this, type, _lastSampleCounterClear);
            }

            evt.S2AReuse(type, _lastSampleCounterClear, resultHandler);
            New<ReportCounterCommand>()->Set(Ref(evt), type, Ref(resultHandler), divisor, hostReserved);
            QueueCommand();

            if (type == CounterType.SamplesPassed)
            {
                _lastSampleCounterClear = false;
            }

            return evt;
        }

        public unsafe void ResetCounter(CounterType type)
        {
            New<ResetCounterCommand>()->Set(type);
            QueueCommand();
            _lastSampleCounterClear = true;
        }

        public void Screenshot()
        {
            _baseRenderer.Screenshot();
        }

        public unsafe void SetBufferData(BufferHandle buffer, int offset, ReadOnlySpan<byte> data)
        {
            if (S2ACollectStats)
            {
                Interlocked.Add(ref _s2aCounters.UploadBytes, data.Length);
            }

            // S2A（帧率能耗线 10-22，方案 B）：环形池（8 MB）放不下时原版走 ToArray 新分配（巫师3 换场景缓冲首次上传几十 MB），改租渲染器上传内存拷进去
            if (!_spanPool.S2ATryInsert(data, out SpanRef<byte> spanRef))
            {
                if (_baseRenderer.S2ATryRentUpload(data.Length, out S2AUploadLease lease))
                {
                    data.CopyTo(lease.Span);
                    New<BufferS2ASetDataCommand>()->Set(buffer, offset, lease);
                    QueueCommand();
                    return;
                }

                if (S2ACollectStats)
                {
                    Interlocked.Increment(ref _s2aCounters.UploadSpills);
                    Interlocked.Add(ref _s2aCounters.UploadSpillBytes, data.Length);
                }

                spanRef = CopySpan(data);
            }

            New<BufferSetDataCommand>()->Set(buffer, offset, spanRef);
            QueueCommand();
        }

        /// <summary>S2A：租约直接向底层渲染器租（原生，线程安全），不排队</summary>
        public bool S2ATryRentUpload(int size, out S2AUploadLease lease) => _baseRenderer.S2ATryRentUpload(size, out lease);

        /// <summary>S2A：退租直接交底层</summary>
        public void S2ADropUpload(S2AUploadLease lease) => _baseRenderer.S2ADropUpload(lease);

        /// <summary>S2A：租约数据写缓冲，按命令顺序排队</summary>
        public unsafe void S2ASetBufferData(BufferHandle buffer, int offset, S2AUploadLease lease)
        {
            New<BufferS2ASetDataCommand>()->Set(buffer, offset, lease);
            QueueCommand();
        }

        public unsafe void UpdateCounters()
        {
            New<UpdateCountersCommand>();
            QueueCommand();
        }

        public void WaitSync(ulong id)
        {
            long s2aStart = S2ACollectStats ? Stopwatch.GetTimestamp() : 0;

            Sync.WaitSyncAvailability(id);
            S2AThrowIfBackendFailed(); // S2A：渲染线程失败时 SyncMap 放开等待，同步号并未登记

            if (S2ACollectStats)
            {
                Interlocked.Increment(ref _s2aCounters.SyncWaitCount);
                Interlocked.Add(ref _s2aCounters.SyncWaitTicks, Stopwatch.GetTimestamp() - s2aStart);
            }

            _baseRenderer.WaitSync(id);
        }

        private void Interrupt(Action action)
        {
            // Interrupt the backend thread from any external thread and invoke the given action.

            if (Thread.CurrentThread == _backendThread)
            {
                // If this is called from the backend thread, the action can run immediately.
                action();
            }
            else
            {
                lock (_interruptLock)
                {
                    while (Interlocked.CompareExchange(ref _interruptAction, action, null) != null)
                    {
                        S2AThrowIfBackendFailed(); // S2A：渲染线程已失败退出，上一个中断动作永远不会被取走
                    }

                    _galWorkAvailable.Set();

                    S2AThrowIfBackendFailed();
                    S2AWait(_interruptRun, "中断（渲染线程在命令间隙执行插入的动作）");
                    S2AThrowIfBackendFailed();
                }
            }
        }

        public void SetInterruptAction(Action<Action> interruptAction)
        {
            // Threaded renderer ignores given interrupt action, as it provides its own to the child renderer.
        }

        public bool PrepareHostMapping(nint address, ulong size)
        {
            return _baseRenderer.PrepareHostMapping(address, size);
        }

        public void FlushThreadedCommands()
        {
            SpinWait wait = new();
            bool s2aBounded = S2ABounded;
            S2AStallWatch s2aWatch = s2aBounded ? S2AWatch() : default;
            long s2aNext = s2aBounded ? Stopwatch.GetTimestamp() + Stopwatch.Frequency * S2AWaitSliceMs / 1000 : 0;

            while (Volatile.Read(ref _commandCount) > 0)
            {
                S2AThrowIfBackendFailed(); // S2A：渲染线程已失败退出，计数不会再降
                wait.SpinOnce();

                // S2A：设了上限就每片查一次渲染线程有没有前进
                if (s2aBounded && Stopwatch.GetTimestamp() >= s2aNext)
                {
                    S2ACheckStall(ref s2aWatch, "排空命令队列");
                    s2aNext = Stopwatch.GetTimestamp() + Stopwatch.Frequency * S2AWaitSliceMs / 1000;
                }
            }
        }

        // Only after the GPU producer joined. Run outstanding compiler work on
        // the encoder, so pending cache saves can finish before their owners die.
        public unsafe void S2AAdvanceProgramsForShutdown(int timeoutMilliseconds)
        {
            long end = Environment.TickCount64 + timeoutMilliseconds;
            S2ADrainForShutdown(timeoutMilliseconds);
            New<ActionCommand>()->Set(Ref<Action>(Programs.ProcessQueue));
            QueueCommand();
            S2ADrainForShutdown((int)Math.Max(0, end - Environment.TickCount64));
        }

        /// <summary>Drain queued destruction while the encoder still owns all resources.</summary>
        public void S2ADrainForShutdown(int timeoutMilliseconds)
        {
            long end = Environment.TickCount64 + timeoutMilliseconds;
            SpinWait wait = new();
            while (Volatile.Read(ref _commandCount) != 0)
            {
                if (!Volatile.Read(ref _running)) throw new InvalidOperationException("编码线程已停，仍有资源释放命令未执行");
                if (Environment.TickCount64 >= end) throw new TimeoutException("图形资源释放命令未排空；旧渲染器不能释放");
                wait.SpinOnce();
            }
        }

        public void Dispose()
        {
            GC.SuppressFinalize(this);

            if (_s2aBackendExited != null)
            {
                S2ADisposeOwnedThreads();

                return;
            }

            // Dispose must happen from the render thread, after all commands have completed.

            // Stop the GPU thread.
            _running = false;
            _galWorkAvailable.Set();

            if (_s2aBackendDone != null)
            {
                // S2A：线程由 S2AStartThread 原生起，等线程体结束的事件而不是 Join
                _s2aGpuDone.Wait();
                _s2aBackendDone.Wait();
            }
            else
            {
                if (_gpuThread is { IsAlive: true })
                {
                    _gpuThread.Join();
                }

                if (_backendThread is { IsAlive: true })
                {
                    _backendThread.Join();
                }
            }

            // Dispose the renderer.
            _baseRenderer.Dispose();

            // Dispose events.
            _frameComplete.Dispose();
            _galWorkAvailable.Dispose();
            _invokeRun.Dispose();
            _interruptRun.Dispose();
            _s2aGpuDone?.Dispose();
            _s2aBackendDone?.Dispose();

            Sync.Dispose();
        }
    }
}
