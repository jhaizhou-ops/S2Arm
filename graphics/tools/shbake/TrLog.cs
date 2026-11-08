// 翻译告警分类计数（10-28 R15 画面还原 P1：BakeGpuAccessor.Log 原是空体，Ryujinx 翻译器的告警——未实现指令 stub、Invalid 指令、子模式告警——整条吞掉）。
//   种类 = 告警原文去掉地址与数字（十六进制 0x… → 0x#、独立的十进制数 → #；贴在名字上的数字如 F2I / Iadd3 / B0 保留），指令名 / 枚举名 / 阶段名照留；
//   烘焙收尾写 <输出根>/translator_log.tsv（种类、次数、首个着色器键）并在烘焙日志打一行汇总。只记录，不影响翻译结果。
//   口径：只计甲段（新配程序按缺省状态各翻一遍；继承条目不走甲段，不计）；次数按「每次翻译」计，同一着色器配进几个程序就计几次。
//   首个着色器键 = 同种类里抽取键字典序最小的那个（并行翻译下谁先到不固定，取最小让产物可复现）
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace S2A.ShBake
{
    sealed class TrLog
    {
        public const string FileName = "translator_log.tsv";
        static readonly Regex Num = new(@"\b0x[0-9A-Fa-f]+\b|\b\d+\b", RegexOptions.Compiled);
        readonly Dictionary<string, (int n, string key)> _kinds = new();

        public static string Kind(string message) =>
            Num.Replace(message.Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' ').Trim(), m => m.Value.StartsWith("0x") ? "0x#" : "#");
        public static bool IsStub(string kind) => kind.StartsWith("Shader instruction ") && kind.EndsWith(" is not implemented.");
        public static bool IsInvalidInst(string kind) => kind.StartsWith("Invalid instruction at ");

        public void Add(string message, string shaderKey)
        {
            string k = Kind(message);
            lock (_kinds)
            {
                _kinds.TryGetValue(k, out var v);
                _kinds[k] = (v.n + 1, v.key == null || string.CompareOrdinal(shaderKey, v.key) < 0 ? shaderKey : v.key);
            }
        }

        // 按次数降序、同次数按种类字典序
        public List<(string kind, int n, string key)> Rows()
        {
            lock (_kinds) return _kinds.Select(kv => (kv.Key, kv.Value.n, kv.Value.key)).OrderByDescending(r => r.n).ThenBy(r => r.Key, StringComparer.Ordinal).ToList();
        }
        public int Total => Rows().Sum(r => r.n);
        public int Stub => Rows().Where(r => IsStub(r.kind)).Sum(r => r.n);
        public int InvalidInst => Rows().Where(r => IsInvalidInst(r.kind)).Sum(r => r.n);

        public void Write(string path) =>
            File.WriteAllText(path, "# 种类（告警原文去地址 / 数字）\t次数\t首个着色器键（同种类取抽取键字典序最小）\n" + string.Concat(Rows().Select(r => $"{r.kind}\t{r.n}\t{r.key}\n")), new UTF8Encoding(false));

        public string Summary()
        {
            var rows = Rows();
            return $"shbake：翻译告警 {rows.Sum(r => r.n)} 条 {rows.Count} 种（未实现指令 {Stub}、Invalid 指令 {InvalidInst}）"
                + (rows.Count > 0 ? "；最多：" + string.Join("，", rows.Take(3).Select(r => $"{r.kind} ×{r.n}")) : "") + $" → {FileName}";
        }
    }
}
