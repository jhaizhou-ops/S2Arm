using System;

namespace Ryujinx.Graphics.Gpu.Synchronization
{
    public class SyncpointWaiterHandle
    {
        internal uint Threshold;
        internal Action<SyncpointWaiterHandle> Callback;
        internal bool S2APooled;   // S2A：来自同步点的句柄池（RegisterCallbackPooled），回调跑完放回池里
    }
}
