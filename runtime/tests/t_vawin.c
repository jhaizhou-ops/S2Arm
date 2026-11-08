// 窗口单测：构造函数（链进本程序的 vawin.c）应已占到窗口——本款跨度给 62 GB（S2A_WIN_NEED_MB，单测没有 main.npdm）+ 尾部统一分配 2 GB = 64 GB，
//   放进 2^39 以下放得下的最高空洞（本机 macOS：只有 [0x70, 0x80) 这块 64 GB 放得下，手量），再往窗口中间建议映射应拿不到
#include "../src/native.h"
#include <sys/mman.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <sys/resource.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <time.h>
__attribute__((constructor(100))) static void need(void) { setenv("S2A_WIN_NEED_MB", "63488", 1); }   // 先于 vawin.c 的构造函数（101）
int main(void) {
    int bad = 0;
    if (!dlsym(RTLD_DEFAULT, "s2a_vaguard_open")) { printf("✗ 地址护栏库没载入（应在可执行文件同目录；弱链接找不到会静默不装，macOS 27 上窗口被 malloc 占走）\n"); bad++; }
    if (!s2a_window_ok()) { printf("✗ 窗口没占到\n"); bad++; }
    uint64_t b, n; s2a_window_get(&b, &n);
    if (b != 0x7000000000ull || n != (64ull << 30)) { printf("✗ 窗口 %#llx +%llu MB，应为 0x7000000000 +65536 MB\n", (unsigned long long)b, (unsigned long long)(n >> 20)); bad++; }
    { uint64_t nd, fit; s2a_window_need(&nd, &fit); if (nd != (62ull << 30) || fit < (64ull << 30)) { printf("✗ 本款跨度 %llu MB（应 63488）、最大能放 %llu MB（应 ≥ 65536）\n", (unsigned long long)(nd >> 20), (unsigned long long)(fit >> 20)); bad++; } }
    void *p = mmap((void *)(b + n / 2), 1 << 20, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p != MAP_FAILED && (uint64_t)p >= b && (uint64_t)p < b + n) { printf("✗ 窗口内还能映射到 %p\n", p); bad++; }
    s2a_window_probe("单测");
    // 客体窗口常驻（心跳读数）：窗口里映射 64 MB 可写匿名页、写满其中 40 MB → 常驻增量 40 MB（±1 页）；未写的 24 MB 不计；记一次扫整窗耗时
    { uint64_t r0, o0, r1, o1; s2a_window_resident(&r0, &o0);
      uint8_t *q = mmap((void *)(b + 0x100000000ull), 64u << 20, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
      if (q == MAP_FAILED) { printf("✗ 窗口内固定映射 64 MB 失败\n"); bad++; }
      else { memset(q, 1, 40u << 20);
        struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0); s2a_window_resident(&r1, &o1); clock_gettime(CLOCK_MONOTONIC, &t1);
        int64_t d = (int64_t)(r1 - r0), pg = getpagesize();
        printf("· 客体窗口常驻：写 40 MB 后增量 %lld KB（期望 %d KB ± 1 页），扫整窗 %.1f ms\n", (long long)(d >> 10), 40 << 10, (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6);
        if (d < (40ll << 20) - pg || d > (40ll << 20) + pg) { printf("✗ 常驻增量 %lld KB，应 %d KB ± 1 页\n", (long long)(d >> 10), 40 << 10); bad++; }
        // 按区段扫（S2A_MEM_SPLIT 分区账）：只扫这 64 MB → 常驻正好 40 MB；只扫未写的后 24 MB → 0；扫写过的前 16 MB → 16 MB
        { uint64_t ra, oa, rb, ob, rc, oc; s2a_range_resident((uint64_t)q, 64u << 20, &ra, &oa); s2a_range_resident((uint64_t)q + (40u << 20), 24u << 20, &rb, &ob); s2a_range_resident((uint64_t)q, 16u << 20, &rc, &oc);
          printf("· 区段常驻：64 MB 段 %llu KB（期望 %d）、未写 24 MB 段 %llu KB（期望 0）、前 16 MB 段 %llu KB（期望 %d）\n", (unsigned long long)(ra >> 10), 40 << 10, (unsigned long long)(rb >> 10), (unsigned long long)(rc >> 10), 16 << 10);
          if (ra != (40ull << 20) || rb != 0 || rc != (16ull << 20)) { printf("✗ 区段常驻不符\n"); bad++; } }
        mmap(q, 64u << 20, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0); } }
    // 句柄用量（10-21 巫师3 归档开不了，现场要分清地址 / 句柄）：多开 5 个句柄计数正好 +5、全关回原数；软 / 硬上限与 getrlimit 一致
    { int n0, n1, n2; uint64_t s, h; s2a_fd_usage(&n0, &s, &h);
      struct rlimit rl; getrlimit(RLIMIT_NOFILE, &rl);
      if (s != rl.rlim_cur || h != rl.rlim_max) { printf("✗ 句柄上限 软 %llu 硬 %llu，getrlimit 为 %llu / %llu\n", (unsigned long long)s, (unsigned long long)h, (unsigned long long)rl.rlim_cur, (unsigned long long)rl.rlim_max); bad++; }
      int fds[5]; for (int i = 0; i < 5; i++) fds[i] = open("/dev/null", O_RDONLY);
      s2a_fd_usage(&n1, &s, &h); for (int i = 0; i < 5; i++) close(fds[i]); s2a_fd_usage(&n2, &s, &h);
      if (n1 != n0 + 5 || n2 != n0) { printf("✗ 句柄计数 原 %d、多开 5 个后 %d（应 %d）、全关后 %d（应 %d）\n", n0, n1, n0 + 5, n2, n0); bad++; } }
    // 窗口尾部统一分配（10-24，缺省开）：收到 61 GB + 258 MB 后尾部 2814 MB 里前 256 MB 不还系统、交给 s2a_tail_map，后 2558 MB 还系统（窗口顶到空洞末尾、上方没有 ≥ 4 GB 空闲 → 只接管 TL_SMALL；空洞正好 +2558 MB；放在最后：收尾不可逆）
    { uint64_t t0, l0, t1, l1; s2a_low_holes(&t0, &l0); s2a_window_trim(61ull * (1ull << 30) + (258ull << 20)); s2a_low_holes(&t1, &l1);
      if (t1 != t0 + (2558ull << 20)) { printf("✗ 尾部应接管 256 MB、还系统 2558 MB，空洞实多 %lld MB\n", (long long)((int64_t)(t1 - t0) >> 20)); bad++; }
      uint64_t tb = b + 61ull * (1ull << 30) + (258ull << 20), te = tb + (256ull << 20), M = 1ull << 20;
      // ① 落进尾部、首次适配连续、可写、虚存标签 = 242 + 使用者
      uint8_t *a1 = s2a_tail_map(M, S2A_TAIL_STACK, PROT_READ | PROT_WRITE), *a2 = s2a_tail_map(M, S2A_TAIL_STACK, PROT_READ | PROT_WRITE), *a3 = s2a_tail_map(M, S2A_TAIL_RYU, PROT_READ | PROT_WRITE);
      if (!a1 || (uint64_t)a1 != tb || a2 != a1 + M || a3 != a2 + M || !s2a_tail_has(a3)) { printf("✗ 尾部分配应从 %#llx 起连续 3 MB，得 %p %p %p\n", (unsigned long long)tb, a1, a2, a3); bad++; }
      else { memset(a1, 7, M); memset(a3, 9, M);
        vm_address_t ra = (vm_address_t)a3; vm_size_t rs = 0; natural_t d = 0; vm_region_submap_info_data_64_t si; mach_msg_type_number_t c = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &ra, &rs, &d, (vm_region_recurse_info_t)&si, &c) || si.user_tag != S2A_TAIL_TAG0 + S2A_TAIL_RYU) { printf("✗ 尾部映射标签应 %d，得 %u\n", S2A_TAIL_TAG0 + S2A_TAIL_RYU, si.user_tag); bad++; } }
      // ② 还回中间那块：回到 PROT_NONE；再要 1 MB 复用同一地址
      s2a_tail_unmap(a2, M, S2A_TAIL_STACK);
      { vm_address_t ra = (vm_address_t)a2; vm_size_t rs = 0; vm_region_basic_info_data_64_t bi; mach_msg_type_number_t c = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t o;
        if (vm_region_64(mach_task_self(), &ra, &rs, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&bi, &c, &o) || ra != (vm_address_t)a2 || bi.protection != VM_PROT_NONE) { printf("✗ 还回后应回 PROT_NONE（得 %d）\n", bi.protection); bad++; } }
      uint8_t *a4 = s2a_tail_map(M, S2A_TAIL_STACK, PROT_READ | PROT_WRITE);
      if (a4 != a2) { printf("✗ 还回的 1 MB 应被复用（%p），得 %p\n", a2, a4); bad++; }
      // ③ 放不下：带 S2A_TAIL_ONLY 回 NULL；不带则退回尾部以外的普通映射（可写），尾部账记「退回」
      //   先占到只剩 1 MB，再要 2 MB（低区空洞放得下的大小）
      uint64_t rest = te - (tb + 3 * M);
      uint8_t *fill = s2a_tail_map(rest - M, S2A_TAIL_METAL | S2A_TAIL_ONLY, PROT_NONE);
      uint8_t *big = s2a_tail_map(2 * M, S2A_TAIL_METAL | S2A_TAIL_ONLY, PROT_READ | PROT_WRITE), *fb = s2a_tail_map(2 * M, S2A_TAIL_METAL, PROT_READ | PROT_WRITE);
      if (!fill) { printf("✗ 尾部剩 %llu MB 应能占到只剩 1 MB\n", (unsigned long long)(rest >> 20)); bad++; }
      if (big) { printf("✗ 尾部放不下且带 ONLY 应回 NULL，得 %p\n", big); bad++; }
      if (!fb || s2a_tail_has(fb)) { printf("✗ 放不下应退回尾部以外的映射，得 %p\n", fb); bad++; } else { fb[0] = 1; s2a_tail_unmap(fb, 2 * M, S2A_TAIL_METAL); }
      s2a_tail_unmap(fill, rest - M, S2A_TAIL_METAL);
      char note[900]; s2a_tail_note(note, sizeof note);
      if (!strstr(note, "Metal 缓冲 在用 0.0 MB") || !strstr(note, "退回低区 2 次")) { printf("✗ 尾部账应记 Metal 退回 2 次：%s\n", note); bad++; }
      // ④ 全部还回后空闲段合并成一整段（剩余 = 接管 = 256 MB，最大空闲块同）
      s2a_tail_unmap(a1, M, S2A_TAIL_STACK); s2a_tail_unmap(a4, M, S2A_TAIL_STACK); s2a_tail_unmap(a3, M, S2A_TAIL_RYU);
      s2a_tail_note(note, sizeof note);
      if (!strstr(note, "接管 256 MB，已用 0.0 MB、剩余 256.0 MB（最大空闲块 256.0 MB、空闲段 1）")) { printf("✗ 全部还回后应合并成一整段：%s\n", note); bad++; }
      printf("· 窗口尾部分配：%s\n", note); }
    printf("%s t_vawin：%d 处不符\n", bad ? "✗" : "✓", bad);
    return bad != 0;
}
