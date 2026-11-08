using Ryujinx.Graphics.GAL;
using Ryujinx.Memory.Range;
using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;

namespace Ryujinx.Graphics.Gpu.Memory
{
    /// <summary>
    /// Buffer cache.
    /// </summary>
    class BufferCache : IDisposable
    {
        /// <summary>
        /// Initial size for the array holding overlaps.
        /// </summary>
        public const int OverlapsBufferInitialCapacity = 10;

        /// <summary>
        /// Maximum size that an array holding overlaps may have after trimming.
        /// </summary>
        public const int OverlapsBufferMaxCapacity = 10000;

        private const ulong BufferAlignmentSize = 0x1000;
        private const ulong BufferAlignmentMask = BufferAlignmentSize - 1;

        /// <summary>
        /// Alignment required for sparse buffer mappings.
        /// </summary>
        public const ulong SparseBufferAlignmentSize = 0x10000;

        private const ulong MaxDynamicGrowthSize = 0x100000;

        private readonly GpuContext _context;
        private readonly PhysicalMemory _physicalMemory;

        /// <remarks>
        /// Only modified from the GPU thread. Must lock for add/remove.
        /// Must lock for any access from other threads.
        /// </remarks>
        private readonly NonOverlappingRangeList<Buffer> _buffers;

        // S2A：缓冲查找的「最近命中」表（按查询地址的页号直接映射）。稳态每次绘制都要按物理地址查缓冲两次
        // （绑定时 CreateBufferAligned 查重叠、提交时 GetBuffer / SynchronizeBufferRange 找所在缓冲），区间表是二分查找 + 泛型接口比较，AOT 下不内联：
        // 旧库 10-19 测试机1 真机符号化 GPU 线程约 18%。命中条件 = 代数号相同且该缓冲完整包含所查区间——此时原代码查到的也只能是它
        // （区间表互不重叠）。_buffers 每次增删（只有两个 CreateBufferAligned 里的 4 处）代数号加一，整表作废。
        private const int S2ALookupBits = 10;
        private readonly S2ALookupEntry[] _s2aLookup = new S2ALookupEntry[1 << S2ALookupBits];
        private uint _s2aGen = 1;

        private struct S2ALookupEntry
        {
            public ulong Start;
            public ulong End;
            public Buffer Buffer;
            public uint Gen;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private Buffer S2ALookup(ulong address, ulong size)
        {
            ref S2ALookupEntry e = ref _s2aLookup[(int)(address >> 12) & ((1 << S2ALookupBits) - 1)];
            return e.Gen == _s2aGen && address >= e.Start && address + size <= e.End ? e.Buffer : null;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private void S2ARemember(ulong address, ulong size, Buffer buffer)
        {
            if (buffer != null && address >= buffer.Address && address + size <= buffer.EndAddress)
            {
                _s2aLookup[(int)(address >> 12) & ((1 << S2ALookupBits) - 1)] = new S2ALookupEntry { Start = buffer.Address, End = buffer.EndAddress, Buffer = buffer, Gen = _s2aGen };
            }
        }

        private readonly MultiRangeList<MultiRangeBuffer> _multiRangeBuffers;

        private readonly Dictionary<ulong, BufferCacheEntry> _dirtyCache;
        private readonly Dictionary<ulong, BufferCacheEntry> _modifiedCache;
        private bool _pruneCaches;
        private int _virtualModifiedSequenceNumber;

        public event Action NotifyBuffersModified;

        /// <summary>
        /// Creates a new instance of the buffer manager.
        /// </summary>
        /// <param name="context">The GPU context that the buffer manager belongs to</param>
        /// <param name="physicalMemory">Physical memory where the cached buffers are mapped</param>
        public BufferCache(GpuContext context, PhysicalMemory physicalMemory)
        {
            _context = context;
            _physicalMemory = physicalMemory;

            _buffers = [];
            _multiRangeBuffers = [];

            _dirtyCache = new Dictionary<ulong, BufferCacheEntry>();

            // There are a lot more entries on the modified cache, so it is separate from the one for ForceDirty.
            _modifiedCache = new Dictionary<ulong, BufferCacheEntry>();
        }

        /// <summary>
        /// Handles removal of buffers written to a memory region being unmapped.
        /// </summary>
        /// <param name="sender">Sender object</param>
        /// <param name="e">Event arguments</param>
        public void MemoryUnmappedHandler(object sender, UnmapEventArgs e)
        {
            MultiRange range = ((MemoryManager)sender).GetPhysicalRegions(e.Address, e.Size);

            for (int index = 0; index < range.Count; index++)
            {
                MemoryRange subRange = range.GetSubRange(index);

                ReadOnlySpan<Buffer> overlaps = _buffers.FindOverlapsAsSpan(subRange.Address, subRange.Size);

                for (int i = 0; i < overlaps.Length; i++)
                {
                    overlaps[i].Unmapped(subRange.Address, subRange.Size);
                }
            }
        }

        /// <summary>
        /// Performs address translation of the GPU virtual address, and creates a
        /// new buffer, if needed, for the specified contiguous range.
        /// </summary>
        /// <param name="memoryManager">GPU memory manager where the buffer is mapped</param>
        /// <param name="gpuVa">Start GPU virtual address of the buffer</param>
        /// <param name="size">Size in bytes of the buffer</param>
        /// <param name="stage">The type of usage that created the buffer</param>
        /// <returns>Contiguous physical range of the buffer, after address translation</returns>
        public MultiRange TranslateAndCreateBuffer(MemoryManager memoryManager, ulong gpuVa, ulong size, BufferStage stage)
        {
            if (gpuVa == 0)
            {
                return new MultiRange(MemoryManager.PteUnmapped, size);
            }

            ulong address = memoryManager.Translate(gpuVa);

            if (address != MemoryManager.PteUnmapped)
            {
                CreateBuffer(address, size, stage);
            }

            return new MultiRange(address, size);
        }

        /// <summary>
        /// Performs address translation of the GPU virtual address, and creates
        /// new physical and virtual buffers, if needed, for the specified range.
        /// </summary>
        /// <param name="memoryManager">GPU memory manager where the buffer is mapped</param>
        /// <param name="gpuVa">Start GPU virtual address of the buffer</param>
        /// <param name="size">Size in bytes of the buffer</param>
        /// <param name="stage">The type of usage that created the buffer</param>
        /// <returns>Physical ranges of the buffer, after address translation</returns>
        public MultiRange TranslateAndCreateMultiBuffers(MemoryManager memoryManager, ulong gpuVa, ulong size, BufferStage stage)
        {
            if (gpuVa == 0 || size == 0)
            {
                return new MultiRange(MemoryManager.PteUnmapped, size);
            }

            // Fast path not taken for non-contiguous ranges,
            // since multi-range buffers are not coalesced, so a buffer that covers
            // the entire cached range might not actually exist.
            if (memoryManager.VirtualRangeCache.TryGetOrAddRange(gpuVa, size, out MultiRange range) &&
                range.Count == 1)
            {
                return range;
            }

            CreateBuffer(range, stage);

            return range;
        }

        /// <summary>
        /// Performs address translation of the GPU virtual address, and creates
        /// new physical buffers, if needed, for the specified range.
        /// </summary>
        /// <param name="memoryManager">GPU memory manager where the buffer is mapped</param>
        /// <param name="gpuVa">Start GPU virtual address of the buffer</param>
        /// <param name="size">Size in bytes of the buffer</param>
        /// <param name="stage">The type of usage that created the buffer</param>
        /// <returns>Physical ranges of the buffer, after address translation</returns>
        public MultiRange TranslateAndCreateMultiBuffersPhysicalOnly(MemoryManager memoryManager, ulong gpuVa, ulong size, BufferStage stage)
        {
            if (gpuVa == 0)
            {
                return new MultiRange(MemoryManager.PteUnmapped, size);
            }

            // Fast path not taken for non-contiguous ranges,
            // since multi-range buffers are not coalesced, so a buffer that covers
            // the entire cached range might not actually exist.
            if (memoryManager.VirtualRangeCache.TryGetOrAddRange(gpuVa, size, out MultiRange range) &&
                range.Count == 1)
            {
                return range;
            }

            for (int i = 0; i < range.Count; i++)
            {
                MemoryRange subRange = range.GetSubRange(i);

                if (subRange.Address != MemoryManager.PteUnmapped)
                {
                    if (range.Count > 1)
                    {
                        CreateBuffer(subRange.Address, subRange.Size, stage, SparseBufferAlignmentSize);
                    }
                    else
                    {
                        CreateBuffer(subRange.Address, subRange.Size, stage);
                    }
                }
            }

            return range;
        }

        /// <summary>
        /// Creates a new buffer for the specified range, if it does not yet exist.
        /// This can be used to ensure the existance of a buffer.
        /// </summary>
        /// <param name="range">Physical ranges of memory where the buffer data is located</param>
        /// <param name="stage">The type of usage that created the buffer</param>
        public void CreateBuffer(MultiRange range, BufferStage stage)
        {
            if (range.Count > 1)
            {
                CreateMultiRangeBuffer(range, stage);
            }
            else
            {
                MemoryRange subRange = range.GetSubRange(0);

                if (subRange.Address != MemoryManager.PteUnmapped)
                {
                    CreateBuffer(subRange.Address, subRange.Size, stage);
                }
            }
        }

        /// <summary>
        /// Creates a new buffer for the specified range, if it does not yet exist.
        /// This can be used to ensure the existance of a buffer.
        /// </summary>
        /// <param name="address">Address of the buffer in memory</param>
        /// <param name="size">Size of the buffer in bytes</param>
        /// <param name="stage">The type of usage that created the buffer</param>
        public void CreateBuffer(ulong address, ulong size, BufferStage stage)
        {
            ulong endAddress = address + size;

            ulong alignedAddress = address & ~BufferAlignmentMask;
            ulong alignedEndAddress = (endAddress + BufferAlignmentMask) & ~BufferAlignmentMask;

            // The buffer must have the size of at least one page.
            if (alignedEndAddress == alignedAddress)
            {
                alignedEndAddress += BufferAlignmentSize;
            }

            CreateBufferAligned(alignedAddress, alignedEndAddress - alignedAddress, stage);
        }

        /// <summary>
        /// Creates a new buffer for the specified range, if it does not yet exist.
        /// This can be used to ensure the existance of a buffer.
        /// </summary>
        /// <param name="address">Address of the buffer in memory</param>
        /// <param name="size">Size of the buffer in bytes</param>
        /// <param name="stage">The type of usage that created the buffer</param>
        /// <param name="alignment">Alignment of the start address of the buffer in bytes</param>
        public void CreateBuffer(ulong address, ulong size, BufferStage stage, ulong alignment)
        {
            ulong alignmentMask = alignment - 1;
            ulong pageAlignmentMask = BufferAlignmentMask;
            ulong endAddress = address + size;

            ulong alignedAddress = address & ~alignmentMask;
            ulong alignedEndAddress = (endAddress + pageAlignmentMask) & ~pageAlignmentMask;

            // The buffer must have the size of at least one page.
            if (alignedEndAddress == alignedAddress)
            {
                alignedEndAddress += pageAlignmentMask;
            }

            CreateBufferAligned(alignedAddress, alignedEndAddress - alignedAddress, stage, alignment);
        }

        /// <summary>
        /// Creates a buffer for a memory region composed of multiple physical ranges,
        /// if it does not exist yet.
        /// </summary>
        /// <param name="range">Physical ranges of memory</param>
        /// <param name="stage">The type of usage that created the buffer</param>
        private void CreateMultiRangeBuffer(MultiRange range, BufferStage stage)
        {
            // Ensure all non-contiguous buffer we might use are sparse aligned.
            for (int i = 0; i < range.Count; i++)
            {
                MemoryRange subRange = range.GetSubRange(i);

                if (subRange.Address != MemoryManager.PteUnmapped)
                {
                    CreateBuffer(subRange.Address, subRange.Size, stage, SparseBufferAlignmentSize);
                }
            }

            // Create sparse buffer.
            MultiRangeBuffer[] overlaps = new MultiRangeBuffer[10];

            int overlapCount = _multiRangeBuffers.FindOverlaps(range, ref overlaps);

            for (int index = 0; index < overlapCount; index++)
            {
                if (overlaps[index].Range.Contains(range))
                {
                    return;
                }
            }

            for (int index = 0; index < overlapCount; index++)
            {
                if (range.Contains(overlaps[index].Range))
                {
                    _multiRangeBuffers.Remove(overlaps[index]);
                    overlaps[index].Dispose();
                }
            }

            MultiRangeBuffer multiRangeBuffer;

            MemoryRange[] alignedSubRanges = new MemoryRange[range.Count];

            ulong alignmentMask = SparseBufferAlignmentSize - 1;

            // S2A（银河2 崩溃根修 10-28）：VirtualRangeCache 不再把不对齐的多段压成一段，这里接住——
            // 稀疏缓冲只收 64 KB 对齐的段；不对齐的走拷贝式，并按真实分段建（对齐外扩会让 FindOffset 对不上请求区间）
            bool sparseAligned = VirtualRangeCache.IsSparseAligned(range);

            if (_context.Capabilities.SupportsSparseBuffer && sparseAligned)
            {
                BufferRange[] storages = new BufferRange[range.Count];

                for (int i = 0; i < range.Count; i++)
                {
                    MemoryRange subRange = range.GetSubRange(i);

                    if (subRange.Address != MemoryManager.PteUnmapped)
                    {
                        ulong endAddress = subRange.Address + subRange.Size;

                        ulong alignedAddress = subRange.Address & ~alignmentMask;
                        ulong alignedEndAddress = (endAddress + alignmentMask) & ~alignmentMask;
                        ulong alignedSize = alignedEndAddress - alignedAddress;

                        Buffer buffer = _buffers.FindOverlap(alignedAddress, alignedSize);

                        // S2A：已映射子段的物理缓冲上面 CreateBuffer 刚建过；查不到 = 缓冲表不一致，
                        //   报红带地址/大小，不返回假缓冲
                        if (buffer == null)
                        {
                            throw new InvalidOperationException($"S2A buffer cache inconsistent: no physical buffer for mapped range 0x{alignedAddress:X}+0x{alignedSize:X}");
                        }

                        BufferRange bufferRange = buffer.GetRange(alignedAddress, alignedSize, false);

                        alignedSubRanges[i] = new MemoryRange(alignedAddress, alignedSize);
                        storages[i] = bufferRange;
                    }
                    else
                    {
                        ulong alignedSize = (subRange.Size + alignmentMask) & ~alignmentMask;

                        alignedSubRanges[i] = new MemoryRange(MemoryManager.PteUnmapped, alignedSize);
                        storages[i] = new BufferRange(BufferHandle.Null, 0, (int)alignedSize);
                    }
                }

                multiRangeBuffer = new(_context, new MultiRange(alignedSubRanges), storages);
            }
            else
            {
                for (int i = 0; i < range.Count; i++)
                {
                    MemoryRange subRange = range.GetSubRange(i);

                    if (!sparseAligned)
                    {
                        alignedSubRanges[i] = subRange;
                    }
                    else if (subRange.Address != MemoryManager.PteUnmapped)
                    {
                        ulong endAddress = subRange.Address + subRange.Size;

                        ulong alignedAddress = subRange.Address & ~alignmentMask;
                        ulong alignedEndAddress = (endAddress + alignmentMask) & ~alignmentMask;
                        ulong alignedSize = alignedEndAddress - alignedAddress;

                        alignedSubRanges[i] = new MemoryRange(alignedAddress, alignedSize);
                    }
                    else
                    {
                        ulong alignedSize = (subRange.Size + alignmentMask) & ~alignmentMask;

                        alignedSubRanges[i] = new MemoryRange(MemoryManager.PteUnmapped, alignedSize);
                    }
                }

                multiRangeBuffer = new(_context, new MultiRange(alignedSubRanges));

                UpdateVirtualBufferDependencies(multiRangeBuffer);
            }

            _multiRangeBuffers.Add(multiRangeBuffer);
        }

        /// <summary>
        /// Adds two-way dependencies to all physical buffers contained within a given virtual buffer.
        /// </summary>
        /// <param name="virtualBuffer">Virtual buffer to have dependencies added</param>
        private void UpdateVirtualBufferDependencies(MultiRangeBuffer virtualBuffer)
        {
            virtualBuffer.ClearPhysicalDependencies();

            ulong dstOffset = 0;

            HashSet<Buffer> physicalBuffers = [];

            for (int i = 0; i < virtualBuffer.Range.Count; i++)
            {
                MemoryRange subRange = virtualBuffer.Range.GetSubRange(i);

                if (subRange.Address != MemoryManager.PteUnmapped)
                {
                    Buffer buffer = _buffers.FindOverlap(subRange.Address, subRange.Size);

                    // S2A：已映射子段的物理缓冲上面 CreateBuffer 刚建过；查不到 = 缓冲表不一致，
                    //   报红带地址/大小，不返回假缓冲（BotW 9400 NRE 顶帧）
                    if (buffer == null)
                    {
                        throw new InvalidOperationException($"S2A buffer cache inconsistent: no physical buffer for mapped range 0x{subRange.Address:X}+0x{subRange.Size:X}");
                    }

                    virtualBuffer.AddPhysicalDependency(buffer, subRange.Address, dstOffset, subRange.Size);
                    physicalBuffers.Add(buffer);
                }

                dstOffset += subRange.Size;
            }

            foreach (Buffer buffer in physicalBuffers)
            {
                buffer.CopyToDependantVirtualBuffer(virtualBuffer);
            }
        }

        /// <summary>
        /// Performs address translation of the GPU virtual address, and attempts to force
        /// the buffer in the region as dirty.
        /// The buffer lookup for this function is cached in a dictionary for quick access, which
        /// accelerates common UBO updates.
        /// </summary>
        /// <param name="memoryManager">GPU memory manager where the buffer is mapped</param>
        /// <param name="gpuVa">Start GPU virtual address of the buffer</param>
        /// <param name="size">Size in bytes of the buffer</param>
        public void ForceDirty(MemoryManager memoryManager, ulong gpuVa, ulong size)
        {
            if (_pruneCaches)
            {
                Prune();
            }

            if (!_dirtyCache.TryGetValue(gpuVa, out BufferCacheEntry result) ||
                result.EndGpuAddress < gpuVa + size ||
                result.UnmappedSequence != result.Buffer.UnmappedSequence)
            {
                MultiRange range = TranslateAndCreateBuffer(memoryManager, gpuVa, size, BufferStage.Internal);
                ulong address = range.GetSubRange(0).Address;
                result = new BufferCacheEntry(address, gpuVa, GetBuffer(address, size, BufferStage.Internal));

                _dirtyCache[gpuVa] = result;
            }

            result.Buffer.ForceDirty(result.Address, size);
        }

        /// <summary>
        /// Checks if the given buffer range has been GPU modifed.
        /// </summary>
        /// <param name="memoryManager">GPU memory manager where the buffer is mapped</param>
        /// <param name="gpuVa">Start GPU virtual address of the buffer</param>
        /// <param name="size">Size in bytes of the buffer</param>
        /// <returns>True if modified, false otherwise</returns>
        public bool CheckModified(MemoryManager memoryManager, ulong gpuVa, ulong size, out ulong outAddr)
        {
            if (_pruneCaches)
            {
                Prune();
            }

            // Align the address to avoid creating too many entries on the quick lookup dictionary.
            ulong mask = BufferAlignmentMask;
            ulong alignedGpuVa = gpuVa & (~mask);
            ulong alignedEndGpuVa = (gpuVa + size + mask) & (~mask);

            size = alignedEndGpuVa - alignedGpuVa;

            if (!_modifiedCache.TryGetValue(alignedGpuVa, out BufferCacheEntry result) ||
                result.EndGpuAddress < alignedEndGpuVa ||
                result.UnmappedSequence != result.Buffer.UnmappedSequence)
            {
                MultiRange range = TranslateAndCreateBuffer(memoryManager, alignedGpuVa, size, BufferStage.None);
                ulong address = range.GetSubRange(0).Address;
                result = new BufferCacheEntry(address, alignedGpuVa, GetBuffer(address, size, BufferStage.None));

                _modifiedCache[alignedGpuVa] = result;
            }

            outAddr = result.Address | (gpuVa & mask);

            return result.Buffer.IsModified(result.Address, size);
        }

        /// <summary>
        /// Creates a new buffer for the specified range, if needed.
        /// If a buffer where this range can be fully contained already exists,
        /// then the creation of a new buffer is not necessary.
        /// </summary>
        /// <param name="address">Address of the buffer in guest memory</param>
        /// <param name="size">Size in bytes of the buffer</param>
        /// <param name="stage">The type of usage that created the buffer</param>
        private void CreateBufferAligned(ulong address, ulong size, BufferStage stage)
        {
            if (S2ALookup(address, size) != null) // S2A：已有缓冲完整包含该区间——原代码此时什么也不做
            {
                return;
            }

            ReadOnlySpan<Buffer> overlaps = _buffers.FindOverlapsAsSpan(address, size);

            if (overlaps.Length == 1)
            {
                S2ARemember(address, size, overlaps[0]); // S2A：只在完整包含时记（此时下面的判断不成立，不动缓冲表）
            }

            // S2A：顺序流式写的新区间（10-23 暗黑2 稳态：全新缓冲 99% 是 ≤4K、紧贴已有缓冲末尾，存活缓冲 589→1120 只增不减，
            //   随后又被跨多段的区间合并重建）。没有重叠、但前 2 页内正好有缓冲结束（中间空隙已映射），且新区间连空隙不超过 2 页
            //   （= 下面合并分支的 1.5 倍预扩条件）→ 区间并上那块缓冲：走合并 + 预扩，之后的顺序小区间落进预扩出的部分，不再各建一个小缓冲。
            //   大于 2 页的不这样做：合并不预扩时每次都要整块拷旧缓冲，顺序大块会变成平方级拷贝
            if (overlaps.Length == 0 && address >= BufferAlignmentSize * 2)
            {
                ReadOnlySpan<Buffer> prev = _buffers.FindOverlapsAsSpan(address - BufferAlignmentSize * 2, BufferAlignmentSize * 2);

                if (prev.Length != 0 && prev[^1].EndAddress <= address && address + size - prev[^1].EndAddress <= BufferAlignmentSize * 2 &&
                    (prev[^1].EndAddress == address || _physicalMemory.IsRangeMapped(prev[^1].EndAddress, address - prev[^1].EndAddress)))
                {
                    // 请求区间起点拉回那块缓冲的起点：两者真正重叠，下面预扩后按新区间重查重叠时一定查得到它（不拉回会查空、取 overlaps[0] 越界）
                    ulong reqEnd = address + size;
                    address = prev[^1].Address;
                    size = reqEnd - address;
                    overlaps = _buffers.FindOverlapsAsSpan(address, size);
                }
            }

            if (overlaps.Length != 0)
            {
                // The buffer already exists. We can just return the existing buffer
                // if the buffer we need is fully contained inside the overlapping buffer.
                // Otherwise, we must delete the overlapping buffers and create a bigger buffer
                // that fits all the data we need. We also need to copy the contents from the
                // old buffer(s) to the new buffer.

                ulong endAddress = address + size;

                if (overlaps[0].Address > address || overlaps[0].EndAddress < endAddress)
                {
                    bool anySparseCompatible = false;

                    // Check if the following conditions are met:
                    // - We have a single overlap.
                    // - The overlap starts at or before the requested range. That is, the overlap happens at the end.
                    // - The size delta between the new, merged buffer and the old one is of at most 2 pages.
                    // In this case, we attempt to extend the buffer further than the requested range,
                    // this can potentially avoid future resizes if the application keeps using overlapping
                    // sequential memory.
                    // Allowing for 2 pages (rather than just one) is necessary to catch cases where the
                    // range crosses a page, and after alignment, ends having a size of 2 pages.
                    if (overlaps.Length == 1 &&
                        address >= overlaps[0].Address &&
                        endAddress - overlaps[0].EndAddress <= BufferAlignmentSize * 2)
                    {
                        // Try to grow the buffer by 1.5x of its current size.
                        // This improves performance in the cases where the buffer is resized often by small amounts.
                        ulong existingSize = overlaps[0].Size;
                        ulong growthSize = (existingSize + Math.Min(existingSize >> 1, MaxDynamicGrowthSize)) & ~BufferAlignmentMask;

                        // S2A：预扩（只是少重建缓冲的启发式）不得伸进客体没映射的内存。原版假定客体地址空间整块可访问（PC 上是），
                        // 我们直通客体内存，没映射的页不可访问：旧库 10-19 巫师3 / 丝之歌扩出的尾巴在建缓冲时被整段同步读，SIGBUS。
                        if (growthSize > size && !_physicalMemory.IsRangeMapped(address, growthSize))
                        {
                            growthSize = size;
                        }

                        size = Math.Max(size, growthSize);
                        endAddress = address + size;

                        overlaps = _buffers.FindOverlapsAsSpan(address, size);
                    }
                    
                    address = Math.Min(address, overlaps[0].Address);
                    endAddress = Math.Max(endAddress, overlaps[^1].EndAddress);
                    
                    for (int i = 0; i < overlaps.Length; i++)
                    {
                        anySparseCompatible |= overlaps[i].SparseCompatible;
                    }

                    Buffer[] overlapsArray = overlaps.ToArray();
                    
                    _s2aGen++; // S2A：缓冲表要变，最近命中表作废
                    _buffers.RemoveRange(overlaps[0], overlaps[^1]);
                    
                    ulong newSize = endAddress - address;

                    CreateBufferAligned(address, newSize, stage, anySparseCompatible, overlapsArray);
                }
            }
            else
            {
                // No overlap, just create a new buffer.
                _s2aGen++; // S2A
                _buffers.Add(new(_context, _physicalMemory, address, size, stage, sparseCompatible: false, []));
            }
        }

        /// <summary>
        /// Creates a new buffer for the specified range, if needed.
        /// If a buffer where this range can be fully contained already exists,
        /// then the creation of a new buffer is not necessary.
        /// </summary>
        /// <param name="address">Address of the buffer in guest memory</param>
        /// <param name="size">Size in bytes of the buffer</param>
        /// <param name="stage">The type of usage that created the buffer</param>
        /// <param name="alignment">Alignment of the start address of the buffer</param>
        private void CreateBufferAligned(ulong address, ulong size, BufferStage stage, ulong alignment)
        {
            bool sparseAligned = alignment >= SparseBufferAlignmentSize;
            
            ReadOnlySpan<Buffer> overlaps = _buffers.FindOverlapsAsSpan(address, size);

            if (overlaps.Length != 0)
            {
                // If the buffer already exists, make sure if covers the entire range,
                // and make sure it is properly aligned, otherwise sparse mapping may fail.

                ulong endAddress = address + size;

                if (overlaps[0].Address > address ||
                    overlaps[0].EndAddress < endAddress ||
                    (overlaps[0].Address & (alignment - 1)) != 0 ||
                    (!overlaps[0].SparseCompatible && sparseAligned))
                {
                    // We need to make sure the new buffer is properly aligned.
                    // However, after the range is aligned, it is possible that it
                    // overlaps more buffers, so try again after each extension
                    // and ensure we cover all overlaps.

                    endAddress = Math.Max(endAddress, overlaps[^1].EndAddress);
                    int oldOverlapCount;
                    
                    do
                    {
                        address = Math.Min(address, overlaps[0].Address);
                        endAddress = Math.Max(endAddress, overlaps[^1].EndAddress);

                        address &= ~(alignment - 1);

                        oldOverlapCount = overlaps.Length;
                        overlaps = _buffers.FindOverlapsAsSpan(address, endAddress - address);
                    }
                    while (oldOverlapCount != overlaps.Length);

                    ulong newSize = endAddress - address;
                    
                    Buffer[] overlapsArray = overlaps.ToArray();
                    
                    _s2aGen++; // S2A：缓冲表要变，最近命中表作废
                    _buffers.RemoveRange(overlaps[0], overlaps[^1]);
                    
                    CreateBufferAligned(address, newSize, stage, sparseAligned, overlapsArray);
                }
            }
            else
            {
                // No overlap, just create a new buffer.
                _s2aGen++; // S2A
                _buffers.Add(new(_context, _physicalMemory, address, size, stage, sparseAligned, []));
            } 
        }

        /// <summary>
        /// Creates a new buffer for the specified range, if needed.
        /// If a buffer where this range can be fully contained already exists,
        /// then the creation of a new buffer is not necessary.
        /// </summary>
        /// <param name="address">Address of the buffer in guest memory</param>
        /// <param name="size">Size in bytes of the buffer</param>
        /// <param name="stage">The type of usage that created the buffer</param>
        /// <param name="sparseCompatible">Indicates if the buffer can be used in a sparse buffer mapping</param>
        /// <param name="overlaps">Buffers overlapping the range</param>
        private Buffer CreateBufferAligned(ulong address, ulong size, BufferStage stage, bool sparseCompatible, Buffer[] overlaps)
        {
            long s2aA = S2AAllocTrace.Mark();   // S2A：新建缓冲分段（0x40_0029–0x40_002c，帧率能耗线 10-22 巫师3 换场景分配）
            Buffer newBuffer = new(_context, _physicalMemory, address, size, stage, sparseCompatible, overlaps);
            S2AAllocTrace.Step(0x40_0029, ref s2aA);

            // S2A：新缓冲先入表再做下面的活——CopyTo / SynchronizeMemory / RecreateMultiRangeBuffers 都会
            //   回到缓冲表（重建多段缓冲会对同段地址 CreateBuffer）。先入表让任何重入都看到一致表；
            //   否则空窗里建出的缓冲与本缓冲重叠，「互不重叠」表被破坏，之后 FindOverlap 拿空 → NRE
            //   （BotW 8E/9000/9400 generic READY+~70s 根因：两条 CreateBufferAligned 合并分支同此窗）
            _buffers.Add(newBuffer);

            for (int index = 0; index < overlaps.Length; index++)
            {
                Buffer buffer = overlaps[index];

                int dstOffset = (int)(buffer.Address - newBuffer.Address);

                buffer.CopyTo(newBuffer, dstOffset);
                newBuffer.InheritModifiedRanges(buffer);

                buffer.DecrementReferenceCount();
            }

            S2AAllocTrace.Step(0x40_002a, ref s2aA);
            newBuffer.SynchronizeMemory(address, size);
            S2AAllocTrace.Step(0x40_002b, ref s2aA);

            // Existing buffers were modified, we need to rebind everything.
            NotifyBuffersModified?.Invoke();

            RecreateMultiRangeBuffers(address, size);
            S2AAllocTrace.Step(0x40_002c, ref s2aA);
            
            return newBuffer;
        }

        /// <summary>
        /// Recreates all the multi-range buffers that overlaps a given physical memory range.
        /// </summary>
        /// <param name="address">Start address of the range</param>
        /// <param name="size">Size of the range in bytes</param>
        private void RecreateMultiRangeBuffers(ulong address, ulong size)
        {
            if ((address & (SparseBufferAlignmentSize - 1)) != 0 || (size & (SparseBufferAlignmentSize - 1)) != 0)
            {
                return;
            }

            MultiRangeBuffer[] overlaps = new MultiRangeBuffer[10];

            int overlapCount = _multiRangeBuffers.FindOverlaps(address, size, ref overlaps);

            for (int index = 0; index < overlapCount; index++)
            {
                _multiRangeBuffers.Remove(overlaps[index]);
                overlaps[index].Dispose();
            }

            for (int index = 0; index < overlapCount; index++)
            {
                CreateMultiRangeBuffer(overlaps[index].Range, BufferStage.None);
            }
        }

        /// <summary>
        /// Copy a buffer data from a given address to another.
        /// </summary>
        /// <remarks>
        /// This does a GPU side copy.
        /// </remarks>
        /// <param name="memoryManager">GPU memory manager where the buffer is mapped</param>
        /// <param name="srcVa">GPU virtual address of the copy source</param>
        /// <param name="dstVa">GPU virtual address of the copy destination</param>
        /// <param name="size">Size in bytes of the copy</param>
        public void CopyBuffer(MemoryManager memoryManager, ulong srcVa, ulong dstVa, ulong size)
        {
            MultiRange srcRange = TranslateAndCreateMultiBuffersPhysicalOnly(memoryManager, srcVa, size, BufferStage.Copy);
            MultiRange dstRange = TranslateAndCreateMultiBuffersPhysicalOnly(memoryManager, dstVa, size, BufferStage.Copy);

            if (srcRange.Count == 1 && dstRange.Count == 1)
            {
                CopyBufferSingleRange(memoryManager, srcRange.GetSubRange(0).Address, dstRange.GetSubRange(0).Address, size);
            }
            else
            {
                ulong copiedSize = 0;
                ulong srcOffset = 0;
                ulong dstOffset = 0;
                int srcRangeIndex = 0;
                int dstRangeIndex = 0;

                while (copiedSize < size)
                {
                    if (srcRange.GetSubRange(srcRangeIndex).Size == srcOffset)
                    {
                        srcRangeIndex++;
                        srcOffset = 0;
                    }

                    if (dstRange.GetSubRange(dstRangeIndex).Size == dstOffset)
                    {
                        dstRangeIndex++;
                        dstOffset = 0;
                    }

                    MemoryRange srcSubRange = srcRange.GetSubRange(srcRangeIndex);
                    MemoryRange dstSubRange = dstRange.GetSubRange(dstRangeIndex);

                    ulong srcSize = srcSubRange.Size - srcOffset;
                    ulong dstSize = dstSubRange.Size - dstOffset;
                    ulong copySize = Math.Min(srcSize, dstSize);

                    CopyBufferSingleRange(memoryManager, srcSubRange.Address + srcOffset, dstSubRange.Address + dstOffset, copySize);

                    srcOffset += copySize;
                    dstOffset += copySize;
                    copiedSize += copySize;
                }
            }
        }

        /// <summary>
        /// Copy a buffer data from a given address to another.
        /// </summary>
        /// <remarks>
        /// This does a GPU side copy.
        /// </remarks>
        /// <param name="memoryManager">GPU memory manager where the buffer is mapped</param>
        /// <param name="srcAddress">Physical address of the copy source</param>
        /// <param name="dstAddress">Physical address of the copy destination</param>
        /// <param name="size">Size in bytes of the copy</param>
        private void CopyBufferSingleRange(MemoryManager memoryManager, ulong srcAddress, ulong dstAddress, ulong size)
        {
            Buffer srcBuffer = GetBuffer(srcAddress, size, BufferStage.Copy);
            Buffer dstBuffer = GetBuffer(dstAddress, size, BufferStage.Copy);

            int srcOffset = (int)(srcAddress - srcBuffer.Address);
            int dstOffset = (int)(dstAddress - dstBuffer.Address);

            _context.Renderer.Pipeline.CopyBuffer(
                srcBuffer.Handle,
                dstBuffer.Handle,
                srcOffset,
                dstOffset,
                (int)size);

            if (srcBuffer.IsModified(srcAddress, size))
            {
                dstBuffer.SignalModified(dstAddress, size, BufferStage.Copy);
            }
            else
            {
                // Optimization: If the data being copied is already in memory, then copy it directly instead of flushing from GPU.

                dstBuffer.ClearModified(dstAddress, size);
                memoryManager.Physical.WriteTrackedResource(dstAddress, memoryManager.Physical.GetSpan(srcAddress, (int)size), ResourceKind.Buffer);
            }

            dstBuffer.CopyToDependantVirtualBuffers(dstAddress, size);
        }

        /// <summary>
        /// S2A（帧率能耗线 10-22）：把贴图第 0 层第 0 级在 GPU 上拷进 dstVa 起 size 字节的缓冲（行跨度 stride），目标缓冲标成 GPU 改过——
        /// CPU 真读到时才按缓冲回写（与 CopyBufferSingleRange 同一套记账）。目标跨多段物理区间时返回 false，调用方走原路径
        /// </summary>
        public bool S2ACopyTextureToBuffer(MemoryManager memoryManager, ITexture texture, ulong dstVa, ulong size, int stride)
        {
            MultiRange range = TranslateAndCreateMultiBuffersPhysicalOnly(memoryManager, dstVa, size, BufferStage.Copy);

            if (range.Count != 1 || range.GetSubRange(0).Address == MemoryManager.PteUnmapped)
            {
                return false;
            }

            ulong address = range.GetSubRange(0).Address;
            Buffer buffer = GetBuffer(address, size, BufferStage.Copy);

            texture.CopyTo(new BufferRange(buffer.Handle, (int)(address - buffer.Address), (int)size, true), 0, 0, stride);

            buffer.SignalModified(address, size, BufferStage.Copy);
            buffer.CopyToDependantVirtualBuffers(address, size);

            // 游戏读这份 GPU 读回结果前必须先回写：写跟踪缺省只拦写不拦读，原先（补丁 0153 起）游戏能拿到新值全靠恰好有信号量写把同页整页回写，
            // 游戏若在那之前读 1x1 亮度就读到旧值——八方2 自动曝光偶发整屏偏红 / 橙色过曝（10-22 jhz 实机 octopath2_1022230148_2 R184，Mac 局同类）。
            // 登记成定向读时回写页（与开不开信号量精确写无关），游戏读时先回写，同 0153 之前 CPU 当场读回的语义
            MemoryManager.S2AMarkReadFlush(address, size);

            return true;
        }

        /// <summary>
        /// S2A：物理区间上有没有 GPU 改过、还没回写的缓冲数据（按字节区间判，不按页）。只在 GPU 线程调、零分配
        /// </summary>
        public bool S2AHasGpuModified(ulong address, ulong size)
        {
            foreach (Buffer buffer in _buffers.FindOverlapsAsSpan(address, size))
            {
                if (buffer.IsModified(address, size))
                {
                    return true;
                }
            }

            return false;
        }

        /// <summary>
        /// Clears a buffer at a given address with the specified value.
        /// </summary>
        /// <remarks>
        /// Both the address and size must be aligned to 4 bytes.
        /// </remarks>
        /// <param name="memoryManager">GPU memory manager where the buffer is mapped</param>
        /// <param name="gpuVa">GPU virtual address of the region to clear</param>
        /// <param name="size">Number of bytes to clear</param>
        /// <param name="value">Value to be written into the buffer</param>
        public void ClearBuffer(MemoryManager memoryManager, ulong gpuVa, ulong size, uint value)
        {
            MultiRange range = TranslateAndCreateMultiBuffersPhysicalOnly(memoryManager, gpuVa, size, BufferStage.Copy);

            for (int index = 0; index < range.Count; index++)
            {
                MemoryRange subRange = range.GetSubRange(index);
                Buffer buffer = GetBuffer(subRange.Address, subRange.Size, BufferStage.Copy);

                int offset = (int)(subRange.Address - buffer.Address);

                _context.Renderer.Pipeline.ClearBuffer(buffer.Handle, offset, (int)subRange.Size, value);

                memoryManager.Physical.FillTrackedResource(subRange.Address, subRange.Size, value, ResourceKind.Buffer);

                buffer.CopyToDependantVirtualBuffers(subRange.Address, subRange.Size);
            }
        }

        /// <summary>
        /// Gets a buffer sub-range starting at a given memory address, aligned to the next page boundary.
        /// </summary>
        /// <param name="range">Physical regions of memory where the buffer is mapped</param>
        /// <param name="stage">Buffer stage that triggered the access</param>
        /// <param name="write">Whether the buffer will be written to by this use</param>
        /// <returns>The buffer sub-range starting at the given memory address</returns>
        public BufferRange GetBufferRangeAligned(MultiRange range, BufferStage stage, bool write = false)
        {
            if (range.Count > 1)
            {
                return GetBuffer(range, stage, write).GetRange(range);
            }
            else
            {
                MemoryRange subRange = range.GetSubRange(0);
                return GetBuffer(subRange.Address, subRange.Size, stage, write).GetRangeAligned(subRange.Address, subRange.Size, write);
            }
        }

        /// <summary>
        /// Gets a buffer sub-range for a given memory range.
        /// </summary>
        /// <param name="range">Physical regions of memory where the buffer is mapped</param>
        /// <param name="stage">Buffer stage that triggered the access</param>
        /// <param name="write">Whether the buffer will be written to by this use</param>
        /// <returns>The buffer sub-range for the given range</returns>
        public BufferRange GetBufferRange(MultiRange range, BufferStage stage, bool write = false)
        {
            if (range.Count > 1)
            {
                return GetBuffer(range, stage, write).GetRange(range);
            }
            else
            {
                MemoryRange subRange = range.GetSubRange(0);
                return GetBuffer(subRange.Address, subRange.Size, stage, write).GetRange(subRange.Address, subRange.Size, write);
            }
        }

        /// <summary>
        /// Gets a buffer for a given memory range.
        /// A buffer overlapping with the specified range is assumed to already exist on the cache.
        /// </summary>
        /// <param name="range">Physical regions of memory where the buffer is mapped</param>
        /// <param name="stage">Buffer stage that triggered the access</param>
        /// <param name="write">Whether the buffer will be written to by this use</param>
        /// <returns>The buffer where the range is fully contained</returns>
        private MultiRangeBuffer GetBuffer(MultiRange range, BufferStage stage, bool write = false)
        {
            for (int i = 0; i < range.Count; i++)
            {
                MemoryRange subRange = range.GetSubRange(i);

                // S2A：多段里的未映射段是洞不是缺登记——建缓冲时按同一哨兵跳过（CreateMultiRangeBuffer /
                // UpdateVirtualBufferDependencies），这里对它 FindOverlap(ulong.MaxValue) 必得空，跳过
                if (subRange.Address == MemoryManager.PteUnmapped)
                {
                    continue;
                }

                Buffer subBuffer = _buffers.FindOverlap(subRange.Address, subRange.Size);

                // S2A：已映射子段必有物理缓冲（TranslateAndCreate* 已建）；查不到 = 缓冲表不一致，
                //   报红带地址/大小，不静默跳过、不返回假缓冲（BotW 9000 NRE 顶帧）
                if (subBuffer == null)
                {
                    throw new InvalidOperationException($"S2A buffer cache inconsistent: no physical buffer for mapped range 0x{subRange.Address:X}+0x{subRange.Size:X}");
                }

                subBuffer.SynchronizeMemory(subRange.Address, subRange.Size);

                if (write)
                {
                    subBuffer.SignalModified(subRange.Address, subRange.Size, stage);
                }
            }

            MultiRangeBuffer[] overlaps = new MultiRangeBuffer[10];

            int overlapCount = _multiRangeBuffers.FindOverlaps(range, ref overlaps);

            MultiRangeBuffer buffer = null;

            for (int i = 0; i < overlapCount; i++)
            {
                if (overlaps[i].Range.Contains(range))
                {
                    buffer = overlaps[i];
                    break;
                }
            }

            // S2A：CreateBuffer 走过的区间必有完整覆盖它的多段缓冲；查不到 = 缓冲表不一致，报红不返回空
            if (buffer == null)
            {
                throw new InvalidOperationException($"S2A buffer cache inconsistent: no virtual buffer contains range {range}");
            }

            if (write && !buffer.IsSparse)
            {
                buffer.AddModifiedRegion(range, ++_virtualModifiedSequenceNumber);
            }

            return buffer;
        }

        /// <summary>
        /// Gets a buffer for a given memory range.
        /// A buffer overlapping with the specified range is assumed to already exist on the cache.
        /// </summary>
        /// <param name="address">Start address of the memory range</param>
        /// <param name="size">Size in bytes of the memory range</param>
        /// <param name="stage">Buffer stage that triggered the access</param>
        /// <param name="write">Whether the buffer will be written to by this use</param>
        /// <returns>The buffer where the range is fully contained</returns>
        private Buffer GetBuffer(ulong address, ulong size, BufferStage stage, bool write = false)
        {
            Buffer buffer;

            if (size != 0)
            {
                buffer = S2ALookup(address, size); // S2A：最近命中
                if (buffer == null)
                {
                    buffer = _buffers.FindOverlap(address, size);
                    S2ARemember(address, size, buffer);
                }

                // S2A：调用方契约是「该区间已有缓冲」；查不到 = 缓冲表不一致，
                //   报红带地址/大小，不返回假缓冲
                if (buffer == null)
                {
                    throw new InvalidOperationException($"S2A buffer cache inconsistent: no buffer for range 0x{address:X}+0x{size:X}");
                }

                buffer.CopyFromDependantVirtualBuffers();
                buffer.SynchronizeMemory(address, size);

                if (write)
                {
                    buffer.SignalModified(address, size, stage);
                }
            }
            else
            {
                buffer = _buffers.FindOverlapFast(address, 1);
            }

            return buffer;
        }

        /// <summary>
        /// Performs guest to host memory synchronization of a given memory range.
        /// </summary>
        /// <param name="range">Physical regions of memory where the buffer is mapped</param>
        public void SynchronizeBufferRange(MultiRange range)
        {
            if (range.Count == 1)
            {
                MemoryRange subRange = range.GetSubRange(0);
                SynchronizeBufferRange(subRange.Address, subRange.Size, copyBackVirtual: true);
            }
            else
            {
                for (int index = 0; index < range.Count; index++)
                {
                    MemoryRange subRange = range.GetSubRange(index);
                    SynchronizeBufferRange(subRange.Address, subRange.Size, copyBackVirtual: false);
                }
            }
        }

        /// <summary>
        /// Performs guest to host memory synchronization of a given memory range.
        /// </summary>
        /// <param name="address">Start address of the memory range</param>
        /// <param name="size">Size in bytes of the memory range</param>
        /// <param name="copyBackVirtual">Whether virtual buffers that uses this buffer as backing memory should have its data copied back if modified</param>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private void SynchronizeBufferRange(ulong address, ulong size, bool copyBackVirtual)
        {
            if (size != 0)
            {
                Buffer buffer = S2ALookup(address, size); // S2A：最近命中（与 GetBuffer 同口径：只在完整包含时命中）
                if (buffer == null)
                {
                    buffer = _buffers.FindOverlap(address, size);
                    S2ARemember(address, size, buffer);
                }

                // S2A：与 GetBuffer 同一契约——查不到 = 缓冲表不一致，报红带地址/大小
                if (buffer == null)
                {
                    throw new InvalidOperationException($"S2A buffer cache inconsistent: no buffer for range 0x{address:X}+0x{size:X}");
                }

                if (copyBackVirtual)
                {
                    buffer.CopyFromDependantVirtualBuffers();
                }

                buffer.SynchronizeMemory(address, size);
            }
        }

        /// <summary>
        /// Signal that the given buffer's handle has changed,
        /// forcing rebind and any overlapping multi-range buffers to be recreated.
        /// </summary>
        /// <param name="buffer">The buffer that has changed handle</param>
        // S2A 缓冲零拷贝：引擎写到的零拷贝缓冲标成待降级（见 PhysicalMemory.S2AEngineWrote）
        internal void S2AEngineWrote(ulong address, ulong size)
        {
            foreach (Buffer buffer in _buffers.FindOverlapsAsSpan(address, size))
            {
                buffer.S2AMarkEngineWritten();
            }
        }

        public void BufferBackingChanged(Buffer buffer)
        {
            NotifyBuffersModified?.Invoke();

            RecreateMultiRangeBuffers(buffer.Address, buffer.Size);
        }

        /// <summary>
        /// Prune any invalid entries from a quick access dictionary.
        /// </summary>
        /// <param name="dictionary">Dictionary to prune</param>
        /// <param name="toDelete">List used to track entries to delete</param>
        private static void Prune(Dictionary<ulong, BufferCacheEntry> dictionary, ref List<ulong> toDelete)
        {
            foreach (KeyValuePair<ulong, BufferCacheEntry> entry in dictionary)
            {
                if (entry.Value.UnmappedSequence != entry.Value.Buffer.UnmappedSequence)
                {
                    (toDelete ??= []).Add(entry.Key);
                }
            }

            if (toDelete != null)
            {
                foreach (ulong entry in toDelete)
                {
                    dictionary.Remove(entry);
                }
            }
        }

        /// <summary>
        /// Prune any invalid entries from the quick access dictionaries.
        /// </summary>
        private void Prune()
        {
            List<ulong> toDelete = null;

            Prune(_dirtyCache, ref toDelete);

            toDelete?.Clear();

            Prune(_modifiedCache, ref toDelete);

            _pruneCaches = false;
        }

        /// <summary>
        /// Queues a prune of invalid entries the next time a dictionary cache is accessed.
        /// </summary>
        public void QueuePrune()
        {
            _pruneCaches = true;
        }

        /// <summary>
        /// Disposes all buffers in the cache.
        /// It's an error to use the buffer cache after disposal.
        /// </summary>
        public void Dispose()
        {
            lock (_buffers)
            {
                foreach (Buffer buffer in _buffers)
                {
                    buffer.Dispose();
                }
            }
        }
    }
}
