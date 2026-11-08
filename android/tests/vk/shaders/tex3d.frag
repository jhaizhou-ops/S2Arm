#version 450
layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 oColor;
layout(set = 0, binding = 0) uniform texture3D uTex;
layout(set = 0, binding = 1) uniform sampler uSmp;
void main() {
    vec2 uv = clamp(vUV, 0.0, 0.999);
    int s = int(uv.y * 2.0) * 2 + int(uv.x * 2.0);
    oColor = texture(sampler3D(uTex, uSmp), vec3(fract(uv * 2.0), (float(s) + 0.5) / 4.0));
}
