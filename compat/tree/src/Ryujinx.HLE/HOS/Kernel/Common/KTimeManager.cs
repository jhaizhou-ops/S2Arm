using Ryujinx.Common;
using Ryujinx.Common.PreciseSleep;
using System;
using System.Collections.Generic;
using System.Threading;

namespace Ryujinx.HLE.HOS.Kernel.Common
{
    class KTimeManager : IDisposable
    {
        public static readonly long DefaultTimeIncrementNanoseconds = ConvertGuestTicksToNanoseconds(2);

        private class WaitingObject
        {
            public IKFutureSchedulerObject Object { get; }
            public long TimePoint { get; }

            public WaitingObject(IKFutureSchedulerObject schedulerObj, long timePoint)
            {
                Object = schedulerObj;
                TimePoint = timePoint;
            }
        }

        private readonly KernelContext _context;
        private readonly List<WaitingObject> _waitingObjects;
        private readonly IPreciseSleepEvent _waitEvent;
        private readonly Thread _thread;
        private readonly object _disposeLock = new();
        private volatile bool _keepRunning;
        private bool _disposed;
        private long _enforceWakeupFromSpinWait;

        private const long NanosecondsPerSecond = 1000000000L;
        private const long NanosecondsPerMillisecond = 1000000L;

        public KTimeManager(KernelContext context)
        {
            _context = context;
            _waitingObjects = [];
            _waitEvent = PreciseSleepHelper.CreateEvent();
            _keepRunning = true;

            _thread = new Thread(WaitAndCheckScheduledObjects)
            {
                Name = "HLE.TimeManager",
            };

            _thread.Start();
        }

        public void ScheduleFutureInvocation(IKFutureSchedulerObject schedulerObj, long timeout)
        {
            long startTime = PerformanceCounter.ElapsedTicks;
            long timePoint = startTime + ConvertNanosecondsToHostTicks(timeout);

            if (timePoint < startTime)
            {
                timePoint = long.MaxValue;
            }

            timePoint = _waitEvent.AdjustTimePoint(timePoint, timeout);

            lock (_context.CriticalSection.Lock)
            {
                _waitingObjects.Add(new WaitingObject(schedulerObj, timePoint));

                if (timeout < NanosecondsPerMillisecond)
                {
                    Interlocked.Exchange(ref _enforceWakeupFromSpinWait, 1);
                }
            }

            _waitEvent.Signal();
        }

        public void UnscheduleFutureInvocation(IKFutureSchedulerObject schedulerObj)
        {
            lock (_context.CriticalSection.Lock)
            {
                for (int index = _waitingObjects.Count - 1; index >= 0; index--)
                {
                    if (_waitingObjects[index].Object == schedulerObj)
                    {
                        _waitingObjects.RemoveAt(index);
                    }
                }
            }
        }

        private void WaitAndCheckScheduledObjects()
        {
            WaitingObject next;

            while (_keepRunning)
            {
                Ryujinx.Common.S2AThreadAlloc.Tick("内核计时"); // S2Arm: per-thread allocation accounting (HLE.TimeManager)

                lock (_context.CriticalSection.Lock)
                {
                    Interlocked.Exchange(ref _enforceWakeupFromSpinWait, 0);
                    if (!_keepRunning) break;

                    next = GetNextWaitingObject();
                }

                if (next != null)
                {
                    long timePoint = PerformanceCounter.ElapsedTicks;

                    if (next.TimePoint > timePoint)
                    {
                        if (!_waitEvent.SleepUntil(next.TimePoint))
                        {
                            PreciseSleepHelper.SpinWaitUntilTimePoint(next.TimePoint, ref _enforceWakeupFromSpinWait);
                        }
                    }

                    bool timeUp = PerformanceCounter.ElapsedTicks >= next.TimePoint;

                    if (timeUp)
                    {
                        lock (_context.CriticalSection.Lock)
                        {
                            if (_keepRunning && _waitingObjects.Remove(next))
                            {
                                next.Object.TimeUp();
                            }
                        }
                    }
                }
                else
                {
                    _waitEvent.Sleep();
                }
            }
        }

        private WaitingObject GetNextWaitingObject()
        {
            WaitingObject selected = null;

            long lowestTimePoint = long.MaxValue;

            for (int index = _waitingObjects.Count - 1; index >= 0; index--)
            {
                WaitingObject current = _waitingObjects[index];

                if (current.TimePoint <= lowestTimePoint)
                {
                    selected = current;
                    lowestTimePoint = current.TimePoint;
                }
            }

            return selected;
        }

        public static long ConvertNanosecondsToMilliseconds(long time)
        {
            time /= NanosecondsPerMillisecond;

            if ((ulong)time > int.MaxValue)
            {
                return int.MaxValue;
            }

            return time;
        }

        public static long ConvertMillisecondsToNanoseconds(long time)
        {
            return time * NanosecondsPerMillisecond;
        }

        public static long ConvertNanosecondsToHostTicks(long ns)
        {
            long nsDiv = ns / NanosecondsPerSecond;
            long nsMod = ns % NanosecondsPerSecond;
            long tickDiv = PerformanceCounter.TicksPerSecond / NanosecondsPerSecond;
            long tickMod = PerformanceCounter.TicksPerSecond % NanosecondsPerSecond;

            long baseTicks = (nsMod * tickMod + PerformanceCounter.TicksPerSecond - 1) / NanosecondsPerSecond;
            return (nsDiv * tickDiv) * NanosecondsPerSecond + nsDiv * tickMod + nsMod * tickDiv + baseTicks;
        }

        public static long ConvertGuestTicksToNanoseconds(long ticks)
        {
            return (long)Math.Ceiling(ticks * (1000000000.0 / 19200000.0));
        }

        public static long ConvertHostTicksToTicks(long time)
        {
            return (long)((time / (double)PerformanceCounter.TicksPerSecond) * 19200000.0);
        }

        public void Dispose()
        {
            if (_thread == Thread.CurrentThread)
            {
                throw new InvalidOperationException("Cannot dispose the kernel timer from its callback thread.");
            }

            lock (_disposeLock)
            {
                if (_disposed) return;
                _keepRunning = false;
                Interlocked.Exchange(ref _enforceWakeupFromSpinWait, 1);
                _waitEvent.Signal();
                if (!_thread.Join(3000))
                {
                    throw new TimeoutException("HLE.TimeManager did not stop within 3 seconds; kernel resources must remain alive.");
                }

                // The caller owns the event until the worker has stopped using it.
                _waitEvent.Dispose();
                _disposed = true;
            }
        }
    }
}
