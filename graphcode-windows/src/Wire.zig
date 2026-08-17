const std = @import("std");
const Forms = @import("Forms.zig");

pub const current_version: u8 = 2;
pub const supported_versions = [_]u8{ 1, 2 };
pub const v2_max_payload: usize = 1_048_576;
pub const legacy_max_payload: usize = 2 * 1_048_576;

pub const ProtocolMode = enum {
    v1,
    v2,
};

pub const ConnectionState = enum {
    disconnected,
    connecting,
    negotiating,
    connected,
    reconnecting,
    unavailable,
    protocol_error,
};

pub const EventKind = enum {
    recent_projects,
    graph_changed,
    error_occurred,
    unknown,
};

pub const CommandKind = enum {
    list_recent_projects,
    restore_open_projects,
    open_global_graph,
    open_project,
    close_project,
    forget_project,
    delete_project_graph,
    graph_command,
};

pub fn commandName(kind: CommandKind) []const u8 {
    return switch (kind) {
        .list_recent_projects => "listRecentProjects",
        .restore_open_projects => "restoreOpenProjects",
        .open_global_graph => "openGlobalGraph",
        .open_project => "openProject",
        .close_project => "closeProject",
        .forget_project => "forgetProject",
        .delete_project_graph => "deleteProjectGraph",
        .graph_command => "graphCommand",
    };
}

pub fn graphCommandName(kind: []const u8) []const u8 {
    return kind;
}

pub fn frameLength(data: []const u8, mode: ProtocolMode) ![4]u8 {
    if (data.len > (if (mode == .v2) v2_max_payload else legacy_max_payload)) {
        return error.PayloadTooLarge;
    }
    const length: u32 = @intCast(data.len);
    return .{
        @intCast((length >> 24) & 0xff),
        @intCast((length >> 16) & 0xff),
        @intCast((length >> 8) & 0xff),
        @intCast(length & 0xff),
    };
}

pub fn decodedLength(header: [4]u8, mode: ProtocolMode) !usize {
    const length: usize =
        (@as(usize, header[0]) << 24) | (@as(usize, header[1]) << 16) | (@as(usize, header[2]) << 8) | @as(usize, header[3]);
    const limit = if (mode == .v2) v2_max_payload else legacy_max_payload;
    if (length > limit) return error.PayloadTooLarge;
    return length;
}

pub fn looksLikeV2(data: []const u8) bool {
    return std.mem.indexOf(u8, data, "\"version\"") != null or
        std.mem.indexOf(u8, data, "\"kind\"") != null;
}

pub fn responseRequestID(data: []const u8) ?[]const u8 {
    return jsonString(data, "requestID");
}

pub fn eventKind(data: []const u8) EventKind {
    if (std.mem.indexOf(u8, data, "\"recentProjectsListed\"") != null) {
        return .recent_projects;
    }
    if (std.mem.indexOf(u8, data, "\"graphChanged\"") != null) {
        return .graph_changed;
    }
    if (std.mem.indexOf(u8, data, "\"errorOccurred\"") != null or
        std.mem.indexOf(u8, data, "\"error\"") != null)
    {
        return .error_occurred;
    }
    return .unknown;
}

pub fn v2Hello(
    allocator: std.mem.Allocator,
    client_id: []const u8,
    resume_from: ?u64,
    subscription_path: []const u8,
) ![]u8 {
    const subscription = if (subscription_path.len == 0)
        try allocator.dupe(u8, "")
    else blk: {
        const quoted_path = try quoteJson(allocator, subscription_path);
        defer allocator.free(quoted_path);
        break :blk try std.mem.concat(allocator, u8, &.{
            ",\"subscription\":{\"projectPaths\":[",
            quoted_path,
            "]}",
        });
    };
    defer allocator.free(subscription);
    if (resume_from) |cursor| {
        const cursor_text = try std.fmt.allocPrint(allocator, "{d}", .{cursor});
        defer allocator.free(cursor_text);
        return std.mem.concat(allocator, u8, &.{
            "{\"version\":2,\"kind\":\"hello\",\"supportedVersions\":[1,2],\"clientID\":\"",
            client_id,
            "\",\"resumeFrom\":",
            cursor_text,
            subscription,
            "}",
        });
    }
    return std.mem.concat(allocator, u8, &.{
        "{\"version\":2,\"kind\":\"hello\",\"supportedVersions\":[1,2],\"clientID\":\"",
        client_id,
        "\"",
        subscription,
        "}",
    });
}

pub fn v2Request(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    command_json: []const u8,
) ![]u8 {
    return std.mem.concat(allocator, u8, &.{
        "{\"version\":2,\"kind\":\"request\",\"requestID\":\"",
        request_id,
        "\",\"command\":",
        command_json,
        "}",
    });
}

pub fn v1Command(allocator: std.mem.Allocator, command_json: []const u8) ![]u8 {
    return allocator.dupe(u8, command_json);
}

pub fn commandListRecentProjects(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "{\"listRecentProjects\":{}}");
}

pub fn commandRestoreOpenProjects(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "{\"restoreOpenProjects\":{}}");
}

pub fn commandOpenGlobalGraph(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "{\"openGlobalGraph\":{}}");
}

pub fn commandOpenProject(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const quoted_path = try quoteJson(allocator, path);
    defer allocator.free(quoted_path);
    return std.mem.concat(allocator, u8, &.{
        "{\"openProject\":{\"path\":",
        quoted_path,
        "}}",
    });
}

pub fn commandCloseProject(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return daemonPathCommand(allocator, "closeProject", path);
}

pub fn commandForgetProject(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return daemonPathCommand(allocator, "forgetProject", path);
}

pub fn commandDeleteProjectGraph(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return daemonPathCommand(allocator, "deleteProjectGraph", path);
}

fn daemonPathCommand(allocator: std.mem.Allocator, name: []const u8, path: []const u8) ![]u8 {
    const quoted = try quoteJson(allocator, path);
    defer allocator.free(quoted);
    return std.mem.concat(allocator, u8, &.{"{\"", name, "\":{\"path\":", quoted, "}}"});
}

pub fn commandGraphCreateNode(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    title: []const u8,
    node_id: []const u8,
) ![]u8 {
    const quoted_path = try quoteJson(allocator, project_path);
    defer allocator.free(quoted_path);
    const quoted_title = try quoteJson(allocator, title);
    defer allocator.free(quoted_title);
    const quoted_id = try quoteJson(allocator, node_id);
    defer allocator.free(quoted_id);
    return std.mem.concat(allocator, u8, &.{
        "{\"graphCommand\":{\"projectPath\":",
        quoted_path,
        ",\"command\":{\"createNode\":{\"_0\":{\"id\":",
        quoted_id,
        ",\"title\":",
        quoted_title,
        ",\"loopType\":\"turnBased\",\"checkDescription\":null,\"triggerPrompt\":null,\"firstInstruction\":\"Work on the requested Windows shell task.\",\"pausesBeforeWritesOnly\":false,\"goal\":null,\"backend\":\"claudeCode\",\"modelTier\":null,\"worktree\":null,\"subGraph\":null,\"createdBy\":null}}}}}",
    });
}

/// Encodes every field currently accepted by Swift `NodeDraft`. Empty form strings
/// intentionally become `null`, matching Optional Codable rather than inventing values.
pub fn commandGraphCreateNodeFull(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    node_id: []const u8,
    draft: Forms.NodeDraft,
) ![]u8 {
    const path = try quoteJson(allocator, project_path); defer allocator.free(path);
    const id = try quoteJson(allocator, node_id); defer allocator.free(id);
    const title = try quoteJson(allocator, draft.title); defer allocator.free(title);
    const loop_type = if (std.mem.eql(u8, draft.loop_type, "composite")) "proactive" else draft.loop_type;
    const lt = try quoteJson(allocator, loop_type); defer allocator.free(lt);
    const check = try nullableString(allocator, draft.check_description); defer allocator.free(check);
    const trigger = try nullableString(allocator, draft.trigger_prompt); defer allocator.free(trigger);
    const first = try nullableString(allocator, draft.first_instruction); defer allocator.free(first);
    const goal = try goalJson(allocator, draft); defer allocator.free(goal);
    const backend = try nullableString(allocator, draft.backend); defer allocator.free(backend);
    const tier = try nullableString(allocator, draft.model_tier); defer allocator.free(tier);
    const worktree = try worktreeJson(allocator, draft); defer allocator.free(worktree);
    const subgraph = try safeSubgraphJson(allocator, draft.subgraph_json);
    defer allocator.free(subgraph);
    const created_by = if (Forms.isUuid(draft.created_by)) try quoteJson(allocator, draft.created_by) else try allocator.dupe(u8, "null"); defer allocator.free(created_by);
    return std.mem.concat(allocator, u8, &.{
        "{\"graphCommand\":{\"projectPath\":", path, ",\"command\":{\"createNode\":{\"_0\":{\"id\":",
        id, ",\"title\":", title, ",\"loopType\":", lt, ",\"checkDescription\":", check,
        ",\"triggerPrompt\":", trigger, ",\"firstInstruction\":", first,
        ",\"pausesBeforeWritesOnly\":", if (draft.pauses_before_writes_only) "true" else "false",
        ",\"goal\":", goal, ",\"backend\":", backend, ",\"modelTier\":", tier,
        ",\"worktree\":", worktree, ",\"subGraph\":", subgraph, ",\"createdBy\":", created_by,
        "}}}}}",
    });
}

fn nullableString(allocator: std.mem.Allocator, value: ?[]const u8) ![]u8 {
    const text = value orelse return allocator.dupe(u8, "null");
    if (text.len == 0) return allocator.dupe(u8, "null");
    return quoteJson(allocator, text);
}

fn safeSubgraphJson(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len == 0) return allocator.dupe(u8, "null");
    Forms.validateSubgraphJson(value) catch return allocator.dupe(u8, "null");
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, value, .{});
    defer parsed.deinit();
    Forms.canonicalizeLoopTypeAliases(&parsed.value);
    stripRuntimeFields(&parsed.value);
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    try output.writer().print("{f}", .{std.json.fmt(parsed.value, .{})});
    return try output.toOwnedSlice();
}

fn stripRuntimeFields(value: *std.json.Value) void {
    switch (value.*) {
        .object => |*object| {
            _ = object.swapRemove("hasActiveDependents");
            if (object.getPtr("subGraph")) |nested| stripRuntimeFields(nested);
            if (object.getPtr("nodes")) |nodes| switch (nodes.*) {
                .array => |*items| for (items.items) |*item| stripRuntimeFields(item),
                else => {},
            };
        },
        .array => |*items| for (items.items) |*item| stripRuntimeFields(item),
        else => {},
    }
}

test "canonical subgraphs omit runtime-only node fields recursively" {
    const allocator = std.testing.allocator;
    const input =
        \\{"id":"11111111-1111-4111-8111-111111111111","project":{"path":"C:\\work\\graph","name":"Graph","lastOpenedAt":0},"nodes":[{"id":"22222222-2222-4222-8222-222222222222","title":"Loop","loopType":"turnBased","backend":"claudeCode","pilotState":"notPiloted","hasActiveDependents":true,"metricHistory":[],"state":{"idle":{}},"createdAt":0,"subGraph":{"id":"33333333-3333-4333-8333-333333333333","project":{"path":"C:\\work\\nested","name":"Nested","lastOpenedAt":0},"nodes":[],"edges":[]}}],"edges":[]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    defer parsed.deinit();
    stripRuntimeFields(&parsed.value);
    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();
    try output.writer().print("{f}", .{std.json.fmt(parsed.value, .{})});
    try std.testing.expect(std.mem.indexOf(u8, output.items, "hasActiveDependents") == null);
}

test "subgraph canonicalization maps nested composite aliases to Swift proactive" {
    const allocator = std.testing.allocator;
    const input =
        \\{"id":"11111111-1111-4111-8111-111111111111","project":{"path":"C:\\work\\graph","name":"Graph","lastOpenedAt":0},"nodes":[{"id":"22222222-2222-4222-8222-222222222222","title":"Composite","loopType":"composite","pausesBeforeWritesOnly":false,"backend":"claudeCode","pilotState":"notPiloted","hasActiveDependents":false,"metricHistory":[],"state":{"idle":{}},"createdAt":0,"subGraph":{"id":"33333333-3333-4333-8333-333333333333","project":{"path":"C:\\work\\nested","name":"Nested","lastOpenedAt":0},"nodes":[{"id":"44444444-4444-4444-8444-444444444444","title":"Nested composite","loopType":"composite","pausesBeforeWritesOnly":false,"backend":"copilotCLI","pilotState":"notPiloted","hasActiveDependents":false,"metricHistory":[],"state":{"idle":{}},"createdAt":0}],"edges":[]}}],"edges":[]}
    ;
    const canonical = try safeSubgraphJson(allocator, input);
    defer allocator.free(canonical);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "\"loopType\":\"proactive\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "\"loopType\":\"composite\"") == null);
}

fn goalJson(allocator: std.mem.Allocator, draft: Forms.NodeDraft) ![]u8 {
    if (draft.goal_summary.len == 0) return allocator.dupe(u8, "null");
    const summary = try quoteJson(allocator, draft.goal_summary); defer allocator.free(summary);
    const predicate = try nullableString(allocator, draft.goal_predicate); defer allocator.free(predicate);
    const stall = if (draft.stall_after_seconds) |value|
        try std.fmt.allocPrint(allocator, "{d}", .{value})
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(stall);
    const metric = try nullableString(allocator, draft.metric_command); defer allocator.free(metric);
    const direction = try quoteJson(allocator, if (draft.metric_direction.len == 0) "maximize" else draft.metric_direction);
    defer allocator.free(direction);
    return std.fmt.allocPrint(allocator,
        "{{\"summary\":{s},\"predicate\":{s},\"pollIntervalSeconds\":{d},\"stallAfterSeconds\":{s},\"metricCommand\":{s},\"metricDirection\":{s}}}",
        .{ summary, predicate, draft.poll_interval_seconds, stall, metric, direction });
}

fn worktreeJson(allocator: std.mem.Allocator, draft: Forms.NodeDraft) ![]u8 {
    if (draft.worktree_repository.len == 0 and draft.worktree_path.len == 0 and draft.worktree_branch.len == 0)
        return allocator.dupe(u8, "null");
    const repo = try quoteJson(allocator, draft.worktree_repository); defer allocator.free(repo);
    const id = try quoteJson(allocator, if (draft.worktree_id.len == 0) draft.worktree_branch else draft.worktree_id); defer allocator.free(id);
    const path = try quoteJson(allocator, draft.worktree_path); defer allocator.free(path);
    const branch = try quoteJson(allocator, draft.worktree_branch); defer allocator.free(branch);
    return std.fmt.allocPrint(allocator,
        "{{\"id\":{s},\"repositoryPath\":{s},\"worktreePath\":{s},\"branch\":{s}}}",
        .{ id, repo, path, branch });
}

pub fn commandGraphNodeAction(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    node_id: []const u8,
    action: []const u8,
    text: ?[]const u8,
) ![]u8 {
    const quoted_path = try quoteJson(allocator, project_path);
    defer allocator.free(quoted_path);
    const quoted_node = try quoteJson(allocator, node_id);
    defer allocator.free(quoted_node);
    if (std.mem.eql(u8, action, "messageNode")) {
        const quoted_text = try quoteJson(allocator, text orelse "");
        defer allocator.free(quoted_text);
        return std.mem.concat(allocator, u8, &.{
            "{\"graphCommand\":{\"projectPath\":",
            quoted_path,
            ",\"command\":{\"messageNode\":{\"_0\":",
            quoted_node,
            ",\"text\":",
            quoted_text,
            ",\"from\":null}}}}",
        });
    }

    if (std.mem.eql(u8, action, "stopNode")) {
        return std.mem.concat(allocator, u8, &.{
            "{\"graphCommand\":{\"projectPath\":",
            quoted_path,
            ",\"command\":{\"stopNode\":{\"_0\":",
            quoted_node,
            "}}}}",
        });
    }
    return error.UnsupportedGraphAction;
}

pub fn commandGraphRenameNode(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    node_id: []const u8,
    title: []const u8,
) ![]u8 {
    const quoted_path = try quoteJson(allocator, project_path);
    defer allocator.free(quoted_path);
    const quoted_node = try quoteJson(allocator, node_id);
    defer allocator.free(quoted_node);
    const quoted_title = try quoteJson(allocator, title);
    defer allocator.free(quoted_title);
    return std.mem.concat(allocator, u8, &.{
        "{\"graphCommand\":{\"projectPath\":",   quoted_path,
        ",\"command\":{\"renameNode\":{\"_0\":", quoted_node,
        ",\"title\":",                           quoted_title,
        "}}}}",
    });
}

pub fn commandGraphCreateEdge(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    from: []const u8,
    to: []const u8,
    kind: []const u8,
) ![]u8 {
    const quoted_path = try quoteJson(allocator, project_path);
    defer allocator.free(quoted_path);
    const quoted_from = try quoteJson(allocator, from);
    defer allocator.free(quoted_from);
    const quoted_to = try quoteJson(allocator, to);
    defer allocator.free(quoted_to);
    const quoted_kind = try quoteJson(allocator, kind);
    defer allocator.free(quoted_kind);
    return std.mem.concat(allocator, u8, &.{
        "{\"graphCommand\":{\"projectPath\":",                                                                                   quoted_path,
        ",\"command\":{\"createEdge\":{\"from\":",                                                                               quoted_from,
        ",\"to\":",                                                                                                              quoted_to,
        ",\"spec\":{\"kind\":",                                                                                                  quoted_kind,
        ",\"condition\":\"always\",\"payloadTransform\":{\"none\":{}},\"cycleGuard\":null,\"spawnTargetProjectPath\":null}}}}}",
    });
}

pub fn commandGraphCreateEdgeFull(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    from: []const u8,
    to: []const u8,
    draft: Forms.EdgeDraft,
) ![]u8 {
    const path = try quoteJson(allocator, project_path); defer allocator.free(path);
    const source = try quoteJson(allocator, from); defer allocator.free(source);
    const target = try quoteJson(allocator, to); defer allocator.free(target);
    const kind = try quoteJson(allocator, draft.kind); defer allocator.free(kind);
    const condition = try quoteJson(allocator, draft.condition); defer allocator.free(condition);
    const transform_value = if (std.mem.eql(u8, draft.transform_kind, "none"))
        try allocator.dupe(u8, "{}")
    else blk: {
        const quoted = try quoteJson(allocator, draft.transform_value);
        defer allocator.free(quoted);
        break :blk try std.fmt.allocPrint(allocator, "{{\"_0\":{s}}}", .{quoted});
    };
    defer allocator.free(transform_value);
    const transform = try std.fmt.allocPrint(allocator, "{{\"{s}\":{s}}}", .{draft.transform_kind, transform_value});
    defer allocator.free(transform);
    const cycle = if (draft.cycle_max_iterations == null and draft.cycle_until.len == 0 and
        draft.cycle_stop_after_passes == null)
        try allocator.dupe(u8, "null")
    else blk: {
        const until = try nullableString(allocator, draft.cycle_until); defer allocator.free(until);
        const max = if (draft.cycle_max_iterations) |value| try std.fmt.allocPrint(allocator, "{d}", .{value}) else try allocator.dupe(u8, "null");
        defer allocator.free(max);
        const flat = if (draft.cycle_stop_after_passes) |value| try std.fmt.allocPrint(allocator, "{d}", .{value}) else try allocator.dupe(u8, "null");
        defer allocator.free(flat);
        break :blk try std.fmt.allocPrint(allocator,
            "{{\"maxIterations\":{s},\"until\":{s},\"stopAfterPassesWithoutImprovement\":{s}}}",
            .{max, until, flat});
    };
    defer allocator.free(cycle);
    const spawn = try nullableString(allocator, draft.spawn_target_project_path); defer allocator.free(spawn);
    return std.mem.concat(allocator, u8, &.{
        "{\"graphCommand\":{\"projectPath\":", path, ",\"command\":{\"createEdge\":{\"from\":",
        source, ",\"to\":", target, ",\"spec\":{\"kind\":", kind, ",\"condition\":", condition,
        ",\"payloadTransform\":", transform, ",\"cycleGuard\":", cycle,
        ",\"spawnTargetProjectPath\":", spawn, "}}}}}",
    });
}

pub fn commandGraphDeleteEdge(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    edge_id: []const u8,
) ![]u8 {
    const quoted_path = try quoteJson(allocator, project_path);
    defer allocator.free(quoted_path);
    const quoted_edge = try quoteJson(allocator, edge_id);
    defer allocator.free(quoted_edge);
    return std.mem.concat(allocator, u8, &.{
        "{\"graphCommand\":{\"projectPath\":",   quoted_path,
        ",\"command\":{\"deleteEdge\":{\"_0\":", quoted_edge,
        "}}}}",
    });
}

pub fn commandGraphDeleteNode(allocator: std.mem.Allocator, project_path: []const u8, node_id: []const u8) ![]u8 {
    return graphUnaryUUID(allocator, project_path, "deleteNode", node_id);
}

pub fn commandGraphPilotComposite(allocator: std.mem.Allocator, project_path: []const u8, node_id: []const u8) ![]u8 {
    return graphUnaryUUID(allocator, project_path, "pilotComposite", node_id);
}

pub fn commandGraphArmComposite(allocator: std.mem.Allocator, project_path: []const u8, node_id: []const u8) ![]u8 {
    return graphUnaryUUID(allocator, project_path, "armComposite", node_id);
}

pub fn commandGraphRefreshUsage(allocator: std.mem.Allocator, project_path: []const u8) ![]u8 {
    const path = try quoteJson(allocator, project_path); defer allocator.free(path);
    return std.fmt.allocPrint(allocator,
        "{{\"graphCommand\":{{\"projectPath\":{s},\"command\":{{\"refreshUsage\":{{}}}}}}}}", .{path});
}

fn graphUnaryUUID(allocator: std.mem.Allocator, project_path: []const u8, name: []const u8, node_id: []const u8) ![]u8 {
    const path = try quoteJson(allocator, project_path); defer allocator.free(path);
    const id = try quoteJson(allocator, node_id); defer allocator.free(id);
    return std.fmt.allocPrint(allocator,
        "{{\"graphCommand\":{{\"projectPath\":{s},\"command\":{{\"{s}\":{{\"_0\":{s}}}}}}}}}", .{path, name, id});
}

pub fn commandGraphUpdateNode(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    node_id: []const u8,
    update_json: []const u8,
) ![]u8 {
    const path = try quoteJson(allocator, project_path); defer allocator.free(path);
    const id = try quoteJson(allocator, node_id); defer allocator.free(id);
    return std.fmt.allocPrint(allocator,
        "{{\"graphCommand\":{{\"projectPath\":{s},\"command\":{{\"updateNode\":{{\"_0\":{s},\"update\":{s}}}}}}}}}", .{path, id, update_json});
}

pub fn commandGraphUpdateNodeForm(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    node_id: []const u8,
    update: Forms.NodeUpdate,
) ![]u8 {
    const json = try nodeUpdateJson(allocator, update);
    defer allocator.free(json);
    return commandGraphUpdateNode(allocator, project_path, node_id, json);
}

fn nodeUpdateJson(allocator: std.mem.Allocator, update: Forms.NodeUpdate) ![]u8 {
    const summary = if (update.goal_summary) |value| try quoteJson(allocator, value) else try allocator.dupe(u8, "null");
    defer allocator.free(summary);
    const predicate = if (update.goal_predicate) |value| try quoteJson(allocator, value) else try allocator.dupe(u8, "null");
    defer allocator.free(predicate);
    const poll = if (update.poll_interval_seconds) |value| try std.fmt.allocPrint(allocator, "{d}", .{value}) else try allocator.dupe(u8, "null");
    defer allocator.free(poll);
    const stall = if (update.stall_after_seconds) |value| try std.fmt.allocPrint(allocator, "{d}", .{value}) else try allocator.dupe(u8, "null");
    defer allocator.free(stall);
    const metric = if (update.metric_command) |value| try quoteJson(allocator, value) else try allocator.dupe(u8, "null");
    defer allocator.free(metric);
    const direction = if (update.metric_direction) |value| try quoteJson(allocator, value) else try allocator.dupe(u8, "null");
    defer allocator.free(direction);
    const trigger = if (update.trigger_prompt) |value| try quoteJson(allocator, value) else try allocator.dupe(u8, "null");
    defer allocator.free(trigger);
    const check = if (update.check_description) |value| try quoteJson(allocator, value) else try allocator.dupe(u8, "null");
    defer allocator.free(check);
    const tier = if (update.model_tier) |value| try quoteJson(allocator, value) else try allocator.dupe(u8, "null");
    defer allocator.free(tier);
    return std.fmt.allocPrint(allocator,
        "{{\"goalSummary\":{s},\"goalPredicate\":{s},\"pollIntervalSeconds\":{s},\"stallAfterSeconds\":{s},\"metricCommand\":{s},\"metricDirection\":{s},\"triggerPrompt\":{s},\"checkDescription\":{s},\"modelTier\":{s},\"updatedBy\":null}}",
        .{summary, predicate, poll, stall, metric, direction, trigger, check, tier});
}

pub fn commandGraphMemoNode(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    node_id: []const u8,
    text: []const u8,
    from: ?[]const u8,
) ![]u8 {
    const path = try quoteJson(allocator, project_path); defer allocator.free(path);
    const id = try quoteJson(allocator, node_id); defer allocator.free(id);
    const memo = try quoteJson(allocator, text); defer allocator.free(memo);
    const origin = if (from) |value| try quoteJson(allocator, value) else try allocator.dupe(u8, "null");
    defer allocator.free(origin);
    return std.fmt.allocPrint(allocator,
        "{{\"graphCommand\":{{\"projectPath\":{s},\"command\":{{\"memoNode\":{{\"_0\":{s},\"text\":{s},\"from\":{s}}}}}}}}}", .{path, id, memo, origin});
}

pub fn commandGraphSubGraph(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    node_id: []const u8,
    nested_command_json: []const u8,
) ![]u8 {
    const path = try quoteJson(allocator, project_path); defer allocator.free(path);
    const id = try quoteJson(allocator, node_id); defer allocator.free(id);
    return std.fmt.allocPrint(allocator,
        "{{\"graphCommand\":{{\"projectPath\":{s},\"command\":{{\"subGraphCommand\":{{\"nodeID\":{s},\"command\":{s}}}}}}}}}", .{path, id, nested_command_json});
}

fn quoteJson(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var size: usize = 2;
    for (value) |byte| {
        size += switch (byte) {
            '"', '\\' => 2,
            0...0x1f => switch (byte) {
                '\n', '\r', '\t', '\x08', '\x0c' => 2,
                else => 6,
            },
            else => 1,
        };
    }
    const quoted = try allocator.alloc(u8, size);
    var cursor: usize = 0;
    quoted[cursor] = '"';
    cursor += 1;
    for (value) |byte| {
        switch (byte) {
            '"' => {
                quoted[cursor] = '\\';
                quoted[cursor + 1] = '"';
                cursor += 2;
            },
            '\\' => {
                quoted[cursor] = '\\';
                quoted[cursor + 1] = '\\';
                cursor += 2;
            },
            0...0x1f => {
                switch (byte) {
                    '\n' => {
                        quoted[cursor] = '\\';
                        quoted[cursor + 1] = 'n';
                        cursor += 2;
                    },
                    '\r' => {
                        quoted[cursor] = '\\';
                        quoted[cursor + 1] = 'r';
                        cursor += 2;
                    },
                    '\t' => {
                        quoted[cursor] = '\\';
                        quoted[cursor + 1] = 't';
                        cursor += 2;
                    },
                    '\x08' => {
                        quoted[cursor] = '\\';
                        quoted[cursor + 1] = 'b';
                        cursor += 2;
                    },
                    '\x0c' => {
                        quoted[cursor] = '\\';
                        quoted[cursor + 1] = 'f';
                        cursor += 2;
                    },
                    else => {
                        const digits = "0123456789abcdef";
                        quoted[cursor] = '\\';
                        quoted[cursor + 1] = 'u';
                        quoted[cursor + 2] = '0';
                        quoted[cursor + 3] = '0';
                        quoted[cursor + 4] = digits[byte >> 4];
                        quoted[cursor + 5] = digits[byte & 0x0f];
                        cursor += 6;
                    },
                }
            },
            else => {
                quoted[cursor] = byte;
                cursor += 1;
            },
        }
    }
    quoted[cursor] = '"';
    return quoted;
}

pub fn decodeJsonString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] != '\\') {
            try result.append(value[index]);
            index += 1;
            continue;
        }
        index += 1;
        if (index >= value.len) return error.MalformedJsonString;
        switch (value[index]) {
            '"', '\\', '/' => try result.append(value[index]),
            'b' => try result.append('\x08'),
            'f' => try result.append('\x0c'),
            'n' => try result.append('\n'),
            'r' => try result.append('\r'),
            't' => try result.append('\t'),
            'u' => {
                if (index + 4 >= value.len) return error.MalformedJsonString;
                const high = try parseHexQuad(value[index + 1 .. index + 5]);
                index += 4;
                var codepoint: u21 = high;
                if (high >= 0xd800 and high <= 0xdbff and
                    index + 6 < value.len and value[index + 1] == '\\' and value[index + 2] == 'u')
                {
                    const low = try parseHexQuad(value[index + 3 .. index + 7]);
                    if (low >= 0xdc00 and low <= 0xdfff) {
                        codepoint = 0x10000 + (@as(u21, high - 0xd800) << 10) + (low - 0xdc00);
                        index += 6;
                    }
                }
                var encoded: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(codepoint, &encoded) catch
                    return error.MalformedJsonString;
                try result.appendSlice(encoded[0..length]);
            },
            else => return error.MalformedJsonString,
        }
        index += 1;
    }
    return result.toOwnedSlice();
}

fn parseHexQuad(bytes: []const u8) !u16 {
    if (bytes.len != 4) return error.MalformedJsonString;
    var value: u16 = 0;
    for (bytes) |byte| {
        value = (value << 4) | (hexDigit(byte) orelse return error.MalformedJsonString);
    }
    return value;
}

fn hexDigit(byte: u8) ?u16 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

pub fn jsonString(data: []const u8, key: []const u8) ?[]const u8 {
    var needle_buffer: [128]u8 = undefined;
    if (key.len + 3 > needle_buffer.len) return null;
    needle_buffer[0] = '"';
    @memcpy(needle_buffer[1 .. key.len + 1], key);
    needle_buffer[key.len + 1] = '"';
    needle_buffer[key.len + 2] = ':';
    const needle = needle_buffer[0 .. key.len + 3];
    const start = std.mem.indexOf(u8, data, needle) orelse return null;
    var cursor = start + needle.len;
    while (cursor < data.len and (data[cursor] == ' ' or data[cursor] == '\t')) : (cursor += 1) {}
    if (cursor >= data.len or data[cursor] != '"') return null;
    cursor += 1;
    const value_start = cursor;
    var escaped = false;
    while (cursor < data.len) : (cursor += 1) {
        if (escaped) {
            escaped = false;
            continue;
        }

        if (data[cursor] == '\\') {
            escaped = true;
            continue;
        }
        if (data[cursor] == '"') return data[value_start..cursor];
    }
    return null;
}

pub fn copyGraphChangedProjectPath(allocator: std.mem.Allocator, data: []const u8) !?[]u8 {
    const graph_start = std.mem.indexOf(u8, data, "\"graphChanged\"") orelse return null;
    const project_start = std.mem.indexOf(u8, data[graph_start..], "\"project\"") orelse return null;
    const project = data[graph_start + project_start..];
    const raw = jsonString(project, "path") orelse return null;
    return try decodeJsonString(allocator, raw);
}

pub fn isCurrentGraphPath(pending: []const u8, accepted: []const u8, path: []const u8) bool {
    return pending.len == 0 or std.mem.eql(u8, path, pending) or std.mem.eql(u8, path, accepted);
}

pub fn jsonNumber(data: []const u8, key: []const u8) ?u64 {
    var needle_buffer: [128]u8 = undefined;
    if (key.len + 3 > needle_buffer.len) return null;
    needle_buffer[0] = '"';
    @memcpy(needle_buffer[1 .. key.len + 1], key);
    needle_buffer[key.len + 1] = '"';
    needle_buffer[key.len + 2] = ':';
    const needle = needle_buffer[0 .. key.len + 3];
    const start = std.mem.indexOf(u8, data, needle) orelse return null;
    var cursor = start + needle.len;
    while (cursor < data.len and (data[cursor] == ' ' or data[cursor] == '\t')) : (cursor += 1) {}
    const value_start = cursor;
    while (cursor < data.len and data[cursor] >= '0' and data[cursor] <= '9') : (cursor += 1) {}
    return std.fmt.parseInt(u64, data[value_start..cursor], 10) catch null;
}

pub fn copyErrorMessage(allocator: std.mem.Allocator, data: []const u8) !?[]u8 {
    const raw = jsonString(data, "message") orelse
        (jsonString(data, "errorOccurred") orelse return null);
    return try decodeJsonString(allocator, raw);
}

test "JSON strings round-trip control characters and unicode" {
    const allocator = std.testing.allocator;
    const value = "quote \" slash \\ line\nsnowman ☃";
    const quoted = try quoteJson(allocator, value);
    defer allocator.free(quoted);
    const decoded = try decodeJsonString(allocator, quoted[1 .. quoted.len - 1]);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings(value, decoded);
}

test "graph project paths are extracted for open ordering" {
    const graph =
        "{\"event\":{\"graphChanged\":{\"project\":{\"path\":\"C:\\\\work\\\\C\"}}}}";
    const graph_path = (try copyGraphChangedProjectPath(std.testing.allocator, graph)).?;
    defer std.testing.allocator.free(graph_path);
    try std.testing.expectEqualStrings("C:\\work\\C", graph_path);
}

test "superseding open ordering keeps A and ignores late B" {
    const accepted = "C:\\work\\A";
    const pending_b = "C:\\work\\B";
    const pending_c = "C:\\work\\C";
    try std.testing.expect(!isCurrentGraphPath(pending_c, accepted, pending_b));
    try std.testing.expect(isCurrentGraphPath(pending_c, accepted, pending_c));
    const rollback_target = accepted;
    try std.testing.expectEqualStrings("C:\\work\\A", rollback_target);
}

test "real request IDs reject late B errors while C is current" {
    const request_b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    const request_c = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
    const late_b =
        "{\"version\":2,\"kind\":\"response\",\"requestID\":\"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb\",\"event\":{\"errorOccurred\":\"B rejected\"}}";
    const current_c =
        "{\"version\":2,\"kind\":\"response\",\"requestID\":\"cccccccc-cccc-4ccc-8ccc-cccccccccccc\",\"event\":{\"errorOccurred\":\"C rejected\"}}";
    try std.testing.expect(!std.mem.eql(u8, responseRequestID(late_b).?, request_c));
    try std.testing.expectEqualStrings(request_c, responseRequestID(current_c).?);
    try std.testing.expectEqualStrings(request_b, responseRequestID(late_b).?);
}

test "frame limits follow protocol mode" {
    const payload = try std.testing.allocator.alloc(u8, v2_max_payload + 1);
    defer std.testing.allocator.free(payload);
    try std.testing.expectError(error.PayloadTooLarge, frameLength(payload, .v2));
    const header = try frameLength(payload, .v1);
    try std.testing.expectEqual(@as(u8, 1), header[3]);
}

test "v2 hello omits subscription for the no-filter case" {
    const allocator = std.testing.allocator;
    const hello = try v2Hello(allocator, "00000000-0000-4000-8000-000000000001", null, "");
    defer allocator.free(hello);
    try std.testing.expectEqualStrings(
        "{\"version\":2,\"kind\":\"hello\",\"supportedVersions\":[1,2],\"clientID\":\"00000000-0000-4000-8000-000000000001\"}",
        hello,
    );
    const subscribed = try v2Hello(
        allocator,
        "00000000-0000-4000-8000-000000000001",
        9,
        "C:\\work\\graph",
    );
    defer allocator.free(subscribed);
    try std.testing.expectEqualStrings(
        "{\"version\":2,\"kind\":\"hello\",\"supportedVersions\":[1,2],\"clientID\":\"00000000-0000-4000-8000-000000000001\",\"resumeFrom\":9,\"subscription\":{\"projectPaths\":[\"C:\\\\work\\\\graph\"]}}",
        subscribed,
    );
}

test "graph commands match Swift Codable associated-value shapes" {
    const allocator = std.testing.allocator;
    const project = "C:\\work\\graph";
    const node = "11111111-1111-4111-8111-111111111111";
    const create = try commandGraphCreateNode(
        allocator,
        project,
        "Windows shell node",
        node,
    );
    defer allocator.free(create);
    try std.testing.expectEqualStrings(
        "{\"graphCommand\":{\"projectPath\":\"C:\\\\work\\\\graph\",\"command\":{\"createNode\":{\"_0\":{\"id\":\"11111111-1111-4111-8111-111111111111\",\"title\":\"Windows shell node\",\"loopType\":\"turnBased\",\"checkDescription\":null,\"triggerPrompt\":null,\"firstInstruction\":\"Work on the requested Windows shell task.\",\"pausesBeforeWritesOnly\":false,\"goal\":null,\"backend\":\"claudeCode\",\"modelTier\":null,\"worktree\":null,\"subGraph\":null,\"createdBy\":null}}}}}",
        create,
    );
    const message = try commandGraphNodeAction(allocator, project, node, "messageNode", "hello");
    defer allocator.free(message);
    try std.testing.expectEqualStrings(
        "{\"graphCommand\":{\"projectPath\":\"C:\\\\work\\\\graph\",\"command\":{\"messageNode\":{\"_0\":\"11111111-1111-4111-8111-111111111111\",\"text\":\"hello\",\"from\":null}}}}",
        message,
    );
    const stop = try commandGraphNodeAction(allocator, project, node, "stopNode", null);
    defer allocator.free(stop);
    try std.testing.expectEqualStrings(
        "{\"graphCommand\":{\"projectPath\":\"C:\\\\work\\\\graph\",\"command\":{\"stopNode\":{\"_0\":\"11111111-1111-4111-8111-111111111111\"}}}}",
        stop,
    );
    try std.testing.expectError(
        error.UnsupportedGraphAction,
        commandGraphNodeAction(allocator, project, node, "deleteNode", null),
    );
    const rename = try commandGraphRenameNode(allocator, project, node, "Renamed");
    defer allocator.free(rename);
    try std.testing.expect(std.mem.indexOf(u8, rename, "\"renameNode\"") != null);
    const edge = try commandGraphCreateEdge(allocator, project, node, "22222222-2222-4222-8222-222222222222", "handoff");
    defer allocator.free(edge);
    try std.testing.expectEqualStrings(
        "{\"graphCommand\":{\"projectPath\":\"C:\\\\work\\\\graph\",\"command\":{\"createEdge\":{\"from\":\"11111111-1111-4111-8111-111111111111\",\"to\":\"22222222-2222-4222-8222-222222222222\",\"spec\":{\"kind\":\"handoff\",\"condition\":\"always\",\"payloadTransform\":{\"none\":{}},\"cycleGuard\":null,\"spawnTargetProjectPath\":null}}}}}",
        edge,
    );
    const delete = try commandGraphDeleteEdge(allocator, project, "33333333-3333-4333-8333-333333333333");
    defer allocator.free(delete);
    try std.testing.expectEqualStrings(
        "{\"graphCommand\":{\"projectPath\":\"C:\\\\work\\\\graph\",\"command\":{\"deleteEdge\":{\"_0\":\"33333333-3333-4333-8333-333333333333\"}}}}",
        delete,
    );
}

test "global overview command uses the daemon command shape" {
    const command = try commandOpenGlobalGraph(std.testing.allocator);
    defer std.testing.allocator.free(command);
    try std.testing.expectEqualStrings("{\"openGlobalGraph\":{}}", command);
}

test "project lifecycle commands preserve Swift Codable labels" {
    const allocator = std.testing.allocator;
    const close = try commandCloseProject(allocator, "C:\\work\\graph");
    defer allocator.free(close);
    try std.testing.expectEqualStrings("{\"closeProject\":{\"path\":\"C:\\\\work\\\\graph\"}}", close);
    const forget = try commandForgetProject(allocator, "C:\\work\\graph");
    defer allocator.free(forget);
    try std.testing.expectEqualStrings("{\"forgetProject\":{\"path\":\"C:\\\\work\\\\graph\"}}", forget);
    const delete = try commandDeleteProjectGraph(allocator, "C:\\work\\graph");
    defer allocator.free(delete);
    try std.testing.expectEqualStrings("{\"deleteProjectGraph\":{\"path\":\"C:\\\\work\\\\graph\"}}", delete);
}

test "typed node and edge forms retain every supported field on the wire" {
    const allocator = std.testing.allocator;
    const node = try commandGraphCreateNodeFull(allocator, "C:\\work\\graph", "11111111-1111-4111-8111-111111111111", .{
        .title = "Goal",
        .loop_type = "goalBased",
        .goal_summary = "Done",
        .goal_predicate = "test -f done",
        .poll_interval_seconds = 15,
        .stall_after_seconds = 0,
        .metric_command = "metric",
        .metric_direction = "minimize",
        .backend = "codex",
        .model_tier = "capable",
        .worktree_repository = "C:\\repo",
        .worktree_id = "wt",
        .worktree_path = "C:\\repo-wt",
        .worktree_branch = "feature",
        .subgraph_json = "{\"id\":\"33333333-3333-4333-8333-333333333333\",\"project\":{\"path\":\"C:\\\\work\\\\subgraph\",\"name\":\"subgraph\",\"lastOpenedAt\":1767225600},\"nodes\":[],\"edges\":[]}",
        .created_by = "11111111-1111-4111-8111-111111111111",
    });
    defer allocator.free(node);
    for ([_][]const u8{ "\"summary\":\"Done\"", "\"predicate\":\"test -f done\"", "pollIntervalSeconds", "stallAfterSeconds", "metricCommand", "metricDirection", "codex", "capable", "repositoryPath", "worktreePath", "feature", "\"nodes\":[]", "\"createdBy\":\"11111111-1111-4111-8111-111111111111\"" }) |field| {
        try std.testing.expect(std.mem.indexOf(u8, node, field) != null);
    }
    const inherited = try commandGraphCreateNodeFull(allocator, "C:\\work\\graph", "11111111-1111-4111-8111-111111111111", .{
        .title = "Inherited",
        .backend = null,
    });
    defer allocator.free(inherited);
    try std.testing.expect(std.mem.indexOf(u8, inherited, "\"backend\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, inherited, "\"createdBy\":null") != null);
    const edge = try commandGraphCreateEdgeFull(allocator, "C:\\work\\graph", "a", "b", .{
        .from = "a",
        .to = "b",
        .kind = "spawn",
        .condition = "onFailure",
        .transform_kind = "template",
        .transform_value = "payload",
        .cycle_max_iterations = 3,
        .spawn_target_project_path = "C:\\other",
    });
    defer allocator.free(edge);
    for ([_][]const u8{ "onFailure", "template", "payload", "maxIterations", "spawnTargetProjectPath" }) |field|
        try std.testing.expect(std.mem.indexOf(u8, edge, field) != null);
}

test "v2 edge fixtures exactly match Zig-generated request envelopes" {
    const allocator = std.testing.allocator;
    const create_inner = try commandGraphCreateEdge(
        allocator,
        "C:\\work\\graph",
        "11111111-1111-4111-8111-111111111111",
        "22222222-2222-4222-8222-222222222222",
        "handoff",
    );
    defer allocator.free(create_inner);
    const create = try v2Request(
        allocator,
        "00000000-0000-4000-8000-000000000005",
        create_inner,
    );
    defer allocator.free(create);
    const expected_create = try std.fs.cwd().readFileAlloc(
        allocator,
        "fixtures/daemon-v2-create-edge.json",
        16 * 1024,
    );
    defer allocator.free(expected_create);
    try std.testing.expectEqualStrings(expected_create, create);

    const delete_inner = try commandGraphDeleteEdge(
        allocator,
        "C:\\work\\graph",
        "33333333-3333-4333-8333-333333333333",
    );
    defer allocator.free(delete_inner);
    const delete = try v2Request(
        allocator,
        "00000000-0000-4000-8000-000000000006",
        delete_inner,
    );
    defer allocator.free(delete);
    const expected_delete = try std.fs.cwd().readFileAlloc(
        allocator,
        "fixtures/daemon-v2-delete-edge.json",
        16 * 1024,
    );
    defer allocator.free(expected_delete);
    try std.testing.expectEqualStrings(expected_delete, delete);
}
