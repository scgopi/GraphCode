const std = @import("std");
const c = @import("Win32.zig").c;

pub fn encodeUtf16(allocator: std.mem.Allocator, text: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
}

pub fn decodeUtf16(allocator: std.mem.Allocator, text: []const u16) ![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(allocator, text);
}

const NativeApi = struct {
    fn open(owner: c.HWND) bool {
        return c.OpenClipboard(owner) != 0;
    }

    fn close() void {
        _ = c.CloseClipboard();
    }

    fn empty() bool {
        return c.EmptyClipboard() != 0;
    }

    /// A copy of the clipboard's Unicode text with its terminator, or null when it has none
    /// (or the copy could not be made); the caller frees it.
    fn readUnits(allocator: std.mem.Allocator) ?[]u16 {
        const memory = c.GetClipboardData(c.CF_UNICODETEXT) orelse return null;
        const byte_count = c.GlobalSize(memory);
        if (byte_count < @sizeOf(u16) or byte_count % @sizeOf(u16) != 0) return null;
        const locked = c.GlobalLock(memory) orelse return null;
        defer _ = c.GlobalUnlock(memory);
        const source: [*]const u16 = @ptrCast(@alignCast(locked));
        const copy = allocator.alloc(u16, byte_count / @sizeOf(u16)) catch return null;
        @memcpy(copy, source[0..copy.len]);
        return copy;
    }

    /// Hands `units` (terminator included) to the clipboard, which owns the memory on success.
    fn setUnits(units: []const u16) bool {
        const memory = c.GlobalAlloc(c.GMEM_MOVEABLE, units.len * @sizeOf(u16)) orelse return false;
        const locked = c.GlobalLock(memory) orelse {
            _ = c.GlobalFree(memory);
            return false;
        };
        const destination: [*]u16 = @ptrCast(@alignCast(locked));
        @memcpy(destination[0..units.len], units);
        _ = c.GlobalUnlock(memory);
        if (c.SetClipboardData(c.CF_UNICODETEXT, memory) == null) {
            _ = c.GlobalFree(memory);
            return false;
        }
        return true;
    }
};

pub fn writeText(owner: c.HWND, allocator: std.mem.Allocator, text: []const u8) !void {
    return writeTextWith(NativeApi, owner, allocator, text);
}

/// Replaces the clipboard's text. Windows only lets a program set the clipboard after emptying
/// it, so a refusal of the new text would lose what the user had copied; the previous text is
/// therefore read first and put back if the write fails, and the error says which happened.
/// Non-text formats the clipboard held are not preserved either way.
fn writeTextWith(comptime Api: type, owner: c.HWND, allocator: std.mem.Allocator, text: []const u8) !void {
    if (owner == null) return error.ClipboardOwnerUnavailable;
    const encoded = try encodeUtf16(allocator, text);
    defer allocator.free(encoded);

    if (!Api.open(owner)) return error.ClipboardOpenFailed;
    defer Api.close();
    const previous = Api.readUnits(allocator);
    defer if (previous) |units| allocator.free(units);
    if (!Api.empty()) return error.ClipboardClearFailed;
    if (Api.setUnits(encoded.ptr[0 .. encoded.len + 1])) return;
    if (previous) |units| {
        if (Api.setUnits(units)) return error.ClipboardWriteFailedKeptPreviousText;
        return error.ClipboardWriteFailedLostPreviousText;
    }
    return error.ClipboardWriteFailed;
}

/// Reads the clipboard's Unicode text as UTF-8. Text longer than `max_units` UTF-16 units is
/// refused without being decoded; every unit is at least one UTF-8 byte, so it could not fit
/// within a `max_units`-byte paste anyway.
pub fn readText(owner: c.HWND, allocator: std.mem.Allocator, max_units: usize) ![]u8 {
    if (owner == null) return error.ClipboardOwnerUnavailable;
    if (c.OpenClipboard(owner) == 0) return error.ClipboardOpenFailed;
    defer _ = c.CloseClipboard();

    const memory = c.GetClipboardData(c.CF_UNICODETEXT) orelse return error.ClipboardTextUnavailable;
    const byte_count = c.GlobalSize(memory);
    if (byte_count < @sizeOf(u16) or byte_count % @sizeOf(u16) != 0) return error.InvalidClipboardText;
    const locked = c.GlobalLock(memory) orelse return error.ClipboardLockFailed;
    defer _ = c.GlobalUnlock(memory);

    const units: [*]const u16 = @ptrCast(@alignCast(locked));
    return textFromUnits(allocator, units, byte_count / @sizeOf(u16), max_units);
}

fn textFromUnits(allocator: std.mem.Allocator, units: [*]const u16, capacity: usize, max_units: usize) ![]u8 {
    const scan_limit = @min(capacity, max_units +| 1);
    var length: usize = 0;
    while (length < scan_limit and units[length] != 0) : (length += 1) {}
    if (length > max_units) return error.ClipboardTextTooLarge;
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
        readText(null, std.testing.allocator, 100),
    );
}

/// A stand-in clipboard that follows the Win32 rules this code depends on: a write needs the
/// clipboard emptied first, and the stand-in can refuse writes or fail to open or empty.
const FakeClipboard = struct {
    var storage: [64]u16 = undefined;
    var held: ?[]const u16 = null;
    var open_ok = true;
    var empty_ok = true;
    var refused_sets: usize = 0;
    var sets: usize = 0;
    var closes: usize = 0;

    fn units(comptime text: []const u8) []const u16 {
        const literal = std.unicode.utf8ToUtf16LeStringLiteral(text);
        return literal.ptr[0 .. literal.len + 1];
    }

    fn reset(text: ?[]const u16) void {
        if (text) |value| {
            @memcpy(storage[0..value.len], value);
            held = storage[0..value.len];
        } else held = null;
        open_ok = true;
        empty_ok = true;
        refused_sets = 0;
        sets = 0;
        closes = 0;
    }

    fn open(_: c.HWND) bool {
        return open_ok;
    }

    fn close() void {
        closes += 1;
    }

    fn empty() bool {
        if (!empty_ok) return false;
        held = null;
        return true;
    }

    fn readUnits(allocator: std.mem.Allocator) ?[]u16 {
        const value = held orelse return null;
        return allocator.dupe(u16, value) catch null;
    }

    fn setUnits(value: []const u16) bool {
        sets += 1;
        if (sets <= refused_sets) return false;
        @memcpy(storage[0..value.len], value);
        held = storage[0..value.len];
        return true;
    }

    fn expectHeld(expected: ?[]const u16) !void {
        if (expected) |value| {
            try std.testing.expect(held != null);
            try std.testing.expectEqualSlices(u16, value, held.?);
        } else try std.testing.expect(held == null);
    }
};

const fake_owner: c.HWND = @ptrFromInt(0x1000);

test "clipboard write replaces the previous text" {
    FakeClipboard.reset(FakeClipboard.units("old"));
    try writeTextWith(FakeClipboard, fake_owner, std.testing.allocator, "new");
    try FakeClipboard.expectHeld(FakeClipboard.units("new"));
    try std.testing.expectEqual(@as(usize, 1), FakeClipboard.closes);
}

test "a refused clipboard write puts the user's previous text back and says so" {
    FakeClipboard.reset(FakeClipboard.units("old"));
    FakeClipboard.refused_sets = 1;
    try std.testing.expectError(
        error.ClipboardWriteFailedKeptPreviousText,
        writeTextWith(FakeClipboard, fake_owner, std.testing.allocator, "new"),
    );
    try FakeClipboard.expectHeld(FakeClipboard.units("old"));
    try std.testing.expectEqual(@as(usize, 2), FakeClipboard.sets);
    try std.testing.expectEqual(@as(usize, 1), FakeClipboard.closes);
}

test "a refused write that also cannot restore the previous text reports the loss" {
    FakeClipboard.reset(FakeClipboard.units("old"));
    FakeClipboard.refused_sets = 2;
    try std.testing.expectError(
        error.ClipboardWriteFailedLostPreviousText,
        writeTextWith(FakeClipboard, fake_owner, std.testing.allocator, "new"),
    );
    try FakeClipboard.expectHeld(null);
}

test "a refused write over a clipboard with no text is a plain write failure" {
    FakeClipboard.reset(null);
    FakeClipboard.refused_sets = 1;
    try std.testing.expectError(
        error.ClipboardWriteFailed,
        writeTextWith(FakeClipboard, fake_owner, std.testing.allocator, "new"),
    );
    try std.testing.expectEqual(@as(usize, 1), FakeClipboard.sets);
}

test "a clipboard that cannot be opened or emptied is left as it was" {
    FakeClipboard.reset(FakeClipboard.units("old"));
    FakeClipboard.open_ok = false;
    try std.testing.expectError(
        error.ClipboardOpenFailed,
        writeTextWith(FakeClipboard, fake_owner, std.testing.allocator, "new"),
    );
    try std.testing.expectEqual(@as(usize, 0), FakeClipboard.closes);
    try FakeClipboard.expectHeld(FakeClipboard.units("old"));

    FakeClipboard.reset(FakeClipboard.units("old"));
    FakeClipboard.empty_ok = false;
    try std.testing.expectError(
        error.ClipboardClearFailed,
        writeTextWith(FakeClipboard, fake_owner, std.testing.allocator, "new"),
    );
    try std.testing.expectEqual(@as(usize, 1), FakeClipboard.closes);
    try FakeClipboard.expectHeld(FakeClipboard.units("old"));
}

test "clipboard text over the limit is refused before it is decoded" {
    const allocator = std.testing.allocator;
    const exact = FakeClipboard.units("abc");
    const text = try textFromUnits(allocator, exact.ptr, exact.len, 3);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("abc", text);

    const longer = FakeClipboard.units("abcd");
    try std.testing.expectError(error.ClipboardTextTooLarge, textFromUnits(allocator, longer.ptr, longer.len, 3));
    // A terminator before the limit ends the text even when the block is much larger.
    var block = [_]u16{0} ** 16;
    block[0] = 'o';
    block[1] = 'k';
    const short = try textFromUnits(allocator, &block, block.len, 3);
    defer allocator.free(short);
    try std.testing.expectEqualStrings("ok", short);
    const unterminated = [_]u16{ 'a', 'b', 'c' };
    try std.testing.expectError(error.UnterminatedClipboardText, textFromUnits(allocator, &unterminated, unterminated.len, 10));
}
