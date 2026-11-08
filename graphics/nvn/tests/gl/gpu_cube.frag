#version 320 es
precision highp float;
uniform samplerCube uCube;
uniform vec3 uDir;
uniform float uLod;
uniform float uDepth;
out vec4 color;
void main() {
    vec4 c = textureLod(uCube, uDir, uLod);
    color = uDepth > 0.5 ? vec4(c.rrr, 1.0) : c;
}
