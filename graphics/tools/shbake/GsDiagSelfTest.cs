// #1456 单点诊断（S2AGsDiag）的门序与写出单测（S2A.ShBake selftest-gsdiag；graphics/tools/shbake/tests/t_gsdiag.sh 调）：
//   ① 玩家包形态（标记 env 不存在=原生门关）：S2A_GS_DIAG=1 也设着 —— On 仍关、三类 API 走一遍零行输出、
//      s_envProbes==0（连诊断 env 都没读；退回「无条件读属性/env」的实现这里必红）；
//   ② 标记在、诊断 env 缺：门开但不给 S2A_GS_DIAG —— On 关、env 恰好读一次、零输出（门开也要显式开诊断）；
//   ③ 标记在、诊断 env=1：直通几何登记（含来源与遮挡态）、遮挡复位×2 报告×1（在飞 1）、SSBO+可写镜像客体 VA 随提交行落盘，
//      行内含 ssbo:0x0（漏填原值不打折）、img-s2、遮挡开×1、追加点×1；下一次提交原子面归零（缓冲只记上次提交以来的）。
using Ryujinx.Common;
using System;
using System.Collections.Generic;

namespace S2A.ShBake
{
    static class GsDiagSelfTest
    {
        static int _fail, _n;
        static void Ck(bool ok, string what) { _n++; if (!ok) _fail++; Console.WriteLine($"{(ok ? "✓" : "不通")} {what}"); }

        internal static int Run()
        {
            List<string> lines = new();

            // ① 玩家包形态：默认门只认原生注的 S2A_DEBUG_ENTRIES；标记缺 = 原生门关（编译期/属性任一道没开都到不了这里），
            //    诊断 env 故意开着，证明门先查、诊断 env 不读、一行不写——退回无条件读 env/属性的实现这里必红
            S2AGsDiag.S2ATestReset();
            Environment.SetEnvironmentVariable("S2A_DEBUG_ENTRIES", null);
            Environment.SetEnvironmentVariable("S2A_GS_DIAG", "1");
            S2AGsDiag.s_emit = lines.Add;
            Ck(!S2AGsDiag.On, "玩家包形态（标记缺）：On 为关（S2A_GS_DIAG=1 也不认）");
            S2AGsDiag.NotePassthrough("ShaderCache");
            S2AGsDiag.OccBegin();
            S2AGsDiag.NoteAtomic("ssbo", -1, 0x1000, 0x100);
            S2AGsDiag.Submit(0);
            S2AGsDiag.DumpLost();   // 门关时回放也一行不打
            Ck(lines.Count == 0, $"玩家包形态：一行不写（实 {lines.Count} 行）");
            Ck(S2AGsDiag.s_envProbes == 0, $"玩家包形态：诊断 env 一次没读（实 {S2AGsDiag.s_envProbes} 次）");

            // ② 标记在、诊断 env 缺：env 恰好读一次、仍不写
            S2AGsDiag.S2ATestReset();
            Environment.SetEnvironmentVariable("S2A_DEBUG_ENTRIES", "1");
            Environment.SetEnvironmentVariable("S2A_GS_DIAG", null);
            S2AGsDiag.s_emit = lines.Add;
            Ck(!S2AGsDiag.On, "标记在 env 缺：On 为关");
            Ck(S2AGsDiag.s_envProbes == 1, $"标记在后诊断 env 恰好读一次（实 {S2AGsDiag.s_envProbes} 次）");
            S2AGsDiag.Submit(0);
            Ck(lines.Count == 0, "标记在 env 缺：零输出");

            // ③ 标记在、诊断 env=1：三类全落盘
            S2AGsDiag.S2ATestReset();
            Environment.SetEnvironmentVariable("S2A_DEBUG_ENTRIES", "1");
            Environment.SetEnvironmentVariable("S2A_GS_DIAG", "1");
            S2AGsDiag.s_emit = lines.Add;
            Ck(S2AGsDiag.On, "标记在 env=1：On 开");

            S2AGsDiag.NotePassthrough("ShaderCache");
            Ck(lines.Count == 1 && lines[0].Contains("来源=ShaderCache") && lines[0].Contains("遮挡查询在飞=关"),
                $"追加登记：来源+遮挡态落行（实：{(lines.Count == 1 ? lines[0] : $"{lines.Count} 行")}）");

            S2AGsDiag.OccBegin();
            S2AGsDiag.OccBegin();
            S2AGsDiag.OccEnd();
            S2AGsDiag.NoteAtomic("ssbo", -1, 0x0, 0x100);     // 漏填的 0x0 原值要看得见
            S2AGsDiag.NoteAtomic("img", 2, 0x4000, 0x800);
            lines.Clear();
            S2AGsDiag.Submit(3);
            Ck(lines.Count == 1, $"提交落一行（实 {lines.Count}）");
            string submit = lines.Count == 1 ? lines[0] : "";
            Ck(submit.Contains("ssbo:0x0+0x100"), "提交行含 SSBO 原值 0x0（漏填证据不打折）");
            Ck(submit.Contains("img-s2:0x4000+0x800"), "提交行含可写镜像客体 VA + 阶段号");
            Ck(submit.Contains("遮挡查询在飞=开×1"), "提交行含遮挡在飞计数（2 复位 1 报告=1）");
            Ck(submit.Contains("直通几何追加=ShaderCache×1"), "提交行含追加点累计");

            lines.Clear();
            S2AGsDiag.Submit(4);
            Ck(lines.Count == 1 && lines[0].Contains("原子面=0"),
                $"下一次提交原子面归零（缓冲只留上次提交以来的；实：{(lines.Count == 1 ? lines[0] : $"{lines.Count} 行")}）");

            // ③b 崩前回放：DumpLost 把最近 ≤8 次提交行重打一遍（10 次提交只留后 8），答「崩前 atomic 有没有 0」
            lines.Clear();
            for (int i = 0; i < 10; i++)
            {
                S2AGsDiag.Submit(i);
            }

            lines.Clear();
            S2AGsDiag.DumpLost();
            Ck(lines.Count == 9 && lines[0].Contains("崩前回放") && lines[0].Contains("最近 8 次"),
                $"崩前回放：头行 + 8 条提交（实 {lines.Count} 行：{(lines.Count > 0 ? lines[0] : "无")}）");
            Ck(lines.Count == 9 && lines[1].Contains("序5") && lines[8].Contains("序12"),
                "崩前回放：环只留最近 8 条（序5…序12，序1-4 被挤出）");

            Environment.SetEnvironmentVariable("S2A_DEBUG_ENTRIES", null);
            Environment.SetEnvironmentVariable("S2A_GS_DIAG", null);
            S2AGsDiag.S2ATestReset();
            Console.WriteLine($"t_gsdiag：{_n} 项，失败 {_fail}");
            return _fail == 0 ? 0 : 1;
        }
    }
}
