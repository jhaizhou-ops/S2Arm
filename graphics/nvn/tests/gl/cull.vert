#version 320 es
in vec2 aPos;
in vec3 aCol;
uniform float uZ;
out vec3 vCol;
void main() { vCol = aCol; gl_Position = vec4(aPos, uZ, 1.0); gl_PointSize = 8.0; }
