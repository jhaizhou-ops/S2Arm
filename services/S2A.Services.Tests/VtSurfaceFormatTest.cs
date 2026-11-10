// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Graphics.Nvdec.Apple;   // 平台例外：本用例只验苹果 VideoToolbox 解码器的出帧面（platform/apple/cs/video，审计 P2-198）；服务层单测只在 macOS 上跑
using System.Runtime.InteropServices;

namespace S2A.Services.Tests
{
    // 审计 P2-198：VideoToolbox 出帧不是 y420 三平面时，面原先打红后照样被当成解出来的一帧（Decode 回 true）。
    //   Attach 现在回 false、面保持空，Decode 据此走失败路径（丢会话、等 IDR、重复上一张好图）。
    // 期望（手写，不跑被测实现）：BGRA 单平面像素缓冲 → Attach 回 false，宽高仍是构造时的 0、Y 面地址 0；
    //   同尺寸 y420 三平面缓冲 → 回 true、宽高 = 64x32、Y 面地址非 0
    public static unsafe partial class Program
    {
        [DllImport("/System/Library/Frameworks/CoreVideo.framework/CoreVideo")]   // 平台例外：本用例只验苹果 VideoToolbox 解码器的出帧面（platform/apple/cs/video，审计 P2-198）；服务层单测只在 macOS 上跑
        private static extern int CVPixelBufferCreate(nint alloc, nint width, nint height, uint format, nint attrs, out nint buffer);

        [SvcCase]
        private static void VtSurfaceRejectsNonY420()
        {
            const uint Bgra = 0x42475241, Y420 = 0x79343230;   // 'BGRA'、'y420'
            Check("建 BGRA 像素缓冲", 0, CVPixelBufferCreate(0, 64, 32, Bgra, 0, out nint bgra));
            Check("建 y420 像素缓冲", 0, CVPixelBufferCreate(0, 64, 32, Y420, 0, out nint y420));
            bool strict = Red.Strict;
            Red.Strict = false;   // 格式不符那条是预期的红
            try
            {
                var s = new VideoToolboxSurface(0, 0);   // 平台例外：本用例只验苹果 VideoToolbox 解码器的出帧面（platform/apple/cs/video，审计 P2-198）；服务层单测只在 macOS 上跑
                Check("非 y420：Attach 回 false", false, s.Attach(bgra));
                Check("非 y420：面保持空（宽、Y 面地址）", "0/0", $"{s.Width}/{(long)s.YPlane.Pointer}");
                Check("y420 三平面：Attach 回 true", true, s.Attach(y420));
                Check("y420 三平面：宽高", "64x32", $"{s.Width}x{s.Height}");
                Check("y420 三平面：Y 面地址非 0", true, (long)s.YPlane.Pointer != 0);
            }
            finally
            {
                Red.Strict = strict;
            }
        }
    }
}
