// 间接绘制参数的 GPU 拷贝核 mdx_mask（nvn_mtl.m mdx_emit_q 派发；单测 graphics/nvn/tests/t_nvn_icl.m 直接跑它）。
//   拷贝：带间接计数的多重绘制，计数以外的记录拷成 0（mdx_run）；普通间接绘制（cnt 为空）照拷。
//   夹紧（#2320，st 非空时）：索引数不超过索引缓冲所在存储剩下的长度减起始索引（lim，0 = 不限）；一笔超过 2^28 个顶点（索引数 × 实例数）画成空。
//   每夹一笔 st[0] 加一、st[1 + 序号 % 64] 记任务号（宿主 icl_report 点名）
#pragma once
static const char k_mdx_msl[] =
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct mjob { device const uint *rec; device const uint *cnt; device uint *out; device atomic_uint *st; uint i, words, id, pad; ulong lim; };\n"   // draw i's record (words long), its multi-draw's count (null: a plain indirect draw), the copy (null: padding); st / id / lim: the clamp (icl_*)
"kernel void mdx_mask(device const mjob *j [[buffer(0)]], uint t [[thread_position_in_grid]]) {\n"
"  mjob m = j[t]; if (!m.out) return; bool live = !m.cnt || m.i < *m.cnt;\n"
"  for (uint k = 0; k < m.words; k++) m.out[k] = live ? m.rec[k] : 0u;\n"
"  if (!live || !m.st) return; uint c = m.out[0], n = m.out[1]; bool bad = false;\n"
"  if (m.words == 5 && m.lim) { ulong f = m.out[2]; ulong room = f < m.lim ? m.lim - f : 0ul; if ((ulong)c > room) { c = (uint)room; bad = true; } }\n"   // indices past the index buffer's storage
"  if ((ulong)c * (ulong)n > (1ul << 28)) { c = 0u; bad = true; }\n"   // more than 2^28 vertices in one draw: arguments no game draws (seconds of GPU time); drawn as nothing
"  if (!bad) return; m.out[0] = c; uint k = atomic_fetch_add_explicit(&m.st[0], 1u, memory_order_relaxed);\n"
"  atomic_store_explicit(&m.st[1 + (k & 63u)], m.id, memory_order_relaxed); }\n";
