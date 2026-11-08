using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu.Memory;
using Ryujinx.Graphics.Texture;
using Ryujinx.Memory;
using Ryujinx.Memory.Range;
using Ryujinx.Memory.Tracking;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.CompilerServices;

namespace Ryujinx.Graphics.Gpu.Image
{
    /// <summary>
    /// An overlapping texture group with a given view compatibility.
    /// </summary>
    readonly struct TextureIncompatibleOverlap
    {
        public readonly TextureGroup Group;
        public readonly TextureViewCompatibility Compatibility;

        /// <summary>
        /// Create a new texture incompatible overlap.
        /// </summary>
        /// <param name="group">The group that is incompatible</param>
        /// <param name="compatibility">The view compatibility for the group</param>
        public TextureIncompatibleOverlap(TextureGroup group, TextureViewCompatibility compatibility)
        {
            Group = group;
            Compatibility = compatibility;
        }
    }

    /// <summary>
    /// A texture group represents a group of textures that belong to the same storage.
    /// When views are created, this class will track memory accesses for them separately.
    /// The group iteratively adds more granular tracking as views of different kinds are added.
    /// Note that a texture group can be absorbed into another when it becomes a view parent.
    /// </summary>
    class TextureGroup : IDisposable
    {
        /// <summary>
        /// Threshold of layers to force granular handles (and thus partial loading) on array/3D textures.
        /// </summary>
        private const int GranularLayerThreshold = 8;

        private delegate bool HandlesCallbackDelegate(int baseHandle, int regionCount, bool split = false, bool specialData = false);

        private readonly HandlesCallbackDelegate _signalModifyingCallback;
        private readonly HandlesCallbackDelegate _signalModifiedCallback;   // S2A：原 lambda 隐式捕获 this，每次 SignalModified 新建一个委托（48 B；巫师3 计算派发贴图提交 / 2D 拷贝稳态各 48 B）
        private readonly HandlesCallbackDelegate _discardDataCallback;
        private readonly HandlesCallbackDelegate _checkDirtyCallback;
        private readonly HandlesCallbackDelegate _synchronizeMemoryCallback;   // S2A：同步回调缓存成委托（原 lambda 捕获 texture，每次同步分配闭包 + 委托 80 B；动森渲染线程每帧一次，10-20 拆账实测）
        private Texture _syncTexture;   // S2A：_synchronizeMemoryCallback 正在同步的贴图（同 _loadNeeded，本来就不可并发；嵌套调用按栈保存恢复）

        /// <summary>
        /// The storage texture associated with this group.
        /// </summary>
        public Texture Storage { get; }

        /// <summary>
        /// Indicates if the texture has copy dependencies. If true, then all modifications
        /// must be signalled to the group, rather than skipping ones still to be flushed.
        /// </summary>
        public bool HasCopyDependencies { get; set; }

        /// <summary>
        /// Indicates if the texture group has a pre-emptive flush buffer.
        /// When one is present, the group must always be notified on unbind.
        /// </summary>
        public bool HasFlushBuffer => _flushBuffer != BufferHandle.Null;

        /// <summary>
        /// Indicates if this texture has any incompatible overlaps alive.
        /// </summary>
        public bool HasIncompatibleOverlaps => _incompatibleOverlaps.Count > 0;

        /// <summary>
        /// Number indicating the order this texture group was modified relative to others.
        /// </summary>
        public long ModifiedSequence { get; private set; }

        private readonly GpuContext _context;
        private readonly PhysicalMemory _physicalMemory;

        private int[] _allOffsets;
        private int[] _sliceSizes;
        private readonly bool _is3D;
        private readonly bool _isBuffer;
        private bool _hasMipViews;
        private bool _hasLayerViews;
        private readonly int _layers;
        private readonly int _levels;

        private MultiRange TextureRange => Storage.Range;

        /// <summary>
        /// The views array from the storage texture.
        /// </summary>
        private Texture[] _views;
        private TextureGroupHandle[] _handles;
        private bool[] _loadNeeded;

        /// <summary>
        /// Other texture groups that have incompatible overlaps with this one.
        /// </summary>
        private readonly List<TextureIncompatibleOverlap> _incompatibleOverlaps;
        private bool _incompatibleOverlapsDirty = true;
        private readonly bool _flushIncompatibleOverlaps;

        private BufferHandle _flushBuffer;
        private bool _flushBufferImported;
        private bool _flushBufferInvalid;

        /// <summary>
        /// Create a new texture group.
        /// </summary>
        /// <param name="context">GPU context that the texture group belongs to</param>
        /// <param name="physicalMemory">Physical memory where the <paramref name="storage"/> texture is mapped</param>
        /// <param name="storage">The storage texture for this group</param>
        /// <param name="incompatibleOverlaps">Groups that overlap with this one but are incompatible</param>
        public TextureGroup(GpuContext context, PhysicalMemory physicalMemory, Texture storage, List<TextureIncompatibleOverlap> incompatibleOverlaps)
        {
            Storage = storage;
            _context = context;
            _physicalMemory = physicalMemory;

            _is3D = storage.Info.Target == Target.Texture3D;
            _isBuffer = storage.Info.Target == Target.TextureBuffer;
            _layers = storage.Info.GetSlices();
            _levels = storage.Info.Levels;

            _incompatibleOverlaps = incompatibleOverlaps;
            _flushIncompatibleOverlaps = TextureCompatibility.IsFormatHostIncompatible(storage.Info, context.Capabilities);

            _signalModifyingCallback = SignalModifyingCallback;
            _signalModifiedCallback = SignalModifiedCallback;
            _discardDataCallback = DiscardDataCallback;
            _checkDirtyCallback = CheckDirtyCallback;
            _synchronizeMemoryCallback = SynchronizeMemoryCallback;
        }

        /// <summary>
        /// Initialize a new texture group's dirty regions and offsets.
        /// </summary>
        /// <param name="size">Size info for the storage texture</param>
        /// <param name="hasLayerViews">True if the storage will have layer views</param>
        /// <param name="hasMipViews">True if the storage will have mip views</param>
        public void Initialize(ref SizeInfo size, bool hasLayerViews, bool hasMipViews)
        {
            long s2aAlloc = S2AAllocTrace.Mark();
            _allOffsets = size.AllOffsets;
            _sliceSizes = size.SliceSizes;

            if (Storage.Target.HasDepthOrLayers && Storage.Info.GetSlices() > GranularLayerThreshold)
            {
                _hasLayerViews = true;
                _hasMipViews = true;
            }
            else
            {
                (_hasLayerViews, _hasMipViews) = PropagateGranularity(hasLayerViews, hasMipViews);

                // If the texture is partially mapped, fully subdivide handles immediately.

                MultiRange range = Storage.Range;
                for (int i = 0; i < range.Count; i++)
                {
                    if (range.GetSubRange(i).Address == MemoryManager.PteUnmapped)
                    {
                        _hasLayerViews = true;
                        _hasMipViews = true;

                        break;
                    }
                }
            }

            RecalculateHandleRegions();
            S2AAllocTrace.Step(0x70_0003, ref s2aAlloc);
        }

        /// <summary>
        /// Initialize all incompatible overlaps in the list, registering them with the other texture groups
        /// and creating copy dependencies when partially compatible.
        /// </summary>
        public void InitializeOverlaps()
        {
            foreach (TextureIncompatibleOverlap overlap in _incompatibleOverlaps)
            {
                if (overlap.Compatibility == TextureViewCompatibility.LayoutIncompatible)
                {
                    CreateCopyDependency(overlap.Group, false);
                }

                overlap.Group._incompatibleOverlaps.Add(new TextureIncompatibleOverlap(this, overlap.Compatibility));
                overlap.Group._incompatibleOverlapsDirty = true;
            }

            if (_incompatibleOverlaps.Count > 0)
            {
                SignalIncompatibleOverlapModified();
            }
        }

        /// <summary>
        /// Signal that the group is dirty to all views and the storage.
        /// </summary>
        private void SignalAllDirty()
        {
            Storage.SignalGroupDirty();
            if (_views != null)
            {
                foreach (Texture texture in _views)
                {
                    texture.SignalGroupDirty();
                }
            }
        }

        /// <summary>
        /// Signal that an incompatible overlap has been modified.
        /// If this group must flush incompatible overlaps, the group is signalled as dirty too.
        /// </summary>
        private void SignalIncompatibleOverlapModified()
        {
            _incompatibleOverlapsDirty = true;

            if (_flushIncompatibleOverlaps)
            {
                SignalAllDirty();
            }
        }

        /// <summary>
        /// Flushes incompatible overlaps if the storage format requires it, and they have been modified.
        /// This allows unsupported host formats to accept data written to format aliased textures.
        /// </summary>
        /// <returns>True if data was flushed, false otherwise</returns>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public bool FlushIncompatibleOverlapsIfNeeded()
        {
            if (_flushIncompatibleOverlaps && _incompatibleOverlapsDirty)
            {
                bool flushed = false;

                foreach (TextureIncompatibleOverlap overlap in _incompatibleOverlaps)
                {
                    S2AReadTag.Current = "不兼容重叠回写";
                    flushed |= overlap.Group.Storage.FlushModified(true);
                    S2AReadTag.Current = null;
                }

                _incompatibleOverlapsDirty = false;

                return flushed;
            }
            else
            {
                return false;
            }
        }

        /// <summary>
        /// Check and optionally consume the dirty flags for a given texture.
        /// The state is shared between views of the same layers and levels.
        /// </summary>
        /// <param name="texture">The texture being used</param>
        /// <param name="consume">True to consume the dirty flags and reprotect, false to leave them as is</param>
        /// <returns>True if a flag was dirty, false otherwise</returns>
        public bool CheckDirty(Texture texture, bool consume)
        {
            EvaluateRelevantHandles(texture, _checkDirtyCallback, out bool dirty, consume);

            return dirty;
        }

        bool CheckDirtyCallback(int baseHandle, int regionCount, bool split, bool consume)
        {
            bool dirty = false;

            for (int i = 0; i < regionCount; i++)
            {
                TextureGroupHandle group = _handles[baseHandle + i];

                foreach (RegionHandle handle in group.Handles)
                {
                    if (handle.Dirty)
                    {
                        if (consume)
                        {
                            handle.Reprotect();
                        }

                        dirty = true;
                    }
                }
            }

            return dirty;
        }

        /// <summary>
        /// Discards all data for a given texture.
        /// This clears all dirty flags and pending copies from other textures.
        /// </summary>
        /// <param name="texture">The texture being discarded</param>
        /// <summary>
        /// S2A：组里有没有被 GPU 改过、还没回写进客体内存的句柄（CPU 直写这段内存会先触发回写：等 GPU 做完 + 读回）。
        /// </summary>
        public bool S2AAnyGpuModified()
        {
            TextureGroupHandle[] handles = _handles;

            if (handles == null)
            {
                return false;
            }

            foreach (TextureGroupHandle handle in handles)
            {
                if (handle.Modified)
                {
                    return true;
                }
            }

            return false;
        }

        public void DiscardData(Texture texture)
        {
            EvaluateRelevantHandles(texture, _discardDataCallback, out _);
        }

        bool DiscardDataCallback(int baseHandle, int regionCount, bool split, bool bound)
        {
            for (int i = 0; i < regionCount; i++)
            {
                TextureGroupHandle group = _handles[baseHandle + i];

                group.DiscardData();
            }

            return true;
        }

        /// <summary>
        /// Synchronize memory for a given texture.
        /// If overlapping tracking handles are dirty, fully or partially synchronize the texture data.
        /// </summary>
        /// <param name="texture">The texture being used</param>
        public void SynchronizeMemory(Texture texture)
        {
            FlushIncompatibleOverlapsIfNeeded();

            Texture prev = _syncTexture;
            _syncTexture = texture;

            try
            {
                EvaluateRelevantHandles(texture, _synchronizeMemoryCallback, out _);
            }
            finally
            {
                _syncTexture = prev;
            }
        }

        private bool SynchronizeMemoryCallback(int baseHandle, int regionCount, bool split, bool bound)
        {
            Texture texture = _syncTexture;

            bool dirty = false;
            bool anyModified = false;
            bool anyNotDirty = false;

            for (int i = 0; i < regionCount; i++)
            {
                TextureGroupHandle group = _handles[baseHandle + i];

                bool modified = group.Modified;
                bool handleDirty = false;
                bool handleUnmapped = false;

                foreach (RegionHandle handle in group.Handles)
                {
                    if (handle.Dirty)
                    {
                        handle.Reprotect();
                        handleDirty = true;
                    }
                    else
                    {
                        handleUnmapped |= handle.Unmapped;
                    }
                }

                // If the modified flag is still present, prefer the data written from gpu.
                // A write from CPU will do a flush before writing its data, which should unset this.
                if (modified)
                {
                    handleDirty = false;
                }

                // Evaluate if any copy dependencies need to be fulfilled. A few rules:
                // If the copy handle needs to be synchronized, prefer our own state.
                // If we need to be synchronized and there is a copy present, prefer the copy.

                if (group.NeedsCopy && group.Copy(_context))
                {
                    anyModified |= true; // The copy target has been modified.
                    handleDirty = false;
                }
                else
                {
                    anyModified |= modified;
                    dirty |= handleDirty;
                }

                if (group.NeedsCopy)
                {
                    // The texture we copied from is still being written to. Copy from it again the next time this texture is used.
                    texture.SignalGroupDirty();
                }

                bool loadNeeded = handleDirty && !handleUnmapped;

                anyNotDirty |= !loadNeeded;
                _loadNeeded[baseHandle + i] = loadNeeded;
            }

            if (dirty)
            {
                if (anyNotDirty || (_handles.Length > 1 && (anyModified || split)))
                {
                    // Partial texture invalidation. Only update the layers/levels with dirty flags of the storage.

                    SynchronizePartial(baseHandle, regionCount);
                }
                else
                {
                    // Full texture invalidation.

                    texture.SynchronizeFull();
                }
            }

            return true;
        }

        /// <summary>
        /// Synchronize part of the storage texture, represented by a given range of handles.
        /// Only handles marked by the _loadNeeded array will be synchronized.
        /// </summary>
        /// <param name="baseHandle">The base index of the range of handles</param>
        /// <param name="regionCount">The number of handles to synchronize</param>
        private void SynchronizePartial(int baseHandle, int regionCount)
        {
            int spanEndIndex = -1;
            int spanBase = 0;
            ReadOnlySpan<byte> dataSpan = ReadOnlySpan<byte>.Empty;
            MemoryOwner<byte> s2aScratch = null;   // 纹理读取租约：换下一段 / 离开时还
            try
            {
            for (int i = 0; i < regionCount; i++)
            {
                if (_loadNeeded[baseHandle + i])
                {
                    (int BaseLayer, int BaseLevel, int Levels, int Layers, int Index) info = GetHandleInformation(baseHandle + i);

                    // Ensure the data for this handle is loaded in the span.
                    if (spanEndIndex <= i - 1)
                    {
                        spanEndIndex = i;

                        if (_is3D)
                        {
                            // Look ahead to see how many handles need to be loaded.
                            for (int j = i + 1; j < regionCount; j++)
                            {
                                if (_loadNeeded[baseHandle + j])
                                {
                                    spanEndIndex = j;
                                }
                                else
                                {
                                    break;
                                }
                            }
                        }

                        (int BaseLayer, int BaseLevel, int Levels, int Layers, int Index) endInfo = spanEndIndex == i ? info : GetHandleInformation(baseHandle + spanEndIndex);

                        spanBase = _allOffsets[info.Index];
                        int spanLast = _allOffsets[endInfo.Index + endInfo.Layers * endInfo.Levels - 1];
                        int endOffset = Math.Min(spanLast + _sliceSizes[endInfo.BaseLevel + endInfo.Levels - 1], (int)Storage.Size);
                        int size = endOffset - spanBase;

                        MultiRange s2aSlice = Storage.Range.Slice((ulong)spanBase, (ulong)size);
                        s2aScratch?.Dispose();
                        s2aScratch = null;
                        dataSpan = _physicalMemory.S2AGetTextureReadSpan(s2aSlice, out s2aScratch);
                    }

                    // Only one of these will be greater than 1, as partial sync is only called when there are sub-image views.
                    for (int layer = 0; layer < info.Layers; layer++)
                    {
                        for (int level = 0; level < info.Levels; level++)
                        {
                            int offsetIndex = GetOffsetIndex(info.BaseLayer + layer, info.BaseLevel + level);
                            int offset = _allOffsets[offsetIndex];

                            ReadOnlySpan<byte> data = dataSpan[(offset - spanBase)..];

                            MemoryOwner<byte> result = Storage.ConvertToHostCompatibleFormat(data, info.BaseLevel + level, true);

                            Storage.SetData(result, info.BaseLayer + layer, info.BaseLevel + level);
                        }
                    }
                }
            }
            }
            finally
            {
                s2aScratch?.Dispose();
            }
        }

        /// <summary>
        /// Synchronize dependent textures, if any of them have deferred a copy from the given texture.
        /// </summary>
        /// <param name="texture">The texture to synchronize dependents of</param>
        public void SynchronizeDependents(Texture texture)
        {
            EvaluateRelevantHandles(texture, (baseHandle, regionCount, split, bound) =>
            {
                for (int i = 0; i < regionCount; i++)
                {
                    TextureGroupHandle group = _handles[baseHandle + i];

                    group.SynchronizeDependents();
                }

                return true;
            }, out _);
        }

        /// <summary>
        /// Determines whether flushes in this texture group should be tracked.
        /// Incompatible overlaps may need data from this texture to flush tracked for it to be visible to them.
        /// </summary>
        /// <returns>True if flushes should be tracked, false otherwise</returns>
        private bool ShouldFlushTriggerTracking()
        {
            foreach (TextureIncompatibleOverlap overlap in _incompatibleOverlaps)
            {
                if (overlap.Group._flushIncompatibleOverlaps)
                {
                    return true;
                }
            }

            return false;
        }

        /// <summary>
        /// Gets data from the host GPU, and flushes a slice to guest memory.
        /// </summary>
        /// <remarks>
        /// This method should be used to retrieve data that was modified by the host GPU.
        /// This is not cheap, avoid doing that unless strictly needed.
        /// When possible, the data is written directly into guest memory, rather than copied.
        /// </remarks>
        /// <param name="tracked">True if writing the texture data is tracked, false otherwise</param>
        /// <param name="sliceIndex">The index of the slice to flush</param>
        /// <param name="inBuffer">Whether the flushed texture data is up to date in the flush buffer</param>
        /// <param name="texture">The specific host texture to flush. Defaults to the storage texture</param>
        private void FlushTextureDataSliceToGuest(bool tracked, int sliceIndex, bool inBuffer, ITexture texture = null)
        {
            (int layer, int level) = GetLayerLevelForView(sliceIndex);

            int offset = _allOffsets[sliceIndex];
            int endOffset = Math.Min(offset + _sliceSizes[level], (int)Storage.Size);
            int size = endOffset - offset;

            using WritableRegion region = _physicalMemory.GetWritableRegion(Storage.Range.Slice((ulong)offset, (ulong)size), tracked);

            if (inBuffer)
            {
                using PinnedSpan<byte> data = _context.Renderer.GetBufferData(_flushBuffer, offset, size);

                Storage.ConvertFromHostCompatibleFormat(region.Memory.Span, data.Get(), level, true);
            }
            else
            {
                Storage.GetTextureDataSliceFromGpu(region.Memory.Span, layer, level, tracked, texture);
            }
        }

        /// <summary>
        /// Gets and flushes a number of slices of the storage texture to guest memory.
        /// </summary>
        /// <param name="tracked">True if writing the texture data is tracked, false otherwise</param>
        /// <param name="sliceStart">The first slice to flush</param>
        /// <param name="sliceEnd">The slice to finish flushing on (exclusive)</param>
        /// <param name="inBuffer">Whether the flushed texture data is up to date in the flush buffer</param>
        /// <param name="texture">The specific host texture to flush. Defaults to the storage texture</param>
        private void FlushSliceRange(bool tracked, int sliceStart, int sliceEnd, bool inBuffer, ITexture texture = null)
        {
            for (int i = sliceStart; i < sliceEnd; i++)
            {
                FlushTextureDataSliceToGuest(tracked, i, inBuffer, texture);
            }
        }

        /// <summary>
        /// Flush modified ranges for a given texture.
        /// </summary>
        /// <param name="texture">The texture being used</param>
        /// <param name="tracked">True if the flush writes should be tracked, false otherwise</param>
        /// <returns>True if data was flushed, false otherwise</returns>
        public bool FlushModified(Texture texture, bool tracked)
        {
            tracked = tracked || ShouldFlushTriggerTracking();
            bool flushed = false;

            EvaluateRelevantHandles(texture, (baseHandle, regionCount, split, bound) =>
            {
                int startSlice = 0;
                int endSlice = 0;
                bool allModified = true;

                for (int i = 0; i < regionCount; i++)
                {
                    TextureGroupHandle group = _handles[baseHandle + i];

                    if (group.Modified)
                    {
                        if (endSlice < group.BaseSlice)
                        {
                            if (endSlice > startSlice)
                            {
                                FlushSliceRange(tracked, startSlice, endSlice, false);
                                flushed = true;
                            }

                            startSlice = group.BaseSlice;
                        }

                        endSlice = group.BaseSlice + group.SliceCount;

                        if (tracked)
                        {
                            group.Modified = false;

                            foreach (Texture texture in group.Overlaps)
                            {
                                texture.SignalModifiedDirty();
                            }
                        }
                    }
                    else
                    {
                        allModified = false;
                    }
                }

                if (endSlice > startSlice)
                {
                    if (allModified && !split)
                    {
                        texture.Flush(tracked);
                    }
                    else
                    {
                        FlushSliceRange(tracked, startSlice, endSlice, false);
                    }

                    flushed = true;
                }

                return true;
            }, out _);

            Storage.SignalModifiedDirty();

            return flushed;
        }

        /// <summary>
        /// Flush the texture data into a persistently mapped buffer.
        /// If the buffer does not exist, this method will create it.
        /// </summary>
        /// <param name="handle">Handle of the texture group to flush slices of</param>
        // S2A 部分回写：条件全满足才做（否则返回 false，照旧整张回写）。见 Ryujinx.Graphics.Texture.S2APartialLayout
        private bool S2ATryPartialFlush(TextureGroupHandle handle, ulong address, ulong size, out ulong pAddr, out ulong pSize)
        {
            pAddr = pSize = 0;
            TextureInfo info = Storage.Info;
            int bpp = info.FormatInfo.BytesPerPixel;

            if (_flushBuffer == BufferHandle.Null || _flushBufferImported || info.Target != Target.Texture2D || info.Levels != 1 || info.GetSlices() != 1 ||
                info.IsLinear || info.FormatInfo.BlockWidth != 1 || info.FormatInfo.BlockHeight != 1 || info.GobBlocksInTileX != 1 || info.GobBlocksInZ != 1 ||
                handle.BaseSlice != 0 || handle.SliceCount != 1 || Storage.Range.Count != 1 || Storage.Size < 0x10000 ||
                (info.Width * bpp) % 16 != 0 || (bpp & (bpp - 1)) != 0 || bpp > 16)
            {
                return false;
            }

            ulong baseAddr = Storage.Range.GetSubRange(0).Address;

            if (address < baseAddr)
            {
                return false;
            }

            int texSize = (int)Storage.Size;
            int off = (int)(address - baseAddr) & ~0xFFF;
            int end = Math.Min(texSize, (int)((address + size - baseAddr + 0xFFF) & ~0xFFFUL));
            int len = end - off;

            if (len <= 0 || len > texSize / 8 || (len & 511) != 0 ||
                !S2APartialLayout.RowRange(off, len, info.Width, info.Height, bpp, info.GobBlocksInY, out int rowMin, out int rowMax))
            {
                return false;
            }

            int stride = S2APartialLayout.HostStride(info.Width, bpp);

            using PinnedSpan<byte> data = _context.Renderer.GetBufferData(_flushBuffer, _allOffsets[0] + rowMin * stride, (rowMax - rowMin + 1) * stride);
            using WritableRegion region = _physicalMemory.GetWritableRegion(Storage.Range.Slice((ulong)off, (ulong)len), false);

            S2APartialLayout.Write(region.Memory.Span, off, info.Width, info.Height, bpp, info.GobBlocksInY, data.Get(), rowMin, stride);
            S2APartialFlush.Count++;
            pAddr = baseAddr + (ulong)off;
            pSize = (ulong)len;

            return true;
        }

        public void FlushIntoBuffer(TextureGroupHandle handle)
        {
            if (S2ATexFlushStat.On) System.Threading.Interlocked.Increment(ref S2ATexFlushStat.Prefill);
            // Ensure that the buffer exists.

            if (_flushBufferInvalid && _flushBuffer != BufferHandle.Null)
            {
                _flushBufferInvalid = false;
                _context.Renderer.DeleteBuffer(_flushBuffer);
                _flushBuffer = BufferHandle.Null;
            }

            if (_flushBuffer == BufferHandle.Null)
            {
                if (!TextureCompatibility.CanTextureFlush(Storage.Info, _context.Capabilities))
                {
                    return;
                }

                bool canImport = Storage.Info.IsLinear && Storage.Info.Stride >= Storage.Info.Width * Storage.Info.FormatInfo.BytesPerPixel;

                nint hostPointer = canImport ? _physicalMemory.GetHostPointer(Storage.Range) : 0;

                if (hostPointer != 0 && _context.Renderer.PrepareHostMapping(hostPointer, Storage.Size))
                {
                    _flushBuffer = _context.Renderer.CreateBuffer(hostPointer, (int)Storage.Size);
                    _flushBufferImported = true;
                }
                else
                {
                    _flushBuffer = _context.Renderer.CreateBuffer((int)Storage.Size, BufferAccess.HostMemory);
                    _flushBufferImported = false;
                }

                Storage.BlacklistScale();
            }

            int sliceStart = handle.BaseSlice;
            int sliceEnd = sliceStart + handle.SliceCount;

            for (int i = sliceStart; i < sliceEnd; i++)
            {
                (int layer, int level) = GetLayerLevelForView(i);

                Storage.GetFlushTexture().CopyTo(new BufferRange(_flushBuffer, _allOffsets[i], _sliceSizes[level]), layer, level, _flushBufferImported ? Storage.Info.Stride : 0);
            }
        }

        /// <summary>
        /// Clears competing modified flags for all incompatible ranges, if they have possibly been modified.
        /// </summary>
        /// <param name="texture">The texture that has been modified</param>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private void ClearIncompatibleOverlaps(Texture texture)
        {
            if (_incompatibleOverlapsDirty)
            {
                foreach (TextureIncompatibleOverlap incompatible in _incompatibleOverlaps)
                {
                    incompatible.Group.ClearModified(texture.Range, this);

                    incompatible.Group.SignalIncompatibleOverlapModified();
                }

                _incompatibleOverlapsDirty = false;
            }
        }

        /// <summary>
        /// Signal that a texture in the group has been modified by the GPU.
        /// </summary>
        /// <param name="texture">The texture that has been modified</param>
        // S2A（帧率能耗线 10-23）：GPU 写了这组贴图（渲染目标绑定 / 图像存储写 / 拷贝）→ 整组内存登记成定向读时回写页（每组一次）。
        // 写跟踪缺省只拦写不拦读，游戏读渲染目标里 GPU 画了、还没回写的字节拿到旧值：塞尔达站立贴地读的就是渲染目标（16×1 / 16×3 R16G16B16A16Float 等，
        // Mac 同存档诊断局：游戏真读到 GPU 改过子页的贴图全部是渲染目标写的）。登记后游戏读先回写，同 Ryujinx 原版
        private bool _s2aReadFlushMarked;

        private void S2AMarkReadFlushOnce()
        {
            // 缺省关（开关与读数见 Buffer.S2AGpuReadFlush）
            if (!Ryujinx.Graphics.Gpu.Memory.Buffer.S2AGpuReadFlush || _s2aReadFlushMarked)
            {
                return;
            }

            _s2aReadFlushMarked = true;
            MultiRange range = Storage.Range;

            for (int i = 0; i < range.Count; i++)
            {
                MemoryRange sub = range.GetSubRange(i);
                Ryujinx.Graphics.Gpu.Memory.MemoryManager.S2AMarkReadFlush(sub.Address, sub.Size);
            }
        }

        public void SignalModified(Texture texture)
        {
            ModifiedSequence = _context.GetModifiedSequence();
            S2AMarkReadFlushOnce();

            ClearIncompatibleOverlaps(texture);

            EvaluateRelevantHandles(texture, _signalModifiedCallback, out _);
        }

        bool SignalModifiedCallback(int baseHandle, int regionCount, bool split, bool bound)
        {
            for (int i = 0; i < regionCount; i++)
            {
                TextureGroupHandle group = _handles[baseHandle + i];

                group.SignalModified(_context);
            }

            return true;
        }

        /// <summary>
        /// Signal that a texture in the group is actively bound, or has been unbound by the GPU.
        /// </summary>
        /// <param name="texture">The texture that has been modified</param>
        /// <param name="bound">True if this texture is being bound, false if unbound</param>
        public void SignalModifying(Texture texture, bool bound)
        {
            ModifiedSequence = _context.GetModifiedSequence();

            if (bound)
            {
                S2AMarkReadFlushOnce();
            }

            ClearIncompatibleOverlaps(texture);

            EvaluateRelevantHandles(texture, _signalModifyingCallback, out _, bound);
        }

        bool SignalModifyingCallback(int baseHandle, int regionCount, bool split, bool bound)
        {
            for (int i = 0; i < regionCount; i++)
            {
                TextureGroupHandle group = _handles[baseHandle + i];

                group.SignalModifying(bound, _context);
            }

            return true;
        }

        /// <summary>
        /// Register a read/write action to flush for a texture group.
        /// </summary>
        /// <param name="group">The group to register an action for</param>
        public void RegisterAction(TextureGroupHandle group)
        {
            foreach (RegionHandle handle in group.Handles)
            {
                handle.RegisterAction((address, size) => FlushAction(group, address, size));
            }
        }

        /// <summary>
        /// Propagates the mip/layer view flags depending on the texture type.
        /// When the most granular type of subresource has views, the other type of subresource must be segmented granularly too.
        /// </summary>
        /// <param name="hasLayerViews">True if the storage has layer views</param>
        /// <param name="hasMipViews">True if the storage has mip views</param>
        /// <returns>The input values after propagation</returns>
        private (bool HasLayerViews, bool HasMipViews) PropagateGranularity(bool hasLayerViews, bool hasMipViews)
        {
            if (_is3D)
            {
                hasMipViews |= hasLayerViews;
            }
            else
            {
                hasLayerViews |= hasMipViews;
            }

            return (hasLayerViews, hasMipViews);
        }

        /// <summary>
        /// Evaluate the range of tracking handles which a view texture overlaps with.
        /// </summary>
        /// <param name="texture">The texture to get handles for</param>
        /// <param name="callback">
        /// A function to be called with the base index of the range of handles for the given texture, and the number of handles it covers.
        /// This can be called for multiple disjoint ranges, if required.
        /// </param>
        private void EvaluateRelevantHandles(Texture texture, HandlesCallbackDelegate callback, out bool result, bool specialData = false)
        {
            if (texture == Storage || !(_hasMipViews || _hasLayerViews))
            {
                result = callback(0, _handles.Length, specialData: specialData);

                return;
            }

            EvaluateRelevantHandles(texture.FirstLayer, texture.FirstLevel, texture.Info.GetSlices(), texture.Info.Levels, callback, out result, specialData);
        }

        /// <summary>
        /// Evaluate the range of tracking handles which a view texture overlaps with,
        /// using the view's position and slice/level counts.
        /// </summary>
        /// <param name="firstLayer">The first layer of the texture</param>
        /// <param name="firstLevel">The first level of the texture</param>
        /// <param name="slices">The slice count of the texture</param>
        /// <param name="levels">The level count of the texture</param>
        /// <param name="callback">
        /// A function to be called with the base index of the range of handles for the given texture, and the number of handles it covers.
        /// This can be called for multiple disjoint ranges, if required.
        /// </param>
        private void EvaluateRelevantHandles(int firstLayer, int firstLevel, int slices, int levels, HandlesCallbackDelegate callback, out bool result, bool specialData = false)
        {
            int targetLayerHandles = _hasLayerViews ? slices : 1;
            int targetLevelHandles = _hasMipViews ? levels : 1;

            result = false;

            if (_isBuffer)
            {
                return;
            }
            else if (_is3D)
            {
                // Future mip levels come after all layers of the last mip level. Each mipmap has less layers (depth) than the last.

                if (!_hasLayerViews)
                {
                    // When there are no layer views, the mips are at a consistent offset.

                    result = callback(firstLevel, targetLevelHandles, specialData: specialData);
                }
                else
                {
                    (int levelIndex, int layerCount) = Get3DLevelRange(firstLevel);

                    if (levels > 1 && slices < _layers)
                    {
                        // The given texture only covers some of the depth of multiple mips. (a "depth slice")
                        // Callback with each mip's range separately.
                        // Can assume that the group is fully subdivided (both slices and levels > 1 for storage)

                        while (levels-- > 1)
                        {
                            result = callback(firstLayer + levelIndex, slices, specialData: specialData);

                            levelIndex += layerCount;
                            layerCount = Math.Max(layerCount >> 1, 1);
                            slices = Math.Max(layerCount >> 1, 1);
                        }
                    }
                    else
                    {
                        int totalSize = Math.Min(layerCount, slices);

                        while (levels-- > 1)
                        {
                            layerCount = Math.Max(layerCount >> 1, 1);
                            totalSize += layerCount;
                        }

                        result = callback(firstLayer + levelIndex, totalSize, specialData: specialData);
                    }
                }
            }
            else
            {
                // Future layers come after all mipmaps of the last.
                int levelHandles = _hasMipViews ? _levels : 1;

                if (slices > 1 && levels < _levels)
                {
                    // The given texture only covers some of the mipmaps of multiple slices. (a "mip slice")
                    // Callback with each layer's range separately.
                    // Can assume that the group is fully subdivided (both slices and levels > 1 for storage)

                    for (int i = 0; i < slices; i++)
                    {
                        result = callback(firstLevel + (firstLayer + i) * levelHandles, targetLevelHandles, true, specialData: specialData);
                    }
                }
                else
                {
                    result = callback(firstLevel + firstLayer * levelHandles, targetLevelHandles + (targetLayerHandles - 1) * levelHandles, specialData: specialData);
                }
            }
        }

        /// <summary>
        /// Get the range of offsets for a given mip level of a 3D texture.
        /// </summary>
        /// <param name="level">The level to return</param>
        /// <returns>Start index and count of offsets for the given level</returns>
        private (int Index, int Count) Get3DLevelRange(int level)
        {
            int index = 0;
            int count = _layers; // Depth. Halves with each mip level.

            while (level-- > 0)
            {
                index += count;
                count = Math.Max(count >> 1, 1);
            }

            return (index, count);
        }

        /// <summary>
        /// Get view information for a single tracking handle.
        /// </summary>
        /// <param name="handleIndex">The index of the handle</param>
        /// <returns>The layers and levels that the handle covers, and its index in the offsets array</returns>
        private (int BaseLayer, int BaseLevel, int Levels, int Layers, int Index) GetHandleInformation(int handleIndex)
        {
            int baseLayer;
            int baseLevel;
            int levels = _hasMipViews ? 1 : _levels;
            int layers = _hasLayerViews ? 1 : _layers;
            int index;

            if (_is3D)
            {
                if (_hasLayerViews)
                {
                    // NOTE: Will also have mip views, or only one level in storage.

                    index = handleIndex;
                    baseLevel = 0;

                    int levelLayers = _layers;

                    while (handleIndex >= levelLayers)
                    {
                        handleIndex -= levelLayers;
                        baseLevel++;
                        levelLayers = Math.Max(levelLayers >> 1, 1);
                    }

                    baseLayer = handleIndex;
                }
                else
                {
                    baseLayer = 0;
                    baseLevel = handleIndex;

                    (index, _) = Get3DLevelRange(baseLevel);
                }
            }
            else
            {
                baseLevel = _hasMipViews ? handleIndex % _levels : 0;
                baseLayer = _hasMipViews ? handleIndex / _levels : handleIndex;
                index = baseLevel + baseLayer * _levels;
            }

            return (baseLayer, baseLevel, levels, layers, index);
        }

        /// <summary>
        /// Gets the layer and level for a given view.
        /// </summary>
        /// <param name="index">The index of the view</param>
        /// <returns>The layer and level of the specified view</returns>
        private (int BaseLayer, int BaseLevel) GetLayerLevelForView(int index)
        {
            if (_is3D)
            {
                int baseLevel = 0;

                int levelLayers = _layers;

                while (index >= levelLayers)
                {
                    index -= levelLayers;
                    baseLevel++;
                    levelLayers = Math.Max(levelLayers >> 1, 1);
                }

                return (index, baseLevel);
            }
            else
            {
                return (index / _levels, index % _levels);
            }
        }

        /// <summary>
        /// Find the byte offset of a given texture relative to the storage.
        /// </summary>
        /// <param name="texture">The texture to locate</param>
        /// <returns>The offset of the texture in bytes</returns>
        public int FindOffset(Texture texture)
        {
            return _allOffsets[GetOffsetIndex(texture.FirstLayer, texture.FirstLevel)];
        }

        /// <summary>
        /// Find the offset index of a given layer and level.
        /// </summary>
        /// <param name="layer">The view layer</param>
        /// <param name="level">The view level</param>
        /// <returns>The offset index of the given layer and level</returns>
        public int GetOffsetIndex(int layer, int level)
        {
            if (_is3D)
            {
                return layer + Get3DLevelRange(level).Index;
            }
            else
            {
                return level + layer * _levels;
            }
        }

        /// <summary>
        /// Generate a CpuRegionHandle for a given address and size range in CPU VA.
        /// </summary>
        /// <param name="address">The start address of the tracked region</param>
        /// <param name="size">The size of the tracked region</param>
        /// <returns>A CpuRegionHandle covering the given range</returns>
        private RegionHandle GenerateHandle(ulong address, ulong size)
        {
            RegionHandle handle = _physicalMemory.BeginTracking(address, size, ResourceKind.Texture);

            // S2A（帧率能耗线 10-23，缺省关 S2A_TEX_PRECISE_SKIP=1）：精确访问没碰本句柄的真实字节就不回写、不标脏（见 RegionHandle.S2AOutsideReal）。
            // 塞尔达 GPU 线程上每秒约 200 次整张回写，来自写跟踪排空的精确写落在同子页里贴图旁边的数据上
            if (S2ATexPreciseSkip.On)
            {
                handle.RegisterPreciseAction((a, s, w) => S2ATexPreciseSkip.Check(handle, a, s));
            }

            return handle;
        }

        /// <summary>
        /// Generate a TextureGroupHandle covering a specified range of views.
        /// </summary>
        /// <param name="viewStart">The start view of the handle</param>
        /// <param name="views">The number of views to cover</param>
        /// <returns>A TextureGroupHandle covering the given views</returns>
        private TextureGroupHandle GenerateHandles(int viewStart, int views)
        {
            int viewEnd = viewStart + views - 1;
            (_, int lastLevel) = GetLayerLevelForView(viewEnd);

            int offset = _allOffsets[viewStart];
            int endOffset = _allOffsets[viewEnd] + _sliceSizes[lastLevel];
            int size = endOffset - offset;

            List<RegionHandle> result = [];

            for (int i = 0; i < TextureRange.Count; i++)
            {
                MemoryRange item = TextureRange.GetSubRange(i);
                int subRangeSize = (int)item.Size;

                int sliceStart = Math.Clamp(offset, 0, subRangeSize);
                int sliceEnd = Math.Clamp(endOffset, 0, subRangeSize);

                if (sliceStart != sliceEnd && item.Address != MemoryManager.PteUnmapped)
                {
                    result.Add(GenerateHandle(item.Address + (ulong)sliceStart, (ulong)(sliceEnd - sliceStart)));
                }

                offset -= subRangeSize;
                endOffset -= subRangeSize;

                if (endOffset <= 0)
                {
                    break;
                }
            }

            (int firstLayer, int firstLevel) = GetLayerLevelForView(viewStart);

            if (_hasLayerViews && _hasMipViews)
            {
                size = _sliceSizes[firstLevel];
            }

            offset = _allOffsets[viewStart];
            ulong maxSize = Storage.Size - (ulong)offset;

            TextureGroupHandle groupHandle = new(
                this,
                offset,
                Math.Min(maxSize, (ulong)size),
                _views,
                firstLayer,
                firstLevel,
                viewStart,
                views,
                result.ToArray());

            return groupHandle;
        }

        /// <summary>
        /// Update the views in this texture group, rebuilding the memory tracking if required.
        /// </summary>
        /// <param name="views">The views list of the storage texture</param>
        /// <param name="texture">The texture that has been added, if that is the only change, otherwise null</param>
        public void UpdateViews(List<Texture> views, Texture texture)
        {
            // This is saved to calculate overlapping views for each handle.
            _views = views.ToArray();

            bool layerViews = _hasLayerViews;
            bool mipViews = _hasMipViews;
            bool regionsRebuilt = false;

            if (!(layerViews && mipViews))
            {
                foreach (Texture view in views)
                {
                    if (view.Info.GetSlices() < _layers)
                    {
                        layerViews = true;
                    }

                    if (view.Info.Levels < _levels)
                    {
                        mipViews = true;
                    }
                }

                (layerViews, mipViews) = PropagateGranularity(layerViews, mipViews);

                if (layerViews != _hasLayerViews || mipViews != _hasMipViews)
                {
                    _hasLayerViews = layerViews;
                    _hasMipViews = mipViews;

                    RecalculateHandleRegions();
                    regionsRebuilt = true;
                }
            }

            if (!regionsRebuilt)
            {
                if (texture != null)
                {
                    int offset = FindOffset(texture);

                    foreach (TextureGroupHandle handle in _handles)
                    {
                        handle.AddOverlap(offset, texture);
                    }
                }
                else
                {
                    // Must update the overlapping views on all handles, but only if they were not just recreated.

                    foreach (TextureGroupHandle handle in _handles)
                    {
                        handle.RecalculateOverlaps(this, views);
                    }
                }
            }

            SignalAllDirty();
        }

        /// <summary>
        /// Removes a view from the group, removing it from all overlap lists.
        /// </summary>
        /// <param name="views">The views list of the storage texture</param>
        /// <param name="view">View to remove from the group</param>
        public void RemoveView(List<Texture> views, Texture view)
        {
            // This is saved to calculate overlapping views for each handle.
            _views = views.ToArray();

            int offset = FindOffset(view);

            foreach (TextureGroupHandle handle in _handles)
            {
                handle.RemoveOverlap(offset, view);
            }
        }

        /// <summary>
        /// Inherit handle state from an old set of handles, such as modified and dirty flags.
        /// </summary>
        /// <param name="oldHandles">The set of handles to inherit state from</param>
        /// <param name="handles">The set of handles inheriting the state</param>
        /// <param name="relativeOffset">The offset of the old handles in relation to the new ones</param>
        private void InheritHandles(TextureGroupHandle[] oldHandles, TextureGroupHandle[] handles, int relativeOffset)
        {
            foreach (TextureGroupHandle group in handles)
            {
                foreach (RegionHandle handle in group.Handles)
                {
                    bool dirty = false;

                    foreach (TextureGroupHandle oldGroup in oldHandles)
                    {
                        if (group.OverlapsWith(oldGroup.Offset + relativeOffset, oldGroup.Size))
                        {
                            foreach (RegionHandle oldHandle in oldGroup.Handles)
                            {
                                if (handle.OverlapsWith(oldHandle.Address, oldHandle.Size))
                                {
                                    dirty |= oldHandle.Dirty;
                                }
                            }

                            group.Inherit(oldGroup, group.Offset == oldGroup.Offset + relativeOffset);
                        }
                    }

                    if (dirty && !handle.Dirty)
                    {
                        handle.Reprotect(true);
                    }

                    if (group.Modified)
                    {
                        handle.RegisterAction((address, size) => FlushAction(group, address, size));
                    }
                }
            }

            foreach (TextureGroupHandle oldGroup in oldHandles)
            {
                oldGroup.Modified = false;
            }
        }

        /// <summary>
        /// Inherit state from another texture group.
        /// </summary>
        /// <param name="other">The texture group to inherit from</param>
        public void Inherit(TextureGroup other)
        {
            bool layerViews = _hasLayerViews || other._hasLayerViews;
            bool mipViews = _hasMipViews || other._hasMipViews;

            if (layerViews != _hasLayerViews || mipViews != _hasMipViews)
            {
                _hasLayerViews = layerViews;
                _hasMipViews = mipViews;

                RecalculateHandleRegions();
            }

            foreach (TextureIncompatibleOverlap incompatible in other._incompatibleOverlaps)
            {
                RegisterIncompatibleOverlap(incompatible, false);

                incompatible.Group._incompatibleOverlaps.RemoveAll(overlap => overlap.Group == other);
            }

            int relativeOffset = Storage.Range.FindOffset(other.Storage.Range);

            InheritHandles(other._handles, _handles, relativeOffset);
        }

        /// <summary>
        /// Replace the current handles with the new handles. It is assumed that the new handles start dirty.
        /// The dirty flags from the previous handles will be kept.
        /// </summary>
        /// <param name="handles">The handles to replace the current handles with</param>
        /// <param name="rangeChanged">True if the storage memory range changed since the last region handle generation</param>
        private void ReplaceHandles(TextureGroupHandle[] handles, bool rangeChanged)
        {
            if (_handles != null)
            {
                // When replacing handles, they should start as non-dirty.

                foreach (TextureGroupHandle groupHandle in handles)
                {
                    if (rangeChanged)
                    {
                        // When the storage range changes, this becomes a little different.
                        // If a range does not match one in the original, treat it as modified.
                        // It has been newly mapped and its data must be synchronized.

                        if (groupHandle.Handles.Length == 0)
                        {
                            continue;
                        }

                        foreach (TextureGroupHandle oldGroup in _handles)
                        {
                            if (!groupHandle.OverlapsWith(oldGroup.Offset, oldGroup.Size))
                            {
                                continue;
                            }

                            foreach (RegionHandle handle in groupHandle.Handles)
                            {
                                bool hasMatch = false;

                                foreach (RegionHandle oldHandle in oldGroup.Handles)
                                {
                                    if (oldHandle.RangeEquals(handle))
                                    {
                                        hasMatch = true;
                                        break;
                                    }
                                }

                                if (hasMatch)
                                {
                                    handle.Reprotect();
                                }
                            }
                        }
                    }
                    else
                    {
                        foreach (RegionHandle handle in groupHandle.Handles)
                        {
                            handle.Reprotect();
                        }
                    }
                }

                InheritHandles(_handles, handles, 0);

                foreach (TextureGroupHandle oldGroup in _handles)
                {
                    foreach (RegionHandle oldHandle in oldGroup.Handles)
                    {
                        oldHandle.Dispose();
                    }
                }
            }

            _handles = handles;
            _loadNeeded = new bool[_handles.Length];
        }

        /// <summary>
        /// Recalculate handle regions for this texture group, and inherit existing state into the new handles.
        /// </summary>
        /// <param name="rangeChanged">True if the storage memory range changed since the last region handle generation</param>
        private void RecalculateHandleRegions(bool rangeChanged = false)
        {
            TextureGroupHandle[] handles;

            if (_isBuffer)
            {
                handles = [];
            }
            else if (!(_hasMipViews || _hasLayerViews))
            {
                // Single dirty region.
                RegionHandle[] cpuRegionHandles = new RegionHandle[TextureRange.Count];
                int count = 0;

                for (int i = 0; i < TextureRange.Count; i++)
                {
                    MemoryRange currentRange = TextureRange.GetSubRange(i);
                    if (currentRange.Address != MemoryManager.PteUnmapped)
                    {
                        cpuRegionHandles[count++] = GenerateHandle(currentRange.Address, currentRange.Size);
                    }
                }

                if (count != TextureRange.Count)
                {
                    Array.Resize(ref cpuRegionHandles, count);
                }

                TextureGroupHandle groupHandle = new(this, 0, Storage.Size, _views, 0, 0, 0, _allOffsets.Length, cpuRegionHandles);

                handles = [groupHandle];
            }
            else
            {
                // Get views for the host texture.
                // It's worth noting that either the texture has layer views or mip views when getting to this point, which simplifies the logic a little.
                // Depending on if the texture is 3d, either the mip views imply that layer views are present (2d) or the other way around (3d).
                // This is enforced by the way the texture matched as a view, so we don't need to check.

                int layerHandles = _hasLayerViews ? _layers : 1;
                int levelHandles = _hasMipViews ? _levels : 1;

                int handleIndex = 0;

                if (_is3D)
                {
                    List<TextureGroupHandle> handlesList = [];

                    for (int i = 0; i < levelHandles; i++)
                    {
                        for (int j = 0; j < layerHandles; j++)
                        {
                            (int viewStart, int views) = Get3DLevelRange(i);
                            viewStart += j;
                            views = _hasLayerViews ? 1 : views; // A layer view is also a mip view.

                            handlesList.Add(GenerateHandles(viewStart, views));
                        }

                        layerHandles = Math.Max(1, layerHandles >> 1);
                    }

                    handles = handlesList.ToArray();
                }
                else
                {
                    handles = new TextureGroupHandle[layerHandles * levelHandles];

                    for (int i = 0; i < layerHandles; i++)
                    {
                        for (int j = 0; j < levelHandles; j++)
                        {
                            int viewStart = j + i * _levels;
                            int views = _hasMipViews ? 1 : _levels; // A mip view is also a layer view.

                            handles[handleIndex++] = GenerateHandles(viewStart, views);
                        }
                    }
                }
            }

            ReplaceHandles(handles, rangeChanged);
        }

        /// <summary>
        /// Regenerates handles when the storage range has been remapped.
        /// This forces the regions to be fully subdivided.
        /// </summary>
        public void RangeChanged()
        {
            _hasLayerViews = true;
            _hasMipViews = true;

            RecalculateHandleRegions(true);

            SignalAllDirty();
        }

        /// <summary>
        /// Ensure that there is a handle for each potential texture view. Required for copy dependencies to work.
        /// </summary>
        private void EnsureFullSubdivision()
        {
            if (!(_hasLayerViews && _hasMipViews))
            {
                _hasLayerViews = true;
                _hasMipViews = true;

                RecalculateHandleRegions();
            }
        }

        /// <summary>
        /// Create a copy dependency between this texture group, and a texture at a given layer/level offset.
        /// </summary>
        /// <param name="other">The view compatible texture to create a dependency to</param>
        /// <param name="firstLayer">The base layer of the given texture relative to the storage</param>
        /// <param name="firstLevel">The base level of the given texture relative to the storage</param>
        /// <param name="copyTo">True if this texture is first copied to the given one, false for the opposite direction</param>
        public void CreateCopyDependency(Texture other, int firstLayer, int firstLevel, bool copyTo)
        {
            TextureGroup otherGroup = other.Group;

            EnsureFullSubdivision();
            otherGroup.EnsureFullSubdivision();

            // Get the location of each texture within its storage, so we can find the handles to apply the dependency to.
            // This can consist of multiple disjoint regions, for example if this is a mip slice of an array texture.

            List<(int BaseHandle, int RegionCount)> targetRange = [];
            List<(int BaseHandle, int RegionCount)> otherRange = [];

            EvaluateRelevantHandles(firstLayer, firstLevel, other.Info.GetSlices(), other.Info.Levels, (baseHandle, regionCount, split, specialData) =>
            {
                targetRange.Add((baseHandle, regionCount));
                return true;
            }, out _);
            otherGroup.EvaluateRelevantHandles(other, (baseHandle, regionCount, split, specialData) =>
            {
                otherRange.Add((baseHandle, regionCount));
                return true;
            }, out _);

            int targetIndex = 0;
            int otherIndex = 0;
            (int Handle, int RegionCount) targetRegion = (0, 0);
            (int Handle, int RegionCount) otherRegion = (0, 0);

            while (true)
            {
                if (targetRegion.RegionCount == 0)
                {
                    if (targetIndex >= targetRange.Count)
                    {
                        break;
                    }

                    targetRegion = targetRange[targetIndex++];
                }

                if (otherRegion.RegionCount == 0)
                {
                    if (otherIndex >= otherRange.Count)
                    {
                        break;
                    }

                    otherRegion = otherRange[otherIndex++];
                }

                TextureGroupHandle handle = _handles[targetRegion.Handle++];
                TextureGroupHandle otherHandle = other.Group._handles[otherRegion.Handle++];

                targetRegion.RegionCount--;
                otherRegion.RegionCount--;

                handle.CreateCopyDependency(otherHandle, copyTo);

                // If "copyTo" is true, this texture must copy to the other.
                // Otherwise, it must copy to this texture.

                if (copyTo)
                {
                    otherHandle.Copy(_context, handle);
                }
                else
                {
                    handle.Copy(_context, otherHandle);
                }
            }
        }

        /// <summary>
        /// Creates a copy dependency to another texture group, where handles overlap.
        /// Scans through all handles to find compatible patches in the other group.
        /// </summary>
        /// <param name="other">The texture group that overlaps this one</param>
        /// <param name="copyTo">True if this texture is first copied to the given one, false for the opposite direction</param>
        public void CreateCopyDependency(TextureGroup other, bool copyTo)
        {
            for (int i = 0; i < _allOffsets.Length; i++)
            {
                (_, int level) = GetLayerLevelForView(i);
                MultiRange handleRange = Storage.Range.Slice((ulong)_allOffsets[i], 1);
                ulong handleBase = handleRange.GetSubRange(0).Address;

                for (int j = 0; j < other._handles.Length; j++)
                {
                    (_, int otherLevel) = other.GetLayerLevelForView(j);
                    MultiRange otherHandleRange = other.Storage.Range.Slice((ulong)other._allOffsets[j], 1);
                    ulong otherHandleBase = otherHandleRange.GetSubRange(0).Address;

                    if (handleBase == otherHandleBase)
                    {
                        // Check if the two sizes are compatible.
                        TextureInfo info = Storage.Info;
                        TextureInfo otherInfo = other.Storage.Info;

                        if (TextureCompatibility.ViewLayoutCompatible(info, otherInfo, level, otherLevel) &&
                            TextureCompatibility.CopySizeMatches(info, otherInfo, level, otherLevel))
                        {
                            // These textures are copy compatible. Create the dependency.

                            EnsureFullSubdivision();
                            other.EnsureFullSubdivision();

                            TextureGroupHandle handle = _handles[i];
                            TextureGroupHandle otherHandle = other._handles[j];

                            handle.CreateCopyDependency(otherHandle, copyTo);

                            // If "copyTo" is true, this texture must copy to the other.
                            // Otherwise, it must copy to this texture.

                            if (copyTo)
                            {
                                otherHandle.Copy(_context, handle);
                            }
                            else
                            {
                                handle.Copy(_context, otherHandle);
                            }
                        }
                    }
                }
            }
        }

        /// <summary>
        /// Registers another texture group as an incompatible overlap, if not already registered.
        /// </summary>
        /// <param name="other">The texture group to add to the incompatible overlaps list</param>
        /// <param name="copy">True if the overlap should register copy dependencies</param>
        public void RegisterIncompatibleOverlap(TextureIncompatibleOverlap other, bool copy)
        {
            if (!_incompatibleOverlaps.Any(overlap => overlap.Group == other.Group))
            {
                if (copy && other.Compatibility == TextureViewCompatibility.LayoutIncompatible)
                {
                    // Any of the group's views may share compatibility, even if the parents do not fully.
                    CreateCopyDependency(other.Group, false);
                }

                _incompatibleOverlaps.Add(other);
                other.Group._incompatibleOverlaps.Add(new TextureIncompatibleOverlap(this, other.Compatibility));
            }

            other.Group.SignalIncompatibleOverlapModified();
            SignalIncompatibleOverlapModified();
        }

        /// <summary>
        /// Clear modified flags in the given range.
        /// This will stop any GPU written data from flushing or copying to dependent textures.
        /// </summary>
        /// <param name="range">The range to clear modified flags in</param>
        /// <param name="ignore">Ignore handles that have a copy dependency to the specified group</param>
        public void ClearModified(MultiRange range, TextureGroup ignore = null)
        {
            TextureGroupHandle[] handles = _handles;

            foreach (TextureGroupHandle handle in handles)
            {
                // Handles list is not modified by another thread, only replaced, so this is thread safe.
                // Remove modified flags from all overlapping handles, so that the textures don't flush to unmapped/remapped GPU memory.

                // S2A：不分配的切片判重叠（多段时 Slice 每次新建 List + 数组；渲染目标每次绑定 / 解绑都走这里）
                if (Storage.Range.SliceOverlapsWith((ulong)handle.Offset, (ulong)handle.Size, range))
                {
                    if ((ignore == null || !handle.HasDependencyTo(ignore)) && handle.Modified)
                    {
                        handle.Modified = false;
                        handle.DeferredCopy = null;
                        Storage.SignalModifiedDirty();

                        lock (handle.Overlaps)
                        {
                            foreach (Texture texture in handle.Overlaps)
                            {
                                texture.SignalModifiedDirty();
                            }
                        }
                    }
                }
            }

            Storage.SignalModifiedDirty();

            Texture[] views = _views;

            if (views != null)
            {
                foreach (Texture texture in views)
                {
                    texture.SignalModifiedDirty();
                }
            }
        }

        /// <summary>
        /// A flush has been requested on a tracked region. Flush texture data for the given handle.
        /// </summary>
        /// <param name="handle">The handle this flush action is for</param>
        /// <param name="address">The address of the flushing memory access</param>
        /// <param name="size">The size of the flushing memory access</param>
        public void FlushAction(TextureGroupHandle handle, ulong address, ulong size)
        {
            S2AReadTag.Current = "跟踪触发回写";   // S2A 诊断：读回来源（CPU 碰到 GPU 改过的贴图内存）

            try
            {
                S2AFlushActionImpl(handle, address, size);
            }
            finally
            {
                S2AReadTag.Current = null;
            }
        }

        private void S2AFlushActionImpl(TextureGroupHandle handle, ulong address, ulong size)
        {
            // There is a small gap here where the action is removed but _actionRegistered is still 1.
            // In this case it will skip registering the action, but here we are already handling it,
            // so there shouldn't be any issue as it's the same handler for all actions.

            handle.ClearActionRegistered();

            if (!handle.Modified)
            {
                return;
            }

            bool isGpuThread = _context.IsGpuThread();

            if (S2ATexFlushTrace.On) S2ATexFlushTrace.Note(isGpuThread, Storage.Info, address, size);
            if (S2ATexFlushStat.On) S2ATexFlushStat.NoteOffset(Storage.Info, Storage.Range.GetSubRange(0).Address, address, size, (int)Storage.Size);

            if (isGpuThread)
            {
                // No need to wait if we're on the GPU thread, we can just clear the modified flag immediately.
                handle.Modified = false;
            }

            bool s2aRead = Ryujinx.Memory.Tracking.MemoryTracking.S2AReadTouch;   // 游戏代码读缺页触发（NxTrack.Touch）：可只回写所碰子页

            // S2A（帧率能耗线 10-23）：游戏读、而它还没在 CPU 上等过这批 GPU 结果（要等的宿主同步号 > 游戏已确认的 G）：按 Switch 语义读到的就是内存现值
            // （GPU 写到哪算哪），不阻塞、不回写——放开所碰子页让这次读用现内存，回写动作保留、其余照拦；游戏等到之后（G 前进）或 GPU 再写时整段设回
            if (s2aRead && !isGpuThread && S2AUnsyncNoWait.On && Memory.Buffer.S2AGpuReadFlush && handle.S2ANeededSync > S2AGameSync.G)
            {
                ulong subA = address & ~0xFFFUL, subE = (address + Math.Max(size, 1) + 0xFFF) & ~0xFFFUL;
                RegionHandle.S2AKeepAction = true;
                handle.Modified = true;
                handle.S2AServeUnsynced(subA, subE - subA);
                S2AUnsyncNoWait.Count++;

                return;
            }

            _context.Renderer.BackgroundContextAction(() =>
            {
                long s2aT0 = S2ATexFlushStat.On ? System.Diagnostics.Stopwatch.GetTimestamp() : 0;
                bool s2aUnsynced = S2ATexFlushStat.On && !isGpuThread && handle.S2ANeededSync > S2AGameSync.G;
                bool inBuffer = !isGpuThread && handle.Sync(_context);
                long s2aT1 = S2ATexFlushStat.On ? System.Diagnostics.Stopwatch.GetTimestamp() : 0;

                Storage.SignalModifiedDirty();

                lock (handle.Overlaps)
                {
                    foreach (Texture texture in handle.Overlaps)
                    {
                        texture.SignalModifiedDirty();
                    }
                }

                // S2A 部分回写（帧率能耗线 10-23）：游戏读、数据已在回写缓冲 → 只把所碰子页从缓冲转块线性写回，「GPU 改过」保持、离开跟踪锁后重新登记
                if (s2aRead && inBuffer && S2APartialFlush.On && Memory.Buffer.S2AGpuReadFlush && S2ATryPartialFlush(handle, address, size, out ulong pAddr, out ulong pSize))
                {
                    handle.Modified = true;
                    RegionHandle.S2AKeepAction = true;
                    handle.S2APartialDone(pAddr, pSize);
                    if (S2ATexFlushStat.On) S2ATexFlushStat.Note(Storage.Info, true, false, s2aT1 - s2aT0, System.Diagnostics.Stopwatch.GetTimestamp() - s2aT1, partial: true, unsynced: s2aUnsynced);

                    return;
                }

                if (TextureCompatibility.CanTextureFlush(Storage.Info, _context.Capabilities) && !(inBuffer && _flushBufferImported))
                {
                    FlushSliceRange(false, handle.BaseSlice, handle.BaseSlice + handle.SliceCount, inBuffer, Storage.GetFlushTexture());
                }

                if (S2ATexFlushStat.On) S2ATexFlushStat.Note(Storage.Info, inBuffer, isGpuThread, s2aT1 - s2aT0, System.Diagnostics.Stopwatch.GetTimestamp() - s2aT1, unsynced: s2aUnsynced);
            });
        }

        /// <summary>
        /// Called if any part of the storage texture is unmapped.
        /// </summary>
        public void Unmapped()
        {
            if (_flushBufferImported)
            {
                _flushBufferInvalid = true;
            }
        }

        /// <summary>
        /// Dispose this texture group, disposing all related memory tracking handles.
        /// </summary>
        public void Dispose()
        {
            foreach (TextureGroupHandle group in _handles)
            {
                group.Dispose();
            }

            foreach (TextureIncompatibleOverlap incompatible in _incompatibleOverlaps)
            {
                incompatible.Group._incompatibleOverlaps.RemoveAll(overlap => overlap.Group == this);
            }

            if (_flushBuffer != BufferHandle.Null)
            {
                _context.Renderer.DeleteBuffer(_flushBuffer);
            }
        }
    }

    // S2A 诊断（帧率能耗线 10-22，缺省关）：S2A_TEXFLUSH_TRACE=1 时按「触发线程 + 调用栈」累计贴图回写（FlushAction）次数，每 10 秒打前 3。
    // 八方2 每帧在 GPU 线程上触发一次贴图回写、渲染线程等满一帧 GPU（约 14.5 ms）：查 GPU 线程为什么要读这块 GPU 写过的贴图内存
    internal static class S2ATexFlushTrace
    {
        public static readonly bool On = Environment.GetEnvironmentVariable("S2A_TEXFLUSH_TRACE") == "1";
        private static readonly System.Collections.Generic.Dictionary<string, (long N, string Tex)> _n = new();
        private static long _last;
        public static void Note(bool gpuThread, TextureInfo info, ulong address, ulong size)
        {
            string st = new System.Diagnostics.StackTrace(2, false).ToString();
            string[] lines = st.Split('\n');
            string key = (gpuThread ? "GPU 线程" : "其它线程 " + System.Threading.Thread.CurrentThread.Name) + " | " + string.Join(" ← ", System.Linq.Enumerable.Take(System.Linq.Enumerable.Select(lines, l => l.Trim()), 10));
            string tex = $"{info.Width}x{info.Height} {info.FormatInfo.Format} 地址 {address:x}+{size:x}";
            lock (_n)
            {
                _n[key] = _n.TryGetValue(key, out var v) ? (v.N + 1, tex) : (1, tex);
                long now = System.Diagnostics.Stopwatch.GetTimestamp();
                if (now - _last < System.Diagnostics.Stopwatch.Frequency * 10) return;
                _last = now;
                foreach (var kv in System.Linq.Enumerable.Take(System.Linq.Enumerable.OrderByDescending(_n, kv => kv.Value.N), 3))
                    Console.Error.WriteLine($"[texflush] ×{kv.Value.N} 最近贴图 {kv.Value.Tex}｜{kv.Key}");
            }
        }
    }

    // S2A 诊断（帧率能耗线 10-23，缺省关）：S2A_TEXFLUSH_STAT=1 时贴图回写按（格式 尺寸｜从回写缓冲拷 / 临时向 GPU 读回｜GPU 线程 / 其他线程）分账：次数、等同步耗时、拷贝耗时；
    // 另计提前拷进回写缓冲（FlushIntoBuffer）次数。每 10 秒全打（不截断）。用来定「预先回写」做哪种
    internal static class S2ATexFlushStat
    {
        public static readonly bool On = System.Environment.GetEnvironmentVariable("S2A_TEXFLUSH_STAT") == "1";
        public static long Prefill;
        private static readonly System.Collections.Generic.Dictionary<string, (long N, long Wait, long Copy)> _acc = new();
        private static long _next;

        // 触发回写的访问在贴图里的偏移（按 4 KB 子页）：每张贴图（格式 尺寸 地址）统计前 16 个子页 × 次数，看游戏碰的是整张还是几片
        private static readonly System.Collections.Generic.Dictionary<string, System.Collections.Generic.Dictionary<long, long>> _off = new();
        public static void NoteOffset(TextureInfo info, ulong baseAddr, ulong address, ulong size, int texSize)
        {
            string key = $"{info.FormatInfo.Format} {info.Width}x{info.Height} 块高 {info.GobBlocksInY} 基址 {baseAddr:x} 大小 {texSize:x}";
            long sub = ((long)address - (long)baseAddr) >> 12;
            lock (_acc)
            {
                if (!_off.TryGetValue(key, out var d)) _off[key] = d = new();
                d.TryGetValue(sub, out long n); d[sub] = n + 1;
            }
        }

        public static long UnsyncN, UnsyncWait, SyncN, SyncWait;

        public static void Note(TextureInfo info, bool inBuffer, bool gpuThread, long wait, long copy, bool partial = false, bool unsynced = false)
        {
            if (!gpuThread) { if (unsynced) { UnsyncN++; UnsyncWait += wait; } else { SyncN++; SyncWait += wait; } }
            string key = $"{info.FormatInfo.Format} {info.Width}x{info.Height}｜{(partial ? "部分回写" : inBuffer ? "从回写缓冲拷" : "临时读回")}｜{(gpuThread ? "GPU 线程" : unsynced ? "其他线程·游戏未同步" : "其他线程·游戏已同步")}";
            lock (_acc)
            {
                _acc.TryGetValue(key, out var v);
                _acc[key] = (v.N + 1, v.Wait + wait, v.Copy + copy);
                long now = System.Diagnostics.Stopwatch.GetTimestamp();
                if (now < _next) return;
                _next = now + System.Diagnostics.Stopwatch.Frequency * 10;
                double f = 1000.0 / System.Diagnostics.Stopwatch.Frequency;
                long n = 0, w = 0, c = 0; foreach (var x in _acc.Values) { n += x.N; w += x.Wait; c += x.Copy; }
                System.Console.Error.WriteLine($"[贴图回写账] 精确访问不碰贴图字节、跳过 {System.Threading.Interlocked.Read(ref S2ATexPreciseSkip.Skipped)} 次（S2A_TEX_PRECISE_SKIP={(S2ATexPreciseSkip.On ? 1 : 0)}）");
                System.Console.Error.WriteLine($"[贴图回写账] 累计 {n} 次：等同步 {w * f:F0} ms、拷贝 {c * f:F0} ms；提前拷进回写缓冲 {System.Threading.Interlocked.Read(ref Prefill)} 次；部分回写 {S2APartialFlush.Count} 次；游戏未同步 {UnsyncN} 次 等 {UnsyncWait * f:F0} ms / 已同步 {SyncN} 次 等 {SyncWait * f:F0} ms；未同步放行不回写 贴图 {S2AUnsyncNoWait.Count} / 缓冲 {S2AUnsyncNoWait.BufCount} 次");
                foreach (var kv in System.Linq.Enumerable.OrderByDescending(_acc, kv => kv.Value.Wait + kv.Value.Copy))
                    System.Console.Error.WriteLine($"[贴图回写账]   {kv.Key}：{kv.Value.N} 次 等 {kv.Value.Wait * f:F1} ms 拷 {kv.Value.Copy * f:F1} ms");
                foreach (var kv in _off)
                {
                    long tot = 0; foreach (var x in kv.Value.Values) tot += x;
                    if (tot < 50) continue;
                    var sb = new System.Text.StringBuilder();
                    foreach (var x in System.Linq.Enumerable.Take(System.Linq.Enumerable.OrderByDescending(kv.Value, x => x.Value), 16)) sb.Append($" 子页 {x.Key}×{x.Value}");
                    System.Console.Error.WriteLine($"[贴图回写触发] {kv.Key}：共 {tot} 次、不同子页 {kv.Value.Count} 个；{sb}");
                }
            }
        }
    }

    // S2A 部分回写的开关（S2A_PARTIAL_FLUSH=0 关，A/B 用）
    internal static class S2ATexPreciseSkip
    {
        public static readonly bool On = System.Environment.GetEnvironmentVariable("S2A_TEX_PRECISE_SKIP") == "1";
        public static long Skipped;

        public static bool Check(RegionHandle handle, ulong address, ulong size)
        {
            if (!RegionHandle.S2AOutsideReal(handle, address, size))
            {
                return false;
            }

            System.Threading.Interlocked.Increment(ref Skipped);

            return true;
        }
    }

    internal static class S2APartialFlush
    {
        public static readonly bool On = System.Environment.GetEnvironmentVariable("S2A_PARTIAL_FLUSH") != "0";
        public static long Count;
    }

    // S2A 游戏没等过就读不阻塞（S2A_UNSYNC_NOWAIT=0 关；整体随 Buffer.S2AGpuReadFlush，缺省关）
    internal static class S2AUnsyncNoWait
    {
        public static readonly bool On = System.Environment.GetEnvironmentVariable("S2A_UNSYNC_NOWAIT") != "0";
        public static long Count, BufCount;
    }
}
