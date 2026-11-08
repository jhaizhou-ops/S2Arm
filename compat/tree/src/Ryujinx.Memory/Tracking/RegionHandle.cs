using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;

namespace Ryujinx.Memory.Tracking
{
    /// <summary>
    /// A tracking handle for a given region of virtual memory. The Dirty flag is updated whenever any changes are made,
    /// and an action can be performed when the region is read to or written from.
    /// </summary>
    public class RegionHandle : IRegionHandle
    {
        /// <summary>
        /// If more than this number of checks have been performed on a dirty flag since its last reprotect,
        /// then it is dirtied infrequently.
        /// </summary>
        private const int CheckCountForInfrequent = 3;

        /// <summary>
        /// Number of frequent dirty/consume in a row to make this handle volatile.
        /// </summary>
        private const int VolatileThreshold = 5;

        public bool Dirty
        {
            get
            {
                return Bitmap.IsSet(DirtyBit);
            }
            protected set
            {
                Bitmap.Set(DirtyBit, value);
            }
        }

        internal int SequenceNumber { get; set; }
        internal int Id { get; }

        public bool Unmapped { get; private set; }

        public ulong Address { get; }
        public ulong Size { get; }
        public ulong EndAddress { get; }

        public ulong RealAddress { get; }
        public ulong RealSize { get; }
        public ulong RealEndAddress { get; }

        internal IMultiRegionHandle Parent { get; set; }

        private event Action OnDirty;

        // S2A（帧率能耗线 10-22）：锁按需建（多数句柄从不注册动作；巫师3 换场景一帧建 8000+ 个句柄，每个 48 B）
        private Lock _preActionLock;
        private Lock PreActionLock => _preActionLock ?? Interlocked.CompareExchange(ref _preActionLock, new Lock(), null) ?? _preActionLock;
        private RegionSignal _preAction; // Action to perform before a read or write. This will block the memory access.
        private PreciseRegionSignal _preciseAction; // Action to perform on a precise read or write.
        private readonly List<VirtualRegion> _regions;
        private readonly List<VirtualRegion> _guestRegions;
        private readonly MemoryTracking _tracking;
        private bool _disposed;

        private int _checkCount = 0;
        private int _volatileCount = 0;
        private bool _volatile;

        internal MemoryPermission RequiredPermission
        {
            get
            {
                // If this is unmapped, allow reprotecting as RW as it can't be dirtied.
                // This is required for the partial unmap cases where part of the data are still being accessed.
                if (Unmapped)
                {
                    return MemoryPermission.ReadAndWrite;
                }

                if (_preAction != null)
                {
                    return MemoryPermission.None;
                }

                return Dirty ? MemoryPermission.ReadAndWrite : MemoryPermission.Read;
            }
        }

        internal RegionSignal PreAction => _preAction;

        internal ConcurrentBitmap Bitmap;
        internal int DirtyBit;

        /// <summary>
        /// Create a new bitmap backed region handle. The handle is registered with the given tracking object,
        /// and will be notified of any changes to the specified region.
        /// </summary>
        /// <param name="tracking">Tracking object for the target memory block</param>
        /// <param name="address">Virtual address of the region to track</param>
        /// <param name="size">Size of the region to track</param>
        /// <param name="realAddress">The real, unaligned address of the handle</param>
        /// <param name="realSize">The real, unaligned size of the handle</param>
        /// <param name="bitmap">The bitmap the dirty flag for this handle is stored in</param>
        /// <param name="bit">The bit index representing the dirty flag for this handle</param>
        /// <param name="id">Handle ID</param>
        /// <param name="flags">Region flags</param>
        /// <param name="mapped">True if the region handle starts mapped</param>
        /// <summary>S2A 诊断（帧率能耗线 10-22）：句柄累计新建 / 释放数、虚拟区域累计新建数（GPU 层每 Tick 看增量，判对象池能不能接住换场景）</summary>
        public static long S2ACreated, S2ADisposed, S2AVRegions;

        internal RegionHandle(
            MemoryTracking tracking,
            ulong address,
            ulong size,
            ulong realAddress,
            ulong realSize,
            ConcurrentBitmap bitmap,
            int bit,
            int id,
            RegionFlags flags,
            bool mapped = true)
        {
            Bitmap = bitmap;
            DirtyBit = bit;

            Dirty = mapped;

            Id = id;

            Unmapped = !mapped;
            Address = address;
            Size = size;
            EndAddress = address + size;

            RealAddress = realAddress;
            RealSize = realSize;
            RealEndAddress = realAddress + realSize;

            _tracking = tracking;

            _regions = tracking.GetVirtualRegionsForHandle(address, size, false);
            _guestRegions = GetGuestRegions(tracking, address, size, flags);
            System.Threading.Interlocked.Increment(ref S2ACreated);

            InitializeRegions();
        }

        /// <summary>
        /// Create a new region handle. The handle is registered with the given tracking object,
        /// and will be notified of any changes to the specified region.
        /// </summary>
        /// <param name="tracking">Tracking object for the target memory block</param>
        /// <param name="address">Virtual address of the region to track</param>
        /// <param name="size">Size of the region to track</param>
        /// <param name="realAddress">The real, unaligned address of the handle</param>
        /// <param name="realSize">The real, unaligned size of the handle</param>
        /// <param name="id">Handle ID</param>
        /// <param name="flags">Region flags</param>
        /// <param name="mapped">True if the region handle starts mapped</param>
        internal RegionHandle(MemoryTracking tracking, ulong address, ulong size, ulong realAddress, ulong realSize, int id, RegionFlags flags, bool mapped = true)
        {
            Bitmap = new ConcurrentBitmap(1, mapped);

            Id = id;

            Unmapped = !mapped;

            Address = address;
            Size = size;
            EndAddress = address + size;

            RealAddress = realAddress;
            RealSize = realSize;
            RealEndAddress = realAddress + realSize;

            _tracking = tracking;

            _regions = tracking.GetVirtualRegionsForHandle(address, size, false);
            _guestRegions = GetGuestRegions(tracking, address, size, flags);
            System.Threading.Interlocked.Increment(ref S2ACreated);

            InitializeRegions();
        }

        private static List<VirtualRegion> GetGuestRegions(MemoryTracking tracking, ulong address, ulong size, RegionFlags flags)
        {
            ulong guestAddress;
            ulong guestSize;

            if (flags.HasFlag(RegionFlags.UnalignedAccess))
            {
                (guestAddress, guestSize) = tracking.GetUnalignedSafeRegion(address, size);
            }
            else
            {
                (guestAddress, guestSize) = (address, size);
            }

            return tracking.GetVirtualRegionsForHandle(guestAddress, guestSize, true);
        }

        private void InitializeRegions()
        {
            foreach (VirtualRegion region in _regions)
            {
                region.Handles.Add(this);
            }

            foreach (VirtualRegion region in _guestRegions)
            {
                region.Handles.Add(this);
            }
        }

        /// <summary>
        /// Replace the bitmap and bit index used to track dirty state.
        /// </summary>
        /// <remarks>
        /// The tracking lock should be held when this is called, to ensure neither bitmap is modified.
        /// </remarks>
        /// <param name="bitmap">The bitmap the dirty flag for this handle is stored in</param>
        /// <param name="bit">The bit index representing the dirty flag for this handle</param>
        internal void ReplaceBitmap(ConcurrentBitmap bitmap, int bit)
        {
            // Assumes the tracking lock is held, so nothing else can signal right now.

            ConcurrentBitmap oldBitmap = Bitmap;
            int oldBit = DirtyBit;

            bitmap.Set(bit, Dirty);

            Bitmap = bitmap;
            DirtyBit = bit;

            Dirty |= oldBitmap.IsSet(oldBit);
        }

        /// <summary>
        /// Clear the volatile state of this handle.
        /// </summary>
        private void ClearVolatile()
        {
            _volatileCount = 0;
            _volatile = false;
        }

        /// <summary>
        /// Check if this handle is dirty, or if it is volatile. (changes very often)
        /// </summary>
        /// <returns>True if the handle is dirty or volatile, false otherwise</returns>
        public bool DirtyOrVolatile()
        {
            _checkCount++;
            return _volatile || Dirty;
        }

        /// <summary>
        /// Signal that a memory action occurred within this handle's virtual regions.
        /// </summary>
        /// <param name="address">Address accessed</param>
        /// <param name="size">Size of the region affected in bytes</param>
        /// <param name="write">Whether the region was written to or read</param>
        /// <param name="handleIterable">Reference to the handles being iterated, in case the list needs to be copied</param>
        /// <summary>S2A 部分回写：回写动作在本线程执行期间置真 = 动作执行完不撤（见 Signal）</summary>
        [ThreadStatic]
        public static bool S2AKeepAction;

        /// <summary>
        /// S2A（#1397 重入闸，等价原生 t_in_touch 上移一层）：本线程正在执行回写动作的句柄栈。
        /// 回写动作里取可写区会对仍在排空的区间再发收口读事件——8E 实测该自触发沿
        /// Signal→FlushAction→取可写区→再收口每级 12 帧约 0x640 字节无界叠宿主栈，8 MiB 也吃满
        /// （nx-84 确定性 SIGSEGV/SEGV_ACCERR）。信号命中在信号句柄自身时跳过动作（在跑的那次
        /// 调用本身就是这次信号要的回写，不重发、不延后——丢不得也无需补），同段其余别名句柄
        /// 照常同步执行，保「读之前先回写」的顺序语义。
        /// </summary>
        [ThreadStatic]
        private static List<RegionHandle> s2aInSignal;

        internal void Signal(ulong address, ulong size, bool write, ref IList<RegionHandle> handleIterable)
        {
            // If this handle was already unmapped (even if just partially),
            // then we have nothing to do until it is mapped again.
            // The pre-action should be still consumed to avoid flushing on remap.
            if (Unmapped)
            {
                Interlocked.Exchange(ref _preAction, null);
                return;
            }

            if (_preAction != null &&
                (MemoryTracking.S2AReadFlushNoGuard ||
                 s2aInSignal == null ||
                 !s2aInSignal.Contains(this)))
            {
                // Limit the range to within this handle.
                ulong maxAddress = Math.Max(address, RealAddress);
                ulong minEndAddress = Math.Min(address + size, RealAddress + RealSize);

                // Copy the handles list in case it changes when we're out of the lock.
                if (handleIterable is List<RegionHandle>)
                {
                    handleIterable = handleIterable.ToArray();
                }

                // Temporarily release the tracking lock while we're running the action.
                Monitor.Exit(_tracking.TrackingLock);

                bool consumed = false;
                try
                {
                    lock (PreActionLock)
                    {
                        (s2aInSignal ??= new List<RegionHandle>()).Add(this);
                        try
                        {
                            S2AKeepAction = false;
                            _preAction?.Invoke(maxAddress, minEndAddress - maxAddress);

                            // The action is removed after it returns, to ensure that the null check above succeeds when
                            // it's still in progress rather than continuing and possibly missing a required data flush.
                            // S2A：动作只回写了所碰的一段（部分回写）时置 S2AKeepAction：动作保留、保护保持 None，其余部分照旧拦（不留放开再登记的窗口）
                            if (!S2AKeepAction)
                            {
                                Interlocked.Exchange(ref _preAction, null);
                                consumed = true;
                            }

                            S2AKeepAction = false;
                        }
                        finally
                        {
                            s2aInSignal.RemoveAt(s2aInSignal.Count - 1);
                        }
                    }
                }
                finally
                {
                    Monitor.Enter(_tracking.TrackingLock);
                }

                // S2A（#1427 回归）：动作消费后把另一保护域也收口。动作可由宿主域信号跑完（GetSpan(tracked) 等
                // 托管读，VirtualMemoryEvent guest:false）——重入闸跳过嵌套同句柄信号后，_preAction 在外层宿主域
                // 信号里清掉，本域 Signal 的 UpdateProtection 只更新自己，guest 域仍停在「动作挂着」的 None 记账：
                // 原生 act/want 不再退，排空把页设回不可读，之后同段托管借用读直接缺页（8E DmaClass.Copy AV）。
                // 消费后按 RegisterActionImpl 同款把两域都重算——guest 域是唯一驱动真实页保护的域，必须收到
                // 非 None（act 退）；宿主域顺手同步，防 _lastPermission 记账漂移。S2AKeepAction 时 _preAction
                // 未清不算消费，两域照旧保持 None。
                if (consumed)
                {
                    foreach (VirtualRegion region in _regions)
                    {
                        region.UpdateProtection();
                    }

                    foreach (VirtualRegion region in _guestRegions)
                    {
                        region.UpdateProtection();
                    }
                }
            }

            if (write)
            {
                bool oldDirty = Dirty;
                Dirty = true;
                if (!oldDirty)
                {
                    OnDirty?.Invoke();
                }

                Parent?.SignalWrite();
            }
        }

        /// <summary>
        /// Signal that a precise memory action occurred within this handle's virtual regions.
        /// If there is no precise action, or the action returns false, the normal signal handler will be called.
        /// </summary>
        /// <param name="address">Address accessed</param>
        /// <param name="size">Size of the region affected in bytes</param>
        /// <param name="write">Whether the region was written to or read</param>
        /// <param name="handleIterable">Reference to the handles being iterated, in case the list needs to be copied</param>
        /// <returns>True if a precise action was performed and returned true, false otherwise</returns>
        internal bool SignalPrecise(ulong address, ulong size, bool write, ref IList<RegionHandle> handleIterable)
        {
            if (!Unmapped && _preciseAction != null && _preciseAction(address, size, write))
            {
                return true;
            }

            Signal(address, size, write, ref handleIterable);

            return false;
        }

        /// <summary>
        /// Force this handle to be dirty, without reprotecting.
        /// </summary>
        public void ForceDirty()
        {
            Dirty = true;
        }

        /// <summary>
        /// Consume the dirty flag for this handle, and reprotect so it can be set on the next write.
        /// </summary>
        /// <param name="asDirty">True if the handle should be reprotected as dirty, rather than have it cleared</param>
        /// <param name="consecutiveCheck">True if this reprotect is the result of consecutive dirty checks</param>
        public void Reprotect(bool asDirty, bool consecutiveCheck = false)
        {
            if (_volatile)
            {
                return;
            }

            Dirty = asDirty;

            bool protectionChanged = false;

            lock (_tracking.TrackingLock)
            {
                foreach (VirtualRegion region in _regions)
                {
                    protectionChanged |= region.UpdateProtection();
                }

                foreach (VirtualRegion region in _guestRegions)
                {
                    protectionChanged |= region.UpdateProtection();
                }
            }

            if (!protectionChanged)
            {
                // Counteract the check count being incremented when this handle was forced dirty.
                // It doesn't count for protected write tracking.

                _checkCount--;
            }
            else if (!asDirty)
            {
                if (consecutiveCheck || (_checkCount > 0 && _checkCount < CheckCountForInfrequent))
                {
                    if (++_volatileCount >= VolatileThreshold && _preAction == null)
                    {
                        _volatile = true;
                        return;
                    }
                }
                else
                {
                    _volatileCount = 0;
                }

                _checkCount = 0;
            }
        }

        /// <summary>
        /// Consume the dirty flag for this handle, and reprotect so it can be set on the next write.
        /// </summary>
        /// <param name="asDirty">True if the handle should be reprotected as dirty, rather than have it cleared</param>
        public void Reprotect(bool asDirty = false)
        {
            Reprotect(asDirty, false);
        }

        /// <summary>
        /// Register an action to perform when the tracked region is read or written.
        /// The action is automatically removed after it runs.
        /// </summary>
        /// <param name="action">Action to call on read or write</param>
        public void RegisterAction(RegionSignal action)
        {
            ClearVolatile();

            lock (PreActionLock)
            {
                if (_tracking.ReprotectOnActionRegistration)
                {
                    // Publish the action and its native generation under the same lock
                    // used by Signal's final protection update. Publishing the action
                    // before acquiring this lock leaves a second unnotified-action race.
                    lock (_tracking.TrackingLock)
                    {
                        RegisterActionImpl(action);
                    }
                }
                else
                {
                    RegisterActionImpl(action);
                }
            }
        }

        private void RegisterActionImpl(RegionSignal action)
        {
            RegionSignal lastAction = Interlocked.Exchange(ref _preAction, action);

            if (lastAction == null && action != lastAction)
            {
                lock (_tracking.TrackingLock)
                {
                    foreach (VirtualRegion region in _regions)
                    {
                        region.UpdateProtection();
                    }

                    foreach (VirtualRegion region in _guestRegions)
                    {
                        // Signal releases TrackingLock while invoking the previous action.
                        // A new registration can win the lock before Signal updates None
                        // back to Read/RW. Publish this new action even if None is unchanged.
                        region.UpdateProtection(_tracking.ReprotectOnActionRegistration);
                    }
                }
            }
        }

        /// <summary>
        /// Register an action to perform when a precise access occurs (one with exact address and size).
        /// If the action returns true, read/write tracking are skipped.
        /// </summary>
        /// <param name="action">Action to call on read or write</param>
        public void RegisterPreciseAction(PreciseRegionSignal action)
        {
            _preciseAction = action;
        }

        /// <summary>
        /// S2A（帧率能耗线 10-23，贴图假共享）：精确访问 [address, address+size) 与本句柄真实字节区间 [RealAddress, RealAddress+RealSize) 不相交。
        /// 跟踪按页对齐登记，同一 4 KB 子页里贴图旁边的别的数据被游戏写，原版也会把整张贴图回写并标脏；访问没碰本句柄的字节时两样都不需要。
        /// size 为 0 按相交处理（保守）
        /// </summary>
        public static bool S2AOutsideReal(RegionHandle handle, ulong address, ulong size)
        {
            return size != 0 && (address + size <= handle.RealAddress || address >= handle.RealAddress + handle.RealSize);
        }

        /// <summary>
        /// Register an action to perform when the region is written to.
        /// This action will not be removed when it is called - it is called each time the dirty flag is set.
        /// </summary>
        /// <param name="action">Action to call on dirty</param>
        public void RegisterDirtyEvent(Action action)
        {
            OnDirty += action;
        }

        /// <summary>
        /// Add a child virtual region to this handle.
        /// </summary>
        /// <param name="region">Virtual region to add as a child</param>
        internal void AddChild(VirtualRegion region)
        {
            if (region.Guest)
            {
                _guestRegions.Add(region);
            }
            else
            {
                _regions.Add(region);
            }
        }

        /// <summary>
        /// Signal that this handle has been mapped or unmapped.
        /// </summary>
        /// <param name="mapped">True if the handle has been mapped, false if unmapped</param>
        internal void SignalMappingChanged(bool mapped)
        {
            if (Unmapped == mapped)
            {
                Unmapped = !mapped;

                if (Unmapped)
                {
                    ClearVolatile();
                    Dirty = false;
                }
            }
        }

        /// <summary>
        /// Check if this region overlaps with another.
        /// </summary>
        /// <param name="address">Base address</param>
        /// <param name="size">Size of the region</param>
        /// <returns>True if overlapping, false otherwise</returns>
        public bool OverlapsWith(ulong address, ulong size)
        {
            return Address < address + size && address < EndAddress;
        }

        /// <summary>
        /// Determines if this handle's memory range matches another exactly.
        /// </summary>
        /// <param name="other">The other handle</param>
        /// <returns>True on a match, false otherwise</returns>
        public bool RangeEquals(RegionHandle other)
        {
            return RealAddress == other.RealAddress && RealSize == other.RealSize;
        }

        /// <summary>
        /// Dispose the handle. Within the tracking lock, this removes references from virtual regions.
        /// </summary>
        public void Dispose()
        {
            ObjectDisposedException.ThrowIf(_disposed, this);

            GC.SuppressFinalize(this);

            _disposed = true;
            System.Threading.Interlocked.Increment(ref S2ADisposed);

            lock (_tracking.TrackingLock)
            {
                foreach (VirtualRegion region in _regions)
                {
                    region.RemoveHandle(this);
                }

                foreach (VirtualRegion region in _guestRegions)
                {
                    region.RemoveHandle(this);
                }
            }
        }
    }
}
