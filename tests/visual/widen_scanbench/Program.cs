// widen_scanbench：宽屏包装层 CPU 回放基准（10-21 起：整份 WidenRenderer 套在空渲染器上回放录像，只算不画、不用 GPU）。
// 录像前 N 帧（含序章）读进内存，交替回放两遍：A = 空渲染器、B = 包装层 + 空渲染器；只计第 W 帧之后（跳过序章与预热），
// 按进程 CPU 时间（本机负载高、墙钟不可比）；包装层每帧 CPU = (B − A) ÷ 帧数，各遍取最小。
// 同一份源码可对旧代码编（没有 graphics/widen/CbufShadow.cs 时不编 --check），改前 / 改后用同一把尺子。
// --check（新代码）：另跑一遍挂影子对照（WidenOldModel：旧「上传即整段改写」模型），逐绘制比这次读到的字节，报漏改 / 多改。
// 用法：widen_scanbench <gal.rec> [--until N=300] [--warm W=60] [--passes P=3] [--widen 2.1727] [--game-wide] [--check]
using RyuJudge.GalRec;
using Ryujinx.Graphics.GAL;
using S2Arm.Gfx.Widen.Gal;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;

static unsafe class P
{
    const uint OpPresent = 0x201;

    static string Opt(string[] a, string k) { int i = Array.IndexOf(a, k); return i >= 0 && i + 1 < a.Length ? a[i + 1] : null; }

    static int Main(string[] a)
    {
        if (a.Length < 1) { Console.Error.WriteLine("用法：widen_scanbench <gal.rec> [--until N] [--warm W] [--passes P] [--widen 宽高比] [--game-wide] [--check]"); return 2; }
        int until = int.Parse(Opt(a, "--until") ?? "300"), warm = int.Parse(Opt(a, "--warm") ?? "60"), passes = int.Parse(Opt(a, "--passes") ?? "3");
        float aspect = float.Parse(Opt(a, "--widen") ?? "2.1727");
        bool gameWide = a.Contains("--game-wide"), check = a.Contains("--check");
        using GalRecFile f = GalRecFile.Load(a[0]);
        // 读进内存：前 until 次上屏为止的全部记录
        var recs = new List<(uint Op, long Off, int Len)>(); long total = 0; int frames = 0;
        foreach (GalRecRecord r in f.Records())
        {
            recs.Add((r.Op, total, r.Length)); total += r.Length;
            if (r.Op == OpPresent && ++frames >= until) break;
        }
        byte* mem = (byte*)NativeMemory.Alloc((nuint)Math.Max(total, 1));
        { int i = 0; foreach (GalRecRecord r in f.Records()) { if (i >= recs.Count) break; f.Payload(r).CopyTo(new Span<byte>(mem + recs[i].Off, r.Length)); i++; } }
        Console.WriteLine($"录像 {a[0]}：读进 {recs.Count} 条记录 {total / 1048576.0:F0} MB（{frames} 帧），计时第 {warm + 1}..{frames} 帧；k 宽高比 {aspect}{(gameWide ? "，游戏自己出宽图（gameWide）" : "")}");

        double Run(bool wrap, out WidenRenderer wr, object chk = null, List<int> bands = null)
        {
            var nul = new NullRenderer(f.Capabilities);
            wr = wrap ? new WidenRenderer(nul, aspect, gameWide) : null;
#if WIDEN_LAZY
            if (wr != null && chk is S2Arm.Gfx.Widen.IWidenCheck c) wr.State.Check = c;
#endif
            var pn = new GalRecReplayer((IRenderer)wr ?? nul);
            var me = Process.GetCurrentProcess();
            TimeSpan t0 = default; int pres = 0; long errs = 0;
            foreach (var (op, off, len) in recs)
            {
                if (op < 0xFF00)
                {
                    var rr = new R(new ReadOnlySpan<byte>(mem + off, len));
                    try { pn.ReplayOne(op, ref rr); } catch (Exception e) { if (errs++ < 3) Console.Error.WriteLine($"回放错误：{e.GetType().Name} {e.Message}"); }
                }
                else { var rr = new R(new ReadOnlySpan<byte>(mem + off, len)); pn.ReplayOne(op, ref rr); }
                if (op == OpPresent) bands?.Add(wr?.LastPillar ?? -1);
                if (op == OpPresent && ++pres == warm) { me.Refresh(); t0 = me.TotalProcessorTime; }
            }
            me.Refresh();
            if (errs > 0) Console.WriteLine($"  回放错误 {errs} 条");
            return (me.TotalProcessorTime - t0).TotalMilliseconds;
        }

        // --bands：只回放一遍包装层，逐帧打上屏告诉出图层的种类（0 照常判 / 1 原比例页 / 2 两侧是放宽内容画的），不计时
        if (a.Contains("--bands"))
        {
            var ks = new List<int>(); Run(true, out _, null, ks);
            Console.WriteLine($"上屏两侧种类（逐帧，第 1 帧起）：{string.Join(" ", ks)}");
            NativeMemory.Free(mem);
            return 0;
        }
        var tA = new List<double>(); var tB = new List<double>(); WidenRenderer last = null;
        for (int p = 0; p < passes; p++)
        {
            tA.Add(Run(false, out _));
            tB.Add(Run(true, out last));
            GC.Collect();
        }
        int n = Math.Max(1, frames - warm);
        double a0 = tA.Min(), b0 = tB.Min();
        Console.WriteLine($"空渲染器 {string.Join(" / ", tA.Select(x => x.ToString("F0")))} ms；包装层 + 空渲染器 {string.Join(" / ", tB.Select(x => x.ToString("F0")))} ms（{passes} 遍）");
        Console.WriteLine($"包装层每帧 CPU {(b0 - a0) / n:F3} ms（各取最小：{b0:F0} − {a0:F0} ms，{n} 帧）");
        Console.WriteLine(last.Report());
#if WIDEN_LAZY
        if (check)
        {
            var m = new WidenOldModel(aspect);
            Run(true, out WidenRenderer wc, m);
            Console.WriteLine(m.Summary());
            foreach (string s in m.Samples) Console.WriteLine("  " + s);
            Console.WriteLine($"影子对照判据：期望 漏改矩阵 0 → 真结果 {m.MissMatrix}（浮点条目漏改 {m.Miss - m.MissMatrix}），{(m.MissMatrix == 0 ? "绿" : "红")}");
            NativeMemory.Free(mem);
            return m.MissMatrix == 0 ? 0 : 1;
        }
#else
        if (check) Console.WriteLine("（旧代码没有影子对照，--check 跳过）");
#endif
        NativeMemory.Free(mem);
        return 0;
    }
}
