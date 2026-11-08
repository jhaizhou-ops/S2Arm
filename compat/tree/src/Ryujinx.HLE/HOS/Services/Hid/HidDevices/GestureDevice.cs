using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.Common;
using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.Gesture;
using System;

namespace Ryujinx.HLE.HOS.Services.Hid
{
    // Explicitly constructed by an opt-in platform provider. The default HID
    // initialization does not write the previously reserved gesture region.
    public sealed class GestureDevice
    {
        private readonly Switch _device;
        private ulong _samplingNumber;

        public GestureDevice(Switch device)
        {
            _device = device;
            _device.Hid.SharedMemory.Gesture = RingLifo<GestureState>.Create();
        }

        internal static void Write(ref RingLifo<GestureState> ring, ref ulong samplingNumber, in GestureInput input)
        {
            if (input.PointCount < 0 || input.PointCount > 4 || (uint)input.Type > (uint)GestureType.Rotate ||
                (uint)input.Direction > (uint)GestureDirection.Down || !float.IsFinite(input.Scale) ||
                !float.IsFinite(input.RotationAngle) || !float.IsFinite(input.VelocityX) ||
                !float.IsFinite(input.VelocityY) || samplingNumber == ulong.MaxValue)
                throw new ArgumentException("Invalid gesture HID state.");
            GestureState state = new() { SamplingNumber = ++samplingNumber, Input = input };
            ring.Write(ref state);
        }

        public void Update(GestureInput input) => Write(ref _device.Hid.SharedMemory.Gesture, ref _samplingNumber, in input);
        public void Clear() => _device.Hid.SharedMemory.Gesture.Clear();
    }
}
