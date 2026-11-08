using System;
using System.Diagnostics;
using System.Threading;

namespace Ryujinx.Audio.Backends.Common
{
    /// <summary>
    /// When queued samples count as played for the game: handed back by the device, plus a lead of one device pull.
    /// </summary>
    // S2Arm (11-02 Pokopia iPhone 断续): a game on AudioOut keeps a few buffers queued and appends the next one only when one is released
    //   (played). On a Switch the hardware consumes 240 frames every 5 ms, so a queue of 4 × 240 frames is plenty there. A host device
    //   pulls a whole IO period at once and hands back only buffers it has fully taken: iPhone speaker 1024 frames per 21.3 ms, Mac 512.
    //   When everything the game keeps queued is less than one pull (Pokopia: 4 × 240 = 960 < 1024), every pull comes up short and the
    //   game cannot refill before it: iPhone delivered 437,760 of 480,000 frames per 10 s (gap 885 ms), Mac with its 512-frame pulls 0.
    //   So a queued sample counts as played once the device handed it back or it lies within one pull ahead of what was handed back
    //   (and it was already submitted: guest memory must have been read). The game then refills one pull earlier and the device always
    //   holds at least a pull; the stream stays paced by the device, latency grows by one pull, nothing else changes.
    //   The pull is measured, not assumed (routes and devices differ): the hand-backs of one pull come back to back, so a burst is the
    //   queued-sample bytes handed back with gaps ≤ burstGapTicks, and the lead is the median of the last Window bursts (a stalled callback that
    //   returns many pulls at once does not move the median). With a short supply a burst is the supply, so the lead starts there and
    //   grows to a full pull after a few periods.
    // S2Arm (11-02 Pokopia iPhone 杂音): the credit is a play head that moves at the sample rate, between the hand-backs (floor) and
    //   hand-backs + lead (cap), not a step of a whole pull at each hand-back. A Switch releases one 240-frame buffer every 5 ms; released
    //   four at once every 21.3 ms, Pokopia's mixer (paced by its own 5 ms clock) had the fourth one ready only 81% of the time and
    //   appended it silent: 7.3 holes of 5 ms per second (iPhone wav: holes at burst position 0/1/2/3 = 0 / 0 / 1.6% / 18.8%).
    //   The session asks TicksUntil when the next buffer will be due and releases it then (one wakeup per buffer).
    public sealed class PlaybackCredit
    {
        private const int Window = 32;
        private readonly Lock _lock = new();
        private readonly int _bytesPerFrame;
        private readonly long _maxLeadBytes;
        private readonly long _burstGapTicks;
        private readonly long[] _bursts = new long[Window];
        private int _burstN, _burstW;
        private long _burstBytes, _lastReturnTicks;
        private readonly long _bytesPerSecond;
        private long _leadBytes, _handedBack, _credited;
        // Play head (bytes, may hold a fraction of a frame) and when it was last moved (0: not yet)
        private double _head;
        private long _headTicks;

        public PlaybackCredit(int bytesPerFrame, long bytesPerSecond, long maxLeadBytes, long burstGapTicks)
        {
            _bytesPerFrame = bytesPerFrame;
            _bytesPerSecond = bytesPerSecond;
            _maxLeadBytes = maxLeadBytes / bytesPerFrame * bytesPerFrame;
            _burstGapTicks = burstGapTicks;
        }

        /// <summary>
        /// Current lead in bytes (one device pull, at most maxLeadBytes).
        /// </summary>
        public long LeadBytes => Volatile.Read(ref _leadBytes);

        /// <summary>
        /// The device handed back a buffer holding <paramref name="sampleBytes"/> of queued samples (0 for internal silence), at
        /// <paramref name="ticks"/> (Stopwatch).
        /// </summary>
        public void Returned(int sampleBytes, long ticks)
        {
            lock (_lock)
            {
                if (_lastReturnTicks != 0 && ticks - _lastReturnTicks > _burstGapTicks)
                {
                    PushBurstLocked(_burstBytes);
                    _burstBytes = 0;
                }

                _burstBytes += sampleBytes;
                _lastReturnTicks = ticks;
                _handedBack += sampleBytes;
            }
        }

        /// <summary>
        /// Queued samples taken back from the device unplayed (it was stopped or rebuilt): they are done with, as if handed back.
        /// </summary>
        public void Reclaimed(int sampleBytes)
        {
            lock (_lock)
            {
                _handedBack += sampleBytes;
            }
        }

        /// <summary>
        /// Bytes of queued samples that count as played at <paramref name="ticks"/> (Stopwatch) and did not before, given
        /// <paramref name="submittedSampleBytes"/> of queued samples submitted to the device so far.
        /// </summary>
        public int Take(long submittedSampleBytes, long ticks)
        {
            lock (_lock)
            {
                MoveHeadLocked(ticks);
                long target = Math.Min(submittedSampleBytes, (long)_head / _bytesPerFrame * _bytesPerFrame);

                if (target <= _credited)
                {
                    return 0;
                }

                int n = (int)(target - _credited);
                _credited = target;

                return n;
            }
        }

        /// <summary>
        /// Stopwatch ticks from <paramref name="ticks"/> until <paramref name="moreBytes"/> more than credited so far count as played;
        /// long.MaxValue when that lies beyond the cap (it waits for the next hand-back) or beyond what was submitted (it waits for that).
        /// </summary>
        public long TicksUntil(long moreBytes, long submittedSampleBytes, long ticks)
        {
            lock (_lock)
            {
                MoveHeadLocked(ticks);
                long want = _credited + moreBytes;

                if (want > _handedBack + _leadBytes || want > submittedSampleBytes)
                {
                    return long.MaxValue;
                }

                double ahead = want - _head;

                return ahead <= 0 ? 0 : (long)Math.Ceiling(ahead * Stopwatch.Frequency / _bytesPerSecond);
            }
        }

        // Under _lock: the head moves at the sample rate since the last move, never past hand-backs + lead nor behind the hand-backs
        private void MoveHeadLocked(long ticks)
        {
            if (_headTicks != 0 && ticks > _headTicks)
            {
                _head += (double)(ticks - _headTicks) * _bytesPerSecond / Stopwatch.Frequency;
            }

            _headTicks = ticks;
            _head = Math.Max(Math.Min(_head, _handedBack + _leadBytes), _handedBack);
        }

        // Under _lock: a burst closed; the lead is the median of the last Window bursts (allocation-free: the callback thread is real time)
        private void PushBurstLocked(long bytes)
        {
            _bursts[_burstW] = bytes;
            _burstW = (_burstW + 1) % Window;
            _burstN = Math.Min(_burstN + 1, Window);

            Span<long> s = stackalloc long[Window];
            _bursts.AsSpan(0, _burstN).CopyTo(s);
            s = s[.._burstN];
            s.Sort();

            Volatile.Write(ref _leadBytes, Math.Min(s[_burstN / 2], _maxLeadBytes) / _bytesPerFrame * _bytesPerFrame);
        }
    }
}
