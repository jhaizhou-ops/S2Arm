using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace Ryujinx.Graphics.Gpu.Shader.DiskCache
{
    /// <summary>Stable identity of the effective capabilities consumed by GPU translation.</summary>
    static class HostCacheCapabilities
    {
        // Explicit serialization is NativeAOT-safe. Tests perturb every GAL field; adding a
        // field without serializing it (or documenting its exclusion) fails coverage. Never hash
        // struct padding or object identity. VendorName already namespaces the host filename.
        // Resource backing/format conversion, view sharing, sampler/viewport state, memory
        // budgets and MME execution choices do not specialize host programs. Their explicit
        // exclusions and consumer evidence are maintained with the cache admission tests.
        public static string GetIdentity(in Capabilities capabilities, ComputeTranslationProfile selected = null)
        {
            using MemoryStream stream = new();
            using BinaryWriter writer = new(stream, Encoding.UTF8, leaveOpen: true);
            writer.Write(1u); // Private host identity schema; guest/shared formats are unchanged.
            writer.Write((int)capabilities.Api);
            writer.Write(capabilities.HasFrontFacingBug);
            writer.Write(capabilities.HasVectorIndexingBug);
            writer.Write(capabilities.NeedsFragmentOutputSpecialization);
            writer.Write(capabilities.ReduceShaderPrecision);
            writer.Write(capabilities.SupportsBgraFormat);
            writer.Write(capabilities.SupportsScaledVertexFormats);
            writer.Write(capabilities.S2AVertexPull);
            // Same language selection as ShaderCache.CreateTranslationOptions; no renderer -> GPU dependency.
            selected?.RequireCapabilities(in capabilities);
            bool usesSpirv = selected != null ? selected.Language == TargetLanguage.Spirv :
                GraphicsConfig.EnableSpirvCompilationOnVulkan && capabilities.Api == TargetApi.Vulkan;
            writer.Write(usesSpirv);
            writer.Write(usesSpirv && capabilities.RequiresLinkedVaryingInterface);
            writer.Write(capabilities.RequiresLinkedVaryingInterface);
            writer.Write(capabilities.MaximumVertexOutputComponents);
            writer.Write(capabilities.MaximumFragmentInputComponents);
            writer.Write(capabilities.SupportsSnormBufferTextureFormat);
            writer.Write(capabilities.SupportsBlendEquationAdvanced);
            writer.Write(capabilities.SupportsFragmentShaderInterlock);
            writer.Write(capabilities.SupportsFragmentShaderOrderingIntel);
            writer.Write(capabilities.SupportsGeometryShader);
            writer.Write(capabilities.SupportsGeometryShaderPassthrough);
            writer.Write(capabilities.SupportsTransformFeedback);
            writer.Write(capabilities.SupportsImageLoadFormatted);
            writer.Write(capabilities.SupportsLayerVertexTessellation);
            writer.Write(capabilities.SupportsNonConstantTextureOffset);
            writer.Write(capabilities.SupportsQuads);
            writer.Write(capabilities.SupportsSeparateSampler);
            writer.Write(capabilities.SupportsShaderBallot);
            writer.Write(capabilities.SupportsShaderBarrierDivergence);
            writer.Write(capabilities.SupportsShaderFloat64);
            writer.Write(capabilities.SupportsShaderNonUniformIndexing);
            writer.Write(capabilities.SupportsTextureGatherOffsets);
            writer.Write(capabilities.SupportsTextureShadowLod);
            writer.Write(capabilities.SupportsVertexStoreAndAtomics);
            writer.Write(capabilities.SupportsViewportIndexVertexTessellation);
            writer.Write(capabilities.SupportsViewportMask);
            writer.Write(capabilities.SupportsDepthClipControl);
            writer.Write(capabilities.UniformBufferSetIndex);
            writer.Write(capabilities.StorageBufferSetIndex);
            writer.Write(capabilities.TextureSetIndex);
            writer.Write(capabilities.ImageSetIndex);
            writer.Write(capabilities.ExtraSetBaseIndex);
            writer.Write(capabilities.MaximumExtraSets);
            writer.Write(capabilities.MaximumUniformBuffersPerStage);
            writer.Write(capabilities.MaximumStorageBuffersPerStage);
            writer.Write(capabilities.MaximumTexturesPerStage);
            writer.Write(capabilities.MaximumImagesPerStage);
            writer.Write(capabilities.MaximumComputeSharedMemorySize);
            writer.Write(capabilities.ShaderSubgroupSize);
            writer.Write(capabilities.StorageBufferOffsetAlignment);
            writer.Write(capabilities.GatherBiasPrecision);
            // S2A（F1）：只在为真时追加，为假（Metal、NVIDIA、改前）时身份字节与改前相同，已有宿主缓存继续可用
            if (capabilities.S2AStorageWindowClamp || capabilities.S2AStorageOobRecord)
            {
                writer.Write("s2a-storage-window");
                writer.Write(capabilities.S2AStorageWindowClamp);
                writer.Write(capabilities.S2AStorageOobRecord);
            }
            // S2A：空集不追加——全支持的宿主身份字节与改前相同；非空时集合影响生成的
            //   解码码流，必须把格式值写进身份，否则跨设备缓存会错配。
            if (capabilities.UnsupportedUniformTexelBufferFormats is { Length: > 0 } unsupportedTexel)
            {
                writer.Write("s2a-texel-view-fallback");
                writer.Write(unsupportedTexel.Length);
                foreach (Format format in unsupportedTexel)
                {
                    writer.Write((int)format);
                }
            }
            // #1456：GS+遮挡查询运行时能力为假时身份字节与改前相同（已有宿主缓存继续可用）；
            //   为真必须轮转——真走硬件 GS 着色器集，假走转计算着色器集。
            if (capabilities.SupportsGeometryShaderOcclusionQuery)
            {
                writer.Write("s2a-gsocc");
                writer.Write(true);
            }
            // S2A（VUID-08737 根修）：只在为真时追加，为假时身份字节与改前相同。无格式写支持与否
            //   决定存储 texel buffer 的 Image Format 声明（Unknown vs 具体格式），输出不同必须分身份。
            if (capabilities.SupportsImageStoreFormatted)
            {
                writer.Write("s2a-store-without-format");
            }
            if (usesSpirv && capabilities.S2ASpirv15)
            {
                writer.Write("s2a-spirv-15-layer-output");
            }
            // The old emitter already used EXT unconditionally. Keep that key when
            // EXT is actually the chosen legacy route; rotate the key when the new
            // route instead selects NV or rejects output. Core 1.5 is keyed above.
            if (usesSpirv && !capabilities.S2ASpirv15 && !capabilities.S2ASpirvLayerExt)
            {
                writer.Write("s2a-spirv-layer-legacy-route");
                writer.Write(capabilities.S2ASpirvLayerNv);
            }
            // The old translator could create an unsupported hardware GS on
            // this profile; its already persisted host binary must not bypass
            // the new fail-closed route. Guest/shared records remain reusable.
            if (!capabilities.SupportsGeometryShader && !capabilities.SupportsLayerVertexTessellation)
            {
                writer.Write("s2a-layer-route-fail-closed-v1");
            }
            writer.Flush();
            return Convert.ToHexStringLower(SHA256.HashData(stream.GetBuffer().AsSpan(0, (int)stream.Length)));
        }
    }
}
