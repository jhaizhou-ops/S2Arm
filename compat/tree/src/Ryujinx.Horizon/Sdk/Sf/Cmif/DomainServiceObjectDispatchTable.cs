using Ryujinx.Horizon.Common;
using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Ryujinx.Horizon.Sdk.Sf.Cmif
{
    class DomainServiceObjectDispatchTable : ServiceDispatchTableBase
    {
        public override Result ProcessMessage(ref ServiceDispatchContext context, ReadOnlySpan<byte> inRawData)
        {
            return ProcessMessageImpl(ref context, ((DomainServiceObject)context.ServiceObject).GetServerDomain(), inRawData);
        }

        private static Result ProcessMessageImpl(ref ServiceDispatchContext context, ServerDomainBase domain, ReadOnlySpan<byte> inRawData)
        {
            if (inRawData.Length < Unsafe.SizeOf<CmifDomainInHeader>())
            {
                return SfResult.InvalidHeaderSize;
            }

            CmifDomainInHeader inHeader = MemoryMarshal.Cast<byte, CmifDomainInHeader>(inRawData)[0];

            ReadOnlySpan<byte> inDomainRawData = inRawData[Unsafe.SizeOf<CmifDomainInHeader>()..];

            int targetObjectId = inHeader.ObjectId;

            switch (inHeader.Type)
            {
                case CmifDomainRequestType.SendMessage:
                    ServiceObjectHolder targetObject = domain.GetObjectForDispatch(targetObjectId);
                    if (targetObject == null)
                    {
                        return SfResult.TargetNotFound;
                    }

                    if (inHeader.DataSize + inHeader.ObjectsCount * sizeof(int) > inDomainRawData.Length)
                    {
                        return SfResult.InvalidHeaderSize;
                    }

                    ReadOnlySpan<byte> inMessageRawData = inDomainRawData[..inHeader.DataSize];

                    if (inHeader.ObjectsCount > DomainServiceObjectProcessor.MaximumObjects)
                    {
                        return SfResult.InvalidInObjectsCount;
                    }

                    // S2Arm: the processor only lives for this message — take the thread's spare one (was a new processor + two id
                    // arrays per domain message, 176 B; d3 polls a domain object ~85 times a second). A nested dispatch on the same
                    // thread finds no spare and gets its own, as before
                    DomainServiceObjectProcessor domainProcessor = DomainServiceObjectProcessor.Rent(domain, inHeader.ObjectsCount);

                    if (context.Processor == null)
                    {
                        context.Processor = domainProcessor;
                    }
                    else
                    {
                        context.Processor.SetImplementationProcessor(domainProcessor);
                    }

                    context.ServiceObject = targetObject.ServiceObject;

                    try
                    {
                        return targetObject.ProcessMessage(ref context, inMessageRawData);
                    }
                    finally
                    {
                        DomainServiceObjectProcessor.Return(domainProcessor);
                    }

                case CmifDomainRequestType.Close:
                    domain.UnregisterObject(targetObjectId);
                    return Result.Success;

                default:
                    return SfResult.InvalidInHeader;
            }
        }
    }
}
