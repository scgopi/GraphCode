const std = @import("std");
const GraphModel = @import("GraphModel.zig");
const Tokens = @import("DesignTokens.zig");
const Sidebar = @import("Sidebar.zig");
const c = @import("Win32.zig").c;

pub fn paint(
    hwnd: c.HWND,
    hdc: c.HDC,
    model: *const GraphModel.Model,
    status: []const u8,
    allocator: std.mem.Allocator,
) void {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    fill(hdc, client, Tokens.canvas_tone);
    header(hdc, allocator, client.right, status);
    Sidebar.draw(hdc, model, status, allocator);

    const graph_bounds = rect(
        Tokens.sidebar_width,
        Tokens.header_height,
        client.right,
        @max(Tokens.header_height + 1, client.bottom - Tokens.workspace_height),
    );
    fill(hdc, graph_bounds, Tokens.canvas_tone);
    drawGrid(hdc, graph_bounds);
    if (model.graph) |graph| {
        drawEdges(hdc, graph);
        for (graph.nodes.items, 0..) |node, index| {
            drawNode(hdc, allocator, node, index, model.selected_node);
        }
    } else {
        drawText(hdc, allocator, "Open a project to view its graph", Tokens.sidebar_width + 32, 120, 18, 0x00B8B8B8);
    }
}

fn header(hdc: c.HDC, allocator: std.mem.Allocator, width: i32, status: []const u8) void {
    fill(hdc, rect(0, 0, width, Tokens.header_height), Tokens.window_tone);
    drawText(hdc, allocator, "GraphCode Windows", 16, 8, 15, 0x00FFFFFF);
    drawText(hdc, allocator, status, width - 320, 9, 12, 0x00A8A8A8);
}

fn drawGrid(hdc: c.HDC, bounds: c.RECT) void {
    const pen = c.CreatePen(c.PS_SOLID, 1, Tokens.rgb(Tokens.canvas_grid_line));
    if (pen == null) return;
    const old = c.SelectObject(hdc, pen);
    var x = bounds.left;
    while (x < bounds.right) : (x += Tokens.canvas_grid_cell) {
        _ = c.MoveToEx(hdc, x, bounds.top, null);
        _ = c.LineTo(hdc, x, bounds.bottom);
    }
    var y = bounds.top;
    while (y < bounds.bottom) : (y += Tokens.canvas_grid_cell) {
        _ = c.MoveToEx(hdc, bounds.left, y, null);
        _ = c.LineTo(hdc, bounds.right, y);
    }
    _ = c.SelectObject(hdc, old);
    _ = c.DeleteObject(pen);
}

fn drawEdges(hdc: c.HDC, graph: GraphModel.Graph) void {
    const pen = c.CreatePen(c.PS_SOLID, 2, 0x005D5D5D);
    if (pen == null) return;
    const old = c.SelectObject(hdc, pen);
    for (graph.edges.items) |edge| {
        const from = connectorPosition(graph.nodes.items, edge.from, true) orelse continue;
        const to = connectorPosition(graph.nodes.items, edge.to, false) orelse continue;
        _ = c.MoveToEx(hdc, from.x, from.y, null);
        _ = c.LineTo(hdc, to.x, to.y);
    }
    _ = c.SelectObject(hdc, old);
    _ = c.DeleteObject(pen);
}

const Connector = struct {
    x: i32,
    y: i32,
};

fn connectorPosition(nodes: []const GraphModel.Node, node_id: []const u8, outgoing: bool) ?Connector {
    for (nodes, 0..) |node, index| {
        if (!std.mem.eql(u8, node.id, node_id)) continue;
        const bounds = nodeBounds(index);
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
) void {
    const bounds = nodeBounds(index);
    const x = bounds.left;
    const y = bounds.top;
    fill(hdc, bounds, if (selected == index) 0x00345D8C else 0x00262626);
    fill(hdc, rect(x, y, x + Tokens.loop_card_stripe, y + Tokens.loop_card_height), stateColor(node.state));
    drawText(hdc, allocator, node.title, x + 14, y + 16, 14, 0x00FFFFFF);
    drawText(hdc, allocator, node.state, x + 14, y + 43, 11, 0x00B8B8B8);
    if (node.activity.len != 0) drawText(hdc, allocator, node.activity, x + 14, y + 67, 10, 0x008A8A8A);
}

fn nodeBounds(index: usize) c.RECT {
    const column = @as(i32, @intCast(index % 3));
    const row = @as(i32, @intCast(index / 3));
    const x = Tokens.sidebar_width + 32 + column * 260;
    const y = Tokens.header_height + 50 + row * 140;
    return rect(x, y, x + Tokens.loop_card_width, y + Tokens.loop_card_height);
}

fn stateColor(state: []const u8) u32 {
    if (std.mem.eql(u8, state, "running")) return 0x000A84FF;
    if (std.mem.eql(u8, state, "failed")) return 0x00FF453A;
    if (std.mem.eql(u8, state, "blocked")) return 0x00FF9F0A;
    if (std.mem.eql(u8, state, "succeeded")) return 0x0030D158;
    return 0x00909090;
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
    const from = connectorPosition(&nodes, "node-a", true) orelse return error.MissingConnector;
    const to = connectorPosition(&nodes, "node-z", false) orelse return error.MissingConnector;
    const expected_from = nodeBounds(1);
    const expected_to = nodeBounds(0);
    try std.testing.expectEqual(expected_from.right, from.x);
    try std.testing.expectEqual(@divTrunc(expected_from.top + expected_from.bottom, 2), from.y);
    try std.testing.expectEqual(expected_to.left, to.x);
    try std.testing.expectEqual(@divTrunc(expected_to.top + expected_to.bottom, 2), to.y);
    try std.testing.expect(connectorPosition(&nodes, "missing", true) == null);
}
