// Regression tests for SidecarStore slice-accessor discipline.
//
// The 30Hz tick iterates sidecar data via `store.items()` / `store.entityIds()`.
// These return slices already bounded to the dense population count. A future
// refactor that accidentally exposed the raw backing array (length == capacity)
// would quietly iterate garbage slots - the items themselves are valid Entry
// structs but not populated. These tests pin the contract so that regression
// fails loudly.

const std = @import("std");
const sidecar_store = @import("sidecar_store.zig");
const types = @import("types/root.zig");
const EntityId = types.EntityId;

const TestEntry = struct {
    entity: EntityId,
    value: u32,
};

const TestStore = sidecar_store.SidecarStore(TestEntry, 16, 1024, 4);

test "SidecarStore_Items_ReturnsBoundedSlice" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var store = try TestStore.init(gpa.allocator());
    defer store.deinit(gpa.allocator());

    // Empty store: items().len must be zero, not the backing-array capacity.
    try std.testing.expectEqual(@as(usize, 0), store.items().len);
    try std.testing.expectEqual(@as(usize, 0), store.len());

    const n: u32 = 5;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const eid: EntityId = i + 1;
        try store.add(eid, .{ .entity = eid, .value = i });
    }

    // After N inserts: items().len == N and items().len == store.len().
    // If a regression returned the raw MultiArrayList backing slice, this
    // would fail because the backing length remains at capacity (16).
    try std.testing.expectEqual(@as(usize, n), store.len());
    try std.testing.expectEqual(store.len(), store.items().len);
    try std.testing.expectEqual(@as(usize, n), store.items().len);

    // After remove, items().len must drop in lock-step with len().
    store.remove(3);
    try std.testing.expectEqual(@as(usize, n - 1), store.len());
    try std.testing.expectEqual(store.len(), store.items().len);
}

test "SidecarStore_EntityIds_ReturnsBoundedSlice" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var store = try TestStore.init(gpa.allocator());
    defer store.deinit(gpa.allocator());

    // Empty store: entityIds().len must be zero.
    try std.testing.expectEqual(@as(usize, 0), store.entityIds().len);

    const n: u32 = 7;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const eid: EntityId = i + 100;
        try store.add(eid, .{ .entity = eid, .value = i });
    }

    // After N inserts: entityIds().len == N and matches len().
    try std.testing.expectEqual(@as(usize, n), store.len());
    try std.testing.expectEqual(store.len(), store.entityIds().len);
    try std.testing.expectEqual(@as(usize, n), store.entityIds().len);

    // items() and entityIds() must stay in lock-step index-wise.
    try std.testing.expectEqual(store.items().len, store.entityIds().len);

    // After swap-remove, both slices must shrink together.
    store.remove(102);
    try std.testing.expectEqual(store.len(), store.entityIds().len);
    try std.testing.expectEqual(store.items().len, store.entityIds().len);
}
