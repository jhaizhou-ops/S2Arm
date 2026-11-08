// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#version 450
layout(location=0) out vec4 varying0;
void main() {
    vec2 p=vec2(float((gl_VertexIndex<<1)&2),float(gl_VertexIndex&2));
    gl_Position=vec4(p*2.0-1.0,0.0,1.0);
    varying0=vec4(0.25,0.5,0.75,1.0);
}
