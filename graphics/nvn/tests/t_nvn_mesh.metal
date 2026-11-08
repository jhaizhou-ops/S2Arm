// t_nvn_mesh.m 的任务 / 网格着色器夹具（mk 按 KIND 编成三份库，形状照 Switch2 兼容线「网格着色接口约定」：入口 main0 / main0_z，起始工作组号在 buffer(29)）。
// 网格工作组 c 画 8×4 目标的第 c 列（整列）：x ∈ [c/4 − 1, (c+1)/4 − 1]，像素中心 (i + 0.5)/4 − 1 落在其中 ⇔ i == c，没有像素中心压边
//   KIND 1：任务（object）main0：任务工作组号 t = dm_first[0] + 组号，派 2 个网格工作组，载荷带 t
//   KIND 2：有任务的网格（mesh）：列 = 2t + 组号
//   KIND 3：无任务的网格：列 = dm_first[0] + 组号
//   网格两份的 main0（GL 深度约定）一个图元都不出：测试开 near = 0，画出来就证明载入的是 main0_z
#include <metal_stdlib>
using namespace metal;
struct V { float4 p [[position]]; };
struct PL { uint t; };
using M = mesh<V, void, 4, 2, topology::triangle>;
#define QUAD(m, tid, col) do { \
    if ((tid) == 0) (m).set_primitive_count(2); \
    if ((tid) < 4) { V v; float x = float((col) + ((tid) & 1)) / 4.0 - 1.0; v.p = float4(x, ((tid) & 2) ? 1.0 : -1.0, 0.0, 1.0); (m).set_vertex((tid), v); } \
    const uchar ix[6] = {0, 1, 2, 2, 1, 3}; if ((tid) < 6) (m).set_index((tid), ix[(tid)]); } while (0)
#if KIND == 1
[[object]] void main0(object_data PL &pl [[payload]], mesh_grid_properties mgp, uint tid [[thread_index_in_threadgroup]], uint g [[threadgroup_position_in_grid]],
                      constant uint *dm_first [[buffer(29)]]) {
    if (tid == 0) { pl.t = dm_first[0] + g; mgp.set_threadgroups_per_grid(uint3(2, 1, 1)); }
}
#elif KIND == 2
[[mesh]] void main0(M m, uint tid [[thread_index_in_threadgroup]]) { if (tid == 0) m.set_primitive_count(0); }
[[mesh]] void main0_z(M m, const object_data PL &pl [[payload]], uint tid [[thread_index_in_threadgroup]], uint g [[threadgroup_position_in_grid]],
                      constant uint *dm_first [[buffer(29)]]) { QUAD(m, tid, 2 * pl.t + g); }
#else
[[mesh]] void main0(M m, uint tid [[thread_index_in_threadgroup]]) { if (tid == 0) m.set_primitive_count(0); }
[[mesh]] void main0_z(M m, uint tid [[thread_index_in_threadgroup]], uint g [[threadgroup_position_in_grid]], constant uint *dm_first [[buffer(29)]]) { QUAD(m, tid, dm_first[0] + g); }
#endif
