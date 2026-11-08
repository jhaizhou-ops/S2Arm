using Ryujinx.Common.Memory;
using System;

namespace Ryujinx.Memory
{
    public sealed class WritableRegion : IDisposable
    {
        private IWritableBlock _block;
        private ulong _va;
        private readonly MemoryOwner<byte> _memoryOwner;
        private readonly bool _tracked;

        private bool NeedsWriteback => _block != null;

        public Memory<byte> Memory { get; private set; }

        // S2Arm: re-point a region that has no write-back block (Dispose is then a no-op), so a memory manager whose
        // memory is directly addressable can hand out regions without allocating one per call
        public void S2AReuse(Memory<byte> memory)
        {
            if (NeedsWriteback || _memoryOwner != null)
            {
                throw new InvalidOperationException("S2Arm: only regions without write-back can be reused");
            }

            Memory = memory;
        }

        // S2Arm: re-point a region that writes back through `block` on Dispose (untracked: block.WriteUntracked) and owns no memory,
        // so a memory manager can hand out write-back regions over its own reused scratch without allocating one per call
        public void S2AReuse(IWritableBlock block, ulong va, Memory<byte> memory)
        {
            if (_memoryOwner != null || _tracked)
            {
                throw new InvalidOperationException("S2Arm: only untracked regions without owned memory can be reused with a block");
            }

            _block = block;
            _va = va;
            Memory = memory;
        }

        public WritableRegion(IWritableBlock block, ulong va, Memory<byte> memory, bool tracked = false)
        {
            _block = block;
            _va = va;
            _tracked = tracked;
            Memory = memory;
        }

        public WritableRegion(IWritableBlock block, ulong va, MemoryOwner<byte> memoryOwner, bool tracked = false)
            : this(block, va, memoryOwner.Memory, tracked)
        {
            _memoryOwner = memoryOwner;
        }

        public void Dispose()
        {
            if (NeedsWriteback)
            {
                if (_tracked)
                {
                    _block.Write(_va, Memory.Span);
                }
                else
                {
                    _block.WriteUntracked(_va, Memory.Span);
                }
            }

            _memoryOwner?.Dispose();
        }
    }
}
