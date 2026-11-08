// SMAA, Jorge Jimenez et al. Derived from the bundled Ryujinx SmaaEdge.spv
// using SPIRV-Cross; copyright and license: AA-LICENSE.txt.
#pragma clang diagnostic ignored "-Wmissing-prototypes"
#pragma clang diagnostic ignored "-Wmissing-braces"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

template<typename T, size_t Num>
struct spvUnsafeArray
{
    T elements[Num ? Num : 1];

    thread T& operator [] (size_t pos) thread
    {
        return elements[pos];
    }
    constexpr const thread T& operator [] (size_t pos) const thread
    {
        return elements[pos];
    }
    device T& operator [] (size_t pos) device
    {
        return elements[pos];
    }
    constexpr const device T& operator [] (size_t pos) const device
    {
        return elements[pos];
    }
    constexpr const constant T& operator [] (size_t pos) const constant
    {
        return elements[pos];
    }
    threadgroup T& operator [] (size_t pos) threadgroup
    {
        return elements[pos];
    }
    constexpr const threadgroup T& operator [] (size_t pos) const threadgroup
    {
        return elements[pos];
    }
};

constant float METRIC_WIDTH_tmp [[function_constant(4)]];
constant float METRIC_WIDTH = is_function_constant_defined(METRIC_WIDTH_tmp) ? METRIC_WIDTH_tmp : 1920.0;
constant float METRIC_HEIGHT_tmp [[function_constant(5)]];
constant float METRIC_HEIGHT = is_function_constant_defined(METRIC_HEIGHT_tmp) ? METRIC_HEIGHT_tmp : 1080.0;
constant uint AA_PIXELS_PER_THREAD_tmp [[function_constant(6)]];
constant uint AA_PIXELS_PER_THREAD = is_function_constant_defined(AA_PIXELS_PER_THREAD_tmp) ? AA_PIXELS_PER_THREAD_tmp : 4u;

struct invResolution
{
    float2 invResolution_data;
};

constant int SMAA_PRESET_LOW_tmp [[function_constant(0)]];
constant int SMAA_PRESET_LOW = is_function_constant_defined(SMAA_PRESET_LOW_tmp) ? SMAA_PRESET_LOW_tmp : 0;
constant int SMAA_PRESET_MEDIUM_tmp [[function_constant(1)]];
constant int SMAA_PRESET_MEDIUM = is_function_constant_defined(SMAA_PRESET_MEDIUM_tmp) ? SMAA_PRESET_MEDIUM_tmp : 0;
constant int SMAA_PRESET_HIGH_tmp [[function_constant(2)]];
constant int SMAA_PRESET_HIGH = is_function_constant_defined(SMAA_PRESET_HIGH_tmp) ? SMAA_PRESET_HIGH_tmp : 0;
constant int SMAA_PRESET_ULTRA_tmp [[function_constant(3)]];
constant int SMAA_PRESET_ULTRA = is_function_constant_defined(SMAA_PRESET_ULTRA_tmp) ? SMAA_PRESET_ULTRA_tmp : 0;
constant uint3 gl_WorkGroupSize [[maybe_unused]] = uint3(16u, 16u, 1u);

static inline __attribute__((always_inline))
void SMAAEdgeDetectionVS(thread const float2& texcoord, thread spvUnsafeArray<float4, 3>& offset)
{
    offset[0] = fma(float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).xyxy, float4(-1.0, 0.0, 0.0, -1.0), texcoord.xyxy);
    offset[1] = fma(float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).xyxy, float4(1.0, 0.0, 0.0, 1.0), texcoord.xyxy);
    offset[2] = fma(float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).xyxy, float4(-2.0, 0.0, 0.0, -2.0), texcoord.xyxy);
}

static inline __attribute__((always_inline))
float2 SMAAColorEdgeDetectionPS(thread const float2& texcoord, thread const spvUnsafeArray<float4, 3>& offset, texture2d<float> colorTex, sampler colorTexSmplr)
{
    float2 threshold = float2(SMAA_PRESET_LOW ? 0.15 : SMAA_PRESET_ULTRA ? 0.05 : 0.1);
    float3 C = colorTex.sample(colorTexSmplr, texcoord, level(0.0)).xyz;
    float3 Cleft = colorTex.sample(colorTexSmplr, offset[0].xy, level(0.0)).xyz;
    float3 t = abs(C - Cleft);
    float4 delta;
    delta.x = fast::max(fast::max(t.x, t.y), t.z);
    float3 Ctop = colorTex.sample(colorTexSmplr, offset[0].zw, level(0.0)).xyz;
    t = abs(C - Ctop);
    delta.y = fast::max(fast::max(t.x, t.y), t.z);
    float2 edges = step(threshold, delta.xy);
    if (dot(edges, float2(1.0)) == 0.0)
    {
        return float2(-2.0);
    }
    float3 Cright = colorTex.sample(colorTexSmplr, offset[1].xy, level(0.0)).xyz;
    t = abs(C - Cright);
    delta.z = fast::max(fast::max(t.x, t.y), t.z);
    float3 Cbottom = colorTex.sample(colorTexSmplr, offset[1].zw, level(0.0)).xyz;
    t = abs(C - Cbottom);
    delta.w = fast::max(fast::max(t.x, t.y), t.z);
    float2 maxDelta = fast::max(delta.xy, delta.zw);
    float3 Cleftleft = colorTex.sample(colorTexSmplr, offset[2].xy, level(0.0)).xyz;
    t = abs(C - Cleftleft);
    delta.z = fast::max(fast::max(t.x, t.y), t.z);
    float3 Ctoptop = colorTex.sample(colorTexSmplr, offset[2].zw, level(0.0)).xyz;
    t = abs(C - Ctoptop);
    delta.w = fast::max(fast::max(t.x, t.y), t.z);
    maxDelta = fast::max(maxDelta, delta.zw);
    float finalDelta = fast::max(maxDelta.x, maxDelta.y);
    edges *= step(float2(finalDelta), delta.xy * 2.0);
    return edges;
}

kernel void aa_edge(constant invResolution& _302 [[buffer(0)]], texture2d<float> inputImg [[texture(0)]], texture2d<float, access::write> imgOutput [[texture(1)]], sampler inputImgSmplr [[sampler(0)]], uint3 gl_GlobalInvocationID [[thread_position_in_grid]])
{
    float2 loc = float2(int2(gl_GlobalInvocationID.xy * AA_PIXELS_PER_THREAD));
    spvUnsafeArray<float4, 3> param_1;
    for (uint i = 0; i < AA_PIXELS_PER_THREAD; i++)
    {
        for (uint j = 0; j < AA_PIXELS_PER_THREAD; j++)
        {
            int2 texelCoord = int2(int(loc.x + float(i)), int(loc.y + float(j)));
            if (any(texelCoord >= int2(imgOutput.get_width(), imgOutput.get_height()))) continue;
            float2 coord = (float2(texelCoord) + float2(0.5)) / _302.invResolution_data;
            float2 param = coord;
            SMAAEdgeDetectionVS(param, param_1);
            spvUnsafeArray<float4, 3> offset = param_1;
            float2 param_2 = coord;
            spvUnsafeArray<float4, 3> param_3 = offset;
            float2 oColor = SMAAColorEdgeDetectionPS(param_2, param_3, inputImg, inputImgSmplr);
            // The GLSL discard sentinel must clear the recycled edge surface.
            imgOutput.write(float4(all(oColor == float2(-2.0)) ? float2(0.0) : oColor, 0.0, 1.0), uint2(texelCoord));
        }
    }
}
