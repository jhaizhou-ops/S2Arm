using Ryujinx.Graphics.Video;
using System;

namespace Ryujinx.Graphics.Nvdec
{
    class NvdecDecoderContext : IDisposable
    {
        private IH264Decoder _h264Decoder;
        private IVp8Decoder _vp8Decoder;

        // 解码器一律由平台装配登记进 S2AVideoDecoders（苹果 AppleVideo、安卓 AndroidVideo）；没登记落到 Unavailable
        public IH264Decoder GetH264Decoder()
        {
            return _h264Decoder ??= S2AVideoDecoders.CreateH264() ?? new UnavailableH264Decoder();
        }

        public IVp8Decoder GetVp8Decoder()
        {
            return _vp8Decoder ??= S2AVideoDecoders.CreateVp8() ?? new UnavailableVp8Decoder();
        }

        public void Dispose()
        {
            _h264Decoder?.Dispose();
            _h264Decoder = null;

            _vp8Decoder?.Dispose();
            _vp8Decoder = null;
        }
    }
}
