// Vulkan backend - implements the Renderer vtable with DOD render queue.
//
// Owns all Vulkan state. SDL3 Vulkan surface is created here via @cImport;
// no SDL Vulkan types escape this file.
//
// Architecture:
//   - Instance data uploaded to a host-visible SSBO each frame.
//   - Single push constant for VP matrix (shared across all instances).
//   - Per-material pipelines bound once; instanced draw per material range.
//   - Total draw calls = number of unique materials, not number of entities.
//
// Design decisions referenced:
//   S3: Vulkan first rendering backend; abstraction layer hides backend types
//   S33: DOD render queue, SSBO instancing, build-time material baking

const std = @import("std");
const vk = @import("vulkan");
const zgui = @import("zgui");
const renderer_mod = @import("../renderer.zig");
const instance_mod = @import("instance.zig");
const device_mod = @import("device.zig");
const swapchain_mod = @import("swapchain.zig");
const pipeline_mod = @import("pipeline.zig");
const commands_mod = @import("commands.zig");

// SDL3 Vulkan functions - not exposed beyond this file.
const c = @cImport({
    @cInclude("SDL3/SDL_vulkan.h");
});

// Unit quad: two triangles covering a 1x1 world-space square centred at origin.
// The VP matrix push constant and per-instance SSBO data place it in screen space.
const QUAD_VERTS = [12]f32{
    -0.5, -0.5, 0.5, -0.5, 0.5,  0.5,
    -0.5, -0.5, 0.5, 0.5,  -0.5, 0.5,
};

/// Maximum number of instances the SSBO can hold.
/// 10,000 instances * 96 bytes = 960 KB. Trivial for host-visible memory.
pub const MAX_INSTANCES: u32 = 10_000;

/// Maximum number of material pipelines that can be registered.
pub const MAX_MATERIALS: usize = 64;

/// SSBO push constant layout: VP matrix only (64 bytes, vertex stage).
const FramePushData = extern struct {
    vp: [16]f32, // view-projection matrix (column-major), bytes 0-63
};

comptime {
    std.debug.assert(@sizeOf(FramePushData) == 64);
}

pub const VulkanBackend = struct {
    allocator: std.mem.Allocator,
    surface: vk.SurfaceKHR,
    instance: instance_mod.InstanceState,
    device: device_mod.DeviceState,
    swapchain: swapchain_mod.SwapchainState,
    pipeline: pipeline_mod.PipelineState,
    commands: commands_mod.CommandState,
    vertex_buffer: vk.Buffer,
    vertex_buffer_memory: vk.DeviceMemory,
    imgui_descriptor_pool: vk.DescriptorPool,
    // Instance SSBO: host-visible buffer for per-instance data.
    instance_buffer: vk.Buffer,
    instance_buffer_memory: vk.DeviceMemory,
    instance_buffer_ptr: [*]u8, // persistently mapped pointer
    // Descriptor set for SSBO binding.
    descriptor_pool: vk.DescriptorPool,
    descriptor_set_layout: vk.DescriptorSetLayout,
    descriptor_set: vk.DescriptorSet,
    // Material pipelines: indexed by material_id (game-assigned u16).
    material_pipelines: [MAX_MATERIALS]vk.Pipeline,
    material_layouts: [MAX_MATERIALS]vk.PipelineLayout,
    material_count: usize,
    // Per-frame state (valid between beginFrame and present).
    current_frame: u32,
    current_image: u32,
    current_vp: [16]f32,

    /// Open a Vulkan context attached to an SDL3 window.
    ///
    /// On macOS, VK_ICD_FILENAMES must point to MoltenVK_icd.json before calling
    /// this function. Use `zig build run` which sets it automatically, or set the
    /// environment variable before launching the binary directly.
    ///
    /// `materials` is a slice of MaterialDef loaded by the game during its init
    /// phase (e.g. from @embedFile, VFS, or .pak). No disk I/O occurs here.
    pub fn init(
        allocator: std.mem.Allocator,
        window: anytype,
        width: u32,
        height: u32,
        materials: []const renderer_mod.MaterialDef,
    ) !VulkanBackend {
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
        const pip = try pipeline_mod.init(dev.vkd, dev.handle, sc.format);
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
        errdefer {
            var cmds_copy = cmds;
            commands_mod.deinit(&cmds_copy, dev.vkd, dev.handle);
        }
        const vb = try createVertexBuffer(inst.vki, dev.vkd, dev.handle, dev.physical);
        const imgui_pool = try createImguiDescriptorPool(dev.vkd, dev.handle);
        errdefer dev.vkd.destroyDescriptorPool(dev.handle, imgui_pool, null);

        // Create SSBO for instance data (host-visible, persistently mapped).
        const ssbo = try createInstanceBuffer(
            inst.vki,
            dev.vkd,
            dev.handle,
            dev.physical,
            MAX_INSTANCES * @sizeOf(renderer_mod.InstanceData),
        );
        errdefer {
            dev.vkd.destroyBuffer(dev.handle, ssbo.buffer, null);
            dev.vkd.freeMemory(dev.handle, ssbo.memory, null);
        }

        // Create descriptor set layout + pool + set for the SSBO.
        const ds = try createInstanceDescriptor(
            dev.vkd,
            dev.handle,
            ssbo.buffer,
        );
        errdefer {
            dev.vkd.destroyDescriptorSetLayout(dev.handle, ds.layout, null);
            dev.vkd.destroyDescriptorPool(dev.handle, ds.pool, null);
        }

        // Create per-material pipelines from the pre-loaded MaterialDef slice.
        var mat_pipelines: [MAX_MATERIALS]vk.Pipeline = undefined;
        var mat_layouts: [MAX_MATERIALS]vk.PipelineLayout = undefined;
        var mat_count: usize = 0;
        for (materials) |mat| {
            if (mat_count >= MAX_MATERIALS) break;
            const push_range = vk.PushConstantRange{
                .stage_flags = .{ .vertex_bit = true },
                .offset = 0,
                .size = @sizeOf(FramePushData),
            };
            const layout = try dev.vkd.createPipelineLayout(dev.handle, &.{
                .set_layout_count = 1,
                .p_set_layouts = @ptrCast(&ds.layout),
                .push_constant_range_count = 1,
                .p_push_constant_ranges = @ptrCast(&push_range),
            }, null);
            errdefer dev.vkd.destroyPipelineLayout(dev.handle, layout, null);
            const pipeline = try pipeline_mod.createMaterialPipeline(
                dev.vkd,
                dev.handle,
                pip.render_pass,
                layout,
                sc.extent,
                mat.vertex_spv,
                mat.fragment_spv,
                mat.blend_enable,
            );
            errdefer dev.vkd.destroyPipeline(dev.handle, pipeline, null);
            // Pipeline stored at the material_id index for O(1) lookup.
            std.debug.assert(mat.material_id < MAX_MATERIALS);
            mat_pipelines[mat.material_id] = pipeline;
            mat_layouts[mat.material_id] = layout;
            mat_count += 1;
        }

        // Dear ImGui - SDL3 + Vulkan backend.
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
            .commands = cmds,
            .vertex_buffer = vb.buffer,
            .vertex_buffer_memory = vb.memory,
            .imgui_descriptor_pool = imgui_pool,
            .instance_buffer = ssbo.buffer,
            .instance_buffer_memory = ssbo.memory,
            .instance_buffer_ptr = ssbo.ptr,
            .descriptor_pool = ds.pool,
            .descriptor_set_layout = ds.layout,
            .descriptor_set = ds.set,
            .material_pipelines = mat_pipelines,
            .material_layouts = mat_layouts,
            .material_count = mat_count,
            .current_frame = 0,
            .current_image = 0,
            .current_vp = [_]f32{0} ** 16,
        };
    }

    pub fn deinit(self: *VulkanBackend) void {
        _ = self.device.vkd.deviceWaitIdle(self.device.handle) catch {};
        zgui.backend.deinit();
        zgui.deinit();
        // Destroy material pipelines and layouts.
        for (0..self.material_count) |i| {
            self.device.vkd.destroyPipeline(self.device.handle, self.material_pipelines[i], null);
            self.device.vkd.destroyPipelineLayout(self.device.handle, self.material_layouts[i], null);
        }
        self.device.vkd.destroyDescriptorSetLayout(self.device.handle, self.descriptor_set_layout, null);
        self.device.vkd.destroyDescriptorPool(self.device.handle, self.descriptor_pool, null);
        self.device.vkd.destroyBuffer(self.device.handle, self.instance_buffer, null);
        self.device.vkd.unmapMemory(self.device.handle, self.instance_buffer_memory);
        self.device.vkd.freeMemory(self.device.handle, self.instance_buffer_memory, null);
        self.device.vkd.destroyDescriptorPool(self.device.handle, self.imgui_descriptor_pool, null);
        commands_mod.deinit(&self.commands, self.device.vkd, self.device.handle);
        pipeline_mod.deinit(&self.pipeline, self.device.vkd, self.device.handle);
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
        // Bind the shared vertex buffer (unit quad) once for the entire frame.
        const offset: vk.DeviceSize = 0;
        vkd.cmdBindVertexBuffers(self.commands.buffers[frame], 0, 1, @ptrCast(&self.vertex_buffer), @ptrCast(&offset));
        // Bind the instance SSBO descriptor set for the entire frame.
        vkd.cmdBindDescriptorSets(
            self.commands.buffers[frame],
            .graphics,
            // Use the first material's layout (all share the same set layout).
            self.material_layouts[0],
            0,
            1,
            @ptrCast(&self.descriptor_set),
            null,
        );
    }

    /// Submit a sorted render queue. Uploads instances to SSBO, pushes VP
    /// matrix once, then issues one instanced draw per material range.
    pub fn submitQueue(self: *VulkanBackend, queue: renderer_mod.RenderQueue) !void {
        if (queue.count == 0) return;
        const cmd = self.commands.buffers[self.current_frame];
        const vkd = self.device.vkd;
        const dev = self.device.handle;

        // Upload instance data to the persistently-mapped SSBO.
        const upload_size = queue.count * @sizeOf(renderer_mod.InstanceData);
        @memcpy(self.instance_buffer_ptr[0..upload_size], @as([*]const u8, @ptrCast(queue.instances.ptr))[0..upload_size]);
        // Flush for host-coherent memory (ensures GPU sees the writes).
        vkd.flushMappedMemoryRange(dev, &.{
            .memory = self.instance_buffer_memory,
            .offset = 0,
            .size = upload_size,
        }) catch {};

        // Push VP matrix as a single push constant.
        const push = FramePushData{ .vp = self.current_vp };
        // Push to first material's layout (all materials share the same push range).
        vkd.cmdPushConstants(
            cmd,
            self.material_layouts[0],
            .{ .vertex_bit = true },
            0,
            @sizeOf(FramePushData),
            &push,
        );

        // Draw each material range with its own pipeline.
        var prev_material: u16 = std.math.maxInt(u16);
        for (queue.ranges[0..queue.range_count]) |range| {
            std.debug.assert(range.material_id < MAX_MATERIALS);
            // Bind pipeline only when material changes (sorted data guarantees
            // each material range is contiguous).
            if (range.material_id != prev_material) {
                vkd.cmdBindPipeline(cmd, .graphics, self.material_pipelines[range.material_id]);
                prev_material = range.material_id;
            }
            vkd.cmdDraw(cmd, 6, range.instance_count, 0, range.first_instance);
        }
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
/// VK_NO_PROTOTYPES - Vulkan symbols are not statically linked).
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
// Buffer helpers
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

/// Create a host-visible SSBO for instance data. Persistently mapped for
/// zero-overhead uploads each frame (memcpy + flush).
fn createInstanceBuffer(
    vki: vk.InstanceWrapper,
    vkd: vk.DeviceWrapper,
    device: vk.Device,
    physical: vk.PhysicalDevice,
    size: vk.DeviceSize,
) !struct { buffer: vk.Buffer, memory: vk.DeviceMemory, ptr: [*]u8 } {
    const buf = try vkd.createBuffer(device, &.{
        .size = size,
        .usage = .{ .storage_buffer_bit = true },
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

    return .{ .buffer = buf, .memory = mem, .ptr = @ptrCast(@alignCast(raw_ptr)) };
}

/// Create descriptor set layout, pool, and set for the instance SSBO.
/// The SSBO is bound at set 0, binding 0 for all material pipelines.
fn createInstanceDescriptor(
    vkd: vk.DeviceWrapper,
    device: vk.Device,
    instance_buffer: vk.Buffer,
) !struct { layout: vk.DescriptorSetLayout, pool: vk.DescriptorPool, set: vk.DescriptorSet } {
    // Layout: one SSBO binding at set=0, binding=0.
    const binding = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
    };
    const layout = try vkd.createDescriptorSetLayout(device, &.{
        .binding_count = 1,
        .p_bindings = @ptrCast(&binding),
    }, null);
    errdefer vkd.destroyDescriptorSetLayout(device, layout, null);

    // Pool: one SSBO descriptor.
    const pool_size = vk.DescriptorPoolSize{
        .type = .storage_buffer,
        .descriptor_count = 1,
    };
    const pool = try vkd.createDescriptorPool(device, &.{
        .max_sets = 1,
        .pool_size_count = 1,
        .p_pool_sizes = @ptrCast(&pool_size),
    }, null);
    errdefer vkd.destroyDescriptorPool(device, pool, null);

    // Allocate the descriptor set.
    var set: vk.DescriptorSet = undefined;
    _ = try vkd.allocateDescriptorSets(device, &.{
        .descriptor_pool = pool,
        .descriptor_set_count = 1,
        .p_set_layouts = @ptrCast(&layout),
    }, @ptrCast(&set));

    // Write the SSBO buffer info into the descriptor set.
    const buf_info = vk.DescriptorBufferInfo{
        .buffer = instance_buffer,
        .offset = 0,
        .range = vk.WHOLE_SIZE,
    };
    vkd.updateDescriptorSets(device, 1, &[_]vk.WriteDescriptorSet{.{
        .dst_set = set,
        .dst_binding = 0,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .storage_buffer,
        .p_buffer_info = @ptrCast(&buf_info),
    }}, 0, null);

    return .{ .layout = layout, .pool = pool, .set = set };
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
// Vtable shims (C-style fn pointers -> method calls)
// ============================================================================

const vtable = renderer_mod.Renderer.VTable{
    .begin_frame_fn = struct {
        fn f(ptr: *anyopaque, camera: renderer_mod.CameraData) anyerror!void {
            return @as(*VulkanBackend, @ptrCast(@alignCast(ptr))).beginFrame(camera);
        }
    }.f,
    .submit_queue_fn = struct {
        fn f(ptr: *anyopaque, queue: renderer_mod.RenderQueue) anyerror!void {
            return @as(*VulkanBackend, @ptrCast(@alignCast(ptr))).submitQueue(queue);
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
