using Ryujinx.Horizon.Common;
using System;

namespace Ryujinx.Horizon.Sdk.Sf.Cmif
{
    abstract class ServerDomainBase
    {
        public abstract Result ReserveIds(Span<int> outIds);
        public abstract void UnreserveIds(ReadOnlySpan<int> ids);
        public abstract void RegisterObject(int id, ServiceObjectHolder obj);

        public abstract ServiceObjectHolder UnregisterObject(int id);
        public abstract ServiceObjectHolder GetObject(int id);

        // S2Arm: the registered holder itself, for dispatching one message to it (holders are immutable; GetObject's clone is for
        // callers that keep it, e.g. a new session). Was a clone per domain message
        public abstract ServiceObjectHolder GetObjectForDispatch(int id);
    }
}
