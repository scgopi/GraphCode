const std = @import("std");
const Wire = @import("Wire.zig");
pub const WorktreeSummary = @import("WorktreeStatus.zig").Summary;

pub const Node = struct {
    id: []u8,
    title: []u8,
    loop_type: []u8,
    state: []u8,
    activity: []u8,
    presence: []u8,
    goal_summary: []u8 = &.{},
    goal_predicate: []u8 = &.{},
    metric_command: []u8 = &.{},
    metric_direction: []u8 = &.{},
    trigger_prompt: []u8 = &.{},
    check_description: []u8 = &.{},
    model_tier: []u8 = &.{},
    poll_interval_seconds: ?f64 = null,
    stall_after_seconds: ?f64 = null,
    worktree_path: []u8 = @constCast(""),
    worktree_branch: []u8 = &.{},
};

pub const ActivityEvent = struct {
    title: []u8,
    state: []u8,
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

    pub fn isRemote(self: Project) bool {
        return std.mem.startsWith(u8, self.path, "ssh://");
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

pub const GraphSummary = struct {
    project: Project,
    nodes: std.array_list.Managed(Node),
    edges: std.array_list.Managed(Edge),

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
    last_sequence: u64 = 0,
    attention: std.array_list.Managed(Node),
    attention_entries: std.array_list.Managed(AttentionEntry),
    activity: std.array_list.Managed(ActivityEvent),
    lifecycle_callback: ?LifecycleCallback = null,
    lifecycle_context: ?*anyopaque = null,
    restore_state: RestoreState = .cold,
    restore_generation: u64 = 0,
    graph_generations: std.array_list.Managed(GraphGeneration),

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
        }
        self.activity.deinit();
        if (self.graph) |*graph| freeGraph(self.allocator, graph);
        if (self.selected_project_path) |path| self.allocator.free(path);
        self.freeSelectedNodeID();
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
        self.restore_generation += 1;
        self.restore_state = .restoring;
    }

    pub fn markRestored(self: *Model) void {
        self.reconcileRestore();
        self.restore_state = .restored;
    }

    pub fn markReconnecting(self: *Model) void {
        // Graph summaries and selection intentionally survive transport loss.
        self.restore_state = .reconnecting;
    }

    pub fn selectedNodeID(self: *const Model) ?[]const u8 {
        return if (self.selected()) |node| node.id else null;
    }

    pub fn selectedIndex(self: *const Model) ?usize {
        return self.selected_index;
    }

    pub fn setSelectedIndex(self: *Model, index: ?usize) bool {
        const graph = self.currentGraph() orelse return index == null;
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

    pub fn selectProject(self: *Model, project_path: []const u8) bool {
        const summary = self.graphFor(project_path) orelse return false;
        if (self.selected_project_path) |path| self.allocator.free(path);
        self.selected_project_path = self.allocator.dupe(u8, summary.project.path) catch return false;
        self.selected_index = if (summary.nodes.items.len == 0) null else 0;
        if (summary.nodes.items.len == 0) self.freeSelectedNodeID() else self.replaceSelectedNodeID(summary.nodes.items[0].id);
        self.syncLegacyGraph();
        return true;
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
            else => return Wire.eventKind(frame),
        }
    }

    pub fn attentionCount(self: *const Model) usize {
        return self.attention.items.len;
    }

    pub fn selected(self: *const Model) ?*const Node {
        const graph = self.currentGraph() orelse return null;
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
        const graph = self.currentGraph() orelse return null;
        return findEdgeIndexByID(graph.edges.items, id);
    }

    pub fn selectNext(self: *Model) void {
        const graph = self.currentGraph() orelse return;
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
        const graph = self.currentGraph() orelse return false;
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
        else self.graph == null;
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
            for (summary.nodes.items) |node| freeNode(self.allocator, node);
            for (summary.edges.items) |edge| freeEdge(self.allocator, edge);
            summary.nodes.clearRetainingCapacity();
            summary.edges.clearRetainingCapacity();
            for (graph.nodes.items) |node| try summary.nodes.append(try cloneNode(self.allocator, node));
            for (graph.edges.items) |edge| try summary.edges.append(try cloneEdge(self.allocator, edge));
            return;
        }
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
                    const entry = AttentionEntry{ .project_path = self.allocator.dupe(u8, summary.project.path) catch { freeNode(self.allocator, node_copy); continue; }, .node = node_copy };
                    self.attention_entries.append(entry) catch { freeAttentionEntry(self.allocator, entry); continue; };
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
            const event = ActivityEvent{ .title = title, .state = state };
            self.activity.insert(0, event) catch {
                self.allocator.free(event.title);
                self.allocator.free(event.state);
                continue;
            };
            if (self.activity.items.len > 32) {
                const removed = self.activity.pop() orelse continue;
                self.allocator.free(removed.title);
                self.allocator.free(removed.state);
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
        .goal_summary = try allocator.dupe(u8, node.goal_summary),
        .goal_predicate = try allocator.dupe(u8, node.goal_predicate),
        .metric_command = try allocator.dupe(u8, node.metric_command),
        .metric_direction = try allocator.dupe(u8, node.metric_direction),
        .trigger_prompt = try allocator.dupe(u8, node.trigger_prompt),
        .check_description = try allocator.dupe(u8, node.check_description),
        .model_tier = try allocator.dupe(u8, node.model_tier),
        .poll_interval_seconds = node.poll_interval_seconds,
        .stall_after_seconds = node.stall_after_seconds,
        .worktree_path = try allocator.dupe(u8, node.worktree_path),
        .worktree_branch = try allocator.dupe(u8, node.worktree_branch),
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
        try nodes.append(.{
            .id = try duplicateJsonString(allocator, object, "id"),
            .title = try duplicateJsonStringOr(allocator, object, "title", "Untitled"),
            .loop_type = try duplicateJsonStringOr(allocator, object, "loopType", "turnBased"),
            .state = try duplicateJsonStringOr(allocator, object, "state", "idle"),
            .activity = try duplicateJsonStringOr(allocator, object, "activity", ""),
            .presence = try duplicatePresence(allocator, object),
            .goal_summary = try duplicateJsonStringOr(allocator, object, "summary", ""),
            .goal_predicate = try duplicateJsonStringOr(allocator, object, "predicate", ""),
            .metric_command = try duplicateJsonStringOr(allocator, object, "metricCommand", ""),
            .metric_direction = try duplicateJsonStringOr(allocator, object, "metricDirection", ""),
            .trigger_prompt = try duplicateJsonStringOr(allocator, object, "triggerPrompt", ""),
            .check_description = try duplicateJsonStringOr(allocator, object, "checkDescription", ""),
            .model_tier = try duplicateJsonStringOr(allocator, object, "modelTier", ""),
            .poll_interval_seconds = jsonFloat(object, "pollIntervalSeconds"),
            .stall_after_seconds = jsonFloat(object, "stallAfterSeconds"),
            .worktree_path = try duplicateWorktreePath(allocator, object),
            .worktree_branch = try duplicateWorktreeBranch(allocator, object),
        });
        cursor = end + 1;
    }
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
    allocator.free(node.goal_summary);
    allocator.free(node.goal_predicate);
    allocator.free(node.metric_command);
    allocator.free(node.metric_direction);
    allocator.free(node.trigger_prompt);
    allocator.free(node.check_description);
    allocator.free(node.model_tier);
    allocator.free(node.worktree_path);
    allocator.free(node.worktree_branch);
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
