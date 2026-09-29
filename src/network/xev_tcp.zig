// Async TCP wrapper around libxev (TD-002).
//
// XevTcp wraps libxev's dynamic TCP (xev.Dynamic.TCP) with convenience
// methods for accept/read/write/close. The xev.Loop and xev.ThreadPool are
// owned externally (by the caller). XevTcp is lightweight: just a TCP handle
// and completion scratch space.
//
// The dynamic API selects the backend at runtime via dxev.detect(): Linux
// prefers io_uring and falls back to epoll when the io_uring_setup syscall is
// blocked (seccomp in CI containers). On macOS the dynamic API collapses to
// static kqueue (single candidate), so detect() does not exist there and
// ensureBackend() is a comptime no-op.
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
const dxev = xev.Dynamic;

pub const XevTcp = struct {
    tcp: dxev.TCP,

    // Shared completion for accept, connect, and close.
    // These are mutually exclusive: connect happens before any read/write,
    // accept happens on the listener (separate XevTcp), close happens after
    // all read/write stop. They share a completion to avoid field bloat.
    completion: dxev.Completion = .{},

    // Separate completions for read and write so .no_wait operations in
    // opposite directions never corrupt each other.
    read_completion: dxev.Completion = .{},
    write_completion: dxev.Completion = .{},

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

    /// Set the dynamic backend global once before any TCP/loop use.
    /// Comptime no-op when the dynamic API collapsed to a single static
    /// backend (macOS: kqueue), where the backend is already fixed.
    fn ensureBackend() void {
        if (comptime dxev.dynamic) dxev.detect() catch {};
    }

    /// Create a new TCP, not yet connected or bound.
    pub fn init(addr: std.Io.net.IpAddress) !XevTcp {
        ensureBackend();
        return XevTcp{ .tcp = try dxev.TCP.init(addr) };
    }

    /// Wrap an existing file descriptor (for testing via socketpair).
    /// Caller owns the fd lifecycle.
    ///
    /// POST: on poll-based backends (kqueue/epoll) the fd has O_NONBLOCK set.
    /// Those backends run read/write synchronously inside
    /// Completion.perform(); a blocking fd parks the whole loop the moment a
    /// kernel buffer fills (TD-120). dxev.TCP.init() creates sockets with
    /// SOCK.NONBLOCK, so wrapped fds must match. io_uring transfers
    /// in-kernel and is exempt.
    pub fn initFd(fd_value: std.posix.socket_t) XevTcp {
        ensureBackend();
        // io_uring's in-kernel transfers tolerate a blocking fd; poll
        // backends must never see one (TD-120). dxev.backend is a runtime
        // global on Linux, so this is a plain (not comptime) branch that
        // folds on the single-candidate macOS collapse.
        if (dxev.backend != .io_uring) setNonBlock(fd_value);
        return XevTcp{ .tcp = dxev.TCP.initFd(fd_value) };
    }

    fn setNonBlock(fd_value: std.posix.socket_t) void {
        const flags: c_int = @intCast(std.c.fcntl(fd_value, std.c.F.GETFL, @as(c_int, 0)));
        std.debug.assert(flags >= 0); // PRE: caller passed a valid fd
        const nonblock: c_int = @intCast(@as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
        const rc = std.c.fcntl(fd_value, std.c.F.SETFL, @as(c_int, flags | nonblock));
        std.debug.assert(rc >= 0); // POST: O_NONBLOCK is set
    }

    /// The underlying file descriptor. The static TCP exposes fd as a public
    /// field; the dynamic TCP hides it behind an accessor.
    pub fn fd(self: *const XevTcp) std.posix.socket_t {
        if (comptime dxev.dynamic) return self.tcp.fd();
        return self.tcp.fd;
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
    /// via r: dxev.AcceptError!dxev.TCP. conn_ptr is set to the accepted TCP
    /// and the callback disarms on success.
    pub fn accept(
        self: *XevTcp,
        loop: *dxev.Loop,
        conn_ptr: *?dxev.TCP,
    ) void {
        self.tcp.accept(loop, &self.completion, ?dxev.TCP, conn_ptr, acceptCallback);
    }

    fn acceptCallback(
        ud: ?*?dxev.TCP,
        _: *dxev.Loop,
        _: *dxev.Completion,
        r: dxev.AcceptError!dxev.TCP,
    ) dxev.CallbackAction {
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
        loop: *dxev.Loop,
        addr: std.Io.net.IpAddress,
    ) !void {
        var connected: bool = false;
        self.tcp.connect(loop, &self.completion, addr, bool, &connected, connectCallback);
        try loop.run(.until_done);
        if (!connected) return error.ConnectionFailed;
    }

    fn connectCallback(
        ud: ?*bool,
        _: *dxev.Loop,
        _: *dxev.Completion,
        _: dxev.TCP,
        r: dxev.ConnectError!void,
    ) dxev.CallbackAction {
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
    /// `read_result` after loop.run() - it holds bytes read, or 0 on
    /// error/EOF/no-data-yet.
    ///
    /// Caller contract: read `read_result` (not a local variable) after
    /// pump(), because the callback writes to XevTcp's stable storage.
    ///
    /// No manual completion re-arm: dxev's shared stream layer resubmits the
    /// completion in its .dead state and both poll backends' loop.add() arm
    /// it. The old per-backend .adding pre-set was a static-API workaround,
    /// redundant in the dynamic layer.
    pub fn read(
        self: *XevTcp,
        loop: *dxev.Loop,
        buf: []u8,
    ) void {
        if (self.read_pending) return;
        self.read_pending = true;
        self.read_result = 0;
        self.tcp.read(loop, &self.read_completion, .{ .slice = buf }, XevTcp, self, readCallback);
    }

    fn readCallback(
        ud: ?*XevTcp,
        _: *dxev.Loop,
        _: *dxev.Completion,
        _: dxev.TCP,
        _: dxev.ReadBuffer,
        r: dxev.ReadError!usize,
    ) dxev.CallbackAction {
        const s = ud.?;
        s.read_result = r catch 0;
        s.read_pending = false;
        if (s.read_result == 0) s.eof = true;
        return .disarm;
    }

    /// Submit a non-blocking write of data. Pump the loop afterward.
    ///
    /// If a previous write is still pending, this is a no-op (the completion
    /// is armed; submitting again would corrupt it). The caller should check
    /// `write_result` after loop.run() - it holds bytes written, or 0 on
    /// error/buffer-full.
    ///
    /// Caller contract: read `write_result` (not a local variable) after
    /// pump(), because the callback writes to XevTcp's stable storage.
    pub fn write(
        self: *XevTcp,
        loop: *dxev.Loop,
        data: []const u8,
    ) void {
        if (self.write_pending) return;
        self.write_pending = true;
        self.write_result = 0;
        self.tcp.write(loop, &self.write_completion, .{ .slice = data }, XevTcp, self, writeCallback);
    }

    fn writeCallback(
        ud: ?*XevTcp,
        _: *dxev.Loop,
        _: *dxev.Completion,
        _: dxev.TCP,
        _: dxev.WriteBuffer,
        r: dxev.WriteError!usize,
    ) dxev.CallbackAction {
        const s = ud.?;
        s.write_result = r catch 0;
        s.write_pending = false;
        return .disarm;
    }

    /// Graceful close. The callback fires when the close completes.
    /// Pump the loop afterward to process the completion.
    pub fn close(
        self: *XevTcp,
        loop: *dxev.Loop,
    ) void {
        self.tcp.close(loop, &self.completion, void, null, closeCallback);
    }

    fn closeCallback(
        _: ?*void,
        _: *dxev.Loop,
        _: *dxev.Completion,
        _: dxev.TCP,
        _: dxev.CloseError!void,
    ) dxev.CallbackAction {
        return .disarm;
    }

    /// True when the peer has closed the connection (TCP FIN received).
    /// Check after loop.run(...) when a read completed with 0 bytes.
    pub fn isEof(self: *const XevTcp) bool {
        return self.eof;
    }
};
