using Ryujinx.Common.Memory;
using Ryujinx.Cpu;
using Ryujinx.Graphics.Device;
using Ryujinx.Graphics.Gpu.Image;
using Ryujinx.Graphics.Gpu.Shader;
using Ryujinx.Memory;
using Ryujinx.Memory.Range;
using Ryujinx.Memory.Tracking;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;

namespace Ryujinx.Graphics.Gpu
{
    public static class S2AGpuCaps
    {
        // Set by the platform before GPU initialization.
        public static bool WritebackRequireProvider { get; set; }
    }

}

namespace Ryujinx.Graphics.Gpu.Memory
{
    /// <summary>
    /// Represents physical memory, accessible from the GPU.
    /// This is actually working CPU virtual addresses, of memory mapped on the application process.
    /// </summary>
    class PhysicalMemory : IDisposable
    {
        private readonly GpuContext _context;
        private readonly IVirtualMemoryManagerTracked _cpuMemory;
        private int _referenceCount;
        private S2ABufferReadScratch _s2aBufferReadScratch;
        // 复用委托：稳态回写不因方法组转换每次分配
        private readonly Action<ulong, Memory<byte>> _s2aReadForWriteback;
        // 仅供主机负控：老的借页直读。目标页受保护时必缺页（AV），生产不得选到。
        private static readonly bool S2AWritebackBorrowedReadOn = Environment.GetEnvironmentVariable("S2A_WRITEBACK_BORROWED_READ") == "1";
        private static int _s2aWritebackBorrowedRed;

        /// <summary>
        /// In-memory shader cache.
        /// </summary>
        public ShaderCache ShaderCache { get; }

        /// <summary>
        /// GPU buffer manager.
        /// </summary>
        public BufferCache BufferCache { get; }

        /// <summary>
        /// GPU texture manager.
        /// </summary>
        public TextureCache TextureCache { get; }

        /// <summary>
        /// Creates a new instance of the physical memory.
        /// </summary>
        /// <param name="context">GPU context that the physical memory belongs to</param>
        /// <param name="cpuMemory">CPU memory manager of the application process</param>
        public PhysicalMemory(GpuContext context, IVirtualMemoryManagerTracked cpuMemory)
        {
            _context = context;
            _cpuMemory = cpuMemory;
            _s2aReadForWriteback = S2AReadForWriteback;
            ShaderCache = new ShaderCache(context);
            BufferCache = new BufferCache(context, this);
            TextureCache = new TextureCache(context, this);

            if (cpuMemory is IRefCounted rc)
            {
                rc.IncrementReferenceCount();
            }

            _referenceCount = 1;
        }

        /// <summary>
        /// Increments the memory reference count.
        /// </summary>
        public void IncrementReferenceCount()
        {
            Interlocked.Increment(ref _referenceCount);
        }

        /// <summary>
        /// Decrements the memory reference count.
        /// </summary>
        public void DecrementReferenceCount()
        {
            if (Interlocked.Decrement(ref _referenceCount) == 0 && _cpuMemory is IRefCounted rc)
            {
                rc.DecrementReferenceCount();
            }
        }

        /// <summary>
        /// Creates a new device memory manager.
        /// </summary>
        /// <returns>The memory manager</returns>
        public DeviceMemoryManager CreateDeviceMemoryManager()
        {
            return new DeviceMemoryManager(_cpuMemory);
        }

        /// <summary>
        /// Gets a host pointer for a given range of application memory.
        /// If the memory region is not a single contiguous block, this method returns 0.
        /// </summary>
        /// <remarks>
        /// Getting a host pointer is unsafe. It should be considered invalid immediately if the GPU memory is unmapped.
        /// </remarks>
        /// <param name="range">Ranges of physical memory where the target data is located</param>
        /// <returns>Pointer to the range of memory</returns>
        public nint GetHostPointer(MultiRange range)
        {
            if (range.Count == 1)
            {
                MemoryRange singleRange = range.GetSubRange(0);
                if (singleRange.Address != MemoryManager.PteUnmapped)
                {
                    IEnumerable<HostMemoryRange> regions = _cpuMemory.GetHostRegions(singleRange.Address, singleRange.Size);

                    if (regions != null && regions.Count() == 1)
                    {
                        return (nint)regions.First().Address;
                    }
                }
            }

            return 0;
        }

        /// <summary>
        /// Gets a span of data from the application process.
        /// </summary>
        /// <param name="address">Start address of the range</param>
        /// <param name="size">Size in bytes to be range</param>
        /// <param name="tracked">True if read tracking is triggered on the span</param>
        /// <returns>A read only span of the data at the specified memory location</returns>
        public ReadOnlySpan<byte> GetSpan(ulong address, int size, bool tracked = false)
        {
            return _cpuMemory.GetSpan(address, size, tracked);
        }

        /// <summary>
        /// Gets a span of data from the application process.
        /// </summary>
        /// <param name="range">Ranges of physical memory where the data is located</param>
        /// <param name="tracked">True if read tracking is triggered on the span</param>
        /// <returns>A read only span of the data at the specified memory location</returns>
        public ReadOnlySpan<byte> GetSpan(MultiRange range, bool tracked = false) => S2AGetSpan(range, out _, tracked, false);

        /// <summary>
        /// S2A：同 GetSpan(MultiRange)，但多段时拼接用的暂存从 MemoryOwner 租（用完由调用方 Dispose 归还），不再每次 new 一整张贴图大的托管数组。
        /// 10-24 原生层：怪猎 Mac 局 240 秒里贴图建立（Texture.SynchronizeFull / TextureGroup.SynchronizePartial）经这里新分配 ≥1 MB 的 byte[] 累计 131 MB，
        /// 是大对象堆里 Byte[] 的主源（2048²×4 = 16 MB、1280×768×4 等），读盘段把大对象堆顶到几百 MB、gen2 才清。
        /// 租来的块走 MemoryOwner 池（同尺寸复用）；S2A_MO_NATIVE=1 时 ≥85000 字节的直接取窗口尾部原生暂存、完全不进 GC 堆。
        /// 只给「本地读完即弃」的调用方用：返回的 span 在 scratch Dispose 后失效
        /// </summary>
        public ReadOnlySpan<byte> S2AGetSpanScratch(MultiRange range, out MemoryOwner<byte> scratch, bool tracked = false) => S2AGetSpan(range, out scratch, tracked, true);

        private ReadOnlySpan<byte> S2AGetSpan(MultiRange range, out MemoryOwner<byte> scratch, bool tracked, bool rent)
        {
            scratch = null;
            if (range.Count == 1)
            {
                MemoryRange singleRange = range.GetSubRange(0);
                if (singleRange.Address != MemoryManager.PteUnmapped)
                {
                    return _cpuMemory.GetSpan(singleRange.Address, (int)singleRange.Size, tracked);
                }
            }

            if (rent)
            {
                scratch = MemoryOwner<byte>.Rent(checked((int)range.GetSize()));
            }

            Span<byte> data = rent ? scratch.Span : new byte[range.GetSize()];

            int offset = 0;

            for (int i = 0; i < range.Count; i++)
            {
                MemoryRange currentRange = range.GetSubRange(i);
                int size = (int)currentRange.Size;
                if (currentRange.Address != MemoryManager.PteUnmapped)
                {
                    _cpuMemory.GetSpan(currentRange.Address, size, tracked).CopyTo(data.Slice(offset, size));
                }
                else if (rent)
                {
                    data.Slice(offset, size).Clear();   // 租来的块不保证清零；原路 new byte[] 的未映射段是 0
                }

                offset += size;
            }

            return data;
        }

        // Reuse the platform readonly-copy provider without the tracked-read
        // signaling performed by the texture helper. This method never writes
        // guest memory, changes its protection, or recursively flushes the GPU.
        // If a platform has no readonly-copy provider, fall back to the tracker's
        // own untracked read (same protected-safe alias semantics). Never fall back
        // to a borrowed span: a PROT_NONE destination page would fault in managed
        // code, which NativeAOT turns into an unrecoverable AccessViolation.
        internal unsafe void S2ACopyUntrackedForDma(MultiRange range, Memory<byte> target)
        {
            if (target.Length == 0) return;
            Action<ulong, Memory<byte>> copy = _context.S2AReadGuestMemory;
            if (copy == null && MemoryTracking.S2AReadUntracked == null)
                throw new NotSupportedException("DMA preserve-read requires a platform readonly-copy or untracked-read provider.");
            if (!_context.IsGpuThread())
                throw new InvalidOperationException("DMA preserve-read requires the GPU owner thread.");
            int total = 0;
            for (int i = 0; i < range.Count; i++)
            {
                MemoryRange part = range.GetSubRange(i);
                if (part.Address == MemoryManager.PteUnmapped)
                    throw new InvalidOperationException("DMA preserve-read touches unmapped GPU memory.");
                _ = checked(part.Address + part.Size);
                total = checked(total + checked((int)part.Size));
            }
            if (total != target.Length) throw new ArgumentException("DMA preserve-read range length mismatch.");
            // 审计 #1534 P1-7：保留读取读的是矩形外要原样写回的目标字节。GPU 改过、还没回写的部分先按跟踪状态回写
            //   （同源区的 tracked 读、贴图读前回写；上游借页直读碰到受保护页时由缺页走同一事件），否则拿未跟踪的旧字节连同矩形一起写回、盖掉 GPU 的结果
            for (int i = 0; i < range.Count; i++)
            {
                MemoryRange part = range.GetSubRange(i);
                if (part.Size != 0) _cpuMemory.SignalMemoryTracking(part.Address, part.Size, false);
            }
            int offset = 0;
            for (int i = 0; i < range.Count; i++)
            {
                MemoryRange part = range.GetSubRange(i);
                int size = (int)part.Size;
                if (size != 0)
                {
                    if (copy != null) copy(part.Address, target.Slice(offset, size));
                    else S2ACopyUntrackedForDmaFallback(part.Address, target.Slice(offset, size));
                }
                offset += size;
            }
        }

        // Tracker-provided untracked read (NxTrack.S2AReadUntracked → s2a_track_read_untracked):
        // reads PROT_NONE pages through the shared read-only alias, never through a borrowed span.
        private static unsafe void S2ACopyUntrackedForDmaFallback(ulong address, Memory<byte> target)
        {
            delegate*<ulong, byte*, int, void> read = MemoryTracking.S2AReadUntracked;
            if (read == null)
                throw new NotSupportedException("DMA preserve-read requires an untracked-read provider.");
            fixed (byte* dst = target.Span)
            {
                int offset = 0;
                while (offset < target.Length)
                {
                    int size = Math.Min(target.Length - offset, 1 << 20);
                    read(address + (ulong)offset, dst + offset, size);
                    offset += size;
                }
            }
        }

        /// <summary>
        /// 纹理上传的正常读取。精确 GPU 读同步仍先执行；平台副本只解决源页保护，不代替读回。
        /// 返回的 owner 由调用者在转换和上传取数结束后归还；归还不会写入 guest。
        /// </summary>
        public ReadOnlySpan<byte> S2AGetTextureReadSpan(MultiRange range, out MemoryOwner<byte> owner)
        {
            owner = null;
            Action<ulong, Memory<byte>> copy = _context.S2AReadGuestMemory;
            if (copy != null && !_context.IsGpuThread())
            {
                throw new InvalidOperationException("Guest texture reads require the GPU owner thread.");
            }

            if (copy == null)
            {
                S2ASignalReadForTexture(range);
                return S2AGetSpanScratch(range, out owner);
            }

            // 先检查每段与总长，不能让 ulong 加法或 int 截断把真实映射洞隐藏起来。
            int total = 0;
            for (int i = 0; i < range.Count; i++)
            {
                MemoryRange part = range.GetSubRange(i);
                int size = checked((int)part.Size);
                if (part.Address != MemoryManager.PteUnmapped)
                {
                    _ = checked(part.Address + part.Size);
                }
                total = checked(total + size);
            }

            S2ASignalReadForTexture(range);
            return S2ACopyReadSpan(range, copy, total, out owner);
        }

        /// <summary>
        /// 缓冲已按自身 dirty/GPU-modified 区间完成同步后取数；这里不能再次发跟踪事件，避免重入当前 flush。
        /// 未安装平台复制时保留原 span；副本 owner 必须活到 SetBufferData 消费结束。
        /// </summary>
        internal ReadOnlySpan<byte> S2AGetBufferReadSpan(ulong address, int size, out S2ABufferReadScratch.Lease owner)
        {
            owner = default;
            Action<ulong, Memory<byte>> copy = _context.S2AReadGuestMemory;
            if (copy == null)
            {
                return GetSpan(address, size);
            }

            if (!_context.IsGpuThread())
            {
                throw new InvalidOperationException("Guest buffer reads require the GPU owner thread.");
            }

            ArgumentOutOfRangeException.ThrowIfNegative(size);
            _ = checked(address + (ulong)size);
            S2ABufferReadScratch.Lease rented = S2ABufferReadScratch.Enabled
                ? (_s2aBufferReadScratch ??= new S2ABufferReadScratch()).Rent(size)
                : new S2ABufferReadScratch.Lease(MemoryOwner<byte>.Rent(size));
            try
            {
                if (size != 0) copy(address, rented.Memory);
                owner = rented;
                return rented.Span;
            }
            catch
            {
                rented.Dispose();
                throw;
            }
        }

        private static ReadOnlySpan<byte> S2ACopyReadSpan(MultiRange range, Action<ulong, Memory<byte>> copy,
            int total, out MemoryOwner<byte> owner)
        {
            owner = null;
            MemoryOwner<byte> rented = MemoryOwner<byte>.Rent(total);
            try
            {
                int offset = 0;
                for (int i = 0; i < range.Count; i++)
                {
                    MemoryRange part = range.GetSubRange(i);
                    int size = checked((int)part.Size);
                    Memory<byte> target = rented.Memory.Slice(offset, size);
                    if (part.Address == MemoryManager.PteUnmapped)
                    {
                        target.Span.Clear(); // 仅保留原 GetSpan 的显式 PTE 空洞语义。
                    }
                    else if (size != 0)
                    {
                        copy(part.Address, target);
                    }
                    offset += size;
                }
                owner = rented;
                return rented.Span;
            }
            catch
            {
                rented.Dispose();
                throw;
            }
        }

        /// <summary>
        /// Gets a writable region from the application process.
        /// </summary>
        /// <param name="address">Start address of the range</param>
        /// <param name="size">Size in bytes to be range</param>
        /// <param name="tracked">True if write tracking is triggered on the span</param>
        /// <returns>A writable region with the data at the specified memory location</returns>
        public unsafe WritableRegion GetWritableRegion(ulong address, int size, bool tracked = false)
        {
            // S2Arm: an untracked region here is the GPU writing its own data to guest memory (texture flush, buffer clear fill; every caller disposes it).
            // Hand out a copy written back through WriteUntracked on Dispose, like Buffer.FlushImpl, so the guest write tracker keeps the bytes as GPU data
            // instead of reporting them later as a CPU write (which re-uploaded them over newer GPU writes and forced a GPU wait whenever the page had a flush action)
            if (!tracked && size > 0)
            {
                bool hasProvider = S2AWritebackHasProvider;

                if (S2AWritebackBorrowedReadOn || (!hasProvider && !S2AGpuCaps.WritebackRequireProvider))
                {
                    if (!hasProvider)
                    {
                        S2AWritebackBorrowedWarning();
                    }

                    // 审计 #1534 P1-17：借来的跨度只在这一支取。有提供者那支只经提供者读旧字节，不先对客内存取跨度
                    //   （产品的不跟踪 GetSpan 会先按「GPU 改过没回写」收口回写，跨块时还要拷远端副本，取了又不用）
                    ReadOnlySpan<byte> current = _cpuMemory.GetSpan(address, size);

                    return S2AUntrackedRegionPool.Rent(_cpuMemory, address, current);
                }

                if (!hasProvider)
                {
                    throw new NotSupportedException("GPU writeback requires a platform readonly-copy or untracked-read provider.");
                }

                return S2AUntrackedRegionPool.Rent(_cpuMemory, address, size, _s2aReadForWriteback);
            }

            return _cpuMemory.GetWritableRegion(address, size, tracked);
        }

        /// <summary>
        /// Gets a writable region from GPU mapped memory.
        /// </summary>
        /// <param name="range">Range</param>
        /// <param name="tracked">True if write tracking is triggered on the span</param>
        /// <returns>A writable region with the data at the specified memory location</returns>
        public unsafe WritableRegion GetWritableRegion(MultiRange range, bool tracked = false)
        {
            if (range.Count == 1)
            {
                MemoryRange subrange = range.GetSubRange(0);

                return GetWritableRegion(subrange.Address, (int)subrange.Size, tracked);
            }
            else
            {
                MemoryOwner<byte> memoryOwner = MemoryOwner<byte>.Rent(checked((int)range.GetSize()));

                try
                {
                    bool hasProvider = S2AWritebackHasProvider;

                    if (S2AWritebackBorrowedReadOn || (!hasProvider && !S2AGpuCaps.WritebackRequireProvider))
                    {
                        if (!hasProvider)
                        {
                            S2AWritebackBorrowedWarning();
                        }

                        Span<byte> memorySpan = memoryOwner.Span;

                        int offset = 0;
                        for (int i = 0; i < range.Count; i++)
                        {
                            MemoryRange currentRange = range.GetSubRange(i);
                            int size = (int)currentRange.Size;
                            if (currentRange.Address != MemoryManager.PteUnmapped)
                            {
                                GetSpan(currentRange.Address, size).CopyTo(memorySpan.Slice(offset, size));
                            }

                            offset += size;
                        }
                    }
                    else if (!hasProvider)
                    {
                        throw new NotSupportedException("GPU writeback requires a platform readonly-copy or untracked-read provider.");
                    }
                    else
                    {
                        // 多段回写同样先拷出旧字节。不能按段借页直读：目标页可能被写跟踪
                        // 设成 PROT_NONE（读时回写 / GPU 改过），托管直读会缺页。与单段
                        // Rent 走同一条无跟踪读。
                        S2AReadForWriteback(range, memoryOwner.Memory);
                    }
                }
                catch
                {
                    memoryOwner.Dispose();
                    throw;
                }

                return new WritableRegion(new MultiRangeWritableBlock(range, this), 0, memoryOwner, tracked);
            }
        }

        // 有任意一条安全读提供者就可用：跟踪器的无跟踪读（与 S2AUntrackedRegionPool 单段
        // Rent 同一条）或平台只读拷贝提供者（Android）。
        private unsafe bool S2AWritebackHasProvider =>
            MemoryTracking.S2AReadUntracked != null || _context.S2AReadGuestMemory != null;

        // 非安卓没有提供者时沿用原来的借页直读；只报一次红，避免每帧刷日志。
        private static void S2AWritebackBorrowedWarning()
        {
            if (Interlocked.Exchange(ref _s2aWritebackBorrowedRed, 1) == 0)
            {
                Console.Error.WriteLine("[gal] 【红】GPU 回写没有无跟踪读提供者：退回借页直读（非安卓；受保护页可能缺页）");
            }
        }

        // 本类回写先拷出的旧字节只能经无跟踪读取：目标页可能被读时回写 / GPU 改过设成
        // PROT_NONE，借页直读在宿主上下文里会缺页（安全读钩子未装时 NativeAOT 无法把它
        // 变成一次正确读回）。优先用跟踪器的无跟踪读（与 S2AUntrackedRegionPool 单段
        // Rent 同一条），其次用平台只读拷贝提供者（Android）。
        private unsafe void S2AReadForWriteback(ulong address, Memory<byte> target)
        {
            if (target.Length == 0)
            {
                return;
            }

            delegate*<ulong, byte*, int, void> read = MemoryTracking.S2AReadUntracked;

            if (read != null)
            {
                fixed (byte* dst = target.Span)
                {
                    read(address, dst, target.Length);
                }

                return;
            }

            Action<ulong, Memory<byte>> copy = _context.S2AReadGuestMemory;

            if (copy != null)
            {
                copy(address, target);
                return;
            }

            throw new NotSupportedException("GPU writeback requires a platform readonly-copy or untracked-read provider.");
        }

        private void S2AReadForWriteback(MultiRange range, Memory<byte> target)
        {
            int offset = 0;

            for (int i = 0; i < range.Count; i++)
            {
                MemoryRange part = range.GetSubRange(i);
                int size = (int)part.Size;

                if (part.Address == MemoryManager.PteUnmapped)
                {
                    target.Span.Slice(offset, size).Clear(); // 原 GetSpan 对显式 PTE 空洞给 0
                }
                else if (size != 0)
                {
                    S2AReadForWriteback(part.Address, target.Slice(offset, size));
                }

                offset += size;
            }
        }

        /// <summary>
        /// Reads data from the application process.
        /// </summary>
        /// <typeparam name="T">Type of the structure</typeparam>
        /// <param name="address">Address to read from</param>
        /// <returns>The data at the specified memory location</returns>
        public T Read<T>(ulong address) where T : unmanaged
        {
            return _cpuMemory.Read<T>(address);
        }

        /// <summary>
        /// Reads data from the application process, with write tracking.
        /// </summary>
        /// <typeparam name="T">Type of the structure</typeparam>
        /// <param name="address">Address to read from</param>
        /// <returns>The data at the specified memory location</returns>
        public T ReadTracked<T>(ulong address) where T : unmanaged
        {
            return _cpuMemory.ReadTracked<T>(address);
        }

        /// <summary>
        /// Writes data to the application process, triggering a precise memory tracking event.
        /// </summary>
        /// <param name="address">Address to write into</param>
        /// <param name="data">Data to be written</param>
        public void WriteTrackedResource(ulong address, ReadOnlySpan<byte> data)
        {
            S2AEngineWrote(address, (ulong)data.Length);
            _cpuMemory.SignalMemoryTracking(address, (ulong)data.Length, true, precise: true);
            _cpuMemory.WriteUntracked(address, data);
        }

        /// <summary>
        /// Writes data to the application process, triggering a precise memory tracking event.
        /// </summary>
        /// <param name="address">Address to write into</param>
        /// <param name="data">Data to be written</param>
        /// <param name="kind">Kind of the resource being written, which will not be signalled as CPU modified</param>
        public void WriteTrackedResource(ulong address, ReadOnlySpan<byte> data, ResourceKind kind)
        {
            S2AEngineWrote(address, (ulong)data.Length);
            _cpuMemory.SignalMemoryTracking(address, (ulong)data.Length, true, precise: true, exemptId: (int)kind);
            _cpuMemory.WriteUntracked(address, data);
        }

        /// <summary>
        /// Writes data to the application process.
        /// </summary>
        /// <param name="address">Address to write into</param>
        /// <param name="data">Data to be written</param>
        public void Write(ulong address, ReadOnlySpan<byte> data)
        {
            S2AEngineWrote(address, (ulong)data.Length);
            _cpuMemory.Write(address, data);
        }

        /// <summary>
        /// Writes data to the application process.
        /// </summary>
        /// <param name="range">Ranges of physical memory where the data is located</param>
        /// <param name="data">Data to be written</param>
        public void Write(MultiRange range, ReadOnlySpan<byte> data)
        {
            for (int i = 0; i < range.Count; i++)
            {
                MemoryRange r = range.GetSubRange(i);
                S2AEngineWrote(r.Address, r.Size);
            }

            WriteImpl(range, data, _cpuMemory.Write);
        }

        /// <summary>
        /// Writes data to the application process, without any tracking.
        /// </summary>
        /// <param name="address">Address to write into</param>
        /// <param name="data">Data to be written</param>
        public void WriteUntracked(ulong address, ReadOnlySpan<byte> data)
        {
            _cpuMemory.WriteUntracked(address, data);
        }

        /// <summary>
        /// Writes data to the application process, without any tracking.
        /// </summary>
        /// <param name="range">Ranges of physical memory where the data is located</param>
        /// <param name="data">Data to be written</param>
        public void WriteUntracked(MultiRange range, ReadOnlySpan<byte> data)
        {
            WriteImpl(range, data, _cpuMemory.WriteUntracked);
        }

        /// <summary>
        /// Writes data to the application process, returning false if the data was not changed.
        /// This triggers read memory tracking, as a redundancy check would be useless if the data is not up to date.
        /// </summary>
        /// <remarks>The memory manager can return that memory has changed when it hasn't to avoid expensive data copies.</remarks>
        /// <param name="address">Address to write into</param>
        /// <param name="data">Data to be written</param>
        /// <returns>True if the data was changed, false otherwise</returns>
        public bool WriteWithRedundancyCheck(ulong address, ReadOnlySpan<byte> data)
        {
            S2AEngineWrote(address, (ulong)data.Length);
            return _cpuMemory.WriteWithRedundancyCheck(address, data);
        }

        // S2A 缓冲零拷贝（S2A_ZEROCOPY=1）：模拟 GPU 引擎在命令流里写游戏内存（常量缓冲更新、内联上传、DMA、信号量 / 报告）都经这几个入口。
        // 被它们写到的零拷贝缓冲必须降级成普通缓冲：引擎写当场落进游戏内存（模拟 GPU 自己马上要在 CPU 上读），宿主 GPU 落后一截，
        // 排在前面还没执行的绘制若读的是同一块内存，会看到命令流里「将来」的值（10-23 塞尔达零拷贝白屏的第二个根因）。这里只登记（不拿跟踪锁），
        // 下次取用时降级（Buffer.SynchronizeMemory）。只认 GPU 线程上的写（引擎都在那里跑）
        private void S2AEngineWrote(ulong address, ulong size)
        {
            if (S2AZeroCopy.On && size != 0 && _context.IsGpuThread())
            {
                BufferCache.S2AEngineWrote(address, size);
            }
        }

        private delegate void WriteCallback(ulong address, ReadOnlySpan<byte> data);

        /// <summary>
        /// Writes data to the application process, using the supplied callback method.
        /// </summary>
        /// <param name="range">Ranges of physical memory where the data is located</param>
        /// <param name="data">Data to be written</param>
        /// <param name="writeCallback">Callback method that will perform the write</param>
        private static void WriteImpl(MultiRange range, ReadOnlySpan<byte> data, WriteCallback writeCallback)
        {
            if (range.Count == 1)
            {
                MemoryRange singleRange = range.GetSubRange(0);
                if (singleRange.Address != MemoryManager.PteUnmapped)
                {
                    writeCallback(singleRange.Address, data);
                }
            }
            else
            {
                int offset = 0;

                for (int i = 0; i < range.Count; i++)
                {
                    MemoryRange currentRange = range.GetSubRange(i);
                    int size = (int)currentRange.Size;
                    if (currentRange.Address != MemoryManager.PteUnmapped)
                    {
                        writeCallback(currentRange.Address, data.Slice(offset, size));
                    }

                    offset += size;
                }
            }
        }

        /// <summary>
        /// Fills the specified memory region with a 32-bit integer value.
        /// </summary>
        /// <param name="address">CPU virtual address of the region</param>
        /// <param name="size">Size of the region</param>
        /// <param name="value">Value to fill the region with</param>
        /// <param name="kind">Kind of the resource being filled, which will not be signalled as CPU modified</param>
        public void FillTrackedResource(ulong address, ulong size, uint value, ResourceKind kind)
        {
            _cpuMemory.SignalMemoryTracking(address, size, write: true, precise: true, (int)kind);

            // S2Arm: through the copy-and-write-back region (WriteUntracked right after the precise signal: the fill value is final, not a CPU write)
            using WritableRegion region = GetWritableRegion(address, (int)size);

            MemoryMarshal.Cast<byte, uint>(region.Memory.Span).Fill(value);
        }

        /// <summary>
        /// Obtains a memory tracking handle for the given virtual region. This should be disposed when finished with.
        /// </summary>
        /// <param name="address">CPU virtual address of the region</param>
        /// <param name="size">Size of the region</param>
        /// <param name="kind">Kind of the resource being tracked</param>
        /// <param name="flags">Region flags</param>
        /// <returns>The memory tracking handle</returns>
        // S2A（帧率能耗线 10-22）：贴图从内存同步（新建 / CPU 改过后重传）前，贴图字节若和 GPU 改过、没回写的缓冲重叠，按读对这段发跟踪事件、豁免贴图自己的句柄：
        // 同页里 GPU 改过、没回写的缓冲先在正常上下文里回写，再读。原版靠宿主读缺页时信号处理里回写；我方信号处理不能回写
        // （宿主线程没有改道，见 graphics/track/track.c READFLUSH 宿主读），宿主读到旧值再传给 GPU 就盖掉 GPU 新值。S2A_TEX_READ_TRACK=0 关
        private static readonly bool _s2aTexReadTrack = Environment.GetEnvironmentVariable("S2A_TEX_READ_TRACK") != "0";

        public void S2ASignalReadForTexture(MultiRange range)
        {
            if (!_s2aTexReadTrack)
            {
                return;
            }

            for (int i = 0; i < range.Count; i++)
            {
                MemoryRange r = range.GetSubRange(i);

                // 只在贴图自己的字节真和 GPU 改过、没回写的缓冲重叠时发（同页不重叠不用等：读的字节不归 GPU 管。10-22 八方2 按页发每帧白等约 1.5 ms）
                if (r.Address != MemoryManager.PteUnmapped && BufferCache.S2AHasGpuModified(r.Address, r.Size))
                {
                    _cpuMemory.SignalMemoryTracking(r.Address, r.Size, false, false, (int)ResourceKind.Texture);
                }
            }
        }

        public RegionHandle BeginTracking(ulong address, ulong size, ResourceKind kind, RegionFlags flags = RegionFlags.None)
        {
            return _cpuMemory.BeginTracking(address, size, (int)kind, flags);
        }

        /// <summary>
        /// Obtains a memory tracking handle for the given virtual region. This should be disposed when finished with.
        /// </summary>
        /// <param name="range">Ranges of physical memory where the data is located</param>
        /// <param name="kind">Kind of the resource being tracked</param>
        /// <returns>The memory tracking handle</returns>
        public GpuRegionHandle BeginTracking(MultiRange range, ResourceKind kind)
        {
            RegionHandle[] cpuRegionHandles = new RegionHandle[range.Count];
            int count = 0;

            for (int i = 0; i < range.Count; i++)
            {
                MemoryRange currentRange = range.GetSubRange(i);
                if (currentRange.Address != MemoryManager.PteUnmapped)
                {
                    cpuRegionHandles[count++] = _cpuMemory.BeginTracking(currentRange.Address, currentRange.Size, (int)kind);
                }
            }

            if (count != range.Count)
            {
                Array.Resize(ref cpuRegionHandles, count);
            }

            return new GpuRegionHandle(cpuRegionHandles);
        }

        /// <summary>
        /// Obtains a memory tracking handle for the given virtual region, with a specified granularity. This should be disposed when finished with.
        /// </summary>
        /// <param name="address">CPU virtual address of the region</param>
        /// <param name="size">Size of the region</param>
        /// <param name="kind">Kind of the resource being tracked</param>
        /// <param name="flags">Region flags</param>
        /// <param name="handles">Handles to inherit state from or reuse</param>
        /// <param name="granularity">Desired granularity of write tracking</param>
        /// <returns>The memory tracking handle</returns>
        public MultiRegionHandle BeginGranularTracking(
            ulong address,
            ulong size,
            ResourceKind kind,
            RegionFlags flags = RegionFlags.None,
            IEnumerable<IRegionHandle> handles = null,
            ulong granularity = 4096)
        {
            return _cpuMemory.BeginGranularTracking(address, size, handles, granularity, (int)kind, flags);
        }

        /// <summary>
        /// Obtains a smart memory tracking handle for the given virtual region, with a specified granularity. This should be disposed when finished with.
        /// </summary>
        /// <param name="address">CPU virtual address of the region</param>
        /// <param name="size">Size of the region</param>
        /// <param name="kind">Kind of the resource being tracked</param>
        /// <param name="granularity">Desired granularity of write tracking</param>
        /// <returns>The memory tracking handle</returns>
        public SmartMultiRegionHandle BeginSmartGranularTracking(ulong address, ulong size, ResourceKind kind, ulong granularity = 4096)
        {
            return _cpuMemory.BeginSmartGranularTracking(address, size, granularity, (int)kind);
        }

        /// <summary>
        /// Checks if a given memory page is mapped.
        /// </summary>
        /// <param name="address">CPU virtual address of the page</param>
        /// <returns>True if mapped, false otherwise</returns>
        public bool IsMapped(ulong address)
        {
            return _cpuMemory.IsMapped(address);
        }

        /// <summary>
        /// S2A: Checks if a given memory range is fully mapped.
        /// </summary>
        /// <param name="address">CPU virtual address of the range</param>
        /// <param name="size">Size of the range in bytes</param>
        /// <returns>True if the entire range is mapped, false otherwise</returns>
        public bool IsRangeMapped(ulong address, ulong size)
        {
            return _cpuMemory.IsRangeMapped(address, size);
        }

        /// <summary>
        /// Release our reference to the CPU memory manager.
        /// </summary>
        public void Dispose()
        {
            _context.DeferredActions.Enqueue(Destroy);
        }

        /// <summary>
        /// Performs disposal of the host GPU caches with resources mapped on this physical memory.
        /// This must only be called from the render thread.
        /// </summary>
        private void Destroy()
        {
            ShaderCache.Dispose();
            BufferCache.Dispose();
            TextureCache.Dispose();

            DecrementReferenceCount();
        }
    }
}
