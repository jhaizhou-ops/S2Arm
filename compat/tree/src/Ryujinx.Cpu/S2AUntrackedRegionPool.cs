using Ryujinx.Memory;
using System;
using System.Buffers;
using System.Runtime.InteropServices;

namespace Ryujinx.Cpu
{
    // S2Arm: copy-and-write-back regions for writes the GPU emulation makes to guest memory itself (texture flush, buffer clear fill).
    // The caller writes into a private copy; Dispose writes it back through IVirtualMemoryManagerTracked.WriteUntracked, exactly like Buffer.FlushImpl,
    // so the memory manager's write tracker can treat the bytes as GPU data (baseline) instead of a CPU write it reports later.
    // Copies and region objects are pooled (zero allocation in steady state); a region may be disposed on another thread;
    // copies larger than KeepMax are freed on return so a one-off big flush does not stay resident.
    public static unsafe class S2AUntrackedRegionPool
    {
        private const int KeepMax = 16 << 20;

        private sealed class PointerMemory : MemoryManager<byte>
        {
            private byte* _ptr;
            private int _len;

            public void Reset(byte* ptr, int len)
            {
                _ptr = ptr;
                _len = len;
            }

            public override Span<byte> GetSpan() => new(_ptr, _len);

            public override MemoryHandle Pin(int elementIndex = 0) => new(_ptr + elementIndex);

            public override void Unpin()
            {
            }

            protected override void Dispose(bool disposing)
            {
            }
        }

        private sealed class Slot : IWritableBlock
        {
            public byte* Buf;
            public int Cap;
            public bool Used;
            public IVirtualMemoryManagerTracked Target;
            public readonly PointerMemory Mem = new();
            public readonly WritableRegion Region = new(null, 0, Memory<byte>.Empty);

            public void Write(ulong va, ReadOnlySpan<byte> data) => WriteUntracked(va, data);

            public void WriteUntracked(ulong va, ReadOnlySpan<byte> data)
            {
                Target.WriteUntracked(va, data);
                Return(this);
            }
        }

        private static readonly object _lock = new();
        private static Slot[] _slots = new Slot[8];
        private static int _count;

        // No GPU or guest thread may still own a region. A live writer is a shutdown
        // error, never permission to discard its pending write-back into guest memory.
        public static void ResetSession()
        {
            lock (_lock)
            {
                for (int i = 0; i < _count; i++)
                    if (_slots[i].Used) throw new InvalidOperationException("GPU 写回区域尚未归还，禁止重启");
                for (int i = 0; i < _count; i++) NativeMemory.Free(_slots[i].Buf);
                _slots = new Slot[8];
                _count = 0;
            }
        }

        /// <summary>
        /// Rents a writable copy of <paramref name="current"/> (the guest bytes at <paramref name="va"/>) that is written back to
        /// <paramref name="target"/> with WriteUntracked when the region is disposed.
        /// </summary>
        public static WritableRegion Rent(IVirtualMemoryManagerTracked target, ulong va, ReadOnlySpan<byte> current)
        {
            int size = current.Length;
            Slot slot = Acquire(size);

            try
            {
                // 原样拷出目标段：经不走页保护的读（读时回写把这些页设成不可读，直接读会缺页、改两次保护；字节相同）
                if (Ryujinx.Memory.Tracking.MemoryTracking.S2AReadUntracked != null)
                {
                    Ryujinx.Memory.Tracking.MemoryTracking.S2AReadUntracked(va, slot.Buf, size);
                }
                else
                {
                    current.CopyTo(new Span<byte>(slot.Buf, size));
                }
            }
            catch
            {
                Return(slot);
                throw;
            }

            return Bind(slot, target, va, size);
        }

        /// <summary>
        /// Rents a writable copy of the guest bytes at <paramref name="va"/> that is written back to
        /// <paramref name="target"/> with WriteUntracked when the region is disposed. The bytes are
        /// copied by <paramref name="read"/>, which must not borrow a possibly protected page.
        /// </summary>
        public static WritableRegion Rent(IVirtualMemoryManagerTracked target, ulong va, int size, Action<ulong, Memory<byte>> read)
        {
            ArgumentNullException.ThrowIfNull(read);

            Slot slot = Acquire(size);

            try
            {
                slot.Mem.Reset(slot.Buf, size);
                read(va, slot.Mem.Memory);
            }
            catch
            {
                Return(slot);
                throw;
            }

            return Bind(slot, target, va, size);
        }

        private static Slot Acquire(int size)
        {
            Slot slot = null;

            lock (_lock)
            {
                // Among free slots prefer the smallest one that fits, otherwise the largest one (grown below)
                for (int i = 0; i < _count; i++)
                {
                    Slot s = _slots[i];

                    if (s.Used)
                    {
                        continue;
                    }

                    bool fits = s.Cap >= size;

                    if (slot == null || (fits && (slot.Cap < size || s.Cap < slot.Cap)) || (!fits && slot.Cap < size && s.Cap > slot.Cap))
                    {
                        slot = s;
                    }
                }

                if (slot == null)
                {
                    if (_count == _slots.Length)
                    {
                        Array.Resize(ref _slots, _count * 2);
                    }

                    slot = _slots[_count++] = new Slot();
                }

                slot.Used = true;

                if (slot.Cap < size)
                {
                    NativeMemory.Free(slot.Buf);
                    slot.Buf = (byte*)NativeMemory.Alloc((nuint)Math.Max(size, 1));
                    slot.Cap = size;
                }
            }

            return slot;
        }

        private static WritableRegion Bind(Slot slot, IVirtualMemoryManagerTracked target, ulong va, int size)
        {
            slot.Target = target;
            slot.Mem.Reset(slot.Buf, size);
            slot.Region.S2AReuse(slot, va, slot.Mem.Memory);

            return slot.Region;
        }

        private static void Return(Slot slot)
        {
            lock (_lock)
            {
                if (slot.Cap > KeepMax)
                {
                    NativeMemory.Free(slot.Buf);
                    slot.Buf = null;
                    slot.Cap = 0;
                }

                slot.Target = null;
                slot.Used = false;
            }
        }
    }
}
