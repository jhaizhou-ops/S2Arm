#version 300 es
precision mediump float;
uniform sampler2D tex[2];
in vec3 vCol;
out vec4 oColor;
void main() { vec4 a = texture(tex[0], vec2(0.5)); vec4 b = texture(tex[1], vec2(0.5)); oColor = gl_FragCoord.x < 32.0 ? a : b; }
