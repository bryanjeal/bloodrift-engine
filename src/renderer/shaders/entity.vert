#version 450

// Push constants layout (96 bytes, vertex stage only):
//   bytes  0–63: view-projection matrix (column-major)
//   bytes 64–75: entity world-space position (xyz)
//   bytes 76–79: padding
//   bytes 80–95: entity RGBA color

layout(push_constant) uniform PC {
    mat4 vp;
    vec3 model_pos;
    float _pad;
    vec4 color;
} pc;

layout(location = 0) in vec2 pos;

layout(location = 0) out vec4 frag_color;

void main() {
    gl_Position = pc.vp * vec4(pos + pc.model_pos.xy, pc.model_pos.z, 1.0);
    frag_color = pc.color;
}
