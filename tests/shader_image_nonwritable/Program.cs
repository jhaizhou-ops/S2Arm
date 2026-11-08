// #1165（安卓直连门槛）：没被写过的存储图像 / 存储 texel buffer 在 SPIR-V 里带 NonWritable，写过（ImageStore / ImageAtomic）的不带。
// 用真实 ResourceManager 登记三张图像、真实 SpirvGenerator 出模块，按 Binding 找变量再查装饰；期望值由登记用的指令直接定，不经被测实现。
using System;
using System.Collections.Generic;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using Ryujinx.Graphics.Shader.StructuredIr;
using Ryujinx.Graphics.Shader.CodeGen;
using Ryujinx.Graphics.Shader.CodeGen.Spirv;
using Ryujinx.Graphics.Shader.Translation;
namespace Ryujinx.Common { static class EmbeddedResources { public static string ReadAllText(string name) => throw new InvalidOperationException(name); } }
class Accessor : IGpuAccessor
{
    int _image;
    public ReadOnlySpan<ulong> GetCode(ulong address, int minimumSize) => throw new NotSupportedException();
    public SetBindingPair CreateConstantBufferBinding(int index) => new(0, index);
    public SetBindingPair CreateStorageBufferBinding(int index) => new(1, index);
    public SetBindingPair CreateTextureBinding(int count, bool isBuffer) => new(2, 0);
    public SetBindingPair CreateImageBinding(int count, bool isBuffer) => new(3, _image++);
    public SetBindingPair CreateS2AStorageOobRecordBinding(ShaderStage stage) => new(-1, -1);
    public int CreateExtraSet() => -1;
    public int QuerySamplerArrayLengthFromPool() => 8;
    public int QueryTextureArrayLengthFromBuffer(int slot) => 8;
    public int QueryTextureArrayLengthFromPool() => 8;
}
static class Program
{
    static int Main()
    {
        var gpu = new Accessor(); var manager = new ResourceManager(ShaderStage.Compute, gpu);
        // 期望（由指令定）：只读 = 只被 ImageLoad 用；写 = ImageStore；原子 = ImageAtomic；同一图像先读后写 = 写（用途取并集）
        var cases = new (string Name, Instruction[] Insts, SamplerType Type, bool WantNonWritable)[]
        {
            ("只读存储 texel buffer（ImageLoad）", new[] { Instruction.ImageLoad }, SamplerType.TextureBuffer, true),
            ("只读存储图像 2D（ImageLoad）", new[] { Instruction.ImageLoad }, SamplerType.Texture2D, true),
            ("写的存储图像（ImageStore）", new[] { Instruction.ImageStore }, SamplerType.Texture2D, false),
            ("原子的存储 texel buffer（ImageAtomic）", new[] { Instruction.ImageAtomic }, SamplerType.TextureBuffer, false),
            ("先读后写的同一图像（ImageLoad + ImageStore）", new[] { Instruction.ImageLoad, Instruction.ImageStore }, SamplerType.Texture2D, false),
        };
        var binding = new int[cases.Length];
        for (int i = 0; i < cases.Length; i++)
            foreach (Instruction inst in cases[i].Insts)
                binding[i] = manager.GetTextureOrImageBinding(inst, cases[i].Type, TextureFormat.R32Uint, TextureFlags.None, 0, 0x10 * (i + 1)).Binding;
        var info = new StructuredProgramInfo();
        info.Functions.Add(new StructuredFunction(new AstBlock(AstBlockType.Main), "main", AggregateType.Void, [], []));
        var caps = new HostCapabilities(false, false, false, false, false, false, false, true, true, false,
            supportsSpirv15: false, spirvLayerExt: false, spirvLayerNv: false, layerOutput: false, viewportOutput: false);
        var parameters = new CodeGenParameters(new AttributeUsage(gpu), new ShaderDefinitions(ShaderStage.Compute, 1, 1, 1), manager.Properties, caps, gpu, TargetApi.Vulkan);
        byte[] spv = SpirvGenerator.Generate(info, parameters);
        // OpDecorate（71）：target, decoration, literal…；Binding = 33、DescriptorSet = 34、NonWritable = 24
        var words = new uint[spv.Length / 4]; Buffer.BlockCopy(spv, 0, words, 0, spv.Length);
        if (words.Length < 5 || words[0] != 0x07230203) { Console.WriteLine("FAIL 没出 SPIR-V 模块"); return 1; }
        var bindOf = new Dictionary<uint, uint>(); var setOf = new Dictionary<uint, uint>(); var nonWritable = new HashSet<uint>();
        for (int at = 5; at < words.Length;)
        {
            uint wc = words[at] >> 16, op = words[at] & 0xffff;
            if (wc == 0) { Console.WriteLine("FAIL SPIR-V 指令长度 0"); return 1; }
            if (op == 71 && wc >= 3)
            {
                uint target = words[at + 1], dec = words[at + 2];
                if (dec == 33 && wc >= 4) bindOf[target] = words[at + 3];
                else if (dec == 34 && wc >= 4) setOf[target] = words[at + 3];
                else if (dec == 24) nonWritable.Add(target);
            }
            at += (int)wc;
        }
        int failures = 0;
        for (int i = 0; i < cases.Length; i++)
        {
            uint? var = null;
            foreach (var (id, b) in bindOf) if (b == (uint)binding[i] && setOf.TryGetValue(id, out uint s) && s == 3) var = id;
            bool got = var is uint v && nonWritable.Contains(v), ok = var != null && got == cases[i].WantNonWritable;
            Console.WriteLine($"{(ok ? "过" : "FAIL")}  {cases[i].Name}：期望 NonWritable={cases[i].WantNonWritable} → 真结果 {(var == null ? "（没找到变量）" : got.ToString())}");
            if (!ok) failures++;
        }
        Console.WriteLine($"共 {cases.Length} 项，失败 {failures} 项");
        return failures == 0 ? 0 : 1;
    }
}
