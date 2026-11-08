// galcount：只解析不回放，按 GAL 调用类型和参数取值计数。用法：galcount <录像.rec> [输出.tsv]
// 输出行：<键>\t<全部次数>\t<序幕内次数>。键 = 操作名 或 操作名|字段=取值。
using Ryujinx.Graphics.GAL;
using RyuJudge.GalRec;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;

static class P
{
    static readonly Dictionary<string, (long all, long pro)> C = new();
    static bool inPro;
    static void Add(string k) { C.TryGetValue(k, out var v); C[k] = (v.all + 1, v.pro + (inPro ? 1 : 0)); }

    static void Flat(string pre, object o, int depth = 0)
    {
        if (o == null) { Add(pre + "=null"); return; }
        Type t = o.GetType();
        if (t.IsPrimitive || t.IsEnum || depth >= 2 || t.Name.StartsWith("Array") || t == typeof(string)) { Add($"{pre}={o}"); return; }
        foreach (var p in t.GetProperties(BindingFlags.Public | BindingFlags.Instance))
        {
            if (p.GetIndexParameters().Length != 0 || p.Name == "EqualityContract") continue;
            object v; try { v = p.GetValue(o); } catch { continue; }
            Flat(pre + "." + p.Name, v, depth + 1);
        }
        foreach (var f in t.GetFields(BindingFlags.Public | BindingFlags.Instance)) Flat(pre + "." + f.Name, f.GetValue(o), depth + 1);
    }

    static int Main(string[] a)
    {
        using GalRecFile f = GalRecFile.Load(a[0]);
        long frames = 0, recs = 0;
        foreach (GalRecRecord r in f.Records())
        {
            recs++;
            uint op = r.Op;
            if (op == GalRecFormat.OpPrologueBegin) { inPro = true; continue; }
            if (op == GalRecFormat.OpPrologueEnd) { inPro = false; continue; }
            if (op == GalRecFormat.OpFrame) { frames++; continue; }
            string n = f.Name(op);
            int paren = n.IndexOf('('); string nm = n;
            Add(nm);
            if (r.Length == 0) continue;
            var span = f.Payload(r);
            R rr = new(span);
            try
            {
                switch (op)
                {
                    case GalOps.IPipeline_SetBlendState_2: rr.I32(); Flat(nm, rr.Blit<BlendDescriptor>()); break;
                    case GalOps.IPipeline_SetBlendState_1: Flat(nm, rr.Blit<AdvancedBlendDescriptor>()); break;
                    case GalOps.IPipeline_SetLogicOpState: { bool en = rr.Bool(); var lo = (LogicalOp)rr.I32(); Add($"{nm}|enable={en}"); if (en) Add($"{nm}|op={lo}"); break; }
                    case GalOps.IPipeline_SetPrimitiveTopology: Add($"{nm}|{(PrimitiveTopology)rr.I32()}"); break;
                    case GalOps.IPipeline_SetPolygonMode: Add($"{nm}|front={(PolygonMode)rr.I32()}|back={(PolygonMode)rr.I32()}"); break;
                    case GalOps.IPipeline_SetDepthTest: Flat(nm, rr.Blit<DepthTestDescriptor>()); break;
                    case GalOps.IPipeline_SetStencilTest: Flat(nm, rr.Blit<StencilTestDescriptor>()); break;
                    case GalOps.IPipeline_SetRasterizerDiscard: Add($"{nm}|{rr.Bool()}"); break;
                    case GalOps.IPipeline_SetFaceCulling: Add($"{nm}|enable={rr.Bool()}|face={(Face)rr.I32()}"); break;
                    case GalOps.IPipeline_SetFrontFace: Add($"{nm}|{(FrontFace)rr.I32()}"); break;
                    case GalOps.IPipeline_SetDepthMode: Add($"{nm}|{(DepthMode)rr.I32()}"); break;
                    case GalOps.IPipeline_SetDepthClamp: Add($"{nm}|{rr.Bool()}"); break;
                    case GalOps.IPipeline_SetDepthBias: Add($"{nm}|mask={(PolygonModeMask)rr.I32()}"); break;
                    case GalOps.IPipeline_SetAlphaTest: { bool en = rr.Bool(); rr.F32(); Add($"{nm}|enable={en}|op={(CompareOp)rr.I32()}"); break; }
                    case GalOps.IPipeline_SetPrimitiveRestart: Add($"{nm}|{rr.Bool()}"); break;
                    case GalOps.IPipeline_SetMultisampleState: Flat(nm, rr.Blit<MultisampleDescriptor>()); break;
                    case GalOps.IPipeline_SetPointParameters: { rr.F32(); Add($"{nm}|progSize={rr.Bool()}|spriteEn={rr.Bool()}|origin={(Origin)rr.I32()}"); break; }
                    case GalOps.IPipeline_SetLineParameters: { rr.F32(); Add($"{nm}|smooth={rr.Bool()}"); break; }
                    case GalOps.IPipeline_SetUserClipDistance: Add($"{nm}|idx={rr.I32()}|en={rr.Bool()}"); break;
                    case GalOps.IPipeline_SetIndexBuffer: rr.Blit<BufferRange>(); Add($"{nm}|{(IndexType)rr.I32()}"); break;
                    case GalOps.IPipeline_SetVertexAttribs: foreach (var d in rr.Span<VertexAttribDescriptor>()) { Add($"{nm}|attr.Format={d.Format}"); if (d.IsZero) Add($"{nm}|attr.IsZero"); } break;
                    case GalOps.IPipeline_SetRenderTargetColorMasks: foreach (var m in rr.Span<uint>()) Add($"{nm}|mask={m}"); break;
                    case GalOps.IPipeline_TryHostConditionalRendering_1: case GalOps.IPipeline_TryHostConditionalRendering_2: break;
                    case GalOps.IRenderer_CreateSampler: Flat(nm, rr.Blit<SamplerCreateInfo>()); break;
                    case GalOps.IRenderer_ReportCounter: Add($"{nm}|{(CounterType)rr.I32()}"); break;
                    case ObjOps.TexCreateView: rr.U32(); goto case GalOps.IRenderer_CreateTexture;
                    case GalOps.IRenderer_CreateTexture:
                    {
                        var t = rr.Blit<TextureCreateInfo>();
                        Add($"{nm}|Format={t.Format}"); Add($"{nm}|Target={t.Target}"); Add($"{nm}|Samples={t.Samples}");
                        Add($"{nm}|Swizzle={t.SwizzleR},{t.SwizzleG},{t.SwizzleB},{t.SwizzleA}"); Add($"{nm}|DepthStencilMode={t.DepthStencilMode}");
                        break;
                    }
                }
            }
            catch (Exception e) { Add($"{nm}|解码异常:{e.GetType().Name}"); }
        }
        var w = a.Length > 1 ? new StreamWriter(a[1]) : Console.Out;
        w.WriteLine($"# 录像 {a[0]}  记录 {recs}  帧 {frames}  截断={(f.Truncation ?? "无")}");
        foreach (var kv in C.OrderBy(k => k.Key, StringComparer.Ordinal)) w.WriteLine($"{kv.Key}\t{kv.Value.all}\t{kv.Value.pro}");
        w.Flush();
        return 0;
    }
}
