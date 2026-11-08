using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace S2Arm.Backends.Vulkan.ProgramCache;

public static class ProgramBinaryCodec
{
    public const int MaximumBytes = 16 * 1024 * 1024;
    private const int MaximumStageBytes = 4 * 1024 * 1024;
    private const int HeaderBytes = 48;
    private static readonly byte[] Magic = "S2VKPB01"u8.ToArray();

    public static byte[] Encode(ProgramBinary recipe)
    {
        Validate(recipe);
        using MemoryStream payload = new();
        using (BinaryWriter w = new(payload, Encoding.UTF8, true))
        {
            Identity(w, recipe.Identity);
            w.Write(recipe.Options.MinimalLayout);
            w.Write(recipe.Options.TransformFeedback);
            w.Write(recipe.Options.Composite);
            w.Write(recipe.Sources.Length);
            for (int i = 0; i < recipe.Sources.Length; i++)
            {
                ShaderSource s = recipe.Sources[i];
                w.Write((byte)s.Stage);
                Bytes(w, s.BinaryCode);
                ProgramBinaryStageSpecialization spec = recipe.Specializations[i];
                w.Write(spec.Map.Length);
                foreach (ProgramBinarySpecializationEntry entry in spec.Map)
                {
                    w.Write(entry.ConstantId);
                    w.Write(entry.Offset);
                    w.Write(entry.Size);
                }
                Bytes(w, spec.Data);
            }
            ProgramBinaryMetadata.Write(w, recipe.Info);
        }
        byte[] body = payload.ToArray();
        Require(body.Length <= MaximumBytes - HeaderBytes, "LIMIT", "recipe too large");
        using MemoryStream output = new();
        using BinaryWriter header = new(output);
        header.Write(Magic);
        header.Write(1u);
        header.Write(body.Length);
        header.Write(SHA256.HashData(body));
        header.Write(body);
        return output.ToArray();
    }

    public static bool TryEncode(ProgramBinary recipe, out byte[] binary, out string error)
    {
        try
        {
            binary = Encode(recipe);
            error = null;
            return true;
        }
        catch (ProgramBinaryException e)
        {
            binary = null;
            error = e.Code + ": " + e.Message;
            return false;
        }
    }

    public static bool TryDecode(ReadOnlySpan<byte> bytes, ProgramBinaryIdentity expected,
        out ProgramBinary program, out string error)
    {
        try
        {
            program = Decode(bytes, expected);
            error = null;
            return true;
        }
        catch (ProgramBinaryException e)
        {
            program = null;
            error = e.Code + ": " + e.Message;
            return false;
        }
    }

    public static ProgramBinary Decode(ReadOnlySpan<byte> bytes, ProgramBinaryIdentity expected)
    {
        ValidateIdentity(expected);
        Require(bytes.Length >= HeaderBytes && bytes.Length <= MaximumBytes, "LENGTH", "invalid envelope length");
        using MemoryStream stream = new(bytes.ToArray(), false);
        using BinaryReader r = new(stream, new UTF8Encoding(false, true));
        Require(r.ReadBytes(8).AsSpan().SequenceEqual(Magic), "MAGIC", "unknown program binary magic");
        Require(r.ReadUInt32() == 1, "VERSION", "unknown program binary version");
        int length = r.ReadInt32();
        Require(length == bytes.Length - HeaderBytes, "LENGTH", "payload length mismatch or trailing bytes");
        byte[] hash = r.ReadBytes(32);
        Require(CryptographicOperations.FixedTimeEquals(hash, SHA256.HashData(bytes[HeaderBytes..])), "HASH", "payload digest mismatch");
        try
        {
            ProgramBinaryIdentity identity = Identity(r);
            Require(identity == expected, "IDENTITY", "program identity/profile/binding ABI does not match");
            ProgramBinaryOptions options = new(ProgramBinaryMetadata.Bool(r), ProgramBinaryMetadata.Bool(r), ProgramBinaryMetadata.Bool(r));
            int count = Count(r, 5);
            Require(count is >= 1 and <= 5, "STAGE", "invalid stage count");
            ShaderSource[] sources = new ShaderSource[count];
            ProgramBinaryStageSpecialization[] specs = new ProgramBinaryStageSpecialization[count];
            for (int i = 0; i < count; i++)
            {
                ShaderStage stage = (ShaderStage)r.ReadByte();
                sources[i] = new ShaderSource(Bytes(r, MaximumStageBytes), stage, TargetLanguage.Spirv);
                int n = Count(r, 256);
                ProgramBinarySpecializationEntry[] entries = new ProgramBinarySpecializationEntry[n];
                for (int j = 0; j < n; j++)
                    entries[j] = new(r.ReadUInt32(), r.ReadUInt32(), r.ReadUInt32());
                specs[i] = new(entries, Bytes(r, 65536));
            }
            ShaderInfo info = ProgramBinaryMetadata.Read(r);
            Require(stream.Position == stream.Length, "LENGTH", "unconsumed recipe metadata");
            ProgramBinary result = new(identity, options, sources, info, specs);
            Validate(result);
            return result;
        }
        catch (EndOfStreamException) { throw new ProgramBinaryException("LENGTH", "truncated recipe metadata"); }
        catch (DecoderFallbackException) { throw new ProgramBinaryException("TEXT", "invalid identity text"); }
    }

    // Production GAL adapter. No Vk object or default ShaderInfo is fabricated.
    public static ProgramBinary Capture(ProgramBinaryIdentity identity, ProgramBinaryOptions options,
        ShaderSource[] sources, ShaderInfo info, ProgramBinaryStageSpecialization[] specializations)
    {
        ProgramBinary recipe = new(identity, options, sources, info, specializations);
        return Decode(Encode(recipe), identity); // owned deep snapshot; nullable state and all GAL fields preserved
    }

    private static void Validate(ProgramBinary p)
    {
        Require(p != null, "METADATA", "null recipe");
        ValidateIdentity(p.Identity);
        Require(p.Options != null && !p.Options.MinimalLayout && !p.Options.TransformFeedback && !p.Options.Composite,
            "UNSUPPORTED", "minimal/helper, TF and composite programs require a future recipe version");
        Require(p.Sources != null && p.Specializations != null && p.Sources.Length == p.Specializations.Length,
            "STAGE", "source/specialization count differs");
        bool compute = p.Sources.Length == 1 && p.Sources[0].Stage == ShaderStage.Compute;
        bool graphics = p.Sources.Length >= 2 && p.Sources[0].Stage == ShaderStage.Vertex &&
            p.Sources.Any(s => s.Stage == ShaderStage.Fragment) &&
            p.Sources.All(s => s.Stage != ShaderStage.Compute) &&
            p.Sources.Select(s => s.Stage).Distinct().Count() == p.Sources.Length;
        Require(compute || graphics, "STAGE", "supported stage sets are [compute] or a unique vertex-first graphics set");
        for (int i = 0; i < p.Sources.Length; i++)
        {
            ShaderSource s = p.Sources[i];
            Require(s.Language == TargetLanguage.Spirv && s.BinaryCode != null,
                "SPIRV", "completed binary SPIR-V is required; GLSL/async compilation is outside this codec");
            Dictionary<uint, uint> ids = ProgramBinarySpirv.Check(s.BinaryCode, s.Stage, MaximumStageBytes);
            ProgramBinaryStageSpecialization spec = p.Specializations[i];
            Require(spec?.Map != null && spec.Data != null && spec.Map.Length <= 256 && spec.Data.Length <= 65536,
                "SPECIALIZATION", "missing or oversized specialization");
            HashSet<uint> seen = new();
            foreach (ProgramBinarySpecializationEntry entry in spec.Map)
            {
                Require(entry != null && seen.Add(entry.ConstantId) && ids.ContainsKey(entry.ConstantId),
                    "SPECIALIZATION", "unknown/duplicate specialization constant id");
                Require(entry.Size == ids[entry.ConstantId] && (ulong)entry.Offset + entry.Size <= (ulong)spec.Data.Length,
                    "SPECIALIZATION", "specialization map exceeds owned data");
            }
            Require(spec.Map.Length != 0 || spec.Data.Length == 0, "SPECIALIZATION", "unreferenced specialization data");
        }
        ProgramBinaryMetadata.Validate(p.Info);
    }

    private static void ValidateIdentity(ProgramBinaryIdentity id)
    {
        Require(id != null && Token(id.Scheme), "IDENTITY", "identity producer scheme required");
        Require(Token(id.ProfileKey) && Token(id.TranslationKey), "IDENTITY", "validated opaque keys required");
        Require(id.BindingAbi != null && id.BindingAbi.Length is > 0 and <= 128 &&
            id.BindingAbi.All(c => char.IsAsciiLetterOrDigit(c) || "._:-".Contains(c)), "IDENTITY", "invalid binding ABI token");
    }

    private static bool Token(string s) => s != null && s.Length is > 0 and <= 128 &&
        s.All(c => char.IsAsciiLetterOrDigit(c) || "._:-".Contains(c));
    private static void Identity(BinaryWriter w, ProgramBinaryIdentity id)
    {
        Text(w, id.Scheme);
        Text(w, id.ProfileKey);
        Text(w, id.TranslationKey);
        Text(w, id.BindingAbi);
    }
    private static ProgramBinaryIdentity Identity(BinaryReader r) => new(Text(r), Text(r), Text(r), Text(r));
    private static void Text(BinaryWriter w, string s) => Bytes(w, Encoding.ASCII.GetBytes(s));
    private static string Text(BinaryReader r)
    {
        byte[] b = Bytes(r, 128);
        Require(b.All(x => x < 128), "TEXT", "non-ASCII identity token");
        return Encoding.ASCII.GetString(b);
    }
    internal static void Require(bool ok, string code, string message)
    {
        if (!ok)
            throw new ProgramBinaryException(code, message);
    }
    internal static int Count(BinaryReader r, int maximum)
    {
        int count = r.ReadInt32();
        Require(count >= 0 && count <= maximum, "LIMIT", "collection length outside local limits");
        return count;
    }
    private static void Bytes(BinaryWriter w, byte[] data)
    {
        w.Write(data.Length);
        w.Write(data);
    }
    private static byte[] Bytes(BinaryReader r, int maximum)
    {
        int count = Count(r, maximum);
        Require(count <= r.BaseStream.Length - r.BaseStream.Position, "LENGTH", "truncated byte section");
        return r.ReadBytes(count);
    }
}
