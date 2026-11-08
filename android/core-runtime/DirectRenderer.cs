// C5：direct 会话的托管渲染器。direct 模式下 guest 的图形由 native（NVN 前端 + d2r 引擎）执行，
// 托管侧**不建第二套 GPU**；这个类只负责让 Ryujinx HLE 能构造出"有渲染器"的上下文。
// 规则：能正确什么都不做的（Dispose / Initialize / PreFrame / UpdateCounters）就明确什么都不做；
// 真正要画东西或要分配 GPU 资源的一律抛 NotSupportedException 并带成员名 —— 不静默假装成功。
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using System;
using System.Threading;

namespace S2A.Android.Aot
{
    public sealed class DirectRenderer : IRenderer
    {
        private const string Prefix = "direct renderer: ";

        public event EventHandler<ScreenCaptureImageInfo> ScreenCaptured;
        public bool PreferThreading => false;
        public IPipeline Pipeline => throw Unsupported(nameof(Pipeline));
        public IWindow Window => throw Unsupported(nameof(Window));
        public uint ProgramCount => 0;

        public void Initialize(GraphicsDebugLevel logLevel)
            => Console.Error.WriteLine($"{Prefix}Initialize({logLevel})：托管侧无 GPU，图形走 native direct 表");

        public void Dispose()
            => Console.Error.WriteLine($"{Prefix}Dispose()");

        // 下面这些在 direct 下确实是"无事可做"，明确空实现（不是假装成功：它们没有返回值/副作用）。
        public void PreFrame() { }
        public void UpdateCounters() { }
        public void WaitSync(ulong id) { }
        public void CreateSync(ulong id, bool strict) { }
        public ulong GetCurrentSync() => 0;
        public void ResetCounter(CounterType type) { }
        public void Screenshot() { }
        public void SetInterruptAction(Action<Action> interruptAction) { }
        public void BackgroundContextAction(Action action, bool alwaysBackground = false) { }

        public void RunLoop(ThreadStart gpuLoop)
            => Console.Error.WriteLine($"{Prefix}RunLoop：direct 下不跑 Ryujinx 的 GPU 模拟循环（guest 图形归 native）");

        public ICounterEvent ReportCounter(CounterType type, EventHandler<ulong> resultHandler, float divisor, bool hostReserved)
            => throw Unsupported(nameof(ReportCounter));

        public BufferHandle CreateBuffer(int size, BufferAccess access = BufferAccess.Default)
            => throw Unsupported(nameof(CreateBuffer));
        public BufferHandle CreateBuffer(nint pointer, int size) => throw Unsupported(nameof(CreateBuffer));
        public BufferHandle CreateBufferSparse(ReadOnlySpan<BufferRange> storageBuffers) => throw Unsupported(nameof(CreateBufferSparse));
        public void DeleteBuffer(BufferHandle buffer) => throw Unsupported(nameof(DeleteBuffer));
        public PinnedSpan<byte> GetBufferData(BufferHandle buffer, int offset, int size) => throw Unsupported(nameof(GetBufferData));
        public void SetBufferData(BufferHandle buffer, int offset, ReadOnlySpan<byte> data) => throw Unsupported(nameof(SetBufferData));
        public IImageArray CreateImageArray(int size, bool isBuffer) => throw Unsupported(nameof(CreateImageArray));
        public ITextureArray CreateTextureArray(int size, bool isBuffer) => throw Unsupported(nameof(CreateTextureArray));
        public IProgram CreateProgram(ShaderSource[] shaders, ShaderInfo info) => throw Unsupported(nameof(CreateProgram));
        public IProgram LoadProgramBinary(byte[] programBinary, bool hasFragmentShader, ShaderInfo info)
            => throw Unsupported(nameof(LoadProgramBinary));
        public ISampler CreateSampler(SamplerCreateInfo info) => throw Unsupported(nameof(CreateSampler));
        public ITexture CreateTexture(TextureCreateInfo info) => throw Unsupported(nameof(CreateTexture));
        public bool PrepareHostMapping(nint address, ulong size) => false;
        public Capabilities GetCapabilities() => throw Unsupported(nameof(GetCapabilities));
        public HardwareInfo GetHardwareInfo() => throw Unsupported(nameof(GetHardwareInfo));

        private static NotSupportedException Unsupported(string member)
            => new(Prefix + member + "：direct 会话里由 native 执行，托管侧不得再开一套 GPU");
    }
}
