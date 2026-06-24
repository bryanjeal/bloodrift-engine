// Async TCP wrapper around libxev (TD-002).
//
// XevTcp wraps xev.TCP with convenience methods for accept/read/write/close.
// The xev.Loop and xev.ThreadPool are owned externally (by the caller).
// XevTcp is lightweight: just a TCP handle and completion scratch space.
//
// ALL fields must come before ALL declarations (Zig language rule).

const std = @import("std");
const xev = @import("xev");

pub const XevTcp = struct {
    tcp: xev.TCP,
    completion: xev.Completion = .{},
    // ---- all fields above, all declarations below ----

    /// Create a new TCP, not yet connected or bound.
    pub fn init(addr: std.net.Address) !XevTcp {
        return XevTcp{ .tcp = try xev.TCP.init(addr) };
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

    /// Read data into buf. The callback sets n_read to the number of bytes read
    /// (or 0 on error). Pump the loop afterward to process the completion.
    pub fn read(
        self: *XevTcp,
        loop: *xev.Loop,
        buf: []u8,
        n_read: *usize,
    ) void {
        self.tcp.read(loop, &self.completion, .{ .slice = buf }, usize, n_read, readCallback);
    }

    fn readCallback(
        ud: ?*usize,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        _: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        ud.?.* = r catch 0;
        return .disarm;
    }

    /// Write data. The callback sets n_written to the number of bytes written
    /// (or 0 on error). Pump the loop afterward to process the completion.
    pub fn write(
        self: *XevTcp,
        loop: *xev.Loop,
        data: []const u8,
        n_written: *usize,
    ) void {
        self.tcp.write(loop, &self.completion, .{ .slice = data }, usize, n_written, writeCallback);
    }

    fn writeCallback(
        ud: ?*usize,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        _: xev.WriteBuffer,
        r: xev.WriteError!usize,
    ) xev.CallbackAction {
        ud.?.* = r catch 0;
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
