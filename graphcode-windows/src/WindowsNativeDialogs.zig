const std = @import("std");
const Win32 = @import("Win32.zig");
const c = Win32.c;
const ModalTeardown = @import("ModalTeardown.zig");
const AppFont = @import("AppFont.zig");

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
    description: []const u8 = "",
    description_window: c.HWND = null,
    count: usize = 0,
    scroll_offset: i32 = 0,
    accepted: bool = false,
    closed: bool = false,
    failure: ?anyerror = null,
    button_y: i32 = 565,
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
    return textWithDescription(parent, allocator, title, "", labels, initial);
}

pub fn textWithDescription(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    title: []const u8,
    description: []const u8,
    labels: []const []const u8,
    initial: []const []const u8,
) !?Result {
    if (active) return error.DialogAlreadyOpen;
    if (labels.len == 0 or labels.len > 16 or labels.len != initial.len) return error.InvalidDialogFields;
    var state = State{
        .allocator = allocator,
        .parent = parent,
        .count = labels.len,
        .description = description,
    };
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
    const window_height: i32 = if (labels.len <= 4)
        @as(i32, @intCast(150 + labels.len * 52))
    else
        620;
    state.button_y = window_height - 55;
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
        window_height,
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
    ModalTeardown.dismiss(hwnd, parent);
    active = false;
    return finishText(&active_state);
}

fn finishText(state: *State) !?Result {
    if (state.failure) |err| {
        freeStateValues(state);
        return err;
    }
    if (!state.accepted) {
        freeStateValues(state);
        return null;
    }
    const result = Result{ .values = state.values, .count = state.count };
    state.values = [_][]u8{&.{}} ** 16;
    state.count = 0;
    return result;
}

const TextCommand = enum { submit, cancel, close };

fn applyTextCommand(state: *State, command: TextCommand) void {
    if (command == .submit) {
        readValues(state) catch |err| {
            state.failure = err;
            state.accepted = false;
            state.closed = true;
            return;
        };
        state.accepted = true;
    } else {
        state.accepted = false;
    }
    state.closed = true;
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
    klass.hCursor = c.LoadCursorW(null, Win32.resourceIdentifier(32512));
    if (c.RegisterClassW(&klass) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.DialogClassRegistrationFailed;
}

fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (!active) return c.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_CREATE => {
            if (active_state.description.len != 0) createDescription(hwnd, &active_state);
            for (active_state.labels[0..active_state.count], 0..) |label, index| {
                createField(hwnd, &active_state, label, index);
            }
            createButton(hwnd, "OK", ok_id, 490, active_state.button_y);
            createButton(hwnd, "Cancel", cancel_id, 400, active_state.button_y);
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
                applyTextCommand(&active_state, .submit);
                return 0;
            }
            if (command == cancel_id) {
                applyTextCommand(&active_state, .cancel);
                return 0;
            }
        },
        c.WM_KEYDOWN => {
            if (wparam == c.VK_RETURN) {
                applyTextCommand(&active_state, .submit);
                return 0;
            }
            if (wparam == c.VK_ESCAPE) {
                applyTextCommand(&active_state, .cancel);
                return 0;
            }
        },
        c.WM_CLOSE => {
            applyTextCommand(&active_state, .close);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn createDescription(hwnd: c.HWND, state: *State) void {
    const wide = wideZ(state.allocator, state.description) catch return;
    defer state.allocator.free(wide);
    state.description_window = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr,
        wide.ptr,
        c.WS_CHILD | c.WS_VISIBLE,
        18,
        12,
        540,
        36,
        hwnd,
        null,
        c.GetModuleHandleW(null),
        null,
    );
    AppFont.apply(state.description_window, AppFont.control_size, false);
}

fn fieldBaseY(state: *const State) usize {
    return if (state.description.len == 0) 12 else 56;
}

fn createField(hwnd: c.HWND, state: *State, label: []const u8, index: usize) void {
    const y: i32 = @intCast(fieldBaseY(state) + index * 52);
    const wide_label = wideZ(state.allocator, label) catch return;
    defer state.allocator.free(wide_label);
    state.label_windows[index] = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr, wide_label.ptr, c.WS_CHILD | c.WS_VISIBLE, 18, y, 500, 18, hwnd, null, c.GetModuleHandleW(null), null);
    AppFont.apply(state.label_windows[index], AppFont.control_size, false);
    const edit_id = Win32.opaquePointerFromInt(c.HMENU, 9904 + index * 8);
    const edit = c.CreateWindowExW(c.WS_EX_CLIENTEDGE, std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr, null, c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_AUTOHSCROLL, 18, y + 18, 500, 24, hwnd, edit_id, c.GetModuleHandleW(null), null) orelse return;
    AppFont.apply(edit, AppFont.control_size, false);
    state.edits[index] = edit;
    const wide_value = wideZ(state.allocator, state.values[index]) catch return;
    defer state.allocator.free(wide_value);
    _ = c.SetWindowTextW(edit, wide_value.ptr);
}

fn repositionFields() void {
    for (0..active_state.count) |index| {
        const y: i32 = @as(i32, @intCast(fieldBaseY(&active_state) + index * 52)) - active_state.scroll_offset;
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
    const button_id = Win32.opaquePointerFromInt(c.HMENU, id);
    const button = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON").ptr, wide.ptr, c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_DEFPUSHBUTTON, x, y, 80, 28, hwnd, button_id, c.GetModuleHandleW(null), null);
    AppFont.apply(button, AppFont.control_size, false);
}

fn readValues(state: *State) !void {
    var buffer: [4096]u16 = undefined;
    for (0..state.count) |index| {
        if (c.IsWindow(state.edits[index]) == 0) return error.DialogReadFailed;
        if (c.GetWindowTextLengthW(state.edits[index]) >= buffer.len) return error.DialogTextTooLong;
        c.SetLastError(0);
        const length = c.GetWindowTextW(state.edits[index], &buffer, @intCast(buffer.len));
        if (length == 0 and c.GetLastError() != 0) return error.DialogReadFailed;
        const value = try std.unicode.utf16LeToUtf8Alloc(state.allocator, buffer[0..@intCast(length)]);
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

test "accepted workspace text survives native edit teardown" {
    const allocator = std.testing.allocator;
    var state = State{ .allocator = allocator, .parent = null, .count = 2 };
    defer freeStateValues(&state);
    state.values[0] = try allocator.dupe(u8, "old workspace");
    state.values[1] = try allocator.dupe(u8, "old name");
    const first = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr,
        std.unicode.utf8ToUtf16LeStringLiteral("alpha").ptr,
        0,
        0,
        0,
        100,
        20,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.TestWindowCreationFailed;
    defer if (c.IsWindow(first) != 0) {
        _ = c.DestroyWindow(first);
    };
    const second = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr,
        std.unicode.utf8ToUtf16LeStringLiteral("Проекты über").ptr,
        0,
        0,
        0,
        100,
        20,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.TestWindowCreationFailed;
    defer if (c.IsWindow(second) != 0) {
        _ = c.DestroyWindow(second);
    };
    state.edits[0] = first;
    state.edits[1] = second;
    applyTextCommand(&state, .submit);
    try std.testing.expect(c.DestroyWindow(first) != 0);
    try std.testing.expect(c.DestroyWindow(second) != 0);
    var result = (try finishText(&state)) orelse return error.ExpectedAcceptedText;
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualStrings("alpha", result.values[0]);
    try std.testing.expectEqualStrings("Проекты über", result.values[1]);
    try std.testing.expectEqual(@as(usize, 0), state.count);
}

test "cancelled or closed workspace text has no accepted result" {
    for ([_]TextCommand{ .cancel, .close }) |command| {
        var state = State{
            .allocator = std.testing.allocator,
            .parent = null,
            .count = 1,
        };
        defer freeStateValues(&state);
        state.values[0] = try state.allocator.dupe(u8, "do-not-delete");
        applyTextCommand(&state, command);
        try std.testing.expect((try finishText(&state)) == null);
        try std.testing.expect(state.closed);
        try std.testing.expectEqual(@as(usize, 0), state.count);
    }
}

test "workspace text read failure never accepts stale values" {
    var state = State{
        .allocator = std.testing.allocator,
        .parent = null,
        .count = 1,
    };
    defer freeStateValues(&state);
    state.values[0] = try state.allocator.dupe(u8, "stale-name");
    applyTextCommand(&state, .submit);
    try std.testing.expect(!state.accepted);
    try std.testing.expect(state.closed);
    try std.testing.expectError(error.DialogReadFailed, finishText(&state));
    try std.testing.expectEqual(@as(usize, 0), state.count);
}

test "workspace text rejects reentrant presentation before creating any window" {
    const previous = active;
    active = true;
    defer active = previous;
    try std.testing.expectError(error.DialogAlreadyOpen, textWithDescription(
        null,
        std.testing.allocator,
        "New Workspace",
        "",
        &.{"Name"},
        &.{""},
    ));
}

test "workspace text capture and transfer release every partial allocation" {
    const edit = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr,
        std.unicode.utf8ToUtf16LeStringLiteral("new workspace").ptr,
        0,
        0,
        0,
        100,
        20,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.TestWindowCreationFailed;
    defer _ = c.DestroyWindow(edit);
    const Probe = struct {
        fn run(allocator: std.mem.Allocator, window: c.HWND) !void {
            var state = State{ .allocator = allocator, .parent = null, .count = 2 };
            defer freeStateValues(&state);
            state.values[0] = try allocator.dupe(u8, "old first");
            state.values[1] = try allocator.dupe(u8, "old second");
            state.edits[0] = window;
            state.edits[1] = window;
            applyTextCommand(&state, .submit);
            var result = (try finishText(&state)) orelse return error.ExpectedAcceptedText;
            defer result.deinit(allocator);
            try std.testing.expectEqualStrings("new workspace", result.values[0]);
            try std.testing.expectEqualStrings("new workspace", result.values[1]);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{edit});
}
