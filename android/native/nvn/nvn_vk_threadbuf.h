// 每线程一块惰性分配、线程退出自动归还的缓冲。
//
// 为什么单独一层：备忘/暂存这类“每线程几 MB”的缓冲原来写成 `static __thread` 数组（1.2 MB 静态 TLS），
// 改成堆分配后必须解决“线程退出谁归还”——会话重建会重建渲染线程，预热路径也可能各建一份。
// 用 pthread_key 挂析构统一归还，任何线程生命周期都不泄漏，宿主可测（单测：线程退出后 live 归零）。
#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// 取本线程的缓冲：首次调用按 bytes 分配；之后同线程再调返回同一块（bytes 更大时扩容并保留原内容）。
// 分配失败返回 NULL（调用方按“没有缓冲”降级，不能影响正确性）。
void *nvn_vk_threadbuf_acquire(size_t bytes);
// 诊断/测试：当前仍活着的线程缓冲块数（线程退出后应减回去）。
int nvn_vk_threadbuf_live(void);

#ifdef __cplusplus
}
#endif
