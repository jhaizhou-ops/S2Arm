// SMAA, Jorge Jimenez et al. Derived from the bundled Ryujinx SmaaNeighbour.spv
// using SPIRV-Cross; copyright and license: AA-LICENSE.txt.
#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

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
void SMAANeighborhoodBlendingVS(thread const float2& texcoord, thread float4& offset)
{
    offset = fma(float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).xyxy, float4(1.0, 0.0, 0.0, 1.0), texcoord.xyxy);
}

static inline __attribute__((always_inline))
void SMAAMovc(thread const bool2& cond, thread float2& variable, thread const float2& value)
{
    if (cond.x)
    {
        variable.x = value.x;
    }
    if (cond.y)
    {
        variable.y = value.y;
    }
}

static inline __attribute__((always_inline))
void SMAAMovc(thread const bool4& cond, thread float4& variable, thread const float4& value)
{
    bool2 param = cond.xy;
    float2 param_1 = variable.xy;
    float2 param_2 = value.xy;
    SMAAMovc(param, param_1, param_2);
    variable.x = param_1.x;
    variable.y = param_1.y;
    bool2 param_3 = cond.zw;
    float2 param_4 = variable.zw;
    float2 param_5 = value.zw;
    SMAAMovc(param_3, param_4, param_5);
    variable.z = param_4.x;
    variable.w = param_4.y;
}

static inline __attribute__((always_inline))
float4 SMAANeighborhoodBlendingPS(thread const float2& texcoord, thread const float4& offset, texture2d<float> colorTex, sampler colorTexSmplr, texture2d<float> blendTex, sampler blendTexSmplr)
{
    float4 a;
    a.x = blendTex.sample(blendTexSmplr, offset.xy, level(0.0)).w;
    a.y = blendTex.sample(blendTexSmplr, offset.zw, level(0.0)).y;
    float2 _122 = blendTex.sample(blendTexSmplr, texcoord, level(0.0)).xz;
    a.w = _122.x;
    a.z = _122.y;
    if (dot(a, float4(1.0)) < 9.9999997473787516355514526367188e-06)
    {
        float4 color = colorTex.sample(colorTexSmplr, texcoord, level(0.0));
        return color;
    }
    else
    {
        bool h = fast::max(a.x, a.z) > fast::max(a.y, a.w);
        float4 blendingOffset = float4(0.0, a.y, 0.0, a.w);
        float2 blendingWeight = a.yw;
        bool4 param = bool4(h, h, h, h);
        float4 param_1 = blendingOffset;
        float4 param_2 = float4(a.x, 0.0, a.z, 0.0);
        SMAAMovc(param, param_1, param_2);
        blendingOffset = param_1;
        bool2 param_3 = bool2(h, h);
        float2 param_4 = blendingWeight;
        float2 param_5 = a.xz;
        SMAAMovc(param_3, param_4, param_5);
        blendingWeight = param_4;
        blendingWeight /= float2(dot(blendingWeight, float2(1.0)));
        float4 blendingCoord = fma(blendingOffset, float4(float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).xy, -float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).xy), texcoord.xyxy);
        float4 color_1 = colorTex.sample(colorTexSmplr, blendingCoord.xy, level(0.0)) * blendingWeight.x;
        color_1 += (colorTex.sample(colorTexSmplr, blendingCoord.zw, level(0.0)) * blendingWeight.y);
        return color_1;
    }
}

static float3 aa_encode_srgb(float3 linear)
{
    return select(1.055 * pow(max(linear, float3(0.0)), float3(1.0 / 2.4)) - 0.055,
                  12.92 * linear, linear <= float3(0.0031308));
}

kernel void aa_neighbour(constant invResolution& _294 [[buffer(0)]], texture2d<float> inputImg [[texture(0)]], texture2d<float> samplerBlend [[texture(1)]], texture2d<float, access::write> imgOutput [[texture(2)]], sampler inputImgSmplr [[sampler(0)]], sampler samplerBlendSmplr [[sampler(1)]], uint3 gl_GlobalInvocationID [[thread_position_in_grid]])
{
    float2 loc = float2(int2(gl_GlobalInvocationID.xy * AA_PIXELS_PER_THREAD));
    float4 param_1;
    for (uint i = 0; i < AA_PIXELS_PER_THREAD; i++)
    {
        for (uint j = 0; j < AA_PIXELS_PER_THREAD; j++)
        {
            int2 texelCoord = int2(int(loc.x + float(i)), int(loc.y + float(j)));
            if (any(texelCoord >= int2(imgOutput.get_width(), imgOutput.get_height()))) continue;
            float2 coord = (float2(texelCoord) + float2(0.5)) / _294.invResolution_data;
            float2 param = coord;
            SMAANeighborhoodBlendingVS(param, param_1);
            float4 offset = param_1;
            float2 param_2 = coord;
            float4 param_3 = offset;
            float4 oColor = SMAANeighborhoodBlendingPS(param_2, param_3, inputImg, inputImgSmplr, samplerBlend, samplerBlendSmplr);
            imgOutput.write(float4(aa_encode_srgb(oColor.rgb), 1.0), uint2(texelCoord));
        }
    }
}
