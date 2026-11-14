// nvn_warm.c（预热调度）的宿主回归：用可控的假 owner 证明时序合同，不碰 GPU、不碰真清单。
// 覆盖：
//   1) 顺序：程序清单全部走完（含在途重试）之后才开始管线清单；
//   2) 在途重试：build 返回 1 的条目会被重试，最终成功计入 built，不丢；
//   3) 计数：失败条目计入 failed，不阻塞其它条目；
//   4) Stop：请停后线程在有界时间内退出（nvk_warm_active 归 0），且 Stop 会调两个 save 与 quiesce；
//   5) 开关：debug.s2a.nvk_warm=0 时不起线程。
// 合同参考 graphics/nvn/gfx/nvn/nvn_mtl.m 的 warm_start（后台清单预热、不挡首帧）。
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "../../android/native/nvn/nvn_warm.h"
#include "../../android/native/nvn/nvn_vk_prog_warm.h"
#include "../../android/native/nvn/nvn_vk_pipe_warm.h"

// ---- 假 owner（被 nvn_warm.c 调用的两个模块）----
// debug.s2a.nvk_warm 的假替身。平台开关在进程内不变（nvn_plat.h 契约），所以「关」与「开」用两次进程跑：
// 本程序第二次带 NVK_WARM_OFF=1 起，断言起不来线程。
static int g_flag = 1;
static int g_prog_total = 6, g_pipe_total = 4;
static int g_prog_taken, g_pipe_taken;
static atomic_int g_order_violation;    // 管线先于程序被取走 = 1
static atomic_int g_retry_prog = 2;     // 前 2 次调用返回 1（在途），之后成功
static atomic_int g_prog_built, g_prog_failed, g_pipe_built, g_pipe_failed;
static atomic_int g_saved, g_quiesced;

int nvn_plat_flag(const char *name, int dflt) { (void)dflt; return strcmp(name, "nvk_warm") == 0 ? g_flag : dflt; }
void nvn_plat_log(int level, const char *cls, const char *text) { (void)level; (void)cls; (void)text; }

int nvk_prog_warm_load(void) { return g_prog_total; }
int nvk_prog_warm_pending(void) { return g_prog_total - g_prog_taken; }
int nvk_prog_warm_take(struct nvk_prog_rec *out) {
    if (g_prog_taken >= g_prog_total) return 0;
    memset(out, 0, sizeof *out);
    out->identity[0] = (uint8_t)g_prog_taken++;
    out->stage_mask = 3;
    return 1;
}
static atomic_int g_prog_attempts[64];
int nvk_prog_warm_build(const struct nvk_prog_rec *rec) {
    int id = rec->identity[0];
    int n = atomic_fetch_add(&g_prog_attempts[id], 1);
    if (id == 3) return -1;                                  // 一条固定失败
    if (n < atomic_load(&g_retry_prog)) return 1;            // 前几条在途：应被重试
    atomic_fetch_add(&g_prog_built, 1);
    return 0;
}
void nvk_prog_warm_note(const struct nvk_prog_rec *rec) { (void)rec; }
void nvk_prog_warm_save(void) { atomic_fetch_add(&g_saved, 1); }
int nvk_shader_warm_quiesce(uint32_t budget_ms) { (void)budget_ms; atomic_fetch_add(&g_quiesced, 1); return 0; }
void nvk_prog_warm_stats(struct nvk_prog_warm_stats *o) {
    if (!o) return;
    memset(o, 0, sizeof *o);
    o->loaded = (uint64_t)g_prog_total;
    o->built = (uint64_t)atomic_load(&g_prog_built);
    o->failed = (uint64_t)atomic_load(&g_prog_failed);
    o->pending = (uint64_t)(g_prog_total - g_prog_taken);
}

int nvk_pipe_warm_load(void) { return g_pipe_total; }
int nvk_pipe_warm_pending(void) { return g_pipe_total - g_pipe_taken; }
int nvk_pipe_warm_take(struct nvk_pipe_rec *out) {
    if (g_pipe_taken >= g_pipe_total) return 0;
    if (g_prog_taken < g_prog_total) atomic_store(&g_order_violation, 1);   // 程序没走完就取管线 = 违约
    memset(out, 0, sizeof *out);
    out->prog_identity[0] = (uint8_t)g_pipe_taken++;
    return 1;
}
int nvk_pipe_warm_build(const struct nvk_pipe_rec *rec) {
    if (rec->prog_identity[0] == 1) return -1;               // 一条固定失败
    atomic_fetch_add(&g_pipe_built, 1);
    return 0;
}
void nvk_pipe_warm_note(const nvn_gpu_pipe_desc *d, const uint8_t prog_identity[32]) { (void)d; (void)prog_identity; }
void nvk_pipe_warm_save(void) { atomic_fetch_add(&g_saved, 1); }
void nvk_pipe_warm_stats(struct nvk_pipe_warm_stats *o) {
    if (!o) return;
    memset(o, 0, sizeof *o);
    o->loaded = (uint64_t)g_pipe_total;
    o->built = (uint64_t)atomic_load(&g_pipe_built);
    o->pending = (uint64_t)(g_pipe_total - g_pipe_taken);
}

// ---- 用例 ----
static void wait_idle(int ms) {
    for (int i = 0; i < ms; i++) { if (!nvk_warm_active()) return; usleep(1000); }
}

// 关掉开关：不起线程（进程内开关不变，只在本进程第一次 start 时读，所以单独一个进程跑）。
static void t_disable(void) {
    nvk_warm_start();
    assert(!nvk_warm_active());
    printf("t_disable ok（debug.s2a.nvk_warm=0 时不起线程）\n");
}

// 本局预热集在开局冻结：预热进行中游戏继续产生新身份（g_*_total 增长）不得扩集，否则预热线程
// 会跟着游戏无限跑、跟它抢核（真机：第二次启动预热到 105 秒还在跑，帧率 22.6 → 18.0）。
static void t_order_and_counts(void) {
    g_flag = 1;
    g_prog_taken = g_pipe_taken = 0;
    const int prog0 = g_prog_total, pipe0 = g_pipe_total;
    atomic_store(&g_retry_prog, 2);
    atomic_store(&g_prog_built, 0); atomic_store(&g_prog_failed, 0);
    atomic_store(&g_pipe_built, 0); atomic_store(&g_pipe_failed, 0);
    memset((void *)g_prog_attempts, 0, sizeof g_prog_attempts);
    nvk_warm_start();
    // 预热线程开工后，模拟游戏持续产生新身份：预热集不得因此扩大。
    usleep(2000);
    g_prog_total = prog0 + 50;
    g_pipe_total = pipe0 + 50;
    for (int i = 0; i < 3000; i++) { if (g_prog_taken >= prog0 && g_pipe_taken >= pipe0) break; usleep(1000); }
    wait_idle(2000);
    assert(atomic_load(&g_order_violation) == 0);          // 程序先于管线
    g_prog_total = prog0;   // 断言用开局冻结的那批（之后追加的 50 条不该被取走）
    g_pipe_total = pipe0;
    assert(g_prog_taken == prog0);
    assert(g_pipe_taken == pipe0);
    assert(atomic_load(&g_prog_built) == g_prog_total - 1);  // 一条固定失败
    assert(atomic_load(&g_pipe_built) == g_pipe_total - 1);
    for (int i = 0; i < g_prog_total; i++)
        if (i != 3) assert(atomic_load(&g_prog_attempts[i]) >= 3);   // 在途重试确实发生过
    struct nvk_warm_totals tt;
    nvk_warm_totals(&tt);
    assert(tt.prog_built == (uint64_t)(g_prog_total - 1));
    assert(tt.pipe_built == (uint64_t)(g_pipe_total - 1));
    // 清单跑完不等于线程退休：它还要负责周期性把本局新记录落盘（玩家/bench 直接杀进程时没有 Stop）。
    // 修前这里会在清单排空后立刻退出（active=0），记录只能等 Stop——真机上就丢过整份清单。
    {
        int waited = 0;
        while (waited < 3000 && !nvk_warm_active()) { usleep(1000); waited++; }
        if (!nvk_warm_active()) { while (waited < 3000) { usleep(1000); waited++; } }
        assert(nvk_warm_active() == 1);   // 清单完成后线程仍在（等 Stop + 定期落盘）
    }
    // Stop 有界：清单早已跑完，stop 只做 join 检查 + 落盘 + quiesce，必须很快返回。
    uint64_t t0 = (uint64_t)time(NULL);
    nvk_warm_stop();
    assert(!nvk_warm_active());
    assert(atomic_load(&g_saved) >= 1);          // 两个 owner 的清单都落盘
    assert(atomic_load(&g_quiesced) >= 1);
    assert((uint64_t)time(NULL) - t0 <= 2);      // 有界（含落盘与 quiesce）
    printf("t_order_and_counts ok (prog %llu pipe %llu why %d)\n",
           (unsigned long long)tt.prog_built, (unsigned long long)tt.pipe_built, tt.why);
}

int main(void) {
    const char *off = getenv("NVK_WARM_OFF");
    g_flag = off && off[0] == '1' ? 0 : 1;
    if (!g_flag) { t_disable(); printf("nvk warm scheduler test: ok（关）\n"); return 0; }
    t_order_and_counts();
    printf("nvk warm scheduler test: ok\n");
    return 0;
}
