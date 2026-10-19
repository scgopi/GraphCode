const std = @import("std");
const GraphModel = @import("GraphModel.zig");
const Tokens = @import("DesignTokens.zig");
const Sidebar = @import("Sidebar.zig");
const WorktreeStatus = @import("WorktreeStatus.zig");
const WorkspaceControls = @import("WorkspaceControls.zig");
const LoopBarLayout = @import("LoopBarLayout.zig");
const LaneLayout = @import("LaneLayout.zig");
const c = @import("Win32.zig").c;
const AppFont = @import("AppFont.zig");
const GdiplusAA = @import("GdiplusAA.zig");
pub const connection_failure_message = "GraphCode daemon unavailable. Navigation remains available while reconnection continues.";

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
    touch_pan_active: bool = false,
    touch_pan_start_x: i32 = 0,
    touch_pan_start_y: i32 = 0,
    touch_pan_start_pan_x: f32 = 0,
    touch_pan_start_pan_y: f32 = 0,
    touch_pan_context: u64 = 0,
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
    node_drag_started: bool = false,
    node_drag_index: usize = 0,
    node_drag_key: u64 = 0,
    node_drag_x: i32 = 0,
    node_drag_y: i32 = 0,
    node_drag_origin: NodeOffset = .{},
    node_drag_pan_x: f32 = 0,
    node_drag_pan_y: f32 = 0,
    hovered_connector: ?usize = null,
    /// Native touchscreen pinch (WM_GESTURE/GID_ZOOM) state. `pinch_base_distance`
    /// and `pinch_base_zoom` are captured once at GF_BEGIN and every subsequent
    /// GID_ZOOM message computes an absolute target zoom relative to that base
    /// (per the documented WM_GESTURE contract), not relative to the previous
    /// message, so repeated updates cannot compound the zoom factor.
    pinch_base_distance: ?u32 = null,
    pinch_base_zoom: f32 = 1,
    /// A caller-supplied identity captured at `beginPinchZoom` (e.g. a hash
    /// of the active surface and selected project, mirroring the existing
    /// `nodeKey` hashing pattern rather than holding onto a borrowed string).
    /// A pinch gesture can legitimately span many messages, so the app can
    /// change destination (surface switch, project switch) *without* ever
    /// delivering GID_END for the in-progress gesture; `continuePinchZoom`
    /// treats a mismatched context as the gesture no longer being valid for
    /// whatever is now on screen, rather than silently continuing to scale
    /// it.
    pinch_context: u64 = 0,
    project_layout: ?LaneLayout.Layout = null,
    overview_layout: ?LaneLayout.Overview = null,
    layout_fingerprint: ?u64 = null,
    layout_bounds: c.RECT = .{ .left = Tokens.sidebar_width, .top = Tokens.header_height, .right = 1280, .bottom = 720 },

    pub fn syncLayout(self: *CanvasState, allocator: std.mem.Allocator, model: *const GraphModel.Model, bounds: c.RECT, order: []const []const u8, declared: []const []const u8) !void {
        self.layout_bounds = bounds;
        const fingerprint = layoutFingerprint(model, bounds, order, declared);
        if (self.layout_fingerprint == fingerprint) return;
        // A failed refresh must not leave yesterday's indices under today's nodes.
        self.deinitLayout();
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const temp = scratch.allocator();
        const sidebar_order = try sidebarLayoutOrder(temp, model, order);
        var project: ?LaneLayout.Layout = null;
        errdefer if (project) |*layout| layout.deinit();
        const height: f32 = @floatFromInt(@max(1, bounds.bottom - bounds.top));
        if (model.graph) |graph| {
            var row_height = LaneLayout.MacMetrics.row_height;
            for (graph.nodes.items) |node| {
                if (GraphModel.subgraphNodeCount(node.subgraph_json) > 0)
                    row_height = LaneLayout.SubGraphMetrics.row_pitch;
            }
            project = try LaneLayout.init(allocator, graph.nodes.items, graph.edges.items, .{
                .row_budget = LaneLayout.MacMetrics.rowBudget(height),
                .row_height = row_height,
                .order = sidebar_order,
                .declared_entries = declared,
            });
        }
        const graphs = try temp.alloc(LaneLayout.OverviewGraph, model.graphs.items.len);
        for (model.graphs.items, graphs) |graph, *input| {
            const nodes = try temp.alloc(LaneLayout.Node, graph.nodes.items.len);
            for (graph.nodes.items, nodes) |node, *value| value.* = .{ .id = node.id, .loop_type = node.loop_type };
            const edges = try temp.alloc(LaneLayout.Edge, graph.edges.items.len);
            for (graph.edges.items, edges) |edge, *value| value.* = .{
                .id = edge.id,
                .from = edge.from,
                .to = edge.to,
                .kind = edge.kind,
                .fired = edge.fired,
            };
            input.* = .{
                .graph = .{ .nodes = nodes, .edges = edges },
                .is_global = graph.project.isGlobal(),
                .order = sidebar_order,
                .declared_entries = if (model.graph) |active|
                    if (std.mem.eql(u8, active.project.path, graph.project.path)) declared else &.{}
                else
                    &.{},
            };
        }
        const overview = try LaneLayout.initOverview(allocator, graphs, height);
        self.project_layout = project;
        self.overview_layout = overview;
        self.layout_fingerprint = fingerprint;
    }

    pub fn deinitLayout(self: *CanvasState) void {
        if (self.project_layout) |*layout| layout.deinit();
        if (self.overview_layout) |*layout| layout.deinit();
        self.project_layout = null;
        self.overview_layout = null;
        self.layout_fingerprint = null;
    }

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

    pub fn beginTouchPan(self: *CanvasState, x: i32, y: i32, context: u64) void {
        self.endPinchZoom();
        self.touch_pan_active = true;
        self.touch_pan_start_x = x;
        self.touch_pan_start_y = y;
        self.touch_pan_start_pan_x = self.pan_x;
        self.touch_pan_start_pan_y = self.pan_y;
        self.touch_pan_context = context;
    }

    pub fn continueTouchPan(self: *CanvasState, x: i32, y: i32, context: u64) void {
        if (!self.touch_pan_active) return;
        if (context != self.touch_pan_context) {
            self.endTouchPan();
            return;
        }
        self.pan_x = self.touch_pan_start_pan_x +
            (@as(f32, @floatFromInt(x)) - @as(f32, @floatFromInt(self.touch_pan_start_x)));
        self.pan_y = self.touch_pan_start_pan_y +
            (@as(f32, @floatFromInt(y)) - @as(f32, @floatFromInt(self.touch_pan_start_y)));
    }

    pub fn endTouchPan(self: *CanvasState) void {
        self.touch_pan_active = false;
        self.touch_pan_start_x = 0;
        self.touch_pan_start_y = 0;
        self.touch_pan_start_pan_x = 0;
        self.touch_pan_start_pan_y = 0;
        self.touch_pan_context = 0;
    }

    pub fn cancelInteraction(self: *CanvasState) void {
        self.dragging = false;
        self.endTouchPan();
        self.edge_dragging = false;
        self.edge_drag_source_id = "";
        if (self.node_dragging and self.node_drag_index < self.node_offsets.len)
            self.node_offsets[self.node_drag_index] = self.node_drag_origin;
        if (self.node_dragging) {
            self.pan_x = self.node_drag_pan_x;
            self.pan_y = self.node_drag_pan_y;
        }
        self.node_dragging = false;
        self.node_drag_started = false;
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
        self.node_dragging = true;
        self.node_drag_started = false;
        self.node_drag_index = index;
        self.node_drag_key = nodeKey(node_id);
        self.node_drag_x = x;
        self.node_drag_y = y;
        self.node_drag_origin = if (index < self.node_offsets.len) self.node_offsets[index] else .{};
        self.node_drag_pan_x = self.pan_x;
        self.node_drag_pan_y = self.pan_y;
    }

    pub fn updateNodeDrag(self: *CanvasState, x: i32, y: i32) void {
        if (!self.node_dragging) return;
        if (!self.node_drag_started) {
            if (@abs(x - self.node_drag_x) < 6 and @abs(y - self.node_drag_y) < 6) return;
            self.node_drag_started = true;
        }
        // ProjectCanvasView's parent DragGesture pans the sheet, not one card.
        self.pan_x = self.node_drag_pan_x + @as(f32, @floatFromInt(x - self.node_drag_x));
        self.pan_y = self.node_drag_pan_y + @as(f32, @floatFromInt(y - self.node_drag_y));
    }

    pub fn endNodeDrag(self: *CanvasState) void {
        self.node_dragging = false;
        self.node_drag_started = false;
        self.node_drag_key = 0;
    }

    pub fn completeNodeDrag(self: *CanvasState) ?usize {
        if (!self.node_dragging) return null;
        const activate = !self.node_drag_started;
        const index = self.node_drag_index;
        self.endNodeDrag();
        return if (activate) index else null;
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
            for (nodes, 0..) |node, index| {
                if (nodeKey(node.id) == self.node_drag_key) {
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
        const steps = @max(1, @abs(@as(i32, wheel_delta)) / 120);
        const factor: f32 = if (wheel_delta > 0)
            std.math.pow(f32, 1.1, @floatFromInt(steps))
        else
            std.math.pow(f32, 0.9, @floatFromInt(steps));
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

    /// Captures the gesture's starting distance/zoom baseline. Per the
    /// documented WM_GESTURE contract, the first GID_ZOOM message ("GF_BEGIN")
    /// begins a zoom but must not cause any zooming itself. `distance` is the
    /// OS-reported GESTUREINFO.ullArguments low dword, an unsigned integer by
    /// construction (so this can never receive a NaN/Inf input); zero is the
    /// platform's way of saying "no meaningful distance yet," so we leave the
    /// base unset rather than dividing by it later. `context` identifies what
    /// this gesture is being applied to (see the `pinch_context` field doc);
    /// it is always (re)recorded here so a later `continuePinchZoom` can
    /// detect the gesture has outlived the thing it started on.
    pub fn beginPinchZoom(self: *CanvasState, distance: u32, context: u64) void {
        self.endTouchPan();
        self.pinch_context = context;
        if (distance == 0) {
            self.pinch_base_distance = null;
            return;
        }
        self.pinch_base_distance = distance;
        self.pinch_base_zoom = self.zoom;
    }

    /// Applies a subsequent GID_ZOOM message. The target zoom is always
    /// computed as an *absolute* value relative to the gesture's captured
    /// base (`pinch_base_zoom * currentDistance / pinch_base_distance`), then
    /// converted into the one-shot multiplicative factor `zoomBy` expects
    /// (`target / currentZoom`). This is what keeps repeated updates from
    /// compounding: recomputing from the base every message, rather than
    /// chaining `currentDistance / previousDistance` factors, means
    /// intermediate clamping (from `zoomBy`) is self-correcting instead of
    /// accumulating error.
    ///
    /// `context` must match the value passed to the `beginPinchZoom` that
    /// started this gesture. A single physical gesture can span many
    /// messages without ever delivering GID_END (e.g. the user switches the
    /// active project or the surface changes to the terminal mid-pinch);
    /// when the context no longer matches, this resets the baseline instead
    /// of applying a zoom update, so a gesture that began on one graph can
    /// never scale a different one it happened to still be "in progress"
    /// over. After a reset, this call remains a no-op (see the base-distance
    /// guard above) until a genuinely NEW `beginPinchZoom` establishes a
    /// fresh baseline -- it does not resume on its own.
    pub fn continuePinchZoom(self: *CanvasState, x: i32, y: i32, distance: u32, context: u64) void {
        if (context != self.pinch_context) {
            self.pinch_base_distance = null;
            return;
        }
        const base_distance = self.pinch_base_distance orelse return;
        if (distance == 0 or self.zoom == 0) return;
        const target_zoom = self.pinch_base_zoom *
            (@as(f32, @floatFromInt(distance)) / @as(f32, @floatFromInt(base_distance)));
        self.zoomBy(x, y, target_zoom / self.zoom);
    }

    /// Ends native gesture state on GF_END, a generic GID_END bracket, routing
    /// failure, or window deactivation. The shared reset also prevents a pan
    /// sequence from surviving any existing pinch-reset path.
    pub fn endPinchZoom(self: *CanvasState) void {
        self.pinch_base_distance = null;
        self.endTouchPan();
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
        ), 0.55, 1);
        self.pan_x = @as(f32, @floatFromInt(bounds.left + 24)) +
            (@as(f32, @floatFromInt(viewport_width)) - @as(f32, @floatFromInt(content_width)) * self.zoom) / 2 -
            @as(f32, @floatFromInt(bounds.left)) * self.zoom;
        self.pan_y = @as(f32, @floatFromInt(bounds.top + 24)) +
            (@as(f32, @floatFromInt(viewport_height)) - @as(f32, @floatFromInt(content_height)) * self.zoom) / 2 -
            @as(f32, @floatFromInt(bounds.top)) * self.zoom;
    }
};

fn sidebarLayoutOrder(allocator: std.mem.Allocator, model: *const GraphModel.Model, roots: []const []const u8) ![]const []const u8 {
    var expanded = Sidebar.State.init(allocator);
    const root_order = try allocator.alloc([]u8, roots.len);
    for (roots, root_order) |id, *owned| owned.* = try allocator.dupe(u8, id);
    expanded.root_order = .{ .items = root_order, .capacity = root_order.len };
    // The enclosing arena owns traversal storage; node IDs remain borrowed.
    // Expansion never changes the canvas's order, only the sidebar's visibility.
    for (model.graphs.items) |graph| {
        for (graph.nodes.items) |node| try expanded.expanded_nodes.put(allocator, node.id, {});
    }
    if (model.graph) |graph| {
        for (graph.nodes.items) |node| try expanded.expanded_nodes.put(allocator, node.id, {});
    }
    const rows = try Sidebar.appendRows(allocator, model, null, 0, &expanded);
    var order = std.array_list.Managed([]const u8).init(allocator);
    for (rows.items) |row| {
        if (row.kind != .loop) continue;
        const graph = Sidebar.graphForProject(model, row.project_path orelse return error.InvalidSidebarLayout) orelse return error.InvalidSidebarLayout;
        if (row.index >= graph.nodes().len) return error.InvalidSidebarLayout;
        try order.append(graph.nodes()[row.index].id);
    }
    return order.items;
}

fn layoutFingerprint(model: *const GraphModel.Model, bounds: c.RECT, order: []const []const u8, declared: []const []const u8) u64 {
    var hash = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hash, bounds.bottom - bounds.top);
    std.hash.autoHash(&hash, model.graph != null);
    if (model.graph) |graph| {
        std.hash.autoHash(&hash, graph.project.path.len);
        hash.update(graph.project.path);
        hashLayoutGraph(&hash, graph.nodes.items, graph.edges.items);
    }
    std.hash.autoHash(&hash, model.graphs.items.len);
    for (model.graphs.items) |graph| {
        std.hash.autoHash(&hash, graph.project.path.len);
        hash.update(graph.project.path);
        hashLayoutGraph(&hash, graph.nodes.items, graph.edges.items);
    }
    for (order) |id| {
        std.hash.autoHash(&hash, id.len);
        hash.update(id);
    }
    std.hash.autoHash(&hash, order.len);
    for (declared) |id| {
        std.hash.autoHash(&hash, id.len);
        hash.update(id);
    }
    std.hash.autoHash(&hash, declared.len);
    return hash.final();
}

fn hashLayoutGraph(hash: *std.hash.Wyhash, nodes: []const GraphModel.Node, edges: []const GraphModel.Edge) void {
    std.hash.autoHash(hash, nodes.len);
    for (nodes) |node| {
        std.hash.autoHash(hash, node.id.len);
        hash.update(node.id);
        std.hash.autoHash(hash, node.subgraph_json.len);
        hash.update(node.subgraph_json);
    }
    std.hash.autoHash(hash, edges.len);
    for (edges) |edge| {
        std.hash.autoHash(hash, edge.from.len);
        hash.update(edge.from);
        std.hash.autoHash(hash, edge.to.len);
        hash.update(edge.to);
        std.hash.autoHash(hash, edge.kind.len);
        hash.update(edge.kind);
        std.hash.autoHash(hash, edge.blocks_target);
    }
}

fn nodeKey(id: []const u8) u64 {
    return std.hash.Wyhash.hash(0, id);
}

pub const CardTextLayout = struct {
    title: c.RECT,
    pill: c.RECT,
    live: c.RECT,
    detail: c.RECT,
    meta: c.RECT,
};

pub const RenderBounds = struct { left: i32, top: i32, right: i32, bottom: i32 };
pub const Surface = Sidebar.Surface;
pub const OverviewHit = struct { graph_index: usize, node_index: usize };
pub const OverviewLaneAction = enum { open_project, inspect_worktrees };
pub const overview_worktree_notice_kind = "overview-worktree-notice";

pub fn overviewWorktreeNotice(graph: *const GraphModel.GraphSummary) ?WorktreeStatus.NoticePresentation {
    if (graph.project.isGlobal()) return null;
    return WorktreeStatus.NoticePresentation.fromRecord(graph.worktree_notice);
}

pub fn overviewWorktreeNoticeIdentity(allocator: std.mem.Allocator, project_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ overview_worktree_notice_kind, project_path });
}

pub fn projectWorktreeChip(model: *const GraphModel.Model) ?WorktreeStatus.Summary {
    if (model.isCompositeOpen()) return null;
    const graph = model.currentGraph() orelse return null;
    if (graph.project.isGlobal()) return null;
    const record = graph.worktree_notice orelse return null;
    const observation = record.observation orelse return null;
    if (observation.summary.total == 0) return null;
    return observation.summary;
}

pub fn projectWorktreeChipBounds(bounds: c.RECT) c.RECT {
    return rect(bounds.left + 24, bounds.top + 14, @min(bounds.right - 24, bounds.left + 250), bounds.top + 42);
}

pub fn hitTestProjectWorktreeChip(model: *const GraphModel.Model, x: i32, y: i32, bounds: c.RECT) bool {
    return projectWorktreeChip(model) != null and insideGraph(x, y, projectWorktreeChipBounds(bounds));
}

fn drawProjectWorktreeChip(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    model: *const GraphModel.Model,
    bounds: c.RECT,
) void {
    const summary = projectWorktreeChip(model) orelse return;
    const label = if (summary.reclaimable != 0)
        std.fmt.allocPrint(allocator, "{d} worktree{s} · {d} reclaimable", .{
            summary.total,
            if (summary.total == 1) "" else "s",
            summary.reclaimable,
        })
    else
        std.fmt.allocPrint(allocator, "{d} worktree{s}", .{
            summary.total,
            if (summary.total == 1) "" else "s",
        });
    const text = label catch return;
    defer allocator.free(text);
    const chip = projectWorktreeChipBounds(bounds);
    fill(hdc, chip, 0x00352B1C);
    drawTextRect(hdc, allocator, text, chip, 10, 0x00FFCD7A, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
}

pub const ZoomControl = enum { out, actual, in, fit };
pub const HeaderAction = enum { review_attention, inspect_worktrees, jump, toggle_panel };
pub const header_actions = [_]HeaderAction{ .review_attention, .inspect_worktrees, .jump, .toggle_panel };

pub fn headerIdentity(action: HeaderAction) []const u8 {
    return switch (action) {
        .review_attention => "header-attention:needs-you",
        .inspect_worktrees => "header-worktree:worktrees",
        .jump => "header-jump:jump",
        .toggle_panel => "header-toggle-panel:control",
    };
}

pub const Header = struct {
    pub const ProjectGlyph = enum { folder, remote, global };

    title: []const u8 = "GraphCode Windows",
    context: []const u8 = "",
    project_glyph: ?ProjectGlyph = null,
    detail_left: i32 = 0,
    attention_count: usize = 0,
    notice_name: []const u8 = "",
    notice: ?WorktreeStatus.Summary = null,
    notice_extra_folders: usize = 0,
    panel_visible: ?bool = null,

    pub fn contains(self: Header, action: HeaderAction) bool {
        return switch (action) {
            .review_attention => self.attention_count != 0,
            .inspect_worktrees => self.notice != null,
            .jump => true,
            .toggle_panel => self.panel_visible != null,
        };
    }

    pub fn label(self: Header, allocator: std.mem.Allocator, action: HeaderAction) ![]u8 {
        return switch (action) {
            .review_attention => std.fmt.allocPrint(allocator, "{d} need you", .{self.attention_count}),
            .inspect_worktrees => if (self.notice_extra_folders != 0)
                std.fmt.allocPrint(allocator, "{s}: {d} {s} +{d}", .{
                    self.notice_name,
                    if (self.notice.?.reclaimable != 0) self.notice.?.reclaimable else self.notice.?.total,
                    if (self.notice.?.reclaimable != 0) "reclaimable" else "worktrees",
                    self.notice_extra_folders,
                })
            else if (self.notice.?.reclaimable != 0)
                std.fmt.allocPrint(allocator, "{s}: {d} reclaimable", .{ self.notice_name, self.notice.?.reclaimable })
            else
                std.fmt.allocPrint(allocator, "{s}: {d} worktrees", .{ self.notice_name, self.notice.?.total }),
            .jump => allocator.dupe(u8, "Jump to loop   Ctrl+P"),
            .toggle_panel => allocator.dupe(u8, if (self.panel_visible.?) "Hide loop panel" else "Show loop panel"),
        };
    }

    pub fn layout(self: Header, width: i32) HeaderLayout {
        var result = HeaderLayout{};
        const right = @max(0, width - 8);
        const identity_left = if (self.project_glyph != null) @min(right, self.detail_left + 20) else @min(8, right);
        const identity_right = if (self.project_glyph != null)
            @min(right, identity_left + @min(240, @divTrunc(@max(0, width - identity_left), 3)))
        else
            @min(right, @max(0, @min(280, @divTrunc(width, 3))));
        result.identity = rect(identity_left, 1, identity_right, Tokens.header_height - 1);
        const status_width: i32 = if (width >= 1100) 220 else 0;
        result.status = rect(right - status_width, 5, right, Tokens.header_height - 5);
        const controls_right = @max(identity_right, right - status_width - (if (status_width != 0) @as(i32, 8) else 0));
        var total: i32 = 0;
        var count: i32 = 0;
        const preferred = [_]i32{ 112, 180, 164, 136 };
        for (header_actions, preferred) |action, preferred_width| {
            if (!self.contains(action)) continue;
            total += preferred_width;
            count += 1;
        }
        const gap = @min(@as(i32, 8), @divTrunc(controls_right - identity_right, count * 2));
        const available = @max(0, controls_right - identity_right - gap * count);
        var left = identity_right + gap;
        for (header_actions, preferred, 0..) |action, preferred_width, index| {
            if (!self.contains(action)) continue;
            const control_width = @min(preferred_width, @divTrunc(available * preferred_width, total));
            if (control_width > 0) result.controls[index] = rect(left, 5, left + control_width, Tokens.header_height - 5);
            left += control_width + gap;
        }
        return result;
    }
};

pub const HeaderLayout = struct {
    identity: c.RECT = std.mem.zeroes(c.RECT),
    status: c.RECT = std.mem.zeroes(c.RECT),
    controls: [header_actions.len]?c.RECT = .{null} ** header_actions.len,

    pub fn bounds(self: HeaderLayout, action: HeaderAction) ?c.RECT {
        return self.controls[@intFromEnum(action)];
    }

    pub fn actionAt(self: HeaderLayout, x: i32, y: i32) ?HeaderAction {
        for (header_actions, self.controls) |action, control| {
            if (control) |bounds_value| if (insideGraph(x, y, bounds_value)) return action;
        }
        return null;
    }

    pub fn step(self: HeaderLayout, current: ?HeaderAction, backwards: bool) ?HeaderAction {
        const start: usize = if (current) |action| @intFromEnum(action) else if (backwards) 0 else header_actions.len - 1;
        for (1..header_actions.len + 1) |offset| {
            const index = if (backwards)
                (start + header_actions.len - offset) % header_actions.len
            else
                (start + offset) % header_actions.len;
            if (self.controls[index] != null) return header_actions[index];
        }
        return null;
    }
};

pub fn loopPanelHasContent(model: *const GraphModel.Model, surface: Surface, quick_chat: bool) bool {
    if (surface != .workspace or quick_chat) return false;
    const graph = model.currentGraph() orelse return false;
    const index = model.selectedIndex() orelse return false;
    if (index >= graph.nodes.items.len) return false;
    const node = graph.nodes.items[index];
    if (node.metric_sample_count >= 2) return true;
    for (graph.edges.items) |edge| {
        if (std.mem.eql(u8, edge.from, node.id) or std.mem.eql(u8, edge.to, node.id)) return true;
    }
    return false;
}

pub fn headerWorktreeNotice(model: *const GraphModel.Model, inspection: *const WorktreeStatus.Inspection, policy: WorktreeStatus.Policy) bool {
    const graph = model.currentGraph() orelse return false;
    if (!graph.project.isLocalFilesystem() or !std.mem.eql(u8, graph.project.path, inspection.project_path)) return false;
    return WorktreeStatus.noticeState(inspection.entries.items, policy) == .notice;
}
pub const AttentionAction = enum { none, reply, inspect };
pub const ReclaimAction = enum { reclaim, keep };
pub const ReclaimHit = struct { node_index: usize, action: ReclaimAction };

pub fn attentionRailBounds(width: i32) c.RECT {
    return attentionRailLayout(rect(Tokens.sidebar_width, Tokens.header_height, width, 720)).rail;
}

pub fn hitTestAttentionRail(x: i32, y: i32, width: i32) bool {
    return insideGraph(x, y, attentionRailLayout(rect(Tokens.sidebar_width, Tokens.header_height, width, 720)).review);
}

pub const AttentionRailLayout = struct { rail: c.RECT, count: c.RECT, age: c.RECT, review: c.RECT };

pub fn attentionRailLayout(bounds: c.RECT) AttentionRailLayout {
    const left = @min(bounds.right, bounds.left + 20);
    const right = @max(left, @min(left + 390, bounds.right - 148));
    const top = bounds.top + 18;
    const review_left = @max(left, right - 124);
    const count_right = @min(left + 151, @max(left, review_left - 9));
    return .{
        .rail = rect(left, top, right, top + 30),
        .count = rect(@min(left + 27, count_right), top, count_right, top + 30),
        .age = rect(@min(count_right + 9, review_left), top, @max(@min(count_right + 9, review_left), review_left - 9), top + 30),
        .review = rect(review_left, top + 5, @max(review_left, right - 6), top + 25),
    };
}

/// The rail belongs to the graph surfaces. A loop workspace paints its loop bar over the
/// same strip, so there it is neither drawn nor clickable: a click on the bar's Show in
/// Graph button must never land on the rail's Review action.
pub fn attentionRailShown(model: *const GraphModel.Model, surface: Surface) bool {
    return (surface == .project or surface == .overview) and model.attentionCount() != 0;
}

pub fn loopDetailCollapseBounds(client_right: i32) c.RECT {
    return rect(client_right - Tokens.loop_detail_width + 172, Tokens.header_height + 12, client_right - 18, Tokens.header_height + 34);
}

/// The collapsed panel's "Loop panel" control is the loop bar's trailing button, so its
/// bounds come from the bar's layout, which keeps Show in graph and Stop clear of it.
pub fn loopDetailExpandBounds(client_right: i32) c.RECT {
    const bounds = LoopBarLayout.panelToggleRect(Tokens.header_height, client_right);
    return rect(bounds.left, bounds.top, bounds.right, bounds.bottom);
}

pub fn hitTestLoopDetailCollapse(x: i32, y: i32, client_right: i32, visible: bool) bool {
    return insideGraph(x, y, if (visible) loopDetailCollapseBounds(client_right) else loopDetailExpandBounds(client_right));
}

pub fn paintLoopDetailExpandControl(hdc: c.HDC, allocator: std.mem.Allocator, client_right: i32) void {
    const bounds = loopDetailExpandBounds(client_right);
    fill(hdc, bounds, 0x00303035);
    drawTextRect(hdc, allocator, "Loop panel", bounds, 10, 0x00D8D8DE, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
}

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
    hdc: c.HDC,
    client_right: i32,
    client_bottom: i32,
    model: *const GraphModel.Model,
    inspection: ?*const WorktreeStatus.Inspection,
    selected_worktree_path: []const u8,
    sidebar_scroll: i32,
    status: []const u8,
    update_version: []const u8,
    ingress_error: []const u8,
    connection_failed: bool,
    worktree_activity: []const u8,
    declared_entries: []const []const u8,
    kept_worktrees: []const []const u8,
    allocator: std.mem.Allocator,
    state: *const CanvasState,
    sidebar_state: *const Sidebar.State,
    sidebar_hover_y: i32,
    controls: WorkspaceControls.State,
    surface: Surface,
) void {
    const client = c.RECT{ .left = 0, .top = 0, .right = client_right, .bottom = client_bottom };
    fill(hdc, client, Tokens.canvas_tone);
    const visible_inspection = if (inspection) |value|
        if (model.graph) |graph|
            if (std.mem.eql(u8, value.project_path, graph.project.path)) value else null
        else
            null
    else
        null;
    if (controls.rail_visible) {
        Sidebar.draw(
            hdc,
            model,
            surface,
            visible_inspection,
            selected_worktree_path,
            sidebar_scroll,
            status,
            sidebarBottom(client.bottom, controls, surface),
            update_version,
            ingress_error,
            sidebar_state,
            sidebar_hover_y,
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
        .overview => drawOverview(hdc, allocator, model, graph_bounds, state, declared_entries) catch |err| {
            std.log.warn("Overview card role resolution failed: {s}", .{@errorName(err)});
            drawText(hdc, allocator, "Graph layout unavailable", graph_bounds.left + 24, graph_bounds.top + 24, 13, Tokens.dialog_error_text, graph_bounds.right - 24);
        },
        .quick_chats => drawQuickChats(hdc, allocator, model, graph_bounds, state),
        .project => if (model.graph) |graph| {
            drawProjectWorktreeChip(hdc, allocator, model, graph_bounds);
            drawCompositeBreadcrumb(hdc, allocator, model, graph_bounds);
            if (graph.nodes.items.len == 0) {
                emptyGraph(hdc, allocator, graph, graph_bounds);
            } else if (state.project_layout == null) {
                drawText(hdc, allocator, "Graph layout unavailable", graph_bounds.left + 24, graph_bounds.top + 24, 13, Tokens.dialog_error_text, graph_bounds.right - 24);
            } else {
                if (state.project_layout) |layout| {
                    const roles = layout.roles;
                    const geometry = GraphGeometry{ .state = state };
                    if (graphBand(graph.nodes.items.len, geometry)) |band| {
                        drawLaneBand(hdc, band, state.zoom);
                        drawEntryOrigin(hdc, allocator, graph.nodes.items.len, roles, geometry, band, false);
                    }
                    drawEdges(hdc, graph, state);
                    drawEdgeLabels(hdc, allocator, graph, state);
                    for (graph.nodes.items, 0..) |node, index| {
                        drawLoopCardShadow(hdc, allocator, node, nodeBounds(index, state), state, roles[index],
                            needsAttention(node, graph.nodes.items, graph.edges.items), model.selectedIndex() == index);
                    }
                    for (graph.nodes.items, 0..) |node, index| {
                        drawNode(
                            hdc,
                            allocator,
                            node,
                            index,
                            model.selectedIndex(),
                            graph.nodes.items,
                            graph.edges.items,
                            roles[index],
                            inspection,
                            kept_worktrees,
                            state,
                        );
                    }
                }
            }
        } else {
            welcome(hdc, allocator, graph_bounds);
        },
        .workspace => {},
    }
    if (surface != .workspace and worktree_activity.len != 0) {
        const activity = worktreeActivityBounds(graph_bounds);
        fill(hdc, activity, 0x00352B1C);
        drawTextRect(
            hdc,
            allocator,
            worktree_activity,
            rect(activity.left + 14, activity.top + 8, activity.right - 14, activity.bottom - 8),
            11,
            0x00FFCD7A,
            c.DT_LEFT | c.DT_SINGLELINE | c.DT_VCENTER | c.DT_END_ELLIPSIS,
        );
    }
    const alert_text = if (ingress_error.len != 0)
        ingress_error
    else if (connection_failed)
        connection_failure_message
    else
        "";
    if (surface != .workspace and alert_text.len != 0) {
        const alert = inlineAlertBounds(graph_bounds);
        fill(hdc, alert, 0x0034242A);
        drawTextRect(
            hdc,
            allocator,
            alert_text,
            rect(alert.left + 14, alert.top + 8, alert.right - 14, alert.bottom - 8),
            11,
            0x008080FF,
            c.DT_LEFT | c.DT_VCENTER | c.DT_WORDBREAK,
        );
    }

    if (surface != .workspace) drawZoomControls(hdc, allocator, graph_bounds, state);

    _ = c.RestoreDC(hdc, saved);
    if (attentionRailShown(model, surface)) attentionRail(hdc, allocator, model, graph_bounds);
    if (controls.activity_enabled) {
        const workspace_height: i32 = if (surface == .workspace) 0 else if (controls.panel_visible) Tokens.workspace_height else 0;
        activityStrip(
            hdc,
            allocator,
            model,
            rect(0, client.bottom - workspace_height - Tokens.activity_strip_height, client.right, client.bottom - workspace_height),
        );
    }
}

pub fn sidebarBottom(client_bottom: i32, controls: WorkspaceControls.State, surface: Surface) i32 {
    var bottom = client_bottom;
    if (controls.panel_visible and surface != .workspace) bottom -= Tokens.workspace_height;
    if (controls.activity_enabled) bottom -= Tokens.activity_strip_height;
    return bottom;
}

pub fn worktreeActivityBounds(bounds: c.RECT) c.RECT {
    return rect(bounds.left + 24, bounds.top + 24, @min(bounds.right - 24, bounds.left + 420), bounds.top + 64);
}

pub fn inlineAlertBounds(bounds: c.RECT) c.RECT {
    return rect(
        bounds.left + 24,
        @max(bounds.top + 24, bounds.bottom - 94),
        bounds.right - 24,
        bounds.bottom - 38,
    );
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
    declared_entries: []const []const u8,
) !void {
    _ = declared_entries;
    if (model.graphs.items.len == 0) {
        const center_y = bounds.top + @divTrunc(bounds.bottom - bounds.top, 2) - 60;
        drawTextRect(hdc, allocator, "Nothing running yet", rect(bounds.left + 40, center_y, bounds.right - 40, center_y + 34), 20, 0x00F2F2F2, c.DT_CENTER | c.DT_SINGLELINE);
        drawTextRect(hdc, allocator, "Loops from every folder you open show up here, wired to how they run.", rect(bounds.left + 100, center_y + 40, bounds.right - 100, center_y + 86), 13, 0x00A8A8AE, c.DT_CENTER | c.DT_WORDBREAK);
        return;
    }
    const overview = state.overview_layout orelse return error.GraphLayoutUnavailable;
    for (overview.lanes) |laid_out| {
        const graph_index = laid_out.graph_index;
        const graph = model.graphs.items[graph_index];
        const roles = laid_out.layout.roles;
        const lane = overviewLaneBounds(model, graph_index, bounds, state);
        drawLaneBand(hdc, lane, state.zoom);
        const caption = overviewLaneCaption(model, graph_index, bounds, state);
        const title = try std.fmt.allocPrint(allocator, "{s} · {d} loop{s}", .{
            graph.project.name, graph.nodes.items.len, if (graph.nodes.items.len == 1) "" else "s",
        });
        defer allocator.free(title);
        drawFolderGlyph(hdc, caption.title, state.zoom, graph.project.isGlobal());
        drawTextRect(hdc, allocator, title, rect(caption.title.left + scaledValue(16, state.zoom), caption.title.top, caption.title.right, caption.title.bottom), scaledValue(11, state.zoom), 0x009D9D9D, c.DT_LEFT | c.DT_SINGLELINE | c.DT_VCENTER | c.DT_END_ELLIPSIS);
        const open = caption.open;
        const worktrees = caption.worktrees;
        fill(hdc, open, 0x002D2418);
        fill(hdc, worktrees, 0x00352B1C);
        drawTextRect(hdc, allocator, "Open", open, scaledValue(9, state.zoom), 0x00E6E6E6, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
        drawTextRect(hdc, allocator, "Worktrees", worktrees, scaledValue(8, state.zoom), 0x00FFCD7A, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
        if (caption.notice) |notice_bounds| {
            const presentation = overviewWorktreeNotice(&graph).?;
            const label = presentation.label(allocator) catch null;
            if (label) |text| {
                defer allocator.free(text);
                const is_notice = presentation.state == .notice;
                fill(hdc, notice_bounds, if (is_notice) @as(c.COLORREF, 0x00352B1C) else 0x00303035);
                const text_bounds = rect(notice_bounds.left + scaledValue(6, state.zoom), notice_bounds.top, notice_bounds.right - scaledValue(6, state.zoom), notice_bounds.bottom);
                drawTextRect(hdc, allocator, text, text_bounds, scaledValue(9, state.zoom), if (is_notice) @as(c.COLORREF, 0x00FFCD7A) else 0x00B8B8BE, c.DT_LEFT | c.DT_SINGLELINE | c.DT_VCENTER | c.DT_END_ELLIPSIS);
            } else {
                drawTextRect(hdc, allocator, "Worktree notice unavailable", notice_bounds, scaledValue(9, state.zoom), 0x00B8B8BE, c.DT_LEFT | c.DT_SINGLELINE | c.DT_VCENTER);
            }
        }
        const geometry = GraphGeometry{ .state = state, .overview = .{ .model = model, .graph_index = graph_index, .bounds = bounds } };
        drawEntryOrigin(hdc, allocator, graph.nodes.items.len, roles, geometry, lane, true);
        drawGraphEdges(hdc, graph.nodes.items, graph.edges.items, geometry, false);
        for (graph.nodes.items, 0..) |node, node_index| {
            drawLoopCardShadow(hdc, allocator, node, overviewCardBounds(model, graph_index, node_index, bounds, state),
                state, roles[node_index], needsAttention(node, graph.nodes.items, graph.edges.items), false);
        }
        var index: usize = 0;
        while (index < graph.nodes.items.len) : (index += 1) {
            const card = overviewCardBounds(model, graph_index, index, bounds, state);
            const node = graph.nodes.items[index];
            drawLoopCard(
                hdc,
                allocator,
                node,
                card,
                state,
                roles[index],
                needsAttention(node, graph.nodes.items, graph.edges.items),
                primaryCardAction(node),
                false,
                null,
                false,
            );
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
    roundedCard(hdc, band, Tokens.workspace_rail, false);
    for (model.quick_chats.items, 0..) |chat, index| {
        const card = quickChatCardBounds(index, bounds, state);
        roundedCard(hdc, card, Tokens.loop_card_bottom, false);
        fill(hdc, rect(card.left, card.top, card.left + scaledValue(4, state.zoom), card.bottom), 0x007A7A7A);
        drawText(hdc, allocator, chat.title, card.left + scaledValue(14, state.zoom), card.top + scaledValue(12, state.zoom), scaledValue(13, state.zoom), 0x00FFFFFF, card.right - scaledValue(14, state.zoom));
        drawText(hdc, allocator, if (std.mem.eql(u8, chat.backend, "claudeCode")) "chat" else chat.backend, card.left + scaledValue(14, state.zoom), card.top + scaledValue(37, state.zoom), scaledValue(10, state.zoom), 0x009A9A9A, card.right - scaledValue(14, state.zoom));
    }
}

fn overviewLaneBounds(
    model: *const GraphModel.Model,
    graph_index: usize,
    bounds: c.RECT,
    state: *const CanvasState,
) c.RECT {
    _ = model;
    const lane = cachedOverviewLane(state, graph_index) orelse return rect(0, 0, 0, 0);
    return transformedRect(bounds, state, @intFromFloat(LaneLayout.MacMetrics.band_x), @intFromFloat(lane.top), @intFromFloat(lane.width), @intFromFloat(lane.height));
}

pub fn overviewCardBounds(
    model: *const GraphModel.Model,
    graph_index: usize,
    node_index: usize,
    bounds: c.RECT,
    state: *const CanvasState,
) c.RECT {
    _ = model;
    const lane = cachedOverviewLane(state, graph_index) orelse return rect(0, 0, 0, 0);
    if (node_index >= lane.layout.positions.len) return rect(0, 0, 0, 0);
    return cardBoundsAt(lane.layout.positions[node_index], bounds, state);
}

fn cachedOverviewLane(state: *const CanvasState, graph_index: usize) ?*const LaneLayout.OverviewLane {
    const overview = &(state.overview_layout orelse return null);
    for (overview.lanes) |*lane| {
        if (lane.graph_index == graph_index) return lane;
    }
    return null;
}

pub const OverviewLaneCaption = struct {
    title: c.RECT,
    open: c.RECT,
    worktrees: c.RECT,
    notice: ?c.RECT,
};

pub const OverviewCaptionMetrics = struct {
    pub const open_trailing = 76;
    pub const open_width = 56;
    pub const worktrees_trailing = 18;
    pub const worktrees_width = 54;
    pub const notice_gap = 8;
    pub const notice_width = 286;
    pub const open_notice_offset = notice_gap + open_width / 2;
    pub const worktrees_notice_offset = notice_gap + open_trailing + open_width - worktrees_trailing - worktrees_width / 2;
    pub const actions_right_notice_offset = notice_gap + open_trailing + open_width - worktrees_trailing;
};

pub fn overviewLaneCaption(model: *const GraphModel.Model, graph_index: usize, bounds: c.RECT, state: *const CanvasState) OverviewLaneCaption {
    const lane = overviewLaneBounds(model, graph_index, bounds, state);
    const metrics = OverviewCaptionMetrics;
    const open = rect(lane.right - scaledValue(metrics.open_trailing + metrics.open_width, state.zoom), lane.top + scaledValue(10, state.zoom), lane.right - scaledValue(metrics.open_trailing, state.zoom), lane.top + scaledValue(30, state.zoom));
    const worktrees = rect(lane.right - scaledValue(metrics.worktrees_trailing + metrics.worktrees_width, state.zoom), lane.top + scaledValue(10, state.zoom), lane.right - scaledValue(metrics.worktrees_trailing, state.zoom), lane.top + scaledValue(30, state.zoom));
    const notice = if (graph_index < model.graphs.items.len and overviewWorktreeNotice(&model.graphs.items[graph_index]) != null)
        rect(open.left - scaledValue(metrics.notice_gap + metrics.notice_width, state.zoom), open.top, open.left - scaledValue(metrics.notice_gap, state.zoom), open.bottom)
    else
        null;
    return .{
        .title = rect(lane.left + scaledValue(18, state.zoom), open.top, (if (notice) |value| value.left else open.left) - scaledValue(10, state.zoom), open.bottom),
        .open = open,
        .worktrees = worktrees,
        .notice = notice,
    };
}

test "lane gate caption anchor projects to actual action hit bounds across zoom and DPI" {
    const Dpi = @import("Dpi.zig");
    var fixture = try paint764FixtureModel(std.testing.allocator, .overview);
    defer fixture.model.deinit();
    const consumer = try std.fs.cwd().readFileAlloc(std.testing.allocator, "..\\Tools\\windows\\uia-live-gate.ps1", 2 * 1024 * 1024);
    defer std.testing.allocator.free(consumer);
    inline for (.{
        .{ "laneOpenNoticeOffset", OverviewCaptionMetrics.open_notice_offset },
        .{ "laneWorktreesNoticeOffset", OverviewCaptionMetrics.worktrees_notice_offset },
        .{ "laneActionsRightNoticeOffset", OverviewCaptionMetrics.actions_right_notice_offset },
        .{ "minimumLaneWidth", @as(i32, @intFromFloat(LaneLayout.MacMetrics.bandWidth(3 * LaneLayout.MacMetrics.depth_width + LaneLayout.MacMetrics.card_width))) },
        .{ "laneCardInset", @as(i32, @intFromFloat(LaneLayout.MacMetrics.padding + LaneLayout.MacMetrics.origin_lane)) },
        .{ "captionCardTop", @as(i32, @intFromFloat(LaneLayout.MacMetrics.caption_height + LaneLayout.MacMetrics.padding)) },
        .{ "oneRowLaneHeight", @as(i32, @intFromFloat(LaneLayout.MacMetrics.bandHeight(1))) },
    }) |binding| {
        const expected = try std.fmt.allocPrint(std.testing.allocator, "${s} = {d}", .{ binding[0], binding[1] });
        defer std.testing.allocator.free(expected);
        try std.testing.expect(std.mem.indexOf(u8, consumer, expected) != null);
    }
    var cases: usize = 0;
    for ([_]f32{ 0.55, 0.75, 0.8, 1, 1.25, 1.8 }) |zoom| {
        var state = try modelTestState(&fixture.model, .{ .zoom = zoom, .pan_x = -713, .pan_y = 17 }, chrome764GraphBounds());
        defer state.deinitLayout();
        const caption = overviewLaneCaption(&fixture.model, 0, state.layout_bounds, &state);
        const card = overviewCardBounds(&fixture.model, 0, 0, state.layout_bounds, &state);
        for ([_]u32{ 96, 144, 192 }) |dpi| {
            const notice_right = Dpi.scale(caption.notice.?.right, dpi);
            const scale = @as(f32, @floatFromInt(Dpi.scale(card.right, dpi) - Dpi.scale(card.left, dpi))) / LaneLayout.MacMetrics.card_width;
            for ([_]struct { bounds: c.RECT, offset: i32 }{
                .{ .bounds = caption.open, .offset = OverviewCaptionMetrics.open_notice_offset },
                .{ .bounds = caption.worktrees, .offset = OverviewCaptionMetrics.worktrees_notice_offset },
            }) |action| {
                const x = notice_right + @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(action.offset)) * scale)));
                try std.testing.expect(x >= Dpi.scale(action.bounds.left, dpi) and x < Dpi.scale(action.bounds.right, dpi));
                try std.testing.expectEqual(Dpi.scale(caption.notice.?.top, dpi), Dpi.scale(action.bounds.top, dpi));
                try std.testing.expectEqual(Dpi.scale(caption.notice.?.bottom, dpi), Dpi.scale(action.bounds.bottom, dpi));
            }
            cases += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 18), cases);
}

pub fn overviewLaneActionAt(model: *const GraphModel.Model, graph_index: usize, x: i32, y: i32, bounds: c.RECT, state: *const CanvasState) ?OverviewLaneAction {
    if (graph_index >= model.graphs.items.len) return null;
    const caption = overviewLaneCaption(model, graph_index, bounds, state);
    if (insideGraph(x, y, caption.open)) return .open_project;
    if (insideGraph(x, y, caption.worktrees)) return .inspect_worktrees;
    if (caption.notice) |notice| {
        if (insideGraph(x, y, bounds) and insideGraph(x, y, notice)) return .inspect_worktrees;
    }
    return null;
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
    return rect(bounds.right - 148, bounds.bottom - 42, bounds.right - 12, bounds.bottom - 12);
}

fn zoomButtonBounds(bounds: c.RECT, index: i32) c.RECT {
    const controls = zoomControlsBounds(bounds);
    const offsets = [_]i32{ 6, 30, 78, 108 };
    const widths = [_]i32{ 22, 46, 22, 22 };
    const i: usize = @intCast(index);
    return rect(controls.left + offsets[i], controls.top + 4, controls.left + offsets[i] + widths[i], controls.bottom - 4);
}

pub fn zoomControlBounds(bounds: c.RECT, control: ZoomControl) c.RECT {
    return zoomButtonBounds(bounds, @intFromEnum(control));
}

fn drawZoomControls(hdc: c.HDC, allocator: std.mem.Allocator, bounds: c.RECT, state: *const CanvasState) void {
    const controls = zoomControlsBounds(bounds);
    roundedControl(hdc, controls, 15, 0x002A2827, 0x00413F3E);
    fill(hdc, rect(controls.left + 104, controls.top + 8, controls.left + 105, controls.bottom - 8), 0x004B4948);
    for (0..4) |index| {
        const button = zoomButtonBounds(bounds, @intCast(index));
        if (index == 1) {
            var percent: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&percent, "{d}%", .{@as(i32, @intFromFloat(state.zoom * 100))}) catch "100%";
            drawTextRect(hdc, allocator, text, button, 11, 0x00E0E0E0, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE);
        } else {
            drawZoomGlyph(hdc, button, @enumFromInt(index));
        }
    }
}

fn drawZoomGlyph(hdc: c.HDC, bounds: c.RECT, control: ZoomControl) void {
    const x = @divTrunc(bounds.left + bounds.right, 2);
    const y = @divTrunc(bounds.top + bounds.bottom, 2);
    const pen = c.CreatePen(c.PS_SOLID, 1, 0x00D8D8D8) orelse return;
    defer _ = c.DeleteObject(pen);
    const old_pen = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, old_pen);
    const old_brush = c.SelectObject(hdc, c.GetStockObject(c.HOLLOW_BRUSH));
    defer _ = c.SelectObject(hdc, old_brush);
    if (control == .fit) {
        const segments = [_][4]i32{
            .{ x - 6, y + 6, x - 6, y + 1 }, .{ x - 6, y + 6, x - 1, y + 6 },
            .{ x - 6, y + 6, x - 1, y + 1 }, .{ x + 6, y - 6, x + 6, y - 1 },
            .{ x + 6, y - 6, x + 1, y - 6 }, .{ x + 6, y - 6, x + 1, y - 1 },
        };
        for (segments) |line| {
            _ = c.MoveToEx(hdc, line[0], line[1], null);
            _ = c.LineTo(hdc, line[2], line[3]);
        }
    } else {
        _ = c.Ellipse(hdc, x - 7, y - 7, x + 4, y + 4);
        _ = c.MoveToEx(hdc, x + 2, y + 2, null);
        _ = c.LineTo(hdc, x + 7, y + 7);
        _ = c.MoveToEx(hdc, x - 5, y - 2, null);
        _ = c.LineTo(hdc, x + 2, y - 2);
        if (control == .in) {
            _ = c.MoveToEx(hdc, x - 2, y - 5, null);
            _ = c.LineTo(hdc, x - 2, y + 2);
        }
    }
}

pub fn addButtonBounds(bounds: c.RECT) c.RECT {
    return rect(bounds.right - 138, bounds.top + 18, bounds.right - 20, bounds.top + 48);
}

pub fn paintAddButton(hdc: c.HDC, allocator: std.mem.Allocator, bounds: c.RECT, label: []const u8, highlighted: bool, focused: bool) void {
    fill(hdc, bounds, Tokens.canvas_tone);
    roundedControl(hdc, bounds, 8, if (highlighted) 0x00232220 else 0x001A1B19, 0x00313230);
    drawTextRect(hdc, allocator, "+", rect(bounds.left + 12, bounds.top, bounds.left + 24, bounds.bottom), 14, 0x00919090, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
    drawCardText(hdc, allocator, label, rect(bounds.left + 31, bounds.top, bounds.right - 10, bounds.bottom), 12, .semibold, if (highlighted) 0x00E8E8E8 else 0x00BDBDBD, true) catch |err| {
        std.log.warn("Canvas add label unavailable: {s}", .{@errorName(err)});
    };
    if (focused) {
        var focus = bounds;
        _ = c.InflateRect(&focus, -3, -3);
        _ = c.DrawFocusRect(hdc, &focus);
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

pub fn contentSize(model: *const GraphModel.Model, surface: Surface, state: *const CanvasState) struct { width: i32, height: i32 } {
    return switch (surface) {
        .overview => if (state.overview_layout) |overview|
            .{ .width = @intFromFloat(@max(1, overview.size.x)), .height = @intFromFloat(@max(1, overview.size.y)) }
        else
            .{ .width = 1, .height = 1 },
        .quick_chats => .{
            .width = 808,
            .height = @max(1, @as(i32, @intCast(((model.quick_chats.items.len + 2) / 3) * 104 + 66))),
        },
        .project => if (state.project_layout) |layout| .{
            .width = @intFromFloat(LaneLayout.MacMetrics.band_x * 2 + LaneLayout.MacMetrics.bandWidth(layout.content_width)),
            .height = projectContentHeight(layout),
        } else .{ .width = 1, .height = 1 },
        .workspace => .{ .width = 1, .height = 1 },
    };
}

fn projectContentHeight(layout: LaneLayout.Layout) i32 {
    var bottom = LaneLayout.MacMetrics.origin.y;
    for (layout.positions) |position| bottom = @max(bottom, position.y);
    return @intFromFloat(bottom + LaneLayout.MacMetrics.card_height / 2 + LaneLayout.MacMetrics.padding + LaneLayout.MacMetrics.lane_top);
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
    try std.testing.expectEqual(
        @as(i32, 900 - Tokens.workspace_height - Tokens.activity_strip_height),
        sidebarBottom(900, .{}, .project),
    );
    try std.testing.expectEqual(
        @as(i32, 900 - Tokens.activity_strip_height),
        sidebarBottom(900, .{}, .workspace),
    );
}

test "inline canvas alerts remain inside the active detail surface" {
    const bounds = rect(Tokens.sidebar_width, Tokens.header_height, 1200, 800);
    const alert = inlineAlertBounds(bounds);
    try std.testing.expect(alert.left > bounds.left);
    try std.testing.expect(alert.top > bounds.top);
    try std.testing.expect(alert.right < bounds.right);
    try std.testing.expect(alert.bottom < bounds.bottom);
}

pub fn paintHeader(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    width: i32,
    status: []const u8,
    presentation: Header,
    focused: ?HeaderAction,
) void {
    fill(hdc, rect(0, 0, width, Tokens.header_height), Tokens.window_tone);
    const layout = presentation.layout(width);
    const flags = c.DT_SINGLELINE | c.DT_VCENTER | c.DT_END_ELLIPSIS | c.DT_NOPREFIX;
    var title_bounds = layout.identity;
    if (presentation.project_glyph) |glyph| {
        const glyph_bounds = rect(title_bounds.left, 9, title_bounds.left + 14, 24);
        drawHeaderProjectGlyph(hdc, glyph_bounds, glyph);
        title_bounds.left += 21;
    } else if (presentation.context.len != 0) {
        var context_bounds = layout.identity;
        context_bounds.top = 1;
        context_bounds.bottom = 15;
        title_bounds.top = 14;
        title_bounds.bottom = Tokens.header_height - 1;
        drawTextRect(hdc, allocator, presentation.context, context_bounds, 8, 0x00A8A8A8, flags);
    }
    if (presentation.project_glyph != null) {
        drawCardText(hdc, allocator, presentation.title, title_bounds, 13, .semibold, 0x00F4F4F4, true) catch |err| {
            std.log.warn("Project identity unavailable: {s}", .{@errorName(err)});
        };
    } else {
        drawTextRect(hdc, allocator, presentation.title, title_bounds, 11, 0x00FFFFFF, flags);
    }
    for (header_actions) |action| {
        const bounds = layout.bounds(action) orelse continue;
        const notice = action == .review_attention or action == .inspect_worktrees;
        fill(hdc, bounds, if (notice) @as(c.COLORREF, 0x00352B1C) else 0x00282828);
        const label = presentation.label(allocator, action) catch {
            std.debug.print("Unable to allocate header control label\n", .{});
            continue;
        };
        defer allocator.free(label);
        var text_bounds = bounds;
        text_bounds.left += 4;
        text_bounds.right -= 4;
        drawTextRect(hdc, allocator, label, text_bounds, 10, if (notice) @as(c.COLORREF, 0x00FFCD7A) else 0x00D8D8D8, flags | c.DT_CENTER);
        if (focused == action) {
            var ring = bounds;
            _ = c.InflateRect(&ring, -1, -1);
            _ = c.DrawFocusRect(hdc, &ring);
        }
    }
    if (layout.status.right > layout.status.left) drawTextRect(hdc, allocator, status, layout.status, 10, 0x00A8A8A8, flags);
}

fn drawHeaderProjectGlyph(hdc: c.HDC, bounds: c.RECT, glyph: Header.ProjectGlyph) void {
    const color: u32 = 0x00EFA55D;
    if (glyph == .folder) {
        roundedControl(hdc, rect(bounds.left, bounds.top + 2, bounds.left + 6, bounds.top + 7), 1, color, color);
        roundedControl(hdc, rect(bounds.left, bounds.top + 5, bounds.right, bounds.bottom - 1), 2, color, color);
    } else {
        drawGraphDot(hdc, .{ .x = bounds.left + 7, .y = bounds.top + 7 }, 12, Tokens.window_tone, color, 1);
        const pen = c.CreatePen(c.PS_SOLID, 1, color) orelse return;
        defer _ = c.DeleteObject(pen);
        const old = c.SelectObject(hdc, pen);
        defer _ = c.SelectObject(hdc, old);
        _ = c.MoveToEx(hdc, bounds.left + 1, bounds.top + 7, null);
        _ = c.LineTo(hdc, bounds.right - 1, bounds.top + 7);
        if (glyph == .remote) {
            _ = c.MoveToEx(hdc, bounds.left + 7, bounds.top + 1, null);
            _ = c.LineTo(hdc, bounds.left + 7, bounds.top + 13);
        }
    }
}

test "header layout shares visibility hit testing and focus order at narrow widths" {
    const header = Header{ .attention_count = 2, .notice = .{ .total = 8, .reclaimable = 3, .blocked = 5 }, .notice_name = "Project", .panel_visible = false };
    for ([_]i32{ 480, 640, 900, 1280 }) |width| {
        const layout = header.layout(width);
        var previous_right = layout.identity.right;
        var focused: ?HeaderAction = null;
        for (header_actions) |action| {
            const bounds = layout.bounds(action).?;
            try std.testing.expect(bounds.left > previous_right);
            try std.testing.expect(bounds.right > bounds.left);
            try std.testing.expect(bounds.right <= width);
            try std.testing.expectEqual(action, layout.actionAt(bounds.left + 1, bounds.top + 1).?);
            focused = layout.step(focused, false);
            try std.testing.expectEqual(action, focused.?);
            previous_right = bounds.right;
        }
        try std.testing.expect(previous_right <= layout.status.left);
        try std.testing.expectEqual(HeaderAction.review_attention, layout.step(focused, false).?);
        try std.testing.expectEqual(HeaderAction.toggle_panel, layout.step(null, true).?);
    }
    const empty = (Header{}).layout(640);
    try std.testing.expectEqual(HeaderAction.jump, empty.step(.toggle_panel, false).?);
    try std.testing.expect(empty.bounds(.toggle_panel) == null);
    try std.testing.expect(empty.bounds(.inspect_worktrees) == null);
    try std.testing.expect(empty.bounds(.review_attention) == null);
    try std.testing.expect(empty.actionAt(0, Tokens.header_height) == null);
}

test "header panel belongs only to a selected workspace loop with supported content" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"C:\\test","name":"Test"},"nodes":[{"id":"a","title":"A","state":"idle"},{"id":"b","title":"B","state":"idle","metricHistory":[{"value":1},{"value":2}]},{"id":"c","title":"C","state":"idle"}],"edges":[{"from":"a","to":"b"}]}}}
    );
    try std.testing.expect(model.setSelectedIndex(0));
    for ([_]Surface{ .project, .overview, .quick_chats }) |surface| {
        try std.testing.expect(!loopPanelHasContent(&model, surface, false));
    }
    try std.testing.expect(loopPanelHasContent(&model, .workspace, false));
    try std.testing.expect(!loopPanelHasContent(&model, .workspace, true));
    try std.testing.expect(model.setSelectedIndex(1));
    try std.testing.expect(loopPanelHasContent(&model, .workspace, false));
    try std.testing.expect(model.setSelectedIndex(2));
    try std.testing.expect(!loopPanelHasContent(&model, .workspace, false));
    model.selected_index = null;
    try std.testing.expect(!loopPanelHasContent(&model, .workspace, false));
}

test "header notice threshold and owner gating exclude invisible actions" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"C:\\test","name":"Test"},"nodes":[],"edges":[]}}}
    );
    var inspection = WorktreeStatus.Inspection{
        .entries = std.array_list.Managed(WorktreeStatus.Entry).init(std.testing.allocator),
        .project_path = @constCast("C:\\test"),
        .default_branch = @constCast("main"),
    };
    defer inspection.entries.deinit();
    try inspection.entries.append(.{ .path = @constCast("C:\\tree"), .branch = @constCast("topic"), .size_bytes = 1024 * 1024 * 1024 - 1, .size_complete = true });
    const policy = WorktreeStatus.Policy{ .notice_count = 2, .notice_size_gb = 1 };
    try std.testing.expect(!headerWorktreeNotice(&model, &inspection, policy));
    inspection.entries.items[0].size_bytes += 1;
    try std.testing.expect(headerWorktreeNotice(&model, &inspection, policy));
    inspection.entries.items[0].size_bytes += 1;
    try std.testing.expect(headerWorktreeNotice(&model, &inspection, policy));
    inspection.entries.items[0].size_bytes = 0;
    try std.testing.expect(!headerWorktreeNotice(&model, &inspection, policy));
    try inspection.entries.append(inspection.entries.items[0]);
    try std.testing.expect(headerWorktreeNotice(&model, &inspection, policy));
    try inspection.entries.append(inspection.entries.items[0]);
    try std.testing.expect(headerWorktreeNotice(&model, &inspection, policy));
    inspection.entries.shrinkRetainingCapacity(1);
    inspection.entries.items[0].size_complete = false;
    inspection.entries.items[0].size_error = error.AccessDenied;
    try std.testing.expectEqual(WorktreeStatus.NoticeState.indeterminate, WorktreeStatus.noticeState(inspection.entries.items, policy));
    try std.testing.expect(!headerWorktreeNotice(&model, &inspection, policy));
    inspection.entries.items[0].size_bytes = 1024 * 1024 * 1024;
    try std.testing.expect(headerWorktreeNotice(&model, &inspection, policy));
    inspection.project_path = @constCast("C:\\foreign");
    try std.testing.expect(!headerWorktreeNotice(&model, &inspection, policy));
}

test "worktree notice header never treats nonlocal projects as local inspections" {
    const frames = [_][]const u8{
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"ssh://host/repo","name":"Remote"},"nodes":[],"edges":[]}}}
        ,
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"codespace://name/repo","name":"Codespace"},"nodes":[],"edges":[]}}}
        ,
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"graphcode://global","name":"Global"},"nodes":[],"edges":[]}}}
        ,
    };
    for (frames) |frame| {
        var model = GraphModel.Model.init(std.testing.allocator);
        defer model.deinit();
        _ = try model.updateFromFrame(frame);
        var inspection = WorktreeStatus.Inspection{
            .entries = std.array_list.Managed(WorktreeStatus.Entry).init(std.testing.allocator),
            .project_path = model.currentGraph().?.project.path,
            .default_branch = @constCast("main"),
        };
        defer inspection.entries.deinit();
        try inspection.entries.append(.{
            .path = @constCast("worktree"),
            .branch = @constCast("topic"),
            .size_bytes = 2147483648,
            .size_complete = true,
        });
        try std.testing.expect(!headerWorktreeNotice(&model, &inspection, .{}));
    }
}

test "worktree notice lane geometry preserves old actions and shares the new chip hit target" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    const frames = [_][]const u8{
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"C:\\a","name":"Same"},"nodes":[],"edges":[]}}}
        ,
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"project":{"path":"C:\\b","name":"Same"},"nodes":[],"edges":[]}}}
        ,
        \\{"version":2,"kind":"event","sequence":3,"event":{"graphChanged":{"project":{"path":"graphcode://global","name":"Global"},"nodes":[],"edges":[]}}}
        ,
    };
    for (frames) |frame| _ = try model.updateFromFrame(frame);
    const bounds = rect(220, 34, 3200, 1400);
    var state = try modelTestState(&model, .{}, bounds);
    defer state.deinitLayout();
    const a = overviewLaneCaption(&model, 0, bounds, &state);
    const b = overviewLaneCaption(&model, 1, bounds, &state);
    try std.testing.expectEqualDeep(rect(1690, 106, 1746, 126), a.open);
    try std.testing.expectEqualDeep(rect(1750, 106, 1804, 126), a.worktrees);
    try std.testing.expectEqualDeep(rect(1396, 106, 1682, 126), a.notice.?);
    try std.testing.expectEqualDeep(rect(1396, 284, 1682, 304), b.notice.?);
    try std.testing.expect(a.title.right < a.notice.?.left);
    try std.testing.expect(a.notice.?.right < a.open.left);
    try std.testing.expectEqual(OverviewLaneAction.inspect_worktrees, overviewLaneActionAt(&model, 0, 1406, 116, bounds, &state).?);
    try std.testing.expectEqual(OverviewLaneAction.inspect_worktrees, overviewLaneActionAt(&model, 1, 1406, 294, bounds, &state).?);
    try std.testing.expect(overviewLaneActionAt(&model, 0, 1406, 294, bounds, &state) == null);
    try std.testing.expect(overviewLaneActionAt(&model, 0, 1386, 116, bounds, &state) == null);
    try std.testing.expect(overviewLaneCaption(&model, 2, bounds, &state).notice == null);
    var transformed = try modelTestState(&model, .{ .zoom = 1.5, .pan_x = 17, .pan_y = -9 }, bounds);
    defer transformed.deinitLayout();
    try std.testing.expectEqualDeep(rect(2111, 150, 2540, 180), overviewLaneCaption(&model, 0, bounds, &transformed).notice.?);
    try std.testing.expectEqual(OverviewLaneAction.inspect_worktrees, overviewLaneActionAt(&model, 0, 2120, 156, bounds, &transformed).?);
    try std.testing.expect(overviewLaneActionAt(&model, 0, 2300, 190, bounds, &transformed) == null);
    const identity_a = try overviewWorktreeNoticeIdentity(std.testing.allocator, "C:\\a");
    defer std.testing.allocator.free(identity_a);
    const identity_b = try overviewWorktreeNoticeIdentity(std.testing.allocator, "C:\\b");
    defer std.testing.allocator.free(identity_b);
    try std.testing.expectEqualStrings("overview-worktree-notice:C:\\a", identity_a);
    try std.testing.expect(!std.mem.eql(u8, identity_a, identity_b));
}

test "worktree notice lane uses production observations for exact count and size boundaries" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"C:\\a","name":"A"},"nodes":[],"edges":[]}}}
    );
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"project":{"path":"C:\\b","name":"B"},"nodes":[],"edges":[]}}}
    );
    var inspection = WorktreeStatus.Inspection{
        .entries = std.array_list.Managed(WorktreeStatus.Entry).init(std.testing.allocator),
        .project_path = @constCast("C:\\a"),
        .default_branch = @constCast("main"),
    };
    defer inspection.entries.deinit();
    for (0..9) |_| try inspection.entries.append(.{
        .path = @constCast("tree"),
        .branch = @constCast("topic"),
        .size_complete = true,
    });
    const policy = WorktreeStatus.policyReadOutcome(error.FileNotFound);
    for ([_]usize{ 7, 8, 9 }, [_]WorktreeStatus.NoticeState{ .below_threshold, .notice, .notice }) |count, expected| {
        inspection.entries.items.len = count;
        try model.recordWorktreeInspection(&inspection, policy);
        const presentation = overviewWorktreeNotice(model.graphFor("C:\\a").?).?;
        try std.testing.expectEqual(expected, presentation.state);
        try std.testing.expectEqual(count, presentation.summary.?.total);
        try std.testing.expectEqual(WorktreeStatus.NoticePhase.uninspected, overviewWorktreeNotice(model.graphFor("C:\\b").?).?.phase);
    }
    inspection.entries.items.len = 1;
    for ([_]u64{ 2147483647, 2147483648, 2147483649 }, [_]WorktreeStatus.NoticeState{ .below_threshold, .notice, .notice }) |bytes, expected| {
        inspection.entries.items[0].size_bytes = bytes;
        try model.recordWorktreeInspection(&inspection, policy);
        try std.testing.expectEqual(expected, overviewWorktreeNotice(model.graphFor("C:\\a").?).?.state);
    }
    try model.recordWorktreePolicy("C:\\a", WorktreeStatus.policyReadOutcome(error.AccessDenied));
    try std.testing.expectEqual(WorktreeStatus.NoticeState.indeterminate, overviewWorktreeNotice(model.graphFor("C:\\a").?).?.state);
    inspection.entries.clearRetainingCapacity();
    try model.recordWorktreeInspection(&inspection, policy);
    try std.testing.expect(overviewWorktreeNotice(model.graphFor("C:\\a").?) == null);
    const bounds = rect(220, 34, 2200, 900);
    var state = try modelTestState(&model, .{}, bounds);
    defer state.deinitLayout();
    try std.testing.expect(overviewLaneCaption(&model, 0, bounds, &state).notice == null);
    try std.testing.expectEqual(OverviewLaneAction.inspect_worktrees, overviewLaneActionAt(&model, 0, 1770, 116, bounds, &state).?);
}

fn attentionRail(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    model: *const GraphModel.Model,
    bounds: c.RECT,
) void {
    if (model.attentionCount() == 0) return;
    var count: [32]u8 = undefined;
    const label = if (model.attentionCount() == 1)
        "1 loop needs you"
    else
        std.fmt.bufPrint(&count, "{d} loops need you", .{model.attentionCount()}) catch "loops need you";
    const layout = attentionRailLayout(bounds);
    if (layout.rail.right <= layout.rail.left) return;
    roundedControl(hdc, layout.rail, 8, 0x00111E2A, 0x00123954);
    drawGraphDot(hdc, .{ .x = layout.rail.left + 14, .y = layout.rail.top + 15 }, 7, 0x000A9FFF, 0x000A9FFF, 0);
    drawCardText(hdc, allocator, label, layout.count, 12, .semibold, 0x007ACDFF, true) catch |err| {
        std.log.warn("Attention count unavailable: {s}", .{@errorName(err)});
    };
    var age_buffer: [96]u8 = undefined;
    const oldest = if (model.attention_entries.items.len != 0)
        attentionAgeLabel(&age_buffer, model.attention_entries.items[0].node)
    else
        "";
    drawCardText(hdc, allocator, oldest, layout.age, 10, .card_mono, 0x00467191, true) catch |err| {
        std.log.warn("Attention age unavailable: {s}", .{@errorName(err)});
    };
    roundedControl(hdc, layout.review, 5, 0x000B90E8, 0x000B90E8);
    drawCardText(hdc, allocator, "Review", rect(layout.review.left + 8, layout.review.top, layout.review.left + 44, layout.review.bottom), 11, .card_state, 0x00031724, false) catch |err| {
        std.log.warn("Attention review label unavailable: {s}", .{@errorName(err)});
    };
    drawCardText(hdc, allocator, "Ctrl+Shift+R", rect(layout.review.left + 47, layout.review.top, layout.review.right - 3, layout.review.bottom), 9.5, .card_mono, 0x00102E49, true) catch |err| {
        std.log.warn("Attention review shortcut unavailable: {s}", .{@errorName(err)});
    };
}

fn attentionAgeLabel(buffer: []u8, node: GraphModel.Node) []const u8 {
    return attentionAgeLabelAt(buffer, node, @intCast(@max(0, std.time.timestamp())));
}

fn attentionAgeLabelAt(buffer: []u8, node: GraphModel.Node, now: u64) []const u8 {
    if (node.created_at) |created| {
        var stream = std.io.fixedBufferStream(buffer);
        stream.writer().writeAll("oldest ") catch |err| {
            std.log.warn("Attention age unavailable: {s}", .{@errorName(err)});
            return "Age unavailable";
        };
        writeCardAge(stream.writer(), now -| created) catch |err| {
            std.log.warn("Attention age unavailable: {s}", .{@errorName(err)});
            return "Age unavailable";
        };
        return stream.getWritten();
    }
    return "";
}

fn activityStrip(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    model: *const GraphModel.Model,
    bounds: c.RECT,
) void {
    fill(hdc, bounds, 0x001D1D21);
    const summary_left = bounds.left + 76;
    const card_left = bounds.left + 142;
    drawText(hdc, allocator, "ACTIVITY", bounds.left + 16, bounds.top + 10, 10, 0x007A7A7A, summary_left - 12);
    var count_buffer: [32]u8 = undefined;
    const summary = std.fmt.bufPrint(&count_buffer, "{d} recent", .{model.activity.items.len}) catch "recent";
    drawText(hdc, allocator, summary, summary_left, bounds.top + 10, 10, 0x00909098, card_left - 12);
    var x = card_left;
    const visible_count = @min(model.activity.items.len, 4);
    const start = model.activity.items.len - visible_count;
    for (model.activity.items[start..]) |event| {
        const card = rect(x, bounds.top + 5, @min(x + 176, bounds.right - 8), bounds.bottom - 5);
        if (card.right <= card.left) break;
        roundedCard(hdc, card, 0x0026262B, false);
        fill(hdc, rect(card.left, card.top, card.left + 3, card.bottom), stateColor(event.state, false));
        drawText(hdc, allocator, event.title, card.left + 10, card.top + 7, 10, 0x00D8D8DE, card.right - 10);
        drawText(hdc, allocator, compactActivityState(event.state), card.left + 10, card.top + 22, 9, stateColor(event.state, false), card.right - 10);
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
    drawGraphEdges(hdc, graph.nodes.items, graph.edges.items, .{ .state = state }, true);
    if (state.edge_dragging) {
        if (state.edge_drag_source_id.len != 0) {
            if (connectorPosition(graph.nodes.items, state.edge_drag_source_id, true, state)) |from| {
                drawBezier(hdc, from, .{ .x = state.edge_drag_x, .y = state.edge_drag_y }, Tokens.rgb(Tokens.canvas_selection), state.zoom);
            }
        }
    }
}

fn drawEdgeLabels(hdc: c.HDC, allocator: std.mem.Allocator, graph: GraphModel.Graph, state: *const CanvasState) void {
    var placed: [128]c.RECT = undefined;
    var placed_count: usize = 0;
    for (graph.edges.items, 0..) |edge, index| {
        const from = connectorPosition(graph.nodes.items, edge.from, true, state) orelse continue;
        const to = connectorPosition(graph.nodes.items, edge.to, false, state) orelse continue;
        const selected = if (state.selected_edge_id.len != 0)
            std.mem.eql(u8, edge.id, state.selected_edge_id)
        else
            state.selected_edge == index;
        const color = if (selected)
            Tokens.rgb(Tokens.canvas_selection)
        else if (edge.fired or edge.fire_count > 0)
            0x006BD58D
        else
            edgeKindColor(edge.kind);
        const label_result = edgeLabel(allocator, edge);
        defer if (label_result) |owned| allocator.free(owned) else |_| {};
        const label = if (label_result) |text| text else |err| switch (err) {
            error.OutOfMemory => "Edge label unavailable (out of memory)",
            error.InvalidUtf8 => "Edge label unavailable (invalid text)",
        };
        const center_x = @divTrunc(from.x + to.x, 2);
        var label_y = if (@abs(to.y - from.y) < 40)
            @min(from.y, to.y) - 76
        else
            @divTrunc(from.y + to.y, 2) - 10;
        var bounds = rect(center_x - 74, label_y, center_x + 74, label_y + 20);
        var attempts: usize = 0;
        while (attempts < 12 and overlapsPlaced(bounds, placed[0..placed_count])) : (attempts += 1) {
            label_y += 24;
            bounds = rect(center_x - 74, label_y, center_x + 74, label_y + 20);
        }
        if (placed_count < placed.len) {
            placed[placed_count] = bounds;
            placed_count += 1;
        }
        drawTextRect(hdc, allocator, label, bounds, 10, color, c.DT_CENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);
    }
}

fn overlapsPlaced(candidate: c.RECT, placed: []const c.RECT) bool {
    for (placed) |other| {
        if (candidate.left < other.right and candidate.right > other.left and
            candidate.top < other.bottom and candidate.bottom > other.top)
            return true;
    }
    return false;
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

fn edgeLabel(allocator: std.mem.Allocator, edge: GraphModel.Edge) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    const writer = output.writer();
    const kind = if (edge.kind.len == 0) "handoff" else edge.kind;
    try writer.writeAll(kind);
    if (edge.fire_count > 0 or !std.mem.eql(u8, edge.condition, "always"))
        try writer.print(" · {s}", .{edge.condition});
    if (edge.cycle_guard) |guard| {
        try writer.print(" · loop {d}/", .{edge.fire_count});
        try writeCycleGuard(writer, guard);
    } else if (edge.fire_count > 0) {
        try writer.print(" · fired {d}", .{edge.fire_count});
    }
    return output.toOwnedSlice();
}

fn writeCycleGuard(writer: anytype, guard: GraphModel.CycleGuard) !void {
    var has_part = false;
    if (guard.max_iterations) |maximum| {
        try writer.print("≤{d}×", .{maximum});
        has_part = true;
    }
    if (guard.until) |raw| {
        const until = try effectiveEdgeUntil(raw);
        if (until.len != 0) {
            if (has_part) try writer.writeAll(" or ");
            try writer.print("until `{s}`", .{until});
            has_part = true;
        }
    }
    if (guard.stop_after_passes_without_improvement) |passes| {
        if (passes > 0) {
            if (has_part) try writer.writeAll(" or ");
            try writer.print("{d} flat passes", .{passes});
            has_part = true;
        }
    }
    if (!has_part) try writer.writeAll("unbounded");
}

fn effectiveEdgeUntil(text: []const u8) error{InvalidUtf8}![]const u8 {
    const view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var iterator = view.iterator();
    var start = text.len;
    var end: usize = 0;
    var offset: usize = 0;
    while (iterator.nextCodepointSlice()) |bytes| {
        const codepoint = std.unicode.utf8Decode(bytes) catch return error.InvalidUtf8;
        // Foundation .whitespaces: Unicode space separators plus horizontal tab, not newlines.
        const whitespace = switch (codepoint) {
            0x09, 0x20, 0xa0, 0x1680, 0x2000...0x200a, 0x202f, 0x205f, 0x3000 => true,
            else => false,
        };
        if (!whitespace) {
            start = @min(start, offset);
            end = offset + bytes.len;
        }
        offset += bytes.len;
    }
    return text[@min(start, end)..end];
}

fn drawBezier(hdc: c.HDC, from: Connector, to: Connector, color: u32, zoom: f32) void {
    drawRoute(hdc, CubicRoute.between(from, to, zoom), color, 2 * zoom, null);
}

const Connector = struct {
    x: i32,
    y: i32,
};

const CubicRoute = struct {
    from: Connector,
    out: Connector,
    in: Connector,
    to: Connector,

    fn between(from: Connector, to: Connector, zoom: f32) CubicRoute {
        const span = to.x - from.x;
        const reach: i32 = @max(scaledValue(26, zoom), @divTrunc(@as(i32, @intCast(@abs(span))), 2));
        const bend = if (span < 0) -reach else reach;
        return .{
            .from = from,
            .out = .{ .x = from.x + bend, .y = from.y },
            .in = .{ .x = to.x - bend, .y = to.y },
            .to = to,
        };
    }

    fn point(self: CubicRoute, t: f32) Connector {
        const one = 1 - t;
        return .{
            .x = @intFromFloat(@as(f32, @floatFromInt(self.from.x)) * one * one * one +
                @as(f32, @floatFromInt(self.out.x)) * 3 * one * one * t +
                @as(f32, @floatFromInt(self.in.x)) * 3 * one * t * t +
                @as(f32, @floatFromInt(self.to.x)) * t * t * t),
            .y = @intFromFloat(@as(f32, @floatFromInt(self.from.y)) * one * one * one +
                @as(f32, @floatFromInt(self.out.y)) * 3 * one * one * t +
                @as(f32, @floatFromInt(self.in.y)) * 3 * one * t * t +
                @as(f32, @floatFromInt(self.to.y)) * t * t * t),
        };
    }
};

const GraphGeometry = struct {
    state: *const CanvasState,
    overview: ?struct { model: *const GraphModel.Model, graph_index: usize, bounds: c.RECT } = null,

    fn card(self: GraphGeometry, index: usize) c.RECT {
        if (self.overview) |view|
            return overviewCardBounds(view.model, view.graph_index, index, view.bounds, self.state);
        return nodeBounds(index, self.state);
    }
};

fn graphEdgeRoute(nodes: []const GraphModel.Node, edge: GraphModel.Edge, geometry: GraphGeometry) ?CubicRoute {
    var source: ?c.RECT = null;
    var target: ?c.RECT = null;
    for (nodes, 0..) |node, index| {
        if (std.mem.eql(u8, node.id, edge.from)) source = geometry.card(index);
        if (std.mem.eql(u8, node.id, edge.to)) target = geometry.card(index);
    }
    const from = source orelse return null;
    const to = target orelse return null;
    const forward = from.left + from.right <= to.left + to.right;
    return CubicRoute.between(
        .{ .x = if (forward) from.right else from.left, .y = @divTrunc(from.top + from.bottom, 2) },
        .{ .x = if (forward) to.left else to.right, .y = @divTrunc(to.top + to.bottom, 2) },
        geometry.state.zoom,
    );
}

fn graphEdgeColor(edge: GraphModel.Edge, selected: bool) u32 {
    if (selected) return Tokens.canvas_selection;
    if (edge.cycle_guard != null and edge.fire_count > 0)
        return blendCardColor(0x000A9FFF, Tokens.canvas_tone, 55);
    if (std.mem.eql(u8, edge.kind, "spawn"))
        return blendCardColor(0x00E98590, Tokens.canvas_tone, 50);
    return blendCardColor(0x00FFFFFF, Tokens.canvas_tone, if (std.mem.eql(u8, edge.kind, "message")) 28 else 45);
}

fn graphEdgeDash(edge: GraphModel.Edge) ?[2]i32 {
    if (edge.cycle_guard != null and edge.fire_count > 0) return .{ 5, 4 };
    if (std.mem.eql(u8, edge.kind, "message")) return .{ 4, 4 };
    if (std.mem.eql(u8, edge.kind, "spawn")) return .{ 2, 4 };
    return if (edge.fired or edge.fire_count > 0) null else .{ 5, 4 };
}

fn drawRoute(hdc: c.HDC, route: CubicRoute, color: u32, width: f32, dash: ?[2]i32) void {
    if (dash == null and GdiplusAA.drawBezier(hdc, route.from.x, route.from.y, route.out.x, route.out.y, route.in.x, route.in.y, route.to.x, route.to.y, color, width)) return;
    var brush = std.mem.zeroes(c.LOGBRUSH);
    brush.lbStyle = c.BS_SOLID;
    brush.lbColor = color;
    var pattern: [2]c.DWORD = .{ 1, 1 };
    if (dash) |values| {
        pattern = .{ @intCast(values[0]), @intCast(values[1]) };
    }
    const pen = c.ExtCreatePen(@intCast(c.PS_GEOMETRIC | c.PS_ENDCAP_FLAT | c.PS_JOIN_ROUND |
        @as(c_int, if (dash == null) c.PS_SOLID else c.PS_USERSTYLE)), @intFromFloat(@max(1, @round(width))), &brush, if (dash == null) 0 else 2, if (dash == null) null else &pattern);
    if (pen == null) {
        std.log.warn("Canvas connector pen creation failed: {d}", .{c.GetLastError()});
        return;
    }
    defer _ = c.DeleteObject(pen);
    const old = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, old);
    const points = [_]c.POINT{
        .{ .x = route.from.x, .y = route.from.y }, .{ .x = route.out.x, .y = route.out.y },
        .{ .x = route.in.x, .y = route.in.y },     .{ .x = route.to.x, .y = route.to.y },
    };
    if (c.PolyBezier(hdc, &points, points.len) == 0)
        std.log.warn("Canvas connector paint failed: {d}", .{c.GetLastError()});
}

fn drawGraphEdges(hdc: c.HDC, nodes: []const GraphModel.Node, edges: []const GraphModel.Edge, geometry: GraphGeometry, selectable: bool) void {
    const zoom = geometry.state.zoom;
    for (edges, 0..) |edge, index| {
        const route = graphEdgeRoute(nodes, edge, geometry) orelse continue;
        const selected = selectable and (if (geometry.state.selected_edge_id.len != 0)
            std.mem.eql(u8, edge.id, geometry.state.selected_edge_id)
        else
            geometry.state.selected_edge == index);
        const color = graphEdgeColor(edge, selected);
        const logical_dash = graphEdgeDash(edge);
        const dash: ?[2]i32 = if (logical_dash) |values|
            .{ scaledValue(values[0], zoom), scaledValue(values[1], zoom) }
        else
            null;
        drawRoute(hdc, route, color, (if (selected) @as(f32, 2.5) else 1.5) * zoom, dash);
        const direction: i32 = if (route.to.x >= route.in.x) 1 else -1;
        const length = scaledValue(7, zoom);
        const half = scaledValue(3, zoom);
        const head = [_]c.POINT{
            .{ .x = route.to.x, .y = route.to.y },
            .{ .x = route.to.x - direction * length, .y = route.to.y - half },
            .{ .x = route.to.x - direction * length, .y = route.to.y + half },
        };
        const brush = c.CreateSolidBrush(color);
        if (brush != null) {
            const old_brush = c.SelectObject(hdc, brush);
            const old_pen = c.SelectObject(hdc, c.GetStockObject(c.NULL_PEN));
            _ = c.Polygon(hdc, &head, head.len);
            _ = c.SelectObject(hdc, old_pen);
            _ = c.SelectObject(hdc, old_brush);
            _ = c.DeleteObject(brush);
        } else {
            std.log.warn("Canvas edge arrow brush creation failed: {d}", .{c.GetLastError()});
        }
        if (edge.fired or edge.fire_count > 0) {
            const middle = route.point(0.5);
            drawGraphDot(hdc, middle, scaledValue(5, zoom), 0x00FFBC7C, 0x00FFBC7C, 0);
        }
    }
}

fn drawGraphDot(hdc: c.HDC, center: Connector, diameter: i32, color: u32, border: u32, border_width: f32) void {
    const radius = @divTrunc(diameter, 2);
    const bounds = rect(center.x - radius, center.y - radius, center.x - radius + diameter, center.y - radius + diameter);
    if (GdiplusAA.drawRoundedRect(hdc, bounds, radius, color, border, border_width)) return;
    const brush = c.CreateSolidBrush(color);
    const pen = c.CreatePen(c.PS_SOLID, @intFromFloat(@max(1, @round(border_width))), border);
    if (brush == null or pen == null) {
        if (brush != null) _ = c.DeleteObject(brush);
        if (pen != null) _ = c.DeleteObject(pen);
        std.log.warn("Canvas port resource creation failed: {d}", .{c.GetLastError()});
        return;
    }
    defer _ = c.DeleteObject(brush);
    defer _ = c.DeleteObject(pen);
    const old_brush = c.SelectObject(hdc, brush);
    const old_pen = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, old_brush);
    defer _ = c.SelectObject(hdc, old_pen);
    _ = c.Ellipse(hdc, bounds.left, bounds.top, bounds.right, bounds.bottom);
}

fn drawLaneBand(hdc: c.HDC, bounds: c.RECT, zoom: f32) void {
    const pen = c.CreatePen(c.PS_SOLID, 1, blendCardColor(0x00FFFFFF, Tokens.canvas_tone, 5));
    if (pen == null) {
        std.log.warn("Canvas band pen creation failed: {d}", .{c.GetLastError()});
        return;
    }
    defer _ = c.DeleteObject(pen);
    const old_pen = c.SelectObject(hdc, pen);
    const old_brush = c.SelectObject(hdc, c.GetStockObject(c.NULL_BRUSH));
    defer _ = c.SelectObject(hdc, old_pen);
    defer _ = c.SelectObject(hdc, old_brush);
    const diameter = scaledValue(24, zoom);
    _ = c.RoundRect(hdc, bounds.left, bounds.top, bounds.right, bounds.bottom, diameter, diameter);
}

fn graphBand(node_count: usize, geometry: GraphGeometry) ?c.RECT {
    if (node_count == 0) return null;
    var bounds = geometry.card(0);
    for (1..node_count) |index| {
        const card = geometry.card(index);
        bounds.left = @min(bounds.left, card.left);
        bounds.top = @min(bounds.top, card.top);
        bounds.right = @max(bounds.right, card.right);
        bounds.bottom = @max(bounds.bottom, card.bottom);
    }
    return rect(bounds.left - scaledValue(82, geometry.state.zoom), bounds.top - scaledValue(20, geometry.state.zoom), bounds.right + scaledValue(20, geometry.state.zoom), bounds.bottom + scaledValue(20, geometry.state.zoom));
}

fn drawEntryOrigin(hdc: c.HDC, allocator: std.mem.Allocator, node_count: usize, roles: []const NodeRole, geometry: GraphGeometry, band: c.RECT, overview: bool) void {
    _ = overview;
    var has_entry = false;
    for (roles) |role| {
        if (role == .entry or role == .unwired) has_entry = true;
    }
    if (!has_entry) return;
    const zoom = geometry.state.zoom;
    const enclosing = graphBand(node_count, geometry) orelse return;
    const first_left = enclosing.left + scaledValue(82, zoom);
    const origin = Connector{
        .x = band.left + scaledValue(31, zoom),
        .y = @divTrunc(band.top + band.bottom, 2),
    };
    const color = blendCardColor(0x00FFFFFF, Tokens.canvas_tone, 22);
    for (roles, 0..) |role, index| {
        if (role != .entry and role != .unwired) continue;
        const card = geometry.card(index);
        const port = Connector{ .x = card.left, .y = @divTrunc(card.top + card.bottom, 2) };
        if (card.left < first_left + scaledValue(Tokens.loop_card_width, zoom)) {
            const reach = @max(scaledValue(20, zoom), @divTrunc((port.x - origin.x) * 55, 100));
            drawRoute(hdc, .{ .from = origin, .out = .{ .x = origin.x + reach, .y = origin.y }, .in = .{ .x = port.x - reach, .y = port.y }, .to = port }, color, 1.5 * zoom, null);
        } else {
            var gap = scaledValue(40, zoom);
            for (0..node_count) |other_index| {
                const other = geometry.card(other_index);
                if (other.right < card.left and other.top < card.bottom and other.bottom > card.top)
                    gap = @min(gap, card.left - other.right);
            }
            const gutter = card.left - @max(1, @divTrunc(gap, 2));
            const corridor = card.top - scaledValue(12, zoom);
            const corner = @min(scaledValue(10, zoom), @max(1, @divTrunc(gap, 2)));
            const sign: i32 = if (corridor < origin.y) -1 else 1;
            const a = Connector{ .x = origin.x, .y = corridor - sign * corner };
            const b = Connector{ .x = origin.x + corner, .y = corridor };
            const d = Connector{ .x = gutter - corner, .y = corridor };
            const e = Connector{ .x = gutter, .y = corridor + corner };
            const f = Connector{ .x = gutter, .y = port.y - corner };
            const g = Connector{ .x = gutter + corner, .y = port.y };
            const turns = [_]CubicRoute{
                .{ .from = origin, .out = origin, .in = a, .to = a },
                .{ .from = a, .out = .{ .x = origin.x, .y = corridor }, .in = .{ .x = origin.x, .y = corridor }, .to = b },
                .{ .from = b, .out = b, .in = d, .to = d },
                .{ .from = d, .out = .{ .x = gutter, .y = corridor }, .in = .{ .x = gutter, .y = corridor }, .to = e },
                .{ .from = e, .out = e, .in = f, .to = f },
                .{ .from = f, .out = .{ .x = gutter, .y = port.y }, .in = .{ .x = gutter, .y = port.y }, .to = g },
                .{ .from = g, .out = g, .in = port, .to = port },
            };
            for (turns) |turn| drawRoute(hdc, turn, color, 1.5 * zoom, null);
        }
    }
    drawGraphDot(hdc, origin, scaledValue(12, zoom), color, Tokens.canvas_tone, 2 * zoom);
    drawTextRect(hdc, allocator, "ENTRY", rect(origin.x - scaledValue(15, zoom), origin.y + scaledValue(8, zoom), origin.x + scaledValue(15, zoom), origin.y + scaledValue(23, zoom)), scaledValue(9, zoom), blendCardColor(0x00FFFFFF, Tokens.canvas_tone, 42), c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
}

fn drawFolderGlyph(hdc: c.HDC, bounds: c.RECT, zoom: f32, global: bool) void {
    const x = bounds.left;
    const y = @divTrunc(bounds.top + bounds.bottom, 2);
    const color = blendCardColor(0x00FFFFFF, Tokens.canvas_tone, 50);
    if (global) {
        drawGraphDot(hdc, .{ .x = x + scaledValue(5, zoom), .y = y }, scaledValue(8, zoom), Tokens.canvas_tone, color, 1);
    } else {
        fill(hdc, rect(x, y - scaledValue(4, zoom), x + scaledValue(5, zoom), y), color);
        fill(hdc, rect(x, y - scaledValue(2, zoom), x + scaledValue(11, zoom), y + scaledValue(5, zoom)), color);
    }
}

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
    role: NodeRole,
    inspection: ?*const WorktreeStatus.Inspection,
    kept_worktrees: []const []const u8,
    state: *const CanvasState,
) void {
    const bounds = nodeBounds(index, state);
    const attention = needsAttention(node, nodes, edges);
    const selected_card = selected == index;
    const reclaim_offer = reclaimOffer(node, inspection, kept_worktrees);
    drawLoopCard(
        hdc,
        allocator,
        node,
        bounds,
        state,
        role,
        attention,
        primaryCardAction(node),
        selected_card,
        reclaim_offer,
        true,
    );
    if (state.hovered_connector == index) {
        const connector = connectorPositionForIndex(nodes, index, true, state);
        drawGraphDot(hdc, connector, scaled(14, state), 0x00302F2E, blendCardColor(0x00FFFFFF, Tokens.canvas_tone, 40), state.zoom);
        drawTextRect(hdc, allocator, "+", rect(connector.x - scaled(7, state), connector.y - scaled(7, state), connector.x + scaled(7, state), connector.y + scaled(7, state)), scaled(9, state), 0x00E6E6E6, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
    }
}

fn loopCardChrome(
    node: GraphModel.Node,
    state: *const CanvasState,
    role: NodeRole,
    attention: bool,
    selected: bool,
) GdiplusAA.LoopCardChrome {
    const stripe = loopTypeColor(node.loop_type);
    return .{
        .top = if (attention) Tokens.loop_card_attention_top else Tokens.loop_card_top,
        .bottom = if (attention) Tokens.loop_card_attention_bottom else Tokens.loop_card_bottom,
        .radius = scaled(Tokens.loop_card_radius, state),
        .stripe_width = scaled(Tokens.loop_card_stripe, state),
        .stripe = stripe,
        .stripe_alpha = if (role == .unwired) 89 else 255,
        .border = if (selected) Tokens.canvas_selection else if (attention) 0x000A9FFF else 0x00FFFFFF,
        .border_alpha = if (selected) 255 else if (attention) 140 else 23,
        .border_width = (if (selected) @as(f32, 2) else 1) * state.zoom,
        .dashed = role == .unwired and !selected,
        .halo = if (attention) 0x000A9FFF else stripe,
        .halo_opacity = if (attention) 0.45 else 0.16,
        .halo_sigma = (if (attention) @as(f32, 18) else 12) * state.zoom,
        .zoom = state.zoom,
    };
}

fn drawLoopCardShadow(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    node: GraphModel.Node,
    bounds: c.RECT,
    state: *const CanvasState,
    role: NodeRole,
    attention: bool,
    selected: bool,
) void {
    GdiplusAA.drawLoopCardShadows(hdc, allocator, bounds, loopCardChrome(node, state, role, attention, selected)) catch |err| {
        std.log.warn("Card {s} shadow unavailable: {s}", .{ node.id, @errorName(err) });
    };
}

fn drawLoopCard(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    node: GraphModel.Node,
    bounds: c.RECT,
    state: *const CanvasState,
    role: NodeRole,
    attention: bool,
    action: ?AttentionAction,
    selected: bool,
    reclaim: ?ReclaimOffer,
    show_reclaim: bool,
) void {
    GdiplusAA.drawLoopCardChrome(hdc, bounds, loopCardChrome(node, state, role, attention, selected)) catch |err| {
        std.log.warn("Card {s} chrome degraded to flat GDI fallback: {s}", .{ node.id, @errorName(err) });
        roundedControlStroke(hdc, bounds, scaled(Tokens.loop_card_radius, state),
            if (attention) Tokens.loop_card_attention_bottom else Tokens.loop_card_bottom,
            if (selected) Tokens.canvas_selection else if (attention) Tokens.loop_card_attention_border else Tokens.loop_card_border,
            if (selected) scaled(2, state) else scaled(1, state));
        fill(
            hdc,
            rect(bounds.left, bounds.top, bounds.left + scaled(Tokens.loop_card_stripe, state), bounds.bottom),
            if (role == .unwired) blendCardColor(loopTypeColor(node.loop_type), if (attention) Tokens.loop_card_attention_bottom else Tokens.loop_card_bottom, 35) else loopTypeColor(node.loop_type),
        );
    };
    drawCardBody(hdc, allocator, node, bounds, state.zoom, role, attention, action, reclaim) catch |err| {
        std.log.warn("Card {s} presentation failed: {s}", .{ node.id, @errorName(err) });
    };
    if (action) |primary_action| {
        const action_bounds = attentionActionBounds(bounds, state);
        fill(hdc, action_bounds, 0x000A9FFF);
        drawTextRect(hdc, allocator, attentionActionLabelFor(primary_action), action_bounds, scaled(9, state), 0x00241703, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
    }

    if (show_reclaim and reclaim != null) {
        const offer = reclaimOfferBounds(bounds);
        roundedControl(hdc, offer.reclaim, scaled(5, state), 0x003A3535, 0x00534F4F);
        drawCardText(hdc, allocator, "Reclaim", rect(offer.reclaim.left + scaled(9, state), offer.reclaim.top, offer.reclaim.right, offer.reclaim.bottom), 11 * state.zoom, .semibold, 0x00D7D7D7, false) catch |err| {
            std.log.warn("Reclaim label unavailable: {s}", .{@errorName(err)});
        };
        drawCardText(hdc, allocator, "Keep", offer.keep, 11 * state.zoom, .semibold, 0x00919191, false) catch |err| {
            std.log.warn("Keep label unavailable: {s}", .{@errorName(err)});
        };
    }
    if (role == .entry or role == .unwired) {
        const accent = loopTypeColor(node.loop_type);
        drawGraphDot(hdc, .{ .x = bounds.left, .y = @divTrunc(bounds.top + bounds.bottom, 2) }, scaled(10, state), if (role == .unwired) blendCardColor(accent, Tokens.canvas_tone, 40) else accent, Tokens.canvas_tone, 2 * state.zoom);
    }
}

pub fn attentionActionLabel(node: GraphModel.Node) []const u8 {
    return switch (attentionActionForNode(node)) {
        .reply => "Reply",
        .inspect => "Inspect",
        .none => "",
    };
}

pub fn attentionActionForNode(node: GraphModel.Node) AttentionAction {
    if (std.mem.eql(u8, node.state, "running") and std.mem.eql(u8, node.presence, "awaitingInput")) return .reply;
    if (std.mem.eql(u8, node.state, "blocked")) return .inspect;
    return .none;
}

fn attentionActionLabelFor(action: AttentionAction) []const u8 {
    return switch (action) {
        .reply => "Reply",
        .inspect => "Inspect",
        .none => "",
    };
}

fn primaryCardAction(node: GraphModel.Node) ?AttentionAction {
    const action = attentionActionForNode(node);
    return if (action == .none) null else action;
}

pub fn attentionActionBounds(bounds: c.RECT, state: *const CanvasState) c.RECT {
    return attentionActionBoundsForZoom(bounds, state.zoom);
}

fn attentionActionBoundsForZoom(bounds: c.RECT, zoom: f32) c.RECT {
    return rect(bounds.right - scaledValue(77, zoom), bounds.top + scaledValue(51, zoom), bounds.right - scaledValue(11, zoom), bounds.top + scaledValue(68, zoom));
}

pub fn attentionActionVisible(node: GraphModel.Node, nodes: []const GraphModel.Node, edges: []const GraphModel.Edge) bool {
    _ = nodes;
    _ = edges;
    return attentionActionForNode(node) != .none;
}

pub fn hitTestAttentionAction(
    nodes: []const GraphModel.Node,
    edges: []const GraphModel.Edge,
    x: i32,
    y: i32,
    state: *const CanvasState,
) ?usize {
    var index = nodes.len;
    while (index > 0) {
        index -= 1;
        if (!attentionActionVisible(nodes[index], nodes, edges)) continue;
        if (insideGraph(x, y, attentionActionBounds(nodeBounds(index, state), state))) return index;
    }
    return null;
}

const ReclaimOfferBounds = struct { reclaim: c.RECT, keep: c.RECT };

pub fn reclaimOfferBounds(bounds: c.RECT) ReclaimOfferBounds {
    const zoom = @as(f32, @floatFromInt(bounds.right - bounds.left)) / @as(f32, @floatFromInt(Tokens.loop_card_width));
    return .{
        .reclaim = rect(bounds.left + scaledValue(11, zoom), bounds.top + scaledValue(51, zoom), bounds.left + scaledValue(77, zoom), bounds.top + scaledValue(72, zoom)),
        .keep = rect(bounds.left + scaledValue(84, zoom), bounds.top + scaledValue(51, zoom), bounds.left + scaledValue(120, zoom), bounds.top + scaledValue(72, zoom)),
    };
}

pub fn hasReclaimOffer(
    node: GraphModel.Node,
    inspection: ?*const WorktreeStatus.Inspection,
    kept_worktrees: []const []const u8,
) bool {
    return reclaimOffer(node, inspection, kept_worktrees) != null;
}

const ReclaimOffer = struct {
    default_branch: []const u8,
    size_bytes: ?u64 = null,
};

fn cardIsResolved(node: GraphModel.Node) bool {
    return std.mem.eql(u8, node.state, "succeeded") or std.mem.eql(u8, node.state, "failed") or
        std.mem.eql(u8, node.state, "stalled") or std.mem.eql(u8, node.state, "stopped");
}

fn reclaimOffer(
    node: GraphModel.Node,
    inspection: ?*const WorktreeStatus.Inspection,
    kept_worktrees: []const []const u8,
) ?ReclaimOffer {
    if (!cardIsResolved(node) or node.worktree_path.len == 0) return null;
    for (kept_worktrees) |path| if (std.mem.eql(u8, path, node.worktree_path)) return null;
    const value = inspection orelse return null;
    for (value.entries.items) |entry| {
        if (std.mem.eql(u8, entry.path, node.worktree_path)) {
            if (WorktreeStatus.decision(entry) != .reclaimable) return null;
            return .{
                .default_branch = if (std.mem.startsWith(u8, value.default_branch, "refs/remotes/origin/"))
                    value.default_branch["refs/remotes/origin/".len..]
                else if (std.mem.startsWith(u8, value.default_branch, "origin/"))
                    value.default_branch["origin/".len..]
                else
                    value.default_branch,
                .size_bytes = if (entry.sizeCoverage().complete) entry.size_bytes else null,
            };
        }
    }
    return null;
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
    if (cardHasText(node.activity)) return node.activity;
    if (std.mem.eql(u8, node.loop_type, "goalBased")) return node.goal_summary;
    if (std.mem.eql(u8, node.loop_type, "timeBased")) return node.trigger_prompt;
    if (std.mem.eql(u8, node.loop_type, "turnBased")) return node.check_description;
    if (std.mem.eql(u8, node.loop_type, "composite") or std.mem.eql(u8, node.loop_type, "proactive")) return node.pilot_state;
    return node.first_instruction;
}

fn cardWhitespace(cp: u21) bool {
    return cp == ' ' or (cp >= 9 and cp <= 13) or cp == 0x85 or cp == 0xa0 or cp == 0x1680 or
        (cp >= 0x2000 and cp <= 0x200a) or cp == 0x2028 or cp == 0x2029 or cp == 0x202f or cp == 0x205f or cp == 0x3000;
}

fn cardHasText(text: []const u8) bool {
    // Keep malformed activity selected so cardLiveLine reports the UTF-8 error.
    var iterator = (std.unicode.Utf8View.init(text) catch return true).iterator();
    while (iterator.nextCodepoint()) |cp| {
        if (!cardWhitespace(cp)) return true;
    }
    return false;
}

pub fn cardLiveLine(allocator: std.mem.Allocator, node: GraphModel.Node) ![]u8 {
    if (cardIsResolved(node)) {
        if (node.resolution) |resolution| {
            if (std.mem.eql(u8, node.presence, "busy") and cardHasText(node.activity))
                return collapsedCardLine(allocator, node.activity);
            return resolutionLine(allocator, resolution, false);
        }
    } else if (node.pending_completion) |pending| {
        return resolutionLine(allocator, pending, true);
    }
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    const has_activity = cardHasText(node.activity);
    if (!has_activity and
        (std.mem.eql(u8, node.loop_type, "composite") or std.mem.eql(u8, node.loop_type, "proactive")))
    {
        const pilot = cardPilotName(node.pilot_state);
        if (node.subgraph_json.len == 0) return allocator.dupe(u8, pilot);
        const count = GraphModel.subgraphNodeCount(node.subgraph_json);
        try result.writer().print("{d} {s} · {s}", .{ count, if (count == 1) "loop" else "loops", pilot });
        return result.toOwnedSlice();
    }
    const source = nodePrimaryDetail(node);
    if (has_activity and node.metric_passes != 0)
        try result.writer().print("pass {d} · ", .{node.metric_passes});
    try appendCollapsedCardLine(&result, source);
    return result.toOwnedSlice();
}

fn collapsedCardLine(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    try appendCollapsedCardLine(&result, source);
    return result.toOwnedSlice();
}

fn appendCollapsedCardLine(result: *std.array_list.Managed(u8), source: []const u8) !void {
    var iterator = (try std.unicode.Utf8View.init(source)).iterator();
    var pending_space = false;
    while (iterator.nextCodepointSlice()) |bytes| {
        const cp = try std.unicode.utf8Decode(bytes);
        if (cardWhitespace(cp)) {
            pending_space = result.items.len != 0;
        } else {
            if (pending_space and result.items.len != 0 and result.items[result.items.len - 1] != ' ') try result.append(' ');
            try result.appendSlice(bytes);
            pending_space = false;
        }
    }
}

fn resolutionLine(allocator: std.mem.Allocator, resolution: GraphModel.LoopResolution, pending: bool) ![]u8 {
    const phrase = switch (resolution.basis) {
        .predicate => "predicate passed",
        .nativeGoal => "goal met",
        .agentReported => "reported done",
        .human => "marked done",
        .sessionExited => "session exited",
        .workers => "workers rolled up",
    };
    var text = std.array_list.Managed(u8).init(allocator);
    defer text.deinit();
    try text.appendSlice(phrase);
    if (resolution.detail) |detail| if (detail.len != 0) {
        try text.appendSlice(" · ");
        try text.appendSlice(detail);
    };
    if (pending) try text.appendSlice(" · waiting on the loops it created");
    return collapsedCardLine(allocator, text.items);
}

fn reclaimLine(allocator: std.mem.Allocator, offer: ReclaimOffer) ![]u8 {
    var text = std.array_list.Managed(u8).init(allocator);
    errdefer text.deinit();
    try text.writer().print("landed in {s} · ", .{offer.default_branch});
    if (offer.size_bytes) |bytes| {
        if (bytes > 0) {
            try writeReclaimFileSize(text.writer(), bytes);
            try text.appendSlice(" left behind");
            return text.toOwnedSlice();
        }
    }
    try text.appendSlice("worktree left behind");
    return text.toOwnedSlice();
}

fn writeReclaimFileSize(writer: anytype, bytes: u64) !void {
    if (bytes > std.math.maxInt(i64)) return error.ReclaimSizeOverflow;
    // Match ByteCountFormatter's .file decimal units and adaptive, unpadded precision.
    const units = [_][]const u8{ "bytes", "KB", "MB", "GB", "TB", "PB", "EB" };
    var unit: usize = 0;
    var divisor: u64 = 1;
    while (unit + 1 < units.len and bytes / divisor >= 1000) {
        divisor *= 1000;
        unit += 1;
    }
    const precision: u64 = if (unit < 2) 1 else if (unit == 2) 10 else 100;
    const scaled_bytes = @as(u128, bytes) * precision;
    var rounded = scaled_bytes / divisor;
    const remainder = scaled_bytes % divisor;
    if (remainder * 2 > divisor or (remainder * 2 == divisor and rounded % 2 != 0)) rounded += 1;
    const whole = rounded / precision;
    if (whole >= 1000) {
        try writer.print("{d},{d:0>3}", .{ whole / 1000, whole % 1000 });
    } else try writer.print("{d}", .{whole});
    const fraction = rounded % precision;
    if (fraction != 0) {
        if (precision == 100 and fraction % 10 != 0) {
            try writer.print(".{d:0>2}", .{fraction});
        } else try writer.print(".{d}", .{if (precision == 100) fraction / 10 else fraction});
    }
    try writer.print(" {s}", .{if (bytes == 1) "byte" else units[unit]});
}

test "loop outcome live line renders decoded Main STOPPED and Goal DONE evidence" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"event":{"graphChanged":{"project":{"path":"A"},"nodes":[{"id":"main","loopType":"sketch","state":"stopped","firstInstruction":"old instruction","resolution":{"basis":"sessionExited","detail":"exit 0","resolvedAt":813000000.25}},{"id":"goal","loopType":"goalBased","state":"succeeded","goal":{"summary":"old goal"},"resolution":{"basis":"predicate","detail":"exit 0","resolvedAt":813000001}}],"edges":[]}}}
    );
    for (model.graph.?.nodes.items, [_][]const u8{ "session exited · exit 0", "predicate passed · exit 0" }) |node, expected| {
        const line = try cardLiveLine(std.testing.allocator, node);
        defer std.testing.allocator.free(line);
        try std.testing.expectEqualStrings(expected, line);
    }
}

test "loop outcome Main STOPPED receives the same safe reclaim offer as Goal DONE" {
    var inspection = WorktreeStatus.Inspection{
        .entries = std.array_list.Managed(WorktreeStatus.Entry).init(std.testing.allocator),
        .default_branch = @constCast("main"),
        .project_path = @constCast("A"),
    };
    defer inspection.entries.deinit();
    try inspection.entries.append(.{ .path = @constCast("tree"), .branch = @constCast("topic"), .pushed = true, .landed = true, .size_bytes = 312_000_000, .size_complete = true });
    const node = GraphModel.Node{ .id = @constCast("main"), .title = @constCast("Main"), .loop_type = @constCast("sketch"), .state = @constCast("stopped"), .activity = &.{}, .presence = &.{}, .worktree_path = @constCast("tree") };
    try std.testing.expect(hasReclaimOffer(node, &inspection, &.{}));
}

test "loop outcome live line follows Mac basis pending completion and active followup precedence" {
    var node = GraphModel.Node{
        .id = @constCast("loop"),
        .title = @constCast("Loop"),
        .loop_type = @constCast("goalBased"),
        .state = @constCast("succeeded"),
        .activity = @constCast("old activity"),
        .presence = &.{},
        .goal_summary = @constCast("old goal"),
        .metric_passes = 4,
    };
    for (std.enums.values(GraphModel.LoopResolution.Basis), [_][]const u8{
        "predicate passed", "goal met", "reported done", "marked done", "session exited", "workers rolled up",
    }) |basis, phrase| {
        node.resolution = .{ .basis = basis, .resolved_at = 1 };
        const line = try cardLiveLine(std.testing.allocator, node);
        defer std.testing.allocator.free(line);
        try std.testing.expectEqualStrings(phrase, line);
    }
    node.resolution = .{ .basis = .human, .detail = @constCast(" \u{96ea}\n  done "), .resolved_at = 1 };
    const detailed = try cardLiveLine(std.testing.allocator, node);
    defer std.testing.allocator.free(detailed);
    try std.testing.expectEqualStrings("marked done · \u{96ea} done", detailed);
    node.presence = @constCast("busy");
    node.activity = @constCast(" reading\n GraphStore.swift ");
    const followup = try cardLiveLine(std.testing.allocator, node);
    defer std.testing.allocator.free(followup);
    try std.testing.expectEqualStrings("reading GraphStore.swift", followup);
    node.activity = @constCast(" \n");
    const no_activity = try cardLiveLine(std.testing.allocator, node);
    defer std.testing.allocator.free(no_activity);
    try std.testing.expectEqualStrings("marked done · \u{96ea} done", no_activity);
    node.state = @constCast("running");
    node.pending_completion = .{ .basis = .agentReported, .detail = @constCast("all green"), .resolved_at = 2 };
    const pending = try cardLiveLine(std.testing.allocator, node);
    defer std.testing.allocator.free(pending);
    try std.testing.expectEqualStrings("reported done · all green · waiting on the loops it created", pending);
    node.pending_completion = null;
    node.resolution = null;
    node.activity = @constCast("still working");
    const unchanged = try cardLiveLine(std.testing.allocator, node);
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings("pass 4 · still working", unchanged);
}

test "loop outcome reclaim keeps all safety gates and complete inspection facts" {
    var inspection = WorktreeStatus.Inspection{
        .entries = std.array_list.Managed(WorktreeStatus.Entry).init(std.testing.allocator),
        .default_branch = @constCast("release"),
        .project_path = @constCast("A"),
    };
    defer inspection.entries.deinit();
    const safe = WorktreeStatus.Entry{ .path = @constCast("tree"), .branch = @constCast("topic"), .pushed = true, .landed = true, .size_bytes = 312_000_000, .size_complete = true };
    try inspection.entries.append(safe);
    var node = GraphModel.Node{
        .id = @constCast("loop"),
        .title = @constCast("Loop"),
        .loop_type = @constCast("sketch"),
        .state = @constCast("stopped"),
        .activity = &.{},
        .presence = &.{},
        .worktree_path = @constCast("tree"),
    };
    for ([_][]const u8{ "succeeded", "failed", "stalled", "stopped" }) |state| {
        node.state = @constCast(state);
        const offer = reclaimOffer(node, &inspection, &.{}).?;
        try std.testing.expectEqualStrings("release", offer.default_branch);
        try std.testing.expectEqual(@as(?u64, 312_000_000), offer.size_bytes);
        try std.testing.expect(!hasReclaimOffer(node, &inspection, &.{"tree"}));
        try std.testing.expect(!hasReclaimOffer(node, null, &.{}));
        inline for (.{ "primary", "locked", "prunable", "dirty", "untracked", "conflicted", "bound_running" }) |flag| {
            inspection.entries.items[0] = safe;
            @field(inspection.entries.items[0], flag) = true;
            try std.testing.expect(!hasReclaimOffer(node, &inspection, &.{}));
        }
        inline for (.{ "pushed", "landed" }) |flag| {
            inspection.entries.items[0] = safe;
            @field(inspection.entries.items[0], flag) = false;
            try std.testing.expect(!hasReclaimOffer(node, &inspection, &.{}));
        }
        inspection.entries.items[0] = safe;
        inspection.entries.items[0].size_complete = false;
        try std.testing.expect(reclaimOffer(node, &inspection, &.{}).?.size_bytes == null);
        inspection.entries.items[0] = safe;
        inspection.entries.items[0].size_error = error.AccessDenied;
        try std.testing.expect(reclaimOffer(node, &inspection, &.{}).?.size_bytes == null);
        inspection.entries.items[0] = safe;
    }
    for ([_][]const u8{ "idle", "running", "awaitingInput", "blocked", "waiting" }) |state| {
        node.state = @constCast(state);
        try std.testing.expect(!hasReclaimOffer(node, &inspection, &.{}));
    }
    node.state = @constCast("stopped");
    node.worktree_path = @constCast("other");
    try std.testing.expect(!hasReclaimOffer(node, &inspection, &.{}));
    node.worktree_path = @constCast("tree");
    for ([_][]const u8{ "release", "origin/release", "refs/remotes/origin/release" }) |branch| {
        inspection.default_branch = @constCast(branch);
        try std.testing.expectEqualStrings("release", reclaimOffer(node, &inspection, &.{}).?.default_branch);
    }
}

test "loop outcome reclaim sentence matches file sizes without binary units or invented bytes" {
    for ([_]struct { bytes: ?u64, expected: []const u8 }{
        .{ .bytes = null, .expected = "worktree left behind" },
        .{ .bytes = 0, .expected = "worktree left behind" },
        .{ .bytes = 1, .expected = "1 byte left behind" },
        .{ .bytes = 999, .expected = "999 bytes left behind" },
        .{ .bytes = 1_000, .expected = "1 KB left behind" },
        .{ .bytes = 1_234_567, .expected = "1.2 MB left behind" },
        .{ .bytes = 312_000_000, .expected = "312 MB left behind" },
        .{ .bytes = 1_230_000_000, .expected = "1.23 GB left behind" },
        .{ .bytes = 1_200_000_000, .expected = "1.2 GB left behind" },
        .{ .bytes = 999_999, .expected = "1,000 KB left behind" },
    }) |sample| {
        const expected = try std.fmt.allocPrint(std.testing.allocator, "landed in release · {s}", .{sample.expected});
        defer std.testing.allocator.free(expected);
        const line = try reclaimLine(std.testing.allocator, .{ .default_branch = "release", .size_bytes = sample.bytes });
        defer std.testing.allocator.free(line);
        try std.testing.expectEqualStrings(expected, line);
    }
    try std.testing.expectError(error.ReclaimSizeOverflow, reclaimLine(std.testing.allocator, .{ .default_branch = "main", .size_bytes = std.math.maxInt(u64) }));
}

test "loop outcome copy partial allocation failures and invalid Unicode propagate" {
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var node = GraphModel.Node{
                .id = @constCast("loop"),
                .title = @constCast("Loop"),
                .loop_type = @constCast("goalBased"),
                .state = @constCast("succeeded"),
                .activity = &.{},
                .presence = &.{},
                .resolution = .{ .basis = .workers, .detail = @constCast("3 of 3 \u{96ea}"), .resolved_at = 1 },
            };
            const resolved = try cardLiveLine(allocator, node);
            defer allocator.free(resolved);
            node.state = @constCast("running");
            node.pending_completion = node.resolution;
            const pending = try cardLiveLine(allocator, node);
            defer allocator.free(pending);
            const reclaim = try reclaimLine(allocator, .{ .default_branch = "main", .size_bytes = 312_000_000 });
            defer allocator.free(reclaim);
            try std.testing.expectEqualStrings("workers rolled up · 3 of 3 \u{96ea}", resolved);
            try std.testing.expectEqualStrings("landed in main · 312 MB left behind", reclaim);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
    try std.testing.expectError(error.InvalidUtf8, resolutionLine(std.testing.allocator, .{ .basis = .human, .detail = @constCast("\xff"), .resolved_at = 1 }, false));
}

test "loop outcome production paint uses outcome and reclaim text in the existing live row" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"A"},"nodes":[{"id":"main","title":"Main","loopType":"sketch","state":"stopped","resolution":{"basis":"sessionExited","detail":"exit 0","resolvedAt":813000000}},{"id":"goal","title":"Goal","loopType":"goalBased","state":"succeeded","resolution":{"basis":"nativeGoal","resolvedAt":813000001}}],"edges":[]}}
    );
    for (model.graph.?.nodes.items, [_][]const u8{ "session exited · exit 0", "goal met" }) |node, expected| {
        for ([_]?ReclaimOffer{ null, .{ .default_branch = "main", .size_bytes = 312_000_000 } }) |offer| {
            const actual = try ParityDib.init(400, 140);
            defer actual.deinit();
            const reference = try ParityDib.init(400, 140);
            defer reference.deinit();
            const bounds = rect(20, 20, 380, 120);
            fill(actual.dc, rect(0, 0, 400, 140), Tokens.loop_card_bottom);
            fill(reference.dc, rect(0, 0, 400, 140), Tokens.loop_card_bottom);
            try drawCardBody(actual.dc, allocator, node, bounds, 1, .entry, false, null, offer);
            const old = try selectCardFont(actual.dc, 10, .card_state);
            const pill_width = (try measuredText(actual.dc, allocator, cardState(node).word)) + 22;
            _ = c.SelectObject(actual.dc, old);
            const live_bounds = cardTextLayout(bounds, 1, pill_width).live;
            try drawCardText(reference.dc, allocator, if (offer != null) "landed in main · 312 MB left behind" else expected, live_bounds, 10.5, .card_mono, 0x009F9C9C, true);
            try std.testing.expect(actual.count(live_bounds, 0x009F9C9C) > 0);
            var y = live_bounds.top;
            while (y < live_bounds.bottom) : (y += 1) {
                var x = live_bounds.left;
                while (x < live_bounds.right) : (x += 1)
                    try std.testing.expectEqual(c.GetPixel(reference.dc, x, y), c.GetPixel(actual.dc, x, y));
            }
        }
    }
}

const outcomePaintFrame =
    \\{"graphChanged":{"project":{"path":"A","name":"Outcome fixture"},"nodes":[{"id":"main","title":"Main","loopType":"sketch","state":"stopped","worktreeBinding":{"path":"main-tree","branch":"loop/main"},"resolution":{"basis":"sessionExited","detail":"exit 0","resolvedAt":813000000}},{"id":"goal","title":"Goal","loopType":"goalBased","state":"succeeded","goal":{"summary":"the suite is green"},"worktreeBinding":{"path":"goal-tree","branch":"loop/goal"},"resolution":{"basis":"nativeGoal","detail":"the suite is green","resolvedAt":813000001}}],"edges":[]}}
;

test "paint export: loop-outcomes" {
    const allocator = std.testing.allocator;
    const root = std.process.getEnvVarOwned(allocator, "GRAPHCODE_PAINT_EXPORT_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(root);
    if (root.len == 0) return error.PaintExportDirectoryEmpty;
    const commit = try std.process.getEnvVarOwned(allocator, "GRAPHCODE_PAINT_SOURCE_COMMIT");
    defer allocator.free(commit);
    if (commit.len != 40) return error.PaintExportSourceCommitInvalid;
    for (commit) |character| if (!std.ascii.isHex(character)) return error.PaintExportSourceCommitInvalid;
    var directory = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer directory.close();
    var iterator = directory.iterate();
    if (try iterator.next() != null) return error.PaintExportRootNotEmpty;
    try chrome764Native();
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(outcomePaintFrame);
    var inspection = WorktreeStatus.Inspection{
        .entries = std.array_list.Managed(WorktreeStatus.Entry).init(allocator),
        .default_branch = @constCast("main"),
        .project_path = @constCast("A"),
    };
    defer inspection.entries.deinit();
    for ([_][]const u8{ "main-tree", "goal-tree" }) |path|
        try inspection.entries.append(.{ .path = @constCast(path), .branch = @constCast("topic"), .pushed = true, .landed = true, .size_bytes = 312_000_000, .size_complete = true });
    var receipt = std.array_list.Managed(u8).init(allocator);
    defer receipt.deinit();
    var fixture_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(outcomePaintFrame, &fixture_hash, .{});
    try receipt.writer().print(
        "{{\"evidenceClass\":\"offscreen production card paint only\",\"sourceCommit\":\"{s}\",\"fixtureSha256\":\"{x}\",\"logicalDpi\":96,\"width\":640,\"height\":240,\"zoom\":1,\"role\":\"entry\",\"selected\":false,\"attention\":false,\"scenes\":[",
        .{ commit, &fixture_hash },
    );
    const scenes = [_]struct { name: []const u8, node: usize, reclaim: bool }{
        .{ .name = "main-stopped-resolution", .node = 0, .reclaim = false },
        .{ .name = "main-stopped-reclaim", .node = 0, .reclaim = true },
        .{ .name = "goal-done-resolution", .node = 1, .reclaim = false },
        .{ .name = "goal-done-reclaim", .node = 1, .reclaim = true },
    };
    for (scenes, 0..) |scene, index| {
        var first_rgb: [32]u8 = undefined;
        const node = model.graph.?.nodes.items[scene.node];
        const offer = if (scene.reclaim) reclaimOffer(node, &inspection, &.{}) else null;
        for (0..3) |repeat| {
            const dib = try ParityDib.init(640, 240);
            defer dib.deinit();
            fill(dib.dc, rect(0, 0, 640, 240), Tokens.canvas_tone);
            const bounds = rect(180, 70, 180 + Tokens.loop_card_width, 70 + Tokens.loop_card_height);
            drawLoopCardShadow(dib.dc, allocator, node, bounds, &.{}, .entry, false, false);
            drawLoopCard(dib.dc, allocator, node, bounds, &.{}, .entry, false, null, false, offer, true);
            const rgb = try dib.rgbSha256(allocator);
            if (repeat == 0) first_rgb = rgb else try std.testing.expectEqualSlices(u8, &first_rgb, &rgb);
            const name = try std.fmt.allocPrint(allocator, "{s}-{d}.bmp", .{ scene.name, repeat + 1 });
            defer allocator.free(name);
            const path = try std.fs.path.join(allocator, &.{ root, name });
            defer allocator.free(path);
            const digest = try dib.writeBmp(allocator, path);
            if (repeat == 0) {
                if (index != 0) try receipt.append(',');
                try receipt.writer().print("{{\"scene\":\"{s}\",\"nodeId\":\"{s}\",\"state\":\"{s}\",\"file\":\"{s}\",\"repeats\":3,\"bmpSha256\":\"{x}\",\"rgbSha256\":\"{x}\"}}", .{ scene.name, node.id, node.state, name, &digest, &rgb });
            }
        }
    }
    try receipt.appendSlice("]}\n");
    var file = try directory.createFile("loop-outcomes-receipt.json", .{ .exclusive = true });
    defer file.close();
    try file.writeAll(receipt.items);
    var fixture_file = try directory.createFile("loop-outcomes-frame.json", .{ .exclusive = true });
    defer fixture_file.close();
    try fixture_file.writeAll(outcomePaintFrame);
    std.debug.print("loop outcome export: 4 scenes x 3 repeats, matching RGB hashes; production decoder/card paint; no desktop capture\n", .{});
}

fn cardPilotName(pilot: []const u8) []const u8 {
    if (std.mem.eql(u8, pilot, "notPiloted")) return "Not piloted";
    if (std.mem.eql(u8, pilot, "piloting")) return "Piloting";
    if (std.mem.eql(u8, pilot, "piloted")) return "Piloted";
    if (std.mem.eql(u8, pilot, "armed")) return "Armed";
    return pilot;
}

fn cardTypeName(loop_type: []const u8) []const u8 {
    if (std.mem.eql(u8, loop_type, "goalBased")) return "Goal";
    if (std.mem.eql(u8, loop_type, "timeBased")) return "Timed";
    if (std.mem.eql(u8, loop_type, "turnBased")) return "Turn";
    if (std.mem.eql(u8, loop_type, "composite") or std.mem.eql(u8, loop_type, "proactive")) return "Composite";
    return "Main";
}

fn cardBackendName(backend: []const u8) []const u8 {
    if (std.mem.eql(u8, backend, "claudeCode") or backend.len == 0) return "";
    if (std.mem.eql(u8, backend, "copilotCLI")) return "Copilot CLI";
    if (std.mem.eql(u8, backend, "codex")) return "Codex";
    if (std.mem.eql(u8, backend, "openCode")) return "OpenCode";
    if (std.mem.eql(u8, backend, "pi")) return "Pi";
    if (std.mem.eql(u8, backend, "nod")) return "Nod";
    return backend;
}

fn writeCardAge(writer: anytype, seconds: u64) !void {
    const days = seconds / 86400;
    const hours = seconds / 3600 % 24;
    const minutes = seconds / 60 % 60;
    if (days > 0) {
        try writer.print("{d}d", .{days});
        if (hours > 0) try writer.print(" {d}h", .{hours});
    } else if (hours > 0) {
        try writer.print("{d}h", .{hours});
        if (minutes > 0) try writer.print(" {d}m", .{minutes});
    } else if (minutes > 0) {
        try writer.print("{d}m", .{minutes});
    } else try writer.print("{d}s", .{seconds});
}

fn nodeMetadata(allocator: std.mem.Allocator, node: GraphModel.Node, branch: []const u8, now: u64) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    const writer = result.writer();
    try writer.writeAll(cardTypeName(node.loop_type));
    if (branch.len != 0) try writer.print(" · {s}", .{branch});
    const backend = cardBackendName(node.backend);
    if (backend.len != 0) try writer.print(" · {s}", .{backend});
    if (node.created_at) |created| {
        try writer.writeAll(" · ");
        try writeCardAge(writer, now -| created);
    }
    return result.toOwnedSlice();
}

fn writeMetricChange(writer: anytype, node: GraphModel.Node) !void {
    try writeMetricReadings(writer, node);
    try writer.writeAll(" · ");
    try writeMetricChangeLabel(writer, cardMetricRatio(node));
}

fn writeMetricReadings(writer: anytype, node: GraphModel.Node) !void {
    const first = node.metric_samples[0];
    const last = node.metric_samples[@as(usize, node.metric_sample_count) - 1];
    if (!std.math.isFinite(first) or !std.math.isFinite(last)) return error.InvalidCardMetric;
    const whole = first == @round(first) and last == @round(last);
    if (whole) try writeMetricNumber(writer, first) else try writer.print("{d:.2}", .{first});
    try writer.writeAll(" → ");
    if (whole) try writeMetricNumber(writer, last) else try writer.print("{d:.2}", .{last});
}

fn writeMetricChangeLabel(writer: anytype, ratio: f64) !void {
    const percent: u32 = @intFromFloat(@round(@abs(ratio) * 100));
    if (percent == 0) try writer.writeAll("flat") else try writer.print("{d}% {s}", .{ percent, if (ratio > 0) "better" else "worse" });
}

fn cardMetricRatio(node: GraphModel.Node) f64 {
    const first = node.metric_samples[0];
    const last = node.metric_samples[@as(usize, node.metric_sample_count) - 1];
    const scale = @max(@abs(first), @abs(last));
    if (scale == 0) return 0;
    return if (std.mem.eql(u8, node.metric_direction, "minimize")) first / scale - last / scale else last / scale - first / scale;
}

fn writeMetricNumber(writer: anytype, value: f64) !void {
    if (@abs(value) < 1_000_000_000 and value == @round(value))
        return writer.print("{d}", .{@as(i64, @intFromFloat(value))});
    return writer.print("{d:.2}", .{value});
}

fn formatTokenUsage(writer: anytype, tokens: u32) !void {
    if (tokens >= 1_000_000) return writer.print("{d}M tok", .{tokens / 1_000_000});
    if (tokens >= 1000) return writer.print("{d}k tok", .{tokens / 1000});
    return writer.print("{d} tok", .{tokens});
}

const CardState = struct {
    word: []const u8,
    tint: u32,
    ink: u32,
    fill: u32,
    hollow: bool = false,
    stroke: ?u32 = null,
};

fn blendCardColor(foreground: u32, background: u32, opacity: u32) u32 {
    var result: u32 = 0;
    inline for ([_]u5{ 0, 8, 16 }) |shift| {
        const front = (foreground >> shift) & 255;
        const back = (background >> shift) & 255;
        result |= ((front * opacity + back * (100 - opacity) + 50) / 100) << shift;
    }
    return result;
}

fn cardState(node: GraphModel.Node) CardState {
    const state = if (std.mem.eql(u8, node.presence, "awaitingInput"))
        "awaitingInput"
    else if (std.mem.eql(u8, node.presence, "busy"))
        "running"
    else if (std.mem.eql(u8, node.state, "running") and std.mem.eql(u8, node.presence, "idle"))
        "idle"
    else
        node.state;
    const base = Tokens.loop_card_bottom;
    if (std.mem.eql(u8, state, "running") or std.mem.eql(u8, state, "waiting")) return .{
        .word = if (std.mem.eql(u8, state, "waiting")) "WAITING" else "RUNNING",
        .tint = 0x00FF840A,
        .ink = 0x00FFC58C,
        .fill = blendCardColor(0x00FF840A, base, if (std.mem.eql(u8, state, "waiting")) 10 else 16),
        .hollow = std.mem.eql(u8, state, "waiting"),
    };
    if (std.mem.eql(u8, state, "awaitingInput") or std.mem.eql(u8, state, "blocked")) return .{
        .word = if (std.mem.eql(u8, state, "blocked")) "BLOCKED" else "NEEDS YOU",
        .tint = 0x000A9FFF,
        .ink = 0x007ACDFF,
        .fill = blendCardColor(0x000A9FFF, base, if (std.mem.eql(u8, state, "blocked")) 14 else 22),
        .hollow = std.mem.eql(u8, state, "blocked"),
        .stroke = if (std.mem.eql(u8, state, "blocked")) blendCardColor(0x000A9FFF, base, 40) else null,
    };
    if (std.mem.eql(u8, state, "succeeded")) return .{ .word = "DONE", .tint = 0x0058D130, .ink = 0x009BE47E, .fill = blendCardColor(0x0058D130, base, 16) };
    if (std.mem.eql(u8, state, "failed")) return .{ .word = "FAILED", .tint = 0x003A45FF, .ink = 0x00808AFF, .fill = blendCardColor(0x003A45FF, base, 16) };
    if (std.mem.eql(u8, state, "stalled")) return .{ .word = "STALLED", .tint = 0x00F25ABF, .ink = 0x00F7A2D9, .fill = blendCardColor(0x00F25ABF, base, 16) };
    const neutral_fill = blendCardColor(0x00FFFFFF, base, 7);
    return .{
        .word = if (std.mem.eql(u8, state, "stopped")) "STOPPED" else if (std.mem.eql(u8, node.loop_type, "timeBased")) "SCHEDULED" else "IDLE",
        .tint = blendCardColor(0x00FFFFFF, neutral_fill, 35),
        .ink = blendCardColor(0x00FFFFFF, neutral_fill, 50),
        .fill = neutral_fill,
        .hollow = std.mem.eql(u8, state, "stopped"),
    };
}

fn selectCardFont(hdc: c.HDC, size: f32, style: AppFont.Style) !c.HGDIOBJ {
    const font = AppFont.getStyle(size, style) orelse return error.CardFontUnavailable;
    return c.SelectObject(hdc, font) orelse error.CardFontSelectionFailed;
}

fn measuredWide(hdc: c.HDC, text: []const u16) !i32 {
    if (text.len == 0) return 0;
    var size: c.SIZE = undefined;
    const length = std.math.cast(i32, text.len) orelse return error.CardTextTooLong;
    if (c.GetTextExtentPoint32W(hdc, text.ptr, length, &size) == 0) return error.CardTextMeasurementFailed;
    return size.cx;
}

fn measuredText(hdc: c.HDC, allocator: std.mem.Allocator, text: []const u8) !i32 {
    const wide = try std.unicode.utf8ToUtf16LeAlloc(allocator, text);
    defer allocator.free(wide);
    return measuredWide(hdc, wide);
}

fn middleElide(hdc: c.HDC, allocator: std.mem.Allocator, text: []const u16, width: i32) ![]u16 {
    if (try measuredWide(hdc, text) <= width) return allocator.dupe(u16, text);
    var boundaries = std.array_list.Managed(usize).init(allocator);
    defer boundaries.deinit();
    try boundaries.append(0);
    var index: usize = 0;
    while (index < text.len) {
        index += if (std.unicode.utf16IsHighSurrogate(text[index])) @as(usize, 2) else 1;
        try boundaries.append(index);
    }
    const count = boundaries.items.len - 1;
    if (count < 3) return error.CardMetadataTooWide;
    const scratch = try allocator.alloc(u16, text.len + 1);
    defer allocator.free(scratch);
    var low: usize = 2;
    var high: usize = count - 1;
    var best: ?usize = null;
    while (low <= high) {
        const keep = low + (high - low) / 2;
        const candidate = elidedCandidate(scratch, text, boundaries.items, keep);
        if (try measuredWide(hdc, candidate) <= width) {
            best = keep;
            low = keep + 1;
        } else high = keep - 1;
    }
    const keep = best orelse return error.CardMetadataTooWide;
    return allocator.dupe(u16, elidedCandidate(scratch, text, boundaries.items, keep));
}

fn elidedCandidate(scratch: []u16, text: []const u16, boundaries: []const usize, keep: usize) []u16 {
    const head = boundaries[(keep + 1) / 2];
    const tail = boundaries[boundaries.len - 1 - keep / 2];
    @memcpy(scratch[0..head], text[0..head]);
    scratch[head] = 0x2026;
    @memcpy(scratch[head + 1 ..][0 .. text.len - tail], text[tail..]);
    return scratch[0 .. head + 1 + text.len - tail];
}

fn cardBranchForWidth(hdc: c.HDC, allocator: std.mem.Allocator, branch: []const u16, width: i32) !?[]u16 {
    const ellipsis = [_]u16{0x2026};
    if (try measuredWide(hdc, &ellipsis) > width) return null;
    return middleElide(hdc, allocator, branch, width) catch |err| switch (err) {
        error.CardMetadataTooWide => try allocator.dupe(u16, &ellipsis),
        else => return err,
    };
}

fn cardMetaForWidth(hdc: c.HDC, allocator: std.mem.Allocator, node: GraphModel.Node, now: u64, width: i32) ![]u8 {
    const full = try nodeMetadata(allocator, node, node.worktree_branch, now);
    errdefer allocator.free(full);
    if (try measuredText(hdc, allocator, full) <= width) return full;
    const fixed = try nodeMetadata(allocator, node, "", now);
    defer allocator.free(fixed);
    const fixed_width = try measuredText(hdc, allocator, fixed);
    if (fixed_width > width or node.worktree_branch.len == 0) return error.CardMetadataTooWide;
    var branch_width = width - fixed_width - try measuredText(hdc, allocator, " · ");
    const branch = try std.unicode.utf8ToUtf16LeAlloc(allocator, node.worktree_branch);
    defer allocator.free(branch);
    while (branch_width > 0) {
        const shortened = try cardBranchForWidth(hdc, allocator, branch, branch_width) orelse break;
        defer allocator.free(shortened);
        const utf8 = try std.unicode.utf16LeToUtf8Alloc(allocator, shortened);
        defer allocator.free(utf8);
        const result = try nodeMetadata(allocator, node, utf8, now);
        errdefer allocator.free(result);
        const measured = try measuredText(hdc, allocator, result);
        if (measured <= width) {
            allocator.free(full);
            return result;
        }
        allocator.free(result);
        // A mapped DC rounds each measured run, so verify the assembled line too.
        branch_width -= @max(1, measured - width);
    }
    // Complete visual elision of the branch is preferable to clipping backend/age.
    const result = try allocator.dupe(u8, fixed);
    allocator.free(full);
    return result;
}

fn drawCardText(hdc: c.HDC, allocator: std.mem.Allocator, text: []const u8, bounds: c.RECT, size: f32, style: AppFont.Style, color: u32, ellipsis: bool) !void {
    if (text.len == 0 or bounds.right <= bounds.left) return;
    const wide = try std.unicode.utf8ToUtf16LeAlloc(allocator, text);
    defer allocator.free(wide);
    const old_font = try selectCardFont(hdc, size, style);
    defer _ = c.SelectObject(hdc, old_font);
    _ = c.SetTextColor(hdc, color);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    var target = bounds;
    const format: c.UINT = @intCast(c.DT_LEFT | c.DT_SINGLELINE | c.DT_VCENTER | c.DT_NOPREFIX | @as(c.INT, if (ellipsis) c.DT_END_ELLIPSIS else 0));
    if (c.DrawTextW(hdc, wide.ptr, std.math.cast(i32, wide.len) orelse return error.CardTextTooLong, &target, format) == 0)
        return error.CardTextPaintFailed;
}

fn cardMetricDetail(allocator: std.mem.Allocator, node: GraphModel.Node) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    if (node.metric_sample_count >= 2 and node.metric_direction.len != 0)
        try writeMetricChange(result.writer(), node);
    return result.toOwnedSlice();
}

fn drawCardPill(hdc: c.HDC, allocator: std.mem.Allocator, presentation: CardState, bounds: c.RECT, zoom: f32) !void {
    const brush = c.CreateSolidBrush(presentation.fill) orelse return error.CardBrushCreationFailed;
    defer _ = c.DeleteObject(brush);
    const pen = c.CreatePen(c.PS_SOLID, 1, presentation.stroke orelse presentation.fill) orelse return error.CardPenCreationFailed;
    defer _ = c.DeleteObject(pen);
    const old_brush = c.SelectObject(hdc, brush);
    defer _ = c.SelectObject(hdc, old_brush);
    const old_pen = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, old_pen);
    _ = c.RoundRect(hdc, bounds.left, bounds.top, bounds.right, bounds.bottom, scaledValue(10, zoom), scaledValue(10, zoom));
    const diameter = scaledValue(6, zoom);
    const dot_left = bounds.left + scaledValue(5, zoom);
    const dot_top = @divTrunc(bounds.top + bounds.bottom - diameter, 2);
    const dot = c.CreateSolidBrush(if (presentation.hollow) presentation.fill else presentation.tint) orelse return error.CardBrushCreationFailed;
    defer _ = c.DeleteObject(dot);
    const dot_pen = c.CreatePen(c.PS_SOLID, scaledValue(1, zoom), presentation.tint) orelse return error.CardPenCreationFailed;
    defer _ = c.DeleteObject(dot_pen);
    _ = c.SelectObject(hdc, dot);
    _ = c.SelectObject(hdc, dot_pen);
    _ = c.Ellipse(hdc, dot_left, dot_top, dot_left + diameter, dot_top + diameter);
    _ = c.SelectObject(hdc, brush);
    _ = c.SelectObject(hdc, pen);
    try drawCardText(hdc, allocator, presentation.word, rect(dot_left + diameter + scaledValue(4, zoom), bounds.top, bounds.right - scaledValue(7, zoom), bounds.bottom), 10 * zoom, .card_state, presentation.ink, false);
}

fn drawCardBody(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    node: GraphModel.Node,
    bounds: c.RECT,
    zoom: f32,
    role: NodeRole,
    attention: bool,
    action: ?AttentionAction,
    reclaim: ?ReclaimOffer,
) !void {
    _ = attention;
    const presentation = cardState(node);
    const pill_width = blk: {
        const old = try selectCardFont(hdc, 10 * zoom, .card_state);
        defer _ = c.SelectObject(hdc, old);
        break :blk (try measuredText(hdc, allocator, presentation.word)) + scaledValue(22, zoom);
    };
    const layout = cardTextLayout(bounds, zoom, pill_width);
    try drawCardText(hdc, allocator, node.title, layout.title, 14.5 * zoom, .card_title, 0x00F4F4F4, true);
    try drawCardPill(hdc, allocator, presentation, layout.pill, zoom);
    const live = if (reclaim) |offer| try reclaimLine(allocator, offer) else try cardLiveLine(allocator, node);
    defer allocator.free(live);
    try drawCardText(hdc, allocator, live, layout.live, 10.5 * zoom, .card_mono, 0x009F9C9C, true);
    const chip_in_detail = drawCardMetaRow(hdc, allocator, node, layout, zoom, role) catch |err| switch (err) {
        error.CardMetadataTooWide => blk: {
            std.log.warn("Card {s} fixed metadata does not fit: {s}", .{ node.id, @errorName(err) });
            try drawCardText(hdc, allocator, "Metadata unavailable", layout.meta, 10.5 * zoom, .card_mono, Tokens.dialog_error_text, true);
            break :blk false;
        },
        else => return err,
    };
    if (action == null and reclaim == null and node.metric_sample_count >= 2 and node.metric_direction.len != 0) {
        var detail_bounds = layout.detail;
        if (chip_in_detail) {
            const chip_width = try cardRoleChipWidth(hdc, allocator, role, zoom);
            detail_bounds.left += chip_width + scaledValue(4, zoom);
        }
        if (detail_bounds.right > detail_bounds.left) {
            var readings = std.array_list.Managed(u8).init(allocator);
            defer readings.deinit();
            try writeMetricReadings(readings.writer(), node);
            const ratio = cardMetricRatio(node);
            var change_buffer: [32]u8 = undefined;
            var change_stream = std.io.fixedBufferStream(&change_buffer);
            try writeMetricChangeLabel(change_stream.writer(), ratio);
            const change = change_stream.getWritten();
            const change_width = blk: {
                const old = try selectCardFont(hdc, 10.5 * zoom, .card_mono);
                defer _ = c.SelectObject(hdc, old);
                break :blk try measuredText(hdc, allocator, change);
            };
            const change_left = @max(detail_bounds.left, detail_bounds.right - change_width);
            detail_bounds.bottom -= scaledValue(4, zoom);
            try drawCardText(hdc, allocator, readings.items, rect(detail_bounds.left, detail_bounds.top, @max(detail_bounds.left, change_left - scaledValue(6, zoom)), detail_bounds.bottom), 10.5 * zoom, .card_mono, 0x009F9C9C, true);
            try drawCardText(hdc, allocator, change, rect(change_left, detail_bounds.top, detail_bounds.right, detail_bounds.bottom), 10.5 * zoom, .card_mono, 0x009F9C9C, true);
            const track = rect(detail_bounds.left, layout.detail.bottom - scaledValue(3, zoom), detail_bounds.right, layout.detail.bottom);
            fill(hdc, track, 0x00444141);
            const fraction = std.math.clamp(ratio, 0, 1);
            const end = track.left + @as(i32, @intFromFloat(@as(f64, @floatFromInt(track.right - track.left)) * fraction));
            if (end > track.left) fill(hdc, rect(track.left, track.top, end, track.bottom), loopTypeColor(node.loop_type));
        }
    }
}

const CardRoleChip = struct {
    label: []const u8,
    fill: u32,
    ink: u32,
    stroke: ?u32,
    padding: i32,
    radius: i32,
    font_size: f32,
    font_style: AppFont.Style,
};

const CardMetaPresentation = struct {
    text: []u8,
    chip_in_detail: bool,
};

fn cardRoleChip(role: NodeRole) ?CardRoleChip {
    return switch (role) {
        .entry => .{
            .label = "entry",
            .fill = blendCardColor(0x00709E19, Tokens.loop_card_bottom, 18),
            .ink = 0x00ABD36F,
            .stroke = null,
            .padding = 6,
            .radius = 4,
            .font_size = 10.5,
            .font_style = .card_state,
        },
        .cycle_only => .{
            .label = "cycle · no entry point",
            .fill = blendCardColor(0x000A9FFF, Tokens.loop_card_bottom, 12),
            .ink = blendCardColor(0x007ACDFF, Tokens.loop_card_bottom, 90),
            .stroke = blendCardColor(0x000A9FFF, Tokens.loop_card_bottom, 28),
            .padding = 6,
            .radius = 5,
            .font_size = 9.5,
            .font_style = .card_mono,
        },
        .interior, .unwired => null,
    };
}

fn cardRoleChipWidth(hdc: c.HDC, allocator: std.mem.Allocator, role: NodeRole, zoom: f32) !i32 {
    const chip = cardRoleChip(role) orelse return 0;
    const old_font = try selectCardFont(hdc, chip.font_size * zoom, chip.font_style);
    defer _ = c.SelectObject(hdc, old_font);
    return (try measuredText(hdc, allocator, chip.label)) + scaledValue(chip.padding * 2, zoom);
}

fn cardMetaPresentation(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    node: GraphModel.Node,
    layout: CardTextLayout,
    zoom: f32,
    role: NodeRole,
) !CardMetaPresentation {
    const old_font = try selectCardFont(hdc, 10.5 * zoom, .card_mono);
    defer _ = c.SelectObject(hdc, old_font);
    const full_text_bounds = rect(layout.meta.left + scaledValue(11, zoom), layout.meta.top, layout.meta.right, layout.meta.bottom);
    if (cardRoleChip(role) == null) return .{
        .text = try cardMetaForWidth(
            hdc,
            allocator,
            node,
            @intCast(@max(0, std.time.timestamp())),
            full_text_bounds.right - full_text_bounds.left,
        ),
        .chip_in_detail = false,
    };

    const chip_width = try cardRoleChipWidth(hdc, allocator, role, zoom);
    const gap = scaledValue(5, zoom);
    const reserved_bounds = rect(full_text_bounds.left, full_text_bounds.top, full_text_bounds.right - chip_width - gap, full_text_bounds.bottom);
    const now: u64 = @intCast(@max(0, std.time.timestamp()));
    const meta = cardMetaForWidth(hdc, allocator, node, now, reserved_bounds.right - reserved_bounds.left) catch |err| switch (err) {
        error.CardMetadataTooWide => return .{
            .text = try cardMetaForWidth(hdc, allocator, node, now, full_text_bounds.right - full_text_bounds.left),
            .chip_in_detail = true,
        },
        else => return err,
    };
    return .{ .text = meta, .chip_in_detail = false };
}

fn drawCardRoleChip(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    role: NodeRole,
    bounds: c.RECT,
    zoom: f32,
) !void {
    const chip = cardRoleChip(role) orelse return;
    const brush = c.CreateSolidBrush(chip.fill) orelse return error.CardBrushCreationFailed;
    defer _ = c.DeleteObject(brush);
    const pen = c.CreatePen(c.PS_SOLID, scaledValue(1, zoom), chip.stroke orelse chip.fill) orelse return error.CardPenCreationFailed;
    defer _ = c.DeleteObject(pen);
    const old_brush = c.SelectObject(hdc, brush);
    defer _ = c.SelectObject(hdc, old_brush);
    const old_pen = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, old_pen);
    _ = c.RoundRect(hdc, bounds.left, bounds.top, bounds.right, bounds.bottom, scaledValue(chip.radius * 2, zoom), scaledValue(chip.radius * 2, zoom));
    try drawCardText(
        hdc,
        allocator,
        chip.label,
        rect(bounds.left + scaledValue(chip.padding, zoom), bounds.top, bounds.right - scaledValue(chip.padding, zoom), bounds.bottom),
        chip.font_size * zoom,
        chip.font_style,
        chip.ink,
        false,
    );
}

fn drawCardMetaRow(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    node: GraphModel.Node,
    layout: CardTextLayout,
    zoom: f32,
    role: NodeRole,
) !bool {
    const square_top = @divTrunc(layout.meta.top + layout.meta.bottom - scaledValue(6, zoom), 2);
    fill(hdc, rect(layout.meta.left, square_top, layout.meta.left + scaledValue(6, zoom), square_top + scaledValue(6, zoom)), loopTypeColor(node.loop_type));
    const meta = try cardMetaPresentation(hdc, allocator, node, layout, zoom, role);
    defer allocator.free(meta.text);
    const role_chip = cardRoleChip(role);
    const text_right = if (meta.chip_in_detail or role_chip == null)
        layout.meta.right
    else blk: {
        const chip_width = try cardRoleChipWidth(hdc, allocator, role, zoom);
        break :blk layout.meta.right - chip_width - scaledValue(5, zoom);
    };
    const text_bounds = rect(layout.meta.left + scaledValue(11, zoom), layout.meta.top, text_right, layout.meta.bottom);
    try drawCardText(hdc, allocator, meta.text, text_bounds, 10.5 * zoom, .card_mono, blendCardColor(0x00FFFFFF, Tokens.loop_card_bottom, 52), false);
    if (role_chip) |_| {
        const chip_width = try cardRoleChipWidth(hdc, allocator, role, zoom);
        const chip_bounds = if (meta.chip_in_detail) blk: {
            const chip_left = layout.detail.left;
            const chip_right = chip_left + chip_width;
            const chip_height = scaledValue(14, zoom);
            const top = @divTrunc(layout.detail.top + layout.detail.bottom - chip_height, 2);
            break :blk rect(chip_left, top, chip_right, top + chip_height);
        } else blk: {
            const chip_height = scaledValue(14, zoom);
            const top = @divTrunc(layout.meta.top + layout.meta.bottom - chip_height, 2);
            break :blk rect(layout.meta.right - chip_width, top, layout.meta.right, top + chip_height);
        };
        try drawCardRoleChip(hdc, allocator, role, chip_bounds, zoom);
        return meta.chip_in_detail;
    }
    return false;
}

pub fn nodeBounds(index: usize, state: *const CanvasState) c.RECT {
    const layout = state.project_layout orelse return rect(0, 0, 0, 0);
    if (index >= layout.positions.len) return rect(0, 0, 0, 0);
    return cardBoundsAt(layout.positions[index], state.layout_bounds, state);
}

fn cardBoundsAt(point: LaneLayout.Point, bounds: c.RECT, state: *const CanvasState) c.RECT {
    const x: i32 = @intFromFloat((@as(f32, @floatFromInt(bounds.left)) + point.x - LaneLayout.MacMetrics.card_width / 2) * state.zoom + state.pan_x);
    const y: i32 = @intFromFloat((@as(f32, @floatFromInt(bounds.top)) + point.y - LaneLayout.MacMetrics.card_height / 2) * state.zoom + state.pan_y);
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

fn loopTypeColor(loop_type: []const u8) u32 {
    if (std.mem.eql(u8, loop_type, "sketch")) return 0x00E3DAD3;
    if (std.mem.eql(u8, loop_type, "goalBased")) return 0x00709E19;
    if (std.mem.eql(u8, loop_type, "timeBased")) return 0x000085C9;
    if (std.mem.eql(u8, loop_type, "turnBased")) return 0x008151D5;
    if (std.mem.eql(u8, loop_type, "composite")) return 0x00E98590;
    if (std.mem.eql(u8, loop_type, "proactive")) return 0x00C77DFF;
    if (std.mem.eql(u8, loop_type, "message")) return 0x006BD58D;
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

const NodeRole = LaneLayout.Role;

fn graphRoleTestNode(id: []const u8) GraphModel.Node {
    return .{
        .id = @constCast(id),
        .title = @constCast("Role test"),
        .loop_type = @constCast("sketch"),
        .state = @constCast("idle"),
        .activity = @constCast(""),
        .presence = @constCast("idle"),
    };
}

fn graphRoleTestEdge(from: []const u8, to: []const u8, kind: []const u8) GraphModel.Edge {
    return .{
        .from = @constCast(from),
        .to = @constCast(to),
        .kind = @constCast(kind),
        .blocks_target = !std.mem.eql(u8, kind, "message"),
    };
}

fn resolveCardRoles(
    allocator: std.mem.Allocator,
    nodes: []const GraphModel.Node,
    edges: []const GraphModel.Edge,
    declared_entries: []const []const u8,
) ![]NodeRole {
    var layout = try LaneLayout.init(allocator, nodes, edges, .{ .declared_entries = declared_entries });
    defer layout.deinit();
    return allocator.dupe(NodeRole, layout.roles);
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
        const route = graphEdgeRoute(nodes, edge, .{ .state = state }) orelse continue;
        if (routeDistanceSquared(route, x, y) <= edgeHitRadius(state) * edgeHitRadius(state)) return index;
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
    return routeDistanceSquared(CubicRoute.between(from, to, 1), x, y);
}

fn routeDistanceSquared(route: CubicRoute, x: i32, y: i32) i32 {
    var previous = route.from;
    var best: i32 = std.math.maxInt(i32);
    var step: i32 = 1;
    while (step <= 24) : (step += 1) {
        const t = @as(f32, @floatFromInt(step)) / 24.0;
        const current = route.point(t);
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

fn cardTextLayout(bounds: c.RECT, zoom: f32, pill_width: i32) CardTextLayout {
    const left = bounds.left + scaledValue(11, zoom);
    const right = bounds.right - scaledValue(11, zoom);
    const pill_left = right - pill_width;
    return .{
        .title = rect(left, bounds.top + scaledValue(8, zoom), @max(left, pill_left - scaledValue(6, zoom)), bounds.top + scaledValue(26, zoom)),
        .pill = rect(pill_left, bounds.top + scaledValue(9, zoom), right, bounds.top + scaledValue(25, zoom)),
        .live = rect(left, bounds.top + scaledValue(32, zoom), right, bounds.top + scaledValue(45, zoom)),
        .detail = rect(left, bounds.top + scaledValue(51, zoom), right, bounds.top + scaledValue(68, zoom)),
        .meta = rect(left, bounds.bottom - scaledValue(21, zoom), right, bounds.bottom - scaledValue(8, zoom)),
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
    fill(hdc, rect(left, top, client_right, client_bottom), Tokens.workspace_rail);
    fill(hdc, rect(left, top, left + 1, client_bottom), 0x00312D2D);
    const collapse = loopDetailCollapseBounds(client_right);
    drawText(hdc, allocator, "THIS LOOP", left + 12, top + 16, 11, 0x007A7777, collapse.left - 8);
    fill(hdc, collapse, 0x00303035);
    drawTextRect(hdc, allocator, "Collapse", collapse, 10, 0x00D8D8DE, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);

    const map_layout = loopDetailMiniMapLayout(left, top, client_right);
    roundedCard(hdc, map_layout.frame, Tokens.loop_minimap_surface, false);
    paintMiniMapChip(hdc, node, map_layout.center, true);
    paintMiniMapRow(hdc, allocator, graph, node.id, true, map_layout.incoming.?);
    paintMiniMapRow(hdc, allocator, graph, node.id, false, map_layout.outgoing.?);

    var y = map_layout.frame.bottom + 10;
    var handoff_count: usize = 0;
    for (graph.edges.items) |edge| {
        if (!std.mem.eql(u8, edge.from, node.id) or nodeById(graph, edge.to) == null) continue;
        const row_y = y + if (handoff_count == 0) @as(i32, 24) else 0;
        const row = loopDetailRowLayout(left, row_y, client_right, edge.condition).row;
        if (!loopDetailRowFits(row, node, client_right, client_bottom)) break;
        if (handoff_count == 0) {
            drawText(hdc, allocator, "HANDS OFF TO", left + 12, y, 11, 0x007A7777, client_right - 12);
            y += 24;
        }
        if (paintRelationRow(hdc, allocator, graph, edge.to, edge.condition, edge.fired, left, client_right, y)) {
            handoff_count += 1;
            y += 40;
        }
    }

    if (node.metric_sample_count >= 2) {
        const sparkline = loopDetailSparklineBounds(client_right, client_bottom);
        drawText(hdc, allocator, "RECENT PASSES", sparkline.left, sparkline.top - 24, 11, 0x007A7777, sparkline.right);
        paintMetricSparkline(hdc, node, sparkline);
    }
    const footer = loopDetailFooterBounds(client_right, client_bottom);
    if (node.worktree_branch.len != 0)
        drawText(hdc, allocator, node.worktree_branch, footer.left, footer.top - 18, 10, 0x007A7777, footer.right);
    var footer_buffer: [160]u8 = undefined;
    const footer_text = loopDetailFooter(&footer_buffer, node);
    drawTextRect(hdc, allocator, footer_text, footer, 10, 0x007A7777, c.DT_LEFT | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);
}

fn paintMiniMapRow(hdc: c.HDC, allocator: std.mem.Allocator, graph: *const GraphModel.GraphSummary, node_id: []const u8, incoming: bool, bounds: c.RECT) void {
    var nodes: [4]GraphModel.Node = undefined;
    var count: usize = 0;
    for (graph.edges.items) |edge| {
        if (incoming and !std.mem.eql(u8, edge.to, node_id)) continue;
        if (!incoming and !std.mem.eql(u8, edge.from, node_id)) continue;
        nodes[count] = nodeById(graph, if (incoming) edge.from else edge.to) orelse continue;
        count += 1;
        if (count == nodes.len) break;
    }
    if (count == 0) {
        drawTextRect(hdc, allocator, "—", bounds, 10, 0x00545151, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
        return;
    }
    const row_width = @as(i32, @intCast(count)) * 31 - 5;
    const start = @divTrunc(bounds.left + bounds.right - row_width, 2);
    for (nodes[0..count], 0..) |related, index| {
        const x = start + @as(i32, @intCast(index)) * 31;
        paintMiniMapChip(hdc, related, rect(x, bounds.top, x + 26, bounds.bottom), false);
    }
}

fn panelLoopTypeColor(loop_type: []const u8) u32 {
    if (std.mem.eql(u8, loop_type, "goalBased")) return 0x00709E19;
    if (std.mem.eql(u8, loop_type, "timeBased")) return 0x000085C9;
    if (std.mem.eql(u8, loop_type, "turnBased")) return 0x008151D5;
    if (std.mem.eql(u8, loop_type, "composite") or std.mem.eql(u8, loop_type, "proactive")) return 0x00E98590;
    return 0x00E3DAD3;
}

fn paintMiniMapChip(hdc: c.HDC, node: GraphModel.Node, bounds: c.RECT, selected: bool) void {
    const color = panelLoopTypeColor(node.loop_type);
    const opacity: u32 = if (selected) 90 else 50;
    var blended: u32 = 0;
    inline for (.{ 0, 8, 16 }) |shift| {
        const channel = (((color >> shift) & 255) * opacity +
            ((Tokens.loop_minimap_surface >> shift) & 255) * (100 - opacity)) / 100;
        blended |= channel << shift;
    }
    if (!GdiplusAA.drawRoundedRect(hdc, bounds, 3, blended, if (selected) Tokens.pane_focus_tint else blended, if (selected) 1.5 else 0))
        fill(hdc, bounds, blended);
    if (panelWantsHuman(node))
        drawDot(hdc, bounds.right, bounds.top, 0x000A9FFF, 2);
}

pub fn loopDetailFooterBounds(client_right: i32, client_bottom: i32) c.RECT {
    return rect(@max(0, client_right - Tokens.loop_detail_width) + 12, client_bottom - 28, client_right - 12, client_bottom - 10);
}

pub fn loopDetailSparklineBounds(client_right: i32, client_bottom: i32) c.RECT {
    return rect(@max(0, client_right - Tokens.loop_detail_width) + 12, client_bottom - 102, client_right - 12, client_bottom - 70);
}

fn loopDetailRowFits(row: c.RECT, node: GraphModel.Node, client_right: i32, client_bottom: i32) bool {
    const lower_section_top = if (node.metric_sample_count >= 2)
        loopDetailSparklineBounds(client_right, client_bottom).top - 24
    else
        loopDetailFooterBounds(client_right, client_bottom).top - if (node.worktree_branch.len != 0) @as(i32, 18) else 0;
    return row.bottom <= lower_section_top - 10;
}

fn loopDetailFooter(buffer: []u8, node: GraphModel.Node) []const u8 {
    var stream = std.io.fixedBufferStream(buffer);
    const writer = stream.writer();
    var wrote = false;
    if (node.created_at) |created| {
        var time_buffer: [32]u8 = undefined;
        writer.writeAll("started ") catch return buffer[0..stream.pos];
        writer.writeAll(startTimeLabel(&time_buffer, created)) catch return buffer[0..stream.pos];
        wrote = true;
    }
    if (node.token_usage) |tokens| {
        if (wrote) writer.writeAll(" · ") catch return buffer[0..stream.pos];
        formatTokenUsage(writer, tokens) catch return buffer[0..stream.pos];
        wrote = true;
    }
    return buffer[0..stream.pos];
}

fn startTimeLabel(buffer: []u8, created_at: u64) []const u8 {
    const seconds = if (created_at < 1_000_000_000_000) created_at else created_at / 1000;
    const ticks = (seconds +| 11_644_473_600) *| 10_000_000;
    const utc = c.FILETIME{ .dwLowDateTime = @truncate(ticks), .dwHighDateTime = @truncate(ticks >> 32) };
    var utc_time: c.SYSTEMTIME = undefined;
    var time: c.SYSTEMTIME = undefined;
    if (c.FileTimeToSystemTime(&utc, &utc_time) == 0 or c.SystemTimeToTzSpecificLocalTime(null, &utc_time, &time) == 0) {
        std.log.warn("Unable to format loop start time: Win32 error {d}", .{c.GetLastError()});
        return "unknown time";
    }
    return formatClockTime(buffer, time.wHour, time.wMinute);
}

fn formatClockTime(buffer: []u8, hour: u16, minute: u16) []const u8 {
    var time = std.mem.zeroes(c.SYSTEMTIME);
    time.wHour = hour;
    time.wMinute = minute;
    var wide: [80]u16 = undefined;
    const length = c.GetTimeFormatEx(null, c.TIME_NOSECONDS, &time, null, &wide, wide.len);
    if (length == 0) {
        std.log.warn("Unable to format local loop start time: Win32 error {d}", .{c.GetLastError()});
        return "unknown time";
    }
    const bytes = std.unicode.utf16LeToUtf8(buffer, wide[0..@intCast(length - 1)]) catch |err| {
        std.log.warn("Unable to encode local loop start time: {s}", .{@errorName(err)});
        return "unknown time";
    };
    return buffer[0..bytes];
}

fn paintMetricSparkline(hdc: c.HDC, node: GraphModel.Node, bounds: c.RECT) void {
    fill(hdc, bounds, 0x00222226);
    if (node.metric_sample_count == 0) {
        drawTextRect(hdc, std.heap.page_allocator, "No metric samples", bounds, 10, 0x007A7A82, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
        return;
    }
    const samples = node.metric_samples[0..@as(usize, node.metric_sample_count)];
    var min = samples[0];
    var max = samples[0];
    for (samples) |value| {
        min = @min(min, value);
        max = @max(max, value);
    }
    const range = if (max > min) max - min else 1;
    const count: i32 = @intCast(samples.len);
    var previous_x = bounds.left + 8;
    var previous_y = bounds.bottom - 8 - @as(i32, @intFromFloat(((samples[0] - min) / range) * @as(f64, @floatFromInt(bounds.bottom - bounds.top - 16))));
    // Fallback GDI pen, created lazily only if a GDI+ segment draw fails.
    var fallback_pen: c.HPEN = null;
    var index: usize = 1;
    while (index < samples.len) : (index += 1) {
        const x = bounds.left + 8 + @divTrunc(@as(i32, @intCast(index)) * @max(1, bounds.right - bounds.left - 16), @max(1, count - 1));
        const y = bounds.bottom - 8 - @as(i32, @intFromFloat(((samples[index] - min) / range) * @as(f64, @floatFromInt(bounds.bottom - bounds.top - 16))));
        if (!GdiplusAA.drawLine(hdc, previous_x, previous_y, x, y, 0x007AB8FF, 2)) {
            if (fallback_pen == null) fallback_pen = c.CreatePen(c.PS_SOLID, 2, 0x007AB8FF);
            if (fallback_pen != null) {
                const old = c.SelectObject(hdc, fallback_pen);
                _ = c.MoveToEx(hdc, previous_x, previous_y, null);
                _ = c.LineTo(hdc, x, y);
                _ = c.SelectObject(hdc, old);
            }
        }
        previous_x = x;
        previous_y = y;
    }
    if (fallback_pen != null) _ = c.DeleteObject(fallback_pen);
}

const LoopDetailRowLayout = struct {
    row: c.RECT,
    type_bar: c.RECT,
    title: ?c.RECT,
    condition: ?c.RECT,
    status_dot: c.RECT,
};

fn textRect(x: i32, y: i32, size: i32, limit_right: i32) ?c.RECT {
    if (limit_right - x < 24) return null;
    return rect(x, y, limit_right, y + size + 8);
}

fn loopDetailMiniMapLayout(left: i32, top: i32, client_right: i32) struct {
    frame: c.RECT,
    incoming: ?c.RECT,
    center: c.RECT,
    outgoing: ?c.RECT,
} {
    const frame = rect(left + 12, top + 44, client_right - 12, top + 162);
    const mid = @divTrunc(frame.left + frame.right, 2);
    const center = rect(mid - 18, frame.top + 51, mid + 18, frame.top + 67);
    const incoming = rect(frame.left + 10, frame.top + 29, frame.right - 10, frame.top + 41);
    const outgoing = rect(frame.left + 10, frame.top + 77, frame.right - 10, frame.top + 89);
    return .{
        .frame = frame,
        .incoming = incoming,
        .center = center,
        .outgoing = outgoing,
    };
}

fn loopDetailRowLayout(left: i32, y: i32, client_right: i32, _: []const u8) LoopDetailRowLayout {
    const row = rect(left + 12, y, client_right - 12, y + 36);
    const type_bar = rect(row.left + 5, row.top + 8, row.left + 8, row.top + 28);
    const status_dot = rect(row.right - 10, row.top + 15, row.right - 4, row.top + 21);
    const title = rect(row.left + 15, row.top + 3, status_dot.left - 8, row.top + 20);
    const condition_bounds = rect(row.left + 15, row.top + 21, status_dot.left - 8, row.top + 34);
    return .{
        .row = row,
        .type_bar = type_bar,
        .title = title,
        .condition = condition_bounds,
        .status_dot = status_dot,
    };
}

fn paintRelationRow(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    graph: *const GraphModel.GraphSummary,
    node_id: []const u8,
    condition: []const u8,
    fired: bool,
    left: i32,
    client_right: i32,
    y: i32,
) bool {
    const related = nodeById(graph, node_id) orelse return false;
    const layout = loopDetailRowLayout(left, y, client_right, condition);
    if (panelWantsHuman(related))
        roundedCard(hdc, layout.row, 0x00202334, false);
    fill(hdc, layout.type_bar, panelLoopTypeColor(related.loop_type));
    if (layout.title) |title| drawTextRect(hdc, allocator, related.title, title, 12, 0x00E0E0E5, c.DT_LEFT | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);
    var condition_buffer: [96]u8 = undefined;
    if (layout.condition) |condition_bounds|
        drawTextRect(hdc, allocator, handoffConditionLabel(&condition_buffer, condition, fired), condition_bounds, 10, 0x00858282, c.DT_LEFT | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);
    drawPanelStatusDot(hdc, layout.status_dot, related);
    return true;
}

fn handoffConditionLabel(buffer: []u8, condition: []const u8, fired: bool) []const u8 {
    const label = if (std.mem.eql(u8, condition, "always")) "Always" else if (std.mem.eql(u8, condition, "onSuccess")) "On success" else if (std.mem.eql(u8, condition, "onFailure")) "On failure" else condition;
    if (!fired) return label;
    const lower = if (std.mem.eql(u8, condition, "always")) "always" else if (std.mem.eql(u8, condition, "onSuccess")) "on success" else if (std.mem.eql(u8, condition, "onFailure")) "on failure" else condition;
    return std.fmt.bufPrint(buffer, "{s} · fired", .{lower}) catch label;
}

fn panelStateColor(node: GraphModel.Node) u32 {
    if (panelWantsHuman(node)) return 0x000A9FFF;
    if (std.mem.eql(u8, node.state, "running") or std.mem.eql(u8, node.state, "waiting")) return 0x00FF840A;
    if (std.mem.eql(u8, node.state, "succeeded")) return 0x0058D130;
    if (std.mem.eql(u8, node.state, "failed")) return 0x003A45FF;
    if (std.mem.eql(u8, node.state, "stalled")) return 0x00F25ABF;
    return 0x006E6C6C;
}

fn panelWantsHuman(node: GraphModel.Node) bool {
    return std.mem.eql(u8, node.state, "awaitingInput") or
        std.mem.eql(u8, node.state, "blocked") or
        (std.mem.eql(u8, node.state, "running") and std.mem.eql(u8, node.presence, "awaitingInput"));
}

fn panelStateHollow(state: []const u8) bool {
    return std.mem.eql(u8, state, "blocked") or std.mem.eql(u8, state, "stopped") or std.mem.eql(u8, state, "waiting");
}

fn drawPanelStatusDot(hdc: c.HDC, bounds: c.RECT, node: GraphModel.Node) void {
    const color = panelStateColor(node);
    const background = if (panelWantsHuman(node)) @as(u32, 0x00202334) else Tokens.workspace_rail;
    const brush = c.CreateSolidBrush(if (panelStateHollow(node.state)) background else color);
    const pen = c.CreatePen(c.PS_SOLID, 1, color);
    if (brush == null or pen == null) {
        if (brush != null) _ = c.DeleteObject(brush);
        if (pen != null) _ = c.DeleteObject(pen);
        return;
    }
    const old_brush = c.SelectObject(hdc, brush);
    const old_pen = c.SelectObject(hdc, pen);
    _ = c.Ellipse(hdc, bounds.left, bounds.top, bounds.right, bounds.bottom);
    _ = c.SelectObject(hdc, old_pen);
    _ = c.SelectObject(hdc, old_brush);
    _ = c.DeleteObject(pen);
    _ = c.DeleteObject(brush);
}

fn nodeById(graph: *const GraphModel.GraphSummary, id: []const u8) ?GraphModel.Node {
    for (graph.nodes.items) |node| if (std.mem.eql(u8, node.id, id)) return node;
    return null;
}

fn nodeTitle(graph: *const GraphModel.GraphSummary, id: []const u8) []const u8 {
    return (nodeById(graph, id) orelse return "Unknown loop").title;
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
    const border_width: f32 = if (selected) 2 else 1;
    // Selected: Tokens.canvas_selection. Unselected: Tokens.loop_card_border, i.e.
    // macOS's Theme.loopCardBorder (white 9% over the card fill) pre-blended flat.
    const border_color: u32 = if (selected) Tokens.canvas_selection else Tokens.loop_card_border;
    // Anti-aliased path first: matches macOS's smoothly-curved node cards
    // and selection rings instead of GDI's jagged RoundRect corners.
    if (GdiplusAA.drawRoundedRect(hdc, bounds, 12, color, border_color, border_width)) return;

    const brush = c.CreateSolidBrush(color);
    const pen = c.CreatePen(c.PS_SOLID, if (selected) 2 else 1, border_color);
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

fn roundedControl(hdc: c.HDC, bounds: c.RECT, radius: i32, color: u32, border: u32) void {
    roundedControlStroke(hdc, bounds, radius, color, border, 1);
}

fn roundedControlStroke(hdc: c.HDC, bounds: c.RECT, radius: i32, color: u32, border: u32, stroke: i32) void {
    if (bounds.right <= bounds.left or bounds.bottom <= bounds.top) return;
    if (GdiplusAA.drawRoundedRect(hdc, bounds, radius, color, border, @floatFromInt(stroke))) return;
    const brush = c.CreateSolidBrush(color) orelse {
        std.log.warn("Canvas control brush unavailable\n", .{});
        return;
    };
    defer _ = c.DeleteObject(brush);
    const pen = c.CreatePen(c.PS_SOLID, stroke, border) orelse {
        std.log.warn("Canvas control border unavailable\n", .{});
        return;
    };
    defer _ = c.DeleteObject(pen);
    const old_brush = c.SelectObject(hdc, brush);
    defer _ = c.SelectObject(hdc, old_brush);
    const old_pen = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, old_pen);
    _ = c.RoundRect(hdc, bounds.left, bounds.top, bounds.right, bounds.bottom, radius * 2, radius * 2);
}

fn drawText(
    hdc: c.HDC,
    allocator: std.mem.Allocator,
    text: []const u8,
    x: i32,
    y: i32,
    size: i32,
    color: u32,
    limit_right: i32,
) void {
    const bounds = textRect(x, y, size, limit_right) orelse return;
    const wide = std.unicode.utf8ToUtf16LeAlloc(allocator, text) catch return;
    defer allocator.free(wide);
    if (wide.len == 0) return;
    const old_font = AppFont.select(hdc, size, false);
    _ = c.SetTextColor(hdc, color);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    var draw_bounds = bounds;
    _ = c.DrawTextW(hdc, wide.ptr, @intCast(wide.len), &draw_bounds, c.DT_LEFT | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);
    _ = c.SelectObject(hdc, old_font);
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
    if (wide.len == 0) return;
    const old_font = AppFont.select(hdc, size, false);
    _ = c.SetTextColor(hdc, color);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    var bounds = bounds_value;
    _ = c.DrawTextW(hdc, wide.ptr, @intCast(wide.len), &bounds, format);
    _ = c.SelectObject(hdc, old_font);
}

test "edge connectors resolve reordered node IDs to card positions" {
    const nodes = [_]GraphModel.Node{
        .{ .id = @constCast("node-z"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
        .{ .id = @constCast("node-a"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
    };
    var state = try cardTestState(.{});
    defer state.deinitLayout();
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

test "connected canvas entry ports straddle the leading edge on both surfaces" {
    try initPaint764TestRenderer();
    var fixture = try paint764FixtureModel(std.testing.allocator, .overview);
    defer fixture.model.deinit();
    var dib = try ParityDib.init(1280, 720);
    defer dib.deinit();
    var state = try modelTestState(&fixture.model, .{ .zoom = paint764_zoom }, chrome764GraphBounds());
    defer state.deinitLayout();
    for ([_]Paint764Scene{ .project, .overview }) |scene| {
        try paint764TestSurface(dib, &fixture, std.testing.allocator, scene);
        const card = chrome764Card(&fixture, scene, 0, &state);
        const cy = @divTrunc(card.top + card.bottom, 2);
        // LoopCardView.Metrics.port = 10; the 2pt canvas ring is outside the card clip.
        const outside = rect(card.left - 4, cy - 2, card.left, cy + 3);
        try std.testing.expect(dib.count(outside, 0x00E3DAD3) >= 8);
        try std.testing.expectEqual(@as(?usize, 0), if (scene == .project)
            hitTest(fixture.model.graph.?.nodes.items, card.left + 2, cy, &state, chrome764GraphBounds())
        else if (hitTestOverview(&fixture.model, card.left + 2, cy, &state, chrome764GraphBounds())) |hit|
            hit.node_index
        else
            null);
    }
}

test "connected canvas reverse curves share the source-derived horizontal controls with hits" {
    // CanvasEdgeGeometry.controls: signed half-span, 26pt minimum reach.
    const from = Connector{ .x = 800, .y = 120 };
    const to = Connector{ .x = 300, .y = 320 };
    try std.testing.expect(bezierDistanceSquared(from, to, 652, 151) <= 4);
    try std.testing.expect(bezierDistanceSquared(from, to, 792, 151) > 100);
}

test "connected canvas facing anchors retain endpoint identity and shared hit geometry" {
    const nodes = [_]GraphModel.Node{ graphRoleTestNode("target"), graphRoleTestNode("source") };
    var edge = graphRoleTestEdge("source", "target", "handoff");
    var state = try cardTestState(.{ .zoom = 0.75, .pan_x = 120, .pan_y = 30 });
    defer state.deinitLayout();
    const route = graphEdgeRoute(&nodes, edge, .{ .state = &state }) orelse return error.MissingConnector;
    try std.testing.expectEqual(nodeBounds(1, &state).right, route.from.x);
    try std.testing.expectEqual(nodeBounds(0, &state).left, route.to.x);
    const middle = route.point(0.5);
    try std.testing.expectEqual(@as(?usize, 0), hitTestEdge(&nodes, &.{edge}, middle.x, middle.y, &state, rect(220, 34, 1280, 720)));
    edge.to = @constCast("missing");
    try std.testing.expect(graphEdgeRoute(&nodes, edge, .{ .state = &state }) == null);
}

test "connected canvas stroke patterns preserve real edge kinds and fired state" {
    var edge = graphRoleTestEdge("a", "b", "handoff");
    try std.testing.expectEqual(@as(?[2]i32, .{ 5, 4 }), graphEdgeDash(edge));
    const quiet = graphEdgeColor(edge, false);
    edge.fired = true;
    try std.testing.expect(graphEdgeDash(edge) == null);
    try std.testing.expectEqual(quiet, graphEdgeColor(edge, false));
    edge.kind = @constCast("message");
    try std.testing.expectEqual(@as(?[2]i32, .{ 4, 4 }), graphEdgeDash(edge));
    try std.testing.expect(graphEdgeColor(edge, false) != quiet);
    edge.kind = @constCast("spawn");
    try std.testing.expectEqual(@as(?[2]i32, .{ 2, 4 }), graphEdgeDash(edge));
    const spawn = graphEdgeColor(edge, false);
    edge.cycle_guard = .{ .max_iterations = 3 };
    edge.fire_count = 2;
    try std.testing.expectEqual(@as(?[2]i32, .{ 5, 4 }), graphEdgeDash(edge));
    try std.testing.expect(graphEdgeColor(edge, false) != spawn);
    try std.testing.expectEqual(Tokens.canvas_selection, graphEdgeColor(edge, true));
}

test "connected canvas overview keeps notebook lines visible inside folder lanes" {
    var fixture = try paint764FixtureModel(std.testing.allocator, .overview);
    defer fixture.model.deinit();
    var dib = try ParityDib.init(1280, 720);
    defer dib.deinit();
    try paint764TestSurface(dib, &fixture, std.testing.allocator, .overview);
    // This unoccupied row is inside the first band, not under a card or caption.
    const sample = rect(280, 330, 400, 345);
    var darkest: u32 = 255;
    var lightest: u32 = 0;
    var x = sample.left;
    while (x < sample.right) : (x += 1) {
        const color = c.GetPixel(dib.dc, x, 340);
        try std.testing.expect(color != c.CLR_INVALID);
        darkest = @min(darkest, color & 255);
        lightest = @max(lightest, color & 255);
    }
    // CanvasBand.fill is white at 0.022; it tints rather than erasing the grid.
    try std.testing.expect(lightest > darkest);
    try std.testing.expect(darkest < 24);
}

test "connected canvas overview paints actual graph edges between card middles" {
    var fixture = try paint764FixtureModel(std.testing.allocator, .overview);
    defer fixture.model.deinit();
    var dib = try ParityDib.init(1280, 720);
    defer dib.deinit();
    try paint764TestSurface(dib, &fixture, std.testing.allocator, .overview);
    var state = try modelTestState(&fixture.model, .{ .zoom = paint764_zoom }, chrome764GraphBounds());
    defer state.deinitLayout();
    const first = overviewCardBounds(&fixture.model, 0, 0, chrome764GraphBounds(), &state);
    const next = overviewCardBounds(&fixture.model, 0, 1, chrome764GraphBounds(), &state);
    const cy = @divTrunc(first.top + first.bottom, 2);
    var ink: usize = 0;
    var x = first.right + 1;
    while (x < next.left - 1) : (x += 1) {
        const stroke = c.GetPixel(dib.dc, x, cy);
        const ground = c.GetPixel(dib.dc, x, cy + 4);
        try std.testing.expect(stroke != c.CLR_INVALID and ground != c.CLR_INVALID);
        if (paint764RgbL1(stroke, ground) > 40) ink += 1;
    }
    try std.testing.expect(ink > 0);
}

test "connected canvas root furniture includes a distinct twelve point ENTRY origin" {
    var fixture = try paint764FixtureModel(std.testing.allocator, .overview);
    defer fixture.model.deinit();
    var dib = try ParityDib.init(1280, 720);
    defer dib.deinit();
    var state = try modelTestState(&fixture.model, .{}, chrome764GraphBounds());
    defer state.deinitLayout();
    for ([_]Paint764Scene{ .project, .overview }) |scene| {
        try chrome764Paint(dib, &fixture, scene, &state, null, &.{});
        const geometry = GraphGeometry{ .state = &state, .overview = if (scene == .overview) .{ .model = &fixture.model, .graph_index = 0, .bounds = chrome764GraphBounds() } else null };
        const band = if (scene == .project) graphBand(6, geometry).? else overviewLaneBounds(&fixture.model, 0, chrome764GraphBounds(), &state);
        const cy = @divTrunc(band.top + band.bottom, 2);
        const cx = band.left + scaledValue(31, state.zoom);
        const radius = @divTrunc(scaledValue(12, state.zoom), 2);
        const marker = rect(cx - radius, cy - radius, cx + radius, cy + radius);
        const caption = rect(cx - scaledValue(15, state.zoom), cy + scaledValue(8, state.zoom), cx + scaledValue(15, state.zoom), cy + scaledValue(23, state.zoom));
        try std.testing.expect(dib.count(marker, blendCardColor(0x00FFFFFF, Tokens.canvas_tone, 22)) > 20);
        try std.testing.expect(dib.count(caption, blendCardColor(0x00FFFFFF, Tokens.canvas_tone, 42)) > 0);
    }
}

test "connected canvas hover continuation is a circular fourteen point handle" {
    try initPaint764TestRenderer();
    var fixture = try chrome764IsolatedFixture();
    defer fixture.model.deinit();
    var normal = try ParityDib.init(1280, 720);
    defer normal.deinit();
    var hover = try ParityDib.init(1280, 720);
    defer hover.deinit();
    var state = try modelTestState(&fixture.model, .{}, chrome764GraphBounds());
    defer state.deinitLayout();
    var hovered = try modelTestState(&fixture.model, .{ .hovered_connector = 0 }, chrome764GraphBounds());
    defer hovered.deinitLayout();
    try chrome764Paint(normal, &fixture, .project, &state, null, &.{"chrome-isolated"});
    try chrome764Paint(hover, &fixture, .project, &hovered, null, &.{"chrome-isolated"});
    const graph = fixture.model.graph.?;
    const center = connectorPositionForIndex(graph.nodes.items, 0, true, &state);
    try std.testing.expectEqual(c.GetPixel(normal.dc, center.x + 6, center.y + 6), c.GetPixel(hover.dc, center.x + 6, center.y + 6));
    try std.testing.expect(try label858Differences(normal, hover, rect(center.x - 7, center.y - 7, center.x + 7, center.y + 7)) > 20);
    try std.testing.expectEqual(@as(?usize, 0), hitTestConnector(graph.nodes.items, center.x, center.y, &hovered, chrome764GraphBounds()));
    const consumer = try std.fs.cwd().readFileAlloc(std.testing.allocator, "..\\Tools\\windows\\uia-live-gate.ps1", 2 * 1024 * 1024);
    defer std.testing.allocator.free(consumer);
    const prefix = "$expectedConnectorHoverColor = [System.Drawing.Color]::FromArgb(";
    const color_start = (std.mem.indexOf(u8, consumer, prefix) orelse return error.HoverConsumerColorMissing) + prefix.len;
    const color_end = std.mem.indexOfScalarPos(u8, consumer, color_start, ')') orelse return error.HoverConsumerColorMissing;
    var components = std.mem.splitScalar(u8, consumer[color_start..color_end], ',');
    var expected: u32 = 0;
    for ([_]u5{ 0, 8, 16 }) |shift| {
        const value = components.next() orelse return error.HoverConsumerColorMissing;
        expected |= @as(u32, try std.fmt.parseInt(u8, std.mem.trim(u8, value, " \r\n"), 0)) << shift;
    }
    if (components.next() != null) return error.HoverConsumerColorInvalid;
    var before_match = false;
    var after_match = false;
    var x = center.x - 6;
    while (x <= center.x + 6) : (x += 1) {
        var y = center.y - 6;
        while (y <= center.y + 6) : (y += 1) {
            before_match = before_match or chrome764ColorNear(c.GetPixel(normal.dc, x, y), expected, 24);
            after_match = after_match or chrome764ColorNear(c.GetPixel(hover.dc, x, y), expected, 24);
        }
    }
    try std.testing.expect(!before_match);
    try std.testing.expect(after_match);
}

test "canvas zoom keeps the graph point beneath the cursor stable" {
    var state = CanvasState{};
    state.zoomAt(400, 300, 120);
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), state.zoom, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -40), state.pan_x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -30), state.pan_y, 0.01);
}

test "canvas wheel zoom scales high-resolution trackpad deltas" {
    var state = CanvasState{};
    state.zoomAt(200, 120, 240);
    try std.testing.expectApproxEqAbs(@as(f32, 1.21), state.zoom, 0.01);
}

test "touch pan applies screen deltas and continues through inertia updates" {
    var state = CanvasState{ .pan_x = 8, .pan_y = -4 };
    state.beginTouchPan(100, 200, 7);
    state.continueTouchPan(125, 185, 7);
    try std.testing.expectApproxEqAbs(@as(f32, 33), state.pan_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -19), state.pan_y, 0.001);

    state.continueTouchPan(140, 175, 7);
    try std.testing.expectApproxEqAbs(@as(f32, 48), state.pan_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -29), state.pan_y, 0.001);
}

test "touch pan ends, cancels, and rejects updates after destination changes" {
    var state = CanvasState{ .pan_x = 8, .pan_y = -4 };
    state.beginTouchPan(100, 200, 7);
    state.endTouchPan();
    state.continueTouchPan(150, 150, 7);
    try std.testing.expectApproxEqAbs(@as(f32, 8), state.pan_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -4), state.pan_y, 0.001);
    try std.testing.expect(!state.touch_pan_active);
    try std.testing.expectEqual(@as(u64, 0), state.touch_pan_context);

    state.beginTouchPan(100, 200, 7);
    state.continueTouchPan(150, 150, 8);
    try std.testing.expectApproxEqAbs(@as(f32, 8), state.pan_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -4), state.pan_y, 0.001);
    state.continueTouchPan(160, 140, 8);
    try std.testing.expectApproxEqAbs(@as(f32, 8), state.pan_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -4), state.pan_y, 0.001);

    state.beginTouchPan(100, 200, 7);
    state.cancelInteraction();
    state.continueTouchPan(150, 150, 7);
    try std.testing.expectApproxEqAbs(@as(f32, 8), state.pan_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -4), state.pan_y, 0.001);

    state.beginTouchPan(100, 200, 7);
    state.endPinchZoom();
    state.continueTouchPan(150, 150, 7);
    try std.testing.expectApproxEqAbs(@as(f32, 8), state.pan_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -4), state.pan_y, 0.001);
}

test "pinch zoom scales relative to the gesture's captured base distance" {
    var state = CanvasState{};
    state.beginPinchZoom(100, 1);
    try std.testing.expectEqual(@as(?u32, 100), state.pinch_base_distance);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), state.zoom, 0.0001);

    state.continuePinchZoom(400, 300, 200, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1.8), state.zoom, 0.001);
}

test "pinch zoom does not compound across repeated updates" {
    // Every GID_ZOOM message recomputes the target from the base distance,
    // rather than chaining relative-to-previous factors, so two updates that
    // both report a 2x distance land on the same zoom, not zoom^2.
    var single = CanvasState{};
    single.beginPinchZoom(100, 1);
    single.continuePinchZoom(400, 300, 150, 1);

    var repeated = CanvasState{};
    repeated.beginPinchZoom(100, 1);
    repeated.continuePinchZoom(400, 300, 150, 1);
    repeated.continuePinchZoom(400, 300, 150, 1);
    repeated.continuePinchZoom(400, 300, 150, 1);

    try std.testing.expectApproxEqAbs(single.zoom, repeated.zoom, 0.0001);
}

test "pinch zoom respects the existing zoomBy clamp range" {
    var state = CanvasState{};
    state.beginPinchZoom(100, 1);
    state.continuePinchZoom(400, 300, 10_000, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1.8), state.zoom, 0.0001);

    var shrink = CanvasState{};
    shrink.beginPinchZoom(100, 1);
    shrink.continuePinchZoom(400, 300, 1, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), shrink.zoom, 0.0001);
}

test "pinch zoom with zero distance never sets a baseline or divides by zero" {
    var state = CanvasState{};
    state.beginPinchZoom(0, 1);
    try std.testing.expectEqual(@as(?u32, null), state.pinch_base_distance);

    // Also guards a base captured normally but then fed a zero continuation.
    state.beginPinchZoom(100, 1);
    state.continuePinchZoom(400, 300, 0, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), state.zoom, 0.0001);
}

test "pinch zoom is a no-op before a base distance has been captured" {
    var state = CanvasState{};
    state.continuePinchZoom(400, 300, 200, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), state.zoom, 0.0001);
}

test "ending a pinch gesture clears the baseline for the next gesture" {
    var state = CanvasState{};
    state.beginPinchZoom(100, 1);
    state.continuePinchZoom(400, 300, 150, 1);
    state.endPinchZoom();
    try std.testing.expectEqual(@as(?u32, null), state.pinch_base_distance);

    // A stray continuation after end must not resume the stale gesture.
    const zoom_after_end = state.zoom;
    state.continuePinchZoom(400, 300, 400, 1);
    try std.testing.expectApproxEqAbs(zoom_after_end, state.zoom, 0.0001);

    // A fresh begin starts an independent gesture from the current zoom.
    state.beginPinchZoom(100, 1);
    try std.testing.expectApproxEqAbs(zoom_after_end, state.pinch_base_zoom, 0.0001);
}

test "pinch zoom with a very large OS-reported distance stays finite and clamped" {
    var state = CanvasState{};
    state.beginPinchZoom(1, 1);
    state.continuePinchZoom(400, 300, std.math.maxInt(u32), 1);
    try std.testing.expect(std.math.isFinite(state.zoom));
    try std.testing.expectApproxEqAbs(@as(f32, 1.8), state.zoom, 0.0001);
}

test "pinch continuation with a mismatched context resets instead of zooming" {
    // A gesture begun against one destination (surface/project) must not be
    // able to keep scaling once the app has moved on to a different one --
    // even though the OS never delivered a GID_END for it (e.g. the user
    // switched projects, or the surface flipped to the terminal, mid-pinch).
    var state = CanvasState{};
    state.beginPinchZoom(100, 111);
    try std.testing.expectEqual(@as(u64, 111), state.pinch_context);

    state.continuePinchZoom(400, 300, 200, 222);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), state.zoom, 0.0001);
    try std.testing.expectEqual(@as(?u32, null), state.pinch_base_distance);

    // A fresh begin for the new destination establishes its own baseline
    // rather than being blocked by the stale context.
    state.beginPinchZoom(100, 222);
    state.continuePinchZoom(400, 300, 200, 222);
    try std.testing.expectApproxEqAbs(@as(f32, 1.8), state.zoom, 0.001);
}

test "loop card stripe follows loop type rather than lifecycle state" {
    try std.testing.expect(loopTypeColor("goalBased") != stateColor("failed", false));
    try std.testing.expectEqual(@as(u32, 0x00E98590), loopTypeColor("composite"));
}

fn laneRectanglesIntersect(a: c.RECT, b: c.RECT) bool {
    return a.left < b.right and b.left < a.right and a.top < b.bottom and b.top < a.bottom;
}

fn modelTestState(model: *const GraphModel.Model, initial: CanvasState, bounds: c.RECT) !CanvasState {
    var state = initial;
    state.project_layout = null;
    state.overview_layout = null;
    state.layout_fingerprint = null;
    try state.syncLayout(std.testing.allocator, model, bounds, &.{}, &.{});
    return state;
}

fn cardTestState(initial: CanvasState) !CanvasState {
    var state = initial;
    const nodes = [_]LaneLayout.Node{ .{ .id = "0" }, .{ .id = "1" }, .{ .id = "2" }, .{ .id = "3" }, .{ .id = "4" }, .{ .id = "5" } };
    state.project_layout = try LaneLayout.init(std.testing.allocator, &nodes, &[_]LaneLayout.Edge{}, .{});
    return state;
}

test "lane integration production project and overview read edges rather than arrival index" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"graphChanged":{"id":"lane","project":{"path":"lane","name":"Lane"},"nodes":[{"id":"c","title":"Third"},{"id":"a","title":"First"},{"id":"b","title":"Second"}],"edges":[{"id":"ab","from":"a","to":"b","kind":"handoff"},{"id":"bc","from":"b","to":"c","kind":"handoff"}]}}
    );
    var state = CanvasState{};
    defer state.deinitLayout();
    const viewport = rect(220, 34, 1800, 900);
    try state.syncLayout(allocator, &model, viewport, &.{}, &.{});
    const a = nodeBounds(1, &state);
    const b = nodeBounds(2, &state);
    const c_card = nodeBounds(0, &state);
    try std.testing.expectEqual(a.top, b.top);
    try std.testing.expectEqual(b.top, c_card.top);
    try std.testing.expect(b.left > a.right);
    try std.testing.expect(c_card.left > b.right);
    try std.testing.expectEqualDeep(a, overviewCardBounds(&model, 0, 1, viewport, &state));
    try std.testing.expectEqualDeep(b, overviewCardBounds(&model, 0, 2, viewport, &state));
    try std.testing.expectEqualDeep(c_card, overviewCardBounds(&model, 0, 0, viewport, &state));
}

test "lane integration stale restored offsets cannot overlap production card rectangles" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"graphChanged":{"id":"lane","project":{"path":"lane","name":"Lane"},"nodes":[{"id":"a","title":"First"},{"id":"b","title":"Second"}],"edges":[]}}
    );
    var state = CanvasState{};
    state.syncNodeOffsets(model.graph.?.nodes.items);
    state.node_offsets[1] = .{ .x = -260 };
    const encoded = try state.encodeNodeOffsets(allocator);
    defer allocator.free(encoded);
    var restored = CanvasState{};
    defer restored.deinitLayout();
    try restored.decodeNodeOffsets(encoded);
    restored.syncNodeOffsets(model.graph.?.nodes.items);
    try restored.syncLayout(allocator, &model, rect(220, 34, 1800, 900), &.{}, &.{});
    try std.testing.expect(!laneRectanglesIntersect(nodeBounds(0, &restored), nodeBounds(1, &restored)));
}

test "lane integration fit uses full derived content rather than three-column grid dimensions" {
    var fixture = try paint764FixtureModel(std.testing.allocator, .overview);
    defer fixture.model.deinit();
    const viewport = chrome764GraphBounds();
    for ([_]Surface{ .project, .overview }) |surface| {
        var state = try modelTestState(&fixture.model, .{}, viewport);
        defer state.deinitLayout();
        const content = contentSize(&fixture.model, surface, &state);
        try std.testing.expectEqual(@as(i32, if (surface == .project) 1472 else 1682), content.width);
        state.fit(viewport, content.width, content.height);
        try std.testing.expect(state.zoom <= 1);
        var cards: usize = 0;
        if (surface == .project) {
            for (fixture.model.graph.?.nodes.items, 0..) |_, index| {
                const card = nodeBounds(index, &state);
                try std.testing.expect(card.left >= viewport.left and card.right <= viewport.right and card.top >= viewport.top and card.bottom <= viewport.bottom);
                cards += 1;
            }
        } else {
            for (fixture.model.graphs.items, 0..) |graph, graph_index| {
                for (graph.nodes.items, 0..) |_, index| {
                    const card = overviewCardBounds(&fixture.model, graph_index, index, viewport, &state);
                    try std.testing.expect(card.left >= viewport.left and card.right <= viewport.right and card.top >= viewport.top and card.bottom <= viewport.bottom);
                    cards += 1;
                }
            }
        }
        try std.testing.expectEqual(@as(usize, if (surface == .project) 6 else 8), cards);
    }
}

fn expectLaneRectangles(model: *const GraphModel.Model, state: *const CanvasState) !usize {
    var pairs: usize = 0;
    if (model.graph) |graph| {
        for (graph.nodes.items, 0..) |_, i| {
            const a = nodeBounds(i, state);
            try std.testing.expect(a.right > a.left and a.bottom > a.top);
            for (i + 1..graph.nodes.items.len) |j| {
                try std.testing.expect(!laneRectanglesIntersect(a, nodeBounds(j, state)));
                pairs += 1;
            }
        }
    }
    for (model.graphs.items, 0..) |graph, lane| {
        for (graph.nodes.items, 0..) |_, i| {
            const a = overviewCardBounds(model, lane, i, state.layout_bounds, state);
            try std.testing.expect(a.right > a.left and a.bottom > a.top);
            for (model.graphs.items[lane..], lane..) |other_graph, other_lane| {
                const first = if (lane == other_lane) i + 1 else 0;
                for (first..other_graph.nodes.items.len) |j| {
                    try std.testing.expect(!laneRectanglesIntersect(a, overviewCardBounds(model, other_lane, j, state.layout_bounds, state)));
                    pairs += 1;
                }
            }
        }
    }
    return pairs;
}

test "lane integration fixture rectangles never intersect within projects or across overview lanes" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    var state = CanvasState{};
    defer state.deinitLayout();
    var pairs: usize = 0;
    var frames: usize = 0;
    for ([_][]const u8{
        "fixtures\\paint-project-v1.json",
        "fixtures\\paint-764-project.json",
        "fixtures\\paint-764-overview-peer.json",
        "fixtures\\daemon-v2-graph-event.json",
        "fixtures\\daemon-v2-graph-reordered-edges.json",
        "fixtures\\daemon-v2-graph-attention.json",
    }) |path| {
        const frame = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        defer allocator.free(frame);
        _ = try model.updateFromFrame(frame);
        try state.syncLayout(allocator, &model, rect(220, 34, 2400, 1600), &.{}, &.{});
        pairs += try expectLaneRectangles(&model, &state);
        frames += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), frames);
    try std.testing.expect(pairs > 40);
}

test "lane integration reorder insertion deletion switch and legacy restoration keep one geometry source" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    var state = CanvasState{ .zoom = 0.8, .pan_x = 18, .pan_y = 9 };
    defer state.deinitLayout();
    const frames = [_][]const u8{
        \\{"graphChanged":{"project":{"path":"A","name":"A"},"nodes":[{"id":"c","title":"C"},{"id":"a","title":"A"},{"id":"b","title":"B"}],"edges":[{"id":"ab","from":"a","to":"b","kind":"handoff"},{"id":"bc","from":"b","to":"c","kind":"handoff"}]}}
        ,
        \\{"graphChanged":{"project":{"path":"A","name":"A"},"nodes":[{"id":"b","title":"B"},{"id":"new","title":"New"},{"id":"c","title":"C"},{"id":"a","title":"A"}],"edges":[{"id":"ab","from":"a","to":"b","kind":"handoff"},{"id":"bc","from":"b","to":"c","kind":"handoff"}]}}
        ,
        \\{"graphChanged":{"project":{"path":"A","name":"A"},"nodes":[{"id":"c","title":"C"},{"id":"new","title":"New"},{"id":"a","title":"A"}],"edges":[{"id":"ac","from":"a","to":"c","kind":"handoff"}]}}
        ,
        \\{"graphChanged":{"project":{"path":"B","name":"B"},"nodes":[{"id":"cycle-b","title":"B"},{"id":"cycle-a","title":"A"}],"edges":[{"id":"ba","from":"cycle-b","to":"cycle-a","kind":"handoff"},{"id":"ab","from":"cycle-a","to":"cycle-b","kind":"handoff"}]}}
        ,
    };
    var checked: usize = 0;
    for (frames) |frame| {
        _ = try model.updateFromFrame(frame);
        state.syncNodeOffsets(model.graph.?.nodes.items);
        state.node_offsets[0] = .{ .x = 5000, .y = -5000 };
        const encoded = try state.encodeNodeOffsets(allocator);
        defer allocator.free(encoded);
        try state.decodeNodeOffsets(encoded);
        try state.syncLayout(allocator, &model, rect(220, 34, 2400, 1600), &.{}, &.{});
        checked += try expectLaneRectangles(&model, &state);
        const graph = model.graph.?;
        for (graph.nodes.items, 0..) |node, index| {
            const bounds = nodeBounds(index, &state);
            const center = Connector{ .x = @divTrunc(bounds.left + bounds.right, 2), .y = @divTrunc(bounds.top + bounds.bottom, 2) };
            try std.testing.expectEqual(@as(?usize, index), hitTest(graph.nodes.items, center.x, center.y, &state, state.layout_bounds));
            const port = connectorPosition(graph.nodes.items, node.id, true, &state).?;
            try std.testing.expectEqual(bounds.right, port.x);
            try std.testing.expectEqual(center.y, port.y);
        }
        const positions = state.project_layout.?.positions.ptr;
        try state.syncLayout(allocator, &model, state.layout_bounds, &.{}, &.{});
        try std.testing.expectEqual(positions, state.project_layout.?.positions.ptr);
    }
    try std.testing.expect(model.selectProject("B"));
    try state.syncLayout(allocator, &model, state.layout_bounds, &.{}, &.{});
    checked += try expectLaneRectangles(&model, &state);
    try std.testing.expectEqual(@as(usize, 2), state.project_layout.?.positions.len);
    try std.testing.expect(checked > 20);
}

fn layoutAllocationFixture(allocator: std.mem.Allocator, model: *const GraphModel.Model) !void {
    var state = CanvasState{};
    defer state.deinitLayout();
    try state.syncLayout(allocator, model, rect(220, 34, 1280, 720), &.{}, &.{});
}

test "lane integration cache allocation failures release every project and overview result" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"A","name":"A"},"nodes":[{"id":"a","title":"A"},{"id":"b","title":"B"}],"edges":[{"id":"ab","from":"a","to":"b","kind":"handoff"}]}}
    );
    try std.testing.checkAllAllocationFailures(std.testing.allocator, layoutAllocationFixture, .{&model});
    var state = try modelTestState(&model, .{}, rect(220, 34, 1280, 720));
    defer state.deinitLayout();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, state.syncLayout(failing.allocator(), &model, rect(220, 34, 1280, 400), &.{}, &.{}));
    try std.testing.expectEqualDeep(rect(0, 0, 0, 0), nodeBounds(0, &state));
    try std.testing.expect(state.overview_layout == null and state.layout_fingerprint == null);
}

test "dense edge labels move away from already placed labels" {
    const first = rect(100, 100, 248, 120);
    try std.testing.expect(overlapsPlaced(rect(120, 110, 200, 118), &.{first}));
    try std.testing.expect(!overlapsPlaced(rect(260, 110, 340, 118), &.{first}));
}

test "canvas hit testing follows pan and zoom" {
    var state = try cardTestState(.{});
    defer state.deinitLayout();
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

test "card drag pans the whole sheet without overriding derived placement and cancels safely" {
    var state = try cardTestState(.{ .zoom = 2 });
    defer state.deinitLayout();
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
    try std.testing.expectEqual(@as(f32, 0), state.node_offsets[0].x);
    try std.testing.expectEqual(@as(f32, 0), state.node_offsets[0].y);
    state.cancelInteraction();
    const restored = nodeBounds(0, &state);
    try std.testing.expectEqual(before.left, restored.left);
    try std.testing.expectEqual(before.top, restored.top);
    state.beginNodeDrag("a", 0, before.left, before.top);
    state.updateNodeDrag(before.left + 30, before.top + 10);
    state.endNodeDrag();
    try std.testing.expectEqual(before.left + 30, nodeBounds(0, &state).left);
}

test "node card release activates below drag threshold and movement never repositions" {
    var state = try cardTestState(.{});
    defer state.deinitLayout();
    const nodes = [_]GraphModel.Node{
        .{ .id = @constCast("a"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
    };
    state.syncNodeOffsets(&nodes);
    const before = nodeBounds(0, &state);
    state.beginNodeDrag("a", 0, before.left + 10, before.top + 10);
    state.updateNodeDrag(before.left + 14, before.top + 14);
    try std.testing.expectEqual(@as(?usize, 0), state.completeNodeDrag());
    try std.testing.expectEqual(before.left, nodeBounds(0, &state).left);
    try std.testing.expectEqual(before.top, nodeBounds(0, &state).top);

    state.beginNodeDrag("a", 0, before.left + 10, before.top + 10);
    state.updateNodeDrag(before.left + 20, before.top + 10);
    try std.testing.expect(state.completeNodeDrag() == null);
    try std.testing.expectEqual(before.left + 10, nodeBounds(0, &state).left);
}

test "legacy offsets rekey across daemon reorder without changing derived rectangles" {
    var state = try cardTestState(.{});
    defer state.deinitLayout();
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
    try std.testing.expectEqual(before_a.left + 30, moved_a.left);
    try std.testing.expectEqual(before_a.top + 120 + 10, moved_a.top);
    try std.testing.expectEqual(before_a.left + 30, unmoved_b.left);
    try std.testing.expectEqual(before_a.top + 10, unmoved_b.top);
}

test "legacy offset reload never restores free card positioning" {
    var state = try cardTestState(.{});
    defer state.deinitLayout();
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

    var restored = try cardTestState(.{});
    defer restored.deinitLayout();
    try restored.decodeNodeOffsets(encoded);
    restored.syncNodeOffsets(&nodes);
    try std.testing.expectEqual(before.left, nodeBounds(0, &restored).left);
    try std.testing.expectEqual(before.top, nodeBounds(0, &restored).top);
}

test "invalid persisted node movement is rejected without replacing valid state" {
    var state = try cardTestState(.{});
    defer state.deinitLayout();
    const nodes = [_]GraphModel.Node{
        .{ .id = @constCast("valid"), .title = @constCast(""), .loop_type = @constCast(""), .state = @constCast(""), .activity = @constCast(""), .presence = @constCast("") },
    };
    state.syncNodeOffsets(&nodes);
    state.node_offsets[0] = .{ .x = 12, .y = 8 };
    try std.testing.expectError(
        error.InvalidCanvasLayout,
        state.decodeNodeOffsets("1\tnan\t4\n"),
    );
    try std.testing.expectEqual(@as(f32, 12), state.node_offsets[0].x);
    try std.testing.expectEqual(@as(f32, 8), state.node_offsets[0].y);
    try std.testing.expectEqual(@as(i32, Tokens.sidebar_width + 162), nodeBounds(0, &state).left);
    try std.testing.expectEqual(@as(i32, Tokens.header_height + 100), nodeBounds(0, &state).top);
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
    defer state.deinitLayout();
    try state.syncLayout(allocator, &model, bounds, &.{}, &.{});
    const card = overviewCardBounds(&model, 0, 0, bounds, &state);
    const hit = hitTestOverview(&model, card.left + 4, card.top + 4, &state, bounds) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), hit.graph_index);
    try std.testing.expectEqual(@as(usize, 0), hit.node_index);
    const chat = quickChatCardBounds(2, bounds, &state);
    try std.testing.expectEqual(@as(?usize, 2), hitTestQuickChat(3, chat.left + 4, chat.top + 4, &state, bounds));
    try std.testing.expect(hitTestQuickChat(3, bounds.left - 1, chat.top, &state, bounds) == null);
}

test "cross-project overview stacks every open folder as its own lane" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    const frameA =
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"a","project":{"path":"A","name":"Alpha"},"nodes":[{"id":"a1","title":"Alpha 1","state":"idle"},{"id":"a2","title":"Alpha 2","state":"idle"},{"id":"a3","title":"Alpha 3","state":"idle"},{"id":"a4","title":"Alpha 4","state":"idle"}],"edges":[]}}}
    ;
    const frameB =
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"id":"b","project":{"path":"B","name":"Beta"},"nodes":[{"id":"b1","title":"Beta 1","state":"idle"},{"id":"b2","title":"Beta 2","state":"idle"}],"edges":[]}}}
    ;
    _ = try model.updateFromFrame(frameA);
    _ = try model.updateFromFrame(frameB);
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":3,"event":{"recentProjectsListed":[{"path":"C","name":"Recent only"}]}}
    );
    try std.testing.expectEqual(@as(usize, 2), model.graphs.items.len);
    try std.testing.expect(model.graphFor("C") == null);
    const bounds = rect(Tokens.sidebar_width, Tokens.header_height, 2600, 2000);
    var identity = try modelTestState(&model, .{}, bounds);
    defer identity.deinitLayout();
    try std.testing.expectEqualDeep(rect(300, 96, 1822, 610), overviewLaneBounds(&model, 0, bounds, &identity));
    try std.testing.expectEqualDeep(rect(300, 634, 1822, 908), overviewLaneBounds(&model, 1, bounds, &identity));
    try std.testing.expectEqualDeep(rect(382, 494, 632, 590), overviewCardBounds(&model, 0, 3, bounds, &identity));
    try std.testing.expectEqualDeep(rect(382, 672, 632, 768), overviewCardBounds(&model, 1, 0, bounds, &identity));

    for ([_]CanvasState{
        .{},
        .{ .zoom = 0.75, .pan_x = 100, .pan_y = 17 },
        .{ .zoom = 1.25, .pan_x = -30, .pan_y = -12 },
    }) |initial| {
        var state = try modelTestState(&model, initial, bounds);
        defer state.deinitLayout();
        const lane_a = overviewLaneBounds(&model, 0, bounds, &state);
        const lane_b = overviewLaneBounds(&model, 1, bounds, &state);
        try std.testing.expect(lane_a.bottom < lane_b.top);
        try std.testing.expectEqual(lane_a.left, lane_b.left);
        try std.testing.expectEqual(lane_a.right, lane_b.right);
        for (model.graphs.items, 0..) |graph, graph_index| {
            const lane = overviewLaneBounds(&model, graph_index, bounds, &state);
            for (graph.nodes.items, 0..) |_, node_index| {
                const card = overviewCardBounds(&model, graph_index, node_index, bounds, &state);
                try std.testing.expect(card.left >= lane.left and card.right <= lane.right);
                try std.testing.expect(card.top > lane.top and card.bottom < lane.bottom);
                try std.testing.expectEqual(
                    @as(?OverviewHit, .{ .graph_index = graph_index, .node_index = node_index }),
                    hitTestOverview(&model, card.left + 2, card.top + 2, &state, bounds),
                );
            }
            for ([_]struct { offset: i32, action: OverviewLaneAction }{
                .{ .offset = 104, .action = .open_project },
                .{ .offset = 45, .action = .inspect_worktrees },
            }) |target| {
                const x = lane.right - scaledValue(target.offset, state.zoom);
                const y = lane.top + scaledValue(20, state.zoom);
                try std.testing.expectEqual(target.action, overviewLaneActionAt(&model, graph_index, x, y, bounds, &state).?);
                try std.testing.expect(overviewLaneActionAt(&model, 1 - graph_index, x, y, bounds, &state) == null);
                try std.testing.expect(hitTestOverview(&model, x, y, &state, bounds) == null);
            }
        }
        try std.testing.expect(overviewLaneActionAt(&model, 2, lane_b.right - 40, lane_b.top + 20, bounds, &state) == null);
    }

    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":4,"event":{"graphChanged":{"id":"b","project":{"path":"B","name":"Beta"},"nodes":[],"edges":[]}}}
    );
    try identity.syncLayout(allocator, &model, bounds, &.{}, &.{});
    const empty_lane = overviewLaneBounds(&model, 1, bounds, &identity);
    try std.testing.expectEqualDeep(rect(300, 634, 1822, 788), empty_lane);
    try std.testing.expectEqual(OverviewLaneAction.open_project, overviewLaneActionAt(&model, 1, 1710, 654, bounds, &identity).?);
    try std.testing.expectEqual(OverviewLaneAction.inspect_worktrees, overviewLaneActionAt(&model, 1, 1770, 654, bounds, &identity).?);
    try std.testing.expect(hitTestOverview(&model, 382, 672, &identity, bounds) == null);
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
    defer state.deinitLayout();
    try state.syncLayout(std.testing.allocator, &model, bounds, &.{}, &.{});
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

test "canvas visual finish attention rail is compact and clear of the add control" {
    for ([_]i32{ 640, 900, 1280, 1920 }) |width| {
        const rail = attentionRailBounds(width);
        try std.testing.expect(rail.right - rail.left <= 410);
        try std.testing.expectEqual(@as(i32, 30), rail.bottom - rail.top);
        try std.testing.expectEqual(@as(i32, Tokens.header_height + 18), rail.top);
        try std.testing.expect(rail.right <= width - 140);
    }
    var buffer: [96]u8 = undefined;
    var node = parityTestNode();
    node.title = @constCast("A title so long that it must never widen the queue rail " ** 8);
    const age = attentionAgeLabel(&buffer, node);
    try std.testing.expect(std.mem.startsWith(u8, age, "oldest "));
    try std.testing.expect(std.mem.indexOf(u8, age, node.title) == null);
    try std.testing.expect(std.mem.indexOf(u8, age, ":") == null);
}

test "canvas visual finish attention queue visibility and shared Review geometry" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    for ([_][]const u8{ "idle", "running", "failed" }, 0..) |state, index| {
        const frame = try std.fmt.allocPrint(std.testing.allocator, "{{\"graphChanged\":{{\"project\":{{\"path\":\"A\",\"name\":\"A\"}},\"nodes\":[{{\"id\":\"a\",\"title\":\"Long title\",\"state\":\"{s}\",\"presence\":{{\"presence\":\"{s}\"}}}},{{\"id\":\"b\",\"title\":\"Another loop\",\"state\":\"{s}\"}}],\"edges\":[]}}}}", .{ state, if (index == 1) "awaitingInput" else "idle", if (index == 2) "failed" else "idle" });
        defer std.testing.allocator.free(frame);
        _ = try model.updateFromFrame(frame);
        try std.testing.expectEqual(index, model.attentionCount());
        for ([_]Surface{ .project, .overview, .quick_chats, .workspace }) |surface|
            try std.testing.expectEqual(index != 0 and (surface == .project or surface == .overview), attentionRailShown(&model, surface));
    }
    for ([_]i32{ 0, Tokens.sidebar_width }) |left| {
        const bounds = rect(left, Tokens.header_height, 1280, 720);
        const layout = attentionRailLayout(bounds);
        try std.testing.expectEqual(left + 20, layout.rail.left);
        try std.testing.expect(layout.count.right <= layout.age.left);
        try std.testing.expect(layout.age.right < layout.review.left);
        try std.testing.expect(layout.review.right < addButtonBounds(bounds).left);
        try std.testing.expect(layout.review.top >= layout.rail.top and layout.review.bottom <= layout.rail.bottom);
        if (left != 0) {
            try std.testing.expect(hitTestAttentionRail(layout.review.left + 2, layout.review.top + 2, bounds.right));
            try std.testing.expect(!hitTestAttentionRail(layout.count.left + 2, layout.count.top + 2, bounds.right));
        }
    }
}

test "canvas visual finish oldest age uses the shared duration without a title or buckets" {
    var node = parityTestNode();
    node.created_at = 1000;
    var buffer: [96]u8 = undefined;
    for ([_]struct { age: u64, expected: []const u8 }{
        .{ .age = 0, .expected = "oldest 0s" },
        .{ .age = 59, .expected = "oldest 59s" },
        .{ .age = 60, .expected = "oldest 1m" },
        .{ .age = 3660, .expected = "oldest 1h 1m" },
        .{ .age = 93600, .expected = "oldest 1d 2h" },
    }) |sample| {
        try std.testing.expectEqualStrings(sample.expected, attentionAgeLabelAt(&buffer, node, 1000 + sample.age));
    }
    try std.testing.expectEqualStrings("oldest 0s", attentionAgeLabelAt(&buffer, node, 500));
    node.created_at = null;
    try std.testing.expectEqualStrings("", attentionAgeLabelAt(&buffer, node, 500));
}

test "canvas visual finish folder identity stays on the detail axis and actions remain disjoint" {
    for ([_]i32{ 0, Tokens.sidebar_width }) |left| {
        for ([_]Header.ProjectGlyph{ .folder, .remote, .global }) |glyph| {
            const header = Header{ .title = "A long project identity that yields to toolbar actions", .project_glyph = glyph, .detail_left = left, .attention_count = 12, .panel_visible = false };
            for ([_]i32{ 640, 900, 1280, 1920 }) |width| {
                const layout = header.layout(width);
                try std.testing.expectEqual(left + 20, layout.identity.left);
                var right = layout.identity.right;
                for (header_actions) |action| {
                    const button = layout.bounds(action) orelse continue;
                    try std.testing.expect(button.left > right);
                    try std.testing.expectEqual(action, layout.actionAt(button.left + 1, button.top + 1).?);
                    right = button.right;
                }
                try std.testing.expect(right <= width);
            }
        }
    }
    const plain = (Header{ .title = "Quick Chat", .context = "Quick Chat workspace" }).layout(1280);
    try std.testing.expectEqual(@as(i32, 8), plain.identity.left);
}

test "canvas visual finish add control shares compact paint focus and hit geometry" {
    var dib = try ParityDib.init(640, 240);
    defer dib.deinit();
    const bounds = addButtonBounds(rect(0, 0, 640, 240));
    try std.testing.expectEqual(@as(i32, 118), bounds.right - bounds.left);
    try std.testing.expectEqual(@as(i32, 30), bounds.bottom - bounds.top);
    paintAddButton(dib.dc, std.testing.allocator, bounds, "New Node", false, false);
    try std.testing.expectEqual(Tokens.canvas_tone, c.GetPixel(dib.dc, bounds.left, bounds.top));
    try std.testing.expectEqual(@as(u32, 0x001A1B19), c.GetPixel(dib.dc, bounds.left + 3, bounds.top + 15));
    try std.testing.expect(dib.count(bounds, 0x00BDBDBD) > 0);
    paintAddButton(dib.dc, std.testing.allocator, bounds, "New Chat", true, true);
    try std.testing.expect(dib.count(bounds, 0x00232220) > 0);
    try std.testing.expect(dib.count(bounds, 0x00E8E8E8) > 0);
}

test "canvas visual finish notebook raster has 48 pixel pitch and follows pan zoom" {
    var dib = try ParityDib.init(640, 480);
    defer dib.deinit();
    const bounds = rect(40, 40, 600, 440);
    for ([_]f32{ 0.75, 1, 1.25 }) |zoom| {
        const state = CanvasState{ .zoom = zoom, .pan_x = -37, .pan_y = 19 };
        fill(dib.dc, bounds, Tokens.canvas_tone);
        drawGrid(dib.dc, bounds, &state);
        const pitch: i32 = @intFromFloat(48 * zoom);
        var lines: usize = 0;
        var previous: ?i32 = null;
        var x = bounds.left;
        while (x < bounds.right) : (x += 1) {
            if (c.GetPixel(dib.dc, x, 42) != Tokens.canvas_grid_line) continue;
            if (previous) |last| try std.testing.expectEqual(pitch, x - last);
            previous = x;
            lines += 1;
        }
        try std.testing.expect(lines >= 8);
        try std.testing.expectEqual(Tokens.canvas_grid_line, c.GetPixel(dib.dc, bounds.left + @mod(@as(i32, @intFromFloat(state.pan_x)), pitch), 42));
    }
}

test "canvas visual finish zoom capsule has compact disjoint action geometry" {
    const bounds = rect(240, 34, 1280, 720);
    const controls = zoomControlsBounds(bounds);
    try std.testing.expect(controls.right - controls.left <= 140);
    try std.testing.expectEqual(@as(i32, 30), controls.bottom - controls.top);
    var right = controls.left;
    for (0..4) |index| {
        const button = zoomButtonBounds(bounds, @intCast(index));
        try std.testing.expect(button.left > right);
        try std.testing.expect(button.right < controls.right);
        try std.testing.expect(button.top > controls.top and button.bottom < controls.bottom);
        try std.testing.expectEqual(@as(ZoomControl, @enumFromInt(index)), hitTestZoomControl(@divTrunc(button.left + button.right, 2), button.top + 2, bounds).?);
        right = button.right;
    }
    try std.testing.expect(hitTestZoomControl(controls.left, controls.top, bounds) == null);
}

test "canvas visual finish reclaim controls retain a legible rounded action row" {
    for ([_]f32{ 0.55, 0.8, 1, 1.8 }) |zoom| {
        const bounds = rect(80, 80, 80 + scaledValue(250, zoom), 80 + scaledValue(96, zoom));
        const offer = reclaimOfferBounds(bounds);
        try std.testing.expect(offer.reclaim.bottom - offer.reclaim.top >= scaledValue(20, zoom));
        try std.testing.expect(offer.reclaim.right < offer.keep.left);
        try std.testing.expect(offer.keep.right < bounds.right);
        try std.testing.expect(offer.keep.bottom <= bounds.bottom - scaledValue(21, zoom));
    }
}

test "canvas visual finish attention warmth survives the non AA fallback" {
    if (GdiplusAA.isReady()) return error.SkipZigTest;
    var dib = try ParityDib.init(640, 240);
    defer dib.deinit();
    const bounds = rect(40, 40, 290, 136);
    var node = parityTestNode();
    node.state = @constCast("running");
    node.presence = @constCast("awaitingInput");
    for ([_]bool{ false, true }) |selected| {
        fill(dib.dc, rect(0, 0, 640, 240), Tokens.canvas_tone);
        drawLoopCard(dib.dc, std.testing.allocator, node, bounds, &.{}, .interior, true, .reply, selected, null, true);
        try std.testing.expectEqual(Tokens.loop_card_attention_bottom, c.GetPixel(dib.dc, bounds.right - 8, bounds.top + 45));
        try std.testing.expect(dib.count(bounds, if (selected) Tokens.canvas_selection else Tokens.loop_card_attention_border) > 20);
    }
}

test "canvas visual finish controls select actual UI and monospaced font faces" {
    const dc = c.CreateCompatibleDC(null) orelse return error.TestDcCreationFailed;
    defer _ = c.DeleteDC(dc);
    for ([_]struct { size: f32, style: AppFont.Style, face: []const u8, weight: i32 }{
        .{ .size = 12, .style = .semibold, .face = "Segoe UI", .weight = c.FW_SEMIBOLD },
        .{ .size = 13, .style = .semibold, .face = "Segoe UI", .weight = c.FW_SEMIBOLD },
        .{ .size = 11, .style = .semibold, .face = "Segoe UI", .weight = c.FW_SEMIBOLD },
        .{ .size = 9.5, .style = .card_mono, .face = "Consolas", .weight = c.FW_NORMAL },
    }) |request| {
        const fact = try inspectPaintFont(std.testing.allocator, dc,
            AppFont.getStyle(request.size, request.style), request.face,
            -AppFont.styleHeight(request.size, 96), request.weight);
        defer std.testing.allocator.free(fact.actual_face);
        std.debug.print("canvas visual font requested={s} actual={s} size={d} weight={d}\n",
            .{ request.face, fact.actual_face, request.size, fact.weight });
    }
}

test "loop card parity project metrics match the shipping card" {
    var state = try cardTestState(.{});
    defer state.deinitLayout();
    const bounds = nodeBounds(0, &state);
    try std.testing.expectEqual(@as(i32, 250), bounds.right - bounds.left);
    try std.testing.expectEqual(@as(i32, 96), bounds.bottom - bounds.top);
}

test "loop card parity overview metrics match the project card" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"A","name":"A"},"nodes":[{"id":"a","title":"A"}],"edges":[]}}
    );
    var state = try modelTestState(&model, .{}, rect(220, 34, 1200, 900));
    defer state.deinitLayout();
    const bounds = overviewCardBounds(&model, 0, 0, rect(220, 34, 1200, 900), &state);
    try std.testing.expectEqual(@as(i32, 250), bounds.right - bounds.left);
    try std.testing.expectEqual(@as(i32, 96), bounds.bottom - bounds.top);
}

test "loop card parity activity outranks a populated goal" {
    const node = GraphModel.Node{
        .id = @constCast("card"),
        .title = @constCast("Card"),
        .loop_type = @constCast("goalBased"),
        .state = @constCast("running"),
        .presence = @constCast("busy"),
        .activity = @constCast("checking tests"),
        .goal_summary = @constCast("All tests pass"),
    };
    try std.testing.expectEqualStrings("checking tests", nodePrimaryDetail(node));
}

test "loop card parity meta uses type and backend display name without tokens" {
    const node = GraphModel.Node{
        .id = @constCast("card"),
        .title = @constCast("Card"),
        .loop_type = @constCast("goalBased"),
        .state = @constCast("running"),
        .presence = @constCast("busy"),
        .activity = @constCast(""),
        .backend = @constCast("copilotCLI"),
        .model_tier = @constCast("capable"),
        .token_usage = 12_345,
    };
    const meta = try nodeMetadata(std.testing.allocator, node, node.worktree_branch, 0);
    defer std.testing.allocator.free(meta);
    try std.testing.expectEqualStrings("Goal · Copilot CLI", meta);
}

test "loop card parity existing actions stay above the bottom meta row" {
    for ([_]f32{ 0.55, 0.75, 1, 1.25, 1.8 }) |zoom| {
        var state = try cardTestState(.{ .zoom = zoom, .pan_x = 1200, .pan_y = -20 });
        defer state.deinitLayout();
        const bounds = nodeBounds(0, &state);
        const meta_top = bounds.bottom - scaledValue(21, zoom);
        const action = attentionActionBounds(bounds, &state);
        const offer = reclaimOfferBounds(bounds);
        try std.testing.expect(action.bottom <= meta_top);
        try std.testing.expect(offer.reclaim.bottom <= meta_top);
        try std.testing.expect(offer.keep.bottom <= meta_top);
        try std.testing.expect(offer.reclaim.right < offer.keep.left);
        try std.testing.expect(offer.keep.right < action.left);
    }
}

fn parityTestNode() GraphModel.Node {
    return .{
        .id = @constCast("parity-card"),
        .title = @constCast("A long title that must yield to the state pill"),
        .loop_type = @constCast("goalBased"),
        .state = @constCast("running"),
        .presence = @constCast("busy"),
        .activity = @constCast("checking tests"),
        .backend = @constCast("copilotCLI"),
        .created_at = 0,
    };
}

test "card live detail 764 Unicode whitespace activity falls back to each handed line" {
    var node = parityTestNode();
    node.activity = @constCast("\u{a0}\u{2003}\u{2028}\u{3000}");
    node.metric_passes = 4;
    node.goal_summary = @constCast(" Ship\n the fixture ");
    node.trigger_prompt = @constCast(" Run\t the check ");
    node.check_description = @constCast(" Review\r\n the output ");
    node.first_instruction = @constCast(" Inspect\u{a0} the graph ");
    node.pilot_state = @constCast("armed");
    node.subgraph_json = @constCast("{\"nodes\":[{}]}");
    for ([_][2][]const u8{
        .{ "goalBased", "Ship the fixture" },
        .{ "timeBased", "Run the check" },
        .{ "turnBased", "Review the output" },
        .{ "sketch", "Inspect the graph" },
        .{ "composite", "1 loop · Armed" },
    }) |sample| {
        node.loop_type = @constCast(sample[0]);
        const live = try cardLiveLine(std.testing.allocator, node);
        defer std.testing.allocator.free(live);
        try std.testing.expectEqualStrings(sample[1], live);
    }
}

test "card live detail 764 whole metric readings keep macOS precision up to a billion" {
    var node = parityTestNode();
    node.metric_direction = @constCast("minimize");
    node.metric_sample_count = 2;
    node.metric_samples[0] = 2_000_000;
    node.metric_samples[1] = 1_000_000;
    const detail = try cardMetricDetail(std.testing.allocator, node);
    defer std.testing.allocator.free(detail);
    try std.testing.expectEqualStrings("2000000 → 1000000 · 50% better", detail);
    node.metric_samples[0] = 0.5;
    node.metric_samples[1] = 1;
    node.metric_direction = @constCast("maximize");
    const fractional = try cardMetricDetail(std.testing.allocator, node);
    defer std.testing.allocator.free(fractional);
    try std.testing.expectEqualStrings("0.50 → 1.00 · 50% better", fractional);
}

test "card live detail 764 metric evidence covers absent flat better worse and negative readings" {
    var node = parityTestNode();
    node.metric_direction = @constCast("maximize");
    for ([_]u8{ 0, 1 }) |count| {
        node.metric_sample_count = count;
        const detail = try cardMetricDetail(std.testing.allocator, node);
        defer std.testing.allocator.free(detail);
        try std.testing.expectEqualStrings("", detail);
    }
    node.metric_sample_count = 2;
    for ([_]struct { first: f64, last: f64, direction: []const u8, expected: []const u8, fraction: f64 }{
        .{ .first = 0, .last = 0, .direction = "maximize", .expected = "0 → 0 · flat", .fraction = 0 },
        .{ .first = 41, .last = 41, .direction = "minimize", .expected = "41 → 41 · flat", .fraction = 0 },
        .{ .first = 1.42, .last = 1.10, .direction = "minimize", .expected = "1.42 → 1.10 · 23% better", .fraction = 0.32 / 1.42 },
        .{ .first = 1.42, .last = 1.10, .direction = "maximize", .expected = "1.42 → 1.10 · 23% worse", .fraction = 0 },
        .{ .first = -1, .last = 1, .direction = "maximize", .expected = "-1 → 1 · 200% better", .fraction = 1 },
        .{ .first = 1, .last = -1, .direction = "maximize", .expected = "1 → -1 · 200% worse", .fraction = 0 },
    }) |sample| {
        node.metric_samples[0] = sample.first;
        node.metric_samples[1] = sample.last;
        node.metric_direction = @constCast(sample.direction);
        const detail = try cardMetricDetail(std.testing.allocator, node);
        defer std.testing.allocator.free(detail);
        try std.testing.expectEqualStrings(sample.expected, detail);
        try std.testing.expectApproxEqAbs(sample.fraction, std.math.clamp(cardMetricRatio(node), 0, 1), 0.000001);
    }
    node.metric_direction = @constCast("");
    const absent = try cardMetricDetail(std.testing.allocator, node);
    defer std.testing.allocator.free(absent);
    try std.testing.expectEqualStrings("", absent);
}

fn cardLiveDetailMetricNode() GraphModel.Node {
    var node = parityTestNode();
    node.metric_direction = @constCast("minimize");
    node.metric_sample_count = 2;
    node.metric_samples[0] = 1.42;
    node.metric_samples[1] = 1.10;
    return node;
}

test "card live detail 764 production fixtures contain real trends and human-action controls" {
    var fixture = try paint764FixtureModel(std.testing.allocator, .overview);
    defer fixture.model.deinit();
    const graph = fixture.model.graphs.items[0];
    const goal = graph.nodes.items[1];
    const turn = graph.nodes.items[3];
    const asking = graph.nodes.items[5];
    const peer = fixture.model.graphs.items[1].nodes.items[0];
    for ([_]struct { node: GraphModel.Node, expected: []const u8 }{
        .{ .node = goal, .expected = "41 → 30 · 27% better" },
        .{ .node = turn, .expected = "0.50 → 1.00 · 50% better" },
        .{ .node = asking, .expected = "10 → 5 · 50% better" },
        .{ .node = peer, .expected = "1.42 → 1.10 · 23% better" },
    }) |sample| {
        const detail = try cardMetricDetail(std.testing.allocator, sample.node);
        defer std.testing.allocator.free(detail);
        try std.testing.expectEqualStrings(sample.expected, detail);
    }
    try std.testing.expectEqual(AttentionAction.reply, primaryCardAction(asking).?);
    const live = try cardLiveLine(std.testing.allocator, turn);
    defer std.testing.allocator.free(live);
    try std.testing.expectEqualStrings("pass 2 · Rendering synthetic content", live);
}

test "card live detail 764 attention alone does not hide a real metric" {
    var node = cardLiveDetailMetricNode();
    node.state = @constCast("failed");
    node.presence = @constCast("");
    var dib = try ParityDib.init(320, 160);
    defer dib.deinit();
    const bounds = rect(20, 20, 270, 116);
    const rows = cardTextLayout(bounds, 1, 80);
    fill(dib.dc, rect(0, 0, 320, 160), Tokens.loop_card_bottom);
    try drawCardBody(dib.dc, std.testing.allocator, node, bounds, 1, .interior, true, null, null);
    const track = rect(rows.detail.left, rows.detail.bottom - 3, rows.detail.right, rows.detail.bottom);
    try std.testing.expect(dib.count(track, loopTypeColor(node.loop_type)) > 0);
    try std.testing.expect(dib.count(track, 0x00444141) > 0);
}

test "card live detail 764 human action suppresses progress without attention warmth" {
    var node = cardLiveDetailMetricNode();
    node.state = @constCast("blocked");
    var dib = try ParityDib.init(320, 160);
    defer dib.deinit();
    const bounds = rect(20, 20, 270, 116);
    const rows = cardTextLayout(bounds, 1, 80);
    fill(dib.dc, rect(0, 0, 320, 160), Tokens.loop_card_bottom);
    try drawCardBody(dib.dc, std.testing.allocator, node, bounds, 1, .interior, false, .inspect, null);
    try std.testing.expectEqual(@as(usize, 0), dib.count(rows.detail, 0x00444141));
    try std.testing.expectEqual(@as(usize, 0), dib.count(rows.detail, loopTypeColor(node.loop_type)));
}

test "card live detail 764 no history one reading missing direction and reclaim do not invent bars" {
    var node = cardLiveDetailMetricNode();
    var dib = try ParityDib.init(320, 160);
    defer dib.deinit();
    const bounds = rect(20, 20, 270, 116);
    const rows = cardTextLayout(bounds, 1, 80);
    for ([_]struct { count: u8, direction: []const u8, reclaim: bool }{
        .{ .count = 0, .direction = "minimize", .reclaim = false },
        .{ .count = 1, .direction = "minimize", .reclaim = false },
        .{ .count = 2, .direction = "", .reclaim = false },
        .{ .count = 2, .direction = "minimize", .reclaim = true },
    }) |sample| {
        node.metric_sample_count = sample.count;
        node.metric_direction = @constCast(sample.direction);
        fill(dib.dc, rect(0, 0, 320, 160), Tokens.loop_card_bottom);
        try drawCardBody(dib.dc, std.testing.allocator, node, bounds, 1, .interior, false, null, if (sample.reclaim) .{ .default_branch = "main" } else null);
        try std.testing.expectEqual(@as(usize, 0), dib.count(rows.detail, 0x00444141));
        try std.testing.expectEqual(@as(usize, 0), dib.count(rows.detail, loopTypeColor(node.loop_type)));
    }
}

test "card live detail 764 malformed live text and nonfinite metrics report errors" {
    var node = cardLiveDetailMetricNode();
    node.activity = @constCast("\xff");
    try std.testing.expectError(error.InvalidUtf8, cardLiveLine(std.testing.allocator, node));
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |invalid| {
        node.metric_samples[1] = invalid;
        try std.testing.expectError(error.InvalidCardMetric, cardMetricDetail(std.testing.allocator, node));
    }
}

test "card live detail 764 change is right aligned and track is three logical points" {
    const node = cardLiveDetailMetricNode();
    for ([_]f32{ 0.75, 1, 1.5 }) |zoom| {
        var dib = try ParityDib.init(480, 240);
        defer dib.deinit();
        const bounds = rect(20, 20, 20 + scaledValue(250, zoom), 20 + scaledValue(96, zoom));
        const rows = cardTextLayout(bounds, zoom, scaledValue(80, zoom));
        fill(dib.dc, rect(0, 0, 480, 240), Tokens.loop_card_bottom);
        try drawCardBody(dib.dc, std.testing.allocator, node, bounds, zoom, .interior, false, null, null);
        const old = try selectCardFont(dib.dc, 10.5 * zoom, .card_mono);
        defer _ = c.SelectObject(dib.dc, old);
        const change_width = try measuredText(dib.dc, std.testing.allocator, "23% better");
        const change = rect(rows.detail.right - change_width, rows.detail.top, rows.detail.right, rows.detail.bottom - scaledValue(4, zoom));
        var reference = try ParityDib.init(480, 240);
        defer reference.deinit();
        fill(reference.dc, rect(0, 0, 480, 240), Tokens.loop_card_bottom);
        try drawCardText(reference.dc, std.testing.allocator, "23% better", change, 10.5 * zoom, .card_mono, 0x009F9C9C, true);
        var expected_ink: usize = 0;
        var y = change.top;
        while (y < change.bottom) : (y += 1) {
            var x = change.left;
            while (x < change.right) : (x += 1) {
                const expected = c.GetPixel(reference.dc, x, y);
                try std.testing.expect(expected != c.CLR_INVALID);
                try std.testing.expectEqual(expected, c.GetPixel(dib.dc, x, y));
                if (expected != Tokens.loop_card_bottom) expected_ink += 1;
            }
        }
        try std.testing.expect(expected_ink > 0);
        const track_top = rows.detail.bottom - scaledValue(3, zoom);
        try std.testing.expectEqual(@as(usize, @intCast(rows.detail.right - rows.detail.left)),
            dib.count(rect(rows.detail.left, track_top, rows.detail.right, track_top + 1), 0x00444141) +
                dib.count(rect(rows.detail.left, track_top, rows.detail.right, track_top + 1), loopTypeColor(node.loop_type)));
    }
}

test "loop card parity metrics and rows fit the owning card" {
    const dc = c.CreateCompatibleDC(null) orelse return error.TestDcCreationFailed;
    defer _ = c.DeleteDC(dc);
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"A","name":"A"},"nodes":[{"id":"a","title":"A"},{"id":"b","title":"B"},{"id":"c","title":"C"},{"id":"d","title":"D"},{"id":"e","title":"E"},{"id":"f","title":"F"}],"edges":[]}}
    );
    for ([_]f32{ 0.55, 0.75, 1, 1.25, 1.8 }) |zoom| {
        var state = try modelTestState(&model, .{ .zoom = zoom, .pan_x = 1300, .pan_y = -17 }, rect(220, 34, 1200, 900));
        defer state.deinitLayout();
        const project = nodeBounds(0, &state);
        const overview = overviewCardBounds(&model, 0, 0, rect(220, 34, 1200, 900), &state);
        for ([_][]const u8{ "NEEDS YOU", "SCHEDULED" }) |word| {
            const old = try selectCardFont(dc, 10 * zoom, .card_state);
            defer _ = c.SelectObject(dc, old);
            const pill_width = try measuredText(dc, std.testing.allocator, word) + scaledValue(22, zoom);
            for ([_]c.RECT{ project, overview }) |bounds| {
                const rows = cardTextLayout(bounds, zoom, pill_width);
                for ([_]c.RECT{ rows.title, rows.pill, rows.live, rows.detail, rows.meta }) |row| {
                    try std.testing.expect(row.left >= bounds.left + scaledValue(11, zoom));
                    try std.testing.expect(row.right <= bounds.right - scaledValue(11, zoom));
                    try std.testing.expect(row.top >= bounds.top + scaledValue(8, zoom));
                    try std.testing.expect(row.bottom <= bounds.bottom - scaledValue(8, zoom));
                    try std.testing.expect(row.right > row.left and row.bottom > row.top);
                }
                try std.testing.expect(rows.title.right < rows.pill.left);
                try std.testing.expect(rows.title.bottom < rows.live.top);
                try std.testing.expect(rows.live.bottom < rows.detail.top);
                try std.testing.expect(rows.detail.bottom < rows.meta.top);
            }
        }
        const adjacent = overviewCardBounds(&model, 0, 5, rect(220, 34, 1200, 900), &state);
        const next_row = overviewCardBounds(&model, 0, 1, rect(220, 34, 1200, 900), &state);
        try std.testing.expect(overview.right < adjacent.left);
        try std.testing.expect(overview.bottom < next_row.top);
    }
}

test "loop card parity overview narrow client retains action hits and pannable card extents" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"A","name":"Alpha"},"nodes":[{"id":"a","title":"A"},{"id":"b","title":"B"},{"id":"c","title":"C"},{"id":"d","title":"D"}],"edges":[]}}}
    );
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"project":{"path":"B","name":"Beta"},"nodes":[{"id":"e","title":"E"}],"edges":[]}}}
    );
    var identity = CanvasState{};
    defer identity.deinitLayout();
    try identity.syncLayout(allocator, &model, rect(220, 34, 1028, 900), &.{}, &.{});
    try std.testing.expectEqual(@as(i32, 1682), contentSize(&model, .overview, &identity).width);
    for ([_]i32{ 1028, 1440 }) |right| {
        const viewport = rect(220, 34, right, 900);
        for ([_]CanvasState{ .{}, .{ .zoom = 0.75, .pan_x = 15, .pan_y = -12 }, .{ .zoom = 1.25, .pan_x = -120, .pan_y = 20 } }) |initial| {
            var state = try modelTestState(&model, initial, viewport);
            defer state.deinitLayout();
            const lane = overviewLaneBounds(&model, 0, viewport, &state);
            const next_lane = overviewLaneBounds(&model, 1, viewport, &state);
            const first = overviewCardBounds(&model, 0, 0, viewport, &state);
            const second = overviewCardBounds(&model, 0, 1, viewport, &state);
            const third = overviewCardBounds(&model, 0, 2, viewport, &state);
            const fourth = overviewCardBounds(&model, 0, 3, viewport, &state);
            try std.testing.expect(first.left == second.left and second.left == third.left);
            try std.testing.expect(first.bottom < second.top and second.bottom < third.top);
            try std.testing.expect(first.bottom < fourth.top and fourth.bottom < lane.bottom);
            try std.testing.expect(third.right < lane.right and lane.bottom < next_lane.top);
        }
    }
    const narrow = rect(220, 34, 1028, 900);
    const caption = overviewLaneCaption(&model, 0, narrow, &identity);
    try std.testing.expectEqualDeep(rect(1690, 106, 1746, 126), caption.open);
    try std.testing.expectEqualDeep(rect(1750, 106, 1804, 126), caption.worktrees);
    try std.testing.expect(caption.worktrees.left > narrow.right);
    var panned = try modelTestState(&model, .{ .pan_x = -800 }, narrow);
    defer panned.deinitLayout();
    const shifted = overviewLaneCaption(&model, 0, narrow, &panned);
    const third = overviewCardBounds(&model, 0, 2, narrow, &panned);
    try std.testing.expect(shifted.worktrees.right <= narrow.right);
    try std.testing.expect(third.right <= narrow.right);
    try std.testing.expectEqual(OverviewLaneAction.inspect_worktrees, overviewLaneActionAt(&model, 0, shifted.worktrees.left + 1, shifted.worktrees.top + 1, narrow, &panned).?);
}

test "loop card parity live and meta content and duration boundaries" {
    const allocator = std.testing.allocator;
    var node = parityTestNode();
    node.activity = @constCast(" \tchecking \r\n tests  ");
    node.goal_summary = @constCast("ignored goal");
    node.metric_passes = 4;
    const live = try cardLiveLine(allocator, node);
    defer allocator.free(live);
    try std.testing.expectEqualStrings("pass 4 · checking tests", live);
    node.activity = @constCast("");
    node.created_at = null;
    node.backend = @constCast("claudeCode");
    for ([_][2][]const u8{
        .{ "sketch", "Main" },    .{ "goalBased", "Goal" },      .{ "timeBased", "Timed" },
        .{ "turnBased", "Turn" }, .{ "composite", "Composite" },
    }) |kind| {
        node.loop_type = @constCast(kind[0]);
        const meta = try nodeMetadata(allocator, node, "", 0);
        defer allocator.free(meta);
        try std.testing.expectEqualStrings(kind[1], meta);
    }
    for ([_]struct { kind: []const u8, expected: []const u8 }{
        .{ .kind = "goalBased", .expected = "ignored goal" },
        .{ .kind = "timeBased", .expected = "Run on schedule" },
        .{ .kind = "turnBased", .expected = "Pause for approval" },
        .{ .kind = "composite", .expected = "Piloted" },
    }) |sample| {
        node.loop_type = @constCast(sample.kind);
        node.trigger_prompt = @constCast("Run on schedule");
        node.check_description = @constCast("Pause for approval");
        node.pilot_state = @constCast("piloted");
        const fallback = try cardLiveLine(allocator, node);
        defer allocator.free(fallback);
        try std.testing.expectEqualStrings(sample.expected, fallback);
    }
    node.subgraph_json = @constCast("{\"nodes\":[{},{}]}");
    const composite = try cardLiveLine(allocator, node);
    defer allocator.free(composite);
    try std.testing.expectEqualStrings("2 loops · Piloted", composite);
    node.subgraph_json = @constCast("");
    node.loop_type = @constCast("sketch");
    node.first_instruction = @constCast(" First\ninstruction ");
    const handed = try cardLiveLine(allocator, node);
    defer allocator.free(handed);
    try std.testing.expectEqualStrings("First instruction", handed);
    node.created_at = 1000;
    for ([_]struct { age: u64, text: []const u8 }{
        .{ .age = 0, .text = "Main · 0s" },     .{ .age = 59, .text = "Main · 59s" },
        .{ .age = 60, .text = "Main · 1m" },    .{ .age = 3599, .text = "Main · 59m" },
        .{ .age = 3600, .text = "Main · 1h" },  .{ .age = 3660, .text = "Main · 1h 1m" },
        .{ .age = 86400, .text = "Main · 1d" }, .{ .age = 93600, .text = "Main · 1d 2h" },
    }) |sample| {
        const meta = try nodeMetadata(allocator, node, "", 1000 + sample.age);
        defer allocator.free(meta);
        try std.testing.expectEqualStrings(sample.text, meta);
    }
    node.created_at = null;
    for ([_][2][]const u8{
        .{ "copilotCLI", "Copilot CLI" }, .{ "codex", "Codex" }, .{ "openCode", "OpenCode" },
        .{ "pi", "Pi" },                  .{ "nod", "Nod" },     .{ "futureBackend", "futureBackend" },
    }) |backend| {
        try std.testing.expectEqualStrings(backend[1], cardBackendName(backend[0]));
    }
    node.metric_sample_count = 2;
    node.metric_samples[0] = 1;
    node.metric_samples[1] = 3;
    node.metric_direction = @constCast("maximize");
    const rising = try cardMetricDetail(allocator, node);
    defer allocator.free(rising);
    try std.testing.expectEqualStrings("1 → 3 · 67% better", rising);
    node.metric_samples[0] = 3;
    node.metric_samples[1] = 1;
    node.metric_direction = @constCast("minimize");
    const falling = try cardMetricDetail(allocator, node);
    defer allocator.free(falling);
    try std.testing.expectEqualStrings("3 → 1 · 67% better", falling);
    node.metric_sample_count = 0;
    const absent = try cardMetricDetail(allocator, node);
    defer allocator.free(absent);
    try std.testing.expectEqual(@as(usize, 0), absent.len);
}

test "loop card parity pill words indicators and source colors" {
    var node = parityTestNode();
    node.presence = @constCast("");
    for ([_]struct { state: []const u8, word: []const u8, hollow: bool, tint: u32 }{
        .{ .state = "idle", .word = "IDLE", .hollow = false, .tint = 0 },
        .{ .state = "running", .word = "RUNNING", .hollow = false, .tint = 0x00FF840A },
        .{ .state = "waiting", .word = "WAITING", .hollow = true, .tint = 0x00FF840A },
        .{ .state = "awaitingInput", .word = "NEEDS YOU", .hollow = false, .tint = 0x000A9FFF },
        .{ .state = "blocked", .word = "BLOCKED", .hollow = true, .tint = 0x000A9FFF },
        .{ .state = "succeeded", .word = "DONE", .hollow = false, .tint = 0x0058D130 },
        .{ .state = "failed", .word = "FAILED", .hollow = false, .tint = 0x003A45FF },
        .{ .state = "stalled", .word = "STALLED", .hollow = false, .tint = 0x00F25ABF },
        .{ .state = "stopped", .word = "STOPPED", .hollow = true, .tint = 0 },
    }) |sample| {
        node.state = @constCast(sample.state);
        const presentation = cardState(node);
        try std.testing.expectEqualStrings(sample.word, presentation.word);
        try std.testing.expectEqual(sample.hollow, presentation.hollow);
        if (sample.tint != 0) try std.testing.expectEqual(sample.tint, presentation.tint);
        try std.testing.expect(presentation.fill != presentation.ink);
        try std.testing.expect(presentation.fill != presentation.tint);
        try std.testing.expectEqual(std.mem.eql(u8, sample.state, "blocked"), presentation.stroke != null);
    }
    for ([_][]const u8{ "succeeded", "blocked", "running" }) |stored| {
        node.state = @constCast(stored);
        node.presence = @constCast("awaitingInput");
        try std.testing.expectEqualStrings("NEEDS YOU", cardState(node).word);
    }
    node.state = @constCast("running");
    node.presence = @constCast("idle");
    try std.testing.expectEqualStrings("IDLE", cardState(node).word);
    node.loop_type = @constCast("timeBased");
    try std.testing.expectEqualStrings("SCHEDULED", cardState(node).word);
    node.presence = @constCast("busy");
    try std.testing.expectEqualStrings("RUNNING", cardState(node).word);
}

fn parityOwnedTextExercise(allocator: std.mem.Allocator, dc: c.HDC) !void {
    var node = parityTestNode();
    const long_activity = try std.mem.join(allocator, " ", &.{ "工具 🧪 activity" ** 30, "tail" });
    defer allocator.free(long_activity);
    node.activity = long_activity;
    node.metric_passes = 4;
    const live = try cardLiveLine(allocator, node);
    defer allocator.free(live);
    try std.testing.expect(live.len > 256 and std.mem.endsWith(u8, live, "tail"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(live));
    const branch = try std.mem.concat(allocator, u8, &.{ "feature/工具/", "long/" ** 40, "🧪/tail" });
    defer allocator.free(branch);
    node.worktree_branch = branch;
    const full = try nodeMetadata(allocator, node, node.worktree_branch, 93600);
    defer allocator.free(full);
    try std.testing.expect(std.mem.indexOf(u8, full, branch) != null);
    try std.testing.expect(full.len > 128);
    const meta = try cardMetaForWidth(dc, allocator, node, 93600, 218);
    defer allocator.free(meta);
    try std.testing.expect(std.mem.startsWith(u8, meta, "Goal · f"));
    try std.testing.expect(std.mem.endsWith(u8, meta, "tail · Copilot CLI · 1d 2h") or std.mem.endsWith(u8, meta, "l · Copilot CLI · 1d 2h"));
    try std.testing.expect(std.mem.indexOf(u8, meta, "…") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(meta));
    try std.testing.expect(try measuredText(dc, allocator, meta) <= 218);
    node.metric_sample_count = 2;
    node.metric_direction = @constCast("maximize");
    node.metric_samples[0] = 0.125;
    node.metric_samples[1] = 1e150;
    const metric = try cardMetricDetail(allocator, node);
    defer allocator.free(metric);
    try std.testing.expect(metric.len > 128);
    try std.testing.expect(std.mem.endsWith(u8, metric, "100% better"));
    var compact = parityTestNode();
    compact.loop_type = @constCast("composite");
    compact.worktree_branch = @constCast("main");
    for ([_]i32{ 218, 200 }) |width| {
        const short = try cardMetaForWidth(dc, allocator, compact, 3900, width);
        defer allocator.free(short);
        try std.testing.expect(try measuredText(dc, allocator, short) <= width);
        try std.testing.expect(std.mem.endsWith(u8, short, "Copilot CLI · 1h 5m"));
    }
}

test "loop card parity long Unicode text measured middle elision and allocation cleanup" {
    const dc = c.CreateCompatibleDC(null) orelse return error.TestDcCreationFailed;
    defer _ = c.DeleteDC(dc);
    const old = try selectCardFont(dc, 10.5, .card_mono);
    defer _ = c.SelectObject(dc, old);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parityOwnedTextExercise, .{dc});
    var node = parityTestNode();
    node.backend = @constCast("a backend identifier too wide to fit without lying");
    try std.testing.expectError(error.CardMetadataTooWide, cardMetaForWidth(dc, std.testing.allocator, node, 93600, 218));
}

const ParityDib = struct {
    dc: c.HDC,
    bitmap: c.HBITMAP,
    old_bitmap: c.HGDIOBJ,
    pixels: [*]u8,
    width: usize,
    height: usize,
    row_bytes: usize,
    byte_len: usize,

    fn init(width: i32, height: i32) !ParityDib {
        if (width <= 0 or height <= 0) return error.TestBitmapDimensionsInvalid;
        const width_usize: usize = @intCast(width);
        const height_usize: usize = @intCast(height);
        if (width_usize > std.math.maxInt(usize) / 4) return error.TestBitmapDimensionsOverflow;
        const row_bytes = width_usize * 4;
        if (height_usize > std.math.maxInt(usize) / row_bytes) return error.TestBitmapDimensionsOverflow;
        const byte_len = row_bytes * height_usize;
        if (byte_len > std.math.maxInt(u32)) return error.TestBitmapTooLarge;
        const dc = c.CreateCompatibleDC(null) orelse return error.TestDcCreationFailed;
        errdefer _ = c.DeleteDC(dc);
        var info = std.mem.zeroes(c.BITMAPINFO);
        info.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
        info.bmiHeader.biWidth = width;
        info.bmiHeader.biHeight = -height;
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = c.BI_RGB;
        info.bmiHeader.biSizeImage = @intCast(byte_len);
        var bits: ?*anyopaque = null;
        const bitmap = c.CreateDIBSection(dc, &info, c.DIB_RGB_COLORS, &bits, null, 0) orelse return error.TestBitmapCreationFailed;
        errdefer _ = c.DeleteObject(bitmap);
        const pixel_storage = bits orelse return error.TestBitmapBitsUnavailable;
        const old_bitmap = c.SelectObject(dc, bitmap) orelse return error.TestBitmapSelectionFailed;
        if (@intFromPtr(old_bitmap) == std.math.maxInt(usize)) return error.TestBitmapSelectionFailed;
        return .{
            .dc = dc,
            .bitmap = bitmap,
            .old_bitmap = old_bitmap,
            .pixels = @ptrCast(@alignCast(pixel_storage)),
            .width = width_usize,
            .height = height_usize,
            .row_bytes = row_bytes,
            .byte_len = byte_len,
        };
    }

    fn deinit(self: ParityDib) void {
        _ = c.SelectObject(self.dc, self.old_bitmap);
        _ = c.DeleteObject(self.bitmap);
        _ = c.DeleteDC(self.dc);
    }

    fn count(self: ParityDib, bounds: c.RECT, color: u32) usize {
        var result: usize = 0;
        var y = bounds.top;
        while (y < bounds.bottom) : (y += 1) {
            var x = bounds.left;
            while (x < bounds.right) : (x += 1) {
                if (c.GetPixel(self.dc, x, y) == color) result += 1;
            }
        }
        return result;
    }

    fn rgbSha256(self: ParityDib, allocator: std.mem.Allocator) ![32]u8 {
        if (c.GdiFlush() == 0) return error.PaintFixtureFlushFailed;
        const pixel_count = self.width * self.height;
        const rgb_len = pixel_count * 3;
        const rgb = try allocator.alloc(u8, rgb_len);
        defer allocator.free(rgb);
        var destination: usize = 0;
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const source = y * self.row_bytes + x * 4;
                rgb[destination] = self.pixels[source + 2];
                rgb[destination + 1] = self.pixels[source + 1];
                rgb[destination + 2] = self.pixels[source];
                destination += 3;
            }
        }
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(rgb, &digest, .{});
        return digest;
    }

    fn nonBackgroundPixels(self: ParityDib, colorref: u32) usize {
        const red: u8 = @truncate(colorref);
        const green: u8 = @truncate(colorref >> 8);
        const blue: u8 = @truncate(colorref >> 16);
        var result: usize = 0;
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const offset = y * self.row_bytes + x * 4;
                if (self.pixels[offset] != blue or self.pixels[offset + 1] != green or self.pixels[offset + 2] != red)
                    result += 1;
            }
        }
        return result;
    }

    fn writeBmp(self: ParityDib, allocator: std.mem.Allocator, path: []const u8) ![32]u8 {
        if (c.GdiFlush() == 0) return error.PaintFixtureFlushFailed;
        const header_len: usize = 54;
        const file_len = header_len + self.byte_len;
        if (file_len > std.math.maxInt(u32)) return error.TestBitmapTooLarge;
        const bytes = try allocator.alloc(u8, file_len);
        defer allocator.free(bytes);
        @memset(bytes, 0);
        bytes[0] = 'B';
        bytes[1] = 'M';
        putU32(bytes, 2, @intCast(file_len));
        putU32(bytes, 10, @intCast(header_len));
        putU32(bytes, 14, 40);
        putU32(bytes, 18, @intCast(self.width));
        putU32(bytes, 22, @intCast(self.height));
        putU16(bytes, 26, 1);
        putU16(bytes, 28, 32);
        putU32(bytes, 30, c.BI_RGB);
        putU32(bytes, 34, @intCast(self.byte_len));
        putU32(bytes, 38, 3780);
        putU32(bytes, 42, 3780);
        for (0..self.height) |file_y| {
            const source_y = self.height - file_y - 1;
            for (0..self.width) |x| {
                const source = source_y * self.row_bytes + x * 4;
                const destination = header_len + file_y * self.row_bytes + x * 4;
                bytes[destination] = self.pixels[source];
                bytes[destination + 1] = self.pixels[source + 1];
                bytes[destination + 2] = self.pixels[source + 2];
                bytes[destination + 3] = 0xFF;
            }
        }
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        var file = try std.fs.cwd().createFile(path, .{ .exclusive = true });
        defer file.close();
        try file.writeAll(bytes);
        return digest;
    }
};

fn putU16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}

fn putU32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
    bytes[offset + 3] = @truncate(value >> 24);
}

const PaintExportFixture = struct {
    model: GraphModel.Model,
    sha256: [std.crypto.hash.sha2.Sha256.digest_length]u8,
};

const Paint764Scene = enum { project, overview };

const Paint764Fixture = struct {
    model: GraphModel.Model,
    project_sha256: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    peer_sha256: ?[std.crypto.hash.sha2.Sha256.digest_length]u8,
};

fn paintExportFixtureModel(allocator: std.mem.Allocator) !PaintExportFixture {
    var model = GraphModel.Model.init(allocator);
    errdefer model.deinit();
    const fixture = try std.fs.cwd().readFileAlloc(allocator, "fixtures\\paint-project-v1.json", 64 * 1024);
    defer allocator.free(fixture);
    var fixture_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fixture, &fixture_digest, .{});
    _ = try model.updateFromFrame(fixture);
    if (!model.setSelectedIndex(0)) return error.PaintFixtureSelectionFailed;
    const graph = model.graph orelse return error.PaintFixtureGraphMissing;
    if (graph.nodes.items.len != 2 or graph.edges.items.len != 1 or model.activity.items.len != 0)
        return error.PaintFixtureModelMismatch;
    for (graph.nodes.items) |node| {
        if (node.created_at != null) return error.PaintFixtureHasTimestamp;
        if (!std.mem.eql(u8, node.state, "idle")) return error.PaintFixtureStateMismatch;
    }
    if (!std.mem.eql(u8, graph.nodes.items[0].title, "Goal") or
        !std.mem.eql(u8, graph.nodes.items[1].title, "Check") or
        !std.mem.eql(u8, graph.nodes.items[0].goal_summary, "Keep README present.") or
        !std.mem.eql(u8, graph.nodes.items[1].check_description, "Check formatting.") or
        !std.mem.eql(u8, graph.edges.items[0].condition, "always") or
        !std.mem.eql(u8, graph.edges.items[0].kind, "handoff"))
    {
        return error.PaintFixtureTextMismatch;
    }
    return .{ .model = model, .sha256 = fixture_digest };
}

fn paint764FixtureModel(allocator: std.mem.Allocator, scene: Paint764Scene) !Paint764Fixture {
    var model = GraphModel.Model.init(allocator);
    errdefer model.deinit();

    const project_bytes = try std.fs.cwd().readFileAlloc(
        allocator,
        "fixtures\\paint-764-project.json",
        64 * 1024,
    );
    defer allocator.free(project_bytes);
    var project_sha256: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(project_bytes, &project_sha256, .{});
    _ = try model.updateFromFrame(project_bytes);
    if (!model.setSelectedIndex(0)) return error.Paint764ProjectSelectionFailed;

    var peer_sha256: ?[std.crypto.hash.sha2.Sha256.digest_length]u8 = null;
    if (scene == .overview) {
        const peer_bytes = try std.fs.cwd().readFileAlloc(
            allocator,
            "fixtures\\paint-764-overview-peer.json",
            64 * 1024,
        );
        defer allocator.free(peer_bytes);
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(peer_bytes, &digest, .{});
        peer_sha256 = digest;
        _ = try model.updateFromFrame(peer_bytes);
    }

    const project = model.graphFor("C:\\GraphCodeFixture\\CardStates") orelse
        return error.Paint764ProjectMissing;
    if (project.nodes.items.len != 6 or project.edges.items.len != 3)
        return error.Paint764ProjectInventoryMismatch;
    if (scene == .overview and model.graphs.items.len != 2)
        return error.Paint764OverviewInventoryMismatch;
    return .{
        .model = model,
        .project_sha256 = project_sha256,
        .peer_sha256 = peer_sha256,
    };
}

fn paintExportFixture(
    dib: ParityDib,
    model: *const GraphModel.Model,
    allocator: std.mem.Allocator,
    surface: Surface,
    header_context: []const u8,
) !void {
    if (c.SetMapMode(dib.dc, c.MM_ANISOTROPIC) == 0) return error.PaintFixtureMapModeFailed;
    if (c.SetWindowExtEx(dib.dc, 96, 96, null) == 0 or c.SetViewportExtEx(dib.dc, 96, 96, null) == 0)
        return error.PaintFixtureDpiMappingFailed;
    var state = try modelTestState(model, .{ .zoom = if (std.mem.eql(u8, header_context, "Alpha")) 1 else paint764_zoom }, chrome764GraphBounds());
    defer state.deinitLayout();
    var sidebar_state = Sidebar.State.init(allocator);
    defer sidebar_state.deinit();
    const controls = WorkspaceControls.State{
        .graph_visible = true,
        .rail_visible = true,
        .panel_visible = false,
        .activity_enabled = false,
    };
    paint(
        dib.dc,
        1280,
        720,
        model,
        null,
        "",
        0,
        "",
        "",
        "",
        false,
        "",
        &.{},
        &.{},
        allocator,
        &state,
        &sidebar_state,
        -1,
        controls,
        surface,
    );
    paintHeader(
        dib.dc,
        allocator,
        1280,
        "",
        .{ .title = "GraphCode", .context = header_context, .panel_visible = false },
        null,
    );
    if (c.GdiFlush() == 0) return error.PaintFixtureFlushFailed;
}

const PaintFontFact = struct {
    actual_face: []u8,
    height: i32,
    weight: i32,
};

fn inspectPaintFont(
    allocator: std.mem.Allocator,
    dc: c.HDC,
    font: c.HFONT,
    expected_face: []const u8,
    expected_height: i32,
    expected_weight: i32,
) !PaintFontFact {
    const font_handle = font orelse return error.PaintFontCreationFailed;
    var info = std.mem.zeroes(c.LOGFONTW);
    if (c.GetObjectW(font_handle, @intCast(@sizeOf(c.LOGFONTW)), &info) != @as(c.INT, @intCast(@sizeOf(c.LOGFONTW))))
        return error.PaintFontInformationUnavailable;
    if (info.lfHeight != expected_height or info.lfWeight != expected_weight or info.lfQuality != c.CLEARTYPE_QUALITY)
        return error.PaintFontConfigurationMismatch;

    const previous = c.SelectObject(dc, font_handle) orelse return error.PaintFontSelectionFailed;
    if (@intFromPtr(previous) == std.math.maxInt(usize)) return error.PaintFontSelectionFailed;
    defer _ = c.SelectObject(dc, previous);
    var face: [32]u16 = [_]u16{0} ** 32;
    if (c.GetTextFaceW(dc, @intCast(face.len), &face) <= 0) return error.PaintFontFaceUnavailable;
    const actual_face = try std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.sliceTo(&face, 0));
    errdefer allocator.free(actual_face);
    if (!std.mem.eql(u8, actual_face, expected_face)) return error.PaintFontSubstitution;
    return .{
        .actual_face = actual_face,
        .height = info.lfHeight,
        .weight = info.lfWeight,
    };
}

const PaintRenderProof = struct {
    rgb_sha256: [32]u8,
    bmp_sha256: [32]u8,
    dpi_x: i32,
    dpi_y: i32,
    age_observed_at: u64 = 0,
};

fn verifyPaintContract(dib: ParityDib, fixture: *const PaintExportFixture, allocator: std.mem.Allocator) !void {
    const model = &fixture.model;
    const graph = model.graph orelse return error.PaintFixtureGraphMissing;
    const viewport = renderBounds(1280, 720, .{
        .rail_visible = true,
        .panel_visible = false,
        .activity_enabled = false,
    });
    var state = try modelTestState(model, .{}, chrome764GraphBounds());
    defer state.deinitLayout();
    for (graph.nodes.items, 0..) |node, index| {
        const bounds = nodeBounds(index, &state);
        try std.testing.expectEqual(@as(i32, 250), bounds.right - bounds.left);
        try std.testing.expectEqual(@as(i32, 96), bounds.bottom - bounds.top);
        try std.testing.expect(bounds.left >= viewport.left and bounds.top >= viewport.top);
        try std.testing.expect(bounds.right <= viewport.right and bounds.bottom <= viewport.bottom);
        const presentation = cardState(node);
        const pill_width = blk: {
            const old = try selectCardFont(dib.dc, 10, .card_state);
            defer _ = c.SelectObject(dib.dc, old);
            break :blk try measuredText(dib.dc, allocator, presentation.word) + 22;
        };
        const rows = cardTextLayout(bounds, 1, pill_width);
        try std.testing.expect(dib.count(rows.pill, presentation.fill) > 20);
        try std.testing.expect(dib.count(rows.title, 0x00F4F4F4) > 0);
        try std.testing.expect(dib.count(rows.live, 0x009F9C9C) > 0);
        try std.testing.expectEqual(@as(usize, 36), dib.count(rows.meta, loopTypeColor(node.loop_type)));
        try std.testing.expect(dib.count(rows.meta, blendCardColor(0x00FFFFFF, Tokens.loop_card_bottom, 52)) > 0);
    }
    try std.testing.expectEqual(@as(?usize, 0), model.selectedIndex());
    try std.testing.expectEqual(@as(usize, 0), model.activity.items.len);
    const edge = graph.edges.items[0];
    const from = connectorPosition(graph.nodes.items, edge.from, true, &state).?;
    const to = connectorPosition(graph.nodes.items, edge.to, false, &state).?;
    const label_x = @divTrunc(from.x + to.x, 2);
    const label_y = @min(from.y, to.y) - 76;
    const label_bounds = rect(label_x - 74, label_y, label_x + 74, label_y + 20);
    try std.testing.expect(label_bounds.left >= viewport.left and label_bounds.top >= viewport.top);
    try std.testing.expect(label_bounds.right <= viewport.right and label_bounds.bottom <= viewport.bottom);
    const label = try edgeLabel(allocator, edge);
    defer allocator.free(label);
    try std.testing.expectEqualStrings("handoff", label);
    try std.testing.expect(dib.count(label_bounds, edgeKindColor(edge.kind)) > 0);
    try std.testing.expect(dib.nonBackgroundPixels(Tokens.canvas_tone) > 10_000);
}

fn verifyPaint764Inventory(fixture: *const Paint764Fixture, scene: Paint764Scene) !void {
    const model = &fixture.model;
    const graph = model.graph orelse return error.Paint764ActiveGraphMissing;
    const roles = try resolveCardRoles(std.testing.allocator, graph.nodes.items, graph.edges.items, &.{});
    defer std.testing.allocator.free(roles);
    try std.testing.expectEqual(@as(usize, 6), graph.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 3), graph.edges.items.len);
    try std.testing.expectEqual(@as(?u64, 1_704_067_200), graph.nodes.items[0].created_at);
    try std.testing.expectEqualStrings("review", graph.nodes.items[1].worktree_branch);
    try std.testing.expectEqual(@as(usize, 0), model.activity.items.len);
    try std.testing.expectEqual(NodeRole.entry, roles[0]);
    try std.testing.expectEqual(NodeRole.interior, roles[1]);
    try std.testing.expectEqual(NodeRole.interior, roles[2]);
    try std.testing.expectEqual(NodeRole.entry, roles[3]);
    try std.testing.expectEqual(NodeRole.interior, roles[4]);
    try std.testing.expectEqual(NodeRole.unwired, roles[5]);
    try std.testing.expect(attentionActionVisible(
        graph.nodes.items[2],
        graph.nodes.items,
        graph.edges.items,
    ));
    try std.testing.expect(attentionActionVisible(
        graph.nodes.items[5],
        graph.nodes.items,
        graph.edges.items,
    ));

    var main_count: usize = 0;
    var goal_count: usize = 0;
    var timed_count: usize = 0;
    var turn_count: usize = 0;
    var composite_count: usize = 0;
    var state_words = [_]usize{0} ** 6;
    for (graph.nodes.items) |node| {
        if (std.mem.eql(u8, cardTypeName(node.loop_type), "Main")) main_count += 1;
        if (std.mem.eql(u8, cardTypeName(node.loop_type), "Goal")) goal_count += 1;
        if (std.mem.eql(u8, cardTypeName(node.loop_type), "Timed")) timed_count += 1;
        if (std.mem.eql(u8, cardTypeName(node.loop_type), "Turn")) turn_count += 1;
        if (std.mem.eql(u8, cardTypeName(node.loop_type), "Composite")) composite_count += 1;
        try std.testing.expectEqual(@as(?u64, 1_704_067_200), node.created_at);
        const word = cardState(node).word;
        for ([_][]const u8{ "IDLE", "DONE", "STOPPED", "RUNNING", "BLOCKED", "NEEDS YOU" }, 0..) |expected, index| {
            if (std.mem.eql(u8, word, expected)) state_words[index] += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), main_count);
    try std.testing.expectEqual(@as(usize, 1), goal_count);
    try std.testing.expectEqual(@as(usize, 1), timed_count);
    try std.testing.expectEqual(@as(usize, 2), turn_count);
    try std.testing.expectEqual(@as(usize, 1), composite_count);
    for (state_words) |count| try std.testing.expectEqual(@as(usize, 1), count);

    if (scene == .overview) {
        try std.testing.expectEqual(@as(usize, 2), model.graphs.items.len);
        try std.testing.expectEqual(@as(usize, 2), model.graphs.items[1].nodes.items.len);
        try std.testing.expectEqual(@as(usize, 1), model.graphs.items[1].edges.items.len);
        try std.testing.expect(fixture.peer_sha256 != null);
        try std.testing.expectEqualStrings("sample", model.graphs.items[1].nodes.items[0].worktree_branch);
    } else {
        try std.testing.expectEqual(@as(usize, 1), model.graphs.items.len);
        try std.testing.expect(fixture.peer_sha256 == null);
    }
}

fn paint764AgeLabel(allocator: std.mem.Allocator, created_at: u64, now: u64) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    try writeCardAge(result.writer(), now -| created_at);
    return result.toOwnedSlice();
}

fn verifyPaint764AgeStable(
    model: *const GraphModel.Model,
    allocator: std.mem.Allocator,
    first_observation: u64,
    second_observation: u64,
) !void {
    for (model.graphs.items) |graph| {
        for (graph.nodes.items) |node| {
            const created_at = node.created_at orelse continue;
            const first = try paint764AgeLabel(allocator, created_at, first_observation);
            defer allocator.free(first);
            const second = try paint764AgeLabel(allocator, created_at, second_observation);
            defer allocator.free(second);
            if (!std.mem.eql(u8, first, second)) return error.PaintExportAgeBucketChanged;
        }
    }
}

fn paint764AgeEvidence(
    allocator: std.mem.Allocator,
    fixture: *const Paint764Fixture,
    observed_at: u64,
) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    const writer = result.writer();
    try writer.print("{{\"observedAtEpochSeconds\":{d},\"nodes\":[", .{observed_at});
    var first_node = true;
    for (fixture.model.graphs.items) |graph| {
        for (graph.nodes.items) |node| {
            const created_at = node.created_at orelse continue;
            const age = try paint764AgeLabel(allocator, created_at, observed_at);
            defer allocator.free(age);
            try writer.print(
                "{s}{{\"id\":\"{s}\",\"createdAtEpochSeconds\":{d},\"display\":\"{s}\"}}",
                .{ if (first_node) "" else ",", node.id, created_at, age },
            );
            first_node = false;
        }
    }
    try writer.writeAll("]}");
    return result.toOwnedSlice();
}

const paint764_zoom = LaneLayout.MacMetrics.default_fit_floor;

fn verifyPaint764CardPixels(
    dib: ParityDib,
    allocator: std.mem.Allocator,
    node: GraphModel.Node,
    bounds: c.RECT,
    role: NodeRole,
    attention: bool,
    now: u64,
    zoom: f32,
) !void {
    try std.testing.expectEqual(scaledValue(250, zoom), bounds.right - bounds.left);
    try std.testing.expectEqual(scaledValue(96, zoom), bounds.bottom - bounds.top);
    const presentation = cardState(node);
    const pill_width = blk: {
        const old = try selectCardFont(dib.dc, 10 * zoom, .card_state);
        defer _ = c.SelectObject(dib.dc, old);
        break :blk try measuredText(dib.dc, allocator, presentation.word) + scaledValue(22, zoom);
    };
    const rows = cardTextLayout(bounds, zoom, pill_width);
    try std.testing.expect(dib.count(rows.pill, presentation.fill) > 20);
    try std.testing.expect(dib.count(rows.title, 0x00F4F4F4) > 0);
    const square: usize = @intCast(scaledValue(6, zoom));
    try std.testing.expectEqual(square * square, dib.count(rows.meta, loopTypeColor(node.loop_type)));
    const meta_bounds = rect(rows.meta.left + scaledValue(11, zoom), rows.meta.top, rows.meta.right, rows.meta.bottom);
    const old_font = try selectCardFont(dib.dc, 10.5 * zoom, .card_mono);
    defer _ = c.SelectObject(dib.dc, old_font);
    const metadata = try cardMetaForWidth(
        dib.dc,
        allocator,
        node,
        now,
        meta_bounds.right - meta_bounds.left,
    );
    defer allocator.free(metadata);
    if (node.created_at) |created_at| {
        const age = try paint764AgeLabel(allocator, created_at, now);
        defer allocator.free(age);
        try std.testing.expect(std.mem.endsWith(u8, metadata, age));
    }
    if (node.worktree_branch.len != 0) {
        try std.testing.expect(std.mem.indexOf(u8, metadata, node.worktree_branch) != null);
    }
    if (node.metric_sample_count >= 2 and node.metric_direction.len != 0) {
        const track = rect(rows.detail.left, rows.detail.bottom - scaledValue(3, zoom), rows.detail.right, rows.detail.bottom);
        if (primaryCardAction(node) == null) {
            try std.testing.expect(dib.count(track, loopTypeColor(node.loop_type)) > 0);
            try std.testing.expect(dib.count(track, 0x00444141) > 0);
        } else {
            try std.testing.expectEqual(@as(usize, 0), dib.count(track, loopTypeColor(node.loop_type)));
            try std.testing.expectEqual(@as(usize, 0), dib.count(track, 0x00444141));
        }
    }
    if (attention) {
        const action = attentionActionBounds(bounds, &.{ .zoom = zoom });
        try std.testing.expect(dib.count(action, 0x000A9FFF) > 0);
    }
    if (!attention and role == .entry) {
        const chip = cardRoleChip(role) orelse return error.Paint764EntryRoleChipMissing;
        const role_presentation = try cardMetaPresentation(dib.dc, allocator, node, rows, zoom, role);
        defer allocator.free(role_presentation.text);
        const chip_width = try cardRoleChipWidth(dib.dc, allocator, role, zoom);
        const chip_height = scaledValue(14, zoom);
        const chip_row = if (role_presentation.chip_in_detail) rows.detail else rows.meta;
        const chip_top = @divTrunc(chip_row.top + chip_row.bottom - chip_height, 2);
        const chip_left = if (role_presentation.chip_in_detail) chip_row.left else chip_row.right - chip_width;
        const chip_bounds = rect(chip_left, chip_top, chip_left + chip_width, chip_top + chip_height);
        try std.testing.expect(dib.count(chip_bounds, chip.fill) > 20);
    }
    if (!attention and role == .unwired) {
        try std.testing.expect(dib.count(rows.detail, 0x007ACDFF) > 0);
    }
}

fn paint764NodeIndex(nodes: []const GraphModel.Node, id: []const u8) ?usize {
    for (nodes, 0..) |node, index| {
        if (std.mem.eql(u8, node.id, id)) return index;
    }
    return null;
}

fn paint764RgbL1(a: u32, b: u32) u32 {
    var distance: u32 = 0;
    inline for ([_]u5{ 0, 8, 16 }) |shift| {
        const left: i32 = @intCast((a >> shift) & 255);
        const right: i32 = @intCast((b >> shift) & 255);
        distance += @abs(left - right);
    }
    return distance;
}

fn verifyPaint764StrokeVisibility(dib: ParityDib, mask: ParityDib, sample: c.RECT, expected: u32, edge_id: []const u8) !void {
    try std.testing.expectEqual(@as(i32, 41), sample.right - sample.left);
    try std.testing.expectEqual(@as(i32, 7), sample.bottom - sample.top);
    const stroke_y = sample.top + 3;
    // Keep the fixed 40-point contrast/edge-distance margin. A wider hand-off
    // exposes real dash gaps: the independent route mask identifies ink, not
    // observed output pixels. Also assert those gaps actually remain gaps.
    const margin: u32 = 40;
    var comparisons: usize = 0;
    var failures: usize = 0;
    var gaps: usize = 0;
    var x = sample.left;
    while (x < sample.right) : (x += 1) {
        const stroke = c.GetPixel(dib.dc, x, stroke_y);
        const mask_pixel = c.GetPixel(mask.dc, x, stroke_y);
        for ([_]i32{ -1, 1 }) |offset| {
            const neighbor = c.GetPixel(dib.dc, x, stroke_y + offset);
            if (stroke == c.CLR_INVALID or neighbor == c.CLR_INVALID or mask_pixel == c.CLR_INVALID) {
                std.debug.print("paint764 edge visibility unreadable edge={s} x={d} stroke-y={d} offset={d}\n",
                    .{ edge_id, x, stroke_y, offset });
                return error.Paint764EdgeStrokeSampleUnreadable;
            }
            const contrast = paint764RgbL1(stroke, neighbor);
            if (mask_pixel != 0x00FFFFFF) {
                gaps += 1;
                try std.testing.expect(contrast < margin);
                continue;
            }
            const stroke_distance = paint764RgbL1(stroke, expected);
            const neighbor_distance = paint764RgbL1(neighbor, expected);
            const advantage = @as(i32, @intCast(neighbor_distance)) - @as(i32, @intCast(stroke_distance));
            const visible = contrast >= margin and advantage >= @as(i32, @intCast(margin));
            comparisons += 1;
            if (!visible) failures += 1;
            std.debug.print("paint764 edge visibility edge={s} x={d} stroke-y={d} neighbor-y={d} contrast={d} edge-advantage={d} margin={d} pass={}\n",
                .{ edge_id, x, stroke_y, stroke_y + offset, contrast, advantage, margin, visible });
        }
    }
    std.debug.print("paint764 edge visibility summary edge={s} region=({d},{d},{d},{d}) comparisons={d} failures={d} margin={d}\n",
        .{ edge_id, sample.left, sample.top, sample.right, sample.bottom, comparisons, failures, margin });
    try std.testing.expect(comparisons >= 14);
    try std.testing.expect(gaps >= 2);
    if (failures != 0) return error.Paint764EdgeStrokeNotVisible;
}

test "lane visibility mask rejects absent strokes and retains positive ink and dash-gap controls" {
    var actual = try ParityDib.init(64, 16);
    defer actual.deinit();
    var mask = try ParityDib.init(64, 16);
    defer mask.deinit();
    fill(actual.dc, rect(0, 0, 64, 16), 0);
    fill(mask.dc, rect(0, 0, 64, 16), 0);
    fill(mask.dc, rect(4, 6, 13, 7), 0x00FFFFFF);
    const sample = rect(2, 3, 43, 10);
    try std.testing.expectError(error.Paint764EdgeStrokeNotVisible, verifyPaint764StrokeVisibility(actual, mask, sample, 0x00FFFFFF, "negative-no-stroke"));
    fill(actual.dc, rect(4, 6, 13, 7), 0x00FFFFFF);
    try verifyPaint764StrokeVisibility(actual, mask, sample, 0x00FFFFFF, "positive-stroke-and-gaps");
}

fn verifyPaint764Contract(
    dib: ParityDib,
    fixture: *const Paint764Fixture,
    allocator: std.mem.Allocator,
    scene: Paint764Scene,
    age_observed_at: u64,
) !void {
    try verifyPaint764Inventory(fixture, scene);
    const controls = WorkspaceControls.State{
        .graph_visible = true,
        .rail_visible = true,
        .panel_visible = false,
        .activity_enabled = false,
    };
    const viewport = renderBounds(1280, 720, controls);
    const graph_bounds = rect(viewport.left, viewport.top, viewport.right, viewport.bottom);
    var state = try modelTestState(&fixture.model, .{ .zoom = paint764_zoom }, graph_bounds);
    defer state.deinitLayout();
    if (scene == .project) {
        const graph = fixture.model.graph orelse return error.Paint764ActiveGraphMissing;
        const roles = try resolveCardRoles(allocator, graph.nodes.items, graph.edges.items, &.{});
        defer allocator.free(roles);
        for (graph.nodes.items, 0..) |node, index| {
            const bounds = nodeBounds(index, &state);
            try std.testing.expect(bounds.left >= viewport.left and bounds.top >= viewport.top);
            try std.testing.expect(bounds.right <= viewport.right and bounds.bottom <= viewport.bottom);
            try verifyPaint764CardPixels(
                dib,
                allocator,
                node,
                bounds,
                roles[index],
                needsAttention(node, graph.nodes.items, graph.edges.items),
                age_observed_at,
                state.zoom,
            );
        }
        var placed_edge_labels: [128]c.RECT = undefined;
        var placed_edge_label_count: usize = 0;
        for (graph.edges.items) |edge| {
            const from = connectorPosition(graph.nodes.items, edge.from, true, &state) orelse
                return error.Paint764EdgeSourceMissing;
            const to = connectorPosition(graph.nodes.items, edge.to, false, &state) orelse
                return error.Paint764EdgeTargetMissing;
            const from_index = paint764NodeIndex(graph.nodes.items, edge.from) orelse
                return error.Paint764EdgeSourceMissing;
            const to_index = paint764NodeIndex(graph.nodes.items, edge.to) orelse
                return error.Paint764EdgeTargetMissing;
            try std.testing.expectEqual(nodeBounds(from_index, &state).right, from.x);
            try std.testing.expectEqual(nodeBounds(to_index, &state).left, to.x);
            const center_x = @divTrunc(from.x + to.x, 2);
            const center_y = @divTrunc(from.y + to.y, 2);
            try std.testing.expectEqual(from.y, to.y);
            const stroke_sample = rect(from.x + 8, center_y - 3, from.x + 49, center_y + 4);
            var mask = try ParityDib.init(1280, 720);
            defer mask.deinit();
            fill(mask.dc, rect(0, 0, 1280, 720), 0);
            const route = graphEdgeRoute(graph.nodes.items, edge, .{ .state = &state }) orelse return error.Paint764EdgeSourceMissing;
            const dash = graphEdgeDash(edge).?;
            drawRoute(mask.dc, route, 0x00FFFFFF, 1.5 * state.zoom, .{ scaledValue(dash[0], state.zoom), scaledValue(dash[1], state.zoom) });
            try verifyPaint764StrokeVisibility(dib, mask, stroke_sample, edgeKindColor(edge.kind), edge.id);
            const label = try edgeLabel(allocator, edge);
            defer allocator.free(label);
            try std.testing.expectEqualStrings("handoff", label);
            var label_y = if (@abs(to.y - from.y) < 40)
                @min(from.y, to.y) - 76
            else
                @divTrunc(from.y + to.y, 2) - 10;
            var label_bounds = rect(center_x - 74, label_y, center_x + 74, label_y + 20);
            var attempts: usize = 0;
            while (attempts < 12 and overlapsPlaced(label_bounds, placed_edge_labels[0..placed_edge_label_count])) : (attempts += 1) {
                label_y += 24;
                label_bounds = rect(center_x - 74, label_y, center_x + 74, label_y + 20);
            }
            if (placed_edge_label_count < placed_edge_labels.len) {
                placed_edge_labels[placed_edge_label_count] = label_bounds;
                placed_edge_label_count += 1;
            }
        }
    } else {
        var painted_edges: usize = 0;
        for (fixture.model.graphs.items, 0..) |graph, graph_index| {
            const roles = try resolveCardRoles(allocator, graph.nodes.items, graph.edges.items, &.{});
            defer allocator.free(roles);
            const lane = overviewLaneBounds(&fixture.model, graph_index, graph_bounds, &state);
            try std.testing.expectEqual(@as(i32, 1457), lane.right);
            try std.testing.expect(lane.left >= viewport.left and lane.left < viewport.right);
            try std.testing.expect(lane.top >= viewport.top and lane.bottom <= viewport.bottom);
            const caption = overviewLaneCaption(&fixture.model, graph_index, graph_bounds, &state);
            try std.testing.expectEqual(@as(usize, 0), dib.count(caption.worktrees, 0x00352B1C));
            var panned = try ParityDib.init(1280, 720);
            defer panned.deinit();
            state.pan_x = @floatFromInt(viewport.right - lane.right - 18);
            try chrome764Paint(panned, fixture, .overview, &state, null, &.{});
            const panned_caption = overviewLaneCaption(&fixture.model, graph_index, graph_bounds, &state);
            try std.testing.expect(panned_caption.worktrees.right < viewport.right);
            try std.testing.expect(panned.count(panned_caption.worktrees, 0x00352B1C) > 0);
            state.pan_x = 0;
            for (graph.nodes.items, 0..) |node, node_index| {
                const bounds = overviewCardBounds(&fixture.model, graph_index, node_index, graph_bounds, &state);
                try std.testing.expect(bounds.left >= lane.left and bounds.top > lane.top);
                try std.testing.expect(bounds.right <= lane.right and bounds.bottom < lane.bottom);
                try verifyPaint764CardPixels(dib, allocator, node, bounds, roles[node_index], needsAttention(node, graph.nodes.items, graph.edges.items), age_observed_at, state.zoom);
            }
            for (graph.edges.items) |edge| {
                const geometry = GraphGeometry{ .state = &state, .overview = .{ .model = &fixture.model, .graph_index = graph_index, .bounds = graph_bounds } };
                const route = graphEdgeRoute(graph.nodes.items, edge, geometry) orelse return error.Paint764EdgeSourceMissing;
                try std.testing.expectEqual(route.from.y, route.to.y);
                var mask = try ParityDib.init(1280, 720);
                defer mask.deinit();
                fill(mask.dc, rect(0, 0, 1280, 720), 0);
                const dash = graphEdgeDash(edge).?;
                drawRoute(mask.dc, route, 0x00FFFFFF, 1.5 * state.zoom, .{ scaledValue(dash[0], state.zoom), scaledValue(dash[1], state.zoom) });
                try verifyPaint764StrokeVisibility(dib, mask, rect(route.from.x + 8, route.from.y - 3, route.from.x + 49, route.from.y + 4), edgeKindColor(edge.kind), edge.id);
                painted_edges += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 4), painted_edges);
    }
    try std.testing.expect(c.GdiFlush() != 0);
    try std.testing.expect(dib.nonBackgroundPixels(Tokens.canvas_tone) > 10_000);
}

fn renderPaintArtifact(
    allocator: std.mem.Allocator,
    fixture: *const PaintExportFixture,
    path: []const u8,
) !PaintRenderProof {
    var dib = try ParityDib.init(1280, 720);
    defer dib.deinit();
    if (!GdiplusAA.isReady()) return error.PaintExportGdiplusNotReady;
    try paintExportFixture(dib, &fixture.model, allocator, .project, "Alpha");
    try verifyPaintContract(dib, fixture, allocator);
    const rgb_sha256 = try dib.rgbSha256(allocator);
    const bmp_sha256 = try dib.writeBmp(allocator, path);
    return .{
        .rgb_sha256 = rgb_sha256,
        .bmp_sha256 = bmp_sha256,
        .dpi_x = c.GetDeviceCaps(dib.dc, c.LOGPIXELSX),
        .dpi_y = c.GetDeviceCaps(dib.dc, c.LOGPIXELSY),
    };
}

fn writePaintReceipt(
    allocator: std.mem.Allocator,
    path: []const u8,
    fixture: *const PaintExportFixture,
    render: PaintRenderProof,
    font_facts: *const [4]PaintFontFact,
    hashes: *const [3][32]u8,
    source_commit: []const u8,
) !void {
    const fixture_hex = std.fmt.bytesToHex(fixture.sha256, .lower);
    const bmp_hex = std.fmt.bytesToHex(render.bmp_sha256, .lower);
    const rgb_hex = std.fmt.bytesToHex(render.rgb_sha256, .lower);
    const render0_hex = std.fmt.bytesToHex(hashes[0], .lower);
    const render1_hex = std.fmt.bytesToHex(hashes[1], .lower);
    const render2_hex = std.fmt.bytesToHex(hashes[2], .lower);
    const receipt = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "schemaVersion": 1,
        \\  "evidenceClass": "paint-only",
        \\  "scene": "project-paint-v1",
        \\  "fixturePath": "graphcode-windows/fixtures/paint-project-v1.json",
        \\  "fixtureSha256": "{s}",
        \\  "sourceCommit": "{s}",
        \\  "renderer": "GraphCanvas.paint + GraphCanvas.paintHeader -> memory DIB",
        \\  "dimensions": {{"width": 1280, "height": 720, "logicalWidth": 1280, "logicalHeight": 720}},
        \\  "dpiMapping": {{"windowExtX": 96, "windowExtY": 96, "viewportExtX": 96, "viewportExtY": 96, "deviceDpiX": {d}, "deviceDpiY": {d}}},
        \\  "canvas": {{"zoom": 1, "panX": 0, "panY": 0, "selectedIndex": 0, "railVisible": true, "panelVisible": false, "activityEnabled": false}},
        \\  "model": {{"nodes": 2, "edges": 1, "activityHistory": 0, "createdAtValues": 0}},
        \\  "header": {{"title": "GraphCode", "context": "Alpha", "reachabilityClaim": "declared fixture/test value only; not App reachability"}},
        \\  "gdiPlusReady": true,
        \\  "colorAssumption": "SDR RGB; unused DIB alpha is normalized to opaque in BMP transport",
        \\  "fontEvidenceScope": "Sampled card title, state, metadata, and header title font selections only; not a census of every text draw",
        \\  "fonts": [
        \\    {{"role": "card-title", "logicalFace": "Segoe UI", "actualFace": "{s}", "height": {d}, "weight": {d}, "quality": "CLEARTYPE_QUALITY"}},
        \\    {{"role": "card-state", "logicalFace": "Segoe UI", "actualFace": "{s}", "height": {d}, "weight": {d}, "quality": "CLEARTYPE_QUALITY"}},
        \\    {{"role": "card-mono", "logicalFace": "Consolas", "actualFace": "{s}", "height": {d}, "weight": {d}, "quality": "CLEARTYPE_QUALITY"}},
        \\    {{"role": "header", "logicalFace": "Segoe UI", "actualFace": "{s}", "height": {d}, "weight": {d}, "quality": "CLEARTYPE_QUALITY"}}
        \\  ],
        \\  "transport": [
        \\    {{"name": "project-paint-v1.bmp", "bmpSha256": "{s}", "rgbSha256": "{s}"}},
        \\    {{"name": "project-paint-v1-repeat-2.bmp", "rgbSha256": "{s}"}},
        \\    {{"name": "project-paint-v1-repeat-3.bmp", "rgbSha256": "{s}"}}
        \\  ],
        \\  "renderRgbSha256": ["{s}", "{s}", "{s}"],
        \\  "candidateArtifactCount": 1,
        \\  "excludedSurfaces": ["whole window", "composition", "popups", "terminals", "per-monitor DPI", "sidebar/right-panel fidelity", "native form controls", "accessibility"]
        \\}}
    , .{
        fixture_hex,
        source_commit,
        render.dpi_x,
        render.dpi_y,
        font_facts[0].actual_face,
        font_facts[0].height,
        font_facts[0].weight,
        font_facts[1].actual_face,
        font_facts[1].height,
        font_facts[1].weight,
        font_facts[2].actual_face,
        font_facts[2].height,
        font_facts[2].weight,
        font_facts[3].actual_face,
        font_facts[3].height,
        font_facts[3].weight,
        bmp_hex,
        rgb_hex,
        rgb_hex,
        rgb_hex,
        render0_hex,
        render1_hex,
        render2_hex,
    });
    defer allocator.free(receipt);
    var file = try std.fs.cwd().createFile(path, .{ .exclusive = true });
    defer file.close();
    try file.writeAll(receipt);
}

fn paint764SceneName(scene: Paint764Scene) []const u8 {
    return if (scene == .project) "project-paint-764" else "overview-paint-764";
}

fn paint764HeaderContext(scene: Paint764Scene) []const u8 {
    return if (scene == .project) "Card States" else "Overview";
}

fn paint764ArtifactName(allocator: std.mem.Allocator, scene: Paint764Scene, render_index: usize) ![]u8 {
    const suffix = switch (render_index) {
        0 => "",
        1 => "-repeat-2",
        2 => "-repeat-3",
        else => return error.Paint764RenderIndexInvalid,
    };
    return std.fmt.allocPrint(allocator, "{s}{s}.bmp", .{ paint764SceneName(scene), suffix });
}

fn renderPaint764Artifact(
    allocator: std.mem.Allocator,
    fixture: *const Paint764Fixture,
    path: []const u8,
    scene: Paint764Scene,
) !PaintRenderProof {
    var dib = try ParityDib.init(1280, 720);
    defer dib.deinit();
    if (!GdiplusAA.isReady()) return error.PaintExportGdiplusNotReady;
    const surface: Surface = if (scene == .project) .project else .overview;
    const age_started_at: u64 = @intCast(@max(0, std.time.timestamp()));
    try paintExportFixture(dib, &fixture.model, allocator, surface, paint764HeaderContext(scene));
    const age_observed_at: u64 = @intCast(@max(0, std.time.timestamp()));
    try verifyPaint764AgeStable(&fixture.model, allocator, age_started_at, age_observed_at);
    try verifyPaint764Contract(dib, fixture, allocator, scene, age_observed_at);
    return .{
        .rgb_sha256 = try dib.rgbSha256(allocator),
        .bmp_sha256 = try dib.writeBmp(allocator, path),
        .dpi_x = c.GetDeviceCaps(dib.dc, c.LOGPIXELSX),
        .dpi_y = c.GetDeviceCaps(dib.dc, c.LOGPIXELSY),
        .age_observed_at = age_observed_at,
    };
}

fn writePaint764Receipt(
    allocator: std.mem.Allocator,
    path: []const u8,
    fixture: *const Paint764Fixture,
    render: PaintRenderProof,
    font_facts: *const [4]PaintFontFact,
    hashes: *const [3][32]u8,
    source_commit: []const u8,
    scene: Paint764Scene,
) !void {
    const project_hex = std.fmt.bytesToHex(fixture.project_sha256, .lower);
    var peer_hex_storage: [64]u8 = undefined;
    const peer_hex: []const u8 = if (fixture.peer_sha256) |digest| blk: {
        peer_hex_storage = std.fmt.bytesToHex(digest, .lower);
        break :blk peer_hex_storage[0..];
    } else "";
    const fixture_list = if (scene == .overview)
        try std.fmt.allocPrint(
            allocator,
            \\[{{"path":"graphcode-windows/fixtures/paint-764-project.json","sha256":"{s}"}},{{"path":"graphcode-windows/fixtures/paint-764-overview-peer.json","sha256":"{s}"}}]
        ,
            .{ project_hex, peer_hex },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            \\[{{"path":"graphcode-windows/fixtures/paint-764-project.json","sha256":"{s}"}}]
        ,
            .{project_hex},
        );
    defer allocator.free(fixture_list);
    const bmp_hex = std.fmt.bytesToHex(render.bmp_sha256, .lower);
    const rgb_hex = std.fmt.bytesToHex(render.rgb_sha256, .lower);
    const render0_hex = std.fmt.bytesToHex(hashes[0], .lower);
    const render1_hex = std.fmt.bytesToHex(hashes[1], .lower);
    const render2_hex = std.fmt.bytesToHex(hashes[2], .lower);
    const nodes: usize = if (scene == .project) 6 else 8;
    const edges: usize = if (scene == .project) 3 else 4;
    const painted_edges: usize = edges;
    const age_evidence = try paint764AgeEvidence(allocator, fixture, render.age_observed_at);
    defer allocator.free(age_evidence);
    const artifact0 = try paint764ArtifactName(allocator, scene, 0);
    defer allocator.free(artifact0);
    const artifact1 = try paint764ArtifactName(allocator, scene, 1);
    defer allocator.free(artifact1);
    const artifact2 = try paint764ArtifactName(allocator, scene, 2);
    defer allocator.free(artifact2);
    const fonts_json = try std.fmt.allocPrint(allocator,
        \\[
        \\  {{"role": "card-title", "logicalFace": "Segoe UI", "actualFace": "{s}", "height": {d}, "weight": {d}, "quality": "CLEARTYPE_QUALITY"}},
        \\  {{"role": "card-state", "logicalFace": "Segoe UI", "actualFace": "{s}", "height": {d}, "weight": {d}, "quality": "CLEARTYPE_QUALITY"}},
        \\  {{"role": "card-mono", "logicalFace": "Consolas", "actualFace": "{s}", "height": {d}, "weight": {d}, "quality": "CLEARTYPE_QUALITY"}},
        \\  {{"role": "header", "logicalFace": "Segoe UI", "actualFace": "{s}", "height": {d}, "weight": {d}, "quality": "CLEARTYPE_QUALITY"}}
        \\]
    , .{
        font_facts[0].actual_face,
        font_facts[0].height,
        font_facts[0].weight,
        font_facts[1].actual_face,
        font_facts[1].height,
        font_facts[1].weight,
        font_facts[2].actual_face,
        font_facts[2].height,
        font_facts[2].weight,
        font_facts[3].actual_face,
        font_facts[3].height,
        font_facts[3].weight,
    });
    defer allocator.free(fonts_json);
    const receipt = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "schemaVersion": 1,
        \\  "evidenceClass": "paint-only",
        \\  "scene": "{s}",
        \\  "fixturePath": "graphcode-windows/fixtures/paint-764-project.json",
        \\  "fixtureSha256": "{s}",
        \\  "fixtures": {s},
        \\  "sourceCommit": "{s}",
        \\  "renderer": "GraphCanvas.paint + GraphCanvas.paintHeader -> memory DIB",
        \\  "dimensions": {{"width": 1280, "height": 720, "logicalWidth": 1280, "logicalHeight": 720}},
        \\  "dpiMapping": {{"windowExtX": 96, "windowExtY": 96, "viewportExtX": 96, "viewportExtY": 96, "deviceDpiX": {d}, "deviceDpiY": {d}}},
        \\  "canvas": {{"surface": "{s}", "zoom": 0.8, "panX": 0, "panY": 0, "selectedIndex": 0, "railVisible": true, "panelVisible": false, "activityEnabled": false}},
        \\  "model": {{"nodes": {d}, "edges": {d}, "paintedEdges": {d}, "activityHistory": 0, "createdAtValues": {d}}},
        \\  "ageEvidence": {s},
        \\  "header": {{"title": "GraphCode", "context": "{s}", "reachabilityClaim": "declared fixture/test value only; not App reachability"}},
        \\  "gdiPlusReady": true,
        \\  "colorAssumption": "SDR RGB; unused DIB alpha is normalized to opaque in BMP transport",
        \\  "fontEvidenceScope": "Sampled card title, state, metadata, and header title font selections only; not a census of every text draw",
        \\  "fonts": {s},
        \\  "transport": [
        \\    {{"name": "{s}", "bmpSha256": "{s}", "rgbSha256": "{s}"}},
        \\    {{"name": "{s}", "rgbSha256": "{s}"}},
        \\    {{"name": "{s}", "rgbSha256": "{s}"}}
        \\  ],
        \\  "renderRgbSha256": ["{s}", "{s}", "{s}"],
        \\  "candidateArtifactCount": 1,
        \\  "excludedSurfaces": ["whole window composition", "input and button behavior", "project opening and canvas fit", "backend lifecycle and persistence", "UI Automation and accessibility", "per-monitor DPI", "unreviewed sidebar and loop-bar palette"]
        \\}}
    , .{
        paint764SceneName(scene),
        project_hex,
        fixture_list,
        source_commit,
        render.dpi_x,
        render.dpi_y,
        if (scene == .project) "project" else "overview",
        nodes,
        edges,
        painted_edges,
        nodes,
        age_evidence,
        paint764HeaderContext(scene),
        fonts_json,
        artifact0,
        bmp_hex,
        rgb_hex,
        artifact1,
        render1_hex,
        artifact2,
        render2_hex,
        render0_hex,
        render1_hex,
        render2_hex,
    });
    defer allocator.free(receipt);
    var file = try std.fs.cwd().createFile(path, .{ .exclusive = true });
    defer file.close();
    try file.writeAll(receipt);
}

fn verifyPaint764Transport(allocator: std.mem.Allocator, transport: []const u8, scene: Paint764Scene) !usize {
    var directory = try std.fs.cwd().openDir(transport, .{ .iterate = true });
    defer directory.close();
    var seen = [_]bool{false} ** 3;
    var iterator = directory.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) return error.PaintExportUnexpectedArtifact;
        var match: ?usize = null;
        for (0..seen.len) |index| {
            const expected = try paint764ArtifactName(allocator, scene, index);
            defer allocator.free(expected);
            if (std.mem.eql(u8, entry.name, expected)) {
                match = index;
                break;
            }
        }
        const index = match orelse return error.PaintExportUnexpectedArtifact;
        if (seen[index]) return error.PaintExportDuplicateArtifact;
        seen[index] = true;
        const artifact_path = try std.fs.path.join(allocator, &.{ transport, entry.name });
        defer allocator.free(artifact_path);
        const stat = try std.fs.cwd().statFile(artifact_path);
        if (stat.size <= 54) return error.PaintExportArtifactEmpty;
    }
    for (seen) |present| {
        if (!present) return error.PaintExportArtifactMissing;
    }
    return seen.len;
}

fn paint764Export(scene: Paint764Scene) !void {
    const allocator = std.testing.allocator;
    const export_root = std.process.getEnvVarOwned(allocator, "GRAPHCODE_PAINT_EXPORT_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(export_root);
    if (export_root.len == 0) return error.PaintExportDirectoryEmpty;
    const source_commit = std.process.getEnvVarOwned(allocator, "GRAPHCODE_PAINT_SOURCE_COMMIT") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.PaintExportSourceCommitMissing,
        else => return err,
    };
    defer allocator.free(source_commit);
    if (source_commit.len != 40) return error.PaintExportSourceCommitInvalid;
    for (source_commit) |character| {
        if (!std.ascii.isDigit(character) and !(character >= 'a' and character <= 'f'))
            return error.PaintExportSourceCommitInvalid;
    }
    const transport = try std.fs.path.join(allocator, &.{ export_root, "transport" });
    defer allocator.free(transport);
    var export_dir = try std.fs.cwd().openDir(export_root, .{ .iterate = true });
    defer export_dir.close();
    var iterator = export_dir.iterate();
    if (try iterator.next() != null) return error.PaintExportRootNotEmpty;
    try std.fs.cwd().makeDir(transport);

    var fixture = try paint764FixtureModel(allocator, scene);
    defer fixture.model.deinit();
    try verifyPaint764Inventory(&fixture, scene);
    GdiplusAA.init();
    defer GdiplusAA.deinit();
    const deadline = std.time.nanoTimestamp() + 2_000_000_000;
    while (!GdiplusAA.isReady()) {
        if (std.time.nanoTimestamp() >= deadline) return error.PaintExportGdiplusNotReady;
        std.Thread.sleep(1_000_000);
    }

    var font_facts: [4]PaintFontFact = undefined;
    var font_facts_len: usize = 0;
    defer for (font_facts[0..font_facts_len]) |fact| allocator.free(fact.actual_face);
    const font_requests = [_]struct {
        font: c.HFONT,
        face: []const u8,
        height: i32,
        weight: i32,
    }{
        .{ .font = AppFont.getStyle(14.5 * paint764_zoom, .card_title), .face = "Segoe UI", .height = -12, .weight = c.FW_SEMIBOLD },
        .{ .font = AppFont.getStyle(10 * paint764_zoom, .card_state), .face = "Segoe UI", .height = -8, .weight = c.FW_BOLD },
        .{ .font = AppFont.getStyle(10.5 * paint764_zoom, .card_mono), .face = "Consolas", .height = -8, .weight = c.FW_NORMAL },
        .{ .font = AppFont.get(11, false), .face = "Segoe UI", .height = -11, .weight = c.FW_NORMAL },
    };
    var rgb_hashes: [3][32]u8 = undefined;
    var first_proof: PaintRenderProof = undefined;
    for (0..3) |render_index| {
        const file_name = try paint764ArtifactName(allocator, scene, render_index);
        defer allocator.free(file_name);
        const artifact_path = try std.fs.path.join(allocator, &.{ transport, file_name });
        defer allocator.free(artifact_path);
        const proof = try renderPaint764Artifact(allocator, &fixture, artifact_path, scene);
        if (render_index == 0) {
            first_proof = proof;
            const dib = try ParityDib.init(1280, 720);
            defer dib.deinit();
            for (font_requests) |request| {
                font_facts[font_facts_len] = try inspectPaintFont(
                    allocator,
                    dib.dc,
                    request.font,
                    request.face,
                    request.height,
                    request.weight,
                );
                font_facts_len += 1;
            }
        } else if (proof.dpi_x != first_proof.dpi_x or proof.dpi_y != first_proof.dpi_y) {
            return error.PaintExportDeviceMetricsChanged;
        } else {
            try verifyPaint764AgeStable(
                &fixture.model,
                allocator,
                first_proof.age_observed_at,
                proof.age_observed_at,
            );
        }
        rgb_hashes[render_index] = proof.rgb_sha256;
    }
    try std.testing.expectEqualSlices(u8, &rgb_hashes[0], &rgb_hashes[1]);
    try std.testing.expectEqualSlices(u8, &rgb_hashes[0], &rgb_hashes[2]);
    const rendered_count = try verifyPaint764Transport(allocator, transport, scene);
    const canonical_name = try paint764ArtifactName(allocator, scene, 0);
    defer allocator.free(canonical_name);
    const canonical_path = try std.fs.path.join(allocator, &.{ transport, canonical_name });
    defer allocator.free(canonical_path);
    const canonical_stat = try std.fs.cwd().statFile(canonical_path);
    if (canonical_stat.size <= 54) return error.PaintExportCanonicalArtifactEmpty;
    const candidate_count: usize = @intFromBool(rendered_count == 3 and canonical_stat.size > 54);
    try std.testing.expectEqual(@as(usize, 1), candidate_count);
    const receipt_path = try std.fs.path.join(allocator, &.{ transport, "paint-receipt.json" });
    defer allocator.free(receipt_path);
    try writePaint764Receipt(allocator, receipt_path, &fixture, first_proof, &font_facts, &rgb_hashes, source_commit, scene);
    std.debug.print(
        "paint export artifact contract scene={s} expected=1 actual={d} renders={d} matching-rgb-hashes=1\n",
        .{ paint764SceneName(scene), candidate_count, rendered_count },
    );
}

test "paint export: project-paint-v1" {
    const allocator = std.testing.allocator;
    const export_root = std.process.getEnvVarOwned(allocator, "GRAPHCODE_PAINT_EXPORT_DIR") catch return error.SkipZigTest;
    defer allocator.free(export_root);
    if (export_root.len == 0) return error.PaintExportDirectoryEmpty;

    const transport = try std.fs.path.join(allocator, &.{ export_root, "transport" });
    defer allocator.free(transport);
    var export_dir = try std.fs.cwd().openDir(export_root, .{ .iterate = true });
    defer export_dir.close();
    var iterator = export_dir.iterate();
    if (try iterator.next() != null) return error.PaintExportRootNotEmpty;
    try std.fs.cwd().makeDir(transport);

    var fixture = try paintExportFixtureModel(allocator);
    defer fixture.model.deinit();
    GdiplusAA.init();
    defer GdiplusAA.deinit();

    const deadline = std.time.nanoTimestamp() + 2_000_000_000;
    while (!GdiplusAA.isReady()) {
        if (std.time.nanoTimestamp() >= deadline) return error.PaintExportGdiplusNotReady;
        std.Thread.sleep(1_000_000);
    }

    var font_facts: [4]PaintFontFact = undefined;
    var font_facts_len: usize = 0;
    defer for (font_facts[0..font_facts_len]) |fact| allocator.free(fact.actual_face);
    const font_requests = [_]struct {
        font: c.HFONT,
        face: []const u8,
        height: i32,
        weight: i32,
    }{
        .{ .font = AppFont.getStyle(14.5, .card_title), .face = "Segoe UI", .height = -15, .weight = c.FW_SEMIBOLD },
        .{ .font = AppFont.getStyle(10, .card_state), .face = "Segoe UI", .height = -10, .weight = c.FW_BOLD },
        .{ .font = AppFont.getStyle(10.5, .card_mono), .face = "Consolas", .height = -11, .weight = c.FW_NORMAL },
        .{ .font = AppFont.get(11, false), .face = "Segoe UI", .height = -11, .weight = c.FW_NORMAL },
    };
    var rgb_hashes: [3][32]u8 = undefined;
    var first_proof: PaintRenderProof = undefined;
    for (0..3) |render_index| {
        const file_name = switch (render_index) {
            0 => "project-paint-v1.bmp",
            1 => "project-paint-v1-repeat-2.bmp",
            else => "project-paint-v1-repeat-3.bmp",
        };
        const artifact_path = try std.fs.path.join(allocator, &.{ transport, file_name });
        defer allocator.free(artifact_path);
        const proof = try renderPaintArtifact(allocator, &fixture, artifact_path);
        if (render_index == 0) {
            first_proof = proof;
            const dib = try ParityDib.init(1280, 720);
            defer dib.deinit();
            for (font_requests) |request| {
                font_facts[font_facts_len] = try inspectPaintFont(
                    allocator,
                    dib.dc,
                    request.font,
                    request.face,
                    request.height,
                    request.weight,
                );
                font_facts_len += 1;
            }
        } else if (proof.dpi_x != first_proof.dpi_x or proof.dpi_y != first_proof.dpi_y) {
            return error.PaintExportDeviceMetricsChanged;
        }
        rgb_hashes[render_index] = proof.rgb_sha256;
    }
    try std.testing.expectEqualSlices(u8, &rgb_hashes[0], &rgb_hashes[1]);
    try std.testing.expectEqualSlices(u8, &rgb_hashes[0], &rgb_hashes[2]);
    const source_commit = try std.process.getEnvVarOwned(allocator, "GRAPHCODE_PAINT_SOURCE_COMMIT");
    defer allocator.free(source_commit);
    if (source_commit.len != 40) return error.PaintExportSourceCommitInvalid;
    for (source_commit) |character| {
        if (!std.ascii.isHex(character)) return error.PaintExportSourceCommitInvalid;
    }
    const receipt_path = try std.fs.path.join(allocator, &.{ transport, "paint-receipt.json" });
    defer allocator.free(receipt_path);
    try writePaintReceipt(allocator, receipt_path, &fixture, first_proof, &font_facts, &rgb_hashes, source_commit);

    const artifact_path = try std.fs.path.join(allocator, &.{ transport, "project-paint-v1.bmp" });
    defer allocator.free(artifact_path);
    const canonical_exists = blk: {
        var file = std.fs.cwd().openFile(artifact_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        file.close();
        break :blk true;
    };
    std.debug.print("paint export artifact contract expected=1 actual={d}; renders=3 matching-rgb-hashes=1\n", .{@intFromBool(canonical_exists)});
    try std.testing.expectEqual(@as(usize, 1), @as(usize, @intFromBool(canonical_exists)));
}

test "paint export: project-paint-764" {
    try paint764Export(.project);
}

test "paint export: overview-paint-764" {
    try paint764Export(.overview);
}

const VisualFinishScene = enum {
    project_zero_100,
    project_one_100,
    project_many_100,
    overview_many_100,
    workspace_header_local,
    controls_states,
    attention_matrix_100,
};

fn visualFinishFixture(allocator: std.mem.Allocator, count: usize) !GraphModel.Model {
    var model = GraphModel.Model.init(allocator);
    errdefer model.deinit();
    const frame = try std.fmt.allocPrint(allocator, "{{\"graphChanged\":{{\"project\":{{\"path\":\"C:\\\\VisualFixture\",\"name\":\"Canvas Fixture\"}},\"nodes\":[" ++
        "{{\"id\":\"source\",\"title\":\"Source\",\"loopType\":\"sketch\",\"state\":\"{s}\",\"createdAt\":1}}," ++
        "{{\"id\":\"goal\",\"title\":\"Review synthetic result\",\"loopType\":\"goalBased\",\"state\":\"{s}\",\"presence\":{{\"presence\":\"{s}\"}},\"goal\":{{\"summary\":\"Inspect the synthetic result.\"}},\"createdAt\":1}}," ++
        "{{\"id\":\"blocked\",\"title\":\"Downstream\",\"loopType\":\"sketch\",\"state\":\"{s}\",\"createdAt\":1}}]," ++
        "\"edges\":[{{\"id\":\"handoff\",\"from\":\"source\",\"to\":\"blocked\",\"kind\":\"handoff\",\"fired\":false}}]}}}}", .{ if (count > 1) "failed" else "running", if (count != 0) "running" else "idle", if (count != 0) "awaitingInput" else "idle", if (count > 1) "blocked" else "idle" });
    defer allocator.free(frame);
    _ = try model.updateFromFrame(frame);
    try std.testing.expectEqual(if (count > 1) @as(usize, 3) else count, model.attentionCount());
    try std.testing.expect(model.setSelectedID("goal"));
    return model;
}

fn paintVisualFinish(dib: ParityDib, allocator: std.mem.Allocator, scene: VisualFinishScene) !void {
    const count: usize = switch (scene) {
        .project_zero_100 => 0,
        .project_one_100 => 1,
        else => 3,
    };
    var model = try visualFinishFixture(allocator, count);
    defer model.deinit();
    const surface: Surface = switch (scene) {
        .overview_many_100 => .overview,
        .workspace_header_local => .workspace,
        else => .project,
    };
    const bounds = chrome764GraphBounds();
    var state = try modelTestState(&model, .{}, bounds);
    defer state.deinitLayout();
    var sidebar = Sidebar.State.init(allocator);
    defer sidebar.deinit();
    paint(dib.dc, 1280, 720, &model, null, "", 0, "", "", "", false, "", &.{}, &.{}, allocator, &state, &sidebar, -1, .{ .rail_visible = true, .panel_visible = false, .activity_enabled = false }, surface);
    paintHeader(dib.dc, allocator, 1280, "", .{
        .title = "Canvas Fixture",
        .project_glyph = if (surface == .workspace) .folder else null,
        .detail_left = Tokens.sidebar_width,
    }, null);
    if (surface != .workspace) paintAddButton(dib.dc, allocator, addButtonBounds(bounds), "New Node", false, false);
    if (scene == .controls_states or scene == .attention_matrix_100) {
        fill(dib.dc, bounds, Tokens.canvas_tone);
        drawGrid(dib.dc, bounds, &.{});
        if (scene == .controls_states) {
            for ([_]bool{ false, true }, 0..) |highlighted, index| {
                const x: i32 = 280 + @as(i32, @intCast(index)) * 180;
                paintAddButton(dib.dc, allocator, rect(x, 90, x + 118, 120), "New Node", highlighted, highlighted);
            }
            var node = parityTestNode();
            node.id = @constCast("reclaim");
            node.title = @constCast("Resolved Goal");
            node.state = @constCast("succeeded");
            node.presence = @constCast("idle");
            node.created_at = null;
            for ([_]f32{ 1, 0.55 }, 0..) |zoom, index| {
                const x: i32 = 280 + @as(i32, @intCast(index)) * 340;
                const card = rect(x, 200, x + scaledValue(250, zoom), 200 + scaledValue(96, zoom));
                drawLoopCardShadow(dib.dc, allocator, node, card, &.{ .zoom = zoom }, .interior, false, false);
                drawLoopCard(dib.dc, allocator, node, card, &.{ .zoom = zoom }, .interior, false, null, false, .{ .default_branch = "main" }, true);
            }
            drawZoomControls(dib.dc, allocator, bounds, &.{});
        } else {
            const matrix_bounds = rect(0, Tokens.header_height, 1280, 720);
            fill(dib.dc, matrix_bounds, Tokens.canvas_tone);
            drawGrid(dib.dc, matrix_bounds, &.{});
            const types = [_][]const u8{ "goalBased", "sketch", "composite", "sketch" };
            for (types, 0..) |kind, row| {
                for (0..4) |column| {
                    var node = parityTestNode();
                    node.id = @constCast("attention-matrix");
                    node.title = @constCast(if (row == 0) "Needs you" else if (row == 3 and column >= 2) "Waiting upstream" else "Blocked");
                    node.loop_type = @constCast(kind);
                    node.state = @constCast(if (row == 0) "running" else "blocked");
                    node.presence = @constCast(if (row == 0) "awaitingInput" else "idle");
                    node.created_at = null;
                    var upstream = graphRoleTestNode("upstream");
                    upstream.state = @constCast(if (row == 3) "running" else "failed");
                    const nodes = [_]GraphModel.Node{ upstream, node };
                    const edges = [_]GraphModel.Edge{graphRoleTestEdge("upstream", node.id, "handoff")};
                    const graph_edges: []const GraphModel.Edge = if (column < 2) &.{} else &edges;
                    const roles = try resolveCardRoles(allocator, &nodes, graph_edges, &.{});
                    defer allocator.free(roles);
                    const warm = needsAttention(node, &nodes, graph_edges);
                    try std.testing.expectEqual(row == 0 or (row != 3 and column >= 2), warm);
                    const role = roles[1];
                    try std.testing.expectEqual(if (column < 2) NodeRole.unwired else NodeRole.interior, role);
                    const selected = column % 2 == 1;
                    const x: i32 = 30 + @as(i32, @intCast(column)) * 310;
                    const y: i32 = 100 + @as(i32, @intCast(row)) * 145;
                    const card = rect(x, y, x + 250, y + 96);
                    drawTextRect(dib.dc, allocator, if (column < 2)
                        (if (selected) "Unwired / selected" else "Unwired / unselected")
                    else
                        (if (selected) "Wired / selected" else "Wired / unselected"), rect(x, y - 25, x + 250, y - 5), 11, 0x00B0B0B0, c.DT_LEFT | c.DT_SINGLELINE);
                    drawLoopCardShadow(dib.dc, allocator, node, card, &.{}, role, warm, selected);
                    drawLoopCard(dib.dc, allocator, node, card, &.{}, role, warm, primaryCardAction(node), selected, null, true);
                }
            }
        }
    }
    if (c.GdiFlush() == 0) return error.PaintFixtureFlushFailed;
}

test "paint export: canvas-visual-finish" {
    const allocator = std.testing.allocator;
    const root = std.process.getEnvVarOwned(allocator, "GRAPHCODE_VISUAL_FINISH_EXPORT_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(root);
    const commit = try std.process.getEnvVarOwned(allocator, "GRAPHCODE_PAINT_SOURCE_COMMIT");
    defer allocator.free(commit);
    if (commit.len != 40) return error.PaintExportSourceCommitInvalid;
    for (commit) |character| if (!std.ascii.isHex(character)) return error.PaintExportSourceCommitInvalid;
    var directory = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer directory.close();
    var iterator = directory.iterate();
    if (try iterator.next() != null) return error.PaintExportRootNotEmpty;
    try chrome764Native();
    var receipt = std.array_list.Managed(u8).init(allocator);
    defer receipt.deinit();
    try receipt.writer().print("{{\"evidenceClass\":\"offscreen component paint only\",\"baseCommit\":\"{s}\",\"logicalDpi\":96,\"width\":1280,\"height\":720,\"scenes\":[", .{commit});
    for (std.enums.values(VisualFinishScene), 0..) |scene, index| {
        var first_rgb: [32]u8 = undefined;
        for (0..3) |repeat| {
            var dib = try ParityDib.init(1280, 720);
            defer dib.deinit();
            try paintVisualFinish(dib, allocator, scene);
            const rgb = try dib.rgbSha256(allocator);
            if (repeat == 0) first_rgb = rgb else try std.testing.expectEqualSlices(u8, &first_rgb, &rgb);
            const name = try std.fmt.allocPrint(allocator, "{s}-{d}.bmp", .{ @tagName(scene), repeat + 1 });
            defer allocator.free(name);
            const path = try std.fs.path.join(allocator, &.{ root, name });
            defer allocator.free(path);
            const digest = try dib.writeBmp(allocator, path);
            if (repeat == 0) {
                if (index != 0) try receipt.append(',');
                try receipt.writer().print("{{\"scene\":\"{s}\",\"file\":\"{s}\",\"zoom\":1,\"repeats\":3,\"bmpSha256\":\"{x}\",\"rgbSha256\":\"{x}\"}}", .{ @tagName(scene), name, &digest, &rgb });
            }
        }
    }
    try receipt.appendSlice("]}\n");
    const receipt_path = try std.fs.path.join(allocator, &.{ root, "visual-finish-receipt.json" });
    defer allocator.free(receipt_path);
    var file = try std.fs.cwd().createFile(receipt_path, .{ .exclusive = true });
    defer file.close();
    try file.writeAll(receipt.items);
    std.debug.print("visual-finish export scenes=7 repeats=3 matching-rgb=7 logical-dpi=96; no desktop capture\n", .{});
}

test "paint scene 764 project inventory" {
    var fixture = try paint764FixtureModel(std.testing.allocator, .project);
    defer fixture.model.deinit();
    try verifyPaint764Inventory(&fixture, .project);
}

test "paint scene 764 overview inventory" {
    var fixture = try paint764FixtureModel(std.testing.allocator, .overview);
    defer fixture.model.deinit();
    try verifyPaint764Inventory(&fixture, .overview);
}

var paint764TestRendererInitAttempted = false;
var paint764TestRendererReady = false;

fn initPaint764TestRenderer() !void {
    if (paint764TestRendererReady) return;
    if (paint764TestRendererInitAttempted) return error.Paint764TestGdiplusNotReady;
    const export_root: ?[]u8 = std.process.getEnvVarOwned(std.testing.allocator, "GRAPHCODE_PAINT_EXPORT_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (export_root) |root| {
        defer std.testing.allocator.free(root);
        if (root.len == 0) return error.PaintExportDirectoryEmpty;
    } else {
        const native = std.process.getEnvVarOwned(std.testing.allocator, "GRAPHCODE_NATIVE_PAINT_TESTS") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return,
            else => return err,
        };
        defer std.testing.allocator.free(native);
        if (!std.mem.eql(u8, native, "1")) return error.Paint764NativeTestFlagInvalid;
    }
    paint764TestRendererInitAttempted = true;
    GdiplusAA.init();
    const deadline = std.time.nanoTimestamp() + 2_000_000_000;
    while (!GdiplusAA.isReady()) {
        if (std.time.nanoTimestamp() >= deadline) return error.Paint764TestGdiplusNotReady;
        std.Thread.sleep(1_000_000);
    }
    paint764TestRendererReady = true;
}

fn paint764TestSurface(
    dib: ParityDib,
    fixture: *const Paint764Fixture,
    allocator: std.mem.Allocator,
    scene: Paint764Scene,
) !void {
    const surface: Surface = if (scene == .project) .project else .overview;
    try paintExportFixture(dib, &fixture.model, allocator, surface, paint764HeaderContext(scene));
}

fn paint764ExpectedAccent(loop_type: []const u8) ?u32 {
    if (std.mem.eql(u8, loop_type, "sketch")) return 0x00E3DAD3;
    if (std.mem.eql(u8, loop_type, "goalBased")) return 0x00709E19;
    if (std.mem.eql(u8, loop_type, "timeBased")) return 0x000085C9;
    if (std.mem.eql(u8, loop_type, "turnBased")) return 0x008151D5;
    if (std.mem.eql(u8, loop_type, "composite")) return 0x00E98590;
    return null;
}

const Chrome764Checks = struct {
    observations: usize = 0,
    failures: usize = 0,

    fn expect(self: *Chrome764Checks, condition: bool, name: []const u8, scene: Paint764Scene, node: []const u8) void {
        self.observations += 1;
        if (!condition) {
            self.failures += 1;
            std.debug.print("chrome764 missing={s} surface={s} node={s}\n", .{ name, @tagName(scene), node });
        }
    }

    fn pixel(self: *Chrome764Checks, actual: u32, expected: u32, name: []const u8, scene: Paint764Scene, node: []const u8) void {
        const matches = chrome764ColorNear(actual, expected, 1);
        self.expect(matches, name, scene, node);
        if (!matches) std.debug.print("  expected=0x{x:0>6} actual=0x{x:0>6} channel-tolerance=1\n", .{ expected, actual });
    }

    fn finish(self: Chrome764Checks, failure: anyerror) !void {
        std.debug.print("chrome764 observations={d} passed={d} failed={d} native-ready={}\n", .{
            self.observations, self.observations - self.failures, self.failures, GdiplusAA.isReady(),
        });
        if (self.observations == 0) return error.Chrome764NoObservations;
        if (self.failures != 0) return failure;
    }
};

fn chrome764ColorNear(actual: u32, expected: u32, tolerance: u32) bool {
    if (actual == c.CLR_INVALID) return false;
    for ([_]u5{ 0, 8, 16 }) |shift| {
        const a: i32 = @intCast((actual >> shift) & 255);
        const b: i32 = @intCast((expected >> shift) & 255);
        if (@abs(a - b) > tolerance) return false;
    }
    return true;
}

fn chrome764Face(attention: bool, y: i32, height: i32) u32 {
    const top: u32 = if (attention) 0x00222A30 else 0x00302C2C;
    const bottom: u32 = if (attention) 0x00202226 else 0x00262323;
    var result: u32 = 0;
    for ([_]u5{ 0, 8, 16 }) |shift| {
        const a: f64 = @floatFromInt((top >> shift) & 255);
        const b: f64 = @floatFromInt((bottom >> shift) & 255);
        const t = (@as(f64, @floatFromInt(y)) + 0.5) / @as(f64, @floatFromInt(height));
        const channel: u32 = @intFromFloat(@round(a + (b - a) * t));
        result |= channel << shift;
    }
    return result;
}

fn chrome764Blend(foreground: u32, background: u32, percent: u32) u32 {
    var result: u32 = 0;
    for ([_]u5{ 0, 8, 16 }) |shift| {
        const a = (foreground >> shift) & 255;
        const b = (background >> shift) & 255;
        result |= ((a * percent + b * (100 - percent) + 50) / 100) << shift;
    }
    return result;
}

fn chrome764Native() !void {
    try initPaint764TestRenderer();
    if (!paint764TestRendererReady) return error.SkipZigTest;
    try std.testing.expect(GdiplusAA.isReady());
}

fn chrome764GraphBounds() c.RECT {
    const bounds = renderBounds(1280, 720, .{
        .graph_visible = true,
        .rail_visible = true,
        .panel_visible = false,
        .activity_enabled = false,
    });
    return rect(bounds.left, bounds.top, bounds.right, bounds.bottom);
}

fn chrome764Card(fixture: *const Paint764Fixture, scene: Paint764Scene, index: usize, state: *const CanvasState) c.RECT {
    return if (scene == .project)
        nodeBounds(index, state)
    else
        overviewCardBounds(&fixture.model, 0, index, chrome764GraphBounds(), state);
}

fn chrome764Map(dib: ParityDib, dpi: i32) !void {
    if (c.SetMapMode(dib.dc, c.MM_ANISOTROPIC) == 0 or
        c.SetWindowExtEx(dib.dc, 96, 96, null) == 0 or
        c.SetViewportExtEx(dib.dc, dpi, dpi, null) == 0)
        return error.Chrome764MappingFailed;
}

fn chrome764DibPixel(dib: ParityDib, x: i32, y: i32, dpi: i32) !u32 {
    if (c.GdiFlush() == 0) return error.Chrome764FlushFailed;
    const px = std.math.cast(usize, @divTrunc(x * dpi, 96)) orelse return error.Chrome764SampleOutsideDib;
    const py = std.math.cast(usize, @divTrunc(y * dpi, 96)) orelse return error.Chrome764SampleOutsideDib;
    if (px >= dib.width or py >= dib.height) return error.Chrome764SampleOutsideDib;
    const offset = py * dib.row_bytes + px * 4;
    return @as(u32, dib.pixels[offset + 2]) |
        (@as(u32, dib.pixels[offset + 1]) << 8) |
        (@as(u32, dib.pixels[offset]) << 16);
}

fn chrome764Paint(
    dib: ParityDib,
    fixture: *const Paint764Fixture,
    scene: Paint764Scene,
    state: *const CanvasState,
    inspection: ?*const WorktreeStatus.Inspection,
    entries: []const []const u8,
) !void {
    const owns_layout = state.layout_fingerprint == null or entries.len > 0;
    var prepared = if (owns_layout) try modelTestState(&fixture.model, state.*, chrome764GraphBounds()) else state.*;
    defer if (owns_layout) prepared.deinitLayout();
    if (entries.len > 0) try prepared.syncLayout(std.testing.allocator, &fixture.model, chrome764GraphBounds(), &.{}, entries);
    var sidebar = Sidebar.State.init(std.testing.allocator);
    defer sidebar.deinit();
    paint(
        dib.dc,
        1280,
        720,
        &fixture.model,
        inspection,
        "",
        0,
        "",
        "",
        "",
        false,
        "",
        entries,
        &.{},
        std.testing.allocator,
        &prepared,
        &sidebar,
        -1,
        .{ .graph_visible = true, .rail_visible = true, .panel_visible = false, .activity_enabled = false },
        if (scene == .project) .project else .overview,
    );
    if (c.GdiFlush() == 0) return error.Chrome764FlushFailed;
}

fn chrome764Replace(destination: *[]u8, value: []const u8) !void {
    const owned = try std.testing.allocator.dupe(u8, value);
    std.testing.allocator.free(destination.*);
    destination.* = owned;
}

fn chrome764State(fixture: *Paint764Fixture, index: usize, state: []const u8, presence: []const u8) !void {
    const project = &(fixture.model.graph orelse return error.Chrome764ProjectMissing).nodes.items[index];
    const overview = &fixture.model.graphs.items[0].nodes.items[index];
    try chrome764Replace(&project.state, state);
    try chrome764Replace(&project.presence, presence);
    try chrome764Replace(&overview.state, state);
    try chrome764Replace(&overview.presence, presence);
}

fn chrome764IsolatedFixture() !Paint764Fixture {
    var fixture = try paint764FixtureModel(std.testing.allocator, .project);
    errdefer fixture.model.deinit();
    _ = try fixture.model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"id":"paint-764-project","project":{"path":"C:\\GraphCodeFixture\\CardStates","name":"Card States"},"nodes":[{"id":"chrome-isolated","title":"Isolated chrome","loopType":"goalBased","state":"idle","backend":"copilotCLI","firstInstruction":"In-memory native chrome check."}],"edges":[]}}}
    );
    return fixture;
}

test "loop card parity chrome 764 normal gradient and shared surfaces" {
    try chrome764Native();
    var fixture = try paint764FixtureModel(std.testing.allocator, .overview);
    defer fixture.model.deinit();
    var project = try ParityDib.init(1280, 720);
    defer project.deinit();
    var overview = try ParityDib.init(1280, 720);
    defer overview.deinit();
    var state = try modelTestState(&fixture.model, .{}, chrome764GraphBounds());
    defer state.deinitLayout();
    try chrome764Paint(project, &fixture, .project, &state, null, &.{});
    try chrome764Paint(overview, &fixture, .overview, &state, null, &.{});
    var checks = Chrome764Checks{};
    for ([_]usize{ 0, 1, 3, 4 }) |index| {
        const node = fixture.model.graphs.items[0].nodes.items[index];
        const pb = chrome764Card(&fixture, .project, index, &state);
        const ob = chrome764Card(&fixture, .overview, index, &state);
        for ([_]i32{ 16, 48, 80 }) |y| {
            const expected = chrome764Face(false, y, 96);
            const pp = c.GetPixel(project.dc, pb.right - 7, pb.top + y);
            const op = c.GetPixel(overview.dc, ob.right - 7, ob.top + y);
            checks.pixel(pp, expected, "normal-local-gradient", .project, node.id);
            checks.pixel(op, expected, "normal-local-gradient", .overview, node.id);
            checks.pixel(pp, op, "shared-local-face", .overview, node.id);
            checks.pixel(
                c.GetPixel(project.dc, pb.left + 2, pb.top + 48),
                c.GetPixel(overview.dc, ob.left + 2, ob.top + 48),
                "shared-local-stripe", .overview, node.id,
            );
        }
        for ([_]Paint764Scene{ .project, .overview }) |scene| {
            const dib = if (scene == .project) project else overview;
            const bounds = chrome764Card(&fixture, scene, index, &state);
            const top = c.GetPixel(dib.dc, bounds.right - 7, bounds.top + 16);
            const bottom = c.GetPixel(dib.dc, bounds.right - 7, bounds.top + 80);
            checks.expect((top & 255) >= (bottom & 255) + 3, "normal-top-to-bottom-variation", scene, node.id);
        }
    }
    try checks.finish(error.Chrome764NormalGradientMissing);
}

test "loop card parity chrome 764 warmth remains independent of primary actions" {
    try chrome764Native();
    var fixture = try paint764FixtureModel(std.testing.allocator, .overview);
    defer fixture.model.deinit();
    var dib = try ParityDib.init(1280, 720);
    defer dib.deinit();
    var checks = Chrome764Checks{};
    var state = try modelTestState(&fixture.model, .{}, chrome764GraphBounds());
    defer state.deinitLayout();
    for (0..2) |variant| {
        if (variant == 1) {
            try chrome764State(&fixture, 0, "failed", "idle");
            try chrome764State(&fixture, 1, "running", "busy");
            try chrome764State(&fixture, 3, "stalled", "idle");
        }
        const expected_warm = if (variant == 0)
            [_]bool{ false, false, true, false, false, true }
        else
            [_]bool{ true, false, false, true, false, true };
        const graph = fixture.model.graphs.items[0];
        for ([_]Paint764Scene{ .project, .overview }) |scene| {
            for (graph.nodes.items, 0..) |node, index| {
                state.pan_x = 0;
                state.pan_y = 0;
                const unpanned = chrome764Card(&fixture, scene, index, &state);
                if (unpanned.right > 1280) state.pan_x = @floatFromInt(1200 - unpanned.right);
                try chrome764Paint(dib, &fixture, scene, &state, null, &.{});
                const warm = needsAttention(node, graph.nodes.items, graph.edges.items);
                checks.expect(warm == expected_warm[index], "preserved-attention-classification", scene, node.id);
                const bounds = chrome764Card(&fixture, scene, index, &state);
                checks.pixel(c.GetPixel(dib.dc, bounds.right - 7, bounds.top + 48),
                    chrome764Face(expected_warm[index], 48, 96), "reason-selected-face", scene, node.id);
                const action = primaryCardAction(node);
                const expected_action: ?AttentionAction = if (index == 2) .inspect else if (index == 5) .reply else null;
                checks.expect(action == expected_action, "preserved-independent-primary-action", scene, node.id);
                const action_pixels = dib.count(attentionActionBounds(bounds, &state), 0x000A9FFF);
                checks.expect(if (expected_action != null) action_pixels > 20 else action_pixels == 0,
                    "primary-action-pixels-independent-of-warmth", scene, node.id);
            }
        }
    }
    try checks.finish(error.Chrome764AttentionFaceMissing);
}

test "loop card parity chrome 764 tinted falloff and offset black lift on both grounds" {
    try chrome764Native();
    var fixture = try chrome764IsolatedFixture();
    defer fixture.model.deinit();
    var normal = try ParityDib.init(1280, 720);
    defer normal.deinit();
    var warm = try ParityDib.init(1280, 720);
    defer warm.deinit();
    var background = try ParityDib.init(1280, 720);
    defer background.deinit();
    var checks = Chrome764Checks{};
    var state = try modelTestState(&fixture.model, .{}, chrome764GraphBounds());
    defer state.deinitLayout();
    for ([_]Paint764Scene{ .project, .overview }) |scene| {
        try chrome764State(&fixture, 0, "idle", "idle");
        try chrome764Paint(normal, &fixture, scene, &state, null, &.{"chrome-isolated"});
        try chrome764State(&fixture, 0, "failed", "idle");
        try chrome764Paint(warm, &fixture, scene, &state, null, &.{"chrome-isolated"});
        const bounds = chrome764Card(&fixture, scene, 0, &state);
        fill(background.dc, rect(0, 0, 1280, 720), Tokens.canvas_tone);
        drawGrid(background.dc, chrome764GraphBounds(), &state);
        if (scene == .project) {
            drawLaneBand(background.dc, graphBand(1, .{ .state = &state }).?, 1);
        } else {
            const lane = overviewLaneBounds(&fixture.model, 0, chrome764GraphBounds(), &state);
            drawLaneBand(background.dc, rect(lane.left - 18, lane.top, lane.right, lane.bottom), 1);
        }
        // Clear of caption ink; measure shadow contrast against the actual grid/band, not an opaque lane.
        const x = bounds.left + 225;
        var last_green: u32 = 255;
        var last_orange: u32 = 255;
        for ([_]i32{ 6, 12, 20 }) |distance| {
            const np = c.GetPixel(normal.dc, x, bounds.top - distance);
            const wp = c.GetPixel(warm.dc, x, bounds.top - distance);
            const ground = c.GetPixel(background.dc, x, bounds.top - distance);
            const green = ((np >> 8) & 255) -| ((ground >> 8) & 255);
            const orange = (wp & 255) -| (ground & 255);
            checks.expect(green > 0, "positive-type-tinted-halo", scene, "chrome-isolated");
            checks.expect(orange > 0, "positive-attention-orange-halo", scene, "chrome-isolated");
            checks.expect(green <= last_green and orange <= last_orange, "bounded-alpha-falloff-not-flat-rings", scene, "chrome-isolated");
            if (distance == 20) checks.expect(orange > green, "emphasized-halo-wider-and-stronger", scene, "chrome-isolated");
            last_green = green;
            last_orange = orange;
            std.debug.print("chrome764 halo surface={s} distance={d} normal=0x{x} warm=0x{x} ground=0x{x}\n",
                .{ @tagName(scene), distance, np, wp, ground });
        }
        for ([_]i32{ 2, 7 }) |distance| {
            const above = c.GetPixel(normal.dc, x, bounds.top - distance);
            const below = c.GetPixel(normal.dc, x, bounds.bottom + distance);
            checks.expect((below & 255) < (above & 255), "downward-contact-and-ambient-black-lift", scene, "chrome-isolated");
        }
        checks.pixel(c.GetPixel(normal.dc, bounds.right + 80, bounds.top + 48),
            c.GetPixel(warm.dc, bounds.right + 80, bounds.top + 48),
            "finite-shadow-support-leaves-far-ground-unchanged", scene, "chrome-isolated");
    }
    try checks.finish(error.Chrome764HaloAndContactShadowMissing);
}

test "loop card parity chrome 764 rounded stripe alpha hairline and unwired dash" {
    try chrome764Native();
    var fixture = try paint764FixtureModel(std.testing.allocator, .overview);
    defer fixture.model.deinit();
    var dib = try ParityDib.init(1280, 720);
    defer dib.deinit();
    var checks = Chrome764Checks{};
    var state = try modelTestState(&fixture.model, .{}, chrome764GraphBounds());
    defer state.deinitLayout();
    const accent: u32 = 0x008151D5;
    for ([_]bool{ false, true }) |attention| {
        try chrome764State(&fixture, 5, if (attention) "running" else "idle", if (attention) "awaitingInput" else "idle");
        for ([_]Paint764Scene{ .project, .overview }) |scene| {
            try chrome764Paint(dib, &fixture, scene, &state, null, &.{});
            const bounds = chrome764Card(&fixture, scene, 5, &state);
            const face = chrome764Face(attention, 40, 96);
            checks.pixel(c.GetPixel(dib.dc, bounds.left + 2, bounds.top + 40), chrome764Blend(accent, face, 35), "unwired-alpha-over-local-gradient", scene, "fixture-turn-needs-you");
            const corner = c.GetPixel(dib.dc, bounds.left + 1, bounds.top + 1);
            const middle = c.GetPixel(dib.dc, bounds.left + 1, bounds.top + 40);
            checks.expect(!chrome764ColorNear(corner, middle, 8), "radius11-corner-excludes-rectangular-stripe", scene, "fixture-turn-needs-you");
            var transitions: usize = 0;
            var previous = c.GetPixel(dib.dc, bounds.left + 30, bounds.bottom);
            var x = bounds.left + 31;
            while (x < bounds.left + 120) : (x += 1) {
                const pixel = c.GetPixel(dib.dc, x, bounds.bottom);
                if (!chrome764ColorNear(pixel, previous, 2)) transitions += 1;
                previous = pixel;
            }
            checks.expect(transitions >= 12, "unwired-four-three-dashed-hairline", scene, "fixture-turn-needs-you");
            const upper = c.GetPixel(dib.dc, bounds.right - 1, bounds.top + 16);
            const lower = c.GetPixel(dib.dc, bounds.right - 1, bounds.top + 80);
            checks.expect(!chrome764ColorNear(upper, lower, 1), "alpha-hairline-preserves-local-face-variation", scene, "fixture-turn-needs-you");
        }
        if (!fixture.model.setSelectedIndex(5)) return error.Chrome764SelectionFailed;
        try chrome764Paint(dib, &fixture, .project, &state, null, &.{});
        const bounds = nodeBounds(5, &state);
        checks.expect(dib.count(rect(bounds.left + 20, bounds.top, bounds.left + 220, bounds.top + 1),
            Tokens.canvas_selection) >= 190, "selected-unwired-solid-blue-precedence", .project, "fixture-turn-needs-you");
        if (!fixture.model.setSelectedIndex(0)) return error.Chrome764SelectionFailed;
    }
    try checks.finish(error.Chrome764RoundedStripeAndDashedAlphaBorderMissing);
}

test "loop card parity chrome 764 zoom mapping and graph viewport clip" {
    try chrome764Native();
    var fixture = try chrome764IsolatedFixture();
    defer fixture.model.deinit();
    try chrome764State(&fixture, 0, "failed", "idle");
    var dib = try ParityDib.init(2600, 1500);
    defer dib.deinit();
    var checks = Chrome764Checks{};
    const graph_bounds = chrome764GraphBounds();
    for ([_]i32{ 96, 120, 144, 192 }) |dpi| {
        for ([_]f32{ 0.55, 0.75, 1, 1.25, 1.8 }) |zoom| {
            for ([_]Paint764Scene{ .project, .overview }) |scene| {
                const saved = c.SaveDC(dib.dc);
                if (saved == 0) return error.Chrome764SaveDcFailed;
                defer _ = c.RestoreDC(dib.dc, saved);
                try chrome764Map(dib, dpi);
                const sentinel: u32 = 0x00EF12AB;
                fill(dib.dc, rect(0, 0, 1280, 720), sentinel);
                if (c.IntersectClipRect(dib.dc, graph_bounds.left, graph_bounds.top, graph_bounds.right, graph_bounds.bottom) == c.ERROR)
                    return error.Chrome764ClipFailed;
                var state = try modelTestState(&fixture.model, .{ .zoom = zoom }, graph_bounds);
                defer state.deinitLayout();
                const unshifted = chrome764Card(&fixture, scene, 0, &state);
                state.pan_x = @floatFromInt(300 - unshifted.left);
                state.pan_y = @floatFromInt(200 - unshifted.top);
                try chrome764Paint(dib, &fixture, scene, &state, null, &.{"chrome-isolated"});
                const bounds = chrome764Card(&fixture, scene, 0, &state);
                const stripe_x = bounds.left + @divTrunc(scaledValue(4, zoom), 2);
                checks.pixel(c.GetPixel(dib.dc, stripe_x, bounds.top + scaledValue(12, zoom)),
                    0x00709E19, "stripe-radius-and-HDC-mapping-scale-once", scene, "chrome-isolated");
                checks.expect(!chrome764ColorNear(c.GetPixel(dib.dc, bounds.left + scaledValue(1, zoom),
                    bounds.top + scaledValue(1, zoom)), 0x00709E19, 1),
                    "scaled-rounded-corner-clips-stripe", scene, "chrome-isolated");
                const sample_y = bounds.top - scaledValue(12, zoom);
                const sample_x = bounds.left + scaledValue(125, zoom);
                const ground: u32 = if (scene == .project) Tokens.canvas_tone else Tokens.workspace_rail;
                const halo = c.GetPixel(dib.dc, sample_x, sample_y);
                checks.expect((halo & 255) > (ground & 255), "scaled-halo-overflows-card-within-viewport", scene, "chrome-isolated");
                checks.pixel(try chrome764DibPixel(dib, graph_bounds.left - 2, 200, dpi), sentinel,
                    "left-viewport-sentinel-unchanged", scene, "chrome-isolated");
                checks.pixel(try chrome764DibPixel(dib, 400, graph_bounds.top - 2, dpi), sentinel,
                    "top-viewport-sentinel-unchanged", scene, "chrome-isolated");
                var clip: c.RECT = undefined;
                if (c.GetClipBox(dib.dc, &clip) == c.ERROR) return error.Chrome764ClipQueryFailed;
                checks.expect(clip.left == graph_bounds.left and clip.top == graph_bounds.top and
                    clip.right == graph_bounds.right and clip.bottom == graph_bounds.bottom,
                    "caller-clip-restored-after-card-chrome", scene, "chrome-isolated");
                std.debug.print("chrome764 mapped surface={s} dpi={d} zoom={d} card=({d},{d},{d},{d}) halo=0x{x}\n",
                    .{ @tagName(scene), dpi, zoom, bounds.left, bounds.top, bounds.right, bounds.bottom, halo });
            }
        }
    }
    try checks.finish(error.Chrome764ScaledChromeOrViewportContractMissing);
}

test "loop card parity chrome 764 preserves geometry content roles and affordances" {
    try chrome764Native();
    var fixture = try paint764FixtureModel(std.testing.allocator, .overview);
    defer fixture.model.deinit();
    var dib = try ParityDib.init(1280, 720);
    defer dib.deinit();
    var checks = Chrome764Checks{};
    var state = try modelTestState(&fixture.model, .{}, chrome764GraphBounds());
    defer state.deinitLayout();
    const graph_bounds = chrome764GraphBounds();
    try verifyPaint764Inventory(&fixture, .overview);
    const project_size = contentSize(&fixture.model, .project, &state);
    const overview_size = contentSize(&fixture.model, .overview, &state);
    checks.expect(project_size.width == 1472 and project_size.height == 518, "project-fit-excludes-noninteractive-halo", .project, "fixture-main-idle");
    checks.expect(overview_size.width == 1682 and overview_size.height == 696, "overview-fit-excludes-noninteractive-halo", .overview, "fixture-main-idle");
    for ([_]usize{ 0, 5 }) |selected| {
        if (!fixture.model.setSelectedIndex(selected)) return error.Chrome764SelectionFailed;
        for ([_]Paint764Scene{ .project, .overview }) |scene| {
            const graph = fixture.model.graphs.items[0];
            const roles = try resolveCardRoles(std.testing.allocator, graph.nodes.items, graph.edges.items, &.{});
            defer std.testing.allocator.free(roles);
            checks.expect(roles[0] == .entry and roles[5] == .unwired, "entry-and-unwired-roles-preserved", scene, "fixture-main-idle");
            for (graph.nodes.items, 0..) |node, index| {
                state.pan_x = 0;
                state.pan_y = 0;
                const unpanned = chrome764Card(&fixture, scene, index, &state);
                if (unpanned.right > 1280) state.pan_x = @floatFromInt(1200 - unpanned.right);
                try chrome764Paint(dib, &fixture, scene, &state, null, &.{});
                const bounds = chrome764Card(&fixture, scene, index, &state);
                try verifyPaint764CardPixels(dib, std.testing.allocator, node, bounds, roles[index], needsAttention(node, graph.nodes.items, graph.edges.items), @intCast(std.time.timestamp()), state.zoom);
                checks.expect(bounds.right - bounds.left == scaledValue(250, state.zoom) and bounds.bottom - bounds.top == scaledValue(96, state.zoom), "250-by-96-logical-hit-geometry-preserved", scene, node.id);
                const live = try cardLiveLine(std.testing.allocator, node);
                defer std.testing.allocator.free(live);
                if (live.len != 0) {
                    const rows = cardTextLayout(bounds, state.zoom, scaledValue(80, state.zoom));
                    checks.expect(dib.count(rows.live, 0x009F9C9C) > 0, "description-or-activity-ink-preserved", scene, node.id);
                }
                const x = bounds.left + scaledValue(125, state.zoom);
                const y = bounds.top + scaledValue(48, state.zoom);
                if (scene == .project) {
                    checks.expect(hitTest(graph.nodes.items, x, y, &state, graph_bounds) == index,
                        "project-hit-and-activation-identity", scene, node.id);
                    checks.expect(hitTest(graph.nodes.items, x, bounds.top - 4, &state, graph_bounds) == null,
                        "halo-overflow-not-interactive", scene, node.id);
                } else {
                    const hit = hitTestOverview(&fixture.model, x, y, &state, graph_bounds);
                    checks.expect(hit != null and hit.?.graph_index == 0 and hit.?.node_index == index,
                        "overview-hit-and-activation-identity", scene, node.id);
                    checks.expect(hitTestOverview(&fixture.model, x, bounds.top - 4, &state, graph_bounds) == null,
                        "halo-overflow-not-interactive", scene, node.id);
                }
                if (primaryCardAction(node) != null and scene == .project) {
                    const action = attentionActionBounds(bounds, &state);
                    checks.expect(hitTestAttentionAction(graph.nodes.items, graph.edges.items,
                        action.left + 1, action.top + 1, &state) == index,
                        "reply-inspect-action-hit-preserved", scene, node.id);
                }
            }
        }
    }
    for ([_]*GraphModel.Edge{
        &(fixture.model.graph orelse return error.Chrome764ProjectMissing).edges.items[1],
        &fixture.model.graphs.items[0].edges.items[1],
    }) |edge| try chrome764Replace(&edge.to, "fixture-main-idle");
    state.pan_x = 0;
    state.pan_y = 0;
    try state.syncLayout(std.testing.allocator, &fixture.model, graph_bounds, &.{}, &.{});
    for ([_]Paint764Scene{ .project, .overview }) |scene| {
        try chrome764Paint(dib, &fixture, scene, &state, null, &.{});
        const graph = fixture.model.graphs.items[0];
        const roles = try resolveCardRoles(std.testing.allocator, graph.nodes.items, graph.edges.items, &.{});
        defer std.testing.allocator.free(roles);
        checks.expect(roles[0] == .cycle_only and roles[1] == .cycle_only,
            "closed-handoff-cycle-role-preserved", scene, "fixture-main-idle");
        const bounds = chrome764Card(&fixture, scene, 0, &state);
        const chip = cardRoleChip(.cycle_only) orelse return error.Chrome764CycleChipMissing;
        checks.expect(dib.count(bounds, chip.fill) > 0, "cycle-role-chip-still-painted", scene, "fixture-main-idle");
    }
    var inspection = WorktreeStatus.Inspection{
        .entries = std.array_list.Managed(WorktreeStatus.Entry).init(std.testing.allocator),
        .default_branch = @constCast("main"),
        .project_path = @constCast("C:\\GraphCodeFixture\\CardStates"),
    };
    defer inspection.entries.deinit();
    try inspection.entries.append(.{
        .path = @constCast("C:\\GraphCodeFixture\\CardStates\\worktrees\\review"),
        .branch = @constCast("review"), .pushed = true, .landed = true,
    });
    try chrome764Paint(dib, &fixture, .project, &state, &inspection, &.{});
    const graph = (fixture.model.graph orelse return error.Chrome764ProjectMissing);
    const offer = reclaimOfferBounds(nodeBounds(1, &state));
    checks.expect(dib.count(offer.reclaim, 0x003A3535) > 20, "reclaim-rounded-fill-preserved", .project, "fixture-goal-done");
    checks.expect(dib.count(offer.keep, 0x00919191) > 0, "keep-semibold-label-preserved", .project, "fixture-goal-done");
    const reclaim = hitTestReclaimOffer(graph.nodes.items, &inspection, &.{}, offer.reclaim.left + 1, offer.reclaim.top + 1, &state);
    const keep = hitTestReclaimOffer(graph.nodes.items, &inspection, &.{}, offer.keep.left + 1, offer.keep.top + 1, &state);
    checks.expect(reclaim != null and reclaim.?.node_index == 1 and reclaim.?.action == .reclaim,
        "reclaim-hit-preserved", .project, "fixture-goal-done");
    checks.expect(keep != null and keep.?.node_index == 1 and keep.?.action == .keep,
        "keep-hit-preserved", .project, "fixture-goal-done");
    try checks.finish(error.Chrome764ExistingSemanticsRegressed);
}

fn label858Fixture() !Paint764Fixture {
    var fixture = try paint764FixtureModel(std.testing.allocator, .project);
    errdefer fixture.model.deinit();
    _ = try fixture.model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"id":"paint-764-project","project":{"path":"C:\\GraphCodeFixture\\CardStates","name":"Card States"},"nodes":[{"id":"label-0","title":"Layer zero","loopType":"goalBased","state":"idle"},{"id":"label-1","title":"Layer one","loopType":"goalBased","state":"idle"},{"id":"label-2","title":"Layer two","loopType":"goalBased","state":"idle"},{"id":"label-3","title":"Layer three","loopType":"goalBased","state":"idle"}],"edges":[{"id":"label-edge","from":"label-0","to":"label-3","kind":"handoff","condition":"always"}]}}}
    );
    if (!fixture.model.setSelectedIndex(1)) return error.Label858SelectionFailed;
    return fixture;
}

fn label858State(fixture: *const Paint764Fixture, initial: CanvasState) !CanvasState {
    const state = try modelTestState(&fixture.model, initial, chrome764GraphBounds());
    // These frozen 1x glyph/occlusion controls deliberately inject the old
    // synthetic scene. Production lane geometry is covered separately above.
    for (state.project_layout.?.positions, 0..) |*point, index| {
        point.* = .{
            .x = 157 + @as(f32, @floatFromInt(index % 3)) * 260,
            .y = 98 + @as(f32, @floatFromInt(index / 3)) * 140,
        };
    }
    return state;
}

fn label858RgbDistance(a: u32, b: u32) !u32 {
    if (a == c.CLR_INVALID or b == c.CLR_INVALID) return error.Label858InvalidPixel;
    var distance: u32 = 0;
    for ([_]u5{ 0, 8, 16 }) |shift| {
        const first: i32 = @intCast((a >> shift) & 255);
        const second: i32 = @intCast((b >> shift) & 255);
        distance += @abs(first - second);
    }
    return distance;
}

const label858Glyphs = [_]c.POINT{
    .{ .x = 390, .y = 195 }, .{ .x = 393, .y = 195 }, .{ .x = 362, .y = 197 },
    .{ .x = 367, .y = 197 }, .{ .x = 373, .y = 197 }, .{ .x = 378, .y = 197 },
    .{ .x = 384, .y = 197 }, .{ .x = 385, .y = 197 }, .{ .x = 389, .y = 197 },
    .{ .x = 390, .y = 197 }, .{ .x = 391, .y = 197 }, .{ .x = 392, .y = 197 },
    .{ .x = 393, .y = 197 }, .{ .x = 360, .y = 198 }, .{ .x = 371, .y = 198 },
    .{ .x = 367, .y = 199 }, .{ .x = 368, .y = 199 }, .{ .x = 366, .y = 201 },
    .{ .x = 367, .y = 201 }, .{ .x = 368, .y = 201 }, .{ .x = 378, .y = 201 },
    .{ .x = 379, .y = 201 }, .{ .x = 380, .y = 201 }, .{ .x = 384, .y = 201 },
    .{ .x = 385, .y = 201 },
};

const Label858Checks = struct {
    observations: usize = 0,
    failures: usize = 0,

    fn expect(self: *Label858Checks, condition: bool) void {
        self.observations += 1;
        if (!condition) self.failures += 1;
    }

    fn finish(self: Label858Checks, name: []const u8, failure: anyerror) !void {
        std.debug.print("label858 case={s} observations={d} failures={d} native-ready={}\n",
            .{ name, self.observations, self.failures, GdiplusAA.isReady() });
        if (self.observations == 0) return error.Label858NoObservations;
        if (self.failures != 0) return failure;
    }
};

fn label858Text(hdc: c.HDC, color: u32, bounds: c.RECT) void {
    drawTextRect(hdc, std.testing.allocator, "handoff", bounds, 10, color,
        c.DT_CENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);
}

fn label858Composition(dib: ParityDib, fixture: *const Paint764Fixture, state: *const CanvasState,
    order: enum { below, above, omitted }) !void
{
    const graph = fixture.model.graph orelse return error.Label858GraphMissing;
    fill(dib.dc, rect(0, 0, 1280, 720), Tokens.canvas_tone);
    drawGrid(dib.dc, chrome764GraphBounds(), state);
    drawEdges(dib.dc, graph, state);
    const color: u32 = if (state.selected_edge == 0) Tokens.canvas_selection else
        if (graph.edges.items[0].fired) 0x006BD58D else edgeKindColor("handoff");
    if (order == .below) label858Text(dib.dc, color, rect(303, 192, 451, 212));
    const roles = try resolveCardRoles(std.testing.allocator, graph.nodes.items, graph.edges.items, &.{});
    defer std.testing.allocator.free(roles);
    for (graph.nodes.items, 0..) |node, index| {
        drawLoopCardShadow(dib.dc, std.testing.allocator, node, nodeBounds(index, state), state, roles[index],
            needsAttention(node, graph.nodes.items, graph.edges.items), fixture.model.selectedIndex() == index);
    }
    for (graph.nodes.items, 0..) |node, index| {
        drawNode(dib.dc, std.testing.allocator, node, index, fixture.model.selectedIndex(),
            graph.nodes.items, graph.edges.items, roles[index], null, &.{}, state);
    }
    if (order == .above) label858Text(dib.dc, color, rect(303, 192, 451, 212));
    if (c.GdiFlush() == 0) return error.Label858FlushFailed;
}

fn label858Differences(a: ParityDib, b: ParityDib, bounds: c.RECT) !usize {
    var differences: usize = 0;
    var y = bounds.top;
    while (y < bounds.bottom) : (y += 1) {
        var x = bounds.left;
        while (x < bounds.right) : (x += 1) {
            if (try label858RgbDistance(c.GetPixel(a.dc, x, y), c.GetPixel(b.dc, x, y)) != 0)
                differences += 1;
        }
    }
    return differences;
}

test "loop card parity edge-label chrome 858 backing preserves lower-layer pixels" {
    try chrome764Native();
    var fixture = try label858Fixture();
    defer fixture.model.deinit();
    var actual = try ParityDib.init(1280, 720);
    defer actual.deinit();
    var lower = try ParityDib.init(1280, 720);
    defer lower.deinit();
    var checks = Label858Checks{};
    const graph = &(fixture.model.graph orelse return error.Label858GraphMissing);
    for (0..3) |variant| {
        var state = try label858State(&fixture, .{ .selected_edge = if (variant == 1) 0 else null });
        defer state.deinitLayout();
        graph.edges.items[0].fired = variant == 2;
        fill(lower.dc, rect(0, 0, 1280, 720), Tokens.canvas_tone);
        var x: i32 = 303;
        while (x < 451) : (x += 1)
            fill(lower.dc, rect(x, 192, x + 1, 212), if (@mod(x, 2) == 0) 0x001B2418 else 0x00251820);
        if (c.BitBlt(actual.dc, 0, 0, 1280, 720, lower.dc, 0, 0, c.SRCCOPY) == 0)
            return error.Label858CopyFailed;
        drawEdgeLabels(actual.dc, std.testing.allocator, graph.*, &state);
        var y: i32 = 192;
        while (y < 212) : (y += 1) {
            for ([_]c.RECT{ rect(303, y, 323, y + 1), rect(431, y, 451, y + 1) }) |strip| {
                x = strip.left;
                while (x < strip.right) : (x += 1) {
                    checks.expect(try label858RgbDistance(c.GetPixel(actual.dc, x, y), c.GetPixel(lower.dc, x, y)) == 0);
                }
            }
        }
        var ink: usize = 0;
        for (label858Glyphs) |point| {
            if (try label858RgbDistance(c.GetPixel(actual.dc, point.x, point.y), c.GetPixel(lower.dc, point.x, point.y)) > 20)
                ink += 1;
        }
        checks.expect(ink == 25);
        std.debug.print("label858 backing variant={d} protected=800 positive-glyphs={d}\n", .{ variant, ink });
    }
    var empty = graph.*;
    empty.edges.items = &.{};
    const before = try actual.rgbSha256(std.testing.allocator);
    drawEdgeLabels(actual.dc, std.testing.allocator, empty, &CanvasState{});
    checks.expect(std.mem.eql(u8, &before, &(try actual.rgbSha256(std.testing.allocator))));
    try checks.finish("backing", error.Label858OpaqueBacking);
}

test "loop card parity edge-label chrome 858 text is below normal and attention shadows" {
    try chrome764Native();
    var fixture = try label858Fixture();
    defer fixture.model.deinit();
    var actual = try ParityDib.init(1280, 720);
    defer actual.deinit();
    var below = try ParityDib.init(1280, 720);
    defer below.deinit();
    var above = try ParityDib.init(1280, 720);
    defer above.deinit();
    var checks = Label858Checks{};
    var state = try label858State(&fixture, .{});
    defer state.deinitLayout();
    for (0..2) |warm| {
        const graph = &(fixture.model.graph orelse return error.Label858GraphMissing);
        for ([_]usize{ 0, 3 }) |index|
            try chrome764Replace(&graph.nodes.items[index].state, if (warm == 0) "idle" else "failed");
        try chrome764Paint(actual, &fixture, .project, &state, null, &.{});
        try label858Composition(below, &fixture, &state, .below);
        try label858Composition(above, &fixture, &state, .above);
        const region = rect(303, 192, 451, 212);
        const discriminating = try label858Differences(below, above, region);
        if (discriminating == 0) return error.Label858NondiscriminatingOrder;
        const mismatches = try label858Differences(actual, below, region);
        checks.expect(mismatches == 0);
        checks.expect(try label858Differences(actual, above, region) > 0);
        std.debug.print("label858 order warm={d} pixels=2960 discriminating={d} correct-order-mismatches={d}\n",
            .{ warm, discriminating, mismatches });
    }
    try checks.finish("shadow-order", error.Label858TextAboveShadows);
}

test "loop card parity edge-label chrome 858 card face occludes overlapping label" {
    try chrome764Native();
    var fixture = try label858Fixture();
    defer fixture.model.deinit();
    var actual = try ParityDib.init(1280, 720);
    defer actual.deinit();
    var omitted = try ParityDib.init(1280, 720);
    defer omitted.deinit();
    var above = try ParityDib.init(1280, 720);
    defer above.deinit();
    var checks = Label858Checks{};
    var state = try label858State(&fixture, .{});
    defer state.deinitLayout();
    state.project_layout.?.positions[1].x -= 182;
    state.project_layout.?.positions[1].y += 106;
    for ([_]usize{ 2, 1 }) |selected| {
        if (!fixture.model.setSelectedIndex(selected)) return error.Label858SelectionFailed;
        try chrome764Paint(actual, &fixture, .project, &state, null, &.{});
        try label858Composition(omitted, &fixture, &state, .omitted);
        try label858Composition(above, &fixture, &state, .above);
        const region = rect(350, 194, 410, 208);
        const discriminating = try label858Differences(omitted, above, region);
        if (discriminating == 0) return error.Label858NondiscriminatingOcclusion;
        const mismatches = try label858Differences(actual, omitted, region);
        checks.expect(mismatches == 0);
        std.debug.print("label858 face selected={d} pixels=840 discriminating={d} mismatches={d}\n",
            .{ selected, discriminating, mismatches });
    }
    try checks.finish("face-occlusion", error.Label858TextAboveFace);
}

test "loop card parity edge-label chrome 858 placement and viewport boundaries remain unchanged" {
    try chrome764Native();
    var fixture = try label858Fixture();
    defer fixture.model.deinit();
    const graph = fixture.model.graph orelse return error.Label858GraphMissing;
    var checks = Label858Checks{};
    for ([_]i32{ 96, 120, 144, 192 }) |dpi| {
        for ([_]f32{ 0.55, 1, 1.8 }) |zoom| {
            var actual = try ParityDib.init(@divTrunc(1280 * dpi, 96), @divTrunc(720 * dpi, 96));
            defer actual.deinit();
            var expected = try ParityDib.init(@divTrunc(1280 * dpi, 96), @divTrunc(720 * dpi, 96));
            defer expected.deinit();
            try chrome764Map(actual, dpi);
            try chrome764Map(expected, dpi);
            var state = try label858State(&fixture, .{ .zoom = zoom, .pan_x = 17, .pan_y = 9 });
            defer state.deinitLayout();
            const left: i32 = @intFromFloat(252 * zoom + 17);
            const width: i32 = @intFromFloat(250 * zoom);
            const top0: i32 = @intFromFloat(84 * zoom + 9);
            const top3: i32 = @intFromFloat(224 * zoom + 9);
            const height: i32 = @intFromFloat(96 * zoom);
            const cy = @divTrunc(top0 + top3 + height, 2);
            const cx = left + @divTrunc(width, 2);
            for ([_]ParityDib{ actual, expected }) |dib| {
                fill(dib.dc, rect(0, 0, 1280, 720), Tokens.canvas_tone);
                if (c.IntersectClipRect(dib.dc, 223, 35, 1000, 620) == c.ERROR) return error.Label858ClipFailed;
            }
            drawEdgeLabels(actual.dc, std.testing.allocator, graph, &state);
            label858Text(expected.dc, edgeKindColor("handoff"), rect(cx - 74, cy - 10, cx + 74, cy + 10));
            const hash = try actual.rgbSha256(std.testing.allocator);
            checks.expect(std.mem.eql(u8, &hash, &(try expected.rgbSha256(std.testing.allocator))));
            std.debug.print("label858 placement dpi={d} zoom={d} pan=17,9 expected=({d},{d},148,20) full-rgb-clip-check=true\n",
                .{ dpi, zoom, cx - 74, cy - 10 });
        }
    }
    var actual = try ParityDib.init(1280, 720);
    defer actual.deinit();
    var expected = try ParityDib.init(1280, 720);
    defer expected.deinit();
    for ([_]i32{ 39, 40 }) |delta| {
        var state = try label858State(&fixture, .{});
        defer state.deinitLayout();
        state.project_layout.?.positions[3].y += @as(f32, @floatFromInt(delta - 140));
        fill(actual.dc, rect(0, 0, 1280, 720), Tokens.canvas_tone);
        fill(expected.dc, rect(0, 0, 1280, 720), Tokens.canvas_tone);
        drawEdgeLabels(actual.dc, std.testing.allocator, graph, &state);
        const y: i32 = if (delta == 39) 56 else 142;
        label858Text(expected.dc, edgeKindColor("handoff"), rect(303, y, 451, y + 20));
        const hash = try actual.rgbSha256(std.testing.allocator);
        checks.expect(std.mem.eql(u8, &hash, &(try expected.rgbSha256(std.testing.allocator))));
    }
    var edges: [130]GraphModel.Edge = undefined;
    @memset(&edges, graph.edges.items[0]);
    var crowded_state = try label858State(&fixture, .{});
    defer crowded_state.deinitLayout();
    for ([_]usize{ 2, 128, 129, 130 }) |count| {
        var crowded = graph;
        crowded.edges.items = edges[0..count];
        fill(actual.dc, rect(0, 0, 1280, 720), Tokens.canvas_tone);
        fill(expected.dc, rect(0, 0, 1280, 720), Tokens.canvas_tone);
        drawEdgeLabels(actual.dc, std.testing.allocator, crowded, &crowded_state);
        for (0..count) |index| {
            const y: i32 = 192 + @as(i32, @intCast(@min(index, 12))) * 24;
            label858Text(expected.dc, edgeKindColor("handoff"), rect(303, y, 451, y + 20));
        }
        if (c.GdiFlush() == 0) return error.Label858FlushFailed;
        var support_mismatches: usize = 0;
        for (0..actual.height) |y| {
            for (0..actual.width) |x| {
                const offset = y * actual.row_bytes + x * 4;
                const a = actual.pixels[offset .. offset + 3];
                const b = expected.pixels[offset .. offset + 3];
                const ground = [_]u8{ 11, 12, 10 };
                if (std.mem.eql(u8, a, &ground) != std.mem.eql(u8, b, &ground))
                    support_mismatches += 1;
            }
        }
        checks.expect(support_mismatches == 0);
        std.debug.print("label858 collision edges={d} attempts=12 record-limit=128 exact-ink-support-mismatches={d}\n",
            .{ count, support_mismatches });
    }
    const placed = [_]c.RECT{rect(303, 192, 451, 212)};
    checks.expect(!overlapsPlaced(rect(451, 192, 599, 212), &placed));
    checks.expect(overlapsPlaced(rect(450, 192, 598, 212), &placed));
    try checks.finish("placement-clip", error.Label858PlacementChanged);
}

test "loop card parity edge-label chrome 858 project-only change preserves the card contract" {
    try chrome764Native();
    var fixture = try label858Fixture();
    defer fixture.model.deinit();
    var actual = try ParityDib.init(1280, 720);
    defer actual.deinit();
    var omitted = try ParityDib.init(1280, 720);
    defer omitted.deinit();
    var checks = Label858Checks{};
    for (0..2) |warm| {
        const graph = &(fixture.model.graph orelse return error.Label858GraphMissing);
        for ([_]usize{ 0, 3 }) |index|
            try chrome764Replace(&graph.nodes.items[index].state, if (warm == 0) "idle" else "failed");
        for (0..3) |variant| {
            var state = try label858State(&fixture, .{ .selected_edge = if (variant == 1) 0 else null });
            defer state.deinitLayout();
            graph.edges.items[0].fired = variant == 2;
            try chrome764Paint(actual, &fixture, .project, &state, null, &.{});
            try label858Composition(omitted, &fixture, &state, .omitted);
            var pairs: usize = 0;
            var ink: usize = 0;
            var minimum: u32 = std.math.maxInt(u32);
            for (label858Glyphs) |point| {
                const glyph = c.GetPixel(actual.dc, point.x, point.y);
                const no_label = c.GetPixel(omitted.dc, point.x, point.y);
                if (try label858RgbDistance(glyph, no_label) >= 100) ink += 1;
                for ([_]i32{ 302, 451 }) |hx| {
                    const distance = try label858RgbDistance(glyph, c.GetPixel(actual.dc, hx, point.y));
                    minimum = @min(minimum, distance);
                    checks.expect(distance >= 100);
                    pairs += 1;
                }
            }
            checks.expect(ink > 0);
            checks.expect(pairs == 50);
            std.debug.print("label858 fixed-legibility warm={d} variant={d} frozen-glyphs=25 positive-ink={d} pairs={d} minimum-l1={d} fixed-margin=100\n",
                .{ warm, variant, ink, pairs, minimum });
        }
    }
    var state = try label858State(&fixture, .{});
    defer state.deinitLayout();
    const graph = fixture.model.graph orelse return error.Label858GraphMissing;
    checks.expect(hitTest(graph.nodes.items, 377, 132, &state, chrome764GraphBounds()) == 0);
    checks.expect(contentSize(&fixture.model, .project, &state).width > 0);
    const label = try edgeLabel(std.testing.allocator, graph.edges.items[0]);
    defer std.testing.allocator.free(label);
    checks.expect(std.mem.eql(u8, label, "handoff"));
    var outside = std.crypto.hash.sha2.Sha256.init(.{});
    if (c.GdiFlush() == 0) return error.Label858FlushFailed;
    for (0..actual.height) |y| {
        for (0..actual.width) |x| {
            if (x >= 303 and x < 451 and y >= 192 and y < 212) continue;
            const offset = y * actual.row_bytes + x * 4;
            outside.update(actual.pixels[offset .. offset + 3]);
        }
    }
    const outside_digest = outside.finalResult();
    std.debug.print("label858 project-outside-label rgb-sha256={s} pixels=918640\n",
        .{std.fmt.bytesToHex(outside_digest, .lower)});
    var overview_fixture = try paint764FixtureModel(std.testing.allocator, .overview);
    defer overview_fixture.model.deinit();
    try paint764TestSurface(actual, &overview_fixture, std.testing.allocator, .overview);
    const overview_digest = try actual.rgbSha256(std.testing.allocator);
    std.debug.print("label858 overview-preservation rgb-sha256={s} byte-count={d} unix-seconds={d}\n",
        .{ std.fmt.bytesToHex(overview_digest, .lower), actual.width * actual.height * 3, std.time.timestamp() });
    try checks.finish("preservation-legibility", error.Label858LegibilityOrCardContractChanged);
}

test "loop card parity paint 764 accents match Mac COLORREFs on both surfaces" {
    const allocator = std.testing.allocator;
    var fixture = try paint764FixtureModel(allocator, .overview);
    defer fixture.model.deinit();
    try initPaint764TestRenderer();

    var project = try ParityDib.init(1280, 720);
    defer project.deinit();
    var overview = try ParityDib.init(1280, 720);
    defer overview.deinit();
    try paint764TestSurface(project, &fixture, allocator, .project);
    try paint764TestSurface(overview, &fixture, allocator, .overview);

    var state = try modelTestState(&fixture.model, .{ .zoom = paint764_zoom }, chrome764GraphBounds());
    defer state.deinitLayout();
    const viewport_bounds = renderBounds(1280, 720, .{
        .rail_visible = true,
        .panel_visible = false,
        .activity_enabled = false,
    });
    const graph_bounds = rect(
        viewport_bounds.left,
        viewport_bounds.top,
        viewport_bounds.right,
        viewport_bounds.bottom,
    );
    const graph = fixture.model.graphs.items[0];
    const roles = try resolveCardRoles(allocator, graph.nodes.items, graph.edges.items, &.{});
    defer allocator.free(roles);
    for (graph.nodes.items, 0..) |node, index| {
        const expected = paint764ExpectedAccent(node.loop_type) orelse
            return error.Paint764UnexpectedLoopType;
        const expected_stripe = if (roles[index] == .unwired)
            blendCardColor(expected, if (paint764TestRendererReady) chrome764Face(needsAttention(node, graph.nodes.items, graph.edges.items), 8, 96) else if (needsAttention(node, graph.nodes.items, graph.edges.items)) Tokens.loop_card_attention_bottom else Tokens.loop_card_bottom, 35)
        else
            expected;
        const bounds = nodeBounds(index, &state);
        const stripe = rect(
            bounds.left,
            bounds.top,
            bounds.left + scaledValue(Tokens.loop_card_stripe, state.zoom),
            bounds.bottom,
        );
        const actual = c.GetPixel(project.dc, stripe.left + 1, stripe.top + 8);
        if (actual != expected_stripe) {
            std.debug.print(
                "paint764 accent RED surface=project node={s} type={s} expected=0x{x} actual=0x{x}\n",
                .{ node.id, node.loop_type, expected_stripe, actual },
            );
            return error.Paint764CardStripeAccentMismatch;
        }

        const overview_bounds = overviewCardBounds(&fixture.model, 0, index, graph_bounds, &state);
        const overview_stripe = rect(
            overview_bounds.left,
            overview_bounds.top,
            overview_bounds.left + scaledValue(Tokens.loop_card_stripe, state.zoom),
            overview_bounds.bottom,
        );
        const overview_actual = c.GetPixel(overview.dc, overview_stripe.left + 1, overview_stripe.top + 8);
        if (overview_actual != expected_stripe) {
            std.debug.print(
                "paint764 accent RED surface=overview node={s} type={s} expected=0x{x} actual=0x{x}\n",
                .{ node.id, node.loop_type, expected_stripe, overview_actual },
            );
            return error.Paint764OverviewStripeAccentMismatch;
        }

        const presentation = cardState(node);
        const pill_width = blk: {
            const old = try selectCardFont(project.dc, 10 * state.zoom, .card_state);
            defer _ = c.SelectObject(project.dc, old);
            break :blk try measuredText(project.dc, allocator, presentation.word) + scaledValue(22, state.zoom);
        };
        const project_rows = cardTextLayout(bounds, state.zoom, pill_width);
        const overview_rows = cardTextLayout(overview_bounds, state.zoom, pill_width);
        const project_square_top = @divTrunc(
            project_rows.meta.top + project_rows.meta.bottom - scaledValue(6, state.zoom),
            2,
        );
        const overview_square_top = @divTrunc(
            overview_rows.meta.top + overview_rows.meta.bottom - scaledValue(6, state.zoom),
            2,
        );
        try std.testing.expectEqual(
            expected,
            c.GetPixel(project.dc, project_rows.meta.left + 3, project_square_top + 3),
        );
        try std.testing.expectEqual(
            expected,
            c.GetPixel(overview.dc, overview_rows.meta.left + 3, overview_square_top + 3),
        );
    }
}

test "loop card parity paint 764 no-chip metadata paints its final glyph inside the measured width" {
    const allocator = std.testing.allocator;
    try initPaint764TestRenderer();

    var actual = try ParityDib.init(640, 120);
    defer actual.deinit();
    var expected = try ParityDib.init(640, 120);
    defer expected.deinit();
    var clipped = try ParityDib.init(640, 120);
    defer clipped.deinit();
    fill(actual.dc, rect(0, 0, 640, 120), 0);
    fill(expected.dc, rect(0, 0, 640, 120), 0);
    fill(clipped.dc, rect(0, 0, 640, 120), 0);

    var node = parityTestNode();
    node.backend = @constCast("backendWWWWWWWW");
    node.created_at = null;
    const bounds = rect(20, 10, 600, 100);
    var layout = cardTextLayout(bounds, 1, 0);
    const initial = try cardMetaPresentation(actual.dc, allocator, node, layout, 1, .interior);
    defer allocator.free(initial.text);
    const old_font = try selectCardFont(actual.dc, 10.5, .card_mono);
    defer _ = c.SelectObject(actual.dc, old_font);
    const measured_width = try measuredText(actual.dc, allocator, initial.text);
    layout.meta.right = layout.meta.left + scaledValue(11, 1) + measured_width;

    const metadata = try cardMetaPresentation(expected.dc, allocator, node, layout, 1, .interior);
    defer allocator.free(metadata.text);
    try std.testing.expectEqualStrings(initial.text, metadata.text);
    try std.testing.expect(std.mem.endsWith(u8, metadata.text, "WWWWWWWW"));
    const expected_text_bounds = rect(
        layout.meta.left + scaledValue(11, 1),
        layout.meta.top,
        layout.meta.right,
        layout.meta.bottom,
    );
    try std.testing.expectEqual(measured_width, expected_text_bounds.right - expected_text_bounds.left);

    const text_color = blendCardColor(0x00FFFFFF, Tokens.loop_card_bottom, 52);
    try drawCardText(
        expected.dc,
        allocator,
        metadata.text,
        expected_text_bounds,
        10.5,
        .card_mono,
        text_color,
        false,
    );
    const clipped_text_bounds = rect(
        expected_text_bounds.left,
        expected_text_bounds.top,
        expected_text_bounds.right - scaledValue(5, 1),
        expected_text_bounds.bottom,
    );
    try drawCardText(
        clipped.dc,
        allocator,
        metadata.text,
        clipped_text_bounds,
        10.5,
        .card_mono,
        text_color,
        false,
    );
    try std.testing.expect(!try drawCardMetaRow(actual.dc, allocator, node, layout, 1, .interior));

    var clipped_final_ink = false;
    var y = expected_text_bounds.top;
    while (y < expected_text_bounds.bottom) : (y += 1) {
        var x = expected_text_bounds.left;
        while (x < expected_text_bounds.right) : (x += 1) {
            const full_pixel = c.GetPixel(expected.dc, x, y);
            const shortened_pixel = c.GetPixel(clipped.dc, x, y);
            if (x >= expected_text_bounds.right - scaledValue(5, 1) and
                full_pixel != 0 and shortened_pixel == 0)
            {
                clipped_final_ink = true;
            }
            if (c.GetPixel(actual.dc, x, y) != full_pixel) return error.Paint764NoChipMetadataFinalGlyphClipped;
        }
    }
    if (!clipped_final_ink) return error.Paint764FinalGlyphFixtureDidNotReachMeasuredEdge;
}

test "loop card parity paint 764 overview preserves entry role content" {
    const allocator = std.testing.allocator;
    var fixture = try paint764FixtureModel(allocator, .overview);
    defer fixture.model.deinit();
    try initPaint764TestRenderer();

    var project = try ParityDib.init(1280, 720);
    defer project.deinit();
    var overview = try ParityDib.init(1280, 720);
    defer overview.deinit();
    try paint764TestSurface(project, &fixture, allocator, .project);
    try paint764TestSurface(overview, &fixture, allocator, .overview);

    const graph = fixture.model.graphs.items[0];
    const node = graph.nodes.items[0];
    const roles = try resolveCardRoles(allocator, graph.nodes.items, graph.edges.items, &.{});
    defer allocator.free(roles);
    try std.testing.expectEqual(NodeRole.entry, roles[0]);
    var state = try modelTestState(&fixture.model, .{ .zoom = paint764_zoom }, chrome764GraphBounds());
    defer state.deinitLayout();
    const viewport_bounds = renderBounds(1280, 720, .{
        .rail_visible = true,
        .panel_visible = false,
        .activity_enabled = false,
    });
    const graph_bounds = rect(
        viewport_bounds.left,
        viewport_bounds.top,
        viewport_bounds.right,
        viewport_bounds.bottom,
    );
    const project_bounds = nodeBounds(0, &state);
    const overview_bounds = overviewCardBounds(&fixture.model, 0, 0, graph_bounds, &state);
    const presentation = cardState(node);
    const pill_width = blk: {
        const old = try selectCardFont(project.dc, 10 * state.zoom, .card_state);
        defer _ = c.SelectObject(project.dc, old);
        break :blk try measuredText(project.dc, allocator, presentation.word) + scaledValue(22, state.zoom);
    };
    const project_layout = cardTextLayout(project_bounds, state.zoom, pill_width);
    const overview_layout = cardTextLayout(overview_bounds, state.zoom, pill_width);
    const project_detail = project_layout.detail;
    const overview_detail = overview_layout.detail;
    const project_role = try cardMetaPresentation(project.dc, allocator, node, project_layout, state.zoom, .entry);
    defer allocator.free(project_role.text);
    const overview_role = try cardMetaPresentation(overview.dc, allocator, node, overview_layout, state.zoom, .entry);
    defer allocator.free(overview_role.text);
    const project_chip_width = try cardRoleChipWidth(project.dc, allocator, .entry, state.zoom);
    const overview_chip_width = try cardRoleChipWidth(overview.dc, allocator, .entry, state.zoom);
    const chip_height = scaledValue(14, state.zoom);
    const project_chip_row = if (project_role.chip_in_detail) project_detail else project_layout.meta;
    const overview_chip_row = if (overview_role.chip_in_detail) overview_detail else overview_layout.meta;
    const project_chip_top = @divTrunc(project_chip_row.top + project_chip_row.bottom - chip_height, 2);
    const overview_chip_top = @divTrunc(overview_chip_row.top + overview_chip_row.bottom - chip_height, 2);
    const entry_fill = cardRoleChip(.entry).?.fill;
    const project_chip_left = if (project_role.chip_in_detail) project_chip_row.left else project_chip_row.right - project_chip_width;
    const overview_chip_left = if (overview_role.chip_in_detail) overview_chip_row.left else overview_chip_row.right - overview_chip_width;
    try std.testing.expect(project.count(rect(project_chip_left, project_chip_top, project_chip_left + project_chip_width, project_chip_top + chip_height), entry_fill) > 20);
    try std.testing.expect(overview.count(rect(overview_chip_left, overview_chip_top, overview_chip_left + overview_chip_width, overview_chip_top + chip_height), entry_fill) > 20);
    const detail_width = project_detail.right - project_detail.left;
    const detail_height = project_detail.bottom - project_detail.top;
    if (detail_width != overview_detail.right - overview_detail.left or
        detail_height != overview_detail.bottom - overview_detail.top)
    {
        return error.Paint764RoleDetailGeometryMismatch;
    }

    var y: i32 = 0;
    while (y < detail_height) : (y += 1) {
        var x: i32 = 0;
        while (x < detail_width) : (x += 1) {
            const project_pixel = c.GetPixel(project.dc, project_detail.left + x, project_detail.top + y);
            const overview_pixel = c.GetPixel(overview.dc, overview_detail.left + x, overview_detail.top + y);
            if (project_pixel != overview_pixel) {
                std.debug.print(
                    "paint764 role RED node={s} role=entry detail-offset=({d},{d}) project=0x{x} overview=0x{x}\n",
                    .{ node.id, x, y, project_pixel, overview_pixel },
                );
                return error.Paint764OverviewEntryRoleContentMismatch;
            }
        }
    }
}

test "loop card parity paint 764 overview paints primary action within owning card" {
    const allocator = std.testing.allocator;
    var fixture = try paint764FixtureModel(allocator, .overview);
    defer fixture.model.deinit();
    try initPaint764TestRenderer();

    var overview = try ParityDib.init(1280, 720);
    defer overview.deinit();
    try paint764TestSurface(overview, &fixture, allocator, .overview);

    const graph = fixture.model.graphs.items[0];
    const node_index = paint764NodeIndex(graph.nodes.items, "fixture-turn-needs-you") orelse
        return error.Paint764AttentionNodeMissing;
    const node = graph.nodes.items[node_index];
    try std.testing.expect(needsAttention(node, graph.nodes.items, graph.edges.items));
    var state = try modelTestState(&fixture.model, .{ .zoom = paint764_zoom }, chrome764GraphBounds());
    defer state.deinitLayout();
    const viewport_bounds = renderBounds(1280, 720, .{
        .rail_visible = true,
        .panel_visible = false,
        .activity_enabled = false,
    });
    const graph_bounds = rect(
        viewport_bounds.left,
        viewport_bounds.top,
        viewport_bounds.right,
        viewport_bounds.bottom,
    );
    const card = overviewCardBounds(&fixture.model, 0, node_index, graph_bounds, &state);
    const action = attentionActionBounds(card, &state);
    const action_pixels = overview.count(action, 0x000A9FFF);
    if (action_pixels == 0) {
        std.debug.print(
            "paint764 overview action RED node={s} expected={s} pixels-inside-action={d}\n",
            .{ node.id, attentionActionLabel(node), action_pixels },
        );
        return error.Paint764OverviewPrimaryActionMissing;
    }
    var label_pixels: usize = 0;
    var y = action.top;
    while (y < action.bottom) : (y += 1) {
        var x = action.left;
        while (x < action.right) : (x += 1) {
            if (c.GetPixel(overview.dc, x, y) != 0x000A9FFF) label_pixels += 1;
        }
    }
    if (label_pixels == 0) return error.Paint764OverviewPrimaryActionLabelMissing;
    const hit = hitTestOverview(
        &fixture.model,
        action.left + @divTrunc(action.right - action.left, 2),
        action.top + @divTrunc(action.bottom - action.top, 2),
        &state,
        graph_bounds,
    ) orelse return error.Paint764OverviewActionHitMissing;
    try std.testing.expectEqual(@as(usize, 0), hit.graph_index);
    try std.testing.expectEqual(node_index, hit.node_index);
}

test "loop card parity both production renderers paint named pill and mono meta regions" {
    const allocator = std.testing.allocator;
    const dib = try ParityDib.init(2200, 500);
    defer dib.deinit();
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"parity","project":{"path":"A","name":"Alpha"},"nodes":[{"id":"parity-card","title":"A long title must yield to NEEDS YOU","loopType":"goalBased","state":"succeeded","presence":"awaitingInput","activity":"reading tools","backend":"copilotCLI","createdAt":0}],"edges":[]}}}
    );
    const node = model.graphs.items[0].nodes.items[0];
    const viewport = rect(220, 34, 2200, 500);
    var state = try modelTestState(&model, .{ .pan_x = 1200 }, viewport);
    defer state.deinitLayout();
    fill(dib.dc, rect(0, 0, 2200, 500), 0);
    drawNode(dib.dc, allocator, node, 0, null, &.{node}, &.{}, .unwired, null, &.{}, &state);
    const project = nodeBounds(0, &state);
    const presentation = cardState(node);
    const old = try selectCardFont(dib.dc, 10, .card_state);
    const pill_width = try measuredText(dib.dc, allocator, presentation.word) + 22;
    _ = c.SelectObject(dib.dc, old);
    const project_rows = cardTextLayout(project, 1, pill_width);
    try std.testing.expect(c.GdiFlush() != 0);
    try std.testing.expect(dib.count(project_rows.pill, presentation.fill) > 20);
    try std.testing.expect(dib.count(project_rows.pill, presentation.tint) > 0);
    try std.testing.expect(dib.count(project_rows.title, 0x00F4F4F4) > 0);
    try std.testing.expect(dib.count(project_rows.live, 0x009F9C9C) > 0);
    try std.testing.expect(dib.count(project_rows.meta, loopTypeColor(node.loop_type)) == 36);
    try std.testing.expect(dib.count(project_rows.meta, 0x00979595) > 0);
    const project_pill_pixels = dib.count(project_rows.pill, presentation.fill);
    fill(dib.dc, rect(0, 0, 2200, 500), 0);
    try drawOverview(dib.dc, allocator, &model, viewport, &state, &.{});
    const overview = overviewCardBounds(&model, 0, 0, viewport, &state);
    const overview_rows = cardTextLayout(overview, 1, pill_width);
    try std.testing.expect(c.GdiFlush() != 0);
    try std.testing.expectEqual(project_pill_pixels, dib.count(overview_rows.pill, presentation.fill));
    try std.testing.expect(dib.count(overview_rows.meta, loopTypeColor(node.loop_type)) == 36);
    try std.testing.expect(dib.count(overview_rows.meta, 0x00979595) > 0);
    try std.testing.expect(dib.count(overview_rows.detail, 0x000A9FFF) == 0);
}

test "loop card parity production long text and hollow pills paint across zoom and mapped DPI" {
    const allocator = std.testing.allocator;
    const dib = try ParityDib.init(2400, 1000);
    defer dib.deinit();
    var node = parityTestNode();
    const activity = try std.mem.concat(allocator, u8, &.{ "工具 🧪 " ** 50, "complete activity tail" });
    defer allocator.free(activity);
    const branch = try std.mem.concat(allocator, u8, &.{ "feature/", "branch/工具/" ** 30, "🧪/tail" });
    defer allocator.free(branch);
    node.activity = activity;
    node.worktree_branch = branch;
    node.created_at = @intCast(@max(0, std.time.timestamp() - 93600));
    node.state = @constCast("stopped");
    node.presence = @constCast("");
    for ([_]u32{ 96, 120, 144, 192 }) |dpi| {
        const saved = c.SaveDC(dib.dc);
        defer _ = c.RestoreDC(dib.dc, saved);
        _ = c.SetMapMode(dib.dc, c.MM_ANISOTROPIC);
        _ = c.SetWindowExtEx(dib.dc, 96, 96, null);
        _ = c.SetViewportExtEx(dib.dc, @intCast(dpi), @intCast(dpi), null);
        for ([_]f32{ 0.55, 0.75, 1, 1.25, 1.8 }) |zoom| {
            var state = try cardTestState(.{ .zoom = zoom, .pan_x = 25 - 130 * zoom, .pan_y = 19 - 50 * zoom });
            defer state.deinitLayout();
            const bounds = nodeBounds(0, &state);
            fill(dib.dc, rect(0, 0, 1000, 450), 0);
            roundedCard(dib.dc, bounds, Tokens.loop_card_bottom, false);
            try drawCardBody(dib.dc, allocator, node, bounds, zoom, .interior, false, null, null);
            const old = try selectCardFont(dib.dc, 10 * zoom, .card_state);
            const pill_width = try measuredText(dib.dc, allocator, "STOPPED") + scaledValue(22, zoom);
            _ = c.SelectObject(dib.dc, old);
            const rows = cardTextLayout(bounds, zoom, pill_width);
            try std.testing.expect(c.GdiFlush() != 0);
            try std.testing.expect(dib.count(rows.pill, cardState(node).fill) > 0);
            try std.testing.expect(dib.count(rows.meta, loopTypeColor(node.loop_type)) > 0);
            const center_x = rows.pill.left + scaledValue(5, zoom) + @divTrunc(scaledValue(6, zoom), 2);
            const center_y = @divTrunc(rows.pill.top + rows.pill.bottom, 2);
            try std.testing.expectEqual(cardState(node).fill, c.GetPixel(dib.dc, center_x, center_y));
        }
    }
}

test "loop card parity compact composite metadata never blanks title or state" {
    const allocator = std.testing.allocator;
    const dib = try ParityDib.init(600, 240);
    defer dib.deinit();
    var node = parityTestNode();
    node.loop_type = @constCast("composite");
    node.worktree_branch = @constCast("main");
    node.created_at = @intCast(@max(0, std.time.timestamp() - 3900));
    const bounds = rect(20, 20, 270, 116);
    fill(dib.dc, rect(0, 0, 600, 240), 0);
    try drawCardBody(dib.dc, allocator, node, bounds, 1, .interior, false, null, null);
    try std.testing.expect(c.GdiFlush() != 0);
    try std.testing.expect(dib.count(rect(31, 28, 170, 46), 0x00F4F4F4) > 0);
    try std.testing.expect(dib.count(rect(170, 28, 259, 46), cardState(node).fill) > 0);
    const old = try selectCardFont(dib.dc, 10.5, .card_mono);
    defer _ = c.SelectObject(dib.dc, old);
    const metadata = try cardMetaForWidth(dib.dc, allocator, node, node.created_at.? + 3900, 218);
    defer allocator.free(metadata);
    try std.testing.expectEqualStrings("Composite · … · Copilot CLI · 1h 5m", metadata);
    const minimum = try measuredText(dib.dc, allocator, metadata);
    const exact = try cardMetaForWidth(dib.dc, allocator, node, node.created_at.? + 3900, minimum);
    defer allocator.free(exact);
    try std.testing.expectEqualStrings(metadata, exact);
    const below = try cardMetaForWidth(dib.dc, allocator, node, node.created_at.? + 3900, minimum - 1);
    defer allocator.free(below);
    try std.testing.expectEqualStrings("Composite · Copilot CLI · 1h 5m", below);
    const fixed_width = try measuredText(dib.dc, allocator, below);
    const exact_fixed = try cardMetaForWidth(dib.dc, allocator, node, node.created_at.? + 3900, fixed_width);
    defer allocator.free(exact_fixed);
    try std.testing.expectEqualStrings(below, exact_fixed);
    try std.testing.expectError(error.CardMetadataTooWide, cardMetaForWidth(dib.dc, allocator, node, node.created_at.? + 3900, fixed_width - 1));
    node.backend = @constCast("a backend identifier too wide to fit without lying");
    fill(dib.dc, rect(0, 0, 600, 240), 0);
    try drawCardBody(dib.dc, allocator, node, bounds, 1, .interior, false, null, null);
    try std.testing.expect(c.GdiFlush() != 0);
    try std.testing.expect(dib.count(rect(31, 28, 170, 46), 0x00F4F4F4) > 0);
    try std.testing.expect(dib.count(rect(31, 52, 259, 65), 0x009F9C9C) > 0);
    try std.testing.expect(dib.count(rect(31, 95, 259, 108), Tokens.dialog_error_text) > 0);
}

test "loop card parity middle elision cuts only between complete surrogate pairs" {
    const allocator = std.testing.allocator;
    const dc = c.CreateCompatibleDC(null) orelse return error.TestDcCreationFailed;
    defer _ = c.DeleteDC(dc);
    const old = try selectCardFont(dc, 10.5, .card_mono);
    defer _ = c.SelectObject(dc, old);
    const source = try std.unicode.utf8ToUtf16LeAlloc(allocator, "🧪abcdefghijkl🧪");
    defer allocator.free(source);
    const expected = try std.unicode.utf8ToUtf16LeAlloc(allocator, "🧪…🧪");
    defer allocator.free(expected);
    const result = try middleElide(dc, allocator, source, try measuredWide(dc, expected));
    defer allocator.free(result);
    try std.testing.expectEqualSlices(u16, expected, result);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(allocator, result);
    defer allocator.free(utf8);
    try std.testing.expectEqualStrings("🧪…🧪", utf8);
}

test "loop card parity existing action fills use hit bounds and never paint over meta" {
    const allocator = std.testing.allocator;
    const dib = try ParityDib.init(1200, 500);
    defer dib.deinit();
    var nodes = [_]GraphModel.Node{ parityTestNode(), parityTestNode() };
    nodes[0].presence = @constCast("awaitingInput");
    nodes[1].id = @constCast("resolved");
    nodes[1].state = @constCast("succeeded");
    nodes[1].presence = @constCast("idle");
    nodes[1].worktree_path = @constCast("fixture-safe");
    var inspection = WorktreeStatus.Inspection{
        .entries = std.array_list.Managed(WorktreeStatus.Entry).init(allocator),
        .default_branch = @constCast("main"),
        .project_path = @constCast("fixture"),
    };
    defer inspection.entries.deinit();
    try inspection.entries.append(.{ .path = @constCast("fixture-safe"), .branch = @constCast("main"), .pushed = true, .landed = true });
    for ([_]f32{ 0.55, 0.75, 1, 1.25, 1.8 }) |zoom| {
        var state = try cardTestState(.{ .zoom = zoom, .pan_x = 252 - 382 * zoom, .pan_y = 84 - 134 * zoom });
        defer state.deinitLayout();
        fill(dib.dc, rect(0, 0, 1200, 500), 0);
        for (nodes, 0..) |node, index| drawNode(dib.dc, allocator, node, index, null, &nodes, &.{}, .unwired, &inspection, &.{}, &state);
        const attention = attentionActionBounds(nodeBounds(0, &state), &state);
        const offer = reclaimOfferBounds(nodeBounds(1, &state));
        try std.testing.expect(c.GdiFlush() != 0);
        try std.testing.expect(dib.count(attention, 0x000A9FFF) > 0);
        try std.testing.expect(dib.count(offer.reclaim, 0x003A3535) > 0);
        try std.testing.expectEqual(@as(?usize, 0), hitTestAttentionAction(&nodes, &.{}, attention.left + 1, attention.top + 1, &state));
        try std.testing.expectEqual(ReclaimAction.reclaim, hitTestReclaimOffer(&nodes, &inspection, &.{}, offer.reclaim.left + 1, offer.reclaim.top + 1, &state).?.action);
        for (0..2) |index| {
            const meta = cardTextLayout(nodeBounds(index, &state), zoom, scaledValue(80, zoom)).meta;
            try std.testing.expectEqual(@as(usize, 0), dib.count(meta, 0x000A9FFF));
            try std.testing.expectEqual(@as(usize, 0), dib.count(meta, 0x003A3535));
        }
    }
}

test "minimum zoom keeps compact rows separated inside a 96 point card" {
    var state = try cardTestState(.{ .zoom = 0.55 });
    defer state.deinitLayout();
    const bounds = nodeBounds(0, &state);
    const layout = cardTextLayout(bounds, 0.55, 48);
    try std.testing.expect(layout.title.bottom <= layout.live.top);
    try std.testing.expect(layout.live.bottom <= layout.detail.top);
    try std.testing.expect(layout.detail.bottom <= layout.meta.top);
    try std.testing.expect(layout.meta.bottom < bounds.bottom);
}

test "bounded text rectangles stop at the owning container" {
    const wide = rect(1496, 34, 1780, 380);
    const wide_text = textRect(wide.left + 18, wide.top + 16, 11, wide.right - 18) orelse
        return error.TestExpectedRect;
    try std.testing.expectEqual(wide.left + 18, wide_text.left);
    try std.testing.expectEqual(wide.right - 18, wide_text.right);
    try std.testing.expect(wide_text.right > wide_text.left);

    const narrow = rect(1496, 34, 1600, 380);
    const narrow_text = textRect(narrow.left + 18, narrow.top + 16, 11, narrow.right - 18) orelse
        return error.TestExpectedRect;
    try std.testing.expectEqual(narrow.right - 18, narrow_text.right);
    try std.testing.expect(textRect(narrow.left + 18, narrow.top + 16, 11, narrow.left + 30) == null);
}

test "canvas text raster stays within its owner beyond x1200" {
    const width = 1920;
    const height = 80;
    const hdc = c.CreateCompatibleDC(null) orelse return error.TestDcCreationFailed;
    defer _ = c.DeleteDC(hdc);
    var info = std.mem.zeroes(c.BITMAPINFO);
    info.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    info.bmiHeader.biWidth = width;
    info.bmiHeader.biHeight = -height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = c.BI_RGB;
    var bits: ?*anyopaque = null;
    const bitmap = c.CreateDIBSection(hdc, &info, c.DIB_RGB_COLORS, &bits, null, 0) orelse
        return error.TestBitmapCreationFailed;
    defer _ = c.DeleteObject(bitmap);
    const old_bitmap = c.SelectObject(hdc, bitmap);
    defer _ = c.SelectObject(hdc, old_bitmap);
    const pixels = @as([*]u32, @ptrCast(@alignCast(bits.?)))[0 .. width * height];
    @memset(pixels, 0);
    // Run the same raster contract against main's seven-argument helper and its replacement.
    if (comptime @typeInfo(@TypeOf(drawText)).@"fn".params.len == 7) {
        drawText(hdc, std.testing.allocator, "Readable loop heading", 100, 8, 14, 0x00FFFFFF);
        drawText(hdc, std.testing.allocator, "Readable loop heading", 1496, 8, 14, 0x00FFFFFF);
        drawText(hdc, std.testing.allocator, "Readable loop heading", 100, 44, 14, 0x00FFFFFF);
    } else {
        drawText(hdc, std.testing.allocator, "Readable loop heading", 100, 8, 14, 0x00FFFFFF, 354);
        drawText(hdc, std.testing.allocator, "Readable loop heading", 1496, 8, 14, 0x00FFFFFF, 1750);
        drawText(hdc, std.testing.allocator, "Readable loop heading", 100, 44, 14, 0x00FFFFFF, 160);
    }
    try std.testing.expect(c.GdiFlush() != 0);
    var reference_ink: usize = 0;
    var wide_ink: usize = 0;
    for (0..36) |y| {
        for (0..200) |x| {
            if (pixels[y * width + 100 + x] & 0x00FFFFFF != 0) reference_ink += 1;
            if (pixels[y * width + 1496 + x] & 0x00FFFFFF != 0) wide_ink += 1;
        }
    }
    try std.testing.expect(reference_ink > 0);
    std.debug.print("CANVAS_TEXT_RASTER referenceInk={d} wideInk={d}\n", .{ reference_ink, wide_ink });
    try std.testing.expectEqual(reference_ink, wide_ink);
    for (40..height) |y| {
        for (160..354) |x| try std.testing.expectEqual(@as(u32, 0), pixels[y * width + x] & 0x00FFFFFF);
    }
}

test "loop detail rows keep type, title, condition, and status apart" {
    const client_right = 1780;
    const left = client_right - Tokens.loop_detail_width;
    const layout = loopDetailRowLayout(left, 244, client_right, "onSuccess");
    const title = layout.title orelse return error.TestExpectedRect;
    try std.testing.expect(layout.row.left >= left + 12);
    try std.testing.expectEqual(client_right - 12, layout.row.right);
    try std.testing.expect(layout.type_bar.right <= title.left);
    const condition = layout.condition orelse return error.TestExpectedRect;
    try std.testing.expect(title.bottom <= condition.top);
    try std.testing.expect(condition.right <= layout.status_dot.left);
    try std.testing.expect(layout.status_dot.right <= layout.row.right);
}

test "loop detail minimap blocks do not overlap" {
    const layout = loopDetailMiniMapLayout(1496, 34, 1780);
    try std.testing.expect(layout.frame.right <= 1780 - 12);
    if (layout.incoming) |incoming| {
        try std.testing.expect(incoming.bottom < layout.center.top);
    }
    if (layout.outgoing) |outgoing| {
        try std.testing.expect(layout.center.bottom < outgoing.top);
    }
}

test "loop detail handoff titles have full width with conditions below at 960 pixels" {
    for ([_]i32{ 960, 1280, 2560 }) |width| {
        const layout = loopDetailRowLayout(width - Tokens.loop_detail_width, 244, width, "always");
        const title = layout.title orelse return error.TestExpectedRect;
        const condition = layout.condition orelse return error.TestExpectedRect;
        try std.testing.expect(title.right - title.left >= 180);
        try std.testing.expectEqual(title.left, condition.left);
        try std.testing.expect(title.bottom <= condition.top);
        try std.testing.expect(condition.bottom <= layout.row.bottom);
        try std.testing.expect(title.right < layout.status_dot.left);
    }
}

test "loop detail minimap stacks incoming self and outgoing like macOS" {
    const layout = loopDetailMiniMapLayout(1496, 34, 1768);
    const incoming = layout.incoming orelse return error.TestExpectedRect;
    const outgoing = layout.outgoing orelse return error.TestExpectedRect;
    try std.testing.expectEqual(@as(i32, 118), layout.frame.bottom - layout.frame.top);
    try std.testing.expect(incoming.bottom < layout.center.top);
    try std.testing.expect(layout.center.bottom < outgoing.top);
}

test "loop detail conditions use display names and preserve fired information" {
    var buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings("Always", handoffConditionLabel(&buffer, "always", false));
    try std.testing.expectEqualStrings("On success", handoffConditionLabel(&buffer, "onSuccess", false));
    try std.testing.expectEqualStrings("on failure · fired", handoffConditionLabel(&buffer, "onFailure", true));
}

test "loop detail footer uses locale time without a backend placeholder" {
    var buffer: [160]u8 = undefined;
    for ([_][2]u16{ .{ 0, 5 }, .{ 12, 30 }, .{ 15, 47 } }) |clock| {
        var time = std.mem.zeroes(c.SYSTEMTIME);
        time.wHour = clock[0];
        time.wMinute = clock[1];
        var wide: [80]u16 = undefined;
        const length = c.GetTimeFormatEx(null, c.TIME_NOSECONDS, &time, null, &wide, wide.len);
        try std.testing.expect(length > 1);
        var expected: [160]u8 = undefined;
        const bytes = try std.unicode.utf16LeToUtf8(&expected, wide[0..@intCast(length - 1)]);
        try std.testing.expectEqualStrings(expected[0..bytes], formatClockTime(&buffer, clock[0], clock[1]));
    }
    const node = GraphModel.Node{
        .id = @constCast("loop"),
        .title = @constCast("Loop"),
        .loop_type = @constCast("sketch"),
        .state = @constCast("idle"),
        .activity = @constCast(""),
        .presence = @constCast("idle"),
        .backend = @constCast("copilotCLI"),
    };
    try std.testing.expectEqualStrings("", loopDetailFooter(&buffer, node));
}

test "loop detail handoff rows stay above lower sections at minimum height" {
    var node = GraphModel.Node{
        .id = @constCast("loop"),
        .title = @constCast("Loop"),
        .loop_type = @constCast("sketch"),
        .state = @constCast("idle"),
        .activity = @constCast(""),
        .presence = @constCast("idle"),
        .worktree_branch = @constCast("feature/parity"),
    };
    for ([_]u8{ 0, 2 }) |samples| {
        node.metric_sample_count = samples;
        var visible: usize = 0;
        for (0..12) |index| {
            const row = loopDetailRowLayout(960 - Tokens.loop_detail_width, 230 + @as(i32, @intCast(index)) * 40, 960, "always").row;
            if (!loopDetailRowFits(row, node, 960, 517)) break;
            visible += 1;
            try std.testing.expect(row.bottom < loopDetailFooterBounds(960, 517).top - 18);
            if (samples >= 2) try std.testing.expect(row.bottom < loopDetailSparklineBounds(960, 517).top - 24);
        }
        try std.testing.expectEqual(if (samples >= 2) @as(usize, 3) else 5, visible);
    }
}

test "loop detail status rings distinguish stopped blocked and waiting" {
    for ([_][]const u8{ "stopped", "blocked", "waiting" }) |state| try std.testing.expect(panelStateHollow(state));
    for ([_][]const u8{ "idle", "running", "awaitingInput", "succeeded", "failed", "stalled" }) |state| try std.testing.expect(!panelStateHollow(state));
}

test "loop detail status includes explicit and presence-based requests for input" {
    var node = GraphModel.Node{
        .id = @constCast("loop"),
        .title = @constCast("Loop"),
        .loop_type = @constCast("sketch"),
        .state = @constCast("awaitingInput"),
        .activity = @constCast(""),
        .presence = @constCast("idle"),
    };
    try std.testing.expect(panelWantsHuman(node));
    try std.testing.expectEqual(@as(u32, 0x000A9FFF), panelStateColor(node));
    node.state = @constCast("running");
    node.presence = @constCast("awaitingInput");
    try std.testing.expect(panelWantsHuman(node));
    try std.testing.expectEqual(@as(u32, 0x000A9FFF), panelStateColor(node));
    node.state = @constCast("succeeded");
    try std.testing.expect(!panelWantsHuman(node));
    try std.testing.expectEqual(@as(u32, 0x0058D130), panelStateColor(node));
}

test "loop card detail prioritizes activity and keeps metadata card-specific" {
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
    try std.testing.expectEqualStrings("checking tests", nodePrimaryDetail(node));
    const meta = try nodeMetadata(std.testing.allocator, node, node.worktree_branch, 0);
    defer std.testing.allocator.free(meta);
    try std.testing.expectEqualStrings("Goal · feature/parity", meta);
}

test "loop card metadata excludes progress and token usage but keeps backend and real age" {
    const node = GraphModel.Node{
        .id = @constCast("node"),
        .title = @constCast("Live"),
        .loop_type = @constCast("goalBased"),
        .state = @constCast("running"),
        .activity = @constCast(""),
        .presence = @constCast("busy"),
        .backend = @constCast("copilotCLI"),
        .created_at = 0,
        .metric_passes = 3,
        .metric_samples = [_]f64{ 1, 2, 3, 0, 0, 0, 0, 0 },
        .metric_sample_count = 3,
        .metric_direction = @constCast("maximize"),
        .token_usage = 12_345,
    };
    const metadata = try nodeMetadata(std.testing.allocator, node, node.worktree_branch, 93600);
    defer std.testing.allocator.free(metadata);
    try std.testing.expectEqualStrings("Goal · Copilot CLI · 1d 2h", metadata);
    const detail = try cardMetricDetail(std.testing.allocator, node);
    defer std.testing.allocator.free(detail);
    try std.testing.expectEqualStrings("1 → 3 · 67% better", detail);
}

test "loop age labels show a just-created daemon loop as recent" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    // The daemon's Date counts seconds from 2001-01-01, 978,307,200 behind Unix time.
    const created = std.time.timestamp() - 978_307_200;
    const frame = try std.fmt.allocPrint(
        allocator,
        "{{\"version\":2,\"kind\":\"event\",\"sequence\":1,\"event\":{{\"graphChanged\":{{\"id\":\"g\",\"project\":{{\"path\":\"A\",\"name\":\"Alpha\"}},\"nodes\":[{{\"id\":\"loop\",\"title\":\"Loop\",\"state\":\"running\",\"createdAt\":{d}.25}}],\"edges\":[]}}}}}}",
        .{created},
    );
    defer allocator.free(frame);
    _ = try model.updateFromFrame(frame);
    const node = model.currentGraph().?.nodes.items[0];
    var buffer: [128]u8 = undefined;
    const meta = try nodeMetadata(allocator, node, node.worktree_branch, node.created_at.?);
    defer allocator.free(meta);
    try std.testing.expectEqualStrings("Turn · 0s", meta);
    const footer = loopDetailFooter(&buffer, node);
    try std.testing.expect(std.mem.startsWith(u8, footer, "started "));
    try std.testing.expect(footer.len > "started ".len);
    try std.testing.expect(std.mem.indexOf(u8, footer, "unknown time") == null);
    try std.testing.expectEqualStrings("oldest 0s", attentionAgeLabelAt(&buffer, node, node.created_at.?));
}

test "attention cards expose reason-specific primary actions" {
    const awaiting = GraphModel.Node{
        .id = @constCast("awaiting"),
        .title = @constCast("Question"),
        .loop_type = @constCast("turnBased"),
        .state = @constCast("running"),
        .activity = @constCast(""),
        .presence = @constCast("awaitingInput"),
    };
    const failed = GraphModel.Node{
        .id = @constCast("failed"),
        .title = @constCast("Broken"),
        .loop_type = @constCast("goalBased"),
        .state = @constCast("failed"),
        .activity = @constCast(""),
        .presence = @constCast("idle"),
    };
    const blocked = graphRoleTestNode("blocked");
    const upstream = graphRoleTestNode("upstream");
    var running_upstream = upstream;
    running_upstream.state = @constCast("running");
    running_upstream.activity = @constCast("Building");
    var waiting = blocked;
    waiting.state = @constCast("blocked");
    const nodes = [_]GraphModel.Node{ running_upstream, waiting };
    const edges = [_]GraphModel.Edge{graphRoleTestEdge("upstream", "blocked", "handoff")};
    try std.testing.expectEqual(AttentionAction.reply, attentionActionForNode(awaiting));
    try std.testing.expectEqualStrings("Reply", attentionActionLabel(awaiting));
    try std.testing.expect(!needsAttention(waiting, &nodes, &edges));
    try std.testing.expect(attentionActionVisible(waiting, &nodes, &edges));
    try std.testing.expectEqual(AttentionAction.inspect, attentionActionForNode(waiting));
    try std.testing.expectEqualStrings("Inspect", attentionActionLabel(waiting));
    try std.testing.expect(needsAttention(failed, &.{failed}, &.{}));
    try std.testing.expectEqual(AttentionAction.none, attentionActionForNode(failed));
    try std.testing.expectEqualStrings("", attentionActionLabel(failed));
    try std.testing.expect(!attentionActionVisible(failed, &.{failed}, &.{}));
}

test "card roles use Mac sequencing reachability including spawn but not message edges" {
    const allocator = std.testing.allocator;
    const nodes = [_]GraphModel.Node{
        graphRoleTestNode("root"),
        graphRoleTestNode("child"),
        graphRoleTestNode("message-source"),
        graphRoleTestNode("message-target"),
        graphRoleTestNode("spawn-source"),
        graphRoleTestNode("spawn-target"),
        graphRoleTestNode("closed-a"),
        graphRoleTestNode("closed-b"),
        graphRoleTestNode("cycle-tail"),
        graphRoleTestNode("self-loop"),
        graphRoleTestNode("declared"),
        graphRoleTestNode("declared-target"),
        graphRoleTestNode("open-a"),
        graphRoleTestNode("open-b"),
        graphRoleTestNode("loose"),
    };
    var edges = [_]GraphModel.Edge{
        graphRoleTestEdge("root", "child", "handoff"),
        graphRoleTestEdge("message-source", "message-target", "message"),
        graphRoleTestEdge("spawn-source", "spawn-target", "spawn"),
        graphRoleTestEdge("root", "closed-a", "message"),
        graphRoleTestEdge("closed-a", "closed-b", "handoff"),
        graphRoleTestEdge("closed-b", "closed-a", "handoff"),
        graphRoleTestEdge("closed-b", "cycle-tail", "handoff"),
        graphRoleTestEdge("self-loop", "self-loop", "handoff"),
        graphRoleTestEdge("root", "declared", "handoff"),
        graphRoleTestEdge("declared", "declared-target", "handoff"),
        graphRoleTestEdge("root", "open-a", "handoff"),
        graphRoleTestEdge("open-a", "open-b", "handoff"),
        graphRoleTestEdge("open-b", "open-a", "handoff"),
    };
    const declared_entries = [_][]const u8{"declared"};
    const roles = try resolveCardRoles(allocator, &nodes, &edges, &declared_entries);
    defer allocator.free(roles);
    try std.testing.expectEqual(NodeRole.entry, roles[0]);
    try std.testing.expectEqual(NodeRole.interior, roles[1]);
    try std.testing.expectEqual(NodeRole.entry, roles[2]);
    try std.testing.expectEqual(NodeRole.entry, roles[3]);
    try std.testing.expectEqual(NodeRole.entry, roles[4]);
    try std.testing.expectEqual(NodeRole.interior, roles[5]);
    try std.testing.expectEqual(NodeRole.cycle_only, roles[6]);
    try std.testing.expectEqual(NodeRole.cycle_only, roles[7]);
    try std.testing.expectEqual(NodeRole.cycle_only, roles[8]);
    try std.testing.expectEqual(NodeRole.cycle_only, roles[9]);
    try std.testing.expectEqual(NodeRole.entry, roles[10]);
    try std.testing.expectEqual(NodeRole.interior, roles[11]);
    try std.testing.expectEqual(NodeRole.interior, roles[12]);
    try std.testing.expectEqual(NodeRole.interior, roles[13]);
    try std.testing.expectEqual(NodeRole.unwired, roles[14]);

    edges[0].fired = true;
    const refired_roles = try resolveCardRoles(allocator, &nodes, &edges, &declared_entries);
    defer allocator.free(refired_roles);
    try std.testing.expectEqual(NodeRole.entry, refired_roles[0]);
    try std.testing.expectEqual(NodeRole.interior, refired_roles[1]);
    const dib = try ParityDib.init(480, 180);
    defer dib.deinit();
    const node = graphRoleTestNode("cycle-chip");
    const bounds = rect(20, 20, 270, 116);
    fill(dib.dc, rect(0, 0, 480, 180), 0);
    try drawCardBody(dib.dc, allocator, node, bounds, 1, .cycle_only, false, null, null);
    try std.testing.expect(c.GdiFlush() != 0);

    const presentation = cardState(node);
    const old_font = try selectCardFont(dib.dc, 10, .card_state);
    defer _ = c.SelectObject(dib.dc, old_font);
    const pill_width = try measuredText(dib.dc, allocator, presentation.word) + 22;
    const meta = cardTextLayout(bounds, 1, pill_width).meta;
    const chip_width = try cardRoleChipWidth(dib.dc, allocator, .cycle_only, 1);
    const chip_height = scaledValue(14, 1);
    const chip_top = @divTrunc(meta.top + meta.bottom - chip_height, 2);
    const chip_bounds = rect(meta.right - chip_width, chip_top, meta.right, chip_top + chip_height);
    const chip = cardRoleChip(.cycle_only).?;
    try std.testing.expect(dib.count(chip_bounds, chip.fill) > 20);
    const text_bounds = rect(chip_bounds.left + scaledValue(chip.padding, 1), chip_bounds.top, chip_bounds.right - scaledValue(chip.padding, 1), chip_bounds.bottom);
    var label_pixels: usize = 0;
    var y = text_bounds.top;
    while (y < text_bounds.bottom) : (y += 1) {
        var x = text_bounds.left;
        while (x < text_bounds.right) : (x += 1) {
            if (c.GetPixel(dib.dc, x, y) != chip.fill) label_pixels += 1;
        }
    }
    try std.testing.expect(label_pixels > 0);
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
    var state = try cardTestState(.{});
    defer state.deinitLayout();
    const offer = reclaimOfferBounds(nodeBounds(0, &state));
    try std.testing.expectEqual(ReclaimAction.reclaim, hitTestReclaimOffer(&nodes, &inspection, &.{}, offer.reclaim.left + 1, offer.reclaim.top + 1, &state).?.action);
    try std.testing.expectEqual(ReclaimAction.keep, hitTestReclaimOffer(&nodes, &inspection, &.{}, offer.keep.left + 1, offer.keep.top + 1, &state).?.action);
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
    var state = try cardTestState(.{ .pan_x = 18, .pan_y = -7, .zoom = 1.15 });
    defer state.deinitLayout();
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
    const message = GraphModel.Edge{
        .id = @constCast("edge"),
        .from = @constCast("a"),
        .to = @constCast("b"),
        .kind = @constCast("message"),
        .condition = @constCast("onSuccess"),
        .fire_count = 2,
    };
    try std.testing.expectEqual(c.PS_DOT, edgeKindPenStyle(message.kind));
    const label = try edgeLabel(std.testing.allocator, message);
    defer std.testing.allocator.free(label);
    try std.testing.expectEqualStrings("message · onSuccess · fired 2", label);
    try std.testing.expect(edgeKindColor("message") != edgeKindColor("spawn"));
}

test "edge guard JSON reaches the production label" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"00000000-0000-4000-8000-000000000001","project":{"path":"edge-fixture","name":"Edge fixture"},"nodes":[],"edges":[{"id":"00000000-0000-4000-8000-000000000002","from":"00000000-0000-4000-8000-000000000003","to":"00000000-0000-4000-8000-000000000004","kind":"handoff","condition":"always","payloadTransform":{"none":{}},"cycleGuard":{"maxIterations":3,"until":"  test -f done  ","stopAfterPassesWithoutImprovement":2},"fireCount":2}]}}}
    );
    const label = try edgeLabel(std.testing.allocator, model.graph.?.edges.items[0]);
    defer std.testing.allocator.free(label);
    try std.testing.expectEqualStrings(
        "handoff · always · loop 2/≤3× or until `test -f done` or 2 flat passes",
        label,
    );
}

fn edgeGuardLabelTestModel(allocator: std.mem.Allocator, edge_json: []const u8) !GraphModel.Model {
    const frame = try std.mem.concat(allocator, u8, &.{
        "{\"version\":2,\"kind\":\"event\",\"sequence\":1,\"event\":{\"graphChanged\":{\"project\":{\"path\":\"edge-fixture\",\"name\":\"Edge fixture\"},\"nodes\":[],\"edges\":[",
        edge_json,
        "]}}}",
    });
    defer allocator.free(frame);
    var model = GraphModel.Model.init(allocator);
    errdefer model.deinit();
    _ = try model.updateFromFrame(frame);
    return model;
}

test "edge guard JSON labels match domain summary variants and legacy counts" {
    const Case = struct { json: []const u8, label: []const u8 };
    const cases = [_]Case{
        .{ .json = "{}", .label = "handoff" },
        .{ .json = "{\"cycleGuard\":null}", .label = "handoff" },
        .{ .json = "{\"fired\":true}", .label = "handoff · always · fired 1" },
        .{ .json = "{\"fireCount\":null,\"fired\":true}", .label = "handoff · always · fired 1" },
        .{ .json = "{\"fireCount\":0,\"fired\":true}", .label = "handoff" },
        .{ .json = "{\"fireCount\":-1,\"fired\":true}", .label = "handoff" },
        .{ .json = "{\"kind\":\"message\",\"condition\":\"onSuccess\",\"fireCount\":2}", .label = "message · onSuccess · fired 2" },
        .{ .json = "{\"cycleGuard\":{}}", .label = "handoff · loop 0/unbounded" },
        .{ .json = "{\"cycleGuard\":{\"maxIterations\":null,\"until\":null,\"stopAfterPassesWithoutImprovement\":null}}", .label = "handoff · loop 0/unbounded" },
        .{ .json = "{\"cycleGuard\":{\"maxIterations\":3}}", .label = "handoff · loop 0/≤3×" },
        .{ .json = "{\"cycleGuard\":{\"maxIterations\":3},\"fireCount\":2}", .label = "handoff · always · loop 2/≤3×" },
        .{ .json = "{\"cycleGuard\":{\"maxIterations\":3},\"fireCount\":0,\"fired\":true}", .label = "handoff · loop 0/≤3×" },
        .{ .json = "{\"cycleGuard\":{\"maxIterations\":3},\"fireCount\":null,\"fired\":true}", .label = "handoff · always · loop 1/≤3×" },
        .{ .json = "{\"cycleGuard\":{\"maxIterations\":0,\"stopAfterPassesWithoutImprovement\":-1}}", .label = "handoff · loop 0/≤0×" },
        .{ .json = "{\"cycleGuard\":{\"maxIterations\":-3},\"fireCount\":-2}", .label = "handoff · loop -2/≤-3×" },
        .{ .json = "{\"cycleGuard\":{\"until\":\"  test -f done  \"}}", .label = "handoff · loop 0/until `test -f done`" },
        .{ .json = "{\"cycleGuard\":{\"until\":\"\"}}", .label = "handoff · loop 0/unbounded" },
        .{ .json = "{\"cycleGuard\":{\"until\":\" \\t\\u00a0\\u2003\\u3000 \"}}", .label = "handoff · loop 0/unbounded" },
        .{ .json = "{\"cycleGuard\":{\"until\":\"\\u00a0\\t echo \\\"yes\\\" \\\\ \\u2603\\u2003\"}}", .label = "handoff · loop 0/until `echo \"yes\" \\ ☃`" },
        .{ .json = "{\"cycleGuard\":{\"until\":\" \\ncommand\\r\\n \"}}", .label = "handoff · loop 0/until `\ncommand\r\n`" },
        .{ .json = "{\"cycleGuard\":{\"stopAfterPassesWithoutImprovement\":1}}", .label = "handoff · loop 0/1 flat passes" },
        .{ .json = "{\"cycleGuard\":{\"stopAfterPassesWithoutImprovement\":0}}", .label = "handoff · loop 0/unbounded" },
        .{ .json = "{\"cycleGuard\":{\"stopAfterPassesWithoutImprovement\":-1}}", .label = "handoff · loop 0/unbounded" },
        .{ .json = "{\"cycleGuard\":{\"maxIterations\":3,\"stopAfterPassesWithoutImprovement\":2}}", .label = "handoff · loop 0/≤3× or 2 flat passes" },
        .{ .json = "{\"cycleGuard\":{\"maxIterations\":3,\"until\":\"done\"}}", .label = "handoff · loop 0/≤3× or until `done`" },
        .{ .json = "{\"condition\":\"onFailure\",\"cycleGuard\":{\"until\":\"done\",\"stopAfterPassesWithoutImprovement\":2}}", .label = "handoff · onFailure · loop 0/until `done` or 2 flat passes" },
        .{ .json = "{\"kind\":\"futureKind\",\"condition\":\"futureCondition\",\"cycleGuard\":{\"budget\":3},\"future\":{\"maxIterations\":7}}", .label = "futureKind · futureCondition · loop 0/unbounded" },
        .{ .json = "{\"fireCount\":9223372036854775807,\"cycleGuard\":{\"maxIterations\":-9223372036854775808,\"stopAfterPassesWithoutImprovement\":9223372036854775807}}", .label = "handoff · always · loop 9223372036854775807/≤-9223372036854775808× or 9223372036854775807 flat passes" },
    };
    for (cases) |case| {
        var model = try edgeGuardLabelTestModel(std.testing.allocator, case.json);
        defer model.deinit();
        for ([_]GraphModel.Edge{ model.graph.?.edges.items[0], model.currentGraph().?.edges.items[0] }) |edge| {
            const label = try edgeLabel(std.testing.allocator, edge);
            defer std.testing.allocator.free(label);
            try std.testing.expectEqualStrings(case.label, label);
        }
    }
}

test "edge guard long Unicode labels remain complete and allocation failures unwind" {
    const allocator = std.testing.allocator;
    const command = "☃" ** 100;
    const json = try std.fmt.allocPrint(allocator, "{{\"cycleGuard\":{{\"until\":\"{s}\"}},\"fireCount\":2}}", .{command});
    defer allocator.free(json);
    var model = try edgeGuardLabelTestModel(allocator, json);
    defer model.deinit();
    const expected = "handoff · always · loop 2/until `" ++ command ++ "`";
    const label = try edgeLabel(allocator, model.graph.?.edges.items[0]);
    defer allocator.free(label);
    try std.testing.expect(label.len > 128);
    try std.testing.expect(std.unicode.utf8ValidateSlice(label));
    try std.testing.expectEqualStrings(expected, label);
    const Exercise = struct {
        fn run(test_allocator: std.mem.Allocator, edge: GraphModel.Edge) !void {
            const text = try edgeLabel(test_allocator, edge);
            defer test_allocator.free(text);
            try std.testing.expectEqualStrings(expected, text);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Exercise.run, .{model.graph.?.edges.items[0]});
    try std.testing.expectError(error.InvalidUtf8, edgeLabel(allocator, .{
        .from = &.{},
        .to = &.{},
        .cycle_guard = .{ .until = @constCast("\xff") },
    }));
}

test "edge guard malformed refresh keeps the previous production label" {
    const allocator = std.testing.allocator;
    var model = try edgeGuardLabelTestModel(allocator,
        \\{"id":"kept","from":"a","to":"b","cycleGuard":{"maxIterations":3,"until":"done"},"fireCount":2}
    );
    defer model.deinit();
    try std.testing.expectError(error.MalformedEdge, model.updateFromFrame(
        \\{"event":{"graphChanged":{"project":{"path":"edge-fixture","name":"Edge fixture"},"nodes":[],"edges":[{"id":"kept","cycleGuard":{"maxIterations":"invalid"}}]}}}
    ));
    const label = try edgeLabel(allocator, model.graph.?.edges.items[0]);
    defer allocator.free(label);
    try std.testing.expectEqualStrings("handoff · always · loop 2/≤3× or until `done`", label);
}

test "edge guard production label follows composite refresh and guard removal" {
    const allocator = std.testing.allocator;
    var model = GraphModel.Model.init(allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"event":{"graphChanged":{"project":{"path":"edge-fixture","name":"Edge fixture"},"edges":[],"nodes":[{"id":"parent","title":"Group","loopType":"proactive","subGraph":{"nodes":[],"edges":[{"id":"nested","from":"a","to":"b","cycleGuard":{"until":"first"},"fireCount":1}]}}]}}}
    );
    try std.testing.expect(model.openComposite("parent"));
    const first = try edgeLabel(allocator, model.graph.?.edges.items[0]);
    defer allocator.free(first);
    try std.testing.expectEqualStrings("handoff · always · loop 1/until `first`", first);
    _ = try model.updateFromFrame(
        \\{"event":{"graphChanged":{"project":{"path":"edge-fixture","name":"Edge fixture"},"edges":[],"nodes":[{"id":"parent","title":"Group","loopType":"proactive","subGraph":{"nodes":[],"edges":[{"id":"nested","from":"a","to":"b","cycleGuard":{"maxIterations":4},"fireCount":2}]}}]}}}
    );
    try std.testing.expectEqualStrings("nested", model.graph.?.edges.items[0].id);
    const refreshed = try edgeLabel(allocator, model.graph.?.edges.items[0]);
    defer allocator.free(refreshed);
    try std.testing.expectEqualStrings("handoff · always · loop 2/≤4×", refreshed);
    _ = try model.updateFromFrame(
        \\{"event":{"graphChanged":{"project":{"path":"edge-fixture","name":"Edge fixture"},"edges":[],"nodes":[{"id":"parent","title":"Group","loopType":"proactive","subGraph":{"nodes":[],"edges":[{"id":"nested","from":"a","to":"b","cycleGuard":null,"fireCount":0,"fired":true}]}}]}}}
    );
    const removed = try edgeLabel(allocator, model.graph.?.edges.items[0]);
    defer allocator.free(removed);
    try std.testing.expectEqualStrings("handoff", removed);
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
