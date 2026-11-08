using Ryujinx.Graphics.GAL.Multithreading.Model;
using Ryujinx.Graphics.GAL.Multithreading.Resources;
using System.Linq;

namespace Ryujinx.Graphics.GAL.Multithreading.Commands.TextureArray
{
    struct TextureArraySetTexturesCommand : IGALCommand, IGALCommand<TextureArraySetTexturesCommand>
    {
        public readonly CommandType CommandType => CommandType.TextureArraySetTextures;
        private TableRef<ThreadedTextureArray> _textureArray;
        private int _index;
        private TableRef<ITexture[]> _textures;

        public void Set(TableRef<ThreadedTextureArray> textureArray, int index, TableRef<ITexture[]> textures)
        {
            _textureArray = textureArray;
            _index = index;
            _textures = textures;
        }

        public static void Run(ref TextureArraySetTexturesCommand command, ThreadedRenderer threaded, IRenderer renderer)
        {
            ThreadedTextureArray textureArray = command._textureArray.Get(threaded);
            if (S2ATexArrReuse.On)
            {
                // 入队那份是我们的私有副本（S2ATexArrReuse 池里取的）：原地换成底层对象、交下去，下游同步拷走后清空归还
                ITexture[] a = command._textures.Get(threaded);
                for (int i = 0; i < a.Length; i++) a[i] = ((ThreadedTexture)a[i])?.Base;
                textureArray.Base.SetTextures(command._index, a);
                S2ATexArrReuse.Return(a);
                return;
            }

            ITexture[] textures = command._textures.Get(threaded);
            S2ATexArrReuse.DiagAdd(3, textures.Length);
            textureArray.Base.SetTextures(command._index, textures.Select(texture => ((ThreadedTexture)texture)?.Base).ToArray());
        }
    }
}
