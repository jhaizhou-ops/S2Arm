// s2a_direct_ready 就绪判定口径单测（docs/设计_直连架构.md §12.3，10-24 写死）：期望值按口径手写，不由被测实现推出。
// 每例写一份 keys.tsv（S2A_GAME_DATA/shaders/direct/）与 seen_shaders.tsv（S2A_DOCS/wire/<程序号>/，测试里没有 main.npdm → 程序号 0）
#include "../src/native.h"
#include "s2a_gfx_mode.h"
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>

static char g_dir[256];
const char *s2a_module_dir(void) { return g_dir; }
void *sw_xstack_wrap(const char *name, void *fn) { (void)name; return fn; }
void *s2a_nvn_bootstrap_entry(void) { return NULL; }
uint64_t s2a_direct_lookup(const char *name);   // gfxmode.c（装载器 loader.c 同样自声明）
static char g_vk_impl;   // 假的 Vulkan 层：只认 vkCreateDevice（graphics/nvn/host_adapt.m s2a_vk_entry 的替身）
void *s2a_vk_entry(const char *name) { return !strcmp(name, "vkCreateDevice") ? &g_vk_impl : NULL; }
static int g_vk_lib;   // 假的 Vulkan 库就绪（graphics/nvn/gfx/vk/hle_vk.m s2a_vk_lib_ready 的替身；口径核对在那边）
int s2a_vk_lib_ready(const char *game_data) { (void)game_data; return g_vk_lib; }
static char g_gl_impl; static int g_gl_lib;   // 假的 OpenGL 层与 GL 库就绪（host_adapt.m s2a_gl_entry / gl_prog.m s2a_gl_lib_ready 的替身）：只认 eglGetProcAddress
void *s2a_gl_entry(const char *name) { return !strcmp(name, "eglGetProcAddress") ? &g_gl_impl : NULL; }
int s2a_gl_lib_ready(const char *game_data) { (void)game_data; return g_gl_lib; }
// 假的 Switch 2 视频接管层（graphics/nvn/gfx/nvn/nvn2_codec.c s2a_codec_entry 的替身）：记下问了几次；名字族的判定在入口里（这里只认 codec / syncpt / gs / 原生图像）——
//   核的是 gfxmode 的分派条件：C++ 名与 Nv* C 名都问入口、入口回 NULL 的照原路径，别的名字不问
static char g_cv_impl; static int g_cv_asked;
void *s2a_codec_entry(const char *name) {
    g_cv_asked++;
    return !strncmp(name, "_ZN2nn5codec", 12) || !strncmp(name, "_ZN2nn6syncpt", 13) || !strncmp(name, "_ZN2nn2gs", 9) || strstr(name, "nvnNativeImage") || strstr(name, "FromNativeImage") ? &g_cv_impl : NULL;
}
int s2a_direct_device_ok(void) { return getenv("T_NO_MTL4") == NULL; }   // 假的设备能力：设 T_NO_MTL4 当这台设备两条直连路（Metal 4 / Metal 3）都走不了

static void put(const char *path, const char *text) {
    if (!text) { unlink(path); return; }
    FILE *f = fopen(path, "w"); if (!f) { perror(path); exit(2); }
    fputs(text, f); fclose(f);
}
static int fails;
static void check(const char *name, const char *keys, const char *seen, int want) {
    char p[512];
    snprintf(p, sizeof p, "%s/gd/shaders/direct/keys.tsv", g_dir); put(p, keys);
    snprintf(p, sizeof p, "%s/docs/wire/0000000000000000/seen_shaders.tsv", g_dir); put(p, seen);
    int got = s2a_direct_ready();
    if (got != want) { fails++; printf("✗ %s：期望 %d，实际 %d\n", name, want, got); }
    else printf("  ✓ %s → %d\n", name, got);
}

#include "../../graphics/nvn/gfx/nvn/dmsh_chain.h"
#define A "00000b0b62850e7a"
#define B "000084a91b9e57a2"
int main(void) {
    snprintf(g_dir, sizeof g_dir, "/tmp/t_gfxmode.%d", (int)getpid());
    char p[512];
    const char *dirs[] = {"", "/gd", "/gd/shaders", "/gd/shaders/direct", "/docs", "/docs/wire", "/docs/wire/0000000000000000"};
    for (unsigned i = 0; i < sizeof dirs / sizeof *dirs; i++) { snprintf(p, sizeof p, "%s%s", g_dir, dirs[i]); mkdir(p, 0755); }
    snprintf(p, sizeof p, "%s/gd", g_dir); setenv("S2A_GAME_DATA", p, 1);
    snprintf(p, sizeof p, "%s/docs", g_dir); setenv("S2A_DOCS", p, 1);
    unsetenv("S2A_FAKE_DIRECT_READY");
    snprintf(p, sizeof p, "%s/gd/.applied", g_dir); put(p, "abc123\n");   // 资源包指纹：模式只定一次、指纹同时算，故在第一次 s2a_gfx_mode 之前写
    // 旧的直连失败标记（10-26 总指挥改定运行中不切换）：wire/<程序号>/fail 在（旧格式无指纹行 = 旧规则下照样作数、该退回通用）、包里有直连库、
    //   没有 S2A_GFX / mode 文件 → 期望仍选直连，fail 与 fail_seen 被删，日志有「删掉旧的直连失败标记」一行。模式每进程只定一次：放子进程里、在本进程第一次判模式之前
    { pid_t c = fork();
      if (!c) {
          char w[512], ws[512], lf[600], buf[4096] = "";
          snprintf(w, sizeof w, "%s/docs/wire/0000000000000000/fail", g_dir); snprintf(ws, sizeof ws, "%s/docs/wire/0000000000000000/fail_seen", g_dir);
          put(w, "GPU 命令缓冲报错：synthetic\n"); put(ws, "1\n");
          snprintf(lf, sizeof lf, "%s/log_fail.txt", g_dir); int fd = open(lf, O_RDWR | O_CREAT | O_TRUNC, 0644); g_s2a_logfd = fd;
          unsetenv("S2A_GFX"); g_vk_lib = 1;
          int m = s2a_gfx_mode();
          ssize_t n = pread(fd, buf, sizeof buf - 1, 0); if (n > 0) buf[n] = 0;
          int ok = m == S2A_GFX_DIRECT && access(w, F_OK) && access(ws, F_OK) && strstr(buf, "删掉旧的直连失败标记") && !strstr(buf, "fail 在");
          if (!ok) printf("✗ 旧 fail 在：期望直连且 fail / fail_seen 已删，实际模式 %d、fail %s、fail_seen %s；日志「%s」\n", m, access(w, F_OK) ? "已删" : "还在", access(ws, F_OK) ? "已删" : "还在", buf);
          fflush(stdout); _exit(ok ? 0 : 1);
      }
      int st = 0; waitpid(c, &st, 0);
      if (!WIFEXITED(st) || WEXITSTATUS(st)) fails++; else printf("  ✓ 旧 fail 在（旧规则会退回通用）：起局仍选直连，fail / fail_seen 被删并打日志\n"); }
    // 直连缺省省电组合：没设的补 S2A_AUDIO_SCHED=interactive（10-30 起不再补 DM_RT=0：出图线程照常声明实时）；游戏线程 QoS 不再补（10-26 起主线程不设 = thread.c 缺省 interactive），显式给的（S2A_GUEST_QOS=interactive）照用。模式每进程只定一次，故放在最前
    setenv("S2A_GFX", "direct", 1); unsetenv("DM_RT"); unsetenv("S2A_GAME_MAIN_QOS"); unsetenv("S2A_AUDIO_SCHED"); setenv("S2A_GUEST_QOS", "interactive", 1);
    { int m = s2a_gfx_mode(); const char *rt = getenv("DM_RT"), *mq = getenv("S2A_GAME_MAIN_QOS"), *gq = getenv("S2A_GUEST_QOS"), *as = getenv("S2A_AUDIO_SCHED");
      int ok = m == S2A_GFX_DIRECT && !rt && !mq && gq && !strcmp(gq, "interactive") && as && !strcmp(as, "interactive");
      if (!ok) { fails++; printf("✗ 直连缺省省电组合：模式 %d DM_RT=%s MAIN=%s GUEST=%s AUDIO=%s\n", m, rt ? rt : "(无)", mq ? mq : "(无)", gq ? gq : "(无)", as ? as : "(无)"); }
      else printf("  ✓ 直连缺省省电组合（显式值不覆盖）\n"); }
    // 直连模式下 vk* 导入解析到 Vulkan 层（Vulkan 款）；层里没有的名字、非 vk 名字回 0（装载器照原路径找）
    { uint64_t a = s2a_direct_lookup("vkCreateDevice"), b = s2a_direct_lookup("vkNotThere"), c = s2a_direct_lookup("nnFoo");
      if (a != (uint64_t)&g_vk_impl || b || c) { fails++; printf("✗ 直连 vk* 解析：vkCreateDevice %#llx（期望 %p）/ 没有的 %#llx / 非 vk %#llx\n", (unsigned long long)a, (void *)&g_vk_impl, (unsigned long long)b, (unsigned long long)c); }
      else printf("  ✓ 直连 vk* 解析到 Vulkan 层（没有的 / 非 vk 回 0）\n"); }
    // egl* / gl*：直连模式下 NVIDIA GL 驱动模块不装，有没有 GL 直连库都交给 GL 层——OpenGL 款（带 GL 库），与在 GL 里画一部分画面的 NVN 款
    //   （火影：没有 GL 库，导入 eglGetDisplay 等 10 个 egl*）。层里没有的名字（eglNotThere、马车8 的 glslcCompile）与非 egl / gl 名字回 0（装载器照原路径找）
    { g_gl_lib = 0; uint64_t a = s2a_direct_lookup("eglGetProcAddress"), g = s2a_direct_lookup("glslcCompile");
      g_gl_lib = 1; uint64_t b = s2a_direct_lookup("eglGetProcAddress"), c = s2a_direct_lookup("eglNotThere"), e = s2a_direct_lookup("nnFoo"); g_gl_lib = 0;
      if (a != (uint64_t)&g_gl_impl || b != (uint64_t)&g_gl_impl || c || e || g) { fails++; printf("✗ 直连 egl* 解析：无 GL 库 %#llx / 有 GL 库 %#llx（都期望 %p）/ 没有的 %#llx / 非 egl %#llx / glslc %#llx\n",
          (unsigned long long)a, (unsigned long long)b, (void *)&g_gl_impl, (unsigned long long)c, (unsigned long long)e, (unsigned long long)g); }
      else printf("  ✓ 直连 egl* 不论带不带 GL 库都解析到 GL 层（NVN 款的 EGL 导入不再未解析；层里没有的 / glslc / 非 egl 回 0）\n"); }
    // Switch 2 SDK 接管层：C++ 名（_Z…）与 NVIDIA 驱动 C 名（Nv*）都问入口（族的判定在入口里），入口回 NULL 的照原路径（movie::VideoFrame 问了、回 0）；
    //   别的名字（nn 开头的 C 名、vk / egl 已在前面分走）不问
    { g_cv_asked = 0;
      uint64_t a = s2a_direct_lookup("_ZN2nn5codec5video10InitializeEv"), b = s2a_direct_lookup("_ZN2nn6syncpt3sdk20CreateSyncPointEventEPNS1_18SyncPointEventTypeE"),
               c = s2a_direct_lookup("_ZN2nn2gs17TryWaitNativeSyncERKNS0_16NativeSyncHandleE"), d = s2a_direct_lookup("_Z24nvnNativeImageInitializeP14NVNnativeImagePK21NVNnativeImageBuilder"),
               e = s2a_direct_lookup("_Z35nvnTextureInitializeFromNativeImageP10NVNtextureP14NVNnativeImage");
      int asked = g_cv_asked; uint64_t f = s2a_direct_lookup("_ZN5movie10VideoFrame20GetNativeImageHandleEPN2nn2gs17NativeImageHandleE");
      uint64_t g = s2a_direct_lookup("NvRmChannelOpen"); int asked2 = g_cv_asked; uint64_t h = s2a_direct_lookup("nnMain");
      uint64_t want = (uint64_t)&g_cv_impl;
      if (a != want || b != want || c != want || d != want || e != want || asked != 5 || f || g || asked2 != 7 || h || g_cv_asked != 7) { fails++; printf("✗ Switch 2 接管层分派：codec %d syncpt %d gs %d 原生图像 %d 纹理 %d（问了 %d 次）/ movie::VideoFrame %#llx、NvRm %#llx（共问 %d 次，期望 7）/ nnMain %#llx（之后 %d 次，期望 7）\n",
          a == want, b == want, c == want, d == want, e == want, asked, (unsigned long long)f, (unsigned long long)g, asked2, (unsigned long long)h, g_cv_asked); }
      else printf("  ✓ Switch 2 接管层：C++ 名与 Nv* 名问入口（族判定在入口里），入口回 NULL 的照原路径，别的名字不问\n"); }
    unsetenv("S2A_GFX");

    check("没有 seen 文件 = 没有依据", A "\n" B "\n", NULL, 0);
    check("seen 只有空行 = 空 seen", A "\n" B "\n", "\n\n", 0);
    check("seen ⊆ keys", A "\n" B "\n", A "\n", 1);
    check("seen 全覆盖（重复行）", A "\n" B "\n", A "\n" B "\n" A "\n", 1);
    check("seen 有库外键", A "\n", A "\n" B "\n", 0);
    check("code: 兜底计入缺口", A "\n" B "\n", A "\ncode:0123456789abcdef\n", 0);
    check("大写键不是合法键 → 缺口", "000000000000000a\n", "000000000000000A\n", 0);
    check("行尾 CRLF / 空格 / TAB 忽略", A "\n" B "\n", A "\r\n" B " \t\n", 1);
    check("15 位不是合法键 → 缺口", A "\n", "00000b0b62850e7\n", 0);
    check("keys 有坏行 = 输入错", A "\nheader\n", A "\n", 0);
    check("没有 keys 文件", NULL, A "\n", 0);
    setenv("S2A_FAKE_DIRECT_READY", "1", 1);
    check("S2A_FAKE_DIRECT_READY=1 假就绪", NULL, NULL, 1);
    unsetenv("S2A_FAKE_DIRECT_READY");

    // s2a_mode_next（提示重启界面用）：只看 wire/<程序号>/ 下的 mode 文件；fail 不再是依据（10-26）
    { char w[512], m[512];
      snprintf(w, sizeof w, "%s/docs/wire/0000000000000000/fail", g_dir); snprintf(m, sizeof m, "%s/docs/wire/0000000000000000/mode", g_dir);
      struct { const char *name, *mode, *fail; int want; } t[] = {
          {"下次模式：没有文件 → 通用", NULL, NULL, S2A_GFX_GENERIC}, {"下次模式：mode=direct → 直连", "direct\n", NULL, S2A_GFX_DIRECT},
          {"下次模式：mode=direct + 旧 fail 在 → 仍直连（fail 不作依据）", "direct\n", "x\n", S2A_GFX_DIRECT}, {"下次模式：mode=generic → 通用", "generic\n", NULL, S2A_GFX_GENERIC}};
      for (unsigned i = 0; i < sizeof t / sizeof *t; i++) {
          put(m, t[i].mode); put(w, t[i].fail);
          int got = s2a_mode_next();
          if (got != t[i].want) { fails++; printf("✗ %s：期望 %d，实际 %d\n", t[i].name, t[i].want, got); }
          else printf("  ✓ %s\n", t[i].name);
      }
      put(m, NULL); put(w, NULL); }

    // 直连起手（10-25）：包里带本翻译链的直连库 b-<DMSH_CHAIN> 才算；别的链版本不算；有了库，mode=generic 照样优先、旧 fail 不作依据
    { char d[512], o[512], w[512], m[512]; int got;
      snprintf(d, sizeof d, "%s/gd/shaders/direct/b-%s", g_dir, DMSH_CHAIN); snprintf(o, sizeof o, "%s/gd/shaders/direct/b-000000000000", g_dir);
      snprintf(w, sizeof w, "%s/docs/wire/0000000000000000/fail", g_dir); snprintf(m, sizeof m, "%s/docs/wire/0000000000000000/mode", g_dir);
      mkdir(o, 0755);
      #define PK(name, want) do { int g_ = s2a_direct_packaged(); if (g_ != (want)) { fails++; printf("✗ %s：期望 %d，实际 %d\n", name, want, g_); } else printf("  ✓ %s\n", name); } while (0)
      { char lf[600]; snprintf(lf, sizeof lf, "%s/log.txt", g_dir); int keep = g_s2a_logfd, fd = open(lf, O_RDWR | O_CREAT | O_TRUNC, 0644); g_s2a_logfd = fd;
        PK("只有别的链版本的库 → 不算包里有直连库", 0);
        g_s2a_logfd = keep; char buf[2048] = ""; ssize_t n = pread(fd, buf, sizeof buf - 1, 0); close(fd); if (n > 0) buf[n] = 0;
        char want[200]; snprintf(want, sizeof want, "包里的 NVN 直连库是翻译链 000000000000，本宿主要 %s", DMSH_CHAIN);
        if (!strstr(buf, "【红】") || !strstr(buf, want)) { fails++; printf("✗ 只有别链的库要报【红】写明两边版本：日志「%s」\n", buf); }
        else printf("  ✓ 只有别链的库 → 【红】写明 000000000000 ≠ %s\n", DMSH_CHAIN); }
      g_vk_lib = 1; PK("Vulkan 款：没有 NVN 库、Vulkan 库就绪 → 包里有直连库", 1);
      g_vk_lib = 0; PK("Vulkan 库不就绪（没有 / 口径不符）→ 不算", 0);
      g_gl_lib = 1; PK("OpenGL 款：没有 NVN 库、GL 库就绪 → 包里有直连库", 1);
      g_gl_lib = 0; PK("GL 库不就绪 → 不算", 0);
      got = s2a_mode_next(); if (got != S2A_GFX_GENERIC) { fails++; printf("✗ 下次模式：只有别链的库 → 通用，实际 %d\n", got); } else printf("  ✓ 下次模式：只有别链的库 → 通用\n");
      mkdir(d, 0755);
      PK("有本链 b-" DMSH_CHAIN " 但没有 shader_map.tsv → 不算（资源包不全，10-25 马车8 起局 abort）", 0);
      char sm[512]; snprintf(sm, sizeof sm, "%s/gd/shaders/direct/shader_map.tsv", g_dir); put(sm, "x\n");
      PK("有本链 b-" DMSH_CHAIN " + shader_map.tsv，但 b- 里没有 lib.idx（逐键旧格式）→ 不算", 0);
      char li[600]; snprintf(li, sizeof li, "%s/lib.idx", d); put(li, "S2ALIB");   // 只写 6 字节：魔数不全
      PK("lib.idx 魔数不全 → 不算", 0);
      { FILE *f = fopen(li, "wb"); if (f) { fwrite("S2ALIB\0\0", 1, 8, f); fclose(f); } }
      PK("有本链 b-" DMSH_CHAIN " + shader_map.tsv + lib.idx（魔数 S2ALIB）→ 包里有直连库", 1);
      setenv("T_NO_MTL4", "1", 1); PK("有本链库但设备跑不了直连（既无 Metal 4 也无 Metal 3 路径）→ 不直连起手", 0); unsetenv("T_NO_MTL4");
      got = s2a_mode_next(); if (got != S2A_GFX_DIRECT) { fails++; printf("✗ 下次模式：没有文件、包里有本链库 → 直连，实际 %d\n", got); } else printf("  ✓ 下次模式：没有文件、包里有本链库 → 直连\n");
      put(m, "generic\n"); got = s2a_mode_next(); if (got != S2A_GFX_GENERIC) { fails++; printf("✗ 下次模式：mode=generic 优先于包里的库，实际 %d\n", got); } else printf("  ✓ 下次模式：mode=generic 优先于包里的库\n");
      put(m, NULL); put(w, "x\n"); got = s2a_mode_next(); if (got != S2A_GFX_DIRECT) { fails++; printf("✗ 下次模式：旧 fail 在、包里有本链库 → 仍直连，实际 %d\n", got); } else printf("  ✓ 下次模式：旧 fail 在、包里有本链库 → 仍直连\n");
      put(w, NULL); put(sm, NULL); put(li, NULL); rmdir(d); rmdir(o); }

    if (fails) { printf("✗ t_gfxmode：%d 例不符\n", fails); return 1; }
    printf("✓ t_gfxmode：35 例全符\n");
    return 0;
}
