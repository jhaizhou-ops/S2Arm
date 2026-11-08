namespace Ryujinx.Graphics.GAL
{
    /// <summary>
    /// S2A 诊断（帧率能耗线 10-23，马车8 进赛道首帧读回 68 ms）：Gpu 层触发贴图回写前设「读回来源」，后端读回统计（NxGal S2A_GETDATA_BT）拼进键。
    /// 不用线程局部：线程化渲染器里真正读的是渲染线程，GPU 线程同步等它。只作诊断，关着时不读
    /// </summary>
    public static class S2AReadTag
    {
        public static volatile string Current;
    }
}
