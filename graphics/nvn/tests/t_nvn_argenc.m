// 参数块长度不再问 Metal（nvn_mtl.m shader_args_init，10-30）：Metal 编译服务被系统强杀时，[fn newArgumentEncoderWithBufferIndex:] 拿不到函数反射，
//   断言「bufferIndex 0 does not identify an argument buffer」整局 abort（本机 10-30 07–09 普查 5 款）。直接包含生产 nvn_mtl.m，真 Metal 设备。
// 期望按规则手写（8 字节 × (最大参数编号 + 1)），不由被测实现推出：
//   ① 带参数块的函数（4 个指针成员，编号 0..3）、反射编号 0..3 → 长度 32，可用；Metal 自己算的也是 32（布局规则成立的交叉核对）
//   ② 编译服务失效的样子：函数没有参数块、反射却说有（编号到 3）→ 不问 Metal、不崩，长度 32，可用（这支之后建管线失败会自己跳过，不杀整局）
//      反证：子进程里照旧调 [fn newArgumentEncoderWithBufferIndex:0] 必须死于 SIGABRT（就是普查里那个断言；证明 ② 的夹具真能复现）
//   ③ S2A_ARGCHECK=1（诊断）且 Metal 的长度（32）与反射（编号到 6 → 56）不符 → 这支不可用（返回 0），不 abort（子进程里跑：开关按进程只读一次）
//   ④ 参数编号超出上限 NVN_REFL_MAXARG → 不可用
//   ⑤ 上限不是人为卡在 Metal 之下（11-02 马力欧派对 超级巨星 64 支片元编号到 198–207 被整支丢弃，上限原是 192）：
//      照它的真实参数块（39 个单项 + 5 个 32 项数组 + 4 个单项，编号到 202）→ 可用、长度 8 × 203 = 1624；Metal 编出同布局的函数、自己算的长度也是 1624、能建管线；
//      编号顶满上限（NVN_REFL_MAXARG - 1 项纹理数组 + 编号 NVN_REFL_MAXARG - 1 的指针）→ 可用、长度 8 × NVN_REFL_MAXARG，Metal 同样编得出、长度相同、能建管线
#include "../gfx/nvn/nvn_mtl.m"
#include <sys/wait.h>
#include <spawn.h>
extern char **environ;

static unsigned failures, checks;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static id<MTLFunction> g_with, g_without;
static NvShader *shn(id<MTLFunction> f, int nb, const uint16_t *aid, const uint8_t *n) {   // reflection: nb argument-buffer bindings (binding i at aid[i], an array of n[i] entries when n[i] > 0)
    NvShader *o = [NvShader new]; o->fn = f; o->stage = 1; strlcpy(o->key, "t_argenc", sizeof o->key);
    o->rf.b = calloc((size_t)nb, sizeof *o->rf.b); REQUIRE(o->rf.b);   // nb bindings (nvn_refl.h: allocated to the count)
    o->rf.nb = nb; o->rf.abi = 0;
    for (int i = 0; i < nb; i++) { o->rf.b[i].aid = aid[i]; o->rf.b[i].n = n[i]; }
    return o;
}
static NvShader *sh(id<MTLFunction> f, int top) {   // ids 0..top: one array of top + 1 entries (n is uint8_t: past 256 entries a single binding at id top)
    uint16_t a = top < 256 ? 0 : (uint16_t)top; uint8_t n = top < 256 ? (uint8_t)(top + 1) : 0;
    return shn(f, 1, &a, &n);
}
static int pso_ok(id<MTLFunction> fs) {   // Metal builds a render pipeline with it (the backend compiler accepts the layout, not only the front end)
    NSError *e = nil; id<MTLLibrary> vl = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nvertex float4 v() { return float4(0, 0, 0, 1); }\n" options:nil error:&e];
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; d.vertexFunction = [vl newFunctionWithName:@"v"]; d.fragmentFunction = fs;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    return [g_dev newRenderPipelineStateWithDescriptor:d error:&e] != nil;
}
// 子进程是重新执行的自己（posix_spawn + 模式参数），不是 fork：Metal 初始化后 fork 不 exec，子进程继承父进程 Metal 后台线程持着的半截锁状态，
//   门禁并行负载下随机 abort（134）/ 段错误（139），③ 与反证轮流红（10-30 列车两批）。各自是干净进程、自己 mtl_init。
static int child(const char *self, const char *mode) {   // exit status, or 128 + signal
    fflush(stdout); pid_t p; char *av[] = {(char *)self, (char *)mode, NULL};
    REQUIRE(posix_spawn(&p, self, NULL, NULL, av, environ) == 0);
    int st; waitpid(p, &st, 0); return WIFSIGNALED(st) ? 128 + WTERMSIG(st) : WEXITSTATUS(st);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
        const char *mode = argc > 1 ? argv[1] : "";
        if (!strcmp(mode, "--argcheck")) setenv("S2A_ARGCHECK", "1", 1);   // 开关按进程只读一次：在 mtl_init 之前设
        mtl_init(); if (!*mode) printf("DEVICE %s backend=Metal%d\n", g_dev.name.UTF8String, g_m3 ? 3 : 4);
        NSError *e = nil;
        id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct AB { device float *a [[id(0)]]; device float *b [[id(1)]]; device float *c [[id(2)]]; device float *d [[id(3)]]; };\n"
            "fragment float4 withab(constant AB &ab [[buffer(0)]]) { return float4(ab.a[0] + ab.b[0] + ab.c[0] + ab.d[0]); }\n"
            "fragment float4 noab() { return float4(1); }\n" options:nil error:&e];
        REQUIRE(lib); g_with = [lib newFunctionWithName:@"withab"]; g_without = [lib newFunctionWithName:@"noab"]; REQUIRE(g_with && g_without);

        if (!strcmp(mode, "--argcheck")) { NvShader *c = sh(g_with, 6); return shader_args_init(c) == 0 && c->arg_len == 56 ? 0 : 1; }   // ③ 的子进程
        if (!strcmp(mode, "--ask")) { (void)[g_without newArgumentEncoderWithBufferIndex:0]; return 0; }   // ② 反证的子进程：照旧问 Metal
        int r = child(argv[0], "--argcheck");
        VERIFY(r == 0, "③ S2A_ARGCHECK=1、Metal 32 字节对反射 56：这支不可用、不 abort（子进程结束于 %d，期望 0）", r);
        NvShader *a = sh(g_with, 3);
        VERIFY(shader_args_init(a) == 1 && a->arg_len == 32, "① 带参数块、编号 0..3：可用、长度 %lu（期望 32）", (unsigned long)a->arg_len);
        NSUInteger ml = [g_with newArgumentEncoderWithBufferIndex:0].encodedLength;
        VERIFY(ml == 32, "① Metal 自己算的长度 %lu（期望 32：每个编号 8 字节）", (unsigned long)ml);

        NvShader *b = sh(g_without, 3);
        VERIFY(shader_args_init(b) == 1 && b->arg_len == 32, "② 函数没有参数块、反射说有：不问 Metal、不崩，长度 %lu（期望 32）", (unsigned long)b->arg_len);
        r = child(argv[0], "--ask");
        VERIFY(r == 128 + SIGABRT, "② 反证：照旧问 Metal 的子进程结束于 %d（期望 %d = SIGABRT）", r, 128 + SIGABRT);


        NvShader *d = sh(g_with, NVN_REFL_MAXARG);
        VERIFY(shader_args_init(d) == 0, "④ 参数编号到 %d（超出上限 %d）：不可用", NVN_REFL_MAXARG, NVN_REFL_MAXARG - 1);

        // ⑤ 马力欧派对 3f4381bb6ab7df96_b 的参数块（真库 json 照抄形状）：编号 0..38 单项，39 / 71 / 103 / 135 / 167 各 32 项数组（纹理、采样器、纹理…），199..202 单项
        uint16_t pa[48]; uint8_t pn[48]; int np = 0;
        for (int i = 0; i <= 38; i++) { pa[np] = (uint16_t)i; pn[np++] = 0; }
        for (int i = 0; i < 5; i++) { pa[np] = (uint16_t)(39 + 32 * i); pn[np++] = 32; }
        for (int i = 199; i <= 202; i++) { pa[np] = (uint16_t)i; pn[np++] = 0; }
        NvShader *p = shn(g_with, np, pa, pn);
        VERIFY(shader_args_init(p) == 1 && p->arg_len == 1624, "⑤ 马力欧派对真实参数块（编号到 202）：可用、长度 %lu（期望 8 × 203 = 1624）", (unsigned long)p->arg_len);
        NSMutableString *ms = [NSMutableString stringWithString:@"#include <metal_stdlib>\nusing namespace metal;\nstruct AB {\n"];
        for (int i = 0; i <= 38; i++) [ms appendFormat:@" device float *p%d [[id(%d)]];\n", i, i];
        [ms appendString:@" array<texturecube<float>, 32> a0 [[id(39)]];\n array<sampler, 32> a1 [[id(71)]];\n array<texturecube<float>, 32> a2 [[id(103)]];\n"
            " array<texture2d<float>, 32> a3 [[id(135)]];\n array<texture2d<float>, 32> a4 [[id(167)]];\n texture2d<uint> im [[id(199)]];\n"
            " device uint *p199 [[id(200)]];\n constant uint *p200 [[id(201)]];\n constant float4 *p201 [[id(202)]];\n};\n"
            "fragment float4 party(constant AB &ab [[buffer(0)]], float4 pos [[position]]) { uint k = uint(pos.x) & 31u; float s = ab.p0[0] + ab.p38[0] + float(ab.p199[0]) + float(ab.p200[0]) + ab.p201[0].x;\n"
            " return ab.a0[k].sample(ab.a1[k], float3(s)) + ab.a2[k].sample(ab.a1[0], float3(0)) + ab.a3[k].sample(ab.a1[1], float2(s)) + ab.a4[k].sample(ab.a1[2], float2(0)) + float4(ab.im.read(uint2(0)));\n}\n"];
        e = nil; id<MTLLibrary> pl = [g_dev newLibraryWithSource:ms options:nil error:&e]; id<MTLFunction> pf = [pl newFunctionWithName:@"party"];
        NSUInteger pml = pf ? [pf newArgumentEncoderWithBufferIndex:0].encodedLength : 0;
        VERIFY(pf && pml == 1624 && pso_ok(pf), "⑤ Metal 编出同布局函数（%s）、自己算的长度 %lu（期望 1624）、能建管线", pf ? "编过" : e.description.UTF8String, (unsigned long)pml);

        uint16_t ta[2] = {0, NVN_REFL_MAXARG - 1}; uint8_t tn[2] = {0, 0};   // 上千项的数组装不进反射 uint8_t 的 n：两个端点足以定最大编号
        NvShader *t = shn(g_with, 2, ta, tn);
        VERIFY(shader_args_init(t) == 1 && t->arg_len == 8 * NVN_REFL_MAXARG, "⑤ 编号顶满上限 %d：可用、长度 %lu（期望 %d）", NVN_REFL_MAXARG - 1, (unsigned long)t->arg_len, 8 * NVN_REFL_MAXARG);
        NSString *ts = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\nstruct AB { array<texture2d<float>, %d> t [[id(0)]]; device float *p [[id(%d)]]; };\n"
            "fragment float4 top(constant AB &ab [[buffer(0)]], float4 pos [[position]]) { return ab.t[uint(pos.x) %% %du].read(uint2(0)) + ab.p[0]; }\n", NVN_REFL_MAXARG - 1, NVN_REFL_MAXARG - 1, NVN_REFL_MAXARG - 1];
        e = nil; id<MTLLibrary> tl = [g_dev newLibraryWithSource:ts options:nil error:&e]; id<MTLFunction> tf = [tl newFunctionWithName:@"top"];
        NSUInteger tml = tf ? [tf newArgumentEncoderWithBufferIndex:0].encodedLength : 0;
        VERIFY(tf && tml == 8 * NVN_REFL_MAXARG && pso_ok(tf), "⑤ Metal 编出顶满上限的函数（%s）、自己算的长度 %lu（期望 %d）、能建管线", tf ? "编过" : e.description.UTF8String, (unsigned long)tml, 8 * NVN_REFL_MAXARG);

        printf("%s t_nvn_argenc：%u 项，%u 项失败（%s）\n", failures ? "✗" : "✓", checks, failures, g_m3 ? "Metal 3" : "Metal 4");
        return failures != 0;
    }
}
