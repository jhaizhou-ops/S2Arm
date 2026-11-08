#version 450
layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 oColor;
layout(set = 0, binding = 0) uniform textureCube uTex;
layout(set = 0, binding = 1) uniform sampler uSmp;
void main() {
    vec2 uv = clamp(vUV, 0.0, 0.999);
    int f = int(uv.y * 2.0) * 3 + int(uv.x * 3.0);
    vec3 dir = f == 0 ? vec3(1,0,0) : f == 1 ? vec3(-1,0,0) : f == 2 ? vec3(0,1,0)
             : f == 3 ? vec3(0,-1,0) : f == 4 ? vec3(0,0,1) : vec3(0,0,-1);
    oColor = texture(samplerCube(uTex, uSmp), dir);
}
