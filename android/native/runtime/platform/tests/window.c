#include "native.h"
#include "platform/plat.h"
#include <errno.h>
#include <sys/mman.h>
#include <sys/resource.h>

static unsigned checked;
#define CHECK(e) do { checked++; if (!(e)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #e); return 1; } } while (0)

// 真内核负控：在生产构造函数之前缩小 RLIMIT_AS，让窗口预留真正失败。
__attribute__((constructor(100))) static void limit_address_space(void) {
    if (getenv("S2A_TEST_LIMIT_VA")) {
        struct rlimit lim = {1ull << 30, 1ull << 30};
        if (setrlimit(RLIMIT_AS, &lim)) _exit(90);
    }
}

int main(int argc, char **argv) {
    uint64_t b, n;
    s2a_window_get(&b, &n);
    if (getenv("S2A_TEST_LIMIT_VA") || getenv("S2A_VAWIN_NORESERVE")) {
        CHECK(!s2a_window_ok()); CHECK(b == 0 && n == 0);
        printf("window unavailable %u checks\n", checked); return 0;
    }
    CHECK(s2a_window_ok()); CHECK(n == S2A_WIN_SIZE);
    CHECK(b != 0 && !(b & ((1ull << 30) - 1)));
    CHECK(b + n <= 1ull << 39);
    void *hint = (void *)(uintptr_t)(b + n / 2);
    void *other = mmap(hint, 1 << 20, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(other != MAP_FAILED);
    CHECK((uint64_t)(uintptr_t)other < b || (uint64_t)(uintptr_t)other >= b + n);
    CHECK(munmap(other, 1 << 20) == 0);
    s2a_window_probe("test owner held");
    if (argc > 1 && !strcmp(argv[1], "trim-zero")) { s2a_window_trim(0); return 91; }
    if (argc > 1 && !strcmp(argv[1], "trim-unaligned")) { s2a_window_trim(n - 1); return 92; }
    uint64_t resident0, resident1, swapped;
    s2a_window_resident(&resident0, &swapped);
    CHECK(resident0 == 0 && swapped == 0);
    unsigned char *page = (void *)(uintptr_t)(b + (1ull << 30));
    CHECK(plat_vm_protect(page, 8u << 20, PLAT_PROT_READ | PLAT_PROT_WRITE) == 0);
    memset(page, 0x56, 4u << 20);
    s2a_window_resident(&resident1, &swapped);
    CHECK(resident1 >= resident0 + (4u << 20));
    CHECK(resident1 <= resident0 + (4u << 20) + plat_page_size());
    uint64_t holes0, largest0, holes1, largest1;
    s2a_low_holes(&holes0, &largest0);
    s2a_window_trim(n - (1ull << 30));
    s2a_window_get(&b, &n);
    CHECK(n == S2A_WIN_SIZE - (1ull << 30));
    s2a_low_holes(&holes1, &largest1);
    CHECK(holes1 - holes0 == 1ull << 30);
    CHECK(largest1 >= 1ull << 30);
    void *tail = mmap((void *)(uintptr_t)(b + n), 1u << 20, PROT_NONE,
        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(tail == (void *)(uintptr_t)(b + n));
    CHECK(munmap(tail, 1u << 20) == 0);
    s2a_window_probe("test trimmed owner");
    printf("window held %u checks\n", checked);
    return 0;
}
