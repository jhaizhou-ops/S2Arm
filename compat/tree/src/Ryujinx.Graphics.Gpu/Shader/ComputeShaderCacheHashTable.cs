using Ryujinx.Graphics.Gpu.Shader.HashTable;
using System.Collections.Generic;

namespace Ryujinx.Graphics.Gpu.Shader
{
    /// <summary>
    /// Compute shader cache hash table.
    /// </summary>
    class ComputeShaderCacheHashTable
    {
        private readonly PartitionedHashTable<ShaderSpecializationList> _cache;
        private readonly List<CachedShaderProgram> _shaderPrograms;

        // S2Arm: groups holding programs indexed at boot (their materialized programs are enumerated by GetPrograms)
        private readonly List<ShaderSpecializationList> _lazyLists = [];

        /// <summary>
        /// Creates a new compute shader cache hash table.
        /// </summary>
        public ComputeShaderCacheHashTable()
        {
            _cache = new PartitionedHashTable<ShaderSpecializationList>();
            _shaderPrograms = [];
        }

        /// <summary>
        /// Adds a program to the cache.
        /// </summary>
        /// <param name="program">Program to be added</param>
        public void Add(CachedShaderProgram program)
        {
            ShaderSpecializationList specList = _cache.GetOrAdd(program.Shaders[0].Code, []);
            specList.Add(program);
            _shaderPrograms.Add(program);
        }

        /// <summary>
        /// S2Arm: indexes a cached compute program by its guest code without materializing it (see <see cref="DiskCache.S2ALazyProgram"/>).
        /// </summary>
        public void AddLazy(DiskCache.S2ALazyProgram program)
        {
            ShaderSpecializationList specList = _cache.GetOrAdd(program.GuestShaders[0].Value.Code, []);
            specList.AddLazy(program);
            _lazyLists.Add(specList);
        }

        /// <summary>
        /// Tries to find a cached program.
        /// </summary>
        /// <param name="channel">GPU channel</param>
        /// <param name="poolState">Texture pool state</param>
        /// <param name="computeState">Compute state</param>
        /// <param name="gpuVa">GPU virtual address of the compute shader</param>
        /// <param name="program">Cached host program for the given state, if found</param>
        /// <param name="cachedGuestCode">Cached guest code, if any found</param>
        /// <returns>True if a cached host program was found, false otherwise</returns>
        public bool TryFind(
            GpuChannel channel,
            GpuChannelPoolState poolState,
            GpuChannelComputeState computeState,
            ulong gpuVa,
            out CachedShaderProgram program,
            out byte[] cachedGuestCode)
        {
            program = null;
            ShaderCodeAccessor codeAccessor = new(channel.MemoryManager, gpuVa);
            bool hasSpecList = _cache.TryFindItem(codeAccessor, out ShaderSpecializationList specList, out cachedGuestCode);

            // S2A（10-21）：不中分类（首遇重翻诊断，见 ShaderCache.S2ALogMiss）
            if (!hasSpecList) { ShaderSpecializationState.S2AMiss = "缺客体代码（计算）"; return false; }
            ShaderSpecializationState.S2AMissWhy = null;
            bool hit = specList.TryFindForCompute(channel, poolState, computeState, out program);
            if (!hit) ShaderSpecializationState.S2AMiss = "特化不符（" + (ShaderSpecializationState.S2AMissWhy ?? "未记字段") + "）";
            return hit;
        }

        /// <summary>S2A：加载屏预热遍历带 lazy 程序的计算分组。</summary>
        internal IEnumerable<ShaderSpecializationList> S2ALazyGroups => _lazyLists;

        /// <summary>
        /// Gets all programs that have been added to the table.
        /// </summary>
        /// <returns>Programs added to the table</returns>
        public IEnumerable<CachedShaderProgram> GetPrograms()
        {
            foreach (CachedShaderProgram program in _shaderPrograms)
            {
                yield return program;
            }

            // Materialized lazily-indexed programs (unmaterialized ones own no host resources). A group may be listed more than once
            // and may also hold eagerly added programs already yielded above, so only yield programs not seen yet
            HashSet<CachedShaderProgram> seen = [.. _shaderPrograms];

            foreach (ShaderSpecializationList specList in _lazyLists)
            {
                foreach (CachedShaderProgram program in specList)
                {
                    if (seen.Add(program))
                    {
                        yield return program;
                    }
                }
            }
        }
    }
}
