#version 450
// 采样两级 mip 纹理：纹理和渲染目标同尺寸、uv = 像素坐标 / 纹理尺寸 → 隐式 LOD 正好 0；采样器的 mipLodBias 把它推到第 1 级
layout(set = 0, binding = 0) uniform sampler2D t;
layout(location = 0) out vec4 o;
void main() { o = texture(t, gl_FragCoord.xy / vec2(textureSize(t, 0))); }
