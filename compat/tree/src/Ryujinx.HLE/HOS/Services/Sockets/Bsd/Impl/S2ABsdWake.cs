using Ryujinx.Common;
using System.Threading;

namespace Ryujinx.HLE.HOS.Services.Sockets.Bsd.Impl
{
    /// <summary>
    /// S2Arm: one wait for selects that mix descriptor kinds (eventfds and offline sockets).
    /// </summary>
    /// <remarks>
    /// The two kinds have no common wait primitive, so IClient.Select polled every manager without waiting and slept 1 ms until
    /// something was ready or the timeout passed: ~1000 wakeups per second per blocked select, each poll allocating its lists
    /// (10-21 d2r on Mac: about 1 MB per select, 260 selects in 200 s = 133 MB, the largest steady allocation on the game threads).
    /// Every state change of an eventfd or offline socket bumps a version here; a mixed select remembers the version before it
    /// polls and, when nothing was ready, waits until the version moves, the timeout passes or shutdown is requested.
    /// </remarks>
    static class S2ABsdWake
    {
        private static readonly object _lock = new();
        private static long _version;

        static S2ABsdWake()
        {
            S2AShutdown.OnRequest(Signal);
        }

        public static long Version => Interlocked.Read(ref _version);

        public static void Signal()
        {
            lock (_lock)
            {
                _version++;
                Monitor.PulseAll(_lock);
            }
        }

        /// <summary>
        /// Wait until the version is no longer <paramref name="seen"/>, <paramref name="timeoutMilliseconds"/> passed (-1 = forever)
        /// or shutdown was requested.
        /// </summary>
        public static void Wait(long seen, int timeoutMilliseconds)
        {
            lock (_lock)
            {
                if (_version == seen && !S2AShutdown.Requested)
                {
                    Monitor.Wait(_lock, timeoutMilliseconds);
                }
            }
        }
    }
}
