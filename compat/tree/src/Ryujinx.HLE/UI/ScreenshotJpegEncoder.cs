// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;

namespace Ryujinx.HLE.UI
{
    // Packed RGBA8888, premultiplied alpha, top-to-bottom rows; no row padding.
    // Return a complete JPEG or throw. A provider must never report success without encoding.
    public delegate byte[] ScreenshotJpegEncoder(ReadOnlySpan<byte> rgba, int width, int height, int quality);
}
