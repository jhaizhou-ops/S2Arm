#version 450
layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 oColor;
layout(set = 0, binding = 0) uniform textureCubeArray uTex;
layout(set = 0, binding = 1) uniform sampler uSmp;
void main() {
    vec2 uv = clamp(vUV, 0.0, 0.999);
    int layer = int(uv.x * 2.0);
    oColor = texture(samplerCubeArray(uTex, uSmp), vec4(1,0,0,layer));
}
