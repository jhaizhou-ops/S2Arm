// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#ifndef S2A_LAN_DISCOVERY_H
#define S2A_LAN_DISCOVERY_H
#include <stdint.h>
/* Platform registers a process-lifetime table before Boot. ABI must be 1;
 * all three callbacks are required. No runtime provider replacement.
 * Calls may arrive on LAN service threads: callbacks must be reentrant and
 * nonblocking (return within 100 ms). start schedules discovery/publication on platform threads,
 * returning 0 on acceptance or negative errno on failure (never fake success).
 * Order: start -> any number of set_hosting -> stop. start after stop is valid;
 * repeated stop is harmless. After stop returns no old session callback may
 * call S2A_LdnSetServer. The platform must invalidate queued callbacks and
 * synchronize any in-flight callback before returning; network cleanup may
 * finish asynchronously. port is the actual relay port, never a fixed value.
 */
typedef struct s2a_lan_discovery_v1 {
    uint32_t abi;
    int (*start)(uint64_t program_id, uint16_t port);
    void (*set_hosting)(int on);
    void (*stop)(void);
} s2a_lan_discovery_v1;
#endif
