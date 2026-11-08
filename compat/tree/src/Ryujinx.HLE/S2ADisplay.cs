using System;
using System.Collections.Concurrent;

namespace Ryujinx.HLE
{
    // S2Arm: display resolution reported to the game follows the host screen's aspect ratio (native widescreen, the game
    // computes its own frustum). Wider than 16:9: height unchanged (1080 docked / 720 handheld), width = round(height × aspect / 2) × 2.
    // Narrower than 16:9 (taller: iPhone Duo inner screen, iPad): width unchanged, height = round(height × ScaleY / 2) × 2, ScaleY = native
    //   s2a_screen_h / 1080 (the same height the widen core and the tall render targets use: 720 → 900 / 1080 → 1350 at 1.422).
    //   Before 11-05 a taller screen reported the original 16:9 size, so tall layer 1 never existed.
    // Aspect comes from the host: S2Arm sets it at S2A_Init from the native layer's screen width (s2a_screen_w / 1080, the single
    // source shared with the widescreen patch points and the GAL widen wrapper); default 16:9, which reproduces the original 1920 / 1280.
    public static class S2ADisplay
    {
        private static double _aspect = 16.0 / 9.0;
        private static readonly ConcurrentDictionary<string, byte> _logged = new();

        public static double Aspect
        {
            get => _aspect;
            set => _aspect = value > 0 ? value : 16.0 / 9.0;
        }

        private static double _scaleY = 1.0;

        // Taller screen: height scale over 16:9 (native s2a_screen_h / 1080); 1 = not taller
        public static double ScaleY
        {
            get => _scaleY;
            set => _scaleY = value > 1 ? value : 1.0;
        }

        public static ulong Width(ulong height) => (ulong)Math.Round(height * _aspect / 2) * 2;

        public static ulong Height(ulong height) => (ulong)Math.Round(height * _scaleY / 2) * 2;

        // First query per interface logs one line (the widescreen loop checks whether the game reads it at all)
        public static void Report(string where, ulong width, ulong height)
        {
            if (_logged.TryAdd(where, 0))
            {
                Console.Error.WriteLine($"[宽] 显示分辨率被查询：{where} → {width}x{height}");
            }
        }
    }
}
