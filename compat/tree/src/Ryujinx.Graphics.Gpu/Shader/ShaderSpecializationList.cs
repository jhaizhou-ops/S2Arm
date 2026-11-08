using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu.Shader.DiskCache;
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;

namespace Ryujinx.Graphics.Gpu.Shader
{
    /// <summary>
    /// List of cached shader programs that differs only by specialization state.
    /// </summary>
    class ShaderSpecializationList : IEnumerable<CachedShaderProgram>, IS2APipelineWarmGroup
    {
        private readonly List<CachedShaderProgram> _entries = [];

        // S2Arm: programs indexed from the disk cache at boot, materialized when a lookup first reaches this group
        private List<S2ALazyProgram> _lazy;

        // S2A（10-27）：实化时宿主二进制不在的条目。它们先只登记，按运行时特化状态核对，只有真的匹配到才算一次作废 / 首遇现编
        private List<S2ALazyProgram> _s2aMissingHost;

        /// <summary>
        /// Adds a program that is materialized on the first lookup of this group.
        /// </summary>
        public void AddLazy(S2ALazyProgram program)
        {
            (_lazy ??= []).Add(program);
        }

        /// <summary>S2A：该组是否含热表里的程序号（加载屏预热用，未实化时才可能命中）。</summary>
        public bool S2AContainsWarm(HashSet<int> warm)
        {
            if (_lazy == null || warm == null || warm.Count == 0)
            {
                return false;
            }

            foreach (S2ALazyProgram lazy in _lazy)
            {
                if (lazy != null && warm.Contains(lazy.ProgramIndex))
                {
                    return true;
                }
            }

            return false;
        }

        /// <summary>S2A：加载屏预热的同步实化入口（与首次查找走同一条 Materialize）。</summary>
        public IEnumerable<IProgram> S2AMaterializeHostPrograms()
        {
            Materialize();

            foreach (CachedShaderProgram program in _entries)
            {
                yield return program.HostProgram;
            }
        }

        private void Materialize()
        {
            if (_lazy == null)
            {
                return;
            }

            foreach (S2ALazyProgram lazy in _lazy)
            {
                if (lazy.Materialize() is CachedShaderProgram program)
                {
                    _entries.Add(program);
                }
                else if (lazy.HostMissing)
                {
                    (_s2aMissingHost ??= []).Add(lazy);
                }
            }

            _lazy = null;
        }

        /// <summary>
        /// S2A（10-27）：本组没有可用条目命中后，按运行时状态核对实化时缺宿主二进制的条目。
        /// 只有「这一支的特化状态真的匹配当前状态」才报一次作废（= 一次首遇现编）；同组里没被选中的特化变体不是作废，不报。
        /// 同包第二局时上一局现编的条目已带宿主二进制并命中，查找根本走不到这里，红行归零。
        /// 保守口径：缺宿主二进制时不知道它是不是顶点转计算 / 读不读绘制参数，按「都是」比（只多比、不少比，不会把不符报成相符）。
        /// </summary>
        private void S2AProbeMissingHostGraphics(GpuChannel channel, ref GpuChannelPoolState poolState, ref GpuChannelGraphicsState graphicsState)
        {
            if (_s2aMissingHost == null)
            {
                return;
            }

            string why = ShaderSpecializationState.S2AMissWhy;

            foreach (S2ALazyProgram lazy in _s2aMissingHost)
            {
                if (lazy.ReportedMissingHost)
                {
                    continue;
                }

                ShaderSpecializationState specState;

                try
                {
                    specState = lazy.Storage.S2AReadSpecState(lazy);
                }
                catch (Exception e) when (e is DiskCacheLoadException or IOException or InvalidDataException)
                {
                    continue;   // 读不了 = 不能证明这一支被需要；缓存坏的行由实化路径负责
                }

                specState.S2APrepareMatchOnly();

                if (specState.MatchesGraphics(channel, ref poolState, ref graphicsState, true,
                    !specState.S2AUsageTracked || specState.S2ACbdpRead, checkTextures: true))
                {
                    S2AReportMissingHost(lazy);
                    break;
                }
            }

            ShaderSpecializationState.S2AMissWhy = why;   // 查找不中的拒因仍按可用条目算，别被核对覆盖
        }

        /// <summary>S2A：同 <see cref="S2AProbeMissingHostGraphics"/>，计算着色器。</summary>
        private void S2AProbeMissingHostCompute(GpuChannel channel, GpuChannelPoolState poolState, GpuChannelComputeState computeState)
        {
            if (_s2aMissingHost == null)
            {
                return;
            }

            string why = ShaderSpecializationState.S2AMissWhy;

            foreach (S2ALazyProgram lazy in _s2aMissingHost)
            {
                if (lazy.ReportedMissingHost)
                {
                    continue;
                }

                ShaderSpecializationState specState;

                try
                {
                    specState = lazy.Storage.S2AReadSpecState(lazy);
                }
                catch (Exception e) when (e is DiskCacheLoadException or IOException or InvalidDataException)
                {
                    continue;
                }

                specState.S2APrepareMatchOnly();

                if (specState.MatchesCompute(channel, ref poolState, computeState, checkTextures: true))
                {
                    S2AReportMissingHost(lazy);
                    break;
                }
            }

            ShaderSpecializationState.S2AMissWhy = why;
        }

        private static void S2AReportMissingHost(S2ALazyProgram lazy)
        {
            lazy.ReportedMissingHost = true;
            S2AShaderCacheGuard.Report(1, $"程序 {lazy.ProgramIndex} 缺主机代码（按需实化）");
        }

        /// <summary>
        /// Adds a program to the list.
        /// </summary>
        /// <param name="program">Program to be added</param>
        public void Add(CachedShaderProgram program)
        {
            _entries.Add(program);
        }

        /// <summary>
        /// Tries to find an existing 3D program on the cache.
        /// </summary>
        /// <param name="channel">GPU channel</param>
        /// <param name="poolState">Texture pool state</param>
        /// <param name="graphicsState">Graphics state</param>
        /// <param name="program">Cached program, if found</param>
        /// <returns>True if a compatible program is found, false otherwise</returns>
        public bool TryFindForGraphics(
            GpuChannel channel,
            ref GpuChannelPoolState poolState,
            ref GpuChannelGraphicsState graphicsState,
            out CachedShaderProgram program)
        {
            Materialize();
            List<string> whys = null;

            foreach (CachedShaderProgram entry in _entries)
            {
                // S2A：首次命中核对出与运行时不符的磁盘缓存条目（ShaderSpecializationState.S2AVerify）不再复用
                if (entry.SpecializationState.S2ARejected)
                {
                    continue;
                }

                bool vertexAsCompute = entry.VertexAsCompute != null;
                bool usesDrawParameters = entry.Shaders[1]?.Info.UsesDrawParameters ?? false;

                if (entry.SpecializationState.MatchesGraphics(
                    channel,
                    ref poolState,
                    ref graphicsState,
                    vertexAsCompute,
                    usesDrawParameters,
                    checkTextures: true))
                {
                    program = entry;
                    return true;
                }
                S2ANoteMiss(ref whys);
            }

            S2AFinishMiss(whys);
            S2AProbeMissingHostGraphics(channel, ref poolState, ref graphicsState);
            program = default;
            return false;
        }

        // S2A（10-24）：首遇重翻拒因记全每个候选的不符字段（原先只剩最后一个候选的）。xc3 冷局「透明测试开关」256 次实为：包里「关」「开」两份都在，
        //   「关」那份比到透明测试不符、盖掉了「开」那份真正不符的字段。拒因写成「候选数：字段一；字段二」，同字段只记一次
        private static void S2ANoteMiss(ref List<string> whys)
        {
            string w = ShaderSpecializationState.S2AMissWhy ?? "未记字段";
            ShaderSpecializationState.S2AMissWhy = null;
            whys ??= new List<string>();
            if (!whys.Contains(w)) whys.Add(w);
        }

        private void S2AFinishMiss(List<string> whys)
        {
            if (whys != null) ShaderSpecializationState.S2AMissWhy = $"候选 {_entries.Count} 份：" + string.Join("；", whys);
        }

        /// <summary>
        /// Tries to find an existing compute program on the cache.
        /// </summary>
        /// <param name="channel">GPU channel</param>
        /// <param name="poolState">Texture pool state</param>
        /// <param name="computeState">Compute state</param>
        /// <param name="program">Cached program, if found</param>
        /// <returns>True if a compatible program is found, false otherwise</returns>
        public bool TryFindForCompute(GpuChannel channel, GpuChannelPoolState poolState, GpuChannelComputeState computeState, out CachedShaderProgram program)
        {
            Materialize();
            List<string> whys = null;

            foreach (CachedShaderProgram entry in _entries)
            {
                if (entry.SpecializationState.S2ARejected)
                {
                    continue;
                }

                if (entry.SpecializationState.MatchesCompute(channel, ref poolState, computeState, true))
                {
                    program = entry;
                    return true;
                }
                S2ANoteMiss(ref whys);
            }

            S2AFinishMiss(whys);
            S2AProbeMissingHostCompute(channel, poolState, computeState);
            program = default;
            return false;
        }

        public IEnumerator<CachedShaderProgram> GetEnumerator()
        {
            return _entries.GetEnumerator();
        }

        IEnumerator IEnumerable.GetEnumerator()
        {
            return GetEnumerator();
        }
    }
}
