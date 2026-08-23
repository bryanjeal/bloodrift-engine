// Engine network subsystem.
//
// Exports the libxev async transport layer. Game code accesses networking
// through these public APIs without importing zflecs, SDL3, or any other
// engine-internal dependency directly.

pub const xev_tcp = @import("xev_tcp.zig");

test {
    _ = xev_tcp;
    _ = @import("xev_tcp_test.zig");
}
