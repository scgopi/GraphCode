const std = @import("std");
const Forms = @import("Forms.zig");
const DraftAttachments = @import("DraftAttachments.zig");
const WorktreeStatus = @import("WorktreeStatus.zig");
const Tokens = @import("DesignTokens.zig");
const Win32 = @import("Win32.zig");
const c = Win32.c;
const Dpi = @import("Dpi.zig");
const AppFont = @import("AppFont.zig");
const ModalTeardown = @import("ModalTeardown.zig");

extern fn graphcode_pick_files(owner: c.HWND, buffer: [*]u16, stride: c.DWORD, max_files: c.DWORD) callconv(.c) c_int;

const DialogState = struct {
    allocator: std.mem.Allocator,
    kind: Kind,
    parent: c.HWND,
    result: bool = false,
    closed: bool = false,
    dpi: u32 = Dpi.base_dpi,
    scroll_offset: i32 = 0,
    checks: [3]c.HWND = .{ null, null, null },
    labels: [256]c.HWND = .{null} ** 256,
    helps: [256]c.HWND = .{null} ** 256,
    edits: [256]c.HWND = .{null} ** 256,
    input_kinds: [256]InputKind = .{.edit} ** 256,
    choice_groups: [256]ChoiceGroup = .{.none} ** 256,
    visible: [256]bool = .{false} ** 256,
    field_count: usize = 0,
    intro: c.HWND = null,
    validation: c.HWND = null,
    recap: c.HWND = null,
    values: [256][]u8 = .{&.{}} ** 256,
    initial_values: [256][]u8 = .{&.{}} ** 256,
    display_labels: [256][]u8 = .{&.{}} ** 256,
    sweep_selectable: [256]bool = .{false} ** 256,
    sweep_paths: [256][]const u8 = .{&.{}} ** 256,
    policy: WorktreeStatus.Policy = .{},
    edge_endpoints: []const EdgeEndpoint = &.{},
    lock_edge_endpoints: bool = true,
    immediate_policy_path: []const u8 = "",
    confirmation_armed: bool = false,
    tile_field_index: ?usize = null,
    tile_buttons: [max_tiles]c.HWND = .{null} ** max_tiles,
    tile_count: usize = 0,
    template_options: []const []const u8 = &.{},
    templates_available: bool = false,
    template_requested: bool = false,
    // Attachments live outside the fixed-index field system entirely (see the
    // "Attachments" comment above `createAttachmentsSection`): they are the one node
    // field with a variable-length, user-editable list of entries rather than a single
    // scalar value, and the field-index arrays above are sized/labelled per `Kind` in
    // ways that assume one value per index.
    attachment_project_path: []const u8 = "",
    attachment_draft_id: []const u8 = "",
    node_worktree_choices: []const WorktreeChoice = &.{},
    attachment_dir: []u8 = &.{},
    attachment_names: [DraftAttachments.max_attachments][]u8 = .{&.{}} ** DraftAttachments.max_attachments,
    attachment_paths: [DraftAttachments.max_attachments][]u8 = .{&.{}} ** DraftAttachments.max_attachments,
    attachment_ids: [DraftAttachments.max_attachments][]u8 = .{&.{}} ** DraftAttachments.max_attachments,
    attachment_count: usize = 0,
    attachment_label: c.HWND = null,
    attachment_listbox: c.HWND = null,
    attachment_attach_button: c.HWND = null,
    attachment_remove_button: c.HWND = null,
    attachment_help: c.HWND = null,
};

const max_tiles = 8;
const tile_base_id = 9600;
const attachment_attach_id = 8;
const attachment_remove_id = 9;

const Kind = enum { node, edge, update, settings, jump, template_picker, worktree_policy, worktree_sweep };
const InputKind = enum { edit, readonly, combo, checkbox, tiles };
const ChoiceGroup = enum { none, loop_type, backend, model_tier, metric_direction, optional_metric_direction, edge_kind, edge_condition, transform };
const Choice = struct { label: []const u8, value: []const u8, description: []const u8 = "", accent: u32 = Tokens.canvas_selection };
pub const EdgeEndpoint = struct { id: []const u8, title: []const u8 };
pub const WorktreeChoice = struct {
    path: []const u8,
    branch: []const u8,
    is_default: bool,
};
pub const WorktreeSweepResult = struct {
    selected: [256]bool = .{false} ** 256,
    count: usize = 0,
    destructive_confirmed: bool = false,
};
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeNativeForm");
const ok_id = 1;
const cancel_id = 2;
const reveal_id = 3;
const templates_id = 4;

const form_width: i32 = 760;
const form_max_height: i32 = 760;
const form_min_height: i32 = 420;
const form_margin: i32 = 24;
const form_fields_top: i32 = 76;
const form_footer_height: i32 = 64;
const form_label_height: i32 = 22;
const form_input_height: i32 = 32;
const form_help_height: i32 = 20;
const form_row_height: i32 = 84;
const tile_row_height: i32 = 204;
const attachment_section_height: i32 = 176;

fn scaled(state: *const DialogState, value: i32) i32 {
    return Dpi.scale(value, state.dpi);
}

fn formContentWidth(hwnd: c.HWND, state: *const DialogState) i32 {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    return @max(scaled(state, 240), client.right - scaled(state, form_margin * 2));
}

fn formViewportHeight(hwnd: c.HWND, state: *const DialogState) i32 {
    return @max(scaled(state, 120), clientHeight(hwnd) - scaled(state, form_footer_height));
}

var active_state: bool = false;
var active_state_storage: DialogState = undefined;

const ModalCommand = enum { submit, cancel, close, destroy };

pub fn isModalActive() bool {
    return active_state;
}

fn acquireModal() !void {
    if (active_state) return error.FormAlreadyOpen;
    active_state = true;
}

fn releaseModal() void {
    active_state = false;
}

/// Loop-type teaching-tile accents, converted from the exact RGB values macOS
/// uses for the same four types (LoopTypeAppearance.swift's `accent`), so the
/// Windows tiles read as the same visual language rather than a new palette.
fn tileColor(red: u8, green: u8, blue: u8) u32 {
    return @as(u32, red) | (@as(u32, green) << 8) | (@as(u32, blue) << 16);
}

const loop_type_choices = [_]Choice{
    .{ .label = "Turn-based", .value = "turnBased", .description = "Pauses for you each turn", .accent = tileColor(213, 81, 129) },
    .{ .label = "Time-based", .value = "timeBased", .description = "Runs again on a schedule", .accent = tileColor(201, 133, 0) },
    .{ .label = "Goal-based", .value = "goalBased", .description = "Works until a condition is met", .accent = tileColor(25, 158, 112) },
    .{ .label = "Proactive", .value = "proactive", .description = "A group of loops, armed later", .accent = tileColor(144, 133, 233) },
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

/// Applies a teaching-tile click: updates the bound field's value, redraws
/// every tile so the new selection highlight and old one both repaint, and
/// re-runs the same conditional-visibility/validation reset a combo change
/// would have triggered.
fn selectTile(state: *DialogState, tile_index: usize) void {
    const field_index = state.tile_field_index orelse return;
    const next = choiceValue(state.choice_groups[field_index], tile_index, state.values[field_index]);
    const value = state.allocator.dupe(u8, next) catch return;
    state.allocator.free(state.values[field_index]);
    state.values[field_index] = value;
    updateConditionalVisibility(state);
    setStaticText(state, state.validation, "");
    for (0..state.tile_count) |i| _ = c.InvalidateRect(state.tile_buttons[i], null, 1);
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
    project_path: []const u8,
    draft_id: []const u8,
    worktree_choices: []const WorktreeChoice,
    initial: Forms.NodeDraft,
) !?Forms.NodeDraft {
    return switch (try nodeWithTemplates(parent, allocator, project_path, draft_id, worktree_choices, initial, false)) {
        .draft => |draft| draft,
        .cancelled, .templates => null,
    };
}

pub const NodeResult = union(enum) {
    cancelled,
    draft: Forms.NodeDraft,
    templates: Forms.NodeDraft,
};

/// Opens the normal node form. Saved templates are an explicit secondary action,
/// mirroring macOS's Templates control rather than intercepting New Loop.
pub fn nodeWithTemplates(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    project_path: []const u8,
    draft_id: []const u8,
    worktree_choices: []const WorktreeChoice,
    initial: Forms.NodeDraft,
    templates_available: bool,
) !NodeResult {
    const state = try allocator.create(DialogState);
    state.* = .{
        .allocator = allocator,
        .kind = .node,
        .parent = parent,
        .templates_available = templates_available,
        .node_worktree_choices = worktree_choices,
    };
    state.attachment_project_path = project_path;
    state.attachment_draft_id = draft_id;
    var attachments_transferred = false;
    defer {
        // A cancelled dialog leaves nothing behind for the daemon to clean up — the
        // draft id it was staged under is never going to become a real node — so the
        // client has to take the same responsibility macOS's `cancelNodeForm` does.
        if (!state.result and !attachments_transferred and state.attachment_dir.len != 0)
            DraftAttachments.discardAll(state.attachment_dir);
        freeAttachmentState(state);
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
    state.values[14] = try worktreeSelectionText(allocator, worktree_choices, initial.worktree_path);
    state.values[15] = try allocator.dupe(u8, initial.worktree_repository);
    state.values[16] = try allocator.dupe(u8, initial.worktree_id);
    state.values[17] = try allocator.dupe(u8, initial.worktree_path);
    state.values[18] = try allocator.dupe(u8, initial.worktree_branch);
    state.values[19] = try allocator.dupe(u8, initial.subgraph_json);
    state.values[20] = try allocator.dupe(u8, initial.created_by);
    for (0..21) |index| state.initial_values[index] = try allocator.dupe(u8, state.values[index]);
    try restoreStagedAttachments(state, initial);
    if (!(try show(state, "Create or edit node", &.{}))) {
        if (!state.template_requested) return .cancelled;
        const draft = try buildNodeDraftUnchecked(allocator, state, initial);
        attachments_transferred = true;
        return .{ .templates = draft };
    }
    return .{ .draft = buildNodeDraft(allocator, state, initial) catch |err| {
        // The user pressed Create, but validation rejected the draft, so no node will
        // claim this staged directory.
        if (state.attachment_dir.len != 0) DraftAttachments.discardAll(state.attachment_dir);
        return err;
    } };
}

/// A native, keyboard-searchable list of saved templates. The editable combo
/// provides standard type-ahead search, Up/Down selection, Enter acceptance,
/// and UI Automation ComboBox semantics without introducing a custom canvas.
pub fn templatePicker(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    options: []const []const u8,
) !?usize {
    if (options.len == 0) return null;
    const state = try allocator.create(DialogState);
    state.* = .{ .allocator = allocator, .kind = .template_picker, .parent = parent, .template_options = options };
    defer {
        freeValues(state);
        allocator.destroy(state);
    }
    state.values[0] = try allocator.dupe(u8, "0");
    if (!(try show(state, "Choose a saved template", &.{}))) return null;
    const selected = std.fmt.parseUnsigned(usize, state.values[0], 10) catch return error.InvalidTemplateSelection;
    if (selected >= options.len) return error.InvalidTemplateSelection;
    return selected;
}

fn restoreStagedAttachments(state: *DialogState, initial: Forms.NodeDraft) !void {
    if (initial.attachment_count == 0) return;
    const support = try DraftAttachments.supportDirectory(state.allocator);
    defer state.allocator.free(support);
    state.attachment_dir = try DraftAttachments.attachmentsDirectory(
        state.allocator,
        support,
        state.attachment_project_path,
        state.attachment_draft_id,
    );
    for (0..initial.attachment_count) |index| {
        state.attachment_paths[index] = try state.allocator.dupe(u8, initial.attachment_paths[index]);
        state.attachment_ids[index] = try state.allocator.dupe(u8, initial.attachment_ids[index]);
        state.attachment_names[index] = try state.allocator.dupe(
            u8,
            std.fs.path.basename(initial.attachment_paths[index]),
        );
    }
    state.attachment_count = initial.attachment_count;
}

fn buildNodeDraft(
    allocator: std.mem.Allocator,
    state: *const DialogState,
    initial: Forms.NodeDraft,
) !Forms.NodeDraft {
    var result = try buildNodeDraftUnchecked(allocator, state, initial);
    errdefer result.deinit(allocator);
    try Forms.validateNode(result);
    return result;
}

fn buildNodeDraftUnchecked(
    allocator: std.mem.Allocator,
    state: *const DialogState,
    initial: Forms.NodeDraft,
) !Forms.NodeDraft {
    const values = &state.values;
    const selected_worktree = selectedWorktreeChoice(state);
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
    const preserves_initial_worktree = state.node_worktree_choices.len == 0;
    result.worktree_repository = try allocator.dupe(u8, if (selected_worktree != null) state.attachment_project_path else if (preserves_initial_worktree) initial.worktree_repository else "");
    result.worktree_id = try allocator.dupe(u8, if (selected_worktree) |choice| choice.branch else if (preserves_initial_worktree) initial.worktree_id else "");
    result.worktree_path = try allocator.dupe(u8, if (selected_worktree) |choice| choice.path else if (preserves_initial_worktree) initial.worktree_path else "");
    result.worktree_branch = try allocator.dupe(u8, if (selected_worktree) |choice| choice.branch else if (preserves_initial_worktree) initial.worktree_branch else "");
    result.subgraph_json = try allocator.dupe(u8, initial.subgraph_json);
    result.created_by = try allocator.dupe(u8, initial.created_by);
    result.claude_permissions = initial.claude_permissions;
    result.copilot_permissions = initial.copilot_permissions;
    result.briefing_enabled = initial.briefing_enabled;
    result.activity_enabled = initial.activity_enabled;
    // Only carried when at least one file was staged: an unattached node keeps the
    // legacy empty `node_id`, so `DaemonClient.sendCreateNodeDraft` still generates a
    // fresh one at send time exactly as it always has, and the dialog's would-be draft
    // directory (never created, since nothing was ever ingested into it) is simply
    // abandoned rather than referenced by a node that has no reason to expect it.
    if (state.attachment_count != 0) {
        result.node_id = try allocator.dupe(u8, state.attachment_draft_id);
        for (0..state.attachment_count) |index| {
            result.attachment_paths[index] = try allocator.dupe(u8, state.attachment_paths[index]);
            result.attachment_ids[index] = try allocator.dupe(u8, state.attachment_ids[index]);
        }
        result.attachment_count = state.attachment_count;
    }
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
    return try buildEdgeDraft(allocator, &state.values);
}

fn buildEdgeDraft(allocator: std.mem.Allocator, values: []const []u8) !Forms.EdgeDraft {
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
    try initializeNodeUpdate(state, initial);
    if (!(try show(state, "Update node", &.{}))) return null;
    return try buildNodeUpdate(state, initial);
}

fn initializeNodeUpdate(state: *DialogState, initial: Forms.NodeUpdate) !void {
    const allocator = state.allocator;
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
}

fn buildNodeUpdate(state: *const DialogState, initial: Forms.NodeUpdate) !?Forms.NodeUpdate {
    if (!state.result) return null;
    const allocator = state.allocator;
    const poll_interval = try changedFloat(state.values[2], initial.poll_interval_seconds, false);
    const stall_after = try changedFloat(state.values[3], initial.stall_after_seconds, true);
    var result = Forms.NodeUpdate{};
    errdefer result.deinit(allocator);
    result.goal_summary = try changedOptional(allocator, state.values[0], state.initial_values[0], false);
    result.goal_predicate = try changedOptional(allocator, state.values[1], state.initial_values[1], true);
    result.poll_interval_seconds = poll_interval;
    result.stall_after_seconds = stall_after;
    result.metric_command = try changedOptional(allocator, state.values[4], state.initial_values[4], true);
    result.metric_direction = try changedOptional(allocator, state.values[5], state.initial_values[5], false);
    result.trigger_prompt = try changedOptional(allocator, state.values[6], state.initial_values[6], true);
    result.check_description = try changedOptional(allocator, state.values[7], state.initial_values[7], true);
    result.model_tier = try changedOptional(allocator, state.values[8], state.initial_values[8], false);
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

pub fn worktreePolicy(parent: c.HWND, allocator: std.mem.Allocator, project_path: []const u8, initial: WorktreeStatus.Policy) !?WorktreeStatus.Policy {
    const state = try allocator.create(DialogState);
    state.* = .{
        .allocator = allocator,
        .kind = .worktree_policy,
        .parent = parent,
        .policy = initial,
        .immediate_policy_path = project_path,
    };
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
        const size = try WorktreeStatus.sizeCoverageText(allocator, entry.sizeCoverage());
        defer allocator.free(size);
        state.display_labels[index] = try std.fmt.allocPrint(
            allocator,
            "{s}: {s} - {s} - {s}",
            .{ tier, branch, WorktreeStatus.failureReasonText(entry), size },
        );
        state.values[index] = try allocator.dupe(u8, if (WorktreeStatus.sweepSelectable(entry) and WorktreeStatus.decision(entry) == .reclaimable) "true" else "false");
        state.initial_values[index] = try allocator.dupe(u8, state.values[index]);
        state.input_kinds[index] = .checkbox;
        state.visible[index] = true;
        state.sweep_selectable[index] = WorktreeStatus.sweepSelectable(entry);
        state.sweep_paths[index] = entry.path;
    }
    state.field_count = count;
    var safe_count: usize = 0;
    var look_count: usize = 0;
    var in_use_count: usize = 0;
    for (entries[0..count]) |entry| {
        if (entry.primary or entry.bound_running) {
            in_use_count += 1;
        } else if (WorktreeStatus.decision(entry) == .reclaimable) {
            safe_count += 1;
        } else {
            look_count += 1;
        }
    }
    const total_text = try WorktreeStatus.sizeCoverageText(allocator, WorktreeStatus.totalSize(entries[0..count]));
    defer allocator.free(total_text);
    const title = try std.fmt.allocPrint(
        allocator,
        "Worktrees - {s} ({d} total, {d} safe, {d} look, {d} in use, {s})",
        .{ project_name, count, safe_count, look_count, in_use_count, total_text },
    );
    defer allocator.free(title);
    if (!(try show(state, title, &.{}))) return null;
    var result = WorktreeSweepResult{ .count = count, .destructive_confirmed = state.confirmation_armed };
    for (0..count) |index| result.selected[index] = std.mem.eql(u8, state.values[index], "true");
    return result;
}

fn show(state: *DialogState, title: []const u8, labels: []const []const u8) !bool {
    _ = labels;
    try acquireModal();
    defer releaseModal();
    registerClass() catch return error.FormClassRegistrationFailed;
    const wide_title = try utf8ToWideZ(state.allocator, title);
    defer state.allocator.free(wide_title);
    active_state_storage = state.*;
    active_state_storage.closed = false;
    active_state_storage.result = false;
    active_state_storage.dpi = Dpi.normalize(Win32.dpiForWindow(state.parent));
    const screen_height = c.GetSystemMetrics(c.SM_CYSCREEN);
    const desired_height = if (state.kind == .worktree_policy) 520 else form_max_height;
    const dialog_height = @max(
        Dpi.scale(form_min_height, active_state_storage.dpi),
        @min(Dpi.scale(desired_height, active_state_storage.dpi), screen_height - Dpi.scale(64, active_state_storage.dpi)),
    );
    const hwnd = c.CreateWindowExW(
        c.WS_EX_DLGMODALFRAME | c.WS_EX_CONTROLPARENT,
        class_name.ptr,
        wide_title.ptr,
        c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU | c.WS_VSCROLL,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        Dpi.scale(form_width, active_state_storage.dpi),
        dialog_height,
        state.parent,
        null,
        c.GetModuleHandleW(null),
        @ptrCast(state),
    ) orelse {
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
    ModalTeardown.dismiss(hwnd, state.parent);
    state.* = active_state_storage;
    if (quit_code) |value| c.PostQuitMessage(@intCast(value));
    return state.result;
}

fn registerClass() !void {
    var window_class: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    window_class.lpfnWndProc = @ptrCast(&windowProc);
    window_class.hInstance = c.GetModuleHandleW(null);
    window_class.lpszClassName = class_name.ptr;
    window_class.hCursor = c.LoadCursorW(null, Win32.resourceIdentifier(32512));
    window_class.hbrBackground = null;
    if (c.RegisterClassW(&window_class) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.ClassRegistrationFailed;
}

// Dark sheet theme: same panel/text palette as the validated
// WindowsProductSettings.zig window (see DesignTokens.zig), applied here so
// every native form/sheet (node, edge, update, jump, worktree policy/sweep)
// paints with the app's dark native language instead of default Win32 gray.
var dark_field_brush: c.HBRUSH = null;
var dark_panel_brush: c.HBRUSH = null;

fn darkFieldBrush() c.HBRUSH {
    if (dark_field_brush == null) dark_field_brush = c.CreateSolidBrush(Tokens.dialog_field_background);
    return dark_field_brush;
}

// WM_ERASEBKGND fires repeatedly while a form lays out and repaints (every
// moved control can trigger one), so the panel brush is created once and
// reused rather than allocated/freed on every erase.
fn darkPanelBrush() c.HBRUSH {
    if (dark_panel_brush == null) dark_panel_brush = c.CreateSolidBrush(Tokens.dialog_panel);
    return dark_panel_brush;
}

fn fillFormBackground(hdc: c.HDC, bounds: c.RECT) void {
    const brush = darkPanelBrush();
    if (brush == null) return;
    _ = c.FillRect(hdc, &bounds, brush);
}

fn formCtlColorStatic(hwnd: c.HWND, wparam: c.WPARAM, validation_label: c.HWND) c.LRESULT {
    const hdc = deviceContextFrom(wparam);
    _ = c.SetTextColor(hdc, if (hwnd == validation_label) Tokens.dialog_error_text else Tokens.dialog_body_text);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    return @intCast(@intFromPtr(c.GetStockObject(c.NULL_BRUSH)));
}

fn formCtlColorEdit(wparam: c.WPARAM) c.LRESULT {
    const hdc = deviceContextFrom(wparam);
    _ = c.SetTextColor(hdc, Tokens.dialog_title_text);
    _ = c.SetBkColor(hdc, Tokens.dialog_field_background);
    _ = c.SetBkMode(hdc, c.OPAQUE);
    return @intCast(@intFromPtr(darkFieldBrush()));
}

fn deviceContextFrom(wparam: c.WPARAM) c.HDC {
    @setRuntimeSafety(false);
    return @ptrFromInt(wparam);
}

fn controlHandleFrom(lparam: c.LPARAM) c.HWND {
    @setRuntimeSafety(false);
    return @ptrFromInt(@as(usize, @bitCast(lparam)));
}

/// Win32 passes the `DRAWITEMSTRUCT` address through `lparam`. Safety is
/// disabled for the same reason as the handle conversions above: the value
/// arrives as a raw integer and must not be subjected to Zig's pointer
/// alignment assertions, which abort the process rather than fail softly.
fn drawItemFrom(lparam: c.LPARAM) *c.DRAWITEMSTRUCT {
    @setRuntimeSafety(false);
    return @ptrFromInt(@as(usize, @bitCast(lparam)));
}

/// Blends `overlay` into `base` at `percent` strength (0-100), approximating
/// the translucent accent fills LoopTypeChooser.swift layers over its dark
/// background (`type.accent.opacity(0.12)` selected / `Color.white.opacity(0.035)`
/// idle) using plain GDI solid fills.
fn blendColor(base: u32, overlay: u32, percent: u8) u32 {
    const inv: u32 = 100 - percent;
    const br = base & 0xFF;
    const bg = (base >> 8) & 0xFF;
    const bb = (base >> 16) & 0xFF;
    const orr = overlay & 0xFF;
    const og = (overlay >> 8) & 0xFF;
    const ob = (overlay >> 16) & 0xFF;
    const r = (br * inv + orr * percent) / 100;
    const g = (bg * inv + og * percent) / 100;
    const b = (bb * inv + ob * percent) / 100;
    return r | (g << 8) | (b << 16);
}

fn drawTile(state: *DialogState, tile_index: usize, draw_item: *c.DRAWITEMSTRUCT) void {
    const field_index = state.tile_field_index orelse return;
    const options = choices(state.choice_groups[field_index]);
    if (tile_index >= options.len) return;
    const choice = options[tile_index];
    const selected = std.mem.eql(u8, choice.value, state.values[field_index]) or
        (std.mem.eql(u8, choice.value, "proactive") and std.mem.eql(u8, state.values[field_index], "composite"));
    const bounds = draw_item.rcItem;
    const card_color = if (selected) blendColor(Tokens.dialog_panel, choice.accent, 22) else blendColor(Tokens.dialog_panel, 0x00FFFFFF, 4);
    const border_color = if (selected) choice.accent else Tokens.dialog_field_border;
    const brush = c.CreateSolidBrush(card_color);
    const pen = c.CreatePen(c.PS_SOLID, if (selected) 2 else 1, border_color);
    if (brush != null and pen != null) {
        const old_brush = c.SelectObject(draw_item.hDC, brush);
        const old_pen = c.SelectObject(draw_item.hDC, pen);
        _ = c.RoundRect(draw_item.hDC, bounds.left, bounds.top, bounds.right, bounds.bottom, 9, 9);
        _ = c.SelectObject(draw_item.hDC, old_pen);
        _ = c.SelectObject(draw_item.hDC, old_brush);
    }
    if (pen != null) _ = c.DeleteObject(pen);
    if (brush != null) _ = c.DeleteObject(brush);
    const chip = c.RECT{
        .left = bounds.left + scaled(state, 14),
        .top = bounds.top + scaled(state, 15),
        .right = bounds.left + scaled(state, 23),
        .bottom = bounds.top + scaled(state, 24),
    };
    const chip_brush = c.CreateSolidBrush(choice.accent);
    if (chip_brush != null) {
        _ = c.FillRect(draw_item.hDC, &chip, chip_brush);
        _ = c.DeleteObject(chip_brush);
    }
    formDrawText(draw_item.hDC, choice.label, .{
        .left = bounds.left + scaled(state, 32),
        .top = bounds.top + scaled(state, 9),
        .right = bounds.right - scaled(state, 12),
        .bottom = bounds.top + scaled(state, 32),
    }, 14, Tokens.dialog_title_text, true);
    formDrawText(draw_item.hDC, choice.description, .{
        .left = bounds.left + scaled(state, 14),
        .top = bounds.top + scaled(state, 38),
        .right = bounds.right - scaled(state, 12),
        .bottom = bounds.bottom - scaled(state, 9),
    }, 12, Tokens.dialog_muted_text, false);
    if ((draw_item.itemState & c.ODS_FOCUS) != 0) _ = c.DrawFocusRect(draw_item.hDC, &bounds);
}

fn formDrawText(hdc: c.HDC, text: []const u8, bounds_value: c.RECT, size: i32, color: u32, bold: bool) void {
    const wide = std.unicode.utf8ToUtf16LeAlloc(std.heap.c_allocator, text) catch return;
    defer std.heap.c_allocator.free(wide);
    const old_font = AppFont.selectForDpi(hdc, size, bold);
    _ = c.SetTextColor(hdc, color);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    var bounds = bounds_value;
    _ = c.DrawTextW(hdc, wide.ptr, @intCast(wide.len), &bounds, c.DT_LEFT | c.DT_WORDBREAK | c.DT_END_ELLIPSIS);
    _ = c.SelectObject(hdc, old_font);
}

fn configureFields(state: *DialogState) void {
    state.field_count = switch (state.kind) {
        .node => 15,
        .edge => 10,
        .update => 9,
        .settings => 2,
        .jump, .template_picker => 1,
        .worktree_policy => 0,
        .worktree_sweep => state.field_count,
    };
    for (0..state.field_count) |index| state.visible[index] = true;
    switch (state.kind) {
        .node => {
            state.input_kinds[1] = .tiles;
            state.choice_groups[1] = .loop_type;
            state.input_kinds[5] = .checkbox;
            state.input_kinds[11] = .combo;
            state.choice_groups[11] = .metric_direction;
            state.input_kinds[12] = .combo;
            state.choice_groups[12] = .backend;
            state.input_kinds[13] = .combo;
            state.choice_groups[13] = .model_tier;
            state.input_kinds[14] = .combo;
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
        .template_picker => {
            state.input_kinds[0] = .combo;
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
        "Agent",                                     "Model",                                     "Branch",
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
        .template_picker => "Saved templates — type to search, then use Up/Down and Enter",
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
        14 => "This folder creates no worktree binding. Existing branches are shown only after Worktrees has inspected this project.",
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
    // `hwnd` is already a `c.HWND`; the previous `@ptrFromInt(@intFromPtr(...))`
    // round-trip only re-derived the same value, but it reintroduced a
    // pointer-alignment safety check against a value that is a Win32 *handle*,
    // not a real aligned pointer. Window handles are opaque, arbitrarily
    // valued tokens, so whenever the window manager happened to hand out an
    // unaligned handle the round-trip aborted the process with
    // "panic: incorrect alignment" while the form was laying out. Use the
    // parameter directly so no alignment assumption is made about a handle.
    const safe_hwnd: c.HWND = hwnd;
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
                if (value.kind == .node) createAttachmentsSection(safe_hwnd, value);
                if (showsRecap(value.kind)) {
                    const recap = recapText(value);
                    defer if (recap.len != 0) value.allocator.free(recap);
                    createStatic(safe_hwnd, value, recap, 18, 0, 530, 34, &value.recap);
                }
                createStatic(safe_hwnd, value, "", 18, 0, 320, 34, &value.validation);
                layoutForm(safe_hwnd, value);
            }
            var client: c.RECT = undefined;
            _ = c.GetClientRect(safe_hwnd, &client);
            createButton(safe_hwnd, value, if (value.kind == .node) "Create" else if (value.kind == .worktree_policy) "Done" else if (value.kind == .worktree_sweep) "Remove Selected" else "OK", ok_id, 0, 0);
            if (value.kind == .node and value.templates_available)
                createButton(safe_hwnd, value, "Templates", templates_id, 0, 0);
            if (value.kind == .worktree_sweep) createButton(safe_hwnd, value, "Show in Explorer", reveal_id, 0, 0);
            createButton(safe_hwnd, value, "Cancel", cancel_id, 0, 0);
            layoutFooter(safe_hwnd, value);
            return 0;
        },
        c.WM_ERASEBKGND => {
            const hdc = deviceContextFrom(wparam);
            var client: c.RECT = undefined;
            _ = c.GetClientRect(safe_hwnd, &client);
            fillFormBackground(hdc, client);
            return 1;
        },
        c.WM_CTLCOLORSTATIC => return formCtlColorStatic(controlHandleFrom(lparam), wparam, value.validation),
        c.WM_CTLCOLOREDIT => return formCtlColorEdit(wparam),
        c.WM_CTLCOLORLISTBOX => return formCtlColorEdit(wparam),
        c.WM_DRAWITEM => {
            const draw_item = drawItemFrom(lparam);
            if (value.tile_field_index != null and draw_item.CtlID >= tile_base_id and draw_item.CtlID < tile_base_id + max_tiles) {
                drawTile(value, draw_item.CtlID - tile_base_id, draw_item);
                return 1;
            }
            return 0;
        },
        c.WM_SIZE => {
            layoutFooter(safe_hwnd, value);
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
                c.SB_LINEUP => -scaled(value, 48),
                c.SB_LINEDOWN => scaled(value, 48),
                c.SB_PAGEUP => -@as(i32, @intCast(@max(scaled(value, 48), formViewportHeight(safe_hwnd, value) - scaled(value, 12)))),
                c.SB_PAGEDOWN => @as(i32, @intCast(@max(scaled(value, 48), formViewportHeight(safe_hwnd, value) - scaled(value, 12)))),
                c.SB_TOP => -100000,
                c.SB_BOTTOM => 100000,
                else => 0,
            };
            scrollFields(safe_hwnd, value, delta);
            return 0;
        },
        c.WM_MOUSEWHEEL => {
            const wheel_delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
            scrollFields(safe_hwnd, value, if (wheel_delta > 0) -scaled(value, 48) else scaled(value, 48));
            return 0;
        },
        c.WM_COMMAND => {
            const command = @as(u16, @truncate(wparam));
            const notification: u16 = @truncate(wparam >> 16);
            if (notification == c.BN_CLICKED and command >= tile_base_id and command < tile_base_id + max_tiles) {
                selectTile(value, command - tile_base_id);
                layoutForm(safe_hwnd, value);
                return 0;
            }
            if ((notification == c.EN_SETFOCUS or notification == c.CBN_SETFOCUS or notification == c.BN_SETFOCUS) and command >= 9100 and command < 9120) {
                ensureControlVisible(safe_hwnd, value, command - 9100);
                return 0;
            }
            if (notification == c.CBN_SELCHANGE and command >= 9100 and command < 9120) {
                readValue(value, command - 9100);
                updateConditionalVisibility(value);
                setStaticText(value, value.validation, "");
                refreshRecap(value);
                layoutForm(safe_hwnd, value);
                return 0;
            }
            if ((notification == c.EN_CHANGE or notification == c.BN_CLICKED) and command >= 9100 and command < 9120) {
                readValue(value, command - 9100);
                setStaticText(value, value.validation, "");
                refreshRecap(value);
            }
            if (value.kind == .worktree_policy and
                (notification == c.EN_CHANGE or notification == c.BN_CLICKED) and
                command >= 9100 and command < 9200)
            {
                readPolicy(value);
                persistPolicy(value);
            }
            if (command == ok_id) {
                readValues(value);
                readPolicy(value);
                if (value.kind == .worktree_sweep and hasDestructiveSelection(value) and !value.confirmation_armed) {
                    value.confirmation_armed = true;
                    setStaticText(value, value.validation, "Selected rows contain uncommitted files. Press Remove Selected again to remove anyway.");
                    return 0;
                }
                if (validationReason(value)) |reason| {
                    setStaticText(value, value.validation, reason);
                } else {
                    applyModalCommand(value, .submit);
                }
                return 0;
            }
            if (command == reveal_id and value.kind == .worktree_sweep) {
                for (0..value.field_count) |index| {
                    if (!std.mem.eql(u8, value.values[index], "true")) continue;
                    const parameters = WorktreeStatus.explorerParameters(value.allocator, value.sweep_paths[index]) catch break;
                    defer value.allocator.free(parameters);
                    const wide = utf8ToWideZ(value.allocator, parameters) catch break;
                    defer value.allocator.free(wide);
                    _ = c.ShellExecuteW(safe_hwnd, std.unicode.utf8ToUtf16LeStringLiteral("open").ptr, std.unicode.utf8ToUtf16LeStringLiteral("explorer.exe").ptr, wide.ptr, null, c.SW_SHOWNORMAL);
                    break;
                }
                return 0;
            }
            if (command == templates_id and value.kind == .node and value.templates_available) {
                readValues(value);
                value.template_requested = true;
                applyModalCommand(value, .cancel);
                return 0;
            }
            if (command == cancel_id) {
                applyModalCommand(value, .cancel);
                return 0;
            }
            if (value.kind == .node and command == attachment_attach_id and notification == c.BN_CLICKED) {
                attachFiles(safe_hwnd, value);
                layoutForm(safe_hwnd, value);
                return 0;
            }
            if (value.kind == .node and command == attachment_remove_id and notification == c.BN_CLICKED) {
                removeSelectedAttachment(value);
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
    output.* = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr, wide.ptr, c.WS_CHILD | c.WS_VISIBLE | c.SS_LEFT, scaled(state, x), scaled(state, y), scaled(state, width), scaled(state, height), hwnd, null, c.GetModuleHandleW(null), null);
    AppFont.apply(output.*, AppFont.control_size, false);
}

fn isEndpointCombo(state: *const DialogState, index: usize) bool {
    return state.kind == .edge and !state.lock_edge_endpoints and index < 2;
}

fn isNodeWorktreeCombo(state: *const DialogState, index: usize) bool {
    return state.kind == .node and index == 14;
}

fn worktreeSelectionText(
    allocator: std.mem.Allocator,
    choices_value: []const WorktreeChoice,
    initial_path: []const u8,
) ![]u8 {
    for (choices_value, 0..) |choice, index| {
        if (std.mem.eql(u8, choice.path, initial_path)) return std.fmt.allocPrint(allocator, "{d}", .{index + 1});
    }
    return allocator.dupe(u8, "0");
}

fn selectedWorktreeChoice(state: *const DialogState) ?WorktreeChoice {
    const selection = std.fmt.parseUnsigned(usize, state.values[14], 10) catch return null;
    if (selection == 0 or selection > state.node_worktree_choices.len) return null;
    return state.node_worktree_choices[selection - 1];
}

fn createNodeWorktreeChoices(hwnd: c.HWND, state: *DialogState, input: c.HWND) void {
    _ = hwnd;
    const local = utf8ToWideZ(state.allocator, "This folder") catch return;
    defer state.allocator.free(local);
    _ = c.SendMessageW(input, c.CB_ADDSTRING, 0, @intCast(@intFromPtr(local.ptr)));
    for (state.node_worktree_choices) |choice| {
        const suffix: []const u8 = if (choice.is_default) " (default)" else "";
        const label = std.fmt.allocPrint(state.allocator, "{s}{s}", .{ choice.branch, suffix }) catch continue;
        defer state.allocator.free(label);
        const wide = utf8ToWideZ(state.allocator, label) catch continue;
        defer state.allocator.free(wide);
        _ = c.SendMessageW(input, c.CB_ADDSTRING, 0, @intCast(@intFromPtr(wide.ptr)));
    }
    const selection = std.fmt.parseUnsigned(usize, state.values[14], 10) catch 0;
    _ = c.SendMessageW(input, c.CB_SETCURSEL, selection, 0);
}

fn endpointIndex(endpoints: []const EdgeEndpoint, value: []const u8) usize {
    for (endpoints, 0..) |endpoint, index| {
        if (std.mem.eql(u8, endpoint.id, value)) return index;
    }
    return 0;
}

fn inputControlHeight(state: *const DialogState, kind: InputKind) i32 {
    return scaled(state, if (kind == .combo) 220 else form_input_height);
}

// Attachments: unlike every other node field, this one is a variable-length list the
// user builds up by repeatedly invoking a native file picker, not a single scalar bound
// to `state.values[index]` — so it is laid out as its own section appended after the
// generic field loop (`layoutForm`/`contentHeight`) rather than folded into the
// fixed-index field system `createField`/`InputKind` drive everything else through.
// This keeps every existing field index (and the worktree/subgraph/createdBy
// pass-through slots at 14-19) completely untouched.
const attachment_listbox_id = 6;

fn attachmentsVisible(state: *const DialogState) bool {
    return state.kind == .node and !std.mem.eql(u8, state.values[1], "proactive");
}

/// Which node field a `[image #N]` placeholder is inserted into/removed from — the
/// one free-text field actually shown for the loop type currently selected. Composite
/// ("proactive") loops have no such field, matching macOS hiding attachments entirely
/// for that loop type.
fn briefFieldIndex(state: *const DialogState) ?usize {
    if (std.mem.eql(u8, state.values[1], "turnBased")) return 4;
    if (std.mem.eql(u8, state.values[1], "timeBased")) return 3;
    if (std.mem.eql(u8, state.values[1], "goalBased")) return 6;
    return null;
}

fn createAttachmentsSection(hwnd: c.HWND, state: *DialogState) void {
    createStatic(hwnd, state, "Attachments", 18, 0, 530, 18, &state.attachment_label);
    state.attachment_listbox = c.CreateWindowExW(
        c.WS_EX_CLIENTEDGE,
        std.unicode.utf8ToUtf16LeStringLiteral("LISTBOX").ptr,
        null,
        @as(c.DWORD, @intCast(c.WS_CHILD)) | @as(c.DWORD, @intCast(c.WS_VISIBLE)) |
            @as(c.DWORD, @intCast(c.WS_TABSTOP)) | @as(c.DWORD, @intCast(c.WS_VSCROLL)) |
            @as(c.DWORD, @intCast(c.LBS_NOTIFY)),
        scaled(state, 18),
        0,
        scaled(state, 392),
        scaled(state, 84),
        hwnd,
        childId(attachment_listbox_id),
        c.GetModuleHandleW(null),
        null,
    );
    AppFont.apply(state.attachment_listbox, AppFont.control_size, false);
    state.attachment_attach_button = createButtonLabelled(hwnd, state, "Attach…", attachment_attach_id, 422, 0, 126, 32);
    state.attachment_remove_button = createButtonLabelled(hwnd, state, "Remove", attachment_remove_id, 422, 38, 126, 32);
    createStatic(
        hwnd,
        state,
        "Up to 8 files, 10 MB each. Copied into node storage when you press Create.",
        18,
        0,
        530,
        18,
        &state.attachment_help,
    );
}

fn createButtonLabelled(hwnd: c.HWND, state: *const DialogState, text: []const u8, id: usize, x: i32, y: i32, width: i32, height: i32) c.HWND {
    const wide = utf8ToWideZ(std.heap.c_allocator, text) catch return null;
    defer std.heap.c_allocator.free(wide);
    const button = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON").ptr,
        wide.ptr,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP,
        scaled(state, x),
        scaled(state, y),
        scaled(state, width),
        scaled(state, height),
        hwnd,
        childId(id),
        c.GetModuleHandleW(null),
        null,
    );
    AppFont.apply(button, AppFont.control_size, false);
    return button;
}

fn layoutAttachmentsSection(hwnd: c.HWND, state: *DialogState, top: i32) void {
    const shown = attachmentsVisible(state);
    const command = if (shown) c.SW_SHOW else c.SW_HIDE;
    for ([_]c.HWND{ state.attachment_label, state.attachment_listbox, state.attachment_attach_button, state.attachment_remove_button, state.attachment_help }) |control|
        _ = c.ShowWindow(control, command);
    if (!shown) return;
    const margin = scaled(state, form_margin);
    const width = formContentWidth(hwnd, state);
    const button_width = scaled(state, 132);
    const gap = scaled(state, 12);
    const list_width = width - button_width - gap;
    _ = c.MoveWindow(state.attachment_label, margin, top, width, scaled(state, form_label_height), 1);
    _ = c.MoveWindow(state.attachment_listbox, margin, top + scaled(state, 26), list_width, scaled(state, 106), 1);
    _ = c.MoveWindow(state.attachment_attach_button, margin + list_width + gap, top + scaled(state, 26), button_width, scaled(state, 32), 1);
    _ = c.MoveWindow(state.attachment_remove_button, margin + list_width + gap, top + scaled(state, 66), button_width, scaled(state, 32), 1);
    _ = c.MoveWindow(state.attachment_help, margin, top + scaled(state, 140), width, scaled(state, form_help_height), 1);
}

fn refreshAttachmentListbox(state: *DialogState) void {
    if (state.attachment_listbox == null) return;
    _ = c.SendMessageW(state.attachment_listbox, c.LB_RESETCONTENT, 0, 0);
    for (0..state.attachment_count) |index| {
        const size = fileSizeBytes(state.attachment_paths[index]);
        const size_text = WorktreeStatus.sizeText(state.allocator, size) catch continue;
        defer state.allocator.free(size_text);
        const line = std.fmt.allocPrint(state.allocator, "{s} ({s})", .{ state.attachment_names[index], size_text }) catch continue;
        defer state.allocator.free(line);
        const wide = utf8ToWideZ(state.allocator, line) catch continue;
        defer state.allocator.free(wide);
        _ = c.SendMessageW(state.attachment_listbox, c.LB_ADDSTRING, 0, @intCast(@intFromPtr(wide.ptr)));
    }
}

fn fileSizeBytes(path: []const u8) u64 {
    const file = std.fs.cwd().openFile(path, .{}) catch return 0;
    defer file.close();
    const stat = file.stat() catch return 0;
    return stat.size;
}

fn ensureAttachmentsDirectory(state: *DialogState) ![]const u8 {
    if (state.attachment_dir.len == 0) {
        const support = try DraftAttachments.supportDirectory(state.allocator);
        defer state.allocator.free(support);
        state.attachment_dir = try DraftAttachments.attachmentsDirectory(
            state.allocator,
            support,
            state.attachment_project_path,
            state.attachment_draft_id,
        );
    }
    return state.attachment_dir;
}

fn attachmentErrorReason(err: DraftAttachments.IngestError) []const u8 {
    return switch (err) {
        error.UnsupportedFileType => "That file type isn't supported for attachments.",
        error.FileTooLarge => "That file is larger than the 10 MB attachment limit.",
        error.EmptyFile => "That file is empty.",
        error.SourceUnreadable => "That file couldn't be read.",
        error.DestinationUnwritable => "Unable to save the attachment.",
        error.TooManyAttachments => "Up to 8 attachments per node.",
        error.OutOfMemory => "Out of memory while attaching the file.",
    };
}

fn insertAttachmentToken(state: *DialogState, number: usize) void {
    const index = briefFieldIndex(state) orelse return;
    if (state.edits[index] == null) return;
    const placeholder = DraftAttachments.token(state.allocator, number) catch return;
    defer state.allocator.free(placeholder);
    var buffer: [8192]u16 = undefined;
    const length = c.GetWindowTextW(state.edits[index], &buffer, @intCast(buffer.len));
    const current = std.unicode.utf16LeToUtf8Alloc(state.allocator, buffer[0..@intCast(length)]) catch return;
    defer state.allocator.free(current);
    const trimmed = std.mem.trim(u8, current, " \t\r\n");
    const next = if (trimmed.len == 0)
        state.allocator.dupe(u8, placeholder) catch return
    else
        std.fmt.allocPrint(state.allocator, "{s} {s}", .{ trimmed, placeholder }) catch return;
    defer state.allocator.free(next);
    const wide = utf8ToWideZ(state.allocator, next) catch return;
    defer state.allocator.free(wide);
    _ = c.SetWindowTextW(state.edits[index], wide.ptr);
}

fn removeAttachmentToken(state: *DialogState, number: usize) void {
    const index = briefFieldIndex(state) orelse return;
    if (state.edits[index] == null) return;
    var buffer: [8192]u16 = undefined;
    const length = c.GetWindowTextW(state.edits[index], &buffer, @intCast(buffer.len));
    const current = std.unicode.utf16LeToUtf8Alloc(state.allocator, buffer[0..@intCast(length)]) catch return;
    defer state.allocator.free(current);
    const updated = DraftAttachments.removing(state.allocator, current, number, state.attachment_count) catch return;
    defer state.allocator.free(updated);
    const wide = utf8ToWideZ(state.allocator, updated) catch return;
    defer state.allocator.free(wide);
    _ = c.SetWindowTextW(state.edits[index], wide.ptr);
}

/// Runs the native multi-select picker, then ingests every path it returned in order —
/// each success adds one `attachment-<n>.<ext>` file plus a `[image #n]` token in the
/// brief field; each failure surfaces its reason in the validation line without
/// aborting the rest of the batch.
fn attachFiles(hwnd: c.HWND, state: *DialogState) void {
    if (state.attachment_count >= DraftAttachments.max_attachments) {
        setStaticText(state, state.validation, "Up to 8 attachments per node.");
        return;
    }
    const remaining = DraftAttachments.max_attachments - state.attachment_count;
    const stride: usize = 260;
    const buffer = state.allocator.alloc(u16, remaining * stride) catch return;
    defer state.allocator.free(buffer);
    @memset(buffer, 0);
    const picked = graphcode_pick_files(hwnd, buffer.ptr, @intCast(stride), @intCast(remaining));
    if (picked <= 0) return;
    const dir = ensureAttachmentsDirectory(state) catch {
        setStaticText(state, state.validation, "Unable to prepare attachment storage.");
        return;
    };
    var added = false;
    var index: usize = 0;
    while (index < @as(usize, @intCast(picked)) and state.attachment_count < DraftAttachments.max_attachments) : (index += 1) {
        const slot = buffer[index * stride .. index * stride + stride];
        const length = std.mem.indexOfScalar(u16, slot, 0) orelse slot.len;
        const path_utf8 = std.unicode.utf16LeToUtf8Alloc(state.allocator, slot[0..length]) catch continue;
        defer state.allocator.free(path_utf8);
        const number = state.attachment_count + 1;
        const dest_path = DraftAttachments.ingest(state.allocator, path_utf8, dir, number) catch |err| {
            setStaticText(state, state.validation, attachmentErrorReason(err));
            continue;
        };
        var id_buffer: [36]u8 = undefined;
        Forms.generateDraftId(&id_buffer);
        const id = state.allocator.dupe(u8, &id_buffer) catch {
            state.allocator.free(dest_path);
            continue;
        };
        const name = state.allocator.dupe(u8, std.fs.path.basename(path_utf8)) catch {
            state.allocator.free(dest_path);
            state.allocator.free(id);
            continue;
        };
        state.attachment_paths[state.attachment_count] = dest_path;
        state.attachment_ids[state.attachment_count] = id;
        state.attachment_names[state.attachment_count] = name;
        state.attachment_count += 1;
        added = true;
        insertAttachmentToken(state, number);
    }
    if (added) refreshAttachmentListbox(state);
}

fn removeSelectedAttachment(state: *DialogState) void {
    if (state.attachment_listbox == null) return;
    const selected = c.SendMessageW(state.attachment_listbox, c.LB_GETCURSEL, 0, 0);
    if (selected < 0) return;
    const index: usize = @intCast(selected);
    if (index >= state.attachment_count) return;
    removeAttachmentToken(state, index + 1);
    state.allocator.free(state.attachment_names[index]);
    state.allocator.free(state.attachment_paths[index]);
    state.allocator.free(state.attachment_ids[index]);
    var i = index;
    while (i + 1 < state.attachment_count) : (i += 1) {
        state.attachment_names[i] = state.attachment_names[i + 1];
        state.attachment_paths[i] = state.attachment_paths[i + 1];
        state.attachment_ids[i] = state.attachment_ids[i + 1];
    }
    state.attachment_count -= 1;
    refreshAttachmentListbox(state);
}

/// Teaching tiles: one owner-drawn, tab-stop BUTTON per loop-type choice,
/// painted in `drawTile` as a color-accented card with title + description —
/// the same "explain itself" grid LoopTypeChooser.swift uses on macOS,
/// replacing the plain drop-down this field used to be.
fn createTileButtons(hwnd: c.HWND, state: *DialogState, index: usize) c.HWND {
    state.tile_field_index = index;
    const options = choices(state.choice_groups[index]);
    state.tile_count = @min(options.len, max_tiles);
    var first: c.HWND = null;
    for (0..state.tile_count) |i| {
        const wide = utf8ToWideZ(state.allocator, options[i].label) catch continue;
        defer state.allocator.free(wide);
        const button = c.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("BUTTON").ptr,
            wide.ptr,
            c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | @as(c.DWORD, @intCast(c.BS_OWNERDRAW)),
            scaled(state, 18),
            0,
            scaled(state, 250),
            scaled(state, 76),
            hwnd,
            childId(tile_base_id + i),
            c.GetModuleHandleW(null),
            null,
        );
        AppFont.apply(button, AppFont.control_size, false);
        state.tile_buttons[i] = button;
        if (first == null) first = button;
    }
    return first;
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
        .tiles => createTileButtons(hwnd, state, index),
        .combo => c.CreateWindowExW(
            c.WS_EX_CLIENTEDGE,
            std.unicode.utf8ToUtf16LeStringLiteral("COMBOBOX").ptr,
            null,
            style | @as(c.DWORD, @intCast(if (state.kind == .template_picker) c.CBS_DROPDOWN else c.CBS_DROPDOWNLIST)) | @as(c.DWORD, @intCast(c.WS_VSCROLL)),
            scaled(state, 18),
            0,
            scaled(state, 530),
            scaled(state, 180),
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
                scaled(state, 18),
                0,
                scaled(state, 530),
                scaled(state, form_input_height),
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
            scaled(state, 18),
            0,
            scaled(state, 530),
            scaled(state, form_input_height),
            hwnd,
            childId(9100 + index),
            c.GetModuleHandleW(null),
            null,
        ),
    } orelse return;
    state.edits[index] = input;
    AppFont.apply(input, AppFont.control_size, false);
    AppFont.apply(state.labels[index], AppFont.control_size, true);
    switch (state.input_kinds[index]) {
        .tiles => {},
        .combo => {
            if (state.kind == .template_picker) {
                for (state.template_options) |option| {
                    const wide = utf8ToWideZ(state.allocator, option) catch continue;
                    defer state.allocator.free(wide);
                    _ = c.SendMessageW(input, c.CB_ADDSTRING, 0, @intCast(@intFromPtr(wide.ptr)));
                }
                _ = c.SendMessageW(input, c.CB_SETCURSEL, 0, 0);
            } else
            if (isEndpointCombo(state, index)) {
                for (state.edge_endpoints) |endpoint| {
                    const label = std.fmt.allocPrint(state.allocator, "{s} — {s}", .{ endpoint.title, endpoint.id }) catch continue;
                    defer state.allocator.free(label);
                    const wide = utf8ToWideZ(state.allocator, label) catch continue;
                    defer state.allocator.free(wide);
                    _ = c.SendMessageW(input, c.CB_ADDSTRING, 0, @intCast(@intFromPtr(wide.ptr)));
                }
                _ = c.SendMessageW(input, c.CB_SETCURSEL, endpointIndex(state.edge_endpoints, state.values[index]), 0);
            } else if (isNodeWorktreeCombo(state, index)) {
                createNodeWorktreeChoices(hwnd, state, input);
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
            if (state.kind == .worktree_sweep and !state.sweep_selectable[index])
                _ = c.EnableWindow(input, 0);
        },
        else => {
            const wide = utf8ToWideZ(state.allocator, state.values[index]) catch return;
            defer state.allocator.free(wide);
            _ = c.SetWindowTextW(input, wide.ptr);
        },
    }
    createStatic(hwnd, state, fieldHelp(state.kind, index), 18, 0, 530, 18, &state.helps[index]);
    AppFont.apply(state.helps[index], 12, false);
}

fn setStaticText(state: *DialogState, hwnd: c.HWND, text: []const u8) void {
    if (hwnd == null) return;
    const wide = utf8ToWideZ(state.allocator, text) catch return;
    defer state.allocator.free(wide);
    _ = c.SetWindowTextW(hwnd, wide.ptr);
}

fn rowHeight(state: *const DialogState, index: usize) i32 {
    return scaled(state, if (state.input_kinds[index] == .tiles) tile_row_height else form_row_height);
}

fn showsRecap(kind: Kind) bool {
    return kind == .node or kind == .edge or kind == .update;
}

fn recapText(state: *const DialogState) []const u8 {
    const title = switch (state.kind) {
        .node => Forms.resolvedTitle(state.values[0]),
        .edge => state.values[2],
        .update => if (hasUpdateChanges(state)) "changed fields" else "no changes yet",
        else => "",
    };
    const detail = switch (state.kind) {
        .node => state.values[1],
        .edge => state.values[3],
        .update => "review before saving",
        else => "",
    };
    return std.fmt.allocPrint(state.allocator, "Recap: {s} — {s}", .{ title, detail }) catch
        state.allocator.dupe(u8, "Recap unavailable") catch &.{};
}

fn refreshRecap(state: *DialogState) void {
    if (!showsRecap(state.kind) or state.recap == null) return;
    const recap = recapText(state);
    defer if (recap.len != 0) state.allocator.free(recap);
    setStaticText(state, state.recap, recap);
}

fn fieldTop(state: *const DialogState, target: usize) ?i32 {
    var y = scaled(state, form_fields_top);
    for (0..state.field_count) |index| {
        if (!state.visible[index]) continue;
        if (index == target) return y;
        y += rowHeight(state, index);
    }
    return null;
}

fn layoutForm(hwnd: c.HWND, state: *DialogState) void {
    var y = scaled(state, form_fields_top);
    const margin = scaled(state, form_margin);
    const width = formContentWidth(hwnd, state);
    _ = c.MoveWindow(state.intro, margin, scaled(state, 16) - state.scroll_offset, width, scaled(state, 48), 1);
    for (0..state.field_count) |index| {
        const shown = state.visible[index];
        const command = if (shown) c.SW_SHOW else c.SW_HIDE;
        _ = c.ShowWindow(state.labels[index], command);
        if (state.input_kinds[index] == .tiles) {
            for (0..state.tile_count) |t| _ = c.ShowWindow(state.tile_buttons[t], command);
        } else {
            _ = c.ShowWindow(state.edits[index], command);
        }
        _ = c.ShowWindow(state.helps[index], if (state.input_kinds[index] == .tiles) c.SW_HIDE else command);
        if (!shown) continue;
        const top = y - state.scroll_offset;
        _ = c.MoveWindow(state.labels[index], margin, top, width, scaled(state, form_label_height), 1);
        if (state.input_kinds[index] == .tiles) {
            layoutTiles(state, index, margin, top + scaled(state, 28), width);
        } else {
            _ = c.MoveWindow(state.edits[index], margin, top + scaled(state, 26), width, inputControlHeight(state, state.input_kinds[index]), 1);
            _ = c.MoveWindow(state.helps[index], margin, top + scaled(state, 62), width, scaled(state, form_help_height), 1);
        }
        y += rowHeight(state, index);
    }
    if (state.kind == .node) {
        layoutAttachmentsSection(hwnd, state, y - state.scroll_offset);
        if (attachmentsVisible(state)) y += scaled(state, attachment_section_height);
    }
    if (showsRecap(state.kind)) {
        _ = c.ShowWindow(state.recap, c.SW_SHOW);
        _ = c.MoveWindow(state.recap, margin, y - state.scroll_offset, width, scaled(state, 40), 1);
    }
    updateScrollBar(hwnd, state);
}

const tile_columns = 2;

fn layoutTiles(state: *DialogState, index: usize, x: i32, y: i32, width: i32) void {
    _ = index;
    const gap = scaled(state, 12);
    const tile_width = @divTrunc(width - gap * (tile_columns - 1), tile_columns);
    const tile_height = scaled(state, 76);
    for (0..state.tile_count) |i| {
        const col: i32 = @intCast(i % tile_columns);
        const tile_row: i32 = @intCast(i / tile_columns);
        const tx = x + col * (tile_width + gap);
        const ty = y + tile_row * (tile_height + gap);
        _ = c.MoveWindow(state.tile_buttons[i], tx, ty, tile_width, tile_height, 1);
    }
}

fn contentHeight(state: *const DialogState) i32 {
    var y = scaled(state, form_fields_top);
    for (0..state.field_count) |index| {
        if (state.visible[index]) y += rowHeight(state, index);
    }
    if (state.kind == .node and attachmentsVisible(state)) y += scaled(state, attachment_section_height);
    if (showsRecap(state.kind)) y += scaled(state, 40);
    return y + scaled(state, 16);
}

fn clientHeight(hwnd: c.HWND) i32 {
    var rect: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &rect);
    return rect.bottom;
}

fn scrollFields(hwnd: c.HWND, state: *DialogState, requested: i32) void {
    const viewport = formViewportHeight(hwnd, state);
    const content = contentHeight(state);
    const next = boundedScrollOffset(content, viewport, state.scroll_offset, requested);
    setScrollOffsetValue(hwnd, state, next);
}

fn setScrollOffset(hwnd: c.HWND, state: *DialogState, requested: i32) void {
    const viewport = formViewportHeight(hwnd, state);
    const content = contentHeight(state);
    const next = std.math.clamp(requested, 0, @max(0, content - viewport));
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
    const viewport = formViewportHeight(hwnd, state);
    const content = contentHeight(state);
    const page: u32 = @intCast(@max(1, viewport));
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
    const top = fieldTop(state, index) orelse return;
    const viewport = formViewportHeight(hwnd, state);
    const bottom = top + rowHeight(state, index) - 3;
    const visible_top = state.scroll_offset;
    const visible_bottom = state.scroll_offset + @max(1, viewport);
    if (top < visible_top) {
        scrollFields(hwnd, state, top - visible_top);
    } else if (bottom > visible_bottom) {
        scrollFields(hwnd, state, bottom - visible_bottom);
    }
}

fn boundedScrollOffset(content: i32, viewport: i32, current: i32, requested: i32) i32 {
    const max_offset = @max(0, content - @max(120, viewport));
    return std.math.clamp(current + requested, 0, max_offset);
}

fn createButton(hwnd: c.HWND, state: *const DialogState, text: []const u8, id: usize, x: i32, y: i32) void {
    const wide = utf8ToWideZ(std.heap.c_allocator, text) catch return;
    defer std.heap.c_allocator.free(wide);
    const button_style: c.DWORD = @intCast(if (id == ok_id) c.BS_DEFPUSHBUTTON else c.BS_PUSHBUTTON);
    const style: c.DWORD = @as(c.DWORD, @intCast(c.WS_CHILD)) |
        @as(c.DWORD, @intCast(c.WS_VISIBLE)) |
        @as(c.DWORD, @intCast(c.WS_TABSTOP)) |
        button_style;
    const button = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON").ptr, wide.ptr, style, scaled(state, x), scaled(state, y), scaled(state, 88), scaled(state, 34), hwnd, childId(id), c.GetModuleHandleW(null), null);
    AppFont.apply(button, AppFont.control_size, false);
}

fn layoutFooter(hwnd: c.HWND, state: *DialogState) void {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    const margin = scaled(state, form_margin);
    const button_width = scaled(state, 96);
    const button_height = scaled(state, 36);
    const gap = scaled(state, 12);
    const y = client.bottom - scaled(state, 50);
    const ok_x = client.right - margin - button_width;
    const cancel_x = ok_x - gap - button_width;
    _ = c.MoveWindow(c.GetDlgItem(hwnd, @intCast(ok_id)), ok_x, y, button_width, button_height, 1);
    _ = c.MoveWindow(c.GetDlgItem(hwnd, @intCast(cancel_id)), cancel_x, y, button_width, button_height, 1);
    if ((state.kind == .node and state.templates_available) or state.kind == .worktree_sweep) {
        const auxiliary_id: usize = if (state.kind == .worktree_sweep) reveal_id else templates_id;
        _ = c.MoveWindow(c.GetDlgItem(hwnd, @intCast(auxiliary_id)), cancel_x - gap - scaled(state, 132), y, scaled(state, 132), button_height, 1);
    }
    if (state.validation != null)
        _ = c.MoveWindow(state.validation, margin, client.bottom - scaled(state, 54), @max(scaled(state, 180), cancel_x - margin - gap), scaled(state, 42), 1);
}

fn createCheckBox(hwnd: c.HWND, state: *DialogState, text: []const u8, index: usize, y: i32) void {
    const wide = utf8ToWideZ(state.allocator, text) catch return;
    defer state.allocator.free(wide);
    const check = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON").ptr, wide.ptr, c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_AUTOCHECKBOX, scaled(state, 18), scaled(state, y), scaled(state, 380), scaled(state, form_input_height), hwnd, childId(9200 + index), c.GetModuleHandleW(null), null) orelse return;
    state.checks[index] = check;
    AppFont.apply(check, AppFont.control_size, false);
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
        scaled(state, 18),
        scaled(state, y),
        scaled(state, 530),
        scaled(state, form_input_height),
        hwnd,
        childId(9200 + index),
        c.GetModuleHandleW(null),
        null,
    ) orelse return;
    state.checks[index] = radio;
    AppFont.apply(radio, AppFont.control_size, false);
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
        scaled(state, x),
        scaled(state, y),
        scaled(state, width),
        scaled(state, form_input_height),
        hwnd,
        childId(9100 + index),
        c.GetModuleHandleW(null),
        null,
    ) orelse return;
    state.edits[index] = edit;
    AppFont.apply(edit, AppFont.control_size, false);
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
        .tiles => {},
        .combo => {
            const selected = c.SendMessageW(state.edits[index], c.CB_GETCURSEL, 0, 0);
            if (selected < 0) return;
            const selected_index: usize = @intCast(selected);
            const value: []u8 = if (state.kind == .template_picker or isNodeWorktreeCombo(state, index))
                std.fmt.allocPrint(state.allocator, "{d}", .{selected_index}) catch return
            else blk: {
                const next = if (isEndpointCombo(state, index) and selected_index < state.edge_endpoints.len)
                    state.edge_endpoints[selected_index].id
                else
                    choiceValue(state.choice_groups[index], selected_index, state.values[index]);
                break :blk state.allocator.dupe(u8, next) catch return;
            };
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

fn persistPolicy(state: *DialogState) void {
    if (state.immediate_policy_path.len == 0) return;
    const size = std.fmt.parseInt(u32, std.mem.trim(u8, state.values[0], " \t\r\n"), 10) catch return;
    const count = std.fmt.parseInt(u32, std.mem.trim(u8, state.values[1], " \t\r\n"), 10) catch return;
    if (size == 0 or count == 0) return;
    WorktreeStatus.savePolicy(state.allocator, state.immediate_policy_path, state.policy) catch {
        setStaticText(state, state.validation, "Unable to save project settings");
    };
}

fn hasDestructiveSelection(state: *const DialogState) bool {
    if (state.kind != .worktree_sweep) return false;
    for (0..state.field_count) |index| {
        if (!state.sweep_selectable[index] or !std.mem.eql(u8, state.values[index], "true")) continue;
        if (std.mem.indexOf(u8, state.display_labels[index], "local changes") != null or
            std.mem.indexOf(u8, state.display_labels[index], "untracked files") != null or
            std.mem.indexOf(u8, state.display_labels[index], "merge conflicts") != null)
            return true;
    }
    return false;
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
            const selected_worktree = selectedWorktreeChoice(state);
            const preserves_initial_worktree = state.node_worktree_choices.len == 0;
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
                .worktree_repository = if (selected_worktree != null) state.attachment_project_path else if (preserves_initial_worktree) state.values[15] else "",
                .worktree_id = if (selected_worktree) |choice| choice.branch else if (preserves_initial_worktree) state.values[16] else "",
                .worktree_path = if (selected_worktree) |choice| choice.path else if (preserves_initial_worktree) state.values[17] else "",
                .worktree_branch = if (selected_worktree) |choice| choice.branch else if (preserves_initial_worktree) state.values[18] else "",
                .subgraph_json = state.values[19],
                .created_by = state.values[20],
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

fn freeAttachmentState(state: *DialogState) void {
    for (state.attachment_names[0..state.attachment_count]) |value| state.allocator.free(value);
    for (state.attachment_paths[0..state.attachment_count]) |value| state.allocator.free(value);
    for (state.attachment_ids[0..state.attachment_count]) |value| state.allocator.free(value);
    if (state.attachment_dir.len != 0) state.allocator.free(state.attachment_dir);
}

fn utf8ToWideZ(allocator: std.mem.Allocator, value: []const u8) ![]u16 {
    const raw = try std.unicode.utf8ToUtf16LeAlloc(allocator, value);
    defer allocator.free(raw);
    const result = try allocator.alloc(u16, raw.len + 1);
    @memcpy(result[0..raw.len], raw);
    result[raw.len] = 0;
    return result;
}

// Win32 handles (HWND/HDC) and message-supplied struct addresses are opaque
// integers, not guaranteed-aligned pointers. Converting them with a plain
// `@ptrFromInt` makes Zig assert pointer alignment and abort the process with
// "panic: incorrect alignment" whenever the window manager hands back an
// unaligned value -- which crashed the node form mid-layout. Every conversion
// must therefore go through a `@setRuntimeSafety(false)` helper. These odd
// (deliberately unaligned) values reproduce the original panic if that
// guarantee regresses.
test "win32 handle conversions tolerate unaligned handle values" {
    const unaligned: usize = 0x0002_0311;
    try std.testing.expectEqual(unaligned, @intFromPtr(deviceContextFrom(unaligned)));
    try std.testing.expectEqual(
        unaligned,
        @intFromPtr(controlHandleFrom(@as(c.LPARAM, @bitCast(unaligned)))),
    );
    try std.testing.expectEqual(
        unaligned,
        @intFromPtr(drawItemFrom(@as(c.LPARAM, @bitCast(unaligned)))),
    );
    // A handle whose low bit is set is the exact shape that aborted before.
    const odd: usize = 0x000b_0b0b;
    try std.testing.expectEqual(odd, @intFromPtr(deviceContextFrom(odd)));
    try std.testing.expectEqual(
        odd,
        @intFromPtr(controlHandleFrom(@as(c.LPARAM, @bitCast(odd)))),
    );
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

test "native forms reject reentrant modal acquisition and allow sequential dialogs" {
    active_state = false;
    defer active_state = false;

    try acquireModal();
    try std.testing.expect(isModalActive());
    try std.testing.expectError(error.FormAlreadyOpen, acquireModal());

    releaseModal();
    try std.testing.expect(!isModalActive());
    try acquireModal();
    try std.testing.expect(isModalActive());
    releaseModal();
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
    var state = DialogState{ .allocator = std.testing.allocator, .kind = .node, .parent = null };
    try std.testing.expectEqual(@as(i32, 220), inputControlHeight(&state, .combo));
    try std.testing.expectEqual(@as(i32, form_input_height), inputControlHeight(&state, .checkbox));
    try std.testing.expect(attachment_attach_id != templates_id);
    try std.testing.expect(attachment_remove_id != templates_id);
    try std.testing.expect(attachment_attach_id != attachment_remove_id);
}

test "form recap describes the pending node, edge, and update" {
    var node_state = DialogState{ .allocator = std.testing.allocator, .kind = .node, .parent = null };
    node_state.values[0] = @constCast("Ship the picker");
    node_state.values[1] = @constCast("goalBased");
    const node_recap = recapText(&node_state);
    defer std.testing.allocator.free(node_recap);
    try std.testing.expect(std.mem.indexOf(u8, node_recap, "Ship the picker") != null);
    try std.testing.expect(std.mem.indexOf(u8, node_recap, "goalBased") != null);

    var edge_state = DialogState{ .allocator = std.testing.allocator, .kind = .edge, .parent = null };
    edge_state.values[2] = @constCast("handoff");
    edge_state.values[3] = @constCast("onSuccess");
    const edge_recap = recapText(&edge_state);
    defer std.testing.allocator.free(edge_recap);
    try std.testing.expect(std.mem.indexOf(u8, edge_recap, "handoff") != null);
    try std.testing.expect(std.mem.indexOf(u8, edge_recap, "onSuccess") != null);

    var update_state = DialogState{ .allocator = std.testing.allocator, .kind = .update, .parent = null };
    update_state.field_count = 9;
    update_state.values[0] = @constCast("changed goal");
    update_state.initial_values[0] = @constCast("");
    const update_recap = recapText(&update_state);
    defer std.testing.allocator.free(update_recap);
    try std.testing.expect(std.mem.indexOf(u8, update_recap, "changed fields") != null);
}

test "node worktree picker has an honest empty state and binds only real choices" {
    const empty = try worktreeSelectionText(std.testing.allocator, &.{}, "");
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("0", empty);

    const choices_value = [_]WorktreeChoice{
        .{ .path = "C:\\repo\\worktrees\\main", .branch = "main", .is_default = true },
        .{ .path = "C:\\repo\\worktrees\\fix", .branch = "fix/picker", .is_default = false },
    };
    const selected = try worktreeSelectionText(std.testing.allocator, &choices_value, choices_value[1].path);
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqualStrings("2", selected);

    var state = DialogState{ .allocator = std.testing.allocator, .kind = .node, .parent = null };
    state.node_worktree_choices = &choices_value;
    state.values[14] = @constCast("2");
    const selected_choice = selectedWorktreeChoice(&state).?;
    try std.testing.expectEqualStrings("fix/picker", selected_choice.branch);
    state.values[14] = @constCast("0");
    try std.testing.expect(selectedWorktreeChoice(&state) == null);
}

test "node draft builder preserves every hidden initial field" {
    var state = DialogState{ .allocator = std.testing.allocator, .kind = .node, .parent = null };
    state.values[1] = @constCast("turnBased");
    state.values[4] = @constCast("Start here");
    state.values[5] = @constCast("false");
    state.values[8] = @constCast("60");
    state.values[11] = @constCast("maximize");
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
    var draft = try buildNodeDraft(std.testing.allocator, &state, initial);
    defer draft.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(initial.worktree_repository, draft.worktree_repository);
    try std.testing.expectEqualStrings(initial.worktree_id, draft.worktree_id);
    try std.testing.expectEqualStrings(initial.worktree_path, draft.worktree_path);
    try std.testing.expectEqualStrings(initial.worktree_branch, draft.worktree_branch);
    try std.testing.expectEqualStrings(initial.created_by, draft.created_by);
    try std.testing.expectEqualStrings(initial.claude_permissions, draft.claude_permissions);
    try std.testing.expectEqual(initial.briefing_enabled, draft.briefing_enabled);
    try std.testing.expectEqual(initial.activity_enabled, draft.activity_enabled);
    try std.testing.expectEqual(@as(usize, 0), draft.attachment_count);
    try std.testing.expectEqual(@as(usize, 0), draft.node_id.len);

    var hidden_state = state;
    hidden_state.values[8] = @constCast("not-a-number");
    hidden_state.values[9] = @constCast("also-invalid");
    var hidden_draft = try buildNodeDraft(std.testing.allocator, &hidden_state, initial);
    defer hidden_draft.deinit(std.testing.allocator);
    try std.testing.expectEqual(initial.poll_interval_seconds, hidden_draft.poll_interval_seconds);
    try std.testing.expectEqual(initial.stall_after_seconds, hidden_draft.stall_after_seconds);
}

test "node draft builder carries staged attachments and the draft id onto the wire draft" {
    var state = DialogState{ .allocator = std.testing.allocator, .kind = .node, .parent = null };
    state.values[1] = @constCast("turnBased");
    state.values[4] = @constCast("look at [image #1]");
    state.values[5] = @constCast("false");
    state.values[8] = @constCast("60");
    state.values[11] = @constCast("maximize");
    state.attachment_draft_id = "11111111-1111-4111-8111-111111111111";
    state.attachment_count = 1;
    state.attachment_paths[0] = @constCast("C:\\Users\\me\\.graphcode\\memory\\slug\\11111111-1111-4111-8111-111111111111\\attachments\\attachment-1.png");
    state.attachment_ids[0] = @constCast("aaaaaaaa-1111-4111-8111-111111111111");
    var draft = try buildNodeDraft(std.testing.allocator, &state, .{ .title = "before" });
    defer draft.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("11111111-1111-4111-8111-111111111111", draft.node_id);
    try std.testing.expectEqual(@as(usize, 1), draft.attachment_count);
    try std.testing.expectEqualStrings(state.attachment_paths[0], draft.attachment_paths[0]);
    try std.testing.expectEqualStrings(state.attachment_ids[0], draft.attachment_ids[0]);
}

test "template handoff retains staged attachments in the unchecked draft" {
    var state = DialogState{ .allocator = std.testing.allocator, .kind = .node, .parent = null };
    state.values[1] = @constCast("turnBased");
    state.values[4] = @constCast("review [image #1]");
    state.values[5] = @constCast("false");
    state.values[8] = @constCast("60");
    state.values[11] = @constCast("maximize");
    state.attachment_draft_id = "11111111-1111-4111-8111-111111111111";
    state.attachment_count = 1;
    state.attachment_paths[0] = @constCast("C:\\memory\\project\\11111111-1111-4111-8111-111111111111\\attachments\\attachment-1.png");
    state.attachment_ids[0] = @constCast("aaaaaaaa-1111-4111-8111-111111111111");

    // The Templates action returns this unchecked draft to App, which applies the
    // selected template and reopens the form before the checked Create result.
    var handoff = try buildNodeDraftUnchecked(std.testing.allocator, &state, .{ .title = "before" });
    defer handoff.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(state.attachment_draft_id, handoff.node_id);
    try std.testing.expectEqual(@as(usize, 1), handoff.attachment_count);
    try std.testing.expectEqualStrings(state.attachment_paths[0], handoff.attachment_paths[0]);
    try std.testing.expectEqualStrings(state.attachment_ids[0], handoff.attachment_ids[0]);

    var reopened = DialogState{ .allocator = std.testing.allocator, .kind = .node, .parent = null };
    reopened.attachment_project_path = "C:\\project";
    reopened.attachment_draft_id = handoff.node_id;
    defer freeAttachmentState(&reopened);
    try restoreStagedAttachments(&reopened, handoff);
    try std.testing.expectEqual(@as(usize, 1), reopened.attachment_count);
    try std.testing.expectEqualStrings(handoff.attachment_paths[0], reopened.attachment_paths[0]);
    try std.testing.expectEqualStrings(handoff.attachment_ids[0], reopened.attachment_ids[0]);
}

test "attachments are hidden for composite loops and mapped to the shown brief field" {
    var state = DialogState{ .allocator = undefined, .kind = .node, .parent = null };
    state.values[1] = @constCast("turnBased");
    try std.testing.expect(attachmentsVisible(&state));
    try std.testing.expectEqual(@as(?usize, 4), briefFieldIndex(&state));

    state.values[1] = @constCast("timeBased");
    try std.testing.expectEqual(@as(?usize, 3), briefFieldIndex(&state));

    state.values[1] = @constCast("goalBased");
    try std.testing.expectEqual(@as(?usize, 6), briefFieldIndex(&state));

    state.values[1] = @constCast("proactive");
    try std.testing.expect(!attachmentsVisible(&state));
    try std.testing.expectEqual(@as(?usize, null), briefFieldIndex(&state));
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
    var edge_draft = try buildEdgeDraft(std.testing.allocator, &edge_state.values);
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

test "node update uses its owned baseline after the source graph changes" {
    var summary = "Original goal".*;
    const initial = Forms.NodeUpdate{ .goal_summary = &summary, .poll_interval_seconds = 30 };
    var state = DialogState{ .allocator = std.testing.allocator, .kind = .update, .parent = null };
    defer freeValues(&state);
    try initializeNodeUpdate(&state, initial);
    @memset(&summary, 'x');
    state.allocator.free(state.values[2]);
    state.values[2] = try state.allocator.dupe(u8, "45");
    applyModalCommand(&state, .submit);
    var result = (try buildNodeUpdate(&state, initial)).?;
    defer result.deinit(state.allocator);
    try std.testing.expect(result.goal_summary == null);
    try std.testing.expectEqual(@as(?f64, 45), result.poll_interval_seconds);
}

test "node update preserves unchanged values and clear semantics" {
    const initial = Forms.NodeUpdate{
        .goal_summary = "Goal",
        .goal_predicate = "test",
        .poll_interval_seconds = 30,
        .stall_after_seconds = 120,
        .metric_command = "coverage",
        .metric_direction = "maximize",
        .trigger_prompt = "Trigger",
        .check_description = "Check",
        .model_tier = "capable",
    };
    var state = DialogState{ .allocator = std.testing.allocator, .kind = .update, .parent = null };
    defer freeValues(&state);
    try initializeNodeUpdate(&state, initial);
    applyModalCommand(&state, .submit);
    try std.testing.expectError(error.InvalidNodeUpdate, buildNodeUpdate(&state, initial));
    for (0..9) |index| {
        state.allocator.free(state.values[index]);
        state.values[index] = &.{};
    }
    var result = (try buildNodeUpdate(&state, initial)).?;
    defer result.deinit(state.allocator);
    try std.testing.expect(result.goal_summary == null);
    try std.testing.expectEqualStrings("", result.goal_predicate.?);
    try std.testing.expect(result.poll_interval_seconds == null);
    try std.testing.expectEqual(@as(?f64, 0), result.stall_after_seconds);
    try std.testing.expectEqualStrings("", result.metric_command.?);
    try std.testing.expect(result.metric_direction == null);
    try std.testing.expectEqualStrings("", result.trigger_prompt.?);
    try std.testing.expectEqualStrings("", result.check_description.?);
    try std.testing.expect(result.model_tier == null);
}

test "node update binds every changed field to the typed result" {
    var state = DialogState{ .allocator = std.testing.allocator, .kind = .update, .parent = null };
    defer freeValues(&state);
    const initial = Forms.NodeUpdate{};
    try initializeNodeUpdate(&state, initial);
    const values = [_][]const u8{
        "New goal", "new-test", "45.5", "90.25", "new-metric", "minimize", "New trigger", "New check", "standard",
    };
    for (values, 0..) |value, index| {
        const owned = try state.allocator.dupe(u8, value);
        state.allocator.free(state.values[index]);
        state.values[index] = owned;
    }
    applyModalCommand(&state, .submit);
    var result = (try buildNodeUpdate(&state, initial)).?;
    defer result.deinit(state.allocator);
    try std.testing.expectEqualStrings(values[0], result.goal_summary.?);
    try std.testing.expectEqualStrings(values[1], result.goal_predicate.?);
    try std.testing.expectEqual(@as(?f64, 45.5), result.poll_interval_seconds);
    try std.testing.expectEqual(@as(?f64, 90.25), result.stall_after_seconds);
    try std.testing.expectEqualStrings(values[4], result.metric_command.?);
    try std.testing.expectEqualStrings(values[5], result.metric_direction.?);
    try std.testing.expectEqualStrings(values[6], result.trigger_prompt.?);
    try std.testing.expectEqualStrings(values[7], result.check_description.?);
    try std.testing.expectEqualStrings(values[8], result.model_tier.?);
}

test "node update cancellation and close return no result" {
    for ([_]ModalCommand{ .cancel, .close }) |command| {
        var state = DialogState{ .allocator = std.testing.allocator, .kind = .update, .parent = null };
        defer freeValues(&state);
        const initial = Forms.NodeUpdate{ .goal_summary = "Goal", .poll_interval_seconds = 30 };
        try initializeNodeUpdate(&state, initial);
        const invalid = try state.allocator.dupe(u8, "not a number");
        state.allocator.free(state.values[2]);
        state.values[2] = invalid;
        applyModalCommand(&state, command);
        try std.testing.expect((try buildNodeUpdate(&state, initial)) == null);
        try std.testing.expect(state.closed);
        try std.testing.expectEqualStrings("Goal", state.initial_values[0]);
    }
}

test "node update initialization and result release every partial allocation" {
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var state = DialogState{ .allocator = allocator, .kind = .update, .parent = null };
            defer freeValues(&state);
            const initial = Forms.NodeUpdate{ .goal_summary = "Old goal", .poll_interval_seconds = 30 };
            try initializeNodeUpdate(&state, initial);
            const values = [_][]const u8{
                "New goal", "test", "45", "90", "metric", "maximize", "trigger", "check", "fast",
            };
            for (values, 0..) |value, index| {
                const owned = try allocator.dupe(u8, value);
                allocator.free(state.values[index]);
                state.values[index] = owned;
            }
            applyModalCommand(&state, .submit);
            var result = (try buildNodeUpdate(&state, initial)).?;
            defer result.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

test "keyboard-sized guided form keeps every field reachable through bounded scrolling" {
    const content: i32 = form_fields_top + 10 * form_row_height + 16;
    const viewport: i32 = 768 - form_footer_height;
    const max_offset = boundedScrollOffset(content, viewport, 0, 100000);
    try std.testing.expectEqual(max_offset, boundedScrollOffset(content, viewport, max_offset, 48));
    try std.testing.expectEqual(@as(i32, 0), boundedScrollOffset(content, viewport, 0, -48));
    const last_top: i32 = form_fields_top + 9 * form_row_height;
    try std.testing.expect(last_top + form_row_height <= max_offset + viewport);
}

test "scrollbar thumb positions seek and clamp the dialog content" {
    const content: i32 = form_fields_top + 10 * form_row_height + 16;
    const viewport: i32 = 768 - form_footer_height;
    try std.testing.expectEqual(@as(i32, 0), std.math.clamp(@as(i32, 0), 0, content - viewport));
    const max_offset = boundedScrollOffset(content, viewport, 0, 100000);
    try std.testing.expectEqual(@min(@as(i32, 200), max_offset), std.math.clamp(@as(i32, 200), 0, max_offset));
    try std.testing.expectEqual(max_offset, std.math.clamp(@as(i32, 100000), 0, max_offset));
}

test "loop type teaching tiles carry the exact macOS accent colors" {
    // LoopTypeAppearance.swift: turnBased #D55181, timeBased #C98500,
    // goalBased #199E70, composite/proactive #9085E9. tileColor packs a
    // COLORREF (0x00BBGGRR) so these render as the true RGB on screen,
    // unlike the pre-existing R/B-swapped literals elsewhere in this codebase.
    try std.testing.expectEqual(@as(u32, 0x00_81_51_D5), loop_type_choices[0].accent);
    try std.testing.expectEqual(@as(u32, 0x00_00_85_C9), loop_type_choices[1].accent);
    try std.testing.expectEqual(@as(u32, 0x00_70_9E_19), loop_type_choices[2].accent);
    try std.testing.expectEqual(@as(u32, 0x00_E9_85_90), loop_type_choices[3].accent);
    try std.testing.expectEqualStrings("Turn-based", loop_type_choices[0].label);
    try std.testing.expect(loop_type_choices[0].description.len > 0);
    try std.testing.expect(loop_type_choices[3].description.len > 0);
}

test "tile rows reserve full teaching-tile height while other rows stay compact" {
    var state = DialogState{ .allocator = std.testing.allocator, .kind = .node, .parent = null };
    state.field_count = 3;
    state.input_kinds[0] = .edit;
    state.input_kinds[1] = .tiles;
    state.input_kinds[2] = .combo;
    state.visible[0] = true;
    state.visible[1] = true;
    state.visible[2] = true;
    try std.testing.expectEqual(@as(i32, form_row_height), rowHeight(&state, 0));
    try std.testing.expectEqual(@as(i32, tile_row_height), rowHeight(&state, 1));
    try std.testing.expectEqual(@as(i32, form_row_height), rowHeight(&state, 2));
    try std.testing.expectEqual(@as(i32, form_fields_top), fieldTop(&state, 0).?);
    try std.testing.expectEqual(@as(i32, form_fields_top + form_row_height), fieldTop(&state, 1).?);
    try std.testing.expectEqual(@as(i32, form_fields_top + form_row_height + tile_row_height), fieldTop(&state, 2).?);
    try std.testing.expectEqual(@as(i32, form_fields_top + form_row_height + tile_row_height + form_row_height + attachment_section_height + 40 + 16), contentHeight(&state));
}

test "native form layout scales design units at common Windows DPI steps" {
    var state = DialogState{ .allocator = std.testing.allocator, .kind = .node, .parent = null, .dpi = 144 };
    state.field_count = 1;
    state.visible[0] = true;
    try std.testing.expectEqual(@as(i32, 126), rowHeight(&state, 0));
    try std.testing.expectEqual(@as(i32, 114), fieldTop(&state, 0).?);
    try std.testing.expectEqual(@as(i32, 48), inputControlHeight(&state, .edit));
    state.dpi = 192;
    try std.testing.expectEqual(@as(i32, 168), rowHeight(&state, 0));
    try std.testing.expectEqual(@as(i32, 152), fieldTop(&state, 0).?);
    try std.testing.expectEqual(@as(i32, 64), inputControlHeight(&state, .edit));
}

test "blendColor tints toward the overlay color proportionally to strength" {
    try std.testing.expectEqual(@as(u32, 0x00_00_00_00), blendColor(0x00000000, 0x00FFFFFF, 0));
    try std.testing.expectEqual(@as(u32, 0x00_FF_FF_FF), blendColor(0x00000000, 0x00FFFFFF, 100));
    // A light 22% selected-state tint should stay much closer to the base
    // panel color than to the accent, matching the subtle macOS fill.
    const tinted = blendColor(Tokens.dialog_panel, tileColor(213, 81, 129), 22);
    try std.testing.expect(tinted != Tokens.dialog_panel);
    try std.testing.expect(tinted != tileColor(213, 81, 129));
}
