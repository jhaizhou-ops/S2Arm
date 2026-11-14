#version 450
layout(set=0, binding=0, std430) readonly buffer Empty { uint words[]; } emptySlot;
layout(location=0) out vec4 vColor;
void main() {
    vec2 p[3] = vec2[3](vec2(-1,-1), vec2(3,-1), vec2(-1,3));
    gl_Position = vec4(p[gl_VertexIndex], 0, 1);
    bool zero = emptySlot.words[0] == 0u && emptySlot.words[16383] == 0u;
    vColor = zero ? vec4(0,1,0,1) : vec4(1,0,0,1);
}
