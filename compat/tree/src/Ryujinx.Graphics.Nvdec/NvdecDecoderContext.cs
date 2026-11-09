using Ryujinx.Graphics.Video;
using System;

namespace Ryujinx.Graphics.Nvdec
{
    class NvdecDecoderContext : IDisposable
    {
        private IH264Decoder _h264Decoder;
        private IVp8Decoder _vp8Decoder;
        private IVp9Decoder _vp9Decoder;

        // 解码器一律由平台装配登记进 S2AVideoDecoders（苹果 AppleVideo、安卓 AndroidVideo）；没登记落到 Unavailable
        // （VP9 例外：工厂没登记回树内托管 Vp9.Decoder——登记槽接上之前 VP9 一直走的也是它）。
        public IH264Decoder GetH264Decoder()
        {
            return _h264Decoder ??= S2AVideoDecoders.CreateH264() ?? new UnavailableH264Decoder();
        }

        public IVp8Decoder GetVp8Decoder()
        {
            return _vp8Decoder ??= S2AVideoDecoders.CreateVp8() ?? new UnavailableVp8Decoder();
        }

        public IVp9Decoder GetVp9Decoder()
        {
            return _vp9Decoder ??= S2AVideoDecoders.CreateVp9() ?? new Vp9.Decoder();
        }

        public void Dispose()
        {
            _h264Decoder?.Dispose();
            _h264Decoder = null;

            _vp8Decoder?.Dispose();
            _vp8Decoder = null;

            _vp9Decoder?.Dispose();
            _vp9Decoder = null;
        }
    }
}
