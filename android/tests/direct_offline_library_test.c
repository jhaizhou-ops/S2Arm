// F5.3 宿主回归：安装 revision 内离线程序库的只读消费（native/direct/offline_library.c）。
//
// 反例基线（任一成立，运行时就会消费到不属于本请求或已被破坏的程序）：
//   * 把“文件存在”当命中（不核容器内部身份 / 负载摘要 / 真实长度）；
//   * 只按身份找文件，不看请求的 directABI/profileHash 目录（拿另一 profile 的条目）；
//   * 命中或拒绝时改动、删除、重建 revision 里的条目（安装 revision 必须冻结）。
// 这里用假 revision 目录逐项构造：命中、缺失、目录结构损坏、摘要不符、身份不符、容器损坏、
// 冻结 revision（读取前后逐文件一致）。
//
// 容器由生产端写入路径 s2a_program_cache_store 直接写出（同一 S2APC1 v2 格式），所以本组用例
// 同时锁住“离线库 = 私有缓存格式”：program_cache.c 升版本时这里会先红。
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "direct/offline_library.h"
#include "direct/program_cache.h"
#include "direct/sha256.h"

static int fails;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL: %s\n", (what)); fails++; } } while (0)

// 两个 profile 目录 + 一个用于“坏条目必须留在原地”的目录，都是 sha256-<64 小写 hex>。
#define PROFILE_A "sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
#define PROFILE_B "sha256-fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
#define PROFILE_C "sha256-5555555555555555555555555555555555555555555555555555555555555555"
#define PROFILE_D "sha256-9999999999999999999999999999999999999999999999999999999999999999"

static char g_base[256], g_root[320], g_dir_a[420], g_dir_b[420], g_dir_c[420];
static uint8_t g_id_a[32], g_id_b[32];
static uint8_t g_payload_a[4096], g_payload_b[2048];

static void seed(uint8_t *p, size_t n, uint8_t key) {
    for (size_t i = 0; i < n; i++) p[i] = (uint8_t)(key + i * 7u + (i >> 3));
}

static int copy_path(const char *src, const char *dst) {
    int in = open(src, O_RDONLY);
    if (in < 0) return -1;
    int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (out < 0) { close(in); return -1; }
    char buf[4096];
    ssize_t n;
    while ((n = read(in, buf, sizeof buf)) > 0)
        if (write(out, buf, (size_t)n) != n) { close(in); close(out); return -1; }
    close(in);
    close(out);
    return n < 0 ? -1 : 0;
}

static void hex64(const uint8_t sha[32], char out[65]) {
    static const char *d = "0123456789abcdef";
    for (int i = 0; i < 32; i++) { out[2 * i] = d[sha[i] >> 4]; out[2 * i + 1] = d[sha[i] & 15]; }
    out[64] = 0;
}

static int make_dirs(const char *path) {
    char tmp[1024];
    if (!path || strlen(path) >= sizeof tmp) return -1;
    snprintf(tmp, sizeof tmp, "%s", path);
    for (char *p = tmp + 1; *p; p++) {
        if (*p != '/') continue;
        *p = 0;
        if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
        *p = '/';
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
    return 0;
}

static int remove_path(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0) return errno == ENOENT ? 0 : -1;
    if (S_ISDIR(st.st_mode)) return rmdir(path);
    return unlink(path);
}

static void remove_tree(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0) return;
    if (!S_ISDIR(st.st_mode)) { unlink(path); return; }
    DIR *d = opendir(path);
    if (d) {
        struct dirent *e;
        while ((e = readdir(d)) != NULL) {
            if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
            char child[1024];
            snprintf(child, sizeof child, "%s/%s", path, e->d_name);
            remove_tree(child);
        }
        closedir(d);
    }
    rmdir(path);
}

static int write_file(const char *path, const void *data, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    size_t w = fwrite(data, 1, len, f);
    int rc = fclose(f);
    return (w == len && rc == 0) ? 0 : -1;
}

static int patch_file(const char *path, long off, const void *data, size_t len) {
    FILE *f = fopen(path, "r+b");
    if (!f) return -1;
    int ok = fseek(f, off, SEEK_SET) == 0 && fwrite(data, 1, len, f) == len;
    if (fclose(f) != 0) ok = 0;
    return ok ? 0 : -1;
}

static int append_byte(const char *path, uint8_t v) {
    FILE *f = fopen(path, "ab");
    if (!f) return -1;
    int ok = fputc((int)v, f) != EOF;
    if (fclose(f) != 0) ok = 0;
    return ok ? 0 : -1;
}

static void entry_path(const char *dir, const uint8_t id[32], char *out, size_t n) {
    char hex[65];
    hex64(id, hex);
    snprintf(out, n, "%s/%s.program", dir, hex);
}

static int store(const char *dir, const uint8_t id[32], const uint8_t *bytes, size_t len, const char *what) {
    char why[192] = "";
    int rc = s2a_program_cache_store(dir, id, bytes, len, why, sizeof why);
    if (rc != 0) printf("FAIL: store entry (%s): %s\n", what, why);
    fails += rc != 0;
    return rc;
}

static int fetch(const char *root, const uint8_t id[32], uint32_t abi, const char *profile,
                 struct s2a_offline_program *out, char *why, size_t why_size) {
    struct s2a_offline_request req;
    memset(&req, 0, sizeof req);
    memcpy(req.identity, id, 32);
    req.direct_abi = abi;
    req.profile_hash = profile;
    req.profile_declared = 1;
    return s2a_offline_library_fetch(root, &req, out, why, why_size);
}

struct counts { uint64_t hits, misses, rejects; };

static struct counts counts_now(void) {
    struct counts c;
    c.hits = s2a_offline_hits();
    c.misses = s2a_offline_misses();
    c.rejects = s2a_offline_rejects();
    return c;
}

static void expect_counts(struct counts before, uint64_t dh, uint64_t dm, uint64_t dr, const char *what) {
    struct counts now = counts_now();
    uint64_t ah = now.hits - before.hits, am = now.misses - before.misses, ar = now.rejects - before.rejects;
    if (ah != dh || am != dm || ar != dr) {
        printf("FAIL: counters after %s: hit +%llu miss +%llu reject +%llu (want +%llu/+%llu/+%llu)\n",
               what, (unsigned long long)ah, (unsigned long long)am, (unsigned long long)ar,
               (unsigned long long)dh, (unsigned long long)dm, (unsigned long long)dr);
        fails++;
    }
}

// ---- revision 冻结快照：逐文件（相对路径、长度、SHA-256）排序后比对 ----
#define SNAP_MAX 64
struct snapshot {
    char lines[SNAP_MAX][768];
    int n;
};

static int hash_file(const char *path, char out[65]) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    s2a_sha256 ctx;
    s2a_sha256_init(&ctx);
    if (fseek(f, 0, SEEK_SET) != 0) { fclose(f); return -1; }
    uint8_t buf[4096];
    size_t n = 0;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) s2a_sha256_update(&ctx, buf, n);
    int bad = ferror(f);
    fclose(f);
    if (bad) return -1;
    uint8_t digest[32];
    s2a_sha256_final(&ctx, digest);
    s2a_sha256_hex(digest, out);
    return 0;
}

static void snap_walk(const char *dir, const char *rel, struct snapshot *s) {
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char path[1024], child[512];
        snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
        if (rel[0]) snprintf(child, sizeof child, "%s/%s", rel, e->d_name);
        else snprintf(child, sizeof child, "%s", e->d_name);
        struct stat st;
        if (lstat(path, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) { snap_walk(path, child, s); continue; }
        char hex[65];
        if (hash_file(path, hex) != 0) continue;
        if (s->n < SNAP_MAX)
            snprintf(s->lines[s->n++], sizeof s->lines[0], "%s\t%lld\t%s", child, (long long)st.st_size, hex);
    }
    closedir(d);
}

static int line_cmp(const void *a, const void *b) { return strcmp((const char *)a, (const char *)b); }

static void snapshot_tree(const char *root, struct snapshot *s) {
    memset(s, 0, sizeof *s);
    snap_walk(root, "", s);
    qsort(s->lines, (size_t)s->n, sizeof s->lines[0], line_cmp);
}

static int snap_equal(const struct snapshot *a, const struct snapshot *b) {
    if (a->n != b->n) return 0;
    for (int i = 0; i < a->n; i++)
        if (strcmp(a->lines[i], b->lines[i]) != 0) return 0;
    return 1;
}

static void expect_frozen(const char *what) {
    struct snapshot before, after;
    snapshot_tree(g_root, &before);
    // 冻结用例只在内部做读取；这里顺序执行“命中 / 缺失 / 拒绝”各一次。
    struct s2a_offline_program p;
    char why[256] = "";
    struct counts c0 = counts_now();
    CHECK(fetch(g_root, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_HIT, what);
    free(p.bytes);
    CHECK(fetch(g_root, g_id_b, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_MISS, what);
    CHECK(fetch(g_root, g_id_a, 1, PROFILE_C, &p, why, sizeof why) == S2A_OFFLINE_REJECT, what);
    expect_counts(c0, 1, 1, 1, what);
    snapshot_tree(g_root, &after);
    if (!snap_equal(&before, &after)) {
        printf("FAIL: %s: the revision tree changed (%d -> %d files)\n", what, before.n, after.n);
        for (int i = 0; i < before.n || i < after.n; i++) {
            const char *a = i < before.n ? before.lines[i] : "<missing>";
            const char *b = i < after.n ? after.lines[i] : "<missing>";
            if (strcmp(a, b) != 0) printf("  before: %s\n  after : %s\n", a, b);
        }
        fails++;
    }
}

int main(void) {
    char tmpl[] = "/tmp/s2a-offline-lib-XXXXXX";
    char *base = mkdtemp(tmpl);
    if (!base) { printf("FAIL: mkdtemp\n"); return 1; }
    snprintf(g_base, sizeof g_base, "%s", base);
    snprintf(g_root, sizeof g_root, "%s/revision", g_base);
    snprintf(g_dir_a, sizeof g_dir_a, "%s/shaders/vulkan/direct/1/%s", g_root, PROFILE_A);
    snprintf(g_dir_b, sizeof g_dir_b, "%s/shaders/vulkan/direct/1/%s", g_root, PROFILE_B);
    snprintf(g_dir_c, sizeof g_dir_c, "%s/shaders/vulkan/direct/1/%s", g_root, PROFILE_C);
    CHECK(make_dirs(g_dir_a) == 0 && make_dirs(g_dir_b) == 0 && make_dirs(g_dir_c) == 0,
          "create the fake installed revision tree");

    seed(g_id_a, sizeof g_id_a, 0x11);
    seed(g_id_b, sizeof g_id_b, 0x40);
    seed(g_payload_a, sizeof g_payload_a, 0x21);
    seed(g_payload_b, sizeof g_payload_b, 0x61);

    CHECK(store(g_dir_a, g_id_a, g_payload_a, sizeof g_payload_a, "A under profile A") == 0,
          "program_cache writer produces the A entry");
    CHECK(store(g_dir_b, g_id_b, g_payload_b, sizeof g_payload_b, "B under profile B") == 0,
          "program_cache writer produces the B entry");
    CHECK(store(g_dir_c, g_id_a, g_payload_a, sizeof g_payload_a, "corrupt-able entry") == 0,
          "program_cache writer produces the profile C entry");

    char path_a[520], path_c[520];
    entry_path(g_dir_a, g_id_a, path_a, sizeof path_a);
    entry_path(g_dir_c, g_id_a, path_c, sizeof path_c);

    struct s2a_offline_program p;
    char why[256] = "";

    // --- 1. 命中：同一容器，与私有缓存 loader 逐字节互认 ---
    {
        struct s2a_offline_request unlisted = {0};
        memcpy(unlisted.identity, g_id_a, 32);
        unlisted.direct_abi = 1;
        unlisted.profile_hash = PROFILE_A;
        struct counts c0 = counts_now();
        CHECK(s2a_offline_library_fetch(g_root, &unlisted, &p, why, sizeof why) == S2A_OFFLINE_MISS,
              "unlisted live profile misses even when a valid file exists");
        CHECK(p.bytes == NULL && p.len == 0, "unlisted profile returns no bytes");
        expect_counts(c0, 0, 1, 0, "unlisted profile");
    }
    {
        struct counts c0 = counts_now();
        memset(&p, 0, sizeof p);
        CHECK(fetch(g_root, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_HIT, "identical identity hits");
        CHECK(p.bytes && p.len == sizeof g_payload_a && !memcmp(p.bytes, g_payload_a, p.len),
              "hit returns the container payload bytes");
        CHECK(why[0] == 0, "a hit leaves no rejection reason");
        {
            uint8_t want[32];
            s2a_sha256 ctx;
            s2a_sha256_init(&ctx);
            s2a_sha256_update(&ctx, g_payload_a, sizeof g_payload_a);
            s2a_sha256_final(&ctx, want);
            CHECK(!memcmp(p.result_sha, want, 32), "hit returns the verified payload digest");
        }
        expect_counts(c0, 1, 0, 0, "offline hit");

        // 运行时的私有缓存 loader 读同一目录同一身份必须得到同一份字节与摘要：
        // F5.3 是“同一格式换目录”，不是另造一种库格式。
        uint8_t *cbytes = NULL;
        size_t clen = 0;
        uint8_t csha[32];
        char cwhy[192] = "";
        CHECK(s2a_program_cache_load(g_dir_a, g_id_a, &cbytes, &clen, csha, cwhy, sizeof cwhy) == 0,
              "program_cache loader accepts the same entry");
        CHECK(clen == p.len && cbytes && !memcmp(cbytes, p.bytes, clen) && !memcmp(csha, p.result_sha, 32),
              "offline reader and program_cache loader agree byte for byte");
        free(cbytes);
        free(p.bytes);
        p.bytes = NULL;
    }

    // --- 2. 缺失：身份不在库、目录/ABI/profile 不对、revision 不存在都应 miss ---
    {
        struct counts c0 = counts_now();
        CHECK(fetch(g_root, g_id_b, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_MISS,
              "identity absent from this profile directory misses");
        CHECK(strstr(why, "未命中") != NULL, "a miss says so (identified by path)");
        CHECK(p.bytes == NULL && p.len == 0, "a miss leaves outputs empty");
        expect_counts(c0, 0, 1, 0, "missing identity");

        c0 = counts_now();
        CHECK(fetch(g_root, g_id_a, 2, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_MISS,
              "another directABI directory misses (path is <abi>/<profileHash>)");
        CHECK(fetch(g_root, g_id_a, 1, PROFILE_B, &p, why, sizeof why) == S2A_OFFLINE_MISS,
              "another profile directory with a different identity misses");
        expect_counts(c0, 0, 2, 0, "wrong abi/profile directory");

        c0 = counts_now();
        char absent[320];
        snprintf(absent, sizeof absent, "%s/no-such-revision", g_base);
        CHECK(fetch(absent, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_MISS,
              "a revision without the direct library misses instead of failing");
        expect_counts(c0, 0, 1, 0, "revision without a library");

        // 同一 profile 目录下只有 B 的条目时，按 A 查不能“找到什么就用什么”。
        c0 = counts_now();
        CHECK(fetch(g_root, g_id_a, 1, PROFILE_B, &p, why, sizeof why) == S2A_OFFLINE_MISS,
              "a directory holding only another identity does not hit");
        expect_counts(c0, 0, 1, 0, "directory with only other identities");
    }

    // --- 2b. 路径结构：缺层是 miss；层是普通文件/符号链接必须拒绝，不能当成“没有” ---
    {
        char root2[320], root3[320], root4[320], dir[420], file[420], linkd[460];
        struct counts c0 = counts_now();
        snprintf(root2, sizeof root2, "%s/revision-broken-direct", g_base);
        snprintf(dir, sizeof dir, "%s/shaders/vulkan", root2);
        CHECK(make_dirs(dir) == 0, "build a revision whose direct layer is a file");
        snprintf(file, sizeof file, "%s/shaders/vulkan/direct", root2);
        CHECK(write_file(file, "not a directory", 15) == 0, "put a file where shaders/vulkan/direct belongs");
        CHECK(fetch(root2, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_REJECT,
              "a direct layer that is a file is rejected, not reported as missing");
        CHECK(strstr(why, "不是目录") != NULL, "the non-directory layer is named");
        expect_counts(c0, 0, 0, 1, "direct layer is a file");

        c0 = counts_now();
        snprintf(root3, sizeof root3, "%s/revision-broken-abi", g_base);
        snprintf(dir, sizeof dir, "%s/shaders/vulkan/direct", root3);
        CHECK(make_dirs(dir) == 0, "build a revision whose abi layer is a file");
        snprintf(file, sizeof file, "%s/shaders/vulkan/direct/1", root3);
        CHECK(write_file(file, "not a directory", 15) == 0, "put a file where <abi> belongs");
        CHECK(fetch(root3, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_REJECT,
              "an abi layer that is a file is rejected, not reported as missing");
        CHECK(strstr(why, "不是目录") != NULL, "the non-directory abi layer is named");
        expect_counts(c0, 0, 0, 1, "abi layer is a file");

        c0 = counts_now();
        snprintf(root4, sizeof root4, "%s/revision-empty", g_base);
        CHECK(make_dirs(root4) == 0, "build a revision without any shader layer");
        CHECK(fetch(root4, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_MISS,
              "a revision without a shader layer is a miss, not a rejection");
        expect_counts(c0, 0, 1, 0, "revision without a shader layer");

        c0 = counts_now();
        snprintf(linkd, sizeof linkd, "%s/shaders/vulkan/direct/1/%s", g_root, PROFILE_D);
        CHECK(symlink(g_dir_a, linkd) == 0, "point a profile directory at another profile directory");
        CHECK(fetch(g_root, g_id_a, 1, PROFILE_D, &p, why, sizeof why) == S2A_OFFLINE_REJECT,
              "a symlinked profile directory is rejected instead of followed");
        CHECK(strstr(why, "符号链接") != NULL, "the symlinked directory component is named");
        expect_counts(c0, 0, 0, 1, "symlinked profile directory");
        CHECK(unlink(linkd) == 0, "remove the symlinked profile directory");
    }

    // --- 2b. 条目符号链接：指向 revision 内（导入器的内容库格式）= 接受；指向库外 = 拒绝 ---
    {
        char store_dir[520], store_file[620], outside[620];
        struct counts c0 = counts_now();
        snprintf(store_dir, sizeof store_dir, "%s/store", g_root);
        CHECK(make_dirs(store_dir) == 0, "create a content store inside the revision");
        snprintf(store_file, sizeof store_file, "%s/a.program", store_dir);
        CHECK(copy_path(path_a, store_file) == 0, "copy the valid entry into the revision store");
        CHECK(unlink(path_a) == 0, "remove the real entry");
        CHECK(symlink(store_file, path_a) == 0, "point the entry at the in-revision store");
        CHECK(fetch(g_root, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_HIT,
              "an entry symlink resolving inside the revision is accepted");
        CHECK(p.bytes && p.len == sizeof g_payload_a, "the accepted link returns the container payload");
        expect_counts(c0, 1, 0, 0, "in-revision entry symlink");
        CHECK(unlink(path_a) == 0, "remove the in-revision link");

        snprintf(outside, sizeof outside, "%s/outside.program", g_base);
        CHECK(copy_path(store_file, outside) == 0, "copy the container outside the revision");
        CHECK(symlink(outside, path_a) == 0, "point the entry outside the revision");
        c0 = counts_now();
        CHECK(fetch(g_root, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_HIT,
              "an entry symlink whose target is a valid container is accepted (App content store)");
        CHECK(p.bytes && p.len == sizeof g_payload_a, "the accepted outside link returns the payload");
        expect_counts(c0, 1, 0, 0, "entry symlink to the app content store");
        CHECK(unlink(path_a) == 0, "remove the outside link");

        // 链接目标不是合法容器（这里写原始 payload，没有容器头）→ 必须按内容拒绝，
        // 不能因为“能打开”就当命中。
        char bogus[620];
        snprintf(bogus, sizeof bogus, "%s/bogus.program", g_base);
        CHECK(write_file(bogus, g_payload_a, sizeof g_payload_a) == 0, "write a non-container target");
        CHECK(symlink(bogus, path_a) == 0, "point the entry at the non-container");
        c0 = counts_now();
        CHECK(fetch(g_root, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_REJECT,
              "a symlink target that is not a container is rejected");
        CHECK(p.bytes == NULL && p.len == 0, "a rejected link returns no bytes");
        expect_counts(c0, 0, 0, 1, "entry symlink to a non-container");
        CHECK(unlink(path_a) == 0, "remove the bogus link");
        CHECK(copy_path(store_file, path_a) == 0, "restore the real A entry");
    }

    // --- 3. 身份不符：文件被改名/串身份（容器内部身份 != 请求身份）---
    {
        uint8_t id_b_copy[32];
        memcpy(id_b_copy, g_id_b, 32);
        CHECK(patch_file(path_a, 16, id_b_copy, 32) == 0, "rewrite the container identity");
        struct counts c0 = counts_now();
        CHECK(fetch(g_root, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_REJECT,
              "an entry whose internal identity differs is rejected");
        CHECK(strstr(why, "身份") != NULL, "identity mismatch is reported as an identity problem");
        CHECK(p.bytes == NULL && p.len == 0, "a rejection returns no bytes");
        expect_counts(c0, 0, 0, 1, "identity mismatch");
        CHECK(store(g_dir_a, g_id_a, g_payload_a, sizeof g_payload_a, "restore A") == 0, "restore the A entry");
    }

    // --- 4. 摘要不符：负载翻一个字节，头部 identity 仍对 ---
    {
        uint8_t bad = (uint8_t)(g_payload_a[100] ^ 0xFF);
        CHECK(patch_file(path_a, 88 + 100, &bad, 1) == 0, "flip one payload byte");
        struct counts c0 = counts_now();
        CHECK(fetch(g_root, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_REJECT,
              "a payload digest mismatch is rejected");
        CHECK(strstr(why, "摘要") != NULL, "digest mismatch is reported as a digest problem");
        expect_counts(c0, 0, 0, 1, "payload digest mismatch");
        CHECK(store(g_dir_a, g_id_a, g_payload_a, sizeof g_payload_a, "restore A") == 0, "restore the A entry");
    }

    // --- 5. 容器损坏：magic/版本/声明长度/截断/多余字节/符号链接/目录 ---
    {
        uint8_t x = 'X';
        struct counts c0 = counts_now();
        CHECK(patch_file(path_a, 0, &x, 1) == 0, "damage the magic");
        CHECK(fetch(g_root, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_REJECT,
              "a wrong magic is rejected");
        CHECK(strstr(why, "magic") != NULL, "the wrong magic is named in the reason");
        expect_counts(c0, 0, 0, 1, "bad magic");
        CHECK(store(g_dir_a, g_id_a, g_payload_a, sizeof g_payload_a, "restore A") == 0, "restore the A entry");

        uint8_t v1[4] = { 1, 0, 0, 0 };
        c0 = counts_now();
        CHECK(patch_file(path_a, 8, v1, 4) == 0, "downgrade the container version");
        CHECK(fetch(g_root, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_REJECT,
              "an older container version is rejected instead of guessed compatible");
        CHECK(strstr(why, "版本") != NULL, "the version mismatch is named in the reason");
        expect_counts(c0, 0, 0, 1, "old container version");
        CHECK(store(g_dir_a, g_id_a, g_payload_a, sizeof g_payload_a, "restore A") == 0, "restore the A entry");

        uint8_t h87[4] = { 87, 0, 0, 0 };
        c0 = counts_now();
        CHECK(patch_file(path_a, 12, h87, 4) == 0, "change the declared header size");
        CHECK(fetch(g_root, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_REJECT,
              "a header size other than 88 is rejected");
        CHECK(strstr(why, "版本") != NULL, "the header mismatch is reported with the version fields");
        expect_counts(c0, 0, 0, 1, "wrong header size");
        CHECK(store(g_dir_a, g_id_a, g_payload_a, sizeof g_payload_a, "restore A") == 0, "restore the A entry");

        uint8_t zero8[8] = { 0 };
        c0 = counts_now();
        CHECK(patch_file(path_a, 80, zero8, 8) == 0, "declare a zero payload length");
        CHECK(fetch(g_root, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_REJECT,
              "a zero payload length is rejected");
        CHECK(strstr(why, "越界") != NULL, "the out-of-range length is named");
        expect_counts(c0, 0, 0, 1, "zero payload length");
        CHECK(store(g_dir_a, g_id_a, g_payload_a, sizeof g_payload_a, "restore A") == 0, "restore the A entry");

        uint8_t huge8[8] = { 1, 0, 0, 4, 0, 0, 0, 0 };   // 64 MiB + 1
        c0 = counts_now();
        CHECK(patch_file(path_a, 80, huge8, 8) == 0, "declare an oversized payload length");
        CHECK(fetch(g_root, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_REJECT,
              "a payload above the 64 MiB cap is rejected");
        CHECK(strstr(why, "越界") != NULL, "the oversized length is named");
        expect_counts(c0, 0, 0, 1, "oversized payload length");
        CHECK(store(g_dir_a, g_id_a, g_payload_a, sizeof g_payload_a, "restore A") == 0, "restore the A entry");

        c0 = counts_now();
        CHECK(truncate(path_a, 40) == 0, "truncate the entry below the header");
        CHECK(fetch(g_root, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_REJECT,
              "a file shorter than the header is rejected");
        CHECK(strstr(why, "短于") != NULL, "the short header is named");
        expect_counts(c0, 0, 0, 1, "file shorter than the header");
        CHECK(store(g_dir_a, g_id_a, g_payload_a, sizeof g_payload_a, "restore A") == 0, "restore the A entry");

        c0 = counts_now();
        CHECK(truncate(path_a, 88 + 10) == 0, "truncate the payload");
        CHECK(fetch(g_root, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_REJECT,
              "a payload shorter than the declared length is rejected");
        CHECK(strstr(why, "长度") != NULL, "the truncated length is named");
        expect_counts(c0, 0, 0, 1, "truncated payload");
        CHECK(store(g_dir_a, g_id_a, g_payload_a, sizeof g_payload_a, "restore A") == 0, "restore the A entry");

        c0 = counts_now();
        CHECK(append_byte(path_a, 0x7F) == 0, "append a byte after the payload");
        CHECK(fetch(g_root, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_REJECT,
              "a file longer than the declared length is rejected");
        CHECK(strstr(why, "长度") != NULL, "the longer file is named");
        expect_counts(c0, 0, 0, 1, "file longer than declared");
        CHECK(store(g_dir_a, g_id_a, g_payload_a, sizeof g_payload_a, "restore A") == 0, "restore the A entry");

        c0 = counts_now();
        CHECK(remove_path(path_a) == 0 && mkdir(path_a, 0755) == 0, "put a directory where the entry belongs");
        CHECK(fetch(g_root, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_REJECT,
              "a directory named like an entry is rejected");
        CHECK(strstr(why, "普通文件") != NULL, "the non-regular entry is named");
        expect_counts(c0, 0, 0, 1, "entry is a directory");
        CHECK(remove_path(path_a) == 0, "remove the directory entry");
        CHECK(store(g_dir_a, g_id_a, g_payload_a, sizeof g_payload_a, "restore A") == 0, "restore the A entry");

        c0 = counts_now();
        CHECK(remove_path(path_a) == 0 && mkfifo(path_a, 0644) == 0, "put a FIFO where the entry belongs");
        CHECK(fetch(g_root, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_REJECT,
              "a FIFO named like an entry is rejected without blocking");
        CHECK(strstr(why, "普通文件") != NULL, "the FIFO entry is named as non-regular");
        expect_counts(c0, 0, 0, 1, "entry is a FIFO");
        CHECK(remove_path(path_a) == 0, "remove the FIFO entry");
        CHECK(store(g_dir_a, g_id_a, g_payload_a, sizeof g_payload_a, "restore A") == 0, "restore the A entry");

        c0 = counts_now();
        char outside[280], outside_copy[360];
        snprintf(outside, sizeof outside, "%s/outside", g_base);
        snprintf(outside_copy, sizeof outside_copy, "%s/outside/entry.program", g_base);
        CHECK(make_dirs(outside) == 0 && write_file(outside_copy, g_payload_a, sizeof g_payload_a) == 0,
              "write the symlink target");
        CHECK(remove_path(path_a) == 0 && symlink(outside_copy, path_a) == 0, "point the entry at a symlink");
        CHECK(fetch(g_root, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_REJECT,
              "a symlinked entry to a non-container is rejected by content, not followed blindly");
        CHECK(p.bytes == NULL && p.len == 0, "the rejected link returns no bytes");
        expect_counts(c0, 0, 0, 1, "entry is a symlink");
        CHECK(remove_path(path_a) == 0, "remove the symlink");
        CHECK(store(g_dir_a, g_id_a, g_payload_a, sizeof g_payload_a, "restore A") == 0, "restore the A entry");
    }

    // --- 6. 拒绝之后恢复：同一个位置再命中，不能有残留状态 ---
    {
        struct counts c0 = counts_now();
        CHECK(fetch(g_root, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_HIT,
              "the restored entry hits again");
        CHECK(p.bytes && p.len == sizeof g_payload_a && !memcmp(p.bytes, g_payload_a, p.len),
              "the restored entry returns the original bytes");
        free(p.bytes);
        expect_counts(c0, 1, 0, 0, "recovery hit");
    }

    // --- 7. 参数错误：不计入任何计数（这是调用方 bug，不是库的状态）---
    {
        struct counts c0 = counts_now();
        struct s2a_offline_request req;
        memset(&req, 0, sizeof req);
        memcpy(req.identity, g_id_a, 32);
        req.direct_abi = 1;
        req.profile_hash = PROFILE_A;
        CHECK(s2a_offline_library_fetch(NULL, &req, &p, why, sizeof why) == S2A_OFFLINE_INVALID,
              "a null revision root is an argument error");
        CHECK(s2a_offline_library_fetch("relative/revision", &req, &p, why, sizeof why) == S2A_OFFLINE_INVALID,
              "a relative revision root is an argument error");
        CHECK(s2a_offline_library_fetch(g_root, NULL, &p, why, sizeof why) == S2A_OFFLINE_INVALID,
              "a null request is an argument error");
        CHECK(s2a_offline_library_fetch(g_root, &req, NULL, why, sizeof why) == S2A_OFFLINE_INVALID,
              "a null output is an argument error");
        req.direct_abi = 0;
        CHECK(s2a_offline_library_fetch(g_root, &req, &p, why, sizeof why) == S2A_OFFLINE_INVALID,
              "directABI 0 is an argument error");
        req.direct_abi = 1;
        req.profile_hash = "sha256-xyz";
        CHECK(s2a_offline_library_fetch(g_root, &req, &p, why, sizeof why) == S2A_OFFLINE_INVALID,
              "a short profileHash is an argument error");
        {
            char bad[72];
            memset(bad, 'A', sizeof bad - 1);
            bad[0] = 's'; bad[1] = 'h'; bad[2] = 'a'; bad[3] = '2'; bad[4] = '5'; bad[5] = '6'; bad[6] = '-';
            bad[71] = 0;
            req.profile_hash = bad;
            CHECK(s2a_offline_library_fetch(g_root, &req, &p, why, sizeof why) == S2A_OFFLINE_INVALID,
                  "an uppercase profileHash is an argument error");
        }
        {
            char bad[72];
            snprintf(bad, sizeof bad, "sha256-");
            memset(bad + 7, '/', 64);
            bad[71] = 0;
            req.profile_hash = bad;
            CHECK(s2a_offline_library_fetch(g_root, &req, &p, why, sizeof why) == S2A_OFFLINE_INVALID,
                  "a path separator in profileHash is an argument error (no traversal)");
        }
        expect_counts(c0, 0, 0, 0, "argument errors");
    }

    // --- 8. 结尾斜杠等价：目录形状不影响定位 ---
    {
        char with_slash[336];
        snprintf(with_slash, sizeof with_slash, "%s/", g_root);
        struct counts c0 = counts_now();
        CHECK(fetch(with_slash, g_id_a, 1, PROFILE_A, &p, why, sizeof why) == S2A_OFFLINE_HIT,
              "a revision root with a trailing slash hits the same entry");
        free(p.bytes);
        expect_counts(c0, 1, 0, 0, "trailing slash root");
    }

    // --- 9. 冻结 revision：读取（含坏条目被拒）前后逐文件不变，坏条目留在原地 ---
    {
        uint8_t bad = (uint8_t)(g_payload_a[7] ^ 0x5A);
        CHECK(store(g_dir_c, g_id_a, g_payload_a, sizeof g_payload_a, "profile C entry") == 0,
              "prepare the never-repaired corrupt entry");
        CHECK(patch_file(path_c, 88 + 7, &bad, 1) == 0, "corrupt the profile C entry");
        expect_frozen("frozen revision (reads do not modify, repair or delete entries)");
    }

    // --- 10. 只读目录：没有写权限也要能命中，并且仍然不改 revision ---
    {
        CHECK(chmod(g_dir_a, 0555) == 0 && chmod(g_dir_c, 0555) == 0, "make the library directories read-only");
        expect_frozen("frozen revision with read-only library directories");
        CHECK(chmod(g_dir_a, 0755) == 0 && chmod(g_dir_c, 0755) == 0, "restore directory permissions");
    }

    if (!fails) {
        printf("direct offline library: ok (hits=%llu misses=%llu rejects=%llu)\n",
               (unsigned long long)s2a_offline_hits(),
               (unsigned long long)s2a_offline_misses(),
               (unsigned long long)s2a_offline_rejects());
    } else {
        printf("direct offline library: %d FAILURES\n", fails);
    }
    if (strncmp(g_base, "/tmp/s2a-offline-lib-", 21) == 0) remove_tree(g_base);
    return fails ? 1 : 0;
}
