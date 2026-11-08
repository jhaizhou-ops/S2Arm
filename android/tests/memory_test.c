#include "memory.h"
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #expr); return 1; } } while (0)
int main(void) {
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    void *window = (void *)1;
    CHECK(s2a_android_reserve(page, page + 1, 1ull << 39, &window) == EINVAL && !window);
    CHECK(s2a_android_reserve(SIZE_MAX, page, UINT64_MAX, &window) == EINVAL);
    CHECK(s2a_android_reserve(page, page, page - 1, &window) == EINVAL);
    CHECK(s2a_android_reserve(page, page, 1ull << 39, NULL) == EINVAL);
    CHECK(s2a_android_reserve(64ull << 30, 1ull << 30, 1ull << 39, &window) == 0);
    CHECK(window && !((uintptr_t)window % (1ull << 30)));
    CHECK((uintptr_t)window + (64ull << 30) <= (1ull << 39));
    // Only commit one real page in a 64 GiB reservation, then release all of it.
    CHECK(mprotect(window, page, PROT_READ | PROT_WRITE) == 0);
    *(volatile uint8_t *)window = 0x7A;
    CHECK(*(volatile uint8_t *)window == 0x7A);
    CHECK(munmap(window, 64ull << 30) == 0);
    char filename[] = "/tmp/s2arm-memory-XXXXXX";
    int fd = mkstemp(filename); CHECK(fd >= 0); unlink(filename);
    size_t large_page = page > 16384 ? page : 16384;
    CHECK(ftruncate(fd, (off_t)large_page) == 0);
    CHECK(pwrite(fd, "A", 1, 0) == 1);
    CHECK(s2a_android_check_alias(fd, page) == 0);
    CHECK(s2a_android_check_alias(fd, large_page) == 0);
    char original = 0; CHECK(pread(fd, &original, 1, 0) == 1 && original == 'A');
    close(fd);
    CHECK(s2a_android_check_alias(-1, page) == EBADF);
    CHECK(s2a_android_check_alias(-1, page - 1) == EINVAL);
    puts("Android memory: aligned 39-bit reservation, commit, real alias coherence, cleanup, invalid inputs passed");
    return 0;
}

