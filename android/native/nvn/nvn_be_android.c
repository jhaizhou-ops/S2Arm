// main 的后端诊断入口在 Android 侧的实现（Apple 侧在 nvn_mtl.m）。
//
// 共享前端 hle_nvn.c 由 main 维护，直接调用 nvn_be_* / nvn_diag_path；本线的 Android 后端
// （mtl_vk_shim.c / nvn_vk.c / vk_nvn_adapter.c）原先只实现 mtl_* 这一套。这个文件承接
// 没有 mtl_ 对应物、或语义依赖 Apple 平台的那几个入口，三个构建共用，避免各写一份。
//
// 原则：能给真实读数就给，给不了就明确记录，不返回伪造的成功。
#include <stdio.h>
#include <stdint.h>
#include <string.h>

// 后台着色器预取（Apple 侧用后台队列预载库）。Android 侧按首遇编译，没有按 key 预取的入口：
// 记录一次说明，不假装已经预载。合流前 Android 本来就没有这一步，行为不变。
void nvn_be_shader_prefetch(const uint8_t key[8]) {
    (void)key;
    static int said;
    if (!said) { said = 1; fprintf(stderr, "[nvn-android] shader prefetch 未接线：按首遇编译\n"); }
}

// 诊断输出路径（DM_NVN_TSV 等）。main 在非 iOS 平台就是原样返回传入路径（见 nvn_mtl.m 的 #else 分支），
// Android 与之一致：不改写、不创建目录，调用方按给到的路径 fopen。
const char *nvn_diag_path(const char *p, char *buf, size_t n) {
    (void)buf; (void)n;
    return p;
}

// 每 300 帧一次的内存读数（调用方已限频、限行）。Apple 侧会带 Metal 侧分配量与资源表统计；
// Android 没有那些账本，只如实报前端给的进程常驻值，不编造 GPU 数字。
void nvn_be_mem_stat(unsigned long long frame, unsigned long long rss_mb) {
    fprintf(stderr, "[nvn-android] frame %llu: 进程常驻 %llu MB（无 Metal 侧记账）\n",
            frame, rss_mb);
}

// 纹理生命周期摘要（DM_NVN_ALLOCPROF，每 300 帧一行；Apple 侧 nvn_mtl.m 按 init / release 计数器报）。
// Android 后端（mtl_vk_shim.c）没有这套计数器：开关打开时如实说明一次「未接线」，不编造 init / release 数字；
// 开关不开时什么都不做。共享前端 hle_nvn.c 每帧调用它（#1086 引入），Android 单库缺这个定义会链接失败。
#include <stdlib.h>
void nvn_be_tex_tick(uint64_t frame) {
    static int on = -1;
    if (on < 0) on = getenv("DM_NVN_ALLOCPROF") != NULL;
    if (!on || (frame % 300) != 0) return;
    static int said;
    if (!said) { said = 1; fprintf(stderr, "[nvn-android] 纹理生命周期计数未接线（DM_NVN_ALLOCPROF 的 [tex] 行只在 Apple 后端有）\n"); }
}

// ---------------------------------------------------------------------------
// 会话生命周期：main 的 hle_nvn.c 在 Apple 侧由 nvn_session.inc（Metal 资源账本）实现；
// Android 侧没有 Metal 账本，交给本线的 Vulkan adapter 做同一件事：
//   begin     → 清掉上一会话的停止/退休失败标记，允许新会话重建；
//   stop      → 把图形翻译队列跑空并 join，再置停止位（真实动作，不空转）；
//   drain     → 提交已录制的帧队列并等 GPU 完成（guest fence 的完成证明）；
//   shutdown  → 停线程后拆会话/设备/缓存；退休失败如实返回 -1，不假装已正常收尾。
#include <errno.h>
#include "mtl_vk_adapter.h"

void nvn_be_begin_session(void) {
    s2a_vk_adapter_new_session();
}

int nvn_be_request_stop(void) {
    extern void s2a_mtl_async_stop(void) __attribute__((weak));
    if (!s2a_mtl_async_stop) return -ENOSYS;
    s2a_mtl_async_stop();
    return 0;
}

int nvn_be_drain_session(void) {
    return s2a_vk_adapter_flush();
}

int nvn_be_shutdown_session(void) {
    return s2a_vk_adapter_shutdown();
}

// 按 GL 纹理名建 NVN 纹理（nvnTextureBuilderSetGLTextureName；Apple 侧 nvn_mtl.m 把描述与存储接到 GL 那张 MTLTexture）。
// Android 后端没有 GL 层：如实记录一次「未接线」，返回 0 让前端保留 builder 自己的描述，不伪造成功。
// 共享前端 hle_nvn.c 的 nvnTextureInitialize 调用它（11-03 火影羁绊 Scaleform），缺定义 Android 单库链接失败。
// t 是前端的 tex_t*，这里不解引用，按不透明指针声明，免得把 nvn_obj.h（直连出库阶段键的输入）拉进来。
// GPU 等事件（nvnCommandBufferWaitEvent，hle_nvn.c）：Metal 后端在 GPU 上等到事件满足条件，CPU 写事件后由这里放行（nvn_mtl.m nvn_be_event_written）。
//   安卓 Vulkan 后端还没实现 GPU 等事件：vk_record.c 见到 NVN_EV_WAIT 位的记录直接跳过（照旧不等），没有挂起的等待要放行。
//   注意本函数不是 GPU 侧信号（nvnCommandBufferSignalEvent / ReportValue）的完成语义入口：那条写值由回放层
//   vk_record.c 落 guest 内存，所以“值可见前必须已 GPU 完成”的证明放在回放入口（mtl_vk_adapter.c
//   adapter_event_completion_gate）。CPU 侧 nvnEventSignal（ev_signal）按 NVN 就是立即写、没有完成契约，
//   在这里补 flush 只会多等一轮 GPU，语义反而变重；等 GPU 等事件接线后这里再承担放行等待的职责。
// 原始池表（苹果端 nvn_mtl.m gmem_map）在安卓后端还没有：翻译器的原始全局内存访问那里照旧不支持，记账无事可做（hle_nvn.c pool_mark_addressed 要这个入口）
void nvn_be_pool_addressed(const void *mem, uint64_t size) { (void)mem; (void)size; }
void nvn_be_event_written(volatile uint32_t *val) { (void)val; }
// 池里录到 GPU 写（hle_nvn.c 录制处 → 苹果端 nvn_mtl.m tex_cpu_content 的首用取存储规则）：安卓后端没有首用取存储这条，记账无事可做
void nvn_be_pool_gpu_written(const void *pool) { (void)pool; }
// 间接计数多绘的整段记录（OP_MULTI_DRAW，nvn2_cmd.h）安卓回放（vk_record.c）不认：返回 0，hle_nvn.c 照旧逐条录、截到前 1,024 条
int nvn_be_multi_draw_range(void) { return 0; }
int nvn_be_buf_extent_consumer(void) { return 1; }   // Vulkan 回放 size=0 storage 绑定按地址求活缓冲精确长度（nvn_vk_mrt.c → hle_nvn.c nvn_buf_extent）：要前端登记
void nvn_be_event_gpu_recorded(volatile uint32_t *val) { (void)val; }   // 同上：安卓后端不在 GPU 上等事件，录制时的 GPU 侧信号记账无事可做
// 一次提交（hle_nvn.c nvnQueueSubmitCommands → 苹果端 nvn_mtl.m nvn_xqueue.inc 按跨队列事件顺序分段回放）：安卓后端不在 GPU 上等事件（见上），没有要停住的队列，
//   照旧整段回放；每段前后的 hle 钩子同苹果端。跨队列停住的那几个入口回「没有停住的工作」
void nvn_hle_queue_enter(void *q); void nvn_hle_piece_begun(void);
void nvn_be_sub_begin(void); void nvn_be_sub_index(const uint64_t *h, int n); void nvn_be_exec_rest(const uint64_t *h, int n); void nvn_be_exec(const uint8_t *p); uint64_t nvn_be_sub_commit(void);
void nvn_be_submit(void *q, const uint64_t *h, int n) {
    nvn_hle_queue_enter(q); nvn_be_sub_begin(); nvn_hle_piece_begun(); nvn_be_sub_index(h, n);
    for (int i = 0; i < n; i++) { nvn_be_exec_rest(h + i + 1, n - i - 1); nvn_be_exec((const uint8_t *)(uintptr_t)h[i]); }
    nvn_be_exec_rest(NULL, 0); nvn_be_sub_commit();
}
void nvn_be_xq_flush(void *q, const char *why) { (void)q; (void)why; }
int nvn_be_xq_fence(void *q, void *s) { (void)q; (void)s; return 0; }
int nvn_be_xq_owed(const void *s, void **q) { (void)s; (void)q; return 0; }
int nvn_be_xq_owed_wait(const void *s, uint64_t ns) { (void)s; (void)ns; return 1; }
void nvn_be_xq_wait_queue(void *q, void *owner) { (void)q; (void)owner; }
// 脏页轮询的 GPU 归属判定（hle_nvn.c nvn_ft_poll → nvn_mtl.m nvn_be_tex_gpu_owned_since）：安卓后端没有按页的 GPU 写账，照旧按整张贴图判（mtl_tex_gpu_owned）
int mtl_tex_gpu_owned(uint64_t serial);
int nvn_be_tex_gpu_owned_since(uint64_t serial, uint64_t stamp) { (void)stamp; return mtl_tex_gpu_owned(serial); }
int nvn_be_tex_from_gl(void *t, uint32_t gl_name) {
    (void)t;
    static int said;
    if (!said) { said = 1; fprintf(stderr, "[nvn-android] 按 GL 纹理名建 NVN 纹理未接线（GL 名 %u）：保留 builder 的描述\n", gl_name); }
    return 0;
}

// Switch 2 的 nvn2.c（显示最大缓冲档位等）问主机 / 掌机档：口径同苹果宿主 graphics/nvn/host_adapt.m（S2A_DOCKED=1 主机，其余掌机）
int dm_opmode(void) { const char *d = getenv("S2A_DOCKED"); return d && !strcmp(d, "1"); }
