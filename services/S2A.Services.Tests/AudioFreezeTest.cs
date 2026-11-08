// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Reflection;
using System.Text;
using System.Threading;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private static int _audioFreezeState, _audioFocusState = 1;
        private static int AudioFreezeState() => _audioFreezeState;
        private static int AudioFocusState() => _audioFocusState;

        [SoloTest("--audio-freeze", Booted = true)]
        private static void AudioFreeze()
        {
            var previousFrozen = Native.GuestFrozen;
            var previousFocus = Native.HostFocused;
            var pause = Host.Device.AudioDeviceDriver.GetPauseEvent();
            try
            {
                Native.GuestFrozen = &AudioFreezeState;
                Native.HostFocused = &AudioFocusState;
                _audioFreezeState = 0;
                _audioFocusState = 1;
                Lifecycle.Attach();
                Check("audio freeze: initial audio runs", "True", pause.WaitOne(0).ToString());

                _audioFocusState = 0;
                Lifecycle.Tick(Host.Device.System);
                Check("audio freeze: focus loss without guest freeze keeps audio running", "True", pause.WaitOne(0).ToString());

                _audioFreezeState = 1;
                Lifecycle.Tick(Host.Device.System);
                Check("audio freeze: frozen guest pauses audio", "False", pause.WaitOne(0).ToString());
                Lifecycle.Tick(Host.Device.System);
                Check("audio freeze: repeated frozen tick stays paused", "False", pause.WaitOne(0).ToString());

                using var entered = new ManualResetEventSlim();
                Thread renderer = new(() => { entered.Set(); pause.WaitOne(); }) { IsBackground = true };
                renderer.Start();
                if (!entered.Wait(3000)) throw new TimeoutException("audio pause observer did not start");
                Check("audio freeze: processor wait remains blocked", "False", renderer.Join(50).ToString());

                _audioFreezeState = 0;
                Lifecycle.Tick(Host.Device.System);
                Check("audio freeze: thaw resumes audio", "True", pause.WaitOne(0).ToString());
                Check("audio freeze: thaw wakes processor wait", "True", renderer.Join(3000).ToString());

                _audioFreezeState = 1;
                Lifecycle.Attach();
                Check("audio freeze: attach during freeze starts paused", "False", pause.WaitOne(0).ToString());
                _audioFreezeState = 0;
                Lifecycle.Tick(Host.Device.System);
                Check("audio freeze: thaw after frozen attach resumes", "True", pause.WaitOne(0).ToString());

                Native.GuestFrozen = null;
                Lifecycle.Attach();
                Lifecycle.Tick(Host.Device.System);
                Check("audio freeze: absent provider preserves running audio", "True", pause.WaitOne(0).ToString());
            }
            finally
            {
                pause.Set();
                Native.GuestFrozen = previousFrozen;
                Native.HostFocused = previousFocus;
                Lifecycle.Attach();
            }
        }

        [SoloTest("--lifecycle-messages", Booted = true)]
        private static void LifecycleMessageRegression()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            var (rc, registers) = Svc(0x1F, 0, 0, (ulong)_game);
            uint sm = (uint)registers[1];
            Check("lifecycle regression: connect sm", "Handled", rc == SvcResult.Handled ? "Handled" : "Unhandled");
            Msg init = Msg.Cmif(0, Bytes(0L));
            init.SendPid = true;
            Check("lifecycle regression: initialize sm", 0u, Call(sm, init).Result);
            LifecycleMessages(sm);
            FakeNative.HandleClose(sm);
        }

        private sealed class AudioPauseObserver : WaitHandle
        {
            public AudioPauseObserver(WaitHandle source)
            {
                SafeWaitHandle = new(source.SafeWaitHandle.DangerousGetHandle(), ownsHandle: false);
            }
        }

        [SoloTest("--audio-freeze-shutdown-process", Booted = true)]
        private static void AudioFreezeShutdownProcess() => AudioFreezeShutdown("ProcessExit");

        [SoloTest("--audio-freeze-shutdown-guest", Booted = true)]
        private static void AudioFreezeShutdownGuest() => AudioFreezeShutdown("GuestJoined");

        private static void AudioFreezeShutdown(string mode)
        {
            var pause = Host.Device.AudioDeviceDriver.GetPauseEvent();
            var handle = pause.SafeWaitHandle;
            bool retained = false;
            handle.DangerousAddRef(ref retained);
            try
            {
                // Keep an independent observer alive after the driver disposes its
                // event. The real shutdown path must wake a paused audio processor.
                using var observer = new AudioPauseObserver(pause);
                pause.Reset();
                Check($"{mode}: audio paused before shutdown", "False", observer.WaitOne(0).ToString());
                Check($"{mode}: native freeze does not set Horizon.IsPaused", "False", Host.Device.System.IsPaused.ToString());
                Exports.AfterGuestJoinedShutdown = static _ => { };
                Exports.AfterShutdown = static _ => { }; // Service/audio contract, no GPU fixture.
                const BindingFlags flags = BindingFlags.NonPublic | BindingFlags.Static;
                Type shutdownMode = typeof(Exports).GetNestedType("ShutdownMode", BindingFlags.NonPublic);
                typeof(Exports).GetMethod("ShutdownManaged", flags).Invoke(null,
                    new object[] { Enum.Parse(shutdownMode, mode), "audio freeze regression" });
                Check($"{mode}: shutdown wakes audio before disposing it", "True", observer.WaitOne(0).ToString());
            }
            finally
            {
                if (retained) handle.DangerousRelease();
            }
        }
    }
}
