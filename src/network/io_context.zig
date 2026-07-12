// Minimal Io context for engine network code.
// ZIG016-TODO(M5): wire io through TcpTransport instead of module-level global.
const std = @import("std");
pub var io: std.Io = undefined;
