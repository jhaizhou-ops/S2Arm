// 程序预热清单的宿主回归（nvn_vk_prog_warm.c）：纯逻辑 + 文件层，无 GPU。
// 覆盖：首次无文件 / 记录去重与 uses / 有界淘汰最冷 / uses 热点排序 / 落盘→读回逐字段一致（含 c1）/
//       坏文件整份拒绝（magic·版本·条目大小·条数·长度·FNV·截断）/ 本局有效性整份拒绝（profile·ABI·闭包）/
//       结构坏条目只丢该条 / 落盘没变化不重写 / 统计记账 / reset。
// 期望值不来自被测实现：uses 与淘汰结果按测试自己构造的顺序手算，文件长度按格式手算（60 + n*844 + 8）。
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1   // mkdtemp / st_mtim 在严格 -std=c11 下也要可见
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "nvn_vk_prog_warm.h"
#include "nvn_plat.h"
#include "direct/compile_request.h"

static int checks, failures;
#define CHECK(cond, ...) do { checks++; if (!(cond)) { failures++; fprintf(stderr, "FAIL: "); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

// ---- 平台替身：缓存目录、调试开关、日志 ----
static char g_dir[512];
static int g_warm_max = -1;
static char g_profile[128] = "profile-A";
static char g_closure[64] = "closure-A";
static int32_t g_abi = 7;
static char g_last_red[512], g_last_info[2048];
const char *nvn_plat_dir(int which) { return which == NVN_PLAT_DIR_CACHE && g_dir[0] ? g_dir : NULL; }
int nvn_plat_flag(const char *name, int dflt) {
    if (!strcmp(name, "nvk_warm_max")) return g_warm_max >= 0 ? g_warm_max : dflt;
    return dflt;
}
void nvn_plat_log(int level, const char *cls, const char *text) {
    (void)cls;
    if (level == NVN_PLAT_LOG_RED) snprintf(g_last_red, sizeof g_last_red, "%s", text);
    snprintf(g_last_info, sizeof g_last_info, "%s", text);
}
int s2a_direct_provider_compile_context(struct s2a_direct_compile_context *out) {
    if (!g_profile[0] || !g_closure[0]) return -1;
    memset(out, 0, sizeof *out);
    out->session = 1; out->generation = 1; out->profile_json = g_profile; out->profile_bytes = strlen(g_profile);
    out->direct_abi = (uint32_t)g_abi; out->translator_closure = g_closure;
    return 0;
}

// ---- 夹具 ----
static struct nvk_prog_rec mkrec(int n, uint32_t mask) {
    struct nvk_prog_rec r;
    memset(&r, 0, sizeof r);
    for (int i = 0; i < 32; i++) r.identity[i] = (uint8_t)(n * 17 + i + 1);   // 非零
    r.stage_mask = mask;
    for (int i = 0; i < NVK_PROG_REC_STAGES; i++)
        for (int b = 0; b < 8; b++) r.keys[i][b] = (uint8_t)(n * 7 + i * 3 + b);
    r.c1_ok = (uint8_t)(mask == 1u ? 1u : mask == 3u ? 3u : 7u);
    for (int i = 0; i < NVK_PROG_REC_STAGES; i++) memset(r.c1[i], (uint8_t)(n * 3 + i), NVK_PROG_REC_C1_BYTES);
    return r;
}
static int rec_is(const struct nvk_prog_rec *r, int n) {
    struct nvk_prog_rec x = mkrec(n, r->stage_mask);
    return !memcmp(r->identity, x.identity, 32);
}
static int read_file(const char *path, uint8_t **out, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    if (n <= 0) { fclose(f); return -1; }
    uint8_t *b = (uint8_t *)malloc((size_t)n);
    if (!b) { fclose(f); return -1; }
    if (fread(b, 1, (size_t)n, f) != (size_t)n) { free(b); fclose(f); return -1; }
    fclose(f); *out = b; *len = (size_t)n;
    return 0;
}
static int write_file(const char *path, const uint8_t *buf, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    int ok = fwrite(buf, 1, len, f) == len;
    fclose(f);
    return ok ? 0 : -1;
}
static void dir_reset(void) { g_warm_max = -1; nvk_prog_warm_reset(); }
static int load_now(void) { return nvk_prog_warm_load(); }
static void stats_now(struct nvk_prog_warm_stats *s) { nvk_prog_warm_stats(s); }

int main(void) {
    char tmpl[] = "/tmp/nvk-prog-warm-XXXXXX";
    char *dir = mkdtemp(tmpl);
    CHECK(dir != NULL, "temp dir");
    if (!dir) return 1;
    snprintf(g_dir, sizeof g_dir, "%s", dir);
    char file[600];
    snprintf(file, sizeof file, "%s/programs-v1.bin", dir);

    // 1) 首次没有文件：readiness 事实齐 → 0 条（不是失败），pending 0。
    {
        nvk_prog_warm_reset();
        CHECK(load_now() == 0, "new session without a manifest loads 0 entries");
        struct nvk_prog_warm_stats s; stats_now(&s);
        CHECK(s.loaded == 0 && s.rejected == 0, "empty manifest counts nothing");
        CHECK(nvk_prog_warm_pending() == 0, "empty manifest has nothing pending");
        CHECK(!nvk_prog_warm_contains(mkrec(1, 3).identity), "empty manifest contains nothing");
    }
    // 没有缓存目录 / 上下文没就绪：返回 -1（调度器重试），不是「没有清单」。
    {
        char saved[512]; snprintf(saved, sizeof saved, "%s", g_dir);
        g_dir[0] = 0;
        CHECK(load_now() == -1, "no cache directory answers retry (-1)");
        snprintf(g_dir, sizeof g_dir, "%s", saved);
    }

    // 2) 记录去重 + uses：同一身份 note 两次 uses=2，不产生两条。
    {
        dir_reset();
        struct nvk_prog_rec a = mkrec(1, 3);
        nvk_prog_warm_note(&a);
        nvk_prog_warm_note(&a);
        struct nvk_prog_warm_stats s; stats_now(&s);
        CHECK(s.recorded == 2, "duplicate note is accepted and counted (uses bump), got %llu", (unsigned long long)s.recorded);
        nvk_prog_warm_save();
        nvk_prog_warm_reset();
        CHECK(load_now() == 1, "one identity round-trips through the manifest file");
        struct nvk_prog_rec got;
        CHECK(nvk_prog_warm_take(&got) == 1 && rec_is(&got, 1) && got.uses == 2,
              "round-trip keeps identity and uses (2), got uses=%u", (unsigned)got.uses);
        CHECK(got.c1_ok == 3 && got.c1[0][0] == 3 && got.c1[1][255] == 4, "round-trip keeps c1 bytes per stage");
        CHECK(got.stage_mask == 3 && !memcmp(got.keys[1], a.keys[1], 8), "round-trip keeps stage mask and keys");
        CHECK(nvk_prog_warm_take(&got) == 0, "cursor is exhausted after one take");
    }


    // 2b) 无 c1 的 note：真实 draw 命中「已发布」的程序时没有源快照（只有身份与阶段键），这种 note
    //     不得抹掉记录里已有的 c1（预热产品必须与真实解析逐位一致，c1 缺了 rp_draw 会跳过绘制），
    //     uses 照常 ++、keys 照旧保留。
    {
        dir_reset();
        struct nvk_prog_rec a = mkrec(1, 3);            // c1_ok=3，c1[i] 全为 n*3+i
        CHECK(a.c1_ok == 3, "fixture carries c1 for stages 0 and 1");
        nvk_prog_warm_note(&a);
        struct nvk_prog_rec b = mkrec(1, 3);
        b.c1_ok = 0;                                     // 无源快照的 note
        for (int i = 0; i < NVK_PROG_REC_STAGES; i++) memset(b.c1[i], 0xee, NVK_PROG_REC_C1_BYTES);
        nvk_prog_warm_note(&b);
        nvk_prog_warm_save();
        nvk_prog_warm_reset();
        CHECK(load_now() == 1, "c1-less note keeps exactly one record for the identity");
        struct nvk_prog_rec got;
        CHECK(nvk_prog_warm_take(&got) == 1 && rec_is(&got, 1), "c1-less note round-trips the identity");
        CHECK(got.uses == 2, "c1-less note still bumps uses (got %u)", (unsigned)got.uses);
        CHECK(got.c1_ok == 3 && got.c1[0][0] == 3 && got.c1[1][255] == 4,
              "c1-less note never erases the recorded c1 (c1_ok=%u, c1[0][0]=%u)", (unsigned)got.c1_ok, (unsigned)got.c1[0][0]);
        CHECK(got.c1[2][0] == 5, "c1-less note does not invent c1 for an unrecorded stage");
        CHECK(!memcmp(got.keys[1], a.keys[1], 8) && got.stage_mask == 3, "c1-less note keeps the recorded keys / stage mask");
    }

    // 3) 有界：上限 3 时淘汰最冷的一条（uses 最低，同 uses 最久没用），不拒绝新条目。
    {
        dir_reset();
        g_warm_max = 3;
        for (int n = 1; n <= 2; n++) { struct nvk_prog_rec r = mkrec(1, 1); nvk_prog_warm_note(&r); }   // A uses=2
        for (int n = 2; n <= 5; n++) { struct nvk_prog_rec r = mkrec(n, 1); nvk_prog_warm_note(&r); }   // B..E
        struct nvk_prog_rec a = mkrec(1, 1), b = mkrec(2, 1), c = mkrec(3, 1), d = mkrec(4, 1), e = mkrec(5, 1);
        CHECK(nvk_prog_warm_contains(a.identity), "hottest entry (uses=2) survives eviction");
        CHECK(nvk_prog_warm_contains(e.identity) && nvk_prog_warm_contains(d.identity), "newest entries survive eviction");
        CHECK(!nvk_prog_warm_contains(b.identity) && !nvk_prog_warm_contains(c.identity), "coldest entries are evicted");
        nvk_prog_warm_save();
        nvk_prog_warm_reset();
        g_warm_max = -1;
        int nloaded = load_now();
        CHECK(nloaded == 3, "bounded manifest keeps exactly the limit, got %d", nloaded);
        struct nvk_prog_rec got; int order_ok = 1; int expect[3] = {1, 5, 4};   // uses 降序，再按最近使用降序
        for (int i = 0; i < 3; i++) { if (!nvk_prog_warm_take(&got) || !rec_is(&got, expect[i])) order_ok = 0; }
        CHECK(order_ok, "hot order: uses desc, then most-recently-used (expected 1,5,4)");
        CHECK(nvk_prog_warm_pending() == 0, "take cursor drives pending to 0");
    }

    // 4) 落盘格式与「没变化不重写」：文件长度按格式手算；dirty 清掉后 save 不碰文件。
    {
        nvk_prog_warm_reset();
        for (int n = 1; n <= 2; n++) { struct nvk_prog_rec r = mkrec(n, 3); nvk_prog_warm_note(&r); }
        nvk_prog_warm_save();
        struct stat st1;
        CHECK(stat(file, &st1) == 0, "manifest file exists after save");
        CHECK((uint64_t)st1.st_size == 60ull + 2ull * 844ull + 8ull, "file size = 60 + n*844 + 8, got %lld", (long long)st1.st_size);
        struct timespec nap = {0, 30 * 1000000}; nanosleep(&nap, NULL);
        nvk_prog_warm_save();   // 没有变化：直接返回，不动文件
        struct stat st2;
        CHECK(stat(file, &st2) == 0, "manifest file still there");
        CHECK(st1.st_ino == st2.st_ino && st1.st_mtim.tv_sec == st2.st_mtim.tv_sec &&
              st1.st_mtim.tv_nsec == st2.st_mtim.tv_nsec, "save without changes does not rewrite the file");
        struct nvk_prog_rec r = mkrec(3, 3);
        nvk_prog_warm_note(&r);
        nvk_prog_warm_save();
        struct stat st3;
        CHECK(stat(file, &st3) == 0 && (uint64_t)st3.st_size == 60ull + 3ull * 844ull + 8ull,
              "save after a note rewrites the manifest");
    }

    // 5) 坏文件整份拒绝：magic / 版本 / 条目大小 / 条数 / 长度 / FNV / 截断。
    {
        uint8_t *good = NULL; size_t glen = 0;
        CHECK(read_file(file, &good, &glen) == 0 && glen == 60 + 3 * 844 + 8, "good manifest is readable");
        if (!good || glen != 60 + 3 * 844 + 8) { printf("nvn_vk_prog_warm: cannot continue without a good manifest (%d checks, %d failed)\n", checks, failures); free(good); return 1; }
        struct { const char *name; size_t len; size_t at; uint8_t v; } cases[] = {
            { "magic", glen, 0, 'X' },
            { "version", glen, 4, 9 },
            { "entry size", glen, 8, 0x41 },
            { "count", glen, 12, 4 },
            { "fnv", glen, 0, 0 },   // 特殊：改最后一个字节（下面单独处理）
        };
        for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
            uint8_t *bad = (uint8_t *)malloc(glen);
            memcpy(bad, good, glen);
            if (!strcmp(cases[i].name, "fnv")) bad[glen - 1] ^= 0xFF;
            else bad[cases[i].at] = cases[i].v;
            CHECK(write_file(file, bad, glen) == 0, "%s corruption written", cases[i].name);
            free(bad);
            nvk_prog_warm_reset();
            CHECK(load_now() == 0, "corrupt manifest (%s) is rejected as a whole", cases[i].name);
            struct nvk_prog_warm_stats s; stats_now(&s);
            CHECK(s.loaded == 0, "corrupt manifest (%s) loads 0 entries", cases[i].name);
            CHECK(g_last_red[0] != 0, "corrupt manifest (%s) reports a red line", cases[i].name);
        }
        // 截断与超长
        {
            uint8_t *bad = (uint8_t *)malloc(glen);
            memcpy(bad, good, glen);
            CHECK(write_file(file, bad, glen - 1) == 0, "truncated manifest written");
            nvk_prog_warm_reset();
            CHECK(load_now() == 0, "truncated manifest is rejected");
            uint8_t *longer = (uint8_t *)calloc(glen + 844, 1);
            memcpy(longer, good, glen);
            CHECK(write_file(file, longer, glen + 844) == 0, "oversized manifest written");
            nvk_prog_warm_reset();
            CHECK(load_now() == 0, "manifest longer than its entry count claims is rejected");
            free(longer);
            free(bad);
        }
        // 恢复好文件（后面的用例要用）
        CHECK(write_file(file, good, glen) == 0, "good manifest restored");
        free(good);
    }

    // 6) 本局有效性：profile / directABI / translator 闭包任一变化，整份拒绝（不是逐条过滤）。
    {
        for (int i = 0; i < 3; i++) {
            char saved_profile[128], saved_closure[64];
            snprintf(saved_profile, sizeof saved_profile, "%s", g_profile);
            snprintf(saved_closure, sizeof saved_closure, "%s", g_closure);
            int32_t saved_abi = g_abi;
            if (i == 0) g_profile[0] = (char)(g_profile[0] ^ 1);        // profile 原文变一个字节
            if (i == 1) g_abi = saved_abi + 1;
            if (i == 2) g_closure[0] = (char)(g_closure[0] ^ 1);        // translator 闭包变一个字节
            nvk_prog_warm_reset();
            CHECK(load_now() == 0, "manifest from another session (%s) is rejected whole", i == 0 ? "profile" : i == 1 ? "ABI" : "closure");
            struct nvk_prog_warm_stats s; stats_now(&s);
            CHECK(s.loaded == 0 && s.rejected == 3, "rejected entries are counted (%s), loaded=%llu rejected=%llu",
                  i == 0 ? "profile" : i == 1 ? "ABI" : "closure", (unsigned long long)s.loaded, (unsigned long long)s.rejected);
            snprintf(g_profile, sizeof g_profile, "%s", saved_profile);
            snprintf(g_closure, sizeof g_closure, "%s", saved_closure);
            g_abi = saved_abi;
        }
        nvk_prog_warm_reset();
        CHECK(load_now() == 3, "same session facts accept the manifest again");
    }

    // 7) 结构坏条目只丢该条：阶段掩码 0 / identity 全 0 / c1_ok 越界。
    {
        nvk_prog_warm_reset();
        for (int n = 1; n <= 3; n++) { struct nvk_prog_rec r = mkrec(n, 3); nvk_prog_warm_note(&r); }
        nvk_prog_warm_save();
        uint8_t *buf = NULL; size_t blen = 0;
        CHECK(read_file(file, &buf, &blen) == 0 && blen == 60 + 3 * 844 + 8, "manifest for malformed-entry case");
        if (buf && blen == 60 + 3 * 844 + 8) {
            size_t base = 60;
            uint32_t zero = 0;
            memcpy(buf + base + 32, &zero, 4);                       // 第 1 条 stage_mask = 0
            memset(buf + base + 844, 0, 32);                          // 第 2 条 identity 全 0
            buf[base + 2 * 844 + 60] = 0x08;                          // 第 3 条 c1_ok 有未知位
            CHECK(write_file(file, buf, blen) == 0, "malformed manifest written");
            nvk_prog_warm_reset();
            CHECK(load_now() == 0, "entries with malformed stage mask / identity / c1 bits are dropped");
            struct nvk_prog_warm_stats s; stats_now(&s);
            CHECK(s.rejected == 3, "dropped entries counted as rejected, got %llu", (unsigned long long)s.rejected);
            free(buf);
        }
    }

    // 8) 统计记账 + reset。
    {
        nvk_prog_warm_reset();
        struct nvk_prog_warm_stats s; stats_now(&s);
        CHECK(s.loaded == 0 && s.recorded == 0 && s.built == 0 && s.failed == 0 && s.draw_hits == 0 && s.draw_miss == 0,
              "reset clears the session counters");
        nvk_prog_warm_stat_build(0);
        nvk_prog_warm_stat_build(1);
        nvk_prog_warm_stat_build(-1);
        nvk_prog_warm_stat_draw_hit();
        nvk_prog_warm_stat_draw_miss();
        stats_now(&s);
        CHECK(s.built == 1 && s.retried == 1 && s.failed == 1 && s.draw_hits == 1 && s.draw_miss == 1,
              "build / draw counters are recorded (built=%llu retried=%llu failed=%llu hits=%llu miss=%llu)",
              (unsigned long long)s.built, (unsigned long long)s.retried, (unsigned long long)s.failed,
              (unsigned long long)s.draw_hits, (unsigned long long)s.draw_miss);
        nvk_prog_warm_reset();
        stats_now(&s);
        CHECK(s.built == 0 && s.draw_hits == 0, "reset clears build / draw counters too");
    }

    // 9) 同进程第二局：load 会先清场（不串局），没有文件时不会沿用上一局的条目。
    {
        dir_reset();
        struct nvk_prog_rec a = mkrec(1, 1);
        nvk_prog_warm_note(&a);
        CHECK(nvk_prog_warm_contains(a.identity), "note is visible in this session");
        unlink(file);
        CHECK(load_now() == 0, "next session: missing file loads 0");
        CHECK(!nvk_prog_warm_contains(a.identity), "next session: previous session's note is cleared");
    }

    printf("nvn_vk_prog_warm: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}