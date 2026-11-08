using Ryujinx.Common;
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.Device;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu.Engine.GPFifo;
using Ryujinx.Graphics.Gpu.Memory;
using Ryujinx.Graphics.Gpu.Shader;
using Ryujinx.Graphics.Gpu.Synchronization;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Threading;

namespace Ryujinx.Graphics.Gpu
{
    /// <summary>
    /// GPU emulation context.
    /// </summary>
    public sealed class GpuContext : IDisposable
    {
        public static bool S2ABufferReadScratchEnabled => S2ABufferReadScratch.Enabled;
        private const int NsToTicksFractionNumerator = 384;
        private const int NsToTicksFractionDenominator = 625;

        /// <summary>
        /// Event signaled when the host emulation context is ready to be used by the gpu context.
        /// </summary>
        public ManualResetEvent HostInitalized { get; }

        /// <summary>
        /// Host renderer.
        /// </summary>
        public IRenderer Renderer { get; }
        /// <summary>Host drains queued destruction and joins its encoder before renderer disposal.</summary>
        public Action S2ABeforeRendererDispose { get; set; }

        /// <summary>
        /// 平台可选的正常上下文读取：只向租出的目标复制 guest 字节，不回写、不解除源页保护。
        /// 仅由本 GPU owner 同步消费；调用期间不能处理替页控制请求。未安装的平台沿用原 span。
        /// </summary>
        public Action<ulong, Memory<byte>> S2AReadGuestMemory { get; set; }

        /// <summary>
        /// GPU General Purpose FIFO queue.
        /// </summary>
        public GPFifoDevice GPFifo { get; }

        /// <summary>
        /// GPU synchronization manager.
        /// </summary>
        public SynchronizationManager Synchronization { get; }

        /// <summary>
        /// Presentation window.
        /// </summary>
        public Window Window { get; }

        /// <summary>
        /// Internal sequence number, used to avoid needless resource data updates
        /// in the middle of a command buffer before synchronizations.
        /// </summary>
        internal int SequenceNumber { get; private set; }

        /// <summary>
        /// Internal sync number, used to denote points at which host synchronization can be requested.
        /// </summary>
        internal ulong SyncNumber { get; private set; }

        // S2A（帧率能耗线 10-22，暗黑3 加载转换崩溃）：同步点推进等主机同步做完（= GPU 真做完到这里）再让游戏看到。
        // 原版在 GPU 线程处理到 SyncpointbOperation.Incr 时就推进同步点值，GPU 还没做完；游戏线程等到同步点就去读 GPU 产出，
        // 出图改 CPU 等待（1b157788b）后 GPU 线程跑得更靠前，提前量变大，暗黑3 diff→load 偶发查表 miss 崩（原生层线 A/B：GPUWAIT=1 6/6 不崩，cpuwait 8 局 2 崩）。
        // 做法：推进时强制建严格主机同步号 N，把（同步点，N）按序交给专门线程：WaitSync(N)（CPU 侧等，不占 GPU 渲染通道）后再推进。
        // 缺省关（照上游立即推进）：S2A_SYNCPT_HOSTSYNC=1 整体打开（同时打开 GAL 严格同步号当场提交，gal_core.m sync_strict_commit），单变量 A/B 证明后再翻缺省（总指挥 10-22）
        internal static readonly bool S2ASyncptImmediate = Environment.GetEnvironmentVariable("S2A_SYNCPT_HOSTSYNC") != "1";
        private readonly System.Collections.Concurrent.BlockingCollection<(uint Id, ulong Sync)> _s2aSyncpt = new(new System.Collections.Concurrent.ConcurrentQueue<(uint, ulong)>());
        private Thread _s2aSyncptThread;

        /// <summary>
        /// 推进同步点：S2ASyncptImmediate 时当场推进；否则等刚建的主机同步号（SyncNumber - 1）做完再推进（调用前须以 Force 建过主机同步）
        /// </summary>
        internal void S2AIncrementSyncpointAfterHostSync(uint syncpointId)
        {
            if (S2ASyncptImmediate)
            {
                S2AGameSync.Record(syncpointId, Synchronization.IncrementSyncpoint(syncpointId), SyncNumber - 1);
                return;
            }

            if (_s2aSyncptThread == null)
            {
                _s2aSyncptThread = new Thread(S2ASyncptLoop) { Name = "S2A.Syncpt", IsBackground = true };
                _s2aSyncptThread.Start();
            }

            _s2aSyncpt.Add((syncpointId, SyncNumber - 1));
        }

        private void S2ASyncptLoop()
        {
            foreach ((uint id, ulong sync) in _s2aSyncpt.GetConsumingEnumerable())
            {
                Renderer.WaitSync(sync);
                S2AGameSync.Record(id, Synchronization.IncrementSyncpoint(id), sync);
            }
        }

        /// <summary>
        /// Actions to be performed when a CPU waiting syncpoint or barrier is triggered.
        /// If there are more than 0 items when this happens, a host sync object will be generated for the given <see cref="SyncNumber"/>,
        /// and the SyncNumber will be incremented.
        /// </summary>
        internal List<ISyncActionHandler> SyncActions { get; }

        /// <summary>
        /// Actions to be performed when a CPU waiting syncpoint is triggered.
        /// If there are more than 0 items when this happens, a host sync object will be generated for the given <see cref="SyncNumber"/>,
        /// and the SyncNumber will be incremented.
        /// </summary>
        internal List<ISyncActionHandler> SyncpointActions { get; }

        /// <summary>
        /// Buffer migrations that are currently in-flight. These are checked whenever sync is created to determine if buffer migration
        /// copies have completed on the GPU, and their data can be freed.
        /// </summary>
        internal List<BufferMigration> BufferMigrations { get; }

        /// <summary>
        /// Queue with deferred actions that must run on the render thread.
        /// </summary>
        internal Queue<Action> DeferredActions { get; }

        /// <summary>
        /// Registry with physical memories that can be used with this GPU context, keyed by owner process ID.
        /// </summary>
        internal ConcurrentDictionary<ulong, PhysicalMemory> PhysicalMemoryRegistry { get; }

        // S2A：注册表的数组快照（注册 / 注销 / 清空时重建）。每帧的 ProcessShaderCacheQueue 原本 foreach ConcurrentDictionary.Values，
        // 每次新建一份快照集合（动森渲染线程每帧约 170 B）；整体换引用，GPU 线程读不加锁
        private volatile PhysicalMemory[] _s2aPhysSnap = [];
        private void S2ARefreshPhysSnap() => _s2aPhysSnap = [.. PhysicalMemoryRegistry.Values];

        /// <summary>
        /// Support buffer updater.
        /// </summary>
        internal SupportBufferUpdater SupportBufferUpdater { get; }

        /// <summary>
        /// Enabled dirty hacks.
        /// Used for workarounds to emulator bugs we can't fix/don't know how to fix yet.
        /// </summary>
        internal DirtyHacks DirtyHacks { get; }


        /// <summary>
        /// Host hardware capabilities.
        /// </summary>
        internal Capabilities Capabilities;

        /// <summary>
        /// S2A offline producer override for the host program cache discriminator. The engine
        /// normally asks the renderer policy; ShBake has no renderer object but must write the
        /// exact same host file name the device will read. Null keeps the engine behavior.
        /// </summary>
        internal string S2AHostProgramCacheDiscriminator;

        /// <summary>
        /// Event for signalling shader cache loading progress.
        /// </summary>
        public event Action<ShaderCacheState, int, int> ShaderCacheStateChanged;

        private Thread _gpuThread;
        private bool _pendingSync;

        private long _modifiedSequence;
        private readonly ulong _firstTimestamp;

        private readonly ManualResetEvent _gpuReadyEvent;

        /// <summary>
        /// Creates a new instance of the GPU emulation context.
        /// </summary>
        /// <param name="renderer">Host renderer</param>
        public GpuContext(IRenderer renderer, DirtyHacks hacks)
        {
            Renderer = renderer;

            GPFifo = new GPFifoDevice(this);

            Synchronization = new SynchronizationManager();

            Window = new Window(this);

            HostInitalized = new ManualResetEvent(false);
            _gpuReadyEvent = new ManualResetEvent(false);

            SyncActions = [];
            SyncpointActions = [];
            BufferMigrations = [];

            DeferredActions = new Queue<Action>();

            PhysicalMemoryRegistry = new ConcurrentDictionary<ulong, PhysicalMemory>();

            SupportBufferUpdater = new SupportBufferUpdater(renderer);

            DirtyHacks = hacks;

            _firstTimestamp = ConvertNanosecondsToTicks((ulong)PerformanceCounter.ElapsedNanoseconds);
            _s2aTsBarrierHandler = S2ATsBarrierResult;

            if (S2AGpuTs)
            {
                GraphicsConfig.FastGpuTime = false;   // 时间戳要真实：不再除 256
            }
        }

        /// <summary>
        /// Creates a new GPU channel.
        /// </summary>
        /// <returns>The GPU channel</returns>
        public GpuChannel CreateChannel()
        {
            return new GpuChannel(this);
        }

        /// <summary>
        /// Creates a new GPU memory manager.
        /// </summary>
        /// <param name="pid">ID of the process that owns the memory manager</param>
        /// <param name="cpuMemorySize">The amount of physical CPU Memory Avaiable on the device.</param>
        /// <returns>The memory manager</returns>
        /// <exception cref="ArgumentException">Thrown when <paramref name="pid"/> is invalid</exception>
        public MemoryManager CreateMemoryManager(ulong pid, ulong cpuMemorySize)
        {
            if (!PhysicalMemoryRegistry.TryGetValue(pid, out PhysicalMemory physicalMemory))
            {
                throw new ArgumentException("The PID is invalid or the process was not registered", nameof(pid));
            }

            return new MemoryManager(physicalMemory, cpuMemorySize);
        }

        /// <summary>
        /// Creates a new device memory manager.
        /// </summary>
        /// <param name="pid">ID of the process that owns the memory manager</param>
        /// <returns>The memory manager</returns>
        /// <exception cref="ArgumentException">Thrown when <paramref name="pid"/> is invalid</exception>
        public DeviceMemoryManager CreateDeviceMemoryManager(ulong pid)
        {
            if (!PhysicalMemoryRegistry.TryGetValue(pid, out PhysicalMemory physicalMemory))
            {
                throw new ArgumentException("The PID is invalid or the process was not registered", nameof(pid));
            }

            return physicalMemory.CreateDeviceMemoryManager();
        }

        /// <summary>
        /// Registers virtual memory used by a process for GPU memory access, caching and read/write tracking.
        /// </summary>
        /// <param name="pid">ID of the process that owns <paramref name="cpuMemory"/></param>
        /// <param name="cpuMemory">Virtual memory owned by the process</param>
        /// <exception cref="ArgumentException">Thrown if <paramref name="pid"/> was already registered</exception>
        public void RegisterProcess(ulong pid, Cpu.IVirtualMemoryManagerTracked cpuMemory)
        {
            PhysicalMemory physicalMemory = new(this, cpuMemory);
            if (!PhysicalMemoryRegistry.TryAdd(pid, physicalMemory))
            {
                throw new ArgumentException("The PID was already registered", nameof(pid));
            }

            S2ARefreshPhysSnap();

            physicalMemory.ShaderCache.ShaderCacheStateChanged += ShaderCacheStateUpdate;
        }

        /// <summary>
        /// Unregisters a process, indicating that its memory will no longer be used, and that caches can be freed.
        /// </summary>
        /// <param name="pid">ID of the process</param>
        public void UnregisterProcess(ulong pid)
        {
            if (PhysicalMemoryRegistry.TryRemove(pid, out PhysicalMemory physicalMemory))
            {
                S2ARefreshPhysSnap();
                physicalMemory.ShaderCache.ShaderCacheStateChanged -= ShaderCacheStateUpdate;
                physicalMemory.Dispose();
            }
        }

        /// <summary>
        /// Converts a nanoseconds timestamp value to Maxwell time ticks.
        /// </summary>
        /// <remarks>
        /// The frequency is 614400000 Hz.
        /// </remarks>
        /// <param name="nanoseconds">Timestamp in nanoseconds</param>
        /// <returns>Maxwell ticks</returns>
        private static ulong ConvertNanosecondsToTicks(ulong nanoseconds)
        {
            // We need to divide first to avoid overflows.
            // We fix up the result later by calculating the difference and adding
            // that to the result.
            ulong divided = nanoseconds / NsToTicksFractionDenominator;

            ulong rounded = divided * NsToTicksFractionDenominator;

            ulong errorBias = (nanoseconds - rounded) * NsToTicksFractionNumerator / NsToTicksFractionDenominator;

            return divided * NsToTicksFractionNumerator + errorBias;
        }

        /// <summary>
        /// Gets a sequence number for resource modification ordering. This increments on each call.
        /// </summary>
        /// <returns>A sequence number for resource modification ordering</returns>
        internal long GetModifiedSequence()
        {
            return _modifiedSequence++;
        }

        /// <summary>
        /// Gets the value of the GPU timer.
        /// </summary>
        /// <returns>The current GPU timestamp</returns>
        // S2A_GPU_TS=1（帧率能耗线 10-23，上游塞尔达动态分辨率 / 帧节拍）：游戏读到的 GPU 时间戳 = 报告所在命令段的真实 GPU 结束时刻，
        // 原版 = GPU 线程处理到这条命令时的 CPU 时刻、且 FastGpuTime 再除 256（让游戏以为 GPU 很闲、不降分辨率）。开时 FastGpuTime 一并关
        internal static readonly bool S2AGpuTs = Environment.GetEnvironmentVariable("S2A_GPU_TS") == "1";
        private readonly object _s2aTsLock = new();
        private readonly List<(MemoryManager Mm, ulong Va, ulong Payload, ulong Ticks)> _s2aTsReady = new();
        private int _s2aTsOutstanding;
        private bool _s2aTsLogged;
        private readonly EventHandler<ulong> _s2aTsBarrierHandler;
        private readonly Queue<ICounterEvent> _s2aTsEvents = new();   // 在途 / 已出的时间戳事件，GPU 线程按序释放已出结果的

        private long _s2aTsDone, _s2aTsDisposed;   // 已回调个数（计数线程递增）/ 已释放个数（GPU 线程）

        /// <summary>GPU 线程：记下一个时间戳事件，顺带释放排在前面、已出结果的。时间戳报告与屏障同一条计数队列、按登记序出结果，
        /// 所以已回调 N 个 = 最早登记的 N 个已出结果。ICounterEvent 只在 GPU 线程上 Dispose（同计数缓存替换时的做法）</summary>
        internal void S2ATsTrack(ICounterEvent evt)
        {
            long done = Volatile.Read(ref _s2aTsDone);

            while (_s2aTsDisposed < done && _s2aTsEvents.Count != 0)
            {
                _s2aTsEvents.Dequeue().Dispose();
                _s2aTsDisposed++;
            }

            if (evt != null)
            {
                _s2aTsEvents.Enqueue(evt);
            }
        }

        /// <summary>GPU 线程：登记了一个时间戳报告（计数在途）</summary>
        internal void S2ATsBegin() => Interlocked.Increment(ref _s2aTsOutstanding);

        /// <summary>计数线程：一个时间戳报告出结果（主机纳秒）</summary>
        internal void S2ATsResult(MemoryManager mm, ulong va, ulong payload, ulong hostNs)
        {
            ulong ticks = ConvertNanosecondsToTicks(hostNs) - _firstTimestamp;

            if (!_s2aTsLogged)
            {
                _s2aTsLogged = true;
                long cpuNs = PerformanceCounter.ElapsedNanoseconds;
                Console.Error.WriteLine($"[gpu] 时间戳（S2A_GPU_TS）首个结果：GPU 结束时刻比此刻 CPU 时钟早 {(cpuNs - (long)hostNs) / 1e6:F2} ms（应为小正数，证明两边同一时基）");
            }

            Interlocked.Increment(ref _s2aTsDone);

            lock (_s2aTsLock)
            {
                _s2aTsReady.Add((mm, va, payload, ticks));
                Interlocked.Decrement(ref _s2aTsOutstanding);

                if (_s2aTsReady.Count >= 256)
                {
                    S2ATsWriteLocked();   // 长时间没有同步点：别无限攒
                }
            }
        }

        /// <summary>GPU 线程：同步点推进前调——之前登记的时间戳都出结果后整批写回</summary>
        internal void S2ATsBarrier()
        {
            if (!S2AGpuTs || Volatile.Read(ref _s2aTsOutstanding) == 0 && _s2aTsReady.Count == 0)
            {
                return;
            }

            // 同一计数队列按序出结果：这个屏障出结果时，排在它前面的时间戳都已进待写批
            S2ATsTrack(Renderer.ReportCounter(CounterType.S2ATimestamp, _s2aTsBarrierHandler, 1f, false));
        }

        private void S2ATsBarrierResult(object evt, ulong _)
        {
            Interlocked.Increment(ref _s2aTsDone);

            lock (_s2aTsLock)
            {
                S2ATsWriteLocked();
            }
        }

        private void S2ATsWriteLocked()
        {
            foreach ((MemoryManager mm, ulong va, ulong payload, ulong ticks) in _s2aTsReady)
            {
                mm.Write(va + 8, ticks);   // 只改时间戳字段（载荷已在报告当时写好）
            }

            _s2aTsReady.Clear();
        }

        internal ulong GetTimestamp()
        {
            // Guest timestamp will start at 0, instead of host value.
            ulong ticks = ConvertNanosecondsToTicks((ulong)PerformanceCounter.ElapsedNanoseconds) - _firstTimestamp;

            if (GraphicsConfig.FastGpuTime)
            {
                // Divide by some amount to report time as if operations were performed faster than they really are.
                // This can prevent some games from switching to a lower resolution because rendering is too slow.
                ticks /= 256;
            }

            return ticks;
        }

        /// <summary>
        /// Shader cache state update handler.
        /// </summary>
        /// <param name="state">Current state of the shader cache load process</param>
        /// <param name="current">Number of the current shader being processed</param>
        /// <param name="total">Total number of shaders to process</param>
        private void ShaderCacheStateUpdate(ShaderCacheState state, int current, int total)
        {
            ShaderCacheStateChanged?.Invoke(state, current, total);
        }

        /// <summary>
        /// Initialize the GPU shader cache.
        /// </summary>
        public void InitializeShaderCache(CancellationToken cancellationToken)
        {
            HostInitalized.WaitOne();

            foreach (PhysicalMemory physicalMemory in PhysicalMemoryRegistry.Values)
            {
                physicalMemory.ShaderCache.Initialize(cancellationToken);
            }

            _gpuReadyEvent.Set();
        }

        /// <summary>
        /// Waits until the GPU is ready to receive commands.
        /// </summary>
        public void WaitUntilGpuReady()
        {
            _gpuReadyEvent.WaitOne();
        }

        /// <summary>
        /// Sets the current thread as the main GPU thread.
        /// </summary>
        public void SetGpuThread()
        {
            _gpuThread = Thread.CurrentThread;

            Capabilities = Renderer.GetCapabilities();
        }

        /// <summary>
        /// Checks if the current thread is the GPU thread.
        /// </summary>
        /// <returns>True if the thread is the GPU thread, false otherwise</returns>
        public bool IsGpuThread()
        {
            return _gpuThread == Thread.CurrentThread;
        }

        /// <summary>
        /// Publishes pending buffer and texture writeback actions before native guest backing
        /// changes. The caller must then prove queue completion and flush tracking while the
        /// old mapping remains valid; this method alone does not permit replacing memory.
        /// </summary>
        public void PrepareBackingChange()
        {
            if (!IsGpuThread())
            {
                throw new InvalidOperationException("Backing changes must be prepared by the GPU owner thread.");
            }

            CreateHostSyncIfNeeded(HostSyncFlags.Force | HostSyncFlags.Strict | HostSyncFlags.Syncpoint);
        }

        /// <summary>
        /// Processes the queue of shaders that must save their binaries to the disk cache.
        /// </summary>
        public void ProcessShaderCacheQueue()
        {
            foreach (PhysicalMemory physicalMemory in _s2aPhysSnap)
            {
                physicalMemory.ShaderCache.ProcessShaderCacheQueue();
            }
        }

        /// <summary>
        /// Advances internal sequence number.
        /// This forces the update of any modified GPU resource.
        /// </summary>
        internal void AdvanceSequence()
        {
            SequenceNumber++;
        }

        /// <summary>
        /// Registers a buffer migration. These are checked to see if they can be disposed when the sync number increases,
        /// and the migration copy has completed.
        /// </summary>
        /// <param name="migration">The buffer migration</param>
        internal void RegisterBufferMigration(BufferMigration migration)
        {
            BufferMigrations.Add(migration);
            _pendingSync = true;
        }

        /// <summary>
        /// Registers an action to be performed the next time a syncpoint is incremented.
        /// This will also ensure a host sync object is created, and <see cref="SyncNumber"/> is incremented.
        /// </summary>
        /// <param name="action">The resource with action to be performed on sync object creation</param>
        /// <param name="syncpointOnly">True if the sync action should only run when syncpoints are incremented</param>
        internal void RegisterSyncAction(ISyncActionHandler action, bool syncpointOnly = false)
        {
            if (syncpointOnly)
            {
                SyncpointActions.Add(action);
            }
            else
            {
                SyncActions.Add(action);
                _pendingSync = true;
            }
        }

        /// <summary>
        /// Creates a host sync object if there are any pending sync actions. The actions will then be called.
        /// If no actions are present, a host sync object is not created.
        /// </summary>
        /// <param name="flags">Modifiers for how host sync should be created</param>
        internal void CreateHostSyncIfNeeded(HostSyncFlags flags)
        {
            bool syncPoint = (flags & HostSyncFlags.Syncpoint) == HostSyncFlags.Syncpoint;
            bool strict = (flags & HostSyncFlags.Strict) == HostSyncFlags.Strict;
            bool force = (flags & HostSyncFlags.Force) == HostSyncFlags.Force;

            Memory.S2AZeroCopy.Log();

            if (BufferMigrations.Count > 0)
            {
                ulong currentSyncNumber = Renderer.GetCurrentSync();

                for (int i = 0; i < BufferMigrations.Count; i++)
                {
                    BufferMigration migration = BufferMigrations[i];
                    long diff = (long)(currentSyncNumber - migration.SyncNumber);

                    if (diff >= 0)
                    {
                        migration.Dispose();
                        BufferMigrations.RemoveAt(i--);
                    }
                }
            }

            if (force || _pendingSync || (syncPoint && SyncpointActions.Count > 0))
            {
                for (int i = 0; i < SyncActions.Count; i++)
                {
                    if (SyncActions[i].SyncPreAction(syncPoint))
                    {
                        SyncActions.RemoveAt(i--);
                    }
                }

                foreach (ISyncActionHandler action in SyncpointActions)
                {
                    action.SyncPreAction(syncPoint);
                }

                Renderer.CreateSync(SyncNumber, strict);

                SyncNumber++;

                for (int i = 0; i < SyncActions.Count; i++)
                {
                    if (SyncActions[i].SyncAction(syncPoint))
                    {
                        SyncActions.RemoveAt(i--);
                    }
                }
                
                for (int i = 0; i < SyncpointActions.Count; i++)
                {
                    if (SyncpointActions[i].SyncAction(syncPoint))
                    {
                        SyncpointActions.RemoveAt(i--);
                    }
                }
            }

            _pendingSync = false;
        }

        /// <summary>
        /// Performs deferred actions.
        /// This is useful for actions that must run on the render thread, such as resource disposal.
        /// </summary>
        internal void RunDeferredActions()
        {
            while (DeferredActions.TryDequeue(out Action action))
            {
                action();
            }
        }

        /// <summary>
        /// Disposes all GPU resources currently cached.
        /// It's an error to push any GPU commands after disposal.
        /// Additionally, the GPU commands FIFO must be empty for disposal,
        /// and processing of all commands must have finished.
        /// </summary>
        public void Dispose()
        {
            _s2aSyncpt.CompleteAdding();
            if (_s2aSyncptThread != null && !_s2aSyncptThread.Join(3000))
                throw new TimeoutException("GPU 同步点线程未停止；不能释放旧会话");
            _s2aSyncpt.Dispose();
            ShaderCache.S2AResetSession();
            GPFifo.Dispose();
            HostInitalized.Dispose();
            _gpuReadyEvent.Dispose();

            // Has to be disposed before processing deferred actions, as it will produce some.
            foreach (PhysicalMemory physicalMemory in PhysicalMemoryRegistry.Values)
            {
                physicalMemory.Dispose();
            }

            SupportBufferUpdater.Dispose();

            PhysicalMemoryRegistry.Clear();
            S2ARefreshPhysSnap();

            RunDeferredActions();

            S2ABeforeRendererDispose?.Invoke();
            S2ABeforeRendererDispose = null;
            Renderer.Dispose();
            Shader.S2ASeen.Close();
            Shader.DiskCache.S2AShaderCacheGuard.ResetSession();
            MemoryManager.S2AResetSession();
            S2AGameSync.ResetSession();
            SyncActions.Clear(); SyncpointActions.Clear();
            ShaderCacheStateChanged = null;
        }
    }
}
