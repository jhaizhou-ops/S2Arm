using System;
using System.Collections.Generic;
using System.Threading;

namespace Ryujinx.Graphics.GAL.Multithreading
{
    class SyncMap : IDisposable
    {
        private readonly HashSet<ulong> _inFlight = [];
        private readonly AutoResetEvent _inFlightChanged = new(false);
        // S2A（Android 拆线程）：宿主自起线程且设了上限时等待有界；渲染线程失败 / 卡住后，在途同步号永远不会登记，放开所有等它的线程，由调用方查失败闩重抛
        private readonly ThreadedRenderer _renderer;
        private volatile bool _s2aAbandoned;

        internal SyncMap(ThreadedRenderer renderer)
        {
            _renderer = renderer;
        }

        internal void S2AAbandon()
        {
            _s2aAbandoned = true;
            _inFlightChanged.Set();
        }

        internal void CreateSyncHandle(ulong id)
        {
            lock (_inFlight)
            {
                _inFlight.Add(id);
            }
        }

        internal void AssignSync(ulong id)
        {
            lock (_inFlight)
            {
                _inFlight.Remove(id);
            }

            _inFlightChanged.Set();
        }

        internal void WaitSyncAvailability(ulong id)
        {
            // Blocks until the handle is available.

            bool signal = false;
            bool s2aBounded = _renderer.S2ABounded;
            ThreadedRenderer.S2AStallWatch s2aWatch = s2aBounded ? _renderer.S2AWatch() : default;

            while (true)
            {
                lock (_inFlight)
                {
                    if (!_inFlight.Contains(id) || _s2aAbandoned)
                    {
                        break;
                    }
                }

                if (!s2aBounded)
                {
                    _inFlightChanged.WaitOne();
                    signal = true;
                }
                else if (_inFlightChanged.WaitOne(50))
                {
                    signal = true;
                }
                else
                {
                    _renderer.S2ACheckStall(ref s2aWatch, "同步号在渲染线程上登记");
                }
            }

            if (signal)
            {
                // Signal other threads which might still be waiting.
                _inFlightChanged.Set();
            }
        }

        public void Dispose()
        {
            _inFlightChanged.Dispose();
        }
    }
}
