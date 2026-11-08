// 完整生产 bootstrap / 注册表 / 跳板；Event 与 MemoryPool 均真实初始化。
#include "nvn_protos.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern void *h_nvnBootstrapLoader(const char *name);
static unsigned checks;
static const char *phase = "准备", *filter;
#define CHECK(expr) do { checks++; if (!(expr)) { \
    fprintf(stderr, "FAIL [%s] %s:%d：%s\n", phase, __FILE__, __LINE__, #expr); exit(1); \
} } while (0)
static void *load(const char *name) {
    void *entry = h_nvnBootstrapLoader(name); CHECK(entry != NULL); return entry;
}
#define API(name) ((NVNT_##name)load(#name))
#define GUARD UINT64_C(0x9c7a4d1e3268b5f0)
typedef struct { uint64_t pre; NVNevent event; uint64_t post; } event_box;
typedef struct { NVNmemoryPool pool; void *bytes; size_t size; } memory;

static void make_pool(memory *m, NVNdevice *device) {
    size_t page = (size_t)getpagesize(); m->size = page * 2;
    CHECK(posix_memalign(&m->bytes, page, m->size) == 0);
    memset(m->bytes, 0, m->size);
    NVNmemoryPoolBuilder builder = {{0}};
    API(nvnMemoryPoolBuilderSetDefaults)(&builder);
    API(nvnMemoryPoolBuilderSetDevice)(&builder, device);
    API(nvnMemoryPoolBuilderSetFlags)(&builder, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    API(nvnMemoryPoolBuilderSetStorage)(&builder, m->bytes, m->size);
    CHECK(API(nvnMemoryPoolInitialize)(&m->pool, &builder));
    CHECK(API(nvnMemoryPoolMap)(&m->pool) == m->bytes);
}
static void check_event(event_box *box, memory *m, int64_t offset, uint32_t value) {
    if (!filter || !strcmp(filter, "nvnEventGetMemoryPool"))
        CHECK(API(nvnEventGetMemoryPool)(&box->event) == &m->pool);
    if (!filter || !strcmp(filter, "nvnEventGetMemoryOffset"))
        CHECK(API(nvnEventGetMemoryOffset)(&box->event) == offset);
    API(nvnEventSignal)(&box->event, NVN_EVENT_SIGNAL_MODE_WRITE, value);
    CHECK(API(nvnEventGetValue)(&box->event) == value);
    uint32_t stored; memcpy(&stored, (unsigned char *)m->bytes + offset, sizeof stored);
    CHECK(stored == value);
    API(nvnEventSignal)(&box->event, NVN_EVENT_SIGNAL_MODE_ADD, 3);
    CHECK(API(nvnEventGetValue)(&box->event) == value + 3);
    CHECK(box->pre == GUARD && box->post == GUARD);
}
int main(int argc, char **argv) {
    if (argc > 2 || (argc == 2 && strcmp(argv[1], "nvnEventGetMemoryPool") && strcmp(argv[1], "nvnEventGetMemoryOffset"))) {
        fprintf(stderr, "用法：%s [nvnEventGetMemoryPool|nvnEventGetMemoryOffset]\n", argv[0]); return 2;
    }
    filter = argc == 2 ? argv[1] : NULL;
    NVNdevice device = {{0}}; NVNdeviceBuilder device_builder = {{0}};
    API(nvnDeviceBuilderSetDefaults)(&device_builder);
    CHECK(API(nvnDeviceInitialize)(&device, &device_builder));
    memory a = {0}, b = {0}; make_pool(&a, &device); make_pool(&b, &device);
    event_box first = {GUARD, {{0}}, GUARD}, second = {GUARD, {{0}}, GUARD};
    NVNeventBuilder builder = {{0}};
    API(nvnEventBuilderSetDefaults)(&builder);
    API(nvnEventBuilderSetStorage)(&builder, &a.pool, 0);
    CHECK(API(nvnEventInitialize)(&first.event, &builder));
    phase = "零偏移"; check_event(&first, &a, 0, 17);

    int64_t a_offset = getpagesize(), b_offset = b.size - 64;
    API(nvnEventFinalize)(&first.event);
    API(nvnEventBuilderSetStorage)(&builder, &a.pool, a_offset);
    CHECK(API(nvnEventInitialize)(&first.event, &builder));
    API(nvnEventBuilderSetStorage)(&builder, &b.pool, b_offset);
    CHECK(API(nvnEventInitialize)(&second.event, &builder));
    API(nvnEventBuilderSetDefaults)(&builder);
    phase = "两池快照与 Builder 复位";
    check_event(&first, &a, a_offset, 29);
    check_event(&second, &b, b_offset, 41);
    CHECK(API(nvnEventGetValue)(&first.event) == 32);

    API(nvnEventFinalize)(&first.event);
    API(nvnEventBuilderSetStorage)(&builder, &b.pool, 64);
    CHECK(API(nvnEventInitialize)(&first.event, &builder));
    phase = "重新初始化和同池不同偏移";
    check_event(&first, &b, 64, 53);
    check_event(&second, &b, b_offset, 67);
    CHECK(API(nvnEventGetValue)(&first.event) == 56);
    API(nvnEventFinalize)(&second.event); API(nvnEventFinalize)(&first.event);
    CHECK(first.pre == GUARD && first.post == GUARD && second.pre == GUARD && second.post == GUARD);
    API(nvnMemoryPoolFinalize)(&b.pool); API(nvnMemoryPoolFinalize)(&a.pool);
    free(b.bytes); free(a.bytes); API(nvnDeviceFinalize)(&device);
    printf("✓ t_nvn_event：%u 个真实 API / 存储断言\n", checks);
    return 0;
}
