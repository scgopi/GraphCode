const std = @import("std");
const GraphModel = @import("GraphModel.zig");
const Tokens = @import("DesignTokens.zig");
const Sidebar = @import("Sidebar.zig");
const WorktreeStatus = @import("WorktreeStatus.zig");
const WorkspaceControls = @import("WorkspaceControls.zig");
const LoopBarLayout = @import("LoopBarLayout.zig");
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
        if (index >= self.node_offsets.len) return;
        self.node_dragging = true;
        self.node_drag_started = false;
        self.node_drag_index = index;
        self.node_drag_key = nodeKey(node_id);
        self.node_drag_x = x;
        self.node_drag_y = y;
        self.node_drag_origin = self.node_offsets[index];
    }

    pub fn updateNodeDrag(self: *CanvasState, x: i32, y: i32) void {
        if (!self.node_dragging or self.node_drag_index >= self.node_offsets.len) return;
        if (!self.node_drag_started) {
            if (@abs(x - self.node_drag_x) < 6 and @abs(y - self.node_drag_y) < 6) return;
            self.node_drag_started = true;
        }
        self.node_offsets[self.node_drag_index] = .{
            .x = self.node_drag_origin.x + @as(f32, @floatFromInt(x - self.node_drag_x)) / self.zoom,
            .y = self.node_drag_origin.y + @as(f32, @floatFromInt(y - self.node_drag_y)) / self.zoom,
        };
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
    title: []const u8 = "GraphCode Windows",
    context: []const u8 = "",
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
        const identity_right = @min(right, @max(0, @min(280, @divTrunc(width, 3))));
        result.identity = rect(@min(8, identity_right), 1, identity_right, Tokens.header_height - 1);
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
pub const AttentionAction = enum { reply, inspect };
pub const ReclaimAction = enum { reclaim, keep };
pub const ReclaimHit = struct { node_index: usize, action: ReclaimAction };

pub fn attentionRailBounds(width: i32) c.RECT {
    return rect(Tokens.sidebar_width + 20, Tokens.header_height + 12, width - 20, Tokens.header_height + 43);
}

pub fn hitTestAttentionRail(x: i32, y: i32, width: i32) bool {
    return insideGraph(x, y, attentionRailBounds(width));
}

/// The rail belongs to the graph surfaces. A loop workspace paints its loop bar over the
/// same strip, so there it is neither drawn nor clickable: a click on the bar's Show in
/// Graph button must never land on the rail's Review action.
pub fn attentionRailShown(model: *const GraphModel.Model, surface: Surface) bool {
    return surface != .workspace and model.attentionCount() != 0;
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
        .overview => drawOverview(hdc, allocator, model, graph_bounds, state),
        .quick_chats => drawQuickChats(hdc, allocator, model, graph_bounds, state),
        .project => if (model.graph) |graph| {
            drawProjectWorktreeChip(hdc, allocator, model, graph_bounds);
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
    if (attentionRailShown(model, surface)) attentionRail(hdc, allocator, model, client.right);
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
) void {
    if (model.graphs.items.len == 0) {
        const center_y = bounds.top + @divTrunc(bounds.bottom - bounds.top, 2) - 60;
        drawTextRect(hdc, allocator, "Nothing running yet", rect(bounds.left + 40, center_y, bounds.right - 40, center_y + 34), 20, 0x00F2F2F2, c.DT_CENTER | c.DT_SINGLELINE);
        drawTextRect(hdc, allocator, "Loops from every folder you open show up here, wired to how they run.", rect(bounds.left + 100, center_y + 40, bounds.right - 100, center_y + 86), 13, 0x00A8A8AE, c.DT_CENTER | c.DT_WORDBREAK);
        return;
    }
    for (model.graphs.items, 0..) |graph, graph_index| {
        const lane = overviewLaneBounds(model, graph_index, bounds, state);
        roundedCard(hdc, lane, Tokens.workspace_rail, false);
        const caption = overviewLaneCaption(model, graph_index, bounds, state);
        drawTextRect(hdc, allocator, graph.project.name, caption.title, scaledValue(14, state.zoom), 0x00E8E8E8, c.DT_LEFT | c.DT_SINGLELINE | c.DT_VCENTER | c.DT_END_ELLIPSIS);
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
        var index: usize = 0;
        while (index < graph.nodes.items.len) : (index += 1) {
            const card = overviewCardBounds(model, graph_index, index, bounds, state);
            roundedCard(hdc, card, Tokens.loop_card_bottom, false);
            fill(hdc, rect(card.left, card.top, card.left + scaledValue(4, state.zoom), card.bottom), loopTypeColor(graph.nodes.items[index].loop_type));
            drawCardBody(hdc, allocator, graph.nodes.items[index], card, state.zoom, .interior, false, false) catch |err| {
                std.log.warn("Overview card {s} presentation failed: {s}", .{ graph.nodes.items[index].id, @errorName(err) });
            };
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
    return transformedRect(bounds, state, 24, top, @max(806, bounds.right - bounds.left - 48), height);
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
        lane.left + scaledValue(18 + column * 260, state.zoom),
        lane.top + scaledValue(46 + row * 122, state.zoom),
        lane.left + scaledValue(18 + column * 260, state.zoom) + scaledValue(Tokens.loop_card_width, state.zoom),
        lane.top + scaledValue(46 + row * 122, state.zoom) + scaledValue(Tokens.loop_card_height, state.zoom),
    );
}

pub const OverviewLaneCaption = struct {
    title: c.RECT,
    open: c.RECT,
    worktrees: c.RECT,
    notice: ?c.RECT,
};

pub fn overviewLaneCaption(model: *const GraphModel.Model, graph_index: usize, bounds: c.RECT, state: *const CanvasState) OverviewLaneCaption {
    const lane = overviewLaneBounds(model, graph_index, bounds, state);
    const open = rect(lane.right - scaledValue(132, state.zoom), lane.top + scaledValue(10, state.zoom), lane.right - scaledValue(76, state.zoom), lane.top + scaledValue(30, state.zoom));
    const worktrees = rect(lane.right - scaledValue(72, state.zoom), lane.top + scaledValue(10, state.zoom), lane.right - scaledValue(18, state.zoom), lane.top + scaledValue(30, state.zoom));
    const notice = if (graph_index < model.graphs.items.len and overviewWorktreeNotice(&model.graphs.items[graph_index]) != null)
        rect(open.left - scaledValue(294, state.zoom), open.top, open.left - scaledValue(8, state.zoom), open.bottom)
    else
        null;
    return .{
        .title = rect(lane.left + scaledValue(18, state.zoom), open.top, (if (notice) |value| value.left else open.left) - scaledValue(10, state.zoom), open.bottom),
        .open = open,
        .worktrees = worktrees,
        .notice = notice,
    };
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
    drawTextRect(
        hdc,
        allocator,
        "Zoom  Ctrl+-  Ctrl+0  Ctrl+=  Ctrl+9",
        rect(bounds.right - 292, bounds.bottom - 68, bounds.right - 12, bounds.bottom - 50),
        9,
        0x008A8A8A,
        c.DT_RIGHT | c.DT_SINGLELINE | c.DT_VCENTER,
    );
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
            break :blk .{ .width = 854, .height = @max(1, height) };
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
    if (presentation.context.len != 0) {
        var context_bounds = layout.identity;
        context_bounds.top = 1;
        context_bounds.bottom = 15;
        title_bounds.top = 14;
        title_bounds.bottom = Tokens.header_height - 1;
        drawTextRect(hdc, allocator, presentation.context, context_bounds, 8, 0x00A8A8A8, flags);
    }
    drawTextRect(hdc, allocator, presentation.title, title_bounds, 11, 0x00FFFFFF, flags);
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
    const bounds = rect(220, 34, 1200, 900);
    const state = CanvasState{};
    const a = overviewLaneCaption(&model, 0, bounds, &state);
    const b = overviewLaneCaption(&model, 1, bounds, &state);
    try std.testing.expectEqualDeep(rect(1044, 82, 1100, 102), a.open);
    try std.testing.expectEqualDeep(rect(1104, 82, 1158, 102), a.worktrees);
    try std.testing.expectEqualDeep(rect(750, 82, 1036, 102), a.notice.?);
    try std.testing.expectEqualDeep(rect(750, 198, 1036, 218), b.notice.?);
    try std.testing.expect(a.title.right < a.notice.?.left);
    try std.testing.expect(a.notice.?.right < a.open.left);
    try std.testing.expectEqual(OverviewLaneAction.inspect_worktrees, overviewLaneActionAt(&model, 0, 760, 92, bounds, &state).?);
    try std.testing.expectEqual(OverviewLaneAction.inspect_worktrees, overviewLaneActionAt(&model, 1, 760, 208, bounds, &state).?);
    try std.testing.expect(overviewLaneActionAt(&model, 0, 760, 208, bounds, &state) == null);
    try std.testing.expect(overviewLaneActionAt(&model, 0, 740, 92, bounds, &state) == null);
    try std.testing.expect(overviewLaneCaption(&model, 2, bounds, &state).notice == null);
    const transformed = CanvasState{ .zoom = 1.5, .pan_x = 17, .pan_y = -9 };
    try std.testing.expectEqualDeep(rect(1142, 114, 1571, 144), overviewLaneCaption(&model, 0, bounds, &transformed).notice.?);
    try std.testing.expectEqual(OverviewLaneAction.inspect_worktrees, overviewLaneActionAt(&model, 0, 1150, 120, bounds, &transformed).?);
    try std.testing.expect(overviewLaneActionAt(&model, 0, 1300, 120, bounds, &transformed) == null);
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
    try std.testing.expect(overviewLaneCaption(&model, 0, rect(220, 34, 1200, 900), &.{}).notice == null);
    try std.testing.expectEqual(OverviewLaneAction.inspect_worktrees, overviewLaneActionAt(&model, 0, 1130, 92, rect(220, 34, 1200, 900), &.{}).?);
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
    const rail = attentionRailBounds(width);
    fill(hdc, rail, 0x002D2418);
    const review_left = Tokens.sidebar_width + 210;
    const age_left = Tokens.sidebar_width + 274;
    drawText(hdc, allocator, label, Tokens.sidebar_width + 34, Tokens.header_height + 21, 12, 0x00FFCD7A, review_left - 12);
    var age_buffer: [96]u8 = undefined;
    const oldest = if (model.attention_entries.items.len != 0)
        attentionAgeLabel(&age_buffer, model.attention_entries.items[0].node)
    else
        "none";
    drawText(hdc, allocator, "Review", review_left, Tokens.header_height + 21, 11, 0x00E6E6E6, age_left - 12);
    drawText(hdc, allocator, oldest, age_left, Tokens.header_height + 21, 10, 0x00B8B8B8, rail.right - 18);
}

fn attentionAgeLabel(buffer: []u8, node: GraphModel.Node) []const u8 {
    if (node.created_at) |created| {
        return std.fmt.bufPrint(buffer, "oldest {s}: {s}", .{ elapsedLabel(created), node.title }) catch node.title;
    }
    return node.title;
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
        fill(hdc, bounds, Tokens.canvas_tone);
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

fn drawBezier(hdc: c.HDC, from: Connector, to: Connector, color: u32, style: c_int) void {
    const distance: i32 = if (to.x >= from.x) to.x - from.x else from.x - to.x;
    const bend: i32 = @max(@as(i32, 24), @divTrunc(distance, 2));
    const width: f32 = if (style == c.PS_SOLID) 2 else 1;
    const p1 = c.POINT{ .x = from.x, .y = from.y };
    const p2 = c.POINT{ .x = from.x + bend, .y = from.y };
    const p3 = c.POINT{ .x = to.x - bend, .y = to.y };
    const p4 = c.POINT{ .x = to.x, .y = to.y };
    // Solid connectors are anti-aliased via GDI+; dashed/preview styles
    // (style != PS_SOLID) keep plain GDI since GDI+'s dash patterns don't
    // need to match pixel-for-pixel and the pen style enum differs.
    if (style == c.PS_SOLID and
        GdiplusAA.drawBezier(hdc, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y, p4.x, p4.y, color, width))
    {
        return;
    }

    const pen = c.CreatePen(style, if (style == c.PS_SOLID) 2 else 1, color);
    if (pen == null) return;
    const old = c.SelectObject(hdc, pen);
    var points = [_]c.POINT{ p1, p2, p3, p4 };
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
    // Theme.loopCard's bottom stop (#232326), used for both states: selection is
    // carried by the border/ring (Tokens.canvas_selection via roundedCard's
    // `selected` flag), matching mac -- there is no "selected node fill" color in
    // Theme.swift. Previously an ad-hoc 0x00345D8C blue with no Theme.swift source.
    roundedCard(hdc, bounds, Tokens.loop_card_bottom, selected_card);
    const stripe = loopTypeColor(node.loop_type);
    fill(hdc, rect(x, y, x + scaled(Tokens.loop_card_stripe, state), y + bounds.bottom - y), stripe);
    const role = nodeRole(edges, node.id, declared_entries);
    const reclaim_offer = hasReclaimOffer(node, inspection, kept_worktrees);
    drawCardBody(hdc, allocator, node, bounds, state.zoom, role, attention, reclaim_offer) catch |err| {
        std.log.warn("Project card {s} presentation failed: {s}", .{ node.id, @errorName(err) });
    };
    if (attentionActionVisible(node, nodes, edges)) {
        const action = attentionActionBounds(bounds, state);
        fill(hdc, action, 0x000A9FFF);
        drawTextRect(hdc, allocator, attentionActionLabel(node), action, scaled(9, state), 0x00241703, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
    }
    if (state.hovered_connector == index) {
        const connector = connectorPositionForIndex(nodes, index, true, state);
        fill(hdc, rect(connector.x - connectorRadius(state), connector.y - connectorRadius(state), connector.x + connectorRadius(state), connector.y + connectorRadius(state)), 0x00FFCD7A);
        drawTextRect(hdc, allocator, "+", rect(connector.x - scaled(8, state), connector.y - scaled(8, state), connector.x + scaled(8, state), connector.y + scaled(8, state)), scaled(12, state), 0x00262626, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
    }

    if (reclaim_offer) {
        const offer = reclaimOfferBounds(bounds);
        fill(hdc, offer.reclaim, 0x003A3A44);
        drawTextRect(hdc, allocator, "Reclaim", offer.reclaim, scaled(9, state), 0x00E6E6E6, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
        drawTextRect(hdc, allocator, "Keep", offer.keep, scaled(9, state), 0x008A8A8A, c.DT_CENTER | c.DT_SINGLELINE | c.DT_VCENTER);
    }
}

pub fn attentionActionLabel(node: GraphModel.Node) []const u8 {
    return switch (attentionActionForNode(node)) {
        .reply => "Reply",
        .inspect => "Inspect",
    };
}

pub fn attentionActionForNode(node: GraphModel.Node) AttentionAction {
    if (std.mem.eql(u8, node.state, "running") and std.mem.eql(u8, node.presence, "awaitingInput")) return .reply;
    return .inspect;
}

pub fn attentionActionBounds(bounds: c.RECT, state: *const CanvasState) c.RECT {
    return rect(bounds.right - scaled(77, state), bounds.top + scaled(51, state), bounds.right - scaled(11, state), bounds.top + scaled(68, state));
}

pub fn attentionActionVisible(node: GraphModel.Node, nodes: []const GraphModel.Node, edges: []const GraphModel.Edge) bool {
    return needsAttention(node, nodes, edges);
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
        .reclaim = rect(bounds.left + scaledValue(11, zoom), bounds.top + scaledValue(51, zoom), bounds.left + scaledValue(77, zoom), bounds.top + scaledValue(68, zoom)),
        .keep = rect(bounds.left + scaledValue(83, zoom), bounds.top + scaledValue(51, zoom), bounds.left + scaledValue(119, zoom), bounds.top + scaledValue(68, zoom)),
    };
}

pub fn hasReclaimOffer(
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
    if (std.mem.trim(u8, node.activity, " \t\r\n").len != 0) return node.activity;
    if (std.mem.eql(u8, node.loop_type, "goalBased")) return node.goal_summary;
    if (std.mem.eql(u8, node.loop_type, "timeBased")) return node.trigger_prompt;
    if (std.mem.eql(u8, node.loop_type, "turnBased")) return node.check_description;
    if (std.mem.eql(u8, node.loop_type, "composite") or std.mem.eql(u8, node.loop_type, "proactive")) return node.pilot_state;
    return node.first_instruction;
}

fn cardLiveLine(allocator: std.mem.Allocator, node: GraphModel.Node) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    if (std.mem.trim(u8, node.activity, " \t\r\n").len == 0 and
        (std.mem.eql(u8, node.loop_type, "composite") or std.mem.eql(u8, node.loop_type, "proactive")))
    {
        const pilot = cardPilotName(node.pilot_state);
        if (node.subgraph_json.len == 0) return allocator.dupe(u8, pilot);
        const count = GraphModel.subgraphNodeCount(node.subgraph_json);
        try result.writer().print("{d} {s} · {s}", .{ count, if (count == 1) "loop" else "loops", pilot });
        return result.toOwnedSlice();
    }
    const source = nodePrimaryDetail(node);
    if (std.mem.eql(u8, source, node.activity) and std.mem.trim(u8, source, " \t\r\n").len != 0 and node.metric_passes != 0)
        try result.writer().print("pass {d} · ", .{node.metric_passes});
    var iterator = (try std.unicode.Utf8View.init(source)).iterator();
    var pending_space = false;
    while (iterator.nextCodepointSlice()) |bytes| {
        const cp = try std.unicode.utf8Decode(bytes);
        const whitespace = cp == ' ' or (cp >= 9 and cp <= 13) or cp == 0x85 or cp == 0xa0 or cp == 0x1680 or
            (cp >= 0x2000 and cp <= 0x200a) or cp == 0x2028 or cp == 0x2029 or cp == 0x202f or cp == 0x205f or cp == 0x3000;
        if (whitespace) {
            pending_space = result.items.len != 0;
        } else {
            if (pending_space and result.items.len != 0 and result.items[result.items.len - 1] != ' ') try result.append(' ');
            try result.appendSlice(bytes);
            pending_space = false;
        }
    }
    return result.toOwnedSlice();
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
    const first = node.metric_samples[0];
    const last = node.metric_samples[@as(usize, node.metric_sample_count) - 1];
    if (!std.math.isFinite(first) or !std.math.isFinite(last)) return error.InvalidCardMetric;
    const whole = first == @round(first) and last == @round(last);
    if (whole) try writeMetricNumber(writer, first) else try writer.print("{d:.2}", .{first});
    try writer.writeAll(" → ");
    if (whole) try writeMetricNumber(writer, last) else try writer.print("{d:.2}", .{last});
    const ratio = cardMetricRatio(node);
    const percent: u32 = @intFromFloat(@round(@abs(ratio) * 100));
    if (percent == 0) try writer.writeAll(" · flat") else try writer.print(" · {d}% {s}", .{ percent, if (ratio > 0) "better" else "worse" });
}

fn cardMetricRatio(node: GraphModel.Node) f64 {
    const first = node.metric_samples[0];
    const last = node.metric_samples[@as(usize, node.metric_sample_count) - 1];
    const scale = @max(@abs(first), @abs(last));
    if (scale == 0) return 0;
    return if (std.mem.eql(u8, node.metric_direction, "minimize")) first / scale - last / scale else last / scale - first / scale;
}

fn writeMetricNumber(writer: anytype, value: f64) !void {
    if (@abs(value) < 1_000_000 and value == @round(value))
        return writer.print("{d}", .{@as(i64, @intFromFloat(value))});
    return writer.print("{d:.2}", .{value});
}

fn elapsedLabel(created_at: u64) []const u8 {
    const normalized = if (created_at < 1_000_000_000_000) created_at *| 1000 else created_at;
    const now = std.time.milliTimestamp();
    const created: i64 = @intCast(@min(normalized, @as(u64, std.math.maxInt(i64))));
    const elapsed_ms: u64 = if (now > created) @intCast(now - created) else 0;
    const seconds = elapsed_ms / 1000;
    if (seconds < 60) return "0m";
    if (seconds < 3600) return "<1h";
    if (seconds < 86_400) return ">1h";
    return ">1d";
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

fn drawCardBody(hdc: c.HDC, allocator: std.mem.Allocator, node: GraphModel.Node, bounds: c.RECT, zoom: f32, role: NodeRole, attention: bool, reclaim: bool) !void {
    const presentation = cardState(node);
    const pill_width = blk: {
        const old = try selectCardFont(hdc, 10 * zoom, .card_state);
        defer _ = c.SelectObject(hdc, old);
        break :blk (try measuredText(hdc, allocator, presentation.word)) + scaledValue(22, zoom);
    };
    const layout = cardTextLayout(bounds, zoom, pill_width);
    try drawCardText(hdc, allocator, node.title, layout.title, 14.5 * zoom, .card_title, 0x00F4F4F4, true);
    try drawCardPill(hdc, allocator, presentation, layout.pill, zoom);
    const live = try cardLiveLine(allocator, node);
    defer allocator.free(live);
    try drawCardText(hdc, allocator, live, layout.live, 10.5 * zoom, .card_mono, 0x009F9C9C, true);
    const metric = try cardMetricDetail(allocator, node);
    defer allocator.free(metric);
    if (!attention and !reclaim) {
        const entry_detail = if (role == .entry and metric.len != 0) try std.fmt.allocPrint(allocator, "START · {s}", .{metric}) else null;
        defer if (entry_detail) |text| allocator.free(text);
        const detail = if (role == .unwired) "UNWIRED · No connections · right-click to recover" else if (role == .entry) entry_detail orelse "START" else metric;
        var detail_bounds = layout.detail;
        if (metric.len != 0 and role != .unwired) detail_bounds.bottom -= scaledValue(4, zoom);
        try drawCardText(hdc, allocator, detail, detail_bounds, 10.5 * zoom, .card_mono, if (role == .unwired) 0x007ACDFF else 0x009F9C9C, true);
        if (metric.len != 0 and role != .unwired) {
            const track = rect(layout.detail.left, layout.detail.bottom - scaledValue(2, zoom), layout.detail.right, layout.detail.bottom);
            fill(hdc, track, 0x00444141);
            const fraction = std.math.clamp(cardMetricRatio(node), 0, 1);
            const end = track.left + @as(i32, @intFromFloat(@as(f64, @floatFromInt(track.right - track.left)) * fraction));
            if (end > track.left) fill(hdc, rect(track.left, track.top, end, track.bottom), loopTypeColor(node.loop_type));
        }
    } else if (role != .interior) {
        const role_bounds = rect(if (reclaim) reclaimOfferBounds(bounds).keep.right + scaledValue(6, zoom) else layout.live.left, layout.detail.top, if (attention) attentionActionBounds(bounds, &.{ .zoom = zoom }).left - scaledValue(6, zoom) else layout.detail.right, layout.detail.bottom);
        try drawCardText(hdc, allocator, if (role == .entry) "START" else "UNWIRED", role_bounds, 10.5 * zoom, .card_mono, 0x009F9C9C, true);
    }
    const meta_text_bounds = rect(layout.meta.left + scaledValue(11, zoom), layout.meta.top, layout.meta.right, layout.meta.bottom);
    const meta = blk: {
        const old = try selectCardFont(hdc, 10.5 * zoom, .card_mono);
        defer _ = c.SelectObject(hdc, old);
        break :blk cardMetaForWidth(hdc, allocator, node, @intCast(@max(0, std.time.timestamp())), meta_text_bounds.right - meta_text_bounds.left) catch |err| switch (err) {
            error.CardMetadataTooWide => {
                std.log.warn("Card {s} fixed metadata does not fit: {s}", .{ node.id, @errorName(err) });
                try drawCardText(hdc, allocator, "Metadata unavailable", layout.meta, 10.5 * zoom, .card_mono, Tokens.dialog_error_text, true);
                return;
            },
            else => return err,
        };
    };
    defer allocator.free(meta);
    const square_top = @divTrunc(layout.meta.top + layout.meta.bottom - scaledValue(6, zoom), 2);
    fill(hdc, rect(layout.meta.left, square_top, layout.meta.left + scaledValue(6, zoom), square_top + scaledValue(6, zoom)), loopTypeColor(node.loop_type));
    try drawCardText(hdc, allocator, meta, meta_text_bounds, 10.5 * zoom, .card_mono, blendCardColor(0x00FFFFFF, Tokens.loop_card_bottom, 52), false);
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

fn loopTypeColor(loop_type: []const u8) u32 {
    if (std.mem.eql(u8, loop_type, "composite") or std.mem.eql(u8, loop_type, "proactive")) return 0x00C77DFF;
    if (std.mem.eql(u8, loop_type, "goalBased")) return 0x000A84FF;
    if (std.mem.eql(u8, loop_type, "turnBased")) return 0x00D6A649;
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
    try std.testing.expectEqual(@as(u32, 0x00C77DFF), loopTypeColor("composite"));
}

test "dense edge labels move away from already placed labels" {
    const first = rect(100, 100, 248, 120);
    try std.testing.expect(overlapsPlaced(rect(120, 110, 200, 118), &.{first}));
    try std.testing.expect(!overlapsPlaced(rect(260, 110, 340, 118), &.{first}));
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

test "node card release activates below drag threshold and movement only drags" {
    var state = CanvasState{};
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
    const bounds = rect(Tokens.sidebar_width, Tokens.header_height, 1200, 900);
    const identity = CanvasState{};
    try std.testing.expectEqualDeep(rect(244, 72, 1176, 376), overviewLaneBounds(&model, 0, bounds, &identity));
    try std.testing.expectEqualDeep(rect(244, 396, 1176, 572), overviewLaneBounds(&model, 1, bounds, &identity));
    try std.testing.expectEqualDeep(rect(262, 240, 512, 336), overviewCardBounds(&model, 0, 3, bounds, &identity));
    try std.testing.expectEqualDeep(rect(262, 442, 512, 538), overviewCardBounds(&model, 1, 0, bounds, &identity));

    for ([_]CanvasState{
        .{},
        .{ .zoom = 0.75, .pan_x = 100, .pan_y = 17 },
        .{ .zoom = 1.25, .pan_x = -30, .pan_y = -12 },
    }) |state| {
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
    const empty_lane = overviewLaneBounds(&model, 1, bounds, &identity);
    try std.testing.expectEqualDeep(rect(244, 396, 1176, 492), empty_lane);
    try std.testing.expectEqual(OverviewLaneAction.open_project, overviewLaneActionAt(&model, 1, 1072, 416, bounds, &identity).?);
    try std.testing.expectEqual(OverviewLaneAction.inspect_worktrees, overviewLaneActionAt(&model, 1, 1131, 416, bounds, &identity).?);
    try std.testing.expect(hitTestOverview(&model, 264, 444, &identity, bounds) == null);
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

test "loop card parity project metrics match the shipping card" {
    const bounds = nodeBounds(0, &.{});
    try std.testing.expectEqual(@as(i32, 250), bounds.right - bounds.left);
    try std.testing.expectEqual(@as(i32, 96), bounds.bottom - bounds.top);
}

test "loop card parity overview metrics match the project card" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    const bounds = overviewCardBounds(&model, 0, 0, rect(220, 34, 1200, 900), &.{});
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
        const state = CanvasState{ .zoom = zoom, .pan_x = 1200, .pan_y = -20 };
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

test "loop card parity metrics and rows fit the owning card" {
    const dc = c.CreateCompatibleDC(null) orelse return error.TestDcCreationFailed;
    defer _ = c.DeleteDC(dc);
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    for ([_]f32{ 0.55, 0.75, 1, 1.25, 1.8 }) |zoom| {
        const state = CanvasState{ .zoom = zoom, .pan_x = 1300, .pan_y = -17 };
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
        const adjacent = overviewCardBounds(&model, 0, 1, rect(220, 34, 1200, 900), &state);
        const next_row = overviewCardBounds(&model, 0, 3, rect(220, 34, 1200, 900), &state);
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
    try std.testing.expectEqual(@as(i32, 854), contentSize(&model, .overview).width);
    for ([_]i32{ 1028, 1440 }) |right| {
        const viewport = rect(220, 34, right, 900);
        for ([_]CanvasState{ .{}, .{ .zoom = 0.75, .pan_x = 15, .pan_y = -12 }, .{ .zoom = 1.25, .pan_x = -120, .pan_y = 20 } }) |state| {
            const lane = overviewLaneBounds(&model, 0, viewport, &state);
            const next_lane = overviewLaneBounds(&model, 1, viewport, &state);
            const first = overviewCardBounds(&model, 0, 0, viewport, &state);
            const second = overviewCardBounds(&model, 0, 1, viewport, &state);
            const third = overviewCardBounds(&model, 0, 2, viewport, &state);
            const fourth = overviewCardBounds(&model, 0, 3, viewport, &state);
            try std.testing.expect(first.right < second.left and second.right < third.left);
            try std.testing.expect(first.bottom < fourth.top and fourth.bottom < lane.bottom);
            try std.testing.expect(third.right < lane.right and lane.bottom < next_lane.top);
        }
    }
    const narrow = rect(220, 34, 1028, 900);
    const caption = overviewLaneCaption(&model, 0, narrow, &.{});
    try std.testing.expectEqualDeep(rect(918, 82, 974, 102), caption.open);
    try std.testing.expectEqualDeep(rect(978, 82, 1032, 102), caption.worktrees);
    try std.testing.expect(caption.worktrees.left < narrow.right and caption.worktrees.right > narrow.right);
    try std.testing.expectEqual(OverviewLaneAction.inspect_worktrees, overviewLaneActionAt(&model, 0, 1005, 92, narrow, &.{}).?);
    const panned = CanvasState{ .pan_x = -30 };
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

fn paintExportFixture(dib: ParityDib, model: *const GraphModel.Model, allocator: std.mem.Allocator) !void {
    if (c.SetMapMode(dib.dc, c.MM_ANISOTROPIC) == 0) return error.PaintFixtureMapModeFailed;
    if (c.SetWindowExtEx(dib.dc, 96, 96, null) == 0 or c.SetViewportExtEx(dib.dc, 96, 96, null) == 0)
        return error.PaintFixtureDpiMappingFailed;
    const state = CanvasState{ .zoom = 1, .pan_x = 0, .pan_y = 0 };
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
        .project,
    );
    paintHeader(
        dib.dc,
        allocator,
        1280,
        "",
        .{ .title = "GraphCode", .context = "Alpha", .panel_visible = false },
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
};

fn verifyPaintContract(dib: ParityDib, fixture: *const PaintExportFixture, allocator: std.mem.Allocator) !void {
    const model = &fixture.model;
    const graph = model.graph orelse return error.PaintFixtureGraphMissing;
    const viewport = renderBounds(1280, 720, .{
        .rail_visible = true,
        .panel_visible = false,
        .activity_enabled = false,
    });
    const state = CanvasState{ .zoom = 1, .pan_x = 0, .pan_y = 0 };
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

fn renderPaintArtifact(
    allocator: std.mem.Allocator,
    fixture: *const PaintExportFixture,
    path: []const u8,
) !PaintRenderProof {
    var dib = try ParityDib.init(1280, 720);
    defer dib.deinit();
    if (!GdiplusAA.isReady()) return error.PaintExportGdiplusNotReady;
    try paintExportFixture(dib, &fixture.model, allocator);
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
    const state = CanvasState{ .pan_x = 1200 };
    const viewport = rect(220, 34, 2200, 500);
    fill(dib.dc, rect(0, 0, 2200, 500), 0);
    drawNode(dib.dc, allocator, node, 0, null, &.{node}, &.{}, null, &.{}, &.{}, &state);
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
    drawOverview(dib.dc, allocator, &model, viewport, &state);
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
            const state = CanvasState{ .zoom = zoom, .pan_x = 25, .pan_y = 19 };
            const bounds = nodeBounds(0, &state);
            fill(dib.dc, rect(0, 0, 1000, 450), 0);
            roundedCard(dib.dc, bounds, Tokens.loop_card_bottom, false);
            try drawCardBody(dib.dc, allocator, node, bounds, zoom, .interior, false, false);
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
    try drawCardBody(dib.dc, allocator, node, bounds, 1, .interior, false, false);
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
    try drawCardBody(dib.dc, allocator, node, bounds, 1, .interior, false, false);
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
        const state = CanvasState{ .zoom = zoom };
        fill(dib.dc, rect(0, 0, 1200, 500), 0);
        for (nodes, 0..) |node, index| drawNode(dib.dc, allocator, node, index, null, &nodes, &.{}, &inspection, &.{}, &.{}, &state);
        const attention = attentionActionBounds(nodeBounds(0, &state), &state);
        const offer = reclaimOfferBounds(nodeBounds(1, &state));
        try std.testing.expect(c.GdiFlush() != 0);
        try std.testing.expect(dib.count(attention, 0x000A9FFF) > 0);
        try std.testing.expect(dib.count(offer.reclaim, 0x003A3A44) > 0);
        try std.testing.expectEqual(@as(?usize, 0), hitTestAttentionAction(&nodes, &.{}, attention.left + 1, attention.top + 1, &state));
        try std.testing.expectEqual(ReclaimAction.reclaim, hitTestReclaimOffer(&nodes, &inspection, &.{}, offer.reclaim.left + 1, offer.reclaim.top + 1, &state).?.action);
        for (0..2) |index| {
            const meta = cardTextLayout(nodeBounds(index, &state), zoom, scaledValue(80, zoom)).meta;
            try std.testing.expectEqual(@as(usize, 0), dib.count(meta, 0x000A9FFF));
            try std.testing.expectEqual(@as(usize, 0), dib.count(meta, 0x003A3A44));
        }
    }
}

test "minimum zoom keeps compact rows separated inside a 96 point card" {
    const bounds = nodeBounds(0, &.{ .zoom = 0.55 });
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
    try std.testing.expectEqualStrings("oldest 0m: Loop", attentionAgeLabel(&buffer, node));
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
    try std.testing.expectEqual(AttentionAction.reply, attentionActionForNode(awaiting));
    try std.testing.expectEqualStrings("Reply", attentionActionLabel(awaiting));
    try std.testing.expectEqual(AttentionAction.inspect, attentionActionForNode(failed));
    try std.testing.expectEqualStrings("Inspect", attentionActionLabel(failed));
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
