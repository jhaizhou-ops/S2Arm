using Ryujinx.Graphics.GAL.Multithreading.Commands.CounterEvent;
using Ryujinx.Graphics.GAL.Multithreading.Model;
using System;
using System.Threading;

namespace Ryujinx.Graphics.GAL.Multithreading.Resources
{
    class ThreadedCounterEvent : ICounterEvent
    {
        private readonly ThreadedRenderer _renderer;
        public ICounterEvent Base;

        public bool Invalid { get; set; }

        public CounterType Type { get; private set; }
        public bool ClearCounter { get; private set; }

        private bool _reserved;
        private int _createLock;

        // S2Arm: pooled (ThreadedRenderer.ReportCounter was one new event per report: 48 B, d3 reports SamplesPassed ~18 times per frame,
        // ~1 MB per 20 s on the render thread). The backend gets this object's own result handler (bound once); it forwards the result to
        // the GPU layer's handler first and only then marks the result handled, so the GPU layer's reads of Invalid during the callback
        // see this query, never a later one. Back in the pool once both the result is handled and the dispose command has run
        // (ThreadedRenderer.S2ACounterHandled / S2ACounterDropped, under the pool lock).
        private readonly EventHandler<ulong> _ownHandler;
        private EventHandler<ulong> _gpuHandler;
        internal bool S2AHandled;
        internal bool S2ADropped;
        private int _disposeQueued;

        public ThreadedCounterEvent(ThreadedRenderer renderer, CounterType type, bool clearCounter)
        {
            _renderer = renderer;
            Type = type;
            ClearCounter = clearCounter;
            _ownHandler = OnResult;
        }

        internal void S2AReuse(CounterType type, bool clearCounter, EventHandler<ulong> gpuHandler)
        {
            Type = type;
            ClearCounter = clearCounter;
            Base = null;
            Invalid = false;
            _reserved = false;
            _createLock = 0;
            _gpuHandler = gpuHandler;
            S2AHandled = false;
            S2ADropped = false;
            _disposeQueued = 0;
        }

        private void OnResult(object sender, ulong value)
        {
            _gpuHandler?.Invoke(this, value);
            _renderer.S2ACounterHandled(this);
        }

        private TableRef<T> Ref<T>(T reference)
        {
            return new TableRef<T>(_renderer, reference);
        }

        public unsafe void Dispose()
        {
            // S2Arm: once per use (a second dispose command would run after reuse and dispose the next query's backend event)
            if (Interlocked.Exchange(ref _disposeQueued, 1) != 0)
            {
                return;
            }

            if (_renderer.S2ADiscardFrees)
            {
                return; // S2A：进程即将退出，下层对象不逐个释放（ThreadedRenderer.S2ADiscardFrees）
            }

            _renderer.New<CounterEventDisposeCommand>()->Set(Ref(this));
            _renderer.QueueCommand();
        }

        public void Flush()
        {
            ThreadedHelpers.SpinUntilNonNull(ref Base, _renderer, "计数事件在渲染线程上建好");

            Base.Flush();
        }

        public bool ReserveForHostAccess()
        {
            if (Base != null)
            {
                return Base.ReserveForHostAccess();
            }
            else
            {
                bool result = true;

                // A very light lock, as this case is uncommon.
                ThreadedHelpers.SpinUntilExchange(ref _createLock, 1, 0);

                if (Base != null)
                {
                    result = Base.ReserveForHostAccess();
                }
                else
                {
                    _reserved = true;
                }

                Volatile.Write(ref _createLock, 0);

                return result;
            }
        }

        public void Create(IRenderer renderer, CounterType type, System.EventHandler<ulong> eventHandler, float divisor, bool hostReserved)
        {
            ThreadedHelpers.SpinUntilExchange(ref _createLock, 1, 0);
            Base = renderer.ReportCounter(type, _ownHandler, divisor, hostReserved || _reserved);   // S2Arm: own handler, forwards to the GPU layer's (eventHandler)
            Volatile.Write(ref _createLock, 0);
        }
    }
}
