// C ABI 入口（../gal_abi.h）：各块的 DllImport 写在各自文件的 partial class N 里，本文件放核心与库解析。
using System;
using System.Reflection;
using System.Runtime.InteropServices;

namespace NxGal
{
    // 本线程自动释放池轮换（gal_abi.h nxgal_pool_cycle）：给 GAL 外的 C# 线程循环用（graphics/loop/RenderLoop.cs 的 GPU 模拟线程每轮调）
    public static class NxAutorelease { public static void Cycle() => N.nxgal_pool_cycle(); }

    static unsafe partial class N
    {
        public const string Lib = "nxgal";

        static N()
        {
            // Mac 宿主：符号由主程序导出；单测 / 独立进程：NXGAL_LIB 或同目录 libnxgal.dylib。NativeAOT 静态链时不经过这里
            NativeLibrary.SetDllImportResolver(typeof(N).Assembly, (name, asm, path) =>
            {
                if (name != Lib) return IntPtr.Zero;
                IntPtr main = NativeLibrary.GetMainProgramHandle();
                if (NativeLibrary.TryGetExport(main, "nxgal_init", out _)) return main;
                string p = Environment.GetEnvironmentVariable("NXGAL_LIB");
                if (!string.IsNullOrEmpty(p) && NativeLibrary.TryLoad(p, out IntPtr h)) return h;
                return NativeLibrary.TryLoad("libnxgal.dylib", asm, path, out h) ? h : IntPtr.Zero;
            });
        }

        [DllImport(Lib)] public static extern ulong nxgal_abi_hash();   // 与 NxGal.Abi.Hash（构建时由 tools/abi_hash.py 生成）比对
        [DllImport(Lib)] public static extern void nxgal_device_caps(ulong[] o);   // [0] 位：1 BC 2 ASTC 4 ETC2 8 16 位紧凑格式 16 ASTC HDR；[1] 计算共享内存字节 [2] 建议工作集字节
        [DllImport(Lib)] public static extern int nxgal_init(int debugLevel);
        [DllImport(Lib)] public static extern void nxgal_shutdown();
        [DllImport(Lib)] public static extern void nxgal_request_stop();
        [DllImport(Lib)] public static extern int nxgal_shutdown_session();
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_barrier(int kind);
        [DllImport(Lib)] public static extern void nxgal_flush();
        [DllImport(Lib)] public static extern double nxgal_last_gpu_ms(out ulong frame);
        [DllImport(Lib)] public static extern void nxgal_warm_internal();   // 内部管线预建（定格 / 上屏 / 顶点重排 / 索引转换），第一帧之前调一次
        [DllImport(Lib)] public static extern void nxgal_create_sync(ulong id, int strict);
        [DllImport(Lib)] public static extern void nxgal_wait_sync(ulong id);
        [DllImport(Lib)] public static extern ulong nxgal_current_sync();
    }

    // 与 gal_abi.h 逐字段对应的结构
    [StructLayout(LayoutKind.Sequential)] struct NRect { public int X, Y, W, H; }
    [StructLayout(LayoutKind.Sequential)] struct NBufRange { public uint Buf; public int Offset, Size, Write; }
    [StructLayout(LayoutKind.Sequential)] struct NBufAssign { public int Binding; public NBufRange R; }
    [StructLayout(LayoutKind.Sequential)] unsafe struct NTexInfo
    {
        public int Width, Height, Depth, Levels, Samples, BlockW, BlockH, Bpp, Format, DsMode, Target;
        public fixed int Swz[4];
    }
    [StructLayout(LayoutKind.Sequential)] unsafe struct NBlend { public int Enable; public fixed float Constant[4]; public int ColorOp, ColorSrc, ColorDst, AlphaOp, AlphaSrc, AlphaDst; }
    [StructLayout(LayoutKind.Sequential)] struct NDepthTest { public int Test, Write, Func; }
    [StructLayout(LayoutKind.Sequential)] struct NStencil
    {
        public int Enable;
        public int FrontFunc, FrontSFail, FrontDpPass, FrontDpFail, FrontRef, FrontFuncMask, FrontMask;
        public int BackFunc, BackSFail, BackDpPass, BackDpFail, BackRef, BackFuncMask, BackMask;
    }
    [StructLayout(LayoutKind.Sequential)] unsafe struct NViewport { public float X, Y, W, H; public fixed int Swz[4]; public float ZNear, ZFar; }
    [StructLayout(LayoutKind.Sequential)] struct NVAttr { public int Buffer, Offset, IsZero, Format; }
    [StructLayout(LayoutKind.Sequential)] struct NVBuf { public NBufRange R; public int Stride, Divisor; }
    [StructLayout(LayoutKind.Sequential)] unsafe struct NSamplerInfo
    {
        public int MinFilter, MagFilter, SeamlessCube, AddrU, AddrV, AddrP, CompareMode, CompareOp;
        public fixed float Border[4];
        public float MinLod, MaxLod, LodBias, MaxAniso;
    }
    [StructLayout(LayoutKind.Sequential)] struct NCrop { public int Left, Right, Top, Bottom, FlipX, FlipY, Stretched; public float AspectX, AspectY; }
    [StructLayout(LayoutKind.Sequential)] unsafe struct NShader { public byte* Code; public uint Len; public int Stage; }
    [StructLayout(LayoutKind.Sequential)] struct NResDesc { public int Set, Binding, Count, Type, Stages; }

    static class Conv
    {
        public static NBufRange Range(Ryujinx.Graphics.GAL.BufferRange r) => new() { Buf = (uint)(int)r.Handle, Offset = r.Offset, Size = r.Size, Write = r.Write ? 1 : 0 };
        public static unsafe NTexInfo TexInfo(in Ryujinx.Graphics.GAL.TextureCreateInfo i)
        {
            NTexInfo n = new()
            {
                Width = i.Width, Height = i.Height, Depth = i.Depth, Levels = i.Levels, Samples = i.Samples, BlockW = i.BlockWidth, BlockH = i.BlockHeight,
                Bpp = i.BytesPerPixel, Format = (int)i.Format, DsMode = (int)i.DepthStencilMode, Target = (int)i.Target,
            };
            n.Swz[0] = (int)i.SwizzleR; n.Swz[1] = (int)i.SwizzleG; n.Swz[2] = (int)i.SwizzleB; n.Swz[3] = (int)i.SwizzleA;
            return n;
        }
    }
}
