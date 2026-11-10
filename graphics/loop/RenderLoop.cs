// S2Arm 的渲染循环：Ryujinx 里游戏经 nvdrv SubmitGpfifo 交上来的命令只进 GPFifo 队列，要有一条 GPU 线程反复取出执行、上屏
// （Ryujinx 桌面版 WindowBase.RenderLoop：WaitFifo → ProcessFrame（着色器队列 / PreFrame / DispatchCalls）→ ConsumeFrameAvailable → PresentFrame）。
// 本线程就是 Ryujinx 的「GPU 线程」（SetGpuThread）。唤醒时、以及 DispatchCalls 里每个入队晚于上次排空的命令执行前，在本线程排空写跟踪
//（NxTrack.Drain，经 GPFifoDevice.S2ASync，补丁 0114）：单线程排空，覆盖到「提交之前」游戏线程的写，GPU 层读客体内存时缓存已失效。
using NxGal;
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.HLE;
using Ryujinx.Memory.Tracking;
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace S2A.Gfx
{
    public static class FramePacingPolicy
    {
        public static int ParseLimit(string configuredValue)
        {
            // 与直连 graphics/nvn/gfx/nvn/nvn_fps.c nvn_fps_parse 同口径：未设 / "0" = 不限；24–1000 的十进制整数（不带符号、空格或尾随字符）
            if (configuredValue is null or "0") return 0;
            int value = 0;
            bool ok = configuredValue.Length is > 0 and <= 4;
            foreach (char c in configuredValue) { if (c is < '0' or > '9') { ok = false; break; } value = value * 10 + (c - '0'); }
            if (!ok || value < MinLimit || value > MaxLimit)
                throw new ArgumentOutOfRangeException(nameof(configuredValue), configuredValue, $"S2A_FPS must be 0 or an integer {MinLimit}-{MaxLimit}.");
            return value;
        }

        public const int MinLimit = 24, MaxLimit = 1000;
        static bool Valid(int fps) => fps == 0 || fps is >= MinLimit and <= MaxLimit;

        public static int SwapIntervalFloor(int fps, long targetVsyncInterval)
        {
            if (!Valid(fps)) throw new ArgumentOutOfRangeException(nameof(fps));
            if (fps == 0) return 0;
            // 生产端下限取「不慢于上限」的最大交换间隔：floor(vsync / 上限)，至少 1。30 / 60 / 120 与原来的四舍五入同值（2 / 1 / 1）；
            //   非整除的档（如 40：floor 1.5 = 1）不能四舍五入成 2，那会把生产端压到 30 帧、比上限还慢
            return Math.Max(1, (int)Math.Floor((double)targetVsyncInterval / fps));
        }

        public static float MinimumPresentationInterval(float gameIntervalSeconds, int fps)
        {
            if (!Valid(fps)) throw new ArgumentOutOfRangeException(nameof(fps));
            return fps == 0 ? gameIntervalSeconds : Math.Max(gameIntervalSeconds, 1f / fps);
        }
    }

    public static unsafe class RenderLoop
    {
        static volatile bool _active, _started; static bool _producerStopped; static CancellationTokenSource _cts; static readonly ManualResetEventSlim _done = new(), _gpuDone = new();
        // 双线程渲染（缺省开；S2A_THREADED=0 关回单线程）：渲染器套 Ryujinx 原版 ThreadedRenderer——GPU 模拟（命令解析 / NxTrack.Drain / DispatchCalls）一条线程（S2A.GPU.Emu），
        // NxGal Metal 编码在本线程（S2A.GPU）消费命令队列。两条都按 S2A_GPU_QOS 档原生起（ThreadedRenderer.S2AStartThread）。套层在 services/aot/Compose.cs
        // 10-20 测试设备2 动森（都开游戏模式）：开 2.99 W / 关 3.40 W、性能核 2.27 → 1.67 GHz；Mac 关键线程 8.5–10 → 5.0–5.7 ms/帧
        public static readonly bool Threaded = Environment.GetEnvironmentVariable("S2A_THREADED") != "0";
        static int _qos;
        static Switch _device; static MemoryTracking _tracking; static int _fpsLimit;
        static nint _renderThread, _emulationThread;

        // S2A_Init 起完 Ryujinx（Host.Boot）、游戏登记（Application.Register）之后调一次。tracking = GuestMemory.Tracking（写跟踪排空用）
        public static void Start(Switch device, MemoryTracking tracking)
        {
            if (_started) throw new InvalidOperationException("渲染循环已启动");
            int fpsLimit = FramePacingPolicy.ParseLimit(Environment.GetEnvironmentVariable("S2A_FPS"));
            int minSwapInterval = FramePacingPolicy.SwapIntervalFloor(fpsLimit, device.TargetVSyncInterval);
            // 宏执行：NativeAOT（Mac 宿主 / iOS）不支持动态代码，Ryujinx 缺省开的宏 JIT（MacroJitCompiler 用 Reflection.Emit）一跑就抛
            // PlatformNotSupportedException（M0 动森 Mac 渲染线程崩在这）。关掉后走补丁 0004 的离线宏表，没命中落 Ryujinx 解释器
            GraphicsConfig.EnableMacroJit = false;
            NxFrames.HostTotals = &MacroTotals;   // frames.tsv 的 macro_* 列
            _done.Reset(); _gpuDone.Reset();
            _active = true; _started = true; _producerStopped = false; _cts = new CancellationTokenSource(); _device = device; _tracking = tracking;
            lock (_fiTicks) { Array.Clear(_fiTicks); _fiCur = -1; _fiChanges = 0; _fiT0 = 0; _fiSealed = false; }
            NxTrack.Init(tracking);   // 写跟踪 A 方案：游戏写 GPU 改过的页时当场回写（缺页改道回调）
            // 写跟踪排空挂到 GPFIFO：每个命令处理前，若它入队晚于上次排空就先排空（GPFifoDevice.S2ATrackSync，补丁 0114）
            Ryujinx.Graphics.Gpu.Engine.GPFifo.GPFifoDevice.S2ATrackSync = () => NxTrack.Drain(tracking);
            // 线程按核（方案 8a-3）：GPU 线程用用户交互档 QoS（调度器优先放性能核）。.NET 自己建的线程设不了 QoS（EPERM），由渲染器按 QoS 建原生线程回调这里
            // S2A_GPU_QOS（能耗减法实验，缺省不变）：interactive / initiated / utility——10-20 原生层整机录像：新包游戏进程 74% 在性能核（旧包 34%），S2A.GPU 0.39 核全在性能核
            int qos = Environment.GetEnvironmentVariable("S2A_GPU_QOS") switch { "initiated" => QOS_CLASS_USER_INITIATED, "utility" => QOS_CLASS_UTILITY, _ => QOS_CLASS_USER_INTERACTIVE };
            if (qos != QOS_CLASS_USER_INTERACTIVE) Console.Error.WriteLine($"[gal] 渲染线程 QoS {qos:x}（S2A_GPU_QOS，能耗减法实验）");
            _qos = qos;
            // 帧率：保留 S2A_FPS 的生产端交换间隔下限，避免较低档把已算完的游戏帧扔掉；呈现端也应用同一帧率上限，覆盖游戏请求 swapInterval=0 的情况。
            // 120 档只把宿主呈现间隔降到 1/120，不改变 TargetVSyncInterval 或游戏逻辑节拍。
            _fpsLimit = fpsLimit;
            Ryujinx.HLE.HOS.Services.SurfaceFlinger.S2AFramePacing.MinSwapInterval = minSwapInterval;
            if (_fpsLimit > 0)
            {
                Console.Error.WriteLine($"[gal] 帧率上限 S2A_FPS={_fpsLimit}：交换间隔下限 {minSwapInterval}（vsync {device.TargetVSyncInterval} Hz）");
            }
            // 生效间隔每变一次打一行「帧节拍」（固定格式，测试出包线执行器按正则取帧率格的目标帧率，代替按款查表；交换间隔 0 = 游戏关 vsync，执行器按 60 判。格式别改）
            Ryujinx.HLE.HOS.Services.SurfaceFlinger.S2AFramePacing.FrameIntervalChanged = FrameInterval;
            if (Threaded) Ryujinx.Graphics.GAL.Multithreading.ThreadedRenderer.S2AStartThread = StartNative;
            // 遍统计 NXGAL_PSTAT=1（诊断，缺省关）：游戏每次提交的 GPFIFO 命令段交渲染器统计「落在没变的页上」的比例（graphics/metal/gal_pstat.m）
            if (NxPassStat.On) Ryujinx.Graphics.Gpu.Engine.GPFifo.GPFifoDevice.S2ASegmentHook = &PstatSegment;
            int rc; fixed (byte* n = "S2A.GPU\0"u8) rc = NxThread.StartJoinable(&Entry, 0, qos, n, out _renderThread);
            if (rc != 0)
            {
                _active = false; _done.Set(); _gpuDone.Set();
                throw new InvalidOperationException($"渲染线程建不起来（{rc}）");
            }
        }

        // 第一阶段只取消生产循环并唤醒 FIFO。资源必须保留到客体线程、服务线程和图形线程都退出。
        public static void RequestStop()
        {
            if (!_started) return;
            _active = false;
            _cts.Cancel();
            _device.Gpu.GPFifo.Interrupt();
        }

        // 停生产者并 join，保留编码线程：随后 GpuContext.Dispose 会产生资源释放命令，必须仍有人消费。
        public static void StopProducer()
        {
            if (!_started || _producerStopped) return;
            RequestStop();
            if (Threaded)
            {
                if (!_gpuDone.Wait(3000)) throw new TimeoutException("GPU 模拟线程 3 秒内没停下；旧会话资源不能释放");
                NxThread.Join(ref _emulationThread);
            }
            else
            {
                if (!_done.Wait(3000)) throw new TimeoutException("渲染循环 3 秒内没停下；旧会话资源不能释放");
                NxThread.Join(ref _renderThread);
            }
            _producerStopped = true;
            // Services and Device disposal can outlive the ordinary-exit
            // fallback. Seal the final pacing line once the producer joined.
            FrameIntervalSummary();
        }

        public static void EnsureRetirementBackend()
        {
            if (_started && !_producerStopped)
                throw new InvalidOperationException("GPU 生产者尚未 join，不能投递资源析构");
            if (_started && Threaded && _renderThread == 0)
                throw new InvalidOperationException("编码消费者已退出；不能再向旧图形队列投递资源析构");
        }

        // GPU 析构后，或普通进程退出保留资源时，排空已有命令并停止编码线程。
        public static void StopBackend()
        {
            if (!_started) return;
            if (!_producerStopped) throw new InvalidOperationException("GPU 生产者尚未停止，不能释放渲染器");
            long end = Environment.TickCount64 + 3000;
            if (Threaded && _device.Gpu.Renderer is Ryujinx.Graphics.GAL.Multithreading.ThreadedRenderer threaded)
            {
                threaded.S2ADrainForShutdown(3000);
                threaded.S2AStopBackend();
            }
            if (!_done.Wait((int)Math.Max(0, end - Environment.TickCount64))) throw new TimeoutException("渲染循环 3 秒内没停下；旧会话资源不能释放");
            NxThread.Join(ref _renderThread);
        }

        // 第二阶段：调用方已完成服务和 GpuContext.Dispose，才解绑引用旧局的回调。
        public static void ResetSession()
        {
            if (_renderThread != 0 || _emulationThread != 0) throw new InvalidOperationException("图形线程尚未 join");
            Ryujinx.Graphics.Gpu.Engine.GPFifo.GPFifoDevice.S2ATrackSync = null;
            Ryujinx.Graphics.Gpu.Engine.GPFifo.GPFifoDevice.S2ASegmentHook = null;
            Ryujinx.Graphics.GAL.Multithreading.ThreadedRenderer.S2AStartThread = null;
            Ryujinx.HLE.HOS.Services.SurfaceFlinger.S2AFramePacing.FrameIntervalChanged = null;
            Ryujinx.HLE.HOS.Services.SurfaceFlinger.S2AFramePacing.MinSwapInterval = 0;
            _cts?.Dispose(); _cts = null; _device = null; _tracking = null;
            _started = false; _active = false; _producerStopped = false; _fpsLimit = 0;
            lock (_fiTicks) { Array.Clear(_fiTicks); _fiCur = -1; _fiChanges = 0; _fiT0 = 0; _fiSealed = true; }
            NxTrack.ResetSession();
            NxFrames.ResetSession();
        }

        // 帧节拍：各生效交换间隔累计时长（下标 = 交换间隔，0..7），收局补一行占时最多的（10-21 塞尔达在 2 / 3 之间来回切，一局 60 多行）
        static readonly long[] _fiTicks = new long[8]; static int _fiCur = -1, _fiChanges; static long _fiT0; static bool _fiSealed = true;
        static string FrameLine(int si) => si > 0 ? $"帧节拍：交换间隔 {si}，每帧 {si * 1000f / _device.TargetVSyncInterval:F1} ms（{(float)_device.TargetVSyncInterval / si:F0} 帧/秒）" : "帧节拍：交换间隔 0，每帧 0.0 ms（0 帧/秒）";
        static void FrameInterval(float sec)
        {
            float mi = FramePacingPolicy.MinimumPresentationInterval(sec, _fpsLimit);
            NxWindowPacing.SetMinInterval(mi);
            // 标称帧率给原生层（自动玩家折算按 30 帧写的路线帧数，runtime/src/ap_host.c）：出图实际跟的节拍 = 1 / 最短显示间隔（游戏交换间隔与 S2A_FPS 地板取大）；
            //   不限（游戏关垂直同步、又没有 S2A_FPS 地板）按 60 报，同 tools/game_fps.py「交换间隔 0 按 60 判」的口径
            NxWindowPacing.SetNominalFps(mi > 0 ? (int)Math.Round(1 / mi) : 60);
            int si = sec > 0 ? Math.Min(7, (int)Math.Round(sec * _device.TargetVSyncInterval)) : 0;
            // 合成线程调；停止生产者后由关闭线程汇总，同一把锁封存最后一行。
            lock (_fiTicks)
            {
                if (_fiSealed) return; // Already-captured callbacks must not replace the final line.
                long now = System.Diagnostics.Stopwatch.GetTimestamp();
                if (_fiCur >= 0) _fiTicks[_fiCur] += now - _fiT0;
                _fiCur = si; _fiT0 = now;
                // 限频：前 32 次变化照记，之后每 1000 次一行（同出图日志限频）
                if (_fiChanges++ < 32 || _fiChanges % 1000 == 0) Console.Error.WriteLine($"[gal] {FrameLine(si)}");
            }
        }
        // 收局：本局占时最多的交换间隔（执行器取 host.log 最后一行「帧节拍」定帧率格目标）
        static void FrameIntervalSummary()
        {
            lock (_fiTicks)
            {
                if (_fiSealed) return;
                _fiSealed = true;
                if (_fiCur < 0) return;
                long now = System.Diagnostics.Stopwatch.GetTimestamp();
                _fiTicks[_fiCur] += now - _fiT0; _fiT0 = now;
                int best = 0; long total = 0;
                for (int i = 0; i < _fiTicks.Length; i++) { total += _fiTicks[i]; if (_fiTicks[i] > _fiTicks[best]) best = i; }
                Console.Error.WriteLine($"[gal] 收局 {FrameLine(best)}，占 {(total > 0 ? 100.0 * _fiTicks[best] / total : 0):F0}%（变化 {_fiChanges} 次）");
            }
        }

        // ThreadedRenderer.S2AStartThread：GPU 模拟线程按渲染线程同档 QoS 原生起（.NET 自己 new Thread 设不了 QoS）
        static void StartNative(string name, Action body)
        {
            GCHandle h = GCHandle.Alloc(body);
            int rc; fixed (byte* n = "S2A.GPU.Emu\0"u8) rc = NxThread.StartJoinable(&BodyEntry, GCHandle.ToIntPtr(h), _qos, n, out _emulationThread);
            if (rc != 0) { h.Free(); throw new InvalidOperationException($"GPU 模拟线程 {name} 建不起来（{rc}）"); }
        }

        [UnmanagedCallersOnly]
        static void BodyEntry(nint arg)
        {
            GCHandle h = GCHandle.FromIntPtr(arg); Action body = (Action)h.Target; h.Free();
            try { body(); }
            catch (Exception e) { Console.Error.WriteLine($"[gal] 【红】GPU 模拟线程异常退出：{e}"); throw; }
            finally { _gpuDone.Set(); }
        }

        // GPFIFO 段（GPU 地址 + 字节）→ CPU 侧连续片（按 4 KB GPU 页翻译、相邻合并），栈上数组，不分配。有未映射页或片超过 64 段：只报字节（未统计）
        static void PstatSegment(Ryujinx.Graphics.Gpu.Memory.MemoryManager mm, ulong gva, ulong size)
        {
            if (size == 0) return;
            const int Max = 64;
            ulong* r = stackalloc ulong[Max * 2]; int n = 0;
            ulong end = gva + size;
            for (ulong va = gva; va < end;)
            {
                ulong next = Math.Min((va | Ryujinx.Graphics.Gpu.Memory.MemoryManager.PageMask) + 1, end);
                ulong pa = mm.Translate(va);
                if (pa == Ryujinx.Graphics.Gpu.Memory.MemoryManager.PteUnmapped) { NxPassStat.Segment(r, -1, size); return; }
                if (n > 0 && r[2 * n - 2] + r[2 * n - 1] == pa) r[2 * n - 1] += next - va;
                else
                {
                    if (n == Max) { NxPassStat.Segment(r, -1, size); return; }
                    r[2 * n] = pa; r[2 * n + 1] = next - va; n++;
                }
                va = next;
            }
            NxPassStat.Segment(r, n, size);
        }

        const int QOS_CLASS_USER_INTERACTIVE = 0x21;
        const int QOS_CLASS_USER_INITIATED = 0x19, QOS_CLASS_UTILITY = 0x11;   // 游戏主线程归原生层、声音 / 服务线程归服务接入线另设

        static void MacroTotals(long* o)
        {
            o[0] = Ryujinx.Graphics.Gpu.Engine.MME.S2AMacroAot.HleN + Ryujinx.Graphics.Gpu.Engine.MME.S2AMacroAot.AotN + Ryujinx.Graphics.Gpu.Engine.MME.S2AMacroAot.InterpN;
            o[1] = Ryujinx.Graphics.Gpu.Engine.MME.S2AMacroAot.InterpN;
            o[2] = Ryujinx.Graphics.Gpu.Engine.MME.S2AMacroAot.HleTicks + Ryujinx.Graphics.Gpu.Engine.MME.S2AMacroAot.AotTicks + Ryujinx.Graphics.Gpu.Engine.MME.S2AMacroAot.InterpTicks;
            o[3] = Ryujinx.Graphics.Gpu.Engine.MME.S2AMacroAot.InterpTicks;
        }

        [UnmanagedCallersOnly]
        static void Entry(nint arg)
        {
            try { Run(_device, _tracking); }
            catch (Exception e) { Console.Error.WriteLine($"[gal] 【红】渲染循环异常退出：{e}"); throw; }
            finally { _done.Set(); }
        }

        static void Run(Switch device, MemoryTracking tracking)
        {
            IRenderer r = device.Gpu.Renderer;
            // 首遇不跳过绘制（10-22）：程序首遇现编 / 基础管线归档没命中都在绘制时阻塞等编完，同 Ryujinx Vulkan 后端（ShaderCollection 用到时等链接完成、从不跳过）。
            //   原先产品局开 NXGAL_FIRST_SKIP / NXGAL_PSO_ASYNC 编好前跳过绘制：被跳过的若是写常驻状态的绘制，状态永久错——八方2 读档进镇整屏青绿
            //   （同存档同路线只关 NXGAL_PSO_ASYNC 即恢复正常，docs/坑记录.md）。两个开关仍可在外部设 1 做对照
            if (Threaded && r is not Ryujinx.Graphics.GAL.Multithreading.ThreadedRenderer) Console.Error.WriteLine("[gal] 【红】双线程渲染开着，但渲染器没套 ThreadedRenderer（Compose.cs）");
            r.Initialize(GraphicsDebugLevel.None);
            if (OperatingSystem.IsIOS() && !NxIosLayer.TryAttach(r))
            {
                // RunLoop has not started GPU emulation. Let Stop observe both
                // threads as finished; the shell keeps the error page/diagnostics.
                _active = false; _cts.Cancel(); _gpuDone.Set();
                return;
            }
            ShaderPack.Mount();   // 着色器包：渲染器初始化之后（开离线库要 Metal 设备）、Ryujinx 读着色器磁盘缓存之前
            NxProgram.WarmInternal();   // 渲染器内部管线预建：不让它们落进首局（10-20 M2 首局要求现建 0）
            Console.Error.WriteLine(Threaded ? "[gal] 渲染循环已起（双线程：GPU 模拟线程 S2A.GPU.Emu + Metal 编码线程 S2A.GPU）" : "[gal] 渲染循环已起（单线程 S2A.GPU，S2A_THREADED=0）");
            r.RunLoop(() =>
            {
                device.Gpu.SetGpuThread();
                device.Gpu.InitializeShaderCache(_cts.Token);   // 等 Gpu.HostInitalized（游戏登记时置）：照 Ryujinx 加载器顺序
                bool at = Ryujinx.Graphics.Gpu.S2AAllocTrace.On;   // S2A_ALLOC_TRACE=1：渲染循环四段各计本线程分配，每 20 秒打一行（与 GPFIFO 分派点拆账对照）
                long[] seg = new long[6]; long next = System.Diagnostics.Stopwatch.GetTimestamp() + System.Diagnostics.Stopwatch.Frequency * 20, presents = 0;
                while (_active)
                {
                    NxAutorelease.Cycle();   // GPU 模拟线程没有释放池：每轮放掉上一轮 GAL 入口里自动释放的对象（见 gal_core.m nxgal_pool_cycle）
                    Ryujinx.Common.S2AThreadAlloc.Tick("渲染");   // 服务接入线：按线程拆账（各线程之和对整进程）
                    long a0 = at ? GC.GetAllocatedBytesForCurrentThread() : 0;
                    if (device.WaitFifo())
                    {
                        long a1 = at ? GC.GetAllocatedBytesForCurrentThread() : 0;
                        device.Gpu.GPFifo.S2ASync();
                        long a2 = at ? GC.GetAllocatedBytesForCurrentThread() : 0;
                        if (!at) device.ProcessFrame();
                        else
                        {   // 与 Switch.ProcessFrame 同序的三步，分开计
                            device.Gpu.ProcessShaderCacheQueue(); long b1 = GC.GetAllocatedBytesForCurrentThread();
                            device.Gpu.Renderer.PreFrame(); long b2 = GC.GetAllocatedBytesForCurrentThread();
                            device.Gpu.GPFifo.DispatchCalls(); long a3 = GC.GetAllocatedBytesForCurrentThread();
                            seg[0] += a1 - a0; seg[1] += a2 - a1; seg[2] += a3 - a2; seg[4] += b1 - a2; seg[5] += b2 - b1; a0 = a3;
                        }
                    }
                    else if (at) { long a1 = GC.GetAllocatedBytesForCurrentThread(); seg[0] += a1 - a0; a0 = a1; }
                    while (device.ConsumeFrameAvailable()) { device.PresentFrame(null); presents++; }
                    if (at)
                    {
                        seg[3] += GC.GetAllocatedBytesForCurrentThread() - a0;
                        if (System.Diagnostics.Stopwatch.GetTimestamp() >= next)
                        {
                            Console.Error.WriteLine($"[分配·渲染循环] 近 20 秒 上屏 {presents} 次：WaitFifo {seg[0]} B、NxTrack.Drain {seg[1]} B、ProcessFrame {seg[2]} B（着色器队列 {seg[4]}、PreFrame {seg[5]}、DispatchCalls {seg[2] - seg[4] - seg[5]}）、PresentFrame {seg[3]} B");
                            long[] q = Ryujinx.Graphics.GAL.S2ATexArrReuse.Diag;
                            Console.Error.WriteLine($"[分配·贴图数组] 累计 KB：池未命中 {q[0] >> 10}、宽屏 Unwrap {q[1] >> 10}、入队 ToArray {q[2] >> 10}、执行 ToArray {q[3] >> 10}、Gpu 复用路径新建 {q[4] >> 10}、Gpu 关时新建 {q[5] >> 10}（图像数组复用 {(Ryujinx.Graphics.GAL.S2ATexArrReuse.ImgOn ? "开" : "关")}）");
                            Array.Clear(seg); presents = 0; next = System.Diagnostics.Stopwatch.GetTimestamp() + System.Diagnostics.Stopwatch.Frequency * 20;
                        }
                    }
                }
                // 双线程：退出前把已排进队列的命令执行完（照 Ryujinx 桌面版 AppHost 收尾），收局停渲染线程时队列是空的
                if (r is Ryujinx.Graphics.GAL.Multithreading.ThreadedRenderer t) t.FlushThreadedCommands();
            });
            {
                long lt = Ryujinx.Graphics.Gpu.Engine.GPFifo.S2ASegStats.LongTotal, ls = Ryujinx.Graphics.Gpu.Engine.GPFifo.S2ASegStats.LongSkipped;
                Console.Error.WriteLine($"[段缓存] 长段 {lt}，跳过哈希直接解读 {ls}（{(lt > 0 ? 100.0 * ls / lt : 0):F0}%），进入跳过 {Ryujinx.Graphics.Gpu.Engine.GPFifo.S2ASegStats.SkipRounds} 次");
            }
            Console.Error.WriteLine(Threaded ? $"[gal] 渲染循环已停（双线程；非 GPU 线程直调下层 {Ryujinx.Graphics.GAL.Multithreading.ThreadedRenderer.S2AOffThreadCalls} 次）" : "[gal] 渲染循环已停");
        }
    }
}
