// 计数事件（ReportCounter / ICounterEvent）：结果在 C 端出（gal_cnt.m），C# 端按事件编号回调 resultHandler。
using Ryujinx.Graphics.GAL;
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

namespace NxGal
{
    static unsafe partial class N
    {
        [DllImport(Lib)] public static extern uint nxgal_counter_report(int type, float divisor, int hostReserved);
        [DllImport(Lib)] public static extern void nxgal_counter_reset(int type);
        [DllImport(Lib)] public static extern void nxgal_counter_flush(uint ev);
        [DllImport(Lib)] public static extern void nxgal_counter_release(uint ev);
        [DllImport(Lib)] public static extern int nxgal_counter_poll(uint* ids, ulong* values, int max);
        [DllImport(Lib)] public static extern void nxgal_counter_kick();
        [DllImport(Lib)] public static extern int nxgal_counter_wait(int timeoutMs);
        [DllImport(Lib)] public static extern void nxgal_pre_frame();
    }

    // 事件对象复用（每帧零分配：暗黑3 每帧约 18 次遮挡查询，原先每次一个新事件）：Gpu 层的计数缓存放手时 Dispose（不撤销还没出的结果），
    // 「已放手 + 结果回调已做完」两件都成立才回池——此后 Gpu 层再没有引用它。重用时按新查询复位全部字段。
    // 两件在不同线程上发生（回调在计数线程、放手在渲染线程）：两个状态都在计数表锁内转换，后到的一方回池，同一对象不会回池两次
    public sealed class NxCounterEvent : ICounterEvent
    {
        public uint Id { get; private set; }
        internal EventHandler<ulong> Handler;
        readonly NxCounters _owner;
        internal bool Done;
        internal bool Handled;
        internal bool Dropped;
        public bool Invalid { get; set; }
        internal NxCounterEvent(NxCounters owner) { _owner = owner; }
        internal void Reuse(uint id, EventHandler<ulong> h) { Id = id; Handler = h; Done = false; Handled = false; Dropped = false; Invalid = false; }
        public bool ReserveForHostAccess() => true;
        // 返回时结果回调已做完（Gpu 层随后读客体内存里的结果，如条件渲染）：没出结果先在本线程等 GPU 出，再等计数线程把回调做完
        public void Flush()
        {
            uint id = Id;
            if (Volatile.Read(ref Handled)) return;
            if (!Volatile.Read(ref Done)) N.nxgal_counter_flush(id);
            _owner.WaitHandled(this, id);
        }
        public void Dispose() => _owner.Drop(this);
    }

    // 结果回调只在计数线程（NxGal.Counter）上按出结果的顺序调，照 Ryujinx Vulkan（Queries/CounterQueue.cs EventConsumer 的 CPU.CounterQueue 线程）。
    // 回调里 Gpu 层写客体内存，要拿写跟踪锁（MemoryTracking）；渲染线程不能拿：游戏线程会拿着这把锁在 WaitSync 里等渲染线程处理建同步号，两边互等
    //（10-21 马车8 / 塞尔达「出图停」11 局：渲染线程 PreFrame → Update → CounterReport.OnResult 等锁，nx-81 持锁在 RegionHandle.Signal → WaitSync 等渲染线程）。
    // 渲染线程（PreFrame / UpdateCounters）只叫醒计数线程；Flush 在调用线程等 GPU 出结果，再等计数线程把回调做完。
    sealed unsafe class NxCounters
    {
        readonly NxRenderer _r;
        readonly Dictionary<uint, NxCounterEvent> _live = new();
        readonly Stack<NxCounterEvent> _pool = new();
        Thread _thread;
        volatile bool _stop;
        int _waiters;
        public NxCounters(NxRenderer r) => _r = r;

        // 叫醒计数线程取结果（首次调用时起线程；Report 之前不会有结果）
        public void Kick()
        {
            if (_stop) return;
            if (_thread == null) Start();
            N.nxgal_counter_kick();
        }
        void Start()
        {
            lock (_live)
            {
                if (_thread != null || _stop) return;
                _thread = new Thread(Consume) { Name = "NxGal.Counter", IsBackground = true };
                _thread.Start();
            }
        }
        // 照 Ryujinx CounterQueue.EventConsumer：取完就在 C 端等队头出结果（提交 / GPU 做完 / 叫醒都会返回），不靠渲染线程再叫醒（见 gal_cnt.m「计数线程等结果」）
        void Consume()
        {
            while (!_stop)
            {
                Ryujinx.Common.S2AThreadAlloc.Tick("渲染·计数");   // 按线程拆账
                Update();
                N.nxgal_counter_wait(1000);
            }
        }
        public void RequestStop()
        {
            lock (_live) { _stop = true; Monitor.PulseAll(_live); }
            N.nxgal_counter_kick();
        }
        public void StopCallbacks()
        {
            RequestStop();
            if (_thread != null && !_thread.Join(3000)) throw new TimeoutException("计数回调线程未停止；旧客体内存仍可能被写入");
        }
        public void Stop()
        {
            StopCallbacks();
            lock (_live)
            {
                foreach (NxCounterEvent e in _live.Values)
                {
                    e.Invalid = true; e.Handler = null; e.Done = true; e.Handled = true;
                    N.nxgal_counter_release(e.Id);
                }
                _live.Clear(); _pool.Clear(); _thread = null;
            }
        }

        // 等 id 这次查询的回调做完（GPU 已出结果：Flush 先做了 nxgal_counter_flush）。
        // 在计数线程自己身上（回调里 Flush）不等、不重入取结果（t_got 按线程复用，重入会盖掉外层这一批），同修前「已取走就返回」。
        // 编号 0（未知计数类型，C 端不出结果）不等，同修前。
        // 照上游 CounterQueue.FlushTo 一直等到回调做完（提前返回 = 条件渲染读到旧值）。调用方持写跟踪锁时这里会和回调互等：
        // 现有唯一调用方是 Gpu 层条件渲染（ConditionalRendering.CounterNonZero，GPU 模拟线程处理 3D 命令时，不持跟踪锁）；等满 3 秒打一行红，当场暴露新调用方
        internal void WaitHandled(NxCounterEvent e, uint id)
        {
            if (Thread.CurrentThread == _thread) return;
            Kick();
            long t0 = Environment.TickCount64; bool red = false;
            lock (_live)
            {
                _waiters++;
                while (!_stop && e.Id == id && !e.Handled && (e.Done || (id != 0 && _live.ContainsKey(id))))
                {
                    Monitor.Wait(_live, 100);
                    if (!e.Done) N.nxgal_counter_kick();
                    if (!red && Environment.TickCount64 - t0 > 3000)
                    {
                        red = true;
                        Console.Error.WriteLine($"[gal] 【红】计数 Flush 等结果回调已超过 3 秒（查询 {id}，线程 {Thread.CurrentThread.Name}，结果已取走 {e.Done}）：调用方可能持着回调要的锁（写跟踪锁），见 NxCounter.cs 头");
                    }
                }
                _waiters--;
            }
        }

        // _live 加锁：Report 在渲染线程，Update 在计数线程，Drop 在渲染线程，WaitHandled 在 Flush 的调用线程。
        // 报告与登记、取结果与出表各在一次持锁内（否则可能在登记前取走结果、回调永不发生）；回调在锁外调（回调里 Gpu 层写客体内存，不在本锁里等别的锁）
        public ICounterEvent Report(CounterType type, EventHandler<ulong> h, float divisor, bool hostReserved)
        {
            lock (_live)
            {
                NxCounterEvent e = _pool.Count != 0 ? _pool.Pop() : new NxCounterEvent(this);
                e.Reuse(N.nxgal_counter_report((int)type, divisor, hostReserved ? 1 : 0), h);
                _live[e.Id] = e;
                return e;
            }
        }
        public void Reset(CounterType type) => N.nxgal_counter_reset((int)type);
        // Gpu 层放手：结果回调已做完就当场回池，否则等 Update 做完回调再回
        internal void Drop(NxCounterEvent e)
        {
            lock (_live)
            {
                if (e.Dropped) return;
                e.Dropped = true;
                if (e.Handled) { e.Handler = null; _pool.Push(e); }
            }
        }
        [ThreadStatic] static NxCounterEvent[] t_got;
        // 只在计数线程上调（WaitHandled 在计数线程自己身上时也是）
        void Update()
        {
            uint* ids = stackalloc uint[64]; ulong* vals = stackalloc ulong[64];
            // 按线程复用：稳态零分配
            NxCounterEvent[] got = t_got ??= new NxCounterEvent[64];
            int n;
            while (true)
            {
                lock (_live)
                {
                    if ((n = N.nxgal_counter_poll(ids, vals, 64)) <= 0) return;
                    // 出结果即出表
                    for (int i = 0; i < n; i++)
                        if (_live.Remove(ids[i], out NxCounterEvent e) && !e.Done) { Volatile.Write(ref e.Done, true); got[i] = e; }
                        else got[i] = null;
                }
                for (int i = 0; i < n; i++)
                {
                    NxCounterEvent e = got[i]; if (e == null) continue; got[i] = null;
                    e.Handler?.Invoke(e, vals[i]);
                    // 回调做完：Gpu 层已放手的当场回池
                    lock (_live)
                    {
                        Volatile.Write(ref e.Handled, true);
                        if (e.Dropped) { e.Handler = null; _pool.Push(e); }
                        if (_waiters != 0) Monitor.PulseAll(_live);
                    }
                }
            }
        }
    }
}
