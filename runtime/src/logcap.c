// 日志落盘的唯一出口（native.h s2a_log_out；11-07 Switch2 线 84，总指挥令「日志防刷屏，写在日志层通用处」）。
//   测试机2 金刚 GPU 挂死后每个命令缓冲都报一串红行（一局 1.6 万行），下次启动主线程整份读它卡几秒（diag.m，已改不读）。日志层自己兜两件事：
//   ① 同一条红行（含「【红】」，数字抹掉后相同）只记前 S2A_LOG_RED_KEEP 条，之后压掉、每秒至多一行「[日志] 压掉同类红行 N 条」汇总（下一次有日志写出时补打）；
//   ② host.log（普通文件）超过 S2A_LOG_CAP 就滚动：留开头 S2A_LOG_HEAD（起局信息）+ 最新 S2A_LOG_KEEP，中间换成一行「…滚动截掉 N 字节…」。
//      只看本出口写过的字节数决定何时去查文件大小（每 1 MB 查一次 fstat，C# 等别的写者的字节也算在文件大小里）。
//   不是红行的照写；控制台副本（logcon.c）不在这里，照旧由调用方推
#define S2A_LOGCAP_IMPL
#include "native.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define S2A_LOG_RED_KEEP 8
#define S2A_LOG_CAP (64ull << 20)
#define S2A_LOG_HEAD (8ull << 20)
#define S2A_LOG_KEEP (16ull << 20)
enum { RED_SLOTS = 256, SAMPLE = 120 };
typedef struct { uint64_t key; uint32_t n, supp; char sample[SAMPLE]; } red_slot;
static red_slot g_red[RED_SLOTS];
static uint64_t g_supp_pending, g_supp_total, g_last_sum_ns;
static uint64_t g_since_check;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static __thread int g_in;   // 同线程重入（信号处理里打日志恰好打断临界区）：直写，不碰表、不加锁

#ifdef S2A_UNIT_TEST
uint64_t s2a_logcap_test_cap = 0, s2a_logcap_test_head = 0, s2a_logcap_test_keep = 0;   // 单测缩小上限
#define CAP (s2a_logcap_test_cap ? s2a_logcap_test_cap : S2A_LOG_CAP)
#define HEAD (s2a_logcap_test_head ? s2a_logcap_test_head : S2A_LOG_HEAD)
#define KEEP (s2a_logcap_test_keep ? s2a_logcap_test_keep : S2A_LOG_KEEP)
#define CHECK_EVERY (CAP / 64 ? CAP / 64 : 1)
#else
#define CAP S2A_LOG_CAP
#define HEAD S2A_LOG_HEAD
#define KEEP S2A_LOG_KEEP
#define CHECK_EVERY (1ull << 20)
#endif

static uint64_t mono_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec; }
static int is_red(const char *p, size_t n) { return memmem(p, n, "【红】", strlen("【红】")) != NULL; }
// 红行的「同一条」：抹掉数字与 0x 十六进制后取 FNV-1a（栅栏号、帧号、地址、时间不同仍算同一条）；只看前 240 字节
static uint64_t red_key(const char *p, size_t n) {
    uint64_t h = 1469598103934665603ull; size_t lim = n < 240 ? n : 240;
    for (size_t i = 0; i < lim; i++) {
        unsigned char c = (unsigned char)p[i];
        if (c == '0' && i + 1 < lim && (p[i + 1] == 'x' || p[i + 1] == 'X')) { i++; while (i + 1 < lim && ((p[i + 1] >= '0' && p[i + 1] <= '9') || (p[i + 1] >= 'a' && p[i + 1] <= 'f') || (p[i + 1] >= 'A' && p[i + 1] <= 'F'))) i++; c = '#'; }
        else if (c >= '0' && c <= '9') { while (i + 1 < lim && p[i + 1] >= '0' && p[i + 1] <= '9') i++; c = '#'; }
        h = (h ^ c) * 1099511628211ull;
    }
    return h ? h : 1;
}
static void write_all(int fd, const char *p, size_t n) { while (n) { ssize_t w = write(fd, p, n); if (w <= 0) { if (w < 0 && errno == EINTR) continue; return; } p += w; n -= (size_t)w; } }

// 一秒一行的压掉汇总（持锁调）
static void flush_summary(int fd, uint64_t now) {
    if (!g_supp_pending || now - g_last_sum_ns < 1000000000ull) return;
    char b[1024]; int o = snprintf(b, sizeof b, "[s2a] [日志] 压掉同类红行 %llu 条（每条只记前 %d 条；累计压掉 %llu 条）：", (unsigned long long)g_supp_pending, S2A_LOG_RED_KEEP, (unsigned long long)g_supp_total);
    int shown = 0;
    for (int i = 0; i < RED_SLOTS && o < (int)sizeof b - SAMPLE - 32; i++) if (g_red[i].supp) {
        if (shown++ < 4) o += snprintf(b + o, sizeof b - (size_t)o, "%s「%.*s」×%u", shown > 1 ? "；" : "", SAMPLE - 1, g_red[i].sample, g_red[i].supp);
        g_red[i].supp = 0;
    }
    if (o > (int)sizeof b - 2) o = (int)sizeof b - 2;
    b[o++] = '\n'; write_all(fd, b, (size_t)o);
    g_supp_pending = 0; g_last_sum_ns = now;
}

#if defined(__APPLE__)
static uint64_t g_rolls;   // 滚动次数（只苹果滚：安卓日志在 runtime 私有目录另一套）
// 滚动（持锁调）：fd 是 O_APPEND 的共享描述，另开一个不带 O_APPEND 的描述按偏移搬
static void roll(int fd) {
    struct stat st; if (fstat(fd, &st) || !S_ISREG(st.st_mode) || (uint64_t)st.st_size <= CAP) return;
    char path[PATH_MAX]; if (fcntl(fd, F_GETPATH, path)) return;
    int rw = open(path, O_RDWR); if (rw < 0) return;
    uint64_t size = (uint64_t)st.st_size; char *buf = malloc(1 << 20); if (!buf) { close(rw); return; }
    // 头：HEAD 之后第一个换行；尾：size − KEEP 之后第一个换行
    uint64_t head = HEAD, tail = size - KEEP;
    ssize_t r = pread(rw, buf, 4096, (off_t)head); char *nl = r > 0 ? memchr(buf, '\n', (size_t)r) : NULL; if (nl) head += (uint64_t)(nl - buf) + 1;
    r = pread(rw, buf, 4096, (off_t)tail); nl = r > 0 ? memchr(buf, '\n', (size_t)r) : NULL; if (nl) tail += (uint64_t)(nl - buf) + 1;
    if (tail <= head) { free(buf); close(rw); return; }
    char m[200]; int ml = snprintf(m, sizeof m, "[s2a] [日志] …host.log 超过 %llu MB，滚动截掉中间 %llu 字节（第 %llu 次）…\n", (unsigned long long)(CAP >> 20), (unsigned long long)(tail - head), (unsigned long long)g_rolls + 1);
    uint64_t dst = head; if (pwrite(rw, m, (size_t)ml, (off_t)dst) != ml) { free(buf); close(rw); return; } dst += (uint64_t)ml;
    for (uint64_t src = tail; src < size;) {   // dst < src：前搬不重叠覆盖
        size_t k = size - src < (1u << 20) ? (size_t)(size - src) : (1u << 20);
        r = pread(rw, buf, k, (off_t)src); if (r <= 0) break;
        if (pwrite(rw, buf, (size_t)r, (off_t)dst) != r) break;
        src += (uint64_t)r; dst += (uint64_t)r;
    }
    if (!ftruncate(rw, (off_t)dst)) g_rolls++;
    free(buf); close(rw);
}
#else
static void roll(int fd) { (void)fd; }   // 安卓日志走另一套（runtime 私有目录），这里不滚
#endif

void s2a_log_out(int fd, const char *p, size_t n) {
    if (g_in) { write_all(fd, p, n); return; }
    g_in = 1;
    int red = is_red(p, n);
    pthread_mutex_lock(&g_mu);
    int drop = 0;
    if (red) {
        uint64_t k = red_key(p, n); unsigned i = (unsigned)(k % RED_SLOTS);
        for (unsigned j = 0; j < RED_SLOTS; j++, i = (i + 1) % RED_SLOTS) {
            red_slot *s = &g_red[i];
            if (!s->key) { s->key = k; size_t c = n < SAMPLE - 1 ? n : SAMPLE - 1; while (c && (p[c - 1] == '\n')) c--; memcpy(s->sample, p, c); s->sample[c] = 0;
                           while (c && ((unsigned char)s->sample[c - 1] & 0xc0) == 0x80) s->sample[--c] = 0;   // 不留半个 UTF-8 字
                           if (c && (unsigned char)s->sample[c - 1] >= 0xc0) s->sample[--c] = 0; }
            if (s->key == k) { if (++s->n > S2A_LOG_RED_KEEP) { s->supp++; g_supp_pending++; g_supp_total++; drop = 1; } break; }
        }   // 表满（256 种不同红行）：照写
    }
    uint64_t now = g_supp_pending ? mono_ns() : 0;
    if (g_supp_pending && !drop) flush_summary(fd, now);
    if (!drop) write_all(fd, p, n);
    else if (now) flush_summary(fd, now);
    if (!drop && (g_since_check += n) >= CHECK_EVERY) { g_since_check = 0; roll(fd); }
    pthread_mutex_unlock(&g_mu);
    g_in = 0;
}
