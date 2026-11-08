using Ryujinx.Graphics.GAL;
using System;
using System.Threading;

namespace S2Arm.Backends.Vulkan.ProgramCache;

/// <summary>One initialized device's selected profile; never reused for a rebuilt device.</summary>
public sealed class ProgramBinaryProfileSnapshot
{
    private readonly object _owner;
    private int _retired;
    public VulkanProfile Profile { get; }

    public ProgramBinaryProfileSnapshot(object owner, VulkanProfile profile)
    {
        _owner = owner ?? throw new ArgumentNullException(nameof(owner));
        Profile = profile ?? throw new ArgumentNullException(nameof(profile));
        if (!profile.IsFrozen) throw new ArgumentException("A frozen profile is required.", nameof(profile));
    }

    public VulkanProfile RequireCurrent(object owner)
    {
        if (Volatile.Read(ref _retired) != 0 || !ReferenceEquals(_owner, owner))
            throw new InvalidOperationException("The Vulkan translation profile belongs to a retired/different device generation.");
        return Profile;
    }

    public void Retire(object owner)
    {
        _ = RequireCurrent(owner);
        Interlocked.Exchange(ref _retired, 1);
    }

    // The translation fields are pinned. Runtime resource capacity remains independent and
    // is intentionally absent from ProgramBinaryProfile's canonical capability payload.
    public Capabilities Capabilities(object owner, ulong maximumGpuMemory)
    {
        Capabilities c = RequireCurrent(owner).Capabilities;
        return WithMemoryBudget(in c, maximumGpuMemory);
    }

    internal static Capabilities WithMemoryBudget(in Capabilities c, ulong maximumGpuMemory) => new(
        api: c.Api,
        vendorName: c.VendorName,
        memoryType: c.MemoryType,
        hasFrontFacingBug: c.HasFrontFacingBug,
        hasVectorIndexingBug: c.HasVectorIndexingBug,
        needsFragmentOutputSpecialization: c.NeedsFragmentOutputSpecialization,
        reduceShaderPrecision: c.ReduceShaderPrecision,
        supportsAstcCompression: c.SupportsAstcCompression,
        supportsBc123Compression: c.SupportsBc123Compression,
        supportsBc45Compression: c.SupportsBc45Compression,
        supportsBc67Compression: c.SupportsBc67Compression,
        supportsEtc2Compression: c.SupportsEtc2Compression,
        supports3DTextureCompression: c.Supports3DTextureCompression,
        supportsBgraFormat: c.SupportsBgraFormat,
        supportsR4G4Format: c.SupportsR4G4Format,
        supportsR4G4B4A4Format: c.SupportsR4G4B4A4Format,
        supportsScaledVertexFormats: c.SupportsScaledVertexFormats,
        supportsSnormBufferTextureFormat: c.SupportsSnormBufferTextureFormat,
        supports5BitComponentFormat: c.Supports5BitComponentFormat,
        supportsSparseBuffer: c.SupportsSparseBuffer,
        supportsBlendEquationAdvanced: c.SupportsBlendEquationAdvanced,
        supportsFragmentShaderInterlock: c.SupportsFragmentShaderInterlock,
        supportsFragmentShaderOrderingIntel: c.SupportsFragmentShaderOrderingIntel,
        supportsGeometryShader: c.SupportsGeometryShader,
        supportsGeometryShaderPassthrough: c.SupportsGeometryShaderPassthrough,
        supportsTransformFeedback: c.SupportsTransformFeedback,
        supportsImageLoadFormatted: c.SupportsImageLoadFormatted,
        supportsLayerVertexTessellation: c.SupportsLayerVertexTessellation,
        supportsMismatchingViewFormat: c.SupportsMismatchingViewFormat,
        supportsCubemapView: c.SupportsCubemapView,
        supportsNonConstantTextureOffset: c.SupportsNonConstantTextureOffset,
        supportsQuads: c.SupportsQuads,
        supportsSeparateSampler: c.SupportsSeparateSampler,
        supportsShaderBallot: c.SupportsShaderBallot,
        supportsShaderBarrierDivergence: c.SupportsShaderBarrierDivergence,
        supportsShaderFloat64: c.SupportsShaderFloat64,
        supportsShaderNonUniformIndexing: c.SupportsShaderNonUniformIndexing,
        supportsTextureGatherOffsets: c.SupportsTextureGatherOffsets,
        supportsTextureShadowLod: c.SupportsTextureShadowLod,
        supportsVertexStoreAndAtomics: c.SupportsVertexStoreAndAtomics,
        supportsViewportIndexVertexTessellation: c.SupportsViewportIndexVertexTessellation,
        supportsViewportMask: c.SupportsViewportMask,
        supportsViewportSwizzle: c.SupportsViewportSwizzle,
        supportsIndirectParameters: c.SupportsIndirectParameters,
        supportsDepthClipControl: c.SupportsDepthClipControl,
        uniformBufferSetIndex: c.UniformBufferSetIndex,
        storageBufferSetIndex: c.StorageBufferSetIndex,
        textureSetIndex: c.TextureSetIndex,
        imageSetIndex: c.ImageSetIndex,
        extraSetBaseIndex: c.ExtraSetBaseIndex,
        maximumExtraSets: c.MaximumExtraSets,
        maximumUniformBuffersPerStage: c.MaximumUniformBuffersPerStage,
        maximumStorageBuffersPerStage: c.MaximumStorageBuffersPerStage,
        maximumTexturesPerStage: c.MaximumTexturesPerStage,
        maximumImagesPerStage: c.MaximumImagesPerStage,
        maximumComputeSharedMemorySize: c.MaximumComputeSharedMemorySize,
        maximumSupportedAnisotropy: c.MaximumSupportedAnisotropy,
        shaderSubgroupSize: c.ShaderSubgroupSize,
        storageBufferOffsetAlignment: c.StorageBufferOffsetAlignment,
        textureBufferOffsetAlignment: c.TextureBufferOffsetAlignment,
        gatherBiasPrecision: c.GatherBiasPrecision,
        maximumGpuMemory: maximumGpuMemory,
        s2aVertexPull: c.S2AVertexPull,
        requiresLinkedVaryingInterface: c.RequiresLinkedVaryingInterface,
        maximumVertexOutputComponents: c.MaximumVertexOutputComponents,
        maximumFragmentInputComponents: c.MaximumFragmentInputComponents,
        s2aStorageWindowClamp: c.S2AStorageWindowClamp,
        s2aStorageOobRecord: c.S2AStorageOobRecord,
        unsupportedUniformTexelBufferFormats: c.UnsupportedUniformTexelBufferFormats,
        supportsGeometryShaderOcclusionQuery: c.SupportsGeometryShaderOcclusionQuery,
        supportsImageStoreFormatted: c.SupportsImageStoreFormatted,
        s2aSpirv15: c.S2ASpirv15,
        s2aSpirvLayerExt: c.S2ASpirvLayerExt,
        s2aSpirvLayerNv: c.S2ASpirvLayerNv);
}
