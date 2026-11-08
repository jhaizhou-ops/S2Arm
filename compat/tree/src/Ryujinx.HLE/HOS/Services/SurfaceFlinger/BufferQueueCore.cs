using Ryujinx.Common;
using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS.Kernel.Threading;
using Ryujinx.HLE.HOS.Services.SurfaceFlinger.Types;
using System;
using System.Collections.Generic;
using System.Threading;

namespace Ryujinx.HLE.HOS.Services.SurfaceFlinger
{
    class BufferQueueCore
    {
        // The host must cancel blocked producer IPC before it can dispose the
        // compositor. Keep only weak monitor references in the process-wide
        // shutdown callback, so previous sessions are not retained by it.
        private static readonly List<WeakReference<object>> _s2aWaitLocks = [];

        static BufferQueueCore()
        {
            S2AShutdown.OnRequest(S2AWakeWaiters);
        }

        internal static void S2ARegisterWaitLock(object waitLock)
        {
            lock (_s2aWaitLocks)
            {
                _s2aWaitLocks.RemoveAll(static weak => !weak.TryGetTarget(out _));
                _s2aWaitLocks.Add(new WeakReference<object>(waitLock));
            }

            if (S2AShutdown.Requested)
            {
                lock (waitLock) Monitor.PulseAll(waitLock);
            }
        }

        private static void S2AWakeWaiters()
        {
            WeakReference<object>[] waitLocks;
            lock (_s2aWaitLocks)
            {
                waitLocks = _s2aWaitLocks.ToArray();
                _s2aWaitLocks.Clear();
            }

            foreach (WeakReference<object> weak in waitLocks)
            {
                if (weak.TryGetTarget(out object waitLock))
                {
                    lock (waitLock) Monitor.PulseAll(waitLock);
                }
            }
        }

        public BufferSlotArray Slots;
        public int OverrideMaxBufferCount;
        public bool UseAsyncBuffer;
        public bool DequeueBufferCannotBlock;
        public PixelFormat DefaultBufferFormat;
        public int DefaultWidth;
        public int DefaultHeight;
        public int DefaultMaxBufferCount;
        public int MaxAcquiredBufferCount;
        public bool BufferHasBeenQueued;
        public ulong FrameCounter;
        public NativeWindowTransform TransformHint;
        public bool IsAbandoned;
        public NativeWindowApi ConnectedApi;
        public bool IsAllocating;
        public IProducerListener ProducerListener;
        public IConsumerListener ConsumerListener;
        public bool ConsumerControlledByApp;
        public uint ConsumerUsageBits;
        public List<BufferItem> Queue;
        public BufferInfo[] BufferHistory;
        public uint BufferHistoryPosition;
        public bool EnableExternalEvent;
        public int MaxBufferCountCached;

        public readonly object Lock = new();

        private readonly KEvent _waitBufferFreeEvent;
        private readonly KEvent _frameAvailableEvent;

        public ulong Owner { get; }

        public bool Active { get; private set; }

        // S2Arm：队列死态（消费者放弃 / 核心退出 / 宿主收局请求）。死态只代表「没人消费」，
        // 不代表「游戏接口死了」——此时生产者交易按排空语义走（出队回收真实槽、入队收帧即弃、
        // 不阻塞、状态恒 0）。绝不能回 NoInit：游戏对非 0 状态跳过出参赋值，上层拿未初始化
        // 栈值当缓冲下标索引纹理表 → 野指针 SIGSEGV（收局 / 切后台路径双机复现）。
        public bool S2ASinkMode => IsAbandoned || !Active || S2AShutdown.Requested;

        public const int BufferHistoryArraySize = 8;

        public event Action BufferQueued;

        // S2Arm: queued items are recycled once the consumer has taken its copy (QueueBuffer allocated an item plus
        // a ~0x170-byte graphic buffer pointer per frame). Accessed under Lock.
        private readonly Stack<BufferItem> _itemPool = new();

        public BufferItem RentBufferItemLocked()
        {
            return _itemPool.Count != 0 ? _itemPool.Pop() : new BufferItem();
        }

        public void ReturnBufferItemLocked(BufferItem item)
        {
            if (_itemPool.Count < BufferSlotArray.NumBufferSlots)
            {
                _itemPool.Push(item);
            }
        }

        public BufferQueueCore(Switch device, ulong pid)
        {
            Slots = new BufferSlotArray();
            IsAbandoned = false;
            OverrideMaxBufferCount = 0;
            DequeueBufferCannotBlock = false;
            UseAsyncBuffer = false;
            DefaultWidth = 1;
            DefaultHeight = 1;
            DefaultMaxBufferCount = 2;
            MaxAcquiredBufferCount = 1;
            FrameCounter = 0;
            TransformHint = 0;
            DefaultBufferFormat = PixelFormat.Rgba8888;
            IsAllocating = false;
            ProducerListener = null;
            ConsumerListener = null;
            ConsumerUsageBits = 0;

            Queue = [];

            // TODO: CreateGraphicBufferAlloc?

            _waitBufferFreeEvent = new KEvent(device.System.KernelContext);
            _frameAvailableEvent = new KEvent(device.System.KernelContext);

            Owner = pid;

            Active = true;

            BufferHistory = new BufferInfo[BufferHistoryArraySize];
            EnableExternalEvent = true;
            MaxBufferCountCached = 0;
            S2ARegisterWaitLock(Lock);
        }

        public int GetMinUndequeuedBufferCountLocked(bool async)
        {
            if (!UseAsyncBuffer)
            {
                return 0;
            }

            if (DequeueBufferCannotBlock || async)
            {
                return MaxAcquiredBufferCount + 1;
            }

            return MaxAcquiredBufferCount;
        }

        public int GetMinMaxBufferCountLocked(bool async)
        {
            return GetMinUndequeuedBufferCountLocked(async);
        }

        public void UpdateMaxBufferCountCachedLocked(int slot)
        {
            if (MaxBufferCountCached <= slot)
            {
                MaxBufferCountCached = slot + 1;
            }
        }

        public int GetMaxBufferCountLocked(bool async)
        {
            int minMaxBufferCount = GetMinMaxBufferCountLocked(async);

            int maxBufferCount = Math.Max(DefaultMaxBufferCount, minMaxBufferCount);

            if (OverrideMaxBufferCount != 0)
            {
                return OverrideMaxBufferCount;
            }

            // Preserve all buffers already in control of the producer and the consumer.
            for (int slot = maxBufferCount; slot < Slots.Length; slot++)
            {
                BufferState state = Slots[slot].BufferState;

                if (state is BufferState.Queued or BufferState.Dequeued)
                {
                    maxBufferCount = slot + 1;
                }
            }

            return maxBufferCount;
        }

        public Status SetDefaultMaxBufferCountLocked(int count)
        {
            int minBufferCount = UseAsyncBuffer ? 2 : 1;

            if (count < minBufferCount || count > Slots.Length)
            {
                return Status.BadValue;
            }

            DefaultMaxBufferCount = count;

            SignalDequeueEvent();

            return Status.Success;
        }

        public void SignalWaitBufferFreeEvent()
        {
            if (EnableExternalEvent)
            {
                _waitBufferFreeEvent.WritableEvent.Signal();
            }
        }

        public void SignalFrameAvailableEvent()
        {
            if (EnableExternalEvent)
            {
                _frameAvailableEvent.WritableEvent.Signal();
            }
        }

        public void PrepareForExit()
        {
            lock (Lock)
            {
                Active = false;

                Monitor.PulseAll(Lock);
            }
        }

        // TODO: Find an accurate way to handle a regular condvar here as this will wake up unwanted threads in some edge cases.
        public void SignalDequeueEvent()
        {
            Monitor.PulseAll(Lock);
        }

        public void WaitDequeueEvent()
        {
            WaitForLock();
        }

        public void SignalIsAllocatingEvent()
        {
            Monitor.PulseAll(Lock);
        }

        public void WaitIsAllocatingEvent()
        {
            WaitForLock();
        }

        public void SignalQueueEvent()
        {
            BufferQueued?.Invoke();
        }

        private void WaitForLock()
        {
            if (Active && !S2AShutdown.Requested)
            {
                Monitor.Wait(Lock);
            }
        }

        public void FreeBufferLocked(int slot)
        {
            Slots[slot].GraphicBuffer.Reset();

            if (Slots[slot].BufferState == BufferState.Acquired)
            {
                Slots[slot].NeedsCleanupOnRelease = true;
            }

            Slots[slot].BufferState = BufferState.Free;
            Slots[slot].FrameNumber = uint.MaxValue;
            Slots[slot].AcquireCalled = false;
            Slots[slot].Fence.FenceCount = 0;
        }

        public void FreeAllBuffersLocked()
        {
            BufferHasBeenQueued = false;

            for (int slot = 0; slot < Slots.Length; slot++)
            {
                FreeBufferLocked(slot);
            }
        }

        public bool StillTracking(ref BufferItem item)
        {
            BufferSlot slot = Slots[item.Slot];

            // TODO: Check this. On Android, this checks the "handle". I assume NvMapHandle is the handle, but it might not be.
            return !slot.GraphicBuffer.IsNull && slot.GraphicBuffer.Object.Buffer.Surfaces[0].NvMapHandle == item.GraphicBuffer.Object.Buffer.Surfaces[0].NvMapHandle;
        }

        public bool WaitWhileAllocatingLocked()
        {
            while (IsAllocating && Active && !S2AShutdown.Requested)
            {
                WaitIsAllocatingEvent();
            }

            return Active && !S2AShutdown.Requested;
        }

        public void CheckSystemEventsLocked(int maxBufferCount)
        {
            if (!EnableExternalEvent)
            {
                return;
            }

            bool needBufferReleaseSignal = false;
            bool needFrameAvailableSignal = false;

            if (maxBufferCount > 1)
            {
                for (int i = 0; i < maxBufferCount; i++)
                {
                    if (Slots[i].BufferState == BufferState.Queued)
                    {
                        needFrameAvailableSignal = true;
                    }
                    else if (Slots[i].BufferState == BufferState.Free)
                    {
                        needBufferReleaseSignal = true;
                    }
                }
            }

            if (needBufferReleaseSignal)
            {
                SignalWaitBufferFreeEvent();
            }
            else
            {
                _waitBufferFreeEvent.WritableEvent.Clear();
            }

            if (needFrameAvailableSignal)
            {
                SignalFrameAvailableEvent();
            }
            else
            {
                _frameAvailableEvent.WritableEvent.Clear();
            }
        }

        public bool IsProducerConnectedLocked()
        {
            return ConnectedApi != NativeWindowApi.NoApi;
        }

        public bool IsConsumerConnectedLocked()
        {
            return ConsumerListener != null;
        }

        public KReadableEvent GetWaitBufferFreeEvent()
        {
            lock (Lock)
            {
                return _waitBufferFreeEvent.ReadableEvent;
            }
        }

        public bool IsOwnedByConsumerLocked(int slot)
        {
            if (Slots[slot].BufferState != BufferState.Acquired)
            {
                Logger.Error?.Print(LogClass.SurfaceFlinger, $"Slot {slot} is not owned by the consumer (state = {Slots[slot].BufferState})");

                return false;
            }

            return true;
        }

        public bool IsOwnedByProducerLocked(int slot)
        {
            if (Slots[slot].BufferState != BufferState.Dequeued)
            {
                Logger.Error?.Print(LogClass.SurfaceFlinger, $"Slot {slot} is not owned by the producer (state = {Slots[slot].BufferState})");

                return false;
            }

            return true;
        }
    }
}
