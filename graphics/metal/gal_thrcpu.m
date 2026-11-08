// 诊断（S2A_THR_CPU=<秒>，缺省关）：每 <秒> 列本进程全部线程的 CPU 占一核百分比与线程名，不截断——
// 动森新架构 iPhone 6.0–6.45 W、旧库同机 2.6–3.0 W，GPU 每帧持平（20.9 vs 22 ms），多出的在 CPU 侧；真机上只能进程内自量（10-20 帧率能耗线）
// task_threads + THREAD_EXTENDED_INFO（用户 + 内核时间，纳秒）与 THREAD_IDENTIFIER_INFO（线程号），Mac / iOS 同一份
#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef struct { uint64_t id, ns; char name[64]; } thr_s;
enum { THR_MAX = 1024 };
static thr_s g_a[THR_MAX], g_b[THR_MAX];

static int thr_snap(thr_s *o) {
    thread_act_array_t th; mach_msg_type_number_t n = 0; int k = 0;
    if (task_threads(mach_task_self(), &th, &n) != KERN_SUCCESS) return 0;
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        thread_extended_info_data_t ei; mach_msg_type_number_t c = THREAD_EXTENDED_INFO_COUNT;
        thread_identifier_info_data_t ii; mach_msg_type_number_t c2 = THREAD_IDENTIFIER_INFO_COUNT;
        if (k < THR_MAX && thread_info(th[i], THREAD_EXTENDED_INFO, (thread_info_t)&ei, &c) == KERN_SUCCESS
            && thread_info(th[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ii, &c2) == KERN_SUCCESS) {
            o[k].id = ii.thread_id; o[k].ns = ei.pth_user_time + ei.pth_system_time;
            memcpy(o[k].name, ei.pth_name, sizeof o[k].name); o[k].name[63] = 0; k++;
        }
        mach_port_deallocate(mach_task_self(), th[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)th, n * sizeof(thread_act_t));
    if (k == THR_MAX) fprintf(stderr, "[线程CPU] 【红】线程数超过 %d 条，多出的没记\n", THR_MAX);
    return k;
}

static int by_pct(const void *x, const void *y) { double a = *(const double *)x, b = *(const double *)y; return a < b ? 1 : a > b ? -1 : 0; }

static double mono_s(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

static void *thr_main(void *arg) {
    pthread_setname_np("S2A.ThrCpu");
    int sec = (int)(intptr_t)arg, na = thr_snap(g_a); double ta = mono_s();
    static struct { double pct; int i; } row[THR_MAX];
    for (;;) {
        sleep(sec);
        int nb = thr_snap(g_b); double tb = mono_s(), dt = tb - ta, tot = 0;
        for (int i = 0; i < nb; i++) {
            uint64_t prev = 0;
            for (int j = 0; j < na; j++) if (g_a[j].id == g_b[i].id) { prev = g_a[j].ns; break; }
            row[i].pct = (g_b[i].ns - prev) / 1e9 / dt * 100; row[i].i = i; tot += row[i].pct;
        }
        qsort(row, nb, sizeof row[0], by_pct);
        fprintf(stderr, "[线程CPU] 窗口 %.1f 秒，线程 %d 条（全列），合计 %.1f%% 核\n", dt, nb, tot);
        for (int r = 0; r < nb; r++) {
            thr_s *t = &g_b[row[r].i];
            fprintf(stderr, "[线程CPU] %6.2f%% %s #%llu\n", row[r].pct, t->name[0] ? t->name : "?", (unsigned long long)t->id);
        }
        memcpy(g_a, g_b, nb * sizeof g_a[0]); na = nb; ta = tb;
    }
    return NULL;
}

void gal_thrcpu_start(void) {
    const char *v = getenv("S2A_THR_CPU"); int sec = v ? atoi(v) : 0;
    if (sec <= 0) return;
    pthread_attr_t a; pthread_attr_init(&a); pthread_attr_set_qos_class_np(&a, QOS_CLASS_UTILITY, 0);
    pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
    pthread_t t; if (pthread_create(&t, &a, thr_main, (void *)(intptr_t)sec)) fprintf(stderr, "[线程CPU] 【红】诊断线程起不来\n");
    else fprintf(stderr, "[线程CPU] 已开：每 %d 秒列一次\n", sec);
    pthread_attr_destroy(&a);
}
