// 直连出库里**影响翻译产物**的那一段（11-02 总指挥 / 出包线：翻译缓存键的翻译器指纹 Xfp 只由 S2A.Dsh.csproj 的 DshXfpInput 算，本文件列在里面；
//   Build.cs 其余是编排——键表、缓存仓、逐键收尾、Metal 编译、汇总——不进指纹，改它们只让直连阶段热重跑，不让翻译缓存失效）。
//   放这里的判据：改了会让同一组输入翻出不同的 _b.metal / _b.json 等产物——包记录怎么切成控制段与代码区、交给 DshCompiler 的参数与开关、配对顶点读片元 MSL 的来源。
//   tests/xfp_single_source_test.sh 断言：本文件在指纹输入里、Build.cs 不在；改本文件指纹就变
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using S2A.Dsh;

static partial class Build
{
    // 每个包只读、只切一次：GetOrAdd 的工厂不保证只跑一次，键摘要 16 路并行首次碰到同一个包时各线程都整份读进来再各切一份（马力欧派对起步 1 秒内峰值约 10–15 GB，
    //   11-02 Air 16 GB 实测）；Lazy 按「执行并发布」只让一个线程加载，其余等它
    static List<byte[]> Records(string name) => Packs.GetOrAdd(name, n => new Lazy<List<byte[]>>(() =>
    {
        string path = Path.Combine(Pkg, n);
        // 包超过一个数组放得下的长度就流式切（逐字节同整读）；其余照旧整读
        return new FileInfo(path).Length > Array.MaxLength ? PkgRead.RecordsStream(path, 1 << 26) : PkgRead.Records(File.ReadAllBytes(path));
    }, LazyThreadSafetyMode.ExecutionAndPublication)).Value;   // 切法与出包 Vulkan 库工具共用（PkgRead.cs，同进指纹）

    // 翻译前的全局开关：配对顶点读片元 _b.metal 从产物表读（片元在第一波收尾时已写进 Side，配对顶点在第二波才翻）：不再在 PackMsl 里另留全文（同 Python 写进 BO 目录、用时读）
    static ISpvCross XlateSetup()
    {
        DshCompiler.PackOut = true; DshCompiler.PackMslKeep = new HashSet<string>(); DshCompiler.PackMslRead = MAC.Text;
        return new InprocSpvCross(A["--spvc"]);
    }

    // 一个键的翻译：包记录 → 控制段 / 代码区 → DshCompiler.Compile → 产物进 BOM 与缓存仓（键 = Digest，见 Build.cs ShaderKey）
    static void XlateOne(string key, string dir, ISpvCross xc)
    {
        var (pk, idx) = Loc[key]; var (code, ctl) = PkgRead.Split(Records(pk)[idx]);
        Dictionary<string, string> f;
        try
        {
            DshCompiler.Compile(key, pk[..2], code, ctl, dir, xc, Prof, Path.Combine(dir, ".work"));
            f = DshCompiler.PackFiles.ToDictionary(x => x.Key[16..], x => x.Value);
        }
        catch (DshError e) { XlSt[key] = (e.Status, e.Detail.Replace('\t', ' ').Replace('\n', ' ')); return; }
        catch (Exception e) { XlSt[key] = ("translation failed", (e.GetType().Name + ": " + e.Message.Split('\n')[0]).Replace('\t', ' ')); return; }
        BOM[key] = f; XlSt[key] = ("ok", "");
        // 写缓存仓不在上面的 try 里（同 Python 写仓 OSError 整份报红）：盘满 / 仓目录无权限原先被收成该键「translation failed」、整单退出 0 带洞出包（合入线 11-02 对照 #2）
        Store.Put("xl/" + Digest[key], f.ToDictionary(x => x.Key, x => U8.GetBytes(x.Value)));
    }
}
