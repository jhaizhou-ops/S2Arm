using Ryujinx.Graphics.GAL.Multithreading.Commands.TextureArray;
using Ryujinx.Graphics.GAL.Multithreading.Model;
using System;
using System.Linq;

namespace Ryujinx.Graphics.GAL.Multithreading.Resources
{
    /// <summary>
    /// Threaded representation of a texture and sampler array.
    /// </summary>
    class ThreadedTextureArray : ITextureArray
    {
        private readonly ThreadedRenderer _renderer;
        public ITextureArray Base;

        public ThreadedTextureArray(ThreadedRenderer renderer)
        {
            _renderer = renderer;
        }

        // 贴图数组复用开着时（缺省开）：入队那份从精确长度池取（执行完在命令里归还），不每次 ToArray（见 S2ATexArrReuse）
        private static T[] S2ACopy<T>(T[] a) where T : class => S2ATexArrReuse.Copy(a, S2ATexArrReuse.On);

        private TableRef<T> Ref<T>(T reference)
        {
            return new TableRef<T>(_renderer, reference);
        }

        public unsafe void Dispose()
        {
            if (_renderer.S2ADiscardFrees)
            {
                return; // S2A：进程即将退出，下层对象不逐个释放（ThreadedRenderer.S2ADiscardFrees）
            }

            _renderer.New<TextureArrayDisposeCommand>()->Set(Ref(this));
            _renderer.QueueCommand();
        }

        public unsafe void SetSamplers(int index, ISampler[] samplers)
        {
            _renderer.New<TextureArraySetSamplersCommand>()->Set(Ref(this), index, Ref(S2ACopy(samplers)));
            _renderer.QueueCommand();
        }

        public unsafe void SetTextures(int index, ITexture[] textures)
        {
            _renderer.New<TextureArraySetTexturesCommand>()->Set(Ref(this), index, Ref(S2ACopy(textures)));
            _renderer.QueueCommand();
        }
    }
}
