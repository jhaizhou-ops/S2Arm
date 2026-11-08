#version 450
layout(location = 0) out vec4 oColor;
layout(set = 0, binding = 0) uniform texture2D uTex[2];
layout(set = 0, binding = 1) uniform sampler uSmp;
void main() { oColor = texture(sampler2D(uTex[1], uSmp), vec2(0.5)); }
