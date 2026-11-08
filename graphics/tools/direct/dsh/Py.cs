// 移植用的 Python 语义小工具：str.find / 切片的负下标、re 的锚定写法、json.dump(indent=1, ensure_ascii=False) 的逐字节输出、保序字典。
// 离线链（dmsh_build.py）的字符串处理逐条照搬，这里只补 C# 与 Python 语义不同的那几处，免得移植处各写各的。
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace S2A.Dsh
{
    /// <summary>保序字典（Python dict：改已有键不挪位置）</summary>
    sealed class PyDict : OrderedDictionary<string, object>
    {
        public PyDict() : base(StringComparer.Ordinal) { }
        public PyDict(PyDict src) : base(StringComparer.Ordinal) { foreach (var kv in src) Add(kv.Key, kv.Value); }
        public PyDict Set(string k, object v) { this[k] = v; return this; }
    }

    /// <summary>JSON 数字原文（答案表里带来的值原样写回）</summary>
    sealed record PyNum(string Text);

    static class Py
    {
        const RegexOptions O = RegexOptions.CultureInvariant;

        /// <summary>str.find(sub, start)：start 为负从尾部算</summary>
        public static int Find(string s, string sub, int start = 0)
        {
            if (start < 0) start = Math.Max(0, start + s.Length);
            if (start > s.Length) return -1;
            return s.IndexOf(sub, start, StringComparison.Ordinal);
        }
        public static int Find(string s, char c, int start = 0)
        {
            if (start < 0) start = Math.Max(0, start + s.Length);
            if (start >= s.Length) return -1;
            return s.IndexOf(c, start);
        }
        /// <summary>str.rfind(c, 0, end)</summary>
        public static int RFind(string s, char c, int end) => end <= 0 ? -1 : s.LastIndexOf(c, Math.Min(end, s.Length) - 1);
        /// <summary>s[a:b]（Python 切片：负下标从尾部算，越界截断）</summary>
        public static string Sl(string s, int a, int? b = null)
        {
            int n = s.Length, x = a < 0 ? Math.Max(0, a + n) : Math.Min(a, n), y = b is int bb ? (bb < 0 ? Math.Max(0, bb + n) : Math.Min(bb, n)) : n;
            return y > x ? s.Substring(x, y - x) : "";
        }
        public static byte[] Sl(byte[] s, int a, int b)
        {
            int n = s.Length, x = a < 0 ? Math.Max(0, a + n) : Math.Min(a, n), y = b < 0 ? Math.Max(0, b + n) : Math.Min(b, n);
            return y > x ? s.AsSpan(x, y - x).ToArray() : Array.Empty<byte>();
        }
        public static string Replace(string s, string a, string b) => s.Replace(a, b, StringComparison.Ordinal);
        /// <summary>str.replace(a, b, 1)</summary>
        public static string Replace1(string s, string a, string b)
        {
            int i = s.IndexOf(a, StringComparison.Ordinal);
            return i < 0 ? s : string.Concat(s.AsSpan(0, i), b, s.AsSpan(i + a.Length));
        }
        public static int Count(string s, string sub)
        {
            int n = 0;
            for (int i = s.IndexOf(sub, StringComparison.Ordinal); i >= 0; i = s.IndexOf(sub, i + sub.Length, StringComparison.Ordinal)) n++;
            return n;
        }
        public static bool Has(string s, string sub) => s.Contains(sub, StringComparison.Ordinal);

        // ---- re ----
        // 正则缓存（11-06 出包速度线，Air 喷射战士3 直连库剖析：出库进程真在算的里头正则解释执行占最大一块）：原先 R() 每次 new Regex（每支着色器、每处改写都重新解析式子），
        //   Search / All / Full / MatchStart 走 .NET 静态方法，自带缓存只留最近 15 个式子、本文件用到的远多于此，一直被挤掉重建。
        //   改为按（式子, 选项）缓存：先用解释版，同一式子用满 RegexHot 次换成编译成机器码的版本（常量式子很快升级；每支着色器拼一次的动态式子不白花编译）；
        //   缓存满 RegexMax 条后不再收新式子（照旧现建解释版）。匹配语义与原先逐字相同（RegexOptions.Compiled 只换执行方式）
        sealed class RegexSlot { public Regex Rx; public int Uses; }
        static readonly System.Collections.Concurrent.ConcurrentDictionary<(string, RegexOptions), RegexSlot> Rc = new();
        const int RegexHot = 32, RegexMax = 4096;
        public static Regex R(string pattern, RegexOptions o = RegexOptions.None)
        {
            var key = (pattern, o | O);
            if (!Rc.TryGetValue(key, out var slot))
            {
                if (Rc.Count >= RegexMax) return new Regex(pattern, o | O);
                slot = Rc.GetOrAdd(key, k => new RegexSlot { Rx = new Regex(k.Item1, k.Item2) });
            }
            if (System.Threading.Interlocked.Increment(ref slot.Uses) == RegexHot) slot.Rx = new Regex(pattern, o | O | RegexOptions.Compiled);
            return slot.Rx;
        }
        /// <summary>re.search</summary>
        public static Match Search(string pattern, string s, RegexOptions o = RegexOptions.None) => R(pattern, o).Match(s);
        /// <summary>re.match（只在开头）</summary>
        public static Match MatchStart(string pattern, string s, RegexOptions o = RegexOptions.None) => R(@"\A(?:" + pattern + ")", o).Match(s);
        /// <summary>re.fullmatch</summary>
        public static Match Full(string pattern, string s, RegexOptions o = RegexOptions.None) => R(@"\A(?:" + pattern + @")\z", o).Match(s);
        public static MatchCollection All(string pattern, string s, RegexOptions o = RegexOptions.None) => R(pattern, o).Matches(s);
        /// <summary>re.sub(pattern, repl, s, count)：repl 是字面串（不解释 $）</summary>
        public static string Sub(string pattern, string repl, string s, int count = -1, RegexOptions o = RegexOptions.None)
            => R(pattern, o).Replace(s, _ => repl, count);
        public static string Esc(string s) => Regex.Escape(s);
        public static bool G(Match m) => m != null && m.Success;
        public static int Int(string s) => int.Parse(s, NumberStyles.None, CultureInfo.InvariantCulture);
        public static long Hex(string s) => long.Parse(s, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture);

        // ---- json.dump(value, f, ensure_ascii=False, indent=1)：逐字节同 Python ----
        public static string Dumps(object v) { var sb = new StringBuilder(); Enc(sb, v, 0); return sb.ToString(); }
        static void Enc(StringBuilder sb, object v, int lv)
        {
            switch (v)
            {
                case null: sb.Append("null"); return;
                case bool b: sb.Append(b ? "true" : "false"); return;
                case string s: Str(sb, s); return;
                case int i: sb.Append(i.ToString(CultureInfo.InvariantCulture)); return;
                case long l: sb.Append(l.ToString(CultureInfo.InvariantCulture)); return;
                case PyNum n: sb.Append(n.Text); return;
                case JsonNode j: Enc(sb, FromJson(j), lv); return;
                case PyDict d:
                    if (d.Count == 0) { sb.Append("{}"); return; }
                    sb.Append('{'); bool first = true;
                    foreach (var kv in d)
                    {
                        sb.Append(first ? "\n" : ",\n").Append(' ', lv + 1); first = false;
                        Str(sb, kv.Key); sb.Append(": "); Enc(sb, kv.Value, lv + 1);
                    }
                    sb.Append('\n').Append(' ', lv).Append('}'); return;
                case System.Collections.IEnumerable e:
                    {
                        bool none = true;
                        foreach (var x in e)
                        {
                            sb.Append(none ? "[\n" : ",\n").Append(' ', lv + 1); none = false;
                            Enc(sb, x, lv + 1);
                        }
                        sb.Append(none ? "[]" : "\n" + new string(' ', lv) + "]"); return;
                    }
                default: throw new ArgumentException("json：不认识的值类型 " + v.GetType().Name);
            }
        }
        static void Str(StringBuilder sb, string s)
        {
            sb.Append('"');
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    case '\b': sb.Append("\\b"); break;
                    case '\f': sb.Append("\\f"); break;
                    default:
                        if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture)); else sb.Append(c);
                        break;
                }
            }
            sb.Append('"');
        }
        /// <summary>System.Text.Json 节点 → 本文件的值模型（对象保序；数字留原文）</summary>
        public static object FromJson(JsonNode j)
        {
            switch (j)
            {
                case null: return null;
                case JsonObject o: { var d = new PyDict(); foreach (var kv in o) d[kv.Key] = FromJson(kv.Value); return d; }
                case JsonArray a: { var l = new List<object>(); foreach (var x in a) l.Add(FromJson(x)); return l; }
                case JsonValue v:
                    if (v.TryGetValue(out string s)) return s;
                    if (v.TryGetValue(out bool b)) return b;
                    if (v.TryGetValue(out long l2)) return l2;
                    return new PyNum(v.ToJsonString());
                default: throw new ArgumentException("json 节点");
            }
        }
    }
}
