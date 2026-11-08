#version 450
// ㉑ 等现编的管线：顶点着色器不进离线库（同 tri.vert 盖住整个视口，深度换成 0.25 让键不同）
void main() { vec2 p[3] = vec2[](vec2(-1, -1), vec2(3, -1), vec2(-1, 3)); gl_Position = vec4(p[gl_VertexIndex], 0.25, 1); }
