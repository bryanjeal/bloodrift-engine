// Uniform spatial hash grid for broadphase radius queries.
//
// Rebuilt every tick from settled post-physics positions. Zero allocations
// per tick - all four backing arrays are heap-allocated once at init.
// Designed for ~16k entities; four arrays at max_entities=16384 total ~768 KB
// (entries 256KB + scratch 256KB + cell_count 128KB + cell_start 128KB), which
// fits in a typical L3 and is rebuilt sequentially on one thread.
//
// Two-prime Teschner hash: stable, cache-friendly, O(N + C) rebuild.
// Callers do distance-squared filtering after visitInRadius - the grid
// is a broadphase superset, not an exact set.

const std = @import("std");
const types = @import("../types/root.zig");

pub const EntityId = types.EntityId;

/// Game-agnostic position in raw fixed-point units (i64 per axis).
/// Callers cast their own position struct to this type; the layout must match
/// (i64 x, i64 y, i64 z in that order).
pub const Position = struct { x: i64, y: i64, z: i64 };

/// One slot in the sorted entry table.
/// extern struct with explicit padding guarantees 16-byte-aligned, deterministic layout.
pub const Entry = extern struct {
    id: EntityId, // 8 B
    hash: u32, // 4 B
    faction: u8, // 1 B; copied from Team component to avoid sidecar lookup in hot path
    _pad: [3]u8, // 3 B padding to reach 16 B total
};

/// Construction parameters. Validated at init; stored values are derived from these.
pub const Config = struct {
    /// Cell edge length in Fp16 raw units. Must be > 0.
    cell_size_raw: i64,
    /// Number of hash buckets. Must be a power of two.
    cell_count: u32,
    /// Maximum number of entities per rebuild call.
    max_entities: u32,
};

/// Uniform spatial hash grid.
///
/// Lifecycle: init once, rebuild every tick (after Phase 3 position settle),
/// query any number of times in the same tick, deinit at shutdown.
pub const HashGrid = struct {
    /// Source order scratch buffer; filled during count pass.
    scratch: []Entry,
    /// Counting-sort output; what queries read.
    entries: []Entry,
    /// How many entries are valid after the last rebuild.
    entry_count: usize,
    /// cell_start[h] = first index in entries[] for bucket h.
    cell_start: []u32,
    /// cell_count[h] = number of entries in bucket h.
    cell_count: []u32,
    /// Cell edge length in Fp16 raw units.
    cell_size_raw: i64,
    /// Bitmask applied to raw hash to produce bucket index (= cell_count_val - 1).
    hash_mask: u32,
    /// Tick at which the last rebuild completed. 0 = never rebuilt.
    last_rebuild_tick: u64,
    /// Number of times rebuild has been called. Used to distinguish "never rebuilt"
    /// from "first rebuild happened on tick 0".
    rebuild_count: u64,

    /// Allocates four backing arrays on the heap. Zero further allocations after this.
    ///
    /// PRE: cfg.cell_size_raw > 0
    /// PRE: cfg.cell_count is a power of two
    /// PRE: cfg.max_entities > 0
    pub fn init(allocator: std.mem.Allocator, cfg: Config) !HashGrid {
        std.debug.assert(cfg.cell_size_raw > 0);
        std.debug.assert(cfg.max_entities > 0);
        // Power-of-two check: exactly one bit set.
        std.debug.assert(cfg.cell_count > 0 and (cfg.cell_count & (cfg.cell_count - 1)) == 0);

        const scratch = try allocator.alloc(Entry, cfg.max_entities);
        errdefer allocator.free(scratch);

        const entries = try allocator.alloc(Entry, cfg.max_entities);
        errdefer allocator.free(entries);

        const cell_start = try allocator.alloc(u32, cfg.cell_count);
        errdefer allocator.free(cell_start);
        @memset(cell_start, 0);

        const cell_count = try allocator.alloc(u32, cfg.cell_count);
        errdefer allocator.free(cell_count);
        @memset(cell_count, 0);

        return HashGrid{
            .scratch = scratch,
            .entries = entries,
            .entry_count = 0,
            .cell_start = cell_start,
            .cell_count = cell_count,
            .cell_size_raw = cfg.cell_size_raw,
            .hash_mask = cfg.cell_count - 1,
            .last_rebuild_tick = 0,
            .rebuild_count = 0,
        };
    }

    /// Frees all four backing arrays. Must be called with the same allocator used at init.
    pub fn deinit(self: *HashGrid, allocator: std.mem.Allocator) void {
        allocator.free(self.scratch);
        allocator.free(self.entries);
        allocator.free(self.cell_start);
        allocator.free(self.cell_count);
        self.* = undefined;
    }

    /// Rebuilds the grid from current entity positions in O(N + cell_count) time.
    ///
    /// PRE-27.1: all three input slices have equal length; length <= max_entities.
    /// POST-27.1: every input entity appears exactly once in its cell's slice.
    /// POST-27.3: zero heap allocations.
    pub fn rebuild(
        self: *HashGrid,
        positions: []const Position,
        entities: []const EntityId,
        factions: []const u8,
        tick: u64,
    ) void {
        std.debug.assert(positions.len == entities.len);
        std.debug.assert(positions.len == factions.len);
        std.debug.assert(positions.len <= self.scratch.len);

        countPerCell(self, positions, entities, factions);
        prefixSum(self);
        scatter(self, positions.len);
        restoreCounts(self);

        self.entry_count = positions.len;
        self.last_rebuild_tick = tick;
        self.rebuild_count += 1;
    }

    /// Calls cb(ctx, id, faction) for every entry in the AABB of cells covering
    /// [center - radius, center + radius]. Callers must do distance-sq filtering.
    ///
    /// PRE-27.3: radius_raw > 0
    /// PRE-27.4a: grid has been rebuilt at least once (rebuild_count > 0); a
    ///            zero-entity rebuild satisfies this - entry_count may be 0.
    /// PRE-27.5: radius_raw < maxInt(i64)/2 to prevent AABB corner arithmetic wrap
    /// POST-27.2: every entity within the AABB is visited (superset of true circle)
    pub fn visitInRadius(
        self: *const HashGrid,
        center: Position,
        radius_raw: i64,
        ctx: *anyopaque,
        cb: *const fn (*anyopaque, EntityId, u8) void,
    ) void {
        std.debug.assert(self.rebuild_count > 0);
        std.debug.assert(radius_raw > 0);
        // center.x +/- radius_raw must not overflow i64; half max is a safe ceiling
        // for any game world size reachable via Fp16 coordinates.
        std.debug.assert(radius_raw < std.math.maxInt(i64) / 2);

        // i64 throughout to avoid i32 overflow on large Fp16 coordinates.
        const cx_min: i64 = @divFloor(center.x - radius_raw, self.cell_size_raw);
        const cx_max: i64 = @divFloor(center.x + radius_raw, self.cell_size_raw);
        const cy_min: i64 = @divFloor(center.y - radius_raw, self.cell_size_raw);
        const cy_max: i64 = @divFloor(center.y + radius_raw, self.cell_size_raw);

        var cy: i64 = cy_min;
        while (cy <= cy_max) : (cy += 1) {
            var cx: i64 = cx_min;
            while (cx <= cx_max) : (cx += 1) {
                const h = hashCell(cx, cy, self.hash_mask);
                const start = self.cell_start[h];
                const count = self.cell_count[h];
                for (self.entries[start .. start + count]) |e| {
                    cb(ctx, e.id, e.faction);
                }
            }
        }
    }

    /// Maps a position to its grid cell coordinates and bucket hash.
    /// Exposed so tests can verify stable mapping without going through rebuild.
    ///
    /// Cell coordinates are i64 to avoid i32 overflow at large Fp16 world coords.
    pub fn computeCell(self: *const HashGrid, pos: Position) struct { cx: i64, cy: i64, h: u32 } {
        const cx: i64 = @divFloor(pos.x, self.cell_size_raw);
        const cy: i64 = @divFloor(pos.y, self.cell_size_raw);
        return .{ .cx = cx, .cy = cy, .h = hashCell(cx, cy, self.hash_mask) };
    }
};

// --- private helpers -----------------------------------------------------------

/// Two-prime Teschner hash over i64 cell coordinates, truncated to a u32 bucket index.
/// i64 wrapping multiply avoids overflow; @truncate keeps only low 32 bits of the XOR.
fn hashCell(cx: i64, cy: i64, mask: u32) u32 {
    const prod_x: i64 = cx *% 73856093;
    const prod_y: i64 = cy *% 19349663;
    const mixed: u64 = @bitCast(prod_x ^ prod_y);
    const k: u32 = @truncate(mixed);
    return k & mask;
}

/// Pass 1: zero histogram, fill scratch in source order, tally per-bucket counts.
fn countPerCell(
    self: *HashGrid,
    positions: []const Position,
    entities: []const EntityId,
    factions: []const u8,
) void {
    @memset(self.cell_count, 0);
    for (positions, entities, factions, 0..) |pos, id, faction, i| {
        const c = self.computeCell(pos);
        self.scratch[i] = .{
            .id = id,
            .hash = c.h,
            .faction = faction,
            ._pad = .{ 0, 0, 0 },
        };
        self.cell_count[c.h] += 1;
    }
}

/// Pass 2: exclusive prefix sum over cell_count -> cell_start.
fn prefixSum(self: *HashGrid) void {
    var offset: u32 = 0;
    for (0..self.cell_count.len) |i| {
        self.cell_start[i] = offset;
        offset += self.cell_count[i];
    }
}

/// Pass 3: scatter scratch -> entries using cell_start as cursors (stored in cell_count).
/// After this pass, cell_count[h] = cell_start[h] + original_count[h].
fn scatter(self: *HashGrid, count: usize) void {
    // Reuse cell_count as a running write cursor; init it to cell_start values.
    @memcpy(self.cell_count, self.cell_start);
    for (self.scratch[0..count]) |e| {
        const slot = self.cell_count[e.hash];
        self.entries[slot] = e;
        self.cell_count[e.hash] += 1;
    }
}

/// Pass 4: restore cell_count to original per-bucket counts.
/// After scatter, cell_count[h] = cell_start[h] + count; subtract to recover count.
fn restoreCounts(self: *HashGrid) void {
    for (0..self.cell_count.len) |i| {
        self.cell_count[i] -= self.cell_start[i];
    }
}
