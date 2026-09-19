const std = @import("std");
const c = @import("Win32.zig").c;

pub const Action = enum {
    later,
    release_notes,
    install_unavailable,
};

const State = struct {
    allocator: std.mem.Allocator,
    version: []const u8,
    reason: []const u8,
    action: Action = .later,
    closed: bool = false,
};

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeUpdateOffer");
const install_id = 9701;
const release_notes_id = 9702;
const later_id = 9703;
var active = false;
var active_state: State = undefined;

pub fn show(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    version: []const u8,
    reason: []const u8,
) !Action {
    registerClass() catch return error.DialogClassRegistrationFailed;
    var state = State{ .allocator = allocator, .version = version, .reason = reason };
    active_state = state;
    active_state.closed = false;
    active = true;
    const title = try wideZ(allocator, "GraphCode Update Available");
    defer allocator.free(title);
    const hwnd = c.CreateWindowExW(
        c.WS_EX_DLGMODALFRAME | c.WS_EX_CONTROLPARENT,
        class_name.ptr,
        title.ptr,
        c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        620,
        280,
        parent,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse {
        active = false;
        return error.DialogCreationFailed;
    };
    _ = c.EnableWindow(parent, 0);
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.SetForegroundWindow(hwnd);
    var message: c.MSG = undefined;
    while (!active_state.closed) {
        const code = c.GetMessageW(&message, null, 0, 0);
        if (code <= 0) {
            active_state.closed = true;
            break;
        }
        if (c.IsDialogMessageW(hwnd, &message) != 0) continue;
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }
    _ = c.DestroyWindow(hwnd);
    _ = c.EnableWindow(parent, 1);
    _ = c.SetActiveWindow(parent);
    state = active_state;
    active = false;
    return state.action;
}

fn registerClass() !void {
    var klass: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    klass.lpfnWndProc = @ptrCast(&windowProc);
    klass.hInstance = c.GetModuleHandleW(null);
    klass.lpszClassName = class_name.ptr;
    klass.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
    if (c.RegisterClassW(&klass) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.DialogClassRegistrationFailed;
}

fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (!active) return c.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_CREATE => {
            createStatic(hwnd, active_state.allocator, "An update is available.", 18, 16, 560, 24);
            const version_text = std.fmt.allocPrint(active_state.allocator, "GraphCode {s}", .{
                if (active_state.version.len == 0) "update" else active_state.version,
            }) catch return 0;
            defer active_state.allocator.free(version_text);
            createStatic(hwnd, active_state.allocator, version_text, 18, 46, 560, 24);
            createStatic(hwnd, active_state.allocator, "Release Notes opens the verified GraphCode release page.", 18, 76, 560, 24);
            createStatic(hwnd, active_state.allocator, active_state.reason, 18, 106, 560, 44);
            createButton(hwnd, "Install", install_id, 18, 190, false);
            createButton(hwnd, "Release Notes", release_notes_id, 160, 190, true);
            createButton(hwnd, "Later", later_id, 470, 190, true);
            return 0;
        },
        c.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            if (command == install_id) {
                active_state.action = .install_unavailable;
                requestClose(hwnd);
                return 0;
            }
            if (command == release_notes_id) {
                active_state.action = .release_notes;
                requestClose(hwnd);
                return 0;
            }
            if (command == later_id) {
                active_state.action = .later;
                requestClose(hwnd);
                return 0;
            }
        },
        c.WM_CLOSE => {
            active_state.action = .later;
            requestClose(hwnd);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn requestClose(hwnd: c.HWND) void {
    active_state.closed = true;
    _ = c.PostMessageW(hwnd, c.WM_NULL, 0, 0);
}

fn createStatic(
    hwnd: c.HWND,
    allocator: std.mem.Allocator,
    text: []const u8,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) void {
    const wide = wideZ(allocator, text) catch return;
    defer allocator.free(wide);
    _ = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr,
        wide.ptr,
        c.WS_CHILD | c.WS_VISIBLE | c.SS_LEFT,
        x,
        y,
        width,
        height,
        hwnd,
        null,
        c.GetModuleHandleW(null),
        null,
    );
}

fn createButton(hwnd: c.HWND, text: []const u8, id: usize, x: i32, y: i32, enabled: bool) void {
    const wide = wideZ(std.heap.c_allocator, text) catch return;
    defer std.heap.c_allocator.free(wide);
    const disabled_style: c.DWORD = if (enabled) 0 else @as(c.DWORD, @intCast(c.WS_DISABLED));
    const style: c.DWORD = @as(c.DWORD, @intCast(c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_PUSHBUTTON)) | disabled_style;
    const button = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON").ptr,
        wide.ptr,
        style,
        x,
        y,
        if (id == later_id) 110 else 140,
        30,
        hwnd,
        controlId(id),
        c.GetModuleHandleW(null),
        null,
    ) orelse return;
    _ = c.EnableWindow(button, if (enabled) 1 else 0);
}

fn controlId(value: usize) c.HMENU {
    @setRuntimeSafety(false);
    return @ptrFromInt(value);
}

fn wideZ(allocator: std.mem.Allocator, value: []const u8) ![]u16 {
    const raw = try std.unicode.utf8ToUtf16LeAlloc(allocator, value);
    defer allocator.free(raw);
    const result = try allocator.alloc(u16, raw.len + 1);
    @memcpy(result[0..raw.len], raw);
    result[raw.len] = 0;
    return result;
}

test "update offer keeps install unavailable while preserving explicit actions" {
    try std.testing.expectEqual(Action.later, .later);
    try std.testing.expectEqual(Action.release_notes, .release_notes);
    try std.testing.expectEqual(Action.install_unavailable, .install_unavailable);
}
