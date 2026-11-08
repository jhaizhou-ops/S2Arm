using Ryujinx.HLE.HOS.Kernel.Threading;

namespace Ryujinx.HLE.HOS.Services.Bluetooth.BluetoothDriver
{
    static class BluetoothEventManager
    {
        internal static void S2AReset()
        {
            InitializeBleDebugEvent = UnknownBleDebugEvent = RegisterBleDebugEvent = null;
            InitializeBleEvent = UnknownBleEvent = RegisterBleEvent = null;
            InitializeBleDebugEventHandle = UnknownBleDebugEventHandle = RegisterBleDebugEventHandle = 0;
            InitializeBleEventHandle = UnknownBleEventHandle = RegisterBleEventHandle = 0;
        }
        public static KEvent InitializeBleDebugEvent;
        public static int InitializeBleDebugEventHandle;

        public static KEvent UnknownBleDebugEvent;
        public static int UnknownBleDebugEventHandle;

        public static KEvent RegisterBleDebugEvent;
        public static int RegisterBleDebugEventHandle;

        public static KEvent InitializeBleEvent;
        public static int InitializeBleEventHandle;

        public static KEvent UnknownBleEvent;
        public static int UnknownBleEventHandle;

        public static KEvent RegisterBleEvent;
        public static int RegisterBleEventHandle;
    }
}
