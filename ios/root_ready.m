#include "root_ready.h"
#include <dispatch/dispatch.h>
#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <stdint.h>

static dispatch_group_t root_ready_group(void) {
    static dispatch_group_t group; static dispatch_once_t once;
    dispatch_once(&once, ^{ group = dispatch_group_create(); dispatch_group_enter(group); });
    return group;
}
void s2a_ios_root_view_ready(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ dispatch_group_leave(root_ready_group()); });
}
int s2a_ios_wait_root_view(int timeout_ms) {
    int64_t ns = (int64_t)(timeout_ms > 0 ? timeout_ms : 0) * NSEC_PER_MSEC;
    return dispatch_group_wait(root_ready_group(), dispatch_time(DISPATCH_TIME_NOW, ns)) == 0 ? 0 : -1;
}
void s2a_ios_wait_ui_signal(dispatch_semaphore_t done) {
    if (!pthread_main_np()) { dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER); return; }
    while (dispatch_semaphore_wait(done, DISPATCH_TIME_NOW)) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
}
void s2a_ios_on_root_view(void (^block)(void)) {
    dispatch_group_notify(root_ready_group(), dispatch_get_main_queue(), block);
}
