const std = @import("std");
const Forms = @import("Forms.zig");
const c = @import("Win32.zig").c;

const DialogState = struct {
    allocator: std.mem.Allocator,
    kind: Kind,
    parent: c.HWND,
    result: bool = false,
    closed: bool = false,
    edits: [17]c.HWND = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
    values: [17][]u8 = .{ &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{} },
};

const Kind = enum { node, edge, update, settings, jump };
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeNativeForm");
const ok_id = 9001;
const cancel_id = 9002;
var active_state: bool = false;
var active_state_storage: DialogState = undefined;

const ModalCommand = enum { submit, cancel, close, destroy };

fn applyModalCommand(state: *DialogState, command: ModalCommand) void {
    switch (command) {
        .submit => state.result = true,
        .cancel, .close => state.result = false,
        .destroy => {},
    }
    state.closed = true;
}

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
    state.values[2] = try allocator.dupe(u8, initial.check_description);
    state.values[3] = try allocator.dupe(u8, initial.trigger_prompt);
    state.values[4] = try allocator.dupe(u8, initial.first_instruction);
    state.values[5] = try allocator.dupe(u8, if (initial.pauses_before_writes_only) "true" else "false");
    state.values[6] = try allocator.dupe(u8, initial.goal_summary);
    state.values[7] = try allocator.dupe(u8, initial.goal_predicate);
    state.values[8] = try dupFloatText(allocator, initial.poll_interval_seconds);
    state.values[9] = try dupOptionalFloatText(allocator, initial.stall_after_seconds);
    state.values[10] = try allocator.dupe(u8, initial.metric_command);
    state.values[11] = try allocator.dupe(u8, initial.metric_direction);
    state.values[12] = try allocator.dupe(u8, initial.backend);
    state.values[13] = try allocator.dupe(u8, initial.model_tier);
    state.values[14] = try allocator.dupe(u8, initial.worktree_repository);
    state.values[15] = try allocator.dupe(u8, initial.worktree_path);
    state.values[16] = try allocator.dupe(u8, initial.worktree_branch);
    if (!(try show(state, "Create or edit node", &.{
        "Title", "Loop type", "Check description", "Trigger prompt",
        "First instruction", "Pause before writes only (true/false)", "Goal summary",
        "Goal predicate", "Poll interval seconds", "Stall after seconds", "Metric command",
        "Metric direction (maximize/minimize)", "Backend", "Model tier", "Worktree repository",
        "Worktree path", "Worktree branch",
    }))) return null;
    var result = Forms.NodeDraft{
        .title = try allocator.dupe(u8, state.values[0]),
        .loop_type = try allocator.dupe(u8, state.values[1]),
        .check_description = try allocator.dupe(u8, state.values[2]),
        .trigger_prompt = try allocator.dupe(u8, state.values[3]),
        .first_instruction = try allocator.dupe(u8, state.values[4]),
        .pauses_before_writes_only = std.mem.eql(u8, state.values[5], "true"),
        .goal_summary = try allocator.dupe(u8, state.values[6]),
        .goal_predicate = try allocator.dupe(u8, state.values[7]),
        .poll_interval_seconds = std.fmt.parseFloat(f64, state.values[8]) catch 60,
        .stall_after_seconds = if (std.mem.trim(u8, state.values[9], " \t\r\n").len == 0) null else std.fmt.parseFloat(f64, state.values[9]) catch null,
        .metric_command = try allocator.dupe(u8, state.values[10]),
        .metric_direction = try allocator.dupe(u8, state.values[11]),
        .backend = try allocator.dupe(u8, state.values[12]),
        .model_tier = try allocator.dupe(u8, state.values[13]),
        .worktree_repository = try allocator.dupe(u8, state.values[14]),
        .worktree_path = try allocator.dupe(u8, state.values[15]),
        .worktree_branch = try allocator.dupe(u8, state.values[16]),
    };
    errdefer result.deinit(allocator);
    return result;
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
    state.values[3] = try allocator.dupe(u8, initial.condition);
    state.values[4] = try allocator.dupe(u8, initial.transform_kind);
    state.values[5] = try allocator.dupe(u8, initial.transform_value);
    state.values[6] = try allocator.dupe(u8, initial.cycle_until);
    state.values[7] = try allocator.dupe(u8, initial.spawn_target_project_path);
    if (!(try show(state, "Create or edit edge", &.{
        "From node ID", "To node ID", "Edge kind", "Condition",
        "Transform (none/template/script)", "Transform value", "Cycle until",
        "Spawn target project path",
    }))) return null;
    var result = Forms.EdgeDraft{
        .from = try allocator.dupe(u8, state.values[0]),
        .to = try allocator.dupe(u8, state.values[1]),
        .kind = try allocator.dupe(u8, state.values[2]),
        .condition = try allocator.dupe(u8, state.values[3]),
        .transform_kind = try allocator.dupe(u8, state.values[4]),
        .transform_value = try allocator.dupe(u8, state.values[5]),
        .cycle_until = try allocator.dupe(u8, state.values[6]),
        .spawn_target_project_path = try allocator.dupe(u8, state.values[7]),
    };
    errdefer result.deinit(allocator);
    return result;
}

pub fn update(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    initial: Forms.NodeUpdate,
) !?Forms.NodeUpdate {
    const state = try allocator.create(DialogState);
    state.* = .{ .allocator = allocator, .kind = .update, .parent = parent };
    defer {
        freeValues(state);
        allocator.destroy(state);
    }
    state.values[0] = try dupOptional(allocator, initial.goal_summary);
    state.values[1] = try dupOptional(allocator, initial.goal_predicate);
    state.values[2] = try dupFloat(allocator, initial.poll_interval_seconds);
    state.values[3] = try dupFloat(allocator, initial.stall_after_seconds);
    state.values[4] = try dupOptional(allocator, initial.metric_command);
    state.values[5] = try dupOptional(allocator, initial.metric_direction);
    state.values[6] = try dupOptional(allocator, initial.trigger_prompt);
    state.values[7] = try dupOptional(allocator, initial.check_description);
    state.values[8] = try dupOptional(allocator, initial.model_tier);
    if (!(try show(state, "Update node", &.{
        "Goal summary (blank leaves unchanged)", "Goal predicate (blank clears)",
        "Poll interval seconds", "Stall after seconds", "Metric command",
        "Metric direction (maximize/minimize)", "Trigger prompt", "Check description",
        "Model tier (fast/standard/capable)",
    }))) return null;
    var result = Forms.NodeUpdate{
        .goal_summary = try changedOptional(allocator, state.values[0], initial.goal_summary),
        .goal_predicate = try changedOptional(allocator, state.values[1], initial.goal_predicate),
        .poll_interval_seconds = try changedFloat(state.values[2], initial.poll_interval_seconds, false),
        .stall_after_seconds = try changedFloat(state.values[3], initial.stall_after_seconds, true),
        .metric_command = try changedOptional(allocator, state.values[4], initial.metric_command),
        .metric_direction = try changedOptional(allocator, state.values[5], initial.metric_direction),
        .trigger_prompt = try changedOptional(allocator, state.values[6], initial.trigger_prompt),
        .check_description = try changedOptional(allocator, state.values[7], initial.check_description),
        .model_tier = try changedOptional(allocator, state.values[8], initial.model_tier),
    };
    Forms.validateNodeUpdate(result) catch {
        result.deinit(allocator);
        return error.InvalidNodeUpdate;
    };
    return result;
}

fn dupOptional(allocator: std.mem.Allocator, value: ?[]const u8) ![]u8 {
    return allocator.dupe(u8, value orelse "");
}

fn dupFloat(allocator: std.mem.Allocator, value: ?f64) ![]u8 {
    return if (value) |number| std.fmt.allocPrint(allocator, "{d}", .{number}) else allocator.dupe(u8, "");
}

fn dupFloatText(allocator: std.mem.Allocator, value: f64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

fn dupOptionalFloatText(allocator: std.mem.Allocator, value: ?f64) ![]u8 {
    return if (value) |number| std.fmt.allocPrint(allocator, "{d}", .{number}) else allocator.dupe(u8, "");
}

fn optionalValue(allocator: std.mem.Allocator, value: []const u8) !?[]u8 {
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return null;
    return try allocator.dupe(u8, value);
}

fn changedOptional(
    allocator: std.mem.Allocator,
    value: []const u8,
    initial: ?[]const u8,
) !?[]u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const original = initial orelse "";
    if (std.mem.eql(u8, trimmed, std.mem.trim(u8, original, " \t\r\n"))) return null;
    return try allocator.dupe(u8, if (trimmed.len == 0) "" else value);
}

fn changedFloat(value: []const u8, initial: ?f64, clear_blank: bool) !?f64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) {
        if (clear_blank and initial != null) return 0;
        return null;
    }
    const parsed = try std.fmt.parseFloat(f64, trimmed);
    if (initial) |original| if (parsed == original) return null;
    return parsed;
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

pub fn jump(parent: c.HWND, allocator: std.mem.Allocator, initial: []const u8) !?[]u8 {
    const state = try allocator.create(DialogState);
    state.* = .{ .allocator = allocator, .kind = .jump, .parent = parent };
    defer {
        freeValues(state);
        allocator.destroy(state);
    }
    state.values[0] = try allocator.dupe(u8, initial);
    if (!(try show(state, "Jump to loop", &.{"Loop title or ID"}))) return null;
    return try allocator.dupe(u8, state.values[0]);
}

fn show(state: *DialogState, title: []const u8, labels: []const []const u8) !bool {
    registerClass() catch return error.FormClassRegistrationFailed;
    const wide_title = try utf8ToWideZ(state.allocator, title);
    defer state.allocator.free(wide_title);
    active_state_storage = state.*;
    active_state_storage.closed = false;
    active_state_storage.result = false;
    active_state = true;
    const hwnd = c.CreateWindowExW(
        c.WS_EX_DLGMODALFRAME | c.WS_EX_CONTROLPARENT,
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
    var quit_code: ?c.WPARAM = null;
    while (!active_state_storage.closed) {
        const code = c.GetMessageW(&message, null, 0, 0);
        if (code <= 0) {
            active_state_storage.closed = true;
            if (code == 0) quit_code = message.wParam;
            break;
        }
        if (c.IsDialogMessageW(hwnd, &message) != 0) continue;
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }
    // Destroy the modal window from the owner thread after dispatch returns.
    // Calling DestroyWindow from the window procedure can violate the C
    // callback handle alignment contract on some Zig/Win32 combinations.
    _ = c.DestroyWindow(hwnd);
    _ = c.EnableWindow(state.parent, 1);
    _ = c.SetActiveWindow(state.parent);
    state.* = active_state_storage;
    active_state = false;
    if (quit_code) |value| c.PostQuitMessage(@intCast(value));
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
    const safe_hwnd: c.HWND = @ptrFromInt(@intFromPtr(hwnd.?));
    const value = &active_state_storage;
    switch (message) {
        c.WM_CREATE => {
            var labels: [17][]const u8 = .{ "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "" };
            var label_count: usize = 0;
            switch (value.kind) {
                .node => {
                    labels = .{ "Title", "Loop type", "Check description", "Trigger prompt", "First instruction", "Pause before writes only (true/false)", "Goal summary", "Goal predicate", "Poll interval seconds", "Stall after seconds", "Metric command", "Metric direction (maximize/minimize)", "Backend", "Model tier", "Worktree repository", "Worktree path", "Worktree branch" };
                    label_count = 17;
                },
                .edge => {
                    labels = .{ "From node ID", "To node ID", "Edge kind", "Condition", "Transform (none/template/script)", "Transform value", "Cycle until", "Spawn target project path", "", "", "", "", "", "", "", "", "" };
                    label_count = 8;
                },
                .update => {
                    labels = .{ "Goal summary (blank leaves unchanged)", "Goal predicate (blank clears)", "Poll interval seconds", "Stall after seconds", "Metric command", "Metric direction (maximize/minimize)", "Trigger prompt", "Check description", "Model tier (fast/standard/capable)", "", "", "", "", "", "", "", "" };
                    label_count = 9;
                },
                .settings => {
                    labels = .{ "Daemon pipe override", "Support directory", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "" };
                    label_count = 2;
                },
                .jump => {
                    labels = .{ "Loop title or ID", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "" };
                    label_count = 1;
                },
            }
            for (labels[0..label_count], 0..) |label, index| {
                createText(safe_hwnd, value, label, index);
            }
            createButton(safe_hwnd, "OK", ok_id, 350, @intCast(35 + label_count * 48));
            createButton(safe_hwnd, "Cancel", cancel_id, 265, @intCast(35 + label_count * 48));
            return 0;
        },
        c.WM_COMMAND => {
            const command = @as(u16, @truncate(wparam));
            if (command == ok_id) {
                readValues(value);
                applyModalCommand(value, .submit);
                return 0;
            }
            if (command == cancel_id) {
                applyModalCommand(value, .cancel);
                return 0;
            }
        },
        c.WM_CLOSE => {
            applyModalCommand(value, .close);
            return 0;
        },
        c.WM_DESTROY => {
            applyModalCommand(value, .destroy);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn createText(hwnd: c.HWND, state: *DialogState, label: []const u8, index: usize) void {
    const y: i32 = @intCast(15 + index * 48);
    const wide_label = utf8ToWideZ(state.allocator, label) catch return;
    defer state.allocator.free(wide_label);
    _ = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr, wide_label.ptr, c.WS_CHILD | c.WS_VISIBLE, 18, y, 420, 18, hwnd, null, c.GetModuleHandleW(null), null);
    const edit = c.CreateWindowExW(c.WS_EX_CLIENTEDGE, std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr, null, c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_AUTOHSCROLL, 18, y + 18, 420, 24, hwnd, childId(9100 + index), c.GetModuleHandleW(null), null) orelse return;
    state.edits[index] = edit;
    const wide_value = utf8ToWideZ(state.allocator, state.values[index]) catch return;
    defer state.allocator.free(wide_value);
    _ = c.SetWindowTextW(edit, wide_value.ptr);
}

fn createButton(hwnd: c.HWND, text: []const u8, id: usize, x: i32, y: i32) void {
    const wide = utf8ToWideZ(std.heap.c_allocator, text) catch return;
    defer std.heap.c_allocator.free(wide);
    _ = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON").ptr, wide.ptr, c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_DEFPUSHBUTTON, x, y, 70, 26, hwnd, childId(id), c.GetModuleHandleW(null), null);
}

fn childId(value: usize) c.HMENU {
    @setRuntimeSafety(false);
    return @ptrFromInt(value);
}

fn readValues(state: *DialogState) void {
    var buffer: [1024]u16 = undefined;
    const count: usize = switch (state.kind) {
        .node => 17,
        .edge => 8,
        .update => 9,
        .settings => 2,
        .jump => 1,
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

fn utf8ToWideZ(allocator: std.mem.Allocator, value: []const u8) ![]u16 {
    const raw = try std.unicode.utf8ToUtf16LeAlloc(allocator, value);
    defer allocator.free(raw);
    const result = try allocator.alloc(u16, raw.len + 1);
    @memcpy(result[0..raw.len], raw);
    result[raw.len] = 0;
    return result;
}

test "modal submit and cancel transitions always terminate the loop" {
    var state = DialogState{ .allocator = undefined, .kind = .node, .parent = null };
    applyModalCommand(&state, .submit);
    try std.testing.expect(state.closed);
    try std.testing.expect(state.result);
    state = DialogState{ .allocator = undefined, .kind = .node, .parent = null };
    applyModalCommand(&state, .cancel);
    try std.testing.expect(state.closed);
    try std.testing.expect(!state.result);
    state = DialogState{ .allocator = undefined, .kind = .node, .parent = null };
    applyModalCommand(&state, .close);
    try std.testing.expect(state.closed);
    state.result = true;
    applyModalCommand(&state, .destroy);
    try std.testing.expect(state.closed);
    try std.testing.expect(state.result);
}

test "jump modal result uses production query validation" {
    var state = DialogState{ .allocator = undefined, .kind = .jump, .parent = null };
    state.values[0] = @constCast(" \t\r\n");
    try std.testing.expectError(error.EmptyJumpQuery, Forms.validateJumpQuery(state.values[0]));
    state.values[0] = @constCast("Beta");
    try std.testing.expectEqualStrings("Beta", try Forms.validateJumpQuery(state.values[0]));
}
