using Ryujinx.Graphics.Gpu;
using System;

namespace Ryujinx.HLE.HOS.Services.SurfaceFlinger
{
    class BufferItemConsumer : ConsumerBase
    {
        private readonly GpuContext _gpuContext;

        // S2Arm: acquired copies are recycled on ReleaseBuffer (the compositor acquires one per frame; each copy carries a
        // ~0x170-byte graphic buffer pointer). Accessed under Lock.
        private readonly System.Collections.Generic.Stack<BufferItem> _acquiredPool = new();

        public BufferItemConsumer(Switch device,
            BufferQueueConsumer consumer,
            uint consumerUsage,
            int bufferCount,
            bool controlledByApp,
            IConsumerListener listener = null) : base(consumer, controlledByApp, listener)
        {
            _gpuContext = device.Gpu;

            Status status = Consumer.SetConsumerUsageBits(consumerUsage);

            if (status != Status.Success)
            {
                throw new InvalidOperationException();
            }

            if (bufferCount != -1)
            {
                status = Consumer.SetMaxAcquiredBufferCount(bufferCount);

                if (status != Status.Success)
                {
                    throw new InvalidOperationException();
                }
            }
        }

        public Status AcquireBuffer(out BufferItem bufferItem, ulong expectedPresent, bool waitForFence = false)
        {
            lock (Lock)
            {
                Status status = AcquireBufferLocked(out BufferItem tmp, expectedPresent);

                if (status != Status.Success)
                {
                    bufferItem = null;

                    return status;
                }

                // Make sure to clone the object to not temper the real instance.
                bufferItem = _acquiredPool.Count != 0 ? _acquiredPool.Pop() : new BufferItem();
                bufferItem.CopyFrom(tmp);

                // S2Arm: the queue's instance is not referenced after the copy (ConsumerBase only read it)
                Consumer.RecycleBufferItem(tmp);

                if (waitForFence)
                {
                    bufferItem.Fence.WaitForever(_gpuContext);
                }

                bufferItem.GraphicBuffer.Set(Slots[bufferItem.Slot].GraphicBuffer);

                return Status.Success;
            }
        }

        public Status ReleaseBuffer(BufferItem bufferItem, ref AndroidFence fence)
        {
            lock (Lock)
            {
                Status result = AddReleaseFenceLocked(bufferItem.Slot, ref bufferItem.GraphicBuffer, ref fence);

                if (result == Status.Success)
                {
                    result = ReleaseBufferLocked(bufferItem.Slot, ref bufferItem.GraphicBuffer);
                }

                // S2Arm: the caller drops the item after releasing it
                if (_acquiredPool.Count < BufferSlotArray.NumBufferSlots)
                {
                    _acquiredPool.Push(bufferItem);
                }

                return result;
            }
        }

        public Status SetDefaultBufferSize(uint width, uint height)
        {
            lock (Lock)
            {
                return Consumer.SetDefaultBufferSize(width, height);
            }
        }

        public Status SetDefaultBufferFormat(PixelFormat defaultFormat)
        {
            lock (Lock)
            {
                return Consumer.SetDefaultBufferFormat(defaultFormat);
            }
        }
    }
}
