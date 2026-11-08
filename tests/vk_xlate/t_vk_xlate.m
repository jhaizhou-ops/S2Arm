// 设备上 SPIR-V → MSL（graphics/metal/gal_vkx.m，乙）与出包工具 vk_shaders.py 对拍：同一批 SPIR-V，资源表那一栏逐字相同、阶段相同，
// 翻出的 MSL 在本机 Metal 现编得出入口 vk_<键>（片元有第二混合源时 vk_<键>_d 也编得出）。期望来自出包工具产出的 vk_shaders.tsv，不读被测实现。
// 用法：t_vk_xlate <vk_shaders.tsv> <SPIR-V 目录>...
#import <Metal/Metal.h>
#include <CommonCrypto/CommonDigest.h>
#include <dirent.h>
#include <sys/stat.h>
int s2a_vk_xlate(const uint32_t *code, size_t nwords, const char *key, char **msl, char **msl_d, char *res, size_t rescap, int *stage, char *err, size_t errcap);
typedef struct { char key[17], stage[5]; char *res; } row;
static row *g_rows; static int g_n;
static row *find(const char *k) { for (int i = 0; i < g_n; i++) if (!strcmp(g_rows[i].key, k)) return &g_rows[i]; return NULL; }
static int total, same, compiled, fails, skipped, absent;
static id<MTLDevice> dev;
static void one(const char *path) {
    FILE *f = fopen(path, "rb"); if (!f) return; fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
    if (n < 20 || n % 4) { fclose(f); return; }
    uint32_t *w = malloc((size_t)n); size_t got = fread(w, 1, (size_t)n, f); fclose(f);
    if (got != (size_t)n || w[0] != 0x07230203) { free(w); return; }
    uint8_t h[32]; CC_SHA256(w, (CC_LONG)n, h); char key[17]; for (int i = 0; i < 8; i++) snprintf(key + 2 * i, 3, "%02x", h[i]);
    row *r = find(key);
    char *msl, *msl_d, res[2048], err[512]; int frag;
    int rc = s2a_vk_xlate(w, (size_t)n / 4, key, &msl, &msl_d, res, sizeof res, &frag, err, sizeof err); free(w);
    if (rc == 1) { skipped++; return; }
    total++;
    if (rc) { fails++; printf("  败 %s 翻译失败：%s\n", key, err); return; }
    if (!r) { absent++; printf("  ？ %s 表里没有（出包工具没翻到这支）\n", key); }
    else if (strcmp(r->res, res) || strcmp(r->stage, frag == 1 ? "frag" : frag == 2 ? "comp" : "vert")) { fails++; printf("  败 %s 资源表不同\n    表   %s %s\n    现翻 %s %s\n", key, r->stage, r->res, frag == 1 ? "frag" : frag == 2 ? "comp" : "vert", res); }
    else same++;
    for (int v = 0; v < 2; v++) {
        const char *s = v ? msl_d : msl; if (!s) continue;
        NSError *e = nil; MTLCompileOptions *o = [MTLCompileOptions new]; o.languageVersion = MTLLanguageVersion3_1; o.mathMode = MTLMathModeRelaxed;   // 同宿主现编 vk_rt.inc（MSL 3.1）
        id<MTLLibrary> l = [dev newLibraryWithSource:@(s) options:o error:&e];
        NSString *fn = [NSString stringWithFormat:@"vk_%s%s", key, v ? "_d" : ""];
        if (!l || ![l newFunctionWithName:fn]) { fails++; printf("  败 %s%s 现编失败：%s\n", key, v ? "_d" : "", e.localizedDescription.UTF8String); }
        else if (!v) compiled++;
    }
    free(msl); free(msl_d);
}
static void walk(const char *d) {
    DIR *dp = opendir(d); if (!dp) return; struct dirent *e;
    while ((e = readdir(dp))) {
        if (e->d_name[0] == '.') continue; char p[2048]; snprintf(p, sizeof p, "%s/%s", d, e->d_name); struct stat st;
        if (stat(p, &st)) continue; if (S_ISDIR(st.st_mode)) walk(p); else one(p);
    }
    closedir(dp);
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { printf("用法：t_vk_xlate <vk_shaders.tsv> <SPIR-V 目录>...\n"); return 2; }
    dev = MTLCreateSystemDefaultDevice();
    FILE *f = fopen(argv[1], "r"); char line[8192]; int cap = 0;
    while (f && fgets(line, sizeof line, f)) {
        if (line[0] == '#') continue; char *rest = line, *k = strsep(&rest, "\t"), *st = strsep(&rest, "\t"), *rs = strsep(&rest, "\t\n");
        if (!k || !st || strlen(k) != 16) continue;
        if (g_n == cap) { cap = cap ? cap * 2 : 256; g_rows = realloc(g_rows, cap * sizeof *g_rows); }
        row *r = &g_rows[g_n++]; strcpy(r->key, k); strlcpy(r->stage, st, sizeof r->stage); r->res = strdup(rs ? rs : "");
    }
    if (f) fclose(f);
    for (int i = 2; i < argc; i++) walk(argv[i]);
    printf("%s t_vk_xlate：%d 支（跳过 Metal 没有的阶段 %d），资源表同 %d、表里没有 %d、现编出入口 %d、失败 %d\n", fails || !total ? "✗" : "✓", total, skipped, same, absent, compiled, fails);
    return fails || !total ? 1 : 0;
} }
