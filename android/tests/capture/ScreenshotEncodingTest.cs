// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.IO;
using System.Linq;
using Ryujinx.HLE.HOS.Services.Caps;
using Ryujinx.HLE.UI;
#if !S2A_ANDROID_HOST
using SkiaSharp;
#endif
namespace Ryujinx.HLE { static class S2AHooks { public static ScreenshotJpegEncoder EncodeScreenshotJpeg; } }
static class Program {
    static int n;
    static void Check(bool ok) { if(!ok)throw new Exception("assertion "+n);n++; }
    static void Throws<T>(Action f)where T:Exception {try{f();throw new Exception("accepted invalid input");}catch(T){n++;}}
    static int Main(string[] args) { try { return Run(args); } catch(Exception e) { Console.Error.WriteLine(e); return 1; } }
    static unsafe int Run(string[] args){
#if !S2A_ANDROID_HOST
        System.Runtime.InteropServices.NativeLibrary.SetDllImportResolver(typeof(SKBitmap).Assembly,
            (name, assembly, search) => name == "libSkiaSharp" ? System.Runtime.InteropServices.NativeLibrary.Load(args[1]) : 0);
#endif
        var rgba=new byte[64*48*4];for(int i=0;i<rgba.Length;i++)rgba[i]=(byte)(i%256);
        byte[] reference=File.ReadAllBytes(args[0]);int calls=0;
        Ryujinx.HLE.S2AHooks.EncodeScreenshotJpeg=(pixels,w,h,q)=>{
            calls++;Check(w==64&&h==48&&q==80&&pixels.SequenceEqual(rgba));return reference;
        };
        Check(ReferenceEquals(reference,ScreenshotEncoding.Encode(rgba,64,48,80)));Check(calls==1);
        Throws<ArgumentException>(()=>ScreenshotEncoding.Encode(rgba,0,48,80));
        Throws<ArgumentException>(()=>ScreenshotEncoding.Encode(rgba,64,48,-1));
        Throws<ArgumentException>(()=>ScreenshotEncoding.Encode(rgba,64,48,101));
        Throws<ArgumentException>(()=>ScreenshotEncoding.Encode(rgba.AsSpan(1),64,48,80));
        Throws<ArgumentException>(()=>ScreenshotEncoding.Encode(rgba,int.MaxValue,int.MaxValue,80));Check(calls==1);
        Ryujinx.HLE.S2AHooks.EncodeScreenshotJpeg=(p,w,h,q)=>null;
        Throws<InvalidOperationException>(()=>ScreenshotEncoding.Encode(rgba,64,48,80));
        Ryujinx.HLE.S2AHooks.EncodeScreenshotJpeg=(p,w,h,q)=>new byte[]{1,2,3,4};
        Throws<InvalidOperationException>(()=>ScreenshotEncoding.Encode(rgba,64,48,80));
        var expected=new IOException("real provider failure");
        Ryujinx.HLE.S2AHooks.EncodeScreenshotJpeg=(p,w,h,q)=>throw expected;
        try{ScreenshotEncoding.Encode(rgba,64,48,80);throw new Exception("failure hidden");}
        catch(IOException actual){Check(ReferenceEquals(actual,expected));}
        Ryujinx.HLE.S2AHooks.EncodeScreenshotJpeg=null;
#if S2A_ANDROID_HOST
        Throws<NotSupportedException>(()=>ScreenshotEncoding.Encode(rgba,64,48,80));
#else
        foreach(var size in new[]{(3,2),(17,5),(64,48)})foreach(int quality in new[]{0,80,100}){
            byte[] pixels=new byte[size.Item1*size.Item2*4];
            for(int i=0;i<pixels.Length;i+=4){byte alpha=(byte)(i%256);pixels[i+3]=alpha;
                pixels[i]=(byte)(alpha/2);pixels[i+1]=(byte)(alpha/3);pixels[i+2]=(byte)(alpha/4);}
            using SKBitmap bitmap=new(new SKImageInfo(size.Item1,size.Item2,SKColorType.Rgba8888));
            nint dest=bitmap.GetPixels();Check(dest!=0);pixels.CopyTo(new Span<byte>((void*)dest,pixels.Length));
            using SKData baseline=bitmap.Encode(SKEncodedImageFormat.Jpeg,quality);
            byte[] encoded=ScreenshotEncoding.Encode(pixels,size.Item1,size.Item2,quality);
            Check(encoded.SequenceEqual(baseline.ToArray()));
        }
#endif
        Console.WriteLine("ScreenshotEncoding assertions="+n);return 0;
    }
}
