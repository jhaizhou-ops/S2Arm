// 参照端吃原始位顶点输入的单测（galplay --selftest-vraw <目录> [--anti-all]；tests/visual/gate.sh 调）：期望值按 Maxwell 寄存器位手算，不跑被测实现推期望。
// 着色器 = graphics/metal/tests/t_vraw_{vs,fs}.spvasm（与我方后端单测 t_draw 同一对；位置 0 整向量读、位置 1 按分量经访问链读，片元把位置 1 的位写进 RGBA32Uint）。
// 每种格式：① 按格式类改写（RefRawVertex.Rewrite）→ spirv-val 过 → 参照端（Vulkan@MoltenVK）画 3 顶点覆盖 4×4，读回 (0,0) 逐位比期望；
//   ② 反证：同一格式不改写直接画（子进程 --selftest-vraw-anti 里画：10-21 实测 uvec4 配浮点格式时 MoltenVK 建管线失败、绑空管线 SIGSEGV），
//      期望参照端画错或报错（子进程非 0 退出也算）；缺省只反证 unorm 与 sint 两格（每格崩一次留一份崩溃报告），--anti-all 全反证。
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Linq;

static class RefRawVertexTest
{
    static int _n, _fail;
    static void Ck(bool ok, string what) { _n++; if (!ok) _fail++; Console.WriteLine($"{(ok ? "✓" : "✗")} {what}"); }

    // （名字、录像里的格式、8 字节数据、期望寄存器位）——同 graphics/metal/tests/t_draw.m「原始位顶点输入」段
    static (string n, Format f, byte[] b, uint[] e)[] Cases()
    {
        const uint F1 = 0x3f800000u, FM1 = 0xbf800000u;
        return new (string n, Format f, byte[] b, uint[] e)[]
        {
            ("R8G8B8A8Unorm（unorm 类）", Format.R8G8B8A8Unorm, new byte[] { 0, 255, 0, 255 }, new[] { 0u, F1, 0u, F1 }),
            ("R8G8Snorm（snorm，缺分量 0, 1.0f）", Format.R8G8Snorm, new byte[] { 0x7f, 0x81 }, new[] { F1, FM1, 0u, F1 }),
            ("R16G16B16A16Float（浮点类）", Format.R16G16B16A16Float, new byte[] { 0x00, 0x3c, 0x00, 0xc0, 0x00, 0x38, 0, 0 }, new[] { F1, 0xc0000000u, 0x3f000000u, 0u }),
            ("R10G10B10A2Unorm（打包 unorm）", Format.R10G10B10A2Unorm, new byte[] { 0xff, 0x03, 0x00, 0xc0 }, new[] { F1, 0u, 0u, F1 }),
            ("R16G16Sint（sint，缺分量 0, 1）", Format.R16G16Sint, new byte[] { 0xfe, 0xff, 5, 0 }, new[] { 0xfffffffeu, 5u, 0u, 1u }),
            ("R8G8B8A8Uint（uint）", Format.R8G8B8A8Uint, new byte[] { 1, 2, 3, 4 }, new[] { 1u, 2u, 3u, 4u }),
            ("R8G8B8A8Uscaled（缩放 → 浮点位）", Format.R8G8B8A8Uscaled, new byte[] { 1, 2, 3, 200 }, new[] { F1, 0x40000000u, 0x40400000u, 0x43480000u }),
        };
    }

    // 资源布局：着色器没有资源，但 Vulkan 后端按集号 0–3（常量 / 存储 / 贴图 / 图像）取集，给 4 个空集
    static ResourceLayout Layout()
    {
        var sets = Enumerable.Range(0, 4).Select(_ => new ResourceDescriptorCollection(new ReadOnlyCollection<ResourceDescriptor>(new List<ResourceDescriptor>()))).ToList();
        var uses = Enumerable.Range(0, 4).Select(_ => new ResourceUsageCollection(new ReadOnlyCollection<ResourceUsage>(new List<ResourceUsage>()))).ToList();
        return new ResourceLayout(new ReadOnlyCollection<ResourceDescriptorCollection>(sets), new ReadOnlyCollection<ResourceUsageCollection>(uses));
    }

    sealed class Ctx { public IRenderer R; public ITexture Rt; public BufferHandle Pb; public ResourceLayout L; }
    static Ctx Setup()
    {
        var c = new Ctx { R = RefVk.RefVkRenderer.Create(), L = Layout() };
        c.Rt = c.R.CreateTexture(new TextureCreateInfo(4, 4, 1, 1, 1, 1, 1, 16, Format.R32G32B32A32Uint, DepthStencilMode.Depth, Target.Texture2D,
            SwizzleComponent.Red, SwizzleComponent.Green, SwizzleComponent.Blue, SwizzleComponent.Alpha));
        float[] tri = { -1, -1, 0, 3, -1, 0, -1, 3, 0 };
        var tb = new byte[36]; Buffer.BlockCopy(tri, 0, tb, 0, 36);
        c.Pb = c.R.CreateBuffer(36); c.R.SetBufferData(c.Pb, 0, tb);
        return c;
    }

    public static int Run(string dir, bool antiAll)
    {
        byte[] vs = File.ReadAllBytes(Path.Combine(dir, "vs.spv")), fs = File.ReadAllBytes(Path.Combine(dir, "fs.spv"));
        var cases = Cases();
        uint[] vw = RefRawVertex.Words(vs);
        Ck(RefRawVertex.RawMask(vw) == 0x3, $"原始位输入位置掩码期望 0x3（实得 {RefRawVertex.RawMask(vw):x}）");
        Ctx x = Setup();
        int antiDiff = 0, antiN = 0;
        for (int ci = 0; ci < cases.Length; ci++)
        {
            var c = cases[ci];
            int cls = RefRawVertex.ClassOf(c.f);
            uint[] nw = RefRawVertex.Rewrite(vw, l => l == 1 ? cls : RefRawVertex.Float, out string why);
            Ck(nw != null, $"{c.n}：改写{(nw == null ? "失败：" + why : "成功")}");
            if (nw == null) continue;
            uint wantMask = cls == RefRawVertex.Uint ? 0x2u : 0u;
            Ck(RefRawVertex.RawMask(nw) == wantMask, $"{c.n}：改写后仍带 s2a_raw 名的位置期望 {wantMask:x}（改回类型的换名 s2a_typ），实得 {RefRawVertex.RawMask(nw):x}");
            string val = SpirvVal(RefRawVertex.Bytes(nw));
            Ck(val == null || val == "", $"{c.n}：改写后 spirv-val {(val == null ? "不在本机（跳过）" : val == "" ? "通过" : "不过：" + val)}");
            uint[] got = Draw(x, RefRawVertex.Bytes(nw), fs, c.f, c.b, out string err);
            Ck(got != null && got.SequenceEqual(c.e), $"{c.n}：参照端改写后 期望 {Hex(c.e)} 实得 {(got == null ? "画不出：" + err : Hex(got))}");
            bool doAnti = antiAll || c.f == Format.R8G8B8A8Unorm || c.f == Format.R16G16Sint;
            if (!doAnti) continue;
            (int rc, string line) = Child(dir, ci);
            uint[] raw = line != null && line.StartsWith("位 ") ? line[2..].Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(h => Convert.ToUInt32(h, 16)).ToArray() : null;
            bool same = rc == 0 && raw != null && raw.SequenceEqual(c.e);
            Console.WriteLine($"  反证（不改写，子进程）：退出码 {rc}，{(raw != null ? "画出 " + Hex(raw) : line ?? "无输出")} → {(same ? "与期望相同" : "画错 / 报错")}");
            antiN++; antiDiff += same ? 0 : 1;
        }
        Ck(antiN > 0 && antiDiff == antiN, $"反证：不改写时 {antiN} 格里 {antiDiff} 格画错或报错（期望全部）");
        Console.WriteLine($"参照端原始位顶点输入单测：期望 全部符合 → 真结果 {_n - _fail} / {_n} 项符合{(_fail == 0 ? "" : "，红")}");
        Console.Out.Flush(); Environment.Exit(_fail == 0 ? 0 : 1);
        return _fail == 0 ? 0 : 1;
    }

    // 子进程：不改写直接画，打一行「位 …」或「画不出：…」
    public static int Anti(string dir, int ci)
    {
        byte[] vs = File.ReadAllBytes(Path.Combine(dir, "vs.spv")), fs = File.ReadAllBytes(Path.Combine(dir, "fs.spv"));
        var c = Cases()[ci];
        uint[] got = Draw(Setup(), vs, fs, c.f, c.b, out string err);
        Console.WriteLine(got != null ? "位 " + Hex(got) : "画不出：" + err);
        // 参照渲染器的后台线程不随 Main 返回结束：硬退出
        Console.Out.Flush(); Environment.Exit(0);
        return 0;
    }

    static (int, string) Child(string dir, int ci)
    {
        var psi = new ProcessStartInfo(Environment.ProcessPath, $"--selftest-vraw-anti \"{dir}\" {ci}") { RedirectStandardOutput = true, RedirectStandardError = true };
        using Process p = Process.Start(psi);
        var eo = p.StandardError.ReadToEndAsync();
        string o = p.StandardOutput.ReadToEnd();
        if (!p.WaitForExit(60000)) { p.Kill(); return (-1, "子进程 60 秒没结束"); }
        _ = eo.Result;
        return (p.ExitCode, o.Split('\n').LastOrDefault(l => l.StartsWith("位 ") || l.StartsWith("画不出")));
    }

    static string Hex(uint[] v) => string.Join(" ", v.Select(h => h.ToString("x8")));

    static uint[] Draw(Ctx x, byte[] vs, byte[] fs, Format f, byte[] data, out string err)
    {
        err = null;
        IRenderer r = x.R;
        try
        {
            Format af = RefRawVertex.Unscaled(f);
            var d = new byte[48]; for (int k = 0; k < 3; k++) Array.Copy(data, 0, d, 16 * k, data.Length);
            BufferHandle ab = r.CreateBuffer(48); r.SetBufferData(ab, 0, d);
            IProgram p = r.CreateProgram(new[] { new ShaderSource(vs, ShaderStage.Vertex, TargetLanguage.Spirv), new ShaderSource(fs, ShaderStage.Fragment, TargetLanguage.Spirv) },
                new ShaderInfo(0xf, x.L));
            if (p.CheckProgramLink(true) != ProgramLinkStatus.Success) { err = "程序链接失败"; return null; }
            IPipeline pl = r.Pipeline;
            pl.SetRenderTargets(new[] { x.Rt }, null);
            pl.SetRenderTargetColorMasks(new uint[] { 0xf });
            pl.SetViewports(new[] { new Viewport(new Rectangle<float>(0, 0, 4, 4), ViewportSwizzle.PositiveX, ViewportSwizzle.PositiveY, ViewportSwizzle.PositiveZ, ViewportSwizzle.PositiveW, 0, 1) });
            pl.SetScissors(new[] { new Rectangle<int>(0, 0, 4, 4) });
            pl.SetFaceCulling(false, Face.Back);
            pl.SetDepthTest(new DepthTestDescriptor(false, false, CompareOp.Always));
            pl.SetPrimitiveTopology(PrimitiveTopology.Triangles);
            pl.SetVertexBuffers(new[] { new VertexBufferDescriptor(new BufferRange(x.Pb, 0, 36), 12, 0), new VertexBufferDescriptor(new BufferRange(ab, 0, 48), 16, 0) });
            pl.SetVertexAttribs(new[] { new VertexAttribDescriptor(0, 0, false, Format.R32G32B32Float), new VertexAttribDescriptor(1, 0, false, af) });
            pl.ClearRenderTargetColor(0, 0, 1, 0xf, new ColorF(0, 0, 0, 0));
            pl.SetProgram(p);
            pl.Draw(3, 1, 0, 0);
            var o = new uint[4];
            using (var g = x.Rt.GetData()) { ReadOnlySpan<byte> s = g.Get(); for (int k = 0; k < 4; k++) o[k] = BitConverter.ToUInt32(s.Slice(4 * k, 4)); }
            p.Dispose(); r.DeleteBuffer(ab);
            return o;
        }
        catch (Exception e) { err = $"{e.GetType().Name}: {e.Message}"; return null; }
    }

    // spirv-val --target-env vulkan1.0：通过返回 ""，不过返回首行错误，本机没有 spirv-val 返回 null
    static string SpirvVal(byte[] b)
    {
        string t = Path.Combine(Path.GetTempPath(), $"vraw_{Environment.ProcessId}_{Guid.NewGuid():N}.spv"); File.WriteAllBytes(t, b);
        try
        {
            var psi = new ProcessStartInfo("spirv-val", $"--target-env vulkan1.0 \"{t}\"") { RedirectStandardError = true, RedirectStandardOutput = true };
            using Process pr = Process.Start(psi); string e = pr.StandardError.ReadToEnd() + pr.StandardOutput.ReadToEnd(); pr.WaitForExit();
            return pr.ExitCode == 0 ? "" : e.Split('\n').FirstOrDefault(l => l.Length > 0) ?? $"rc={pr.ExitCode}";
        }
        catch (System.ComponentModel.Win32Exception) { return null; }
        finally { File.Delete(t); }
    }
}
