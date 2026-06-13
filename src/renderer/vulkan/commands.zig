// Vulkan command pool, command buffers, framebuffers, and synchronization.
//
// Owns: command pool, command buffer array, framebuffer array, sync primitives.
// Callers must call deinit() to release resources.
//
// Synchronization architecture (spec-compliant, per Vulkan 1.3 §7.4, §30.6):
//
//   Acquire semaphores (per-frame-in-flight):
//     acquire_sem[frame % max_frames_in_flight]
//     Signaled by vkAcquireNextImageKHR, waited on by vkQueueSubmit.
//     Lifetime is same-frame (acquire→submit), so per-frame indexing is safe.
//     The fence for this frame slot was waited before acquire, guaranteeing
//     the semaphore is unsignaled.
//
//   Render-complete semaphores (per-swapchain-image):
//     render_sem[image_index]
//     Signaled by vkQueueSubmit, waited on by vkQueuePresentKHR.
//     Lifetime is cross-frame: submit signals it, present (which may be
//     deferred by the presentation engine) consumes it. Different swapchain
//     images have independent present timelines, so each image needs its own
//     semaphore. Per-frame indexing would cause a data race when the swapchain
//     image count > max_frames_in_flight: frame N and frame N+max_frames_in_flight
//     would reuse the same semaphore slot for different swapchain images, and
//     the present engine might not have consumed the signal yet (Vulkan 1.3
//     §7.4: a semaphore must be unsignaled before being signaled again).
//
//   Fences (per-frame-in-flight):
//     fences[frame % max_frames_in_flight]
//     CPU throttling: ensures the CPU does not get more than max_frames_in_flight
//     ahead of the GPU. Indexed by frame counter, NOT by swapchain image index.
//
//   Command buffers (per-swapchain-image):
//     buffers[image_index]
//     Records draws into that image's framebuffer. One command buffer per
//     swapchain image so each image has dedicated recording state.
//
//   Framebuffers (per-swapchain-image):
//     framebuffers[image_index]
//     One per swapchain image view. Already correct before this fix.
//
//   In-flight frame data (uniforms, staging buffers):
//     Indexed by frame % max_frames_in_flight — CPU-owned between beginFrame
//     and the fence signal, independent of which swapchain image they target.

const std = @import("std");
const vk = @import("vulkan");
const pipeline_mod = @import("pipeline.zig");
const swapchain_mod = @import("swapchain.zig");

// ============================================================================
// Constants
// ============================================================================

/// Maximum number of frames the CPU may submit ahead of the GPU.
/// Controls input latency (2 = at most one frame of CPU work queued).
/// Independent of swapchain image count — fences and acquire semaphores are
/// indexed by frame counter, not by swapchain image index.
pub const max_frames_in_flight: u32 = 2;

// ============================================================================
// Types
// ============================================================================

pub const CommandState = struct {
    pool: vk.CommandPool,

    /// One command buffer per swapchain image.
    /// Indexed by the image index from vkAcquireNextImageKHR.
    buffers: []vk.CommandBuffer,

    /// One framebuffer per swapchain image view.
    framebuffers: []vk.Framebuffer,

    /// Per-frame-in-flight acquire semaphores.
    /// Signaled by vkAcquireNextImageKHR, waited on by vkQueueSubmit.
    /// Indexed by frame_counter % max_frames_in_flight.
    acquire_sem: [max_frames_in_flight]vk.Semaphore,

    /// Per-swapchain-image render-complete semaphores.
    /// Signaled by vkQueueSubmit, waited on by vkQueuePresentKHR.
    /// Indexed by the image index from vkAcquireNextImageKHR.
    render_sem: []vk.Semaphore,

    /// Per-frame-in-flight fences for CPU throttling.
    /// Indexed by frame_counter % max_frames_in_flight.
    fences: [max_frames_in_flight]vk.Fence,

    image_count: u32,
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
    const image_count: u32 = @intCast(sc.image_views.len);

    const pool = try vkd.createCommandPool(device, &.{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = graphics_family,
    }, null);
    errdefer vkd.destroyCommandPool(device, pool, null);

    // Allocate one command buffer per swapchain image.
    const buffers = try allocator.alloc(vk.CommandBuffer, image_count);
    errdefer allocator.free(buffers);
    try vkd.allocateCommandBuffers(device, &.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = image_count,
    }, buffers.ptr);

    const framebuffers = try createFramebuffers(vkd, device, sc, pip, allocator);
    errdefer {
        for (framebuffers) |fb| vkd.destroyFramebuffer(device, fb, null);
        allocator.free(framebuffers);
    }

    const acquire_sem = try createAcquireSemaphores(vkd, device);
    errdefer destroyAcquireSemaphores(&acquire_sem, vkd, device);

    const render_sem = try createRenderSemaphores(vkd, device, image_count, allocator);
    errdefer destroyRenderSemaphores(render_sem, vkd, device, allocator);

    const fences = try createFences(vkd, device);
    errdefer destroyFences(&fences, vkd, device);

    return .{
        .pool = pool,
        .buffers = buffers,
        .framebuffers = framebuffers,
        .acquire_sem = acquire_sem,
        .render_sem = render_sem,
        .fences = fences,
        .image_count = image_count,
        .allocator = allocator,
    };
}

pub fn deinit(state: *CommandState, vkd: vk.DeviceWrapper, device: vk.Device) void {
    destroyRenderSemaphores(state.render_sem, vkd, device, state.allocator);
    destroyAcquireSemaphores(&state.acquire_sem, vkd, device);
    destroyFences(&state.fences, vkd, device);
    for (state.framebuffers) |fb| vkd.destroyFramebuffer(device, fb, null);
    state.allocator.free(state.framebuffers);
    state.allocator.free(state.buffers);
    vkd.destroyCommandPool(device, state.pool, null);
    state.* = undefined;
}

/// Recreate per-swapchain-image resources after a swapchain resize.
/// Destroys old render semaphores + framebuffers + command buffers,
/// allocates new ones matching the new swapchain's image count.
/// Acquire semaphores and fences are NOT recreated (they are per-frame).
pub fn recreateForSwapchain(
    state: *CommandState,
    vkd: vk.DeviceWrapper,
    device: vk.Device,
    sc: *const swapchain_mod.SwapchainState,
    pip: *const pipeline_mod.PipelineState,
) !void {
    const new_image_count: u32 = @intCast(sc.image_views.len);

    // Destroy old per-image resources.
    destroyRenderSemaphores(state.render_sem, vkd, device, state.allocator);
    for (state.framebuffers) |fb| vkd.destroyFramebuffer(device, fb, null);
    state.allocator.free(state.framebuffers);

    // Reallocate command buffers for the new image count.
    try vkd.resetCommandPool(device, state.pool, .{});
    state.allocator.free(state.buffers);
    state.buffers = try state.allocator.alloc(vk.CommandBuffer, new_image_count);
    errdefer state.allocator.free(state.buffers);
    try vkd.allocateCommandBuffers(device, &.{
        .command_pool = state.pool,
        .level = .primary,
        .command_buffer_count = new_image_count,
    }, state.buffers.ptr);

    // Create new render semaphores and framebuffers.
    state.render_sem = try createRenderSemaphores(vkd, device, new_image_count, state.allocator);
    errdefer destroyRenderSemaphores(state.render_sem, vkd, device, state.allocator);

    state.framebuffers = try createFramebuffers(vkd, device, sc, pip, state.allocator);
    state.image_count = new_image_count;
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

fn createAcquireSemaphores(
    vkd: vk.DeviceWrapper,
    device: vk.Device,
) ![max_frames_in_flight]vk.Semaphore {
    var sem: [max_frames_in_flight]vk.Semaphore = undefined;
    var created: u32 = 0;
    errdefer for (sem[0..created]) |s| vkd.destroySemaphore(device, s, null);
    for (&sem) |*s| {
        s.* = try vkd.createSemaphore(device, &.{}, null);
        created += 1;
    }
    return sem;
}

fn destroyAcquireSemaphores(
    sem: *const [max_frames_in_flight]vk.Semaphore,
    vkd: vk.DeviceWrapper,
    device: vk.Device,
) void {
    for (sem) |s| vkd.destroySemaphore(device, s, null);
}

fn createRenderSemaphores(
    vkd: vk.DeviceWrapper,
    device: vk.Device,
    count: u32,
    allocator: std.mem.Allocator,
) ![]vk.Semaphore {
    const sem = try allocator.alloc(vk.Semaphore, count);
    errdefer allocator.free(sem);
    var created: u32 = 0;
    errdefer for (sem[0..created]) |s| vkd.destroySemaphore(device, s, null);
    for (sem) |*s| {
        s.* = try vkd.createSemaphore(device, &.{}, null);
        created += 1;
    }
    return sem;
}

fn destroyRenderSemaphores(
    sem: []vk.Semaphore,
    vkd: vk.DeviceWrapper,
    device: vk.Device,
    allocator: std.mem.Allocator,
) void {
    for (sem) |s| vkd.destroySemaphore(device, s, null);
    allocator.free(sem);
}

fn createFences(
    vkd: vk.DeviceWrapper,
    device: vk.Device,
) ![max_frames_in_flight]vk.Fence {
    var fences: [max_frames_in_flight]vk.Fence = undefined;
    var created: u32 = 0;
    errdefer for (fences[0..created]) |f| vkd.destroyFence(device, f, null);
    for (&fences) |*f| {
        // Start signaled so the first frame doesn't wait forever.
        f.* = try vkd.createFence(device, &.{ .flags = .{ .signaled_bit = true } }, null);
        created += 1;
    }
    return fences;
}

fn destroyFences(
    fences: *const [max_frames_in_flight]vk.Fence,
    vkd: vk.DeviceWrapper,
    device: vk.Device,
) void {
    for (fences) |f| vkd.destroyFence(device, f, null);
}
