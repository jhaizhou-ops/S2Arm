// t_pso_registry 的着色器（10-23 起离线编成 metallib 随单测发布：单测不再现场编 MSL）
#include <metal_stdlib>
using namespace metal;
vertex float4 registry_vertex(uint i [[vertex_id]]) { float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; return float4(p[i],0,1); }
fragment float4 registry_red() { return float4(1,0,0,1); }
fragment float4 registry_green() { return float4(0,1,0,1); }
fragment float4 registry_blue() { return float4(0,0,1,1); }
fragment float4 registry_slow() { return float4(0,0,1,1); }
fragment float4 registry_other() { return float4(0,1,0,1); }
fragment float4 registry_missing() { return float4(1,0,0,1); }
