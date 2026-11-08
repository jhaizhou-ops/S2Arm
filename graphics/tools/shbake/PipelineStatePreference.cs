using System;
using System.Collections.Generic;
using System.Linq;

namespace S2A.ShBake
{
    /// <summary>
    /// Offline pack merge rule for recorded ProgramPipelineState.
    ///
    /// A pack can inherit a program from an older cache that has no pipeline state, while a newer
    /// cold-run export records the same guest code with a real state. Keeping both lets the runtime
    /// cache lookup hit the stateless record first; ProgramBinary.Info.State stays null and the
    /// program never enters ShaderCollection.BackgroundCompilation, so the first draw still creates
    /// the pipeline synchronously (Wonder 8E: 214 pipelines / 2104 ms on the first launch).
    ///
    /// The dedup key is the guest code <b>plus the full specialization bytes with PipelineState
    /// removed</b>. Guest code alone (stage code + constant buffer 1) is not enough: a stateless
    /// record can differ from the stateful one in texture format, constants or any other
    /// specialization field, and dropping it would lose a real variant (first-use translation on
    /// the device). Only a stateless record whose stripped specialization is byte-identical to a
    /// stateful record is a shadow and may be dropped. Compute programs have no
    /// ProgramPipelineState by design and are never dropped.
    /// </summary>
    public static class PipelineStatePreference
    {
        /// <param name="Items">合并后的记录（保持原顺序）。</param>
        /// <param name="NoStateSameGuest">同客体代码、同计算/图形类别下存在有状态记录的无状态记录条数。</param>
        /// <param name="DroppedNoState">其中因「去掉 PipelineState 后的特化字节」也完全相同而被删的影子条数。</param>
        public readonly record struct MergeResult<T>(List<T> Items, int NoStateSameGuest, int DroppedNoState);

        /// <summary>
        /// Drop a stateless shadow only when another record for the same guest code has a pipeline
        /// state and its specialization is otherwise byte-identical.
        /// </summary>
        /// <param name="items">参考记录（已按完整特化去重）。</param>
        /// <param name="guestKey">客体键：阶段客体代码 + 常量缓冲 1 数据（不含特化状态）。</param>
        /// <param name="shadowKey">影子键：<paramref name="guestKey"/> + 去掉 PipelineState 后的完整特化字节。</param>
        /// <param name="isCompute">计算程序（永远保留）。</param>
        /// <param name="hasState">该记录带 ProgramPipelineState。</param>
        public static MergeResult<T> PreferStateful<T>(
            IEnumerable<T> items,
            Func<T, string> guestKey,
            Func<T, string> shadowKey,
            Func<T, bool> isCompute,
            Func<T, bool> hasState)
        {
            ArgumentNullException.ThrowIfNull(items);
            ArgumentNullException.ThrowIfNull(guestKey);
            ArgumentNullException.ThrowIfNull(shadowKey);
            ArgumentNullException.ThrowIfNull(isCompute);
            ArgumentNullException.ThrowIfNull(hasState);

            List<T> list = items.ToList();
            List<T> stateful = list.Where(item => !isCompute(item) && hasState(item)).ToList();
            if (stateful.Count == 0)
                return new MergeResult<T>(list, 0, 0);

            HashSet<string> statefulGuests = stateful.Select(guestKey).ToHashSet(StringComparer.Ordinal);
            HashSet<string> statefulShadows = stateful.Select(shadowKey).ToHashSet(StringComparer.Ordinal);

            List<T> kept = new(list.Count);
            int noStateSameGuest = 0, dropped = 0;
            foreach (T item in list)
            {
                if (isCompute(item) || hasState(item)) { kept.Add(item); continue; }
                if (!statefulGuests.Contains(guestKey(item))) { kept.Add(item); continue; }
                noStateSameGuest++;
                if (statefulShadows.Contains(shadowKey(item))) { dropped++; continue; }
                kept.Add(item);   // 同客体但特化不同：是另一个变体，必须保留
            }
            return new MergeResult<T>(kept, noStateSameGuest, dropped);
        }
    }
}
