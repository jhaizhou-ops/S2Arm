// shbake 命令行：bake（全量翻译，见 ShaderBake.BakeCmd）/ dump（读 Ryujinx 磁盘缓存，每个程序一行）/ guest-new（候选缓存里新的客体代码组合数）
using System;
namespace S2A.ShBake
{
    static class Program
    {
        static int Main(string[] a)
        {
            if (a.Length > 0 && a[0] == "compute-smoke") return ComputeBake.Run(a[1..]);
            if (a.Length >= 3 && a[0] == "bake") return ShaderBake.BakeCmd(a[1..]);
            if (a.Length == 3 && a[0] == "dump") return ShaderBake.DumpCmd(a[1], a[2]);
            if (a.Length >= 3 && a[0] == "guest-new" && a[1] == "--code") return ShaderBake.GuestNewCmd(a[2], a[3..], codeOnly: true);   // 只比客体代码（社区缓存对账：N / M / K 统一按代码）
            if (a.Length >= 2 && a[0] == "guest-new") return ShaderBake.GuestNewCmd(a[1], a[2..]);   // 收集器 shcollect.sh：候选缓存里有几个已有缓存都没有的客体代码组合
            if (a.Length == 1 && a[0] == "selftest-vtg") return VtgSelfTest.Run();   // 转计算程序进缓存的单测（tests/t_vtg.sh）
            if (a.Length == 1 && a[0] == "selftest-gsdiag") return GsDiagSelfTest.Run();   // #1456 单点诊断门序与写出（tests/t_gsdiag.sh）
            if (a.Length == 2 && a[0] == "fout-int-mask") { Console.WriteLine(FoutStatic.IntWrittenTargets(System.IO.File.ReadAllBytes(a[1]))); return 0; }   // 片元按整数位写的输出位置
            if (a.Length == 2 && a[0] == "fout-int-mask-list") { foreach (string f in System.IO.File.ReadAllLines(a[1])) Console.WriteLine($"{FoutStatic.IntWrittenTargets(System.IO.File.ReadAllBytes(f))}\t{f}"); return 0; }   // 同上，一行一个文件（tests/t_fout_rule.py 批量对拍）掩码（tests/t_fout_static.sh）
            if (a.Length is 1 or 2 or 3 && a[0] == "selftest-trlog") return TrLogSelfTest.Run(a.Length >= 2 ? a[1] : null, a.Length == 3 ? a[2] : null);   // 翻译告警分类计数单测（tests/t_trlog.sh；可给输出目录留端到端产物、给被测 S2A.ShBake 反证）
            if (a.Length == 1 && a[0] == "selftest-matwait") return MatWaitSelfTest.Run();   // 按需实化不等渲染线程的单测（tests/t_mat_wait.sh）
            if (a.Length is 1 or 2 && a[0] == "selftest-fout") return FoutSelfTest.Run(a.Length == 2 ? a[1] : null);   // 片元输出类型变体单测（tests/t_fout.sh；可给被测 S2A.ShBake，反证用旧版）
            Console.Error.WriteLine("用法：S2A.ShBake bake <抽出目录> <输出根> --title <程序号> [--ref <缓存目录>]… [-j N] [--xc <gal_xc> [--plat ios|macos]]\n      S2A.ShBake bake <抽出目录> <输出根> --title <程序号> --vulkan-profile <profile.json> --content-root <sha256-…> [--spirv-val <路径>]   Android VKPB 离线包\n      S2A.ShBake dump <缓存目录（含 shared.toc）> <输出目录>\n      S2A.ShBake guest-new [--code] <候选缓存目录> [<已有缓存目录>…]");
            return 2;
        }
    }
}
