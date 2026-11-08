// GLSLC 工具模式单测（glslc_tool.c，DM_GLSLC_JOB）：游戏的 GLSLC 换成宿主里的假编译器（按 SDK 的调用约定：先 glslcSetAllocator、再 glslcInitialize、
//   每次 glslcCompile 读编译对象 +0xa8 源码表 / +0xb0 阶段表 / +0xb8 条数，结果挂在 +0x00），子进程里跑一份作业文件，父进程逐字节核输出。
// 假编译器的规则（期望值按规则手写，不跑被测实现算）：源码以 "VS" 开头只在阶段 0 编得过、"PS" 只在阶段 1、"BAD" 哪个阶段都不过；
//   编过的输出 = 0x100 字节：+0 魔数 91 68 86 19、+0x44 长度 0x100、+0x48 编时的阶段、+0x90 起源码原文；没设分配器就 glslcInitialize 失败（同真 GLSLC：初始化状态 3）
#include "../src/native.h"
#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>

typedef void *(*alloc_fn)(size_t, size_t, void *); typedef void (*free_fn)(void *, void *); typedef void *(*realloc_fn)(void *, size_t, void *);
static alloc_fn g_alloc; static free_fn g_free; static int g_inits, g_compiles;
static uint64_t f_setalloc(void *a, void *f, void *r, void *u) { (void)u; if (!a || !f || !r) return 0; g_alloc = (alloc_fn)a; g_free = (free_fn)f; (void)r; return 1; }
static uint64_t f_init(void *o) { uint8_t *b = o; uint32_t st = g_alloc ? 1 : 3; memcpy(b + 0xd8, &st, 4); g_inits++; return g_alloc ? 0x101 : 0x100; }   // 高位垃圾：只认低 8 位
static uint64_t f_fini(void *o) { (void)o; return 0; }
static struct { void *status, *output; } g_res; static struct { const char *log; } g_status;
static uint64_t f_compile(void *o) {
    uint8_t *b = o; const char *const *srcs; const uint32_t *stages; memcpy(&srcs, b + 0xa8, 8); memcpy(&stages, b + 0xb0, 8);
    g_compiles++;
    if (b[0xb8] != 1) return 0;
    const char *s = srcs[0]; uint32_t st = stages[0];
    if (g_res.output) { g_free(g_res.output, NULL); g_res.output = NULL; }
    g_status.log = "fake: stage mismatch"; g_res.status = &g_status; void *r = &g_res; memcpy(b, &r, 8);
    int ok = (!strncmp(s, "VS", 2) && st == 0) || (!strncmp(s, "PS", 2) && st == 1);
    if (!ok) return 0x200;   // 低 8 位 0 = 失败
    uint8_t *out = g_alloc(0x100, 0x100, NULL); memset(out, 0, 0x100);
    memcpy(out, "\x91\x68\x86\x19", 4); uint32_t n = 0x100; memcpy(out + 0x44, &n, 4); memcpy(out + 0x48, &st, 4);
    strncpy((char *)out + 0x90, s, 0x100 - 0x90 - 1);
    g_res.output = out; return 1;
}
void *guest_sym(const char *name) {
    if (getenv("T_NO_GLSLC")) return NULL;
    return !strcmp(name, "glslcInitialize") ? (void *)f_init : !strcmp(name, "glslcCompile") ? (void *)f_compile : !strcmp(name, "glslcFinalize") ? (void *)f_fini
         : !strcmp(name, "glslcSetAllocator") ? (void *)f_setalloc : NULL;
}
static module_t g_sub = {.name = "subsdk0"};
module_t *module_of(const void *p) { (void)p; return &g_sub; }
int s2a_module_rebind(module_t *m, const char *name, uint64_t v) { (void)m; (void)name; (void)v; return 0; }   // 假模块没有导入表：改指 0 处
void *sw_xstack_wrap(const char *name, void *fn) { (void)name; return fn; }
uint64_t now_ns(void) { return 0; }
int s2a_glslc_tool_on(void); void s2a_glslc_tool_maybe(void);

static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ " __VA_ARGS__); printf("\n"); bad++; } } while (0)
static void put32(FILE *f, uint32_t v) { fwrite(&v, 4, 1, f); }
static void entry(FILE *f, int k, const uint32_t *st, const char *src) { put32(f, (uint32_t)k); for (int i = 0; i < k; i++) put32(f, st[i]); put32(f, (uint32_t)strlen(src)); fwrite(src, 1, strlen(src), f); }
static int run_child(const char *job, int no_glslc) {
    pid_t p = fork();
    if (!p) { setenv("DM_GLSLC_JOB", job, 1); if (no_glslc) setenv("T_NO_GLSLC", "1", 1); int fd = open("/dev/null", O_WRONLY); dup2(fd, 2); s2a_glslc_tool_maybe(); _exit(42); }
    int st; waitpid(p, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
}
int main(void) {
    char dir[] = "/tmp/t_glslc_tool.XXXXXX"; if (!mkdtemp(dir)) return 1;
    char job[256], outp[300]; snprintf(job, sizeof job, "%s/job.dmgj", dir); snprintf(outp, sizeof outp, "%s.out", job);
    unsetenv("DM_GLSLC_JOB");
    CHECK(!s2a_glslc_tool_on(), "① 没设 DM_GLSLC_JOB 时工具模式应为关");
    s2a_glslc_tool_maybe();   // ① 关着：直接返回（返回了才走得到下一行）
    FILE *f = fopen(job, "wb"); fwrite("DMGJ", 1, 4, f); put32(f, 4);
    static const uint32_t s10[] = {1, 0}, s1[] = {1}, s012[] = {0, 1, 2};
    entry(f, 2, s10, "VS main0");          // ② 先试片元编不过，再试顶点编过 → 阶段 0
    entry(f, 1, s1, "PS main1");           // ③ 片元一次过 → 阶段 1
    entry(f, 3, s012, "BAD shader");       // ④ 全不过 → 0xffffffff、长度 0
    entry(f, 1, s1, "VS only-as-pixel");   // ⑤ 候选里没有它的阶段 → 不过
    fclose(f);
    int rc = run_child(job, 0);
    CHECK(rc == 0, "② 子进程退出码 %d，应为 0（编不过的条目不算工具失败）", rc);
    FILE *o = fopen(outp, "rb"); uint8_t buf[4096]; size_t n = o ? fread(buf, 1, sizeof buf, o) : 0; if (o) fclose(o);
    // 期望：头 8 + ②(8+0x100) + ③(8+0x100) + ④ 8 + ⑤ 8
    CHECK(n == 8 + 2 * (8 + 0x100) + 8 + 8, "输出 %zu 字节，应为 %d", n, 8 + 2 * (8 + 0x100) + 16);
    if (n == 8 + 2 * (8 + 0x100) + 16) {
        uint32_t w[2]; memcpy(w, buf, 8); CHECK(!memcmp(buf, "DMGR", 4) && w[1] == 4, "输出头不是 DMGR / 4 条");
        const uint8_t *e = buf + 8; memcpy(w, e, 8);
        CHECK(w[0] == 0 && w[1] == 0x100 && !memcmp(e + 8, "\x91\x68\x86\x19", 4) && !strcmp((const char *)e + 8 + 0x90, "VS main0"), "② 第 1 条：阶段 %u 长度 %#x 或内容不对", w[0], w[1]);
        e += 8 + 0x100; memcpy(w, e, 8);
        CHECK(w[0] == 1 && w[1] == 0x100 && !strcmp((const char *)e + 8 + 0x90, "PS main1"), "③ 第 2 条：阶段 %u 长度 %#x 或内容不对", w[0], w[1]);
        e += 8 + 0x100; memcpy(w, e, 8); CHECK(w[0] == 0xffffffffu && w[1] == 0, "④ 第 3 条：阶段 %#x 长度 %u，应为 0xffffffff / 0", w[0], w[1]);
        e += 8; memcpy(w, e, 8); CHECK(w[0] == 0xffffffffu && w[1] == 0, "⑤ 第 4 条：阶段 %#x 长度 %u，应为 0xffffffff / 0", w[0], w[1]);
    }
    // ⑥ 模块里没有 GLSLC：报红中止（非 0），不出半份输出当成功
    remove(outp); rc = run_child(job, 1);
    CHECK(rc != 0 && access(outp, F_OK) != 0, "⑥ 没有 GLSLC 时退出码 %d（应非 0）、输出%s", rc, access(outp, F_OK) ? "不在" : "却在");
    // ⑦ 作业文件魔数不对：报红中止
    f = fopen(job, "wb"); fwrite("XXXX", 1, 4, f); put32(f, 0); fclose(f); rc = run_child(job, 0);
    CHECK(rc != 0, "⑦ 魔数不对时退出码 %d，应非 0", rc);
    remove(job); remove(outp); rmdir(dir);
    if (!bad) printf("✓ t_glslc_tool：0 处不符（共 7 项）\n");
    return bad != 0;
}
