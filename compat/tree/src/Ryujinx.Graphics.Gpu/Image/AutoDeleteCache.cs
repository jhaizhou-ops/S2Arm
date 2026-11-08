using Ryujinx.Common.Logging;
using Ryujinx.Graphics.GAL;
using System;
using System.Collections;
using System.Collections.Generic;

namespace Ryujinx.Graphics.Gpu.Image
{
    /// <summary>
    /// An entry on the short duration texture cache.
    /// </summary>
    class ShortTextureCacheEntry
    {
        // S2A：字段可写，条目由 AutoDeleteCache 复用（见 _s2aEntryPool）
        public bool IsAutoDelete;
        public TextureDescriptor Descriptor;
        public int InvalidatedSequence;
        public Texture Texture;

        /// <summary>
        /// Create a new entry on the short duration texture cache.
        /// </summary>
        /// <param name="descriptor">Last descriptor that referenced the texture</param>
        /// <param name="texture">The texture</param>
        public ShortTextureCacheEntry(TextureDescriptor descriptor, Texture texture)
        {
            Descriptor = descriptor;
            InvalidatedSequence = texture.InvalidatedSequence;
            Texture = texture;
        }

        /// <summary>
        /// Create a new entry on the short duration texture cache from the auto delete cache.
        /// </summary>
        /// <param name="texture">The texture</param>
        public ShortTextureCacheEntry(Texture texture)
        {
            IsAutoDelete = true;
            InvalidatedSequence = texture.InvalidatedSequence;
            Texture = texture;
        }

        // S2A：复用时重新填（同两个构造函数）
        public ShortTextureCacheEntry S2AReset(in TextureDescriptor descriptor, Texture texture, bool autoDelete)
        {
            IsAutoDelete = autoDelete;
            Descriptor = autoDelete ? default : descriptor;
            InvalidatedSequence = texture.InvalidatedSequence;
            Texture = texture;
            return this;
        }
    }

    /// <summary>
    /// A texture cache that automatically removes older textures that are not used for some time.
    /// The cache works with a rotated list with a fixed size. When new textures are added, the
    /// old ones at the bottom of the list are deleted.
    /// </summary>
    class AutoDeleteCache : IEnumerable<Texture>
    {
        private const int MinCountForDeletion = 32;
        private const int MaxCapacity = 2048;
        private const ulong GiB = 1024 * 1024 * 1024;
        private ulong MaxTextureSizeCapacity = 2 * GiB;
        private const ulong MinTextureSizeCapacity = 512 * 1024 * 1024;
        private const ulong DefaultTextureSizeCapacity = 1 * GiB;

        private const float MemoryScaleFactor = 0.50f;
        private ulong _maxCacheMemoryUsage = DefaultTextureSizeCapacity;

        private readonly LinkedList<Texture> _textures;
        private ulong _totalSize;

        // S2A（帧率能耗线 10-22）：上游短缓存是两代（builder 收新条目、上一代下次 Tick 删），这里改成 16 代环：
        // 贴图缓冲（TextureBuffer，只是缓冲上的视图、不占自己的存储）留满 16 代，其余照上游留 2 代（放进第 2 个要删的集合）。
        // 八方2 每帧换贴图缓冲描述符、同一描述符隔 3–16 代才回来，两代接不住、每帧新建约 10 张（GPU 模拟线程约 11 KB/帧分配）；
        // Mac 实测 16 代新建 −78%、MARK 后 60 秒 gen0 4 → 1，Metal 已分配不变（op2_alloc r7 / r12）。S2A_SHORT_CACHE_GEN 覆盖代数（A/B 用，2 = 上游）
        // 10-23 原生层线改缺省 64：真机八方2 稳态贴图缓冲全部死于短缓存到期（Mac 诊断 268/268 走 ProcessShortCache），描述符隔 17–64 代回来的仍要新建；
        //   同口径真机局（octopath2_1023015440_1 → _1023071215_2，只差 GEN 16 → 64）：每帧分配 6575 → 3898 B、GC 单帧最长 17.5 → 0 ms、新建贴图 6126 → 2679 张。
        //   命中仍要整个描述符（含地址）相等且失效序号未变，不会读到旧数据；代价是多留住几百个极小的缓冲视图对象。上限放到 256
        private static readonly int _shortCacheGenerations = S2AShortCacheGenerations();
        private readonly HashSet<ShortTextureCacheEntry>[] _shortCacheGens;
        private int _shortCacheBuilder;

        private readonly Dictionary<TextureDescriptor, ShortTextureCacheEntry> _shortCacheLookup;

        // S2A（测试出包线 10-23）：短缓存条目复用。真机八方2 稳态每分钟约 5.5 万次 AddShortCache（每次 new 64 B 条目），条目按代留到 64 代（约 2 秒），
        //   正好活过 gen0、被晋升后在 gen1 / gen2 里变垃圾：gen0 8 MB 存活 5–6 MB、gen1 压缩一次搬 13–17 MB、单次停顿 15–30 ms（八方2 / 马车8）。
        //   条目只在已从全部代集合与查找表移除后回收（ProcessShortCache 到期、RemoveShortCache 命中挂回池）；FindShortCache 的失效分支只移出查找表、
        //   条目还在某代里，不回收，等那代到期再收。全部在 GPU 线程上（同上游短缓存），不加锁
        //   缺省关（S2A_SHORT_POOL=1 开）：按「缺省关合入 → iPhone 同包 A/B 达标 → 翻缺省」（10-23 总指挥）；关时与上游一样每次 new
        // 10-23 真机五款同包 A/B 后翻缺省开：每帧分配降 12–68%，逐次 gen0 / gen1 停顿按晋升量拟合 B 不系统性高于 A（跨代引用没有拉长停顿）；S2A_SHORT_POOL=0 关
        private static readonly bool _s2aPoolOn = System.Environment.GetEnvironmentVariable("S2A_SHORT_POOL") != "0";
        private readonly Stack<ShortTextureCacheEntry> _s2aEntryPool = new();

        private ShortTextureCacheEntry S2ANewEntry(in TextureDescriptor descriptor, Texture texture, bool autoDelete)
        {
            return _s2aPoolOn && _s2aEntryPool.TryPop(out ShortTextureCacheEntry e) ? e.S2AReset(descriptor, texture, autoDelete)
                : autoDelete ? new ShortTextureCacheEntry(texture) : new ShortTextureCacheEntry(descriptor, texture);
        }

        private void S2AFreeEntry(ShortTextureCacheEntry e)
        {
            if (!_s2aPoolOn) return;
            e.Texture = null; // 不攥着贴图
            _s2aEntryPool.Push(e);
        }

        /// <summary>
        /// Initializes the cache, setting the maximum texture capacity for the specified GPU context.
        /// </summary>
        /// <remarks>
        /// If the backend GPU has 0 memory capacity, the cache size defaults to `DefaultTextureSizeCapacity`.
        /// 
        /// Reads the current Device total CPU Memory, to determine the maximum amount of VRAM available. Capped to 50% of Current GPU Memory.
        /// </remarks>
        /// <param name="context">The GPU context that the cache belongs to</param>
        /// <param name="cpuMemorySize">The amount of physical CPU Memory available on the device.</param>
        public void Initialize(GpuContext context, ulong cpuMemorySize)
        {
            ulong cpuMemorySizeGiB = cpuMemorySize / GiB;
            ulong MaximumGpuMemoryGiB = context.Capabilities.MaximumGpuMemory / GiB;
            ulong TextureSizeCapacity = cpuMemorySize - (2 * GiB);

            MaxTextureSizeCapacity =
                context.Capabilities.MaximumGpuMemory == 0 || cpuMemorySizeGiB < 6 && MaximumGpuMemoryGiB < 6
                    ? DefaultTextureSizeCapacity
                    : cpuMemorySizeGiB < 12
                        ? TextureSizeCapacity
                        : cpuMemorySize;

            ulong cacheMemory = (ulong)(context.Capabilities.MaximumGpuMemory * MemoryScaleFactor);

            _maxCacheMemoryUsage = Math.Clamp(cacheMemory, MinTextureSizeCapacity, MaxTextureSizeCapacity);

            Logger.Info?.Print(LogClass.Gpu, $"AutoDelete Cache Allocated VRAM : {_maxCacheMemoryUsage / GiB} GiB");
        }

        /// <summary>
        /// Creates a new instance of the automatic deletion cache.
        /// </summary>
        public AutoDeleteCache()
        {
            _textures = [];

            _shortCacheGens = new HashSet<ShortTextureCacheEntry>[_shortCacheGenerations];

            for (int i = 0; i < _shortCacheGens.Length; i++)
            {
                _shortCacheGens[i] = [];
            }

            _shortCacheLookup = new Dictionary<TextureDescriptor, ShortTextureCacheEntry>();
        }

        /// <summary>
        /// Adds a new texture to the cache, even if the texture added is already on the cache.
        /// </summary>
        /// <remarks>
        /// Using this method is only recommended if you know that the texture is not yet on the cache,
        /// otherwise it would store the same texture more than once.
        /// </remarks>
        /// <param name="texture">The texture to be added to the cache</param>
        public void Add(Texture texture)
        {
            _totalSize += texture.Size;

            texture.IncrementReferenceCount();
            texture.CacheNode = _textures.AddLast(texture);

            if (_textures.Count > MaxCapacity ||
                (_totalSize > _maxCacheMemoryUsage && _textures.Count >= MinCountForDeletion))
            {
                RemoveLeastUsedTexture();
            }
        }

        /// <summary>
        /// Adds a new texture to the cache, or just moves it to the top of the list if the
        /// texture is already on the cache.
        /// </summary>
        /// <remarks>
        /// Moving the texture to the top of the list prevents it from being deleted,
        /// as the textures on the bottom of the list are deleted when new ones are added.
        /// </remarks>
        /// <param name="texture">The texture to be added, or moved to the top</param>
        public void Lift(Texture texture)
        {
            if (texture.CacheNode != null)
            {
                if (texture.CacheNode != _textures.Last)
                {
                    _textures.Remove(texture.CacheNode);
                    _textures.AddLast(texture.CacheNode);
                }

                if (_totalSize > _maxCacheMemoryUsage && _textures.Count >= MinCountForDeletion)
                {
                    RemoveLeastUsedTexture();
                }
            }
            else
            {
                Add(texture);
            }
        }

        /// <summary>
        /// Removes the least used texture from the cache.
        /// </summary>
        private void RemoveLeastUsedTexture()
        {
            Texture oldestTexture = _textures.First.Value;

            _totalSize -= oldestTexture.Size;

            if (!oldestTexture.CheckModified(false))
            {
                // The texture must be flushed if it falls out of the auto delete cache.
                // Flushes out of the auto delete cache do not trigger write tracking,
                // as it is expected that other overlapping textures exist that have more up-to-date contents.

                oldestTexture.Group.SynchronizeDependents(oldestTexture);
                S2AReadTag.Current = "淘汰回写";
                oldestTexture.FlushModified(false);
                S2AReadTag.Current = null;
            }

            _textures.RemoveFirst();

            oldestTexture.DecrementReferenceCount();
            oldestTexture.CacheNode = null;
        }

        /// <summary>
        /// Removes a texture from the cache.
        /// </summary>
        /// <param name="texture">The texture to be removed from the cache</param>
        /// <param name="flush">True to remove the texture if it was on the cache</param>
        /// <returns>True if the texture was found and removed, false otherwise</returns>
        public bool Remove(Texture texture, bool flush)
        {
            if (texture.CacheNode == null)
            {
                return false;
            }

            // Remove our reference to this texture.
            if (flush)
            {
                S2AReadTag.Current = "移出缓存回写";
                texture.FlushModified(false);
                S2AReadTag.Current = null;
            }

            _textures.Remove(texture.CacheNode);

            _totalSize -= texture.Size;

            texture.CacheNode = null;

            return texture.DecrementReferenceCount();
        }

        /// <summary>
        /// Attempt to find a texture on the short duration cache.
        /// </summary>
        /// <param name="descriptor">The texture descriptor</param>
        /// <returns>The texture if found, null otherwise</returns>
        public Texture FindShortCache(in TextureDescriptor descriptor)
        {
            if (_shortCacheLookup.Count > 0 && _shortCacheLookup.TryGetValue(descriptor, out ShortTextureCacheEntry entry))
            {
                if (entry.InvalidatedSequence == entry.Texture.InvalidatedSequence)
                {
                    return entry.Texture;
                }
                else
                {
                    S2ADescReuse.StaleHits++;
                    _shortCacheLookup.Remove(descriptor);
                }
            }

            return null;
        }

        /// <summary>
        /// Removes an entry from the short duration cache generations, dropping the reference it holds.
        /// The caller is responsible for removing the lookup table entry, if any.
        /// </summary>
        /// <param name="entry">Entry to remove</param>
        /// <returns>True if the entry was on a generation set, false otherwise</returns>
        private bool RemoveShortCacheEntry(ShortTextureCacheEntry entry)
        {
            if (entry == null)
            {
                return false;
            }

            bool removed = false;

            foreach (HashSet<ShortTextureCacheEntry> gen in _shortCacheGens)
            {
                removed |= gen.Remove(entry);
            }

            if (!removed)
            {
                return false;
            }

            entry.Texture.DecrementReferenceCount();

            if (entry.Texture.ShortCacheEntry == entry)
            {
                entry.Texture.ShortCacheEntry = null;
            }

            if (!entry.IsAutoDelete)
            {
                S2ARemoveLookup(entry);
            }

            S2AFreeEntry(entry); // 已从全部代集合与查找表移除

            return true;
        }

        /// <summary>
        /// Removes the lookup table entry only if it still points at the given entry.
        /// A stale entry leaving its generation must not evict the newer entry that owns the same descriptor.
        /// </summary>
        /// <param name="entry">Entry that is leaving the cache</param>
        private void S2ARemoveLookup(ShortTextureCacheEntry entry)
        {
            if (_shortCacheLookup.TryGetValue(entry.Descriptor, out ShortTextureCacheEntry current) && current == entry)
            {
                _shortCacheLookup.Remove(entry.Descriptor);
            }
        }

        /// <summary>
        /// Removes a texture from the short duration cache.
        /// </summary>
        /// <param name="texture">Texture to remove from the short cache</param>
        public void RemoveShortCache(Texture texture)
        {
            RemoveShortCacheEntry(texture.ShortCacheEntry);
        }

        /// <summary>
        /// Adds a texture to the short duration cache.
        /// It starts in the builder set, and it is moved into the deletion set on next process.
        /// </summary>
        /// <remarks>
        /// The lookup table is keyed by descriptor, so only one entry per descriptor may exist.
        /// Texture buffer descriptors are reused within the retention window (64 generations by default),
        /// so the same descriptor can be added again while its previous entry is still alive.
        /// If the previous entry belongs to the same texture, it is reused and only its generation is
        /// refreshed — the reference count must not change, otherwise a texture held only by the short
        /// cache (one reference) would be dropped to zero, removed from the texture cache, and then
        /// resurrected by the new entry. If it belongs to another texture, the old entry is removed
        /// (and its reference dropped) before the new one is added, preserving the original
        /// "one entry per descriptor" semantics instead of failing the session.
        /// </remarks>
        /// <param name="texture">Texture to add to the short cache</param>
        /// <param name="descriptor">Last used texture descriptor</param>
        public void AddShortCache(Texture texture, ref TextureDescriptor descriptor)
        {
            if (_shortCacheLookup.TryGetValue(descriptor, out ShortTextureCacheEntry existing))
            {
                if (ReferenceEquals(existing.Texture, texture))
                {
                    // 同一纹理带着同一描述符再入：复用旧条目、刷新代位置与失效序号，引用计数不变。
                    S2AReAddShortCacheEntry(existing, texture);
                    return;
                }

                _shortCacheLookup.Remove(descriptor);
                RemoveShortCacheEntry(existing);
            }

            ShortTextureCacheEntry entry = S2ANewEntry(descriptor, texture, false);

            _shortCacheGens[texture.Target == GAL.Target.TextureBuffer ? _shortCacheBuilder : (_shortCacheBuilder + 2) % _shortCacheGens.Length].Add(entry);
            _shortCacheLookup.Add(entry.Descriptor, entry);

            texture.ShortCacheEntry = entry;

            texture.IncrementReferenceCount();
        }

        /// <summary>
        /// Moves an entry that is already on the short duration cache to the current generation,
        /// refreshing its invalidation sequence. The entry keeps the reference it already holds.
        /// </summary>
        /// <param name="entry">Entry to refresh</param>
        /// <param name="texture">Texture the entry belongs to</param>
        private void S2AReAddShortCacheEntry(ShortTextureCacheEntry entry, Texture texture)
        {
            foreach (HashSet<ShortTextureCacheEntry> gen in _shortCacheGens)
            {
                gen.Remove(entry);
            }

            entry.InvalidatedSequence = texture.InvalidatedSequence;

            _shortCacheGens[texture.Target == GAL.Target.TextureBuffer ? _shortCacheBuilder : (_shortCacheBuilder + 2) % _shortCacheGens.Length].Add(entry);

            texture.ShortCacheEntry = entry;
        }

        /// <summary>
        /// Adds a texture to the short duration cache without a descriptor. This typically keeps it alive for two ticks.
        /// On expiry, it will be removed from the AutoDeleteCache.
        /// </summary>
        /// <param name="texture">Texture to add to the short cache</param>
        public void AddShortCache(Texture texture)
        {
            if (texture.ShortCacheEntry != null)
            {
                ShortTextureCacheEntry entry = S2ANewEntry(default, texture, true);

                _shortCacheGens[(_shortCacheBuilder + 2) % _shortCacheGens.Length].Add(entry);

                texture.ShortCacheEntry = entry;

                texture.IncrementReferenceCount();
            }
        }

        /// <summary>
        /// Delete textures from the short duration cache.
        /// Moves the builder set to be deleted on next process.
        /// </summary>
        public void ProcessShortCache()
        {
            int oldest = (_shortCacheBuilder + 1) % _shortCacheGens.Length;
            HashSet<ShortTextureCacheEntry> toRemove = _shortCacheGens[oldest];

            foreach (ShortTextureCacheEntry entry in toRemove)
            {
                entry.Texture.DecrementReferenceCount();

                if (entry.IsAutoDelete)
                {
                    Remove(entry.Texture, false);
                }
                else
                {
                    S2ARemoveLookup(entry);
                }

                if (entry.Texture.ShortCacheEntry == entry)
                {
                    entry.Texture.ShortCacheEntry = null;
                }
            }

            foreach (ShortTextureCacheEntry entry in toRemove)
            {
                S2AFreeEntry(entry); // 这一代到期：已移出查找表、马上整代清空
            }

            toRemove.Clear();
            _shortCacheBuilder = oldest;
        }

        private static int S2AShortCacheGenerations()
        {
            return int.TryParse(System.Environment.GetEnvironmentVariable("S2A_SHORT_CACHE_GEN"), out int n) && n >= 2 && n <= 256 ? n : 64;
        }

        public IEnumerator<Texture> GetEnumerator()
        {
            return _textures.GetEnumerator();
        }

        IEnumerator IEnumerable.GetEnumerator()
        {
            return _textures.GetEnumerator();
        }
    }
}
