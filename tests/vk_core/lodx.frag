#version 450
// 同 lod.frag，显式 LOD 0（textureLod）：采样器的 mipLodBias 照样加上去（Vulkan 规范 16.5.7：λ' = λbase + 采样器偏置，显式 LOD 也算）
layout(set = 0, binding = 0) uniform sampler2D t;
layout(location = 0) out vec4 o;
void main() { o = textureLod(t, gl_FragCoord.xy / vec2(textureSize(t, 0)), 0.0); }
