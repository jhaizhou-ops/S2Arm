using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.Common;
using System.Runtime.InteropServices;

namespace Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.Gesture
{
    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    struct GestureState : ISampledDataStruct
    {
        public ulong SamplingNumber;
        public GestureInput Input;
    }
}
