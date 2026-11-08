#version 450
// 盖住整个视口的三角形
void main() { vec2 p[3] = vec2[](vec2(-1, -1), vec2(3, -1), vec2(-1, 3)); gl_Position = vec4(p[gl_VertexIndex], 0.5, 1); }
