// 逐帧记账（测试契约 tests/真机契约.md §3）：每上屏一帧调原生层 s2a_frame_presented()（自动玩家 / 健康表的帧数），
// 设了 S2A_FRAMES_TSV 时追加一行 frames.tsv。稳态零分配：行缓冲预分配、Utf8Formatter 格式化、RandomAccess 按偏移写（每帧一次 write，_exit(86) 也不丢已写的行）
using Microsoft.Win32.SafeHandles;
using System;
using System.Buffers.Text;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

namespace NxGal
{
    static unsafe partial class N
    {
        [DllImport(Lib)] public static extern void nxgal_frame_totals(ulong* o);
        [DllImport(Lib)] public static extern ulong nxgal_display_interval_us();
        [DllImport(Lib)] public static extern void nxgal_prog_stats(uint* o);
        [DllImport(Lib)] public static extern void nxgal_pso_cache_stats(ulong* o);
        [DllImport("s2a_native")] public static extern void s2a_frame_presented();
        [DllImport("s2a_native")] public static extern void s2a_nominal_fps_set(int fps);   // 出图实际跟的节拍（自动玩家折算路线帧数，runtime/src/ap_host.c）
        [DllImport("s2a_native")] public static extern void s2a_direct_frame_sample_set(delegate* unmanaged<ulong, long*, void> f);
        // 同局交替开关（runtime/src/alt.c，S2A_ALT=<秒>）：-1 没在交替 / 0 关段 / 1 开段；frames.tsv 末列 alt 记 相位 + 1（0 不交替、1 关、2 开）
        [DllImport("s2a_native")] public static extern int s2a_alt_phase();
    }

    public static unsafe class NxFrames
    {
        static int _altLast = -2, _altSeg;   // 同局交替：上一帧的相位、已开过的段数（换段时打一行）
        // 宿主侧（S2A.Gfx 渲染循环）登记的额外累计：写 4 个 long——宏总次数、解释器次数、宏总刻度、解释器刻度（Stopwatch 刻度）。NxGal 不引用 Ryujinx.Graphics.Gpu，经此取
        public static delegate*<long*, void> HostTotals;
        // 按 GC 间隔拆账回调（S2A_ALLOC_TRACE=1 时 services/aot/Compose.cs 挂上；关着是 null，零开销）：每打一行 [gc] 调一次，返回要紧接着打的行
        public static Func<string> OnGcAlloc;
        // 宿主登记的镜头位姿（画幅线宽屏包装层 CameraTrack）：给 8 个 float——位置 x y z、前向 fx fy fz、偏航、俯仰（度）；返回 1 = 本帧有透视主镜头。frames.tsv cam_* 列，没有写空字段（不写 0，免得被当成镜头在原点）
        public static delegate*<float*, int> Camera;
        static long _mn, _mi, _mt, _mit;
        static bool _init, _noNative;
        static SafeFileHandle _f; static long _off; static readonly byte[] _row = new byte[768];   // 21 列 × 最长 20 位 + 8 列镜头位姿
        static int _gcN; static long _frame, _t; static long _alloc, _allocGpu; static TimeSpan _gcPause; static ulong _rb, _bp, _draw, _pass, _up, _rw; static uint _miss; static long _xn; static ulong _pso, _psoNs;
        const string Head = "frame\twall_us\talloc_b\tgc0\tgc1\tgc2\trb_us\tdraw_n\tpass_n\tupload_n\trw_kb\tshader_miss\talloc_gpu_b\tdisp_us\tmacro_n\tmacro_interp_n\tmacro_us\tmacro_interp_us\txlate_n\tpso_n\tpso_us\tcam_x\tcam_y\tcam_z\tcam_fx\tcam_fy\tcam_fz\tcam_yaw\tcam_pitch\tgpuq_us\tgc_pause_us\talt\n";   // pso_n / pso_us：本帧现建管线（归档没命中）个数与耗时   // xlate_n：本帧 Ryujinx 当场翻译的程序数（着色器包没覆盖到的，见 NxRenderer.CreatedN）   // macro_*：本帧宏执行次数 / 其中走解释器的次数 / 总耗时 / 解释器耗时（微秒；宿主经 HostTotals 给）   // disp_us：最近两次画面真正上屏的间隔（有显示层才有值，没有为 0）   // alloc_gpu_b：渲染线程本帧托管分配（拆账：总分配里多少出在 GPU 线程）

        internal static void OnPresent()
        {
            if (!_noNative)
            {
                try { N.s2a_frame_presented(); }
                catch (Exception e) when (e is DllNotFoundException || e is EntryPointNotFoundException) { _noNative = true; }   // 回放器等不在宿主里跑的进程：没有原生层
            }
            if (!_init) Init();
            ulong* t = stackalloc ulong[6]; N.nxgal_frame_totals(t);
            uint* ps = stackalloc uint[6]; N.nxgal_prog_stats(ps);
            long now = Stopwatch.GetTimestamp(), alloc = GC.GetTotalAllocatedBytes(false), allocGpu = GC.GetAllocatedBytesForCurrentThread(); uint miss = ps[3] + ps[4];
            TimeSpan gcPause = GC.GetTotalPauseDuration();   // OnPresent 在渲染线程上
            if (_f != null)
            {
                Span<byte> b = _row; int n = 0;
                n = U(b, n, (ulong)++_frame, '\t');
                n = U(b, n, _t == 0 ? 0 : (ulong)((now - _t) * 1_000_000 / Stopwatch.Frequency), '\t');
                n = U(b, n, (ulong)Math.Max(0, alloc - _alloc), '\t');
                n = U(b, n, (ulong)GC.CollectionCount(0), '\t'); n = U(b, n, (ulong)GC.CollectionCount(1), '\t'); n = U(b, n, (ulong)GC.CollectionCount(2), '\t');
                n = U(b, n, (t[4] - _rb) / 1000, '\t'); n = U(b, n, t[0] - _draw, '\t'); n = U(b, n, t[1] - _pass, '\t'); n = U(b, n, t[2] - _up, '\t'); n = U(b, n, (t[3] - _rw) / 1024, '\t');
                n = U(b, n, miss - _miss, '\t');
                n = U(b, n, (ulong)Math.Max(0, allocGpu - _allocGpu), '\t');
                n = U(b, n, N.nxgal_display_interval_us(), '\t');
                long* h = stackalloc long[4] { _mn, _mi, _mt, _mit }; if (HostTotals != null) HostTotals(h);
                n = U(b, n, (ulong)(h[0] - _mn), '\t'); n = U(b, n, (ulong)(h[1] - _mi), '\t');
                n = U(b, n, (ulong)((h[2] - _mt) * 1_000_000 / Stopwatch.Frequency), '\t'); n = U(b, n, (ulong)((h[3] - _mit) * 1_000_000 / Stopwatch.Frequency), '\t');
                long xn = System.Threading.Interlocked.Read(ref NxRenderer.CreatedN); n = U(b, n, (ulong)(xn - _xn), '\t'); _xn = xn;
                ulong* pc = stackalloc ulong[4]; N.nxgal_pso_cache_stats(pc); n = U(b, n, pc[1] - _pso, '\t'); n = U(b, n, (pc[2] - _psoNs) / 1000, '\t'); _pso = pc[1]; _psoNs = pc[2];
                float* cam = stackalloc float[8];
                if (Camera != null && Camera(cam) != 0) for (int i = 0; i < 8; i++) { Utf8Formatter.TryFormat(cam[i], b[n..], out int w, new System.Buffers.StandardFormat('F', 3)); n += w; b[n++] = (byte)'\t'; }
                else { for (int i = 0; i < 8; i++) b[n++] = (byte)'\t'; }
                // gpuq_us：本帧编码线程等命令分配器环（GPU 跟不上的反压），与 rb_us（读回 / 同步号）分开记；放在最后一列，前面各列位置不变
                n = U(b, n, (t[5] - _bp) / 1000, '\t');
                // gc_pause_us：已完成 GC 的累计暂停增量，首帧没有前一帧基点，记 0。
                n = U(b, n, _frame == 1 ? 0 : (ulong)Math.Max(0, (gcPause - _gcPause).Ticks / 10), '\t');
                // alt：同局交替开关的相位 + 1（0 不交替、1 关段、2 开段）；换段时打一行（窗口统计按 alt 列分，见 tools/alt_report.py）
                int alt = N.s2a_alt_phase();
                if (alt != _altLast) { if (alt >= 0) Console.Error.WriteLine($"[交替] 第 {_altSeg++} 段{(alt == 1 ? "开" : "关")}，起于帧 {_frame}"); _altLast = alt; }
                n = U(b, n, (ulong)(alt + 1), '\n');
                _mn = h[0]; _mi = h[1]; _mt = h[2]; _mit = h[3];
                RandomAccess.Write(_f, b[..n], _off); _off += n;
            }
            int gcN = GC.CollectionCount(0);
            if (gcN != _gcN && _frame > 0) GcLine(_frame);
            _gcN = gcN;
            _t = now; _alloc = alloc; _allocGpu = allocGpu; _gcPause = gcPause; _rb = t[4]; _bp = t[5]; _draw = t[0]; _pass = t[1]; _up = t[2]; _rw = t[3]; _miss = miss;
        }

        // GC 事件读数（10-23 总指挥：单次停顿时长跟存活 / 晋升量走、不跟分配量走——塞尔达 gen1 一次 13.6 ms、马车8 gen2 一次 80 ms，frames.tsv 只有代计数判不出原因）：
        //   gen0 计数变了（有 GC 完成）就打一行 [gc]：本次是第几代、是否压缩 / 并发、晋升字节、固定对象数、两段停顿、各代 / 大对象堆回收前后大小。只在发生 GC 的帧取一次，平时零开销
        static void GcLine(long frame)
        {
            GCMemoryInfo gi = GC.GetGCMemoryInfo(GCKind.Any); ReadOnlySpan<GCGenerationInfo> gg = gi.GenerationInfo; ReadOnlySpan<TimeSpan> pd = gi.PauseDurations;
            var sb = new System.Text.StringBuilder(256);
            sb.Append($"[gc] 帧 {frame} 第 {gi.Index} 次：gen{gi.Generation}{(gi.Compacted ? " 压缩" : "")}{(gi.Concurrent ? " 并发" : "")}，晋升 {gi.PromotedBytes / 1024} KB，固定 {gi.PinnedObjectsCount}，停顿 {(pd.Length > 0 ? pd[0].TotalMilliseconds : 0):F2}");
            if (pd.Length > 1 && pd[1] > TimeSpan.Zero) sb.Append($" + {pd[1].TotalMilliseconds:F2}");
            sb.Append($" ms，堆 {gi.HeapSizeBytes >> 20} MB；回收前→后");
            for (int i = 0; i < gg.Length; i++) sb.Append($" {(i < 3 ? "g" + i : i == 3 ? "大" : "固")} {gg[i].SizeBeforeBytes >> 10}→{gg[i].SizeAfterBytes >> 10} KB");
            // GC 选不选「阻塞压缩」看的几样（10-24 帧率能耗线：xc3 / 巫师3 的 gen2 都是阻塞压缩、几乎不回收，后台 GC 本就开着）：碎片、内存负载 / 高负载阈值、已提交
            sb.Append($"；碎片 {gi.FragmentedBytes >> 20} MB、内存负载 {gi.MemoryLoadBytes >> 20} / 阈值 {gi.HighMemoryLoadThresholdBytes >> 20} MB、已提交 {gi.TotalCommittedBytes >> 20} MB");
            Console.Error.WriteLine(sb.ToString());
            // 按 GC 间隔拆账（S2A_ALLOC_TRACE=1 时 Compose 挂上）：紧接 [gc] 行列本次与上次 GC 之间各项分配增量
            if (OnGcAlloc != null) { string s = OnGcAlloc(); if (!string.IsNullOrEmpty(s)) Console.Error.WriteLine(s); }
        }

        /// <summary>
        /// 直连模式（通用渲染循环不起）：登记直连图形层的每帧采样钩子（graphics/nvn/host_adapt.m s2a_direct_frame_sample_set），
        /// frames.tsv 的分配 / GC 列由那边唯一的写入点按上屏序号写，[gc] 行由这里在采样时打（帧号 = 第几次上屏）
        /// </summary>
        public static void StartDirect() => N.s2a_direct_frame_sample_set(&DirectSample);

        public static void ResetSession()
        {
            N.s2a_direct_frame_sample_set(null);
            _f?.Dispose(); _f = null; _off = 0; _init = false;
            HostTotals = null;
            _altLast = -2; _altSeg = 0;
            _mn = _mi = _mt = _mit = _frame = _t = _alloc = _allocGpu = _xn = 0;
            _gcN = 0; _gcPause = default;
            _rb = _bp = _draw = _pass = _up = _rw = _pso = _psoNs = 0; _miss = 0;
            NxRenderer.CreatedN = 0;
        }

        [UnmanagedCallersOnly]
        static void DirectSample(ulong c, long* o)
        {
            try
            {
                o[0] = GC.GetTotalAllocatedBytes(false); o[1] = GC.CollectionCount(0); o[2] = GC.CollectionCount(1); o[3] = GC.CollectionCount(2);
                o[4] = GC.GetTotalPauseDuration().Ticks / 10;   // 不取本线程分配：上屏线程没有托管分配（见 host_adapt.m）
                if ((int)o[1] != _gcN && c > 1) GcLine((long)c);
                _gcN = (int)o[1];
            }
            catch (Exception e) { N.s2a_direct_frame_sample_set(null); Console.Error.WriteLine($"[gal] 【红】直连分配 / GC 采样出错、停采：{e}"); }
        }

        static int U(Span<byte> b, int n, ulong v, char sep) { Utf8Formatter.TryFormat(v, b[n..], out int w); n += w; b[n++] = (byte)sep; return n; }

        static void Init()
        {
            _init = true;
            string p = Environment.GetEnvironmentVariable("S2A_FRAMES_TSV");
            if (string.IsNullOrEmpty(p)) return;
            try
            {
                p = NxColdStart.Doc(p);   // 契约给相对名 frames.tsv：落 Documents
                _f = File.OpenHandle(p, FileMode.Create, FileAccess.Write, FileShare.Read);
                byte[] h = System.Text.Encoding.ASCII.GetBytes(Head); RandomAccess.Write(_f, h, 0); _off = h.Length;
            }
            catch (Exception e) { Console.Error.WriteLine($"[gal] 【红】frames.tsv 打不开（{p}）：{e.Message}"); _f = null; }
        }
    }
}
