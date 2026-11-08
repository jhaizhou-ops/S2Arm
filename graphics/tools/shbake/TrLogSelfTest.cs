// 翻译告警分类计数单测（S2A.ShBake selftest-trlog [<输出目录>]；graphics/tools/shbake/tests/t_trlog.sh 调）：期望值全手算，不跑被测实现推期望。
//   ① 归类（TrLog.Kind）：告警原文按翻译器 Log 调用处的写法手拼，去地址 / 数字后的种类手写；
//   ② 计数与产物（TrLog.Add / Write）：3 条 Invalid（地址各异、键 k2 k1 k3）+ 2 条 Bpt（键 b a）+ 1 条 F2I → 3 种，次数 3 / 2 / 1，首键 k1 / a / k9；tsv 逐行比；
//   ③ 端到端：手拼顶点（AST a[0x80] ← R0、操作码 0（14 位译码表空位 → Invalid）、BPT（InstEmit.Bpt 是 stub）、EXIT）+ 片元（写渲染目标 0），
//      @hdr 相邻规则配成 1 个程序，用被测 S2A.ShBake bake 出包（子进程、不给 --xc）。期望：translator_log.tsv 恰 2 行——
//      「Invalid instruction at 0x# (0x#).」×1、「Shader instruction Bpt is not implemented.」×1，首键都是 v0；烘焙日志有汇总行「翻译告警 2 条 2 种（未实现指令 1、Invalid 指令 1）」。
//      反证：给旧版 S2A.ShBake（Log 空体）时没有 translator_log.tsv、没有汇总行（本项必红）。
//   给了 <输出目录> 则 ③ 的烘焙产物留在 <输出目录>/o（t_trlog.sh 拿它对基线做棘轮）；不给就用临时目录、跑完删
using System;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace S2A.ShBake
{
    static class TrLogSelfTest
    {
        static int _fail, _n;
        static void Ck(bool ok, string what) { _n++; if (!ok) _fail++; Console.WriteLine($"{(ok ? "✓" : "不通")} {what}"); }

        public static int Run(string outDir, string bakeBin)
        {
            // ① 归类：左 = 翻译器原文（按 Log 调用处的格式串手拼），右 = 期望种类
            (string msg, string kind)[] cases =
            {
                ("Invalid instruction at 0x000058 (0x0000000000000000).", "Invalid instruction at 0x# (0x#)."),   // Translator.cs EmitOps
                ("Shader instruction Bpt is not implemented.", "Shader instruction Bpt is not implemented."),        // InstEmit.cs stub
                ("Unimplemented 64-bits F2I.", "Unimplemented #-bits F2I."),                                          // InstEmitConversion：贴在名字上的 F2I 留
                ("Iadd3 has invalid component selection 2.", "Iadd3 has invalid component selection #."),           // Iadd3 的 3 贴在名字上，留
                ("Attribute offset 0x80 (UserDefined) is not valid for stage Fragment.", "Attribute offset 0x# (UserDefined) is not valid for stage Fragment."),
                ("Unsupported format for texture 12: R8Unorm.", "Unsupported format for texture #: R8Unorm."),
                ("Failed to find handle source for bindless access of type \"sampler2D\".", "Failed to find handle source for bindless access of type \"sampler2D\"."),
                ("Invalid barrier mode: 3.", "Invalid barrier mode: #."),   // 枚举越界时按数字打印
                ("Bad\ttab\nline", "Bad tab line"),                          // 制表符 / 换行不进 tsv
            };
            foreach (var (msg, kind) in cases) { string got = TrLog.Kind(msg); Ck(got == kind, $"归类「{msg.Replace("\t", "\\t").Replace("\n", "\\n")}」期望「{kind}」→ 实得「{got}」"); }
            Ck(TrLog.IsStub("Shader instruction Bpt is not implemented.") && !TrLog.IsStub("Unimplemented #-bits F2I.") && TrLog.IsInvalidInst("Invalid instruction at 0x# (0x#).") && !TrLog.IsInvalidInst("Invalid barrier mode: #."),
                "分类：stub 只认「Shader instruction X is not implemented.」、Invalid 指令只认「Invalid instruction at」");

            // ② 计数：期望（手算）3 种；Invalid 3 次首键 k1、Bpt 2 次首键 a、F2I 1 次首键 k9；合计 6、stub 2、Invalid 3
            TrLog t = new();
            t.Add("Invalid instruction at 0x000058 (0x0000000000000000).", "k2");
            t.Add("Invalid instruction at 0x000060 (0xFFFF000000000000).", "k1");
            t.Add("Shader instruction Bpt is not implemented.", "b");
            t.Add("Invalid instruction at 0x0001A8 (0x0123456789ABCDEF).", "k3");
            t.Add("Unimplemented 64-bits F2I.", "k9");
            t.Add("Shader instruction Bpt is not implemented.", "a");
            Ck(t.Total == 6 && t.Stub == 2 && t.InvalidInst == 3, $"合计 / stub / Invalid 期望 6 / 2 / 3 → 实得 {t.Total} / {t.Stub} / {t.InvalidInst}");
            string tmp = Path.Combine(Path.GetTempPath(), "s2a_trlog_" + Environment.ProcessId);
            Directory.CreateDirectory(tmp);
            string root = outDir ?? tmp;
            try
            {
                string tsv = Path.Combine(tmp, TrLog.FileName); t.Write(tsv);
                string[] want = { "Invalid instruction at 0x# (0x#).\t3\tk1", "Shader instruction Bpt is not implemented.\t2\ta", "Unimplemented #-bits F2I.\t1\tk9" };
                string[] got = File.ReadAllLines(tsv).Where(l => !l.StartsWith('#')).ToArray();
                Ck(got.SequenceEqual(want), $"tsv 按次数降序、首键取字典序最小：期望 {string.Join(" | ", want)} → 实得 {string.Join(" | ", got)}");
                Ck(t.Summary().Contains("翻译告警 6 条 3 种（未实现指令 2、Invalid 指令 3）"), $"汇总行：{t.Summary()}");

                // ③ 端到端
                bakeBin ??= Environment.ProcessPath;
                string x = Path.Combine(root, "x"), o = Path.Combine(root, "o");
                if (Directory.Exists(x)) Directory.Delete(x, true);
                if (Directory.Exists(o)) Directory.Delete(o, true);
                const ulong Ast = 0xEFF0000000000000UL | (0xFFUL << 39) | (0x80UL << 20) | (7UL << 16) | (0xFFUL << 8);   // AST a[0x80] ← R0（同 FoutSelfTest）
                const ulong Inv = 0x0000000000000000UL;   // 操作码高 14 位 = 0：InstTable 里没有这一格（空位）→ InstName.Invalid
                const ulong Bpt = 0xE3A0000000000000UL;   // 111000111010…：InstName.Bpt（InstEmit.Bpt 只打 not implemented）
                byte[] vs = VtgSelfTest.Guest(1 | (3 << 5) | (1 << 10), 0, 0, 0, 0, Ast, Inv, Bpt);
                byte[] fs = VtgSelfTest.Guest(2 | (3 << 5) | (5 << 10), 0, 0, 0, 0xF, VtgSelfTest.Exit);
                SrcPack.Append(x, "v0", new byte[0x30].Concat(vs).ToArray(), new byte[0x800]);
                SrcPack.Append(x, "p0", new byte[0x30].Concat(fs).ToArray(), new byte[0x800]);
                File.WriteAllText(Path.Combine(x, "rows.tsv"), "v0\tvs\ttrlog.bin@hdr0x0\t0\np0\tps\ttrlog.bin@hdr0x100\t0\n");

                ProcessStartInfo psi = new(bakeBin) { RedirectStandardOutput = true, RedirectStandardError = true };
                foreach (string a in new[] { "bake", x, o, "--title", "0100000000f0a701", "-j", "2" }) psi.ArgumentList.Add(a);
                psi.Environment["S2A_NO_ALPHA_VARIANTS"] = "1";
                foreach (string v in new[] { "S2A_PROG_TABLE", "S2A_PAIR_TABLE", "S2A_STAGE_ALL", "S2A_SHBAKE_PAIR_ONLY", "S2A_SHBAKE_GS_ONLY", "S2A_SPEC_PIPES" }) psi.Environment.Remove(v);
                string log;
                using (Process pr = Process.Start(psi))
                {
                    var t1 = pr.StandardOutput.ReadToEndAsync(); var t2 = pr.StandardError.ReadToEndAsync();
                    if (!pr.WaitForExit(120_000)) { pr.Kill(true); Ck(false, "烘焙 120 秒没完"); return 1; }
                    log = t1.Result + t2.Result;
                    Ck(pr.ExitCode == 0, $"烘焙退出 0（实得 {pr.ExitCode}）");
                }
                foreach (string l in log.Split('\n').Where(l => l.Contains("翻译告警") || l.Contains("【红】"))) Console.WriteLine("  | " + l.TrimEnd());
                string ot = Path.Combine(o, TrLog.FileName);
                string[] eWant = { "Invalid instruction at 0x# (0x#).\t1\tv0", "Shader instruction Bpt is not implemented.\t1\tv0" };
                string[] eGot = File.Exists(ot) ? File.ReadAllLines(ot).Where(l => !l.StartsWith('#')).OrderBy(l => l, StringComparer.Ordinal).ToArray() : new[] { "（没有 translator_log.tsv）" };
                Ck(eGot.SequenceEqual(eWant), $"端到端 translator_log.tsv：期望 {string.Join(" | ", eWant)} → 实得 {string.Join(" | ", eGot)}");
                Ck(log.Contains("翻译告警 2 条 2 种（未实现指令 1、Invalid 指令 1）"), "端到端：烘焙日志有汇总行（未实现指令 1、Invalid 指令 1）");
            }
            catch (Exception e) { Ck(false, $"抛异常 {e.GetType().Name}: {e.Message}"); }
            finally { if (Directory.Exists(tmp)) Directory.Delete(tmp, true); }
            Console.WriteLine($"t_trlog：{_n} 项，失败 {_fail}");
            return _fail == 0 ? 0 : 1;
        }
    }
}
