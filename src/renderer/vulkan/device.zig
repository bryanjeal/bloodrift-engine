// Vulkan physical and logical device selection.
//
// Owns: VkDevice, VkDeviceWrapper, queue handles.
// Callers must call deinit() to release resources.

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");

// ============================================================================
// Types
// ============================================================================

pub const QueueFamilyIndices = struct {
    graphics: u32,
    present: u32,
};

pub const DeviceState = struct {
    physical: vk.PhysicalDevice,
    properties: vk.PhysicalDeviceProperties,
    handle: vk.Device,
    vkd: vk.DeviceWrapper,
    graphics_queue: vk.Queue,
    present_queue: vk.Queue,
    families: QueueFamilyIndices,
};

// ============================================================================
// Init / Deinit
// ============================================================================

pub fn init(
    vki: vk.InstanceWrapper,
    instance: vk.Instance,
    surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
) !DeviceState {
    const physical = try selectPhysicalDevice(vki, instance, surface, allocator);
    const families = try findQueueFamilies(vki, physical, surface, allocator);
    const handle = try createLogicalDevice(vki, physical, families);
    const vkd = vk.DeviceWrapper.load(handle, vki.dispatch.vkGetDeviceProcAddr.?);
    const graphics_queue = vkd.getDeviceQueue(handle, families.graphics, 0);
    const present_queue = vkd.getDeviceQueue(handle, families.present, 0);

    return .{
        .physical = physical,
        .properties = vki.getPhysicalDeviceProperties(physical),
        .handle = handle,
        .vkd = vkd,
        .graphics_queue = graphics_queue,
        .present_queue = present_queue,
        .families = families,
    };
}

pub fn deinit(state: *DeviceState) void {
    state.vkd.destroyDevice(state.handle, null);
    state.* = undefined;
}

// ============================================================================
// Physical device selection
// ============================================================================

fn selectPhysicalDevice(
    vki: vk.InstanceWrapper,
    instance: vk.Instance,
    surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
) !vk.PhysicalDevice {
    const devices = try vki.enumeratePhysicalDevicesAlloc(instance, allocator);
    defer allocator.free(devices);
    std.debug.assert(devices.len > 0);
    for (devices) |device| {
        if (isDeviceSuitable(vki, device, surface, allocator)) return device;
    }
    return error.NoSuitableGpu;
}

fn isDeviceSuitable(
    vki: vk.InstanceWrapper,
    device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
) bool {
    _ = findQueueFamilies(vki, device, surface, allocator) catch return false;
    return checkSwapchainSupport(vki, device, surface, allocator);
}

fn checkSwapchainSupport(
    vki: vk.InstanceWrapper,
    device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
) bool {
    const formats = vki.getPhysicalDeviceSurfaceFormatsAllocKHR(device, surface, allocator) catch return false;
    defer allocator.free(formats);
    const modes = vki.getPhysicalDeviceSurfacePresentModesAllocKHR(device, surface, allocator) catch return false;
    defer allocator.free(modes);
    return formats.len > 0 and modes.len > 0;
}

// ============================================================================
// Queue family discovery
// ============================================================================

fn findQueueFamilies(
    vki: vk.InstanceWrapper,
    device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    allocator: std.mem.Allocator,
) !QueueFamilyIndices {
    const families = try vki.getPhysicalDeviceQueueFamilyPropertiesAlloc(device, allocator);
    defer allocator.free(families);

    var graphics: ?u32 = null;
    var present: ?u32 = null;

    for (families, 0..) |fam, i| {
        const idx: u32 = @intCast(i);
        if (fam.queue_flags.graphics_bit) graphics = idx;
        const supports_present = try vki.getPhysicalDeviceSurfaceSupportKHR(device, idx, surface);
        if (supports_present == vk.TRUE) present = idx;
        if (graphics != null and present != null) break;
    }
    return .{
        .graphics = graphics orelse return error.NoGraphicsQueue,
        .present = present orelse return error.NoPresentQueue,
    };
}

// ============================================================================
// Logical device creation
// ============================================================================

fn createLogicalDevice(
    vki: vk.InstanceWrapper,
    physical: vk.PhysicalDevice,
    families: QueueFamilyIndices,
) !vk.Device {
    const priority: f32 = 1.0;
    const same_family = families.graphics == families.present;
    const queue_infos: []const vk.DeviceQueueCreateInfo = if (same_family)
        &.{.{ .queue_family_index = families.graphics, .queue_count = 1, .p_queue_priorities = @ptrCast(&priority) }}
    else
        &.{
            .{ .queue_family_index = families.graphics, .queue_count = 1, .p_queue_priorities = @ptrCast(&priority) },
            .{ .queue_family_index = families.present, .queue_count = 1, .p_queue_priorities = @ptrCast(&priority) },
        };

    var ext_buf: [4][*:0]const u8 = undefined;
    var ext_count: u32 = 0;
    ext_buf[ext_count] = "VK_KHR_swapchain";
    ext_count += 1;
    if (builtin.os.tag == .macos) {
        ext_buf[ext_count] = "VK_KHR_portability_subset";
        ext_count += 1;
    }

    return vki.createDevice(physical, &.{
        .queue_create_info_count = @intCast(queue_infos.len),
        .p_queue_create_infos = queue_infos.ptr,
        .enabled_extension_count = ext_count,
        .pp_enabled_extension_names = &ext_buf,
    }, null);
}
