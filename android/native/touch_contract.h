// Platform-neutral touch transport. Coordinates are normalized to the final
// game viewport, not the Android window, cutout-safe area or a game's pixels.
#pragma once
#include <stdint.h>

#define S2A_TOUCH_MAX_POINTS 16u
#define S2A_TOUCH_COORD_MAX 65535u
#define S2A_TOUCH_CANCEL 1u

typedef struct s2a_host_touch_point {
    uint32_t id;             // Stable for this contact's lifetime; arbitrary host ID.
    uint32_t x, y;           // 0..65535, top-left origin, final game viewport.
    uint32_t diameter_x, diameter_y; // Same units; 0 means unknown.
} s2a_host_touch_point;

typedef struct s2a_host_touch_frame {
    uint32_t size, abi_version;
    uint64_t sequence;       // Strictly increasing; 0 means no published input yet.
    uint64_t timestamp_ns;   // Host monotonic time, not wall-clock time.
    uint32_t flags, count;
    s2a_host_touch_point points[S2A_TOUCH_MAX_POINTS];
} s2a_host_touch_frame;

// read_touch(host, after_sequence, out): returns the oldest retained frame newer
// than the cursor, without consuming it. Repeating a cursor repeats the frame.
// Success with sequence 0 means no events yet; success with sequence equal to
// the cursor means no new events (held contacts remain held). The consumer must
// advance its cursor only after committing that frame to common HID input.
//
// A cursor older than retained history returns S2A_HOST_E_RANGE, with out set
// to an empty CANCEL frame at the latest sequence. The consumer cancels all
// contacts, advances to that sequence and resumes; it must not synthesize a Tap
// or guess lost transitions. A normal empty frame is a release; CANCEL is not.
// Out->size must hold the v1 frame. Any caller tail remains untouched.
// S2A_HOST_E_UNSUPPORTED means the experiment is disabled: stop touch delivery
// and cancel held HID contacts. Switching arms invalidates retained history;
// callers resume from the last sequence, handling E_RANGE as described above.
