using Ryujinx.Common.Logging;
using Ryujinx.Graphics.Video;
using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Graphics.Nvdec
{
    // Neutral surface for the unavailable decoders: holds no decoded planes.
    internal sealed class UnavailableSurface(int width, int height) : ISurface
    {
        public int Width { get; } = width;
        public int Height { get; } = height;
        public int Stride => 0;
        public int UvWidth => (Width + 1) / 2;
        public int UvHeight => (Height + 1) / 2;
        public int UvStride => 0;
        public FrameField Field => FrameField.Progressive;
        public Plane YPlane => default;
        public Plane UPlane => default;
        public Plane VPlane => default;
        public void Dispose() { }
    }
    internal sealed class UnavailableH264Decoder : IH264Decoder
    {
        private bool _reported;
        public bool IsHardwareAccelerated => false;
        public ISurface CreateSurface(int width, int height) => new UnavailableSurface(width, height);
        public bool Decode(ref H264PictureInfo info, ISurface output, ReadOnlySpan<byte> bitstream)
        {
            if (!_reported) Logger.Error?.Print(LogClass.Nvdec, $"【红】Nvdec H264 backend=unavailable stage=select reason=no declared backend rid={RuntimeInformation.RuntimeIdentifier}");
            _reported = true; return false;
        }
        public void Dispose() { }
    }
    internal sealed class UnavailableVp8Decoder : IVp8Decoder
    {
        private bool _reported;
        public bool IsHardwareAccelerated => false;
        public ISurface CreateSurface(int width, int height) => new UnavailableSurface(width, height);
        public bool Decode(ref Vp8PictureInfo info, ISurface output, ReadOnlySpan<byte> bitstream)
        {
            if (!_reported) Logger.Error?.Print(LogClass.Nvdec, $"【红】Nvdec VP8 backend=unavailable stage=select reason=no declared backend rid={RuntimeInformation.RuntimeIdentifier}");
            _reported = true; return false;
        }
        public void Dispose() { }
    }
}
