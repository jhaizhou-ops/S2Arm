using System;
using System.Collections.Generic;
using System.Threading;

namespace Ryujinx.Graphics.Gpu.Synchronization
{
    /// <summary>
    /// Represents GPU hardware syncpoint.
    /// </summary>
    class Syncpoint
    {
        private int _storedValue;

        public readonly uint Id;

        /// <summary>
        /// The value of the syncpoint.
        /// </summary>
        public uint Value => (uint)_storedValue;

        // TODO: switch to something handling concurrency?
        private readonly List<SyncpointWaiterHandle> _waiters;

        public Syncpoint(uint id)
        {
            Id = id;
            _waiters = [];
        }

        /// <summary>
        /// Register a new callback for a target threshold.
        /// The callback will be called once the threshold is reached and will automatically be unregistered.
        /// </summary>
        /// <param name="threshold">The target threshold</param>
        /// <param name="callback">The callback to call when the threshold is reached</param>
        /// <returns>The created SyncpointWaiterHandle object or null if already past threshold</returns>
        public SyncpointWaiterHandle RegisterCallback(uint threshold, Action<SyncpointWaiterHandle> callback)
        {
            lock (_waiters)
            {
                if (Value >= threshold)
                {
                    callback(null);

                    return null;
                }
                else
                {
                    SyncpointWaiterHandle waiterInformation = new()
                    {
                        Threshold = threshold,
                        Callback = callback,
                    };

                    _waiters.Add(waiterInformation);

                    return waiterInformation;
                }
            }
        }

        // S2A：只要回调、不要句柄的登记（AndroidFence.RegisterCallback：合成线程每帧给没到达的围栏登记帧就绪回调，调用方丢掉返回的句柄）。
        // 句柄从池里取、回调跑完放回（10-21 动森 MARK 后合成线程每帧 32 B，稳态 gen0 的来源之一）；不返回句柄，所以不会被拿去 UnregisterCallback
        private readonly Stack<SyncpointWaiterHandle> _s2aPool = new();

        public void RegisterCallbackPooled(uint threshold, Action<SyncpointWaiterHandle> callback)
        {
            lock (_waiters)
            {
                if (Value >= threshold)
                {
                    callback(null);

                    return;
                }

                SyncpointWaiterHandle waiterInformation = _s2aPool.Count != 0 ? _s2aPool.Pop() : new SyncpointWaiterHandle();
                waiterInformation.Threshold = threshold;
                waiterInformation.Callback = callback;
                waiterInformation.S2APooled = true;

                _waiters.Add(waiterInformation);
            }
        }

        private void S2ARecycle(SyncpointWaiterHandle waiterInformation)
        {
            if (!waiterInformation.S2APooled)
            {
                return;
            }

            waiterInformation.Callback = null;

            lock (_waiters)
            {
                _s2aPool.Push(waiterInformation);
            }
        }

        public void UnregisterCallback(SyncpointWaiterHandle waiterInformation)
        {
            lock (_waiters)
            {
                _waiters.Remove(waiterInformation);
            }
        }

        /// <summary>
        /// Increment the syncpoint
        /// </summary>
        /// <returns>The incremented value of the syncpoint</returns>
        public uint Increment()
        {
            uint currentValue = (uint)Interlocked.Increment(ref _storedValue);

            SyncpointWaiterHandle expired = null;
            List<SyncpointWaiterHandle> expiredList = null;

            lock (_waiters)
            {
                // S2A：手写稳定删除（原 RemoveAll + 捕获三个局部的 lambda，每次递增新建闭包 + 委托 88 B，动森岛上每帧约 3 次；语义同 RemoveAll：逐个判一次、留下的保持原序）
                int keep = 0;
                for (int r = 0; r < _waiters.Count; r++)
                {
                    SyncpointWaiterHandle item = _waiters[r];

                    if (currentValue >= item.Threshold)
                    {
                        if (expired == null)
                        {
                            expired = item;
                        }
                        else
                        {
                            expiredList ??= [];

                            expiredList.Add(item);
                        }
                    }
                    else
                    {
                        _waiters[keep++] = item;
                    }
                }

                if (keep < _waiters.Count)
                {
                    _waiters.RemoveRange(keep, _waiters.Count - keep);
                }
            }

            // Call the callbacks as a separate step.
            // As we don't know what the callback will be doing,
            // and it could block execution for a indefinite amount of time,
            // we can't call it inside the lock.
            if (expired != null)
            {
                expired.Callback(expired);
                S2ARecycle(expired);

                if (expiredList != null)
                {
                    for (int i = 0; i < expiredList.Count; i++)
                    {
                        expiredList[i].Callback(expiredList[i]);
                        S2ARecycle(expiredList[i]);
                    }
                }
            }

            return currentValue;
        }
    }
}
