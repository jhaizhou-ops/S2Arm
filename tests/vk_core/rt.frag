#version 450
// 设备现编回归（乙）：不进离线库；输出 = push 常量换成 bgra 顺序，像素能证明画的是现编出来的这一支
// 多带一张贴图（乘 0 不改像素）：资源栏 2 项（推常量 / 组合贴图采样器），⑬ 核持久化的 .row 三项都在（10-31 Minecraft：落盘只剩第一项）
layout(push_constant) uniform P { vec4 c; } pc;
layout(set = 0, binding = 0) uniform sampler2D t;
layout(location = 0) out vec4 o;
void main() { o = pc.c.bgra + texelFetch(t, ivec2(0), 0) * 0.0; }
