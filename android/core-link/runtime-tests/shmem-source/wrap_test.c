// 直接链接生产 thread.c / plat_android.c；4 KiB 路径使用真实 Linux 内核页与别名。
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "native.h"
#include "plat.h"
#include <assert.h>
#include <errno.h>
#include <sys/mman.h>

static size_t modeled_page;
size_t __real_plat_page_size(void);
size_t __wrap_plat_page_size(void) {
    return modeled_page ? modeled_page : __real_plat_page_size();
}
void *s2a_shmem_lookup(uint32_t handle, uint64_t *size);

int main(int argc, char **argv) {
    assert(argc == 2);
    assert(__real_plat_page_size() == 0x1000);
    const size_t span = 0x4000, allocation = 0x10000;
    uint8_t *mapping = mmap(NULL, allocation, PROT_READ | PROT_WRITE,
                            MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    assert(mapping != MAP_FAILED);
    uint8_t *aligned = (uint8_t *)(((uintptr_t)mapping + span - 1) & ~(span - 1));
    uint8_t *source = aligned + 0x1000;
    assert(((uintptr_t)source & 0x3fff) == 0x1000);
    assert(!s2a_shmem_wrap(NULL, span));
    assert(!s2a_shmem_wrap(source, 0));
    assert(!s2a_shmem_wrap(source + 1, span));

    if (!strcmp(argv[1], "modeled-16k")) {
        // 只模拟平台页大小准入；不能称为 16 KiB 内核上的别名执行证据。
        modeled_page = span;
        assert(!s2a_shmem_wrap(source, span));
        uint32_t handle = s2a_shmem_wrap(aligned, span);
        uint64_t size = 0;
        assert(handle && s2a_shmem_lookup(handle, &size) == aligned && size == span);
        puts("PASS modeled-16k: invalid page offset rejected; aligned source retained");
    } else {
        assert(!strcmp(argv[1], "real-4k"));
        const size_t alias_size = 0x1000;
        uint32_t handle = s2a_shmem_wrap(source, alias_size);
        uint64_t size = 0;
        assert(handle && s2a_shmem_lookup(handle, &size) == source && size == alias_size);
        uint8_t *target = mmap(NULL, alias_size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        assert(target != MAP_FAILED);
        source[7] = 0x41;
        assert(!plat_vm_alias(target, s2a_shmem_lookup(handle, &size), size,
                              PLAT_PROT_READ | PLAT_PROT_WRITE));
        assert(target[7] == 0x41);
        target[8] = 0x72;
        assert(source[8] == 0x72);
        source[alias_size - 1] = 0x63;
        assert(target[alias_size - 1] == 0x63);
        assert(!munmap(target, alias_size));
        puts("PASS real-4k: non-16k-aligned source wraps and aliases with bidirectional writes");
    }
    assert(!munmap(mapping, allocation));
    return 0;
}
