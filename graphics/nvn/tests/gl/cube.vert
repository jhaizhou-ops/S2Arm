#version 320 es
in vec2 aPos;
in vec4 aAdd;
uniform vec2 uOff;
uniform vec2 uScale;
out vec4 vAdd;
void main() {
    vAdd = aAdd;
    gl_Position = vec4(aPos * uScale + uOff, 0.0, 1.0);
}
