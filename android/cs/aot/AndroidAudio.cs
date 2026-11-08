using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using S2A.Audio.AAudio;
using System;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;

namespace S2A.Android.Aot
{
    // Android audio for the service layer: S2A_Init boots Ryujinx with Exports.AudioFactory().
    public static unsafe class AndroidAudio
    {
        [ModuleInitializer]
        internal static void Init() => S2A.Services.Exports.AudioFactory = &Create;

        private static IHardwareDeviceDriver Create() => new AAudioHardwareDeviceDriver();

        // Plays a short quiet tone through the driver the service layer would get, using
        // Ryujinx's session API as the audio system does, and reports the accounting.
        [UnmanagedCallersOnly(EntryPoint = "s2a_android_audio_selftest")]
        public static int Run(byte* buffer, int length)
        {
            string report;
            int failures = 0;
            try
            {
                const int Rate = 48000, Frames = Rate * 400 / 1000;
                IHardwareDeviceDriver driver = S2A.Services.Exports.AudioFactory();
                var session = (AAudioHardwareDeviceSession)driver.OpenDeviceSession(
                    IHardwareDeviceDriver.Direction.Output, null, SampleFormat.PcmInt16, Rate, 2);
                byte[] tone = new byte[Frames * 4];
                for (int i = 0; i < Frames; i++)
                {
                    double fade = Math.Min(1.0, Math.Min(i, Frames - 1 - i) / (Rate * 0.01));
                    short v = (short)(1600 * fade * Math.Sin(2 * Math.PI * 440 * i / Rate));   // about -26 dBFS
                    BitConverter.TryWriteBytes(tone.AsSpan(i * 4), v);
                    BitConverter.TryWriteBytes(tone.AsSpan(i * 4 + 2), v);
                }

                var played = new AudioBuffer { BufferTag = 1, DataPointer = 0x5eed, DataSize = (ulong)tone.Length, Data = tone };
                var update = driver.GetUpdateRequiredEvent();
                update.Reset();
                long wakeStart = session.Wakeups;
                session.QueueBuffer(played);
                var clock = Stopwatch.StartNew();
                session.Start();
                while (!session.WasBufferFullyConsumed(played) && clock.ElapsedMilliseconds < 3000)
                {
                    System.Threading.Thread.Sleep(5);
                }

                long ms = clock.ElapsedMilliseconds;
                ulong samples = session.GetPlayedSampleCount();
                bool signalled = update.WaitOne(0);
                AAudioSink.Stats st = session.GetStats();
                long wakePlaying = session.Wakeups - wakeStart;
                session.Stop();
                System.Threading.Thread.Sleep(300);   // paused: the feeder should stay asleep
                long wakePaused = session.Wakeups - wakeStart - wakePlaying;
                session.Dispose();
                driver.Dispose();
                if (samples != Frames || !signalled || wakePaused > 1)
                {
                    failures++;
                }

                report = $"driver={driver.GetType().Name}; played {samples}/{Frames} frames in {ms} ms (400 ms of audio); "
                    + $"update event {(signalled ? "set" : "NOT set")}; burst {st.BurstFrames}, device buffer {st.BufferFrames} frames, "
                    + $"{(st.Sharing == 0 ? "exclusive" : "shared")}; padded {st.FramesPadded} frames, xruns {st.Xruns}; "
                    + $"feeder wakeups {wakePlaying} while playing, {wakePaused} in 300 ms paused";
            }
            catch (Exception e)
            {
                failures++;
                report = $"FAILED {e.GetType().Name} {e.Message}";
            }

            byte[] text = Encoding.UTF8.GetBytes(report);
            int n = Math.Min(text.Length, length - 1);
            text.AsSpan(0, n).CopyTo(new Span<byte>(buffer, length));
            buffer[n] = 0;
            return failures;
        }
    }
}
