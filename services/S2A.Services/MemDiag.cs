using System;
using System.Threading;
using System.Runtime;
using System.Runtime.InteropServices;

namespace S2A.Services
{
    // 内存诊断（总指挥 10-20：iPhone 内存约束要量清，不猜）：起局打一行 GC 配置与进程内存，OOM 时把同一份读数贴进报红。
    //   S2A_MEMPROBE=1：起局先做定点探测——单块托管数组最大能拿多大、按 256 MB 一块累计（写满、真占物理内存）能拿多少，逐块打读数（被系统杀掉时最后一行就是上限附近）
    public static unsafe class MemDiag
    {
        // 分堆峰值（10-26 GC 硬上限：只给总上限时 SOH 段 = 上限、LOH / POH 段各取 2 倍，开局多保留约 10 GB 低区；
        //   攒九款 SOH / LOH / POH 峰值后改按分堆上限收回地址）。读的是最近一次回收后的各代大小，按快照取最大
        private static long _peakSoh, _peakLoh, _peakPoh;
        private static readonly ManualResetEventSlim _monitorStop = new(false, 0);
        private static Thread _monitorThread;
        // 平台装配登记的进程足迹读数（HostConfiguration.MemoryFootprint，#1073）：登记了就只用它，不再落到 libSystem；
        //   旧入口（Mac / iOS 不带配置起局）不登记，照旧读 proc_pid_rusage。Host 起局登记、会话结束清掉
        internal static Func<long> FootprintProvider;

        static MemDiag()
        {
            Ryujinx.Common.S2AShutdown.OnRequest(_monitorStop.Set);
        }

        private static string Heaps(GCMemoryInfo g)
        {
            ReadOnlySpan<GCGenerationInfo> gi = g.GenerationInfo;
            if (gi.Length < 5)
            {
                return "分堆 取不到";
            }

            long soh = gi[0].SizeAfterBytes + gi[1].SizeAfterBytes + gi[2].SizeAfterBytes, loh = gi[3].SizeAfterBytes, poh = gi[4].SizeAfterBytes;
            _peakSoh = Math.Max(_peakSoh, soh);
            _peakLoh = Math.Max(_peakLoh, loh);
            _peakPoh = Math.Max(_peakPoh, poh);
            return $"分堆（上次回收后）SOH {Mb(soh)} / LOH {Mb(loh)} / POH {Mb(poh)}、峰值 {Mb(_peakSoh)} / {Mb(_peakLoh)} / {Mb(_peakPoh)}";
        }

        public static string Snapshot()
        {
            GCMemoryInfo g = GC.GetGCMemoryInfo();

            return $"GC 堆 {Mb(g.HeapSizeBytes)}、已提交 {Mb(g.TotalCommittedBytes)}、{Heaps(g)}、GC 认定可用上限 {Mb(g.TotalAvailableMemoryBytes)}、高负载阈值 {Mb(g.HighMemoryLoadThresholdBytes)}、内存负载 {Mb(g.MemoryLoadBytes)}；" +
                   $"进程足迹 {(Footprint() is long f && f >= 0 ? Mb(f) : "取不到（当前平台不提供此指标）")}、系统给本进程剩余 {(Available() is long a && a > 0 ? Mb(a) : "取不到（当前平台不提供此指标）")}；" +
                   $"GC 次数 {GC.CollectionCount(0)} / {GC.CollectionCount(1)} / {GC.CollectionCount(2)}（0 / 1 / 2 代）、累计停顿 {GC.GetTotalPauseDuration().TotalMilliseconds:F0} ms、累计分配 {Mb(GC.GetTotalAllocatedBytes())}；" +
                   $"GCSegmentSize {Environment.GetEnvironmentVariable("DOTNET_GCSegmentSize") ?? "未设"}、" +
                   $"服务器 GC {(GCSettings.IsServerGC ? "是" : "否")}、GCHeapHardLimit {Environment.GetEnvironmentVariable("DOTNET_GCHeapHardLimit") ?? AppContext.GetData("GCHeapHardLimit") ?? "未设"}、GCHeapHardLimitPercent {AppContext.GetData("GCHeapHardLimitPercent") ?? "未设"}";
        }

        // 托管堆 OutOfMemoryException 第一次出现时当场打原生地址表（vawin.c s2a_oom_dump：低区全列、窗口尾部逐块、按标签合计）。
        //   挂 FirstChanceException：服务层（IPC 里）与 GPU 模拟线程两条路都抓得到；只第一次，处理函数里不做托管分配（地址表由原生层直接写日志）。
        //   10-24 异度神剑3 真机：低区还有 580 MB 整块、GC 却拿不到 32 MB 新段，要现场地址表才能分清是新段落进窗口尾部还是别的保留挡住
        private static delegate* unmanaged<byte*, void> _oomDump;
        private static int _oomDumped;
        private static int _oomInstalled;

        public static void InstallOomDump()
        {
            _oomDumped = 0;
            _peakSoh = _peakLoh = _peakPoh = 0;
            if (Interlocked.Exchange(ref _oomInstalled, 1) != 0) return;
            if (!System.Runtime.InteropServices.NativeLibrary.TryGetExport(System.Runtime.InteropServices.NativeLibrary.GetMainProgramHandle(), "s2a_oom_dump", out nint f))
            {
                return;
            }

            _oomDump = (delegate* unmanaged<byte*, void>)f;
            AppDomain.CurrentDomain.FirstChanceException += static (_, e) =>
            {
                if (e.Exception is OutOfMemoryException && Interlocked.Exchange(ref _oomDumped, 1) == 0)
                {
                    fixed (byte* w = "托管 OOM\0"u8)
                    {
                        _oomDump(w);
                    }
                }
            };

            // S2A_OOM_SELFTEST=1（诊断正对照）：超过数组上限必抛 OutOfMemoryException，验钩子能打出地址表
            if (Environment.GetEnvironmentVariable("S2A_OOM_SELFTEST") == "1")
            {
                try
                {
                    _ = new byte[int.MaxValue];
                }
                catch (OutOfMemoryException)
                {
                }
            }
        }

        private static string Mb(long b) => $"{b >> 20} MB";

        // 读数来自 libSystem（苹果平台独有）：别的平台不碰 P/Invoke，直接回「取不到」-1（审计 #859：原先无条件调，Linux 上
        //   Host.Boot 里抛 DllNotFoundException，单测主程序在 try 之外直接崩）
        private static bool HasLibSystem => OperatingSystem.IsMacOS() || OperatingSystem.IsIOS() || OperatingSystem.IsMacCatalyst();

        // proc_pid_rusage(RUSAGE_INFO_V2) 的 ri_phys_footprint（偏移 72：uuid 16 + 7 个 u64）：jetsam 按它算
        public static long Footprint()
        {
            if (FootprintProvider is Func<long> provider)
            {
                return provider() is long f && f > 0 ? f : -1;
            }

            if (!HasLibSystem)
            {
                return -1;
            }

            byte* ri = stackalloc byte[256];

            return proc_pid_rusage(Environment.ProcessId, 2, ri) == 0 ? *(long*)(ri + 72) : -1;
        }

        // os_proc_available_memory：只有 iOS 有（Mac 上没有这个符号）
        public static long Available()
        {
            if (!OperatingSystem.IsIOS())
            {
                return -1;
            }

            try
            {
                return (long)os_proc_available_memory();
            }
            catch (EntryPointNotFoundException)
            {
                return -1;
            }
        }

        public static void Stop()
        {
            _monitorStop.Set();
            if (_monitorThread != null && !_monitorThread.Join(3000))
            {
                throw new TimeoutException("内存诊断线程未停止，不能释放当前会话");
            }
            _monitorThread = null;
        }

        public static void Startup()
        {
            Stop();
            Console.Error.WriteLine($"[S2A 内存] 起局：{Snapshot()}");
            bool heapAudit = Environment.GetEnvironmentVariable("S2A_HEAP_AUDIT") == "1";
            if (heapAudit)
            {
                Console.Error.WriteLine("[S2A 堆审计] 已开启：每 30 秒主动阻塞回收全堆，供调试器在 GC 结束前读取；本局不用于正常回收停顿或帧率比较。");
            }

            if (Environment.GetEnvironmentVariable("S2A_MEMPROBE") == "1")
            {
                Probe();
            }

            // 每 30 秒一行（GC 次数 / 累计停顿 / 进程足迹随局走势；GC 段大小等配置的 A/B 读这个）
            // 开发设施（11-07 质量线）：玩家口径（原生层 s2a_dev_on 判 0 并导出 S2A_DEV_FACILITIES=0）不起这条周期账线程；堆审计显式要时照起
            if (Environment.GetEnvironmentVariable("S2A_DEV_FACILITIES") == "0" && !heapAudit)
            {
                Console.Error.WriteLine("[S2A 内存] 开发设施关（玩家口径）：不起 30 秒周期账线程");
                return;
            }
            _monitorStop.Reset();
            _monitorThread = new(() =>
            {
                for (int n = 1; ; n++)
                {
                    Ryujinx.Common.S2AThreadAlloc.Tick("内存诊断");   // 按线程拆账
                    if (_monitorStop.Wait(30000)) break;
                    if (heapAudit)
                    {
                        Console.Error.WriteLine($"[S2A 堆审计] 快照 {n} 请求：{DateTime.UtcNow:O}");
                        GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: false);
                        Console.Error.WriteLine($"[S2A 堆审计] 快照 {n} 回收返回：{DateTime.UtcNow:O}");
                    }
                    Console.Error.WriteLine($"[S2A 内存] 第 {n * 30} 秒：{Snapshot()}");
                }
            }) { IsBackground = true, Name = "S2A.MemDiag" };
            _monitorThread.Start();
        }

        private static void Probe()
        {
            // ① 单块：从 Array.MaxLength 往下对半找能分到的最大托管数组（不写，只看 GC 肯不肯给）
            int ok = 0;

            for (long n = Array.MaxLength; n >= 1 << 20; n /= 2)
            {
                try
                {
                    byte[] a = GC.AllocateUninitializedArray<byte>((int)n);
                    ok = a.Length;
                    break;
                }
                catch (OutOfMemoryException)
                {
                    Console.Error.WriteLine($"[S2A 内存] 探测 单块 {n >> 20} MB：OOM");
                }
            }

            GC.Collect();
            Console.Error.WriteLine($"[S2A 内存] 探测 单块最大能分到 {ok >> 20} MB；{Snapshot()}");

            // ② 累计：每块 256 MB、写满（真占物理内存），直到 OOM / 系统剩余 < 512 MB / 12 GB；每块打一行
            System.Collections.Generic.List<byte[]> keep = new();

            try
            {
                for (int i = 0; i < 48; i++)
                {
                    // iPhone：系统给本进程剩余 < 512 MB 就停（再要会被 jetsam 杀、拉不回日志；10-20 测试机2 首次探测局整局没拉回文件）
                    if (Available() is long av && av > 0 && av < 512L << 20)
                    {
                        Console.Error.WriteLine($"[S2A 内存] 探测 累计 {keep.Count * 256} MB 时系统剩余不到 512 MB，停（这就是 jetsam 上限附近）；{Snapshot()}");
                        break;
                    }

                    byte[] a = GC.AllocateUninitializedArray<byte>(256 << 20);
                    a.AsSpan().Fill(1);
                    keep.Add(a);
                    Console.Error.WriteLine($"[S2A 内存] 探测 累计 {keep.Count * 256} MB：{Snapshot()}");
                }
            }
            catch (OutOfMemoryException)
            {
                Console.Error.WriteLine($"[S2A 内存] 探测 累计到 {keep.Count * 256} MB 后再要 256 MB：OOM；{Snapshot()}");
            }

            keep.Clear();
            GC.Collect();
            Console.Error.WriteLine($"[S2A 内存] 探测结束（已释放）：{Snapshot()}");
        }

        [DllImport("/usr/lib/libSystem.B.dylib")] private static extern int proc_pid_rusage(int pid, int flavor, byte* buffer);
        [DllImport("/usr/lib/libSystem.B.dylib")] private static extern nuint os_proc_available_memory();
    }
}
