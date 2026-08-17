const std = @import("std");

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
