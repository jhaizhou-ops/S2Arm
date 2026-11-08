using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Sdk.Sf;

namespace Ryujinx.Horizon.Sdk.Prepo
{
    interface IAsyncContext : IServiceObject
    {
        Result GetSystemEvent(out int eventHandle);
        Result Cancel();
        Result GetResult();
    }
}
