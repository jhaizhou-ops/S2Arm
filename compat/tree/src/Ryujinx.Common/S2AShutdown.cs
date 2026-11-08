using System;
using System.Collections.Generic;
using System.Threading;

namespace Ryujinx.Common
{
    /// <summary>
    /// S2Arm: process shutdown for service calls that block on host primitives.
    /// </summary>
    /// <remarks>
    /// Service calls run on the game thread that made them. At shutdown the host parks game threads at their next system call and
    /// waits for the calls already in C# to come back, so the services are not torn down under them; a call blocked in a service
    /// wait (bsd select / poll with a timeout, a blocking eventfd read) did not come back before the wait expired
    /// (10-21 d2r: 29 of 50 runs ended with "1 system call still in C#", bsd:u Select). Upstream Ryujinx never waits for them
    /// (the process just exits). Every blocking service wait also watches this; <see cref="Request"/> makes them all return
    /// at once as if timed out / interrupted.
    /// </remarks>
    public static class S2AShutdown
    {
        private static volatile bool _requested;
        private static readonly List<Action> _wakers = [];

        /// <summary>
        /// Set once shutdown was requested.
        /// </summary>
        public static bool Requested => _requested;

        // Only after all callers from the previous game have returned. Wakers are process-wide
        // monitor notifications registered by static constructors and must survive another game.
        public static void Reset()
        {
            lock (_wakers)
            {
                Event.Reset();
                _requested = false;
            }
        }

        /// <summary>
        /// Signaled once shutdown was requested (for waits on wait handles).
        /// </summary>
        public static readonly ManualResetEvent Event = new(false);

        /// <summary>
        /// Run <paramref name="wake"/> on shutdown (at once if it was already requested): wakes waits on monitors.
        /// </summary>
        public static void OnRequest(Action wake)
        {
            bool requested;
            lock (_wakers)
            {
                // Static constructors run once. Even a monitor first initialized during
                // shutdown needs to be registered for subsequent game sessions.
                _wakers.Add(wake);
                requested = _requested;
            }

            if (requested) wake();
        }

        public static void Request()
        {
            Action[] wakers;

            lock (_wakers)
            {
                _requested = true;
                wakers = _wakers.ToArray();
            }

            Event.Set();

            foreach (Action wake in wakers)
            {
                wake();
            }
        }
    }
}
