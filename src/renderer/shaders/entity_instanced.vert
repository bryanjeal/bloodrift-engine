#version 450

// Instanced entity vertex shader.
//
// Per-frame push constants (64 bytes, vertex stage only):
//   bytes 0-63: view-projection matrix (column-major)
//
// Per-instance data is read from SSBO binding 0 using gl_InstanceIndex.
// InstanceData layout (96 bytes, interleaved):
//   bytes  0-63: model matrix (column-major, mat4)
//   bytes 64-79: RGBA color (vec4)
//   bytes 80-83: material_id (u16) + custom_data (u16) packed as uint
//   bytes 84-95: padding

layout(push_constant) uniform PC {
    mat4 vp;
} pc;

struct InstanceData {
    mat4 transform;
    vec4 color;
    uint material_id_custom; // low16=material_id, high16=custom_data
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

layout(std430, set = 0, binding = 0) readonly buffer InstanceBuffer {
    InstanceData instances[];
} buf;

layout(location = 0) in vec2 pos;

layout(location = 0) out vec4 frag_color;
layout(location = 1) flat out uint frag_custom_data;

void main() {
    InstanceData inst = buf.instances[gl_InstanceIndex];
    vec3 world_pos = inst.transform[3].xyz; // translation column
    gl_Position = pc.vp * vec4(pos + world_pos.xy, world_pos.z, 1.0);
    frag_color = inst.color;
    frag_custom_data = inst.material_id_custom >> 16; // extract custom_data from high16
}
