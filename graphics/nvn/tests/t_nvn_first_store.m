// 只有第一个调用写的存储由宿主在派发前写（nvn_refl.m first_store、nvn_mtl.m dispatch；补齐上游参考实现（MIT）c8521eeb / e07cba1c 的宿主半边）。
// 翻译器把「只有第一个调用执行」的常量存储从着色器里拿掉、写进反射顶层键 first_store [{reg, word, value}]（Switch 上它先于别的调用落地，
//   苹果 GPU 的工作组不按顺序开跑）；宿主在每次派发前把存储槽 reg 的第 word 个字写成 value，排在这次派发之前。
// 期望（按上面的语义手写，不由被测实现推出）：计算着色器只做 out[2] = out[1] + 1（一个线程），反射 first_store = [{reg 0, word 1, value 41}]，存储初值全 0：
//   ① 派发 1x1x1 → out[1] = 41、out[2] = 42（宿主的写先于派发）
//   ② 空派发（x = 0）→ 什么都不写（out[1] = 0、out[2] = 0）
//   ③ 槽 0 没绑 → 跳过、不崩，派发照常（着色器读写的槽没绑：这里只验不崩）
//   ④ 绑定只有 4 字节（字 1 在界外）→ 跳过：out[1] 仍 0
//   ⑤ 反射里 5 条 → 拒载；槽号 16 → 拒载；负字号 → 拒载
// NVN_FS_SOURCE 可指向别的 nvn_mtl.m 副本（修前 / 负对照编同一份单测）。
#ifndef NVN_FS_SOURCE
#define NVN_FS_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_FS_SOURCE

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int good_ = !!(c); failures += !good_; printf("%s ", good_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static prog_t pg; static uint32_t *mem;
static void run(int x, uint64_t addr, uint64_t size) {
    memset(mem, 0, 256);
    nvn_be_sub_begin(); state_reset(); S.cprog = &pg; S.ssbo[5][0] = (p_bind_buf){.stage = 5, .index = 0, .addr = addr, .size = size}; args_dirty_all();
    p_dispatch d = {.x = x, .y = 1, .z = 1}; dispatch(&d);
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
}
static NSDictionary *refl(NSArray *first) {
    NSMutableDictionary *j = [@{ @"route": @"B", @"threadgroup_size": @[@1, @1, @1], @"bindings": @[ @{ @"kind": @"sbuf", @"reg": @0, @"arg_id": @0, @"rw": @YES } ] } mutableCopy];
    if (first) j[@"first_store"] = first;
    return j;
}
int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0); alarm(120);
        mtl_init(); printf("DEVICE %s backend=Metal%d\n", g_dev.name.UTF8String, g_m3 ? 3 : 4);
        const op_hdr empty = {OP_END, sizeof(op_hdr)}; nvn_be_exec((const uint8_t *)&empty);
        NSError *e = nil; MTLCompileOptions *o = [MTLCompileOptions new]; o.languageVersion = MTLLanguageVersion2_3;
        id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct Args { device uint *out [[id(0)]]; };\n"
            "kernel void k(constant Args &a [[buffer(0)]], uint3 p [[thread_position_in_grid]]) { if (p.x == 0 && a.out) a.out[2] = a.out[1] + 1u; }\n" options:o error:&e];
        if (!lib) fprintf(stderr, "MSL: %s\n", e.localizedDescription.UTF8String); REQUIRE(lib);
        NvShader *cs = [NvShader new]; cs->stage = 5; cs->fn = [lib newFunctionWithName:@"k"]; REQUIRE(cs->fn);
        cs->ae = [cs->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(cs->ae); cs->arg_len = cs->ae.encodedLength;
        char err[256] = "";
        REQUIRE(!nvn_refl_from_json(refl(@[ @{ @"reg": @0, @"word": @1, @"value": @41 } ]), &cs->rf, err, sizeof err));
        pg = (prog_t){.magic = MAGIC('P', 'R', 'O', 'G'), .serial = nvn_new_serial()}; NvProg *np = [NvProg new]; np->sh[5] = cs; serial_put(pg.serial, np);
        REQUIRE(!posix_memalign((void **)&mem, 65536, 65536)); memset(mem, 0, 65536); nvn_be_pool_add(mem, 65536);   // 活到进程结束：生产池是不拷贝的 MTLBuffer
        uint64_t a = (uint64_t)(uintptr_t)mem;
        run(1, a, 256); CHECK(mem[1] == 41 && mem[2] == 42, "① 派发前写字 1：out[1] = %u、out[2] = %u（期望 41 / 42）", mem[1], mem[2]);
        run(0, a, 256); CHECK(mem[1] == 0 && mem[2] == 0, "② 空派发：out[1] = %u、out[2] = %u（期望 0 / 0）", mem[1], mem[2]);
        run(1, 0, 0); CHECK(1, "③ 槽没绑：跳过、不崩");
        run(1, a, 4); CHECK(mem[1] == 0, "④ 绑定 4 字节、字 1 在界外：out[1] = %u（期望 0，跳过）", mem[1]);
        nvn_refl r;
        NSArray *five = @[ @{ @"reg": @0, @"word": @0, @"value": @1 }, @{ @"reg": @0, @"word": @1, @"value": @1 }, @{ @"reg": @0, @"word": @2, @"value": @1 }, @{ @"reg": @0, @"word": @3, @"value": @1 }, @{ @"reg": @0, @"word": @4, @"value": @1 } ];
        memset(&r, 0, sizeof r); int r5 = nvn_refl_from_json(refl(five), &r, err, sizeof err);
        memset(&r, 0, sizeof r); int r16 = nvn_refl_from_json(refl(@[ @{ @"reg": @16, @"word": @0, @"value": @1 } ]), &r, err, sizeof err);
        memset(&r, 0, sizeof r); int rneg = nvn_refl_from_json(refl(@[ @{ @"reg": @0, @"word": @-1, @"value": @1 } ]), &r, err, sizeof err);
        CHECK(r5 && r16 && rneg, "⑤ 5 条 / 槽 16 / 负字号：拒载 %d / %d / %d（期望都非 0）", r5 != 0, r16 != 0, rneg != 0);
        printf("%s t_nvn_first_store: %u checks %u failures; backend Metal%d\n", failures ? "✗" : "✓", checks, failures, g_m3 ? 3 : 4);
        return failures != 0;
    }
}
