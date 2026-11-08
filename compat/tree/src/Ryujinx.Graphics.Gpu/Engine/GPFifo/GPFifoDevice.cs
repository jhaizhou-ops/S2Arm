using Ryujinx.Graphics.Gpu.Memory;
using System;
using System.Buffers;
using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;

namespace Ryujinx.Graphics.Gpu.Engine.GPFifo
{
    /// <summary>
    /// Represents a GPU General Purpose FIFO device.
    /// </summary>
    public sealed class GPFifoDevice : IDisposable
    {
        /// <summary>
        /// Indicates if the command buffer has pre-fetch enabled.
        /// </summary>
        private enum CommandBufferType
        {
            Prefetch,
            NoPrefetch,
        }

        /// <summary>
        /// Command buffer data.
        /// </summary>
        private struct CommandBuffer
        {
            /// <summary>
            /// Processor used to process the command buffer. Contains channel state.
            /// </summary>
            public GPFifoProcessor Processor;

            /// <summary>
            /// The type of the command buffer.
            /// </summary>
            public CommandBufferType Type;

            /// <summary>
            /// Fetched data.
            /// </summary>
            public int[] Words;

            /// <summary>
            /// S2Arm: <see cref="Words"/> was rented from <see cref="ArrayPool{T}.Shared"/> by <see cref="Prefetch"/> and is
            /// returned once the GPU thread has processed the command buffer (may be longer than <see cref="EntryCount"/>).
            /// </summary>
            public bool PooledWords;

            /// <summary>
            /// The GPFIFO entry address (used in <see cref="CommandBufferType.NoPrefetch"/> mode).
            /// </summary>
            public ulong EntryAddress;

            /// <summary>
            /// The count of entries inside this GPFIFO entry.
            /// </summary>
            public uint EntryCount;

            /// <summary>
            /// S2Arm: push sequence number (<see cref="S2ATrackSync"/>): the CPU writes the game made before pushing this entry
            /// must be drained from the write tracker before the entry is processed.
            /// </summary>
            public long S2ASeq;

            /// <summary>
            /// Get the entries for the command buffer from memory.
            /// </summary>
            /// <param name="memoryManager">The memory manager used to fetch the data</param>
            /// <param name="flush">If true, flushes potential GPU written data before reading the command buffer</param>
            /// <returns>The fetched data</returns>
            private readonly ReadOnlySpan<int> GetWords(MemoryManager memoryManager, bool flush)
            {
                return MemoryMarshal.Cast<byte, int>(memoryManager.GetSpan(EntryAddress, (int)EntryCount * 4, flush));
            }

            /// <summary>
            /// Prefetch the command buffer.
            /// </summary>
            /// <param name="memoryManager">The memory manager used to fetch the data</param>
            public void Prefetch(MemoryManager memoryManager)
            {
                // S2Arm: snapshot into a pooled array instead of a new one per GPFIFO entry (games submit several per frame)
                ReadOnlySpan<int> words = GetWords(memoryManager, true);
                int[] copy = ArrayPool<int>.Shared.Rent(words.Length);
                words.CopyTo(copy);
                Words = copy;
                PooledWords = true;
            }

            /// <summary>
            /// Fetch the command buffer.
            /// </summary>
            /// <param name="memoryManager">The memory manager used to fetch the data</param>
            /// <param name="flush">If true, flushes potential GPU written data before reading the command buffer</param>
            /// <returns>The command buffer words</returns>
            public readonly ReadOnlySpan<int> Fetch(MemoryManager memoryManager, bool flush)
            {
                return Words != null ? Words.AsSpan(0, (int)EntryCount) : GetWords(memoryManager, flush);
            }
        }

        private readonly ConcurrentQueue<CommandBuffer> _commandBufferQueue;

        private GPFifoProcessor _prevChannelProcessor;

        private readonly bool _ibEnable;
        private readonly GpuContext _context;
        private readonly AutoResetEvent _event;

        private bool _interrupt;
        private int _flushSkips;

        /// <summary>
        /// Creates a new instance of the GPU General Purpose FIFO device.
        /// </summary>
        /// <param name="context">GPU context that the GPFIFO belongs to</param>
        internal GPFifoDevice(GpuContext context)
        {
            _commandBufferQueue = new ConcurrentQueue<CommandBuffer>();
            _ibEnable = true;
            _context = context;
            _event = new AutoResetEvent(false);
        }

        /// <summary>
        /// Signal the FIFO that there are new entries to process.
        /// </summary>
        public void SignalNewEntries()
        {
            _event.Set();
        }

        /// <summary>
        /// Push a GPFIFO entry in the form of a prefetched command buffer.
        /// It is intended to be used by nvservices to handle special cases.
        /// </summary>
        /// <param name="processor">Processor used to process <paramref name="commandBuffer"/></param>
        /// <param name="commandBuffer">The command buffer containing the prefetched commands</param>
        internal void PushHostCommandBuffer(GPFifoProcessor processor, int[] commandBuffer)
        {
            _commandBufferQueue.Enqueue(new CommandBuffer
            {
                Processor = processor,
                Type = CommandBufferType.Prefetch,
                Words = commandBuffer,
                EntryAddress = ulong.MaxValue,
                EntryCount = (uint)commandBuffer.Length,
                S2ASeq = Interlocked.Increment(ref _s2aPushSeq),
            });
        }

        /// <summary>
        /// Create a CommandBuffer from a GPFIFO entry.
        /// </summary>
        /// <param name="processor">Processor used to process the command buffer pointed to by <paramref name="entry"/></param>
        /// <param name="entry">The GPFIFO entry</param>
        /// <returns>A new CommandBuffer based on the GPFIFO entry</returns>
        private static CommandBuffer CreateCommandBuffer(GPFifoProcessor processor, GPEntry entry)
        {
            CommandBufferType type = CommandBufferType.Prefetch;

            if (entry.Entry1Sync == Entry1Sync.Wait)
            {
                type = CommandBufferType.NoPrefetch;
            }

            ulong startAddress = ((ulong)entry.Entry0Get << 2) | ((ulong)entry.Entry1GetHi << 32);

            return new CommandBuffer
            {
                Processor = processor,
                Type = type,
                Words = null,
                EntryAddress = startAddress,
                EntryCount = (uint)entry.Entry1Length,
            };
        }

        /// <summary>
        /// S2A：诊断 NXGAL_PSTAT 的 GPFIFO 段统计挂钩（缺省 null = 不调，零开销）。参数：本通道 GPU 内存管理器、段 GPU 地址、段字节。只读统计，不改命令处理
        /// </summary>
        public static unsafe delegate*<MemoryManager, ulong, ulong, void> S2ASegmentHook;

        /// <summary>
        /// Pushes GPFIFO entries.
        /// </summary>
        /// <param name="processor">Processor used to process the command buffers pointed to by <paramref name="entries"/></param>
        /// <param name="entries">GPFIFO entries</param>
        internal void PushEntries(GPFifoProcessor processor, ReadOnlySpan<ulong> entries)
        {
            bool beforeBarrier = true;

            for (int index = 0; index < entries.Length; index++)
            {
                ulong entry = entries[index];

                CommandBuffer commandBuffer = CreateCommandBuffer(processor, Unsafe.As<ulong, GPEntry>(ref entry));

                unsafe
                {
                    if (S2ASegmentHook != null)
                    {
                        S2ASegmentHook(processor.MemoryManager, commandBuffer.EntryAddress, (ulong)commandBuffer.EntryCount * 4);
                    }
                }

                if (beforeBarrier && commandBuffer.Type == CommandBufferType.Prefetch)
                {
                    commandBuffer.Prefetch(processor.MemoryManager);
                }

                if (commandBuffer.Type == CommandBufferType.NoPrefetch)
                {
                    beforeBarrier = false;
                }

                commandBuffer.S2ASeq = Interlocked.Increment(ref _s2aPushSeq);
                _commandBufferQueue.Enqueue(commandBuffer);
            }
        }

        /// <summary>
        /// Waits until commands are pushed to the FIFO.
        /// </summary>
        /// <returns>True if commands were received, false if wait timed out</returns>
        // S2A：能耗减法开关 S2A_FIFO_WAIT_MS=<毫秒>（缺省不设 = 上游 8 ms 轮询不变）。设了：出帧就绪也唤醒（Window.SignalFrameReady → S2AWake），
        // 超时放宽到给定值（保底：停机只取消令牌不发事件）。上游 8 ms 超时空闲时每秒醒约 125 次，且醒在性能核上（10-20 动森新包性能核占比 74%）
        internal static readonly int S2AWaitMs = int.TryParse(System.Environment.GetEnvironmentVariable("S2A_FIFO_WAIT_MS"), out int s2aMs) && s2aMs > 0 ? s2aMs : 8;
        internal static readonly bool S2AWakeOnFrame = S2AWaitMs != 8;

        /// <summary>出帧就绪唤醒等待中的渲染循环（S2A_FIFO_WAIT_MS 设了才生效）</summary>
        public void S2AWake()
        {
            if (S2AWakeOnFrame)
            {
                _event.Set();
            }
        }

        // S2A：写跟踪排空（graphics/track 设计.md 第 11 条）。游戏直跑在真内存上，CPU 写由写跟踪模块记下、排空时才变成 Ryujinx 的跟踪事件；
        // 原版事件在 CPU 写的当下同步发出，任何之后入队的命令都看得到。DispatchCalls 一次会接着取走排空之后才入队的命令（游戏边写下一组缓冲边提交），
        // 只在唤醒时排空一次，这些命令就拿 GPU 侧旧数据画（10-21 八方2 选项页：常量 / 顶点缓冲新旧混杂、4 组轮换缓冲按 4 KB 整页旧内容上传）。
        // 规则：每个命令入队时取递增序号；处理一个命令前，它的序号大于上次排空时读到的序号就先排空——游戏在入队之前的写都已被排空看见。
        // S2ATrackSync = null（单测 / 不接写跟踪）不调
        public static Action S2ATrackSync;
        private long _s2aPushSeq;
        private long _s2aSyncedSeq;
        private int _s2aControlPending;

        /// <summary>
        /// S2Arm: optional session control consumer, invoked on the GPU thread between command buffers.
        /// It must not be invoked inside a processor operation that can retain guest memory spans.
        /// </summary>
        public Action S2AControlPoll { get; set; }

        /// <summary>
        /// Wake the GPU and request a control poll independently of guest command pushes.
        /// The caller must publish its request before signalling.
        /// </summary>
        public void S2ASignalControl()
        {
            Interlocked.Exchange(ref _s2aControlPending, 1);
            _event.Set();
        }

        /// <summary>Consume pending session control on the GPU thread at a safe command boundary.</summary>
        public void S2APollControl()
        {
            if (Volatile.Read(ref _s2aControlPending) != 0 &&
                Interlocked.Exchange(ref _s2aControlPending, 0) != 0)
            {
                S2AControlPoll?.Invoke();
            }
        }

        /// <summary>S2A：排空写跟踪，并记下此刻已入队的序号（之前入队的命令都不必再排空）。只在 GPU 线程调</summary>
        public void S2ASync()
        {
            Action sync = S2ATrackSync;

            if (sync != null)
            {
                _s2aSyncedSeq = Volatile.Read(ref _s2aPushSeq);
                sync();
            }
        }

        public bool WaitForCommands()
        {
            return !_commandBufferQueue.IsEmpty || (_event.WaitOne(S2AWaitMs) && !_commandBufferQueue.IsEmpty);
        }

        /// <summary>
        /// Processes commands pushed to the FIFO.
        /// </summary>
        public void DispatchCalls()
        {
            // Use this opportunity to also dispose any pending channels that were closed.
            long s2aT = S2AAllocTrace.On ? S2AAllocTrace.Now() : 0; // S2A：渲染线程分配拆账（段）
            _context.RunDeferredActions();
            if (S2AAllocTrace.On) { long t = S2AAllocTrace.Now(); S2AAllocTrace.Raw(0x40_0003, t - s2aT); s2aT = t; }

            // Process command buffers.
            while (_ibEnable && !_interrupt && _commandBufferQueue.TryDequeue(out CommandBuffer entry))
            {
                // A VM transaction can park guest writers, so no new push sequence may arrive.
                // Handle it before fetching any span from the next command buffer's backing.
                S2APollControl();
                bool flushCommandBuffer = true;

                if (entry.S2ASeq > _s2aSyncedSeq)
                {
                    S2ASync();
                }

                if (_flushSkips != 0)
                {
                    _flushSkips--;
                    flushCommandBuffer = false;
                }

                ReadOnlySpan<int> words = entry.Fetch(entry.Processor.MemoryManager, flushCommandBuffer);
                if (S2AAllocTrace.On) { long t = S2AAllocTrace.Now(); S2AAllocTrace.Raw(0x40_0001, t - s2aT); s2aT = t; }

                // If we are changing the current channel,
                // we need to force all the host state to be updated.
                if (_prevChannelProcessor != entry.Processor)
                {
                    _prevChannelProcessor = entry.Processor;
                    entry.Processor.ForceAllDirty();
                }

                entry.Processor.Process(entry.EntryAddress, words);
                if (S2AAllocTrace.On) { long t = S2AAllocTrace.Now(); S2AAllocTrace.Raw(0x40_0002, t - s2aT); s2aT = t; }

                // S2Arm: the snapshot is not referenced after processing (the replay cache keeps operations, not words)
                if (entry.PooledWords)
                {
                    ArrayPool<int>.Shared.Return(entry.Words);
                }
            }

            _interrupt = false;
        }

        /// <summary>
        /// Sets the number of flushes that should be skipped for subsequent command buffers.
        /// </summary>
        /// <remarks>
        /// This can improve performance when command buffer data only needs to be consumed by the GPU.
        /// </remarks>
        /// <param name="count">The amount of flushes that should be skipped</param>
        internal void SetFlushSkips(int count)
        {
            _flushSkips = count;
        }

        /// <summary>
        /// Interrupts command processing. This will break out of the DispatchCalls loop.
        /// </summary>
        public void Interrupt()
        {
            _interrupt = true;
            _event.Set();
        }

        /// <summary>
        /// Disposes of resources used for GPFifo command processing.
        /// </summary>
        public void Dispose()
        {
            while (_commandBufferQueue.TryDequeue(out CommandBuffer commandBuffer))
                if (commandBuffer.PooledWords) ArrayPool<int>.Shared.Return(commandBuffer.Words);
            _prevChannelProcessor = null;
            _event.Dispose();
        }
    }
}
