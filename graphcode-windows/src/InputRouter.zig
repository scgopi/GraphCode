const std = @import("std");

pub const Action = enum {
    none,
    reconnect,
    create_node,
    open_node,
    stop_node,
    send_node,
    focus_terminal_a,
    focus_terminal_b,
    select_next,
    new_tab,
    close_tab,
    split_horizontal,
    split_vertical,
    focus_next_pane,
    focus_previous_pane,
};

pub fn keyAction(key: usize, ctrl: bool, shift: bool) Action {
    if (ctrl and key == 'R') return .reconnect;
    if (ctrl and key == 'N') return .create_node;
    if (ctrl and key == 'O') return .open_node;
    if (ctrl and key == 'S') return .stop_node;
    if (ctrl and key == 'M') return .send_node;
    if (key == 0x31) return .focus_terminal_a;
    if (key == 0x32) return .focus_terminal_b;
    if (key == 0x09) return .select_next;
    if (ctrl and key == 'D' and shift) return .split_vertical;
    if (ctrl and key == 'D') return .split_horizontal;
    if (ctrl and key == 'W') return .close_tab;
    if (ctrl and key == 'T') return .new_tab;
    if (ctrl and key == 0xDB) return .focus_previous_pane;
    if (ctrl and key == 0xDD) return .focus_next_pane;
    return .none;
}

pub fn commandText(allocator: std.mem.Allocator, action: Action) ![]u8 {
    return switch (action) {
        .create_node => allocator.dupe(u8, "Create node"),
        .open_node => allocator.dupe(u8, "Open node"),
        .stop_node => allocator.dupe(u8, "Stop node"),
        .send_node => allocator.dupe(u8, "Send node"),
        .reconnect => allocator.dupe(u8, "Reconnect"),
        .focus_terminal_a => allocator.dupe(u8, "Focus terminal A"),
        .focus_terminal_b => allocator.dupe(u8, "Focus terminal B"),
        .select_next => allocator.dupe(u8, "Select next node"),
        .new_tab => allocator.dupe(u8, "New terminal tab"),
        .close_tab => allocator.dupe(u8, "Close terminal tab"),
        .split_horizontal => allocator.dupe(u8, "Split terminal right"),
        .split_vertical => allocator.dupe(u8, "Split terminal down"),
        .focus_next_pane => allocator.dupe(u8, "Focus next pane"),
        .focus_previous_pane => allocator.dupe(u8, "Focus previous pane"),
        .none => allocator.dupe(u8, ""),
    };
}

test "workspace shortcuts route to tabs splits and panes" {
    try std.testing.expectEqual(Action.new_tab, keyAction('T', true, false));
    try std.testing.expectEqual(Action.close_tab, keyAction('W', true, false));
    try std.testing.expectEqual(Action.split_horizontal, keyAction('D', true, false));
    try std.testing.expectEqual(Action.split_vertical, keyAction('D', true, true));
    try std.testing.expectEqual(Action.focus_previous_pane, keyAction(0xDB, true, false));
    try std.testing.expectEqual(Action.focus_next_pane, keyAction(0xDD, true, false));
}
