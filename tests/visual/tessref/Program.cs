// tessref：曲面细分双后端对拍。每个用例（gen_cases.py：域 × 分区 × 因子 × 剔除）在两边各画一次到 256×256 RGBA8：
//   我方 NxRenderer（graphics/metal/gal_tess.m：计算核展开，D3D11 参照细分器）、参照 Ryujinx Vulkan 后端 @ MoltenVK（Metal 原生固定功能细分）。
// 一个四边形片铺满中间 3/4（或一个三角形片），颜色 = gl_TessCoord (u, v, w)。逐像素比：每字节差 ≤ 1 算一致（同 galplay），报差异像素占比与 PSNR、覆盖像素数，存 ours_/ref_/diff_ PNG。
// 用法：tessref <用例目录（含 cases.tsv）> <输出目录>。退出码 0 = 全部跑完（差异读数看报告，不在这里判阈值）、2 = 用法 / 建程序失败
using NxGal;
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;

static unsafe class P
{
    const int W = 256, H = 256;
    static int Main(string[] a)
    {
        Console.OutputEncoding = Encoding.UTF8;
        if (a.Length < 2) { Console.Error.WriteLine("用法：tessref <用例目录> <输出目录>"); return 2; }
        string dir = a[0], outDir = a[1]; Directory.CreateDirectory(outDir);
        var nx = new NxRenderer(); nx.Initialize(GraphicsDebugLevel.None);
        if (a.Length >= 5 && a[2] == "--bench") return Bench(nx, dir, a[3], int.Parse(a[4]), a.Length > 5 ? int.Parse(a[5]) : 64);
        IRenderer rf = RefVk.RefVkRenderer.Create();
        rf.Pipeline.SetDepthMode(DepthMode.ZeroToOne);
        var rep = new StringBuilder("用例\t我方覆盖\t参照覆盖\t差异像素占比\tPSNR_dB\n");
        int rc = 0;
        foreach (string line in File.ReadAllLines(Path.Combine(dir, "cases.tsv")))
        {
            string[] f = line.Split('\t'); string name = f[0]; int ncp = int.Parse(f[1]); int cull = int.Parse(f[2]);
            byte[] ours = Draw(nx, dir, name, ncp, cull, out string e1), refi = Draw(rf, dir, name, ncp, cull, out string e2);
            if (ours == null || refi == null) { Console.WriteLine($"{name}：建不出 我方 {e1} / 参照 {e2}"); rep.Append($"{name}\t失败\t失败\t-\t-\n"); rc = 2; continue; }
            int diff = 0, covO = 0, covR = 0; double se = 0; byte[] dimg = new byte[W * H * 4];
            for (int i = 0; i < W * H; i++)
            {
                bool d = false;
                for (int c = 0; c < 4; c++) { int x = ours[i * 4 + c] - refi[i * 4 + c]; se += x * x; d |= Math.Abs(x) > 1; }
                covO += ours[i * 4 + 3] == 255 ? 1 : 0; covR += refi[i * 4 + 3] == 255 ? 1 : 0;
                if (d) { diff++; dimg[i * 4] = 255; dimg[i * 4 + 3] = 255; } else { dimg[i * 4 + 1] = (byte)(ours[i * 4 + 3] / 4); dimg[i * 4 + 3] = 255; }
            }
            double mse = se / (W * H * 4), psnr = mse == 0 ? double.PositiveInfinity : 10 * Math.Log10(255.0 * 255.0 / mse);
            Png(Path.Combine(outDir, $"ours_{name}.png"), ours); Png(Path.Combine(outDir, $"ref_{name}.png"), refi); Png(Path.Combine(outDir, $"diff_{name}.png"), dimg);
            string row = $"{name}\t{covO}\t{covR}\t{100.0 * diff / (W * H):F3}%\t{(double.IsInfinity(psnr) ? "∞" : psnr.ToString("F1"))}";
            Console.WriteLine(row); rep.Append(row).Append('\n');
        }
        File.WriteAllText(Path.Combine(outDir, "report.tsv"), rep.ToString());
        Environment.Exit(rc);   // 参照渲染器的后台线程不退：直接结束进程
        return rc;
    }

    static byte[] Draw(IRenderer r, string dir, string name, int ncp, int cull, out string err)
    {
        err = null;
        ShaderSource S(string n, ShaderStage st) => new(File.ReadAllBytes(Path.Combine(dir, name, n + ".spv")), st, TargetLanguage.Spirv);
        var sets = Enumerable.Range(0, 4).Select(_ => new ResourceDescriptorCollection(new List<ResourceDescriptor>().AsReadOnly())).ToList().AsReadOnly();
        var uses = Enumerable.Range(0, 4).Select(_ => new ResourceUsageCollection(new List<ResourceUsage>().AsReadOnly())).ToList().AsReadOnly();
        IProgram prog = r.CreateProgram(new[] { S("vs", ShaderStage.Vertex), S("tcs", ShaderStage.TessellationControl), S("tes", ShaderStage.TessellationEvaluation), S("fs", ShaderStage.Fragment) },
                                        new ShaderInfo(0xf, new ResourceLayout(sets, uses)));
        if (prog.CheckProgramLink(true) != ProgramLinkStatus.Success) { err = "程序链接失败"; return null; }
        ITexture rt = r.CreateTexture(new TextureCreateInfo(W, H, 1, 1, 1, 1, 1, 4, Format.R8G8B8A8Unorm, DepthStencilMode.Depth, Target.Texture2D,
            SwizzleComponent.Red, SwizzleComponent.Green, SwizzleComponent.Blue, SwizzleComponent.Alpha));
        IPipeline p = r.Pipeline;
        p.SetRenderTargets(new[] { rt }, null);
        p.SetRenderTargetColorMasks(new uint[] { 0xf });
        p.SetScissors(new[] { new Rectangle<int>(0, 0, W, H) });
        p.ClearRenderTargetColor(0, 0, 1, 0xf, new ColorF(0, 0, 0, 0));
        p.SetViewports(new[] { new Viewport(new Rectangle<float>(0, 0, W, H), ViewportSwizzle.PositiveX, ViewportSwizzle.PositiveY, ViewportSwizzle.PositiveZ, ViewportSwizzle.PositiveW, 0, 1) });
        p.SetBlendState(0, new BlendDescriptor(false, default, BlendOp.Add, BlendFactor.One, BlendFactor.Zero, BlendOp.Add, BlendFactor.One, BlendFactor.Zero));
        p.SetDepthTest(new DepthTestDescriptor(false, false, CompareOp.Always));
        p.SetFaceCulling(cull != 0, cull == 2 ? Face.Front : Face.Back); p.SetFrontFace(FrontFace.CounterClockwise);   // cull：0 不剔 1 剔背面 2 剔正面
        p.SetProgram(prog);
        // 四边形片角序 (0,0)(1,0)(1,1)(0,1)（TES 双线性）；三角形片三角
        float[] v = ncp == 4 ? new float[] { -0.75f, -0.75f, 0, 0.75f, -0.75f, 0, 0.75f, 0.75f, 0, -0.75f, 0.75f, 0 } : new float[] { -0.8f, -0.8f, 0, 0.8f, -0.8f, 0, 0, 0.8f, 0 };
        BufferHandle b = r.CreateBuffer(v.Length * 4, BufferAccess.Default);
        r.SetBufferData(b, 0, System.Runtime.InteropServices.MemoryMarshal.AsBytes(v.AsSpan()));
        p.SetVertexBuffers(new[] { new VertexBufferDescriptor(new BufferRange(b, 0, v.Length * 4), 12, 0) });
        p.SetVertexAttribs(new[] { new VertexAttribDescriptor(0, 0, false, Format.R32G32B32Float) });
        p.SetPrimitiveTopology(PrimitiveTopology.Patches);
        p.SetPatchParameters(ncp, new float[] { 1, 1, 1, 1 }, new float[] { 1, 1 });
        p.Draw(ncp, 1, 0, 0);
        byte[] px; using (var g = rt.GetData(0, 0)) px = g.Get().ToArray();
        rt.Release(); r.DeleteBuffer(b); prog.Dispose();
        return px;
    }

    // --bench <用例> <每帧曲面绘制数> [每次绘制的曲面片数]：1920×1080 RGBA8 目标上，每帧（一次读回为界）画若干次曲面绘制，每次一网格曲面片；
    //   报我方 GPU 毫秒（nxgal_perf_read 已完成提交的 GPU 时间，含结束渲染通道的读入 / 存回）与每次曲面绘制的均摊、结束渲染通道次数（nxgal_tess_stats）。
    //   参照（MoltenVK 原生细分）同样跑一遍：GPU 时间经 nxgal_perf_hook_mtl3 记进同一计数
    [System.Runtime.InteropServices.DllImport("nxgal")] static extern int nxgal_perf_read(ulong* o, int n, int reset);
    [System.Runtime.InteropServices.DllImport("nxgal")] static extern void nxgal_tess_stats(ulong* o);
    [System.Runtime.InteropServices.DllImport("nxgal")] static extern int nxgal_perf_hook_mtl3();
    static unsafe int Bench(IRenderer nx, string dir, string name, int draws, int patches)
    {
        string[] f = File.ReadAllLines(Path.Combine(dir, "cases.tsv")).Select(l => l.Split('\t')).First(x => x[0] == name);
        int ncp = int.Parse(f[1]); int g = (int)Math.Ceiling(Math.Sqrt(patches));
        var rows = new List<string>();
        foreach (bool useRef in new[] { false, true })
        {
            IRenderer r = useRef ? RefVk.RefVkRenderer.Create() : nx;
            if (useRef) { nxgal_perf_hook_mtl3(); r.Pipeline.SetDepthMode(DepthMode.ZeroToOne); }
            var sets = Enumerable.Range(0, 4).Select(_ => new ResourceDescriptorCollection(new List<ResourceDescriptor>().AsReadOnly())).ToList().AsReadOnly();
            var uses = Enumerable.Range(0, 4).Select(_ => new ResourceUsageCollection(new List<ResourceUsage>().AsReadOnly())).ToList().AsReadOnly();
            ShaderSource S(string n, ShaderStage st) => new(File.ReadAllBytes(Path.Combine(dir, name, n + ".spv")), st, TargetLanguage.Spirv);
            IProgram prog = r.CreateProgram(new[] { S("vs", ShaderStage.Vertex), S("tcs", ShaderStage.TessellationControl), S("tes", ShaderStage.TessellationEvaluation), S("fs", ShaderStage.Fragment) }, new ShaderInfo(0xf, new ResourceLayout(sets, uses)));
            prog.CheckProgramLink(true);
            const int BW = 1920, BH = 1080;
            ITexture rt = r.CreateTexture(new TextureCreateInfo(BW, BH, 1, 1, 1, 1, 1, 4, Format.R8G8B8A8Unorm, DepthStencilMode.Depth, Target.Texture2D, SwizzleComponent.Red, SwizzleComponent.Green, SwizzleComponent.Blue, SwizzleComponent.Alpha));
            var v = new List<float>();
            for (int k = 0; k < patches; k++)
            {
                float x0 = -1 + 2f * (k % g) / g, y0 = -1 + 2f * (k / g) / g, s = 2f / g;
                if (ncp == 4) v.AddRange(new[] { x0, y0, 0, x0 + s, y0, 0, x0 + s, y0 + s, 0, x0, y0 + s, 0 }); else v.AddRange(new[] { x0, y0, 0, x0 + s, y0, 0, x0, y0 + s, 0 });
            }
            BufferHandle b = r.CreateBuffer(v.Count * 4, BufferAccess.Default); r.SetBufferData(b, 0, System.Runtime.InteropServices.MemoryMarshal.AsBytes(v.ToArray().AsSpan()));
            IPipeline p = r.Pipeline;
            double best = double.MaxValue; ulong splits = 0;
            for (int it = 0; it < 12; it++)
            {
                ulong* po = stackalloc ulong[128]; ulong* ts0 = stackalloc ulong[6], ts1 = stackalloc ulong[6];
                using (rt.GetData(0, 0)) { }
                nxgal_perf_read(po, 128, 1); nxgal_tess_stats(ts0);
                p.SetRenderTargets(new[] { rt }, null); p.SetRenderTargetColorMasks(new uint[] { 0xf }); p.SetScissors(new[] { new Rectangle<int>(0, 0, BW, BH) });
                p.ClearRenderTargetColor(0, 0, 1, 0xf, new ColorF(0, 0, 0, 0));
                p.SetViewports(new[] { new Viewport(new Rectangle<float>(0, 0, BW, BH), ViewportSwizzle.PositiveX, ViewportSwizzle.PositiveY, ViewportSwizzle.PositiveZ, ViewportSwizzle.PositiveW, 0, 1) });
                p.SetBlendState(0, new BlendDescriptor(false, default, BlendOp.Add, BlendFactor.One, BlendFactor.Zero, BlendOp.Add, BlendFactor.One, BlendFactor.Zero));
                p.SetDepthTest(new DepthTestDescriptor(false, false, CompareOp.Always)); p.SetFaceCulling(false, Face.Back);
                p.SetProgram(prog);
                p.SetVertexBuffers(new[] { new VertexBufferDescriptor(new BufferRange(b, 0, v.Count * 4), 12, 0) });
                p.SetVertexAttribs(new[] { new VertexAttribDescriptor(0, 0, false, Format.R32G32B32Float) });
                p.SetPrimitiveTopology(PrimitiveTopology.Patches); p.SetPatchParameters(ncp, new float[] { 1, 1, 1, 1 }, new float[] { 1, 1 });
                for (int d = 0; d < draws; d++) p.Draw(ncp * patches, 1, 0, 0);
                using (rt.GetData(0, 0)) { }
                System.Threading.Thread.Sleep(50);   // 完成回调异步记 GPU 时间
                int nseg = nxgal_perf_read(po, 128, 1); nxgal_tess_stats(ts1);
                double ms = po[2 * nseg] / 1e6; if (it >= 2 && ms < best) best = ms; splits = ts1[2] - ts0[2];
            }
            rows.Add($"{(useRef ? "参照 MoltenVK 原生细分" : "我方 计算展开")}	{name}	每帧 {draws} 次 × {patches} 片	GPU 最好 {best:F3} ms	每次绘制 {best / draws * 1000:F1} µs	本帧结束渲染通道 {(useRef ? "-" : splits.ToString())}");
        }
        foreach (string row in rows) Console.WriteLine(row);
        Environment.Exit(0); return 0;
    }

    static void Png(string path, byte[] rgba)
    {
        using var ms = new MemoryStream();
        void Chunk(string t, byte[] d) { var tb = Encoding.ASCII.GetBytes(t); WriteBE(ms, (uint)d.Length); ms.Write(tb); ms.Write(d); WriteBE(ms, Crc(tb.Concat(d).ToArray())); }
        ms.Write(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 });
        var ih = new byte[13]; BE(ih, 0, W); BE(ih, 4, H); ih[8] = 8; ih[9] = 6; Chunk("IHDR", ih);
        using var raw = new MemoryStream(); for (int y = 0; y < H; y++) { raw.WriteByte(0); raw.Write(rgba, y * W * 4, W * 4); }
        using var z = new MemoryStream(); using (var zs = new ZLibStream(z, CompressionLevel.Fastest, true)) raw.WriteTo(zs);
        Chunk("IDAT", z.ToArray()); Chunk("IEND", Array.Empty<byte>());
        File.WriteAllBytes(path, ms.ToArray());
    }
    static void BE(byte[] b, int o, int v) { b[o] = (byte)(v >> 24); b[o + 1] = (byte)(v >> 16); b[o + 2] = (byte)(v >> 8); b[o + 3] = (byte)v; }
    static void WriteBE(Stream s, uint v) { s.WriteByte((byte)(v >> 24)); s.WriteByte((byte)(v >> 16)); s.WriteByte((byte)(v >> 8)); s.WriteByte((byte)v); }
    static uint[] _crc;
    static uint Crc(byte[] d)
    {
        if (_crc == null) { _crc = new uint[256]; for (uint n = 0; n < 256; n++) { uint c = n; for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1; _crc[n] = c; } }
        uint x = 0xffffffffu; foreach (byte b in d) x = _crc[(x ^ b) & 0xff] ^ (x >> 8); return x ^ 0xffffffffu;
    }
}
