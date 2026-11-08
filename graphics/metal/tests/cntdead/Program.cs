// t_cntdead：计数结果回调换线程单测（10-21 帧率能耗线）。
// 复现马车8 / 塞尔达「出图停」11 局的互等：游戏线程（nx-81）拿着写跟踪锁在 ThreadedRenderer.WaitSync 里等渲染线程处理建同步号，
// 渲染线程处理 PreFrame 时在计数结果回调里（Gpu 层 CounterReport.OnResult 写客体内存）要同一把锁。修前渲染线程直接调回调 → 两边互等；
// 修后回调在计数线程（NxGal.Counter）上调，渲染线程不碰这把锁。写跟踪锁用一个普通锁对象替身（MemoryTracking.TrackingLock 是 internal）。
// 另核 Flush 的约定：返回时回调已做完（Gpu 层随后读客体内存里的结果，如条件渲染）。
// 真 ThreadedRenderer（含 Ryujinx 补丁 0129 的计数事件池）+ 真 Metal 渲染器（NxGal + libnxgal.dylib）。用法：bash build_run.sh
using NxGal;
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.GAL.Multithreading;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Threading;

static class Program
{
    static int s_total, s_fail;
    static ThreadedRenderer s_th;
    static readonly BlockingCollection<Action> s_gpuWork = new();

    static void Check(string what, bool ok, string got)
    {
        s_total++;
        if (!ok) s_fail++;
        Console.WriteLine($"{(ok ? "通过" : "失败")} {what}：{got}");
    }

    static void Finish()
    {
        Console.WriteLine($"t_cntdead：{s_total} 项，失败 {s_fail}");
        Console.Out.Flush();
        // 卡死的线程不让进程正常退出：直接结束
        Environment.Exit(s_fail == 0 ? 0 : 1);
    }

    // 命令只能由 GPU 线程（ThreadedRenderer 的生产者）排：交给它做，等做完（上限 ms）
    static bool OnGpu(Action a, int ms = 3000)
    {
        using ManualResetEventSlim done = new(false);
        s_gpuWork.Add(() => { a(); done.Set(); });
        return done.Wait(ms);
    }

    static void Main()
    {
        NxRenderer nx = new();
        nx.Initialize(GraphicsDebugLevel.None);

        // ⑤ 单线程渲染口径（S2A_THREADED=0，不套 ThreadedRenderer）：Flush 返回时回调已做完、只调一次，在计数线程上
        {
            int calls = 0; string thr = null;
            ICounterEvent e = nx.ReportCounter(CounterType.SamplesPassed, (s, v) => { thr = Thread.CurrentThread.Name; Interlocked.Increment(ref calls); }, 1f, false);
            nx.PreFrame();
            e.Flush();
            int atFlush = Volatile.Read(ref calls);
            Thread.Sleep(50);
            Check("⑤ 单线程：Flush 返回时回调已做完、只调一次、在计数线程", atFlush == 1 && calls == 1 && thr == "NxGal.Counter", $"Flush 返回时 {atFlush} 次、50 ms 后 {calls} 次，线程 {thr}");
            e.Dispose();
        }

        s_th = new ThreadedRenderer(nx);
        new Thread(() => s_th.RunLoop(() => { foreach (Action a in s_gpuWork.GetConsumingEnumerable()) a(); })) { Name = "S2A.GPU", IsBackground = true }.Start();

        // ① 互等：游戏线程持锁等同步号，渲染线程处理 PreFrame 时的回调要同一把锁
        {
            object trackingLock = new();
            using ManualResetEventSlim handled = new(false);
            string thr = null;
            ICounterEvent e = null;
            OnGpu(() => e = s_th.ReportCounter(CounterType.SamplesPassed, (s, v) => { lock (trackingLock) { } thr = Thread.CurrentThread.Name; handled.Set(); }, 1f, false));
            using ManualResetEventSlim waited = new(false);
            new Thread(() =>
            {
                lock (trackingLock)
                {
                    // 同卡死现场的次序：报计数（上面）→ PreFrame 取结果 → 建同步号；游戏线程持锁等这个同步号
                    OnGpu(() => { s_th.PreFrame(); s_th.CreateSync(1, false); });
                    s_th.WaitSync(1);
                }
                waited.Set();
            }) { Name = "nx-81", IsBackground = true }.Start();
            bool ok = waited.Wait(5000);
            Check("① 游戏线程持写跟踪锁等同步号：5 秒内等到（不互等）", ok, ok ? "等到" : "5 秒没等到——渲染线程在回调里等锁、游戏线程持锁等渲染线程（马车8 / 塞尔达出图停同一卡法）");
            if (!ok) Finish();
            bool h = handled.Wait(3000);
            Check("① 锁放开后回调做完、在计数线程上调", h && thr == "NxGal.Counter", $"做完 {h}，线程 {thr}");
            OnGpu(() => e.Dispose());
        }

        // ② Flush 等回调做完：回调已开始（结果已取走）但还没写完时，GPU 线程上的 Flush 不能返回
        {
            using ManualResetEventSlim entered = new(false), gate = new(false), flushed = new(false);
            int wrote = 0, seen = -1;
            ICounterEvent e = null;
            OnGpu(() => e = s_th.ReportCounter(CounterType.SamplesPassed, (s, v) => { entered.Set(); gate.Wait(5000); Volatile.Write(ref wrote, 1); }, 1f, false));
            OnGpu(() => s_th.PreFrame());
            bool en = entered.Wait(3000);
            s_gpuWork.Add(() => { e.Flush(); seen = Volatile.Read(ref wrote); flushed.Set(); });
            bool early = flushed.Wait(300);
            gate.Set();
            bool fin = flushed.Wait(3000);
            Check("② 回调做到一半时 Flush 不返回，返回时回调已写完", en && !early && fin && seen == 1, $"回调开始 {en}，300 ms 内返回 {early}，最终返回 {fin}，返回时已写 {seen}");
            OnGpu(() => e.Dispose());
        }

        // ③ 次序与次数：300 次报计数（每 7 次 PreFrame 一次）、最后一次 Flush。每个回调恰好一次、按报的次序、都在计数线程；事件用完放手（走 0129 事件池）
        {
            const int N = 300;
            int[] calls = new int[N];
            List<int> order = new();
            HashSet<string> threads = new();
            ICounterEvent[] evs = new ICounterEvent[N];
            OnGpu(() =>
            {
                for (int i = 0; i < N; i++)
                {
                    int k = i;
                    evs[i] = s_th.ReportCounter(CounterType.SamplesPassed, (s, v) => { Interlocked.Increment(ref calls[k]); lock (order) { order.Add(k); threads.Add(Thread.CurrentThread.Name); } }, 1f, false);
                    if (i % 7 == 6) s_th.PreFrame();
                }
            });
            OnGpu(() => evs[N - 1].Flush());
            int once = 0; for (int i = 0; i < N; i++) if (calls[i] == 1) once++;
            bool inOrder = true; lock (order) for (int i = 1; i < order.Count; i++) if (order[i] <= order[i - 1]) inOrder = false;
            Check("③ Flush 最后一次后：每个回调恰好一次、按报的次序、只在计数线程", once == N && inOrder && threads.Count == 1 && threads.Contains("NxGal.Counter"),
                $"恰好一次 {once}/{N}，次序 {(inOrder ? "对" : "乱")}，线程 {string.Join(",", threads)}");
            OnGpu(() => { foreach (ICounterEvent e in evs) e.Dispose(); });
        }

        Finish();
    }
}
