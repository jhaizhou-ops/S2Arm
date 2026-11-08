using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using Ryujinx.Memory;
using System;
using System.Threading;
using static Ryujinx.Audio.Integration.IHardwareDeviceDriver;

namespace Ryujinx.Audio.Backends.Dummy
{
    public class DummyHardwareDeviceDriver : IHardwareDeviceDriver
    {
        private readonly ManualResetEvent _updateRequiredEvent = new(false);
        private readonly ManualResetEvent _pauseEvent = new(true);

        public static bool IsSupported => true;

        public float Volume { get; set; } = 1f;

        public IHardwareDeviceSession OpenDeviceSession(Direction direction, IVirtualMemoryManager memoryManager, SampleFormat sampleFormat, uint sampleRate, uint channelCount)
        {
            if (sampleRate == 0)
            {
                sampleRate = Constants.TargetSampleRate;
            }

            if (channelCount == 0)
            {
                channelCount = 2;
            }

            if (direction == Direction.Output)
            {
                return new DummyHardwareDeviceSessionOutput(this, memoryManager, sampleFormat, sampleRate, channelCount);
            }

            return new DummyHardwareDeviceSessionInput(this, memoryManager);
        }

        public ManualResetEvent GetUpdateRequiredEvent()
        {
            return _updateRequiredEvent;
        }

        public ManualResetEvent GetPauseEvent()
        {
            return _pauseEvent;
        }

        public void Dispose()
        {
            GC.SuppressFinalize(this);
            Dispose(true);
        }

        private void Dispose(bool disposing)
        {
            if (disposing)
            {
                // NOTE: The _updateRequiredEvent will be disposed somewhere else.
                _pauseEvent.Dispose();
            }
        }

        public bool SupportsSampleRate(uint sampleRate)
        {
            return true;
        }

        public bool SupportsSampleFormat(SampleFormat sampleFormat)
        {
            return true;
        }

        public bool SupportsDirection(Direction direction)
        {
            return direction is Direction.Output or Direction.Input;
        }

        public bool SupportsChannelCount(uint channelCount)
        {
            // S2Arm: stereo only (was 1, 2 or 6). Reporting 5.1 made the renderer mix and output 6 channels (virtual device
            // AudioTvOutput reports 6 to the game, every output device takes 240 x 6 samples per 5 ms) for a device that plays nothing;
            // now the same as the cheapest real configuration (Apple backend with surround off: 1 / 2 yes, 6 no)
            return channelCount is 1 or 2;
        }
    }
}
