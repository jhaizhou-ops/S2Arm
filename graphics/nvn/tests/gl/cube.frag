#version 320 es
precision highp float;
in vec4 vAdd;
uniform samplerCube uCube;
uniform sampler2D uTex;
uniform vec3 uDir;
uniform float uUse2D;
uniform vec4 uBias[3];
out vec4 color;
void main() {
    vec4 c = uUse2D > 0.5 ? texture(uTex, vec2(0.5)) : texture(uCube, uDir);
    color = c + vAdd - vec4(0.0, 0.0, 0.0, 1.0) + uBias[2];
}
