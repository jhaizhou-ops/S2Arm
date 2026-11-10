using Ryujinx.Graphics.Video;
using System;

namespace Ryujinx.Graphics.Nvdec
{
    class NvdecDecoderContext : IDisposable
    {
        private IH264Decoder _h264Decoder;
        private IVp8Decoder _vp8Decoder;
        private Vp9.Decoder _managedVp9;
        private Vp9NativePath _nativeVp9;
        private bool _nativeVp9Tried;

        // 解码器一律由平台装配登记进 S2AVideoDecoders（苹果 AppleVideo、安卓 AndroidVideo）；没登记落到 Unavailable
        public IH264Decoder GetH264Decoder()
        {
            return _h264Decoder ??= S2AVideoDecoders.CreateH264() ?? new UnavailableH264Decoder();
        }

        public IVp8Decoder GetVp8Decoder()
        {
            return _vp8Decoder ??= S2AVideoDecoders.CreateVp8() ?? new UnavailableVp8Decoder();
        }

        // Managed VP9 decoder, one per context (its segment-map state belongs to one stream).
        public Vp9.Decoder GetManagedVp9()
        {
            return _managedVp9 ??= new Vp9.Decoder();
        }

        // Native VP9 path, or null when no backend is registered, the mode is managed, or it was disabled.
        public Vp9NativePath GetVp9Native()
        {
            if (!_nativeVp9Tried)
            {
                _nativeVp9Tried = true;

                if (S2AVideoDecoders.Vp9NativeEnabled && S2AVideoDecoders.CreateVp9() is IVp9NativeBackend backend)
                {
                    _nativeVp9 = new Vp9NativePath(backend);
                }
            }

            return _nativeVp9 is { Disabled: false } ? _nativeVp9 : null;
        }

        public void Dispose()
        {
            _h264Decoder?.Dispose();
            _h264Decoder = null;

            _vp8Decoder?.Dispose();
            _vp8Decoder = null;

            _nativeVp9?.Dispose();
            _nativeVp9 = null;

            _managedVp9?.Dispose();
            _managedVp9 = null;
        }
    }
}
