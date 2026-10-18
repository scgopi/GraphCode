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

pub const Action = enum { restart_session, show_graph };
pub const QuickChatAction = enum { restart_session, show_graph };

pub const QuickChatLayout = struct {
    bar: Rect,
    stripe: ?Rect,
    title: ?Rect,
    state: ?Rect,
    subtitle: ?Rect,
    age: ?Rect,
    restart_session: Rect,
    show_graph: Rect,

    pub fn actionAt(self: QuickChatLayout, x: i32, y: i32) ?QuickChatAction {
        if (!self.bar.contains(x, y)) return null;
        if (self.restart_session.contains(x, y)) return .restart_session;
        if (self.show_graph.contains(x, y)) return .show_graph;
        return null;
    }
};

// Maximum width of a live line or progress/spend column before ellipsizing.
pub const natural_text_width: i32 = 220;
// Clearance kept between the last text pixel and the leftmost button.
pub const button_gap: i32 = 8;
// Narrower than this a run would show little more than an ellipsis, so it is dropped.
pub const min_text_width: i32 = 24;
// The collapsed loop detail panel's "Loop panel" expand control, the bar's trailing button.
pub const panel_toggle_width: i32 = 90;
const trailing_inset: i32 = 12;
const show_graph_width: i32 = 92;
const restart_width: i32 = 112;

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
    spend: ?Rect = null,
    divider: ?Rect = null,
    restart_session: ?Rect,
    show_graph: Rect,
    // Present when the loop detail panel is collapsed: its expand control owns the
    // bar's trailing slot, so Show in graph and Restart session move left of it.
    panel_toggle: ?Rect,

    // Buttons accept clicks across the bar's full height, using their drawn columns.
    pub fn actionAt(self: Layout, x: i32, y: i32) ?Action {
        if (!self.bar.contains(x, y)) return null;
        if (x >= self.show_graph.left and x < self.show_graph.right) return .show_graph;
        if (self.restart_session) |restart| if (x >= restart.left and x < restart.right) return .restart_session;
        return null;
    }
};

fn textRect(x: i32, y: i32, size: i32, limit: i32) ?Rect {
    return lineRect(x, y, natural_text_width, size + 8, limit);
}

fn lineRect(x: i32, y: i32, width: i32, height: i32, limit: i32) ?Rect {
    const right = @min(x + width, limit);
    if (right - x < min_text_width) return null;
    return .{ .left = x, .top = y, .right = right, .bottom = y + height };
}

pub fn compute(left: i32, top: i32, right: i32, resolved: bool, panel_toggle: bool) Layout {
    const toggle: ?Rect = if (panel_toggle) panelToggleRect(top, right) else null;
    const show_graph_right = if (toggle) |value| value.left - button_gap else right - trailing_inset;
    const show_graph = Rect{ .left = show_graph_right - show_graph_width, .top = top + 10, .right = show_graph_right, .bottom = top + 36 };
    const restart_right = show_graph.left - button_gap;
    const restart: ?Rect = if (resolved) null else .{ .left = restart_right - restart_width, .top = top + 10, .right = restart_right, .bottom = top + 36 };
    const limit = (if (restart) |value| value.left else show_graph.left) - button_gap;
    const stripe = Rect{ .left = left + 14, .top = top + 11, .right = left + 18, .bottom = top + 35 };
    // LoopWorkspaceLoopBar.swift:40-65 keeps title + state on one line and the
    // live line below; :68-101 separates progress/spend from that identity block.
    const state_left = @min(left + 167, limit - 100);
    const state = if (state_left >= left + 27 + min_text_width + 7)
        lineRect(state_left, top + 6, 100, 17, limit)
    else
        null;
    const visible_state = if (state != null and state.?.width() >= 80) state else null;
    const detail = lineRect(left + 284, top + 6, natural_text_width, 17, limit);
    return .{
        .bar = .{ .left = left, .top = top, .right = right, .bottom = top + Tokens.loop_bar_height },
        .stripe = if (stripe.right <= limit) stripe else null,
        .title = lineRect(left + 27, top + 5, natural_text_width, 17, if (visible_state) |value| value.left - 7 else limit),
        .state = visible_state,
        .activity = lineRect(left + 27, top + 25, natural_text_width, 16, limit),
        .detail = detail,
        .spend = lineRect(left + 284, top + 25, natural_text_width, 16, limit),
        .divider = if (detail != null) .{ .left = left + 275, .top = top + 10, .right = left + 276, .bottom = top + 36 } else null,
        .restart_session = restart,
        .show_graph = show_graph,
        .panel_toggle = toggle,
    };
}

pub fn computeQuickChat(left: i32, top: i32, right: i32) QuickChatLayout {
    const show_graph = Rect{
        .left = right - trailing_inset - show_graph_width,
        .top = top + 10,
        .right = right - trailing_inset,
        .bottom = top + 36,
    };
    const restart_session = Rect{
        .left = show_graph.left - button_gap - 112,
        .top = top + 10,
        .right = show_graph.left - button_gap,
        .bottom = top + 36,
    };
    const text_limit = restart_session.left - button_gap;
    const state_rect = Rect{
        .left = left + 255,
        .top = top + 7,
        .right = left + 303,
        .bottom = top + 27,
    };
    const show_state = state_rect.right <= text_limit;
    return .{
        .bar = .{ .left = left, .top = top, .right = right, .bottom = top + Tokens.loop_bar_height },
        .stripe = if (left + 18 <= text_limit) .{
            .left = left + 14,
            .top = top + 11,
            .right = left + 18,
            .bottom = top + 35,
        } else null,
        .title = textRect(left + 27, top + 5, 13, if (show_state) state_rect.left - button_gap else text_limit),
        .state = if (show_state) state_rect else null,
        .subtitle = textRect(left + 27, top + 24, 10, @min(left + 155, text_limit)),
        .age = textRect(left + 163, top + 24, 10, text_limit),
        .restart_session = restart_session,
        .show_graph = show_graph,
    };
}

fn expectClearOfButtons(layout: Layout) !void {
    const runs = [_]?Rect{ layout.stripe, layout.title, layout.state, layout.activity, layout.detail, layout.spend, layout.divider };
    for (runs) |maybe_run| {
        const run = maybe_run orelse continue;
        try std.testing.expect(run.width() > 0);
        try std.testing.expect(run.left >= layout.bar.left);
        try std.testing.expect(!run.intersects(layout.show_graph));
        if (layout.restart_session) |restart| try std.testing.expect(!run.intersects(restart));
        if (layout.panel_toggle) |toggle| try std.testing.expect(!run.intersects(toggle));
    }
    if (layout.panel_toggle) |toggle| {
        try std.testing.expect(!toggle.intersects(layout.show_graph));
        if (layout.restart_session) |restart| try std.testing.expect(!toggle.intersects(restart));
        try std.testing.expect(toggle.right <= layout.bar.right);
    }
    if (layout.restart_session) |restart| try std.testing.expect(!restart.intersects(layout.show_graph));
}

test "workspace chrome loop bar text runs never overprint one another" {
    for ([_]i32{ 960, 1056, 1280, 1440 }) |width| {
        for ([_]bool{ false, true }) |resolved| {
            for ([_]bool{ false, true }) |panel_toggle| {
                const right = width - if (panel_toggle) @as(i32, 0) else Tokens.loop_detail_width;
                const layout = compute(Tokens.sidebar_width, Tokens.header_height, right, resolved, panel_toggle);
                const runs = [_]?Rect{ layout.title, layout.state, layout.activity, layout.detail, layout.spend, layout.divider };
                for (runs, 0..) |maybe_run, index| {
                    const run = maybe_run orelse continue;
                    for (runs[index + 1 ..]) |maybe_other| {
                        const other = maybe_other orelse continue;
                        try std.testing.expectEqual(false, run.intersects(other));
                    }
                }
                try expectClearOfButtons(layout);
            }
        }
    }
}

test "collapsed loop panel's expand control takes the bar's trailing slot and pushes Show in graph and Restart left" {
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
            if (layout.restart_session) |restart| try std.testing.expectEqual(layout.show_graph.left - button_gap, restart.right);
            // The expand control's column is never a Restart or Show in graph hit.
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

test "loop bar metadata stays clear of Restart and Show in graph at 960px with rail and detail panel" {
    // beta10 Dev Box qualification: 960px shell, 220px sidebar rail, 272px loop detail panel.
    const left = Tokens.sidebar_width;
    const right = 960 - Tokens.loop_detail_width;
    const layout = compute(left, Tokens.header_height, right, false, false);
    try expectClearOfButtons(layout);
    // The progress/spend column does not fit beside the identity and actions.
    try std.testing.expect(layout.detail == null);
    try std.testing.expect(layout.title != null and layout.state != null and layout.activity != null);
}

test "loop bar ellipsizes metadata into the space left of Restart at 1056px with rail and detail panel" {
    const left = Tokens.sidebar_width;
    const right = 1056 - Tokens.loop_detail_width;
    const layout = compute(left, Tokens.header_height, right, false, false);
    try expectClearOfButtons(layout);
    const detail = layout.detail.?;
    try std.testing.expectEqual(left + 284, detail.left);
    try std.testing.expectEqual(layout.restart_session.?.left - button_gap, detail.right);
    try std.testing.expect(detail.width() < natural_text_width);
}

test "loop bar preserves wide action geometry while separating identity and progress text" {
    const left = Tokens.sidebar_width;
    const right = 1280 - Tokens.loop_detail_width;
    const top = Tokens.header_height;
    const layout = compute(left, top, right, false, false);
    try expectClearOfButtons(layout);
    try std.testing.expectEqual(Rect{ .left = left + 14, .top = top + 11, .right = left + 18, .bottom = top + 35 }, layout.stripe.?);
    try std.testing.expectEqual(Rect{ .left = left + 27, .top = top + 5, .right = left + 160, .bottom = top + 22 }, layout.title.?);
    try std.testing.expectEqual(Rect{ .left = left + 167, .top = top + 6, .right = left + 267, .bottom = top + 23 }, layout.state.?);
    try std.testing.expectEqual(Rect{ .left = left + 27, .top = top + 25, .right = left + 247, .bottom = top + 41 }, layout.activity.?);
    try std.testing.expectEqual(Rect{ .left = left + 284, .top = top + 6, .right = left + 504, .bottom = top + 23 }, layout.detail.?);
    try std.testing.expectEqual(Rect{ .left = left + 284, .top = top + 25, .right = left + 504, .bottom = top + 41 }, layout.spend.?);
    try std.testing.expectEqual(Rect{ .left = left + 275, .top = top + 10, .right = left + 276, .bottom = top + 36 }, layout.divider.?);
    try std.testing.expectEqual(Rect{ .left = right - 224, .top = top + 10, .right = right - 112, .bottom = top + 36 }, layout.restart_session.?);
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

test "loop bar text reclaims the Restart slot once the loop is resolved" {
    const left = Tokens.sidebar_width;
    const right = 960 - Tokens.loop_detail_width;
    const resolved = compute(left, Tokens.header_height, right, true, false);
    try std.testing.expect(resolved.restart_session == null);
    try expectClearOfButtons(resolved);
    try std.testing.expectEqual(resolved.show_graph.left - button_gap, resolved.detail.?.right);
}

test "loop bar actions hit exactly the button rects" {
    const layout = compute(220, 34, 1200, false, false);
    try std.testing.expectEqual(Action.restart_session, layout.actionAt(1010, 50).?);
    try std.testing.expectEqual(Action.show_graph, layout.actionAt(1120, 50).?);
    try std.testing.expectEqual(Action.show_graph, layout.actionAt(1120, 35).?);
    try std.testing.expect(layout.actionAt(1120, 80) == null);
    try std.testing.expect(layout.actionAt(1120, 90) == null);
    try std.testing.expect(layout.actionAt(layout.restart_session.?.right, 50) == null);
    try std.testing.expect(compute(220, 34, 1200, true, false).actionAt(1010, 50) == null);
}

test "Quick Chat parity bar geometry has restart and no panel slot" {
    const top = Tokens.header_height;
    for ([_]i32{ 1440, 1200, 960, 480 }) |client_right| {
        for ([_]bool{ false, true }) |sidebar_visible| {
            const left = if (sidebar_visible) Tokens.sidebar_width else 0;
            const layout = computeQuickChat(left, top, client_right);
            try std.testing.expectEqual(left, layout.bar.left);
            try std.testing.expectEqual(client_right, layout.bar.right);
            try std.testing.expect(layout.restart_session.width() >= 112);
            try std.testing.expect(layout.restart_session.left >= left);
            try std.testing.expect(layout.restart_session.right <= client_right);
            try std.testing.expect(layout.show_graph.width() > 0);
            try std.testing.expect(layout.show_graph.left >= left);
            try std.testing.expect(layout.show_graph.right <= client_right);
            try std.testing.expect(!layout.restart_session.intersects(layout.show_graph));
            if (layout.title) |title| {
                try std.testing.expect(title.left >= left);
                try std.testing.expect(title.right <= layout.bar.right);
                if (layout.state) |state| try std.testing.expect(!title.intersects(state));
                try std.testing.expect(!title.intersects(layout.restart_session));
                try std.testing.expect(!title.intersects(layout.show_graph));
            }
            if (layout.state) |state| {
                try std.testing.expect(!state.intersects(layout.restart_session));
                try std.testing.expect(!state.intersects(layout.show_graph));
            }
            if (layout.subtitle) |subtitle| {
                try std.testing.expect(!subtitle.intersects(layout.restart_session));
                try std.testing.expect(!subtitle.intersects(layout.show_graph));
                if (layout.age) |age| try std.testing.expect(!subtitle.intersects(age));
            }
            try std.testing.expectEqual(
                QuickChatAction.restart_session,
                layout.actionAt(layout.restart_session.left + 1, top + 20).?,
            );
            try std.testing.expectEqual(
                QuickChatAction.show_graph,
                layout.actionAt(layout.show_graph.left + 1, top + 20).?,
            );
            try std.testing.expect(layout.actionAt(left -| 1, top + 20) == null);
            try std.testing.expect(layout.actionAt(client_right, top + 20) == null);
            try std.testing.expect(layout.actionAt(layout.restart_session.left - 1, top + 20) == null);
            try std.testing.expect(layout.actionAt(layout.show_graph.left - 1, top + 20) == null);
        }
    }
}
