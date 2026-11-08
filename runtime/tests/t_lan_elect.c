// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "s2a_lan_elect.h"
#include <stdio.h>
#define P "0100000000000001-"
static int expect(const char *label, const char *const *names, int count,
                  int wanted)
{
    const int actual = s2a_lan_elect(P, names, count);
    if (actual != wanted) {
        fprintf(stderr, "FAIL %s: expected index %d, got %d\n",
                label, wanted, actual);
        return 1;
    }
    return 0;
}
static int expect_self(const char *name, int wanted)
{
    const int actual = s2a_lan_is_self(P, "12345678", name);
    if (actual != wanted) {
        fprintf(stderr, "FAIL self %s: expected %d, got %d\n",
                name ? name : "(null)", wanted, actual);
        return 1;
    }
    return 0;
}
int main(void)
{
    int failed = 0;
    failed |= expect("empty", NULL, 0, -1);
    /* 1. The caller includes this device in the discovered snapshot. */
    const char *self[] = {P "10000000"};
    failed |= expect("self-only", self, 1, 0);
    const char *self_tie[] = {P "30000000", P "10000000"};
    failed |= expect("self-in-list", self_tie, 2, 1);
    /* 2. No rooms: the smallest full published name wins. */
    const char *ordinary[] = {P "30000000", P "10000000", P "20000000"};
    failed |= expect("ordinary-order", ordinary, 3, 1);
    /* 3. The '!' before the device ID sorts before ordinary device IDs. */
    const char *hosting[] = {P "!ffffffff", P "00000000"};
    failed |= expect("hosting-before-ordinary", hosting, 2, 0);
    /* 4. Several rooms, including our own. */
    const char *rooms[] = {P "!30000000", P "!10000000", P "00000000"};
    failed |= expect("multiple-rooms", rooms, 3, 1);
    /* 5. Reordering changes the index, not the selected instance. */
    const char *reordered[] = {P "20000000", P "30000000", P "10000000"};
    failed |= expect("reordered-input", reordered, 3, 2);
    /* 6. Same program/device identity, with and without the room marker. */
    const char *same_device[] = {P "12345678", P "!12345678"};
    failed |= expect("same-device-room-marker", same_device, 2, 1);
    const char *duplicates[] = {P "10000000", P "10000000", P "20000000"};
    failed |= expect("duplicate-remote", duplicates, 3, 0);
    const char *mixed[] = {"0000000000000000-!A", NULL, "", P "Z", P "A"};
    failed |= expect("filter-keeps-original-index", mixed, 5, 4);
    const char *no_match[] = {"01000000000000010-!A", "010", NULL, ""};
    failed |= expect("no-matching-prefix", no_match, 4, -1);
    const char *case_names[] = {P "a", P "Z", P "A"};
    failed |= expect("bytewise-case", case_names, 3, 2);
    failed |= expect("bounded-count", ordinary, 1, 0);
    failed |= expect("negative-count", ordinary, -1, -1);
    failed |= expect("null-array", NULL, 1, -1);
    failed |= expect("zero-count", ordinary, 0, -1);
    if (s2a_lan_elect(NULL, ordinary, 3) != -1 ||
        s2a_lan_elect("", ordinary, 3) != -1) {
        fputs("FAIL invalid-prefix\n", stderr);
        failed = 1;
    }
    failed |= expect_self(P "12345678", 1);
    failed |= expect_self(P "!12345678", 1);
    failed |= expect_self(P "!!12345678", 0);
    failed |= expect_self(P "123456789", 0);
    failed |= expect_self(P "1234567", 0);
    failed |= expect_self("01000000000000010-12345678", 0);
    failed |= expect_self("010", 0);
    failed |= expect_self(P, 0);
    failed |= expect_self(P "!", 0);
    failed |= expect_self("", 0);
    failed |= expect_self(NULL, 0);
    if (s2a_lan_is_self(NULL, "A", P "A") ||
        s2a_lan_is_self("", "A", "A") ||
        s2a_lan_is_self(P, NULL, P "A") ||
        s2a_lan_is_self(P, "", P) ||
        s2a_lan_is_self(P, "A", P "a")) {
        fputs("FAIL self-boundaries\n", stderr);
        failed = 1;
    }
    if (failed) return 1;
    puts("✓ t_lan_elect: six original groups, prefix filtering, identity, boundaries");
    return 0;
}
