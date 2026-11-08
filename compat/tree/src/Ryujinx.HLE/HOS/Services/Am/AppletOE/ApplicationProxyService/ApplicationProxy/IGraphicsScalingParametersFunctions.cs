namespace Ryujinx.HLE.HOS.Services.Am.AppletOE.ApplicationProxyService.ApplicationProxy
{
    // S2Arm：Switch 2 的 nn::am::service::IGraphicsScalingParametersFunctions（IApplicationProxy 命令 60）。
    // SDK 的 nn::oe::GetCurrentGraphicsScale 取命令 10 的头一个字，按 10 / 20 / 30 映射成画面档 0 / 1 / 2（the reference port hle_oe.c 的读数）；
    // 主机实际在哪个模式报哪一档没量过：掌机报 10（档 0）、底座报 20（档 1），随运行模式走（同 参考实现 的选择）。后两个字是屏幕比例分子 / 分母，报 1 / 1。
    // 命令号与字段来自 Eden-NS2（GPL，只借事实，代码自写）
    class IGraphicsScalingParametersFunctions : IpcService
    {
        [CommandCmif(10)]
        // GetGraphicsScalingParameters() -> (u32 scale, u32 ratio_numerator, u32 ratio_denominator)
        public ResultCode GetGraphicsScalingParameters(ServiceCtx context)
        {
            context.ResponseData.Write(context.Device.System.State.DockedMode ? 20u : 10u);
            context.ResponseData.Write(1u);
            context.ResponseData.Write(1u);

            return ResultCode.Success;
        }

        [CommandCmif(1050)]
        // SetGraphicsScaleChangedNotificationEnabled(b8)：画面档只随运行模式变，宿主不单独发这条通知
        public ResultCode SetGraphicsScaleChangedNotificationEnabled(ServiceCtx context)
        {
            return ResultCode.Success;
        }
    }
}
