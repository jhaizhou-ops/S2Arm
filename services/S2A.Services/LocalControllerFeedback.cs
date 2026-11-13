// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.HLE;
using Ryujinx.HLE.HOS.Services.Hid;
using Ryujinx.HLE.HOS.Services.Hid.Types;
using Ryujinx.Input;
using System;
using System.Collections.Generic;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace S2A.Services
{
    // One owner for Npads' three feedback callbacks. Native calls only exchange mailboxes;
    // the platform thread, not this HID/game thread, performs sensor and haptic hardware work.
    internal sealed unsafe class LocalControllerFeedback
    {
        internal const uint MotionSingleSource = 4; // Host explicitly exposes one fused source for an OS-combined pair.
        internal const float GyroDeadzoneDps = 1f; // Same vector-length threshold as Ryujinx's default controller motion profile.
        [StructLayout(LayoutKind.Sequential)]
        internal struct MotionSample { public ulong TimestampUs; public float Ax, Ay, Az, Gx, Gy, Gz; }
        [StructLayout(LayoutKind.Sequential)]
        internal struct MouseSample
        {
            public ulong TimestampUs;
            public short X, Y;
            public ushort Distance;
            public byte Side, Known;
        }
        [StructLayout(LayoutKind.Sequential)]
        internal struct FeedbackSlot
        {
            public uint Type, Connected, MotionMask, Reserved;
            public MotionSample Left, Right;
        }
        [InlineArray(8)] internal struct FeedbackSlots { private FeedbackSlot _first; }
        [StructLayout(LayoutKind.Sequential)]
        internal struct FeedbackSnapshot
        {
            public uint Abi, Size, Generation, SlotCount;
            public ulong Session;
            public uint Flags, Reserved;
            public FeedbackSlots Slots;
        }
        internal struct NativeApi
        {
            public delegate* unmanaged<FeedbackSnapshot*, int> Read;
            public delegate* unmanaged<ulong, uint, uint, void> MotionEnable;
            public delegate* unmanaged<ulong, uint, uint, VibrationValue*, uint, void> Rumble;
            public delegate* unmanaged<ulong, uint, uint, void> Stop;
            public delegate* unmanaged<ulong> Now;
            public delegate* unmanaged<MouseSample*, int> ReadMousePair;
            public delegate* unmanaged<int> MousePlayer;
        }
        internal static NativeApi FromBackend(LocalControllerBackend backend) => new()
        {
            Read = (delegate* unmanaged<FeedbackSnapshot*, int>)backend.ReadFeedback,
            MotionEnable = (delegate* unmanaged<ulong, uint, uint, void>)backend.MotionEnable,
            Rumble = (delegate* unmanaged<ulong, uint, uint, VibrationValue*, uint, void>)backend.Rumble,
            Stop = (delegate* unmanaged<ulong, uint, uint, void>)backend.StopFeedback,
            Now = (delegate* unmanaged<ulong>)backend.Now,
            ReadMousePair = (delegate* unmanaged<MouseSample*, int>)backend.ReadMousePair,
            MousePlayer = (delegate* unmanaged<int>)backend.MousePlayer,
        };
        private ulong Now() => _api.Now();
        private readonly NpadDevices _npads;
        private readonly Switch _device;
        private readonly NativeApi _api;
        private readonly List<SixAxisInput> _motionStates = new(16);
        private readonly MotionInput[,] _filters = new MotionInput[8, 2];
        private readonly float[][] _orientations = new float[16][];
        private readonly VibrationValue[] _left = new VibrationValue[8], _right = new VibrationValue[8];
        private readonly ulong[] _renewAt = new ulong[8];
        private readonly Action _beforeHook;
        private readonly Action<PlayerIndex, VibrationValue, VibrationValue> _rumbleHook;
        private readonly Action<bool> _permissionHook;
        private InputPump.LocalInputSnapshot _input;
        private FeedbackSnapshot _feedback;
        private uint _available, _enabledMotion;
        private bool _haveContext, _valid, _motionAllowed, _rumbleAllowed, _motionPublished;
        private volatile bool _stopped;
        private bool _mouseConnected;

        internal LocalControllerFeedback(Switch device, NativeApi api)
        {
            if (api.Read == null || api.Now == null)
                throw new ArgumentException("Local-controller feedback requires a reader and its monotonic clock", nameof(api));
            _device = device; _npads = device.Hid.Npads; _api = api;
            for (int i = 0; i < 16; i++) _orientations[i] = new float[9];
            _beforeHook = Observe; _rumbleHook = AcceptRumble; _permissionHook = PermissionChanged;
            lock (_npads.RumbleSyncRoot)
            {
                _npads.RumbleBeforeAccepted = _beforeHook;
                _npads.RumbleAccepted = _rumbleHook;
                _npads.RumblePermissionChanged = _permissionHook;
            }
        }

        private void StopNative(ulong session, uint generation, uint mask)
        {
            if (session == 0) return;
            if (_api.Stop != null) _api.Stop(session, generation, mask);
            if (_api.MotionEnable != null) _api.MotionEnable(session, generation, 0);
        }
        private void ResetLocked()
        {
            if (_haveContext) StopNative(_input.Session, _input.Generation, _input.ConnectedMask);
            Array.Clear(_filters); Array.Clear(_left); Array.Clear(_right); Array.Clear(_renewAt);
            for (int i = 0; i < NpadDevices.MaxControllers; i++) _npads.ResetRumble((PlayerIndex)i);
            _enabledMotion = 0;
        }
        private void ResetSlots(uint mask)
        {
            if (_api.Stop != null && _input.Session != 0) _api.Stop(_input.Session, _input.Generation, mask);
            for (int i = 0; i < 8; i++)
                if ((mask & (1u << i)) != 0)
                {
                    _filters[i, 0] = _filters[i, 1] = null;
                    _left[i] = _right[i] = default; _renewAt[i] = 0;
                    _npads.ResetRumble(InputPump.LocalPlayer(in _input, i));
                }
        }
        private void Observe()
        {
            if (_stopped || !_haveContext) return;
            FeedbackSnapshot value = default;
            bool valid = _api.Read != null && _api.Read(&value) == 1 && value.Abi == 1 && value.Size == 672 && value.SlotCount <= 8 &&
                value.Generation == _input.Generation && value.Session != 0 && value.Session == _input.Session &&
                (value.Flags & 1) != 0 && (_input.Flags & InputPump.LocalFocused) != 0;
            uint available = 0;
            if (valid)
                for (int i = 0; i < value.SlotCount; i++)
                    if ((_input.ConnectedMask & (1u << i)) != 0 && value.Slots[i].Connected != 0 && value.Slots[i].Type == _input.Slots[i].Type)
                    {
                        PlayerIndex player = InputPump.LocalPlayer(in _input, i);
                        if (_npads.IsSupportedPlayer(player) && _device.Hid.SharedMemory.Npads[(int)player].InternalState.StyleSet != 0)
                            available |= 1u << i;
                    }
            bool motion = valid && (value.Flags & 2) != 0;
            bool rumble = valid && (value.Flags & 4) != 0 && _npads.VibrationPermitted;
            if (valid != _valid || motion != _motionAllowed || rumble != _rumbleAllowed) ResetLocked();
            else if (available != _available) ResetSlots(available ^ _available);
            _feedback = value; _valid = valid; _available = available; _motionAllowed = motion; _rumbleAllowed = rumble;
        }
        private void PermissionChanged(bool permitted)
        {
            if (_stopped) return;
            ResetLocked();
            _rumbleAllowed = permitted && _valid && (_feedback.Flags & 4) != 0;
        }
        private int FindSlot(PlayerIndex player)
        {
            for (int i = 0; i < 8; i++)
                if ((_available & (1u << i)) != 0 && InputPump.LocalPlayer(in _input, i) == player) return i;
            return -1;
        }
        private static bool Vibrating(VibrationValue value) => value.AmplitudeLow > 0 || value.AmplitudeHigh > 0;
        private void Submit(int slot, VibrationValue left, VibrationValue right, ulong now)
        {
            if (_api.Rumble == null) return;
            VibrationValue* values = stackalloc VibrationValue[2]; values[0] = left; values[1] = right;
            _api.Rumble(_input.Session, _input.Generation, (uint)slot, values, 750);
            _renewAt[slot] = now + 250_000;
        }
        private void AcceptRumble(PlayerIndex player, VibrationValue left, VibrationValue right)
        {
            if (_stopped || !_valid || !_rumbleAllowed) return;
            int slot = FindSlot(player);
            if (slot < 0) return;
            if (left != _left[slot] || right != _right[slot]) Submit(slot, left, right, Now());
            _left[slot] = left; _right[slot] = right;
        }

        internal static bool Fresh(in MotionSample sample, ulong now) => sample.TimestampUs != 0 && sample.TimestampUs <= now &&
            now - sample.TimestampUs <= 250_000 && float.IsFinite(sample.Ax) && float.IsFinite(sample.Ay) && float.IsFinite(sample.Az) &&
            float.IsFinite(sample.Gx) && float.IsFinite(sample.Gy) && float.IsFinite(sample.Gz);
        private SixAxisInput Motion(int slot, int side, in MotionSample sample, PlayerIndex player, int imuSensor = -1)
        {
            MotionInput filter = _filters[slot, side];
            if (filter != null && (sample.TimestampUs < filter.TimeStamp || sample.TimestampUs - filter.TimeStamp > 250_000)) filter = null;
            filter ??= new MotionInput();
            if (filter.TimeStamp != sample.TimestampUs)
            {
                Vector3 acceleration = new(SixAxisSensorIc.ClampAcceleration(sample.Ax), SixAxisSensorIc.ClampAcceleration(sample.Ay), SixAxisSensorIc.ClampAcceleration(sample.Az));
                Vector3 gyro = new(SixAxisSensorIc.ClampAngularRate(sample.Gx), SixAxisSensorIc.ClampAngularRate(sample.Gy), SixAxisSensorIc.ClampAngularRate(sample.Gz));
                // The upstream IMU channel consumes the same real raw sample as the six-axis filter.
                // A pair has two real sources: route each to its own current IMU sensor channel.
                // A repeated poll is not a new sample. Single/remapped controllers retain the single-source path.
                _npads.PushImu(player, acceleration, gyro, sample.TimestampUs, imuSensor);
                filter.Update(acceleration, gyro, sample.TimestampUs, 100, GyroDeadzoneDps);
            }
            _filters[slot, side] = filter;
            Matrix4x4 m = filter.GetOrientation(); float[] orientation = _orientations[slot * 2 + side];
            orientation[0] = m.M11; orientation[1] = m.M12; orientation[2] = m.M13;
            orientation[3] = m.M21; orientation[4] = m.M22; orientation[5] = m.M23;
            orientation[6] = m.M31; orientation[7] = m.M32; orientation[8] = m.M33;
            return new() { PlayerId = player, Accelerometer = filter.Accelerometer, Gyroscope = filter.Gyroscrope * .0027f,
                Rotation = filter.Rotation * .0027f, Orientation = orientation };
        }
        private void UpdateMotion(ulong now)
        {
            _motionStates.Clear(); uint enabled = 0;
            for (int slot = 0; slot < 8; slot++)
            {
                uint bit = 1u << slot;
                PlayerIndex player = InputPump.LocalPlayer(in _input, slot);
                FeedbackSlot source = _feedback.Slots[slot];
                ControllerType actual = (ControllerType)NpadDevices.Base(_device.Hid.SharedMemory.Npads[(int)player].InternalState.StyleSet);
                uint active = _npads.GetActiveSixAxisMask(player);
                uint type = _input.Slots[slot].Type;
                bool pair = type == (uint)ControllerType.JoyconPair;
                int side = type == (uint)ControllerType.JoyconRight ? 1 : 0;
                uint capabilities = source.Reserved & 3;
                bool singleSource = pair && (source.Reserved & MotionSingleSource) != 0 && capabilities is 1 or 2;
                if (singleSource) side = capabilities == 2 ? 1 : 0;
                uint required = pair && !singleSource ? 3u : 1u << side;
                bool capable = (source.Reserved & required) == required;
                bool wanted = _valid && _motionAllowed && (_available & bit) != 0 && (active != 0 || _npads.Imu.Active) && actual != ControllerType.None && capable;
                if (wanted) enabled |= bit;
                bool samples = wanted && (source.MotionMask & required) == required &&
                    (side == 0 ? Fresh(in source.Left, now) : Fresh(in source.Right, now)) && (!pair || singleSource || Fresh(in source.Right, now));
                if (!samples)
                {
                    _filters[slot, 0] = _filters[slot, 1] = null;
                    continue;
                }
                if (pair && !singleSource && actual == ControllerType.JoyconPair)
                {
                    _motionStates.Add(Motion(slot, 0, in source.Left, player, imuSensor: 0));
                    _motionStates.Add(Motion(slot, 1, in source.Right, player, imuSensor: 1));
                }
                else
                {
                    if (pair && !singleSource) side = 1; // A pair remapped to FullKey uses the right IMU, matching SDL/Mush8.
                    // An explicitly fused OS pair follows the official single-source path (sensor=-1).
                    MotionSample sample = side == 0 ? source.Left : source.Right;
                    _motionStates.Add(Motion(slot, side, in sample, player));
                }
            }
            if (enabled != _enabledMotion)
            {
                uint disabled = _enabledMotion & ~enabled;
                if (disabled != 0)
                {
                    if (_api.Stop != null) _api.Stop(_input.Session, _input.Generation, disabled);
                    for (int i = 0; i < 8; i++) if ((disabled & (1u << i)) != 0)
                    { _left[i] = _right[i] = default; _renewAt[i] = 0; _npads.ResetRumble(InputPump.LocalPlayer(in _input, i)); }
                }
                if (_api.MotionEnable != null) _api.MotionEnable(_input.Session, _input.Generation, enabled);
                _enabledMotion = enabled;
            }
            if (_motionStates.Count != 0 || _motionPublished) _npads.UpdateSixAxis(_motionStates);
            _motionPublished = _motionStates.Count != 0;
        }

        // Preserve the current host's Joy-Con 2 mouse/connection semantics while the local feedback owner is active.
        // Native supplies the slot of its original NS2 source so mixed SDL/GC setups cannot assign its mouse to SDL P1.
        private void UpdateMouse()
        {
            if (_api.ReadMousePair == null || _api.MousePlayer == null) return;
            MouseSample* samples = stackalloc MouseSample[2];
            int slot = _api.MousePlayer();
            int sides = _api.ReadMousePair(samples);
            if (slot < 0 || slot >= 8 || (_input.ConnectedMask & (1u << slot)) == 0 || sides == 0)
            {
                if (_mouseConnected) _npads.Jcms.Disconnect();
                _mouseConnected = false;
                _npads.SetJoycon2(false);
                return;
            }
            _mouseConnected = true;
            _npads.SetJoycon2(true);
            if ((_input.Flags & InputPump.LocalFocused) == 0) return;
            PlayerIndex player = InputPump.LocalPlayer(in _input, slot);
            int npadId = player >= PlayerIndex.Player1 && player <= PlayerIndex.Player8 ? (int)player : 0;
            NpadJcms.Side left = new() { Present = samples[0].Side == 0, Known = samples[0].Known != 0,
                X = samples[0].X, Y = samples[0].Y, OnSurface = samples[0].Distance == 0 };
            NpadJcms.Side right = new() { Present = samples[1].Side == 1, Known = samples[1].Known != 0,
                X = samples[1].X, Y = samples[1].Y, OnSurface = samples[1].Distance == 0 };
            bool pair = NpadDevices.Base(_npads.StyleOf(player)) == Ryujinx.HLE.HOS.Services.Hid.Types.SharedMemory.Npad.NpadStyleTag.JoyDual;
            if (_npads.Jcms.Active) _npads.Jcms.Push(npadId, left, right,
                samples[0].Side == 0 ? samples[0].TimestampUs : samples[1].TimestampUs, pair);
        }

        private void SetContext(in InputPump.LocalInputSnapshot input)
        {
            if (!_haveContext || !InputPump.SameLocalConfiguration(in _input, in input) || input.Session != _input.Session ||
                (input.Flags & InputPump.LocalFocused) != (_input.Flags & InputPump.LocalFocused))
            {
                ResetLocked(); _input = input; _haveContext = true;
                _valid = _motionAllowed = _rumbleAllowed = false; _available = 0;
            }
            else _input = input;
        }
        // Install the new session before its controller style becomes visible to a game thread.
        internal void Prepare(in InputPump.LocalInputSnapshot input)
        {
            lock (_npads.RumbleSyncRoot) { if (!_stopped) SetContext(in input); }
        }
        internal void Tick(in InputPump.LocalInputSnapshot input)
        {
            lock (_npads.RumbleSyncRoot)
            {
                if (_stopped) return;
                SetContext(in input);
                Observe(); ulong now = Now();
                UpdateMouse();
                UpdateMotion(now);
                if (_valid && _rumbleAllowed)
                    for (int i = 0; i < 8; i++)
                        if ((_available & (1u << i)) != 0 && now >= _renewAt[i] && (Vibrating(_left[i]) || Vibrating(_right[i])))
                            Submit(i, _left[i], _right[i], now);
            }
        }
        internal void Stop()
        {
            lock (_npads.RumbleSyncRoot)
            {
                if (_stopped) return;
                _stopped = true; ResetLocked();
                if (_npads.RumbleBeforeAccepted == _beforeHook) _npads.RumbleBeforeAccepted = null;
                if (_npads.RumbleAccepted == _rumbleHook) _npads.RumbleAccepted = null;
                if (_npads.RumblePermissionChanged == _permissionHook) _npads.RumblePermissionChanged = null;
                _motionStates.Clear();
                if (_motionPublished) _npads.UpdateSixAxis(_motionStates);
                _motionPublished = false;
            }
        }
    }
}
