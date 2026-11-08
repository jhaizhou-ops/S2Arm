#version 320 es
precision highp float;
precision highp int;
uniform int uSel;
uniform ivec2 uI2;
uniform ivec3 uI3;
uniform ivec4 uI4;
uniform mat2 uM2;
uniform mat3 uM3;
out vec4 oColor;
void main() {
    vec4 c;
    if (uSel == 0) c = vec4(vec2(uI2), 0.0, 255.0) / 255.0;
    else if (uSel == 1) c = vec4(vec3(uI3), 255.0) / 255.0;
    else if (uSel == 2) c = vec4(uI4) / 255.0;
    else if (uSel == 3) c = vec4(uM2[0], uM2[1]);
    else if (uSel == 4) c = vec4(uM3[0], 1.0);
    else if (uSel == 5) c = vec4(uM3[1], 1.0);
    else c = vec4(uM3[2], 1.0);
    oColor = c;
}
