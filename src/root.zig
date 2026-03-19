// Blood Rift Engine — Public engine root module.
//
// This is the entry point for all engine subsystems. Game code imports
// this module to access core, renderer, network, physics, audio, and
// platform functionality.

pub const core = @import("core/root.zig");

pub const platform = @import("platform/root.zig");

// Subsystems added as they are implemented:
// pub const renderer = @import("renderer/root.zig");
// pub const network  = @import("network/root.zig");
// pub const physics  = @import("physics/root.zig");
// pub const audio    = @import("audio/root.zig");

test {
    _ = core;
    _ = platform;
}
