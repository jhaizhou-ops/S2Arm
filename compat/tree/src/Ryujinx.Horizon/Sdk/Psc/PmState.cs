namespace Ryujinx.Horizon.Sdk.Psc
{
    // 电源状态（psc 向各模块发的请求；值同主机）
    enum PmState : uint
    {
        FullAwake = 0,
        MinimumAwake = 1,
        SleepReady = 2,
        EssentialServicesSleepReady = 3,
        EssentialServicesAwake = 4,
        ShutdownReady = 5,
        Invalid = 6,
    }
}
