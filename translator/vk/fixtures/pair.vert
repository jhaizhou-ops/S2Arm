#version 450
layout(location = 0) in vec4 source_position;
layout(location = 0) out vec4 partial_value;
layout(location = 1) out float untouched_scalar;
void position_helper() { gl_Position = source_position; }
void main() {
    vec4 local_value = source_position;
    position_helper();
    partial_value.xyz = local_value.xyz;
    if (source_position.x < 0.0) { return; }
    untouched_scalar = 7.0;
}
