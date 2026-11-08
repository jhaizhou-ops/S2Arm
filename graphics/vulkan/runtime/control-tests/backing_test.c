// Native test binding. Local tests use the complete production WSI lease;
// the joint-process boundary shares the production arithmetic under a test lock.
#include "wsi_lease.h"
#include "../../../../android/core-link/runtime-tests/writers-gate/backing_test.h"
static void noop(void *window) { (void)window; }
void *test_create(void) {
    const struct s2a_wsi_window_ops ops = { noop, noop };
    s2a_wsi_lease *l = s2a_wsi_create(1, &ops);
    if (l) s2a_wsi_set_foreground(l, 1);
    return l;
}
void test_destroy(void *p) { s2a_wsi_destroy(p); }
uint64_t test_publish(void *p, uint64_t owner, int advance) { return s2a_wsi_backing_progress(p, 1, owner, advance); }
int test_decision(void *p, uint64_t owner) { return s2a_wsi_backing_decision(p, owner); }
void test_lifecycle(void *p, int fg) { s2a_wsi_set_foreground(p, fg); }
uint64_t test_shared_publish(uint64_t *p, uint64_t o, int a) { return backing_test_publish(p, o, a); }
int test_shared_decision(uint64_t *p, uint64_t o) { return backing_test_decision(p, o); }
void test_shared_lifecycle(uint64_t *p, int f) { backing_test_lifecycle(p, f); }

// Darwin contract tests never call lease condition waits; Linux uses the actual
// monotonic condition clock. This shim is confined to this test translation unit.
#ifdef __APPLE__
#define pthread_condattr_setclock(attr, clock) ((void)(attr), (void)(clock), 0)
#endif
#include "../../../../android/native/wsi_lease.c"
