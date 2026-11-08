#version 450
layout(location = 0) flat out vec3 color;
void main() {
    int tile = gl_VertexIndex / 3;
    int v = gl_VertexIndex % 3;
    vec2 corners[3] = vec2[](vec2(-0.24, -0.24), vec2(0.24, -0.24), vec2(0.0, 0.24));
    vec2 center = vec2(float(tile % 3 - 1), float(tile / 3 - 1)) * (2.0 / 3.0);
    float z = 0.5;
    if (tile == 9) { center = vec2(-2.0 / 3.0, 0.0); z = 0.1; }
    gl_Position = vec4(center + corners[v], z, 1.0);
    color = vec3(gl_InstanceIndex % 3 == 1, gl_InstanceIndex % 3 == 2, gl_InstanceIndex % 3 == 0);
}
