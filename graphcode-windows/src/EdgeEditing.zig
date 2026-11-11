const std = @import("std");
const Forms = @import("Forms.zig");
const GraphModel = @import("GraphModel.zig");
const DaemonClient = @import("DaemonClient.zig").DaemonClient;
const Diagnostics = @import("Diagnostics.zig");

pub const Modal = struct {
    context: ?*anyopaque = null,
    show: *const fn (?*anyopaque, std.mem.Allocator, Forms.EdgeDraft) anyerror!?Forms.EdgeDraft,
};

pub const Result = enum { cancelled, unchanged, queued };

const Scope = struct {
    project: []u8,
    composite: []u8,

    fn capture(allocator: std.mem.Allocator, model: *const GraphModel.Model, client: *const DaemonClient) !Scope {
        const selected = model.selected_project_path orelse return error.StaleScope;
        const result = Scope{
            .project = try allocator.dupe(u8, selected),
            .composite = undefined,
        };
        var owned = result;
        errdefer allocator.free(owned.project);
        owned.composite = try allocator.dupe(u8, model.open_composite_id orelse "");
        errdefer allocator.free(owned.composite);
        try owned.check(model, client);
        return owned;
    }

    fn deinit(self: Scope, allocator: std.mem.Allocator) void {
        allocator.free(self.project);
        allocator.free(self.composite);
    }

    fn check(self: Scope, model: *const GraphModel.Model, client: *const DaemonClient) !void {
        const selected = model.selected_project_path orelse return error.StaleScope;
        const graph = model.graph orelse return error.StaleScope;
        const cached = model.currentGraph() orelse return error.StaleScope;
        if (!std.mem.eql(u8, self.project, selected) or
            !std.mem.eql(u8, self.project, graph.project.path) or
            !std.mem.eql(u8, self.project, cached.project.path) or
            !std.mem.eql(u8, self.composite, model.open_composite_id orelse "") or
            !std.mem.eql(u8, self.composite, client.subgraph_node_id)) return error.StaleScope;
    }
};

fn sameEdgeConfiguration(a: GraphModel.Edge, b: GraphModel.Edge) bool {
    return a.editable_configuration and b.editable_configuration and
        std.mem.eql(u8, a.id, b.id) and std.mem.eql(u8, a.from, b.from) and std.mem.eql(u8, a.to, b.to) and
        Forms.EdgeConfiguration.eql(Forms.EdgeConfiguration.fromEdge(a), Forms.EdgeConfiguration.fromEdge(b));
}

fn checkCurrentEdge(allocator: std.mem.Allocator, model: *const GraphModel.Model, original: GraphModel.Edge) !void {
    const graph = model.graph orelse return error.StaleScope;
    const index = GraphModel.findEdgeIndexByID(graph.edges.items, original.id) orelse return error.StaleEdge;
    if (!sameEdgeConfiguration(original, graph.edges.items[index])) return error.StaleEdge;
    if (GraphModel.findNodeIndexByID(graph.nodes.items, original.from) == null) return error.MissingSource;
    if (GraphModel.findNodeIndexByID(graph.nodes.items, original.to) == null) return error.MissingTarget;
    const cached = try GraphModel.copyCachedEdgeForEditing(allocator, model, original.id);
    defer GraphModel.freeEdge(allocator, cached);
    if (!sameEdgeConfiguration(original, cached)) return error.StaleEdge;
}

pub fn edit(allocator: std.mem.Allocator, model: *GraphModel.Model, client: *DaemonClient, index: usize, modal: Modal) !Result {
    var receipt = Diagnostics.EdgeActionTrace.Event{
        .stage = .guard_entry,
        .project = Diagnostics.EdgeActionTrace.Identity.from(model.selected_project_path orelse ""),
        .index = index,
        .guard = "scope",
    };
    var modal_entered = false;
    Diagnostics.traceEdgeAction(receipt);
    errdefer |err| {
        receipt.stage = .guard_refused;
        receipt.reason = @errorName(err);
        receipt.outcome = if (modal_entered) "after_modal" else "before_modal";
        Diagnostics.traceEdgeAction(receipt);
    }
    const scope = try Scope.capture(allocator, model, client);
    defer scope.deinit(allocator);
    receipt.guard = "graph";
    const graph = model.graph orelse return error.MissingGraph;
    receipt.guard = "index";
    if (index >= graph.edges.items.len) return error.MissingEdge;
    receipt.guard = "clone";
    const edge = try GraphModel.cloneEdge(allocator, graph.edges.items[index]);
    defer GraphModel.freeEdge(allocator, edge);
    receipt.edge = Diagnostics.EdgeActionTrace.Identity.from(edge.id);
    receipt.guard = "identity";
    if (edge.id.len == 0) return error.MissingEdgeIdentity;
    receipt.guard = "editable";
    if (!edge.editable_configuration) return error.UnsupportedEdgeConfiguration;
    receipt.guard = "current";
    try checkCurrentEdge(allocator, model, edge);
    const expected = Forms.EdgeConfiguration.fromEdge(edge);
    const initial = expected.draft(edge.from, edge.to);
    receipt.guard = "validate";
    try Forms.validateEdgeEdit(initial, initial);
    receipt.stage = .guards_passed;
    Diagnostics.traceEdgeAction(receipt);
    receipt.stage = .modal_show;
    receipt.guard = "show";
    Diagnostics.traceEdgeAction(receipt);
    modal_entered = true;
    const shown = try modal.show(modal.context, allocator, initial);
    receipt.stage = .modal_return;
    receipt.outcome = if (shown == null) "cancelled" else "submitted";
    Diagnostics.traceEdgeAction(receipt);
    var draft = shown orelse return .cancelled;
    defer draft.deinit(allocator);
    receipt.guard = "scope_recheck";
    try scope.check(model, client);
    receipt.guard = "current_recheck";
    try checkCurrentEdge(allocator, model, edge);
    receipt.guard = "validate_recheck";
    try Forms.validateEdgeEdit(initial, draft);
    const replacement = expected.applying(draft);
    if (Forms.EdgeConfiguration.eql(expected, replacement)) return .unchanged;
    receipt.guard = "queue";
    try client.sendUpdateEdge(scope.project, edge.id, edge.from, edge.to, expected, replacement, scope.composite);
    return .queued;
}

const fixture =
    \\{"event":{"graphChanged":{"project":{"path":"A","name":"A"},"nodes":[{"id":"11111111-1111-4111-8111-111111111111","title":"Source"},{"id":"22222222-2222-4222-8222-222222222222","title":"Target"}],"edges":[{"id":"33333333-3333-4333-8333-333333333333","from":"11111111-1111-4111-8111-111111111111","to":"22222222-2222-4222-8222-222222222222","kind":"handoff","condition":"onFailure","fireCount":4,"cycleGuard":{"maxIterations":8,"until":"say \"done\""},"payloadTransform":{"template":{"_0":"quoted \"payload\" \u2603"}},"spawnTargetProjectPath":"C:\\target"}]}}}
;

fn loadFixture(model: *GraphModel.Model) !void {
    _ = try model.updateFromFrame(fixture);
}

test "edge editing diagnostic reports guard refusal without opening the modal" {
    const Probe = struct {
        var events: [8]Diagnostics.EdgeActionTrace.Event = undefined;
        var count: usize = 0;
        var modal_calls: usize = 0;

        fn observe(event: Diagnostics.EdgeActionTrace.Event) void {
            if (count < events.len) events[count] = event;
            count += 1;
        }

        fn show(_: ?*anyopaque, _: std.mem.Allocator, _: Forms.EdgeDraft) !?Forms.EdgeDraft {
            modal_calls += 1;
            return null;
        }
    };
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    try loadFixture(&model);
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    Diagnostics.edge_action_test_observer = Probe.observe;
    defer Diagnostics.edge_action_test_observer = null;
    Probe.count = 0;
    Probe.modal_calls = 0;
    try std.testing.expectError(error.MissingEdge, edit(std.testing.allocator, &model, &client, 99, .{ .show = Probe.show }));
    try std.testing.expectEqual(@as(usize, 0), Probe.modal_calls);
    try std.testing.expectEqual(@as(usize, 0), client.outbound_count);
    try std.testing.expectEqual(@as(usize, 2), Probe.count);
    try std.testing.expectEqual(Diagnostics.EdgeActionTrace.Stage.guard_entry, Probe.events[0].stage);
    try std.testing.expectEqual(Diagnostics.EdgeActionTrace.Stage.guard_refused, Probe.events[1].stage);
    try std.testing.expectEqualStrings("index", Probe.events[1].guard);
    try std.testing.expectEqualStrings("MissingEdge", Probe.events[1].reason);
    try std.testing.expectEqualStrings("before_modal", Probe.events[1].outcome);
}

test "edge editing diagnostic records guards and show entry without changing cancellation" {
    const Probe = struct {
        var stages: [8]Diagnostics.EdgeActionTrace.Stage = undefined;
        var count: usize = 0;
        var modal_calls: usize = 0;

        fn observe(event: Diagnostics.EdgeActionTrace.Event) void {
            if (count < stages.len) stages[count] = event.stage;
            count += 1;
        }

        fn show(_: ?*anyopaque, _: std.mem.Allocator, _: Forms.EdgeDraft) !?Forms.EdgeDraft {
            try std.testing.expectEqual(@as(usize, 3), count);
            try std.testing.expectEqual(Diagnostics.EdgeActionTrace.Stage.modal_show, stages[2]);
            modal_calls += 1;
            return null;
        }
    };
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    try loadFixture(&model);
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    Diagnostics.edge_action_test_observer = Probe.observe;
    defer Diagnostics.edge_action_test_observer = null;
    Probe.count = 0;
    Probe.modal_calls = 0;
    try std.testing.expectEqual(Result.cancelled, try edit(std.testing.allocator, &model, &client, 0, .{ .show = Probe.show }));
    try std.testing.expectEqual(@as(usize, 1), Probe.modal_calls);
    try std.testing.expectEqual(@as(usize, 0), client.outbound_count);
    try std.testing.expectEqual(@as(usize, 4), Probe.count);
    try std.testing.expectEqualSlices(Diagnostics.EdgeActionTrace.Stage, &.{ .guard_entry, .guards_passed, .modal_show, .modal_return }, Probe.stages[0..Probe.count]);
}

fn acceptKind(_: ?*anyopaque, allocator: std.mem.Allocator, initial: Forms.EdgeDraft) !?Forms.EdgeDraft {
    const from = try allocator.dupe(u8, initial.from);
    errdefer allocator.free(from);
    const to = try allocator.dupe(u8, initial.to);
    errdefer allocator.free(to);
    const kind = try allocator.dupe(u8, "message");
    errdefer allocator.free(kind);
    const condition = try allocator.dupe(u8, "always");
    errdefer allocator.free(condition);
    return .{ .from = from, .to = to, .kind = kind, .condition = condition, .transform_kind = try allocator.dupe(u8, "none") };
}

test "edge editing: existing condition reaches production modal callback" {
    const Probe = struct {
        fn show(_: ?*anyopaque, _: std.mem.Allocator, initial: Forms.EdgeDraft) !?Forms.EdgeDraft {
            try std.testing.expectEqualStrings("onFailure", initial.condition);
            return null;
        }
    };
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    try loadFixture(&model);
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    try std.testing.expectEqual(Result.cancelled, try edit(std.testing.allocator, &model, &client, 0, .{ .show = Probe.show }));
    try std.testing.expectEqual(@as(usize, 0), client.outbound_count);
}

test "edge editing: one identity preserving update enters real queue" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    try loadFixture(&model);
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    try std.testing.expectEqual(Result.queued, try edit(std.testing.allocator, &model, &client, 0, .{ .show = acceptKind }));
    try std.testing.expectEqual(@as(usize, 1), client.outbound_count);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, client.outbound[client.outbound_head], .{});
    defer parsed.deinit();
    const command = parsed.value.object.get("graphCommand").?.object.get("command").?.object;
    try std.testing.expect(command.contains("updateEdge"));
    try std.testing.expect(!command.contains("deleteEdge") and !command.contains("createEdge"));
    try std.testing.expectEqualStrings("33333333-3333-4333-8333-333333333333", command.get("updateEdge").?.object.get("id").?.string);
}

test "edge editing: foreign selected project cannot reuse identical edge IDs" {
    const Probe = struct {
        fn show(context: ?*anyopaque, allocator: std.mem.Allocator, initial: Forms.EdgeDraft) !?Forms.EdgeDraft {
            const model: *GraphModel.Model = @ptrCast(@alignCast(context.?));
            const other = try std.mem.replaceOwned(u8, allocator, fixture, "\"A\"", "\"B\"");
            defer allocator.free(other);
            _ = try model.updateFromFrame(other);
            try std.testing.expect(model.selectProject("B"));
            return acceptKind(null, allocator, initial);
        }
    };
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    try loadFixture(&model);
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    try std.testing.expectError(error.StaleScope, edit(std.testing.allocator, &model, &client, 0, .{ .context = &model, .show = Probe.show }));
    try std.testing.expectEqual(@as(usize, 0), client.outbound_count);
}

test "edge editing: returned full owned draft is released" {
    const Probe = struct {
        fn show(_: ?*anyopaque, allocator: std.mem.Allocator, initial: Forms.EdgeDraft) !?Forms.EdgeDraft {
            var draft = Forms.EdgeDraft{ .from = &.{}, .to = &.{}, .kind = &.{}, .condition = &.{}, .transform_kind = &.{}, .transform_value = &.{}, .cycle_until = &.{}, .spawn_target_project_path = &.{} };
            errdefer draft.deinit(allocator);
            draft.from = try allocator.dupe(u8, initial.from);
            draft.to = try allocator.dupe(u8, initial.to);
            draft.kind = try allocator.dupe(u8, "message");
            draft.condition = try allocator.dupe(u8, "onSuccess");
            draft.transform_kind = try allocator.dupe(u8, "template");
            draft.transform_value = try allocator.dupe(u8, "payload");
            draft.cycle_until = try allocator.dupe(u8, "until");
            draft.spawn_target_project_path = try allocator.dupe(u8, "target");
            return draft;
        }
    };
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    try loadFixture(&model);
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    _ = try edit(std.testing.allocator, &model, &client, 0, .{ .show = Probe.show });
}

fn changeKind(_: ?*anyopaque, allocator: std.mem.Allocator, initial: Forms.EdgeDraft) !?Forms.EdgeDraft {
    var draft = try initial.clone(allocator);
    errdefer draft.deinit(allocator);
    const kind = try allocator.dupe(u8, "message");
    allocator.free(draft.kind);
    draft.kind = kind;
    return draft;
}

fn queuedUpdate(client: *DaemonClient, allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    try std.testing.expectEqual(@as(usize, 1), client.outbound_count);
    return std.json.parseFromSlice(std.json.Value, allocator, client.outbound[client.outbound_head], .{});
}

test "edge editing: actual wire retains full config and optional legacy guard shapes" {
    for ([_][]const u8{
        "null",                                                                          "{}",                                                                                           "{\"until\":null}", "{\"until\":\"\"}",
        "{\"maxIterations\":-3,\"until\":\"\",\"stopAfterPassesWithoutImprovement\":0}", "{\"maxIterations\":8,\"until\":\"say \\\"done\\\"\",\"stopAfterPassesWithoutImprovement\":2}",
    }) |guard| {
        const allocator = std.testing.allocator;
        var model = GraphModel.Model.init(allocator);
        defer model.deinit();
        const frame = try std.mem.replaceOwned(u8, allocator, fixture, "{\"maxIterations\":8,\"until\":\"say \\\"done\\\"\"}", guard);
        defer allocator.free(frame);
        _ = try model.updateFromFrame(frame);
        var client = try DaemonClient.initForTesting(allocator);
        defer client.deinit();
        _ = try edit(allocator, &model, &client, 0, .{ .show = changeKind });
        const parsed = try queuedUpdate(&client, allocator);
        defer parsed.deinit();
        const update = parsed.value.object.get("graphCommand").?.object.get("command").?.object.get("updateEdge").?.object;
        const expected = update.get("expectedSpec").?.object;
        const replacement = update.get("spec").?.object;
        try std.testing.expectEqualStrings("onFailure", replacement.get("condition").?.string);
        try std.testing.expectEqualStrings("quoted \"payload\" \xe2\x98\x83", replacement.get("payloadTransform").?.object.get("template").?.object.get("_0").?.string);
        try std.testing.expectEqualStrings("C:\\target", replacement.get("spawnTargetProjectPath").?.string);
        const before = try std.json.Stringify.valueAlloc(allocator, expected.get("cycleGuard").?, .{});
        defer allocator.free(before);
        const after = try std.json.Stringify.valueAlloc(allocator, replacement.get("cycleGuard").?, .{});
        defer allocator.free(after);
        try std.testing.expectEqualStrings(before, after);
        try std.testing.expect(!update.contains("fireCount") and !replacement.contains("fireCount"));
        try std.testing.expectEqual(@as(i64, 4), model.graph.?.edges.items[0].fire_count);
    }
}

test "edge editing: cancellation unchanged errors invalid endpoints and queue refusal send nothing" {
    const Case = enum { cancel, unchanged, modal_error, endpoint, invalid, stopped, full };
    const Probe = struct {
        fn show(context: ?*anyopaque, allocator: std.mem.Allocator, initial: Forms.EdgeDraft) !?Forms.EdgeDraft {
            const action: *const Case = @ptrCast(@alignCast(context.?));
            if (action.* == .cancel) return null;
            if (action.* == .modal_error) return error.FormFailure;
            var draft = try initial.clone(allocator);
            errdefer draft.deinit(allocator);
            if (action.* == .endpoint) {
                const value = try allocator.dupe(u8, "foreign");
                allocator.free(draft.to);
                draft.to = value;
            } else if (action.* == .invalid) {
                draft.cycle_max_iterations = -1;
            } else if (action.* == .stopped or action.* == .full) {
                const value = try allocator.dupe(u8, "message");
                allocator.free(draft.kind);
                draft.kind = value;
            }
            return draft;
        }
    };
    for (std.enums.values(Case)) |action_value| {
        var action = action_value;
        const allocator = std.testing.allocator;
        var model = GraphModel.Model.init(allocator);
        defer model.deinit();
        try loadFixture(&model);
        var client = try DaemonClient.initForTesting(allocator);
        defer client.deinit();
        if (action == .stopped) client.stop_worker = true;
        if (action == .full) {
            const edge = model.graph.?.edges.items[0];
            const config = Forms.EdgeConfiguration.fromEdge(edge);
            for (0..client.outbound.len) |_| try client.sendUpdateEdge("A", edge.id, edge.from, edge.to, config, config, "");
        }
        const before = client.outbound_count;
        const result = edit(allocator, &model, &client, 0, .{ .context = &action, .show = Probe.show });
        switch (action) {
            .cancel => try std.testing.expectEqual(Result.cancelled, try result),
            .unchanged => try std.testing.expectEqual(Result.unchanged, try result),
            .modal_error => try std.testing.expectError(error.FormFailure, result),
            .endpoint => try std.testing.expectError(error.ChangedEdgeEndpoints, result),
            .invalid => try std.testing.expectError(error.InvalidCycleGuard, result),
            .stopped, .full => try std.testing.expectError(error.OutboundQueueRejected, result),
        }
        try std.testing.expectEqual(before, client.outbound_count);
    }
}

test "edge editing: refresh frees source storage and runtime progress is not a config conflict" {
    const Probe = struct {
        fn show(context: ?*anyopaque, allocator: std.mem.Allocator, initial: Forms.EdgeDraft) !?Forms.EdgeDraft {
            const model: *GraphModel.Model = @ptrCast(@alignCast(context.?));
            const next = try std.mem.replaceOwned(u8, allocator, fixture, "\"fireCount\":4", "\"fireCount\":5");
            defer allocator.free(next);
            _ = try model.updateFromFrame(next);
            try std.testing.expectEqualStrings("onFailure", initial.condition);
            try std.testing.expectEqualStrings("quoted \"payload\" \xe2\x98\x83", initial.transform_value);
            return changeKind(null, allocator, initial);
        }
    };
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    try loadFixture(&model);
    var client = try DaemonClient.initForTesting(std.testing.allocator);
    defer client.deinit();
    _ = try edit(std.testing.allocator, &model, &client, 0, .{ .context = &model, .show = Probe.show });
    try std.testing.expectEqual(@as(i64, 5), model.graph.?.edges.items[0].fire_count);
    try std.testing.expectEqual(@as(usize, 1), client.outbound_count);
}

test "edge editing: current cache changes and missing endpoints cannot hide behind a display clone" {
    const Probe = struct {
        model: *GraphModel.Model,
        mode: enum { config, edge, endpoint },
        fn show(context: ?*anyopaque, allocator: std.mem.Allocator, initial: Forms.EdgeDraft) !?Forms.EdgeDraft {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const cached = &self.model.graphs.items[0];
            switch (self.mode) {
                .config => {
                    const value = try self.model.allocator.dupe(u8, "always");
                    self.model.allocator.free(cached.edges.items[0].condition);
                    cached.edges.items[0].condition = value;
                },
                .edge => {
                    GraphModel.freeEdge(self.model.allocator, cached.edges.orderedRemove(0));
                },
                .endpoint => {
                    self.model.allocator.free(cached.nodes.items[1].id);
                    cached.nodes.items[1].id = try self.model.allocator.dupe(u8, "gone");
                },
            }
            return changeKind(null, allocator, initial);
        }
    };
    for (std.enums.values(@FieldType(Probe, "mode"))) |mode| {
        var model = GraphModel.Model.init(std.testing.allocator);
        defer model.deinit();
        try loadFixture(&model);
        var client = try DaemonClient.initForTesting(std.testing.allocator);
        defer client.deinit();
        var probe = Probe{ .model = &model, .mode = mode };
        try std.testing.expectError(if (mode == .endpoint) error.MissingTarget else error.StaleEdge, edit(std.testing.allocator, &model, &client, 0, .{ .context = &probe, .show = Probe.show }));
        try std.testing.expectEqual(@as(usize, 0), client.outbound_count);
    }
}

test "edge editing: cached B may be edited while observation subscription stays A" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    try loadFixture(&model);
    const other = try std.mem.replaceOwned(u8, allocator, fixture, "\"A\"", "\"B\"");
    defer allocator.free(other);
    _ = try model.updateFromFrame(other);
    try std.testing.expect(model.selectProject("B"));
    var client = try DaemonClient.initForTesting(allocator);
    defer client.deinit();
    client.subscription_path = try allocator.dupe(u8, "A");
    _ = try edit(allocator, &model, &client, 0, .{ .show = changeKind });
    const parsed = try queuedUpdate(&client, allocator);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("B", parsed.value.object.get("graphCommand").?.object.get("projectPath").?.string);
    try std.testing.expectEqualStrings("A", client.subscription_path);
    try std.testing.expectEqualStrings("B", model.selected_project_path.?);
}

fn loadCompositeFixture(model: *GraphModel.Model) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, model.allocator, fixture, .{});
    defer parsed.deinit();
    const child = try std.json.Stringify.valueAlloc(model.allocator, parsed.value.object.get("event").?.object.get("graphChanged").?, .{});
    defer model.allocator.free(child);
    const frame = try std.fmt.allocPrint(model.allocator, "{{\"event\":{{\"graphChanged\":{{\"project\":{{\"path\":\"A\",\"name\":\"A\"}},\"nodes\":[{{\"id\":\"p\",\"loopType\":\"composite\",\"subGraph\":{s}}},{{\"id\":\"q\",\"loopType\":\"composite\",\"subGraph\":{s}}}],\"edges\":[]}}}}}}", .{ child, child });
    defer model.allocator.free(frame);
    _ = try model.updateFromFrame(frame);
    try std.testing.expect(model.openComposite("p"));
}

test "edge editing: direct composite addressing survives refresh but rejects changed scope and client address" {
    const Probe = struct {
        model: *GraphModel.Model,
        client: *DaemonClient,
        mode: enum { refresh, foreign_composite, client_address },
        fn show(context: ?*anyopaque, allocator: std.mem.Allocator, initial: Forms.EdgeDraft) !?Forms.EdgeDraft {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            switch (self.mode) {
                .refresh => try loadCompositeFixture(self.model),
                .foreign_composite => {
                    try std.testing.expect(self.model.openComposite("q"));
                    self.client.setSubgraphAddress("q");
                },
                .client_address => self.client.setSubgraphAddress(null),
            }
            return changeKind(null, allocator, initial);
        }
    };
    for (std.enums.values(@FieldType(Probe, "mode"))) |mode| {
        const allocator = std.testing.allocator;
        var model = GraphModel.Model.init(allocator);
        defer model.deinit();
        try loadCompositeFixture(&model);
        var client = try DaemonClient.initForTesting(allocator);
        defer client.deinit();
        client.setSubgraphAddress("p");
        var probe = Probe{ .model = &model, .client = &client, .mode = mode };
        const result = edit(allocator, &model, &client, 0, .{ .context = &probe, .show = Probe.show });
        if (mode != .refresh) {
            try std.testing.expectError(error.StaleScope, result);
            try std.testing.expectEqual(@as(usize, 0), client.outbound_count);
        } else {
            try std.testing.expectEqual(Result.queued, try result);
            const parsed = try queuedUpdate(&client, allocator);
            defer parsed.deinit();
            const subgraph = parsed.value.object.get("graphCommand").?.object.get("command").?.object.get("subGraphCommand").?.object;
            try std.testing.expectEqualStrings("p", subgraph.get("nodeID").?.string);
            try std.testing.expect(subgraph.get("command").?.object.contains("updateEdge"));
        }
    }
}

test "edge editing: every snapshot draft encoding and composite wrapper allocation unwinds" {
    const Probe = struct {
        fn run(allocator: std.mem.Allocator, composite: bool) !void {
            var model = GraphModel.Model.init(std.testing.allocator);
            defer model.deinit();
            if (composite) try loadCompositeFixture(&model) else try loadFixture(&model);
            var client = try DaemonClient.initForTesting(allocator);
            defer client.deinit();
            if (composite) client.subgraph_node_id = try allocator.dupe(u8, "p");
            _ = try edit(allocator, &model, &client, 0, .{ .show = changeKind });
            try std.testing.expectEqual(@as(usize, 1), client.outbound_count);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{true});
}
