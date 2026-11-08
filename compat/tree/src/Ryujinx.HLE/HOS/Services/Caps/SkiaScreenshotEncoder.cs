// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using SkiaSharp;
using System;

namespace Ryujinx.HLE.HOS.Services.Caps
{
    // Default hosts retain the original Skia layout, JPEG quality and bytes.
    internal static class SkiaScreenshotEncoder
    {
        public static unsafe byte[] Encode(ReadOnlySpan<byte> rgba, int width, int height, int quality)
        {
            using SKBitmap bitmap = new(new SKImageInfo(width, height, SKColorType.Rgba8888));
            nint pixels = bitmap.GetPixels();
            if (pixels == 0) throw new ScreenshotBitmapAllocationException();
            rgba.CopyTo(new Span<byte>((void*)pixels, rgba.Length));
            using SKData data = bitmap.Encode(SKEncodedImageFormat.Jpeg, quality);
            return data?.ToArray() ?? throw new InvalidOperationException("Screenshot JPEG encoding failed");
        }
    }
}
