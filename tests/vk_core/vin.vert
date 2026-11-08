#version 450
// ㉒ 顶点输入整型符号性：a / b / c 是有符号输入、游戏给 R16_UINT / R8_UINT / R32_UINT；d 是无符号输入、游戏给 R32_SINT。按位原样交给片元
layout(location = 0) in int a;
layout(location = 1) in int b;
layout(location = 2) in int c;
layout(location = 3) in uint d;
layout(location = 0) flat out uvec4 v;
void main() { vec2 p[3] = vec2[](vec2(-1, -1), vec2(3, -1), vec2(-1, 3)); gl_Position = vec4(p[gl_VertexIndex], 0.5, 1); v = uvec4(uint(a), uint(b), uint(c), d); }
