// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using Ryujinx.Audio.Backends.Apple;
using Ryujinx.Audio.Backends.Dummy;
using Ryujinx.Audio.Integration;
using S2A.Services;

namespace S2A.Apple.Audio
{
    public static class AppleAudio
    {
        public static IHardwareDeviceDriver Create()
        {
            if (Environment.GetEnvironmentVariable("S2A_AUDIO_OFF") == "1")
            {
                Console.Error.WriteLine("[S2A 声音] S2A_AUDIO_OFF=1：哑设备（能耗减法实验）");
                return new DummyHardwareDeviceDriver();
            }
            if (AppleHardwareDeviceDriver.IsSupported) return new AppleHardwareDeviceDriver();
            Red.Report("苹果声音输出不可用，退到哑设备");
            return new DummyHardwareDeviceDriver();
        }
    }
}
