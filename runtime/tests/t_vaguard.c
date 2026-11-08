// 地址窗口护栏单测（issue #100 D01）：假 malloc 库（support/fake_xzm.c）在初始化里往窗口固定映射 12 GB，比 vawin.c 的构造函数早。
//   带护栏（libs2a_vaguard）：那次映射被拒（KERN_NO_SPACE = 3），窗口整块占到；不带护栏（旧行为）：映射建成，窗口占不到。
//   本程序按参数 guard / noguard 各编一份（runtime/build.mk 的 native-test-vaguard 两份都跑），只有 guard 那份打「✓ / ✗ t_vaguard」
#include "../src/native.h"
#include <string.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
extern int g_fake_xzm_rc;
__attribute__((constructor(100))) static void need(void) { setenv("S2A_WIN_NEED_MB", "63488", 1); }   // 本款跨度 62 GB + 尾部 2 GB = 64 GB：只有整块 [0x70, 0x80) 放得下
int main(int argc, char **argv) {
    int guard = argc > 1 && !strcmp(argv[1], "guard");
    if (argc > 1 && !strcmp(argv[1], "noreserve")) {
        // S2A_VAWIN_NORESERVE=1（不占窗口、只观察）：护栏也要放行——之后往窗口里固定映射 1 GB 应成功（#100 作者第 1 处：旧代码提前返回没放行，回 3）
        mach_vm_address_t a = 0x7800000000ull;
        kern_return_t kr = mach_vm_map(mach_task_self(), &a, 1ull << 30, 0, 0, MEMORY_OBJECT_NULL, 0, FALSE, VM_PROT_NONE, VM_PROT_NONE, VM_INHERIT_DEFAULT);
        printf("· t_vaguard NORESERVE：窗口内固定映射 1 GB 回 %d（应 0），窗口 %s（应没占）\n", kr, s2a_window_ok() ? "占了" : "没占");
        return kr == KERN_SUCCESS && !s2a_window_ok() ? 0 : 1;
    }
    if (argc > 1 && !strcmp(argv[1], "mmapfail")) {   // 窗口 mmap 被测试库弄失败：窗口应没占到；errno 由 make 规则从日志里核
        printf("· t_vaguard mmapfail：窗口 %s（应没占到）\n", s2a_window_ok() ? "占到" : "没占到");
        return s2a_window_ok() ? 1 : 0;
    }
    uint64_t b, n; s2a_window_get(&b, &n);
    int ok = s2a_window_ok() && b == 0x7000000000ull && n == (64ull << 30);
    if (guard) {
        int bad = 0;
        if (g_fake_xzm_rc != KERN_NO_SPACE) { printf("✗ 带护栏：假 malloc 的窗口内映射应被拒（KERN_NO_SPACE=3），实回 %d\n", g_fake_xzm_rc); bad++; }
        if (!ok) { printf("✗ 带护栏：窗口应整块占到，实 ok=%d %#llx +%llu MB\n", s2a_window_ok(), (unsigned long long)b, (unsigned long long)(n >> 20)); bad++; }
        printf("%s t_vaguard：%d 处不符（假 malloc 映射回 %d，窗口 %s）\n", bad ? "✗" : "✓", bad, g_fake_xzm_rc, ok ? "整块占到" : "没占到");
        return bad != 0;
    }
    // 反证（旧行为）：窗口占不到；打「·」行，不计组数。假 malloc 映射在本机应建成（0）；macOS 27 上真 malloc 先占了那段时会回 3，不影响判据
    printf("· t_vaguard 反证（不带护栏）：假 malloc 映射回 %d，窗口 %s（应没占到）\n", g_fake_xzm_rc, ok ? "整块占到" : "没占到");
    return ok ? 1 : 0;
}
