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
    ///
    /// POST: on poll-based backends (kqueue/epoll) the fd has O_NONBLOCK set.
    /// Those backends run read/write synchronously inside
    /// Completion.perform(); a blocking fd parks the whole loop the moment a
    /// kernel buffer fills (TD-120). xev.TCP.init() creates sockets with
    /// SOCK.NONBLOCK, so wrapped fds must match. io_uring transfers
    /// in-kernel and is exempt, mirroring the .adding switch below.
    pub fn initFd(fd: std.posix.socket_t) XevTcp {
        switch (xev.backend) {
            .io_uring => {},
            else => {
                const flags: c_int = @intCast(std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)));
                std.debug.assert(flags >= 0); // PRE: caller passed a valid fd
                const nonblock: c_int = @intCast(@as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
                const rc = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, flags | nonblock));
                std.debug.assert(rc >= 0); // POST: O_NONBLOCK is set
            },
        }
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
        // io_uring's Completion.State is only { dead, active } (no .adding);
        // its add() registers a .dead completion directly. kqueue/epoll need
        // the .adding reset so submit() starts the completion instead of
        // routing .dead through stop_completion().
        switch (xev.backend) {
            .io_uring => {},
            else => self.read_completion.flags.state = .adding,
        }
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
        switch (xev.backend) {
            .io_uring => {},
            else => self.write_completion.flags.state = .adding,
        }
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
