// 客体内存文件后备的空间检查（vawin.c guest_file_attach，11-05 能耗线）：临时目录剩余空间不到 S2A_GUEST_FILE_MIN_FREE_MB 时不接文件、照旧用匿名内存。
// 期望（按开关语义手写）：门槛设成 1 << 40 MB（任何盘都不够）→ ① s2a_guest_fd() == -1（没接文件）；② 窗口照常占到、放开 64 MB 写满，
//   实占增量 ≥ 48 MB（匿名内存按写入量计；接了文件会 < 16 MB，见 t_guest_file ①）
// 反证：去掉空间检查 → ① fd ≥ 0、② 实占增量只有几百 KB
#include "../src/native.h"
#include <sys/mman.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
__attribute__((constructor(100))) static void need(void) { setenv("S2A_WIN_NEED_MB", "63488", 1); setenv("S2A_GUEST_FILE", "1", 1); setenv("S2A_GUEST_FILE_MIN_FREE_MB", "1099511627776", 1); }   // 先于 vawin.c 的构造函数（101）
static long long fp(void) { task_vm_info_data_t i; mach_msg_type_number_t c = TASK_VM_INFO_COUNT; task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&i, &c); return (long long)i.phys_footprint; }
static int bad;
#define CHECK(c, ...) do { if (c) { printf("✓ "); } else { printf("✗ "); bad++; } printf(__VA_ARGS__); putchar('\n'); } while (0)
int main(void) {
    if (!s2a_window_ok()) { printf("✗ t_guest_file_nospace：窗口没占到\n"); return 1; }
    CHECK(s2a_guest_fd() == -1, "① 空间不够：不接文件（fd %d，期望 -1）", s2a_guest_fd());
    uint64_t b, n; s2a_window_get(&b, &n);
    uint8_t *q = (uint8_t *)(uintptr_t)(b + (4ull << 30)); size_t N = 64u << 20;
    if (mprotect(q, N, PROT_READ | PROT_WRITE)) { printf("✗ t_guest_file_nospace：放开 64 MB 失败\n"); return 1; }
    long long f0 = fp(); for (size_t i = 0; i < N; i += 64) q[i] = 1; long long df = fp() - f0;
    CHECK(df >= (48ll << 20), "② 退回匿名：窗口里写满 64 MB 实占 +%lld KB（期望 ≥ 49152 KB）", df >> 10);
    printf("%s t_guest_file_nospace：%d 项不符\n", bad ? "✗" : "✓", bad);
    return bad != 0;
}
