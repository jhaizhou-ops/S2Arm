using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;

namespace Ryujinx.Common
{
    /// <summary>
    /// S2Arm: per-thread managed allocation accounting (S2A_ALLOC_TRACE=1, diagnostics; off = one static bool check).
    /// Long-lived threads call <see cref="Tick"/> once per loop iteration; bytes allocated on that thread between two ticks
    /// are added to its slot. <see cref="Summary"/> lists every slot with its total and per-iteration average.
    /// </summary>
    public static class S2AThreadAlloc
    {
        // Not readonly: unit tests switch it on before starting the threads they measure (per-thread bytes per iteration, independent of
        // whatever other threads allocate meanwhile — a whole-process total flaked under machine load).
        public static bool On = Environment.GetEnvironmentVariable("S2A_ALLOC_TRACE") == "1";

        private sealed class Slot
        {
            public string Name;
            public long Bytes;
            public long Rounds;
            public bool IsPart;   // S2Arm: a Part (subset of some thread's bytes): listed, but left out of Total so it is not counted twice
        }

        private static readonly List<Slot> _slots = new();
        private static int _generation;
        [ThreadStatic] private static int _threadGeneration;

        public static void ResetSession()
        {
            lock (_slots)
            {
                _slots.Clear();
                Interlocked.Increment(ref _generation);
            }
        }

        [ThreadStatic]
        private static Slot _slot;

        [ThreadStatic]
        private static long _last;

        public static void Tick(string name = null)
        {
            if (!On)
            {
                return;
            }

            long now = GC.GetAllocatedBytesForCurrentThread();

            if (_slot == null || _threadGeneration != Volatile.Read(ref _generation))
            {
                _slot = new Slot { Name = name ?? Thread.CurrentThread.Name ?? $"线程 {Environment.CurrentManagedThreadId}" };

                lock (_slots)
                {
                    _threadGeneration = _generation;
                    _slots.Add(_slot);
                }

                _last = GC.GetAllocatedBytesForCurrentThread();

                return;
            }

            Interlocked.Add(ref _slot.Bytes, now - _last);
            Interlocked.Increment(ref _slot.Rounds);
            _last = now;
        }

        /// <summary>
        /// S2Arm: a named part of some thread's loop (e.g. 「合成·取帧上屏」), counted by the caller around that part while <see cref="On"/>;
        /// listed in <see cref="Summary"/> next to the per-thread slots (a part is a subset of its thread's bytes).
        /// </summary>
        public static void Part(string name, long bytes)
        {
            lock (_slots)
            {
                Slot s = null;

                foreach (Slot x in _slots)
                {
                    if (x.Name == name)
                    {
                        s = x;
                        break;
                    }
                }

                if (s == null)
                {
                    s = new Slot { Name = name, IsPart = true };
                    _slots.Add(s);
                }

                s.Bytes += bytes;
                s.Rounds++;
            }
        }

        /// <summary>Bytes and iterations so far of the slots with this name (summed over threads).</summary>
        public static (long Bytes, long Rounds) Of(string name)
        {
            lock (_slots)
            {
                long b = 0, r = 0;

                foreach (Slot s in _slots)
                {
                    if (s.Name == name)
                    {
                        b += Interlocked.Read(ref s.Bytes);
                        r += Interlocked.Read(ref s.Rounds);
                    }
                }

                return (b, r);
            }
        }

        /// <summary>Sum of all slots (bytes).</summary>
        public static long Total()
        {
            lock (_slots)
            {
                return _slots.Where(s => !s.IsPart).Sum(s => s.Bytes);
            }
        }

        public static string Summary()
        {
            lock (_slots)
            {
                return string.Join("\n", _slots.OrderByDescending(s => s.Bytes).Select(s =>
                    $"[分配·线程]   {s.Name}：{s.Bytes / 1024} KB / {s.Rounds} 圈（{s.Bytes / Math.Max(1, s.Rounds)} B/圈）"));
            }
        }
    }
}
