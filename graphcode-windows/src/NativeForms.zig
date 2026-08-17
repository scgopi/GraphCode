const std = @import("std");
const Forms = @import("Forms.zig");
const c = @import("Win32.zig").c;

const DialogState = struct {
    allocator: std.mem.Allocator,
    kind: Kind,
    parent: c.HWND,
    result: bool = false,
    closed: bool = false,
    scroll_offset: i32 = 0,
    edits: [20]c.HWND = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
    values: [20][]u8 = .{ &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{} },
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
    state.values[12] = try allocator.dupe(u8, initial.backend orelse "");
    state.values[13] = try allocator.dupe(u8, initial.model_tier);
    state.values[14] = try allocator.dupe(u8, initial.worktree_repository);
    state.values[15] = try allocator.dupe(u8, initial.worktree_id);
    state.values[16] = try allocator.dupe(u8, initial.worktree_path);
    state.values[17] = try allocator.dupe(u8, initial.worktree_branch);
    state.values[18] = try allocator.dupe(u8, initial.subgraph_json);
    state.values[19] = try allocator.dupe(u8, initial.created_by);
    if (!(try show(state, "Create or edit node", &.{
        "Title", "Loop type", "Check description", "Trigger prompt",
        "First instruction", "Pause before writes only (true/false)", "Goal summary",
        "Goal predicate", "Poll interval seconds", "Stall after seconds", "Metric command",
        "Metric direction (maximize/minimize)", "Backend (blank inherits default)", "Model tier", "Worktree repository",
        "Worktree ID", "Worktree path", "Worktree branch", "Subgraph JSON", "Created by",
    }))) return null;
    const poll_interval = parseRequiredFloat(state.values[8]) catch return error.InvalidNumericInput;
    const stall_after = parseOptionalFloat(state.values[9]) catch return error.InvalidNumericInput;
    var result = Forms.NodeDraft{ .title = &.{}, .loop_type = &.{}, .check_description = &.{}, .trigger_prompt = &.{}, .first_instruction = &.{}, .goal_summary = &.{}, .goal_predicate = &.{}, .metric_command = &.{}, .metric_direction = &.{}, .model_tier = &.{}, .worktree_repository = &.{}, .worktree_id = &.{}, .worktree_path = &.{}, .worktree_branch = &.{}, .subgraph_json = &.{}, .created_by = &.{} };
    errdefer result.deinit(allocator);
    result.title = try allocator.dupe(u8, state.values[0]);
    result.loop_type = try allocator.dupe(u8, state.values[1]);
    result.check_description = try allocator.dupe(u8, state.values[2]);
    result.trigger_prompt = try allocator.dupe(u8, state.values[3]);
    result.first_instruction = try allocator.dupe(u8, state.values[4]);
    result.pauses_before_writes_only = std.mem.eql(u8, state.values[5], "true");
    result.goal_summary = try allocator.dupe(u8, state.values[6]);
    result.goal_predicate = try allocator.dupe(u8, state.values[7]);
    result.poll_interval_seconds = poll_interval;
    result.stall_after_seconds = stall_after;
    result.metric_command = try allocator.dupe(u8, state.values[10]);
    result.metric_direction = try allocator.dupe(u8, state.values[11]);
    result.backend = if (std.mem.trim(u8, state.values[12], " \t\r\n").len == 0) null else try allocator.dupe(u8, state.values[12]);
    result.model_tier = try allocator.dupe(u8, state.values[13]);
    result.worktree_repository = try allocator.dupe(u8, state.values[14]);
    result.worktree_id = try allocator.dupe(u8, state.values[15]);
    result.worktree_path = try allocator.dupe(u8, state.values[16]);
    result.worktree_branch = try allocator.dupe(u8, state.values[17]);
    result.subgraph_json = try allocator.dupe(u8, state.values[18]);
    result.created_by = try allocator.dupe(u8, state.values[19]);
    result.claude_permissions = initial.claude_permissions;
    result.copilot_permissions = initial.copilot_permissions;
    result.briefing_enabled = initial.briefing_enabled;
    result.activity_enabled = initial.activity_enabled;
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
    state.values[7] = try dupOptionalIntText(allocator, initial.cycle_max_iterations);
    state.values[8] = try dupOptionalIntText(allocator, initial.cycle_stop_after_passes);
    state.values[9] = try allocator.dupe(u8, initial.spawn_target_project_path);
    if (!(try show(state, "Create or edit edge", &.{
        "From node ID", "To node ID", "Edge kind", "Condition",
        "Transform (none/template/script)", "Transform value", "Cycle until",
        "Cycle max iterations", "Cycle stop after passes", "Spawn target project path",
    }))) return null;
    const cycle_max = parseOptionalInt(state.values[7]) catch return error.InvalidNumericInput;
    const cycle_stop = parseOptionalInt(state.values[8]) catch return error.InvalidNumericInput;
    var result = Forms.EdgeDraft{ .from = &.{}, .to = &.{}, .kind = &.{}, .condition = &.{}, .transform_kind = &.{}, .transform_value = &.{}, .cycle_until = &.{}, .spawn_target_project_path = &.{} };
    errdefer result.deinit(allocator);
    result.from = try allocator.dupe(u8, state.values[0]);
    result.to = try allocator.dupe(u8, state.values[1]);
    result.kind = try allocator.dupe(u8, state.values[2]);
    result.condition = try allocator.dupe(u8, state.values[3]);
    result.transform_kind = try allocator.dupe(u8, state.values[4]);
    result.transform_value = try allocator.dupe(u8, state.values[5]);
    result.cycle_until = try allocator.dupe(u8, state.values[6]);
    result.cycle_max_iterations = cycle_max;
    result.cycle_stop_after_passes = cycle_stop;
    result.spawn_target_project_path = try allocator.dupe(u8, state.values[9]);
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
        "Metric direction (blank leaves unchanged; maximize/minimize)", "Trigger prompt (blank clears)", "Check description (blank clears)",
        "Model tier (blank leaves unchanged; fast/standard/capable)",
    }))) return null;
    const poll_interval = try changedFloat(state.values[2], initial.poll_interval_seconds, false);
    const stall_after = try changedFloat(state.values[3], initial.stall_after_seconds, true);
    var result = Forms.NodeUpdate{};
    errdefer result.deinit(allocator);
    result.goal_summary = try changedOptional(allocator, state.values[0], initial.goal_summary, false);
    result.goal_predicate = try changedOptional(allocator, state.values[1], initial.goal_predicate, true);
    result.poll_interval_seconds = poll_interval;
    result.stall_after_seconds = stall_after;
    result.metric_command = try changedOptional(allocator, state.values[4], initial.metric_command, true);
    result.metric_direction = try changedOptional(allocator, state.values[5], initial.metric_direction, false);
    result.trigger_prompt = try changedOptional(allocator, state.values[6], initial.trigger_prompt, true);
    result.check_description = try changedOptional(allocator, state.values[7], initial.check_description, true);
    result.model_tier = try changedOptional(allocator, state.values[8], initial.model_tier, false);
    Forms.validateNodeUpdate(result) catch return error.InvalidNodeUpdate;
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

fn dupOptionalIntText(allocator: std.mem.Allocator, value: ?i64) ![]u8 {
    return if (value) |number| std.fmt.allocPrint(allocator, "{d}", .{number}) else allocator.dupe(u8, "");
}

fn parseRequiredFloat(value: []const u8) !f64 {
    return std.fmt.parseFloat(f64, std.mem.trim(u8, value, " \t\r\n"));
}

fn parseOptionalFloat(value: []const u8) !?f64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try std.fmt.parseFloat(f64, trimmed);
}

fn parseOptionalInt(value: []const u8) !?i64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try std.fmt.parseInt(i64, trimmed, 10);
}

fn optionalValue(allocator: std.mem.Allocator, value: []const u8) !?[]u8 {
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return null;
    return try allocator.dupe(u8, value);
}

fn changedOptional(
    allocator: std.mem.Allocator,
    value: []const u8,
    initial: ?[]const u8,
    allow_clear: bool,
) !?[]u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const original = initial orelse "";
    if (std.mem.eql(u8, trimmed, std.mem.trim(u8, original, " \t\r\n"))) return null;
    if (trimmed.len == 0 and !allow_clear) return null;
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
    _ = labels;
    registerClass() catch return error.FormClassRegistrationFailed;
    const wide_title = try utf8ToWideZ(state.allocator, title);
    defer state.allocator.free(wide_title);
    active_state_storage = state.*;
    active_state_storage.closed = false;
    active_state_storage.result = false;
    active_state = true;
    const screen_height = c.GetSystemMetrics(c.SM_CYSCREEN);
    const dialog_height: i32 = @max(320, @min(700, screen_height - 96));
    const hwnd = c.CreateWindowExW(
        c.WS_EX_DLGMODALFRAME | c.WS_EX_CONTROLPARENT,
        class_name.ptr,
        wide_title.ptr,
        c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU | c.WS_VSCROLL,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        470,
        dialog_height,
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
            var labels: [20][]const u8 = .{ "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "" };
            var label_count: usize = 0;
            switch (value.kind) {
                    .node => {
                        labels = .{ "Title", "Loop type", "Check description", "Trigger prompt", "First instruction", "Pause before writes only (true/false)", "Goal summary", "Goal predicate", "Poll interval seconds", "Stall after seconds", "Metric command", "Metric direction (maximize/minimize)", "Backend (blank inherits default)", "Model tier", "Worktree repository", "Worktree ID", "Worktree path", "Worktree branch", "Subgraph JSON", "Created by" };
                        label_count = 20;
                },
                .edge => {
                        labels = .{ "From node ID", "To node ID", "Edge kind", "Condition", "Transform (none/template/script)", "Transform value", "Cycle until", "Cycle max iterations", "Cycle stop after passes", "Spawn target project path", "", "", "", "", "", "", "", "", "", "" };
                        label_count = 10;
                },
                .update => {
                    labels = .{ "Goal summary (blank leaves unchanged)", "Goal predicate (blank clears)", "Poll interval seconds", "Stall after seconds", "Metric command", "Metric direction (maximize/minimize)", "Trigger prompt", "Check description", "Model tier (fast/standard/capable)", "", "", "", "", "", "", "", "", "", "", "", };
                    label_count = 9;
                },
                .settings => {
                    labels = .{ "Daemon pipe override", "Support directory", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "" };
                    label_count = 2;
                },
                .jump => {
                    labels = .{ "Loop title or ID", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "" };
                    label_count = 1;
                },
            }
            for (labels[0..label_count], 0..) |label, index| {
                createText(safe_hwnd, value, label, index);
            }
            var client: c.RECT = undefined;
            _ = c.GetClientRect(safe_hwnd, &client);
            createButton(safe_hwnd, "OK", ok_id, 350, client.bottom - 38);
            createButton(safe_hwnd, "Cancel", cancel_id, 265, client.bottom - 38);
            return 0;
        },
        c.WM_SIZE => {
            var client: c.RECT = undefined;
            _ = c.GetClientRect(safe_hwnd, &client);
            _ = c.MoveWindow(c.GetDlgItem(safe_hwnd, @intCast(ok_id)), 350, client.bottom - 38, 70, 26, 1);
            _ = c.MoveWindow(c.GetDlgItem(safe_hwnd, @intCast(cancel_id)), 265, client.bottom - 38, 70, 26, 1);
            updateScrollBar(safe_hwnd, value);
            return 0;
        },
        c.WM_VSCROLL => {
            const command: u16 = @truncate(wparam);
            if (command == c.SB_THUMBTRACK or command == c.SB_THUMBPOSITION) {
                var info: c.SCROLLINFO = std.mem.zeroes(c.SCROLLINFO);
                info.cbSize = @sizeOf(c.SCROLLINFO);
                info.fMask = c.SIF_TRACKPOS;
                if (c.GetScrollInfo(safe_hwnd, c.SB_VERT, &info) != 0) {
                    setScrollOffset(safe_hwnd, value, info.nTrackPos);
                }
                return 0;
            }
            const delta: i32 = switch (command) {
                c.SB_LINEUP => -48,
                c.SB_LINEDOWN => 48,
                c.SB_PAGEUP => -@as(i32, @intCast(@max(48, clientHeight(safe_hwnd) - 60))),
                c.SB_PAGEDOWN => @as(i32, @intCast(@max(48, clientHeight(safe_hwnd) - 60))),
                c.SB_TOP => -100000,
                c.SB_BOTTOM => 100000,
                else => 0,
            };
            scrollFields(safe_hwnd, value, delta);
            return 0;
        },
        c.WM_MOUSEWHEEL => {
            const wheel_delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
            scrollFields(safe_hwnd, value, if (wheel_delta > 0) -48 else 48);
            return 0;
        },
        c.WM_COMMAND => {
            const command = @as(u16, @truncate(wparam));
            const notification: u16 = @truncate(wparam >> 16);
            if (notification == c.EN_SETFOCUS and command >= 9100 and command < 9120) {
                ensureControlVisible(safe_hwnd, value, command - 9100);
                return 0;
            }
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
        c.WM_SETFOCUS => {
            if (c.GetFocus()) |focused| {
                for (0..20) |index| {
                    if (focused == value.edits[index]) {
                        ensureControlVisible(safe_hwnd, value, index);
                        break;
                    }
                }
            }
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
    _ = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr, wide_label.ptr, c.WS_CHILD | c.WS_VISIBLE, 18, y, 420, 18, hwnd, childId(8000 + index), c.GetModuleHandleW(null), null);
    const edit = c.CreateWindowExW(c.WS_EX_CLIENTEDGE, std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr, null, c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_AUTOHSCROLL, 18, y + 18, 420, 24, hwnd, childId(9100 + index), c.GetModuleHandleW(null), null) orelse return;
    state.edits[index] = edit;
    const wide_value = utf8ToWideZ(state.allocator, state.values[index]) catch return;
    defer state.allocator.free(wide_value);
    _ = c.SetWindowTextW(edit, wide_value.ptr);
}

fn clientHeight(hwnd: c.HWND) i32 {
    var rect: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &rect);
    return rect.bottom;
}

fn scrollFields(hwnd: c.HWND, state: *DialogState, requested: i32) void {
    const count: usize = switch (state.kind) {
        .node => 20,
        .edge => 10,
        .update => 9,
        .settings => 2,
        .jump => 1,
    };
    const viewport = clientHeight(hwnd);
    const content: i32 = @intCast(15 + count * 48 + 12);
    const next = boundedScrollOffset(content, viewport, state.scroll_offset, requested);
    setScrollOffsetValue(hwnd, state, next);
}

fn setScrollOffset(hwnd: c.HWND, state: *DialogState, requested: i32) void {
    const count: usize = switch (state.kind) {
        .node => 20,
        .edge => 10,
        .update => 9,
        .settings => 2,
        .jump => 1,
    };
    const viewport = clientHeight(hwnd);
    const content: i32 = @intCast(15 + count * 48 + 12);
    const next = std.math.clamp(requested, 0, @max(0, content - @max(120, viewport - 48)));
    setScrollOffsetValue(hwnd, state, next);
}

fn setScrollOffsetValue(hwnd: c.HWND, state: *DialogState, next: i32) void {
    const delta = state.scroll_offset - next;
    if (delta == 0) return;
    state.scroll_offset = next;
    const count: usize = switch (state.kind) {
        .node => 20,
        .edge => 10,
        .update => 9,
        .settings => 2,
        .jump => 1,
    };
    for (0..count) |index| {
        const y: i32 = @as(i32, @intCast(15 + index * 48)) - state.scroll_offset;
        _ = c.MoveWindow(c.GetDlgItem(hwnd, @intCast(8000 + index)), 18, y, 420, 18, 1);
        _ = c.MoveWindow(c.GetDlgItem(hwnd, @intCast(9100 + index)), 18, y + 18, 420, 24, 1);
    }
    updateScrollBar(hwnd, state);
}

fn updateScrollBar(hwnd: c.HWND, state: *DialogState) void {
    const count: usize = switch (state.kind) {
        .node => 20,
        .edge => 10,
        .update => 9,
        .settings => 2,
        .jump => 1,
    };
    const viewport = clientHeight(hwnd);
    const content: i32 = @intCast(15 + count * 48 + 12);
    const page: u32 = @intCast(@max(1, viewport - 48));
    const max_offset = @max(0, content - @as(i32, @intCast(page)));
    state.scroll_offset = std.math.clamp(state.scroll_offset, 0, max_offset);
    var info: c.SCROLLINFO = std.mem.zeroes(c.SCROLLINFO);
    info.cbSize = @sizeOf(c.SCROLLINFO);
    info.fMask = c.SIF_RANGE | c.SIF_PAGE | c.SIF_POS;
    info.nMin = 0;
    info.nMax = content;
    info.nPage = page;
    info.nPos = @intCast(state.scroll_offset);
    _ = c.SetScrollInfo(hwnd, c.SB_VERT, &info, 1);
}

fn ensureControlVisible(hwnd: c.HWND, state: *DialogState, index: usize) void {
    const viewport = clientHeight(hwnd);
    const top: i32 = @intCast(15 + index * 48);
    const bottom = top + 42;
    const visible_top = state.scroll_offset;
    const visible_bottom = state.scroll_offset + @max(1, viewport - 48);
    if (top < visible_top) {
        scrollFields(hwnd, state, top - visible_top);
    } else if (bottom > visible_bottom) {
        scrollFields(hwnd, state, bottom - visible_bottom);
    }

}

fn boundedScrollOffset(content: i32, viewport: i32, current: i32, requested: i32) i32 {
    const max_offset = @max(0, content - @max(120, viewport - 48));
    return std.math.clamp(current + requested, 0, max_offset);
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
        .node => 20,
        .edge => 10,
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

test "numeric form values reject malformed input instead of substituting defaults" {
    try std.testing.expectError(error.InvalidCharacter, parseRequiredFloat("not-a-number"));
    try std.testing.expectError(error.InvalidCharacter, parseOptionalInt("3x"));
    try std.testing.expectEqual(@as(?f64, null), try parseOptionalFloat(" \t"));
    try std.testing.expectEqual(@as(?i64, 7), try parseOptionalInt("7"));
}

test "keyboard-sized form keeps every field reachable through bounded scrolling" {
    const content: i32 = 15 + 20 * 48 + 12;
    const viewport: i32 = 768 - 96;
    const max_offset = boundedScrollOffset(content, viewport, 0, 100000);
    try std.testing.expect(max_offset > 0);
    try std.testing.expectEqual(max_offset, boundedScrollOffset(content, viewport, max_offset, 48));
    try std.testing.expectEqual(@as(i32, 0), boundedScrollOffset(content, viewport, 0, -48));
    const last_top: i32 = 15 + 19 * 48;
    try std.testing.expect(last_top + 42 <= max_offset + viewport - 48);
}

test "scrollbar thumb positions seek and clamp the dialog content" {
    const content: i32 = 15 + 20 * 48 + 12;
    const viewport: i32 = 768 - 96;
    try std.testing.expectEqual(@as(i32, 0), std.math.clamp(@as(i32, 0), 0, content - (viewport - 48)));
    const max_offset = boundedScrollOffset(content, viewport, 0, 100000);
    try std.testing.expectEqual(@as(i32, 200), std.math.clamp(@as(i32, 200), 0, max_offset));
    try std.testing.expectEqual(max_offset, std.math.clamp(@as(i32, 100000), 0, max_offset));
}
