#version 450

// Instanced entity fragment shader.
// Receives per-instance color and custom_data from vertex stage.

layout(location = 0) in vec4 frag_color;
layout(location = 1) flat in uint frag_custom_data;

layout(location = 0) out vec4 out_color;

void main() {
    out_color = frag_color;
}
