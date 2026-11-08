namespace Ryujinx.Graphics.Vulkan
{
    /// <summary>
    /// S2A（#1360）：同通道采样当前深度附件时，若后端没有真正启用 attachment feedback loop
    /// 布局（现有 ChangeFeedbackLoop 路径未生效），只发内存屏障的采样会读到未存回的 tile。
    /// 策略：命中深度 feedback loop 且渲染通道仍在进行时，先结束当前通道（store op 存回），
    /// 下一次 Draw 再 BeginRenderPass；颜色 hazard 不在此列。
    /// </summary>
    internal static class S2AFeedbackLoopPolicy
    {
        public static bool ShouldSplitDepthPass(
            bool feedbackLoopLayoutActive,
            bool feedbackLoopLayoutChanged,
            bool depthHazard,
            bool renderPassActive)
        {
            return !feedbackLoopLayoutActive
                && !feedbackLoopLayoutChanged
                && depthHazard
                && renderPassActive;
        }
    }
}
