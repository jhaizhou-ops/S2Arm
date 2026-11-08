#include <metal_stdlib>
using namespace metal;
kernel void fa(device float *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = 1.0f; }
