using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Sdk.Sf;
using System;

namespace Ryujinx.Horizon.Sdk.Psc
{
    interface IPmModule : IServiceObject
    {
        Result Initialize(out int eventHandle, uint moduleId, ReadOnlySpan<uint> dependencies);
        Result GetRequest(out PmState state, out uint flags);
        Result Acknowledge();
        Result Finalize();
        Result AcknowledgeEx(PmState state);
    }
}
