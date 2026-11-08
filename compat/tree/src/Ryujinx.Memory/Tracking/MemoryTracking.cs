using Ryujinx.Memory.Range;
using System;
using System.Buffers;
using System.Collections.Generic;

namespace Ryujinx.Memory.Tracking
{
    /// <summary>
    /// Manages memory tracking for a given virutal/physical memory block.
    /// </summary>
    public class MemoryTracking
    {
        /// <summary>
        /// S2A（帧率能耗线 10-22）：定向读时回写登记钩子（宿主写跟踪 NxTrack.Init 设）。GPU 层在信号量精确写 / DMA 在 GPU 上读回贴图之后，
        /// 用游戏地址范围调它：这些页里 GPU 改过、还没回写的数据，游戏读时也先回写（只对登记页，不全局开 READFLUSH）
        /// </summary>
        public static Action<ulong, ulong> S2AMarkReadFlush;

        /// <summary>
        /// S2A（帧率能耗线 10-23）：宿主读游戏内存、不经页保护（NxTrack.Init 设，指向 graphics/track s2a_track_read_untracked）。
        /// GPU 回写把目标段原样拷出来（S2AUntrackedRegionPool.Rent）时用：目标页常被读时回写设成不可读，直接读会缺页、改两次保护。为空时照旧直接拷
        /// </summary>
        public static unsafe delegate*<ulong, byte*, int, void> S2AReadUntracked;

        /// <summary>
        /// S2A（帧率能耗线 10-23，部分回写）：本线程正在处理的跟踪事件是游戏代码的读缺页（NxTrack.Touch 设、只在它的调用期间为真）。
        /// GPU 层据此对读只回写所碰子页（写要整张回写：写过的贴图要重传）
        /// </summary>
        [ThreadStatic]
        public static bool S2AReadTouch;

        /// <summary>
        /// S2A（部分回写）：直接改写跟踪层（graphics/track）对一段游戏内存的保护意图，不经 RegionHandle（NxTrack.Init 设 → s2a_track_reprotect）。
        /// 部分回写后只放开被回写的子页（Read）、GPU 再写这张贴图时整段设回（None）；RegionHandle 自己的保护全程不撤（见 RegionHandle.S2AKeepAction）
        /// </summary>
        public static unsafe delegate*<ulong, ulong, int, void> S2AReprotect;

        /// <summary>
        /// S2A（帧率能耗线 10-24，拦写模拟，docs/研究/拦写模拟.md）：缓冲登记回写动作（RegisterAction）期间为真（Buffer 置、本线程）。
        /// 宿主写跟踪据此把这次「GPU 改过」（None）记成缓冲担保；不带它的 None（贴图等）记成污染，永不模拟
        /// </summary>
        [ThreadStatic] public static bool S2ABufferNone;

        /// <summary>
        /// S2A（拦写模拟）：GPU 改过的字节表（宿主写跟踪 s2a_track_mod_set / mod_clear，NxTrack.Init 设）。
        /// BufferModifiedRangeList 每新增一段修改区间置位、一段回写完成或 Clear 后清位；为空时不调
        /// </summary>
        public static unsafe delegate*<ulong, ulong, void> S2AModSet;
        public static unsafe delegate*<ulong, ulong, void> S2AModClear;

        /// <summary>
        /// S2A（诊断，10-29 着色器垃圾代码防线）：宿主页的写跟踪状态（NxTrack.Init 设 → graphics/track s2a_track_page_info，只读、不取锁、任意线程）。
        /// 返回 UINT64_MAX = 没跟踪过；否则按字节打包 state / lastp / act / want / READFLUSH / dirty（见 s2a_track.h）。为空 = 未提供（原生层没这个导出）
        /// </summary>
        public static unsafe delegate*<ulong, ulong> S2ATrackPageInfo;

        private readonly IVirtualMemoryManager _memoryManager;
        private readonly InvalidAccessHandler _invalidAccessHandler;

        /// <summary>
        /// Optional instance admission before a real tracking handle is created. Hosts use
        /// this to atomically reserve backing against unsupported aliases. It must not wait
        /// for another VM/GPU thread; rejection throws before handle publication.
        /// </summary>
        public Action<ulong, ulong> BeforeTracking { get; set; }

        /// <summary>
        /// Notify guest protection again when a new read action is registered, even if
        /// the region is already inaccessible. Native readback hosts use this notification
        /// to distinguish a new action from an old action that failed to finish.
        /// Configure before guest execution. Other hosts retain permission-only coalescing.
        /// </summary>
        public bool ReprotectOnActionRegistration { get; set; }

        // Only use these from within the lock.
        private readonly NonOverlappingRangeList<VirtualRegion> _virtualRegions;
        // Guest virtual regions are a subset of the normal virtual regions, with potentially different protection
        // and expanded area of effect on platforms that don't support misaligned page protection.
        private readonly NonOverlappingRangeList<VirtualRegion> _guestVirtualRegions;

        private readonly int _pageSize;

        private readonly bool _singleByteGuestTracking;

        /// <summary>
        /// This lock must be obtained when traversing or updating the region-handle hierarchy.
        /// It is not required when reading dirty flags.
        /// </summary>
        internal object TrackingLock = new();

        /// <summary>
        /// Create a new tracking structure for the given "physical" memory block,
        /// with a given "virtual" memory manager that will provide mappings and virtual memory protection.
        /// </summary>
        /// <remarks>
        /// If <paramref name="singleByteGuestTracking" /> is true, the memory manager must also support protection on partially
        /// unmapped regions without throwing exceptions or dropping protection on the mapped portion.
        /// </remarks>
        /// <param name="memoryManager">Virtual memory manager</param>
        /// <param name="pageSize">Page size of the virtual memory space</param>
        /// <param name="invalidAccessHandler">Method to call for invalid memory accesses</param>
        /// <param name="singleByteGuestTracking">True if the guest only signals writes for the first byte</param>
        public MemoryTracking(
            IVirtualMemoryManager memoryManager,
            int pageSize,
            InvalidAccessHandler invalidAccessHandler = null,
            bool singleByteGuestTracking = false)
        {
            _memoryManager = memoryManager;
            _pageSize = pageSize;
            _invalidAccessHandler = invalidAccessHandler;
            _singleByteGuestTracking = singleByteGuestTracking;

            _virtualRegions = [];
            _guestVirtualRegions = [];
        }

        private (ulong address, ulong size) PageAlign(ulong address, ulong size)
        {
            ulong pageMask = (ulong)_pageSize - 1;
            ulong rA = address & ~pageMask;
            ulong rS = ((address + size + pageMask) & ~pageMask) - rA;
            return (rA, rS);
        }

        /// <summary>
        /// Indicate that a virtual region has been mapped, and which physical region it has been mapped to.
        /// Should be called after the mapping is complete.
        /// </summary>
        /// <param name="va">Virtual memory address</param>
        /// <param name="size">Size to be mapped</param>
        public void Map(ulong va, ulong size)
        {
            // A mapping may mean we need to re-evaluate each VirtualRegion's affected area.
            // Find all handles that overlap with the range, we need to recalculate their physical regions

            lock (TrackingLock)
            {
                for (int type = 0; type < 2; type++)
                {
                    NonOverlappingRangeList<VirtualRegion> regions = type == 0 ? _virtualRegions : _guestVirtualRegions;
                    regions.Lock.EnterReadLock();
                    ReadOnlySpan<VirtualRegion> overlaps = regions.FindOverlapsAsSpan(va, size);
                    for (int i = 0; i < overlaps.Length; i++)
                    {
                        VirtualRegion region = overlaps[i];

                        // If the region has been fully remapped, signal that it has been mapped again.
                        bool remapped = _memoryManager.IsRangeMapped(region.Address, region.Size);
                        if (remapped)
                        {
                            region.SignalMappingChanged(true);
                        }

                        region.UpdateProtection();
                    }
                    regions.Lock.ExitReadLock();
                }
            }
        }

        /// <summary>
        /// Indicate that a virtual region has been unmapped.
        /// Should be called before the unmapping is complete.
        /// </summary>
        /// <param name="va">Virtual memory address</param>
        /// <param name="size">Size to be unmapped</param>
        public void Unmap(ulong va, ulong size)
        {
            // An unmapping may mean we need to re-evaluate each VirtualRegion's affected area.
            // Find all handles that overlap with the range, we need to notify them that the region was unmapped.

            lock (TrackingLock)
            {
                for (int type = 0; type < 2; type++)
                {
                    NonOverlappingRangeList<VirtualRegion> regions = type == 0 ? _virtualRegions : _guestVirtualRegions;
                    regions.Lock.EnterReadLock();
                    ReadOnlySpan<VirtualRegion> overlaps = regions.FindOverlapsAsSpan(va, size);
                    
                    for (int i = 0; i < overlaps.Length; i++)
                    {
                        overlaps[i].SignalMappingChanged(false);
                    }
                    regions.Lock.ExitReadLock();
                }
            }
        }

        /// <summary>
        /// Alter a tracked memory region to properly capture unaligned accesses.
        /// For most memory manager modes, this does nothing.
        /// </summary>
        /// <param name="address">Original region address</param>
        /// <param name="size">Original region size</param>
        /// <returns>A new address and size for tracking unaligned accesses</returns>
        internal (ulong newAddress, ulong newSize) GetUnalignedSafeRegion(ulong address, ulong size)
        {
            if (_singleByteGuestTracking)
            {
                // The guest only signals the first byte of each memory access with the current memory manager.
                // To catch unaligned access properly, we need to also protect the page before the address.

                // Assume that the address and size are already aligned.

                return (address - (ulong)_pageSize, size + (ulong)_pageSize);
            }
            else
            {
                return (address, size);
            }
        }

        /// <summary>
        /// Get a list of virtual regions that a handle covers.
        /// </summary>
        /// <param name="va">Starting virtual memory address of the handle</param>
        /// <param name="size">Size of the handle's memory region</param>
        /// <param name="guest">True if getting handles for guest protection, false otherwise</param>
        /// <returns>A list of virtual regions within the given range</returns>
        // S2A（帧率能耗线 10-22）：建区域的委托按宿主 / 游戏侧各缓存一个（原来每次调用都新建闭包 + 委托，每个句柄两次约 192 B）
        private Func<ulong, ulong, VirtualRegion> _hostRegionFactory, _guestRegionFactory;

        internal List<VirtualRegion> GetVirtualRegionsForHandle(ulong va, ulong size, bool guest)
        {
            NonOverlappingRangeList<VirtualRegion> regions = guest ? _guestVirtualRegions : _virtualRegions;
            regions.Lock.EnterUpgradeableReadLock();
            regions.GetOrAddRegions(out List<VirtualRegion> result, va, size, guest ? _guestRegionFactory ??= (va, size) => new VirtualRegion(this, va, size, true) : _hostRegionFactory ??= (va, size) => new VirtualRegion(this, va, size, false));
            regions.Lock.ExitUpgradeableReadLock();
            
            return result;
        }

        /// <summary>
        /// Remove a virtual region from the range list. This assumes that the lock has been acquired.
        /// </summary>
        /// <param name="region">Region to remove</param>
        internal void RemoveVirtual(VirtualRegion region)
        {
            if (region.Guest)
            {
                _guestVirtualRegions.Lock.EnterWriteLock();
                _guestVirtualRegions.Remove(region);
                _guestVirtualRegions.Lock.ExitWriteLock();
            }
            else
            {
                _virtualRegions.Lock.EnterWriteLock();
                _virtualRegions.Remove(region);
                _virtualRegions.Lock.ExitWriteLock();
            }
        }

        /// <summary>
        /// Obtains a memory tracking handle for the given virtual region, with a specified granularity. This should be disposed when finished with.
        /// </summary>
        /// <param name="address">CPU virtual address of the region</param>
        /// <param name="size">Size of the region</param>
        /// <param name="handles">Handles to inherit state from or reuse. When none are present, provide null</param>
        /// <param name="granularity">Desired granularity of write tracking</param>
        /// <param name="id">Handle ID</param>
        /// <param name="flags">Region flags</param>
        /// <returns>The memory tracking handle</returns>
        public MultiRegionHandle BeginGranularTracking(ulong address, ulong size, IEnumerable<IRegionHandle> handles, ulong granularity, int id, RegionFlags flags = RegionFlags.None)
        {
            return new MultiRegionHandle(this, address, size, handles, granularity, id, flags);
        }

        /// <summary>
        /// Obtains a smart memory tracking handle for the given virtual region, with a specified granularity. This should be disposed when finished with.
        /// </summary>
        /// <param name="address">CPU virtual address of the region</param>
        /// <param name="size">Size of the region</param>
        /// <param name="granularity">Desired granularity of write tracking</param>
        /// <param name="id">Handle ID</param>
        /// <returns>The memory tracking handle</returns>
        public SmartMultiRegionHandle BeginSmartGranularTracking(ulong address, ulong size, ulong granularity, int id)
        {
            (address, size) = PageAlign(address, size);

            return new SmartMultiRegionHandle(this, address, size, granularity, id);
        }

        /// <summary>
        /// Obtains a memory tracking handle for the given virtual region. This should be disposed when finished with.
        /// </summary>
        /// <param name="address">CPU virtual address of the region</param>
        /// <param name="size">Size of the region</param>
        /// <param name="id">Handle ID</param>
        /// <param name="flags">Region flags</param>
        /// <returns>The memory tracking handle</returns>
        public RegionHandle BeginTracking(ulong address, ulong size, int id, RegionFlags flags = RegionFlags.None)
        {
            (ulong paAddress, ulong paSize) = PageAlign(address, size);
            BeforeTracking?.Invoke(paAddress, paSize);

            lock (TrackingLock)
            {
                bool mapped = _memoryManager.IsRangeMapped(address, size);
                RegionHandle handle = new(this, paAddress, paSize, address, size, id, flags, mapped);

                return handle;
            }
        }

        /// <summary>
        /// Obtains a memory tracking handle for the given virtual region. This should be disposed when finished with.
        /// </summary>
        /// <param name="address">CPU virtual address of the region</param>
        /// <param name="size">Size of the region</param>
        /// <param name="bitmap">The bitmap owning the dirty flag for this handle</param>
        /// <param name="bit">The bit of this handle within the dirty flag</param>
        /// <param name="id">Handle ID</param>
        /// <param name="flags">Region flags</param>
        /// <returns>The memory tracking handle</returns>
        internal RegionHandle BeginTrackingBitmap(ulong address, ulong size, ConcurrentBitmap bitmap, int bit, int id, RegionFlags flags = RegionFlags.None)
        {
            (ulong paAddress, ulong paSize) = PageAlign(address, size);
            BeforeTracking?.Invoke(paAddress, paSize);

            lock (TrackingLock)
            {
                bool mapped = _memoryManager.IsRangeMapped(address, size);
                RegionHandle handle = new(this, paAddress, paSize, address, size, bitmap, bit, id, flags, mapped);

                return handle;
            }
        }

        /// <summary>
        /// Signal that a virtual memory event happened at the given location.
        /// The memory event is assumed to be triggered by guest code.
        /// </summary>
        /// <param name="address">Virtual address accessed</param>
        /// <param name="size">Size of the region affected in bytes</param>
        /// <param name="write">Whether the region was written to or read</param>
        /// <returns>True if the event triggered any tracking regions, false otherwise</returns>
        public bool VirtualMemoryEvent(ulong address, ulong size, bool write)
        {
            return VirtualMemoryEvent(address, size, write, precise: false, exemptId: null, guest: true);
        }

        /// <summary>
        /// Signal that a virtual memory event happened at the given location.
        /// This can be flagged as a precise event, which will avoid reprotection and call special handlers if possible.
        /// A precise event has an exact address and size, rather than triggering on page granularity.
        /// </summary>
        /// <param name="address">Virtual address accessed</param>
        /// <param name="size">Size of the region affected in bytes</param>
        /// <param name="write">Whether the region was written to or read</param>
        /// <param name="precise">True if the access is precise, false otherwise</param>
        /// <param name="exemptId">Optional ID that of the handles that should not be signalled</param>
        /// <param name="guest">True if the access is from the guest, false otherwise</param>
        /// <returns>True if the event triggered any tracking regions, false otherwise</returns>
        public bool VirtualMemoryEvent(ulong address, ulong size, bool write, bool precise, int? exemptId = null, bool guest = false)
        {
            // Look up the virtual region using the region list.
            // Signal up the chain to relevant handles.

            bool shouldThrow = false;

            lock (TrackingLock)
            {
                NonOverlappingRangeList<VirtualRegion> regions = guest ? _guestVirtualRegions : _virtualRegions;
                
                // We use the non-span method here because keeping the lock will cause a deadlock.
                regions.Lock.EnterReadLock();
                VirtualRegion[] overlaps = regions.FindOverlapsAsArray(address, size, out int length);
                regions.Lock.ExitReadLock();

                if (length == 0 && !precise)
                {
                    if (_memoryManager.IsRangeMapped(address, size))
                    {
                        // TODO: There is currently the possibility that a page can be protected after its virtual region is removed.
                        // This code handles that case when it happens, but it would be better to find out how this happens.
                        _memoryManager.TrackingReprotect(address & ~(ulong)(_pageSize - 1), (ulong)_pageSize, MemoryPermission.ReadAndWrite, guest);
                        
                        return true; // This memory _should_ be mapped, so we need to try again.
                    }
                    
                    shouldThrow = true;
                }
                else
                {
                    if (guest && _singleByteGuestTracking)
                    {
                        // Increase the access size to trigger handles with misaligned accesses.
                        size += (ulong)_pageSize;
                    }
                    
                    for (int i = 0; i < length; i++)
                    {
                        VirtualRegion region = overlaps[i];

                        if (precise)
                        {
                            region.SignalPrecise(address, size, write, exemptId);
                        }
                        else
                        {
                            region.Signal(address, size, write, exemptId);
                        }
                    }

                    if (length != 0)
                    {
                        ArrayPool<VirtualRegion>.Shared.Return(overlaps);
                    }
                }
            }

            if (shouldThrow)
            {
                _invalidAccessHandler?.Invoke(address);

                // We can't continue - it's impossible to remove protection from the page.
                // Even if the access handler wants us to continue, we wouldn't be able to.
                throw new InvalidMemoryRegionException();
            }

            return true;
        }

        /// <summary>
        /// S2A（#1397 诊断/负控）：置真关掉 RegionHandle 级的回写重入闸（见 RegionHandle.Signal 的
        /// s2aInSignal 注释）——宿主测试去掉闸时对拍深度用，生产勿置。
        /// </summary>
        [ThreadStatic] public static bool S2AReadFlushNoGuard;

        /// <summary>
        /// S2A（#199 收口回写）：GPU 改过、还没回写的子页被读之前发同一个读跟踪事件——客机缺页
        /// （NxTrack.Touch 读分支）与 GuestMemory 的托管不跟踪读共用这一入口。回写动作在本线程跑完、
        /// 页恢复可读后才返回；失败原样上抛。S2AReadTouch 置位期间 GPU 层只回写所碰子页（部分回写）。
        /// 回写动作里可再发收口读（嵌套）：重入闸在 RegionHandle 级（信号命中在信号句柄自身时跳过、
        /// 同段别名句柄照常同步），收口入口本身不加区间闸；收尾恢复进入前的值，不清外层的标志
        /// （11-01 审计 P2-40）。
        /// </summary>
        /// <param name="va">读区间起点（游戏地址）</param>
        /// <param name="size">读区间长度</param>
        public void S2AReadFlush(ulong va, ulong size)
        {
            bool outer = S2AReadTouch;
            S2AReadTouch = true;
            try
            {
                VirtualMemoryEvent(va, size, false, precise: false, exemptId: null, guest: true);
            }
            finally
            {
                S2AReadTouch = outer;
            }
        }

        /// <summary>
        /// Reprotect a given virtual region. The virtual memory manager will handle this.
        /// </summary>
        /// <param name="region">Region to reprotect</param>
        /// <param name="permission">Memory permission to protect with</param>
        /// <param name="guest">True if the protection is for guest access, false otherwise</param>
        internal void ProtectVirtualRegion(VirtualRegion region, MemoryPermission permission, bool guest)
        {
            _memoryManager.TrackingReprotect(region.Address, region.Size, permission, guest);
        }

        /// <summary>
        /// Returns the number of virtual regions currently being tracked.
        /// Useful for tests and metrics.
        /// </summary>
        /// <returns>The number of virtual regions</returns>
        public int GetRegionCount()
        {
            lock (TrackingLock)
            {
                return _virtualRegions.Count;
            }
        }
    }
}
