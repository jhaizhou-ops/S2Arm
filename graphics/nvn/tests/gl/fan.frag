#version 320 es
precision mediump float;
flat in vec3 vCol;
out vec4 oColor;
void main() { oColor = vec4(vCol, 1.0); }
