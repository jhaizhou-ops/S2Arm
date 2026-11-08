// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Runtime.InteropServices;

namespace S2A.Android.Aot
{
    internal static unsafe class AndroidScreenshotEncoder
    {
        [DllImport("s2arm_android", EntryPoint = "s2a_android_encode_jpeg")]
        private static extern int EncodeNative(byte* rgba, ulong bytes, int width, int height, int quality,
            out nint jpeg, out ulong length);
        [DllImport("s2arm_android", EntryPoint = "s2a_android_free_jpeg")]
        private static extern void FreeNative(nint jpeg);

        internal static byte[] Encode(ReadOnlySpan<byte> rgba, int width, int height, int quality)
        {
            nint jpeg = 0;
            try
            {
                int error;
                ulong length;
                fixed (byte* pixels = rgba)
                    error = EncodeNative(pixels, (ulong)rgba.Length, width, height, quality, out jpeg, out length);
                if (error != 0) throw new InvalidOperationException($"Android screenshot JPEG encoder failed: {error}");
                if (jpeg == 0 || length < 4 || length > 64 * 1024 * 1024)
                    throw new InvalidOperationException("Android screenshot JPEG encoder returned invalid storage");
                byte[] result = new byte[checked((int)length)];
                Marshal.Copy(jpeg, result, 0, result.Length);
                return result;
            }
            finally
            {
                if (jpeg != 0) FreeNative(jpeg);
            }
        }
    }
}
