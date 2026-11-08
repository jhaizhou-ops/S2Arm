#version 320 es
in vec2 aPos;
in vec2 aOff;
in float aK;
out vec4 vCol;
void main() { vCol = vec4(aK, 0.0, 1.0, 1.0); gl_Position = vec4(aPos + aOff, 0.0, 1.0); }
