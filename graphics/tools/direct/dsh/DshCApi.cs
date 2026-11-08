// S2A.Dsh 的 C 导出（NativeAOT 库模式按 [UnmanagedCallersOnly] 导出，services/aot/S2A.Aot.csproj 登记本程序集）：
//   int s2a_dsh_compile(const char *key16, int stage, const void *code, size_t code_len, const void *ctl, size_t ctl_len, const char *out_dir);
//   同步；stage 0 vs / 1 ps / 2 cs / 3 gs / 4 ts / 5 ms（NVN2 任务 / 网格）；code = 机器码区（含 0x30 字节 NVN 头），ctl = 以 34127698 开头的控制段（同直连包记录切出来的两段）。
//   成功 0，失败非 0 并往 stderr 打一行带原因的【红】。写 out_dir/<键>_b.metal + _b.json（几何着色器另有 _bg0.._bg4 / _bgv 各一对），与离线链同 schema；不出 .metallib。
//   int s2a_dsh_fout_variant(const char *metal_in, uint32_t umask, uint32_t smask, const char *metal_out)：片元输出逐位置定类型的入口 main0_t（见下）。
//   int s2a_dsh_vs_pad(const char *metal_in, uint32_t mask, const char *metal_out)：顶点着色器补齐变体（见下，运行期配对的 user(locn) 补齐）
//   int s2a_dsh_samp_emu(const char *metal_in, const char *metal_out)：采样器归约变体 <键>_se.metal（见下，#800）。
//   const char *s2a_dsh_xfp(void)：翻译器指纹（16 位十六进制），现编结果 _b.json 的 "xfp" 字段同值；宿主不等就不复用兜底目录里的旧结果。
//   答案表 / 配对表 / 映射表从 $S2A_GAME_DATA/shaders/direct/ 读（libc getenv：iOS 上它由原生层在运行时起来之后才设，.NET 的环境副本看不到）。
//
// 与离线链产物的差别，依据是直连运行时 graphics/nvn/gfx/nvn/nvn_mtl.m / nvn_refl.m / nvn_geometry.inc对缺省的处理：
//   · _bv（影子输入库）不出、json 不带 vin：nvn_refl.m 读不到 vin → has_vin = 0，vin_fn 直接返回 nil，整数输入照旧 CPU 换算（nvn_mtl.m vin_fn / vconv_wanted）；
//   · _bf（读帧缓冲版）不出、json 不带 fetch：nfc = nfo = 0，并通道合并判「不可证」不合并（nvn_mtl.m fz_p2_draw 的 !fs->rf.nfo 分支）；
//   · _bg0.._bg4 / _bgv 照出：几何绘制 shader_get(<键>_bg<拓扑>) 或 _bgv 拿不到就整笔不画（nvn_geometry.inc），属运行时必需。
// 入口吞掉全部异常，不跨 C 边界抛。
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace S2A.Dsh
{
    public static unsafe class DshCApi
    {
        [DllImport("libc")] static extern IntPtr getenv(string name);
        static ISpvCross s_xc;

        [UnmanagedCallersOnly(EntryPoint = "s2a_dsh_compile")]
        public static int Compile(byte* key16, int stage, byte* code, nuint codeLen, byte* ctl, nuint ctlLen, byte* outDir) => CompileCore(key16, stage, code, codeLen, ctl, ctlLen, outDir, null);

        /// <summary>导出入口的本体（xc 给 null = 内置 SPIRV-Cross 后端）；对拍工具也走这里</summary>
        public static int CompileCore(byte* key16, int stage, byte* code, nuint codeLen, byte* ctl, nuint ctlLen, byte* outDir, ISpvCross xc)
        {
            string key = "?", st = DshCompiler.StageName(stage) ?? stage.ToString();
            try
            {
                if (key16 == null || code == null || ctl == null || outDir == null) throw new DshError("bad argument", "空指针参数");
                key = Marshal.PtrToStringUTF8((IntPtr)key16);
                if (DshCompiler.StageName(stage) == null) throw new DshError("bad stage", $"阶段 {stage} 不支持（0 vs / 1 ps / 2 cs / 3 gs / 4 ts / 5 ms）");
                if (codeLen > int.MaxValue || ctlLen > int.MaxValue) throw new DshError("bad argument", "机器码区或控制段过长");
                var c = new ReadOnlySpan<byte>(code, (int)codeLen).ToArray(); var k = new ReadOnlySpan<byte>(ctl, (int)ctlLen).ToArray();
                IntPtr gd = getenv("S2A_GAME_DATA");
                string g = gd == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(gd);
                if (string.IsNullOrEmpty(g)) throw new DshError("no game data", "S2A_GAME_DATA 没设，答案表 / 配对表找不到");
                DshCompiler.Compile(key, st, c, k, Marshal.PtrToStringUTF8((IntPtr)outDir), xc ?? (s_xc ??= new NxgalSpvCross()), Path.Combine(g, "shaders", "direct"));
                return 0;
            }
            catch (DshError e) { if (!e.Reported) Red(key, st, e.Status + "：" + e.Detail); return 1; }
            catch (Exception e) { Red(key, st, "异常 " + e.GetType().Name + "：" + e.Message); return 2; }
        }

        /// <summary>int s2a_dsh_fout_variant(const char *metal_in, uint32_t umask, uint32_t smask, const char *metal_out)：现编出的片元 .metal 加逐位置定类型的入口 main0_t
        /// （DshCompiler.FsTyped；建管线时画布格式和库里的入口对不上用，nvn_mtl.m pso_get）。成功 0，失败非 0 并往 stderr 打一行【红】</summary>
        [UnmanagedCallersOnly(EntryPoint = "s2a_dsh_fout_variant")]
        public static int FoutVariant(byte* metalIn, uint umask, uint smask, byte* metalOut)
        {
            string i = "?";
            try
            {
                if (metalIn == null || metalOut == null) throw new DshError("bad argument", "空指针参数");
                i = Marshal.PtrToStringUTF8((IntPtr)metalIn);
                string v = DshCompiler.FsTyped(File.ReadAllText(i), umask, smask) ?? throw new DshError("no main0", "源码里认不出片元入口 main0");
                string o = Marshal.PtrToStringUTF8((IntPtr)metalOut), t = o + ".tmp";
                File.WriteAllText(t, v); File.Move(t, o, true);   // 先写临时文件再改名：别的线程 / 下一局只会看到完整的
                return 0;
            }
            catch (DshError e) { Red(Path.GetFileName(i), "ps", $"输出类型变体 u={umask:x} s={smask:x}：" + e.Status + "：" + e.Detail); return 1; }
            catch (Exception e) { Red(Path.GetFileName(i), "ps", $"输出类型变体 u={umask:x} s={smask:x}：异常 " + e.GetType().Name + "：" + e.Message); return 2; }
        }

        /// <summary>int s2a_dsh_samp_emu(const char *metal_in, const char *metal_out)：采样器归约变体（DshCompiler.FsRd，#800；离线库没有这支的变体、本机 GPU 缺原生归约的、
        /// 绘制又真绑了这样的采样器时宿主要它，nvn_mtl.m se_build）。成功 0；main0 没有能改的采样 3（不写文件，宿主记下不再要）；失败 1 / 2 并往 stderr 打一行【红】</summary>
        [UnmanagedCallersOnly(EntryPoint = "s2a_dsh_samp_emu")]
        public static int SampEmu(byte* metalIn, byte* metalOut)
        {
            string i = "?";
            try
            {
                if (metalIn == null || metalOut == null) throw new DshError("bad argument", "空指针参数");
                i = Marshal.PtrToStringUTF8((IntPtr)metalIn);
                string s = File.ReadAllText(i), v = DshCompiler.FsRd(s);
                if (v == s) return 3;
                string o = Marshal.PtrToStringUTF8((IntPtr)metalOut), t = o + ".tmp";
                File.WriteAllText(t, v); File.Move(t, o, true);   // 先写临时文件再改名：别的线程 / 下一局只会看到完整的
                return 0;
            }
            catch (DshError e) { Red(Path.GetFileName(i), "ps/cs", "采样器归约变体：" + e.Status + "：" + e.Detail); return 1; }
            catch (Exception e) { Red(Path.GetFileName(i), "ps/cs", "采样器归约变体：异常 " + e.GetType().Name + "：" + e.Message); return 2; }
        }

        /// <summary>int s2a_dsh_vs_pad(const char *metal_in, uint32_t mask, const char *metal_out)：顶点着色器补齐变体（DshCompiler.VsPadMask；运行期配上的片元要读
        /// 它不写的 user(locn)，位 n = locn，补 (0,0,0,1)，同离线 vs_pad；nvn_mtl.m vp_build）。文件头一行「// s2a:vs-pad 1 &lt;掩码&gt;」。成功 0；没什么可补 3（不写文件）；失败 1 / 2 并往 stderr 打一行【红】</summary>
        [UnmanagedCallersOnly(EntryPoint = "s2a_dsh_vs_pad")]
        public static int VsPad(byte* metalIn, uint mask, byte* metalOut)
        {
            string i = "?";
            try
            {
                if (metalIn == null || metalOut == null) throw new DshError("bad argument", "空指针参数");
                i = Marshal.PtrToStringUTF8((IntPtr)metalIn);
                var (v, miss) = DshCompiler.VsPadMask(File.ReadAllText(i), mask);
                if (miss.Count == 0) return 3;
                string o = Marshal.PtrToStringUTF8((IntPtr)metalOut), t = o + ".tmp";
                File.WriteAllText(t, $"// s2a:vs-pad 1 {mask:x}\n" + v); File.Move(t, o, true);   // 先写临时文件再改名：别的线程 / 下一局只会看到完整的
                return 0;
            }
            catch (DshError e) { Red(Path.GetFileName(i), "vs", $"顶点补齐变体 {mask:x}：" + e.Status + "：" + e.Detail); return 1; }
            catch (Exception e) { Red(Path.GetFileName(i), "vs", $"顶点补齐变体 {mask:x}：异常 " + e.GetType().Name + "：" + e.Message); return 2; }
        }

        /// <summary>const char *s2a_dsh_xfp(void)：本库翻译器指纹（16 位小写十六进制，NUL 结尾、常驻）。宿主 dsh_miss.inc dsh_have / nvn_mtl.m shader_build 用它判兜底目录里上局现编的结果能不能复用</summary>
        [UnmanagedCallersOnly(EntryPoint = "s2a_dsh_xfp")]
        public static byte* Xfp() => s_xfp;
        static readonly byte* s_xfp = MakeXfp();
        static byte* MakeXfp()
        {
            var b = Encoding.ASCII.GetBytes(DshChain.Xfp);
            var p = (byte*)NativeMemory.Alloc((nuint)b.Length + 1);   // 进程内常驻，不释放
            b.AsSpan().CopyTo(new Span<byte>(p, b.Length)); p[b.Length] = 0;
            return p;
        }

        static void Red(string key, string st, string why)
        {
            try { Console.Error.WriteLine($"【红】直连兜底现编 {key}（{st}）失败：{why.Replace('\n', ' ')}"); } catch { }
        }
    }

    /// <summary>翻译器（Program.cs，原样）往 Console 写的东西按线程截下：只截正在调翻译器的那条线程，别的线程照常写到原处</summary>
    static class ThreadCapture
    {
        [ThreadStatic] static StringBuilder t_out, t_err;
        static readonly object s_lock = new(); static volatile bool s_installed;

        sealed class Router : TextWriter
        {
            readonly TextWriter _inner; readonly bool _err;
            public Router(TextWriter inner, bool err) { _inner = inner; _err = err; }
            StringBuilder Cap => _err ? t_err : t_out;
            public override Encoding Encoding => _inner.Encoding;
            public override void Write(char value) { var c = Cap; if (c != null) c.Append(value); else _inner.Write(value); }
            public override void Write(string value) { var c = Cap; if (c != null) c.Append(value); else _inner.Write(value); }
            public override void Write(char[] buffer, int index, int count) { var c = Cap; if (c != null) c.Append(buffer, index, count); else _inner.Write(buffer, index, count); }
            public override void WriteLine(string value) { var c = Cap; if (c != null) c.Append(value).Append('\n'); else _inner.WriteLine(value); }
            public override void WriteLine() { var c = Cap; if (c != null) c.Append('\n'); else _inner.WriteLine(); }
            public override void Flush() { if (Cap == null) _inner.Flush(); }
        }

        public static void Begin()
        {
            if (!s_installed)
                lock (s_lock)
                    if (!s_installed)
                    {
                        Console.SetOut(new Router(Console.Out, false));
                        Console.SetError(new Router(Console.Error, true));
                        s_installed = true;
                    }
            t_out = new StringBuilder(); t_err = new StringBuilder();
        }
        public static void End(out string o, out string e)
        {
            o = t_out?.ToString() ?? ""; e = t_err?.ToString() ?? "";
            t_out = t_err = null;
        }
    }
}
