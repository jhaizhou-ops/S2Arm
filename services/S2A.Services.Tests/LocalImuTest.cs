// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Text;
using System.Threading;
using Ryujinx.HLE.HOS.Services.Hid;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        // A game can enable the new IMU buffer without registering legacy six-axis handles.
        // The two real input slots must still deliver their own raw samples, once per timestamp.
        [SoloTest("--local-imu", Booted = true)]
        private static void LocalImuChannel()
        {
            InputPump.Stop();
            var oldRead = InputPump.LocalPadsReadV2; var oldLegacy = InputPump.LocalPadsRead;
            var oldApi = InputPump.LocalFeedbackApi; var oldHook = InputPump.InputHook;
            var npads = Host.Device.Hid.Npads;
            byte* buf = _game + 0xA000;
            bool Settle(Func<bool> predicate)
            {
                for (int i = 0; i < 150; i++) { if (predicate()) return true; Thread.Sleep(10); }
                return predicate();
            }
            ulong Wi(int player) => *(ulong*)(buf + player * NpadImu.SlotSize + NpadImu.WriteIndexOffset);
            float F32(int player, int offset) => *(float*)(buf + player * NpadImu.SlotSize + offset);
            uint hid = 0;
            try
            {
                Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
                uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Regs[1];
                Msg init = Msg.Cmif(0, Bytes(0L)); init.SendPid = true; Call(sm, init);
                Reply service = Call(sm, Msg.Cmif(1, Name8("hid")));
                hid = service.Move.Count == 1 ? service.Move[0] : 0;
                uint tm = FakeNative.TmemCreate((ulong)buf, 0x4000, 1);
                Msg enable = Msg.Cmif(320, Bytes(1L, 0x4000ul)); enable.SendPid = true; enable.Copy.Add(tm);
                Reply enabled = Call(hid, enable);
                Check("本地IMU：只开hid320、不登记旧六轴", "0 / True / False", $"{enabled.Result} / {npads.Imu.Active} / {npads.SixAxisActive}");

                lock (FeedbackTestSync)
                {
                    _feedbackNow = 1_000_000; _motionEnabledTest = 0;
                    _inputV2Test = new() { Abi = 2, Size = 224, Generation = 55, Session = 66, ConnectedMask = 3, Flags = 3 };
                    _inputV2Test.Slots[0].Type = 8; _inputV2Test.Slots[1].Type = 16;
                    _feedbackTest = new() { Abi = 1, Size = 672, Generation = 55, Session = 66, SlotCount = 8, Flags = 7 };
                    _feedbackTest.Slots[0] = new() { Type = 8, Connected = 1, MotionMask = 1, Reserved = 1,
                        Left = new() { TimestampUs = _feedbackNow, Az = 1, Gx = 90 } };
                    _feedbackTest.Slots[1] = new() { Type = 16, Connected = 1, MotionMask = 2, Reserved = 2,
                        Right = new() { TimestampUs = _feedbackNow, Az = 1, Gy = -180 } };
                }
                InputPump.LocalPadsReadV2 = &ReadInputV2Test; InputPump.LocalPadsRead = null; InputPump.InputHook = null;
                InputPump.LocalFeedbackApi = new() { Read = &ReadFeedbackTest, MotionEnable = &EnableMotionTest,
                    Rumble = &RumbleLocalTest, Stop = &StopFeedbackTest, Now = &FeedbackClockTest };
                InputPump.SetPrimary(Host.Device, PlayerIndex.Player1, ControllerType.ProController);
                bool ready = Settle(() => Wi(0) == 1 && Wi(1) == 1);
                Check("本地IMU：启用两只独立传感器并写入各玩家首样本", "True / 3", $"{ready} / {_motionEnabledTest}");
                bool vectors = MathF.Abs(F32(0, 0x18) - 9.80665f) < .0001f && MathF.Abs(F32(0, 0x1c) - MathF.PI / 2) < .0001f &&
                    MathF.Abs(F32(1, 0x18) - 9.80665f) < .0001f && MathF.Abs(F32(1, 0x20) + MathF.PI) < .0001f;
                Check("本地IMU：两玩家真实轴与单位不串线", "True", vectors.ToString());
                Thread.Sleep(100);
                Check("本地IMU：重复轮询同时间戳不伪造样本", "1 / 1", $"{Wi(0)} / {Wi(1)}");
                lock (FeedbackTestSync)
                {
                    _feedbackNow += 10_000;
                    _feedbackTest.Slots[0].Left.TimestampUs = _feedbackNow;
                    _feedbackTest.Slots[1].Right.TimestampUs = _feedbackNow;
                }
                Check("本地IMU：下个真实样本各写一次", "True", Settle(() => Wi(0) == 2 && Wi(1) == 2).ToString());
                Msg disable = Msg.Cmif(321, Bytes(1L)); disable.SendPid = true; Call(hid, disable);
                bool stopped = Settle(() => { lock (FeedbackTestSync) return _motionEnabledTest == 0; });
                Check("本地IMU：关闭320通道后停止传感器，不依赖旧六轴", "True / 2 / 2", $"{stopped} / {Wi(0)} / {Wi(1)}");

                // The current ABI has separate left/right channels for a combined pair; neither may be discarded.
                Reply pairEnabled = Call(hid, enable);
                lock (FeedbackTestSync)
                {
                    _feedbackNow += 10_000;
                    _inputV2Test.Generation++; _inputV2Test.ConnectedMask = 1; _inputV2Test.Slots[0].Type = 4;
                    _feedbackTest.Generation = _inputV2Test.Generation;
                    _feedbackTest.Slots[0] = new() { Type = 4, Connected = 1, MotionMask = 3, Reserved = 3,
                        Left = new() { TimestampUs = _feedbackNow, Az = 1, Gx = 90 },
                        Right = new() { TimestampUs = _feedbackNow, Az = 1, Gy = -180 } };
                    _feedbackTest.Slots[1] = default;
                }
                ulong RightWi() => *(ulong*)(buf + NpadImu.SecondSensorBase + NpadImu.WriteIndexOffset);
                bool pairReady = Settle(() => Wi(0) == 1 && RightWi() == 1);
                float rightGyro = *(float*)(buf + NpadImu.SecondSensorBase + 0x20);
                Check("本地IMU：合体双JoyCon分别写入传感器0与1", "0 / True / True", $"{pairEnabled.Result} / {pairReady} / {MathF.Abs(F32(0, 0x1c) - MathF.PI / 2) < .0001f && MathF.Abs(rightGyro + MathF.PI) < .0001f}");
                Thread.Sleep(100);
                Check("本地IMU：合体两路重复轮询均不伪造样本", "1 / 1", $"{Wi(0)} / {RightWi()}");
                lock (FeedbackTestSync)
                {
                    _feedbackNow += 10_000;
                    _feedbackTest.Slots[0].Right.TimestampUs = _feedbackNow;
                }
                bool rightAdvanced = Settle(() => RightWi() == 2);
                Check("本地IMU：只有右只更新时仅推进右传感器", "True / 1 / 2", $"{rightAdvanced} / {Wi(0)} / {RightWi()}");
                Call(hid, disable);

                Call(hid, enable);
                lock (FeedbackTestSync)
                {
                    _feedbackNow += 10_000; _inputV2Test.Generation++;
                    _feedbackTest.Generation = _inputV2Test.Generation;
                    _feedbackTest.Slots[0] = new() { Type = 4, Connected = 1, MotionMask = 2,
                        Reserved = 2 | LocalControllerFeedback.MotionSingleSource,
                        Right = new() { TimestampUs = _feedbackNow, Az = 1, Gy = -180 } };
                }
                bool fusedReady = Settle(() => Wi(0) == 1 && RightWi() == 1);
                bool fusedVectors = MathF.Abs(F32(0, 0x20) + MathF.PI) < .0001f &&
                    MathF.Abs(*(float*)(buf + NpadImu.SecondSensorBase + 0x20) + MathF.PI) < .0001f;
                Check("本地IMU：OS明确标记的单融合来源保留官方双环兼容", "True / True", $"{fusedReady} / {fusedVectors}");
                Thread.Sleep(100);
                Check("本地IMU：单融合来源不因轮询制造新读数", "1 / 1", $"{Wi(0)} / {RightWi()}");
                Call(hid, disable);
            }
            finally
            {
                InputPump.Stop();
                npads.Imu.Disable(1);
                InputPump.LocalPadsReadV2 = oldRead; InputPump.LocalPadsRead = oldLegacy;
                InputPump.LocalFeedbackApi = oldApi; InputPump.InputHook = oldHook;
                InputPump.SetPrimary(Host.Device, PlayerIndex.Handheld, ControllerType.Handheld);
            }
        }
    }
}
