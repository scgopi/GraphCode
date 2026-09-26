const std = @import("std");
const DaemonClient = @import("DaemonClient.zig").DaemonClient;
const Forms = @import("Forms.zig");
const GraphModel = @import("GraphModel.zig");
const NativeForms = @import("NativeForms.zig");

pub const LockedEndpoints = struct { from: []const u8, to: []const u8 };

const Snapshot = struct {
    allocator: std.mem.Allocator,
    project_path: []const u8 = &.{},
    composite_id: []const u8 = &.{},
    endpoints: []NativeForms.EdgeEndpoint = &.{},
    from_index: usize = 0,
    to_index: usize = 1,
    locked: bool,

    fn capture(
        allocator: std.mem.Allocator,
        model: *const GraphModel.Model,
        client: *DaemonClient,
        locked: ?LockedEndpoints,
    ) !Snapshot {
        const graph = model.graph orelse return error.ProjectClosed;
        var result = Snapshot{ .allocator = allocator, .locked = locked != null };
        errdefer result.deinit();
        result.project_path = try allocator.dupe(u8, graph.project.path);
        result.composite_id = try allocator.dupe(u8, model.open_composite_id orelse "");
        try result.validateContext(model, client);
        if (locked) |ids| {
            if (std.mem.eql(u8, ids.from, ids.to)) return error.SameEndpoint;
            result.from_index = GraphModel.findNodeIndexByID(graph.nodes.items, ids.from) orelse
                return error.SourceLoopChanged;
            result.to_index = GraphModel.findNodeIndexByID(graph.nodes.items, ids.to) orelse
                return error.TargetLoopChanged;
        } else if (graph.nodes.items.len < 2) return error.NotEnoughEndpoints;
        result.endpoints = try allocator.alloc(NativeForms.EdgeEndpoint, graph.nodes.items.len);
        for (result.endpoints) |*endpoint| endpoint.* = .{ .id = &.{}, .title = &.{} };
        for (graph.nodes.items, result.endpoints) |node, *endpoint| {
            endpoint.id = try allocator.dupe(u8, node.id);
            endpoint.title = try allocator.dupe(u8, node.title);
        }
        return result;
    }

    fn deinit(self: *Snapshot) void {
        for (self.endpoints) |endpoint| {
            self.allocator.free(endpoint.id);
            self.allocator.free(endpoint.title);
        }
        self.allocator.free(self.endpoints);
        self.allocator.free(self.composite_id);
        self.allocator.free(self.project_path);
    }

    fn initial(self: *const Snapshot) Forms.EdgeDraft {
        return .{
            .from = self.endpoints[self.from_index].id,
            .to = self.endpoints[self.to_index].id,
        };
    }

    fn validateContext(self: *const Snapshot, model: *const GraphModel.Model, client: *DaemonClient) !void {
        const graph = model.graph orelse return error.ProjectClosed;
        const selected = model.selected_project_path orelse return error.ProjectClosed;
        if (!std.mem.eql(u8, graph.project.path, self.project_path) or
            !std.mem.eql(u8, selected, self.project_path)) return error.ProjectChanged;
        if (!std.mem.eql(u8, model.open_composite_id orelse "", self.composite_id))
            return error.CompositeChanged;
        // Subscription observes updates; the sender explicitly encodes the captured project path.
        client.mutex.lock();
        defer client.mutex.unlock();
        if (!std.mem.eql(u8, client.subgraph_node_id, self.composite_id))
            return error.ClientScopeChanged;
    }

    fn hasEndpoint(self: *const Snapshot, id: []const u8) bool {
        for (self.endpoints) |endpoint| if (std.mem.eql(u8, endpoint.id, id)) return true;
        return false;
    }

    fn submit(self: *const Snapshot, model: *const GraphModel.Model, client: *DaemonClient, draft: Forms.EdgeDraft) !void {
        try Forms.validateEdge(draft);
        try self.validateContext(model, client);
        const graph = model.graph.?;
        const original = self.initial();
        if (!self.hasEndpoint(draft.from) or
            (self.locked and !std.mem.eql(u8, draft.from, original.from)) or
            GraphModel.findNodeIndexByID(graph.nodes.items, draft.from) == null)
            return error.SourceLoopChanged;
        if (!self.hasEndpoint(draft.to) or
            (self.locked and !std.mem.eql(u8, draft.to, original.to)) or
            GraphModel.findNodeIndexByID(graph.nodes.items, draft.to) == null)
            return error.TargetLoopChanged;
        client.sendCreateEdgeDraft(self.project_path, draft);
    }
};

// The form may pump daemon updates; nothing it borrows may point into the model.
pub fn create(
    allocator: std.mem.Allocator,
    model: *const GraphModel.Model,
    client: *DaemonClient,
    locked: ?LockedEndpoints,
    form: anytype,
) !void {
    var snapshot = try Snapshot.capture(allocator, model, client, locked);
    defer snapshot.deinit();
    var draft = try form.show(allocator, snapshot.initial(), snapshot.endpoints, snapshot.locked) orelse return;
    defer draft.deinit(allocator);
    try snapshot.submit(model, client, draft);
}

pub fn errorStatus(err: anyerror) []const u8 {
    return switch (err) {
        error.ProjectClosed => "Project closed while creating edge",
        error.ProjectChanged => "Project changed while creating edge",
        error.CompositeChanged => "Composite changed while creating edge",
        error.ClientScopeChanged => "Daemon scope changed while creating edge",
        error.SourceLoopChanged => "Source loop changed while creating edge",
        error.TargetLoopChanged => "Target loop changed while creating edge",
        error.NotEnoughEndpoints => "Create two loops before creating an edge",
        error.MissingSource,
        error.MissingTarget,
        error.SameEndpoint,
        error.UnsupportedEdgeKind,
        error.UnsupportedEdgeCondition,
        error.UnsupportedTransform,
        error.InvalidCycleGuard,
        error.InvalidNumericInput,
        => "Invalid edge form",
        error.OutOfMemory => "Unable to prepare edge form",
        else => "Unable to open edge form",
    };
}
