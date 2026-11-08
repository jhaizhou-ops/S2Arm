#version 320 es
precision highp float;
in vec2 vUV;
uniform sampler2D uTex;
out vec4 color;
void main() {
    float depth = texture(uTex, vUV).r;
    color = vec4(depth, 0.0, 0.0, 1.0);
}
