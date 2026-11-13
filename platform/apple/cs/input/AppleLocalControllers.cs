// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Runtime.InteropServices;
using S2A.Services;

namespace S2A.Apple.Input
{
    // Only the Apple composition discovers optional host exports. Shared services
    // consume the registered contract and never choose a platform or symbol owner.
    public static class AppleLocalControllers
    {
        public static void Register()
        {
            nint owner = NativeLibrary.GetMainProgramHandle();
            nint Find(string name) => NativeLibrary.TryGetExport(owner, name, out nint value) ? value : 0;
            nint input = Find("s2a_local_pads_read_v2"), legacy = Find("s2a_local_pads_read");
            if (input == 0 && legacy == 0) return; // Old host: keep its complete existing path.
            nint feedback = Find("s2a_local_feedback_read"), clock = Find("s2a_pad_now_us");
            if (feedback != 0 && clock == 0)
                throw new MissingMethodException("Local-controller feedback has no monotonic clock");
            nint mouse = Find("s2a_pad_read_mouse_pair"), mousePlayer = Find("s2a_local_mouse_player");
            Exports.LocalControllers = new LocalControllerBackend
            {
                ReadInput = input, ReadLegacyInput = legacy,
                WakeSequence = Find("s2a_pad_notification_seq"),
                MergeVirtual = Find("s2a_local_merge_virtual"),
                ReadFeedback = feedback, MotionEnable = Find("s2a_local_motion_enable"),
                Rumble = Find("s2a_local_rumble_submit"), StopFeedback = Find("s2a_local_feedback_stop"), Now = clock,
                ReadMousePair = mousePlayer != 0 ? mouse : 0, MousePlayer = mouse != 0 ? mousePlayer : 0,
            };
        }
    }
}
