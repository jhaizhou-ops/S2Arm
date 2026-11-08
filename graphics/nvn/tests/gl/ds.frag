#version 320 es
precision highp float;
uniform vec4 uColor;
layout(location = 0) out vec4 oColor;
void main() { oColor = uColor; }
