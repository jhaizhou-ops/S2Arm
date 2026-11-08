using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.GAL.Multithreading;
using System;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;

namespace S2A.Services.Tests
{
    // 双线程渲染（ThreadedRenderer，补丁 0105 / 0106）：下层渲染器（录像 / 宽屏 / NxGal 的 C# 层）按单线程写，由渲染线程独占。
    // 期望来自这条约定本身：渲染线程正在下层里执行命令时，非 GPU 线程直调下层（建贴图）必须等它出来，下层同一时刻最多一条线程在内；
    // 渲染线程连着执行一长串命令时，等锁的非 GPU 线程在一条命令之内拿到（不等整批）；收局 S2AStopBackend 之后 RunLoop 返回（不靠 Dispose）。
    public static unsafe partial class Program
    {
        // 拦 IRenderer 全部调用转给桩渲染器；CreateTexture 记同时在内的线程数，渲染线程第一次进来时停在里面等放行
        public class GateRenderer : DispatchProxy
        {
            public IRenderer Inner;
            public bool Gate = true;
            public int SlowMs;
            public int Inside, MaxInside, Calls;
            public readonly ManualResetEventSlim BackendInside = new(), Release = new();

            protected override object Invoke(MethodInfo m, object[] a)
            {
                if (m.Name != nameof(IRenderer.CreateTexture)) return m.Invoke(Inner, a);
                int n = Interlocked.Increment(ref Inside);
                InterlockedMax(ref MaxInside, n);
                try
                {
                    if (Interlocked.Increment(ref Calls) == 1 && Gate) { BackendInside.Set(); Release.Wait(3000); }
                    else if (SlowMs > 0 && Thread.CurrentThread.Name == "单测渲染线程") Thread.Sleep(SlowMs);
                    return m.Invoke(Inner, a);
                }
                finally { Interlocked.Decrement(ref Inside); }
            }

            static void InterlockedMax(ref int t, int v) { int c; while ((c = Volatile.Read(ref t)) < v && Interlocked.CompareExchange(ref t, v, c) != c) { } }
        }

        private static void ThreadedBackendLock()
        {
            IRenderer proxy = DispatchProxy.Create<IRenderer, GateRenderer>();
            GateRenderer g = (GateRenderer)(object)proxy;
            g.Inner = new StubRenderer();
            ThreadedRenderer tr = new(proxy);
            TextureCreateInfo info = new(4, 4, 1, 1, 1, 1, 1, 4, Format.R8G8B8A8Unorm, DepthStencilMode.Depth, Target.Texture2D,
                SwizzleComponent.Red, SwizzleComponent.Green, SwizzleComponent.Blue, SwizzleComponent.Alpha);
            using ManualResetEventSlim gpuExit = new();
            ITexture queued = null;

            // 渲染线程 = 调 RunLoop 的线程；GPU 线程由 RunLoop 起（S2AStartThread 为空：原样 new Thread），在 GPU 线程上建贴图 = 排进命令队列
            Thread backend = new(() => tr.RunLoop(() => { queued = tr.CreateTexture(info); gpuExit.Wait(5000); })) { IsBackground = true, Name = "单测渲染线程" };
            backend.Start();

            bool inside = g.BackendInside.Wait(3000);
            Task<ITexture> off = Task.Run(() => tr.CreateTexture(info));
            bool blocked = !off.Wait(300);
            g.Release.Set();
            bool offDone = off.Wait(3000);
            Check("双线程渲染：渲染线程在下层建贴图时，非 GPU 线程建贴图被挡住", "渲染线程已进下层、300 ms 内被挡住、放行后建成、下层同时在内最多 1",
                $"{(inside ? "渲染线程已进下层" : "渲染线程没进下层")}、300 ms 内{(blocked ? "被挡住" : "没挡住")}、放行后{(offDone && off.Result != null ? "建成" : "没建成")}、下层同时在内最多 {g.MaxInside}");

            gpuExit.Set();
            tr.FlushThreadedCommands();
            tr.S2AStopBackend();
            bool stopped = backend.Join(1000);
            Check("双线程渲染收局：S2AStopBackend 后 RunLoop 1 秒内返回", "返回", stopped ? "返回" : "没返回");

            // 让锁：GPU 线程排 200 条建贴图命令（下层每条在渲染线程上 3 ms，整批约 600 ms），批中途非 GPU 线程建贴图
            IRenderer proxy2 = DispatchProxy.Create<IRenderer, GateRenderer>();
            GateRenderer g2 = (GateRenderer)(object)proxy2;
            g2.Inner = new StubRenderer(); g2.Gate = false; g2.SlowMs = 3;
            ThreadedRenderer tr2 = new(proxy2);
            using ManualResetEventSlim gpuExit2 = new();
            Thread backend2 = new(() => tr2.RunLoop(() => { for (int i = 0; i < 200; i++) tr2.CreateTexture(info); gpuExit2.Wait(5000); })) { IsBackground = true, Name = "单测渲染线程" };
            backend2.Start();
            SpinWait.SpinUntil(() => Volatile.Read(ref g2.Calls) >= 10, 3000);
            var sw = System.Diagnostics.Stopwatch.StartNew();
            tr2.CreateTexture(info);
            long ms = sw.ElapsedMilliseconds;
            int doneAt = Volatile.Read(ref g2.Calls);
            Check("双线程渲染让锁：渲染线程连着执行命令时，非 GPU 线程建贴图 100 ms 内拿到锁（不等整批）", "≤ 100 ms、批没执行完", $"{(ms <= 100 ? "≤ 100 ms" : $"{ms} ms")}、批{(doneAt < 150 ? "没执行完" : "已执行完")}");
            gpuExit2.Set();
            tr2.FlushThreadedCommands();
            tr2.S2AStopBackend();
            backend2.Join(2000);
        }
    }
}
