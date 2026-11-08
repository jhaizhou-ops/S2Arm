// 桩渲染器（不画图的 IRenderer）：显卡线没登记渲染器工厂时让服务链路照常起（显卡相关报红），单测也用它。取自旧库 497552d ryu_judge StubRenderer.cs，去掉旧库计数器引用。
// 桩渲染器：不画任何东西，但接住 Ryujinx Gpu 层发下来的所有 Create* / Set* / Draw* 调用。
// - 管线状态（视口、剪裁、混合、深度模板、光栅化、顶点格式 …）按 GAL 描述符原样保留最后一次设置的值，供出行时读。
// - 缓冲有真实的稀疏内容（SetBufferData / CopyBuffer / GetBufferData 一致），避免 Ryujinx 回写时读到乱码。
// - 纹理 GetData 返回尺寸正确的全零数据（我们不渲染，回写内容本来就不是真值）。
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Threading;

namespace S2A.Services
{
    public sealed class SparseBytes
    {
        const int Bits = 12;
        const int Size = 1 << Bits;
        readonly Dictionary<int, byte[]> _pages = new();
        public int Length;

        public SparseBytes(int length) => Length = length;

        public void Write(int offset, ReadOnlySpan<byte> data)
        {
            int done = 0;
            while (done < data.Length)
            {
                int a = offset + done;
                int off = a & (Size - 1);
                int n = Math.Min(Size - off, data.Length - done);
                if (!_pages.TryGetValue(a >> Bits, out byte[] p))
                {
                    _pages[a >> Bits] = p = new byte[Size];
                }

                data.Slice(done, n).CopyTo(p.AsSpan(off, n));
                done += n;
            }
        }

        public void Read(int offset, Span<byte> data)
        {
            int done = 0;
            while (done < data.Length)
            {
                int a = offset + done;
                int off = a & (Size - 1);
                int n = Math.Min(Size - off, data.Length - done);
                if (_pages.TryGetValue(a >> Bits, out byte[] p))
                {
                    p.AsSpan(off, n).CopyTo(data.Slice(done, n));
                }
                else
                {
                    data.Slice(done, n).Clear();
                }

                done += n;
            }
        }

        public void Fill(int offset, int size, uint value)
        {
            byte[] tmp = new byte[size];
            for (int i = 0; i + 4 <= size; i += 4)
            {
                BitConverter.TryWriteBytes(tmp.AsSpan(i, 4), value);
            }

            Write(offset, tmp);
        }
    }

    sealed class StubTexture : ITexture
    {
        public TextureCreateInfo Info { get; }
        public StubTexture(TextureCreateInfo info) => Info = info;
        public int Width => Info.Width;
        public int Height => Info.Height;

        public void CopyTo(ITexture destination, int firstLayer, int firstLevel) { }
        public void CopyTo(ITexture destination, int srcLayer, int dstLayer, int srcLevel, int dstLevel) { }
        public void CopyTo(ITexture destination, Extents2D srcRegion, Extents2D dstRegion, bool linearFilter) { }
        public void CopyTo(BufferRange range, int layer, int level, int stride) { }
        public ITexture CreateView(TextureCreateInfo info, int firstLayer, int firstLevel) => new StubTexture(info);

        public PinnedSpan<byte> GetData()
        {
            long size = 0;
            for (int level = 0; level < Info.Levels; level++)
            {
                size += Info.GetMipSize(level);
            }

            return PinnedSpan<byte>.UnsafeFromSpan(new byte[size]);
        }

        public PinnedSpan<byte> GetData(int layer, int level) => PinnedSpan<byte>.UnsafeFromSpan(new byte[Info.GetMipSize2D(level)]);

        public void SetData(MemoryOwner<byte> data) => data.Dispose();
        public void SetData(MemoryOwner<byte> data, int layer, int level) => data.Dispose();
        public void SetData(MemoryOwner<byte> data, int layer, int level, Rectangle<int> region) => data.Dispose();
        public void SetStorage(BufferRange buffer) { }
        public void Release() { }
    }

    sealed class StubWindow : IWindow
    {
        public void Present(ITexture texture, ImageCrop crop, Action swapBuffersCallback) => swapBuffersCallback?.Invoke();
        public void SetSize(int width, int height) { }
        public void ChangeVSyncMode(VSyncMode vSyncMode) { }
        public void SetAntiAliasing(AntiAliasing antialiasing) { }
        public void SetScalingFilter(ScalingFilter type) { }
        public void SetScalingFilterLevel(float level) { }
        public void SetColorSpacePassthrough(bool colorSpacePassThroughEnabled) { }
    }

    /// <summary>
    /// 管线状态：保留每类 Set* 最后一次的 GAL 描述符。
    /// </summary>
    public sealed class StubPipeline : IPipeline
    {
        /// <summary>所属桩渲染器（桩渲染器自己的管线时非空；真渲染器外面当观察者时为空）。</summary>
        public StubRenderer Owner;
        public StubPipeline() { }

        // 只计 Ryujinx 实际发到渲染器的绘制调用（host_draws）；frames.tsv 的 draws 在 DrawManager 按硬件判据计
        static bool C(bool indexed, bool indirect)
        {
            return true;
        }

        public PrimitiveTopology Topology;
        public Viewport[] Viewports = Array.Empty<Viewport>();
        public Rectangle<int>[] Scissors = Array.Empty<Rectangle<int>>();
        public readonly BlendDescriptor[] Blend = new BlendDescriptor[8];
        public AdvancedBlendDescriptor? AdvancedBlend;
        public uint[] ColorMasks = new uint[8];
        public DepthTestDescriptor DepthTest;
        public StencilTestDescriptor StencilTest;
        public DepthMode DepthMode;
        public bool DepthClamp;
        public (PolygonModeMask enables, float factor, float units, float clamp) DepthBias;
        public bool CullEnable;
        public Face CullFace;
        public FrontFace FrontFace;
        public PolygonMode PolyFront, PolyBack;
        public bool RasterizerDiscard;
        public (float width, bool smooth) Line;
        public (float size, bool programSize, bool sprite, Origin origin) Point;
        public (bool enable, int index) PrimitiveRestart;
        public (bool enable, LogicalOp op) LogicOp;
        public MultisampleDescriptor Multisample;
        public (bool enable, float reference, CompareOp op) AlphaTest;
        public uint ClipEnableMask;
        public VertexAttribDescriptor[] VertexAttribs = Array.Empty<VertexAttribDescriptor>();
        public VertexBufferDescriptor[] VertexBuffers = Array.Empty<VertexBufferDescriptor>();
        public (BufferRange buffer, IndexType type) IndexBuffer;
        public int PatchVertices;
        public ITexture[] RenderTargets = Array.Empty<ITexture>();
        public ITexture DepthStencilTarget;

        public void Barrier() { }
        public void BeginTransformFeedback(PrimitiveTopology topology) { }
        public void ClearBuffer(BufferHandle destination, int offset, int size, uint value) => Owner?.Buf(destination)?.Fill(offset, size, value); // 真渲染器时没有所属桩渲染器，只记状态

        public void ClearRenderTargetColor(int index, int layer, int layerCount, uint componentMask, ColorF color)
            { }

        public void ClearRenderTargetDepthStencil(int layer, int layerCount, float depthValue, bool depthMask, int stencilValue, int stencilMask)
            { }

        public void CommandBufferBarrier() { }

        public void CopyBuffer(BufferHandle source, BufferHandle destination, int srcOffset, int dstOffset, int size)
        {
            SparseBytes s = Owner?.Buf(source), d = Owner?.Buf(destination);
            if (s == null || d == null || size <= 0)
            {
                return;
            }

            byte[] tmp = new byte[size];
            s.Read(srcOffset, tmp);
            d.Write(dstOffset, tmp);
        }

        public void DispatchCompute(int groupsX, int groupsY, int groupsZ)
            { }

        /// <summary>收到的直接绘制按拓扑换算的图元数累计（给 PrimitivesGenerated 计数器用）。</summary>
        public long Primitives;

        long Prims(int count, int instances)
        {
            long per = Topology switch
            {
                PrimitiveTopology.Points => count,
                PrimitiveTopology.Lines => count / 2,
                PrimitiveTopology.LineStrip => Math.Max(count - 1, 0),
                PrimitiveTopology.LineLoop => count,
                PrimitiveTopology.Triangles => count / 3,
                PrimitiveTopology.TriangleStrip or PrimitiveTopology.TriangleFan or PrimitiveTopology.Polygon => Math.Max(count - 2, 0),
                PrimitiveTopology.Quads => count / 4,
                PrimitiveTopology.QuadStrip => Math.Max(count / 2 - 1, 0),
                _ => count / 3,
            };
            return per * Math.Max(instances, 1);
        }

        public void Draw(int vertexCount, int instanceCount, int firstVertex, int firstInstance)
        {
            Primitives += Prims(vertexCount, instanceCount);
        }

        public void DrawIndexed(int indexCount, int instanceCount, int firstIndex, int firstVertex, int firstInstance)
        {
            Primitives += Prims(indexCount, instanceCount);
        }

        public void DrawIndexedIndirect(BufferRange indirectBuffer) { }
        public void DrawIndexedIndirectCount(BufferRange indirectBuffer, BufferRange parameterBuffer, int maxDrawCount, int stride)
            { }
        public void DrawIndirect(BufferRange indirectBuffer) { }
        public void DrawIndirectCount(BufferRange indirectBuffer, BufferRange parameterBuffer, int maxDrawCount, int stride)
            { }
        public void DrawTexture(ITexture texture, ISampler sampler, Extents2DF srcRegion, Extents2DF dstRegion)
            { }

        public void EndTransformFeedback() { }
        public void SetAlphaTest(bool enable, float reference, CompareOp op) => AlphaTest = (enable, reference, op);
        public void SetBlendState(AdvancedBlendDescriptor blend) => AdvancedBlend = blend;
        public void SetBlendState(int index, BlendDescriptor blend) { Blend[index] = blend; AdvancedBlend = null; }
        public void SetDepthBias(PolygonModeMask enables, float factor, float units, float clamp) => DepthBias = (enables, factor, units, clamp);
        public void SetDepthClamp(bool clamp) => DepthClamp = clamp;
        public void SetDepthMode(DepthMode mode) => DepthMode = mode;
        public void SetDepthTest(DepthTestDescriptor depthTest) => DepthTest = depthTest;
        public void SetFaceCulling(bool enable, Face face) { CullEnable = enable; CullFace = face; }
        public void SetFrontFace(FrontFace frontFace) => FrontFace = frontFace;
        public void SetIndexBuffer(BufferRange buffer, IndexType type) => IndexBuffer = (buffer, type);
        public void SetImage(ShaderStage stage, int binding, ITexture texture) { }
        public void SetImageArray(ShaderStage stage, int binding, IImageArray array) { }
        public void SetImageArraySeparate(ShaderStage stage, int setIndex, IImageArray array) { }
        public void SetLineParameters(float width, bool smooth) => Line = (width, smooth);
        public void SetLogicOpState(bool enable, LogicalOp op) => LogicOp = (enable, op);
        public void SetMultisampleState(MultisampleDescriptor multisample) => Multisample = multisample;
        public void SetPatchParameters(int vertices, ReadOnlySpan<float> defaultOuterLevel, ReadOnlySpan<float> defaultInnerLevel) => PatchVertices = vertices;
        public void SetPointParameters(float size, bool isProgramPointSize, bool enablePointSprite, Origin origin) => Point = (size, isProgramPointSize, enablePointSprite, origin);
        public void SetPolygonMode(PolygonMode frontMode, PolygonMode backMode) { PolyFront = frontMode; PolyBack = backMode; }
        public void SetPrimitiveRestart(bool enable, int index) => PrimitiveRestart = (enable, index);
        public void SetPrimitiveTopology(PrimitiveTopology topology) => Topology = topology;
        public void SetProgram(IProgram program) { }
        public void SetRasterizerDiscard(bool discard) => RasterizerDiscard = discard;
        public void SetRenderTargetColorMasks(ReadOnlySpan<uint> componentMask) => ColorMasks = componentMask.ToArray();
        public void SetRenderTargets(Span<ITexture> colors, ITexture depthStencil) { RenderTargets = colors.ToArray(); DepthStencilTarget = depthStencil; }
        public void SetScissors(ReadOnlySpan<Rectangle<int>> regions) => Scissors = regions.ToArray();
        public void SetStencilTest(StencilTestDescriptor stencilTest) => StencilTest = stencilTest;
        public void SetStorageBuffers(ReadOnlySpan<BufferAssignment> buffers) { }
        public void SetTextureAndSampler(ShaderStage stage, int binding, ITexture texture, ISampler sampler) { }
        public void SetTextureArray(ShaderStage stage, int binding, ITextureArray array) { }
        public void SetTextureArraySeparate(ShaderStage stage, int setIndex, ITextureArray array) { }
        public void SetTransformFeedbackBuffers(ReadOnlySpan<BufferRange> buffers) { }
        public void SetUniformBuffers(ReadOnlySpan<BufferAssignment> buffers) { }
        public void SetUserClipDistance(int index, bool enableClip)
        {
            if (enableClip) ClipEnableMask |= 1u << index; else ClipEnableMask &= ~(1u << index);
        }
        public void SetVertexAttribs(ReadOnlySpan<VertexAttribDescriptor> vertexAttribs) => VertexAttribs = vertexAttribs.ToArray();
        public void SetVertexBuffers(ReadOnlySpan<VertexBufferDescriptor> vertexBuffers) => VertexBuffers = vertexBuffers.ToArray();
        public void SetViewports(ReadOnlySpan<Viewport> viewports) => Viewports = viewports.ToArray();
        public void TextureBarrier() { }
        public void TextureBarrierTiled() { }
        public bool TryHostConditionalRendering(ICounterEvent value, ulong compare, bool isEqual) => false;
        public bool TryHostConditionalRendering(ICounterEvent value, ICounterEvent compare, bool isEqual) => false;
        public void EndHostConditionalRendering() { }
    }

    public enum CounterMode { Visible, Zero }

    public sealed class StubRenderer : IRenderer
    {
        readonly Dictionary<ulong, SparseBytes> _buffers = new();
        ulong _nextBuffer = 1;

        /// <summary>测试用：缓冲句柄改成从 HandleStart 起按 HandleStep 递减 / 递增分配（造「句柄 ≠ 录像编号」的假渲染器）。0 = 缺省 1, 2, 3 …</summary>
        public ulong HandleStart;
        public long HandleStep = 1;

        /// <summary>能力表来源：CapsOverride（录像回放时用录像里的）优先，其次 CapsSource（例如 NxRenderer），都没有就用桩自己的。</summary>
        public Capabilities? CapsOverride;
        public IRenderer CapsSource;
        readonly StubPipeline _pipeline;
        readonly StubWindow _window = new();
        ulong _sync;

        readonly bool _keepData;

        public StubRenderer(bool keepBufferData = false)
        {
            _pipeline = new StubPipeline() { Owner = this };
            _keepData = keepBufferData;
        }

        public StubPipeline StubPipeline => _pipeline;

        public event EventHandler<ScreenCaptureImageInfo> ScreenCaptured { add { } remove { } }
        public bool PreferThreading => false;
        public IPipeline Pipeline => _pipeline;
        public IWindow Window => _window;
        public uint ProgramCount { get; private set; }
        public long TexturesCreated, SamplersCreated, BuffersCreated;

        static BufferHandle MakeHandle(ulong v) => Unsafe.As<ulong, BufferHandle>(ref v);
        static ulong HandleValue(BufferHandle h) => Unsafe.As<BufferHandle, ulong>(ref h);

        public SparseBytes Buf(BufferHandle h) => _buffers.TryGetValue(HandleValue(h), out SparseBytes b) ? b : null;

        public void BackgroundContextAction(Action action, bool alwaysBackground = false) => action();

        public BufferHandle CreateBuffer(int size, BufferAccess access = BufferAccess.Default)
        {
            BuffersCreated++;
            ulong h;
            if (HandleStart != 0)
            {
                h = HandleStart;
                HandleStart = (ulong)((long)HandleStart + HandleStep);
            }
            else
            {
                h = _nextBuffer++;
            }
            _buffers[h] = new SparseBytes(size);
            return MakeHandle(h);
        }

        public BufferHandle CreateBuffer(nint pointer, int size) => CreateBuffer(size);

        public BufferHandle CreateBufferSparse(ReadOnlySpan<BufferRange> storageBuffers)
        {
            int size = 0;
            foreach (BufferRange r in storageBuffers)
            {
                size += r.Size;
            }

            return CreateBuffer(size);
        }

        public IImageArray CreateImageArray(int size, bool isBuffer) => new StubArray();

        public IProgram CreateProgram(ShaderSource[] shaders, ShaderInfo info)
        {
            ProgramCount++;
            return new StubProgram(shaders);
        }

        public ISampler CreateSampler(SamplerCreateInfo info)
        {
            SamplersCreated++;
            return new StubSampler(info);
        }

        public ITexture CreateTexture(TextureCreateInfo info)
        {
            TexturesCreated++;
            return new StubTexture(info);
        }

        public ITextureArray CreateTextureArray(int size, bool isBuffer) => new StubArray();
        public bool PrepareHostMapping(nint address, ulong size) => false;
        public void CreateSync(ulong id, bool strict) => _sync = Math.Max(_sync, id);
        public void DeleteBuffer(BufferHandle buffer) => _buffers.Remove(HandleValue(buffer));

        public PinnedSpan<byte> GetBufferData(BufferHandle buffer, int offset, int size)
        {
            byte[] tmp = new byte[size];
            Buf(buffer)?.Read(offset, tmp);
            return PinnedSpan<byte>.UnsafeFromSpan(tmp);
        }

        public Capabilities GetCapabilities()
        {
            if (CapsOverride is Capabilities co)
            {
                return co;
            }

            if (CapsSource != null)
            {
                return CapsSource.GetCapabilities();
            }

            // 理想主机：压缩格式全支持（不在 CPU 上解码）、Vulkan / SPIR-V 目标；数值取 Ryujinx Vulkan 后端常量。
            return new Capabilities(
                api: TargetApi.Vulkan,
                vendorName: "S2A-Judge",
                memoryType: SystemMemoryType.UnifiedMemory,
                hasFrontFacingBug: false,
                hasVectorIndexingBug: false,
                needsFragmentOutputSpecialization: false,
                reduceShaderPrecision: false,
                supportsAstcCompression: true,
                supportsBc123Compression: true,
                supportsBc45Compression: true,
                supportsBc67Compression: true,
                supportsEtc2Compression: true,
                supports3DTextureCompression: true,
                supportsBgraFormat: true,
                supportsR4G4Format: true,
                supportsR4G4B4A4Format: true,
                supportsScaledVertexFormats: true,
                supportsSnormBufferTextureFormat: true,
                supports5BitComponentFormat: true,
                supportsSparseBuffer: false,
                supportsBlendEquationAdvanced: false,
                supportsFragmentShaderInterlock: false,
                supportsFragmentShaderOrderingIntel: false,
                supportsGeometryShader: true,
                supportsGeometryShaderPassthrough: false,
                supportsTransformFeedback: true,
                supportsImageLoadFormatted: true,
                supportsLayerVertexTessellation: true,
                supportsMismatchingViewFormat: true,
                supportsCubemapView: true,
                supportsNonConstantTextureOffset: false,
                supportsQuads: false,
                supportsSeparateSampler: true,
                supportsShaderBallot: false,
                supportsShaderBarrierDivergence: true,
                supportsShaderFloat64: false,
                supportsShaderNonUniformIndexing: true,
                supportsTextureGatherOffsets: true,
                supportsTextureShadowLod: false,
                supportsVertexStoreAndAtomics: true,
                supportsViewportIndexVertexTessellation: true,
                supportsViewportMask: false,
                supportsViewportSwizzle: false,
                supportsIndirectParameters: true,
                supportsDepthClipControl: true,
                uniformBufferSetIndex: 0,
                storageBufferSetIndex: 1,
                textureSetIndex: 2,
                imageSetIndex: 3,
                extraSetBaseIndex: 4,
                maximumExtraSets: 4,
                maximumUniformBuffersPerStage: 18,
                maximumStorageBuffersPerStage: 16,
                maximumTexturesPerStage: 64,
                maximumImagesPerStage: 16,
                maximumComputeSharedMemorySize: 48 * 1024,
                maximumSupportedAnisotropy: 16,
                shaderSubgroupSize: 32,
                storageBufferOffsetAlignment: 16,
                textureBufferOffsetAlignment: 16,
                gatherBiasPrecision: 0,
                maximumGpuMemory: 8UL << 30);
        }

        public ulong GetCurrentSync() => _sync;
        public HardwareInfo GetHardwareInfo() => new("S2A", "ryu_judge", "stub", "1");
        public IProgram LoadProgramBinary(byte[] programBinary, bool hasFragmentShader, ShaderInfo info) => new StubProgram(Array.Empty<ShaderSource>());
        public void SetBufferData(BufferHandle buffer, int offset, ReadOnlySpan<byte> data)
        {
            if (_keepData)
            {
                Buf(buffer)?.Write(offset, data);
            }
        }
        public void UpdateCounters() { }
        public void PreFrame() { }
        // ---- 计数器（查询）：桩渲染器不画，值按 CounterMode 合成，立即回调（Ryujinx 随即写回客体内存） ----
        // visible（缺省）：SamplesPassed = max(本区间硬件绘制数, 1) × 10000，保证「可见」；
        //                  PrimitivesGenerated / 变换反馈图元 = 本区间桩渲染器收到的直接绘制按拓扑换算的图元数（间接绘制不知道条数，不计）。
        // zero：全部回 0（旧行为，对照用）。区间 = 上次 ResetCounter(该种类) 以来；时间戳由 Ryujinx 自己写（GetTimestamp）。
        public CounterMode CounterMode = CounterMode.Visible;
        readonly long[] _counterBaseDraws = new long[8];
        readonly long[] _counterBasePrims = new long[8];

        public ICounterEvent ReportCounter(CounterType type, EventHandler<ulong> resultHandler, float divisor, bool hostReserved)
        {
            long draws = DrawsNow(); // 每次调用恰好取一个（与 GPU 线程每次调用前排一个对应）
            ulong value = 0;
            if (CounterMode == CounterMode.Visible)
            {
                int t = (int)type;
                switch (type)
                {
                    case CounterType.SamplesPassed:
                        value = (ulong)Math.Max(draws - _counterBaseDraws[t], 1) * 10000;
                        break;
                    case CounterType.PrimitivesGenerated:
                    case CounterType.TransformFeedbackPrimitivesWritten:
                        value = (ulong)Math.Max(_pipeline.Primitives - _counterBasePrims[t], 0);
                        break;
                }
            }

            ReportedValues++;
            LastReported = value;
            resultHandler?.Invoke(this, value);
            return new StubCounterEvent();
        }

        public long ReportedValues;

        /// <summary>
        /// 多线程渲染后端下：GPU 线程在每次 ResetCounter / ReportCounter 调用前把当时的绘制数（S2ACounters.Draws）排进来（S2AHooks.OnCounterOp），
        /// 这里在渲染线程上按同序取出——计数器值按「调用时刻」算，与单线程一致。队列为空（单线程模式没挂钩子）时直接读当前值。
        /// </summary>
        public readonly System.Collections.Concurrent.ConcurrentQueue<long> DrawsAtCounterOp = new();

        long DrawsNow() => DrawsAtCounterOp.TryDequeue(out long d) ? d : 0;
        public ulong LastReported;

        public void ResetCounter(CounterType type)
        {
            int t = (int)type;
            _counterBaseDraws[t] = DrawsNow();
            _counterBasePrims[t] = _pipeline.Primitives;
        }
        public void WaitSync(ulong id) { }
        public void Initialize(GraphicsDebugLevel logLevel) { }
        public void SetInterruptAction(Action<Action> interruptAction) { }
        public void Screenshot() { }
        public void Dispose() { }
    }
}
