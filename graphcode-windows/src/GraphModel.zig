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
    first_instruction: []u8 = &.{},
    check_description: []u8 = &.{},
    model_tier: []u8 = &.{},
    poll_interval_seconds: ?f64 = null,
    stall_after_seconds: ?f64 = null,
    /// Whole Unix seconds; see `unixSecondsFromReferenceDate`.
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

pub const CycleGuard = struct {
    max_iterations: ?i64 = null,
    until: ?[]u8 = null,
    stop_after_passes_without_improvement: ?i64 = null,
};

pub const PayloadTransform = union(enum) {
    none,
    template: []const u8,
    script: []const u8,
};

pub const Edge = struct {
    id: []u8 = &.{},
    from: []u8,
    to: []u8,
    kind: []u8 = &.{},
    condition: []u8 = @constCast("always"),
    blocks_target: bool = true,
    fired: bool = false,
    fire_count: i64 = 0,
    cycle_guard: ?CycleGuard = null,
    payload_transform: PayloadTransform = .none,
    spawn_target_project_path: ?[]const u8 = null,
    editable_configuration: bool = true,
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

const AttentionLists = struct {
    nodes: std.array_list.Managed(Node),
    entries: std.array_list.Managed(AttentionEntry),

    fn deinit(self: *AttentionLists, allocator: std.mem.Allocator) void {
        for (self.nodes.items) |node| freeNode(allocator, node);
        for (self.entries.items) |entry| freeAttentionEntry(allocator, entry);
        self.nodes.deinit();
        self.entries.deinit();
    }
};

const LegacySnapshot = struct {
    graph: ?Graph = null,
    selected_index: ?usize,
    selected_node_id: ?[]u8 = null,
    composite_title: ?[]u8 = null,
    clear_composite: bool = false,

    fn deinit(self: *LegacySnapshot, allocator: std.mem.Allocator) void {
        if (self.graph) |*graph| freeGraph(allocator, graph);
        if (self.selected_node_id) |id| allocator.free(id);
        if (self.composite_title) |title| allocator.free(title);
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
        for (self.activity.items) |event| freeActivityEvent(self.allocator, event);
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
        self.applyWorktreeBindingChange(worktreeBindingsChanged(self.allocator, project, previous, next));
    }

    fn applyWorktreeBindingChange(self: *Model, change: anyerror!bool) void {
        const changed = change catch |err| {
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
        const replacement_path = self.allocator.dupe(u8, summary.project.path) catch return false;
        const replacement_node: ?[]u8 = if (summary.nodes.items.len == 0) null else self.allocator.dupe(u8, summary.nodes.items[0].id) catch {
            self.allocator.free(replacement_path);
            return false;
        };
        self.clearOpenComposite();
        if (self.selected_project_path) |path| self.allocator.free(path);
        self.selected_project_path = replacement_path;
        self.selected_index = if (summary.nodes.items.len == 0) null else 0;
        self.freeSelectedNodeID();
        self.selected_node_id = replacement_node;
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
        var graph = decodeGraphFrame(self.allocator, frame) catch |err| switch (err) {
            error.MalformedJson => return error.MalformedGraph,
            else => return err,
        } orelse return;
        defer freeGraph(self.allocator, &graph);
        const was_selected = if (self.selected_project_path) |path|
            std.mem.eql(u8, path, graph.project.path)
        else
            self.graph == null;
        const prior_node_id: ?[]const u8 = if (was_selected) self.selected_node_id else null;
        const selected_path = if (self.selected_project_path == null)
            try self.allocator.dupe(u8, graph.project.path)
        else
            null;
        errdefer if (selected_path) |path| self.allocator.free(path);
        const already_open = for (self.open_projects.items) |project| {
            if (std.mem.eql(u8, project.path, graph.project.path)) break true;
        } else false;
        const open_project = if (!already_open) try cloneProject(self.allocator, graph.project) else null;
        errdefer if (open_project) |project| freeProject(self.allocator, project);
        if (open_project != null) try self.open_projects.ensureUnusedCapacity(1);
        const seen = try self.prepareGraphSeen(graph.project.path);
        errdefer if (seen) |entry| self.allocator.free(entry.project_path);
        var activity = try self.prepareActivity(graph);
        defer {
            for (activity.items) |event| freeActivityEvent(self.allocator, event);
            activity.deinit();
        }
        try self.activity.ensureUnusedCapacity(activity.items.len);
        var attention = try self.prepareAttention(&graph);
        defer attention.deinit(self.allocator);
        var selected_index = self.selected_index;
        var selected_node_id: ?[]const u8 = self.selected_node_id;
        if (was_selected and graph.nodes.items.len == 0) {
            selected_index = null;
            selected_node_id = null;
        } else if (was_selected) {
            selected_index = 0;
            if (prior_node_id) |node_id| {
                for (graph.nodes.items, 0..) |node, index| {
                    if (std.mem.eql(u8, node.id, node_id)) {
                        selected_index = index;
                        selected_node_id = node.id;
                        break;
                    }
                }
            } else if (graph.nodes.items.len != 0) {
                selected_node_id = graph.nodes.items[0].id;
            }
        }
        const incoming_summary = GraphSummary{
            .project = if (self.graphFor(graph.project.path)) |prior| prior.project else graph.project,
            .nodes = graph.nodes,
            .edges = graph.edges,
        };
        const effective_path = self.selected_project_path orelse selected_path.?;
        const selected_summary = if (std.mem.eql(u8, effective_path, graph.project.path))
            &incoming_summary
        else
            self.graphFor(effective_path);
        var legacy = try self.prepareLegacySnapshot(selected_summary, selected_index, selected_node_id);
        defer legacy.deinit(self.allocator);

        // The summary replacement is the last fallible step; all other owned
        // values and append capacity are ready before any model data is replaced.
        try self.upsertSummary(&graph);
        if (open_project) |project| self.open_projects.appendAssumeCapacity(project);
        if (selected_path) |path| self.selected_project_path = path;
        self.markGraphSeen(graph.project.path, seen);
        self.installActivity(&activity);
        self.installAttention(&attention);
        self.installLegacySnapshot(&legacy);
    }

    fn syncLegacyGraph(self: *Model) void {
        const summary = if (self.selected_project_path) |path| self.graphFor(path) else null;
        var snapshot = self.prepareLegacySnapshot(summary, self.selected_index, self.selected_node_id) catch {
            if (self.graph) |*old| freeGraph(self.allocator, old);
            self.graph = null;
            return;
        };
        defer snapshot.deinit(self.allocator);
        self.installLegacySnapshot(&snapshot);
    }

    fn prepareLegacySnapshot(
        self: *Model,
        summary: ?*const GraphSummary,
        selected_index: ?usize,
        selected_node_id: ?[]const u8,
    ) !LegacySnapshot {
        var snapshot = LegacySnapshot{ .selected_index = selected_index };
        errdefer snapshot.deinit(self.allocator);
        if (selected_node_id) |id| snapshot.selected_node_id = try self.allocator.dupe(u8, id);
        const selected_summary = summary orelse return snapshot;
        snapshot.graph = try cloneGraph(self.allocator, selected_summary.*);
        const node_id = self.open_composite_id orelse return snapshot;
        const top = snapshot.graph.?;
        const index = findNodeIndexByID(top.nodes.items, node_id) orelse {
            snapshot.clear_composite = true;
            return snapshot;
        };
        const node = top.nodes.items[index];
        snapshot.composite_title = try self.allocator.dupe(u8, node.title);
        const nested = decodeSubgraph(self.allocator, top.project, node.subgraph_json) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                // Malformed nested data retains the top-level fallback, including
                // errors from the typed edge parser; allocation failures do not.
                self.allocator.free(snapshot.composite_title.?);
                snapshot.composite_title = null;
                snapshot.clear_composite = true;
                return snapshot;
            },
        };
        freeGraph(self.allocator, &snapshot.graph.?);
        snapshot.graph = nested;
        if (nested.nodes.items.len == 0) {
            snapshot.selected_index = null;
            if (snapshot.selected_node_id) |id| self.allocator.free(id);
            snapshot.selected_node_id = null;
        } else {
            const retained = if (snapshot.selected_node_id) |id|
                findNodeIndexByID(nested.nodes.items, id)
            else
                null;
            snapshot.selected_index = retained orelse 0;
            const id = try self.allocator.dupe(u8, nested.nodes.items[snapshot.selected_index.?].id);
            if (snapshot.selected_node_id) |old| self.allocator.free(old);
            snapshot.selected_node_id = id;
        }
        return snapshot;
    }

    fn installLegacySnapshot(self: *Model, snapshot: *LegacySnapshot) void {
        if (self.graph) |*old| freeGraph(self.allocator, old);
        self.graph = snapshot.graph;
        snapshot.graph = null;
        self.selected_index = snapshot.selected_index;
        self.freeSelectedNodeID();
        self.selected_node_id = snapshot.selected_node_id;
        snapshot.selected_node_id = null;
        if (snapshot.clear_composite) self.clearOpenComposite();
        if (snapshot.composite_title) |title| {
            if (self.open_composite_title) |old| self.allocator.free(old);
            self.open_composite_title = title;
            snapshot.composite_title = null;
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
        var copy = try cloneGraph(self.allocator, .{ .project = graph.project, .nodes = graph.nodes, .edges = graph.edges });
        defer freeGraph(self.allocator, &copy);
        const previous = if (self.graphFor(graph.project.path)) |summary| summary.nodes.items else &.{};
        const binding_change = worktreeBindingsChanged(self.allocator, graph.project, previous, graph.nodes.items);
        if (binding_change) |_| {} else |err| {
            if (err == error.OutOfMemory) return err;
        }
        for (self.graphs.items) |*summary| {
            if (!std.mem.eql(u8, summary.project.path, graph.project.path)) continue;
            self.applyWorktreeBindingChange(binding_change);
            std.mem.swap(std.array_list.Managed(Node), &summary.nodes, &copy.nodes);
            std.mem.swap(std.array_list.Managed(Edge), &summary.edges, &copy.edges);
            return;
        }
        try self.graphs.ensureUnusedCapacity(1);
        self.applyWorktreeBindingChange(binding_change);
        self.graphs.appendAssumeCapacity(.{ .project = copy.project, .nodes = copy.nodes, .edges = copy.edges });
        copy.project = .{ .path = &.{}, .name = &.{} };
        copy.nodes = std.array_list.Managed(Node).init(self.allocator);
        copy.edges = std.array_list.Managed(Edge).init(self.allocator);
    }

    fn prepareGraphSeen(self: *Model, path: []const u8) !?GraphGeneration {
        for (self.graph_generations.items) |entry| {
            if (std.mem.eql(u8, entry.project_path, path)) return null;
        }
        const project_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(project_path);
        try self.graph_generations.ensureUnusedCapacity(1);
        return .{ .project_path = project_path, .generation = self.restore_generation };
    }

    fn markGraphSeen(self: *Model, path: []const u8, prepared: ?GraphGeneration) void {
        if (prepared) |entry| {
            self.graph_generations.appendAssumeCapacity(entry);
            return;
        }
        for (self.graph_generations.items) |*entry| {
            if (std.mem.eql(u8, entry.project_path, path)) {
                entry.generation = self.restore_generation;
                return;
            }
        }
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
        var attention = self.prepareAttention(null) catch {
            for (self.attention.items) |node| freeNode(self.allocator, node);
            self.attention.clearRetainingCapacity();
            for (self.attention_entries.items) |entry| freeAttentionEntry(self.allocator, entry);
            self.attention_entries.clearRetainingCapacity();
            return;
        };
        defer attention.deinit(self.allocator);
        self.installAttention(&attention);
    }

    fn prepareAttention(self: *Model, replacement: ?*const Graph) !AttentionLists {
        var attention = AttentionLists{
            .nodes = std.array_list.Managed(Node).init(self.allocator),
            .entries = std.array_list.Managed(AttentionEntry).init(self.allocator),
        };
        errdefer attention.deinit(self.allocator);
        var replaced = false;
        for (self.graphs.items) |summary| {
            if (replacement) |graph| {
                if (std.mem.eql(u8, summary.project.path, graph.project.path)) {
                    try appendAttention(self.allocator, &attention, .{
                        .project = summary.project,
                        .nodes = graph.nodes,
                        .edges = graph.edges,
                    });
                    replaced = true;
                    continue;
                }
            }
            try appendAttention(self.allocator, &attention, summary);
        }
        if (!replaced) {
            if (replacement) |graph| try appendAttention(self.allocator, &attention, .{
                .project = graph.project,
                .nodes = graph.nodes,
                .edges = graph.edges,
            });
        }
        std.sort.heap(AttentionEntry, attention.entries.items, {}, compareAttentionEntry);
        std.sort.heap(Node, attention.nodes.items, {}, compareAttentionNode);
        return attention;
    }

    fn installAttention(self: *Model, attention: *AttentionLists) void {
        std.mem.swap(std.array_list.Managed(Node), &self.attention, &attention.nodes);
        std.mem.swap(std.array_list.Managed(AttentionEntry), &self.attention_entries, &attention.entries);
    }

    fn prepareActivity(self: *Model, next: Graph) !std.array_list.Managed(ActivityEvent) {
        var activity = std.array_list.Managed(ActivityEvent).init(self.allocator);
        errdefer {
            for (activity.items) |event| freeActivityEvent(self.allocator, event);
            activity.deinit();
        }
        const previous = self.graphFor(next.project.path) orelse return activity;
        for (next.nodes.items) |node| {
            const old = findNode(previous.nodes.items, node.id) orelse continue;
            if (std.mem.eql(u8, old.state, node.state)) continue;
            var event = ActivityEvent{ .title = &.{}, .state = &.{}, .timestamp = std.time.timestamp() };
            errdefer freeActivityEvent(self.allocator, event);
            event.title = try self.allocator.dupe(u8, node.title);
            event.state = try self.allocator.dupe(u8, node.state);
            event.project_path = try self.allocator.dupe(u8, next.project.path);
            event.node_id = try self.allocator.dupe(u8, node.id);
            try activity.append(event);
        }
        return activity;
    }

    fn installActivity(self: *Model, activity: *std.array_list.Managed(ActivityEvent)) void {
        for (activity.items) |event| {
            self.activity.insertAssumeCapacity(0, event);
            if (self.activity.items.len > 32) {
                const removed = self.activity.pop() orelse continue;
                freeActivityEvent(self.allocator, removed);
            }
        }
        activity.clearRetainingCapacity();
    }
};

fn appendAttention(allocator: std.mem.Allocator, attention: *AttentionLists, summary: GraphSummary) !void {
    for (summary.nodes.items) |node| {
        if (!needsAttention(node) and !(std.mem.eql(u8, node.state, "blocked") and isStrandedSummary(&summary, node.id))) continue;
        {
            const node_copy = try cloneNode(allocator, node);
            errdefer freeNode(allocator, node_copy);
            const path = try allocator.dupe(u8, summary.project.path);
            errdefer allocator.free(path);
            try attention.entries.append(.{ .project_path = path, .node = node_copy });
        }
        const compat = try cloneNode(allocator, node);
        errdefer freeNode(allocator, compat);
        try attention.nodes.append(compat);
    }
}

fn freeActivityEvent(allocator: std.mem.Allocator, event: ActivityEvent) void {
    allocator.free(event.title);
    allocator.free(event.state);
    allocator.free(event.project_path);
    allocator.free(event.node_id);
}

fn cloneGraph(allocator: std.mem.Allocator, source: GraphSummary) !Graph {
    var graph = Graph{
        .project = try cloneProject(allocator, source.project),
        .nodes = std.array_list.Managed(Node).init(allocator),
        .edges = std.array_list.Managed(Edge).init(allocator),
    };
    errdefer freeGraph(allocator, &graph);
    for (source.nodes.items) |node| {
        const copy = try cloneNode(allocator, node);
        errdefer freeNode(allocator, copy);
        try graph.nodes.append(copy);
    }
    graph.edges = try cloneEdges(allocator, source.edges.items);
    return graph;
}

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
    var copy = Node{
        .id = &.{},
        .title = &.{},
        .loop_type = &.{},
        .state = &.{},
        .activity = &.{},
        .presence = &.{},
        .poll_interval_seconds = node.poll_interval_seconds,
        .stall_after_seconds = node.stall_after_seconds,
        .created_at = node.created_at,
        .metric_passes = node.metric_passes,
        .metric_samples = node.metric_samples,
        .metric_sample_count = node.metric_sample_count,
        .token_usage = node.token_usage,
        .follows_template = node.follows_template,
    };
    errdefer freeNode(allocator, copy);
    copy.id = try allocator.dupe(u8, node.id);
    copy.title = try allocator.dupe(u8, node.title);
    copy.loop_type = try allocator.dupe(u8, node.loop_type);
    copy.state = try allocator.dupe(u8, node.state);
    copy.activity = try allocator.dupe(u8, node.activity);
    copy.presence = try allocator.dupe(u8, node.presence);
    copy.backend = try allocator.dupe(u8, node.backend);
    copy.pilot_state = try allocator.dupe(u8, node.pilot_state);
    copy.goal_summary = try allocator.dupe(u8, node.goal_summary);
    copy.goal_predicate = try allocator.dupe(u8, node.goal_predicate);
    copy.metric_command = try allocator.dupe(u8, node.metric_command);
    copy.metric_direction = try allocator.dupe(u8, node.metric_direction);
    copy.trigger_prompt = try allocator.dupe(u8, node.trigger_prompt);
    copy.first_instruction = try allocator.dupe(u8, node.first_instruction);
    copy.check_description = try allocator.dupe(u8, node.check_description);
    copy.model_tier = try allocator.dupe(u8, node.model_tier);
    copy.worktree_path = try allocator.dupe(u8, node.worktree_path);
    copy.worktree_branch = try allocator.dupe(u8, node.worktree_branch);
    copy.subgraph_json = try allocator.dupe(u8, node.subgraph_json);
    return copy;
}

pub fn cloneEdge(allocator: std.mem.Allocator, edge: Edge) !Edge {
    var copy = Edge{
        .from = &.{},
        .to = &.{},
        .condition = &.{},
        .blocks_target = edge.blocks_target,
        .fired = edge.fired,
        .fire_count = edge.fire_count,
        .editable_configuration = edge.editable_configuration,
    };
    errdefer freeEdge(allocator, copy);
    copy.id = try allocator.dupe(u8, edge.id);
    copy.from = try allocator.dupe(u8, edge.from);
    copy.to = try allocator.dupe(u8, edge.to);
    copy.kind = try allocator.dupe(u8, edge.kind);
    copy.condition = try allocator.dupe(u8, edge.condition);
    copy.payload_transform = switch (edge.payload_transform) {
        .none => .none,
        .template => |text| .{ .template = try allocator.dupe(u8, text) },
        .script => |text| .{ .script = try allocator.dupe(u8, text) },
    };
    if (edge.spawn_target_project_path) |path| copy.spawn_target_project_path = try allocator.dupe(u8, path);
    if (edge.cycle_guard) |guard| {
        copy.cycle_guard = .{
            .max_iterations = guard.max_iterations,
            .stop_after_passes_without_improvement = guard.stop_after_passes_without_improvement,
            .until = if (guard.until) |until| try allocator.dupe(u8, until) else null,
        };
    }
    return copy;
}

fn cloneEdges(allocator: std.mem.Allocator, edges: []const Edge) !std.array_list.Managed(Edge) {
    var copies = std.array_list.Managed(Edge).init(allocator);
    errdefer freeEdges(allocator, &copies);
    for (edges) |edge| {
        const copy = try cloneEdge(allocator, edge);
        errdefer freeEdge(allocator, copy);
        try copies.append(copy);
    }
    return copies;
}

fn freeEdges(allocator: std.mem.Allocator, edges: *std.array_list.Managed(Edge)) void {
    for (edges.items) |edge| freeEdge(allocator, edge);
    edges.deinit();
}

pub fn freeEdge(allocator: std.mem.Allocator, edge: Edge) void {
    allocator.free(edge.id);
    allocator.free(edge.from);
    allocator.free(edge.to);
    allocator.free(edge.kind);
    allocator.free(edge.condition);
    switch (edge.payload_transform) {
        .none => {},
        .template, .script => |text| allocator.free(text),
    }
    if (edge.spawn_target_project_path) |path| allocator.free(path);
    if (edge.cycle_guard) |guard| {
        if (guard.until) |until| allocator.free(until);
    }
}

fn freeAttentionEntry(allocator: std.mem.Allocator, entry: AttentionEntry) void {
    allocator.free(entry.project_path);
    freeNode(allocator, entry.node);
}

// Values borrow the input; only the field index and decoded keys are temporary
// allocations. String payloads (notably stored subGraph children) are decoded
// only when consumed, preserving the malformed-open-subgraph fallback.
const JsonValue = struct {
    raw: []const u8 = "null",

    fn container(self: JsonValue, open: u8) ?[]const u8 {
        return if (self.raw.len != 0 and self.raw[0] == open) self.raw else null;
    }

    fn isNull(self: JsonValue) bool {
        return std.mem.eql(u8, self.raw, "null");
    }

    fn duplicateString(self: JsonValue, allocator: std.mem.Allocator, fallback: []const u8) ![]u8 {
        return Wire.decodeJsonString(allocator, if (self.raw.len >= 2 and self.raw[0] == '"')
            self.raw[1 .. self.raw.len - 1]
        else
            fallback);
    }

    fn unsigned(self: JsonValue, comptime T: type) ?T {
        var end: usize = 0;
        while (end < self.raw.len and std.ascii.isDigit(self.raw[end])) : (end += 1) {}
        return std.fmt.parseInt(T, self.raw[0..end], 10) catch null;
    }

    fn float(self: JsonValue) ?f64 {
        return std.fmt.parseFloat(f64, self.raw) catch null;
    }

    fn boolean(self: JsonValue) ?bool {
        if (std.mem.eql(u8, self.raw, "true")) return true;
        if (std.mem.eql(u8, self.raw, "false")) return false;
        return null;
    }
};

fn validateJsonScalar(raw: []const u8, string: bool) !void {
    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), raw);
    defer scanner.deinit();
    scanner.skipValue() catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return if (string) error.MalformedJsonString else error.MalformedJson,
    };
    const last = scanner.next() catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return if (string) error.MalformedJsonString else error.MalformedJson,
    };
    if (last != .end_of_document) return error.MalformedJson;
}

fn jsonStringEquals(raw: []const u8, expected: []const u8) bool {
    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), raw);
    defer scanner.deinit();
    var offset: usize = 0;
    while (true) {
        const token = scanner.next() catch |err| switch (err) {
            error.OutOfMemory => unreachable, // Scalar string lexing never grows the nesting stack.
            else => return false,
        };
        switch (token) {
            .string, .partial_string => |chunk| {
                if (!matchJsonChunk(expected, &offset, chunk)) return false;
                if (token == .string) return offset == expected.len;
            },
            inline .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => |chunk| {
                if (!matchJsonChunk(expected, &offset, &chunk)) return false;
            },
            else => return false,
        }
    }
}

fn matchJsonChunk(expected: []const u8, offset: *usize, chunk: []const u8) bool {
    if (chunk.len > expected.len - offset.* or !std.mem.eql(u8, expected[offset.* .. offset.* + chunk.len], chunk)) return false;
    offset.* += chunk.len;
    return true;
}

const JsonTraversalWork = struct {
    // Counts span/string scan byte visits and validator loop iterations; this
    // is not an instruction count for standard-library lexing or allocation.
    span_byte_visits: usize = 0,
    validator_steps: usize = 0,

    fn visit(work: ?*JsonTraversalWork, count: usize) void {
        if (@import("builtin").is_test) {
            if (work) |measured| measured.span_byte_visits += count;
        }
    }
};

const JsonCursor = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    work: ?*JsonTraversalWork = null,

    fn trim(self: *JsonCursor) void {
        self.bytes = std.mem.trimLeft(u8, self.bytes, " \t\r\n");
    }

    fn take(self: *JsonCursor, byte: u8) !void {
        self.trim();
        if (self.bytes.len == 0 or self.bytes[0] != byte) return error.MalformedJson;
        self.bytes = self.bytes[1..];
    }

    fn stringEnd(bytes: []const u8) !usize {
        return stringEndMeasured(bytes, null);
    }

    fn stringEndMeasured(bytes: []const u8, work: ?*JsonTraversalWork) !usize {
        var index: usize = 1;
        while (index < bytes.len) : (index += 1) {
            JsonTraversalWork.visit(work, 1);
            if (bytes[index] == '"') return index + 1;
            if (bytes[index] == '\\') {
                JsonTraversalWork.visit(work, 1);
                index += 1;
            }
        }
        return error.MalformedJsonString;
    }

    fn value(self: *JsonCursor) !JsonValue {
        self.trim();
        if (self.bytes.len == 0) return error.MalformedJson;
        const bytes = self.bytes;
        const end = switch (bytes[0]) {
            '"' => try stringEndMeasured(bytes, self.work),
            '{', '[' => blk: {
                var stack = std.array_list.Managed(u8).init(self.allocator);
                defer stack.deinit();
                var index: usize = 0;
                while (index < bytes.len) {
                    JsonTraversalWork.visit(self.work, 1);
                    switch (bytes[index]) {
                        '"' => {
                            index += try stringEndMeasured(bytes[index..], self.work);
                            continue;
                        },
                        '{' => try stack.append('}'),
                        '[' => try stack.append(']'),
                        '}', ']' => {
                            if (stack.items.len == 0 or stack.pop().? != bytes[index]) return error.MalformedJson;
                            if (stack.items.len == 0) break :blk index + 1;
                        },
                        else => {},
                    }
                    index += 1;
                }
                return error.MalformedJson;
            },
            else => blk: {
                const end = std.mem.indexOfAny(u8, bytes, " \t\r\n,]}") orelse bytes.len;
                JsonTraversalWork.visit(self.work, end + @intFromBool(end < bytes.len));
                if (end == 0) return error.MalformedJson;
                try validateJsonScalar(bytes[0..end], false);
                break :blk end;
            },
        };
        self.bytes = bytes[end..];
        return .{ .raw = bytes[0..end] };
    }
};

const JsonItems = struct {
    cursor: JsonCursor,
    open: u8,
    first: bool = true,
    done: bool = false,
    key: JsonValue = .{},

    fn init(allocator: std.mem.Allocator, bytes: []const u8, open: u8) !JsonItems {
        return initMeasured(allocator, bytes, open, null);
    }

    fn initMeasured(allocator: std.mem.Allocator, bytes: []const u8, open: u8, work: ?*JsonTraversalWork) !JsonItems {
        var result = JsonItems{ .cursor = .{ .allocator = allocator, .bytes = bytes, .work = work }, .open = open };
        try result.cursor.take(open);
        return result;
    }

    fn next(self: *JsonItems) !?JsonValue {
        if (!try self.nextHead()) {
            if (self.cursor.bytes.len != 0) return error.MalformedJson;
            return null;
        }
        return try self.cursor.value();
    }

    fn nextHead(self: *JsonItems) !bool {
        if (self.done) return false;
        self.cursor.trim();
        const close: u8 = if (self.open == '{') '}' else ']';
        if (self.cursor.bytes.len == 0) return error.MalformedJson;
        if (self.cursor.bytes[0] == close) {
            try self.cursor.take(close);
            self.cursor.trim();
            self.done = true;
            return false;
        }
        if (!self.first) try self.cursor.take(',');
        self.first = false;
        if (self.open == '{') {
            self.cursor.trim();
            if (self.cursor.bytes.len == 0 or self.cursor.bytes[0] != '"') return error.MalformedJson;
            self.key = try self.cursor.value();
            try validateJsonScalar(self.key.raw, true);
            try self.cursor.take(':');
        }
        return true;
    }
};

const JsonFields = struct {
    const Field = struct { key: []u8, value: JsonValue };
    fields: std.array_list.Managed(Field),

    fn init(allocator: std.mem.Allocator, bytes: []const u8) !JsonFields {
        var result = JsonFields{ .fields = std.array_list.Managed(Field).init(allocator) };
        errdefer result.deinit();
        var items = try JsonItems.init(allocator, bytes, '{');
        while (try items.next()) |value| {
            const key = try items.key.duplicateString(allocator, "");
            errdefer allocator.free(key);
            try result.fields.append(.{ .key = key, .value = value });
        }
        return result;
    }

    fn deinit(self: *JsonFields) void {
        for (self.fields.items) |field| self.fields.allocator.free(field.key);
        self.fields.deinit();
    }

    fn has(self: *const JsonFields, key: []const u8) bool {
        for (self.fields.items) |field| {
            if (std.mem.eql(u8, field.key, key)) return true;
        }
        return false;
    }

    fn get(self: *const JsonFields, key: []const u8) JsonValue {
        for (self.fields.items) |field| {
            if (std.mem.eql(u8, field.key, key)) return field.value;
        }
        return .{};
    }
};

fn validateGraphStructure(allocator: std.mem.Allocator, bytes: []const u8) !void {
    return validateGraphStructureMeasured(allocator, bytes, null);
}

fn validateGraphStructureMeasured(allocator: std.mem.Allocator, bytes: []const u8, work: ?*JsonTraversalWork) !void {
    var stack = std.array_list.Managed(JsonItems).init(allocator);
    defer stack.deinit();
    try stack.append(try JsonItems.initMeasured(allocator, bytes, '{', work));
    while (stack.items.len != 0) {
        if (@import("builtin").is_test) {
            if (work) |measured| measured.validator_steps += 1;
        }
        const top = &stack.items[stack.items.len - 1];
        if (!try top.nextHead()) {
            const remaining = top.cursor.bytes;
            _ = stack.pop();
            if (stack.items.len == 0) {
                if (remaining.len != 0) return error.MalformedJson;
            } else {
                stack.items[stack.items.len - 1].cursor.bytes = remaining;
            }
            continue;
        }
        if (top.open == '{' and jsonStringEquals(top.key.raw, "subGraph")) {
            _ = try top.cursor.value();
            continue;
        }
        top.cursor.trim();
        if (top.cursor.bytes.len == 0) return error.MalformedJson;
        const open = top.cursor.bytes[0];
        if (open == '{' or open == '[') {
            // Descend before scanning the child; its final cursor advances the
            // parent on unwind instead of rescanning every descendant span.
            const child = try JsonItems.initMeasured(allocator, top.cursor.bytes, open, work);
            try stack.append(child);
        } else {
            _ = try top.cursor.value();
        }
    }
}

/// Seconds from the Unix epoch to Swift's reference date, 2001-01-01T00:00:00Z.
const reference_date_unix_offset: u64 = 978_307_200;

// The daemon encodes `Date` with JSONEncoder's default strategy: possibly
// fractional seconds since the reference date. Consumers compare against the
// Unix clock, so convert here. Starter templates stamp the reference date itself
// as a placeholder, so it and anything earlier stay unknown rather than becoming
// a decades-old age; results stay below the label helpers' 1e12 millisecond cutoff.
fn unixSecondsFromReferenceDate(value: JsonValue) ?u64 {
    const max_reference_seconds: f64 = 1_000_000_000_000 - @as(f64, @floatFromInt(reference_date_unix_offset));
    const seconds = value.float() orelse return null;
    if (!(seconds > 0) or seconds >= max_reference_seconds) return null;
    return @as(u64, @intFromFloat(@floor(seconds))) + reference_date_unix_offset;
}

fn decodeNodes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    nodes: *std.array_list.Managed(Node),
) !void {
    var items = try JsonItems.init(allocator, bytes, '[');
    while (try items.next()) |value| {
        const object = value.container('{') orelse continue;
        var fields = try JsonFields.init(allocator, object);
        defer fields.deinit();
        var goal = try JsonFields.init(allocator, fields.get("goal").container('{') orelse "{}");
        defer goal.deinit();
        var usage = try JsonFields.init(allocator, fields.get("usage").container('{') orelse "{}");
        defer usage.deinit();
        var binding = try JsonFields.init(allocator, fields.get("worktreeBinding").container('{') orelse "{}");
        defer binding.deinit();
        const samples = try scopedMetricSamples(allocator, fields.get("metricHistory"));
        var node = Node{
            .id = &.{},
            .title = &.{},
            .loop_type = &.{},
            .state = &.{},
            .activity = &.{},
            .presence = &.{},
            .poll_interval_seconds = scopedFallback(&fields, &goal, "goal", "pollIntervalSeconds").float(),
            .stall_after_seconds = scopedFallback(&fields, &goal, "goal", "stallAfterSeconds").float(),
            .created_at = unixSecondsFromReferenceDate(fields.get("createdAt")),
            .metric_passes = samples.passes,
            .metric_samples = samples.values,
            .metric_sample_count = samples.count,
            .token_usage = scopedUsageTotal(if (fields.has("usage")) &usage else &fields),
            .follows_template = !fields.get("templateFollow").isNull(),
        };
        errdefer freeNode(allocator, node);
        node.id = try fields.get("id").duplicateString(allocator, "");
        node.title = try fields.get("title").duplicateString(allocator, "Untitled");
        node.loop_type = try fields.get("loopType").duplicateString(allocator, "turnBased");
        node.state = try fields.get("state").duplicateString(allocator, "idle");
        node.activity = try fields.get("activity").duplicateString(allocator, "");
        const presence = fields.get("presence");
        if (presence.container('{')) |reading| {
            var reading_fields = try JsonFields.init(allocator, reading);
            defer reading_fields.deinit();
            node.presence = try reading_fields.get("presence").duplicateString(allocator, "");
        } else {
            node.presence = try presence.duplicateString(allocator, "");
        }
        node.backend = try fields.get("backend").duplicateString(allocator, "");
        node.pilot_state = try fields.get("pilotState").duplicateString(allocator, "notPiloted");
        node.goal_summary = try goal.get("summary").duplicateString(allocator, "");
        node.goal_predicate = try goal.get("predicate").duplicateString(allocator, "");
        node.metric_command = try scopedFallback(&fields, &goal, "goal", "metricCommand").duplicateString(allocator, "");
        node.metric_direction = try scopedFallback(&fields, &goal, "goal", "metricDirection").duplicateString(allocator, "");
        node.trigger_prompt = try fields.get("triggerPrompt").duplicateString(allocator, "");
        node.first_instruction = try fields.get("firstInstruction").duplicateString(allocator, "");
        node.check_description = try fields.get("checkDescription").duplicateString(allocator, "");
        node.model_tier = try fields.get("modelTier").duplicateString(allocator, "");
        const path_value = binding.get("path");
        const path = if (path_value.container('"') != null) path_value else binding.get("worktreePath");
        node.worktree_path = try path.duplicateString(allocator, "");
        node.worktree_branch = try binding.get("branch").duplicateString(allocator, "");
        node.subgraph_json = try allocator.dupe(u8, fields.get("subGraph").container('{') orelse "");
        try nodes.append(node);
    }
}

fn decodeEdges(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !std.array_list.Managed(Edge) {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.MalformedEdge;
    var edges = std.array_list.Managed(Edge).init(allocator);
    errdefer freeEdges(allocator, &edges);
    for (parsed.value.array.items) |value| {
        const edge = try decodeEdge(allocator, value);
        errdefer freeEdge(allocator, edge);
        try edges.append(edge);
    }
    return edges;
}

fn decodeEdge(allocator: std.mem.Allocator, value: std.json.Value) !Edge {
    if (value != .object) return error.MalformedEdge;
    const object = value.object;
    const count = try edgeOptionalInteger(object.get("fireCount")) orelse blk: {
        const legacy = object.get("fired") orelse break :blk 0;
        break :blk switch (legacy) {
            .null => 0,
            .bool => |fired| @as(i64, if (fired) 1 else 0),
            else => return error.MalformedEdge,
        };
    };
    var edge = Edge{
        .from = &.{},
        .to = &.{},
        .condition = &.{},
        .fire_count = count,
        .fired = count > 0,
    };
    errdefer freeEdge(allocator, edge);
    edge.id = try allocator.dupe(u8, edgeString(object, "id", ""));
    edge.from = try allocator.dupe(u8, edgeString(object, "from", ""));
    edge.to = try allocator.dupe(u8, edgeString(object, "to", ""));
    edge.kind = try allocator.dupe(u8, edgeString(object, "kind", "handoff"));
    edge.condition = try allocator.dupe(u8, edgeString(object, "condition", "always"));
    edge.blocks_target = !std.mem.eql(u8, edge.kind, "message");
    edge.cycle_guard = try decodeCycleGuard(allocator, object.get("cycleGuard"));
    edge.payload_transform = decodePayloadTransform(allocator, object) catch |err| switch (err) {
        error.UnsupportedEdgeConfiguration => blk: {
            edge.editable_configuration = false;
            break :blk .none;
        },
        else => return err,
    };
    if (object.get("spawnTargetProjectPath")) |path| switch (path) {
        .null => {},
        .string => |text| edge.spawn_target_project_path = try allocator.dupe(u8, text),
        else => edge.editable_configuration = false,
    };
    return edge;
}

fn decodePayloadTransform(allocator: std.mem.Allocator, object: std.json.ObjectMap) !PayloadTransform {
    if (object.get("payloadTransform")) |value| {
        if (value != .null) {
            if (value != .object or value.object.count() != 1) return error.UnsupportedEdgeConfiguration;
            var iterator = value.object.iterator();
            const entry = iterator.next().?;
            if (entry.value_ptr.* != .object) return error.UnsupportedEdgeConfiguration;
            if (std.mem.eql(u8, entry.key_ptr.*, "none")) return .none;
            const text = entry.value_ptr.object.get("_0") orelse return error.UnsupportedEdgeConfiguration;
            if (text != .string) return error.UnsupportedEdgeConfiguration;
            if (std.mem.eql(u8, entry.key_ptr.*, "template")) return .{ .template = try allocator.dupe(u8, text.string) };
            if (std.mem.eql(u8, entry.key_ptr.*, "script")) return .{ .script = try allocator.dupe(u8, text.string) };
            return error.UnsupportedEdgeConfiguration;
        }
    }
    if (object.get("payloadNote")) |note| switch (note) {
        .null => {},
        .string => |text| return .{ .template = try allocator.dupe(u8, text) },
        else => return error.UnsupportedEdgeConfiguration,
    };
    return .none;
}

test "edge editing model: lossless transform spawn legacy and unsupported fields" {
    const allocator = std.testing.allocator;
    var edges = try decodeEdges(allocator,
        \\[{"payloadTransform":{"template":{"_0":" \u2603 \"text\" "}},"spawnTargetProjectPath":""},{"payloadNote":"legacy","spawnTargetProjectPath":null},{"payloadTransform":{"script":{"_0":""}}},{"payloadTransform":{"future":{"_0":"x"}}},{"spawnTargetProjectPath":3}]
    );
    defer freeEdges(allocator, &edges);
    try std.testing.expectEqualStrings(" \xe2\x98\x83 \"text\" ", edges.items[0].payload_transform.template);
    try std.testing.expectEqualStrings("", edges.items[0].spawn_target_project_path.?);
    try std.testing.expectEqualStrings("legacy", edges.items[1].payload_transform.template);
    try std.testing.expect(edges.items[1].spawn_target_project_path == null);
    try std.testing.expectEqualStrings("", edges.items[2].payload_transform.script);
    try std.testing.expect(!edges.items[3].editable_configuration and !edges.items[4].editable_configuration);
    var copies = try cloneEdges(allocator, edges.items);
    defer freeEdges(allocator, &copies);
    try std.testing.expect(copies.items[0].payload_transform.template.ptr != edges.items[0].payload_transform.template.ptr);
    try std.testing.expect(!copies.items[3].editable_configuration);
}

test "edge editing model: added configuration allocations unwind" {
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var edges = try decodeEdges(allocator,
                \\[{"payloadTransform":{"script":{"_0":"command"}},"spawnTargetProjectPath":"project","cycleGuard":{"until":"until"}},{"payloadNote":"legacy"}]
            );
            defer freeEdges(allocator, &edges);
            var copies = try cloneEdges(allocator, edges.items);
            defer freeEdges(allocator, &copies);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

/// Resolve from the cache, not the separately cloned display projection.
pub fn copyCachedEdgeForEditing(allocator: std.mem.Allocator, model: *const Model, id: []const u8) !Edge {
    const root = model.currentGraph() orelse return error.StaleScope;
    if (model.open_composite_id) |parent_id| {
        const parent_index = findNodeIndexByID(root.nodes.items, parent_id) orelse return error.StaleScope;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, root.nodes.items[parent_index].subgraph_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.StaleScope;
        const edges = parsed.value.object.get("edges") orelse return error.StaleEdge;
        const nodes = parsed.value.object.get("nodes") orelse return error.StaleScope;
        if (edges != .array or nodes != .array) return error.StaleScope;
        for (edges.array.items) |value| {
            if (value != .object or !std.mem.eql(u8, edgeString(value.object, "id", ""), id)) continue;
            const edge = try decodeEdge(allocator, value);
            errdefer freeEdge(allocator, edge);
            var source = false;
            var target = false;
            for (nodes.array.items) |node| {
                if (node != .object) return error.StaleScope;
                const node_id = edgeString(node.object, "id", "");
                source = source or std.mem.eql(u8, node_id, edge.from);
                target = target or std.mem.eql(u8, node_id, edge.to);
            }
            if (!source) return error.MissingSource;
            if (!target) return error.MissingTarget;
            return edge;
        }
        return error.StaleEdge;
    }
    const index = findEdgeIndexByID(root.edges.items, id) orelse return error.StaleEdge;
    const edge = root.edges.items[index];
    if (findNodeIndexByID(root.nodes.items, edge.from) == null) return error.MissingSource;
    if (findNodeIndexByID(root.nodes.items, edge.to) == null) return error.MissingTarget;
    return cloneEdge(allocator, edge);
}

fn edgeString(object: std.json.ObjectMap, key: []const u8, fallback: []const u8) []const u8 {
    const value = object.get(key) orelse return fallback;
    return if (value == .string) value.string else fallback;
}

fn edgeOptionalInteger(value: ?std.json.Value) !?i64 {
    const field = value orelse return null;
    return switch (field) {
        .null => null,
        .integer => |number| number,
        else => error.MalformedEdge,
    };
}

fn decodeCycleGuard(allocator: std.mem.Allocator, value: ?std.json.Value) !?CycleGuard {
    const field = value orelse return null;
    if (field == .null) return null;
    if (field != .object) return error.MalformedEdge;
    const maximum = try edgeOptionalInteger(field.object.get("maxIterations"));
    const plateau = try edgeOptionalInteger(field.object.get("stopAfterPassesWithoutImprovement"));
    const until: ?[]const u8 = if (field.object.get("until")) |text| switch (text) {
        .null => null,
        .string => |string| string,
        else => return error.MalformedEdge,
    } else null;
    return .{
        .max_iterations = maximum,
        .stop_after_passes_without_improvement = plateau,
        .until = if (until) |text| try allocator.dupe(u8, text) else null,
    };
}

const MetricSamples = struct {
    values: [8]f64 = [_]f64{0} ** 8,
    count: u8 = 0,
    passes: u32 = 0,
};

fn scopedMetricSamples(allocator: std.mem.Allocator, value: JsonValue) !MetricSamples {
    const array = value.container('[') orelse return .{};
    var result = MetricSamples{};
    var items = try JsonItems.init(allocator, array, '[');
    while (try items.next()) |item| {
        const object = item.container('{') orelse continue;
        result.passes +|= 1;
        var fields = try JsonFields.init(allocator, object);
        defer fields.deinit();
        if (fields.get("value").float()) |sample| {
            if (result.count == result.values.len) {
                std.mem.copyForwards(f64, result.values[0 .. result.values.len - 1], result.values[1..]);
                result.values[result.values.len - 1] = sample;
            } else {
                result.values[result.count] = sample;
                result.count += 1;
            }
        }
    }
    return result;
}

fn scopedUsageTotal(fields: *const JsonFields) ?u32 {
    const input = fields.get("inputTokens").unsigned(u32) orelse fields.get("inputTokenCount").unsigned(u32) orelse 0;
    const output = fields.get("outputTokens").unsigned(u32) orelse fields.get("outputTokenCount").unsigned(u32) orelse 0;
    if (input == 0 and output == 0) return null;
    return input +| output;
}

fn scopedFallback(fields: *const JsonFields, nested: *const JsonFields, parent: []const u8, key: []const u8) JsonValue {
    if (nested.has(key)) return nested.get(key);
    if (fields.has(parent) and fields.get(parent).container('{') == null) return .{};
    return fields.get(key);
}

fn duplicateJsonString(allocator: std.mem.Allocator, object: []const u8, key: []const u8) ![]u8 {
    return Wire.decodeJsonString(allocator, Wire.jsonString(object, key) orelse "");
}

pub fn subgraphNodeCount(subgraph_json: []const u8) usize {
    // This nonfallible display query remains allocation-free. Decoding performs
    // structural validation; here only immediate fields/elements are counted.
    const json = std.mem.trim(u8, subgraph_json, " \t\r\n");
    if (json.len == 0 or json[0] != '{') return 0;
    var depth: usize = 0;
    var index: usize = 0;
    while (index < json.len) {
        const byte = json[index];
        if (byte == '"') {
            const end = index + (JsonCursor.stringEnd(json[index..]) catch return 0);
            if (depth == 1 and jsonStringEquals(json[index..end], "nodes")) {
                var value = std.mem.trimLeft(u8, json[end..], " \t\r\n");
                if (value.len != 0 and value[0] == ':') {
                    value = std.mem.trimLeft(u8, value[1..], " \t\r\n");
                    if (value.len == 0 or value[0] != '[') return 0;
                    const close = findClosing(value, 0, '[', ']') orelse return 0;
                    return countImmediateObjects(value[1..close]);
                }
            }
            index = end;
            continue;
        }
        if (byte == '{' or byte == '[') depth += 1;
        if (byte == '}' or byte == ']') {
            if (depth == 0) return 0;
            depth -= 1;
            if (depth == 0) return 0;
        }
        index += 1;
    }
    return 0;
}

fn countImmediateObjects(bytes: []const u8) usize {
    var count: usize = 0;
    var depth: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) {
        const byte = bytes[index];
        if (byte == '"') {
            index += JsonCursor.stringEnd(bytes[index..]) catch return 0;
            continue;
        }
        if (byte == '{' or byte == '[') {
            if (byte == '{' and depth == 0) count += 1;
            depth += 1;
        } else if (byte == '}' or byte == ']') {
            if (depth == 0) return 0;
            depth -= 1;
        }
        index += 1;
    }
    return if (depth == 0) count else 0;
}

pub fn decodeSubgraph(
    allocator: std.mem.Allocator,
    parent_project: Project,
    subgraph_json: []const u8,
) !Graph {
    const json = std.mem.trim(u8, subgraph_json, " \t\r\n");
    return decodeGraphObject(allocator, parent_project, if (json.len == 0 or std.mem.eql(u8, json, "null")) "{}" else json) catch |err| switch (err) {
        error.MalformedJson => return error.MalformedSubgraph,
        else => return err,
    };
}

fn decodeGraphFrame(allocator: std.mem.Allocator, frame: []const u8) !?Graph {
    try validateGraphStructure(allocator, frame);
    var root = try JsonFields.init(allocator, frame);
    defer root.deinit();
    var event = try JsonFields.init(allocator, root.get("event").container('{') orelse "{}");
    defer event.deinit();
    const value = if (root.has("event")) event.get("graphChanged") else root.get("graphChanged");
    if (value.isNull()) return null;
    const payload = value.container('{') orelse return error.MalformedJson;
    // The daemon's synthesized Swift coding wraps the unlabeled associated value as
    // {"_0":<graph>}; the unwrapped form remains accepted for existing fixtures.
    var wrapper = try JsonFields.init(allocator, payload);
    defer wrapper.deinit();
    const graph_json = if (wrapper.has("_0"))
        wrapper.get("_0").container('{') orelse return error.MalformedJson
    else
        payload;
    return try decodeGraphObject(allocator, null, graph_json);
}

fn decodeGraphObject(allocator: std.mem.Allocator, parent_project: ?Project, json: []const u8) !Graph {
    try validateGraphStructure(allocator, json);
    var fields = try JsonFields.init(allocator, json);
    defer fields.deinit();
    var graph = Graph{
        .project = .{ .path = &.{}, .name = &.{} },
        .nodes = std.array_list.Managed(Node).init(allocator),
        .edges = std.array_list.Managed(Edge).init(allocator),
    };
    errdefer freeGraph(allocator, &graph);
    if (parent_project) |project| {
        graph.project = try cloneProject(allocator, project);
    } else {
        var project = try JsonFields.init(allocator, fields.get("project").container('{') orelse "{}");
        defer project.deinit();
        graph.project.path = try project.get("path").duplicateString(allocator, "");
        graph.project.name = try project.get("name").duplicateString(allocator, "");
    }
    if (fields.get("nodes").container('[')) |nodes| try decodeNodes(allocator, nodes, &graph.nodes);
    if (fields.get("edges").container('[')) |edges| graph.edges = try decodeEdges(allocator, edges);
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

fn cloneProject(allocator: std.mem.Allocator, project: Project) !Project {
    const path = try allocator.dupe(u8, project.path);
    errdefer allocator.free(path);
    return .{ .path = path, .name = try allocator.dupe(u8, project.name) };
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
    allocator.free(node.first_instruction);
    allocator.free(node.check_description);
    allocator.free(node.model_tier);
    allocator.free(node.worktree_path);
    allocator.free(node.worktree_branch);
    allocator.free(node.subgraph_json);
}

test "sketch promotion first instruction survives decode clones and source replacement" {
    const allocator = std.testing.allocator;
    var model = Model.init(allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"A","name":"A"},"nodes":[{"id":"note","title":"Sketch","loopType":"sketch","firstInstruction":"  \u96ea \"note\"  ","triggerPrompt":"not the note","checkDescription":"not the note"},{"id":"empty","title":"Empty","loopType":"sketch"}],"edges":[]}}
    );
    const summary = model.graphFor("A").?;
    try std.testing.expectEqualStrings("  \u{96ea} \"note\"  ", summary.nodes.items[0].first_instruction);
    try std.testing.expectEqualStrings("", summary.nodes.items[1].first_instruction);
    try std.testing.expectEqualStrings("  \u{96ea} \"note\"  ", model.graph.?.nodes.items[0].first_instruction);
    var copy = try cloneNode(allocator, summary.nodes.items[0]);
    defer freeNode(allocator, copy);
    _ = try model.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"A","name":"A"},"nodes":[{"id":"note","title":"Sketch","loopType":"sketch","firstInstruction":"new"}],"edges":[]}}
    );
    try std.testing.expectEqualStrings("  \u{96ea} \"note\"  ", copy.first_instruction);
    try std.testing.expectEqualStrings("new", model.graph.?.nodes.items[0].first_instruction);
    copy.first_instruction[0] = 'x';
    try std.testing.expectEqualStrings("new", model.graphFor("A").?.nodes.items[0].first_instruction);
}

test "sketch promotion first instruction single owner cleans every clone and decode allocation failure" {
    const Probe = struct {
        fn clone(allocator: std.mem.Allocator) !void {
            const source = Node{
                .id = @constCast("id"), .title = @constCast("Sketch"), .loop_type = @constCast("sketch"),
                .state = @constCast("idle"), .activity = &.{}, .presence = &.{},
                .first_instruction = @constCast("Owned \"note\" \u{96ea}"),
                .check_description = @constCast("allocated after the note"),
            };
            const copy = try cloneNode(allocator, source);
            defer freeNode(allocator, copy);
            try std.testing.expectEqualStrings(source.first_instruction, copy.first_instruction);
            try std.testing.expectEqualStrings(source.check_description, copy.check_description);
        }

        fn decode(allocator: std.mem.Allocator) !void {
            var nodes = std.array_list.Managed(Node).init(allocator);
            defer {
                for (nodes.items) |node| freeNode(allocator, node);
                nodes.deinit();
            }
            try decodeNodes(allocator,
                \\[{"id":"id","firstInstruction":"Owned \"note\" \u96ea","checkDescription":"allocated after the note"},{"id":"second","firstInstruction":"second note"}]
            , &nodes);
            try std.testing.expectEqual(@as(usize, 2), nodes.items.len);
            try std.testing.expectEqualStrings("Owned \"note\" \u{96ea}", nodes.items[0].first_instruction);
            try std.testing.expectEqualStrings("allocated after the note", nodes.items[0].check_description);
            try std.testing.expectEqualStrings("second note", nodes.items[1].first_instruction);
        }

        fn sweep(comptime operation: anytype, name: []const u8) !void {
            var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            try operation(counting.allocator());
            try std.testing.expect(counting.alloc_index > 0);
            try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
            for (0..counting.alloc_index) |fail_index| {
                var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
                try std.testing.expectError(error.OutOfMemory, operation(failing.allocator()));
                try std.testing.expect(failing.has_induced_failure);
                try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            }
            std.debug.print("first instruction {s}: {d} allocation positions -> OutOfMemory, allocated_bytes == freed_bytes at every position\n", .{ name, counting.alloc_index });
        }
    };
    try Probe.sweep(Probe.clone, "cloneNode");
    try Probe.sweep(Probe.decode, "decodeNodes");
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
    for (graph.edges.items) |edge| freeEdge(allocator, edge);
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

fn custodySelectionTestModel() !Model {
    var model = Model.init(std.testing.allocator);
    errdefer model.deinit();
    _ = try model.updateFromFrame(
        \\{"event":{"graphChanged":{"project":{"path":"A","name":"Alpha"},"nodes":[{"id":"group","title":"Group","loopType":"composite","subGraph":{"nodes":[{"id":"inner","title":"Inner"}],"edges":[]}}],"edges":[]}}}
    );
    _ = try model.updateFromFrame(
        \\{"event":{"graphChanged":{"project":{"path":"B","name":"Beta"},"nodes":[{"id":"b1","title":"B1"}],"edges":[]}}}
    );
    _ = try model.updateFromFrame(
        \\{"event":{"graphChanged":{"project":{"path":"E","name":"Empty"},"nodes":[],"edges":[]}}}
    );
    if (!model.openComposite("group") or !model.setSelectedIndex(0)) return error.TestSetupFailed;
    return model;
}

test "custody selection stages both identity allocations before any selection mutation" {
    for (0..2) |fail_index| {
        var model = try custodySelectionTestModel();
        defer model.deinit();
        const old_path = model.selected_project_path.?;
        const old_composite = model.open_composite_id.?;
        const old_composite_title = model.open_composite_title.?;
        const old_node = model.selected_node_id.?;
        const old_nodes = model.graph.?.nodes.items.ptr;
        const old_index = model.selected_index;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        model.allocator = failing.allocator();
        defer model.allocator = std.testing.allocator;
        const selected = model.selectProject("B");
        try std.testing.expect(!selected);
        try std.testing.expect(model.open_composite_id != null);
        try std.testing.expectEqual(old_composite.ptr, model.open_composite_id.?.ptr);
        try std.testing.expectEqual(old_composite_title.ptr, model.open_composite_title.?.ptr);
        try std.testing.expectEqual(old_path.ptr, model.selected_project_path.?.ptr);
        try std.testing.expectEqual(old_node.ptr, model.selected_node_id.?.ptr);
        try std.testing.expectEqual(old_nodes, model.graph.?.nodes.items.ptr);
        try std.testing.expectEqual(old_index, model.selected_index);
        try std.testing.expectEqualStrings("A", model.selected_project_path.?);
        try std.testing.expectEqualStrings("group", model.open_composite_id.?);
        try std.testing.expectEqualStrings("Group", model.open_composite_title.?);
        try std.testing.expectEqualStrings("inner", model.selected_node_id.?);
    }
}

test "custody selection preserves normal same different and empty project behavior" {
    for ([_][]const u8{ "A", "B", "E" }) |target| {
        var model = try custodySelectionTestModel();
        defer model.deinit();
        try std.testing.expect(model.selectProject(target));
        try std.testing.expectEqualStrings(target, model.selected_project_path.?);
        try std.testing.expectEqualStrings(target, model.graph.?.project.path);
        try std.testing.expect(model.open_composite_id == null);
        if (std.mem.eql(u8, target, "E")) {
            try std.testing.expect(model.selected_node_id == null);
            try std.testing.expect(model.selected_index == null);
        } else {
            try std.testing.expectEqualStrings(if (std.mem.eql(u8, target, "A")) "group" else "b1", model.selected_node_id.?);
            try std.testing.expectEqual(@as(?usize, 0), model.selected_index);
        }
    }
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
    try std.testing.expectEqual(@as(i64, 1), model.graph.?.edges.items[0].fire_count);
    try std.testing.expectEqual(@as(i64, 123), model.graph.?.edges.items[1].fire_count);
    try std.testing.expectEqual(@as(usize, 0), model.attentionCount());
}

test "edge guard decoding preserves optional signed data and authoritative counts" {
    const Case = struct { json: []const u8, count: i64, guarded: bool = false };
    const cases = [_]Case{
        .{ .json = "[{}]", .count = 0 },
        .{ .json = "[{\"cycleGuard\":null,\"fired\":null}]", .count = 0 },
        .{ .json = "[{\"fired\":true}]", .count = 1 },
        .{ .json = "[{\"fired\":false}]", .count = 0 },
        .{ .json = "[{\"fireCount\":null,\"fired\":true}]", .count = 1 },
        .{ .json = "[{\"fireCount\":null,\"fired\":false}]", .count = 0 },
        .{ .json = "[{\"fireCount\":null}]", .count = 0 },
        .{ .json = "[{\"fireCount\":0,\"fired\":true}]", .count = 0 },
        .{ .json = "[{\"fireCount\":2,\"fired\":false}]", .count = 2 },
        .{ .json = "[{\"fireCount\":2,\"fired\":\"unused\"}]", .count = 2 },
        .{ .json = "[{\"fireCount\":-1,\"fired\":true}]", .count = -1 },
        .{ .json = "[{\"fireCount\":9223372036854775807}]", .count = std.math.maxInt(i64) },
        .{ .json = "[{\"fireCount\":-9223372036854775808}]", .count = std.math.minInt(i64) },
        .{ .json = "[{\"cycleGuard\":{}}]", .count = 0, .guarded = true },
        .{ .json = "[{\"cycleGuard\":{\"maxIterations\":null,\"until\":null,\"stopAfterPassesWithoutImprovement\":null}}]", .count = 0, .guarded = true },
        .{ .json = "[{\"future\":{\"fireCount\":99,\"kind\":\"message\",\"until\":\"wrong\"},\"cycleGuard\":{\"budget\":5}}]", .count = 0, .guarded = true },
    };
    for (cases) |case| {
        var edges = try decodeEdges(std.testing.allocator, case.json);
        defer freeEdges(std.testing.allocator, &edges);
        try std.testing.expectEqual(@as(usize, 1), edges.items.len);
        const edge = edges.items[0];
        try std.testing.expectEqual(case.count, edge.fire_count);
        try std.testing.expectEqual(case.count > 0, edge.fired);
        try std.testing.expectEqual(case.guarded, edge.cycle_guard != null);
        try std.testing.expectEqualStrings("handoff", edge.kind);
        try std.testing.expectEqualStrings("always", edge.condition);
    }
    var edges = try decodeEdges(std.testing.allocator,
        \\[{"kind":"futureKind","condition":"futureCondition","cycleGuard":{"maxIterations":-9223372036854775808,"until":" \tquote \"x\" \\ \u2603  ","stopAfterPassesWithoutImprovement":9223372036854775807}},{"cycleGuard":{"maxIterations":0,"until":"","stopAfterPassesWithoutImprovement":-2}}]
    );
    defer freeEdges(std.testing.allocator, &edges);
    const guard = edges.items[0].cycle_guard.?;
    try std.testing.expectEqualStrings("futureKind", edges.items[0].kind);
    try std.testing.expectEqualStrings("futureCondition", edges.items[0].condition);
    try std.testing.expectEqual(@as(?i64, std.math.minInt(i64)), guard.max_iterations);
    try std.testing.expectEqual(@as(?i64, std.math.maxInt(i64)), guard.stop_after_passes_without_improvement);
    try std.testing.expectEqualStrings(" \tquote \"x\" \\ ☃  ", guard.until.?);
    try std.testing.expectEqual(@as(?i64, 0), edges.items[1].cycle_guard.?.max_iterations);
    try std.testing.expectEqual(@as(?i64, -2), edges.items[1].cycle_guard.?.stop_after_passes_without_improvement);
    try std.testing.expectEqualStrings("", edges.items[1].cycle_guard.?.until.?);
}

fn edgeGuardTestFrame(allocator: std.mem.Allocator, edges: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{
        "{\"version\":2,\"kind\":\"event\",\"sequence\":1,\"event\":{\"graphChanged\":{\"project\":{\"path\":\"edge-fixture\",\"name\":\"Edge fixture\"},\"nodes\":[],\"edges\":",
        edges,
        "}}}",
    });
}

test "edge guard malformed replacements preserve the last valid graph" {
    const allocator = std.testing.allocator;
    var model = Model.init(allocator);
    defer model.deinit();
    const valid = try edgeGuardTestFrame(allocator,
        \\[{"id":"kept","from":"a","to":"b","cycleGuard":{"until":"keep me"},"fireCount":2}]
    );
    defer allocator.free(valid);
    _ = try model.updateFromFrame(valid);
    for ([_][]const u8{
        "[false]",
        "[{\"cycleGuard\":\"none\"}]",
        "[{\"cycleGuard\":[]}]",
        "[{\"cycleGuard\":{\"until\":true}}]",
        "[{\"cycleGuard\":{\"maxIterations\":\"3\"}}]",
        "[{\"cycleGuard\":{\"maxIterations\":2.5}}]",
        "[{\"cycleGuard\":{\"maxIterations\":9223372036854775808}}]",
        "[{\"cycleGuard\":{\"stopAfterPassesWithoutImprovement\":false}}]",
        "[{\"cycleGuard\":{\"stopAfterPassesWithoutImprovement\":-9223372036854775809}}]",
        "[{\"fireCount\":\"2\",\"fired\":true}]",
        "[{\"fireCount\":2.5,\"fired\":true}]",
        "[{\"fireCount\":2.0}]",
        "[{\"fireCount\":2e0}]",
        "[{\"fireCount\":9223372036854775808}]",
        "[{\"fireCount\":-9223372036854775809}]",
        "[{\"fired\":\"true\"}]",
        "[{\"fireCount\":null,\"fired\":1}]",
        "[{\"cycleGuard\":{\"until\":\"allocated first\"}},{\"cycleGuard\":false}]",
    }) |invalid| {
        const frame = try edgeGuardTestFrame(allocator, invalid);
        defer allocator.free(frame);
        try std.testing.expectError(error.MalformedEdge, model.updateFromFrame(frame));
        for ([_]Edge{ model.graph.?.edges.items[0], model.currentGraph().?.edges.items[0] }) |edge| {
            try std.testing.expectEqualStrings("kept", edge.id);
            try std.testing.expectEqualStrings("keep me", edge.cycle_guard.?.until.?);
            try std.testing.expectEqual(@as(i64, 2), edge.fire_count);
            try std.testing.expect(edge.fired);
        }
    }
    try std.testing.expectError(error.SyntaxError, decodeEdges(allocator, "[{]"));
}

test "edge guard ownership survives input release project selection and same ID refresh" {
    const allocator = std.testing.allocator;
    var model = Model.init(allocator);
    defer model.deinit();
    {
        const frame = try edgeGuardTestFrame(allocator,
            \\[{"id":"kept","from":"a","to":"b","cycleGuard":{"until":"  keep me  ","maxIterations":3},"fireCount":2},{"id":"other","from":"b","to":"a"}]
        );
        defer allocator.free(frame);
        _ = try model.updateFromFrame(frame);
        @memset(frame, '?');
    }
    const retained = model.currentGraph().?.edges.items[0];
    const selected = model.graph.?.edges.items[0];
    try std.testing.expect(retained.cycle_guard.?.until.?.ptr != selected.cycle_guard.?.until.?.ptr);
    try std.testing.expect(retained.id.ptr != selected.id.ptr);
    try std.testing.expectEqualStrings("  keep me  ", selected.cycle_guard.?.until.?);
    _ = try model.updateFromFrame(
        \\{"event":{"graphChanged":{"project":{"path":"other-project","name":"Other"},"nodes":[],"edges":[]}}}
    );
    try std.testing.expect(model.selectProject("other-project"));
    try std.testing.expect(model.selectProject("edge-fixture"));
    try std.testing.expectEqualStrings("  keep me  ", model.graph.?.edges.items[0].cycle_guard.?.until.?);
    const refresh = try edgeGuardTestFrame(allocator,
        \\[{"id":"other","from":"b","to":"a"},{"id":"kept","from":"a","to":"b","cycleGuard":{"until":"replacement","stopAfterPassesWithoutImprovement":2},"fireCount":3}]
    );
    defer allocator.free(refresh);
    _ = try model.updateFromFrame(refresh);
    const index = findEdgeIndexByID(model.graph.?.edges.items, "kept").?;
    try std.testing.expectEqual(@as(usize, 1), index);
    const updated = model.graph.?.edges.items[index];
    try std.testing.expectEqualStrings("a", updated.from);
    try std.testing.expectEqualStrings("b", updated.to);
    try std.testing.expectEqualStrings("replacement", updated.cycle_guard.?.until.?);
    try std.testing.expectEqual(@as(?i64, null), updated.cycle_guard.?.max_iterations);
    const removed = try edgeGuardTestFrame(allocator,
        \\[{"id":"kept","from":"a","to":"b","cycleGuard":null,"fireCount":0,"fired":true}]
    );
    defer allocator.free(removed);
    _ = try model.updateFromFrame(removed);
    try std.testing.expect(model.graph.?.edges.items[0].cycle_guard == null);
    try std.testing.expect(model.currentGraph().?.edges.items[0].cycle_guard == null);
    try std.testing.expect(!model.graph.?.edges.items[0].fired);
}

test "edge guard decoder and clone append allocations unwind" {
    const Exercise = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var edges = try decodeEdges(allocator,
                \\[{"id":"one","from":"a","to":"b","kind":"message","condition":"onSuccess","cycleGuard":{"maxIterations":3,"until":"  test \"done\"  ","stopAfterPassesWithoutImprovement":2},"fireCount":2},{"id":"two","from":"b","to":"a","cycleGuard":{"until":"another"}}]
            );
            defer freeEdges(allocator, &edges);
            var copies = try cloneEdges(allocator, edges.items);
            defer freeEdges(allocator, &copies);
            try std.testing.expectEqualStrings("  test \"done\"  ", copies.items[0].cycle_guard.?.until.?);
            try std.testing.expect(edges.items[0].cycle_guard.?.until.?.ptr != copies.items[0].cycle_guard.?.until.?.ptr);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Exercise.run, .{});
}

test "edge guard composite decoder retains bounds and rejects malformed guard" {
    const allocator = std.testing.allocator;
    var graph = try decodeSubgraph(allocator, .{ .path = @constCast("edge-fixture"), .name = @constCast("Edge fixture") },
        \\{"nodes":[],"edges":[{"id":"nested","from":"a","to":"b","cycleGuard":{"maxIterations":4,"until":"nested command"},"fireCount":3}]}
    );
    defer freeGraph(allocator, &graph);
    try std.testing.expectEqualStrings("nested", graph.edges.items[0].id);
    try std.testing.expectEqualStrings("nested command", graph.edges.items[0].cycle_guard.?.until.?);
    try std.testing.expectEqual(@as(?i64, 4), graph.edges.items[0].cycle_guard.?.max_iterations);
    try std.testing.expect(graph.edges.items[0].fired);
    try std.testing.expectError(error.MalformedEdge, decodeSubgraph(allocator, graph.project,
        \\{"nodes":[],"edges":[{"cycleGuard":false}]}
    ));
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

const scopeChildGraph =
    \\{"nodes":[{"id":"child-a","subGraph":{"nodes":[{"id":"grandchild"}],"edges":[{"id":"grand-edge","from":"grandchild","to":"grandchild"}]}},{"id":"child-b"}],"edges":[{"id":"child-edge","from":"child-a","to":"child-b"}],"project":{"path":"child-project","name":"Child project"}}
;
const scopeNodes = "[{\"subGraph\":" ++ scopeChildGraph ++
    ",\"id\":\"parent-a\"},{\"subGraph\":{\"nodes\":[{\"id\":\"other-child\"}],\"edges\":[{\"id\":\"other-edge\",\"from\":\"other-child\",\"to\":\"other-child\"}]},\"id\":\"parent-b\"}]";
const scopeEdges = "[{\"id\":\"root-edge\",\"from\":\"parent-a\",\"to\":\"parent-b\"}]";
const scopeProject = "{\"path\":\"root-project\",\"name\":\"Root project\"}";
const scopeGraph = "{\"nodes\":" ++ scopeNodes ++ ",\"edges\":" ++ scopeEdges ++ ",\"project\":" ++ scopeProject ++ "}";
const scopeFrame = "{\"event\":{\"graphChanged\":" ++ scopeGraph ++ "}}";

test "field scope graph edges are independent of root and child property order" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |edges_first| {
        for ([_][]const u8{ scopeEdges, "[]" }) |edges| {
            const json = if (edges_first)
                try std.fmt.allocPrint(allocator, "{{\"edges\":{s},\"nodes\":{s},\"project\":{s}}}", .{ edges, scopeNodes, scopeProject })
            else
                try std.fmt.allocPrint(allocator, "{{\"nodes\":{s},\"edges\":{s},\"project\":{s}}}", .{ scopeNodes, edges, scopeProject });
            defer allocator.free(json);
            const frame = try std.fmt.allocPrint(allocator, "{{\"graphChanged\":{s}}}", .{json});
            defer allocator.free(frame);
            var model = Model.init(allocator);
            defer model.deinit();
            try model.decodeGraph(frame);
            const graph = model.graph.?;
            try std.testing.expectEqual(@as(usize, if (edges.len == 2) 0 else 1), graph.edges.items.len);
            if (graph.edges.items.len != 0) try std.testing.expectEqualStrings("root-edge", graph.edges.items[0].id);
            try std.testing.expectEqual(@as(usize, 2), graph.nodes.items.len);
            try std.testing.expectEqualStrings("parent-a", graph.nodes.items[0].id);
        }
    }
}

test "field scope project identity never comes from child graphs or metadata" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try model.decodeGraph(scopeFrame);
    try std.testing.expectEqualStrings("root-project", model.graph.?.project.path);
    try std.testing.expectEqualStrings("Root project", model.graph.?.project.name);
    try std.testing.expectEqualStrings("root-project", model.selected_project_path.?);
    try std.testing.expectEqualStrings("root-project", model.open_projects.items[0].path);
}

test "field scope subgraphs retain immediate children and their own edges at every depth" {
    const allocator = std.testing.allocator;
    const project = Project{ .path = @constCast("parent-project"), .name = @constCast("Parent") };
    var graph = try decodeSubgraph(allocator, project, scopeGraph);
    defer freeGraph(allocator, &graph);
    try std.testing.expectEqualStrings("root-edge", graph.edges.items[0].id);
    var child = try decodeSubgraph(allocator, project, graph.nodes.items[0].subgraph_json);
    defer freeGraph(allocator, &child);
    try std.testing.expectEqualStrings("child-edge", child.edges.items[0].id);
    try std.testing.expectEqual(@as(usize, 2), child.nodes.items.len);
    var grandchild = try decodeSubgraph(allocator, project, child.nodes.items[0].subgraph_json);
    defer freeGraph(allocator, &grandchild);
    try std.testing.expectEqualStrings("grand-edge", grandchild.edges.items[0].id);
    try std.testing.expectEqualStrings("parent-project", grandchild.project.path);
    try std.testing.expectEqual(@as(usize, 2), subgraphNodeCount(scopeGraph));
    try std.testing.expectEqual(@as(usize, 0), subgraphNodeCount("{\"metadata\":" ++ scopeChildGraph ++ ",\"nodes\":[]}"));
}

test "field scope node and edge scalars do not inherit arbitrary nested fields" {
    const json =
        \\{"nodes":[{"metadata":{"id":"wrong","title":"Wrong","state":"failed","backend":"wrong","templateFollow":{},"createdAt":88,"inputTokens":99},"goal":{"metadata":{"summary":"Wrong"},"summary":"Own goal","predicate":"done","metricCommand":"measure","pollIntervalSeconds":12.5},"usage":{"inputTokens":3,"outputTokens":4},"presence":{"metadata":{"presence":"wrong"},"presence":"busy"},"worktreeBinding":{"metadata":{"path":"wrong","branch":"wrong"},"worktreePath":"own-path","branch":"own-branch"},"metricHistory":[{"metadata":{"value":999},"value":2}],"id":"own","title":"Own"}],"edges":[{"metadata":{"id":"wrong","from":"wrong","to":"wrong","kind":"message","fired":true,"fireCount":99},"id":"own-edge","from":"own","to":"own"}]}
    ;
    var graph = try decodeSubgraph(std.testing.allocator, .{ .path = &.{}, .name = &.{} }, json);
    defer freeGraph(std.testing.allocator, &graph);
    const node = graph.nodes.items[0];
    try std.testing.expectEqualStrings("own", node.id);
    try std.testing.expectEqualStrings("Own", node.title);
    try std.testing.expectEqualStrings("idle", node.state);
    try std.testing.expectEqualStrings("", node.backend);
    try std.testing.expect(!node.follows_template);
    try std.testing.expectEqual(@as(?u64, null), node.created_at);
    try std.testing.expectEqualStrings("Own goal", node.goal_summary);
    try std.testing.expectEqualStrings("done", node.goal_predicate);
    try std.testing.expectEqualStrings("measure", node.metric_command);
    try std.testing.expectEqual(@as(?f64, 12.5), node.poll_interval_seconds);
    try std.testing.expectEqual(@as(?u32, 7), node.token_usage);
    try std.testing.expectEqualStrings("busy", node.presence);
    try std.testing.expectEqualStrings("own-path", node.worktree_path);
    try std.testing.expectEqualStrings("own-branch", node.worktree_branch);
    try std.testing.expectEqual(@as(u32, 1), node.metric_passes);
    try std.testing.expectEqual(@as(u8, 1), node.metric_sample_count);
    try std.testing.expectEqual(@as(f64, 2), node.metric_samples[0]);
    const edge = graph.edges.items[0];
    try std.testing.expectEqualStrings("own-edge", edge.id);
    try std.testing.expectEqualStrings("own", edge.from);
    try std.testing.expectEqualStrings("handoff", edge.kind);
    try std.testing.expect(edge.blocks_target and !edge.fired);
    try std.testing.expectEqual(@as(u32, 0), edge.fire_count);
}

test "production daemon graphChanged associated-value frame decodes project and nodes" {
    // Exact shape emitted by the Swift daemon's synthesized DaemonEvent coding:
    // `case graphChanged(LoopGraph)` travels as {"graphChanged":{"_0":<graph>}}.
    const frame =
        \\{"kind":"event","sequence":1,"event":{"graphChanged":{"_0":{"edges":[],"nodes":[{"id":"core-node","title":"Core loop"}],"revision":0,"id":"B566EEB2-0E4E-4162-A067-787F8D7A8306","project":{"name":"Core","lastOpenedAt":812912680.0330639,"path":"C:\/GraphCode-Fixtures\/Core"},"mailroomDigest":{"count":0,"fingerprint":14695981039346656037,"latestID":0}}}}}
    ;
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try std.testing.expectEqual(Wire.EventKind.graph_changed, try model.updateFromFrame(frame));
    const summary = model.graphFor("C:/GraphCode-Fixtures/Core") orelse return error.ProductionGraphProjectMissing;
    try std.testing.expectEqualStrings("Core", summary.project.name);
    try std.testing.expectEqual(@as(usize, 1), summary.nodes.items.len);
    try std.testing.expectEqualStrings("Core loop", summary.nodes.items[0].title);
    try std.testing.expectEqual(@as(usize, 1), model.graphs.items.len);
    try std.testing.expectEqualStrings("C:/GraphCode-Fixtures/Core", model.graph.?.project.path);
}

test "field scope keys and delimiters inside scalar text cannot select graph fields" {
    const frame =
        \\{"metadata":{"graphChanged":{"project":{"path":"wrong"},"nodes":[],"edges":[]}},"event":{"graphChanged":{"note":"\"nodes\": [{\"id\":\"fake\"}], \"edges\": [{}] } \\ \u2603","nodes":[{"note":"\"id\":\"fake\" } [","id" : "real\u2603","title" : "Brace } quote \" slash \\ \uD83D\uDE80"}],"edges":[],"project":{"note":{"path":"wrong"},"path" : "right","name":"Root"}}}}
    ;
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try model.decodeGraph(frame);
    try std.testing.expectEqualStrings("right", model.graph.?.project.path);
    try std.testing.expectEqual(@as(usize, 1), model.graph.?.nodes.items.len);
    try std.testing.expectEqualStrings("real\xe2\x98\x83", model.graph.?.nodes.items[0].id);
    try std.testing.expectEqualStrings("Brace } quote \" slash \\ \xf0\x9f\x9a\x80", model.graph.?.nodes.items[0].title);
    try std.testing.expectEqual(@as(usize, 0), model.graph.?.edges.items.len);
}

test "field scope missing null and wrong-type fields keep defaults without child inheritance" {
    const allocator = std.testing.allocator;
    const frames = [_][]const u8{
        "{\"graphChanged\":{\"metadata\":" ++ scopeGraph ++ "}}",
        "{\"graphChanged\":{\"metadata\":" ++ scopeGraph ++ ",\"project\":null,\"nodes\":null,\"edges\":null}}",
        "{\"graphChanged\":{\"metadata\":" ++ scopeGraph ++ ",\"project\":false,\"nodes\":{},\"edges\":\"edges\"}}",
    };
    for (frames) |frame| {
        var model = Model.init(allocator);
        defer model.deinit();
        try model.decodeGraph(frame);
        try std.testing.expectEqualStrings("", model.graph.?.project.path);
        try std.testing.expectEqualStrings("", model.graph.?.project.name);
        try std.testing.expectEqual(@as(usize, 0), model.graph.?.nodes.items.len);
        try std.testing.expectEqual(@as(usize, 0), model.graph.?.edges.items.len);
    }
    const json =
        \\{"nodes":[null,"{not a node}",[{"id":"not-immediate"}],{"id":null,"title":null,"state":{},"goal":null,"presence":null,"worktreeBinding":null,"templateFollow":null,"usage":null,"createdAt":-1,"metricHistory":null}],"edges":[{"from":null,"to":null,"kind":null,"condition":null,"fired":null,"fireCount":-1}]}
    ;
    var graph = try decodeSubgraph(allocator, .{ .path = &.{}, .name = &.{} }, json);
    defer freeGraph(allocator, &graph);
    try std.testing.expectEqual(@as(usize, 1), graph.nodes.items.len);
    const node = graph.nodes.items[0];
    try std.testing.expectEqualStrings("", node.id);
    try std.testing.expectEqualStrings("Untitled", node.title);
    try std.testing.expectEqualStrings("idle", node.state);
    try std.testing.expectEqualStrings("", node.presence);
    try std.testing.expectEqualStrings("", node.worktree_path);
    try std.testing.expectEqualStrings("", node.goal_summary);
    try std.testing.expectEqual(@as(?u64, null), node.created_at);
    try std.testing.expectEqual(@as(?u32, null), node.token_usage);
    try std.testing.expect(!node.follows_template);
    try std.testing.expectEqual(@as(usize, 1), graph.edges.items.len);
    try std.testing.expectEqualStrings("always", graph.edges.items[0].condition);
    try std.testing.expectEqualStrings("handoff", graph.edges.items[0].kind);
    try std.testing.expect(graph.edges.items[0].blocks_target and !graph.edges.items[0].fired);
    try std.testing.expectEqual(@as(i64, -1), graph.edges.items[0].fire_count);
    for ([_][]const u8{ "{\"edges\":[false]}", "{\"edges\":[[{\"id\":\"not-immediate\"}]]}" }) |invalid| {
        try std.testing.expectError(error.MalformedEdge, decodeSubgraph(allocator, graph.project, invalid));
    }
}

fn checkScopeDecoder(allocator: std.mem.Allocator) !void {
    var model = Model.init(allocator);
    defer model.deinit();
    {
        const frame = try allocator.dupe(u8, scopeFrame);
        defer allocator.free(frame);
        try model.decodeGraph(frame);
    }
    try std.testing.expectEqualStrings("root-project", model.graph.?.project.path);
    try std.testing.expectEqualStrings("root-edge", model.graph.?.edges.items[0].id);
    try std.testing.expectEqualStrings("root-edge", model.graphs.items[0].edges.items[0].id);
    var nested = try decodeSubgraph(allocator, model.graph.?.project, model.graph.?.nodes.items[0].subgraph_json);
    defer freeGraph(allocator, &nested);
    try std.testing.expectEqualStrings("child-edge", nested.edges.items[0].id);
    try std.testing.expectEqualStrings("child-a", nested.nodes.items[0].id);
}

test "field scope owned strings survive temporary input and every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkScopeDecoder, .{});
}

test "field scope populated model replacements retain the parent transaction guarantee" {
    const allocator = std.testing.allocator;
    const failed_frame = try std.mem.replaceOwned(u8, allocator, ownershipGraphFrame, "\"state\":\"running\"", "\"state\":\"failed\"");
    defer allocator.free(failed_frame);
    var before = try initOwnershipModel(allocator, failed_frame, false);
    defer before.deinit();
    var after = try initOwnershipModel(allocator, failed_frame, false);
    defer after.deinit();
    try after.decodeGraph(scopeFrame);
    const summary = after.graphFor("root-project") orelse return error.TestExpectedGraph;
    try std.testing.expectEqualStrings("root-edge", summary.edges.items[0].id);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkModelReplacementOwnership, .{ failed_frame, scopeFrame, false, &before, &after });
}

test "field scope canonical fields and supported legacy fallbacks have explicit precedence" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        canonical: []const u8,
        metric: []const u8,
        poll: ?f64,
        usage: ?u32,
    }{
        .{ .canonical = "", .metric = "legacy", .poll = 9, .usage = 11 },
        .{ .canonical = ",\"goal\":{},\"usage\":{}", .metric = "legacy", .poll = 9, .usage = null },
        .{ .canonical = ",\"goal\":null,\"usage\":null", .metric = "", .poll = null, .usage = null },
        .{ .canonical = ",\"goal\":false,\"usage\":[]", .metric = "", .poll = null, .usage = null },
        .{ .canonical = ",\"goal\":{\"metricCommand\":\"canonical\",\"pollIntervalSeconds\":3},\"usage\":{\"inputTokens\":5,\"outputTokens\":6}", .metric = "canonical", .poll = 3, .usage = 11 },
        .{ .canonical = ",\"goal\":{\"metricCommand\":null,\"pollIntervalSeconds\":null},\"usage\":{\"inputTokens\":null,\"outputTokens\":null}", .metric = "", .poll = null, .usage = null },
        .{ .canonical = ",\"goal\":{\"metricCommand\":{},\"pollIntervalSeconds\":\"3\"},\"usage\":{\"inputTokens\":{},\"outputTokens\":false}", .metric = "", .poll = null, .usage = null },
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |canonical_first| {
            const legacy = "\"metricCommand\":\"legacy\",\"pollIntervalSeconds\":9,\"inputTokens\":11";
            const json = if (canonical_first and case.canonical.len != 0)
                try std.fmt.allocPrint(allocator, "{{\"nodes\":[{{{s},{s}}}]}}", .{ case.canonical[1..], legacy })
            else
                try std.fmt.allocPrint(allocator, "{{\"nodes\":[{{{s}{s}}}]}}", .{ legacy, case.canonical });
            defer allocator.free(json);
            var graph = try decodeSubgraph(allocator, .{ .path = &.{}, .name = &.{} }, json);
            defer freeGraph(allocator, &graph);
            const node = graph.nodes.items[0];
            try std.testing.expectEqualStrings(case.metric, node.metric_command);
            try std.testing.expectEqual(case.poll, node.poll_interval_seconds);
            try std.testing.expectEqual(case.usage, node.token_usage);
        }
    }
    const aliases =
        \\{"nodes":[{"worktreeBinding":{"path":"preferred","worktreePath":"alias"}},{"worktreeBinding":{"path":null,"worktreePath":"alias"}},{"worktreeBinding":{"path":false,"worktreePath":"alias"}},{"presence":"busy"},{"usage":{"inputTokens":null,"inputTokenCount":2,"outputTokens":3}},{"createdAt":12.5}],"edges":[{"fireCount":1}]}
    ;
    var graph = try decodeSubgraph(allocator, .{ .path = &.{}, .name = &.{} }, aliases);
    defer freeGraph(allocator, &graph);
    try std.testing.expectEqualStrings("preferred", graph.nodes.items[0].worktree_path);
    try std.testing.expectEqualStrings("alias", graph.nodes.items[1].worktree_path);
    try std.testing.expectEqualStrings("alias", graph.nodes.items[2].worktree_path);
    try std.testing.expectEqualStrings("busy", graph.nodes.items[3].presence);
    try std.testing.expectEqual(@as(?u32, 5), graph.nodes.items[4].token_usage);
    try std.testing.expectEqual(@as(?u64, 978_307_212), graph.nodes.items[5].created_at);
    try std.testing.expectEqual(@as(i64, 1), graph.edges.items[0].fire_count);
    try std.testing.expectError(error.MalformedEdge, decodeSubgraph(allocator, graph.project, "{\"edges\":[{\"fireCount\":1e2}]}"));
}

test "node createdAt converts daemon reference-date seconds to Unix seconds" {
    const allocator = std.testing.allocator;
    const json =
        \\{"nodes":[{"createdAt":812912680.0330639},{"createdAt":0},{"createdAt":-978307200},{"createdAt":-1},{"createdAt":1e300},{"createdAt":"812912680"},{"createdAt":null}],"edges":[]}
    ;
    var graph = try decodeSubgraph(allocator, .{ .path = &.{}, .name = &.{} }, json);
    defer freeGraph(allocator, &graph);
    try std.testing.expectEqual(@as(usize, 7), graph.nodes.items.len);
    // 812912680.03s after 2001-01-01T00:00:00Z is 2026-10-05T15:04:40Z.
    try std.testing.expectEqual(@as(?u64, 1_791_219_880), graph.nodes.items[0].created_at);
    // The reference date itself is the starter-template placeholder; it and
    // earlier, out-of-range, and non-numeric values have no meaningful age.
    for (graph.nodes.items[1..]) |node| try std.testing.expectEqual(@as(?u64, null), node.created_at);
}

fn checkScopeMalformed(allocator: std.mem.Allocator, json: []const u8, expected: anyerror, before: *const Model) !void {
    var model = Model.init(allocator);
    defer model.deinit();
    try model.decodeGraph(ownershipGraphFrame);
    const frame = try std.fmt.allocPrint(allocator, "{{\"graphChanged\":{s}}}", .{json});
    defer allocator.free(frame);
    model.decodeGraph(frame) catch |err| {
        try expectModelDataEqual(before, &model);
        if (err != expected) return err;
        return;
    };
    return error.TestExpectedError;
}

test "field scope malformed syntax and strings keep meaningful errors and old model data" {
    const cases = [_]struct { json: []const u8, graph_error: anyerror, subgraph_error: anyerror }{
        .{ .json = "{\"nodes\":[}", .graph_error = error.MalformedGraph, .subgraph_error = error.MalformedSubgraph },
        .{ .json = "{\"nodes\":[{\"id\":\"x\"}]", .graph_error = error.MalformedGraph, .subgraph_error = error.MalformedSubgraph },
        .{ .json = "{\"nodes\":[{},]}", .graph_error = error.MalformedGraph, .subgraph_error = error.MalformedSubgraph },
        .{ .json = "{\"nodes\" []}", .graph_error = error.MalformedGraph, .subgraph_error = error.MalformedSubgraph },
        .{ .json = "{\"nodes\":nil}", .graph_error = error.MalformedGraph, .subgraph_error = error.MalformedSubgraph },
        .{ .json = "{\"metadata\":{\"broken\":},\"nodes\":[]}", .graph_error = error.MalformedGraph, .subgraph_error = error.MalformedSubgraph },
        .{ .json = "{\"nodes\":[{\"createdAt\":01}]}", .graph_error = error.MalformedGraph, .subgraph_error = error.MalformedSubgraph },
        .{ .json = "{\"nodes\":[{\"title\":\"bad\\q\"}]}", .graph_error = error.MalformedJsonString, .subgraph_error = error.MalformedJsonString },
        .{ .json = "{\"nodes\":[{\"goal\":{\"metricCommand\":\"bad\\q\"},\"metricCommand\":\"legacy\"}]}", .graph_error = error.MalformedJsonString, .subgraph_error = error.MalformedJsonString },
        .{ .json = "{\"nodes\":[{\"worktreeBinding\":{\"path\":\"bad\\q\",\"worktreePath\":\"alias\"}}]}", .graph_error = error.MalformedJsonString, .subgraph_error = error.MalformedJsonString },
        .{ .json = "{\"nodes\":[{\"title\":\"\\uD800\"}]}", .graph_error = error.MalformedJsonString, .subgraph_error = error.MalformedJsonString },
        .{ .json = "{\"no\\qdes\":[]}", .graph_error = error.MalformedJsonString, .subgraph_error = error.MalformedJsonString },
    };
    var before = Model.init(std.testing.allocator);
    defer before.deinit();
    try before.decodeGraph(ownershipGraphFrame);
    for (cases) |case| {
        try checkScopeMalformed(std.testing.allocator, case.json, case.graph_error, &before);
        try std.testing.checkAllAllocationFailures(std.testing.allocator, checkScopeMalformed, .{ case.json, case.graph_error, &before });
        try std.testing.checkAllAllocationFailures(std.testing.allocator, checkMalformedSubgraphOwnership, .{ case.json, case.subgraph_error });
    }
}

test "field scope missing graph null graph and empty subgraph retain existing contracts" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try model.decodeGraph(ownershipGraphFrame);
    for ([_][]const u8{ "{}", "{\"graphChanged\":null}", "{\"event\":{\"graphChanged\":null}}", "{\"metadata\":" ++ scopeFrame ++ "}" }) |frame| {
        try model.decodeGraph(frame);
        try expectOwnershipGraph(model.graph.?);
    }
    for ([_][]const u8{ "", "null", "{}" }) |json| {
        var graph = try decodeSubgraph(std.testing.allocator, .{ .path = @constCast("parent"), .name = @constCast("Parent") }, json);
        defer freeGraph(std.testing.allocator, &graph);
        try std.testing.expectEqualStrings("parent", graph.project.path);
        try std.testing.expectEqual(@as(usize, 0), graph.nodes.items.len);
        try std.testing.expectEqual(@as(usize, 0), graph.edges.items.len);
    }
}

fn checkScopeFields(allocator: std.mem.Allocator, json: []const u8) !void {
    try validateGraphStructure(allocator, json);
    var fields = try JsonFields.init(allocator, json);
    defer fields.deinit();
    try std.testing.expect(fields.get("nodes").container('[') != null);
    try std.testing.expectEqualStrings(scopeEdges, fields.get("edges").raw);
}

test "field scope helper handles escaped keys deep nesting and exhaustive allocation failure" {
    const allocator = std.testing.allocator;
    const json = "{\"metadata\":" ++ ("[" ** 300) ++ "{\"nodes\":[]}" ++ ("]" ** 300) ++
        ",\"no\\u0064es\":[[{}],\"{\\\"nodes\\\":[]}\",{\"id\":\"a\"},{\"id\":\"b\"}],\"edges\":" ++ scopeEdges ++ "}";
    try std.testing.expectEqual(@as(usize, 2), subgraphNodeCount(json));
    try std.testing.expectEqual(@as(usize, 0), subgraphNodeCount("{\"metadata\":" ++ scopeGraph ++ "}"));
    try std.testing.checkAllAllocationFailures(allocator, checkScopeFields, .{json});
}

test "field scope root and composite arrays remain independent under nested key permutations" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |child_edges_first| {
        for ([_]bool{ false, true }) |root_edges_first| {
            for ([_]bool{ false, true }) |empty_root| {
                const child = if (child_edges_first)
                    "{\"edges\":[{\"id\":\"child-edge\",\"from\":\"child\",\"to\":\"child\"}],\"nodes\":[{\"id\":\"child\"}]}"
                else
                    "{\"nodes\":[{\"id\":\"child\"}],\"edges\":[{\"id\":\"child-edge\",\"from\":\"child\",\"to\":\"child\"}]}";
                const nodes = if (empty_root)
                    try allocator.dupe(u8, "[]")
                else
                    try std.fmt.allocPrint(allocator, "[{{\"id\":\"root\",\"subGraph\":{s}}}]", .{child});
                defer allocator.free(nodes);
                const root_arrays = if (root_edges_first)
                    try std.fmt.allocPrint(allocator, "\"edges\":{s},\"nodes\":{s}", .{ if (empty_root) "[]" else scopeEdges, nodes })
                else
                    try std.fmt.allocPrint(allocator, "\"nodes\":{s},\"edges\":{s}", .{ nodes, if (empty_root) "[]" else scopeEdges });
                defer allocator.free(root_arrays);
                const json = try std.fmt.allocPrint(allocator, "{{\"metadata\":{s},{s}}}", .{ child, root_arrays });
                defer allocator.free(json);
                var graph = try decodeSubgraph(allocator, .{ .path = &.{}, .name = &.{} }, json);
                defer freeGraph(allocator, &graph);
                try std.testing.expectEqual(@as(usize, if (empty_root) 0 else 1), graph.nodes.items.len);
                try std.testing.expectEqual(@as(usize, if (empty_root) 0 else 1), graph.edges.items.len);
                if (!empty_root) {
                    try std.testing.expectEqualStrings("root", graph.nodes.items[0].id);
                    try std.testing.expectEqualStrings("root-edge", graph.edges.items[0].id);
                }
                try std.testing.expectEqual(graph.nodes.items.len, subgraphNodeCount(json));
                var nested = try decodeSubgraph(allocator, graph.project, if (empty_root) child else graph.nodes.items[0].subgraph_json);
                defer freeGraph(allocator, &nested);
                try std.testing.expectEqualStrings("child-edge", nested.edges.items[0].id);
            }
        }
    }
    const frame =
        \\{"graphChanged":{"project":{"path":"legacy"},"nodes":[]},"event":{"graphChanged":{"pro\u006aect":{"path":"canonical","name":"First","name":"Second"},"no\u0064es":[{"i\u0064":"first","id":"second"}],"e\u0064ges":[]}}}
    ;
    var model = Model.init(allocator);
    defer model.deinit();
    try model.decodeGraph(frame);
    try std.testing.expectEqualStrings("canonical", model.graph.?.project.path);
    try std.testing.expectEqualStrings("First", model.graph.?.project.name);
    try std.testing.expectEqualStrings("first", model.graph.?.nodes.items[0].id);
}

fn traversalFixture(allocator: std.mem.Allocator, depth: usize, width: usize, opaque_subgraph: bool) ![]u8 {
    var json = std.array_list.Managed(u8).init(allocator);
    errdefer json.deinit();
    try json.appendSlice(if (opaque_subgraph) "{\"sub\\u0047raph\":[" else "{\"metadata\":[");
    for (0..width) |branch| {
        if (branch != 0) try json.append(',');
        for (0..depth) |_| try json.appendSlice("{\"nested\":[");
        try json.appendSlice("{\"value\":1,\"text\":\"brace } quote \\\" slash \\\\ \\u2603\"}");
        for (0..depth) |_| try json.appendSlice("]}");
    }
    try json.appendSlice("],\"nodes\":[],\"edges\":[]}");
    return json.toOwnedSlice();
}

test "field scope validator bounds actual traversal work as nesting depth and width grow" {
    var within_bound = true;
    for ([_]usize{ 8, 16, 32, 64 }) |depth| {
        for ([_]usize{ 1, 4, 16 }) |width| {
            for ([_]bool{ false, true }) |opaque_subgraph| {
                const json = try traversalFixture(std.testing.allocator, depth, width, opaque_subgraph);
                defer std.testing.allocator.free(json);
                var work = JsonTraversalWork{};
                try validateGraphStructureMeasured(std.testing.allocator, json, &work);
                std.debug.print("traversal depth={d} width={d} opaque={} bytes={d} span_visits={d} validator_steps={d}\n", .{
                    depth, width, opaque_subgraph, json.len, work.span_byte_visits, work.validator_steps,
                });
                // Count actual span-loop byte visits and validator iterations,
                // not elapsed time or input-size-derived synthetic operations.
                if (work.span_byte_visits > 4 * json.len or work.validator_steps > json.len) within_bound = false;
            }
        }
    }
    try std.testing.expect(within_bound);
}

fn checkTraversalAllocation(allocator: std.mem.Allocator, json: []const u8, expected: ?anyerror) !void {
    var work = JsonTraversalWork{};
    validateGraphStructureMeasured(allocator, json, &work) catch |err| {
        if (expected) |syntax_error| {
            if (err == syntax_error) return;
        }
        return err;
    };
    if (expected != null) return error.TestExpectedError;
    try std.testing.expect(work.span_byte_visits <= 4 * json.len);
    try std.testing.expect(work.validator_steps <= json.len);
}

test "field scope validator single-pass stacks release allocations on success syntax errors and OOM" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |opaque_subgraph| {
        const json = try traversalFixture(allocator, 64, 4, opaque_subgraph);
        defer allocator.free(json);
        try std.testing.checkAllAllocationFailures(allocator, checkTraversalAllocation, .{ json, null });
        const trailing = try std.mem.concat(allocator, u8, &.{ json, " false" });
        defer allocator.free(trailing);
        try std.testing.checkAllAllocationFailures(allocator, checkTraversalAllocation, .{ trailing, error.MalformedJson });
    }
    const malformed = [_][]const u8{
        "{\"metadata\":" ++ ("{\"nested\":[" ** 32) ++ "{}" ++ ("]}" ** 31) ++ "}}",
        "{\"metadata\":" ++ ("{\"nested\":[" ** 32) ++ "{}," ++ ("]}" ** 32) ++ "}",
        "{\"metadata\":" ++ ("{\"nested\":[" ** 32) ++ "{\"value\":nil}" ++ ("]}" ** 32) ++ "}",
        "{\"metadata\":" ++ ("{\"nested\":[" ** 32) ++ "{\"bad\\q\":0}" ++ ("]}" ** 32) ++ "}",
    };
    for (malformed, 0..) |json, index| {
        try std.testing.checkAllAllocationFailures(allocator, checkTraversalAllocation, .{
            json, if (index == 3) error.MalformedJsonString else error.MalformedJson,
        });
    }
}

fn traversalWideFixture(allocator: std.mem.Allocator, width: usize, opaque_subgraph: bool) ![]u8 {
    var json = std.array_list.Managed(u8).init(allocator);
    errdefer json.deinit();
    try json.appendSlice(if (opaque_subgraph) "{\"subGraph\":{" else "{\"metadata\":{");
    const values = [_][]const u8{ "null", "true", "123", "\"brace } quote \\\" slash \\\\ \\u2603\"", "{\"n\":1}", "[0,1]" };
    for (0..width) |index| {
        if (index != 0) try json.append(',');
        try json.writer().print("\"field{d}\":{s}", .{ index, values[index % values.len] });
    }
    try json.appendSlice("},\"nodes\":[],\"edges\":[]}");
    return json.toOwnedSlice();
}

test "field scope validator bounds wide objects and opaque child spans" {
    for ([_]usize{ 16, 64, 256, 1024 }) |width| {
        for ([_]bool{ false, true }) |opaque_subgraph| {
            const json = try traversalWideFixture(std.testing.allocator, width, opaque_subgraph);
            defer std.testing.allocator.free(json);
            var work = JsonTraversalWork{};
            try validateGraphStructureMeasured(std.testing.allocator, json, &work);
            std.debug.print("wide width={d} opaque={} bytes={d} span_visits={d} validator_steps={d}\n", .{
                width, opaque_subgraph, json.len, work.span_byte_visits, work.validator_steps,
            });
            try std.testing.expect(work.span_byte_visits <= 4 * json.len);
            try std.testing.expect(work.validator_steps <= json.len);
            try std.testing.checkAllAllocationFailures(std.testing.allocator, checkTraversalAllocation, .{ json, null });
        }
    }
}

test "field scope sketch first instruction stays owned without metadata or child inheritance" {
    const Probe = struct {
        fn run(allocator: std.mem.Allocator, instruction: []const u8, expected: []const u8) !void {
            var model = Model.init(allocator);
            defer model.deinit();
            {
                const frame = try std.mem.concat(allocator, u8, &.{
                    "{\"graphChanged\":{\"project\":{\"path\":\"scope\",\"name\":\"Scope\"},\"nodes\":[{\"metadata\":{\"firstInstruction\":\"metadata\"},\"subGraph\":{\"nodes\":[{\"id\":\"child\",\"firstInstruction\":\"child note\"}],\"edges\":[]},\"id\":\"parent\",\"loopType\":\"sketch\"",
                    instruction,
                    "}],\"edges\":[]}}",
                });
                defer allocator.free(frame);
                try model.decodeGraph(frame);
            }
            const node = model.graph.?.nodes.items[0];
            try std.testing.expectEqualStrings(expected, node.first_instruction);
            try std.testing.expectEqualStrings(expected, model.graphs.items[0].nodes.items[0].first_instruction);
            const copy = try cloneNode(allocator, node);
            defer freeNode(allocator, copy);
            try std.testing.expectEqualStrings(expected, copy.first_instruction);
            var child = try decodeSubgraph(allocator, model.graph.?.project, node.subgraph_json);
            defer freeGraph(allocator, &child);
            try std.testing.expectEqualStrings("child note", child.nodes.items[0].first_instruction);
        }
    };
    const cases = [_]struct { field: []const u8, expected: []const u8 }{
        .{ .field = "", .expected = "" },
        .{ .field = ",\"firstInstruction\":null", .expected = "" },
        .{ .field = ",\"firstInstruction\":{}", .expected = "" },
        .{ .field = ",\"firstInstruction\":\"own \\u96ea \\\"note\\\"\"", .expected = "own \xe9\x9b\xaa \"note\"" },
        .{ .field = ",\"first\\u0049nstruction\":\"escaped key\"", .expected = "escaped key" },
    };
    for (cases) |case| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{ case.field, case.expected });
    }
}

const ownershipGraphJson =
    \\{"project":{"path":"C:\\owned\\graph","name":"Owned \"graph\""},
    \\"edges":[{"id":"edge-first","from":"first","to":"second","kind":"handoff","condition":"onSuccess","fired":true,"fireCount":2,"cycleGuard":{"maxIterations":5,"until":"done","stopAfterPassesWithoutImprovement":3},"payloadTransform":{"template":{"_0":" \u2603 text "}},"spawnTargetProjectPath":""},{"id":"edge-second","from":"second","to":"first","kind":"message","fireCount":-2,"payloadTransform":{"script":{"_0":"command"}},"spawnTargetProjectPath":"C:\\spawn"}],
    \\"nodes":[{"id":"first","title":"First \"node\"","loopType":"proactive","state":"running","activity":"editing","presence":{"presence":"busy"},"backend":"copilot","pilotState":"piloted","goal":{"summary":"Ship it","predicate":"done"},"metricCommand":"measure","metricDirection":"decrease","triggerPrompt":"Continue","firstInstruction":"Owned \"note\" \u96ea","checkDescription":"Check","modelTier":"high","pollIntervalSeconds":12.5,"stallAfterSeconds":60,"createdAt":123,"metricHistory":[{"value":3},{"value":2}],"inputTokens":11,"outputTokens":7,"worktreeBinding":{"path":"C:\\owned\\branch","branch":"topic"},"subGraph":{"nodes":[{"id":"child","title":"Child","state":"idle"}],"edges":[]},"templateFollow":{"id":"template"}},{"id":"second","title":"Second","state":"idle"}]}
;
const ownershipGraphFrame = "{\"graphChanged\":" ++ ownershipGraphJson ++ "}";

fn checkOwnershipAllocationFailures(comptime test_fn: anytype, extra_args: anytype) !void {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try @call(.auto, test_fn, .{counting.allocator()} ++ extra_args);
    std.debug.print("allocation positions: {d}\n", .{counting.alloc_index});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, test_fn, extra_args);
}

fn expectOwnershipGraph(graph: anytype) !void {
    try std.testing.expectEqualStrings("C:\\owned\\graph", graph.project.path);
    try std.testing.expectEqualStrings("Owned \"graph\"", graph.project.name);
    try std.testing.expectEqual(@as(usize, 2), graph.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 2), graph.edges.items.len);
    const node = graph.nodes.items[0];
    try std.testing.expectEqualStrings("first", node.id);
    try std.testing.expectEqualStrings("First \"node\"", node.title);
    try std.testing.expectEqualStrings("proactive", node.loop_type);
    try std.testing.expectEqualStrings("running", node.state);
    try std.testing.expectEqualStrings("editing", node.activity);
    try std.testing.expectEqualStrings("busy", node.presence);
    try std.testing.expectEqualStrings("copilot", node.backend);
    try std.testing.expectEqualStrings("piloted", node.pilot_state);
    try std.testing.expectEqualStrings("Ship it", node.goal_summary);
    try std.testing.expectEqualStrings("done", node.goal_predicate);
    try std.testing.expectEqualStrings("measure", node.metric_command);
    try std.testing.expectEqualStrings("decrease", node.metric_direction);
    try std.testing.expectEqualStrings("Continue", node.trigger_prompt);
    try std.testing.expectEqualStrings("Owned \"note\" \u{96ea}", node.first_instruction);
    try std.testing.expectEqualStrings("Check", node.check_description);
    try std.testing.expectEqualStrings("high", node.model_tier);
    try std.testing.expectEqual(@as(?f64, 12.5), node.poll_interval_seconds);
    try std.testing.expectEqual(@as(?f64, 60), node.stall_after_seconds);
    try std.testing.expectEqual(@as(?u64, 978_307_323), node.created_at);
    try std.testing.expectEqual(@as(u32, 2), node.metric_passes);
    try std.testing.expectEqual(@as(u8, 2), node.metric_sample_count);
    try std.testing.expectEqual(@as(f64, 3), node.metric_samples[0]);
    try std.testing.expectEqual(@as(f64, 2), node.metric_samples[1]);
    try std.testing.expectEqual(@as(?u32, 18), node.token_usage);
    try std.testing.expectEqualStrings("C:\\owned\\branch", node.worktree_path);
    try std.testing.expectEqualStrings("topic", node.worktree_branch);
    try std.testing.expectEqual(@as(usize, 1), subgraphNodeCount(node.subgraph_json));
    try std.testing.expect(node.follows_template);
    try std.testing.expectEqualStrings("second", graph.nodes.items[1].id);
    try std.testing.expectEqualStrings("turnBased", graph.nodes.items[1].loop_type);
    try std.testing.expectEqualStrings("notPiloted", graph.nodes.items[1].pilot_state);
    const edge = graph.edges.items[0];
    try std.testing.expectEqualStrings("edge-first", edge.id);
    try std.testing.expectEqualStrings("first", edge.from);
    try std.testing.expectEqualStrings("second", edge.to);
    try std.testing.expectEqualStrings("handoff", edge.kind);
    try std.testing.expectEqualStrings("onSuccess", edge.condition);
    try std.testing.expect(edge.blocks_target and edge.fired);
    try std.testing.expectEqual(@as(i64, 2), edge.fire_count);
    try std.testing.expectEqual(@as(?i64, 5), edge.cycle_guard.?.max_iterations);
    try std.testing.expectEqualStrings("done", edge.cycle_guard.?.until.?);
    try std.testing.expectEqual(@as(?i64, 3), edge.cycle_guard.?.stop_after_passes_without_improvement);
    try std.testing.expectEqualStrings(" \xe2\x98\x83 text ", edge.payload_transform.template);
    try std.testing.expectEqualStrings("", edge.spawn_target_project_path.?);
    try std.testing.expect(edge.editable_configuration);
    try std.testing.expectEqualStrings("edge-second", graph.edges.items[1].id);
    try std.testing.expectEqualStrings("always", graph.edges.items[1].condition);
    try std.testing.expect(!graph.edges.items[1].blocks_target);
    try std.testing.expectEqual(@as(i64, -2), graph.edges.items[1].fire_count);
    try std.testing.expect(!graph.edges.items[1].fired);
    try std.testing.expectEqualStrings("command", graph.edges.items[1].payload_transform.script);
    try std.testing.expectEqualStrings("C:\\spawn", graph.edges.items[1].spawn_target_project_path.?);
}

fn checkGraphDecoderOwnership(allocator: std.mem.Allocator) !void {
    var model = Model.init(allocator);
    defer model.deinit();
    {
        const frame = try allocator.dupe(u8, ownershipGraphFrame);
        defer allocator.free(frame);
        try model.decodeGraph(frame);
    }
    try expectOwnershipGraph(model.graph orelse return error.TestExpectedGraph);
    try expectOwnershipGraph(model.graphs.items[0]);
}

test "decoder ownership actual graph allocation failures" {
    try checkOwnershipAllocationFailures(checkGraphDecoderOwnership, .{});
}

fn checkSubgraphDecoderOwnership(allocator: std.mem.Allocator) !void {
    var graph = graph: {
        const json = try allocator.dupe(u8, ownershipGraphJson);
        defer allocator.free(json);
        break :graph try decodeSubgraph(allocator, .{
            .path = @constCast("C:\\owned\\graph"),
            .name = @constCast("Owned \"graph\""),
        }, json);
    };
    defer freeGraph(allocator, &graph);
    try expectOwnershipGraph(graph);
}

test "decoder ownership subgraph allocation failures" {
    try checkOwnershipAllocationFailures(checkSubgraphDecoderOwnership, .{});
}

fn checkCloneOwnership(allocator: std.mem.Allocator, source: *const Graph) !void {
    const project = try cloneProject(allocator, source.project);
    defer freeProject(allocator, project);
    try std.testing.expectEqualStrings(source.project.path, project.path);
    try std.testing.expectEqualStrings(source.project.name, project.name);
    for (source.nodes.items) |node| {
        const copy = try cloneNode(allocator, node);
        defer freeNode(allocator, copy);
        inline for (@typeInfo(Node).@"struct".fields) |field| {
            try std.testing.expectEqualDeep(@field(node, field.name), @field(copy, field.name));
        }
    }
    for (source.edges.items) |edge| {
        const copy = try cloneEdge(allocator, edge);
        defer freeEdge(allocator, copy);
        inline for (@typeInfo(Edge).@"struct".fields) |field| {
            try std.testing.expectEqualDeep(@field(edge, field.name), @field(copy, field.name));
        }
    }
}

test "decoder ownership cloning preserves all fields at every allocation failure" {
    var source = try decodeSubgraph(std.testing.allocator, .{
        .path = @constCast("C:\\owned\\graph"),
        .name = @constCast("Owned \"graph\""),
    }, ownershipGraphJson);
    defer freeGraph(std.testing.allocator, &source);
    try checkOwnershipAllocationFailures(checkCloneOwnership, .{&source});
}

fn checkSummaryReplacementOwnership(allocator: std.mem.Allocator, source: *const Graph) !void {
    var model = Model.init(allocator);
    defer model.deinit();
    try model.upsertSummary(source);
    const old_nodes = model.graphs.items[0].nodes.items.ptr;
    const old_edges = model.graphs.items[0].edges.items.ptr;
    model.upsertSummary(source) catch |err| {
        try std.testing.expect(old_nodes == model.graphs.items[0].nodes.items.ptr);
        try std.testing.expect(old_edges == model.graphs.items[0].edges.items.ptr);
        try expectOwnershipGraph(model.graphs.items[0]);
        return err;
    };
    try expectOwnershipGraph(model.graphs.items[0]);
}

test "decoder ownership summary replacement retains old arrays until copies are owned" {
    var source = try decodeSubgraph(std.testing.allocator, .{
        .path = @constCast("C:\\owned\\graph"),
        .name = @constCast("Owned \"graph\""),
    }, ownershipGraphJson);
    defer freeGraph(std.testing.allocator, &source);
    try checkOwnershipAllocationFailures(checkSummaryReplacementOwnership, .{&source});
}

fn checkDecoderListGrowth(allocator: std.mem.Allocator) !void {
    var nodes = std.array_list.Managed(Node).init(allocator);
    defer {
        for (nodes.items) |node| freeNode(allocator, node);
        nodes.deinit();
    }
    var edges = std.array_list.Managed(Edge).init(allocator);
    defer {
        for (edges.items) |edge| freeEdge(allocator, edge);
        edges.deinit();
    }
    try decodeNodes(allocator, "[{\"id\":\"node\"}" ++ (",{\"id\":\"node\"}" ** 9) ++ "]", &nodes);
    edges = try decodeEdges(allocator, "[{\"from\":\"node\",\"to\":\"node\"}" ++ (",{\"from\":\"node\",\"to\":\"node\"}" ** 9) ++ "]");
    try std.testing.expectEqual(@as(usize, 10), nodes.items.len);
    try std.testing.expectEqual(@as(usize, 10), edges.items.len);
    for (nodes.items) |node| try std.testing.expectEqualStrings("Untitled", node.title);
    for (edges.items) |edge| try std.testing.expectEqualStrings("always", edge.condition);
}

test "decoder ownership partial lists and growing appends release every allocation" {
    try checkOwnershipAllocationFailures(checkDecoderListGrowth, .{});
}

fn checkMalformedSubgraphOwnership(allocator: std.mem.Allocator, json: []const u8, expected: anyerror) !void {
    if (decodeSubgraph(allocator, .{ .path = @constCast("parent"), .name = @constCast("Parent") }, json)) |value| {
        var graph = value;
        defer freeGraph(allocator, &graph);
        return error.TestExpectedError;
    } else |err| {
        if (err != expected) return err;
    }
}

test "decoder ownership malformed subgraphs preserve primary errors under allocation failure" {
    const malformed_strings = [_][]const u8{
        \\{"nodes":[{"id":"valid"},{"id":"next","title":"bad\q"}]}
        ,
        \\{"nodes":[{"id":"valid"},{"id":"next","worktreeBinding":{"path":"owned","branch":"bad\q"}}]}
        ,
        \\{"nodes":[{"id":"valid"}],"edges":[{"id":"valid","from":"valid","to":"valid"},{"id":"next","from":"valid","to":"valid","condition":"bad\q"}]}
        ,
    };
    const string_errors = [_]anyerror{ error.MalformedJsonString, error.MalformedJsonString, error.SyntaxError };
    for (malformed_strings, string_errors) |json, expected| {
        try checkOwnershipAllocationFailures(checkMalformedSubgraphOwnership, .{ json, expected });
    }
    const malformed_arrays = [_][]const u8{
        \\{"nodes":[
        ,
        \\{"nodes":[{"id":"valid"}],"edges":[
        ,
    };
    for (malformed_arrays) |json| {
        try checkOwnershipAllocationFailures(checkMalformedSubgraphOwnership, .{ json, error.MalformedSubgraph });
    }
}

test "decoder ownership decoded data outlives temporary JSON storage" {
    const allocator = std.testing.allocator;
    var graph = graph: {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, ownershipGraphJson, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const project = parsed.value.object.get("project").?.object;
        const json = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
        defer allocator.free(json);
        break :graph try decodeSubgraph(allocator, .{
            .path = @constCast(project.get("path").?.string),
            .name = @constCast(project.get("name").?.string),
        }, json);
    };
    defer freeGraph(allocator, &graph);
    try expectOwnershipGraph(graph);
}

test "decoder ownership malformed strings preserve the previous graph" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try model.decodeGraph(ownershipGraphFrame);
    const invalid_frames = [_][]const u8{
        \\{"graphChanged":{"project":{"path":"C:\\owned\\graph","name":"bad\q"},"nodes":[],"edges":[]}}
        ,
        \\{"graphChanged":{"project":{"path":"C:\\owned\\graph","name":"Changed"},"nodes":[{"id":"valid"},{"id":"invalid","title":"bad\q"}],"edges":[]}}
        ,
        \\{"graphChanged":{"project":{"path":"C:\\owned\\graph","name":"Changed"},"nodes":[{"id":"valid"}],"edges":[{"id":"valid","from":"valid","to":"valid"},{"id":"invalid","from":"valid","to":"valid","condition":"bad\q"}]}}
        ,
    };
    const string_errors = [_]anyerror{ error.MalformedJsonString, error.MalformedJsonString, error.SyntaxError };
    for (invalid_frames, string_errors) |frame, expected| {
        try std.testing.expectError(expected, model.decodeGraph(frame));
        try expectOwnershipGraph(model.graph.?);
        try expectOwnershipGraph(model.graphs.items[0]);
        try checkOwnershipAllocationFailures(checkMalformedGraphDecoderOwnership, .{ frame, expected });
    }

    try std.testing.expectError(error.MalformedGraph, model.decodeGraph("{\"graphChanged\":{"));
    try expectOwnershipGraph(model.graph.?);
}

fn checkMalformedGraphDecoderOwnership(allocator: std.mem.Allocator, frame: []const u8, expected: anyerror) !void {
    var model = Model.init(allocator);
    defer model.deinit();
    model.decodeGraph(frame) catch |err| {
        if (err != expected) return err;
        try std.testing.expect(model.graph == null);
        try std.testing.expectEqual(@as(usize, 0), model.graphs.items.len);
        return;
    };
    return error.TestExpectedError;
}

const ownershipOtherFrame =
    \\{"graphChanged":{"project":{"path":"other","name":"Other"},"nodes":[{"id":"other-node","title":"Other node","state":"failed"}],"edges":[]}}
;
const ownershipReplacementFrame =
    \\{"graphChanged":{"project":{"path":"C:\\owned\\graph","name":"Ignored rename"},"edges":[{"id":"replacement-edge","from":"second","to":"first","kind":"message"}],"nodes":[{"id":"first","title":"Updated parent","loopType":"proactive","state":"succeeded","subGraph":{"nodes":[{"id":"child","title":"Updated child","state":"failed"}],"edges":[]}},{"id":"second","title":"Updated second","state":"failed"}]}}
;
const ownershipMalformedCompositeFrame =
    \\{"graphChanged":{"project":{"path":"C:\\owned\\graph","name":"Ignored rename"},"edges":[],"nodes":[{"id":"first","title":"Updated","loopType":"proactive","subGraph":{"nodes":[{"id":"child","title":"bad\q"}],"edges":[]}}]}}
;
const ownershipMalformedCompositeEdgeFrames = [_][]const u8{
    \\{"graphChanged":{"project":{"path":"C:\\owned\\graph","name":"Ignored rename"},"edges":[],"nodes":[{"id":"first","title":"Updated","loopType":"proactive","subGraph":{"nodes":[{"id":"child"}],"edges":[{"from":"child","to":"child","condition":"bad\q"}]}}]}}
    ,
    \\{"graphChanged":{"project":{"path":"C:\\owned\\graph","name":"Ignored rename"},"edges":[],"nodes":[{"id":"first","title":"Updated","loopType":"proactive","subGraph":{"nodes":[{"id":"child"}],"edges":[{"from":"child","to":"child","cycleGuard":{"maxIterations":"bad"}}]}}]}}
    ,
    \\{"graphChanged":{"project":{"path":"C:\\owned\\graph","name":"Ignored rename"},"edges":[],"nodes":[{"id":"first","title":"Updated","loopType":"proactive","subGraph":{"nodes":[{"id":"child"}],"edges":[{"from":"child","to":"child","id":"first","id":"duplicate"}]}}]}}
    ,
};
const ownershipOtherReplacementFrame =
    \\{"graphChanged":{"project":{"path":"other","name":"Ignored rename"},"nodes":[{"id":"other-node","title":"Changed other","state":"succeeded"}],"edges":[]}}
;
const ownershipNewProjectFrame =
    \\{"graphChanged":{"project":{"path":"new","name":"New"},"nodes":[{"id":"new-node","title":"New node","state":"failed"}],"edges":[]}}
;
const ownershipEmptyFrame =
    \\{"graphChanged":{"project":{"path":"C:\\owned\\graph","name":"Ignored rename"},"nodes":[],"edges":[]}}
;

fn initOwnershipModel(allocator: std.mem.Allocator, failed_frame: []const u8, composite: bool) !Model {
    var model = Model.init(allocator);
    errdefer model.deinit();
    try model.decodeGraph(ownershipGraphFrame);
    try model.decodeGraph(failed_frame);
    try model.decodeGraph(ownershipOtherFrame);
    if (composite) {
        model.open_composite_id = try allocator.dupe(u8, "first");
        model.open_composite_title = try allocator.dupe(u8, "First \"node\"");
        try model.decodeGraph(failed_frame);
    }
    model.beginRestore();
    try recordTestNotice(&model, "C:\\owned\\graph", 2147483648);
    try recordTestNotice(&model, "other", 4294967296);
    return model;
}

fn expectGraphDataEqual(expected: anytype, actual: anytype) !void {
    try std.testing.expectEqualDeep(expected.project, actual.project);
    try std.testing.expectEqualDeep(expected.nodes.items, actual.nodes.items);
    try std.testing.expectEqualDeep(expected.edges.items, actual.edges.items);
}

fn expectModelDataEqual(expected: *const Model, actual: *const Model) !void {
    try std.testing.expectEqualDeep(expected.selected_project_path, actual.selected_project_path);
    try std.testing.expectEqualDeep(expected.selected_node_id, actual.selected_node_id);
    try std.testing.expectEqual(expected.selected_index, actual.selected_index);
    try std.testing.expectEqualDeep(expected.open_composite_id, actual.open_composite_id);
    try std.testing.expectEqualDeep(expected.open_composite_title, actual.open_composite_title);
    try std.testing.expectEqual(expected.last_sequence, actual.last_sequence);
    try std.testing.expectEqual(expected.restore_state, actual.restore_state);
    try std.testing.expectEqual(expected.restore_generation, actual.restore_generation);
    try std.testing.expectEqualDeep(expected.graph_generations.items, actual.graph_generations.items);
    try std.testing.expectEqualDeep(expected.recent_projects.items, actual.recent_projects.items);
    try std.testing.expectEqualDeep(expected.open_projects.items, actual.open_projects.items);
    try std.testing.expectEqualDeep(expected.quick_chats.items, actual.quick_chats.items);
    try std.testing.expectEqualDeep(expected.attention.items, actual.attention.items);
    try std.testing.expectEqualDeep(expected.attention_entries.items, actual.attention_entries.items);
    try std.testing.expectEqual(expected.graphs.items.len, actual.graphs.items.len);
    for (expected.graphs.items, actual.graphs.items) |left, right| {
        try expectGraphDataEqual(left, right);
        try std.testing.expectEqualDeep(left.worktree_notice, right.worktree_notice);
    }
    try std.testing.expectEqual(expected.graph == null, actual.graph == null);
    if (expected.graph) |graph| try expectGraphDataEqual(graph, actual.graph.?);
    try std.testing.expectEqual(expected.activity.items.len, actual.activity.items.len);
    for (expected.activity.items, actual.activity.items) |left, right| {
        try std.testing.expectEqualStrings(left.title, right.title);
        try std.testing.expectEqualStrings(left.state, right.state);
        try std.testing.expectEqualStrings(left.project_path, right.project_path);
        try std.testing.expectEqualStrings(left.node_id, right.node_id);
    }
    if (actual.graph) |graph| {
        try std.testing.expectEqualStrings(actual.selected_project_path.?, graph.project.path);
        try std.testing.expect(actual.currentGraph() != null);
    }
}

fn checkModelReplacementOwnership(
    allocator: std.mem.Allocator,
    failed_frame: []const u8,
    frame: []const u8,
    composite: bool,
    before: *const Model,
    after: *const Model,
) !void {
    var model = try initOwnershipModel(allocator, failed_frame, composite);
    defer model.deinit();
    const old_nodes = model.graph.?.nodes.items.ptr;
    const old_summary_nodes = model.graphs.items[0].nodes.items.ptr;
    const old_selection = model.selected_node_id.?.ptr;
    const old_timestamp = model.activity.items[0].timestamp;
    model.decodeGraph(frame) catch |err| {
        try expectModelDataEqual(before, &model);
        try std.testing.expect(old_nodes == model.graph.?.nodes.items.ptr);
        try std.testing.expect(old_summary_nodes == model.graphs.items[0].nodes.items.ptr);
        try std.testing.expect(old_selection == model.selected_node_id.?.ptr);
        try std.testing.expectEqual(old_timestamp, model.activity.items[0].timestamp);
        return err;
    };
    try expectModelDataEqual(after, &model);
}

test "decoder ownership populated model replacements preserve coherent state at every allocation failure" {
    const allocator = std.testing.allocator;
    const failed_frame = try std.mem.replaceOwned(u8, allocator, ownershipGraphFrame, "\"state\":\"running\"", "\"state\":\"failed\"");
    defer allocator.free(failed_frame);
    const cases = [_]struct { frame: []const u8, composite: bool = false }{
        .{ .frame = ownershipReplacementFrame },
        .{ .frame = ownershipOtherReplacementFrame },
        .{ .frame = ownershipNewProjectFrame },
        .{ .frame = ownershipReplacementFrame, .composite = true },
        .{ .frame = ownershipMalformedCompositeFrame, .composite = true },
        .{ .frame = ownershipMalformedCompositeEdgeFrames[0], .composite = true },
        .{ .frame = ownershipMalformedCompositeEdgeFrames[1], .composite = true },
        .{ .frame = ownershipMalformedCompositeEdgeFrames[2], .composite = true },
        .{ .frame = ownershipEmptyFrame },
    };
    for (cases) |case| {
        var before = try initOwnershipModel(allocator, failed_frame, case.composite);
        defer before.deinit();
        var after = try initOwnershipModel(allocator, failed_frame, case.composite);
        defer after.deinit();
        try after.decodeGraph(case.frame);
        try checkOwnershipAllocationFailures(checkModelReplacementOwnership, .{ failed_frame, case.frame, case.composite, &before, &after });
    }
}

test "decoder ownership malformed open subgraph retains the existing top level fallback" {
    for ([_][]const u8{ownershipMalformedCompositeFrame} ++ ownershipMalformedCompositeEdgeFrames) |frame| {
        var model = Model.init(std.testing.allocator);
        defer model.deinit();
        try model.decodeGraph(ownershipGraphFrame);
        try std.testing.expect(model.openComposite("first"));
        try model.decodeGraph(frame);
        try std.testing.expect(!model.isCompositeOpen());
        try std.testing.expectEqualStrings("first", model.graph.?.nodes.items[0].id);
        try std.testing.expectEqualStrings("Owned \"graph\"", model.graph.?.project.name);
    }
}

test "decoder ownership best effort synchronization never retains a different project on allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var model = Model.init(allocator);
    defer model.deinit();
    try model.decodeGraph(ownershipGraphFrame);
    try model.decodeGraph(ownershipOtherFrame);
    const path = try allocator.dupe(u8, "other");
    allocator.free(model.selected_project_path.?);
    model.selected_project_path = path;
    failing.fail_index = failing.alloc_index;
    model.syncLegacyGraph();
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(model.graph == null);
    try std.testing.expectEqualStrings("other", model.currentGraph().?.project.path);
}

fn initAttentionEvictionModel(allocator: std.mem.Allocator, restore: bool) !Model {
    const first =
        \\{"graphChanged":{"project":{"path":"attention-a","name":"A"},"nodes":[{"id":"a-node","title":"A node","state":"failed"}],"edges":[]}}
    ;
    const second =
        \\{"graphChanged":{"project":{"path":"attention-b","name":"B"},"nodes":[{"id":"b-first","title":"B first","state":"failed","activity":"waiting","presence":"awaitingInput"},{"id":"b-second","title":"B second","state":"failed"}],"edges":[]}}
    ;
    var model = Model.init(allocator);
    errdefer model.deinit();
    try model.decodeGraph(first);
    try model.decodeGraph(second);
    try std.testing.expect(model.selectProject("attention-b"));
    if (restore) {
        model.beginRestore();
        try model.decodeGraph(second);
    }
    try std.testing.expectEqual(@as(usize, 3), model.attentionCount());
    try std.testing.expectEqual(@as(usize, 3), model.attention_entries.items.len);
    return model;
}

fn evictAttentionProject(model: *Model, restore: bool) !void {
    if (restore) {
        model.markRestored();
        try std.testing.expectEqual(RestoreState.restored, model.restore_state);
    } else {
        try std.testing.expect(model.applyLifecycle(.close, "attention-a"));
    }
    try std.testing.expect(model.graphFor("attention-a") == null);
    try std.testing.expect(model.graphFor("attention-b") != null);
    try std.testing.expectEqualStrings("attention-b", model.graph.?.project.path);
}

fn expectRetainedProjectAttention(model: *const Model) !void {
    try std.testing.expectEqual(@as(usize, 2), model.attentionCount());
    try std.testing.expectEqual(@as(usize, 2), model.attention_entries.items.len);
    for (model.attention_entries.items) |entry| {
        try std.testing.expectEqualStrings("attention-b", entry.project_path);
        try std.testing.expect(model.graphFor(entry.project_path) != null);
    }
}

fn checkAttentionEvictionFailures(restore: bool) !void {
    const budget = budget: {
        var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var model = try initAttentionEvictionModel(counting.allocator(), restore);
        defer model.deinit();
        const start = counting.alloc_index;
        try evictAttentionProject(&model, restore);
        const total = counting.alloc_index - start;
        try expectRetainedProjectAttention(&model);
        const attention_start = counting.alloc_index;
        var attention = try model.prepareAttention(null);
        defer attention.deinit(counting.allocator());
        const attention_count = counting.alloc_index - attention_start;
        try std.testing.expect(attention_count > 0 and total >= attention_count);
        break :budget .{ .prefix = total - attention_count, .count = attention_count };
    };
    std.debug.print("attention preparation failure positions: {d}\n", .{budget.count});
    for (0..budget.count) |index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        {
            var model = try initAttentionEvictionModel(failing.allocator(), restore);
            defer model.deinit();
            // Removal and legacy synchronization succeed; fail each allocation
            // in the subsequent attention rebuild, including partial lists.
            failing.fail_index = failing.alloc_index + budget.prefix + index;
            try evictAttentionProject(&model, restore);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(@as(usize, 0), model.attentionCount());
            try std.testing.expectEqual(@as(usize, 0), model.attention_entries.items.len);
            model.selectNextAttention();
            try std.testing.expectEqualStrings("attention-b", model.selected_project_path.?);
            try std.testing.expectEqualStrings("b-first", model.selected_node_id.?);

            failing.fail_index = std.math.maxInt(usize);
            model.rebuildAttention();
            try expectRetainedProjectAttention(&model);
            model.selectNextAttention();
            try std.testing.expectEqualStrings("attention-b", model.selected_project_path.?);
        }
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "decoder ownership attention eviction lifecycle removal discards obsolete lists on allocation failure" {
    try checkAttentionEvictionFailures(false);
}

test "decoder ownership attention eviction restore reconciliation discards obsolete lists on allocation failure" {
    try checkAttentionEvictionFailures(true);
}

fn checkNestedEdgeFallbackOwnership(allocator: std.mem.Allocator, summary: *const GraphSummary) !void {
    var model = Model.init(allocator);
    defer model.deinit();
    model.open_composite_id = try allocator.dupe(u8, summary.nodes.items[0].id);
    var snapshot = try model.prepareLegacySnapshot(summary, 0, "child");
    defer snapshot.deinit(allocator);
    // No allocation follows the catch boundary, so a later OOM cannot mask
    // an allocation failure swallowed by the malformed-data fallback.
    try std.testing.expect(snapshot.clear_composite);
    try std.testing.expect(snapshot.composite_title == null);
    try expectGraphDataEqual(summary.*, snapshot.graph orelse return error.TestExpectedGraph);
}

test "decoder ownership nested edge fallback propagates its own OutOfMemory" {
    const allocator = std.testing.allocator;
    const errors = [_]anyerror{ error.SyntaxError, error.MalformedEdge, error.DuplicateField };
    for (ownershipMalformedCompositeEdgeFrames, errors) |frame, expected| {
        var graph = (try decodeGraphFrame(allocator, frame)) orelse return error.TestExpectedGraph;
        defer freeGraph(allocator, &graph);
        try std.testing.expectEqual(@as(usize, 1), graph.nodes.items.len);
        try checkMalformedSubgraphOwnership(allocator, graph.nodes.items[0].subgraph_json, expected);
        const summary = GraphSummary{ .project = graph.project, .nodes = graph.nodes, .edges = graph.edges };

        var counting = std.testing.FailingAllocator.init(allocator, .{});
        try checkNestedEdgeFallbackOwnership(counting.allocator(), &summary);
        try std.testing.expect(counting.alloc_index > 0);
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = counting.alloc_index - 1 });
        try std.testing.expectError(error.OutOfMemory, checkNestedEdgeFallbackOwnership(failing.allocator(), &summary));
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        std.debug.print("nested edge fallback {s}: final allocation {d}/{d} -> OutOfMemory\n", .{
            @errorName(expected), counting.alloc_index - 1, counting.alloc_index,
        });
        try checkOwnershipAllocationFailures(checkNestedEdgeFallbackOwnership, .{&summary});
    }
}
