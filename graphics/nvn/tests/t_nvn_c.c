// 通过生产 bootstrap / swnvn 注册节 / 计数跳板验证 Device 模式查询；不提交 GPU。
#include "nvn_protos.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
static const char *query, *phase;
static unsigned checks;
#define CHECK(expr) do { checks++; if (!(expr)) { \
    fprintf(stderr, "FAIL %s [%s] %s:%d：%s\n", query, phase, __FILE__, __LINE__, #expr); exit(1); \
} } while (0)
static void *load(const char *name) {
    void *entry = h_nvnBootstrapLoader(name); CHECK(entry != NULL); return entry;
}
#define API(name) ((NVNT_##name)load(#name))
#define GUARD UINT64_C(0xc53a709df28b146e)
typedef struct { uint64_t pre[2]; NVNdevice object; uint64_t post[2]; } guarded_device;
static void boundary(const guarded_device *box) {
    CHECK(box->pre[0] == GUARD && box->pre[1] == GUARD);
    CHECK(box->post[0] == GUARD && box->post[1] == GUARD);
}
static void read_query(const guarded_device *box, NVNwindowOriginMode origin, NVNdepthMode depth) {
    NVNdevice before = box->object;
    if (!strcmp(query, "nvnDeviceGetWindowOriginMode")) CHECK(API(nvnDeviceGetWindowOriginMode)(&box->object) == origin);
    else CHECK(API(nvnDeviceGetDepthMode)(&box->object) == depth);
    CHECK(memcmp(&before, &box->object, sizeof before) == 0);
    boundary(box);
}
static void exercise(const char *name) {
    query = name; phase = "初始化缺省值";
    guarded_device a = { {GUARD, GUARD}, {{0}}, {GUARD, GUARD} };
    guarded_device b = { {GUARD, GUARD}, {{0}}, {GUARD, GUARD} };
    // 初始化必须写出真实默认状态，不能依赖调用者先清零 opaque 对象。
    memset(&a.object, 0xa5, sizeof a.object); memset(&b.object, 0xa5, sizeof b.object);
    NVNdeviceBuilder builder = {{0}};
    API(nvnDeviceBuilderSetDefaults)(&builder);
    CHECK(API(nvnDeviceInitialize)(&a.object, &builder));
    CHECK(API(nvnDeviceInitialize)(&b.object, &builder));
    read_query(&a, NVN_WINDOW_ORIGIN_MODE_LOWER_LEFT, NVN_DEPTH_MODE_NEAR_IS_MINUS_W);
    read_query(&b, NVN_WINDOW_ORIGIN_MODE_LOWER_LEFT, NVN_DEPTH_MODE_NEAR_IS_MINUS_W);

    phase = "两个合法模式、独立字段与多 Device 交错";
    API(nvnDeviceSetWindowOriginMode)(&a.object, NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT);
    read_query(&a, NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT, NVN_DEPTH_MODE_NEAR_IS_MINUS_W);
    read_query(&b, NVN_WINDOW_ORIGIN_MODE_LOWER_LEFT, NVN_DEPTH_MODE_NEAR_IS_MINUS_W);
    API(nvnDeviceSetDepthMode)(&b.object, NVN_DEPTH_MODE_NEAR_IS_ZERO);
    read_query(&a, NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT, NVN_DEPTH_MODE_NEAR_IS_MINUS_W);
    read_query(&b, NVN_WINDOW_ORIGIN_MODE_LOWER_LEFT, NVN_DEPTH_MODE_NEAR_IS_ZERO);
    API(nvnDeviceSetDepthMode)(&a.object, NVN_DEPTH_MODE_NEAR_IS_ZERO);
    read_query(&a, NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT, NVN_DEPTH_MODE_NEAR_IS_ZERO);
    API(nvnDeviceSetWindowOriginMode)(&b.object, NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT);
    read_query(&b, NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT, NVN_DEPTH_MODE_NEAR_IS_ZERO);
    API(nvnDeviceSetWindowOriginMode)(&a.object, NVN_WINDOW_ORIGIN_MODE_LOWER_LEFT);
    read_query(&a, NVN_WINDOW_ORIGIN_MODE_LOWER_LEFT, NVN_DEPTH_MODE_NEAR_IS_ZERO);
    read_query(&b, NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT, NVN_DEPTH_MODE_NEAR_IS_ZERO);
    API(nvnDeviceSetDepthMode)(&b.object, NVN_DEPTH_MODE_NEAR_IS_MINUS_W);
    read_query(&a, NVN_WINDOW_ORIGIN_MODE_LOWER_LEFT, NVN_DEPTH_MODE_NEAR_IS_ZERO);
    read_query(&b, NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT, NVN_DEPTH_MODE_NEAR_IS_MINUS_W);
    API(nvnDeviceSetDepthMode)(&a.object, NVN_DEPTH_MODE_NEAR_IS_MINUS_W);
    read_query(&a, NVN_WINDOW_ORIGIN_MODE_LOWER_LEFT, NVN_DEPTH_MODE_NEAR_IS_MINUS_W);
    read_query(&b, NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT, NVN_DEPTH_MODE_NEAR_IS_MINUS_W);
    API(nvnDeviceSetWindowOriginMode)(&b.object, NVN_WINDOW_ORIGIN_MODE_LOWER_LEFT);
    read_query(&a, NVN_WINDOW_ORIGIN_MODE_LOWER_LEFT, NVN_DEPTH_MODE_NEAR_IS_MINUS_W);
    read_query(&b, NVN_WINDOW_ORIGIN_MODE_LOWER_LEFT, NVN_DEPTH_MODE_NEAR_IS_MINUS_W);

    phase = "Finalize 再 Initialize 恢复缺省且不改另一 Device";
    API(nvnDeviceSetWindowOriginMode)(&a.object, NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT);
    API(nvnDeviceSetDepthMode)(&a.object, NVN_DEPTH_MODE_NEAR_IS_ZERO);
    API(nvnDeviceSetWindowOriginMode)(&b.object, NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT);
    read_query(&a, NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT, NVN_DEPTH_MODE_NEAR_IS_ZERO);
    API(nvnDeviceFinalize)(&a.object); boundary(&a);
    CHECK(API(nvnDeviceInitialize)(&a.object, &builder));
    read_query(&a, NVN_WINDOW_ORIGIN_MODE_LOWER_LEFT, NVN_DEPTH_MODE_NEAR_IS_MINUS_W);
    read_query(&b, NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT, NVN_DEPTH_MODE_NEAR_IS_MINUS_W);
    API(nvnDeviceFinalize)(&a.object); API(nvnDeviceFinalize)(&b.object);
    boundary(&a); boundary(&b);
    printf("%s：通过\n", query);
}
int main(int argc, char **argv) {
    const char *names[] = { "nvnDeviceGetWindowOriginMode", "nvnDeviceGetDepthMode" };
    if (argc > 2 || (argc == 2 && strcmp(argv[1], names[0]) && strcmp(argv[1], names[1]))) {
        fprintf(stderr, "用法：%s [完整查询函数名]\n", argv[0]); return 2;
    }
    for (unsigned i = 0; i < 2; i++) if (argc == 1 || !strcmp(argv[1], names[i])) exercise(names[i]);
    printf("✓ t_nvn_c：%u 条真实 API / 对象边界与只读断言\n", checks);
    return 0;
}
