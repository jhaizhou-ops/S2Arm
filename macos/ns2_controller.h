// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#ifndef S2A_MAC_NS2_CONTROLLER_H
#define S2A_MAC_NS2_CONTROLLER_H
#include "../runtime/ns2pro/include/NS2Transport.h"
#include "../runtime/include/s2a_pad.h"

// The menu and the remembered-controller startup path share the same transport.
int s2a_mac_ns2_connect(void);
void s2a_mac_ns2_disconnect(void);
void s2a_mac_ns2_detach(void);
void s2a_mac_ns2_focus(int focused);
int s2a_mac_ns2_read(ns2_state *state);
void s2a_mac_ns2_set_back_buttons(uint16_t left, uint16_t right);
ns2_status s2a_mac_ns2_status(void);
#endif
