using Ryujinx.Common.Configuration;
using Ryujinx.Common.Logging;
using Ryujinx.Graphics.GAL.Multithreading;
using System;
using System.Threading;

namespace Ryujinx.Graphics.GAL
{
    public interface IRenderer : IDisposable
    {
        event EventHandler<ScreenCaptureImageInfo> ScreenCaptured;

        bool PreferThreading { get; }

        /// <summary>S2A：租一段上传内存（见 <see cref="S2AUploadLease"/>；可在 GPU 模拟线程上直接调用）。不支持返回 false，调用方走原路</summary>
        bool S2ATryRentUpload(int size, out S2AUploadLease lease)
        {
            lease = default;
            return false;
        }

        /// <summary>S2A：退还没交出去的租约</summary>
        void S2ADropUpload(S2AUploadLease lease) { }

        /// <summary>S2A：把租约里的数据写进缓冲（同 SetBufferData，按命令顺序生效），租约随之收回</summary>
        void S2ASetBufferData(BufferHandle buffer, int offset, S2AUploadLease lease) => throw new NotSupportedException();

        public IRenderer TryMakeThreaded(BackendThreading backendThreading = BackendThreading.Auto)
        {
            if (backendThreading is BackendThreading.On ||
                (backendThreading is BackendThreading.Auto && PreferThreading))
            {
                Logger.Info?.PrintMsg(LogClass.Gpu, $"Backend Threading ({backendThreading}): True");
                return new ThreadedRenderer(this);
            }

            Logger.Info?.PrintMsg(LogClass.Gpu, $"Backend Threading ({backendThreading}): False");

            return this;
        }

        IPipeline Pipeline { get; }

        IWindow Window { get; }

        uint ProgramCount { get; }

        void BackgroundContextAction(Action action, bool alwaysBackground = false);

        BufferHandle CreateBuffer(int size, BufferAccess access = BufferAccess.Default);
        BufferHandle CreateBuffer(nint pointer, int size);
        BufferHandle CreateBufferSparse(ReadOnlySpan<BufferRange> storageBuffers);

        IImageArray CreateImageArray(int size, bool isBuffer);

        IProgram CreateProgram(ShaderSource[] shaders, ShaderInfo info);

        ISampler CreateSampler(SamplerCreateInfo info);
        ITexture CreateTexture(TextureCreateInfo info);
        /// <summary>S2A：携带纹理自身的分辨率倍率；尺寸已缩放，不再次改尺寸。默认后端沿用原建纹理接口。</summary>
        ITexture CreateTexture(TextureCreateInfo info, float resolutionScale) => CreateTexture(info);
        ITextureArray CreateTextureArray(int size, bool isBuffer);

        bool PrepareHostMapping(nint address, ulong size);

        void CreateSync(ulong id, bool strict);

        void DeleteBuffer(BufferHandle buffer);

        PinnedSpan<byte> GetBufferData(BufferHandle buffer, int offset, int size);

        Capabilities GetCapabilities();
        ulong GetCurrentSync();
        HardwareInfo GetHardwareInfo();

        IProgram LoadProgramBinary(byte[] programBinary, bool hasFragmentShader, ShaderInfo info);

        void SetBufferData(BufferHandle buffer, int offset, ReadOnlySpan<byte> data);

        void UpdateCounters();

        void PreFrame();

        ICounterEvent ReportCounter(CounterType type, EventHandler<ulong> resultHandler, float divisor, bool hostReserved);

        void ResetCounter(CounterType type);

        void RunLoop(ThreadStart gpuLoop)
        {
            gpuLoop();
        }

        void WaitSync(ulong id);

        void Initialize(GraphicsDebugLevel logLevel);

        void SetInterruptAction(Action<Action> interruptAction);

        void Screenshot();
    }
}
