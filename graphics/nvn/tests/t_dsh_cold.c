// 直连冷启动清兜底目录（graphics/nvn/host/dsh_cold.inc）单测：临时目录里摆 wire/<程序号>/{mode, pso_user.tsv, shaders/{a_b.metal 10 字节, a_b.json 20 字节, vk/k.spv 30 字节}}，
// 对 shaders/ 调 dsh_cold_clear。期望（按摆放算）：删 3 个文件、60 字节；shaders/ 下不剩文件；mode 与 pso_user.tsv 还在；空串 / 不存在的目录删 0 个、不出错。
// 反证：旧代码没有 dsh_cold.inc，编不过。
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "../host/dsh_cold.inc"
static int bad;
static void put(const char *p, size_t n) { FILE *f = fopen(p, "wb"); for (size_t i = 0; i < n; i++) fputc('x', f); fclose(f); }
static int exists(const char *p) { struct stat st; return !stat(p, &st); }
#define CK(c, ...) do { if (c) printf("  ✓ " __VA_ARGS__); else { bad++; printf("  ✗ " __VA_ARGS__); } printf("\n"); } while (0)
int main(void) {
    char t[] = "/tmp/t_dsh_cold.XXXXXX"; if (!mkdtemp(t)) return 2;
    char w[300], s[320], v[340], p[400];
    snprintf(w, sizeof w, "%s/wire", t); mkdir(w, 0755); snprintf(s, sizeof s, "%s/shaders", w); mkdir(s, 0755); snprintf(v, sizeof v, "%s/vk", s); mkdir(v, 0755);
    snprintf(p, sizeof p, "%s/mode", w); put(p, 6); snprintf(p, sizeof p, "%s/pso_user.tsv", w); put(p, 5);
    snprintf(p, sizeof p, "%s/a_b.metal", s); put(p, 10); snprintf(p, sizeof p, "%s/a_b.json", s); put(p, 20); snprintf(p, sizeof p, "%s/k.spv", v); put(p, 30);
    uint64_t b = 0, n = dsh_cold_clear(s, &b);
    CK(n == 3 && b == 60, "删 %llu 个文件 %llu 字节（期望 3 个 60 字节）", (unsigned long long)n, (unsigned long long)b);
    snprintf(p, sizeof p, "%s/a_b.metal", s); int g1 = exists(p); snprintf(p, sizeof p, "%s/k.spv", v); int g2 = exists(p);
    CK(!g1 && !g2, "兜底目录（含子目录 vk/）不剩文件");
    snprintf(p, sizeof p, "%s/mode", w); int k1 = exists(p); snprintf(p, sizeof p, "%s/pso_user.tsv", w); int k2 = exists(p);
    CK(k1 && k2, "wire/<程序号>/ 下的 mode 与 pso_user.tsv 不碰");
    snprintf(p, sizeof p, "%s/nonexistent", t); uint64_t z1 = dsh_cold_clear(p, NULL), z2 = dsh_cold_clear("", NULL), z3 = dsh_cold_clear(NULL, NULL);
    CK(!z1 && !z2 && !z3, "不存在 / 空串 / 空指针：删 0 个");
    snprintf(p, sizeof p, "%s/mode", w); unlink(p); snprintf(p, sizeof p, "%s/pso_user.tsv", w); unlink(p); rmdir(v); rmdir(s); rmdir(w); rmdir(t);
    printf("%s t_dsh_cold：%d 处不符\n", bad ? "✗" : "✓", bad); return bad != 0;
}
