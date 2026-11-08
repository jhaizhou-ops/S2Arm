// SPIR-V → MSL / GLSL 的两种实现：
//   CliSpvCross   命令行 spirv-cross（Homebrew 版），参数照 dmsh_build.py 的 XC——只给 Mac 上与离线链对拍用（iOS 没有子进程）；
//   NxgalSpvCross libnxgal 的 nxgal_dmsh_xc（graphics/metal/gal_prog.m），跑仓库内置 SPIRV-Cross（graphics/third_party/spirv_cross），选项等价于 XC——设备用，导出入口缺省走它。
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace S2A.Dsh
{
    public interface ISpvCross
    {
        /// <summary>spirv-cross --msl --msl-version 30100 --msl-argument-buffers --msl-texture-buffer-native --msl-pad-fragment-output &lt;spv&gt;；失败返回 null，err 带原因</summary>
        string Msl(byte[] spv, out string err);
        /// <summary>spirv-cross &lt;spv&gt; --version 450（GLSL）；失败返回 null</summary>
        string Glsl450(byte[] spv, out string err);
    }

    public sealed class CliSpvCross : ISpvCross
    {
        public static readonly string[] XC = { "--msl", "--msl-version", "30100", "--msl-argument-buffers", "--msl-texture-buffer-native", "--msl-pad-fragment-output" };
        readonly string _exe, _tmp;
        public CliSpvCross(string exe = null, string tmpDir = null)
        {
            _exe = exe ?? Environment.GetEnvironmentVariable("SPIRV_CROSS") ?? "spirv-cross";
            _tmp = tmpDir ?? Path.GetTempPath();
        }
        public string Msl(byte[] spv, out string err) => Run(spv, true, out err);
        public string Glsl450(byte[] spv, out string err) => Run(spv, false, out err);

        string Run(byte[] spv, bool msl, out string err)
        {
            string f = Path.Combine(_tmp, "dsh_" + Guid.NewGuid().ToString("N") + ".spv");
            File.WriteAllBytes(f, spv);
            try
            {
                var psi = new ProcessStartInfo(_exe) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, StandardOutputEncoding = new UTF8Encoding(false) };
                if (msl) { foreach (var a in XC) psi.ArgumentList.Add(a); psi.ArgumentList.Add(f); }
                else { psi.ArgumentList.Add(f); psi.ArgumentList.Add("--version"); psi.ArgumentList.Add("450"); }
                using var p = Process.Start(psi);
                var so = p.StandardOutput.ReadToEndAsync(); string se = p.StandardError.ReadToEnd(); p.WaitForExit(); string o = so.Result;
                if (p.ExitCode != 0) { err = se.Trim(); return null; }
                err = null; return o.Replace("\r\n", "\n").Replace('\r', '\n');   // subprocess text=True 的通用换行
            }
            finally { try { File.Delete(f); } catch { } }
        }
    }

    public sealed unsafe class NxgalSpvCross : ISpvCross
    {
        [DllImport("nxgal")] static extern int nxgal_dmsh_xc(byte* spv, ulong len, int glsl, out IntPtr text, byte* err, ulong errlen);
        [DllImport("nxgal")] static extern int nxgal_dmsh_color_round(byte* msl, byte* entry, out IntPtr text, byte* err, ulong errlen);
        [DllImport("nxgal")] static extern void nxgal_dmsh_xc_free(IntPtr p);
        [DllImport("nxgal")] static extern int nxgal_dmsh_xc_tess(byte* spv, ulong len, int vt, uint baseSlot, out IntPtr text, out uint flags, out uint ocp, byte* err, ulong errlen);
        [DllImport("nxgal")] static extern int nxgal_dmsh_spill(byte* src, uint slot, out IntPtr text, out uint bytes, byte* err, ulong errlen);
        [DllImport("nxgal")] static extern uint* nxgal_spv_harden(uint* spv, uint nw, out uint onw);
        [DllImport("nxgal")] static extern void nxgal_spv_free(void* p);

        /// <summary>越界钳位（#1204 T1）：与通用路径同一份 graphics/metal/gal_spvx.m（直连口径 nxgal_spv_harden），交 SPIRV-Cross 之前改写 SPIR-V。
        /// Metal 没有 robustBufferAccess：常量 / 存储缓冲越界读钳到末元素、越界写与原子不执行；直连不加循环上限。常量缓冲界长表 gal_ubo_len（按 NVN 槽）与
        /// spvBufferSizeConstants 由宿主 nvn_mtl.m 按当前绑定填（反射 ubolen / sbsize）。不用改或改写失败（libnxgal 内报红）→ 原样</summary>
        internal static byte[] Harden(byte[] spv)
        {
            if (spv.Length < 20 || (spv.Length & 3) != 0) return spv;
            uint onw; uint* o;
            fixed (byte* p = spv) o = nxgal_spv_harden((uint*)p, (uint)(spv.Length / 4), out onw);
            if (o == null) return spv;
            try { var r = new byte[(int)onw * 4]; Marshal.Copy((IntPtr)o, r, 0, r.Length); return r; }
            finally { nxgal_spv_free(o); }
        }

        internal static string ColorRound(string source)
        {
            byte[] src = Encoding.UTF8.GetBytes(source + "\0"), entry = Encoding.UTF8.GetBytes("main0\0");
            byte* error = stackalloc byte[512]; error[0] = 0; IntPtr text;
            int rc;
            fixed (byte* s = src, e = entry) rc = nxgal_dmsh_color_round(s, e, out text, error, 512);
            if (rc != 0 || text == IntPtr.Zero) throw new DshError("half color export", Marshal.PtrToStringUTF8((IntPtr)error));
            try { return Marshal.PtrToStringUTF8(text); }
            finally { nxgal_dmsh_xc_free(text); }
        }

        // 曲面细分（同 dmsh_build.py tess_msl）：外壳 → 计算核、域 → 顶点函数，接口缓冲从 baseSlot 起；→ (MSL, 记录标志, 外壳输出控制点数)
        internal static (string, uint, uint) TessMsl(byte[] spv, int vt, uint baseSlot)
        {
            byte* e = stackalloc byte[512]; e[0] = 0; IntPtr t; uint fl, ocp; int rc;
            fixed (byte* p = spv) rc = nxgal_dmsh_xc_tess(p, (ulong)spv.Length, vt, baseSlot, out t, out fl, out ocp, e, 512);
            if (rc != 0 || t == IntPtr.Zero) throw new DshError("MSL failed", Marshal.PtrToStringUTF8((IntPtr)e) ?? "nxgal_dmsh_xc_tess 失败");
            try { return (Marshal.PtrToStringUTF8(t), fl, ocp); }
            finally { nxgal_dmsh_xc_free(t); }
        }
        // 共享内存超过 32 KB 的计算核（同 dmsh_build.py spill_fix）：最大的线程组数组挪到设备缓冲、每线程组一片，宿主绑 slot；→ (源码, 每线程组字节)，0 = 没超、原样
        internal static (string, uint) SpillFix(string source, uint slot)
        {
            byte[] src = Encoding.UTF8.GetBytes(source + "\0"); byte* e = stackalloc byte[256]; e[0] = 0; IntPtr t; uint nb; int rc;
            fixed (byte* s = src) rc = nxgal_dmsh_spill(s, slot, out t, out nb, e, 256);
            if (rc < 0) throw new DshError("shared memory spill failed", Marshal.PtrToStringUTF8((IntPtr)e) ?? "nxgal_dmsh_spill 失败");
            if (rc == 0) return (source, 0);
            try { return (Marshal.PtrToStringUTF8(t), nb); }
            finally { nxgal_dmsh_xc_free(t); }
        }

        public string Msl(byte[] spv, out string err) => Run(spv, 0, out err);
        public string Glsl450(byte[] spv, out string err) => Run(spv, 1, out err);

        static string Run(byte[] spv, int glsl, out string err)
        {
            byte* e = stackalloc byte[512]; e[0] = 0; IntPtr t;
            int rc;
            fixed (byte* p = spv) rc = nxgal_dmsh_xc(p, (ulong)spv.Length, glsl, out t, e, 512);
            if (rc != 0 || t == IntPtr.Zero) { err = Marshal.PtrToStringUTF8((IntPtr)e) ?? "nxgal_dmsh_xc 失败"; return null; }
            try { err = null; return Marshal.PtrToStringUTF8(t); }
            finally { nxgal_dmsh_xc_free(t); }
        }
    }
}
