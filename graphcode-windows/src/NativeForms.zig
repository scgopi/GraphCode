const std = @import("std");
const Forms = @import("Forms.zig");
const c = @import("Win32.zig").c;

const DialogState = struct {
    allocator: std.mem.Allocator,
    kind: Kind,
    parent: c.HWND,
    result: bool = false,
    closed: bool = false,
    edits: [3]c.HWND = .{ null, null, null },
    values: [3][]u8 = .{ &.{}, &.{}, &.{} },
};

const Kind = enum { node, edge, settings };
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeNativeForm");
const ok_id = 9001;
const cancel_id = 9002;
var active_state: bool = false;
var active_state_storage: DialogState = undefined;

pub fn node(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    initial: Forms.NodeDraft,
) !?Forms.NodeDraft {
    const state = try allocator.create(DialogState);
    state.* = .{ .allocator = allocator, .kind = .node, .parent = parent };
    defer {
        freeValues(state);
        allocator.destroy(state);
    }
    state.values[0] = try allocator.dupe(u8, initial.title);
    state.values[1] = try allocator.dupe(u8, initial.loop_type);
    if (!(try show(state, "Create or edit node", &.{ "Title", "Loop type" }))) return null;
    return .{
        .title = try allocator.dupe(u8, state.values[0]),
        .loop_type = try allocator.dupe(u8, state.values[1]),
    };
}

pub fn edge(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    initial: Forms.EdgeDraft,
) !?Forms.EdgeDraft {
    const state = try allocator.create(DialogState);
    state.* = .{ .allocator = allocator, .kind = .edge, .parent = parent };
    defer {
        freeValues(state);
        allocator.destroy(state);
    }
    state.values[0] = try allocator.dupe(u8, initial.from);
    state.values[1] = try allocator.dupe(u8, initial.to);
    state.values[2] = try allocator.dupe(u8, initial.kind);
    if (!(try show(state, "Create or edit edge", &.{ "From node ID", "To node ID", "Edge kind" }))) return null;
    return .{
        .from = try allocator.dupe(u8, state.values[0]),
        .to = try allocator.dupe(u8, state.values[1]),
        .kind = try allocator.dupe(u8, state.values[2]),
    };
}

pub fn settings(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    initial: Forms.Settings,
) !?Forms.Settings {
    const state = try allocator.create(DialogState);
    state.* = .{ .allocator = allocator, .kind = .settings, .parent = parent };
    defer {
        freeValues(state);
        allocator.destroy(state);
    }
    state.values[0] = try allocator.dupe(u8, initial.daemon_pipe);
    state.values[1] = try allocator.dupe(u8, initial.support_directory);
    if (!(try show(state, "GraphCode settings", &.{ "Daemon pipe override", "Support directory" }))) return null;
    return .{
        .daemon_pipe = try allocator.dupe(u8, state.values[0]),
        .support_directory = try allocator.dupe(u8, state.values[1]),
        .reconnect_automatically = initial.reconnect_automatically,
    };
}

fn show(state: *DialogState, title: []const u8, labels: []const []const u8) !bool {
    registerClass() catch return error.FormClassRegistrationFailed;
    const wide_title = try std.unicode.utf8ToUtf16LeAlloc(state.allocator, title);
    defer state.allocator.free(wide_title);
    active_state_storage = state.*;
    active_state = true;
    const hwnd = c.CreateWindowExW(
        c.WS_EX_DLGMODALFRAME,
        class_name.ptr,
        wide_title.ptr,
        c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        470,
        @intCast(150 + labels.len * 48),
        state.parent,
        null,
        c.GetModuleHandleW(null),
        @ptrCast(state),
    ) orelse {
        active_state = false;
        return error.FormCreationFailed;
    };
    _ = c.EnableWindow(state.parent, 0);
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.SetForegroundWindow(hwnd);
    var message: c.MSG = undefined;
    while (!state.closed) {
        const code = c.GetMessageW(&message, null, 0, 0);
        if (code <= 0) break;
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }
    _ = c.EnableWindow(state.parent, 1);
    _ = c.SetActiveWindow(state.parent);
    state.* = active_state_storage;
    active_state = false;
    return state.result;
}

fn registerClass() !void {
    var window_class: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    window_class.lpfnWndProc = @ptrCast(&windowProc);
    window_class.hInstance = c.GetModuleHandleW(null);
    window_class.lpszClassName = class_name.ptr;
    window_class.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
    if (c.RegisterClassW(&window_class) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.ClassRegistrationFailed;
}

fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (!active_state) return c.DefWindowProcW(hwnd, message, wparam, lparam);
    const value = &active_state_storage;
    switch (message) {
        c.WM_CREATE => {
            var labels: [3][]const u8 = .{ "", "", "" };
            var label_count: usize = 0;
            switch (value.kind) {
                .node => {
                    labels = .{ "Title", "Loop type", "" };
                    label_count = 2;
                },
                .edge => {
                    labels = .{ "From node ID", "To node ID", "Edge kind" };
                    label_count = 3;
                },
                .settings => {
                    labels = .{ "Daemon pipe override", "Support directory", "" };
                    label_count = 2;
                },
            }
            for (labels[0..label_count], 0..) |label, index| {
                createText(hwnd, value, label, index);
            }
            createButton(hwnd, "OK", ok_id, 350, @intCast(35 + label_count * 48));
            createButton(hwnd, "Cancel", cancel_id, 265, @intCast(35 + label_count * 48));
            return 0;
        },
        c.WM_COMMAND => {
            const command = @as(u16, @truncate(wparam));
            if (command == ok_id) {
                readValues(value);
                value.result = true;
                value.closed = true;
                _ = c.DestroyWindow(hwnd);
                return 0;
            }
            if (command == cancel_id) {
                value.closed = true;
                _ = c.DestroyWindow(hwnd);
                return 0;
            }
        },
        c.WM_CLOSE => {
            value.closed = true;
            _ = c.DestroyWindow(hwnd);
            return 0;
        },
        c.WM_DESTROY => return 0,
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn createText(hwnd: c.HWND, state: *DialogState, label: []const u8, index: usize) void {
    const y: i32 = @intCast(15 + index * 48);
    const wide_label = std.unicode.utf8ToUtf16LeAlloc(state.allocator, label) catch return;
    defer state.allocator.free(wide_label);
    _ = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr, wide_label.ptr, c.WS_CHILD | c.WS_VISIBLE, 18, y, 420, 18, hwnd, null, c.GetModuleHandleW(null), null);
    const edit = c.CreateWindowExW(c.WS_EX_CLIENTEDGE, std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr, null, c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_AUTOHSCROLL, 18, y + 18, 420, 24, hwnd, @ptrFromInt(9100 + index), c.GetModuleHandleW(null), null) orelse return;
    state.edits[index] = edit;
    const wide_value = std.unicode.utf8ToUtf16LeAlloc(state.allocator, state.values[index]) catch return;
    defer state.allocator.free(wide_value);
    _ = c.SetWindowTextW(edit, wide_value.ptr);
}

fn createButton(hwnd: c.HWND, text: []const u8, id: usize, x: i32, y: i32) void {
    const wide = std.unicode.utf8ToUtf16LeAlloc(std.heap.c_allocator, text) catch return;
    defer std.heap.c_allocator.free(wide);
    _ = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON").ptr, wide.ptr, c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_DEFPUSHBUTTON, x, y, 70, 26, hwnd, @ptrFromInt(id), c.GetModuleHandleW(null), null);
}

fn readValues(state: *DialogState) void {
    var buffer: [1024]u16 = undefined;
    const count: usize = switch (state.kind) {
        .node => 2,
        .edge => 3,
        .settings => 2,
    };
    for (0..count) |index| {
        const length = c.GetWindowTextW(state.edits[index], &buffer, @intCast(buffer.len));
        const value = std.unicode.utf16LeToUtf8Alloc(state.allocator, buffer[0..@intCast(length)]) catch continue;
        state.allocator.free(state.values[index]);
        state.values[index] = value;
    }
}

fn freeValues(state: *DialogState) void {
    for (&state.values) |value| if (value.len != 0) state.allocator.free(value);
}
