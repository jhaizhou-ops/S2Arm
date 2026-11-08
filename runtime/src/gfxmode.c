// 图形模式开关（双轨，docs/设计_直连架构.md §12.1；接口见 runtime/include/s2a_gfx_mode.h）。
// 装载器重定位时第一次问（wire.c s2a_wire_lookup），之后只读：同一次运行只有一套图形。
// 弱链接[host]：s2a_nvn_bootstrap_entry（直连图形层 graphics/nvn 提供；链接行按这行放行未定义，runtime/build.mk 自动收）
// 弱链接[host]：s2a_direct_device_ok（直连图形层 graphics/nvn 提供；链接行按这行放行未定义，runtime/build.mk 自动收）
// 弱链接[host]：s2a_vk_entry（直连图形层 graphics/nvn 提供；链接行按这行放行未定义，runtime/build.mk 自动收）
// 弱链接[host]：s2a_vk_lib_ready（直连图形层 graphics/nvn 提供；链接行按这行放行未定义，runtime/build.mk 自动收）
// 弱链接[host]：s2a_gl_entry（直连图形层 graphics/nvn 提供；链接行按这行放行未定义，runtime/build.mk 自动收）
// 弱链接[host]：s2a_gl_lib_ready（直连图形层 graphics/nvn 提供；链接行按这行放行未定义，runtime/build.mk 自动收）
// 弱链接[host]：s2a_vi_entry（直连图形层 graphics/nvn 提供；链接行按这行放行未定义，runtime/build.mk 自动收）
// 弱链接[host]：s2a_nv_entry（直连图形层 graphics/nvn 提供；链接行按这行放行未定义，runtime/build.mk 自动收）
// 弱链接[host]：s2a_codec_entry（直连图形层 graphics/nvn 提供；链接行按这行放行未定义，runtime/build.mk 自动收）
#include "native.h"
#include "s2a_gfx_mode.h"
#include "s2a_docs.h"   // 文档根唯一取法
#include <pthread.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <TargetConditionals.h>
#if defined(__APPLE__)
#include <sys/sysctl.h>
#endif
#include "../../graphics/nvn/gfx/nvn/dmsh_chain.h"   // DMSH_CHAIN：本宿主认的直连着色器库翻译链版本

const char *s2a_module_dir(void);

static _Atomic uint64_t g_pid;
// main.npdm 的程序号（META +0x70 = ACI0 偏移，ACI0 +0x10 = 程序号）：重定位之前就要用，svc_mem.c 那份此时还没读。读不到 = 0
static uint64_t npdm_read(void) {
    char p[1100]; snprintf(p, sizeof p, "%s/main.npdm", s2a_module_dir());
    FILE *f = fopen(p, "rb"); if (!f) return 0;
    uint8_t meta[0x80], aci[0x18]; uint32_t off; uint64_t pid = 0;
    if (fread(meta, 1, sizeof meta, f) == sizeof meta && !memcmp(meta, "META", 4)) {
        memcpy(&off, meta + 0x70, 4);
        if (!fseek(f, off, SEEK_SET) && fread(aci, 1, sizeof aci, f) == sizeof aci && !memcmp(aci, "ACI0", 4)) memcpy(&pid, aci + 0x10, 8);
    }
    fclose(f); return pid;
}

// 文档根（runtime/include/s2a_docs.h）下的 wire/<程序号>/<名>
static void wire_path(char *out, size_t n, const char *name) {
    s2a_docs_path(out, n, "wire/%016llX%s%s", (unsigned long long)g_pid, name ? "/" : "", name ? name : "");
}
static int read_word(const char *path, char *w, size_t n) {
    FILE *f = fopen(path, "r"); if (!f) return 0;
    int ok = fgets(w, (int)n, f) != NULL; fclose(f);
    if (ok) w[strcspn(w, " \t\r\n")] = 0;
    return ok;
}

void *s2a_nvn_bootstrap_entry(void) __attribute__((weak_import));   // 直连图形层（graphics/nvn）；没链 = 不能直连
int s2a_direct_device_ok(void) __attribute__((weak_import));      // 直连图形层（graphics/nvn/host_adapt.m）：这台设备能不能跑直连（Metal 4 家族，或 Metal 3 家族 + 系统 ≥ macOS 15 / iOS 18，见 nvn_be.h）
int s2a_vk_lib_ready(const char *game_data) __attribute__((weak_import));   // graphics/nvn/gfx/vk/hle_vk.m：Vulkan 款的直连库在不在、口径对不对
int s2a_gl_lib_ready(const char *game_data) __attribute__((weak_import));   // graphics/nvn/gfx/gl/gl_prog.m：OpenGL 款的直连库在不在、口径对不对
// 游戏数据 = S2A_GAME_DATA；iOS 上判模式时它还没设（host_main.c 装载后才设），取同一个缺省 Documents/资源包。没有 = NULL
static const char *game_data(char *d, size_t n) {
    const char *gd = getenv("S2A_GAME_DATA");
#if TARGET_OS_IPHONE
    if (!gd || !*gd) { s2a_docs_path(d, n, "资源包"); gd = d; }
#else
    (void)d; (void)n;
#endif
    return gd && *gd ? gd : NULL;
}
// 包里带着本宿主翻译链版本的直连库：<游戏数据>/shaders/direct/b-<链版本>/ 在（graphics/tools/direct/direct_lib.sh 出）、映射表 shader_map.tsv 也在，链进了直连图形层，且这台设备跑得了直连（s2a_direct_device_ok）。
//   映射表是直连图形层缺了就 abort 的那个文件（nvn_mtl.m shmap_load_once MDIE）：10-25 测试机1 马车8 推的资源包清掉了 shader_map.tsv 等 9 个表、b-<链>/ 还在，
//   只看目录判了直连 → 起局 6 秒 abort（信号 6）→ 写 fail，之后一直退回通用。缺映射表 = 包里没有可用的直连库，按通用起、不写 fail
static const char * _Atomic g_lib = "";   // s2a_direct_packaged 认出的直连库种类（开发浮层短写用）
// 包里只有别的翻译链版本的 NVN 直连库（b-<别的链>/）：宿主读不了，按通用起。10-26 链版本换过后旧包就是这样，原先一行不报、默默退成通用（同「直连库 0 个照交局」）：
//   报【红】写明两边版本，返回 1 = 有这种库
static int chain_mismatch(const char *gd) {
    char p[1200]; snprintf(p, sizeof p, "%s/shaders/direct", gd);
    DIR *d = opendir(p); if (!d) return 0;
    char other[64] = ""; struct dirent *e;
    while ((e = readdir(d))) if (!strncmp(e->d_name, "b-", 2) && strcmp(e->d_name + 2, DMSH_CHAIN)) { snprintf(other, sizeof other, "%s", e->d_name + 2); break; }
    closedir(d);
    if (other[0]) LOG("【红】图形模式：包里的 NVN 直连库是翻译链 %s，本宿主要 %s：读不了，不算带直连库（请按当前 main 重出包）", other, DMSH_CHAIN);
    return other[0] != 0;
}
int s2a_direct_packaged(void) {
    if (!s2a_nvn_bootstrap_entry || !s2a_direct_device_ok || !s2a_direct_device_ok()) return 0;   // 设备跑不了直连（不按系统版本整体拦，按图形能力：10-25 jhz 定下限 iOS 17 / macOS 14）
    char d[1100], p[1200]; struct stat st; const char *gd = game_data(d, sizeof d);
    if (!gd) return 0;
    snprintf(p, sizeof p, "%s/shaders/direct/b-%s", gd, DMSH_CHAIN);
    if (!stat(p, &st) && S_ISDIR(st.st_mode)) {
        snprintf(p, sizeof p, "%s/shaders/direct/shader_map.tsv", gd);
        if (stat(p, &st) || !S_ISREG(st.st_mode)) { LOG("【红】图形模式：包里有 b-%s 但没有 %s，不算带直连库（资源包不全）", DMSH_CHAIN, p); return 0; }
        // 直连库是打包容器（10-25 合库：b-<链>/lib.idx + lib.NNN.pak，graphics/nvn/lib_pack.inc 读）：没有 lib.idx 或魔数不对 = 逐键旧格式，直连图形层读不了，按通用起、不写 fail
        snprintf(p, sizeof p, "%s/shaders/direct/b-%s/lib.idx", gd, DMSH_CHAIN);
        char mg[8] = {0}; int fd = open(p, O_RDONLY); ssize_t got = fd >= 0 ? read(fd, mg, sizeof mg) : -1; if (fd >= 0) close(fd);
        if (got == 8 && !memcmp(mg, "S2ALIB\0\0", 8)) { g_lib = "NVN"; return 1; }
        LOG("【红】图形模式：%s %s，直连库是逐键旧格式（或索引坏了），不算带直连库：请重出包", p, fd < 0 ? "不在" : "魔数不对");
        return 0;
    }
    if (s2a_vk_lib_ready && s2a_vk_lib_ready(gd)) { g_lib = "Vulkan"; return 1; }   // Vulkan 款：shaders/direct/vk/，口径号对上才算（graphics/nvn/gfx/vk/vk_lib.h）
    if (s2a_gl_lib_ready && s2a_gl_lib_ready(gd)) { g_lib = "OpenGL"; return 1; }   // OpenGL 款：shaders/direct/gl/（graphics/nvn/gfx/gl/gl_lib.h）
    chain_mismatch(gd);   // 三种库都不算：只有别链的 NVN 库就报红（不静默退通用）
    return 0;
}

static _Atomic int g_mode = S2A_GFX_GENERIC;
static const char * _Atomic g_why = "";   // 判定依据（同「图形模式：」日志行）
static char g_brief[48];         // 判定依据短写（开发浮层一眼能读：NVN b-<链前 6 位> / Vulkan / OpenGL / S2A_GFX / mode 文件）
static pthread_mutex_t g_mode_mu = PTHREAD_MUTEX_INITIALIZER;
static _Atomic int g_decided;
static int g_default_audio_sched;
static int mkdirs(const char *path);
static void decide(void) {
    int mode = S2A_GFX_GENERIC;
    g_pid = npdm_read();
    const char *e = getenv("S2A_GFX"), *why = "缺省";
    char p[1200], w[32];
    // 旧的直连失败标记 wire/<程序号>/fail（10-26 前的版本运行中出错会写它、下次起局退回通用）：10-26 总指挥改定运行中不切换、兼容按款在出包时定，
    //   不再作为依据；玩家机上留着的删掉、打一行（连同记「已切回通用」已读的 fail_seen）
    wire_path(p, sizeof p, "fail_seen"); unlink(p);
    wire_path(p, sizeof p, "fail");
    if (!unlink(p)) LOG("图形模式：删掉旧的直连失败标记 %s（运行中不再切换，模式只按包和 S2A_GFX 定）", p);
    if (e && *e) {
        if (!strcmp(e, "direct")) { mode = S2A_GFX_DIRECT; why = "环境变量 S2A_GFX=direct"; }
        else if (!strcmp(e, "generic")) { mode = S2A_GFX_GENERIC; why = "环境变量 S2A_GFX=generic"; }
        else LOG("【红】图形模式：S2A_GFX=%s 看不懂（direct / generic），按缺省", e);
    } else if (wire_path(p, sizeof p, "mode"), read_word(p, w, sizeof w)) {
        if (!strcmp(w, "direct")) { mode = S2A_GFX_DIRECT; why = "wire/<程序号>/mode = direct"; }
        else if (!strcmp(w, "generic")) why = "wire/<程序号>/mode = generic";
        else LOG("【红】图形模式：%s 内容「%s」看不懂，按缺省", p, w);
    } else if (s2a_direct_packaged()) {   // 缺省：包里带直连库就直连（10-25 jhz 拍板；10-26 起运行中出错不切换，兼容按款在出包时定）
        mode = S2A_GFX_DIRECT; why = "包里带本宿主口径的直连库（NVN b-" DMSH_CHAIN " 或 Vulkan vk/）";
    }
    g_why = why;
    if (!strcmp(why, "缺省")) snprintf(g_brief, sizeof g_brief, "缺省");
    else if (!strncmp(why, "环境变量", strlen("环境变量"))) snprintf(g_brief, sizeof g_brief, "S2A_GFX 指定");
    else if (strstr(why, "/mode")) snprintf(g_brief, sizeof g_brief, "mode 文件");
    else if (!strcmp(g_lib, "NVN")) snprintf(g_brief, sizeof g_brief, "NVN b-%.6s", DMSH_CHAIN);
    else snprintf(g_brief, sizeof g_brief, "%s", g_lib);
    LOG("图形模式：%s（依据 %s；程序号 %016llx）", mode == S2A_GFX_DIRECT ? "直连" : "通用", why, (unsigned long long)g_pid);
#if defined(__APPLE__)
    {   // 机器：系统版本与芯片（11-01 异度3：同一份着色器 M3 / macOS 27 编译器内部错误、M5 / macOS 26 正常；普查「系统版本」列按这行归因）
        char os[32] = "?", cpu[64] = "?"; size_t n = sizeof os; sysctlbyname("kern.osproductversion", os, &n, NULL, 0); n = sizeof cpu; sysctlbyname("machdep.cpu.brand_string", cpu, &n, NULL, 0);
        LOG("机器：系统 %s，芯片 %s", os, cpu);
    }
#endif
    // 直连缺省省电组合（10-24 测试机2 动森掌机档：同时加 DM_RT=0 + 两个 QoS=utility 时 2.336 W，只降 QoS 时 2.510 W，什么都不加 5 局中位 2.644 W；帧时 p95 不变、30 fps；10-26 起只留 DM_RT=0，10-30 起 DM_RT=0 也不补，见下）：
    //   直连层给出图线程声明实时调度，实时线程不受 QoS 管，只降 QoS 时 nx-81 / nx-83 仍 100% 在性能核。只给没设的补缺省（环境变量显式给的照用）；在建游戏线程之前定
    // 声音渲染 / DSP 线程同理（10-25 性能攻坚线：S2ARealtime.Promote 把它提成实时调度，系统为保截止时间放在性能核、顶高频，塞尔达等直连局每 10 秒窗 0.19–0.21 W；
    //   它每 5 ms 本就睡一次，S2A_AUDIO_SCHED=interactive 只给 QoS user-interactive、不提实时；utility 实测不可用：Air 马车8 直连每 10 秒断供 25–30 次、渲染丢 285 周期；判据：[声] 行断供 / 渲染丢周期不涨）
    // 游戏线程 QoS 不再补 utility（10-26 帧率能耗线定，总指挥令用现有读数一次定）：utility 把游戏线程压在能效核、频率压在约 1.6 GHz，重游戏跑不满——
    //   八方2 60 帧 utility 49–56 帧 / interactive 59.7 帧（T1R33c），银河2 同机同档 utility 55.2 帧、>25 ms 12.3% / interactive 60.0 帧、0%（SQC2 / SQB）。
    //   满帧是前提，代价（八方2 +2.4 W：性能核顶 4 GHz）另从频率 / GPU 侧压；回到 thread.c 缺省（主线程 interactive，其余按性能核数）。动森那 0.17 W（2.510 → 2.336 W 里只降 QoS 的部分）让出
    // 出图线程实时声明不再缺省关（10-30 帧率能耗线）：DM_RT=0 让帧关键线程没有截止时间，轮询退避一长，系统就把它们当闲线程挪能效核降频——
    //   丝之歌测试机短睡退避 250 µs 局整机 1.72 W 但慢帧 2.5%：主线程 nx-81 只 19% 在性能核，提交线程 1.74 GHz、每帧 1.6 ms（性能核上 0.42 ms）。
    //   jhz 10-30：稳定 60 帧前提下功耗最低，不靠让关键线程空转留在大核；声明按每帧实测 CPU 自动定（hle_nvn.c rt_comp_tick）
    if (mode == S2A_GFX_DIRECT && !getenv("S2A_AUDIO_SCHED") &&
        !setenv("S2A_AUDIO_SCHED", "interactive", 0)) g_default_audio_sched = 1;
    atomic_store(&g_mode, mode);
}
// iOS：资源包闸门放行之前不落定模式（10-26 测试机2：资源包说明页等「重新检查」时，直连提示轮询先问了模式，
//   没有数据目录判成通用并定死，资源包放好后照样走通用、画面全黑；真预热启动轮询抢在宿主前面也会中）。之前问只给临时的「通用」，不落定
#if TARGET_OS_IPHONE
static _Atomic int g_data_ready;
#else
static _Atomic int g_data_ready = 1;
#endif
void s2a_gfx_mode_data_ready(void) { atomic_store(&g_data_ready, 1); }
int s2a_gfx_mode_settled(void) { return atomic_load(&g_data_ready); }
int s2a_gfx_mode(void) {
    if (!atomic_load(&g_data_ready)) return S2A_GFX_GENERIC;
    if (!atomic_load_explicit(&g_decided, memory_order_acquire)) {
        pthread_mutex_lock(&g_mode_mu);
        if (!atomic_load(&g_decided)) { decide(); atomic_store_explicit(&g_decided, 1, memory_order_release); }
        pthread_mutex_unlock(&g_mode_mu);
    }
    return g_mode;
}
void s2a_gfx_mode_session_reset(void) {
    pthread_mutex_lock(&g_mode_mu);
    const char *audio = getenv("S2A_AUDIO_SCHED");
    if (g_default_audio_sched && audio && !strcmp(audio, "interactive")) unsetenv("S2A_AUDIO_SCHED");
    g_default_audio_sched = 0;
    g_lib = "";
    // 旧会话全部停止后立即在同一把锁下重决策，避免 UI 首次查询抢先落定。
    decide(); atomic_store_explicit(&g_decided, 1, memory_order_release);
    pthread_mutex_unlock(&g_mode_mu);
}
const char *s2a_gfx_mode_why(void) { s2a_gfx_mode(); return g_why; }
const char *s2a_gfx_mode_brief(void) {
    static _Thread_local char brief[sizeof g_brief];
    s2a_gfx_mode();
    pthread_mutex_lock(&g_mode_mu); memcpy(brief, g_brief, sizeof brief); pthread_mutex_unlock(&g_mode_mu);
    return brief;
}
uint64_t s2a_npdm_program_id(void) { s2a_gfx_mode(); return g_pid; }
void s2a_npdm_program_id_set(uint64_t id) { s2a_gfx_mode(); g_pid = id; }   // 帧回放：不装游戏，程序号按录像（着色器库戳比对用）
// 多程序合集切到第 n 支（host_main.c switch_program_modules 换完模块目录后调）：会话复位时的重决策还读的是上一支的 main.npdm，程序号要按新目录重读，
//   否则直连层校验着色器库戳、wire/<程序号> 目录都还按序号 0（11-06 索尼克×夏特：序号 1 的库报「built for 01005EA01C0FC001, not …C000」）
void s2a_npdm_program_id_reload(void) { s2a_gfx_mode(); g_pid = npdm_read(); }

// 下次起局按文件会选的模式（不看环境变量 S2A_GFX，同 decide 的文件部分；提示重启界面用，s2a_direct_prompt.h）
int s2a_mode_next(void) {
    s2a_gfx_mode();
    char p[1200], w[32];
    wire_path(p, sizeof p, "mode");
    if (read_word(p, w, sizeof w)) return !strcmp(w, "direct") ? S2A_GFX_DIRECT : S2A_GFX_GENERIC;
    return s2a_direct_packaged() ? S2A_GFX_DIRECT : S2A_GFX_GENERIC;
}

static int mkdirs(const char *path) {
    char b[1200]; strlcpy(b, path, sizeof b);
    for (char *s = b + 1; *s; s++) if (*s == '/') { *s = 0; if (mkdir(b, 0755) && errno != EEXIST) return -1; *s = '/'; }
    return mkdir(b, 0755) && errno != EEXIST ? -1 : 0;
}
int s2a_mode_request(int mode, const char *reason) {
    s2a_gfx_mode();
    if (mode != S2A_GFX_DIRECT && mode != S2A_GFX_GENERIC) return -1;
    char d[1200], p[1200], t[1300];
    wire_path(d, sizeof d, NULL); if (mkdirs(d)) { LOG("【红】图形模式：建 %s 失败（errno %d）", d, errno); return -1; }
    wire_path(p, sizeof p, "mode"); snprintf(t, sizeof t, "%s.tmp", p);
    FILE *f = fopen(t, "w"); if (!f) { LOG("【红】图形模式：写 %s 失败（errno %d）", t, errno); return -1; }
    fprintf(f, "%s\n", mode == S2A_GFX_DIRECT ? "direct" : "generic");
    if (fclose(f) || rename(t, p)) { LOG("【红】图形模式：写 %s 失败（errno %d）", p, errno); return -1; }
    LOG("图形模式：下次起局改为%s（%s）", mode == S2A_GFX_DIRECT ? "直连" : "通用", reason ? reason : "-");
    return 0;
}

// 就绪：资源包里的直连着色器键清单（S2A_GAME_DATA/shaders/direct/keys.tsv）覆盖通用模式下见过的全部键（Documents/wire/<程序号>/seen_shaders.tsv）。
// 口径见 docs/设计_直连架构.md §12.3（与离线工具 tools/direct_ready.py 同口径）：
//   每行去掉行尾 ASCII 空白后必须正好是 16 位小写十六进制键，空行忽略；keys 里有别的内容 = 输入错（判未就绪）；
//   seen 里不是这种键的行（含 code:<机器码哈希16> 兜底）计入缺口；空 seen 判未就绪
static int key_cmp(const void *a, const void *b) { uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b; return x < y ? -1 : x > y; }
// 1 = 合法键（*v 为值）；0 = 空行；-1 = 别的内容
static int key_line(char *line, uint64_t *v) {
    size_t n = strlen(line);
    while (n && (line[n - 1] == ' ' || line[n - 1] == '\t' || line[n - 1] == '\r' || line[n - 1] == '\n')) line[--n] = 0;
    if (!n) return 0;
    if (n != 16) return -1;
    uint64_t x = 0;
    for (size_t i = 0; i < 16; i++) {
        char c = line[i];
        if (c >= '0' && c <= '9') x = x << 4 | (uint64_t)(c - '0');
        else if (c >= 'a' && c <= 'f') x = x << 4 | (uint64_t)(c - 'a' + 10);
        else return -1;
    }
    *v = x; return 1;
}
int s2a_direct_ready(void) {
    s2a_gfx_mode();
    // 界面开发 / 测试用（贡献者任务 #148）：S2A_FAKE_DIRECT_READY=1 直接回就绪，不看着色器覆盖
    { const char *f = getenv("S2A_FAKE_DIRECT_READY"); if (f && !strcmp(f, "1")) { LOG("直连就绪：是（S2A_FAKE_DIRECT_READY=1，假就绪）"); return 1; } }
    char p[1200], line[256]; const char *gd = getenv("S2A_GAME_DATA");
    if (!gd || !*gd) { LOG("直连就绪：否（没有 S2A_GAME_DATA）"); return 0; }
    snprintf(p, sizeof p, "%s/shaders/direct/keys.tsv", gd);
    FILE *f = fopen(p, "r"); if (!f) { LOG("直连就绪：否（没有 %s）", p); return 0; }
    uint64_t *k = NULL, v; size_t nk = 0, cap = 0; int bad = 0;
    while (fgets(line, sizeof line, f)) {
        int r = key_line(line, &v); if (!r) continue;
        if (r < 0) { bad++; continue; }
        if (nk == cap) { cap = cap ? cap * 2 : 4096; uint64_t *q = realloc(k, cap * sizeof *k); if (!q) { free(k); fclose(f); return 0; } k = q; }
        k[nk++] = v;
    }
    fclose(f);
    if (bad) { free(k); LOG("【红】直连就绪：否（%s 有 %d 行不是 16 位小写十六进制键）", p, bad); return 0; }
    qsort(k, nk, sizeof *k, key_cmp);
    wire_path(p, sizeof p, "seen_shaders.tsv");
    int miss = 0, seen = 0;
    if ((f = fopen(p, "r"))) {
        while (fgets(line, sizeof line, f)) {
            int r = key_line(line, &v); if (!r) continue;
            seen++; if (r < 0 || !bsearch(&v, k, nk, sizeof *k, key_cmp)) miss++;
        }
        fclose(f);
    }
    free(k);
    int ok = seen > 0 && miss == 0;
    LOG("直连就绪：%s（库键 %zu，见过 %d 行，缺 %d 行%s）", ok ? "是" : "否", nk, seen, miss, seen ? "" : "；没有见过的键 = 没有依据");
    return ok;
}

// 装载器重定位时逐个导入问一次（loader.c relocate）：直连模式下游戏导入的 nvnBootstrapLoader 解析到直连图形层（graphics/nvn，NVN→Metal），
//   游戏随包的 NVN 驱动（sdk 模块）不再被引用，Ryujinx 显卡模拟闲置；其余名字、以及通用模式下一律回 0（走原路径）
void *s2a_nvn_bootstrap_entry(void) __attribute__((weak_import));   // graphics/nvn/host_adapt.m；只带原生层编的 Mac 宿主没有（链接参数 -U）
void *s2a_vk_entry(const char *name) __attribute__((weak_import));          // graphics/nvn/host_adapt.m：Vulkan 款的 vk* 导入（直连层 hle_vk，已套切栈桩）
void *s2a_vi_entry(const char *name) __attribute__((weak_import));          // graphics/nvn/host_adapt.m：游戏导入的 nn::vi 显示层函数（SetLayerCrop：上屏区域）
void *s2a_gl_entry(const char *name) __attribute__((weak_import));          // graphics/nvn/host_adapt.m：egl* / gl* 导入（graphics/nvn/gfx/gl，重活已套切栈桩）
void *s2a_nv_entry(const char *name) __attribute__((weak_import));          // graphics/nvn/gfx/nvn/nvn2.c：Switch 2 游戏导入的 nv::（GPU 驱动启动层）、gsv 与其他依赖 gs 启动的命名空间；Switch 1 恒回 NULL
// graphics/nvn/gfx/nvn/nvn2_codec.c：Switch 2 游戏导入的 nn::codec 视频解码器 / 图像池、nn::syncpt::sdk、nn::gs、NVN2 原生图像（真机走 gsv 服务）；Switch 1 恒回 NULL
void *s2a_codec_entry(const char *name) __attribute__((weak_import));
uint64_t s2a_direct_lookup(const char *name) {
    if (s2a_gfx_mode() != S2A_GFX_DIRECT) return 0;
    // Vulkan 款（main 直接导入 vk*，加载器 / NVIDIA 驱动模块不装）：vk* 解析到直连 Vulkan 层；没实现的名字回 0，照原路径找、找不到报红
    if (!strncmp(name, "vk", 2)) { if (!s2a_vk_entry) die("图形模式是直连，但本宿主没链直连图形层（graphics/nvn）"); return (uint64_t)s2a_vk_entry(name); }
    // egl* / gl*：一律问直连 GL 层，不论包里有没有 GL 直连库。EGL / GL 的定义只在 NVIDIA GL 驱动模块（NintendoSDK_OpenGL），直连模式下它和 Vulkan 驱动一样不装
    //   （gpu_drivers.tsv，profile_guess.gpu_driver_modules），原路径不存在，不交给 GL 层就是装载期未解析、一调即中止。
    //   OpenGL 款（main 导入 egl*、经 eglGetProcAddress 取 gl*）如此；在 GL 里画一部分画面的 NVN 款也如此（火影：Scaleform 建无表面的 EGL 上下文、
    //   经 eglGetProcAddress 取 gl* 画界面，再经 nvnTextureBuilderSetGLTextureName / nvnSyncInitializeFromFencedGLSync 交给 NVN）。
    //   层里没实现的名字（如马车8 的 glslc*）回 0，照原路径找
    if (!strncmp(name, "egl", 3) || !strncmp(name, "gl", 2)) { if (!s2a_gl_entry) die("图形模式是直连，但本宿主没链直连图形层（graphics/nvn）"); return (uint64_t)s2a_gl_entry(name); }
    if ((!strncmp(name, "_ZN2nn2vi", 9) || !strncmp(name, "_ZNK2nn2vi", 10)) && s2a_vi_entry) { void *f = s2a_vi_entry(name); if (f) return (uint64_t)sw_xstack_wrap(name, f); }   // 显示层裁切等：直连上屏要知道（真机 SDK 推给系统窗口）
    // Switch 2 的 SDK 接管层（游戏自带 NVN2 驱动 / nn::gs / gsv 直连档不启动，依赖它们的 sdk 函数由宿主答）：C++ 名与 NVIDIA 驱动的 C 名（Nv*）都问两个入口，
    //   名字族的判定在入口里（规格 = 游戏 sdk 的导出表，见 graphics/nvn/gfx/nvn/nvn2.c、nvn2_codec.c）；Switch 1 进程两个入口都回 NULL。
    //   s2a_nv_entry：nv::、streamplay 碰显示层的三个、gsv 与其他依赖 gs 启动的命名空间（chat / camera / gpu / wsi / vi2 / NvRm…）；
    //   s2a_codec_entry：视频解码（subsdk2 的 movie 库导入）、syncpt、gs、NVN2 原生图像
    if (!strncmp(name, "_Z", 2) || !strncmp(name, "Nv", 2)) {
        if (s2a_nv_entry) { void *f = s2a_nv_entry(name); if (f) return (uint64_t)sw_xstack_wrap(name, f); }
        if (s2a_codec_entry) { void *f = s2a_codec_entry(name); if (f) return (uint64_t)sw_xstack_wrap(name, f); }
    }
    if (strcmp(name, "nvnBootstrapLoader")) return 0;
    if (!s2a_nvn_bootstrap_entry) die("图形模式是直连，但本宿主没链直连图形层（graphics/nvn）");
    return (uint64_t)sw_xstack_wrap(name, s2a_nvn_bootstrap_entry());
}
