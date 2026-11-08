// S2A: 本文件为 S2A 新增（非 Ryujinx 原版）。
using System;
using static Ryujinx.Graphics.Texture.BlockLinearConstants;

namespace Ryujinx.Graphics.Texture
{
    /// <summary>
    /// S2A 部分回写（帧率能耗线 10-23）：游戏只读 GPU 渲染目标的一个 4 KB 子页时，只把这一段从线性宿主数据转成块线性写回，
    /// 不整张转换（塞尔达 1920×1080 每次 8.4 MB、约 6 ms）。只处理单层、单级、块高 Z 为 1、GobBlocksInTileX 为 1、非压缩的 2D 块线性贴图；
    /// 偏移与 LayoutConverter.ConvertLinearToBlockLinear 第 0 级完全一致（含小高度时块高减半、宿主行距 4 字节对齐），单测逐字节对照。
    /// </summary>
    public static class S2APartialLayout
    {
        /// <summary>第 0 级实际块高（GOB 数）：同 ConvertLinearToBlockLinear 的减半规则</summary>
        public static int MipGobBlocksInY(int height, int gobBlocksInY)
        {
            int g = gobBlocksInY;

            while (height <= (g >> 1) * GobHeight && g != 1)
            {
                g >>= 1;
            }

            return g;
        }

        /// <summary>宿主线性数据行距（字节）：同 ConvertLinearToBlockLinear（4 字节对齐）</summary>
        public static int HostStride(int width, int bpp) => (width * bpp + LayoutConverter.HostStrideAlignment - 1) & ~(LayoutConverter.HostStrideAlignment - 1);

        /// <summary>块线性字节区间 [off, off+len)（512 字节对齐）用到的源行范围 [rowMin, rowMax]；没有落在图像内的行返回 false</summary>
        public static bool RowRange(int off, int len, int width, int height, int bpp, int gobBlocksInY, out int rowMin, out int rowMax)
        {
            int gobH = MipGobBlocksInY(height, gobBlocksInY);
            int blocksPerRow = AlignUp(width, GobStride / bpp) * bpp / GobStride;
            rowMin = int.MaxValue;
            rowMax = -1;

            for (int g = off / GobSize; g < (off + len) / GobSize; g++)
            {
                int y0 = GobY(g, blocksPerRow, gobH) * GobHeight;

                if (y0 >= height)
                {
                    continue;
                }

                rowMin = Math.Min(rowMin, y0);
                rowMax = Math.Max(rowMax, Math.Min(height - 1, y0 + GobHeight - 1));
            }

            return rowMax >= 0;
        }

        /// <summary>
        /// 把线性源（从第 srcRow0 行起、行距 srcStride）里落在块线性区间 [off, off+dst.Length) 的像素写进 dst（dst[0] 对应偏移 off）。
        /// 图像外的填充字节不动。off、dst.Length 须 512 字节对齐；宽 × 每像素字节须是 16 的倍数（调用方先判）
        /// </summary>
        public static void Write(Span<byte> dst, int off, int width, int height, int bpp, int gobBlocksInY, ReadOnlySpan<byte> src, int srcRow0, int srcStride)
        {
            int gobH = MipGobBlocksInY(height, gobBlocksInY);
            int blocksPerRow = AlignUp(width, GobStride / bpp) * bpp / GobStride;
            int rowBytes = width * bpp;

            for (int g = off / GobSize; g < (off + dst.Length) / GobSize; g++)
            {
                int rem = g % (blocksPerRow * gobH);
                int x0 = rem / gobH * GobStride;
                int y0 = GobY(g, blocksPerRow, gobH) * GobHeight;
                int gobBase = g * GobSize - off;

                for (int y = 0; y < GobHeight && y0 + y < height; y++)
                {
                    for (int xs = 0; xs < GobStride && x0 + xs < rowBytes; xs += 16)
                    {
                        int d = gobBase + (xs >> 5 << 8) + (y >> 1 << 6) + ((xs & 31) >> 4 << 5) + ((y & 1) << 4);
                        src.Slice((y0 + y - srcRow0) * srcStride + x0 + xs, 16).CopyTo(dst.Slice(d, 16));
                    }
                }
            }
        }

        private static int GobY(int g, int blocksPerRow, int gobH)
        {
            int blockRowGobs = blocksPerRow * gobH;

            return g / blockRowGobs * gobH + g % blockRowGobs % gobH;
        }

        private static int AlignUp(int v, int a) => (v + a - 1) / a * a;
    }
}
