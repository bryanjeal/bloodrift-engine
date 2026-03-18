// Core primitive types used throughout the engine and game simulation.
//
// EntityId and Tick are the two fundamental identifiers in the simulation.
// All systems key their data on one or both of these types.

const std = @import("std");

/// A stable, unique identifier for a game entity.
///
/// The lower 32 bits are the entity index; the upper 32 bits are the generation
/// counter, which increments each time an index is recycled. This allows stale
/// handles to be detected: if the generation in the stored EntityId does not
/// match the current generation for that index, the entity is dead.
///
/// Zero is reserved as the null/invalid sentinel. No live entity may have
/// EntityId == 0.
pub const EntityId = u64;

/// The null/invalid entity sentinel.
pub const entity_id_null: EntityId = 0;

/// Returns true if the given EntityId is not the null sentinel.
pub inline fn entity_id_valid(id: EntityId) bool {
    return id != entity_id_null;
}

/// A simulation tick counter.
///
/// One tick represents a single fixed-timestep simulation step. The server is
/// the authoritative source of tick numbering. Clients synchronize their local
/// tick counter with the server during the connection handshake.
///
/// u64 at 60 ticks/second overflows in ~9.7 billion years — no wraparound
/// handling is needed.
pub const Tick = u64;

/// The tick value before any simulation has run.
pub const tick_zero: Tick = 0;

test "entity_id: null sentinel is zero" {
    try std.testing.expectEqual(@as(EntityId, 0), entity_id_null);
}

test "entity_id: valid rejects null" {
    try std.testing.expect(!entity_id_valid(entity_id_null));
}

test "entity_id: valid accepts non-zero" {
    try std.testing.expect(entity_id_valid(1));
    try std.testing.expect(entity_id_valid(std.math.maxInt(EntityId)));
}

test "tick: zero sentinel" {
    try std.testing.expectEqual(@as(Tick, 0), tick_zero);
}

test "tick: u64 capacity at 60 ticks/sec exceeds 9 billion years" {
    const ticks_per_second: u64 = 60;
    const seconds_per_year: u64 = 365 * 24 * 60 * 60;
    const max_years = std.math.maxInt(Tick) / ticks_per_second / seconds_per_year;
    // At 60 Hz a u64 tick counter lasts ~9.7 billion years.
    try std.testing.expect(max_years > 9_000_000_000);
}
