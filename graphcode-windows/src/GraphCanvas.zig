const std = @import("std");
const GraphModel = @import("GraphModel.zig");
const Tokens = @import("DesignTokens.zig");
const Sidebar = @import("Sidebar.zig");
const c = @import("Win32.zig").c;

pub const CanvasState = struct {
    pan_x: f32 = 0,
    pan_y: f32 = 0,
    zoom: f32 = 1,
    dragging: bool = false,
    drag_x: i32 = 0,
    drag_y: i32 = 0,
    start_pan_x: f32 = 0,
    start_pan_y: f32 = 0,

    pub fn beginPan(self: *CanvasState, x: i32, y: i32) void {
        self.dragging = true;
        self.drag_x = x;
        self.drag_y = y;
        self.start_pan_x = self.pan_x;
        self.start_pan_y = self.pan_y;
    }

    pub fn updatePan(self: *CanvasState, x: i32, y: i32) void {
        if (!self.dragging) return;
        self.pan_x = self.start_pan_x + @as(f32, @floatFromInt(x - self.drag_x));
        self.pan_y = self.start_pan_y + @as(f32, @floatFromInt(y - self.drag_y));
    }

    pub fn endPan(self: *CanvasState) void {
        self.dragging = false;
    }

    pub fn zoomAt(self: *CanvasState, x: i32, y: i32, wheel_delta: i16) void {
        const old_zoom = self.zoom;
        const factor: f32 = if (wheel_delta > 0) 1.1 else 0.9;
        const next = std.math.clamp(old_zoom * factor, 0.55, 1.8);
        if (next == old_zoom) return;
        const world_x = (@as(f32, @floatFromInt(x)) - self.pan_x) / old_zoom;
        const world_y = (@as(f32, @floatFromInt(y)) - self.pan_y) / old_zoom;
        self.zoom = next;
        self.pan_x = @as(f32, @floatFromInt(x)) - world_x * next;
        self.pan_y = @as(f32, @floatFromInt(y)) - world_y * next;
    }
};

pub const CardTextLayout = struct {
    title_y: i32,
    state_y: i32,
    show_entry: bool,
    show_activity: bool,
    show_attention: bool,
};

pub fn paint(
    hwnd: c.HWND,
    hdc: c.HDC,
    model: *const GraphModel.Model,
    status: []const u8,
    allocator: std.mem.Allocator,
    sidebar_scroll: i32,
    state: *const CanvasState,
) void {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    fill(hdc, client, Tokens.canvas_tone);
    header(hdc, allocator, client.right, status);
    Sidebar.draw(hdc, model, status, allocator, client.bottom, sidebar_scroll);

    const graph_bounds = rect(
        Tokens.sidebar_width,
        Tokens.header_height,
        client.right,
        @max(Tokens.header_height + 1, client.bottom - Tokens.workspace_height),
    );
    fill(hdc, graph_bounds, Tokens.canvas_tone);
    const saved = c.SaveDC(hdc);
    _ = c.IntersectClipRect(hdc, graph_bounds.left, graph_bounds.top, graph_bounds.right, graph_bounds.bottom);
    drawGrid(hdc, graph_bounds, state);
    if (model.graph) |graph| {
        drawEdges(hdc, graph, state);
        for (graph.nodes.items, 0..) |node, index| {
            drawNode(hdc, allocator, node, index, model.selected_node, graph.nodes.items, graph.edges.items, state);
        }
    } else {
        drawText(hdc, allocator, "Open a project to view its graph", Tokens.sidebar_width + 32, 120, 18, 0x00B8B8B8);
    }
    _ = c.RestoreDC(hdc, saved);
}

fn header(hdc: c.HDC, allocator: std.mem.Allocator, width: i32, status: []const u8) void {
    fill(hdc, rect(0, 0, width, Tokens.header_height), Tokens.window_tone);
    drawText(hdc, allocator, "GraphCode Windows", 16, 8, 15, 0x00FFFFFF);
    drawText(hdc, allocator, status, width - 320, 9, 12, 0x00A8A8A8);
}

fn drawGrid(hdc: c.HDC, bounds: c.RECT, state: *const CanvasState) void {
    const pen = c.CreatePen(c.PS_SOLID, 1, Tokens.rgb(Tokens.canvas_grid_line));
    if (pen == null) return;
    const old = c.SelectObject(hdc, pen);
    const cell = @max(8, @as(i32, @intFromFloat(@as(f32, Tokens.canvas_grid_cell) * state.zoom)));
    var x = bounds.left + @mod(@as(i32, @intFromFloat(state.pan_x)), cell);
    while (x < bounds.right) : (x += cell) {
        _ = c.MoveToEx(hdc, x, bounds.top, null);
        _ = c.LineTo(hdc, x, bounds.bottom);
    }
    var y = bounds.top + @mod(@as(i32, @intFromFloat(state.pan_y)), cell);
    while (y < bounds.bottom) : (y += cell) {
        _ = c.MoveToEx(hdc, bounds.left, y, null);
        _ = c.LineTo(hdc, bounds.right, y);
    }
    _ = c.SelectObject(hdc, old);
    _ = c.DeleteObject(pen);
}

fn drawEdges(hdc: c.HDC, graph: GraphModel.Graph, state: *const CanvasState) void {
    const pen = c.CreatePen(c.PS_SOLID, 2, 0x006A6A6A);
    if (pen == null) return;
    const old = c.SelectObject(hdc, pen);
    for (graph.edges.items) |edge| {
        const from = connectorPosition(graph.nodes.items, edge.from, true, state) orelse continue;
        const to = connectorPosition(graph.nodes.items, edge.to, false, state) orelse continue;
        const distance: i32 = if (to.x >= from.x) to.x - from.x else from.x - to.x;
        const bend: i32 = @max(@as(i32, 24), @divTrunc(distance, 2));
        var points = [_]c.POINT{
            .{ .x = from.x, .y = from.y },
            .{ .x = from.x + bend, .y = from.y },
            .{ .x = to.x - bend, .y = to.y },
            .{ .x = to.x, .y = to.y },
        };
        _ = c.PolyBezier(hdc, &points, 4);
    }
    _ = c.SelectObject(hdc, old);
    _ = c.DeleteObject(pen);
}

const Connector = struct {
    x: i32,
    y: i32,
};

fn connectorPosition(nodes: []const GraphModel.Node, node_id: []const u8, outgoing: bool, state: *const CanvasState) ?Connector {
    for (nodes, 0..) |node, index| {
        if (!std.mem.eql(u8, node.id, node_id)) continue;
        const bounds = nodeBounds(index, state);
        return .{
            .x = if (outgoing) bounds.right else bounds.left,
            .y = @divTrunc(bounds.top + bounds.bottom, 2),
        };
    }
    return null;
}

fn drawNode(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    node: GraphModel.Node,
    index: usize,
    selected: ?usize,
    nodes: []const GraphModel.Node,
    edges: []const GraphModel.Edge,
    state: *const CanvasState,
) void {
    const bounds = nodeBounds(index, state);
    const x = bounds.left;
    const y = bounds.top;
    const attention = needsAttention(node, nodes, edges);
    const selected_card = selected == index;
    roundedCard(hdc, bounds, if (selected_card) 0x00345D8C else 0x00262626, selected_card);
    const stripe = stateColor(node.state, attention);
    fill(hdc, rect(x, y, x + scaled(Tokens.loop_card_stripe, state), y + bounds.bottom - y), stripe);
    const layout = cardTextLayout(state.zoom, isEntry(nodes, edges, node.id), attention);
    if (layout.show_entry) drawText(hdc, allocator, "START", x + scaled(14, state), y + layout.title_y - scaled(10, state), scaled(9, state), 0x008A8A8A);
    drawText(hdc, allocator, node.title, x + scaled(14, state), y + layout.title_y, scaled(14, state), 0x00FFFFFF);
    drawText(hdc, allocator, node.state, x + scaled(14, state), y + layout.state_y, scaled(11, state), if (attention) 0x00FFB340 else 0x00B8B8B8);
    if (layout.show_activity and node.activity.len != 0) drawText(hdc, allocator, node.activity, x + scaled(14, state), y + layout.state_y + scaled(22, state), scaled(10, state), 0x008A8A8A);
    if (layout.show_attention) drawText(hdc, allocator, "NEEDS YOU", bounds.right - scaled(88, state), y + scaled(8, state), scaled(9, state), 0x00FFB340);
}

fn nodeBounds(index: usize, state: *const CanvasState) c.RECT {
    const column = @as(i32, @intCast(index % 3));
    const row = @as(i32, @intCast(index / 3));
    const x = @as(i32, @intFromFloat((@as(f32, @floatFromInt(Tokens.sidebar_width + 32 + column * 260)) * state.zoom) + state.pan_x));
    const y = @as(i32, @intFromFloat((@as(f32, @floatFromInt(Tokens.header_height + 50 + row * 140)) * state.zoom) + state.pan_y));
    return rect(x, y, x + scaled(Tokens.loop_card_width, state), y + scaled(Tokens.loop_card_height, state));
}

fn scaled(value: i32, state: *const CanvasState) i32 {
    return @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(value)) * state.zoom)));
}

fn stateColor(state: []const u8, attention: bool) u32 {
    if (attention) return 0x00FF9F0A;
    if (std.mem.eql(u8, state, "running")) return 0x000A84FF;
    if (std.mem.eql(u8, state, "failed")) return 0x00FF453A;
    if (std.mem.eql(u8, state, "blocked")) return 0x00FF9F0A;
    if (std.mem.eql(u8, state, "succeeded")) return 0x0030D158;
    return 0x00909090;
}

fn needsAttention(node: GraphModel.Node, nodes: []const GraphModel.Node, edges: []const GraphModel.Edge) bool {
    if (std.mem.eql(u8, node.state, "failed") or std.mem.eql(u8, node.state, "stalled")) return true;
    if (std.mem.eql(u8, node.state, "running") and std.mem.eql(u8, node.presence, "awaitingInput")) return true;
    if (!std.mem.eql(u8, node.state, "blocked")) return false;
    for (edges) |edge| {
        if (!std.mem.eql(u8, edge.to, node.id) or !std.mem.eql(u8, edge.kind, "handoff") or !edge.fired) continue;
        for (nodes) |source| {
            if (std.mem.eql(u8, source.id, edge.from) and
                (std.mem.eql(u8, source.state, "failed") or std.mem.eql(u8, source.state, "stalled") or
                    std.mem.eql(u8, source.state, "succeeded")))
            {
                return true;
            }
        }
    }
    return false;
}

fn isEntry(nodes: []const GraphModel.Node, edges: []const GraphModel.Edge, node_id: []const u8) bool {
    _ = nodes;
    for (edges) |edge| {
        if (std.mem.eql(u8, edge.to, node_id)) return false;
    }
    return true;
}

pub fn hitTest(nodes: []const GraphModel.Node, x: i32, y: i32, state: *const CanvasState, graph_bounds: c.RECT) ?usize {
    if (x < graph_bounds.left or x >= graph_bounds.right or y < graph_bounds.top or y >= graph_bounds.bottom) return null;
    var index = nodes.len;
    while (index > 0) {
        index -= 1;
        const bounds = nodeBounds(index, state);
        if (x >= bounds.left and x < bounds.right and y >= bounds.top and y < bounds.bottom) return index;
    }

    return null;
}

fn cardTextLayout(zoom: f32, entry: bool, attention: bool) CardTextLayout {
    if (zoom < 0.75) return .{
        .title_y = scaledValue(14, zoom),
        .state_y = scaledValue(40, zoom),
        .show_entry = false,
        .show_activity = false,
        .show_attention = false,
    };
    return .{
        .title_y = scaledValue(if (entry) 20 else 14, zoom),
        .state_y = scaledValue(if (entry) 47 else 43, zoom),
        .show_entry = entry,
        .show_activity = true,
        .show_attention = attention,
    };
}

fn scaledValue(value: i32, zoom: f32) i32 {
    return @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(value)) * zoom)));
}

fn rect(left: i32, top: i32, right: i32, bottom: i32) c.RECT {
    return .{ .left = left, .top = top, .right = right, .bottom = bottom };
}

fn fill(hdc: c.HDC, bounds: c.RECT, color: u32) void {
    const brush = c.CreateSolidBrush(color);
    if (brush != null) {
        _ = c.FillRect(hdc, &bounds, brush);
        _ = c.DeleteObject(brush);
    }
}

fn roundedCard(hdc: c.HDC, bounds: c.RECT, color: u32, selected: bool) void {
    const brush = c.CreateSolidBrush(color);
    const pen = c.CreatePen(c.PS_SOLID, if (selected) 2 else 1, if (selected) 0x007AB8FF else 0x00383838);
    if (brush == null or pen == null) {
        if (brush != null) _ = c.DeleteObject(brush);
        if (pen != null) _ = c.DeleteObject(pen);
        fill(hdc, bounds, color);
        return;
    }
    const old_brush = c.SelectObject(hdc, brush);
    const old_pen = c.SelectObject(hdc, pen);
    _ = c.RoundRect(hdc, bounds.left, bounds.top, bounds.right, bounds.bottom, 12, 12);
    _ = c.SelectObject(hdc, old_pen);
    _ = c.SelectObject(hdc, old_brush);
    _ = c.DeleteObject(pen);
    _ = c.DeleteObject(brush);
}

fn drawText(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    text: []const u8,
    x: i32,
    y: i32,
    size: i32,
    color: u32,
) void {
    const wide = std.unicode.utf8ToUtf16LeAlloc(allocator, text) catch return;
    defer allocator.free(wide);
    _ = c.SetTextColor(hdc, color);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    var bounds = rect(x, y, 1200, y + size + 8);
    _ = c.DrawTextW(hdc, wide.ptr, @intCast(wide.len), &bounds, c.DT_LEFT | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);
}

test "edge connectors resolve reordered node IDs to card positions" {
    const nodes = [_]GraphModel.Node{
        .{ .id = @constCast("node-z"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
        .{ .id = @constCast("node-a"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
    };
    var state = CanvasState{};
    const from = connectorPosition(&nodes, "node-a", true, &state) orelse return error.MissingConnector;
    const to = connectorPosition(&nodes, "node-z", false, &state) orelse return error.MissingConnector;
    const expected_from = nodeBounds(1, &state);
    const expected_to = nodeBounds(0, &state);
    try std.testing.expectEqual(expected_from.right, from.x);
    try std.testing.expectEqual(@divTrunc(expected_from.top + expected_from.bottom, 2), from.y);
    try std.testing.expectEqual(expected_to.left, to.x);
    try std.testing.expectEqual(@divTrunc(expected_to.top + expected_to.bottom, 2), to.y);
    try std.testing.expect(connectorPosition(&nodes, "missing", true, &state) == null);
}

test "canvas zoom keeps the graph point beneath the cursor stable" {
    var state = CanvasState{};
    state.zoomAt(400, 300, 120);
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), state.zoom, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -40), state.pan_x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -30), state.pan_y, 0.01);
}

test "canvas hit testing follows pan and zoom" {
    var state = CanvasState{};
    state.pan_x = 20;
    state.pan_y = 10;
    state.zoom = 1.2;
    const nodes = [_]GraphModel.Node{};
    _ = nodes;
    const expected = nodeBounds(0, &state);
    const point = hitTest(&[_]GraphModel.Node{
        .{ .id = @constCast("a"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
    }, expected.left + 2, expected.top + 2, &state, rect(Tokens.sidebar_width, Tokens.header_height, 1200, 700));
    try std.testing.expectEqual(@as(?usize, 0), point);
}

test "minimum zoom hides overflow-prone card content" {
    const layout = cardTextLayout(0.55, true, true);
    try std.testing.expect(!layout.show_entry);
    try std.testing.expect(!layout.show_activity);
    try std.testing.expect(!layout.show_attention);
    try std.testing.expect(layout.state_y < @as(i32, @intFromFloat(106 * 0.55)));
}

test "attention follows awaiting input and stranded blocked semantics" {
    const nodes = [_]GraphModel.Node{
        .{ .id = @constCast("awaiting"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast("running"), .activity = @constCast(""), .presence = @constCast("awaitingInput") },
        .{ .id = @constCast("failed"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast("failed"), .activity = @constCast(""), .presence = @constCast("idle") },
        .{ .id = @constCast("blocked"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast("blocked"), .activity = @constCast(""), .presence = @constCast("idle") },
    };
    const edges = [_]GraphModel.Edge{
        .{ .from = @constCast("failed"), .to = @constCast("blocked"), .kind = @constCast("handoff"), .fired = true },
    };
    try std.testing.expect(needsAttention(nodes[0], &nodes, &edges));
    try std.testing.expect(needsAttention(nodes[2], &nodes, &edges));
    const ordinary_waiting = GraphModel.Node{
        .id = @constCast("waiting"),
        .title = @constCast(""),
        .loop_type = @constCast(""),
        .state = @constCast("waiting"),
        .activity = @constCast(""),
        .presence = @constCast("waiting"),
    };
    try std.testing.expect(!needsAttention(ordinary_waiting, &nodes, &edges));
}

test "hit testing rejects cards outside the graph viewport" {
    var state = CanvasState{};
    const nodes = [_]GraphModel.Node{
        .{ .id = @constCast("a"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
    };
    const bounds = rect(Tokens.sidebar_width, Tokens.header_height, 900, 500);
    try std.testing.expect(hitTest(&nodes, 10, 100, &state, bounds) == null);
    try std.testing.expect(hitTest(&nodes, 300, 20, &state, bounds) == null);
}
