// Fixed-capacity associative store for sidecar systems.
//
// Sidecar systems (status effects) run alongside
// Flecs but are not ECS components. They need:
//   - O(1) lookup by EntityId
//   - O(1) add/remove
//   - Fixed capacity, zero hot-path allocations
//   - Snapshot/restore for client-side rollback
//

const std = @import("std");
const types = @import("types/root.zig");
const EntityId = types.EntityId;
const Tick = types.Tick;

/// A fixed-capacity DOD Sparse Set keyed by EntityId with deterministic rollback support.
/// Utilizes a Structure of Arrays (SoA) layout via std.MultiArrayList for cache-perfect
/// contiguous iteration during the simulation tick.
///
/// Parameters:
/// - `Entry`: The struct type stored per entity.
/// - `capacity`: The maximum number of entries that can be active simultaneously.
/// - `max_entities`: The maximum possible entities in the zone (dictates sparse array size).
/// - `snapshot_depth`: Number of ticks to retain in the ring buffer for rollback.
pub fn SidecarStore(comptime Entry: type, comptime capacity: u32, comptime max_entities: u32, comptime snapshot_depth: u32) type {
    // Sentinel value indicating an empty slot in the sparse array.
    // Must be outside the valid range of dense indices.
    const empty_slot: u32 = std.math.maxInt(u32);

    comptime {
        std.debug.assert(capacity > 0);
        std.debug.assert(max_entities > 0);
        std.debug.assert(snapshot_depth > 0);

        // Ensure bounds are strictly less than maxInt(u32) so our empty_slot
        // sentinel can never mathematically collide with a valid dense index or entity index.
        std.debug.assert(capacity < empty_slot);
        std.debug.assert(max_entities < empty_slot);
        std.debug.assert(snapshot_depth < empty_slot);
    }

    // std.MultiArrayList splits this into parallel, contiguous arrays internally
    const DenseEntry = struct {
        id: EntityId,
        data: Entry,
    };

    const SidecarStorePrivate = struct {
        // 1. Structure of Arrays (SoA) Dense Store
        dense: std.MultiArrayList(DenseEntry),

        // 2. Direct O(1) Index Mapping. Size = max_entities.
        sparse: []u32,

        // 3. Snapshot Ring Buffers (Sparse array is dynamically rebuilt, never snapshotted)
        snap_data: *[snapshot_depth][capacity]Entry,
        snap_ids: *[snapshot_depth][capacity]EntityId,
        snap_lens: *[snapshot_depth]u32,
        snap_ticks: *[snapshot_depth]Tick,

        snap_head: u32,
        snap_count: u32,
    };

    return struct {
        const Self = @This();

        private: SidecarStorePrivate,

        /// Initializes the store, allocating all required dense arrays, sparse lookup tables,
        /// and rollback ring buffers upfront. Zero allocations occur on the hot path after this.
        pub fn init(alloc: std.mem.Allocator) !Self {
            var dense = std.MultiArrayList(DenseEntry){};
            try dense.ensureTotalCapacity(alloc, capacity);

            const sparse = try alloc.alloc(u32, max_entities);
            @memset(sparse, empty_slot);

            const snap_data = try alloc.create([snapshot_depth][capacity]Entry);
            const snap_ids = try alloc.create([snapshot_depth][capacity]EntityId);
            const snap_lens = try alloc.create([snapshot_depth]u32);
            const snap_ticks = try alloc.create([snapshot_depth]Tick);

            @memset(snap_ticks, 0);
            @memset(snap_lens, 0);

            return .{
                .private = .{
                    .dense = dense,
                    .sparse = sparse,
                    .snap_data = snap_data,
                    .snap_ids = snap_ids,
                    .snap_lens = snap_lens,
                    .snap_ticks = snap_ticks,
                    .snap_head = 0,
                    .snap_count = 0,
                },
            };
        }

        /// Frees all memory associated with the store. Must be called with the same
        /// allocator used during initialization.
        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            self.private.dense.deinit(alloc);
            alloc.free(self.private.sparse);
            alloc.destroy(self.private.snap_data);
            alloc.destroy(self.private.snap_ids);
            alloc.destroy(self.private.snap_lens);
            alloc.destroy(self.private.snap_ticks);
            self.* = undefined;
        }

        /// Adds a new entry for the given EntityId.
        /// Automatically purges ghost data if the Flecs entity generation counter has rolled over
        /// and a stale handle was left in the sidecar.
        pub fn add(self: *Self, entity: EntityId, entry: Entry) !void {
            std.debug.assert(types.entity_id_valid(entity));
            if (self.private.dense.len >= capacity) return error.SidecarFull;

            const sparse_idx: u32 = @truncate(entity);
            std.debug.assert(sparse_idx < max_entities);

            const existing_dense_idx = self.private.sparse[sparse_idx];
            if (existing_dense_idx != empty_slot) {
                const existing_entity = self.private.dense.items(.id)[existing_dense_idx];

                if (existing_entity == entity) {
                    return error.DuplicateEntity;
                } else {
                    // Stale generation handle detected. Flecs recycled the 32-bit index,
                    // but the old entity was never explicitly removed. Purge it.
                    self.remove(existing_entity);
                }
            }

            const dense_idx = @as(@TypeOf(capacity), @intCast(self.private.dense.len));
            self.private.dense.appendAssumeCapacity(.{ .id = entity, .data = entry });
            self.private.sparse[sparse_idx] = dense_idx;
        }

        /// Returns a mutable pointer to the entity's data, or null if it does not exist.
        /// Validates the generation counter to prevent reading stale entity data.
        pub fn get(self: *Self, entity: EntityId) ?*Entry {
            const index: u32 = @truncate(entity);
            std.debug.assert(index < max_entities);

            const dense_idx = self.private.sparse[index];
            if (dense_idx == empty_slot) return null;

            if (self.private.dense.items(.id)[dense_idx] != entity) return null;

            return &self.private.dense.items(.data)[dense_idx];
        }

        /// Returns a constant pointer to the entity's data, or null if it does not exist.
        /// Validates the generation counter to prevent reading stale entity data.
        pub fn getConst(self: *const Self, entity: EntityId) ?*const Entry {
            const index: u32 = @truncate(entity);
            std.debug.assert(index < max_entities);

            const dense_idx = self.private.sparse[index];
            if (dense_idx == empty_slot) return null;

            if (self.private.dense.items(.id)[dense_idx] != entity) return null;

            return &self.private.dense.items(.data)[dense_idx];
        }

        /// Returns true if the store currently holds valid data for the specific EntityId generation.
        pub fn contains(self: *const Self, entity: EntityId) bool {
            return self.getConst(entity) != null;
        }

        /// Removes the entity's data from the store in O(1) time using a swap-and-pop operation
        /// to ensure the dense array remains perfectly contiguous.
        pub fn remove(self: *Self, entity: EntityId) void {
            const index: u32 = @truncate(entity);
            std.debug.assert(index < max_entities);

            const dense_idx = self.private.sparse[index];
            if (dense_idx == empty_slot) return;

            // Swap and pop the dense array
            self.private.dense.swapRemove(dense_idx);

            // Re-point the sparse array for the element that got moved into the deleted slot
            if (dense_idx < self.private.dense.len) {
                const moved_entity = self.private.dense.items(.id)[dense_idx];
                const moved_index: u32 = @truncate(moved_entity);
                self.private.sparse[moved_index] = dense_idx;
            }

            self.private.sparse[index] = empty_slot;
        }

        /// Returns a tightly packed, contiguous slice of all active data entries.
        /// This is the primary iteration path for the 30Hz simulation tick.
        pub inline fn items(self: *Self) []Entry {
            return self.private.dense.items(.data);
        }

        /// Returns a tightly packed, contiguous slice of the EntityIds that own the active data entries.
        /// Indices align perfectly with the slice returned by `items()`.
        pub inline fn entityIds(self: *Self) []EntityId {
            return self.private.dense.items(.id);
        }

        /// Returns the number of active entries.
        pub inline fn len(self: *Self) @TypeOf(capacity) {
            return @as(@TypeOf(capacity), @intCast(self.private.dense.len));
        }

        /// Saves the current dense state into the ring buffer mapped to the given simulation tick.
        /// Executes a fast block memory copy. Does NOT snapshot the sparse lookup array.
        pub fn snapshot(self: *Self, tick: Tick) void {
            const slot = self.private.snap_head;
            const n = @as(u32, @intCast(self.private.dense.len));

            @memcpy(self.private.snap_data[slot][0..n], self.private.dense.items(.data));
            @memcpy(self.private.snap_ids[slot][0..n], self.private.dense.items(.id));

            self.private.snap_lens[slot] = n;
            self.private.snap_ticks[slot] = tick;

            self.private.snap_head = (self.private.snap_head + 1) % snapshot_depth;
            if (self.private.snap_count < snapshot_depth) {
                self.private.snap_count += 1;
            }
        }

        /// Restores the store to the exact state of the provided tick, if it exists in the ring buffer.
        /// Dynamically rebuilds the sparse lookup array from the restored dense entity IDs.
        /// Returns true if the restore was successful, false if the tick was not found.
        pub fn restore(self: *Self, tick: Tick) bool {
            var i: u32 = 0;
            while (i < self.private.snap_count) : (i += 1) {
                const idx = (self.private.snap_head + snapshot_depth - 1 - i) % snapshot_depth;

                if (self.private.snap_ticks[idx] == tick) {
                    const n = self.private.snap_lens[idx];

                    // 1. Restore the contiguous dense state
                    self.private.dense.len = n;
                    @memcpy(self.private.dense.items(.data)[0..n], self.private.snap_data[idx][0..n]);
                    @memcpy(self.private.dense.items(.id)[0..n], self.private.snap_ids[idx][0..n]);

                    // 2. Dynamically rebuild the sparse lookups
                    @memset(self.private.sparse, empty_slot);
                    for (self.private.dense.items(.id)[0..n], 0..) |ent, dense_idx| {
                        const sparse_idx: u32 = @truncate(ent);
                        self.private.sparse[sparse_idx] = @as(u32, @intCast(dense_idx));
                    }

                    return true;
                }
            }
            return false;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const TestEntry = struct {
    entity: EntityId,
    value: u32,
};

const TestStore = SidecarStore(TestEntry, 16, 32, 4);

test "SidecarStore: add and get" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var store = try TestStore.init(gpa.allocator());
    defer store.deinit(gpa.allocator());

    try store.add(100, .{ .entity = 100, .value = 42 });
    const entry = store.get(100).?;
    try std.testing.expectEqual(@as(u32, 42), entry.value);
    try std.testing.expectEqual(@as(u32, 1), store.len);
}

test "SidecarStore: remove with swap-and-pop" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var store = try TestStore.init(gpa.allocator());
    defer store.deinit(gpa.allocator());

    try store.add(1, .{ .entity = 1, .value = 10 });
    try store.add(2, .{ .entity = 2, .value = 20 });
    try store.add(3, .{ .entity = 3, .value = 30 });

    store.remove(1);

    // Entity 1 gone, 2 and 3 still present.
    try std.testing.expect(!store.contains(1));
    try std.testing.expect(store.contains(2));
    try std.testing.expect(store.contains(3));
    try std.testing.expectEqual(@as(u32, 2), store.len);

    // Values preserved after swap.
    try std.testing.expectEqual(@as(u32, 20), store.get(2).?.value);
    try std.testing.expectEqual(@as(u32, 30), store.get(3).?.value);
}

test "SidecarStore: capacity exhaustion" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var store = try TestStore.init(gpa.allocator());
    defer store.deinit(gpa.allocator());

    // Fill to capacity.
    for (0..16) |i| {
        const eid: EntityId = @intCast(i + 1);
        try store.add(eid, .{ .entity = eid, .value = @intCast(i) });
    }
    try std.testing.expectEqual(@as(u32, 16), store.len);

    // One more should fail.
    const result = store.add(999, .{ .entity = 999, .value = 0 });
    try std.testing.expectError(error.SidecarFull, result);
}

test "SidecarStore: duplicate entity rejected" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var store = try TestStore.init(gpa.allocator());
    defer store.deinit(gpa.allocator());

    try store.add(42, .{ .entity = 42, .value = 1 });
    const result = store.add(42, .{ .entity = 42, .value = 2 });
    try std.testing.expectError(error.DuplicateEntity, result);
}

test "SidecarStore: remove and re-add reuses slots" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var store = try TestStore.init(gpa.allocator());
    defer store.deinit(gpa.allocator());

    try store.add(1, .{ .entity = 1, .value = 10 });
    store.remove(1);
    try std.testing.expectEqual(@as(u32, 0), store.len);

    // Re-add same entity.
    try store.add(1, .{ .entity = 1, .value = 99 });
    try std.testing.expectEqual(@as(u32, 1), store.len);
    try std.testing.expectEqual(@as(u32, 99), store.get(1).?.value);
}

test "SidecarStore: snapshot and restore roundtrip" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var store = try TestStore.init(gpa.allocator());
    defer store.deinit(gpa.allocator());

    // Add entries and snapshot at tick 10.
    try store.add(1, .{ .entity = 1, .value = 100 });
    try store.add(2, .{ .entity = 2, .value = 200 });
    store.snapshot(10);

    // Modify: remove entity 1, change entity 2, add entity 3.
    store.remove(1);
    store.get(2).?.value = 999;
    try store.add(3, .{ .entity = 3, .value = 300 });

    // Verify modified state.
    try std.testing.expectEqual(@as(u32, 2), store.len);
    try std.testing.expect(!store.contains(1));
    try std.testing.expectEqual(@as(u32, 999), store.get(2).?.value);

    // Restore to tick 10.
    try std.testing.expect(store.restore(10));

    // Original state restored.
    try std.testing.expectEqual(@as(u32, 2), store.len);
    try std.testing.expect(store.contains(1));
    try std.testing.expect(store.contains(2));
    try std.testing.expect(!store.contains(3));
    try std.testing.expectEqual(@as(u32, 100), store.get(1).?.value);
    try std.testing.expectEqual(@as(u32, 200), store.get(2).?.value);
}

test "SidecarStore: ring buffer overwrites oldest" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    // snapshot_depth = 4, so 5th snapshot overwrites the 1st.
    var store = try TestStore.init(gpa.allocator());
    defer store.deinit(gpa.allocator());

    try store.add(1, .{ .entity = 1, .value = 0 });

    // Take snapshots at ticks 1..5.
    for (1..6) |tick| {
        store.get(1).?.value = @intCast(tick);
        store.snapshot(@intCast(tick));
    }

    // Tick 1 should be overwritten by tick 5.
    try std.testing.expect(!store.restore(1));
    // Ticks 2..5 should still be available.
    try std.testing.expect(store.restore(2));
    try std.testing.expectEqual(@as(u32, 2), store.get(1).?.value);
}

test "SidecarStore: restore non-existent tick returns false" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var store = try TestStore.init(gpa.allocator());
    defer store.deinit(gpa.allocator());

    try std.testing.expect(!store.restore(42));
}

test "SidecarStore: items iterates all active entries" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var store = try TestStore.init(gpa.allocator());
    defer store.deinit(gpa.allocator());

    try store.add(10, .{ .entity = 10, .value = 1 });
    try store.add(20, .{ .entity = 20, .value = 2 });
    try store.add(30, .{ .entity = 30, .value = 3 });

    const entries = store.items();
    try std.testing.expectEqual(@as(usize, 3), entries.len);

    // Sum values to verify all entries are present.
    var sum: u32 = 0;
    for (entries) |e| sum += e.value;
    try std.testing.expectEqual(@as(u32, 6), sum);
}

test "SidecarStore: get returns null for missing entity" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var store = try TestStore.init(gpa.allocator());
    defer store.deinit(gpa.allocator());

    try std.testing.expect(store.get(999) == null);
}
