using Ryujinx.Common.Memory;
using System;

namespace Ryujinx.Graphics.Gpu.Memory
{
    // GPU-owner-thread only. Slots retain at most 1 MiB per PhysicalMemory.
    // A value lease carries a generation: disposing a copied old lease cannot
    // release a later rental. No MemoryOwner object is ever recycled.
    internal sealed class S2ABufferReadScratch
    {
        public static readonly bool Enabled = Environment.GetEnvironmentVariable("S2A_BUFFER_READ_SCRATCH") == "1";
        private readonly Slot[] _slots = new Slot[4];
        private readonly int _thread = Environment.CurrentManagedThreadId;

        internal sealed class Slot
        {
            internal byte[] Data;
            internal ulong Generation;
            internal bool Active;
        }

        internal void CheckThread()
        {
            if (_thread != Environment.CurrentManagedThreadId)
                throw new InvalidOperationException("Buffer read scratch requires its GPU owner thread.");
        }

        internal Lease Rent(int length)
        {
            CheckThread();
            ArgumentOutOfRangeException.ThrowIfNegative(length);
            if (length <= 256 * 1024)
            {
                int capacity = 256;
                while (capacity < length) capacity *= 2;
                int candidate = -1;
                for (int i = 0; i < _slots.Length; i++)
                {
                    Slot slot = _slots[i];
                    if (slot != null && (slot.Active || slot.Generation == ulong.MaxValue)) continue;
                    if (candidate < 0) candidate = i;
                    if (slot?.Data != null && slot.Data.Length >= capacity)
                    {
                        candidate = i;
                        break;
                    }
                }
                if (candidate >= 0)
                {
                    Slot slot = _slots[candidate] ??= new Slot();
                    if (slot.Data == null || slot.Data.Length < capacity) slot.Data = new byte[capacity];
                    slot.Generation++;
                    slot.Active = true;
                    return new Lease(this, slot, slot.Generation, length);
                }
            }
            return new Lease(MemoryOwner<byte>.Rent(length));
        }

        internal readonly struct Lease : IDisposable
        {
            private readonly S2ABufferReadScratch _pool;
            private readonly Slot _slot;
            private readonly ulong _generation;
            private readonly int _length;
            private readonly MemoryOwner<byte> _fallback;

            internal Lease(MemoryOwner<byte> fallback)
            {
                _pool = null; _slot = null; _generation = 0; _length = 0; _fallback = fallback;
            }

            internal Lease(S2ABufferReadScratch pool, Slot slot, ulong generation, int length)
            {
                _pool = pool; _slot = slot; _generation = generation; _length = length; _fallback = null;
            }

            internal Memory<byte> Memory
            {
                get
                {
                    if (_fallback != null) return _fallback.Memory;
                    _pool?.CheckThread();
                    if (_slot == null || !_slot.Active || _slot.Generation != _generation)
                        throw new ObjectDisposedException(nameof(Lease));
                    return _slot.Data.AsMemory(0, _length);
                }
            }

            internal Span<byte> Span => Memory.Span;

            public void Dispose()
            {
                if (_fallback != null) { _fallback.Dispose(); return; }
                _pool?.CheckThread();
                if (_slot != null && _slot.Active && _slot.Generation == _generation) _slot.Active = false;
            }
        }
    }
}
