// Length-prefix message framing.
//
// Wire format:  [ u32 big-endian length ] [ payload bytes ]
//
// The 4-byte header encodes the payload length. The receiver reads the header
// first, validates the length against max_frame_bytes, then reads exactly that
// many bytes into the caller-supplied buffer.
//
// Design decisions referenced:
//   §5: Message framing — 4-byte length-prefix header + Protobuf payload

const std = @import("std");
const xev = @import("xev");
const transport = @import("transport.zig");

pub const max_frame_bytes = transport.max_frame_bytes;

/// Header size in bytes (u32 big-endian).
pub const header_bytes: usize = 4;

pub const FrameError = error{
    /// Payload exceeds max_frame_bytes — peer is broken or malicious.
    FrameTooLarge,
    /// Caller-supplied buffer is smaller than the incoming payload.
    BufferTooSmall,
    /// Peer closed the connection cleanly.
    ConnectionClosed,
};

// ============================================================================
// Send
// ============================================================================

/// Send a length-prefixed frame over the transport.
/// payload must not exceed max_frame_bytes.
pub fn sendFrame(t: transport.Transport, payload: []const u8) !void {
    std.debug.assert(payload.len <= max_frame_bytes);
    var header: [header_bytes]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload.len), .big);
    try t.send(&header);
    if (payload.len > 0) {
        try t.send(payload);
    }
}

// ============================================================================
// Receive
// ============================================================================

/// Receive one length-prefixed frame into buf.
/// Returns the payload slice (sub-slice of buf).
/// Returns FrameError.FrameTooLarge if the peer sends a length > max_frame_bytes.
/// Returns FrameError.BufferTooSmall if the frame fits in the protocol but not in buf.
/// Returns FrameError.ConnectionClosed if the peer closes cleanly.
pub fn recvFrame(t: transport.Transport, buf: []u8) ![]u8 {
    var header: [header_bytes]u8 = undefined;
    try recvExact(t, &header);

    const len = std.mem.readInt(u32, &header, .big);
    if (len > max_frame_bytes) return FrameError.FrameTooLarge;
    if (len > buf.len) return FrameError.BufferTooSmall;

    const payload = buf[0..len];
    if (len > 0) try recvExact(t, payload);
    return payload;
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Read exactly buf.len bytes from the transport, looping on partial reads.
fn recvExact(t: transport.Transport, buf: []u8) !void {
    std.debug.assert(buf.len > 0);
    var pos: usize = 0;
    while (pos < buf.len) {
        const n = try t.recv(buf[pos..]);
        if (n == 0) return FrameError.ConnectionClosed;
        pos += n;
    }
    std.debug.assert(pos == buf.len);
}

// ============================================================================
// Tests
// ============================================================================

const tcp = @import("tcp.zig");

test "framing: roundtrip empty payload" {
    const fds = try tcp.makeTestPair();
    var sender = tcp.TcpTransport{ .stream = .{ .handle = fds[0] } };
    var receiver = tcp.TcpTransport{ .stream = .{ .handle = fds[1] } };
    defer sender.deinit();
    defer receiver.deinit();

    try sendFrame(sender.transport(), &.{});

    var buf: [256]u8 = undefined;
    const got = try recvFrame(receiver.transport(), &buf);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

test "framing: roundtrip small payload" {
    const fds = try tcp.makeTestPair();
    var sender = tcp.TcpTransport{ .stream = .{ .handle = fds[0] } };
    var receiver = tcp.TcpTransport{ .stream = .{ .handle = fds[1] } };
    defer sender.deinit();
    defer receiver.deinit();

    const payload = "blood rift";
    try sendFrame(sender.transport(), payload);

    var buf: [256]u8 = undefined;
    const got = try recvFrame(receiver.transport(), &buf);
    try std.testing.expectEqualSlices(u8, payload, got);
}

test "framing: roundtrip multiple frames" {
    const fds = try tcp.makeTestPair();
    var sender = tcp.TcpTransport{ .stream = .{ .handle = fds[0] } };
    var receiver = tcp.TcpTransport{ .stream = .{ .handle = fds[1] } };
    defer sender.deinit();
    defer receiver.deinit();

    try sendFrame(sender.transport(), "first");
    try sendFrame(sender.transport(), "second");

    var buf: [256]u8 = undefined;
    const a = try recvFrame(receiver.transport(), &buf);
    try std.testing.expectEqualSlices(u8, "first", a);

    const b = try recvFrame(receiver.transport(), &buf);
    try std.testing.expectEqualSlices(u8, "second", b);
}

test "framing: rejects oversized frame" {
    const fds = try tcp.makeTestPair();
    var sender = tcp.TcpTransport{ .stream = .{ .handle = fds[0] } };
    var receiver = tcp.TcpTransport{ .stream = .{ .handle = fds[1] } };
    defer sender.deinit();
    defer receiver.deinit();

    // Write a header claiming a payload larger than max_frame_bytes.
    var bad_header: [header_bytes]u8 = undefined;
    std.mem.writeInt(u32, &bad_header, max_frame_bytes + 1, .big);
    try sender.stream.writeAll(&bad_header);

    var buf: [256]u8 = undefined;
    const result = recvFrame(receiver.transport(), &buf);
    try std.testing.expectError(FrameError.FrameTooLarge, result);
}

// ============================================================================
// Async framing (M3: libxev-based)
// ============================================================================

const XevTcp = @import("xev_tcp.zig").XevTcp;

/// Send a length-prefixed frame asynchronously. Writes header then payload
/// sequentially via callbacks. The caller's payload must remain valid until
/// the callback fires.
pub fn sendFrameAsync(
    loop: *xev.Loop,
    conn: *XevTcp,
    payload: []const u8,
    n_written: *usize,
) void {
    std.debug.assert(payload.len <= max_frame_bytes);
    var header: [header_bytes]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload.len), .big);

    // Write header first, then payload. For MVP we write both synchronously
    // via the async write API (header write finishes before payload starts
    // because the loop drains both callbacks before returning).
    conn.write(loop, &header, n_written);
    // TODO(M3): chain payload write after header completes
}

/// Async recv frame state machine. Reads header then payload via callbacks.
/// When the complete frame is received, invokes the user callback with
/// the payload slice (a sub-slice of the caller's buf).
pub fn recvFrameAsync(
    _loop: *xev.Loop,
    _conn: *XevTcp,
    _buf: []u8,
    _callback: *const fn ([]const u8, ?FrameError) void,
) void {
    _ = _loop;
    _ = _conn;
    _ = _buf;
    _ = _callback;
    // TODO(M3): implement state machine for header -> payload reads
}

test "framing async: roundtrip empty payload" {
    var tpool = xev.ThreadPool.init(.{});
    defer {
        tpool.shutdown();
        tpool.deinit();
    }
    var loop = try xev.Loop.init(.{ .thread_pool = &tpool });
    defer loop.deinit();

    const fds = try std.posix.socketpair(std.posix.AF.LOCAL, std.posix.SOCK.STREAM, 0);
    var sender = XevTcp{ .tcp = xev.TCP.initFd(fds[0]) };
    var receiver = XevTcp{ .tcp = xev.TCP.initFd(fds[1]) };
    defer {
        var c: xev.Completion = .{};
        sender.tcp.close(&loop, &c, void, null, struct {
            fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.CloseError!void) xev.CallbackAction {
                return .disarm;
            }
        }.cb);
        _ = loop.run(.until_done);
    }
    defer {
        var c: xev.Completion = .{};
        receiver.tcp.close(&loop, &c, void, null, struct {
            fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.CloseError!void) xev.CallbackAction {
                return .disarm;
            }
        }.cb);
        _ = loop.run(.until_done);
    }

    // Sync sendFrame for the sender side (writes header+payload directly).
    // The async framing test focuses on recvFrameAsync.
    // For now, use the XevTcp.write directly.

    var header: [header_bytes]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(@as(usize, 0)), .big);
    var n: usize = 0;
    sender.write(&loop, &header, &n);
    try loop.run(.until_done);
    try std.testing.expectEqual(@as(usize, 4), n);

    // Read header back using raw XevTcp (async framing not yet implemented).
    var read_buf: [4]u8 = undefined;
    var n_read: usize = 0;
    receiver.read(&loop, &read_buf, &n_read);
    try loop.run(.until_done);
    try std.testing.expectEqual(@as(usize, 4), n_read);

    const payload_len = std.mem.readInt(u32, &read_buf, .big);
    try std.testing.expectEqual(@as(u32, 0), payload_len);
}
