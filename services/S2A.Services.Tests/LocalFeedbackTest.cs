// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using Ryujinx.HLE.HOS.Applets;
using Ryujinx.HLE.HOS.Services.Hid;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private static readonly object FeedbackTestSync = new();
        private static InputPump.LocalInputSnapshot _inputV2Test;
        private static LocalControllerFeedback.FeedbackSnapshot _feedbackTest;
        private static ulong _feedbackNow;
        private static uint _motionEnabledTest;
        private static readonly Dictionary<uint, (ulong Session, uint Generation, VibrationValue Left, VibrationValue Right, uint Lease)> FeedbackRumbles = new();
        [UnmanagedCallersOnly] private static int ReadInputV2Test(InputPump.LocalInputSnapshot* output)
        { lock (FeedbackTestSync) { *output = _inputV2Test; return 1; } }
        [UnmanagedCallersOnly] private static int ReadFeedbackTest(LocalControllerFeedback.FeedbackSnapshot* output)
        { lock (FeedbackTestSync) { *output = _feedbackTest; return 1; } }
        [UnmanagedCallersOnly] private static ulong FeedbackClockTest() { lock (FeedbackTestSync) return _feedbackNow; }
        [UnmanagedCallersOnly] private static void EnableMotionTest(ulong session, uint generation, uint mask)
        { lock (FeedbackTestSync) _motionEnabledTest = mask; }
        [UnmanagedCallersOnly] private static void RumbleLocalTest(ulong session, uint generation, uint player, VibrationValue* pair, uint lease)
        { lock (FeedbackTestSync) FeedbackRumbles[player] = (session, generation, pair[0], pair[1], lease); }
        [UnmanagedCallersOnly] private static void StopFeedbackTest(ulong session, uint generation, uint mask)
        { lock (FeedbackTestSync) for (uint i = 0; i < 8; i++) if ((mask & (1u << (int)i)) != 0) FeedbackRumbles.Remove(i); }

        [SoloTest("--local-feedback-abi")]
        private static int LocalFeedbackAbi()
        {
            int bad = 0;
            void Row(string label, bool ok) { if (!ok) bad++; Console.WriteLine($"{(ok ? "✓" : "✗")} 本地反馈 {label}"); }
            Row("输入224B、反馈672B、单motion32B", sizeof(InputPump.LocalInputSnapshot) == 224 && sizeof(LocalControllerFeedback.FeedbackSnapshot) == 672 && sizeof(LocalControllerFeedback.MotionSample) == 32);
            LocalControllerBackend backend = new()
            {
                ReadFeedback = (nint)(delegate* unmanaged<LocalControllerFeedback.FeedbackSnapshot*, int>)&ReadFeedbackTest,
                MotionEnable = (nint)(delegate* unmanaged<ulong, uint, uint, void>)&EnableMotionTest,
                Rumble = (nint)(delegate* unmanaged<ulong, uint, uint, VibrationValue*, uint, void>)&RumbleLocalTest,
                StopFeedback = (nint)(delegate* unmanaged<ulong, uint, uint, void>)&StopFeedbackTest,
                Now = (nint)(delegate* unmanaged<ulong>)&FeedbackClockTest,
            };
            var bound = LocalControllerFeedback.FromBackend(backend);
            Row("平台登记回调表逐项传入反馈，服务不自行找平台导出", (nint)bound.Read == backend.ReadFeedback &&
                (nint)bound.MotionEnable == backend.MotionEnable && (nint)bound.Rumble == backend.Rumble &&
                (nint)bound.Stop == backend.StopFeedback && (nint)bound.Now == backend.Now && bound.MousePlayer == null);
            bound = LocalControllerFeedback.FromBackend(new LocalControllerBackend());
            Row("未提供的可选反馈保持空，不伪造设备", bound.Read == null && bound.Rumble == null && bound.Now == null);
            InputPump.LocalInputSnapshot input = new() { Abi = 2, Size = 224, ConnectedMask = 255, Generation = 1, Session = 1, Flags = 3 };
            for (int i = 0; i < 8; i++) input.Slots[i].Type = 1;
            Row("八个真实槽可用", InputPump.ValidLocalInput(in input));
            var other = input; other.Session++; other.Flags = 1;
            Row("仅focus/session改变不改控制器配置", InputPump.SameLocalConfiguration(in input, in other));
            other.Slots[7].Type = 2;
            Row("掌机不能放进额外玩家槽", !InputPump.ValidLocalInput(in other));
            input.Slots[0].Type = 2;
            Row("触屏slot0映射掌机格", InputPump.ValidLocalInput(in input) && InputPump.LocalPlayer(in input, 0) == PlayerIndex.Handheld);
            LocalControllerFeedback.MotionSample sample = new() { TimestampUs = 900_000, Ax = 1, Gx = 30 };
            Row("实时时间戳fresh", LocalControllerFeedback.Fresh(in sample, 1_000_000));
            Row("旧传感器样本过250ms无效", !LocalControllerFeedback.Fresh(in sample, 1_200_000));
            Row("未来时间戳无效", !LocalControllerFeedback.Fresh(in sample, 800_000));
            sample.Gx = float.NaN;
            Row("坏传感器数据无效", !LocalControllerFeedback.Fresh(in sample, 1_000_000));
            return bad == 0 ? 0 : 1;
        }

        [SoloTest("--local-feedback", Booted = true)]
        private static void LocalFeedbackIntegration()
        {
            InputPump.Stop();
            var oldRead = InputPump.LocalPadsReadV2; var oldLegacyRead = InputPump.LocalPadsRead;
            var oldApi = InputPump.LocalFeedbackApi; var oldInput = InputPump.InputHook;
            ControllerType oldStyles = Host.Device.Hid.Npads.SupportedStyleSets;
            var npads = Host.Device.Hid.Npads;
            int Handle(int player, int style, int side) => style | ((player == 8 ? 0x20 : player) << 8) | (side << 16);
            bool Settle(Func<bool> predicate) { for (int i = 0; i < 150; i++) { if (predicate()) return true; Thread.Sleep(10); } return predicate(); }
            uint Style(int i) => (uint)Host.Device.Hid.SharedMemory.Npads[i].InternalState.StyleSet;
            bool ZeroMotion(int i) => Host.Device.Hid.SharedMemory.Npads[i].InternalState.FullKeySixAxisSensor.GetCurrentEntryRef().AngularVelocity.X == 0 &&
                Host.Device.Hid.SharedMemory.Npads[i].InternalState.FullKeySixAxisSensor.GetCurrentEntryRef().AngularVelocity.Y == 0;
            void Advance()
            {
                lock (FeedbackTestSync)
                {
                    _feedbackNow += 10_000;
                    for (int i = 0; i < 8; i++)
                    {
                        if ((_feedbackTest.Slots[i].MotionMask & 1) != 0) _feedbackTest.Slots[i].Left.TimestampUs = _feedbackNow;
                        if ((_feedbackTest.Slots[i].MotionMask & 2) != 0) _feedbackTest.Slots[i].Right.TimestampUs = _feedbackNow;
                    }
                }
                Thread.Sleep(40);
            }
            int Configuration() => (int)typeof(InputPump).GetField("_configurationGeneration", BindingFlags.NonPublic | BindingFlags.Static)!.GetValue(null)!;
            try
            {
                lock (FeedbackTestSync)
                {
                    _feedbackNow = 1_000_000; _motionEnabledTest = 0; FeedbackRumbles.Clear();
                    _inputV2Test = new() { Abi = 2, Size = 224, Generation = 10, Session = 100, ConnectedMask = 255, Flags = 3 };
                    _feedbackTest = new() { Abi = 1, Size = 672, Generation = 10, Session = 100, SlotCount = 8, Flags = 7 };
                    for (int i = 0; i < 8; i++)
                    {
                        _inputV2Test.Slots[i] = new() { Type = 1, Buttons = 1u << i, LeftX = 1000 + i * 1000 };
                        _feedbackTest.Slots[i] = new() { Type = 1, Connected = 1, MotionMask = 1, Reserved = 1,
                            Left = new() { TimestampUs = _feedbackNow, Az = 1, Gx = i == 0 ? 100 : 0, Gy = i == 1 ? -200 : 0 } };
                    }
                }
                for (int i = 0; i < 8; i++) npads.SetSixAxisActive(999, Handle(i, 3, 2), true);
                InputPump.LocalPadsReadV2 = &ReadInputV2Test; InputPump.LocalPadsRead = null;
                InputPump.LocalFeedbackApi = new() { Read = &ReadFeedbackTest, MotionEnable = &EnableMotionTest,
                    Rumble = &RumbleLocalTest, Stop = &StopFeedbackTest, Now = &FeedbackClockTest };
                InputPump.InputHook = &PressA;
                InputPump.SetPrimary(Host.Device, PlayerIndex.Player1, ControllerType.ProController);
                bool eight = Settle(() => Style(7) == 1 && Host.Device.Hid.SharedMemory.Npads[7].InternalState.FullKey.GetCurrentEntryRef().AnalogStickL.X == 8000);
                Check("本地v2：八路真实独立按键/摇杆，PRIMARY_COMPLETE不叠旧A", "True / 8 / 128", $"{eight} / {InputPump.Pads} / {(ulong)Host.Device.Hid.SharedMemory.Npads[7].InternalState.FullKey.GetCurrentEntryRef().Buttons & 255}");
                Advance(); Advance();
                bool independentMotion = Settle(() => Host.Device.Hid.SharedMemory.Npads[0].InternalState.FullKeySixAxisSensor.GetCurrentEntryRef().AngularVelocity.X > .26f &&
                    Host.Device.Hid.SharedMemory.Npads[1].InternalState.FullKeySixAxisSensor.GetCurrentEntryRef().AngularVelocity.Y < -.53f);
                Check("本地v2：各玩家独立gyro，无跨玩家复制", "True / True", $"{independentMotion} / {ZeroMotion(2)}");
                lock (FeedbackTestSync) _feedbackTest.Slots[2].Reserved = 0;
                bool noSensor = Settle(() => { lock (FeedbackTestSync) return _motionEnabledTest == 251; });
                Check("本地v2：capmask为零的手柄不请求传感器", "True", noSensor.ToString());
                lock (FeedbackTestSync) _feedbackTest.Slots[2].Reserved = 1;
                Settle(() => { lock (FeedbackTestSync) return _motionEnabledTest == 255; });
                bool four = Host.Device.UIHandler.DisplayMessageDialog(new ControllerAppletUIArgs { PlayerCountMin = 4, PlayerCountMax = 4,
                    SupportedStyles = ControllerType.ProController, SupportedPlayers = new[] { PlayerIndex.Player1, PlayerIndex.Player2, PlayerIndex.Player3, PlayerIndex.Player4 } });
                var fourApplet = ShowLocalControllerSupport(4, 4, false, ControllerType.ProController);
                Check("本地v2：四人小程序只向HID提供四个真实玩家", "True / 4 / 4", $"{four} / {fourApplet.Count} / {InputPump.Pads}");

                VibrationValue a = new() { AmplitudeLow = .2f, FrequencyLow = 160, FrequencyHigh = 320 }, b = new() { AmplitudeHigh = .7f, FrequencyLow = 160, FrequencyHigh = 320 };
                npads.UpdateRumbleQueue(PlayerIndex.Player1, true, a, true, b);
                npads.UpdateRumbleQueue(PlayerIndex.Player4, true, b, true, a);
                bool separateRumble;
                lock (FeedbackTestSync) separateRumble = FeedbackRumbles.TryGetValue(0, out var p1) && FeedbackRumbles.TryGetValue(3, out var p4) &&
                    p1.Left == a && p1.Right == b && p4.Left == b && p4.Right == a && p1.Lease <= 2000 && p4.Lease <= 2000;
                Check("本地v2：游戏左右双频震动按玩家隔离，租期不超过两秒", "True", separateRumble.ToString());
                var one = ShowLocalControllerSupport(1, 1, false, ControllerType.ProController);
                bool hiddenStopped = Settle(() => { lock (FeedbackTestSync) return InputPump.Pads == 1 && Style(1) == 0 &&
                    _motionEnabledTest == 1 && !FeedbackRumbles.ContainsKey(1) && !FeedbackRumbles.ContainsKey(3); });
                Check("本地v2：真实单人小程序按上限隐藏P2并停隐藏玩家反馈", "1 / 0 / True", $"{one.Count} / {one.Primary} / {hiddenStopped}");
                lock (FeedbackTestSync) Check("本地v2：人数上限不改宿主物理接法/会话/代次", "255 / 100 / 10",
                    $"{_inputV2Test.ConnectedMask} / {_inputV2Test.Session} / {_inputV2Test.Generation}");
                var restoreFour = ShowLocalControllerSupport(4, 4, false, ControllerType.ProController);
                bool restoredSlot = Settle(() => Style(1) == 1 && Host.Device.Hid.SharedMemory.Npads[1].InternalState.FullKey.GetCurrentEntryRef().AnalogStickL.X == 2000);
                Check("本地v2：放宽上限后P2回到原槽和原输入", "4 / True", $"{restoreFour.Count} / {restoredSlot}");
                npads.UpdateRumbleQueue(PlayerIndex.Player1, true, a, true, b);
                npads.UpdateRumbleQueue(PlayerIndex.Player4, true, b, true, a);
                npads.SetSupportedPlayer(PlayerIndex.Player4, false);
                bool gameDisconnected = Settle(() => { lock (FeedbackTestSync) return Style(3) == 0 && !FeedbackRumbles.ContainsKey(3) && FeedbackRumbles.ContainsKey(0); });
                Check("本地v2：游戏断开P4只停P4震动，不截断P1租约", "True", gameDisconnected.ToString());
                npads.SetSupportedPlayer(PlayerIndex.Player4, true);
                Settle(() => Style(3) == 1);
                // A cap change rebuilds the motion filters. Re-polling the old timestamp is not
                // a new sample: let the restored players receive new samples before stopping P1.
                Advance(); Advance();
                bool motionAfterCap = Settle(() => Host.Device.Hid.SharedMemory.Npads[1].InternalState.FullKeySixAxisSensor.GetCurrentEntryRef().AngularVelocity.Y < -.53f);
                Check("本地v2：人数上限往返后新样本恢复P2体感", "True", motionAfterCap.ToString());
                npads.UpdateRumbleQueue(PlayerIndex.Player4, true, b, true, a);
                npads.SetSixAxisActive(999, Handle(0, 3, 2), false);
                bool oneDisabled = Settle(() => { lock (FeedbackTestSync) return _motionEnabledTest == 14 && !FeedbackRumbles.ContainsKey(0) && FeedbackRumbles.ContainsKey(3) && ZeroMotion(0) && !ZeroMotion(1); });
                if (!oneDisabled)
                    lock (FeedbackTestSync) Console.Error.WriteLine($"Local feedback stop diagnostic: mask={_motionEnabledTest}, p1Rumble={FeedbackRumbles.ContainsKey(0)}, p4Rumble={FeedbackRumbles.ContainsKey(3)}, p1Zero={ZeroMotion(0)}, p2Zero={ZeroMotion(1)}");
                Check("本地v2：单独停P1传感器只清P1反馈，其他玩家继续", "True", oneDisabled.ToString());
                npads.SetSixAxisActive(999, Handle(0, 3, 2), true);
                Advance(); Advance();
                npads.SetVibrationPermitted(false);
                lock (FeedbackTestSync) Check("本地v2：禁止震动立即清掉所有玩家输出", "0", FeedbackRumbles.Count.ToString());
                npads.SetVibrationPermitted(true);

                int config = Configuration();
                lock (FeedbackTestSync) _inputV2Test.Flags = 1;
                bool unfocused = Settle(() => ZeroMotion(0) && Host.Device.Hid.SharedMemory.Npads[7].InternalState.FullKey.GetCurrentEntryRef().Buttons == 0);
                Check("本地v2：失焦清空所有玩家输入与体感，接法不重配", $"True / {config}", $"{unfocused} / {Configuration()}");
                lock (FeedbackTestSync) { _inputV2Test.Flags = 3; _inputV2Test.Session++; }
                Thread.Sleep(60);
                npads.UpdateRumbleQueue(PlayerIndex.Player1, true, a, true, b);
                lock (FeedbackTestSync) Check("本地v2：输入/反馈会话不匹配拒绝旧震动和gyro", "0 / True", $"{FeedbackRumbles.Count} / {ZeroMotion(0)}");
                lock (FeedbackTestSync) _feedbackTest.Session = _inputV2Test.Session;
                bool freshSession = Settle(() => ZeroMotion(0) && Host.Device.Hid.SharedMemory.Npads[0].InternalState.FullKeySixAxisSensor.GetCurrentEntryRef().Angle.X == 0);
                Check("本地v2：新会话首次样本不沿用旧姿态积分", "True", freshSession.ToString());
                Advance(); Advance();
                bool resumed = Settle(() => Host.Device.Hid.SharedMemory.Npads[0].InternalState.FullKeySixAxisSensor.GetCurrentEntryRef().AngularVelocity.X > .26f);
                Check("本地v2：新会话恢复gyro，不重配控制器", $"True / {config}", $"{resumed} / {Configuration()}");
                lock (FeedbackTestSync) _feedbackNow += 300_000;
                bool stale = Settle(() => ZeroMotion(0) && ZeroMotion(1));
                Check("本地v2：传感器超过250ms不伪造fresh、不复制旧姿态", "True", stale.ToString());
                lock (FeedbackTestSync) _feedbackTest.Flags = 5;
                bool disabled = Settle(() => { lock (FeedbackTestSync) return _motionEnabledTest == 0; });
                Check("本地v2：关闭体感硬件请求并清空filter", "True", disabled.ToString());

                lock (FeedbackTestSync)
                {
                    _inputV2Test.Generation++; _inputV2Test.ConnectedMask = 1; _inputV2Test.Slots[0].Type = 4;
                    _feedbackTest.Generation = _inputV2Test.Generation; _feedbackTest.Flags = 7;
                    _feedbackTest.Slots[0] = new() { Type = 4, Connected = 1, MotionMask = 3, Reserved = 3,
                        Left = new() { Az = 1, Gx = 100 }, Right = new() { Az = 1, Gy = -200 } };
                }
                npads.SetSixAxisActive(999, Handle(0, 5, 0), true); npads.SetSixAxisActive(999, Handle(0, 5, 1), true);
                Settle(() => Style(0) == 4); Advance(); Advance();
                bool pair = Settle(() => Host.Device.Hid.SharedMemory.Npads[0].InternalState.JoyDualSixAxisSensor.GetCurrentEntryRef().AngularVelocity.X > .26f &&
                    Host.Device.Hid.SharedMemory.Npads[0].InternalState.JoyDualRightSixAxisSensor.GetCurrentEntryRef().AngularVelocity.Y < -.53f);
                Check("本地v2：合体左右两个真实IMU分别进同玩家左右ring", "True", pair.ToString());
                lock (FeedbackTestSync) _feedbackTest.Slots[0].MotionMask = 1;
                bool missing = Settle(() => Host.Device.Hid.SharedMemory.Npads[0].InternalState.JoyDualSixAxisSensor.GetCurrentEntryRef().AngularVelocity.X == 0 &&
                    Host.Device.Hid.SharedMemory.Npads[0].InternalState.JoyDualRightSixAxisSensor.GetCurrentEntryRef().AngularVelocity.Y == 0);
                Check("本地v2：Pair缺右IMU整组omit，不让HID自动复制左侧", "True", missing.ToString());
                lock (FeedbackTestSync) _feedbackTest.Slots[0].MotionMask = 3;
                npads.SupportedStyleSets = ControllerType.ProController;
                Settle(() => Style(0) == 1); Advance(); Advance();
                bool remapRight = Settle(() => Host.Device.Hid.SharedMemory.Npads[0].InternalState.FullKeySixAxisSensor.GetCurrentEntryRef().AngularVelocity.Y < -.53f &&
                    Host.Device.Hid.SharedMemory.Npads[0].InternalState.FullKeySixAxisSensor.GetCurrentEntryRef().AngularVelocity.X == 0);
                Check("本地v2：Pair映射Pro时选右IMU，不被左侧覆盖", "True", remapRight.ToString());
                npads.SupportedStyleSets = oldStyles;

                lock (FeedbackTestSync)
                {
                    _inputV2Test.Generation++; _inputV2Test.Slots[0].Type = 16;
                    _feedbackTest.Generation = _inputV2Test.Generation;
                    _feedbackTest.Slots[0] = new() { Type = 16, Connected = 1, MotionMask = 2, Reserved = 2,
                        Right = new() { Az = 1, Gz = 100 } };
                }
                npads.SetSixAxisActive(999, Handle(0, 7, 1), true);
                Settle(() => Style(0) == 16); Advance(); Advance();
                bool rightOnly = Settle(() => Host.Device.Hid.SharedMemory.Npads[0].InternalState.JoyRightSixAxisSensor.GetCurrentEntryRef().AngularVelocity.Z > .26f);
                Check("本地v2：右单只读取motion[1]/mask2，不偷用左IMU", "True", rightOnly.ToString());

                lock (FeedbackTestSync)
                {
                    _inputV2Test.Generation++; _inputV2Test.Slots[0].Type = 2; _inputV2Test.Slots[0].Buttons = 2;
                    _feedbackTest.Generation = _inputV2Test.Generation; _feedbackTest.Slots[0].Type = 2; _feedbackTest.Slots[0].MotionMask = 1; _feedbackTest.Slots[0].Reserved = 1;
                }
                bool handheld = Settle(() => Style(8) == 2 && ((ulong)Host.Device.Hid.SharedMemory.Npads[8].InternalState.Handheld.GetCurrentEntryRef().Buttons & 255) == 2);
                Check("本地v2：触屏slot0映射掌机，完整主输入不重复叠加A", "True", handheld.ToString());
                Host.Device.UIHandler.DisplayMessageDialog(new ControllerAppletUIArgs { PlayerCountMin = 1, PlayerCountMax = 1,
                    SupportedStyles = ControllerType.Handheld, SupportedPlayers = new[] { PlayerIndex.Handheld } });
                npads.UpdateRumbleQueue(PlayerIndex.Handheld, true, a, true, b);
                lock (FeedbackTestSync) Check("本地v2：掌机HID玩家8的震动仍路由native槽0", "True",
                    (FeedbackRumbles.TryGetValue(0, out var handheldRumble) && handheldRumble.Left == a && handheldRumble.Right == b).ToString());
                InputPump.Stop();
                lock (FeedbackTestSync) Check("本地v2：Stop停全部震动/体感并释放唯一callback owner", "0 / 0 / True",
                    $"{FeedbackRumbles.Count} / {_motionEnabledTest} / {npads.RumbleAccepted == null}");
            }
            finally
            {
                InputPump.Stop();
                npads.SupportedStyleSets = oldStyles; npads.SetVibrationPermitted(true);
                npads.SetSupportedPlayer(PlayerIndex.Player4, true);
                for (int i = 0; i < 8; i++) npads.SetSixAxisActive(999, Handle(i, 3, 2), false);
                npads.SetSixAxisActive(999, Handle(0, 5, 0), false); npads.SetSixAxisActive(999, Handle(0, 5, 1), false);
                npads.SetSixAxisActive(999, Handle(0, 7, 1), false);
                InputPump.LocalPadsReadV2 = oldRead; InputPump.LocalPadsRead = oldLegacyRead; InputPump.LocalFeedbackApi = oldApi; InputPump.InputHook = oldInput;
                InputPump.SetPrimary(Host.Device, PlayerIndex.Handheld, ControllerType.Handheld);
            }
        }
    }
}
