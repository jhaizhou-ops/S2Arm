// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace S2A.Apple.Capture
{
    // 游戏存相册截图（caps:su SaveScreenShotEx0/1/2 → Ryujinx.HLE ScreenshotEncoding）的苹果 JPEG 编码器：ImageIO（public.jpeg），Mac / iOS 同一份。
    //   苹果宿主是 NativeAOT 静态链接，不带 libSkiaSharp.dylib，原先缺省的 Skia 编码器一调就 DllNotFoundException（Zumba 普查红「服务调用异常 svc 0x21」）。
    //   系统框架按绝对路径 LibraryImport（同 video/VideoToolboxH264Decoder.cs）：运行时经 dlopen 取系统共享缓存里的框架，Mac / iOS 都不用改链接参数。
    // 输入：紧排 RGBA8888、首行在上（ScreenshotEncoding.Encode 已核尺寸 / 质量 / 长度）；alpha 不进 JPEG（kCGImageAlphaNoneSkipLast，按 RGB 原值编，同游戏画面不透明）
    public static unsafe partial class AppleScreenshotEncoder
    {
        // 苹果装配（services/aot/Compose.cs；服务层单测宿主同样）在 Host.Boot 之前登记
        public static void Register() => S2A.Services.Exports.ScreenshotEncoder = Encode;

        public static byte[] Encode(ReadOnlySpan<byte> rgba, int width, int height, int quality)
        {
            if (width <= 0 || height <= 0 || quality < 0 || quality > 100 || (long)width * height * 4 != rgba.Length)
                throw new ArgumentException("Invalid packed RGBA screenshot");
            nint data = 0, dest = 0, provider = 0, image = 0, options = 0, number = 0;
            int released = 0;
            try
            {
                fixed (byte* pixels = rgba)
                {
                    // 像素直接借给 CGDataProvider（不拷）：释放回调证明 ImageIO 用完不再留引用，再出 fixed
                    provider = CG.CGDataProviderCreateWithData(&released, pixels, (nuint)rgba.Length, &OnProviderRelease);
                    if (provider == 0) throw new InvalidOperationException("CGDataProviderCreateWithData failed");
                    image = CG.CGImageCreate((nuint)width, (nuint)height, 8, 32, (nuint)width * 4, CG.SRGB,
                        CG.ImageAlphaNoneSkipLast, provider, null, 0, 0);
                    if (image == 0) throw new InvalidOperationException("CGImageCreate failed");
                    data = CF.CFDataCreateMutable(0, 0);
                    dest = data == 0 ? 0 : IO.CGImageDestinationCreateWithData(data, IO.JpegType, 1, 0);
                    if (dest == 0) throw new InvalidOperationException("CGImageDestinationCreateWithData(public.jpeg) failed");
                    double q = quality / 100.0;
                    number = CF.CFNumberCreate(0, CF.NumberFloat64Type, &q);
                    nint key = IO.LossyCompressionQuality, value = number;
                    options = CF.CFDictionaryCreate(0, &key, &value, 1, CF.TypeDictionaryKeyCallBacks, CF.TypeDictionaryValueCallBacks);
                    if (number == 0 || options == 0) throw new InvalidOperationException("JPEG quality option allocation failed");
                    IO.CGImageDestinationAddImage(dest, image, options);
                    if (IO.CGImageDestinationFinalize(dest) == 0) throw new InvalidOperationException("CGImageDestinationFinalize(public.jpeg) failed");
                    CF.CFRelease(dest); dest = 0;
                    CF.CFRelease(image); image = 0;
                    CF.CFRelease(provider); provider = 0;
                    if (released != 1) throw new InvalidOperationException("ImageIO kept the screenshot pixel provider after encoding");
                }
                long length = CF.CFDataGetLength(data);
                byte* bytes = CF.CFDataGetBytePtr(data);
                if (bytes == null || length < 4 || length > 64 * 1024 * 1024)
                    throw new InvalidOperationException("ImageIO returned invalid JPEG storage");
                return new ReadOnlySpan<byte>(bytes, (int)length).ToArray();
            }
            finally
            {
                if (dest != 0) CF.CFRelease(dest);
                if (image != 0) CF.CFRelease(image);
                if (provider != 0) CF.CFRelease(provider);
                if (options != 0) CF.CFRelease(options);
                if (number != 0) CF.CFRelease(number);
                if (data != 0) CF.CFRelease(data);
            }
        }

        [UnmanagedCallersOnly]
        private static void OnProviderRelease(void* info, void* data, nuint size) => *(int*)info += 1;

        private static partial class CF
        {
            private const string Lib = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";
            public const nint NumberFloat64Type = 6;   // kCFNumberFloat64Type
            [LibraryImport(Lib)] public static partial void CFRelease(nint obj);
            [LibraryImport(Lib)] public static partial nint CFDataCreateMutable(nint allocator, nint capacity);
            [LibraryImport(Lib)] public static partial nint CFDataGetLength(nint data);
            [LibraryImport(Lib)] public static partial byte* CFDataGetBytePtr(nint data);
            [LibraryImport(Lib)] public static partial nint CFNumberCreate(nint allocator, nint type, void* value);
            [LibraryImport(Lib)] public static partial nint CFDictionaryCreate(nint allocator, nint* keys, nint* values, nint count, nint keyCallBacks, nint valueCallBacks);
            [LibraryImport(Lib)] public static partial nint CFStringCreateWithCString(nint allocator, byte* cstr, uint encoding);
            private static readonly nint _handle = NativeLibrary.Load(Lib);
            public static readonly nint TypeDictionaryKeyCallBacks = NativeLibrary.GetExport(_handle, "kCFTypeDictionaryKeyCallBacks");
            public static readonly nint TypeDictionaryValueCallBacks = NativeLibrary.GetExport(_handle, "kCFTypeDictionaryValueCallBacks");
        }

        private static partial class CG
        {
            private const string Lib = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics";
            public const uint ImageAlphaNoneSkipLast = 5;   // kCGImageAlphaNoneSkipLast，字节序缺省 = 内存里 R G B X
            [LibraryImport(Lib)] public static partial nint CGDataProviderCreateWithData(void* info, void* data, nuint size, delegate* unmanaged<void*, void*, nuint, void> release);
            [LibraryImport(Lib)] public static partial nint CGImageCreate(nuint width, nuint height, nuint bitsPerComponent, nuint bitsPerPixel, nuint bytesPerRow,
                nint space, uint bitmapInfo, nint provider, double* decode, byte shouldInterpolate, int intent);
            [LibraryImport(Lib)] private static partial nint CGColorSpaceCreateWithName(nint name);
            private static readonly nint _handle = NativeLibrary.Load(Lib);
            // 进程内常驻一份（不释放）
            public static readonly nint SRGB = CGColorSpaceCreateWithName(*(nint*)NativeLibrary.GetExport(_handle, "kCGColorSpaceSRGB"));
        }

        private static partial class IO
        {
            private const string Lib = "/System/Library/Frameworks/ImageIO.framework/ImageIO";
            [LibraryImport(Lib)] public static partial nint CGImageDestinationCreateWithData(nint data, nint type, nuint count, nint options);
            [LibraryImport(Lib)] public static partial void CGImageDestinationAddImage(nint dest, nint image, nint properties);
            [LibraryImport(Lib)] public static partial byte CGImageDestinationFinalize(nint dest);
            private static readonly nint _handle = NativeLibrary.Load(Lib);
            public static readonly nint LossyCompressionQuality = *(nint*)NativeLibrary.GetExport(_handle, "kCGImageDestinationLossyCompressionQuality");
            // UTI public.jpeg（CFSTR 在 C# 里没有，进程内建一份常驻）
            public static readonly nint JpegType = Utf8("public.jpeg"u8);
            private static nint Utf8(ReadOnlySpan<byte> s)
            {
                Span<byte> z = stackalloc byte[s.Length + 1]; s.CopyTo(z); z[^1] = 0;
                fixed (byte* p = z) return CF.CFStringCreateWithCString(0, p, 0x08000100);   // kCFStringEncodingUTF8
            }
        }
    }
}
