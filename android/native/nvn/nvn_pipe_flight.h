// 配方级在途表（纯逻辑，无 Vulkan / 无设备）：同配方并发需求合并成一份创建，不同配方互不排队。
//
// 为什么要它（外部复核 P1-2）：原来 nvn_gpu_pipe_get 在 g_create_mu 下跑完整个 pipe_build，后台预热
// 配方 A 时首次 draw 要的配方 B 也得排队；拿锁后又不复检缓存，已排队的同配方还会再建一次、只在安装
// 阶段销毁重复品。Vulkan 对 vkCreateGraphicsPipelines 的外部同步要求以「建缓存时设了
// VK_PIPELINE_CACHE_CREATE_EXTERNALLY_SYNCHRONIZED_BIT」为前提（VUID-vkCreateGraphicsPipelines-
// pipelineCache-02876），本后端不设该标志 = 实现内部同步，所以不同配方可以并发建；同配方由这张表合并。
//
// 语义（调用方持有一个 nvk_pf，按配方进入）：
//   nvk_pf_enter → 1 = 你是建者：建完后必须且只能调用一次 nvk_pf_publish（成功给对象、失败给错误码/原因）；
//                → 2 = 同配方已有建者：调用 nvk_pf_wait 等自己那份结果（同一对象 / 同一错误原文）；
//                → 0 = 表不可用或已满：这次不合并，自己建（安装双检兜底，不会出现两份同配方对象）。
// 线程：内部一把互斥 + 每项一个条件变量；等待期间释放互斥。本表从不回调调用方，也不会与调用方的锁嵌套。
// 生命周期：表项不拥有对象，只记一次创建的结果；对象仍归调用方的缓存所有。
#pragma once
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NVK_PF_MAX 128        // 同时在途的配方上限
#define NVK_PF_WHY 192        // 错误原文缓冲（与 nvn_gpu_err.why 同长）
#define NVK_PF_KEY_MAX 512    // 配方键上限（nvn_gpu_pipe_desc 约 400 字节）

struct nvk_pf_ent {
    pthread_cond_t cv;
    uint8_t key[NVK_PF_KEY_MAX];
    void *obj;                // done && code==0：已装进缓存的管线条
    int code;                 // done 后有效：0 = 成功
    char why[NVK_PF_WHY];
    int users;                // 建者 1 + 等待者数；减到 0 时表项空闲
    uint8_t used, done;
};

typedef struct nvk_pf {
    pthread_mutex_t mu;
    int ready;                // cond 全部初始化成功才为 1
    size_t key_bytes;         // 配方键字节数（调用方在 init 时给）
    struct nvk_pf_ent ent[NVK_PF_MAX];
    uint64_t waits, full, late_hit, published, failures;
} nvk_pf;

// 初始化（幂等）。key_bytes 是配方键的字节数（超过 NVK_PF_KEY_MAX 直接停用整表，如实不合并）。
void nvk_pf_init(nvk_pf *t, size_t key_bytes);

// 进入一个新配方（用 eq 比较两个 key 是否同一配方，调用方给，通常就是缓存的 same_pipe_desc）。
// 返回 1 / 2 / 0，见文件头；*handle 在 1 / 2 时有效。
int nvk_pf_enter(nvk_pf *t, const void *key, int (*eq)(const void *, const void *), int *handle);

// 建者发布结果（每次 enter 返回 1 后必须恰好调一次）。obj 成功时给已安装对象，失败给 NULL。
void nvk_pf_publish(nvk_pf *t, int handle, void *obj, int code, const char *why);

// 等待者取结果（enter 返回 2 后调用）。返回 0 = 成功（*obj）；非 0 = 建者给的错误码（why 里是原文）。
int nvk_pf_wait(nvk_pf *t, int handle, void **obj, char *why, size_t why_cap);

// 记录一次「认领后复检缓存命中」（调用方在建之前先复检缓存，命中就省掉一次重复创建）。
void nvk_pf_note_late_hit(nvk_pf *t);

// 读数快照：waits 合并等待次数 / full 表满或停用 / late_hit 认领后复检命中 / published / failures。
void nvk_pf_stats(const nvk_pf *t, uint64_t *waits, uint64_t *full, uint64_t *late_hit,
                  uint64_t *published, uint64_t *failures);

#ifdef __cplusplus
}
#endif
