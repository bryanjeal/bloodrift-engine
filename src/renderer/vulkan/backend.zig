// Vulkan backend — implements the Renderer vtable.
//
// Owns all Vulkan state. SDL3 Vulkan surface is created here via @cImport;
// no SDL Vulkan types escape this file.
//
// Design decisions referenced:
//   §3: Vulkan first rendering backend; abstraction layer hides backend types

const std = @import("std");
const vk = @import("vulkan");
const zgui = @import("zgui");
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

// Unit quad: two triangles covering a 1×1 world-space square centred at origin.
// The VP matrix and model_pos push constant place it in screen space.
const QUAD_VERTS = [12]f32{
    -0.5, -0.5, 0.5, -0.5, 0.5,  0.5,
    -0.5, -0.5, 0.5, 0.5,  -0.5, 0.5,
};

// Push constant layout mirroring entity.vert (96 bytes, vertex stage only).
const PushData = extern struct {
    vp: [16]f32, // view-projection matrix (column-major), bytes 0–63
    model_pos: [3]f32, // entity world-space position, bytes 64–75
    _pad: f32 = 0, // padding, bytes 76–79
    color: [4]f32, // RGBA linear color, bytes 80–95
};

comptime {
    std.debug.assert(@sizeOf(PushData) == 96);
}

// Push constant layout for ground effects (112 bytes, vertex stage only).
const GroundPushData = extern struct {
    vp: [16]f32, // view-projection matrix (column-major), bytes 0–63
    model_pos: [3]f32, // effect world-space position, bytes 64–75
    _pad1: f32 = 0, // padding, bytes 76–79
    color: [4]f32, // RGBA linear color, bytes 80–95
    radius: f32, // ground effect radius, bytes 96–99
    time: f32, // elapsed seconds for animation, bytes 100–103
    effect_type: f32, // GroundEffectType int value, bytes 104–107
    intensity: f32 = 1.0, // visual intensity [0,1], bytes 108–111
};

comptime {
    std.debug.assert(@sizeOf(GroundPushData) == 112);
}

pub const VulkanBackend = struct {
    allocator: std.mem.Allocator,
    surface: vk.SurfaceKHR,
    instance: instance_mod.InstanceState,
    device: device_mod.DeviceState,
    swapchain: swapchain_mod.SwapchainState,
    pipeline: pipeline_mod.PipelineState,
    ground_pipeline: pipeline_mod.PipelineState,
    commands: commands_mod.CommandState,
    vertex_buffer: vk.Buffer,
    vertex_buffer_memory: vk.DeviceMemory,
    imgui_descriptor_pool: vk.DescriptorPool,
    // Per-frame state (valid between beginFrame and present).
    current_frame: u32,
    current_image: u32,
    current_vp: [16]f32,

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
        const ground_pip = try pipeline_mod.initGround(dev.vkd, dev.handle, pip.render_pass, sc.extent);
        errdefer {
            var gp_copy = ground_pip;
            pipeline_mod.deinitGround(&gp_copy, dev.vkd, dev.handle);
        }
        const cmds = try commands_mod.init(
            dev.vkd,
            dev.handle,
            dev.families.graphics,
            &sc,
            &pip,
            allocator,
        );
        errdefer {
            var cmds_copy = cmds;
            commands_mod.deinit(&cmds_copy, dev.vkd, dev.handle);
        }
        const vb = try createVertexBuffer(inst.vki, dev.vkd, dev.handle, dev.physical);
        const imgui_pool = try createImguiDescriptorPool(dev.vkd, dev.handle);
        errdefer dev.vkd.destroyDescriptorPool(dev.handle, imgui_pool, null);

        // Dear ImGui — SDL3 + Vulkan backend.
        // VK_NO_PROTOTYPES is set by zgui's build, so we must provide a function
        // loader before calling backend.init.
        zgui.init(allocator);
        const instance_ptr: ?*anyopaque = @ptrFromInt(@intFromEnum(inst.handle));
        _ = zgui.backend.loadFunctions(@bitCast(vk.API_VERSION_1_2), imguiVkLoader, instance_ptr);
        zgui.backend.init(.{
            .api_version = @bitCast(vk.API_VERSION_1_2),
            .instance = @ptrFromInt(@intFromEnum(inst.handle)),
            .physical_device = @ptrFromInt(@intFromEnum(dev.physical)),
            .device = @ptrFromInt(@intFromEnum(dev.handle)),
            .queue_family = dev.families.graphics,
            .queue = @ptrFromInt(@intFromEnum(dev.graphics_queue)),
            .descriptor_pool = @ptrFromInt(@intFromEnum(imgui_pool)),
            .render_pass = @ptrFromInt(@intFromEnum(pip.render_pass)),
            .min_image_count = commands_mod.MAX_FRAMES_IN_FLIGHT,
            .image_count = @intCast(sc.image_views.len),
        }, @ptrCast(window));

        return .{
            .allocator = allocator,
            .surface = surface,
            .instance = inst,
            .device = dev,
            .swapchain = sc,
            .pipeline = pip,
            .ground_pipeline = ground_pip,
            .commands = cmds,
            .vertex_buffer = vb.buffer,
            .vertex_buffer_memory = vb.memory,
            .imgui_descriptor_pool = imgui_pool,
            .current_frame = 0,
            .current_image = 0,
            .current_vp = [_]f32{0} ** 16,
        };
    }

    pub fn deinit(self: *VulkanBackend) void {
        _ = self.device.vkd.deviceWaitIdle(self.device.handle) catch {};
        zgui.backend.deinit();
        zgui.deinit();
        self.device.vkd.destroyDescriptorPool(self.device.handle, self.imgui_descriptor_pool, null);
        commands_mod.deinit(&self.commands, self.device.vkd, self.device.handle);
        pipeline_mod.deinit(&self.pipeline, self.device.vkd, self.device.handle);
        pipeline_mod.deinitGround(&self.ground_pipeline, self.device.vkd, self.device.handle);
        self.device.vkd.destroyBuffer(self.device.handle, self.vertex_buffer, null);
        self.device.vkd.freeMemory(self.device.handle, self.vertex_buffer_memory, null);
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

    pub fn beginFrame(self: *VulkanBackend, camera: renderer_mod.CameraData) !void {
        self.current_vp = camera.vp;
        // Start a new ImGui frame before any draw commands.
        zgui.backend.newFrame(self.swapchain.extent.width, self.swapchain.extent.height);
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
        const offset: vk.DeviceSize = 0;
        vkd.cmdBindVertexBuffers(self.commands.buffers[frame], 0, 1, @ptrCast(&self.vertex_buffer), @ptrCast(&offset));
    }

    pub fn submitDrawCall(self: *VulkanBackend, dc: renderer_mod.DrawCall) !void {
        std.debug.assert(dc.vertex_count > 0);
        const cmd = self.commands.buffers[self.current_frame];
        const push = PushData{
            .vp = self.current_vp,
            .model_pos = dc.position,
            .color = dc.color.toArray(),
        };
        self.device.vkd.cmdPushConstants(
            cmd,
            self.pipeline.layout,
            .{ .vertex_bit = true },
            0,
            @sizeOf(PushData),
            &push,
        );
        self.device.vkd.cmdDraw(cmd, dc.vertex_count, dc.instance_count, dc.first_vertex, dc.first_instance);
    }

    /// Submit a ground effect draw call using the blended pipeline.
    /// Binds the ground pipeline, pushes extended constants, draws a quad.
    pub fn submitGroundCall(self: *VulkanBackend, gc: renderer_mod.GroundCall) !void {
        const cmd = self.commands.buffers[self.current_frame];
        // Switch to the ground effect pipeline (blended, extended push constants).
        self.device.vkd.cmdBindPipeline(cmd, .graphics, self.ground_pipeline.handle);
        const offset: vk.DeviceSize = 0;
        self.device.vkd.cmdBindVertexBuffers(cmd, 0, 1, @ptrCast(&self.vertex_buffer), @ptrCast(&offset));
        const push = GroundPushData{
            .vp = self.current_vp,
            .model_pos = gc.position,
            .color = gc.color.toArray(),
            .radius = gc.radius,
            .time = gc.time,
            .effect_type = @floatFromInt(@intFromEnum(gc.effect_type)),
            .intensity = gc.intensity,
        };
        self.device.vkd.cmdPushConstants(
            cmd,
            self.ground_pipeline.layout,
            .{ .vertex_bit = true },
            0,
            @sizeOf(GroundPushData),
            &push,
        );
        self.device.vkd.cmdDraw(cmd, 6, 1, 0, 0);
        // Switch back to entity pipeline for subsequent draw calls.
        self.device.vkd.cmdBindPipeline(cmd, .graphics, self.pipeline.handle);
    }

    pub fn endFrame(self: *VulkanBackend) !void {
        const frame = self.current_frame;
        const vkd = self.device.vkd;
        const cmd = self.commands.buffers[frame];
        // Render ImGui draw data inside the render pass (after all game draws).
        zgui.backend.render(@ptrFromInt(@intFromEnum(cmd)));
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

    /// Recreate swapchain and framebuffers for a new window size.
    /// Called after the window is resized. Waits for GPU idle first.
    pub fn resize(self: *VulkanBackend, width: u32, height: u32) !void {
        std.debug.assert(width > 0 and height > 0);
        try self.device.vkd.deviceWaitIdle(self.device.handle);

        // Destroy old framebuffers (they depend on swapchain image views).
        for (self.commands.framebuffers) |fb| {
            self.device.vkd.destroyFramebuffer(self.device.handle, fb, null);
        }
        self.allocator.free(self.commands.framebuffers);

        // Destroy old swapchain (image views + VkSwapchainKHR).
        swapchain_mod.deinit(&self.swapchain, self.device.vkd, self.device.handle);

        // Create new swapchain at the new size.
        self.swapchain = try swapchain_mod.init(
            self.instance.vki,
            self.device.vkd,
            self.device.physical,
            self.device.handle,
            self.surface,
            self.device.families.graphics,
            self.device.families.present,
            width,
            height,
            self.allocator,
        );

        // Recreate framebuffers with the new swapchain image views.
        self.commands.framebuffers = try commands_mod.createFramebuffers(
            self.device.vkd,
            self.device.handle,
            &self.swapchain,
            &self.pipeline,
            self.allocator,
        );
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
// Dear ImGui helpers
// ============================================================================

/// Create a small descriptor pool for ImGui's font texture atlas.
fn createImguiDescriptorPool(vkd: vk.DeviceWrapper, device: vk.Device) !vk.DescriptorPool {
    const pool_size = vk.DescriptorPoolSize{
        .type = .combined_image_sampler,
        .descriptor_count = 1,
    };
    return vkd.createDescriptorPool(device, &.{
        .flags = .{ .free_descriptor_set_bit = true },
        .max_sets = 1,
        .pool_size_count = 1,
        .p_pool_sizes = @ptrCast(&pool_size),
    }, null);
}

/// Vulkan function loader shim for Dear ImGui (required because zgui uses
/// VK_NO_PROTOTYPES — Vulkan symbols are not statically linked).
/// user_data carries the VkInstance pointer; SDL provides the proc address.
fn imguiVkLoader(
    name: [*:0]const u8,
    user_data: ?*anyopaque,
) callconv(.c) ?*anyopaque {
    const raw = c.SDL_Vulkan_GetVkGetInstanceProcAddr() orelse return null;
    // vkGetInstanceProcAddr signature: fn(VkInstance, name) -> PFN_vkVoidFunction.
    // We treat both the instance and the return value as opaque pointers.
    const get_proc: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque = @ptrCast(raw);
    return get_proc(user_data, name);
}

// ============================================================================
// Vertex buffer helpers
// ============================================================================

/// Create a host-visible, host-coherent vertex buffer containing the unit quad.
fn createVertexBuffer(
    vki: vk.InstanceWrapper,
    vkd: vk.DeviceWrapper,
    device: vk.Device,
    physical: vk.PhysicalDevice,
) !struct { buffer: vk.Buffer, memory: vk.DeviceMemory } {
    const size: vk.DeviceSize = @sizeOf(@TypeOf(QUAD_VERTS));
    const buf = try vkd.createBuffer(device, &.{
        .size = size,
        .usage = .{ .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    errdefer vkd.destroyBuffer(device, buf, null);

    const mem_req = vkd.getBufferMemoryRequirements(device, buf);
    const mem_type = try findMemoryType(
        vki,
        physical,
        mem_req.memory_type_bits,
        .{ .host_visible_bit = true, .host_coherent_bit = true },
    );
    const mem = try vkd.allocateMemory(device, &.{
        .allocation_size = mem_req.size,
        .memory_type_index = mem_type,
    }, null);
    errdefer vkd.freeMemory(device, mem, null);

    try vkd.bindBufferMemory(device, buf, mem, 0);
    const raw_ptr = (try vkd.mapMemory(device, mem, 0, size, .{})) orelse
        return error.MapMemoryReturnedNull;
    const typed_ptr: [*]f32 = @ptrCast(@alignCast(raw_ptr));
    @memcpy(typed_ptr[0..QUAD_VERTS.len], &QUAD_VERTS);
    vkd.unmapMemory(device, mem);

    return .{ .buffer = buf, .memory = mem };
}

/// Find the first memory type index satisfying both the type filter and required flags.
fn findMemoryType(
    vki: vk.InstanceWrapper,
    physical: vk.PhysicalDevice,
    type_filter: u32,
    required_flags: vk.MemoryPropertyFlags,
) !u32 {
    const props = vki.getPhysicalDeviceMemoryProperties(physical);
    const required_u32: u32 = @bitCast(required_flags);
    for (0..props.memory_type_count) |i| {
        const bit: u32 = @as(u32, 1) << @intCast(i);
        if (type_filter & bit == 0) continue;
        const mem_flags_u32: u32 = @bitCast(props.memory_types[i].property_flags);
        if (mem_flags_u32 & required_u32 == required_u32) return @intCast(i);
    }
    return error.NoSuitableMemoryType;
}

// ============================================================================
// Vtable shims (C-style fn pointers → method calls)
// ============================================================================

const vtable = renderer_mod.Renderer.VTable{
    .begin_frame_fn = struct {
        fn f(ptr: *anyopaque, camera: renderer_mod.CameraData) anyerror!void {
            return @as(*VulkanBackend, @ptrCast(@alignCast(ptr))).beginFrame(camera);
        }
    }.f,
    .submit_draw_call_fn = struct {
        fn f(ptr: *anyopaque, dc: renderer_mod.DrawCall) anyerror!void {
            return @as(*VulkanBackend, @ptrCast(@alignCast(ptr))).submitDrawCall(dc);
        }
    }.f,
    .submit_ground_call_fn = struct {
        fn f(ptr: *anyopaque, gc: renderer_mod.GroundCall) anyerror!void {
            return @as(*VulkanBackend, @ptrCast(@alignCast(ptr))).submitGroundCall(gc);
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
    .resize_fn = struct {
        fn f(ptr: *anyopaque, width: u32, height: u32) anyerror!void {
            return @as(*VulkanBackend, @ptrCast(@alignCast(ptr))).resize(width, height);
        }
    }.f,
    .deinit_fn = struct {
        fn f(ptr: *anyopaque) void {
            @as(*VulkanBackend, @ptrCast(@alignCast(ptr))).deinit();
        }
    }.f,
};
