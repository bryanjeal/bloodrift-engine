// Unit tests for hash_grid.zig - visitInRadius, alloc, and determinism cases.
//
// Cases 14-20, 24, 25 from the Phase B1 test spec.
// Cases 15, 16 are skipped: std.testing.expectPanic does not exist in Zig 0.15.
// The asserts they cover are verified by code inspection.

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

// ---- 14. visit_radius_basic -------------------------------------------------

test "visit_radius_basic" {
    const allocator = std.testing.allocator;
    var grid = try HashGrid.init(allocator, defaultCfg());
    defer grid.deinit(allocator);

    const positions = [_]Position{pos(0.0, 0.0)};
    const entities = [_]EntityId{42};
    const factions = [_]u8{0};
    grid.rebuild(&positions, &entities, &factions, 1);

    var count: usize = 0;
    var found_id: EntityId = 0;

    const Ctx = struct { count: *usize, id: *EntityId };
    var ctx = Ctx{ .count = &count, .id = &found_id };
    grid.visitInRadius(pos(0.0, 0.0), fp(0.5), &ctx, struct {
        fn cb(raw: *anyopaque, id: EntityId, faction: u8) void {
            _ = faction;
            const c: *Ctx = @ptrCast(@alignCast(raw));
            c.count.* += 1;
            c.id.* = id;
        }
    }.cb);

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(EntityId, 42), found_id);
}

// ---- 15. visit_radius_no_rebuild_asserts ------------------------------------

test "visit_radius_no_rebuild_asserts" {
    // PRE-27.4a: calling visitInRadius before any rebuild must assert.
    // std.testing.expectPanic does not exist in Zig 0.15 - skip.
    // The guard is: assert(rebuild_count > 0) in visitInRadius().
    return error.SkipZigTest;
}

// ---- 16. visit_radius_zero_panics -------------------------------------------

test "visit_radius_zero_panics" {
    // PRE-27.3: radius_raw <= 0 must assert.
    // std.testing.expectPanic does not exist in Zig 0.15 - skip.
    // The guard is: assert(radius_raw > 0) in visitInRadius().
    return error.SkipZigTest;
}

// ---- 17. visit_radius_nine_cell_coverage ------------------------------------

test "visit_radius_nine_cell_coverage" {
    // Entity at (0.1, 0.1); query at (2.5, 2.5) radius 3.5 covers an AABB that
    // includes the cell containing (0.1, 0.1). Callback must fire for entity 99.
    const allocator = std.testing.allocator;
    var grid = try HashGrid.init(allocator, defaultCfg());
    defer grid.deinit(allocator);

    const positions = [_]Position{pos(0.1, 0.1)};
    const entities = [_]EntityId{99};
    const factions = [_]u8{0};
    grid.rebuild(&positions, &entities, &factions, 1);

    var found = false;
    grid.visitInRadius(pos(2.5, 2.5), fp(3.5), &found, struct {
        fn cb(raw: *anyopaque, id: EntityId, faction: u8) void {
            _ = faction;
            if (id == 99) @as(*bool, @ptrCast(@alignCast(raw))).* = true;
        }
    }.cb);

    try std.testing.expect(found);
}

// ---- 18. visit_radius_negative_coords ---------------------------------------

test "visit_radius_negative_coords" {
    // Mix of negative and positive coords; query straddles zero. @divFloor regression.
    const allocator = std.testing.allocator;
    var grid = try HashGrid.init(allocator, defaultCfg());
    defer grid.deinit(allocator);

    const positions = [_]Position{
        pos(-1.5, -1.5),
        pos(1.5, 1.5),
        pos(-0.5, 0.5),
    };
    const entities = [_]EntityId{ 1, 2, 3 };
    const factions = [_]u8{ 0, 0, 0 };
    grid.rebuild(&positions, &entities, &factions, 1);

    var count: usize = 0;
    grid.visitInRadius(pos(0.0, 0.0), fp(2.5), &count, struct {
        fn cb(raw: *anyopaque, id: EntityId, faction: u8) void {
            _ = id;
            _ = faction;
            @as(*usize, @ptrCast(@alignCast(raw))).* += 1;
        }
    }.cb);

    try std.testing.expect(count >= 3);
}

// ---- 19. visit_radius_empty_region ------------------------------------------

test "visit_radius_empty_region" {
    // Entity is far from the query region. Hash aliasing aside, the specific
    // cells covered by the query are all empty, so count should be 0.
    const allocator = std.testing.allocator;
    // Large bucket count reduces aliasing probability to zero for this case.
    var grid = try HashGrid.init(allocator, .{
        .cell_size_raw = fp(1.0),
        .cell_count = 1024,
        .max_entities = 128,
    });
    defer grid.deinit(allocator);

    const positions = [_]Position{pos(100.0, 100.0)};
    const entities = [_]EntityId{1};
    const factions = [_]u8{0};
    grid.rebuild(&positions, &entities, &factions, 1);

    var count: usize = 0;
    // Query far from entity; with 1024 buckets the distant cell will not alias.
    grid.visitInRadius(pos(-100.0, -100.0), fp(0.5), &count, struct {
        fn cb(raw: *anyopaque, id: EntityId, faction: u8) void {
            _ = id;
            _ = faction;
            @as(*usize, @ptrCast(@alignCast(raw))).* += 1;
        }
    }.cb);

    try std.testing.expectEqual(@as(usize, 0), count);
}

// ---- 20. visit_radius_hash_aliasing_ok --------------------------------------

test "visit_radius_hash_aliasing_ok" {
    // Two far-apart entities that may hash to the same bucket.
    // Query near the first entity; callback fires for the nearby one.
    const allocator = std.testing.allocator;
    var grid = try HashGrid.init(allocator, .{
        .cell_size_raw = fp(1.0),
        .cell_count = 4, // small bucket count forces aliasing
        .max_entities = 16,
    });
    defer grid.deinit(allocator);

    const positions = [_]Position{ pos(0.5, 0.5), pos(100.5, 100.5) };
    const entities = [_]EntityId{ 1, 2 };
    const factions = [_]u8{ 0, 1 };
    grid.rebuild(&positions, &entities, &factions, 1);

    var found_near = false;
    grid.visitInRadius(pos(0.5, 0.5), fp(0.6), &found_near, struct {
        fn cb(raw: *anyopaque, id: EntityId, faction: u8) void {
            _ = faction;
            if (id == 1) @as(*bool, @ptrCast(@alignCast(raw))).* = true;
        }
    }.cb);

    try std.testing.expect(found_near);
}

// ---- 24. alloc_once_only -----------------------------------------------------

// CountingAllocator wraps a parent and increments alloc_count on every alloc
// call (resize and free do not count as allocations). Used to prove POST-27.3.
const CountingAllocator = struct {
    parent: std.mem.Allocator,
    alloc_count: usize,

    fn init(parent: std.mem.Allocator) CountingAllocator {
        return .{ .parent = parent, .alloc_count = 0 };
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.alloc_count += 1;
        return self.parent.rawAlloc(n, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.parent.rawResize(buf, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.parent.rawRemap(buf, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.parent.rawFree(buf, alignment, ret_addr);
    }
};

test "alloc_once_only" {
    // POST-27.3: rebuild and visitInRadius must perform zero allocations.
    // CountingAllocator wraps GPA; alloc_count after init must not rise during
    // subsequent rebuild/visit calls.
    var counting = CountingAllocator.init(std.testing.allocator);
    const alloc = counting.allocator();

    var grid = try HashGrid.init(alloc, defaultCfg());
    defer grid.deinit(alloc);

    // Snapshot alloc count after init; all four backing arrays are allocated here.
    const count_after_init = counting.alloc_count;
    try std.testing.expect(count_after_init > 0);

    const positions = [_]Position{ pos(0.5, 0.5), pos(1.5, 1.5) };
    const entities = [_]EntityId{ 1, 2 };
    const factions = [_]u8{ 0, 0 };

    // Ten rebuilds + ten visits - alloc_count must not change (POST-27.3).
    for (0..10) |tick| {
        grid.rebuild(&positions, &entities, &factions, tick + 1);
        var dummy: usize = 0;
        grid.visitInRadius(pos(0.0, 0.0), fp(2.0), &dummy, struct {
            fn cb(raw: *anyopaque, id: EntityId, faction: u8) void {
                _ = id;
                _ = faction;
                @as(*usize, @ptrCast(@alignCast(raw))).* += 1;
            }
        }.cb);
    }

    try std.testing.expectEqual(count_after_init, counting.alloc_count);
}

// ---- 25. rebuild_is_deterministic_across_seeds ------------------------------

test "rebuild_is_deterministic_across_seeds" {
    // Same entity positions in same order must yield byte-identical output every time.
    // Tick value must not affect cell placement (INV-27.3).
    const allocator = std.testing.allocator;

    const positions = [_]Position{
        pos(0.0, 0.0),   pos(1.0, 0.0),  pos(0.0, 1.0),
        pos(-1.0, -1.0), pos(3.7, -2.1),
    };
    const entities = [_]EntityId{ 10, 20, 30, 40, 50 };
    const factions = [_]u8{ 0, 1, 0, 1, 0 };

    var grid_a = try HashGrid.init(allocator, defaultCfg());
    defer grid_a.deinit(allocator);
    var grid_b = try HashGrid.init(allocator, defaultCfg());
    defer grid_b.deinit(allocator);

    grid_a.rebuild(&positions, &entities, &factions, 1);
    grid_b.rebuild(&positions, &entities, &factions, 99999);

    const n = grid_a.entry_count;
    try std.testing.expectEqual(n, grid_b.entry_count);
    try std.testing.expect(std.mem.eql(hg.Entry, grid_a.entries[0..n], grid_b.entries[0..n]));
    try std.testing.expect(std.mem.eql(u32, grid_a.cell_start, grid_b.cell_start));
    try std.testing.expect(std.mem.eql(u32, grid_a.cell_count, grid_b.cell_count));
}
