// M1: Minimal xev echo test. Proves xev types work as struct fields.
// ALL fields must come before ALL declarations (Zig language rule).
const std = @import("std");
const xev = @import("xev");

const EchoServer = struct {
    tpool: xev.ThreadPool,
    loop: xev.Loop,
    listener: xev.TCP,
    accept_c: xev.Completion,
    // ---- all fields above, all declarations below ----

    pub fn init() !EchoServer {
        const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
        var self = EchoServer{
            .tpool = xev.ThreadPool.init(.{}),
            .loop = undefined,
            .listener = try xev.TCP.init(addr),
            .accept_c = .{},
        };
        self.loop = try xev.Loop.init(.{ .thread_pool = &self.tpool });
        try self.listener.bind(addr);
        try self.listener.listen(1);
        return self;
    }

    pub fn port(self: *const EchoServer) u16 {
        return self.listener.fd.port() catch 0;
    }

    pub fn deinit(self: *EchoServer) void {
        self.loop.deinit();
        self.tpool.shutdown();
        self.tpool.deinit();
    }
};

test "xev echo: struct compiles and binds" {
    var server = try EchoServer.init();
    defer server.deinit();
    try std.testing.expect(server.port() > 0);
}

test "xev echo: accept and echo one message" {
    var server = try EchoServer.init();
    defer server.deinit();

    const server_port = server.port();
    const server_addr = try std.net.Address.parseIp4("127.0.0.1", server_port);

    // Accept callback sets accepted connection.
    var accepted: ?xev.TCP = null;
    server.listener.accept(&server.loop, &server.accept_c, ?xev.TCP, &accepted, struct {
        fn callback(
            ud: ?*?xev.TCP,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.TCP,
            r: xev.AcceptError!void,
        ) xev.CallbackAction {
            ud.?.* = r catch return .disarm;
            return .disarm;
        }
    }.callback);

    // Client connect.
    var client = try xev.TCP.init(server_addr);
    defer {
        var c: xev.Completion = .{};
        client.close(&server.loop, &c, void, null, struct {
            fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.CloseError!void) xev.CallbackAction {
                return .disarm;
            }
        }.cb);
        _ = server.loop.run(.until_done);
    }
    var c_connect: xev.Completion = .{};
    client.connect(&server.loop, &c_connect, server_addr, void, null, struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.ConnectError!void) xev.CallbackAction {
            return .disarm;
        }
    }.cb);
    try server.loop.run(.until_done);

    // Client sends "hello".
    const msg = "hello";
    var n_written: usize = 0;
    var c_write: xev.Completion = .{};
    client.write(&server.loop, &c_write, .{ .slice = msg }, usize, &n_written, struct {
        fn cb(
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
    }.cb);
    try server.loop.run(.until_done);
    try std.testing.expectEqual(msg.len, n_written);

    // Server reads it back.
    var read_buf: [128]u8 = undefined;
    var n_read: usize = 0;
    var c_read: xev.Completion = .{};
    const conn = accepted orelse return error.NoConnection;
    conn.read(&server.loop, &c_read, .{ .slice = &read_buf }, usize, &n_read, struct {
        fn cb(
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
    }.cb);
    try server.loop.run(.until_done);
    try std.testing.expectEqual(msg.len, n_read);
    try std.testing.expectEqualStrings(msg, read_buf[0..n_read]);
}
