// Seeded deterministic PRNG for the game simulation.
//
// Uses the SFC64 algorithm (Small Fast Counting, 64-bit variant) by
// Chris Doty-Humphrey. Properties:
//   - Period: >= 2^64 (in practice astronomically larger)
//   - Statistical quality: passes BigCrush
//   - Speed: ~1 ns/call on modern hardware
//   - Deterministic: same seed always produces the same sequence
//   - No global state — each Rng instance is independent
//
// All output is in terms of fixed-point or integer types. The caller is
// responsible for mapping random u64 values into the domain they need.
// Helper methods for common patterns (range, bool, fixed-point range) are
// provided so callers don't need to implement them correctly every time.
//
// Never seed with real-time clock values in simulation code. The server
// owns and distributes seeds. Client simulation uses the server's seed.

const std = @import("std");
const fp_mod = @import("fixed_point.zig");
const FP = fp_mod.FP;

/// A deterministic PRNG instance. Zero-initialize is not valid; use init().
pub const Rng = struct {
    a: u64,
    b: u64,
    c: u64,
    counter: u64,

    /// Initialize the PRNG with a seed. Two Rng instances with the same seed
    /// will produce identical sequences.
    pub fn init(seed: u64) Rng {
        var rng = Rng{ .a = seed, .b = seed, .c = seed, .counter = 1 };
        // Warm up the state with several rounds to avoid correlations between
        // seeds that differ by a small value.
        for (0..12) |_| {
            _ = rng.next();
        }
        return rng;
    }

    /// Advance the state and return the next 64-bit output.
    pub fn next(self: *Rng) u64 {
        const tmp = self.a +% self.b +% self.counter;
        self.counter +%= 1;
        self.a = self.b ^ (self.b >> 11);
        self.b = self.c +% (self.c << 3);
        self.c = std.math.rotl(u64, self.c, 24) +% tmp;
        return tmp;
    }

    /// Return a uniformly distributed integer in [0, bound).
    /// bound must be > 0.
    pub fn nextBelow(self: *Rng, bound: u64) u64 {
        std.debug.assert(bound > 0);
        // Debiased modulo using Daniel Lemire's method.
        const r = self.next();
        var result: u128 = @as(u128, r) * @as(u128, bound);
        var lo: u64 = @truncate(result);
        if (lo < bound) {
            const threshold = (0 -% bound) % bound;
            while (lo < threshold) {
                const r2 = self.next();
                result = @as(u128, r2) * @as(u128, bound);
                lo = @truncate(result);
            }
        }
        return @intCast(result >> 64);
    }

    /// Return a uniformly distributed integer in [lo, hi].
    /// Requires lo <= hi.
    pub fn nextIntRange(self: *Rng, lo: i64, hi: i64) i64 {
        std.debug.assert(lo <= hi);
        const range: u64 = @intCast(hi - lo);
        if (range == 0) return lo;
        const offset = self.nextBelow(range + 1);
        return lo + @as(i64, @intCast(offset));
    }

    /// Return true with probability 1/2 (fair coin flip).
    pub fn nextBool(self: *Rng) bool {
        return (self.next() & 1) == 1;
    }

    /// Return a fixed-point value uniformly distributed in [0, 1).
    /// The result has Q16.16 precision.
    pub fn nextFP(self: *Rng) FP {
        // Take the top 32 bits of the output, then shift down to 16 fractional bits.
        const r = self.next() >> 32;
        // r is in [0, 2^32). Divide by 2^32 to get [0, 1) in Q16.16:
        // result.raw = r * FP.scale / 2^32 = r >> 16.
        return FP.fromRaw(@intCast(r >> 16));
    }

    /// Return a fixed-point value uniformly distributed in [lo, hi).
    pub fn nextFPRange(self: *Rng, lo: FP, hi: FP) FP {
        std.debug.assert(lo.raw <= hi.raw);
        const span_raw = hi.raw - lo.raw;
        if (span_raw == 0) return lo;
        const unit = self.nextFP(); // in [0, 1)
        const offset = FP.mul(unit, FP.fromRaw(span_raw));
        return lo.add(offset);
    }

    /// Shuffle a slice in-place using Fisher-Yates (Knuth) shuffle.
    pub fn shuffle(self: *Rng, comptime T: type, slice: []T) void {
        var i = slice.len;
        while (i > 1) {
            i -= 1;
            const j = self.nextBelow(i + 1);
            const tmp = slice[i];
            slice[i] = slice[j];
            slice[j] = tmp;
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Rng: same seed produces identical sequence" {
    var r1 = Rng.init(12345);
    var r2 = Rng.init(12345);
    for (0..1000) |_| {
        try std.testing.expectEqual(r1.next(), r2.next());
    }
}

test "Rng: different seeds produce different sequences" {
    var r1 = Rng.init(1);
    var r2 = Rng.init(2);
    // With overwhelming probability the first output differs.
    try std.testing.expect(r1.next() != r2.next());
}

test "Rng: nextBelow stays within bound" {
    var rng = Rng.init(999);
    for (0..10_000) |_| {
        const v = rng.nextBelow(7);
        try std.testing.expect(v < 7);
    }
}

test "Rng: nextIntRange stays within range" {
    var rng = Rng.init(42);
    for (0..10_000) |_| {
        const v = rng.nextIntRange(-5, 5);
        try std.testing.expect(v >= -5 and v <= 5);
    }
}

test "Rng: nextFP in [0, 1)" {
    var rng = Rng.init(7);
    for (0..10_000) |_| {
        const v = rng.nextFP();
        try std.testing.expect(v.raw >= 0);
        try std.testing.expect(v.lt(FP.one));
    }
}

test "Rng: nextBool approximate 50/50 distribution" {
    var rng = Rng.init(0xDEADBEEF);
    var trues: u64 = 0;
    const n = 100_000;
    for (0..n) |_| {
        if (rng.nextBool()) trues += 1;
    }
    // Expect within 1% of 50%.
    try std.testing.expect(trues > n * 49 / 100);
    try std.testing.expect(trues < n * 51 / 100);
}

test "Rng: shuffle produces valid permutation" {
    var rng = Rng.init(0xCAFE);
    var arr = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    rng.shuffle(u32, &arr);
    // All values 0..9 must still be present.
    var seen = [_]bool{false} ** 10;
    for (arr) |v| {
        try std.testing.expect(v < 10);
        try std.testing.expect(!seen[v]); // no duplicates
        seen[v] = true;
    }
}

test "Rng: seed 0 is valid (does not produce zero state)" {
    var rng = Rng.init(0);
    // After warmup the state must be non-zero.
    const v = rng.next();
    try std.testing.expect(v != 0 or rng.a != 0 or rng.b != 0 or rng.c != 0);
}

test "Rng: nextBelow(1) always returns 0" {
    // bound == 1 means the only valid result is 0.
    var rng = Rng.init(0xABCDEF);
    for (0..1000) |_| {
        try std.testing.expectEqual(@as(u64, 0), rng.nextBelow(1));
    }
}

test "Rng: nextIntRange lo == hi returns lo" {
    // When lo == hi there is exactly one possible value.
    var rng = Rng.init(0x1234);
    for (0..100) |_| {
        try std.testing.expectEqual(@as(i64, -7), rng.nextIntRange(-7, -7));
        try std.testing.expectEqual(@as(i64, 0), rng.nextIntRange(0, 0));
        try std.testing.expectEqual(@as(i64, 42), rng.nextIntRange(42, 42));
    }
}

test "Rng: nextFPRange stays within [lo, hi)" {
    var rng = Rng.init(0x5A5A5A5A);
    const lo = FP.fromInt(2);
    const hi = FP.fromInt(5);
    for (0..10_000) |_| {
        const v = rng.nextFPRange(lo, hi);
        try std.testing.expect(v.raw >= lo.raw);
        try std.testing.expect(v.raw < hi.raw);
    }
}

test "Rng: nextFPRange lo == hi returns lo" {
    var rng = Rng.init(0xBEEF);
    const lo = FP.fromInt(3);
    for (0..100) |_| {
        const v = rng.nextFPRange(lo, lo);
        try std.testing.expectEqual(lo.raw, v.raw);
    }
}

test "Rng: shuffle empty slice does not panic" {
    var rng = Rng.init(0x1111);
    var arr: [0]u32 = .{};
    rng.shuffle(u32, &arr); // must not panic or access out-of-bounds
}

test "Rng: shuffle single-element slice is unchanged" {
    var rng = Rng.init(0x2222);
    var arr = [_]u32{42};
    rng.shuffle(u32, &arr);
    try std.testing.expectEqual(@as(u32, 42), arr[0]);
}

test "Rng: shuffle is reproducible with the same seed" {
    const n = 16;
    var arr1 = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    var arr2 = arr1;

    var r1 = Rng.init(0xFEEDFACE);
    var r2 = Rng.init(0xFEEDFACE);
    r1.shuffle(u32, &arr1);
    r2.shuffle(u32, &arr2);

    for (0..n) |i| {
        try std.testing.expectEqual(arr1[i], arr2[i]);
    }
}
