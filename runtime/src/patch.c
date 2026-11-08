// 宿主补丁装载器（补丁包 v1，画质性能线 11-02；接口见 runtime/include/patch.h）：只解析、保管、回写 .applied；各段的生效在读它的地方（caps.c / widen.c / patch_data.c）。
// 文件：<补丁根>/<程序号 16 位大写>/patch.tsv。文件头「键\t值」（schema / program / build / title / source …），「[段名]」起一段，段内一行一条（# 起注释，能力行的注释是原因）。
#include "patch.h"
#include "native.h"
#include "s2a_docs.h"   // 文档根唯一取法
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <errno.h>
#include <sys/stat.h>
#ifdef __APPLE__
#include <TargetConditionals.h>   // TARGET_OS_IPHONE（随包补丁的资源包根缺省）
#endif

enum { WROWS = 256, CROWS = 64, NOTES = 64, DROWS = 64, DMARKS = 64 };
typedef struct { char cap[32], val[4], why[160]; int except; } crow_t;
static struct {
    int ok;                       // 有对号补丁
    char dir[1100], build[40];
    s2a_patch_wrow_t w[2][WROWS]; int nw[2], has_w[2];   // [0] 掌机 [1] 主机
    int full[2];                  // -1 = 没这段
    crow_t c[CROWS]; int nc;
    char notes[NOTES][200]; int nnotes, cnt[3];
    char *fps; size_t nfps;       // [fps] 段原文（帧率表行，交 fps.c）
    s2a_patch_drow_t d[DROWS]; int nd, has_d;   // [data] 行（cpatch.c s2a_patch_data_apply 装载时写）
    struct { char mod[32]; uint64_t off, n; } dm[DMARKS]; int ndm;   // 已写入的 [data] 范围
} g;

// main.npdm 的程序号（META +0x70 = ACI0 偏移，ACI0 +0x10 = 程序号）；同 gfxmode.c npdm_read，这里要在模块目录落定前读
static uint64_t npdm_pid(const char *dir) {
    char p[1100]; snprintf(p, sizeof p, "%s/main.npdm", dir);
    FILE *f = fopen(p, "rb"); if (!f) return 0;
    uint8_t meta[0x80], aci[0x18]; uint32_t off; uint64_t pid = 0;
    if (fread(meta, 1, sizeof meta, f) == sizeof meta && !memcmp(meta, "META", 4)) {
        memcpy(&off, meta + 0x70, 4);
        if (!fseek(f, off, SEEK_SET) && fread(aci, 1, sizeof aci, f) == sizeof aci && !memcmp(aci, "ACI0", 4)) memcpy(&pid, aci + 0x10, 8);
    }
    fclose(f); return pid;
}
static int hexv(char c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1; }
// 「aabb??cc」→ 字节 + 掩码；返回字节数，-1 = 写法不对
static int sig_half(const char *s, size_t n, uint8_t *b, uint8_t *mk, int cap) {
    if (n % 2 || (int)(n / 2) > cap) return -1;
    for (size_t i = 0; i < n; i += 2) {
        if (s[i] == '?' && s[i + 1] == '?') { b[i / 2] = 0; mk[i / 2] = 0; continue; }
        int h = hexv(s[i]), l = hexv(s[i + 1]); if (h < 0 || l < 0) return -1;
        b[i / 2] = (uint8_t)(h * 16 + l); mk[i / 2] = 0xff;
    }
    return (int)(n / 2);
}
// [widen.enable.*] 一行；返回 0 = 收下
static int parse_wrow(char *s, s2a_patch_wrow_t *r, int line) {
    memset(r, 0, sizeof *r); r->line = line;
    char *tok[8]; int nt = 0;
    for (char *t = strtok(s, "\t "); t && nt < 8; t = strtok(NULL, "\t ")) tok[nt++] = t;
    if (nt < 4 || strlen(tok[0]) >= sizeof r->mod || strlen(tok[2]) >= sizeof r->kind) return -1;
    char *e; unsigned long off = strtoul(tok[1], &e, 16); if (*e || off > UINT32_MAX) return -1;
    if (strcmp(tok[3], "0") && strcmp(tok[3], "1")) return -1;
    strcpy(r->mod, tok[0]); strcpy(r->kind, tok[2]); r->off = (uint32_t)off; r->on = tok[3][0] == '1';
    for (int i = 4; i < nt; i++) {
        if (!strncmp(tok[i], "orig=", 5)) { unsigned long o = strtoul(tok[i] + 5, &e, 16); if (*e || o > UINT32_MAX || !tok[i][5]) return -1; r->orig = (uint32_t)o; r->has_orig = 1; }
        else if (!strncmp(tok[i], "sig=", 4)) {
            const char *v = tok[i] + 4, *bar = strchr(v, '|'); if (!bar) return -1;
            if ((r->npre = sig_half(v, (size_t)(bar - v), r->pre, r->prem, 32)) < 0 || (r->npost = sig_half(bar + 1, strlen(bar + 1), r->post, r->postm, 32)) < 0) return -1;
        } else return -1;
    }
    return 0;
}

// [data] 一行；返回 0 = 收下
static int parse_drow(char *s, s2a_patch_drow_t *r, int line) {
    memset(r, 0, sizeof *r); r->line = line;
    char *tok[8]; int nt = 0;
    for (char *t = strtok(s, "\t "); t && nt < 8; t = strtok(NULL, "\t ")) tok[nt++] = t;
    if (nt < 4 || strlen(tok[0]) >= sizeof r->mod) return -1;
    char *e; unsigned long off = strtoul(tok[1], &e, 16); if (*e || off > UINT32_MAX) return -1;
    strcpy(r->mod, tok[0]); r->off = (uint32_t)off;
    int no = -1, nn = -1; uint8_t mo[64], mn[64];
    for (int i = 2; i < nt; i++) {
        if (!strncmp(tok[i], "orig=", 5)) no = sig_half(tok[i] + 5, strlen(tok[i] + 5), r->orig, mo, 64);
        else if (!strncmp(tok[i], "new=", 4)) nn = sig_half(tok[i] + 4, strlen(tok[i] + 4), r->nw, mn, 64);
        else if (!strncmp(tok[i], "sig=", 4)) {
            const char *v = tok[i] + 4, *bar = strchr(v, '|'); if (!bar) return -1;
            if ((r->npre = sig_half(v, (size_t)(bar - v), r->pre, r->prem, 32)) < 0 || (r->npost = sig_half(bar + 1, strlen(bar + 1), r->post, r->postm, 32)) < 0) return -1;
        } else return -1;
    }
    if (no <= 0 || nn != no) return -1;   // orig / new 要同长
    for (int i = 0; i < no; i++) if (!mo[i] || !mn[i]) return -1;   // orig / new 不许 ?? 通配
    r->n = no; return 0;
}
int s2a_patch_open(const char *dir) {
    free(g.fps); memset(&g, 0, sizeof g); g.full[0] = g.full[1] = -1;
    if (!dir || !*dir) return 0;
    uint64_t pid = npdm_pid(dir); if (!pid) return 0;
    const char *root = getenv("S2A_PATCH_DIR"); char rb[1024];
    if (!root || !*root) {
        s2a_docs_path(rb, sizeof rb, "S2A/patches");
        root = rb;
    }
    snprintf(g.dir, sizeof g.dir, "%s/%016llX", root, (unsigned long long)pid);
    char path[1200]; snprintf(path, sizeof path, "%s/patch.tsv", g.dir);
    FILE *f = fopen(path, "r");
    // 补丁根没有 → 资源包根随包那份（补丁包部署方案 v2：真机验过的补丁随包下发，pack/stage_rewrite.sh 拷进产物根）。只取一份：补丁根（玩家导入 / 启动器推送）优先。
    //   .applied / .fps.tsv 仍写补丁根下本款目录（资源包根的 .applied 是资源包自己的已应用标记，不能碰），目录没有就建
    //   资源包根 = 游戏数据目录 S2A_GAME_DATA（iOS 读补丁在 host_main.c 设它之前，取同一缺省 Documents/资源包，同 gfxmode.c game_data）；
    //   Mac 宿主的资源包根就是模块目录 dir。iOS 的 dir 是 App 包（settings.m），随包那份不在那（审计 P1-106：原先只开 dir，iOS 永远找不到）
    if (!f) {
        const char *gd = getenv("S2A_GAME_DATA"); char gb[1100];
#if TARGET_OS_IPHONE
        if (!gd || !*gd) { s2a_docs_path(gb, sizeof gb, "资源包"); gd = gb; }
#else
        (void)gb;
#endif
        if (gd && *gd) { snprintf(path, sizeof path, "%s/patch.tsv", gd); f = fopen(path, "r"); }
        if (!f) { snprintf(path, sizeof path, "%s/patch.tsv", dir); f = fopen(path, "r"); }
        if (!f) return 0;   // 补丁根、资源包根都没有：通用层，不打日志
        char md[1100]; snprintf(md, sizeof md, "%s", g.dir);
        for (char *q = md + 1; *q; q++) if (*q == '/') { *q = 0; mkdir(md, 0755); *q = '/'; }
        if (mkdir(md, 0755) && errno != EEXIST) LOG("【红】补丁：建不了 %s（%s），.applied / 补丁帧率表写不出", g.dir, strerror(errno));
    }
    char line[1024], sec[48] = "", prog[32] = ""; int ln = 0, bad = 0, skipped_sec = 0;
    while (fgets(line, sizeof line, f)) {
        ln++; line[strcspn(line, "\r\n")] = 0;
        if (!line[0]) continue;
        if (line[0] == '[') { char *z = strchr(line, ']'); if (!z) { bad++; LOG("【红】补丁 %s 第 %d 行段名没收尾，跳过", path, ln); continue; }
            *z = 0; snprintf(sec, sizeof sec, "%s", line + 1);
            if (strcmp(sec, "caps") && strcmp(sec, "except") && strcmp(sec, "fps") && strcmp(sec, "data") && strcmp(sec, "widen.verified") && strncmp(sec, "widen.enable.", 13) && strncmp(sec, "widen.full.", 11)) {
                skipped_sec++; LOG("补丁：段 [%s] 本版宿主不读（%s），跳过", sec, !strcmp(sec, "fps.code") || !strcmp(sec, "widen.sites") || !strcmp(sec, "cpatch") ? "出包段，出包时读" : "未接");
                sec[0] = '!';
            }
            continue; }
        if (line[0] == '#' || sec[0] == '!') continue;
        int dock = !strcmp(sec, "widen.enable.docked") || !strcmp(sec, "widen.full.docked") ? 1 : !strcmp(sec, "widen.enable.handheld") || !strcmp(sec, "widen.full.handheld") ? 0 : -1;
        if (!sec[0]) {   // 文件头
            char k[32], v[64]; if (sscanf(line, "%31s %63s", k, v) != 2) continue;
            if (!strcmp(k, "program")) snprintf(prog, sizeof prog, "%s", v);
            else if (!strcmp(k, "build")) snprintf(g.build, sizeof g.build, "%s", v);
        } else if (!strcmp(sec, "fps")) {   // 帧率表行（runtime/src/fps.c 的写法：w / slot / speed / present …）原样收下，对号后写成 .fps.tsv 交 fps.c
            size_t n = strlen(line); char *nb = realloc(g.fps, g.nfps + n + 2);
            if (!nb) { bad++; continue; }
            g.fps = nb; memcpy(g.fps + g.nfps, line, n); g.nfps += n; g.fps[g.nfps++] = '\n'; g.fps[g.nfps] = 0;
        } else if (!strcmp(sec, "data")) {   // 正确性类数据补丁（设计稿 12.12）：解析留存，装载各模块时写（cpatch.c s2a_patch_data_apply）
            g.has_d = 1;
            char *h = strchr(line, '#'); if (h) *h = 0;
            if (g.nd == DROWS) { bad++; LOG("【红】补丁 %s 第 %d 行：[data] 行超过 %d，跳过", path, ln, DROWS); continue; }
            if (parse_drow(line, &g.d[g.nd], ln)) { bad++; LOG("【红】补丁 %s 第 %d 行 [data] 写法不认（模块 偏移 orig=… new=… 同长 [sig=前|后]），跳过", path, ln); continue; }
            g.nd++;
        } else if (!strncmp(sec, "widen.enable.", 13)) {
            if (dock < 0) { bad++; LOG("【红】补丁 %s 第 %d 行：段 [%s] 档位不认，跳过", path, ln, sec); continue; }
            g.has_w[dock] = 1;
            char *h = strchr(line, '#'); if (h) *h = 0;
            if (g.nw[dock] == WROWS) { bad++; LOG("【红】补丁 %s 第 %d 行：满屏启用行超过 %d，跳过", path, ln, WROWS); continue; }
            if (parse_wrow(line, &g.w[dock][g.nw[dock]], ln)) { bad++; LOG("【红】补丁 %s 第 %d 行满屏启用行写法不认，跳过", path, ln); continue; }
            g.nw[dock]++;
        } else if (!strncmp(sec, "widen.full.", 11)) {
            if (dock < 0) { bad++; LOG("【红】补丁 %s 第 %d 行：段 [%s] 档位不认，跳过", path, ln, sec); continue; }
            if (!strncmp(line, "0", 1)) g.full[dock] = 0; else if (!strncmp(line, "1", 1)) g.full[dock] = 1;
            else { bad++; LOG("【红】补丁 %s 第 %d 行整套放宽值不认，跳过", path, ln); }
        } else {   // caps / except / widen.verified
            char why[160] = "", *h = strchr(line, '#');
            if (h) { *h = 0; snprintf(why, sizeof why, "%s", h + 1 + (h[1] == ' ')); }
            crow_t *c = &g.c[g.nc]; char v[8];
            if (g.nc == CROWS) { bad++; continue; }
            if (!strcmp(sec, "widen.verified")) { snprintf(c->cap, sizeof c->cap, "widen"); snprintf(c->val, sizeof c->val, "1"); snprintf(c->why, sizeof c->why, "补丁 [widen.verified] %s", line); c->except = 0; g.nc++; continue; }
            if (sscanf(line, "%31s %7s", c->cap, v) != 2 || (strcmp(v, "0") && strcmp(v, "1"))) { bad++; LOG("【红】补丁 %s 第 %d 行能力行写法不认（只收「能力\\t0/1」），跳过", path, ln); continue; }
            snprintf(c->val, sizeof c->val, "%s", v); snprintf(c->why, sizeof c->why, "%s", why); c->except = !strcmp(sec, "except"); g.nc++;
        }
    }
    fclose(f);
    char want[17]; snprintf(want, sizeof want, "%016llX", (unsigned long long)pid);
    if (strcasecmp(prog, want)) {   // 程序号不对：整份不用（patch_wrong_program）
        LOG("【红】补丁 %s 程序号 %s 不是本款 %s，整份不用（patch_wrong_program）", path, prog[0] ? prog : "(没写)", want);
        free(g.fps); memset(&g, 0, sizeof g); g.full[0] = g.full[1] = -1; return 0;
    }
    g.ok = 1;
    // [fps]：补丁 L3 替代包内帧率表（设计稿 12.7 第 2 条）。写成 <补丁目录>/.fps.tsv（表头 build = 补丁编写构建，fps.c 构建号对不上整表不用），
    //   经 fps.c 现有的 S2A_FPS_TABLE 入口读；启动环境已给 S2A_FPS_TABLE 的（调度 / 单测）不覆盖
    if (g.nfps && !getenv("S2A_FPS_TABLE")) {
        char fp[1200]; snprintf(fp, sizeof fp, "%s/.fps.tsv", g.dir); FILE *ff = fopen(fp, "w");
        if (ff && fprintf(ff, "build\t%s\n%s", g.build, g.fps) > 0 && !fclose(ff)) { setenv("S2A_FPS_TABLE", fp, 0); LOG("补丁：帧率表取补丁 [fps]（%s），替代包内帧率表", fp); }
        else { if (ff) fclose(ff); LOG("【红】补丁：[fps] 写不出 %s，按包内帧率表", fp); }
    }
    LOG("补丁来源 %s：编写构建 %s；数据行 %d、能力行 %d、满屏启用 掌机 %s / 主机 %s、整套放宽 掌机 %d / 主机 %d；跳过段 %d、坏行 %d", path, g.build[0] ? g.build : "(没写)", g.nd, g.nc,
        g.has_w[0] ? "有" : "无", g.has_w[1] ? "有" : "无", g.full[0], g.full[1], skipped_sec, bad);
    return 1;
}

void s2a_patch_caps_each(void (*fn)(const char *, const char *, const char *, int)) {
    if (!g.ok) return;
    for (int pass = 1; pass >= 0; pass--) for (int i = 0; i < g.nc; i++) if (g.c[i].except == pass) fn(g.c[i].cap, g.c[i].val, g.c[i].why, pass);
}
int s2a_patch_widen_rows(const char *mod, int docked, const s2a_patch_wrow_t **rows) {
    int d = !!docked; static s2a_patch_wrow_t pick[WROWS];
    if (!g.ok || !g.has_w[d]) return -1;
    int n = 0; for (int i = 0; i < g.nw[d]; i++) if (!strcmp(g.w[d][i].mod, mod)) pick[n++] = g.w[d][i];
    *rows = pick; return n;
}
int s2a_patch_data_rows(const char *mod, const s2a_patch_drow_t **rows) {
    static s2a_patch_drow_t pick[DROWS];
    if (!g.ok || !g.has_d) return -1;
    int n = 0; for (int i = 0; i < g.nd; i++) if (!strcmp(g.d[i].mod, mod)) pick[n++] = g.d[i];
    *rows = pick; return n;
}
void s2a_patch_data_mark(const char *mod, uint64_t off, uint64_t n) {
    if (g.ndm == DMARKS) return;
    snprintf(g.dm[g.ndm].mod, sizeof g.dm[0].mod, "%s", mod); g.dm[g.ndm].off = off; g.dm[g.ndm].n = n; g.ndm++;
}
int s2a_patch_data_overlap(const char *mod, uint64_t off, uint64_t n) {
    for (int i = 0; i < g.ndm; i++) if (!strcmp(g.dm[i].mod, mod) && off < g.dm[i].off + g.dm[i].n && g.dm[i].off < off + n) return 1;
    return 0;
}
int s2a_patch_widen_full(int docked) { return g.ok ? g.full[!!docked] : -1; }
const char *s2a_patch_build(void) { return g.ok ? g.build : ""; }
void s2a_patch_count(int kind) { if (kind >= 0 && kind < 3) g.cnt[kind]++; }
void s2a_patch_note(const char *fmt, ...) {
    char b[200]; va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
    LOG("补丁：%s", b);
    if (g.nnotes < NOTES) snprintf(g.notes[g.nnotes++], sizeof g.notes[0], "%s", b);
}
void s2a_patch_finish(const char *bid) {
    if (!g.ok) return;
    LOG("补丁生效：编写构建 %s、本包 %s；快路径 %d 条 / 特征命中 %d 条 / 跳过 %d 条", g.build[0] ? g.build : "(没写)", bid && *bid ? bid : "(不知道)", g.cnt[0], g.cnt[1], g.cnt[2]);
    char p[1200], t[1210]; snprintf(p, sizeof p, "%s/.applied", g.dir); snprintf(t, sizeof t, "%s.tmp", p);
    FILE *f = fopen(t, "w"); if (!f) { LOG("【红】补丁：.applied 写不了（%s）", p); return; }
    fprintf(f, "build\t%s\npack_build\t%s\nfast\t%d\nsig_hit\t%d\nskipped\t%d\n", g.build, bid ? bid : "", g.cnt[0], g.cnt[1], g.cnt[2]);
    for (int i = 0; i < g.nnotes; i++) fprintf(f, "note\t%s\n", g.notes[i]);
    if (fclose(f) || rename(t, p)) LOG("【红】补丁：.applied 落盘失败（%s）", p);
}
