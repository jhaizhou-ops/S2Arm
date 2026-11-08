// 影子顶点输入变体（_bv）：同 translator/dmsh_vin.py variant，逐条照搬（dsh 收敛到 C#，11-01）。
// 每个整数输入另声明一份 float4 与另一符号的整数（Metal 属性号 16–30），读前三者按位或进本体读的输入；宿主按格式类别把属性送到对应号、其余送零缓冲（nvn_mtl.m vin_ct）。
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using static S2A.Dsh.Py;

namespace S2A.Dsh
{
    public static class DshVin
    {
        const int SLOT0 = 16, SLOT_END = 31;   // Metal 顶点属性号 16..30
        /// <summary>→ (新 MSL, [{location, float, sint | uint}]) 或 (null, 原因串)</summary>
        public static (string, object) Variant(string msl)
        {
            var m = Search(@"\nstruct main0_in\n\{\n(.*?)\n\};", msl, RegexOptions.Singleline);
            if (!m.Success) return (null, Has(msl, "[[stage_in]]") ? "no main0_in struct" : "no integer input");
            var members = new List<(string t, string n, int l)>();
            foreach (var ln in m.Groups[1].Value.Split('\n'))
            {
                var mm = Full(@"    (float4|uint4|int4) (m_\d+(?:_\d+)*) \[\[attribute\((\d+)\)\]\];", ln);
                if (!mm.Success) { var s = ln.Trim(); return (null, "an input declaration not understood: " + (s.Length > 60 ? s[..60] : s)); }
                members.Add((mm.Groups[1].Value, mm.Groups[2].Value, Int(mm.Groups[3].Value)));
            }
            var ints = members.Where(x => x.t != "float4").ToList();
            if (ints.Count == 0) return (null, "no integer input");
            if (members.Any(x => x.l >= SLOT0)) return (null, "an input at attribute 16 or above");
            int slot = SLOT0; var shadows = new List<PyDict>(); var extra = new List<string>();
            foreach (var (t, n, l) in ints)
            {
                if (slot >= SLOT_END) break;
                extra.Add($"    float4 {n}_vf [[attribute({slot})]];"); shadows.Add(new PyDict { ["location"] = (long)l, ["float"] = (long)slot }); slot++;
            }
            for (int i = 0; i < shadows.Count && i < ints.Count; i++)
            {
                if (slot >= SLOT_END) break;
                var (t, n, l) = ints[i]; string o = t == "uint4" ? "int4" : "uint4";
                extra.Add($"    {o} {n}_vo [[attribute({slot})]];"); shadows[i][o == "int4" ? "sint" : "uint"] = (long)slot; slot++;
            }
            var covered = new Dictionary<long, PyDict>(); foreach (var e in shadows) covered[(long)e["location"]] = e;
            int end = m.Index + m.Length;
            string head = msl[..end] + "\n\nstruct main0_in_v\n{\n" + m.Groups[1].Value + "\n" + string.Join("\n", extra) + "\n};";
            string body = msl[end..];
            int cut = body.IndexOf("\nvertex void main0_tf(", System.StringComparison.Ordinal);
            if (cut >= 0) body = body[..cut] + "\n";
            var pro = new StringBuilder("    main0_in in = {};\n");
            foreach (var (t, n, l) in members)
            {
                string ors = "";
                if (covered.TryGetValue(l, out var e)) ors = $" | as_type<{t}>(dm_in.{n}_vf)" + (e.ContainsKey("sint") || e.ContainsKey("uint") ? $" | as_type<{t}>(dm_in.{n}_vo)" : "");
                pro.Append($"    in.{n} = dm_in.{n}{ors};\n");
            }
            foreach (var entry in new[] { "main0", "main0_z" })
            {
                var hdr = Search(@"\nvertex main0_out " + entry + @"\(main0_in in \[\[stage_in\]\]([^\n]*)\)\n\{\n", body);
                if (!hdr.Success) { if (entry == "main0") return (null, "main0 signature not recognized"); continue; }
                string nw = $"\nvertex main0_out {entry}(main0_in_v dm_in [[stage_in]]{hdr.Groups[1].Value})\n{{\n" + pro;
                body = body[..hdr.Index] + nw + body[(hdr.Index + hdr.Length)..];
            }
            return (head + body, shadows.Cast<object>().ToList());
        }
    }
}
