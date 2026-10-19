const std = @import("std");

// Source: graphcode/Sources/Features/Canvas/LaneLayout.swift and SubGraphLayout.swift;
// overview furniture: graphcode/Sources/Features/Overview/GraphOverview.swift.
pub const Point = struct { x: f32 = 0, y: f32 = 0 };
pub const Slot = struct {
    column: usize = 0,
    row: usize = 0,
    sub_column: usize = 0,
    is_loose: bool = false,
};
pub const Role = enum { interior, entry, cycle_only, unwired };

pub const MacMetrics = struct {
    pub const card_width: f32 = 250;
    pub const card_height: f32 = 96;
    pub const column_gap: f32 = 40;
    pub const depth_gap: f32 = 140;
    pub const busy_depth_gap: f32 = 230;
    pub const row_gap: f32 = 24;
    pub const columns = 4;
    pub const minimum_row_budget = 3;
    pub const maximum_columns_per_level = 8;
    pub const maximum_rows_per_level = 5;
    pub const column_width = card_width + column_gap;
    pub const depth_width = card_width + depth_gap;
    pub const row_height = card_height + row_gap;
    pub const band_x: f32 = 80;
    pub const lane_top: f32 = 62;
    pub const padding: f32 = 20;
    pub const caption_height: f32 = 18;
    pub const origin_lane: f32 = 62;
    pub const lane_gap: f32 = 24;
    pub const default_fit_floor: f32 = 0.8;
    pub const first_loop_x = band_x + padding + origin_lane + card_width / 2;
    pub const first_row_inset = caption_height + padding + card_height / 2;
    pub const origin = Point{ .x = first_loop_x, .y = lane_top + first_row_inset };

    pub fn rowBudget(height: f32) usize {
        const usable = height / default_fit_floor - (lane_top + caption_height + padding * 2);
        return @intFromFloat(@max(minimum_row_budget, @trunc(usable / row_height)));
    }

    pub fn rowsPerLevel(budget: usize) usize {
        return @max(1, @min(budget, maximum_rows_per_level));
    }

    pub fn bandWidth(content_width: f32) f32 {
        return padding * 2 + origin_lane + @max(content_width, card_width);
    }

    pub fn bandHeight(rows: usize) f32 {
        return caption_height + padding * 2 + @as(f32, @floatFromInt(@max(1, rows))) * card_height +
            @as(f32, @floatFromInt(@max(1, rows) - 1)) * row_gap;
    }
};

pub const Options = struct {
    origin: Point = MacMetrics.origin,
    row_height: f32 = MacMetrics.row_height,
    row_budget: usize = MacMetrics.maximum_rows_per_level,
    order: []const []const u8 = &.{},
    declared_entries: []const []const u8 = &.{},
};

/// Output arrays follow the input node indices, never arrival-index geometry.
/// IDs and graph values stay with the caller; all output storage is owned here.
pub const Layout = struct {
    allocator: std.mem.Allocator,
    slots: []Slot,
    positions: []Point,
    roles: []Role,
    depth_offsets: [MacMetrics.columns]f32 = .{ 0, 0, 0, 0 },
    row_count: usize = 1,
    content_width: f32 = MacMetrics.card_width,

    pub fn deinit(self: *Layout) void {
        self.allocator.free(self.slots);
        self.allocator.free(self.positions);
        self.allocator.free(self.roles);
        self.* = undefined;
    }
};

const TestNode = struct { id: []const u8 };
const TestEdge = struct {
    from: []const u8,
    to: []const u8,
    kind: []const u8 = "handoff",
};

pub fn init(allocator: std.mem.Allocator, node_input: anytype, edge_input: anytype, options: Options) !Layout {
    const nodes: []const std.meta.Elem(@TypeOf(node_input)) = node_input;
    const edges: []const std.meta.Elem(@TypeOf(edge_input)) = edge_input;
    if (!std.math.isFinite(options.origin.x) or !std.math.isFinite(options.origin.y) or
        !std.math.isFinite(options.row_height) or options.row_height < MacMetrics.card_height)
        return error.InvalidLayoutMetrics;
    const slots = try allocator.alloc(Slot, nodes.len);
    errdefer allocator.free(slots);
    @memset(slots, .{});
    const positions = try allocator.alloc(Point, nodes.len);
    errdefer allocator.free(positions);
    const roles = try allocator.alloc(Role, nodes.len);
    errdefer allocator.free(roles);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const temp = scratch.allocator();
    var indices = std.StringHashMap(usize).init(temp);
    for (nodes, 0..) |_, index| {
        const entry = try indices.getOrPut(nodes[index].id);
        if (entry.found_existing) return error.DuplicateGraphNodeID;
        entry.value_ptr.* = index;
    }
    const ranked = try temp.alloc(usize, nodes.len);
    const seen = try temp.alloc(bool, nodes.len);
    @memset(seen, false);
    var rank_count: usize = 0;
    for (options.order) |id| {
        const index = indices.get(id) orelse continue;
        if (seen[index]) continue;
        seen[index] = true;
        ranked[rank_count] = index;
        rank_count += 1;
    }
    for (nodes, 0..) |_, index| {
        if (seen[index]) continue;
        ranked[rank_count] = index;
        rank_count += 1;
    }

    var touched = std.StringHashMap(void).init(temp);
    var targeted = std.StringHashMap(void).init(temp);
    for (edges) |edge| {
        try touched.put(edge.from, {});
        try touched.put(edge.to, {});
        if (sequencing(edge)) try targeted.put(edge.to, {});
    }
    // LoopGraph.cycleOnlyNodeIDs is sequencing-edge reachability, not SCC
    // decomposition. Declaring a card an entry overrides its badge, not that walk.
    var reached = std.StringHashMap(void).init(temp);
    var frontier = std.array_list.Managed([]const u8).init(temp);
    for (nodes) |node| {
        if (touched.contains(node.id) and !targeted.contains(node.id)) {
            try reached.put(node.id, {});
            try frontier.append(node.id);
        }
    }
    while (frontier.pop()) |id| {
        for (edges) |edge| {
            if (!sequencing(edge) or !std.mem.eql(u8, id, edge.from) or reached.contains(edge.to)) continue;
            try reached.put(edge.to, {});
            try frontier.append(edge.to);
        }
    }
    for (nodes, 0..) |node, index| {
        roles[index] = if (containsID(options.declared_entries, node.id))
            .entry
        else if (!touched.contains(node.id))
            .unwired
        else if (!reached.contains(node.id))
            .cycle_only
        else if (!targeted.contains(node.id))
            .entry
        else
            .interior;
    }

    var depths = std.StringHashMap(usize).init(temp);
    frontier.clearRetainingCapacity();
    for (ranked) |index| {
        if (roles[index] != .entry and roles[index] != .unwired) continue;
        try depths.put(nodes[index].id, 0);
        try frontier.append(nodes[index].id);
    }
    // Like Swift, the capped longest walk reads ALL edge kinds. It also
    // traverses missing endpoints; placement itself only draws existing nodes.
    while (frontier.pop()) |id| {
        const next = (depths.get(id) orelse 0) + 1;
        if (next >= MacMetrics.columns) continue;
        for (edges) |edge| {
            if (!std.mem.eql(u8, edge.from, id)) continue;
            if (depths.get(edge.to)) |depth| {
                if (depth >= next) continue;
            }
            try depths.put(edge.to, next);
            try frontier.append(edge.to);
        }
    }

    const placed = try temp.alloc(bool, nodes.len);
    const parents = try temp.alloc(?usize, nodes.len);
    @memset(placed, false);
    @memset(parents, null);
    const Frame = struct { index: usize, row: usize, next_child: usize = 0 };
    var stack = std.array_list.Managed(Frame).init(temp);
    try stack.ensureTotalCapacity(nodes.len);
    var next_row: usize = 0;
    for (0..2) |pass| {
        for (ranked) |start| {
            if (placed[start] or !touched.contains(nodes[start].id)) continue;
            if (pass == 0 and roles[start] != .entry and roles[start] != .unwired) continue;
            while (rowTaken(slots, placed, next_row, null)) next_row += 1;
            slots[start] = .{ .column = @min(depths.get(nodes[start].id) orelse 0, MacMetrics.columns - 1), .row = next_row };
            placed[start] = true;
            stack.appendAssumeCapacity(.{ .index = start, .row = next_row });
            while (stack.items.len > 0) {
                const frame = &stack.items[stack.items.len - 1];
                if (frame.next_child == ranked.len) {
                    _ = stack.pop();
                    continue;
                }
                const child = ranked[frame.next_child];
                frame.next_child += 1;
                if (placed[child] or !hasEdge(edges, nodes[frame.index].id, nodes[child].id)) continue;
                const column = @min(depths.get(nodes[child].id) orelse 0, MacMetrics.columns - 1);
                var row = frame.row;
                while (rowTaken(slots, placed, row, column)) row += 1;
                parents[child] = frame.index;
                slots[child] = .{ .column = column, .row = row };
                placed[child] = true;
                stack.appendAssumeCapacity(.{ .index = child, .row = row });
            }
        }
    }

    const rows = MacMetrics.rowsPerLevel(options.row_budget);
    const raw_slots = try temp.dupe(Slot, slots);
    const members = try temp.alloc(usize, nodes.len);
    const grouped = try temp.alloc(bool, nodes.len);
    for (0..MacMetrics.columns) |level| {
        var member_count: usize = 0;
        for (ranked) |index| {
            if (placed[index] and raw_slots[index].column == level) {
                members[member_count] = index;
                member_count += 1;
            }
        }
        std.mem.sort(usize, members[0..member_count], raw_slots, struct {
            fn less(raw: []const Slot, a: usize, b: usize) bool {
                return raw[a].row < raw[b].row;
            }
        }.less);
        @memset(grouped, false);
        var column: usize = 0;
        var row: usize = 0;
        for (members[0..member_count]) |first| {
            if (grouped[first]) continue;
            var count: usize = 0;
            for (members[0..member_count]) |index| {
                if (parents[index] == parents[first]) count += 1;
            }
            const fan = count > 1;
            if (fan and row > 0) {
                column += 1;
                row = 0;
            }
            for (members[0..member_count]) |index| {
                if (parents[index] != parents[first]) continue;
                grouped[index] = true;
                // Swift clamps at seven here and aliases cards beyond capacity.
                // Keep its packing below the cap, but never reuse an occupied slot.
                slots[index] = .{ .column = level, .row = row, .sub_column = column };
                row += 1;
                if (row == rows) {
                    column += 1;
                    row = 0;
                }
            }
            if (fan and row > 0) {
                column += 1;
                row = 0;
            }
        }
    }
    var chain_rows: usize = 0;
    for (slots, placed) |slot, exists| {
        if (exists) chain_rows = @max(chain_rows, slot.row + 1);
    }
    var loose_count: usize = 0;
    for (ranked) |index| {
        if (touched.contains(nodes[index].id)) continue;
        slots[index] = .{
            .row = chain_rows + loose_count % rows,
            .sub_column = loose_count / rows,
            .is_loose = true,
        };
        loose_count += 1;
    }
    var result = Layout{ .allocator = allocator, .slots = slots, .positions = positions, .roles = roles };
    for (1..MacMetrics.columns) |depth| {
        var columns: usize = 1;
        var max_row: usize = 0;
        var min_row: usize = std.math.maxInt(usize);
        for (slots) |slot| {
            if (slot.is_loose or slot.column != depth - 1) continue;
            columns = @max(columns, slot.sub_column + 1);
            max_row = @max(max_row, slot.row);
            min_row = @min(min_row, slot.row);
        }
        const width = @as(f32, @floatFromInt(columns)) * MacMetrics.card_width +
            @as(f32, @floatFromInt(columns - 1)) * MacMetrics.column_gap;
        result.depth_offsets[depth] = result.depth_offsets[depth - 1] + width +
            (if (min_row < max_row) MacMetrics.busy_depth_gap else MacMetrics.depth_gap);
    }
    for (slots, positions) |slot, *point| {
        const x = (if (slot.is_loose) 0 else result.depth_offsets[slot.column]) +
            @as(f32, @floatFromInt(slot.sub_column)) * MacMetrics.column_width;
        point.* = .{ .x = options.origin.x + x, .y = options.origin.y + @as(f32, @floatFromInt(slot.row)) * options.row_height };
        if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y) or
            point.x + MacMetrics.card_width / 2 == point.x - MacMetrics.card_width / 2 or
            point.y + MacMetrics.card_height / 2 == point.y - MacMetrics.card_height / 2)
            return error.LayoutTooLarge;
        result.row_count = @max(result.row_count, slot.row + 1);
        result.content_width = @max(result.content_width, x + MacMetrics.card_width);
    }
    return result;
}

fn sequencing(edge: anytype) bool {
    return if (@hasField(@TypeOf(edge), "blocks_target")) edge.blocks_target else !std.mem.eql(u8, edge.kind, "message");
}

fn containsID(ids: []const []const u8, id: []const u8) bool {
    for (ids) |candidate| {
        if (std.mem.eql(u8, candidate, id)) return true;
    }
    return false;
}

fn hasEdge(edges: anytype, from: []const u8, to: []const u8) bool {
    for (edges) |edge| {
        if (std.mem.eql(u8, edge.from, from) and std.mem.eql(u8, edge.to, to)) return true;
    }
    return false;
}

fn rowTaken(slots: []const Slot, placed: []const bool, row: usize, column: ?usize) bool {
    for (slots, placed) |slot, exists| {
        if (exists and slot.row == row and (column == null or slot.column == column.?)) return true;
    }
    return false;
}

pub const Edge = struct {
    id: []const u8 = "",
    from: []const u8,
    to: []const u8,
    kind: []const u8 = "handoff",
    fired: bool = false,
};
pub const Node = struct {
    id: []const u8,
    loop_type: []const u8 = "goalBased",
    sub_graph: ?*const Graph = null,
};
pub const Graph = struct {
    nodes: []const Node = &.{},
    edges: []const Edge = &.{},
};
pub const Anchor = struct { id: []const u8, position: Point };
pub const Placement = struct { node: Node, depth: usize, position: Point };
pub const Link = struct {
    from_id: []const u8,
    to_id: []const u8,
    from: Point,
    to: Point,
    edge: ?Edge = null,
};
pub const Overflow = struct { parent: []const u8, hidden: usize, position: Point };
pub const SubGraphMetrics = struct {
    pub const first_offset = MacMetrics.card_height / 2 + 3;
    pub const step: f32 = 28;
    pub const indent: f32 = 14;
    pub const max_visible = 4;
    pub const chip_height: f32 = 20;
    pub const gutter: f32 = 10;
    pub const row_pitch = first_offset + (max_visible - 1) * step + chip_height / 2 + gutter + MacMetrics.card_height / 2;
};

pub fn canvasRowHeight(graph: Graph) f32 {
    for (graph.nodes) |node| {
        if (node.sub_graph) |sub| {
            if (sub.nodes.len > 0) return @max(MacMetrics.row_height, SubGraphMetrics.row_pitch);
        }
    }
    return MacMetrics.row_height;
}

/// Values borrow graph IDs/nodes; only the three result slices are owned.
pub const SubGraphLayout = struct {
    allocator: std.mem.Allocator,
    placements: []Placement,
    links: []Link,
    overflows: []Overflow,

    pub fn deinit(self: *SubGraphLayout) void {
        self.allocator.free(self.placements);
        self.allocator.free(self.links);
        self.allocator.free(self.overflows);
        self.* = undefined;
    }
};

const Entry = struct { node: Node, parent: []const u8, depth: usize };

pub fn initSubGraphs(allocator: std.mem.Allocator, nodes: []const Node, anchors: []const Anchor) !SubGraphLayout {
    var placements = std.array_list.Managed(Placement).init(allocator);
    errdefer placements.deinit();
    var links = std.array_list.Managed(Link).init(allocator);
    errdefer links.deinit();
    var overflows = std.array_list.Managed(Overflow).init(allocator);
    errdefer overflows.deinit();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const temp = scratch.allocator();
    for (nodes) |node| {
        const sub = node.sub_graph orelse continue;
        const anchor = findAnchor(anchors, node.id) orelse continue;
        var entries = std.array_list.Managed(Entry).init(temp);
        var edges = std.array_list.Managed(Edge).init(temp);
        var stack = std.array_list.Managed(struct {
            graph: *const Graph,
            parent: []const u8,
            depth: usize,
            next: usize = 0,
        }).init(temp);
        try edges.appendSlice(sub.edges);
        try stack.append(.{ .graph = sub, .parent = node.id, .depth = 1 });
        var ids = std.StringHashMap(void).init(temp);
        try ids.put(node.id, {});
        while (stack.items.len > 0) {
            const frame = &stack.items[stack.items.len - 1];
            if (frame.next == frame.graph.nodes.len) {
                _ = stack.pop();
                continue;
            }
            const child = frame.graph.nodes[frame.next];
            frame.next += 1;
            const unique = try ids.getOrPut(child.id);
            if (unique.found_existing) return error.DuplicateGraphNodeID;
            try entries.append(.{ .node = child, .parent = frame.parent, .depth = frame.depth });
            if (child.sub_graph) |nested| {
                const depth = try std.math.add(usize, frame.depth, 1);
                try edges.appendSlice(nested.edges);
                try stack.append(.{ .graph = nested, .parent = child.id, .depth = depth });
            }
        }
        const overflowing = entries.items.len > SubGraphMetrics.max_visible;
        const visible = if (overflowing) SubGraphMetrics.max_visible - 1 else entries.items.len;
        var placed = std.array_list.Managed(Anchor).init(temp);
        try placed.append(.{ .id = node.id, .position = anchor });
        for (entries.items[0..visible], 0..) |entry, slot| {
            const point = Point{
                .x = anchor.x + @as(f32, @floatFromInt(entry.depth)) * SubGraphMetrics.indent,
                .y = anchor.y + SubGraphMetrics.first_offset + @as(f32, @floatFromInt(slot)) * SubGraphMetrics.step,
            };
            try placed.append(.{ .id = entry.node.id, .position = point });
            try placements.append(.{ .node = entry.node, .depth = entry.depth, .position = point });
            if (findAnchor(placed.items, entry.parent)) |parent| {
                try links.append(.{ .from_id = entry.parent, .to_id = entry.node.id, .from = parent, .to = point });
            }
        }
        if (overflowing) try overflows.append(.{
            .parent = node.id,
            .hidden = entries.items.len - visible,
            .position = .{
                .x = anchor.x + SubGraphMetrics.indent,
                .y = anchor.y + SubGraphMetrics.first_offset + @as(f32, @floatFromInt(visible)) * SubGraphMetrics.step,
            },
        });
        for (edges.items) |edge| {
            const from = findAnchor(placed.items, edge.from) orelse continue;
            const to = findAnchor(placed.items, edge.to) orelse continue;
            try links.append(.{ .from_id = edge.from, .to_id = edge.to, .from = from, .to = to, .edge = edge });
        }
    }
    const owned_placements = try placements.toOwnedSlice();
    errdefer allocator.free(owned_placements);
    const owned_links = try links.toOwnedSlice();
    errdefer allocator.free(owned_links);
    return .{
        .allocator = allocator,
        .placements = owned_placements,
        .links = owned_links,
        .overflows = try overflows.toOwnedSlice(),
    };
}

fn findAnchor(anchors: []const Anchor, id: []const u8) ?Point {
    for (anchors) |anchor| {
        if (std.mem.eql(u8, anchor.id, id)) return anchor.position;
    }
    return null;
}

pub fn canvasPositions(allocator: std.mem.Allocator, graph: Graph, options: Options) ![]Anchor {
    var positions = std.array_list.Managed(Anchor).init(allocator);
    errdefer positions.deinit();
    var pending = std.array_list.Managed(Graph).init(allocator);
    defer pending.deinit();
    try pending.append(graph);
    while (pending.pop()) |current| {
        var current_options = options;
        if (positions.items.len > 0) current_options.order = &.{};
        current_options.row_height = canvasRowHeight(current);
        var layout = try init(allocator, current.nodes, current.edges, current_options);
        defer layout.deinit();
        for (current.nodes, layout.positions) |node, point| {
            if (findAnchor(positions.items, node.id) != null) return error.DuplicateGraphNodeID;
            try positions.append(.{ .id = node.id, .position = point });
            if (node.sub_graph) |sub| try pending.append(sub.*);
        }
    }
    return positions.toOwnedSlice();
}

pub const OverviewGraph = struct {
    graph: Graph,
    is_global: bool = false,
    order: []const []const u8 = &.{},
    declared_entries: []const []const u8 = &.{},
};
pub const OverviewLane = struct {
    graph_index: usize,
    layout: Layout,
    top: f32,
    height: f32,
    width: f32,
};
pub const Overview = struct {
    allocator: std.mem.Allocator,
    lanes: []OverviewLane,
    start_node: ?Point,
    size: Point,

    pub fn deinit(self: *Overview) void {
        for (self.lanes) |*lane| lane.layout.deinit();
        self.allocator.free(self.lanes);
        self.* = undefined;
    }
};

pub fn initOverview(allocator: std.mem.Allocator, graphs: []const OverviewGraph, viewport_height: f32) !Overview {
    if (!std.math.isFinite(viewport_height) or viewport_height < 0) return error.InvalidLayoutMetrics;
    var lanes = std.array_list.Managed(OverviewLane).init(allocator);
    errdefer {
        for (lanes.items) |*lane| lane.layout.deinit();
        lanes.deinit();
    }
    var count: usize = 0;
    for (graphs) |graph| {
        if (!graph.is_global or graph.graph.nodes.len > 0) count += 1;
    }
    if (count == 0) return .{ .allocator = allocator, .lanes = try lanes.toOwnedSlice(), .start_node = null, .size = .{} };
    const budget = if (viewport_height > 0)
        @max(MacMetrics.minimum_row_budget, MacMetrics.rowBudget(viewport_height) / count)
    else
        MacMetrics.maximum_rows_per_level;
    var top = MacMetrics.lane_top;
    var width = @as(f32, MacMetrics.columns - 1) * MacMetrics.depth_width + MacMetrics.card_width;
    for (0..2) |pass| {
        for (graphs, 0..) |graph, index| {
            if (graph.is_global != (pass == 0) or (graph.is_global and graph.graph.nodes.len == 0)) continue;
            var layout = try init(allocator, graph.graph.nodes, graph.graph.edges, .{
                .origin = .{ .x = MacMetrics.first_loop_x, .y = top + MacMetrics.first_row_inset },
                .row_budget = budget,
                .order = graph.order,
                .declared_entries = graph.declared_entries,
            });
            errdefer layout.deinit();
            const height = MacMetrics.bandHeight(layout.row_count);
            try lanes.append(.{ .graph_index = index, .layout = layout, .top = top, .height = height, .width = 0 });
            width = @max(width, layout.content_width);
            top += height + MacMetrics.lane_gap;
        }
    }
    const band_width = MacMetrics.bandWidth(width);
    for (lanes.items) |*lane| lane.width = band_width;
    return .{
        .allocator = allocator,
        .lanes = try lanes.toOwnedSlice(),
        .start_node = .{ .x = 30, .y = (MacMetrics.lane_top + top - MacMetrics.lane_gap) / 2 },
        .size = .{ .x = MacMetrics.band_x * 2 + band_width, .y = top - MacMetrics.lane_gap + MacMetrics.lane_top },
    };
}

test "lane chain follows edges rather than arrival order" {
    const nodes = [_]TestNode{ .{ .id = "third" }, .{ .id = "first" }, .{ .id = "second" } };
    const edges = [_]TestEdge{ .{ .from = "first", .to = "second" }, .{ .from = "second", .to = "third" } };
    var layout = try init(std.testing.allocator, &nodes, &edges, .{});
    defer layout.deinit();
    try std.testing.expectEqual(Slot{ .column = 2, .row = 0 }, layout.slots[0]);
    try std.testing.expectEqual(Slot{ .column = 0, .row = 0 }, layout.slots[1]);
    try std.testing.expectEqual(Slot{ .column = 1, .row = 0 }, layout.slots[2]);
    try std.testing.expectEqual(Point{ .x = 1067, .y = 148 }, layout.positions[0]);
    try std.testing.expectEqual(Point{ .x = 287, .y = 148 }, layout.positions[1]);
    try std.testing.expectEqual(Point{ .x = 677, .y = 148 }, layout.positions[2]);
}

fn expectNoOverlap(points: []const Point) !void {
    for (points, 0..) |a, i| {
        for (points[i + 1 ..]) |b| {
            try std.testing.expect(@abs(a.x - b.x) >= MacMetrics.card_width or @abs(a.y - b.y) >= MacMetrics.card_height);
        }
    }
}

fn numberedNodes(allocator: std.mem.Allocator, count: usize) ![]TestNode {
    const nodes = try allocator.alloc(TestNode, count);
    errdefer allocator.free(nodes);
    var initialized: usize = 0;
    errdefer for (nodes[0..initialized]) |node| allocator.free(node.id);
    for (nodes, 0..) |*node, index| {
        node.* = .{ .id = try std.fmt.allocPrint(allocator, "node-{d}", .{index}) };
        initialized += 1;
    }
    return nodes;
}

fn freeNumberedNodes(allocator: std.mem.Allocator, nodes: []TestNode) void {
    for (nodes) |node| allocator.free(node.id);
    allocator.free(nodes);
}

test "lane loose block wraps dynamically below chains with exact MacMetrics" {
    const allocator = std.testing.allocator;
    const nodes = try numberedNodes(allocator, 26);
    defer freeNumberedNodes(allocator, nodes);
    const edges = [_]TestEdge{.{ .from = nodes[0].id, .to = nodes[1].id }};
    var tall = try init(allocator, nodes, &edges, .{ .row_budget = MacMetrics.rowBudget(900) });
    defer tall.deinit();
    var short = try init(allocator, nodes, &edges, .{ .row_budget = MacMetrics.rowBudget(400) });
    defer short.deinit();
    try std.testing.expectEqual(@as(usize, 5), MacMetrics.rowsPerLevel(MacMetrics.rowBudget(900)));
    try std.testing.expectEqual(@as(usize, 3), MacMetrics.rowsPerLevel(MacMetrics.rowBudget(400)));
    try std.testing.expectEqual(Slot{ .row = 1, .is_loose = true }, tall.slots[2]);
    try std.testing.expectEqual(Slot{ .row = 1, .sub_column = 1, .is_loose = true }, tall.slots[7]);
    try std.testing.expectEqual(Slot{ .row = 1, .sub_column = 1, .is_loose = true }, short.slots[5]);
    try std.testing.expectEqual(@as(usize, 6), tall.row_count);
    try std.testing.expectEqual(@as(usize, 4), short.row_count);
    try std.testing.expect(short.content_width > tall.content_width);
    try std.testing.expectEqual(@as(f32, 390), tall.positions[1].x - tall.positions[0].x);
    try std.testing.expectEqual(@as(f32, 290), tall.positions[7].x - tall.positions[2].x);
    try expectNoOverlap(tall.positions);
    try expectNoOverlap(short.positions);
}

test "lane fan wraps densely and preserves sidebar order rather than edge order" {
    const allocator = std.testing.allocator;
    const nodes = try numberedNodes(allocator, 15);
    defer freeNumberedNodes(allocator, nodes);
    var edges: [14]TestEdge = undefined;
    var order: [15][]const u8 = undefined;
    for (&edges, 0..) |*edge, index| edge.* = .{ .from = nodes[0].id, .to = nodes[14 - index].id };
    for (&order, 0..) |*id, index| id.* = nodes[index].id;
    var layout = try init(allocator, nodes, &edges, .{ .order = &order });
    defer layout.deinit();
    for (layout.slots[1..], 0..) |slot, index| {
        try std.testing.expectEqual(Slot{ .column = 1, .row = index % 5, .sub_column = index / 5 }, slot);
    }
    try std.testing.expectEqual(@as(f32, 1220), layout.content_width);
    try expectNoOverlap(layout.positions);
}

test "lane parent fans get separate columns and busy depths earn wider gaps" {
    const allocator = std.testing.allocator;
    const nodes = try numberedNodes(allocator, 9);
    defer freeNumberedNodes(allocator, nodes);
    var edges: [7]TestEdge = undefined;
    for (&edges, 0..) |*edge, index| edge.* = .{ .from = nodes[if (index < 3) 0 else 1].id, .to = nodes[index + 2].id };
    var layout = try init(allocator, nodes, &edges, .{});
    defer layout.deinit();
    try std.testing.expectEqual(Slot{ .column = 0, .row = 0 }, layout.slots[0]);
    try std.testing.expectEqual(Slot{ .column = 0, .row = 1 }, layout.slots[1]);
    try std.testing.expectEqual(Slot{ .column = 1, .row = 0 }, layout.slots[2]);
    try std.testing.expectEqual(Slot{ .column = 1, .row = 0, .sub_column = 1 }, layout.slots[5]);
    try std.testing.expectEqual(@as(f32, 480), layout.depth_offsets[1]);
    try expectNoOverlap(layout.positions);
}

test "lane cycle-only components have no artificial entry and declared cycle walk is capped" {
    const nodes = [_]TestNode{ .{ .id = "a" }, .{ .id = "b" }, .{ .id = "loose" } };
    const edges = [_]TestEdge{ .{ .from = "a", .to = "b" }, .{ .from = "b", .to = "a" } };
    var closed = try init(std.testing.allocator, &nodes, &edges, .{});
    defer closed.deinit();
    try std.testing.expectEqualSlices(Role, &.{ .cycle_only, .cycle_only, .unwired }, closed.roles);
    try std.testing.expectEqual(Slot{ .column = 0, .row = 1 }, closed.slots[1]);
    try std.testing.expectEqual(Slot{ .row = 2, .is_loose = true }, closed.slots[2]);
    var declared = try init(std.testing.allocator, &nodes, &edges, .{ .declared_entries = &.{"a"} });
    defer declared.deinit();
    try std.testing.expectEqualSlices(Role, &.{ .entry, .cycle_only, .unwired }, declared.roles);
    try std.testing.expectEqual(@as(usize, 2), declared.slots[0].column);
    try std.testing.expectEqual(@as(usize, 3), declared.slots[1].column);
    try expectNoOverlap(closed.positions);
    try expectNoOverlap(declared.positions);
}

test "lane message edges place cards but do not manufacture sequencing cycles" {
    const nodes = [_]TestNode{ .{ .id = "a" }, .{ .id = "b" } };
    const edges = [_]TestEdge{ .{ .from = "a", .to = "b" }, .{ .from = "b", .to = "a", .kind = "message" } };
    var layout = try init(std.testing.allocator, &nodes, &edges, .{});
    defer layout.deinit();
    try std.testing.expectEqualSlices(Role, &.{ .entry, .interior }, layout.roles);
    try std.testing.expectEqual(@as(usize, 2), layout.slots[0].column);
    try std.testing.expectEqual(@as(usize, 3), layout.slots[1].column);
    try expectNoOverlap(layout.positions);
}

test "lane sidebar rank ignores unknown and duplicate order IDs and appends new arrivals" {
    const nodes = [_]TestNode{ .{ .id = "a" }, .{ .id = "b" }, .{ .id = "c" } };
    var layout = try init(std.testing.allocator, &nodes, &[_]TestEdge{}, .{ .order = &.{ "unknown", "b", "b", "a" } });
    defer layout.deinit();
    try std.testing.expectEqual(@as(usize, 0), layout.slots[1].row);
    try std.testing.expectEqual(@as(usize, 1), layout.slots[0].row);
    try std.testing.expectEqual(@as(usize, 2), layout.slots[2].row);
    try expectNoOverlap(layout.positions);
}

test "lane duplicate nodes reject and duplicate or dangling edges retain Mac semantics" {
    const duplicate = [_]TestNode{ .{ .id = "a" }, .{ .id = "a" } };
    try std.testing.expectError(error.DuplicateGraphNodeID, init(std.testing.allocator, &duplicate, &[_]TestEdge{}, .{}));
    const nodes = [_]TestNode{ .{ .id = "a" }, .{ .id = "b" }, .{ .id = "c" } };
    const edges = [_]TestEdge{
        .{ .from = "a", .to = "missing" },
        .{ .from = "missing", .to = "b" },
        .{ .from = "a", .to = "missing" },
        .{ .from = "unknown", .to = "c" },
    };
    var layout = try init(std.testing.allocator, &nodes, &edges, .{});
    defer layout.deinit();
    try std.testing.expectEqualSlices(Role, &.{ .entry, .interior, .cycle_only }, layout.roles);
    try std.testing.expectEqual(@as(usize, 2), layout.slots[1].column);
    try std.testing.expect(!layout.slots[2].is_loose);
    try expectNoOverlap(layout.positions);
}

test "lane capacity boundary and beyond never alias rectangles" {
    for ([_]usize{ 3, 5 }) |budget| {
        for ([_]usize{ budget * MacMetrics.maximum_columns_per_level, budget * MacMetrics.maximum_columns_per_level + 1, 73 }) |count| {
            const nodes = try numberedNodes(std.testing.allocator, count);
            defer freeNumberedNodes(std.testing.allocator, nodes);
            var loose = try init(std.testing.allocator, nodes, &[_]TestEdge{}, .{ .row_budget = budget });
            defer loose.deinit();
            try expectNoOverlap(loose.positions);
            for (loose.slots, 0..) |slot, index| {
                try std.testing.expectEqual(Slot{ .row = index % budget, .sub_column = index / budget, .is_loose = true }, slot);
            }
            const edges = try std.testing.allocator.alloc(TestEdge, count - 1);
            defer std.testing.allocator.free(edges);
            for (edges, 0..) |*edge, index| edge.* = .{ .from = nodes[0].id, .to = nodes[index + 1].id };
            var fan = try init(std.testing.allocator, nodes, edges, .{ .row_budget = budget });
            defer fan.deinit();
            try expectNoOverlap(fan.positions);
            for (fan.slots[1..]) |slot| try std.testing.expectEqual(@as(usize, 1), slot.column);
        }
    }
}

test "lane empty graph and invalid metrics are explicit" {
    var empty = try init(std.testing.allocator, &[_]TestNode{}, &[_]TestEdge{}, .{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 1), empty.row_count);
    try std.testing.expectEqual(@as(f32, 250), empty.content_width);
    try std.testing.expectError(error.InvalidLayoutMetrics, init(std.testing.allocator, &[_]TestNode{}, &[_]TestEdge{}, .{ .row_height = 95 }));
    try std.testing.expectError(error.LayoutTooLarge, init(std.testing.allocator, &[_]TestNode{.{ .id = "a" }}, &[_]TestEdge{}, .{ .origin = .{ .x = 1e30 } }));
    try std.testing.expectError(error.InvalidLayoutMetrics, initOverview(std.testing.allocator, &.{}, std.math.inf(f32)));
}

test "lane chain geometry ignores arrival permutations and preserves capped Mac depth walk" {
    const edges = [_]TestEdge{ .{ .from = "a", .to = "b" }, .{ .from = "b", .to = "c" } };
    const ids = [_][]const u8{ "a", "b", "c" };
    for ([_][3]usize{ .{ 0, 1, 2 }, .{ 0, 2, 1 }, .{ 1, 0, 2 }, .{ 1, 2, 0 }, .{ 2, 0, 1 }, .{ 2, 1, 0 } }) |permutation| {
        const nodes = [_]TestNode{ .{ .id = ids[permutation[0]] }, .{ .id = ids[permutation[1]] }, .{ .id = ids[permutation[2]] } };
        var layout = try init(std.testing.allocator, &nodes, &edges, .{});
        defer layout.deinit();
        for (permutation, layout.slots) |level, slot| try std.testing.expectEqual(Slot{ .column = level }, slot);
        try expectNoOverlap(layout.positions);
    }
    const nodes = try numberedNodes(std.testing.allocator, 11);
    defer freeNumberedNodes(std.testing.allocator, nodes);
    var long_edges: [10]TestEdge = undefined;
    for (&long_edges, 0..) |*edge, i| edge.* = .{ .from = nodes[i].id, .to = nodes[i + 1].id };
    var long = try init(std.testing.allocator, nodes, &long_edges, .{});
    defer long.deinit();
    try std.testing.expectEqual(@as(usize, 2), long.slots[2].column);
    try std.testing.expectEqual(@as(usize, 3), long.slots[3].column);
    // LaneLayout.swift:396-408 stops walking at depth three; unreached nodes
    // subsequently use place()'s depth-zero fallback, despite the metrics comment.
    for (long.slots[4..]) |slot| try std.testing.expectEqual(@as(usize, 0), slot.column);
    try expectNoOverlap(long.positions);
}

test "lane separate chains stay aligned and reflow when edges or sidebar order change" {
    const nodes = [_]TestNode{ .{ .id = "a" }, .{ .id = "b" }, .{ .id = "x" }, .{ .id = "y" } };
    const edges = [_]TestEdge{ .{ .from = "a", .to = "b" }, .{ .from = "x", .to = "y" } };
    var loose = try init(std.testing.allocator, &nodes, &[_]TestEdge{}, .{});
    defer loose.deinit();
    var wired = try init(std.testing.allocator, &nodes, &edges, .{});
    defer wired.deinit();
    try std.testing.expectEqual(@as(f32, 0), loose.positions[1].x - loose.positions[0].x);
    try std.testing.expectEqual(@as(f32, 480), wired.positions[1].x - wired.positions[0].x);
    try std.testing.expectEqual(wired.positions[0].y, wired.positions[1].y);
    try std.testing.expectEqual(wired.positions[2].y, wired.positions[3].y);
    var reordered = try init(std.testing.allocator, &nodes, &edges, .{ .order = &.{ "x", "y", "a", "b" } });
    defer reordered.deinit();
    try std.testing.expectEqual(wired.positions[0], reordered.positions[2]);
    try std.testing.expectEqual(wired.positions[2], reordered.positions[0]);
    try expectNoOverlap(wired.positions);
    try expectNoOverlap(reordered.positions);
}

test "subgraph nested preorder containment and real edge kinds are retained" {
    const deep = Graph{ .nodes = &.{.{ .id = "judge" }} };
    const sub = Graph{
        .nodes = &.{ .{ .id = "nested", .loop_type = "composite", .sub_graph = &deep }, .{ .id = "other" } },
        .edges = &.{.{ .id = "memo", .from = "judge", .to = "other", .kind = "message", .fired = true }},
    };
    const nodes = [_]Node{.{ .id = "parent", .loop_type = "composite", .sub_graph = &sub }};
    var layout = try initSubGraphs(std.testing.allocator, &nodes, &.{.{ .id = "parent", .position = .{ .x = 160, .y = 140 } }});
    defer layout.deinit();
    try std.testing.expectEqual(@as(usize, 3), layout.placements.len);
    try std.testing.expectEqual(@as(usize, 1), layout.placements[0].depth);
    try std.testing.expectEqual(@as(usize, 2), layout.placements[1].depth);
    try std.testing.expectEqualStrings("composite", layout.placements[0].node.loop_type);
    try std.testing.expectEqual(Point{ .x = 174, .y = 191 }, layout.placements[0].position);
    try std.testing.expectEqual(Point{ .x = 188, .y = 219 }, layout.placements[1].position);
    try std.testing.expectEqualStrings("nested", layout.links[1].from_id);
    try std.testing.expectEqual(layout.placements[0].position, layout.links[1].from);
    try std.testing.expectEqualStrings("message", layout.links[3].edge.?.kind);
    try std.testing.expect(layout.links[3].edge.?.fired);
}

test "subgraph overflow reserves fourth chip and hides dangling links within taller project row" {
    const children = [_]Node{ .{ .id = "0" }, .{ .id = "1" }, .{ .id = "2" }, .{ .id = "3" }, .{ .id = "4" } };
    const sub = Graph{ .nodes = &children, .edges = &.{.{ .from = "4", .to = "0" }} };
    const graph = Graph{ .nodes = &.{.{ .id = "parent", .sub_graph = &sub }} };
    var layout = try initSubGraphs(std.testing.allocator, graph.nodes, &.{.{ .id = "parent", .position = .{ .x = 160, .y = 140 } }});
    defer layout.deinit();
    try std.testing.expectEqual(@as(usize, 3), layout.placements.len);
    try std.testing.expectEqual(@as(usize, 3), layout.links.len);
    try std.testing.expectEqual(@as(usize, 1), layout.overflows.len);
    try std.testing.expectEqual(@as(usize, 2), layout.overflows[0].hidden);
    try std.testing.expectEqual(Point{ .x = 174, .y = 275 }, layout.overflows[0].position);
    try std.testing.expectEqual(@as(f32, 203), canvasRowHeight(graph));
    try std.testing.expect(layout.overflows[0].position.y + 10 < 140 + canvasRowHeight(graph) - MacMetrics.card_height / 2);
    var skipped = try initSubGraphs(std.testing.allocator, graph.nodes, &.{});
    defer skipped.deinit();
    try std.testing.expectEqual(@as(usize, 0), skipped.placements.len);
}

test "subgraph empty and plain nodes contribute nothing and drilled graph gets independent points" {
    const empty = Graph{};
    const deep = Graph{ .nodes = &.{ .{ .id = "a" }, .{ .id = "b" } }, .edges = &.{.{ .from = "a", .to = "b" }} };
    const graph = Graph{ .nodes = &.{
        .{ .id = "plain" },
        .{ .id = "empty", .sub_graph = &empty },
        .{ .id = "parent", .sub_graph = &deep },
    } };
    var layout = try initSubGraphs(std.testing.allocator, graph.nodes, &.{ .{ .id = "plain", .position = .{} }, .{ .id = "empty", .position = .{} } });
    defer layout.deinit();
    try std.testing.expectEqual(@as(usize, 0), layout.links.len);
    const points = try canvasPositions(std.testing.allocator, graph, .{});
    defer std.testing.allocator.free(points);
    try std.testing.expectEqual(@as(usize, 5), points.len);
    try std.testing.expectEqual(MacMetrics.origin, findAnchor(points, "a").?);
    try std.testing.expectEqual(@as(f32, 677), findAnchor(points, "b").?.x);
}

test "overview shares project points and aligns global-first lanes without cross-lane intersections" {
    const a = Graph{ .nodes = &.{ .{ .id = "third" }, .{ .id = "first" }, .{ .id = "second" } }, .edges = &.{ .{ .from = "first", .to = "second" }, .{ .from = "second", .to = "third" } } };
    const b = Graph{ .nodes = &.{.{ .id = "alone" }} };
    const graphs = [_]OverviewGraph{ .{ .graph = a }, .{ .graph = .{}, .is_global = true }, .{ .graph = b, .is_global = true }, .{ .graph = .{} } };
    var overview = try initOverview(std.testing.allocator, &graphs, 900);
    defer overview.deinit();
    try std.testing.expectEqual(@as(usize, 3), overview.lanes.len);
    try std.testing.expectEqual(@as(usize, 2), overview.lanes[0].graph_index);
    try std.testing.expectEqual(@as(usize, 0), overview.lanes[1].graph_index);
    try std.testing.expectEqual(@as(f32, 62), overview.lanes[0].top);
    try std.testing.expectEqual(@as(f32, 240), overview.lanes[1].top);
    try std.testing.expectEqual(overview.lanes[0].width, overview.lanes[2].width);
    try std.testing.expectEqual(@as(f32, 154), overview.lanes[2].height);
    for (overview.lanes, 0..) |lane, index| {
        try expectNoOverlap(lane.layout.positions);
        if (index > 0) {
            const previous = overview.lanes[index - 1];
            try std.testing.expect(lane.top > previous.top + previous.height);
            for (previous.layout.positions) |before| {
                for (lane.layout.positions) |after| try std.testing.expect(after.y - before.y >= MacMetrics.card_height);
            }
        }
    }
    var single = try initOverview(std.testing.allocator, &.{.{ .graph = a }}, 0);
    defer single.deinit();
    var project = try init(std.testing.allocator, a.nodes, a.edges, .{});
    defer project.deinit();
    try std.testing.expectEqualSlices(Point, project.positions, single.lanes[0].layout.positions);
}

fn allocationFixture(allocator: std.mem.Allocator) !void {
    const sub = Graph{ .nodes = &.{ .{ .id = "a" }, .{ .id = "b" }, .{ .id = "c" }, .{ .id = "d" }, .{ .id = "e" } }, .edges = &.{.{ .from = "a", .to = "b" }} };
    const graph = Graph{ .nodes = &.{ .{ .id = "parent", .sub_graph = &sub }, .{ .id = "loose" } } };
    var layout = try init(allocator, graph.nodes, graph.edges, .{});
    defer layout.deinit();
    var sub_layout = try initSubGraphs(allocator, graph.nodes, &.{.{ .id = "parent", .position = MacMetrics.origin }});
    defer sub_layout.deinit();
    var overview = try initOverview(allocator, &.{.{ .graph = graph }}, 400);
    defer overview.deinit();
    const positions = try canvasPositions(allocator, graph, .{});
    defer allocator.free(positions);
}

test "lane all allocation failures clean up owned layout subgraph and overview results" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFixture, .{});
}
