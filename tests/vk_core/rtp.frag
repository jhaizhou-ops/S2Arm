#version 450
// ㉑ 等现编的管线：片元着色器不进离线库；输出 = push 常量换成 gbra 顺序，像素能证明补建用的是这一支
layout(push_constant) uniform P { vec4 c; } pc;
layout(location = 0) out vec4 o;
void main() { o = pc.c.gbra; }
