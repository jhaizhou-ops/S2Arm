using Ryujinx.Common.Logging;
using Ryujinx.Graphics.Video;
using System;

namespace Ryujinx.Graphics.Nvdec
{
    // S2Arm 平台 adapter（10-30 边界设计 P1，接口约定见 #1069）：视频解码器由平台装配登记工厂，Nvdec 不再按操作系统选实现。
    //   平台装配在 Host.Boot 之前设一次，之后只读；工厂在 Nvdec 设备线程上、每个解码上下文第一次要解码器时调一次，返回新实例，
    //   解码器归 NvdecDecoderContext（它 Dispose 时释放）。工厂不许抛异常：抛了报红一次、当没登记处理。
    //   苹果已登记（platform/apple/cs/video，S2A.Apple.Video.AppleVideo.Register）；安卓已登记（android/cs/video，S2A.Android.Video.AndroidVideo.Register）；没登记一律 Unavailable
    public static class S2AVideoDecoders
    {
        public static Func<IH264Decoder> H264 { get; set; }
        public static Func<IVp8Decoder> Vp8 { get; set; }
        // VP9 native backend (libvpx with S2Arm's hook; docs/设计_原生VP9/design_phase2_B.md). Unregistered = managed decoder only.
        public static Func<IVp9NativeBackend> Vp9 { get; set; }
        // "native" or "managed" when S2A_NVDEC_VP9 is not set; null = managed.
        public static string Vp9DefaultMode { get; set; }

        private static int _h264Failed, _vp8Failed, _vp9Failed;

        internal static IH264Decoder CreateH264() => Create(H264, ref _h264Failed, "H.264");
        internal static IVp8Decoder CreateVp8() => Create(Vp8, ref _vp8Failed, "VP8");
        internal static IVp9NativeBackend CreateVp9() => Create(Vp9, ref _vp9Failed, "VP9");

        private static string _vp9Mode;

        // S2A_NVDEC_VP9=native|managed, read once per process; otherwise the platform default.
        internal static bool Vp9NativeEnabled
        {
            get
            {
                _vp9Mode ??= Environment.GetEnvironmentVariable("S2A_NVDEC_VP9") ?? Vp9DefaultMode ?? "managed";
                return _vp9Mode == "native";
            }
        }

        private static T Create<T>(Func<T> factory, ref int failed, string codec) where T : class
        {
            if (factory == null) return null;
            try
            {
                return factory();
            }
            catch (Exception e)
            {
                if (System.Threading.Interlocked.Exchange(ref failed, 1) == 0)
                    Logger.Error?.Print(LogClass.Nvdec, $"【红】{codec} 解码器工厂抛异常（{e.GetType().Name}：{e.Message}），当作没登记");
                return null;
            }
        }
    }
}
