#nullable disable
using Ryujinx.Common.Logging;
using Ryujinx.Graphics.Nvdec.FFmpeg.H264;
using Ryujinx.Graphics.Video;
using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Graphics.Nvdec.Android
{
    // The native decoder owns DPB and output storage. Nvdec consumes this borrowed
    // I420 view synchronously in SurfaceWriter before the next Decode/Dispose.
    public sealed unsafe partial class AvcH264Decoder : IH264Decoder
    {
        private const string Lib = "s2arm_android";
        [StructLayout(LayoutKind.Sequential)]
        internal struct Config { public uint Abi, Size, Width, Height; }
        [StructLayout(LayoutKind.Sequential)]
        internal struct Diagnostic
        {
            public uint Abi, Size, Stage;
            public int Code, Status;
            public uint Error, Consumed, Decoded, Output, InputToken, OutputToken, Width, Height, Generation;
            public static Diagnostic New() => new() { Abi = 1, Size = (uint)sizeof(Diagnostic) };
        }
        [StructLayout(LayoutKind.Sequential)]
        internal struct NativePlane
        {
            public nint Data;
            public ulong Capacity;
            public uint Width, Height, Stride, Reserved;
        }
        [StructLayout(LayoutKind.Sequential)]
        internal struct View
        {
            public uint Abi, Size, Format, Progressive, Token, Generation;
            public NativePlane Y, U, V;
        }
        [LibraryImport(Lib)] private static partial int s2a_avc_create(in Config config, out nint handle, ref Diagnostic diagnostic);
        [LibraryImport(Lib)] private static partial int s2a_avc_decode(nint handle, byte* au, uint length, byte* sps, uint spsLength, byte* pps, uint ppsLength, uint token, ref Diagnostic diagnostic);
        [LibraryImport(Lib)] private static partial int s2a_avc_planes(nint handle, uint token, ref View view, ref Diagnostic diagnostic);
        [LibraryImport(Lib)] private static partial int s2a_avc_destroy(nint handle, ref Diagnostic diagnostic);
        [LibraryImport(Lib)] private static partial nint s2a_avc_provenance();

        private static readonly bool AbiLayoutValid = sizeof(Config) == 16 && sizeof(Diagnostic) == 56 && sizeof(NativePlane) == 32 && sizeof(View) == 120 && Marshal.OffsetOf<NativePlane>(nameof(NativePlane.Capacity)) == 8;
        // Must match HEADER_MAX in s2a_avc.c. The work buffer is larger than one
        // parameter set because both reconstructed sets are written back to back;
        // worst-case 224 scaling-list deltas take under 1 KiB, so 0x800 bounds the
        // writer and any oversize result is mapped to a red failure below.
        private const int HeaderMax = 0x200;
        private readonly byte[] _headers = new byte[0x800];
        private nint _handle;
        private uint _token;
        private AvcSurface _bound;
        private bool _failed, _disposed;
        private ulong _failures;
        public bool IsHardwareAccelerated => false;
        public ISurface CreateSurface(int width, int height) => new AvcSurface(width, height);

        // Nvdec's H.264 PictureInfo exposes no FMO/ASO fields: Convert() always
        // supplies NumSliceGroupsMinus1=0 and FmoAsoEnable=false. FMO/ASO is
        // therefore not claimed as a production preflight; only an in-band FMO
        // PPS is rejected, by the shim's PPS parser (see codecs/README.md).
        internal static bool Supported(ref H264PictureInfo info) =>
            info.ChromaFormatIdc == 1 && info.FrameMbsOnlyFlag && !info.FieldPicFlag &&
            !info.MbAdaptiveFrameFieldFlag &&
            (info.PicOrderCntType == 0 || info.PicOrderCntType == 2) &&
            info.Log2MaxFrameNumMinus4 <= 12 && info.Log2MaxPicOrderCntLsbMinus4 <= 12 &&
            info.NumRefFrames <= 16 && info.PicWidthInMbsMinus1 < 512 && info.PicHeightInMapUnitsMinus1 < 512 &&
            info.NumRefIdxL0ActiveMinus1 <= 31 && info.NumRefIdxL1ActiveMinus1 <= 31 &&
            info.WeightedBipredIdc <= 2 && info.PicInitQpMinus26 >= -26 && info.PicInitQpMinus26 <= 25 &&
            info.ChromaQpIndexOffset >= -12 && info.ChromaQpIndexOffset <= 12 &&
            info.SecondChromaQpIndexOffset >= -12 && info.SecondChromaQpIndexOffset <= 12;

        private bool Fail(string reason, Diagnostic diagnostic = default)
        {
            _failures++;
            if (!_failed)
            {
                Logger.Error?.Print(LogClass.Nvdec, $"【红】Nvdec H264 backend=libavc stage={diagnostic.Stage} reason={reason} rid={RuntimeInformation.RuntimeIdentifier} code={diagnostic.Code} status={diagnostic.Status} error=0x{diagnostic.Error:x} consumed={diagnostic.Consumed} decoded={diagnostic.Decoded} output={diagnostic.Output} token={diagnostic.InputToken}/{diagnostic.OutputToken} size={diagnostic.Width}x{diagnostic.Height}");
            }
            _failed = true;
            return false;
        }

        public bool Decode(ref H264PictureInfo info, ISurface output, ReadOnlySpan<byte> bitstream)
        {
            _bound?.Detach();
            _bound = null;
            if (_failed) { _failures++; return false; }
            if (_disposed || output is not AvcSurface surface || surface.Disposed || !Supported(ref info) || bitstream.IsEmpty)
            {
                return Fail("unsupported input or decoder/surface state");
            }
            try
            {
                int width = checked(((int)info.PicWidthInMbsMinus1 + 1) * 16);
                int height = checked(((int)info.PicHeightInMapUnitsMinus1 + 1) * 16);
                if (surface.Width != width || surface.Height != height) return Fail("requested surface dimensions");
                if (!AbiLayoutValid) return Fail("ABI layout");
                Diagnostic diagnostic = Diagnostic.New();
                if (_handle == 0)
                {
                    Config config = new() { Abi = 1, Size = (uint)sizeof(Config), Width = (uint)width, Height = (uint)height };
                    if (s2a_avc_create(in config, out _handle, ref diagnostic) != 0 || _handle == 0) return Fail("create", diagnostic);
                    // Keep the provenance marker in the final stripped ELF. This also
                    // detects an incompatible dynamic development library at runtime.
                    if (Marshal.PtrToStringUTF8(s2a_avc_provenance()) != "S2ARM_LIBAVC_d380d04a78c6c08702e36aca86d0fd4baee390f9") return Fail("source provenance");
                }
                Span<byte> headers = SpsAndPpsReconstruction.Reconstruct(ref info, _headers);
                int split = 0;
                for (int i = 4; i + 3 < headers.Length; i++)
                {
                    if (headers[i] == 0 && headers[i + 1] == 0 && headers[i + 2] == 1 && (headers[i + 3] & 31) == 8) { split = i; break; }
                }
                if (split == 0) return Fail("reconstructed parameter sets");
                if (split > HeaderMax || headers.Length - split > HeaderMax) return Fail("reconstructed parameter set length");
                uint token = unchecked(++_token);
                fixed (byte* data = bitstream, header = headers)
                {
                    if (s2a_avc_decode(_handle, data, checked((uint)bitstream.Length), header, (uint)split, header + split, (uint)(headers.Length - split), token, ref diagnostic) != 0) return Fail("decode", diagnostic);
                }
                View view = new() { Abi = 1, Size = (uint)sizeof(View) };
                if (s2a_avc_planes(_handle, token, ref view, ref diagnostic) != 0 || !surface.Attach(in view, token)) return Fail("output view", diagnostic);
                _bound = surface;
                return true;
            }
            catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException or OverflowException or OutOfMemoryException or IndexOutOfRangeException)
            {
                return Fail(error.GetType().Name);
            }
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _bound?.Detach(); _bound = null;
            nint handle = _handle; _handle = 0;
            if (handle == 0) return;
            try
            {
                Diagnostic diagnostic = Diagnostic.New();
                if (s2a_avc_destroy(handle, ref diagnostic) != 0) Fail("destroy", diagnostic);
            }
            catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException)
            {
                Fail(error.GetType().Name);
            }
        }
    }

    internal sealed class AvcSurface(int width, int height) : ISurface
    {
        private AvcH264Decoder.View _view;
        internal bool Disposed { get; private set; }
        public int Width { get; } = width;
        public int Height { get; } = height;
        public int Stride => checked((int)_view.Y.Stride);
        public int UvWidth => (Width + 1) / 2;
        public int UvHeight => (Height + 1) / 2;
        public int UvStride => checked((int)_view.U.Stride);
        public FrameField Field => FrameField.Progressive;
        public Plane YPlane => new(_view.Y.Data, checked((int)_view.Y.Capacity));
        public Plane UPlane => new(_view.U.Data, checked((int)_view.U.Capacity));
        public Plane VPlane => new(_view.V.Data, checked((int)_view.V.Capacity));
        private static bool Valid(in AvcH264Decoder.NativePlane p, int width, int height) =>
            p.Data != 0 && p.Width == width && p.Height == height && p.Stride >= p.Width && p.Stride <= int.MaxValue &&
            p.Capacity <= int.MaxValue && p.Capacity >= (ulong)(p.Height - 1) * p.Stride + p.Width;
        internal bool Attach(in AvcH264Decoder.View view, uint token)
        {
            if (Disposed || view.Abi != 1 || view.Size != 120 || view.Format != 1 || view.Progressive != 1 || view.Token != token ||
                !Valid(in view.Y, Width, Height) || !Valid(in view.U, UvWidth, UvHeight) || !Valid(in view.V, UvWidth, UvHeight) || view.U.Stride != view.V.Stride) return false;
            _view = view; return true;
        }
        internal void Detach() => _view = default;
        public void Dispose() { Detach(); Disposed = true; }
    }
}
