// Engine network transport abstraction.
//
// Transport and Listener are runtime vtable-based interfaces. Game code operates
// on Transport values; the concrete implementation (TCP, future UDP) is chosen
// at startup without changing call sites.
//
// Ownership: the backing memory for the concrete transport (e.g. TcpTransport)
// is owned by the caller. The Transport handle must not outlive it.
//
// Design decisions referenced:
//   §5: Transport abstraction layer for future TCP → UDP swap

const std = @import("std");

// ============================================================================
// Constants
// ============================================================================

/// Maximum payload size for a single framed message.
/// Prevents malicious or buggy peers from requesting oversized reads.
pub const max_frame_bytes: u32 = 64 * 1024; // 64 KiB

// ============================================================================
// Transport
// ============================================================================

/// A bidirectional byte-stream connection (one Transport per peer).
///
/// Transport is a fat pointer — the concrete implementation is chosen at
/// construction time, but all call sites are implementation-agnostic.
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Write all bytes. Blocks until fully written or returns an error.
        sendFn: *const fn (ptr: *anyopaque, bytes: []const u8) anyerror!void,
        /// Read up to buf.len bytes. Returns the number actually read.
        /// Returns 0 on a clean close.
        recvFn: *const fn (ptr: *anyopaque, buf: []u8) anyerror!usize,
        /// Close the connection. Subsequent send/recv return errors.
        closeFn: *const fn (ptr: *anyopaque) void,
    };

    pub fn send(self: Transport, bytes: []const u8) !void {
        return self.vtable.sendFn(self.ptr, bytes);
    }

    pub fn recv(self: Transport, buf: []u8) !usize {
        return self.vtable.recvFn(self.ptr, buf);
    }

    pub fn close(self: Transport) void {
        self.vtable.closeFn(self.ptr);
    }
};

// ============================================================================
// Listener
// ============================================================================

/// A server-side connection acceptor.
pub const Listener = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Block until a client connects and return its Transport.
        /// The allocator is used for any backing memory the implementation needs.
        acceptFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!Transport,
        /// Stop listening. Any blocked accept returns an error.
        closeFn: *const fn (ptr: *anyopaque) void,
    };

    pub fn accept(self: Listener, allocator: std.mem.Allocator) !Transport {
        return self.vtable.acceptFn(self.ptr, allocator);
    }

    pub fn close(self: Listener) void {
        self.vtable.closeFn(self.ptr);
    }
};
