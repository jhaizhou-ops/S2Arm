#pragma once
#include <stddef.h>
static inline void *getsectiondata(const void *h, const char *s, const char *n, unsigned long *z) {
    (void)h; (void)s; (void)n; if (z) *z = 0; return 0;
}
