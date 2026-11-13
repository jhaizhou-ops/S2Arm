// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Runtime.InteropServices;
using System.Threading;
using Ryujinx.HLE.HOS.Applets;
using Ryujinx.HLE.HOS.Services.Hid;
using Ryujinx.HLE.HOS.Services.Am.AppletAE;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private static readonly object LocalTestSync = new();
        private static InputPump.LocalPadsSnapshot _localTestSnapshot;
        private static bool _localTestAvailable;

        [UnmanagedCallersOnly]
        private static int ReadTestLocalPads(InputPump.LocalPadsSnapshot* snapshot)
        {
            lock (LocalTestSync)
            {
                *snapshot = _localTestSnapshot;
                return _localTestAvailable ? 1 : 0;
            }
        }

        private static (int Count, uint Primary) ShowLocalControllerSupport(int min, int max, bool single, ControllerType styles)
        {
            var normal = new AppletSession();
            AppletSession game = normal.GetConsumer();
            game.Push(new byte[0x20]);
            var priv = new ControllerSupportArgPrivate
            {
                PrivateSize = 20, ArgSize = 1072, Mode = ControllerSupportMode.ShowControllerSupport,
                NpadStyleSet = (uint)styles, NpadJoyHoldType = 1,
            };
            byte[] privateBytes = new byte[Marshal.SizeOf<ControllerSupportArgPrivate>()];
            MemoryMarshal.Write(privateBytes, in priv);
            game.Push(privateBytes);
            byte[] arg = new byte[1072];
            var header = new ControllerSupportArgHeader
            {
                PlayerCountMin = (sbyte)min, PlayerCountMax = (sbyte)max,
                EnableTakeOverConnection = 1, EnableSingleMode = single ? (byte)1 : (byte)0,
            };
            MemoryMarshal.Write(arg.AsSpan(), in header);
            game.Push(arg);
            new ControllerApplet(Host.Device.System).Start(normal, new AppletSession());
            byte[] result = game.TryPop(out byte[] response) ? response : new byte[12];
            return ((sbyte)result[0], BitConverter.ToUInt32(result, 4));
        }

        private static ulong _localWaitSequence, _localWaitDeadline;
        private static int _localWaitCalls;
        [UnmanagedCallersOnly] private static ulong LocalWakeClock() => 50_000;
        [UnmanagedCallersOnly] private static int WaitLocalWake(ulong sequence, ulong deadline)
        { _localWaitSequence = sequence; _localWaitDeadline = deadline; _localWaitCalls++; return 0; }

        [SoloTest("--local-pads-abi")]
        private static int LocalPadsAbiTest()
        {
            int bad = 0;
            void Row(string what, string expected, string actual)
            {
                bool ok = expected == actual; if (!ok) bad++;
                Console.WriteLine($"{(ok ? "✓" : "✗")} 本地手柄 {what}：{expected} → {actual}");
            }
            Row("快照 ABI 字节数", "64 / 24", $"{sizeof(InputPump.LocalPadsSnapshot)} / {sizeof(InputPump.LocalPadState)}");
            Row("HID人数上限不压实物理槽", "2 / 10 / 0", $"{InputPump.LimitLocalMask(10, 1)} / {InputPump.LimitLocalMask(10, 2)} / {InputPump.LimitLocalMask(10, 0)}");
            _localWaitCalls = 0;
            bool waited = InputPump.WaitLocalFrame(42, &WaitLocalWake, &LocalWakeClock);
            Row("复用原生事件序号并给8ms心跳", "True / 1 / 42 / 58000", $"{waited} / {_localWaitCalls} / {_localWaitSequence} / {_localWaitDeadline}");
            bool noWait = InputPump.WaitLocalFrame(42, null, &LocalWakeClock);
            Row("旧宿主缺事件等待口不调用等待", "False / 1", $"{noWait} / {_localWaitCalls}");
            InputPump.LocalPadsSnapshot snapshot = new() { Abi = 1, ConnectedMask = 3,
                First = new() { Type = 8 }, Second = new() { Type = 16 } };
            Row("左右两个独立槽位", "True", InputPump.ValidLocalSnapshot(in snapshot).ToString());
            snapshot.Abi = 2;
            Row("未知 ABI 不读", "False", InputPump.ValidLocalSnapshot(in snapshot).ToString());
            snapshot.Abi = 1; snapshot.Second.Type = 2;
            Row("本地协议不接受掌机样式", "False", InputPump.ValidLocalSnapshot(in snapshot).ToString());
            InputPump.LocalPadState physical = new() { Type = 16, Buttons = (uint)(ControllerKeys.X | ControllerKeys.SrRight), RightX = -1234, RightY = 5678 };
            GamepadInput right = InputPump.LocalInput(in physical, PlayerIndex.Player2);
            Row("右只物理输入不再次旋转", $"{(uint)(ControllerKeys.X | ControllerKeys.SrRight)} / 0,0 / -1234,5678",
                $"{(uint)right.Buttons} / {right.LStick.Dx},{right.LStick.Dy} / {right.RStick.Dx},{right.RStick.Dy}");
            foreach (ControllerKeys face in new[] { ControllerKeys.A, ControllerKeys.B, ControllerKeys.X, ControllerKeys.Y })
            {
                InputPump.LocalPadState button = new() { Type = 1, Buttons = (uint)face };
                Row($"保留宿主当前ABXY映射{face}", ((uint)face).ToString(), ((uint)InputPump.LocalInput(in button, PlayerIndex.Player1).Buttons).ToString());
            }
            GamepadInput keyboard = new() { Buttons = ControllerKeys.A | ControllerKeys.L | ControllerKeys.R | ControllerKeys.LStick };
            keyboard.LStick.Dx = 1000; keyboard.LStick.Dy = 2000;
            InputPump.LocalVirtualInput(ref keyboard, ControllerType.JoyconRight);
            Row("右只键盘附加输入转到真实右摇杆和 SL/SR", $"{(uint)(ControllerKeys.X | ControllerKeys.SlRight | ControllerKeys.SrRight | ControllerKeys.RStick)} / 0,0 / -2000,1000",
                $"{(uint)keyboard.Buttons} / {keyboard.LStick.Dx},{keyboard.LStick.Dy} / {keyboard.RStick.Dx},{keyboard.RStick.Dy}");
            return bad == 0 ? 0 : 1;
        }

        private static InputPump.LocalInputSnapshot _localCommitTestSnapshot;
        private static int _localVirtualCommitCalls;
        private static bool _localVirtualPending;
        private static ulong _localVirtualSession;
        private static uint _localVirtualGeneration;
        [UnmanagedCallersOnly]
        private static int ReadCommitTestSnapshot(InputPump.LocalInputSnapshot* output)
        {
            *output = _localCommitTestSnapshot;
            return 1;
        }
        [UnmanagedCallersOnly]
        private static void MergeCommitTestVirtual(ulong session, uint generation, InputPump.LocalPadState* pad)
        {
            _localVirtualCommitCalls++;
            _localVirtualSession = session; _localVirtualGeneration = generation;
            if (!_localVirtualPending) return;
            _localVirtualPending = false;
            pad->Buttons |= (uint)ControllerKeys.SlRight;
            pad->RightX += 432;
        }

        // With the background sampler stopped, this thread owns the real production commit function.
        // Exact callback counts distinguish side-effect-free dialog reads from a consuming HID commit.
        [SoloTest("--local-virtual-commit", Booted = true)]
        private static void LocalPadsVirtualCommitTest()
        {
            InputPump.Stop();
            var oldRead = InputPump.LocalPadsReadV2; var oldLegacy = InputPump.LocalPadsRead;
            var oldMerge = InputPump.LocalMergeVirtual; var oldFeedback = InputPump.LocalFeedbackApi;
            var oldHook = InputPump.InputHook; var oldAutoplay = InputPump.AutoplayKeys1;
            var npads = Host.Device.Hid.Npads; ControllerType oldStyles = npads.SupportedStyleSets;
            var states = new System.Collections.Generic.List<GamepadInput>(8);
            int* sticks = stackalloc int[4];
            string P1()
            {
                ref var value = ref Host.Device.Hid.SharedMemory.Npads[0].InternalState.JoyRight.GetCurrentEntryRef();
                return $"{(ulong)value.Buttons} / {value.AnalogStickR.X},{value.AnalogStickR.Y}";
            }
            string P2()
            {
                ref var value = ref Host.Device.Hid.SharedMemory.Npads[1].InternalState.JoyLeft.GetCurrentEntryRef();
                return $"{(ulong)value.Buttons} / {value.AnalogStickL.X},{value.AnalogStickL.Y}";
            }
            void Commit() => InputPump.CommitLocalFrame(Host.Device, in _localCommitTestSnapshot, states, sticks);
            try
            {
                npads.SupportedStyleSets = ControllerType.JoyconLeft | ControllerType.JoyconRight;
                _localCommitTestSnapshot = new() { Abi = 2, Size = 224, Generation = 9, Session = 77, ConnectedMask = 3, Flags = 3 };
                _localCommitTestSnapshot.Slots[0] = new() { Type = 16, Buttons = (uint)ControllerKeys.A, RightX = 1000, RightY = -2000 };
                _localCommitTestSnapshot.Slots[1] = new() { Type = 8, Buttons = (uint)ControllerKeys.DpadLeft, LeftX = 700, LeftY = -800 };
                _localVirtualCommitCalls = 0; _localVirtualPending = true;
                InputPump.LocalPadsReadV2 = &ReadCommitTestSnapshot; InputPump.LocalPadsRead = null;
                InputPump.LocalMergeVirtual = &MergeCommitTestVirtual; InputPump.LocalFeedbackApi = default;
                InputPump.InputHook = null; InputPump.AutoplayKeys1 = null;
                Commit();
                Check("本地虚拟提交：换接法的中性帧不消费短按", "0 / True / 0 / 0,0 / 0 / 0,0",
                    $"{_localVirtualCommitCalls} / {_localVirtualPending} / {P1()} / {P2()}");
                InputPump.LocalInputSnapshot inspected = default;
                InputPump.LocalPadsReadV2(&inspected);
                bool handled = InputPump.TryLocalControllerDialog(Host.Device, new ControllerAppletUIArgs
                {
                    PlayerCountMin = 2, PlayerCountMax = 2, SupportedStyles = ControllerType.JoyconLeft | ControllerType.JoyconRight,
                    SupportedPlayers = new[] { PlayerIndex.Player1, PlayerIndex.Player2 },
                }, out bool accepted);
                Check("本地虚拟提交：快照与小程序读不消费", "True / True / 0 / True",
                    $"{handled} / {accepted} / {_localVirtualCommitCalls} / {_localVirtualPending}");
                Commit();
                Check("本地虚拟提交：聚焦时一次提交只消费一次且透传会话代次", "1 / False / 77 / 9",
                    $"{_localVirtualCommitCalls} / {_localVirtualPending} / {_localVirtualSession} / {_localVirtualGeneration}");
                Check("本地虚拟提交：P1叠虚拟输入，P2物理输入保持独立", $"{(uint)(ControllerKeys.A | ControllerKeys.SlRight)} / 1432,-2000 / {(uint)ControllerKeys.DpadLeft} / 700,-800",
                    $"{P1()} / {P2()}");
                Commit();
                Check("本地虚拟提交：下一帧不重复已消费的短按", "2 / 1 / 1000,-2000", $"{_localVirtualCommitCalls} / {P1()}");
                _localVirtualPending = true; _localCommitTestSnapshot.Flags = 1;
                Commit();
                Check("本地虚拟提交：失焦释放两玩家且不消费虚拟短按", "2 / True / 0 / 0,0 / 0 / 0,0",
                    $"{_localVirtualCommitCalls} / {_localVirtualPending} / {P1()} / {P2()}");
                _localCommitTestSnapshot.Flags = 3; _localCommitTestSnapshot.Generation++; _localCommitTestSnapshot.Session++;
                Commit();
                Check("本地虚拟提交：新会话换代首帧仍不消费", "2 / True / 0 / 0,0",
                    $"{_localVirtualCommitCalls} / {_localVirtualPending} / {P1()}");
                Commit();
                Check("本地虚拟提交：新会话下一帧消费且不串P2", $"3 / False / 78 / 10 / {(uint)ControllerKeys.DpadLeft} / 700,-800",
                    $"{_localVirtualCommitCalls} / {_localVirtualPending} / {_localVirtualSession} / {_localVirtualGeneration} / {P2()}");
            }
            finally
            {
                InputPump.Stop(); npads.SupportedStyleSets = oldStyles;
                InputPump.LocalPadsReadV2 = oldRead; InputPump.LocalPadsRead = oldLegacy;
                InputPump.LocalMergeVirtual = oldMerge; InputPump.LocalFeedbackApi = oldFeedback;
                InputPump.InputHook = oldHook; InputPump.AutoplayKeys1 = oldAutoplay;
                InputPump.SetPrimary(Host.Device, PlayerIndex.Handheld, ControllerType.Handheld);
            }
        }

        // Exercise the actual HID owner thread and shared-memory rings, not a second test writer.
        [SoloTest("--local-pads", Booted = true)]
        private static void LocalPadsTest()
        {
            InputPump.Stop();
            var oldRead = InputPump.LocalPadsRead;
            var oldHook = InputPump.InputHook;
            ControllerType oldStyles = Host.Device.Hid.Npads.SupportedStyleSets;
            uint Style(int i) => (uint)Host.Device.Hid.SharedMemory.Npads[i].InternalState.StyleSet;
            string Left() { ref var s = ref Host.Device.Hid.SharedMemory.Npads[0].InternalState.JoyLeft.GetCurrentEntryRef(); return $"{(ulong)s.Buttons & 0xFF00FFFFu:X} / {s.AnalogStickL.X},{s.AnalogStickL.Y}"; }
            string Right() { ref var s = ref Host.Device.Hid.SharedMemory.Npads[1].InternalState.JoyRight.GetCurrentEntryRef(); return $"{(ulong)s.Buttons & 0xFF00FFFFu:X} / {s.AnalogStickR.X},{s.AnalogStickR.Y}"; }
            bool Settle(Func<bool> predicate) { for (int i = 0; i < 100; i++) { if (predicate()) return true; Thread.Sleep(10); } return predicate(); }
            void Set(InputPump.LocalPadsSnapshot snapshot) { lock (LocalTestSync) { _localTestSnapshot = snapshot; _localTestAvailable = true; } }
            ControllerAppletUIArgs Args(int min, int max, ControllerType styles) => new()
            {
                PlayerCountMin = min, PlayerCountMax = max, SupportedStyles = styles,
                SupportedPlayers = new[] { PlayerIndex.Player1, PlayerIndex.Player2 },
            };
            InputPump.LocalPadsSnapshot split = new()
            {
                Abi = 1, ConnectedMask = 3, Generation = 1,
                First = new() { Type = 8, Buttons = (uint)(ControllerKeys.DpadRight | ControllerKeys.SlLeft), LeftX = 1234, LeftY = -5678 },
                Second = new() { Type = 16, Buttons = (uint)(ControllerKeys.X | ControllerKeys.SrRight), RightX = -9012, RightY = 3456 },
            };
            try
            {
                Set(split);
                InputPump.InputHook = null;
                InputPump.LocalPadsRead = &ReadTestLocalPads;
                InputPump.SetPrimary(Host.Device, PlayerIndex.Player1, ControllerType.ProController);
                bool independent = Settle(() => Style(0) == 8 && Style(1) == 16 && Left() == "1004000 / 1234,-5678" && Right() == "8000004 / -9012,3456");
                Check("本地双人：左右独立按键、不同模拟量写到 P1 左只 / P2 右只", "True", independent.ToString());
                Check("本地双人：实际两个独立手柄", "2", InputPump.Pads.ToString());
                bool applet = Host.Device.UIHandler.DisplayMessageDialog(Args(2, 2, ControllerType.JoyconLeft | ControllerType.JoyconRight));
                Check("本地双人：手柄小程序保留左右样式", "True / 8,16", $"{applet} / {Style(0)},{Style(1)}");
                bool wrongStyle = Host.Device.UIHandler.DisplayMessageDialog(Args(2, 2, ControllerType.ProController));
                Check("本地双人：不伪造游戏不收的 Pro 镜像", "False / 8,16", $"{wrongStyle} / {Style(0)},{Style(1)}");
                var single = ShowLocalControllerSupport(1, 4, true, ControllerType.JoyconLeft | ControllerType.JoyconRight);
                Check("本地双人：单人选择只给HID的P1，物理接法不重排", "1 / 0 / 8,0", $"{single.Count} / {single.Primary} / {Style(0)},{Style(1)}");
                bool readySingle = Host.Device.UIHandler.DisplayMessageDialog(Args(1, 1, ControllerType.JoyconLeft | ControllerType.JoyconRight));
                var maxOne = ShowLocalControllerSupport(1, 1, false, ControllerType.JoyconLeft | ControllerType.JoyconRight);
                Check("本地双人：非单人模式的上限1同样只给HID一个玩家", "True / 1 / 0 / 8,0",
                    $"{readySingle} / {maxOne.Count} / {maxOne.Primary} / {Style(0)},{Style(1)}");
                var two = ShowLocalControllerSupport(2, 2, false, ControllerType.JoyconLeft | ControllerType.JoyconRight);
                Check("本地双人：双人选择仍回两名真实玩家", "2 / 0 / 8,16", $"{two.Count} / {two.Primary} / {Style(0)},{Style(1)}");
                var unsupported = ShowLocalControllerSupport(1, 1, false, ControllerType.ProController);
                Check("本地双人：单人选择不绕过不支持的样式", "0 / 8,0", $"{unsupported.Count} / {Style(0)},{Style(1)}");
                bool tooFew = Host.Device.UIHandler.DisplayMessageDialog(Args(3, 4, ControllerType.JoyconLeft | ControllerType.JoyconRight));
                Check("本地双人：两只手柄不能答应至少三人", "False / 2", $"{tooFew} / {InputPump.Pads}");
                InputPump.LocalPadsSnapshot unfocused = split;
                unfocused.First.Buttons = unfocused.Second.Buttons = 0;
                unfocused.First.LeftX = unfocused.First.LeftY = unfocused.Second.RightX = unfocused.Second.RightY = 0;
                Set(unfocused);
                bool neutral = Settle(() => Left() == "0 / 0,0" && Right() == "0 / 0,0");
                Check("本地双人：失焦中性帧保持接法但释放两人的按键与摇杆", "True / 8,16", $"{neutral} / {Style(0)},{Style(1)}");
                split.ConnectedMask = 2; split.Generation++;
                Set(split);
                bool rightAlone = Settle(() => Style(0) == 0 && Style(1) == 16 && Right() == "8000004 / -9012,3456");
                Check("本地双人：左只断线后右只仍留 P2、不偷换到 P1", "True / 1", $"{rightAlone} / {InputPump.Pads}");

                InputPump.LocalPadsSnapshot pair = new()
                {
                    Abi = 1, ConnectedMask = 1, Generation = 3,
                    First = new() { Type = 4, Buttons = (uint)ControllerKeys.A, LeftX = 100, LeftY = 200, RightX = 300, RightY = 400 },
                };
                Set(pair);
                bool combined = Settle(() => Style(0) == 4 && Style(1) == 0 &&
                    Host.Device.Hid.SharedMemory.Npads[0].InternalState.JoyDual.GetCurrentEntryRef().AnalogStickR.X == 300);
                Check("本地双人：合体真收缩成一个双 Joy-Con，P2 断开", "True / 1", $"{combined} / {InputPump.Pads}");
                Host.Device.Hid.Npads.SupportedStyleSets = ControllerType.ProController;
                bool proRemap = Settle(() => Style(0) == 1);
                bool proDialog = Host.Device.UIHandler.DisplayMessageDialog(Args(1, 1, ControllerType.ProController));
                Check("本地双人：游戏只收 Pro 时接受现有 Pair→Pro Remap，不改本地接法", "True / True / 1", $"{proRemap} / {proDialog} / {InputPump.Pads}");
                Host.Device.Hid.Npads.SupportedStyleSets = oldStyles;
                pair.ConnectedMask = 0; pair.Generation++;
                Set(pair);
                bool disconnected = Settle(() => Style(0) == 0 && Style(1) == 0 && InputPump.Pads == 0);
                bool absent = Host.Device.UIHandler.DisplayMessageDialog(Args(2, 2, ControllerType.JoyconPair));
                Check("本地双人：全部断线时不造虚拟玩家", "True / False / 0", $"{disconnected} / {absent} / {InputPump.Pads}");

                InputPump.InputHook = &PressA;
                lock (LocalTestSync) _localTestAvailable = false;
                bool fallback = Settle(() => Style((int)PlayerIndex.Handheld) == 2 &&
                    (Host.Device.Hid.SharedMemory.Npads[(int)PlayerIndex.Handheld].InternalState.Handheld.GetCurrentEntryRef().Buttons & (Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.Npad.NpadButton)1) != 0);
                Check("本地双人：宿主不接管时仍回旧键盘／掌机路径", "True", fallback.ToString());
            }
            finally
            {
                InputPump.Stop();
                Host.Device.Hid.Npads.SupportedStyleSets = oldStyles;
                InputPump.LocalPadsRead = oldRead;
                InputPump.InputHook = oldHook;
                lock (LocalTestSync) _localTestAvailable = false;
                InputPump.SetPrimary(Host.Device, PlayerIndex.Handheld, ControllerType.Handheld);
            }
        }
    }
}
