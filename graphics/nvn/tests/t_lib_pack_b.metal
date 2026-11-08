#include <metal_stdlib>
using namespace metal;
kernel void fb(device float *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = 2.0f; }
