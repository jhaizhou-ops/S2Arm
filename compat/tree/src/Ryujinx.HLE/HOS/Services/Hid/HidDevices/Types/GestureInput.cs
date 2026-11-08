using System.Runtime.InteropServices;

namespace Ryujinx.HLE.HOS.Services.Hid
{
    // Horizon ABI, also documented by switchbrew/libnx services/hid.h.
    public enum GestureType : uint { Idle, Complete, Cancel, Touch, Press, Tap, Pan, Swipe, Pinch, Rotate }
    public enum GestureDirection : uint { None, Left, Up, Right, Down }
    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    public struct GesturePoint { public uint X, Y; }
    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    public struct GestureInput
    {
        public ulong ContextNumber;
        public GestureType Type;
        public GestureDirection Direction;
        public uint X, Y;
        public int DeltaX, DeltaY;
        public float VelocityX, VelocityY;
        public uint Attributes;
        public float Scale, RotationAngle;
        public int PointCount;
        public GesturePoint Point0, Point1, Point2, Point3;
    }
}
