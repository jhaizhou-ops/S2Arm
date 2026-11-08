#version 320 es
in vec2 aPos;
in vec3 aCol;
in float aID;
flat out vec3 vCol;
void main() {
    vCol = gl_VertexID == int(aID) ? aCol : vec3(0.0);
    gl_Position = vec4(aPos, 0.0, 1.0);
}
