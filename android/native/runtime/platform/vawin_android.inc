// vawin.c 的 Android 平台实现；保留同一 guest 窗口接口，不伪装 Mach 地址表。
#include "native.h"
#include "platform/plat.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <unistd.h>

static int g_ok;
static uint64_t g_base, g_size, g_res;

int s2a_window_ok(void) { return g_ok; }
void s2a_window_get(uint64_t *base, uint64_t *size) { *base = g_base; *size = g_size; }

typedef void (*map_reader)(uint64_t lo, uint64_t hi, const char prot[4], void *arg);

static int hex_address(const char **text, uint64_t *value) {
    const char *p = *text;
    uint64_t n = 0;
    unsigned count = 0;
    for (;;) {
        unsigned char c = (unsigned char)*p;
        unsigned d = c >= '0' && c <= '9' ? c - '0' :
            c >= 'a' && c <= 'f' ? c - 'a' + 10 : 16;
        if (d == 16) break;
        if (count++ == 16) return EOVERFLOW;
        n = (n << 4) | d;
        p++;
    }
    if (!count) return EINVAL;
    *text = p;
    *value = n;
    return 0;
}

// 只读内核 maps 的前几个字段，不分配堆内存；路径再长也不影响地址段解析。
static int read_maps(map_reader visit, void *arg) {
    int fd = open("/proc/self/maps", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return errno;
    char buf[4096], line[80];
    size_t len = 0;
    int error = 0;
    for (;;) {
        ssize_t n = read(fd, buf, sizeof buf);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (n < 0) error = errno; break; }
        for (ssize_t i = 0; i < n; i++) {
            if (buf[i] != '\n') {
                if (len < sizeof line - 1) line[len++] = buf[i];
                continue;
            }
            line[len] = 0;
            const char *p = line;
            uint64_t lo, hi;
            if (hex_address(&p, &lo) || *p++ != '-' || hex_address(&p, &hi) ||
                *p++ != ' ' || hi <= lo || strlen(p) < 4) { error = EIO; goto done; }
            visit(lo, hi, p, arg);
            len = 0;
        }
    }
    if (len) error = EIO;
done:
    close(fd);
    return error;
}

__attribute__((constructor(101))) static void vawin_reserve(void) {
    const char *e = getenv("S2A_VAWIN_NORESERVE");
    if (e && *e == '1') {
        LOG("Android 地址窗口：诊断禁用持有，不能启动游戏");
        return;
    }
    void *base = NULL;
    int error = plat_vm_reserve(S2A_WIN_SIZE, 1ull << 30, 1ull << 39, &base);
    if (error) {
        LOG("【红】Android 地址窗口：68 GiB 保留失败 errno=%d，不回退", error);
        return;
    }
    uint64_t b = (uint64_t)(uintptr_t)base;
    if (!b || (b & ((1ull << 30) - 1)) || b > (1ull << 39) - S2A_WIN_SIZE)
        die("Android plat_vm_reserve 返回不符合 39 位 / 1 GB 对齐契约的窗口");
    // 所有权留到进程退出或 layout 主动 trim。不能像能力探针那样立刻 munmap。
    g_base = b;
    g_size = g_res = S2A_WIN_SIZE;
    g_ok = 1;
    LOG("Android 所有游戏初始窗口已持有 [%#llx, %#llx)，%llu MiB；非不定款按原布局 trim；客体地址约束 39 位（非宿主 VA 位宽）",
        (unsigned long long)b, (unsigned long long)(b + g_size), (unsigned long long)(g_size >> 20));
    BOOT_MARK("Android 动态库装载 → 持有 guest 窗口");
}

uint64_t s2a_window_spare(void) {
    // 窗口尾部 trim 还回系统的部分；窗口以上的空洞未逐段统计（main 的 vawin.c 在非 Android 路径做），
    // 这里给保守值，lowva 只会更早进入限制模式，不会越界使用。
    return g_ok ? g_res - g_size : 0;
}

void s2a_window_trim(uint64_t size) {
    if (!g_ok || size >= g_size) return;
    size_t pg = plat_page_size();
    if (!size || !pg || size % pg) die("Android 窗口收尾大小不合法");
    if (munmap((void *)(uintptr_t)(g_base + size), g_size - size))
        die("Android 窗口收尾失败 errno=%d", errno);
    LOG("Android 窗口收到前 %llu MB，尾部 %llu MB 归还系统",
        (unsigned long long)(size >> 20), (unsigned long long)((g_size - size) >> 20));
    g_size = size;
}

void s2a_window_resident(uint64_t *resident, uint64_t *paged_out) {
    unsigned char vec[4096];
    uint64_t pg = plat_page_size(), total = 0;
    *resident = *paged_out = 0;
    if (!g_ok || !pg) return;
    for (uint64_t a = g_base; a < g_base + g_size;) {
        uint64_t n = g_base + g_size - a;
        if (n > sizeof vec * pg) n = sizeof vec * pg;
        if (mincore((void *)(uintptr_t)a, n, vec)) {
            LOG("【红】Android 窗口常驻读取失败 errno=%d；本次读数无效", errno);
            return;
        }
        for (uint64_t i = 0; i < n / pg; i++) total += (vec[i] & 1) ? pg : 0;
        a += n;
    }
    *resident = total;
    // Linux mincore 只报告常驻，不能区分未提交与换出；0 不代表实测没有换出。
}

struct map_range { uint64_t lo, hi, next, total, largest; unsigned count; };

static void count_range(uint64_t lo, uint64_t hi, const char prot[4], void *arg) {
    (void)prot;
    struct map_range *r = arg;
    if (hi <= r->lo || lo >= r->hi) return;
    if (lo < r->lo) lo = r->lo;
    if (hi > r->hi) hi = r->hi;
    if (lo > r->next) {
        uint64_t hole = lo - r->next;
        r->total += hole;
        if (hole > r->largest) r->largest = hole;
    }
    if (hi > r->next) r->next = hi;
    r->count++;
}

static int range_holes(struct map_range *r) {
    r->next = r->lo;
    int error = read_maps(count_range, r);
    if (error) return error;
    if (r->next < r->hi) {
        uint64_t hole = r->hi - r->next;
        r->total += hole;
        if (hole > r->largest) r->largest = hole;
    }
    return 0;
}

void s2a_low_holes(uint64_t *total, uint64_t *largest) {
    // 沿用调用方的「窗口以下 + trim 尾部」口径，不把它谎称 Android 全进程 VA 余量。
    struct map_range r = {.lo = 1ull << 32, .hi = g_ok ? g_base : 1ull << 39};
    *total = *largest = 0;
    if (range_holes(&r)) return;
    if (g_ok && g_size < S2A_WIN_SIZE) {
        struct map_range tail = {.lo = g_base + g_size, .hi = g_base + S2A_WIN_SIZE};
        if (range_holes(&tail)) return;
        r.total += tail.total;
        if (tail.largest > r.largest) r.largest = tail.largest;
    }
    *total = r.total;
    *largest = r.largest;
}

void s2a_fd_usage(int *open_n, uint64_t *soft, uint64_t *hard) {
    struct rlimit limits = {0};
    getrlimit(RLIMIT_NOFILE, &limits);
    *soft = limits.rlim_cur;
    *hard = limits.rlim_max;
    int n = 0, limit = limits.rlim_cur < 4096 ? (int)limits.rlim_cur : 4096;
    for (int fd = 0; fd < limit; fd++) if (fcntl(fd, F_GETFD) != -1) n++;
    *open_n = n;
}

uint64_t s2a_va_top(void) { return 0; } // Linux 没有 TASK_VM_INFO max_address；未测，不伪造 2^39。

void s2a_window_probe(const char *when) {
    if (!g_ok) { LOG("Android 窗口探测 [%s]：没有持有窗口", when); return; }
    struct map_range r = {.lo = g_base, .hi = g_base + g_size};
    int error = range_holes(&r);
    if (error) LOG("【红】Android 窗口探测 [%s]：maps 不可读 errno=%d", when, error);
    else LOG("Android 窗口探测 [%s]：%s，%u 段，缺口 %llu 字节", when,
        r.total ? "【红】不完整" : "已持有范围完整", r.count, (unsigned long long)r.total);
}

void s2a_low_tags(char *out, size_t cap) {
    uint64_t total, largest;
    s2a_low_holes(&total, &largest);
    snprintf(out, cap, "Android maps：窗口以下及归还尾部空洞 %llu MB，最大 %llu MB；无 Mach 用途标签",
        (unsigned long long)(total >> 20), (unsigned long long)(largest >> 20));
}

static void map_total(uint64_t lo, uint64_t hi, const char prot[4], void *arg) {
    (void)prot;
    uint64_t *total = arg;
    uint64_t n = hi - lo;
    if (g_ok && hi > g_base && lo < g_base + g_size) {
        uint64_t left = lo > g_base ? lo : g_base;
        uint64_t right = hi < g_base + g_size ? hi : g_base + g_size;
        n -= right - left;
    }
    *total += n;
}
void s2a_vm_top(const char *when) {
    uint64_t total = 0;
    int error = read_maps(map_total, &total);
    if (error) LOG("Android 窗口外 maps [%s]：读数不可用 errno=%d", when, error);
    else LOG("Android 窗口外 maps [%s]：已映射 %llu MB（虚拟地址，不是 RSS；无 Mach 标签）",
        when, (unsigned long long)(total >> 20));
}
void s2a_vm_low(const char *when) {
    char text[256];
    s2a_low_tags(text, sizeof text);
    LOG("地址余量 [%s]：%s", when, text);
}
void s2a_oom_dump(const char *when) { s2a_window_probe(when); s2a_vm_low(when); s2a_vm_top(when); }

static pthread_once_t g_watch_once = PTHREAD_ONCE_INIT;
static void *va_watch(void *arg) {
    (void)arg;
    for (;;) { sleep(30); s2a_vm_low("Android 心跳"); }
    return NULL;
}
static void start_watch(void) {
    pthread_t thread;
    int error = pthread_create(&thread, NULL, va_watch, NULL);
    if (error) LOG("Android 地址巡检线程启动失败 errno=%d", error);
    else pthread_detach(thread);
}
void s2a_va_watch_start(void) { pthread_once(&g_watch_once, start_watch); }
