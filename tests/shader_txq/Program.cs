using System;
using System.Collections.Generic;
using System.Linq;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using Ryujinx.Graphics.Shader.StructuredIr;
using Ryujinx.Graphics.Shader.CodeGen;
using Ryujinx.Graphics.Shader.CodeGen.Spirv;
using Ryujinx.Graphics.Shader.Translation;
using Ryujinx.Graphics.Shader.Translation.Transforms;
using Ryujinx.Graphics.Shader.Translation.Optimizations;
using static Ryujinx.Graphics.Shader.IntermediateRepresentation.OperandHelper;
// This SPIR-V fixture never loads GLSL helpers; reject accidental GLSL execution.
namespace Ryujinx.Common { static class EmbeddedResources { public static string ReadAllText(string name) => throw new InvalidOperationException(name); } }
class Accessor : IGpuAccessor
{
    public ReadOnlySpan<ulong> GetCode(ulong address, int minimumSize) => throw new NotSupportedException();
    public SetBindingPair CreateConstantBufferBinding(int index) => new(0, index);
    public SetBindingPair CreateStorageBufferBinding(int index) => new(1, index);
    public SetBindingPair CreateImageBinding(int count, bool isBuffer) => new(3, 0);
    public SetBindingPair CreateTextureBinding(int count, bool isBuffer) => new(2, 0);
    public bool OobEnabled;
    public SetBindingPair CreateS2AStorageOobRecordBinding(ShaderStage stage) => OobEnabled ? new(1, 31) : new(-1, -1);
    private int extraSet = 4;
    public int CreateExtraSet() => extraSet++;
    public int QueryHostGatherBiasPrecision() => 1;
    public bool QueryHostSupportsTextureGatherOffsets() => false;
    public bool QueryHostSupportsNonConstantTextureOffset() => false;
    public int QuerySamplerArrayLengthFromPool() => 8;
    public int QueryTextureArrayLengthFromBuffer(int slot) => 8;
    public int QueryTextureArrayLengthFromPool() => 8;
}
class Program
{
    static byte[] EmitQuery(ResourceManager manager, Accessor gpu, TextureOperation query)
    {
        var info = new StructuredProgramInfo(); var block = new AstBlock(AstBlockType.Main);
        var function = new StructuredFunction(block, "main", AggregateType.Void, [], []); info.Functions.Add(function);
        var dest = new AstOperand(OperandType.LocalVariable); function.Locals.Add(dest);
        var args = Enumerable.Range(0, query.SourcesCount).Select(i => (IAstNode)new AstOperand(OperandType.Constant, query.GetSource(i).Type == OperandType.Constant ? query.GetSource(i).Value : 1)).ToArray();
        var ast = new AstTextureOperation(query.Inst, query.Type, query.Format, query.Flags, query.Set, query.Binding, query.SamplerSet, query.SamplerBinding, query.Index, args);
        block.Add(new AstAssignment(dest, ast));
        var defs = new ShaderDefinitions(ShaderStage.Compute, 1, 1, 1);
        var caps = new HostCapabilities(false, false, false, false, false, false, false, true, true, false,
            supportsSpirv15: false, spirvLayerExt: false, spirvLayerNv: false, layerOutput: false, viewportOutput: false);
        var parameters = new CodeGenParameters(new AttributeUsage(gpu), defs, manager.Properties, caps, gpu, TargetApi.Vulkan);
        return SpirvGenerator.Generate(info, parameters);
    }
    static void Main(string[] args)
    {
        var gpu = new Accessor { OobEnabled = true }; var manager = new ResourceManager(ShaderStage.Compute, gpu);
        if (!manager.TryGetS2AStorageOobRecordBinding(out int oob) || oob != 31) throw new Exception("OOB binding missing");
        var before = manager.GetStorageBufferDescriptors();
        if (before.Length != 1 || before[0].Set != 1 || before[0].Binding != 31 || !before[0].Flags.HasFlag(BufferUsageFlags.S2AOobRecord)) throw new Exception("OOB descriptor missing");
        var plain = manager.GetTextureOrImageBinding(Instruction.TextureSample, SamplerType.Texture2D, TextureFormat.Unknown, TextureFlags.None, 0, 16);
        var array = manager.GetTextureOrImageBinding(Instruction.TextureSample, SamplerType.Texture2D, TextureFormat.Unknown, TextureFlags.None, 0, 32, 8);
        if (plain != new SetBindingPair(2, 0) || array != new SetBindingPair(4, 0)) throw new Exception("fixture bindings");
        var index = Local(); var dest = Local();
        var sample = new TextureOperation(Instruction.TextureSample, SamplerType.Texture2D, TextureFormat.Unknown, TextureFlags.LodLevel, array.SetIndex, array.Binding, 0, [dest], [index, ConstF(.5f), ConstF(.25f), Const(0)]);
        var block = new BasicBlock(0); var node = block.Operations.AddLast(sample);
        var funcs = new List<Function>(); var hfm = new HelperFunctionManager(funcs, ShaderStage.Compute); FeatureFlags used = default;
        TranslatorContext.S2ARuntimeState = true;
        var context = new TransformContext(hfm, [block], null, manager, gpu, TargetApi.Vulkan, TargetLanguage.Spirv, ShaderStage.Compute, ref used, new StorageRangeContext(ShaderStage.Compute, 0, 0));
        TexturePass.RunPass(context, node);
        var bad = block.Operations.OfType<TextureOperation>().Where(o => o.Inst == Instruction.TextureQuerySize && o.Set == array.SetIndex && o.Binding == array.Binding && o.SourcesCount < 2).ToArray();
        foreach (var query in bad) EmitQuery(manager, gpu, query); // Actual SPIR-V generator used to throw on the missing LOD.
        if (bad.Length != 0) throw new Exception($"indexed TXQ lost index: {bad.Length}, sources={bad[0].SourcesCount}");
        var validQuery = new TextureOperation(Instruction.TextureQuerySize, SamplerType.Texture2D, TextureFormat.Unknown, TextureFlags.LodLevel, array.SetIndex, array.Binding, 0, [Local()], [index, Const(0)]);
        byte[] spirv = EmitQuery(manager, gpu, validQuery);
        if (spirv.Length < 20 || BitConverter.ToUInt32(spirv, 0) != 0x07230203) throw new Exception("indexed TXQ did not emit SPIR-V");
        if (args.Length > 0) System.IO.File.WriteAllBytes(args[0], spirv);
        if (sample.GetSource(0) != index) throw new Exception("indexed sample lost original index");
        // Separate texture/sampler arrays require both indices before LOD.
        var gpu2 = new Accessor(); var manager2 = new ResourceManager(ShaderStage.Compute, gpu2);
        var tex = manager2.GetTextureOrImageBinding(Instruction.TextureSample, SamplerType.Texture2D, TextureFormat.Unknown, TextureFlags.None, 0, 64, 8, true);
        var samp = manager2.GetTextureOrImageBinding(Instruction.TextureSample, SamplerType.None, TextureFormat.Unknown, TextureFlags.None, 0, 96, 8);
        var ti = Local(); var si = Local(); var gathered = new TextureOperation(Instruction.TextureSample, SamplerType.Texture2D, TextureFormat.Unknown, TextureFlags.Gather, tex.SetIndex, tex.Binding, 1, [Local()], [ti, si, ConstF(.5f), ConstF(.25f), Const(0)]);
        gathered.TurnIntoArray(tex, samp);
        var b2 = new BasicBlock(0); var n2 = b2.Operations.AddLast(gathered); FeatureFlags flags2 = default;
        var ctx2 = new TransformContext(new HelperFunctionManager(new List<Function>(), ShaderStage.Compute), [b2], null, manager2, gpu2, TargetApi.Vulkan, TargetLanguage.Spirv, ShaderStage.Compute, ref flags2, new StorageRangeContext(ShaderStage.Compute, 0, 0));
        TexturePass.RunPass(ctx2, n2);
        var queries = b2.Operations.OfType<TextureOperation>().Where(o => o.Inst == Instruction.TextureQuerySize).ToArray();
        foreach (var query in queries) { byte[] generated = EmitQuery(manager2, gpu2, query); if (args.Length > 1) System.IO.File.WriteAllBytes(args[1], generated); }
        if (queries.Length != 2 || queries.Any(q => q.SourcesCount != 3 || q.GetSource(0) != ti || q.GetSource(1) != si || q.SamplerSet != samp.SetIndex || q.SamplerBinding != samp.Binding))
            throw new Exception($"separate indexed gather lost sampler index: queries={queries.Length} sources={(queries.Length == 0 ? -1 : queries[0].SourcesCount)}");
        var descriptors2 = manager2.GetTextureDescriptors();
        var texDesc = descriptors2.Single(d => d.Set == tex.SetIndex && d.Binding == tex.Binding);
        var samplerDesc = descriptors2.Single(d => d.Set == samp.SetIndex && d.Binding == samp.Binding);
        if (!texDesc.Flags.HasFlag(TextureUsageFlags.NeedsScaleValue) || !texDesc.Flags.HasFlag(TextureUsageFlags.ResScaleUnsupported) || samplerDesc.Flags.HasFlag(TextureUsageFlags.NeedsScaleValue)) throw new Exception("query usage not recorded on indexed texture");
        // Reversing registration order must not redirect a plain query's usage flags to the array.
        var gpu3 = new Accessor(); var manager3 = new ResourceManager(ShaderStage.Compute, gpu3);
        var arrayFirst = manager3.GetTextureOrImageBinding(Instruction.TextureSample, SamplerType.Texture2D, TextureFormat.Unknown, TextureFlags.None, 0, 128, 8);
        var plainSecond = manager3.GetTextureOrImageBinding(Instruction.TextureSample, SamplerType.Texture2D, TextureFormat.Unknown, TextureFlags.None, 0, 160);
        var plainSample = new TextureOperation(Instruction.TextureSample, SamplerType.Texture2D, TextureFormat.Unknown, TextureFlags.LodLevel, plainSecond.SetIndex, plainSecond.Binding, 0, [Local()], [ConstF(.5f), ConstF(.25f), Const(0)]);
        var b3 = new BasicBlock(0); var n3 = b3.Operations.AddLast(plainSample); FeatureFlags flags3 = default;
        var ctx3 = new TransformContext(new HelperFunctionManager(new List<Function>(), ShaderStage.Compute), [b3], null, manager3, gpu3, TargetApi.Vulkan, TargetLanguage.Spirv, ShaderStage.Compute, ref flags3, new StorageRangeContext(ShaderStage.Compute, 0, 0));
        TexturePass.RunPass(ctx3, n3);
        var plainQueries = b3.Operations.OfType<TextureOperation>().Where(o => o.Inst == Instruction.TextureQuerySize).ToArray();
        if (plainQueries.Length != 2 || plainQueries.Any(q => q.SourcesCount != 1 || q.Set != plainSecond.SetIndex)) throw new Exception("plain query lost LOD or set");
        var desc3 = manager3.GetTextureDescriptors();
        if (!desc3.Any(d => d.Set == plainSecond.SetIndex && d.Flags.HasFlag(TextureUsageFlags.NeedsScaleValue)) || desc3.Any(d => d.Set == arrayFirst.SetIndex && d.Flags.HasFlag(TextureUsageFlags.NeedsScaleValue))) throw new Exception("query usage attached to wrong set");
        // Dynamic gather offsets must preserve both index operands when rebuilding the query and sample.
        var gpu4 = new Accessor(); var manager4 = new ResourceManager(ShaderStage.Compute, gpu4);
        var tex4 = manager4.GetTextureOrImageBinding(Instruction.TextureSample, SamplerType.Texture2D, TextureFormat.Unknown, TextureFlags.None, 0, 192, 8, true);
        var samp4 = manager4.GetTextureOrImageBinding(Instruction.TextureSample, SamplerType.None, TextureFormat.Unknown, TextureFlags.None, 0, 224, 8);
        var ti4 = Local(); var si4 = Local();
        var offsetSources = new List<Operand> {ti4, si4, ConstF(.5f), ConstF(.25f)};
        for (int i = 0; i < 8; i++) offsetSources.Add(Local());
        offsetSources.Add(Const(0));
        var gather4 = new TextureOperation(Instruction.TextureSample, SamplerType.Texture2D, TextureFormat.Unknown, TextureFlags.Gather | TextureFlags.Offsets, tex4.SetIndex, tex4.Binding, 1, [Local()], offsetSources.ToArray());
        gather4.TurnIntoArray(tex4, samp4);
        var b4 = new BasicBlock(0); var n4 = b4.Operations.AddLast(gather4); FeatureFlags flags4 = default;
        var ctx4 = new TransformContext(new HelperFunctionManager(new List<Function>(), ShaderStage.Compute), [b4], null, manager4, gpu4, TargetApi.Vulkan, TargetLanguage.Spirv, ShaderStage.Compute, ref flags4, new StorageRangeContext(ShaderStage.Compute, 0, 0));
        TexturePass.RunPass(ctx4, n4);
        var rebuilt = b4.Operations.OfType<TextureOperation>().ToArray();
        var q4 = rebuilt.Where(o => o.Inst == Instruction.TextureQuerySize).ToArray();
        if (q4.Length != 4 || q4.Any(q => q.SourcesCount != 3 || q.GetSource(0) != ti4 || q.GetSource(1) != si4 || q.SamplerSet != samp4.SetIndex || q.SamplerBinding != samp4.Binding)) throw new Exception("gather offsets lost array indices");
        var s4 = rebuilt.Single(o => o.Inst == Instruction.TextureSample);
        if (s4.GetSource(0) != ti4 || s4.GetSource(1) != si4 || s4.SamplerSet != samp4.SetIndex || s4.SamplerBinding != samp4.Binding) throw new Exception("rebuilt sample lost sampler");
        foreach (var query in q4) EmitQuery(manager4, gpu4, query);
        var texDesc4 = manager4.GetTextureDescriptors().Single(d => d.Set == tex4.SetIndex && d.Binding == tex4.Binding);
        if (!texDesc4.Flags.HasFlag(TextureUsageFlags.NeedsScaleValue) || !texDesc4.Flags.HasFlag(TextureUsageFlags.ResScaleUnsupported)) throw new Exception("offset query usage not recorded");
        // Mixed separate bindings are not emitted by the current producer; reject them explicitly.
        var gpu5 = new Accessor(); var manager5 = new ResourceManager(ShaderStage.Compute, gpu5);
        var tex5 = manager5.GetTextureOrImageBinding(Instruction.TextureSample, SamplerType.Texture2D, TextureFormat.Unknown, TextureFlags.None, 0, 256, 1, true);
        var samp5 = manager5.GetTextureOrImageBinding(Instruction.TextureSample, SamplerType.None, TextureFormat.Unknown, TextureFlags.None, 0, 288, 8);
        var mixed = new TextureOperation(Instruction.TextureSample, SamplerType.Texture2D, TextureFormat.Unknown, TextureFlags.None, tex5.SetIndex, tex5.Binding, 0, [Local()], [Local(), ConstF(.5f), ConstF(.25f)]);
        mixed.TurnIntoArray(tex5, samp5);
        var b5 = new BasicBlock(0); var n5 = b5.Operations.AddLast(mixed); FeatureFlags flags5 = default;
        var ctx5 = new TransformContext(new HelperFunctionManager(new List<Function>(), ShaderStage.Compute), [b5], null, manager5, gpu5, TargetApi.Vulkan, TargetLanguage.Spirv, ShaderStage.Compute, ref flags5, new StorageRangeContext(ShaderStage.Compute, 0, 0));
        bool rejected = false;
        try { TexturePass.RunPass(ctx5, n5); }
        catch (InvalidOperationException e) when (e.Message == "Separate texture and sampler must both be indexed arrays.") { rejected = true; }
        if (!rejected) throw new Exception("mixed separate arrays were silently accepted");
        // Explicit LOD on a compute offset sample must feed the generated texture-size query.
        var gpu6 = new Accessor(); var manager6 = new ResourceManager(ShaderStage.Compute, gpu6);
        var tex6 = manager6.GetTextureOrImageBinding(Instruction.TextureSample, SamplerType.Texture2D, TextureFormat.Unknown, TextureFlags.None, 0, 320, 8, true);
        var samp6 = manager6.GetTextureOrImageBinding(Instruction.TextureSample, SamplerType.None, TextureFormat.Unknown, TextureFlags.None, 0, 352, 8);
        var ti6 = Local(); var si6 = Local(); var lod6 = Local();
        var sample6 = new TextureOperation(Instruction.TextureSample, SamplerType.Texture2D, TextureFormat.Unknown, TextureFlags.Offset | TextureFlags.LodLevel, tex6.SetIndex, tex6.Binding, 0, [Local()], [ti6, si6, ConstF(.5f), ConstF(.25f), lod6, Local(), Local()]);
        sample6.TurnIntoArray(tex6, samp6);
        var b6 = new BasicBlock(0); var n6 = b6.Operations.AddLast(sample6); FeatureFlags flags6 = default;
        var ctx6 = new TransformContext(new HelperFunctionManager(new List<Function>(), ShaderStage.Compute), [b6], null, manager6, gpu6, TargetApi.Vulkan, TargetLanguage.Spirv, ShaderStage.Compute, ref flags6, new StorageRangeContext(ShaderStage.Compute, 0, 0));
        TexturePass.RunPass(ctx6, n6);
        var q6 = b6.Operations.OfType<TextureOperation>().Where(o => o.Inst == Instruction.TextureQuerySize).ToArray();
        if (q6.Length != 2 || q6.Any(q => q.SourcesCount != 3 || q.GetSource(0) != ti6 || q.GetSource(1) != si6 || q.GetSource(2).AsgOp is not Operation op || op.Inst != Instruction.ConvertFP32ToS32 || op.GetSource(0) != lod6)) throw new Exception("offset query did not use explicit LOD");
        var texDesc6 = manager6.GetTextureDescriptors().Single(d => d.Set == tex6.SetIndex && d.Binding == tex6.Binding);
        if (!texDesc6.Flags.HasFlag(TextureUsageFlags.NeedsScaleValue) || !texDesc6.Flags.HasFlag(TextureUsageFlags.ResScaleUnsupported)) throw new Exception("LOD query usage not recorded");
        var after = manager.GetStorageBufferDescriptors();
        if (after.Length != 1 || after[0].Set != 1 || after[0].Binding != 31 || !after[0].Flags.HasFlag(BufferUsageFlags.S2AOobRecord)) throw new Exception("TXQ clobbered OOB descriptor");
        Console.WriteLine("PASS indexed TXQ preserves source, sampler and OOB descriptor");
    }
}
