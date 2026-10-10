//! Keyboard policy for the embedded terminal: how the shell reads the provider's
//! key events and which chords it keeps for itself instead of sending to the shell.

const std = @import("std");

/// The pinned Winghostty host fills `winghostty_key_event.modifiers` from
/// `GetKeyState` with the Win32 mouse-key masks (`MK_SHIFT`, `MK_CONTROL`) and
/// `0x80` for Alt (`keyModifiers` in `win32_host.zig`). They are not
/// `GhosttyMods` bits.
pub const provider_shift: u32 = 0x04;
pub const provider_ctrl: u32 = 0x08;
pub const provider_alt: u32 = 0x80;

pub const Modifiers = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
};

pub fn decodeProviderModifiers(mask: u32) Modifiers {
    return .{
        .shift = (mask & provider_shift) != 0,
        .ctrl = (mask & provider_ctrl) != 0,
        .alt = (mask & provider_alt) != 0,
    };
}

pub const vk_insert: u32 = 0x2D;
pub const vk_apps: u32 = 0x5D;
pub const vk_f6: u32 = 0x75;
pub const vk_f10: u32 = 0x79;

/// The Menu key and Shift+F10 open the terminal's context menu, as the right button does.
pub fn opensContextMenu(vk: u32, mods: Modifiers) bool {
    if (vk == vk_apps) return !mods.ctrl and !mods.alt;
    return vk == vk_f10 and mods.shift and !mods.ctrl and !mods.alt;
}

/// Terminal-scoped clipboard commands. Winghostty's Windows defaults use
/// Ctrl+Shift+C/V and Ctrl/Shift+Insert, which leave plain Ctrl+C to the shell
/// as an interrupt; plain Ctrl+C copies only while a selection exists, as in
/// Windows Terminal.
pub const ClipboardCommand = enum { copy, paste };

pub fn clipboardCommand(vk: u32, mods: Modifiers, has_selection: bool) ?ClipboardCommand {
    if (mods.alt) return null;
    if (mods.ctrl and mods.shift) return switch (vk) {
        'C' => .copy,
        'V' => .paste,
        else => null,
    };
    if (mods.ctrl) return switch (vk) {
        vk_insert => .copy,
        'C' => if (has_selection) .copy else null,
        else => null,
    };
    if (mods.shift and vk == vk_insert) return .paste;
    return null;
}

/// What the shell does with a chord typed while a terminal has keyboard focus.
pub const Route = enum {
    /// Normal shell handling: menu accelerators and shortcuts apply.
    default,
    /// The key belongs to the program in the terminal; no accelerator may take it.
    terminal,
    /// Ctrl+Shift+W closes the terminal tab (Worktrees owns it outside a terminal).
    close_tab,
    /// Alt+F4: the terminal window swallows system keys, so the shell closes the window.
    system_close,
    /// Alt+Space: the shell opens the window menu instead of typing a space.
    system_menu,
    /// Ctrl+Shift+F10: the shell enters the menu bar, as a bare F10 or Alt tap does elsewhere.
    menu_bar,
};

const vk_f4: u32 = 0x73;
const vk_space: u32 = 0x20;
const vk_oem_4: u32 = 0xDB;
const vk_oem_6: u32 = 0xDD;

/// Terminal-focused keys win: plain Ctrl+D (EOF), Ctrl+W (delete word), Ctrl+S (XOFF and
/// forward search), Ctrl+T (transpose), Ctrl+N (next history), and Ctrl+[ / Ctrl+] (ESC, GS)
/// belong to the program in the terminal, as do F6 and F10 (with or without Shift: Shift+F10
/// is the context menu, decided in the terminal). Their shell commands keep the same keys
/// elsewhere and have terminal-safe alternatives: Ctrl+Shift+T, Ctrl+Shift+N, Alt+Shift+D,
/// Ctrl+Shift+W, Ctrl+Shift+[ / ], Ctrl+Shift+F6 (window toolbar, handled as a header key),
/// and Ctrl+Shift+F10 (menu bar).
pub fn routeChord(vk: u32, mods: Modifiers) Route {
    if (mods.alt and !mods.ctrl and !mods.shift) {
        if (vk == vk_f4) return .system_close;
        if (vk == vk_space) return .system_menu;
    }
    if (mods.ctrl and mods.shift and !mods.alt) {
        if (vk == 'W') return .close_tab;
        if (vk == vk_f10) return .menu_bar;
    }
    if (!mods.ctrl and !mods.alt and (vk == vk_f6 or vk == vk_f10)) return .terminal;
    if (mods.ctrl and !mods.shift and !mods.alt) {
        switch (vk) {
            'D', 'W', 'S', 'T', 'N', vk_oem_4, vk_oem_6 => return .terminal,
            else => {},
        }
    }
    return .default;
}

test "terminal-focused Ctrl chords with shell meanings are terminal input" {
    for ([_]u32{ 'D', 'W', 'S', 'T', 'N', 0xDB, 0xDD }) |vk| {
        try std.testing.expectEqual(Route.terminal, routeChord(vk, .{ .ctrl = true }));
        try std.testing.expectEqual(Route.default, routeChord(vk, .{ .ctrl = true, .alt = true }));
    }
}

test "chords that keep their application meaning in a terminal" {
    // Ctrl+J, Ctrl+O, Ctrl+R are not claimed here: J and O stay documented application keys,
    // and R already reached the shell.
    for ([_]u32{ 'J', 'O', 'R', 0x22, 0x21, 0xBC }) |vk| {
        try std.testing.expectEqual(Route.default, routeChord(vk, .{ .ctrl = true }));
    }
    try std.testing.expectEqual(Route.default, routeChord('T', .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqual(Route.default, routeChord('D', .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqual(Route.default, routeChord(0xDB, .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqual(Route.default, routeChord('A', .{}));
}

test "Ctrl+Shift+W closes the terminal tab and Alt+F4 or Alt+Space stay Windows system keys" {
    try std.testing.expectEqual(Route.close_tab, routeChord('W', .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqual(Route.default, routeChord('W', .{ .ctrl = true, .shift = true, .alt = true }));
    try std.testing.expectEqual(Route.system_close, routeChord(0x73, .{ .alt = true }));
    try std.testing.expectEqual(Route.system_menu, routeChord(0x20, .{ .alt = true }));
    try std.testing.expectEqual(Route.default, routeChord(0x73, .{}));
    try std.testing.expectEqual(Route.default, routeChord(0x20, .{}));
    try std.testing.expectEqual(Route.default, routeChord(0x73, .{ .alt = true, .shift = true }));
}

test "F6 and F10 are terminal input, with Shift as well, and no other function key is claimed" {
    for ([_]u32{ vk_f6, vk_f10 }) |vk| {
        try std.testing.expectEqual(Route.terminal, routeChord(vk, .{}));
        try std.testing.expectEqual(Route.terminal, routeChord(vk, .{ .shift = true }));
        try std.testing.expectEqual(Route.default, routeChord(vk, .{ .alt = true }));
        try std.testing.expectEqual(Route.default, routeChord(vk, .{ .ctrl = true }));
    }
    var vk: u32 = 0x70;
    while (vk <= 0x7B) : (vk += 1) {
        if (vk == vk_f6 or vk == vk_f10) continue;
        try std.testing.expectEqual(Route.default, routeChord(vk, .{}));
        try std.testing.expectEqual(Route.default, routeChord(vk, .{ .shift = true }));
    }
}

test "Ctrl+Shift+F10 reaches the menu bar from a terminal and Ctrl+Shift+F6 stays a shell key" {
    try std.testing.expectEqual(Route.menu_bar, routeChord(vk_f10, .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqual(Route.default, routeChord(vk_f10, .{ .ctrl = true, .shift = true, .alt = true }));
    try std.testing.expectEqual(Route.default, routeChord(vk_f6, .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqual(Route.default, routeChord(vk_f10, .{ .ctrl = true }));
}

test "Menu key and Shift+F10 open the terminal context menu" {
    try std.testing.expect(opensContextMenu(vk_apps, .{}));
    try std.testing.expect(opensContextMenu(vk_apps, .{ .shift = true }));
    try std.testing.expect(opensContextMenu(vk_f10, .{ .shift = true }));
    try std.testing.expect(!opensContextMenu(vk_f10, .{}));
    try std.testing.expect(!opensContextMenu(vk_f10, .{ .shift = true, .ctrl = true }));
    try std.testing.expect(!opensContextMenu(vk_apps, .{ .alt = true }));
    try std.testing.expect(!opensContextMenu('A', .{ .shift = true }));
}

test "provider modifier masks decode as Win32 MK bits, not GhosttyMods" {
    try std.testing.expectEqual(Modifiers{}, decodeProviderModifiers(0));
    try std.testing.expectEqual(Modifiers{ .shift = true }, decodeProviderModifiers(0x04));
    try std.testing.expectEqual(Modifiers{ .ctrl = true }, decodeProviderModifiers(0x08));
    try std.testing.expectEqual(Modifiers{ .alt = true }, decodeProviderModifiers(0x80));
    try std.testing.expectEqual(
        Modifiers{ .shift = true, .ctrl = true, .alt = true },
        decodeProviderModifiers(0x8C),
    );
    // GhosttyMods bit values must not be mistaken for modifiers.
    try std.testing.expectEqual(Modifiers{}, decodeProviderModifiers(0x01 | 0x02));
}

test "clipboard chords follow the Winghostty Windows defaults" {
    const ctrl_shift = Modifiers{ .ctrl = true, .shift = true };
    const ctrl = Modifiers{ .ctrl = true };
    const shift = Modifiers{ .shift = true };
    try std.testing.expectEqual(@as(?ClipboardCommand, .copy), clipboardCommand('C', ctrl_shift, false));
    try std.testing.expectEqual(@as(?ClipboardCommand, .paste), clipboardCommand('V', ctrl_shift, false));
    try std.testing.expectEqual(@as(?ClipboardCommand, .copy), clipboardCommand(vk_insert, ctrl, false));
    try std.testing.expectEqual(@as(?ClipboardCommand, .paste), clipboardCommand(vk_insert, shift, false));
}

test "plain Ctrl+C is an interrupt unless a selection exists, and plain Ctrl+V is never paste" {
    const ctrl = Modifiers{ .ctrl = true };
    try std.testing.expectEqual(@as(?ClipboardCommand, null), clipboardCommand('C', ctrl, false));
    try std.testing.expectEqual(@as(?ClipboardCommand, .copy), clipboardCommand('C', ctrl, true));
    try std.testing.expectEqual(@as(?ClipboardCommand, null), clipboardCommand('V', ctrl, false));
    try std.testing.expectEqual(@as(?ClipboardCommand, null), clipboardCommand('V', ctrl, true));
}

test "clipboard chords ignore Alt combinations and unrelated keys" {
    const alt_ctrl_shift = Modifiers{ .ctrl = true, .shift = true, .alt = true };
    try std.testing.expectEqual(@as(?ClipboardCommand, null), clipboardCommand('V', alt_ctrl_shift, false));
    try std.testing.expectEqual(@as(?ClipboardCommand, null), clipboardCommand(vk_insert, .{ .alt = true, .shift = true }, false));
    try std.testing.expectEqual(@as(?ClipboardCommand, null), clipboardCommand('X', .{ .ctrl = true, .shift = true }, true));
    try std.testing.expectEqual(@as(?ClipboardCommand, null), clipboardCommand(vk_insert, .{}, false));
    try std.testing.expectEqual(@as(?ClipboardCommand, null), clipboardCommand('V', .{ .shift = true }, false));
}
