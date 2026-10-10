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

    /// Copies `units` (terminator included) into a new movable block. Until `publish` succeeds
    /// the caller owns the block and must `free` it exactly once.
    fn stage(units: []const u16) ?*anyopaque {
        const memory = c.GlobalAlloc(c.GMEM_MOVEABLE, units.len * @sizeOf(u16)) orelse return null;
        const locked = c.GlobalLock(memory) orelse {
            _ = c.GlobalFree(memory);
            return null;
        };
        const destination: [*]u16 = @ptrCast(@alignCast(locked));
        @memcpy(destination[0..units.len], units);
        _ = c.GlobalUnlock(memory);
        return memory;
    }

    fn free(memory: *anyopaque) void {
        _ = c.GlobalFree(memory);
    }

    /// Windows owns the block only when this succeeds; after a failure the caller still owns it.
    fn publish(memory: *anyopaque) bool {
        return c.SetClipboardData(c.CF_UNICODETEXT, memory) != null;
    }
};

pub fn writeText(owner: c.HWND, allocator: std.mem.Allocator, text: []const u8) !void {
    return writeTextWith(NativeApi, owner, allocator, text);
}

/// Replaces the whole clipboard with `text`, as Unicode text only. Windows only lets a program
/// set the clipboard after emptying it, and emptying removes every other format (images, HTML,
/// RTF, files, and the history and cloud opt-out formats), so a successful copy replaces all
/// of them, as macOS does with `clearContents` then `setString`. Nothing earlier is read or
/// restored: reading it could block on another program that renders it on demand, and putting
/// back only its text would drop an opt-out marker and could republish text that was excluded
/// from history and sync. The text is copied into a clipboard block before the clipboard is
/// opened, so running out of memory cannot happen once it has been emptied. If the clipboard
/// then refuses the block, the copy fails and the clipboard may be left empty. The block belongs
/// to this function until the clipboard accepts it, and is freed exactly once on every
/// failure; after success Windows owns it.
fn writeTextWith(comptime Api: type, owner: c.HWND, allocator: std.mem.Allocator, text: []const u8) !void {
    if (owner == null) return error.ClipboardOwnerUnavailable;
    const encoded = try encodeUtf16(allocator, text);
    defer allocator.free(encoded);

    const staged = Api.stage(encoded.ptr[0 .. encoded.len + 1]) orelse return error.OutOfMemory;
    var owned = true;
    defer if (owned) Api.free(staged);

    if (!Api.open(owner)) return error.ClipboardOpenFailed;
    defer Api.close();
    if (!Api.empty()) return error.ClipboardClearFailed;
    if (!Api.publish(staged)) return error.ClipboardWriteFailed;
    owned = false;
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
/// clipboard emptied first, and the stand-in can refuse to allocate, open, empty or accept a
/// block. It counts opens, empties, publishes, closes and frees, and tracks which staged blocks
/// the caller still owns, so a leaked or doubly freed block fails a test. It never touches the
/// real clipboard.
const FakeClipboard = struct {
    var storage: [64]u16 = undefined;
    var held: ?[]const u16 = null;
    var open_ok = true;
    var empty_ok = true;
    var sets: usize = 0;
    var closes: usize = 0;
    var opens: usize = 0;
    var empties: usize = 0;
    var stages: usize = 0;
    var frees: usize = 0;
    /// Staged blocks the caller still owns: staged, not yet freed and not yet handed to the clipboard.
    var live: isize = 0;
    var alloc_ok = true;
    var publish_ok = true;
    var is_open = false;
    var staged_while_open = false;
    var staged_storage: [64]u16 = undefined;
    var staged_len: usize = 0;

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
        sets = 0;
        closes = 0;
        opens = 0;
        empties = 0;
        stages = 0;
        frees = 0;
        live = 0;
        alloc_ok = true;
        publish_ok = true;
        is_open = false;
        staged_while_open = false;
        staged_len = 0;
    }

    fn open(_: c.HWND) bool {
        opens += 1;
        is_open = open_ok;
        return open_ok;
    }

    fn close() void {
        closes += 1;
        is_open = false;
    }

    fn empty() bool {
        empties += 1;
        if (!empty_ok) return false;
        held = null;
        return true;
    }

    fn stage(value: []const u16) ?usize {
        stages += 1;
        if (is_open) staged_while_open = true;
        if (!alloc_ok) return null;
        @memcpy(staged_storage[0..value.len], value);
        staged_len = value.len;
        live += 1;
        return 1;
    }

    fn free(_: usize) void {
        frees += 1;
        live -= 1;
    }

    /// Windows takes ownership of the block only when this succeeds.
    fn publish(_: usize) bool {
        sets += 1;
        if (!publish_ok) return false;
        @memcpy(storage[0..staged_len], staged_storage[0..staged_len]);
        held = storage[0..staged_len];
        live -= 1;
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

test "a copy that cannot stage its text touches nothing" {
    FakeClipboard.reset(FakeClipboard.units("old"));
    FakeClipboard.alloc_ok = false;
    try std.testing.expectError(
        error.OutOfMemory,
        writeTextWith(FakeClipboard, fake_owner, std.testing.allocator, "new"),
    );
    try std.testing.expectEqual(@as(usize, 1), FakeClipboard.stages);
    try std.testing.expectEqual(@as(usize, 0), FakeClipboard.opens);
    try std.testing.expectEqual(@as(usize, 0), FakeClipboard.empties);
    try std.testing.expectEqual(@as(usize, 0), FakeClipboard.sets);
    try std.testing.expectEqual(@as(usize, 0), FakeClipboard.frees);
    try FakeClipboard.expectHeld(FakeClipboard.units("old"));
}

test "the new text is staged before the clipboard is opened" {
    FakeClipboard.reset(FakeClipboard.units("old"));
    try writeTextWith(FakeClipboard, fake_owner, std.testing.allocator, "new");
    try std.testing.expectEqual(@as(usize, 1), FakeClipboard.stages);
    try std.testing.expect(!FakeClipboard.staged_while_open);
}

test "a copy that cannot open the clipboard frees its staged text exactly once" {
    FakeClipboard.reset(FakeClipboard.units("old"));
    FakeClipboard.open_ok = false;
    try std.testing.expectError(
        error.ClipboardOpenFailed,
        writeTextWith(FakeClipboard, fake_owner, std.testing.allocator, "new"),
    );
    try std.testing.expectEqual(@as(usize, 1), FakeClipboard.stages);
    try std.testing.expectEqual(@as(usize, 1), FakeClipboard.frees);
    try std.testing.expectEqual(@as(isize, 0), FakeClipboard.live);
    try std.testing.expectEqual(@as(usize, 0), FakeClipboard.empties);
    try std.testing.expectEqual(@as(usize, 0), FakeClipboard.closes);
    try FakeClipboard.expectHeld(FakeClipboard.units("old"));
}

test "a copy that cannot empty the clipboard frees its staged text exactly once" {
    FakeClipboard.reset(FakeClipboard.units("old"));
    FakeClipboard.empty_ok = false;
    try std.testing.expectError(
        error.ClipboardClearFailed,
        writeTextWith(FakeClipboard, fake_owner, std.testing.allocator, "new"),
    );
    try std.testing.expectEqual(@as(usize, 1), FakeClipboard.frees);
    try std.testing.expectEqual(@as(isize, 0), FakeClipboard.live);
    try std.testing.expectEqual(@as(usize, 0), FakeClipboard.sets);
    try std.testing.expectEqual(@as(usize, 1), FakeClipboard.closes);
    try FakeClipboard.expectHeld(FakeClipboard.units("old"));
}

test "a refused publish frees its staged text exactly once, is an ordinary write failure, and restores nothing" {
    FakeClipboard.reset(FakeClipboard.units("old"));
    FakeClipboard.publish_ok = false;
    try std.testing.expectError(
        error.ClipboardWriteFailed,
        writeTextWith(FakeClipboard, fake_owner, std.testing.allocator, "new"),
    );
    try std.testing.expectEqual(@as(usize, 1), FakeClipboard.empties);
    try std.testing.expectEqual(@as(usize, 1), FakeClipboard.sets);
    try std.testing.expectEqual(@as(usize, 1), FakeClipboard.frees);
    try std.testing.expectEqual(@as(isize, 0), FakeClipboard.live);
    try std.testing.expectEqual(@as(usize, 1), FakeClipboard.closes);
    // The clipboard was emptied and stays empty: no earlier text is put back.
    try FakeClipboard.expectHeld(null);
}

test "a successful publish hands the block to Windows and the caller never frees it" {
    FakeClipboard.reset(FakeClipboard.units("old"));
    try writeTextWith(FakeClipboard, fake_owner, std.testing.allocator, "new");
    try FakeClipboard.expectHeld(FakeClipboard.units("new"));
    try std.testing.expectEqual(@as(usize, 1), FakeClipboard.opens);
    try std.testing.expectEqual(@as(usize, 1), FakeClipboard.empties);
    try std.testing.expectEqual(@as(usize, 1), FakeClipboard.sets);
    try std.testing.expectEqual(@as(usize, 1), FakeClipboard.closes);
    try std.testing.expectEqual(@as(usize, 0), FakeClipboard.frees);
    try std.testing.expectEqual(@as(isize, 0), FakeClipboard.live);
}
