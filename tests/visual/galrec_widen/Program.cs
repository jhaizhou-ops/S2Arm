// galrec_widen：在 GAL 录像上跑通用宽屏的识别与判定（只算不画），回答三件事：
//   ① 放宽了哪些贴图、改写了哪些常量（逐个列出唯一矩阵值，人工 / 规则核对是不是真相机矩阵）；
//   ② 画到放宽目标的绘制里，有多少「用到了被改写的矩阵」（= Hor+ 生效）、多少没有（= 会被横向拉伸）；界面层判定数；
//   ③ 误改风险：被改写的常量区间被「画到非放宽目标」的绘制用到的次数（这些绘制会被错误压窄），期望 0。
// 用法：galrec_widen <gal.rec> [目标宽高比，缺省 2868/1320] [明细输出目录]
using RyuJudge.GalRec;
using Ryujinx.Graphics.GAL;
using S2Arm.Gfx.Widen;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;

static class P
{
    const uint OpCreateTexture = 0x108, OpCreateTextureScaled = 0x2F0, OpCreateProgram = 0x106, OpSetBufferData = 0x112, OpDeleteBuffer = 0x10C;
    const uint OpSetRenderTargets = 0x029, OpSetProgram = 0x026, OpSetUniformBuffers = 0x031, OpSetTextureAndSampler = 0x02D, OpPresent = 0x201;
    const uint OpDraw = 0x009, OpDrawIndexed = 0x00A, OpDrawIndexedIndirect = 0x00B, OpDrawIndexedIndirectCount = 0x00C, OpDrawIndirect = 0x00D, OpDrawIndirectCount = 0x00E;
    const uint OpTexCreateView = 0x304, OpTexRelease = 0x30B;

    sealed class HitInfo { public WidenKind Kind; public bool Col; public float[] M; public long UsedWide, UsedNotWide, UsedNotWideDyn; public HashSet<uint> Progs = new(); public Dictionary<string, long> NotWideTargets = new(); }

    static int Main(string[] a)
    {
        if (a.Length < 1) { Console.Error.WriteLine("用法：galrec_widen <gal.rec> [宽高比] [明细目录]"); return 2; }
        float aspect = a.Length > 1 ? float.Parse(a[1]) : 2868f / 1320f;
        string outDir = a.Length > 2 ? a[2] : null;
        using GalRecFile f = GalRecFile.Load(a[0]);
        CheckOps(f);
        var rw = new WidenRewriter(aspect); var fr = new WidenFrame(rw); var sink = new Sink(); fr.Observer = sink;
        var shadow = new Dictionary<ulong, byte[]>(); var reads = new List<CbufRead>(); var progUbo = new Dictionary<uint, List<CbufUse>>(); var progW1 = new Dictionary<uint, bool>(); var progFragCoord = new HashSet<uint>(); var fcSeen = new HashSet<string>(); var stretchProgs = new Dictionary<uint, long>(); long dynUses = 0, allUses = 0; uint prog = 0;
        var ubo = new Dictionary<int, (ulong Buf, int Off, int Size)>();
        var live = new Dictionary<(ulong, int), HitInfo>();          // 当前有效的改写：(缓冲, 缓冲内偏移) → 值
        var uniq = new Dictionary<string, HitInfo>();
        byte[] dst = new byte[1 << 20];
        var hudProgs = new Dictionary<uint, long>(); var hudCenterProgs = new Dictionary<uint, long>();
        var uncoveredProgs = new Dictionary<uint, long>();
        long badUse = 0, wideCreated = 0, wideRead = 0, wideWrite = 0, wideWriteProlog = 0; bool inPrologue = false;
        var wideSizes = new SortedSet<string>(); var texSize = new Dictionary<uint, string>(); var texScale = new Dictionary<uint, float>(); uint curRt = 0, curDs = 0;
        foreach (GalRecRecord rec in f.Records())
        {
            uint op = rec.Op;
            if (op == 0xFF01) inPrologue = true; else if (op == 0xFF02) inPrologue = false;
            if (op >= 0xFF00) continue;
            var r = new R(f.Payload(rec));
            switch (op)
            {
                case OpCreateTexture:
                case OpCreateTextureScaled:
                {
                    var ci = r.Blit<TextureCreateInfo>();
                    float scale = op == OpCreateTextureScaled ? r.F32() : 1f;
                    uint id = r.U32(); texSize[id] = $"{ci.Width}x{ci.Height}:{ci.Format}"; texScale[id] = scale;
                    if (fr.OnCreateTexture(id, ci.Width, ci.Height, scale) != ci.Width) { wideCreated++; wideSizes.Add($"{ci.Width}x{ci.Height}"); }
                    break;
                }
                case OpTexCreateView:
                {
                    uint parent = r.U32(); var ci = r.Blit<TextureCreateInfo>(); r.I32(); r.I32(); uint id = r.U32(); texSize[id] = $"{ci.Width}x{ci.Height}:{ci.Format}";
                    float scale = texScale[parent]; texScale[id] = scale;
                    if (fr.OnCreateTexture(id, ci.Width, ci.Height, scale) != ci.Width) { wideCreated++; wideSizes.Add($"{ci.Width}x{ci.Height}"); }
                    break;
                }
                case OpTexRelease: { uint id = r.U32(); fr.OnReleaseTexture(id); texScale.Remove(id); break; }
                case 0x305: case 0x306: case 0x303: { uint t = r.U32(); if (fr.IsWide(t)) wideRead++; break; }
                case 0x307: case 0x308: case 0x309: { uint t = r.U32(); if (fr.IsWide(t)) { if (inPrologue) wideWriteProlog++; else wideWrite++; } break; }
                case OpCreateProgram:
                {
                    var shs = r.Shaders(); ShaderInfo si = r.ShaderInfo(); uint id = r.U32();
                    if (Environment.GetEnvironmentVariable("GW_DUMP_PROG") is string dp && (dp == "all" || dp.Split(',').Contains(id.ToString())) && outDir != null)
                        foreach (var sh in shs) if (sh.BinaryCode != null) { Directory.CreateDirectory(outDir); File.WriteAllBytes(Path.Combine(outDir, $"prog_{id}_{sh.Stage}.spv"), sh.BinaryCode); }
                    var b = new List<CbufUse>();
                    foreach (var sh in shs) if (sh.BinaryCode != null && SpirvCbufUse.Analyze(sh.BinaryCode) is { } us) foreach (var u in us) { b.Add(u); allUses++; if (u.Dynamic) dynUses++; }
                    progUbo[id] = b;
                    if (shs.Any(sh => sh.Stage == Ryujinx.Graphics.Shader.ShaderStage.Fragment && sh.BinaryCode != null && HasFragCoord(sh.BinaryCode))) progFragCoord.Add(id);
                    progW1[id] = shs.Any(sh => sh.Stage == Ryujinx.Graphics.Shader.ShaderStage.Vertex && sh.BinaryCode != null && SpirvCbufUse.PositionWIsOne(sh.BinaryCode));
                    break;
                }
                case OpSetProgram: prog = r.U32(); break;
                case OpSetUniformBuffers:
                    foreach (var x in r.Span<BufferAssignment>()) ubo[x.Binding] = (Unsafe(x.Range.Handle), x.Range.Offset, x.Range.Size);
                    break;
                case OpSetTextureAndSampler:
                {
                    int stage = r.I32(), bind = r.I32(); uint tex = r.U32();
                    if (stage == (int)Ryujinx.Graphics.Shader.ShaderStage.Fragment) fr.OnFragmentTexture(bind, tex);
                    break;
                }
                case OpSetRenderTargets:
                {
                    uint n = r.U32(); uint c0 = 0; for (int i = 0; i < n; i++) { uint t = r.U32(); if (i == 0) c0 = t; }
                    curRt = c0; curDs = r.U32(); fr.OnRenderTargets(c0, curDs);
                    break;
                }
                case OpSetBufferData:
                {
                    ulong buf = r.U64(); int off = r.I32(); byte[] data = r.Bytes();
                    if (data == null) break;
                    { if (!shadow.TryGetValue(buf, out var sb) || sb.Length < off + data.Length) { var nb = new byte[Math.Max(off + data.Length, (sb?.Length ?? 0))]; sb?.CopyTo(nb, 0); shadow[buf] = sb = nb; } data.CopyTo(sb, off); }
                    if (dst.Length < data.Length) dst = new byte[data.Length * 2];
                    foreach (var k in live.Keys.Where(k => k.Item1 == buf && k.Item2 < off + data.Length && off < k.Item2 + 64).ToList()) live.Remove(k);
                    sink.Clear();
                    if (fr.OnBufferData(buf, off, data, dst))
                        foreach (var h in sink.Hits)
                        {
                            float[] m = MemoryMarshal.Cast<byte, float>(data.AsSpan(h.Off - off, h.Len)).ToArray();
                            string key = h.Kind + ":" + string.Join(",", m.Select(v => v.ToString("G6")));
                            if (!uniq.TryGetValue(key, out var hi)) uniq[key] = hi = new HitInfo { Kind = h.Kind, Col = h.Col, M = m };
                            live[(buf, h.Off)] = hi;
                        }
                    break;
                }
                case OpDeleteBuffer: { ulong buf = r.U64(); fr.OnDeleteBuffer(buf); foreach (var k in live.Keys.Where(k => k.Item1 == buf).ToList()) live.Remove(k); break; }
                case OpDraw: case OpDrawIndexed: case OpDrawIndexedIndirect: case OpDrawIndexedIndirectCount: case OpDrawIndirect: case OpDrawIndirectCount:
                {
                    var used = new List<HitInfo>(); var dynHit = new HashSet<HitInfo>(); reads.Clear();
                    List<CbufUse> bs = progUbo.TryGetValue(prog, out var bl) ? bl : null;
                    if (bs != null)
                        foreach (CbufUse cu in bs)
                            if (ubo.TryGetValue(cu.Binding, out var u) && u.Size > 0)
                            {
                                reads.Add(new CbufRead(u.Buf, u.Off, u.Size, cu));
                                foreach (var kv in live) if (kv.Key.Item1 == u.Buf && cu.Reads(u.Off, u.Size, kv.Key.Item2, kv.Key.Item2 + 64)) { used.Add(kv.Value); if (cu.Dynamic) dynHit.Add(kv.Value); }
                            }
                    long cov0 = fr.DrawsCovered;
                    var mode = fr.OnDraw(System.Runtime.InteropServices.CollectionsMarshal.AsSpan(reads), null, out DrawClass cls);
                    bool cov = fr.DrawsCovered != cov0;
                    if (cls == DrawClass.Hud && Environment.GetEnvironmentVariable("GW_HUDTEX") == fr.Frames.ToString())
                        Console.WriteLine($"[界面贴图] 程序 {prog} 采样 " + string.Join(" ", fr.LastDrawTextures.ToArray().Select((t, i) => (t, i)).Where(x => x.t != 0).Select(x => $"{x.i}:{x.t}={(texSize.TryGetValue(x.t, out var ts3) ? ts3 : "?")}{(fr.IsWide(x.t) ? "*" : "")}")));
                    if (cls == DrawClass.Hud && fr.Frames == 10 && Environment.GetEnvironmentVariable("GW_DEBUG") == "1" && bs != null)
                        Console.WriteLine($"[界面] 程序 {prog} 读 " + string.Join(" ", bs.Where(c => ubo.ContainsKey(c.Binding)).Select(c => $"{c.Binding}:{ubo[c.Binding].Buf}+{ubo[c.Binding].Off}/{ubo[c.Binding].Size}[{(c.Dynamic ? "动态" : string.Join(",", c.Indices.ToArray()))}]{(fr.ReadsRewritten(ubo[c.Binding].Buf, ubo[c.Binding].Off, ubo[c.Binding].Size, c) ? "*" : "")}")));
                    foreach (var hi in used) { if (cls == DrawClass.NotWide) { hi.UsedNotWide++; badUse++; if (dynHit.Contains(hi)) hi.UsedNotWideDyn++; string tk = $"程序{prog}→{(curRt != 0 && texSize.TryGetValue(curRt, out var ts) ? ts : "无颜色")}|{(curDs != 0 && texSize.TryGetValue(curDs, out var ds) ? ds : "无深度")}"; hi.NotWideTargets[tk] = hi.NotWideTargets.TryGetValue(tk, out long q) ? q + 1 : 1; } else hi.UsedWide++; hi.Progs.Add(prog); }
                    if (cls != DrawClass.NotWide && progFragCoord.Contains(prog) && Environment.GetEnvironmentVariable("GW_FRAGCOORD") == "1")
                        foreach (var rd in reads)
                        {
                            if (!shadow.TryGetValue(rd.Buffer, out var sb)) continue;
                            var idxs = rd.Use.Dynamic ? Enumerable.Range(0, Math.Min(rd.Size / 16, 64)) : rd.Use.Indices.ToArray().AsEnumerable();
                            foreach (int i in idxs)
                            {
                                if (rd.Offset + i * 16 + 16 > sb.Length || i * 16 >= rd.Size) continue;
                                var v = MemoryMarshal.Cast<byte, float>(sb.AsSpan(rd.Offset + i * 16, 16)).ToArray();
                                if (!v.Any(x => (x > 0.0001f && x < 0.01f) || x == 1920 || x == 1280 || x == 960)) continue;
                                string key = $"{prog}:{rd.Use.Binding}:{i}:{string.Join(",", v.Select(x => x.ToString("G5")))}";
                                if (fcSeen.Add(key)) Console.WriteLine($"[片元坐标] 帧 {fr.Frames} 程序 {prog} 目标 {(texSize.TryGetValue(curRt, out var tz2) ? tz2 : "?")} 绑定 {rd.Use.Binding} c{i}{(rd.Use.Dynamic ? "(动态)" : "")} = {string.Join(" ", v.Select(x => x.ToString("G5")))}");
                            }
                        }
                    if (cls == DrawClass.Hud) Inc(hudProgs, prog);
                    if (mode == ViewportMode.CenterNative) Inc(hudCenterProgs, prog);
                    if ((cls == DrawClass.Scene || cls == DrawClass.Hud) && !cov) { Inc(uncoveredProgs, prog); if (!(progW1.TryGetValue(prog, out bool w1) && w1) && !ReadsOrtho(reads, shadow)) { Inc(stretchProgs, prog); if (Environment.GetEnvironmentVariable("GW_DEBUG") == "1" && stretchProgs[prog] <= 2) { Console.WriteLine($"[拉伸] 帧 {fr.Frames} 程序 {prog} 类 {cls} 目标 {(texSize.TryGetValue(curRt, out var tz) ? tz : "?")} T_out {fr.OutTexture}"); foreach (var rd in reads) if (shadow.TryGetValue(rd.Buffer, out var sb) && rd.Use.Indices.Length > 0 && rd.Size <= 4096) Console.WriteLine($"   绑定 {rd.Use.Binding} {rd.Buffer}+{rd.Offset}/{rd.Size} 读 [{string.Join(",", rd.Use.Indices.ToArray().Take(12))}] c0..c3 = {string.Join(" ", MemoryMarshal.Cast<byte, float>(sb.AsSpan(rd.Offset, Math.Min(64, sb.Length - rd.Offset))).ToArray().Select(v => v.ToString("G5")))}"); } } }
                    break;
                }
                case OpPresent: { uint pt = r.U32(); if (fr.Frames < 4 && Environment.GetEnvironmentVariable("GW_DEBUG") == "1") Console.WriteLine($"[调试] 上屏 {pt}（放宽 {fr.IsWide(pt)}）上一绘制目标 {fr.LastDrawTarget} 程序 {prog} 采样 {string.Join(",", fr.LastDrawTextures.ToArray().Select((t, i) => (t, i)).Where(x => x.t != 0).Select(x => $"{x.i}:{x.t}"))}"); fr.OnPresent(pt); Console.Write(fr.Frames < 5 && Environment.GetEnvironmentVariable("GW_DEBUG") == "1" ? $"  → T_out {fr.OutTexture}\n" : ""); break; }
            }
        }
        long scene = fr.DrawsWide - fr.DrawsHud;
        Console.WriteLine($"录像 {a[0]}：{fr.Frames} 次上屏，绘制 {fr.Draws}，宽高比 {rw.Aspect:F4}（k {rw.K:F4}）");
        Console.WriteLine($"放宽贴图 {wideCreated} 个，尺寸 {string.Join(" ", wideSizes)}");
        Console.WriteLine($"常量 {rw.Stats}");
        Console.WriteLine($"放宽贴图的 CPU 读回（GetData / 拷到缓冲）{wideRead} 次、CPU 上传（SetData）{wideWrite} 次（另有录像序章补内容 {wideWriteProlog} 次，不是游戏行为）；尺寸对不上，包装层要报红或换算");
        Console.WriteLine($"唯一改写值 {uniq.Count} 个（投影 {uniq.Values.Count(h => h.Kind == WidenKind.Projection)} / 视图投影 {uniq.Values.Count(h => h.Kind == WidenKind.ViewProjection)} / 逆投影 {uniq.Values.Count(h => h.Kind == WidenKind.InverseProjection)} / 宽高比对 {uniq.Values.Count(h => h.Kind == WidenKind.AspectPair)} / 屏幕尺寸 {uniq.Values.Count(h => h.Kind == WidenKind.ScreenSize)}），其中从未被绘制用到的 {uniq.Values.Count(h => h.UsedWide + h.UsedNotWide == 0)}");
        Console.WriteLine($"画到放宽目标的绘制 {fr.DrawsWide}：用到改写矩阵 {fr.DrawsCovered}；界面层 {fr.DrawsHud}（其中按原宽居中 {fr.DrawsHudCentered}）；没读到改写矩阵 {uncoveredProgs.Values.Sum()}");
        Console.WriteLine($"非放宽目标读到改写区间 {badUse} 次（按着色器实际读的下标；常量绑定 {allUses} 个，其中动态下标 {dynUses} 个按整段算）→ 就地写回原值 {fr.Restores} 次、回到放宽目标再写改写值 {fr.Reapplies} 次（每帧 {(fr.Restores + fr.Reapplies) / (double)Math.Max(1, fr.Frames):F1} 次 ≤64 字节写入）");
        Console.WriteLine($"界面层程序：{Top(hudProgs)}；按原宽居中：{Top(hudCenterProgs)}");
        Console.WriteLine($"未覆盖程序（前 15）：{Top(uncoveredProgs, 15)}");
        Console.WriteLine($"会被拉伸的透视绘制（画到放宽目标、没读到改写矩阵、w 不恒为 1、也没读 2D 正交矩阵）{stretchProgs.Values.Sum()} 次：{Top(stretchProgs, 15)}");
        if (outDir != null)
        {
            Directory.CreateDirectory(outDir);
            using var w = new StreamWriter(Path.Combine(outDir, "rewrites.tsv"));
            w.WriteLine("种类\t列存\t画到放宽目标次数\t画到非放宽目标次数（其中动态下标）\t程序\t值\t非放宽目标明细");
            foreach (var h in uniq.Values.OrderBy(h => h.Kind).ThenByDescending(h => h.UsedWide))
                w.WriteLine($"{h.Kind}\t{(h.Col ? 1 : 0)}\t{h.UsedWide}\t{h.UsedNotWide}({h.UsedNotWideDyn})\t{string.Join(",", h.Progs.Take(12))}\t{string.Join(" ", h.M.Select(v => v.ToString("G5")))}\t{string.Join(" ", h.NotWideTargets.OrderByDescending(x => x.Value).Take(6).Select(x => $"{x.Key}×{x.Value}"))}");
            File.WriteAllLines(Path.Combine(outDir, "uncovered_progs.tsv"), uncoveredProgs.OrderByDescending(k => k.Value).Select(k => $"{k.Key}\t{k.Value}"));
        }
        return 0;
    }

    /// <summary>绘制读到的常量里有 2D 正交矩阵（行 0 = (a,0,0,b)、行 1 = (0,c,0,d)、行 3 = (0,0,0,1)，四行都被读）→ 按正交通道算，不算拉伸。只在录像核对里用。</summary>
    static bool ReadsOrtho(List<CbufRead> reads, Dictionary<ulong, byte[]> shadow)
    {
        foreach (var rd in reads)
        {
            if (!shadow.TryGetValue(rd.Buffer, out var sb)) continue;   // 常量下标读到了正交四行即可（同绑定另有动态读不影响）
            foreach (int i in rd.Use.Indices)
            {
                if (!rd.Use.Contains(i + 1) || !rd.Use.Contains(i + 3) || rd.Offset + (i + 4) * 16 > sb.Length) continue;
                var m = MemoryMarshal.Cast<byte, float>(sb.AsSpan(rd.Offset + i * 16, 64));
                bool z(float v) => MathF.Abs(v) < 1e-6f;
                if (m[0] != 0 && z(m[1]) && z(m[2]) && z(m[4]) && m[5] != 0 && z(m[6]) && z(m[12]) && z(m[13]) && z(m[14]) && MathF.Abs(m[15] - 1) < 1e-6f) return true;
            }
        }
        return false;
    }

    static bool HasFragCoord(byte[] spv)
    {
        var w = MemoryMarshal.Cast<byte, uint>(spv);
        for (int i = 5; i + 3 < w.Length;) { int n = (int)(w[i] >> 16); if (n == 0) break; if ((w[i] & 0xffff) == 71 && n == 4 && w[i + 2] == 11 && w[i + 3] == 15) return true; i += n; }
        return false;
    }

    static ulong Unsafe(BufferHandle h) => System.Runtime.CompilerServices.Unsafe.As<BufferHandle, ulong>(ref h);
    static void Inc(Dictionary<uint, long> d, uint k) => d[k] = d.TryGetValue(k, out long v) ? v + 1 : 1;
    static string Top(Dictionary<uint, long> d, int n = 10) => string.Join(" ", d.OrderByDescending(k => k.Value).Take(n).Select(k => $"{k.Key}×{k.Value}"));

    static void CheckOps(GalRecFile f)
    {
        var want = new Dictionary<uint, string> { [OpCreateTexture] = "IRenderer.CreateTexture", [OpCreateProgram] = "IRenderer.CreateProgram", [OpSetBufferData] = "IRenderer.SetBufferData",
            [OpSetRenderTargets] = "IPipeline.SetRenderTargets", [OpSetUniformBuffers] = "IPipeline.SetUniformBuffers", [OpPresent] = "IWindow.Present", [OpDrawIndexed] = "IPipeline.DrawIndexed" };
        foreach (var kv in want)
            if (!f.OpNames.TryGetValue(kv.Key, out string n) || !n.StartsWith(kv.Value)) throw new InvalidDataException($"录像操作码表不符：0x{kv.Key:X} 应为 {kv.Value}，实为 {n}");
    }

    sealed class Sink : IWidenHitSink { public void Hit(int off, int len, WidenKind kind, bool col) => Hits.Add((off, len, kind, col)); public readonly List<(int Off, int Len, WidenKind Kind, bool Col)> Hits = new(); public void Clear() => Hits.Clear(); }
}
