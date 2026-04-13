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
    vertex_spv: []const u8,
    fragment_spv: []const u8,
    blend_enable: bool = false,
};

/// Runtime vtable-based renderer interface.
///
/// Ownership: the backing memory for the concrete backend is owned by the
/// caller. The Renderer handle must not outlive it.
pub const Renderer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Acquire the next swapchain image and begin recording commands.
        /// camera contains the view-projection matrix for this frame.
        begin_frame_fn: *const fn (ptr: *anyopaque, camera: CameraData) anyerror!void,
        /// Submit a sorted render queue. The backend uploads instances to
        /// SSBO, binds per-material pipelines, and issues instanced draws.
        submit_queue_fn: *const fn (ptr: *anyopaque, queue: RenderQueue) anyerror!void,
        /// End command recording and submit to the graphics queue.
        end_frame_fn: *const fn (ptr: *anyopaque) anyerror!void,
        /// Present the rendered frame to the window surface.
        present_fn: *const fn (ptr: *anyopaque) anyerror!void,
        /// Recreate swapchain and framebuffers for the new window size.
        resize_fn: *const fn (ptr: *anyopaque, width: u32, height: u32) anyerror!void,
        /// Destroy all backend resources. Waits for GPU idle before releasing.
        deinit_fn: *const fn (ptr: *anyopaque) void,
    };

    pub fn beginFrame(self: Renderer, camera: CameraData) !void {
        return self.vtable.begin_frame_fn(self.ptr, camera);
    }

    pub fn submitQueue(self: Renderer, queue: RenderQueue) !void {
        return self.vtable.submit_queue_fn(self.ptr, queue);
    }

    pub fn endFrame(self: Renderer) !void {
        return self.vtable.end_frame_fn(self.ptr);
    }

    pub fn present(self: Renderer) !void {
        return self.vtable.present_fn(self.ptr);
    }

    pub fn resize(self: Renderer, width: u32, height: u32) !void {
        return self.vtable.resize_fn(self.ptr, width, height);
    }

    pub fn deinit(self: Renderer) void {
        self.vtable.deinit_fn(self.ptr);
    }
};
