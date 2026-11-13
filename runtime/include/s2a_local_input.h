// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#ifndef S2A_LOCAL_INPUT_H
#define S2A_LOCAL_INPUT_H
#include <stdint.h>

#define S2A_LOCAL_MAX_PLAYERS 8
#define S2A_LOCAL_PRIMARY_COMPLETE 1u
#define S2A_LOCAL_FOCUSED 2u
#define S2A_FEEDBACK_FOCUSED 1u
#define S2A_FEEDBACK_MOTION_ALLOWED 2u
#define S2A_FEEDBACK_RUMBLE_ALLOWED 4u
// Reserved feedback bit: an OS-combined Joy-Con pair exposes one fused IMU.
#define S2A_LOCAL_MOTION_SINGLE_SOURCE (1u << 2)

// Nintendo physical controller coordinates; single right Joy-Con uses RStick.
typedef struct {
    uint32_t type, buttons;
    int32_t lx, ly, rx, ry;
} s2a_local_input_slot;
typedef struct {
    uint32_t abi, size, generation, connected_mask;
    uint64_t session;
    uint32_t flags, reserved;
    s2a_local_input_slot slots[S2A_LOCAL_MAX_PLAYERS];
} s2a_local_input_snapshot;

// Timestamp identifies a real sensor update, monotonic microseconds.
// Acceleration is in g in MotionInput's pre-fusion coordinates (flat face-up: +Z).
// MotionInput negates acceleration once for HID; angular velocity is degrees/second.
typedef struct {
    uint64_t timestamp_us;
    float ax, ay, az, gx, gy, gz;
} s2a_local_motion_sample;
typedef struct {
    uint32_t type, connected, motion_mask, reserved;
    // Left = bit0/sample0; Right = bit1/sample1; Pair = both; full pad = bit0/sample0.
    // reserved bits 0..1: motion capabilities, bit2: one OS-fused pair IMU,
    // bits 8..9: rumble capabilities.
    s2a_local_motion_sample motion[2];
} s2a_local_feedback_slot;
typedef struct {
    uint32_t abi, size, generation, slot_count;
    uint64_t session;
    uint32_t flags, reserved;
    s2a_local_feedback_slot slots[S2A_LOCAL_MAX_PLAYERS];
} s2a_local_feedback_snapshot;
typedef struct { float low_amp, low_hz, high_amp, high_hz; } s2a_local_vibration;

_Static_assert(sizeof(s2a_local_input_snapshot) == 224, "input ABI 2");
_Static_assert(sizeof(s2a_local_motion_sample) == 32, "motion ABI");
_Static_assert(sizeof(s2a_local_feedback_snapshot) == 672, "feedback ABI 1");

// Return 0 = legacy input path, 1 = handled, including neutral/disconnected frames.
int s2a_local_pads_read_v2(s2a_local_input_snapshot *out);
int s2a_local_feedback_read(s2a_local_feedback_snapshot *out);
// Optional platform hooks. Platform adapters resolve them; probes never consume virtual input.
void s2a_local_merge_virtual(uint64_t session, uint32_t generation, s2a_local_input_slot *player0);
int s2a_local_mouse_player(void); // Local slot hosting the existing NS2 mouse path, -1 if absent.
// Exports below only write mailboxes; platform main thread applies hardware work.
void s2a_local_motion_enable(uint64_t session, uint32_t generation, uint32_t player_mask);
void s2a_local_rumble_submit(uint64_t session, uint32_t generation, uint32_t player,
                           const s2a_local_vibration pair[2], uint32_t lease_ms);
void s2a_local_feedback_stop(uint64_t session, uint32_t generation, uint32_t player_mask);
#endif
