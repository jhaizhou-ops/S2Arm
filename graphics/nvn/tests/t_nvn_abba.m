// 直连层纹理释放在「虚拟核 / g_rmu」上的锁序单测（botw 出图停 1500 帧的 ABBA）。
// 现场两条宿主栈互为对手：
//   nx-82   持 g_rmu，在 up_wait_zero 里重新取核（core_acquire <- s2a_core_block_end）；
//   nx-120  持核 1，在 mtl_vc_drop 的 lock(&g_rmu) 等它。
// 锁序相反 → 环路。产品规则写在 nvn_mtl.m：持核线程在临界区里等一个可能被另一条持核线程持有的锁 = 环路，
//   所以「取回核」必须放到解锁之后。hle_nvn.c 的两处 nvn_be_tex_release 调用点都要先放核。
//
// 本测用测试自己的「核」替身（语义同 runtime/src/thread.c 的 s2a_core_enter / leave / block_begin / end，可嵌套）复现这两条线程：
//   A = 持 g_rmu、等核的线程（up_wait_zero：此时它已放核，正在 core_acquire）；
//   B = 持核、调纹理释放的线程（TextureFinalize / TextureInitialize 的重初始化 / 去掉 DM_BLOCK 的旧路径）。
// 期望：Finalize 与 TextureInitialize 两处都在 nvn_be_tex_release 前后 DM_BLOCK（A 在 B 等 g_rmu 时拿得到核）→ 环路断，两边完成；
//   负对照 old：直接调 nvn_be_tex_release（等价于去掉 Finalize 的 DM_BLOCK）→ 必须超时（3 秒），否则本测没有真的构造出环路。
//
// 跑法：t_nvn_abba finalize | reinit | old（native-test-nvn_abba 依次跑三条，前两条要完成、第三条要超时）
// 需要 GPU 吗：不需要。全程只走 serial / 视图表的登记与注销，不建 MTLTexture。
#ifndef NVN_ABBA_SOURCE
#define NVN_ABBA_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif

#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define S2A_TEST_OWN_CORE 1     // 「核」的两个入口由本文件给（真替身，见下）
#define S2A_TEST_REAL_NATIVE 1  // include 了 native.h：模块名表按真实类型定义
#define S2A_TEST_REAL_WIDEN 1   // 同一 TU 里编了 nvn_mtl.m：宽屏入口按 s2a_widen.h 的真实原型给
#include "native.h"
#include "host_stubs.h"       // 其余宿主替身（与 t_nvn_m3 共用）
#include NVN_ABBA_SOURCE       // 产品的 nvn_mtl.m：拿 g_rmu / nvn_be_tex_release / mtl_vc_drop

extern void *h_nvnBootstrapLoader(const char *name);

// native.h 里那两个符号：不链原生层，这里给替身（形状照真实声明）
S2A_TEST_MOD_TABLE(64); int g_nmod;
module_t *module_of(const void *p) { (void)p; return NULL; }
// 宽屏的三个判定入口不在 s2a_widen.h 的导出表里（宽屏库不导出）：返回 0 = 不做宽屏，其余入口不会被调到
int s2a_widen_game(void) { return 0; } int s2a_widen_full(void) { return 0; } int s2a_widen_layout(void) { return 0; }

// ---------- 核替身：单核互斥，可嵌套；block_begin 放核、block_end 取核（同 thread.c 的 t_blk 语义） ----------
static pthread_mutex_t ab_core_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ab_core_cv = PTHREAD_COND_INITIALIZER;
static int ab_core_owner;             // 0 = 空；否则持核线程编号
static __thread int ab_tid;           // 本线程编号：A=1 / B=2 / 主=3
static __thread int ab_blk, ab_has_core;
static atomic_int ab_block_begins;    // DM_BLOCK_BEGIN 被调了几次（证明宏真的落在产品的释放路径上）

static void ab_core_leave(void) {
    pthread_mutex_lock(&ab_core_mu);
    if (ab_core_owner == ab_tid) { ab_core_owner = 0; ab_has_core = 0; pthread_cond_broadcast(&ab_core_cv); }
    pthread_mutex_unlock(&ab_core_mu);
}
static void ab_core_enter(void) {
    pthread_mutex_lock(&ab_core_mu);
    while (ab_core_owner) pthread_cond_wait(&ab_core_cv, &ab_core_mu);
    ab_core_owner = ab_tid; ab_has_core = 1;
    pthread_mutex_unlock(&ab_core_mu);
}
void s2a_core_block_begin(void) { atomic_fetch_add(&ab_block_begins, 1); if (!ab_blk++) ab_core_leave(); }
void s2a_core_block_end(void) { if (ab_blk > 0 && !--ab_blk) ab_core_enter(); }

// ---------- 两条线程 ----------
enum { AB_FINALIZE, AB_REINIT, AB_OLD };
static int ab_mode;
static tex_t ab_tex, ab_tex2;
static tex_builder_t ab_builder;
static void (*ab_finalize)(NVNtexture *);
static void (*ab_initialize)(NVNtexture *, const NVNtextureBuilder *);

static atomic_int ab_core_held, ab_rmu_held;
static pthread_mutex_t ab_done_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ab_done_cv = PTHREAD_COND_INITIALIZER;
static int ab_done;
static void ab_finish(void) { pthread_mutex_lock(&ab_done_mu); ab_done++; pthread_cond_broadcast(&ab_done_cv); pthread_mutex_unlock(&ab_done_mu); }

// A：持 g_rmu，然后在 g_rmu 里等核（up_wait_zero 的 core_acquire；进 up_wait_zero 前它已经 DM_BLOCK_END 放过核）
static void *ab_thr_a(void *a) {
    (void)a; ab_tid = 1;
    while (!atomic_load(&ab_core_held)) sched_yield();   // B 先持核
    pthread_mutex_lock(&g_rmu);
    atomic_store(&ab_rmu_held, 1);
    ab_core_enter();                                    // 等核：B 不在 g_rmu 之前放核就永远等不到
    pthread_mutex_unlock(&g_rmu);
    ab_core_leave();                                    // 拿到了就放（真宿主里它继续跑 guest，这里到此为止）
    ab_finish();
    return NULL;
}
// B：持核，调纹理释放
static void *ab_thr_b(void *a) {
    (void)a; ab_tid = 2;
    ab_core_enter();
    atomic_store(&ab_core_held, 1);
    while (!atomic_load(&ab_rmu_held)) sched_yield();    // A 已持 g_rmu
    if (ab_mode == AB_FINALIZE) ab_finalize((NVNtexture *)&ab_tex);
    else if (ab_mode == AB_REINIT) ab_initialize((NVNtexture *)&ab_tex2, (const NVNtextureBuilder *)&ab_builder);
    else nvn_be_tex_release(&ab_tex);                    // 负对照：去掉 DM_BLOCK 的旧路径
    ab_core_leave();
    ab_finish();
    return NULL;
}

static void ab_make_tex(tex_t *t) {
    memset(t, 0, sizeof *t);
    t->magic = MAGIC('T', 'E', 'X', 0); t->serial = nvn_new_serial();
    t->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 4, .height = 4, .depth = 1, .levels = 1};
    nvn_tex_layout(&t->d, &t->L);
    nvn_be_tex_init(t);
}

int main(int argc, char **argv) {
    const char *m = argc > 1 ? argv[1] : "finalize";
    if (!strcmp(m, "finalize")) ab_mode = AB_FINALIZE;
    else if (!strcmp(m, "reinit")) ab_mode = AB_REINIT;
    else if (!strcmp(m, "old")) ab_mode = AB_OLD;
    else { fprintf(stderr, "用法：%s finalize|reinit|old\n", argv[0]); return 2; }

    ab_finalize = (void (*)(NVNtexture *))h_nvnBootstrapLoader("nvnTextureFinalize");
    ab_initialize = (void (*)(NVNtexture *, const NVNtextureBuilder *))h_nvnBootstrapLoader("nvnTextureInitialize");
    if (!ab_finalize || !ab_initialize) { fprintf(stderr, "找不到 nvnTextureFinalize / nvnTextureInitialize\n"); return 2; }

    ab_make_tex(&ab_tex);
    ab_make_tex(&ab_tex2);
    memset(&ab_builder, 0, sizeof ab_builder);
    ab_builder.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 4, .height = 4, .depth = 1, .levels = 1};

    ab_tid = 3;
    pthread_t ta, tb;
    pthread_create(&tb, NULL, ab_thr_b, NULL);
    pthread_create(&ta, NULL, ab_thr_a, NULL);

    // 3 秒内两条线程都要收工；收不齐就是环路
    struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); ts.tv_sec += 3;
    pthread_mutex_lock(&ab_done_mu);
    while (ab_done < 2) if (pthread_cond_timedwait(&ab_done_cv, &ab_done_mu, &ts) == ETIMEDOUT) break;
    int done = ab_done;
    pthread_mutex_unlock(&ab_done_mu);

    int begins = atomic_load(&ab_block_begins);
    int old = ab_mode == AB_OLD;
    if (old) {
        // 负对照：没有 DM_BLOCK 就必然卡死。卡死算过；居然收工说明本测没构造出环路，判红。
        if (done < 2) { printf("✓ t_nvn_abba old：去掉 DM_BLOCK 后卡死（%d/2 完成，DM_BLOCK %d 次）→ 负对照成立\n", done, begins); fflush(stdout); _exit(0); }
        printf("✗ t_nvn_abba old：去掉 DM_BLOCK 竟然没卡死（%d/2 完成）→ 本测没构造出环路\n", done); fflush(stdout); _exit(1);
    }
    if (done < 2) { printf("✗ t_nvn_abba %s：卡死（%d/2 完成，DM_BLOCK %d 次）→ 持核线程在 g_rmu 上等，等核线程永远等不到核\n", m, done, begins); fflush(stdout); _exit(1); }
    if (begins < 1) { printf("✗ t_nvn_abba %s：两条都完成了，但 DM_BLOCK 一次没调（%d）→ 释放路径没走放核，只是碰巧没撞上\n", m, begins); fflush(stdout); _exit(1); }
    printf("✓ t_nvn_abba %s：两边都完成（DM_BLOCK %d 次）→ 持核线程在临界区前放核，环路断开\n", m, begins);
    return 0;
}
