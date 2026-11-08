// 客体内存文件后备（vawin.c guest_file_attach / s2a_guest_zero，S2A_GUEST_FILE=1）。
// 背景：11-05 时之笛 Switch 2 iPhone 读档进场景被单进程上限 8192 MB 杀；iOS 判杀按 phys_footprint，匿名脏页全计，文件 MAP_SHARED 映射的脏页不计。
// 期望（按宿主内核行为手写：同机小程序实测匿名写 512 MB 实占 +512 MB、文件映射写 512 MB +0.5 MB；文件打洞后读 0）：
//   ① 窗口文件后备：s2a_guest_fd() ≥ 0；窗口里放开 256 MB 写满，实占增量 < 16 MB（匿名会 +256 MB）
//   ② 还页：s2a_guest_zero 那 64 MB 之后放开再读全是 0，且这段在还页后不可访问（mprotect 才能读）
//   ③ 别名：vm_remap（copy = FALSE，同 svc_mem.c alias_map）把窗口里一页映到别处，两边写互相看得见
//   ④ 还页不影响邻居：还的那段之外紧挨着的页内容不变
#include "../src/native.h"
#include <sys/mman.h>
#include <mach/mach.h>
#include <string.h>
#include <unistd.h>
__attribute__((constructor(100))) static void need(void) { setenv("S2A_WIN_NEED_MB", "63488", 1); setenv("S2A_GUEST_FILE", "1", 1); setenv("S2A_GUEST_FILE_MIN_FREE_MB", "1", 1); }   // 空间门槛压到 1 MB：门禁机临时盘余量不定，这里只验接上后的行为（空间不够见 t_guest_file_nospace）   // 先于 vawin.c 的构造函数（101）
static long long fp(void) { task_vm_info_data_t i; mach_msg_type_number_t c = TASK_VM_INFO_COUNT; task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&i, &c); return (long long)i.phys_footprint; }
static int bad;
#define CHECK(c, ...) do { if (c) { printf("✓ "); } else { printf("✗ "); bad++; } printf(__VA_ARGS__); putchar('\n'); } while (0)
int main(void) {
    if (!s2a_window_ok()) { printf("✗ t_guest_file：窗口没占到\n"); return 1; }
    uint64_t b, n; s2a_window_get(&b, &n); size_t pg = (size_t)getpagesize();
    CHECK(s2a_guest_fd() >= 0, "① 窗口换成文件后备（fd %d）", s2a_guest_fd());
    uint8_t *q = (uint8_t *)(uintptr_t)(b + (4ull << 30)); size_t N = 256u << 20;
    if (mprotect(q, N, PROT_READ | PROT_WRITE)) { printf("✗ t_guest_file：放开 256 MB 失败\n"); return 1; }
    long long f0 = fp(); for (size_t i = 0; i < N; i += 64) q[i] = (uint8_t)(i >> 6) | 1; long long df = fp() - f0;
    CHECK(df < (16ll << 20), "① 窗口里写满 256 MB：实占 +%lld KB（期望 < 16384 KB；匿名内存会 +262144 KB）", df >> 10);
    uint8_t *z = q + (64u << 20);
    CHECK(s2a_guest_zero((uint64_t)(uintptr_t)z, 64u << 20) == 1, "② 还页 64 MB（打洞 + 重映射）");
    CHECK(mprotect(z, 64u << 20, PROT_READ | PROT_WRITE) == 0, "② 还过的段重新放开");
    size_t nz = 0; for (size_t i = 0; i < (64u << 20); i += 64) nz += z[i] != 0;
    CHECK(nz == 0, "② 还过的段读回全 0（非 0 %zu 处）", nz);
    CHECK(z[-64] == (uint8_t)(((64u << 20) - 64) >> 6 | 1) && z[64u << 20] == (uint8_t)(((128u << 20)) >> 6 | 1), "④ 还页段两侧的邻居内容不变（%#x %#x）", z[-64], z[64u << 20]);
    vm_address_t a = 0; vm_prot_t cur, max;
    kern_return_t kr = vm_remap(mach_task_self(), &a, pg, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)q, FALSE, &cur, &max, VM_INHERIT_SHARE);
    if (kr == KERN_SUCCESS) { uint8_t *al = (uint8_t *)a; al[5] = 0xAB; q[7] = 0xCD;
        CHECK(q[5] == 0xAB && al[7] == 0xCD, "③ vm_remap 别名：别处写 → 窗口读 %#x（期望 0xab），窗口写 → 别处读 %#x（期望 0xcd）", q[5], al[7]); }
    else CHECK(0, "③ vm_remap 别名失败 kr=%d", kr);
    {   // ⑤ 窗口外的文件后备段（远端影子区溢出，far.c）：能映射、写不计实占
        uint8_t *x = s2a_guest_map_any(64u << 20);
        CHECK(x != MAP_FAILED && !mprotect(x, 64u << 20, PROT_READ | PROT_WRITE), "⑤ 窗口外文件后备段 64 MB 映射并放开");
        if (x != MAP_FAILED) { long long g0 = fp(); for (size_t i = 0; i < (64u << 20); i += 64) x[i] = 3; long long dg = fp() - g0;
            CHECK(dg < (8ll << 20) && x[12345 * 64] == 3, "⑤ 写满 64 MB：实占 +%lld KB（期望 < 8192 KB）", dg >> 10); }
    }
    printf("%s t_guest_file：%d 项不符\n", bad ? "✗" : "✓", bad);
    return bad != 0;
}
