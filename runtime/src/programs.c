// 多程序合集：包里有几支程序、下一局跑哪一支（runtime/include/s2a_programs.h）。
//   只在苹果宿主用（安卓不提供进程内重建，不链本文件；服务层按名找导出，找不到报红）。
#include "native.h"
#include "s2a_programs.h"
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

int s2a_programs_dir(const char *base, int n, char *out, size_t len) {
    if (!base || !*base || !out || !len || n < 0 || n >= S2A_PROGRAMS_MAX) return -1;
    int w = n ? snprintf(out, len, "%s/programs/%d", base, n) : snprintf(out, len, "%s", base);
    return w < 0 || (size_t)w >= len ? -1 : 0;
}

static int has_npdm(const char *dir) {
    char p[1200]; struct stat st;
    if (snprintf(p, sizeof p, "%s/main.npdm", dir) >= (int)sizeof p) return 0;
    return !stat(p, &st) && S_ISREG(st.st_mode);
}

int s2a_programs_count(const char *base) {
    char d[1100];
    if (s2a_programs_dir(base, 0, d, sizeof d) || !has_npdm(d)) return 0;
    int n = 1;
    while (n < S2A_PROGRAMS_MAX && !s2a_programs_dir(base, n, d, sizeof d) && has_npdm(d)) n++;
    return n;
}

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static char g_base[1100];
static int g_count, g_cur, g_next = -1;

void s2a_programs_init(const char *base) {
    pthread_mutex_lock(&g_mu);
    snprintf(g_base, sizeof g_base, "%s", base ? base : "");
    g_count = s2a_programs_count(g_base); g_cur = 0; g_next = -1;
    int n = g_count;
    pthread_mutex_unlock(&g_mu);
    if (n > 1) LOG("多程序合集：包里 %d 支程序（序号 0 = 本目录，1..%d 在 programs/<序号>/），本局序号 0", n, n - 1);
}

int s2a_host_program_count(void) { pthread_mutex_lock(&g_mu); int n = g_count; pthread_mutex_unlock(&g_mu); return n; }
int s2a_host_program_index(void) { pthread_mutex_lock(&g_mu); int n = g_cur; pthread_mutex_unlock(&g_mu); return n; }

int s2a_host_select_program(int n) {
    pthread_mutex_lock(&g_mu);
    int rc = !g_base[0] ? -2 : n < 0 || n >= g_count ? -1 : 0, count = g_count;
    if (!rc) g_next = n;
    pthread_mutex_unlock(&g_mu);
    if (rc == -1) LOG("【红】多程序合集：要切到序号 %d，包里只有 %d 支程序（序号 0..%d）", n, count, count - 1);
    else if (rc == -2) LOG("【红】多程序合集：宿主没登记模块根目录，不能切程序（序号 %d）", n);
    return rc;
}

int s2a_programs_take(char *out, size_t len) {
    pthread_mutex_lock(&g_mu);
    int n = g_next, rc = -1;
    if (n >= 0 && !s2a_programs_dir(g_base, n, out, len)) { rc = n; g_cur = n; }
    g_next = -1;
    pthread_mutex_unlock(&g_mu);
    return rc;
}
