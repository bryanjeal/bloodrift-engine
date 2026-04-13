// Vulkan render pass and graphics pipeline.
//
// Owns: VkRenderPass (shared across all materials).
// Material pipelines are created at init via createMaterialPipeline().
// Shader SPIR-V is loaded once during init from pre-loaded []const u8 slices
// (no disk I/O in the render loop).

const std = @import("std");
const vk = @import("vulkan");

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
) !PipelineState {
    const render_pass = try createRenderPass(vkd, device, swapchain_format);
    errdefer vkd.destroyRenderPass(device, render_pass, null);
    // Placeholder layout and pipeline for the render pass owner.
    // Material pipelines are created separately via createMaterialPipeline().
    const push_range = vk.PushConstantRange{
        .stage_flags = .{ .vertex_bit = true },
        .offset = 0,
        .size = 64, // FramePushData (VP matrix only)
    };
    const layout = try vkd.createPipelineLayout(device, &.{
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @ptrCast(&push_range),
    }, null);
    errdefer vkd.destroyPipelineLayout(device, layout, null);
    // Create a placeholder pipeline that is never used for drawing.
    // It exists only so PipelineState has valid handles for the render pass owner.
    // The real pipelines are per-material, created by createMaterialPipeline().
    const handle = try vkd.createGraphicsPipeline(device, .null_handle, &.{
        .flags = .{},
        .stage_count = 0,
        .p_stages = null,
        .p_vertex_input_state = null,
        .p_input_assembly_state = null,
        .p_tessellation_state = null,
        .p_viewport_state = null,
        .p_rasterization_state = null,
        .p_multisample_state = null,
        .p_depth_stencil_state = null,
        .p_color_blend_state = null,
        .p_dynamic_state = null,
        .layout = layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    }, null) catch |err| switch (err) {
        error.invalid_shader => return error.PlaceholderPipelineFailed,
        else => |e| return e,
    };
    return .{ .render_pass = render_pass, .layout = layout, .handle = handle };
}

pub fn deinit(state: *PipelineState, vkd: vk.DeviceWrapper, device: vk.Device) void {
    vkd.destroyPipeline(device, state.handle, null);
    vkd.destroyPipelineLayout(device, state.layout, null);
    vkd.destroyRenderPass(device, state.render_pass, null);
    state.* = undefined;
}

/// Create a material pipeline from pre-loaded SPIR-V byte slices.
/// `vertex_spv` and `fragment_spv` are []const u8 slices already in memory
/// (loaded at init time from @embedFile, VFS, or .pak archive).
/// `blended` enables alpha blending for transparent materials.
/// `pipeline_layout` must include the SSBO descriptor set layout and push constants.
/// Returns the created VkPipeline (caller owns it).
pub fn createMaterialPipeline(
    vkd: vk.DeviceWrapper,
    device: vk.Device,
    render_pass: vk.RenderPass,
    pipeline_layout: vk.PipelineLayout,
    extent: vk.Extent2D,
    vertex_spv: []const u8,
    fragment_spv: []const u8,
    blended: bool,
) !vk.Pipeline {
    // Align SPIR-V bytes for Vulkan (requires u32 alignment).
    const vert_bytes align(@alignOf(u32)) = vertex_spv;
    const frag_bytes align(@alignOf(u32)) = fragment_spv;

    const vert_module = try createShaderModule(vkd, device, vert_bytes);
    defer vkd.destroyShaderModule(device, vert_module, null);
    const frag_module = try createShaderModule(vkd, device, frag_bytes);
    defer vkd.destroyShaderModule(device, frag_module, null);

    return createGraphicsPipelineFromModules(
        vkd,
        device,
        render_pass,
        pipeline_layout,
        extent,
        vert_module,
        frag_module,
        blended,
    );
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

fn createGraphicsPipelineFromModules(
    vkd: vk.DeviceWrapper,
    device: vk.Device,
    render_pass: vk.RenderPass,
    layout: vk.PipelineLayout,
    extent: vk.Extent2D,
    vert_module: vk.ShaderModule,
    frag_module: vk.ShaderModule,
    blended: bool,
) !vk.Pipeline {
    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{ .stage = .{ .vertex_bit = true }, .module = vert_module, .p_name = "main" },
        .{ .stage = .{ .fragment_bit = true }, .module = frag_module, .p_name = "main" },
    };
    const vertex_binding = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = 2 * @sizeOf(f32), // vec2 position per vertex (unit quad)
        .input_rate = .vertex,
    };
    const vertex_attrib = vk.VertexInputAttributeDescription{
        .location = 0,
        .binding = 0,
        .format = .r32g32_sfloat,
        .offset = 0,
    };
    const vertex_input = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = @ptrCast(&vertex_binding),
        .vertex_attribute_description_count = 1,
        .p_vertex_attribute_descriptions = @ptrCast(&vertex_attrib),
    };
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
        // Back-face culling disabled - quad winding order has not been validated
        // against the isometric camera. Re-enable once winding is confirmed.
        .cull_mode = .{},
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
    // Blended materials use alpha blending; opaque materials write directly.
    const blend_attachment = vk.PipelineColorBlendAttachmentState{
        .blend_enable = if (blended) vk.TRUE else vk.FALSE,
        .src_color_blend_factor = if (blended) .src_alpha else .one,
        .dst_color_blend_factor = if (blended) .one_minus_src_alpha else .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = if (blended) .one else .one,
        .dst_alpha_blend_factor = if (blended) .one_minus_src_alpha else .zero,
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
    _ = try vkd.createGraphicsPipelines(device, .null_handle, 1, @ptrCast(&create_info), null, @ptrCast(&pipeline));
    return pipeline;
}
