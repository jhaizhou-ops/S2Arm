// 安卓侧管线预热清单：记录/落盘/加载。见 nvn_vk_pipe_manifest.h 的合同。
// 线程模型：只在渲染线程上调用（note 在管线创建分支、save 在收尾、configure 在初始化），
// 与 nvn_vk_first_draw.c 的管线缓存同线程，不引入额外锁。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/system_properties.h>
#include <time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <android/log.h>

#include "nvn_vk_pipe_manifest.h"

#define NVM_MAGIC "S2APM1"
#define NVM_VERSION 2u
#define NVM_LOG(...) __android_log_print(ANDROID_LOG_INFO, "S2Arm", __VA_ARGS__)

static struct nvm_entry g_entries[NVM_MAX_ENTRIES];
static uint32_t g_count;
static uint32_t g_loaded, g_recorded, g_dups, g_refused;
static int g_on = -1;
static int g_configured;
static int g_dirty;
static uint64_t g_last_save_ns;
static uint32_t g_take_next;
static _Atomic int g_saving;
static char g_path[560];
static char g_dir[480];

static int nvm_on(void) {
    if (g_on < 0) {
        char b[PROP_VALUE_MAX] = {0};
        __system_property_get("debug.s2a.pipe_manifest", b);
        g_on = b[0] ? atoi(b) : 1;
    }
    return g_on;
}

int nvm_manifest_enabled(void) { return nvm_on(); }

static uint64_t nvm_fnv64(const void *data, size_t n) {
    const uint8_t *p = (const uint8_t *)data;
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ull; }
    return h;
}

// 持久化格式（小端、定长）：用显式字节序列化，不依赖结构体 padding。
static size_t nvm_hdr_size(void) { return 8 + 4 + 4 + 4 + 4 + 8; }   // magic/version/layout/entry_size/count/checksum

static void nvm_put_u32(uint8_t **p, uint32_t v) { memcpy(*p, &v, 4); *p += 4; }
static void nvm_put_u64(uint8_t **p, uint64_t v) { memcpy(*p, &v, 8); *p += 8; }
static uint32_t nvm_get_u32(const uint8_t **p) { uint32_t v; memcpy(&v, *p, 4); *p += 4; return v; }
static uint64_t nvm_get_u64(const uint8_t **p) { uint64_t v; memcpy(&v, *p, 8); *p += 8; return v; }

void nvm_manifest_configure(const char *cache_dir, const uint8_t uuid[16]) {
    g_configured = 0;
    g_count = g_loaded = g_recorded = g_dups = g_refused = 0;
    g_take_next = 0;
    g_dirty = 0;
    g_path[0] = g_dir[0] = 0;
    if (!nvm_on() || !cache_dir || !cache_dir[0] || !uuid) return;
    if (strlen(cache_dir) >= sizeof g_dir) return;
    snprintf(g_dir, sizeof g_dir, "%s", cache_dir);
    char hex[33];
    for (int i = 0; i < 16; i++) snprintf(hex + i * 2, 3, "%02x", uuid[i]);
    snprintf(g_path, sizeof g_path, "%s/pipes-v%u-%s.bin", g_dir, (unsigned)NVK_PIPE_LAYOUT_POLICY, hex);
    g_configured = 1;

    int fd = open(g_path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        if (errno != ENOENT)
            NVM_LOG("pipe manifest: open %s failed (%s); starting empty", g_path, strerror(errno));
        return;
    }
    struct stat st;
    const size_t hdr = nvm_hdr_size();
    const size_t esz = sizeof(struct nvm_entry);
    if (fstat(fd, &st) != 0 || (size_t)st.st_size < hdr || st.st_size > (off_t)(hdr + esz * NVM_MAX_ENTRIES)) {
        close(fd);
        NVM_LOG("pipe manifest: rejected (size %lld)", (long long)st.st_size);
        return;
    }
    /* 先读头（32 字节足够） */
    uint8_t head[32];
    if (read(fd, head, hdr) != (ssize_t)hdr) { close(fd); NVM_LOG("pipe manifest: rejected (short header)"); return; }
    const uint8_t *hp = head;
    char magic[9] = {0};
    memcpy(magic, hp, 8); hp += 8;
    uint32_t version = nvm_get_u32(&hp), layout = nvm_get_u32(&hp), entry = nvm_get_u32(&hp);
    uint32_t count = nvm_get_u32(&hp);
    uint64_t sum = nvm_get_u64(&hp);
    if (strcmp(magic, NVM_MAGIC) != 0 || version != NVM_VERSION || layout != NVK_PIPE_LAYOUT_POLICY ||
        entry != esz || count > NVM_MAX_ENTRIES ||
        (size_t)st.st_size != hdr + esz * (size_t)count) {
        close(fd);
        NVM_LOG("pipe manifest: rejected (magic/version/layout/entry/size)");
        return;
    }
    size_t bytes = esz * (size_t)count;
    uint8_t *buf = bytes ? malloc(bytes) : NULL;
    if (bytes && !buf) { close(fd); NVM_LOG("pipe manifest: rejected (alloc)"); return; }
    if (bytes && read(fd, buf, bytes) != (ssize_t)bytes) {
        free(buf); close(fd);
        NVM_LOG("pipe manifest: rejected (short read)");
        return;
    }
    close(fd);
    if (nvm_fnv64(buf, bytes) != sum) {
        free(buf);
        NVM_LOG("pipe manifest: rejected (checksum)");
        return;
    }
    for (uint32_t i = 0; i < count; i++) {
        memcpy(&g_entries[i], buf + esz * (size_t)i, esz);
        g_entries[i].recipe.device = 0;   // 进程地址不跨会话；预热只按配方字段重建
    }
    free(buf);
    g_count = g_loaded = count;
    NVM_LOG("pipe manifest: loaded %u entries from %s", count, g_path);
}

static int nvm_same(const struct nvk_pipe_recipe *a, const struct nvk_pipe_recipe *b) {
    return nvk_pipe_recipe_match(a, b) != 0;
}

void nvm_manifest_note(const struct nvk_pipe_recipe *r, const uint8_t input_sha[32]) {
    if (!g_configured || !nvm_on() || !r) return;
    struct nvk_pipe_recipe t = *r;
    t.device = 0;   // 比较/落盘都不带进程地址
    for (uint32_t i = 0; i < g_count; i++) {
        if (nvm_same(&g_entries[i].recipe, &t)) { g_dups++; return; }
    }
    if (g_count >= NVM_MAX_ENTRIES) { g_refused++; return; }
    g_entries[g_count].recipe = t;
    if (input_sha) memcpy(g_entries[g_count].input_sha, input_sha, 32);
    else memset(g_entries[g_count].input_sha, 0, 32);
    g_count++;
    g_recorded++;
    g_dirty = 1;
    // 周期性落盘：有新增且距上次 >10s 就存一次（进程被强杀最多丢最近 10s 的记录）。
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    uint64_t now = (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
    if (now - g_last_save_ns > 10000000000ull) nvm_manifest_save();
}

// 写文件 + fsync + 原子替换。快与慢都在这里；调用方决定在哪个线程跑。
static int nvm_write_file(const char *path, const uint8_t *buf, size_t bytes) {
    char tmp[600];
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) { NVM_LOG("pipe manifest: store failed (open %s)", strerror(errno)); return -1; }
    size_t off = 0;
    while (off < bytes) {
        ssize_t w = write(fd, buf + off, bytes - off);
        if (w <= 0) { close(fd); unlink(tmp); NVM_LOG("pipe manifest: store failed (write)"); return -1; }
        off += (size_t)w;
    }
    if (fsync(fd) != 0 || close(fd) != 0) { unlink(tmp); NVM_LOG("pipe manifest: store failed (fsync/close)"); return -1; }
    if (rename(tmp, path) != 0) { unlink(tmp); NVM_LOG("pipe manifest: store failed (rename %s)", strerror(errno)); return -1; }
    return 0;
}

struct nvm_save_job { char path[560]; uint8_t *buf; size_t bytes; };

static void *nvm_save_thread(void *arg) {
    struct nvm_save_job *job = arg;
    if (nvm_write_file(job->path, job->buf, job->bytes) == 0)
        NVM_LOG("pipe manifest: stored (bg) %s", job->path);
    free(job->buf); free(job);
    atomic_store(&g_saving, 0);
    return NULL;
}

// 快照 + 后台写：渲染线程只做 memcpy，fsync 不落在出帧路径上。
void nvm_manifest_save(void) {
    if (!g_configured || !g_dirty || g_count == 0) return;
    if (atomic_exchange(&g_saving, 1)) return;   // 上一份还在写：跳过这次，等下一次触发
    const size_t hdr = nvm_hdr_size();
    const size_t esz = sizeof(struct nvm_entry);
    size_t bytes = hdr + esz * (size_t)g_count;
    struct nvm_save_job *job = calloc(1, sizeof *job);
    job->buf = calloc(1, bytes);
    if (!job || !job->buf) { free(job); atomic_store(&g_saving, 0); NVM_LOG("pipe manifest: store skipped (alloc)"); return; }
    snprintf(job->path, sizeof job->path, "%s", g_path);
    job->bytes = bytes;
    uint8_t *p = job->buf;
    memset(p, 0, 8); memcpy(p, NVM_MAGIC, 6); p += 8;   // magic 前 6 字节 "S2APM1"，后 2 字节 0
    nvm_put_u32(&p, NVM_VERSION);
    nvm_put_u32(&p, NVK_PIPE_LAYOUT_POLICY);
    nvm_put_u32(&p, (uint32_t)esz);
    nvm_put_u32(&p, g_count);
    nvm_put_u64(&p, 0);   // 占位，算完回填
    for (uint32_t i = 0; i < g_count; i++) memcpy(job->buf + hdr + esz * (size_t)i, &g_entries[i], esz);
    uint64_t sum = nvm_fnv64(job->buf + hdr, esz * (size_t)g_count);
    uint8_t *sp = job->buf + 24;
    nvm_put_u64(&sp, sum);
    g_dirty = 0;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    g_last_save_ns = (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
    pthread_t th;
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&th, &at, nvm_save_thread, job) != 0) {
        pthread_attr_destroy(&at);
        nvm_save_thread(job);   // 线程起不来就同步写，正确性优先
        return;
    }
    pthread_attr_destroy(&at);
}

// 收尾用：同步写（进程要退出了，等不起后台线程）。
void nvm_manifest_save_sync(void) {
    if (!g_configured || !g_dirty || g_count == 0) return;
    const size_t hdr = nvm_hdr_size();
    const size_t esz = sizeof(struct nvm_entry);
    size_t bytes = hdr + esz * (size_t)g_count;
    uint8_t *buf = calloc(1, bytes);
    if (!buf) return;
    uint8_t *p = buf;
    memset(p, 0, 8); memcpy(p, NVM_MAGIC, 6); p += 8;
    nvm_put_u32(&p, NVM_VERSION);
    nvm_put_u32(&p, NVK_PIPE_LAYOUT_POLICY);
    nvm_put_u32(&p, (uint32_t)esz);
    nvm_put_u32(&p, g_count);
    nvm_put_u64(&p, 0);
    for (uint32_t i = 0; i < g_count; i++) memcpy(buf + hdr + esz * (size_t)i, &g_entries[i], esz);
    uint64_t sum = nvm_fnv64(buf + hdr, esz * (size_t)g_count);
    uint8_t *sp = buf + 24;
    nvm_put_u64(&sp, sum);
    if (nvm_write_file(g_path, buf, bytes) == 0) {
        g_dirty = 0;
        NVM_LOG("pipe manifest: stored (sync) %u entries to %s", g_count, g_path);
    }
    free(buf);
}

int nvm_manifest_count(void) { return (int)g_count; }

const struct nvm_entry *nvm_manifest_at(int i) {
    return (i >= 0 && (uint32_t)i < g_count) ? &g_entries[i] : NULL;
}

int nvm_manifest_take_next(struct nvm_entry *out) {
    if (!out || g_take_next >= g_count) return 0;
    *out = g_entries[g_take_next++];
    return 1;
}

void nvm_manifest_stats(uint32_t *loaded, uint32_t *recorded, uint32_t *dups, uint32_t *refused) {
    if (loaded) *loaded = g_loaded;
    if (recorded) *recorded = g_recorded;
    if (dups) *dups = g_dups;
    if (refused) *refused = g_refused;
}
