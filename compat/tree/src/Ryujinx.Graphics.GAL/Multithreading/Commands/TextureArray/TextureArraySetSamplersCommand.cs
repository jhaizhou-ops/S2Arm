using Ryujinx.Graphics.GAL.Multithreading.Model;
using Ryujinx.Graphics.GAL.Multithreading.Resources;
using System.Linq;

namespace Ryujinx.Graphics.GAL.Multithreading.Commands.TextureArray
{
    struct TextureArraySetSamplersCommand : IGALCommand, IGALCommand<TextureArraySetSamplersCommand>
    {
        public readonly CommandType CommandType => CommandType.TextureArraySetSamplers;
        private TableRef<ThreadedTextureArray> _textureArray;
        private int _index;
        private TableRef<ISampler[]> _samplers;

        public void Set(TableRef<ThreadedTextureArray> textureArray, int index, TableRef<ISampler[]> samplers)
        {
            _textureArray = textureArray;
            _index = index;
            _samplers = samplers;
        }

        public static void Run(ref TextureArraySetSamplersCommand command, ThreadedRenderer threaded, IRenderer renderer)
        {
            ThreadedTextureArray textureArray = command._textureArray.Get(threaded);
            if (S2ATexArrReuse.On)
            {
                ISampler[] a = command._samplers.Get(threaded);
                for (int i = 0; i < a.Length; i++) a[i] = ((ThreadedSampler)a[i])?.Base;
                textureArray.Base.SetSamplers(command._index, a);
                S2ATexArrReuse.Return(a);
                return;
            }

            ISampler[] samplers = command._samplers.Get(threaded);
            S2ATexArrReuse.DiagAdd(3, samplers.Length);
            textureArray.Base.SetSamplers(command._index, samplers.Select(sampler => ((ThreadedSampler)sampler)?.Base).ToArray());
        }
    }
}
