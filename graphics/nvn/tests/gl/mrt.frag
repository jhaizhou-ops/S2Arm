#version 320 es
precision highp float;
uniform vec4 uColors[8];
layout(location = 0) out vec4 o0;
layout(location = 1) out vec4 o1;
layout(location = 2) out vec4 o2;
layout(location = 3) out vec4 o3;
layout(location = 4) out vec4 o4;
layout(location = 5) out vec4 o5;
layout(location = 6) out vec4 o6;
layout(location = 7) out vec4 o7;
void main() {
    o0 = uColors[0]; o1 = uColors[1]; o2 = uColors[2]; o3 = uColors[3];
    o4 = uColors[4]; o5 = uColors[5]; o6 = uColors[6]; o7 = uColors[7];
}
