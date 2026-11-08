using System;
using System.Collections.Generic;

namespace Ryujinx.Graphics.Gpu.Memory
{
    // S2Arm: one instance per MemoryManager is reused for every map / unmap (under the page table lock), and remap actions
    // are registered as a static callback plus a state object instead of capturing closures, so the per-frame map / unmap
    // pattern of games (nvhost-as MapBufferEx / UnmapBuffer) does not allocate.
    public class UnmapEventArgs
    {
        public ulong Address { get; private set; }
        public ulong Size { get; private set; }

        private readonly List<(Action<object, ulong, ulong> Action, object State)> _remapActions = [];

        public UnmapEventArgs(ulong address, ulong size)
        {
            Address = address;
            Size = size;
        }

        internal void Reset(ulong address, ulong size)
        {
            Address = address;
            Size = size;
            _remapActions.Clear();
        }

        /// <summary>
        /// Registers an action to run after the mapping completes; it receives <paramref name="state"/>, the address and the size.
        /// </summary>
        public void AddRemapAction(Action<object, ulong, ulong> action, object state)
        {
            _remapActions.Add((action, state));
        }

        internal void RunRemapActions()
        {
            foreach ((Action<object, ulong, ulong> action, object state) in _remapActions)
            {
                action(state, Address, Size);
            }
        }
    }
}
