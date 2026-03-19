const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Flecs ECS dependency.
    const zflecs = b.dependency("zflecs", .{
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

    // Engine tests.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("zflecs", zflecs.module("root"));

    const engine_tests = b.addTest(.{
        .root_module = test_module,
    });
    engine_tests.linkLibrary(zflecs.artifact("flecs"));

    const run_engine_tests = b.addRunArtifact(engine_tests);

    const test_step = b.step("test", "Run engine tests");
    test_step.dependOn(&run_engine_tests.step);
}
