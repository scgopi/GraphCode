const std = @import("std");
const c = @import("Win32.zig").c;

pub fn encodeUtf16(allocator: std.mem.Allocator, text: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
}

pub fn decodeUtf16(allocator: std.mem.Allocator, text: []const u16) ![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(allocator, text);
}

/// What the clipboard held as Unicode text before a write.
const Snapshot = union(enum) {
    /// No Unicode text: nothing there to lose.
    none,
    /// The text through its terminator; the caller frees it.
    units: []u16,
    /// Unicode text is there but could not be copied safely, so a write must not empty it.
    unreadable,
};

/// Copies a clipboard text block through its first terminator, never reading past `capacity`
/// units. A block with no terminator is not valid CF_UNICODETEXT and is not republished.
fn snapshotUnits(allocator: std.mem.Allocator, units: [*]const u16, capacity: usize) Snapshot {
    var length: usize = 0;
    while (length < capacity and units[length] != 0) : (length += 1) {}
    if (length == capacity) return .unreadable;
    const copy = allocator.alloc(u16, length + 1) catch return .unreadable;
    @memcpy(copy[0..length], units[0..length]);
    copy[length] = 0;
    return .{ .units = copy };
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

    fn snapshot(allocator: std.mem.Allocator) Snapshot {
        if (c.IsClipboardFormatAvailable(c.CF_UNICODETEXT) == 0) return .none;
        const memory = c.GetClipboardData(c.CF_UNICODETEXT) orelse return .unreadable;
        const byte_count = c.GlobalSize(memory);
        if (byte_count < @sizeOf(u16)) return .unreadable;
        const locked = c.GlobalLock(memory) orelse return .unreadable;
        defer _ = c.GlobalUnlock(memory);
        const source: [*]const u16 = @ptrCast(@alignCast(locked));
        return snapshotUnits(allocator, source, byte_count / @sizeOf(u16));
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
/// it, so a refusal of the new text would lose what the user had copied. The previous Unicode
/// text is therefore copied first and put back if the write fails, and the error says which
/// happened. If Unicode text is there but cannot be copied safely, the clipboard is left alone
/// and the copy fails. Only the Unicode text is protected: emptying the clipboard removes every
/// other format (images, HTML, RTF, files), which are not restored, and a successful copy
/// replaces them as well.
fn writeTextWith(comptime Api: type, owner: c.HWND, allocator: std.mem.Allocator, text: []const u8) !void {
    if (owner == null) return error.ClipboardOwnerUnavailable;
    const encoded = try encodeUtf16(allocator, text);
    defer allocator.free(encoded);

    if (!Api.open(owner)) return error.ClipboardOpenFailed;
    defer Api.close();
    const previous = Api.snapshot(allocator);
    defer if (previous == .units) allocator.free(previous.units);
    if (previous == .unreadable) return error.ClipboardPreviousTextUnreadable;
    if (!Api.empty()) return error.ClipboardClearFailed;
    if (Api.setUnits(encoded.ptr[0 .. encoded.len + 1])) return;
    if (previous == .units) {
        if (Api.setUnits(previous.units)) return error.ClipboardWriteFailedKeptPreviousText;
        return error.ClipboardWriteFailedLostPreviousText;
    }
    return error.ClipboardWriteFailed;
}

/// Reads the clipboard's Unicode text as UTF-8. Text that would be longer than `max_bytes`
/// UTF-8 bytes is refused with nothing allocated for it: a block of more than `max_bytes`
/// UTF-16 units cannot fit (each unit is at least one byte), and a smaller one has its exact
/// UTF-8 length computed before it is converted.
pub fn readText(owner: c.HWND, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    if (owner == null) return error.ClipboardOwnerUnavailable;
    if (c.OpenClipboard(owner) == 0) return error.ClipboardOpenFailed;
    defer _ = c.CloseClipboard();

    const memory = c.GetClipboardData(c.CF_UNICODETEXT) orelse return error.ClipboardTextUnavailable;
    const byte_count = c.GlobalSize(memory);
    if (byte_count < @sizeOf(u16) or byte_count % @sizeOf(u16) != 0) return error.InvalidClipboardText;
    const locked = c.GlobalLock(memory) orelse return error.ClipboardLockFailed;
    defer _ = c.GlobalUnlock(memory);

    const units: [*]const u16 = @ptrCast(@alignCast(locked));
    return textFromUnits(allocator, units, byte_count / @sizeOf(u16), max_bytes);
}

fn textFromUnits(allocator: std.mem.Allocator, units: [*]const u16, capacity: usize, max_bytes: usize) ![]u8 {
    const scan_limit = @min(capacity, max_bytes +| 1);
    var length: usize = 0;
    while (length < scan_limit and units[length] != 0) : (length += 1) {}
    if (length > max_bytes) return error.ClipboardTextTooLarge;
    if (length == capacity) return error.UnterminatedClipboardText;
    if (try utf8Length(units[0..length]) > max_bytes) return error.ClipboardTextTooLarge;
    return decodeUtf16(allocator, units[0..length]);
}

/// The UTF-8 length of UTF-16 text, without converting it.
fn utf8Length(units: []const u16) !usize {
    var total: usize = 0;
    var index: usize = 0;
    while (index < units.len) : (index += 1) {
        const unit = units[index];
        if (unit < 0x80) {
            total += 1;
        } else if (unit < 0x800) {
            total += 2;
        } else if (unit >= 0xD800 and unit <= 0xDBFF) {
            if (index + 1 >= units.len or units[index + 1] < 0xDC00 or units[index + 1] > 0xDFFF) return error.InvalidClipboardText;
            total += 4;
            index += 1;
        } else if (unit >= 0xDC00 and unit <= 0xDFFF) {
            return error.InvalidClipboardText;
        } else {
            total += 3;
        }
    }
    return total;
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
    var unreadable = false;
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
        unreadable = false;
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

    fn snapshot(allocator: std.mem.Allocator) Snapshot {
        if (unreadable) return .unreadable;
        const value = held orelse return .none;
        return snapshotUnits(allocator, value.ptr, value.len);
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

test "the paste limit counts UTF-8 bytes, so wide characters are refused before conversion" {
    const allocator = std.testing.allocator;
    // Euro sign: one UTF-16 unit, three UTF-8 bytes. Emoji: a surrogate pair, four bytes.
    const euro = FakeClipboard.units("\u{20ac}\u{20ac}");
    try std.testing.expectError(error.ClipboardTextTooLarge, textFromUnits(allocator, euro.ptr, euro.len, 5));
    const six = try textFromUnits(allocator, euro.ptr, euro.len, 6);
    defer allocator.free(six);
    try std.testing.expectEqualStrings("\u{20ac}\u{20ac}", six);

    const emoji = FakeClipboard.units("\u{1f600}");
    try std.testing.expectError(error.ClipboardTextTooLarge, textFromUnits(allocator, emoji.ptr, emoji.len, 3));
    const four = try textFromUnits(allocator, emoji.ptr, emoji.len, 4);
    defer allocator.free(four);
    try std.testing.expectEqualStrings("\u{1f600}", four);
    // Refused by size, nothing was allocated: a failing allocator still reports the size error.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.ClipboardTextTooLarge, textFromUnits(failing.allocator(), euro.ptr, euro.len, 5));
}

test "a snapshot copies text through its terminator and refuses an unterminated block" {
    const allocator = std.testing.allocator;
    var block = [_]u16{ 'h', 'i', 0, 'x', 'y' };
    const kept = snapshotUnits(allocator, &block, block.len);
    defer allocator.free(kept.units);
    try std.testing.expectEqualSlices(u16, &[_]u16{ 'h', 'i', 0 }, kept.units);
    const bare = [_]u16{ 'a', 'b', 'c' };
    try std.testing.expect(snapshotUnits(allocator, &bare, bare.len) == .unreadable);
}

test "unreadable or unterminated existing text stops a copy before the clipboard is emptied" {
    // Unicode text is there but cannot be copied: the write is refused and nothing changes.
    FakeClipboard.reset(FakeClipboard.units("old"));
    FakeClipboard.unreadable = true;
    try std.testing.expectError(
        error.ClipboardPreviousTextUnreadable,
        writeTextWith(FakeClipboard, fake_owner, std.testing.allocator, "new"),
    );
    try FakeClipboard.expectHeld(FakeClipboard.units("old"));
    try std.testing.expectEqual(@as(usize, 0), FakeClipboard.sets);
    try std.testing.expectEqual(@as(usize, 1), FakeClipboard.closes);

    // An existing block with no terminator must not be republished by a restore: the copy is
    // stopped before the clipboard is emptied, so a refused write has nothing to restore.
    FakeClipboard.reset(&[_]u16{ 'a', 'b', 'c' });
    FakeClipboard.refused_sets = 1;
    try std.testing.expectError(
        error.ClipboardPreviousTextUnreadable,
        writeTextWith(FakeClipboard, fake_owner, std.testing.allocator, "new"),
    );
    try FakeClipboard.expectHeld(&[_]u16{ 'a', 'b', 'c' });
    try std.testing.expectEqual(@as(usize, 0), FakeClipboard.sets);
}

test "a restore republishes only the text through its terminator" {
    FakeClipboard.reset(&[_]u16{ 'o', 'l', 'd', 0, 'j', 'u', 'n', 'k' });
    FakeClipboard.refused_sets = 1;
    try std.testing.expectError(
        error.ClipboardWriteFailedKeptPreviousText,
        writeTextWith(FakeClipboard, fake_owner, std.testing.allocator, "new"),
    );
    try FakeClipboard.expectHeld(FakeClipboard.units("old"));
}
