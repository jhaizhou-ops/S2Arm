#import <CoreBluetooth/CoreBluetooth.h>
#include "NS2Module.h"

static int authorization_denied(void) {
    return CBManager.authorization == CBManagerAuthorizationDenied ||
           CBManager.authorization == CBManagerAuthorizationRestricted;
}

__attribute__((visibility("default")))
const ns2_api *ns2_module_api(void) {
    static const ns2_api api = {
        .abi_version = NS2_MODULE_ABI_VERSION,
        .struct_size = sizeof(ns2_api),
        .start_with_motion = ns2_start_with_motion,
        .rescan = ns2_rescan,
        .suspend = ns2_suspend,
        .resume = ns2_resume,
        .shutdown = ns2_shutdown,
        .get_info = ns2_get_info,
        .set_motion_enabled = ns2_set_motion_enabled,
        .send_pair_lease = ns2_send_pair_lease,
        .send_lease = ns2_send_lease,
        .stop_rumble = ns2_stop_rumble,
        .get_motion = ns2_get_motion,
        .authorization_denied = authorization_denied,
    };
    return &api;
}
