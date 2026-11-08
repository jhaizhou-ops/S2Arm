// #329 第 2 类：真实 GPU 的 counts → c0 → 间接计算派发回归。
// 直接包含生产实现以访问 dispatch / encode_args；不替换生产函数或宿主符号。
// MSL 与反射是人工定义的输入夹具，本测试不覆盖 Maxwell → MSL 翻译。
#include "../gfx/nvn/nvn_mtl.m"
#include <sys/wait.h>

enum { SIDE = 8, WORDS = 8, PAYLOAD = SIDE * SIDE * SIDE * WORDS * 4,
       GUARD = 256, STRIDE = PAYLOAD + 2 * GUARD, POOL_SIZE = 131072,
       COUNTS_OFFSET = 260, CONFIG_OFFSET = 4096, CASES = 5 };
static const uint32_t SENTINEL = 0xa5a5a5a5u;
static unsigned failures, checks;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; \
    printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

// 每个实际线程独占一个固定坐标的记录，避免用待测 c0 值寻址而掩盖错误。
static NSString *const source = @"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct Args { const device uint *c0 [[id(0)]]; device uint *out [[id(1)]]; const device uint *cfg [[id(2)]]; };\n"
"kernel void counts_writer(constant Args &a [[buffer(0)]]) { a.out[0]=a.cfg[0]; a.out[1]=a.cfg[1]; a.out[2]=a.cfg[2]; }\n"
"inline void record(device uint *out, uint3 p, uint3 n, uint3 d) {\n"
"  if (any(p >= uint3(8))) return;\n"
"  uint i=((p.z*8+p.y)*8+p.x)*8;\n"
"  out[i]=d.x; out[i+1]=d.y; out[i+2]=d.z;\n"
"  out[i+3]=n.x; out[i+4]=n.y; out[i+5]=n.z; out[i+6]=i/8; out[i+7]=0x13579bdf;\n"
"}\n"
"kernel void reader_c0(constant Args &a [[buffer(0)]], uint3 p [[thread_position_in_grid]], uint3 n [[threadgroups_per_grid]]) {\n"
"  record(a.out,p,n,uint3(a.c0[128],a.c0[129],a.c0[130]));\n"
"}\n"
"kernel void reader_plain(constant Args &a [[buffer(0)]], uint3 p [[thread_position_in_grid]], uint3 n [[threadgroups_per_grid]]) {\n"
"  record(a.out,p,n,uint3(0xc0000001,0xc0000002,0xc0000003));\n"
"}\n";

static NvShader *fixture(id<MTLLibrary> library, NSString *name, int writer, int reads_c0) {
    NvShader *shader = [NvShader new]; shader->stage = 5;
    shader->fn = [library newFunctionWithName:name]; REQUIRE(shader->fn);
    shader->ae = [shader->fn newArgumentEncoderWithBufferIndex:0]; REQUIRE(shader->ae);
    shader->arg_len = shader->ae.encodedLength;
    REQUIRE(shader->arg_len >= 16 && shader->arg_len <= NVN_REFL_MAXARG * sizeof(uint64_t));
    REQUIRE(!(shader->arg_len % sizeof(uint64_t)));
    NSMutableArray *bindings = [NSMutableArray arrayWithObject:@{ @"kind": @"sbuf", @"reg": @0, @"arg_id": @1, @"rw": @YES }];
    if (writer) [bindings addObject:@{ @"kind": @"ubo_ptr", @"reg": @0, @"arg_id": @2 }];
    if (reads_c0) [bindings addObject:@{ @"kind": @"drvcb", @"bank": @0, @"arg_id": @0 }];
    NSDictionary *reflection = @{ @"route": @"B", @"bindings": bindings,
        @"threadgroup_size": writer ? @[@1, @1, @1] : @[@2, @2, @2] };
    char error[512]; REQUIRE(!nvn_refl_from_json(reflection, &shader->rf, error, sizeof error));
    REQUIRE(shader->rf.drv_read[0] == reads_c0);
    // ArgumentEncoder independently proves that the fixture's real MSL members
    // occupy the pointer slots the production reflection/encode_args ABI expects.
    id<MTLBuffer> layout = [g_dev newBufferWithLength:shader->arg_len options:MTLResourceStorageModeShared]; REQUIRE(layout);
    memset(layout.contents, 0, layout.length);
    [shader->ae setArgumentBuffer:layout offset:0];
    [shader->ae setBuffer:layout offset:0 atIndex:1];
    REQUIRE(((uint64_t *)layout.contents)[1] == layout.gpuAddress);
    if (writer) { [shader->ae setBuffer:layout offset:0 atIndex:2]; REQUIRE(((uint64_t *)layout.contents)[2] == layout.gpuAddress); }
    if (reads_c0) { [shader->ae setBuffer:layout offset:0 atIndex:0]; REQUIRE(((uint64_t *)layout.contents)[0] == layout.gpuAddress); }
    [shader->ae setArgumentBuffer:nil offset:0];
    return shader;
}

static void register_program(prog_t *guest, NvShader *shader) {
    memset(guest, 0, sizeof *guest); guest->magic = MAGIC('P', 'R', 'O', 'G'); guest->serial = nvn_new_serial();
    NvProg *program = [NvProg new]; program->sh[5] = shader; serial_put(guest->serial, program);
}

typedef struct { id<MTLBuffer> buffer; size_t offset; uint8_t before[DRV_SIZE]; } driver_snapshot;
static void consumer(prog_t *program, uint64_t output, uint64_t indirect, const uint32_t dimensions[3], driver_snapshot *snapshot) {
    S.cprog = program; S.ssbo[5][0] = (p_bind_buf){.addr = output, .size = PAYLOAD};
    p_dispatch command = {.x = (int)dimensions[0], .y = (int)dimensions[1], .z = (int)dimensions[2], .ind = indirect};
    dispatch(&command);
    if (snapshot) {
        REQUIRE(g_c0_dim_buf && g_c0_dim_off >= 0x200);
        snapshot->buffer = g_c0_dim_buf; snapshot->offset = g_c0_dim_off - 0x200;
        REQUIRE(snapshot->offset + DRV_SIZE <= snapshot->buffer.length);
        memcpy(snapshot->before, (uint8_t *)snapshot->buffer.contents + snapshot->offset, DRV_SIZE);
    } else REQUIRE(!g_c0_dim_buf);
}

static void writer(prog_t *program, uint64_t counts, uint64_t configuration) {
    S.cprog = program;
    S.ssbo[5][0] = (p_bind_buf){.addr = counts, .size = 12};
    S.ubo[5][0] = (p_bind_buf){.addr = configuration, .size = 12};
    p_dispatch command = {.x = 1, .y = 1, .z = 1}; dispatch(&command);
}

static void verify_output(const uint8_t *memory, unsigned which, const uint32_t dimensions[3], int reads_c0) {
    unsigned bad = 0, touched = 0;
    const uint32_t *out = (const uint32_t *)(memory + which * STRIDE + GUARD);
    for (unsigned z = 0; z < SIDE; z++) for (unsigned y = 0; y < SIDE; y++) for (unsigned x = 0; x < SIDE; x++) {
        unsigned i = (z * SIDE + y) * SIDE + x;
        int active = x < dimensions[0] * 2 && y < dimensions[1] * 2 && z < dimensions[2] * 2;
        touched += active;
        for (unsigned word = 0; word < WORDS; word++) {
            uint32_t expected = SENTINEL;
            if (active) expected = word < 3 ? (reads_c0 ? dimensions[word] : 0xc0000001u + word) :
                word < 6 ? dimensions[word - 3] : word == 6 ? i : 0x13579bdfu;
            if (out[i * WORDS + word] != expected) {
                if (!bad) printf("  case %u coordinate %u,%u,%u word %u: got %08x want %08x\n", which, x, y, z, word, out[i * WORDS + word], expected);
                bad++;
            }
        }
    }
    VERIFY(!bad, "case %u %s %ux%ux%u: %u actual threads, mismatched words %u", which,
        reads_c0 ? "c0" : "no c0", dimensions[0], dimensions[1], dimensions[2], touched, bad);
}

static int child(int metal3, int own) {
    alarm(60);
    mtl_init();
    REQUIRE(g_m3 == metal3 && dispatch_own() == own);
    if (!metal3) { int supported = 0; if (@available(macOS 26.0, *)) supported = [g_dev supportsFamily:MTLGPUFamilyMetal4]; REQUIRE(supported); }
    NSError *error = nil;
    MTLCompileOptions *options = [MTLCompileOptions new]; options.languageVersion = MTLLanguageVersion2_3;
    id<MTLLibrary> library = [g_dev newLibraryWithSource:source options:options error:&error];
    if (!library) fprintf(stderr, "MSL compile: %s\n", error.localizedDescription.UTF8String);
    REQUIRE(library);
    NvShader *write_shader = fixture(library, @"counts_writer", 1, 0);
    NvShader *read_shader = fixture(library, @"reader_c0", 0, 1);
    NvShader *plain_shader = fixture(library, @"reader_plain", 0, 0);
    prog_t write_program, read_program, plain_program;
    register_program(&write_program, write_shader); register_program(&read_program, read_shader); register_program(&plain_program, plain_shader);
    uint8_t *counts = NULL, *outputs = NULL;
    REQUIRE(!posix_memalign((void **)&counts, 16384, POOL_SIZE));
    REQUIRE(!posix_memalign((void **)&outputs, 16384, POOL_SIZE));
    memset(counts, 0xa5, POOL_SIZE); memset(outputs, 0xa5, POOL_SIZE);
    static const uint32_t dimensions[CASES][3] = {{2, 1, 3}, {3, 2, 2}, {1, 3, 2}, {2, 2, 1}, {1, 1, 2}};
    for (unsigned i = 0; i < CASES; i++) memcpy(counts + CONFIG_OFFSET + 16 * i, dimensions[i], 12);
    uint8_t *counts_before = malloc(POOL_SIZE); REQUIRE(counts_before); memcpy(counts_before, counts, POOL_SIZE);
    nvn_be_pool_add(counts, POOL_SIZE); nvn_be_pool_add(outputs, POOL_SIZE);
    uint64_t address = (uint64_t)(uintptr_t)counts, out_address = (uint64_t)(uintptr_t)outputs;
    driver_snapshot snapshots[4]; memset(snapshots, 0, sizeof snapshots);
    // One production submission, with no CPU read/wait between any producer and consumer.
    nvn_be_sub_begin();
    consumer(&read_program, out_address + GUARD, 0, dimensions[0], &snapshots[0]);
    for (unsigned i = 1; i < 4; i++) {
        writer(&write_program, address + COUNTS_OFFSET, address + CONFIG_OFFSET + 16 * i);
        // The CPU values are deliberately unrelated: only the GPU-written counts can pass.
        const uint32_t stale[3] = {7, 6, 5};
        consumer(i == 3 ? &plain_program : &read_program, out_address + i * STRIDE + GUARD,
            address + COUNTS_OFFSET, stale, i == 3 ? NULL : &snapshots[i]);
    }
    consumer(&read_program, out_address + 4 * STRIDE + GUARD, 0, dimensions[4], &snapshots[3]);
    uint64_t fence = nvn_be_sub_commit();
    REQUIRE(nvn_be_wait(fence, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
    for (unsigned i = 0; i < CASES; i++) verify_output(outputs, i, dimensions[i], i != 3);
    unsigned bad = 0;
    for (unsigned offset = 0; offset < POOL_SIZE; offset++) {
        int payload = 0;
        for (unsigned i = 0; i < CASES; i++) if (offset >= i * STRIDE + GUARD && offset < i * STRIDE + GUARD + PAYLOAD) payload = 1;
        if (!payload && outputs[offset] != 0xa5) bad++;
    }
    VERIFY(!bad, "output guards and unused pool: mismatched bytes %u", bad);
    memcpy(counts_before + COUNTS_OFFSET, dimensions[3], 12);
    VERIFY(!memcmp(counts_before, counts, POOL_SIZE), "GPU counts at nonzero offset %u: final counts and all surrounding bytes", COUNTS_OFFSET);
    for (unsigned i = 0; i < 4; i++) {
        unsigned which = i == 3 ? 4 : i;
        memcpy(snapshots[i].before + 0x200, dimensions[which], 12);
        VERIFY(!memcmp(snapshots[i].before, (uint8_t *)snapshots[i].buffer.contents + snapshots[i].offset, DRV_SIZE),
            "c0 case %u: correct 12-byte dimensions, all other %u bytes unchanged", which, DRV_SIZE - 12);
    }
    nvn_be_drain();
    printf("%s Metal %d own=%d: %u checks, %u failures (real GPU; Maxwell translation excluded)\n",
        failures ? "FAIL" : "PASS", metal3 ? 3 : 4, own, checks, failures);
    // Pools remain registered until process exit, as required by the real no-copy buffers.
    free(counts_before);
    return failures != 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 4 && !strcmp(argv[1], "--child")) return child(atoi(argv[2]), atoi(argv[3]));
        REQUIRE(argc == 1);
        unsigned bad = 0;
        // 第 5 路（10-26）：Metal 4、共用编码器、但设了已删的 DM_NVN_PASSGPU：派发路径必须不变（子进程里 dispatch_own() == own 的 REQUIRE 与全部 GPU 检查照跑）。
        //   旧代码设了它 dispatch_own() 就返回 1、每个派发单开编码器并挂 Metal 3 采样缓冲（暗黑3 真机带它第 670 帧崩）
        static const int runs[5][3] = {{0, 0, 0}, {0, 1, 0}, {1, 0, 0}, {1, 1, 0}, {0, 0, 1}};
        for (int r = 0; r < 5; r++) { int metal3 = runs[r][0], own = runs[r][1], passgpu = runs[r][2];
            fflush(NULL); pid_t pid = fork(); REQUIRE(pid >= 0);
            if (!pid) {
                if (passgpu) setenv("DM_NVN_PASSGPU", "/dev/null", 1); else unsetenv("DM_NVN_PASSGPU");
                if (metal3) setenv("NXGAL_BE", "mtl3", 1); else unsetenv("NXGAL_BE");
                setenv("DM_NVN_DISPATCH_OWN", own ? "1" : "0", 1);
                setenv("DM_NVN_ENC_THREAD", "0", 1); setenv("DM_PRESENT_LINK", "0", 1);
                execl(argv[0], argv[0], "--child", metal3 ? "1" : "0", own ? "1" : "0", (char *)NULL); _exit(127);
            }
            int status = 0; pid_t waited; do { waited = waitpid(pid, &status, 0); } while (waited < 0 && errno == EINTR);
            REQUIRE(waited == pid);
            int ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
            printf("%s process Metal %d own=%d%s (status=%d)\n", ok ? "PASS" : "FAIL", metal3 ? 3 : 4, own, passgpu ? " DM_NVN_PASSGPU set" : "", status);
            bad += !ok;
        }
        if (bad) printf("✗ t_nvn_dispatch：Metal 4 / 3 × 共用 / 独立编码器 4 路 + 设了 DM_NVN_PASSGPU 1 路，共 5 路里 %u 路不过\n", bad);   // 原生门禁按「✓ t_ / ✗ t_」逐组判（runtime/gate.sh）
        else printf("✓ t_nvn_dispatch：Metal 4 / 3 × 共用 / 独立编码器 4 路 + 设了 DM_NVN_PASSGPU 派发路径不变 1 路，5 路全过（c0 计数经 GPU 复制的间接派发）\n");
        return bad != 0;
    }
}
