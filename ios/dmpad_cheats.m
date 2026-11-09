// 金手指引擎（移植自 nxnative-fe3h-bl2h 的 dm/host/hle_cheats.c）。
// 认 Atmosphere / EdiZon 的文本格式（金手指站点发的 <TID>/cheats/<BID>.txt）。
//   [方括号] 开头是一节 = 齿轮菜单里的一个开关；{花括号} 是公共主代码（任何开关打开时先应用它），本身不单独开关。
//   每行代码是 0TME0000 AAAAAAAA [VVVVVVVV]：
//     0TME0000 里 T = 宽度（1/2/4/8 字节）、E = 相对 main：把 V 写到 main + A。8 字节行带两个值字，第二个是 A 处的低字（站点把高字印在前面）。
//     8000XXXX 按键条件：在按住那组键时应用（本引擎里开关打开就当作常开，见下方说明）。
//     20000000 条件块结束。
//     2/3/4/5/9/C0 等指针 / 循环 / 寄存器码：指针链（580F0000 / 580F1000 / 780F0000 / 6T0F0000）会执行，其余不识别码只记日志，节本身仍是一个开关。
// 每一处写入都先留住原字节，关掉时写回去。落在游戏代码页的写入在 iOS 上无法运行期完成（签名只读），会明确报红并跳过，
//   需要在出包时把金手指烘进镜像。
#include "hle.h"
#include "dm_input.h"   // dm_input_held()：快捷键型金手指要看现在按着哪些键
#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>
#include <dirent.h>
#include <time.h>
#include <stdarg.h>

void dm_guest_write_prepare(void *addr, size_t len);   // graphics/nvn/host_adapt.m：写游戏内存前的统一入口（放开写跟踪的只读页）

#define CH_MAXSEC  96   // 包内金手指 + 玩家自己放在 Documents/cheats 的，合并上限
#define CH_MAXW    200
#define CH_NAMELEN 96

typedef struct { uint64_t off; uint32_t val[2]; int bytes; uint8_t orig[8]; int have_orig; int text; int abs; } ch_w;   // abs = 绝对 guest 地址，不是 main+偏移
// 站点文件会把「基址 → 读指针 → 加偏移 → 写入」拆成几行：
//   580F0000 <imm> = 读 main+imm 处的指针放进基址，580F1000 <imm> = 读 base+imm 处的指针（一层一行，能串链），
//   780F0000 <imm> = 基址加 imm，6T0F0000 <off> <val> = 在 base+off 写 T 字节。
// 5TMRI0AA 是读（同 Atmosphère 的 opcode 5）：580F0000 是「main+imm 处的指针」，不是「main+imm 这个地址」。
// 少读一层就会把写入落到那个列表末尾之外，把后面的分配写坏（真机上几秒后闪退）。
enum { CH_SET = 1, CH_DEREF, CH_ADD, CH_STORE };
typedef struct { uint64_t off; uint32_t val[2]; uint8_t kind, bytes; } ch_op;
typedef struct { char name[CH_NAMELEN]; ch_w w[CH_MAXW]; ch_op op[CH_MAXW]; int nw, nops, nprog; int cond; int on; int done; int unsw; uint32_t key; uint64_t cnt; } ch_sec;
// unsw = 不可切换（原文件里只改代码、没有开关变量）；cnt = 这一节钩子计数的地址（用来判断游戏有没有走到那处代码）；nprog = 指针程序的写入条数

static ch_sec g_sec[CH_MAXSEC];
static int g_nsec, g_master = -1, g_loaded, g_skipped;
static char g_src[1024];
static int sec_writes(const ch_sec *s);   // 定义在下面；加载时的日志行先用到
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
void dm_cheats_set_all(int on);

static module_t *main_mod(void) {
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main") && g_mod[i].base) return &g_mod[i];
    return NULL;
}

// 写进游戏映像。代码段在 iOS 上是签名的只读页：写下去这页就变成未签名页，游戏下一次取指直接 SIGILL，所以代码页写入一律跳过并报红。
static int g_code_skip;
static void guest_write(module_t *m, uint64_t off, const void *src, size_t n) {
    if (off + n > m->size) { LOG("[金手指] 写入越界：main+%#llx（%zu 字节，映像 %#zx）已丢弃", (unsigned long long)off, n, m->size); return; }
    uint64_t page_end = (m->text_end + 0x3FFF) & ~(uint64_t)0x3FFF;   // 代码是 [0, page_end)
    if (off < page_end) {
        if (g_code_skip++ < 3) LOG("[金手指] 【红】main+%#llx 是代码页（签名只读）：这个包没有烘焙金手指，运行期改不了，已跳过", (unsigned long long)off);
        else if (g_code_skip == 4) LOG("[金手指] 【红】（后面的代码页写入不再逐条打印）");
        return;
    }
    uint8_t *p = m->base + off;
    dm_guest_write_prepare(p, n);
    memcpy(p, src, n);
}

static unsigned hexval(const char *s, size_t n) {
    unsigned v = 0;
    for (size_t i = 0; i < n; i++) {
        int c = (unsigned char)s[i], d;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else break;
        v = v << 4 | (unsigned)d;
    }
    return v;
}

static uint64_t hexval64(const char *s, size_t n) {   // 绝对地址能超过 4 GB（游戏 main 在 0x1_0a80_0000 一带），这一侧用 64 位
    uint64_t v = 0;
    for (size_t i = 0; i < n; i++) {
        int c = (unsigned char)s[i], d;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else break;
        v = v << 4 | (unsigned)d;
    }
    return v;
}

static char *trim(char *s) {
    while (*s && isspace((unsigned char)*s)) s++;
    char *e = s + strlen(s);
    while (e > s && isspace((unsigned char)e[-1])) *--e = 0;
    return s;
}

// 一份文件，追加进表（fresh = 从头开始）。返回目前已收下的节数。
static int load_one(const char *file, int fresh) {
    FILE *f = fopen(file, "r");
    if (!f) { LOG("[金手指] 打不开 %s", file); return g_nsec; }
    if (fresh) { g_nsec = 0; g_master = -1; g_skipped = 0; g_src[0] = 0; }
    if (!g_src[0]) snprintf(g_src, sizeof g_src, "%s", file);
    char line[512];
    int cur = -1;
    while (fgets(line, sizeof line, f)) {
        char *s = trim(line);
        if (!*s) continue;
        if (s[0] == '/' && s[1] == '/' && (strstr(s, "static") || strstr(s, "always"))) { if (cur >= 0) g_sec[cur].unsw = 1; continue; }   // 这一节只改代码、没有开关变量
        if (s[0] == '/' && s[1] == '/' && strstr(s, "count")) {   // // count <十六进制地址> = 这一节钩子的执行次数所在处
            char *cp = strstr(s, "count") + 5;
            while (*cp && !((*cp >= '0' && *cp <= '9') || (*cp >= 'a' && *cp <= 'f'))) cp++;
            char *e3 = NULL;
            unsigned long long v = *cp ? strtoull(cp, &e3, 16) : 0;
            if (cur >= 0 && e3 != cp) g_sec[cur].cnt = v;
            continue;
        }
        if (s[0] == '/' && s[1] == '/' && strstr(s, "hotkey")) {   // // hotkey <掩码>：原文件里这一节是按键触发的（如 0x30 = L3+R3）
            char *hp = strstr(s, "hotkey") + 6;
            while (*hp && !((*hp >= '0' && *hp <= '9') || (*hp >= 'a' && *hp <= 'f') || (*hp >= 'A' && *hp <= 'F'))) hp++;
            char *e2 = NULL;
            unsigned long m = *hp ? strtoul(hp, &e2, 16) : 0;
            if (cur >= 0 && e2 != hp) g_sec[cur].key = (uint32_t)m;
            continue;
        }
        if (s[0] == '/' && s[1] == '/') continue;
        if (*s == '[' || *s == '{') {
            char name[CH_NAMELEN] = {0};
            snprintf(name, sizeof name, "%s", s + 1);
            char *r = strpbrk(name, "]}"); if (r) *r = 0;
            char *nm = trim(name);
            if (strstr(nm, "TID=") || strstr(nm, "BID=")) { cur = -1; continue; }   // 文件头不是一节
            if (strstr(nm, "还原") || strcasestr(nm, "restore")) { cur = -1; continue; }   // 站点的「还原原代码」块：本引擎自己留快照
            if (g_nsec >= CH_MAXSEC) { cur = -1; continue; }
            cur = g_nsec++;
            memset(&g_sec[cur], 0, sizeof g_sec[cur]);
            snprintf(g_sec[cur].name, CH_NAMELEN, "%s", nm);
            if (*s == '{') g_master = cur;
            continue;
        }
        if (cur < 0) continue;
        char a[24] = {0}, b[24] = {0}, c[24] = {0}, d[24] = {0};
        int n = sscanf(s, "%23s %23s %23s %23s", a, b, c, d);
        if (n < 2) continue;
        unsigned op = hexval(a, strlen(a));
        int type = (int)(op >> 28), width = (int)((op >> 24) & 0xF);
        int atype = (int)((op >> 20) & 0xF), mem = (int)((op >> 16) & 0xF);   // Atmosphère 的布局：第 3 个十六进制位是地址类型，第 4 位是内存类型
        if (type == 8) { g_sec[cur].cond = 1; continue; }   // 按键条件：列出这一节，它的写入在开关打开时照常执行
        if (type == 2) continue;                            // 条件块结束
        if (type == 5 || type == 6 || type == 7) {   // 指针码：见 ch_op 的注释
            ch_sec *sec = &g_sec[cur];
            if (sec->nops >= CH_MAXW || n < 2) { g_skipped++; continue; }
            ch_op *o = &sec->op[sec->nops];
            memset(o, 0, sizeof *o);
            if (type == 5) { o->kind = ((op >> 12) & 0xF) ? CH_DEREF : CH_SET; o->off = hexval64(b, strlen(b)); }
            else if (type == 7) { o->kind = CH_ADD; o->off = hexval64(b, strlen(b)); }
            else {   // 6T0F：以基址为底的写入，T = 宽度
                if (mem != 0xF || (width != 1 && width != 2 && width != 4 && width != 8) || n < 3) { g_skipped++; continue; }
                o->kind = CH_STORE; o->off = hexval64(b, strlen(b)); o->bytes = (uint8_t)width;
                if (width == 8 && n >= 4) { o->val[0] = hexval(d, strlen(d)); o->val[1] = hexval(c, strlen(c)); }   // 站点把高字写在前面
                else o->val[0] = hexval(c, strlen(c));
                sec->nprog++;
            }
            sec->nops++;
            continue;
        }
        // atype 0 + mem E = main+偏移（站点文件都是这种）；atype 1 = 绝对 guest 地址（玩家自己填的数值金手指常用这种）
        int abs = atype == 1;
        if (type != 0 || (!abs && mem != 0xE) || (width != 1 && width != 2 && width != 4 && width != 8) || n < 3) { g_skipped++; continue; }
        ch_sec *sec = &g_sec[cur];
        if (sec->nw >= CH_MAXW) { g_skipped++; continue; }
        ch_w *w = &sec->w[sec->nw];
        memset(w, 0, sizeof *w);
        w->off = hexval64(b, strlen(b));
        w->bytes = width;
        w->abs = abs;
        if (width == 8) {   // 08 行带四个词，最后一个才是 off 处的低字（站点把高字印在前面）
            if (n < 4) { g_skipped++; continue; }
            w->val[0] = hexval(d, strlen(d));
            w->val[1] = hexval(c, strlen(c));
        } else w->val[0] = hexval(c, strlen(c));
        sec->nw++;
    }
    fclose(f);
    g_loaded = 1;
    return g_nsec;
}

// 一个 .txt 文件，或一个目录：目录里的 *.txt 全部合并，按文件名排序，菜单顺序每次一致
static int load_path(const char *path) {
    if (!path || !*path) return g_nsec;
    if (strstr(path, ".txt")) return load_one(path, g_src[0] == 0);
    DIR *d = opendir(path);
    if (!d) return g_nsec;
    static char names[24][640];
    int nn = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL && nn < 24) {
        size_t l = strlen(e->d_name);
        if (l > 4 && !strcasecmp(e->d_name + l - 4, ".txt")) snprintf(names[nn++], sizeof names[0], "%s/%s", path, e->d_name);
    }
    closedir(d);
    for (int i = 1; i < nn; i++) {   // 按名字插入排序：顺序稳定，页面不会每次进去都换位置
        char t[640]; strcpy(t, names[i]);
        int j = i;
        while (j > 0 && strcmp(names[j - 1], t) > 0) { strcpy(names[j], names[j - 1]); j--; }
        strcpy(names[j], t);
    }
    for (int i = 0; i < nn; i++) load_one(names[i], g_src[0] == 0);
    return g_nsec;
}

// 包内文件和玩家的 Documents/cheats 里同名同内容时，同一份码会被加载两遍。
// 两节名字和每条写入都一样的只留第一份：否则两个「无敌(开)」会互相把对方关掉，菜单上也多出一倍行。
static int sec_same(const ch_sec *a, const ch_sec *b) {
    if (strcmp(a->name, b->name)) return 0;
    if (a->nops != b->nops || a->nw != b->nw || a->nprog != b->nprog) return 0;
    for (int i = 0; i < a->nops; i++) {
        if (a->op[i].kind != b->op[i].kind || a->op[i].off != b->op[i].off || a->op[i].bytes != b->op[i].bytes || a->op[i].val[0] != b->op[i].val[0]) return 0;
    }
    for (int i = 0; i < a->nw; i++) {
        if (a->w[i].off != b->w[i].off || a->w[i].bytes != b->w[i].bytes || a->w[i].abs != b->w[i].abs || a->w[i].val[0] != b->w[i].val[0]) return 0;
    }
    return 1;
}
static void cheats_dedupe(void) {
    int w = 0;
    for (int i = 0; i < g_nsec; i++) {
        int dup = 0;
        for (int j = 0; j < w; j++) if (sec_same(&g_sec[i], &g_sec[j])) { dup = 1; break; }
        if (dup) continue;
        if (w != i) g_sec[w] = g_sec[i];
        w++;
    }
    g_nsec = w;
}

int dm_cheats_reload(void) {   // 菜单用：包内的文件 + 玩家自己的 Documents/cheats
    pthread_mutex_lock(&g_mu);
    g_nsec = 0; g_master = -1; g_loaded = 0; g_skipped = 0; g_src[0] = 0;
    const char *e = getenv("DM_CHEATS");
    load_path(e && *e ? e : getenv("DM_CHEATS_DIR"));
    load_path(getenv("DM_CHEATS_USER"));
    cheats_dedupe();
    g_loaded = 1;
    int unsw = 0; for (int i = 0; i < g_nsec; i++) if (g_sec[i].unsw) unsw++;
    LOG("[金手指] %s：%d 节（%d 主代码，%d 代码补丁类不可切换），未识别码 %d", g_src, g_nsec, g_master >= 0 ? 1 : 0, unsw, g_skipped);
    for (int i = 0; i < g_nsec; i++) LOG("[金手指]   [%d] %s（%d 个写入%s%s）", i, g_sec[i].name, sec_writes(&g_sec[i]),
                                          g_sec[i].unsw ? "，代码补丁类" : "", g_sec[i].cond ? "，原文件按键触发" : "");
    int all = getenv("DM_CHEATS_ALL") != NULL;
    pthread_mutex_unlock(&g_mu);
    if (all) dm_cheats_set_all(1);
    return g_nsec;
}

int dm_cheats_load(const char *path) {   // 单个文件或目录（测试入口）
    pthread_mutex_lock(&g_mu);
    g_nsec = 0; g_master = -1; g_loaded = 0; g_skipped = 0; g_src[0] = 0;
    int n = load_path(path);
    cheats_dedupe();
    g_loaded = 1;
    LOG("[金手指] %s：%d 节（%d 主代码），未识别码 %d", g_src, n, g_master >= 0 ? 1 : 0, g_skipped);
    pthread_mutex_unlock(&g_mu);
    if (n && getenv("DM_CHEATS_ALL")) dm_cheats_set_all(1);
    return n;
}

// 绝对地址来自玩家自己填的文件，可能是错的：先探测可读（vm_read_overwrite 不成功只会返回失败，不会杀掉进程）。
static int abs_slot(ch_w *w, uint8_t **pp) {
    uint8_t *p = (uint8_t *)(uintptr_t)w->off;
    vm_size_t got = 0;
    if (w->off < 0x1000 || vm_read_overwrite(mach_task_self(), (vm_address_t)p, (vm_size_t)w->bytes, (vm_address_t)w->orig, &got) != KERN_SUCCESS || got != (vm_size_t)w->bytes) return 0;
    *pp = p;
    return 1;
}
// 生效后把每个写入点的当前值读回来打一行：值对 = 标志确实进了内存（剩下的就是游戏有没有执行到那处钩子）
static void sec_verify(module_t *m, ch_sec *s) {
    for (int i = 0; i < s->nw; i++) {
        ch_w *w = &s->w[i];
        for (int j = i + 1; j < s->nw; j++)          // 同一地址在本节里被写多次时（快捷键的"变体序号"），只按最后一次判读
            if (s->w[j].abs == w->abs && s->w[j].off == w->off && s->w[j].bytes == w->bytes) { i = j - 1; w = &s->w[j]; break; }
        uint8_t *p = w->abs ? (uint8_t *)(uintptr_t)w->off : m->base + w->off;
        unsigned long long got = 0, want = 0, mask = w->bytes >= 8 ? ~0ull : ((1ull << (w->bytes * 8)) - 1);
        memcpy(&want, w->val, (size_t)w->bytes); want &= mask;
        vm_size_t have = 0;
        if (vm_read_overwrite(mach_task_self(), (vm_address_t)p, (vm_size_t)w->bytes, (vm_address_t)&got, &have) != KERN_SUCCESS || have != (vm_size_t)w->bytes) { LOG("[金手指]   校验 %s%#llx 读不回", w->abs ? "" : "main+", (unsigned long long)w->off); continue; }
        got &= mask;
        LOG("[金手指]   校验 %s%#llx（%d 字节）期望 %#llx 读回 %#llx%s", w->abs ? "" : "main+", (unsigned long long)w->off, w->bytes,
            want, got, got == want ? "" : "  ← 与期望不符（游戏自己改写了这一处？）");
    }
    if (s->cnt) {   // 计数在涨 = 游戏确实走到了这处代码；一直是 0 = 这处代码没执行（要等回合结束 / 战斗结算 / 拿经验那类操作）
        uint32_t c = 0; vm_size_t have = 0;
        uint8_t *q = m->base + s->cnt;
        if (vm_read_overwrite(mach_task_self(), (vm_address_t)q, 4, (vm_address_t)&c, &have) == KERN_SUCCESS && have == 4)
            LOG("[金手指]   钩子已执行 %u 次（main+%#llx）%s", c, (unsigned long long)s->cnt, c ? "" : "← 游戏还没走到这段代码");
    }
}

static int sec_writes(const ch_sec *s) { return s->nw ? s->nw : s->nprog; }   // 还没执行过指针程序时，用解析出的写入条数回答「能不能开关」

// 第一次成功解析一份指针程序时，把整条链路记下来（真机上「拨开了却没效果」或「改了以后闪退」时，
// 日志里这一行就能看出是哪一层读错了，站点文件换版本时最常错的就是这里）。
static char g_chain[600];
static int g_chain_on;
static void chain_note(const char *what, uint64_t off, int hasv, uint64_t v) {
    if (!g_chain_on) return;
    size_t n = strlen(g_chain);
    if (n > sizeof g_chain - 48) return;
    if (hasv) snprintf(g_chain + n, sizeof g_chain - n, "%s%#llx→%#llx ", what, (unsigned long long)off, (unsigned long long)v);
    else snprintf(g_chain + n, sizeof g_chain - n, "%s%#llx ", what, (unsigned long long)off);
}

// 地址是否落在任何一个模块的代码页里：这些页是签名的，写下去游戏下一次取指直接 SIGILL。
// 指针算出来的绝对地址也可能落进这里（比如指针链偏了），所以写之前按模块查一遍。
static int in_code(uintptr_t a) {
    for (int i = 0; i < g_nmod; i++) {
        module_t *mm = &g_mod[i];
        if (!mm->base) continue;
        uint64_t pe = (mm->text_end + 0x3FFF) & ~(uint64_t)0x3FFF;
        if (a >= (uintptr_t)mm->base && a < (uintptr_t)mm->base + pe) return 1;
    }
    return 0;
}
// 链路没就绪时的日志节流：这一段每个出图都可能跑一次，每帧打一行会让 log.txt 膨胀。
static int miss_log(const ch_sec *s, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static int miss_log(const ch_sec *s, const char *fmt, ...) {
    static uint32_t cnt[CH_MAXSEC];
    int i = (int)(s - g_sec);
    if (i < 0 || i >= CH_MAXSEC) return 0;
    uint32_t *c = &cnt[i];
    (*c)++;
    if (*c != 1 && *c % 600) return 0;
    char line[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    LOG("[金手指] %s", line);
    return 1;
}
// 指针程序的第一步：算出这一节真正会写到哪些地址（不写内存）。先算地址再改值，
// 是因为「同一地址的互斥选项」要在写之前就能认出对方。
static int prog_resolve_into(module_t *m, ch_sec *s, ch_w *out, int max) {
    uint8_t *base = NULL;
    int n = 0;
    for (int k = 0; k < s->nops; k++) {
        ch_op *o = &s->op[k];
        switch (o->kind) {
        case CH_SET:      // 580F0000 <imm>：读 main+imm 处的指针
        case CH_DEREF: {  // 580F1000 <imm>：读 base+imm 处的指针
            uint8_t *at = o->kind == CH_SET ? (m->base ? m->base + o->off : NULL) : (base ? (uint8_t *)((uintptr_t)base + o->off) : NULL);
            if (!at) break;
            uint64_t v = 0; vm_size_t got = 0;
            if (vm_read_overwrite(mach_task_self(), (vm_address_t)(uintptr_t)at, 8, (vm_address_t)&v, &got) != KERN_SUCCESS || got != 8) {
                miss_log(s, "[金手指]   指针链路读不回（main+%#llx），本节跳过", o->off); base = NULL; break;
            }
            // 读得回但不像一个 guest 指针（0 / 个位数 / 内核地址）：指针对象还没建好，或这条码不是这个版本的。
            if (v < 0x100000000ull || v >= 0x10000000000ull) {
                miss_log(s, "[金手指]   指针链路指向 %#llx（不在 guest 地址空间），本节跳过", v);
                base = NULL; break;
            }
            chain_note(o->kind == CH_SET ? "main+" : "+", o->off, 1, v);
            base = (uint8_t *)(uintptr_t)v;
            break;
        }
        case CH_ADD: if (base) { chain_note("+", o->off, 0, 0); base = (uint8_t *)((uintptr_t)base + o->off); } break;
        case CH_STORE: {
            if (!base || n >= max) break;
            uintptr_t addr = (uintptr_t)base + o->off;
            // 写之前先验证目标确实可读：指针算得出来但落在未映射的页上时，写下去就是闪退。
            uint8_t probe[8]; vm_size_t pn = 0;
            if (!addr || vm_read_overwrite(mach_task_self(), (vm_address_t)addr, (vm_size_t)o->bytes, (vm_address_t)probe, &pn) != KERN_SUCCESS || pn != (vm_size_t)o->bytes) {
                miss_log(s, "[金手指]   目标 %#llx 不可读，本节跳过", (uint64_t)addr);
                break;
            }
            if (in_code(addr)) {   // 代码页：写了就闪退，只能出包时烘焙
                miss_log(s, "[金手指]   【红】目标 %#llx 是代码页（签名只读），这一节需要出包烘焙，已跳过", (uint64_t)addr);
                break;
            }
            ch_w *w = &out[n];
            memset(w, 0, sizeof *w);
            if (m->base && addr >= (uintptr_t)m->base && addr + o->bytes <= (uintptr_t)m->base + m->size) { w->off = addr - (uintptr_t)m->base; w->abs = 0; }
            else { w->off = addr; w->abs = 1; }
            w->bytes = o->bytes; w->val[0] = o->val[0]; w->val[1] = o->val[1];
            n++;
            break;
        }
        default: break;
        }
    }
    return n;
}

static void prog_resolve(module_t *m, ch_sec *s) {
    if (s->nw) return;   // 已经解过一次（原字节也已留好），不要重算把 w[] 冲掉
    s->nw = prog_resolve_into(m, s, s->w, CH_MAXW);
}

// 每帧重算：指针指向的对象会被游戏重建（换房间 / 读档），地址变了就要跟着变；
// 同一个地址上的原字节必须沿用上一次的，否则「关掉」时会把补丁值当成原值写回去。
static void prog_refresh(module_t *m, ch_sec *s) {
    ch_w nw[CH_MAXW];
    int n = prog_resolve_into(m, s, nw, CH_MAXW);
    if (!n) return;   // 这一帧算不出来：留着上一次的地址和原字节，关掉时才能恢复
    for (int i = 0; i < n; i++)
        for (int j = 0; j < s->nw; j++)
            if (nw[i].abs == s->w[j].abs && nw[i].off == s->w[j].off && nw[i].bytes == s->w[j].bytes) {
                memcpy(nw[i].orig, s->w[j].orig, sizeof nw[i].orig);
                nw[i].have_orig = s->w[j].have_orig; nw[i].text = s->w[j].text;
                break;
            }
    memcpy(s->w, nw, sizeof(ch_w) * (size_t)n);
    s->nw = n;
}

// 第二步：把解析出的地址写进去（绝对地址先探测可读，main+偏移过 guest_write），每条都留原字节供关掉时恢复。
static void prog_write(module_t *m, ch_sec *s) {
    for (int i = 0; i < s->nw; i++) {
        ch_w *w = &s->w[i];
        uint8_t *p = NULL;
        if (w->abs) { if (!abs_slot(w, &p)) { LOG("[金手指] 绝对地址 %#llx 不可读写，跳过", (unsigned long long)w->off); continue; } }
        else p = m->base + w->off;
        if (!w->have_orig) {
            if (!w->abs && w->off + (uint64_t)w->bytes > m->size) continue;
            memcpy(w->orig, p, (size_t)w->bytes);
            w->have_orig = 1;
            w->text = !w->abs && w->off < m->text_end;
            LOG("[金手指]   %s 写入 %#llx（%d 字节，原值 %#llx）", s->name, (unsigned long long)(uintptr_t)p, w->bytes, (unsigned long long)w->orig[0]);
        }
        if (w->abs) { dm_guest_write_prepare(p, (size_t)w->bytes); memcpy(p, w->val, (size_t)w->bytes); }
        else guest_write(m, w->off, w->val, (size_t)w->bytes);
    }
}

static void prog_apply(module_t *m, ch_sec *s) {
    prog_resolve(m, s);
    prog_write(m, s);
    LOG("[金手指]   %s：指针程序写入 %d 处", s->name, s->nw);
    if (s->nw && g_chain[0]) LOG("[金手指]   %s 链路：%s", s->name, g_chain);
}

static void sec_apply(module_t *m, ch_sec *s) {   // 写入；第一次写某个目标时留住原字节
    if (s->nops) {
        g_chain_on = !s->done; g_chain[0] = 0;
        prog_apply(m, s);
        g_chain_on = 0;
        sec_verify(m, s); return;
    }
    for (int i = 0; i < s->nw; i++) {
        ch_w *w = &s->w[i];
        uint8_t *p;
        if (w->abs) { if (!abs_slot(w, &p)) { LOG("[金手指] 绝对地址 %#llx 不可读写，跳过", (unsigned long long)w->off); continue; } }
        else p = m->base + w->off;
        if (!w->have_orig) {
            if (!w->abs && w->off + (uint64_t)w->bytes > m->size) continue;
            memcpy(w->orig, p, (size_t)w->bytes);
            w->have_orig = 1;
            w->text = !w->abs && w->off < m->text_end;
        }
        if (w->abs) { dm_guest_write_prepare(p, (size_t)w->bytes); memcpy(p, w->val, (size_t)w->bytes); }
        else guest_write(m, w->off, w->val, (size_t)w->bytes);
    }
    sec_verify(m, s);   // 每个节生效时读回一次
}

static void sec_restore(module_t *m, ch_sec *s) {
    for (int i = s->nw - 1; i >= 0; i--) {   // 逆序恢复：同一节里重叠的写入按相反顺序撤销
        ch_w *w = &s->w[i];
        if (!w->have_orig) continue;
        if (w->abs) { uint8_t *p = (uint8_t *)(uintptr_t)w->off; dm_guest_write_prepare(p, (size_t)w->bytes); memcpy(p, w->orig, (size_t)w->bytes); }
        else guest_write(m, w->off, w->orig, (size_t)w->bytes);
    }
}

int dm_cheats_count(void) { return g_loaded ? g_nsec : 0; }
void dm_cheats_ensure(void) {   // 金手指页：第一次出图之前就先加载
    if (!g_loaded) dm_cheats_reload();
}
const char *dm_cheats_name(int i) { return i >= 0 && i < g_nsec ? g_sec[i].name : ""; }
int dm_cheats_is_master(int i) { return i == g_master; }
int dm_cheats_on(int i) { return i >= 0 && i < g_nsec && g_sec[i].on; }
// 1 = 运行期不能开关：原文件里这一节只改代码（没有自己的开关变量），iOS 改不了签名只读的代码页。
int dm_cheats_unswitchable(int i) { return i >= 0 && i < g_nsec && g_sec[i].unsw; }
// 1 = 这一节写的是游戏代码页（签名只读）：运行期做不了，必须出包时烘焙；0 = 普通数据写入，引擎能立即应用；-1 = main 还没映射，暂时不知道
int dm_cheats_needs_bake(int i) {
    if (i < 0 || i >= g_nsec) return 0;
    module_t *m = main_mod();
    if (!m) return -1;
    uint64_t page_end = (m->text_end + 0x3FFF) & ~(uint64_t)0x3FFF;
    for (int k = 0; k < g_sec[i].nw; k++) if (g_sec[i].w[k].off < page_end) return 1;   // 还有代码写入没被跳过：说明没烘焙
    return 0;
}
int dm_cheats_cond(int i) { return i >= 0 && i < g_nsec && g_sec[i].cond; }
uint32_t dm_cheats_hotkey(int i) { return i >= 0 && i < g_nsec ? g_sec[i].key : 0; }
int dm_cheats_stores(int i) { return i >= 0 && i < g_nsec ? sec_writes(&g_sec[i]) : 0; }   // 0 = 只能列出，不能开关（代码补丁类）
const char *dm_cheats_source(void) { return g_src; }

// 同一个数值的多个变体（x4 / x8 / x16，伤害 x0.5 / x2 / x3，13a / 13b）写的是同一个目标：开一个就要关掉别的。
// 否则最后一次写入赢，而先开的变体的代码钩子还挂着，游戏会跑到为另一个变体写的分支（闪退）。
static int shares_target(const ch_sec *a, const ch_sec *b) {
    for (int i = 0; i < a->nw; i++)
        for (int j = 0; j < b->nw; j++)
            if (a->w[i].off < b->w[j].off + (uint64_t)b->w[j].bytes && b->w[j].off < a->w[i].off + (uint64_t)a->w[i].bytes) return 1;
    return 0;
}

void dm_cheats_set(int i, int on) {   // 单个开关；主代码在任意开关打开时应用
    if (!g_loaded || i < 0 || i >= g_nsec || i == g_master) return;
    if (g_sec[i].unsw || sec_writes(&g_sec[i]) == 0) return;   // 代码补丁类没有可写的开关：不要记成已开
    pthread_mutex_lock(&g_mu);
    g_sec[i].on = on ? 1 : 0;   // 选择一直保留：main 映射后由 tick 应用
    // 快捷键型（原文件写成 8000xxxx）：开关 = 打开就一直生效；没打开时按住那组键也能临时触发。
    module_t *m = main_mod();
    if (!m) { LOG("[金手指] %s → %s（等游戏跑起来后生效）", g_sec[i].name, on ? "开" : "关"); pthread_mutex_unlock(&g_mu); return; }
    if (on && g_sec[i].nops) prog_resolve(m, &g_sec[i]);   // 先算出这一节会写哪里
    if (on) for (int k = 0; k < g_nsec; k++)   // 同一地址的互斥选项先关掉
        if (k != i && k != g_master && g_sec[k].on && shares_target(&g_sec[i], &g_sec[k])) {
            g_sec[k].on = 0;
            if (g_sec[k].done) { sec_restore(m, &g_sec[k]); g_sec[k].done = 0; }
            LOG("[金手指] %s → 关（同一地址的另一个选项开了）", g_sec[k].name);
        }
    int any = 0;
    for (int k = 0; k < g_nsec; k++) if (k != g_master && g_sec[k].on) any = 1;
    if (any && g_master >= 0 && !g_sec[g_master].done) { sec_apply(m, &g_sec[g_master]); g_sec[g_master].done = 1; }
    if (on) {   // 指针还没解出来（游戏的对象没建好）不置 done：交给 tick 重试
        if (!g_sec[i].done) { sec_apply(m, &g_sec[i]); if (!g_sec[i].nops || g_sec[i].nw) g_sec[i].done = 1; }
    }
    else if (g_sec[i].done) { sec_restore(m, &g_sec[i]); g_sec[i].done = 0; }
    LOG("[金手指] %s → %s", g_sec[i].name, on ? "开" : "关");
    pthread_mutex_unlock(&g_mu);
}

void dm_cheats_set_all(int on) {
    for (int i = 0; i < g_nsec; i++) if (i != g_master) dm_cheats_set(i, on);
}

// 每上屏一帧调一次（直连层与通用出图层都挂了钩子）：main 映射后把开关应用上去，
// 指针程序每帧重算地址并重写；内部按 100 ms 节流，避免每帧都扫一遍全部节。
static void cheats_tick_body(void) {
    static int tried;
    if (!g_loaded && !tried) { tried = 1; dm_cheats_reload(); }   // 包内文件 + 玩家自己的 Documents/cheats
    if (!g_loaded || !g_nsec) return;
    module_t *m = main_mod();
    if (!m) return;
    int any = 0;
    for (int i = 0; i < g_nsec; i++) if (i != g_master && g_sec[i].on) any = 1;
    if (!any) return;
    pthread_mutex_lock(&g_mu);
    if (g_master >= 0 && !g_sec[g_master].done) {
        sec_apply(m, &g_sec[g_master]);
        if (!g_sec[g_master].nops || g_sec[g_master].nw) g_sec[g_master].done = 1;   // 指针还没解出来就别记成已生效
    }
    for (int i = 0; i < g_nsec; i++) {
        if (i == g_master || !g_sec[i].on) continue;
        if (g_sec[i].key) {   // 原文件是按键条件节（8000XXXX）：开关打开就当作常开（本引擎拿不到游戏的按键状态）
            uint64_t held = dm_input_held();
            int want = g_sec[i].on || (held & g_sec[i].key) == g_sec[i].key;
            if (want && !g_sec[i].done) {
                sec_apply(m, &g_sec[i]);
                if (!g_sec[i].nops || g_sec[i].nw) g_sec[i].done = 1;
                LOG("[金手指] %s 生效（开关）", g_sec[i].name);
            } else if (!want && g_sec[i].done) { sec_restore(m, &g_sec[i]); g_sec[i].done = 0; }
            continue;
        }
        if (g_sec[i].nops) {
            // 游戏会重建指针指向的对象（换房间 / 读档），而且游戏自己每帧重算这些数值，所以每帧重写一遍。
            int first = !g_sec[i].done;
            if (first) { g_chain_on = 1; g_chain[0] = 0; }
            prog_refresh(m, &g_sec[i]);
            if (!g_sec[i].nw) { g_chain_on = 0; continue; }   // 指针还没就绪：下一帧继续试
            prog_write(m, &g_sec[i]);
            if (first) { g_chain_on = 0; if (g_chain[0]) LOG("[金手指]   %s 链路：%s", g_sec[i].name, g_chain); }
            if (!g_sec[i].done) { g_sec[i].done = 1; sec_verify(m, &g_sec[i]); LOG("[金手指] %s 生效（%d 处）", g_sec[i].name, g_sec[i].nw); }
            continue;
        }
        if (g_sec[i].done) continue;
        sec_apply(m, &g_sec[i]); g_sec[i].done = 1;
    }
    pthread_mutex_unlock(&g_mu);
}

void dm_cheats_tick(void) {
    static uint64_t last;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (last && now - last < 100000000ull) return;   // 100 ms 节流
    last = now;
    cheats_tick_body();
}
