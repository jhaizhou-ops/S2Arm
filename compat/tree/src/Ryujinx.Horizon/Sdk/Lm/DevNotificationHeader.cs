using System.Runtime.InteropServices;

namespace Ryujinx.Horizon.Sdk.Lm
{
    // S2Arm: nn::diag::DevNotificationHeader as sent by lm ILogger 3 (DevNotify): 0x28 bytes of in-data, copied verbatim by the SDK
    //   (Zelda OoT Switch 2 sdk proxy). The meaning of its fields is not known; the service keeps it opaque.
    [StructLayout(LayoutKind.Sequential, Size = 0x28, Pack = 1)]
    struct DevNotificationHeader
    {
    }
}
