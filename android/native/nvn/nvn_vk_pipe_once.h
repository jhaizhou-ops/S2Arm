// 「同一配方只有一份」的装载判定（backend_vulkan.c 的管线缓存用）。
//
// 语义：调用方按配方查过一次、没查到，于是建了新对象；建完之后调本模块 adopt。adopt 在调用方给的
// 锁下**再查一次**（双检）：查到同配方就把新建的那份销毁、把既有的那份交出来；查不到才把新建的装进
// 表。这样「提交线程同步建」与「预热线程后台建」同时撞同一配方时，后端缓存里那一份是唯一的——
// 渲染结果与缓存判据都依赖这个唯一性。
//
// 线程：调用方持自己的锁（backend 是 g_mu）。本模块不取锁、不假设单线程，也不记任何全局状态。
// 生命周期：本模块不拥有对象。被丢弃的新建对象由 destroy 回调真的销毁（不是留着泄漏，也不是交给
//   GC）；交出去的那份归调用方的表。
// 出错：find / link / destroy 任一为空、或 fresh 为空 → 返回 -1，*out 置 NULL，调用方据此销毁新建对象
//   并报红（不返回假成功）。
//
// 纯逻辑、无图形 API 类型（对象是 void*），宿主单测用假创建函数 + 两个线程驱动（见
// android/tests/nvn_vk_pipe_once_test.c）。
#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// 调用方注入的三件事；ctx 原样回传（backend 传 NULL）。
typedef struct nvk_pipe_once_ops {
    void *ctx;
    void *(*find)(void *ctx, const void *key, size_t key_bytes);   // 查同配方的既有对象；没有返回 NULL
    void (*link)(void *ctx, void *fresh);                          // 把新建对象装进调用方的表
    void (*destroy)(void *ctx, void *fresh);                       // 销毁被丢弃的新建对象
} nvk_pipe_once_ops;

// 返回 1 = 用了既有的（新建的那份已经由 destroy 销毁，*out = 既有）
//      0 = 用了新建的（已经由 link 装表，*out = fresh）
//     -1 = 参数非法（*out = NULL；fresh 没被动过，调用方自己销毁并报红）
int nvk_pipe_once_adopt(const nvk_pipe_once_ops *ops, const void *key, size_t key_bytes, void *fresh, void **out);

#ifdef __cplusplus
}
#endif
