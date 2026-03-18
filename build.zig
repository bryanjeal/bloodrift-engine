const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Expose the engine as a module for the parent build.
    _ = b.addModule("engine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Engine tests.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const engine_tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_engine_tests = b.addRunArtifact(engine_tests);

    const test_step = b.step("test", "Run engine tests");
    test_step.dependOn(&run_engine_tests.step);
}
