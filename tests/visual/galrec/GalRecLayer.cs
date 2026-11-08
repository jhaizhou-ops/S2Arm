// 由 tools/gen_recording.py 生成，别手改。说明见生成脚本与 README「GAL 调用流录像」。
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.Buffers;
using System.Collections.Generic;
using System.Threading;

namespace RyuJudge.GalRec
{
    public static class GalOps
    {
        public const uint IPipeline_Barrier = 0x001;
        public const uint IPipeline_BeginTransformFeedback = 0x002;
        public const uint IPipeline_ClearBuffer = 0x003;
        public const uint IPipeline_ClearRenderTargetColor = 0x004;
        public const uint IPipeline_ClearRenderTargetDepthStencil = 0x005;
        public const uint IPipeline_CommandBufferBarrier = 0x006;
        public const uint IPipeline_CopyBuffer = 0x007;
        public const uint IPipeline_DispatchCompute = 0x008;
        public const uint IPipeline_Draw = 0x009;
        public const uint IPipeline_DrawIndexed = 0x00A;
        public const uint IPipeline_DrawIndexedIndirect = 0x00B;
        public const uint IPipeline_DrawIndexedIndirectCount = 0x00C;
        public const uint IPipeline_DrawIndirect = 0x00D;
        public const uint IPipeline_DrawIndirectCount = 0x00E;
        public const uint IPipeline_DrawTexture = 0x00F;
        public const uint IPipeline_EndTransformFeedback = 0x010;
        public const uint IPipeline_SetAlphaTest = 0x011;
        public const uint IPipeline_SetBlendState_1 = 0x012;
        public const uint IPipeline_SetBlendState_2 = 0x013;
        public const uint IPipeline_SetDepthBias = 0x014;
        public const uint IPipeline_SetDepthClamp = 0x015;
        public const uint IPipeline_SetDepthMode = 0x016;
        public const uint IPipeline_SetDepthTest = 0x017;
        public const uint IPipeline_SetFaceCulling = 0x018;
        public const uint IPipeline_SetFrontFace = 0x019;
        public const uint IPipeline_SetIndexBuffer = 0x01A;
        public const uint IPipeline_SetImage = 0x01B;
        public const uint IPipeline_SetImageArray = 0x01C;
        public const uint IPipeline_SetImageArraySeparate = 0x01D;
        public const uint IPipeline_SetLineParameters = 0x01E;
        public const uint IPipeline_SetLogicOpState = 0x01F;
        public const uint IPipeline_SetMultisampleState = 0x020;
        public const uint IPipeline_SetPatchParameters = 0x021;
        public const uint IPipeline_SetPointParameters = 0x022;
        public const uint IPipeline_SetPolygonMode = 0x023;
        public const uint IPipeline_SetPrimitiveRestart = 0x024;
        public const uint IPipeline_SetPrimitiveTopology = 0x025;
        public const uint IPipeline_SetProgram = 0x026;
        public const uint IPipeline_SetRasterizerDiscard = 0x027;
        public const uint IPipeline_SetRenderTargetColorMasks = 0x028;
        public const uint IPipeline_SetRenderTargets = 0x029;
        public const uint IPipeline_SetScissors = 0x02A;
        public const uint IPipeline_SetStencilTest = 0x02B;
        public const uint IPipeline_SetStorageBuffers = 0x02C;
        public const uint IPipeline_SetTextureAndSampler = 0x02D;
        public const uint IPipeline_SetTextureArray = 0x02E;
        public const uint IPipeline_SetTextureArraySeparate = 0x02F;
        public const uint IPipeline_SetTransformFeedbackBuffers = 0x030;
        public const uint IPipeline_SetUniformBuffers = 0x031;
        public const uint IPipeline_SetUserClipDistance = 0x032;
        public const uint IPipeline_SetVertexAttribs = 0x033;
        public const uint IPipeline_SetVertexBuffers = 0x034;
        public const uint IPipeline_SetViewports = 0x035;
        public const uint IPipeline_TextureBarrier = 0x036;
        public const uint IPipeline_TextureBarrierTiled = 0x037;
        public const uint IPipeline_TryHostConditionalRendering_1 = 0x038;
        public const uint IPipeline_TryHostConditionalRendering_2 = 0x039;
        public const uint IPipeline_EndHostConditionalRendering = 0x03A;
        public const uint IRenderer_BackgroundContextAction = 0x101;
        public const uint IRenderer_CreateBuffer_1 = 0x102;
        public const uint IRenderer_CreateBuffer_2 = 0x103;
        public const uint IRenderer_CreateBufferSparse = 0x104;
        public const uint IRenderer_CreateImageArray = 0x105;
        public const uint IRenderer_CreateProgram = 0x106;
        public const uint IRenderer_CreateSampler = 0x107;
        public const uint IRenderer_CreateTexture = 0x108;
        public const uint IRenderer_CreateTextureArray = 0x109;
        public const uint IRenderer_PrepareHostMapping = 0x10A;
        public const uint IRenderer_CreateSync = 0x10B;
        public const uint IRenderer_DeleteBuffer = 0x10C;
        public const uint IRenderer_GetBufferData = 0x10D;
        public const uint IRenderer_GetCapabilities = 0x10E;
        public const uint IRenderer_GetCurrentSync = 0x10F;
        public const uint IRenderer_GetHardwareInfo = 0x110;
        public const uint IRenderer_LoadProgramBinary = 0x111;
        public const uint IRenderer_SetBufferData = 0x112;
        public const uint IRenderer_UpdateCounters = 0x113;
        public const uint IRenderer_PreFrame = 0x114;
        public const uint IRenderer_ReportCounter = 0x115;
        public const uint IRenderer_ResetCounter = 0x116;
        public const uint IRenderer_WaitSync = 0x117;
        public const uint IRenderer_Initialize = 0x118;
        public const uint IRenderer_SetInterruptAction = 0x119;
        public const uint IRenderer_Screenshot = 0x11A;
        public const uint IWindow_Present = 0x201;
        public const uint IWindow_SetSize = 0x202;
        public const uint IWindow_ChangeVSyncMode = 0x203;
        public const uint IWindow_SetAntiAliasing = 0x204;
        public const uint IWindow_SetScalingFilter = 0x205;
        public const uint IWindow_SetScalingFilterLevel = 0x206;
        public const uint IWindow_SetColorSpacePassthrough = 0x207;

        /// <summary>GAL 接口签名哈希（172 条签名 + 能力表字段，SHA-256）。写进录像头，读端核不上拒放。</summary>
        public const string SignatureHash = "2b051fdf6805753d83ddd920f26c70b1ae016b06306219f6afc2ec63e961062b";

        /// <summary>操作码 → 名字（含对象方法与特殊记录），写进录像文件头。</summary>
        public static readonly SortedDictionary<uint, string> Names = MakeNames();
        static SortedDictionary<uint, string> MakeNames()
        {
            SortedDictionary<uint, string> d = new();
            d[IPipeline_Barrier] = "IPipeline.Barrier()";
            d[IPipeline_BeginTransformFeedback] = "IPipeline.BeginTransformFeedback(PrimitiveTopology)";
            d[IPipeline_ClearBuffer] = "IPipeline.ClearBuffer(BufferHandle,int,int,uint)";
            d[IPipeline_ClearRenderTargetColor] = "IPipeline.ClearRenderTargetColor(int,int,int,uint,ColorF)";
            d[IPipeline_ClearRenderTargetDepthStencil] = "IPipeline.ClearRenderTargetDepthStencil(int,int,float,bool,int,int)";
            d[IPipeline_CommandBufferBarrier] = "IPipeline.CommandBufferBarrier()";
            d[IPipeline_CopyBuffer] = "IPipeline.CopyBuffer(BufferHandle,BufferHandle,int,int,int)";
            d[IPipeline_DispatchCompute] = "IPipeline.DispatchCompute(int,int,int)";
            d[IPipeline_Draw] = "IPipeline.Draw(int,int,int,int)";
            d[IPipeline_DrawIndexed] = "IPipeline.DrawIndexed(int,int,int,int,int)";
            d[IPipeline_DrawIndexedIndirect] = "IPipeline.DrawIndexedIndirect(BufferRange)";
            d[IPipeline_DrawIndexedIndirectCount] = "IPipeline.DrawIndexedIndirectCount(BufferRange,BufferRange,int,int)";
            d[IPipeline_DrawIndirect] = "IPipeline.DrawIndirect(BufferRange)";
            d[IPipeline_DrawIndirectCount] = "IPipeline.DrawIndirectCount(BufferRange,BufferRange,int,int)";
            d[IPipeline_DrawTexture] = "IPipeline.DrawTexture(ITexture,ISampler,Extents2DF,Extents2DF)";
            d[IPipeline_EndTransformFeedback] = "IPipeline.EndTransformFeedback()";
            d[IPipeline_SetAlphaTest] = "IPipeline.SetAlphaTest(bool,float,CompareOp)";
            d[IPipeline_SetBlendState_1] = "IPipeline.SetBlendState(AdvancedBlendDescriptor)";
            d[IPipeline_SetBlendState_2] = "IPipeline.SetBlendState(int,BlendDescriptor)";
            d[IPipeline_SetDepthBias] = "IPipeline.SetDepthBias(PolygonModeMask,float,float,float)";
            d[IPipeline_SetDepthClamp] = "IPipeline.SetDepthClamp(bool)";
            d[IPipeline_SetDepthMode] = "IPipeline.SetDepthMode(DepthMode)";
            d[IPipeline_SetDepthTest] = "IPipeline.SetDepthTest(DepthTestDescriptor)";
            d[IPipeline_SetFaceCulling] = "IPipeline.SetFaceCulling(bool,Face)";
            d[IPipeline_SetFrontFace] = "IPipeline.SetFrontFace(FrontFace)";
            d[IPipeline_SetIndexBuffer] = "IPipeline.SetIndexBuffer(BufferRange,IndexType)";
            d[IPipeline_SetImage] = "IPipeline.SetImage(ShaderStage,int,ITexture)";
            d[IPipeline_SetImageArray] = "IPipeline.SetImageArray(ShaderStage,int,IImageArray)";
            d[IPipeline_SetImageArraySeparate] = "IPipeline.SetImageArraySeparate(ShaderStage,int,IImageArray)";
            d[IPipeline_SetLineParameters] = "IPipeline.SetLineParameters(float,bool)";
            d[IPipeline_SetLogicOpState] = "IPipeline.SetLogicOpState(bool,LogicalOp)";
            d[IPipeline_SetMultisampleState] = "IPipeline.SetMultisampleState(MultisampleDescriptor)";
            d[IPipeline_SetPatchParameters] = "IPipeline.SetPatchParameters(int,ReadOnlySpan<float>,ReadOnlySpan<float>)";
            d[IPipeline_SetPointParameters] = "IPipeline.SetPointParameters(float,bool,bool,Origin)";
            d[IPipeline_SetPolygonMode] = "IPipeline.SetPolygonMode(PolygonMode,PolygonMode)";
            d[IPipeline_SetPrimitiveRestart] = "IPipeline.SetPrimitiveRestart(bool,int)";
            d[IPipeline_SetPrimitiveTopology] = "IPipeline.SetPrimitiveTopology(PrimitiveTopology)";
            d[IPipeline_SetProgram] = "IPipeline.SetProgram(IProgram)";
            d[IPipeline_SetRasterizerDiscard] = "IPipeline.SetRasterizerDiscard(bool)";
            d[IPipeline_SetRenderTargetColorMasks] = "IPipeline.SetRenderTargetColorMasks(ReadOnlySpan<uint>)";
            d[IPipeline_SetRenderTargets] = "IPipeline.SetRenderTargets(Span<ITexture>,ITexture)";
            d[IPipeline_SetScissors] = "IPipeline.SetScissors(ReadOnlySpan<Rectangle<int>>)";
            d[IPipeline_SetStencilTest] = "IPipeline.SetStencilTest(StencilTestDescriptor)";
            d[IPipeline_SetStorageBuffers] = "IPipeline.SetStorageBuffers(ReadOnlySpan<BufferAssignment>)";
            d[IPipeline_SetTextureAndSampler] = "IPipeline.SetTextureAndSampler(ShaderStage,int,ITexture,ISampler)";
            d[IPipeline_SetTextureArray] = "IPipeline.SetTextureArray(ShaderStage,int,ITextureArray)";
            d[IPipeline_SetTextureArraySeparate] = "IPipeline.SetTextureArraySeparate(ShaderStage,int,ITextureArray)";
            d[IPipeline_SetTransformFeedbackBuffers] = "IPipeline.SetTransformFeedbackBuffers(ReadOnlySpan<BufferRange>)";
            d[IPipeline_SetUniformBuffers] = "IPipeline.SetUniformBuffers(ReadOnlySpan<BufferAssignment>)";
            d[IPipeline_SetUserClipDistance] = "IPipeline.SetUserClipDistance(int,bool)";
            d[IPipeline_SetVertexAttribs] = "IPipeline.SetVertexAttribs(ReadOnlySpan<VertexAttribDescriptor>)";
            d[IPipeline_SetVertexBuffers] = "IPipeline.SetVertexBuffers(ReadOnlySpan<VertexBufferDescriptor>)";
            d[IPipeline_SetViewports] = "IPipeline.SetViewports(ReadOnlySpan<Viewport>)";
            d[IPipeline_TextureBarrier] = "IPipeline.TextureBarrier()";
            d[IPipeline_TextureBarrierTiled] = "IPipeline.TextureBarrierTiled()";
            d[IPipeline_TryHostConditionalRendering_1] = "IPipeline.TryHostConditionalRendering(ICounterEvent,ulong,bool)";
            d[IPipeline_TryHostConditionalRendering_2] = "IPipeline.TryHostConditionalRendering(ICounterEvent,ICounterEvent,bool)";
            d[IPipeline_EndHostConditionalRendering] = "IPipeline.EndHostConditionalRendering()";
            d[IRenderer_BackgroundContextAction] = "IRenderer.BackgroundContextAction(Action,bool)";
            d[IRenderer_CreateBuffer_1] = "IRenderer.CreateBuffer(int,BufferAccess)";
            d[IRenderer_CreateBuffer_2] = "IRenderer.CreateBuffer(nint,int)";
            d[IRenderer_CreateBufferSparse] = "IRenderer.CreateBufferSparse(ReadOnlySpan<BufferRange>)";
            d[IRenderer_CreateImageArray] = "IRenderer.CreateImageArray(int,bool)";
            d[IRenderer_CreateProgram] = "IRenderer.CreateProgram(ShaderSource[],ShaderInfo)";
            d[IRenderer_CreateSampler] = "IRenderer.CreateSampler(SamplerCreateInfo)";
            d[IRenderer_CreateTexture] = "IRenderer.CreateTexture(TextureCreateInfo)";
            d[IRenderer_CreateTextureArray] = "IRenderer.CreateTextureArray(int,bool)";
            d[IRenderer_PrepareHostMapping] = "IRenderer.PrepareHostMapping(nint,ulong)";
            d[IRenderer_CreateSync] = "IRenderer.CreateSync(ulong,bool)";
            d[IRenderer_DeleteBuffer] = "IRenderer.DeleteBuffer(BufferHandle)";
            d[IRenderer_GetBufferData] = "IRenderer.GetBufferData(BufferHandle,int,int)";
            d[IRenderer_GetCapabilities] = "IRenderer.GetCapabilities()";
            d[IRenderer_GetCurrentSync] = "IRenderer.GetCurrentSync()";
            d[IRenderer_GetHardwareInfo] = "IRenderer.GetHardwareInfo()";
            d[IRenderer_LoadProgramBinary] = "IRenderer.LoadProgramBinary(byte[],bool,ShaderInfo)";
            d[IRenderer_SetBufferData] = "IRenderer.SetBufferData(BufferHandle,int,ReadOnlySpan<byte>)";
            d[IRenderer_UpdateCounters] = "IRenderer.UpdateCounters()";
            d[IRenderer_PreFrame] = "IRenderer.PreFrame()";
            d[IRenderer_ReportCounter] = "IRenderer.ReportCounter(CounterType,EventHandler<ulong>,float,bool)";
            d[IRenderer_ResetCounter] = "IRenderer.ResetCounter(CounterType)";
            d[IRenderer_WaitSync] = "IRenderer.WaitSync(ulong)";
            d[IRenderer_Initialize] = "IRenderer.Initialize(GraphicsDebugLevel)";
            d[IRenderer_SetInterruptAction] = "IRenderer.SetInterruptAction(Action<Action>)";
            d[IRenderer_Screenshot] = "IRenderer.Screenshot()";
            d[IWindow_Present] = "IWindow.Present(ITexture,ImageCrop,Action)";
            d[IWindow_SetSize] = "IWindow.SetSize(int,int)";
            d[IWindow_ChangeVSyncMode] = "IWindow.ChangeVSyncMode(VSyncMode)";
            d[IWindow_SetAntiAliasing] = "IWindow.SetAntiAliasing(AntiAliasing)";
            d[IWindow_SetScalingFilter] = "IWindow.SetScalingFilter(ScalingFilter)";
            d[IWindow_SetScalingFilterLevel] = "IWindow.SetScalingFilterLevel(float)";
            d[IWindow_SetColorSpacePassthrough] = "IWindow.SetColorSpacePassthrough(bool)";
            foreach ((uint k, string v) in ObjOps.Names) d[k] = v;
            return d;
        }
    }

    /// <summary>录像头里的能力表：按 Capabilities 字段声明顺序逐字段写（枚举 i32）。</summary>
    public static class CapsIO
    {
        public static readonly string[] Fields = { "Api", "VendorName", "MemoryType", "HasFrontFacingBug", "HasVectorIndexingBug", "NeedsFragmentOutputSpecialization", "ReduceShaderPrecision", "SupportsAstcCompression", "SupportsBc123Compression", "SupportsBc45Compression", "SupportsBc67Compression", "SupportsEtc2Compression", "Supports3DTextureCompression", "SupportsBgraFormat", "SupportsR4G4Format", "SupportsR4G4B4A4Format", "SupportsScaledVertexFormats", "SupportsSnormBufferTextureFormat", "SupportsSparseBuffer", "Supports5BitComponentFormat", "SupportsBlendEquationAdvanced", "SupportsFragmentShaderInterlock", "SupportsFragmentShaderOrderingIntel", "SupportsGeometryShader", "SupportsGeometryShaderPassthrough", "SupportsTransformFeedback", "SupportsImageLoadFormatted", "SupportsLayerVertexTessellation", "SupportsMismatchingViewFormat", "SupportsCubemapView", "SupportsNonConstantTextureOffset", "SupportsQuads", "SupportsSeparateSampler", "SupportsShaderBallot", "SupportsShaderBarrierDivergence", "SupportsShaderFloat64", "SupportsShaderNonUniformIndexing", "SupportsTextureGatherOffsets", "SupportsTextureShadowLod", "SupportsVertexStoreAndAtomics", "SupportsViewportIndexVertexTessellation", "SupportsViewportMask", "SupportsViewportSwizzle", "SupportsIndirectParameters", "SupportsDepthClipControl", "UniformBufferSetIndex", "StorageBufferSetIndex", "TextureSetIndex", "ImageSetIndex", "ExtraSetBaseIndex", "MaximumExtraSets", "MaximumUniformBuffersPerStage", "MaximumStorageBuffersPerStage", "MaximumTexturesPerStage", "MaximumImagesPerStage", "MaximumComputeSharedMemorySize", "MaximumSupportedAnisotropy", "ShaderSubgroupSize", "StorageBufferOffsetAlignment", "TextureBufferOffsetAlignment", "GatherBiasPrecision", "MaximumGpuMemory" };

        public static void Write(IBufferWriter<byte> w, in Capabilities c)
        {
            W.I32(w, (int)c.Api);
            W.Str(w, c.VendorName);
            W.I32(w, (int)c.MemoryType);
            W.Bool(w, c.HasFrontFacingBug);
            W.Bool(w, c.HasVectorIndexingBug);
            W.Bool(w, c.NeedsFragmentOutputSpecialization);
            W.Bool(w, c.ReduceShaderPrecision);
            W.Bool(w, c.SupportsAstcCompression);
            W.Bool(w, c.SupportsBc123Compression);
            W.Bool(w, c.SupportsBc45Compression);
            W.Bool(w, c.SupportsBc67Compression);
            W.Bool(w, c.SupportsEtc2Compression);
            W.Bool(w, c.Supports3DTextureCompression);
            W.Bool(w, c.SupportsBgraFormat);
            W.Bool(w, c.SupportsR4G4Format);
            W.Bool(w, c.SupportsR4G4B4A4Format);
            W.Bool(w, c.SupportsScaledVertexFormats);
            W.Bool(w, c.SupportsSnormBufferTextureFormat);
            W.Bool(w, c.SupportsSparseBuffer);
            W.Bool(w, c.Supports5BitComponentFormat);
            W.Bool(w, c.SupportsBlendEquationAdvanced);
            W.Bool(w, c.SupportsFragmentShaderInterlock);
            W.Bool(w, c.SupportsFragmentShaderOrderingIntel);
            W.Bool(w, c.SupportsGeometryShader);
            W.Bool(w, c.SupportsGeometryShaderPassthrough);
            W.Bool(w, c.SupportsTransformFeedback);
            W.Bool(w, c.SupportsImageLoadFormatted);
            W.Bool(w, c.SupportsLayerVertexTessellation);
            W.Bool(w, c.SupportsMismatchingViewFormat);
            W.Bool(w, c.SupportsCubemapView);
            W.Bool(w, c.SupportsNonConstantTextureOffset);
            W.Bool(w, c.SupportsQuads);
            W.Bool(w, c.SupportsSeparateSampler);
            W.Bool(w, c.SupportsShaderBallot);
            W.Bool(w, c.SupportsShaderBarrierDivergence);
            W.Bool(w, c.SupportsShaderFloat64);
            W.Bool(w, c.SupportsShaderNonUniformIndexing);
            W.Bool(w, c.SupportsTextureGatherOffsets);
            W.Bool(w, c.SupportsTextureShadowLod);
            W.Bool(w, c.SupportsVertexStoreAndAtomics);
            W.Bool(w, c.SupportsViewportIndexVertexTessellation);
            W.Bool(w, c.SupportsViewportMask);
            W.Bool(w, c.SupportsViewportSwizzle);
            W.Bool(w, c.SupportsIndirectParameters);
            W.Bool(w, c.SupportsDepthClipControl);
            W.I32(w, c.UniformBufferSetIndex);
            W.I32(w, c.StorageBufferSetIndex);
            W.I32(w, c.TextureSetIndex);
            W.I32(w, c.ImageSetIndex);
            W.I32(w, c.ExtraSetBaseIndex);
            W.I32(w, c.MaximumExtraSets);
            W.U32(w, c.MaximumUniformBuffersPerStage);
            W.U32(w, c.MaximumStorageBuffersPerStage);
            W.U32(w, c.MaximumTexturesPerStage);
            W.U32(w, c.MaximumImagesPerStage);
            W.I32(w, c.MaximumComputeSharedMemorySize);
            W.F32(w, c.MaximumSupportedAnisotropy);
            W.I32(w, c.ShaderSubgroupSize);
            W.I32(w, c.StorageBufferOffsetAlignment);
            W.I32(w, c.TextureBufferOffsetAlignment);
            W.I32(w, c.GatherBiasPrecision);
            W.U64(w, c.MaximumGpuMemory);
        }

        public static Capabilities Read(ref R rr)
        {
            var f0 = (TargetApi)rr.I32();
            var f1 = rr.Str();
            var f2 = (SystemMemoryType)rr.I32();
            var f3 = rr.Bool();
            var f4 = rr.Bool();
            var f5 = rr.Bool();
            var f6 = rr.Bool();
            var f7 = rr.Bool();
            var f8 = rr.Bool();
            var f9 = rr.Bool();
            var f10 = rr.Bool();
            var f11 = rr.Bool();
            var f12 = rr.Bool();
            var f13 = rr.Bool();
            var f14 = rr.Bool();
            var f15 = rr.Bool();
            var f16 = rr.Bool();
            var f17 = rr.Bool();
            var f18 = rr.Bool();
            var f19 = rr.Bool();
            var f20 = rr.Bool();
            var f21 = rr.Bool();
            var f22 = rr.Bool();
            var f23 = rr.Bool();
            var f24 = rr.Bool();
            var f25 = rr.Bool();
            var f26 = rr.Bool();
            var f27 = rr.Bool();
            var f28 = rr.Bool();
            var f29 = rr.Bool();
            var f30 = rr.Bool();
            var f31 = rr.Bool();
            var f32 = rr.Bool();
            var f33 = rr.Bool();
            var f34 = rr.Bool();
            var f35 = rr.Bool();
            var f36 = rr.Bool();
            var f37 = rr.Bool();
            var f38 = rr.Bool();
            var f39 = rr.Bool();
            var f40 = rr.Bool();
            var f41 = rr.Bool();
            var f42 = rr.Bool();
            var f43 = rr.Bool();
            var f44 = rr.Bool();
            var f45 = rr.I32();
            var f46 = rr.I32();
            var f47 = rr.I32();
            var f48 = rr.I32();
            var f49 = rr.I32();
            var f50 = rr.I32();
            var f51 = rr.U32();
            var f52 = rr.U32();
            var f53 = rr.U32();
            var f54 = rr.U32();
            var f55 = rr.I32();
            var f56 = rr.F32();
            var f57 = rr.I32();
            var f58 = rr.I32();
            var f59 = rr.I32();
            var f60 = rr.I32();
            var f61 = rr.U64();
            return new Capabilities(f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f19, f18, f20, f21, f22, f23, f24, f25, f26, f27, f28, f29, f30, f31, f32, f33, f34, f35, f36, f37, f38, f39, f40, f41, f42, f43, f44, f45, f46, f47, f48, f49, f50, f51, f52, f53, f54, f55, f56, f57, f58, f59, f60, f61);
        }

        public static byte[] Bytes(in Capabilities c) { ArrayBufferWriter<byte> w = new(); Write(w, c); return w.WrittenSpan.ToArray(); }

        /// <summary>逐字段比，返回不同的字段（名字=录像值/目标值）。</summary>
        public static List<string> Diff(in Capabilities a, in Capabilities b)
        {
            List<string> d = new();
            if (!Equals(a.Api, b.Api)) d.Add($"Api={a.Api}/{b.Api}");
            if (!Equals(a.VendorName, b.VendorName)) d.Add($"VendorName={a.VendorName}/{b.VendorName}");
            if (!Equals(a.MemoryType, b.MemoryType)) d.Add($"MemoryType={a.MemoryType}/{b.MemoryType}");
            if (!Equals(a.HasFrontFacingBug, b.HasFrontFacingBug)) d.Add($"HasFrontFacingBug={a.HasFrontFacingBug}/{b.HasFrontFacingBug}");
            if (!Equals(a.HasVectorIndexingBug, b.HasVectorIndexingBug)) d.Add($"HasVectorIndexingBug={a.HasVectorIndexingBug}/{b.HasVectorIndexingBug}");
            if (!Equals(a.NeedsFragmentOutputSpecialization, b.NeedsFragmentOutputSpecialization)) d.Add($"NeedsFragmentOutputSpecialization={a.NeedsFragmentOutputSpecialization}/{b.NeedsFragmentOutputSpecialization}");
            if (!Equals(a.ReduceShaderPrecision, b.ReduceShaderPrecision)) d.Add($"ReduceShaderPrecision={a.ReduceShaderPrecision}/{b.ReduceShaderPrecision}");
            if (!Equals(a.SupportsAstcCompression, b.SupportsAstcCompression)) d.Add($"SupportsAstcCompression={a.SupportsAstcCompression}/{b.SupportsAstcCompression}");
            if (!Equals(a.SupportsBc123Compression, b.SupportsBc123Compression)) d.Add($"SupportsBc123Compression={a.SupportsBc123Compression}/{b.SupportsBc123Compression}");
            if (!Equals(a.SupportsBc45Compression, b.SupportsBc45Compression)) d.Add($"SupportsBc45Compression={a.SupportsBc45Compression}/{b.SupportsBc45Compression}");
            if (!Equals(a.SupportsBc67Compression, b.SupportsBc67Compression)) d.Add($"SupportsBc67Compression={a.SupportsBc67Compression}/{b.SupportsBc67Compression}");
            if (!Equals(a.SupportsEtc2Compression, b.SupportsEtc2Compression)) d.Add($"SupportsEtc2Compression={a.SupportsEtc2Compression}/{b.SupportsEtc2Compression}");
            if (!Equals(a.Supports3DTextureCompression, b.Supports3DTextureCompression)) d.Add($"Supports3DTextureCompression={a.Supports3DTextureCompression}/{b.Supports3DTextureCompression}");
            if (!Equals(a.SupportsBgraFormat, b.SupportsBgraFormat)) d.Add($"SupportsBgraFormat={a.SupportsBgraFormat}/{b.SupportsBgraFormat}");
            if (!Equals(a.SupportsR4G4Format, b.SupportsR4G4Format)) d.Add($"SupportsR4G4Format={a.SupportsR4G4Format}/{b.SupportsR4G4Format}");
            if (!Equals(a.SupportsR4G4B4A4Format, b.SupportsR4G4B4A4Format)) d.Add($"SupportsR4G4B4A4Format={a.SupportsR4G4B4A4Format}/{b.SupportsR4G4B4A4Format}");
            if (!Equals(a.SupportsScaledVertexFormats, b.SupportsScaledVertexFormats)) d.Add($"SupportsScaledVertexFormats={a.SupportsScaledVertexFormats}/{b.SupportsScaledVertexFormats}");
            if (!Equals(a.SupportsSnormBufferTextureFormat, b.SupportsSnormBufferTextureFormat)) d.Add($"SupportsSnormBufferTextureFormat={a.SupportsSnormBufferTextureFormat}/{b.SupportsSnormBufferTextureFormat}");
            if (!Equals(a.SupportsSparseBuffer, b.SupportsSparseBuffer)) d.Add($"SupportsSparseBuffer={a.SupportsSparseBuffer}/{b.SupportsSparseBuffer}");
            if (!Equals(a.Supports5BitComponentFormat, b.Supports5BitComponentFormat)) d.Add($"Supports5BitComponentFormat={a.Supports5BitComponentFormat}/{b.Supports5BitComponentFormat}");
            if (!Equals(a.SupportsBlendEquationAdvanced, b.SupportsBlendEquationAdvanced)) d.Add($"SupportsBlendEquationAdvanced={a.SupportsBlendEquationAdvanced}/{b.SupportsBlendEquationAdvanced}");
            if (!Equals(a.SupportsFragmentShaderInterlock, b.SupportsFragmentShaderInterlock)) d.Add($"SupportsFragmentShaderInterlock={a.SupportsFragmentShaderInterlock}/{b.SupportsFragmentShaderInterlock}");
            if (!Equals(a.SupportsFragmentShaderOrderingIntel, b.SupportsFragmentShaderOrderingIntel)) d.Add($"SupportsFragmentShaderOrderingIntel={a.SupportsFragmentShaderOrderingIntel}/{b.SupportsFragmentShaderOrderingIntel}");
            if (!Equals(a.SupportsGeometryShader, b.SupportsGeometryShader)) d.Add($"SupportsGeometryShader={a.SupportsGeometryShader}/{b.SupportsGeometryShader}");
            if (!Equals(a.SupportsGeometryShaderPassthrough, b.SupportsGeometryShaderPassthrough)) d.Add($"SupportsGeometryShaderPassthrough={a.SupportsGeometryShaderPassthrough}/{b.SupportsGeometryShaderPassthrough}");
            if (!Equals(a.SupportsTransformFeedback, b.SupportsTransformFeedback)) d.Add($"SupportsTransformFeedback={a.SupportsTransformFeedback}/{b.SupportsTransformFeedback}");
            if (!Equals(a.SupportsImageLoadFormatted, b.SupportsImageLoadFormatted)) d.Add($"SupportsImageLoadFormatted={a.SupportsImageLoadFormatted}/{b.SupportsImageLoadFormatted}");
            if (!Equals(a.SupportsLayerVertexTessellation, b.SupportsLayerVertexTessellation)) d.Add($"SupportsLayerVertexTessellation={a.SupportsLayerVertexTessellation}/{b.SupportsLayerVertexTessellation}");
            if (!Equals(a.SupportsMismatchingViewFormat, b.SupportsMismatchingViewFormat)) d.Add($"SupportsMismatchingViewFormat={a.SupportsMismatchingViewFormat}/{b.SupportsMismatchingViewFormat}");
            if (!Equals(a.SupportsCubemapView, b.SupportsCubemapView)) d.Add($"SupportsCubemapView={a.SupportsCubemapView}/{b.SupportsCubemapView}");
            if (!Equals(a.SupportsNonConstantTextureOffset, b.SupportsNonConstantTextureOffset)) d.Add($"SupportsNonConstantTextureOffset={a.SupportsNonConstantTextureOffset}/{b.SupportsNonConstantTextureOffset}");
            if (!Equals(a.SupportsQuads, b.SupportsQuads)) d.Add($"SupportsQuads={a.SupportsQuads}/{b.SupportsQuads}");
            if (!Equals(a.SupportsSeparateSampler, b.SupportsSeparateSampler)) d.Add($"SupportsSeparateSampler={a.SupportsSeparateSampler}/{b.SupportsSeparateSampler}");
            if (!Equals(a.SupportsShaderBallot, b.SupportsShaderBallot)) d.Add($"SupportsShaderBallot={a.SupportsShaderBallot}/{b.SupportsShaderBallot}");
            if (!Equals(a.SupportsShaderBarrierDivergence, b.SupportsShaderBarrierDivergence)) d.Add($"SupportsShaderBarrierDivergence={a.SupportsShaderBarrierDivergence}/{b.SupportsShaderBarrierDivergence}");
            if (!Equals(a.SupportsShaderFloat64, b.SupportsShaderFloat64)) d.Add($"SupportsShaderFloat64={a.SupportsShaderFloat64}/{b.SupportsShaderFloat64}");
            if (!Equals(a.SupportsShaderNonUniformIndexing, b.SupportsShaderNonUniformIndexing)) d.Add($"SupportsShaderNonUniformIndexing={a.SupportsShaderNonUniformIndexing}/{b.SupportsShaderNonUniformIndexing}");
            if (!Equals(a.SupportsTextureGatherOffsets, b.SupportsTextureGatherOffsets)) d.Add($"SupportsTextureGatherOffsets={a.SupportsTextureGatherOffsets}/{b.SupportsTextureGatherOffsets}");
            if (!Equals(a.SupportsTextureShadowLod, b.SupportsTextureShadowLod)) d.Add($"SupportsTextureShadowLod={a.SupportsTextureShadowLod}/{b.SupportsTextureShadowLod}");
            if (!Equals(a.SupportsVertexStoreAndAtomics, b.SupportsVertexStoreAndAtomics)) d.Add($"SupportsVertexStoreAndAtomics={a.SupportsVertexStoreAndAtomics}/{b.SupportsVertexStoreAndAtomics}");
            if (!Equals(a.SupportsViewportIndexVertexTessellation, b.SupportsViewportIndexVertexTessellation)) d.Add($"SupportsViewportIndexVertexTessellation={a.SupportsViewportIndexVertexTessellation}/{b.SupportsViewportIndexVertexTessellation}");
            if (!Equals(a.SupportsViewportMask, b.SupportsViewportMask)) d.Add($"SupportsViewportMask={a.SupportsViewportMask}/{b.SupportsViewportMask}");
            if (!Equals(a.SupportsViewportSwizzle, b.SupportsViewportSwizzle)) d.Add($"SupportsViewportSwizzle={a.SupportsViewportSwizzle}/{b.SupportsViewportSwizzle}");
            if (!Equals(a.SupportsIndirectParameters, b.SupportsIndirectParameters)) d.Add($"SupportsIndirectParameters={a.SupportsIndirectParameters}/{b.SupportsIndirectParameters}");
            if (!Equals(a.SupportsDepthClipControl, b.SupportsDepthClipControl)) d.Add($"SupportsDepthClipControl={a.SupportsDepthClipControl}/{b.SupportsDepthClipControl}");
            if (!Equals(a.UniformBufferSetIndex, b.UniformBufferSetIndex)) d.Add($"UniformBufferSetIndex={a.UniformBufferSetIndex}/{b.UniformBufferSetIndex}");
            if (!Equals(a.StorageBufferSetIndex, b.StorageBufferSetIndex)) d.Add($"StorageBufferSetIndex={a.StorageBufferSetIndex}/{b.StorageBufferSetIndex}");
            if (!Equals(a.TextureSetIndex, b.TextureSetIndex)) d.Add($"TextureSetIndex={a.TextureSetIndex}/{b.TextureSetIndex}");
            if (!Equals(a.ImageSetIndex, b.ImageSetIndex)) d.Add($"ImageSetIndex={a.ImageSetIndex}/{b.ImageSetIndex}");
            if (!Equals(a.ExtraSetBaseIndex, b.ExtraSetBaseIndex)) d.Add($"ExtraSetBaseIndex={a.ExtraSetBaseIndex}/{b.ExtraSetBaseIndex}");
            if (!Equals(a.MaximumExtraSets, b.MaximumExtraSets)) d.Add($"MaximumExtraSets={a.MaximumExtraSets}/{b.MaximumExtraSets}");
            if (!Equals(a.MaximumUniformBuffersPerStage, b.MaximumUniformBuffersPerStage)) d.Add($"MaximumUniformBuffersPerStage={a.MaximumUniformBuffersPerStage}/{b.MaximumUniformBuffersPerStage}");
            if (!Equals(a.MaximumStorageBuffersPerStage, b.MaximumStorageBuffersPerStage)) d.Add($"MaximumStorageBuffersPerStage={a.MaximumStorageBuffersPerStage}/{b.MaximumStorageBuffersPerStage}");
            if (!Equals(a.MaximumTexturesPerStage, b.MaximumTexturesPerStage)) d.Add($"MaximumTexturesPerStage={a.MaximumTexturesPerStage}/{b.MaximumTexturesPerStage}");
            if (!Equals(a.MaximumImagesPerStage, b.MaximumImagesPerStage)) d.Add($"MaximumImagesPerStage={a.MaximumImagesPerStage}/{b.MaximumImagesPerStage}");
            if (!Equals(a.MaximumComputeSharedMemorySize, b.MaximumComputeSharedMemorySize)) d.Add($"MaximumComputeSharedMemorySize={a.MaximumComputeSharedMemorySize}/{b.MaximumComputeSharedMemorySize}");
            if (!Equals(a.MaximumSupportedAnisotropy, b.MaximumSupportedAnisotropy)) d.Add($"MaximumSupportedAnisotropy={a.MaximumSupportedAnisotropy}/{b.MaximumSupportedAnisotropy}");
            if (!Equals(a.ShaderSubgroupSize, b.ShaderSubgroupSize)) d.Add($"ShaderSubgroupSize={a.ShaderSubgroupSize}/{b.ShaderSubgroupSize}");
            if (!Equals(a.StorageBufferOffsetAlignment, b.StorageBufferOffsetAlignment)) d.Add($"StorageBufferOffsetAlignment={a.StorageBufferOffsetAlignment}/{b.StorageBufferOffsetAlignment}");
            if (!Equals(a.TextureBufferOffsetAlignment, b.TextureBufferOffsetAlignment)) d.Add($"TextureBufferOffsetAlignment={a.TextureBufferOffsetAlignment}/{b.TextureBufferOffsetAlignment}");
            if (!Equals(a.GatherBiasPrecision, b.GatherBiasPrecision)) d.Add($"GatherBiasPrecision={a.GatherBiasPrecision}/{b.GatherBiasPrecision}");
            if (!Equals(a.MaximumGpuMemory, b.MaximumGpuMemory)) d.Add($"MaximumGpuMemory={a.MaximumGpuMemory}/{b.MaximumGpuMemory}");
            return d;
        }
    }

    public sealed class RecordingPipeline : IPipeline
    {
        readonly IPipeline _obs, _inner;
        readonly GalRecorder _r;
        public RecordingPipeline(IPipeline observer, IPipeline inner, GalRecorder recorder) { _obs = observer; _inner = inner; _r = recorder; }

        public void Barrier()
        {
            _obs?.Barrier(); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.Barrier(); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.Barrier")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin();  _r.Emit(GalOps.IPipeline_Barrier, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.Barrier(); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.Barrier")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void BeginTransformFeedback(PrimitiveTopology topology)
        {
            _obs?.BeginTransformFeedback(topology); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.BeginTransformFeedback(topology); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.BeginTransformFeedback")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, (int)topology); _r.Emit(GalOps.IPipeline_BeginTransformFeedback, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.BeginTransformFeedback(topology); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.BeginTransformFeedback")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void ClearBuffer(BufferHandle destination, int offset, int size, uint value)
        {
            _obs?.ClearBuffer(destination, offset, size, value); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.ClearBuffer(destination, offset, size, value); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.ClearBuffer")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Blit(p, destination); W.I32(p, offset); W.I32(p, size); W.U32(p, value); _r.Emit(GalOps.IPipeline_ClearBuffer, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.ClearBuffer(_r.In(destination), offset, size, value); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.ClearBuffer")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void ClearRenderTargetColor(int index, int layer, int layerCount, uint componentMask, ColorF color)
        {
            _obs?.ClearRenderTargetColor(index, layer, layerCount, componentMask, color); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.ClearRenderTargetColor(index, layer, layerCount, componentMask, color); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.ClearRenderTargetColor")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, index); W.I32(p, layer); W.I32(p, layerCount); W.U32(p, componentMask); W.Blit(p, color); _r.Emit(GalOps.IPipeline_ClearRenderTargetColor, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.ClearRenderTargetColor(index, layer, layerCount, componentMask, color); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.ClearRenderTargetColor")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void ClearRenderTargetDepthStencil(int layer, int layerCount, float depthValue, bool depthMask, int stencilValue, int stencilMask)
        {
            _obs?.ClearRenderTargetDepthStencil(layer, layerCount, depthValue, depthMask, stencilValue, stencilMask); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.ClearRenderTargetDepthStencil(layer, layerCount, depthValue, depthMask, stencilValue, stencilMask); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.ClearRenderTargetDepthStencil")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, layer); W.I32(p, layerCount); W.F32(p, depthValue); W.Bool(p, depthMask); W.I32(p, stencilValue); W.I32(p, stencilMask); _r.Emit(GalOps.IPipeline_ClearRenderTargetDepthStencil, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.ClearRenderTargetDepthStencil(layer, layerCount, depthValue, depthMask, stencilValue, stencilMask); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.ClearRenderTargetDepthStencil")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void CommandBufferBarrier()
        {
            _obs?.CommandBufferBarrier(); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.CommandBufferBarrier(); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.CommandBufferBarrier")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin();  _r.Emit(GalOps.IPipeline_CommandBufferBarrier, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.CommandBufferBarrier(); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.CommandBufferBarrier")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void CopyBuffer(BufferHandle source, BufferHandle destination, int srcOffset, int dstOffset, int size)
        {
            _obs?.CopyBuffer(source, destination, srcOffset, dstOffset, size); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.CopyBuffer(source, destination, srcOffset, dstOffset, size); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.CopyBuffer")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Blit(p, source); W.Blit(p, destination); W.I32(p, srcOffset); W.I32(p, dstOffset); W.I32(p, size); _r.Emit(GalOps.IPipeline_CopyBuffer, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.CopyBuffer(_r.In(source), _r.In(destination), srcOffset, dstOffset, size); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.CopyBuffer")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void DispatchCompute(int groupsX, int groupsY, int groupsZ)
        {
            _obs?.DispatchCompute(groupsX, groupsY, groupsZ); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.DispatchCompute(groupsX, groupsY, groupsZ); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.DispatchCompute")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, groupsX); W.I32(p, groupsY); W.I32(p, groupsZ); _r.Emit(GalOps.IPipeline_DispatchCompute, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.DispatchCompute(groupsX, groupsY, groupsZ); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.DispatchCompute")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void Draw(int vertexCount, int instanceCount, int firstVertex, int firstInstance)
        {
            _obs?.Draw(vertexCount, instanceCount, firstVertex, firstInstance); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.Draw(vertexCount, instanceCount, firstVertex, firstInstance); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.Draw")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, vertexCount); W.I32(p, instanceCount); W.I32(p, firstVertex); W.I32(p, firstInstance); _r.Emit(GalOps.IPipeline_Draw, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.Draw(vertexCount, instanceCount, firstVertex, firstInstance); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.Draw")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void DrawIndexed(int indexCount, int instanceCount, int firstIndex, int firstVertex, int firstInstance)
        {
            _obs?.DrawIndexed(indexCount, instanceCount, firstIndex, firstVertex, firstInstance); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.DrawIndexed(indexCount, instanceCount, firstIndex, firstVertex, firstInstance); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.DrawIndexed")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, indexCount); W.I32(p, instanceCount); W.I32(p, firstIndex); W.I32(p, firstVertex); W.I32(p, firstInstance); _r.Emit(GalOps.IPipeline_DrawIndexed, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.DrawIndexed(indexCount, instanceCount, firstIndex, firstVertex, firstInstance); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.DrawIndexed")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void DrawIndexedIndirect(BufferRange indirectBuffer)
        {
            _obs?.DrawIndexedIndirect(indirectBuffer); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.DrawIndexedIndirect(indirectBuffer); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.DrawIndexedIndirect")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Blit(p, indirectBuffer); _r.Emit(GalOps.IPipeline_DrawIndexedIndirect, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.DrawIndexedIndirect(_r.In(indirectBuffer)); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.DrawIndexedIndirect")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void DrawIndexedIndirectCount(BufferRange indirectBuffer, BufferRange parameterBuffer, int maxDrawCount, int stride)
        {
            _obs?.DrawIndexedIndirectCount(indirectBuffer, parameterBuffer, maxDrawCount, stride); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.DrawIndexedIndirectCount(indirectBuffer, parameterBuffer, maxDrawCount, stride); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.DrawIndexedIndirectCount")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Blit(p, indirectBuffer); W.Blit(p, parameterBuffer); W.I32(p, maxDrawCount); W.I32(p, stride); _r.Emit(GalOps.IPipeline_DrawIndexedIndirectCount, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.DrawIndexedIndirectCount(_r.In(indirectBuffer), _r.In(parameterBuffer), maxDrawCount, stride); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.DrawIndexedIndirectCount")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void DrawIndirect(BufferRange indirectBuffer)
        {
            _obs?.DrawIndirect(indirectBuffer); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.DrawIndirect(indirectBuffer); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.DrawIndirect")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Blit(p, indirectBuffer); _r.Emit(GalOps.IPipeline_DrawIndirect, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.DrawIndirect(_r.In(indirectBuffer)); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.DrawIndirect")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void DrawIndirectCount(BufferRange indirectBuffer, BufferRange parameterBuffer, int maxDrawCount, int stride)
        {
            _obs?.DrawIndirectCount(indirectBuffer, parameterBuffer, maxDrawCount, stride); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.DrawIndirectCount(indirectBuffer, parameterBuffer, maxDrawCount, stride); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.DrawIndirectCount")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Blit(p, indirectBuffer); W.Blit(p, parameterBuffer); W.I32(p, maxDrawCount); W.I32(p, stride); _r.Emit(GalOps.IPipeline_DrawIndirectCount, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.DrawIndirectCount(_r.In(indirectBuffer), _r.In(parameterBuffer), maxDrawCount, stride); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.DrawIndirectCount")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void DrawTexture(ITexture texture, ISampler sampler, Extents2DF srcRegion, Extents2DF dstRegion)
        {
            _obs?.DrawTexture(texture, sampler, srcRegion, dstRegion); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.DrawTexture(texture, sampler, srcRegion, dstRegion); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.DrawTexture")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.U32(p, GalRecorder.IdOf(texture)); W.U32(p, GalRecorder.IdOf(sampler)); W.Blit(p, srcRegion); W.Blit(p, dstRegion); _r.Emit(GalOps.IPipeline_DrawTexture, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.DrawTexture(GalRecorder.U(texture), GalRecorder.U(sampler), srcRegion, dstRegion); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.DrawTexture")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void EndTransformFeedback()
        {
            _obs?.EndTransformFeedback(); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.EndTransformFeedback(); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.EndTransformFeedback")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin();  _r.Emit(GalOps.IPipeline_EndTransformFeedback, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.EndTransformFeedback(); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.EndTransformFeedback")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetAlphaTest(bool enable, float reference, CompareOp op)
        {
            _obs?.SetAlphaTest(enable, reference, op); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetAlphaTest(enable, reference, op); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetAlphaTest")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Bool(p, enable); W.F32(p, reference); W.I32(p, (int)op); _r.Emit(GalOps.IPipeline_SetAlphaTest, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetAlphaTest(enable, reference, op); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetAlphaTest")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetBlendState(AdvancedBlendDescriptor blend)
        {
            _obs?.SetBlendState(blend); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetBlendState(blend); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetBlendState")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Blit(p, blend); _r.Emit(GalOps.IPipeline_SetBlendState_1, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetBlendState(blend); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetBlendState")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetBlendState(int index, BlendDescriptor blend)
        {
            _obs?.SetBlendState(index, blend); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetBlendState(index, blend); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetBlendState")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, index); W.Blit(p, blend); _r.Emit(GalOps.IPipeline_SetBlendState_2, p, 4);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetBlendState(index, blend); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetBlendState")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetDepthBias(PolygonModeMask enables, float factor, float units, float clamp)
        {
            _obs?.SetDepthBias(enables, factor, units, clamp); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetDepthBias(enables, factor, units, clamp); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetDepthBias")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, (int)enables); W.F32(p, factor); W.F32(p, units); W.F32(p, clamp); _r.Emit(GalOps.IPipeline_SetDepthBias, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetDepthBias(enables, factor, units, clamp); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetDepthBias")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetDepthClamp(bool clamp)
        {
            _obs?.SetDepthClamp(clamp); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetDepthClamp(clamp); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetDepthClamp")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Bool(p, clamp); _r.Emit(GalOps.IPipeline_SetDepthClamp, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetDepthClamp(clamp); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetDepthClamp")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetDepthMode(DepthMode mode)
        {
            _obs?.SetDepthMode(mode); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetDepthMode(mode); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetDepthMode")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, (int)mode); _r.Emit(GalOps.IPipeline_SetDepthMode, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetDepthMode(mode); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetDepthMode")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetDepthTest(DepthTestDescriptor depthTest)
        {
            _obs?.SetDepthTest(depthTest); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetDepthTest(depthTest); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetDepthTest")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Blit(p, depthTest); _r.Emit(GalOps.IPipeline_SetDepthTest, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetDepthTest(depthTest); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetDepthTest")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetFaceCulling(bool enable, Face face)
        {
            _obs?.SetFaceCulling(enable, face); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetFaceCulling(enable, face); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetFaceCulling")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Bool(p, enable); W.I32(p, (int)face); _r.Emit(GalOps.IPipeline_SetFaceCulling, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetFaceCulling(enable, face); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetFaceCulling")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetFrontFace(FrontFace frontFace)
        {
            _obs?.SetFrontFace(frontFace); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetFrontFace(frontFace); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetFrontFace")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, (int)frontFace); _r.Emit(GalOps.IPipeline_SetFrontFace, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetFrontFace(frontFace); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetFrontFace")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetIndexBuffer(BufferRange buffer, IndexType type)
        {
            _obs?.SetIndexBuffer(buffer, type); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetIndexBuffer(buffer, type); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetIndexBuffer")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Blit(p, buffer); W.I32(p, (int)type); _r.Emit(GalOps.IPipeline_SetIndexBuffer, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetIndexBuffer(_r.In(buffer), type); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetIndexBuffer")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetImage(ShaderStage stage, int binding, ITexture texture)
        {
            _obs?.SetImage(stage, binding, texture); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetImage(stage, binding, texture); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetImage")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, (int)stage); W.I32(p, binding); W.U32(p, GalRecorder.IdOf(texture)); _r.Emit(GalOps.IPipeline_SetImage, p, 8);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetImage(stage, binding, GalRecorder.U(texture)); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetImage")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetImageArray(ShaderStage stage, int binding, IImageArray array)
        {
            _obs?.SetImageArray(stage, binding, array); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetImageArray(stage, binding, array); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetImageArray")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, (int)stage); W.I32(p, binding); W.U32(p, GalRecorder.IdOf(array)); _r.Emit(GalOps.IPipeline_SetImageArray, p, 8);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetImageArray(stage, binding, GalRecorder.U(array)); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetImageArray")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetImageArraySeparate(ShaderStage stage, int setIndex, IImageArray array)
        {
            _obs?.SetImageArraySeparate(stage, setIndex, array); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetImageArraySeparate(stage, setIndex, array); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetImageArraySeparate")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, (int)stage); W.I32(p, setIndex); W.U32(p, GalRecorder.IdOf(array)); _r.Emit(GalOps.IPipeline_SetImageArraySeparate, p, 8);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetImageArraySeparate(stage, setIndex, GalRecorder.U(array)); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetImageArraySeparate")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetLineParameters(float width, bool smooth)
        {
            _obs?.SetLineParameters(width, smooth); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetLineParameters(width, smooth); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetLineParameters")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.F32(p, width); W.Bool(p, smooth); _r.Emit(GalOps.IPipeline_SetLineParameters, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetLineParameters(width, smooth); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetLineParameters")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetLogicOpState(bool enable, LogicalOp op)
        {
            _obs?.SetLogicOpState(enable, op); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetLogicOpState(enable, op); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetLogicOpState")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Bool(p, enable); W.I32(p, (int)op); _r.Emit(GalOps.IPipeline_SetLogicOpState, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetLogicOpState(enable, op); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetLogicOpState")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetMultisampleState(MultisampleDescriptor multisample)
        {
            _obs?.SetMultisampleState(multisample); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetMultisampleState(multisample); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetMultisampleState")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Blit(p, multisample); _r.Emit(GalOps.IPipeline_SetMultisampleState, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetMultisampleState(multisample); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetMultisampleState")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetPatchParameters(int vertices, ReadOnlySpan<float> defaultOuterLevel, ReadOnlySpan<float> defaultInnerLevel)
        {
            _obs?.SetPatchParameters(vertices, defaultOuterLevel, defaultInnerLevel); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetPatchParameters(vertices, defaultOuterLevel, defaultInnerLevel); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetPatchParameters")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, vertices); W.Span(p, defaultOuterLevel); W.Span(p, defaultInnerLevel); _r.Emit(GalOps.IPipeline_SetPatchParameters, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetPatchParameters(vertices, defaultOuterLevel, defaultInnerLevel); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetPatchParameters")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetPointParameters(float size, bool isProgramPointSize, bool enablePointSprite, Origin origin)
        {
            _obs?.SetPointParameters(size, isProgramPointSize, enablePointSprite, origin); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetPointParameters(size, isProgramPointSize, enablePointSprite, origin); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetPointParameters")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.F32(p, size); W.Bool(p, isProgramPointSize); W.Bool(p, enablePointSprite); W.I32(p, (int)origin); _r.Emit(GalOps.IPipeline_SetPointParameters, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetPointParameters(size, isProgramPointSize, enablePointSprite, origin); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetPointParameters")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetPolygonMode(PolygonMode frontMode, PolygonMode backMode)
        {
            _obs?.SetPolygonMode(frontMode, backMode); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetPolygonMode(frontMode, backMode); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetPolygonMode")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, (int)frontMode); W.I32(p, (int)backMode); _r.Emit(GalOps.IPipeline_SetPolygonMode, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetPolygonMode(frontMode, backMode); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetPolygonMode")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetPrimitiveRestart(bool enable, int index)
        {
            _obs?.SetPrimitiveRestart(enable, index); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetPrimitiveRestart(enable, index); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetPrimitiveRestart")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Bool(p, enable); W.I32(p, index); _r.Emit(GalOps.IPipeline_SetPrimitiveRestart, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetPrimitiveRestart(enable, index); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetPrimitiveRestart")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetPrimitiveTopology(PrimitiveTopology topology)
        {
            _obs?.SetPrimitiveTopology(topology); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetPrimitiveTopology(topology); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetPrimitiveTopology")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, (int)topology); _r.Emit(GalOps.IPipeline_SetPrimitiveTopology, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetPrimitiveTopology(topology); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetPrimitiveTopology")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetProgram(IProgram program)
        {
            _obs?.SetProgram(program); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetProgram(program); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetProgram")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.U32(p, GalRecorder.IdOf(program)); _r.Emit(GalOps.IPipeline_SetProgram, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetProgram(GalRecorder.U(program)); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetProgram")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetRasterizerDiscard(bool discard)
        {
            _obs?.SetRasterizerDiscard(discard); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetRasterizerDiscard(discard); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetRasterizerDiscard")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Bool(p, discard); _r.Emit(GalOps.IPipeline_SetRasterizerDiscard, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetRasterizerDiscard(discard); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetRasterizerDiscard")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetRenderTargetColorMasks(ReadOnlySpan<uint> componentMask)
        {
            _obs?.SetRenderTargetColorMasks(componentMask); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetRenderTargetColorMasks(componentMask); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetRenderTargetColorMasks")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Span(p, componentMask); _r.EmitSpan(GalOps.IPipeline_SetRenderTargetColorMasks, p, componentMask);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetRenderTargetColorMasks(componentMask); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetRenderTargetColorMasks")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetRenderTargets(Span<ITexture> colors, ITexture depthStencil)
        {
            _obs?.SetRenderTargets(colors, depthStencil); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetRenderTargets(colors, depthStencil); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetRenderTargets")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); GalRecorder.Ids(p, colors); W.U32(p, GalRecorder.IdOf(depthStencil)); _r.Emit(GalOps.IPipeline_SetRenderTargets, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetRenderTargets(GalRecorder.U(colors).AsSpan(), GalRecorder.U(depthStencil)); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetRenderTargets")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetScissors(ReadOnlySpan<Rectangle<int>> regions)
        {
            _obs?.SetScissors(regions); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetScissors(regions); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetScissors")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Span(p, regions); _r.EmitSpan(GalOps.IPipeline_SetScissors, p, regions);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetScissors(regions); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetScissors")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetStencilTest(StencilTestDescriptor stencilTest)
        {
            _obs?.SetStencilTest(stencilTest); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetStencilTest(stencilTest); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetStencilTest")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Blit(p, stencilTest); _r.Emit(GalOps.IPipeline_SetStencilTest, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetStencilTest(stencilTest); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetStencilTest")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetStorageBuffers(ReadOnlySpan<BufferAssignment> buffers)
        {
            _obs?.SetStorageBuffers(buffers); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetStorageBuffers(buffers); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetStorageBuffers")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Span(p, buffers); _r.EmitBindings(GalOps.IPipeline_SetStorageBuffers, p, buffers);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetStorageBuffers(_r.In(buffers)); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetStorageBuffers")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetTextureAndSampler(ShaderStage stage, int binding, ITexture texture, ISampler sampler)
        {
            _obs?.SetTextureAndSampler(stage, binding, texture, sampler); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetTextureAndSampler(stage, binding, texture, sampler); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetTextureAndSampler")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, (int)stage); W.I32(p, binding); W.U32(p, GalRecorder.IdOf(texture)); W.U32(p, GalRecorder.IdOf(sampler)); _r.Emit(GalOps.IPipeline_SetTextureAndSampler, p, 8);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetTextureAndSampler(stage, binding, GalRecorder.U(texture), GalRecorder.U(sampler)); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetTextureAndSampler")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetTextureArray(ShaderStage stage, int binding, ITextureArray array)
        {
            _obs?.SetTextureArray(stage, binding, array); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetTextureArray(stage, binding, array); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetTextureArray")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, (int)stage); W.I32(p, binding); W.U32(p, GalRecorder.IdOf(array)); _r.Emit(GalOps.IPipeline_SetTextureArray, p, 8);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetTextureArray(stage, binding, GalRecorder.U(array)); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetTextureArray")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetTextureArraySeparate(ShaderStage stage, int setIndex, ITextureArray array)
        {
            _obs?.SetTextureArraySeparate(stage, setIndex, array); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetTextureArraySeparate(stage, setIndex, array); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetTextureArraySeparate")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, (int)stage); W.I32(p, setIndex); W.U32(p, GalRecorder.IdOf(array)); _r.Emit(GalOps.IPipeline_SetTextureArraySeparate, p, 8);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetTextureArraySeparate(stage, setIndex, GalRecorder.U(array)); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetTextureArraySeparate")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetTransformFeedbackBuffers(ReadOnlySpan<BufferRange> buffers)
        {
            _obs?.SetTransformFeedbackBuffers(buffers); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetTransformFeedbackBuffers(buffers); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetTransformFeedbackBuffers")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Span(p, buffers); _r.EmitSpan(GalOps.IPipeline_SetTransformFeedbackBuffers, p, buffers);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetTransformFeedbackBuffers(_r.In(buffers)); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetTransformFeedbackBuffers")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetUniformBuffers(ReadOnlySpan<BufferAssignment> buffers)
        {
            _obs?.SetUniformBuffers(buffers); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetUniformBuffers(buffers); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetUniformBuffers")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Span(p, buffers); _r.EmitBindings(GalOps.IPipeline_SetUniformBuffers, p, buffers);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetUniformBuffers(_r.In(buffers)); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetUniformBuffers")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetUserClipDistance(int index, bool enableClip)
        {
            _obs?.SetUserClipDistance(index, enableClip); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetUserClipDistance(index, enableClip); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetUserClipDistance")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, index); W.Bool(p, enableClip); _r.Emit(GalOps.IPipeline_SetUserClipDistance, p, 4);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetUserClipDistance(index, enableClip); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetUserClipDistance")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetVertexAttribs(ReadOnlySpan<VertexAttribDescriptor> vertexAttribs)
        {
            _obs?.SetVertexAttribs(vertexAttribs); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetVertexAttribs(vertexAttribs); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetVertexAttribs")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Span(p, vertexAttribs); _r.EmitSpan(GalOps.IPipeline_SetVertexAttribs, p, vertexAttribs);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetVertexAttribs(vertexAttribs); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetVertexAttribs")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetVertexBuffers(ReadOnlySpan<VertexBufferDescriptor> vertexBuffers)
        {
            _obs?.SetVertexBuffers(vertexBuffers); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetVertexBuffers(vertexBuffers); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetVertexBuffers")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Span(p, vertexBuffers); _r.EmitSpan(GalOps.IPipeline_SetVertexBuffers, p, vertexBuffers);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetVertexBuffers(_r.In(vertexBuffers)); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetVertexBuffers")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetViewports(ReadOnlySpan<Viewport> viewports)
        {
            _obs?.SetViewports(viewports); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetViewports(viewports); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetViewports")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Span(p, viewports); _r.EmitSpan(GalOps.IPipeline_SetViewports, p, viewports);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetViewports(viewports); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.SetViewports")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void TextureBarrier()
        {
            _obs?.TextureBarrier(); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.TextureBarrier(); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.TextureBarrier")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin();  _r.Emit(GalOps.IPipeline_TextureBarrier, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.TextureBarrier(); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.TextureBarrier")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void TextureBarrierTiled()
        {
            _obs?.TextureBarrierTiled(); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.TextureBarrierTiled(); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.TextureBarrierTiled")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin();  _r.Emit(GalOps.IPipeline_TextureBarrierTiled, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.TextureBarrierTiled(); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.TextureBarrierTiled")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public bool TryHostConditionalRendering(ICounterEvent value, ulong compare, bool isEqual)
        {
            _obs?.TryHostConditionalRendering(value, compare, isEqual); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { return _inner.TryHostConditionalRendering(value, compare, isEqual); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.TryHostConditionalRendering")) { return false; } } finally { GalTiming.End(__tg, 0); } } }
            var p = _r.Begin(); W.U32(p, GalRecorder.IdOf(value)); W.U64(p, compare); W.Bool(p, isEqual);
            bool o; long __t = GalTiming.Begin(); try { try { o = _inner.TryHostConditionalRendering(GalRecorder.U(value), compare, isEqual); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.TryHostConditionalRendering")) { o = false; } } finally { GalTiming.End(__t, 0); }
            W.Bool(p, o);
            _r.Emit(GalOps.IPipeline_TryHostConditionalRendering_1, p); return o;
        }
        public bool TryHostConditionalRendering(ICounterEvent value, ICounterEvent compare, bool isEqual)
        {
            _obs?.TryHostConditionalRendering(value, compare, isEqual); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { return _inner.TryHostConditionalRendering(value, compare, isEqual); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.TryHostConditionalRendering")) { return false; } } finally { GalTiming.End(__tg, 0); } } }
            var p = _r.Begin(); W.U32(p, GalRecorder.IdOf(value)); W.U32(p, GalRecorder.IdOf(compare)); W.Bool(p, isEqual);
            bool o; long __t = GalTiming.Begin(); try { try { o = _inner.TryHostConditionalRendering(GalRecorder.U(value), GalRecorder.U(compare), isEqual); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.TryHostConditionalRendering")) { o = false; } } finally { GalTiming.End(__t, 0); }
            W.Bool(p, o);
            _r.Emit(GalOps.IPipeline_TryHostConditionalRendering_2, p); return o;
        }
        public void EndHostConditionalRendering()
        {
            _obs?.EndHostConditionalRendering(); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.EndHostConditionalRendering(); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.EndHostConditionalRendering")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin();  _r.Emit(GalOps.IPipeline_EndHostConditionalRendering, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.EndHostConditionalRendering(); } catch (Exception e) when (GalGuard.Missing(e, "IPipeline.EndHostConditionalRendering")) { } } finally { GalTiming.End(__tg, 0); } }
        }
    }

    public sealed class GuardedWindow : IWindow
    {
        readonly IWindow _inner;
        readonly GalRecorder _r;
        public GuardedWindow(IWindow inner, GalRecorder recorder) { _inner = inner; _r = recorder; }

        public void Present(ITexture texture, ImageCrop crop, Action swapBuffersCallback)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.Present(texture, crop, swapBuffersCallback); } catch (Exception e) when (GalGuard.Missing(e, "IWindow.Present")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.U32(p, GalRecorder.IdOf(texture)); W.Blit(p, crop); W.Bool(p, swapBuffersCallback != null); _r.Emit(GalOps.IWindow_Present, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.Present(GalRecorder.U(texture), crop, swapBuffersCallback); } catch (Exception e) when (GalGuard.Missing(e, "IWindow.Present")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetSize(int width, int height)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetSize(width, height); } catch (Exception e) when (GalGuard.Missing(e, "IWindow.SetSize")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, width); W.I32(p, height); _r.Emit(GalOps.IWindow_SetSize, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetSize(width, height); } catch (Exception e) when (GalGuard.Missing(e, "IWindow.SetSize")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void ChangeVSyncMode(VSyncMode vSyncMode)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.ChangeVSyncMode(vSyncMode); } catch (Exception e) when (GalGuard.Missing(e, "IWindow.ChangeVSyncMode")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, (int)vSyncMode); _r.Emit(GalOps.IWindow_ChangeVSyncMode, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.ChangeVSyncMode(vSyncMode); } catch (Exception e) when (GalGuard.Missing(e, "IWindow.ChangeVSyncMode")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetAntiAliasing(AntiAliasing antialiasing)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetAntiAliasing(antialiasing); } catch (Exception e) when (GalGuard.Missing(e, "IWindow.SetAntiAliasing")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, (int)antialiasing); _r.Emit(GalOps.IWindow_SetAntiAliasing, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetAntiAliasing(antialiasing); } catch (Exception e) when (GalGuard.Missing(e, "IWindow.SetAntiAliasing")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetScalingFilter(ScalingFilter type)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetScalingFilter(type); } catch (Exception e) when (GalGuard.Missing(e, "IWindow.SetScalingFilter")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, (int)type); _r.Emit(GalOps.IWindow_SetScalingFilter, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetScalingFilter(type); } catch (Exception e) when (GalGuard.Missing(e, "IWindow.SetScalingFilter")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetScalingFilterLevel(float level)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetScalingFilterLevel(level); } catch (Exception e) when (GalGuard.Missing(e, "IWindow.SetScalingFilterLevel")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.F32(p, level); _r.Emit(GalOps.IWindow_SetScalingFilterLevel, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetScalingFilterLevel(level); } catch (Exception e) when (GalGuard.Missing(e, "IWindow.SetScalingFilterLevel")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetColorSpacePassthrough(bool colorSpacePassThroughEnabled)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetColorSpacePassthrough(colorSpacePassThroughEnabled); } catch (Exception e) when (GalGuard.Missing(e, "IWindow.SetColorSpacePassthrough")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Bool(p, colorSpacePassThroughEnabled); _r.Emit(GalOps.IWindow_SetColorSpacePassthrough, p, 0);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetColorSpacePassthrough(colorSpacePassThroughEnabled); } catch (Exception e) when (GalGuard.Missing(e, "IWindow.SetColorSpacePassthrough")) { } } finally { GalTiming.End(__tg, 0); } }
        }
    }

    public sealed partial class RecordingRenderer : IRenderer
    {
        readonly IRenderer _inner;
        readonly RecordingPipeline _pipeline;
        readonly GuardedWindow _window;
        readonly GalRecorder _r;
        public IRenderer Inner => _inner;
        public GalRecorder Recorder => _r;
        /// <param name="observer">管线观察者（可空）：每个管线调用先给它（StubPipeline 记状态 / 出 draws.jsonl）</param>
        /// <param name="recorder">录像（可空）：非空时对象 / 缓冲换稳定编号并逐条记录</param>
        public RecordingRenderer(IRenderer inner, IPipeline observer, GalRecorder recorder)
        {
            _inner = inner; _r = recorder;
            if (_r != null) _r.Inner = inner;
            _pipeline = new RecordingPipeline(observer, inner.Pipeline, recorder);
            _window = new GuardedWindow(inner.Window, recorder);
        }

        public event EventHandler<ScreenCaptureImageInfo> ScreenCaptured { add => _inner.ScreenCaptured += value; remove => _inner.ScreenCaptured -= value; }
        public bool PreferThreading => false;
        public IPipeline Pipeline => _pipeline;
        public IWindow Window => _window;
        public uint ProgramCount => _inner.ProgramCount;
        public void Dispose() => _inner.Dispose();

        public void BackgroundContextAction(Action action, bool alwaysBackground = false)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.BackgroundContextAction(action, alwaysBackground); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.BackgroundContextAction")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Bool(p, action != null); W.Bool(p, alwaysBackground); _r.Emit(GalOps.IRenderer_BackgroundContextAction, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.BackgroundContextAction(action, alwaysBackground); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.BackgroundContextAction")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public BufferHandle CreateBuffer(int size, BufferAccess access = BufferAccess.Default)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { return _inner.CreateBuffer(size, access); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.CreateBuffer")) { return BufferHandle.Null; } } finally { GalTiming.End(__tg, 0); } } }
            var p = _r.Begin(); W.I32(p, size); W.I32(p, (int)access);
            BufferHandle h; long __t = GalTiming.Begin(); try { try { h = _inner.CreateBuffer(size, access); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.CreateBuffer")) { h = BufferHandle.Null; } } finally { GalTiming.End(__t, 0); }
            BufferHandle id = _r.NewBuffer(h, size, GalOps.IRenderer_CreateBuffer_1, p); _r.Emit(GalOps.IRenderer_CreateBuffer_1, p); return id;
        }
        public BufferHandle CreateBuffer(nint pointer, int size)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { return _inner.CreateBuffer(pointer, size); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.CreateBuffer")) { return BufferHandle.Null; } } finally { GalTiming.End(__tg, 0); } } }
            var p = _r.Begin(); W.I64(p, (long)pointer); W.I32(p, size);
            BufferHandle h; long __t = GalTiming.Begin(); try { try { h = _inner.CreateBuffer(pointer, size); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.CreateBuffer")) { h = BufferHandle.Null; } } finally { GalTiming.End(__t, 0); }
            BufferHandle id = _r.NewBuffer(h, size, GalOps.IRenderer_CreateBuffer_2, p); _r.Emit(GalOps.IRenderer_CreateBuffer_2, p); return id;
        }
        public BufferHandle CreateBufferSparse(ReadOnlySpan<BufferRange> storageBuffers)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { return _inner.CreateBufferSparse(storageBuffers); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.CreateBufferSparse")) { return BufferHandle.Null; } } finally { GalTiming.End(__tg, 0); } } }
            var p = _r.Begin(); W.Span(p, storageBuffers);
            BufferHandle h; long __t = GalTiming.Begin(); try { try { h = _inner.CreateBufferSparse(_r.In(storageBuffers)); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.CreateBufferSparse")) { h = BufferHandle.Null; } } finally { GalTiming.End(__t, 0); }
            BufferHandle id = _r.NewBuffer(h, GalRecorder.SumSize(storageBuffers), GalOps.IRenderer_CreateBufferSparse, p); _r.Emit(GalOps.IRenderer_CreateBufferSparse, p); return id;
        }
        public IImageArray CreateImageArray(int size, bool isBuffer)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { return _inner.CreateImageArray(size, isBuffer); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.CreateImageArray")) { return new StubArray(); } } finally { GalTiming.End(__tg, 0); } } }
            var p = _r.Begin(); W.I32(p, size); W.Bool(p, isBuffer); uint id = _r.NewId(); W.U32(p, id);
            IImageArray o; long __t = GalTiming.Begin(); try { try { o = _inner.CreateImageArray(size, isBuffer); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.CreateImageArray")) { o = new StubArray(); } } finally { GalTiming.End(__t, 0); }
            var w = new RecArray(_r, o as ITextureArray, o, id); _r.Register(w, GalOps.IRenderer_CreateImageArray, p); _r.Emit(GalOps.IRenderer_CreateImageArray, p); return w;
        }
        public IProgram CreateProgram(ShaderSource[] shaders, ShaderInfo info)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { return _inner.CreateProgram(shaders, info); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.CreateProgram")) { return new StubProgram(Array.Empty<ShaderSource>()); } } finally { GalTiming.End(__tg, 2); } } }
            var p = _r.Begin(); W.Shaders(p, shaders); W.ShaderInfo(p, info); uint id = _r.NewId(); W.U32(p, id);
            IProgram o; long __t = GalTiming.Begin(); try { try { o = _inner.CreateProgram(shaders, info); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.CreateProgram")) { o = new StubProgram(Array.Empty<ShaderSource>()); } } finally { GalTiming.End(__t, 2); }
            var w = new RecProgram(_r, o, id); _r.Register(w, GalOps.IRenderer_CreateProgram, p); _r.Emit(GalOps.IRenderer_CreateProgram, p); return w;
        }
        public ISampler CreateSampler(SamplerCreateInfo info)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { return _inner.CreateSampler(info); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.CreateSampler")) { return new StubSampler(info); } } finally { GalTiming.End(__tg, 0); } } }
            var p = _r.Begin(); W.Blit(p, info); uint id = _r.NewId(); W.U32(p, id);
            ISampler o; long __t = GalTiming.Begin(); try { try { o = _inner.CreateSampler(info); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.CreateSampler")) { o = new StubSampler(info); } } finally { GalTiming.End(__t, 0); }
            var w = new RecSampler(_r, o, id); _r.Register(w, GalOps.IRenderer_CreateSampler, p); _r.Emit(GalOps.IRenderer_CreateSampler, p); return w;
        }
        public ITexture CreateTexture(TextureCreateInfo info)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { return _inner.CreateTexture(info); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.CreateTexture")) { return default; } } finally { GalTiming.End(__tg, 0); } } }
            var p = _r.Begin(); W.Blit(p, info); uint id = _r.NewId(); W.U32(p, id);
            ITexture o; long __t = GalTiming.Begin(); try { try { o = _inner.CreateTexture(info); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.CreateTexture")) { o = default; } } finally { GalTiming.End(__t, 0); }
            var w = new RecTexture(_r, o, id); _r.Register(w, GalOps.IRenderer_CreateTexture, p); _r.Emit(GalOps.IRenderer_CreateTexture, p); return w;
        }
        public ITextureArray CreateTextureArray(int size, bool isBuffer)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { return _inner.CreateTextureArray(size, isBuffer); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.CreateTextureArray")) { return new StubArray(); } } finally { GalTiming.End(__tg, 0); } } }
            var p = _r.Begin(); W.I32(p, size); W.Bool(p, isBuffer); uint id = _r.NewId(); W.U32(p, id);
            ITextureArray o; long __t = GalTiming.Begin(); try { try { o = _inner.CreateTextureArray(size, isBuffer); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.CreateTextureArray")) { o = new StubArray(); } } finally { GalTiming.End(__t, 0); }
            var w = new RecArray(_r, o, o as IImageArray, id); _r.Register(w, GalOps.IRenderer_CreateTextureArray, p); _r.Emit(GalOps.IRenderer_CreateTextureArray, p); return w;
        }
        public bool PrepareHostMapping(nint address, ulong size)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { return _inner.PrepareHostMapping(address, size); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.PrepareHostMapping")) { return false; } } finally { GalTiming.End(__tg, 0); } } }
            var p = _r.Begin(); W.I64(p, (long)address); W.U64(p, size);
            bool o; long __t = GalTiming.Begin(); try { try { o = _inner.PrepareHostMapping(address, size); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.PrepareHostMapping")) { o = false; } } finally { GalTiming.End(__t, 0); }
            W.Bool(p, o);
            _r.Emit(GalOps.IRenderer_PrepareHostMapping, p); return o;
        }
        public void CreateSync(ulong id, bool strict)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.CreateSync(id, strict); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.CreateSync")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.U64(p, id); W.Bool(p, strict); _r.Emit(GalOps.IRenderer_CreateSync, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.CreateSync(id, strict); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.CreateSync")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void DeleteBuffer(BufferHandle buffer)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.DeleteBuffer(buffer); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.DeleteBuffer")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Blit(p, buffer); _r.Emit(GalOps.IRenderer_DeleteBuffer, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.DeleteBuffer(_r.In(buffer)); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.DeleteBuffer")) { } } finally { GalTiming.End(__tg, 0); } } _r.DeleteBuffer(buffer);
        }
        public PinnedSpan<byte> GetBufferData(BufferHandle buffer, int offset, int size)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { return _inner.GetBufferData(buffer, offset, size); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.GetBufferData")) { return PinnedSpan<byte>.UnsafeFromSpan(new byte[Math.Max(size, 0)]); } } finally { GalTiming.End(__tg, 1); } } }
            var p = _r.Begin(); W.Blit(p, buffer); W.I32(p, offset); W.I32(p, size);
            PinnedSpan<byte> o; long __t = GalTiming.Begin(); try { try { o = _inner.GetBufferData(_r.In(buffer), offset, size); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.GetBufferData")) { o = PinnedSpan<byte>.UnsafeFromSpan(new byte[Math.Max(size, 0)]); } } finally { GalTiming.End(__t, 1); }
            W.Digest(p, o.Get());
            _r.Emit(GalOps.IRenderer_GetBufferData, p); return o;
        }
        public Capabilities GetCapabilities()
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { return _inner.GetCapabilities(); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.GetCapabilities")) { return default; } } finally { GalTiming.End(__tg, 0); } } }
            var p = _r.Begin(); 
            Capabilities o; long __t = GalTiming.Begin(); try { try { o = _inner.GetCapabilities(); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.GetCapabilities")) { o = default; } } finally { GalTiming.End(__t, 0); }
            _r.Emit(GalOps.IRenderer_GetCapabilities, p); return o;
        }
        public ulong GetCurrentSync()
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { return _inner.GetCurrentSync(); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.GetCurrentSync")) { return 0; } } finally { GalTiming.End(__tg, 0); } } }
            var p = _r.Begin(); 
            ulong o; long __t = GalTiming.Begin(); try { try { o = _inner.GetCurrentSync(); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.GetCurrentSync")) { o = 0; } } finally { GalTiming.End(__t, 0); }
            W.U64(p, o);
            _r.Emit(GalOps.IRenderer_GetCurrentSync, p); return o;
        }
        public HardwareInfo GetHardwareInfo()
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { return _inner.GetHardwareInfo(); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.GetHardwareInfo")) { return new HardwareInfo("?", "?", "?", "?"); } } finally { GalTiming.End(__tg, 0); } } }
            var p = _r.Begin(); 
            HardwareInfo o; long __t = GalTiming.Begin(); try { try { o = _inner.GetHardwareInfo(); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.GetHardwareInfo")) { o = new HardwareInfo("?", "?", "?", "?"); } } finally { GalTiming.End(__t, 0); }
            _r.Emit(GalOps.IRenderer_GetHardwareInfo, p); return o;
        }
        public IProgram LoadProgramBinary(byte[] programBinary, bool hasFragmentShader, ShaderInfo info)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { return _inner.LoadProgramBinary(programBinary, hasFragmentShader, info); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.LoadProgramBinary")) { return new StubProgram(Array.Empty<ShaderSource>()); } } finally { GalTiming.End(__tg, 2); } } }
            var p = _r.Begin(); W.Bytes(p, programBinary); W.Bool(p, hasFragmentShader); W.ShaderInfo(p, info); uint id = _r.NewId(); W.U32(p, id);
            IProgram o; long __t = GalTiming.Begin(); try { try { o = _inner.LoadProgramBinary(programBinary, hasFragmentShader, info); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.LoadProgramBinary")) { o = new StubProgram(Array.Empty<ShaderSource>()); } } finally { GalTiming.End(__t, 2); }
            var w = new RecProgram(_r, o, id); _r.Register(w, GalOps.IRenderer_LoadProgramBinary, p); _r.Emit(GalOps.IRenderer_LoadProgramBinary, p); return w;
        }
        public void SetBufferData(BufferHandle buffer, int offset, ReadOnlySpan<byte> data)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetBufferData(buffer, offset, data); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.SetBufferData")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Blit(p, buffer); W.I32(p, offset); W.Span(p, data); _r.Emit(GalOps.IRenderer_SetBufferData, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetBufferData(_r.In(buffer), offset, data); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.SetBufferData")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void UpdateCounters()
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.UpdateCounters(); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.UpdateCounters")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin();  _r.Emit(GalOps.IRenderer_UpdateCounters, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.UpdateCounters(); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.UpdateCounters")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void PreFrame()
        {
            _r?.PreFrameMark(); if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.PreFrame(); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.PreFrame")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin();  _r.Emit(GalOps.IRenderer_PreFrame, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.PreFrame(); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.PreFrame")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public ICounterEvent ReportCounter(CounterType type, EventHandler<ulong> resultHandler, float divisor, bool hostReserved)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { return _inner.ReportCounter(type, resultHandler, divisor, hostReserved); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.ReportCounter")) { return new StubCounterEvent(); } } finally { GalTiming.End(__tg, 0); } } }
            uint id = _r.NewId();
            EventHandler<ulong> h = resultHandler == null ? null : (s, v) => { _r.CounterResult(id, v); resultHandler(s, v); };
            var p = _r.Begin(); W.I32(p, (int)type); W.Bool(p, resultHandler != null); W.F32(p, divisor); W.Bool(p, hostReserved); W.U32(p, id); _r.Emit(GalOps.IRenderer_ReportCounter, p);
            ICounterEvent o; long __t = GalTiming.Begin(); try { try { o = _inner.ReportCounter(type, h, divisor, hostReserved); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.ReportCounter")) { o = new StubCounterEvent(); } } finally { GalTiming.End(__t, 0); }
            return new RecCounter(_r, o, id);
        }
        public void ResetCounter(CounterType type)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.ResetCounter(type); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.ResetCounter")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, (int)type); _r.Emit(GalOps.IRenderer_ResetCounter, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.ResetCounter(type); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.ResetCounter")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void WaitSync(ulong id)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.WaitSync(id); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.WaitSync")) { } } finally { GalTiming.End(__tg, 1); } } return; }
            var p = _r.Begin(); W.U64(p, id); _r.Emit(GalOps.IRenderer_WaitSync, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.WaitSync(id); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.WaitSync")) { } } finally { GalTiming.End(__tg, 1); } }
        }
        public void Initialize(GraphicsDebugLevel logLevel)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.Initialize(logLevel); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.Initialize")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.I32(p, (int)logLevel); _r.Emit(GalOps.IRenderer_Initialize, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.Initialize(logLevel); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.Initialize")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void SetInterruptAction(Action<Action> interruptAction)
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.SetInterruptAction(interruptAction); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.SetInterruptAction")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin(); W.Bool(p, interruptAction != null); _r.Emit(GalOps.IRenderer_SetInterruptAction, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.SetInterruptAction(interruptAction); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.SetInterruptAction")) { } } finally { GalTiming.End(__tg, 0); } }
        }
        public void Screenshot()
        {
            if (_r == null) { { long __tg = GalTiming.Begin(); try { try { _inner.Screenshot(); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.Screenshot")) { } } finally { GalTiming.End(__tg, 0); } } return; }
            var p = _r.Begin();  _r.Emit(GalOps.IRenderer_Screenshot, p);
            { long __tg = GalTiming.Begin(); try { try { _inner.Screenshot(); } catch (Exception e) when (GalGuard.Missing(e, "IRenderer.Screenshot")) { } } finally { GalTiming.End(__tg, 0); } }
        }
    }

    public sealed partial class GalRecReplayer
    {
        /// <summary>回放一条接口方法记录；返回假表示不是接口方法操作码（交给对象方法 / 特殊记录处理）。</summary>
        bool ReplayInterface(uint op, ref R rr)
        {
            GalRecReplayer x = this;
            uint pendingId = 0;
            switch (op)
            {
                case GalOps.IPipeline_Barrier:
                {
                    Target.Pipeline.Barrier();
                    return true;
                }
                case GalOps.IPipeline_BeginTransformFeedback:
                {
                    var a0 = (PrimitiveTopology)rr.I32();
                    Target.Pipeline.BeginTransformFeedback(a0);
                    return true;
                }
                case GalOps.IPipeline_ClearBuffer:
                {
                    var a0 = x.Buf(rr.Blit<BufferHandle>()); var a1 = rr.I32(); var a2 = rr.I32(); var a3 = rr.U32();
                    Target.Pipeline.ClearBuffer(a0, a1, a2, a3);
                    return true;
                }
                case GalOps.IPipeline_ClearRenderTargetColor:
                {
                    var a0 = rr.I32(); var a1 = rr.I32(); var a2 = rr.I32(); var a3 = rr.U32(); var a4 = rr.Blit<ColorF>();
                    Target.Pipeline.ClearRenderTargetColor(a0, a1, a2, a3, a4);
                    return true;
                }
                case GalOps.IPipeline_ClearRenderTargetDepthStencil:
                {
                    var a0 = rr.I32(); var a1 = rr.I32(); var a2 = rr.F32(); var a3 = rr.Bool(); var a4 = rr.I32(); var a5 = rr.I32();
                    Target.Pipeline.ClearRenderTargetDepthStencil(a0, a1, a2, a3, a4, a5);
                    return true;
                }
                case GalOps.IPipeline_CommandBufferBarrier:
                {
                    Target.Pipeline.CommandBufferBarrier();
                    return true;
                }
                case GalOps.IPipeline_CopyBuffer:
                {
                    var a0 = x.Buf(rr.Blit<BufferHandle>()); var a1 = x.Buf(rr.Blit<BufferHandle>()); var a2 = rr.I32(); var a3 = rr.I32(); var a4 = rr.I32();
                    Target.Pipeline.CopyBuffer(a0, a1, a2, a3, a4);
                    return true;
                }
                case GalOps.IPipeline_DispatchCompute:
                {
                    var a0 = rr.I32(); var a1 = rr.I32(); var a2 = rr.I32();
                    Target.Pipeline.DispatchCompute(a0, a1, a2);
                    return true;
                }
                case GalOps.IPipeline_Draw:
                {
                    var a0 = rr.I32(); var a1 = rr.I32(); var a2 = rr.I32(); var a3 = rr.I32();
                    Target.Pipeline.Draw(a0, a1, a2, a3);
                    return true;
                }
                case GalOps.IPipeline_DrawIndexed:
                {
                    var a0 = rr.I32(); var a1 = rr.I32(); var a2 = rr.I32(); var a3 = rr.I32(); var a4 = rr.I32();
                    Target.Pipeline.DrawIndexed(a0, a1, a2, a3, a4);
                    return true;
                }
                case GalOps.IPipeline_DrawIndexedIndirect:
                {
                    var a0 = x.Map(rr.Blit<BufferRange>());
                    Target.Pipeline.DrawIndexedIndirect(a0);
                    return true;
                }
                case GalOps.IPipeline_DrawIndexedIndirectCount:
                {
                    var a0 = x.Map(rr.Blit<BufferRange>()); var a1 = x.Map(rr.Blit<BufferRange>()); var a2 = rr.I32(); var a3 = rr.I32();
                    Target.Pipeline.DrawIndexedIndirectCount(a0, a1, a2, a3);
                    return true;
                }
                case GalOps.IPipeline_DrawIndirect:
                {
                    var a0 = x.Map(rr.Blit<BufferRange>());
                    Target.Pipeline.DrawIndirect(a0);
                    return true;
                }
                case GalOps.IPipeline_DrawIndirectCount:
                {
                    var a0 = x.Map(rr.Blit<BufferRange>()); var a1 = x.Map(rr.Blit<BufferRange>()); var a2 = rr.I32(); var a3 = rr.I32();
                    Target.Pipeline.DrawIndirectCount(a0, a1, a2, a3);
                    return true;
                }
                case GalOps.IPipeline_DrawTexture:
                {
                    var a0 = x.Obj<ITexture>(rr.U32()); var a1 = x.Obj<ISampler>(rr.U32()); var a2 = rr.Blit<Extents2DF>(); var a3 = rr.Blit<Extents2DF>();
                    Target.Pipeline.DrawTexture(a0, a1, a2, a3);
                    return true;
                }
                case GalOps.IPipeline_EndTransformFeedback:
                {
                    Target.Pipeline.EndTransformFeedback();
                    return true;
                }
                case GalOps.IPipeline_SetAlphaTest:
                {
                    var a0 = rr.Bool(); var a1 = rr.F32(); var a2 = (CompareOp)rr.I32();
                    Target.Pipeline.SetAlphaTest(a0, a1, a2);
                    return true;
                }
                case GalOps.IPipeline_SetBlendState_1:
                {
                    var a0 = rr.Blit<AdvancedBlendDescriptor>();
                    Target.Pipeline.SetBlendState(a0);
                    return true;
                }
                case GalOps.IPipeline_SetBlendState_2:
                {
                    var a0 = rr.I32(); var a1 = rr.Blit<BlendDescriptor>();
                    Target.Pipeline.SetBlendState(a0, a1);
                    return true;
                }
                case GalOps.IPipeline_SetDepthBias:
                {
                    var a0 = (PolygonModeMask)rr.I32(); var a1 = rr.F32(); var a2 = rr.F32(); var a3 = rr.F32();
                    Target.Pipeline.SetDepthBias(a0, a1, a2, a3);
                    return true;
                }
                case GalOps.IPipeline_SetDepthClamp:
                {
                    var a0 = rr.Bool();
                    Target.Pipeline.SetDepthClamp(a0);
                    return true;
                }
                case GalOps.IPipeline_SetDepthMode:
                {
                    var a0 = (DepthMode)rr.I32();
                    Target.Pipeline.SetDepthMode(a0);
                    return true;
                }
                case GalOps.IPipeline_SetDepthTest:
                {
                    var a0 = rr.Blit<DepthTestDescriptor>();
                    Target.Pipeline.SetDepthTest(a0);
                    return true;
                }
                case GalOps.IPipeline_SetFaceCulling:
                {
                    var a0 = rr.Bool(); var a1 = (Face)rr.I32();
                    Target.Pipeline.SetFaceCulling(a0, a1);
                    return true;
                }
                case GalOps.IPipeline_SetFrontFace:
                {
                    var a0 = (FrontFace)rr.I32();
                    Target.Pipeline.SetFrontFace(a0);
                    return true;
                }
                case GalOps.IPipeline_SetIndexBuffer:
                {
                    var a0 = x.Map(rr.Blit<BufferRange>()); var a1 = (IndexType)rr.I32();
                    Target.Pipeline.SetIndexBuffer(a0, a1);
                    return true;
                }
                case GalOps.IPipeline_SetImage:
                {
                    var a0 = (ShaderStage)rr.I32(); var a1 = rr.I32(); var a2 = x.Obj<ITexture>(rr.U32());
                    Target.Pipeline.SetImage(a0, a1, a2);
                    return true;
                }
                case GalOps.IPipeline_SetImageArray:
                {
                    var a0 = (ShaderStage)rr.I32(); var a1 = rr.I32(); var a2 = x.Obj<IImageArray>(rr.U32());
                    Target.Pipeline.SetImageArray(a0, a1, a2);
                    return true;
                }
                case GalOps.IPipeline_SetImageArraySeparate:
                {
                    var a0 = (ShaderStage)rr.I32(); var a1 = rr.I32(); var a2 = x.Obj<IImageArray>(rr.U32());
                    Target.Pipeline.SetImageArraySeparate(a0, a1, a2);
                    return true;
                }
                case GalOps.IPipeline_SetLineParameters:
                {
                    var a0 = rr.F32(); var a1 = rr.Bool();
                    Target.Pipeline.SetLineParameters(a0, a1);
                    return true;
                }
                case GalOps.IPipeline_SetLogicOpState:
                {
                    var a0 = rr.Bool(); var a1 = (LogicalOp)rr.I32();
                    Target.Pipeline.SetLogicOpState(a0, a1);
                    return true;
                }
                case GalOps.IPipeline_SetMultisampleState:
                {
                    var a0 = rr.Blit<MultisampleDescriptor>();
                    Target.Pipeline.SetMultisampleState(a0);
                    return true;
                }
                case GalOps.IPipeline_SetPatchParameters:
                {
                    var a0 = rr.I32(); var a1 = rr.Span<float>(); var a2 = rr.Span<float>();
                    Target.Pipeline.SetPatchParameters(a0, a1, a2);
                    return true;
                }
                case GalOps.IPipeline_SetPointParameters:
                {
                    var a0 = rr.F32(); var a1 = rr.Bool(); var a2 = rr.Bool(); var a3 = (Origin)rr.I32();
                    Target.Pipeline.SetPointParameters(a0, a1, a2, a3);
                    return true;
                }
                case GalOps.IPipeline_SetPolygonMode:
                {
                    var a0 = (PolygonMode)rr.I32(); var a1 = (PolygonMode)rr.I32();
                    Target.Pipeline.SetPolygonMode(a0, a1);
                    return true;
                }
                case GalOps.IPipeline_SetPrimitiveRestart:
                {
                    var a0 = rr.Bool(); var a1 = rr.I32();
                    Target.Pipeline.SetPrimitiveRestart(a0, a1);
                    return true;
                }
                case GalOps.IPipeline_SetPrimitiveTopology:
                {
                    var a0 = (PrimitiveTopology)rr.I32();
                    Target.Pipeline.SetPrimitiveTopology(a0);
                    return true;
                }
                case GalOps.IPipeline_SetProgram:
                {
                    var a0 = x.Obj<IProgram>(rr.U32());
                    Target.Pipeline.SetProgram(a0);
                    return true;
                }
                case GalOps.IPipeline_SetRasterizerDiscard:
                {
                    var a0 = rr.Bool();
                    Target.Pipeline.SetRasterizerDiscard(a0);
                    return true;
                }
                case GalOps.IPipeline_SetRenderTargetColorMasks:
                {
                    var a0 = rr.Span<uint>();
                    Target.Pipeline.SetRenderTargetColorMasks(a0);
                    return true;
                }
                case GalOps.IPipeline_SetRenderTargets:
                {
                    var a0 = x.Objs<ITexture>(ref rr).AsSpan(); var a1 = x.Obj<ITexture>(rr.U32());
                    Target.Pipeline.SetRenderTargets(a0, a1);
                    return true;
                }
                case GalOps.IPipeline_SetScissors:
                {
                    var a0 = rr.Span<Rectangle<int>>();
                    Target.Pipeline.SetScissors(a0);
                    return true;
                }
                case GalOps.IPipeline_SetStencilTest:
                {
                    var a0 = rr.Blit<StencilTestDescriptor>();
                    Target.Pipeline.SetStencilTest(a0);
                    return true;
                }
                case GalOps.IPipeline_SetStorageBuffers:
                {
                    var a0 = x.Map(rr.Span<BufferAssignment>());
                    Target.Pipeline.SetStorageBuffers(a0);
                    return true;
                }
                case GalOps.IPipeline_SetTextureAndSampler:
                {
                    var a0 = (ShaderStage)rr.I32(); var a1 = rr.I32(); var a2 = x.Obj<ITexture>(rr.U32()); var a3 = x.Obj<ISampler>(rr.U32());
                    Target.Pipeline.SetTextureAndSampler(a0, a1, a2, a3);
                    return true;
                }
                case GalOps.IPipeline_SetTextureArray:
                {
                    var a0 = (ShaderStage)rr.I32(); var a1 = rr.I32(); var a2 = x.Obj<ITextureArray>(rr.U32());
                    Target.Pipeline.SetTextureArray(a0, a1, a2);
                    return true;
                }
                case GalOps.IPipeline_SetTextureArraySeparate:
                {
                    var a0 = (ShaderStage)rr.I32(); var a1 = rr.I32(); var a2 = x.Obj<ITextureArray>(rr.U32());
                    Target.Pipeline.SetTextureArraySeparate(a0, a1, a2);
                    return true;
                }
                case GalOps.IPipeline_SetTransformFeedbackBuffers:
                {
                    var a0 = x.Map(rr.Span<BufferRange>());
                    Target.Pipeline.SetTransformFeedbackBuffers(a0);
                    return true;
                }
                case GalOps.IPipeline_SetUniformBuffers:
                {
                    var a0 = x.Map(rr.Span<BufferAssignment>());
                    Target.Pipeline.SetUniformBuffers(a0);
                    return true;
                }
                case GalOps.IPipeline_SetUserClipDistance:
                {
                    var a0 = rr.I32(); var a1 = rr.Bool();
                    Target.Pipeline.SetUserClipDistance(a0, a1);
                    return true;
                }
                case GalOps.IPipeline_SetVertexAttribs:
                {
                    var a0 = rr.Span<VertexAttribDescriptor>();
                    Target.Pipeline.SetVertexAttribs(a0);
                    return true;
                }
                case GalOps.IPipeline_SetVertexBuffers:
                {
                    var a0 = x.Map(rr.Span<VertexBufferDescriptor>());
                    Target.Pipeline.SetVertexBuffers(a0);
                    return true;
                }
                case GalOps.IPipeline_SetViewports:
                {
                    var a0 = rr.Span<Viewport>();
                    Target.Pipeline.SetViewports(a0);
                    return true;
                }
                case GalOps.IPipeline_TextureBarrier:
                {
                    Target.Pipeline.TextureBarrier();
                    return true;
                }
                case GalOps.IPipeline_TextureBarrierTiled:
                {
                    Target.Pipeline.TextureBarrierTiled();
                    return true;
                }
                case GalOps.IPipeline_TryHostConditionalRendering_1:
                {
                    var a0 = x.Obj<ICounterEvent>(rr.U32()); var a1 = rr.U64(); var a2 = rr.Bool();
                    var o = Target.Pipeline.TryHostConditionalRendering(a0, a1, a2); x.CheckValue(GalOps.IPipeline_TryHostConditionalRendering_1, rr.Bool().Equals(o));
                    return true;
                }
                case GalOps.IPipeline_TryHostConditionalRendering_2:
                {
                    var a0 = x.Obj<ICounterEvent>(rr.U32()); var a1 = x.Obj<ICounterEvent>(rr.U32()); var a2 = rr.Bool();
                    var o = Target.Pipeline.TryHostConditionalRendering(a0, a1, a2); x.CheckValue(GalOps.IPipeline_TryHostConditionalRendering_2, rr.Bool().Equals(o));
                    return true;
                }
                case GalOps.IPipeline_EndHostConditionalRendering:
                {
                    Target.Pipeline.EndHostConditionalRendering();
                    return true;
                }
                case GalOps.IRenderer_BackgroundContextAction:
                {
                    var a0 = (rr.Bool() ? (Action)(() => { }) : null); var a1 = rr.Bool();
                    Target.BackgroundContextAction(a0, a1);
                    return true;
                }
                case GalOps.IRenderer_CreateBuffer_1:
                {
                    var a0 = rr.I32(); var a1 = (BufferAccess)rr.I32();
                    BufferHandle h = Target.CreateBuffer(a0, a1); x.PutBuf(rr.U64(), h);
                    return true;
                }
                case GalOps.IRenderer_CreateBuffer_2:
                {
                    var a0 = (nint)rr.I64(); var a1 = rr.I32();
                    BufferHandle h = Target.CreateBuffer(a0, a1); x.PutBuf(rr.U64(), h);
                    return true;
                }
                case GalOps.IRenderer_CreateBufferSparse:
                {
                    var a0 = x.Map(rr.Span<BufferRange>());
                    BufferHandle h = Target.CreateBufferSparse(a0); x.PutBuf(rr.U64(), h);
                    return true;
                }
                case GalOps.IRenderer_CreateImageArray:
                {
                    var a0 = rr.I32(); var a1 = rr.Bool();
                    var o = Target.CreateImageArray(a0, a1); x.Put(rr.U32(), o);
                    return true;
                }
                case GalOps.IRenderer_CreateProgram:
                {
                    var a0 = rr.Shaders(); var a1 = rr.ShaderInfo();
                    // 手改（生成脚本不在仓内）：ShaderFilter 给参照端注入循环上限（galplay --ref）
                    var o = Target.CreateProgram(ShaderFilter != null ? ShaderFilter(a0) : a0, a1); x.Put(rr.U32(), o);
                    return true;
                }
                case GalOps.IRenderer_CreateSampler:
                {
                    var a0 = rr.Blit<SamplerCreateInfo>();
                    var o = Target.CreateSampler(a0); x.Put(rr.U32(), o);
                    return true;
                }
                case GalOps.IRenderer_CreateTexture:
                {
                    var a0 = rr.Blit<TextureCreateInfo>();
                    var o = Target.CreateTexture(a0); x.Put(rr.U32(), o);
                    return true;
                }
                case GalOps.IRenderer_CreateTextureArray:
                {
                    var a0 = rr.I32(); var a1 = rr.Bool();
                    var o = Target.CreateTextureArray(a0, a1); x.Put(rr.U32(), o);
                    return true;
                }
                case GalOps.IRenderer_PrepareHostMapping:
                {
                    var a0 = (nint)rr.I64(); var a1 = rr.U64();
                    var o = Target.PrepareHostMapping(a0, a1); x.CheckValue(GalOps.IRenderer_PrepareHostMapping, rr.Bool().Equals(o));
                    return true;
                }
                case GalOps.IRenderer_CreateSync:
                {
                    var a0 = rr.U64(); var a1 = rr.Bool();
                    Target.CreateSync(a0, a1);
                    return true;
                }
                case GalOps.IRenderer_DeleteBuffer:
                {
                    var rec = rr.Blit<BufferHandle>(); Target.DeleteBuffer(x.Buf(rec)); x.DropBuf(rec);
                    return true;
                }
                case GalOps.IRenderer_GetBufferData:
                {
                    var a0 = x.Buf(rr.Blit<BufferHandle>()); var a1 = rr.I32(); var a2 = rr.I32();
                    using var o = Target.GetBufferData(a0, a1, a2); x.CheckDigest(GalOps.IRenderer_GetBufferData, ref rr, o.Get());
                    return true;
                }
                case GalOps.IRenderer_GetCapabilities:
                {
                    Target.GetCapabilities();
                    return true;
                }
                case GalOps.IRenderer_GetCurrentSync:
                {
                    var o = Target.GetCurrentSync(); x.CheckValue(GalOps.IRenderer_GetCurrentSync, rr.U64().Equals(o));
                    return true;
                }
                case GalOps.IRenderer_GetHardwareInfo:
                {
                    Target.GetHardwareInfo();
                    return true;
                }
                case GalOps.IRenderer_LoadProgramBinary:
                {
                    var a0 = rr.Bytes(); var a1 = rr.Bool(); var a2 = rr.ShaderInfo();
                    var o = Target.LoadProgramBinary(a0, a1, a2); x.Put(rr.U32(), o);
                    return true;
                }
                case GalOps.IRenderer_SetBufferData:
                {
                    var a0 = x.Buf(rr.Blit<BufferHandle>()); var a1 = rr.I32(); var a2 = rr.Span<byte>();
                    Target.SetBufferData(a0, a1, a2);
                    return true;
                }
                case GalOps.IRenderer_UpdateCounters:
                {
                    Target.UpdateCounters();
                    return true;
                }
                case GalOps.IRenderer_PreFrame:
                {
                    Target.PreFrame();
                    return true;
                }
                case GalOps.IRenderer_ReportCounter:
                {
                    var a0 = (CounterType)rr.I32(); bool f1 = rr.Bool(); var a2 = rr.F32(); var a3 = rr.Bool();
                    pendingId = rr.U32();
                    EventHandler<ulong> a1 = f1 ? x.CounterHandler(pendingId) : null;
                    x.Put(pendingId, Target.ReportCounter(a0, a1, a2, a3));
                    return true;
                }
                case GalOps.IRenderer_ResetCounter:
                {
                    var a0 = (CounterType)rr.I32();
                    Target.ResetCounter(a0);
                    return true;
                }
                case GalOps.IRenderer_WaitSync:
                {
                    var a0 = rr.U64();
                    Target.WaitSync(a0);
                    return true;
                }
                case GalOps.IRenderer_Initialize:
                {
                    var a0 = (GraphicsDebugLevel)rr.I32();
                    Target.Initialize(a0);
                    return true;
                }
                case GalOps.IRenderer_SetInterruptAction:
                {
                    var a0 = (rr.Bool() ? (Action<Action>)(a => { }) : null);
                    Target.SetInterruptAction(a0);
                    return true;
                }
                case GalOps.IRenderer_Screenshot:
                {
                    Target.Screenshot();
                    return true;
                }
                case GalOps.IWindow_Present:
                {
                    var a0 = x.Obj<ITexture>(rr.U32()); var a1 = rr.Blit<ImageCrop>(); var a2 = (rr.Bool() ? (Action)(() => { }) : null);
                    Target.Window.Present(a0, a1, a2);
                    return true;
                }
                case GalOps.IWindow_SetSize:
                {
                    var a0 = rr.I32(); var a1 = rr.I32();
                    Target.Window.SetSize(a0, a1);
                    return true;
                }
                case GalOps.IWindow_ChangeVSyncMode:
                {
                    var a0 = (VSyncMode)rr.I32();
                    Target.Window.ChangeVSyncMode(a0);
                    return true;
                }
                case GalOps.IWindow_SetAntiAliasing:
                {
                    var a0 = (AntiAliasing)rr.I32();
                    Target.Window.SetAntiAliasing(a0);
                    return true;
                }
                case GalOps.IWindow_SetScalingFilter:
                {
                    var a0 = (ScalingFilter)rr.I32();
                    Target.Window.SetScalingFilter(a0);
                    return true;
                }
                case GalOps.IWindow_SetScalingFilterLevel:
                {
                    var a0 = rr.F32();
                    Target.Window.SetScalingFilterLevel(a0);
                    return true;
                }
                case GalOps.IWindow_SetColorSpacePassthrough:
                {
                    var a0 = rr.Bool();
                    Target.Window.SetColorSpacePassthrough(a0);
                    return true;
                }
                default:
                    return false;
            }
        }
    }
}
