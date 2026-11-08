#version 300 es
in vec2 aPos;
in vec3 aCol;
uniform vec2 uOff;
out vec3 vCol;
void main() { vCol = aCol; gl_Position = vec4(aPos + uOff, 0.0, 1.0); }
