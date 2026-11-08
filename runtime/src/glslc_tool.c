// 宿主工具模式：用游戏自带的 GLSLC（运行时编着色器的那份 glslcCompile，神之天平 外传在 subsdk0）在出包期把 GLSL 源码编成 NVN 程序二进制。
// 为什么要它：有的游戏不带编好的着色器，开机或用到时才拿 main 里的 GLSL 源码调 glslcCompile 现编（DxLib 款神之天平 外传：main 里 4 个 DxLib 压缩包、3509 支源码；
//   火焰纹章 风花雪月的 KTGL 开机编 9 支）。直连库的键 = 控制段 + 代码区的哈希，只有游戏自己的编译器、同样的源码与选项才编得出同样的字节，
//   所以出包时直接调游戏里那份编译器（不起 C#、不起图形、不进 nnMain），编出的就是游戏运行时会提交的程序。源码由 translator/glslc_offline.py 从 main 里找出来、写成作业文件。
// 用法：DM_GLSLC_JOB=<作业文件> s2arm-host <改写模块目录>
//   作业文件："DMGJ" u32 条数，每条 u32 候选阶段数 k、u32 阶段 ×k（NVNshaderStage：0 顶点 1 片元 2 几何 3 曲面控制 4 曲面求值 5 计算）、u32 源码长度 + 源码（不含结尾 NUL）
//   输出 <作业文件>.out："DMGR" u32 条数，每条 u32 编成的阶段（0xffffffff = 候选阶段全编不过）、u32 输出长度 + GLSLC 输出（从魔数 0x19866891 起整份，长度取输出 +0x44）；退出 0。
//   候选阶段按顺序试，第一个编过的就是这条的结果（源码分不出阶段时由作业方给多个候选）。编不过的条目只记数、打前几条的编译日志，不算工具失败
// 时机：nninitStartup 与各模块 DT_INIT 之后（guest_main.c 在 Oodle 的 late 调用之后调）——GLSLC 是带全局构造的 C++ 代码，operator new / 日志 / 互斥量走 SDK 的 libc 与 nn::os；
//   SDK 初始化要连系统服务，所以这个模式照常起 C# 服务层（host_main.c，要 S2A_CS=1 的宿主），只是不起前端、不进 nnMain。
// 分配器：glslcInitialize 先查 glslcSetAllocator 设过没有（没设直接返回失败、初始化状态 3），这里设宿主自己的三个回调（游戏线程上、客体栈上直接调，同 NVN 的宿主实现）。
//   运行时游戏设的是它自己的分配器，分配器只决定输出放在哪，不改输出字节。
// 编译对象（GLSLCcompileObject，按神之天平 外传 subsdk0 的 glslcInitialize / glslcCompile 与 DxLib 的调用点核）：+0x00 lastCompiledResults、+0x10 私有数据、
//   +0x18 选项（glslcInitialize 填缺省值，DxLib 不改）、+0xa8 input.sources（const char *const *）、+0xb0 input.stages（const NVNshaderStage *）、+0xb8 input.count（u8）、
//   +0xd8 初始化状态；结果 +0x00 编译状态（+0x00 infoLog）、+0x08 GLSLC 输出。对象按 0x400 字节清零给，比真结构大
#include "native.h"
#include <unistd.h>

typedef uint64_t (*g_fn1)(void *);
typedef uint64_t (*g_setalloc)(void *, void *, void *, void *);
static struct { g_fn1 init, compile, fini; g_setalloc setalloc; const char *mod; } g_gc;

// GLSLC 的分配回调（GLSLCallocateFunction / GLSLCfreeFunction / GLSLCreallocateFunction）：size_t 与指针都是 64 位，Apple 与 Switch 的传参一致
static void *gc_alloc(size_t n, size_t align, void *user) { (void)user; void *p = NULL; if (align < 16) align = 16; return posix_memalign(&p, align, n ? n : 1) ? NULL : p; }
static void gc_free(void *p, void *user) { (void)user; free(p); }
static void *gc_realloc(void *p, size_t n, void *user) { (void)user; return realloc(p, n ? n : 1); }

int s2a_glslc_tool_on(void) { const char *j = getenv("DM_GLSLC_JOB"); return j && *j; }

// 编译器模块的 C++ 内存函数（11-02 塞尔达传说 御天之剑 HD：subsdk0 glslcInitialize+0xa8 调 operator new(16)，导入绑到 main 自己重写的 operator new，
//   它按线程找游戏堆、找不到退回全局缺省堆，工具模式不进 nnMain、两个都没建 → 返回 NULL 不抛，NvOsMutexCreate(NULL) 写空指针、宿主 139）：改指宿主分配。
//   分配器只决定输出放在哪，不改输出字节（同 gc_alloc）；只在工具模式，运行时不改
static void *gc_new(size_t n) { void *p = NULL; if (posix_memalign(&p, 16, n ? n : 1)) die("【红】DM_GLSLC_JOB：编译器 operator new(%zu) 宿主分配失败", n); return p; }
static void *gc_new_nt(size_t n, const void *nt) { (void)nt; void *p = NULL; return posix_memalign(&p, 16, n ? n : 1) ? NULL : p; }
static void gc_del(void *p) { free(p); }
static void gc_del2(void *p, size_t n) { (void)n; free(p); }
static void gc_rebind_new(module_t *m) {
    static const struct { const char *name; void *fn; } k[] = {
        {"_Znwm", (void *)gc_new}, {"_Znam", (void *)gc_new}, {"_ZnwmRKSt9nothrow_t", (void *)gc_new_nt}, {"_ZnamRKSt9nothrow_t", (void *)gc_new_nt},
        {"_ZdlPv", (void *)gc_del}, {"_ZdaPv", (void *)gc_del}, {"_ZdlPvm", (void *)gc_del2}, {"_ZdaPvm", (void *)gc_del2},
        {"_ZdlPvRKSt9nothrow_t", (void *)gc_del2}, {"_ZdaPvRKSt9nothrow_t", (void *)gc_del2} };
    int n = 0;
    for (unsigned i = 0; i < sizeof k / sizeof *k; i++) n += s2a_module_rebind(m, k[i].name, (uint64_t)sw_xstack_wrap(k[i].name, k[i].fn));
    LOG("DM_GLSLC_JOB：%s 的 C++ 内存函数导入改指宿主分配 %d 处（工具模式不建游戏堆）", m->name, n);
}

static void gc_find(void) {
    g_gc.init = (g_fn1)guest_sym("glslcInitialize"); g_gc.compile = (g_fn1)guest_sym("glslcCompile");
    g_gc.fini = (g_fn1)guest_sym("glslcFinalize"); g_gc.setalloc = (g_setalloc)guest_sym("glslcSetAllocator");
    if (!g_gc.init || !g_gc.compile || !g_gc.setalloc) die("【红】DM_GLSLC_JOB：装好的模块里没有游戏自带的 GLSLC（glslcInitialize %p、glslcCompile %p、glslcSetAllocator %p）",
                                                       (void *)g_gc.init, (void *)g_gc.compile, (void *)g_gc.setalloc);
    module_t *m = module_of((void *)g_gc.compile); g_gc.mod = m ? m->name : "?";
    if (m) gc_rebind_new(m);
}

static uint32_t rd32(FILE *f) { uint32_t v = 0; if (fread(&v, 4, 1, f) != 1) die("【红】DM_GLSLC_JOB：作业文件提前结束"); return v; }
static void wr(FILE *f, const void *p, size_t n) { if (n && fwrite(p, 1, n, f) != n) die("【红】DM_GLSLC_JOB：写输出失败"); }

static void job_run(const char *job) {
    FILE *in = fopen(job, "rb"); if (!in) die("【红】DM_GLSLC_JOB：打不开 %s", job);
    if (rd32(in) != 0x4a474d44) die("【红】DM_GLSLC_JOB：%s 不是作业文件（魔数不是 DMGJ）", job);
    uint32_t n = rd32(in);
    char outp[1024]; snprintf(outp, sizeof outp, "%s.out", job);
    FILE *out = fopen(outp, "wb"); if (!out) die("【红】DM_GLSLC_JOB：写不了 %s", outp);
    uint32_t hdr[2] = {0x52474d44, n}; wr(out, hdr, sizeof hdr);
    if (!(g_gc.setalloc(gc_alloc, gc_free, gc_realloc, NULL) & 0xff)) die("【红】DM_GLSLC_JOB：glslcSetAllocator 返回失败");
    uint8_t *obj = calloc(1, 0x400); if (!obj) die("【红】DM_GLSLC_JOB：编译对象分配失败");
    if (!(g_gc.init(obj) & 0xff)) { uint32_t st; memcpy(&st, obj + 0xd8, 4); die("【红】DM_GLSLC_JOB：glslcInitialize 失败（初始化状态 %u）", st); }
    uint32_t ok = 0, bad = 0; uint64_t bytes = 0, t0 = now_ns();
    for (uint32_t i = 0; i < n; i++) {
        uint32_t k = rd32(in), st[8]; if (!k || k > 8) die("【红】DM_GLSLC_JOB：第 %u 条候选阶段数 %u", i, k);
        for (uint32_t j = 0; j < k; j++) { st[j] = rd32(in); if (st[j] > 5) die("【红】DM_GLSLC_JOB：第 %u 条阶段 %u 不认识", i, st[j]); }
        uint32_t len = rd32(in); char *src = malloc((size_t)len + 1); if (!src) die("【红】DM_GLSLC_JOB：第 %u 条源码缓冲分配失败", i);
        if (fread(src, 1, len, in) != len) die("【红】DM_GLSLC_JOB：第 %u 条提前结束", i);
        src[len] = 0;
        const char *srcs[1] = {src}; uint32_t used = 0xffffffffu, olen = 0; const uint8_t *o = NULL; const char *why = NULL;
        for (uint32_t j = 0; j < k && used == 0xffffffffu; j++) {
            uint32_t stage = st[j];
            const char *const *sv = srcs; const uint32_t *sp = &stage;
            memcpy(obj + 0xa8, &sv, 8); memcpy(obj + 0xb0, &sp, 8); obj[0xb8] = 1;
            uint64_t r = g_gc.compile(obj) & 0xff; uint8_t *res; memcpy(&res, obj, 8);
            if (r && res) { memcpy(&o, res + 8, 8); if (o) { memcpy(&olen, o + 0x44, 4); if (!memcmp(o, "\x91\x68\x86\x19", 4) && olen >= 0x90) used = stage; } }
            if (used == 0xffffffffu && res) { const uint8_t *cs; memcpy(&cs, res, 8); if (cs) memcpy(&why, cs, 8); }
        }
        uint32_t rec[2] = {used, used == 0xffffffffu ? 0 : olen}; wr(out, rec, sizeof rec);
        if (used != 0xffffffffu) { wr(out, o, olen); ok++; bytes += olen; }
        else if (bad++ < 4) LOG("【黄】DM_GLSLC_JOB：第 %u 条（%u 字节，候选阶段 %u 个）编不过：%.300s", i, len, k, why ? why : "（没有编译日志）");
        free(src);
    }
    if (g_gc.fini) g_gc.fini(obj);
    fclose(in); if (fclose(out)) die("【红】DM_GLSLC_JOB：写输出失败");
    LOG("DM_GLSLC_JOB：用游戏 %s 的 glslcCompile 编成 %u 条、编不过 %u 条（共 %.1f MB，%.1f 秒）→ %s", g_gc.mod, ok, bad, bytes / 1048576.0, (now_ns() - t0) / 1e9, outp);
    fflush(stderr); _exit(0);
}

// guest_main.c 在 nninitStartup 与各模块 DT_INIT 之后调；做完 _exit，不进 nnMain
void s2a_glslc_tool_maybe(void) {
    if (!s2a_glslc_tool_on()) return;
    gc_find();
    LOG("GLSLC 工具模式：游戏的 glslcCompile 在 %s（SDK 初始化之后）", g_gc.mod);
    job_run(getenv("DM_GLSLC_JOB"));
}
