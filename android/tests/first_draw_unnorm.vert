#version 450
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
void main(){const vec2 p[3]=vec2[3](vec2(-1,-1),vec2(3,-1),vec2(-1,3)); gl_Position=vec4(p[gl_VertexIndex],0,1);}
