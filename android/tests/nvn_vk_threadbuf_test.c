// 每线程缓冲（nvn_vk_threadbuf）的确定性宿主用例：
// 同线程复用同一块、扩容保留内容、第二块不存在、线程退出时由 pthread_key 析构归还（live 计数归零）。
#include <pthread.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

#include "nvn/nvn_vk_threadbuf.h"

static int g_fail, g_checks;
#define CHECK(cond) do { g_checks++; if (!(cond)) { g_fail++; printf("    FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)
#define CASE(name) printf("  case %-28s", name)

static _Atomic int g_thread_live_after_acquire;

static void *worker(void *arg) {
    size_t bytes = (size_t)(uintptr_t)arg;
    unsigned char *p = (unsigned char *)nvn_vk_threadbuf_acquire(bytes);
    if (p) memset(p, 0xAB, bytes);
    atomic_store(&g_thread_live_after_acquire, nvn_vk_threadbuf_live());
    return p ? (void *)1 : NULL;
}

int main(void) {
    CASE("same_thread_reuse");
    {
        unsigned char *a = (unsigned char *)nvn_vk_threadbuf_acquire(1024);
        CHECK(a != NULL);
        memset(a, 0x5A, 1024);
        unsigned char *b = (unsigned char *)nvn_vk_threadbuf_acquire(1024);
        CHECK(b == a);                     // 同线程同尺寸：同一块
        CHECK(b[0] == 0x5A && b[1023] == 0x5A);
        CHECK(nvn_vk_threadbuf_live() == 1);
        printf("ok\n");
    }

    CASE("grow_keeps_content");
    {
        unsigned char *a = (unsigned char *)nvn_vk_threadbuf_acquire(4096);   // 扩容
        CHECK(a != NULL);
        CHECK(a[0] == 0x5A && a[1023] == 0x5A);   // 原内容保留
        memset(a, 0x33, 4096);
        CHECK(nvn_vk_threadbuf_live() == 1);      // 扩容不产生新块
        printf("ok\n");
    }

    CASE("thread_exit_releases");
    {
        const int before = nvn_vk_threadbuf_live();
        for (int i = 0; i < 4; i++) {
            pthread_t t;
            atomic_store(&g_thread_live_after_acquire, 0);
            CHECK(pthread_create(&t, NULL, worker, (void *)(uintptr_t)(2048u + (unsigned)i * 512u)) == 0);
            CHECK(pthread_join(t, NULL) == 0);
            CHECK(atomic_load(&g_thread_live_after_acquire) == before + 1);   // 线程内确实拿到了一块
        }
        CHECK(nvn_vk_threadbuf_live() == before);   // 四个线程退出后全部归还
        printf("ok\n");
    }

    CASE("zero_bytes_no_alloc");
    {
        const int before = nvn_vk_threadbuf_live();
        pthread_t t;
        atomic_store(&g_thread_live_after_acquire, 0);
        CHECK(pthread_create(&t, NULL, worker, (void *)0) == 0);
        CHECK(pthread_join(t, NULL) == 0);
        const int inside = atomic_load(&g_thread_live_after_acquire);
        CHECK(inside == before);   // 0 字节不分配
        printf("ok (live 在 0 字节线程内仍为 %d)\n", inside);
    }

    printf("nvn-vk-threadbuf: 检查 %d 项，失败 %d 项 → %s\n", g_checks, g_fail, g_fail ? "红" : "通过");
    return g_fail ? 1 : 0;
}
