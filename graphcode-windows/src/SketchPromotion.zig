const std = @import("std");
const GraphModel = @import("GraphModel.zig");

pub const Target = enum { goal, turn, timed };
pub const Interval = enum { quarter_hour, hourly, six_hourly, daily, custom };

pub const Source = enum {
    sketch,
    goal,
    timed,

    pub fn fromLoopType(loop_type: []const u8) ?Source {
        if (std.mem.eql(u8, loop_type, "sketch")) return .sketch;
        if (std.mem.eql(u8, loop_type, "goalBased")) return .goal;
        if (std.mem.eql(u8, loop_type, "timeBased")) return .timed;
        return null;
    }

    pub fn retypeTarget(self: Source) ?Target {
        return switch (self) {
            .sketch => null,
            .goal => .timed,
            .timed => .goal,
        };
    }

    pub fn accepts(self: Source, target: Target) bool {
        return switch (self) {
            .sketch => true,
            .goal => target == .timed,
            .timed => target == .goal,
        };
    }
};

/// Owned result: only the target's one decision, never a replacement NodeDraft.
pub const Draft = union(Target) {
    goal: []const u8,
    turn: bool,
    timed: []const u8,

    pub fn deinit(self: *Draft, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .goal, .timed => |text| allocator.free(text),
            .turn => {},
        }
        self.* = .{ .turn = false };
    }
};

pub const Input = struct {
    target: Target,
    source: Source = .sketch,
    goal: []const u8 = "",
    task: []const u8 = "",
    pauses_before_writes_only: bool = false,
    interval: Interval = .hourly,
    custom_interval: []const u8 = "",
    first_instruction: []const u8 = "",
};

pub fn build(allocator: std.mem.Allocator, input: Input) !Draft {
    if (!input.source.accepts(input.target)) return error.InvalidPromotionTarget;
    return switch (input.target) {
        .goal => blk: {
            const summary = try trim(input.goal, true);
            if (summary.len == 0) return error.MissingGoal;
            break :blk .{ .goal = try allocator.dupe(u8, summary) };
        },
        .turn => .{ .turn = input.pauses_before_writes_only },
        .timed => blk: {
            const custom = try trim(input.custom_interval, false);
            const cadence = switch (input.interval) {
                .quarter_hour => "15m",
                .hourly => "1h",
                .six_hourly => "6h",
                .daily => "24h",
                .custom => if (custom.len == 0) "1h" else custom,
            };
            const task = if (input.source == .goal) blk_task: {
                const entered = try trim(input.task, true);
                if (entered.len == 0) return error.MissingTask;
                break :blk_task entered;
            } else blk_task: {
                const note = try trim(input.first_instruction, false);
                break :blk_task if (note.len == 0) "Carry on with what this session has been doing." else note;
            };
            break :blk .{ .timed = try std.fmt.allocPrint(allocator, "/loop {s} {s}", .{ cadence, task }) };
        },
    };
}

pub fn validate(draft: Draft) !void {
    switch (draft) {
        .goal => |text| if ((try trim(text, true)).len == 0) return error.MissingGoal,
        .timed => |text| if ((try trim(text, true)).len == 0) return error.MissingCadence,
        .turn => {},
    }
}

/// Foundation CharacterSet.whitespaces, optionally unioned with .newlines.
pub fn trim(text: []const u8, newlines: bool) ![]const u8 {
    var iterator = (try std.unicode.Utf8View.init(text)).iterator();
    var first: ?usize = null;
    var end: usize = 0;
    while (iterator.nextCodepoint()) |point| {
        const whitespace = switch (point) {
            0x09, 0x20, 0xa0, 0x1680, 0x2000...0x200b, 0x202f, 0x205f, 0x3000 => true,
            0x0a...0x0d, 0x85, 0x2028, 0x2029 => newlines,
            else => false,
        };
        if (!whitespace) {
            if (first == null) first = iterator.i - try std.unicode.utf8CodepointSequenceLength(point);
            end = iterator.i;
        }
    }
    return text[first orelse text.len .. if (first == null) text.len else end];
}

pub const Context = struct {
    project_path: []const u8 = "",
    composite_id: []const u8 = "",
    node_id: []const u8 = "",
    loop_type: []const u8 = "",
    title: []const u8 = "",
    first_instruction: []const u8 = "",
    origin_project_path: []const u8 = "",
    origin_composite_id: []const u8 = "",
    origin_node_id: []const u8 = "",

    pub fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        inline for (std.meta.fields(Context)) |field| allocator.free(@field(self, field.name));
        self.* = .{};
    }

    pub fn capture(
        allocator: std.mem.Allocator,
        model: *const GraphModel.Model,
        project_path: []const u8,
        composite_id: []const u8,
        node: GraphModel.Node,
    ) !Context {
        const source_type = Source.fromLoopType(node.loop_type) orelse return error.NotSketch;
        if (source_type != .sketch and std.mem.eql(u8, node.state, "stopped")) return error.PromotionStopped;
        const captured = Context{
            .project_path = project_path,
            .composite_id = composite_id,
            .node_id = node.id,
            .loop_type = node.loop_type,
            .title = node.title,
            .first_instruction = node.first_instruction,
            .origin_project_path = if (model.graph) |graph| graph.project.path else "",
            .origin_composite_id = model.open_composite_id orelse "",
            .origin_node_id = model.selectedNodeID() orelse "",
        };
        var result = Context{};
        errdefer result.deinit(allocator);
        inline for (std.meta.fields(Context)) |field| {
            @field(result, field.name) = try allocator.dupe(u8, @field(captured, field.name));
        }
        return result;
    }

    pub const Selection = enum { current_graph, root_project };

    pub fn source(self: Context) !Source {
        return Source.fromLoopType(self.loop_type) orelse error.NotSketch;
    }

    pub fn validateTarget(self: Context, target: Target) !void {
        if (!(try self.source()).accepts(target)) return error.InvalidPromotionTarget;
    }

    fn validateNode(self: Context, node: GraphModel.Node) !void {
        const original = try self.source();
        if (!std.mem.eql(u8, node.loop_type, self.loop_type))
            return if (original == .sketch) error.NotSketch else error.PromotionContextChanged;
        if (original != .sketch and std.mem.eql(u8, node.state, "stopped"))
            return error.PromotionStopped;
    }

    /// Validate the popup's original scope before the normal clicked-target selection.
    pub fn selectionPlan(self: Context, model: *const GraphModel.Model, client_composite: []const u8) !Selection {
        if (!matchesScope(model, self.origin_project_path, self.origin_composite_id) or
            !std.mem.eql(u8, client_composite, self.origin_composite_id) or
            !std.mem.eql(u8, model.selectedNodeID() orelse "", self.origin_node_id))
            return error.PromotionContextChanged;
        if (self.composite_id.len != 0) {
            try self.validateCurrent(model, client_composite);
            return .current_graph;
        }
        const graph = model.graphFor(self.project_path) orelse return error.PromotionContextChanged;
        const index = GraphModel.findNodeIndexByID(graph.nodes.items, self.node_id) orelse return error.PromotionNodeMissing;
        try self.validateNode(graph.nodes.items[index]);
        return if (matchesScope(model, self.project_path, "")) .current_graph else .root_project;
    }

    pub fn validateCurrent(self: Context, model: *const GraphModel.Model, client_composite: []const u8) !void {
        if (!matchesScope(model, self.project_path, self.composite_id) or
            !std.mem.eql(u8, client_composite, self.composite_id))
            return error.PromotionContextChanged;
        const graph = model.graph orelse return error.PromotionContextChanged;
        const index = GraphModel.findNodeIndexByID(graph.nodes.items, self.node_id) orelse return error.PromotionNodeMissing;
        try self.validateNode(graph.nodes.items[index]);
    }
};

fn matchesScope(model: *const GraphModel.Model, path: []const u8, composite: []const u8) bool {
    const graph = model.graph orelse return path.len == 0 and composite.len == 0;
    return std.mem.eql(u8, graph.project.path, path) and
        std.mem.eql(u8, model.selected_project_path orelse graph.project.path, path) and
        std.mem.eql(u8, model.open_composite_id orelse "", composite);
}

test "sketch promotion builds only the target decision with macOS cadence defaults" {
    const allocator = std.testing.allocator;
    var goal = try build(allocator, .{ .target = .goal, .goal = "\u{2003}\nDone \"well\" \u{96ea}\u{a0}" });
    defer goal.deinit(allocator);
    try std.testing.expectEqualStrings("Done \"well\" \u{96ea}", goal.goal);
    try std.testing.expectError(error.MissingGoal, build(allocator, .{ .target = .goal, .goal = "\u{200b}\u{2028}\t" }));
    try std.testing.expectError(error.InvalidUtf8, build(allocator, .{ .target = .goal, .goal = "\xff" }));
    for ([_]bool{ false, true }) |pause| {
        const turn = try build(allocator, .{ .target = .turn, .pauses_before_writes_only = pause });
        try std.testing.expectEqual(pause, turn.turn);
    }
    for ([_]Interval{ .quarter_hour, .hourly, .six_hourly, .daily, .custom }, [_][]const u8{ "15m", "1h", "6h", "24h", "1h" }) |interval, cadence| {
        var timed = try build(allocator, .{ .target = .timed, .interval = interval });
        defer timed.deinit(allocator);
        const expected = try std.fmt.allocPrint(allocator, "/loop {s} Carry on with what this session has been doing.", .{cadence});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, timed.timed);
    }
    var custom = try build(allocator, .{ .target = .timed, .interval = .custom, .custom_interval = "\u{a0}not a cadence\u{2003}", .first_instruction = "\t\nwatch \"\u{96ea}\"\n " });
    defer custom.deinit(allocator);
    try std.testing.expectEqualStrings("/loop not a cadence \nwatch \"\u{96ea}\"\n", custom.timed);
}

fn allocationExercise(allocator: std.mem.Allocator, model: *const GraphModel.Model) !void {
    var context = try Context.capture(allocator, model, "A", "group", model.graph.?.nodes.items[0]);
    defer context.deinit(allocator);
    var goal = try build(allocator, .{ .target = .goal, .goal = "done" });
    defer goal.deinit(allocator);
    var timed = try build(allocator, .{ .target = .timed, .first_instruction = context.first_instruction });
    defer timed.deinit(allocator);
}

test "sketch promotion owns every field and frees partial allocations" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"A","name":"A"},"nodes":[{"id":"group","title":"Group","loopType":"proactive","subGraph":{"project":{"path":"A","name":"A"},"nodes":[{"id":"child","title":"Sketch","loopType":"sketch","firstInstruction":" note "}],"edges":[]}}],"edges":[]}}
    );
    try std.testing.expect(model.openComposite("group"));
    try std.testing.expect(model.setSelectedID("child"));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{&model});
}

fn retypeTestFrame(allocator: std.mem.Allocator, loop_type: []const u8, state: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"event":{{"graphChanged":{{"project":{{"path":"A","name":"A"}},"nodes":[{{"id":"target","title":"Target","loopType":"{s}","state":"{s}"}},{{"id":"other","loopType":"sketch","state":"idle"}}],"edges":[]}}}}}}
    , .{ loop_type, state });
}

fn retypeTestModel(allocator: std.mem.Allocator, loop_type: []const u8, state: []const u8) !GraphModel.Model {
    var model = GraphModel.Model.init(allocator);
    errdefer model.deinit();
    const frame = try retypeTestFrame(allocator, loop_type, state);
    defer allocator.free(frame);
    _ = try model.updateFromFrame(frame);
    if (!model.setSelectedID("target")) return error.TestTargetMissing;
    return model;
}

test "canvas retype context admits Goal and Timed in every non-stopped state" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "goalBased", "timeBased" }) |loop_type| {
        for ([_][]const u8{ "idle", "running", "awaitingInput", "blocked", "succeeded", "failed", "stalled", "waiting" }) |state| {
            var model = try retypeTestModel(allocator, loop_type, state);
            defer model.deinit();
            var context = try Context.capture(allocator, &model, "A", "", model.graph.?.nodes.items[0]);
            defer context.deinit(allocator);
            try context.validateCurrent(&model, "");
            try std.testing.expectEqual(Context.Selection.current_graph, try context.selectionPlan(&model, ""));
            const allowed: Target = if (std.mem.eql(u8, loop_type, "goalBased")) .timed else .goal;
            try context.validateTarget(allowed);
            try std.testing.expectError(error.InvalidPromotionTarget, context.validateTarget(.turn));
        }
        var stopped = try retypeTestModel(allocator, loop_type, "stopped");
        defer stopped.deinit();
        try std.testing.expectError(
            error.PromotionStopped,
            Context.capture(allocator, &stopped, "A", "", stopped.graph.?.nodes.items[0]),
        );
    }
    var sketch = try retypeTestModel(allocator, "sketch", "stopped");
    defer sketch.deinit();
    var sketch_context = try Context.capture(allocator, &sketch, "A", "", sketch.graph.?.nodes.items[0]);
    defer sketch_context.deinit(allocator);
    try sketch_context.validateCurrent(&sketch, "");
}

test "canvas retype context rejects stale selection type state and composite scope" {
    const allocator = std.testing.allocator;
    var model = try retypeTestModel(allocator, "goalBased", "running");
    defer model.deinit();
    var context = try Context.capture(allocator, &model, "A", "", model.graph.?.nodes.items[0]);
    defer context.deinit(allocator);
    try std.testing.expect(model.setSelectedID("other"));
    try std.testing.expectError(error.PromotionContextChanged, context.selectionPlan(&model, ""));
    try std.testing.expect(model.setSelectedID("target"));

    const stopped = try retypeTestFrame(allocator, "goalBased", "stopped");
    defer allocator.free(stopped);
    _ = try model.updateFromFrame(stopped);
    try std.testing.expectError(error.PromotionStopped, context.validateCurrent(&model, ""));

    const changed = try retypeTestFrame(allocator, "timeBased", "running");
    defer allocator.free(changed);
    _ = try model.updateFromFrame(changed);
    try std.testing.expectError(error.PromotionContextChanged, context.validateCurrent(&model, ""));

    var nested = GraphModel.Model.init(allocator);
    defer nested.deinit();
    _ = try nested.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"A","name":"A"},"nodes":[{"id":"group","title":"Group","loopType":"proactive","subGraph":{"project":{"path":"A","name":"A"},"nodes":[{"id":"target","loopType":"goalBased","state":"running"}],"edges":[]}}],"edges":[]}}
    );
    try std.testing.expect(nested.openComposite("group"));
    try std.testing.expect(nested.setSelectedID("target"));
    var nested_context = try Context.capture(allocator, &nested, "A", "group", nested.graph.?.nodes.items[0]);
    defer nested_context.deinit(allocator);
    try nested_context.validateCurrent(&nested, "group");
    try std.testing.expectError(error.PromotionContextChanged, nested_context.validateCurrent(&nested, "other"));
    nested.closeComposite();
    try std.testing.expectError(error.PromotionContextChanged, nested_context.validateCurrent(&nested, "group"));
}

test "canvas retype payload requires a new task and keeps sketch fallback" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "", " \t\n", "\u{2003}\u{2028}" }) |task| {
        try std.testing.expectError(error.MissingTask, build(allocator, .{
            .source = .goal,
            .target = .timed,
            .task = task,
            .first_instruction = "old note is not a task",
        }));
    }
    var timed = try build(allocator, .{
        .source = .goal,
        .target = .timed,
        .task = " \u{2003}check \"\u{96ea}\"\n ",
        .interval = .custom,
        .custom_interval = " 45m ",
    });
    defer timed.deinit(allocator);
    try std.testing.expectEqualStrings("/loop 45m check \"\u{96ea}\"", timed.timed);
    var sketch = try build(allocator, .{ .target = .timed });
    defer sketch.deinit(allocator);
    try std.testing.expectEqualStrings("/loop 1h Carry on with what this session has been doing.", sketch.timed);
    try std.testing.expectError(error.InvalidPromotionTarget, build(allocator, .{ .source = .goal, .target = .goal, .goal = "done" }));
    try std.testing.expectError(error.InvalidPromotionTarget, build(allocator, .{ .source = .timed, .target = .turn }));
}

test "canvas retype payload uses existing promote and composite serialization" {
    const allocator = std.testing.allocator;
    const Wire = @import("Wire.zig");
    var timed = try build(allocator, .{ .source = .goal, .target = .timed, .task = "check \"\u{96ea}\"" });
    defer timed.deinit(allocator);
    const command = try Wire.commandGraphPromoteNode(allocator, "A", "target", timed);
    defer allocator.free(command);
    const addressed = try Wire.addressGraphCommandToSubGraph(allocator, command, "group");
    defer allocator.free(addressed);
    try std.testing.expect(std.mem.indexOf(u8, addressed, "\"projectPath\":\"A\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, addressed, "\"subGraphCommand\":{\"nodeID\":\"group\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, addressed, "\"promoteNode\":{\"_0\":\"target\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, addressed, "\"triggerPrompt\":\"/loop 1h check \\\"\u{96ea}\\\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, addressed, "\"promotedBy\":null") != null);
    var goal = try build(allocator, .{ .source = .timed, .target = .goal, .goal = "  Done \n" });
    defer goal.deinit(allocator);
    const goal_command = try Wire.commandGraphPromoteNode(allocator, "A", "target", goal);
    defer allocator.free(goal_command);
    try std.testing.expect(std.mem.indexOf(u8, goal_command, "\"summary\":\"Done\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, goal_command, "\"promotedBy\":null") != null);
}
