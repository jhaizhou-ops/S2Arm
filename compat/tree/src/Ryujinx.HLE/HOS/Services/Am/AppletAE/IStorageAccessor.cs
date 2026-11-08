using System;

namespace Ryujinx.HLE.HOS.Services.Am.AppletAE
{
    class IStorageAccessor : IpcService
    {
        private readonly IStorage _storage;

        public IStorageAccessor(IStorage storage)
        {
            _storage = storage;
        }

        [CommandCmif(0)]
        // GetSize() -> u64
        public ResultCode GetSize(ServiceCtx context)
        {
            context.ResponseData.Write((long)_storage.Data.Length);

            return ResultCode.Success;
        }

        [CommandCmif(10)]
        // Write(u64, buffer<bytes, 0x21>)
        public ResultCode Write(ServiceCtx context)
        {
            if (_storage.IsReadOnly)
            {
                return ResultCode.ObjectInvalid;
            }

            ulong writePosition = context.RequestData.ReadUInt64();

            if (writePosition > (ulong)_storage.Data.Length)
            {
                return ResultCode.OutOfBounds;
            }

            (ulong position, ulong size) = context.Request.GetBufferType0x21();

            size = Math.Min(size, (ulong)_storage.Data.Length - writePosition);

            if (size > 0)
            {
                ulong maxSize = (ulong)_storage.Data.Length - writePosition;

                if (size > maxSize)
                {
                    size = maxSize;
                }

                // S2Arm: copy straight from the game buffer into the storage (no intermediate array of the request length)
                context.Memory.GetSpan(position, (int)size).CopyTo(_storage.Data.Span[(int)writePosition..]);
            }

            return ResultCode.Success;
        }

        [CommandCmif(11)]
        // Read(u64) -> buffer<bytes, 0x22>
        public ResultCode Read(ServiceCtx context)
        {
            ulong readPosition = context.RequestData.ReadUInt64();

            if (readPosition > (ulong)_storage.Data.Length)
            {
                return ResultCode.OutOfBounds;
            }

            (ulong position, ulong size) = context.Request.GetBufferType0x22();

            size = Math.Min(size, (ulong)_storage.Data.Length - readPosition);

            // S2Arm: copy straight from the storage into the game buffer (no intermediate array of the request length)
            context.Memory.Write(position, _storage.Data.Span.Slice((int)readPosition, (int)size));

            return ResultCode.Success;
        }
    }
}
