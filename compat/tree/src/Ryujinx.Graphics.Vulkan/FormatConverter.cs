using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Graphics.Vulkan
{
    class FormatConverter
    {
        // S2Arm：D24S8 在没有 D24 的设备（MoltenVK）上换成 D32FloatS8Uint 时，缓冲 ↔ 图像拷贝只拷深度面（TextureView.CopyFromOrToBuffer 的
        // 深度 / 模板图只取 DepthBit），Vulkan 深度面是紧排 float（4 字节 / 像素），与客体 D24S8 打包数据一一对应、逐像素同位置。
        // 原实现按「float 深度 + 模板」交错 8 字节转：上传把交错数据当紧排拷进深度面（隔点是模板），读回又两两配对，深度错位、后半张全 0。
        // 模板不经这条路（深度面拷贝不带模板）：上传丢模板、读回模板记 0。换算用 double：float 在 [0.5, 1) 的间距 2^-24 略小于 D24 一级 1/0xffffff，
        // 双精度除、就近取 float，再双精度乘回取整，误差 ≤ 2^-25 × 0xffffff < 0.5，往返逐值不变（单精度乘会差 1 级）。
        public static void ConvertD24S8ToD32FS8(Span<byte> output, ReadOnlySpan<byte> input)
        {
            Span<uint> outputUint = MemoryMarshal.Cast<byte, uint>(output);
            ReadOnlySpan<uint> inputUint = MemoryMarshal.Cast<byte, uint>(input);

            int n = Math.Min(inputUint.Length, outputUint.Length);

            for (int i = 0; i < n; i++)
            {
                outputUint[i] = (uint)BitConverter.SingleToInt32Bits((float)((inputUint[i] >> 8) / (double)0xffffff));
            }

            outputUint[n..].Clear();
        }

        public static void ConvertD32FS8ToD24S8(Span<byte> output, ReadOnlySpan<byte> input)
        {
            Span<uint> outputUint = MemoryMarshal.Cast<byte, uint>(output);
            ReadOnlySpan<uint> inputUint = MemoryMarshal.Cast<byte, uint>(input);

            int n = Math.Min(inputUint.Length, outputUint.Length);

            for (int i = 0; i < n; i++)
            {
                float depth = BitConverter.Int32BitsToSingle((int)inputUint[i]);
                outputUint[i] = (uint)Math.Clamp(Math.Round(depth * (double)0xffffff), 0.0, 0xffffff) << 8;
            }
        }
    }
}
