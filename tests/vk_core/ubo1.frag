#version 450
// ㉓ 只读 set 0 的 binding 1（uniform 缓冲里的颜色）
layout(set = 0, binding = 1) uniform U { vec4 c; } u;
layout(location = 0) out vec4 o;
void main() { o = u.c; }
