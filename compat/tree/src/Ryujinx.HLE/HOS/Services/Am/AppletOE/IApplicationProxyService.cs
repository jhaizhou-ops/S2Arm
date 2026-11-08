using Ryujinx.HLE.HOS.Services.Am.AppletOE.ApplicationProxyService;

namespace Ryujinx.HLE.HOS.Services.Am
{
    [Service("appletOE")]
    class IApplicationProxyService : IpcService
    {
        public IApplicationProxyService(ServiceCtx context) { }

        [CommandCmif(0)]
        // OpenApplicationProxy(u64, pid, handle<copy>) -> object<nn::am::service::IApplicationProxy>
        public ResultCode OpenApplicationProxy(ServiceCtx context)
        {
            MakeObject(context, new IApplicationProxy(context.Request.HandleDesc.PId));

            return ResultCode.Success;
        }

        [CommandCmif(10)]
        // OpenApplicationProxyWithFlags(u32 flags, u64, pid, handle<copy>) -> object<nn::am::service::IApplicationProxy>
        // S2Arm：Switch 2 SDK（Pokopia 0400A3A01EE4C000 起局第一条 am 请求）改用这条；多一个 u32 标志，其余同 0（Eden-NS2 只思路，自写）
        public ResultCode OpenApplicationProxyWithFlags(ServiceCtx context)
        {
            return OpenApplicationProxy(context);
        }
    }
}
