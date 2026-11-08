// t_vawin_tail：窗口之上还有大块空闲时尾部接管 TL_TAKE（2 GB）——本款跨度给 30 GB（S2A_WIN_NEED_MB），窗口 = 30 + 2 = 32 GB 放进 [0x70, 0x80)（手量：本机只有它放得下），
//   其上 32 GB 空着（≥ 4 GB）；收到 30 GB 后尾部 2 GB 全部接管、不还系统（对照 t_vawin：窗口顶到空洞末尾只接管 256 MB）
#include "../src/native.h"
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
int s2a_host_hi_range(uint64_t *lo, uint64_t *hi);   // vawin.c（不进 native.h：它是抽取阶段的冷输入）
__attribute__((constructor(100))) static void need(void) { setenv("S2A_WIN_NEED_MB", "30720", 1); setenv("S2A_IPHONE_VA", "0", 1); }   // 先于 vawin.c 的构造函数（101）
int main(void) {
    int bad = 0; uint64_t b, n; s2a_window_get(&b, &n);
    if (!s2a_window_ok() || n != (32ull << 30)) { printf("✗ 窗口应占 32 GB，得 ok=%d %llu MB\n", s2a_window_ok(), (unsigned long long)(n >> 20)); bad++; }
    s2a_window_trim(30ull << 30);
    char note[900]; s2a_tail_note(note, sizeof note);
    if (!strstr(note, "接管 2048 MB")) { printf("✗ 窗口之上有大块空闲时尾部应接管 2048 MB：%s\n", note); bad++; }
    {   // 宿主高位区（甲：窗口放得下标准布局）= 收尾后的窗口之上到 2^39；直连库段（graphics/nvn/lib_pack.inc lp_map）带提示映射落在这里，跳过尾部那 2 GB 保留，
        //   不进 mmap(NULL) 挑的窗口下方低区（GC 新段只能落低区，11-05 赤痕 / 轩辕剑柒托管 OOM）
        uint64_t lo = 0, hi = 0, top = s2a_va_top(), h39 = 1ull << 39; if (top && top < h39) h39 = top;
        int rc = s2a_host_hi_range(&lo, &hi);
        if (rc != 1 || lo != b + (30ull << 30) || hi != h39) { printf("✗ 高位区应为 [%#llx, %#llx)，得 rc=%d [%#llx, %#llx)\n", (unsigned long long)(b + (30ull << 30)), (unsigned long long)h39, rc, (unsigned long long)lo, (unsigned long long)hi); bad++; }
        char tf[] = "/tmp/t_vawin_tail_f.XXXXXX"; int fd = mkstemp(tf); const size_t L = 4u << 20;
        if (fd < 0 || ftruncate(fd, L)) { printf("✗ 建临时文件失败\n"); bad++; }
        else { void *m = mmap((void *)lo, L, PROT_READ, MAP_PRIVATE, fd, 0), *z = mmap(NULL, L, PROT_READ, MAP_PRIVATE, fd, 0); uint64_t a = (uint64_t)m, c = (uint64_t)z;
            if (m == MAP_FAILED || a < b + (32ull << 30) || a + L > hi) { printf("✗ 带提示的文件映射应落在尾部之后、高位区内 [%#llx, %#llx)，得 %p\n", (unsigned long long)(b + (32ull << 30)), (unsigned long long)hi, m); bad++; }
            if (z == MAP_FAILED || c >= b) { printf("✗ 对照：mmap(NULL) 应落在窗口下方低区（< %#llx），得 %p\n", (unsigned long long)b, z); bad++; }
            if (m != MAP_FAILED) munmap(m, L); if (z != MAP_FAILED) munmap(z, L); close(fd); }
        unlink(tf); }
    printf("%s t_vawin_tail：%d 处不符\n", bad ? "✗" : "✓", bad); return bad != 0;
}
