// 远端影子单测（far.c）：游戏地址保持不可访问（PROT_NONE 预留），内容在影子区；真信号走一遍缺页代执行。
//   期望值都从「往哪写了什么」直接推出，不调被测的翻译算式：经游戏地址写 → 影子里读到；影子里写 → 经游戏地址读到。
#include "../src/native.h"
#include <setjmp.h>
#include <signal.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include <sys/ucontext.h>
module_t *module_of(const void *p) { (void)p; return NULL; }   // 单测不装模块：点全记成宿主代码
static uint64_t g_he; uint64_t s2a_mem_heap_end(void) { return g_he; }   // 堆顶（svc_mem.c 的桩）：缺省 0 = 没有堆
int s2a_guest_zero(uint64_t a, uint64_t n) { (void)a; (void)n; return 0; } void *s2a_guest_map_any(uint64_t len) { (void)len; return MAP_FAILED; }   // vawin.c 的桩：没有客体内存文件后备
static int bad, cnt;
int s2a_far_session_reset(void);
#define EQ(name, want, got) do { unsigned long long w_ = (unsigned long long)(want), g_ = (unsigned long long)(got); cnt++; if (w_ != g_) { bad++; printf("✗ %s：期望 %#llx → 真结果 %#llx\n", name, w_, g_); } } while (0)
static uint64_t g_fc, g_fp, g_fn; static void fake_flush(const void *p, size_t n) { g_fc++; g_fp = (uint64_t)p; g_fn = n; }
static sigjmp_buf g_jb; static volatile int g_refused;
static void on_fault(int sig, siginfo_t *si, void *ctx) {
    uint32_t esr = ((ucontext_t *)ctx)->uc_mcontext->__es.__esr;
    if (s2a_far_fault(ctx, (uint64_t)si->si_addr, (int)(esr >> 6 & 1))) return;
    g_refused = 1; siglongjmp(g_jb, 1);
}
int main(void) {
    const uint64_t MB = 1ull << 20, SPAN = 16 * MB;
    // 影子区：布局给的堆区（窗口里的不可访问保留，这里自己占 64 MiB，没有堆）；远端：只取地址、不预先映射，s2a_far_set 自己把空洞占成不可访问
    const uint64_t SH = 64 * MB; uint8_t *sraw = mmap(NULL, SH + 2 * MB, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    uint8_t *shadow = (uint8_t *)(((uint64_t)sraw + 2 * MB - 1) & ~(2 * MB - 1));   // 同真实布局：堆区起止按 2 MiB 对齐
    uint8_t *raw = mmap(NULL, SPAN + 2 * MB, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0); munmap(raw, SPAN + 2 * MB);
    uint64_t G = ((uint64_t)raw + 2 * MB - 1) & ~(2 * MB - 1);   // 远端起点按 2 MiB 对齐（同布局：别名区伸出窗口处在 GiB 边界上）
    s2a_far_set(G, G + SPAN, (uint64_t)shadow, (uint64_t)shadow + SH);
    typedef struct { uint64_t lo; int64_t *dir; } far_desc_t;   // 同 far.c s2a_far_desc 布局（C# Native.FarDesc 照它声明）
    const far_desc_t *fd = s2a_far_desc_get();
    EQ("描述符（C# GuestMemory 取的那张）：远端起点", G, fd->lo); EQ("描述符：目录已建", 1, fd->dir != NULL);
    { uint8_t v; EQ("远端空洞已占成不可访问（mincore 认得这段 = 有映射）", 0, mincore((void *)G, 0x4000, (char *)&v)); }
    struct sigaction sa = {0}; sa.sa_sigaction = on_fault; sa.sa_flags = SA_SIGINFO; sigaction(SIGBUS, &sa, NULL); sigaction(SIGSEGV, &sa, NULL);
    EQ("给页 [G, +32K)", 0, s2a_far_map(G, 0x8000));
    EQ("给页 [G+2M, +16K)", 0, s2a_far_map(G + 2 * MB, 0x4000));
    uint8_t *h0 = s2a_far_g2h(G), *h2 = s2a_far_g2h(G + 2 * MB);
    EQ("描述符目录第 1 块 = 该块影子 − 游戏", (uint64_t)h2 - (G + 2 * MB), (uint64_t)fd->dir[1]);
    EQ("影子从堆区顶往下分：第一块在顶", (uint64_t)shadow + SH - 2 * MB, (uint64_t)(h0 - 0));
    EQ("第二块紧贴第一块下方（与游戏地址顺序相反，跨块访存走并排槽）", (uint64_t)h0 - 2 * MB, (uint64_t)h2);
    EQ("影子已分到的最低地址", (uint64_t)h2, s2a_far_floor());
    EQ("游戏地址本身仍不可访问（影子与游戏地址不同）", 1, (uint64_t)h0 != G);
    *(volatile uint64_t *)(G + 8) = 0x1122334455667788ull;
    EQ("经游戏地址写 8 字节 → 影子", 0x1122334455667788ull, *(uint64_t *)(h0 + 8));
    h0[16] = 0xAB;
    EQ("影子写 → 经游戏地址读 1 字节", 0xAB, *(volatile uint8_t *)(G + 16));
    { uint64_t a = 0x0101010101010101ull, b = 0x0202020202020202ull; __asm__ volatile("stp %0, %1, [%2]" :: "r"(a), "r"(b), "r"(G + 0x40) : "memory");
      EQ("寄存器对写 前半", a, *(uint64_t *)(h0 + 0x40)); EQ("寄存器对写 后半", b, *(uint64_t *)(h0 + 0x48)); }
    { memcpy(h0 + 0x3FFC, "\x11\x22\x33\x44\x55\x66\x77\x88", 8); uint64_t v; __asm__ volatile("ldr %0, [%1]" : "=r"(v) : "r"(G + 0x3FFC) : "memory");
      EQ("跨 16 KB 页（同一影子块）读 8 字节", 0x8877665544332211ull, v); }
    { memset(h0 + 0x80, 0xFF, 64); __asm__ volatile("dc zva, %0" :: "r"(G + 0x80) : "memory");
      uint64_t z = 0; for (int i = 0; i < 64; i++) z |= h0[0x80 + i]; EQ("DC ZVA 清影子 64 字节", 0, z); }
    __asm__ volatile("dc civac, %0" :: "r"(G + 0x100) : "memory"); EQ("DC CIVAC 跳过不崩", 0, g_refused);
    g_refused = 0; if (!sigsetjmp(g_jb, 1)) { (void)*(volatile uint64_t *)(G + 4 * MB); }
    EQ("碰没映射的远端地址：拒绝代执行（走崩溃老路）", 1, g_refused);
    { EQ("给页 [G+2M−16K, +16K)：与 [G+2M, …) 相邻", 0, s2a_far_map(G + 2 * MB - 0x4000, 0x4000));   // 第一块已分，只放开影子页
      uint64_t a = 0x0303030303030303ull, b = 0x0404040404040404ull; __asm__ volatile("stp %0, %1, [%2]" :: "r"(a), "r"(b), "r"(G + 2 * MB - 8) : "memory");
      EQ("跨 2 MiB 块（影子不相邻）的寄存器对写 前半（落第一块）", a, *(uint64_t *)(h0 + 2 * MB - 8)); EQ("跨块 后半（落第二块）", b, *(uint64_t *)h2);
      uint64_t v[2]; __asm__ volatile("ldp %0, %1, [%2]" : "=r"(v[0]), "=r"(v[1]) : "r"(G + 2 * MB - 8) : "memory");
      EQ("跨块读回 前半", a, v[0]); EQ("跨块读回 后半", b, v[1]); }
    // 独占 / 原子（far_atomic）：期望值从初值直接推
    { uint64_t g = G + 0x200; *(uint64_t *)(h0 + 0x200) = 41; uint32_t st;
      __asm__ volatile("1: ldaxr x8, [%1]\n add x8, x8, #1\n stlxr %w0, x8, [%1]\n cbnz %w0, 1b" : "=&r"(st) : "r"(g) : "x8", "memory");
      EQ("独占循环加一 41 → 42", 42, *(uint64_t *)(h0 + 0x200)); }
    { uint64_t g = G + 0x210, old; *(uint64_t *)(h0 + 0x210) = 100;
      __asm__ volatile(".arch armv8.1-a\n ldadd %1, %0, [%2]" : "=&r"(old) : "r"((uint64_t)5), "r"(g) : "memory");
      EQ("LDADD 回旧值 100", 100, old); EQ("LDADD 后 105", 105, *(uint64_t *)(h0 + 0x210)); }
    { uint64_t g = G + 0x220, e = 7; *(uint32_t *)(h0 + 0x220) = 7;
      __asm__ volatile(".arch armv8.1-a\n cas %w0, %w1, [%2]" : "+r"(e) : "r"((uint64_t)9), "r"(g) : "memory");
      EQ("CAS 成功：旧值 7", 7, e); EQ("CAS 成功：写成 9", 9, *(uint32_t *)(h0 + 0x220));
      e = 7; __asm__ volatile(".arch armv8.1-a\n cas %w0, %w1, [%2]" : "+r"(e) : "r"((uint64_t)11), "r"(g) : "memory");
      EQ("CAS 失败：回现值 9", 9, e); EQ("CAS 失败：不写", 9, *(uint32_t *)(h0 + 0x220)); }
    { uint64_t g = G + 0x230, old; *(uint64_t *)(h0 + 0x230) = 0xAA;
      __asm__ volatile(".arch armv8.1-a\n swp %1, %0, [%2]" : "=&r"(old) : "r"((uint64_t)0x55), "r"(g) : "memory");
      EQ("SWP 回旧值", 0xAA, old); EQ("SWP 写入", 0x55, *(uint64_t *)(h0 + 0x230)); }
    { uint64_t g = G + 0x240; uint32_t st; *(uint64_t *)(h0 + 0x240) = 1; *(uint64_t *)(h0 + 0x248) = 2;
      __asm__ volatile("1: ldxp x8, x9, [%1]\n add x8, x8, #10\n add x9, x9, #20\n stxp %w0, x8, x9, [%1]\n cbnz %w0, 1b" : "=&r"(st) : "r"(g) : "x8", "x9", "memory");
      EQ("独占对 前半 1 → 11", 11, *(uint64_t *)(h0 + 0x240)); EQ("独占对 后半 2 → 22", 22, *(uint64_t *)(h0 + 0x248)); }
    // SDK 内存函数族（s2a_far_bind）：G 起两块已分（[G, +32K) 与 [G+2M−16K, G+2M+16K)，两块影子不相邻）
    { void *(*mc)(void *, const void *, size_t) = (void *)s2a_far_bind("memcpy", 1), *(*ms)(void *, int, size_t) = (void *)s2a_far_bind("memset", 1),
           *(*mm)(void *, const void *, size_t) = (void *)s2a_far_bind("memmove", 1);
      EQ("不在名单的导入原样回", 77, s2a_far_bind("strlen", 77));
      uint8_t src[64]; for (int i = 0; i < 64; i++) src[i] = (uint8_t)(i + 1);
      mc((void *)(G + 2 * MB - 32), src, 64);   // 近 → 远端，跨块
      EQ("memcpy 跨块 前段落第一块影子", 1, h0[2 * MB - 32]); EQ("memcpy 跨块 后段落第二块影子", 64, h2[31]);
      uint8_t back[64]; mc(back, (void *)(G + 2 * MB - 32), 64);   // 远端 → 近
      EQ("memcpy 远端读回", 0, memcmp(back, src, 64));
      ms((void *)(G + 2 * MB - 8), 0xEE, 16); EQ("memset 跨块 前半", 0xEE, h0[2 * MB - 1]); EQ("memset 跨块 后半", 0xEE, h2[7]);
      for (int i = 0; i < 32; i++) h0[0x300 + i] = (uint8_t)i;
      mm((void *)(G + 0x304), (void *)(G + 0x300), 16);   // 远端内重叠后移
      EQ("memmove 重叠后移：首字节", 0, h0[0x304]); EQ("memmove 重叠后移：末字节", 15, h0[0x313]); }
    { void (*fl)(const void *, size_t) = (void *)s2a_far_bind("_ZN2nn2os14FlushDataCacheEPKvm", (uint64_t)fake_flush);
      uint8_t near[16]; fl(near, 16); EQ("FlushDataCache 近地址：原函数、原指针", (uint64_t)near, g_fp);
      g_fc = 0; fl((void *)(G + 0x100), 64); EQ("FlushDataCache 远端：原函数调 1 次", 1, g_fc); EQ("FlushDataCache 远端：传影子地址", (uint64_t)(h0 + 0x100), g_fp); EQ("FlushDataCache 远端：长度", 64, g_fn); }
    s2a_far_release(G, 0x4000); EQ("还页后再给", 0, s2a_far_map(G, 0x4000));
    EQ("还过的页再给出去是零页", 0, *(volatile uint64_t *)(G + 8));
    // 一次请求跨三块（[G+6M−16K, G+10M+16K) 涉及 3、4、5 号块）：三块影子按游戏地址升序连成一段（显存池整池一个零拷贝缓冲靠它）
    EQ("一次请求给页跨三块", 0, s2a_far_map(G + 6 * MB - 0x4000, 4 * MB + 0x8000));
    EQ("同请求的块影子连续 3→4", (uint64_t)s2a_far_g2h(G + 6 * MB - 0x4000) + 0x4000, (uint64_t)s2a_far_g2h(G + 6 * MB));
    EQ("同请求的块影子连续 4→5", (uint64_t)s2a_far_g2h(G + 6 * MB) + 2 * MB, (uint64_t)s2a_far_g2h(G + 8 * MB));
    // 堆区放不下（堆顶长到堆区顶）：影子改从宿主任意空闲地址整段分，照样连续、照样经游戏地址读写；堆的上限（s2a_far_floor）不动
    { uint64_t fl0 = s2a_far_floor(); g_he = (uint64_t)shadow + SH;
      EQ("堆区放不下：给页 [G+12M, +4M) 照样成功", 0, s2a_far_map(G + 12 * MB, 4 * MB));
      uint64_t h6 = (uint64_t)s2a_far_g2h(G + 12 * MB), h7 = (uint64_t)s2a_far_g2h(G + 14 * MB);
      EQ("堆区外的影子不在堆区里", 1, h6 + 4 * MB <= (uint64_t)shadow || h6 >= (uint64_t)shadow + SH);
      EQ("堆区外同请求的两块影子连续", h6 + 2 * MB, h7);
      if (h6 && h7) {   // 给页失败时游戏地址没有影子，再碰会一直缺页：上两项已报红，这里跳过
        *(volatile uint64_t *)(G + 14 * MB - 8) = 0x1122334455667788ull; EQ("经游戏地址写（缺页代执行）→ 堆区外影子读到", 0x1122334455667788ull, *(uint64_t *)(h7 - 8));
        *(uint64_t *)(h7 + 0x10) = 0xa5a5a5a5a5a5a5a5ull; EQ("堆区外影子写 → 经游戏地址读到", 0xa5a5a5a5a5a5a5a5ull, *(volatile uint64_t *)(G + 14 * MB + 0x10));
      } else EQ("堆区外影子已分", 1, 0);
      EQ("堆的上限不因堆区外的影子下移", fl0, s2a_far_floor()); g_he = 0; }
    s2a_far_report("单测");
    EQ("第一局远端退休", 0, s2a_far_session_reset());
    // 远端区间里有宿主可访问的映射（11-01 审计 P1-12）：不开远端——描述符目录留空、s2a_far_has 回 0（旧代码打红照开，游戏访存落到宿主内存上）
    { uint8_t *host = mmap((void *)(G + 4 * MB), 0x4000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
      EQ("重叠用例：在远端区间里放一页宿主读写映射", (uint64_t)(G + 4 * MB), (uint64_t)host);
      s2a_far_set(G, G + SPAN, (uint64_t)shadow, (uint64_t)shadow + SH);
      EQ("与宿主映射重叠：描述符目录留空 / 远端不认 / 堆上限不受影子限制", 0x101, (fd->dir == NULL ? 0x100 : 0) | (s2a_far_has(G, 0x4000) ? 0 : 1) | (s2a_far_floor() == UINT64_MAX ? 0 : 0x10));
      if (fd->dir) EQ("（重叠用例误开后退休）", 0, s2a_far_session_reset());
      mmap((void *)(G + 4 * MB), 0x4000, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0); }
    // 真实两块请求放不进一块大的影子区；不借助堆顶桩，走生产 mmap 溢出路径。
    s2a_far_set(G, G + SPAN, (uint64_t)shadow, (uint64_t)shadow + 2 * MB);
    EQ("小影子区放不下首个 4 MiB 请求", 0, s2a_far_map(G, 4 * MB));
    EQ("一块请求仍能使用窗口内影子", 0, s2a_far_map(G + 6 * MB, 0x4000));
    EQ("小影子区放不下第二个 4 MiB 请求", 0, s2a_far_map(G + 10 * MB, 4 * MB));
    uint8_t *overflow[4] = {s2a_far_g2h(G), s2a_far_g2h(G + 2 * MB),
        s2a_far_g2h(G + 10 * MB), s2a_far_g2h(G + 12 * MB)};
    for (unsigned i = 0; i < 4; i++) {
        EQ("退休前溢出块在窗口外", 1, (uint64_t)overflow[i] + 2 * MB <= (uint64_t)shadow || (uint64_t)overflow[i] >= (uint64_t)shadow + SH);
        overflow[i][0] = (uint8_t)(i + 1);
    }
    EQ("窗口内外影子混合退休", 0, s2a_far_session_reset());
    for (unsigned i = 0; i < 4; i++) {
        vm_address_t address = (vm_address_t)overflow[i]; vm_size_t size = 0;
        vm_region_basic_info_data_64_t info; mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        kern_return_t result = vm_region_64(mach_task_self(), &address, &size,
            VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
        if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
        EQ("退休后整个窗口外影子块没有 VM 映射", 1,
            result == KERN_INVALID_ADDRESS || (result == KERN_SUCCESS && address >= (vm_address_t)overflow[i] + 2 * MB));
    }
    { vm_address_t address = (vm_address_t)shadow; vm_size_t size = 0;
      vm_region_basic_info_data_64_t info; mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
      mach_port_t object = MACH_PORT_NULL;
      kern_return_t result = vm_region_64(mach_task_self(), &address, &size,
          VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
      if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
      EQ("窗口内影子仍交给 window reset 回收", 1,
          result == KERN_SUCCESS && address <= (vm_address_t)shadow && address + size >= (vm_address_t)shadow + 0x4000); }
    EQ("退休后远端描述符已撤销", 1, fd->dir == NULL && fd->lo == 0);
    EQ("空会话重复退休", 0, s2a_far_session_reset());
    // 影子页放不开（11-01 审计 P2-19）：影子区的最高保护压成只读，mprotect 读写必失败。期望：给页回 -1、目录不发布（游戏地址查不到影子）、
    //   影子余量收回（堆上限回到影子区顶）、之后同一块照常可给（旧代码先发布目录再 mprotect，失败不收回）
    { uint8_t *ro = mmap(NULL, 6 * MB, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0); uint64_t rb = ((uint64_t)ro + 2 * MB - 1) & ~(2 * MB - 1);
      EQ("放不开用例：影子区最高保护压成只读", KERN_SUCCESS, vm_protect(mach_task_self(), (vm_address_t)rb, 4 * MB, TRUE, VM_PROT_READ));
      s2a_far_set(G, G + SPAN, rb, rb + 4 * MB);
      EQ("影子页放不开：给页回 -1", (uint64_t)-1, (uint64_t)(int64_t)s2a_far_map(G, 0x4000));
      EQ("影子页放不开：目录不发布（游戏地址查不到影子）", 0, (uint64_t)s2a_far_g2h(G));
      EQ("影子页放不开：影子余量收回（堆上限 = 影子区顶）", rb + 4 * MB, s2a_far_floor());
      EQ("放不开用例退休", 0, s2a_far_session_reset()); munmap(ro, 6 * MB); }
    // 已分块里的页中途放不开（P2-19 后续）：块内 4 页原保护 读写 / 不可访问 / 不可访问 / 第 4 页最高保护压成只读（mprotect 读写必失败）。
    //   期望给页 [第 1 页, +4 页) 回 -1，前 3 页回到各自原保护（读写 / 无 / 无）；旧代码逐页改成读写、失败不退回（第 2、3 页留在读写）。
    //   再一例：请求跨已分块（1 页不可访问）与新块，新块影子放不开 → 已分块那页也要退回不可访问
    { uint8_t *sr = mmap(NULL, 10 * MB, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0); uint64_t sb = ((uint64_t)sr + 2 * MB - 1) & ~(2 * MB - 1);
      s2a_far_set(G, G + SPAN, sb, sb + 8 * MB);
      EQ("中途放不开用例：先给整块首 4 页", 0, s2a_far_map(G, 0x10000));
      uint8_t *c0 = s2a_far_g2h(G);
      s2a_far_release(G + 0x4000, 0x8000);   // 第 2、3 页还回 = 不可访问
      EQ("第 4 页最高保护压成只读", KERN_SUCCESS, vm_protect(mach_task_self(), (vm_address_t)(c0 + 0xC000), 0x4000, TRUE, VM_PROT_READ));
      EQ("第 4 页当前保护随之降为只读", KERN_SUCCESS, vm_protect(mach_task_self(), (vm_address_t)(c0 + 0xC000), 0x4000, FALSE, VM_PROT_READ));
      EQ("已分块第 4 页放不开：给页回 -1", (uint64_t)-1, (uint64_t)(int64_t)s2a_far_map(G, 0x10000));
      int pr[4];
      for (int i = 0; i < 4; i++) { vm_address_t ad = (vm_address_t)(c0 + i * 0x4000); vm_size_t sz = 0; vm_region_basic_info_data_64_t in; mach_msg_type_number_t ct = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t ob = MACH_PORT_NULL;
        pr[i] = vm_region_64(mach_task_self(), &ad, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&in, &ct, &ob) == KERN_SUCCESS && ad <= (vm_address_t)(c0 + i * 0x4000) ? in.protection : -1;
        if (ob != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), ob); }
      EQ("中途放不开：前 3 页保护回原值（读写 / 无 / 无 编码 0x300）、第 4 页仍只读", 0x3001, (uint64_t)(pr[0] << 12 | pr[1] << 8 | pr[2] << 4 | pr[3]));
      // 新块放不开：下一块影子落在 floor − 2M，先把它最高保护压成只读
      uint64_t nb = s2a_far_floor() - 2 * MB;
      EQ("新块影子最高保护压成只读", KERN_SUCCESS, vm_protect(mach_task_self(), (vm_address_t)nb, 2 * MB, TRUE, VM_PROT_READ));
      EQ("跨已分块与新块、新块放不开：给页回 -1", (uint64_t)-1, (uint64_t)(int64_t)s2a_far_map(G + 2 * MB - 0x4000, 0x8000));
      { vm_address_t ad = (vm_address_t)(c0 + 2 * MB - 0x4000); vm_size_t sz = 0; vm_region_basic_info_data_64_t in; mach_msg_type_number_t ct = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t ob = MACH_PORT_NULL;
        int p = vm_region_64(mach_task_self(), &ad, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&in, &ct, &ob) == KERN_SUCCESS && ad <= (vm_address_t)(c0 + 2 * MB - 0x4000) ? in.protection : -1;
        if (ob != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), ob);
        EQ("新块放不开：已分块那页退回不可访问", 0, (uint64_t)p); }
      EQ("中途放不开用例退休", 0, s2a_far_session_reset()); munmap(sr, 10 * MB); }
    printf("%s t_far：%d / %d 项通过\n", bad ? "✗" : "✓", cnt - bad, cnt);
    return bad != 0;
}
