#version 320 es
in vec2 aPos;
uniform float uZ;
void main() { gl_Position = vec4(aPos, uZ, 1.0); }
