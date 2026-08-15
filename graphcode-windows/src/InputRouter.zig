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
};

pub fn keyAction(key: usize, ctrl: bool, shift: bool) Action {
    _ = shift;
    if (ctrl and key == 'R') return .reconnect;
    if (ctrl and key == 'N') return .create_node;
    if (ctrl and key == 'O') return .open_node;
    if (ctrl and key == 'S') return .stop_node;
    if (ctrl and key == 'M') return .send_node;
    if (key == 0x31) return .focus_terminal_a;
    if (key == 0x32) return .focus_terminal_b;
    if (key == 0x09) return .select_next;
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
        .none => allocator.dupe(u8, ""),
    };
}
