const std = @import("std");
const GraphModel = @import("GraphModel.zig");

pub const NodeDraft = struct {
    title: []const u8,
    loop_type: []const u8 = "turnBased",
    check_description: []const u8 = "",
    trigger_prompt: []const u8 = "",
    first_instruction: []const u8 = "Work on the requested Windows shell task.",
    pauses_before_writes_only: bool = false,
    goal_summary: []const u8 = "",
    goal_predicate: []const u8 = "",
    poll_interval_seconds: f64 = 60,
    stall_after_seconds: ?f64 = null,
    metric_command: []const u8 = "",
    metric_direction: []const u8 = "maximize",
    backend: []const u8 = "claudeCode",
    model_tier: []const u8 = "",
    worktree_repository: []const u8 = "",
    worktree_id: []const u8 = "",
    worktree_path: []const u8 = "",
    worktree_branch: []const u8 = "",
    subgraph_json: []const u8 = "",
    created_by: []const u8 = "",
};

pub const EdgeDraft = struct {
    from: []const u8,
    to: []const u8,
    kind: []const u8 = "handoff",
    condition: []const u8 = "always",
    transform_kind: []const u8 = "none",
    transform_value: []const u8 = "",
    cycle_max_iterations: ?i64 = null,
    cycle_until: []const u8 = "",
    cycle_stop_after_passes: ?i64 = null,
    spawn_target_project_path: []const u8 = "",
};

pub const NodeUpdate = struct {
    goal_summary: ?[]const u8 = null,
    goal_predicate: ?[]const u8 = null,
    poll_interval_seconds: ?f64 = null,
    stall_after_seconds: ?f64 = null,
    metric_command: ?[]const u8 = null,
    metric_direction: ?[]const u8 = null,
    trigger_prompt: ?[]const u8 = null,
    check_description: ?[]const u8 = null,
    model_tier: ?[]const u8 = null,
};

pub const Settings = struct {
    daemon_pipe: []const u8 = "",
    support_directory: []const u8 = "",
    reconnect_automatically: bool = true,
};

pub const FormError = error{
    EmptyTitle,
    MissingSource,
    MissingTarget,
    SameEndpoint,
    UnsupportedLoopType,
    UnsupportedEdgeKind,
    UnsupportedEdgeCondition,
    UnsupportedTransform,
    UnsupportedBackend,
    UnsupportedModelTier,
    UnsupportedMetricDirection,
    InvalidGoal,
    InvalidWorktree,
    InvalidCycleGuard,
    MissingFirstInstruction,
    MissingTriggerPrompt,
    EmptyJumpQuery,
};

pub fn validateJumpQuery(query: []const u8) FormError![]const u8 {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyJumpQuery;
    return trimmed;
}

pub fn validateNode(draft: NodeDraft) FormError!void {
    if (std.mem.eql(u8, draft.loop_type, "composite")) {
        if (std.mem.trim(u8, draft.title, " \t\r\n").len == 0) return error.EmptyTitle;
    }
    if (!std.mem.eql(u8, draft.loop_type, "turnBased") and
        !std.mem.eql(u8, draft.loop_type, "timeBased") and
        !std.mem.eql(u8, draft.loop_type, "goalBased") and
        !std.mem.eql(u8, draft.loop_type, "composite"))
        return error.UnsupportedLoopType;
    if (!std.mem.eql(u8, draft.backend, "claudeCode") and
        !std.mem.eql(u8, draft.backend, "copilotCLI") and
        !std.mem.eql(u8, draft.backend, "codex"))
        return error.UnsupportedBackend;
    if (draft.model_tier.len != 0 and
        !std.mem.eql(u8, draft.model_tier, "fast") and
        !std.mem.eql(u8, draft.model_tier, "standard") and
        !std.mem.eql(u8, draft.model_tier, "capable"))
        return error.UnsupportedModelTier;
    if (std.mem.eql(u8, draft.loop_type, "turnBased") and
        std.mem.trim(u8, draft.first_instruction, " \t\r\n").len == 0)
        return error.MissingFirstInstruction;
    if (std.mem.eql(u8, draft.loop_type, "timeBased") and
        std.mem.trim(u8, draft.trigger_prompt, " \t\r\n").len == 0)
        return error.MissingTriggerPrompt;
    if (std.mem.eql(u8, draft.loop_type, "goalBased")) {
        if (std.mem.trim(u8, draft.goal_summary, " \t\r\n").len == 0) return error.InvalidGoal;
        if (draft.poll_interval_seconds <= 0) return error.InvalidGoal;
        if (draft.stall_after_seconds) |seconds| if (seconds <= 0) return error.InvalidGoal;
        if (draft.metric_direction.len != 0 and
            !std.mem.eql(u8, draft.metric_direction, "maximize") and
            !std.mem.eql(u8, draft.metric_direction, "minimize"))
            return error.UnsupportedMetricDirection;
    }
    const has_worktree = draft.worktree_repository.len != 0 or
        draft.worktree_path.len != 0 or draft.worktree_branch.len != 0;
    if (has_worktree and (draft.worktree_repository.len == 0 or
        draft.worktree_path.len == 0 or draft.worktree_branch.len == 0))
        return error.InvalidWorktree;
}

pub fn validateEdge(draft: EdgeDraft) FormError!void {
    if (draft.from.len == 0) return error.MissingSource;
    if (draft.to.len == 0) return error.MissingTarget;
    if (std.mem.eql(u8, draft.from, draft.to)) return error.SameEndpoint;
    if (!std.mem.eql(u8, draft.kind, "handoff") and
        !std.mem.eql(u8, draft.kind, "message") and
        !std.mem.eql(u8, draft.kind, "spawn"))
        return error.UnsupportedEdgeKind;
    if (!std.mem.eql(u8, draft.condition, "always") and
        !std.mem.eql(u8, draft.condition, "onSuccess") and
        !std.mem.eql(u8, draft.condition, "onFailure"))
        return error.UnsupportedEdgeCondition;
    if (!std.mem.eql(u8, draft.transform_kind, "none") and
        !std.mem.eql(u8, draft.transform_kind, "template") and
        !std.mem.eql(u8, draft.transform_kind, "script"))
        return error.UnsupportedTransform;
    if (!std.mem.eql(u8, draft.transform_kind, "none") and draft.transform_value.len == 0)
        return error.UnsupportedTransform;
    if (draft.cycle_max_iterations) |count| if (count <= 0) return error.InvalidCycleGuard;
    if (draft.cycle_stop_after_passes) |count| if (count <= 0) return error.InvalidCycleGuard;
}

pub fn validateNodeUpdate(update: NodeUpdate) FormError!void {
    if (update.goal_summary) |value| if (std.mem.trim(u8, value, " \t\r\n").len == 0) return error.InvalidGoal;
    if (update.poll_interval_seconds) |value| if (value <= 0) return error.InvalidGoal;
    if (update.stall_after_seconds) |value| if (value <= 0) return error.InvalidGoal;
    if (update.metric_direction) |value|
        if (!std.mem.eql(u8, value, "maximize") and !std.mem.eql(u8, value, "minimize"))
            return error.UnsupportedMetricDirection;
    if (update.model_tier) |value|
        if (!std.mem.eql(u8, value, "fast") and !std.mem.eql(u8, value, "standard") and !std.mem.eql(u8, value, "capable"))
            return error.UnsupportedModelTier;
    if (update.goal_summary == null and update.goal_predicate == null and update.poll_interval_seconds == null and
        update.stall_after_seconds == null and update.metric_command == null and update.metric_direction == null and
        update.trigger_prompt == null and update.check_description == null and update.model_tier == null)
        return error.InvalidGoal;
}

pub fn jumpTo(nodes: []const GraphModel.Node, query: []const u8, current: ?usize) ?usize {
    if (nodes.len == 0) return null;
    const needle = std.mem.trim(u8, query, " \t\r\n");
    if (needle.len == 0) return current orelse 0;
    const start = (current orelse nodes.len - 1) + 1;
    var offset: usize = 0;
    while (offset < nodes.len) : (offset += 1) {
        const index = (start + offset) % nodes.len;
        if (containsIgnoreCase(nodes[index].title, needle) or
            containsIgnoreCase(nodes[index].id, needle))
            return index;
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var equal = true;
        for (needle, 0..) |byte, index| {
            if (std.ascii.toLower(haystack[start + index]) != std.ascii.toLower(byte)) {
                equal = false;
                break;
            }
        }
        if (equal) return true;
    }
    return false;
}

pub const ContextCommand = enum {
    create_node,
    edit_node,
    create_edge,
    open_node,
    stop_node,
    delete_node,
    jump,
    settings,
};

test "node and edge forms reject invalid drafts explicitly" {
    try std.testing.expectError(error.EmptyTitle, validateNode(.{ .title = " \n" }));
    try std.testing.expectError(error.SameEndpoint, validateEdge(.{ .from = "a", .to = "a" }));
    try std.testing.expectError(error.UnsupportedEdgeKind, validateEdge(.{ .from = "a", .to = "b", .kind = "bad" }));
}

test "jump navigation wraps and matches title or id case insensitively" {
    const nodes = [_]GraphModel.Node{
        .{ .id = @constCast("node-a"), .title = @constCast("Alpha"), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
        .{ .id = @constCast("node-b"), .title = @constCast("Beta"), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
    };
    try std.testing.expectEqual(@as(?usize, 1), jumpTo(&nodes, "be", 0));
    try std.testing.expectEqual(@as(?usize, 0), jumpTo(&nodes, "NODE-A", 1));
}

test "jump queries reject empty and whitespace input before navigation" {
    try std.testing.expectError(error.EmptyJumpQuery, validateJumpQuery(""));
    try std.testing.expectError(error.EmptyJumpQuery, validateJumpQuery(" \t\r\n "));
    try std.testing.expectEqualStrings("be", try validateJumpQuery(" \tbe\n"));
    const nodes = [_]GraphModel.Node{
        .{ .id = @constCast("node-a"), .title = @constCast("Alpha"), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
    };
    try std.testing.expectEqual(@as(?usize, null), jumpTo(&nodes, "missing", 0));
}
