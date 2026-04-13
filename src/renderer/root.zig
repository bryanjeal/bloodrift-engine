// Renderer module - public exports.
//
// Exposes the backend-agnostic DOD render queue interface and the concrete
// VulkanBackend implementation.

pub const CameraData = @import("renderer.zig").CameraData;
pub const InstanceData = @import("renderer.zig").InstanceData;
pub const MaterialRange = @import("renderer.zig").MaterialRange;
pub const RenderQueue = @import("renderer.zig").RenderQueue;
pub const MaterialDef = @import("renderer.zig").MaterialDef;
pub const Renderer = @import("renderer.zig").Renderer;
pub const VulkanBackend = @import("vulkan/root.zig").VulkanBackend;
