using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Sdk.Sf.Hipc;
using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Ryujinx.Horizon.Sdk.Sf.Cmif
{
    class DomainServiceObjectProcessor : ServerMessageProcessor
    {
        public const int MaximumObjects = 8;

        private ServerMessageProcessor _implProcessor;
        private ServerDomainBase _domain;
        private int _outObjectIdsOffset;
        private readonly int[] _inObjectIds;
        private int _inObjectsCount;
        private readonly int[] _reservedObjectIds;
        private ServerMessageRuntimeMetadata _implMetadata;

        private int InObjectsCount => _inObjectsCount;

        // S2Arm: one spare processor per thread, reset per message (see DomainServiceObjectDispatchTable)
        [ThreadStatic]
        private static DomainServiceObjectProcessor _spare;

        public static DomainServiceObjectProcessor Rent(ServerDomainBase domain, int inObjectsCount)
        {
            DomainServiceObjectProcessor processor = _spare ?? new DomainServiceObjectProcessor();
            _spare = null;

            processor._implProcessor = null;
            processor._domain = domain;
            processor._outObjectIdsOffset = 0;
            processor._inObjectsCount = inObjectsCount;
            processor._implMetadata = default;
            processor._inObjectIds.AsSpan().Clear();
            processor._reservedObjectIds.AsSpan().Clear();

            return processor;
        }

        public static void Return(DomainServiceObjectProcessor processor)
        {
            processor._implProcessor = null;
            processor._domain = null;
            _spare = processor;
        }

        private DomainServiceObjectProcessor()
        {
            _inObjectIds = new int[MaximumObjects];
            _reservedObjectIds = new int[MaximumObjects];
        }
        private int OutObjectsCount => _implMetadata.OutObjectsCount;
        private int ImplOutDataTotalSize => _implMetadata.OutDataSize + _implMetadata.OutHeadersSize;

        public override void SetImplementationProcessor(ServerMessageProcessor impl)
        {
            if (_implProcessor == null)
            {
                _implProcessor = impl;
            }
            else
            {
                _implProcessor.SetImplementationProcessor(impl);
            }

            _implMetadata = _implProcessor.GetRuntimeMetadata();
        }

        public override ServerMessageRuntimeMetadata GetRuntimeMetadata()
        {
            ServerMessageRuntimeMetadata runtimeMetadata = _implProcessor.GetRuntimeMetadata();

            return new ServerMessageRuntimeMetadata(
                (ushort)(runtimeMetadata.InDataSize + runtimeMetadata.InObjectsCount * sizeof(int)),
                (ushort)(runtimeMetadata.OutDataSize + runtimeMetadata.OutObjectsCount * sizeof(int)),
                (byte)(runtimeMetadata.InHeadersSize + Unsafe.SizeOf<CmifDomainInHeader>()),
                (byte)(runtimeMetadata.OutHeadersSize + Unsafe.SizeOf<CmifDomainOutHeader>()),
                0,
                0);
        }

        public override Result PrepareForProcess(ref ServiceDispatchContext context, ServerMessageRuntimeMetadata runtimeMetadata)
        {
            if (_implMetadata.InObjectsCount != InObjectsCount)
            {
                return SfResult.InvalidInObjectsCount;
            }

            Result result = _domain.ReserveIds(new Span<int>(_reservedObjectIds)[..OutObjectsCount]);

            if (result.IsFailure)
            {
                return result;
            }

            return _implProcessor.PrepareForProcess(ref context, runtimeMetadata);
        }

        public override Result GetInObjects(Span<ServiceObjectHolder> inObjects)
        {
            for (int i = 0; i < InObjectsCount; i++)
            {
                inObjects[i] = _domain.GetObject(_inObjectIds[i]);
            }

            return Result.Success;
        }

        public override HipcMessageData PrepareForReply(scoped ref ServiceDispatchContext context, out Span<byte> outRawData, ServerMessageRuntimeMetadata runtimeMetadata)
        {
            HipcMessageData response = _implProcessor.PrepareForReply(ref context, out outRawData, runtimeMetadata);

            int outHeaderSize = Unsafe.SizeOf<CmifDomainOutHeader>();
            int implOutDataTotalSize = ImplOutDataTotalSize;

            DebugUtil.Assert(outHeaderSize + implOutDataTotalSize + OutObjectsCount * sizeof(int) <= outRawData.Length);

            outRawData = outRawData[outHeaderSize..];
            _outObjectIdsOffset = (response.DataWords.Length * sizeof(uint) - outRawData.Length) + implOutDataTotalSize;

            return response;
        }

        public override void PrepareForErrorReply(scoped ref ServiceDispatchContext context, out Span<byte> outRawData, ServerMessageRuntimeMetadata runtimeMetadata)
        {
            _implProcessor.PrepareForErrorReply(ref context, out outRawData, runtimeMetadata);

            int outHeaderSize = Unsafe.SizeOf<CmifDomainOutHeader>();
            int implOutDataTotalSize = ImplOutDataTotalSize;

            DebugUtil.Assert(outHeaderSize + implOutDataTotalSize <= outRawData.Length);

            outRawData = outRawData[outHeaderSize..];

            _domain.UnreserveIds(new Span<int>(_reservedObjectIds)[..OutObjectsCount]);
        }

        public override void SetOutObjects(scoped ref ServiceDispatchContext context, HipcMessageData response, Span<ServiceObjectHolder> outObjects)
        {
            int outObjectsCount = OutObjectsCount;
            Span<int> objectIds = _reservedObjectIds;

            for (int i = 0; i < outObjectsCount; i++)
            {
                if (outObjects[i] == null)
                {
                    _domain.UnreserveIds(objectIds.Slice(i, 1));
                    objectIds[i] = 0;
                    continue;
                }

                _domain.RegisterObject(objectIds[i], outObjects[i]);
            }

            Span<int> outObjectIds = MemoryMarshal.Cast<byte, int>(MemoryMarshal.Cast<uint, byte>(response.DataWords)[_outObjectIdsOffset..]);

            for (int i = 0; i < outObjectsCount; i++)
            {
                outObjectIds[i] = objectIds[i];
            }
        }
    }
}
