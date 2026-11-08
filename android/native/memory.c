#include "memory.h"
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>

int s2a_android_reserve(size_t size, size_t alignment, uint64_t limit, void **out) {
    if (!out) return EINVAL;
    *out = NULL;
    long pg = sysconf(_SC_PAGESIZE);
    if (pg <= 0 || !size || alignment < (size_t)pg || (alignment & (alignment - 1))
        || size % (size_t)pg || size > SIZE_MAX - alignment || size > limit) return EINVAL;
    size_t total = size + alignment;
    int error = ENOMEM;
    // Non-fixed hints allow finding a 39-bit window on 48-bit Android processes.
    // A plain mmap(NULL) can land above Horizon's IPC address range.
    for (unsigned i = 1; i <= 7; i++) {
        uint64_t hint = (limit / 8) * i;
        if (hint > UINTPTR_MAX || hint > limit - size) break;
        void *raw = mmap((void *)(uintptr_t)hint, total, PROT_NONE,
                        MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
        if (raw == MAP_FAILED) { error = errno; continue; }
        uintptr_t start = (uintptr_t)raw;
        uintptr_t aligned = (start + alignment - 1) & ~(uintptr_t)(alignment - 1);
        if (aligned < start || aligned > limit - size) {
            munmap(raw, total); continue;
        }
        size_t prefix = aligned - start, suffix = total - prefix - size;
        if (prefix && munmap(raw, prefix)) { error = errno; munmap(raw, total); return error; }
        if (suffix && munmap((void *)(aligned + size), suffix)) {
            error = errno; munmap((void *)aligned, total - prefix); return error;
        }
        *out = (void *)aligned;
        return 0;
    }
    return error;
}

int s2a_android_check_alias(int fd, size_t size) {
    long pg = sysconf(_SC_PAGESIZE);
    if (pg <= 0 || size < (size_t)pg || size % (size_t)pg) return EINVAL;
    uint8_t *first = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (first == MAP_FAILED) return errno;
    // Linux's old_size=0 aliasing requires shared backing (PR #1).
    uint8_t *second = mremap(first, 0, size, MREMAP_MAYMOVE);
    if (second == MAP_FAILED) { int error = errno; munmap(first, size); return error; }
    volatile uint8_t *a = first, *b = second;
    uint8_t saved_first = a[0], saved_last = a[size - 1];
    a[0] = 0x35; b[size - 1] = 0xCA;
    int error = b[0] == 0x35 && a[size - 1] == 0xCA ? 0 : EIO;
    a[0] = saved_first; a[size - 1] = saved_last;
    munmap(second, size); munmap(first, size);
    return error;
}

