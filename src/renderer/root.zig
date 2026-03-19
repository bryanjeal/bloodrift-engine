// Renderer module — public exports.
//
// Exposes the backend-agnostic Renderer interface and the concrete
// VulkanBackend implementation.

pub const Renderer = @import("renderer.zig").Renderer;
pub const DrawCall = @import("renderer.zig").DrawCall;
pub const VulkanBackend = @import("vulkan/root.zig").VulkanBackend;
