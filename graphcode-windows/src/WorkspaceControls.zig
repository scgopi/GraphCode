const std = @import("std");
const Tokens = @import("DesignTokens.zig");

pub const Action = enum {
    show_graph,
    toggle_rail,
    toggle_panel,
    toggle_activity,
    increase_activity_limit,
    decrease_activity_limit,
};

pub const State = struct {
    graph_visible: bool = true,
    rail_visible: bool = true,
    panel_visible: bool = true,
    activity_enabled: bool = true,
    activity_limit: usize = 32,

    pub fn apply(self: *State, action: Action) void {
        switch (action) {
            .show_graph => self.graph_visible = true,
            .toggle_rail => self.rail_visible = !self.rail_visible,
            .toggle_panel => self.panel_visible = !self.panel_visible,
            .toggle_activity => self.activity_enabled = !self.activity_enabled,
            .increase_activity_limit => self.activity_limit = @min(self.activity_limit + 8, 256),
            .decrease_activity_limit => self.activity_limit = @max(self.activity_limit -| 8, 8),
        }
    }
};

pub const min_detail_width: i32 = 452;
pub const RailMode = enum { hidden, overlay, docked };

pub const RailPresentation = struct {
    mode: RailMode,
    content_left: i32,
    rail_right: i32,
};

pub fn railPresentation(client_width: i32, state: State) RailPresentation {
    if (!state.rail_visible) return .{ .mode = .hidden, .content_left = 0, .rail_right = 0 };
    if (client_width < Tokens.sidebar_width + min_detail_width) {
        return .{ .mode = .overlay, .content_left = 0, .rail_right = Tokens.sidebar_width };
    }
    return .{
        .mode = .docked,
        .content_left = Tokens.sidebar_width,
        .rail_right = Tokens.sidebar_width,
    };
}

test "workspace controls keep graph rail panel and activity state independent" {
    var state = State{};
    state.apply(.toggle_rail);
    state.apply(.toggle_panel);
    state.apply(.toggle_activity);
    try std.testing.expect(!state.rail_visible);
    try std.testing.expect(!state.panel_visible);
    try std.testing.expect(!state.activity_enabled);
    try std.testing.expect(state.graph_visible);
    state.apply(.decrease_activity_limit);
    try std.testing.expectEqual(@as(usize, 24), state.activity_limit);
}

test "responsive sidebar presentation changes at the minimum detail width" {
    const overlay = [_]i32{ 451, 452, 671 };
    for (overlay) |width| {
        const presentation = railPresentation(width, .{});
        try std.testing.expectEqual(RailMode.overlay, presentation.mode);
        try std.testing.expectEqual(@as(i32, 0), presentation.content_left);
        try std.testing.expectEqual(Tokens.sidebar_width, presentation.rail_right);
    }
    const docked = railPresentation(672, .{});
    try std.testing.expectEqual(RailMode.docked, docked.mode);
    try std.testing.expectEqual(Tokens.sidebar_width, docked.content_left);
    try std.testing.expectEqual(Tokens.sidebar_width, docked.rail_right);
}

test "responsive sidebar presentation hides the rail without reserving content" {
    for ([_]i32{ 451, 452, 671, 672 }) |width| {
        const presentation = railPresentation(width, .{ .rail_visible = false });
        try std.testing.expectEqual(RailMode.hidden, presentation.mode);
        try std.testing.expectEqual(@as(i32, 0), presentation.content_left);
        try std.testing.expectEqual(@as(i32, 0), presentation.rail_right);
    }
}
