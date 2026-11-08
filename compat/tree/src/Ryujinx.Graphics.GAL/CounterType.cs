namespace Ryujinx.Graphics.GAL
{
    public enum CounterType
    {
        SamplesPassed,
        PrimitivesGenerated,
        TransformFeedbackPrimitivesWritten,
        // S2A（帧率能耗线 10-23，S2A_GPU_TS）：结果 = 报告所在命令段在 GPU 上的结束时刻（主机单调时钟纳秒）；后端不支持时不应收到这一类
        S2ATimestamp,
    }
}
