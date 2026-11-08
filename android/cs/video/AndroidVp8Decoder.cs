#nullable disable
using Ryujinx.Common.Logging;
using Ryujinx.Graphics.Video;
using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Graphics.Nvdec.Android
{
    // Android failure boundary only. Apple keeps the existing Vpx implementation.
    internal sealed class AndroidVp8Decoder : IVp8Decoder
    {
        private readonly Vpx.VpxVp8Decoder _inner = new();
        private bool _failed, _disposed;
        public bool IsHardwareAccelerated => false;
        public ISurface CreateSurface(int width, int height) => _inner.CreateSurface(width, height);
        private bool Fail(string reason)
        {
            if (!_failed) Logger.Error?.Print(LogClass.Nvdec, $"【红】Nvdec VP8 backend=libvpx stage=decode reason={reason} rid={RuntimeInformation.RuntimeIdentifier}");
            _failed = true; return false;
        }
        public bool Decode(ref Vp8PictureInfo info, ISurface output, ReadOnlySpan<byte> bitstream)
        {
            if (_failed) return false;
            if (_disposed) return Fail("disposed");
            try { return _inner.Decode(ref info, output, bitstream) || Fail("decode returned false"); }
            catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException or OverflowException or OutOfMemoryException) { return Fail(error.GetType().Name); }
        }
        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            try { _inner.Dispose(); }
            catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException) { Fail(error.GetType().Name); }
        }
    }
}
