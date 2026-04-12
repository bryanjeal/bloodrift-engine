const std = @import("std");

/// Color represented as RGBA components in [0,255].
pub const Color = extern struct {
    /// Red channel
    r: u8,
    /// Green channel
    g: u8,
    /// Blue channel
    b: u8,
    /// Alpha channel
    a: u8,

    /// Check for equality between two Colors.
    pub fn eq(self: Color, other: Color) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b and self.a == other.a;
    }

    /// Create a Color from RGBA components in [0,255].
    pub fn fromRGBA(r: u8, g: u8, b: u8, a: u8) Color {
        return Color{
            .r = r,
            .g = g,
            .b = b,
            .a = a,
        };
    }

    /// Convert to RGBA array of normalized floats in [0,1].
    pub fn toArray(self: Color) [4]f32 {
        return .{
            @as(f32, @floatFromInt(self.r)) / 255.0,
            @as(f32, @floatFromInt(self.g)) / 255.0,
            @as(f32, @floatFromInt(self.b)) / 255.0,
            @as(f32, @floatFromInt(self.a)) / 255.0,
        };
    }

    /// Convert from RGBA array of normalized floats in [0,1] to Color.
    pub fn fromArray(arr: [4]f32) Color {
        return Color{
            .r = @as(u8, @intFromFloat(arr[0] * 255)),
            .g = @as(u8, @intFromFloat(arr[1] * 255)),
            .b = @as(u8, @intFromFloat(arr[2] * 255)),
            .a = @as(u8, @intFromFloat(arr[3] * 255)),
        };
    }

    /// Convert to a single u32 hex value in RGBA order (0xRRGGBBAA).
    pub fn toHex(self: Color) u32 {
        return (@as(u32, self.r) << 24) | (@as(u32, self.g) << 16) | (@as(u32, self.b) << 8) | @as(u32, self.a);
    }

    /// Convert from a single u32 hex value in RGBA order (0xRRGGBBAA) to Color.
    pub fn fromHex(hex: u32) Color {
        return Color{
            .r = @as(u8, @intCast((hex >> 24) & 0xFF)),
            .g = @as(u8, @intCast((hex >> 16) & 0xFF)),
            .b = @as(u8, @intCast((hex >> 8) & 0xFF)),
            .a = @as(u8, @intCast(hex & 0xFF)),
        };
    }

    pub const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const grey = Color{ .r = 128, .g = 128, .b = 128, .a = 255 };
    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

    pub const red = Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
    pub const green = Color{ .r = 0, .g = 255, .b = 0, .a = 255 };
    pub const blue = Color{ .r = 0, .g = 0, .b = 255, .a = 255 };

    pub const cyan = Color{ .r = 0, .g = 255, .b = 255, .a = 255 };
    pub const yellow = Color{ .r = 255, .g = 255, .b = 0, .a = 255 };
    pub const magenta = Color{ .r = 255, .g = 0, .b = 255, .a = 255 };

    pub const orange = Color{ .r = 255, .g = 165, .b = 0, .a = 255 };
    pub const purple = Color{ .r = 128, .g = 0, .b = 128, .a = 255 };
    pub const brown = Color{ .r = 165, .g = 42, .b = 42, .a = 255 };
    pub const ivory = Color{ .r = 255, .g = 255, .b = 240, .a = 255 };
    pub const golden = Color{ .r = 255, .g = 215, .b = 0, .a = 255 };
    pub const white_ghostly = Color{ .r = 204, .g = 229, .b = 255, .a = 255 };
    pub const green_toxic = Color{ .r = 90, .g = 204, .b = 51, .a = 255 };
    pub const yellow_pale = Color{ .r = 255, .g = 255, .b = 204, .a = 255 };

    pub const blue_light = Color{ .r = 173, .g = 216, .b = 230, .a = 255 };
    pub const red_light = Color{ .r = 255, .g = 182, .b = 193, .a = 255 };
    pub const green_light = Color{ .r = 144, .g = 238, .b = 144, .a = 255 };
    pub const yellow_light = Color{ .r = 255, .g = 255, .b = 224, .a = 255 };
    pub const magenta_light = Color{ .r = 255, .g = 182, .b = 255, .a = 255 };
    pub const orange_light = Color{ .r = 255, .g = 200, .b = 0, .a = 255 };
    pub const purple_light = Color{ .r = 216, .g = 191, .b = 216, .a = 255 };
    pub const brown_light = Color{ .r = 222, .g = 184, .b = 135, .a = 255 };
    pub const golden_light = Color{ .r = 255, .g = 223, .b = 0, .a = 255 };
    pub const grey_light = Color{ .r = 211, .g = 211, .b = 211, .a = 255 };

    pub const red_dark = Color{ .r = 139, .g = 0, .b = 0, .a = 255 };
    pub const purple_dark = Color{ .r = 75, .g = 0, .b = 130, .a = 255 };
    pub const magenta_dark = Color{ .r = 139, .g = 0, .b = 139, .a = 255 };
    pub const grey_dark = Color{ .r = 64, .g = 64, .b = 64, .a = 255 };
    pub const blue_dark = Color{ .r = 0, .g = 0, .b = 139, .a = 255 };
};

test "Color conversions" {
    const expected_white_hex: u32 = 0xFFFFFFFF;
    const actual_white_from_hex = Color.fromHex(expected_white_hex);
    try std.testing.expect(Color.white.eq(actual_white_from_hex));

    const magenta_arr_expected: [4]f32 = .{ 1.0, 0.0, 1.0, 1.0 };
    const magenta_arr_actual = Color.magenta.toArray();
    try std.testing.expectEqualSlices(f32, &magenta_arr_expected, &magenta_arr_actual);

    const magenta_from_arr = Color.fromArray(magenta_arr_expected);
    try std.testing.expect(Color.magenta.eq(magenta_from_arr));

    const hex = actual_white_from_hex.toHex();
    try std.testing.expect(hex == expected_white_hex);

    const expected_white: Color = Color.fromRGBA(255, 255, 255, 255);
    try std.testing.expect(expected_white.eq(actual_white_from_hex));
    try std.testing.expect(expected_white.eq(Color.white));

    // Define an acceptable margin of error (e.g., 0.01 is plenty for 8-bit color rounding)
    const tolerance: f32 = 0.01;

    const c_arr_expected: [4]f32 = .{ 0.3, 0.3, 0.3, 1.0 };
    const c = Color.fromArray(c_arr_expected);
    const c_arr_actual = c.toArray();
    // Loop through both arrays simultaneously
    for (&c_arr_expected, &c_arr_actual) |expected_val, actual_val| {
        try std.testing.expectApproxEqAbs(expected_val, actual_val, tolerance);
    }

    const c2 = Color.fromArray(c_arr_actual);
    try std.testing.expect(c.eq(c2));
}
