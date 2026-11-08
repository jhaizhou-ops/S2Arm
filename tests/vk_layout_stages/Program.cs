// 宿主单测：SPIR-V 实际用到的每个 (set, binding) 在程序资源布局里都要包含使用它的阶段（#199 9000 歧路旅人 II DeviceLost）。
//
// 现场：9000（Mali-G710）没有 VK_EXT_depth_clip_control，S2A 运行时状态开时，最后一个 VTG 阶段（这里是 GS）的
//   -1..1 → 0..1 深度变换要读支持缓冲（set 0 / binding 0）。修前 ShaderInfoBuilder 的 SupportBufferStages 只有
//   Compute | Vertex | Fragment，布局里这个绑定对 Geometry 不可见，违反 VUID-VkGraphicsPipelineCreateInfo-layout-07988。
//
// 本单测不碰 Vulkan 设备：用生产翻译器翻一个 VS→GS→FS 程序，取真实 ShaderProgramInfo 交给生产 ShaderInfoBuilder 建布局，
//   再静态解析每个阶段的 SPIR-V（OpVariable + DescriptorSet/Binding 修饰 + 真正引用该变量的指令），逐项核布局阶段位。
//   修前 GS 的 (0, 0) 判红；修后全绿。Tessellation 阶段由同一个 VtgStages 口径覆盖，另加一条布局守卫。
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Shader;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;

class StubRenderer : DispatchProxy
{
    protected override object Invoke(MethodInfo method, object[] args)
    {
        Type type = method.ReturnType;
        if (type == typeof(void))
        {
            return null;
        }
        if (type.IsInterface)
        {
            return Create(type, typeof(StubRenderer));
        }
        return type.IsValueType ? Activator.CreateInstance(type) : null;
    }
}

sealed class TestAccessor(byte[] code) : IGpuAccessor
{
    // 9000 的能力组合：没有 depth clip control，S2A 运行时状态开 → 最后 VTG 阶段读支持缓冲。
    public bool QueryS2ARuntimeState() => true;
    public bool QueryHostSupportsDepthClipControl() => false;

    public ReadOnlySpan<ulong> GetCode(ulong address, int minimumSize) => MemoryMarshal.Cast<byte, ulong>(code.AsSpan(checked((int)address)));
    public SetBindingPair CreateConstantBufferBinding(int index) => new(0, index + 1);
    public SetBindingPair CreateStorageBufferBinding(int index) => new(1, index);
    public SetBindingPair CreateImageBinding(int count, bool isBuffer) => new(3, 0);
    public SetBindingPair CreateTextureBinding(int count, bool isBuffer) => new(2, 0);
    public int QuerySamplerArrayLengthFromPool() => 8;
    public int QueryTextureArrayLengthFromBuffer(int slot) => 8;
    public int QueryTextureArrayLengthFromPool() => 8;

    public GpuGraphicsState QueryGraphicsState() => new(
        false,
        InputTopology.Triangles,
        false,
        TessPatchType.Triangles,
        TessSpacing.EqualSpacing,
        false,
        false,
        false,
        false,
        false,
        1f,
        AlphaTestOp.Always,
        0f,
        default,
        true,
        default,
        false,
        false,
        true,
        false);
}

static class Program
{
    const ulong Sched = 0x001F8000FC0007E0UL;
    const ulong Exit = 0xE30000000007000FUL;

    // OUT.Emit：OutR 编码，OutType = Emit（bit 39），谓词恒真。EmitOut 在最后一个 VTG 阶段会先做深度重映射。
    const ulong OutEmit = 0xFBE00080000707FFUL;

    static ulong Ast(int location, int component = 0, int reg = 0) =>
        0xEFF0000000000000UL | (0xFFUL << 39) | ((ulong)(0x80 + location * 16 + component * 4) << 20) | (7UL << 16) | (0xFFUL << 8) | (uint)reg;

    static byte[] Guest(bool fragment, ulong[] ops)
    {
        int blocks = (ops.Length + 1 + 2) / 3;
        byte[] bytes = new byte[0x50 + blocks * 32];
        BinaryPrimitives.WriteUInt32LittleEndian(bytes, fragment ? 2u | (3u << 5) | (5u << 10) : 1u | (3u << 5) | (1u << 10));
        if (fragment)
        {
            BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(72), 15);
        }
        for (int i = 0; i < blocks * 4; i++)
        {
            int opIndex = i / 4 * 3 + i % 4 - 1;
            ulong op = i % 4 == 0 ? Sched : opIndex < ops.Length ? ops[opIndex] : Exit;
            BinaryPrimitives.WriteUInt64LittleEndian(bytes.AsSpan(0x50 + i * 8), op);
        }
        return bytes;
    }

    // 非直通几何着色器：写位置后 OUT.Emit（GpPassthrough = 0，与游戏里真正改输出的 GS 同路径）。
    static byte[] Geometry()
    {
        byte[] bytes = Guest(false, [Ast(0, 0, 0), Ast(0, 1, 1), Ast(0, 2, 2), Ast(0, 3, 3), OutEmit]);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes, 1u | (3u << 5) | (4u << 10));   // SphType 1 / version 3 / Stage Geometry / 非直通
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(4), 1u << 24);              // PerPatchAttributeCount = 1
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(8), 3u << 24);             // ThreadsPerInputPrimitive = 3（三角形）
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(12), 7u << 24);            // OutputTopology = TriangleStrip
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(16), 3);                   // MaxOutputVertexCount = 3
        return bytes;
    }

    static Capabilities TestCapabilities() => new(
        api: TargetApi.Vulkan,
        vendorName: "S2A test",
        memoryType: SystemMemoryType.UnifiedMemory,
        hasFrontFacingBug: false,
        hasVectorIndexingBug: false,
        needsFragmentOutputSpecialization: false,
        reduceShaderPrecision: false,
        supportsAstcCompression: false,
        supportsBc123Compression: false,
        supportsBc45Compression: false,
        supportsBc67Compression: false,
        supportsEtc2Compression: false,
        supports3DTextureCompression: false,
        supportsBgraFormat: true,
        supportsR4G4Format: true,
        supportsR4G4B4A4Format: true,
        supportsScaledVertexFormats: true,
        supportsSnormBufferTextureFormat: true,
        supports5BitComponentFormat: true,
        supportsSparseBuffer: false,
        supportsBlendEquationAdvanced: false,
        supportsFragmentShaderInterlock: false,
        supportsFragmentShaderOrderingIntel: false,
        supportsGeometryShader: true,
        supportsGeometryShaderPassthrough: true,
        supportsTransformFeedback: false,
        supportsImageLoadFormatted: true,
        supportsLayerVertexTessellation: true,
        supportsMismatchingViewFormat: true,
        supportsCubemapView: true,
        supportsNonConstantTextureOffset: true,
        supportsQuads: false,
        supportsSeparateSampler: true,
        supportsShaderBallot: false,
        supportsShaderBarrierDivergence: true,
        supportsShaderFloat64: false,
        supportsShaderNonUniformIndexing: true,
        supportsTextureGatherOffsets: false,
        supportsTextureShadowLod: false,
        supportsVertexStoreAndAtomics: false,
        supportsViewportIndexVertexTessellation: false,
        supportsViewportMask: false,
        supportsViewportSwizzle: false,
        supportsIndirectParameters: false,
        supportsDepthClipControl: false,
        uniformBufferSetIndex: 0,
        storageBufferSetIndex: 1,
        textureSetIndex: 2,
        imageSetIndex: 3,
        extraSetBaseIndex: 4,
        maximumExtraSets: 4,
        maximumUniformBuffersPerStage: 18,
        maximumStorageBuffersPerStage: 16,
        maximumTexturesPerStage: 64,
        maximumImagesPerStage: 16,
        maximumComputeSharedMemorySize: 0xc000,
        maximumSupportedAnisotropy: 16f,
        shaderSubgroupSize: 32,
        storageBufferOffsetAlignment: 16,
        textureBufferOffsetAlignment: 16,
        gatherBiasPrecision: 0,
        maximumGpuMemory: 0);

    static ResourceStages StageMask(ShaderStage stage) => stage switch
    {
        ShaderStage.Compute => ResourceStages.Compute,
        ShaderStage.Vertex => ResourceStages.Vertex,
        ShaderStage.TessellationControl => ResourceStages.TessellationControl,
        ShaderStage.TessellationEvaluation => ResourceStages.TessellationEvaluation,
        ShaderStage.Geometry => ResourceStages.Geometry,
        ShaderStage.Fragment => ResourceStages.Fragment,
        _ => ResourceStages.None,
    };

    static List<(int Set, int Binding)> UsedDescriptors(byte[] binary)
    {
        uint[] words = new uint[binary.Length / 4];
        Buffer.BlockCopy(binary, 0, words, 0, binary.Length);

        HashSet<uint> descriptorVariables = [];
        Dictionary<uint, int> sets = [];
        Dictionary<uint, int> bindings = [];

        for (int index = 5; index < words.Length;)
        {
            int wordCount = (int)(words[index] >> 16);
            int opcode = (int)(words[index] & 0xFFFF);
            if (wordCount <= 0)
            {
                break;
            }

            if (opcode == 59 && wordCount >= 4) // OpVariable
            {
                uint storageClass = words[index + 3];
                if (storageClass is 0 or 2 or 12) // UniformConstant / Uniform / StorageBuffer
                {
                    descriptorVariables.Add(words[index + 2]);
                }
            }
            else if (opcode == 71 && wordCount >= 4) // OpDecorate
            {
                uint target = words[index + 1];
                uint decoration = words[index + 2];
                if (decoration == 34) // DescriptorSet
                {
                    sets[target] = (int)words[index + 3];
                }
                else if (decoration == 33) // Binding
                {
                    bindings[target] = (int)words[index + 3];
                }
            }

            index += wordCount;
        }

        HashSet<uint> used = [];
        for (int index = 5; index < words.Length;)
        {
            int wordCount = (int)(words[index] >> 16);
            int opcode = (int)(words[index] & 0xFFFF);
            if (wordCount <= 0)
            {
                break;
            }

            // 声明 / 注解 / 调试名 / 入口点接口表不算使用；其余指令的操作数里出现变量 id 即视为该阶段真正引用了它。
            if (opcode is not (59 or 71 or 5 or 6 or 15 or 16 or 17 or 14))
            {
                for (int operand = 1; operand < wordCount; operand++)
                {
                    if (descriptorVariables.Contains(words[index + operand]))
                    {
                        used.Add(words[index + operand]);
                    }
                }
            }

            index += wordCount;
        }

        return used
            .Where(id => sets.ContainsKey(id) && bindings.ContainsKey(id))
            .Select(id => (sets[id], bindings[id]))
            .Distinct()
            .OrderBy(item => item.Item1)
            .ThenBy(item => item.Item2)
            .ToList();
    }

    static bool LayoutCovers(ShaderInfo info, int set, int binding, ShaderStage stage)
    {
        if (set < 0 || set >= info.ResourceLayout.Sets.Count)
        {
            return false;
        }

        ResourceStages wanted = StageMask(stage);
        foreach (ResourceDescriptor descriptor in info.ResourceLayout.Sets[set].Descriptors)
        {
            if (binding >= descriptor.Binding && binding < descriptor.Binding + descriptor.Count)
            {
                return (descriptor.Stages & wanted) != 0;
            }
        }

        return false;
    }

    static int _pass;
    static int _fail;

    static void Check(string name, bool ok, string detail = "")
    {
        if (ok)
        {
            _pass++;
        }
        else
        {
            _fail++;
        }

        Console.WriteLine($"{(ok ? "✓" : "✗")} {name}{(detail.Length > 0 ? "：" + detail : "")}");
    }

    static int Main()
    {
        TranslatorContext.S2AStageIndep = true;
        TranslatorContext.S2ARuntimeState = true;

        TranslationOptions options = new(TargetLanguage.Spirv, TargetApi.Vulkan, TranslationFlags.DebugMode);
        var fragmentContext = Translator.CreateContext(0, new TestAccessor(Guest(true, [])), options);
        var geometryContext = Translator.CreateContext(0, new TestAccessor(Geometry()), options);
        var vertexContext = Translator.CreateContext(0, new TestAccessor(Guest(false, [Ast(0, 0, 0), Ast(0, 1, 1), Ast(0, 2, 2), Ast(0, 3, 3)])), options);

        geometryContext.SetNextStage(fragmentContext);
        vertexContext.SetNextStage(geometryContext);

        ShaderProgram vertex = vertexContext.Translate();
        ShaderProgram geometry = geometryContext.Translate();
        ShaderProgram fragment = fragmentContext.Translate();

        Check("翻译出 VS / GS / FS 三个阶段", vertex.Info.Stage == ShaderStage.Vertex && geometry.Info.Stage == ShaderStage.Geometry && fragment.Info.Stage == ShaderStage.Fragment);

        var geometryUses = UsedDescriptors(geometry.BinaryCode);
        Check("GS 的 SPIR-V 真的读取支持缓冲 (set 0, binding 0)", geometryUses.Contains((0, 0)), string.Join(", ", geometryUses.Select(item => $"({item.Set}, {item.Binding})")));

        GpuContext gpuContext = new((IRenderer)DispatchProxy.Create(typeof(IRenderer), typeof(StubRenderer)), new DirtyHacks(Array.Empty<ulong>()))
        {
            Capabilities = TestCapabilities(),
        };

        ShaderInfoBuilder builder = new(gpuContext, tfEnabled: false);
        builder.AddStageInfo(vertex.Info);
        builder.AddStageInfo(geometry.Info);
        builder.AddStageInfo(fragment.Info);
        ShaderInfo info = builder.Build(null);

        foreach ((ShaderProgram program, string name) in new[] { (vertex, "VS"), (geometry, "GS"), (fragment, "FS") })
        {
            var used = UsedDescriptors(program.BinaryCode);
            List<string> missing = [];
            foreach ((int set, int binding) in used)
            {
                if (!LayoutCovers(info, set, binding, program.Info.Stage))
                {
                    missing.Add($"({set}, {binding})");
                }
            }

            Check($"{name} 用到的每个 (set, binding) 在布局里都包含 {program.Info.Stage} 阶段", missing.Count == 0,
                used.Count == 0 ? "本阶段无描述符" : missing.Count == 0 ? $"共 {used.Count} 项" : $"缺阶段位：{string.Join(", ", missing)}");
        }

        // 支持缓冲布局是全局共享的：几何 / 细分阶段都必须可见（VtgStages 口径），不只修当前这一支 GS。
        int supportSet = TestCapabilities().UniformBufferSetIndex;
        ResourceStages supportStages = info.ResourceLayout.Sets[supportSet].Descriptors.First(descriptor => descriptor.Binding == 0).Stages;
        ResourceStages vtg = ResourceStages.Vertex | ResourceStages.TessellationControl | ResourceStages.TessellationEvaluation | ResourceStages.Geometry;
        Check("支持缓冲阶段位覆盖 VtgStages（Vertex + TessControl + TessEval + Geometry）", (supportStages & vtg) == vtg, supportStages.ToString());

        Console.WriteLine($"vk_layout_stages：{_pass + _fail} 项，失败 {_fail}");
        return _fail == 0 ? 0 : 1;
    }
}
