// Authored IR, real CFG/SSA/TexturePass, production SPVC and NVN reflection.
// No Maxwell or game data is manufactured, and no reflection is hand-authored.
using System.Diagnostics;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Decoders;
using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using Ryujinx.Graphics.Shader.Translation;
using Ryujinx.Graphics.Shader.Translation.Optimizations;
using Ryujinx.Graphics.Shader.Translation.Transforms;
using S2A.Dsh;
using static Ryujinx.Graphics.Shader.IntermediateRepresentation.OperandHelper;

static class Program
{
    sealed class OwnedAccessor : IGpuAccessor
    {
        int binding = 1;
        readonly bool sizeTable;
        public OwnedAccessor(bool sizeTable) { this.sizeTable = sizeTable; }
        // false is IGpuAccessor's production default, selecting the retained
        // TexturePass legacy helpers; it changes no runtime binding provider.
        public bool QueryHostSupportsTextureSizeTable() => sizeTable;
        public bool QueryHostSupportsShaderFloat64() => false;
        public int QuerySamplerArrayLengthFromPool() => 1;
        public int QueryTextureArrayLengthFromBuffer(int slot) => 1;
        public int QueryTextureArrayLengthFromPool() => 1;
        public SetBindingPair CreateConstantBufferBinding(int index) => new(0, binding++);
        public SetBindingPair CreateStorageBufferBinding(int index) => new(0, binding++);
        public SetBindingPair CreateTextureBinding(int count, bool isBuffer) { int first = binding; binding += count; return new(0, first); }
        public SetBindingPair CreateImageBinding(int count, bool isBuffer) { int first = binding; binding += count; return new(0, first); }
        public ReadOnlySpan<ulong> GetCode(ulong address, int minimumSize) => throw new InvalidOperationException("Authored IR is not Maxwell code");
        public GpuGraphicsState QueryGraphicsState() => new(false, InputTopology.Triangles, false, TessPatchType.Triangles, TessSpacing.EqualSpacing,
            false, false, false, false, false, 1f, AlphaTestOp.Always, 0f, default(Array32<AttributeType>), false, default(Array8<AttributeType>), false, false, true, false);
    }

    static void Run(string executable, params string[] arguments)
    {
        var start = new ProcessStartInfo(executable) { UseShellExecute = false };
        foreach (string argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        process.WaitForExit();
        if (process.ExitCode != 0) throw new InvalidOperationException(executable + " failed: " + process.ExitCode);
    }

    static ShaderProgram Compile(ShaderStage stage, string kind, bool sizeTable)
    {
        var accessor = new OwnedAccessor(sizeTable);
        var usage = new AttributeUsage(accessor);
        var definitions = stage == ShaderStage.Compute ? new ShaderDefinitions(stage, 1, 1, 1)
            : new ShaderDefinitions(stage, accessor.QueryGraphicsState(), false, 1, OutputTopology.TriangleStrip, 3,
                new ImapPixelType[32], stage == ShaderStage.Fragment ? 15 : 0, false, false, false, 0, null);
        var resources = new ResourceManager(stage, accessor);
        var emitter = new EmitterContext();
        var features = stage == ShaderStage.Fragment && (kind is "coord" or "fetch") ? FeatureFlags.FragCoordXY : FeatureFlags.None;
        Operand Frag(int axis)
        {
            Operand physical = emitter.Load(StorageKind.Input, IoVariable.FragmentCoord, null, Const(axis));
            Operand divisor = emitter.Load(StorageKind.ConstantBuffer, 0,
                Const((int)(axis == 0 ? SupportBufferField.RenderScale : SupportBufferField.RenderScaleY)), Const(0));
            return emitter.FPDivide(physical, divisor);
        }
        if (stage == ShaderStage.Vertex)
        {
            Operand vertex = emitter.Load(StorageKind.Input, IoVariable.VertexIndex);
            Operand x = emitter.IConvertS32ToFP32(emitter.IMultiply(emitter.BitwiseAnd(vertex, Const(1)), Const(4)));
            Operand y = emitter.IConvertS32ToFP32(emitter.IMultiply(emitter.BitwiseAnd(emitter.ShiftRightU32(vertex, Const(1)), Const(1)), Const(4)));
            Operand[] position = [emitter.FPSubtract(x, ConstF(1)), emitter.FPSubtract(y, ConstF(1)), ConstF(0), ConstF(1)];
            for (int component = 0; component < 4; component++) emitter.Store(StorageKind.Output, IoVariable.Position, null, Const(component), position[component]);
        }
        else
        {
            Operand[] result;
            if (kind == "coord") result = [Frag(0), Frag(1), ConstF(0), ConstF(1)];
            else
            {
                SetBindingPair texture = resources.GetTextureOrImageBinding(Instruction.TextureSample, SamplerType.Texture2D,
                    TextureFormat.Unknown, TextureFlags.IntCoords | TextureFlags.LodLevel, 2, 8);
                if (kind == "fetch")
                {
                    result = [Local(), Local(), Local(), Local()];
                    emitter.TextureSample(SamplerType.Texture2D, TextureFlags.IntCoords | TextureFlags.LodLevel, texture, 15, result,
                        [emitter.FP32ConvertToS32(Frag(0)), emitter.FP32ConvertToS32(Frag(1)), Const(2)]);
                }
                else
                {
                    Operand w = emitter.TextureQuerySize(SamplerType.Texture2D, TextureFlags.None, texture, 0, [Const(0)]);
                    Operand h = emitter.TextureQuerySize(SamplerType.Texture2D, TextureFlags.None, texture, 1, [Const(0)]);
                    resources.SetUsageFlagsForTextureQuery(texture, SamplerType.Texture2D);
                    result = [emitter.IConvertS32ToFP32(w), emitter.IConvertS32ToFP32(h), ConstF(0), ConstF(1)];
                }
            }
            if (stage == ShaderStage.Fragment)
                for (int c = 0; c < 4; c++) emitter.Store(StorageKind.Output, IoVariable.FragmentOutputColor, null, Const(0), Const(c), result[c]);
            else
            {
                if (!resources.TryGetStorageBufferBinding(0, 0x310 / 4, true, out int storage)) throw new InvalidOperationException("CS output binding unavailable");
                for (int c = 0; c < 4; c++) emitter.Store(StorageKind.StorageBuffer, storage, Const(0), Const(c), result[c]);
            }
        }
        emitter.Return();
        var cfg = ControlFlowGraph.Create(emitter.GetOperations());
        Dominance.FindDominators(cfg); Dominance.FindDominanceFrontiers(cfg.Blocks); Ssa.Rename(cfg.Blocks);
        var functions = new List<Function> { null };
        var helpers = new HelperFunctionManager(functions, stage);
        var transform = new TransformContext(helpers, cfg.Blocks, definitions, resources, accessor, TargetApi.Vulkan, TargetLanguage.Spirv, stage, ref features,
            new StorageRangeContext(stage, 0, 0));   // compat/tree：存储越界诊断上下文（合成资产无源码哈希，只影响诊断记录）
        Optimizer.RunPass(transform); TransformPasses.RunPass(transform);
        functions[0] = new Function(cfg.Blocks, "main", false, 0, 0);
        var decoded = new DecodedProgram(null, new Dictionary<ulong, DecodedFunction>(), usage, features, 0, 0);
        var translator = new TranslatorContext(0, 0, 0, definitions, accessor, new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, TranslationFlags.DebugMode), decoded);
        var generate = typeof(TranslatorContext).GetMethod("Generate", BindingFlags.NonPublic | BindingFlags.Instance)!;
        return (ShaderProgram)generate.Invoke(translator, [functions, usage, definitions, definitions, resources, features, (byte)0])!;
    }

    static JsonObject Metadata(ShaderProgram program)
    {
        var res = new JsonObject { ["notes"] = new JsonArray(), ["sbufs"] = new JsonArray(), ["textures"] = new JsonArray(), ["images"] = new JsonArray() };
        foreach (var d in program.Info.SBuffers) res["sbufs"].AsArray().Add(new JsonObject { ["binding"] = d.Binding, ["slot"] = d.Slot, ["cb_slot"] = d.SbCbSlot, ["cb_offset"] = d.SbCbOffset, ["flags"] = (int)d.Flags });
        foreach (var (list, name) in new[] { (program.Info.Textures, "textures"), (program.Info.Images, "images") })
            foreach (var t in list) res[name].AsArray().Add(new JsonObject { ["binding"] = t.Binding, ["type"] = (int)t.Type, ["format"] = t.Format.ToString(), ["cbuf_slot"] = t.CbufSlot, ["handle"] = t.HandleIndex, ["array"] = t.ArrayLength, ["separate"] = t.Separate, ["flags"] = (int)t.Flags });
        typeof(DshCompiler).Assembly.GetType("SwshXlate")!.GetMethod("FetchScales", BindingFlags.Static | BindingFlags.NonPublic)!.Invoke(null, [program, res]);
        return JsonNode.Parse(res.ToJsonString())!.AsObject();
    }

    static void Main(string[] args)
    {
        if (args.Length != 1) throw new ArgumentException("DirectResolutionAssets <output-directory>");
        string output = Path.GetFullPath(args[0]); Directory.CreateDirectory(output);
        string libraries = Path.Combine(output, "b-" + DshCompiler.Chain); Directory.CreateDirectory(libraries);
        var manifest = new Dictionary<string, object>();
        var map = new System.Text.StringBuilder();
        var options = new JsonSerializerOptions { WriteIndented = true };
        foreach (var (name, kind, stage, stageName) in new[] {
            ("fullscreen_vs", "fullscreen", ShaderStage.Vertex, "vs"), ("size_lod0_ps", "size", ShaderStage.Fragment, "ps"),
            ("size_lod0_cs", "size", ShaderStage.Compute, "cs"), ("frag_coord_ps", "coord", ShaderStage.Fragment, "ps"),
            ("fetch_lod2_ps", "fetch", ShaderStage.Fragment, "ps"),
            ("legacy_fetch_lod2_ps", "fetch", ShaderStage.Fragment, "ps") })
        {
            bool sizeTable = name != "legacy_fetch_lod2_ps";
            ShaderProgram program = Compile(stage, kind, sizeTable);
            string key = Convert.ToHexStringLower(SHA256.HashData(program.BinaryCode))[..16], stem = Path.Combine(libraries, key + "_b");
            File.WriteAllBytes(stem + ".spv", program.BinaryCode);
            Run("spirv-val", "--target-env", "vulkan1.1", stem + ".spv");
            string msl = new CliSpvCross(tmpDir: output).Msl(program.BinaryCode, out string error) ?? throw new InvalidOperationException(error);
            msl = DshCompiler.Precise(msl);
            if (stage == ShaderStage.Vertex) msl = DshCompiler.VsDepth(DshCompiler.VsLayer(DshCompiler.VsInit(msl))).Item2;
            JsonObject res = Metadata(program);
            PyDict scale = DshCompiler.ScaleMetadata(res);
            if ((bool)scale["resolution_scale_exact"] != sizeTable ||
                (string)scale["resolution_scale_status"] != (sizeTable ? "exact" : "legacy_1x") ||
                (!sizeTable && (!(bool)scale["scale_exact"] || res["resolution_scale_reasons"].AsArray().Count == 0)))
                throw new InvalidOperationException("Production analysis disagrees with the authored capability configuration: " + name + " " + res.ToJsonString());
            var reads = DshCompiler.DrvReads(msl);
            var reflection = new Dictionary<string, object> {
                ["key"] = key + "_b", ["route"] = "B", ["chain"] = DshCompiler.Chain, ["stage"] = stageName,
                ["source"] = "authored ABI2 1x IR: " + name, ["entry"] = "main0",
                ["bindings"] = DshCompiler.Reflect(stageName, msl, res), ["drv_reads"] = reads, ["drv_unfillable"] = DshCompiler.Unfillable(reads),
                ["raster"] = DshCompiler.RasterFacts(stageName, msl), ["vertex_inputs"] = Array.Empty<object>(), ["vs_pad"] = Array.Empty<object>(),
                ["c1"] = "", ["notes"] = Array.Empty<string>(), ["frag_coord"] = program.Info.UsesFragCoord,
            };
            if (stage == ShaderStage.Vertex) reflection["entry_z"] = "main0_z";
            if (stage == ShaderStage.Compute) reflection["threadgroup_size"] = new[] { 1, 1, 1 };
            foreach (var field in scale) reflection[field.Key] = field.Value;
            File.WriteAllText(stem + ".res.json", res.ToJsonString(options));
            File.WriteAllText(stem + ".metal", stage == ShaderStage.Fragment ? DshCompiler.FsAlphaMs(msl) : msl);   // as production (Dsh.cs): the library's fragment main0 carries the optional S2A_AT / S2A_MSOFF constants (gap families 34 / 37); reflection reads the source without them
            File.WriteAllText(stem + ".json", JsonSerializer.Serialize(reflection, options));
            Run("xcrun", "-sdk", "macosx", "metal", "-c", "-fpreserve-invariance", stem + ".metal", "-o", stem + ".air");
            Run("xcrun", "-sdk", "macosx", "metallib", stem + ".air", "-o", stem + ".metallib"); File.Delete(stem + ".air");
            manifest[name] = new { key, stage = stageName, library = key + "_b.metallib", metadata = key + "_b.json" };
            map.Append("authored\t0\t").Append(stage == ShaderStage.Vertex ? "vertex" : stage == ShaderStage.Fragment ? "pixel" : "compute").Append('\t').Append(key).Append('\n');
        }
        File.WriteAllText(Path.Combine(output, "shader_map.tsv"), map.ToString());
        File.WriteAllText(Path.Combine(output, "manifest.json"), JsonSerializer.Serialize(new { chain = DshCompiler.Chain, gpu_executed = false, assets = manifest }, options));
        Console.WriteLine($"{manifest.Count} authored IR → production ABI2 analysis/reflection → Metal assets compiled; GPU untested: " + output);
    }
}
