// t_vawin_astype：本款跨度算不出时，红行按事实说原因（11-05 Minecraft: Story Mode：NPDM +0x0C = 0x03 → 地址空间类型 1（36 位），
//   布局只认类型 3，跨度为 0，旧红行报成「读不到本款 main.npdm」）。
//   做法：本程序把自己再起一遍（子进程），argv[1] = 临时模块目录，构造函数（链进来的 vawin.c）按它找 main.npdm；子进程 stderr 进文件，父进程核红行。
//   本程序不链 svc_mem.c，跨度由下面的桩 s2a_npdm_window_need 给（vawin.c 按名字 dlsym 取）：不设 T_NEED_MB 恒为 0，测「为 0 时说什么」；设了按它占窗口。
//   期望（手写，不取被测输出）：
//     ① +0x0C = 0x03（类型 1 = 36 位，11-06 起布局支持）、跨度 0 → 「类型 1（36 位），但算不出本款跨度」，没有「暂不支持」「读不到」，窗口没占
//     ② +0x0C = 0x01（类型 0）→ 有「NPDM 地址空间类型 0（32 位）暂不支持（布局只支持类型 1 = 36 位、3 = 39 位）」
//     ③ 目录里没有 main.npdm（正对照）→ 仍是「读不到本款 main.npdm」
//     ④ +0x0C = 0x07（类型 3）、跨度仍为 0 → 有「类型 3（39 位），但算不出本款跨度」，没有「读不到」
//     ⑤ 类型 1、跨度 4096 MB → 窗口占到且顶 ≤ 2^36（老 SDK 打包 HIPC 缓冲描述符只编 36 位地址，窗口在 2^36 之上游戏传给服务的缓冲地址丢高位），日志写「2^36 以下」
//     ⑥ 类型 3、跨度 4096 MB（对照）→ 窗口占到，日志写「2^39 以下」
#include "../src/native.h"
#include "../src/as_type.h"
#include <fcntl.h>
#include <spawn.h>
#include <sys/wait.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
extern char **environ;
__attribute__((visibility("default"), used)) uint64_t s2a_npdm_window_need(const char *npdm) { (void)npdm; const char *e = getenv("T_NEED_MB"); return e ? (uint64_t)atoll(e) << 20 : 0; }
static int bad;
// 本机 [4 GB, 2^36) 里最大的空洞（字节），与被测实现无关的独立读法（mach_vm_region 逐段走）：macOS 27 的共享缓存铺满 [6, 57) GB，
//   2^36 以下可能一块 4 GB 都放不下（11-06 mini 27.0.1 门禁红），⑤ 按本机实际有没有地方分两种期望
static uint64_t hole_below_2_36(void) {
    mach_vm_address_t a = 4ull << 30, prev_end = 4ull << 30; uint64_t best = 0;
    for (;;) {
        mach_vm_size_t sz = 0; natural_t depth = 0; vm_region_submap_info_data_64_t info; mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (mach_vm_region_recurse(mach_task_self(), &a, &sz, &depth, (vm_region_recurse_info_t)&info, &cnt) != KERN_SUCCESS || a >= (1ull << 36)) {
            uint64_t g = (1ull << 36) - prev_end; if (g > best) best = g; break; }
        if (a > prev_end && a - prev_end > best) best = a - prev_end;
        if (a + sz > prev_end) prev_end = a + sz; a += sz;
    }
    return best;
}
static void ck(int ok, const char *what) { printf("%s %s\n", ok ? "✓" : "✗", what); if (!ok) bad++; }
// 起子进程：模块目录 dir，返回子进程 stderr 全文（静态缓冲）与窗口是否占到
static const char *child(const char *self, const char *dir, int *win_ok) {
    static char out[8192]; char log[1200]; snprintf(log, sizeof log, "%s/stderr.txt", dir);
    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 2, log, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    char *av[] = {(char *)self, (char *)dir, "child", NULL}; pid_t p; int st = -1;
    if (posix_spawn(&p, self, &fa, NULL, av, environ) || waitpid(p, &st, 0) != p) st = -1;
    posix_spawn_file_actions_destroy(&fa);
    *win_ok = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    FILE *f = fopen(log, "r"); size_t n = f ? fread(out, 1, sizeof out - 1, f) : 0; if (f) fclose(f); out[n] = 0;
    return out;
}
static void npdm(const char *dir, int b0c) {
    char p[1200]; snprintf(p, sizeof p, "%s/main.npdm", dir);
    if (b0c < 0) { unlink(p); return; }
    uint8_t m[0x80] = {'M', 'E', 'T', 'A'}; m[0x0C] = (uint8_t)b0c;
    FILE *f = fopen(p, "wb"); fwrite(m, 1, sizeof m, f); fclose(f);
}
int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[2], "child")) { uint64_t b, z; s2a_window_get(&b, &z); fprintf(stderr, "astype=%d\nwin_end=%#llx\n", s2a_window_astype(), (unsigned long long)(b + z)); return s2a_window_ok(); }   // 子进程：构造函数已经打完红行；另报自检页要用的地址空间类型
    unsetenv("S2A_WIN_NEED_MB"); unsetenv("S2A_VAWIN_NORESERVE"); unsetenv("S2A_VA_CAP_MB"); unsetenv("S2A_VA_IOS26");
    char dir[] = "/tmp/t_vawin_astype.XXXXXX"; if (!mkdtemp(dir)) { printf("✗ mkdtemp\n"); return 1; }
    int w; const char *o;
    unsetenv("T_NEED_MB");
    npdm(dir, 0x03); o = child(argv[0], dir, &w);
    ck(strstr(o, "类型 1（36 位），但算不出本款跨度") != NULL, "① 类型 1 跨度 0：报「类型 1（36 位），但算不出本款跨度」");
    ck(!strstr(o, "暂不支持") && !strstr(o, "读不到本款 main.npdm"), "① 类型 1 跨度 0：不报「暂不支持」、不报「读不到」");
    ck(w == 0, "① 类型 1 跨度 0：窗口没占");
    ck(strstr(o, "astype=1\n") != NULL, "① 类型 1：s2a_window_astype() = 1");
    if (bad) printf("  子进程 stderr：%s\n", o);
    npdm(dir, 0x01); o = child(argv[0], dir, &w);
    ck(strstr(o, "NPDM 地址空间类型 0（32 位）暂不支持（布局只支持类型 1 = 36 位、3 = 39 位）") != NULL, "② 类型 0：报「NPDM 地址空间类型 0（32 位）暂不支持（布局只支持类型 1 = 36 位、3 = 39 位）」");
    npdm(dir, -1); o = child(argv[0], dir, &w);
    ck(strstr(o, "读不到本款 main.npdm") != NULL, "③ 没有 main.npdm（正对照）：仍报「读不到本款 main.npdm」");
    ck(strstr(o, "astype=-1\n") != NULL, "③ 没有 main.npdm：s2a_window_astype() = -1（自检页仍说资源不完整）");
    npdm(dir, 0x07); o = child(argv[0], dir, &w);
    ck(strstr(o, "类型 3（39 位），但算不出本款跨度") != NULL && !strstr(o, "读不到本款 main.npdm"), "④ 类型 3 跨度为 0：报「算不出本款跨度」、不报读不到");
    setenv("T_NEED_MB", "4096", 1); setenv("S2A_IPHONE_VA", "0", 1);
    npdm(dir, 0x03); o = child(argv[0], dir, &w);
    { const char *we = strstr(o, "win_end="); unsigned long long e = we ? strtoull(we + 8, NULL, 16) : 0;
      uint64_t hole = hole_below_2_36(); printf("  （本机 [4 GB, 2^36) 最大空洞 %llu MB）\n", (unsigned long long)(hole >> 20));
      if (hole >= (5ull << 30)) {   // 放得下（留 1 GB 余量给宿主下方保留）：窗口必须占到且整块在 2^36 以下
          ck(w == 1 && e && e <= (1ull << 36), "⑤ 类型 1 跨度 4096 MB、本机放得下：窗口占到、顶 ≤ 2^36");
          ck(strstr(o, "2^36 以下最大一块") != NULL, "⑤ 类型 1：日志写「2^36 以下」");
      } else if (hole < (4ull << 30)) {   // 放不下：不许越过 2^36 去占，报红写清是 2^36 以下放不下
          ck(!(w == 1 && e > (1ull << 36)), "⑤ 类型 1 跨度 4096 MB、本机 2^36 以下放不下：没有越过 2^36 去占窗口");
          ck(strstr(o, "2^36 以下") != NULL, "⑤ 类型 1 放不下：红行写「2^36 以下」");
      } else printf("  （⑤ 本机空洞 4–5 GB 之间，占不占取决于宿主下方保留，不判）\n");
      printf("  （⑤ 类型 1 窗口顶 %#llx）\n", e); if (bad) printf("  子进程 stderr：%s\n", o); }
    npdm(dir, 0x07); o = child(argv[0], dir, &w);
    ck(w == 1 && strstr(o, "2^39 以下最大一块") != NULL, "⑥ 类型 3 跨度 4096 MB（对照）：窗口占到、日志写「2^39 以下」");
    { const char *we = strstr(o, "win_end="); printf("  （⑥ 类型 3 窗口顶 %llx）\n", we ? strtoull(we + 8, NULL, 16) : 0ull); }
    unsetenv("T_NEED_MB"); unsetenv("S2A_IPHONE_VA");
    char rm[1200]; snprintf(rm, sizeof rm, "%s/stderr.txt", dir); unlink(rm); npdm(dir, -1); rmdir(dir);
    printf("%s t_vawin_astype：%d 处不符\n", bad ? "✗" : "✓", bad); return bad != 0;
}
