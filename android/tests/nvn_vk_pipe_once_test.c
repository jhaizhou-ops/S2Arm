// nvk_pipe_once_adopt 的宿主单测：假创建 + 假表，两个（多个）线程并发建同一配方。
// 期望：每个线程都建了自己那份（创建计数 = 线程数），但装进表的只有一份，其余 N-1 份由 destroy 真销毁，
// 每个线程拿到的是同一个对象；负对照（去掉 adopt 里的 find）必须看到两份同配方对象。
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nvn_vk_pipe_once.h"

#define NTHREAD 4
#define NTAB 8

struct obj { unsigned char key[8]; uint64_t handle; int destroyed; };
static struct obj *g_tab[NTAB];
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_creates, g_links, g_destroys;

static void *fake_find(void *ctx, const void *key, size_t key_bytes) {
    (void)ctx;
    for (int i = 0; i < NTAB; i++)
        if (g_tab[i] && memcmp(g_tab[i]->key, key, key_bytes) == 0) return g_tab[i];
    return NULL;
}
static void fake_link(void *ctx, void *fresh) {
    (void)ctx;
    struct obj *o = fresh;
    for (int i = 0; i < NTAB; i++) if (!g_tab[i]) { g_tab[i] = o; g_links++; return; }
    abort();   // 用例自己的表满：实现不该这样用
}
static void fake_destroy(void *ctx, void *fresh) {
    (void)ctx;
    struct obj *o = fresh;
    o->destroyed = 1;
    g_destroys++;
}
// 假创建：每次调用都真的新建一份（模拟「两个线程各自建了一条同配方管线」）
static struct obj *fake_create(const unsigned char key[8]) {
    struct obj *o = calloc(1, sizeof *o);
    if (!o) abort();
    memcpy(o->key, key, 8);
    o->handle = (uint64_t)(uintptr_t)o;
    __atomic_fetch_add(&g_creates, 1, __ATOMIC_RELAXED);
    return o;
}

struct arg { const unsigned char *key; void *got; };
static void *worker(void *p) {
    struct arg *a = p;
    struct obj *fresh = fake_create(a->key);   // 建在锁外：与后端一致（pipe_build 在 g_create_mu 下，不持 g_mu）
    nvk_pipe_once_ops ops = { NULL, fake_find, fake_link, fake_destroy };
    void *out = NULL;
    pthread_mutex_lock(&g_mu);
    int r = nvk_pipe_once_adopt(&ops, a->key, 8, fresh, &out);
    pthread_mutex_unlock(&g_mu);
    if (r < 0) { free(fresh); out = NULL; }
    a->got = out;
    return NULL;
}

static int g_fail;
#define CHECK(c, ...) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); g_fail = 1; } } while (0)

int main(void) {
    // 1) 顺序：第一次装进去，第二次拿到同一份并被销毁
    unsigned char k1[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    nvk_pipe_once_ops ops = { NULL, fake_find, fake_link, fake_destroy };
    void *a = NULL, *b = NULL;
    struct obj *fa = fake_create(k1), *fb = fake_create(k1);
    CHECK(nvk_pipe_once_adopt(&ops, k1, 8, fa, &a) == 0, "first adopt must install the fresh object");
    CHECK(nvk_pipe_once_adopt(&ops, k1, 8, fb, &b) == 1, "second adopt of the same recipe must reuse");
    CHECK(a == b && a == (void *)fa, "both adopters must get the same object");
    CHECK(fb->destroyed == 1 && g_destroys == 1, "the duplicate fresh object must be destroyed (destroyed=%d)", fb->destroyed);
    free(fb);
    // 2) 并发：N 个线程各建一份同配方，只有一份进表
    unsigned char k2[8] = {9, 9, 9, 9, 9, 9, 9, 9};
    pthread_t th[NTHREAD];
    struct arg args[NTHREAD];
    memset(g_tab, 0, sizeof g_tab);
    g_links = g_destroys = 0;
    int before_creates = g_creates;
    for (int i = 0; i < NTHREAD; i++) { args[i].key = k2; args[i].got = NULL; pthread_create(&th[i], NULL, worker, &args[i]); }
    for (int i = 0; i < NTHREAD; i++) pthread_join(th[i], NULL);
    int creates = g_creates - before_creates;
    CHECK(creates == NTHREAD, "every thread must build its own object (creates=%d)", creates);
    CHECK(g_links == 1, "exactly one object may be installed for one recipe (links=%d)", g_links);
    CHECK(g_destroys == NTHREAD - 1, "the other %d built objects must be destroyed (destroys=%d)", NTHREAD - 1, g_destroys);
    for (int i = 1; i < NTHREAD; i++)
        CHECK(args[i].got && args[i].got == args[0].got, "thread %d got a different object", i);
    // 3) 参数非法：回调缺失如实 -1，不返回假成功
    void *x = (void *)1;
    nvk_pipe_once_ops bad = { NULL, NULL, fake_link, fake_destroy };
    struct obj *fc = fake_create(k1);
    CHECK(nvk_pipe_once_adopt(&bad, k1, 8, fc, &x) == -1, "missing find callback must fail");
    CHECK(x == NULL, "failed adopt must clear the output");
    free(fc);
    printf("%s nvk_pipe_once_adopt：顺序双检 / %d 线程并发只装一份 / 参数非法如实失败\n", g_fail ? "FAIL" : "PASS", NTHREAD);
    return g_fail;
}
