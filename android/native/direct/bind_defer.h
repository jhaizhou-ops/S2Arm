// Bind*Deferred 句柄记录的回放解析（纯计算，宿主回归可原样编译）。
// 记录契约在 nvn_obj.h p_bind_handles：defer=1 时 h[] 在录制时未填（游戏之后才写句柄数组），
// src 是游戏侧句柄数组地址，h[n] 之后追加了录制时的纹理/采样器池编号基址 p_bind_pool_bases。
// 语义与 nvn_mtl.m bh_fresh 对齐：回放读时才取句柄，并按录制时的池基址把池局部编号换成绝对编号。
#pragma once
#include <stddef.h>
#include <stdint.h>

#include "nvn_obj.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef int (*s2a_guest_read_fn)(void *opaque, uint64_t address, void *dst, size_t bytes);

enum {
    S2A_BH_OK = 0,
    S2A_BH_INVALID = 1,   // 记录本身不成立（计数越界 / 载荷不够长 / deferred 缺池基址尾）
    S2A_BH_MEMORY = 2,    // deferred 句柄数组读不到
};

// 解析 OP_BIND_TEX / OP_BIND_SAMP / OP_BIND_IMG 的载荷（op_hdr 之后的字节；不含 OP_BIND_TEX1，
// 单条组合绑定已经由 bind_rec 折好且不带 defer）。
// 非 deferred 记录只按 p_bind_handles 取出；deferred 记录另经 rd 读游戏句柄数组并重基。
// 失败时 *why 指向静态说明串；out 不保证内容。
int s2a_bind_handles_parse(s2a_guest_read_fn rd, void *opaque,
                           const void *payload, uint32_t payload_bytes,
                           p_bind_handles *out, const char **why);

#ifdef __cplusplus
}
#endif
