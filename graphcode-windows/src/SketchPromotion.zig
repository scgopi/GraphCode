const std = @import("std");
const GraphModel = @import("GraphModel.zig");

pub const Target = enum { goal, turn, timed };
pub const Interval = enum { quarter_hour, hourly, six_hourly, daily, custom };

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
    goal: []const u8 = "",
    pauses_before_writes_only: bool = false,
    interval: Interval = .hourly,
    custom_interval: []const u8 = "",
    first_instruction: []const u8 = "",
};

pub fn build(allocator: std.mem.Allocator, input: Input) !Draft {
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
            const note = try trim(input.first_instruction, false);
            const task = if (note.len == 0) "Carry on with what this session has been doing." else note;
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
        if (!std.mem.eql(u8, node.loop_type, "sketch")) return error.NotSketch;
        const source = Context{
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
            @field(result, field.name) = try allocator.dupe(u8, @field(source, field.name));
        }
        return result;
    }

    pub const Selection = enum { current_graph, root_project };

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
        if (!std.mem.eql(u8, graph.nodes.items[index].loop_type, self.loop_type)) return error.NotSketch;
        return if (matchesScope(model, self.project_path, "")) .current_graph else .root_project;
    }

    pub fn validateCurrent(self: Context, model: *const GraphModel.Model, client_composite: []const u8) !void {
        if (!matchesScope(model, self.project_path, self.composite_id) or
            !std.mem.eql(u8, client_composite, self.composite_id))
            return error.PromotionContextChanged;
        const graph = model.graph orelse return error.PromotionContextChanged;
        const index = GraphModel.findNodeIndexByID(graph.nodes.items, self.node_id) orelse return error.PromotionNodeMissing;
        if (!std.mem.eql(u8, self.loop_type, "sketch") or
            !std.mem.eql(u8, graph.nodes.items[index].loop_type, self.loop_type))
            return error.NotSketch;
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
