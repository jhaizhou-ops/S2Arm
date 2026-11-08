// 首遇现编耗时测量（方案第九节）：对目录里每支 <键>.spv 走与运行时同一条路（持久缓存 → SPIRV-Cross → Metal），逐支同步计时。
// 跑两遍：第 1 遍冷（持久缓存目录先清空），第 2 遍热（命中持久缓存 + Metal 系统缓存）。输出 TSV 到 stdout：遍次 键 来源 SPIRV-Cross_ms Metal_ms。
// 用法：xc_bench <SPIR-V 目录> <持久缓存目录>     （iOS 上由宿主 App 以同样参数调 xc_bench_main）
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <limits.h>
#include <mach/mach_time.h>

int gal_xc_bench_one(const void *spv, uint32_t len, double *xc_ms, double *mtl_ms, int *from_disk, char *why);   // gal_prog.m 提供
void *gal_xc_bench_start(const void *spv, uint32_t len);
int gal_xc_bench_collect(void *job, double *xc_ms, double *mtl_ms, int *from_disk, uint32_t *qos, uint32_t *active, char *why);

static int cmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }
static void pct(const char *name, double *v, int n) {
    if (!n) return; qsort(v, n, sizeof *v, cmp); double s = 0; for (int i = 0; i < n; i++) s += v[i];
    fprintf(stderr, "  %s：中位 %.2f ms，p90 %.2f，p99 %.2f，最大 %.2f，合计 %.0f ms（%d 支）\n", name, v[n / 2], v[n * 9 / 10], v[n * 99 / 100], v[n - 1], s, n);
}
// 独立进程的一遍真实后台队列；保留用户指定缓存，既不删除它，也不清系统 Metal 缓存。
// 输出实际线程 QoS / 同时在编数；耗时包含当前 OS 缓存状态，不能据一次顺序 A/B 宣称冷编收益。
static int queued_main(const char *dir, const char *cache, int limit) {
    setenv("NXGAL_SHADER_CACHE_DIR", cache, 1);
    if (nxgal_init(0)) return 2;
    NSError *error = nil;
    NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@(dir) error:&error];
    if (!files) { fprintf(stderr, "打不开 %s：%s\n", dir, error.localizedDescription.UTF8String); return 2; }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *name in files) if ([name.pathExtension isEqualToString:@"spv"] && [name componentsSeparatedByString:@"."].count == 2) [names addObject:name];
    [names sortUsingSelector:@selector(compare:)];
    int n = (int)names.count; if (limit > 0 && n > limit) n = limit;
    if (!n) { fprintf(stderr, "目录里没有普通 .spv 语料：%s\n", dir); return 2; }
    void **jobs = calloc(n, sizeof *jobs);
    double *xa = calloc(n, sizeof *xa), *ma = calloc(n, sizeof *ma);
    uint64_t start = mach_absolute_time();
    for (int i = 0; i < n; i++) {
        NSString *path = [@(dir) stringByAppendingPathComponent:names[i]];
        NSData *spv = [NSData dataWithContentsOfFile:path options:0 error:&error];
        if (!spv || spv.length > UINT32_MAX) { fprintf(stderr, "读不了 %s：%s\n", path.UTF8String, error.localizedDescription.UTF8String); return 2; }
        jobs[i] = gal_xc_bench_start(spv.bytes, (uint32_t)spv.length);
    }
    const char *q = getenv("NXGAL_XC_QOS");
    uint32_t expected = q && !strcmp(q, "utility") ? QOS_CLASS_UTILITY : QOS_CLASS_USER_INITIATED;   // 缺省 USER_INITIATED（gal_prog.m xc_init）
    uint32_t peak = 0; int ok = 0, bad_qos = 0;
    printf("# 键\t来源\tSPIRV-Cross_ms\tMetal_ms\t实际QoS\t同时在编\n");
    for (int i = 0; i < n; i++) {
        double xc, mt; int disk; uint32_t qos, active; char why[256] = "";
        int success = gal_xc_bench_collect(jobs[i], &xc, &mt, &disk, &qos, &active, why);
        if (active > peak) peak = active;
        if (qos != expected) bad_qos++;
        if (!success) { fprintf(stderr, "失败 %s：%s\n", names[i].UTF8String, why); continue; }
        printf("%s\t%s\t%.3f\t%.3f\t0x%x\t%u\n", names[i].UTF8String, disk ? "缓存" : "现编", xc, mt, qos, active);
        xa[ok] = xc; ma[ok] = mt; ok++;
    }
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    double elapsed = (double)(mach_absolute_time() - start) * tb.numer / tb.denom / 1e6;
    int slots = TARGET_OS_IPHONE ? 2 : (int)[NSProcessInfo processInfo].activeProcessorCount / 4;
    if (slots < 2) slots = 2;
    fprintf(stderr, "队列基准：%d/%d 支成功，QoS 期望 0x%x、不符 %d，峰值并发 %u/槽数 %d，墙钟 %.1f ms\n", ok, n, expected, bad_qos, peak, slots, elapsed);
    pct("SPIRV-Cross（或读缓存）", xa, ok); pct("Metal 编译", ma, ok);
    free(jobs); free(xa); free(ma);
    return ok == n && !bad_qos && peak <= (uint32_t)slots ? 0 : 1;
}
int xc_bench_main(const char *dir, const char *cache) {
    if (nxgal_init(0)) return 2;
    setenv("NXGAL_SHADER_CACHE_DIR", cache, 1);
    char cmd[2048]; snprintf(cmd, sizeof cmd, "%s", cache);
    DIR *d = opendir(cache); if (d) { struct dirent *e; while ((e = readdir(d))) if (e->d_name[0] != '.') { char p[2048]; snprintf(p, sizeof p, "%s/%s", cache, e->d_name); unlink(p); } closedir(d); }
    char **names = NULL; int n = 0;
    d = opendir(dir); if (!d) { fprintf(stderr, "打不开 %s\n", dir); return 2; }
    struct dirent *e; while ((e = readdir(d))) { size_t l = strlen(e->d_name); if (l > 4 && !strcmp(e->d_name + l - 4, ".spv")) { names = realloc(names, (n + 1) * sizeof *names); names[n++] = strdup(e->d_name); } }
    closedir(d);
    double *xa = calloc(n, sizeof *xa), *ma = calloc(n, sizeof *ma), *ta = calloc(n, sizeof *ta);
    for (int pass = 1; pass <= 2; pass++) {
        int k = 0, fails = 0;
        for (int i = 0; i < n; i++) {
            char p[2048]; snprintf(p, sizeof p, "%s/%s", dir, names[i]);
            FILE *f = fopen(p, "rb"); if (!f) continue; fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
            void *b = malloc(len); fread(b, 1, len, f); fclose(f);
            double xc, mt; int disk; char why[256] = "";
            if (gal_xc_bench_one(b, (uint32_t)len, &xc, &mt, &disk, why)) { printf("%d\t%.*s\t%s\t%.3f\t%.3f\n", pass, 16, names[i], disk ? "缓存" : "现编", xc, mt); xa[k] = xc; ma[k] = mt; ta[k] = xc + mt; k++; }
            else { fails++; fprintf(stderr, "失败 %s：%s\n", names[i], why); }
            free(b);
        }
        fprintf(stderr, "第 %d 遍（%s）：%d 支成功，%d 支失败\n", pass, pass == 1 ? "冷" : "热：持久缓存 + Metal 系统缓存", k, fails);
        pct("SPIRV-Cross（或读缓存）", xa, k); pct("Metal 编译", ma, k); pct("合计（SPIR-V 到可用）", ta, k);
    }
    return 0;
}
#if !TARGET_OS_IPHONE
int main(int argc, char **argv) {
    if ((argc == 4 || argc == 5) && !strcmp(argv[1], "--queued")) {
        long limit = 0;
        if (argc == 5) {
            char *end; limit = strtol(argv[4], &end, 10);
            if (!*argv[4] || *end || limit <= 0 || limit > INT_MAX) { fprintf(stderr, "支数上限必须为正整数\n"); return 2; }
        }
        return queued_main(argv[2], argv[3], (int)limit);
    }
    if (argc != 3) { fprintf(stderr, "用法：xc_bench <SPIR-V 目录> <持久缓存目录>\n       xc_bench --queued <SPIR-V 目录> <保留的持久缓存目录> [支数上限]\n"); return 2; }
    return xc_bench_main(argv[1], argv[2]);
}
#endif
