// Renderer module - public exports.
//
// Exposes the backend-agnostic DOD render queue interface and the concrete
// VulkanBackend implementation.
const build_options = @import("build_options");

const renderer_mod = @import("renderer.zig");
pub const CameraData = renderer_mod.CameraData;
pub const InstanceData = renderer_mod.InstanceData;
pub const MaterialRange = renderer_mod.MaterialRange;
pub const RenderQueue = renderer_mod.RenderQueue;
pub const MaterialDef = renderer_mod.MaterialDef;

// pull in the concrete renderer type selected at compile-time
const selected_renderer = build_options.renderer;
const VulkanBackend = @import("vulkan/root.zig").VulkanBackend;

/// The concrete renderer type mapped at compile-time.
/// All backend structs must implement the expected methods
/// (beginFrame, submitQueue, etc.) via Zig's duck-typing.
pub const Renderer = switch (build_options.renderer) {
    .vulkan => VulkanBackend,
    else => @compileError("Unsupported renderer backend"),
};

comptime {
    // Assert that the selected renderer implements the required interface.
    // If this fails, the error messages will point to the offending method(s).
    _ = renderer_mod.assertRendererInterface(Renderer);
}
