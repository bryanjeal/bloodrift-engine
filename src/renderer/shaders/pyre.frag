#version 450

// Pyre fragment shader - procedural fire (fbm-based).
// Single code path (no effect_type branching). Opacity at 0.6.

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in flat float frag_radius;
layout(location = 3) in flat float frag_time;
layout(location = 4) in flat float frag_intensity;

layout(location = 0) out vec4 out_color;

// --- Simplex 2D noise (Ashima Arts) ---
vec3 mod289(vec3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec2 mod289(vec2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec3 permute(vec3 x) { return mod289(((x * 34.0) + 1.0) * x); }

float snoise(vec2 v) {
    const vec4 C = vec4(0.211324865405187, 0.366025403784439,
                       -0.577350269189626, 0.024390243902439);
    vec2 i  = floor(v + dot(v, C.yy));
    vec2 x0 = v - i + dot(i, C.xx);
    vec2 i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    vec4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = mod289(i);
    vec3 p = permute(permute(i.y + vec3(0.0, i1.y, 1.0)) + i.x + vec3(0.0, i1.x, 1.0));
    vec3 m = max(0.5 - vec3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    vec3 x_ = 2.0 * fract(p * C.www) - 1.0;
    vec3 h = abs(x_) - 0.5;
    vec3 ox = floor(x_ + 0.5);
    vec3 a0 = x_ - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    vec3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

// Four-octave fbm for fire.
float fbm4(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    vec2 shift = vec2(100.0);
    for (int i = 0; i < 4; ++i) {
        v += a * snoise(p);
        p = p * 2.0 + shift;
        a *= 0.5;
    }
    return v;
}

void main() {
    float dist = length(frag_uv);

    // Discard fragments outside the unit circle.
    if (dist > 1.0) discard;

    float t = frag_time;

    // Rising distortion: scroll noise upward.
    vec2 fire_uv = frag_uv * 2.5;
    float n = fbm4(fire_uv + vec2(0.0, -t * 2.0));

    // Remap and sharpen for flickering tongues.
    n = smoothstep(0.0, 0.8, n * 0.5 + 0.5);

    // Fire color gradient: dark red at base -> bright orange at tips.
    float height = -frag_uv.y * 0.5 + 0.5; // 0=bottom, 1=top
    vec3 fire_low  = vec3(0.6, 0.1, 0.0);
    vec3 fire_mid  = vec3(1.0, 0.4, 0.0);
    vec3 fire_high = vec3(1.0, 0.8, 0.2);
    vec3 fire_color = mix(fire_low, fire_mid, smoothstep(0.0, 0.5, height));
    fire_color = mix(fire_color, fire_high, smoothstep(0.5, 1.0, height));

    // Blend with affinity color for variety (fire stays warm).
    fire_color = mix(fire_color, frag_color.rgb, 0.3);

    // Edge fade: circular falloff.
    float edge = 1.0 - smoothstep(0.3, 1.0, dist);

    float alpha = 0.6 * n * edge * frag_intensity;
    out_color = vec4(fire_color, alpha);
}
