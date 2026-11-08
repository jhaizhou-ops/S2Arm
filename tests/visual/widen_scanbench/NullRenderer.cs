// 空渲染器（只给 CPU 回放基准用）：GAL 调用全部空转，建出来的对象只记尺寸。宽屏包装层套在它外面回放录像，量的就是包装层自己的 CPU。
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader;
using RyuJudge;
using System;
using System.Runtime.CompilerServices;
using System.Threading;

sealed class NullRenderer : IRenderer
{
    readonly Capabilities _caps; ulong _nextBuf = 1;
    public NullRenderer(Capabilities caps) { _caps = caps; }
    public event EventHandler<ScreenCaptureImageInfo> ScreenCaptured { add { } remove { } }
    public bool PreferThreading => false;
    public IPipeline Pipeline { get; } = new NullPipeline();
    public IWindow Window { get; } = new NullWindow();
    public uint ProgramCount => 0;
    public void BackgroundContextAction(Action action, bool alwaysBackground = false) => action();
    BufferHandle NewBuf() { ulong v = _nextBuf++; return Unsafe.As<ulong, BufferHandle>(ref v); }
    public BufferHandle CreateBuffer(int size, BufferAccess access = BufferAccess.Default) => NewBuf();
    public BufferHandle CreateBuffer(nint pointer, int size) => NewBuf();
    public BufferHandle CreateBufferSparse(ReadOnlySpan<BufferRange> storageBuffers) => NewBuf();
    public IImageArray CreateImageArray(int size, bool isBuffer) => new StubArray();
    public IProgram CreateProgram(ShaderSource[] shaders, ShaderInfo info) => new StubProgram(shaders);
    public ISampler CreateSampler(SamplerCreateInfo info) => new StubSampler(info);
    public ITexture CreateTexture(TextureCreateInfo info) => new NullTexture(info);
    public ITextureArray CreateTextureArray(int size, bool isBuffer) => new StubArray();
    public bool PrepareHostMapping(nint address, ulong size) => false;
    public void CreateSync(ulong id, bool strict) { }
    public void DeleteBuffer(BufferHandle buffer) { }
    public PinnedSpan<byte> GetBufferData(BufferHandle buffer, int offset, int size) => default;
    public Capabilities GetCapabilities() => _caps;
    public ulong GetCurrentSync() => 0;
    public HardwareInfo GetHardwareInfo() => default;
    public IProgram LoadProgramBinary(byte[] programBinary, bool hasFragmentShader, ShaderInfo info) => new StubProgram(null);
    public void SetBufferData(BufferHandle buffer, int offset, ReadOnlySpan<byte> data) { }
    public void UpdateCounters() { }
    public void PreFrame() { }
    public ICounterEvent ReportCounter(CounterType type, EventHandler<ulong> resultHandler, float divisor, bool hostReserved) => new StubCounterEvent();
    public void ResetCounter(CounterType type) { }
    public void RunLoop(ThreadStart gpuLoop) => gpuLoop();
    public void WaitSync(ulong id) { }
    public void Initialize(GraphicsDebugLevel logLevel) { }
    public void SetInterruptAction(Action<Action> interruptAction) { }
    public void Screenshot() { }
    public void Dispose() { }
}

sealed class NullTexture : ITexture
{
    readonly TextureCreateInfo _i;
    public NullTexture(TextureCreateInfo i) { _i = i; }
    public int Width => _i.Width;
    public int Height => _i.Height;
    public void CopyTo(ITexture destination, int firstLayer, int firstLevel) { }
    public void CopyTo(ITexture destination, int srcLayer, int dstLayer, int srcLevel, int dstLevel) { }
    public void CopyTo(ITexture destination, Extents2D srcRegion, Extents2D dstRegion, bool linearFilter) { }
    public void CopyTo(BufferRange range, int layer, int level, int stride) { }
    public ITexture CreateView(TextureCreateInfo info, int firstLayer, int firstLevel) => new NullTexture(info);
    public PinnedSpan<byte> GetData() => default;
    public PinnedSpan<byte> GetData(int layer, int level) => default;
    public void SetData(MemoryOwner<byte> data) => data.Dispose();
    public void SetData(MemoryOwner<byte> data, int layer, int level) => data.Dispose();
    public void SetData(MemoryOwner<byte> data, int layer, int level, Rectangle<int> region) => data.Dispose();
    public void SetStorage(BufferRange buffer) { }
    public void Release() { }
}

sealed class NullWindow : IWindow
{
    public void Present(ITexture texture, ImageCrop crop, Action swapBuffersCallback) => swapBuffersCallback?.Invoke();
    public void SetSize(int width, int height) { }
    public void ChangeVSyncMode(VSyncMode vSyncMode) { }
    public void SetAntiAliasing(AntiAliasing antialiasing) { }
    public void SetScalingFilter(ScalingFilter type) { }
    public void SetScalingFilterLevel(float level) { }
    public void SetColorSpacePassthrough(bool colorSpacePassThroughEnabled) { }
}

sealed class NullPipeline : IPipeline
{
        public void Barrier() { }
        public void BeginTransformFeedback(PrimitiveTopology topology) { }
        public void ClearBuffer(BufferHandle destination, int offset, int size, uint value) { }
        public void ClearRenderTargetColor(int index, int layer, int layerCount, uint componentMask, ColorF color) { }
        public void ClearRenderTargetDepthStencil(int layer, int layerCount, float depthValue, bool depthMask, int stencilValue, int stencilMask) { }
        public void CommandBufferBarrier() { }
        public void CopyBuffer(BufferHandle source, BufferHandle destination, int srcOffset, int dstOffset, int size) { }
        public void DispatchCompute(int groupsX, int groupsY, int groupsZ) { }
        public void Draw(int vertexCount, int instanceCount, int firstVertex, int firstInstance) { }
        public void DrawIndexed(int indexCount, int instanceCount, int firstIndex, int firstVertex, int firstInstance) { }
        public void DrawIndexedIndirect(BufferRange indirectBuffer) { }
        public void DrawIndexedIndirectCount(BufferRange indirectBuffer, BufferRange parameterBuffer, int maxDrawCount, int stride) { }
        public void DrawIndirect(BufferRange indirectBuffer) { }
        public void DrawIndirectCount(BufferRange indirectBuffer, BufferRange parameterBuffer, int maxDrawCount, int stride) { }
        public void DrawTexture(ITexture texture, ISampler sampler, Extents2DF srcRegion, Extents2DF dstRegion) { }
        public void EndTransformFeedback() { }
        public void SetAlphaTest(bool enable, float reference, CompareOp op) { }
        public void SetBlendState(AdvancedBlendDescriptor blend) { }
        public void SetBlendState(int index, BlendDescriptor blend) { }
        public void SetDepthBias(PolygonModeMask enables, float factor, float units, float clamp) { }
        public void SetDepthClamp(bool clamp) { }
        public void SetDepthMode(DepthMode mode) { }
        public void SetDepthTest(DepthTestDescriptor depthTest) { }
        public void SetFaceCulling(bool enable, Face face) { }
        public void SetFrontFace(FrontFace frontFace) { }
        public void SetIndexBuffer(BufferRange buffer, IndexType type) { }
        public void SetImage(ShaderStage stage, int binding, ITexture texture) { }
        public void SetImageArray(ShaderStage stage, int binding, IImageArray array) { }
        public void SetImageArraySeparate(ShaderStage stage, int setIndex, IImageArray array) { }
        public void SetLineParameters(float width, bool smooth) { }
        public void SetLogicOpState(bool enable, LogicalOp op) { }
        public void SetMultisampleState(MultisampleDescriptor multisample) { }
        public void SetPatchParameters(int vertices, ReadOnlySpan<float> defaultOuterLevel, ReadOnlySpan<float> defaultInnerLevel) { }
        public void SetPointParameters(float size, bool isProgramPointSize, bool enablePointSprite, Origin origin) { }
        public void SetPolygonMode(PolygonMode frontMode, PolygonMode backMode) { }
        public void SetPrimitiveRestart(bool enable, int index) { }
        public void SetPrimitiveTopology(PrimitiveTopology topology) { }
        public void SetProgram(IProgram program) { }
        public void SetRasterizerDiscard(bool discard) { }
        public void SetRenderTargetColorMasks(ReadOnlySpan<uint> componentMask) { }
        public void SetRenderTargets(Span<ITexture> colors, ITexture depthStencil) { }
        public void SetScissors(ReadOnlySpan<Rectangle<int>> regions) { }
        public void SetStencilTest(StencilTestDescriptor stencilTest) { }
        public void SetStorageBuffers(ReadOnlySpan<BufferAssignment> buffers) { }
        public void SetTextureAndSampler(ShaderStage stage, int binding, ITexture texture, ISampler sampler) { }
        public void SetTextureArray(ShaderStage stage, int binding, ITextureArray array) { }
        public void SetTextureArraySeparate(ShaderStage stage, int setIndex, ITextureArray array) { }
        public void SetTransformFeedbackBuffers(ReadOnlySpan<BufferRange> buffers) { }
        public void SetUniformBuffers(ReadOnlySpan<BufferAssignment> buffers) { }
        public void SetUserClipDistance(int index, bool enableClip) { }
        public void SetVertexAttribs(ReadOnlySpan<VertexAttribDescriptor> vertexAttribs) { }
        public void SetVertexBuffers(ReadOnlySpan<VertexBufferDescriptor> vertexBuffers) { }
        public void SetViewports(ReadOnlySpan<Viewport> viewports) { }
        public void TextureBarrier() { }
        public void TextureBarrierTiled() { }
        public bool TryHostConditionalRendering(ICounterEvent value, ulong compare, bool isEqual) => false;
        public bool TryHostConditionalRendering(ICounterEvent value, ICounterEvent compare, bool isEqual) => false;
        public void EndHostConditionalRendering() { }
}
