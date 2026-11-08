using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.Common;
using Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.TouchScreen;
using System;

namespace Ryujinx.HLE.HOS.Services.Hid
{
    public class TouchDevice : BaseDevice
    {
        public TouchDevice(Switch device, bool active) : base(device, active) { }

        // S2Arm: last mode the game passed to SetTouchScreenConfiguration; -1 = never configured.
        public volatile int ConfiguredMode = -1;

        public void Update(params ReadOnlySpan<TouchPoint> points)
            => UpdateWithIds(points, default);

        // Optional stable host IDs; existing callers retain index-based IDs.
        public void UpdateWithIds(ReadOnlySpan<TouchPoint> points, ReadOnlySpan<uint> fingerIds)
        {
            if (!fingerIds.IsEmpty && (points.Length > 16 || fingerIds.Length != points.Length))
                throw new ArgumentException("Invalid touch point / finger ID count.");
            ref RingLifo<TouchScreenState> lifo = ref _device.Hid.SharedMemory.TouchScreen;

            ref TouchScreenState previousEntry = ref lifo.GetCurrentEntryRef();

            TouchScreenState newState = new()
            {
                SamplingNumber = previousEntry.SamplingNumber + 1,
            };

            if (Active)
            {
                newState.TouchesCount = points.Length;

                Span<TouchState> touchesSpan = newState.Touches.AsSpan();
                
                int pointsLength = Math.Min(points.Length, touchesSpan.Length);

                for (int i = 0; i < pointsLength; ++i)
                {
                    TouchPoint pi = points[i];
                    touchesSpan[i] = new TouchState
                    {
                        DeltaTime = newState.SamplingNumber,
                        Attribute = pi.Attribute,
                        X = pi.X,
                        Y = pi.Y,
                        FingerId = fingerIds.IsEmpty ? (uint)i : fingerIds[i],
                        DiameterX = pi.DiameterX,
                        DiameterY = pi.DiameterY,
                        RotationAngle = pi.Angle,
                    };
                }
            }

            lifo.Write(ref newState);
        }
    }
}
