const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Vulkan SDK path — used for vk.xml (code generation) and glslc (shader compilation).
    // Resolved from -Dvulkan-sdk=... option, then VULKAN_SDK env var, then a known default.
    const vulkan_sdk = b.option([]const u8, "vulkan-sdk", "Path to Vulkan SDK (e.g. ~/VulkanSDK/1.x.x/macOS)") orelse std.posix.getenv("VULKAN_SDK") orelse "/Users/bryanjeal/VulkanSDK/1.3.275.0/macOS";

    // Flecs ECS dependency.
    const zflecs = b.dependency("zflecs", .{
        .target = target,
        .optimize = optimize,
    });

    // SDL3 bindings dependency.
    const zsdl = b.dependency("zsdl", .{
        .target = target,
        .optimize = optimize,
    });

    // Vulkan bindings (generates idiomatic Zig from vk.xml at build time).
    const registry_path = std.fmt.allocPrint(b.allocator, "{s}/share/vulkan/registry/vk.xml", .{vulkan_sdk}) catch @panic("OOM");
    const vulkan_dep = b.dependency("vulkan", .{
        .registry = @as(std.Build.LazyPath, .{ .cwd_relative = registry_path }),
    });
    const vulkan_module = vulkan_dep.module("vulkan-zig");

    // Compile entity shaders to SPIR-V using glslc.
    const glslc_path = std.fmt.allocPrint(b.allocator, "{s}/bin/glslc", .{vulkan_sdk}) catch @panic("OOM");
    const vert_spv = compileShader(b, glslc_path, "src/renderer/shaders/entity.vert");
    const frag_spv = compileShader(b, glslc_path, "src/renderer/shaders/entity.frag");

    // Wrap each SPIR-V file in a tiny Zig module that exposes it via @embedFile.
    const shader_wf = b.addWriteFiles();
    const vert_wrapper = shader_wf.add("vert_spv.zig",
        \\pub const bytes = @embedFile("entity.vert.spv");
    );
    const frag_wrapper = shader_wf.add("frag_spv.zig",
        \\pub const bytes = @embedFile("entity.frag.spv");
    );
    _ = shader_wf.addCopyFile(vert_spv, "entity.vert.spv");
    _ = shader_wf.addCopyFile(frag_spv, "entity.frag.spv");

    const vert_module = b.createModule(.{ .root_source_file = vert_wrapper });
    const frag_module = b.createModule(.{ .root_source_file = frag_wrapper });

    // Expose the engine as a module for the parent build.
    const engine_module = b.addModule("engine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine_module.addImport("zflecs", zflecs.module("root"));
    engine_module.addImport("zsdl3", zsdl.module("zsdl3"));
    engine_module.addImport("vulkan", vulkan_module);
    engine_module.addImport("vert_spv", vert_module);
    engine_module.addImport("frag_spv", frag_module);
    addSdl3IncludePaths(engine_module, target.result.os.tag);

    // Engine tests.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("zflecs", zflecs.module("root"));
    test_module.addImport("zsdl3", zsdl.module("zsdl3"));
    test_module.addImport("vulkan", vulkan_module);
    test_module.addImport("vert_spv", vert_module);
    test_module.addImport("frag_spv", frag_module);
    addSdl3IncludePaths(test_module, target.result.os.tag);

    const engine_tests = b.addTest(.{
        .root_module = test_module,
    });
    engine_tests.linkLibrary(zflecs.artifact("flecs"));
    linkSdl3(engine_tests);
    linkVulkan(engine_tests, vulkan_sdk);

    const run_engine_tests = b.addRunArtifact(engine_tests);

    const test_step = b.step("test", "Run engine tests");
    test_step.dependOn(&run_engine_tests.step);
}

/// Compile a GLSL shader to SPIR-V using glslc.
fn compileShader(b: *std.Build, glslc: []const u8, src: []const u8) std.Build.LazyPath {
    const ext = std.fs.path.extension(src); // ".vert" or ".frag"
    const out_name = std.fmt.allocPrint(b.allocator, "{s}.spv", .{std.fs.path.basename(src)}) catch @panic("OOM");
    _ = ext;
    const cmd = b.addSystemCommand(&.{ glslc, "--target-env=vulkan1.2", "-o" });
    const spv = cmd.addOutputFileArg(out_name);
    cmd.addFileArg(b.path(src));
    return spv;
}

/// Add SDL3 C include paths to a module (needed for @cImport in backend.zig).
fn addSdl3IncludePaths(module: *std.Build.Module, os: std.Target.Os.Tag) void {
    switch (os) {
        .macos => module.addIncludePath(.{ .cwd_relative = "/usr/local/opt/sdl3/include" }),
        else => {},
    }
}

/// Link the SDL3 system library for a compile step.
/// On macOS (Homebrew Intel), SDL3 lives under /usr/local/opt/sdl3.
pub fn linkSdl3(step: *std.Build.Step.Compile) void {
    switch (step.rootModuleTarget().os.tag) {
        .macos => {
            step.addLibraryPath(.{ .cwd_relative = "/usr/local/opt/sdl3/lib" });
            step.linkSystemLibrary("SDL3");
            step.root_module.addRPathSpecial("@executable_path");
        },
        .linux => {
            step.linkSystemLibrary("SDL3");
            step.root_module.addRPathSpecial("$ORIGIN");
        },
        .windows => {
            step.linkSystemLibrary("SDL3");
        },
        else => {},
    }
}

/// Link the Vulkan loader library for a compile step.
/// Also adds the SDL3 include path so @cImport(SDL_vulkan.h) resolves.
pub fn linkVulkan(step: *std.Build.Step.Compile, vulkan_sdk: []const u8) void {
    const b = step.step.owner;
    switch (step.rootModuleTarget().os.tag) {
        .macos => {
            const lib_path = std.fmt.allocPrint(b.allocator, "{s}/lib", .{vulkan_sdk}) catch @panic("OOM");
            step.addLibraryPath(.{ .cwd_relative = lib_path });
            step.linkSystemLibrary("vulkan");
            step.addRPath(.{ .cwd_relative = lib_path });
            step.root_module.addIncludePath(.{ .cwd_relative = "/usr/local/opt/sdl3/include" });
        },
        .linux => {
            step.linkSystemLibrary("vulkan");
        },
        .windows => {
            step.linkSystemLibrary("vulkan-1");
        },
        else => {},
    }
}
