using Ryujinx.Common.Logging;
using Ryujinx.Graphics.Video;
using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Graphics.Nvdec.Vpx
{
    // S2Arm：VP8 走 libvpx（静态链进宿主，services/vpx：libvpx + C 垫片 s2a_vp8.c），不带 FFmpeg（暗黑2 片头是 VP8，原先缺 libavutil 起局即崩）。
    // 帧头补法同 FFmpeg 版（Nvdec 只给出压缩数据，未压缩帧头由 PictureInfo 还原）；参考帧由 libvpx 自己管。
    // 输出面直接引用 libvpx 本帧的三个平面：Vp8Decoder 解完立即 SurfaceWriter 回写，下次解码前不再使用。
    public sealed unsafe partial class VpxVp8Decoder : IVp8Decoder
    {
        private const string Lib = "s2a_vpx";

        [LibraryImport(Lib)] private static partial nint s2a_vp8_open();
        [LibraryImport(Lib)] private static partial int s2a_vp8_decode(nint h, byte* data, uint len, byte** planes, int* strides, int* wh);
        [LibraryImport(Lib)] private static partial void s2a_vp8_close(nint h);

        private nint _handle;
        private byte[] _frame = new byte[0x10000];

        public bool IsHardwareAccelerated => false;

        public ISurface CreateSurface(int width, int height) => new VpxSurface(width, height);

        public bool Decode(ref Vp8PictureInfo pictureInfo, ISurface output, ReadOnlySpan<byte> bitstream)
        {
            if (_handle == 0)
            {
                _handle = s2a_vp8_open();

                if (_handle == 0)
                {
                    Logger.Error?.Print(LogClass.Nvdec, "libvpx：VP8 解码器打不开");
                    return false;
                }
            }

            int uncompHeaderSize = pictureInfo.KeyFrame ? 10 : 3;
            int len = bitstream.Length + uncompHeaderSize;

            if (_frame.Length < len)
            {
                _frame = new byte[len * 2];
            }

            Span<byte> frame = _frame.AsSpan(0, len);
            frame[..uncompHeaderSize].Clear();

            uint firstPartSizeShifted = pictureInfo.FirstPartSize << 5;

            frame[0] = (byte)(pictureInfo.KeyFrame ? 0 : 1);
            frame[0] |= (byte)((pictureInfo.Version & 7) << 1);
            frame[0] |= 1 << 4;
            frame[0] |= (byte)firstPartSizeShifted;
            frame[1] |= (byte)(firstPartSizeShifted >> 8);
            frame[2] |= (byte)(firstPartSizeShifted >> 16);

            if (pictureInfo.KeyFrame)
            {
                frame[3] = 0x9d;
                frame[4] = 0x01;
                frame[5] = 0x2a;
                frame[6] = (byte)pictureInfo.FrameWidth;
                frame[7] = (byte)((pictureInfo.FrameWidth >> 8) & 0x3F);
                frame[8] = (byte)pictureInfo.FrameHeight;
                frame[9] = (byte)((pictureInfo.FrameHeight >> 8) & 0x3F);
            }

            bitstream.CopyTo(frame[uncompHeaderSize..]);

            byte** planes = stackalloc byte*[3];
            int* strides = stackalloc int[3];
            int* wh = stackalloc int[2];
            int rc;

            fixed (byte* p = frame)
            {
                rc = s2a_vp8_decode(_handle, p, (uint)len, planes, strides, wh);
            }

            if (rc != 0)
            {
                if (rc < 0)
                {
                    Logger.Error?.Print(LogClass.Nvdec, $"libvpx：VP8 解码失败（{len} 字节，关键帧 {pictureInfo.KeyFrame}）");
                }

                return false;
            }

            ((VpxSurface)output).Attach(planes[0], planes[1], planes[2], strides[0], strides[1], wh[0], wh[1]);
            return true;
        }

        public void Dispose()
        {
            s2a_vp8_close(_handle);
            _handle = 0;
        }
    }

    sealed unsafe class VpxSurface : ISurface
    {
        private byte* _y, _u, _v;
        private int _stride, _uvStride;

        public VpxSurface(int width, int height)
        {
            Width = width;
            Height = height;
        }

        public Plane YPlane => new((nint)_y, _stride * Height);
        public Plane UPlane => new((nint)_u, _uvStride * UvHeight);
        public Plane VPlane => new((nint)_v, _uvStride * UvHeight);

        public FrameField Field => FrameField.Progressive;

        public int Width { get; private set; }
        public int Height { get; private set; }
        public int Stride => _stride;
        public int UvWidth => (Width + 1) >> 1;
        public int UvHeight => (Height + 1) >> 1;
        public int UvStride => _uvStride;

        public void Attach(byte* y, byte* u, byte* v, int stride, int uvStride, int width, int height)
        {
            _y = y;
            _u = u;
            _v = v;
            _stride = stride;
            _uvStride = uvStride;
            Width = width;
            Height = height;
        }

        public void Dispose()
        {
        }
    }
}
