// t_nvn_tess_dom ⑦ 的三角域 hull 核：mk 编成 <库目录>/4444444444444444_b_t1.metallib（同出库 tess_finish 的 <key>_b_t<域> 库，S2A.Dsh graphics/tools/direct/dsh/Dsh.cs，函数名 main0）。
// 接口槽同生产 tess_draw ②：buffer(23) = 曲面因子（三角 4 个 half：3 条边 + 内部），buffer(24) = {P, Pt}；一个线程一片（输出控制点数 1）。因子全写 1 → 每片 1 个三角形
#include <metal_stdlib>
using namespace metal;
kernel void main0(device half *tl [[buffer(23)]], constant uint2 &pp [[buffer(24)]], uint g [[thread_position_in_grid]]) {
    if (g < pp.y) for (uint k = 0; k < 4; k++) tl[g * 4 + k] = half(1);
}
