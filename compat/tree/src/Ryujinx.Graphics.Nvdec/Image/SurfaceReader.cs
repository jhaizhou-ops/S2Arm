using Ryujinx.Common;
using Ryujinx.Graphics.Device;
using Ryujinx.Graphics.Texture;
using Ryujinx.Graphics.Video;
using System;
using System.Runtime.CompilerServices;
using System.Runtime.Intrinsics;
using System.Runtime.Intrinsics.Arm;
using System.Runtime.Intrinsics.X86;
using static Ryujinx.Graphics.Nvdec.Image.SurfaceCommon;

namespace Ryujinx.Graphics.Nvdec.Image
{
    static class SurfaceReader
    {
        // S2Arm: the SSE2 fast path below also serves ARM64 (AdvSimd ZIP1 / ZIP2 interleave exactly like
        // punpcklbw / punpckhbw). Upstream ran the per-pixel block-linear offset loop on ARM64; on Android
        // that loop was ~23% of the Nvdec thread's CPU in P4G's 1080p VP9 cutscenes.
        private static bool FastPath => Sse2.IsSupported || AdvSimd.Arm64.IsSupported;

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static Vector128<byte> UnpackLow(Vector128<byte> a, Vector128<byte> b)
            => Sse2.IsSupported ? Sse2.UnpackLow(a, b) : AdvSimd.Arm64.ZipLow(a, b);

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static Vector128<byte> UnpackHigh(Vector128<byte> a, Vector128<byte> b)
            => Sse2.IsSupported ? Sse2.UnpackHigh(a, b) : AdvSimd.Arm64.ZipHigh(a, b);

        public static void Read(DeviceMemoryManager mm, ISurface surface, uint lumaOffset, uint chromaOffset)
        {
            int width = surface.Width;
            int height = surface.Height;
            int stride = surface.Stride;

            ReadOnlySpan<byte> luma = mm.DeviceGetSpan(lumaOffset, GetBlockLinearSize(width, height, 1));

            ReadLuma(surface.YPlane.AsSpan(), luma, stride, width, height);

            int uvWidth = surface.UvWidth;
            int uvHeight = surface.UvHeight;
            int uvStride = surface.UvStride;

            ReadOnlySpan<byte> chroma = mm.DeviceGetSpan(chromaOffset, GetBlockLinearSize(uvWidth, uvHeight, 2));

            ReadChroma(surface.UPlane.AsSpan(), surface.VPlane.AsSpan(), chroma, uvStride, uvWidth, uvHeight);
        }

        private static void ReadLuma(Span<byte> dst, ReadOnlySpan<byte> src, int dstStride, int width, int height)
        {
            LayoutConverter.ConvertBlockLinearToLinear(dst, width, height, dstStride, 1, 2, src);
        }

        private unsafe static void ReadChroma(
            Span<byte> dstU,
            Span<byte> dstV,
            ReadOnlySpan<byte> src,
            int dstStride,
            int width,
            int height)
        {
            OffsetCalculator calc = new(width, height, 0, false, 2, 2);

            if (FastPath)
            {
                int strideTrunc64 = BitUtils.AlignDown(width * 2, 64);

                int outStrideGap = dstStride - width;

                fixed (byte* dstUPtr = dstU, dstVPtr = dstV, dataPtr = src)
                {
                    byte* uPtr = dstUPtr;
                    byte* vPtr = dstVPtr;

                    for (int y = 0; y < height; y++)
                    {
                        calc.SetY(y);

                        for (int x = 0; x < strideTrunc64; x += 64, uPtr += 32, vPtr += 32)
                        {
                            byte* offset = dataPtr + calc.GetOffsetWithLineOffset64(x);
                            byte* offset2 = offset + 0x20;
                            byte* offset3 = offset + 0x100;
                            byte* offset4 = offset + 0x120;

                            Vector128<byte> value = *(Vector128<byte>*)offset;
                            Vector128<byte> value2 = *(Vector128<byte>*)offset2;
                            Vector128<byte> value3 = *(Vector128<byte>*)offset3;
                            Vector128<byte> value4 = *(Vector128<byte>*)offset4;

                            Vector128<byte> u00 = UnpackLow(value, value2);
                            Vector128<byte> v00 = UnpackHigh(value, value2);
                            Vector128<byte> u01 = UnpackLow(value3, value4);
                            Vector128<byte> v01 = UnpackHigh(value3, value4);

                            Vector128<byte> u10 = UnpackLow(u00, v00);
                            Vector128<byte> v10 = UnpackHigh(u00, v00);
                            Vector128<byte> u11 = UnpackLow(u01, v01);
                            Vector128<byte> v11 = UnpackHigh(u01, v01);

                            Vector128<byte> u20 = UnpackLow(u10, v10);
                            Vector128<byte> v20 = UnpackHigh(u10, v10);
                            Vector128<byte> u21 = UnpackLow(u11, v11);
                            Vector128<byte> v21 = UnpackHigh(u11, v11);

                            Vector128<byte> u30 = UnpackLow(u20, v20);
                            Vector128<byte> v30 = UnpackHigh(u20, v20);
                            Vector128<byte> u31 = UnpackLow(u21, v21);
                            Vector128<byte> v31 = UnpackHigh(u21, v21);

                            *(Vector128<byte>*)uPtr = u30;
                            *(Vector128<byte>*)(uPtr + 16) = u31;
                            *(Vector128<byte>*)vPtr = v30;
                            *(Vector128<byte>*)(vPtr + 16) = v31;
                        }

                        for (int x = strideTrunc64 / 2; x < width; x++, uPtr++, vPtr++)
                        {
                            byte* offset = dataPtr + calc.GetOffset(x);

                            *uPtr = *offset;
                            *vPtr = *(offset + 1);
                        }

                        uPtr += outStrideGap;
                        vPtr += outStrideGap;
                    }
                }
            }
            else
            {
                for (int y = 0; y < height; y++)
                {
                    int dstBaseOffset = y * dstStride;

                    calc.SetY(y);

                    for (int x = 0; x < width; x++)
                    {
                        int srcOffset = calc.GetOffset(x);

                        dstU[dstBaseOffset + x] = src[srcOffset];
                        dstV[dstBaseOffset + x] = src[srcOffset + 1];
                    }
                }
            }
        }
    }
}
