using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace S2A.Services.Tests
{
    // 苹果相册截图 JPEG 编码器（platform/apple/cs/capture/AppleScreenshotEncoder.cs，ImageIO）。
    //   11-02 Zumba 普查红：苹果宿主没接 S2AHooks.EncodeScreenshotJpeg，落到 Skia、宿主里没有 libSkiaSharp.dylib → 「服务调用异常 svc 0x21」。
    //   期望全部按输入手写、不跑被测实现：JPEG 头 FF D8 尾 FF D9；系统 ImageIO 解回的宽高 = 输入宽高；纯色图解回中心像素 = 输入 RGB（±4，JPEG 量化）、
    //   alpha 不参与（alpha 0 的同色图解回同色）；同一张噪声图质量 0 的字节数 < 质量 100；非法尺寸 / 质量 / 长度抛 ArgumentException。
    public static unsafe partial class Program
    {
        [SoloTest("--apple-screenshot-jpeg")]
        private static int AppleScreenshotJpeg()
        {
            int bad = 0;
            void Row(string what, string expect, string actual)
            {
                bool ok = expect == actual; if (!ok) bad++;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 苹果截图 JPEG {what}：{expect} → {actual}");
            }
            // 尺寸 × 质量：头尾、解回宽高
            foreach ((int w, int h) in new[] { (3, 2), (17, 5), (64, 48), (1280, 720) })
                foreach (int q in new[] { 0, 80, 100 })
                {
                    byte[] px = new byte[w * h * 4];
                    for (int i = 0; i < px.Length; i++) px[i] = (byte)(i * 7 + i / 13);
                    byte[] j = S2A.Apple.Capture.AppleScreenshotEncoder.Encode(px, w, h, q);
                    (int dw, int dh, _) = DecodeJpeg(j, w / 2, h / 2);
                    Row($"{w}×{h} 质量 {q}（头、尾、解回宽高）", $"FFD8、FFD9、{w}×{h}", $"{j[0]:X2}{j[1]:X2}、{j[^2]:X2}{j[^1]:X2}、{dw}×{dh}");
                }
            // 纯色：通道顺序、alpha 不参与
            foreach ((byte r, byte g, byte b, byte a) in new[] { ((byte)200, (byte)40, (byte)90, (byte)255), ((byte)30, (byte)180, (byte)220, (byte)255), ((byte)200, (byte)40, (byte)90, (byte)0) })
            {
                byte[] px = new byte[64 * 48 * 4];
                for (int i = 0; i < px.Length; i += 4) { px[i] = r; px[i + 1] = g; px[i + 2] = b; px[i + 3] = a; }
                (_, _, uint c) = DecodeJpeg(S2A.Apple.Capture.AppleScreenshotEncoder.Encode(px, 64, 48, 100), 32, 24);
                Row($"纯色 ({r},{g},{b}) alpha {a} 质量 100 解回中心像素（各通道 ±4）", "是", Near(c, r, g, b) ? "是" : $"否 {c:X8}");
            }
            // 质量参数真生效：噪声图质量 0 比 100 小
            {
                byte[] px = new byte[64 * 48 * 4]; uint s = 12345;
                for (int i = 0; i < px.Length; i++) { s = s * 1103515245 + 12345; px[i] = (byte)(s >> 16); }
                int n0 = S2A.Apple.Capture.AppleScreenshotEncoder.Encode(px, 64, 48, 0).Length, n100 = S2A.Apple.Capture.AppleScreenshotEncoder.Encode(px, 64, 48, 100).Length;
                Row("噪声图 质量 0 字节数 < 质量 100", "是", n0 < n100 ? "是" : $"否 {n0} / {n100}");
            }
            // 非法输入
            {
                byte[] px = new byte[64 * 48 * 4]; int thrown = 0;
                foreach (Action f in new Action[] {
                    () => S2A.Apple.Capture.AppleScreenshotEncoder.Encode(px, 0, 48, 80),
                    () => S2A.Apple.Capture.AppleScreenshotEncoder.Encode(px, 64, 48, -1),
                    () => S2A.Apple.Capture.AppleScreenshotEncoder.Encode(px, 64, 48, 101),
                    () => S2A.Apple.Capture.AppleScreenshotEncoder.Encode(px.AsSpan(1), 64, 48, 80) })
                    try { f(); } catch (ArgumentException) { thrown++; }
                Row("非法宽 / 质量 -1 / 质量 101 / 长度差 1 抛 ArgumentException 个数", "4", thrown.ToString());
            }
            return bad == 0 ? 0 : 1;
        }

        // 服务层：caps:su SaveScreenShotEx0（游戏存相册，Zumba 调的同一条）经苹果装配登记的编码器写出相册 jpg，系统能解回 1280×720、中心像素 = 输入色
        [SoloTest("--caps-save-jpeg", Booted = true)]
        private static void CapsSaveJpeg()
        {
            const int W = 1280, H = 720, Shot = W * H * 4;
            string root = Path.Combine(Path.GetTempPath(), $"s2a_caps_jpeg_{Environment.ProcessId}");
            try
            {
                Directory.CreateDirectory(Path.Combine(root, "exefs"));
                Directory.CreateDirectory(Path.Combine(root, "ctl"));
                Directory.CreateDirectory(Path.Combine(root, "romfs"));
                File.Copy(Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../compat/tree/src/Ryujinx.HLE/Homebrew.npdm")), Path.Combine(root, "exefs", "main.npdm"));
                File.WriteAllBytes(Path.Combine(root, "ctl", "control.nacp"), new byte[0x4000]);
                Host.Device.System.ServiceTable.WaitServicesReady();
                Application.Register(Host.Device, root);
                Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
                uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
                Msg init = Msg.Cmif(0, Bytes(0L)); init.SendPid = true; Call(sm, init);
                Reply gcs = Call(sm, Msg.Cmif(1, Name8("caps:su")));
                uint capsu = gcs.Move.Count == 1 ? gcs.Move[0] : 0;
                byte* shot = FakeNative.Alloc(Shot);
                for (int i = 0; i < Shot; i += 4) { shot[i] = 200; shot[i + 1] = 40; shot[i + 2] = 90; shot[i + 3] = 255; }
                try { Directory.Delete(CapsAlbumDir(), true); } catch (DirectoryNotFoundException) { }
                long red0 = Red.Total;
                Msg ss = Msg.Cmif(203, Bytes(new byte[0x40], 0u, 0UL, 0UL)); ss.SendPid = true; ss.A.Add(((ulong)shot, (ulong)Shot));
                uint r = Call(capsu, ss).Result;
                string[] made = Directory.Exists(CapsAlbumDir()) ? Directory.GetFiles(CapsAlbumDir(), "*.jpg", SearchOption.AllDirectories) : [];
                byte[] j = made.Length == 1 ? File.ReadAllBytes(made[0]) : [];
                bool head = j.Length >= 4 && j[0] == 0xFF && j[1] == 0xD8 && j[^2] == 0xFF && j[^1] == 0xD9;
                (int dw, int dh, uint c) = head ? DecodeJpeg(j, W / 2, H / 2) : (0, 0, 0u);
                Check("截图 SaveScreenShotEx0 走苹果编码器：结果、新增报红、相册 jpg 个数、JPEG 头尾、系统解回宽高、中心像素 = (200,40,90)±4",
                    "0、0、1、是、1280×720、是", $"{r}、{Red.Total - red0}、{made.Length}、{(head ? "是" : "否")}、{dw}×{dh}、{(Near(c, 200, 40, 90) ? "是" : $"否 {c:X8}")}");
                try { Directory.Delete(CapsAlbumDir(), true); } catch (DirectoryNotFoundException) { }
            }
            finally { try { Directory.Delete(root, true); } catch { } }
        }

        private static bool Near(uint rgba, int r, int g, int b) =>
            Math.Abs((int)(rgba & 0xFF) - r) <= 4 && Math.Abs((int)(rgba >> 8 & 0xFF) - g) <= 4 && Math.Abs((int)(rgba >> 16 & 0xFF) - b) <= 4;

        // 系统 ImageIO 解 JPEG → (宽, 高, (x, y) 处像素：内存 R G B A 排成小端 uint)。画进 sRGB 位图上下文（与编码同色彩空间，不做色彩转换）
        private static (int W, int H, uint Px) DecodeJpeg(byte[] jpeg, int x, int y)
        {
            nint data = 0, src = 0, img = 0, ctx = 0;
            try
            {
                fixed (byte* p = jpeg) data = JpegCF.CFDataCreate(0, p, jpeg.Length);
                src = JpegIO.CGImageSourceCreateWithData(data, 0);
                img = src == 0 ? 0 : JpegIO.CGImageSourceCreateImageAtIndex(src, 0, 0);
                if (img == 0) return (0, 0, 0);
                int w = (int)JpegCG.CGImageGetWidth(img), h = (int)JpegCG.CGImageGetHeight(img);
                uint[] buf = new uint[w * h];
                fixed (uint* b = buf)
                {
                    ctx = JpegCG.CGBitmapContextCreate(b, (nuint)w, (nuint)h, 8, (nuint)w * 4, JpegCG.SRGB, 1 /* kCGImageAlphaPremultipliedLast：R G B A */);
                    if (ctx == 0) return (w, h, 0);
                    JpegCG.CGContextDrawImage(ctx, new JpegCG.Rect { W = w, H = h }, img);
                }
                return (w, h, buf[y * w + x]);
            }
            finally
            {
                if (ctx != 0) JpegCF.CFRelease(ctx);
                if (img != 0) JpegCF.CFRelease(img);
                if (src != 0) JpegCF.CFRelease(src);
                if (data != 0) JpegCF.CFRelease(data);
            }
        }

        private static partial class JpegCF
        {
            private const string Lib = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";
            [LibraryImport(Lib)] public static partial void CFRelease(nint obj);
            [LibraryImport(Lib)] public static partial nint CFDataCreate(nint allocator, byte* bytes, nint length);
        }

        private static partial class JpegIO
        {
            private const string Lib = "/System/Library/Frameworks/ImageIO.framework/ImageIO";
            [LibraryImport(Lib)] public static partial nint CGImageSourceCreateWithData(nint data, nint options);
            [LibraryImport(Lib)] public static partial nint CGImageSourceCreateImageAtIndex(nint src, nuint index, nint options);
        }

        private static partial class JpegCG
        {
            private const string Lib = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics";
            [StructLayout(LayoutKind.Sequential)] public struct Rect { public double X, Y, W, H; }
            [LibraryImport(Lib)] public static partial nuint CGImageGetWidth(nint img);
            [LibraryImport(Lib)] public static partial nuint CGImageGetHeight(nint img);
            [LibraryImport(Lib)] public static partial nint CGBitmapContextCreate(void* data, nuint w, nuint h, nuint bpc, nuint bpr, nint space, uint info);
            [LibraryImport(Lib)] public static partial void CGContextDrawImage(nint ctx, Rect rect, nint img);
            [LibraryImport(Lib)] private static partial nint CGColorSpaceCreateWithName(nint name);
            private static readonly nint _handle = NativeLibrary.Load(Lib);
            public static readonly nint SRGB = CGColorSpaceCreateWithName(*(nint*)NativeLibrary.GetExport(_handle, "kCGColorSpaceSRGB"));   // 平台例外：本用例只验苹果截图编码器（platform/apple/cs/capture），解码比对用同一个 sRGB 色彩空间；只在苹果上跑
        }
    }
}
