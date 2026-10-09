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
