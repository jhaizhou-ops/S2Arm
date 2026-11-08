#ifndef NS2_MODULE_H
#define NS2_MODULE_H

#include "NS2Transport.h"

#ifdef __cplusplus
extern "C" {
#endif

#define NS2_MODULE_ABI_VERSION 1u

typedef struct ns2_api {
    uint32_t abi_version;
    uint32_t struct_size;
    int (*start_with_motion)(ns2_state_callback, ns2_status_callback, ns2_motion_callback, void *);
    int (*rescan)(void);
    int (*suspend)(void);
    int (*resume)(void);
    int (*shutdown)(const char *, unsigned);
    void (*get_info)(ns2_info *);
    void (*set_motion_enabled)(int);
    void (*send_pair_lease)(const ns2_vibration[2], unsigned);
    void (*send_lease)(unsigned, float, float, float, float, unsigned);
    void (*stop_rumble)(void);
    void (*get_motion)(ns2_motion *);
    int (*authorization_denied)(void);
} ns2_api;

// Load this symbol only after the app's explicit NS2 setting is enabled.
// The function only returns the immutable table; it does not start Bluetooth.
const ns2_api *ns2_module_api(void);

#ifdef __cplusplus
}
#endif
#endif
