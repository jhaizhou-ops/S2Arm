#include "game_touch.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    int64_t view[8];
    s2a_host_touch_frame frame = {.size = sizeof frame};
    assert(s2a_android_game_touch_read(0, &frame) == S2A_HOST_E_UNSUPPORTED);
    assert(s2a_android_touch_enable(1) == 0);
    s2a_android_game_touch_viewport(1, 100, 50, 1280, 720, 1600, 900);
    assert(s2a_android_game_touch_viewport_read(view) == 0 && view[1] == 1);
    s2a_host_touch_point p = {.id = 7, .x = 65535, .y = 0};
    assert(s2a_android_game_touch_set(&p, 1, 0, 99, 1, 1) == 0);
    assert(s2a_android_game_touch_read(1, &frame) == 0 && frame.count == 1 && frame.timestamp_ns == 99);
    uint64_t cursor = frame.sequence;
    s2a_android_game_touch_viewport(1, 100, 50, 1280, 720, 1600, 900);
    assert(s2a_android_game_touch_viewport_read(view) == 0 && view[1] == 1);
    s2a_android_game_touch_viewport(1, 0, 0, 1600, 900, 1600, 900);
    assert(s2a_android_game_touch_set(&p, 1, 0, 100, 1, 1) == S2A_HOST_E_RANGE);
    assert(s2a_android_game_touch_read(cursor, &frame) == 0 && frame.flags == S2A_TOUCH_CANCEL);
    assert(s2a_android_game_touch_viewport_read(view) == 0 && view[1] == 2);
    cursor = frame.sequence;
    assert(s2a_android_game_touch_set(&p, 1, 0, 101, 1, 2) == 0);
    do { assert(s2a_android_game_touch_read(cursor, &frame) == 0); cursor = frame.sequence; } while (!frame.count);
    assert(frame.points[0].id == 7 && frame.points[0].x == 65535);
    s2a_android_game_touch_revoke();
    assert(s2a_android_game_touch_viewport_read(view) == S2A_HOST_E_UNSUPPORTED);
    assert(s2a_android_game_touch_set(&p, 1, 0, 102, 1, 2) == S2A_HOST_E_RANGE);
    s2a_android_game_touch_retire();
    s2a_android_game_touch_viewport(1, 0, 0, 1280, 720, 1280, 720);
    assert(s2a_android_game_touch_viewport_read(view) == S2A_HOST_E_UNSUPPORTED);
    s2a_android_game_touch_viewport(2, 0, 0, 1280, 720, 1280, 720);
    assert(s2a_android_game_touch_viewport_read(view) == 0 && view[0] == 2);
    s2a_android_game_touch_viewport(2, 10, 0, 1600, 900, 1600, 900);
    assert(s2a_android_game_touch_viewport_read(view) == S2A_HOST_E_UNSUPPORTED);
    // A surface may retire before its first present; late in-flight frames must not revive it.
    s2a_android_game_touch_offer(3);
    uint64_t epoch = s2a_android_game_touch_epoch();
    s2a_android_game_touch_retire();
    s2a_android_game_touch_viewport_checked(epoch, 3, 0, 0, 1280, 720, 1280, 720);
    assert(s2a_android_game_touch_viewport_read(view) == S2A_HOST_E_UNSUPPORTED);
    s2a_android_game_touch_offer(4);
    epoch = s2a_android_game_touch_epoch();
    s2a_android_game_touch_revoke();
    s2a_android_game_touch_viewport_checked(epoch, 4, 0, 0, 1280, 720, 1280, 720);
    assert(s2a_android_game_touch_viewport_read(view) == S2A_HOST_E_UNSUPPORTED);
    epoch = s2a_android_game_touch_epoch();
    s2a_android_game_touch_viewport_checked(epoch, 4, 0, 0, 1280, 720, 1280, 720);
    assert(s2a_android_game_touch_viewport_read(view) == S2A_HOST_E_OK && view[0] == 4);
    assert(s2a_android_touch_enable(0) == 0);
    assert(s2a_android_game_touch_read(cursor, &frame) == S2A_HOST_E_UNSUPPORTED);
    puts("game touch: viewport, stale-race cancellation, mapping, revoke and off gates passed");
}
