const std = @import("std");

pub const Action = enum {
    none,
    reconnect,
    open_folder,
    create_node,
    open_node,
    stop_node,
    send_node,
    edit_node,
    rename_selected,
    delete_selected,
    create_edge,
    jump_next,
    settings,
    product_settings,
    clone_repository,
    cancel_clone,
    remote_repository,
    onboarding,
    cycle_attention,
    inspect_worktrees,
    reclaim_worktrees,
    reveal_worktree,
    edit_worktree_policy,
    save_worktree_policy,
    worktree_next,
    worktree_previous,
    focus_terminal_a,
    focus_terminal_b,
    select_next,
    select_previous,
    new_tab,
    close_tab,
    split_horizontal,
    split_vertical,
    focus_next_pane,
    focus_previous_pane,
    select_previous_tab,
    select_next_tab,
};

pub fn keyAction(key: usize, ctrl: bool, shift: bool) Action {
    if (ctrl and shift and key == ',') return .product_settings;
    if (ctrl and shift and key == 'C') return .clone_repository;
    if (ctrl and shift and key == 'X') return .cancel_clone;
    if (ctrl and shift and key == 'R') return .remote_repository;
    if (ctrl and key == 'R') return .reconnect;
    if (ctrl and key == 'N') return .create_node;
    if (ctrl and key == 'O') return .open_folder;
    if (ctrl and shift and key == 'I') return .inspect_worktrees;
    if (ctrl and shift and key == 'S') return .save_worktree_policy;
    if (ctrl and shift and key == 'P') return .edit_worktree_policy;
    if (ctrl and key == 'S') return .stop_node;
    if (ctrl and key == 'M') return .send_node;
    if (ctrl and key == 'E' and shift) return .reveal_worktree;
    if (ctrl and key == 'E') return .edit_node;
    if (!ctrl and key == 0x71) return .rename_selected;
    if (!ctrl and key == 0x2E) return .delete_selected;
    if (ctrl and key == 'J') return .jump_next;
    if (ctrl and key == ',') return .settings;
    if (key == 0x70) return .onboarding;
    if (ctrl and key == 0x09) return .cycle_attention;
    if (ctrl and key == 'W' and shift) return .reclaim_worktrees;
    if (!ctrl and key == 0x28) return .worktree_next;
    if (!ctrl and key == 0x26) return .worktree_previous;
    if (key == 0x31) return .focus_terminal_a;
    if (key == 0x32) return .focus_terminal_b;
    if (key == 0x09 and shift) return .select_previous;
    if (key == 0x09) return .select_next;
    if (ctrl and key == 'D' and shift) return .split_vertical;
    if (ctrl and key == 'D') return .split_horizontal;
    if (ctrl and key == 'W') return .close_tab;
    if (ctrl and key == 'T') return .new_tab;
    if (ctrl and key == 0xDB) return .focus_previous_pane;
    if (ctrl and key == 0xDD) return .focus_next_pane;
    if (ctrl and key == 0x21) return .select_previous_tab;
    if (ctrl and key == 0x22) return .select_next_tab;
    return .none;
}

pub fn commandText(allocator: std.mem.Allocator, action: Action) ![]u8 {
    return switch (action) {
        .open_folder => allocator.dupe(u8, "Open folder"),
        .create_node => allocator.dupe(u8, "Create node"),
        .open_node => allocator.dupe(u8, "Open node"),
        .stop_node => allocator.dupe(u8, "Stop node"),
        .send_node => allocator.dupe(u8, "Send node"),
        .edit_node => allocator.dupe(u8, "Edit node"),
        .rename_selected => allocator.dupe(u8, "Rename selected loop"),
        .delete_selected => allocator.dupe(u8, "Delete selected canvas item"),
        .create_edge => allocator.dupe(u8, "Create edge"),
        .jump_next => allocator.dupe(u8, "Jump to next node"),
        .settings => allocator.dupe(u8, "Settings"),
        .product_settings => allocator.dupe(u8, "Product settings"),
        .clone_repository => allocator.dupe(u8, "Clone HTTPS repository"),
        .cancel_clone => allocator.dupe(u8, "Cancel clone"),
        .remote_repository => allocator.dupe(u8, "Add SSH repository"),
        .onboarding => allocator.dupe(u8, "GraphCode onboarding"),
        .cycle_attention => allocator.dupe(u8, "Review next loop needing you"),
        .inspect_worktrees => allocator.dupe(u8, "Inspect worktrees"),
        .reclaim_worktrees => allocator.dupe(u8, "Reclaim selected worktrees"),
        .reveal_worktree => allocator.dupe(u8, "Reveal selected worktree in Explorer"),
        .edit_worktree_policy => allocator.dupe(u8, "Edit worktree policy"),
        .save_worktree_policy => allocator.dupe(u8, "Save worktree policy"),
        .worktree_next => allocator.dupe(u8, "Select next worktree row"),
        .worktree_previous => allocator.dupe(u8, "Select previous worktree row"),
        .reconnect => allocator.dupe(u8, "Reconnect"),
        .focus_terminal_a => allocator.dupe(u8, "Focus terminal A"),
        .focus_terminal_b => allocator.dupe(u8, "Focus terminal B"),
        .select_next => allocator.dupe(u8, "Select next node"),
        .select_previous => allocator.dupe(u8, "Select previous node"),
        .new_tab => allocator.dupe(u8, "New terminal tab"),
        .close_tab => allocator.dupe(u8, "Close terminal tab"),
        .split_horizontal => allocator.dupe(u8, "Split terminal right"),
        .split_vertical => allocator.dupe(u8, "Split terminal down"),
        .focus_next_pane => allocator.dupe(u8, "Focus next pane"),
        .focus_previous_pane => allocator.dupe(u8, "Focus previous pane"),
        .select_previous_tab => allocator.dupe(u8, "Select previous terminal tab"),
        .select_next_tab => allocator.dupe(u8, "Select next terminal tab"),
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
    try std.testing.expectEqual(Action.select_previous_tab, keyAction(0x21, true, false));
    try std.testing.expectEqual(Action.select_next_tab, keyAction(0x22, true, false));
}

test "attention and worktree shortcuts are distinct from ordinary selection" {
    try std.testing.expectEqual(Action.cycle_attention, keyAction(0x09, true, false));
    try std.testing.expectEqual(Action.close_tab, keyAction('W', true, false));
    try std.testing.expectEqual(Action.inspect_worktrees, keyAction('W', true, true));
    try std.testing.expectEqual(Action.select_next, keyAction(0x09, false, false));
    try std.testing.expectEqual(Action.select_previous, keyAction(0x09, false, true));
}

test "OEM comma routes to settings only with control" {
    try std.testing.expectEqual(Action.settings, keyAction(0xBC, true, false));
    try std.testing.expectEqual(Action.none, keyAction(0xBC, false, false));
}

test "tab variants keep terminal navigation distinct" {
    try std.testing.expectEqual(Action.select_next, keyAction(0x09, false, false));
    try std.testing.expectEqual(Action.select_previous, keyAction(0x09, false, true));
    try std.testing.expectEqual(Action.cycle_attention, keyAction(0x09, true, false));
}

test "canvas destructive and rename keyboard equivalents are explicit" {
    try std.testing.expectEqual(Action.delete_selected, keyAction(0x2E, false, false));
    try std.testing.expectEqual(Action.rename_selected, keyAction(0x71, false, false));
}

test "modifier-specific actions win over base shortcuts" {
    try std.testing.expectEqual(Action.product_settings, keyAction(',', true, true));
    try std.testing.expectEqual(Action.remote_repository, keyAction('R', true, true));
    try std.testing.expectEqual(Action.clone_repository, keyAction('C', true, true));
    try std.testing.expectEqual(Action.reconnect, keyAction('R', true, false));
    try std.testing.expectEqual(Action.edit_worktree_policy, keyAction('P', true, true));
    try std.testing.expectEqual(Action.save_worktree_policy, keyAction('S', true, true));
    try std.testing.expectEqual(Action.inspect_worktrees, keyAction('I', true, true));
}
