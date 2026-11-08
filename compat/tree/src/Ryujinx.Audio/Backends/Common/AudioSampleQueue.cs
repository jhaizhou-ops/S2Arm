using Ryujinx.Audio.Common;
using System;
using System.Threading;

namespace Ryujinx.Audio.Backends.Common
{
    /// <summary>
    /// The byte stream an output session plays: the queued buffers' samples, in queue order.
    /// </summary>
    // S2Arm: replaces the session's DynamicRingBuffer, which held a copy of every queued byte (sized by what the game queued, unbounded).
    // - Registered guest buffers are not copied: their samples are pulled from guest memory (through AudioBuffer.SampleReader, which also
    //   applies the compat layer's conversion) when the device reads them. The audio system owns them until released, and released means
    //   played, i.e. already read here.
    // - Buffers whose samples are in Data (renderer output: one array reused every round) are copied in when queued, into a ring of
    //   at most maxCopiedBytes; bytes beyond it play as silence, so lengths and timing stay as queued.
    // - Release (Stop / FlushBuffers / Dispose hand a buffer back to the game before it was played) copies its unread samples in first,
    //   so what plays is still what the buffer held while it was queued.
    // Copied bytes sit in the ring in queue order: guest segments always form the tail of the queue (copying one in also copies those
    // queued before it), so a ring read always belongs to the head segment.
    public class AudioSampleQueue
    {
        // Guest samples are copied in through a stack buffer of this size
        private const int CopyChunkSize = 4096;

        private struct Segment
        {
            // Not null: samples still in guest memory. Null: the first Stored bytes are in the ring, the rest is silence
            public AudioBuffer Buffer;
            public long Size;
            public long Offset;
            public long Stored;
        }

        private readonly Lock _lock = new();
        private readonly DynamicRingBuffer _ring;
        private Segment[] _segments = new Segment[16];
        private int _head;
        private int _count;
        // Index (from the head) of the first guest segment; _count if there is none
        private int _firstGuest;
        private long _length;

        public AudioSampleQueue(int maxCopiedBytes)
        {
            _ring = new DynamicRingBuffer(maxCopiedBytes);
        }

        /// <summary>
        /// Unread bytes.
        /// </summary>
        public int Length
        {
            get
            {
                lock (_lock)
                {
                    return (int)Math.Min(_length, int.MaxValue);
                }
            }
        }

        public void Enqueue(AudioBuffer buffer)
        {
            lock (_lock)
            {
                if (buffer.Data != null)
                {
                    if (buffer.Data.Length == 0)
                    {
                        return;
                    }

                    CopyInLocked(_count - 1);

                    int stored = _ring.Write(buffer.Data, 0, buffer.Data.Length);

                    AddLocked(new Segment { Size = buffer.Data.Length, Stored = stored });
                    _firstGuest = _count;
                }
                else
                {
                    if (buffer.DataSize == 0)
                    {
                        return;
                    }

                    AddLocked(new Segment { Buffer = buffer, Size = (long)buffer.DataSize });
                }
            }
        }

        /// <summary>
        /// Read up to destination.Length bytes from the head of the stream.
        /// </summary>
        /// <returns>The number of bytes read</returns>
        public int Read(Span<byte> destination)
        {
            lock (_lock)
            {
                int total = 0;

                while (total < destination.Length && _count > 0)
                {
                    ref Segment s = ref _segments[_head];

                    int n = (int)Math.Min(s.Size - s.Offset, destination.Length - total);
                    Span<byte> dst = destination.Slice(total, n);

                    if (s.Buffer != null)
                    {
                        s.Buffer.SampleReader.ReadSamples(s.Buffer, (ulong)s.Offset, dst);
                    }
                    else
                    {
                        int fromRing = (int)Math.Clamp(s.Stored - s.Offset, 0, n);

                        if (fromRing > 0)
                        {
                            _ring.Read(dst, 0, fromRing);
                        }

                        dst[fromRing..].Clear();
                    }

                    s.Offset += n;
                    total += n;
                    _length -= n;

                    if (s.Offset == s.Size)
                    {
                        s = default;
                        _head = (_head + 1) % _segments.Length;
                        _count--;
                        _firstGuest = Math.Max(_firstGuest - 1, 0);
                    }
                }

                return total;
            }
        }

        /// <summary>
        /// The buffer goes back to its owner: copy in whatever of it has not been read yet.
        /// </summary>
        public void Release(AudioBuffer buffer)
        {
            lock (_lock)
            {
                for (int i = _count - 1; i >= _firstGuest; i--)
                {
                    if (_segments[(_head + i) % _segments.Length].Buffer == buffer)
                    {
                        CopyInLocked(i);

                        return;
                    }
                }
            }
        }

        // Copy the unread samples of guest segments [_firstGuest, last] into the ring, in order
        private void CopyInLocked(int last)
        {
            if (_firstGuest > last)
            {
                return;
            }

            Span<byte> chunk = stackalloc byte[CopyChunkSize];

            for (; _firstGuest <= last; _firstGuest++)
            {
                ref Segment s = ref _segments[(_head + _firstGuest) % _segments.Length];

                long size = s.Size - s.Offset;
                long stored = 0;

                while (stored < size)
                {
                    int n = (int)Math.Min(CopyChunkSize, size - stored);

                    s.Buffer.SampleReader.ReadSamples(s.Buffer, (ulong)(s.Offset + stored), chunk[..n]);

                    int written = _ring.Write(chunk, 0, n);

                    stored += written;

                    if (written < n)
                    {
                        break;
                    }
                }

                s = new Segment { Size = size, Stored = stored };
            }
        }

        private void AddLocked(Segment segment)
        {
            if (_count == _segments.Length)
            {
                Segment[] grown = new Segment[_segments.Length * 2];

                for (int i = 0; i < _count; i++)
                {
                    grown[i] = _segments[(_head + i) % _segments.Length];
                }

                _segments = grown;
                _head = 0;
            }

            _segments[(_head + _count) % _segments.Length] = segment;
            _count++;
            _length += segment.Size;
        }
    }
}
