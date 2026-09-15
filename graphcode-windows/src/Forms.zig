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
    backend: ?[]const u8 = null,
    model_tier: []const u8 = "",
    worktree_repository: []const u8 = "",
    worktree_id: []const u8 = "",
    worktree_path: []const u8 = "",
    worktree_branch: []const u8 = "",
    subgraph_json: []const u8 = "",
    created_by: []const u8 = "",
    claude_permissions: []const u8 = "auto",
    copilot_permissions: []const u8 = "allowEverything",
    briefing_enabled: bool = true,
    activity_enabled: bool = false,
    pub fn deinit(self: *NodeDraft, allocator: std.mem.Allocator) void {
        freeSlice(allocator, self.title);
        freeSlice(allocator, self.loop_type);
        freeSlice(allocator, self.check_description);
        freeSlice(allocator, self.trigger_prompt);
        freeSlice(allocator, self.first_instruction);
        freeSlice(allocator, self.goal_summary);
        freeSlice(allocator, self.goal_predicate);
        freeSlice(allocator, self.metric_command);
        freeSlice(allocator, self.metric_direction);
        if (self.backend) |value| freeSlice(allocator, value);
        freeSlice(allocator, self.model_tier);
        freeSlice(allocator, self.worktree_repository);
        freeSlice(allocator, self.worktree_id);
        freeSlice(allocator, self.worktree_path);
        freeSlice(allocator, self.worktree_branch);
        freeSlice(allocator, self.subgraph_json);
        freeSlice(allocator, self.created_by);
    }
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

    pub fn deinit(self: *EdgeDraft, allocator: std.mem.Allocator) void {
        freeSlice(allocator, self.from);
        freeSlice(allocator, self.to);
        freeSlice(allocator, self.kind);
        freeSlice(allocator, self.condition);
        freeSlice(allocator, self.transform_kind);
        freeSlice(allocator, self.transform_value);
        freeSlice(allocator, self.cycle_until);
        freeSlice(allocator, self.spawn_target_project_path);
    }
};

fn freeSlice(allocator: std.mem.Allocator, value: []const u8) void {
    if (value.len != 0) allocator.free(value);
}

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

    pub fn deinit(self: *NodeUpdate, allocator: std.mem.Allocator) void {
        if (self.goal_summary) |value| allocator.free(value);
        if (self.goal_predicate) |value| allocator.free(value);
        if (self.metric_command) |value| allocator.free(value);
        if (self.metric_direction) |value| allocator.free(value);
        if (self.trigger_prompt) |value| allocator.free(value);
        if (self.check_description) |value| allocator.free(value);
        if (self.model_tier) |value| allocator.free(value);
    }
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
    InvalidSubgraph,
    InvalidCreatedBy,
    InvalidCycleGuard,
    InvalidNumericInput,
    MissingFirstInstruction,
    MissingTriggerPrompt,
    EmptyJumpQuery,
};

pub const untitled_fallback = "New Loop";

pub fn resolvedTitle(title: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, title, " \t\r\n");
    return if (trimmed.len == 0) untitled_fallback else trimmed;
}

pub fn validateJumpQuery(query: []const u8) FormError![]const u8 {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyJumpQuery;
    return trimmed;
}

pub fn validateNode(draft: NodeDraft) FormError!void {
    if (!isLoopType(draft.loop_type) and !std.mem.eql(u8, draft.loop_type, "composite"))
        return error.UnsupportedLoopType;
    if (std.mem.eql(u8, draft.loop_type, "composite") and
        std.mem.trim(u8, draft.title, " \t\r\n").len == 0)
        return error.EmptyTitle;
    if (draft.backend) |backend| {
        if (!isBackend(backend))
            return error.UnsupportedBackend;
    }
    if (draft.model_tier.len != 0 and
        !isModelTier(draft.model_tier))
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
            !isMetricDirection(draft.metric_direction))
            return error.UnsupportedMetricDirection;
    }
    const has_worktree = draft.worktree_repository.len != 0 or
        draft.worktree_path.len != 0 or draft.worktree_branch.len != 0;
    if (has_worktree and (draft.worktree_repository.len == 0 or
        draft.worktree_path.len == 0 or draft.worktree_branch.len == 0))
        return error.InvalidWorktree;
    if (draft.subgraph_json.len != 0) try validateSubgraphJson(draft.subgraph_json);
    if (draft.created_by.len != 0 and !isUuid(draft.created_by)) return error.InvalidCreatedBy;
}

pub fn validateSubgraphJson(value: []const u8) FormError!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), value, .{}) catch return error.InvalidSubgraph;
    defer parsed.deinit();
    canonicalizeLoopTypeAliases(&parsed.value);
    try validateLoopGraphValue(parsed.value, 0);
}

pub fn isLoopType(value: []const u8) bool {
    return std.mem.eql(u8, value, "turnBased") or
        std.mem.eql(u8, value, "timeBased") or
        std.mem.eql(u8, value, "goalBased") or
        std.mem.eql(u8, value, "proactive");
}

pub fn canonicalizeLoopTypeAliases(value: *std.json.Value) void {
    switch (value.*) {
        .object => |*object| {
            if (object.getPtr("loopType")) |loop_type| switch (loop_type.*) {
                .string => |text| if (std.mem.eql(u8, text, "composite")) {
                    loop_type.* = .{ .string = "proactive" };
                },
                else => {},
            };
            if (object.getPtr("subGraph")) |nested| canonicalizeLoopTypeAliases(nested);
            if (object.getPtr("nodes")) |nodes| switch (nodes.*) {
                .array => |*items| for (items.items) |*item| canonicalizeLoopTypeAliases(item),
                else => {},
            };
        },
        .array => |*items| for (items.items) |*item| canonicalizeLoopTypeAliases(item),
        else => {},
    }
}

pub fn isBackend(value: []const u8) bool {
    return std.mem.eql(u8, value, "claudeCode") or
        std.mem.eql(u8, value, "copilotCLI") or
        std.mem.eql(u8, value, "codex");
}

pub fn isModelTier(value: []const u8) bool {
    return std.mem.eql(u8, value, "fast") or
        std.mem.eql(u8, value, "standard") or
        std.mem.eql(u8, value, "capable");
}

pub fn isMetricDirection(value: []const u8) bool {
    return std.mem.eql(u8, value, "maximize") or std.mem.eql(u8, value, "minimize");
}

pub fn isEdgeKind(value: []const u8) bool {
    return std.mem.eql(u8, value, "handoff") or
        std.mem.eql(u8, value, "message") or
        std.mem.eql(u8, value, "spawn");
}

pub fn isEdgeCondition(value: []const u8) bool {
    return std.mem.eql(u8, value, "always") or
        std.mem.eql(u8, value, "onSuccess") or
        std.mem.eql(u8, value, "onFailure");
}

pub fn isTransformKind(value: []const u8) bool {
    return std.mem.eql(u8, value, "none") or
        std.mem.eql(u8, value, "template") or
        std.mem.eql(u8, value, "script");
}

fn validateLoopGraphValue(value: std.json.Value, depth: usize) FormError!void {
    if (depth > 32) return error.InvalidSubgraph;
    const object = switch (value) {
        .object => |item| item,
        else => return error.InvalidSubgraph,
    };
    const graph_id = object.get("id") orelse return error.InvalidSubgraph;
    if (!isUuidValue(graph_id)) return error.InvalidSubgraph;
    const project = object.get("project") orelse return error.InvalidSubgraph;
    const project_object = switch (project) {
        .object => |item| item,
        else => return error.InvalidSubgraph,
    };
    if (!nonEmptyString(project_object.get("path")) or
        !nonEmptyString(project_object.get("name")) or
        !isDateValue(project_object.get("lastOpenedAt")))
        return error.InvalidSubgraph;
    const nodes = object.get("nodes") orelse return error.InvalidSubgraph;
    const edges = object.get("edges") orelse return error.InvalidSubgraph;
    const node_items = switch (nodes) {
        .array => |items| items,
        else => return error.InvalidSubgraph,
    };
    const edge_items = switch (edges) {
        .array => |items| items,
        else => return error.InvalidSubgraph,
    };
    for (node_items.items) |item| {
        const node = switch (item) {
            .object => |value_object| value_object,
            else => return error.InvalidSubgraph,
        };
        if (!isUuidValue(node.get("id")) or
            !nonEmptyString(node.get("title")) or
            !enumString(node.get("loopType"), isLoopType))
            return error.InvalidSubgraph;
        try optionalString(node.get("checkDescription"));
        try optionalString(node.get("triggerPrompt"));
        try optionalString(node.get("firstInstruction"));
        try requiredBool(node.get("pausesBeforeWritesOnly"));
        try validateGoal(node.get("goal"));
        if (!enumString(node.get("backend"), isBackend)) return error.InvalidSubgraph;
        if (!enumStringOrNull(node.get("modelTier"), isModelTier)) return error.InvalidSubgraph;
        try validateWorktree(node.get("worktreeBinding"));
        const subgraph = node.get("subGraph") orelse null;
        if (subgraph) |nested| switch (nested) {
            .null => {},
            else => try validateLoopGraphValue(nested, depth + 1),
        };
        if (!enumString(node.get("pilotState"), isPilotState)) return error.InvalidSubgraph;
        try validateUsage(node.get("usage"));
        try optionalString(node.get("activity"));
        try validatePresence(node.get("presence"));
        // Runtime-only and intentionally ignored by Codable persistence.
        try validateMetricHistory(node.get("metricHistory"));
        if (!isUuidOrNull(node.get("createdBy"))) return error.InvalidSubgraph;
        if (!enumObject(node.get("state"), isLoopState)) return error.InvalidSubgraph;
        if (!isDateValue(node.get("createdAt"))) return error.InvalidSubgraph;
    }
    for (edge_items.items) |item| {
        const edge = switch (item) {
            .object => |value_object| value_object,
            else => return error.InvalidSubgraph,
        };
        if (!isUuidValue(edge.get("id")) or
            !isUuidValue(edge.get("from")) or
            !isUuidValue(edge.get("to")) or
            !enumString(edge.get("kind"), isEdgeKind) or
            !enumString(edge.get("condition"), isEdgeCondition))
            return error.InvalidSubgraph;
        try validatePayloadTransform(edge.get("payloadTransform"));
        try validateCycleGuard(edge.get("cycleGuard"));
        try optionalString(edge.get("spawnTargetProjectPath"));
        try optionalInteger(edge.get("fireCount"));
    }
}

fn validateGoal(value: ?std.json.Value) FormError!void {
    const item = value orelse return;
    if (item == .null) return;
    const object = switch (item) {
        .object => |value_object| value_object,
        else => return error.InvalidSubgraph,
    };
    if (!nonEmptyString(object.get("summary")) or
        !isPositiveNumber(object.get("pollIntervalSeconds")))
        return error.InvalidSubgraph;
    try optionalString(object.get("predicate"));
    try optionalNumber(object.get("stallAfterSeconds"));
    try optionalString(object.get("metricCommand"));
    if (!enumString(object.get("metricDirection"), isMetricDirection)) return error.InvalidSubgraph;
}

fn validateWorktree(value: ?std.json.Value) FormError!void {
    const item = value orelse return;
    if (item == .null) return;
    const object = switch (item) {
        .object => |value_object| value_object,
        else => return error.InvalidSubgraph,
    };
    if (!nonEmptyString(object.get("id")) or
        !nonEmptyString(object.get("repositoryPath")) or
        !nonEmptyString(object.get("worktreePath")) or
        !nonEmptyString(object.get("branch")))
        return error.InvalidSubgraph;
}

fn validatePayloadTransform(value: ?std.json.Value) FormError!void {
    const item = value orelse return;
    const object = switch (item) {
        .object => |value_object| value_object,
        else => return error.InvalidSubgraph,
    };
    var count: usize = 0;
    if (object.get("none")) |none| {
        count += 1;
        if (none != .object) return error.InvalidSubgraph;
    }
    for ([_][]const u8{ "template", "script" }) |key| {
        if (object.get(key)) |payload| {
            count += 1;
            if (!transformPayloadValue(payload)) return error.InvalidSubgraph;
        }
    }
    if (count != 1) return error.InvalidSubgraph;
}

fn transformPayloadValue(value: std.json.Value) bool {
    return switch (value) {
        .object => |object| nonEmptyString(object.get("_0")),
        .string => |text| std.mem.trim(u8, text, " \t\r\n").len != 0,
        else => false,
    };
}

fn validateCycleGuard(value: ?std.json.Value) FormError!void {
    const item = value orelse return;
    if (item == .null) return;
    const object = switch (item) {
        .object => |value_object| value_object,
        else => return error.InvalidSubgraph,
    };
    var bounded = false;
    if (object.get("maxIterations")) |field| {
        if (field == .null) {} else {
            if (!isPositiveInteger(field)) return error.InvalidSubgraph;
            bounded = true;
        }
    }
    if (object.get("until")) |field| {
        if (field == .null) {} else {
            if (!nonEmptyStringValue(field)) return error.InvalidSubgraph;
            bounded = true;
        }
    }
    if (object.get("stopAfterPassesWithoutImprovement")) |field| {
        if (field == .null) {} else {
            if (!isPositiveInteger(field)) return error.InvalidSubgraph;
            bounded = true;
        }
    }
    if (!bounded) return error.InvalidSubgraph;
}

fn validateUsage(value: ?std.json.Value) FormError!void {
    const item = value orelse return;
    if (item == .null) return;
    const object = switch (item) {
        .object => |value_object| value_object,
        else => return error.InvalidSubgraph,
    };
    try optionalInteger(object.get("inputTokens"));
    try optionalInteger(object.get("outputTokens"));
    try optionalNumber(object.get("costUSD"));
    try optionalDate(object.get("reportedAt"));
}

fn validatePresence(value: ?std.json.Value) FormError!void {
    const item = value orelse return;
    if (item == .null) return;
    const object = switch (item) {
        .object => |value_object| value_object,
        else => return error.InvalidSubgraph,
    };
    if (!enumString(object.get("presence"), isPresence) or
        !enumString(object.get("confidence"), isPresenceConfidence))
        return error.InvalidSubgraph;
}

fn validateMetricHistory(value: ?std.json.Value) FormError!void {
    const item = value orelse return;
    const array = switch (item) {
        .array => |items| items,
        else => return error.InvalidSubgraph,
    };
    for (array.items) |entry| {
        const object = switch (entry) {
            .object => |value_object| value_object,
            else => return error.InvalidSubgraph,
        };
        if (!isFiniteNumber(object.get("value")) or !isDateValue(object.get("recordedAt")))
            return error.InvalidSubgraph;
    }
}

fn isPilotState(value: []const u8) bool {
    return std.mem.eql(u8, value, "notPiloted") or std.mem.eql(u8, value, "piloting") or
        std.mem.eql(u8, value, "piloted") or std.mem.eql(u8, value, "armed");
}

fn isLoopState(value: []const u8) bool {
    return std.mem.eql(u8, value, "idle") or std.mem.eql(u8, value, "running") or
        std.mem.eql(u8, value, "awaitingInput") or std.mem.eql(u8, value, "blocked") or
        std.mem.eql(u8, value, "succeeded") or std.mem.eql(u8, value, "failed") or
        std.mem.eql(u8, value, "stalled") or std.mem.eql(u8, value, "waiting") or
        std.mem.eql(u8, value, "stopped");
}

fn isPresence(value: []const u8) bool {
    return std.mem.eql(u8, value, "busy") or std.mem.eql(u8, value, "awaitingInput") or
        std.mem.eql(u8, value, "idle") or std.mem.eql(u8, value, "absent") or
        std.mem.eql(u8, value, "unknown");
}

fn isPresenceConfidence(value: []const u8) bool {
    return std.mem.eql(u8, value, "reported") or std.mem.eql(u8, value, "scanned") or
        std.mem.eql(u8, value, "heuristic");
}

fn enumString(value: ?std.json.Value, validator: *const fn ([]const u8) bool) bool {
    return switch (value orelse return false) {
        .string => |text| validator(text),
        else => false,
    };
}

fn enumStringOrNull(value: ?std.json.Value, validator: *const fn ([]const u8) bool) bool {
    const item = value orelse return true;
    return switch (item) {
        .null => true,
        .string => |text| validator(text),
        else => false,
    };
}

fn enumObject(value: ?std.json.Value, validator: *const fn ([]const u8) bool) bool {
    const item = value orelse return false;
    const object = switch (item) {
        .object => |value_object| value_object,
        else => return false,
    };
    var count: usize = 0;
    var valid = false;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        count += 1;
        if (validator(entry.key_ptr.*)) {
            valid = entry.value_ptr.* == .object;
        }
    }
    return count == 1 and valid;
}

fn optionalString(value: ?std.json.Value) FormError!void {
    const item = value orelse return;
    if (item != .null and item != .string) return error.InvalidSubgraph;
}

fn optionalBool(value: ?std.json.Value) FormError!void {
    const item = value orelse return;
    if (item != .null and item != .bool) return error.InvalidSubgraph;
}

fn requiredBool(value: ?std.json.Value) FormError!void {
    const item = value orelse return error.InvalidSubgraph;
    if (item != .bool) return error.InvalidSubgraph;
}

fn optionalNumber(value: ?std.json.Value) FormError!void {
    const item = value orelse return;
    if (item != .null and !isFiniteNumber(item)) return error.InvalidSubgraph;
}

fn optionalInteger(value: ?std.json.Value) FormError!void {
    const item = value orelse return;
    if (item != .null and item != .integer) return error.InvalidSubgraph;
}

fn optionalDate(value: ?std.json.Value) FormError!void {
    const item = value orelse return;
    if (item != .null and !isDateValue(item)) return error.InvalidSubgraph;
}

fn isUuidOrNull(value: ?std.json.Value) bool {
    const item = value orelse return true;
    return item == .null or isUuidValue(item);
}

fn isPositiveNumber(value: ?std.json.Value) bool {
    return switch (value orelse return false) {
        .integer => |number| number > 0,
        .float => |number| std.math.isFinite(number) and number > 0,
        else => false,
    };
}

fn isPositiveInteger(value: std.json.Value) bool {
    return switch (value) {
        .integer => |number| number > 0,
        else => false,
    };
}

fn isFiniteNumber(value: ?std.json.Value) bool {
    return switch (value orelse return false) {
        .integer => true,
        .float => |number| std.math.isFinite(number),
        else => false,
    };
}

fn nonEmptyStringValue(value: std.json.Value) bool {
    return switch (value) {
        .string => |text| std.mem.trim(u8, text, " \t\r\n").len != 0,
        else => false,
    };
}

pub fn isUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
        } else if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn isUuidValue(value: ?std.json.Value) bool {
    return switch (value orelse return false) {
        .string => |text| isUuid(text),
        else => false,
    };
}

fn nonEmptyString(value: ?std.json.Value) bool {
    return switch (value orelse return false) {
        .string => |text| std.mem.trim(u8, text, " \t\r\n").len != 0,
        else => false,
    };
}

fn isDateValue(value: ?std.json.Value) bool {
    return switch (value orelse return false) {
        .float, .integer => true,
        else => false,
    };
}

pub fn validateEdge(draft: EdgeDraft) FormError!void {
    if (draft.from.len == 0) return error.MissingSource;
    if (draft.to.len == 0) return error.MissingTarget;
    if (std.mem.eql(u8, draft.from, draft.to)) return error.SameEndpoint;
    if (!isEdgeKind(draft.kind))
        return error.UnsupportedEdgeKind;
    if (!isEdgeCondition(draft.condition))
        return error.UnsupportedEdgeCondition;
    if (!isTransformKind(draft.transform_kind))
        return error.UnsupportedTransform;
    if (!std.mem.eql(u8, draft.transform_kind, "none") and draft.transform_value.len == 0)
        return error.UnsupportedTransform;
    if (draft.cycle_max_iterations) |count| if (count <= 0) return error.InvalidCycleGuard;
    if (draft.cycle_stop_after_passes) |count| if (count <= 0) return error.InvalidCycleGuard;
}

pub fn validateNodeUpdate(update: NodeUpdate) FormError!void {
    if (update.goal_summary) |value| if (std.mem.trim(u8, value, " \t\r\n").len == 0) return error.InvalidGoal;
    if (update.poll_interval_seconds) |value| if (value <= 0) return error.InvalidGoal;
    if (update.stall_after_seconds) |value| {
        // Zero or negative is the explicit clear sentinel used by NodeUpdate.
        if (!std.math.isFinite(value)) return error.InvalidGoal;
    }
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
    try std.testing.expectError(error.EmptyTitle, validateNode(.{ .title = " \n", .loop_type = "composite" }));
    try validateNode(.{ .title = " \n", .loop_type = "turnBased" });
    try std.testing.expectEqualStrings("New Loop", resolvedTitle(" \n"));
    try std.testing.expectError(error.SameEndpoint, validateEdge(.{ .from = "a", .to = "a" }));
    try std.testing.expectError(error.UnsupportedEdgeKind, validateEdge(.{ .from = "a", .to = "b", .kind = "bad" }));
    try validateNode(.{ .title = "Composite", .loop_type = "composite", .subgraph_json = "{\"id\":\"33333333-3333-4333-8333-333333333333\",\"project\":{\"path\":\"C:\\\\work\\\\subgraph\",\"name\":\"subgraph\",\"lastOpenedAt\":1767225600},\"nodes\":[],\"edges\":[]}", .created_by = "11111111-1111-4111-8111-111111111111" });
    try std.testing.expectError(error.InvalidSubgraph, validateNode(.{ .title = "Composite", .loop_type = "composite", .subgraph_json = "{\"nodes\":[]}" }));
    try std.testing.expectError(error.InvalidCreatedBy, validateNode(.{ .title = "Loop", .created_by = "not-a-uuid" }));
}

test "node updates preserve unchanged fields and allow stall clear sentinel" {
    try validateNodeUpdate(.{ .stall_after_seconds = 0 });
    try std.testing.expectError(error.InvalidGoal, validateNodeUpdate(.{ .poll_interval_seconds = 0 }));
}

test "typed form result deinit releases every owned allocation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    const allocator = gpa.allocator();
    var draft = NodeDraft{
        .title = try allocator.dupe(u8, "title"),
        .loop_type = try allocator.dupe(u8, "turnBased"),
        .check_description = try allocator.dupe(u8, "check"),
        .trigger_prompt = try allocator.dupe(u8, "trigger"),
        .first_instruction = try allocator.dupe(u8, "do"),
        .goal_summary = try allocator.dupe(u8, ""),
        .goal_predicate = try allocator.dupe(u8, ""),
        .metric_command = try allocator.dupe(u8, ""),
        .metric_direction = try allocator.dupe(u8, "maximize"),
        .backend = try allocator.dupe(u8, "claudeCode"),
        .model_tier = try allocator.dupe(u8, ""),
        .worktree_repository = try allocator.dupe(u8, ""),
        .worktree_id = try allocator.dupe(u8, ""),
        .worktree_path = try allocator.dupe(u8, ""),
        .worktree_branch = try allocator.dupe(u8, ""),
        .subgraph_json = try allocator.dupe(u8, ""),
        .created_by = try allocator.dupe(u8, ""),
    };
    draft.deinit(allocator);
    var update = NodeUpdate{
        .goal_summary = try allocator.dupe(u8, "done"),
        .goal_predicate = try allocator.dupe(u8, ""),
        .metric_command = try allocator.dupe(u8, "metric"),
    };
    update.deinit(allocator);
    var edge = EdgeDraft{
        .from = try allocator.dupe(u8, "a"),
        .to = try allocator.dupe(u8, "b"),
        .kind = try allocator.dupe(u8, "handoff"),
        .condition = try allocator.dupe(u8, "always"),
        .transform_kind = try allocator.dupe(u8, "none"),
        .transform_value = try allocator.dupe(u8, ""),
        .cycle_until = try allocator.dupe(u8, ""),
        .spawn_target_project_path = try allocator.dupe(u8, ""),
    };
    edge.deinit(allocator);
}

test "incremental draft construction survives every allocation failure" {
    const Builder = struct {
        fn node(allocator: std.mem.Allocator) !void {
            var draft = NodeDraft{ .title = &.{}, .loop_type = &.{}, .check_description = &.{}, .trigger_prompt = &.{}, .first_instruction = &.{}, .goal_summary = &.{}, .goal_predicate = &.{}, .metric_command = &.{}, .metric_direction = &.{}, .model_tier = &.{}, .worktree_repository = &.{}, .worktree_id = &.{}, .worktree_path = &.{}, .worktree_branch = &.{}, .subgraph_json = &.{}, .created_by = &.{} };
            errdefer draft.deinit(allocator);
            draft.title = try allocator.dupe(u8, "title");
            draft.loop_type = try allocator.dupe(u8, "turnBased");
            draft.check_description = try allocator.dupe(u8, "check");
            draft.trigger_prompt = try allocator.dupe(u8, "trigger");
            draft.first_instruction = try allocator.dupe(u8, "instruction");
            draft.goal_summary = try allocator.dupe(u8, "goal");
            draft.goal_predicate = try allocator.dupe(u8, "predicate");
            draft.metric_command = try allocator.dupe(u8, "metric");
            draft.metric_direction = try allocator.dupe(u8, "maximize");
            draft.model_tier = try allocator.dupe(u8, "standard");
            draft.worktree_repository = try allocator.dupe(u8, "repo");
            draft.worktree_id = try allocator.dupe(u8, "id");
            draft.worktree_path = try allocator.dupe(u8, "path");
            draft.worktree_branch = try allocator.dupe(u8, "branch");
            draft.subgraph_json = try allocator.dupe(u8, "{\"nodes\":[],\"edges\":[]}");
            draft.created_by = try allocator.dupe(u8, "11111111-1111-4111-8111-111111111111");
            draft.deinit(allocator);
        }

        fn edge(allocator: std.mem.Allocator) !void {
            var draft = EdgeDraft{ .from = &.{}, .to = &.{}, .kind = &.{}, .condition = &.{}, .transform_kind = &.{}, .transform_value = &.{}, .cycle_until = &.{}, .spawn_target_project_path = &.{} };
            errdefer draft.deinit(allocator);
            draft.from = try allocator.dupe(u8, "from");
            draft.to = try allocator.dupe(u8, "to");
            draft.kind = try allocator.dupe(u8, "handoff");
            draft.condition = try allocator.dupe(u8, "always");
            draft.transform_kind = try allocator.dupe(u8, "none");
            draft.transform_value = try allocator.dupe(u8, "value");
            draft.cycle_until = try allocator.dupe(u8, "until");
            draft.spawn_target_project_path = try allocator.dupe(u8, "project");
            draft.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Builder.node, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Builder.edge, .{});
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
