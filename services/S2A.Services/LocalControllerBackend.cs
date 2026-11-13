// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
namespace S2A.Services
{
    // Managed platform-composition contract for runtime/include/s2a_local_input.h.
    // Callback addresses and their owner live until process exit; publish before Boot only.
    // Snapshot/WakeSequence reads are non-consuming. MergeVirtual is called only by the HID commit owner.
    // A feedback reader requires Now in the same monotonic microsecond epoch as its samples.
    public sealed class LocalControllerBackend
    {
        public nint ReadInput { get; init; }
        public nint ReadLegacyInput { get; init; }
        public nint WakeSequence { get; init; }
        public nint MergeVirtual { get; init; }
        public nint ReadFeedback { get; init; }
        public nint MotionEnable { get; init; }
        public nint Rumble { get; init; }
        public nint StopFeedback { get; init; }
        public nint Now { get; init; }
        public nint ReadMousePair { get; init; }
        public nint MousePlayer { get; init; }
    }
}
