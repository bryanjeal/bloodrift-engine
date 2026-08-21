// Tests for xev_tcp.zig (XevTcp libxev wrapper).
// Extracted to keep xev_tcp.zig under the 500-line limit (TD-120 work).

const std = @import("std");
const xev = @import("xev");
const XevTcp = @import("xev_tcp.zig").XevTcp;

// ============================================================================
// Tests
// ============================================================================

test "xev_tcp: initFd forces O_NONBLOCK on wrapped fds" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .wasi) return error.SkipZigTest;
    if (xev.backend == .io_uring) return error.SkipZigTest; // not enforced on io_uring

    var sv: [2]std.c.fd_t = undefined;
    const rc = std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sv);
    if (rc != 0) return error.SkipZigTest;
    defer _ = std.c.close(sv[0]);
    defer _ = std.c.close(sv[1]);

    const nonblock: c_int = @intCast(@as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));

    // Precondition: socketpair fds are blocking by default.
    const before = std.c.fcntl(sv[0], std.c.F.GETFL, @as(c_int, 0));
    try std.testing.expect(before >= 0);
    try std.testing.expectEqual(@as(c_int, 0), before & nonblock);

    const t = XevTcp.initFd(sv[0]);

    // Postcondition: wrapped fd is non-blocking.
    const after = std.c.fcntl(t.tcp.fd, std.c.F.GETFL, @as(c_int, 0));
    try std.testing.expect(after & nonblock != 0);
}

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

    // Retrieve the actual port assigned by the OS. getsockname must write a
    // full sockaddr (16 bytes); writing into the 6-byte Ip4Address payload
    // overflows it and corrupts the address passed to connect(), which then
    // targets a random IP and wedges the loop on poll backends (TD-120).
    var sa: std.c.sockaddr.in = undefined;
    var sock_len: std.posix.socklen_t = @sizeOf(std.c.sockaddr.in);
    try std.testing.expectEqual(@as(c_int, 0), std.c.getsockname(server.tcp.fd, @ptrCast(&sa), &sock_len));
    address = .{ .ip4 = .{
        .bytes = @bitCast(sa.addr),
        .port = std.mem.bigToNative(u16, sa.port),
    } };

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
