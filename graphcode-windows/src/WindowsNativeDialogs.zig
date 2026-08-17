const std = @import("std");
const c = @import("Win32.zig").c;

pub const Result = struct {
    values: [16][]u8,
    count: usize,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.values[0..self.count]) |value| allocator.free(value);
        self.* = undefined;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    parent: c.HWND,
    labels: [16][]const u8 = [_][]const u8{""} ** 16,
    values: [16][]u8 = [_][]u8{&.{}} ** 16,
    label_windows: [16]c.HWND = [_]c.HWND{null} ** 16,
    edits: [16]c.HWND = [_]c.HWND{null} ** 16,
    count: usize = 0,
    scroll_offset: i32 = 0,
    accepted: bool = false,
    closed: bool = false,
};

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeWindowsDialog");
const ok_id = 9800;
const cancel_id = 9808;
var active = false;
var active_state: State = undefined;

pub fn text(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    title: []const u8,
    labels: []const []const u8,
    initial: []const []const u8,
) !?Result {
    if (labels.len == 0 or labels.len > 16 or labels.len != initial.len) return error.InvalidDialogFields;
    var state = State{ .allocator = allocator, .parent = parent, .count = labels.len };
    for (labels, 0..) |label, index| {
        state.labels[index] = label;
        state.values[index] = allocator.dupe(u8, initial[index]) catch |err| {
            freeStateValues(&state);
            return err;
        };
    }

    registerClass() catch {
        freeStateValues(&state);
        return error.DialogClassRegistrationFailed;
    };
    const wide_title = wideZ(allocator, title) catch |err| {
        freeStateValues(&state);
        return err;
    };
    defer allocator.free(wide_title);
    active_state = state;
    active_state.closed = false;
    active_state.accepted = false;
    active = true;
    const hwnd = c.CreateWindowExW(
        c.WS_EX_DLGMODALFRAME | c.WS_EX_CONTROLPARENT,
        class_name.ptr,
        wide_title.ptr,
        c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU | c.WS_VSCROLL,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        600,
        620,
        parent,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse {
        freeStateValues(&active_state);
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
    active = false;
    if (!active_state.accepted) {
        freeStateValues(&active_state);
        return null;
    }
    var result = Result{ .values = [_][]u8{&.{}} ** 16, .count = state.count };
    readValues(&active_state);
    for (active_state.values[0..state.count], 0..) |value, index| {
        result.values[index] = allocator.dupe(u8, value) catch |err| {
            result.deinit(allocator);
            freeStateValues(&active_state);
            return err;
        };
    }
    freeStateValues(&active_state);
    return result;
}

fn freeStateValues(state: *State) void {
    for (state.values[0..state.count]) |value| state.allocator.free(value);
    state.values = [_][]u8{&.{}} ** 16;
    state.count = 0;
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
            for (active_state.labels[0..active_state.count], 0..) |label, index| {
                createField(hwnd, &active_state, label, index);
            }
            createButton(hwnd, "OK", ok_id, 490, 565);
            createButton(hwnd, "Cancel", cancel_id, 400, 565);
            return 0;
        },
        c.WM_VSCROLL => {
            const action: u16 = @truncate(wparam);
            const max_offset: i32 = @max(0, @as(i32, @intCast(active_state.count * 52)) - 510);
            switch (action) {
                c.SB_LINEUP => active_state.scroll_offset = @max(0, active_state.scroll_offset - 52),
                c.SB_LINEDOWN => active_state.scroll_offset = @min(max_offset, active_state.scroll_offset + 52),
                c.SB_PAGEUP => active_state.scroll_offset = @max(0, active_state.scroll_offset - 510),
                c.SB_PAGEDOWN => active_state.scroll_offset = @min(max_offset, active_state.scroll_offset + 510),
                else => {},
            }
            repositionFields();
            return 0;
        },
        c.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            if (command == ok_id) {
                readValues(&active_state);
                active_state.accepted = true;
                active_state.closed = true;
                return 0;
            }
            if (command == cancel_id) {
                active_state.accepted = false;
                active_state.closed = true;
                return 0;
            }
        },
        c.WM_CLOSE => {
            active_state.accepted = false;
            active_state.closed = true;
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn createField(hwnd: c.HWND, state: *State, label: []const u8, index: usize) void {
    const y: i32 = @intCast(12 + index * 52);
    const wide_label = wideZ(state.allocator, label) catch return;
    defer state.allocator.free(wide_label);
    state.label_windows[index] = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr, wide_label.ptr, c.WS_CHILD | c.WS_VISIBLE, 18, y, 500, 18, hwnd, null, c.GetModuleHandleW(null), null);
    const edit_id: c.HMENU = @ptrFromInt(9904 + index * 8);
    const edit = c.CreateWindowExW(c.WS_EX_CLIENTEDGE, std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr, null, c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_AUTOHSCROLL, 18, y + 18, 500, 24, hwnd, edit_id, c.GetModuleHandleW(null), null) orelse return;
    state.edits[index] = edit;
    const wide_value = wideZ(state.allocator, state.values[index]) catch return;
    defer state.allocator.free(wide_value);
    _ = c.SetWindowTextW(edit, wide_value.ptr);
}

fn repositionFields() void {
    for (0..active_state.count) |index| {
        const y: i32 = @as(i32, @intCast(12 + index * 52)) - active_state.scroll_offset;
        const visible = y >= 0 and y < 535;
        _ = c.ShowWindow(active_state.label_windows[index], if (visible) c.SW_SHOW else c.SW_HIDE);
        _ = c.ShowWindow(active_state.edits[index], if (visible) c.SW_SHOW else c.SW_HIDE);
        if (visible) {
            _ = c.SetWindowPos(active_state.label_windows[index], null, 18, y, 500, 18, c.SWP_NOZORDER);
            _ = c.SetWindowPos(active_state.edits[index], null, 18, y + 18, 500, 24, c.SWP_NOZORDER);
        }
    }
}

fn createButton(hwnd: c.HWND, label: []const u8, id: usize, x: i32, y: i32) void {
    const wide = wideZ(std.heap.c_allocator, label) catch return;
    defer std.heap.c_allocator.free(wide);
    const button_id: c.HMENU = @ptrFromInt(id);
    _ = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON").ptr, wide.ptr, c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_DEFPUSHBUTTON, x, y, 80, 28, hwnd, button_id, c.GetModuleHandleW(null), null);
}

fn readValues(state: *State) void {
    var buffer: [4096]u16 = undefined;
    for (0..state.count) |index| {
        const length = c.GetWindowTextW(state.edits[index], &buffer, @intCast(buffer.len));
        const value = std.unicode.utf16LeToUtf8Alloc(state.allocator, buffer[0..@intCast(length)]) catch continue;
        state.allocator.free(state.values[index]);
        state.values[index] = value;
    }
}

fn wideZ(allocator: std.mem.Allocator, value: []const u8) ![]u16 {
    const raw = try std.unicode.utf8ToUtf16LeAlloc(allocator, value);
    defer allocator.free(raw);
    const result = try allocator.alloc(u16, raw.len + 1);
    @memcpy(result[0..raw.len], raw);
    result[raw.len] = 0;
    return result;
}

test "native dialog field contract preserves Unicode and field count" {
    const labels = [_][]const u8{ "URL", "Destination" };
    try std.testing.expectEqual(labels.len, 2);
    try std.testing.expect(std.unicode.utf8ValidateSlice("Проекты\\über"));
}
