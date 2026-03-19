// TCP transport implementation.
//
// TcpTransport wraps a std.net.Stream and exposes the Transport vtable.
// TcpListener wraps a std.net.Server and handles incoming connections.
//
// Both support a configurable receive timeout (SO_RCVTIMEO) so callers
// can poll for data without blocking indefinitely. Callers interpret
// error.WouldBlock as "no data yet, try again next tick."
//
// Design decisions referenced:
//   §5: TCP for initial implementation; abstraction allows future UDP swap

const std = @import("std");
const transport = @import("transport.zig");

pub const Transport = transport.Transport;
pub const Listener = transport.Listener;

// ============================================================================
// TcpTransport
// ============================================================================

/// A TCP connection. Stack-allocatable — no heap allocation required.
/// Caller must keep this alive for the lifetime of any Transport handle
/// derived from it.
pub const TcpTransport = struct {
    stream: std.net.Stream,

    /// Connect to a remote address.
    pub fn connect(address: std.net.Address) !TcpTransport {
        const stream = try std.net.tcpConnectToAddress(address);
        return .{ .stream = stream };
    }

    pub fn deinit(self: *TcpTransport) void {
        self.stream.close();
        self.* = undefined;
    }

    /// Set a receive timeout. read() returns error.WouldBlock after timeout_ms.
    /// Pass 0 to disable the timeout (block indefinitely).
    pub fn setRecvTimeout(self: *TcpTransport, timeout_ms: u32) !void {
        const usec: i32 = @intCast((timeout_ms % 1000) * 1000);
        const sec: i32 = @intCast(timeout_ms / 1000);
        const tv = std.posix.timeval{ .sec = sec, .usec = usec };
        try std.posix.setsockopt(
            self.stream.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&tv),
        );
    }

    /// Return a Transport handle backed by this TcpTransport.
    /// Caller must not move or free self while the handle is live.
    pub fn transport(self: *TcpTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // ------------------------------------------------------------------
    // vtable implementations
    // ------------------------------------------------------------------

    fn sendImpl(ptr: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *TcpTransport = @ptrCast(@alignCast(ptr));
        std.debug.assert(bytes.len > 0);
        try self.stream.writeAll(bytes);
    }

    fn recvImpl(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *TcpTransport = @ptrCast(@alignCast(ptr));
        std.debug.assert(buf.len > 0);
        return self.stream.read(buf);
    }

    fn closeImpl(ptr: *anyopaque) void {
        const self: *TcpTransport = @ptrCast(@alignCast(ptr));
        self.stream.close();
    }

    const vtable: Transport.VTable = .{
        .sendFn = sendImpl,
        .recvFn = recvImpl,
        .closeFn = closeImpl,
    };
};

// ============================================================================
// TcpListener
// ============================================================================

/// A TCP listening socket. Stack-allocatable.
pub const TcpListener = struct {
    server: std.net.Server,

    /// Bind and begin listening on the given address.
    pub fn init(address: std.net.Address) !TcpListener {
        const server = try address.listen(.{ .reuse_address = true });
        return .{ .server = server };
    }

    pub fn deinit(self: *TcpListener) void {
        self.server.deinit();
        self.* = undefined;
    }

    /// Set a receive timeout on the listening socket.
    /// accept() returns error.WouldBlock when no connection arrives within the timeout.
    pub fn setAcceptTimeout(self: *TcpListener, timeout_ms: u32) !void {
        const usec: i32 = @intCast((timeout_ms % 1000) * 1000);
        const sec: i32 = @intCast(timeout_ms / 1000);
        const tv = std.posix.timeval{ .sec = sec, .usec = usec };
        try std.posix.setsockopt(
            self.server.stream.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&tv),
        );
    }

    /// Accept one incoming connection. The returned TcpTransport is
    /// heap-allocated via allocator and must be freed by the caller.
    pub fn accept(self: *TcpListener, allocator: std.mem.Allocator) !*TcpTransport {
        const conn = try self.server.accept();
        const t = try allocator.create(TcpTransport);
        t.* = .{ .stream = conn.stream };
        return t;
    }

    /// Return a Listener handle backed by this TcpListener.
    pub fn listener(self: *TcpListener) Listener {
        return .{ .ptr = self, .vtable = &listener_vtable };
    }

    // ------------------------------------------------------------------
    // vtable implementations
    // ------------------------------------------------------------------

    fn acceptImpl(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!Transport {
        const self: *TcpListener = @ptrCast(@alignCast(ptr));
        const t = try self.accept(allocator);
        return t.transport();
    }

    fn listenerCloseImpl(ptr: *anyopaque) void {
        const self: *TcpListener = @ptrCast(@alignCast(ptr));
        self.server.deinit();
    }

    const listener_vtable: Listener.VTable = .{
        .acceptFn = acceptImpl,
        .closeFn = listenerCloseImpl,
    };
};

// ============================================================================
// Tests
// ============================================================================

test "tcp: connect and echo via socketpair" {
    const fds = try makeTestPair();
    var client = TcpTransport{ .stream = .{ .handle = fds[0] } };
    var server = TcpTransport{ .stream = .{ .handle = fds[1] } };
    defer client.deinit();
    defer server.deinit();

    const ct = client.transport();
    const st = server.transport();

    const msg = "hello";
    try ct.send(msg);

    var buf: [64]u8 = undefined;
    const n = try st.recv(&buf);
    try std.testing.expectEqual(msg.len, n);
    try std.testing.expectEqualSlices(u8, msg, buf[0..n]);
}

test "tcp: vtable close is idempotent via stream" {
    const fds = try makeTestPair();
    var t = TcpTransport{ .stream = .{ .handle = fds[0] } };
    _ = std.c.close(fds[1]);
    const handle = t.transport();
    handle.close(); // must not panic or assert-fail
}

/// Create a connected socket pair for use in tests (replaces std.posix.socketpair
/// which was removed in Zig 0.15).
fn makeTestPair() ![2]std.c.fd_t {
    var sv: [2]std.c.fd_t = undefined;
    const rc = std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sv);
    if (rc != 0) return error.SocketpairFailed;
    return sv;
}
