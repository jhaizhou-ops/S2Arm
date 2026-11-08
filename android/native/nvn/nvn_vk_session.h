// 直连 Vulkan 后端会话：device + 纹理/采样器缓存 + 后续管线/命令的容器。
// provider 将用它替换 d2r 引擎；当前先提供 create/destroy 与资源缓存，绘制/上屏逐步接入。
#pragma once
#include <stddef.h>
#include "vk_device.h"
#include "nvn_vk_texcache.h"
#include "nvn_vk_sampler_cache.h"
#include "nvn_vk_swapchain.h"
#include "nvn_vk_pipeline.h"
#include <android/native_window.h>

#ifdef __cplusplus
extern "C" {
#endif
struct nvn_vk_session {
    struct s2a_vk_device device;
    struct nvn_vk_texcache textures;
    struct nvn_vk_sampler_cache samplers;
    struct nvn_vk_swapchain swapchain;
    struct nvn_vk_pipeline_cache pipelines;
    int has_window;
    int ready;
};
// 首次调用前须零初始化；已有 device/instance/ready 时拒绝覆盖，销毁成功后才可重建。
int nvn_vk_session_create(struct nvn_vk_session *s, char *why, size_t why_size);
// 接游戏窗口：建 surface/swapchain（present 用）；失败写 why。
int nvn_vk_session_attach_window(struct nvn_vk_session *s, ANativeWindow *window, char *why, size_t why_size);
// 窗口被撤销/换代：先销毁交换链（有界观察最后一帧的 present fence），成功才清 has_window。
// 返回 0 = 已退休、可以归还/ACK 租约；-1 = 呈现退休没有证明，swapchain/surface/present fence
// 与租约都必须保留（调用方不得 release_window/released，也不得再 attach 新窗口）。
int nvn_vk_session_detach_window(struct nvn_vk_session *s);
// 清一帧并 present（真实 Surface）；失败写 why。
int nvn_vk_session_present_clear(struct nvn_vk_session *s, float r, float g, float b, float a, char *why, size_t why_size);
// 在已接的窗口上画一次 C2 程序（全屏三角形）并 present；blob 为 NVKP 文件路径。
int nvn_vk_session_draw_present(struct nvn_vk_session *s, const char *blob_path, char *why, size_t why_size);
// 前端 tex_t → 会话纹理缓存（供 mtl_tex_init 适配层使用）。
struct nvn_vk_tex *nvn_vk_session_tex(struct nvn_vk_session *s, const tex_t *t, char *why, size_t why_size);
// 丢掉某张 tex_t 的会话纹理（CPU 内容变了或纹理对象释放）。
void nvn_vk_session_tex_release(struct nvn_vk_session *s, const tex_t *t);
// 真实 gpu_owned（按 serial）：供前端决定 CPU 写是否通知成内容更新。
int nvn_vk_session_tex_gpu_owned(struct nvn_vk_session *s, uint64_t serial);
// CPU 改了内容：只标脏（下一次解析重传），不销毁会话纹理；与 Finalize 的释放分开。
// 这是无范围 hint（脏页轮询/外部写），不构成“哪些字节归 CPU”的证明。
void nvn_vk_session_tex_cpu_written(struct nvn_vk_session *s, const tex_t *t);
// CPU 声明写范围（权威内容归属）：池内存被 FlushMappedRange 发布的精确范围。
void nvn_vk_session_pool_written(struct nvn_vk_session *s, const void *mem, uint64_t off, uint64_t size);
// CPU 声明写范围：WriteTexels 的精确矩形（3D 的 z0/nz 是深度切片，其余是层）。
void nvn_vk_session_tex_written_rect(struct nvn_vk_session *s, const tex_t *t, unsigned level, unsigned layer0,
                                     int x, int y, int w, int h, int z0, int nz);
void nvn_vk_session_tex_gpu_written_subres(struct nvn_vk_session *s, const tex_t *t, unsigned level, unsigned layer);
// 游戏窗口纹理上屏：纹理缓存解析 + 缩放到 swapchain + present；失败写 why。
int nvn_vk_session_present_tex(struct nvn_vk_session *s, const tex_t *t, const int crop[4], char *why, size_t why_size);
// 销毁会话。返回 0 = 账本/呈现退休与设备收尾都已完成；-1 = 设备空闲、账本结清或
// 呈现退休没有证明（包括 DEVICE_LOST）：未退休对象与 device 保留，拒绝新会话，
// 由进程退出回收（调用方不得按“正常收局”
// 清 attempt/ACK 已完成）。显式 vkDestroyDevice 在孩子仍存活时执行是非法用法，这条路径不做。
int nvn_vk_session_destroy(struct nvn_vk_session *s);
// release 仅在终局结算与呈现退休成功、销毁 device 前调用。
int nvn_vk_session_destroy_with_callback(struct nvn_vk_session *s, void (*release)(struct s2a_vk_device *));
#ifdef __cplusplus
}
#endif
void nvn_vk_session_mark_written(struct nvn_vk_session *s, VkImage image);

