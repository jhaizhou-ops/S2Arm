// S2RF 夹具的宿主自检（t_rfx）：不依赖 Metal / 真机 / 任何图形 API。
//   1. 写一份 .rfx，读回，记录逐条一致（格式往返）；
//   2. 比对器自比绿；
//   3. 改一个字节 → 报红且位置正确（记录号 / 文件偏移）；
//   4. 截断文件 → 报「坏格式」而不是崩；
//   5. 提交的样例文件全部能解析：kind 对、以 END 收尾、期望文件首条是 ASSUME。
// 用法：t_rfx [夹具目录]（带目录时做第 5 项）。
// fileno / ftruncate / mkdtemp：-std=c11 下 glibc 不声明（macOS 照声明），Linux CTest 的 android_replay_fixture_repro 编不过（11-06）；
//   _GNU_SOURCE 在 glibc 全开、macOS 不受影响（_POSIX_C_SOURCE 反而让 macOS 藏起 mkdtemp）
#define _GNU_SOURCE
#include "rfx.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static const char *g_tmp;
static char g_paths[8][1024];
static int g_pi;
static const char *tmpf(const char *name) {   // 轮换缓冲：同一表达式里取两个路径不互踩
    snprintf(g_paths[g_pi], sizeof g_paths[0], "%s/%s", g_tmp, name);
    return g_paths[g_pi++ % 8];
}

static void write_sample_input(const char *path) {
    rfx_w *w = rfx_w_open(path, RFX_KIND_IN);
    CHECK(w != NULL, "open input");
    rfx_w_region(w, 0x10000000, 0x2000, 3);
    uint8_t cmd[64] = {0};
    cmd[4] = 8;            // 第一条 OP 的 size
    rfx_w_data(w, 0x10000000, cmd, sizeof cmd);
    rfx_call_u32(w, RFX_BE_SET_DEPTH_ZERO, 0, 1);
    rfx_call_u64(w, RFX_BE_POOL_ADD, 0, 0x10000000);
    rfx_call_sub_index(w, RFX_BE_SUB_INDEX, (uint64_t[]){0x10000000}, 1);
    rfx_call_none(w, RFX_BE_SUB_BEGIN, 0);
    rfx_call_u64(w, RFX_BE_EXEC, 0, 0x10000000);
    rfx_call_none(w, RFX_BE_SUB_COMMIT, 1);
    rfx_w_end(w);
    CHECK(rfx_w_close(w) == 0, "close input");
}

static void write_sample_exp(const char *path) {
    rfx_w *w = rfx_w_open(path, RFX_KIND_EXP);
    CHECK(w != NULL, "open exp");
    rfx_w_raw(w, RFX_REC_ASSUME, "\x0a\x00\x00\x00", 4);
    uint8_t p[24] = {0};
    *(int32_t *)p = 0;
    rfx_w_exp(w, RFX_GPU_OPEN, p, 4);
    rfx_w_exp(w, RFX_GPU_CMD_BEGIN, p, 16);
    rfx_w_exp(w, RFX_GPU_CMD_COMMIT, p, 16);
    uint8_t d[16] = {1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    rfx_w_chk(w, RFX_CHK_DONE, d, 13);
    rfx_w_end(w);
    CHECK(rfx_w_close(w) == 0, "close exp");
}

static void test_roundtrip(void) {
    const char *in = tmpf("rt.in.rfx");
    write_sample_input(in);
    rfx_r r;
    CHECK(rfx_r_open(&r, in) == 0, "read back input");
    CHECK(r.kind == RFX_KIND_IN, "kind = IN");
    CHECK(rfx_r_validate_kind(&r) == 0, "kind validation");
    rfx_rec rec;
    int n_call = 0, n_data = 0, st;
    while ((st = rfx_r_next(&r, &rec)) == 1) {
        if (rec.tag == RFX_REC_CALL) n_call++;
        if (rec.tag == RFX_REC_DATA) n_data++;
    }
    CHECK(st == 0, "ends with END");
    CHECK(n_call == 6 && n_data == 1, "record counts: call=%d data=%d", n_call, n_data);
    rfx_r_close(&r);
}

static void test_cmp_green(void) {
    const char *a = tmpf("a.exp.rfx"), *b = tmpf("b.exp.rfx");
    write_sample_exp(a);
    write_sample_exp(b);
    rfx_diff d;
    CHECK(rfx_cmp_file(a, b, NULL, 0, &d) == 0, "identical files compare green");
    CHECK(rfx_cmp_file(a, a, NULL, 0, &d) == 0, "self compare green");
}

static void test_cmp_byteflip(void) {
    const char *a = tmpf("fa.exp.rfx"), *b = tmpf("fb.exp.rfx");
    write_sample_exp(a);
    write_sample_exp(b);
    // 改 b 里 EXP CMD_COMMIT 负载的一个字节：找到该记录再改
    rfx_r r;
    CHECK(rfx_r_open(&r, b) == 0, "open b for flip");
    rfx_rec rec;
    uint64_t off = UINT64_MAX;
    int st;
    while ((st = rfx_r_next(&r, &rec)) == 1)
        if (rec.tag == RFX_REC_EXP && rec.id == RFX_GPU_CMD_COMMIT) { off = rec.off + 8 + 4 + 1; break; }
    CHECK(off != UINT64_MAX, "found commit record");
    FILE *f = fopen(b, "r+b");
    fseek(f, (long)off, SEEK_SET);
    int c = fgetc(f);
    fseek(f, (long)off, SEEK_SET);
    fputc(c ^ 0xFF, f);
    fclose(f);
    rfx_r_close(&r);
    rfx_diff d;
    CHECK(rfx_cmp_file(a, b, NULL, 0, &d) != 0, "flipped byte reported");
    CHECK(d.file_off == off, "diff offset right: got %#llx want %#llx", (unsigned long long)d.file_off, (unsigned long long)off);
    CHECK(d.id == RFX_GPU_CMD_COMMIT && d.tag == RFX_REC_EXP, "diff record right");
    CHECK(strstr(d.msg, "nvn_gpu_cmd_commit") != NULL, "diff message names function: %s", d.msg);
}

static void test_cmp_truncated(void) {
    const char *a = tmpf("ta.exp.rfx"), *b = tmpf("tb.exp.rfx");
    write_sample_exp(a);
    write_sample_exp(b);
    FILE *f = fopen(b, "r+b");
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    CHECK(ftruncate(fileno(f), n - 10) == 0, "truncate sample");   // 砍掉 END 与最后一条记录尾部（glibc 标 warn_unused_result）
    fclose(f);
    rfx_diff d;
    CHECK(rfx_cmp_file(a, b, NULL, 0, &d) != 0, "truncated file reported");
}

static void test_samples_dir(const char *dir) {
    DIR *dp = opendir(dir);
    if (!dp) { printf("样例目录 %s 打不开（第 5 项跳过）\n", dir); return; }
    struct dirent *de;
    int n_in = 0, n_exp = 0, bad = 0;
    char p[1024];
    while ((de = readdir(dp))) {
        int is_in = strstr(de->d_name, ".in.rfx") != NULL;
        int is_exp = strstr(de->d_name, ".exp.rfx") != NULL;
        if (!is_in && !is_exp) continue;
        snprintf(p, sizeof p, "%s/%s", dir, de->d_name);
        rfx_r r;
        if (rfx_r_open(&r, p)) { printf("FAIL: %s 打不开\n", p); bad++; continue; }
        if (rfx_r_validate_kind(&r)) { printf("FAIL: %s 记录与 kind 不符\n", p); bad++; }
        if (is_in) n_in++; else n_exp++;
        if (is_exp) {   // 期望文件第一条必须是 ASSUME
            rfx_rec rec;
            r.pos = 16;
            if (rfx_r_next(&r, &rec) != 1 || rec.tag != RFX_REC_ASSUME) { printf("FAIL: %s 首条不是 ASSUME\n", p); bad++; }
        }
        rfx_r_close(&r);
    }
    closedir(dp);
    CHECK(bad == 0, "sample files parse");
    CHECK(n_in > 0 && n_in == n_exp, "sample pairs: in=%d exp=%d", n_in, n_exp);
    printf("样例解析：%d 对 .in/.exp 全部合法\n", n_in);
}

int main(int argc, char **argv) {
    char tmpl[] = "/tmp/rfx-test-XXXXXX";
    g_tmp = mkdtemp(tmpl);
    CHECK(g_tmp != NULL, "mkdtemp");
    test_roundtrip();
    test_cmp_green();
    test_cmp_byteflip();
    test_cmp_truncated();
    if (argc > 1) test_samples_dir(argv[1]);
    if (fails) { printf("【红】%d 项失败\n", fails); return 1; }
    printf("✓ t_rfx：格式往返、比对器自比绿、字节翻转报位、截断报错%s\n", argc > 1 ? "、样例文件解析" : "");
    return 0;
}
