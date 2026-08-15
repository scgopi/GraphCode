const std = @import("std");
const c = @import("Win32.zig").c;

pub const WheelMessage = struct {
    point: c.POINT,
    delta: i16,
};

pub fn decodeWheelMessage(lparam: c.LPARAM, wparam: c.WPARAM) WheelMessage {
    return .{
        .point = .{
            .x = signedWord(@as(usize, @bitCast(lparam))),
            .y = signedWord(@as(usize, @bitCast(lparam)) >> 16),
        },
        .delta = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(wparam)) >> 16)))),
    };
}

pub fn screenToClient(hwnd: c.HWND, point: c.POINT) ?c.POINT {
    return screenToClientWith(hwnd, point, c.ScreenToClient);
}

fn screenToClientWith(hwnd: c.HWND, point: c.POINT, mapper: anytype) ?c.POINT {
    var mapped = point;
    if (mapper(hwnd, &mapped) == 0) return null;
    return mapped;
}

fn signedWord(value: usize) i32 {
    return @as(i32, @as(i16, @bitCast(@as(u16, @truncate(value)))));
}

test "wheel message decodes negative and positive signed deltas" {
    try std.testing.expectEqual(@as(i16, -120), decodeWheelMessage(0, @as(c.WPARAM, 0xFF880000)).delta);
    try std.testing.expectEqual(@as(i16, 120), decodeWheelMessage(0, @as(c.WPARAM, 0x00780000)).delta);
}

test "screen wheel point preserves non-origin client mapping contract" {
    const screen = c.POINT{ .x = 1320, .y = 760 };
    const mapped = screenToClientWith(null, screen, fakeScreenToClient);
    try std.testing.expect(mapped != null);
    try std.testing.expectEqual(@as(i32, 120), mapped.?.x);
    try std.testing.expectEqual(@as(i32, 120), mapped.?.y);
}

fn fakeScreenToClient(hwnd: c.HWND, point: *c.POINT) c.BOOL {
    _ = hwnd;
    point.x -= 1200;
    point.y -= 640;
    return 1;
}
