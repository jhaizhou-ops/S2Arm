using System;

namespace Ryujinx.Graphics.Video
{
    public interface IVp8Decoder : IDecoder
    {
        bool Decode(ref Vp8PictureInfo pictureInfo, ISurface output, ReadOnlySpan<byte> bitstream);
    }
}
