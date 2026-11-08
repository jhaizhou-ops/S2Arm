// SPDX-License-Identifier: MIT
// Copyright (c) Ryujinx Team and Contributors
// Present-fit geometry moved verbatim out of AndroidWindow.cs: the same formulas,
// isolated so the Android output-adapter code has its own file for per-platform
// implementation hashing (#1574 F7, tools/caps_policy.py IMPL).
using Ryujinx.Graphics.GAL;
using System;

namespace S2Arm.Backends.Vulkan.Wsi;

// Maps a game frame crop into the published Android window: aspect-fit inside the
// inset-free region, plus the matching Switch touch rectangle. Pure geometry — the
// caller still owns the blit and the native touch publish.
internal static class AndroidPresentFit
{
    public struct Rect
    {
        public int SrcX0, SrcY0, SrcX1, SrcY1;   // source crop, texels
        public int DstX0, DstY0, DstX1, DstY1;   // destination corners, window pixels
        public int TouchX, TouchY, TouchWidth, TouchHeight;   // Switch touch region, window pixels
        public bool SwitchRegion;                // crop is the standard 16:9 game frame
    }

    public static Rect Fit(ImageCrop crop, int sourceWidth, int sourceHeight, NativeLeaseState state, int chainWidth, int chainHeight)
    {
        int x0 = crop.Left, x1 = crop.Right == 0 ? sourceWidth : crop.Right;
        int y0 = crop.Top, y1 = crop.Bottom == 0 ? sourceHeight : crop.Bottom;
        int width = chainWidth - state.InsetLeft - state.InsetRight;
        int height = chainHeight - state.InsetTop - state.InsetBottom;
        float rx = crop.IsStretched ? 1 : MathF.Min(1, height * crop.AspectRatioX / (width * crop.AspectRatioY));
        float ry = crop.IsStretched ? 1 : MathF.Min(1, width * crop.AspectRatioY / (height * crop.AspectRatioX));
        int px = (width - (int)(width * rx)) / 2, py = (height - (int)(height * ry)) / 2;
        return new Rect
        {
            SrcX0 = x0, SrcY0 = y0, SrcX1 = x1, SrcY1 = y1,
            DstX0 = state.InsetLeft + (crop.FlipX ? width - px : px),
            DstX1 = state.InsetLeft + (crop.FlipX ? px : width - px),
            DstY0 = state.InsetTop + (crop.FlipY ? py : height - py),
            DstY1 = state.InsetTop + (crop.FlipY ? height - py : py),
            TouchX = state.InsetLeft + px,
            TouchY = state.InsetTop + py,
            TouchWidth = width - 2 * px,
            TouchHeight = height - 2 * py,
            SwitchRegion = MathF.Abs(crop.AspectRatioX / crop.AspectRatioY - 16f / 9) < 0.001f,
        };
    }
}
