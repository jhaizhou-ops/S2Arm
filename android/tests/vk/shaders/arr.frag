#version 450
layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 oColor;
layout(set = 0, binding = 0) uniform texture2DArray uTex;
layout(set = 0, binding = 1) uniform sampler uSmp;
void main() {
    vec2 uv = clamp(vUV, 0.0, 0.999);
    int ix = int(uv.x * 2.0), iy = int(uv.y * 2.0);
    int layer = iy * 2 + ix;
    oColor = texture(sampler2DArray(uTex, uSmp), vec3(fract(uv * 2.0), float(layer)));
}
