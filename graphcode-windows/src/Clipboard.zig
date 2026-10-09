const std = @import("std");
const c = @import("Win32.zig").c;

pub fn encodeUtf16(allocator: std.mem.Allocator, text: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
}

pub fn decodeUtf16(allocator: std.mem.Allocator, text: []const u16) ![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(allocator, text);
}

pub fn writeText(owner: c.HWND, allocator: std.mem.Allocator, text: []const u8) !void {
    if (owner == null) return error.ClipboardOwnerUnavailable;
    const encoded = try encodeUtf16(allocator, text);
    defer allocator.free(encoded);

    const unit_count = try std.math.add(usize, encoded.len, 1);
    const byte_count = try std.math.mul(usize, unit_count, @sizeOf(u16));
    const memory = c.GlobalAlloc(c.GMEM_MOVEABLE, byte_count) orelse return error.ClipboardAllocationFailed;
    var clipboard_owns_memory = false;
    defer if (!clipboard_owns_memory) {
        _ = c.GlobalFree(memory);
    };

    const locked = c.GlobalLock(memory) orelse return error.ClipboardLockFailed;
    const destination: [*]u16 = @ptrCast(@alignCast(locked));
    @memcpy(destination[0..encoded.len], encoded);
    destination[encoded.len] = 0;
    _ = c.GlobalUnlock(memory);

    if (c.OpenClipboard(owner) == 0) return error.ClipboardOpenFailed;
    defer _ = c.CloseClipboard();
    if (c.EmptyClipboard() == 0) return error.ClipboardClearFailed;
    if (c.SetClipboardData(c.CF_UNICODETEXT, memory) == null) return error.ClipboardWriteFailed;
    clipboard_owns_memory = true;
}

pub fn readText(owner: c.HWND, allocator: std.mem.Allocator) ![]u8 {
    if (owner == null) return error.ClipboardOwnerUnavailable;
    if (c.OpenClipboard(owner) == 0) return error.ClipboardOpenFailed;
    defer _ = c.CloseClipboard();

    const memory = c.GetClipboardData(c.CF_UNICODETEXT) orelse return error.ClipboardTextUnavailable;
    const byte_count = c.GlobalSize(memory);
    if (byte_count < @sizeOf(u16) or byte_count % @sizeOf(u16) != 0) return error.InvalidClipboardText;
    const locked = c.GlobalLock(memory) orelse return error.ClipboardLockFailed;
    defer _ = c.GlobalUnlock(memory);

    const units: [*]const u16 = @ptrCast(@alignCast(locked));
    const capacity = byte_count / @sizeOf(u16);
    var length: usize = 0;
    while (length < capacity and units[length] != 0) : (length += 1) {}
    if (length == capacity) return error.UnterminatedClipboardText;
    return decodeUtf16(allocator, units[0..length]);
}

test "clipboard UTF-16 conversion preserves Unicode and multiline text" {
    const text = "snowman ☃, emoji \u{1f642}\r\nsecond line\nthird line";
    const wide = try encodeUtf16(std.testing.allocator, text);
    defer std.testing.allocator.free(wide);

    try std.testing.expectEqual(@as(u16, 0), wide.ptr[wide.len]);
    const round_trip = try decodeUtf16(std.testing.allocator, wide);
    defer std.testing.allocator.free(round_trip);
    try std.testing.expectEqualStrings(text, round_trip);
}

test "clipboard UTF-16 conversion preserves empty text" {
    const wide = try encodeUtf16(std.testing.allocator, "");
    defer std.testing.allocator.free(wide);
    try std.testing.expectEqual(@as(usize, 0), wide.len);
    try std.testing.expectEqual(@as(u16, 0), wide.ptr[0]);

    const round_trip = try decodeUtf16(std.testing.allocator, wide);
    defer std.testing.allocator.free(round_trip);
    try std.testing.expectEqualStrings("", round_trip);
}

test "clipboard Win32 operations require an owner window" {
    try std.testing.expectError(
        error.ClipboardOwnerUnavailable,
        writeText(null, std.testing.allocator, "text"),
    );
    try std.testing.expectError(
        error.ClipboardOwnerUnavailable,
        readText(null, std.testing.allocator),
    );
}
