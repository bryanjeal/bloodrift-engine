// Vulkan instance creation and debug utilities.
//
// Owns: VkInstance, VkDebugUtilsMessengerEXT (debug builds only).
// Callers must call deinit() to release resources.

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");

// ============================================================================
// Types
// ============================================================================

pub const InstanceState = struct {
    vkb: vk.BaseWrapper,
    vki: vk.InstanceWrapper,
    handle: vk.Instance,
    debug_messenger: vk.DebugUtilsMessengerEXT,
};

// ============================================================================
// Init / Deinit
// ============================================================================

/// Create a Vulkan instance with the given extensions.
/// sdl_extensions must include the platform surface extension(s) from SDL3.
pub fn init(
    loader: vk.PfnGetInstanceProcAddr,
    sdl_extensions: [][*:0]const u8,
    allocator: std.mem.Allocator,
) !InstanceState {
    const vkb = vk.BaseWrapper.load(loader);
    const handle = try createInstance(vkb, sdl_extensions, allocator);
    errdefer {
        const vki_tmp = vk.InstanceWrapper.load(handle, loader);
        vki_tmp.destroyInstance(handle, null);
    }
    const vki = vk.InstanceWrapper.load(handle, vkb.dispatch.vkGetInstanceProcAddr.?);
    const debug_messenger = try createDebugMessenger(vki, handle);
    return .{
        .vkb = vkb,
        .vki = vki,
        .handle = handle,
        .debug_messenger = debug_messenger,
    };
}

pub fn deinit(state: *InstanceState) void {
    if (state.debug_messenger != .null_handle) {
        state.vki.destroyDebugUtilsMessengerEXT(state.handle, state.debug_messenger, null);
    }
    state.vki.destroyInstance(state.handle, null);
    state.* = undefined;
}

// ============================================================================
// Instance creation helpers
// ============================================================================

fn createInstance(
    vkb: vk.BaseWrapper,
    sdl_extensions: [][*:0]const u8,
    allocator: std.mem.Allocator,
) !vk.Instance {
    // Zig 0.15.2: ArrayList is unmanaged — allocator passed per call.
    var extensions = std.ArrayList([*:0]const u8){};
    defer extensions.deinit(allocator);
    try extensions.appendSlice(allocator, sdl_extensions);
    if (builtin.mode == .Debug) {
        try extensions.append(allocator, "VK_EXT_debug_utils");
    }
    // macOS/MoltenVK: must enumerate portability drivers.
    if (builtin.os.tag == .macos) {
        try extensions.append(allocator, "VK_KHR_portability_enumeration");
    }

    const layers: []const [*:0]const u8 = if (builtin.mode == .Debug)
        &.{"VK_LAYER_KHRONOS_validation"}
    else
        &.{};

    const flags: vk.InstanceCreateFlags = if (builtin.os.tag == .macos)
        .{ .enumerate_portability_bit_khr = true }
    else
        .{};

    return vkb.createInstance(&.{
        .p_application_info = &.{
            .p_application_name = "Blood Rift",
            .application_version = @bitCast(vk.makeApiVersion(0, 0, 7, 0)),
            .p_engine_name = "Blood Rift Engine",
            .engine_version = @bitCast(vk.makeApiVersion(0, 0, 7, 0)),
            .api_version = @bitCast(vk.API_VERSION_1_2),
        },
        .flags = flags,
        .enabled_layer_count = @intCast(layers.len),
        .pp_enabled_layer_names = layers.ptr,
        .enabled_extension_count = @intCast(extensions.items.len),
        .pp_enabled_extension_names = extensions.items.ptr,
    }, null);
}

// ============================================================================
// Debug messenger
// ============================================================================

fn createDebugMessenger(vki: vk.InstanceWrapper, instance: vk.Instance) !vk.DebugUtilsMessengerEXT {
    if (builtin.mode != .Debug) return .null_handle;
    return vki.createDebugUtilsMessengerEXT(instance, &.{
        .message_severity = .{
            .warning_bit_ext = true,
            .error_bit_ext = true,
        },
        .message_type = .{
            .general_bit_ext = true,
            .validation_bit_ext = true,
            .performance_bit_ext = true,
        },
        .pfn_user_callback = debugCallback,
    }, null);
}

fn debugCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    _: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    _: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    const msg = if (p_callback_data) |d| d.p_message else "(null)";
    if (severity.error_bit_ext) {
        std.debug.panic("Vulkan validation error: {s}", .{msg});
    }
    std.log.warn("Vulkan validation: {s}", .{msg});
    return vk.FALSE;
}
