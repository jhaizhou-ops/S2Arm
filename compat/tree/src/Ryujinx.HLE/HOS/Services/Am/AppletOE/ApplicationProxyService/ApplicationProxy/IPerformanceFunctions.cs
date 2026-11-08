namespace Ryujinx.HLE.HOS.Services.Am.AppletOE.ApplicationProxyService.ApplicationProxy
{
    // S2Arm：Switch 2 的 nn::am::service::IPerformanceFunctions（IApplicationProxy 命令 40；nn::oe::IsCpuOverclockEnabled / SetCpuOverclockEnabled 经它走）。
    // 宿主不调 CPU 频率：开关只记下来，问时回游戏设的值，起局为关。命令号来自 Eden-NS2（GPL，只借事实），语义同 the reference port hle_oe.c（MIT）
    class IPerformanceFunctions : IpcService
    {
        private bool _cpuOverclock;

        [CommandCmif(0)]
        // IsCpuOverclockEnabled() -> b8
        public ResultCode IsCpuOverclockEnabled(ServiceCtx context)
        {
            context.ResponseData.Write(_cpuOverclock);

            return ResultCode.Success;
        }

        [CommandCmif(1)]
        // SetCpuOverclockEnabled(b8)
        public ResultCode SetCpuOverclockEnabled(ServiceCtx context)
        {
            _cpuOverclock = context.RequestData.ReadBoolean();

            return ResultCode.Success;
        }
    }
}
