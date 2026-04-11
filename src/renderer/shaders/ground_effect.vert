#version 450

// Ground effect vertex shader - auras and pyres.
//
// Push constants (112 bytes):
//   bytes   0-63: view-projection matrix (column-major)
//   bytes  64-75: world-space position (xyz)
//   bytes  76-79: padding
//   bytes  80-95: RGBA color
//   bytes  96-99: radius (float)
//   bytes 100-103: elapsed time (float)
//   bytes 104-107: effect type (0=aura, 1=pyre)
//   bytes 108-111: intensity [0,1]

layout(push_constant) uniform PC {
    mat4 vp;
    vec3 model_pos;
    float _pad1;
    vec4 color;
    float radius;
    float time;
    float effect_type;
    float intensity;
} pc;

layout(location = 0) in vec2 pos;

layout(location = 0) out vec2 frag_uv;
layout(location = 1) out vec4 frag_color;
layout(location = 2) out flat float frag_radius;
layout(location = 3) out flat float frag_time;
layout(location = 4) out flat float frag_effect_type;
layout(location = 5) out flat float frag_intensity;

void main() {
    // Scale quad by radius so the fragment shader gets UV coords in [-1,1].
    vec2 world_offset = pos * pc.radius;
    gl_Position = pc.vp * vec4(world_offset + pc.model_pos.xy, pc.model_pos.z, 1.0);
    frag_uv = pos; // [-1, 1] range
    frag_color = pc.color;
    frag_radius = pc.radius;
    frag_time = pc.time;
    frag_effect_type = pc.effect_type;
    frag_intensity = pc.intensity;
}
