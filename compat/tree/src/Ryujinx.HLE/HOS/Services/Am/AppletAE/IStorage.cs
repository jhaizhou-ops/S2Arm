using Ryujinx.Memory;
using System;
using System.Runtime.InteropServices;

namespace Ryujinx.HLE.HOS.Services.Am.AppletAE
{
    // S2Arm: storage data is Memory<byte> so it can be a view of the game's transfer memory (no copy) or native memory owned by the
    // storage (CreateStorage of a game-chosen size), instead of a managed array of the requested length (iPhone low address space is scarce)
    class IStorage : IpcService, IDisposable
    {
        public bool IsReadOnly { get; private set; }
        public Memory<byte> Data { get; private set; }

        private unsafe byte* _native;

        public IStorage(byte[] data, bool isReadOnly = false)
        {
            IsReadOnly = isReadOnly;
            Data = data;
        }

        public IStorage(Memory<byte> data, bool isReadOnly = false)
        {
            IsReadOnly = isReadOnly;
            Data = data;
        }

        // Zeroed native memory owned by this storage, freed on Dispose
        public static unsafe IStorage CreateNative(int size)
        {
            byte* p = (byte*)NativeMemory.AllocZeroed((nuint)size);

            return new IStorage(new NativeMemoryManager<byte>(p, size).Memory) { _native = p };
        }

        public unsafe void Dispose()
        {
            if (_native != null)
            {
                NativeMemory.Free(_native);
                _native = null;
                Data = Memory<byte>.Empty;
            }
        }

        [CommandCmif(0)]
        // Open() -> object<nn::am::service::IStorageAccessor>
        public ResultCode Open(ServiceCtx context)
        {
            MakeObject(context, new IStorageAccessor(this));

            return ResultCode.Success;
        }
    }
}
