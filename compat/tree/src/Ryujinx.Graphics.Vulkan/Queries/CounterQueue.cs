using Ryujinx.Graphics.GAL;
using Silk.NET.Vulkan;
using System;
using System.Collections.Generic;
using System.Threading;

namespace Ryujinx.Graphics.Vulkan.Queries
{
    class CounterQueue : IDisposable
    {
        private const int QueryPoolInitialSize = 100;
        private const long FlushToTimeoutMs = 500;

        private readonly VulkanRenderer _gd;
        private readonly Device _device;
        private readonly PipelineFull _pipeline;

        public CounterType Type { get; }
        public bool Disposed { get; private set; }

        private readonly Queue<CounterQueueEvent> _events = new();
        private CounterQueueEvent _current;

        private ulong _accumulatedCounter;
        private int _waiterCount;

        private readonly Lock _lock = new();

        private readonly Queue<BufferedQuery> _queryPool;
        private readonly AutoResetEvent _queuedEvent = new(false);
        private readonly AutoResetEvent _wakeSignal = new(false);
        private readonly AutoResetEvent _eventConsumed = new(false);

        private readonly Thread _consumerThread;
        private readonly object _s2aCallbackGate = new();
        private volatile bool _s2aStopped;

        // Android 进程快退：先关回调再有界等消费线程，不释放查询/事件/设备（尚在 AwaitResult 的线程仍持有它们）。
        public bool S2AStopForExit(int milliseconds)
        {
            long deadline = Environment.TickCount64 + milliseconds;
            if (!Monitor.TryEnter(_s2aCallbackGate, milliseconds))
                throw new TimeoutException("Counter callback did not quiesce; retain GPU tracking until process exit.");
            try { _s2aStopped = true; }
            finally { Monitor.Exit(_s2aCallbackGate); }
            _queuedEvent.Set();
            _wakeSignal.Set();
            return _consumerThread.Join((int)Math.Max(0, deadline - Environment.TickCount64));
        }

        internal void S2ADeliverResult(EventHandler<ulong> handler, object sender, ulong result)
        {
            if (!_gd.S2ACounterLifetime) { handler?.Invoke(sender, result); return; }
            lock (_s2aCallbackGate)
                if (!_s2aStopped) handler?.Invoke(sender, result);
        }

        public int ResetSequence { get; private set; }

        internal CounterQueue(VulkanRenderer gd, Device device, PipelineFull pipeline, CounterType type)
        {
            _gd = gd;
            _device = device;
            _pipeline = pipeline;

            Type = type;

            _queryPool = new Queue<BufferedQuery>(QueryPoolInitialSize);
            for (int i = 0; i < QueryPoolInitialSize; i++)
            {
                // AMD Polaris GPUs on Windows seem to have issues reporting 64-bit query results.
                _queryPool.Enqueue(new BufferedQuery(_gd, _device, _pipeline, type, gd.IsAmdWindows));
            }

            _current = new CounterQueueEvent(this, type, 0);

            _consumerThread = new Thread(EventConsumer) { Name = "CPU.CounterQueue." + (int)type };
            _consumerThread.Start();
        }

        public void ResetCounterPool()
        {
            ResetSequence++;
        }

        public void ResetFutureCounters(CommandBuffer cmd, int count)
        {
            // Pre-emptively reset queries to avoid render pass splitting.
            lock (_queryPool)
            {
                count = Math.Min(count, _queryPool.Count);

                if (count > 0)
                {
                    foreach (BufferedQuery query in _queryPool)
                    {
                        query.PoolReset(cmd, ResetSequence);

                        if (--count == 0)
                        {
                            break;
                        }
                    }
                }
            }
        }

        private void EventConsumer()
        {
            while (!Disposed && !_s2aStopped)
            {
                CounterQueueEvent evt = null;
                lock (_lock)
                {
                    if (_events.Count > 0)
                    {
                        evt = _events.Peek();
                    }
                }

                if (evt == null)
                {
                    _queuedEvent.WaitOne(); // No more events to go through, wait for more.
                }
                // Spin-wait rather than sleeping if there are any waiters, by passing null instead of the wake signal.
                else if (evt.TryConsume(ref _accumulatedCounter, true, _waiterCount == 0 ? _wakeSignal : null))
                {
                    // Peek-then-dequeue: a failed consume keeps the event queued so it can
                    // still complete when its result lands; only a success removes it.
                    lock (_lock)
                    {
                        if (_events.Count > 0 && ReferenceEquals(_events.Peek(), evt))
                        {
                            _events.Dequeue();
                        }
                    }
                }

                if (_waiterCount > 0)
                {
                    _eventConsumed.Set();
                }
            }
        }

        internal BufferedQuery GetQueryObject()
        {
            // Creating/disposing query objects on a context we're sharing with will cause issues.
            // So instead, make a lot of query objects on the main thread and reuse them.

            lock (_lock)
            {
                if (_queryPool.Count > 0)
                {
                    BufferedQuery result = _queryPool.Dequeue();
                    return result;
                }

                return new BufferedQuery(_gd, _device, _pipeline, Type, _gd.IsAmdWindows);
            }
        }

        internal void ReturnQueryObject(BufferedQuery query)
        {
            lock (_lock)
            {
                // The query will be reset when it dequeues.
                _queryPool.Enqueue(query);
            }
        }

        public CounterQueueEvent QueueReport(EventHandler<ulong> resultHandler, float divisor, ulong lastDrawIndex, bool hostReserved)
        {
            CounterQueueEvent result;
            ulong draws = lastDrawIndex - _current.DrawIndex;

            lock (_lock)
            {
                // A query's result only matters if more than one draw was performed during it.
                // Otherwise, dummy it out and return 0 immediately.

                if (hostReserved)
                {
                    // This counter event is guaranteed to be available for host conditional rendering.
                    _current.ReserveForHostAccess();
                }

                _current.Complete(draws > 0 && Type != CounterType.TransformFeedbackPrimitivesWritten, divisor);
                _events.Enqueue(_current);

                _current.OnResult += resultHandler;

                result = _current;

                _current = new CounterQueueEvent(this, Type, lastDrawIndex);
            }

            _queuedEvent.Set();

            return result;
        }

        public void QueueReset(ulong lastDrawIndex)
        {
            ulong draws = lastDrawIndex - _current.DrawIndex;

            lock (_lock)
            {
                _current.Clear(draws != 0);
            }
        }

        public void Flush(bool blocking)
        {
            if (!blocking)
            {
                // Just wake the consumer thread - it will update the queries.
                _wakeSignal.Set();
                return;
            }

            while (true)
            {
                CounterQueueEvent flush;
                lock (_lock)
                {
                    if (_events.Count == 0)
                    {
                        return;
                    }

                    flush = _events.Peek();
                }

                // The bounded consume runs outside the queue lock: holding it across a 500 ms
                // await would stall QueueReport/QueueReset for the full timeout per event.
                if (!flush.TryConsume(ref _accumulatedCounter, true))
                {
                    return; // If not blocking, then return when we encounter an event that is not ready yet.
                }

                lock (_lock)
                {
                    if (_events.Count > 0 && ReferenceEquals(_events.Peek(), flush))
                    {
                        _events.Dequeue();
                    }
                }
            }
        }

        public void FlushTo(CounterQueueEvent evt)
        {
            // Flush the counter queue on the main thread.
            Interlocked.Increment(ref _waiterCount);

            // S2A：等的是计数消费线程拿到 GPU 结果，而结果所在的命令缓冲要靠渲染线程提交；宿主（Android 拆线程）经 S2AWaitCheck
            // 做有界与失败闩检查（渲染线程卡住 / 失败时抛错）。没登记 = 原样；抛错时也要把等待计数还回去。
            // 等待自带上限：到期报红返回（事件仍留队，结果真到了消费线程照样交付），不把进程拖进无界自旋。
            long deadline = Environment.TickCount64 + FlushToTimeoutMs;
            try
            {
                _wakeSignal.Set();

                while (!evt.Disposed)
                {
                    if (Environment.TickCount64 >= deadline)
                    {
                        Ryujinx.Common.Logging.Logger.Error?.Print(Ryujinx.Common.Logging.LogClass.Gpu,
                            $"Error: Counter queue flush for {Type} timed out after {FlushToTimeoutMs} ms; event stays pending.");
                        return;
                    }

                    _eventConsumed.WaitOne(1);
                    _gd.S2AWaitCheck?.Invoke();
                }
            }
            finally
            {
                Interlocked.Decrement(ref _waiterCount);
            }
        }

        public void Dispose()
        {
            lock (_lock)
            {
                while (_events.Count > 0)
                {
                    CounterQueueEvent evt = _events.Dequeue();

                    evt.Dispose();
                }

                Disposed = true;
            }

            _queuedEvent.Set();

            _consumerThread.Join();

            _current?.Dispose();

            foreach (BufferedQuery query in _queryPool)
            {
                query.Dispose();
            }

            _queuedEvent.Dispose();
            _wakeSignal.Dispose();
            _eventConsumed.Dispose();
        }
    }
}
