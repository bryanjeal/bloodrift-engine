// Renderer abstraction - backend-agnostic DOD render queue interface.
//
// The engine renderer does not know about game entities, effects, or
// semantics. It receives a flat InstanceData[] sorted by material_id
// and issues instanced draw calls via SSBO. Zero game types cross this
// boundary. The game defines what material_id values mean.
//
// Design decisions referenced:
//   S3: Vulkan as first rendering backend, behind an abstraction layer
//   S33: DOD render queue, SSBO instancing, build-time material baking

const build_options = @import("build_options");

const selected_renderer = build_options.renderer;

/// Per-frame camera data. Pushed as a single push constant (64 bytes).
/// The view-projection matrix is column-major to match Vulkan/GLSL convention.
/// Obtain from Mat4f: @bitCast(mat4.cols)
pub const CameraData = extern struct {
    vp: [16]f32,
};

/// Per-instance data for the render queue. 96 bytes, 16-byte aligned.
///
/// The engine does not interpret material_id or custom_data. The game
/// assigns material_id values and each material's shader interprets
/// custom_data according to its own layout.
///
/// For ground effects: pack radius/time/intensity into unused transform
/// matrix fields (transform[0].w = radius, transform[1].w = time,
/// transform[2].w = intensity). The model matrix for a ground effect
/// is just translation + uniform scale, so 12 matrix floats are unused.
pub const InstanceData = extern struct {
    transform: [16]f32, // column-major model matrix
    color: [4]f32, // RGBA linear color
    material_id: u16, // pipeline/shader selector (game-assigned)
    custom_data: u16, // game-defined per-instance payload
    _pad: [2]u32 = .{ 0, 0 }, // alignment to 96 bytes / 16-byte boundary
};

/// A contiguous range of instances sharing the same material_id.
/// Produced by sorting InstanceData[] by material_id.
pub const MaterialRange = struct {
    material_id: u16,
    first_instance: u32,
    instance_count: u32,
};

/// Sorted instance data ready for GPU upload.
pub const RenderQueue = struct {
    instances: []const InstanceData,
    count: usize,
    ranges: []const MaterialRange,
    range_count: usize,
    camera: CameraData,
};

/// Material definition. Loaded once during engine initialization.
/// Shader byte-code is a pre-loaded []const u8 slice residing in memory.
/// The loading mechanism (@embedFile, VFS, .pak archive) is chosen at
/// init time and never touches disk during the render loop.
pub const MaterialDef = struct {
    material_id: u16,
    vertex_shader: ShaderPayload,
    fragment_shader: ShaderPayload,
    blend_enable: bool = false,

    const ShaderPayload = switch (selected_renderer) {
        .vulkan => []align(@alignOf(u32)) const u8, // SPIR-V bytecode must be u32-aligned for Vulkan.
        .webgpu => []const u8, // WGSL bytecode is UTF-8 text, can be unaligned.
        .opengl => [:0]const u8, // GLSL needs null-terminated UTF-8 string ([:0]const u8).
    };
};

/// Asserts at compile time that the provided type T perfectly matches
/// the required Renderer interface.
pub fn assertRendererInterface(comptime T: type) void {
    // If this is evaluated outside of a `comptime { }` block, kill the build.
    if (!@inComptime()) {
        @compileError("assertRendererInterface must only be called inside a comptime block!");
    }

    // By trying to assign the struct's functions to these explicitly
    // typed constants, the compiler will hard-stop if signatures mismatch.
    comptime {
        const beginFrame: *const fn (*T, CameraData) anyerror!void = &T.beginFrame;
        _ = beginFrame;

        const submitQueue: *const fn (*T, RenderQueue) anyerror!void = &T.submitQueue;
        _ = submitQueue;

        const endFrame: *const fn (*T) anyerror!void = &T.endFrame;
        _ = endFrame;

        const present: *const fn (*T) anyerror!void = &T.present;
        _ = present;

        const resize: *const fn (*T, u32, u32) anyerror!void = &T.resize;
        _ = resize;

        const deinit: *const fn (*T) void = &T.deinit;
        _ = deinit;
    }
}
