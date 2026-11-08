// 空渲染器（只给 CPU 回放基准用）：GAL 调用全部空转，建出来的对象只记尺寸。宽屏包装层套在它外面回放录像，量的就是包装层自己的 CPU。
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader;
using System;
using System.Runtime.CompilerServices;
using System.Threading;

sealed class UploadRenderer : IRenderer
{
    readonly Capabilities _caps; ulong _nextBuf = 1;
    public UploadRenderer(Capabilities caps) { _caps = caps; }
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
    public IImageArray CreateImageArray(int size, bool isBuffer) => throw new NotSupportedException();
    public IProgram CreateProgram(ShaderSource[] shaders, ShaderInfo info) => throw new NotSupportedException();
    public ISampler CreateSampler(SamplerCreateInfo info) => throw new NotSupportedException();
    public ITexture CreateTexture(TextureCreateInfo info) => new NullTexture(info);
    public ITextureArray CreateTextureArray(int size, bool isBuffer) => throw new NotSupportedException();
    public bool PrepareHostMapping(nint address, ulong size) => false;
    public void CreateSync(ulong id, bool strict) { }
    public void DeleteBuffer(BufferHandle buffer) { }
    public PinnedSpan<byte> GetBufferData(BufferHandle buffer, int offset, int size) => default;
    public Capabilities GetCapabilities() => _caps;
    public ulong GetCurrentSync() => 0;
    public HardwareInfo GetHardwareInfo() => default;
    public IProgram LoadProgramBinary(byte[] programBinary, bool hasFragmentShader, ShaderInfo info) => throw new NotSupportedException();
    public VulkanUpload Upload;
    public void SetBufferData(BufferHandle buffer, int offset, ReadOnlySpan<byte> data) => Upload.SetData(offset, data);
    public void UpdateCounters() { }
    public void PreFrame() { }
    public ICounterEvent ReportCounter(CounterType type, EventHandler<ulong> resultHandler, float divisor, bool hostReserved) => throw new NotSupportedException();
    public void ResetCounter(CounterType type) { }
    public void RunLoop(ThreadStart gpuLoop) => gpuLoop();
    public void WaitSync(ulong id) { }
    public void Initialize(GraphicsDebugLevel logLevel) { }
    public void SetInterruptAction(Action<Action> interruptAction) { }
    public void Screenshot() { }
    public void Dispose() { }
}
