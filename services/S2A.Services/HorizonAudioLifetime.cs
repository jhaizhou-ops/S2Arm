using System;
using System.Collections.Generic;

namespace S2A.Services
{
    // Android 宿主停住原生服务线程后，Horizon 服务入口走不到自己的 Shutdown；独立音频 worker 必须先于驱动事件停止。
    internal sealed class HorizonAudioLifetime : IDisposable
    {
        private readonly object _gate = new();
        private List<IDisposable> _owners = new();
        private bool _closing;
        private bool _disposing;

        internal void Register(IDisposable owner)
        {
            lock (_gate)
            {
                if (_closing) throw new InvalidOperationException("Audio service created after host cleanup began.");
                _owners.Add(owner);
            }
        }

        public void Dispose()
        {
            lock (_gate)
            {
                if (_owners == null) return;
                if (_disposing) throw new InvalidOperationException("Audio cleanup is already running.");
                _closing = true;
                _disposing = true;
                try
                {
                    // A failed owner remains first for retry; already disposed owners
                    // are removed so retries never dispose them twice.
                    while (_owners.Count != 0)
                    {
                        _owners[0].Dispose();
                        _owners.RemoveAt(0);
                    }
                    _owners = null;
                }
                finally { _disposing = false; }
            }
        }
    }
}
