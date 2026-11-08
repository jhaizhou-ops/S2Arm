#version 320 es
precision highp float;
uniform highp sampler2DArray uArr;
uniform highp sampler3D uVol;
uniform int uSel;
uniform float uZ;
in vec2 vUV;
out vec4 oColor;
void main() { oColor = uSel == 0 ? texture(uArr, vec3(vUV, uZ)) : texture(uVol, vec3(vUV, uZ)); }
