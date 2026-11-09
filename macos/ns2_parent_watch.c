// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "ns2_parent_watch.h"
#include <sys/event.h>
#include <unistd.h>

int s2a_ns2_wait_for_parent_exit(pid_t parent) {
    int queue = kqueue();
    if (queue < 0) return 0;
    struct kevent change;
    EV_SET(&change, (uintptr_t)parent, EVFILT_PROC, EV_ADD | EV_ENABLE, NOTE_EXIT, 0, NULL);
    int watched = kevent(queue, &change, 1, NULL, 0, NULL) == 0;
    if (watched) {
        struct kevent event;
        watched = kevent(queue, NULL, 0, &event, 1, NULL) == 1;
    }
    close(queue);
    return watched;
}
