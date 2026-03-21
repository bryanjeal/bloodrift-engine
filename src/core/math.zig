// Math types for simulation and rendering.
//
// Two families of types exist and must never be mixed:
//
//   Simulation (deterministic, fixed-point):
//     FVec3  — 3D vector backed by FixedPoint(16) components
//     FQuat  — quaternion backed by FixedPoint(16) components
//
//   Rendering (non-deterministic, hardware float):
//     Vec3f  — 3D vector backed by f32 components
//     Vec4f  — 4D vector backed by f32 components (homogeneous coords)
//     Mat4f  — 4x4 column-major matrix backed by f32 (view/projection)
//     Quatf  — quaternion backed by f32 components
//
// Boundary conversions (call only at the sim→render handoff, never inside
// a system that runs on both client and server):
//     FVec3.toVec3f() / Vec3f.toFVec3()
//
// The file is intentionally kept free of trigonometry in the rendering types
// (keep rendering code in the renderer module). Simulation trig goes through
// fixed_point.sin / fixed_point.cos.

const std = @import("std");
const fp_mod = @import("fixed_point.zig");
const FP = fp_mod.FP; // FixedPoint(16) — Q16.16

// ============================================================================
// Simulation types — fixed-point, deterministic
// ============================================================================

/// 3D vector with Q16.16 fixed-point components. Used for all entity positions,
/// velocities, and simulation-side geometry. Must not appear in rendering code.
pub const FVec3 = struct {
    x: FP,
    y: FP,
    z: FP,

    pub const zero: FVec3 = .{ .x = FP.zero, .y = FP.zero, .z = FP.zero };
    pub const one: FVec3 = .{ .x = FP.one, .y = FP.one, .z = FP.one };
    pub const unit_x: FVec3 = .{ .x = FP.one, .y = FP.zero, .z = FP.zero };
    pub const unit_y: FVec3 = .{ .x = FP.zero, .y = FP.one, .z = FP.zero };
    pub const unit_z: FVec3 = .{ .x = FP.zero, .y = FP.zero, .z = FP.one };

    pub fn init(x: FP, y: FP, z: FP) FVec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn fromInts(x: i64, y: i64, z: i64) FVec3 {
        return .{ .x = FP.fromInt(x), .y = FP.fromInt(y), .z = FP.fromInt(z) };
    }

    pub fn add(a: FVec3, b: FVec3) FVec3 {
        return .{ .x = a.x.add(b.x), .y = a.y.add(b.y), .z = a.z.add(b.z) };
    }

    pub fn sub(a: FVec3, b: FVec3) FVec3 {
        return .{ .x = a.x.sub(b.x), .y = a.y.sub(b.y), .z = a.z.sub(b.z) };
    }

    pub fn scale(a: FVec3, s: FP) FVec3 {
        return .{ .x = a.x.mul(s), .y = a.y.mul(s), .z = a.z.mul(s) };
    }

    pub fn neg(a: FVec3) FVec3 {
        return .{ .x = a.x.neg(), .y = a.y.neg(), .z = a.z.neg() };
    }

    pub fn dot(a: FVec3, b: FVec3) FP {
        return a.x.mul(b.x).add(a.y.mul(b.y)).add(a.z.mul(b.z));
    }

    pub fn cross(a: FVec3, b: FVec3) FVec3 {
        return .{
            .x = a.y.mul(b.z).sub(a.z.mul(b.y)),
            .y = a.z.mul(b.x).sub(a.x.mul(b.z)),
            .z = a.x.mul(b.y).sub(a.y.mul(b.x)),
        };
    }

    /// Squared length. Does not require sqrt.
    pub fn len_sq(a: FVec3) FP {
        return a.dot(a);
    }

    /// Euclidean length via fixed-point sqrt.
    pub fn len(a: FVec3) FP {
        return FP.sqrt(a.len_sq());
    }

    /// Normalize to unit length. Returns FVec3.zero for the zero vector.
    pub fn normalize(a: FVec3) FVec3 {
        const l = a.len();
        if (l.raw == 0) return FVec3.zero;
        return a.scale(FP.one.div(l));
    }

    pub fn eql(a: FVec3, b: FVec3) bool {
        return a.x.eql(b.x) and a.y.eql(b.y) and a.z.eql(b.z);
    }

    /// Convert to rendering Vec3f. Call only at the simulation→rendering boundary.
    pub fn toVec3f(self: FVec3) Vec3f {
        return .{
            .x = self.x.toF32(),
            .y = self.y.toF32(),
            .z = self.z.toF32(),
        };
    }
};

/// Quaternion with Q16.16 fixed-point components. Represents rotations in the
/// deterministic simulation. Component convention: (x, y, z, w) where w is
/// the scalar part. Assumed unit quaternion for rotation ops.
pub const FQuat = struct {
    x: FP,
    y: FP,
    z: FP,
    w: FP,

    /// The identity quaternion (no rotation).
    pub const identity: FQuat = .{
        .x = FP.zero,
        .y = FP.zero,
        .z = FP.zero,
        .w = FP.one,
    };

    pub fn init(x: FP, y: FP, z: FP, w: FP) FQuat {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    /// Hamilton product of two quaternions.
    pub fn mul(a: FQuat, b: FQuat) FQuat {
        return .{
            .x = a.w.mul(b.x).add(a.x.mul(b.w)).add(a.y.mul(b.z)).sub(a.z.mul(b.y)),
            .y = a.w.mul(b.y).sub(a.x.mul(b.z)).add(a.y.mul(b.w)).add(a.z.mul(b.x)),
            .z = a.w.mul(b.z).add(a.x.mul(b.y)).sub(a.y.mul(b.x)).add(a.z.mul(b.w)),
            .w = a.w.mul(b.w).sub(a.x.mul(b.x)).sub(a.y.mul(b.y)).sub(a.z.mul(b.z)),
        };
    }

    /// Conjugate (inverse for unit quaternions).
    pub fn conjugate(q: FQuat) FQuat {
        return .{ .x = q.x.neg(), .y = q.y.neg(), .z = q.z.neg(), .w = q.w };
    }

    /// Rotate a vector by this quaternion: v' = q * v * q^-1.
    pub fn rotate(q: FQuat, v: FVec3) FVec3 {
        // Optimized form: v' = v + 2w(q×v) + 2(q×(q×v))
        // where q here refers to the (x,y,z) part of the quaternion.
        const qv = FVec3.init(q.x, q.y, q.z);
        const t = qv.cross(v).scale(FP.fromInt(2));
        const u = qv.cross(t);
        const wt = t.scale(q.w);
        return v.add(wt).add(u);
    }

    pub fn eql(a: FQuat, b: FQuat) bool {
        return a.x.eql(b.x) and a.y.eql(b.y) and a.z.eql(b.z) and a.w.eql(b.w);
    }

    /// Convert to rendering Quatf. Call only at the simulation→rendering boundary.
    pub fn toQuatf(self: FQuat) Quatf {
        return .{
            .x = self.x.toF32(),
            .y = self.y.toF32(),
            .z = self.z.toF32(),
            .w = self.w.toF32(),
        };
    }
};

// ============================================================================
// Integer math utilities — deterministic, platform-independent
// ============================================================================

/// Integer square root: returns floor(sqrt(n)).
/// Uses Newton-Raphson iteration — fully deterministic on all platforms.
/// isqrt(0) == 0.
pub fn isqrt(n: u64) u64 {
    if (n == 0) return 0;
    var x: u64 = n;
    var r: u64 = (x + 1) >> 1;
    while (r < x) {
        x = r;
        r = (x + n / x) >> 1;
    }
    return x;
}

// ============================================================================
// Rendering types — hardware float (f32), non-deterministic
// ============================================================================

/// 3D vector with f32 components. Used only in rendering code (camera, draw
/// call submission, shader parameters). Must not appear in simulation code.
pub const Vec3f = struct {
    x: f32,
    y: f32,
    z: f32,

    pub const zero: Vec3f = .{ .x = 0, .y = 0, .z = 0 };
    pub const one: Vec3f = .{ .x = 1, .y = 1, .z = 1 };
    pub const unit_x: Vec3f = .{ .x = 1, .y = 0, .z = 0 };
    pub const unit_y: Vec3f = .{ .x = 0, .y = 1, .z = 0 };
    pub const unit_z: Vec3f = .{ .x = 0, .y = 0, .z = 1 };

    pub fn init(x: f32, y: f32, z: f32) Vec3f {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn add(a: Vec3f, b: Vec3f) Vec3f {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn sub(a: Vec3f, b: Vec3f) Vec3f {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn scale(a: Vec3f, s: f32) Vec3f {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }

    pub fn neg(a: Vec3f) Vec3f {
        return .{ .x = -a.x, .y = -a.y, .z = -a.z };
    }

    pub fn dot(a: Vec3f, b: Vec3f) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn cross(a: Vec3f, b: Vec3f) Vec3f {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    pub fn len_sq(a: Vec3f) f32 {
        return a.dot(a);
    }

    pub fn len(a: Vec3f) f32 {
        return @sqrt(a.len_sq());
    }

    pub fn normalize(a: Vec3f) Vec3f {
        const l = a.len();
        std.debug.assert(l > 0.0);
        return a.scale(1.0 / l);
    }

    /// Linear interpolation: a + t*(b-a). t should be in [0,1].
    pub fn lerp(a: Vec3f, b: Vec3f, t: f32) Vec3f {
        return a.add(b.sub(a).scale(t));
    }

    /// Convert to simulation FVec3. Call only at the rendering→simulation boundary.
    /// Loses precision; use with care.
    pub fn toFVec3(self: Vec3f) FVec3 {
        return .{
            .x = FP.fromFloat(self.x),
            .y = FP.fromFloat(self.y),
            .z = FP.fromFloat(self.z),
        };
    }
};

/// 4D vector with f32 components. Used for homogeneous coordinates in matrix
/// math (view/projection transforms).
pub const Vec4f = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub const zero: Vec4f = .{ .x = 0, .y = 0, .z = 0, .w = 0 };

    pub fn init(x: f32, y: f32, z: f32, w: f32) Vec4f {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    pub fn fromVec3(v: Vec3f, w: f32) Vec4f {
        return .{ .x = v.x, .y = v.y, .z = v.z, .w = w };
    }

    pub fn toVec3(self: Vec4f) Vec3f {
        return .{ .x = self.x, .y = self.y, .z = self.z };
    }

    pub fn dot(a: Vec4f, b: Vec4f) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    }
};

/// 4×4 column-major matrix with f32 components. Used for view and projection
/// transforms in the renderer. Column-major matches Vulkan/GLSL convention.
pub const Mat4f = struct {
    // cols[col][row]
    cols: [4][4]f32,

    pub const identity: Mat4f = .{ .cols = .{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    } };

    pub const zero: Mat4f = .{ .cols = .{
        .{ 0, 0, 0, 0 },
        .{ 0, 0, 0, 0 },
        .{ 0, 0, 0, 0 },
        .{ 0, 0, 0, 0 },
    } };

    pub fn mul(a: Mat4f, b: Mat4f) Mat4f {
        var result = Mat4f.zero;
        for (0..4) |col| {
            for (0..4) |row| {
                var sum: f32 = 0;
                for (0..4) |k| {
                    sum += a.cols[k][row] * b.cols[col][k];
                }
                result.cols[col][row] = sum;
            }
        }
        return result;
    }

    pub fn mul_vec4(m: Mat4f, v: Vec4f) Vec4f {
        return .{
            .x = m.cols[0][0] * v.x + m.cols[1][0] * v.y + m.cols[2][0] * v.z + m.cols[3][0] * v.w,
            .y = m.cols[0][1] * v.x + m.cols[1][1] * v.y + m.cols[2][1] * v.z + m.cols[3][1] * v.w,
            .z = m.cols[0][2] * v.x + m.cols[1][2] * v.y + m.cols[2][2] * v.z + m.cols[3][2] * v.w,
            .w = m.cols[0][3] * v.x + m.cols[1][3] * v.y + m.cols[2][3] * v.z + m.cols[3][3] * v.w,
        };
    }

    /// Build a translation matrix.
    pub fn translation(t: Vec3f) Mat4f {
        var m = Mat4f.identity;
        m.cols[3][0] = t.x;
        m.cols[3][1] = t.y;
        m.cols[3][2] = t.z;
        return m;
    }

    /// Build a uniform scale matrix.
    pub fn uniform_scale(s: f32) Mat4f {
        var m = Mat4f.zero;
        m.cols[0][0] = s;
        m.cols[1][1] = s;
        m.cols[2][2] = s;
        m.cols[3][3] = 1.0;
        return m;
    }

    /// Orthographic projection (right-handed, depth range [0, 1] — Vulkan NDC).
    pub fn ortho(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4f {
        std.debug.assert(right != left);
        std.debug.assert(top != bottom);
        std.debug.assert(far != near);
        var m = Mat4f.zero;
        m.cols[0][0] = 2.0 / (right - left);
        m.cols[1][1] = 2.0 / (top - bottom);
        m.cols[2][2] = 1.0 / (far - near);
        m.cols[3][0] = -(right + left) / (right - left);
        m.cols[3][1] = -(top + bottom) / (top - bottom);
        m.cols[3][2] = -near / (far - near);
        m.cols[3][3] = 1.0;
        return m;
    }

    /// Perspective projection (right-handed, depth range [0, 1] — Vulkan NDC).
    /// fov_y is in radians.
    pub fn perspective(fov_y: f32, aspect: f32, near: f32, far: f32) Mat4f {
        std.debug.assert(fov_y > 0.0);
        std.debug.assert(aspect > 0.0);
        std.debug.assert(far > near);
        const tan_half = @tan(fov_y / 2.0);
        var m = Mat4f.zero;
        m.cols[0][0] = 1.0 / (aspect * tan_half);
        m.cols[1][1] = 1.0 / tan_half;
        m.cols[2][2] = far / (far - near);
        m.cols[2][3] = 1.0;
        m.cols[3][2] = -(far * near) / (far - near);
        return m;
    }

    /// Look-at view matrix.
    pub fn look_at(eye: Vec3f, center: Vec3f, up: Vec3f) Mat4f {
        const f = center.sub(eye).normalize();
        const s = f.cross(up).normalize();
        const u = s.cross(f);
        var m = Mat4f.identity;
        m.cols[0][0] = s.x;
        m.cols[1][0] = s.y;
        m.cols[2][0] = s.z;
        m.cols[0][1] = u.x;
        m.cols[1][1] = u.y;
        m.cols[2][1] = u.z;
        m.cols[0][2] = -f.x;
        m.cols[1][2] = -f.y;
        m.cols[2][2] = -f.z;
        m.cols[3][0] = -s.dot(eye);
        m.cols[3][1] = -u.dot(eye);
        m.cols[3][2] = f.dot(eye);
        return m;
    }

    /// Return a raw pointer to the column-major float data for passing to Vulkan.
    pub fn ptr(self: *const Mat4f) *const f32 {
        return @ptrCast(&self.cols[0][0]);
    }
};

/// Quaternion with f32 components. Used for camera and animation interpolation
/// in the renderer. Must not appear in simulation code.
pub const Quatf = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub const identity: Quatf = .{ .x = 0, .y = 0, .z = 0, .w = 1 };

    pub fn init(x: f32, y: f32, z: f32, w: f32) Quatf {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    pub fn mul(a: Quatf, b: Quatf) Quatf {
        return .{
            .x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            .y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            .z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            .w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        };
    }

    /// Convert to simulation FQuat. Call only at the rendering→simulation boundary.
    pub fn toFQuat(self: Quatf) FQuat {
        return .{
            .x = FP.fromFloat(self.x),
            .y = FP.fromFloat(self.y),
            .z = FP.fromFloat(self.z),
            .w = FP.fromFloat(self.w),
        };
    }
};

// ============================================================================
// Easing functions — f32, t in [0, 1]
//
// Standard Robert Penner easing functions for animation and UI transitions.
// All functions map t=0 → 0 and t=1 → 1.
// Reference: https://easings.net
// ============================================================================

pub const Ease = struct {
    /// Quartic ease-out: fast start, decelerates sharply toward t=1.
    /// f(t) = 1 − (1 − t)⁴
    /// Useful for camera follow, projectile arrival, and UI panel slides.
    pub fn outQuart(t: f32) f32 {
        const inv = 1.0 - t;
        return 1.0 - inv * inv * inv * inv;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "FVec3: add and sub" {
    const a = FVec3.fromInts(1, 2, 3);
    const b = FVec3.fromInts(4, 5, 6);
    try std.testing.expect(FVec3.fromInts(5, 7, 9).eql(a.add(b)));
    try std.testing.expect(FVec3.fromInts(-3, -3, -3).eql(a.sub(b)));
}

test "FVec3: dot product" {
    const a = FVec3.fromInts(1, 2, 3);
    const b = FVec3.fromInts(4, 5, 6);
    // 1*4 + 2*5 + 3*6 = 4 + 10 + 18 = 32
    try std.testing.expect(FP.fromInt(32).eql(a.dot(b)));
}

test "FVec3: cross product" {
    const a = FVec3.unit_x;
    const b = FVec3.unit_y;
    // x × y = z
    try std.testing.expect(FVec3.unit_z.eql(a.cross(b)));
}

test "FVec3: length and normalize" {
    const a = FVec3.fromInts(3, 4, 0);
    // len = 5
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), a.len().toF64(), 0.01);
    const n = a.normalize();
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), n.len().toF64(), 0.01);
}

test "FVec3: toVec3f round-trip accuracy" {
    const a = FVec3.fromInts(7, -3, 12);
    const v = a.toVec3f();
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), v.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -3.0), v.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), v.z, 0.001);
}

test "FQuat: identity rotates vector unchanged" {
    const v = FVec3.fromInts(1, 2, 3);
    const rotated = FQuat.identity.rotate(v);
    try std.testing.expectApproxEqAbs(v.x.toF64(), rotated.x.toF64(), 0.001);
    try std.testing.expectApproxEqAbs(v.y.toF64(), rotated.y.toF64(), 0.001);
    try std.testing.expectApproxEqAbs(v.z.toF64(), rotated.z.toF64(), 0.001);
}

test "FQuat: conjugate of identity is identity" {
    try std.testing.expect(FQuat.identity.eql(FQuat.identity.conjugate()));
}

test "Vec3f: lerp midpoint" {
    const a = Vec3f.init(0, 0, 0);
    const b = Vec3f.init(2, 4, 6);
    const mid = Vec3f.lerp(a, b, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mid.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), mid.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), mid.z, 0.001);
}

test "Mat4f: identity mul_vec4 returns same vector" {
    const v = Vec4f.init(1, 2, 3, 1);
    const result = Mat4f.identity.mul_vec4(v);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), result.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), result.z, 0.001);
}

test "Mat4f: identity * identity == identity" {
    const result = Mat4f.identity.mul(Mat4f.identity);
    for (0..4) |col| {
        for (0..4) |row| {
            try std.testing.expectApproxEqAbs(Mat4f.identity.cols[col][row], result.cols[col][row], 0.001);
        }
    }
}

test "Mat4f: translation moves a point" {
    const t = Mat4f.translation(Vec3f.init(5, 3, 1));
    const p = Vec4f.fromVec3(Vec3f.zero, 1.0);
    const result = t.mul_vec4(p);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), result.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), result.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result.z, 0.001);
}

test "FVec3: neg" {
    const a = FVec3.fromInts(1, -2, 3);
    const n = FVec3.neg(a);
    try std.testing.expect(FVec3.fromInts(-1, 2, -3).eql(n));
    // neg(zero) == zero
    try std.testing.expect(FVec3.zero.eql(FVec3.neg(FVec3.zero)));
    // neg(neg(v)) == v
    try std.testing.expect(a.eql(FVec3.neg(FVec3.neg(a))));
}

test "FVec3: scale" {
    const a = FVec3.fromInts(2, 4, 6);
    const s = a.scale(FP.fromFloat(0.5));
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), s.x.toF64(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), s.y.toF64(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), s.z.toF64(), 0.001);
    // scale by zero yields zero vector
    try std.testing.expect(FVec3.zero.eql(a.scale(FP.zero)));
    // scale by one yields same vector
    try std.testing.expect(a.eql(a.scale(FP.one)));
}

test "FVec3: len_sq" {
    // 3² + 4² + 0² = 25
    const a = FVec3.fromInts(3, 4, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 25.0), a.len_sq().toF64(), 0.01);
    // zero vector has len_sq = 0
    try std.testing.expect(FP.zero.eql(FVec3.zero.len_sq()));
}

test "FVec3: eql negative case" {
    const a = FVec3.fromInts(1, 2, 3);
    const b = FVec3.fromInts(1, 2, 4);
    try std.testing.expect(!a.eql(b));
    try std.testing.expect(!FVec3.unit_x.eql(FVec3.unit_y));
}

test "FQuat: mul — identity is absorbing element" {
    const q = FQuat.init(
        FP.fromFloat(0.0),
        FP.fromFloat(0.0),
        FP.fromFloat(0.7071067811865476),
        FP.fromFloat(0.7071067811865476),
    );
    // identity * q == q
    const lhs = FQuat.identity.mul(q);
    try std.testing.expectApproxEqAbs(q.x.toF64(), lhs.x.toF64(), 0.002);
    try std.testing.expectApproxEqAbs(q.y.toF64(), lhs.y.toF64(), 0.002);
    try std.testing.expectApproxEqAbs(q.z.toF64(), lhs.z.toF64(), 0.002);
    try std.testing.expectApproxEqAbs(q.w.toF64(), lhs.w.toF64(), 0.002);
    // q * identity == q
    const rhs = q.mul(FQuat.identity);
    try std.testing.expectApproxEqAbs(q.x.toF64(), rhs.x.toF64(), 0.002);
    try std.testing.expectApproxEqAbs(q.w.toF64(), rhs.w.toF64(), 0.002);
}

test "FQuat: mul — 90° rotations about z compose to 180°" {
    // q90 = 90° about z-axis: (0, 0, sin45°, cos45°)
    const half_sqrt2 = FP.fromFloat(std.math.sqrt2 / 2.0);
    const q90 = FQuat.init(FP.zero, FP.zero, half_sqrt2, half_sqrt2);
    // q90 * q90 should be 180° about z: (0, 0, 1, 0)
    const q180 = q90.mul(q90);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), q180.x.toF64(), 0.002);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), q180.y.toF64(), 0.002);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), q180.z.toF64(), 0.002);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), q180.w.toF64(), 0.002);
}

test "FQuat: rotate — 90° about z maps unit_x to unit_y" {
    const half_sqrt2 = FP.fromFloat(std.math.sqrt2 / 2.0);
    const q90z = FQuat.init(FP.zero, FP.zero, half_sqrt2, half_sqrt2);
    const rotated = q90z.rotate(FVec3.unit_x);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), rotated.x.toF64(), 0.002);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), rotated.y.toF64(), 0.002);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), rotated.z.toF64(), 0.002);
}

test "FQuat: rotate — 90° about z maps unit_y to -unit_x" {
    const half_sqrt2 = FP.fromFloat(std.math.sqrt2 / 2.0);
    const q90z = FQuat.init(FP.zero, FP.zero, half_sqrt2, half_sqrt2);
    const rotated = q90z.rotate(FVec3.unit_y);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), rotated.x.toF64(), 0.002);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), rotated.y.toF64(), 0.002);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), rotated.z.toF64(), 0.002);
}

test "FQuat: eql negative case" {
    const a = FQuat.identity;
    const b = FQuat.init(FP.one, FP.zero, FP.zero, FP.zero);
    try std.testing.expect(!a.eql(b));
}

test "FQuat: toQuatf" {
    const half_sqrt2 = FP.fromFloat(std.math.sqrt2 / 2.0);
    const fq = FQuat.init(FP.zero, FP.zero, half_sqrt2, half_sqrt2);
    const rf = fq.toQuatf();
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), rf.x, 0.002);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), rf.y, 0.002);
    try std.testing.expectApproxEqAbs(@as(f32, std.math.sqrt2 / 2.0), rf.z, 0.002);
    try std.testing.expectApproxEqAbs(@as(f32, std.math.sqrt2 / 2.0), rf.w, 0.002);
}

test "Vec3f: neg" {
    const a = Vec3f.init(1, -2, 3);
    const n = Vec3f.neg(a);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), n.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), n.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -3.0), n.z, 0.001);
}

test "Vec3f: cross product" {
    // x × y = z
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), Vec3f.unit_x.cross(Vec3f.unit_y).x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), Vec3f.unit_x.cross(Vec3f.unit_y).y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), Vec3f.unit_x.cross(Vec3f.unit_y).z, 0.001);
    // y × x = -z (anti-commutativity)
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), Vec3f.unit_y.cross(Vec3f.unit_x).z, 0.001);
}

test "Vec3f: len_sq" {
    try std.testing.expectApproxEqAbs(@as(f32, 25.0), Vec3f.init(3, 4, 0).len_sq(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), Vec3f.zero.len_sq(), 0.001);
}

test "Vec3f: normalize produces unit vector" {
    const v = Vec3f.init(3, 4, 0);
    const n = v.normalize();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), n.len(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), n.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), n.y, 0.001);
}

test "Vec3f: lerp at endpoints" {
    const a = Vec3f.init(1, 2, 3);
    const b = Vec3f.init(7, 8, 9);
    // t=0 returns a
    const at0 = Vec3f.lerp(a, b, 0.0);
    try std.testing.expectApproxEqAbs(a.x, at0.x, 0.001);
    try std.testing.expectApproxEqAbs(a.z, at0.z, 0.001);
    // t=1 returns b
    const at1 = Vec3f.lerp(a, b, 1.0);
    try std.testing.expectApproxEqAbs(b.x, at1.x, 0.001);
    try std.testing.expectApproxEqAbs(b.z, at1.z, 0.001);
}

test "Vec4f: fromVec3 and toVec3 round-trip" {
    const v3 = Vec3f.init(1, 2, 3);
    const v4 = Vec4f.fromVec3(v3, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), v4.w, 0.001);
    const back = v4.toVec3();
    try std.testing.expectApproxEqAbs(v3.x, back.x, 0.001);
    try std.testing.expectApproxEqAbs(v3.y, back.y, 0.001);
    try std.testing.expectApproxEqAbs(v3.z, back.z, 0.001);
}

test "Vec4f: dot" {
    const a = Vec4f.init(1, 2, 3, 4);
    const b = Vec4f.init(5, 6, 7, 8);
    // 5+12+21+32 = 70
    try std.testing.expectApproxEqAbs(@as(f32, 70.0), Vec4f.dot(a, b), 0.001);
}

test "Mat4f: uniform_scale" {
    const m = Mat4f.uniform_scale(3.0);
    const v = Vec4f.init(1, 2, 3, 1);
    const result = m.mul_vec4(v);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), result.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), result.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), result.z, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result.w, 0.001);
}

test "Mat4f: translation does not move direction vectors (w=0)" {
    const t = Mat4f.translation(Vec3f.init(5, 3, 1));
    // A direction vector (w=0) must not be affected by translation.
    const dir = Vec4f.init(1, 0, 0, 0);
    const result = t.mul_vec4(dir);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result.z, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result.w, 0.001);
}

test "Mat4f: mul — two translations compose" {
    const t1 = Mat4f.translation(Vec3f.init(1, 2, 3));
    const t2 = Mat4f.translation(Vec3f.init(4, 5, 6));
    const combined = t1.mul(t2);
    const p = Vec4f.fromVec3(Vec3f.zero, 1.0);
    const result = combined.mul_vec4(p);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), result.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), result.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), result.z, 0.001);
}

test "Mat4f: ortho — maps corners to NDC correctly" {
    // Maps the volume [-10,10]x[-5,5]x[1,100] to NDC [−1,1]x[−1,1]x[0,1].
    const m = Mat4f.ortho(-10, 10, -5, 5, 1, 100);

    // Near-plane top-right corner (10, 5, 1) → (1, 1, 0)
    const near_tr = m.mul_vec4(Vec4f.init(10, 5, 1, 1));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), near_tr.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), near_tr.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), near_tr.z, 0.001);

    // Far-plane top-right corner (10, 5, 100) → (1, 1, 1)
    const far_tr = m.mul_vec4(Vec4f.init(10, 5, 100, 1));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), far_tr.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), far_tr.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), far_tr.z, 0.001);

    // Near-plane bottom-left corner (-10, -5, 1) → (-1, -1, 0)
    const near_bl = m.mul_vec4(Vec4f.init(-10, -5, 1, 1));
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), near_bl.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), near_bl.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), near_bl.z, 0.001);

    // Center of the volume → (0, 0, 0.5)
    const mid_z = 1.0 + (100.0 - 1.0) / 2.0; // midpoint of [1, 100]
    const center = m.mul_vec4(Vec4f.init(0, 0, mid_z, 1));
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), center.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), center.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), center.z, 0.001);
}

test "Mat4f: perspective — w component is z for depth" {
    // For a perspective matrix the w component of the result must equal the input z.
    const m = Mat4f.perspective(std.math.pi / 2.0, 16.0 / 9.0, 0.1, 1000.0);
    const p = Vec4f.init(0, 0, 5, 1); // point on the camera axis at depth 5
    const result = m.mul_vec4(p);
    // w_clip = z_eye = 5 (right-handed convention)
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), result.w, 0.01);
    // x=0, y=0 maps to x_clip=0, y_clip=0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result.y, 0.001);
}

test "Mat4f: look_at — forward axis" {
    // Camera at (0,0,-5) looking at origin with up=(0,1,0).
    const view = Mat4f.look_at(
        Vec3f.init(0, 0, -5),
        Vec3f.zero,
        Vec3f.unit_y,
    );
    // Origin in view space should have z < 0 (in front of camera in
    // right-handed convention where the camera looks along -z).
    const origin_view = view.mul_vec4(Vec4f.fromVec3(Vec3f.zero, 1.0));
    try std.testing.expect(origin_view.z < 0.0);
    // The eye itself in view space is at (0,0,0).
    const eye_view = view.mul_vec4(Vec4f.init(0, 0, -5, 1));
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), eye_view.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), eye_view.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), eye_view.z, 0.001);
}

test "Mat4f: ptr returns pointer to first element" {
    const m = Mat4f.identity;
    const p = m.ptr();
    // First element of column-major identity is 1.0.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), p.*, 0.001);
}

test "isqrt: edge cases" {
    try std.testing.expectEqual(@as(u64, 0), isqrt(0));
    try std.testing.expectEqual(@as(u64, 1), isqrt(1));
    try std.testing.expectEqual(@as(u64, 1), isqrt(3)); // floor(sqrt(3)) = 1
    try std.testing.expectEqual(@as(u64, 2), isqrt(4));
    try std.testing.expectEqual(@as(u64, 3), isqrt(9));
    try std.testing.expectEqual(@as(u64, 10), isqrt(100));
    // isqrt is a floor: sqrt(99) ≈ 9.949, floor = 9
    try std.testing.expectEqual(@as(u64, 9), isqrt(99));
    try std.testing.expectEqual(@as(u64, 3), isqrt(15)); // floor(sqrt(15)) = 3
}

test "FVec3: normalize — zero vector returns zero" {
    // Zero vector must not divide by zero; must return FVec3.zero.
    const result = FVec3.zero.normalize();
    try std.testing.expect(FVec3.zero.eql(result));
}

test "FVec3: normalize — (3, 4, 0) yields unit vector" {
    // Pythagorean triple: |(3,4,0)| = 5. Unit vector ≈ (0.6, 0.8, 0).
    const v = FVec3.fromInts(3, 4, 0);
    const n = v.normalize();
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), n.len().toF64(), 0.01);
    // Direction should point mostly in x and y.
    try std.testing.expect(n.x.raw > 0);
    try std.testing.expect(n.y.raw > 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), n.z.toF64(), 0.01);
}

test "Quatf: mul — identity absorbs" {
    const q = Quatf.init(0, 0, std.math.sqrt2 / 2.0, std.math.sqrt2 / 2.0);
    const lhs = Quatf.identity.mul(q);
    try std.testing.expectApproxEqAbs(q.x, lhs.x, 0.001);
    try std.testing.expectApproxEqAbs(q.w, lhs.w, 0.001);
}

test "Quatf: toFQuat" {
    const q = Quatf.init(0, 0, std.math.sqrt2 / 2.0, std.math.sqrt2 / 2.0);
    const fq = q.toFQuat();
    try std.testing.expectApproxEqAbs(q.x, fq.x.toF32(), 0.002);
    try std.testing.expectApproxEqAbs(q.z, fq.z.toF32(), 0.002);
    try std.testing.expectApproxEqAbs(q.w, fq.w.toF32(), 0.002);
}

test "Vec3f: toFVec3 and back to Vec3f" {
    const v = Vec3f.init(3.5, -1.25, 0.0);
    const fp = v.toFVec3();
    const back = fp.toVec3f();
    // Round-trip should be within 1 ULP of Q16.16 precision (1/65536 ≈ 0.000015).
    try std.testing.expectApproxEqAbs(v.x, back.x, 0.0002);
    try std.testing.expectApproxEqAbs(v.y, back.y, 0.0002);
    try std.testing.expectApproxEqAbs(v.z, back.z, 0.0002);
}

test "Ease.outQuart: boundary values" {
    // f(0) = 0, f(1) = 1 — required for all standard easing functions.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), Ease.outQuart(0.0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), Ease.outQuart(1.0), 0.0001);
}

test "Ease.outQuart: midpoint is greater than linear" {
    // Ease-out is fast at the start, so f(0.5) > 0.5 (above the linear diagonal).
    try std.testing.expect(Ease.outQuart(0.5) > 0.5);
}

test "Ease.outQuart: monotonically increasing" {
    // Verify f is strictly increasing across the [0, 1] domain.
    var prev: f32 = Ease.outQuart(0.0);
    var i: u32 = 1;
    while (i <= 10) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / 10.0;
        const cur = Ease.outQuart(t);
        try std.testing.expect(cur > prev);
        prev = cur;
    }
}

test "Ease.outQuart: known value at t=0.5" {
    // f(0.5) = 1 − (0.5)⁴ = 1 − 0.0625 = 0.9375
    try std.testing.expectApproxEqAbs(@as(f32, 0.9375), Ease.outQuart(0.5), 0.0001);
}
