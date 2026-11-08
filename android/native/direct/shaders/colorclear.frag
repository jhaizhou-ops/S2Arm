#version 450
// 部分颜色通道清除：输出清除色，实际写入通道由 VkPipelineColorBlendAttachmentState::colorWriteMask 限制。
layout(push_constant) uniform PC { vec4 color; } pc;
layout(location = 0) out vec4 o;
void main() { o = pc.color; }
