using Ryujinx.Horizon.Common;

namespace Ryujinx.Horizon.Sdk.Psc
{
    // psc 结果码（值同主机，Atmosphère psc_results.hpp / switchbrew 错误码表）
    static class PscResult
    {
        private const int ModuleId = 138;

        public static Result NotInitialized => new(ModuleId, 3);
    }
}
