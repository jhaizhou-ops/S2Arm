using Ryujinx.Common.Logging;
using Ryujinx.Graphics.GAL;
using Silk.NET.Vulkan;
using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;
using VkBuffer = Silk.NET.Vulkan.Buffer;
using VkFormat = Silk.NET.Vulkan.Format;

namespace Ryujinx.Graphics.Vulkan
{
    class BufferHolder : IDisposable, IMirrorable<DisposableBuffer>, IMirrorable<DisposableBufferView>
    {
        private const int MaxUpdateBufferSize = 0x10000;

        private const int SetCountThreshold = 100;
        private const int WriteCountThreshold = 50;
        private const int FlushCountThreshold = 5;

        public const int DeviceLocalSizeThreshold = 256 * 1024; // 256kb

        public const AccessFlags DefaultAccessFlags =
            AccessFlags.IndirectCommandReadBit |
            AccessFlags.IndexReadBit |
            AccessFlags.VertexAttributeReadBit |
            AccessFlags.ShaderReadBit |
            AccessFlags.ShaderWriteBit |
            AccessFlags.TransferReadBit |
            AccessFlags.TransferWriteBit |
            AccessFlags.UniformReadBit;

        private readonly VulkanRenderer _gd;
        private readonly Device _device;
        private readonly MemoryAllocation _allocation;
        private readonly Auto<DisposableBuffer> _buffer;
        private readonly Auto<MemoryAllocation> _allocationAuto;
        private readonly bool _allocationImported;
        private readonly ulong _bufferHandle;

        private CacheByRange<BufferHolder> _cachedConvertedBuffers;

        private readonly AlignedTexelWritebackQueue<Auto<DisposableBuffer>> _alignedTexelWrites = new();
        private HashSet<Action> _alignedTexelViewInvalidates;

        public int Size { get; }

        private readonly nint _map;

        private readonly MultiFenceHolder _waitable;

        private bool _lastAccessIsWrite;

        private readonly BufferAllocationType _baseType;
        private readonly BufferAllocationType _activeType;

        private readonly ReaderWriterLockSlim _flushLock;
        private FenceHolder _flushFence;
        private int _flushWaiting;

        private byte[] _pendingData;
        private BufferMirrorRangeList _pendingDataRanges;
        private Dictionary<ulong, StagingBufferReserved> _mirrors;
        private bool _useMirrors;

        private Action _decrementReferenceCount;

        public BufferHolder(VulkanRenderer gd, Device device, VkBuffer buffer, MemoryAllocation allocation, int size, BufferAllocationType type, BufferAllocationType currentType)
        {
            _gd = gd;
            _device = device;
            _allocation = allocation;
            _allocationAuto = new Auto<MemoryAllocation>(allocation);
            _waitable = new MultiFenceHolder(size);
            _buffer = new Auto<DisposableBuffer>(new DisposableBuffer(gd.Api, device, buffer, size), this, _waitable, _allocationAuto);
            _bufferHandle = buffer.Handle;
            Size = size;
            _map = allocation.HostPointer;

            _baseType = type;
            _activeType = currentType;

            _flushLock = new ReaderWriterLockSlim();
            _useMirrors = gd.IsTBDR;
            
            _decrementReferenceCount = _buffer.DecrementReferenceCount;
        }

        public BufferHolder(VulkanRenderer gd, Device device, VkBuffer buffer, Auto<MemoryAllocation> allocation, int size, BufferAllocationType type, BufferAllocationType currentType, int offset)
        {
            _gd = gd;
            _device = device;
            _allocation = allocation.GetUnsafe();
            _allocationAuto = allocation;
            _allocationImported = true;
            _waitable = new MultiFenceHolder(size);
            _buffer = new Auto<DisposableBuffer>(new DisposableBuffer(gd.Api, device, buffer, size), this, _waitable, _allocationAuto);
            _bufferHandle = buffer.Handle;
            Size = size;
            _map = _allocation.HostPointer + offset;

            _baseType = type;
            _activeType = currentType;

            _flushLock = new ReaderWriterLockSlim();
        }

        public BufferHolder(VulkanRenderer gd, Device device, VkBuffer buffer, int size, Auto<MemoryAllocation>[] storageAllocations)
        {
            _gd = gd;
            _device = device;
            _waitable = new MultiFenceHolder(size);
            _buffer = new Auto<DisposableBuffer>(new DisposableBuffer(gd.Api, device, buffer, size), _waitable, storageAllocations);
            _bufferHandle = buffer.Handle;
            Size = size;

            _baseType = BufferAllocationType.Sparse;
            _activeType = BufferAllocationType.Sparse;

            _flushLock = new ReaderWriterLockSlim();
        }

        internal static bool NeedsAlignedTexelCopy(int offset, int alignment)
        {
            return alignment > 1 && (uint)offset % (uint)alignment != 0;
        }

        public Auto<DisposableBufferView> CreateView(VkFormat format, int offset, int size, Action invalidateView, CommandBufferScoped cbs, out Auto<DisposableBuffer> alignedCopy)
        {
            alignedCopy = null;

            if (!NeedsAlignedTexelCopy(offset, _gd.MinTexelBufferOffsetAlignment))
            {
                return CreateViewDirect(format, offset, size);
            }

            FlushAlignedTexelWrites();

            // The view offset does not meet minTexelBufferOffsetAlignment. Serve the
            // view from an aligned sub-allocation shadowing the same data, so texel
            // indices still read identical bytes. Source writes invalidate the shadow
            // through the converted-buffer cache; shadow writes are copied back here
            // before the next access to the source range.

            AlignedTexelCopyCacheKey key = new();

            if (!_cachedConvertedBuffers.TryGetValue(offset, size, key, out BufferHolder shadow))
            {
                shadow = _gd.BufferManager.Create(_gd, size, baseType: BufferAllocationType.DeviceLocal);
                S2APipelineDiagnostics.ReportAlignedTexelShadow();

                _gd.PipelineInternal.EndRenderPass();
                S2APipelineDiagnostics.ReportAlignedTexelEndRenderPass();

                Copy(_gd, cbs, _buffer, shadow.GetBuffer(), offset, 0, size);

                key.SetShadow(shadow);

                _cachedConvertedBuffers.Add(offset, size, key, shadow);
            }

            shadow.AddAlignedTexelViewInvalidate(invalidateView);

            alignedCopy = shadow.GetBuffer();
            alignedCopy.IncrementReferenceCount();

            return shadow.CreateViewDirect(format, 0, size);
        }

        internal void ArmAlignedTexelWriteback(Auto<DisposableBuffer> alignedCopy, int srcOffset, int size)
        {
            // 挂账先进 pending——使用它的 draw/dispatch 记录完成后才 promote 生效，
            // 绑定到绘制之间的宿主侧访问不会提前把没被写过的影子拷回源缓冲。
            if (_alignedTexelWrites.Arm(alignedCopy, srcOffset, size))
            {
                alignedCopy.IncrementReferenceCount();
            }
        }

        internal void PromoteAlignedTexelWritebacks()
        {
            List<AlignedTexelWritebackQueue<Auto<DisposableBuffer>>.Entry> dropped =
                _alignedTexelWrites.Promote(IsAlignedTexelShadowLive);

            if (dropped != null)
            {
                foreach (AlignedTexelWritebackQueue<Auto<DisposableBuffer>>.Entry write in dropped)
                {
                    write.Shadow.Dispose();
                }
            }
        }

        private bool IsAlignedTexelShadowLive(AlignedTexelWritebackQueue<Auto<DisposableBuffer>>.Entry write)
        {
            // pending 期间源被写过 → 影子被 ClearRange 逐出缓存；拿着死影子回写会用旧数据
            // 盖新数据，这笔账必须丢弃。armed 账不存在这个问题：宿主写源前 flush 会先消费它。
            AlignedTexelCopyCacheKey key = new();

            return _cachedConvertedBuffers.TryGetValue(write.SrcOffset, write.Size, key, out BufferHolder shadow) &&
                   ReferenceEquals(shadow.GetBuffer(), write.Shadow);
        }

        internal bool HasAlignedTexelWritebacks => _alignedTexelWrites.HasAny;

        private unsafe Auto<DisposableBufferView> CreateViewDirect(VkFormat format, int offset, int size)
        {
            BufferViewCreateInfo bufferViewCreateInfo = new()
            {
                SType = StructureType.BufferViewCreateInfo,
                Buffer = new VkBuffer(_bufferHandle),
                Format = format,
                Offset = (uint)offset,
                Range = (uint)size,
            };

            _gd.Api.CreateBufferView(_device, in bufferViewCreateInfo, null, out BufferView bufferView).ThrowOnError();

            return new Auto<DisposableBufferView>(new DisposableBufferView(_gd.Api, _device, bufferView), this, _waitable, _buffer);
        }

        private void AddAlignedTexelViewInvalidate(Action invalidateView)
        {
            if (invalidateView != null)
            {
                (_alignedTexelViewInvalidates ??= []).Add(invalidateView);
            }
        }

        internal void InvalidateAlignedTexelViews()
        {
            if (_alignedTexelViewInvalidates == null)
            {
                return;
            }

            foreach (Action invalidateView in _alignedTexelViewInvalidates)
            {
                invalidateView();
            }

            _alignedTexelViewInvalidates = null;
        }

        internal void FlushAlignedTexelWrites()
        {
            // 只消费 armed 账——pending 账对应的 draw/dispatch 还没被 GPU 写过，不能提前拷回。
            List<AlignedTexelWritebackQueue<Auto<DisposableBuffer>>.Entry> writes =
                _alignedTexelWrites.TakeArmed();

            if (writes == null)
            {
                return;
            }

            _gd.PipelineInternal.EndRenderPass();
            S2APipelineDiagnostics.ReportAlignedTexelEndRenderPass();
            S2APipelineDiagnostics.ReportAlignedTexelWriteback(writes.Count);

            CommandBufferScoped cbs = _gd.PipelineInternal.CurrentCommandBuffer;

            foreach (AlignedTexelWritebackQueue<Auto<DisposableBuffer>>.Entry write in writes)
            {
                Copy(_gd, cbs, write.Shadow, _buffer, 0, write.SrcOffset, write.Size);
                write.Shadow.Dispose();

                // Writing the source back invalidates cached copies of that range
                // (other converted buffers, texel shadows) the same way SignalWrite does.
                _cachedConvertedBuffers.ClearRange(write.SrcOffset, write.Size);
            }
        }

        private void FlushAlignedTexelWritesAndWait(int offset, int size)
        {
            if (!_alignedTexelWrites.HasAny)
            {
                return;
            }

            if (_gd.CommandBufferPool.OwnedByCurrentThread)
            {
                FlushAlignedTexelWrites();
                _gd.FlushAllCommands();
            }
            else if (_alignedTexelWrites.HasArmed)
            {
                // 修复②：armed 账对应的写命令录在渲染线程还没提交的命令缓冲里。
                // 后台池上的拷贝会抢在 draw/dispatch 之前跑、把还没写过的影子拷回源；
                // 这里不静默拷贝、不改 _cachedConvertedBuffers——报红，等渲染线程落账。
                Logger.Error?.Print(LogClass.Gpu,
                    "【红】后台线程访问挂着未落账 texel 写回的缓冲：渲染线程还没提交写命令，" +
                    "后台静默拷贝会拷到旧数据——等渲染线程在下个 draw/dispatch 或 EndRenderPass 落账后再读。");
                throw new InvalidOperationException(
                    "Pending aligned texel write-back cannot be flushed from a background thread.");
            }

            WaitForFences(offset, size);
        }

        public unsafe void InsertBarrier(CommandBuffer commandBuffer, bool isWrite)
        {
            // If the last access is write, we always need a barrier to be sure we will read or modify
            // the correct data.
            // If the last access is read, and current one is a write, we need to wait until the
            // read finishes to avoid overwriting data still in use.
            // Otherwise, if the last access is a read and the current one too, we don't need barriers.
            bool needsBarrier = isWrite || _lastAccessIsWrite;

            _lastAccessIsWrite = isWrite;

            if (needsBarrier)
            {
                MemoryBarrier memoryBarrier = new()
                {
                    SType = StructureType.MemoryBarrier,
                    SrcAccessMask = DefaultAccessFlags,
                    DstAccessMask = DefaultAccessFlags,
                };

                _gd.Api.CmdPipelineBarrier(
                    commandBuffer,
                    PipelineStageFlags.AllCommandsBit,
                    PipelineStageFlags.AllCommandsBit,
                    DependencyFlags.DeviceGroupBit,
                    1,
                    in memoryBarrier,
                    0,
                    null,
                    0,
                    null);
            }
        }

        private static ulong ToMirrorKey(int offset, int size)
        {
            return ((ulong)offset << 32) | (uint)size;
        }

        private static (int offset, int size) FromMirrorKey(ulong key)
        {
            return ((int)(key >> 32), (int)key);
        }

        private unsafe bool TryGetMirror(CommandBufferScoped cbs, ref int offset, int size, out Auto<DisposableBuffer> buffer)
        {
            size = Math.Min(size, Size - offset);

            // Does this binding need to be mirrored?

            if (!_pendingDataRanges.OverlapsWith(offset, size))
            {
                buffer = null;
                return false;
            }

            ulong key = ToMirrorKey(offset, size);

            if (_mirrors.TryGetValue(key, out StagingBufferReserved reserved))
            {
                buffer = reserved.Buffer.GetBuffer();
                offset = reserved.Offset;

                return true;
            }

            // Is this mirror allowed to exist? Can't be used for write in any in-flight write.
            if (_waitable.IsBufferRangeInUse(offset, size, true))
            {
                // Some of the data is not mirrorable, so upload the whole range.
                ClearMirrors(cbs, offset, size);

                buffer = null;
                return false;
            }

            // Build data for the new mirror.

            Span<byte> baseData = new((void*)(_map + offset), size);
            Span<byte> modData = _pendingData.AsSpan(offset, size);

            StagingBufferReserved? newMirror = _gd.BufferManager.StagingBuffer.TryReserveData(cbs, size);

            if (newMirror != null)
            {
                StagingBufferReserved mirror = newMirror.Value;
                _pendingDataRanges.FillData(baseData, modData, offset, new Span<byte>((void*)(mirror.Buffer._map + mirror.Offset), size));

                if (_mirrors.Count == 0)
                {
                    _gd.PipelineInternal.RegisterActiveMirror(this);
                }

                _mirrors.Add(key, mirror);

                buffer = mirror.Buffer.GetBuffer();
                offset = mirror.Offset;

                return true;
            }
            else
            {
                // Data could not be placed on the mirror, likely out of space. Force the data to flush.
                ClearMirrors(cbs, offset, size);

                buffer = null;
                return false;
            }
        }

        public Auto<DisposableBuffer> GetBuffer()
        {
            FlushAlignedTexelWrites();

            return _buffer;
        }

        public Auto<DisposableBuffer> GetBuffer(CommandBuffer commandBuffer, bool isWrite = false, bool isSSBO = false)
        {
            FlushAlignedTexelWrites();

            if (isWrite)
            {
                SignalWrite(0, Size);
            }

            return _buffer;
        }

        public Auto<DisposableBuffer> GetBuffer(CommandBuffer commandBuffer, int offset, int size, bool isWrite = false)
        {
            FlushAlignedTexelWrites();

            if (isWrite)
            {
                SignalWrite(offset, size);
            }

            return _buffer;
        }

        public Auto<DisposableBuffer> GetMirrorable(CommandBufferScoped cbs, ref int offset, int size, out bool mirrored)
        {
            FlushAlignedTexelWrites();

            if (_pendingData != null && TryGetMirror(cbs, ref offset, size, out Auto<DisposableBuffer> result))
            {
                mirrored = true;
                return result;
            }

            mirrored = false;
            return _buffer;
        }

        Auto<DisposableBufferView> IMirrorable<DisposableBufferView>.GetMirrorable(CommandBufferScoped cbs, ref int offset, int size, out bool mirrored)
        {
            // Cannot mirror buffer views right now.

            throw new NotImplementedException();
        }

        public void ClearMirrors()
        {
            // Clear mirrors without forcing a flush. This happens when the command buffer is switched,
            // as all reserved areas on the staging buffer are released.

            if (_pendingData != null)
            {
                _mirrors.Clear();
            }
        }

        public void ClearMirrors(CommandBufferScoped cbs, int offset, int size)
        {
            // Clear mirrors in the given range, and submit overlapping pending data.

            if (_pendingData != null)
            {
                bool hadMirrors = _mirrors.Count > 0 && RemoveOverlappingMirrors(offset, size);

                if (_pendingDataRanges.Count() != 0)
                {
                    UploadPendingData(cbs, offset, size);
                }

                if (hadMirrors)
                {
                    _gd.PipelineInternal.Rebind(_buffer, offset, size);
                }
            }
        }

        public void UseMirrors()
        {
            _useMirrors = true;
        }

        private void UploadPendingData(CommandBufferScoped cbs, int offset, int size)
        {
            List<BufferMirrorRangeList.Range> ranges = _pendingDataRanges.FindOverlaps(offset, size);

            if (ranges != null)
            {
                _pendingDataRanges.Remove(offset, size);

                foreach (BufferMirrorRangeList.Range range in ranges)
                {
                    int rangeOffset = Math.Max(offset, range.Offset);
                    int rangeSize = Math.Min(offset + size, range.End) - rangeOffset;

                    if (_gd.PipelineInternal.CurrentCommandBuffer.CommandBuffer.Handle == cbs.CommandBuffer.Handle)
                    {
                        SetData(rangeOffset, _pendingData.AsSpan(rangeOffset, rangeSize), cbs, _gd.PipelineInternal.EndRenderPassDelegate, false);
                    }
                    else
                    {
                        SetData(rangeOffset, _pendingData.AsSpan(rangeOffset, rangeSize), cbs, null, false);
                    }
                }
            }
        }

        public Auto<MemoryAllocation> GetAllocation()
        {
            return _allocationAuto;
        }

        public (DeviceMemory, ulong) GetDeviceMemoryAndOffset()
        {
            return (_allocation.Memory, _allocation.Offset);
        }

        public void SignalWrite(int offset, int size)
        {
            FlushAlignedTexelWrites();

            if (offset == 0 && size == Size)
            {
                _cachedConvertedBuffers.Clear();
            }
            else
            {
                _cachedConvertedBuffers.ClearRange(offset, size);
            }
        }

        public BufferHandle Handle
        {
            get
            {
                ulong handle = _bufferHandle;
                return Unsafe.As<ulong, BufferHandle>(ref handle);
            }  
        }

        public nint Map(int offset, int mappingSize)
        {
            FlushAlignedTexelWritesAndWait(offset, mappingSize);

            return _map;
        }

        private void ClearFlushFence()
        {
            // Assumes _flushLock is held as writer.

            if (_flushFence != null)
            {
                if (_flushWaiting == 0)
                {
                    _flushFence.Put();
                }

                _flushFence = null;
            }
        }

        private void WaitForFlushFence()
        {
            if (_flushFence == null)
            {
                return;
            }

            // If storage has changed, make sure the fence has been reached so that the data is in place.
            _flushLock.ExitReadLock();
            _flushLock.EnterWriteLock();

            if (_flushFence != null)
            {
                FenceHolder fence = _flushFence;
                Interlocked.Increment(ref _flushWaiting);

                // Don't wait in the lock.

                _flushLock.ExitWriteLock();

                fence.Wait();

                _flushLock.EnterWriteLock();

                if (Interlocked.Decrement(ref _flushWaiting) == 0)
                {
                    fence.Put();
                }

                _flushFence = null;
            }

            // Assumes the _flushLock is held as reader, returns in same state.
            _flushLock.ExitWriteLock();
            _flushLock.EnterReadLock();
        }

        public PinnedSpan<byte> GetData(int offset, int size)
        {
            _flushLock.EnterReadLock();

            WaitForFlushFence();

            FlushAlignedTexelWritesAndWait(offset, size);

            Span<byte> result;

            if (_map != nint.Zero)
            {
                result = GetDataStorage(offset, size);

                // Need to be careful here, the buffer can't be unmapped while the data is being used.
                _buffer.IncrementReferenceCount();

                _flushLock.ExitReadLock();

                return PinnedSpan<byte>.UnsafeFromSpan(result, _decrementReferenceCount);
            }

            BackgroundResource resource = _gd.BackgroundResources.Get();

            if (_gd.CommandBufferPool.OwnedByCurrentThread)
            {
                _gd.FlushAllCommands();

                result = resource.GetFlushBuffer().GetBufferData(_gd.CommandBufferPool, this, offset, size);
            }
            else
            {
                result = resource.GetFlushBuffer().GetBufferData(resource.GetPool(), this, offset, size);
            }

            _flushLock.ExitReadLock();

            // Flush buffer is pinned until the next GetBufferData on the thread, which is fine for current uses.
            return PinnedSpan<byte>.UnsafeFromSpan(result);
        }

        public unsafe Span<byte> GetDataStorage(int offset, int size)
        {
            FlushAlignedTexelWritesAndWait(offset, size);

            int mappingSize = Math.Min(size, Size - offset);

            if (_map != nint.Zero)
            {
                return new Span<byte>((void*)(_map + offset), mappingSize);
            }

            throw new InvalidOperationException("The buffer is not host mapped.");
        }

        public bool RemoveOverlappingMirrors(int offset, int size)
        {
            List<ulong> toRemove = null;
            foreach (ulong key in _mirrors.Keys)
            {
                (int keyOffset, int keySize) = FromMirrorKey(key);
                if (!(offset + size <= keyOffset || offset >= keyOffset + keySize))
                {
                    toRemove ??= [];

                    toRemove.Add(key);
                }
            }

            if (toRemove != null)
            {
                foreach (ulong key in toRemove)
                {
                    _mirrors.Remove(key);
                }

                return true;
            }

            return false;
        }

        public unsafe void SetData(int offset, ReadOnlySpan<byte> data, CommandBufferScoped? cbs = null, Action endRenderPass = null, bool allowCbsWait = true)
        {
            int dataSize = Math.Min(data.Length, Size - offset);
            if (dataSize == 0)
            {
                return;
            }

            FlushAlignedTexelWrites();

            bool allowMirror = _useMirrors && allowCbsWait && cbs != null && _activeType <= BufferAllocationType.HostMapped;

            if (_map != nint.Zero)
            {
                // If persistently mapped, set the data directly if the buffer is not currently in use.
                bool isRented = _buffer.HasRentedCommandBufferDependency(_gd.CommandBufferPool);

                // If the buffer is rented, take a little more time and check if the use overlaps this handle.
                bool needsFlush = isRented && _waitable.IsBufferRangeInUse(offset, dataSize, false);

                if (!needsFlush)
                {
                    WaitForFences(offset, dataSize);

                    data[..dataSize].CopyTo(new Span<byte>((void*)(_map + offset), dataSize));

                    if (_pendingData != null)
                    {
                        bool removed = _pendingDataRanges.Remove(offset, dataSize);
                        if (RemoveOverlappingMirrors(offset, dataSize) || removed)
                        {
                            // If any mirrors were removed, rebind the buffer range.
                            _gd.PipelineInternal.Rebind(_buffer, offset, dataSize);
                        }
                    }

                    SignalWrite(offset, dataSize);

                    return;
                }
            }

            // If the buffer does not have an in-flight write (including an inline update), then upload data to a pendingCopy.
            if (allowMirror && !_waitable.IsBufferRangeInUse(offset, dataSize, true))
            {
                if (_pendingData == null)
                {
                    _pendingData = new byte[Size];
                    _mirrors = new Dictionary<ulong, StagingBufferReserved>();
                }

                data[..dataSize].CopyTo(_pendingData.AsSpan(offset, dataSize));
                _pendingDataRanges.Add(offset, dataSize);

                // Remove any overlapping mirrors.
                RemoveOverlappingMirrors(offset, dataSize);

                // Tell the graphics device to rebind any constant buffer that overlaps the newly modified range, as it should access a mirror.
                _gd.PipelineInternal.Rebind(_buffer, offset, dataSize);

                return;
            }

            if (_pendingData != null)
            {
                _pendingDataRanges.Remove(offset, dataSize);
            }

            if (cbs != null &&
                _gd.PipelineInternal.RenderPassActive &&
                !(_buffer.HasCommandBufferDependency(cbs.Value) &&
                _waitable.IsBufferRangeInUse(cbs.Value.CommandBufferIndex, offset, dataSize)))
            {
                // If the buffer hasn't been used on the command buffer yet, try to preload the data.
                // This avoids ending and beginning render passes on each buffer data upload.

                cbs = _gd.PipelineInternal.GetPreloadCommandBuffer();
                endRenderPass = null;
            }

            if (cbs == null ||
                !VulkanConfiguration.UseFastBufferUpdates ||
                data.Length > MaxUpdateBufferSize ||
                !TryPushData(cbs.Value, endRenderPass, offset, data))
            {
                if (allowCbsWait)
                {
                    _gd.BufferManager.StagingBuffer.PushData(_gd.CommandBufferPool, cbs, endRenderPass, this, offset, data);
                }
                else
                {
                    bool rentCbs = cbs == null;
                    if (rentCbs)
                    {
                        cbs = _gd.CommandBufferPool.Rent();
                    }

                    if (!_gd.BufferManager.StagingBuffer.TryPushData(cbs.Value, endRenderPass, this, offset, data))
                    {
                        // Need to do a slow upload.
                        BufferHolder srcHolder = _gd.BufferManager.Create(_gd, dataSize, baseType: BufferAllocationType.HostMapped);
                        srcHolder.SetDataUnchecked(0, data);

                        Auto<DisposableBuffer> srcBuffer = srcHolder.GetBuffer();
                        Auto<DisposableBuffer> dstBuffer = this.GetBuffer(cbs.Value.CommandBuffer, true);

                        Copy(_gd, cbs.Value, srcBuffer, dstBuffer, 0, offset, dataSize);

                        srcHolder.Dispose();
                    }

                    if (rentCbs)
                    {
                        cbs.Value.Dispose();
                    }
                }
            }
        }

        public unsafe void SetDataUnchecked(int offset, ReadOnlySpan<byte> data)
        {
            int dataSize = Math.Min(data.Length, Size - offset);
            if (dataSize == 0)
            {
                return;
            }

            FlushAlignedTexelWritesAndWait(offset, dataSize);

            if (_map != nint.Zero)
            {
                data[..dataSize].CopyTo(new Span<byte>((void*)(_map + offset), dataSize));
            }
            else
            {
                _gd.BufferManager.StagingBuffer.PushData(_gd.CommandBufferPool, null, null, this, offset, data);
            }
        }

        public unsafe void SetDataUnchecked<T>(int offset, ReadOnlySpan<T> data) where T : unmanaged
        {
            SetDataUnchecked(offset, MemoryMarshal.AsBytes(data));
        }

        public void SetDataInline(CommandBufferScoped cbs, Action endRenderPass, int dstOffset, ReadOnlySpan<byte> data)
        {
            if (!TryPushData(cbs, endRenderPass, dstOffset, data))
            {
                throw new ArgumentException($"Invalid offset 0x{dstOffset:X} or data size 0x{data.Length:X}.");
            }
        }

        private unsafe bool TryPushData(CommandBufferScoped cbs, Action endRenderPass, int dstOffset, ReadOnlySpan<byte> data)
        {
            if ((dstOffset & 3) != 0 || (data.Length & 3) != 0)
            {
                return false;
            }

            endRenderPass?.Invoke();

            VkBuffer dstBuffer = GetBuffer(cbs.CommandBuffer, dstOffset, data.Length, true).Get(cbs, dstOffset, data.Length, true).Value;

            InsertBufferBarrier(
                _gd,
                cbs.CommandBuffer,
                dstBuffer,
                DefaultAccessFlags,
                AccessFlags.TransferWriteBit,
                PipelineStageFlags.AllCommandsBit,
                PipelineStageFlags.TransferBit,
                dstOffset,
                data.Length);

            fixed (byte* pData = data)
            {
                for (ulong offset = 0; offset < (ulong)data.Length;)
                {
                    ulong size = Math.Min(MaxUpdateBufferSize, (ulong)data.Length - offset);
                    _gd.Api.CmdUpdateBuffer(cbs.CommandBuffer, dstBuffer, (ulong)dstOffset + offset, size, pData + offset);
                    offset += size;
                }
            }

            InsertBufferBarrier(
                _gd,
                cbs.CommandBuffer,
                dstBuffer,
                AccessFlags.TransferWriteBit,
                DefaultAccessFlags,
                PipelineStageFlags.TransferBit,
                PipelineStageFlags.AllCommandsBit,
                dstOffset,
                data.Length);

            return true;
        }

        public static unsafe void Copy(
            VulkanRenderer gd,
            CommandBufferScoped cbs,
            Auto<DisposableBuffer> src,
            Auto<DisposableBuffer> dst,
            int srcOffset,
            int dstOffset,
            int size,
            bool registerSrcUsage = true)
        {
            VkBuffer srcBuffer = registerSrcUsage ? src.Get(cbs, srcOffset, size).Value : src.GetUnsafe().Value;
            VkBuffer dstBuffer = dst.Get(cbs, dstOffset, size, true).Value;

            // Internal buffer merges and virtual-buffer copies can consume GPU-written data
            // without a guest barrier. Make those writes visible to this transfer read.
            InsertBufferBarrier(
                gd,
                cbs.CommandBuffer,
                srcBuffer,
                AccessFlags.MemoryWriteBit,
                AccessFlags.TransferReadBit,
                PipelineStageFlags.AllCommandsBit,
                PipelineStageFlags.TransferBit,
                srcOffset,
                size);

            InsertBufferBarrier(
                gd,
                cbs.CommandBuffer,
                dstBuffer,
                DefaultAccessFlags,
                AccessFlags.TransferWriteBit,
                PipelineStageFlags.AllCommandsBit,
                PipelineStageFlags.TransferBit,
                dstOffset,
                size);

            BufferCopy region = new((ulong)srcOffset, (ulong)dstOffset, (ulong)size);

            gd.Api.CmdCopyBuffer(cbs.CommandBuffer, srcBuffer, dstBuffer, 1, &region);

            InsertBufferBarrier(
                gd,
                cbs.CommandBuffer,
                dstBuffer,
                AccessFlags.TransferWriteBit,
                DefaultAccessFlags,
                PipelineStageFlags.TransferBit,
                PipelineStageFlags.AllCommandsBit,
                dstOffset,
                size);
        }

        public static unsafe void InsertBufferBarrier(
            VulkanRenderer gd,
            CommandBuffer commandBuffer,
            VkBuffer buffer,
            AccessFlags srcAccessMask,
            AccessFlags dstAccessMask,
            PipelineStageFlags srcStageMask,
            PipelineStageFlags dstStageMask,
            int offset,
            int size)
        {
            BufferMemoryBarrier memoryBarrier = new()
            {
                SType = StructureType.BufferMemoryBarrier,
                SrcAccessMask = srcAccessMask,
                DstAccessMask = dstAccessMask,
                SrcQueueFamilyIndex = Vk.QueueFamilyIgnored,
                DstQueueFamilyIndex = Vk.QueueFamilyIgnored,
                Buffer = buffer,
                Offset = (ulong)offset,
                Size = (ulong)size,
            };

            gd.Api.CmdPipelineBarrier(
                commandBuffer,
                srcStageMask,
                dstStageMask,
                0,
                0,
                null,
                1,
                in memoryBarrier,
                0,
                null);
        }

        public void WaitForFences()
        {
            _waitable.WaitForFences(_gd.Api, _device);
        }

        public void WaitForFences(int offset, int size)
        {
            _waitable.WaitForFences(_gd.Api, _device, offset, size);
        }

        private bool BoundToRange(int offset, ref int size)
        {
            if (offset >= Size)
            {
                return false;
            }

            size = Math.Min(Size - offset, size);

            return true;
        }

        public Auto<DisposableBuffer> GetBufferI8ToI16(CommandBufferScoped cbs, int offset, int size)
        {
            FlushAlignedTexelWrites();

            if (!BoundToRange(offset, ref size))
            {
                return null;
            }

            I8ToI16CacheKey key = new(_gd);

            if (!_cachedConvertedBuffers.TryGetValue(offset, size, key, out BufferHolder holder))
            {
                holder = _gd.BufferManager.Create(_gd, (size * 2 + 3) & ~3, baseType: BufferAllocationType.DeviceLocal);

                _gd.PipelineInternal.EndRenderPass();
                _gd.HelperShader.ConvertI8ToI16(_gd, cbs, this, holder, offset, size);

                key.SetBuffer(holder.GetBuffer());

                _cachedConvertedBuffers.Add(offset, size, key, holder);
            }

            return holder.GetBuffer();
        }

        public Auto<DisposableBuffer> GetAlignedVertexBuffer(CommandBufferScoped cbs, int offset, int size, int stride, int alignment)
        {
            FlushAlignedTexelWrites();

            if (!BoundToRange(offset, ref size))
            {
                return null;
            }

            AlignedVertexBufferCacheKey key = new(_gd, stride, alignment);

            if (!_cachedConvertedBuffers.TryGetValue(offset, size, key, out BufferHolder holder))
            {
                int alignedStride = (stride + (alignment - 1)) & -alignment;

                holder = _gd.BufferManager.Create(_gd, (size / stride) * alignedStride, baseType: BufferAllocationType.DeviceLocal);

                _gd.PipelineInternal.EndRenderPass();
                _gd.HelperShader.ChangeStride(_gd, cbs, this, holder, offset, size, stride, alignedStride);

                key.SetBuffer(holder.GetBuffer());

                _cachedConvertedBuffers.Add(offset, size, key, holder);
            }

            return holder.GetBuffer();
        }

        public Auto<DisposableBuffer> GetBufferTopologyConversion(CommandBufferScoped cbs, int offset, int size, IndexBufferPattern pattern, int indexSize)
        {
            FlushAlignedTexelWrites();

            if (!BoundToRange(offset, ref size))
            {
                return null;
            }

            TopologyConversionCacheKey key = new(_gd, pattern, indexSize);

            if (!_cachedConvertedBuffers.TryGetValue(offset, size, key, out BufferHolder holder))
            {
                // The destination index size is always I32.

                int indexCount = size / indexSize;

                int convertedCount = pattern.GetConvertedCount(indexCount);

                holder = _gd.BufferManager.Create(_gd, convertedCount * 4, baseType: BufferAllocationType.DeviceLocal);

                _gd.PipelineInternal.EndRenderPass();
                _gd.HelperShader.ConvertIndexBuffer(_gd, cbs, this, holder, pattern, indexSize, offset, indexCount);

                key.SetBuffer(holder.GetBuffer());

                _cachedConvertedBuffers.Add(offset, size, key, holder);
            }

            return holder.GetBuffer();
        }

        public bool TryGetCachedConvertedBuffer(int offset, int size, ICacheKey key, out BufferHolder holder)
        {
            return _cachedConvertedBuffers.TryGetValue(offset, size, key, out holder);
        }

        public void AddCachedConvertedBuffer(int offset, int size, ICacheKey key, BufferHolder holder)
        {
            _cachedConvertedBuffers.Add(offset, size, key, holder);
        }

        public void AddCachedConvertedBufferDependency(int offset, int size, ICacheKey key, Dependency dependency)
        {
            _cachedConvertedBuffers.AddDependency(offset, size, key, dependency);
        }

        public void RemoveCachedConvertedBuffer(int offset, int size, ICacheKey key)
        {
            _cachedConvertedBuffers.Remove(offset, size, key);
        }

        public void Dispose()
        {
            _gd.PipelineInternal?.FlushCommandsIfWeightExceeding(_buffer, (ulong)Size);

            List<AlignedTexelWritebackQueue<Auto<DisposableBuffer>>.Entry> writes = _alignedTexelWrites.TakeAll();
            if (writes != null)
            {
                foreach (AlignedTexelWritebackQueue<Auto<DisposableBuffer>>.Entry write in writes)
                {
                    write.Shadow.Dispose();
                }
            }

            _buffer.Dispose();
            _cachedConvertedBuffers.Dispose();
            if (_allocationImported)
            {
                _allocationAuto.DecrementReferenceCount();
            }
            else
            {
                _allocationAuto?.Dispose();
            }

            _flushLock.EnterWriteLock();

            ClearFlushFence();

            _flushLock.ExitWriteLock();
        }
    }
}
