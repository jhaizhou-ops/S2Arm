using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace S2Arm.Backends.Vulkan.ProgramCache;

/// <summary>
/// Android Vulkan translation profile for VKPB records. The host file name keeps using
/// HostCacheCapabilities; this profile additionally pins the backend, SPIR-V target and
/// translator/codegen closure that the program bytes came from.
/// </summary>
public static class ProgramBinaryProfile
{
    public const string Scheme = "s2a-vkpb1";
    public const string BindingAbi = "gal-sets-1";
    public const string Backend = "vulkan";

    private const string ProfileMagic = "s2a-vkpb-profile-v1";

    /// <summary>Bounded canonical profile payload; the wire fields are fixed size plus one vendor name.</summary>
    public const int MaximumProfileBytes = 8192;

    public const int MaximumVendorLength = 64;

    // Every Capabilities field that can reach translation/codegen. MaximumGpuMemory is
    // deliberately excluded: memory pressure changes a budget, not generated code.
    private static readonly string[] SerializedFields =
    [
        nameof(Capabilities.Api), nameof(Capabilities.VendorName), nameof(Capabilities.MemoryType),
        nameof(Capabilities.HasFrontFacingBug), nameof(Capabilities.HasVectorIndexingBug),
        nameof(Capabilities.NeedsFragmentOutputSpecialization), nameof(Capabilities.ReduceShaderPrecision),
        nameof(Capabilities.SupportsAstcCompression), nameof(Capabilities.SupportsBc123Compression),
        nameof(Capabilities.SupportsBc45Compression), nameof(Capabilities.SupportsBc67Compression),
        nameof(Capabilities.SupportsEtc2Compression), nameof(Capabilities.Supports3DTextureCompression),
        nameof(Capabilities.SupportsBgraFormat), nameof(Capabilities.SupportsR4G4Format),
        nameof(Capabilities.SupportsR4G4B4A4Format), nameof(Capabilities.SupportsScaledVertexFormats),
        nameof(Capabilities.S2AVertexPull), nameof(Capabilities.SupportsSnormBufferTextureFormat),
        nameof(Capabilities.SupportsSparseBuffer), nameof(Capabilities.Supports5BitComponentFormat),
        nameof(Capabilities.SupportsBlendEquationAdvanced), nameof(Capabilities.SupportsFragmentShaderInterlock),
        nameof(Capabilities.SupportsFragmentShaderOrderingIntel), nameof(Capabilities.SupportsGeometryShader),
        nameof(Capabilities.SupportsGeometryShaderPassthrough), nameof(Capabilities.SupportsTransformFeedback),
        nameof(Capabilities.SupportsImageLoadFormatted), nameof(Capabilities.SupportsLayerVertexTessellation),
        nameof(Capabilities.SupportsMismatchingViewFormat), nameof(Capabilities.SupportsCubemapView),
        nameof(Capabilities.SupportsNonConstantTextureOffset), nameof(Capabilities.SupportsQuads),
        nameof(Capabilities.SupportsSeparateSampler), nameof(Capabilities.SupportsShaderBallot),
        nameof(Capabilities.SupportsShaderBarrierDivergence), nameof(Capabilities.SupportsShaderFloat64),
        nameof(Capabilities.SupportsShaderNonUniformIndexing), nameof(Capabilities.SupportsTextureGatherOffsets),
        nameof(Capabilities.SupportsTextureShadowLod), nameof(Capabilities.SupportsVertexStoreAndAtomics),
        nameof(Capabilities.SupportsViewportIndexVertexTessellation), nameof(Capabilities.SupportsViewportMask),
        nameof(Capabilities.SupportsViewportSwizzle), nameof(Capabilities.SupportsIndirectParameters),
        nameof(Capabilities.SupportsDepthClipControl), nameof(Capabilities.UniformBufferSetIndex),
        nameof(Capabilities.StorageBufferSetIndex), nameof(Capabilities.TextureSetIndex),
        nameof(Capabilities.ImageSetIndex), nameof(Capabilities.ExtraSetBaseIndex),
        nameof(Capabilities.MaximumExtraSets), nameof(Capabilities.MaximumUniformBuffersPerStage),
        nameof(Capabilities.MaximumStorageBuffersPerStage), nameof(Capabilities.MaximumTexturesPerStage),
        nameof(Capabilities.MaximumImagesPerStage), nameof(Capabilities.MaximumComputeSharedMemorySize),
        nameof(Capabilities.MaximumSupportedAnisotropy), nameof(Capabilities.ShaderSubgroupSize),
        nameof(Capabilities.StorageBufferOffsetAlignment), nameof(Capabilities.TextureBufferOffsetAlignment),
        nameof(Capabilities.GatherBiasPrecision), nameof(Capabilities.RequiresLinkedVaryingInterface),
        nameof(Capabilities.MaximumVertexOutputComponents), nameof(Capabilities.MaximumFragmentInputComponents),
        nameof(Capabilities.S2AStorageWindowClamp), nameof(Capabilities.S2AStorageOobRecord),
        nameof(Capabilities.UnsupportedUniformTexelBufferFormats),
        nameof(Capabilities.SupportsGeometryShaderOcclusionQuery),
        nameof(Capabilities.SupportsImageStoreFormatted),
        nameof(Capabilities.S2ASpirv15),
        nameof(Capabilities.S2ASpirvLayerExt), nameof(Capabilities.S2ASpirvLayerNv),
    ];

    // S2A (F1): optional trailing flags byte, written only when non-zero so profiles of hosts without the
    // storage-window clamp keep their exact bytes (and profile key). Bit 0 = clamp, bit 1 = OOB record.
    // #1456 bit 3 = GS+occlusion-query runtime capability: changes which shader set is generated
    // (hardware GS vs compute fallback), so it must rotate the program profile.
    private const byte StorageWindowClampFlag = 1;
    private const byte StorageOobRecordFlag = 2;
    // S2A (VUID-08737 根修): bit 2 = 宿主支持无格式存储图像写；为假（离线档/缺特性宿主）不追加字节。
    private const byte StoreWithoutFormatFlag = 4;
    private const byte GsOcclusionQueryFlag = 8;
    private const byte Spirv15Flag = 16;
    private const byte SpirvLayerExtFlag = 32;
    private const byte SpirvLayerNvFlag = 64;
    private const byte KnownFlags =
        StorageWindowClampFlag | StorageOobRecordFlag | StoreWithoutFormatFlag | GsOcclusionQueryFlag | Spirv15Flag | SpirvLayerExtFlag | SpirvLayerNvFlag;

    internal static string[] Fields => SerializedFields;

    public static bool Token(string value) => value is { Length: > 0 and <= 128 } &&
        value.All(c => char.IsAsciiLetterOrDigit(c) || "._:-".Contains(c));

    public static ProgramBinaryIdentity Create(in Capabilities capabilities, uint spirvVersion,
        string translatorClosure)
    {
        RequireClosure(translatorClosure);

        byte[] profile = SerializeProfile(in capabilities, spirvVersion);
        string profileKey = Hash(profile);
        string translationKey = Hash(Encoding.UTF8.GetBytes(
            $"s2a-vkpb-translation-v1|{Backend}|{BindingAbi}|{spirvVersion}|{translatorClosure}"));

        return new ProgramBinaryIdentity(Scheme, profileKey, translationKey, BindingAbi);
    }

    /// <summary>Explicit v2 domain; the historical v1 canonical payload/key stays unchanged.</summary>
    public static ProgramBinaryIdentity CreateFrozen(in Capabilities capabilities, uint spirvVersion,
        string translatorClosure, ComputeTranslationProfile selected, string gpuProducer, string ruleProducer)
    {
        ArgumentNullException.ThrowIfNull(selected);
        selected.RequireCapabilities(in capabilities);
        ProgramBinaryIdentity legacy = Create(in capabilities, spirvVersion, translatorClosure);
        string profileKey = Hash(Encoding.UTF8.GetBytes(
            $"s2a-vkpb-profile-v2|{legacy.ProfileKey}|{selected.ExecutionRulesHash}|{selected.SelectionKey}"));
        string translationKey = Hash(Encoding.UTF8.GetBytes(
            $"s2a-vkpb-translation-v2|{legacy.TranslationKey}|{gpuProducer}|{ruleProducer}"));
        return new ProgramBinaryIdentity(Scheme, profileKey, translationKey, BindingAbi);
    }

    internal static void RequireClosure(string translatorClosure)
    {
        if (string.IsNullOrEmpty(translatorClosure) || translatorClosure.Length > 256)
            throw new ProgramBinaryException("PROFILE", "A bounded translator/codegen closure is required.");
    }

    /// <summary>
    /// Canonical bytes covered by the profile key. Runtime export, the offline producer and
    /// the host tests all use this one serializer, so a profile cannot describe one
    /// capability set while hashing another.
    /// </summary>
    public static byte[] SerializeProfile(in Capabilities capabilities, uint spirvVersion)
    {
        Require(!capabilities.S2ASpirv15 || spirvVersion >= 0x00402000u, "PROFILE",
            "SPIR-V 1.5 output requires a Vulkan 1.2 target");
        using MemoryStream profileStream = new();
        using (BinaryWriter writer = new(profileStream, Encoding.UTF8, true))
        {
            writer.Write(ProfileMagic);
            writer.Write(Backend);
            writer.Write(spirvVersion);
            WriteCapabilities(writer, in capabilities);
        }

        return profileStream.ToArray();
    }

    /// <summary>
    /// Strict inverse of <see cref="SerializeProfile"/>. Bounds are applied before the
    /// capabilities constructor so a hostile profile file cannot reach translation and the
    /// host cache with impossible limits.
    /// </summary>
    public static bool TryReadProfile(ReadOnlySpan<byte> profile, out Capabilities capabilities,
        out uint spirvVersion, out string error)
    {
        capabilities = default;
        spirvVersion = 0;

        try
        {
            Require(profile.Length > 0 && profile.Length <= MaximumProfileBytes, "PROFILE",
                "profile length out of range");
            using MemoryStream stream = new(profile.ToArray(), writable: false);
            using BinaryReader reader = new(stream, Encoding.UTF8, true);

            Require(ReadText(reader, 64) == ProfileMagic, "PROFILE", "profile magic mismatch");
            Require(ReadText(reader, 32) == Backend, "PROFILE", "profile backend mismatch");
            spirvVersion = reader.ReadUInt32();

            TargetApi api = (TargetApi)reader.ReadInt32();
            Require(Enum.IsDefined(api), "PROFILE", "unknown target API");

            string vendor = ReadText(reader, MaximumVendorLength);
            Require(vendor.Length > 0, "PROFILE", "empty vendor name");
            foreach (char c in vendor)
                Require(c is >= ' ' and <= '~' && c != ' ', "PROFILE", "vendor name is not printable filename text");

            SystemMemoryType memoryType = (SystemMemoryType)reader.ReadInt32();
            Require(Enum.IsDefined(memoryType), "PROFILE", "unknown system memory type");

            bool hasFrontFacingBug = ReadBool(reader);
            bool hasVectorIndexingBug = ReadBool(reader);
            bool needsFragmentOutputSpecialization = ReadBool(reader);
            bool reduceShaderPrecision = ReadBool(reader);
            bool supportsAstcCompression = ReadBool(reader);
            bool supportsBc123Compression = ReadBool(reader);
            bool supportsBc45Compression = ReadBool(reader);
            bool supportsBc67Compression = ReadBool(reader);
            bool supportsEtc2Compression = ReadBool(reader);
            bool supports3DTextureCompression = ReadBool(reader);
            bool supportsBgraFormat = ReadBool(reader);
            bool supportsR4G4Format = ReadBool(reader);
            bool supportsR4G4B4A4Format = ReadBool(reader);
            bool supportsScaledVertexFormats = ReadBool(reader);
            bool s2aVertexPull = ReadBool(reader);
            bool supportsSnormBufferTextureFormat = ReadBool(reader);
            bool supportsSparseBuffer = ReadBool(reader);
            bool supports5BitComponentFormat = ReadBool(reader);
            bool supportsBlendEquationAdvanced = ReadBool(reader);
            bool supportsFragmentShaderInterlock = ReadBool(reader);
            bool supportsFragmentShaderOrderingIntel = ReadBool(reader);
            bool supportsGeometryShader = ReadBool(reader);
            bool supportsGeometryShaderPassthrough = ReadBool(reader);
            bool supportsTransformFeedback = ReadBool(reader);
            bool supportsImageLoadFormatted = ReadBool(reader);
            bool supportsLayerVertexTessellation = ReadBool(reader);
            bool supportsMismatchingViewFormat = ReadBool(reader);
            bool supportsCubemapView = ReadBool(reader);
            bool supportsNonConstantTextureOffset = ReadBool(reader);
            bool supportsQuads = ReadBool(reader);
            bool supportsSeparateSampler = ReadBool(reader);
            bool supportsShaderBallot = ReadBool(reader);
            bool supportsShaderBarrierDivergence = ReadBool(reader);
            bool supportsShaderFloat64 = ReadBool(reader);
            bool supportsShaderNonUniformIndexing = ReadBool(reader);
            bool supportsTextureGatherOffsets = ReadBool(reader);
            bool supportsTextureShadowLod = ReadBool(reader);
            bool supportsVertexStoreAndAtomics = ReadBool(reader);
            bool supportsViewportIndexVertexTessellation = ReadBool(reader);
            bool supportsViewportMask = ReadBool(reader);
            bool supportsViewportSwizzle = ReadBool(reader);
            bool supportsIndirectParameters = ReadBool(reader);
            bool supportsDepthClipControl = ReadBool(reader);

            int uniformBufferSetIndex = ReadSetIndex(reader, "uniform buffer");
            int storageBufferSetIndex = ReadSetIndex(reader, "storage buffer");
            int textureSetIndex = ReadSetIndex(reader, "texture");
            int imageSetIndex = ReadSetIndex(reader, "image");
            int extraSetBaseIndex = ReadSetIndex(reader, "extra set base");
            int maximumExtraSets = ReadRange(reader.ReadInt32(), 0, 1024, "maximum extra sets");

            uint maximumUniformBuffersPerStage = ReadCount(reader.ReadUInt32(), "uniform buffers per stage");
            uint maximumStorageBuffersPerStage = ReadCount(reader.ReadUInt32(), "storage buffers per stage");
            uint maximumTexturesPerStage = ReadCount(reader.ReadUInt32(), "textures per stage");
            uint maximumImagesPerStage = ReadCount(reader.ReadUInt32(), "images per stage");
            int maximumComputeSharedMemorySize = ReadRange(reader.ReadInt32(), 0, 16 * 1024 * 1024,
                "maximum compute shared memory");

            float maximumSupportedAnisotropy = BitConverter.Int32BitsToSingle(reader.ReadInt32());
            Require(float.IsFinite(maximumSupportedAnisotropy) && maximumSupportedAnisotropy is >= 0 and <= 64,
                "PROFILE", "maximum anisotropy out of range");

            int shaderSubgroupSize = ReadRange(reader.ReadInt32(), 1, 256, "shader subgroup size");
            int storageBufferOffsetAlignment = ReadRange(reader.ReadInt32(), 1, 1 << 20, "storage buffer alignment");
            int textureBufferOffsetAlignment = ReadRange(reader.ReadInt32(), 1, 1 << 20, "texture buffer alignment");
            int gatherBiasPrecision = ReadRange(reader.ReadInt32(), -32, 64, "gather bias precision");

            // Appended fields: an older profile ends before these reads and is rejected as
            // truncated instead of being interpreted with a shifted field layout.
            bool requiresLinkedVaryingInterface = ReadBool(reader);
            int maximumVertexOutputComponents = ReadRange(reader.ReadInt32(), 0, 1 << 20,
                "maximum vertex output components");
            int maximumFragmentInputComponents = ReadRange(reader.ReadInt32(), 0, 1 << 20,
                "maximum fragment input components");

            bool s2aStorageWindowClamp = false;
            bool s2aStorageOobRecord = false;
            bool supportsGeometryShaderOcclusionQuery = false;
            bool storeWithoutFormat = false;
            bool s2aSpirv15 = false;
            bool s2aSpirvLayerExt = false, s2aSpirvLayerNv = false;

            if (stream.Position < stream.Length)
            {
                byte flags = reader.ReadByte();
                // clamp/oob 两位沿用原约束：OOB 记录必须以 clamp 为前提（{0,1,3}，不许单独 2）；
                // store-without-format（位 2）与 gs+遮挡（位 3）独立自由；
                // flags==0 仅在后面还跟不支持格式段时合法（写出端为保持段头一致也会落一个 0）。
                Require((flags & (StorageWindowClampFlag | StorageOobRecordFlag)) is 0 or StorageWindowClampFlag or (StorageWindowClampFlag | StorageOobRecordFlag)
                        && (flags & ~KnownFlags) == 0
                        && (flags != 0 || stream.Position < stream.Length), "PROFILE",
                    "storage window flags are not canonical");
                s2aStorageWindowClamp = (flags & StorageWindowClampFlag) != 0;
                s2aStorageOobRecord = (flags & StorageOobRecordFlag) != 0;
                supportsGeometryShaderOcclusionQuery = (flags & GsOcclusionQueryFlag) != 0;
                storeWithoutFormat = (flags & StoreWithoutFormatFlag) != 0;
                s2aSpirv15 = (flags & Spirv15Flag) != 0;
                s2aSpirvLayerExt = (flags & SpirvLayerExtFlag) != 0;
                s2aSpirvLayerNv = (flags & SpirvLayerNvFlag) != 0;
            }

            Format[] unsupportedUniformTexel = null;
            if (stream.Position < stream.Length)
            {
                int count = ReadRange(reader.ReadUInt16(), 0, VertexTexelFormats.All.Length,
                    "unsupported uniform texel format count");
                unsupportedUniformTexel = new Format[count];
                for (int i = 0; i < count; i++)
                {
                    unsupportedUniformTexel[i] = (Format)reader.ReadInt32();
                    Require(Enum.IsDefined(unsupportedUniformTexel[i]) &&
                        Array.IndexOf(VertexTexelFormats.All, unsupportedUniformTexel[i]) >= 0, "PROFILE",
                        "unsupported uniform texel format is not a vertex texel format");
                }
            }

            Require(stream.Position == stream.Length, "PROFILE", "trailing bytes after the profile");
            Require(!s2aSpirv15 || spirvVersion >= 0x00402000u, "PROFILE",
                "SPIR-V 1.5 output requires a Vulkan 1.2 target");

            capabilities = new Capabilities(
                api,
                vendor,
                memoryType,
                hasFrontFacingBug,
                hasVectorIndexingBug,
                needsFragmentOutputSpecialization,
                reduceShaderPrecision,
                supportsAstcCompression,
                supportsBc123Compression,
                supportsBc45Compression,
                supportsBc67Compression,
                supportsEtc2Compression,
                supports3DTextureCompression,
                supportsBgraFormat,
                supportsR4G4Format,
                supportsR4G4B4A4Format,
                supportsScaledVertexFormats,
                supportsSnormBufferTextureFormat,
                supports5BitComponentFormat,
                supportsSparseBuffer,
                supportsBlendEquationAdvanced,
                supportsFragmentShaderInterlock,
                supportsFragmentShaderOrderingIntel,
                supportsGeometryShader,
                supportsGeometryShaderPassthrough,
                supportsTransformFeedback,
                supportsImageLoadFormatted,
                supportsLayerVertexTessellation,
                supportsMismatchingViewFormat,
                supportsCubemapView,
                supportsNonConstantTextureOffset,
                supportsQuads,
                supportsSeparateSampler,
                supportsShaderBallot,
                supportsShaderBarrierDivergence,
                supportsShaderFloat64,
                supportsShaderNonUniformIndexing,
                supportsTextureGatherOffsets,
                supportsTextureShadowLod,
                supportsVertexStoreAndAtomics,
                supportsViewportIndexVertexTessellation,
                supportsViewportMask,
                supportsViewportSwizzle,
                supportsIndirectParameters,
                supportsDepthClipControl,
                uniformBufferSetIndex,
                storageBufferSetIndex,
                textureSetIndex,
                imageSetIndex,
                extraSetBaseIndex,
                maximumExtraSets,
                maximumUniformBuffersPerStage,
                maximumStorageBuffersPerStage,
                maximumTexturesPerStage,
                maximumImagesPerStage,
                maximumComputeSharedMemorySize,
                maximumSupportedAnisotropy,
                shaderSubgroupSize,
                storageBufferOffsetAlignment,
                textureBufferOffsetAlignment,
                gatherBiasPrecision,
                0,
                s2aVertexPull,
                requiresLinkedVaryingInterface,
                maximumVertexOutputComponents,
                maximumFragmentInputComponents,
                s2aStorageWindowClamp,
                s2aStorageOobRecord,
                unsupportedUniformTexel,
                supportsGeometryShaderOcclusionQuery,
                supportsImageStoreFormatted: storeWithoutFormat,
                s2aSpirv15: s2aSpirv15,
                s2aSpirvLayerExt: s2aSpirvLayerExt,
                s2aSpirvLayerNv: s2aSpirvLayerNv);

            error = null;
            return true;
        }
        catch (ProgramBinaryException e)
        {
            error = e.Code + ": " + e.Message;
            capabilities = default;
            return false;
        }
        catch (EndOfStreamException)
        {
            error = "PROFILE: truncated profile";
            capabilities = default;
            return false;
        }
        catch (FormatException)
        {
            error = "PROFILE: malformed string field";
            capabilities = default;
            return false;
        }
    }

    private static void WriteCapabilities(BinaryWriter writer, in Capabilities c)
    {
        writer.Write((int)c.Api);
        writer.Write(c.VendorName ?? string.Empty);
        writer.Write((int)c.MemoryType);
        writer.Write(c.HasFrontFacingBug);
        writer.Write(c.HasVectorIndexingBug);
        writer.Write(c.NeedsFragmentOutputSpecialization);
        writer.Write(c.ReduceShaderPrecision);
        writer.Write(c.SupportsAstcCompression);
        writer.Write(c.SupportsBc123Compression);
        writer.Write(c.SupportsBc45Compression);
        writer.Write(c.SupportsBc67Compression);
        writer.Write(c.SupportsEtc2Compression);
        writer.Write(c.Supports3DTextureCompression);
        writer.Write(c.SupportsBgraFormat);
        writer.Write(c.SupportsR4G4Format);
        writer.Write(c.SupportsR4G4B4A4Format);
        writer.Write(c.SupportsScaledVertexFormats);
        writer.Write(c.S2AVertexPull);
        writer.Write(c.SupportsSnormBufferTextureFormat);
        writer.Write(c.SupportsSparseBuffer);
        writer.Write(c.Supports5BitComponentFormat);
        writer.Write(c.SupportsBlendEquationAdvanced);
        writer.Write(c.SupportsFragmentShaderInterlock);
        writer.Write(c.SupportsFragmentShaderOrderingIntel);
        writer.Write(c.SupportsGeometryShader);
        writer.Write(c.SupportsGeometryShaderPassthrough);
        writer.Write(c.SupportsTransformFeedback);
        writer.Write(c.SupportsImageLoadFormatted);
        writer.Write(c.SupportsLayerVertexTessellation);
        writer.Write(c.SupportsMismatchingViewFormat);
        writer.Write(c.SupportsCubemapView);
        writer.Write(c.SupportsNonConstantTextureOffset);
        writer.Write(c.SupportsQuads);
        writer.Write(c.SupportsSeparateSampler);
        writer.Write(c.SupportsShaderBallot);
        writer.Write(c.SupportsShaderBarrierDivergence);
        writer.Write(c.SupportsShaderFloat64);
        writer.Write(c.SupportsShaderNonUniformIndexing);
        writer.Write(c.SupportsTextureGatherOffsets);
        writer.Write(c.SupportsTextureShadowLod);
        writer.Write(c.SupportsVertexStoreAndAtomics);
        writer.Write(c.SupportsViewportIndexVertexTessellation);
        writer.Write(c.SupportsViewportMask);
        writer.Write(c.SupportsViewportSwizzle);
        writer.Write(c.SupportsIndirectParameters);
        writer.Write(c.SupportsDepthClipControl);
        writer.Write(c.UniformBufferSetIndex);
        writer.Write(c.StorageBufferSetIndex);
        writer.Write(c.TextureSetIndex);
        writer.Write(c.ImageSetIndex);
        writer.Write(c.ExtraSetBaseIndex);
        writer.Write(c.MaximumExtraSets);
        writer.Write(c.MaximumUniformBuffersPerStage);
        writer.Write(c.MaximumStorageBuffersPerStage);
        writer.Write(c.MaximumTexturesPerStage);
        writer.Write(c.MaximumImagesPerStage);
        writer.Write(c.MaximumComputeSharedMemorySize);
        writer.Write(c.MaximumSupportedAnisotropy);
        writer.Write(c.ShaderSubgroupSize);
        writer.Write(c.StorageBufferOffsetAlignment);
        writer.Write(c.TextureBufferOffsetAlignment);
        writer.Write(c.GatherBiasPrecision);
        writer.Write(c.RequiresLinkedVaryingInterface);
        writer.Write(c.MaximumVertexOutputComponents);
        writer.Write(c.MaximumFragmentInputComponents);

        byte flags = (byte)((c.S2AStorageWindowClamp ? StorageWindowClampFlag : 0) | (c.S2AStorageOobRecord ? StorageOobRecordFlag : 0) | (c.SupportsImageStoreFormatted ? StoreWithoutFormatFlag : 0) | (c.SupportsGeometryShaderOcclusionQuery ? GsOcclusionQueryFlag : 0) | (c.S2ASpirv15 ? Spirv15Flag : 0) | (c.S2ASpirvLayerExt ? SpirvLayerExtFlag : 0) | (c.S2ASpirvLayerNv ? SpirvLayerNvFlag : 0));

        // 追加段只在有内容时写出：全支持 texel 的宿主字节与改前相同；段头先写 flags
        //   保证读取器总能按 flags-then-array 解析。
        if (flags != 0 || c.UnsupportedUniformTexelBufferFormats is { Length: > 0 })
        {
            writer.Write(flags);
        }

        if (c.UnsupportedUniformTexelBufferFormats is { Length: > 0 } unsupportedTexel)
        {
            writer.Write((ushort)unsupportedTexel.Length);
            foreach (Format format in unsupportedTexel)
            {
                writer.Write((int)format);
            }
        }
    }

    private static string ReadText(BinaryReader reader, int maximumBytes)
    {
        string text = reader.ReadString();
        Require(text.Length > 0 && text.Length <= maximumBytes, "PROFILE", "text field length out of range");
        return text;
    }

    private static bool ReadBool(BinaryReader reader)
    {
        byte value = reader.ReadByte();
        Require(value is 0 or 1, "PROFILE", "non-canonical boolean");
        return value != 0;
    }

    private static int ReadSetIndex(BinaryReader reader, string field) =>
        ReadRange(reader.ReadInt32(), -1, 1024, field + " set index");

    private static int ReadRange(int value, int minimum, int maximum, string field) =>
        value >= minimum && value <= maximum
            ? value
            : throw new ProgramBinaryException("PROFILE", field + " out of range");

    private static uint ReadCount(uint value, string field) =>
        value <= 65536 ? value : throw new ProgramBinaryException("PROFILE", field + " out of range");

    private static void Require(bool condition, string code, string message)
    {
        if (!condition) throw new ProgramBinaryException(code, message);
    }

    private static string Hash(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
}
