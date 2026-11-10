#nullable disable
using Ryujinx.Graphics.Nvdec;
using Ryujinx.Graphics.Nvdec.Android;

namespace S2A.Android.Video
{
    // 安卓装配登记视频解码器（平台 adapter P1，#1069）：Exports.Initialize（Host.Boot）之前调一次，之后只读。
    public static class AndroidVideo
    {
        public static void Register()
        {
            S2AVideoDecoders.H264 = static () => new AvcH264Decoder();
            S2AVideoDecoders.Vp8 = static () => new AndroidVp8Decoder();
            // VP9: NVDEC jobs through libvpx with S2Arm's hook (docs/设计_原生VP9/design_phase2_B.md); the managed decoder
            // takes any job libvpx cannot represent exactly. A missing native library is caught in Vp9Decoder's routing.
            S2AVideoDecoders.Vp9 = static () => new Ryujinx.Graphics.Nvdec.Vpx.VpxVp9Backend();
            S2AVideoDecoders.Vp9DefaultMode = "native";
        }
    }
}
