// nvn_pipe_pend（纯逻辑待定表）宿主单测：钉住 iOS pso_pend_state/take 的语义。
// 先红后绿：负对照把 nvk_pp_enter 的同键合并去掉（-DNVK_PP_NEG_NO_DEDUP）→ 用例 follow 必须变红。
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "nvn_pipe_pend.h"

static int fails;
#define CHECK(c, msg) do { if (!(c)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); fails++; } } while (0)

typedef struct { int id; } key_t;
static int eq(const void *a, const void *b) { return ((const key_t *)a)->id == ((const key_t *)b)->id; }

static void test_basic(void) {
    nvk_pp t; nvk_pp_init(&t, sizeof(key_t));
    key_t k = { 1 }; int h;
    CHECK(nvk_pp_enter(&t, &k, eq, &h) == NVK_PP_ENTER_BUILDER, "first enter is builder");
    CHECK(nvk_pp_state(&t, &k, eq, NULL, NULL, NULL, 0) == NVK_PP_COMPILING, "compiling before publish");
    int c0 = 0;
    nvk_pp_publish(&t, h, (void *)0xABC, 0, NULL);
    void *obj = NULL;
    CHECK(nvk_pp_state(&t, &k, eq, &obj, &c0, NULL, 0) == NVK_PP_READY, "ready after publish");
    CHECK(obj == (void *)0xABC, "state returns obj");
    obj = NULL;
    CHECK(nvk_pp_wait(&t, &k, eq, 0, &obj, &c0, NULL, 0) == NVK_PP_WAIT_READY && obj == (void *)0xABC, "wait ready");
}

static void test_follow(void) {
    nvk_pp t; nvk_pp_init(&t, sizeof(key_t));
    key_t k = { 2 }; int h1, h2;
    CHECK(nvk_pp_enter(&t, &k, eq, &h1) == NVK_PP_ENTER_BUILDER, "builder");
    CHECK(nvk_pp_enter(&t, &k, eq, &h2) == NVK_PP_ENTER_FOLLOW, "second enter follows");
    nvk_pp_publish(&t, h1, (void *)0x1, 0, NULL);
    uint64_t e, f, p, fl, tl, ts, fu, ev;
    nvk_pp_stats(&t, &e, &f, &p, &fl, &tl, &ts, &fu, &ev);
    CHECK(f == 1 && p == 1, "stats followers/published");
}

static void test_fail(void) {
    nvk_pp t; nvk_pp_init(&t, sizeof(key_t));
    key_t k = { 3 }; int h;
    CHECK(nvk_pp_enter(&t, &k, eq, &h) == NVK_PP_ENTER_BUILDER, "builder");
    nvk_pp_publish(&t, h, NULL, -5, "boom");
    int code = 0; char why[64]; void *obj = (void *)0xdead;
    CHECK(nvk_pp_wait(&t, &k, eq, 0, &obj, &code, why, sizeof why) == NVK_PP_WAIT_FAILED, "wait failed");
    CHECK(code == -5 && !strcmp(why, "boom") && obj == NULL, "failed carries code/why and null obj");
}

static void test_bounded_wait(void) {
    nvk_pp t; nvk_pp_init(&t, sizeof(key_t));
    key_t k = { 4 }; int h;
    CHECK(nvk_pp_enter(&t, &k, eq, &h) == NVK_PP_ENTER_BUILDER, "builder");
    uint64_t t0 = (uint64_t)time(NULL);
    void *obj = NULL; int code = 0;
    int r = nvk_pp_wait(&t, &k, eq, 10, &obj, &code, NULL, 0);   // 10ms，未发布 → 超时
    (void)t0;
    CHECK(r == NVK_PP_WAIT_TIMEOUT, "bounded wait times out while compiling");
    nvk_pp_publish(&t, h, (void *)0x77, 0, NULL);
    CHECK(nvk_pp_wait(&t, &k, eq, 0, &obj, &code, NULL, 0) == NVK_PP_WAIT_READY && obj == (void *)0x77, "ready after publish");
}

static void test_marks(void) {
    nvk_pp t; nvk_pp_init(&t, sizeof(key_t));
    key_t k = { 5 }; int h, late = -1, stuck = -1;
    CHECK(nvk_pp_enter(&t, &k, eq, &h) == NVK_PP_ENTER_BUILDER, "builder");
    CHECK(nvk_pp_marks(&t, &k, eq, &late, &stuck) == 1 && late == 0 && stuck == 0, "no marks initially");
    nvk_pp_mark(&t, &k, eq, 0);   // late
    CHECK(nvk_pp_marks(&t, &k, eq, &late, &stuck) == 1 && late == 1 && stuck == 0, "late marked");
    nvk_pp_mark(&t, &k, eq, 1);   // stuck
    CHECK(nvk_pp_marks(&t, &k, eq, &late, &stuck) == 1 && late == 1 && stuck == 1, "stuck marked");
    key_t k2 = { 6 };
    CHECK(nvk_pp_marks(&t, &k2, eq, &late, &stuck) == 0, "absent key: no marks");
}

static void test_full(void) {
    nvk_pp t; nvk_pp_init(&t, sizeof(key_t));
    int got_full = 0;
    for (int i = 0; i < NVK_PP_MAX + 8; i++) {
        key_t k = { 1000 + i }; int h;
        int r = nvk_pp_enter(&t, &k, eq, &h);
        if (r == NVK_PP_ENTER_FULL) { got_full = 1; break; }
    }
    CHECK(got_full, "table full reports FULL (all COMPILING, none evictable)");
}

int main(void) {
    test_basic();
    test_follow();
    test_fail();
    test_bounded_wait();
    test_marks();
    test_full();
    printf("%s (%d failures)\n", fails ? "RED" : "GREEN", fails);
    return fails ? 1 : 0;
}