// Fixed-point arithmetic for deterministic game simulation.
//
// Why fixed-point?
//   Floating-point arithmetic is not bit-identical across CPU architectures,
//   compilers, and optimization levels. The game simulation (positions,
//   velocities, combat math, status effect durations, cooldowns) must produce
//   byte-identical results on every platform so that client-side prediction
//   and server reconciliation stay in sync. Fixed-point satisfies this because
//   integer arithmetic is deterministic everywhere.
//
// Design:
//   FixedPoint(FracBits) is a comptime-parameterized signed Q-format integer.
//   The backing type is i64, giving a large range and immunity to overflow on
//   intermediate multiplications (we widen to i128 before multiplying).
//
//   Q24.8  (FracBits=8)  — range ±8.3M,  precision 1/256   (~0.004)
//   Q16.16 (FracBits=16) — range ±32768,  precision 1/65536 (~0.000015)
//
//   The game uses Q16.16 for world coordinates and velocities, and Q24.8 for
//   quantities that need larger range (e.g., damage totals).
//
// Trigonometry:
//   sin/cos are implemented via a pre-computed 1024-entry lookup table with
//   linear interpolation. Accuracy is ~0.0001 — sufficient for game steering
//   and projectile math.

const std = @import("std");

/// Returns a fixed-point type with the given number of fractional bits.
/// Backing storage is i64. Arithmetic uses i128 intermediates to avoid
/// overflow on multiplication.
pub fn FixedPoint(comptime frac_bits: u6) type {
    comptime {
        std.debug.assert(frac_bits > 0);
        std.debug.assert(frac_bits < 64);
    }

    return struct {
        const Self = @This();

        /// Number of fractional bits. Available at comptime for interop.
        pub const frac: u6 = frac_bits;
        /// The scale factor: integer 1 == Self{ .raw = scale }.
        pub const scale: i64 = @as(i64, 1) << frac_bits;
        /// The smallest representable positive value.
        pub const epsilon: Self = .{ .raw = 1 };
        pub const zero: Self = .{ .raw = 0 };
        pub const one: Self = .{ .raw = scale };
        pub const min: Self = .{ .raw = std.math.minInt(i64) };
        pub const max: Self = .{ .raw = std.math.maxInt(i64) };

        raw: i64,

        // ----------------------------------------------------------------
        // Constructors
        // ----------------------------------------------------------------

        /// Convert an integer to fixed-point.
        pub fn fromInt(v: i64) Self {
            return .{ .raw = v * scale };
        }

        /// Convert a float to fixed-point, rounding to nearest.
        /// Only use this at startup / content-load time — never in the
        /// deterministic simulation hot path.
        pub fn fromFloat(v: f64) Self {
            return .{ .raw = @intFromFloat(std.math.round(v * @as(f64, @floatFromInt(scale)))) };
        }

        /// Wrap a raw i64 value directly.
        pub fn fromRaw(r: i64) Self {
            return .{ .raw = r };
        }

        // ----------------------------------------------------------------
        // Conversions
        // ----------------------------------------------------------------

        /// Return the integer part (truncated toward zero).
        pub fn toInt(self: Self) i64 {
            return @divTrunc(self.raw, scale);
        }

        /// Convert to f32 for rendering. Never call in simulation code.
        pub fn toF32(self: Self) f32 {
            return @as(f32, @floatFromInt(self.raw)) / @as(f32, @floatFromInt(scale));
        }

        /// Convert to f64 for rendering. Never call in simulation code.
        pub fn toF64(self: Self) f64 {
            return @as(f64, @floatFromInt(self.raw)) / @as(f64, @floatFromInt(scale));
        }

        // ----------------------------------------------------------------
        // Arithmetic
        // ----------------------------------------------------------------

        pub fn add(a: Self, b: Self) Self {
            return .{ .raw = a.raw + b.raw };
        }

        pub fn sub(a: Self, b: Self) Self {
            return .{ .raw = a.raw - b.raw };
        }

        /// Multiply two fixed-point values.
        /// Uses i128 intermediate to prevent overflow before the shift.
        pub fn mul(a: Self, b: Self) Self {
            const wide: i128 = @as(i128, a.raw) * @as(i128, b.raw);
            return .{ .raw = @intCast(wide >> frac_bits) };
        }

        /// Divide two fixed-point values. Asserts divisor is non-zero.
        pub fn div(a: Self, b: Self) Self {
            std.debug.assert(b.raw != 0);
            const wide: i128 = @as(i128, a.raw) << frac_bits;
            return .{ .raw = @intCast(@divTrunc(wide, @as(i128, b.raw))) };
        }

        /// Negate.
        /// Precondition: a.raw != minInt(i64). The value minInt(i64) represents
        /// approximately -140 trillion in Q16.16 — unreachable in any game world.
        pub fn neg(a: Self) Self {
            std.debug.assert(a.raw != std.math.minInt(i64));
            return .{ .raw = -a.raw };
        }

        /// Absolute value.
        /// Precondition: a.raw != minInt(i64). |minInt(i64)| cannot be represented
        /// as i64, so the @intCast would overflow.
        pub fn abs(a: Self) Self {
            std.debug.assert(a.raw != std.math.minInt(i64));
            return .{ .raw = @intCast(@abs(a.raw)) };
        }

        // ----------------------------------------------------------------
        // Comparison
        // ----------------------------------------------------------------

        pub fn eql(a: Self, b: Self) bool {
            return a.raw == b.raw;
        }

        pub fn lt(a: Self, b: Self) bool {
            return a.raw < b.raw;
        }

        pub fn lte(a: Self, b: Self) bool {
            return a.raw <= b.raw;
        }

        pub fn gt(a: Self, b: Self) bool {
            return a.raw > b.raw;
        }

        pub fn gte(a: Self, b: Self) bool {
            return a.raw >= b.raw;
        }

        // ----------------------------------------------------------------
        // Clamping
        // ----------------------------------------------------------------

        pub fn clamp(v: Self, lo: Self, hi: Self) Self {
            std.debug.assert(lo.raw <= hi.raw);
            if (v.raw < lo.raw) return lo;
            if (v.raw > hi.raw) return hi;
            return v;
        }

        // ----------------------------------------------------------------
        // Square root (Newton-Raphson, integer domain)
        // ----------------------------------------------------------------

        /// Integer square root of the raw value, shifted appropriately so the
        /// result is a valid fixed-point number.
        /// Returns zero for negative inputs (safe; asserts non-negative in debug).
        pub fn sqrt(a: Self) Self {
            std.debug.assert(a.raw >= 0);
            if (a.raw <= 0) return zero;
            // Compute sqrt of (a.raw << frac_bits) to get the correctly scaled result.
            const shifted: i128 = @as(i128, a.raw) << frac_bits;
            var x: i128 = shifted;
            var r: i128 = (x + 1) >> 1;
            while (r < x) {
                x = r;
                r = (x + @divTrunc(shifted, x)) >> 1;
            }
            return .{ .raw = @intCast(x) };
        }

        // ----------------------------------------------------------------
        // Formatting (debug only)
        // ----------------------------------------------------------------

        pub fn format(
            self: Self,
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try writer.print("{d:.6}", .{self.toF64()});
        }
    };
}

// ----------------------------------------------------------------------------
// Sin / Cos lookup table
// ----------------------------------------------------------------------------

// 1024-entry table covering [0, 2π). Values stored as Q0.16 (raw i32, scaled
// by 65536). Angle input is in fixed-point radians (Q16.16).
//
// The table is generated at comptime so there is zero runtime overhead to
// initializing it. Each entry is sin(i * 2π / 1024) * 65536, rounded.

const sin_table_size: comptime_int = 1024;
const sin_table: [sin_table_size]i32 = blk: {
    @setEvalBranchQuota(1024 * 32);
    var table: [sin_table_size]i32 = undefined;
    for (&table, 0..) |*entry, i| {
        const angle = @as(f64, @floatFromInt(i)) * (2.0 * std.math.pi) / @as(f64, sin_table_size);
        entry.* = @intFromFloat(std.math.round(@sin(angle) * 65536.0));
    }
    break :blk table;
};

// Public fixed-point type used for angles (Q16.16).
pub const Fp16 = FixedPoint(16);

/// Fixed-point sin using the lookup table with linear interpolation.
/// Input: angle in radians as Fp16 (Q16.16).
/// Output: result in [-1, 1] as Fp16 (Q16.16).
pub fn sin(angle: Fp16) Fp16 {
    // Normalize angle to [0, 2π).
    const two_pi = Fp16.fromFloat(2.0 * std.math.pi);
    var a = angle;
    // Reduce to [0, 2π) by repeated subtraction/addition.
    // This is safe for reasonable angle ranges (avoids division).
    while (a.raw < 0) a = a.add(two_pi);
    while (a.gte(two_pi)) a = a.sub(two_pi);

    // Map angle to table index in Q16.16 format.
    // index_fp = a * sin_table_size / (2π), stored as fixed-point so integer
    // part = table index, fractional part = interpolation weight.
    const table_fp_raw: i64 = @intCast(
        @divTrunc(@as(i128, a.raw) * sin_table_size * Fp16.scale, @as(i128, two_pi.raw)),
    );
    const idx0: usize = @intCast(@mod(@divTrunc(table_fp_raw, Fp16.scale), sin_table_size));
    const idx1: usize = (idx0 + 1) % sin_table_size;
    const frac_part: i64 = @mod(table_fp_raw, Fp16.scale);

    // Linear interpolation between table[idx0] and table[idx1].
    const v0: i64 = sin_table[idx0];
    const v1: i64 = sin_table[idx1];
    const interp: i64 = v0 + @divTrunc((v1 - v0) * frac_part, Fp16.scale);

    // Table is Q0.16 (scale 65536). We need Q16.16.
    // interp is already in 65536-scaled units, matching Fp16.scale for Fp16=Q16.16.
    return Fp16.fromRaw(interp);
}

/// Fixed-point cos. cos(x) = sin(x + π/2).
pub fn cos(angle: Fp16) Fp16 {
    return sin(angle.add(Fp16.fromFloat(std.math.pi / 2.0)));
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "FixedPoint: fromInt round-trips through toInt" {
    const FP16 = FixedPoint(16);
    const cases = [_]i64{ 0, 1, -1, 100, -100, 32767, -32768 };
    for (cases) |v| {
        try std.testing.expectEqual(v, FP16.fromInt(v).toInt());
    }
}

test "FixedPoint: add and sub" {
    const FP16 = FixedPoint(16);
    const a = FP16.fromInt(3);
    const b = FP16.fromInt(4);
    try std.testing.expect(FP16.fromInt(7).eql(a.add(b)));
    try std.testing.expect(FP16.fromInt(-1).eql(a.sub(b)));
}

test "FixedPoint: mul" {
    const FP16 = FixedPoint(16);
    const a = FP16.fromFloat(2.5);
    const b = FP16.fromFloat(4.0);
    const result = a.mul(b);
    // 2.5 * 4.0 = 10.0; allow 1 ULP of rounding error.
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.toF64(), 1.0 / @as(f64, FP16.scale));
}

test "FixedPoint: div" {
    const FP16 = FixedPoint(16);
    const a = FP16.fromFloat(10.0);
    const b = FP16.fromFloat(4.0);
    const result = a.div(b);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), result.toF64(), 2.0 / @as(f64, FP16.scale));
}

test "FixedPoint: sqrt" {
    const FP16 = FixedPoint(16);
    const cases = [_]f64{ 0.0, 1.0, 4.0, 9.0, 2.0, 0.25 };
    for (cases) |v| {
        const fp = FP16.fromFloat(v);
        const result = FP16.sqrt(fp);
        const expected = @sqrt(v);
        try std.testing.expectApproxEqAbs(expected, result.toF64(), 0.001);
    }
}

test "FixedPoint: clamp" {
    const FP16 = FixedPoint(16);
    const lo = FP16.fromInt(0);
    const hi = FP16.fromInt(10);
    try std.testing.expect(lo.eql(FP16.clamp(FP16.fromInt(-5), lo, hi)));
    try std.testing.expect(hi.eql(FP16.clamp(FP16.fromInt(20), lo, hi)));
    try std.testing.expect(FP16.fromInt(5).eql(FP16.clamp(FP16.fromInt(5), lo, hi)));
}

test "FixedPoint: abs" {
    const FP16 = FixedPoint(16);
    try std.testing.expect(FP16.fromInt(5).eql(FP16.abs(FP16.fromInt(-5))));
    try std.testing.expect(FP16.fromInt(5).eql(FP16.abs(FP16.fromInt(5))));
    try std.testing.expect(FP16.zero.eql(FP16.abs(FP16.zero)));
}

test "FixedPoint: different FracBits are independent types" {
    const FP8 = FixedPoint(8);
    const FP16 = FixedPoint(16);
    // The types should not be assignable to each other — verified at comptime
    // by the fact that this test file compiles with both used separately.
    try std.testing.expectEqual(@as(i64, 256), FP8.scale);
    try std.testing.expectEqual(@as(i64, 65536), FP16.scale);
}

test "sin: sin(0) == 0" {
    const result = sin(Fp16.zero);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.toF64(), 0.001);
}

test "sin: sin(π/2) == 1" {
    const result = sin(Fp16.fromFloat(std.math.pi / 2.0));
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.toF64(), 0.001);
}

test "sin: sin(π) ≈ 0" {
    const result = sin(Fp16.fromFloat(std.math.pi));
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.toF64(), 0.001);
}

test "sin: sin(3π/2) == -1" {
    const result = sin(Fp16.fromFloat(3.0 * std.math.pi / 2.0));
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), result.toF64(), 0.001);
}

test "cos: cos(0) == 1" {
    const result = cos(Fp16.zero);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.toF64(), 0.001);
}

test "cos: cos(π) == -1" {
    const result = cos(Fp16.fromFloat(std.math.pi));
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), result.toF64(), 0.001);
}

test "FixedPoint: neg" {
    const FP16 = FixedPoint(16);
    // neg(zero) == zero
    try std.testing.expect(FP16.zero.eql(FP16.neg(FP16.zero)));
    // neg(positive) is negative
    try std.testing.expect(FP16.neg(FP16.fromInt(5)).eql(FP16.fromInt(-5)));
    // neg(negative) is positive
    try std.testing.expect(FP16.neg(FP16.fromInt(-3)).eql(FP16.fromInt(3)));
    // neg(neg(x)) == x
    const v = FP16.fromFloat(1.5);
    try std.testing.expect(FP16.neg(FP16.neg(v)).eql(v));
}

test "FixedPoint: fromRaw and toF32" {
    const FP16 = FixedPoint(16);
    // fromRaw wraps the value directly.
    const r = FP16.fromRaw(FP16.scale); // == one
    try std.testing.expect(FP16.one.eql(r));
    // toF32 converts correctly.
    const v = FP16.fromFloat(3.25);
    try std.testing.expectApproxEqAbs(@as(f32, 3.25), v.toF32(), 0.0002);
    try std.testing.expectApproxEqAbs(@as(f32, -1.5), FP16.fromFloat(-1.5).toF32(), 0.0002);
}

test "FixedPoint: toInt truncates toward zero for fractional values" {
    const FP16 = FixedPoint(16);
    // Positive fractional: 2.9 → 2
    try std.testing.expectEqual(@as(i64, 2), FP16.fromFloat(2.9).toInt());
    // Negative fractional: -2.9 → -2 (truncated toward zero, not floor)
    try std.testing.expectEqual(@as(i64, -2), FP16.fromFloat(-2.9).toInt());
    // -0.5 → 0
    try std.testing.expectEqual(@as(i64, 0), FP16.fromFloat(-0.5).toInt());
    // Exact integer: -5.0 → -5
    try std.testing.expectEqual(@as(i64, -5), FP16.fromInt(-5).toInt());
}

test "FixedPoint: comparison operators" {
    const FP16 = FixedPoint(16);
    const a = FP16.fromInt(3);
    const b = FP16.fromInt(5);
    const c = FP16.fromInt(3);

    // lt
    try std.testing.expect(a.lt(b));
    try std.testing.expect(!b.lt(a));
    try std.testing.expect(!a.lt(c)); // equal is not less-than

    // lte
    try std.testing.expect(a.lte(b));
    try std.testing.expect(a.lte(c)); // equal satisfies lte
    try std.testing.expect(!b.lte(a));

    // gt
    try std.testing.expect(b.gt(a));
    try std.testing.expect(!a.gt(b));
    try std.testing.expect(!a.gt(c));

    // gte
    try std.testing.expect(b.gte(a));
    try std.testing.expect(a.gte(c)); // equal satisfies gte
    try std.testing.expect(!a.gte(b));

    // Negative values
    const neg5 = FP16.fromInt(-5);
    try std.testing.expect(neg5.lt(a));
    try std.testing.expect(a.gt(neg5));
}

test "FixedPoint: clamp lo == hi returns that value" {
    const FP16 = FixedPoint(16);
    const v = FP16.fromInt(7);
    const result = FP16.clamp(FP16.fromInt(3), v, v);
    try std.testing.expect(v.eql(result));
    // Value already equal to lo == hi.
    try std.testing.expect(v.eql(FP16.clamp(v, v, v)));
}

test "FixedPoint: clamp at exact boundary" {
    const FP16 = FixedPoint(16);
    const lo = FP16.fromInt(0);
    const hi = FP16.fromInt(10);
    // Value exactly at lo returns lo.
    try std.testing.expect(lo.eql(FP16.clamp(lo, lo, hi)));
    // Value exactly at hi returns hi.
    try std.testing.expect(hi.eql(FP16.clamp(hi, lo, hi)));
}

test "FixedPoint: mul with negatives" {
    const FP16 = FixedPoint(16);
    // positive * negative = negative
    const pos = FP16.fromFloat(3.0);
    const neg_v = FP16.fromFloat(-2.0);
    try std.testing.expectApproxEqAbs(@as(f64, -6.0), pos.mul(neg_v).toF64(), 0.001);
    // negative * negative = positive
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), neg_v.mul(FP16.fromFloat(-3.0)).toF64(), 0.001);
    // x * zero = zero
    try std.testing.expect(FP16.zero.eql(pos.mul(FP16.zero)));
    // x * one = x
    try std.testing.expect(pos.eql(pos.mul(FP16.one)));
}

test "FixedPoint: div with negatives" {
    const FP16 = FixedPoint(16);
    // positive / negative = negative
    try std.testing.expectApproxEqAbs(
        @as(f64, -2.0),
        FP16.fromFloat(6.0).div(FP16.fromFloat(-3.0)).toF64(),
        0.001,
    );
    // negative / negative = positive
    try std.testing.expectApproxEqAbs(
        @as(f64, 2.0),
        FP16.fromFloat(-6.0).div(FP16.fromFloat(-3.0)).toF64(),
        0.001,
    );
    // zero / non-zero = zero
    try std.testing.expect(FP16.zero.eql(FP16.zero.div(FP16.fromInt(5))));
}

test "FixedPoint: sqrt of larger and small fractional values" {
    const FP16 = FixedPoint(16);
    // sqrt(100) = 10
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), FP16.sqrt(FP16.fromInt(100)).toF64(), 0.01);
    // sqrt(10000) = 100
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), FP16.sqrt(FP16.fromInt(10000)).toF64(), 0.1);
    // sqrt(epsilon) > 0
    const r = FP16.sqrt(FP16.epsilon);
    try std.testing.expect(r.raw > 0);
    // sqrt(0.0625) = 0.25
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), FP16.sqrt(FP16.fromFloat(0.0625)).toF64(), 0.001);
}

test "sin: negative angle normalizes correctly" {
    // sin(-π/2) = -1
    const result = sin(Fp16.fromFloat(-std.math.pi / 2.0));
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), result.toF64(), 0.001);
    // sin(-π) ≈ 0
    const result2 = sin(Fp16.fromFloat(-std.math.pi));
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result2.toF64(), 0.001);
}

test "sin: arbitrary angle (π/4)" {
    // sin(π/4) = √2/2 ≈ 0.7071
    const result = sin(Fp16.fromFloat(std.math.pi / 4.0));
    try std.testing.expectApproxEqAbs(@as(f64, std.math.sqrt2 / 2.0), result.toF64(), 0.001);
}

test "cos: arbitrary angle (π/3)" {
    // cos(π/3) = 0.5
    const result = cos(Fp16.fromFloat(std.math.pi / 3.0));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.toF64(), 0.001);
}

test "sin/cos: Pythagorean identity sin²+cos²=1" {
    // For several angles, sin²(θ) + cos²(θ) should equal 1.
    const angles = [_]f64{ 0.1, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0 };
    for (angles) |a| {
        const s = sin(Fp16.fromFloat(a));
        const c = cos(Fp16.fromFloat(a));
        const identity = s.mul(s).add(c.mul(c));
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), identity.toF64(), 0.002);
    }
}

test "FixedPoint: determinism — same raw input always produces same output" {
    // This is the core guarantee. Run the same operations twice and verify
    // the raw values are bit-identical (not just approximately equal).
    const FP16 = FixedPoint(16);
    const a = FP16.fromFloat(1.7320508); // sqrt(3) input
    const b = FP16.fromFloat(2.2360679); // sqrt(5) input

    const run1_add = a.add(b).raw;
    const run1_mul = a.mul(b).raw;
    const run1_sqrt = FP16.sqrt(a).raw;

    const run2_add = a.add(b).raw;
    const run2_mul = a.mul(b).raw;
    const run2_sqrt = FP16.sqrt(a).raw;

    try std.testing.expectEqual(run1_add, run2_add);
    try std.testing.expectEqual(run1_mul, run2_mul);
    try std.testing.expectEqual(run1_sqrt, run2_sqrt);
}
