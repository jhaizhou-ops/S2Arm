// 测试替身：生产 NativeTickSource.cs（10-29 #863 起）引用 Ryujinx.HLE.S2AHooks 的两个成员；本单测只验时钟提供者归属，不链整个 Ryujinx.HLE。
// 签名对齐 compat/tree/src/Ryujinx.HLE/S2AHooks.cs（TickUnseenNs / SteadyClockCatchUp）；那边改签名这里编译即红
namespace Ryujinx.HLE
{
    static class S2AHooks
    {
        public static System.Func<long> TickUnseenNs;
        public static void SteadyClockCatchUp() { }
    }
}
