const std = @import("std");
const Wire = @import("Wire.zig");

pub const Node = struct {
    id: []u8,
    title: []u8,
    loop_type: []u8,
    state: []u8,
    activity: []u8,
    presence: []u8,
};

pub const Edge = struct {
    from: []u8,
    to: []u8,
};

pub const Project = struct {
    path: []u8,
    name: []u8,
    remote: bool = false,
    global: bool = false,
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

    pub fn init(allocator: std.mem.Allocator) Model {
        return .{
            .allocator = allocator,
            .recent_projects = std.array_list.Managed(Project).init(allocator),
        };
    }

    pub fn deinit(self: *Model) void {
        for (self.recent_projects.items) |project| freeProject(self.allocator, project);
        self.recent_projects.deinit();
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
                .remote = std.mem.indexOf(u8, object, "\"remote\":true") != null,
                .global = std.mem.indexOf(u8, object, "\"isGlobal\":true") != null,
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
                .remote = std.mem.indexOf(u8, graph_json, "\"remote\":true") != null,
                .global = std.mem.indexOf(u8, graph_json, "\"isGlobal\":true") != null,
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
        if (self.graph) |*old| freeGraph(self.allocator, old);
        self.graph = graph;
        if (graph.nodes.items.len == 0) self.selected_node = null else if (self.selected_node == null) self.selected_node = 0;
    }
};

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
        });
        cursor = end + 1;
    }
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
}

fn freeGraph(allocator: std.mem.Allocator, graph: *Graph) void {
    freeProject(allocator, graph.project);
    for (graph.nodes.items) |node| freeNode(allocator, node);
    for (graph.edges.items) |edge| {
        allocator.free(edge.from);
        allocator.free(edge.to);
    }
    graph.nodes.deinit();
    graph.edges.deinit();
}

test "graph snapshots decode escaped project data and presence" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    const frame =
        \\{"version":2,"kind":"event","sequence":7,"event":{"graphChanged":{"id":"graph","project":{"path":"C:\\work\\graph","name":"Visual \u2603","remote":false},"nodes":[{"id":"node","title":"Node \"A\"","loopType":"turnBased","state":"running","activity":"editing","presence":{"presence":"busy","confidence":"reported"}}],"edges":[]}}}
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
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"stub-graph","project":{"path":"graphcode://stub/project","name":"Stub project","remote":false},"nodes":[{"id":"11111111-1111-4111-8111-111111111111","title":"Stub node A","loopType":"turnBased","state":"running","activity":"stub","presence":{"presence":"busy","confidence":"reported"}},{"id":"22222222-2222-4222-8222-222222222222","title":"Stub node B","loopType":"turnBased","state":"idle","activity":"stub","presence":{"presence":"idle","confidence":"reported"}}],"edges":[]}}}
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
