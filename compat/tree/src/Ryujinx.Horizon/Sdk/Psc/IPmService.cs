using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Sdk.Sf;

namespace Ryujinx.Horizon.Sdk.Psc
{
    interface IPmService : IServiceObject
    {
        Result GetPmModule(out IPmModule module);
    }
}
