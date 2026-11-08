using Ryujinx.Common;
using Ryujinx.Graphics.Device;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu.Engine.Types;
using Ryujinx.Graphics.Gpu.Image;
using Ryujinx.Graphics.Gpu.Memory;
using Ryujinx.Graphics.Texture;
using Ryujinx.Memory;
using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Intrinsics;

namespace Ryujinx.Graphics.Gpu.Engine.Twod
{
    /// <summary>
    /// Represents a 2D engine class.
    /// </summary>
    class TwodClass : IDeviceState
    {
        private readonly GpuChannel _channel;
        private readonly DeviceState<TwodClassState> _state;

        /// <summary>
        /// Creates a new instance of the 2D engine class.
        /// </summary>
        /// <param name="channel">The channel that will make use of the engine</param>
        public TwodClass(GpuChannel channel)
        {
            _channel = channel;
            _state = new DeviceState<TwodClassState>(new Dictionary<string, RwCallback>
            {
                { nameof(TwodClassState.PixelsFromMemorySrcY0Int), new RwCallback(PixelsFromMemorySrcY0Int, null) },
            });
        }

        /// <summary>
        /// Reads data from the class registers.
        /// </summary>
        /// <param name="offset">Register byte offset</param>
        /// <returns>Data at the specified offset</returns>
        public int Read(int offset) => _state.Read(offset);

        /// <summary>
        /// Writes data to the class registers.
        /// </summary>
        /// <param name="offset">Register byte offset</param>
        /// <param name="data">Data to be written</param>
        public void Write(int offset, int data) => _state.Write(offset, data);

        private int _s2aGpuDstLogged;

        /// <summary>
        /// Determines if data is compatible between the source and destination texture.
        /// The two textures must have the same size, layout, and bytes per pixel.
        /// </summary>
        /// <param name="lhs">Info for the first texture</param>
        /// <param name="rhs">Info for the second texture</param>
        /// <param name="lhsFormat">Format of the first texture</param>
        /// <param name="rhsFormat">Format of the second texture</param>
        /// <returns>True if the data is compatible, false otherwise</returns>
        private static bool IsDataCompatible(TwodTexture lhs, TwodTexture rhs, FormatInfo lhsFormat, FormatInfo rhsFormat)
        {
            if (lhsFormat.BytesPerPixel != rhsFormat.BytesPerPixel ||
                lhs.Height != rhs.Height ||
                lhs.Depth != rhs.Depth ||
                lhs.LinearLayout != rhs.LinearLayout ||
                lhs.MemoryLayout.Packed != rhs.MemoryLayout.Packed)
            {
                return false;
            }

            if (lhs.LinearLayout)
            {
                return lhs.Stride == rhs.Stride;
            }
            else
            {
                return lhs.Width == rhs.Width;
            }
        }

        /// <summary>
        /// Determine if the given region covers the full texture, also considering width alignment.
        /// </summary>
        /// <param name="texture">The texture to check</param>
        /// <param name="formatInfo"></param>
        /// <param name="x1">Region start x</param>
        /// <param name="y1">Region start y</param>
        /// <param name="x2">Region end x</param>
        /// <param name="y2">Region end y</param>
        /// <returns>True if the region covers the full texture, false otherwise</returns>
        private static bool IsCopyRegionComplete(TwodTexture texture, FormatInfo formatInfo, int x1, int y1, int x2, int y2)
        {
            if (x1 != 0 || y1 != 0 || y2 != texture.Height)
            {
                return false;
            }

            int width;
            int widthAlignment;

            if (texture.LinearLayout)
            {
                widthAlignment = 1;
                width = texture.Stride / formatInfo.BytesPerPixel;
            }
            else
            {
                widthAlignment = Constants.GobAlignment / formatInfo.BytesPerPixel;
                width = texture.Width;
            }

            return width == BitUtils.AlignUp(x2, widthAlignment);
        }

        /// <summary>
        /// Performs a full data copy between two textures, reading and writing guest memory directly.
        /// The textures must have a matching layout, size, and bytes per pixel.
        /// </summary>
        /// <param name="src">The source texture</param>
        /// <param name="dst">The destination texture</param>
        /// <param name="w">Copy width</param>
        /// <param name="h">Copy height</param>
        /// <param name="bpp">Bytes per pixel</param>
        private void UnscaledFullCopy(TwodTexture src, TwodTexture dst, int w, int h, int bpp)
        {
            OffsetCalculator srcCalculator = new(
                w,
                h,
                src.Stride,
                src.LinearLayout,
                src.MemoryLayout.UnpackGobBlocksInY(),
                src.MemoryLayout.UnpackGobBlocksInZ(),
                bpp);

            (int _, int srcSize) = srcCalculator.GetRectangleRange(0, 0, w, h);

            MemoryManager memoryManager = _channel.MemoryManager;

            ulong srcGpuVa = src.Address.Pack();
            ulong dstGpuVa = dst.Address.Pack();

            ReadOnlySpan<byte> srcSpan = memoryManager.GetSpan(srcGpuVa, srcSize, true);

            int width;
            int height = src.Height;
            if (src.LinearLayout)
            {
                width = src.Stride / bpp;
            }
            else
            {
                width = src.Width;
            }

            // If the copy is not equal to the width and height of the texture, we will need to copy partially.
            // It's worth noting that it has already been established that the src and dst are the same size.

            if (w == width && h == height)
            {
                memoryManager.Write(dstGpuVa, srcSpan);
            }
            else
            {
                using WritableRegion dstRegion = memoryManager.GetWritableRegion(dstGpuVa, srcSize, true);
                Span<byte> dstSpan = dstRegion.Memory.Span;

                if (src.LinearLayout)
                {
                    int stride = src.Stride;
                    int offset = 0;
                    int lineSize = width * bpp;

                    for (int y = 0; y < height; y++)
                    {
                        srcSpan.Slice(offset, lineSize).CopyTo(dstSpan[offset..]);

                        offset += stride;
                    }
                }
                else
                {
                    // Copy with the block linear layout in mind.
                    // Recreate the offset calculate with bpp 1 for copy.

                    int stride = w * bpp;

                    srcCalculator = new OffsetCalculator(
                        stride,
                        h,
                        0,
                        false,
                        src.MemoryLayout.UnpackGobBlocksInY(),
                        src.MemoryLayout.UnpackGobBlocksInZ(),
                        1);

                    int strideTrunc = BitUtils.AlignDown(stride, 16);

                    ReadOnlySpan<Vector128<byte>> srcVec = MemoryMarshal.Cast<byte, Vector128<byte>>(srcSpan);
                    Span<Vector128<byte>> dstVec = MemoryMarshal.Cast<byte, Vector128<byte>>(dstSpan);

                    for (int y = 0; y < h; y++)
                    {
                        int x = 0;

                        srcCalculator.SetY(y);

                        for (; x < strideTrunc; x += 16)
                        {
                            int offset = srcCalculator.GetOffset(x) >> 4;

                            dstVec[offset] = srcVec[offset];
                        }

                        for (; x < stride; x++)
                        {
                            int offset = srcCalculator.GetOffset(x);

                            dstSpan[offset] = srcSpan[offset];
                        }
                    }
                }
            }
        }

        /// <summary>
        /// Performs the blit operation, triggered by the register write.
        /// </summary>
        /// <param name="argument">Method call argument</param>
        private void PixelsFromMemorySrcY0Int(int argument)
        {
            MemoryManager memoryManager = _channel.MemoryManager;

            TwodTexture dstCopyTexture = Unsafe.As<uint, TwodTexture>(ref _state.State.SetDstFormat);
            TwodTexture srcCopyTexture = Unsafe.As<uint, TwodTexture>(ref _state.State.SetSrcFormat);

            long srcX = ((long)_state.State.SetPixelsFromMemorySrcX0Int << 32) | (long)(ulong)_state.State.SetPixelsFromMemorySrcX0Frac;
            long srcY = ((long)_state.State.PixelsFromMemorySrcY0Int << 32) | (long)(ulong)_state.State.SetPixelsFromMemorySrcY0Frac;

            long duDx = ((long)_state.State.SetPixelsFromMemoryDuDxInt << 32) | (long)(ulong)_state.State.SetPixelsFromMemoryDuDxFrac;
            long dvDy = ((long)_state.State.SetPixelsFromMemoryDvDyInt << 32) | (long)(ulong)_state.State.SetPixelsFromMemoryDvDyFrac;

            bool originCorner = _state.State.SetPixelsFromMemorySampleModeOrigin == SetPixelsFromMemorySampleModeOrigin.Corner;

            if (originCorner)
            {
                // If the origin is corner, it is assumed that the guest API
                // is manually centering the origin by adding a offset to the
                // source region X/Y coordinates.
                // Here we attempt to remove such offset to ensure we have the correct region.
                // The offset is calculated as FactorXY / 2.0, where FactorXY = SrcXY / DstXY,
                // so we do the same here by dividing the fixed point value by 2, while
                // throwing away the fractional part to avoid rounding errors.
                srcX -= (duDx >> 33) << 32;
                srcY -= (dvDy >> 33) << 32;
            }

            int srcX1 = (int)(srcX >> 32);
            int srcY1 = (int)(srcY >> 32);

            int srcX2 = srcX1 + (int)((duDx * _state.State.SetPixelsFromMemoryDstWidth + uint.MaxValue) >> 32);
            int srcY2 = srcY1 + (int)((dvDy * _state.State.SetPixelsFromMemoryDstHeight + uint.MaxValue) >> 32);

            int dstX1 = (int)_state.State.SetPixelsFromMemoryDstX0;
            int dstY1 = (int)_state.State.SetPixelsFromMemoryDstY0;

            int dstX2 = dstX1 + (int)_state.State.SetPixelsFromMemoryDstWidth;
            int dstY2 = dstY1 + (int)_state.State.SetPixelsFromMemoryDstHeight;

            // The source and destination textures should at least be as big as the region being requested.
            // The hints will only resize within alignment constraints, so out of bound copies won't resize in most cases.
            Size srcHint = new(srcX2, srcY2, 1);
            Size dstHint = new(dstX2, dstY2, 1);

            FormatInfo srcCopyTextureFormat = srcCopyTexture.Format.Convert();

            int srcWidthAligned = srcCopyTexture.Stride / srcCopyTextureFormat.BytesPerPixel;

            ulong offset = 0;

            // For an out of bounds copy, we must ensure that the copy wraps to the next line,
            // so for a copy from a 64x64 texture, in the region [32, 96[, there are 32 pixels that are
            // outside the bounds of the texture. We fill the destination with the first 32 pixels
            // of the next line on the source texture.
            // This can be done by simply adding an offset to the texture address, so that the initial
            // gap is skipped and the copy is inside bounds again.
            // This is required by the proprietary guest OpenGL driver.
            if (srcCopyTexture.LinearLayout && srcCopyTexture.Width == srcX2 && srcX2 > srcWidthAligned && srcX1 > 0)
            {
                offset = (ulong)(srcX1 * srcCopyTextureFormat.BytesPerPixel);
                srcCopyTexture.Width -= srcX1;
                srcX2 -= srcX1;
                srcX1 = 0;
            }

            FormatInfo dstCopyTextureFormat = dstCopyTexture.Format.Convert();

            bool canDirectCopy = GraphicsConfig.Fast2DCopy &&
                srcX2 == dstX2 && srcY2 == dstY2 &&
                IsDataCompatible(srcCopyTexture, dstCopyTexture, srcCopyTextureFormat, dstCopyTextureFormat) &&
                IsCopyRegionComplete(srcCopyTexture, srcCopyTextureFormat, srcX1, srcY1, srcX2, srcY2) &&
                IsCopyRegionComplete(dstCopyTexture, dstCopyTextureFormat, dstX1, dstY1, dstX2, dstY2);

            // S2A：目标内存上有被 GPU 改过、还没回写的贴图时不走 CPU 直拷——CPU 直写会先触发那张贴图的回写（GPU 线程经渲染线程提交在录命令、
            // 等 GPU 全部做完、再读回整张贴图），改走下面的 GPU 拷贝（与 Fast2DCopy 关闭时同一条上游路径），数据留在 GPU 上。
            // 10-22 帧率能耗线：暗黑2 每帧一次 2D 引擎整面拷贝写进 GPU 刚画过的 256×256×4 D16 贴图所在内存，渲染线程每帧等满一整帧 GPU 工作
            //（Mac 读回阻塞 2.9–4.0 秒 / 60 秒、真机 20 秒 / 60 秒）
            if (canDirectCopy)
            {
                OffsetCalculator dstCalculator = new(
                    srcX2,
                    srcY2,
                    dstCopyTexture.Stride,
                    dstCopyTexture.LinearLayout,
                    dstCopyTexture.MemoryLayout.UnpackGobBlocksInY(),
                    dstCopyTexture.MemoryLayout.UnpackGobBlocksInZ(),
                    dstCopyTextureFormat.BytesPerPixel);

                (int _, int dstSize) = dstCalculator.GetRectangleRange(0, 0, srcX2, srcY2);

                if (memoryManager.Physical.TextureCache.S2AHasGpuModified(memoryManager.GetPhysicalRegions(dstCopyTexture.Address.Pack(), (ulong)dstSize)))
                {
                    canDirectCopy = false;

                    if (_s2aGpuDstLogged < 4)
                    {
                        _s2aGpuDstLogged++;
                        Console.Error.WriteLine($"[gpu] 2D 引擎整面拷贝：目标内存上有 GPU 改过的贴图，改走 GPU 拷贝（第 {_s2aGpuDstLogged} 次）：源格式 {srcCopyTexture.Format} 目标格式 {dstCopyTexture.Format} {srcX2}×{srcY2}；" +
                            memoryManager.Physical.TextureCache.S2ADescribeOverlaps(memoryManager.GetPhysicalRegions(dstCopyTexture.Address.Pack(), (ulong)dstSize)));
                    }
                }
            }

            // We can only allow aliasing of color formats as depth if the source and destination textures
            // are the same, as we can't blit between different depth formats.
            bool srcDepthAlias = srcCopyTexture.Format == dstCopyTexture.Format;

            long s2aA = S2AAllocTrace.Mark();   // S2A：渲染线程分配拆账（2D 拷贝分段 0x40_0019–0x40_001c）
            Image.Texture srcTexture = memoryManager.Physical.TextureCache.FindOrCreateTexture(
                memoryManager,
                srcCopyTexture,
                offset,
                srcCopyTextureFormat,
                srcDepthAlias,
                !canDirectCopy,
                false,
                srcHint);
            S2AAllocTrace.Step(0x40_0019, ref s2aA);

            if (srcTexture == null)
            {
                if (canDirectCopy)
                {
                    // Directly copy the data on CPU.
                    UnscaledFullCopy(srcCopyTexture, dstCopyTexture, srcX2, srcY2, srcCopyTextureFormat.BytesPerPixel);
                }

                return;
            }

            memoryManager.Physical.TextureCache.Lift(srcTexture);
            S2AAllocTrace.Step(0x40_001a, ref s2aA);

            // When the source texture that was found has a depth format,
            // we must enforce the target texture also has a depth format,
            // as copies between depth and color formats are not allowed.
            // For depth blit, the destination texture format should always match exactly.

            if (srcTexture.Format.IsDepthOrStencil)
            {
                dstCopyTextureFormat = srcTexture.Info.FormatInfo;
            }
            else
            {
                dstCopyTextureFormat = dstCopyTexture.Format.Convert();
            }

            Image.Texture dstTexture = memoryManager.Physical.TextureCache.FindOrCreateTexture(
                memoryManager,
                dstCopyTexture,
                0,
                dstCopyTextureFormat,
                depthAlias: false,
                shouldCreate: true,
                srcTexture.ScaleMode == TextureScaleMode.Scaled,
                dstHint);
            S2AAllocTrace.Step(0x40_001b, ref s2aA);

            if (dstTexture == null)
            {
                return;
            }

            if (srcTexture.Info.Samples > 1 || dstTexture.Info.Samples > 1)
            {
                srcTexture.PropagateScale(dstTexture);
            }

            float scale = srcTexture.ScaleFactor;
            float dstScale = dstTexture.ScaleFactor;

            Extents2D srcRegion = new(
                (int)Math.Ceiling(scale * (srcX1 / srcTexture.Info.SamplesInX)),
                (int)Math.Ceiling(scale * (srcY1 / srcTexture.Info.SamplesInY)),
                (int)Math.Ceiling(scale * (srcX2 / srcTexture.Info.SamplesInX)),
                (int)Math.Ceiling(scale * (srcY2 / srcTexture.Info.SamplesInY)));

            Extents2D dstRegion = new(
                (int)Math.Ceiling(dstScale * (dstX1 / dstTexture.Info.SamplesInX)),
                (int)Math.Ceiling(dstScale * (dstY1 / dstTexture.Info.SamplesInY)),
                (int)Math.Ceiling(dstScale * (dstX2 / dstTexture.Info.SamplesInX)),
                (int)Math.Ceiling(dstScale * (dstY2 / dstTexture.Info.SamplesInY)));

            bool linearFilter = _state.State.SetPixelsFromMemorySampleModeFilter == SetPixelsFromMemorySampleModeFilter.Bilinear;

            srcTexture.HostTexture.CopyTo(dstTexture.HostTexture, srcRegion, dstRegion, linearFilter);

            dstTexture.SignalModified();
            S2AAllocTrace.Step(0x40_001c, ref s2aA);
        }
    }
}
