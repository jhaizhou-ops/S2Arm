#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Executes the synthetic module that tools/device_selftest.sh rewrites with
// S2A_TARGET=android and imports into <dir>: every thread-slot rewrite kind
// (tpidr_el0 read / write, tpidrro_el0 read, x18 write / read, svc gate) is
// called on two threads against real bionic key slots. Writes a one-line
// report; returns 0 when all checks pass, ENOENT when nothing is imported.
int s2a_android_rewrite_selftest(const char *dir, char *report, size_t n);

#ifdef __cplusplus
}
#endif
