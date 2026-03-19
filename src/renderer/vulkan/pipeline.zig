// Vulkan render pass and graphics pipeline.
//
// Owns: VkRenderPass, VkPipelineLayout, VkPipeline.
// Shader SPIR-V is embedded at build time via anonymous imports.
// Callers must call deinit() to release resources.

const std = @import("std");
const vk = @import("vulkan");

// SPIR-V bytecode embedded by the build system.
// Aligned to u32 as required by Vulkan.
const vert_spv = @import("vert_spv");
const frag_spv = @import("frag_spv");

// ============================================================================
// Types
// ============================================================================

pub const PipelineState = struct {
    render_pass: vk.RenderPass,
    layout: vk.PipelineLayout,
    handle: vk.Pipeline,
};

// ============================================================================
// Init / Deinit
// ============================================================================

pub fn init(
    vkd: vk.DeviceWrapper,
    device: vk.Device,
    swapchain_format: vk.Format,
    extent: vk.Extent2D,
) !PipelineState {
    const render_pass = try createRenderPass(vkd, device, swapchain_format);
    errdefer vkd.destroyRenderPass(device, render_pass, null);
    const layout = try vkd.createPipelineLayout(device, &.{}, null);
    errdefer vkd.destroyPipelineLayout(device, layout, null);
    const handle = try createGraphicsPipeline(vkd, device, render_pass, layout, extent);
    return .{ .render_pass = render_pass, .layout = layout, .handle = handle };
}

pub fn deinit(state: *PipelineState, vkd: vk.DeviceWrapper, device: vk.Device) void {
    vkd.destroyPipeline(device, state.handle, null);
    vkd.destroyPipelineLayout(device, state.layout, null);
    vkd.destroyRenderPass(device, state.render_pass, null);
    state.* = undefined;
}

// ============================================================================
// Render pass
// ============================================================================

fn createRenderPass(
    vkd: vk.DeviceWrapper,
    device: vk.Device,
    format: vk.Format,
) !vk.RenderPass {
    const attachment = vk.AttachmentDescription{
        .format = format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };
    const color_ref = vk.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
    const subpass = vk.SubpassDescription{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_ref),
    };
    const dep = vk.SubpassDependency{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{ .color_attachment_output_bit = true },
        .dst_stage_mask = .{ .color_attachment_output_bit = true },
        .src_access_mask = .{},
        .dst_access_mask = .{ .color_attachment_write_bit = true },
    };
    return vkd.createRenderPass(device, &.{
        .attachment_count = 1,
        .p_attachments = @ptrCast(&attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
        .dependency_count = 1,
        .p_dependencies = @ptrCast(&dep),
    }, null);
}

// ============================================================================
// Shader module helpers
// ============================================================================

fn createShaderModule(vkd: vk.DeviceWrapper, device: vk.Device, code: []align(@alignOf(u32)) const u8) !vk.ShaderModule {
    std.debug.assert(code.len % @sizeOf(u32) == 0);
    return vkd.createShaderModule(device, &.{
        .code_size = code.len,
        .p_code = @ptrCast(code.ptr),
    }, null);
}

// ============================================================================
// Graphics pipeline
// ============================================================================

fn createGraphicsPipeline(
    vkd: vk.DeviceWrapper,
    device: vk.Device,
    render_pass: vk.RenderPass,
    layout: vk.PipelineLayout,
    extent: vk.Extent2D,
) !vk.Pipeline {
    const vert_bytes align(@alignOf(u32)) = vert_spv.bytes.*;
    const frag_bytes align(@alignOf(u32)) = frag_spv.bytes.*;

    const vert_module = try createShaderModule(vkd, device, &vert_bytes);
    defer vkd.destroyShaderModule(device, vert_module, null);
    const frag_module = try createShaderModule(vkd, device, &frag_bytes);
    defer vkd.destroyShaderModule(device, frag_module, null);

    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{ .stage = .{ .vertex_bit = true }, .module = vert_module, .p_name = "main" },
        .{ .stage = .{ .fragment_bit = true }, .module = frag_module, .p_name = "main" },
    };
    const vertex_input = vk.PipelineVertexInputStateCreateInfo{};
    const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = vk.FALSE,
    };
    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .min_depth = 0,
        .max_depth = 1,
    };
    const scissor = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
    const viewport_state = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .p_viewports = @ptrCast(&viewport),
        .scissor_count = 1,
        .p_scissors = @ptrCast(&scissor),
    };
    const rasterizer = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .cull_mode = .{ .back_bit = true },
        .front_face = .clockwise,
        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };
    const multisampling = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = vk.FALSE,
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
    };
    const blend_attachment = vk.PipelineColorBlendAttachmentState{
        .blend_enable = vk.FALSE,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };
    const color_blending = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = vk.FALSE,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&blend_attachment),
        .blend_constants = .{ 0, 0, 0, 0 },
    };
    const create_info = vk.GraphicsPipelineCreateInfo{
        .stage_count = stages.len,
        .p_stages = &stages,
        .p_vertex_input_state = &vertex_input,
        .p_input_assembly_state = &input_assembly,
        .p_viewport_state = &viewport_state,
        .p_rasterization_state = &rasterizer,
        .p_multisample_state = &multisampling,
        .p_color_blend_state = &color_blending,
        .layout = layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_index = -1,
    };
    var pipeline: vk.Pipeline = undefined;
    const result = try vkd.createGraphicsPipelines(device, .null_handle, 1, @ptrCast(&create_info), null, @ptrCast(&pipeline));
    _ = result;
    return pipeline;
}
