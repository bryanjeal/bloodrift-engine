const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    // Expose the engine as a module for the parent build.
    const engine_module = b.addModule("engine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine_module.addImport("zflecs", zflecs.module("root"));
    engine_module.addImport("zsdl3", zsdl.module("zsdl3"));

    // Engine tests.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("zflecs", zflecs.module("root"));
    test_module.addImport("zsdl3", zsdl.module("zsdl3"));

    const engine_tests = b.addTest(.{
        .root_module = test_module,
    });
    engine_tests.linkLibrary(zflecs.artifact("flecs"));
    linkSdl3(engine_tests);

    const run_engine_tests = b.addRunArtifact(engine_tests);

    const test_step = b.step("test", "Run engine tests");
    test_step.dependOn(&run_engine_tests.step);
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
