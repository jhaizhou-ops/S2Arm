// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Collections.Generic;
using Ryujinx.HLE.HOS.Applets;
using Ryujinx.HLE.HOS.Services.Hid;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        // Exercise the same keyboard HID ring as the existing keyboard-hid test, while
        // the local-controller branch owns commits and bypasses the legacy loop.
        [SoloTest("--local-keyboard-commit", Booted = true)]
        private static void LocalKeyboardCommit()
        {
            InputPump.Stop();
            var oldRead = InputPump._kbRead;
            var oldFeedback = InputPump.LocalFeedbackApi;
            var oldMerge = InputPump.LocalMergeVirtual;
            var oldHook = InputPump.InputHook;
            var oldAutoplay = InputPump.AutoplayKeys1;
            var oldBegin = TextInput.BeginHook;
            var oldCancel = TextInput.CancelHook;
            bool oldActive = Host.Device.Hid.Keyboard.Active;
            IDisposable box = null;
            var states = new List<GamepadInput>(8);
            int* sticks = stackalloc int[4];
            InputPump.LocalInputSnapshot snapshot = new() { Abi = 2, Size = 224,
                Generation = 1, Session = 1, ConnectedMask = 1, Flags = 3 };
            snapshot.Slots[0].Type = (uint)ControllerType.ProController;
            void Commit() => InputPump.CommitLocalFrame(Host.Device, in snapshot, states, sticks);
            const string pressed = "4000000 0 0 200000000 mods Shift", released = "0 0 0 0 mods None";
            try
            {
                Host.Device.Hid.Keyboard.Active = true;
                InputPump._kbRead = &FakeKbRead;
                InputPump.LocalFeedbackApi = default;
                InputPump.LocalMergeVirtual = null;
                InputPump.InputHook = null; InputPump.AutoplayKeys1 = null;
                Commit();
                Check("本地提交：原始键盘键态继续刷新HID环", pressed, KeyboardBits(Host.Device));
                snapshot.Flags = 1;
                Commit();
                Check("本地提交：失焦释放键盘按键及修饰键", released, KeyboardBits(Host.Device));
                snapshot.Flags = 3;
                Commit();
                Check("本地提交：重新聚焦恢复当前键态", pressed, KeyboardBits(Host.Device));

                TextInput.BeginHook = (_, _) => 1;
                TextInput.CancelHook = _ => { };
                box = TextInput.Begin(new SoftwareKeyboardUIArgs(), (_, _) => { });
                Commit();
                Check("本地提交：软键盘开框时原始键盘静音", released, KeyboardBits(Host.Device));
                box.Dispose(); box = null;
                Commit();
                Check("本地提交：软键盘收框后恢复当前键态", pressed, KeyboardBits(Host.Device));
            }
            finally
            {
                box?.Dispose();
                TextInput.BeginHook = oldBegin; TextInput.CancelHook = oldCancel;
                InputPump.Stop();
                InputPump._kbRead = oldRead; InputPump.LocalFeedbackApi = oldFeedback;
                InputPump.LocalMergeVirtual = oldMerge;
                InputPump.InputHook = oldHook; InputPump.AutoplayKeys1 = oldAutoplay;
                Host.Device.Hid.Keyboard.Active = oldActive;
                InputPump.SetPrimary(Host.Device, PlayerIndex.Handheld, ControllerType.Handheld);
            }
        }
    }
}
