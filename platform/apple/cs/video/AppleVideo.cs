using Ryujinx.Graphics.Nvdec;

namespace S2A.Apple.Video
{
    // 苹果装配登记视频解码器（平台 adapter P1，#1069）：Host.Boot 之前调一次
    public static class AppleVideo
    {
        public static void Register()
        {
            S2AVideoDecoders.H264 = static () => new Ryujinx.Graphics.Nvdec.Apple.VideoToolboxH264Decoder();
            S2AVideoDecoders.Vp8 = static () => new Ryujinx.Graphics.Nvdec.Vpx.VpxVp8Decoder();   // 共用 libvpx 封装（安卓的 AndroidVp8Decoder 也包它）；VideoToolbox 不解 VP8
        }
    }
}
