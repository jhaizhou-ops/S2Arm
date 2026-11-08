// 片元着色器的「可读瓦片」版本（_bf）：同 translator/dmsh_fetch.py variant，逐条照搬（dsh 收敛到 C#，11-01 总指挥：出包改由 C# 常驻进程翻译，离线 Python 改写器删掉）。
// 同一遍里后面的绘制在本像素采样前面绘制写的颜色附件时，改成从瓦片直接读（帧缓冲读取），两遍并成一遍。函数常量编号：FX_i = i（第 i 个可改写采样读哪个颜色序号，-1 = 照常采样）；
//   FB_k（开颜色输入 k）= 32 + k；OM_j_k（第 j 个输出写附件 k）= 64 + 8 j + k。可改写的采样与投影屏幕坐标写法见 dmsh_fetch.py 文件头。
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using static S2A.Dsh.Py;

namespace S2A.Dsh
{
    public static class DshFetch
    {
        const int NFB = 8;
        // 操作数 V：变量 _N，或直接读插值分量 in.m_N.c——翻译器关 DebugMode 后表达式传播把分量读并进乘法 / 倒数 / float2（11-07 卡顿线：旷野之息 0b6d8f4f993ae7ee
        //   关 DebugMode 后坐标写成「_70 = in.m_40.x * _64; _64 = 1.0 / in.m_40.w;」，只认 _N 的旧写法认不出，整款 0 个 _bf，G-buffer 读自身附件改成断遍采样、林克画成剪影）
        const string V = @"(_\d+|in\.m_\d+\.[xyzw])";
        static readonly Regex Def = R(@"float(2?) (_\d+) = ([^;]*);"), Mul = R(V + @" \* " + V), Recip = R(@"1\.0 / " + V), F2 = R(@"float2\(((?:[^,()]|\((?:[^()]|\([^()]*\))*\))+), ((?:[^,()]|\((?:[^()]|\([^()]*\))*\))+)\)");
        static readonly Dictionary<char, Regex> Comp = "xyzw".ToDictionary(c => c, c => R(@"in\.(m_\d+)\." + c));
        static readonly Regex Tex = R(@"texture2d<float> (\w+) \[\[id\(\d+\)\]\];"), Locn = R(@"float4 (m_\d+) \[\[user\(locn(\d+)\)\]\];");
        static readonly Regex Pat = R(@"spvDescriptorSet0\.(\w+)\.sample\(spvDescriptorSet0\.(\w+)Smplr, (?:s2a_uv\()?select\((_\d+), float2\(0\.0\), isnan\(\3\)\)(?:, spvDescriptorSet0\.s2a_uvx\[\d+\]\))?"
                                      + @"(?:, bias\(spvDescriptorSet0\.s2a_lb\[\d+\]\))?\)");

        // 任意赋值（带不带类型声明）：循环 / 分支里会被重新赋值的临时量不能代回其定义（11-07：旷野之息 0e0440f4f042f99d 循环变量「float _80 = _46;」后在循环体里「_80 = _299;」）
        static readonly Regex AnyAssign = R(@"(?<![\w.])(_\d+)\s*=(?!=)\s*([^;]*);");
        static Dictionary<(string, string), List<string>> Defs(string msl)   // → {(类型 "" / "2", 变量): [各处定义的右侧，按出现顺序]}；另记 ("=", 变量)：全部赋值（含不带类型的）
        {
            var d = new Dictionary<(string, string), List<string>>();
            foreach (Match m in Def.Matches(msl))
            {
                var k = (m.Groups[1].Value, m.Groups[2].Value);
                if (!d.TryGetValue(k, out var l)) d[k] = l = new List<string>();
                l.Add(m.Groups[3].Value);
            }
            foreach (Match m in AnyAssign.Matches(msl))
            {
                var k = ("=", m.Groups[1].Value);
                if (!d.TryGetValue(k, out var l)) d[k] = l = new List<string>();
                l.Add(m.Groups[2].Value);
            }
            return d;
        }
        // 11-07 卡顿线：坐标分量按「因子多重集」规范化后识别，与翻译器写法（DebugMode 开时逐个临时量 / 关时表达式内联）无关。
        //   临时量 _N 有且只有一处 float 定义、整段代码里也只被赋值这一次才代回；「1.0 / X」记作 inv(X)；括号里的纯乘积摊平；系数 1.0 省略；其余片段按去空白文本当一个因子。
        //   直接读 = {in.m_K.x}；投影屏幕坐标 = {in.m_K.x, inv(in.m_K.w)}（同旧模板 x = A * R、A = 分量读、R = 1.0 / w 分量读，不约分、不放宽）
        static readonly Regex Inv = R(@"1\.0 / (.+)"), Comp1 = R(@"in\.(m_\d+)\.([xyzw])");
        static List<string> Factors(string e, Dictionary<(string, string), List<string>> d, int depth = 0)
        {
            e = e.Trim();
            if (depth > 64) return new List<string> { Regex.Replace(e, @"\s+", "") };
            while (e.Length > 1 && e[0] == '(' && Closes(e)) e = e[1..^1].Trim();
            var parts = TopSplit(e, '*');
            if (parts.Count > 1) return parts.SelectMany(x => Factors(x, d, depth + 1)).Where(x => x != "1.0").OrderBy(x => x, System.StringComparer.Ordinal).ToList();
            var inv = FullAt(Inv, e);
            if (inv != null && TopSplit(e, '/').Count == 2) return new List<string> { "inv(" + string.Join("*", Factors(inv.Groups[1].Value, d, depth + 1)) + ")" };
            if (Full(@"_\d+", e).Success && d.TryGetValue(("", e), out var l) && l.Count == 1 && !(d.TryGetValue(("=", e), out var re) && re.Count > 1)) return Factors(l[0], d, depth + 1);
            return new List<string> { Regex.Replace(e, @"\s+", "") };
        }
        static bool Closes(string e) { int k = 0; for (int i = 0; i < e.Length; i++) { if (e[i] == '(') k++; else if (e[i] == ')' && --k == 0 && i != e.Length - 1) return false; } return true; }
        static List<string> TopSplit(string e, char op)   // 顶层（括号 / 方括号外）按 op 切；含 + − ? : , 的顶层表达式整体不切（不是纯乘积）
        {
            var r = new List<string>(); int k = 0, st = 0;
            for (int i = 0; i < e.Length; i++)
            {
                char c = e[i];
                if (c == '(' || c == '[') k++; else if (c == ')' || c == ']') k--;
                else if (k == 0 && (c == '?' || c == ':' || c == ',' || c == '<' || c == '>' || c == '=' || c == '&' || c == '|' || ((c == '+' || c == '-') && i > 0 && !(e[i - 1] == 'e' && i > 1 && char.IsDigit(e[i - 2]))))) return new List<string> { e };
                else if (k == 0 && c == op) { r.Add(e[st..i]); st = i + 1; }
            }
            r.Add(e[st..]); return r;
        }
        // 分量 u 是不是插值量的 c 分量 → (插值量成员名, 投影?) 或 null
        static (string Mem, bool Proj)? CompOf(string u, char c, Dictionary<(string, string), List<string>> d)
        {
            var f = Factors(u, d);
            if (f.Count == 1) { var m = FullAt(Comp1, f[0]); if (m != null && m.Groups[2].Value[0] == c) return (m.Groups[1].Value, false); }
            if (f.Count == 2)
            {
                string a = f.FirstOrDefault(x => !x.StartsWith("inv(", System.StringComparison.Ordinal)), w = f.FirstOrDefault(x => x.StartsWith("inv(", System.StringComparison.Ordinal));
                var ma = a == null ? null : FullAt(Comp1, a); var mw = w == null ? null : FullAt(Comp1, w[4..^1]);
                if (ma != null && mw != null && ma.Groups[2].Value[0] == c && mw.Groups[2].Value == "w" && ma.Groups[1].Value == mw.Groups[1].Value) return (ma.Groups[1].Value, true);
            }
            return null;
        }
        static Match FullAt(Regex rx, string rhs)   // Python re.fullmatch：预编译的 rx 从头匹配到尾（.NET 没有 fullmatch，按位置与长度核）
        {
            for (var m = rx.Match(rhs); m.Success; m = m.NextMatch()) if (m.Index == 0 && m.Length == rhs.Length) return m;
            return null;
        }
        /// <summary>→ (新 MSL, 元数据 PyDict) 或 (null, 原因串)；同 dmsh_fetch.variant(msl, bindings, om_only_ok)</summary>
        public static (string, object) Variant(string msl, JsonArray bindings, bool omOnlyOk = false)
        {
            var tex = new HashSet<string>(); foreach (Match m in Tex.Matches(msl)) tex.Add(m.Groups[1].Value);
            string inStruct = msl.Split("struct main0_in", 2).Last().Split("};", 2)[0];
            var locn = new Dictionary<string, int>(); foreach (Match m in Locn.Matches(inStruct)) locn[m.Groups[1].Value] = Int(m.Groups[2].Value);
            Dictionary<(string, string), List<string>> dd = null;
            var reg = new Dictionary<string, long>();
            foreach (var b in bindings)
                if (b is JsonObject o && o["kind"] is JsonNode k && (string)k == "tex" && o["msl_name"] is JsonNode n && !string.IsNullOrEmpty((string)n) && o["reg"] is JsonNode r)
                    reg[(string)n] = (long)r;
            var calls = new List<PyDict>(); var parts = new StringBuilder(); int pos = 0;
            Match DefFull(string kind, string v, Regex rx) { if (!dd.TryGetValue((kind, v), out var l)) return null; foreach (var rhs in l) { var m = FullAt(rx, rhs); if (m != null) return m; } return null; }
            foreach (Match m in Pat.Matches(msl))
            {
                string member = m.Groups[1].Value, v = m.Groups[3].Value;
                if (!tex.Contains(member) || member != m.Groups[2].Value || !reg.ContainsKey(member)) continue;
                dd ??= Defs(msl);
                var d = DefFull("2", v, F2);
                var cx = d == null ? null : CompOf(d.Groups[1].Value, 'x', dd); var cy = d == null ? null : CompOf(d.Groups[2].Value, 'y', dd);
                if (cx == null || cy == null || cx.Value.Mem != cy.Value.Mem || cx.Value.Proj != cy.Value.Proj || !locn.ContainsKey(cx.Value.Mem)) continue;
                int proj = cx.Value.Proj ? 1 : 0; string vmem = cx.Value.Mem;
                int i = calls.Count;
                if (i >= 32) break;
                var sel = string.Concat(Enumerable.Range(0, NFB).Select(kk => $"FX_{i} == {kk} ? fb{kk} : "));
                parts.Append(msl, pos, m.Index - pos); parts.Append('(').Append(sel).Append(m.Value).Append(')'); pos = m.Index + m.Length;
                var c = new PyDict { ["fc"] = (long)i, ["tex_reg"] = reg[member], ["varying_locn"] = (long)locn[vmem] };
                if (proj != 0) c["proj"] = 1L;
                calls.Add(c);
            }
            if (calls.Count == 0 && !omOnlyOk) return (null, "no rewritable sample");
            var conv = new Dictionary<long, int>(); foreach (var c in calls) { long t = (long)c["tex_reg"]; conv[t] = conv.GetValueOrDefault(t) + 1; }
            var mixed = reg.Where(kv => tex.Contains(kv.Key) && Count(msl, $"spvDescriptorSet0.{kv.Key}.") > conv.GetValueOrDefault(kv.Value)).Select(kv => kv.Value).Distinct().OrderBy(x => x).Select(x => (object)x).ToList();
            string body = parts.ToString() + msl[pos..];
            var om = Search(@"struct main0_out\s*\{(.*?)\};", body, RegexOptions.Singleline);
            if (!om.Success) return (null, "no output struct");
            var outs = All(@"(\w+) (m_\d+) \[\[color\((\d+)\)\]\];", om.Groups[1].Value).Select(x => (t: x.Groups[1].Value, n: x.Groups[2].Value, c: Int(x.Groups[3].Value))).ToList();
            if (outs.Count == 0 || outs.Count > 4 || Sub(@"\w+ m_\d+ \[\[color\(\d+\)\]\];", "", om.Groups[1].Value).Trim() != "") return (null, "the output struct is not plain color outputs (or has more than 4)");
            var members = new StringBuilder();
            for (int j = 0; j < outs.Count; j++) for (int k = 0; k < NFB; k++) members.Append($"    {outs[j].t} {outs[j].n}_at{k} [[color({k}), function_constant(OM_{j}_{k})]];\n");
            body = body[..om.Groups[1].Index] + "\n" + members + body[(om.Groups[1].Index + om.Groups[1].Length)..];
            var consts = new StringBuilder();
            foreach (var c in calls) consts.Append($"constant int FX_{c["fc"]} [[function_constant({c["fc"]})]];\n");
            for (int k = 0; k < NFB; k++) consts.Append($"constant bool FB_{k} [[function_constant({32 + k})]];\n");
            for (int j = 0; j < outs.Count; j++) for (int k = 0; k < NFB; k++) consts.Append($"constant bool OM_{j}_{k} [[function_constant({64 + 8 * j + k})]];\n");
            body = ReplaceOnce(body, "using namespace metal;\n", "using namespace metal;\n\n" + consts);
            int i0 = body.IndexOf("fragment main0_out main0(", System.StringComparison.Ordinal);
            int i1 = i0 >= 0 ? body.IndexOf(")\n{", i0, System.StringComparison.Ordinal) : -1;
            if (i0 < 0 || i1 < 0) return (null, "main function signature not recognized");
            body = body[..i1] + string.Concat(Enumerable.Range(0, NFB).Select(k => $", float4 fb{k} [[color({k}), function_constant(FB_{k})]]")) + body[i1..];
            body = ReplaceOnce(body, "    main0_out out = {};\n", "    main0_out out = {};\n" + string.Concat(outs.Select(o => $"    {o.t} spv_o_{o.n} = {o.t}(0);\n")));
            foreach (var o in outs) body = body.Replace($"out.{o.n}", $"spv_o_{o.n}");
            var put = new StringBuilder();
            for (int j = 0; j < outs.Count; j++) for (int k = 0; k < NFB; k++) put.Append($"    if (OM_{j}_{k}) out.{outs[j].n}_at{k} = spv_o_{outs[j].n};\n");
            var returns = R(@"^[ \t]*return out;[ \t]*\n", RegexOptions.Multiline);
            if (!returns.IsMatch(body)) return (null, "return out not found");
            body = returns.Replace(body, m => put + m.Value);
            var meta = new PyDict { ["calls"] = calls.Cast<object>().ToList(), ["mixed_regs"] = mixed,
                                    ["outputs"] = outs.Select(o => (object)new PyDict { ["color"] = (long)o.c, ["type"] = o.t }).ToList() };
            return (body, meta);
        }
        static string ReplaceOnce(string s, string a, string b) { int i = s.IndexOf(a, System.StringComparison.Ordinal); return i < 0 ? s : s[..i] + b + s[(i + a.Length)..]; }
    }
}
