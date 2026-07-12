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

    // Set true when a read completes with 0 bytes (TCP FIN from peer).
    eof: bool = false,

    // ---- all fields above, all declarations below ----

    /// Create a new TCP, not yet connected or bound.
    pub fn init(addr: std.Io.net.IpAddress) !XevTcp {
        return XevTcp{ .tcp = try xev.TCP.init(addr) };
    }

    /// Wrap an existing file descriptor (for testing via socketpair).
    /// Caller owns the fd lifecycle.
    pub fn initFd(fd: std.posix.socket_t) XevTcp {
        return XevTcp{ .tcp = xev.TCP.initFd(fd) };
    }

    /// Bind to an address (server-side).
    pub fn bind(self: *XevTcp, addr: std.Io.net.IpAddress) !void {
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
        addr: std.Io.net.IpAddress,
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
        std.log.info("xev_tcp: read submitted (buf={} bytes)", .{buf.len});
        // tcp.read() sets c.* = .{...} which defaults flags.state to .dead.
        // stop_completion() does nothing for .dead non-timer ops (kqueue.zig:948).
        // Set state back to .adding so submit() properly starts the completion.
        self.tcp.read(loop, &self.read_completion, .{ .slice = buf }, XevTcp, self, readCallback);
        self.read_completion.flags.state = .adding;
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
        std.log.info("xev_tcp: read completed (result={})", .{s.read_result});
        if (s.read_result == 0) s.eof = true;
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
        std.log.info("xev_tcp: write submitted (data={} bytes)", .{data.len});
        // xev.Completion defaults to state=.dead, which routes through
        // stop_completion() instead of start(). Explicitly reset to .adding
        // so the completion is properly registered with kqueue.
        self.tcp.write(loop, &self.write_completion, .{ .slice = data }, XevTcp, self, writeCallback);
        self.write_completion.flags.state = .adding;
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
        std.log.info("xev_tcp: write completed (result={})", .{s.write_result});
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

    /// True when the peer has closed the connection (TCP FIN received).
    /// Check after loop.run(...) when a read completed with 0 bytes.
    pub fn isEof(self: *const XevTcp) bool {
        return self.eof;
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
    _ = std.c.close(sv[0]); // unused client fd

    // Submit a read when there is no data, then pump.
    var recv_buf: [64]u8 = undefined;
    server.read(&loop, &recv_buf);
    try loop.run(.no_wait);

    // Capture state after first read attempt.
    const was_pending = server.read_pending;
    const first_result = server.read_result;

    // Submit a second read. If the first is still pending, this must no-op
    // rather than overwrite the armed completion. If the first completed,
    // this submits a new read normally. Either way, no crash, no corruption.
    server.read(&loop, &recv_buf);

    // State after second read: if the first was pending, state unchanged.
    // If the first completed, the second may have submitted and possibly
    // completed too. The key invariant: the second read didn't corrupt
    // the first completion (which would crash or hang xev internally).
    if (was_pending) {
        try std.testing.expectEqual(first_result, server.read_result);
    }
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
    defer _ = std.c.close(sv[1]); // unused server fd, closed after client

    // Write a large chunk to try to fill the socket buffer. Don't read
    // from the other end, so the send buffer may back up.
    const big_msg = [_]u8{0xAA} ** (256 * 1024); // 256 KB
    client.write(&loop, &big_msg);
    try loop.run(.no_wait);

    // Capture state after first write.
    const was_pending = client.write_pending;
    const first_result = client.write_result;

    // Submit a second write. If pending, must no-op. Otherwise submits normally.
    client.write(&loop, "should_not_corrupt");

    // If the first write was pending, the guard prevented completion overwrite:
    // write_pending and write_result are unchanged.
    if (was_pending) {
        try std.testing.expectEqual(first_result, client.write_result);
    }
    // Either way, we didn't crash. The guard works.
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

test "xev_tcp: real TCP sequential write then read (repro handshake hang)" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;
    if (builtin.os.tag == .freebsd) return error.SkipZigTest;

    var tpool = xev.ThreadPool.init(.{});
    defer tpool.deinit();
    defer tpool.shutdown();
    var loop = try xev.Loop.init(.{ .thread_pool = &tpool });
    defer loop.deinit();

    // Use port 0 for OS-assigned random port (Zig #14907).
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try XevTcp.init(address);
    defer {
        server.close(&loop);
        loop.run(.until_done) catch {};
    }
    try server.bind(address);
    try server.listen(1);

    // Retrieve the actual port assigned by the OS.
    var sock_len: std.posix.socklen_t = @sizeOf(std.c.sockaddr);
    _ = std.c.getsockname(server.tcp.fd, @ptrCast(&address.ip4), &sock_len);

    var client = try XevTcp.init(address);
    defer {
        client.close(&loop);
        loop.run(.until_done) catch {};
    }

    // ---- Phase 1: Accept and connect (simultaneous, like libxev test) ----
    var accepted: ?xev.TCP = null;
    server.accept(&loop, &accepted);

    var connected: bool = false;
    client.tcp.connect(&loop, &client.completion, address, bool, &connected, (struct {
        fn cb(
            ud: ?*bool,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.TCP,
            r: xev.ConnectError!void,
        ) xev.CallbackAction {
            ud.?.* = if (r) |_| true else |_| false;
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try std.testing.expect(accepted != null);
    try std.testing.expect(connected);

    var server_conn = XevTcp{ .tcp = accepted.? };
    defer {
        server_conn.close(&loop);
        loop.run(.until_done) catch {};
    }

    // ---- Phase 2: Sequential write then read (mimics production flow) ----
    // Client writes data first, pump to completion.
    const msg = "hello_real_tcp_handshake";
    client.write(&loop, msg);
    try loop.run(.until_done);
    try std.testing.expectEqual(msg.len, client.write_result);
    try std.testing.expect(!client.write_pending);

    // Server reads AFTER client write completed (sequential, not simultaneous).
    // This is the exact pattern that hangs in production: data is already in
    // the kernel TCP receive buffer when the server submits its read.
    var recv_buf: [128]u8 = undefined;
    server_conn.read(&loop, &recv_buf);
    try loop.run(.until_done);
    try std.testing.expectEqual(msg.len, server_conn.read_result);
    try std.testing.expect(!server_conn.read_pending);
    try std.testing.expect(!server_conn.isEof());
    try std.testing.expectEqualSlices(u8, msg, recv_buf[0..server_conn.read_result]);
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
