#pragma once
#include <stdatomic.h>
// Test-only link interposition: observe entry into the real OS condvar wait,
// while the broker mutex is still locked. Cancellation cannot acquire that
// mutex until the OS has atomically registered the waiter and released it.
void s2a_ui_test_observe_wait(atomic_int *entered);
// One-shot timeout scheduling seam: the real OS wait returns ETIMEDOUT first.
// Release/reacquire its mutex around action to model a producer publishing in
// the allowed timeout/relock race. Production sees the real timeout plus the
// state it must recheck under lock; no production predicate is copied here.
void s2a_ui_test_timeout_action(void (*action)(void *), void *context);
