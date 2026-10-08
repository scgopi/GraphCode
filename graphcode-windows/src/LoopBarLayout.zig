const std = @import("std");
const Tokens = @import("DesignTokens.zig");

// Logical-pixel geometry of the 46px workspace loop bar. Painting, mouse hit-testing,
// and UIA bounds all read these rects so the drawn buttons and their actionable areas
// cannot drift apart.

pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }

    pub fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.left and x < self.right and y >= self.top and y < self.bottom;
    }

    pub fn intersects(self: Rect, other: Rect) bool {
        return self.left < other.right and other.left < self.right and self.top < other.bottom and other.top < self.bottom;
    }
};

pub const Action = enum { stop, show_graph };

// Every text run in the bar is drawn into a fixed 220px-wide rect when it has room.
pub const natural_text_width: i32 = 220;
// Clearance kept between the last text pixel and the leftmost button.
pub const button_gap: i32 = 8;
// Narrower than this a run would show little more than an ellipsis, so it is dropped.
pub const min_text_width: i32 = 24;
// The collapsed loop detail panel's "Loop panel" expand control, the bar's trailing button.
pub const panel_toggle_width: i32 = 90;
const trailing_inset: i32 = 12;
const show_graph_width: i32 = 92;
const stop_width: i32 = 84;

/// Where the collapsed loop panel's expand control sits in a bar ending at `right`.
pub fn panelToggleRect(top: i32, right: i32) Rect {
    return .{ .left = right - trailing_inset - panel_toggle_width, .top = top + 10, .right = right - trailing_inset, .bottom = top + 36 };
}

pub const Layout = struct {
    bar: Rect,
    stripe: ?Rect,
    title: ?Rect,
    state: ?Rect,
    activity: ?Rect,
    detail: ?Rect,
    stop: ?Rect,
    show_graph: Rect,
    // Present when the loop detail panel is collapsed: its expand control owns the
    // bar's trailing slot, so Show in graph and Stop move left of it.
    panel_toggle: ?Rect,

    // Buttons accept clicks across the bar's full height, using their drawn columns.
    pub fn actionAt(self: Layout, x: i32, y: i32) ?Action {
        if (!self.bar.contains(x, y)) return null;
        if (x >= self.show_graph.left and x < self.show_graph.right) return .show_graph;
        if (self.stop) |stop| if (x >= stop.left and x < stop.right) return .stop;
        return null;
    }
};

fn textRect(x: i32, y: i32, size: i32, limit: i32) ?Rect {
    const right = @min(x + natural_text_width, limit);
    if (right - x < min_text_width) return null;
    return .{ .left = x, .top = y, .right = right, .bottom = y + size + 8 };
}

pub fn compute(left: i32, top: i32, right: i32, resolved: bool, panel_toggle: bool) Layout {
    const toggle: ?Rect = if (panel_toggle) panelToggleRect(top, right) else null;
    const show_graph_right = if (toggle) |value| value.left - button_gap else right - trailing_inset;
    const show_graph = Rect{ .left = show_graph_right - show_graph_width, .top = top + 10, .right = show_graph_right, .bottom = top + 36 };
    const stop_right = show_graph.left - button_gap;
    const stop: ?Rect = if (resolved) null else .{ .left = stop_right - stop_width, .top = top + 10, .right = stop_right, .bottom = top + 36 };
    const limit = (if (stop) |value| value.left else show_graph.left) - button_gap;
    const stripe = Rect{ .left = left + 14, .top = top + 11, .right = left + 18, .bottom = top + 35 };
    return .{
        .bar = .{ .left = left, .top = top, .right = right, .bottom = top + Tokens.loop_bar_height },
        .stripe = if (stripe.right <= limit) stripe else null,
        .title = textRect(left + 27, top + 5, 13, limit),
        .state = textRect(left + 190, top + 8, 10, limit),
        .activity = textRect(left + 27, top + 24, 10, limit),
        .detail = textRect(left + 260, top + 10, 9, limit),
        .stop = stop,
        .show_graph = show_graph,
        .panel_toggle = toggle,
    };
}

fn expectClearOfButtons(layout: Layout) !void {
    const runs = [_]?Rect{ layout.stripe, layout.title, layout.state, layout.activity, layout.detail };
    for (runs) |maybe_run| {
        const run = maybe_run orelse continue;
        try std.testing.expect(run.width() > 0);
        try std.testing.expect(run.left >= layout.bar.left);
        try std.testing.expect(!run.intersects(layout.show_graph));
        if (layout.stop) |stop| try std.testing.expect(!run.intersects(stop));
        if (layout.panel_toggle) |toggle| try std.testing.expect(!run.intersects(toggle));
    }
    if (layout.panel_toggle) |toggle| {
        try std.testing.expect(!toggle.intersects(layout.show_graph));
        if (layout.stop) |stop| try std.testing.expect(!toggle.intersects(stop));
        try std.testing.expect(toggle.right <= layout.bar.right);
    }
    if (layout.stop) |stop| try std.testing.expect(!stop.intersects(layout.show_graph));
}

test "collapsed loop panel's expand control takes the bar's trailing slot and pushes Show in graph and Stop left" {
    const top = Tokens.header_height;
    for ([_]i32{ 1280, 1200, 960 }) |width| {
        for ([_]bool{ false, true }) |resolved| {
            const left = Tokens.sidebar_width;
            const layout = compute(left, top, width, resolved, true);
            try expectClearOfButtons(layout);
            const toggle = layout.panel_toggle.?;
            try std.testing.expectEqual(panelToggleRect(top, width), toggle);
            try std.testing.expectEqual(Rect{ .left = width - 102, .top = top + 10, .right = width - 12, .bottom = top + 36 }, toggle);
            try std.testing.expectEqual(toggle.left - button_gap, layout.show_graph.right);
            try std.testing.expectEqual(@as(i32, 92), layout.show_graph.width());
            if (layout.stop) |stop| try std.testing.expectEqual(layout.show_graph.left - button_gap, stop.right);
            // The expand control's column is never a Stop or Show in graph hit.
            try std.testing.expect(layout.actionAt(toggle.left + 4, top + 20) == null);
            try std.testing.expect(layout.actionAt(toggle.right - 1, top + 20) == null);
            try std.testing.expectEqual(Action.show_graph, layout.actionAt(layout.show_graph.left + 4, top + 20).?);
        }
    }
}

test "expanded loop panel leaves the bar without a trailing toggle slot" {
    const layout = compute(Tokens.sidebar_width, Tokens.header_height, 960 - Tokens.loop_detail_width, false, false);
    try std.testing.expect(layout.panel_toggle == null);
}

test "loop bar metadata stays clear of Stop and Show in graph at 960px with rail and detail panel" {
    // beta10 Dev Box qualification: 960px shell, 220px sidebar rail, 272px loop detail panel.
    const left = Tokens.sidebar_width;
    const right = 960 - Tokens.loop_detail_width;
    const layout = compute(left, Tokens.header_height, right, false, false);
    try expectClearOfButtons(layout);
    // Only 4px remain between the metadata origin and Stop, so the run is dropped.
    try std.testing.expect(layout.detail == null);
    try std.testing.expect(layout.title != null and layout.state != null and layout.activity != null);
}

test "loop bar ellipsizes metadata into the space left of Stop at 1056px with rail and detail panel" {
    const left = Tokens.sidebar_width;
    const right = 1056 - Tokens.loop_detail_width;
    const layout = compute(left, Tokens.header_height, right, false, false);
    try expectClearOfButtons(layout);
    const detail = layout.detail.?;
    try std.testing.expectEqual(left + 260, detail.left);
    try std.testing.expectEqual(layout.stop.?.left - button_gap, detail.right);
    try std.testing.expect(detail.width() < natural_text_width);
}

test "loop bar keeps the wide 1280px geometry unchanged" {
    const left = Tokens.sidebar_width;
    const right = 1280 - Tokens.loop_detail_width;
    const top = Tokens.header_height;
    const layout = compute(left, top, right, false, false);
    try expectClearOfButtons(layout);
    try std.testing.expectEqual(Rect{ .left = left + 14, .top = top + 11, .right = left + 18, .bottom = top + 35 }, layout.stripe.?);
    try std.testing.expectEqual(Rect{ .left = left + 27, .top = top + 5, .right = left + 247, .bottom = top + 26 }, layout.title.?);
    try std.testing.expectEqual(Rect{ .left = left + 190, .top = top + 8, .right = left + 410, .bottom = top + 26 }, layout.state.?);
    try std.testing.expectEqual(Rect{ .left = left + 27, .top = top + 24, .right = left + 247, .bottom = top + 42 }, layout.activity.?);
    try std.testing.expectEqual(Rect{ .left = left + 260, .top = top + 10, .right = left + 480, .bottom = top + 27 }, layout.detail.?);
    try std.testing.expectEqual(Rect{ .left = right - 196, .top = top + 10, .right = right - 112, .bottom = top + 36 }, layout.stop.?);
    try std.testing.expectEqual(Rect{ .left = right - 104, .top = top + 10, .right = right - 12, .bottom = top + 36 }, layout.show_graph);
}

test "loop bar drops text that cannot fit beside the buttons on an extremely narrow bar" {
    const left = Tokens.sidebar_width;
    const right = left + 240;
    const layout = compute(left, Tokens.header_height, right, false, false);
    try expectClearOfButtons(layout);
    try std.testing.expect(layout.title == null and layout.state == null and layout.activity == null and layout.detail == null);
    try std.testing.expectEqual(right - 12, layout.show_graph.right);
    const sliver = compute(left, Tokens.header_height, left + 100, false, false);
    try expectClearOfButtons(sliver);
    try std.testing.expect(sliver.stripe == null);
}

test "loop bar text reclaims the Stop slot once the loop is resolved" {
    const left = Tokens.sidebar_width;
    const right = 960 - Tokens.loop_detail_width;
    const resolved = compute(left, Tokens.header_height, right, true, false);
    try std.testing.expect(resolved.stop == null);
    try expectClearOfButtons(resolved);
    try std.testing.expectEqual(resolved.show_graph.left - button_gap, resolved.detail.?.right);
}

test "loop bar actions hit exactly the button rects" {
    const layout = compute(220, 34, 1200, false, false);
    try std.testing.expectEqual(Action.stop, layout.actionAt(1010, 50).?);
    try std.testing.expectEqual(Action.show_graph, layout.actionAt(1120, 50).?);
    try std.testing.expectEqual(Action.show_graph, layout.actionAt(1120, 35).?);
    try std.testing.expect(layout.actionAt(1120, 80) == null);
    try std.testing.expect(layout.actionAt(1120, 90) == null);
    try std.testing.expect(layout.actionAt(layout.stop.?.right, 50) == null);
    try std.testing.expect(compute(220, 34, 1200, true, false).actionAt(1010, 50) == null);
}
