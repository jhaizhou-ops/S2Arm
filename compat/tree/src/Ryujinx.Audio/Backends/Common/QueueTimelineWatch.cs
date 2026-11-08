using System.Diagnostics;

namespace Ryujinx.Audio.Backends.Common
{
    /// <summary>
    /// Tells when an output queue's timeline has run ahead of the samples given to it: they arrive at the sample rate, yet the queue
    /// keeps nothing in flight.
    /// </summary>
    // S2Arm (11-06 时之笛 / 金刚 iPhone 读档后永久静音): after an iOS AudioQueue runs dry once, its timeline keeps moving; the buffers
    //   enqueued afterwards are placed after the last one, at a time already gone, and are handed back at the next IO cycle without being
    //   heard. A game delivers at the sample rate, never faster, so the queue never catches up: silent for good. iPhone 测试机2 (A19 Pro),
    //   第 32 版包: a 500 ms producer stall at 25 s (S2A_AUDIO_TEST_PRODUCER_STALL_AT=25:500) left the queue's own level meter at 0.0000
    //   for the rest of the run while the samples submitted peaked at 0.16–0.32; the 11-06 save-load run went the same way at load, and
    //   the speaker (system RTAID RMS) went from −20 dB to −120 dB with no interruption or route change. Its hand-back log: before, about
    //   4300 frames in flight and 0–2 hand-backs a 10 s with nothing left in flight; after, about 650 frames and about 445, at 48,0xx
    //   frames a second. A Mac AudioQueue recovers by itself (the same game on Mac, and a stand-alone underrun test).
    //   A queue that is merely starved (the game delivers slower than the sample rate) also hands back with nothing in flight, but then
    //   hands back slower than the sample rate. So: at least MinZeroReturns such hand-backs in each of two watchdog ticks in a row, and
    //   over both ticks bytes handed back at ≥ MinRate of the sample rate (two ticks: one tick of 250 ms holds about 12 device pulls, and
    //   a pull of 21.3 ms more or less moves one tick's rate by 8%). The session then restarts the queue, which starts a new timeline.
    public sealed class QueueTimelineWatch
    {
        public const int MinZeroReturns = 4;
        public const double MinRate = 0.85;

        private readonly long _bytesPerSecond;
        private int _prevZero;
        private long _prevBytes, _prevTicks;

        public QueueTimelineWatch(long bytesPerSecond)
        {
            _bytesPerSecond = bytesPerSecond;
        }

        /// <summary>One watchdog tick: hand-backs that left nothing in flight, bytes handed back, ticks since the last tick. True: restart.</summary>
        public bool Tick(int zeroReturns, long returnedBytes, long elapsedTicks)
        {
            bool ahead = _prevZero >= MinZeroReturns && zeroReturns >= MinZeroReturns && _prevTicks > 0 && elapsedTicks > 0 &&
                         (double)(_prevBytes + returnedBytes) * Stopwatch.Frequency >= MinRate * _bytesPerSecond * (_prevTicks + elapsedTicks);

            _prevZero = zeroReturns;
            _prevBytes = returnedBytes;
            _prevTicks = elapsedTicks;

            if (ahead)
            {
                Reset();
            }

            return ahead;
        }

        /// <summary>Forget the previous tick (the queue was stopped or restarted).</summary>
        public void Reset()
        {
            _prevZero = 0;
            _prevBytes = 0;
            _prevTicks = 0;
        }
    }
}
