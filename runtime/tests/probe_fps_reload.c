// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Actual loader/fps lifecycle with a user's read-only rewritten modules and
// existing speed table. No guest, services, renderer or substitute provider.
#include "../src/native.h"

void s2a_fps_start(const char *dir);
int s2a_fps_session_reset(void);
extern uint8_t *dm_fps_state;

static int page_clear(const uint8_t *page) {
    for (unsigned i = 0; i < 4096; i++) if (page[i]) return 0;
    return 1;
}
int main(int argc, char **argv) {
    if (argc < 3 || !s2a_window_ok()) {
        fprintf(stderr, "usage: probe_fps_reload <existing module directory> <module names...>\n"); return 2;
    }
    if (getenv("S2A_FPS_TABLE")) {
        fprintf(stderr, "use the existing fps.tsv in the supplied module root, without a table override\n"); return 2;
    }
    load_modules(argv[1], (const char **)&argv[2], argc - 2);
    if (setenv("S2A_FSTEP", "1", 1) || setenv("S2A_FPS60", "1", 1)) return 1;
    s2a_fps_start(argv[1]);
    uint8_t *first = dm_fps_state;
    if (!first) { fprintf(stderr, "real input requires an applicable fps.tsv with a speed row\n"); return 2; }
    uint32_t bits = __atomic_load_n((uint32_t *)first, __ATOMIC_RELAXED); float target;
    memcpy(&target, &bits, sizeof target);
    if (target != 60.0f) { fprintf(stderr, "first session target is not 60\n"); return 1; }
    if (s2a_fps_session_reset()) return 1;
    int bad = dm_fps_state != NULL || !page_clear(first);
    fprintf(stderr, "retired FPS page: detached=%d clear=%d\n", dm_fps_state == NULL, page_clear(first));
    if (setenv("S2A_FSTEP", "0", 1)) return 1;
    s2a_fps_start(argv[1]);
    fprintf(stderr, "next session S2A_FSTEP=0: detached=%d\n", dm_fps_state == NULL);
    bad |= dm_fps_state != NULL;
    if (s2a_fps_session_reset()) return 1;
    if (setenv("S2A_FSTEP", "1", 1)) return 1;
    s2a_fps_start(argv[1]);
    if (dm_fps_state != first) { fprintf(stderr, "third session did not attach the production page\n"); return 1; }
    if (s2a_fps_session_reset()) return 1;
    bad |= dm_fps_state != NULL || !page_clear(first);
    fprintf(stderr, "FPS lifecycle: three starts/resets, mismatches=%d\n", bad);
    return bad != 0;
}
