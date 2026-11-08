#version 320 es
precision highp float;
uniform sampler2D uTex;
uniform float uLod;
uniform float uDepth;
out vec4 color;
void main() {
    vec4 c = textureLod(uTex, vec2(0.5), uLod);
    color = uDepth > 0.5 ? vec4(c.rrr, 1.0) : c;
}
