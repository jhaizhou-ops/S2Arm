// Standalone loader boundary for tests that intentionally do not link loader.c.
#include "../../src/native.h"
#include <sys/mman.h>
int s2a_key_page_writable(module_t *m) {
    return mprotect(m->base + m->key_page_off, m->key_page_size, PROT_READ | PROT_WRITE);
}
