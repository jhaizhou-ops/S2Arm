#include "root_ready.h"
#include <dispatch/dispatch.h>
#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); return 1; } } while (0)
static _Atomic int g_ready_set;
typedef struct { dispatch_semaphore_t entered; int result, saw_ready; } waiter;
static void *wait_root(void *arg) {
    waiter *w = arg;
    dispatch_semaphore_signal(w->entered);
    w->result = s2a_ios_wait_root_view(2000);
    w->saw_ready = atomic_load(&g_ready_set);
    return NULL;
}
// 审计 P2-16：主线程上等界面选择不能睡（UIKit 事件同在主线程），要转运行循环直到按钮回调发信号；旧做法直接返回
static _Atomic int g_signalled;
static void signal_later(dispatch_semaphore_t done, double s) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(s * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ atomic_store(&g_signalled, 1); dispatch_semaphore_signal(done); });
}
static dispatch_semaphore_t g_done;
static void *thread_wait(void *arg) { (void)arg; s2a_ios_wait_ui_signal(g_done); return NULL; }
int main(int argc, char **argv) {
    CHECK(argc == 2);
    if (!strcmp(argv[1], "main-wait")) {
        // 主线程：信号由主队列上 50 ms 后的回调发（等同按钮回调在主线程上跑）；返回时必须已经收到
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        signal_later(done, 0.05);
        s2a_ios_wait_ui_signal(done);
        CHECK(atomic_load(&g_signalled) == 1);
        // 后台线程：同一接口睡等，主线程照常转运行循环发信号
        atomic_store(&g_signalled, 0); g_done = dispatch_semaphore_create(0); pthread_t th;
        CHECK(pthread_create(&th, NULL, thread_wait, NULL) == 0);
        signal_later(g_done, 0.05);
        while (!atomic_load(&g_signalled)) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, 1);
        CHECK(pthread_join(th, NULL) == 0);
    } else if (!strcmp(argv[1], "notify")) {
        // 审计 P2-17：没有界面时挂起的事要等根视图就绪才在主线程跑；旧做法当场就跑
        __block int ran = 0; __block int on_main = 0;
        s2a_ios_on_root_view(^{ ran++; on_main = pthread_main_np(); });
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, 0);
        CHECK(ran == 0);
        s2a_ios_root_view_ready();
        for (int i = 0; i < 100 && !ran; i++) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, 1);
        CHECK(ran == 1 && on_main == 1);
        // 已就绪：下一拍照跑
        s2a_ios_on_root_view(^{ ran++; });
        for (int i = 0; i < 100 && ran < 2; i++) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, 1);
        CHECK(ran == 2);
    } else if (!strcmp(argv[1], "ready-first")) {
        s2a_ios_root_view_ready(); s2a_ios_root_view_ready();
        CHECK(s2a_ios_wait_root_view(0) == 0);
        CHECK(s2a_ios_wait_root_view(0) == 0);
    } else if (!strcmp(argv[1], "timeout")) {
        CHECK(s2a_ios_wait_root_view(2) == -1);
        CHECK(s2a_ios_wait_root_view(0) == -1);
        s2a_ios_root_view_ready();
        CHECK(s2a_ios_wait_root_view(0) == 0);
    } else {
        int n = !strcmp(argv[1], "many-waiters") ? 6 : 1;
        CHECK(n == 6 || !strcmp(argv[1], "render-first"));
        pthread_t threads[6]; waiter waiters[6];
        dispatch_semaphore_t entered = dispatch_semaphore_create(0);
        for (int i = 0; i < n; i++) {
            waiters[i] = (waiter){entered, -2, 0};
            CHECK(pthread_create(&threads[i], NULL, wait_root, &waiters[i]) == 0);
        }
        for (int i = 0; i < n; i++) CHECK(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
        // Renderer starts before the scene, as on a cold iOS launch.
        usleep(20000);
        atomic_store(&g_ready_set, 1);
        s2a_ios_root_view_ready(); s2a_ios_root_view_ready();
        for (int i = 0; i < n; i++) { CHECK(pthread_join(threads[i], NULL) == 0); CHECK(waiters[i].result == 0 && waiters[i].saw_ready); }
    }
    printf("PASS root readiness %s\n", argv[1]);
    return 0;
}
