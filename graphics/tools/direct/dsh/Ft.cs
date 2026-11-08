// 片元输出类型变体 <键>_ft（现编回收 R2，docs/研究/现编回收方案.md）：同 translator/dmsh_build.py ft_masks 与 ft_finish「拼 MSL」那段，逐条照搬（dsh 收敛到 C#）。
// 每个请求的掩码（fout_want.tsv，graphics/tools/direct/fout_want.m）一个入口 main0_t<u>_<s>，建管线时画布是整数格式、库里 main0 / main0_u 都对不上的从库里取；编译归 Python 编排层。
using System;
using System.Collections.Generic;
using System.Linq;

namespace S2A.Dsh
{
    static class DshFt   // internal：参数是 PyDict（本程序集内部的值模型）；对拍工具经 InternalsVisibleTo 调
    {
        static bool Truthy(object v) => v switch { null => false, bool b => b, long l => l != 0, int i => i != 0, string s => s.Length > 0, System.Collections.ICollection c => c.Count > 0, _ => true };

        /// <summary>本片元着色器的库带哪些输出类型变体（同 dmsh_build.ft_masks）：fout_want.tsv 的原始掩码按宿主的过滤（nvn_mtl.m pso_int_need：只留着色器写的颜色 raster.colors）
        /// 收窄（有符号位 8 双源混合留着，nvn_mtl.m pso_fout_need），去掉宿主拿 main0_u 的（只有无符号且等于 u_mask）与什么都不要的。→ 升序 [(无符号, 有符号)]</summary>
        public static List<(long U, long S)> Masks(PyDict refl, IEnumerable<(long U, long S)> want)
        {
            var raster = refl.TryGetValue("raster", out var r) && Truthy(r) ? r as PyDict : null;
            object cols = null; raster?.TryGetValue("colors", out cols);
            long cm = 0;
            if (cols is List<object> cl) { foreach (var c in cl) { long x = Convert.ToInt64(c); if (0 <= x && x < 8) cm += 1L << (int)x; } }   // Python 是 sum（不是按位或），照搬
            else cm = 0xff;
            object um = Truthy(refl.GetValueOrDefault("entry_u")) ? refl.GetValueOrDefault("u_mask") : null;
            var got = new HashSet<(long, long)>();
            foreach (var (u, s) in want ?? Enumerable.Empty<(long, long)>()) got.Add((u & cm, s & (cm | DshCompiler.FoutDual)));   // 有符号位 8 = 双源混合（FsTyped），不是颜色位置、不按颜色过滤
            // 双源混合静态判（11-05 总指挥定）：只写颜色输出 0 与 1 的片元，不管真跑留下的管线键（fout_want.tsv）里有没有，都出 [[color(0), index(0 / 1)]] 变体。
            //   原先只靠真跑留下的键：World War Z 两支片元（380b1265ab53544a_b、22018388723d4d08_b）以前没跑到，建管线时游戏已复用控制段、宿主翻不出变体（nvn_mtl.m pso_fout_variant），
            //   管线建不出（「Fragment shader does not write to render target color(0), index(1)」）。双源只用到输出 0 / 1，所以只写这两个的才是候选；没有颜色信息（cm = 0xff）证明不了，不加
            if (cols is List<object> && cm == 0b11) got.Add((0, DshCompiler.FoutDual));
            return got.Where(m => m != (0, 0) && !(um != null && m == (Convert.ToInt64(um), 0))).OrderBy(m => m.Item1).ThenBy(m => m.Item2).ToList();
        }

        /// <summary>&lt;键&gt;_ft 的 MSL（同 dmsh_build.ft_finish 拼 MSL 那段）：src 截掉 main0_u 之后的部分，每个掩码接一份 FsTyped 出的结构体 + 入口，改名 main0_out_t&lt;u&gt;_&lt;s&gt; / main0_t&lt;u&gt;_&lt;s&gt;。
        /// 任一掩码认不出 main0 → null</summary>
        public static string Msl(string src, IEnumerable<(long U, long S)> want)
        {
            int i = src.IndexOf("\nstruct main0_out_u\n", StringComparison.Ordinal);
            string cut = i >= 0 ? src[..i] : src, msl = cut;
            foreach (var (u, s) in want)
            {
                string t = DshCompiler.FsTyped(src, (uint)u, (uint)s);
                if (t == null) return null;
                string nm = $"{u:x}_{s:x}";
                msl += t[cut.Length..].Replace("main0_out_t", "main0_out_t" + nm, StringComparison.Ordinal).Replace(" main0_t(", $" main0_t{nm}(", StringComparison.Ordinal);
            }
            return msl;
        }
    }
}
