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
    rail_auto_hidden: bool = false,
    panel_auto_hidden: bool = false,
    priority: enum { rail, panel } = .panel,

    pub fn setPanelVisible(self: *State, visible: bool) void {
        self.panel_visible = visible;
        self.panel_auto_hidden = false;
        if (visible) self.priority = .panel;
    }

    pub fn requestedRailVisible(self: State) bool {
        return self.rail_visible or self.rail_auto_hidden;
    }

    pub fn requestedPanelVisible(self: State) bool {
        return self.panel_visible or self.panel_auto_hidden;
    }

    /// Visibility is transient; requested panels return when the viewport admits them.
    pub fn fitTerminal(self: *State, width: i32, minimum: i32, rail_width: i32, panel_width: i32) bool {
        self.rail_visible = self.requestedRailVisible();
        self.panel_visible = self.requestedPanelVisible();
        self.rail_auto_hidden = false;
        self.panel_auto_hidden = false;
        if (minimum + (if (self.rail_visible) rail_width else @as(i32, 0)) +
            (if (self.panel_visible) panel_width else @as(i32, 0)) <= width) return true;
        if (self.priority == .panel) {
            self.rail_auto_hidden = self.rail_visible;
            self.rail_visible = false;
        } else {
            self.panel_auto_hidden = self.panel_visible;
            self.panel_visible = false;
        }
        if (minimum + (if (self.rail_visible) rail_width else @as(i32, 0)) +
            (if (self.panel_visible) panel_width else @as(i32, 0)) <= width) return true;
        self.rail_auto_hidden = self.rail_auto_hidden or self.rail_visible;
        self.panel_auto_hidden = self.panel_auto_hidden or self.panel_visible;
        self.rail_visible = false;
        self.panel_visible = false;
        return false;
    }

    pub fn restorePanels(self: *State) void {
        self.rail_visible = self.requestedRailVisible();
        self.panel_visible = self.requestedPanelVisible();
        self.rail_auto_hidden = false;
        self.panel_auto_hidden = false;
    }

    pub fn apply(self: *State, action: Action) void {
        switch (action) {
            .show_graph => self.graph_visible = true,
            .toggle_rail => {
                self.rail_visible = !self.rail_visible;
                self.rail_auto_hidden = false;
                if (self.rail_visible) self.priority = .rail;
            },
            .toggle_panel => self.setPanelVisible(!self.panel_visible),
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

test "terminal panel priority restores intent but never explicitly hidden panels" {
    var state = State{};
    try std.testing.expect(state.fitTerminal(1024, 348, 440, 544));
    try std.testing.expect(!state.rail_visible and state.panel_visible);
    state.apply(.toggle_rail);
    try std.testing.expect(state.fitTerminal(1024, 348, 440, 544));
    try std.testing.expect(state.rail_visible and !state.panel_visible);
    state.apply(.toggle_panel);
    try std.testing.expect(state.fitTerminal(1024, 348, 440, 544));
    try std.testing.expect(!state.rail_visible and state.panel_visible);
    try std.testing.expect(state.fitTerminal(1920, 348, 440, 544));
    try std.testing.expect(state.rail_visible and state.panel_visible);
    state.apply(.toggle_panel);
    try std.testing.expect(state.fitTerminal(1024, 348, 440, 544));
    try std.testing.expect(state.rail_visible and !state.panel_visible);
    try std.testing.expect(state.fitTerminal(1920, 348, 440, 544));
    try std.testing.expect(state.rail_visible and !state.panel_visible);
    state.setPanelVisible(true);
    try std.testing.expect(!state.fitTerminal(500, 348, 440, 544));
    try std.testing.expect(!state.rail_visible and !state.panel_visible);
    try std.testing.expect(state.requestedRailVisible() and state.requestedPanelVisible());
    state.restorePanels();
    try std.testing.expect(state.rail_visible and state.panel_visible);
}
