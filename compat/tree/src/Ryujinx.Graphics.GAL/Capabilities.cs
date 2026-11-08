using Ryujinx.Graphics.Shader.Translation;

namespace Ryujinx.Graphics.GAL
{
    public readonly struct Capabilities
    {
        public readonly TargetApi Api;
        public readonly string VendorName;
        public readonly SystemMemoryType MemoryType;

        public readonly bool HasFrontFacingBug;
        public readonly bool HasVectorIndexingBug;
        public readonly bool NeedsFragmentOutputSpecialization;
        public readonly bool ReduceShaderPrecision;

        public readonly bool SupportsAstcCompression;
        public readonly bool SupportsBc123Compression;
        public readonly bool SupportsBc45Compression;
        public readonly bool SupportsBc67Compression;
        public readonly bool SupportsEtc2Compression;
        public readonly bool Supports3DTextureCompression;
        public readonly bool SupportsBgraFormat;
        public readonly bool SupportsR4G4Format;
        public readonly bool SupportsR4G4B4A4Format;
        public readonly bool SupportsScaledVertexFormats;
        // S2A：渲染器顶点自取（graphics/metal/gal_vpull.m）——顶点着色器自己按格式解码属性，产出 Maxwell 寄存器原始位。
        // 为真时 Gpu 层把缩放整数格式原样交给渲染器（不改成整数格式），翻译器可把顶点输入声明为原始位（ShaderDefinitions.S2AVertexRaw）
        public readonly bool S2AVertexPull;
        // 实际渲染器的接口合同。Metal 也接收 Vulkan SPIR-V，不能用 Api 区分。
        public readonly bool RequiresLinkedVaryingInterface;
        public readonly int MaximumVertexOutputComponents;
        public readonly int MaximumFragmentInputComponents;
        public readonly bool SupportsSnormBufferTextureFormat;
        public readonly bool SupportsSparseBuffer;
        public readonly bool Supports5BitComponentFormat;
        public readonly bool SupportsBlendEquationAdvanced;
        public readonly bool SupportsFragmentShaderInterlock;
        public readonly bool SupportsFragmentShaderOrderingIntel;
        public readonly bool SupportsGeometryShader;
        // S2A（#1456）：设备指纹级运行时探测结论（capprobe 结果文件 gs_occlusion）。
        //   通用 Vulkan 建设备时读文件得出；为假时 SupportsGeometryShader 已被同一
        //   文件压成假（原值 && 本位）。Apple Metal 能力表恒为假、从不读文件——
        //   Metal 没有 GS+遮挡查询组合可探。
        public readonly bool SupportsGeometryShaderOcclusionQuery;
        public readonly bool SupportsGeometryShaderPassthrough;
        public readonly bool SupportsTransformFeedback;
        public readonly bool SupportsImageLoadFormatted;
        public readonly bool SupportsLayerVertexTessellation;
        public readonly bool SupportsMismatchingViewFormat;
        public readonly bool SupportsCubemapView;
        public readonly bool SupportsNonConstantTextureOffset;
        public readonly bool SupportsQuads;
        public readonly bool SupportsSeparateSampler;
        public readonly bool SupportsShaderBallot;
        public readonly bool SupportsShaderBarrierDivergence;
        public readonly bool SupportsShaderFloat64;
        public readonly bool SupportsShaderNonUniformIndexing;
        public readonly bool SupportsTextureGatherOffsets;
        public readonly bool SupportsTextureShadowLod;
        public readonly bool SupportsVertexStoreAndAtomics;
        public readonly bool SupportsViewportIndexVertexTessellation;
        public readonly bool SupportsViewportMask;
        public readonly bool SupportsViewportSwizzle;
        public readonly bool SupportsIndirectParameters;
        public readonly bool SupportsDepthClipControl;

        public readonly int UniformBufferSetIndex;
        public readonly int StorageBufferSetIndex;
        public readonly int TextureSetIndex;
        public readonly int ImageSetIndex;
        public readonly int ExtraSetBaseIndex;
        public readonly int MaximumExtraSets;

        public readonly uint MaximumUniformBuffersPerStage;
        public readonly uint MaximumStorageBuffersPerStage;
        public readonly uint MaximumTexturesPerStage;
        public readonly uint MaximumImagesPerStage;

        public readonly int MaximumComputeSharedMemorySize;
        public readonly float MaximumSupportedAnisotropy;
        public readonly int ShaderSubgroupSize;
        public readonly int StorageBufferOffsetAlignment;
        public readonly int TextureBufferOffsetAlignment;

        public readonly int GatherBiasPrecision;

        public readonly ulong MaximumGpuMemory;

        // S2A（F1）：存储缓冲访存按宿主绑定窗口（OpArrayLength）检查并钳位下标。只有 Vulkan 渲染器在设备未启用
        //   robustBufferAccess 时置真（Mali / Adreno 等）；Metal（NxCaps 也报 Vulkan）、NVIDIA、离线能力表为假，
        //   为假时 GlobalToStorage 的输出与改前逐字节相同。计入宿主缓存能力身份（只在为真时写入，为假时身份不变）。
        public readonly bool S2AStorageWindowClamp;

        // S2A（F1）：越界记录缓冲（缺省关的诊断开关 S2A_SSBO_OOB_DIAG=1，且 S2AStorageWindowClamp 为真）。
        //   为真时片元 / 计算阶段（宿主支持 vertexPipelineStoresAndAtomics 时含顶点 / 细分 / 几何）多一个可写记录缓冲；
        //   计入宿主缓存能力身份，开与关的宿主程序不混用。
        public readonly bool S2AStorageOobRecord;

        // S2A：宿主不支持作 uniform texel buffer 的顶点 texel 格式集合（FormatTable.VertexTexelViewFormats
        //   中 bufferFeatures 无 UNIFORM_TEXEL_BUFFER 者）；命中时转计算绑同位宽整型替代 view，
        //   着色器按 AttributeType.TexelDecode 语义解码。不序列化进宿主缓存/烘焙档——加载时以
        //   本机能力重算，与特化状态里的 decode 位一并生效。
        public readonly Format[] UnsupportedUniformTexelBufferFormats;

        // S2A：宿主支持无格式存储图像写（Vulkan shaderStorageImageWriteWithoutFormat）。存储 texel buffer
        //   只在宿主同时支持无格式读/写时才把 Image Format 声明成 Unknown（VUID-08737 根修），
        //   输出代码不同 → 计入宿主缓存能力身份与 program profile（为假时字节与改前相同）。
        public readonly bool SupportsImageStoreFormatted;

        // The Vulkan target supports SPIR-V 1.5. This is part of shader cache identity.
        public readonly bool S2ASpirv15;
        public readonly bool S2ASpirvLayerExt;
        public readonly bool S2ASpirvLayerNv;

        public Capabilities(
            TargetApi api,
            string vendorName,
            SystemMemoryType memoryType,
            bool hasFrontFacingBug,
            bool hasVectorIndexingBug,
            bool needsFragmentOutputSpecialization,
            bool reduceShaderPrecision,
            bool supportsAstcCompression,
            bool supportsBc123Compression,
            bool supportsBc45Compression,
            bool supportsBc67Compression,
            bool supportsEtc2Compression,
            bool supports3DTextureCompression,
            bool supportsBgraFormat,
            bool supportsR4G4Format,
            bool supportsR4G4B4A4Format,
            bool supportsScaledVertexFormats,
            bool supportsSnormBufferTextureFormat,
            bool supports5BitComponentFormat,
            bool supportsSparseBuffer,
            bool supportsBlendEquationAdvanced,
            bool supportsFragmentShaderInterlock,
            bool supportsFragmentShaderOrderingIntel,
            bool supportsGeometryShader,
            bool supportsGeometryShaderPassthrough,
            bool supportsTransformFeedback,
            bool supportsImageLoadFormatted,
            bool supportsLayerVertexTessellation,
            bool supportsMismatchingViewFormat,
            bool supportsCubemapView,
            bool supportsNonConstantTextureOffset,
            bool supportsQuads,
            bool supportsSeparateSampler,
            bool supportsShaderBallot,
            bool supportsShaderBarrierDivergence,
            bool supportsShaderFloat64,
            bool supportsShaderNonUniformIndexing,
            bool supportsTextureGatherOffsets,
            bool supportsTextureShadowLod,
            bool supportsVertexStoreAndAtomics,
            bool supportsViewportIndexVertexTessellation,
            bool supportsViewportMask,
            bool supportsViewportSwizzle,
            bool supportsIndirectParameters,
            bool supportsDepthClipControl,
            int uniformBufferSetIndex,
            int storageBufferSetIndex,
            int textureSetIndex,
            int imageSetIndex,
            int extraSetBaseIndex,
            int maximumExtraSets,
            uint maximumUniformBuffersPerStage,
            uint maximumStorageBuffersPerStage,
            uint maximumTexturesPerStage,
            uint maximumImagesPerStage,
            int maximumComputeSharedMemorySize,
            float maximumSupportedAnisotropy,
            int shaderSubgroupSize,
            int storageBufferOffsetAlignment,
            int textureBufferOffsetAlignment,
            int gatherBiasPrecision,
            ulong maximumGpuMemory,
            bool s2aVertexPull = false,
            bool requiresLinkedVaryingInterface = false,
            int maximumVertexOutputComponents = 0,
            int maximumFragmentInputComponents = 0,
            bool s2aStorageWindowClamp = false,
            bool s2aStorageOobRecord = false,
            Format[] unsupportedUniformTexelBufferFormats = null,
            bool supportsGeometryShaderOcclusionQuery = false,
            bool supportsImageStoreFormatted = false,
            bool s2aSpirv15 = false,
            bool s2aSpirvLayerExt = false,
            bool s2aSpirvLayerNv = false)
        {
            S2ASpirv15 = s2aSpirv15;
            S2ASpirvLayerExt = s2aSpirvLayerExt;
            S2ASpirvLayerNv = s2aSpirvLayerNv;
            SupportsGeometryShaderOcclusionQuery = supportsGeometryShaderOcclusionQuery;
            UnsupportedUniformTexelBufferFormats = unsupportedUniformTexelBufferFormats;
            SupportsImageStoreFormatted = supportsImageStoreFormatted;
            S2AStorageWindowClamp = s2aStorageWindowClamp;
            S2AStorageOobRecord = s2aStorageWindowClamp && s2aStorageOobRecord;
            S2AVertexPull = s2aVertexPull;
            RequiresLinkedVaryingInterface = requiresLinkedVaryingInterface;
            MaximumVertexOutputComponents = maximumVertexOutputComponents;
            MaximumFragmentInputComponents = maximumFragmentInputComponents;
            Api = api;
            VendorName = vendorName;
            MemoryType = memoryType;
            HasFrontFacingBug = hasFrontFacingBug;
            HasVectorIndexingBug = hasVectorIndexingBug;
            NeedsFragmentOutputSpecialization = needsFragmentOutputSpecialization;
            ReduceShaderPrecision = reduceShaderPrecision;
            SupportsAstcCompression = supportsAstcCompression;
            SupportsBc123Compression = supportsBc123Compression;
            SupportsBc45Compression = supportsBc45Compression;
            SupportsBc67Compression = supportsBc67Compression;
            SupportsEtc2Compression = supportsEtc2Compression;
            Supports3DTextureCompression = supports3DTextureCompression;
            SupportsBgraFormat = supportsBgraFormat;
            SupportsR4G4Format = supportsR4G4Format;
            SupportsR4G4B4A4Format = supportsR4G4B4A4Format;
            SupportsScaledVertexFormats = supportsScaledVertexFormats;
            SupportsSnormBufferTextureFormat = supportsSnormBufferTextureFormat;
            Supports5BitComponentFormat = supports5BitComponentFormat;
            SupportsSparseBuffer = supportsSparseBuffer;
            SupportsBlendEquationAdvanced = supportsBlendEquationAdvanced;
            SupportsFragmentShaderInterlock = supportsFragmentShaderInterlock;
            SupportsFragmentShaderOrderingIntel = supportsFragmentShaderOrderingIntel;
            SupportsGeometryShader = supportsGeometryShader;
            SupportsGeometryShaderPassthrough = supportsGeometryShaderPassthrough;
            SupportsTransformFeedback = supportsTransformFeedback;
            SupportsImageLoadFormatted = supportsImageLoadFormatted;
            SupportsLayerVertexTessellation = supportsLayerVertexTessellation;
            SupportsMismatchingViewFormat = supportsMismatchingViewFormat;
            SupportsCubemapView = supportsCubemapView;
            SupportsNonConstantTextureOffset = supportsNonConstantTextureOffset;
            SupportsQuads = supportsQuads;
            SupportsSeparateSampler = supportsSeparateSampler;
            SupportsShaderBallot = supportsShaderBallot;
            SupportsShaderBarrierDivergence = supportsShaderBarrierDivergence;
            SupportsShaderFloat64 = supportsShaderFloat64;
            SupportsShaderNonUniformIndexing = supportsShaderNonUniformIndexing;
            SupportsTextureGatherOffsets = supportsTextureGatherOffsets;
            SupportsTextureShadowLod = supportsTextureShadowLod;
            SupportsVertexStoreAndAtomics = supportsVertexStoreAndAtomics;
            SupportsViewportIndexVertexTessellation = supportsViewportIndexVertexTessellation;
            SupportsViewportMask = supportsViewportMask;
            SupportsViewportSwizzle = supportsViewportSwizzle;
            SupportsIndirectParameters = supportsIndirectParameters;
            SupportsDepthClipControl = supportsDepthClipControl;
            UniformBufferSetIndex = uniformBufferSetIndex;
            StorageBufferSetIndex = storageBufferSetIndex;
            TextureSetIndex = textureSetIndex;
            ImageSetIndex = imageSetIndex;
            ExtraSetBaseIndex = extraSetBaseIndex;
            MaximumExtraSets = maximumExtraSets;
            MaximumUniformBuffersPerStage = maximumUniformBuffersPerStage;
            MaximumStorageBuffersPerStage = maximumStorageBuffersPerStage;
            MaximumTexturesPerStage = maximumTexturesPerStage;
            MaximumImagesPerStage = maximumImagesPerStage;
            MaximumComputeSharedMemorySize = maximumComputeSharedMemorySize;
            MaximumSupportedAnisotropy = maximumSupportedAnisotropy;
            ShaderSubgroupSize = shaderSubgroupSize;
            StorageBufferOffsetAlignment = storageBufferOffsetAlignment;
            TextureBufferOffsetAlignment = textureBufferOffsetAlignment;
            GatherBiasPrecision = gatherBiasPrecision;
            MaximumGpuMemory = maximumGpuMemory;
        }
    }
}
