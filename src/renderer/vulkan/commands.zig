// Vulkan command pool, command buffers, framebuffers, and synchronization.
//
// Owns: command pool, command buffer array, framebuffer array, sync primitives.
// Callers must call deinit() to release resources.

const std = @import("std");
const vk = @import("vulkan");
const pipeline_mod = @import("pipeline.zig");
const swapchain_mod = @import("swapchain.zig");

// ============================================================================
// Constants
// ============================================================================

/// Number of frames that can be in-flight simultaneously.
pub const MAX_FRAMES_IN_FLIGHT: u32 = 2;

// ============================================================================
// Types
// ============================================================================

pub const FrameSync = struct {
    image_available: vk.Semaphore,
    render_finished: vk.Semaphore,
    in_flight: vk.Fence,
};

pub const CommandState = struct {
    pool: vk.CommandPool,
    buffers: [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
    framebuffers: []vk.Framebuffer,
    sync: [MAX_FRAMES_IN_FLIGHT]FrameSync,
    allocator: std.mem.Allocator,
};

// ============================================================================
// Init / Deinit
// ============================================================================

pub fn init(
    vkd: vk.DeviceWrapper,
    device: vk.Device,
    graphics_family: u32,
    sc: *const swapchain_mod.SwapchainState,
    pip: *const pipeline_mod.PipelineState,
    allocator: std.mem.Allocator,
) !CommandState {
    const pool = try vkd.createCommandPool(device, &.{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = graphics_family,
    }, null);
    errdefer vkd.destroyCommandPool(device, pool, null);

    var buffers: [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer = undefined;
    try vkd.allocateCommandBuffers(device, &.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = MAX_FRAMES_IN_FLIGHT,
    }, &buffers);

    const framebuffers = try createFramebuffers(vkd, device, sc, pip, allocator);
    errdefer {
        for (framebuffers) |fb| vkd.destroyFramebuffer(device, fb, null);
        allocator.free(framebuffers);
    }

    const sync = try createSyncObjects(vkd, device);
    return .{
        .pool = pool,
        .buffers = buffers,
        .framebuffers = framebuffers,
        .sync = sync,
        .allocator = allocator,
    };
}

pub fn deinit(state: *CommandState, vkd: vk.DeviceWrapper, device: vk.Device) void {
    for (&state.sync) |*s| {
        vkd.destroySemaphore(device, s.image_available, null);
        vkd.destroySemaphore(device, s.render_finished, null);
        vkd.destroyFence(device, s.in_flight, null);
    }
    for (state.framebuffers) |fb| vkd.destroyFramebuffer(device, fb, null);
    state.allocator.free(state.framebuffers);
    vkd.destroyCommandPool(device, state.pool, null);
    state.* = undefined;
}

// ============================================================================
// Framebuffer creation
// ============================================================================

pub fn createFramebuffers(
    vkd: vk.DeviceWrapper,
    device: vk.Device,
    sc: *const swapchain_mod.SwapchainState,
    pip: *const pipeline_mod.PipelineState,
    allocator: std.mem.Allocator,
) ![]vk.Framebuffer {
    const fbs = try allocator.alloc(vk.Framebuffer, sc.image_views.len);
    errdefer allocator.free(fbs);
    var created: usize = 0;
    errdefer for (fbs[0..created]) |fb| vkd.destroyFramebuffer(device, fb, null);
    for (sc.image_views, fbs) |view, *fb| {
        fb.* = try vkd.createFramebuffer(device, &.{
            .render_pass = pip.render_pass,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&view),
            .width = sc.extent.width,
            .height = sc.extent.height,
            .layers = 1,
        }, null);
        created += 1;
    }
    return fbs;
}

// ============================================================================
// Synchronization primitives
// ============================================================================

fn createSyncObjects(vkd: vk.DeviceWrapper, device: vk.Device) ![MAX_FRAMES_IN_FLIGHT]FrameSync {
    var sync: [MAX_FRAMES_IN_FLIGHT]FrameSync = undefined;
    var created: u32 = 0;
    errdefer for (sync[0..created]) |*s| {
        vkd.destroySemaphore(device, s.image_available, null);
        vkd.destroySemaphore(device, s.render_finished, null);
        vkd.destroyFence(device, s.in_flight, null);
    };
    for (&sync) |*s| {
        s.image_available = try vkd.createSemaphore(device, &.{}, null);
        s.render_finished = try vkd.createSemaphore(device, &.{}, null);
        // Start signaled so the first frame doesn't wait forever.
        s.in_flight = try vkd.createFence(device, &.{ .flags = .{ .signaled_bit = true } }, null);
        created += 1;
    }
    return sync;
}
