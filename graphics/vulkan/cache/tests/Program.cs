using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using S2Arm.Backends.Vulkan.ProgramCache;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;

static class Tests
{
    private static int count;
    private static ProgramBinaryIdentity Identity = new("synthetic-unified-key-fixture", new('a', 64), new('b', 64), "synthetic-binding-v1");
    static void Check(bool ok, string name)
    {
        if (!ok)
            throw new Exception("FAIL: " + name);
        count++;
        Console.WriteLine("PASS " + name);
    }
    static void Reject(Action action, string code, string name)
    {
        try
        {
            action();
        }
        catch (ProgramBinaryException e) { Check(e.Code == code, name + " (" + e.Code + ")"); return; }
        throw new Exception("FAIL: accepted " + name);
    }
    static ResourceLayout Layout()
    {
        ResourceStages reserved = ResourceStages.Compute | ResourceStages.Vertex | ResourceStages.Fragment;
        ResourceDescriptorCollection[] ds = [
            new(Array.AsReadOnly(new[] { new ResourceDescriptor(0, 1, ResourceType.UniformBuffer, reserved) })),
            new(Array.AsReadOnly(new[] { new ResourceDescriptor(3, 1, ResourceType.StorageBuffer, ResourceStages.Compute) })),
            new(Array.AsReadOnly(Array.Empty<ResourceDescriptor>())),
            new(Array.AsReadOnly(new[] { new ResourceDescriptor(9, 4, ResourceType.Image, ResourceStages.Fragment) }))];
        ResourceUsageCollection[] us = [
            new(Array.AsReadOnly(new[] { new ResourceUsage(0, 1, ResourceType.UniformBuffer, reserved, false) })),
            new(Array.AsReadOnly(new[] { new ResourceUsage(3, 1, ResourceType.StorageBuffer, ResourceStages.Compute, true) })),
            new(Array.AsReadOnly(Array.Empty<ResourceUsage>())),
            new(Array.AsReadOnly(new[] { new ResourceUsage(9, 4, ResourceType.Image, ResourceStages.Fragment, true) }))];
        return new(Array.AsReadOnly(ds), Array.AsReadOnly(us));
    }
    static ProgramPipelineState State()
    {
        ProgramPipelineState s = new()
        {
            SamplesCount = 4,
            DepthStencilEnable = true,
            DepthStencilFormat = Format.D32Float,
            LogicOpEnable = true,
            LogicOp = LogicalOp.Xor,
            VertexAttribCount = 2,
            VertexBufferCount = 2,
            DepthTest = new(true, true, CompareOp.GreaterOrEqual),
            StencilTest = new(true, CompareOp.Less, StencilOp.Keep, StencilOp.Replace, StencilOp.IncrementAndClamp,
                13, 0x25, 0x39, CompareOp.Greater, StencilOp.Zero, StencilOp.DecrementAndClamp, StencilOp.Invert, 71, 0x51, 0x12),
            FrontFace = FrontFace.Clockwise,
            CullMode = Face.FrontAndBack,
            CullEnable = true,
            BiasEnable = PolygonModeMask.Fill | PolygonModeMask.Line,
            LineWidth = 1.75f,
            DepthClampEnable = true,
            RasterizerDiscard = true,
            Topology = PrimitiveTopology.TriangleStrip,
            PrimitiveRestartEnable = true,
            PatchControlPoints = 3,
            DepthMode = DepthMode.ZeroToOne
        };
        for (int i = 0; i < 8; i++)
        {
            s.AttachmentEnable[i] = (i % 2) == 0;
            s.AttachmentFormats[i] = Format.R8G8B8A8Unorm;
            s.ColorWriteMask[i] = (uint)(i + 1);
            s.BlendDescriptors[i] = new(true, new(i * .1f, .25f, -.5f, 1), BlendOp.ReverseSubtract,
                BlendFactor.SrcAlpha, BlendFactor.OneMinusSrcAlpha, BlendOp.Maximum, BlendFactor.One, BlendFactor.Zero);
        }
        for (int i = 0; i < 32; i++)
        {
            s.VertexAttribs[i] = new(i % 2, i * 4, i == 1, Format.R32Float);
            s.VertexBuffers[i] = new(i % 2 == 0, i * 16, i + 1);
        }
        return s;
    }
    static ProgramBinary Recipe(string root, bool graphics)
    {
        ShaderSource[] sources = graphics ? [new(File.ReadAllBytes(Path.Combine(root, "vertex.spv")), ShaderStage.Vertex, TargetLanguage.Spirv),
            new(File.ReadAllBytes(Path.Combine(root, "fragment.spv")), ShaderStage.Fragment, TargetLanguage.Spirv)] :
            [new(File.ReadAllBytes(Path.Combine(root, "compute.spv")), ShaderStage.Compute, TargetLanguage.Spirv)];
        ProgramBinaryStageSpecialization empty = new([], []);
        ProgramBinaryStageSpecialization[] specs = graphics ? [empty, new([new(11, 0, 4)], [0, 0, 0x40, 0x3f])] : [new([new(7, 4, 4)], [9, 8, 7, 6, 0x2a, 0, 0, 0])];
        ShaderInfo info = graphics ? new(0x12345678, Layout(), State(), true) : new(-1, Layout(), false);
        return new(Identity, new(false, false, false), sources, info, specs);
    }
    static void Equal(ProgramBinary a, ProgramBinary b)
    {
        Check(a.Identity == b.Identity, "W9 opaque identity retained");
        Check(a.Info.FragmentOutputMap == b.Info.FragmentOutputMap && a.Info.FromCache == b.Info.FromCache &&
            a.Info.State.HasValue == b.Info.State.HasValue, "ShaderInfo scalars/nullability");
        Check(a.Info.State.Equals(b.Info.State), "all ProgramPipelineState fields including dormant arrays");
        for (int i = 0; i < a.Sources.Length; i++)
        {
            Check(a.Sources[i].Stage == b.Sources[i].Stage && a.Sources[i].Language == b.Sources[i].Language &&
                a.Sources[i].BinaryCode.SequenceEqual(b.Sources[i].BinaryCode), "production ShaderSource " + i);
            Check(a.Specializations[i].Map.SequenceEqual(b.Specializations[i].Map) &&
                a.Specializations[i].Data.SequenceEqual(b.Specializations[i].Data), "specialization map/data " + i);
        }
        ResourceLayout x = a.Info.ResourceLayout, y = b.Info.ResourceLayout;
        Check(x.Sets.Count == y.Sets.Count && x.SetUsages.Count == y.SetUsages.Count, "set counts/empty sets");
        for (int s = 0; s < x.Sets.Count; s++)
        {
            Check(x.Sets[s].Descriptors.SequenceEqual(y.Sets[s].Descriptors), "descriptor values set" + s);
            Check(x.SetUsages[s].Usages.Count == y.SetUsages[s].Usages.Count && x.SetUsages[s].Usages.Zip(y.SetUsages[s].Usages)
                .All(pair => pair.First.Binding == pair.Second.Binding && pair.First.ArrayLength == pair.Second.ArrayLength &&
                    pair.First.Type == pair.Second.Type && pair.First.Stages == pair.Second.Stages && pair.First.Write == pair.Second.Write),
                "usage including Write set" + s); // GAL ResourceUsage.Equals omits Write; do not use it here.
        }
    }
    static byte[] Retag(byte[] input)
    {
        SHA256.HashData(input.AsSpan(48)).CopyTo(input, 16);
        return input;
    }
    static int Main(string[] args)
    {
        try
        {
            if (args.Length == 0) args = [Path.Combine(AppContext.BaseDirectory, "fixtures")];
            if (args.Length is < 1 or > 2 || (args.Length == 2 && args[1] != "--metadata-boundaries"))
                throw new Exception("usage: CodecTests <assembled-fixture-directory> [--metadata-boundaries]");
            if (args.Length == 2)
            {
                MetadataBoundaryTests.Run(Recipe(args[0], true));
                return 0;
            }
            foreach (bool graphics in new[] { false, true })
            {
                ProgramBinary p = Recipe(args[0], graphics);
                byte[] encoded = ProgramBinaryCodec.Encode(p);
                Equal(p, ProgramBinaryCodec.Decode(encoded, Identity));
                Check(encoded.SequenceEqual(ProgramBinaryCodec.Encode(ProgramBinaryCodec.Decode(encoded, Identity))), "deterministic full byte roundtrip");
                ProgramBinary snapshot = ProgramBinaryCodec.Capture(Identity, p.Options, p.Sources, p.Info, p.Specializations);
                p.Sources[0].BinaryCode[0] ^= 1;
                Check(snapshot.Sources[0].BinaryCode[0] == 3, "capture owns SPIR-V storage");
            }
            ProgramBinary compute = Recipe(args[0], false), graphicsRecipe = Recipe(args[0], true);
            byte[] valid = ProgramBinaryCodec.Encode(compute);
            Reject(() => ProgramBinaryCodec.Decode(valid, Identity with { ProfileKey = new('c', 64) }), "IDENTITY", "wrong expected profile");
            Reject(() => ProgramBinaryCodec.Decode(valid, Identity with { TranslationKey = new('c', 64) }), "IDENTITY", "wrong translation content identity");
            Reject(() => ProgramBinaryCodec.Decode(valid, Identity with { BindingAbi = "other" }), "IDENTITY", "wrong binding ABI");
            Reject(() => ProgramBinaryCodec.Encode(compute with { Identity = Identity with { Scheme = "invalid/scheme" } }), "IDENTITY", "malformed identity producer scheme");
            byte[] changed = (byte[])valid.Clone();
            changed[8] = 2;
            Reject(() => ProgramBinaryCodec.Decode(changed, Identity), "VERSION", "unknown envelope version");
            changed = (byte[])valid.Clone();
            changed[0] ^= 1;
            Reject(() => ProgramBinaryCodec.Decode(changed, Identity), "MAGIC", "unknown magic");
            changed = (byte[])valid.Clone();
            changed[^1] ^= 1;
            Reject(() => ProgramBinaryCodec.Decode(changed, Identity), "HASH", "same-length payload corruption");
            Reject(() => ProgramBinaryCodec.Decode(valid.Concat(new byte[1]).ToArray(), Identity), "LENGTH", "trailing byte");
            for (int n = 0; n < valid.Length; n++)
            {
                try
                {
                    ProgramBinaryCodec.Decode(valid.AsSpan(0, n), Identity);
                    throw new Exception("accepted truncation " + n);
                }
                catch (ProgramBinaryException) { }
            }
            Check(true, "every envelope truncation rejected");
            changed = valid.AsSpan(0, valid.Length - 1).ToArray();
            BitConverter.GetBytes(changed.Length - 48).CopyTo(changed, 12);
            Retag(changed);
            Reject(() => ProgramBinaryCodec.Decode(changed, Identity), "LENGTH", "rehashed partial metadata");
            Reject(() => ProgramBinaryCodec.Encode(compute with { Sources = [graphicsRecipe.Sources[0]] }), "STAGE", "vertex-only unsupported");
            Check(!ProgramBinaryCodec.TryEncode(compute with { Sources = [graphicsRecipe.Sources[0]] }, out _, out string saveError) &&
                saveError.StartsWith("STAGE"), "unsupported program stage set is a typed save miss");
            Reject(() => ProgramBinaryCodec.Encode(graphicsRecipe with { Sources = [graphicsRecipe.Sources[1], graphicsRecipe.Sources[0]] }), "STAGE", "reversed stage order");
            Reject(() => ProgramBinaryCodec.Encode(graphicsRecipe with { Sources = [graphicsRecipe.Sources[0], graphicsRecipe.Sources[0]] }), "STAGE", "duplicate stage");
            Reject(() => ProgramBinaryCodec.Encode(compute with { Sources = [new(compute.Sources[0].BinaryCode, ShaderStage.Geometry, TargetLanguage.Spirv)] }), "STAGE", "GS composite unsupported");
            Reject(() => ProgramBinaryCodec.Encode(compute with { Sources = [new(compute.Sources[0].BinaryCode, ShaderStage.Compute, TargetLanguage.Glsl)] }), "SPIRV", "GLSL not completed SPIR-V");
            Reject(() => ProgramBinaryCodec.Encode(compute with { Sources = [new(graphicsRecipe.Sources[0].BinaryCode, ShaderStage.Compute, TargetLanguage.Spirv)] }), "STAGE", "SPIR-V execution model mismatch");
            byte[] spv = (byte[])compute.Sources[0].BinaryCode.Clone();
            spv[20] = spv[21] = spv[22] = spv[23] = 0;
            Reject(() => ProgramBinaryCodec.Encode(compute with { Sources = [new(spv, ShaderStage.Compute, TargetLanguage.Spirv)] }), "SPIRV", "zero instruction count");
            Reject(() => ProgramBinaryCodec.Encode(compute with { Info = default }), "LAYOUT", "default ShaderInfo not complete");
            Reject(() => ProgramBinaryCodec.Encode(compute with { Specializations = [new([new(7, uint.MaxValue, 4)], [1, 2, 3, 4])] }), "SPECIALIZATION", "specialization extent overflow");
            Reject(() => ProgramBinaryCodec.Encode(compute with { Specializations = [new([new(8, 0, 4)], [1, 2, 3, 4])] }), "SPECIALIZATION", "unknown specialization ID");
            Reject(() => ProgramBinaryCodec.Encode(compute with { Specializations = [new([new(7, 0, 4), new(7, 0, 4)], [1, 2, 3, 4])] }), "SPECIALIZATION", "duplicate specialization ID");
            Reject(() => ProgramBinaryCodec.Encode(compute with { Options = new(true, false, false) }), "UNSUPPORTED", "minimal layout explicitly rejected");
            Reject(() => ProgramBinaryCodec.Encode(compute with { Options = new(false, true, false) }), "UNSUPPORTED", "transform feedback explicitly rejected");
            Reject(() => ProgramBinaryCodec.Encode(compute with { Options = new(false, false, true) }), "UNSUPPORTED", "composite explicitly rejected");
            Reject(() => ProgramBinaryCodec.Encode(compute with { Specializations = [new([new(7, 0, 2)], [0, 0])] }), "SPECIALIZATION", "scalar specialization type size mismatch");
            Reject(() => ProgramBinaryCodec.Encode(compute with { Info = new(-1, new ResourceLayout(null, null)) }), "LAYOUT", "null resource collections rejected");
            ProgramPipelineState bad = State();
            bad.VertexAttribCount = 33;
            Reject(() => ProgramBinaryCodec.Encode(graphicsRecipe with { Info = new(9, Layout(), bad) }), "METADATA", "vertex count overflow");
            bad = State();
            bad.Topology = (PrimitiveTopology)int.MaxValue;
            Reject(() => ProgramBinaryCodec.Encode(graphicsRecipe with { Info = new(9, Layout(), bad) }), "METADATA", "unknown pipeline enum");
            bad = State();
            bad.LineWidth = float.NaN;
            Reject(() => ProgramBinaryCodec.Encode(graphicsRecipe with { Info = new(9, Layout(), bad) }), "METADATA", "non-finite pipeline float");
            string fields = "AttachmentEnable AttachmentFormats BiasEnable BlendDescriptors ColorWriteMask CullEnable CullMode DepthClampEnable DepthMode DepthStencilEnable DepthStencilFormat DepthTest FrontFace LineWidth LogicOp LogicOpEnable PatchControlPoints PrimitiveRestartEnable RasterizerDiscard SamplesCount StencilTest Topology VertexAttribCount VertexAttribs VertexBufferCount VertexBuffers";
            Check(string.Join(" ", typeof(ProgramPipelineState).GetFields().Select(f => f.Name).Order()) == fields,
                "production pipeline field drift requires codec review");
            // A changed usage.Write bit must alter the byte identity even though GAL Equals ignores it.
            ResourceLayout old = Layout();
            ResourceUsageCollection[] changedUses = old.SetUsages.ToArray();
            changedUses[1] = new(Array.AsReadOnly(new[] { new ResourceUsage(3, 1, ResourceType.StorageBuffer, ResourceStages.Compute, false) }));
            ShaderInfo changedInfo = new(-1, new(old.Sets, Array.AsReadOnly(changedUses)), false);
            Check(!valid.SequenceEqual(ProgramBinaryCodec.Encode(compute with
            {
                Info = changedInfo
            })), "usage.Write changes cache bytes");
            // Regression: high bits of a disk int must not disappear when narrowed to byte-backed ResourceStages.
            using (BinaryReader offsets = new(new MemoryStream(valid, false)))
            {
                offsets.BaseStream.Position = 48;
                for (int i = 0; i < 4; i++)
                {
                    int tokenLength = offsets.ReadInt32();
                    offsets.BaseStream.Position += tokenLength;
                }
                offsets.BaseStream.Position += 3 + 4 + 1;
                int length = offsets.ReadInt32();
                offsets.BaseStream.Position += length;
                int maps = offsets.ReadInt32();
                offsets.BaseStream.Position += maps * 12;
                length = offsets.ReadInt32();
                offsets.BaseStream.Position += length;
                offsets.BaseStream.Position += 4 + 1 + 1 + 4 + 4 + 12;
                int position = (int)offsets.BaseStream.Position;
                changed = (byte[])valid.Clone();
                changed[position + 2] = 1;
                Retag(changed);
                Reject(() => ProgramBinaryCodec.Decode(changed, Identity), "LAYOUT", "resource stage high bits rejected before byte narrowing");
            }
            Random random = new(17);
            int acceptedProbes = 0, rejectedProbes = 0;
            for (int i = 0; i < 512; i++)
            {
                byte[] mutated = (byte[])valid.Clone();
                mutated[random.Next(48, mutated.Length)] ^= (byte)random.Next(1, 256);
                Retag(mutated);
                try
                {
                    ProgramBinary accepted = ProgramBinaryCodec.Decode(mutated, Identity);
                    if (!ProgramBinaryCodec.Encode(accepted).SequenceEqual(mutated))
                        throw new Exception("accepted mutation lost values");
                    acceptedProbes++;
                }
                catch (ProgramBinaryException) { rejectedProbes++; }
            }
            Check(acceptedProbes + rejectedProbes == 512, "512 rehashed payload probes: bounded typed failure or lossless acceptance");
            Console.WriteLine("MUTATIONS probes=512 accepted=" + acceptedProbes + " rejected=" + rejectedProbes);
            string infoProperties = string.Join(" ", typeof(ShaderInfo).GetProperties().Select(p => p.Name).Order());
            Check(infoProperties == "FragmentOutputMap FromCache ResourceLayout State", "production ShaderInfo field drift requires codec review");
            count += S1Tests.Run();
            count += S2Tests.Run();
            count += FrozenProfileTests.Run();
            count += MetadataBoundaryTests.Run(graphicsRecipe);
            Console.WriteLine("RESULT host_checks=" + count + " gpu_executed=false production_loader_connected=false");
            return 0;
        }
        catch (Exception e) { Console.Error.WriteLine(e); return 1; }
    }
}
