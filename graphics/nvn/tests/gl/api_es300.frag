#version 300 es
precision mediump float;
in vec3 vCol;
uniform vec4 uTint;
out vec4 oColor;
void main() { oColor = vec4(vCol, 1.0) * uTint; }
