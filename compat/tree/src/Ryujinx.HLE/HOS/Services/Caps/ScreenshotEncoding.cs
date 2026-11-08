// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;

namespace Ryujinx.HLE.HOS.Services.Caps
{
    internal sealed class ScreenshotBitmapAllocationException : Exception { }

    internal static class ScreenshotEncoding
    {
        public static byte[] Encode(ReadOnlySpan<byte> rgba, int width, int height, int quality)
        {
            if (width <= 0 || height <= 0 || width > 4096 || height > 4096 ||
                quality < 0 || quality > 100 || (long)width * height * 4 != rgba.Length)
                throw new ArgumentException("Invalid packed RGBA screenshot");
            byte[] jpeg;
            if (S2AHooks.EncodeScreenshotJpeg != null)
                jpeg = S2AHooks.EncodeScreenshotJpeg(rgba, width, height, quality);
            else
#if S2A_ANDROID_HOST
                throw new NotSupportedException("Android screenshot encoder is not connected");
#elif S2A_APPLE_HOST
                throw new NotSupportedException("Apple screenshot encoder is not connected");
#else
                jpeg = SkiaScreenshotEncoder.Encode(rgba, width, height, quality);
#endif
            if (jpeg == null || jpeg.Length < 4 || jpeg[0] != 0xff || jpeg[1] != 0xd8 ||
                jpeg[^2] != 0xff || jpeg[^1] != 0xd9)
                throw new InvalidOperationException("Screenshot provider did not return a complete JPEG");
            return jpeg;
        }
    }
}
