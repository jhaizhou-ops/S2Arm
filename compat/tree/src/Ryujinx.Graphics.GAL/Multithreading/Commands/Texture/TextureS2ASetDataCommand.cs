using Ryujinx.Graphics.GAL.Multithreading.Model;
using Ryujinx.Graphics.GAL.Multithreading.Resources;

namespace Ryujinx.Graphics.GAL.Multithreading.Commands.Texture
{
    /// <summary>S2A：整张贴图写入，数据在上传租约里（Gpu 层转格式直接写进租约，见 S2AUploadLease）</summary>
    struct TextureS2ASetDataCommand : IGALCommand, IGALCommand<TextureS2ASetDataCommand>
    {
        public readonly CommandType CommandType => CommandType.TextureS2ASetData;
        private TableRef<ThreadedTexture> _texture;
        private S2AUploadLease _lease;

        public void Set(TableRef<ThreadedTexture> texture, S2AUploadLease lease)
        {
            _texture = texture;
            _lease = lease;
        }

        public static void Run(ref TextureS2ASetDataCommand command, ThreadedRenderer threaded, IRenderer renderer)
        {
            ThreadedTexture texture = command._texture.Get(threaded);
            texture.Base.S2ASetData(command._lease);
        }
    }
}
