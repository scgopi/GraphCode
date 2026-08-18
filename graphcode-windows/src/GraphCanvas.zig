const std = @import("std");
const GraphModel = @import("GraphModel.zig");
const Tokens = @import("DesignTokens.zig");
const Sidebar = @import("Sidebar.zig");
const WorktreeStatus = @import("WorktreeStatus.zig");
const WorkspaceControls = @import("WorkspaceControls.zig");
const c = @import("Win32.zig").c;

pub const CanvasState = struct {
    const NodeOffset = struct { x: f32 = 0, y: f32 = 0 };

    pan_x: f32 = 0,
    pan_y: f32 = 0,
    zoom: f32 = 1,
    dragging: bool = false,
    drag_x: i32 = 0,
    drag_y: i32 = 0,
    start_pan_x: f32 = 0,
    start_pan_y: f32 = 0,
    selected_edge: ?usize = null,
    selected_edge_id: []const u8 = "",
    edge_dragging: bool = false,
    edge_drag_source_id: []const u8 = "",
    edge_drag_x: i32 = 0,
    edge_drag_y: i32 = 0,
    node_offsets: [512]NodeOffset = [_]NodeOffset{.{}} ** 512,
    node_offset_keys: [512]u64 = [_]u64{0} ** 512,
    node_offset_used: [512]bool = [_]bool{false} ** 512,
    node_dragging: bool = false,
    node_drag_index: usize = 0,
    node_drag_key: u64 = 0,
    node_drag_x: i32 = 0,
    node_drag_y: i32 = 0,
    node_drag_origin: NodeOffset = .{},

    pub fn beginPan(self: *CanvasState, x: i32, y: i32) void {
        self.dragging = true;
        self.drag_x = x;
        self.drag_y = y;
        self.start_pan_x = self.pan_x;
        self.start_pan_y = self.pan_y;
    }

    test "toolbar actions require visible contextual controls" {
        const attention = headerAttentionRect();
        try std.testing.expectEqual(
            HeaderAction.review_attention,
            headerActionAt(attention.left + 2, attention.top + 2, 1200, true, false, false).?,
        );
        try std.testing.expect(headerActionAt(attention.left + 2, attention.top + 2, 1200, false, false, false) == null);
        const jump = headerJumpRect(1200);
        try std.testing.expectEqual(HeaderAction.jump, headerActionAt(jump.left + 2, jump.top + 2, 1200, false, false, false).?);
        const panel = headerPanelRect(1200);
        try std.testing.expect(headerActionAt(panel.left + 2, panel.top + 2, 1200, false, false, false) == null);
        try std.testing.expectEqual(HeaderAction.toggle_panel, headerActionAt(panel.left + 2, panel.top + 2, 1200, false, false, true).?);
    }

    pub fn updatePan(self: *CanvasState, x: i32, y: i32) void {
        if (!self.dragging) return;
        self.pan_x = self.start_pan_x + @as(f32, @floatFromInt(x - self.drag_x));
        self.pan_y = self.start_pan_y + @as(f32, @floatFromInt(y - self.drag_y));
    }

    pub fn endPan(self: *CanvasState) void {
        self.dragging = false;
    }

    pub fn cancelInteraction(self: *CanvasState) void {
        self.dragging = false;
        self.edge_dragging = false;
        self.edge_drag_source_id = "";
        if (self.node_dragging and self.node_drag_index < self.node_offsets.len)
            self.node_offsets[self.node_drag_index] = self.node_drag_origin;
        self.node_dragging = false;
        self.node_drag_key = 0;
    }

    pub fn beginEdgeDrag(self: *CanvasState, source_id: []const u8, x: i32, y: i32) void {
        self.edge_dragging = true;
        self.edge_drag_source_id = source_id;
        self.edge_drag_x = x;
        self.edge_drag_y = y;
    }

    pub fn updateEdgeDrag(self: *CanvasState, x: i32, y: i32) void {
        if (!self.edge_dragging) return;
        self.edge_drag_x = x;
        self.edge_drag_y = y;
    }

    pub fn beginNodeDrag(self: *CanvasState, node_id: []const u8, index: usize, x: i32, y: i32) void {
        if (index >= self.node_offsets.len) return;
        self.node_dragging = true;
        self.node_drag_index = index;
        self.node_drag_key = nodeKey(node_id);
        self.node_drag_x = x;
        self.node_drag_y = y;
        self.node_drag_origin = self.node_offsets[index];
    }

    pub fn updateNodeDrag(self: *CanvasState, x: i32, y: i32) void {
        if (!self.node_dragging or self.node_drag_index >= self.node_offsets.len) return;
        self.node_offsets[self.node_drag_index] = .{
            .x = self.node_drag_origin.x + @as(f32, @floatFromInt(x - self.node_drag_x)) / self.zoom,
            .y = self.node_drag_origin.y + @as(f32, @floatFromInt(y - self.node_drag_y)) / self.zoom,
        };
    }

    pub fn endNodeDrag(self: *CanvasState) void {
        self.node_dragging = false;
        self.node_drag_key = 0;
    }

    pub fn syncNodeOffsets(self: *CanvasState, nodes: []const GraphModel.Node) void {
        const old_offsets = self.node_offsets;
        const old_keys = self.node_offset_keys;
        const old_used = self.node_offset_used;
        self.node_offsets = [_]NodeOffset{.{}} ** self.node_offsets.len;
        self.node_offset_keys = [_]u64{0} ** self.node_offset_keys.len;
        self.node_offset_used = [_]bool{false} ** self.node_offset_used.len;

        for (nodes[0..@min(nodes.len, self.node_offsets.len)], 0..) |node, index| {
            const key = nodeKey(node.id);
            self.node_offset_keys[index] = key;
            self.node_offset_used[index] = true;
            for (old_keys, old_used, 0..) |old_key, used, old_index| {
                if (used and old_key == key) {
                    self.node_offsets[index] = old_offsets[old_index];
                    break;
                }
            }
        }
        var next = @min(nodes.len, self.node_offsets.len);
        for (old_keys, old_used, 0..) |old_key, used, old_index| {
            if (!used or next >= self.node_offsets.len) continue;
            var retained = false;
            for (self.node_offset_keys[0..next], self.node_offset_used[0..next]) |key, current_used| {
                if (current_used and key == old_key) {
                    retained = true;
                    break;
                }
            }
            if (retained) continue;
            self.node_offset_keys[next] = old_key;
            self.node_offset_used[next] = true;
            self.node_offsets[next] = old_offsets[old_index];
            next += 1;
        }

        if (self.node_dragging) {
            for (self.node_offset_keys, self.node_offset_used, 0..) |key, used, index| {
                if (used and key == self.node_drag_key) {
                    self.node_drag_index = index;
                    return;
                }
            }
            self.node_dragging = false;
            self.node_drag_key = 0;
        }
    }

    pub fn encodeNodeOffsets(self: *const CanvasState, allocator: std.mem.Allocator) ![]u8 {
        var output = std.array_list.Managed(u8).init(allocator);
        errdefer output.deinit();
        for (self.node_offset_keys, self.node_offset_used, self.node_offsets) |key, used, offset| {
            if (!used) continue;
            try output.writer().print("{x}\t{d}\t{d}\n", .{ key, offset.x, offset.y });
        }
        return output.toOwnedSlice();
    }

    pub fn decodeNodeOffsets(self: *CanvasState, data: []const u8) !void {
        var offsets = [_]NodeOffset{.{}} ** 512;
        var keys = [_]u64{0} ** 512;
        var used_entries = [_]bool{false} ** 512;
        var next: usize = 0;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const key_text = fields.next() orelse return error.InvalidCanvasLayout;
            const x_text = fields.next() orelse return error.InvalidCanvasLayout;
            const y_text = fields.next() orelse return error.InvalidCanvasLayout;
            if (fields.next() != null) return error.InvalidCanvasLayout;
            const key = try std.fmt.parseInt(u64, key_text, 16);
            const x = try std.fmt.parseFloat(f32, x_text);
            const y = try std.fmt.parseFloat(f32, y_text);
            if (!std.math.isFinite(x) or !std.math.isFinite(y) or
                @abs(x) > 100_000 or @abs(y) > 100_000)
                return error.InvalidCanvasLayout;
            var existing: ?usize = null;
            for (keys[0..next], used_entries[0..next], 0..) |stored_key, used, index| {
                if (used and stored_key == key) {
                    existing = index;
                    break;
                }
            }
            const index = existing orelse blk: {
                if (next >= offsets.len) return error.CanvasLayoutTooLarge;
                const result = next;
                next += 1;
                break :blk result;
            };
            keys[index] = key;
            used_entries[index] = true;
            offsets[index] = .{ .x = x, .y = y };
        }
        self.node_offsets = offsets;
        self.node_offset_keys = keys;
        self.node_offset_used = used_entries;
    }

    pub fn endEdgeDrag(self: *CanvasState) ?[]const u8 {
        if (!self.edge_dragging) return null;
        const source_id = self.edge_drag_source_id;
        self.edge_dragging = false;
        self.edge_drag_source_id = "";
        return source_id;
    }

    pub fn zoomAt(self: *CanvasState, x: i32, y: i32, wheel_delta: i16) void {
        const factor: f32 = if (wheel_delta > 0) 1.1 else 0.9;
        self.zoomBy(x, y, factor);
    }

    pub fn zoomBy(self: *CanvasState, x: i32, y: i32, factor: f32) void {
        const old_zoom = self.zoom;
        const next = std.math.clamp(old_zoom * factor, 0.55, 1.8);
        if (next == old_zoom) return;
        const world_x = (@as(f32, @floatFromInt(x)) - self.pan_x) / old_zoom;
        const world_y = (@as(f32, @floatFromInt(y)) - self.pan_y) / old_zoom;
        self.zoom = next;
        self.pan_x = @as(f32, @floatFromInt(x)) - world_x * next;
        self.pan_y = @as(f32, @floatFromInt(y)) - world_y * next;
    }

    pub fn actualSize(self: *CanvasState) void {
        self.zoom = 1;
        self.pan_x = 0;
        self.pan_y = 0;
    }

    pub fn fit(self: *CanvasState, bounds: c.RECT, content_width: i32, content_height: i32) void {
        if (content_width <= 0 or content_height <= 0) return;
        const viewport_width = @max(1, bounds.right - bounds.left - 48);
        const viewport_height = @max(1, bounds.bottom - bounds.top - 48);
        self.zoom = std.math.clamp(@min(
            @as(f32, @floatFromInt(viewport_width)) / @as(f32, @floatFromInt(content_width)),
            @as(f32, @floatFromInt(viewport_height)) / @as(f32, @floatFromInt(content_height)),
        ), 0.55, 1.8);
        self.pan_x = @as(f32, @floatFromInt(bounds.left + 24)) +
            (@as(f32, @floatFromInt(viewport_width)) - @as(f32, @floatFromInt(content_width)) * self.zoom) / 2;
        self.pan_y = @as(f32, @floatFromInt(bounds.top + 24)) +
            (@as(f32, @floatFromInt(viewport_height)) - @as(f32, @floatFromInt(content_height)) * self.zoom) / 2;
    }
};

fn nodeKey(id: []const u8) u64 {
    return std.hash.Wyhash.hash(0, id);
}

pub const CardTextLayout = struct {
    title_y: i32,
    state_y: i32,
    show_entry: bool,
    show_activity: bool,
    show_attention: bool,
};

pub const RenderBounds = struct { left: i32, top: i32, right: i32, bottom: i32 };
pub const Surface = enum { project, overview, quick_chats, workspace };
pub const OverviewHit = struct { graph_index: usize, node_index: usize };
pub const ZoomControl = enum { out, actual, in, fit };
pub const HeaderAction = enum { review_attention, inspect_worktrees, jump, toggle_panel };
pub const ReclaimAction = enum { reclaim, keep };
pub const ReclaimHit = struct { node_index: usize, action: ReclaimAction };

pub fn renderBounds(client_right: i32, client_bottom: i32, controls: WorkspaceControls.State) RenderBounds {
    const left = if (controls.rail_visible) Tokens.sidebar_width else 0;
    const activity = if (controls.activity_enabled) Tokens.activity_strip_height else 0;
    return .{
        .left = left,
        .top = Tokens.header_height,
        .right = client_right,
        .bottom = @max(
            Tokens.header_height + 1,
            client_bottom - (if (controls.panel_visible) Tokens.workspace_height else 0) - activity,
        ),
    };
}

pub fn paint(
    hwnd: c.HWND,
    hdc: c.HDC,
    model: *const GraphModel.Model,
    inspection: ?*const WorktreeStatus.Inspection,
    selected_worktree_path: []const u8,
    sidebar_scroll: i32,
    status: []const u8,
    update_version: []const u8,
    ingress_error: []const u8,
    declared_entries: []const []const u8,
    kept_worktrees: []const []const u8,
    allocator: std.mem.Allocator,
    state: *const CanvasState,
    controls: WorkspaceControls.State,
    surface: Surface,
) void {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    fill(hdc, client, Tokens.canvas_tone);
    const visible_inspection = if (inspection) |value|
        if (model.graph) |graph|
            if (std.mem.eql(u8, value.project_path, graph.project.path)) value else null
        else
            null
    else
        null;
    header(hdc, allocator, client.right, status, model, inspection, surface);
    if (controls.rail_visible) {
        const sidebar_bottom = if (controls.panel_visible and surface != .workspace)
            client.bottom - Tokens.workspace_height
        else
            client.bottom;
        Sidebar.draw(
            hdc,
            model,
            visible_inspection,
            selected_worktree_path,
            sidebar_scroll,
            status,
            sidebar_bottom,
            update_version,
            ingress_error,
            allocator,
        );
    }

    var presentation_controls = controls;
    if (surface == .workspace) presentation_controls.panel_visible = false;
    const bounds = renderBounds(client.right, client.bottom, presentation_controls);
    const graph_bounds = rect(bounds.left, bounds.top, bounds.right, bounds.bottom);
    fill(hdc, graph_bounds, Tokens.canvas_tone);
    const saved = c.SaveDC(hdc);
    _ = c.IntersectClipRect(hdc, graph_bounds.left, graph_bounds.top, graph_bounds.right, graph_bounds.bottom);
    drawGrid(hdc, graph_bounds, state);
    switch (surface) {
        .overview => drawOverview(hdc, allocator, model, graph_bounds, state),
        .quick_chats => drawQuickChats(hdc, allocator, model, graph_bounds, state),
        .project => if (model.graph) |graph| {
            drawCompositeBreadcrumb(hdc, allocator, model, graph_bounds);
            if (graph.nodes.items.len == 0) {
                emptyGraph(hdc, allocator, graph, graph_bounds);
            } else {
                drawEdges(hdc, graph, state);
                for (graph.nodes.items, 0..) |node, index| {
                    drawNode(hdc, allocator, node, index, model.selectedIndex(), graph.nodes.items, graph.edges.items, inspection, declared_entries, kept_worktrees, state);
                }

                drawEdgeLabels(hdc, allocator, graph, state);
            }
        } else {
            welcome(hdc, allocator, graph_bounds);
        },
        .workspace => {},
    }
    if (surface != .workspace) drawZoomControls(hdc, allocator, graph_bounds, state);

    _ = c.RestoreDC(hdc, saved);
    attentionRail(hdc, allocator, model, client.right);
    if (controls.activity_enabled) {
        const workspace_height: i32 = if (surface == .workspace) 0 else if (controls.panel_visible) Tokens.workspace_height else 0;
        activityStrip(
            hdc,
            allocator,
            model,
            rect(0, client.bottom - workspace_height - Tokens.activity_strip_height,
                client.right, client.bottom - workspace_height),
        );
    }
}

fn drawCompositeBreadcrumb(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    model: *const GraphModel.Model,
    bounds: c.RECT,
) void {
    const graph = model.graph orelse return;
    const title = model.open_composite_title orelse return;
    const label = std.fmt.allocPrint(
        allocator,
        "‹  {s}  >  {s}  ·  {d} loop{s}",
        .{ graph.project.name, title, graph.nodes.items.len, if (graph.nodes.items.len == 1) "" else "s" },
    ) catch return;
    defer allocator.free(label);
    const crumb = compositeBreadcrumbBounds(bounds);
    fill(hdc, crumb, 0x00292825);
    drawTextRect(hdc, allocator, label, crumb, 11, 0x00E6E6E6, c.DT_LEFT | c.DT_SINGLELINE | c.DT_VCENTER);
}

pub fn compositeBreadcrumbBounds(bounds: c.RECT) c.RECT {
    return rect(bounds.left + 18, bounds.top + 14, @min(bounds.right - 18, bounds.left + 520), bounds.top + 42);
}

pub fn hitTestCompositeBack(model: *const GraphModel.Model, x: i32, y: i32, bounds: c.RECT) bool {
    const crumb = compositeBreadcrumbBounds(bounds);
    return model.isCompositeOpen() and
        x >= crumb.left and x < crumb.right and y >= crumb.top and y < crumb.bottom;
}

fn drawOverview(
        hdc: c.HDC,
        allocator: std.mem.Allocator,
        model: *const GraphModel.Model,
        bounds: c.RECT,
        state: *const CanvasState,
    ) void {
        if (model.graphs.items.len == 0) {
            const center_y = bounds.top + @divTrunc(bounds.bottom - bounds.top, 2) - 60;
            drawTextRect(hdc, allocator, "Nothing running yet", rect(bounds.left + 40, center_y, bounds.right - 40, center_y + 34), 20, 0x00F2F2F2, c.DT_CENTER | c.DT_SINGLELINE);
            drawTextRect(hdc, allocator, "Loops from every folder you open show up here, wired to how they run.", rect(bounds.left + 100, center_y + 40, bounds.right - 100, center_y + 86), 13, 0x00A8A8AE, c.DT_CENTER | c.DT_WORDBREAK);
            return;
        }
        for (model.graphs.items, 0..) |graph, graph_index| {
            const lane = overviewLaneBounds(model, graph_index, bounds, state);
            roundedCard(hdc, lane, 0x001D1D21, false);
            drawText(hdc, allocator, graph.project.name, lane.left + scaledValue(18, state.zoom), lane.top + scaledValue(16, state.zoom), scaledValue(14, state.zoom), 0x00E8E8E8);
            var index: usize = 0;
            while (index < graph.nodes.items.len) : (index += 1) {
                const card = overviewCardBounds(model, graph_index, index, bounds, state);
                roundedCard(hdc, card, 0x00262626, false);
                fill(hdc, rect(card.left, card.top, card.left + scaledValue(4, state.zoom), card.bottom), stateColor(graph.nodes.items[index].state, false));
                drawText(hdc, allocator, graph.nodes.items[index].title, card.left + scaledValue(14, state.zoom), card.top + scaledValue(16, state.zoom), scaledValue(13, state.zoom), 0x00FFFFFF);
                drawText(hdc, allocator, graph.nodes.items[index].state, card.left + scaledValue(14, state.zoom), card.top + scaledValue(46, state.zoom), scaledValue(10, state.zoom), 0x00B8B8B8);
            }
        }
    }

fn drawQuickChats(
        hdc: c.HDC,
        allocator: std.mem.Allocator,
        model: *const GraphModel.Model,
        bounds: c.RECT,
        state: *const CanvasState,
    ) void {
        if (model.quick_chats.items.len == 0) {
            const center_y = bounds.top + @divTrunc(bounds.bottom - bounds.top, 2) - 60;
            drawTextRect(hdc, allocator, "No chats yet", rect(bounds.left + 40, center_y, bounds.right - 40, center_y + 34), 20, 0x00F2F2F2, c.DT_CENTER | c.DT_SINGLELINE);
            drawTextRect(hdc, allocator, "A quick chat is a bare session for questions that are not a loop's work.", rect(bounds.left + 100, center_y + 40, bounds.right - 100, center_y + 86), 13, 0x00A8A8AE, c.DT_CENTER | c.DT_WORDBREAK);
            return;
        }
        const rows = (model.quick_chats.items.len + 2) / 3;
        const band = transformedRect(bounds, state, 24, 34, @max(760, bounds.right - bounds.left - 48), @as(i32, @intCast(rows * 104 + 32)));
        roundedCard(hdc, band, 0x001D1D21, false);
        for (model.quick_chats.items, 0..) |chat, index| {
            const card = quickChatCardBounds(index, bounds, state);
            roundedCard(hdc, card, 0x00262626, false);
            fill(hdc, rect(card.left, card.top, card.left + scaledValue(4, state.zoom), card.bottom), 0x007A7A7A);
            drawText(hdc, allocator, chat.title, card.left + scaledValue(14, state.zoom), card.top + scaledValue(12, state.zoom), scaledValue(13, state.zoom), 0x00FFFFFF);
            drawText(hdc, allocator, if (std.mem.eql(u8, chat.backend, "claudeCode")) "chat" else chat.backend, card.left + scaledValue(14, state.zoom), card.top + scaledValue(37, state.zoom), scaledValue(10, state.zoom), 0x009A9A9A);
        }
}

fn overviewLaneHeight(node_count: usize) i32 {
    return @max(@as(i32, 96), @as(i32, @intCast(((node_count + 2) / 3) * 128 + 48)));
}

fn overviewLaneBounds(
    model: *const GraphModel.Model,
    graph_index: usize,
    bounds: c.RECT,
    state: *const CanvasState,
) c.RECT {
    var top: i32 = 38;
    for (model.graphs.items[0..@min(graph_index, model.graphs.items.len)]) |graph| {
        top += overviewLaneHeight(graph.nodes.items.len) + 20;
    }
    const height = if (graph_index < model.graphs.items.len)
        overviewLaneHeight(model.graphs.items[graph_index].nodes.items.len)
    else
        0;
    return transformedRect(bounds, state, 24, top, @max(760, bounds.right - bounds.left - 48), height);
}

pub fn overviewCardBounds(
    model: *const GraphModel.Model,
    graph_index: usize,
    node_index: usize,
    bounds: c.RECT,
    state: *const CanvasState,
) c.RECT {
    const lane = overviewLaneBounds(model, graph_index, bounds, state);
    const column = @as(i32, @intCast(node_index % 3));
    const row = @as(i32, @intCast(node_index / 3));
    return rect(
        lane.left + scaledValue(18 + column * 246, state.zoom),
        lane.top + scaledValue(46 + row * 122, state.zoom),
        lane.left + scaledValue(238 + column * 246, state.zoom),
        lane.top + scaledValue(132 + row * 122, state.zoom),
    );
}

pub fn quickChatCardBounds(index: usize, bounds: c.RECT, state: *const CanvasState) c.RECT {
    const column = @as(i32, @intCast(index % 3));
    const row = @as(i32, @intCast(index / 3));
    return transformedRect(bounds, state, 42 + column * 246, 54 + row * 104, 220, 64);
}

fn transformedRect(bounds: c.RECT, state: *const CanvasState, x: i32, y: i32, width: i32, height: i32) c.RECT {
    const left = @as(i32, @intFromFloat(@as(f32, @floatFromInt(bounds.left + x)) * state.zoom + state.pan_x));
    const top = @as(i32, @intFromFloat(@as(f32, @floatFromInt(bounds.top + y)) * state.zoom + state.pan_y));
    return rect(left, top, left + scaledValue(width, state.zoom), top + scaledValue(height, state.zoom));
}

fn zoomControlsBounds(bounds: c.RECT) c.RECT {
    return rect(bounds.right - 190, bounds.bottom - 48, bounds.right - 12, bounds.bottom - 12);
}

fn zoomButtonBounds(bounds: c.RECT, index: i32) c.RECT {
    const controls = zoomControlsBounds(bounds);
    const widths = [_]i32{ 36, 68, 36, 38 };
    var left = controls.left;
    var current: i32 = 0;
    while (current < index) : (current += 1) left += widths[@intCast(current)];
    return rect(left, controls.top, left + widths[@intCast(index)], controls.bottom);
}

fn drawZoomControls(hdc: c.HDC, allocator: std.mem.Allocator, bounds: c.RECT, state: *const CanvasState) void {
    roundedCard(hdc, zoomControlsBounds(bounds), 0x0026262A, false);
    const labels = [_][]const u8{ "-", "", "+", "Fit" };
    for (labels, 0..) |label, index| {
        const button = zoomButtonBounds(bounds, @intCast(index));
        if (index != 0) fill(hdc, rect(button.left, button.top + 7, button.left + 1, button.bottom - 7), 0x00454549);
        if (index == 1) {
            var percent: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&percent, "{d}%", .{@as(i32, @intFromFloat(state.zoom * 100))}) catch "100%";
            drawTextRect(hdc, allocator, text, button, 11, 0x00E0E0E0, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE);
        } else {
            drawTextRect(hdc, allocator, label, button, 11, 0x00E0E0E0, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE);
        }
    }
}

pub fn hitTestZoomControl(x: i32, y: i32, bounds: c.RECT) ?ZoomControl {
    if (!insideGraph(x, y, zoomControlsBounds(bounds))) return null;
    var index: i32 = 0;
    while (index < 4) : (index += 1) {
        const button = zoomButtonBounds(bounds, index);
        if (insideGraph(x, y, button)) return switch (index) {
            0 => .out,
            1 => .actual,
            2 => .in,
            else => .fit,
        };
    }
    return null;
}

pub fn contentSize(model: *const GraphModel.Model, surface: Surface) struct { width: i32, height: i32 } {
    return switch (surface) {
        .overview => blk: {
            var height: i32 = 38;
            for (model.graphs.items) |graph| height += overviewLaneHeight(graph.nodes.items.len) + 20;
            break :blk .{ .width = 808, .height = @max(1, height) };
        },
        .quick_chats => .{
            .width = 808,
            .height = @max(1, @as(i32, @intCast(((model.quick_chats.items.len + 2) / 3) * 104 + 66))),
        },
        .project => if (model.graph) |graph| .{
            .width = @max(1, @as(i32, @intCast(@min(graph.nodes.items.len, 3))) * 260 + 64),
            .height = @max(1, @as(i32, @intCast((graph.nodes.items.len + 2) / 3)) * 140 + 100),
        } else .{ .width = 1, .height = 1 },
        .workspace => .{ .width = 1, .height = 1 },
    };
}

pub fn hitTestOverview(
    model: *const GraphModel.Model,
    x: i32,
    y: i32,
    state: *const CanvasState,
    graph_bounds: c.RECT,
) ?OverviewHit {
    if (!insideGraph(x, y, graph_bounds)) return null;
    var graph_index = model.graphs.items.len;
    while (graph_index > 0) {
        graph_index -= 1;
        const nodes = model.graphs.items[graph_index].nodes.items;
        var node_index = nodes.len;
        while (node_index > 0) {
            node_index -= 1;
            const bounds = overviewCardBounds(model, graph_index, node_index, graph_bounds, state);
            if (x >= bounds.left and x < bounds.right and y >= bounds.top and y < bounds.bottom) {
                return .{ .graph_index = graph_index, .node_index = node_index };
            }
        }
    }
    return null;
}

pub fn hitTestQuickChat(
    chat_count: usize,
    x: i32,
    y: i32,
    state: *const CanvasState,
    graph_bounds: c.RECT,
) ?usize {
    if (!insideGraph(x, y, graph_bounds)) return null;
    var index = chat_count;
    while (index > 0) {
        index -= 1;
        const bounds = quickChatCardBounds(index, graph_bounds, state);
        if (x >= bounds.left and x < bounds.right and y >= bounds.top and y < bounds.bottom) return index;
    }
    return null;
}

fn welcome(hdc: c.HDC, allocator: std.mem.Allocator, bounds: c.RECT) void {
    const center_y = bounds.top + @divTrunc(bounds.bottom - bounds.top, 2) - 70;
    drawTextRect(hdc, allocator, "◇", rect(bounds.left, center_y - 54, bounds.right, center_y - 10), 34, 0x008A8A8A, c.DT_CENTER | c.DT_SINGLELINE);
    drawTextRect(hdc, allocator, "Create a graph of loops for a folder", rect(bounds.left + 40, center_y, bounds.right - 40, center_y + 34), 22, 0x00F2F2F2, c.DT_CENTER | c.DT_SINGLELINE);
    drawTextRect(
        hdc,
        allocator,
        "Open a folder or git repository to start orchestrating a graph of AI coding loops in it.",
        rect(bounds.left + 100, center_y + 42, bounds.right - 100, center_y + 92),
        13,
        0x00A8A8AE,
        c.DT_CENTER | c.DT_WORDBREAK,
    );
}

fn emptyGraph(hdc: c.HDC, allocator: std.mem.Allocator, graph: GraphModel.Graph, bounds: c.RECT) void {
    const center_y = bounds.top + @divTrunc(bounds.bottom - bounds.top, 2) - 60;
    const title = if (graph.project.isGlobal()) "Nothing running yet" else "No loops yet";
    const message = if (graph.project.isGlobal())
        "Loops from every folder you open show up here, wired to how they run."
    else
        "Create the first loop in this folder to start its graph.";
    drawTextRect(hdc, allocator, title, rect(bounds.left + 40, center_y, bounds.right - 40, center_y + 34), 20, 0x00F2F2F2, c.DT_CENTER | c.DT_SINGLELINE);
    drawTextRect(hdc, allocator, message, rect(bounds.left + 100, center_y + 40, bounds.right - 100, center_y + 86), 13, 0x00A8A8AE, c.DT_CENTER | c.DT_WORDBREAK);
}

test "workspace controls change graph render bounds" {
    const shown = renderBounds(1200, 900, .{});
    const hidden = renderBounds(1200, 900, .{ .rail_visible = false, .activity_enabled = false });
    try std.testing.expectEqual(@as(i32, Tokens.sidebar_width), shown.left);
    try std.testing.expectEqual(@as(i32, 0), hidden.left);
    try std.testing.expect(hidden.bottom > shown.bottom);
}

fn header(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    width: i32,
    status: []const u8,
    model: *const GraphModel.Model,
    inspection: ?*const WorktreeStatus.Inspection,
    surface: Surface,
) void {
    fill(hdc, rect(0, 0, width, Tokens.header_height), Tokens.window_tone);
    if (surface == .workspace and model.currentGraph() != null) {
        const project = model.currentGraph().?.project;
        drawText(hdc, allocator, project.name, 16, 7, 15, 0x00FFFFFF);
        drawText(hdc, allocator, if (project.isRemote()) "Remote" else "Local folder", 172, 10, 11, 0x008E8E93);
    } else {
        drawText(hdc, allocator, "GraphCode Windows", 16, 8, 15, 0x00FFFFFF);
    }
    if (model.attentionCount() != 0) {
        const bounds = headerAttentionRect();
        fill(hdc, bounds, 0x00352B1C);
        var buffer: [48]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "{d} need you", .{model.attentionCount()}) catch "Needs you";
        drawTextRect(hdc, allocator, label, bounds, 10, 0x00FFCD7A, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
    }
    if (inspection) |value| {
        const summary = WorktreeStatus.summarize(value.entries.items);
        const bounds = headerWorktreeRect();
        fill(hdc, bounds, 0x002D2418);
        var buffer: [64]u8 = undefined;
        const label = if (summary.reclaimable != 0)
            std.fmt.bufPrint(&buffer, "{d} reclaimable", .{summary.reclaimable}) catch "Worktrees"
        else
            std.fmt.bufPrint(&buffer, "{d} worktrees", .{summary.total}) catch "Worktrees";
        drawTextRect(hdc, allocator, label, bounds, 10, 0x00FFCD7A, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
    }
    const jump = headerJumpRect(width);
    fill(hdc, jump, 0x00282828);
    drawTextRect(hdc, allocator, "Jump to loop   Ctrl+P", jump, 10, 0x00B8B8B8, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
    if (model.currentGraph() != null) {
        const panel = headerPanelRect(width);
        fill(hdc, panel, 0x00282828);
        drawTextRect(hdc, allocator, if (surface == .workspace) "Hide loop panel" else "Loop panel", panel, 10, 0x00D8D8D8, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
    }
    drawText(hdc, allocator, status, width - 270, 9, 11, 0x00A8A8A8);
}

pub fn headerAttentionRect() c.RECT {
    return rect(220, 5, 330, Tokens.header_height - 5);
}

pub fn headerWorktreeRect() c.RECT {
    return rect(338, 5, 458, Tokens.header_height - 5);
}

pub fn headerJumpRect(width: i32) c.RECT {
    return rect(width - 560, 5, width - 400, Tokens.header_height - 5);
}

pub fn headerPanelRect(width: i32) c.RECT {
    return rect(width - 390, 5, width - 280, Tokens.header_height - 5);
}

pub fn headerActionAt(
    x: i32,
    y: i32,
    width: i32,
    has_attention: bool,
    has_worktrees: bool,
    has_graph: bool,
) ?HeaderAction {
    if (y < 0 or y >= Tokens.header_height) return null;
    if (has_attention and insideGraph(x, y, headerAttentionRect())) return .review_attention;
    if (has_worktrees and insideGraph(x, y, headerWorktreeRect())) return .inspect_worktrees;
    if (insideGraph(x, y, headerJumpRect(width))) return .jump;
    if (has_graph and insideGraph(x, y, headerPanelRect(width))) return .toggle_panel;
    return null;
}

fn attentionRail(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    model: *const GraphModel.Model,
    width: i32,
) void {
    if (model.attentionCount() == 0) return;
    var count: [32]u8 = undefined;
    const label = if (model.attentionCount() == 1)
        "1 loop needs you"
    else
        std.fmt.bufPrint(&count, "{d} loops need you", .{model.attentionCount()}) catch "loops need you";
    fill(hdc, rect(Tokens.sidebar_width + 20, Tokens.header_height + 12, width - 20, Tokens.header_height + 43), 0x002D2418);
    drawText(hdc, allocator, label, Tokens.sidebar_width + 34, Tokens.header_height + 21, 12, 0x00FFCD7A);
    drawText(hdc, allocator, "Ctrl+Tab review", Tokens.sidebar_width + 210, Tokens.header_height + 21, 11, 0x00B8B8B8);
}

fn activityStrip(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    model: *const GraphModel.Model,
    bounds: c.RECT,
) void {
    fill(hdc, bounds, 0x001D1D21);
    drawText(hdc, allocator, "ACTIVITY", bounds.left + 16, bounds.top + 10, 10, 0x007A7A7A);
    var count_buffer: [32]u8 = undefined;
    const summary = std.fmt.bufPrint(&count_buffer, "{d} recent", .{model.activity.items.len}) catch "recent";
    drawText(hdc, allocator, summary, bounds.left + 76, bounds.top + 10, 10, 0x00909098);
    var x = bounds.left + 142;
    const visible_count = @min(model.activity.items.len, 4);
    const start = model.activity.items.len - visible_count;
    for (model.activity.items[start..]) |event| {
        const card = rect(x, bounds.top + 5, @min(x + 176, bounds.right - 8), bounds.bottom - 5);
        if (card.right <= card.left) break;
        roundedCard(hdc, card, 0x0026262B, false);
        fill(hdc, rect(card.left, card.top, card.left + 3, card.bottom), stateColor(event.state, false));
        drawText(hdc, allocator, event.title, card.left + 10, card.top + 7, 10, 0x00D8D8DE);
        drawText(hdc, allocator, compactActivityState(event.state), card.left + 10, card.top + 22, 9, stateColor(event.state, false));
        x += 184;
        if (x >= bounds.right - 80) break;
    }
}

fn compactActivityState(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "succeeded")) return "completed";
    if (std.mem.eql(u8, state, "awaitingInput")) return "needs attention";
    return state;
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
    for (graph.edges.items, 0..) |edge, index| {
        const from = connectorPosition(graph.nodes.items, edge.from, true, state) orelse continue;
        const to = connectorPosition(graph.nodes.items, edge.to, false, state) orelse continue;
        const selected = if (state.selected_edge_id.len != 0)
            std.mem.eql(u8, edge.id, state.selected_edge_id)
        else
            state.selected_edge == index;
        const color = if (selected)
            Tokens.rgb(Tokens.canvas_selection)
        else if (edge.fired or edge.fire_count != 0)
            0x006BD58D
        else
            edgeKindColor(edge.kind);
        drawBezier(hdc, from, to, color, edgeKindPenStyle(edge.kind));
    }
    if (state.edge_dragging) {
        if (state.edge_drag_source_id.len != 0) {
            if (connectorPosition(graph.nodes.items, state.edge_drag_source_id, true, state)) |from| {
                drawBezier(hdc, from, .{ .x = state.edge_drag_x, .y = state.edge_drag_y }, Tokens.rgb(Tokens.canvas_selection), c.PS_SOLID);
            }
        }
    }
}

fn drawEdgeLabels(hdc: c.HDC, allocator: std.mem.Allocator, graph: GraphModel.Graph, state: *const CanvasState) void {
    for (graph.edges.items, 0..) |edge, index| {
        const from = connectorPosition(graph.nodes.items, edge.from, true, state) orelse continue;
        const to = connectorPosition(graph.nodes.items, edge.to, false, state) orelse continue;
        const selected = if (state.selected_edge_id.len != 0)
            std.mem.eql(u8, edge.id, state.selected_edge_id)
        else
            state.selected_edge == index;
        const color = if (selected)
            Tokens.rgb(Tokens.canvas_selection)
        else if (edge.fired or edge.fire_count != 0)
            0x006BD58D
        else
            edgeKindColor(edge.kind);
        var label_buffer: [128]u8 = undefined;
        const label = edgeLabel(&label_buffer, edge);
        const center_x = @divTrunc(from.x + to.x, 2);
        const label_y = if (@abs(to.y - from.y) < 40)
            @min(from.y, to.y) - 76
        else
            @divTrunc(from.y + to.y, 2) - 10;
        const bounds = rect(center_x - 74, label_y, center_x + 74, label_y + 20);
        fill(hdc, bounds, Tokens.canvas_tone);
        drawTextRect(hdc, allocator, label, bounds, 10, color, c.DT_CENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);
    }
}

fn edgeKindPenStyle(kind: []const u8) c_int {
    if (std.mem.eql(u8, kind, "message")) return c.PS_DOT;
    if (std.mem.eql(u8, kind, "spawn")) return c.PS_DASH;
    return c.PS_SOLID;
}

fn edgeKindColor(kind: []const u8) u32 {
    if (std.mem.eql(u8, kind, "message")) return 0x00D6A649;
    if (std.mem.eql(u8, kind, "spawn")) return 0x00C77DFF;
    return Tokens.rgb(Tokens.canvas_edge);
}

fn edgeLabel(buffer: []u8, edge: GraphModel.Edge) []const u8 {
    const kind = if (edge.kind.len == 0) "handoff" else edge.kind;
    if (edge.fire_count != 0)
        return std.fmt.bufPrint(buffer, "{s} · {s} · fired {d}", .{ kind, edge.condition, edge.fire_count }) catch kind;
    if (!std.mem.eql(u8, edge.condition, "always"))
        return std.fmt.bufPrint(buffer, "{s} · {s}", .{ kind, edge.condition }) catch kind;
    return kind;
}

fn drawBezier(hdc: c.HDC, from: Connector, to: Connector, color: u32, style: c_int) void {
    const pen = c.CreatePen(style, if (style == c.PS_SOLID) 2 else 1, color);
    if (pen == null) return;
    const old = c.SelectObject(hdc, pen);
    const distance: i32 = if (to.x >= from.x) to.x - from.x else from.x - to.x;
    const bend: i32 = @max(@as(i32, 24), @divTrunc(distance, 2));
    var points = [_]c.POINT{
        .{ .x = from.x, .y = from.y },
        .{ .x = from.x + bend, .y = from.y },
        .{ .x = to.x - bend, .y = to.y },
        .{ .x = to.x, .y = to.y },
    };
    _ = c.PolyBezier(hdc, &points, 4);
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
        return connectorPositionForIndex(nodes, index, outgoing, state);
    }
    return null;
}

fn connectorPositionForIndex(nodes: []const GraphModel.Node, index: usize, outgoing: bool, state: *const CanvasState) Connector {
    _ = nodes;
    const bounds = nodeBounds(index, state);
    return .{
        .x = if (outgoing) bounds.right else bounds.left,
        .y = @divTrunc(bounds.top + bounds.bottom, 2),
    };
}

fn drawNode(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    node: GraphModel.Node,
    index: usize,
    selected: ?usize,
    nodes: []const GraphModel.Node,
    edges: []const GraphModel.Edge,
    inspection: ?*const WorktreeStatus.Inspection,
    declared_entries: []const []const u8,
    kept_worktrees: []const []const u8,
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
    const role = nodeRole(edges, node.id, declared_entries);
    const reclaim_offer = hasReclaimOffer(node, inspection, kept_worktrees);
    const layout = cardTextLayout(state.zoom, role == .entry, attention);
    if (layout.show_entry) drawText(hdc, allocator, "START", x + scaled(14, state), y + layout.title_y - scaled(10, state), scaled(9, state), 0x008A8A8A);
    if (role == .unwired) drawText(hdc, allocator, "UNWIRED", x + scaled(14, state), y + layout.title_y - scaled(10, state), scaled(9, state), 0x00FFCD7A);
    drawText(hdc, allocator, node.title, x + scaled(14, state), y + layout.title_y, scaled(14, state), 0x00FFFFFF);
    drawText(hdc, allocator, node.state, x + scaled(14, state), y + layout.state_y, scaled(11, state), if (attention) 0x00FFB340 else 0x00B8B8B8);
    if (layout.show_activity) {
        const primary = nodePrimaryDetail(node);
        if (primary.len != 0)
            drawText(hdc, allocator, primary, x + scaled(14, state), y + layout.state_y + scaled(20, state), scaled(9, state), 0x00A8A8A8);
        if (node.activity.len != 0 and !std.mem.eql(u8, node.activity, primary))
            drawText(hdc, allocator, node.activity, x + scaled(14, state), y + layout.state_y + scaled(35, state), scaled(9, state), 0x008A8A8A);
        var metadata_buffer: [128]u8 = undefined;
        const metadata = nodeMetadata(&metadata_buffer, node);
        if (metadata.len != 0 and (role != .unwired or reclaim_offer))
            drawText(hdc, allocator, metadata, x + scaled(14, state), y + layout.state_y + scaled(43, state), scaled(8, state), 0x007A7A7A);
        if (role == .unwired and !reclaim_offer)
            drawText(hdc, allocator, "No connections · right-click to recover", x + scaled(14, state), y + layout.state_y + scaled(43, state), scaled(8, state), 0x00FFCD7A);
    }
    if (layout.show_attention) drawText(hdc, allocator, "NEEDS YOU", bounds.right - scaled(88, state), y + scaled(8, state), scaled(9, state), 0x00FFB340);
    if (reclaim_offer) {
        const offer = reclaimOfferBounds(bounds);
        fill(hdc, offer.reclaim, 0x003A3A44);
        drawTextRect(hdc, allocator, "Reclaim", offer.reclaim, scaled(9, state), 0x00E6E6E6, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
        drawTextRect(hdc, allocator, "Keep", offer.keep, scaled(9, state), 0x008A8A8A, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
    }
}

const ReclaimOfferBounds = struct { reclaim: c.RECT, keep: c.RECT };

fn reclaimOfferBounds(bounds: c.RECT) ReclaimOfferBounds {
    return .{
        .reclaim = rect(bounds.left + 12, bounds.bottom - 24, bounds.left + 78, bounds.bottom - 5),
        .keep = rect(bounds.left + 84, bounds.bottom - 24, bounds.left + 126, bounds.bottom - 5),
    };
}

fn hasReclaimOffer(
    node: GraphModel.Node,
    inspection: ?*const WorktreeStatus.Inspection,
    kept_worktrees: []const []const u8,
) bool {
    if (!std.mem.eql(u8, node.state, "succeeded") or node.worktree_path.len == 0) return false;
    for (kept_worktrees) |path| if (std.mem.eql(u8, path, node.worktree_path)) return false;
    const value = inspection orelse return false;
    for (value.entries.items) |entry| {
        if (std.mem.eql(u8, entry.path, node.worktree_path))
            return WorktreeStatus.decision(entry) == .reclaimable;
    }
    return false;
}

pub fn hitTestReclaimOffer(
    nodes: []const GraphModel.Node,
    inspection: ?*const WorktreeStatus.Inspection,
    kept_worktrees: []const []const u8,
    x: i32,
    y: i32,
    state: *const CanvasState,
) ?ReclaimHit {
    var index = nodes.len;
    while (index > 0) {
        index -= 1;
        if (!hasReclaimOffer(nodes[index], inspection, kept_worktrees)) continue;
        const offer = reclaimOfferBounds(nodeBounds(index, state));
        if (insideGraph(x, y, offer.reclaim)) return .{ .node_index = index, .action = .reclaim };
        if (insideGraph(x, y, offer.keep)) return .{ .node_index = index, .action = .keep };
    }
    return null;
}

fn nodePrimaryDetail(node: GraphModel.Node) []const u8 {
    if (node.goal_summary.len != 0) return node.goal_summary;
    if (node.trigger_prompt.len != 0) return node.trigger_prompt;
    if (node.check_description.len != 0) return node.check_description;
    return node.activity;
}

fn nodeMetadata(buffer: []u8, node: GraphModel.Node) []const u8 {
    if (node.worktree_branch.len != 0 and node.model_tier.len != 0)
        return std.fmt.bufPrint(buffer, "{s} · {s}", .{ node.worktree_branch, node.model_tier }) catch node.worktree_branch;
    if (node.worktree_branch.len != 0) return node.worktree_branch;
    if (node.model_tier.len != 0) return node.model_tier;
    if (node.metric_command.len != 0)
        return std.fmt.bufPrint(buffer, "metric · {s}", .{if (node.metric_direction.len != 0) node.metric_direction else "configured"}) catch "metric";
    return "";
}

pub fn nodeBounds(index: usize, state: *const CanvasState) c.RECT {
    const column = @as(i32, @intCast(index % 3));
    const row = @as(i32, @intCast(index / 3));
    const offset = if (index < state.node_offsets.len) state.node_offsets[index] else CanvasState.NodeOffset{};
    const x = @as(i32, @intFromFloat(((@as(f32, @floatFromInt(Tokens.sidebar_width + 32 + column * 260)) + offset.x) * state.zoom) + state.pan_x));
    const y = @as(i32, @intFromFloat(((@as(f32, @floatFromInt(Tokens.header_height + 50 + row * 140)) + offset.y) * state.zoom) + state.pan_y));
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
        if (!std.mem.eql(u8, edge.to, node.id) or !std.mem.eql(u8, edge.kind, "handoff") or edge.fired) continue;
        var source_found = false;
        for (nodes) |source| {
            if (std.mem.eql(u8, source.id, edge.from)) {
                source_found = true;
                if (!(std.mem.eql(u8, source.state, "failed") or std.mem.eql(u8, source.state, "stalled") or
                    std.mem.eql(u8, source.state, "succeeded") or std.mem.eql(u8, source.state, "stopped")))
                {
                    return false;
                }
            }
        }
        if (!source_found) return false;
        // Continue checking every unfired handoff input; all must be resolved.
    }
    for (edges) |edge| {
        if (std.mem.eql(u8, edge.to, node.id) and std.mem.eql(u8, edge.kind, "handoff") and !edge.fired) return true;
    }
    return false;
}

const NodeRole = enum { interior, entry, unwired };

fn nodeRole(edges: []const GraphModel.Edge, node_id: []const u8, declared_entries: []const []const u8) NodeRole {
    var inbound = false;
    var outbound = false;
    for (edges) |edge| {
        if (std.mem.eql(u8, edge.to, node_id)) inbound = true;
        if (std.mem.eql(u8, edge.from, node_id)) outbound = true;
    }
    if (inbound) return .interior;
    if (outbound) return .entry;
    for (declared_entries) |id| if (std.mem.eql(u8, id, node_id)) return .entry;
    return .unwired;
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

pub fn hitTestConnector(nodes: []const GraphModel.Node, x: i32, y: i32, state: *const CanvasState, graph_bounds: c.RECT) ?usize {
    if (!insideGraph(x, y, graph_bounds)) return null;
    for (nodes, 0..) |_, index| {
        const connector = connectorPositionForIndex(nodes, index, true, state);
        if (distanceSquared(x, y, connector.x, connector.y) <= connectorRadius(state) * connectorRadius(state)) return index;
    }
    return null;
}

pub fn hitTestEdge(
    nodes: []const GraphModel.Node,
    edges: []const GraphModel.Edge,
    x: i32,
    y: i32,
    state: *const CanvasState,
    graph_bounds: c.RECT,
) ?usize {
    if (!insideGraph(x, y, graph_bounds)) return null;
    for (edges, 0..) |edge, index| {
        const from = connectorPosition(nodes, edge.from, true, state) orelse continue;
        const to = connectorPosition(nodes, edge.to, false, state) orelse continue;
        if (bezierDistanceSquared(from, to, x, y) <= edgeHitRadius(state) * edgeHitRadius(state)) return index;
    }
    return null;
}

fn insideGraph(x: i32, y: i32, bounds: c.RECT) bool {
    return x >= bounds.left and x < bounds.right and y >= bounds.top and y < bounds.bottom;
}

fn connectorRadius(state: *const CanvasState) i32 {
    return @max(7, @as(i32, @intFromFloat(9 * state.zoom)));
}

fn edgeHitRadius(state: *const CanvasState) i32 {
    return @max(6, @as(i32, @intFromFloat(8 * state.zoom)));
}

fn distanceSquared(x1: i32, y1: i32, x2: i32, y2: i32) i32 {
    const dx = x1 - x2;
    const dy = y1 - y2;
    return dx * dx + dy * dy;
}

fn bezierDistanceSquared(from: Connector, to: Connector, x: i32, y: i32) i32 {
    const distance: i32 = if (to.x >= from.x) to.x - from.x else from.x - to.x;
    const bend: i32 = @max(@as(i32, 24), @divTrunc(distance, 2));
    var previous = from;
    var best: i32 = std.math.maxInt(i32);
    var step: i32 = 1;
    while (step <= 24) : (step += 1) {
        const t = @as(f32, @floatFromInt(step)) / 24.0;
        const one = 1.0 - t;
        const px = @as(f32, @floatFromInt(from.x)) * one * one * one +
            @as(f32, @floatFromInt(from.x + bend)) * 3 * one * one * t +
            @as(f32, @floatFromInt(to.x - bend)) * 3 * one * t * t +
            @as(f32, @floatFromInt(to.x)) * t * t * t;
        const py = @as(f32, @floatFromInt(from.y)) * one * one * one +
            @as(f32, @floatFromInt(from.y)) * 3 * one * one * t +
            @as(f32, @floatFromInt(to.y)) * 3 * one * t * t +
            @as(f32, @floatFromInt(to.y)) * t * t * t;
        const current = Connector{ .x = @intFromFloat(px), .y = @intFromFloat(py) };
        best = @min(best, segmentDistanceSquared(previous, current, x, y));
        previous = current;
    }
    return best;
}

fn segmentDistanceSquared(a: Connector, b: Connector, x: i32, y: i32) i32 {
    const ax = @as(f32, @floatFromInt(a.x));
    const ay = @as(f32, @floatFromInt(a.y));
    const bx = @as(f32, @floatFromInt(b.x));
    const by = @as(f32, @floatFromInt(b.y));
    const dx = bx - ax;
    const dy = by - ay;
    const denominator = dx * dx + dy * dy;
    const raw = if (denominator == 0) 0 else ((@as(f32, @floatFromInt(x)) - ax) * dx +
        (@as(f32, @floatFromInt(y)) - ay) * dy) / denominator;
    const t = std.math.clamp(raw, 0, 1);
    const px = ax + dx * t;
    const py = ay + dy * t;
    const ex = @as(f32, @floatFromInt(x)) - px;
    const ey = @as(f32, @floatFromInt(y)) - py;
    return @intFromFloat(ex * ex + ey * ey);
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

pub fn paintLoopDetailRail(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    graph: *const GraphModel.GraphSummary,
    selected_index: usize,
    client_right: i32,
    client_bottom: i32,
) void {
    if (selected_index >= graph.nodes.items.len) return;
    const left = @max(0, client_right - Tokens.loop_detail_width);
    const top = Tokens.header_height;
    const node = graph.nodes.items[selected_index];
    fill(hdc, rect(left, top, client_right, client_bottom), 0x0028282C);
    fill(hdc, rect(left, top, left + 1, client_bottom), 0x0045454B);
    drawText(hdc, allocator, "LOOP MAP", left + 18, top + 16, 11, 0x009898A0);

    const map_top = top + 44;
    roundedCard(hdc, rect(left + 18, map_top, client_right - 18, map_top + 72), 0x00303035, false);
    const center_x = left + @divTrunc(Tokens.loop_detail_width, 2);
    const center_y = map_top + 36;
    for (graph.edges.items) |edge| {
        const upstream = std.mem.eql(u8, edge.to, node.id);
        const downstream = std.mem.eql(u8, edge.from, node.id);
        if (!upstream and !downstream) continue;
        const other_x = if (upstream) center_x - 72 else center_x + 72;
        const pen = c.CreatePen(c.PS_SOLID, 2, if (edge.fired) 0x0058C878 else 0x00606068);
        if (pen != null) {
            const old = c.SelectObject(hdc, pen);
            _ = c.MoveToEx(hdc, if (upstream) other_x + 8 else center_x + 8, center_y, null);
            _ = c.LineTo(hdc, if (upstream) center_x - 8 else other_x - 8, center_y);
            _ = c.SelectObject(hdc, old);
            _ = c.DeleteObject(pen);
        }
        drawDot(hdc, other_x, center_y, if (edge.fired) 0x0058C878 else 0x00606068, 6);
    }
    drawDot(hdc, center_x, center_y, 0x00FFAE5A, 8);

    var y = map_top + 92;
    drawText(hdc, allocator, "UPSTREAM", left + 18, y, 11, 0x009898A0);
    y += 24;
    var upstream_count: usize = 0;
    for (graph.edges.items) |edge| {
        if (!std.mem.eql(u8, edge.to, node.id)) continue;
        upstream_count += 1;
        paintRelationRow(hdc, allocator, graph, edge.from, edge.condition, edge.fired, left, y);
        y += 42;
        if (upstream_count == 3) break;
    }
    if (upstream_count == 0) {
        drawText(hdc, allocator, "No incoming loops", left + 28, y, 12, 0x007A7A82);
        y += 34;
    }

    y += 8;
    drawText(hdc, allocator, "DOWNSTREAM", left + 18, y, 11, 0x009898A0);
    y += 24;
    var downstream_count: usize = 0;
    for (graph.edges.items) |edge| {
        if (!std.mem.eql(u8, edge.from, node.id)) continue;
        downstream_count += 1;
        paintRelationRow(hdc, allocator, graph, edge.to, edge.condition, edge.fired, left, y);
        y += 42;
        if (downstream_count == 3) break;
    }
    if (downstream_count == 0) {
        drawText(hdc, allocator, "No outgoing loops", left + 28, y, 12, 0x007A7A82);
        y += 34;
    }

    const footer_top = @max(y + 18, client_bottom - 148);
    fill(hdc, rect(left + 18, footer_top, client_right - 18, footer_top + 1), 0x0045454B);
    drawText(hdc, allocator, "DETAIL", left + 18, footer_top + 14, 11, 0x009898A0);
    const branch = if (node.worktree_branch.len != 0) node.worktree_branch else if (node.worktree_path.len != 0) node.worktree_path else "Primary checkout";
    drawText(hdc, allocator, branch, left + 18, footer_top + 38, 12, 0x00D8D8DE);
    const metric = if (node.metric_command.len != 0) node.metric_command else if (node.goal_summary.len != 0) node.goal_summary else "No metric configured";
    drawText(hdc, allocator, metric, left + 18, footer_top + 62, 12, 0x009898A0);
    if (node.model_tier.len != 0) drawText(hdc, allocator, node.model_tier, left + 18, footer_top + 86, 12, 0x007AB8FF);
}

fn paintRelationRow(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    graph: *const GraphModel.GraphSummary,
    node_id: []const u8,
    condition: []const u8,
    fired: bool,
    left: i32,
    y: i32,
) void {
    roundedCard(hdc, rect(left + 18, y, left + Tokens.loop_detail_width - 18, y + 34), 0x00303035, false);
    drawDot(hdc, left + 31, y + 17, if (fired) 0x0058C878 else 0x00686870, 4);
    drawText(hdc, allocator, nodeTitle(graph, node_id), left + 44, y + 7, 12, 0x00E0E0E5);
    if (!std.mem.eql(u8, condition, "always"))
        drawText(hdc, allocator, condition, left + Tokens.loop_detail_width - 92, y + 7, 10, 0x009898A0);
}

fn nodeTitle(graph: *const GraphModel.GraphSummary, id: []const u8) []const u8 {
    for (graph.nodes.items) |node| if (std.mem.eql(u8, node.id, id)) return node.title;
    return "Unknown loop";
}

fn drawDot(hdc: c.HDC, x: i32, y: i32, color: u32, radius: i32) void {
    const brush = c.CreateSolidBrush(color);
    if (brush == null) return;
    const old = c.SelectObject(hdc, brush);
    _ = c.Ellipse(hdc, x - radius, y - radius, x + radius, y + radius);
    _ = c.SelectObject(hdc, old);
    _ = c.DeleteObject(brush);
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

fn drawTextRect(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    text_value: []const u8,
    bounds_value: c.RECT,
    size: i32,
    color: u32,
    format: c.UINT,
) void {
    const wide = std.unicode.utf8ToUtf16LeAlloc(allocator, text_value) catch return;
    defer allocator.free(wide);
    const font = c.CreateFontW(
        -size, 0, 0, 0, c.FW_NORMAL, 0, 0, 0, c.DEFAULT_CHARSET,
        c.OUT_DEFAULT_PRECIS, c.CLIP_DEFAULT_PRECIS, c.CLEARTYPE_QUALITY,
        c.DEFAULT_PITCH | c.FF_DONTCARE,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI").ptr,
    );
    const old_font = if (font != null) c.SelectObject(hdc, font) else null;
    _ = c.SetTextColor(hdc, color);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    var bounds = bounds_value;
    _ = c.DrawTextW(hdc, wide.ptr, @intCast(wide.len), &bounds, format);
    if (font != null) {
        _ = c.SelectObject(hdc, old_font);
        _ = c.DeleteObject(font);
    }
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

test "direct node movement follows zoom and cancels safely" {
    var state = CanvasState{ .zoom = 2 };
    const nodes = [_]GraphModel.Node{
        .{ .id = @constCast("a"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
    };
    state.syncNodeOffsets(&nodes);
    const before = nodeBounds(0, &state);
    state.beginNodeDrag("a", 0, before.left, before.top);
    state.updateNodeDrag(before.left + 40, before.top + 20);
    const moved = nodeBounds(0, &state);
    try std.testing.expectEqual(before.left + 40, moved.left);
    try std.testing.expectEqual(before.top + 20, moved.top);
    state.cancelInteraction();
    const restored = nodeBounds(0, &state);
    try std.testing.expectEqual(before.left, restored.left);
    try std.testing.expectEqual(before.top, restored.top);
    state.beginNodeDrag("a", 0, before.left, before.top);
    state.updateNodeDrag(before.left + 30, before.top + 10);
    state.endNodeDrag();
    try std.testing.expectEqual(before.left + 30, nodeBounds(0, &state).left);
}

test "direct node movement follows stable node identity across daemon reorder" {
    var state = CanvasState{};
    const initial = [_]GraphModel.Node{
        .{ .id = @constCast("a"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
        .{ .id = @constCast("b"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
    };
    state.syncNodeOffsets(&initial);
    const before_a = nodeBounds(0, &state);
    state.beginNodeDrag("a", 0, before_a.left, before_a.top);
    state.updateNodeDrag(before_a.left + 30, before_a.top + 10);
    state.endNodeDrag();

    const reordered = [_]GraphModel.Node{ initial[1], initial[0] };
    state.syncNodeOffsets(&reordered);
    const moved_a = nodeBounds(1, &state);
    const unmoved_b = nodeBounds(0, &state);
    try std.testing.expectEqual(@as(i32, Tokens.sidebar_width + 32 + 260 + 30), moved_a.left);
    try std.testing.expectEqual(@as(i32, Tokens.header_height + 50 + 10), moved_a.top);
    try std.testing.expectEqual(@as(i32, Tokens.sidebar_width + 32), unmoved_b.left);
    try std.testing.expectEqual(@as(i32, Tokens.header_height + 50), unmoved_b.top);
}

test "node movement persists by stable identity across canvas state reload" {
    var state = CanvasState{};
    const nodes = [_]GraphModel.Node{
        .{ .id = @constCast("persisted"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
    };
    state.syncNodeOffsets(&nodes);
    const before = nodeBounds(0, &state);
    state.beginNodeDrag("persisted", 0, before.left, before.top);
    state.updateNodeDrag(before.left + 45, before.top + 25);
    state.endNodeDrag();
    const encoded = try state.encodeNodeOffsets(std.testing.allocator);
    defer std.testing.allocator.free(encoded);

    var restored = CanvasState{};
    try restored.decodeNodeOffsets(encoded);
    restored.syncNodeOffsets(&nodes);
    try std.testing.expectEqual(before.left + 45, nodeBounds(0, &restored).left);
    try std.testing.expectEqual(before.top + 25, nodeBounds(0, &restored).top);
}

test "invalid persisted node movement is rejected without replacing valid state" {
    var state = CanvasState{};
    const nodes = [_]GraphModel.Node{
        .{ .id = @constCast("valid"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
    };
    state.syncNodeOffsets(&nodes);
    state.node_offsets[0] = .{ .x = 12, .y = 8 };
    try std.testing.expectError(
        error.InvalidCanvasLayout,
        state.decodeNodeOffsets("1\tnan\t4\n"),
    );
    try std.testing.expectEqual(@as(i32, Tokens.sidebar_width + 32 + 12), nodeBounds(0, &state).left);
    try std.testing.expectEqual(@as(i32, Tokens.header_height + 50 + 8), nodeBounds(0, &state).top);
}

test "overview and quick chat hit testing follows rendered cards" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    const frame =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"a","project":{"path":"A","name":"Alpha"},"nodes":[{"id":"a1","title":"Loop A","state":"running"}],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(frame);
    var state = CanvasState{ .pan_y = 17 };
    const bounds = rect(Tokens.sidebar_width, Tokens.header_height, 1200, 800);
    const card = overviewCardBounds(&model, 0, 0, bounds, &state);
    const hit = hitTestOverview(&model, card.left + 4, card.top + 4, &state, bounds) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), hit.graph_index);
    try std.testing.expectEqual(@as(usize, 0), hit.node_index);
    const chat = quickChatCardBounds(2, bounds, &state);
    try std.testing.expectEqual(@as(?usize, 2), hitTestQuickChat(3, chat.left + 4, chat.top + 4, &state, bounds));
    try std.testing.expect(hitTestQuickChat(3, bounds.left - 1, chat.top, &state, bounds) == null);
}

test "overview and quick chat geometry applies pan and zoom consistently" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    var graph = GraphModel.GraphSummary{
        .project = .{
            .path = try std.testing.allocator.dupe(u8, "graphcode://test"),
            .name = try std.testing.allocator.dupe(u8, "Test"),
        },
        .nodes = std.array_list.Managed(GraphModel.Node).init(std.testing.allocator),
        .edges = std.array_list.Managed(GraphModel.Edge).init(std.testing.allocator),
    };
    try graph.nodes.append(.{
        .id = try std.testing.allocator.dupe(u8, "node"),
        .title = try std.testing.allocator.dupe(u8, "Node"),
        .loop_type = try std.testing.allocator.dupe(u8, "turnBased"),
        .state = try std.testing.allocator.dupe(u8, "idle"),
        .activity = try std.testing.allocator.dupe(u8, ""),
        .presence = try std.testing.allocator.dupe(u8, "idle"),
    });
    try model.graphs.append(graph);
    const bounds = rect(240, 42, 1200, 800);
    var state = CanvasState{ .pan_x = 25, .pan_y = -12, .zoom = 1.25 };
    const card = overviewCardBounds(&model, 0, 0, bounds, &state);
    try std.testing.expectEqual(@as(?OverviewHit, .{ .graph_index = 0, .node_index = 0 }), hitTestOverview(&model, card.left + 2, card.top + 2, &state, bounds));
    const chat = quickChatCardBounds(0, bounds, &state);
    try std.testing.expectEqual(@as(?usize, 0), hitTestQuickChat(1, chat.left + 2, chat.top + 2, &state, bounds));
}

test "zoom controls expose every action and fit content" {
    const bounds = rect(240, 42, 1200, 800);
    inline for ([_]ZoomControl{ .out, .actual, .in, .fit }, 0..) |expected, index| {
        const button = zoomButtonBounds(bounds, @intCast(index));
        try std.testing.expectEqual(expected, hitTestZoomControl(button.left + 2, button.top + 2, bounds).?);
    }
    var state = CanvasState{};
    state.fit(bounds, 1600, 900);
    try std.testing.expect(state.zoom < 1);
}

test "minimum zoom hides overflow-prone card content" {
    const layout = cardTextLayout(0.55, true, true);
    try std.testing.expect(!layout.show_entry);
    try std.testing.expect(!layout.show_activity);
    try std.testing.expect(!layout.show_attention);
    try std.testing.expect(layout.state_y < @as(i32, @intFromFloat(106 * 0.55)));
}

test "loop card detail prioritizes goal and preserves metadata" {
    const node = GraphModel.Node{
        .id = @constCast("node"),
        .title = @constCast("Goal"),
        .loop_type = @constCast("goalBased"),
        .state = @constCast("running"),
        .activity = @constCast("checking tests"),
        .presence = @constCast("busy"),
        .goal_summary = @constCast("All tests pass"),
        .model_tier = @constCast("capable"),
        .worktree_branch = @constCast("feature/parity"),
    };
    try std.testing.expectEqualStrings("All tests pass", nodePrimaryDetail(node));
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("feature/parity · capable", nodeMetadata(&buffer, node));
}

test "unwired roles require explicit session entry acknowledgement" {
    const no_edges = [_]GraphModel.Edge{};
    try std.testing.expectEqual(NodeRole.unwired, nodeRole(&no_edges, "loose", &.{}));
    try std.testing.expectEqual(NodeRole.entry, nodeRole(&no_edges, "loose", &.{"loose"}));
    const edge = [_]GraphModel.Edge{.{
        .from = @constCast("source"),
        .to = @constCast("target"),
    }};
    try std.testing.expectEqual(NodeRole.entry, nodeRole(&edge, "source", &.{}));
    try std.testing.expectEqual(NodeRole.interior, nodeRole(&edge, "target", &.{}));
}

test "safe resolved worktrees expose distinct reclaim and keep targets" {
    var inspection = WorktreeStatus.Inspection{
        .entries = std.array_list.Managed(WorktreeStatus.Entry).init(std.testing.allocator),
        .default_branch = @constCast("main"),
        .project_path = @constCast("project"),
    };
    defer inspection.entries.deinit();
    try inspection.entries.append(.{
        .path = @constCast("C:\\safe"),
        .branch = @constCast("done"),
        .pushed = true,
        .landed = true,
    });
    const node = GraphModel.Node{
        .id = @constCast("node"),
        .title = @constCast("Done"),
        .loop_type = @constCast("turnBased"),
        .state = @constCast("succeeded"),
        .activity = @constCast(""),
        .presence = @constCast("idle"),
        .worktree_path = @constCast("C:\\safe"),
    };
    try std.testing.expect(hasReclaimOffer(node, &inspection, &.{}));
    try std.testing.expect(!hasReclaimOffer(node, &inspection, &.{"C:\\safe"}));
    const nodes = [_]GraphModel.Node{node};
    const offer = reclaimOfferBounds(nodeBounds(0, &.{}));
    try std.testing.expectEqual(ReclaimAction.reclaim, hitTestReclaimOffer(&nodes, &inspection, &.{}, offer.reclaim.left + 1, offer.reclaim.top + 1, &.{}).?.action);
    try std.testing.expectEqual(ReclaimAction.keep, hitTestReclaimOffer(&nodes, &inspection, &.{}, offer.keep.left + 1, offer.keep.top + 1, &.{}).?.action);
}

test "attention follows awaiting input and stranded blocked semantics" {
    const nodes = [_]GraphModel.Node{
        .{ .id = @constCast("awaiting"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast("running"), .activity = @constCast(""), .presence = @constCast("awaitingInput") },
        .{ .id = @constCast("failed"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast("failed"), .activity = @constCast(""), .presence = @constCast("idle") },
        .{ .id = @constCast("blocked"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast("blocked"), .activity = @constCast(""), .presence = @constCast("idle") },
    };
    const edges = [_]GraphModel.Edge{
        .{ .from = @constCast("failed"), .to = @constCast("blocked"), .kind = @constCast("handoff"), .fired = false },
    };
    try std.testing.expect(needsAttention(nodes[0], &nodes, &edges));
    try std.testing.expect(needsAttention(nodes[2], &nodes, &edges));
    const unresolved_nodes = [_]GraphModel.Node{
        nodes[1],
        .{ .id = @constCast("running"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast("running"), .activity = @constCast(""), .presence = @constCast("busy") },
        nodes[2],
    };
    const unresolved_edges = [_]GraphModel.Edge{
        edges[0],
        .{ .from = @constCast("running"), .to = @constCast("blocked"), .kind = @constCast("handoff"), .fired = false },
    };
    try std.testing.expect(!needsAttention(unresolved_nodes[2], &unresolved_nodes, &unresolved_edges));
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

test "edge hit testing follows reordered endpoint IDs and zoom pan" {
    var state = CanvasState{ .pan_x = 18, .pan_y = -7, .zoom = 1.15 };
    const nodes = [_]GraphModel.Node{
        .{ .id = @constCast("target"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
        .{ .id = @constCast("source"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
    };
    const edges = [_]GraphModel.Edge{
        .{ .from = @constCast("source"), .to = @constCast("target"), .kind = @constCast("handoff") },
    };
    const from = connectorPosition(&nodes, "source", true, &state) orelse return error.MissingConnector;
    const to = connectorPosition(&nodes, "target", false, &state) orelse return error.MissingConnector;
    const distance: i32 = if (to.x >= from.x) to.x - from.x else from.x - to.x;
    const bend: i32 = @max(@as(i32, 24), @divTrunc(distance, 2));
    const midpoint = Connector{
        .x = @intFromFloat(
            @as(f32, @floatFromInt(from.x)) * 0.125 +
                @as(f32, @floatFromInt(from.x + bend)) * 0.375 +
                @as(f32, @floatFromInt(to.x - bend)) * 0.375 +
                @as(f32, @floatFromInt(to.x)) * 0.125,
        ),
        .y = @intFromFloat((@as(f32, @floatFromInt(from.y)) + @as(f32, @floatFromInt(to.y))) / 2),
    };
    const bounds = rect(Tokens.sidebar_width, Tokens.header_height, 1200, 800);
    try std.testing.expectEqual(@as(?usize, 0), hitTestEdge(&nodes, &edges, midpoint.x, midpoint.y, &state, bounds));
}

test "edge drag state cancels without leaving a selection" {
    var state = CanvasState{};
    state.beginEdgeDrag("node-3", 100, 120);
    state.updateEdgeDrag(140, 160);
    try std.testing.expectEqualStrings("node-3", state.endEdgeDrag().?);
    try std.testing.expect(!state.edge_dragging);
    try std.testing.expectEqualStrings("", state.edge_drag_source_id);
}

test "edge presentation distinguishes kind condition and fired state" {
    var buffer: [128]u8 = undefined;
    const message = GraphModel.Edge{
        .id = @constCast("edge"),
        .from = @constCast("a"),
        .to = @constCast("b"),
        .kind = @constCast("message"),
        .condition = @constCast("onSuccess"),
        .fire_count = 2,
    };
    try std.testing.expectEqual(c.PS_DOT, edgeKindPenStyle(message.kind));
    try std.testing.expectEqualStrings("message · onSuccess · fired 2", edgeLabel(&buffer, message));
    try std.testing.expect(edgeKindColor("message") != edgeKindColor("spawn"));
}

test "capture loss cancels both pan and edge drag state" {
    var state = CanvasState{};
    state.beginPan(10, 20);
    state.beginEdgeDrag("node-1", 30, 40);
    state.cancelInteraction();
    try std.testing.expect(!state.dragging);
    try std.testing.expect(!state.edge_dragging);
    try std.testing.expectEqualStrings("", state.edge_drag_source_id);
}
