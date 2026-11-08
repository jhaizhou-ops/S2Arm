using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using System;
using System.Runtime.CompilerServices;

namespace S2A.Android.Aot
{
    // HLE requires an IRenderer to construct its service process. Direct graphics
    // are owned by native Vulkan. Any accidental GPU emulation command is an error.
    internal sealed class DirectServiceRenderer : IRenderer
    {
        private static Exception Unexpected([CallerMemberName] string name = "") =>
            new InvalidOperationException("Vulkan direct session unexpectedly entered generic renderer: " + name);
        public event EventHandler<ScreenCaptureImageInfo> ScreenCaptured { add => throw Unexpected(); remove => throw Unexpected(); }
        public bool PreferThreading => false;
        public uint ProgramCount => 0;
        public IPipeline Pipeline => throw Unexpected();
        public IWindow Window => throw Unexpected();
        public void BackgroundContextAction(Action action, bool alwaysBackground = false) => throw Unexpected();
        public BufferHandle CreateBuffer(int size, BufferAccess access = BufferAccess.Default) => throw Unexpected();
        public BufferHandle CreateBuffer(nint pointer, int size) => throw Unexpected();
        public BufferHandle CreateBufferSparse(ReadOnlySpan<BufferRange> storageBuffers) => throw Unexpected();
        public IImageArray CreateImageArray(int size, bool isBuffer) => throw Unexpected();
        public IProgram CreateProgram(ShaderSource[] shaders, ShaderInfo info) => throw Unexpected();
        public ISampler CreateSampler(SamplerCreateInfo info) => throw Unexpected();
        public ITexture CreateTexture(TextureCreateInfo info) => throw Unexpected();
        public ITextureArray CreateTextureArray(int size, bool isBuffer) => throw Unexpected();
        public bool PrepareHostMapping(nint address, ulong size) => throw Unexpected();
        public void CreateSync(ulong id, bool strict) => throw Unexpected();
        public void DeleteBuffer(BufferHandle buffer) => throw Unexpected();
        public PinnedSpan<byte> GetBufferData(BufferHandle buffer, int offset, int size) => throw Unexpected();
        public Capabilities GetCapabilities() => throw Unexpected();
        public ulong GetCurrentSync() => throw Unexpected();
        public HardwareInfo GetHardwareInfo() => throw Unexpected();
        public IProgram LoadProgramBinary(byte[] binary, bool fragment, ShaderInfo info) => throw Unexpected();
        public void SetBufferData(BufferHandle buffer, int offset, ReadOnlySpan<byte> data) => throw Unexpected();
        public void UpdateCounters() => throw Unexpected();
        public void PreFrame() => throw Unexpected();
        public ICounterEvent ReportCounter(CounterType type, EventHandler<ulong> handler, float divisor, bool reserved) => throw Unexpected();
        public void ResetCounter(CounterType type) => throw Unexpected();
        public void WaitSync(ulong id) => throw Unexpected();
        public void Initialize(GraphicsDebugLevel logLevel) => throw Unexpected();
        public void SetInterruptAction(Action<Action> interruptAction) => throw Unexpected();
        public void Screenshot() => throw Unexpected();
        public void Dispose() { } // No GAL resources were allocated by this renderer.
    }
}
