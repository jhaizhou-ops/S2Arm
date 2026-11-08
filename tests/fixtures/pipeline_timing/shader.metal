#include <metal_stdlib>
using namespace metal;
vertex float4 fixture_vertex(uint id [[vertex_id]]) {
    return float4(float(id & 1) * 2.0 - 1.0, float((id >> 1) & 1) * 2.0 - 1.0, 0.0, 1.0);
}
struct VertexInput { float2 position [[attribute(0)]]; };
vertex float4 fixture_attributes(VertexInput in [[stage_in]]) { return float4(in.position, 0.0, 1.0); }
fragment float4 fixture_fragment() { return float4(1.0, 0.25, 0.0, 1.0); }
vertex float4 fixture_unused_vertex(uint id [[vertex_id]]) { return float4(float(id), 0.0, 0.0, 1.0); }
fragment float4 fixture_unused_fragment() { return float4(0.0, 0.0, 1.0, 1.0); }
kernel void fixture_compute(device float *out [[buffer(0)]]) { out[0] = 1.0; }
