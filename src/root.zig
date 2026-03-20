// Blood Rift Engine — Public engine root module.
//
// This is the entry point for all engine subsystems. Game code imports
// this module to access core, renderer, network, physics, audio, and
// platform functionality.

pub const core = @import("core/root.zig");

pub const network = @import("network/root.zig");

pub const platform = @import("platform/root.zig");

pub const renderer = @import("renderer/root.zig");

/// Dear ImGui bindings — re-exported so game code can use `@import("engine").zgui`.
pub const zgui = @import("zgui");

// Subsystems added as they are implemented:
// pub const physics  = @import("physics/root.zig");
// pub const audio    = @import("audio/root.zig");

test {
    _ = core;
    _ = network;
    _ = platform;
    _ = renderer;
}
