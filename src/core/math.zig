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

    /// Normalize to unit length. Asserts the vector is non-zero.
    pub fn normalize(a: FVec3) FVec3 {
        const l = a.len();
        std.debug.assert(l.raw != 0);
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

test "Vec3f: toFVec3 and back to Vec3f" {
    const v = Vec3f.init(3.5, -1.25, 0.0);
    const fp = v.toFVec3();
    const back = fp.toVec3f();
    // Round-trip should be within 1 ULP of Q16.16 precision (1/65536 ≈ 0.000015).
    try std.testing.expectApproxEqAbs(v.x, back.x, 0.0002);
    try std.testing.expectApproxEqAbs(v.y, back.y, 0.0002);
    try std.testing.expectApproxEqAbs(v.z, back.z, 0.0002);
}
