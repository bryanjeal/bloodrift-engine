// Fixed-capacity associative store for sidecar systems.
//
// Sidecar systems (status effects, cooldowns, skill XP) run alongside
// Flecs but are not ECS components. They need:
//   - O(1) lookup by EntityId
//   - O(1) add/remove
//   - Fixed capacity, zero hot-path allocations
//   - Snapshot/restore for client-side rollback
//
// SidecarStore provides all of the above via a dense array + hash map
// pattern. The hash map maps EntityId → dense index. Remove uses
// swap-and-pop to keep the dense array contiguous.
//
// Snapshot support stores copies of the dense array + map state into a
// ring buffer, enabling rollback to any of the last N ticks.

const std = @import("std");
const types = @import("types/root.zig");
const EntityId = types.EntityId;
const Tick = types.Tick;

/// A fixed-capacity store keyed by EntityId with snapshot/restore support.
///
/// - `Entry`: the value type stored per entity.
/// - `capacity`: maximum number of entries (comptime).
/// - `snapshot_depth`: number of snapshots retained in the ring buffer.
///
/// All internal arrays are heap-allocated via the backing allocator passed
/// to init(). Zero allocations occur after init().
pub fn SidecarStore(comptime Entry: type, comptime capacity: u32, comptime snapshot_depth: u32) type {
    comptime {
        std.debug.assert(capacity > 0);
        std.debug.assert(snapshot_depth > 0);
    }

    // Hash map capacity: 2x entry capacity for ~0.5 load factor.
    const map_capacity: u32 = capacity * 2;
    const empty_slot: u32 = std.math.maxInt(u32);

    return struct {
        const Self = @This();

        /// Dense array of active entries.
        entries: *[capacity]Entry,
        /// Parallel array: the EntityId owning each dense slot.
        entry_ids: *[capacity]EntityId,
        /// Number of active entries.
        len: u32,
        /// Open-addressing hash map: EntityId → dense index.
        map_keys: *[map_capacity]EntityId,
        map_vals: *[map_capacity]u32,

        /// Ring buffer of snapshots for rollback.
        snap_entries: *[snapshot_depth][capacity]Entry,
        snap_ids: *[snapshot_depth][capacity]EntityId,
        snap_lens: *[snapshot_depth]u32,
        snap_ticks: *[snapshot_depth]Tick,
        snap_map_keys: *[snapshot_depth][map_capacity]EntityId,
        snap_map_vals: *[snapshot_depth][map_capacity]u32,
        snap_head: u32,
        snap_count: u32,

        /// Initialize the store, heap-allocating all internal arrays.
        /// The backing allocator is only used here and in deinit().
        pub fn init(alloc: std.mem.Allocator) !Self {
            const entries = try alloc.create([capacity]Entry);
            const entry_ids = try alloc.create([capacity]EntityId);
            errdefer alloc.destroy(entries);
            errdefer alloc.destroy(entry_ids);

            const map_keys = try alloc.create([map_capacity]EntityId);
            const map_vals = try alloc.create([map_capacity]u32);
            errdefer alloc.destroy(map_keys);
            errdefer alloc.destroy(map_vals);

            const snap_entries = try alloc.create([snapshot_depth][capacity]Entry);
            const snap_ids = try alloc.create([snapshot_depth][capacity]EntityId);
            const snap_lens = try alloc.create([snapshot_depth]u32);
            const snap_ticks = try alloc.create([snapshot_depth]Tick);
            const snap_map_keys = try alloc.create([snapshot_depth][map_capacity]EntityId);
            const snap_map_vals = try alloc.create([snapshot_depth][map_capacity]u32);
            errdefer alloc.destroy(snap_entries);
            errdefer alloc.destroy(snap_ids);
            errdefer alloc.destroy(snap_lens);
            errdefer alloc.destroy(snap_ticks);
            errdefer alloc.destroy(snap_map_keys);
            errdefer alloc.destroy(snap_map_vals);

            // Initialize hash map to empty.
            @memset(map_keys, types.entity_id_null);
            @memset(map_vals, empty_slot);
            @memset(snap_ticks, 0);
            @memset(snap_lens, 0);

            return .{
                .entries = entries,
                .entry_ids = entry_ids,
                .len = 0,
                .map_keys = map_keys,
                .map_vals = map_vals,
                .snap_entries = snap_entries,
                .snap_ids = snap_ids,
                .snap_lens = snap_lens,
                .snap_ticks = snap_ticks,
                .snap_map_keys = snap_map_keys,
                .snap_map_vals = snap_map_vals,
                .snap_head = 0,
                .snap_count = 0,
            };
        }

        /// Release all heap-allocated memory.
        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            alloc.destroy(self.entries);
            alloc.destroy(self.entry_ids);
            alloc.destroy(self.map_keys);
            alloc.destroy(self.map_vals);
            alloc.destroy(self.snap_entries);
            alloc.destroy(self.snap_ids);
            alloc.destroy(self.snap_lens);
            alloc.destroy(self.snap_ticks);
            alloc.destroy(self.snap_map_keys);
            alloc.destroy(self.snap_map_vals);
            self.* = undefined;
        }

        /// Add an entry for the given entity. Returns error if at capacity
        /// or if the entity already has an entry.
        pub fn add(self: *Self, entity: EntityId, entry: Entry) !void {
            std.debug.assert(types.entity_id_valid(entity));
            if (self.len >= capacity) return error.SidecarFull;
            if (self.mapLookup(entity) != null) return error.DuplicateEntity;

            const idx = self.len;
            self.entries[idx] = entry;
            self.entry_ids[idx] = entity;
            self.len += 1;
            self.mapInsert(entity, idx);
        }

        /// Get a mutable pointer to the entry for the given entity.
        /// Returns null if the entity has no entry.
        pub fn get(self: *Self, entity: EntityId) ?*Entry {
            const idx = self.mapLookup(entity) orelse return null;
            return &self.entries[idx];
        }

        /// Get a read-only pointer to the entry for the given entity.
        pub fn getConst(self: *const Self, entity: EntityId) ?*const Entry {
            const idx = self.mapLookupConst(entity) orelse return null;
            return &self.entries[idx];
        }

        /// Remove the entry for the given entity. Uses swap-and-pop to
        /// maintain dense array contiguity. Asserts the entity exists.
        pub fn remove(self: *Self, entity: EntityId) void {
            const idx = self.mapLookup(entity) orelse {
                std.debug.assert(false); // Entity not found.
                return;
            };
            self.mapRemove(entity);

            const last = self.len - 1;
            if (idx != last) {
                // Swap with the last entry.
                self.entries[idx] = self.entries[last];
                const moved_id = self.entry_ids[last];
                self.entry_ids[idx] = moved_id;
                // Update the map for the moved entity.
                self.mapUpdate(moved_id, idx);
            }
            self.len -= 1;
        }

        /// Check if the entity has an entry.
        pub fn contains(self: *const Self, entity: EntityId) bool {
            return self.mapLookupConst(entity) != null;
        }

        /// Save the current state as a snapshot for the given tick.
        /// Overwrites the oldest snapshot if the ring buffer is full.
        pub fn snapshot(self: *Self, tick: Tick) void {
            const slot = self.snap_head;
            const n = self.len;

            @memcpy(self.snap_entries[slot][0..n], self.entries[0..n]);
            @memcpy(self.snap_ids[slot][0..n], self.entry_ids[0..n]);
            self.snap_lens[slot] = n;
            self.snap_ticks[slot] = tick;
            self.snap_map_keys[slot] = self.map_keys.*;
            self.snap_map_vals[slot] = self.map_vals.*;

            self.snap_head = (self.snap_head + 1) % snapshot_depth;
            if (self.snap_count < snapshot_depth) {
                self.snap_count += 1;
            }
        }

        /// Restore state from the snapshot for the given tick.
        /// Returns true if the snapshot was found and restored, false otherwise.
        pub fn restore(self: *Self, tick: Tick) bool {
            // Search the ring buffer for the matching tick.
            var i: u32 = 0;
            while (i < self.snap_count) : (i += 1) {
                // Walk backward from most recent.
                const idx = (self.snap_head + snapshot_depth - 1 - i) %
                    snapshot_depth;
                if (self.snap_ticks[idx] == tick) {
                    const n = self.snap_lens[idx];
                    @memcpy(self.entries[0..n], self.snap_entries[idx][0..n]);
                    @memcpy(self.entry_ids[0..n], self.snap_ids[idx][0..n]);
                    self.len = n;
                    self.map_keys.* = self.snap_map_keys[idx];
                    self.map_vals.* = self.snap_map_vals[idx];
                    return true;
                }
            }
            return false;
        }

        /// Iterate over all active entries. Returns slices valid until
        /// the next mutation.
        pub fn items(self: *Self) []Entry {
            return self.entries[0..self.len];
        }

        /// Iterate over entity IDs paired with entries.
        pub fn entityIds(self: *Self) []EntityId {
            return self.entry_ids[0..self.len];
        }

        // --- Hash map internals (open addressing, linear probing) ---

        fn hashEntity(entity: EntityId) u32 {
            // Fibonacci hashing for good distribution.
            const h = @as(u32, @truncate(entity *% 0x9E3779B97F4A7C15));
            return h % map_capacity;
        }

        fn mapLookup(self: *Self, entity: EntityId) ?u32 {
            var slot = hashEntity(entity);
            var probes: u32 = 0;
            while (probes < map_capacity) : (probes += 1) {
                if (self.map_keys[slot] == entity) {
                    return self.map_vals[slot];
                }
                if (self.map_keys[slot] == types.entity_id_null) {
                    return null;
                }
                slot = (slot + 1) % map_capacity;
            }
            return null;
        }

        fn mapLookupConst(self: *const Self, entity: EntityId) ?u32 {
            var slot = hashEntity(entity);
            var probes: u32 = 0;
            while (probes < map_capacity) : (probes += 1) {
                if (self.map_keys[slot] == entity) {
                    return self.map_vals[slot];
                }
                if (self.map_keys[slot] == types.entity_id_null) {
                    return null;
                }
                slot = (slot + 1) % map_capacity;
            }
            return null;
        }

        fn mapInsert(self: *Self, entity: EntityId, dense_idx: u32) void {
            var slot = hashEntity(entity);
            while (self.map_keys[slot] != types.entity_id_null) {
                std.debug.assert(self.map_keys[slot] != entity);
                slot = (slot + 1) % map_capacity;
            }
            self.map_keys[slot] = entity;
            self.map_vals[slot] = dense_idx;
        }

        fn mapRemove(self: *Self, entity: EntityId) void {
            var slot = hashEntity(entity);
            while (self.map_keys[slot] != entity) {
                std.debug.assert(self.map_keys[slot] != types.entity_id_null);
                slot = (slot + 1) % map_capacity;
            }
            // Remove and fix the probe chain (backward shift deletion).
            self.map_keys[slot] = types.entity_id_null;
            self.map_vals[slot] = empty_slot;

            var next = (slot + 1) % map_capacity;
            while (self.map_keys[next] != types.entity_id_null) {
                const ideal = hashEntity(self.map_keys[next]);
                // If the entry at 'next' would not naturally probe through
                // 'slot', it needs to be moved backward.
                if (!probeWraps(ideal, slot, next)) {
                    self.map_keys[slot] = self.map_keys[next];
                    self.map_vals[slot] = self.map_vals[next];
                    self.map_keys[next] = types.entity_id_null;
                    self.map_vals[next] = empty_slot;
                    slot = next;
                }
                next = (next + 1) % map_capacity;
            }
        }

        fn mapUpdate(self: *Self, entity: EntityId, new_idx: u32) void {
            var slot = hashEntity(entity);
            while (self.map_keys[slot] != entity) {
                std.debug.assert(self.map_keys[slot] != types.entity_id_null);
                slot = (slot + 1) % map_capacity;
            }
            self.map_vals[slot] = new_idx;
        }

        /// Returns true if slot 'empty' is between 'ideal' and 'current'
        /// in the circular probe sequence.
        fn probeWraps(ideal: u32, empty: u32, current: u32) bool {
            if (ideal <= current) {
                return empty >= ideal and empty <= current;
            }
            // Wraps around: ideal > current.
            return empty >= ideal or empty <= current;
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

const TestStore = SidecarStore(TestEntry, 16, 4);

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
