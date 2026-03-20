// Renderer abstraction — backend-agnostic interface for the Blood Rift renderer.
//
// Follows the same fat-pointer/vtable pattern as engine/src/network/transport.zig.
// No Vulkan or backend-specific types cross this boundary.
//
// Design decisions referenced:
//   §3: Vulkan as first rendering backend, behind an abstraction layer

/// Per-frame camera data passed to beginFrame.
/// The view-projection matrix is column-major to match Vulkan/GLSL convention.
/// Obtain from Mat4f: @bitCast(mat4.cols)
pub const CameraData = struct {
    vp: [16]f32,
};

/// A single draw call submitted to the renderer.
pub const DrawCall = struct {
    vertex_count: u32,
    instance_count: u32 = 1,
    first_vertex: u32 = 0,
    first_instance: u32 = 0,
    /// Entity world-space position (x, y, z). Passed as push constant.
    position: [3]f32 = .{ 0, 0, 0 },
    /// RGBA linear color. Looked up from Renderable.color_id by the caller.
    color: [4]f32 = .{ 1, 1, 1, 1 },
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
        /// Record a draw call into the active command buffer.
        submit_draw_call_fn: *const fn (ptr: *anyopaque, dc: DrawCall) anyerror!void,
        /// End command recording and submit to the graphics queue.
        end_frame_fn: *const fn (ptr: *anyopaque) anyerror!void,
        /// Present the rendered frame to the window surface.
        present_fn: *const fn (ptr: *anyopaque) anyerror!void,
        /// Destroy all backend resources. Waits for GPU idle before releasing.
        deinit_fn: *const fn (ptr: *anyopaque) void,
    };

    pub fn beginFrame(self: Renderer, camera: CameraData) !void {
        return self.vtable.begin_frame_fn(self.ptr, camera);
    }

    pub fn submitDrawCall(self: Renderer, dc: DrawCall) !void {
        return self.vtable.submit_draw_call_fn(self.ptr, dc);
    }

    pub fn endFrame(self: Renderer) !void {
        return self.vtable.end_frame_fn(self.ptr);
    }

    pub fn present(self: Renderer) !void {
        return self.vtable.present_fn(self.ptr);
    }

    pub fn deinit(self: Renderer) void {
        self.vtable.deinit_fn(self.ptr);
    }
};
