// GPU 挂死看门狗（T10 / #635，缺省关）：某批命令缓冲提交后超过 N 毫秒仍未完成，由一条独立线程判卡死并 _exit。
//
// 与既有 gal_gpu_stall_exit（gal_core.m）的分工 —— 这是本模块存在的全部理由：
//   gal_gpu_stall_exit 长在「正在等栅栏的那条线程」里：只有那条线程还在被调度、还在转 200 ms 轮询，才走得到它。
//   本模块长在一条不碰 Metal、不持 GAL API 锁、也不取任何互斥量的线程上，只按「提交时刻 → 现在」算年龄。
//   于是进程里所有线程都堵在无超时的 Metal 调用里（waitUntilCompleted / commit / nextDrawable / 等事件）时，
//   它照样能判、照样能退 —— 而那条路径恰恰是 gal_gpu_stall_exit 覆盖不到的。
//
// 无锁（T10 现场结论）：看门狗的判据只读三个原子量（每栅栏的提交时刻、已登记的最大栅栏、已完成的最大栅栏），
//   不取互斥量。理由是 s2a_dump_threads（runtime/src/tdump.c）会 thread_suspend 全部线程；若某条被挂起的线程
//   正持着看门狗要的锁，看门狗就跟着停摆，等于把「救命的线程」挂在「出事的那条线程」上。原子量没有这个耦合。
//
// 缺省不改任何既有行为：NXGAL_GPU_WD_MS 不设 = 不建线程、不判、每次提交只多一次全局 int 读。
// 阈值建议（研究文档 §5 定档）：Mac 8000 ms 起步。不能照抄现有 3 秒 —— 动森进岛第一帧单缓冲 6945 绘制、
// GPU 跑超 3 秒属正常负载（gal_core.m:1111-1114）；而 Metal越界.md #46 的 25.7 秒是病理自旋实验，不是正常负载，不纳入定档。
#pragma once
#include <stddef.h>
#include <stdint.h>

// 开了没有（0 = 关，缺省）
int gal_gpuwd_on(void);

// 提交时的现场：全是整数，由提交线程在登记那一刻填好，按栅栏号存进看门狗自己的环。
// 判死时看门狗只格式化这些数 —— 不回调宿主、不读宿主全局、不碰 Metal（审计 #772 F-gpuwd-scene-live：
//   原先判死时回调宿主现读，读到的是提交后已清零的在录通道和别的帧号，还在 _exit 前调了 MTLSharedEvent.signaledValue）
typedef struct {
    uint32_t draws, encs;   // 本批命令缓冲里的绘制+派发数 / 编码器数
    uint64_t frame;         // 本批所属的帧号
    uint32_t pass_w, pass_h, pass_fmt, pass_draws, pass_kind;   // 本批最后在录的通道：宽 / 高 / 格式 / 绘制数 / 种类（1 渲染 2 拷贝 / 计算）
} gal_gpuwd_scene;

// 提交登记：fence = 本次提交的栅栏号（每次提交 +1，连续），sc = 这次提交的现场（只进现场行；可为 NULL = 全 0）
void gal_gpuwd_on_commit(uint64_t fence, const gal_gpuwd_scene *sc);

// 完成推进：done = 已完成的最大栅栏号（同一条队列按提交序完成）。只前进，不回退
void gal_gpuwd_on_done(uint64_t done);

// 日志出口（可选）：不装就 fprintf(stderr)。gal_core 装成 GLOG，行格式与其余读数一致
void gal_gpuwd_set_log(void (*fn)(const char *line));

// ---------- 单测钩子（tests/t_gpuwd.c）----------
// 判据（纯函数）：age_ms = 最老在途命令缓冲的年龄，late_ms = 看门狗自己比预期晚到的量。
// 返回 0 不动 / 1 只打一行「慢」 / 2 判卡死
int gal_gpuwd_test_decide(uint64_t age_ms, uint64_t late_ms);
// 把 _exit(86) 换成 fn（单测在进程内验退出路径而不真死）
void gal_gpuwd_test_set_exit(void (*fn)(int code));
// 清零全部状态（单测每项之间复位；生产不调）
void gal_gpuwd_test_reset(void);
// 当前在途条数（已登记 − 已完成）
uint64_t gal_gpuwd_test_inflight(void);
