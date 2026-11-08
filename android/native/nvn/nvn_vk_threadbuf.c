// 每线程缓冲 + 线程退出归还。见 nvn_vk_threadbuf.h 的说明。
#include "nvn_vk_threadbuf.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct threadbuf {
    size_t cap;
    unsigned char data[];   // 8 字节对齐足够（备忘槽是结构体数组，调用方按自身对齐使用）
};

static pthread_key_t g_key;
static pthread_once_t g_key_once = PTHREAD_ONCE_INIT;
static _Atomic int g_live;

static void threadbuf_destroy(void *p) {
    if (!p) return;
    free(p);
    atomic_fetch_sub_explicit(&g_live, 1, memory_order_relaxed);
}
static void threadbuf_key_init(void) { (void)pthread_key_create(&g_key, threadbuf_destroy); }

void *nvn_vk_threadbuf_acquire(size_t bytes) {
    pthread_once(&g_key_once, threadbuf_key_init);
    struct threadbuf *b = (struct threadbuf *)pthread_getspecific(g_key);
    if (!bytes) return b ? b->data : NULL;
    if (b && b->cap >= bytes) return b->data;
    size_t cap = bytes;
    struct threadbuf *nb = (struct threadbuf *)realloc(b, sizeof *nb + cap);
    if (!nb) return b ? b->data : NULL;   // 扩容失败：有旧的继续用，没有就降级
    nb->cap = cap;
    if (!b) atomic_fetch_add_explicit(&g_live, 1, memory_order_relaxed);
    (void)pthread_setspecific(g_key, nb);
    return nb->data;
}

int nvn_vk_threadbuf_live(void) { return atomic_load_explicit(&g_live, memory_order_relaxed); }
