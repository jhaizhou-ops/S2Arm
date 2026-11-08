using Ryujinx.Common.Logging;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu.Image;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using System;

namespace Ryujinx.Graphics.Gpu.Shader
{
    /// <summary>
    /// GPU accessor.
    /// </summary>
    class GpuAccessorBase : IComputeTranslationProfileProvider
    {
        private readonly GpuContext _context;
        private readonly ResourceCounts _resourceCounts;
        private readonly int _stageIndex;
        private readonly IComputeTranslationProfileProvider _s2aProfileProvider;
        private readonly ComputeTranslationProfile _s2aProfile;
        private readonly Capabilities _s2aCapabilities;

        internal static IComputeTranslationProfileProvider S2AProfileProvider(GpuContext context)
        {
            IRenderer renderer = context.Renderer is Ryujinx.Graphics.GAL.Multithreading.ThreadedRenderer threaded
                ? threaded.BaseRenderer : context.Renderer;
            return renderer as IComputeTranslationProfileProvider;
        }

        internal static Capabilities S2ATranslationCapabilities(GpuContext context)
        {
            IComputeTranslationProfileProvider provider = S2AProfileProvider(context);
            return provider?.ComputeTranslationProfile != null ? provider.FrozenTranslationCapabilities : context.Capabilities;
        }

        public Capabilities FrozenTranslationCapabilities => TranslationCapabilities;

        public bool QueryHostSupportsSpirv15() => TranslationCapabilities.S2ASpirv15;
        public bool QueryHostSpirvLayerExt() => TranslationCapabilities.S2ASpirvLayerExt;
        public bool QueryHostSpirvLayerNv() => TranslationCapabilities.S2ASpirvLayerNv;

        public ComputeTranslationProfile ComputeTranslationProfile
        {
            get
            {
                if (_s2aProfile != null && !ReferenceEquals(_s2aProfileProvider.ComputeTranslationProfile, _s2aProfile))
                    throw new InvalidOperationException("The GPU accessor has a stale Vulkan translation profile generation.");
                return _s2aProfile;
            }
        }

        protected Capabilities TranslationCapabilities => ComputeTranslationProfile == null
            ? _context.Capabilities : _s2aCapabilities;

        private int _reservedConstantBuffers;
        private int _reservedStorageBuffers;
        private int _reservedTextures;
        private int _reservedImages;

        private int _staticTexturesCount;
        private int _staticImagesCount;

        /// <summary>
        /// Creates a new GPU accessor.
        /// </summary>
        /// <param name="context">GPU context</param>
        /// <param name="resourceCounts">Counter of GPU resources used by the shader</param>
        /// <param name="stageIndex">Index of the shader stage, 0 for compute</param>
        public GpuAccessorBase(GpuContext context, ResourceCounts resourceCounts, int stageIndex)
        {
            _context = context;
            _resourceCounts = resourceCounts;
            _stageIndex = stageIndex;
            _s2aProfileProvider = S2AProfileProvider(context);
            _s2aProfile = _s2aProfileProvider?.ComputeTranslationProfile;
            _s2aCapabilities = _s2aProfile != null ? _s2aProfileProvider.FrozenTranslationCapabilities : context.Capabilities;
            _s2aProfile?.RequireCapabilities(in _s2aCapabilities);
        }

        /// <summary>
        /// Initializes counts for bindings that will be reserved for emulator use.
        /// </summary>
        /// <param name="tfEnabled">Indicates if the current graphics shader is used with transform feedback enabled</param>
        /// <param name="vertexAsCompute">Indicates that the vertex shader will be emulated on a compute shader</param>
        public void InitializeReservedCounts(bool tfEnabled, bool vertexAsCompute)
        {
            ResourceReservationCounts rrc = new(!TranslationCapabilities.SupportsTransformFeedback && tfEnabled, vertexAsCompute);

            _reservedConstantBuffers = rrc.ReservedConstantBuffers;
            _reservedStorageBuffers = rrc.ReservedStorageBuffers;
            _reservedTextures = rrc.ReservedTextures;
            _reservedImages = rrc.ReservedImages;
        }

        public SetBindingPair CreateConstantBufferBinding(int index)
        {
            int binding;

            if (TranslationCapabilities.Api == TargetApi.Vulkan)
            {
                binding = GetBindingFromIndex(index, TranslationCapabilities.MaximumUniformBuffersPerStage, "Uniform buffer");
            }
            else
            {
                binding = _resourceCounts.UniformBuffersCount++;
            }

            return new SetBindingPair(TranslationCapabilities.UniformBufferSetIndex, binding + _reservedConstantBuffers);
        }

        public SetBindingPair CreateImageBinding(int count, bool isBuffer)
        {
            int binding;

            if (TranslationCapabilities.Api == TargetApi.Vulkan)
            {
                if (count == 1)
                {
                    int index = _staticImagesCount++;

                    if (isBuffer)
                    {
                        index += (int)TranslationCapabilities.MaximumImagesPerStage;
                    }

                    binding = GetBindingFromIndex(index, TranslationCapabilities.MaximumImagesPerStage * 2, "Image");
                }
                else
                {
                    binding = (int)GetDynamicBaseIndexDual(TranslationCapabilities.MaximumImagesPerStage) + _resourceCounts.ImagesCount++;
                }
            }
            else
            {
                binding = _resourceCounts.ImagesCount;

                _resourceCounts.ImagesCount += count;
            }

            return new SetBindingPair(TranslationCapabilities.ImageSetIndex, binding + _reservedImages);
        }

        public SetBindingPair CreateStorageBufferBinding(int index)
        {
            int binding;

            if (TranslationCapabilities.Api == TargetApi.Vulkan)
            {
                binding = GetBindingFromIndex(index, TranslationCapabilities.MaximumStorageBuffersPerStage, "Storage buffer");
            }
            else
            {
                binding = _resourceCounts.StorageBuffersCount++;
            }

            return new SetBindingPair(TranslationCapabilities.StorageBufferSetIndex, binding + _reservedStorageBuffers);
        }

        /// <summary>S2A（F1）：存储缓冲访存按宿主绑定窗口钳位（只由 Vulkan 渲染器在未启用 robustBufferAccess 时置真）。</summary>
        public bool QueryHostStorageWindowClamp()
        {
            return ComputeTranslationProfile?.StorageWindowClamp ?? TranslationCapabilities.S2AStorageWindowClamp;
        }

        /// <summary>S2A（F1）：越界记录诊断（缺省关，S2A_SSBO_OOB_DIAG=1）。</summary>
        public bool QueryHostStorageOobRecord()
        {
            return ComputeTranslationProfile?.StorageOobRecord ?? TranslationCapabilities.S2AStorageOobRecord;
        }

        /// <summary>
        /// S2A（F1）：越界记录缓冲绑定。只有开了记录诊断的 Vulkan 渲染器按程序绑定它（S2AStorageOobRecorder）；顶点 / 细分 / 几何阶段
        /// 在宿主不支持 vertexPipelineStoresAndAtomics 时不写存储缓冲，不给记录（越界仍钳位）。片元阶段按 fragmentStoresAndAtomics
        /// 可用处理：Capabilities 不带这一位，Ryujinx 的片元存储写本来就依赖它。
        /// </summary>
        public SetBindingPair CreateS2AStorageOobRecordBinding(ShaderStage stage)
        {
            bool vtg = stage is ShaderStage.Vertex or ShaderStage.TessellationControl or ShaderStage.TessellationEvaluation or ShaderStage.Geometry;

            if (!TranslationCapabilities.S2AStorageOobRecord || (vtg && !TranslationCapabilities.SupportsVertexStoreAndAtomics))
            {
                return new SetBindingPair(-1, -1);
            }

            return new SetBindingPair(TranslationCapabilities.StorageBufferSetIndex, S2AStorageOobRecord.Binding);
        }

        public SetBindingPair CreateTextureBinding(int count, bool isBuffer)
        {
            int binding;

            if (TranslationCapabilities.Api == TargetApi.Vulkan)
            {
                if (count == 1)
                {
                    int index = _staticTexturesCount++;

                    if (isBuffer)
                    {
                        index += (int)TranslationCapabilities.MaximumTexturesPerStage;
                    }

                    binding = GetBindingFromIndex(index, TranslationCapabilities.MaximumTexturesPerStage * 2, "Texture");
                }
                else
                {
                    binding = (int)GetDynamicBaseIndexDual(TranslationCapabilities.MaximumTexturesPerStage) + _resourceCounts.TexturesCount++;
                }
            }
            else
            {
                binding = _resourceCounts.TexturesCount;

                _resourceCounts.TexturesCount += count;
            }

            return new SetBindingPair(TranslationCapabilities.TextureSetIndex, binding + _reservedTextures);
        }

        private int GetBindingFromIndex(int index, uint maxPerStage, string resourceName)
        {
            if ((uint)index >= maxPerStage)
            {
                Logger.Error?.Print(LogClass.Gpu, $"{resourceName} index {index} exceeds per stage limit of {maxPerStage}.");
            }

            return GetStageIndex(_stageIndex) * (int)maxPerStage + index;
        }

        public static int GetStageIndex(int stageIndex)
        {
            // This is just a simple remapping to ensure that most frequently used shader stages
            // have the lowest binding numbers.
            // This is useful because if we need to run on a system with a low limit on the bindings,
            // then we can still get most games working as the most common shaders will have low binding numbers.
            return stageIndex switch
            {
                4 => 1, // Fragment
                3 => 2, // Geometry
                1 => 3, // Tessellation control
                2 => 4, // Tessellation evaluation
                _ => 0, // Vertex/Compute
            };
        }

        private static uint GetDynamicBaseIndexDual(uint maxPerStage)
        {
            return GetDynamicBaseIndex(maxPerStage) * 2;
        }

        private static uint GetDynamicBaseIndex(uint maxPerStage)
        {
            return maxPerStage * Constants.ShaderStages;
        }

        public int CreateExtraSet()
        {
            if (_resourceCounts.SetsCount >= TranslationCapabilities.MaximumExtraSets)
            {
                return -1;
            }

            return TranslationCapabilities.ExtraSetBaseIndex + _resourceCounts.SetsCount++;
        }

        public int QueryHostGatherBiasPrecision() => TranslationCapabilities.GatherBiasPrecision;

        public bool QueryHostReducedPrecision() => TranslationCapabilities.ReduceShaderPrecision;

        public bool QueryHostHasFrontFacingBug() => TranslationCapabilities.HasFrontFacingBug;

        public bool QueryHostHasVectorIndexingBug() => TranslationCapabilities.HasVectorIndexingBug;

        public int QueryHostStorageBufferOffsetAlignment() => TranslationCapabilities.StorageBufferOffsetAlignment;

        public int QueryHostSubgroupSize() => TranslationCapabilities.ShaderSubgroupSize;

        public bool QueryHostSupportsBgraFormat() => TranslationCapabilities.SupportsBgraFormat;

        public bool QueryHostSupportsFragmentShaderInterlock() => TranslationCapabilities.SupportsFragmentShaderInterlock;

        public bool QueryHostSupportsFragmentShaderOrderingIntel() => TranslationCapabilities.SupportsFragmentShaderOrderingIntel;

        public bool QueryHostSupportsGeometryShader() => TranslationCapabilities.SupportsGeometryShader;

        public bool QueryHostSupportsGeometryShaderPassthrough() => TranslationCapabilities.SupportsGeometryShaderPassthrough;

        public bool QueryHostSupportsImageLoadFormatted() => TranslationCapabilities.SupportsImageLoadFormatted;

        public bool QueryHostSupportsImageStoreFormatted() => TranslationCapabilities.SupportsImageStoreFormatted;

        public bool QueryHostSupportsLayerVertexTessellation() => TranslationCapabilities.SupportsLayerVertexTessellation;

        public bool QueryHostSupportsNonConstantTextureOffset() => TranslationCapabilities.SupportsNonConstantTextureOffset;

        public bool QueryHostSupportsScaledVertexFormats() => TranslationCapabilities.SupportsScaledVertexFormats;

        public bool QueryHostS2AVertexPull() => TranslationCapabilities.S2AVertexPull;

        public bool QueryHostRequiresLinkedVaryingInterface() => TranslationCapabilities.RequiresLinkedVaryingInterface;

        public int QueryHostMaximumVertexOutputComponents() => TranslationCapabilities.MaximumVertexOutputComponents;

        public int QueryHostMaximumFragmentInputComponents() => TranslationCapabilities.MaximumFragmentInputComponents;

        public bool QueryHostSupportsSeparateSampler() => TranslationCapabilities.SupportsSeparateSampler;

        public bool QueryHostSupportsShaderBallot() => TranslationCapabilities.SupportsShaderBallot;

        public bool QueryHostSupportsShaderBarrierDivergence() => TranslationCapabilities.SupportsShaderBarrierDivergence;

        public bool QueryHostSupportsShaderFloat64() => TranslationCapabilities.SupportsShaderFloat64;

        public bool QueryHostSupportsShaderNonUniformIndexing() => TranslationCapabilities.SupportsShaderNonUniformIndexing;

        public bool QueryHostSupportsSnormBufferTextureFormat() => TranslationCapabilities.SupportsSnormBufferTextureFormat;

        public bool QueryHostSupportsTextureGatherOffsets() => TranslationCapabilities.SupportsTextureGatherOffsets;

        public bool QueryHostSupportsTextureShadowLod() => TranslationCapabilities.SupportsTextureShadowLod;

        public bool QueryHostSupportsTransformFeedback() => TranslationCapabilities.SupportsTransformFeedback;

        public bool QueryHostSupportsViewportIndexVertexTessellation() => TranslationCapabilities.SupportsViewportIndexVertexTessellation;

        public bool QueryHostSupportsViewportMask() => TranslationCapabilities.SupportsViewportMask;

        public bool QueryHostSupportsDepthClipControl() => TranslationCapabilities.SupportsDepthClipControl;

        /// <summary>
        /// Converts a packed Maxwell texture format to the shader translator texture format.
        /// </summary>
        /// <param name="format">Packed maxwell format</param>
        /// <param name="formatSrgb">Indicates if the format is sRGB</param>
        /// <returns>Shader translator texture format</returns>
        protected internal static TextureFormat ConvertToTextureFormat(uint format, bool formatSrgb)
        {
            if (!FormatTable.TryGetTextureFormat(format, formatSrgb, out FormatInfo formatInfo))
            {
                return TextureFormat.Unknown;
            }

            return formatInfo.Format switch
            {
#pragma warning disable IDE0055 // Disable formatting
                Format.R8Unorm           => TextureFormat.R8Unorm,
                Format.R8Snorm           => TextureFormat.R8Snorm,
                Format.R8Uint            => TextureFormat.R8Uint,
                Format.R8Sint            => TextureFormat.R8Sint,
                Format.R16Float          => TextureFormat.R16Float,
                Format.R16Unorm          => TextureFormat.R16Unorm,
                Format.R16Snorm          => TextureFormat.R16Snorm,
                Format.R16Uint           => TextureFormat.R16Uint,
                Format.R16Sint           => TextureFormat.R16Sint,
                Format.R32Float          => TextureFormat.R32Float,
                Format.R32Uint           => TextureFormat.R32Uint,
                Format.R32Sint           => TextureFormat.R32Sint,
                Format.R8G8Unorm         => TextureFormat.R8G8Unorm,
                Format.R8G8Snorm         => TextureFormat.R8G8Snorm,
                Format.R8G8Uint          => TextureFormat.R8G8Uint,
                Format.R8G8Sint          => TextureFormat.R8G8Sint,
                Format.R16G16Float       => TextureFormat.R16G16Float,
                Format.R16G16Unorm       => TextureFormat.R16G16Unorm,
                Format.R16G16Snorm       => TextureFormat.R16G16Snorm,
                Format.R16G16Uint        => TextureFormat.R16G16Uint,
                Format.R16G16Sint        => TextureFormat.R16G16Sint,
                Format.R32G32Float       => TextureFormat.R32G32Float,
                Format.R32G32Uint        => TextureFormat.R32G32Uint,
                Format.R32G32Sint        => TextureFormat.R32G32Sint,
                Format.R8G8B8A8Unorm     => TextureFormat.R8G8B8A8Unorm,
                Format.R8G8B8A8Snorm     => TextureFormat.R8G8B8A8Snorm,
                Format.R8G8B8A8Uint      => TextureFormat.R8G8B8A8Uint,
                Format.R8G8B8A8Sint      => TextureFormat.R8G8B8A8Sint,
                Format.R8G8B8A8Srgb      => TextureFormat.R8G8B8A8Unorm,
                Format.R16G16B16A16Float => TextureFormat.R16G16B16A16Float,
                Format.R16G16B16A16Unorm => TextureFormat.R16G16B16A16Unorm,
                Format.R16G16B16A16Snorm => TextureFormat.R16G16B16A16Snorm,
                Format.R16G16B16A16Uint  => TextureFormat.R16G16B16A16Uint,
                Format.R16G16B16A16Sint  => TextureFormat.R16G16B16A16Sint,
                Format.R32G32B32A32Float => TextureFormat.R32G32B32A32Float,
                Format.R32G32B32A32Uint  => TextureFormat.R32G32B32A32Uint,
                Format.R32G32B32A32Sint  => TextureFormat.R32G32B32A32Sint,
                Format.R10G10B10A2Unorm  => TextureFormat.R10G10B10A2Unorm,
                Format.R10G10B10A2Uint   => TextureFormat.R10G10B10A2Uint,
                Format.R11G11B10Float    => TextureFormat.R11G11B10Float,
                _                        => TextureFormat.Unknown,
#pragma warning restore IDE0055
            };
        }
    }
}
