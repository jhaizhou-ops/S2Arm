using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Sdk.Psc;
using Ryujinx.Horizon.Sdk.Sf;

namespace Ryujinx.Horizon.Psc.Ipc
{
    partial class PmService : IPmService
    {
        // S2Arm（缺口扫描族 1，11-01）：原先 psc:m 一个命令都没有，游戏收不到休眠 / 唤醒
        [CmifCommand(0)]
        public Result GetPmModule(out IPmModule module)
        {
            module = new PmModule();

            return Result.Success;
        }
    }
}
