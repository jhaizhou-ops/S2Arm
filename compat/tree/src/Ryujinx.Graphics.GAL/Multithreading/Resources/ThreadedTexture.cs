using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL.Multithreading.Commands.Texture;
using Ryujinx.Graphics.GAL.Multithreading.Model;
using System.Threading;

namespace Ryujinx.Graphics.GAL.Multithreading.Resources
{
    /// <summary>
    /// Threaded representation of a texture.
    /// </summary>
    class ThreadedTexture : ITexture
    {
        private readonly ThreadedRenderer _renderer;
        private readonly TextureCreateInfo _info;
        public ITexture Base;

        public int Width => _info.Width;

        public int Height => _info.Height;

        public ThreadedTexture(ThreadedRenderer renderer, TextureCreateInfo info)
        {
            _renderer = renderer;
            _info = info;
        }

        private TableRef<T> Ref<T>(T reference)
        {
            return new TableRef<T>(_renderer, reference);
        }

        public unsafe void CopyTo(ITexture destination, int firstLayer, int firstLevel)
        {
            _renderer.New<TextureCopyToCommand>()->Set(Ref(this), Ref((ThreadedTexture)destination), firstLayer, firstLevel);
            _renderer.QueueCommand();
        }

        public unsafe void CopyTo(ITexture destination, int srcLayer, int dstLayer, int srcLevel, int dstLevel)
        {
            _renderer.New<TextureCopyToSliceCommand>()->Set(Ref(this), Ref((ThreadedTexture)destination), srcLayer, dstLayer, srcLevel, dstLevel);
            _renderer.QueueCommand();
        }

        public unsafe void CopyTo(ITexture destination, Extents2D srcRegion, Extents2D dstRegion, bool linearFilter)
        {
            ThreadedTexture dest = (ThreadedTexture)destination;

            if (_renderer.IsGpuThread())
            {
                _renderer.New<TextureCopyToScaledCommand>()->Set(Ref(this), Ref(dest), srcRegion, dstRegion, linearFilter);
                _renderer.QueueCommand();
            }
            else
            {
                // Scaled copy can happen on another thread for a res scale flush.
                ThreadedHelpers.SpinUntilNonNull(ref Base, _renderer, "贴图在渲染线程上建好（缩放拷贝源）");
                ThreadedHelpers.SpinUntilNonNull(ref dest.Base, _renderer, "贴图在渲染线程上建好（缩放拷贝目标）");
                Interlocked.Increment(ref ThreadedRenderer.S2AOffThreadCalls);

                // S2A：等到对象建好之后持渲染线程锁调下层（见 ThreadedRenderer._s2aBaseLock）
                _renderer.S2AEnterBase();

                try
                {
                    Base.CopyTo(dest.Base, srcRegion, dstRegion, linearFilter);
                }
                finally
                {
                    _renderer.S2AExitBase();
                }
            }
        }

        public unsafe ITexture CreateView(TextureCreateInfo info, int firstLayer, int firstLevel)
        {
            ThreadedTexture newTex = new(_renderer, info);
            _renderer.New<TextureCreateViewCommand>()->Set(Ref(this), Ref(newTex), info, firstLayer, firstLevel);
            _renderer.QueueCommand();

            return newTex;
        }

        public unsafe PinnedSpan<byte> GetData()
        {
            if (_renderer.IsGpuThread())
            {
                ResultBox<PinnedSpan<byte>> box = new();
                _renderer.New<TextureGetDataCommand>()->Set(Ref(this), Ref(box));
                _renderer.InvokeCommand();

                return box.Result;
            }
            else
            {
                ThreadedHelpers.SpinUntilNonNull(ref Base, _renderer, "贴图在渲染线程上建好（读回）");
                Interlocked.Increment(ref ThreadedRenderer.S2AOffThreadCalls);

                _renderer.S2AEnterBase();

                try
                {
                    return Base.GetData();
                }
                finally
                {
                    _renderer.S2AExitBase();
                }
            }
        }

        public unsafe PinnedSpan<byte> GetData(int layer, int level)
        {
            if (_renderer.IsGpuThread())
            {
                ResultBox<PinnedSpan<byte>> box = new();
                _renderer.New<TextureGetDataSliceCommand>()->Set(Ref(this), Ref(box), layer, level);
                _renderer.InvokeCommand();

                return box.Result;
            }
            else
            {
                ThreadedHelpers.SpinUntilNonNull(ref Base, _renderer, "贴图在渲染线程上建好（读回）");
                Interlocked.Increment(ref ThreadedRenderer.S2AOffThreadCalls);

                _renderer.S2AEnterBase();

                try
                {
                    return Base.GetData(layer, level);
                }
                finally
                {
                    _renderer.S2AExitBase();
                }
            }
        }

        public unsafe void CopyTo(BufferRange range, int layer, int level, int stride)
        {
            _renderer.New<TextureCopyToBufferCommand>()->Set(Ref(this), range, layer, level, stride);
            _renderer.QueueCommand();
        }

        /// <inheritdoc/>
        public unsafe void SetData(MemoryOwner<byte> data)
        {
            _renderer.S2AAdmitPayload(data.Length); // S2A：宿主设了在途载荷上限就计入（超上限先背压等），渲染线程执行到时扣掉
            _renderer.New<TextureSetDataCommand>()->Set(Ref(this), Ref(data));
            _renderer.QueueCommand();
        }

        /// <inheritdoc/>
        public unsafe void S2ASetData(S2AUploadLease lease)
        {
            _renderer.New<TextureS2ASetDataCommand>()->Set(Ref(this), lease);
            _renderer.QueueCommand();
        }

        /// <inheritdoc/>
        public unsafe void SetData(MemoryOwner<byte> data, int layer, int level)
        {
            _renderer.S2AAdmitPayload(data.Length); // S2A：同上
            _renderer.New<TextureSetDataSliceCommand>()->Set(Ref(this), Ref(data), layer, level);
            _renderer.QueueCommand();
        }

        /// <inheritdoc/>
        public unsafe void SetData(MemoryOwner<byte> data, int layer, int level, Rectangle<int> region)
        {
            _renderer.S2AAdmitPayload(data.Length); // S2A：同上
            _renderer.New<TextureSetDataSliceRegionCommand>()->Set(Ref(this), Ref(data), layer, level, region);
            _renderer.QueueCommand();
        }

        public unsafe void SetStorage(BufferRange buffer)
        {
            _renderer.New<TextureSetStorageCommand>()->Set(Ref(this), buffer);
            _renderer.QueueCommand();
        }

        public unsafe void Release()
        {
            if (_renderer.S2ADiscardFrees)
            {
                return; // S2A：进程即将退出，下层对象不逐个释放（ThreadedRenderer.S2ADiscardFrees）
            }

            _renderer.New<TextureReleaseCommand>()->Set(Ref(this));
            _renderer.QueueCommand();
        }
    }
}
