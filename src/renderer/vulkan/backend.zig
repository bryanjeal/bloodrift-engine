// Vulkan backend — implements the Renderer vtable.
//
// Owns all Vulkan state. SDL3 Vulkan surface is created here via @cImport;
// no SDL Vulkan types escape this file.
//
// Design decisions referenced:
//   §3: Vulkan first rendering backend; abstraction layer hides backend types

const std = @import("std");
const vk = @import("vulkan");
const renderer_mod = @import("../renderer.zig");
const instance_mod = @import("instance.zig");
const device_mod = @import("device.zig");
const swapchain_mod = @import("swapchain.zig");
const pipeline_mod = @import("pipeline.zig");
const commands_mod = @import("commands.zig");

// SDL3 Vulkan functions — not exposed beyond this file.
const c = @cImport({
    @cInclude("SDL3/SDL_vulkan.h");
});

pub const VulkanBackend = struct {
    allocator: std.mem.Allocator,
    surface: vk.SurfaceKHR,
    instance: instance_mod.InstanceState,
    device: device_mod.DeviceState,
    swapchain: swapchain_mod.SwapchainState,
    pipeline: pipeline_mod.PipelineState,
    commands: commands_mod.CommandState,
    // Per-frame state (valid between beginFrame and present).
    current_frame: u32,
    current_image: u32,

    /// Open a Vulkan context attached to an SDL3 window.
    ///
    /// On macOS, VK_ICD_FILENAMES must point to MoltenVK_icd.json before calling
    /// this function. Use `zig build run` which sets it automatically, or set the
    /// environment variable before launching the binary directly.
    pub fn init(allocator: std.mem.Allocator, window: anytype, width: u32, height: u32) !VulkanBackend {
        std.debug.assert(width > 0 and height > 0);
        const loader = try getSdlLoader();
        const sdl_exts = try getSdlExtensions(allocator);
        defer allocator.free(sdl_exts);
        const inst = try instance_mod.init(loader, sdl_exts, allocator);
        errdefer {
            var inst_copy = inst;
            instance_mod.deinit(&inst_copy);
        }
        const surface = try createSurface(window, inst.handle);
        errdefer inst.vki.destroySurfaceKHR(inst.handle, surface, null);
        const dev = try device_mod.init(inst.vki, inst.handle, surface, allocator);
        errdefer {
            var dev_copy = dev;
            device_mod.deinit(&dev_copy);
        }
        const sc = try swapchain_mod.init(
            inst.vki,
            dev.vkd,
            dev.physical,
            dev.handle,
            surface,
            dev.families.graphics,
            dev.families.present,
            width,
            height,
            allocator,
        );
        errdefer {
            var sc_copy = sc;
            swapchain_mod.deinit(&sc_copy, dev.vkd, dev.handle);
        }
        const pip = try pipeline_mod.init(dev.vkd, dev.handle, sc.format, sc.extent);
        errdefer {
            var pip_copy = pip;
            pipeline_mod.deinit(&pip_copy, dev.vkd, dev.handle);
        }
        const cmds = try commands_mod.init(
            dev.vkd,
            dev.handle,
            dev.families.graphics,
            &sc,
            &pip,
            allocator,
        );
        return .{
            .allocator = allocator,
            .surface = surface,
            .instance = inst,
            .device = dev,
            .swapchain = sc,
            .pipeline = pip,
            .commands = cmds,
            .current_frame = 0,
            .current_image = 0,
        };
    }

    pub fn deinit(self: *VulkanBackend) void {
        _ = self.device.vkd.deviceWaitIdle(self.device.handle) catch {};
        commands_mod.deinit(&self.commands, self.device.vkd, self.device.handle);
        pipeline_mod.deinit(&self.pipeline, self.device.vkd, self.device.handle);
        swapchain_mod.deinit(&self.swapchain, self.device.vkd, self.device.handle);
        device_mod.deinit(&self.device);
        self.instance.vki.destroySurfaceKHR(self.instance.handle, self.surface, null);
        instance_mod.deinit(&self.instance);
        self.* = undefined;
    }

    /// Return a vtable-based Renderer pointing at this backend.
    /// The returned Renderer must not outlive this VulkanBackend.
    pub fn renderer(self: *VulkanBackend) renderer_mod.Renderer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // =========================================================================
    // Frame interface
    // =========================================================================

    pub fn beginFrame(self: *VulkanBackend) !void {
        const frame = self.current_frame;
        const sync = &self.commands.sync[frame];
        const dev = self.device.handle;
        const vkd = self.device.vkd;
        _ = try vkd.waitForFences(dev, 1, @ptrCast(&sync.in_flight), vk.TRUE, std.math.maxInt(u64));
        const acquire = try vkd.acquireNextImageKHR(dev, self.swapchain.handle, std.math.maxInt(u64), sync.image_available, .null_handle);
        self.current_image = acquire.image_index;
        try vkd.resetFences(dev, 1, @ptrCast(&sync.in_flight));
        try vkd.resetCommandBuffer(self.commands.buffers[frame], .{});
        try vkd.beginCommandBuffer(self.commands.buffers[frame], &.{ .flags = .{ .one_time_submit_bit = true } });
        const clear = vk.ClearValue{ .color = .{ .float_32 = .{ 0.05, 0.05, 0.05, 1.0 } } };
        vkd.cmdBeginRenderPass(self.commands.buffers[frame], &.{
            .render_pass = self.pipeline.render_pass,
            .framebuffer = self.commands.framebuffers[self.current_image],
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swapchain.extent },
            .clear_value_count = 1,
            .p_clear_values = @ptrCast(&clear),
        }, .@"inline");
        vkd.cmdBindPipeline(self.commands.buffers[frame], .graphics, self.pipeline.handle);
    }

    pub fn submitDrawCall(self: *VulkanBackend, dc: renderer_mod.DrawCall) !void {
        std.debug.assert(dc.vertex_count > 0);
        self.device.vkd.cmdDraw(self.commands.buffers[self.current_frame], dc.vertex_count, dc.instance_count, dc.first_vertex, dc.first_instance);
    }

    pub fn endFrame(self: *VulkanBackend) !void {
        const frame = self.current_frame;
        const vkd = self.device.vkd;
        const cmd = self.commands.buffers[frame];
        vkd.cmdEndRenderPass(cmd);
        try vkd.endCommandBuffer(cmd);
        const wait_stage = vk.PipelineStageFlags{ .color_attachment_output_bit = true };
        const sync = &self.commands.sync[frame];
        try vkd.queueSubmit(self.device.graphics_queue, 1, &[_]vk.SubmitInfo{.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&sync.image_available),
            .p_wait_dst_stage_mask = @ptrCast(&wait_stage),
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&cmd),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&sync.render_finished),
        }}, sync.in_flight);
    }

    pub fn present(self: *VulkanBackend) !void {
        const sync = &self.commands.sync[self.current_frame];
        _ = try self.device.vkd.queuePresentKHR(self.device.present_queue, &.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&sync.render_finished),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.swapchain.handle),
            .p_image_indices = @ptrCast(&self.current_image),
        });
        self.current_frame = (self.current_frame + 1) % commands_mod.MAX_FRAMES_IN_FLIGHT;
    }

    // =========================================================================
    // SDL integration (macOS / cross-platform)
    // =========================================================================

    fn getSdlLoader() !vk.PfnGetInstanceProcAddr {
        const fn_ptr = c.SDL_Vulkan_GetVkGetInstanceProcAddr() orelse return error.VkGetProcAddrNull;
        return @ptrCast(fn_ptr);
    }

    fn getSdlExtensions(allocator: std.mem.Allocator) ![][*:0]const u8 {
        var count: u32 = 0;
        const ptr = c.SDL_Vulkan_GetInstanceExtensions(&count) orelse return error.SdlExtensionsNull;
        const exts = try allocator.alloc([*:0]const u8, count);
        for (ptr[0..count], exts) |src, *dst| dst.* = src;
        return exts;
    }

    fn createSurface(window: anytype, instance: vk.Instance) !vk.SurfaceKHR {
        const c_window: *c.SDL_Window = @ptrCast(window);
        const c_instance: c.VkInstance = @ptrFromInt(@intFromEnum(instance));
        var raw_surface: c.VkSurfaceKHR = undefined;
        if (!c.SDL_Vulkan_CreateSurface(c_window, c_instance, null, &raw_surface)) {
            return error.SurfaceCreationFailed;
        }
        return @enumFromInt(@intFromPtr(raw_surface));
    }
};

// ============================================================================
// Vtable shims (C-style fn pointers → method calls)
// ============================================================================

const vtable = renderer_mod.Renderer.VTable{
    .begin_frame_fn = struct {
        fn f(ptr: *anyopaque) anyerror!void {
            return @as(*VulkanBackend, @ptrCast(@alignCast(ptr))).beginFrame();
        }
    }.f,
    .submit_draw_call_fn = struct {
        fn f(ptr: *anyopaque, dc: renderer_mod.DrawCall) anyerror!void {
            return @as(*VulkanBackend, @ptrCast(@alignCast(ptr))).submitDrawCall(dc);
        }
    }.f,
    .end_frame_fn = struct {
        fn f(ptr: *anyopaque) anyerror!void {
            return @as(*VulkanBackend, @ptrCast(@alignCast(ptr))).endFrame();
        }
    }.f,
    .present_fn = struct {
        fn f(ptr: *anyopaque) anyerror!void {
            return @as(*VulkanBackend, @ptrCast(@alignCast(ptr))).present();
        }
    }.f,
    .deinit_fn = struct {
        fn f(ptr: *anyopaque) void {
            @as(*VulkanBackend, @ptrCast(@alignCast(ptr))).deinit();
        }
    }.f,
};
