using Ryujinx.Graphics.Shader;
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Text;
using static S2Arm.Backends.Vulkan.ProgramCache.ProgramBinaryCodec;

namespace S2Arm.Backends.Vulkan.ProgramCache;

// Bounded framing/entry-point checks only. A semantic SPIR-V validator remains required upstream.
internal static class ProgramBinarySpirv
{
    internal static Dictionary<uint, uint> Check(byte[] bytes, ShaderStage stage, int maximum)
    {
        Require(bytes.Length >= 20 && bytes.Length <= maximum && bytes.Length % 4 == 0,
            "SPIRV", "invalid SPIR-V length");
        uint Word(int n) => BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(n * 4, 4));
        Require(Word(0) == 0x07230203 && Word(1) >= 0x00010000 && Word(1) <= 0x00010600 &&
            (Word(1) & 0xff) == 0 && Word(3) > 0 && Word(4) == 0, "SPIRV", "unsupported SPIR-V header");
        uint model = stage switch
        {
            ShaderStage.Vertex => 0u,
            ShaderStage.TessellationControl => 1u,
            ShaderStage.TessellationEvaluation => 2u,
            ShaderStage.Geometry => 3u,
            ShaderStage.Fragment => 4u,
            ShaderStage.Compute => 5u,
            _ => 0xffffffff
        };
        int entries = 0;
        Require(model != 0xffffffff, "STAGE", "unsupported shader stage");
        Dictionary<uint, uint> specTargets = new(), specTypes = new(), typeSizes = new();
        for (int i = 5; i < bytes.Length / 4;)
        {
            uint head = Word(i);
            int count = (int)(head >> 16), op = (int)(head & 65535);
            Require(count > 0 && count <= bytes.Length / 4 - i, "SPIRV", "invalid instruction span");
            if (op == 15) // OpEntryPoint
            {
                Require(count >= 4 && Word(i + 1) == model && Word(i + 2) < Word(3), "STAGE", "SPIR-V execution model mismatch");
                ReadOnlySpan<byte> literal = bytes.AsSpan((i + 3) * 4, (count - 3) * 4);
                int end = literal.IndexOf((byte)0);
                Require(end == 4 && Encoding.ASCII.GetString(literal[..end]) == "main", "STAGE", "only a single main entry point is supported");
                entries++;
            }
            if (op == 71 && count >= 3 && Word(i + 2) == 1) // OpDecorate SpecId
            {
                Require(count == 4 && specTargets.TryAdd(Word(i + 3), Word(i + 1)),
                    "SPECIALIZATION", "invalid/duplicate SpecId decoration");
            }
            if (op == 20 && count == 2)
                typeSizes[Word(i + 1)] = 4; // OpTypeBool: VkBool32
            if ((op == 21 && count == 4) || (op == 22 && count == 3))
            {
                uint width = Word(i + 2);
                if (width is 16 or 32 or 64)
                    typeSizes[Word(i + 1)] = width / 8;
            }
            if (op is 48 or 49 or 50 or 52 && count >= 3)
                specTypes[Word(i + 2)] = Word(i + 1);
            i += count;
        }
        Require(entries == 1, "STAGE", "one entry point required");
        Dictionary<uint, uint> sizes = new();
        foreach ((uint id, uint target) in specTargets)
        {
            Require(specTypes.TryGetValue(target, out uint type) && typeSizes.TryGetValue(type, out uint size),
                "SPECIALIZATION", "SpecId must name a supported scalar specialization constant");
            sizes[id] = typeSizes[type];
        }
        return sizes;
    }
}
