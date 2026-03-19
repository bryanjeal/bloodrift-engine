// Engine network subsystem.
//
// Exports the transport abstraction, TCP implementation, and framing layer.
// Game code accesses networking through these public APIs without importing
// zflecs, SDL3, or any other engine-internal dependency directly.

pub const transport = @import("transport.zig");
pub const tcp = @import("tcp.zig");
pub const framing = @import("framing.zig");

test {
    _ = transport;
    _ = tcp;
    _ = framing;
}
