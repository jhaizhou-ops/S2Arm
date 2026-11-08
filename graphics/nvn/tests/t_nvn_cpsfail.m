// 计算管线建失败只建一次（dispatch 的 g_cps 失败缓存）：直接包含生产 nvn_mtl.m，计算核是现编的真 Metal 函数，线程组内存 36880 字节（怪猎崛起同值），
//   超过 Apple 上限 32768，库编得过、建管线失败。期望值手写：同一着色器派发 3 次，建管线计数只 +1；反证：同一单测编改前的 nvn_mtl.m，计数 +3
#include "../gfx/nvn/nvn_mtl.m"

static unsigned failures, checks;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static NSString *const source = @"#include <metal_stdlib>\nusing namespace metal;\n"
"kernel void big(device uint *o [[buffer(0)]], uint t [[thread_index_in_threadgroup]]) {\n"
"  threadgroup uint s[9220];\n"   // 36880 字节
"  s[t] = t; threadgroup_barrier(mem_flags::mem_threadgroup); o[t] = s[9219 - t];\n"
"}\n";

int main(void) {
    @autoreleasepool {
        char map[] = "/tmp/t_cpsfail_map_XXXXXX"; int fd = mkstemp(map); REQUIRE(fd >= 0); close(fd); setenv("DM_NVN_SHMAP", map, 1);
        mtl_init();
        NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:source options:nil error:&e];
        REQUIRE(lib);
        NvShader *cs = [NvShader new]; cs->stage = 5; cs->fn = [lib newFunctionWithName:@"big"]; REQUIRE(cs->fn); strlcpy(cs->key, "eeeeeeeeeeeeeeee_b", sizeof cs->key);
        static prog_t guest; memset(&guest, 0, sizeof guest); guest.magic = MAGIC('P', 'R', 'O', 'G'); guest.serial = nvn_new_serial();
        NvProg *program = [NvProg new]; program->sh[5] = cs; serial_put(guest.serial, program);
        S.cprog = &guest;
        uint64_t n0 = g_bp_pso_n;
        for (int i = 0; i < 3; i++) { p_dispatch d = {.x = 1, .y = 1, .z = 1}; dispatch(&d); }
        VERIFY(g_bp_pso_n == n0 + 1, "线程组内存超限的计算核派发 3 次：建管线只 1 次（计数 %llu → %llu）", (unsigned long long)n0, (unsigned long long)g_bp_pso_n);
        unlink(map);
    }
    if (failures) { printf("✗ t_nvn_cpsfail：%u 项里 %u 项不符\n", checks, failures); return 1; }   // 原生门禁按「✓ t_ / ✗ t_」逐组判
    printf("✓ t_nvn_cpsfail：%u 项全过（建失败的计算管线只建一次、只报一次）\n", checks); return 0;
}
