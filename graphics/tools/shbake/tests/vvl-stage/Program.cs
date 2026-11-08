// VUID-03017/03023/07988：着色器资源阶段布局。
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Shader;
using Ryujinx.Graphics.Shader;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using ShaderStage = Ryujinx.Graphics.Shader.ShaderStage;

namespace S2A.VvlTest
{
    static class Program
    {
        static int _fail;

        static void Check(bool cond, string name, string expect, string actual)
        {
            if (!cond)
            {
                _fail++;
                Console.WriteLine($"FAIL {name}：期望 {expect} → 真结果 {actual}");
            }
        }

        // ---- ② VUID-03017/03023/07988：ShaderInfoBuilder 阶段位与实际占用 ----
        class Fake : DispatchProxy
        {
            protected override object Invoke(MethodInfo m, object[] a)
            {
                if (m.Name == nameof(IRenderer.GetCapabilities)) return Caps();
                return m.ReturnType.IsValueType && m.ReturnType != typeof(void) ? Activator.CreateInstance(m.ReturnType) : null;
            }
            public static IRenderer Renderer() => Create<IRenderer, Fake>();
        }

        static Capabilities Caps()
        {
            // 对齐 Vulkan 后端常量：set 序 0/1/2/3，每级 UBO 18 / SSBO 16 / TEX 64 / IMG 16。
            object caps = default(Capabilities);
            var t = typeof(Capabilities);
            t.GetField("Api").SetValue(caps, Ryujinx.Graphics.Shader.Translation.TargetApi.Vulkan);
            t.GetField("VendorName").SetValue(caps, "vvltest");
            t.GetField("SupportsTransformFeedback").SetValue(caps, true);
            t.GetField("SupportsGeometryShader").SetValue(caps, true);
            t.GetField("UniformBufferSetIndex").SetValue(caps, 0);
            t.GetField("StorageBufferSetIndex").SetValue(caps, 1);
            t.GetField("TextureSetIndex").SetValue(caps, 2);
            t.GetField("ImageSetIndex").SetValue(caps, 3);
            t.GetField("ExtraSetBaseIndex").SetValue(caps, 4);
            t.GetField("MaximumUniformBuffersPerStage").SetValue(caps, 18u);
            t.GetField("MaximumStorageBuffersPerStage").SetValue(caps, 16u);
            t.GetField("MaximumTexturesPerStage").SetValue(caps, 64u);
            t.GetField("MaximumImagesPerStage").SetValue(caps, 16u);
            return (Capabilities)caps;
        }

        // 着色器声明的 cbuffer 绑定（翻译后绑定号 = 预留 + stageIndex*18 + slot）。
        static BufferDescriptor[] Cbs(params int[] bindings)
        {
            var l = new List<BufferDescriptor>();
            foreach (int b in bindings) l.Add(new BufferDescriptor(0, b, 0));
            return l.ToArray();
        }

        static ShaderProgramInfo Info(ShaderStage stage, BufferDescriptor[] cbs)
        {
            return new ShaderProgramInfo(cbs, [], [], [], stage, 0, 0, 0, false, false, false, false, 0, -1);
        }

        static int StageUboCount(ResourceDescriptorCollection dc, ResourceStages stage)
        {
            return dc.Descriptors.Count(d => d.Type == ResourceType.UniformBuffer && d.Stages.HasFlag(stage));
        }

        static void TestStages()
        {
            // 复刻 12ba 形态：VS 用 cb{1,5,9}、GS 用 {37}、FS 用 {19,22}（绑定号 = stageIndex*18 + slot）。
            var ctx = new GpuContext(Fake.Renderer(), new Ryujinx.Common.Configuration.DirtyHacks(Array.Empty<ulong>()));
            ctx.Capabilities = Caps();

            var b = new ShaderInfoBuilder(ctx, tfEnabled: false);
            b.AddStageInfo(Info(ShaderStage.Vertex, Cbs(1, 5, 9)));
            b.AddStageInfo(Info(ShaderStage.Geometry, Cbs(37)));
            b.AddStageInfo(Info(ShaderStage.Fragment, Cbs(19, 22)));
            ShaderInfo info = b.Build(null);

            ResourceDescriptorCollection dc = info.ResourceLayout.Sets[0];

            // 07988：support_buffer（binding 0）必须对所有真实使用阶段可见 —— 含 Geometry 与 Tessellation。
            ResourceDescriptor sb = dc.Descriptors.Single(d => d.Binding == 0);
            Check(sb.Stages.HasFlag(ResourceStages.Geometry), "stages.gs.support",
                "binding0 含 Geometry", sb.Stages.ToString());
            Check(sb.Stages.HasFlag(ResourceStages.TessellationControl)
                && sb.Stages.HasFlag(ResourceStages.TessellationEvaluation), "stages.tess.support",
                "binding0 含 TC|TE", sb.Stages.ToString());
            Check(sb.Stages.HasFlag(ResourceStages.Vertex)
                && sb.Stages.HasFlag(ResourceStages.Fragment)
                && sb.Stages.HasFlag(ResourceStages.Compute), "stages.vfc.support",
                "binding0 含 V|F|C", sb.Stages.ToString());

            // 03017：每级 UBO 声明数 = 实际占用（+support），不是 18 全占、不是 ALL_GRAPHICS。
            // 期望：VS = 1(support)+3 = 4；GS = 1+1 = 2；FS = 1+2 = 3 —— 均 ≤ 36。
            Check(StageUboCount(dc, ResourceStages.Vertex) == 4, "count.vs",
                "4", StageUboCount(dc, ResourceStages.Vertex).ToString());
            Check(StageUboCount(dc, ResourceStages.Geometry) == 2, "count.gs",
                "2", StageUboCount(dc, ResourceStages.Geometry).ToString());
            Check(StageUboCount(dc, ResourceStages.Fragment) == 3, "count.fs",
                "3", StageUboCount(dc, ResourceStages.Fragment).ToString());

            // 未用绑定不再声明：VS 段未用的（如 binding 3）、FS 段未用的（如 20）不得出现。
            Check(!dc.Descriptors.Any(d => d.Type == ResourceType.UniformBuffer && d.Binding == 3), "decl.unused",
                "binding3 未声明", "declared");
            Check(!dc.Descriptors.Any(d => d.Type == ResourceType.UniformBuffer && d.Binding == 20), "decl.unused.fs",
                "binding20 未声明", "declared");

            // 无重复绑定。
            Check(dc.Descriptors.GroupBy(d => d.Binding).All(g => g.Count() == 1), "decl.nodup",
                "无重复 binding", "dup");

            // 已用绑定带对阶段位：VS 的 binding 5 只有 Vertex；FS 的 22 只有 Fragment；GS 的 37 只有 Geometry。
            Check(dc.Descriptors.Single(d => d.Binding == 5).Stages == ResourceStages.Vertex, "flags.vs5",
                "Vertex", dc.Descriptors.Single(d => d.Binding == 5).Stages.ToString());
            Check(dc.Descriptors.Single(d => d.Binding == 22).Stages == ResourceStages.Fragment, "flags.fs22",
                "Fragment", dc.Descriptors.Single(d => d.Binding == 22).Stages.ToString());
            Check(dc.Descriptors.Single(d => d.Binding == 37).Stages == ResourceStages.Geometry, "flags.gs37",
                "Geometry", dc.Descriptors.Single(d => d.Binding == 37).Stages.ToString());
        }

        static void TestMetalLayout()
        {
            // NxRenderer 和离线烘焙器共用的真实 Metal 能力表，不模拟 Vulkan 能力。
            var caps = NxGal.NxCaps.Build(new ulong[] { 0, 49152, 0, 0 });
            var ctx = new GpuContext(Fake.Renderer(), new Ryujinx.Common.Configuration.DirtyHacks(Array.Empty<ulong>()));
            ctx.Capabilities = caps;
            var builder = new ShaderInfoBuilder(ctx, tfEnabled: false);
            builder.AddStageInfo(Info(ShaderStage.Vertex, Cbs(1, 5)));
            builder.AddStageInfo(Info(ShaderStage.Fragment, Cbs(19, 22)));
            var uniforms = builder.Build(null).ResourceLayout.Sets[caps.UniformBufferSetIndex].Descriptors
                .Where(d => d.Type == ResourceType.UniformBuffer).OrderBy(d => d.Binding).ToArray();
            // 修前同一调用声明 support 0 + VS 1..18 + FS 19..36，共 37 项；修后只保留用到的 4 项。
            int[] expected = { 0, 1, 5, 19, 22 };
            Check(uniforms.Select(d => d.Binding).SequenceEqual(expected), "metal.layout.used",
                "0,1,5,19,22", string.Join(",", uniforms.Select(d => d.Binding)));
            Check(uniforms.All(d => d.Count == 1) && uniforms.Single(d => d.Binding == 1).Stages == ResourceStages.Vertex
                && uniforms.Single(d => d.Binding == 19).Stages == ResourceStages.Fragment,
                "metal.layout.stages", "每项 count=1 且 VS/FS 阶段不变", "count/stage mismatch");
            var support = uniforms.Single(d => d.Binding == 0).Stages;
            var before = ResourceStages.Compute | ResourceStages.Vertex | ResourceStages.Fragment;
            var added = ResourceStages.TessellationControl | ResourceStages.TessellationEvaluation | ResourceStages.Geometry;
            Check(support == (before | added), "metal.layout.support", "原 C|V|F 加 TCS|TES|GS", support.ToString());
            Console.WriteLine($"Metal 当前 UBO binding：{string.Join(",", uniforms.Select(d => d.Binding))}；support={support}。");
        }

        static int Main()
        {
            TestStages();
            TestMetalLayout();
            Console.WriteLine(_fail == 0 ? "期望 → 真结果：全过" : $"失败 {_fail} 条");
            return _fail;
        }
    }
}
