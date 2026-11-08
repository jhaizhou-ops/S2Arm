// 写跟踪的平台接缝：Linux/Android 实现，不模拟 Mach ABI。
#pragma once
#include <stddef.h>
#include <stdint.h>

// 真实映射权限（PROT_*）；失败返回负 errno。缺页上下文可调用，不分配、不取用户锁。
int s2a_track_platform_protection(uintptr_t address);
// 同一 maps 扫描顺带取共享位：返回宿主权限（负 errno 失败），*shared = 1 共享映射 / 0 私有 backing。
int s2a_track_platform_prot_shared(uintptr_t address, int *shared);
// 共享同一 backing 的临时映射；不能复制内容冒充别名。正常上下文调用。
// 失败返回 errno、*out=NULL，原映射和原权限保持不变。
int s2a_track_platform_alias(uintptr_t address, size_t size, int protection, void **out);
// 返回 0 或 errno：ENOENT=别名栈下溢（无配对），EINVAL=地址/长度与登记不符，ESTALE=镜像世代已翻（可整段重试）。
int s2a_track_platform_unalias(void *address, size_t size);
// unalias 报 ESTALE 时记账一次（镜像统计里的 retry 计数）。
void s2a_track_platform_note_stale(void);
// 镜像换页写者计数（#1184 D1）：写路径取写别名前 enter、写完（含记账）后 leave。
// mirror_begin 翻奇数后必须等计数归零（有界，超限报红）才改映射；计数中的线程再取别名遇到奇数世代
// 返回 EAGAIN（不得等待，否则与等计数互锁），调用方 leave 后 wait_stable 等偶数再重试。
void s2a_track_platform_writer_enter(void);
void s2a_track_platform_writer_leave(void);
// 等镜像世代回到偶数；0 = 已稳定，ETIMEDOUT = 超时（已报红）。
int s2a_track_platform_wait_stable(void);
// 仅释放已不含存活快照的页；保留虚拟地址。
int s2a_track_platform_discard(void *address, size_t size);
