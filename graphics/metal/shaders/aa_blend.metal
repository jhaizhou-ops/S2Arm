// SMAA, Jorge Jimenez et al. Derived from the bundled Ryujinx SmaaBlend.spv
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
// The original GLSL tests preprocessor defines, not its specialization ints.
// Explicitly restore the four published SMAA presets after SPIR-V translation.
constant float SMAA_SEARCH = SMAA_PRESET_LOW ? 4.0 : SMAA_PRESET_MEDIUM ? 8.0 : SMAA_PRESET_ULTRA ? 32.0 : 16.0;
constant float SMAA_DIAG = SMAA_PRESET_ULTRA ? 15.0 : 7.0;
constant uint3 gl_WorkGroupSize [[maybe_unused]] = uint3(16u, 16u, 1u);

static inline __attribute__((always_inline))
void SMAABlendingWeightCalculationVS(thread const float2& texcoord, thread float2& pixcoord, thread spvUnsafeArray<float4, 3>& offset)
{
    pixcoord = texcoord * float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).zw;
    offset[0] = fma(float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).xyxy, float4(-0.25, -0.125, 1.25, -0.125), texcoord.xyxy);
    offset[1] = fma(float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).xyxy, float4(-0.125, -0.25, -0.125, 1.25), texcoord.xyxy);
    offset[2] = fma(float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).xxyy, SMAA_SEARCH * float4(-2.0, 2.0, -2.0, 2.0), float4(offset[0].xz, offset[1].yw));
}

static inline __attribute__((always_inline))
float2 SMAASearchDiag1(texture2d<float> edgesTex, sampler edgesTexSmplr, thread const float2& texcoord, thread const float2& dir, thread float2& e)
{
    float4 coord = float4(texcoord, -1.0, 1.0);
    float3 t = float3(float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).xy, 1.0);
    for (;;)
    {
        bool _260 = coord.z < SMAA_DIAG;
        bool _267;
        if (_260)
        {
            _267 = coord.w > 0.89999997615814208984375;
        }
        else
        {
            _267 = _260;
        }
        if (_267)
        {
            float4 _273 = coord;
            float3 _275 = fma(t, float3(dir, 1.0), _273.xyz);
            coord.x = _275.x;
            coord.y = _275.y;
            coord.z = _275.z;
            e = edgesTex.sample(edgesTexSmplr, coord.xy, level(0.0)).xy;
            coord.w = dot(e, float2(0.5));
            continue;
        }
        else
        {
            break;
        }
    }
    return coord.zw;
}

static inline __attribute__((always_inline))
float4 SMAADecodeDiagBilinearAccess(thread float4& e)
{
    float4 _218 = e;
    float4 _220 = e;
    float2 _226 = _218.xz * abs((_220.xz * 5.0) - float2(3.75));
    e.x = _226.x;
    e.z = _226.y;
    return round(e);
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
float2 SMAAAreaDiag(texture2d<float> areaTex, sampler areaTexSmplr, thread const float2& dist, thread const float2& e, thread const float& offset)
{
    float2 texcoord = fma(float2(20.0), e, dist);
    texcoord = fma(float2(0.0062500000931322574615478515625, 0.001785714295692741870880126953125), texcoord, float2(0.00312500004656612873077392578125, 0.0008928571478463709354400634765625));
    texcoord.x += 0.5;
    texcoord.y += (0.14285714924335479736328125 * offset);
    return areaTex.sample(areaTexSmplr, texcoord, level(0.0)).xy;
}

static inline __attribute__((always_inline))
float2 SMAADecodeDiagBilinearAccess(thread float2& e)
{
    e.x *= abs((5.0 * e.x) - 3.75);
    return round(e);
}

static inline __attribute__((always_inline))
float2 SMAASearchDiag2(texture2d<float> edgesTex, sampler edgesTexSmplr, thread const float2& texcoord, thread const float2& dir, thread float2& e)
{
    float4 coord = float4(texcoord, -1.0, 1.0);
    coord.x += (0.25 * float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).x);
    float3 t = float3(float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).xy, 1.0);
    for (;;)
    {
        bool _327 = coord.z < SMAA_DIAG;
        bool _333;
        if (_327)
        {
            _333 = coord.w > 0.89999997615814208984375;
        }
        else
        {
            _333 = _327;
        }
        if (_333)
        {
            float4 _339 = coord;
            float3 _341 = fma(t, float3(dir, 1.0), _339.xyz);
            coord.x = _341.x;
            coord.y = _341.y;
            coord.z = _341.z;
            e = edgesTex.sample(edgesTexSmplr, coord.xy, level(0.0)).xy;
            float2 param = e;
            float2 _355 = SMAADecodeDiagBilinearAccess(param);
            e = _355;
            coord.w = dot(e, float2(0.5));
            continue;
        }
        else
        {
            break;
        }
    }
    return coord.zw;
}

static inline __attribute__((always_inline))
float2 SMAACalculateDiagWeights(texture2d<float> edgesTex, sampler edgesTexSmplr, texture2d<float> areaTex, sampler areaTexSmplr, thread const float2& texcoord, thread const float2& e, thread const float4& subsampleIndices)
{
    float2 weights = float2(0.0);
    float4 d;
    float2 end;
    if (e.x > 0.0)
    {
        float2 param = texcoord;
        float2 param_1 = float2(-1.0, 1.0);
        float2 param_2;
        float2 _408 = SMAASearchDiag1(edgesTex, edgesTexSmplr, param, param_1, param_2);
        end = param_2;
        d.x = _408.x;
        d.z = _408.y;
        d.x += float(end.y > 0.89999997615814208984375);
    }
    else
    {
        d.x = 0.0;
        d.z = 0.0;
    }
    float2 param_3 = texcoord;
    float2 param_4 = float2(1.0, -1.0);
    float2 param_5;
    float2 _432 = SMAASearchDiag1(edgesTex, edgesTexSmplr, param_3, param_4, param_5);
    end = param_5;
    d.y = _432.x;
    d.w = _432.y;
    if ((d.x + d.y) > 2.0)
    {
        float4 coords = fma(float4((-d.x) + 0.25, d.x, d.y, (-d.y) - 0.25), float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).xyxy, texcoord.xyxy);
        float2 _476 = edgesTex.sample(edgesTexSmplr, coords.xy, level(0.0), int2(-1, 0)).xy;
        float4 c;
        c.x = _476.x;
        c.y = _476.y;
        float2 _486 = edgesTex.sample(edgesTexSmplr, coords.zw, level(0.0), int2(1, 0)).xy;
        c.z = _486.x;
        c.w = _486.y;
        float4 param_6 = c;
        float4 _493 = SMAADecodeDiagBilinearAccess(param_6);
        c = float4(_493.y, _493.x, _493.w, _493.z);
        float2 cc = fma(float2(2.0), c.xz, c.yw);
        bool2 param_7 = step(float2(0.89999997615814208984375), d.zw) != float2(0.0);
        float2 param_8 = cc;
        float2 param_9 = float2(0.0);
        SMAAMovc(param_7, param_8, param_9);
        cc = param_8;
        float2 param_10 = d.xy;
        float2 param_11 = cc;
        float param_12 = subsampleIndices.z;
        weights += SMAAAreaDiag(areaTex, areaTexSmplr, param_10, param_11, param_12);
    }
    float2 param_13 = texcoord;
    float2 param_14 = float2(-1.0);
    float2 param_15;
    float2 _530 = SMAASearchDiag2(edgesTex, edgesTexSmplr, param_13, param_14, param_15);
    end = param_15;
    d.x = _530.x;
    d.z = _530.y;
    if (edgesTex.sample(edgesTexSmplr, texcoord, level(0.0), int2(1, 0)).x > 0.0)
    {
        float2 param_16 = texcoord;
        float2 param_17 = float2(1.0);
        float2 param_18;
        float2 _548 = SMAASearchDiag2(edgesTex, edgesTexSmplr, param_16, param_17, param_18);
        end = param_18;
        d.y = _548.x;
        d.w = _548.y;
        d.y += float(end.y > 0.89999997615814208984375);
    }
    else
    {
        d.y = 0.0;
        d.w = 0.0;
    }
    if ((d.x + d.y) > 2.0)
    {
        float4 coords_1 = fma(float4(-d.x, -d.x, d.y, d.y), float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).xyxy, texcoord.xyxy);
        float4 c_1;
        c_1.x = edgesTex.sample(edgesTexSmplr, coords_1.xy, level(0.0), int2(-1, 0)).y;
        c_1.y = edgesTex.sample(edgesTexSmplr, coords_1.xy, level(0.0), int2(0, -1)).x;
        float2 _612 = edgesTex.sample(edgesTexSmplr, coords_1.zw, level(0.0), int2(1, 0)).yx;
        c_1.z = _612.x;
        c_1.w = _612.y;
        float2 cc_1 = fma(float2(2.0), c_1.xz, c_1.yw);
        bool2 param_19 = step(float2(0.89999997615814208984375), d.zw) != float2(0.0);
        float2 param_20 = cc_1;
        float2 param_21 = float2(0.0);
        SMAAMovc(param_19, param_20, param_21);
        cc_1 = param_20;
        float2 param_22 = d.xy;
        float2 param_23 = cc_1;
        float param_24 = subsampleIndices.w;
        weights += SMAAAreaDiag(areaTex, areaTexSmplr, param_22, param_23, param_24).yx;
    }
    return weights;
}

static inline __attribute__((always_inline))
float SMAASearchLength(texture2d<float> searchTex, sampler searchTexSmplr, thread const float2& e, thread const float& offset)
{
    float2 scale = float2(33.0, -33.0);
    float2 bias0 = float2(66.0, 33.0) * float2(offset, 1.0);
    scale += float2(-1.0, 1.0);
    bias0 += float2(0.5, -0.5);
    scale *= float2(0.015625, 0.0625);
    bias0 *= float2(0.015625, 0.0625);
    return searchTex.sample(searchTexSmplr, fma(scale, e, bias0), level(0.0)).x;
}

static inline __attribute__((always_inline))
float SMAASearchXLeft(texture2d<float> edgesTex, sampler edgesTexSmplr, texture2d<float> searchTex, sampler searchTexSmplr, thread float2& texcoord, thread const float& end)
{
    float2 e = float2(0.0, 1.0);
    for (;;)
    {
        bool _691 = texcoord.x > end;
        bool _698;
        if (_691)
        {
            _698 = e.y > 0.828100025653839111328125;
        }
        else
        {
            _698 = _691;
        }
        bool _704;
        if (_698)
        {
            _704 = e.x == 0.0;
        }
        else
        {
            _704 = _698;
        }
        if (_704)
        {
            e = edgesTex.sample(edgesTexSmplr, texcoord, level(0.0)).xy;
            texcoord = fma(float2(-2.0, -0.0), float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).xy, texcoord);
            continue;
        }
        else
        {
            break;
        }
    }
    float2 param = e;
    float param_1 = 0.0;
    float offset = fma(-2.007874011993408203125, SMAASearchLength(searchTex, searchTexSmplr, param, param_1), 3.25);
    return fma(float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).x, offset, texcoord.x);
}

static inline __attribute__((always_inline))
float SMAASearchXRight(texture2d<float> edgesTex, sampler edgesTexSmplr, texture2d<float> searchTex, sampler searchTexSmplr, thread float2& texcoord, thread const float& end)
{
    float2 e = float2(0.0, 1.0);
    for (;;)
    {
        bool _745 = texcoord.x < end;
        bool _751;
        if (_745)
        {
            _751 = e.y > 0.828100025653839111328125;
        }
        else
        {
            _751 = _745;
        }
        bool _757;
        if (_751)
        {
            _757 = e.x == 0.0;
        }
        else
        {
            _757 = _751;
        }
        if (_757)
        {
            e = edgesTex.sample(edgesTexSmplr, texcoord, level(0.0)).xy;
            texcoord = fma(float2(2.0, 0.0), float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).xy, texcoord);
            continue;
        }
        else
        {
            break;
        }
    }
    float2 param = e;
    float param_1 = 0.5;
    float offset = fma(-2.007874011993408203125, SMAASearchLength(searchTex, searchTexSmplr, param, param_1), 3.25);
    return fma(-float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).x, offset, texcoord.x);
}

static inline __attribute__((always_inline))
float2 SMAAArea(texture2d<float> areaTex, sampler areaTexSmplr, thread const float2& dist, thread const float& e1, thread const float& e2, thread const float& offset)
{
    float2 texcoord = fma(float2(16.0), round(float2(e1, e2) * 4.0), dist);
    texcoord = fma(float2(0.0062500000931322574615478515625, 0.001785714295692741870880126953125), texcoord, float2(0.00312500004656612873077392578125, 0.0008928571478463709354400634765625));
    texcoord.y = fma(0.14285714924335479736328125, offset, texcoord.y);
    return areaTex.sample(areaTexSmplr, texcoord, level(0.0)).xy;
}

static inline __attribute__((always_inline))
void SMAADetectHorizontalCornerPattern(texture2d<float> edgesTex, sampler edgesTexSmplr, thread float2& weights, thread const float4& texcoord, thread const float2& d)
{
    if (SMAA_PRESET_LOW || SMAA_PRESET_MEDIUM) return;
    float2 leftRight = step(d, d.yx);
    float2 rounding = leftRight * 0.75;
    rounding /= float2(leftRight.x + leftRight.y);
    float2 factor = float2(1.0);
    factor.x -= (rounding.x * edgesTex.sample(edgesTexSmplr, texcoord.xy, level(0.0), int2(0, 1)).x);
    factor.x -= (rounding.y * edgesTex.sample(edgesTexSmplr, texcoord.zw, level(0.0), int2(1)).x);
    factor.y -= (rounding.x * edgesTex.sample(edgesTexSmplr, texcoord.xy, level(0.0), int2(0, -2)).x);
    factor.y -= (rounding.y * edgesTex.sample(edgesTexSmplr, texcoord.zw, level(0.0), int2(1, -2)).x);
    weights *= fast::clamp(factor, float2(0.0), float2(1.0));
}

static inline __attribute__((always_inline))
float SMAASearchYUp(texture2d<float> edgesTex, sampler edgesTexSmplr, texture2d<float> searchTex, sampler searchTexSmplr, thread float2& texcoord, thread const float& end)
{
    float2 e = float2(1.0, 0.0);
    for (;;)
    {
        bool _796 = texcoord.y > end;
        bool _802;
        if (_796)
        {
            _802 = e.x > 0.828100025653839111328125;
        }
        else
        {
            _802 = _796;
        }
        bool _808;
        if (_802)
        {
            _808 = e.y == 0.0;
        }
        else
        {
            _808 = _802;
        }
        if (_808)
        {
            e = edgesTex.sample(edgesTexSmplr, texcoord, level(0.0)).xy;
            texcoord = fma(float2(-0.0, -2.0), float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).xy, texcoord);
            continue;
        }
        else
        {
            break;
        }
    }
    float2 param = e.yx;
    float param_1 = 0.0;
    float offset = fma(-2.007874011993408203125, SMAASearchLength(searchTex, searchTexSmplr, param, param_1), 3.25);
    return fma(float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).y, offset, texcoord.y);
}

static inline __attribute__((always_inline))
float SMAASearchYDown(texture2d<float> edgesTex, sampler edgesTexSmplr, texture2d<float> searchTex, sampler searchTexSmplr, thread float2& texcoord, thread const float& end)
{
    float2 e = float2(1.0, 0.0);
    for (;;)
    {
        bool _846 = texcoord.y < end;
        bool _852;
        if (_846)
        {
            _852 = e.x > 0.828100025653839111328125;
        }
        else
        {
            _852 = _846;
        }
        bool _858;
        if (_852)
        {
            _858 = e.y == 0.0;
        }
        else
        {
            _858 = _852;
        }
        if (_858)
        {
            e = edgesTex.sample(edgesTexSmplr, texcoord, level(0.0)).xy;
            texcoord = fma(float2(0.0, 2.0), float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).xy, texcoord);
            continue;
        }
        else
        {
            break;
        }
    }
    float2 param = e.yx;
    float param_1 = 0.5;
    float offset = fma(-2.007874011993408203125, SMAASearchLength(searchTex, searchTexSmplr, param, param_1), 3.25);
    return fma(-float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).y, offset, texcoord.y);
}

static inline __attribute__((always_inline))
void SMAADetectVerticalCornerPattern(texture2d<float> edgesTex, sampler edgesTexSmplr, thread float2& weights, thread const float4& texcoord, thread const float2& d)
{
    if (SMAA_PRESET_LOW || SMAA_PRESET_MEDIUM) return;
    float2 leftRight = step(d, d.yx);
    float2 rounding = leftRight * 0.75;
    rounding /= float2(leftRight.x + leftRight.y);
    float2 factor = float2(1.0);
    factor.x -= (rounding.x * edgesTex.sample(edgesTexSmplr, texcoord.xy, level(0.0), int2(1, 0)).y);
    factor.x -= (rounding.y * edgesTex.sample(edgesTexSmplr, texcoord.zw, level(0.0), int2(1)).y);
    factor.y -= (rounding.x * edgesTex.sample(edgesTexSmplr, texcoord.xy, level(0.0), int2(-2, 0)).y);
    factor.y -= (rounding.y * edgesTex.sample(edgesTexSmplr, texcoord.zw, level(0.0), int2(-2, 1)).y);
    weights *= fast::clamp(factor, float2(0.0), float2(1.0));
}

static inline __attribute__((always_inline))
float4 SMAABlendingWeightCalculationPS(thread const float2& texcoord, thread const float2& pixcoord, thread const spvUnsafeArray<float4, 3>& offset, texture2d<float> edgesTex, sampler edgesTexSmplr, texture2d<float> areaTex, sampler areaTexSmplr, texture2d<float> searchTex, sampler searchTexSmplr, thread const float4& subsampleIndices)
{
    float4 weights = float4(0.0);
    float2 e = edgesTex.sample(edgesTexSmplr, texcoord, level(0.0)).xy;
    if (e.y > 0.0)
    {
        float2 param = texcoord;
        float2 param_1 = e;
        float4 param_2 = subsampleIndices;
        float2 _1080 = float2(0.0);
        if (!SMAA_PRESET_LOW && !SMAA_PRESET_MEDIUM)
            _1080 = SMAACalculateDiagWeights(edgesTex, edgesTexSmplr, areaTex, areaTexSmplr, param, param_1, param_2);
        weights.x = _1080.x;
        weights.y = _1080.y;
        if (weights.x == (-weights.y))
        {
            float2 param_3 = offset[0].xy;
            float param_4 = offset[2].x;
            float _1101 = SMAASearchXLeft(edgesTex, edgesTexSmplr, searchTex, searchTexSmplr, param_3, param_4);
            float3 coords;
            coords.x = _1101;
            coords.y = offset[1].y;
            float2 d;
            d.x = coords.x;
            float e1 = edgesTex.sample(edgesTexSmplr, coords.xy, level(0.0)).x;
            float2 param_5 = offset[0].zw;
            float param_6 = offset[2].y;
            float _1123 = SMAASearchXRight(edgesTex, edgesTexSmplr, searchTex, searchTexSmplr, param_5, param_6);
            coords.z = _1123;
            d.y = coords.z;
            d = abs(round(fma(float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).zz, d, -pixcoord.xx)));
            float2 sqrt_d = sqrt(d);
            float e2 = edgesTex.sample(edgesTexSmplr, coords.zy, level(0.0), int2(1, 0)).x;
            float2 param_7 = sqrt_d;
            float param_8 = e1;
            float param_9 = e2;
            float param_10 = subsampleIndices.y;
            float2 _1157 = SMAAArea(areaTex, areaTexSmplr, param_7, param_8, param_9, param_10);
            weights.x = _1157.x;
            weights.y = _1157.y;
            coords.y = texcoord.y;
            float2 param_11 = weights.xy;
            float4 param_12 = coords.xyzy;
            float2 param_13 = d;
            SMAADetectHorizontalCornerPattern(edgesTex, edgesTexSmplr, param_11, param_12, param_13);
            weights.x = param_11.x;
            weights.y = param_11.y;
        }
        else
        {
            e.x = 0.0;
        }
    }
    if (e.x > 0.0)
    {
        float2 param_14 = offset[1].xy;
        float param_15 = offset[2].z;
        float _1194 = SMAASearchYUp(edgesTex, edgesTexSmplr, searchTex, searchTexSmplr, param_14, param_15);
        float3 coords_1;
        coords_1.y = _1194;
        coords_1.x = offset[0].x;
        float2 d_1;
        d_1.x = coords_1.y;
        float e1_1 = edgesTex.sample(edgesTexSmplr, coords_1.xy, level(0.0)).y;
        float2 param_16 = offset[1].zw;
        float param_17 = offset[2].w;
        float _1216 = SMAASearchYDown(edgesTex, edgesTexSmplr, searchTex, searchTexSmplr, param_16, param_17);
        coords_1.z = _1216;
        d_1.y = coords_1.z;
        d_1 = abs(round(fma(float4(1.0 / METRIC_WIDTH, 1.0 / METRIC_HEIGHT, METRIC_WIDTH, METRIC_HEIGHT).ww, d_1, -pixcoord.yy)));
        float2 sqrt_d_1 = sqrt(d_1);
        float e2_1 = edgesTex.sample(edgesTexSmplr, coords_1.xz, level(0.0), int2(0, 1)).y;
        float2 param_18 = sqrt_d_1;
        float param_19 = e1_1;
        float param_20 = e2_1;
        float param_21 = subsampleIndices.x;
        float2 _1250 = SMAAArea(areaTex, areaTexSmplr, param_18, param_19, param_20, param_21);
        weights.z = _1250.x;
        weights.w = _1250.y;
        coords_1.x = texcoord.x;
        float2 param_22 = weights.zw;
        float4 param_23 = coords_1.xyxz;
        float2 param_24 = d_1;
        SMAADetectVerticalCornerPattern(edgesTex, edgesTexSmplr, param_22, param_23, param_24);
        weights.z = param_22.x;
        weights.w = param_22.y;
    }
    return weights;
}

kernel void aa_blend(constant invResolution& _1325 [[buffer(0)]], texture2d<float> inputImg [[texture(0)]], texture2d<float> samplerArea [[texture(1)]], texture2d<float> samplerSearch [[texture(2)]], texture2d<float, access::write> imgOutput [[texture(3)]], sampler inputImgSmplr [[sampler(0)]], sampler samplerAreaSmplr [[sampler(1)]], sampler samplerSearchSmplr [[sampler(2)]], uint3 gl_GlobalInvocationID [[thread_position_in_grid]])
{
    int2 loc = int2(gl_GlobalInvocationID.xy * AA_PIXELS_PER_THREAD);
    float2 param_1;
    spvUnsafeArray<float4, 3> param_2;
    for (uint i = 0; i < AA_PIXELS_PER_THREAD; i++)
    {
        for (uint j = 0; j < AA_PIXELS_PER_THREAD; j++)
        {
            int2 texelCoord = int2(loc.x + i, loc.y + j);
            if (any(texelCoord >= int2(imgOutput.get_width(), imgOutput.get_height()))) continue;
            float2 coord = (float2(texelCoord) + float2(0.5)) / _1325.invResolution_data;
            float2 param = coord;
            SMAABlendingWeightCalculationVS(param, param_1, param_2);
            float2 pixCoord = param_1;
            spvUnsafeArray<float4, 3> offset = param_2;
            float2 param_3 = coord;
            float2 param_4 = pixCoord;
            spvUnsafeArray<float4, 3> param_5 = offset;
            float4 param_6 = float4(0.0);
            float4 oColor = SMAABlendingWeightCalculationPS(param_3, param_4, param_5, inputImg, inputImgSmplr, samplerArea, samplerAreaSmplr, samplerSearch, samplerSearchSmplr, param_6);
            imgOutput.write(oColor, uint2(texelCoord));
        }
    }
}
