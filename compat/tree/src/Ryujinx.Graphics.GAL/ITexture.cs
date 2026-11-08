using Ryujinx.Common.Memory;
using System;

namespace Ryujinx.Graphics.GAL
{
    public interface ITexture
    {
        int Width { get; }
        int Height { get; }

        void CopyTo(ITexture destination, int firstLayer, int firstLevel);
        void CopyTo(ITexture destination, int srcLayer, int dstLayer, int srcLevel, int dstLevel);
        void CopyTo(ITexture destination, Extents2D srcRegion, Extents2D dstRegion, bool linearFilter);
        void CopyTo(BufferRange range, int layer, int level, int stride);

        ITexture CreateView(TextureCreateInfo info, int firstLayer, int firstLevel);

        PinnedSpan<byte> GetData();
        PinnedSpan<byte> GetData(int layer, int level);

        /// <summary>
        /// Sets the texture data. The data passed as a <see cref="MemoryOwner{Byte}" /> will be disposed when
        /// the operation completes.
        /// </summary>
        /// <param name="data">Texture data bytes</param>
        void SetData(MemoryOwner<byte> data);
        /// <summary>S2A：同 SetData(MemoryOwner)，数据在渲染器租出的上传内存里（<see cref="S2AUploadLease"/>），租约随之收回。只有租约来自的渲染器支持</summary>
        void S2ASetData(S2AUploadLease lease) => throw new NotSupportedException();

        /// <summary>
        /// Sets the texture data. The data passed as a <see cref="MemoryOwner{Byte}" /> will be disposed when
        /// the operation completes.
        /// </summary>
        /// <param name="data">Texture data bytes</param>
        /// <param name="layer">Target layer</param>
        /// <param name="level">Target level</param>
        void SetData(MemoryOwner<byte> data, int layer, int level);

        /// <summary>
        /// Sets the texture data. The data passed as a <see cref="MemoryOwner{Byte}" /> will be disposed when
        /// the operation completes.
        /// </summary>
        /// <param name="data">Texture data bytes</param>
        /// <param name="layer">Target layer</param>
        /// <param name="level">Target level</param>
        /// <param name="region">Target sub-region of the texture to update</param>
        void SetData(MemoryOwner<byte> data, int layer, int level, Rectangle<int> region);

        void SetStorage(BufferRange buffer);

        void Release();
    }
}
