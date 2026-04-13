#version 450

// Instanced aura vertex shader.
//
// Per-frame push constants (64 bytes):
//   bytes 0-63: view-projection matrix (column-major)
//
// Per-instance data from SSBO:
//   transform[3].xyz = world position
//   transform[0].w = radius
//   transform[1].w = elapsed time (seconds)
//   transform[2].w = intensity [0,1]
//   color = RGBA tint
//   custom_data (high16 of material_id_custom) = unused for aura

layout(push_constant) uniform PC {
    mat4 vp;
} pc;

struct InstanceData {
    mat4 transform;
    vec4 color;
    uint material_id_custom;
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

layout(std430, set = 0, binding = 0) readonly buffer InstanceBuffer {
    InstanceData instances[];
} buf;

layout(location = 0) in vec2 pos;

layout(location = 0) out vec2 frag_uv;
layout(location = 1) out vec4 frag_color;
layout(location = 2) out flat float frag_radius;
layout(location = 3) out flat float frag_time;
layout(location = 4) out flat float frag_intensity;

void main() {
    InstanceData inst = buf.instances[gl_InstanceIndex];
    vec3 world_pos = inst.transform[3].xyz;
    float radius = inst.transform[0].w;
    float time = inst.transform[1].w;
    float intensity = inst.transform[2].w;

    vec2 world_offset = pos * radius;
    gl_Position = pc.vp * vec4(world_offset + world_pos.xy, world_pos.z, 1.0);
    frag_uv = pos; // [-1, 1] range
    frag_color = inst.color;
    frag_radius = radius;
    frag_time = time;
    frag_intensity = intensity;
}
