const std = @import("std");
const Forms = @import("Forms.zig");
const WorktreeStatus = @import("WorktreeStatus.zig");
const c = @import("Win32.zig").c;

const DialogState = struct {
    allocator: std.mem.Allocator,
    kind: Kind,
    parent: c.HWND,
    result: bool = false,
    closed: bool = false,
    scroll_offset: i32 = 0,
    checks: [3]c.HWND = .{ null, null, null },
    labels: [20]c.HWND = .{null} ** 20,
    helps: [20]c.HWND = .{null} ** 20,
    edits: [20]c.HWND = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
    input_kinds: [20]InputKind = .{.edit} ** 20,
    choice_groups: [20]ChoiceGroup = .{.none} ** 20,
    visible: [20]bool = .{false} ** 20,
    field_count: usize = 0,
    intro: c.HWND = null,
    validation: c.HWND = null,
    values: [20][]u8 = .{ &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{} },
    initial_values: [20][]u8 = .{ &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{} },
    display_labels: [20][]u8 = .{ &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{} },
    policy: WorktreeStatus.Policy = .{},
    edge_endpoints: []const EdgeEndpoint = &.{},
    lock_edge_endpoints: bool = true,
};

const Kind = enum { node, edge, update, settings, jump, worktree_policy, worktree_sweep };
const InputKind = enum { edit, readonly, combo, checkbox };
const ChoiceGroup = enum { none, loop_type, backend, model_tier, metric_direction, optional_metric_direction, edge_kind, edge_condition, transform };
const Choice = struct { label: []const u8, value: []const u8 };
pub const EdgeEndpoint = struct { id: []const u8, title: []const u8 };
pub const WorktreeSweepResult = struct {
    selected: [20]bool = .{false} ** 20,
    count: usize = 0,
};
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeNativeForm");
const ok_id = 1;
const cancel_id = 2;
var active_state: bool = false;
var active_state_storage: DialogState = undefined;

const ModalCommand = enum { submit, cancel, close, destroy };

const loop_type_choices = [_]Choice{
    .{ .label = "Turn-based — pause for review", .value = "turnBased" },
    .{ .label = "Time-based — repeat a prompt", .value = "timeBased" },
    .{ .label = "Goal-based — work toward done", .value = "goalBased" },
    .{ .label = "Proactive — design a nested workflow", .value = "proactive" },
};
const backend_choices = [_]Choice{
    .{ .label = "Use workspace default", .value = "" },
    .{ .label = "Claude Code", .value = "claudeCode" },
    .{ .label = "GitHub Copilot CLI", .value = "copilotCLI" },
    .{ .label = "OpenAI Codex", .value = "codex" },
};
const model_choices = [_]Choice{
    .{ .label = "Use agent default", .value = "" },
    .{ .label = "Fast", .value = "fast" },
    .{ .label = "Standard", .value = "standard" },
    .{ .label = "Capable", .value = "capable" },
};
const metric_direction_choices = [_]Choice{
    .{ .label = "Higher is better", .value = "maximize" },
    .{ .label = "Lower is better", .value = "minimize" },
};
const optional_metric_direction_choices = [_]Choice{
    .{ .label = "Leave unchanged", .value = "" },
    .{ .label = "Higher is better", .value = "maximize" },
    .{ .label = "Lower is better", .value = "minimize" },
};
const edge_kind_choices = [_]Choice{
    .{ .label = "Hand-off — continue execution", .value = "handoff" },
    .{ .label = "Message — store a message route", .value = "message" },
    .{ .label = "Spawn — start work in another project", .value = "spawn" },
};
const edge_condition_choices = [_]Choice{
    .{ .label = "Always", .value = "always" },
    .{ .label = "Only after success", .value = "onSuccess" },
    .{ .label = "Only after failure", .value = "onFailure" },
};
const transform_choices = [_]Choice{
    .{ .label = "Pass context unchanged", .value = "none" },
    .{ .label = "Apply a text template", .value = "template" },
    .{ .label = "Run a script", .value = "script" },
};

fn choices(group: ChoiceGroup) []const Choice {
    return switch (group) {
        .loop_type => &loop_type_choices,
        .backend => &backend_choices,
        .model_tier => &model_choices,
        .metric_direction => &metric_direction_choices,
        .optional_metric_direction => &optional_metric_direction_choices,
        .edge_kind => &edge_kind_choices,
        .edge_condition => &edge_condition_choices,
        .transform => &transform_choices,
        .none => &.{},
    };
}

fn choiceIndex(group: ChoiceGroup, value: []const u8) usize {
    const normalized = if (group == .loop_type and std.mem.eql(u8, value, "composite")) "proactive" else value;
    for (choices(group), 0..) |choice, index| {
        if (std.mem.eql(u8, choice.value, normalized)) return index;
    }
    return 0;
}

fn choiceValue(group: ChoiceGroup, index: usize, previous: []const u8) []const u8 {
    const options = choices(group);
    if (index >= options.len) return previous;
    if (group == .loop_type and index == 3 and std.mem.eql(u8, previous, "composite"))
        return previous;
    return options[index].value;
}

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
    for (0..20) |index| state.initial_values[index] = try allocator.dupe(u8, state.values[index]);
    if (!(try show(state, "Create or edit node", &.{}))) return null;
    return try buildNodeDraft(allocator, state.values, initial);
}

fn buildNodeDraft(
    allocator: std.mem.Allocator,
    values: [20][]u8,
    initial: Forms.NodeDraft,
) !Forms.NodeDraft {
    const goal_based = std.mem.eql(u8, values[1], "goalBased");
    const poll_interval = if (goal_based)
        parseRequiredFloat(values[8]) catch return error.InvalidNumericInput
    else
        initial.poll_interval_seconds;
    const stall_after = if (goal_based)
        parseOptionalFloat(values[9]) catch return error.InvalidNumericInput
    else
        initial.stall_after_seconds;
    var result = Forms.NodeDraft{ .title = &.{}, .loop_type = &.{}, .check_description = &.{}, .trigger_prompt = &.{}, .first_instruction = &.{}, .goal_summary = &.{}, .goal_predicate = &.{}, .metric_command = &.{}, .metric_direction = &.{}, .model_tier = &.{}, .worktree_repository = &.{}, .worktree_id = &.{}, .worktree_path = &.{}, .worktree_branch = &.{}, .subgraph_json = &.{}, .created_by = &.{} };
    errdefer result.deinit(allocator);
    result.title = try allocator.dupe(u8, values[0]);
    result.loop_type = try allocator.dupe(u8, values[1]);
    result.check_description = try allocator.dupe(u8, values[2]);
    result.trigger_prompt = try allocator.dupe(u8, values[3]);
    result.first_instruction = try allocator.dupe(u8, values[4]);
    result.pauses_before_writes_only = std.mem.eql(u8, values[5], "true");
    result.goal_summary = try allocator.dupe(u8, values[6]);
    result.goal_predicate = try allocator.dupe(u8, values[7]);
    result.poll_interval_seconds = poll_interval;
    result.stall_after_seconds = stall_after;
    result.metric_command = try allocator.dupe(u8, values[10]);
    result.metric_direction = try allocator.dupe(u8, values[11]);
    result.backend = if (std.mem.trim(u8, values[12], " \t\r\n").len == 0) null else try allocator.dupe(u8, values[12]);
    result.model_tier = try allocator.dupe(u8, values[13]);
    result.worktree_repository = try allocator.dupe(u8, initial.worktree_repository);
    result.worktree_id = try allocator.dupe(u8, initial.worktree_id);
    result.worktree_path = try allocator.dupe(u8, initial.worktree_path);
    result.worktree_branch = try allocator.dupe(u8, initial.worktree_branch);
    result.subgraph_json = try allocator.dupe(u8, initial.subgraph_json);
    result.created_by = try allocator.dupe(u8, initial.created_by);
    result.claude_permissions = initial.claude_permissions;
    result.copilot_permissions = initial.copilot_permissions;
    result.briefing_enabled = initial.briefing_enabled;
    result.activity_enabled = initial.activity_enabled;
    try Forms.validateNode(result);
    return result;
}

pub fn edge(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    initial: Forms.EdgeDraft,
) !?Forms.EdgeDraft {
    return edgeWithEndpoints(parent, allocator, initial, &.{}, true);
}

pub fn edgeWithEndpoints(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    initial: Forms.EdgeDraft,
    endpoints: []const EdgeEndpoint,
    lock_endpoints: bool,
) !?Forms.EdgeDraft {
    const state = try allocator.create(DialogState);
    state.* = .{
        .allocator = allocator,
        .kind = .edge,
        .parent = parent,
        .edge_endpoints = endpoints,
        .lock_edge_endpoints = lock_endpoints,
    };
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
    if (!(try show(state, "Create or edit edge", &.{}))) return null;
    return try buildEdgeDraft(allocator, state.values);
}

fn buildEdgeDraft(allocator: std.mem.Allocator, values: [20][]u8) !Forms.EdgeDraft {
    const cycle_max = parseOptionalInt(values[7]) catch return error.InvalidNumericInput;
    const cycle_stop = parseOptionalInt(values[8]) catch return error.InvalidNumericInput;
    var result = Forms.EdgeDraft{ .from = &.{}, .to = &.{}, .kind = &.{}, .condition = &.{}, .transform_kind = &.{}, .transform_value = &.{}, .cycle_until = &.{}, .spawn_target_project_path = &.{} };
    errdefer result.deinit(allocator);
    result.from = try allocator.dupe(u8, values[0]);
    result.to = try allocator.dupe(u8, values[1]);
    result.kind = try allocator.dupe(u8, values[2]);
    result.condition = try allocator.dupe(u8, values[3]);
    result.transform_kind = try allocator.dupe(u8, values[4]);
    result.transform_value = try allocator.dupe(u8, values[5]);
    result.cycle_until = try allocator.dupe(u8, values[6]);
    result.cycle_max_iterations = cycle_max;
    result.cycle_stop_after_passes = cycle_stop;
    result.spawn_target_project_path = try allocator.dupe(u8, values[9]);
    try Forms.validateEdge(result);
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
    for (0..9) |index| state.initial_values[index] = try allocator.dupe(u8, state.values[index]);
    if (!(try show(state, "Update node", &.{}))) return null;
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

pub fn worktreePolicy(parent: c.HWND, allocator: std.mem.Allocator, initial: WorktreeStatus.Policy) !?WorktreeStatus.Policy {
    const state = try allocator.create(DialogState);
    state.* = .{ .allocator = allocator, .kind = .worktree_policy, .parent = parent, .policy = initial };
    defer {
        freeValues(state);
        allocator.destroy(state);
    }

    state.values[0] = try std.fmt.allocPrint(allocator, "{d}", .{initial.notice_size_gb});
    state.values[1] = try std.fmt.allocPrint(allocator, "{d}", .{initial.notice_count});
    if (!(try show(state, "Project Settings", &.{}))) return null;
    return state.policy;
}

pub fn worktreeSweep(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    project_name: []const u8,
    entries: []const WorktreeStatus.Entry,
) !?WorktreeSweepResult {
    const state = try allocator.create(DialogState);
    state.* = .{ .allocator = allocator, .kind = .worktree_sweep, .parent = parent };
    defer {
        freeValues(state);
        allocator.destroy(state);
    }
    const count = @min(entries.len, state.values.len);
    for (entries[0..count], 0..) |entry, index| {
        const tier = if (WorktreeStatus.decision(entry) == .reclaimable)
            "SAFE TO REMOVE"
        else if (entry.bound_running or entry.primary)
            "IN USE"
        else
            "LOOK BEFORE REMOVING";
        const branch = if (entry.branch.len != 0) entry.branch else entry.path;
        state.display_labels[index] = try std.fmt.allocPrint(
            allocator,
            "{s}: {s} - {s}",
            .{ tier, branch, WorktreeStatus.failureReasonText(entry) },
        );
        state.values[index] = try allocator.dupe(u8, if (WorktreeStatus.decision(entry) == .reclaimable) "true" else "false");
        state.initial_values[index] = try allocator.dupe(u8, state.values[index]);
        state.input_kinds[index] = .checkbox;
        state.visible[index] = true;
    }
    state.field_count = count;
    const title = try std.fmt.allocPrint(allocator, "Worktrees - {s}", .{project_name});
    defer allocator.free(title);
    if (!(try show(state, title, &.{}))) return null;
    var result = WorktreeSweepResult{ .count = count };
    for (0..count) |index| result.selected[index] = std.mem.eql(u8, state.values[index], "true");
    return result;
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
    const dialog_height: i32 = if (state.kind == .worktree_policy) 430 else @max(320, @min(700, screen_height - 96));
    const hwnd = c.CreateWindowExW(
        c.WS_EX_DLGMODALFRAME | c.WS_EX_CONTROLPARENT,
        class_name.ptr,
        wide_title.ptr,
        c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU | c.WS_VSCROLL,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        580,
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

fn configureFields(state: *DialogState) void {
    state.field_count = switch (state.kind) {
        .node => 14,
        .edge => 10,
        .update => 9,
        .settings => 2,
        .jump => 1,
        .worktree_policy => 0,
        .worktree_sweep => state.field_count,
    };
    for (0..state.field_count) |index| state.visible[index] = true;
    switch (state.kind) {
        .node => {
            state.input_kinds[1] = .combo;
            state.choice_groups[1] = .loop_type;
            state.input_kinds[5] = .checkbox;
            state.input_kinds[11] = .combo;
            state.choice_groups[11] = .metric_direction;
            state.input_kinds[12] = .combo;
            state.choice_groups[12] = .backend;
            state.input_kinds[13] = .combo;
            state.choice_groups[13] = .model_tier;
        },
        .edge => {
            state.input_kinds[0] = if (state.lock_edge_endpoints) .readonly else .combo;
            state.input_kinds[1] = if (state.lock_edge_endpoints) .readonly else .combo;
            state.input_kinds[2] = .combo;
            state.choice_groups[2] = .edge_kind;
            state.input_kinds[3] = .combo;
            state.choice_groups[3] = .edge_condition;
            state.input_kinds[4] = .combo;
            state.choice_groups[4] = .transform;
        },
        .update => {
            state.input_kinds[5] = .combo;
            state.choice_groups[5] = .optional_metric_direction;
            state.input_kinds[8] = .combo;
            state.choice_groups[8] = .model_tier;
        },
        else => {},
    }
    updateConditionalVisibility(state);
}

fn updateConditionalVisibility(state: *DialogState) void {
    switch (state.kind) {
        .node => {
            const loop_type = state.values[1];
            const turn = std.mem.eql(u8, loop_type, "turnBased");
            const timed = std.mem.eql(u8, loop_type, "timeBased");
            const goal = std.mem.eql(u8, loop_type, "goalBased");
            state.visible[2] = turn;
            state.visible[3] = timed;
            state.visible[4] = turn;
            state.visible[5] = turn;
            for (6..12) |index| state.visible[index] = goal;
        },
        .edge => {
            state.visible[5] = !std.mem.eql(u8, state.values[4], "none");
            state.visible[9] = std.mem.eql(u8, state.values[2], "spawn");
        },
        else => {},
    }
}

fn formIntro(kind: Kind) []const u8 {
    return switch (kind) {
        .node => "Choose how this loop works. Only the settings that affect that loop type are shown; existing internal graph metadata is preserved.",
        .edge => "Choose or confirm two loops, then describe how work moves between them.",
        .update => "Change only the fields you intend to update. Blank optional fields keep their documented clear-or-unchanged behavior.",
        .worktree_sweep => "Safe rows start selected. Blocked rows remain visible for review. Only committed, pushed, landed, unbound worktrees are eligible; branches remain recoverable from reflog.",
        else => "",
    };
}

fn fieldLabel(kind: Kind, index: usize) []const u8 {
    const node_labels = [_][]const u8{
        "Name (optional)",                           "How should this loop run?",          "What are you checking for? (optional)",
        "What should it do each time?",              "First instruction",                  "Pause only before writing files",
        "What does done look like?",                 "Done check command (optional)",      "Check every (seconds)",
        "Declare stalled after (seconds, optional)", "Progress metric command (optional)", "When is the metric better?",
        "Agent",                                     "Model",
    };
    const edge_labels = [_][]const u8{
        "Source loop identity",                          "Target loop identity", "What should this connection do?", "When does it fire?",
        "What context should cross?",                    "Template or script",   "Stop early command (optional)",   "Maximum passes (optional)",
        "Flat metric passes before stopping (optional)", "Target project path",
    };
    const update_labels = [_][]const u8{
        "Goal summary (blank leaves unchanged)", "Goal predicate (blank clears)",    "Poll interval seconds",
        "Stall after seconds (blank clears)",    "Metric command (blank clears)",    "Metric direction",
        "Trigger prompt (blank clears)",         "Check description (blank clears)", "Model tier",
    };
    const settings_labels = [_][]const u8{ "Daemon pipe override", "Support directory" };
    return switch (kind) {
        .node => node_labels[index],
        .edge => edge_labels[index],
        .update => update_labels[index],
        .settings => settings_labels[index],
        .jump => "Loop title or ID",
        .worktree_policy, .worktree_sweep => "",
    };
}

fn stateFieldLabel(state: *const DialogState, index: usize) []const u8 {
    if (state.kind == .worktree_sweep and state.display_labels[index].len != 0)
        return state.display_labels[index];
    return fieldLabel(state.kind, index);
}

fn fieldHelp(kind: Kind, index: usize) []const u8 {
    if (kind == .node) return switch (index) {
        2 => "Shown at each pause as the bar the loop is aiming for.",
        3 => "This prompt is run whenever the time-based trigger fires.",
        4 => "The session starts with this task instead of opening without direction.",
        5 => "When unchecked, the loop pauses after every turn.",
        6 => "Say it in your own words; the loop works toward this outcome.",
        7 => "Exit 0 means done.",
        10 => "A command that prints one number.",
        12 => "Use the workspace default unless this loop needs a specific agent.",
        else => "",
    };
    if (kind == .edge) return switch (index) {
        0, 1 => "Choose a loop by title; its stable graph identity is preserved.",
        2 => "Hand-offs unblock, messages deliver into a live session, and spawns instantiate work.",
        5 => "Required when a template or script transform is selected.",
        6 => "Exit 0 ends a repeated hand-off early.",
        7 => "A positive bound prevents an unbounded cycle.",
        8 => "Requires a progress metric on the source loop.",
        else => "",
    };
    return "";
}

fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (!active_state) return c.DefWindowProcW(hwnd, message, wparam, lparam);
    const safe_hwnd: c.HWND = @ptrFromInt(@intFromPtr(hwnd.?));
    const value = &active_state_storage;
    switch (message) {
        c.WM_CREATE => {
            configureFields(value);
            if (value.kind == .worktree_policy) {
                createStatic(safe_hwnd, value, "Project Settings", 18, 14, 530, 24, &value.intro);
                var unused: c.HWND = null;
                createStatic(safe_hwnd, value, "When a loop resolves and its branch has landed", 18, 48, 530, 20, &unused);
                createPolicyRadio(safe_hwnd, value, "Remove: automatically remove safe landed worktrees.", 0, 74);
                createPolicyRadio(safe_hwnd, value, "Ask: offer Reclaim / Keep on the resolved loop.", 1, 104);
                createPolicyRadio(safe_hwnd, value, "Keep: leave worktrees until Worktrees is opened.", 2, 134);
                createStatic(safe_hwnd, value, "Only landed, clean, pushed, unbound worktrees are ever eligible.", 18, 170, 530, 32, &unused);
                createStatic(safe_hwnd, value, "Mention worktrees when this project passes either threshold", 18, 210, 530, 20, &unused);
                createPolicyEdit(safe_hwnd, value, 0, 18, 238, 70);
                createStatic(safe_hwnd, value, "GB", 94, 242, 30, 20, &unused);
                createPolicyEdit(safe_hwnd, value, 1, 145, 238, 70);
                createStatic(safe_hwnd, value, "worktrees", 221, 242, 90, 20, &unused);
                createStatic(safe_hwnd, value, "The notice removes nothing; it only surfaces cleanup work.", 18, 276, 530, 32, &unused);
                createStatic(safe_hwnd, value, "", 18, 316, 360, 34, &value.validation);
            } else {
                createStatic(safe_hwnd, value, formIntro(value.kind), 18, 12, 530, 34, &value.intro);
                for (0..value.field_count) |index| createField(safe_hwnd, value, index);
                createStatic(safe_hwnd, value, "", 18, 0, 320, 34, &value.validation);
                layoutForm(safe_hwnd, value);
            }
            var client: c.RECT = undefined;
            _ = c.GetClientRect(safe_hwnd, &client);
            createButton(safe_hwnd, if (value.kind == .node) "Create" else if (value.kind == .worktree_policy) "Done" else if (value.kind == .worktree_sweep) "Remove Selected" else "OK", ok_id, 478, client.bottom - 38);
            createButton(safe_hwnd, "Cancel", cancel_id, 393, client.bottom - 38);
            return 0;
        },
        c.WM_SIZE => {
            var client: c.RECT = undefined;
            _ = c.GetClientRect(safe_hwnd, &client);
            _ = c.MoveWindow(c.GetDlgItem(safe_hwnd, @intCast(ok_id)), 478, client.bottom - 38, 70, 26, 1);
            _ = c.MoveWindow(c.GetDlgItem(safe_hwnd, @intCast(cancel_id)), 393, client.bottom - 38, 70, 26, 1);
            if (value.validation != null) _ = c.MoveWindow(value.validation, 18, client.bottom - 42, 360, 34, 1);
            if (value.kind != .worktree_policy) layoutForm(safe_hwnd, value);
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
            if ((notification == c.EN_SETFOCUS or notification == c.CBN_SETFOCUS or notification == c.BN_SETFOCUS) and command >= 9100 and command < 9120) {
                ensureControlVisible(safe_hwnd, value, command - 9100);
                return 0;
            }
            if (notification == c.CBN_SELCHANGE and command >= 9100 and command < 9120) {
                readValue(value, command - 9100);
                updateConditionalVisibility(value);
                setStaticText(value, value.validation, "");
                layoutForm(safe_hwnd, value);
                return 0;
            }
            if ((notification == c.EN_CHANGE or notification == c.BN_CLICKED) and command >= 9100 and command < 9120)
                setStaticText(value, value.validation, "");
            if (command == ok_id) {
                readValues(value);
                readPolicy(value);
                if (validationReason(value)) |reason| {
                    setStaticText(value, value.validation, reason);
                } else {
                    applyModalCommand(value, .submit);
                }
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

fn createStatic(hwnd: c.HWND, state: *DialogState, text: []const u8, x: i32, y: i32, width: i32, height: i32, output: *c.HWND) void {
    const wide = utf8ToWideZ(state.allocator, text) catch return;
    defer state.allocator.free(wide);
    output.* = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr, wide.ptr, c.WS_CHILD | c.WS_VISIBLE | c.SS_LEFT, x, y, width, height, hwnd, null, c.GetModuleHandleW(null), null);
}

fn isEndpointCombo(state: *const DialogState, index: usize) bool {
    return state.kind == .edge and !state.lock_edge_endpoints and index < 2;
}

fn endpointIndex(endpoints: []const EdgeEndpoint, value: []const u8) usize {
    for (endpoints, 0..) |endpoint, index| {
        if (std.mem.eql(u8, endpoint.id, value)) return index;
    }
    return 0;
}

fn inputControlHeight(kind: InputKind) i32 {
    return if (kind == .combo) 180 else 24;
}

fn createField(hwnd: c.HWND, state: *DialogState, index: usize) void {
    createStatic(
        hwnd,
        state,
        if (state.input_kinds[index] == .checkbox) "" else stateFieldLabel(state, index),
        18,
        0,
        530,
        18,
        &state.labels[index],
    );
    const style: c.DWORD = @as(c.DWORD, @intCast(c.WS_CHILD)) |
        @as(c.DWORD, @intCast(c.WS_VISIBLE)) |
        @as(c.DWORD, @intCast(c.WS_TABSTOP));
    const input = switch (state.input_kinds[index]) {
        .combo => c.CreateWindowExW(
            c.WS_EX_CLIENTEDGE,
            std.unicode.utf8ToUtf16LeStringLiteral("COMBOBOX").ptr,
            null,
            style | @as(c.DWORD, @intCast(c.CBS_DROPDOWNLIST)) | @as(c.DWORD, @intCast(c.WS_VSCROLL)),
            18,
            0,
            530,
            180,
            hwnd,
            childId(9100 + index),
            c.GetModuleHandleW(null),
            null,
        ),
        .checkbox => blk: {
            const wide = utf8ToWideZ(state.allocator, stateFieldLabel(state, index)) catch break :blk null;
            defer state.allocator.free(wide);
            break :blk c.CreateWindowExW(
                0,
                std.unicode.utf8ToUtf16LeStringLiteral("BUTTON").ptr,
                wide.ptr,
                style | @as(c.DWORD, @intCast(c.BS_AUTOCHECKBOX)),
                18,
                0,
                530,
                24,
                hwnd,
                childId(9100 + index),
                c.GetModuleHandleW(null),
                null,
            );
        },
        .edit, .readonly => c.CreateWindowExW(
            c.WS_EX_CLIENTEDGE,
            std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr,
            null,
            style | @as(c.DWORD, @intCast(c.ES_AUTOHSCROLL)) | (if (state.input_kinds[index] == .readonly) @as(c.DWORD, @intCast(c.ES_READONLY)) else 0),
            18,
            0,
            530,
            24,
            hwnd,
            childId(9100 + index),
            c.GetModuleHandleW(null),
            null,
        ),
    } orelse return;
    state.edits[index] = input;
    switch (state.input_kinds[index]) {
        .combo => {
            if (isEndpointCombo(state, index)) {
                for (state.edge_endpoints) |endpoint| {
                    const label = std.fmt.allocPrint(state.allocator, "{s} — {s}", .{ endpoint.title, endpoint.id }) catch continue;
                    defer state.allocator.free(label);
                    const wide = utf8ToWideZ(state.allocator, label) catch continue;
                    defer state.allocator.free(wide);
                    _ = c.SendMessageW(input, c.CB_ADDSTRING, 0, @intCast(@intFromPtr(wide.ptr)));
                }
                _ = c.SendMessageW(input, c.CB_SETCURSEL, endpointIndex(state.edge_endpoints, state.values[index]), 0);
            } else {
                for (choices(state.choice_groups[index])) |choice| {
                    const wide = utf8ToWideZ(state.allocator, choice.label) catch continue;
                    defer state.allocator.free(wide);
                    _ = c.SendMessageW(input, c.CB_ADDSTRING, 0, @intCast(@intFromPtr(wide.ptr)));
                }
                _ = c.SendMessageW(input, c.CB_SETCURSEL, choiceIndex(state.choice_groups[index], state.values[index]), 0);
            }
        },
        .checkbox => {
            _ = c.SendMessageW(input, c.BM_SETCHECK, if (std.mem.eql(u8, state.values[index], "true")) c.BST_CHECKED else c.BST_UNCHECKED, 0);
            if (state.kind == .worktree_sweep and !std.mem.eql(u8, state.initial_values[index], "true"))
                _ = c.EnableWindow(input, 0);
        },
        else => {
            const wide = utf8ToWideZ(state.allocator, state.values[index]) catch return;
            defer state.allocator.free(wide);
            _ = c.SetWindowTextW(input, wide.ptr);
        },
    }
    createStatic(hwnd, state, fieldHelp(state.kind, index), 18, 0, 530, 18, &state.helps[index]);
}

fn setStaticText(state: *DialogState, hwnd: c.HWND, text: []const u8) void {
    if (hwnd == null) return;
    const wide = utf8ToWideZ(state.allocator, text) catch return;
    defer state.allocator.free(wide);
    _ = c.SetWindowTextW(hwnd, wide.ptr);
}

fn layoutForm(hwnd: c.HWND, state: *DialogState) void {
    var row: i32 = 0;
    for (0..state.field_count) |index| {
        const shown = state.visible[index];
        const command = if (shown) c.SW_SHOW else c.SW_HIDE;
        _ = c.ShowWindow(state.labels[index], command);
        _ = c.ShowWindow(state.edits[index], command);
        _ = c.ShowWindow(state.helps[index], command);
        if (!shown) continue;
        const y = 54 + row * 64 - state.scroll_offset;
        _ = c.MoveWindow(state.labels[index], 18, y, 530, 18, 1);
        _ = c.MoveWindow(state.edits[index], 18, y + 18, 530, inputControlHeight(state.input_kinds[index]), 1);
        _ = c.MoveWindow(state.helps[index], 18, y + 43, 530, 18, 1);
        row += 1;
    }
    updateScrollBar(hwnd, state);
}

fn visibleRowFor(state: *const DialogState, target: usize) ?usize {
    var row: usize = 0;
    for (0..state.field_count) |index| {
        if (!state.visible[index]) continue;
        if (index == target) return row;
        row += 1;
    }
    return null;
}

fn visibleFieldCount(state: *const DialogState) usize {
    var count: usize = 0;
    for (state.visible[0..state.field_count]) |shown| if (shown) {
        count += 1;
    };
    return count;
}

fn contentHeight(state: *const DialogState) i32 {
    return @intCast(54 + visibleFieldCount(state) * 64 + 12);
}

fn clientHeight(hwnd: c.HWND) i32 {
    var rect: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &rect);
    return rect.bottom;
}

fn scrollFields(hwnd: c.HWND, state: *DialogState, requested: i32) void {
    const viewport = clientHeight(hwnd);
    const content = contentHeight(state);
    const next = boundedScrollOffset(content, viewport, state.scroll_offset, requested);
    setScrollOffsetValue(hwnd, state, next);
}

fn setScrollOffset(hwnd: c.HWND, state: *DialogState, requested: i32) void {
    const viewport = clientHeight(hwnd);
    const content = contentHeight(state);
    const next = std.math.clamp(requested, 0, @max(0, content - @max(120, viewport - 48)));
    setScrollOffsetValue(hwnd, state, next);
}

fn setScrollOffsetValue(hwnd: c.HWND, state: *DialogState, next: i32) void {
    const delta = state.scroll_offset - next;
    if (delta == 0) return;
    state.scroll_offset = next;
    layoutForm(hwnd, state);
    updateScrollBar(hwnd, state);
}

fn updateScrollBar(hwnd: c.HWND, state: *DialogState) void {
    const viewport = clientHeight(hwnd);
    const content = contentHeight(state);
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
    const row = visibleRowFor(state, index) orelse return;
    const viewport = clientHeight(hwnd);
    const top: i32 = @intCast(54 + row * 64);
    const bottom = top + 61;
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
    const button_style: c.DWORD = @intCast(if (id == ok_id) c.BS_DEFPUSHBUTTON else c.BS_PUSHBUTTON);
    const style: c.DWORD = @as(c.DWORD, @intCast(c.WS_CHILD)) |
        @as(c.DWORD, @intCast(c.WS_VISIBLE)) |
        @as(c.DWORD, @intCast(c.WS_TABSTOP)) |
        button_style;
    _ = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON").ptr, wide.ptr, style, x, y, 70, 26, hwnd, childId(id), c.GetModuleHandleW(null), null);
}

fn createCheckBox(hwnd: c.HWND, state: *DialogState, text: []const u8, index: usize, y: i32) void {
    const wide = utf8ToWideZ(state.allocator, text) catch return;
    defer state.allocator.free(wide);
    const check = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON").ptr, wide.ptr, c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_AUTOCHECKBOX, 18, y, 380, 24, hwnd, childId(9200 + index), c.GetModuleHandleW(null), null) orelse return;
    state.checks[index] = check;
    const selected = if (index == 0) state.policy.allow_reclaim else state.policy.confirm_each_reclaim;
    _ = c.SendMessageW(check, c.BM_SETCHECK, if (selected) c.BST_CHECKED else c.BST_UNCHECKED, 0);
}

fn createPolicyRadio(hwnd: c.HWND, state: *DialogState, text: []const u8, index: usize, y: i32) void {
    const wide = utf8ToWideZ(state.allocator, text) catch return;
    defer state.allocator.free(wide);
    const style: c.DWORD = @as(c.DWORD, @intCast(c.WS_CHILD)) |
        @as(c.DWORD, @intCast(c.WS_VISIBLE)) |
        @as(c.DWORD, @intCast(c.WS_TABSTOP)) |
        @as(c.DWORD, @intCast(c.BS_AUTORADIOBUTTON)) |
        (if (index == 0) @as(c.DWORD, @intCast(c.WS_GROUP)) else 0);
    const radio = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON").ptr,
        wide.ptr,
        style,
        18,
        y,
        530,
        24,
        hwnd,
        childId(9200 + index),
        c.GetModuleHandleW(null),
        null,
    ) orelse return;
    state.checks[index] = radio;
    const selected_index: usize = switch (state.policy.effectiveResolveAction()) {
        .remove => 0,
        .ask => 1,
        .keep, .legacy => 2,
    };
    _ = c.SendMessageW(radio, c.BM_SETCHECK, if (selected_index == index) c.BST_CHECKED else c.BST_UNCHECKED, 0);
}

fn createPolicyEdit(hwnd: c.HWND, state: *DialogState, index: usize, x: i32, y: i32, width: i32) void {
    const edit = c.CreateWindowExW(
        c.WS_EX_CLIENTEDGE,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr,
        null,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_AUTOHSCROLL | c.ES_NUMBER,
        x,
        y,
        width,
        24,
        hwnd,
        childId(9100 + index),
        c.GetModuleHandleW(null),
        null,
    ) orelse return;
    state.edits[index] = edit;
    const wide = utf8ToWideZ(state.allocator, state.values[index]) catch return;
    defer state.allocator.free(wide);
    _ = c.SetWindowTextW(edit, wide.ptr);
}

fn childId(value: usize) c.HMENU {
    @setRuntimeSafety(false);
    return @ptrFromInt(value);
}

fn readValues(state: *DialogState) void {
    for (0..state.field_count) |index| readValue(state, index);
}

fn readValue(state: *DialogState, index: usize) void {
    if (state.edits[index] == null) return;
    switch (state.input_kinds[index]) {
        .combo => {
            const selected = c.SendMessageW(state.edits[index], c.CB_GETCURSEL, 0, 0);
            if (selected < 0) return;
            const selected_index: usize = @intCast(selected);
            const next = if (isEndpointCombo(state, index) and selected_index < state.edge_endpoints.len)
                state.edge_endpoints[selected_index].id
            else
                choiceValue(state.choice_groups[index], selected_index, state.values[index]);
            const value = state.allocator.dupe(u8, next) catch return;
            state.allocator.free(state.values[index]);
            state.values[index] = value;
        },
        .checkbox => {
            const selected = c.SendMessageW(state.edits[index], c.BM_GETCHECK, 0, 0) == c.BST_CHECKED;
            const value = state.allocator.dupe(u8, if (selected) "true" else "false") catch return;
            state.allocator.free(state.values[index]);
            state.values[index] = value;
        },
        .edit, .readonly => {
            var buffer: [4096]u16 = undefined;
            const length = c.GetWindowTextW(state.edits[index], &buffer, @intCast(buffer.len));
            const value = std.unicode.utf16LeToUtf8Alloc(state.allocator, buffer[0..@intCast(length)]) catch return;
            state.allocator.free(state.values[index]);
            state.values[index] = value;
        },
    }
}

fn readPolicy(state: *DialogState) void {
    if (state.kind != .worktree_policy) return;
    readValue(state, 0);
    readValue(state, 1);
    const action: WorktreeStatus.ResolveAction = if (c.SendMessageW(state.checks[0], c.BM_GETCHECK, 0, 0) == c.BST_CHECKED)
        .remove
    else if (c.SendMessageW(state.checks[1], c.BM_GETCHECK, 0, 0) == c.BST_CHECKED)
        .ask
    else
        .keep;
    state.policy.applyResolveAction(action);
    state.policy.notice_size_gb = std.fmt.parseInt(u32, std.mem.trim(u8, state.values[0], " \t\r\n"), 10) catch state.policy.notice_size_gb;
    state.policy.notice_count = std.fmt.parseInt(u32, std.mem.trim(u8, state.values[1], " \t\r\n"), 10) catch state.policy.notice_count;
}

fn validationReason(state: *DialogState) ?[]const u8 {
    switch (state.kind) {
        .node => {
            const goal_based = std.mem.eql(u8, state.values[1], "goalBased");
            const poll = parseRequiredFloat(if (goal_based) state.values[8] else state.initial_values[8]) catch
                return "Enter a valid number of seconds between goal checks.";
            const stall = parseOptionalFloat(if (goal_based) state.values[9] else state.initial_values[9]) catch
                return "Enter a valid stall timeout, or leave it blank.";
            const backend: ?[]const u8 = if (std.mem.trim(u8, state.values[12], " \t\r\n").len == 0) null else state.values[12];
            Forms.validateNode(.{
                .title = state.values[0],
                .loop_type = state.values[1],
                .check_description = state.values[2],
                .trigger_prompt = state.values[3],
                .first_instruction = state.values[4],
                .pauses_before_writes_only = std.mem.eql(u8, state.values[5], "true"),
                .goal_summary = state.values[6],
                .goal_predicate = state.values[7],
                .poll_interval_seconds = poll,
                .stall_after_seconds = stall,
                .metric_command = state.values[10],
                .metric_direction = state.values[11],
                .backend = backend,
                .model_tier = state.values[13],
                .worktree_repository = state.values[14],
                .worktree_id = state.values[15],
                .worktree_path = state.values[16],
                .worktree_branch = state.values[17],
                .subgraph_json = state.values[18],
                .created_by = state.values[19],
            }) catch |err| return formErrorReason(err);
        },
        .edge => {
            const cycle_max = parseOptionalInt(state.values[7]) catch return "Maximum passes must be a whole number.";
            const cycle_stop = parseOptionalInt(state.values[8]) catch return "Flat metric passes must be a whole number.";
            Forms.validateEdge(.{
                .from = state.values[0],
                .to = state.values[1],
                .kind = state.values[2],
                .condition = state.values[3],
                .transform_kind = state.values[4],
                .transform_value = state.values[5],
                .cycle_until = state.values[6],
                .cycle_max_iterations = cycle_max,
                .cycle_stop_after_passes = cycle_stop,
                .spawn_target_project_path = state.values[9],
            }) catch |err| return formErrorReason(err);
        },
        .update => {
            if (parseOptionalFloat(state.values[2])) |value| {
                if (value) |number| if (number <= 0) return "Poll interval must be greater than zero.";
            } else |_| return "Poll interval must be a valid number.";
            if (parseOptionalFloat(state.values[3])) |_| {} else |_| return "Stall timeout must be a valid number.";
            if (!hasUpdateChanges(state)) return "Change at least one field, or choose Cancel.";
        },
        .jump => {
            _ = Forms.validateJumpQuery(state.values[0]) catch return "Enter a loop title or ID.";
        },
        .worktree_policy => {
            const size = std.fmt.parseInt(u32, std.mem.trim(u8, state.values[0], " \t\r\n"), 10) catch
                return "Enter a positive whole-number GB threshold.";
            const count = std.fmt.parseInt(u32, std.mem.trim(u8, state.values[1], " \t\r\n"), 10) catch
                return "Enter a positive whole-number worktree threshold.";
            if (size == 0 or count == 0) return "Worktree notice thresholds must be greater than zero.";
        },
        else => {},
    }

    return null;
}

fn hasUpdateChanges(state: *const DialogState) bool {
    for ([_]usize{ 1, 4, 6, 7 }) |index| {
        if (!std.mem.eql(
            u8,
            std.mem.trim(u8, state.values[index], " \t\r\n"),
            std.mem.trim(u8, state.initial_values[index], " \t\r\n"),
        )) return true;
    }
    for ([_]usize{ 0, 5, 8 }) |index| {
        const next = std.mem.trim(u8, state.values[index], " \t\r\n");
        if (next.len != 0 and !std.mem.eql(
            u8,
            next,
            std.mem.trim(u8, state.initial_values[index], " \t\r\n"),
        )) return true;
    }
    const poll = parseOptionalFloat(state.values[2]) catch return true;
    const initial_poll = parseOptionalFloat(state.initial_values[2]) catch return true;
    if (poll != initial_poll) return true;
    const stall = parseOptionalFloat(state.values[3]) catch return true;
    const initial_stall = parseOptionalFloat(state.initial_values[3]) catch return true;
    return stall != initial_stall;
}

fn formErrorReason(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyTitle => "Name this proactive loop to continue.",
        error.MissingFirstInstruction => "Add a first instruction to continue.",
        error.MissingTriggerPrompt => "Say what to do each time to continue.",
        error.InvalidGoal => "Say what done looks like and use positive timing values.",
        error.UnsupportedTransform => "Enter the template or script that should carry context.",
        error.InvalidCycleGuard => "Cycle limits must be positive whole numbers.",
        error.SameEndpoint => "Source and target must be different loops.",
        error.MissingSource, error.MissingTarget => "This connection needs both endpoint identities.",
        error.UnsupportedBackend => "Choose a supported agent.",
        error.UnsupportedModelTier => "Choose a supported model tier.",
        else => "Review the choices and required fields.",
    };
}

fn freeValues(state: *DialogState) void {
    for (&state.values) |value| if (value.len != 0) state.allocator.free(value);
    for (&state.initial_values) |value| if (value.len != 0) state.allocator.free(value);
    for (&state.display_labels) |value| if (value.len != 0) state.allocator.free(value);
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

test "guided choices map human labels to stable wire values" {
    try std.testing.expectEqual(@as(usize, 2), choiceIndex(.loop_type, "goalBased"));
    try std.testing.expectEqualStrings("goalBased", choiceValue(.loop_type, 2, "turnBased"));
    try std.testing.expectEqualStrings("composite", choiceValue(.loop_type, 3, "composite"));
    try std.testing.expectEqualStrings("copilotCLI", choiceValue(.backend, 2, ""));
    try std.testing.expectEqualStrings("onFailure", choiceValue(.edge_condition, 2, "always"));
    try std.testing.expectEqualStrings("script", choiceValue(.transform, 2, "none"));
    const endpoints = [_]EdgeEndpoint{
        .{ .id = "node-a", .title = "Alpha" },
        .{ .id = "node-b", .title = "Beta" },
    };
    try std.testing.expectEqual(@as(usize, 1), endpointIndex(&endpoints, "node-b"));
    try std.testing.expectEqual(@as(i32, 180), inputControlHeight(.combo));
    try std.testing.expectEqual(@as(i32, 24), inputControlHeight(.checkbox));
}

test "node draft builder preserves every hidden initial field" {
    var values: [20][]u8 = .{@constCast("")} ** 20;
    values[1] = @constCast("turnBased");
    values[4] = @constCast("Start here");
    values[5] = @constCast("false");
    values[8] = @constCast("60");
    values[11] = @constCast("maximize");
    const initial = Forms.NodeDraft{
        .title = "before",
        .worktree_repository = "D:\\repo",
        .worktree_id = "worktree-7",
        .worktree_path = "D:\\repo-wt",
        .worktree_branch = "feature/forms",
        .subgraph_json = "",
        .created_by = "11111111-1111-4111-8111-111111111111",
        .claude_permissions = "plan",
        .copilot_permissions = "readOnly",
        .briefing_enabled = false,
        .activity_enabled = true,
    };
    var draft = try buildNodeDraft(std.testing.allocator, values, initial);
    defer draft.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(initial.worktree_repository, draft.worktree_repository);
    try std.testing.expectEqualStrings(initial.worktree_id, draft.worktree_id);
    try std.testing.expectEqualStrings(initial.worktree_path, draft.worktree_path);
    try std.testing.expectEqualStrings(initial.worktree_branch, draft.worktree_branch);
    try std.testing.expectEqualStrings(initial.created_by, draft.created_by);
    try std.testing.expectEqualStrings(initial.claude_permissions, draft.claude_permissions);
    try std.testing.expectEqual(initial.briefing_enabled, draft.briefing_enabled);
    try std.testing.expectEqual(initial.activity_enabled, draft.activity_enabled);

    var hidden_values = values;
    hidden_values[8] = @constCast("not-a-number");
    hidden_values[9] = @constCast("also-invalid");
    var hidden_draft = try buildNodeDraft(std.testing.allocator, hidden_values, initial);
    defer hidden_draft.deinit(std.testing.allocator);
    try std.testing.expectEqual(initial.poll_interval_seconds, hidden_draft.poll_interval_seconds);
    try std.testing.expectEqual(initial.stall_after_seconds, hidden_draft.stall_after_seconds);
}

test "conditional graph fields and validation follow selected types" {
    var node_state = DialogState{ .allocator = undefined, .kind = .node, .parent = null };
    node_state.field_count = 14;
    for (0..14) |index| node_state.visible[index] = true;
    node_state.values[1] = @constCast("goalBased");
    node_state.values[6] = @constCast("");
    node_state.values[8] = @constCast("60");
    node_state.values[11] = @constCast("maximize");
    updateConditionalVisibility(&node_state);
    try std.testing.expect(node_state.visible[6]);
    try std.testing.expect(!node_state.visible[4]);
    try std.testing.expectEqualStrings("Say what done looks like and use positive timing values.", validationReason(&node_state).?);

    var edge_state = DialogState{ .allocator = undefined, .kind = .edge, .parent = null };
    edge_state.field_count = 10;
    for (0..10) |index| edge_state.visible[index] = true;
    edge_state.values[0] = @constCast("source");
    edge_state.values[1] = @constCast("target");
    edge_state.values[2] = @constCast("spawn");
    edge_state.values[3] = @constCast("always");
    edge_state.values[4] = @constCast("template");
    edge_state.values[5] = @constCast("");
    updateConditionalVisibility(&edge_state);
    try std.testing.expect(edge_state.visible[5]);
    try std.testing.expect(edge_state.visible[9]);
    try std.testing.expect(edge_state.visible[3]);
    try std.testing.expect(edge_state.visible[7]);
    try std.testing.expectEqualStrings("Enter the template or script that should carry context.", validationReason(&edge_state).?);

    edge_state.values[4] = @constCast("none");
    edge_state.values[6] = @constCast("test -f done.flag");
    edge_state.values[7] = @constCast("4");
    edge_state.values[8] = @constCast("2");
    edge_state.values[9] = @constCast("D:\\other-project");
    var edge_draft = try buildEdgeDraft(std.testing.allocator, edge_state.values);
    defer edge_draft.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("test -f done.flag", edge_draft.cycle_until);
    try std.testing.expectEqual(@as(?i64, 4), edge_draft.cycle_max_iterations);
    try std.testing.expectEqual(@as(?i64, 2), edge_draft.cycle_stop_after_passes);
    try std.testing.expectEqualStrings("D:\\other-project", edge_draft.spawn_target_project_path);

}

test "graph form cancellation leaves draft values untouched" {
    var state = DialogState{ .allocator = undefined, .kind = .edge, .parent = null };
    state.values[0] = @constCast("source-id");
    state.values[2] = @constCast("handoff");
    applyModalCommand(&state, .cancel);
    try std.testing.expect(!state.result);
    try std.testing.expect(state.closed);
    try std.testing.expectEqualStrings("source-id", state.values[0]);
    try std.testing.expectEqualStrings("handoff", state.values[2]);
}

test "keyboard-sized guided form keeps every field reachable through bounded scrolling" {
    const content: i32 = 54 + 10 * 64 + 12;
    const viewport: i32 = 768 - 96;
    const max_offset = boundedScrollOffset(content, viewport, 0, 100000);
    try std.testing.expectEqual(max_offset, boundedScrollOffset(content, viewport, max_offset, 48));
    try std.testing.expectEqual(@as(i32, 0), boundedScrollOffset(content, viewport, 0, -48));
    const last_top: i32 = 54 + 9 * 64;
    try std.testing.expect(last_top + 61 <= max_offset + viewport - 48);
}

test "scrollbar thumb positions seek and clamp the dialog content" {
    const content: i32 = 54 + 10 * 64 + 12;
    const viewport: i32 = 768 - 96;
    try std.testing.expectEqual(@as(i32, 0), std.math.clamp(@as(i32, 0), 0, content - (viewport - 48)));
    const max_offset = boundedScrollOffset(content, viewport, 0, 100000);
    try std.testing.expectEqual(@min(@as(i32, 200), max_offset), std.math.clamp(@as(i32, 200), 0, max_offset));
    try std.testing.expectEqual(max_offset, std.math.clamp(@as(i32, 100000), 0, max_offset));
}
