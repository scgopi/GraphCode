const std = @import("std");
const EdgeCreation = @import("EdgeCreation.zig");
const DaemonClient = @import("DaemonClient.zig").DaemonClient;
const FrameBuffer = @import("FrameBuffer.zig").FrameBuffer;
const Forms = @import("Forms.zig");
const GraphModel = @import("GraphModel.zig");
const NativeForms = @import("NativeForms.zig");

const accepted = Forms.EdgeDraft{
    .from = "from",
    .to = "to",
    .kind = "spawn",
    .condition = "onFailure",
    .transform_kind = "script",
    .transform_value = "echo \"\u{96ea}\"\nnext",
    .cycle_max_iterations = 7,
    .cycle_until = "test \"\u{2713}\"",
    .cycle_stop_after_passes = 3,
    .spawn_target_project_path = "D:\\\u{96ea}\\\"spawn\"",
};

const expected = "{\"graphCommand\":{\"projectPath\":\"C:\\\\project\",\"command\":{\"createEdge\":{\"from\":\"from\",\"to\":\"to\",\"spec\":{\"kind\":\"spawn\",\"condition\":\"onFailure\",\"payloadTransform\":{\"script\":{\"_0\":\"echo \\\"\u{96ea}\\\"\\nnext\"}},\"cycleGuard\":{\"maxIterations\":7,\"until\":\"test \\\"\u{2713}\\\"\",\"stopAfterPassesWithoutImprovement\":3},\"spawnTargetProjectPath\":\"D:\\\\\u{96ea}\\\\\\\"spawn\\\"\"}}}}}";

fn clientWithoutWorker(allocator: std.mem.Allocator) !DaemonClient {
    return .{ .allocator = allocator, .frame_buffer = try FrameBuffer.init(allocator, .v2) };
}

const graph_frame =
    \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"C:\\project","name":"Project"},"nodes":[{"id":"from","title":"From"},{"id":"to","title":"To"},{"id":"third","title":"Third"},{"id":"group-one","title":"Group One","loopType":"composite","subGraph":{"nodes":[{"id":"from","title":"From"},{"id":"to","title":"To"},{"id":"third","title":"Third"}],"edges":[]}},{"id":"group-two","title":"Group Two","loopType":"composite","subGraph":{"nodes":[{"id":"from","title":"From"},{"id":"to","title":"To"},{"id":"third","title":"Third"}],"edges":[]}}],"edges":[]}}}
;

const Fixture = struct {
    model: GraphModel.Model,
    client: DaemonClient,

    fn init(composite: bool) !Fixture {
        var result = Fixture{
            .model = GraphModel.Model.init(std.testing.allocator),
            .client = try clientWithoutWorker(std.testing.allocator),
        };
        errdefer result.deinit();
        _ = try result.model.updateFromFrame(graph_frame);
        result.client.setSubscription("C:\\project");
        if (composite) {
            try std.testing.expect(result.model.openComposite("group-one"));
            result.client.setSubgraphAddress("group-one");
        }
        return result;
    }

    fn deinit(self: *Fixture) void {
        self.model.deinit();
        self.client.deinit();
    }

    fn replaceFrame(self: *Fixture, old: []const u8, new: []const u8) !void {
        const frame = try std.mem.replaceOwned(u8, std.testing.allocator, graph_frame, old, new);
        defer std.testing.allocator.free(frame);
        _ = try self.model.updateFromFrame(frame);
    }
};

fn ownDraft(allocator: std.mem.Allocator, draft: Forms.EdgeDraft) !Forms.EdgeDraft {
    var owned = Forms.EdgeDraft{
        .from = &.{},
        .to = &.{},
        .kind = &.{},
        .condition = &.{},
        .transform_kind = &.{},
        .transform_value = &.{},
        .cycle_until = &.{},
        .spawn_target_project_path = &.{},
        .cycle_max_iterations = draft.cycle_max_iterations,
        .cycle_stop_after_passes = draft.cycle_stop_after_passes,
    };
    errdefer owned.deinit(allocator);
    inline for (.{
        "from",        "to",                        "kind", "condition", "transform_kind", "transform_value",
        "cycle_until", "spawn_target_project_path",
    }) |field| @field(owned, field) = try allocator.dupe(u8, @field(draft, field));
    return owned;
}

const Mutation = enum {
    none,
    refresh,
    foreign_project,
    selected_project,
    close_project,
    lose_selection,
    enter_composite,
    switch_composite,
    leave_composite,
    delete_composite,
    subscription_refresh,
    subscription_change,
    subscription_clear,
    client_composite,
    client_composite_lost,
    delete_source,
    delete_target,
    add_endpoint,
};

const Outcome = enum { accept, cancel, form_error };

const FormProbe = struct {
    fixture: *Fixture,
    draft: Forms.EdgeDraft = accepted,
    mutation: Mutation = .none,
    outcome: Outcome = .accept,
    called: bool = false,
    locked: bool,

    pub fn show(
        self: *FormProbe,
        allocator: std.mem.Allocator,
        initial: Forms.EdgeDraft,
        endpoints: []const NativeForms.EdgeEndpoint,
        locked: bool,
    ) !?Forms.EdgeDraft {
        self.called = true;
        try std.testing.expectEqual(self.locked, locked);
        const model = &self.fixture.model;
        const client = &self.fixture.client;
        const from = model.findNodeIndex(initial.from).?;
        const to = model.findNodeIndex(initial.to).?;
        try std.testing.expect(initial.from.ptr != model.graph.?.nodes.items[from].id.ptr);
        try std.testing.expect(initial.to.ptr != model.graph.?.nodes.items[to].id.ptr);
        for (endpoints, model.graph.?.nodes.items) |endpoint, node| {
            try std.testing.expect(endpoint.id.ptr != node.id.ptr);
            try std.testing.expect(endpoint.title.ptr != node.title.ptr);
            try std.testing.expectEqualStrings(node.id, endpoint.id);
            try std.testing.expectEqualStrings(node.title, endpoint.title);
        }
        switch (self.mutation) {
            .none => {},
            .refresh => {
                try self.fixture.replaceFrame(
                    "{\"id\":\"from\",\"title\":\"From\"},{\"id\":\"to\",\"title\":\"To\"}",
                    "{\"id\":\"to\",\"title\":\"To refreshed\"},{\"id\":\"from\",\"title\":\"From refreshed\"}",
                );
                try std.testing.expectEqualStrings("from", initial.from);
                try std.testing.expectEqualStrings("to", initial.to);
                try std.testing.expectEqualStrings("From", endpoints[0].title);
                try std.testing.expectEqualStrings("To", endpoints[1].title);
                try std.testing.expectEqualStrings("to", model.graph.?.nodes.items[0].id);
                try std.testing.expectEqualStrings("To refreshed", model.graph.?.nodes.items[0].title);
            },
            .foreign_project => {
                const composite = model.isCompositeOpen();
                try self.fixture.replaceFrame("C:\\\\project", "D:\\\\foreign");
                try std.testing.expect(model.selectProject("D:\\foreign"));
                client.setSubscription("D:\\foreign");
                if (composite) try std.testing.expect(model.openComposite("group-one"));
                try std.testing.expect(model.findNodeIndex("from") != null);
                try std.testing.expect(model.findNodeIndex("to") != null);
            },
            .selected_project, .lose_selection => {
                model.allocator.free(model.selected_project_path.?);
                model.selected_project_path = if (self.mutation == .lose_selection) null else try model.allocator.dupe(u8, "D:\\foreign");
            },
            .close_project => {
                model.deinit();
                model.* = GraphModel.Model.init(std.testing.allocator);
            },
            .enter_composite => {
                try std.testing.expect(model.openComposite("group-one"));
                client.setSubgraphAddress("group-one");
            },
            .switch_composite => {
                model.closeComposite();
                try std.testing.expect(model.openComposite("group-two"));
                client.setSubgraphAddress("group-two");
            },
            .leave_composite => {
                model.closeComposite();
                client.setSubgraphAddress(null);
            },
            .delete_composite => try self.fixture.replaceFrame("\"id\":\"group-one\"", "\"id\":\"removed-group\""),
            .subscription_refresh => {
                _ = try model.updateFromFrame(graph_frame);
                client.setSubscription("C:\\project");
            },
            .subscription_change => client.setSubscription("D:\\foreign"),
            .subscription_clear => client.setSubscription(""),
            .client_composite => client.setSubgraphAddress("group-two"),
            .client_composite_lost => client.setSubgraphAddress(null),
            .delete_source => try self.fixture.replaceFrame("\"id\":\"from\"", "\"id\":\"removed-from\""),
            .delete_target => try self.fixture.replaceFrame("\"id\":\"to\"", "\"id\":\"removed-to\""),
            .add_endpoint => try self.fixture.replaceFrame("\"id\":\"third\"", "\"id\":\"late\""),
        }
        // Even a refresh that frees all model strings must leave the modal's choices intact.
        try std.testing.expectEqualStrings(initial.from, endpoints[from].id);
        try std.testing.expectEqualStrings(initial.to, endpoints[to].id);
        return switch (self.outcome) {
            .accept => try ownDraft(allocator, self.draft),
            .cancel => null,
            .form_error => error.FormUnavailable,
        };
    }
};

fn selection(locked: bool) ?EdgeCreation.LockedEndpoints {
    return if (locked) .{ .from = "from", .to = "to" } else null;
}

test "edge creation accepted full draft reaches outgoing command" {
    for ([_]bool{ false, true }) |locked| {
        var fixture = try Fixture.init(false);
        defer fixture.deinit();
        var form = FormProbe{ .fixture = &fixture, .locked = locked };
        try Forms.validateEdge(accepted);
        try EdgeCreation.create(std.testing.allocator, &fixture.model, &fixture.client, selection(locked), &form);
        try std.testing.expect(form.called);
        try std.testing.expectEqual(@as(usize, 1), fixture.client.outbound_count);
        try std.testing.expectEqualStrings(expected, fixture.client.outbound[fixture.client.outbound_head]);
    }
}

fn expectNullableInt(expected_value: ?i64, value: std.json.Value) !void {
    if (expected_value) |number| {
        try std.testing.expect(value == .integer);
        try std.testing.expectEqual(number, value.integer);
    } else try std.testing.expect(value == .null);
}

fn expectNullableString(expected_value: []const u8, value: std.json.Value) !void {
    if (expected_value.len == 0) {
        try std.testing.expect(value == .null);
    } else try std.testing.expectEqualStrings(expected_value, value.string);
}

fn expectCommand(client: *DaemonClient, path: []const u8, composite: ?[]const u8, draft: Forms.EdgeDraft) !void {
    try std.testing.expectEqual(@as(usize, 1), client.outbound_count);
    const json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, client.outbound[client.outbound_head], .{});
    defer json.deinit();
    const addressed = json.value.object.get("graphCommand").?.object;
    try std.testing.expectEqualStrings(path, addressed.get("projectPath").?.string);
    var command = addressed.get("command").?.object;
    if (composite) |id| {
        try std.testing.expectEqual(@as(usize, 1), command.count());
        const nested = command.get("subGraphCommand").?.object;
        try std.testing.expectEqualStrings(id, nested.get("nodeID").?.string);
        command = nested.get("command").?.object;
    }
    try std.testing.expectEqual(@as(usize, 1), command.count());
    const edge = command.get("createEdge").?.object;
    try std.testing.expectEqualStrings(draft.from, edge.get("from").?.string);
    try std.testing.expectEqualStrings(draft.to, edge.get("to").?.string);
    const spec = edge.get("spec").?.object;
    try std.testing.expectEqual(@as(usize, 5), spec.count());
    try std.testing.expectEqualStrings(draft.kind, spec.get("kind").?.string);
    try std.testing.expectEqualStrings(draft.condition, spec.get("condition").?.string);
    const transform = spec.get("payloadTransform").?.object;
    try std.testing.expectEqual(@as(usize, 1), transform.count());
    const transform_payload = transform.get(draft.transform_kind).?.object;
    if (std.mem.eql(u8, draft.transform_kind, "none")) {
        try std.testing.expectEqual(@as(usize, 0), transform_payload.count());
    } else try std.testing.expectEqualStrings(draft.transform_value, transform_payload.get("_0").?.string);
    const cycle = spec.get("cycleGuard").?;
    if (draft.cycle_max_iterations == null and draft.cycle_until.len == 0 and draft.cycle_stop_after_passes == null) {
        try std.testing.expect(cycle == .null);
    } else {
        try std.testing.expectEqual(@as(usize, 3), cycle.object.count());
        try expectNullableInt(draft.cycle_max_iterations, cycle.object.get("maxIterations").?);
        try expectNullableString(draft.cycle_until, cycle.object.get("until").?);
        try expectNullableInt(draft.cycle_stop_after_passes, cycle.object.get("stopAfterPassesWithoutImprovement").?);
    }
    try expectNullableString(draft.spawn_target_project_path, spec.get("spawnTargetProjectPath").?);
}

fn expectCachedProjectCreation(locked: bool) !void {
    for ([_]bool{ false, true }) |composite| {
        for ([_]Mutation{ .none, .subscription_refresh, .subscription_change, .subscription_clear }) |mutation| {
            var fixture = try Fixture.init(true);
            defer fixture.deinit();
            try fixture.replaceFrame("C:\\\\project", "D:\\\\cached");
            try std.testing.expect(fixture.model.graphFor("C:\\project") != null);
            try std.testing.expect(fixture.model.graphFor("D:\\cached") != null);
            // App.selectProject selects the cached model and clears addressing, not the subscription.
            try std.testing.expect(fixture.model.selectProject("D:\\cached"));
            fixture.client.setSubgraphAddress(null);
            try std.testing.expect(!fixture.model.isCompositeOpen());
            if (composite) {
                try std.testing.expect(fixture.model.openComposite("group-one"));
                fixture.client.setSubgraphAddress("group-one");
            }
            try std.testing.expectEqualStrings("C:\\project", fixture.client.subscription_path);
            var form = FormProbe{ .fixture = &fixture, .locked = locked, .mutation = mutation };
            try EdgeCreation.create(std.testing.allocator, &fixture.model, &fixture.client, selection(locked), &form);
            try std.testing.expect(form.called);
            try expectCommand(&fixture.client, "D:\\cached", if (composite) "group-one" else null, accepted);
            if (!composite) {
                const expected_cached = try std.mem.replaceOwned(u8, std.testing.allocator, expected, "C:\\\\project", "D:\\\\cached");
                defer std.testing.allocator.free(expected_cached);
                try std.testing.expectEqualStrings(expected_cached, fixture.client.outbound[fixture.client.outbound_head]);
            }
            try std.testing.expectEqualStrings("D:\\cached", fixture.model.selected_project_path.?);
            try std.testing.expectEqualStrings(if (composite) "group-one" else "", fixture.client.subgraph_node_id);
            try std.testing.expectEqualStrings(switch (mutation) {
                .subscription_change => "D:\\foreign",
                .subscription_clear => "",
                else => "C:\\project",
            }, fixture.client.subscription_path);
        }
    }
}

test "edge creation cached project menu submission is independent of subscription" {
    try expectCachedProjectCreation(false);
}

test "edge creation cached project locked submission is independent of subscription" {
    try expectCachedProjectCreation(true);
}

test "edge creation preserves typed optional guards and transforms in root and composite commands" {
    for ([_]bool{ false, true }) |composite| {
        for ([_]bool{ false, true }) |locked| {
            for (0..8) |mask| {
                for ([_][]const u8{ "none", "template", "script" }) |transform| {
                    var fixture = try Fixture.init(composite);
                    defer fixture.deinit();
                    var draft = accepted;
                    draft.transform_kind = transform;
                    draft.cycle_max_iterations = if (mask & 1 != 0) 7 else null;
                    draft.cycle_until = if (mask & 2 != 0) accepted.cycle_until else "";
                    draft.cycle_stop_after_passes = if (mask & 4 != 0) 3 else null;
                    if (mask == 0) {
                        draft.kind = "handoff";
                        draft.condition = "always";
                        draft.spawn_target_project_path = "";
                    } else if (mask == 1) {
                        draft.kind = "message";
                        draft.condition = "onSuccess";
                    }
                    var form = FormProbe{ .fixture = &fixture, .locked = locked, .draft = draft };
                    try EdgeCreation.create(std.testing.allocator, &fixture.model, &fixture.client, selection(locked), &form);
                    try expectCommand(&fixture.client, "C:\\project", if (composite) "group-one" else null, draft);
                    try std.testing.expect(fixture.client.worker == null);
                }
            }
        }
    }
}

test "edge creation owns initial IDs titles and context across a reordered model refresh" {
    for ([_]bool{ false, true }) |composite| {
        for ([_]bool{ false, true }) |locked| {
            var fixture = try Fixture.init(composite);
            defer fixture.deinit();
            const graph = fixture.model.graph.?;
            const borrowed: ?EdgeCreation.LockedEndpoints = if (locked) .{
                .from = graph.nodes.items[0].id,
                .to = graph.nodes.items[1].id,
            } else null;
            var form = FormProbe{ .fixture = &fixture, .locked = locked, .mutation = .refresh };
            try EdgeCreation.create(std.testing.allocator, &fixture.model, &fixture.client, borrowed, &form);
            try expectCommand(&fixture.client, "C:\\project", if (composite) "group-one" else null, accepted);
        }
    }
}

test "edge creation preserves quoted Unicode project and endpoint identities" {
    for ([_]bool{ false, true }) |composite| {
        var fixture = try Fixture.init(false);
        defer fixture.deinit();
        const path = "C:\\\u{96ea}\\\"project\"";
        const renamed_path = try std.mem.replaceOwned(u8, std.testing.allocator, graph_frame, "C:\\\\project", "C:\\\\\u{96ea}\\\\\\\"project\\\"");
        defer std.testing.allocator.free(renamed_path);
        const renamed_source = try std.mem.replaceOwned(u8, std.testing.allocator, renamed_path, "\"id\":\"from\"", "\"id\":\"from-\\\"\u{96ea}\\\"\"");
        defer std.testing.allocator.free(renamed_source);
        const renamed_target = try std.mem.replaceOwned(u8, std.testing.allocator, renamed_source, "\"id\":\"to\"", "\"id\":\"to-\\\"\u{2713}\\\"\"");
        defer std.testing.allocator.free(renamed_target);
        _ = try fixture.model.updateFromFrame(renamed_target);
        try std.testing.expect(fixture.model.selectProject(path));
        fixture.client.setSubscription(path);
        if (composite) {
            try std.testing.expect(fixture.model.openComposite("group-one"));
            fixture.client.setSubgraphAddress("group-one");
        }
        var draft = accepted;
        draft.from = "from-\"\u{96ea}\"";
        draft.to = "to-\"\u{2713}\"";
        var form = FormProbe{ .fixture = &fixture, .locked = true, .draft = draft };
        try EdgeCreation.create(std.testing.allocator, &fixture.model, &fixture.client, .{ .from = draft.from, .to = draft.to }, &form);
        try expectCommand(&fixture.client, path, if (composite) "group-one" else null, draft);
    }
}

test "edge creation rejects stale model and actual client scope without retargeting" {
    const Case = struct { composite: bool = false, mutation: Mutation, err: anyerror, status: []const u8 };
    const cases = [_]Case{
        .{ .mutation = .foreign_project, .err = error.ProjectChanged, .status = "Project changed while creating edge" },
        .{ .composite = true, .mutation = .foreign_project, .err = error.ProjectChanged, .status = "Project changed while creating edge" },
        .{ .mutation = .selected_project, .err = error.ProjectChanged, .status = "Project changed while creating edge" },
        .{ .mutation = .close_project, .err = error.ProjectClosed, .status = "Project closed while creating edge" },
        .{ .mutation = .lose_selection, .err = error.ProjectClosed, .status = "Project closed while creating edge" },
        .{ .mutation = .enter_composite, .err = error.CompositeChanged, .status = "Composite changed while creating edge" },
        .{ .composite = true, .mutation = .switch_composite, .err = error.CompositeChanged, .status = "Composite changed while creating edge" },
        .{ .composite = true, .mutation = .leave_composite, .err = error.CompositeChanged, .status = "Composite changed while creating edge" },
        .{ .composite = true, .mutation = .delete_composite, .err = error.CompositeChanged, .status = "Composite changed while creating edge" },
        .{ .mutation = .client_composite, .err = error.ClientScopeChanged, .status = "Daemon scope changed while creating edge" },
        .{ .composite = true, .mutation = .client_composite, .err = error.ClientScopeChanged, .status = "Daemon scope changed while creating edge" },
        .{ .composite = true, .mutation = .client_composite_lost, .err = error.ClientScopeChanged, .status = "Daemon scope changed while creating edge" },
        .{ .mutation = .delete_source, .err = error.SourceLoopChanged, .status = "Source loop changed while creating edge" },
        .{ .mutation = .delete_target, .err = error.TargetLoopChanged, .status = "Target loop changed while creating edge" },
        .{ .composite = true, .mutation = .delete_source, .err = error.SourceLoopChanged, .status = "Source loop changed while creating edge" },
        .{ .composite = true, .mutation = .delete_target, .err = error.TargetLoopChanged, .status = "Target loop changed while creating edge" },
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |locked| {
            var fixture = try Fixture.init(case.composite);
            defer fixture.deinit();
            var form = FormProbe{ .fixture = &fixture, .locked = locked, .mutation = case.mutation };
            try std.testing.expectError(case.err, EdgeCreation.create(std.testing.allocator, &fixture.model, &fixture.client, selection(locked), &form));
            try std.testing.expect(form.called);
            try std.testing.expectEqualStrings(case.status, EdgeCreation.errorStatus(case.err));
            try std.testing.expectEqual(@as(usize, 0), fixture.client.outbound_count);
            if (case.mutation == .foreign_project)
                try std.testing.expectEqualStrings("D:\\foreign", fixture.client.subscription_path);
            if (case.mutation == .switch_composite or case.mutation == .client_composite)
                try std.testing.expectEqualStrings("group-two", fixture.client.subgraph_node_id);
            if (case.mutation == .foreign_project or case.mutation == .selected_project)
                try std.testing.expectEqualStrings("D:\\foreign", fixture.model.selected_project_path.?);
        }
    }
}

test "edge creation refuses invalid context and missing endpoints before opening the form" {
    for ([_]bool{ false, true }) |composite| {
        var fixture = try Fixture.init(composite);
        defer fixture.deinit();
        var form = FormProbe{ .fixture = &fixture, .locked = true };
        fixture.client.setSubscription("D:\\foreign");
        fixture.client.setSubgraphAddress("different");
        try std.testing.expectError(error.ClientScopeChanged, EdgeCreation.create(std.testing.allocator, &fixture.model, &fixture.client, selection(true), &form));
        fixture.client.setSubgraphAddress(if (composite) "group-one" else null);
        try std.testing.expectError(error.SourceLoopChanged, EdgeCreation.create(std.testing.allocator, &fixture.model, &fixture.client, .{ .from = "missing", .to = "to" }, &form));
        try std.testing.expectError(error.TargetLoopChanged, EdgeCreation.create(std.testing.allocator, &fixture.model, &fixture.client, .{ .from = "from", .to = "missing" }, &form));
        try std.testing.expectError(error.SameEndpoint, EdgeCreation.create(std.testing.allocator, &fixture.model, &fixture.client, .{ .from = "from", .to = "from" }, &form));
        fixture.model.allocator.free(fixture.model.selected_project_path.?);
        fixture.model.selected_project_path = try fixture.model.allocator.dupe(u8, "D:\\foreign");
        try std.testing.expectError(error.ProjectChanged, EdgeCreation.create(std.testing.allocator, &fixture.model, &fixture.client, selection(true), &form));
        fixture.model.allocator.free(fixture.model.selected_project_path.?);
        fixture.model.selected_project_path = null;
        try std.testing.expectError(error.ProjectClosed, EdgeCreation.create(std.testing.allocator, &fixture.model, &fixture.client, selection(true), &form));
        fixture.model.deinit();
        fixture.model = GraphModel.Model.init(std.testing.allocator);
        try std.testing.expectError(error.ProjectClosed, EdgeCreation.create(std.testing.allocator, &fixture.model, &fixture.client, selection(true), &form));
        try std.testing.expect(!form.called);
        try std.testing.expectEqual(@as(usize, 0), fixture.client.outbound_count);
    }
}

test "edge creation allows captured menu choices but rejects changed locked or newly appeared endpoints" {
    for ([_]bool{ false, true }) |composite| {
        for ([_]bool{ false, true }) |locked| {
            for ([_]bool{ false, true }) |new_endpoint| {
                var fixture = try Fixture.init(composite);
                defer fixture.deinit();
                var draft = accepted;
                draft.from = if (new_endpoint) "late" else "third";
                var form = FormProbe{
                    .fixture = &fixture,
                    .locked = locked,
                    .draft = draft,
                    .mutation = if (new_endpoint) .add_endpoint else .none,
                };
                const result = EdgeCreation.create(std.testing.allocator, &fixture.model, &fixture.client, selection(locked), &form);
                if (new_endpoint or locked) {
                    try std.testing.expectError(error.SourceLoopChanged, result);
                    try std.testing.expectEqual(@as(usize, 0), fixture.client.outbound_count);
                } else {
                    try result;
                    try expectCommand(&fixture.client, "C:\\project", if (composite) "group-one" else null, draft);
                }
            }
        }
    }
}

test "edge creation rejects changed locked targets and uncaptured menu targets" {
    for ([_]bool{ false, true }) |locked| {
        var fixture = try Fixture.init(false);
        defer fixture.deinit();
        var draft = accepted;
        draft.to = if (locked) "third" else "late";
        var form = FormProbe{
            .fixture = &fixture,
            .locked = locked,
            .draft = draft,
            .mutation = if (locked) .none else .add_endpoint,
        };
        try std.testing.expectError(error.TargetLoopChanged, EdgeCreation.create(std.testing.allocator, &fixture.model, &fixture.client, selection(locked), &form));
        try std.testing.expectEqual(@as(usize, 0), fixture.client.outbound_count);
    }
}

test "edge creation cancellation form errors and invalid accepted values send nothing" {
    for ([_]bool{ false, true }) |locked| {
        for ([_]Outcome{ .cancel, .form_error, .accept }) |outcome| {
            var fixture = try Fixture.init(false);
            defer fixture.deinit();
            var draft = accepted;
            draft.cycle_max_iterations = 0;
            var form = FormProbe{
                .fixture = &fixture,
                .locked = locked,
                .outcome = outcome,
                .draft = draft,
                .mutation = .refresh,
            };
            const result = EdgeCreation.create(std.testing.allocator, &fixture.model, &fixture.client, selection(locked), &form);
            switch (outcome) {
                .cancel => try result,
                .form_error => try std.testing.expectError(error.FormUnavailable, result),
                .accept => try std.testing.expectError(error.InvalidCycleGuard, result),
            }
            try std.testing.expectEqual(@as(usize, 0), fixture.client.outbound_count);
        }
    }
    try std.testing.expectEqualStrings("Unable to open edge form", EdgeCreation.errorStatus(error.FormUnavailable));
    try std.testing.expectEqualStrings("Invalid edge form", EdgeCreation.errorStatus(error.InvalidCycleGuard));
    try std.testing.expectEqualStrings("Unable to prepare edge form", EdgeCreation.errorStatus(error.OutOfMemory));
}

fn allocationProbe(allocator: std.mem.Allocator, locked: bool, outcome: Outcome, reject: bool) !void {
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    var form = FormProbe{
        .fixture = &fixture,
        .locked = locked,
        .outcome = outcome,
        .mutation = if (reject) .foreign_project else .refresh,
    };
    EdgeCreation.create(allocator, &fixture.model, &fixture.client, selection(locked), &form) catch |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqual(if (outcome == .form_error) error.FormUnavailable else error.ProjectChanged, err);
        try std.testing.expectEqual(@as(usize, 0), fixture.client.outbound_count);
        return;
    };
    try std.testing.expectEqual(@as(usize, if (outcome == .accept) 1 else 0), fixture.client.outbound_count);
}

test "edge creation releases partial snapshot and full accepted draft allocations on every outcome" {
    for ([_]bool{ false, true }) |locked| {
        for ([_]Outcome{ .accept, .cancel, .form_error }) |outcome| {
            try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{ locked, outcome, false });
        }
        try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{ locked, Outcome.accept, true });
    }
}

test "edge creation sender allocation and queue failures remain explicit and send nothing" {
    for ([_]bool{ false, true }) |encoding_failure| {
        var fixture = try Fixture.init(false);
        defer fixture.deinit();
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        if (encoding_failure) fixture.client.allocator = failing.allocator() else fixture.client.stop_worker = true;
        var form = FormProbe{ .fixture = &fixture, .locked = true };
        try EdgeCreation.create(std.testing.allocator, &fixture.model, &fixture.client, selection(true), &form);
        try std.testing.expectEqual(@as(usize, 0), fixture.client.outbound_count);
        try std.testing.expectEqualStrings(if (encoding_failure)
            "create edge command encoding failed"
        else
            "daemon outbound queue is full", fixture.client.statusText());
    }
}

test "edge creation sender cleans up every full command and composite addressing allocation failure" {
    for ([_]bool{ false, true }) |composite| {
        var allocation_count: usize = 0;
        {
            var fixture = try Fixture.init(composite);
            defer fixture.deinit();
            var counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            fixture.client.allocator = counter.allocator();
            var form = FormProbe{ .fixture = &fixture, .locked = true };
            try EdgeCreation.create(std.testing.allocator, &fixture.model, &fixture.client, selection(true), &form);
            try expectCommand(&fixture.client, "C:\\project", if (composite) "group-one" else null, accepted);
            allocation_count = counter.alloc_index;
        }
        for (0..allocation_count) |fail_index| {
            var fixture = try Fixture.init(composite);
            defer fixture.deinit();
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
            fixture.client.allocator = failing.allocator();
            var form = FormProbe{ .fixture = &fixture, .locked = true };
            try EdgeCreation.create(std.testing.allocator, &fixture.model, &fixture.client, selection(true), &form);
            try std.testing.expect(failing.has_induced_failure);
            if (fixture.client.outbound_count == 0) {
                const status = fixture.client.statusText();
                try std.testing.expect(std.mem.eql(u8, status, "create edge command encoding failed") or
                    std.mem.eql(u8, status, "unable to address composite graph command"));
            } else {
                try expectCommand(&fixture.client, "C:\\project", if (composite) "group-one" else null, accepted);
            }
        }
    }
}
