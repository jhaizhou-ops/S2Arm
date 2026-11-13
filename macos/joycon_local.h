// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#ifndef S2A_JOYCON_LOCAL_H
#define S2A_JOYCON_LOCAL_H
#include <stdint.h>
#include "../runtime/include/s2a_local_input.h"

// Optional Mac-only HID input. Keep the legacy s2a_vpad_read ABI unchanged.
// Values are Nintendo physical buttons/axes, not sideways mini-gamepad axes.
typedef struct {
    uint32_t type, buttons;
    int32_t lx, ly, rx, ry;
} s2a_local_pad_slot;
typedef struct {
    uint32_t abi, connected_mask, generation, reserved;
    s2a_local_pad_slot slots[2];
} s2a_local_pads_snapshot;
_Static_assert(sizeof(s2a_local_pads_snapshot) == 64, "local pad ABI");

void s2a_local_pads_poll(int focused);
int s2a_local_pads_available(void);
void s2a_local_pads_set_mode(int split);
int s2a_local_pads_mode(void);
uint32_t s2a_local_pads_system_buttons(void);
void s2a_local_pads_shutdown(void);
int s2a_local_pads_prepare(s2a_local_input_snapshot *out);
void s2a_local_pads_commit(const s2a_local_input_snapshot *frame, int fallback_slot,
                           const s2a_local_feedback_slot *fallback, uint32_t external_generation);
void s2a_local_pads_feedback_update(int slot, const s2a_local_feedback_slot *feedback);
void s2a_local_pads_update_external_input(int slot, const s2a_local_input_slot *state);
void s2a_local_pads_fallback_request(int slot, int *motion, s2a_local_vibration pair[2]);
int s2a_local_pads_read(s2a_local_pads_snapshot *out);
void s2a_local_pads_set_motion(int enabled);
int s2a_local_pads_motion_enabled(void);
void s2a_local_pads_set_rumble(int enabled);
int s2a_local_pads_rumble_enabled(void);
void s2a_local_pads_recenter(void);
#endif
