// F5.3：安装 revision 内离线程序库的只读消费者。合同见 offline_library.h。
//
// 容器格式与私有缓存（program_cache.c）逐字节相同：这里独立读一遍是为了把
// “未命中 / 找到但不可接受”分成两个计数并给出准确原因，也为了明确拒绝符号链接与非普通文件；
// program_cache_load 把这两类都报成 -1，且会让离线读取混进私有缓存的 hit/failure 账。
// 宿主用例 direct_offline_library_test.c 用 s2a_program_cache_store 写出的容器直接喂给本模块，
// 锁住“同一格式”；program_cache 升版本时那组用例会先红。
//
// 只读：不 mkdir、不 unlink、不写临时文件、不“修复”坏条目。安装 revision 的冻结由宿主用例
// 在读取前后逐文件比对证明。
#include "offline_library.h"

#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "sha256.h"

#define OL_MAGIC "S2APC1\n\0"
#define OL_VERSION 2u
#define OL_HEADER 88u
#define OL_MAX_PAYLOAD (64u * 1024u * 1024u)
#define OL_PATH 1024
#define OL_DIRECT_REL "/shaders/vulkan/direct"

static _Atomic uint64_t g_hits, g_misses, g_rejects;

uint64_t s2a_offline_hits(void) { return atomic_load(&g_hits); }
uint64_t s2a_offline_misses(void) { return atomic_load(&g_misses); }
uint64_t s2a_offline_rejects(void) { return atomic_load(&g_rejects); }

static void setwhy(char *why, size_t n, const char *fmt, ...) {
    if (!why || !n) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(why, n, fmt, ap);
    va_end(ap);
}

// 条目存在但不可接受：关闭 fd、计 reject、写原因。所有拒绝路径共用，计数不会漏。
static int reject(int fd, char *why, size_t why_size, const char *fmt, ...) {
    if (fd >= 0) close(fd);
    atomic_fetch_add(&g_rejects, 1);
    if (why && why_size) {
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(why, why_size, fmt, ap);
        va_end(ap);
    }
    return S2A_OFFLINE_REJECT;
}

static int miss(char *why, size_t why_size, const char *fmt, ...) {
    atomic_fetch_add(&g_misses, 1);
    if (why && why_size) {
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(why, why_size, fmt, ap);
        va_end(ap);
    }
    return S2A_OFFLINE_MISS;
}

static void hex64(const uint8_t sha[32], char out[65]) {
    static const char *d = "0123456789abcdef";
    for (int i = 0; i < 32; i++) {
        out[2 * i] = d[sha[i] >> 4];
        out[2 * i + 1] = d[sha[i] & 15];
    }
    out[64] = 0;
}

static uint32_t get_u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t get_u64(const uint8_t *p) {
    return (uint64_t)get_u32(p) | ((uint64_t)get_u32(p + 4) << 32);
}

// profileHash 只接受 "sha256-" + 64 位小写 hex（与 graphics.c / 编译器 DirectProfile 同一口径）。
// 目录名参与路径拼接，形状严格检查过才用；调用方传别的形状是 bug，不当成“未命中”。
static int valid_profile_hash(const char *text) {
    if (!text || strlen(text) != 71) return 0;
    if (memcmp(text, "sha256-", 7) != 0) return 0;
    for (int i = 7; i < 71; i++) {
        char c = text[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return 0;
    }
    return 1;
}

// <root>[/]shaders/vulkan/direct/<abi>/<profileHash>/<identity>.program
// 只接受绝对 revision 根：相对路径会跟着进程 cwd 漂移，不是“已激活 revision”。
static int build_entry_path(const char *root, const struct s2a_offline_request *request,
                            char *out, size_t out_size) {
    size_t rlen = strlen(root);
    while (rlen > 0 && root[rlen - 1] == '/') rlen--;
    if (rlen >= out_size) return -1;   // snprintf 的 %.*s 精度要装得进 int；先挡掉超长根
    char hex[65];
    hex64(request->identity, hex);
    int n = snprintf(out, out_size, "%.*s" OL_DIRECT_REL "/%lu/%s/%s.program",
                     (int)rlen, root, (unsigned long)request->direct_abi, request->profile_hash, hex);
    return (n > 0 && (size_t)n < out_size) ? 0 : -1;
}

// read 可能短读；EINTR 不算失败。返回 0 只表示读满 n 字节。
static int read_full(int fd, void *buf, size_t n) {
    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, p + got, n - got);
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (r == 0) break;
        got += (size_t)r;
    }
    return got == n ? 0 : -1;
}

int s2a_offline_library_fetch(const char *revision_root, const struct s2a_offline_request *request,
                              struct s2a_offline_program *out, char *why, size_t why_size) {
    if (out) memset(out, 0, sizeof *out);
    if (why && why_size) why[0] = 0;
    if (!revision_root || !revision_root[0] || !request || !out) {
        setwhy(why, why_size, "离线库：参数缺失（revision_root/request/out）");
        return S2A_OFFLINE_INVALID;
    }
    if (revision_root[0] != '/') {
        setwhy(why, why_size, "离线库：安装 revision 不是绝对路径：%s", revision_root);
        return S2A_OFFLINE_INVALID;
    }
    if (request->direct_abi == 0) {
        setwhy(why, why_size, "离线库：请求没有 directABI（0 不是有效值）");
        return S2A_OFFLINE_INVALID;
    }
    if (!valid_profile_hash(request->profile_hash)) {
        setwhy(why, why_size, "离线库：profileHash 不是 sha256-<64 小写 hex>");
        return S2A_OFFLINE_INVALID;
    }
    if (!request->profile_declared)
        return miss(why, why_size, "离线库未命中：live profile 未列入描述符");

    char path[OL_PATH];
    if (build_entry_path(revision_root, request, path, sizeof path)) {
        setwhy(why, why_size, "离线库：条目路径过长");
        return S2A_OFFLINE_INVALID;
    }

    // 逐级 openat 下钻，而不是把整条路径交给 open：revision 根由调用方给出（其自身路径按普通
    // 解析，视为可信），其下每一级目录都要求真目录 + O_NOFOLLOW。O_NOFOLLOW 只保护路径的最后
    // 一段，整条字符串一次 open 时中间目录是链接就会被跟出去；逐级打开还让后续的目录替换
    // 不影响已经取得的 fd（TOCTOU 面收窄）。文件名来自身份 hex，本身不含 '/'。
    const char *parts[5] = { "shaders", "vulkan", "direct", NULL, request->profile_hash };
    char abi_text[12];
    snprintf(abi_text, sizeof abi_text, "%lu", (unsigned long)request->direct_abi);
    parts[3] = abi_text;
    char hex[65];
    hex64(request->identity, hex);
    char name[80];
    snprintf(name, sizeof name, "%s.program", hex);

    int dirfd = open(revision_root, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dirfd < 0) {
        int err = errno;
        if (err == ENOENT) return miss(why, why_size, "离线库未命中：%s 不存在", path);
        return reject(-1, why, why_size, "离线库 revision 根打不开：%s（%s）", revision_root, strerror(err));
    }
    for (int i = 0; i < 5; i++) {
        int next = openat(dirfd, parts[i], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0) {
            int err = errno;
            // O_DIRECTORY 与 O_NOFOLLOW 同时给出时，Linux 对“末级是链接”报 ENOTDIR 而不是 ELOOP
            // （实测 errno=20）。这里用 AT_SYMLINK_NOFOLLOW 再确认一次，才能给出准确原因。
            int is_link = 0;
            struct stat cst;
            if ((err == ELOOP || err == ENOTDIR) &&
                fstatat(dirfd, parts[i], &cst, AT_SYMLINK_NOFOLLOW) == 0 && S_ISLNK(cst.st_mode))
                is_link = 1;
            close(dirfd);
            // 结构缺失 = 未命中（没有这一层库）；结构存在但类型错/是链接 = 拒绝，不能当成“没有”。
            if (err == ENOENT) return miss(why, why_size, "离线库未命中：%s 不存在", path);
            if (is_link || err == ELOOP)
                return reject(-1, why, why_size, "离线库路径组件是符号链接（%s；只读库不接受链接）：%s",
                              parts[i], path);
            if (err == ENOTDIR)
                return reject(-1, why, why_size, "离线库路径组件不是目录（%s）：%s", parts[i], path);
            return reject(-1, why, why_size, "离线库目录打不开（%s：%s）：%s", parts[i], strerror(err), path);
        }
        close(dirfd);
        dirfd = next;
    }
    // O_NONBLOCK：条目被换成 FIFO 时不阻塞读线程，交给下面的“不是普通文件”准确拒绝。
    int fd = openat(dirfd, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0 && errno == ELOOP) {
        // 导入器把 revision 资源存成“指向内容库的符号链接”，内容库可能在 revision 之外
        // （App 的共享存储），这是产品路径的存储格式。目录组件仍然逐级 O_NOFOLLOW，
        // 只有条目本身允许链接；链接目标可以是普通文件，但字节必须通过容器身份/长度/
        // 摘要校验，指向别的程序或非法文件都会在下面按内容拒绝，不会把替换当命中。
        char item_real[PATH_MAX];
        if (realpath(path, item_real))
            fd = open(item_real, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
        else
            return reject(-1, why, why_size, "离线库条目链接目标不存在：%s", path);
    }
    if (fd < 0) {
        int err = errno;
        close(dirfd);
        if (err == ENOENT) return miss(why, why_size, "离线库未命中：%s 不存在", path);
        if (err == ELOOP) return reject(-1, why, why_size, "离线库条目是符号链接（只读库不接受链接）：%s", path);
        return reject(-1, why, why_size, "离线库条目打不开：%s（%s）", path, strerror(err));
    }
    close(dirfd);

    struct stat st;
    if (fstat(fd, &st) != 0) return reject(fd, why, why_size, "离线库条目无法取得状态：%s", path);
    if (!S_ISREG(st.st_mode)) return reject(fd, why, why_size, "离线库条目不是普通文件：%s", path);
    if (st.st_size < (off_t)OL_HEADER)
        return reject(fd, why, why_size, "离线库条目短于 S2APC1 头部（%lld B）：%s",
                      (long long)st.st_size, path);

    uint8_t head[OL_HEADER];
    if (read_full(fd, head, sizeof head) != 0)
        return reject(fd, why, why_size, "离线库条目头部读不全：%s", path);
    if (memcmp(head, OL_MAGIC, 8) != 0)
        return reject(fd, why, why_size, "离线库条目 magic 不符（不是 S2APC1 v2 容器）：%s", path);
    uint32_t version = get_u32(head + 8), header = get_u32(head + 12);
    if (version != OL_VERSION || header != OL_HEADER)
        return reject(fd, why, why_size,
                      "离线库条目格式版本不符（version=%u header=%u，期望 %u/%u）：%s",
                      version, header, OL_VERSION, OL_HEADER, path);
    // 文件名来自请求身份，容器内部身份必须与它一致：被改名/串身份的程序不能按“正确身份”消费。
    if (memcmp(head + 16, request->identity, 32) != 0)
        return reject(fd, why, why_size, "离线库条目内部身份与请求身份不符（改名或串了身份）：%s", path);
    uint64_t len = get_u64(head + 80);
    if (len == 0 || len > OL_MAX_PAYLOAD)
        return reject(fd, why, why_size, "离线库条目负载长度越界（%llu）：%s",
                      (unsigned long long)len, path);
    if ((uint64_t)st.st_size != (uint64_t)OL_HEADER + len)
        return reject(fd, why, why_size,
                      "离线库条目长度与头部声明不符（文件 %lld B，头部声明 %llu B；截断？）：%s",
                      (long long)st.st_size, (unsigned long long)(OL_HEADER + len), path);
    uint8_t *bytes = malloc((size_t)len);
    if (!bytes)
        return reject(fd, why, why_size, "离线库条目负载分配失败（%llu B）：%s",
                      (unsigned long long)len, path);
    if (read_full(fd, bytes, (size_t)len) != 0) {
        free(bytes);
        return reject(fd, why, why_size, "离线库条目负载读不全：%s", path);
    }
    close(fd);

    uint8_t digest[32];
    s2a_sha256 ctx;
    s2a_sha256_init(&ctx);
    s2a_sha256_update(&ctx, bytes, (size_t)len);
    s2a_sha256_final(&ctx, digest);
    // 头里的 identity 只证明“这是谁的结果”；result 摘要才能发现同一身份下的字节损坏。
    if (memcmp(digest, head + 48, 32) != 0) {
        free(bytes);
        return reject(-1, why, why_size, "离线库条目结果摘要不符（字节损坏）：%s", path);
    }

    out->bytes = bytes;
    out->len = (size_t)len;
    memcpy(out->result_sha, digest, 32);
    atomic_fetch_add(&g_hits, 1);
    return S2A_OFFLINE_HIT;
}
