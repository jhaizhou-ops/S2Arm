#version 320 es
precision highp float;
precision highp sampler2DShadow;
in vec2 vUV;
uniform sampler2DShadow uShadow;
uniform float uRef;
out vec4 color;
void main() {
    float pass = texture(uShadow, vec3(vUV, uRef));
    color = vec4(pass, pass, pass, 1.0);
}
