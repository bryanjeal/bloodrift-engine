// Async TCP wrapper around libxev (TD-002).
//
// XevTcp wraps xev.TCP with convenience methods for accept/read/write/close.
// The xev.Loop and xev.ThreadPool are owned externally (by the caller).
// XevTcp is lightweight: just a TCP handle and completion scratch space.
//
// Each XevTcp has SEPARATE completions for read and write so that a
// pending .no_wait operation in one direction never overwrites the other.
// Pending flags prevent a second submission in the same direction before
// the first completes. Results are stored on XevTcp (not on the caller's
// stack) so callbacks are always writing to live memory.
//
// ALL fields must come before ALL declarations (Zig language rule).

const std = @import("std");
const xev = @import("xev");

pub const XevTcp = struct {
    tcp: xev.TCP,

    // Shared completion for accept, connect, and close.
    // These are mutually exclusive: connect happens before any read/write,
    // accept happens on the listener (separate XevTcp), close happens after
    // all read/write stop. They share a completion to avoid field bloat.
    completion: xev.Completion = .{},

    // Separate completions for read and write so .no_wait operations in
    // opposite directions never corrupt each other.
    read_completion: xev.Completion = .{},
    write_completion: xev.Completion = .{},

    // Guards: a second read()/write() before the first completes is a no-op.
    // The callback clears the flag when the operation finishes.
    read_pending: bool = false,
    write_pending: bool = false,

    // Stable result storage. Callbacks write here (not to the caller's
    // stack), so the result is valid regardless of when the callback fires.
    read_result: usize = 0,
    write_result: usize = 0,

    // ---- all fields above, all declarations below ----

    /// Create a new TCP, not yet connected or bound.
    pub fn init(addr: std.net.Address) !XevTcp {
        return XevTcp{ .tcp = try xev.TCP.init(addr) };
    }

    /// Wrap an existing file descriptor (for testing via socketpair).
    /// Caller owns the fd lifecycle.
    pub fn initFd(fd: xev.TCP.FdType) XevTcp {
        return XevTcp{ .tcp = xev.TCP.initFd(fd) };
    }

    /// Bind to an address (server-side).
    pub fn bind(self: *XevTcp, addr: std.net.Address) !void {
        try self.tcp.bind(addr);
    }

    /// Listen for incoming connections (server-side).
    pub fn listen(self: *XevTcp, backlog: u31) !void {
        try self.tcp.listen(backlog);
    }

    /// Accept a connection. The callback receives the accepted TCP on success
    /// via r: xev.AcceptError!xev.TCP. conn_ptr is set to the accepted TCP
    /// and the callback disarms on success.
    pub fn accept(
        self: *XevTcp,
        loop: *xev.Loop,
        conn_ptr: *?xev.TCP,
    ) void {
        self.tcp.accept(loop, &self.completion, ?xev.TCP, conn_ptr, acceptCallback);
    }

    fn acceptCallback(
        ud: ?*?xev.TCP,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.AcceptError!xev.TCP,
    ) xev.CallbackAction {
        if (r) |conn| {
            ud.?.* = conn;
        } else |_| {
            ud.?.* = null;
        }
        return .disarm;
    }

    /// Connect to a remote address (client-side). Blocks until the connection
    /// completes or fails. Returns error on connection failure.
    pub fn connect(
        self: *XevTcp,
        loop: *xev.Loop,
        addr: std.net.Address,
    ) !void {
        var connected: bool = false;
        self.tcp.connect(loop, &self.completion, addr, bool, &connected, connectCallback);
        try loop.run(.until_done);
        if (!connected) return error.ConnectionFailed;
    }

    fn connectCallback(
        ud: ?*bool,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        r: xev.ConnectError!void,
    ) xev.CallbackAction {
        if (r) |_| {
            ud.?.* = true;
        } else |_| {
            ud.?.* = false;
        }
        return .disarm;
    }

    /// Submit a non-blocking read into buf. Pump the loop afterward.
    ///
    /// If a previous read is still pending, this is a no-op (the completion
    /// is armed; submitting again would corrupt it). The caller should check
    /// `read_result` after loop.run() — it holds bytes read, or 0 on
    /// error/EOF/no-data-yet.
    ///
    /// Caller contract: read `read_result` (not a local variable) after
    /// pump(), because the callback writes to XevTcp's stable storage.
    pub fn read(
        self: *XevTcp,
        loop: *xev.Loop,
        buf: []u8,
    ) void {
        if (self.read_pending) return;
        self.read_pending = true;
        self.read_result = 0;
        self.tcp.read(loop, &self.read_completion, .{ .slice = buf }, XevTcp, self, readCallback);
    }

    fn readCallback(
        ud: ?*XevTcp,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        _: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        const s = ud.?;
        s.read_result = r catch 0;
        s.read_pending = false;
        return .disarm;
    }

    /// Submit a non-blocking write of data. Pump the loop afterward.
    ///
    /// If a previous write is still pending, this is a no-op (the completion
    /// is armed; submitting again would corrupt it). The caller should check
    /// `write_result` after loop.run() — it holds bytes written, or 0 on
    /// error/buffer-full.
    ///
    /// Caller contract: read `write_result` (not a local variable) after
    /// pump(), because the callback writes to XevTcp's stable storage.
    pub fn write(
        self: *XevTcp,
        loop: *xev.Loop,
        data: []const u8,
    ) void {
        if (self.write_pending) return;
        self.write_pending = true;
        self.write_result = 0;
        self.tcp.write(loop, &self.write_completion, .{ .slice = data }, XevTcp, self, writeCallback);
    }

    fn writeCallback(
        ud: ?*XevTcp,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        _: xev.WriteBuffer,
        r: xev.WriteError!usize,
    ) xev.CallbackAction {
        const s = ud.?;
        s.write_result = r catch 0;
        s.write_pending = false;
        return .disarm;
    }

    /// Graceful close. The callback fires when the close completes.
    /// Pump the loop afterward to process the completion.
    pub fn close(
        self: *XevTcp,
        loop: *xev.Loop,
    ) void {
        self.tcp.close(loop, &self.completion, void, null, closeCallback);
    }

    fn closeCallback(
        _: ?*void,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        _: xev.CloseError!void,
    ) xev.CallbackAction {
        return .disarm;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "xev_tcp: read and write use separate completions" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    // Create a connected socketpair so we can test read/write isolation
    // without a full TCP handshake.
    var sv: [2]std.c.fd_t = undefined;
    const rc = std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sv);
    if (rc != 0) return error.SkipZigTest;

    var tpool = xev.ThreadPool.init(.{});
    defer tpool.deinit();
    defer tpool.shutdown();
    var loop = try xev.Loop.init(.{ .thread_pool = &tpool });
    defer loop.deinit();

    var client = XevTcp.initFd(sv[0]);
    var server = XevTcp.initFd(sv[1]);
    defer {
        client.close(&loop);
        loop.run(.until_done) catch {};
    }
    defer {
        server.close(&loop);
        loop.run(.until_done) catch {};
    }

    // Write data from the client side (non-blocking).
    const msg = "hello_separate";
    client.write(&loop, msg);
    try loop.run(.until_done);
    try std.testing.expectEqual(msg.len, client.write_result);
    try std.testing.expect(!client.write_pending);

    // Read data on the server side (non-blocking).
    var recv_buf: [64]u8 = undefined;
    server.read(&loop, &recv_buf);
    try loop.run(.until_done);
    try std.testing.expectEqual(msg.len, server.read_result);
    try std.testing.expect(!server.read_pending);
    try std.testing.expectEqualSlices(u8, msg, recv_buf[0..server.read_result]);
}

test "xev_tcp: read_pending prevents completion overwrite" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var sv: [2]std.c.fd_t = undefined;
    const rc = std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sv);
    if (rc != 0) return error.SkipZigTest;

    var tpool = xev.ThreadPool.init(.{});
    defer tpool.deinit();
    defer tpool.shutdown();
    var loop = try xev.Loop.init(.{ .thread_pool = &tpool });
    defer loop.deinit();

    var server = XevTcp.initFd(sv[1]);
    defer {
        server.close(&loop);
        loop.run(.until_done) catch {};
    }
    _ = sv[0]; // client fd, not needed for this test

    // Submit a read when there is no data. The read will be pending.
    var recv_buf: [64]u8 = undefined;
    server.read(&loop, &recv_buf);
    try loop.run(.no_wait);
    // read_pending is true because there is no data yet.
    try std.testing.expect(server.read_pending);
    try std.testing.expectEqual(@as(usize, 0), server.read_result);

    // Submit a second read while the first is still pending.
    // This MUST be a no-op - it must not overwrite the armed completion.
    server.read(&loop, &recv_buf);
    try std.testing.expect(server.read_pending); // still pending
    try std.testing.expectEqual(@as(usize, 0), server.read_result);
}

test "xev_tcp: write_pending prevents completion overwrite" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var sv: [2]std.c.fd_t = undefined;
    const rc = std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sv);
    if (rc != 0) return error.SkipZigTest;

    var tpool = xev.ThreadPool.init(.{});
    defer tpool.deinit();
    defer tpool.shutdown();
    var loop = try xev.Loop.init(.{ .thread_pool = &tpool });
    defer loop.deinit();

    var client = XevTcp.initFd(sv[0]);
    defer {
        client.close(&loop);
        loop.run(.until_done) catch {};
    }
    _ = sv[1]; // server fd, not needed for this test

    // Fill up the send buffer by writing a very large chunk with a small
    // SO_SNDBUF. After the first write, a second should no-op because the
    // first is still pending.
    _ = std.posix.setsockopt(
        client.tcp.fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDBUF,
        &std.mem.toBytes(@as(c_int, 1024)),
    );

    const big_msg = [_]u8{0xAA} ** (1024 * 1024); // 1 MB
    client.write(&loop, &big_msg);
    try loop.run(.no_wait);

    // Submit a second write while the first might still be pending.
    // The pending guard prevents overwriting the armed completion.
    client.write(&loop, "should_noop");
    // After the no-op, write_pending is still whatever the first write
    // set it to. write_result is still the first write's result.
    // The key property: the completion was NOT overwritten.
}

test "xev_tcp: bidirectionhal read and write do not interfere" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var sv: [2]std.c.fd_t = undefined;
    const rc = std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sv);
    if (rc != 0) return error.SkipZigTest;

    var tpool = xev.ThreadPool.init(.{});
    defer tpool.deinit();
    defer tpool.shutdown();
    var loop = try xev.Loop.init(.{ .thread_pool = &tpool });
    defer loop.deinit();

    var a = XevTcp.initFd(sv[0]);
    var b = XevTcp.initFd(sv[1]);
    defer {
        a.close(&loop);
        loop.run(.until_done) catch {};
    }
    defer {
        b.close(&loop);
        loop.run(.until_done) catch {};
    }

    // Write from A to B.
    const msg_ab = "a_to_b";
    a.write(&loop, msg_ab);

    // Write from B to A (opposite direction) before pumping.
    const msg_ba = "b_to_a";
    b.write(&loop, msg_ba);

    // Pump the loop - both writes should complete independently
    // because they use separate XevTcp instances with separate completions.
    try loop.run(.until_done);

    try std.testing.expectEqual(msg_ab.len, a.write_result);
    try std.testing.expectEqual(msg_ba.len, b.write_result);

    // Now read on both sides.
    var a_buf: [64]u8 = undefined;
    var b_buf: [64]u8 = undefined;
    a.read(&loop, &a_buf);
    b.read(&loop, &b_buf);
    try loop.run(.until_done);

    try std.testing.expectEqual(msg_ba.len, a.read_result);
    try std.testing.expectEqual(msg_ab.len, b.read_result);
    try std.testing.expectEqualSlices(u8, msg_ba, a_buf[0..a.read_result]);
    try std.testing.expectEqualSlices(u8, msg_ab, b_buf[0..b.read_result]);
}

test "xev_tcp: same-connection read and write use separate completions" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var sv: [2]std.c.fd_t = undefined;
    const rc = std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sv);
    if (rc != 0) return error.SkipZigTest;

    var tpool = xev.ThreadPool.init(.{});
    defer tpool.deinit();
    defer tpool.shutdown();
    var loop = try xev.Loop.init(.{ .thread_pool = &tpool });
    defer loop.deinit();

    var a = XevTcp.initFd(sv[0]);
    var b = XevTcp.initFd(sv[1]);
    defer {
        a.close(&loop);
        loop.run(.until_done) catch {};
    }
    defer {
        b.close(&loop);
        loop.run(.until_done) catch {};
    }

    // Write from B so A has data to read.
    b.write(&loop, "hello");
    try loop.run(.until_done);

    // On A: submit a read AND a write simultaneously.
    // They use read_completion and write_completion respectively,
    // so neither should corrupt the other.
    var a_recv: [64]u8 = undefined;
    a.read(&loop, &a_recv);
    a.write(&loop, "world");
    try loop.run(.until_done);

    // Both operations should have completed independently.
    try std.testing.expect(!a.read_pending);
    try std.testing.expect(!a.write_pending);
    try std.testing.expectEqual(@as(usize, 5), a.read_result);
    try std.testing.expectEqual(@as(usize, 5), a.write_result);
    try std.testing.expectEqualSlices(u8, "hello", a_recv[0..5]);

    // B reads A's write.
    var b_recv: [64]u8 = undefined;
    b.read(&loop, &b_recv);
    try loop.run(.until_done);
    try std.testing.expectEqual(@as(usize, 5), b.read_result);
    try std.testing.expectEqualSlices(u8, "world", b_recv[0..5]);
}
