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
            .project = .{ .path = &.{}, .name = &.{} },
            .nodes = std.array_list.Managed(Node).init(self.allocator),
            .edges = std.array_list.Managed(Edge).init(self.allocator),
        };
        defer freeGraph(self.allocator, &graph);
        graph.project.path = try duplicateJsonString(self.allocator, graph_json, "path");
        graph.project.name = try duplicateJsonString(self.allocator, graph_json, "name");

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
            error.MalformedSubgraph, error.MalformedJsonString => {
                self.allocator.free(snapshot.composite_title.?);
                snapshot.composite_title = null;
                snapshot.clear_composite = true;
                return snapshot;
            },
            else => return err,
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
        for (self.graphs.items) |*summary| {
            if (!std.mem.eql(u8, summary.project.path, graph.project.path)) continue;
            std.mem.swap(std.array_list.Managed(Node), &summary.nodes, &copy.nodes);
            std.mem.swap(std.array_list.Managed(Edge), &summary.edges, &copy.edges);
            return;
        }
        try self.graphs.append(.{ .project = copy.project, .nodes = copy.nodes, .edges = copy.edges });
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
    for (source.edges.items) |edge| {
        const copy = try cloneEdge(allocator, edge);
        errdefer freeEdge(allocator, copy);
        try graph.edges.append(copy);
    }
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
    copy.check_description = try allocator.dupe(u8, node.check_description);
    copy.model_tier = try allocator.dupe(u8, node.model_tier);
    copy.worktree_path = try allocator.dupe(u8, node.worktree_path);
    copy.worktree_branch = try allocator.dupe(u8, node.worktree_branch);
    copy.subgraph_json = try allocator.dupe(u8, node.subgraph_json);
    return copy;
}

fn cloneEdge(allocator: std.mem.Allocator, edge: Edge) !Edge {
    var copy = Edge{
        .from = &.{},
        .to = &.{},
        .condition = &.{},
        .blocks_target = edge.blocks_target,
        .fired = edge.fired,
        .fire_count = edge.fire_count,
    };
    errdefer freeEdge(allocator, copy);
    copy.id = try allocator.dupe(u8, edge.id);
    copy.from = try allocator.dupe(u8, edge.from);
    copy.to = try allocator.dupe(u8, edge.to);
    copy.kind = try allocator.dupe(u8, edge.kind);
    copy.condition = try allocator.dupe(u8, edge.condition);
    return copy;
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
        var node = Node{
            .id = &.{},
            .title = &.{},
            .loop_type = &.{},
            .state = &.{},
            .activity = &.{},
            .presence = &.{},
            .poll_interval_seconds = jsonFloat(scalar_object, "pollIntervalSeconds"),
            .stall_after_seconds = jsonFloat(scalar_object, "stallAfterSeconds"),
            .created_at = jsonNumber64(scalar_object, "createdAt"),
            .metric_passes = jsonArrayObjectCount(scalar_object, "metricHistory"),
            .metric_samples = samples.values,
            .metric_sample_count = samples.count,
            .token_usage = jsonUsageTotal(scalar_object),
            .follows_template = hasNonNullJsonField(scalar_object, "templateFollow"),
        };
        errdefer freeNode(allocator, node);
        node.id = try duplicateJsonString(allocator, scalar_object, "id");
        node.title = try duplicateJsonStringOr(allocator, scalar_object, "title", "Untitled");
        node.loop_type = try duplicateJsonStringOr(allocator, scalar_object, "loopType", "turnBased");
        node.state = try duplicateJsonStringOr(allocator, scalar_object, "state", "idle");
        node.activity = try duplicateJsonStringOr(allocator, scalar_object, "activity", "");
        node.presence = try duplicatePresence(allocator, scalar_object);
        node.backend = try duplicateJsonStringOr(allocator, scalar_object, "backend", "");
        node.pilot_state = try duplicateJsonStringOr(allocator, scalar_object, "pilotState", "notPiloted");
        node.goal_summary = try duplicateJsonStringOr(allocator, scalar_object, "summary", "");
        node.goal_predicate = try duplicateJsonStringOr(allocator, scalar_object, "predicate", "");
        node.metric_command = try duplicateJsonStringOr(allocator, scalar_object, "metricCommand", "");
        node.metric_direction = try duplicateJsonStringOr(allocator, scalar_object, "metricDirection", "");
        node.trigger_prompt = try duplicateJsonStringOr(allocator, scalar_object, "triggerPrompt", "");
        node.check_description = try duplicateJsonStringOr(allocator, scalar_object, "checkDescription", "");
        node.model_tier = try duplicateJsonStringOr(allocator, scalar_object, "modelTier", "");
        node.worktree_path = try duplicateWorktreePath(allocator, scalar_object);
        node.worktree_branch = try duplicateWorktreeBranch(allocator, scalar_object);
        node.subgraph_json = try duplicateJsonObjectOrEmpty(allocator, object, "subGraph");
        try nodes.append(node);
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
        var edge = Edge{
            .from = &.{},
            .to = &.{},
            .condition = &.{},
            .blocks_target = !std.mem.eql(u8, Wire.jsonString(object, "kind") orelse "", "message"),
            .fired = jsonBool(object, "fired") orelse false,
            .fire_count = jsonNumber(object, "fireCount") orelse 0,
        };
        errdefer freeEdge(allocator, edge);
        edge.id = try duplicateJsonStringOr(allocator, object, "id", "");
        edge.from = try duplicateJsonString(allocator, object, "from");
        edge.to = try duplicateJsonString(allocator, object, "to");
        edge.kind = try duplicateJsonStringOr(allocator, object, "kind", "handoff");
        edge.condition = try duplicateJsonStringOr(allocator, object, "condition", "always");
        try edges.append(edge);
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
        .project = try cloneProject(allocator, parent_project),
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
    for (graph.edges.items) |edge| freeEdge(allocator, edge);
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

const ownershipGraphJson =
    \\{"project":{"path":"C:\\owned\\graph","name":"Owned \"graph\""},
    \\"edges":[{"id":"edge-first","from":"first","to":"second","kind":"handoff","condition":"onSuccess","fired":true,"fireCount":2},{"id":"edge-second","from":"second","to":"first","kind":"message"}],
    \\"nodes":[{"id":"first","title":"First \"node\"","loopType":"proactive","state":"running","activity":"editing","presence":{"presence":"busy"},"backend":"copilot","pilotState":"piloted","goal":{"summary":"Ship it","predicate":"done"},"metricCommand":"measure","metricDirection":"decrease","triggerPrompt":"Continue","checkDescription":"Check","modelTier":"high","pollIntervalSeconds":12.5,"stallAfterSeconds":60,"createdAt":123,"metricHistory":[{"value":3},{"value":2}],"inputTokens":11,"outputTokens":7,"worktreeBinding":{"path":"C:\\owned\\branch","branch":"topic"},"subGraph":{"nodes":[{"id":"child","title":"Child","state":"idle"}],"edges":[]},"templateFollow":{"id":"template"}},{"id":"second","title":"Second","state":"idle"}]}
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
    try std.testing.expectEqualStrings("Check", node.check_description);
    try std.testing.expectEqualStrings("high", node.model_tier);
    try std.testing.expectEqual(@as(?f64, 12.5), node.poll_interval_seconds);
    try std.testing.expectEqual(@as(?f64, 60), node.stall_after_seconds);
    try std.testing.expectEqual(@as(?u64, 123), node.created_at);
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
    try std.testing.expectEqual(@as(u32, 2), edge.fire_count);
    try std.testing.expectEqualStrings("edge-second", graph.edges.items[1].id);
    try std.testing.expectEqualStrings("always", graph.edges.items[1].condition);
    try std.testing.expect(!graph.edges.items[1].blocks_target);
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
    try decodeEdges(allocator, "[{\"from\":\"node\",\"to\":\"node\"}" ++ (",{\"from\":\"node\",\"to\":\"node\"}" ** 9) ++ "]", &edges);
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
    for (malformed_strings) |json| {
        try checkOwnershipAllocationFailures(checkMalformedSubgraphOwnership, .{ json, error.MalformedJsonString });
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
    for (invalid_frames) |frame| {
        try std.testing.expectError(error.MalformedJsonString, model.decodeGraph(frame));
        try expectOwnershipGraph(model.graph.?);
        try expectOwnershipGraph(model.graphs.items[0]);
        try checkOwnershipAllocationFailures(checkMalformedGraphDecoderOwnership, .{frame});
    }

    try std.testing.expectError(error.MalformedGraph, model.decodeGraph("{\"graphChanged\":{"));
    try expectOwnershipGraph(model.graph.?);
}

fn checkMalformedGraphDecoderOwnership(allocator: std.mem.Allocator, frame: []const u8) !void {
    var model = Model.init(allocator);
    defer model.deinit();
    model.decodeGraph(frame) catch |err| {
        if (err != error.MalformedJsonString) return err;
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
    for (expected.graphs.items, actual.graphs.items) |left, right| try expectGraphDataEqual(left, right);
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
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try model.decodeGraph(ownershipGraphFrame);
    try std.testing.expect(model.openComposite("first"));
    try model.decodeGraph(ownershipMalformedCompositeFrame);
    try std.testing.expect(!model.isCompositeOpen());
    try std.testing.expectEqualStrings("first", model.graph.?.nodes.items[0].id);
    try std.testing.expectEqualStrings("Owned \"graph\"", model.graph.?.project.name);
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
