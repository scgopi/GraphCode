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
    worktree_path: []u8 = @constCast(""),
};

pub const ActivityEvent = struct {
    title: []u8,
    state: []u8,
};

pub const Edge = struct {
    from: []u8,
    to: []u8,
    kind: []u8 = &.{},
    condition: []u8 = @constCast("always"),
    blocks_target: bool = true,
    fired: bool = false,
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
};

pub const Graph = struct {
    project: Project,
    nodes: std.array_list.Managed(Node),
    edges: std.array_list.Managed(Edge),
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    recent_projects: std.array_list.Managed(Project),
    graph: ?Graph = null,
    selected_node: ?usize = null,
    last_sequence: u64 = 0,
    attention: std.array_list.Managed(Node) ,
    activity: std.array_list.Managed(ActivityEvent),

    pub fn init(allocator: std.mem.Allocator) Model {
        return .{
            .allocator = allocator,
            .recent_projects = std.array_list.Managed(Project).init(allocator),
            .attention = std.array_list.Managed(Node).init(allocator),
            .activity = std.array_list.Managed(ActivityEvent).init(allocator),
        };
    }

    pub fn deinit(self: *Model) void {
        for (self.recent_projects.items) |project| freeProject(self.allocator, project);
        self.recent_projects.deinit();
        for (self.attention.items) |node| freeNode(self.allocator, node);
        self.attention.deinit();
        for (self.activity.items) |event| {
            self.allocator.free(event.title);
            self.allocator.free(event.state);
        }
        self.activity.deinit();
        if (self.graph) |*graph| freeGraph(self.allocator, graph);
    }

    pub fn clearProjects(self: *Model) void {
        for (self.recent_projects.items) |project| freeProject(self.allocator, project);
        self.recent_projects.clearRetainingCapacity();
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
        const graph = if (self.graph) |*value| value else return null;
        const index = self.selected_node orelse return null;
        if (index >= graph.nodes.items.len) return null;
        return &graph.nodes.items[index];
    }

    pub fn selectNext(self: *Model) void {
        const graph = if (self.graph) |*value| value else return;
        if (graph.nodes.items.len == 0) {
            self.selected_node = null;
        } else {
            self.selected_node = ((self.selected_node orelse 0) + 1) % graph.nodes.items.len;
        }
    }

    pub fn selectNextAttention(self: *Model) void {
        if (self.attention.items.len == 0) return;
        const graph = self.graph orelse return;
        const current = self.selected_node orelse 0;
        if (current < graph.nodes.items.len) {
            for (self.attention.items, 0..) |attention, offset| {
                if (!std.mem.eql(u8, attention.id, graph.nodes.items[current].id)) continue;
                const next = self.attention.items[(offset + 1) % self.attention.items.len];
                for (graph.nodes.items, 0..) |node, index| {
                    if (std.mem.eql(u8, node.id, next.id)) {
                        self.selected_node = index;
                        return;
                    }
                }
            }
        }
        const first = self.attention.items[0];
        for (graph.nodes.items, 0..) |node, index| {
            if (std.mem.eql(u8, node.id, first.id)) {
                self.selected_node = index;
                return;
            }
        }
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
        self.recordActivity(graph);
        self.replaceAttention(&graph);
        if (self.graph) |*old| freeGraph(self.allocator, old);
        self.graph = graph;
        if (graph.nodes.items.len == 0) self.selected_node = null else if (self.selected_node == null) self.selected_node = 0;
    }

    fn replaceAttention(self: *Model, graph: *const Graph) void {
        for (self.attention.items) |node| freeNode(self.allocator, node);
        self.attention.clearRetainingCapacity();
        for (graph.nodes.items) |node| {
            if (!needsAttention(node)) continue;
            const copy = cloneNode(self.allocator, node) catch continue;
            const rank = attentionRank(copy);
            var index: usize = 0;
            while (index < self.attention.items.len and
                attentionRank(self.attention.items[index]) <= rank) : (index += 1) {}
            self.attention.insert(index, copy) catch {
                freeNode(self.allocator, copy);
            };
        }
        for (graph.nodes.items) |node| {
            if (!std.mem.eql(u8, node.state, "blocked") or
                !isStranded(graph, node.id)) continue;
            const copy = cloneNode(self.allocator, node) catch continue;
            self.attention.append(copy) catch freeNode(self.allocator, copy);
        }
    }

    fn recordActivity(self: *Model, next: Graph) void {
        const previous = self.graph orelse return;
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
                const removed = self.activity.pop();
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
        .worktree_path = try allocator.dupe(u8, node.worktree_path),
    };
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
            .worktree_path = try duplicateWorktreePath(allocator, object),
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
            .from = try duplicateJsonString(allocator, object, "from"),
            .to = try duplicateJsonString(allocator, object, "to"),
            .kind = try duplicateJsonStringOr(allocator, object, "kind", "handoff"),
            .condition = try duplicateJsonStringOr(allocator, object, "condition", "always"),
            .blocks_target = !std.mem.eql(u8, Wire.jsonString(object, "kind") orelse "", "message"),
            .fired = jsonBool(object, "fired") orelse false,
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
    allocator.free(node.worktree_path);
}

fn freeGraph(allocator: std.mem.Allocator, graph: *Graph) void {
    freeProject(allocator, graph.project);
    for (graph.nodes.items) |node| freeNode(allocator, node);
    for (graph.edges.items) |edge| {
        allocator.free(edge.from);
        allocator.free(edge.to);
        allocator.free(edge.kind);
        allocator.free(edge.condition);
    }
    graph.nodes.deinit();
    graph.edges.deinit();
}

fn jsonBool(data: []const u8, key: []const u8) ?bool {
    var needle_buffer: [128]u8 = undefined;
    if (key.len + 3 > needle_buffer.len) return null;
    needle_buffer[0] = '"';
    @memcpy(needle_buffer[1 .. key.len + 1], key);
    needle_buffer[key.len + 1] = '"';
    needle_buffer[key.len + 2] = ':';
    const start = std.mem.indexOf(u8, data, needle_buffer[0 .. key.len + 3]) orelse return null;
    const value = data[start + key.len + 3 ..];
    if (std.mem.startsWith(u8, value, "true")) return true;
    if (std.mem.startsWith(u8, value, "false")) return false;
    return null;
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
    model.selected_node = 1;
    model.selectNextAttention();
    try std.testing.expectEqual(@as(usize, 0), model.selected_node.?);
    model.selectNextAttention();
    try std.testing.expectEqual(@as(usize, 1), model.selected_node.?);
}
