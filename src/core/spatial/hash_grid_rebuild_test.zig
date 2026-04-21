// Unit tests for hash_grid.zig - init, rebuild, and capacity cases.
//
// Cases 1-13 and 21-23 from the Phase B1 test spec.
// Cases 2, 3, 22, 23 are skipped: std.testing.expectPanic does not exist in
// Zig 0.15. The asserts they cover are verified by code inspection.

const std = @import("std");
const builtin = @import("builtin");
const hg = @import("hash_grid.zig");

const HashGrid = hg.HashGrid;
const Config = hg.Config;
const Position = hg.Position;
const EntityId = hg.EntityId;

const fp16_scale: i64 = 1 << 16;

fn fp(v: f64) i64 {
    return @intFromFloat(@round(v * @as(f64, @floatFromInt(fp16_scale))));
}

fn pos(x: f64, y: f64) Position {
    return .{ .x = fp(x), .y = fp(y), .z = 0 };
}

fn defaultCfg() Config {
    return .{
        .cell_size_raw = fp(1.0),
        .cell_count = 64,
        .max_entities = 128,
    };
}

// ---- 1. init_zeroed ----------------------------------------------------------

test "init_zeroed" {
    const allocator = std.testing.allocator;
    var grid = try HashGrid.init(allocator, .{
        .cell_size_raw = fp(1.0),
        .cell_count = 8,
        .max_entities = 64,
    });
    defer grid.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), grid.entry_count);
    try std.testing.expectEqual(@as(u64, 0), grid.last_rebuild_tick);
    try std.testing.expectEqual(@as(u32, 7), grid.hash_mask);
}

// ---- 2. init_asserts_power_of_two --------------------------------------------

test "init_asserts_power_of_two" {
    // cell_count=7 is not a power of two; assert fires in Debug/ReleaseSafe.
    // std.testing.expectPanic does not exist in Zig 0.15 - skip.
    // The guard is: assert(cell_count > 0 and (cell_count & (cell_count - 1)) == 0).
    return error.SkipZigTest;
}

// ---- 3. init_asserts_cell_size_positive --------------------------------------

test "init_asserts_cell_size_positive" {
    // assert(cell_size_raw > 0) fires in Debug/ReleaseSafe before any allocation.
    // std.testing.expectPanic does not exist in Zig 0.15 - skip.
    return error.SkipZigTest;
}

// ---- 4. rebuild_empty --------------------------------------------------------

test "rebuild_empty" {
    const allocator = std.testing.allocator;
    var grid = try HashGrid.init(allocator, defaultCfg());
    defer grid.deinit(allocator);

    grid.rebuild(&.{}, &.{}, &.{}, 42);

    try std.testing.expectEqual(@as(usize, 0), grid.entry_count);
    try std.testing.expectEqual(@as(u64, 42), grid.last_rebuild_tick);
    for (grid.cell_count) |c| try std.testing.expectEqual(@as(u32, 0), c);
    for (grid.cell_start) |s| try std.testing.expectEqual(@as(u32, 0), s);
}

// ---- 5. rebuild_single_origin -----------------------------------------------

test "rebuild_single_origin" {
    const allocator = std.testing.allocator;
    var grid = try HashGrid.init(allocator, defaultCfg());
    defer grid.deinit(allocator);

    const positions = [_]Position{pos(0.0, 0.0)};
    const entities = [_]EntityId{1};
    const factions = [_]u8{0};

    grid.rebuild(&positions, &entities, &factions, 1);

    const c = grid.computeCell(pos(0.0, 0.0));
    try std.testing.expectEqual(@as(u32, 1), grid.cell_count[c.h]);
    const e = grid.entries[grid.cell_start[c.h]];
    try std.testing.expectEqual(@as(EntityId, 1), e.id);
}

// ---- 6. rebuild_single_negative ---------------------------------------------

test "rebuild_single_negative" {
    // @divFloor must map (-0.5, -0.5) to cell (-1, -1), not (0, 0).
    const allocator = std.testing.allocator;
    var grid = try HashGrid.init(allocator, defaultCfg());
    defer grid.deinit(allocator);

    const positions = [_]Position{pos(-0.5, -0.5)};
    const entities = [_]EntityId{7};
    const factions = [_]u8{1};

    grid.rebuild(&positions, &entities, &factions, 1);

    const c = grid.computeCell(pos(-0.5, -0.5));
    try std.testing.expectEqual(@as(i64, -1), c.cx);
    try std.testing.expectEqual(@as(i64, -1), c.cy);
    try std.testing.expectEqual(@as(u32, 1), grid.cell_count[c.h]);
    const e = grid.entries[grid.cell_start[c.h]];
    try std.testing.expectEqual(@as(EntityId, 7), e.id);
}

// ---- 7. rebuild_two_same_cell -----------------------------------------------

test "rebuild_two_same_cell" {
    const allocator = std.testing.allocator;
    var grid = try HashGrid.init(allocator, defaultCfg());
    defer grid.deinit(allocator);

    // Both land in cell (0,0) with cell_size=1.0.
    const positions = [_]Position{ pos(0.1, 0.1), pos(0.9, 0.9) };
    const entities = [_]EntityId{ 10, 20 };
    const factions = [_]u8{ 0, 0 };

    grid.rebuild(&positions, &entities, &factions, 1);

    const c = grid.computeCell(pos(0.1, 0.1));
    try std.testing.expectEqual(@as(u32, 2), grid.cell_count[c.h]);

    const start = grid.cell_start[c.h];
    const a = grid.entries[start].id;
    const b = grid.entries[start + 1].id;
    try std.testing.expect((a == 10 and b == 20) or (a == 20 and b == 10));
}

// ---- 8. rebuild_two_different_cells -----------------------------------------

test "rebuild_two_different_cells" {
    const allocator = std.testing.allocator;
    var grid = try HashGrid.init(allocator, defaultCfg());
    defer grid.deinit(allocator);

    const positions = [_]Position{ pos(0.2, 0.2), pos(10.5, 10.5) };
    const entities = [_]EntityId{ 11, 22 };
    const factions = [_]u8{ 0, 0 };

    grid.rebuild(&positions, &entities, &factions, 1);

    const ca = grid.computeCell(pos(0.2, 0.2));
    const cb = grid.computeCell(pos(10.5, 10.5));
    // The two cells may hash to the same bucket (aliasing); verify each count >= 1
    // and the entities appear somewhere in their bucket slice.
    try std.testing.expect(grid.cell_count[ca.h] >= 1);
    try std.testing.expect(grid.cell_count[cb.h] >= 1);

    const slice_a = grid.entries[grid.cell_start[ca.h] .. grid.cell_start[ca.h] + grid.cell_count[ca.h]];
    var found_11 = false;
    for (slice_a) |e| if (e.id == 11) {
        found_11 = true;
    };
    try std.testing.expect(found_11);

    const slice_b = grid.entries[grid.cell_start[cb.h] .. grid.cell_start[cb.h] + grid.cell_count[cb.h]];
    var found_22 = false;
    for (slice_b) |e| if (e.id == 22) {
        found_22 = true;
    };
    try std.testing.expect(found_22);
}

// ---- 9. rebuild_stable_insertion_order --------------------------------------

test "rebuild_stable_insertion_order" {
    // Eight entities landing in two cells (4 each).
    // Verify source order within each cell is preserved (stable counting sort).
    const allocator = std.testing.allocator;
    var grid = try HashGrid.init(allocator, defaultCfg());
    defer grid.deinit(allocator);

    const positions = [_]Position{
        pos(0.1, 0.1), pos(1.1, 0.1),
        pos(0.2, 0.2), pos(1.2, 0.2),
        pos(0.3, 0.3), pos(1.3, 0.3),
        pos(0.4, 0.4), pos(1.4, 0.4),
    };
    const entities = [_]EntityId{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const factions = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };

    grid.rebuild(&positions, &entities, &factions, 1);

    const c00 = grid.computeCell(pos(0.1, 0.1));
    const c10 = grid.computeCell(pos(1.1, 0.1));

    const s0 = grid.cell_start[c00.h];
    const n0 = grid.cell_count[c00.h];
    var ids0 = [_]EntityId{0} ** 8;
    var cnt0: usize = 0;
    for (grid.entries[s0 .. s0 + n0]) |e| {
        if (e.id == 1 or e.id == 3 or e.id == 5 or e.id == 7) {
            ids0[cnt0] = e.id;
            cnt0 += 1;
        }
    }
    // Source order: 1, 3, 5, 7.
    try std.testing.expectEqual(@as(EntityId, 1), ids0[0]);
    try std.testing.expectEqual(@as(EntityId, 3), ids0[1]);
    try std.testing.expectEqual(@as(EntityId, 5), ids0[2]);
    try std.testing.expectEqual(@as(EntityId, 7), ids0[3]);

    const s1 = grid.cell_start[c10.h];
    const n1 = grid.cell_count[c10.h];
    var ids1 = [_]EntityId{0} ** 8;
    var cnt1: usize = 0;
    for (grid.entries[s1 .. s1 + n1]) |e| {
        if (e.id == 2 or e.id == 4 or e.id == 6 or e.id == 8) {
            ids1[cnt1] = e.id;
            cnt1 += 1;
        }
    }
    try std.testing.expectEqual(@as(EntityId, 2), ids1[0]);
    try std.testing.expectEqual(@as(EntityId, 4), ids1[1]);
    try std.testing.expectEqual(@as(EntityId, 6), ids1[2]);
    try std.testing.expectEqual(@as(EntityId, 8), ids1[3]);
}

// ---- 10. rebuild_double_rebuild_identical ------------------------------------

test "rebuild_double_rebuild_identical" {
    const allocator = std.testing.allocator;
    var grid = try HashGrid.init(allocator, defaultCfg());
    defer grid.deinit(allocator);

    const positions = [_]Position{ pos(0.5, 0.5), pos(2.5, 2.5), pos(-1.5, 3.0) };
    const entities = [_]EntityId{ 1, 2, 3 };
    const factions = [_]u8{ 0, 1, 0 };

    grid.rebuild(&positions, &entities, &factions, 1);

    const n = grid.entry_count;
    var entries_a: [128]hg.Entry = undefined;
    var cell_start_a: [64]u32 = undefined;
    var cell_count_a: [64]u32 = undefined;
    @memcpy(entries_a[0..n], grid.entries[0..n]);
    @memcpy(&cell_start_a, grid.cell_start);
    @memcpy(&cell_count_a, grid.cell_count);

    grid.rebuild(&positions, &entities, &factions, 2);

    try std.testing.expect(std.mem.eql(hg.Entry, entries_a[0..n], grid.entries[0..n]));
    try std.testing.expect(std.mem.eql(u32, &cell_start_a, grid.cell_start));
    try std.testing.expect(std.mem.eql(u32, &cell_count_a, grid.cell_count));
}

// ---- 11. rebuild_completeness -----------------------------------------------

test "rebuild_completeness" {
    const allocator = std.testing.allocator;
    var grid = try HashGrid.init(allocator, defaultCfg());
    defer grid.deinit(allocator);

    const N: usize = 64;
    var positions: [N]Position = undefined;
    var entities: [N]EntityId = undefined;
    var factions: [N]u8 = undefined;
    for (0..N) |i| {
        const fi: f64 = @floatFromInt(i);
        positions[i] = pos(@mod(fi * 0.7, 8.0), @mod(fi * 1.3, 8.0));
        entities[i] = i + 1;
        factions[i] = 0;
    }

    grid.rebuild(&positions, &entities, &factions, 1);

    var total: usize = 0;
    for (grid.cell_count) |c| total += c;
    try std.testing.expectEqual(N, total);

    var seen = [_]bool{false} ** (N + 1);
    for (grid.entries[0..grid.entry_count]) |e| {
        try std.testing.expect(e.id >= 1 and e.id <= N);
        try std.testing.expect(!seen[e.id]);
        seen[e.id] = true;
    }
    for (1..N + 1) |id| try std.testing.expect(seen[id]);
}

// ---- 12. rebuild_no_duplicates ----------------------------------------------

test "rebuild_no_duplicates" {
    const allocator = std.testing.allocator;
    var grid = try HashGrid.init(allocator, defaultCfg());
    defer grid.deinit(allocator);

    const positions = [_]Position{ pos(0.0, 0.0), pos(1.0, 0.0), pos(0.0, 1.0) };
    const entities = [_]EntityId{ 100, 200, 300 };
    const factions = [_]u8{ 0, 0, 0 };

    grid.rebuild(&positions, &entities, &factions, 1);

    var map = std.AutoHashMap(EntityId, void).init(allocator);
    defer map.deinit();

    for (grid.entries[0..grid.entry_count]) |e| {
        try std.testing.expect(!map.contains(e.id));
        try map.put(e.id, {});
    }
    try std.testing.expectEqual(@as(usize, 3), map.count());
}

// ---- 13. rebuild_cell_bucket_consistency ------------------------------------

test "rebuild_cell_bucket_consistency" {
    // For every non-empty cell h, every entry in its slice must hash to h.
    const allocator = std.testing.allocator;
    var grid = try HashGrid.init(allocator, defaultCfg());
    defer grid.deinit(allocator);

    const positions = [_]Position{
        pos(0.5, 0.5),   pos(1.5, 0.5),  pos(2.5, 2.5),
        pos(-0.5, -0.5), pos(3.5, -1.5),
    };
    const entities = [_]EntityId{ 1, 2, 3, 4, 5 };
    const factions = [_]u8{ 0, 0, 0, 0, 0 };

    grid.rebuild(&positions, &entities, &factions, 1);

    for (0..grid.cell_count.len) |h| {
        const cnt = grid.cell_count[h];
        if (cnt == 0) continue;
        const start = grid.cell_start[h];
        for (grid.entries[start .. start + cnt]) |e| {
            try std.testing.expectEqual(@as(u32, @intCast(h)), e.hash);
        }
    }
}

// ---- 21. rebuild_at_capacity ------------------------------------------------

test "rebuild_at_capacity" {
    const cap: u32 = 16;
    const allocator = std.testing.allocator;
    var grid = try HashGrid.init(allocator, .{
        .cell_size_raw = fp(1.0),
        .cell_count = 32,
        .max_entities = cap,
    });
    defer grid.deinit(allocator);

    var positions: [cap]Position = undefined;
    var entities: [cap]EntityId = undefined;
    var factions: [cap]u8 = undefined;
    for (0..cap) |i| {
        const fi: f64 = @floatFromInt(i);
        positions[i] = pos(fi, 0.0);
        entities[i] = i + 1;
        factions[i] = 0;
    }

    grid.rebuild(&positions, &entities, &factions, 1);
    try std.testing.expectEqual(@as(usize, cap), grid.entry_count);
}

// ---- 22. rebuild_over_capacity_panics ----------------------------------------

test "rebuild_over_capacity_panics" {
    // N > max_entities triggers assert(positions.len <= self.scratch.len).
    // std.testing.expectPanic does not exist in Zig 0.15 - skip.
    // The guard is: assert(positions.len <= self.scratch.len) in rebuild().
    return error.SkipZigTest;
}

// ---- 23. rebuild_mismatched_slice_lengths_panics ----------------------------

test "rebuild_mismatched_slice_lengths_panics" {
    // positions.len != entities.len triggers assert.
    // std.testing.expectPanic does not exist in Zig 0.15 - skip.
    // The guard is: assert(positions.len == entities.len) in rebuild().
    return error.SkipZigTest;
}
