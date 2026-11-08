// 原生 Linux VM + 生产 registry：CPU-only alias 与 GPU 两向原子准入。
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "../runtime.h"
#include "../../../../../platform/plat.h"
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

static unsigned checks, failures;
#define CHECK(label, condition) do { ++checks; if (!(condition)) { ++failures; fprintf(stderr, "FAIL %s line %d\n", label, __LINE__); } } while (0)
static size_t page;
int s2a_track_test_pagesize(void) { return (int)page; }

static int alias(void *destination, void *source, size_t size) {
    int error = s2a_track_backing_begin((uintptr_t)destination, size, (uintptr_t)source);
    if (error) return error;
    error = plat_vm_alias(destination, source, size, PLAT_PROT_READ | PLAT_PROT_WRITE);
    s2a_track_backing_end((uintptr_t)destination, size, !error, !error);
    return error;
}
static int remove_mapping(void *address, size_t size) {
    int error = s2a_track_backing_begin((uintptr_t)address, size, 0);
    if (error) return error;
    void *mapped = mmap(address, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (mapped == MAP_FAILED) abort();
    s2a_track_backing_end((uintptr_t)address, size, 0, 1);
    return 0;
}
typedef struct { pthread_barrier_t barrier; uint8_t *source, *destination; int gpu_result, vm_result; } race;
static void *reserve_race(void *opaque) {
    race *r = opaque;
    pthread_barrier_wait(&r->barrier);
    r->gpu_result = s2a_track_gpu_reserve((uintptr_t)r->source, page);
    return NULL;
}
static void *alias_race(void *opaque) {
    race *r = opaque;
    pthread_barrier_wait(&r->barrier);
    r->vm_result = alias(r->destination, r->source, page);
    return NULL;
}
int main(void) {
    page = (size_t)sysconf(_SC_PAGESIZE);
    int fd = memfd_create("s2a-registry-test", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, (off_t)(page * 64))) return 2;
    uint8_t *memory = mmap(NULL, page * 64, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (memory == MAP_FAILED || s2a_track_runtime_prepare()) return 2;
    uint8_t *a = memory, *b = memory + page, *c = memory + page * 2;
    a[0] = 0x35;
    CHECK("CPU-only alias实际建立", !alias(b, a, page) && b[0] == 0x35);
    b[1] = 0x42;
    CHECK("CPU-only双向共享", a[1] == 0x42);
    CHECK("已有alias源GPU拒绝", s2a_track_gpu_reserve((uintptr_t)a, page) == EOPNOTSUPP);
    CHECK("已有alias目标GPU拒绝", s2a_track_gpu_reserve((uintptr_t)b, page) == EOPNOTSUPP);
    CHECK("链式alias实际建立", !alias(c, b, page) && c[1] == 0x42);
    CHECK("删除中介映射", !remove_mapping(b, page));
    CHECK("中介删除源仍拒绝GPU", s2a_track_gpu_reserve((uintptr_t)a, page) == EOPNOTSUPP);
    CHECK("中介删除末端仍拒绝GPU", s2a_track_gpu_reserve((uintptr_t)c, page) == EOPNOTSUPP);
    CHECK("失败unmap事务开始", !s2a_track_backing_begin((uintptr_t)c, page, 0));
    CHECK("失败unmap真实保留映射", munmap(c + 1, page) == -1 && errno == EINVAL && c[1] == 0x42);
    s2a_track_backing_end((uintptr_t)c, page, 1, 0);
    CHECK("回滚保留alias登记", s2a_track_gpu_reserve((uintptr_t)c, page) == EOPNOTSUPP);
    CHECK("删除最后别名", !remove_mapping(c, page));
    CHECK("仅剩单映射可以GPU跟踪", !s2a_track_gpu_reserve((uintptr_t)a, page));
    CHECK("GPU先登记后建alias拒绝", alias(b, a, page) == EOPNOTSUPP);
    CHECK("GPU拒绝前没改页", a[1] == 0x42);

    uint8_t *source = memory + page * 12, *destination = memory + page * 16;
    CHECK("多页alias建立", !alias(destination, source, page * 4));
    CHECK("中段alias解除", !remove_mapping(destination + page, page * 2));
    CHECK("左段alias仍拒绝", s2a_track_gpu_reserve((uintptr_t)source, page) == EOPNOTSUPP);
    CHECK("右段alias仍拒绝", s2a_track_gpu_reserve((uintptr_t)(source + page * 3), page) == EOPNOTSUPP);
    CHECK("中段已无alias可以GPU", !s2a_track_gpu_reserve((uintptr_t)(source + page), page * 2));
    CHECK("跨已GPU子范围的alias拒绝", alias(memory + page * 20, source, page * 4) == EOPNOTSUPP);
    CHECK("GPU目标先登记", !s2a_track_gpu_reserve((uintptr_t)(memory + page * 24), page));
    CHECK("GPU目标建立alias拒绝", alias(memory + page * 24, memory + page * 25, page) == EOPNOTSUPP);

    uint8_t *failed_source = memory + page * 26, *failed_destination = memory + page * 27;
    CHECK("失败map事务开始", !s2a_track_backing_begin((uintptr_t)failed_destination, page, (uintptr_t)failed_source));
    CHECK("在途source GPU拒绝", s2a_track_gpu_reserve((uintptr_t)failed_source, page) == EBUSY);
    CHECK("在途destination GPU拒绝", s2a_track_gpu_reserve((uintptr_t)failed_destination, page) == EBUSY);
    CHECK("不相邻GPU范围不受阻", !s2a_track_gpu_reserve((uintptr_t)(memory + page * 28), page));
    CHECK("内核拒绝无效map", mmap(failed_destination, page, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, -1) == MAP_FAILED);
    s2a_track_backing_end((uintptr_t)failed_destination, page, 1, 0);
    CHECK("失败map未伪登记source alias", !s2a_track_gpu_reserve((uintptr_t)failed_source, page));
    CHECK("失败map未伪登记destination alias", !s2a_track_gpu_reserve((uintptr_t)failed_destination, page));

    for (unsigned i = 0; i < 12; i++) {
        race r = {.source = memory + page * (32 + i * 2), .destination = memory + page * (33 + i * 2)};
        pthread_t gpu_thread, vm_thread;
        if (pthread_barrier_init(&r.barrier, NULL, 2) || pthread_create(&gpu_thread, NULL, reserve_race, &r)
            || pthread_create(&vm_thread, NULL, alias_race, &r)) return 2;
        pthread_join(gpu_thread, NULL); pthread_join(vm_thread, NULL); pthread_barrier_destroy(&r.barrier);
        CHECK("并发GPU与alias至多一个成功", (!r.gpu_result) != (!r.vm_result));
        CHECK("并发失败明确能力或在途拒绝", r.gpu_result == EOPNOTSUPP || r.gpu_result == EBUSY || r.vm_result == EOPNOTSUPP);
    }
    CHECK("GPU拒绝溢出范围", s2a_track_gpu_reserve(UINT64_MAX - page + 1, page) == EINVAL);
    CHECK("GPU拒绝空范围", s2a_track_gpu_reserve((uintptr_t)memory, 0) == EINVAL);
    munmap(memory, page * 64); close(fd);
    printf("%s Linux alias registry: %u checks, %u failures\n", failures ? "FAIL" : "PASS", checks, failures);
    return failures != 0;
}
