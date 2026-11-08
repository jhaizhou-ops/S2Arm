#version 320 es
precision highp float;
in vec2 vUV;
uniform sampler2D uTex;
out vec4 color;
void main() { color = texture(uTex, vUV); }
