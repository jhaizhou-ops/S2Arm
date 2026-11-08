// shader_overlay.h 单测（外置着色器包的直连选择规则）：在临时目录里摆出各种外置包形状，期望值按规则手写，不跑被测函数算
#include "../gfx/nvn/shader_overlay.h"
#include <string.h>
#include <unistd.h>
static int bad;
static void ck(int ok, const char *what) { printf("%s %s\n", ok ? "  ok" : "  ✗", what); if (!ok) bad++; }
static void touch(const char *p) { FILE *f = fopen(p, "w"); if (f) fclose(f); }
int main(void) {
    char tmp[] = "/tmp/t_shader_overlay.XXXXXX", d[1200], p[1300], out[1200];
    if (!mkdtemp(tmp)) { perror("mkdtemp"); return 1; }
    const uint64_t pid = 0x0100abcd00010000ull; const char *chain = "6b8af7fe3786";
    // 文档目录口径：S2A_DOCS 优先，否则 $HOME/Documents
    setenv("S2A_DOCS", tmp, 1); s2a_shader_overlay_root(out, sizeof out, pid);
    snprintf(p, sizeof p, "%s/gal/0100ABCD00010000/shaders", tmp); ck(!strcmp(out, p), "S2A_DOCS 设了：<S2A_DOCS>/gal/<程序号大写>/shaders");
    unsetenv("S2A_DOCS"); setenv("HOME", "/h", 1); s2a_shader_overlay_root(out, sizeof out, pid);
    ck(!strcmp(out, "/h/Documents/gal/0100ABCD00010000/shaders"), "S2A_DOCS 没设：$HOME/Documents/gal/<程序号>/shaders");
    setenv("S2A_DOCS", tmp, 1);
    ck(s2a_shader_overlay_direct(out, sizeof out, pid, chain) == 0, "没有外置包 → 0（照旧包内）");
    snprintf(d, sizeof d, "%s/gal", tmp); mkdir(d, 0755); snprintf(d, sizeof d, "%s/gal/0100ABCD00010000", tmp); mkdir(d, 0755);
    strcat(d, "/shaders"); mkdir(d, 0755); strcat(d, "/direct"); mkdir(d, 0755);
    snprintf(p, sizeof p, "%s/b-0000old00000", d); mkdir(p, 0755); snprintf(p, sizeof p, "%s/shader_map.tsv", d); touch(p);
    ck(s2a_shader_overlay_direct(out, sizeof out, pid, chain) == -1, "外置包只有旧链号的库 → -1（退回包内）");
    snprintf(p, sizeof p, "%s/shader_map.tsv", d); unlink(p); snprintf(p, sizeof p, "%s/b-%s", d, chain); mkdir(p, 0755);
    ck(s2a_shader_overlay_direct(out, sizeof out, pid, chain) == -1, "有本链号的库、缺映射表 → -1");
    snprintf(p, sizeof p, "%s/shader_map.tsv", d); touch(p);
    ck(s2a_shader_overlay_direct(out, sizeof out, pid, chain) == 1 && !strcmp(out, d), "本链号的库 + 映射表都在 → 1，库目录 = <根>/direct");
    ck(s2a_shader_overlay_direct(out, sizeof out, 0x0100abcd00020000ull, chain) == 0, "别的程序号 → 0");
    char cmd[1300]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", tmp); if (system(cmd)) {}
    if (bad) { printf("shader_overlay 单测 %d 项不通\n", bad); return 1; }
    printf("✓ t_shader_overlay 单测全过\n"); return 0;
}
