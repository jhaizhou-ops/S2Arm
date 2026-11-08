// Android 背板核心：单一 memfd、pgoff 等于 guest 地址、按宿主页打洞。
// 本文件没有生产调用方（P1）；调用方负责把任何非 0 返回当终止条件。
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "backing.h"
#include "../../../../platform/plat.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 0x0001U
#endif
#ifndef MFD_NOEXEC_SEAL
#define MFD_NOEXEC_SEAL 0x0008U
#endif
#ifndef FALLOC_FL_KEEP_SIZE
#define FALLOC_FL_KEEP_SIZE 0x01
#endif
#ifndef FALLOC_FL_PUNCH_HOLE
#define FALLOC_FL_PUNCH_HOLE 0x02
#endif

// 512 GiB 末端与整文件打洞依赖 64 位 off_t / size_t；32 位 ABI 会截断。
_Static_assert(sizeof(off_t) == 8 && sizeof(size_t) == 8,
               "背板需要 64 位 off_t 与 size_t");

// 稀疏区间表：只记别名源（基础提交不计数）。段数上界是并发别名数。
typedef struct {
    uint64_t lo, hi;
    uint32_t refs;
} backing_ref_range;

static pthread_mutex_t g_bk_mu = PTHREAD_MUTEX_INITIALIZER;   // 叶子锁：持有时不取其它锁
static int g_bk_fd = -1;
static uint64_t g_bk_limit;
static backing_ref_range *g_bk_refs;
static size_t g_bk_ref_count, g_bk_ref_cap;
static _Atomic uint64_t g_bk_sequence;
static _Atomic uint64_t g_bk_deferred;

static int backing_page(uint64_t *page) {
    size_t value = plat_page_size();
    if (!value) return ENOTSUP;
    *page = (uint64_t)value;
    return 0;
}

static int backing_round(uint64_t limit, uint64_t *rounded) {
    uint64_t page;
    int error = backing_page(&page);
    if (error) return error;
    if (!limit) return EINVAL;
    if (limit > UINT64_MAX - (page - 1)) return EOVERFLOW;
    uint64_t value = (limit + page - 1) & ~(page - 1);
    if (value > (uint64_t)INT64_MAX) return EOVERFLOW;
    *rounded = value;
    return 0;
}

// 调用方持 g_bk_mu 且已 open。
static int backing_range_locked(uint64_t pgoff, size_t size) {
    uint64_t page;
    int error = backing_page(&page);
    if (error) return error;
    if (!size || (pgoff & (page - 1)) || (size & (page - 1))) return EINVAL;
    if (pgoff > g_bk_limit || (uint64_t)size > g_bk_limit - pgoff) return EINVAL;
    return 0;
}

static int backing_refs_reserve(size_t need) {
    if (need <= g_bk_ref_cap) return 0;
    size_t capacity = g_bk_ref_cap ? g_bk_ref_cap : 8;
    while (capacity < need) {
        if (capacity > SIZE_MAX / 2) return ENOMEM;
        capacity *= 2;
    }
    backing_ref_range *table = realloc(g_bk_refs, capacity * sizeof(*table));
    if (!table) return ENOMEM;
    g_bk_refs = table;
    g_bk_ref_cap = capacity;
    return 0;
}

// 保证 pos 是段边界；pos 落在某段内部时把该段一分为二。
static int backing_refs_split(uint64_t pos) {
    for (size_t i = 0; i < g_bk_ref_count; i++) {
        if (g_bk_refs[i].lo < pos && pos < g_bk_refs[i].hi) {
            int error = backing_refs_reserve(g_bk_ref_count + 1);
            if (error) return error;
            memmove(&g_bk_refs[i + 2], &g_bk_refs[i + 1],
                    (g_bk_ref_count - i - 1) * sizeof(*g_bk_refs));
            g_bk_refs[i + 1].lo = pos;
            g_bk_refs[i + 1].hi = g_bk_refs[i].hi;
            g_bk_refs[i + 1].refs = g_bk_refs[i].refs;
            g_bk_refs[i].hi = pos;
            g_bk_ref_count++;
            return 0;
        }
    }
    return 0;
}

static void backing_refs_merge(void) {
    size_t write = 0;
    for (size_t read = 0; read < g_bk_ref_count; read++) {
        if (write && g_bk_refs[write - 1].hi == g_bk_refs[read].lo
            && g_bk_refs[write - 1].refs == g_bk_refs[read].refs) {
            g_bk_refs[write - 1].hi = g_bk_refs[read].hi;
        } else {
            g_bk_refs[write++] = g_bk_refs[read];
        }
    }
    g_bk_ref_count = write;
}

static uint32_t backing_refs_max_locked(uint64_t pgoff, size_t size) {
    uint64_t hi = pgoff + (uint64_t)size;
    uint32_t maximum = 0;
    for (size_t i = 0; i < g_bk_ref_count; i++) {
        if (g_bk_refs[i].hi <= pgoff) continue;
        if (g_bk_refs[i].lo >= hi) break;
        if (g_bk_refs[i].refs > maximum) maximum = g_bk_refs[i].refs;
    }
    return maximum;
}

static int backing_refs_add_locked(uint64_t pgoff, uint64_t hi) {
    // 前提：调用方已在 pgoff / hi 处拆分，所有段不会跨过这两个边界；
    // 本函数直接用段边界，不再处理跨界段。
    if (g_bk_ref_count > (SIZE_MAX - 4) / 2) return ENOMEM;
    size_t capacity = g_bk_ref_count * 2 + 4;
    backing_ref_range *out = calloc(capacity, sizeof(*out));
    if (!out) return ENOMEM;
    size_t count = 0, read = 0;
    uint64_t cursor = pgoff;
    while (read < g_bk_ref_count && g_bk_refs[read].hi <= pgoff) out[count++] = g_bk_refs[read++];
    while (read < g_bk_ref_count && g_bk_refs[read].lo < hi) {
        if (g_bk_refs[read].lo > cursor) {
            out[count].lo = cursor;
            out[count].hi = g_bk_refs[read].lo;
            out[count].refs = 1;
            count++;
            cursor = g_bk_refs[read].lo;
        }
        if (g_bk_refs[read].refs == UINT32_MAX) { free(out); return EOVERFLOW; }
        out[count].lo = g_bk_refs[read].lo;
        out[count].hi = g_bk_refs[read].hi < hi ? g_bk_refs[read].hi : hi;
        out[count].refs = g_bk_refs[read].refs + 1;
        cursor = out[count].hi;
        count++;
        read++;
    }
    if (cursor < hi) {
        out[count].lo = cursor;
        out[count].hi = hi;
        out[count].refs = 1;
        count++;
    }
    while (read < g_bk_ref_count) out[count++] = g_bk_refs[read++];
    size_t write = 0;
    for (size_t i = 0; i < count; i++) {
        if (write && out[write - 1].hi == out[i].lo && out[write - 1].refs == out[i].refs)
            out[write - 1].hi = out[i].hi;
        else
            out[write++] = out[i];
    }
    free(g_bk_refs);
    g_bk_refs = out;
    g_bk_ref_count = write;
    g_bk_ref_cap = capacity;
    return 0;
}

static int backing_punch_locked(uint64_t pgoff, size_t size, int *deferred) {
    int error = backing_range_locked(pgoff, size);
    if (error) return error;
    if (backing_refs_max_locked(pgoff, size)) {
        atomic_fetch_add_explicit(&g_bk_deferred, 1, memory_order_relaxed);
        *deferred = 1;
        return 0;
    }
    *deferred = 0;
    atomic_fetch_add_explicit(&g_bk_sequence, 1, memory_order_acq_rel);
    int rc;
    do {
        rc = fallocate(g_bk_fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE,
                       (off_t)pgoff, (off_t)size);
    } while (rc && errno == EINTR);
    error = rc ? errno : 0;
    atomic_fetch_add_explicit(&g_bk_sequence, 1, memory_order_acq_rel);
    return error;
}

static int backing_native_prot(uint32_t prot, int *out) {
    if (prot & ~(uint32_t)(PLAT_PROT_READ | PLAT_PROT_WRITE | PLAT_PROT_EXEC)) return EINVAL;
    int value = PROT_NONE;
    if (prot & PLAT_PROT_READ) value |= PROT_READ;
    if (prot & PLAT_PROT_WRITE) value |= PROT_WRITE;
    if (prot & PLAT_PROT_EXEC) value |= PROT_EXEC;
    *out = value;
    return 0;
}

// open 自检：同一 memfd 上映射、写入、打洞、读回零。任何一步失败都回 errno，
// 不退回共享匿名映射。
static int backing_selfcheck_locked(void) {
    uint64_t page;
    int error = backing_page(&page);
    if (error) return error;
    uint8_t *probe = mmap(NULL, (size_t)page, PROT_READ | PROT_WRITE,
                          MAP_SHARED, g_bk_fd, 0);
    if (probe == MAP_FAILED) return errno;
    probe[0] = 0x5a;
    probe[page - 1] = 0xa5;
    int deferred = 0;
    error = backing_punch_locked(0, (size_t)page, &deferred);
    if (!error && (deferred || probe[0] != 0 || probe[page - 1] != 0)) error = EIO;
    if (munmap(probe, (size_t)page)) { if (!error) error = errno; }
    return error;
}

int plat_backing_open(uint64_t limit) {
    uint64_t rounded;
    int error = backing_round(limit, &rounded);
    if (error) return error;
    pthread_mutex_lock(&g_bk_mu);
    if (g_bk_fd >= 0) {
        if (rounded <= g_bk_limit) {
            pthread_mutex_unlock(&g_bk_mu);
            return 0;
        }
        if (ftruncate(g_bk_fd, (off_t)rounded)) error = errno;
        else g_bk_limit = rounded;
        pthread_mutex_unlock(&g_bk_mu);
        return error;
    }
    int fd = (int)syscall(SYS_memfd_create, "s2a-guest", MFD_CLOEXEC | MFD_NOEXEC_SEAL);
    if (fd < 0 && errno == EINVAL)
        fd = (int)syscall(SYS_memfd_create, "s2a-guest", MFD_CLOEXEC);
    if (fd < 0) {
        error = errno;
        pthread_mutex_unlock(&g_bk_mu);
        return error;
    }
    if (ftruncate(fd, (off_t)rounded)) {
        error = errno;
        close(fd);
        pthread_mutex_unlock(&g_bk_mu);
        return error;
    }
    g_bk_fd = fd;
    g_bk_limit = rounded;
    error = backing_selfcheck_locked();
    if (error) {
        close(fd);
        g_bk_fd = -1;
        g_bk_limit = 0;
    }
    pthread_mutex_unlock(&g_bk_mu);
    return error;
}

int plat_backing_map(void *addr, size_t size, uint32_t plat_prot, uint64_t pgoff) {
    int native;
    int error = backing_native_prot(plat_prot, &native);
    if (error) return error;
    if (!addr) return EINVAL;
    pthread_mutex_lock(&g_bk_mu);
    if (g_bk_fd < 0) error = EINVAL;
    else error = backing_range_locked(pgoff, size);
    if (!error) {
        void *mapped = mmap(addr, size, native, MAP_SHARED | MAP_FIXED, g_bk_fd, (off_t)pgoff);
        if (mapped == MAP_FAILED) error = errno;
        else if (mapped != addr) error = EIO;
    }
    pthread_mutex_unlock(&g_bk_mu);
    return error;
}

int plat_backing_punch(uint64_t pgoff, size_t size, int *deferred) {
    if (!deferred) return EINVAL;
    pthread_mutex_lock(&g_bk_mu);
    int error;
    if (g_bk_fd < 0) error = EINVAL;
    else error = backing_punch_locked(pgoff, size, deferred);
    pthread_mutex_unlock(&g_bk_mu);
    return error;
}

int plat_backing_ref(uint64_t pgoff, size_t size) {
    pthread_mutex_lock(&g_bk_mu);
    int error;
    if (g_bk_fd < 0) error = EINVAL;
    else error = backing_range_locked(pgoff, size);
    if (!error) error = backing_refs_reserve(g_bk_ref_count + 2);
    if (!error) {
        uint64_t hi = pgoff + (uint64_t)size;
        error = backing_refs_split(pgoff);
        if (!error) error = backing_refs_split(hi);
        if (!error) error = backing_refs_add_locked(pgoff, hi);
    }
    if (error) backing_refs_merge();   // 失败也要保持「相邻同数合并」的不变量
    pthread_mutex_unlock(&g_bk_mu);
    return error;
}

int plat_backing_unref(uint64_t pgoff, size_t size) {
    pthread_mutex_lock(&g_bk_mu);
    int error;
    if (g_bk_fd < 0) error = EINVAL;
    else error = backing_range_locked(pgoff, size);
    uint64_t hi = pgoff + (uint64_t)size;
    if (!error) {
        // 整个区间必须都有引用；有空洞就不改任何状态。
        uint64_t at = pgoff;
        for (size_t i = 0; i < g_bk_ref_count && at < hi; i++) {
            if (g_bk_refs[i].hi <= at) continue;
            if (g_bk_refs[i].lo > at) { error = EINVAL; break; }
            at = g_bk_refs[i].hi < hi ? g_bk_refs[i].hi : hi;
        }
        if (!error && at < hi) error = EINVAL;
    }
    if (!error) error = backing_refs_reserve(g_bk_ref_count + 2);
    if (!error) error = backing_refs_split(pgoff);
    if (!error) error = backing_refs_split(hi);
    if (!error) {
        size_t write = 0;
        for (size_t i = 0; i < g_bk_ref_count; i++) {
            if (g_bk_refs[i].lo >= pgoff && g_bk_refs[i].hi <= hi) {
                if (!g_bk_refs[i].refs) abort();   // 预检后不应发生；不允许截断表
                g_bk_refs[i].refs--;
            }
            if (g_bk_refs[i].refs) g_bk_refs[write++] = g_bk_refs[i];
        }
        g_bk_ref_count = write;
        backing_refs_merge();
    }
    pthread_mutex_unlock(&g_bk_mu);
    return error;
}

uint32_t plat_backing_refs(uint64_t pgoff, size_t size) {
    pthread_mutex_lock(&g_bk_mu);
    // 出错按「有引用」处理（fail-closed），不能把非法区间当成安全的无引用。
    uint32_t maximum = UINT32_MAX;
    if (g_bk_fd >= 0 && !backing_range_locked(pgoff, size))
        maximum = backing_refs_max_locked(pgoff, size);
    pthread_mutex_unlock(&g_bk_mu);
    return maximum;
}

uint64_t plat_backing_sequence(void) {
    return atomic_load_explicit(&g_bk_sequence, memory_order_acquire);
}

int plat_backing_reset(void) {
    pthread_mutex_lock(&g_bk_mu);
    int error;
    if (g_bk_fd < 0) error = EINVAL;
    else if (g_bk_ref_count) error = EBUSY;
    else {
        int deferred = 0;
        error = backing_punch_locked(0, (size_t)g_bk_limit, &deferred);
        if (!error && deferred) error = EBUSY;   // refs 已空，不应走到
    }
    pthread_mutex_unlock(&g_bk_mu);
    return error;
}

uint64_t plat_backing_limit(void) {
    pthread_mutex_lock(&g_bk_mu);
    uint64_t limit = g_bk_limit;
    pthread_mutex_unlock(&g_bk_mu);
    return limit;
}

uint64_t plat_backing_deferred(void) {
    return atomic_load_explicit(&g_bk_deferred, memory_order_acquire);
}
