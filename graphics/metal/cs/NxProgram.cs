// IProgram（第 4 块）：SPIR-V + 资源布局交 C 端（gal_prog.m）。
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader;
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace NxGal
{
    static unsafe partial class N
    {
        [DllImport(Lib)] public static extern uint nxgal_prog_create(NShader* shaders, int n, NResDesc* descs, int ndesc, int fragOutputMap);
        [DllImport(Lib)] public static extern int nxgal_prog_status(uint prog, int blocking);
        [DllImport(Lib)] public static extern void nxgal_prog_release(uint prog);
        [DllImport(Lib)] public static extern int nxgal_prog_binary(uint prog, void* outp, int cap);
        [DllImport(Lib)] public static extern uint nxgal_prog_load_binary(void* data, int len, int hasFragment);
        [DllImport(Lib)] public static extern int nxgal_prog_lib_open(byte* dir);
        [DllImport(Lib)] public static extern byte* nxgal_prog_last_error();
        [DllImport(Lib)] public static extern int nxgal_pso_archive_open_dir(byte* dir);
    }

    public sealed unsafe class NxProgram : IProgram
    {
        public readonly uint Id;
        NxProgram(uint id) => Id = id;

        /// <summary>渲染器内部管线预建（定格 / 上屏 / 顶点重排 / 索引转换），第一帧之前调一次，不计入首局现建</summary>
        public static void WarmInternal() => N.nxgal_warm_internal();

        /// <summary>开着色器包里本机 GPU 架构的管线归档（gal_pso.&lt;架构&gt;.bin）：0 载入 / 1 没有本机架构 / -1 失败</summary>
        public static int OpenPsoArchive(string dir)
        {
            byte[] a = System.Text.Encoding.UTF8.GetBytes(dir + "\0");
            fixed (byte* p = a) return N.nxgal_pso_archive_open_dir(p);
        }

        /// <summary>开离线着色器库目录（gal.idx + gal.shards + 各片 metallib，nxgal_init 之后）；失败返回原因，成功返回 null</summary>
        public static string OpenLibrary(string dir)
        {
            byte[] a = System.Text.Encoding.UTF8.GetBytes(dir + "\0");
            fixed (byte* pa = a) if (N.nxgal_prog_lib_open(pa) == 0) return null;
            return Marshal.PtrToStringUTF8((nint)N.nxgal_prog_last_error());
        }

        internal static NxProgram Create(ShaderSource[] shaders, ShaderInfo info)
        {
            List<NResDesc> descs = new();
            ResourceLayout layout = info.ResourceLayout;
            for (int set = 0; set < layout.Sets.Count; set++)
                foreach (ResourceDescriptor d in layout.Sets[set].Descriptors)
                    descs.Add(new NResDesc { Set = set, Binding = d.Binding, Count = d.Count, Type = (int)d.Type, Stages = (int)d.Stages });
            GCHandle[] pins = new GCHandle[shaders.Length];
            NShader* s = stackalloc NShader[shaders.Length];
            try
            {
                for (int i = 0; i < shaders.Length; i++)
                {
                    pins[i] = GCHandle.Alloc(shaders[i].BinaryCode, GCHandleType.Pinned);
                    s[i] = new NShader { Code = (byte*)pins[i].AddrOfPinnedObject(), Len = (uint)shaders[i].BinaryCode.Length, Stage = (int)shaders[i].Stage };
                }
                NResDesc[] arr = descs.ToArray();
                fixed (NResDesc* d = arr) return new NxProgram(N.nxgal_prog_create(s, shaders.Length, d, arr.Length, info.FragmentOutputMap));
            }
            finally { foreach (GCHandle h in pins) if (h.IsAllocated) h.Free(); }
        }

        // info 不读：资源布局在二进制里（nxgal_prog_load_binary）。Gpu 层载入缓存二进制时传空（DiskCacheHostStorage.S2AHostBinaryInfo），这里若改成读 info 要先改那边
        internal static NxProgram Load(byte[] binary, bool hasFragmentShader, ShaderInfo info)
        {
            fixed (byte* p = binary) return new NxProgram(N.nxgal_prog_load_binary(p, binary.Length, hasFragmentShader ? 1 : 0));
        }

        public ProgramLinkStatus CheckProgramLink(bool blocking) => Id == 0 ? ProgramLinkStatus.Failure : MapLinkStatus(N.nxgal_prog_status(Id, blocking ? 1 : 0));
        /// <summary>C 接口 nxgal_prog_status 的返回值（0 成功 / 1 失败 / 2 未完成）按值换成 Ryujinx 枚举（声明顺序是 Incomplete、Success、Failure，数值对不上，不能强转）；未知值按失败</summary>
        public static ProgramLinkStatus MapLinkStatus(int c) => c switch { 0 => ProgramLinkStatus.Success, 2 => ProgramLinkStatus.Incomplete, _ => ProgramLinkStatus.Failure };
        public byte[] GetBinary()
        {
            int n = N.nxgal_prog_binary(Id, null, 0);
            byte[] b = new byte[Math.Max(0, n)];
            fixed (byte* p = b) N.nxgal_prog_binary(Id, p, b.Length);
            return b;
        }
        public void Dispose() => N.nxgal_prog_release(Id);
    }
}
