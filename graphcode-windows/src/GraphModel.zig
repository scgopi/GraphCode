const std = @import("std");
const Wire = @import("Wire.zig");
const WorktreeStatus = @import("WorktreeStatus.zig");
pub const WorktreeSummary = WorktreeStatus.Summary;

pub const Node = struct {
    id: []u8,
    title: []u8,
    loop_type: []u8,
    state: []u8,
    activity: []u8,
    presence: []u8,
    backend: []u8 = &.{},
    pilot_state: []u8 = &.{},
    goal_summary: []u8 = &.{},
    goal_predicate: []u8 = &.{},
    metric_command: []u8 = &.{},
    metric_direction: []u8 = &.{},
    trigger_prompt: []u8 = &.{},
    check_description: []u8 = &.{},
    model_tier: []u8 = &.{},
    poll_interval_seconds: ?f64 = null,
    stall_after_seconds: ?f64 = null,
    created_at: ?u64 = null,
    metric_passes: u32 = 0,
    metric_samples: [8]f64 = [_]f64{0} ** 8,
    metric_sample_count: u8 = 0,
    token_usage: ?u32 = null,
    worktree_path: []u8 = @constCast(""),
    worktree_branch: []u8 = &.{},
    subgraph_json: []u8 = &.{},
    follows_template: bool = false,
};

pub const ActivityEvent = struct {
    title: []u8,
    state: []u8,
    project_path: []u8 = &.{},
    node_id: []u8 = &.{},
    timestamp: i64 = 0,
};

pub const QuickChat = struct {
    id: []u8,
    title: []u8,
    backend: []u8,
    activity: []u8 = &.{},
    activity_sequence: u64 = 0,
};

pub const Edge = struct {
    id: []u8 = &.{},
    from: []u8,
    to: []u8,
    kind: []u8 = &.{},
    condition: []u8 = @constCast("always"),
    blocks_target: bool = true,
    fired: bool = false,
    fire_count: u32 = 0,
};

pub const Project = struct {
    path: []u8,
    name: []u8,

    /// Both remote schemes count: a Codespace is `codespace://<name><path>` rather
    /// than `ssh://`, because gh's tunnel — not a host ssh can dial — owns the
    /// connection. Everything above the dial treats the two identically, which is why
    /// the sidebar, canvas, and terminal chrome all branch on this one predicate.
    pub fn isRemote(self: Project) bool {
        return std.mem.startsWith(u8, self.path, "ssh://") or
            std.mem.startsWith(u8, self.path, "codespace://");
    }

    pub fn isCodespace(self: Project) bool {
        return std.mem.startsWith(u8, self.path, "codespace://");
    }

    pub fn isGlobal(self: Project) bool {
        return std.mem.eql(u8, self.path, "graphcode://global");
    }

    pub fn isLocalFilesystem(self: Project) bool {
        return !self.isRemote() and !self.isGlobal() and std.mem.indexOf(u8, self.path, "://") == null;
    }
};

pub const Graph = struct {
    project: Project,
    nodes: std.array_list.Managed(Node),
    edges: std.array_list.Managed(Edge),
};

pub const AttentionEntry = struct {
    project_path: []u8,
    node: Node,
};

pub const GraphGeneration = struct {
    project_path: []u8,
    generation: u64,
};

pub const LifecycleAction = enum {
    select,
    close,
    forget,
    delete,
};

pub const LifecycleRequest = struct {
    action: LifecycleAction,
    project_path: []const u8,
};

pub const LifecycleCallback = *const fn (context: ?*anyopaque, request: LifecycleRequest) void;

pub const RestoreState = enum {
    cold,
    restoring,
    restored,
    reconnecting,
};

const LifecycleProbe = struct {
    path: [64]u8 = undefined,
    path_len: usize = 0,
    called: bool = false,
};

fn lifecycleProbeCallback(context: ?*anyopaque, request: LifecycleRequest) void {
    const probe: *LifecycleProbe = @ptrCast(@alignCast(context.?));
    probe.path_len = request.project_path.len;
    @memcpy(probe.path[0..probe.path_len], request.project_path);
    probe.called = true;
}

fn worktreeBindingFactsDiffer(before: Node, after: Node) bool {
    return !std.mem.eql(u8, before.worktree_path, after.worktree_path) or
        !std.mem.eql(u8, before.worktree_branch, after.worktree_branch) or
        !std.mem.eql(u8, before.state, after.state) or
        !std.mem.eql(u8, before.loop_type, after.loop_type);
}

fn uniqueWorktreeNodeIndex(nodes: []const Node, id: []const u8) !?usize {
    if (id.len == 0) return error.AmbiguousWorktreeNode;
    var found: ?usize = null;
    for (nodes, 0..) |node, index| {
        if (!std.mem.eql(u8, node.id, id)) continue;
        if (found != null) return error.AmbiguousWorktreeNode;
        found = index;
    }
    return found;
}

fn flatWorktreeBindingsChanged(previous: []const Node, next: []const Node) !bool {
    for (previous) |node| {
        if (node.worktree_path.len == 0) continue;
        _ = try uniqueWorktreeNodeIndex(previous, node.id);
        const index = (try uniqueWorktreeNodeIndex(next, node.id)) orelse return true;
        if (worktreeBindingFactsDiffer(node, next[index])) return true;
    }
    for (next) |node| {
        if (node.worktree_path.len == 0) continue;
        _ = try uniqueWorktreeNodeIndex(next, node.id);
        const index = (try uniqueWorktreeNodeIndex(previous, node.id)) orelse return true;
        if (worktreeBindingFactsDiffer(previous[index], node)) return true;
    }
    return false;
}

const WorktreeBindingComparison = struct {
    const max_depth = 32;
    const max_items = 4096;
    const max_json_work = 2 * Wire.legacy_max_payload;
    const max_scratch = 8 * Wire.legacy_max_payload;

    allocator: std.mem.Allocator,
    project: Project,
    remaining_items: usize = max_items,
    remaining_json: usize = max_json_work,

    fn consumeItems(self: *@This(), count: usize) !void {
        if (count > self.remaining_items) return error.WorktreeComparisonLimit;
        self.remaining_items -= count;
    }

    fn indexNodes(self: *@This(), nodes: []const Node) !std.StringHashMap(usize) {
        var indices = std.StringHashMap(usize).init(self.allocator);
        errdefer indices.deinit();
        for (nodes, 0..) |node, index| {
            if (node.id.len == 0) return error.AmbiguousWorktreeNode;
            const entry = try indices.getOrPut(node.id);
            if (entry.found_existing) return error.AmbiguousWorktreeNode;
            entry.value_ptr.* = index;
        }
        return indices;
    }

    fn decode(self: *@This(), node: Node) !Graph {
        if (!std.mem.eql(u8, node.loop_type, "composite") and
            !std.mem.eql(u8, node.loop_type, "proactive")) return error.UnsupportedWorktreeSubgraph;
        const bytes = node.subgraph_json;
        if (bytes.len > self.remaining_json) return error.WorktreeComparisonLimit;
        self.remaining_json -= bytes.len;

        var scanner = std.json.Scanner.initCompleteInput(self.allocator, bytes);
        defer scanner.deinit();
        var json_depth: usize = 0;
        while (true) {
            switch (try scanner.next()) {
                .object_begin, .array_begin => {
                    json_depth += 1;
                    if (json_depth > 4 * max_depth) return error.WorktreeComparisonLimit;
                },
                .object_end, .array_end => json_depth -= 1,
                .end_of_document => break,
                else => {},
            }
        }
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.MalformedSubgraph;
        const root = parsed.value.object;
        const json_nodes: []const std.json.Value = if (root.get("nodes")) |value| switch (value) {
            .array => |array| array.items,
            else => return error.MalformedSubgraph,
        } else &.{};
        if (json_nodes.len > self.remaining_items) return error.WorktreeComparisonLimit;
        if (root.get("edges")) |value| switch (value) {
            .array => |array| try self.consumeItems(array.items.len),
            else => return error.MalformedSubgraph,
        };
        var graph = try decodeSubgraph(self.allocator, self.project, bytes);
        errdefer freeGraph(self.allocator, &graph);
        if (graph.nodes.items.len != json_nodes.len) return error.MalformedSubgraph;
        for (json_nodes, graph.nodes.items) |value, decoded| {
            if (value != .object) return error.MalformedSubgraph;
            const object = value.object;
            const id = object.get("id") orelse return error.AmbiguousWorktreeNode;
            if (id != .string or id.string.len == 0 or !std.mem.eql(u8, id.string, decoded.id))
                return error.AmbiguousWorktreeNode;
            if (object.get("subGraph")) |nested| switch (nested) {
                .null => if (decoded.subgraph_json.len != 0) return error.MalformedSubgraph,
                .object => if (decoded.subgraph_json.len == 0) return error.MalformedSubgraph,
                else => return error.UnsupportedWorktreeSubgraph,
            };
        }
        return graph;
    }

    fn compare(self: *@This(), previous: []const Node, next: []const Node, depth: usize) anyerror!bool {
        if (depth > max_depth) return error.WorktreeComparisonLimit;
        try self.consumeItems(previous.len);
        try self.consumeItems(next.len);
        var before_indices = try self.indexNodes(previous);
        defer before_indices.deinit();
        var after_indices = try self.indexNodes(next);
        defer after_indices.deinit();
        for (previous) |node| {
            const index = after_indices.get(node.id);
            if (node.worktree_path.len != 0) {
                const other = next[index orelse return true];
                if (worktreeBindingFactsDiffer(node, other)) return true;
            }
            if (node.subgraph_json.len != 0) {
                var before = try self.decode(node);
                defer freeGraph(self.allocator, &before);
                if (index) |matched| {
                    const other = next[matched];
                    if (!std.mem.eql(u8, node.loop_type, other.loop_type)) return true;
                    if (other.subgraph_json.len != 0) {
                        if (std.mem.eql(u8, node.subgraph_json, other.subgraph_json)) {
                            if (try self.compare(before.nodes.items, before.nodes.items, depth + 1)) return true;
                        } else {
                            var after = try self.decode(other);
                            defer freeGraph(self.allocator, &after);
                            if (try self.compare(before.nodes.items, after.nodes.items, depth + 1)) return true;
                        }
                        continue;
                    }
                }
                if (try self.compare(before.nodes.items, &.{}, depth + 1)) return true;
            }
        }
        for (next) |node| {
            const index = before_indices.get(node.id);
            if (node.worktree_path.len != 0) {
                const other = previous[index orelse return true];
                if (!std.mem.eql(u8, node.worktree_path, other.worktree_path)) return true;
            }
            if (node.subgraph_json.len != 0 and (index == null or previous[index.?].subgraph_json.len == 0)) {
                var added = try self.decode(node);
                defer freeGraph(self.allocator, &added);
                if (try self.compare(&.{}, added.nodes.items, depth + 1)) return true;
            }
        }
        return false;
    }
};

fn worktreeBindingsChanged(allocator: std.mem.Allocator, project: Project, previous: []const Node, next: []const Node) !bool {
    if (previous.len > WorktreeBindingComparison.max_items or next.len > WorktreeBindingComparison.max_items - previous.len)
        return error.WorktreeComparisonLimit;
    var nested_bytes: usize = 0;
    var relevant = false;
    for ([_][]const Node{ previous, next }) |nodes| {
        for (nodes) |node| {
            relevant = relevant or node.worktree_path.len != 0 or node.subgraph_json.len != 0;
            if (node.subgraph_json.len > WorktreeBindingComparison.max_json_work - nested_bytes)
                return error.WorktreeComparisonLimit;
            nested_bytes += node.subgraph_json.len;
        }
    }
    if (!relevant) return false;
    if (nested_bytes == 0) return flatWorktreeBindingsChanged(previous, next);
    const capacity = @min(WorktreeBindingComparison.max_scratch, 64 * 1024 + (previous.len + next.len) * 256 + nested_bytes * 64);
    const buffer = try allocator.alloc(u8, capacity);
    defer allocator.free(buffer);
    // The region also owns any partially decoded nodes when the existing parser runs out of memory.
    var scratch = std.heap.FixedBufferAllocator.init(buffer);
    var comparison = WorktreeBindingComparison{ .allocator = scratch.allocator(), .project = project };
    return comparison.compare(previous, next, 0) catch |err| return if (err == error.OutOfMemory) error.WorktreeComparisonLimit else err;
}

pub const GraphSummary = struct {
    project: Project,
    nodes: std.array_list.Managed(Node),
    edges: std.array_list.Managed(Edge),
    worktree_notice: ?WorktreeStatus.NoticeRecord = null,

    fn deinit(self: *GraphSummary, allocator: std.mem.Allocator) void {
        freeProject(allocator, self.project);
        for (self.nodes.items) |node| freeNode(allocator, node);
        for (self.edges.items) |edge| freeEdge(allocator, edge);
        self.nodes.deinit();
        self.edges.deinit();
    }
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    recent_projects: std.array_list.Managed(Project),
    open_projects: std.array_list.Managed(Project),
    graphs: std.array_list.Managed(GraphSummary),
    graph: ?Graph = null,
    selected_project_path: ?[]u8 = null,
    selected_node_id: ?[]u8 = null,
    selected_index: ?usize = null,
    open_composite_id: ?[]u8 = null,
    open_composite_title: ?[]u8 = null,
    last_sequence: u64 = 0,
    attention: std.array_list.Managed(Node),
    attention_entries: std.array_list.Managed(AttentionEntry),
    activity: std.array_list.Managed(ActivityEvent),
    lifecycle_callback: ?LifecycleCallback = null,
    lifecycle_context: ?*anyopaque = null,
    restore_state: RestoreState = .cold,
    restore_generation: u64 = 0,
    graph_generations: std.array_list.Managed(GraphGeneration),
    quick_chats: std.array_list.Managed(QuickChat),

    pub fn init(allocator: std.mem.Allocator) Model {
        return .{
            .allocator = allocator,
            .recent_projects = std.array_list.Managed(Project).init(allocator),
            .open_projects = std.array_list.Managed(Project).init(allocator),
            .graphs = std.array_list.Managed(GraphSummary).init(allocator),
            .attention = std.array_list.Managed(Node).init(allocator),
            .attention_entries = std.array_list.Managed(AttentionEntry).init(allocator),
            .activity = std.array_list.Managed(ActivityEvent).init(allocator),
            .graph_generations = std.array_list.Managed(GraphGeneration).init(allocator),
            .quick_chats = std.array_list.Managed(QuickChat).init(allocator),
        };
    }

    pub fn deinit(self: *Model) void {
        for (self.recent_projects.items) |project| freeProject(self.allocator, project);
        self.recent_projects.deinit();
        for (self.open_projects.items) |project| freeProject(self.allocator, project);
        self.open_projects.deinit();
        for (self.graphs.items) |*summary| summary.deinit(self.allocator);
        self.graphs.deinit();
        for (self.attention.items) |node| freeNode(self.allocator, node);
        self.attention.deinit();
        for (self.attention_entries.items) |entry| freeAttentionEntry(self.allocator, entry);
        self.attention_entries.deinit();
        for (self.activity.items) |event| {
            self.allocator.free(event.title);
            self.allocator.free(event.state);
            self.allocator.free(event.project_path);
            self.allocator.free(event.node_id);
        }
        self.activity.deinit();
        for (self.quick_chats.items) |chat| freeQuickChat(self.allocator, chat);
        self.quick_chats.deinit();
        if (self.graph) |*graph| freeGraph(self.allocator, graph);
        if (self.selected_project_path) |path| self.allocator.free(path);
        self.freeSelectedNodeID();
        self.clearOpenComposite();
        for (self.graph_generations.items) |entry| self.allocator.free(entry.project_path);
        self.graph_generations.deinit();
    }

    pub fn clearProjects(self: *Model) void {
        for (self.recent_projects.items) |project| freeProject(self.allocator, project);
        self.recent_projects.clearRetainingCapacity();
    }

    pub fn setLifecycleCallback(self: *Model, context: ?*anyopaque, callback: ?LifecycleCallback) void {
        self.lifecycle_context = context;
        self.lifecycle_callback = callback;
    }

    pub fn dispatchLifecycle(self: *Model, action: LifecycleAction, project_path: []const u8) void {
        if (self.lifecycle_callback) |callback| {
            callback(self.lifecycle_context, .{ .action = action, .project_path = project_path });
        }
    }

    pub fn beginRestore(self: *Model) void {
        self.invalidateWorktreeNotices(.connection_changed);
        self.restore_generation += 1;
        self.restore_state = .restoring;
    }

    pub fn markRestored(self: *Model) void {
        self.reconcileRestore();
        self.restore_state = .restored;
    }

    pub fn markReconnecting(self: *Model) void {
        // Graph summaries and selection intentionally survive transport loss.
        self.invalidateWorktreeNotices(.connection_changed);
        self.restore_state = .reconnecting;
    }

    pub fn selectedNodeID(self: *const Model) ?[]const u8 {
        return if (self.selected()) |node| node.id else null;
    }

    pub fn selectedIndex(self: *const Model) ?usize {
        return self.selected_index;
    }

    pub fn setSelectedIndex(self: *Model, index: ?usize) bool {
        const graph = if (self.graph) |*value| value else return index == null;
        if (index) |value| {
            if (value >= graph.nodes.items.len) return false;
            self.selected_index = value;
            self.replaceSelectedNodeID(graph.nodes.items[value].id);
        } else {
            self.selected_index = null;
            self.freeSelectedNodeID();
        }
        return true;
    }

    pub fn setSelectedID(self: *Model, id: []const u8) bool {
        return self.selectNodeID(id);
    }

    fn freeSelectedNodeID(self: *Model) void {
        if (self.selected_node_id) |id| self.allocator.free(id);
        self.selected_node_id = null;
    }

    fn replaceSelectedNodeID(self: *Model, id: []const u8) void {
        const copy = self.allocator.dupe(u8, id) catch return;
        self.freeSelectedNodeID();
        self.selected_node_id = copy;
    }

    pub fn currentGraph(self: *const Model) ?*const GraphSummary {
        if (self.selected_project_path) |path| return self.graphFor(path);
        if (self.graph) |graph| return self.graphFor(graph.project.path);
        return null;
    }

    pub fn graphFor(self: *const Model, project_path: []const u8) ?*const GraphSummary {
        for (self.graphs.items) |*summary| {
            if (std.mem.eql(u8, summary.project.path, project_path)) return summary;
        }
        return null;
    }

    fn worktreeNoticeOwner(self: *Model, project_path: []const u8) !*GraphSummary {
        for (self.graphs.items) |*summary| {
            if (!std.mem.eql(u8, summary.project.path, project_path)) continue;
            if (!summary.project.isLocalFilesystem()) return error.UnsupportedWorktreeProject;
            return summary;
        }
        return error.WorktreeProjectClosed;
    }

    pub fn recordWorktreeInspection(self: *Model, inspection: *const WorktreeStatus.Inspection, policy: WorktreeStatus.PolicyOutcome) !void {
        const owner = try self.worktreeNoticeOwner(inspection.project_path);
        owner.worktree_notice = WorktreeStatus.NoticeRecord.inspected(inspection, policy);
    }

    pub fn recordWorktreeFailure(self: *Model, project_path: []const u8, failure: anyerror) !void {
        const owner = try self.worktreeNoticeOwner(project_path);
        var record = owner.worktree_notice orelse WorktreeStatus.NoticeRecord{};
        record.refresh_error = failure;
        owner.worktree_notice = record;
    }

    pub fn recordWorktreePolicy(self: *Model, project_path: []const u8, policy: WorktreeStatus.PolicyOutcome) !void {
        const owner = try self.worktreeNoticeOwner(project_path);
        var record = owner.worktree_notice orelse WorktreeStatus.NoticeRecord{};
        record.policy = policy;
        owner.worktree_notice = record;
    }

    pub fn invalidateWorktreeNotices(self: *Model, reason: WorktreeStatus.StaleReason) void {
        for (self.graphs.items) |*summary| {
            if (summary.worktree_notice) |*record| {
                if (record.observation != null) {
                    record.stale = reason;
                    record.stale_error = null;
                }
            }
        }
    }

    fn invalidateForWorktreeBindings(self: *Model, project: Project, previous: []const Node, next: []const Node) void {
        const changed = worktreeBindingsChanged(self.allocator, project, previous, next) catch |err| {
            self.invalidateWorktreeNotices(.bindings_unavailable);
            for (self.graphs.items) |*summary| {
                if (summary.worktree_notice) |*record| {
                    if (record.observation != null) record.stale_error = err;
                }
            }
            return;
        };
        if (changed) self.invalidateWorktreeNotices(.bindings_changed);
    }

    pub fn selectProject(self: *Model, project_path: []const u8) bool {
        const summary = self.graphFor(project_path) orelse return false;
        self.clearOpenComposite();
        if (self.selected_project_path) |path| self.allocator.free(path);
        self.selected_project_path = self.allocator.dupe(u8, summary.project.path) catch return false;
        self.selected_index = if (summary.nodes.items.len == 0) null else 0;
        if (summary.nodes.items.len == 0) self.freeSelectedNodeID() else self.replaceSelectedNodeID(summary.nodes.items[0].id);
        self.syncLegacyGraph();
        return true;
    }

    pub fn openComposite(self: *Model, node_id: []const u8) bool {
        const summary = self.currentGraph() orelse return false;
        const index = findNodeIndexByID(summary.nodes.items, node_id) orelse return false;
        const node = summary.nodes.items[index];
        if ((!std.mem.eql(u8, node.loop_type, "composite") and
            !std.mem.eql(u8, node.loop_type, "proactive")) or node.subgraph_json.len == 0)
            return false;
        const id = self.allocator.dupe(u8, node.id) catch return false;
        errdefer self.allocator.free(id);
        const title = self.allocator.dupe(u8, node.title) catch return false;
        self.clearOpenComposite();
        self.open_composite_id = id;
        self.open_composite_title = title;
        self.syncLegacyGraph();
        return self.graph != null;
    }

    pub fn closeComposite(self: *Model) void {
        const parent_id = if (self.open_composite_id) |id|
            self.allocator.dupe(u8, id) catch null
        else
            null;
        defer if (parent_id) |id| self.allocator.free(id);
        self.clearOpenComposite();
        self.syncLegacyGraph();
        if (parent_id) |id| _ = self.selectNodeID(id);
    }

    pub fn isCompositeOpen(self: *const Model) bool {
        return self.open_composite_id != null;
    }

    fn clearOpenComposite(self: *Model) void {
        if (self.open_composite_id) |id| self.allocator.free(id);
        if (self.open_composite_title) |title| self.allocator.free(title);
        self.open_composite_id = null;
        self.open_composite_title = null;
    }

    pub fn reconcileRestore(self: *Model) void {
        var index: usize = 0;
        while (index < self.graphs.items.len) {
            const path = self.graphs.items[index].project.path;
            if (!self.wasGraphSeen(path)) {
                self.removeOpenProject(path);
                var removed = self.graphs.orderedRemove(index);
                removed.deinit(self.allocator);
                continue;
            }
            index += 1;
        }
        if (self.selected_project_path) |path| {
            if (self.graphFor(path) != null) {
                self.syncLegacyGraph();
                self.rebuildAttention();
                return;
            }
            self.allocator.free(path);
            self.selected_project_path = null;
        }
        if (self.graphs.items.len != 0) {
            _ = self.selectProject(self.graphs.items[0].project.path);
        } else {
            self.selected_index = null;
            self.freeSelectedNodeID();
        }
        self.syncLegacyGraph();
        self.rebuildAttention();
    }

    pub fn applyLifecycle(self: *Model, action: LifecycleAction, project_path: []const u8) bool {
        const stable_path = self.allocator.dupe(u8, project_path) catch return false;
        defer self.allocator.free(stable_path);
        const path = stable_path;
        const index = for (self.graphs.items, 0..) |summary, i| {
            if (std.mem.eql(u8, summary.project.path, path)) break i;
        } else null;
        if (action == .select) {
            const selected_result = self.selectProject(path);
            if (selected_result) self.dispatchLifecycle(action, path);
            return selected_result;
        }
        var known = index != null;
        for (self.open_projects.items) |project| known = known or std.mem.eql(u8, project.path, path);
        for (self.recent_projects.items) |project| known = known or std.mem.eql(u8, project.path, path);
        if (!known) return false;
        if (index) |i| {
            self.invalidateForWorktreeBindings(self.graphs.items[i].project, self.graphs.items[i].nodes.items, &.{});
        }
        switch (action) {
            .select => unreachable,
            .close => {
                if (index) |i| {
                    var summary = self.graphs.orderedRemove(i);
                    summary.deinit(self.allocator);
                }
                self.removeOpenProject(path);
            },
            .forget => {
                if (index) |i| {
                    var summary = self.graphs.orderedRemove(i);
                    summary.deinit(self.allocator);
                }
                self.removeOpenProject(path);
                self.removeRecentProject(path);
            },
            .delete => {
                if (index) |i| {
                    var summary = self.graphs.orderedRemove(i);
                    summary.deinit(self.allocator);
                }
                self.removeOpenProject(path);
                self.removeRecentProject(path);
            },
        }
        if (self.selected_project_path) |selected_path| {
            if (std.mem.eql(u8, selected_path, path)) {
                self.allocator.free(selected_path);
                self.selected_project_path = null;
                if (self.graph) |*graph| {
                    if (std.mem.eql(u8, graph.project.path, path)) {
                        freeGraph(self.allocator, graph);
                        self.graph = null;
                    }
                }
                self.selected_index = null;
                self.freeSelectedNodeID();
                if (self.graphs.items.len != 0) {
                    _ = self.selectProject(self.graphs.items[0].project.path);
                }
            }
        }
        self.syncLegacyGraph();
        self.rebuildAttention();
        self.dispatchLifecycle(action, path);
        return true;
    }

    fn removeOpenProject(self: *Model, path: []const u8) void {
        var i: usize = 0;
        while (i < self.open_projects.items.len) {
            if (std.mem.eql(u8, self.open_projects.items[i].path, path)) {
                const project = self.open_projects.orderedRemove(i);
                freeProject(self.allocator, project);
            } else i += 1;
        }
    }

    fn removeRecentProject(self: *Model, path: []const u8) void {
        var i: usize = 0;
        while (i < self.recent_projects.items.len) {
            if (std.mem.eql(u8, self.recent_projects.items[i].path, path)) {
                const project = self.recent_projects.orderedRemove(i);
                freeProject(self.allocator, project);
            } else i += 1;
        }
    }

    pub fn updateFromFrame(self: *Model, frame: []const u8) !Wire.EventKind {
        if (Wire.jsonNumber(frame, "sequence")) |sequence| self.last_sequence = sequence;
        switch (Wire.eventKind(frame)) {
            .graph_changed => {
                try self.decodeGraph(frame);
                return .graph_changed;
            },
            .recent_projects => {
                try self.decodeRecentProjects(frame);
                return .recent_projects;
            },
            .quick_chats, .quick_chat_changed, .quick_chat_deleted, .quick_chat_activity => {
                try self.decodeQuickChats(frame, Wire.eventKind(frame));
                return Wire.eventKind(frame);
            },
            else => return Wire.eventKind(frame),
        }
    }

    pub fn attentionCount(self: *const Model) usize {
        return self.attention.items.len;
    }

    pub fn selected(self: *const Model) ?*const Node {
        const graph = if (self.graph) |*value| value else return null;
        if (self.selected_node_id) |id| {
            for (graph.nodes.items) |*node| if (std.mem.eql(u8, node.id, id)) return node;
        }
        const index = self.selected_index orelse return null;
        if (index >= graph.nodes.items.len) return null;
        return &graph.nodes.items[index];
    }

    pub fn findNodeIndex(self: *const Model, id: []const u8) ?usize {
        const graph = self.graph orelse return null;
        return findNodeIndexByID(graph.nodes.items, id);
    }

    pub fn findEdgeIndex(self: *const Model, id: []const u8) ?usize {
        const graph = self.graph orelse return null;
        return findEdgeIndexByID(graph.edges.items, id);
    }

    pub fn selectNext(self: *Model) void {
        const graph = self.graph orelse return;
        if (graph.nodes.items.len == 0) {
            self.selected_index = null;
        } else {
            self.selected_index = ((self.selected_index orelse 0) + 1) % graph.nodes.items.len;
            self.replaceSelectedNodeID(graph.nodes.items[self.selected_index.?].id);
        }
    }

    pub fn selectNextAttention(self: *Model) void {
        if (self.attention_entries.items.len == 0) return;
        var next_index: usize = 0;
        if (self.selected_project_path) |project_path| {
            var current_node_id = self.selected_node_id;
            if (self.currentGraph()) |graph| {
                if (self.selected_index) |index| {
                    if (index < graph.nodes.items.len) current_node_id = graph.nodes.items[index].id;
                }
            }
            if (current_node_id) |node_id| {
                for (self.attention_entries.items, 0..) |entry, index| {
                    if (std.mem.eql(u8, entry.project_path, project_path) and
                        std.mem.eql(u8, entry.node.id, node_id))
                    {
                        next_index = (index + 1) % self.attention_entries.items.len;
                        break;
                    }
                }
            }
        }
        const next = self.attention_entries.items[next_index];
        if (!self.selectProject(next.project_path)) return;
        _ = self.selectNodeID(next.node.id);
    }

    fn selectNodeID(self: *Model, node_id: []const u8) bool {
        const graph = self.graph orelse return false;
        for (graph.nodes.items, 0..) |node, index| {
            if (std.mem.eql(u8, node.id, node_id)) {
                _ = self.setSelectedIndex(index);
                return true;
            }
        }
        return false;
    }

    fn decodeRecentProjects(self: *Model, frame: []const u8) !void {
        self.clearProjects();
        const list = std.mem.indexOf(u8, frame, "\"recentProjectsListed\"") orelse return;
        const open = indexOfByte(frame, list, '[') orelse return;
        const close = findClosing(frame, open, '[', ']') orelse return;
        var cursor = open + 1;
        while (cursor < close) {
            const object_start = indexOfByte(frame, cursor, '{') orelse break;
            if (object_start >= close) break;
            const object_end = findClosing(frame, object_start, '{', '}') orelse break;
            const object = frame[object_start .. object_end + 1];
            try self.recent_projects.append(.{
                .path = try duplicateJsonString(self.allocator, object, "path"),
                .name = try duplicateJsonString(self.allocator, object, "name"),
            });
            cursor = object_end + 1;
        }
        // The daemon's recent list is also the authoritative restore/open seed.
        // Keep open projects separate so a later project event never evicts older
        // graph summaries.
        if (std.mem.indexOf(u8, frame, "\"openProjects\"")) |open_key| {
            if (indexOfByte(frame, open_key, '[')) |open_projects_start| {
                if (findClosing(frame, open_projects_start, '[', ']')) |open_projects_end| {
                    var open_cursor = open_projects_start + 1;
                    while (open_cursor < open_projects_end) {
                        const start = indexOfByte(frame, open_cursor, '{') orelse break;
                        if (start >= open_projects_end) break;
                        const end = findClosing(frame, start, '{', '}') orelse break;
                        const object = frame[start .. end + 1];
                        try self.addOpenProject(.{
                            .path = try duplicateJsonString(self.allocator, object, "path"),
                            .name = try duplicateJsonString(self.allocator, object, "name"),
                        });
                        open_cursor = end + 1;
                    }
                }
            }
        }
    }

    fn decodeQuickChats(self: *Model, frame: []const u8, kind: Wire.EventKind) !void {
        if (kind == .quick_chats) {
            for (self.quick_chats.items) |chat| freeQuickChat(self.allocator, chat);
            self.quick_chats.clearRetainingCapacity();
        }
        const marker = switch (kind) {
            .quick_chats => "\"quickChatsListed\"",
            .quick_chat_changed => "\"quickChatChanged\"",
            .quick_chat_deleted => "\"quickChatDeleted\"",
            .quick_chat_activity => "\"quickChatActivity\"",
            else => return,
        };
        const start = std.mem.indexOf(u8, frame, marker) orelse return;
        if (kind == .quick_chat_deleted) {
            const id = Wire.jsonString(frame[start..], "quickChatDeleted") orelse return;
            var index: usize = 0;
            while (index < self.quick_chats.items.len) : (index += 1) {
                if (std.mem.eql(u8, self.quick_chats.items[index].id, id)) {
                    const removed = self.quick_chats.orderedRemove(index);
                    freeQuickChat(self.allocator, removed);
                    return;
                }
            }
            return;
        }
        const open = indexOfByte(frame, start, if (kind == .quick_chats) '[' else '{') orelse return;
        const close = findClosing(frame, open, if (kind == .quick_chats) '[' else '{', if (kind == .quick_chats) ']' else '}') orelse return;
        if (kind == .quick_chats) {
            var cursor = open + 1;
            while (cursor < close) {
                const object_start = indexOfByte(frame, cursor, '{') orelse break;
                if (object_start >= close) break;
                const object_end = findClosing(frame, object_start, '{', '}') orelse break;
                try self.upsertQuickChat(frame[object_start .. object_end + 1]);
                cursor = object_end + 1;
            }
        } else if (kind == .quick_chat_activity) {
            const object = frame[open .. close + 1];
            const id = Wire.jsonString(object, "id") orelse return;
            const activity_start = std.mem.indexOf(u8, object, "\"activity\"") orelse return;
            const activity_open = indexOfByte(object, activity_start, '{') orelse return;
            const activity_close = findClosing(object, activity_open, '{', '}') orelse return;
            const activity_object = object[activity_open .. activity_close + 1];
            const sequence = Wire.jsonNumber(activity_object, "sequence") orelse 0;
            const activity = Wire.jsonString(activity_object, "text") orelse "";
            for (self.quick_chats.items) |*chat| {
                if (std.mem.eql(u8, chat.id, id) and sequence >= chat.activity_sequence) {
                    self.allocator.free(chat.activity);
                    chat.activity = try self.allocator.dupe(u8, activity);
                    chat.activity_sequence = sequence;
                }
            }
        } else {
            try self.upsertQuickChat(frame[open .. close + 1]);
        }
    }

    fn upsertQuickChat(self: *Model, object: []const u8) !void {
        const id = duplicateJsonString(self.allocator, object, "id") catch return;
        errdefer self.allocator.free(id);
        for (self.quick_chats.items) |*existing| {
            if (std.mem.eql(u8, existing.id, id)) {
                self.allocator.free(existing.title);
                existing.title = try duplicateJsonString(self.allocator, object, "title");
                self.allocator.free(id);
                return;
            }
        }
        var chat = QuickChat{
            .id = id,
            .title = try duplicateJsonString(self.allocator, object, "title"),
            .backend = try duplicateJsonStringOr(self.allocator, object, "backend", "claudeCode"),
        };
        if (std.mem.indexOf(u8, object, "\"activity\"")) |activity_key| {
            if (indexOfByte(object, activity_key, '{')) |activity_open| {
                if (findClosing(object, activity_open, '{', '}')) |activity_close| {
                    const activity_object = object[activity_open .. activity_close + 1];
                    chat.activity_sequence = Wire.jsonNumber(activity_object, "sequence") orelse 0;
                    chat.activity = try self.allocator.dupe(
                        u8,
                        Wire.jsonString(activity_object, "text") orelse "",
                    );
                }
            }
        }
        try self.quick_chats.append(chat);
    }

    fn decodeGraph(self: *Model, frame: []const u8) !void {
        const graph_start = std.mem.indexOf(u8, frame, "\"graphChanged\"") orelse return;
        const object_start = indexOfByte(frame, graph_start, '{') orelse return;
        const object_end = findClosing(frame, object_start, '{', '}') orelse return error.MalformedGraph;
        const graph_json = frame[object_start .. object_end + 1];
        var graph = Graph{
            .project = .{
                .path = try duplicateJsonString(self.allocator, graph_json, "path"),
                .name = try duplicateJsonString(self.allocator, graph_json, "name"),
            },
            .nodes = std.array_list.Managed(Node).init(self.allocator),
            .edges = std.array_list.Managed(Edge).init(self.allocator),
        };
        errdefer freeGraph(self.allocator, &graph);

        if (std.mem.indexOf(u8, graph_json, "\"nodes\"")) |nodes_key| {
            if (indexOfByte(graph_json, nodes_key, '[')) |nodes_open| {
                if (findClosing(graph_json, nodes_open, '[', ']')) |nodes_close| {
                    try decodeNodes(self.allocator, graph_json[nodes_open + 1 .. nodes_close], &graph.nodes);
                }
            }
        }
        if (std.mem.indexOf(u8, graph_json, "\"edges\"")) |edges_key| {
            if (indexOfByte(graph_json, edges_key, '[')) |edges_open| {
                if (findClosing(graph_json, edges_open, '[', ']')) |edges_close| {
                    try decodeEdges(self.allocator, graph_json[edges_open + 1 .. edges_close], &graph.edges);
                }
            }
        }
        const was_selected = if (self.selected_project_path) |path|
            std.mem.eql(u8, path, graph.project.path)
        else
            self.graph == null;
        const prior_node_id: ?[]const u8 = if (was_selected) self.selected_node_id else null;
        self.recordActivity(graph);
        try self.upsertSummary(&graph);
        self.markGraphSeen(graph.project.path);
        self.rebuildAttention();
        try self.addOpenProject(.{
            .path = try self.allocator.dupe(u8, graph.project.path),
            .name = try self.allocator.dupe(u8, graph.project.name),
        });
        if (self.graph) |*old| freeGraph(self.allocator, old);
        self.graph = graph;
        if (self.selected_project_path == null) {
            self.selected_project_path = try self.allocator.dupe(u8, graph.project.path);
        }
        if (was_selected and graph.nodes.items.len == 0) {
            self.selected_index = null;
            self.freeSelectedNodeID();
        } else if (was_selected) {
            self.selected_index = 0;
            if (prior_node_id) |node_id| {
                for (graph.nodes.items, 0..) |node, index| {
                    if (std.mem.eql(u8, node.id, node_id)) {
                        self.selected_index = index;
                        self.replaceSelectedNodeID(node.id);
                        break;
                    }
                }
            } else if (graph.nodes.items.len != 0) {
                self.replaceSelectedNodeID(graph.nodes.items[0].id);
            }
        }
        self.syncLegacyGraph();
    }

    fn syncLegacyGraph(self: *Model) void {
        if (self.graph) |*old| {
            freeGraph(self.allocator, old);
            self.graph = null;
        }
        const path = self.selected_project_path orelse return;
        const summary = self.graphFor(path) orelse return;
        const project_path = self.allocator.dupe(u8, summary.project.path) catch return;
        const project_name = self.allocator.dupe(u8, summary.project.name) catch {
            self.allocator.free(project_path);
            return;
        };
        var graph = Graph{
            .project = .{
                .path = project_path,
                .name = project_name,
            },
            .nodes = std.array_list.Managed(Node).init(self.allocator),
            .edges = std.array_list.Managed(Edge).init(self.allocator),
        };
        for (summary.nodes.items) |node| {
            const copy = cloneNode(self.allocator, node) catch {
                freeGraph(self.allocator, &graph);
                return;
            };
            graph.nodes.append(copy) catch {
                freeNode(self.allocator, copy);
                freeGraph(self.allocator, &graph);
                return;
            };
        }
        for (summary.edges.items) |edge| {
            const copy = cloneEdge(self.allocator, edge) catch {
                freeGraph(self.allocator, &graph);
                return;
            };
            graph.edges.append(copy) catch {
                freeEdge(self.allocator, copy);
                freeGraph(self.allocator, &graph);
                return;
            };
        }
        self.graph = graph;
        self.applyOpenComposite();
    }

    fn applyOpenComposite(self: *Model) void {
        const node_id = self.open_composite_id orelse return;
        const top = self.graph orelse return;
        const index = findNodeIndexByID(top.nodes.items, node_id) orelse {
            self.clearOpenComposite();
            return;
        };
        const node = top.nodes.items[index];
        if (self.allocator.dupe(u8, node.title)) |title| {
            if (self.open_composite_title) |old| self.allocator.free(old);
            self.open_composite_title = title;
        } else |_| {}
        const nested = decodeSubgraph(self.allocator, top.project, node.subgraph_json) catch {
            self.clearOpenComposite();
            return;
        };
        if (self.graph) |*old| freeGraph(self.allocator, old);
        self.graph = nested;
        if (nested.nodes.items.len == 0) {
            self.selected_index = null;
            self.freeSelectedNodeID();
        } else {
            const retained = if (self.selected_node_id) |id|
                findNodeIndexByID(nested.nodes.items, id)
            else
                null;
            self.selected_index = retained orelse 0;
            self.replaceSelectedNodeID(nested.nodes.items[self.selected_index.?].id);
        }
    }

    fn addOpenProject(self: *Model, project: Project) !void {
        for (self.open_projects.items) |existing| {
            if (std.mem.eql(u8, existing.path, project.path)) {
                freeProject(self.allocator, project);
                return;
            }
        }
        try self.open_projects.append(project);
    }

    fn upsertSummary(self: *Model, graph: *const Graph) !void {
        for (self.graphs.items) |*summary| {
            if (!std.mem.eql(u8, summary.project.path, graph.project.path)) continue;
            self.invalidateForWorktreeBindings(graph.project, summary.nodes.items, graph.nodes.items);
            for (summary.nodes.items) |node| freeNode(self.allocator, node);
            for (summary.edges.items) |edge| freeEdge(self.allocator, edge);
            summary.nodes.clearRetainingCapacity();
            summary.edges.clearRetainingCapacity();
            for (graph.nodes.items) |node| try summary.nodes.append(try cloneNode(self.allocator, node));
            for (graph.edges.items) |edge| try summary.edges.append(try cloneEdge(self.allocator, edge));
            return;
        }
        self.invalidateForWorktreeBindings(graph.project, &.{}, graph.nodes.items);
        var summary = GraphSummary{
            .project = .{
                .path = try self.allocator.dupe(u8, graph.project.path),
                .name = try self.allocator.dupe(u8, graph.project.name),
            },
            .nodes = std.array_list.Managed(Node).init(self.allocator),
            .edges = std.array_list.Managed(Edge).init(self.allocator),
        };
        errdefer summary.deinit(self.allocator);
        for (graph.nodes.items) |node| try summary.nodes.append(try cloneNode(self.allocator, node));
        for (graph.edges.items) |edge| try summary.edges.append(try cloneEdge(self.allocator, edge));
        try self.graphs.append(summary);
    }

    fn markGraphSeen(self: *Model, path: []const u8) void {
        for (self.graph_generations.items) |*entry| {
            if (std.mem.eql(u8, entry.project_path, path)) {
                entry.generation = self.restore_generation;
                return;
            }
        }
        self.graph_generations.append(.{
            .project_path = self.allocator.dupe(u8, path) catch return,
            .generation = self.restore_generation,
        }) catch {};
    }

    fn wasGraphSeen(self: *const Model, path: []const u8) bool {
        for (self.graph_generations.items) |entry| {
            if (std.mem.eql(u8, entry.project_path, path)) return entry.generation == self.restore_generation;
        }
        return false;
    }

    fn replaceAttention(self: *Model, graph: *const Graph) void {
        _ = graph;
        self.rebuildAttention();
    }

    fn rebuildAttention(self: *Model) void {
        for (self.attention.items) |node| freeNode(self.allocator, node);
        self.attention.clearRetainingCapacity();
        for (self.attention_entries.items) |entry| freeAttentionEntry(self.allocator, entry);
        self.attention_entries.clearRetainingCapacity();
        for (self.graphs.items) |summary| {
            for (summary.nodes.items) |node| {
                if (!needsAttention(node) and !(std.mem.eql(u8, node.state, "blocked") and isStrandedSummary(&summary, node.id))) continue;
                const node_copy = cloneNode(self.allocator, node) catch continue;
                const entry = AttentionEntry{ .project_path = self.allocator.dupe(u8, summary.project.path) catch {
                    freeNode(self.allocator, node_copy);
                    continue;
                }, .node = node_copy };
                self.attention_entries.append(entry) catch {
                    freeAttentionEntry(self.allocator, entry);
                    continue;
                };
                const compat = cloneNode(self.allocator, node) catch continue;
                self.attention.append(compat) catch freeNode(self.allocator, compat);
            }
        }
        std.sort.heap(AttentionEntry, self.attention_entries.items, {}, compareAttentionEntry);
        std.sort.heap(Node, self.attention.items, {}, compareAttentionNode);
    }

    fn recordActivity(self: *Model, next: Graph) void {
        const previous = self.graphFor(next.project.path) orelse return;
        for (next.nodes.items) |node| {
            const old = findNode(previous.nodes.items, node.id) orelse continue;
            if (std.mem.eql(u8, old.state, node.state)) continue;
            const title = self.allocator.dupe(u8, node.title) catch continue;
            const state = self.allocator.dupe(u8, node.state) catch {
                self.allocator.free(title);
                continue;
            };
            const project_path = self.allocator.dupe(u8, next.project.path) catch {
                self.allocator.free(title);
                self.allocator.free(state);
                continue;
            };
            const node_id = self.allocator.dupe(u8, node.id) catch {
                self.allocator.free(title);
                self.allocator.free(state);
                self.allocator.free(project_path);
                continue;
            };
            const event = ActivityEvent{
                .title = title,
                .state = state,
                .project_path = project_path,
                .node_id = node_id,
                .timestamp = std.time.timestamp(),
            };
            self.activity.insert(0, event) catch {
                self.allocator.free(event.title);
                self.allocator.free(event.state);
                self.allocator.free(event.project_path);
                self.allocator.free(event.node_id);
                continue;
            };
            if (self.activity.items.len > 32) {
                const removed = self.activity.pop() orelse continue;
                self.allocator.free(removed.title);
                self.allocator.free(removed.state);
                self.allocator.free(removed.project_path);
                self.allocator.free(removed.node_id);
            }
        }
    }
};

fn findNode(nodes: []const Node, id: []const u8) ?Node {
    for (nodes) |node| if (std.mem.eql(u8, node.id, id)) return node;
    return null;
}

pub fn findNodeIndexByID(nodes: []const Node, id: []const u8) ?usize {
    for (nodes, 0..) |node, index| if (std.mem.eql(u8, node.id, id)) return index;
    return null;
}

pub fn findEdgeIndexByID(edges: []const Edge, id: []const u8) ?usize {
    for (edges, 0..) |edge, index| if (std.mem.eql(u8, edge.id, id)) return index;
    return null;
}

fn needsAttention(node: Node) bool {
    return std.mem.eql(u8, node.state, "failed") or
        std.mem.eql(u8, node.state, "stalled") or
        std.mem.eql(u8, node.presence, "awaitingInput");
}

fn attentionRank(node: Node) u8 {
    if (std.mem.eql(u8, node.state, "failed")) return 0;
    if (std.mem.eql(u8, node.state, "stalled")) return 1;
    if (std.mem.eql(u8, node.presence, "awaitingInput")) return 2;
    return 3;
}

fn isStranded(graph: *const Graph, node_id: []const u8) bool {
    var has_blocking_edge = false;
    for (graph.edges.items) |edge| {
        if (!std.mem.eql(u8, edge.to, node_id) or !edge.blocks_target or edge.fired) continue;
        has_blocking_edge = true;
        const source = findNode(graph.nodes.items, edge.from) orelse return false;
        if (!isResolved(source.state)) return false;
    }

    return has_blocking_edge;
}

fn isStrandedSummary(graph: *const GraphSummary, node_id: []const u8) bool {
    var has_blocking_edge = false;
    for (graph.edges.items) |edge| {
        if (!std.mem.eql(u8, edge.to, node_id) or !edge.blocks_target or edge.fired) continue;
        has_blocking_edge = true;
        const source = findNode(graph.nodes.items, edge.from) orelse return false;
        if (!isResolved(source.state)) return false;
    }
    return has_blocking_edge;
}

fn compareAttentionEntry(_: void, a: AttentionEntry, b: AttentionEntry) bool {
    return attentionRank(a.node) < attentionRank(b.node);
}

fn compareAttentionNode(_: void, a: Node, b: Node) bool {
    return attentionRank(a) < attentionRank(b);
}

fn isResolved(state: []const u8) bool {
    return std.mem.eql(u8, state, "succeeded") or
        std.mem.eql(u8, state, "failed") or
        std.mem.eql(u8, state, "stalled") or
        std.mem.eql(u8, state, "stopped");
}

fn cloneNode(allocator: std.mem.Allocator, node: Node) !Node {
    return .{
        .id = try allocator.dupe(u8, node.id),
        .title = try allocator.dupe(u8, node.title),
        .loop_type = try allocator.dupe(u8, node.loop_type),
        .state = try allocator.dupe(u8, node.state),
        .activity = try allocator.dupe(u8, node.activity),
        .presence = try allocator.dupe(u8, node.presence),
        .backend = try allocator.dupe(u8, node.backend),
        .pilot_state = try allocator.dupe(u8, node.pilot_state),
        .goal_summary = try allocator.dupe(u8, node.goal_summary),
        .goal_predicate = try allocator.dupe(u8, node.goal_predicate),
        .metric_command = try allocator.dupe(u8, node.metric_command),
        .metric_direction = try allocator.dupe(u8, node.metric_direction),
        .trigger_prompt = try allocator.dupe(u8, node.trigger_prompt),
        .check_description = try allocator.dupe(u8, node.check_description),
        .model_tier = try allocator.dupe(u8, node.model_tier),
        .poll_interval_seconds = node.poll_interval_seconds,
        .stall_after_seconds = node.stall_after_seconds,
        .created_at = node.created_at,
        .metric_passes = node.metric_passes,
        .metric_samples = node.metric_samples,
        .metric_sample_count = node.metric_sample_count,
        .token_usage = node.token_usage,
        .worktree_path = try allocator.dupe(u8, node.worktree_path),
        .worktree_branch = try allocator.dupe(u8, node.worktree_branch),
        .subgraph_json = try allocator.dupe(u8, node.subgraph_json),
        .follows_template = node.follows_template,
    };
}

fn cloneEdge(allocator: std.mem.Allocator, edge: Edge) !Edge {
    return .{
        .id = try allocator.dupe(u8, edge.id),
        .from = try allocator.dupe(u8, edge.from),
        .to = try allocator.dupe(u8, edge.to),
        .kind = try allocator.dupe(u8, edge.kind),
        .condition = try allocator.dupe(u8, edge.condition),
        .blocks_target = edge.blocks_target,
        .fired = edge.fired,
        .fire_count = edge.fire_count,
    };
}

fn freeEdge(allocator: std.mem.Allocator, edge: Edge) void {
    allocator.free(edge.id);
    allocator.free(edge.from);
    allocator.free(edge.to);
    allocator.free(edge.kind);
    allocator.free(edge.condition);
}

fn freeAttentionEntry(allocator: std.mem.Allocator, entry: AttentionEntry) void {
    allocator.free(entry.project_path);
    freeNode(allocator, entry.node);
}

fn decodeNodes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    nodes: *std.array_list.Managed(Node),
) !void {
    var cursor: usize = 0;
    while (cursor < bytes.len) {
        const start = indexOfByte(bytes, cursor, '{') orelse break;
        const end = findClosing(bytes, start, '{', '}') orelse break;
        const object = bytes[start .. end + 1];
        const scalar_object = try withoutJsonObjectField(allocator, object, "subGraph");
        defer allocator.free(scalar_object);
        const samples = jsonMetricSamples(scalar_object, "metricHistory");
        try nodes.append(.{
            .id = try duplicateJsonString(allocator, scalar_object, "id"),
            .title = try duplicateJsonStringOr(allocator, scalar_object, "title", "Untitled"),
            .loop_type = try duplicateJsonStringOr(allocator, scalar_object, "loopType", "turnBased"),
            .state = try duplicateJsonStringOr(allocator, scalar_object, "state", "idle"),
            .activity = try duplicateJsonStringOr(allocator, scalar_object, "activity", ""),
            .presence = try duplicatePresence(allocator, scalar_object),
            .backend = try duplicateJsonStringOr(allocator, scalar_object, "backend", ""),
            .pilot_state = try duplicateJsonStringOr(allocator, scalar_object, "pilotState", "notPiloted"),
            .goal_summary = try duplicateJsonStringOr(allocator, scalar_object, "summary", ""),
            .goal_predicate = try duplicateJsonStringOr(allocator, scalar_object, "predicate", ""),
            .metric_command = try duplicateJsonStringOr(allocator, scalar_object, "metricCommand", ""),
            .metric_direction = try duplicateJsonStringOr(allocator, scalar_object, "metricDirection", ""),
            .trigger_prompt = try duplicateJsonStringOr(allocator, scalar_object, "triggerPrompt", ""),
            .check_description = try duplicateJsonStringOr(allocator, scalar_object, "checkDescription", ""),
            .model_tier = try duplicateJsonStringOr(allocator, scalar_object, "modelTier", ""),
            .poll_interval_seconds = jsonFloat(scalar_object, "pollIntervalSeconds"),
            .stall_after_seconds = jsonFloat(scalar_object, "stallAfterSeconds"),
            .created_at = jsonNumber64(scalar_object, "createdAt"),
            .metric_passes = jsonArrayObjectCount(scalar_object, "metricHistory"),
            .metric_samples = samples.values,
            .metric_sample_count = samples.count,
            .token_usage = jsonUsageTotal(scalar_object),
            .worktree_path = try duplicateWorktreePath(allocator, scalar_object),
            .worktree_branch = try duplicateWorktreeBranch(allocator, scalar_object),
            .subgraph_json = try duplicateJsonObjectOrEmpty(allocator, object, "subGraph"),
            .follows_template = hasNonNullJsonField(scalar_object, "templateFollow"),
        });
        cursor = end + 1;
    }

}

fn hasNonNullJsonField(object: []const u8, key: []const u8) bool {
    const marker = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{key}) catch return false;
    defer std.heap.page_allocator.free(marker);
    const start = std.mem.indexOf(u8, object, marker) orelse return false;
    const value = std.mem.trimLeft(u8, object[start + marker.len ..], " \t\r\n");
    return !std.mem.startsWith(u8, value, "null");
}

fn decodeEdges(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    edges: *std.array_list.Managed(Edge),
) !void {
    var cursor: usize = 0;
    while (cursor < bytes.len) {
        const start = indexOfByte(bytes, cursor, '{') orelse break;
        const end = findClosing(bytes, start, '{', '}') orelse break;
        const object = bytes[start .. end + 1];
        try edges.append(.{
            .id = try duplicateJsonStringOr(allocator, object, "id", ""),
            .from = try duplicateJsonString(allocator, object, "from"),
            .to = try duplicateJsonString(allocator, object, "to"),
            .kind = try duplicateJsonStringOr(allocator, object, "kind", "handoff"),
            .condition = try duplicateJsonStringOr(allocator, object, "condition", "always"),
            .blocks_target = !std.mem.eql(u8, Wire.jsonString(object, "kind") orelse "", "message"),
            .fired = jsonBool(object, "fired") orelse false,
            .fire_count = jsonNumber(object, "fireCount") orelse 0,
        });
        cursor = end + 1;
    }
}

fn jsonBool(object: []const u8, key: []const u8) ?bool {
    const needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{key}) catch return null;
    defer std.heap.page_allocator.free(needle);
    const start = std.mem.indexOf(u8, object, needle) orelse return null;
    const value = object[start + needle.len ..];
    if (std.mem.startsWith(u8, value, "true")) return true;
    if (std.mem.startsWith(u8, value, "false")) return false;
    return null;
}

fn jsonNumber(object: []const u8, key: []const u8) ?u32 {
    const needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{key}) catch return null;
    defer std.heap.page_allocator.free(needle);
    const start = std.mem.indexOf(u8, object, needle) orelse return null;
    const value = std.mem.trimLeft(u8, object[start + needle.len ..], " ");
    var end: usize = 0;
    while (end < value.len and value[end] >= '0' and value[end] <= '9') : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseInt(u32, value[0..end], 10) catch null;
}

fn jsonNumber64(object: []const u8, key: []const u8) ?u64 {
    const needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{key}) catch return null;
    defer std.heap.page_allocator.free(needle);
    const start = std.mem.indexOf(u8, object, needle) orelse return null;
    const value = std.mem.trimLeft(u8, object[start + needle.len ..], " ");
    var end: usize = 0;
    while (end < value.len and value[end] >= '0' and value[end] <= '9') : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseInt(u64, value[0..end], 10) catch null;
}

fn jsonArrayObjectCount(object: []const u8, key: []const u8) u32 {
    const needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":[", .{key}) catch return 0;
    defer std.heap.page_allocator.free(needle);
    const start = std.mem.indexOf(u8, object, needle) orelse return 0;
    const close = std.mem.indexOfScalarPos(u8, object, start + needle.len, ']') orelse return 0;
    var count: u32 = 0;
    for (object[start + needle.len .. close]) |value| {
        if (value == '{') count += 1;
    }
    return count;
}

const MetricSamples = struct {
    values: [8]f64 = [_]f64{0} ** 8,
    count: u8 = 0,
};

fn jsonMetricSamples(object: []const u8, key: []const u8) MetricSamples {
    const needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":[", .{key}) catch return .{};
    defer std.heap.page_allocator.free(needle);
    const start = std.mem.indexOf(u8, object, needle) orelse return .{};
    const close = std.mem.indexOfScalarPos(u8, object, start + needle.len, ']') orelse return .{};
    const array = object[start + needle.len .. close];
    var result = MetricSamples{};
    var cursor: usize = 0;
    while (cursor < array.len) {
        const value_key = std.mem.indexOfPos(u8, array, cursor, "\"value\":") orelse break;
        const value = std.mem.trimLeft(u8, array[value_key + "\"value\":".len ..], " ");
        var end: usize = 0;
        while (end < value.len and (std.ascii.isDigit(value[end]) or value[end] == '.' or value[end] == '-' or value[end] == '+' or value[end] == 'e' or value[end] == 'E')) : (end += 1) {}
        if (end != 0) {
            if (std.fmt.parseFloat(f64, value[0..end])) |sample| {
                if (result.count == result.values.len) {
                    std.mem.copyForwards(f64, result.values[0 .. result.values.len - 1], result.values[1..]);
                    result.values[result.values.len - 1] = sample;
                } else {
                    result.values[result.count] = sample;
                    result.count += 1;
                }
            } else |_| {}
        }
        cursor = value_key + "\"value\":".len + end;
    }
    return result;
}

fn jsonUsageTotal(object: []const u8) ?u32 {
    const input = jsonNumber(object, "inputTokens") orelse jsonNumber(object, "inputTokenCount") orelse 0;
    const output = jsonNumber(object, "outputTokens") orelse jsonNumber(object, "outputTokenCount") orelse 0;
    if (input == 0 and output == 0) return null;
    return input +| output;
}

fn jsonFloat(object: []const u8, key: []const u8) ?f64 {
    const needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{key}) catch return null;
    defer std.heap.page_allocator.free(needle);
    const start = std.mem.indexOf(u8, object, needle) orelse return null;
    const value = std.mem.trimLeft(u8, object[start + needle.len ..], " ");
    var end: usize = 0;
    while (end < value.len and (std.ascii.isDigit(value[end]) or value[end] == '.' or value[end] == '-' or value[end] == '+' or value[end] == 'e' or value[end] == 'E')) : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseFloat(f64, value[0..end]) catch null;
}

fn duplicateJsonString(allocator: std.mem.Allocator, object: []const u8, key: []const u8) ![]u8 {
    return Wire.decodeJsonString(allocator, Wire.jsonString(object, key) orelse "");
}

fn duplicateJsonObjectOrEmpty(
    allocator: std.mem.Allocator,
    object: []const u8,
    key: []const u8,
) ![]u8 {
    const needle = try std.fmt.allocPrint(allocator, "\"{s}\":", .{key});
    defer allocator.free(needle);
    const key_start = std.mem.indexOf(u8, object, needle) orelse return allocator.dupe(u8, "");
    const value = std.mem.trimLeft(u8, object[key_start + needle.len ..], " \t\r\n");
    if (value.len == 0 or value[0] != '{') return allocator.dupe(u8, "");
    const end = findClosing(value, 0, '{', '}') orelse return allocator.dupe(u8, "");
    return allocator.dupe(u8, value[0 .. end + 1]);
}

fn withoutJsonObjectField(
    allocator: std.mem.Allocator,
    object: []const u8,
    key: []const u8,
) ![]u8 {
    const needle = try std.fmt.allocPrint(allocator, "\"{s}\":", .{key});
    defer allocator.free(needle);
    const key_start = std.mem.indexOf(u8, object, needle) orelse return allocator.dupe(u8, object);
    const value_start = key_start + needle.len;
    const value = std.mem.trimLeft(u8, object[value_start..], " \t\r\n");
    if (value.len == 0 or value[0] != '{') return allocator.dupe(u8, object);
    const value_offset = @intFromPtr(value.ptr) - @intFromPtr(object.ptr);
    const end = findClosing(object, value_offset, '{', '}') orelse return allocator.dupe(u8, object);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ object[0..key_start], object[end + 1 ..] });
}

pub fn subgraphNodeCount(subgraph_json: []const u8) usize {
    const nodes_start = std.mem.indexOf(u8, subgraph_json, "\"nodes\":") orelse return 0;
    const value = std.mem.trimLeft(u8, subgraph_json[nodes_start + "\"nodes\":".len ..], " \t\r\n");
    if (value.len == 0 or value[0] != '[') return 0;
    const end = findClosing(value, 0, '[', ']') orelse return 0;
    var count: usize = 0;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (value[1..end]) |byte| {
        if (in_string) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == '"') in_string = false;
            continue;
        }
        if (byte == '"') {
            in_string = true;
        } else if (byte == '{') {
            if (depth == 0) count += 1;
            depth += 1;
        } else if (byte == '}' and depth != 0) {
            depth -= 1;
        }
    }
    return count;
}

pub fn decodeSubgraph(
    allocator: std.mem.Allocator,
    parent_project: Project,
    subgraph_json: []const u8,
) !Graph {
    var graph = Graph{
        .project = .{
            .path = try allocator.dupe(u8, parent_project.path),
            .name = try allocator.dupe(u8, parent_project.name),
        },
        .nodes = std.array_list.Managed(Node).init(allocator),
        .edges = std.array_list.Managed(Edge).init(allocator),
    };
    errdefer freeGraph(allocator, &graph);
    if (std.mem.indexOf(u8, subgraph_json, "\"nodes\"")) |nodes_key| {
        if (indexOfByte(subgraph_json, nodes_key, '[')) |nodes_open| {
            const nodes_close = findClosing(subgraph_json, nodes_open, '[', ']') orelse
                return error.MalformedSubgraph;
            try decodeNodes(
                allocator,
                subgraph_json[nodes_open + 1 .. nodes_close],
                &graph.nodes,
            );
        }
    }
    if (std.mem.indexOf(u8, subgraph_json, "\"edges\"")) |edges_key| {
        if (indexOfByte(subgraph_json, edges_key, '[')) |edges_open| {
            const edges_close = findClosing(subgraph_json, edges_open, '[', ']') orelse
                return error.MalformedSubgraph;
            try decodeEdges(
                allocator,
                subgraph_json[edges_open + 1 .. edges_close],
                &graph.edges,
            );
        }
    }
    return graph;
}

fn indexOfByte(bytes: []const u8, start: usize, byte: u8) ?usize {
    if (start >= bytes.len) return null;
    const offset = std.mem.indexOf(u8, bytes[start..], &[_]u8{byte}) orelse return null;
    return start + offset;
}

fn duplicateJsonStringOr(
    allocator: std.mem.Allocator,
    object: []const u8,
    key: []const u8,
    fallback: []const u8,
) ![]u8 {
    return Wire.decodeJsonString(allocator, Wire.jsonString(object, key) orelse fallback);
}

fn duplicatePresence(allocator: std.mem.Allocator, object: []const u8) ![]u8 {
    if (Wire.jsonString(object, "presence")) |value| {
        return Wire.decodeJsonString(allocator, value);
    }

    const key = std.mem.indexOf(u8, object, "\"presence\"") orelse
        return allocator.dupe(u8, "");
    const open = indexOfByte(object, key, '{') orelse return allocator.dupe(u8, "");
    const close = findClosing(object, open, '{', '}') orelse return allocator.dupe(u8, "");
    const reading = object[open .. close + 1];
    return duplicateJsonStringOr(allocator, reading, "presence", "");
}

fn duplicateWorktreePath(allocator: std.mem.Allocator, object: []const u8) ![]u8 {
    const key = std.mem.indexOf(u8, object, "\"worktreeBinding\"") orelse
        return allocator.dupe(u8, "");
    const open = indexOfByte(object, key, '{') orelse return allocator.dupe(u8, "");
    const close = findClosing(object, open, '{', '}') orelse return allocator.dupe(u8, "");
    const binding = object[open .. close + 1];
    return duplicateJsonStringOr(allocator, binding, "path", Wire.jsonString(binding, "worktreePath") orelse "");
}

fn duplicateWorktreeBranch(allocator: std.mem.Allocator, object: []const u8) ![]u8 {
    const key = std.mem.indexOf(u8, object, "\"worktreeBinding\"") orelse return allocator.dupe(u8, "");
    const open = indexOfByte(object, key, '{') orelse return allocator.dupe(u8, "");
    const close = findClosing(object, open, '{', '}') orelse return allocator.dupe(u8, "");
    return duplicateJsonStringOr(allocator, object[open .. close + 1], "branch", "");
}

fn findClosing(bytes: []const u8, start: usize, open: u8, close: u8) ?usize {
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    var index = start;
    while (index < bytes.len) : (index += 1) {
        const byte = bytes[index];
        if (quoted) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == '"') quoted = false;
            continue;
        }
        if (byte == '"') {
            quoted = true;
        } else if (byte == open) {
            depth += 1;
        } else if (byte == close) {
            depth -= 1;
            if (depth == 0) return index;
        }
    }
    return null;
}

fn freeProject(allocator: std.mem.Allocator, project: Project) void {
    allocator.free(project.path);
    allocator.free(project.name);
}

fn freeNode(allocator: std.mem.Allocator, node: Node) void {
    allocator.free(node.id);
    allocator.free(node.title);
    allocator.free(node.loop_type);
    allocator.free(node.state);
    allocator.free(node.activity);
    allocator.free(node.presence);
    allocator.free(node.backend);
    allocator.free(node.pilot_state);
    allocator.free(node.goal_summary);
    allocator.free(node.goal_predicate);
    allocator.free(node.metric_command);
    allocator.free(node.metric_direction);
    allocator.free(node.trigger_prompt);
    allocator.free(node.check_description);
    allocator.free(node.model_tier);
    allocator.free(node.worktree_path);
    allocator.free(node.worktree_branch);
    allocator.free(node.subgraph_json);
}

fn freeQuickChat(allocator: std.mem.Allocator, chat: QuickChat) void {
    allocator.free(chat.id);
    allocator.free(chat.title);
    allocator.free(chat.backend);
    if (chat.activity.len != 0) allocator.free(chat.activity);
}

fn freeGraph(allocator: std.mem.Allocator, graph: *Graph) void {
    freeProject(allocator, graph.project);
    for (graph.nodes.items) |node| freeNode(allocator, node);
    for (graph.edges.items) |edge| {
        if (edge.id.len != 0) allocator.free(edge.id);
        allocator.free(edge.from);
        allocator.free(edge.to);
        allocator.free(edge.kind);
        allocator.free(edge.condition);
    }
    graph.nodes.deinit();
    graph.edges.deinit();
}

fn noticeTestModel(allocator: std.mem.Allocator) !Model {
    var model = Model.init(allocator);
    errdefer model.deinit();
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"C:\\notice-a","name":"Same"},"nodes":[{"id":"a","title":"A","state":"running","worktreeBinding":{"path":"C:\\wt-a"}}],"edges":[]}}}
    );
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"project":{"path":"C:\\notice-b","name":"Same"},"nodes":[],"edges":[]}}}
    );
    return model;
}

fn recordTestNotice(model: *Model, path: []const u8, bytes: u64) !void {
    var inspection = WorktreeStatus.Inspection{
        .entries = std.array_list.Managed(WorktreeStatus.Entry).init(std.testing.allocator),
        .project_path = try std.testing.allocator.dupe(u8, path),
        .default_branch = @constCast("main"),
    };
    defer std.testing.allocator.free(inspection.project_path);
    defer inspection.entries.deinit();
    try inspection.entries.append(.{
        .path = @constCast("tree"),
        .branch = @constCast("topic"),
        .size_bytes = bytes,
        .size_complete = true,
        .pushed = true,
        .landed = true,
    });
    try model.recordWorktreeInspection(&inspection, WorktreeStatus.policyReadOutcome(error.FileNotFound));
    @memset(inspection.project_path, 'x');
    inspection.entries.items[0].size_bytes = 0;
}

test "worktree notice observations keep exact owners and outlive inspection storage" {
    var model = try noticeTestModel(std.testing.allocator);
    defer model.deinit();
    try recordTestNotice(&model, "C:\\notice-a", 2147483648);
    try std.testing.expect(model.graphFor("C:\\notice-b").?.worktree_notice == null);
    try std.testing.expect(model.selectProject("C:\\notice-b"));
    try recordTestNotice(&model, "C:\\notice-b", 4294967296);
    try std.testing.expectEqual(@as(u64, 2147483648), model.graphFor("C:\\notice-a").?.worktree_notice.?.observation.?.size.bytes);
    try std.testing.expectEqual(@as(u64, 4294967296), model.graphFor("C:\\notice-b").?.worktree_notice.?.observation.?.size.bytes);
    std.mem.swap(GraphSummary, &model.graphs.items[0], &model.graphs.items[1]);
    try std.testing.expect(model.selectProject("C:\\notice-a"));
    try std.testing.expectEqual(WorktreeStatus.NoticeState.notice, model.graphFor("C:\\notice-a").?.worktree_notice.?.state());
    try std.testing.expectEqual(@as(usize, 1), model.graphFor("C:\\notice-b").?.worktree_notice.?.observation.?.summary.total);
    try std.testing.expectError(error.WorktreeProjectClosed, recordTestNotice(&model, "C:\\foreign", 1));
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":3,"event":{"graphChanged":{"project":{"path":"ssh://host/repo","name":"Same"},"nodes":[],"edges":[]}}}
    );
    try std.testing.expectError(error.UnsupportedWorktreeProject, recordTestNotice(&model, "ssh://host/repo", 2147483648));
    try std.testing.expect(model.graphFor("ssh://host/repo").?.worktree_notice == null);
}

test "worktree notice failed refresh and policy outcome never fabricate new counts" {
    var model = try noticeTestModel(std.testing.allocator);
    defer model.deinit();
    try recordTestNotice(&model, "C:\\notice-a", 2147483648);
    try model.recordWorktreeFailure("C:\\notice-a", error.GitFailed);
    const failed = model.graphFor("C:\\notice-a").?.worktree_notice.?;
    try std.testing.expectEqual(@as(u64, 2147483648), failed.observation.?.size.bytes);
    try std.testing.expectEqual(@as(?anyerror, error.GitFailed), failed.refresh_error);
    try std.testing.expectEqual(WorktreeStatus.NoticeState.indeterminate, failed.state());
    try model.recordWorktreeFailure("C:\\notice-b", error.GitFailed);
    try std.testing.expect(model.graphFor("C:\\notice-b").?.worktree_notice.?.observation == null);
    try recordTestNotice(&model, "C:\\notice-a", 2147483648);
    try model.recordWorktreePolicy("C:\\notice-a", WorktreeStatus.policyReadOutcome(error.AccessDenied));
    try std.testing.expectEqual(WorktreeStatus.NoticeState.indeterminate, model.graphFor("C:\\notice-a").?.worktree_notice.?.state());
    try model.recordWorktreePolicy("C:\\notice-a", WorktreeStatus.policyReadOutcome(
        \\{"allowReclaim":false,"confirmEachReclaim":true,"onResolveLanded":"keep","noticeSizeGB":4,"noticeCount":12}
    ));
    try std.testing.expectEqual(WorktreeStatus.NoticeState.below_threshold, model.graphFor("C:\\notice-a").?.worktree_notice.?.state());
    try std.testing.expectEqual(@as(?anyerror, error.GitFailed), model.graphFor("C:\\notice-b").?.worktree_notice.?.refresh_error);
}

test "worktree notice invalidation follows bindings connection and actual owner lifetime" {
    var model = try noticeTestModel(std.testing.allocator);
    defer model.deinit();
    try recordTestNotice(&model, "C:\\notice-a", 2147483648);
    try recordTestNotice(&model, "C:\\notice-b", 2147483648);
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":3,"event":{"graphChanged":{"project":{"path":"C:\\notice-a","name":"Same"},"nodes":[{"id":"a","title":"Renamed","state":"running","position":{"x":900,"y":20},"worktreeBinding":{"path":"C:\\wt-a"}}],"edges":[]}}}
    );
    try std.testing.expect(model.graphFor("C:\\notice-a").?.worktree_notice.?.stale == null);
    try std.testing.expect(model.graphFor("C:\\notice-b").?.worktree_notice.?.stale == null);
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":4,"event":{"graphChanged":{"project":{"path":"C:\\notice-a","name":"Same"},"nodes":[{"id":"a","title":"Renamed","state":"succeeded","worktreeBinding":{"path":"C:\\wt-a"}}],"edges":[]}}}
    );
    for (model.graphs.items) |graph| try std.testing.expectEqual(@as(?WorktreeStatus.StaleReason, .bindings_changed), graph.worktree_notice.?.stale);
    try recordTestNotice(&model, "C:\\notice-a", 2147483648);
    try std.testing.expectEqual(WorktreeStatus.NoticeState.notice, model.graphFor("C:\\notice-a").?.worktree_notice.?.state());
    try std.testing.expectEqual(WorktreeStatus.NoticeState.indeterminate, model.graphFor("C:\\notice-b").?.worktree_notice.?.state());
    model.markReconnecting();
    try std.testing.expectEqual(@as(?WorktreeStatus.StaleReason, .connection_changed), model.graphFor("C:\\notice-a").?.worktree_notice.?.stale);
    try std.testing.expect(model.applyLifecycle(.close, "C:\\notice-a"));
    try std.testing.expect(model.graphFor("C:\\notice-a") == null);
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":5,"event":{"graphChanged":{"project":{"path":"C:\\notice-a","name":"Same"},"nodes":[],"edges":[]}}}
    );
    try std.testing.expect(model.graphFor("C:\\notice-a").?.worktree_notice == null);
    model.beginRestore();
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":6,"event":{"graphChanged":{"project":{"path":"C:\\notice-b","name":"Same"},"nodes":[],"edges":[]}}}
    );
    model.markRestored();
    try std.testing.expect(model.graphFor("C:\\notice-a") == null);
    try std.testing.expect(model.graphFor("C:\\notice-b").?.worktree_notice != null);
    model.invalidateWorktreeNotices(.worktrees_changed);
    try std.testing.expectEqual(@as(?WorktreeStatus.StaleReason, .worktrees_changed), model.graphFor("C:\\notice-b").?.worktree_notice.?.stale);
}

test "worktree notice branch binding changes invalidate otherwise unchanged observations" {
    var model = try noticeTestModel(std.testing.allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":3,"event":{"graphChanged":{"project":{"path":"C:\\notice-a","name":"Same"},"nodes":[{"id":"a","title":"A","state":"running","worktreeBinding":{"path":"C:\\wt-a","branch":"main"}}],"edges":[]}}}
    );
    try recordTestNotice(&model, "C:\\notice-a", 2147483648);
    try recordTestNotice(&model, "C:\\notice-b", 2147483648);
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":4,"event":{"graphChanged":{"project":{"path":"C:\\notice-a","name":"Same"},"nodes":[{"id":"a","title":"A","state":"running","worktreeBinding":{"path":"C:\\wt-a","branch":"feature"}}],"edges":[]}}}
    );
    try std.testing.expectEqual(@as(?WorktreeStatus.StaleReason, .bindings_changed), model.graphFor("C:\\notice-a").?.worktree_notice.?.stale);
    try std.testing.expectEqual(@as(?WorktreeStatus.StaleReason, .bindings_changed), model.graphFor("C:\\notice-b").?.worktree_notice.?.stale);
}

fn loadNestedNoticeTestGraph(model: *Model, subgraph: []const u8, parent_type: []const u8) !void {
    const frame = try std.mem.concat(std.testing.allocator, u8, &.{
        "{\"version\":2,\"kind\":\"event\",\"sequence\":20,\"event\":{\"graphChanged\":{\"project\":{\"path\":\"C:\\\\notice-a\",\"name\":\"A\"},\"nodes\":[{\"id\":\"group\",\"title\":\"Group\",\"loopType\":\"",
        parent_type,
        "\",\"subGraph\":",
        subgraph,
        "}],\"edges\":[]}}}",
    });
    defer std.testing.allocator.free(frame);
    _ = try model.updateFromFrame(frame);
}

fn recordActiveNestedNotice(model: *Model) !void {
    const active = model.graph.?;
    const node = active.nodes.items[findNodeIndexByID(active.nodes.items, "child").?];
    var inspection = WorktreeStatus.Inspection{
        .project_path = active.project.path,
        .default_branch = @constCast("main"),
        .entries = std.array_list.Managed(WorktreeStatus.Entry).init(std.testing.allocator),
    };
    defer inspection.entries.deinit();
    try inspection.entries.append(.{
        .path = node.worktree_path,
        .branch = node.worktree_branch,
        .bound_running = true,
        .size_bytes = 2147483648,
        .size_complete = true,
    });
    try model.recordWorktreeInspection(&inspection, WorktreeStatus.policyReadOutcome(error.FileNotFound));
}

test "worktree notice nested binding changes invalidate an active composite inspection" {
    var model = try noticeTestModel(std.testing.allocator);
    defer model.deinit();
    try loadNestedNoticeTestGraph(&model,
        \\{"nodes":[{"id":"child","title":"Child","loopType":"turnBased","state":"running","worktreeBinding":{"path":"C:\\nested-a","branch":"main"}}],"edges":[]}
    , "composite");
    try std.testing.expect(model.openComposite("group"));
    try std.testing.expectEqualStrings("C:\\nested-a", model.graph.?.nodes.items[0].worktree_path);
    try recordActiveNestedNotice(&model);
    try loadNestedNoticeTestGraph(&model,
        \\{"nodes":[{"id":"child","title":"Child","loopType":"turnBased","state":"running","worktreeBinding":{"path":"C:\\nested-b","branch":"main"}}],"edges":[]}
    , "composite");
    try std.testing.expectEqualStrings("C:\\nested-b", model.graph.?.nodes.items[0].worktree_path);
    try std.testing.expectEqual(@as(?WorktreeStatus.StaleReason, .bindings_changed), model.graphFor("C:\\notice-a").?.worktree_notice.?.stale);
}

const nested_notice_baseline =
    \\{"nodes":[{"id":"child","title":"Child","loopType":"turnBased","state":"running","worktreeBinding":{"path":"C:\\nested-a","branch":"main"}},{"id":"peer","title":"Peer","state":"idle"}],"edges":[]}
;

test "worktree notice nested branch state removal and type changes invalidate by stable scope" {
    const branch_change =
        \\{"nodes":[{"id":"child","title":"Child","loopType":"turnBased","state":"running","worktreeBinding":{"path":"C:\\nested-a","branch":"topic"}},{"id":"peer","title":"Peer","state":"idle"}],"edges":[]}
    ;
    const state_change =
        \\{"nodes":[{"id":"child","title":"Child","loopType":"turnBased","state":"succeeded","worktreeBinding":{"path":"C:\\nested-a","branch":"main"}},{"id":"peer","title":"Peer","state":"idle"}],"edges":[]}
    ;
    const removal =
        \\{"nodes":[{"id":"peer","title":"Peer","state":"idle"}],"edges":[]}
    ;
    const type_change =
        \\{"nodes":[{"id":"child","title":"Child","loopType":"goalBased","state":"running","worktreeBinding":{"path":"C:\\nested-a","branch":"main"}},{"id":"peer","title":"Peer","state":"idle"}],"edges":[]}
    ;
    const cases = [_]struct { graph: []const u8, parent_type: []const u8 = "composite" }{
        .{ .graph = branch_change },
        .{ .graph = state_change },
        .{ .graph = removal },
        .{ .graph = type_change },
        .{ .graph = nested_notice_baseline, .parent_type = "turnBased" },
        .{ .graph = nested_notice_baseline, .parent_type = "proactive" },
    };
    for (cases) |case| {
        var model = try noticeTestModel(std.testing.allocator);
        defer model.deinit();
        try loadNestedNoticeTestGraph(&model, nested_notice_baseline, "composite");
        try std.testing.expect(model.openComposite("group"));
        try recordActiveNestedNotice(&model);
        try loadNestedNoticeTestGraph(&model, case.graph, case.parent_type);
        try std.testing.expectEqual(@as(?WorktreeStatus.StaleReason, .bindings_changed), model.graphFor("C:\\notice-a").?.worktree_notice.?.stale);
    }
}

test "worktree notice nested reorder title and position edits retain the inspected values" {
    var model = try noticeTestModel(std.testing.allocator);
    defer model.deinit();
    try loadNestedNoticeTestGraph(&model, nested_notice_baseline, "proactive");
    try std.testing.expect(model.openComposite("group"));
    try recordActiveNestedNotice(&model);
    const previous = model.graphFor("C:\\notice-a").?.worktree_notice.?;
    try loadNestedNoticeTestGraph(&model,
        \\{"nodes":[{"id":"peer","title":"Renamed peer","state":"idle","position":{"x":10,"y":20}},{"id":"child","title":"Renamed child","loopType":"turnBased","state":"running","position":{"x":90,"y":30},"worktreeBinding":{"path":"C:\\nested-a","branch":"main"}}],"edges":[]}
    , "proactive");
    try std.testing.expectEqualDeep(previous, model.graphFor("C:\\notice-a").?.worktree_notice.?);
    const repeated = model.graphFor("C:\\notice-a").?.nodes.items[0].subgraph_json;
    const owned_repeat = try std.testing.allocator.dupe(u8, repeated);
    defer std.testing.allocator.free(owned_repeat);
    try loadNestedNoticeTestGraph(&model, owned_repeat, "proactive");
    try std.testing.expectEqualDeep(previous, model.graphFor("C:\\notice-a").?.worktree_notice.?);
}

test "worktree notice comparisons recurse into deeper supported scopes" {
    var model = try noticeTestModel(std.testing.allocator);
    defer model.deinit();
    try loadNestedNoticeTestGraph(&model,
        \\{"nodes":[{"id":"child","title":"Child","loopType":"turnBased","state":"running","worktreeBinding":{"path":"C:\\nested-a","branch":"main"}},{"id":"inner","loopType":"proactive","subGraph":{"nodes":[{"id":"child","state":"running","worktreeBinding":{"path":"C:\\deep","branch":"main"}}],"edges":[]}}],"edges":[]}
    , "composite");
    try std.testing.expect(model.openComposite("group"));
    try recordActiveNestedNotice(&model);
    try loadNestedNoticeTestGraph(&model,
        \\{"nodes":[{"id":"inner","loopType":"proactive","subGraph":{"nodes":[{"id":"child","state":"running","worktreeBinding":{"path":"C:\\deep","branch":"changed"}}],"edges":[]}},{"id":"child","title":"Child","loopType":"turnBased","state":"running","worktreeBinding":{"path":"C:\\nested-a","branch":"main"}}],"edges":[]}
    , "composite");
    try std.testing.expectEqual(@as(?WorktreeStatus.StaleReason, .bindings_changed), model.graphFor("C:\\notice-a").?.worktree_notice.?.stale);
}

test "worktree notice malformed unsupported and ambiguous nested data remain uncertain" {
    const cases = [_][]const u8{
        "{\"nodes\":1,\"edges\":[]}",
        "{bad}",
        "{\"nodes\":[{\"id\":\"same\"},{\"id\":\"same\"}],\"edges\":[]}",
        "{\"nodes\":[{\"id\":\"child\",\"subGraph\":{\"nodes\":[],\"edges\":[]}}],\"edges\":[]}",
    };
    for (cases) |graph| {
        var model = try noticeTestModel(std.testing.allocator);
        defer model.deinit();
        try loadNestedNoticeTestGraph(&model, graph, "composite");
        try recordTestNotice(&model, "C:\\notice-a", 2147483648);
        try loadNestedNoticeTestGraph(&model, graph, "composite");
        const record = model.graphFor("C:\\notice-a").?.worktree_notice.?;
        try std.testing.expectEqual(@as(?WorktreeStatus.StaleReason, .bindings_unavailable), record.stale);
        try std.testing.expect(record.stale_error != null);
        try std.testing.expectEqual(WorktreeStatus.NoticeState.indeterminate, record.state());
        const presentation = WorktreeStatus.NoticePresentation.fromRecord(record).?;
        try std.testing.expectEqual(WorktreeStatus.NoticePhase.stale, presentation.phase);
        try std.testing.expectEqual(record.stale_error, presentation.failure);
    }
}

test "worktree notice nested comparison OOM retains explicit uncertainty without altering nodes" {
    var model = try noticeTestModel(std.testing.allocator);
    defer model.deinit();
    try loadNestedNoticeTestGraph(&model, nested_notice_baseline, "composite");
    try std.testing.expect(model.openComposite("group"));
    try recordActiveNestedNotice(&model);
    const owner = model.graphFor("C:\\notice-a").?;
    const nodes = owner.nodes.items;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    model.allocator = failing.allocator();
    model.invalidateForWorktreeBindings(owner.project, nodes, nodes);
    model.allocator = std.testing.allocator;
    try std.testing.expect(failing.has_induced_failure);
    const record = model.graphFor("C:\\notice-a").?.worktree_notice.?;
    try std.testing.expectEqual(@as(?anyerror, error.OutOfMemory), record.stale_error);
    try std.testing.expectEqual(@as(?WorktreeStatus.StaleReason, .bindings_unavailable), record.stale);
    try std.testing.expectEqualStrings(nested_notice_baseline, nodes[0].subgraph_json);
    try std.testing.expectEqual(@as(u64, 2147483648), record.observation.?.size.bytes);
    try recordActiveNestedNotice(&model);
    try std.testing.expect(model.graphFor("C:\\notice-a").?.worktree_notice.?.stale_error == null);
}

test "worktree notice flat title-only comparison does not allocate recursive scratch" {
    var model = try noticeTestModel(std.testing.allocator);
    defer model.deinit();
    try recordTestNotice(&model, "C:\\notice-a", 2147483648);
    const owner = model.graphFor("C:\\notice-a").?;
    const previous = owner.worktree_notice.?;
    var edited = owner.nodes.items[0];
    edited.title = @constCast("A renamed");
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    model.allocator = failing.allocator();
    model.invalidateForWorktreeBindings(owner.project, owner.nodes.items, &.{edited});
    model.allocator = std.testing.allocator;
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqualDeep(previous, model.graphFor("C:\\notice-a").?.worktree_notice.?);
}

test "worktree notice comparison depth row work and scratch bounds fail closed" {
    const allocator = std.testing.allocator;
    var model = try noticeTestModel(allocator);
    defer model.deinit();
    const project = model.graphFor("C:\\notice-a").?.project;
    var comparison = WorktreeBindingComparison{ .allocator = allocator, .project = project };
    try std.testing.expect(!(try comparison.compare(&.{}, &.{}, 32)));
    try std.testing.expectError(error.WorktreeComparisonLimit, comparison.compare(&.{}, &.{}, 33));
    const nodes = try allocator.alloc(Node, 4097);
    defer allocator.free(nodes);
    for (nodes) |*node| node.* = .{
        .id = @constCast("unused"),
        .title = @constCast(""),
        .loop_type = @constCast("turnBased"),
        .state = @constCast("idle"),
        .activity = @constCast(""),
        .presence = @constCast(""),
    };
    try std.testing.expect(!(try worktreeBindingsChanged(allocator, project, nodes[0..4096], &.{})));
    try std.testing.expectError(error.WorktreeComparisonLimit, worktreeBindingsChanged(allocator, project, nodes, &.{}));
    const oversized = try allocator.alloc(u8, 4194305);
    defer allocator.free(oversized);
    @memset(oversized, ' ');
    nodes[0].subgraph_json = oversized;
    try std.testing.expectError(error.WorktreeComparisonLimit, worktreeBindingsChanged(allocator, project, nodes[0..1], &.{}));
    var tiny: [1]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&tiny);
    comparison = .{ .allocator = scratch.allocator(), .project = project };
    try std.testing.expectError(error.OutOfMemory, comparison.compare(nodes[0..1], &.{}, 0));
}

test "worktree notice deeply nested identical frames never bypass comparison bounds" {
    const allocator = std.testing.allocator;
    var graph = try allocator.dupe(u8, "{\"nodes\":[],\"edges\":[]}");
    defer allocator.free(graph);
    for (0..34) |index| {
        const wrapped = try std.fmt.allocPrint(allocator, "{{\"nodes\":[{{\"id\":\"layer-{d}\",\"loopType\":\"composite\",\"subGraph\":{s}}}],\"edges\":[]}}", .{ index, graph });
        allocator.free(graph);
        graph = wrapped;
    }
    var model = try noticeTestModel(allocator);
    defer model.deinit();
    try loadNestedNoticeTestGraph(&model, graph, "composite");
    try recordTestNotice(&model, "C:\\notice-a", 2147483648);
    try loadNestedNoticeTestGraph(&model, graph, "composite");
    const record = model.graphFor("C:\\notice-a").?.worktree_notice.?;
    try std.testing.expectEqual(@as(?WorktreeStatus.StaleReason, .bindings_unavailable), record.stale);
    try std.testing.expectEqual(@as(?anyerror, error.WorktreeComparisonLimit), record.stale_error);
    try std.testing.expectEqual(WorktreeStatus.NoticeState.indeterminate, record.state());
}

test "graph snapshots decode escaped project data and presence" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const frame =
        \\{"version":2,"kind":"event","sequence":7,"event":{"graphChanged":{"id":"graph","project":{"path":"C:\\work\\graph","name":"Visual \u2603"},"nodes":[{"id":"node","title":"Node \"A\"","loopType":"turnBased","state":"running","activity":"editing","presence":{"presence":"busy","confidence":"reported"}}],"edges":[]}}}
    ;
    try std.testing.expectEqual(Wire.EventKind.graph_changed, try model.updateFromFrame(frame));
    const graph = model.graph orelse return error.TestExpectedGraph;
    try std.testing.expectEqualStrings("C:\\work\\graph", graph.project.path);
    try std.testing.expectEqualStrings("Visual ☃", graph.project.name);
    try std.testing.expectEqual(@as(usize, 1), graph.nodes.items.len);
    try std.testing.expectEqualStrings("Node \"A\"", graph.nodes.items[0].title);
    try std.testing.expectEqualStrings("busy", graph.nodes.items[0].presence);
}

test "stub graph snapshot decodes two actionable nodes" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const frame =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"stub-graph","project":{"path":"graphcode://stub/project","name":"Stub project"},"nodes":[{"id":"11111111-1111-4111-8111-111111111111","title":"Stub node A","loopType":"turnBased","state":"running","activity":"stub","presence":{"presence":"busy","confidence":"reported"}},{"id":"22222222-2222-4222-8222-222222222222","title":"Stub node B","loopType":"turnBased","state":"idle","activity":"stub","presence":{"presence":"idle","confidence":"reported"}}],"edges":[]}}}
    ;
    try std.testing.expectEqual(Wire.EventKind.graph_changed, try model.updateFromFrame(frame));
    const graph = model.graph orelse return error.TestExpectedGraph;
    try std.testing.expectEqualStrings("graphcode://stub/project", graph.project.path);
    try std.testing.expectEqual(@as(usize, 2), graph.nodes.items.len);
    try std.testing.expectEqualStrings(
        "11111111-1111-4111-8111-111111111111",
        graph.nodes.items[0].id,
    );
    try std.testing.expectEqualStrings("busy", graph.nodes.items[0].presence);
    try std.testing.expectEqualStrings("idle", graph.nodes.items[1].presence);
}

test "template-following nodes retain their detach eligibility" {
    const allocator = std.testing.allocator;
    var nodes = std.array_list.Managed(Node).init(allocator);
    defer {
        for (nodes.items) |node| freeNode(allocator, node);
        nodes.deinit();
    }
    try decodeNodes(
        allocator,
        \\[{"id":"11111111-1111-4111-8111-111111111111","title":"Template loop","loopType":"turnBased","state":{"idle":{}},"pausesBeforeWritesOnly":false,"pilotState":"notPiloted","templateFollow":{"id":"22222222-2222-4222-8222-222222222222"}}]
    ,
        &nodes,
    );
    try std.testing.expect(nodes.items[0].follows_template);
}

test "reordered graph fixture preserves nonsequential edge IDs" {
    const allocator = std.testing.allocator;
    const frame = try std.fs.cwd().readFileAlloc(
        allocator,
        "fixtures/daemon-v2-graph-reordered-edges.json",
        64 * 1024,
    );
    defer allocator.free(frame);
    var model = Model.init(allocator);
    defer model.deinit();
    try std.testing.expectEqual(Wire.EventKind.graph_changed, try model.updateFromFrame(frame));
    const graph = model.graph orelse return error.TestExpectedGraph;
    try std.testing.expectEqualStrings("node-z", graph.nodes.items[0].id);
    try std.testing.expectEqualStrings("node-a", graph.nodes.items[1].id);
    try std.testing.expectEqualStrings("node-a", graph.edges.items[0].from);
    try std.testing.expectEqualStrings("node-q", graph.edges.items[0].to);
    try std.testing.expectEqualStrings("node-z", graph.edges.items[1].from);
    try std.testing.expectEqualStrings("node-a", graph.edges.items[1].to);
}

test "quick chat fixture preserves stable identity and activity ordering" {
    const allocator = std.testing.allocator;
    const frame = try std.fs.cwd().readFileAlloc(
        allocator,
        "fixtures/daemon-v2-quick-chats.json",
        64 * 1024,
    );
    defer allocator.free(frame);
    var model = Model.init(allocator);
    defer model.deinit();
    try std.testing.expectEqual(Wire.EventKind.quick_chats, try model.updateFromFrame(frame));
    try std.testing.expectEqual(@as(usize, 2), model.quick_chats.items.len);
    try std.testing.expectEqualStrings("Scratch", model.quick_chats.items[0].title);
    try std.testing.expectEqual(@as(u64, 2), model.quick_chats.items[0].activity_sequence);
}

test "project identity derives remote and global from Codable paths" {
    const remote = Project{ .path = @constCast("ssh://build/graph"), .name = @constCast("Remote") };
    const global = Project{ .path = @constCast("graphcode://global"), .name = @constCast("Graph") };
    const local = Project{ .path = @constCast("C:\\work\\graph"), .name = @constCast("Local") };
    try std.testing.expect(remote.isRemote());
    try std.testing.expect(!remote.isGlobal());
    try std.testing.expect(global.isGlobal());
    try std.testing.expect(!global.isRemote());
    try std.testing.expect(!local.isRemote());
    try std.testing.expect(!local.isGlobal());

    const codespace = Project{
        .path = @constCast("codespace://dev-widget-x5jq4w/workspaces/widget"),
        .name = @constCast("widget"),
    };
    try std.testing.expect(codespace.isRemote());
    try std.testing.expect(codespace.isCodespace());
    try std.testing.expect(!codespace.isGlobal());
    try std.testing.expect(!codespace.isLocalFilesystem());
    try std.testing.expect(!remote.isCodespace());
}

test "multi-project fixture retains both summaries and selection identity" {
    const allocator = std.testing.allocator;
    var model = Model.init(allocator);
    defer model.deinit();
    const local = try std.fs.cwd().readFileAlloc(allocator, "fixtures/daemon-v2-multi-project.json", 64 * 1024);
    defer allocator.free(local);
    const remote = try std.fs.cwd().readFileAlloc(allocator, "fixtures/daemon-v2-multi-project-remote.json", 64 * 1024);
    defer allocator.free(remote);
    _ = try model.updateFromFrame(local);
    _ = try model.updateFromFrame(remote);
    try std.testing.expectEqual(@as(usize, 2), model.graphs.items.len);
    try std.testing.expectEqual(@as(usize, 2), model.open_projects.items.len);
    try std.testing.expectEqualStrings("C:\\work\\local", model.selected_project_path.?);
    try std.testing.expect(model.graphFor("C:\\work\\local") != null);
    try std.testing.expect(model.selectProject("C:\\work\\local"));
    try std.testing.expectEqualStrings("C:\\work\\local", model.selected_project_path.?);
}

test "current graph and selection operations resolve the selected project" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const first =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"a","project":{"path":"a","name":"A"},"nodes":[{"id":"a1","title":"A1","state":"running"}],"edges":[{"from":"a1","to":"a1","kind":"message"}]}}}
    ;
    const second =
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"id":"b","project":{"path":"b","name":"B"},"nodes":[{"id":"b1","title":"B1","state":"running"},{"id":"b2","title":"B2","state":"running"}],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(first);
    _ = try model.updateFromFrame(second);
    try std.testing.expectEqual(@as(usize, 1), model.graphFor("a").?.edges.items.len);
    try std.testing.expectEqualStrings("a", model.currentGraph().?.project.path);
    model.selectNext();
    try std.testing.expectEqualStrings("A1", model.selected().?.title);
    try std.testing.expect(model.selectProject("b"));
    try std.testing.expectEqualStrings("b", model.currentGraph().?.project.path);
    model.selectNext();
    try std.testing.expectEqualStrings("B2", model.selected().?.title);
}

test "selecting B resynchronizes the active snapshot and current graph" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const a =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"a","project":{"path":"A","name":"A"},"nodes":[{"id":"a1","title":"A1","state":"running"}],"edges":[]}}}
    ;
    const b =
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"id":"b","project":{"path":"B","name":"B"},"nodes":[{"id":"b1","title":"B1","state":"failed"}],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(a);
    _ = try model.updateFromFrame(b);
    try std.testing.expect(model.selectProject("B"));
    try std.testing.expectEqualStrings("B", model.currentGraph().?.project.path);
    try std.testing.expectEqualStrings("B", model.graph.?.project.path);
    try std.testing.expectEqualStrings("B1", model.graph.?.nodes.items[0].title);
}

test "restore generation removes unreplayed graphs and preserves valid selection" {
    const allocator = std.testing.allocator;
    var model = Model.init(allocator);
    defer model.deinit();
    const local = try std.fs.cwd().readFileAlloc(allocator, "fixtures/daemon-v2-multi-project.json", 64 * 1024);
    defer allocator.free(local);
    const remote = try std.fs.cwd().readFileAlloc(allocator, "fixtures/daemon-v2-multi-project-remote.json", 64 * 1024);
    defer allocator.free(remote);
    _ = try model.updateFromFrame(local);
    _ = try model.updateFromFrame(remote);
    try std.testing.expect(model.selectProject("ssh://build/remote"));
    model.beginRestore();
    _ = try model.updateFromFrame(remote);
    model.markRestored();
    try std.testing.expectEqual(@as(usize, 1), model.graphs.items.len);
    try std.testing.expectEqualStrings("ssh://build/remote", model.selected_project_path.?);
    try std.testing.expectEqual(RestoreState.restored, model.restore_state);
}

test "restore fallback resynchronizes graph after removing selected A" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const a =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"a","project":{"path":"A","name":"A"},"nodes":[{"id":"a1","title":"A1","state":"running"}],"edges":[]}}}
    ;
    const b =
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"id":"b","project":{"path":"B","name":"B"},"nodes":[{"id":"b1","title":"B1","state":"failed"}],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(a);
    _ = try model.updateFromFrame(b);
    try std.testing.expect(model.selectProject("A"));
    model.beginRestore();
    _ = try model.updateFromFrame(b);
    model.markRestored();
    try std.testing.expectEqualStrings("B", model.selected_project_path.?);
    try std.testing.expectEqualStrings("B", model.currentGraph().?.project.path);
    try std.testing.expectEqualStrings("B", model.graph.?.project.path);
    try std.testing.expectEqualStrings("B1", model.graph.?.nodes.items[0].title);
}

test "attention aggregate keeps project and node identity" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const local =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"a","project":{"path":"a","name":"A"},"nodes":[{"id":"a1","title":"Local failure","state":"failed"}],"edges":[]}}}
    ;
    const remote =
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"id":"b","project":{"path":"b","name":"B"},"nodes":[{"id":"b1","title":"Remote question","state":"running","presence":{"presence":"awaitingInput"}}],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(local);
    _ = try model.updateFromFrame(remote);
    try std.testing.expectEqual(@as(usize, 2), model.attention_entries.items.len);
    try std.testing.expectEqualStrings("a", model.attention_entries.items[0].project_path);
    try std.testing.expectEqualStrings("a1", model.attention_entries.items[0].node.id);
    try std.testing.expectEqualStrings("b", model.attention_entries.items[1].project_path);
    model.selectNextAttention();
    try std.testing.expectEqualStrings("b", model.selected_project_path.?);
}

test "close forget and delete have distinct graph lifecycle semantics" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const frame =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"g","project":{"path":"C:\\work\\graph","name":"Graph"},"nodes":[],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(frame);
    try model.recent_projects.append(.{
        .path = try std.testing.allocator.dupe(u8, "C:\\work\\graph"),
        .name = try std.testing.allocator.dupe(u8, "Graph"),
    });
    try std.testing.expect(model.applyLifecycle(.close, "C:\\work\\graph"));
    try std.testing.expectEqual(@as(usize, 0), model.graphs.items.len);
    try std.testing.expectEqual(@as(usize, 1), model.recent_projects.items.len);
    try std.testing.expect(model.applyLifecycle(.forget, "C:\\work\\graph"));
    try std.testing.expectEqual(@as(usize, 0), model.recent_projects.items.len);
}

test "lifecycle callback receives an owned path before graph storage is freed" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const frame =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"g","project":{"path":"owned-path","name":"Graph"},"nodes":[],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(frame);
    var probe = LifecycleProbe{};
    model.setLifecycleCallback(&probe, lifecycleProbeCallback);
    try std.testing.expect(model.applyLifecycle(.close, model.graphs.items[0].project.path));
    try std.testing.expect(probe.called);
    try std.testing.expectEqualStrings("owned-path", probe.path[0..probe.path_len]);
}

test "closing selected A preserves project B and its active snapshot" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const a =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"a","project":{"path":"A","name":"A"},"nodes":[{"id":"a1","title":"A1","state":"running"}],"edges":[]}}}
    ;
    const b =
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"id":"b","project":{"path":"B","name":"B"},"nodes":[{"id":"b1","title":"B1","state":"running"}],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(a);
    _ = try model.updateFromFrame(b);
    try std.testing.expect(model.selectProject("A"));
    try std.testing.expect(model.applyLifecycle(.close, "A"));
    try std.testing.expectEqualStrings("B", model.selected_project_path.?);
    try std.testing.expectEqualStrings("B", model.currentGraph().?.project.path);
    try std.testing.expectEqualStrings("B", model.graph.?.project.path);
}

test "closing snapshot B while selected A resynchronizes the active graph to A" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const a =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"a","project":{"path":"A","name":"A"},"nodes":[{"id":"a1","title":"A1","state":"running"}],"edges":[]}}}
    ;
    const b =
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"id":"b","project":{"path":"B","name":"B"},"nodes":[{"id":"b1","title":"B1","state":"running"}],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(a);
    _ = try model.updateFromFrame(b);
    try std.testing.expect(model.selectProject("A"));
    try std.testing.expectEqualStrings("A", model.currentGraph().?.project.path);
    try std.testing.expect(model.applyLifecycle(.close, "B"));
    try std.testing.expectEqualStrings("A", model.selected_project_path.?);
    try std.testing.expectEqualStrings("A", model.currentGraph().?.project.path);
    try std.testing.expectEqualStrings("A", model.graph.?.project.path);
}

test "restore remains restoring until markRestored" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const frame =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"g","project":{"path":"restore-path","name":"Graph"},"nodes":[],"edges":[]}}}
    ;
    model.beginRestore();
    _ = try model.updateFromFrame(frame);
    try std.testing.expectEqual(RestoreState.restoring, model.restore_state);
    model.markRestored();
    try std.testing.expectEqual(RestoreState.restored, model.restore_state);
}

test "activity compares the prior graph for the same project across interleaved updates" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const a1 =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"a","project":{"path":"a","name":"A"},"nodes":[{"id":"a1","title":"A","state":"running"}],"edges":[]}}}
    ;
    const b1 =
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"id":"b","project":{"path":"b","name":"B"},"nodes":[{"id":"b1","title":"B","state":"running"}],"edges":[]}}}
    ;
    const a2 =
        \\{"version":2,"kind":"event","sequence":3,"event":{"graphChanged":{"id":"a","project":{"path":"a","name":"A"},"nodes":[{"id":"a1","title":"A","state":"failed"}],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(a1);
    _ = try model.updateFromFrame(b1);
    _ = try model.updateFromFrame(a2);
    try std.testing.expectEqual(@as(usize, 1), model.activity.items.len);
    try std.testing.expectEqualStrings("A", model.activity.items[0].title);
    try std.testing.expectEqualStrings("failed", model.activity.items[0].state);
}

test "worktrees are limited to local filesystem projects" {
    const local = Project{ .path = @constCast("C:\\work\\graph"), .name = @constCast("Graph") };
    const remote = Project{ .path = @constCast("ssh://host/graph"), .name = @constCast("Graph") };
    const global = Project{ .path = @constCast("graphcode://global"), .name = @constCast("Global") };
    try std.testing.expect(local.isLocalFilesystem());
    try std.testing.expect(!remote.isLocalFilesystem());
    try std.testing.expect(!global.isLocalFilesystem());
}

test "attention fixture preserves awaiting input and stranded edge metadata" {
    const allocator = std.testing.allocator;
    const frame = try std.fs.cwd().readFileAlloc(
        allocator,
        "fixtures/daemon-v2-graph-attention.json",
        64 * 1024,
    );
    defer allocator.free(frame);
    var model = Model.init(allocator);
    defer model.deinit();
    try std.testing.expectEqual(Wire.EventKind.graph_changed, try model.updateFromFrame(frame));
    const graph = model.graph orelse return error.TestExpectedGraph;
    try std.testing.expectEqualStrings("awaitingInput", graph.nodes.items[0].presence);
    try std.testing.expectEqualStrings("handoff", graph.edges.items[0].kind);
    try std.testing.expect(!graph.edges.items[0].fired);
}

test "attention rollup surfaces awaiting input and failures" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const frame =
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"id":"g","project":{"path":"C:\\work\\graph","name":"Graph","remote":false},"nodes":[{"id":"a","title":"Question","loopType":"turnBased","state":"running","presence":{"presence":"awaitingInput","confidence":"reported"}},{"id":"b","title":"Broken","loopType":"goalBased","state":"failed","presence":{"presence":"idle","confidence":"reported"}}],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(frame);
    try std.testing.expectEqual(@as(usize, 2), model.attentionCount());
    try std.testing.expectEqualStrings("Broken", model.attention.items[0].title);
    try std.testing.expectEqualStrings("Question", model.attention.items[1].title);
}

test "activity log records state transitions but not initial snapshot" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const first =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"g","project":{"path":"C:\\work\\graph","name":"Graph","remote":false},"nodes":[{"id":"a","title":"Worker","loopType":"goalBased","state":"running","presence":{"presence":"busy","confidence":"reported"}}],"edges":[]}}}
    ;
    const second =
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"id":"g","project":{"path":"C:\\work\\graph","name":"Graph","remote":false},"nodes":[{"id":"a","title":"Worker","loopType":"goalBased","state":"succeeded","presence":{"presence":"idle","confidence":"reported"}}],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(first);
    try std.testing.expectEqual(@as(usize, 0), model.activity.items.len);
    _ = try model.updateFromFrame(second);
    try std.testing.expectEqual(@as(usize, 1), model.activity.items.len);
    try std.testing.expectEqualStrings("Worker", model.activity.items[0].title);
}

test "presence polling does not evict or create activity history" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const first =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"g","project":{"path":"C:\\work\\graph","name":"Graph","remote":false},"nodes":[{"id":"a","title":"Worker","loopType":"goalBased","state":"running","presence":{"presence":"busy","confidence":"reported"}}],"edges":[]}}}
    ;
    const second =
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"id":"g","project":{"path":"C:\\work\\graph","name":"Graph","remote":false},"nodes":[{"id":"a","title":"Worker","loopType":"goalBased","state":"running","presence":{"presence":"awaitingInput","confidence":"reported"}}],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(first);
    _ = try model.updateFromFrame(second);
    try std.testing.expectEqual(@as(usize, 0), model.activity.items.len);
}

test "blocked attention requires every blocking upstream to be resolved" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const frame =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"g","project":{"path":"C:\\work\\graph","name":"Graph","remote":false},"nodes":[{"id":"up","title":"Upstream","loopType":"goalBased","state":"failed"},{"id":"blocked","title":"Stranded","loopType":"goalBased","state":"blocked"},{"id":"live","title":"Live","loopType":"goalBased","state":"running"},{"id":"waiting","title":"Still waiting","loopType":"goalBased","state":"blocked"}],"edges":[{"from":"up","to":"blocked","kind":"handoff","fired":false},{"from":"live","to":"waiting","kind":"handoff","fired":false}]}}}
    ;
    _ = try model.updateFromFrame(frame);
    try std.testing.expectEqual(@as(usize, 2), model.attentionCount());
    try std.testing.expectEqualStrings("Upstream", model.attention.items[0].title);
    try std.testing.expectEqualStrings("Stranded", model.attention.items[1].title);
}

test "attention fixture keeps real daemon state and worktree context visible" {
    const frame = try std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "fixtures/daemon-v2-attention-worktree.json",
        64 * 1024,
    );
    defer std.testing.allocator.free(frame);
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(frame);
    try std.testing.expectEqualStrings("Attention fixture", model.graph.?.project.name);
    try std.testing.expectEqual(@as(usize, 2), model.attentionCount());
    try std.testing.expectEqualStrings("Failed check", model.attention.items[0].title);
    try std.testing.expectEqualStrings("C:\\work\\graph-review", model.graph.?.nodes.items[0].worktree_path);
    try std.testing.expectEqualStrings("review", model.graph.?.nodes.items[0].worktree_branch);
}

test "real edge payload uses fireCount and only handoff blocks" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const frame =
        \\{"version":2,"kind":"event","sequence":3,"event":{"graphChanged":{"id":"g","project":{"path":"C:\\work\\graph","name":"Graph"},"nodes":[{"id":"a","title":"A","state":"succeeded"},{"id":"b","title":"B","state":"blocked"},{"id":"c","title":"C","state":"blocked"}],"edges":[{"from":"a","to":"b","kind":"handoff","fireCount":0},{"from":"a","to":"c","kind":"message","fireCount":0}]}}}
    ;
    _ = try model.updateFromFrame(frame);
    try std.testing.expectEqual(@as(usize, 1), model.attentionCount());
    try std.testing.expectEqualStrings("B", model.attention.items[0].title);
}

test "fireCount parses complete positive numeric tokens" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const frame =
        \\{"version":2,"kind":"event","sequence":4,"event":{"graphChanged":{"id":"g","project":{"path":"C:\\work\\graph","name":"Graph"},"nodes":[{"id":"a","title":"A","state":"running"},{"id":"b","title":"B","state":"blocked"}],"edges":[{"from":"a","to":"b","kind":"handoff","fireCount":1},{"from":"a","to":"b","kind":"handoff","fireCount":123}]}}}
    ;
    _ = try model.updateFromFrame(frame);
    try std.testing.expectEqual(@as(u32, 1), model.graph.?.edges.items[0].fire_count);
    try std.testing.expectEqual(@as(u32, 123), model.graph.?.edges.items[1].fire_count);
    try std.testing.expectEqual(@as(usize, 0), model.attentionCount());
}

test "metric history samples retain recent values for sparklines" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const frame =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"g","project":{"path":"C:\\work\\graph","name":"Graph"},"nodes":[{"id":"a","title":"A","state":"running","metricHistory":[{"value":5},{"value":4},{"value":3},{"value":2},{"value":1},{"value":0},{"value":-1},{"value":-2},{"value":-3}]}],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(frame);
    const node = model.graph.?.nodes.items[0];
    try std.testing.expectEqual(@as(u32, 9), node.metric_passes);
    try std.testing.expectEqual(@as(u8, 8), node.metric_sample_count);
    try std.testing.expectEqual(@as(f64, 4), node.metric_samples[0]);
    try std.testing.expectEqual(@as(f64, -3), node.metric_samples[7]);
}

test "attention cursor is independent from ordinary selection" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const frame =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"g","project":{"path":"C:\\work\\graph","name":"Graph"},"nodes":[{"id":"a","title":"A","state":"failed"},{"id":"b","title":"B","state":"failed"}],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(frame);
    try std.testing.expect(model.setSelectedIndex(1));
    model.selectNextAttention();
    try std.testing.expectEqual(@as(usize, 0), model.selectedIndex().?);
    model.selectNextAttention();
    try std.testing.expectEqual(@as(usize, 1), model.selectedIndex().?);
}

test "stable selection lookup survives reordered graph collections" {
    const nodes = [_]Node{
        .{ .id = @constCast("node-b"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
        .{ .id = @constCast("node-a"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
    };
    const edges = [_]Edge{
        .{ .id = @constCast("edge-a"), .from = @constCast("node-a"), .to = @constCast("node-b") },
        .{ .id = @constCast("edge-b"), .from = @constCast("node-b"), .to = @constCast("node-a") },
    };
    try std.testing.expectEqual(@as(?usize, 1), findNodeIndexByID(&nodes, "node-a"));
    try std.testing.expectEqual(@as(?usize, 1), findEdgeIndexByID(&edges, "edge-b"));
    try std.testing.expect(findEdgeIndexByID(&edges, "missing") == null);
}

test "stable selection survives a daemon graph refresh during a modal edit" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const first =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"C:\\work\\graph","name":"Graph"},"nodes":[{"id":"node-a","title":"A","state":"running"}],"edges":[{"id":"edge-a","from":"node-a","to":"node-b","kind":"handoff"}]}}}
    ;
    const second =
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"project":{"path":"C:\\work\\graph","name":"Graph"},"nodes":[{"id":"node-b","title":"B","state":"idle"},{"id":"node-a","title":"A","state":"running"}],"edges":[{"id":"edge-a","from":"node-a","to":"node-b","kind":"handoff"}]}}}
    ;
    _ = try model.updateFromFrame(first);
    _ = try model.updateFromFrame(second);
    try std.testing.expectEqual(@as(?usize, 1), model.findNodeIndex("node-a"));
    try std.testing.expectEqual(@as(?usize, 0), model.findEdgeIndex("edge-a"));
}

test "edge lookup is scoped to the selected project" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const first =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"A","name":"A"},"nodes":[{"id":"a","title":"A","state":"running"}],"edges":[{"id":"shared","from":"a","to":"a","kind":"handoff"}]}}}
    ;
    const second =
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"project":{"path":"B","name":"B"},"nodes":[{"id":"b","title":"B","state":"running"}],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(first);
    _ = try model.updateFromFrame(second);
    try std.testing.expect(model.selectProject("B"));
    try std.testing.expect(model.findEdgeIndex("shared") == null);
    try std.testing.expect(model.selectProject("A"));
    try std.testing.expectEqual(@as(?usize, 0), model.findEdgeIndex("shared"));
}

test "composite subgraph payload preserves top-level child count" {
    const payload =
        \\{"nodes":[{"id":"a","title":"A","goal":{"summary":"nested"}},{"id":"b","title":"B"}],"edges":[{"from":"a","to":"b"}]}
    ;
    try std.testing.expectEqual(@as(usize, 2), subgraphNodeCount(payload));
    try std.testing.expectEqual(@as(usize, 0), subgraphNodeCount("{}"));
}

test "real subGraph decoding preserves children without inheriting child scalar fields" {
    var nodes = std.array_list.Managed(Node).init(std.testing.allocator);
    defer {
        for (nodes.items) |node| freeNode(std.testing.allocator, node);
        nodes.deinit();
    }
    const payload =
        \\[{"id":"parent","title":"Parent","loopType":"proactive","subGraph":{"nodes":[{"id":"child","title":"Child","worktreeBinding":{"path":"C:\\child","branch":"nested"}}],"edges":[]},"state":"idle"}]
    ;
    try decodeNodes(std.testing.allocator, payload, &nodes);
    try std.testing.expectEqual(@as(usize, 1), nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), subgraphNodeCount(nodes.items[0].subgraph_json));
    try std.testing.expectEqualStrings("", nodes.items[0].worktree_path);
    try std.testing.expectEqualStrings("idle", nodes.items[0].state);
}

test "composite navigation swaps to nested graph and survives refresh" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const first =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"C:\\work\\graph","name":"Graph"},"nodes":[{"id":"parent","title":"Group","loopType":"composite","pilotState":"piloted","state":"idle","subGraph":{"nodes":[{"id":"child-a","title":"Child A","state":"idle"},{"id":"child-b","title":"Child B","state":"running"}],"edges":[{"id":"nested-edge","from":"child-a","to":"child-b","kind":"handoff"}]}}],"edges":[]}}}
    ;
    const second =
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"project":{"path":"C:\\work\\graph","name":"Graph"},"nodes":[{"id":"parent","title":"Group","loopType":"composite","state":"idle","subGraph":{"nodes":[{"id":"child-b","title":"Child B updated","state":"succeeded"},{"id":"child-a","title":"Child A","state":"idle"}],"edges":[]}}],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(first);
    try std.testing.expectEqualStrings("piloted", model.graph.?.nodes.items[0].pilot_state);
    try std.testing.expect(model.openComposite("parent"));
    try std.testing.expect(model.isCompositeOpen());
    try std.testing.expectEqualStrings("Group", model.open_composite_title.?);
    try std.testing.expectEqual(@as(usize, 2), model.graph.?.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), model.graph.?.edges.items.len);
    try std.testing.expect(model.setSelectedID("child-b"));

    _ = try model.updateFromFrame(second);
    try std.testing.expect(model.isCompositeOpen());
    try std.testing.expectEqualStrings("Child B updated", model.selected().?.title);
    try std.testing.expectEqual(@as(usize, 0), model.graph.?.edges.items.len);

    model.closeComposite();
    try std.testing.expect(!model.isCompositeOpen());
    try std.testing.expectEqual(@as(usize, 1), model.graph.?.nodes.items.len);
    try std.testing.expectEqualStrings("parent", model.selected().?.id);
}
