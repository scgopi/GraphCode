const std = @import("std");

pub const base_dpi: u32 = 96;

pub fn normalize(dpi: u32) u32 {
    return if (dpi == 0) base_dpi else dpi;
}

pub fn scale(value: i32, dpi: u32) i32 {
    const normalized = normalize(dpi);
    const scaled = @divTrunc(
        @as(i64, value) * @as(i64, normalized) + @as(i64, base_dpi / 2),
        @as(i64, base_dpi),
    );
    return @intCast(scaled);
}

pub fn unscale(value: i32, dpi: u32) i32 {
    const normalized = normalize(dpi);
    const scaled = @divTrunc(
        @as(i64, value) * @as(i64, base_dpi) + @as(i64, normalized / 2),
        @as(i64, normalized),
    );
    return @intCast(scaled);
}

/// The font/UI scale factor a DPI-aware host (e.g. a winghostty terminal surface)
/// should apply so its glyph rendering matches the monitor's DPI: 1.0 at 96 DPI
/// (100%), 1.25 at 120 DPI (125%), etc. This is the single source of truth for
/// terminal DPI scaling so callers never also pre-scale cell/font metrics
/// themselves, which would double-apply the DPI ratio.
pub fn fontScale(dpi: u32) f32 {
    return @as(f32, @floatFromInt(normalize(dpi))) / @as(f32, @floatFromInt(base_dpi));
}

test "font scale matches the standard Windows DPI steps" {
    try std.testing.expectEqual(@as(f32, 1.0), fontScale(96));
    try std.testing.expectEqual(@as(f32, 1.25), fontScale(120));
    try std.testing.expectEqual(@as(f32, 1.5), fontScale(144));
    try std.testing.expectEqual(@as(f32, 2.0), fontScale(192));
    try std.testing.expectEqual(@as(f32, 1.0), fontScale(0));
}

test "DPI scaling rounds at the native boundary" {
    try std.testing.expectEqual(@as(i32, 100), scale(100, 96));
    try std.testing.expectEqual(@as(i32, 125), scale(100, 120));
    try std.testing.expectEqual(@as(i32, 150), scale(100, 144));
    try std.testing.expectEqual(@as(i32, 100), unscale(125, 120));
}

test "zero DPI falls back to the Windows base DPI" {
    try std.testing.expectEqual(base_dpi, normalize(0));
    try std.testing.expectEqual(@as(i32, 42), scale(42, 0));
}
