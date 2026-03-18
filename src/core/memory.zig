// Arena and pool allocators for zero-allocation hot paths.
//
// Design principles:
//   - All capacity is decided at init time. No growth, no reallocation.
//   - Pass allocators explicitly — no global allocator state.
//   - ArenaAllocator: bump allocator, reset cheaply each frame.
//   - PoolAllocator: fixed-size slot allocator for homogeneous objects.
//
// Both allocators are not thread-safe. Synchronization is the caller's
// responsibility if used from multiple threads.

const std = @import("std");
const types = @import("types.zig");

// ----------------------------------------------------------------------------
// ArenaAllocator
// ----------------------------------------------------------------------------

/// A bump allocator backed by a fixed-size byte buffer.
///
/// All allocations advance a cursor forward through the buffer. Reset() rewinds
/// the cursor to zero in O(1), effectively freeing all allocations at once.
/// Suitable for per-frame temporary allocations that are discarded each tick.
///
/// Invariants:
///   - cursor <= buffer.len at all times
///   - No individual free() is supported; use reset() to reclaim everything
pub const ArenaAllocator = struct {
    buffer: []u8,
    cursor: usize,

    /// Initialize the arena, taking ownership of the provided backing buffer.
    /// The buffer must outlive the arena. Typically backed by a []u8 allocated
    /// once at startup from the parent allocator.
    pub fn init(buffer: []u8) ArenaAllocator {
        std.debug.assert(buffer.len > 0);
        return .{ .buffer = buffer, .cursor = 0 };
    }

    /// Return an std.mem.Allocator interface backed by this arena.
    pub fn allocator(self: *ArenaAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    /// Reset the cursor to zero, making the entire buffer available again.
    /// All pointers into the arena are invalidated after this call.
    pub fn reset(self: *ArenaAllocator) void {
        self.cursor = 0;
    }

    /// Return the number of bytes currently allocated.
    pub fn used(self: *const ArenaAllocator) usize {
        return self.cursor;
    }

    /// Return the total capacity of the backing buffer.
    pub fn capacity(self: *const ArenaAllocator) usize {
        return self.buffer.len;
    }

    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *ArenaAllocator = @ptrCast(@alignCast(ctx));
        const align_val = alignment.toByteUnits();
        // Align the cursor up to the required alignment.
        const aligned_cursor = std.mem.alignForward(usize, self.cursor, align_val);
        const new_cursor = aligned_cursor + n;
        if (new_cursor > self.buffer.len) return null;
        self.cursor = new_cursor;
        return self.buffer[aligned_cursor..new_cursor].ptr;
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        // The arena does not support resize.
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        // The arena does not support remap.
        return null;
    }

    fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {
        // Individual frees are no-ops; use reset() to reclaim all memory.
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

// ----------------------------------------------------------------------------
// PoolAllocator
// ----------------------------------------------------------------------------

/// A fixed-capacity slot allocator for homogeneous objects of type T.
///
/// Pre-allocates capacity slots at init time. alloc() returns a pointer to a
/// free slot in O(1) via a free-list. free() returns the slot to the free-list
/// in O(1). No fragmentation; capacity is always the total number of slots.
///
/// Invariants:
///   - len <= capacity at all times
///   - Freeing a slot that is not currently allocated is a programming error
///     (caught by assertion in safe build modes)
pub fn PoolAllocator(comptime T: type) type {
    return struct {
        const Self = @This();

        // Each slot is either occupied (holds a T) or free (holds the index of
        // the next free slot in the free-list chain, or free_list_end).
        const Slot = union(enum) {
            occupied: T,
            free: u32,
        };

        const free_list_end: u32 = std.math.maxInt(u32);

        slots: []Slot,
        free_head: u32,
        len: u32,

        /// Initialize the pool, allocating `cap` slots from `backing_allocator`.
        /// `backing_allocator` is only used during init/deinit.
        pub fn init(backing_allocator: std.mem.Allocator, cap: u32) !Self {
            std.debug.assert(cap > 0);
            const slots = try backing_allocator.alloc(Slot, cap);
            // Build the initial free-list: slot i points to slot i+1.
            for (slots, 0..) |*slot, i| {
                const next: u32 = if (i + 1 < cap) @intCast(i + 1) else free_list_end;
                slot.* = .{ .free = next };
            }
            return .{
                .slots = slots,
                .free_head = 0,
                .len = 0,
            };
        }

        pub fn deinit(self: *Self, backing_allocator: std.mem.Allocator) void {
            backing_allocator.free(self.slots);
            self.* = undefined;
        }

        /// Allocate one slot. Returns null if the pool is exhausted.
        pub fn alloc(self: *Self) ?*T {
            if (self.free_head == free_list_end) return null;
            const idx = self.free_head;
            const slot = &self.slots[idx];
            self.free_head = slot.free;
            slot.* = .{ .occupied = undefined };
            self.len += 1;
            return &slot.occupied;
        }

        /// Return a slot to the pool.
        /// Asserts that the pointer actually belongs to this pool's backing array.
        pub fn free(self: *Self, ptr: *T) void {
            // Verify the pointer is within our backing array.
            const base = @intFromPtr(self.slots.ptr);
            const p = @intFromPtr(ptr);
            std.debug.assert(p >= base);
            const byte_offset = p - base;
            std.debug.assert(byte_offset % @sizeOf(Slot) == 0);
            const idx: u32 = @intCast(byte_offset / @sizeOf(Slot));
            std.debug.assert(idx < self.slots.len);
            // Use switch to test the active tag only — payload equality is irrelevant here.
            std.debug.assert(switch (self.slots[idx]) {
                .occupied => true,
                .free => false,
            });
            self.slots[idx] = .{ .free = self.free_head };
            self.free_head = idx;
            self.len -= 1;
        }

        /// Return the maximum number of slots this pool can hold.
        pub fn capacity(self: *const Self) u32 {
            return @intCast(self.slots.len);
        }
    };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "ArenaAllocator: basic alloc and reset" {
    var backing: [1024]u8 = undefined;
    var arena = ArenaAllocator.init(&backing);
    const alloc = arena.allocator();

    const a = try alloc.create(u64);
    a.* = 42;
    try std.testing.expect(arena.used() >= @sizeOf(u64));

    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.used());
}

test "ArenaAllocator: alignment is honoured" {
    var backing: [1024]u8 = undefined;
    var arena = ArenaAllocator.init(&backing);
    const alloc = arena.allocator();

    _ = try alloc.create(u8); // misalign cursor intentionally
    const ptr = try alloc.create(u64);
    // Pointer must be 8-byte aligned.
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(ptr) % @alignOf(u64));
}

test "ArenaAllocator: returns null when exhausted" {
    var backing: [8]u8 = undefined;
    var arena = ArenaAllocator.init(&backing);
    const alloc = arena.allocator();

    // A 16-byte alloc must fail on an 8-byte arena.
    const result = alloc.alloc(u8, 16);
    try std.testing.expectError(error.OutOfMemory, result);
}

test "ArenaAllocator: reset allows reuse" {
    var backing: [64]u8 = undefined;
    var arena = ArenaAllocator.init(&backing);
    const alloc = arena.allocator();

    const a = try alloc.create(u32);
    a.* = 1;
    arena.reset();
    const b = try alloc.create(u32);
    b.* = 2;
    // After reset the arena hands out the same memory again.
    try std.testing.expectEqual(@intFromPtr(a), @intFromPtr(b));
}

test "PoolAllocator: alloc and free cycle" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const backing = gpa.allocator();

    const Pool = PoolAllocator(types.EntityId);
    var pool = try Pool.init(backing, 4);
    defer pool.deinit(backing);

    const a = pool.alloc().?;
    a.* = 1;
    const b = pool.alloc().?;
    b.* = 2;
    try std.testing.expectEqual(@as(u32, 2), pool.len);

    pool.free(a);
    try std.testing.expectEqual(@as(u32, 1), pool.len);

    // After freeing, the slot should be reusable.
    const c = pool.alloc().?;
    c.* = 3;
    try std.testing.expectEqual(@as(u32, 2), pool.len);
}

test "PoolAllocator: exhaustion returns null" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const backing = gpa.allocator();

    const Pool = PoolAllocator(u32);
    var pool = try Pool.init(backing, 2);
    defer pool.deinit(backing);

    _ = pool.alloc().?;
    _ = pool.alloc().?;
    // Third alloc must return null.
    try std.testing.expectEqual(@as(?*u32, null), pool.alloc());
}

test "PoolAllocator: capacity unchanged after alloc/free" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const backing = gpa.allocator();

    const Pool = PoolAllocator(u64);
    var pool = try Pool.init(backing, 8);
    defer pool.deinit(backing);

    try std.testing.expectEqual(@as(u32, 8), pool.capacity());
    const p = pool.alloc().?;
    p.* = 99;
    pool.free(p);
    try std.testing.expectEqual(@as(u32, 8), pool.capacity());
}

test "ArenaAllocator: exactly fills buffer" {
    // Allocating exactly capacity bytes must succeed; one more byte must fail.
    var backing: [32]u8 = undefined;
    var arena = ArenaAllocator.init(&backing);
    const alloc = arena.allocator();

    const slice = try alloc.alloc(u8, 32);
    try std.testing.expectEqual(@as(usize, 32), slice.len);
    try std.testing.expectEqual(arena.used(), arena.capacity());

    const extra = alloc.alloc(u8, 1);
    try std.testing.expectError(error.OutOfMemory, extra);
}

test "ArenaAllocator: used and capacity invariant" {
    var backing: [256]u8 = undefined;
    var arena = ArenaAllocator.init(&backing);
    const alloc = arena.allocator();

    try std.testing.expectEqual(@as(usize, 256), arena.capacity());
    try std.testing.expectEqual(@as(usize, 0), arena.used());

    _ = try alloc.create(u64);
    try std.testing.expect(arena.used() > 0);
    try std.testing.expect(arena.used() <= arena.capacity());

    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.used());
    try std.testing.expectEqual(@as(usize, 256), arena.capacity());
}

test "ArenaAllocator: multiple resets restore full capacity" {
    var backing: [128]u8 = undefined;
    var arena = ArenaAllocator.init(&backing);
    const alloc = arena.allocator();

    for (0..5) |_| {
        _ = try alloc.alloc(u8, 64);
        try std.testing.expect(arena.used() >= 64);
        arena.reset();
        try std.testing.expectEqual(@as(usize, 0), arena.used());
        // After reset, a full-capacity alloc must succeed again.
        _ = try alloc.alloc(u8, 128);
        arena.reset();
    }
}

test "PoolAllocator: capacity = 1 edge case" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const backing = gpa.allocator();

    const Pool = PoolAllocator(u32);
    var pool = try Pool.init(backing, 1);
    defer pool.deinit(backing);

    try std.testing.expectEqual(@as(u32, 1), pool.capacity());
    try std.testing.expectEqual(@as(u32, 0), pool.len);

    const p = pool.alloc().?;
    p.* = 7;
    try std.testing.expectEqual(@as(u32, 1), pool.len);

    // Exhausted after first alloc.
    try std.testing.expectEqual(@as(?*u32, null), pool.alloc());

    // Free and re-alloc.
    pool.free(p);
    try std.testing.expectEqual(@as(u32, 0), pool.len);

    const q = pool.alloc().?;
    q.* = 99;
    try std.testing.expectEqual(@as(u32, 1), pool.len);
}

test "PoolAllocator: fill all, free all, fill all again" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const backing = gpa.allocator();

    const cap: u32 = 8;
    const Pool = PoolAllocator(u64);
    var pool = try Pool.init(backing, cap);
    defer pool.deinit(backing);

    // Fill to capacity.
    var ptrs: [cap]*u64 = undefined;
    for (0..cap) |i| {
        ptrs[i] = pool.alloc().?;
        ptrs[i].* = @intCast(i);
    }
    try std.testing.expectEqual(cap, pool.len);
    try std.testing.expectEqual(@as(?*u64, null), pool.alloc());

    // Free all.
    for (0..cap) |i| pool.free(ptrs[i]);
    try std.testing.expectEqual(@as(u32, 0), pool.len);

    // Fill again — all cap slots must be available.
    for (0..cap) |i| {
        ptrs[i] = pool.alloc().?;
        ptrs[i].* = @intCast(i + 100);
    }
    try std.testing.expectEqual(cap, pool.len);
    // Values are correctly written in the second fill.
    for (0..cap) |i| {
        try std.testing.expectEqual(@as(u64, @intCast(i + 100)), ptrs[i].*);
    }
}

test "PoolAllocator: len tracks correctly across interleaved alloc/free" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const backing = gpa.allocator();

    const Pool = PoolAllocator(u32);
    var pool = try Pool.init(backing, 4);
    defer pool.deinit(backing);

    const a = pool.alloc().?;
    const b = pool.alloc().?;
    const c = pool.alloc().?;
    try std.testing.expectEqual(@as(u32, 3), pool.len);

    pool.free(b);
    try std.testing.expectEqual(@as(u32, 2), pool.len);

    const d = pool.alloc().?;
    _ = d;
    try std.testing.expectEqual(@as(u32, 3), pool.len);

    pool.free(a);
    pool.free(c);
    try std.testing.expectEqual(@as(u32, 1), pool.len);
}
