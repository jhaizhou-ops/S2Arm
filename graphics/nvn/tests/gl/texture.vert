#version 320 es
in vec2 aPos;
uniform vec2 uOff;
uniform vec2 uScale;
uniform vec2 uUVScale;
uniform vec2 uUVOff;
out vec2 vUV;
void main() {
    vUV = (aPos + vec2(1.0)) * 0.5 * uUVScale + uUVOff;
    gl_Position = vec4(aPos * uScale + uOff, 0.0, 1.0);
}
