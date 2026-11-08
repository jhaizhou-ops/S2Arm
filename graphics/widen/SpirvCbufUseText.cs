// 着色器常量读法（SpirvCbufUse）的一行文本：离线表（直连着色器库构建时写）与运行时登记（WidenSession.Shader）之间的格式。
// 放在运行时工程而不是 shader/：着色器阶段键只随 shader/ 变，加这个格式不该让九款重新翻译。
// 格式：各槽用 ';' 分隔，每项「槽号:下标,下标,…」（着色器会读的 vec4 下标，升序）或「槽号:*」（动态下标，整个绑定都会读）。例："0:0,1,2,3;3:*"。空串 = 不读任何常量槽。
using System;
using System.Collections.Generic;
using System.Text;

namespace S2Arm.Gfx.Widen
{
    public static class SpirvCbufUseText
    {
        /// <summary>按 SPIR-V 分析出的读法写文本。slotOfBinding：SPIR-V 绑定号 → 常量槽号（null = 绑定号就是槽号；映射不到 / 为负的跳过）。</summary>
        public static string Format(IReadOnlyList<CbufUse> uses, ReadOnlySpan<int> slotOfBinding)
        {
            var parts = new SortedDictionary<int, string>();
            foreach (CbufUse u in uses)
            {
                int slot = u.Binding;
                if (slotOfBinding.Length > 0) slot = (uint)u.Binding < (uint)slotOfBinding.Length ? slotOfBinding[u.Binding] : -1;
                if (slot < 0) continue;
                parts[slot] = u.Dynamic ? "*" : string.Join(",", u.Indices.ToArray());
            }
            var sb = new StringBuilder();
            foreach (var kv in parts) { if (sb.Length > 0) sb.Append(';'); sb.Append(kv.Key).Append(':').Append(kv.Value); }
            return sb.ToString();
        }

        /// <summary>解析成按槽号的读法表（下标 = 槽号，null = 这个槽不读）。格式坏的项跳过。</summary>
        public static CbufUse[] Parse(string text, int slots)
        {
            var o = new CbufUse[slots];
            foreach (string item in text.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                int c = item.IndexOf(':');
                if (c <= 0 || !int.TryParse(item.AsSpan(0, c), out int slot) || (uint)slot >= (uint)slots) continue;
                string rest = item[(c + 1)..];
                var u = new CbufUse { Binding = slot, Dynamic = rest == "*" };
                if (!u.Dynamic)
                    foreach (string s in rest.Split(',', StringSplitOptions.RemoveEmptyEntries))
                        if (int.TryParse(s, out int i) && i >= 0) u.Add(i);
                o[slot] = u;
            }
            return o;
        }
    }
}
