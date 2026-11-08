// 存储缓冲地址不在任何内存池时报红（审计 #1565 P1-112 读数缺口：原先静默绑假缓冲，存储缓冲那种情形量不到）。生产 nvn_mtl.m 编进本 TU，走生产 encode_args。
// 期望（手写）：① 槽 0 绑在池里 → 不报（红计数 0）；② 槽 0 没绑（地址 0）→ 不报（没绑本来就读假缓冲）；③ 槽 0 绑一个池外地址 → 红 167 记一次；④ 再来一次 → 计数 2、红行仍只打一次（RED_ONCE）；
//   ⑤ 句柄放在统一缓冲里的存储缓冲（SBUFU），句柄指向池外 → 红 168 记一次
#include "../gfx/nvn/nvn_mtl.m"
#include <sys/mman.h>
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static NvShader *sb_shader(int kind) {   // 计算：参数 0 = 存储缓冲（SBUFP 槽 0，或 SBUFU：句柄在 cb0 + 0）
    NvShader *sh = [NvShader new]; sh->stage = 5; sh->arg_len = 8; strcpy(sh->key, kind == NVN_RB_SBUFP ? "t_sbuf_red_p" : "t_sbuf_red_u");
    sh->rf.nb = 1; sh->rf.b = calloc(1, sizeof *sh->rf.b); sh->rf.b[0].kind = kind; sh->rf.b[0].reg = 0; sh->rf.b[0].aid = 0; sh->rf.b[0].off = 0;
    return sh;
}
static void enc(NvShader *sh) { args_dirty_all(); encode_args(nil, sh, 5, 0); }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
    setenv("DM_NVN_ENC_THREAD", "0", 0); setenv("DM_PRESENT_LINK", "0", 1);
    mtl_init(); arena_begin();
    size_t psz = 65536; uint8_t *pool = mmap(NULL, psz, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); REQUIRE(pool != MAP_FAILED);
    nvn_be_pool_add(pool, psz);
    uint8_t *outside = mmap(NULL, 16384, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); REQUIRE(outside != MAP_FAILED);   // 不进池
    NvShader *p = sb_shader(NVN_RB_SBUFP), *u = sb_shader(NVN_RB_SBUFU);
    S.ssbo[5][0].addr = (uint64_t)(uintptr_t)pool; S.ssbo[5][0].size = 256; enc(p);
    VERIFY(g_red_once[167] == 0, "① 池里的存储缓冲：红计数 %d（期望 0）", g_red_once[167]);
    S.ssbo[5][0].addr = 0; S.ssbo[5][0].size = 0; enc(p);
    VERIFY(g_red_once[167] == 0, "② 没绑的存储缓冲：红计数 %d（期望 0）", g_red_once[167]);
    S.ssbo[5][0].addr = (uint64_t)(uintptr_t)outside; S.ssbo[5][0].size = 256; enc(p);
    VERIFY(g_red_once[167] == 1, "③ 池外地址：红计数 %d（期望 1）", g_red_once[167]);
    enc(p);
    VERIFY(g_red_once[167] == 2, "④ 再来一次：红计数 %d（期望 2，红行只打首例）", g_red_once[167]);
    uint64_t h = (uint64_t)(uintptr_t)outside; memcpy(pool + 1024, &h, 8);   // cb0 放池里，句柄指向池外
    S.ubo[5][0].addr = (uint64_t)(uintptr_t)(pool + 1024); S.ubo[5][0].size = 64; enc(u);
    VERIFY(g_red_once[168] == 1, "⑤ 句柄在统一缓冲里、指向池外：红计数 %d（期望 1）", g_red_once[168]);
  }
  printf("%s t_nvn_sbuf_red %u/%u（存储缓冲地址不在池里报红：池里 / 没绑不报，池外与句柄指向池外各报）\n", failures ? "✗" : "✓", checks - failures, checks);
  return failures != 0;
}
