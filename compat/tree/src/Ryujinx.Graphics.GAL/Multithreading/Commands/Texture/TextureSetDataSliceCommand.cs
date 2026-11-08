using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL.Multithreading.Model;
using Ryujinx.Graphics.GAL.Multithreading.Resources;

namespace Ryujinx.Graphics.GAL.Multithreading.Commands.Texture
{
    struct TextureSetDataSliceCommand : IGALCommand, IGALCommand<TextureSetDataSliceCommand>
    {
        public readonly CommandType CommandType => CommandType.TextureSetDataSlice;
        private TableRef<ThreadedTexture> _texture;
        private TableRef<MemoryOwner<byte>> _data;
        private int _layer;
        private int _level;

        public void Set(TableRef<ThreadedTexture> texture, TableRef<MemoryOwner<byte>> data, int layer, int level)
        {
            _texture = texture;
            _data = data;
            _layer = layer;
            _level = level;
        }

        public static void Run(ref TextureSetDataSliceCommand command, ThreadedRenderer threaded, IRenderer renderer)
        {
            ThreadedTexture texture = command._texture.Get(threaded);
            MemoryOwner<byte> data = command._data.Get(threaded);
            threaded.S2AReleasePayload(data.Length); // S2A：入队时计入过在途载荷（宿主设了上限时）
            texture.Base.SetData(data, command._layer, command._level);
        }
    }
}
