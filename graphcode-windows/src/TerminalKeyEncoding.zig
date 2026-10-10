//! Translates a Windows key press into the bytes a terminal program expects, using the
//! pinned Ghostty key encoder so cursor-key application mode, modifier parameters, and
//! function keys match what the macOS terminal sends. Presses and auto-repeats only:
//! releases, application keypad mode, and Kitty-protocol event reporting are not handled.
//!
//! Keys that produce text (letters, digits, punctuation, dead keys, AltGr, IME) are not
//! encoded here: Windows turns them into WM_CHAR and the surface forwards that text.

const std = @import("std");
const TerminalVt = @import("TerminalVt.zig");
const TerminalKeys = @import("TerminalKeys.zig");
const c = TerminalVt.c;

pub const Action = enum { press, repeat };

pub const Event = struct {
    vk: u32,
    action: Action = .press,
    mods: TerminalKeys.Modifiers = .{},
    /// The key's extended-key flag (bit 24 of the WM_KEYDOWN lparam).
    extended: bool = false,
    /// What the key types with Alt held down, for Alt chords on printable keys.
    text: []const u8 = "",
};

pub const max_sequence_bytes = 64;

pub const Outcome = union(enum) {
    /// The shell does not encode this key; Windows' own WM_CHAR carries it, if it has one.
    not_encoded,
    encoded: []const u8,
};

const vk_back = 0x08;
const vk_tab = 0x09;
const vk_return = 0x0D;
const vk_escape = 0x1B;
const vk_space = 0x20;
const vk_prior = 0x21;
const vk_next = 0x22;
const vk_end = 0x23;
const vk_home = 0x24;
const vk_left = 0x25;
const vk_up = 0x26;
const vk_right = 0x27;
const vk_down = 0x28;
const vk_insert = 0x2D;
const vk_delete = 0x2E;
const vk_f1 = 0x70;
const vk_f24 = 0x87;

fn keyOffset(base: c.GhosttyKey, delta: u32) c.GhosttyKey {
    return base + @as(c.GhosttyKey, @intCast(delta));
}

fn namedKey(vk: u32, extended: bool) ?c.GhosttyKey {
    return switch (vk) {
        vk_back => c.GHOSTTY_KEY_BACKSPACE,
        vk_tab => c.GHOSTTY_KEY_TAB,
        vk_return => if (extended) c.GHOSTTY_KEY_NUMPAD_ENTER else c.GHOSTTY_KEY_ENTER,
        vk_escape => c.GHOSTTY_KEY_ESCAPE,
        vk_space => c.GHOSTTY_KEY_SPACE,
        vk_prior => c.GHOSTTY_KEY_PAGE_UP,
        vk_next => c.GHOSTTY_KEY_PAGE_DOWN,
        vk_end => c.GHOSTTY_KEY_END,
        vk_home => c.GHOSTTY_KEY_HOME,
        vk_left => c.GHOSTTY_KEY_ARROW_LEFT,
        vk_up => c.GHOSTTY_KEY_ARROW_UP,
        vk_right => c.GHOSTTY_KEY_ARROW_RIGHT,
        vk_down => c.GHOSTTY_KEY_ARROW_DOWN,
        vk_insert => c.GHOSTTY_KEY_INSERT,
        vk_delete => c.GHOSTTY_KEY_DELETE,
        vk_f1...vk_f24 => keyOffset(c.GHOSTTY_KEY_F1, vk - vk_f1),
        else => null,
    };
}

/// The physical key behind a printable VK, for Alt chords. Letters and digits only map
/// from the VK itself; punctuation keys are identified by the text they type.
fn printableKey(vk: u32) c.GhosttyKey {
    return switch (vk) {
        'A'...'Z' => keyOffset(c.GHOSTTY_KEY_A, vk - 'A'),
        '0' => c.GHOSTTY_KEY_DIGIT_0,
        '1'...'9' => keyOffset(c.GHOSTTY_KEY_DIGIT_1, vk - '1'),
        else => c.GHOSTTY_KEY_UNIDENTIFIED,
    };
}

fn lowerFirstCodepoint(text: []const u8) u32 {
    if (text.len == 0) return 0;
    const length = std.unicode.utf8ByteSequenceLength(text[0]) catch return 0;
    if (length > text.len) return 0;
    const codepoint = std.unicode.utf8Decode(text[0..length]) catch return 0;
    return if (codepoint >= 'A' and codepoint <= 'Z') codepoint + 32 else codepoint;
}

fn ghosttyMods(mods: TerminalKeys.Modifiers) c.GhosttyMods {
    var result: c.GhosttyMods = 0;
    if (mods.shift) result |= c.GHOSTTY_MODS_SHIFT;
    if (mods.ctrl) result |= c.GHOSTTY_MODS_CTRL;
    if (mods.alt) result |= c.GHOSTTY_MODS_ALT;
    return result;
}

/// Whether the shell encodes `event` itself instead of leaving it to WM_CHAR.
pub fn encodes(event: Event) bool {
    if (namedKey(event.vk, event.extended) == null) return false;
    // Ctrl+Space types a NUL; plain Space is ordinary text, and Alt+Space belongs to Windows.
    if (event.vk == vk_space) return event.mods.ctrl and !event.mods.alt;
    // Ctrl+Enter is a line feed: Windows already translates it to one.
    if (event.vk == vk_return and event.mods.ctrl and !event.mods.alt) return false;
    return true;
}

/// Whether the shell encodes this Alt chord on a printable key (Alt+B sends ESC b).
/// Ctrl+Alt is AltGr on layouts that have one, so it stays ordinary text.
pub fn encodesAltChord(event: Event) bool {
    return event.mods.alt and !event.mods.ctrl and event.text.len != 0 and
        namedKey(event.vk, event.extended) == null;
}

/// Encodes one key event. `terminal`, when given, lends its current modes to the encoder
/// (`ghostty_key_encoder_setopt_from_terminal`). Only application cursor keys (DECCKM) is
/// exercised by the tests below; Kitty keyboard flags and modifyOtherKeys are whatever the
/// pinned encoder does with them and are not verified here. Key releases never reach this
/// function (`TerminalSurface.onKey` drops them), so Kitty release/event-type reporting is
/// not implemented, and of the keypad keys only the numpad Enter is told apart from its
/// main-keyboard twin. Without a terminal, legacy defaults apply.
pub fn encode(buffer: *[max_sequence_bytes]u8, event: Event, terminal: c.GhosttyTerminal) Outcome {
    const key: c.GhosttyKey = if (encodes(event))
        namedKey(event.vk, event.extended).?
    else if (encodesAltChord(event))
        printableKey(event.vk)
    else
        return .not_encoded;

    var encoder: c.GhosttyKeyEncoder = null;
    if (c.ghostty_key_encoder_new(null, &encoder) != c.GHOSTTY_SUCCESS) return .not_encoded;
    defer c.ghostty_key_encoder_free(encoder);
    if (terminal != null) c.ghostty_key_encoder_setopt_from_terminal(encoder, terminal);
    // Alt sends an ESC prefix, as on the macOS terminal with option-as-alt.
    const alt_prefix = true;
    c.ghostty_key_encoder_setopt(encoder, c.GHOSTTY_KEY_ENCODER_OPT_ALT_ESC_PREFIX, &alt_prefix);

    var key_event: c.GhosttyKeyEvent = null;
    if (c.ghostty_key_event_new(null, &key_event) != c.GHOSTTY_SUCCESS) return .not_encoded;
    defer c.ghostty_key_event_free(key_event);
    c.ghostty_key_event_set_action(key_event, switch (event.action) {
        .press => c.GHOSTTY_KEY_ACTION_PRESS,
        .repeat => c.GHOSTTY_KEY_ACTION_REPEAT,
    });
    c.ghostty_key_event_set_key(key_event, key);
    c.ghostty_key_event_set_mods(key_event, ghosttyMods(event.mods));
    if (event.text.len != 0 and encodesAltChord(event)) {
        c.ghostty_key_event_set_utf8(key_event, event.text.ptr, event.text.len);
        c.ghostty_key_event_set_unshifted_codepoint(key_event, lowerFirstCodepoint(event.text));
    } else if (event.vk == vk_space) {
        c.ghostty_key_event_set_utf8(key_event, " ", 1);
        c.ghostty_key_event_set_unshifted_codepoint(key_event, ' ');
    }

    var written: usize = 0;
    if (c.ghostty_key_encoder_encode(encoder, key_event, buffer, buffer.len, &written) != c.GHOSTTY_SUCCESS)
        return .not_encoded;
    return .{ .encoded = buffer[0..written] };
}

fn expectEncoded(event: Event, terminal: c.GhosttyTerminal, expected: []const u8) !void {
    var buffer: [max_sequence_bytes]u8 = undefined;
    switch (encode(&buffer, event, terminal)) {
        .not_encoded => {
            std.debug.print("vk 0x{x} mods {any}: not encoded, expected {any}\n", .{ event.vk, event.mods, expected });
            return error.TestExpectedEncoding;
        },
        .encoded => |bytes| try std.testing.expectEqualSlices(u8, expected, bytes),
    }
}

fn expectNotEncoded(event: Event) !void {
    var buffer: [max_sequence_bytes]u8 = undefined;
    switch (encode(&buffer, event, null)) {
        .not_encoded => {},
        .encoded => |bytes| {
            std.debug.print("vk 0x{x} mods {any}: unexpectedly encoded as {any}\n", .{ event.vk, event.mods, bytes });
            return error.TestUnexpectedEncoding;
        },
    }
}

const shift = TerminalKeys.Modifiers{ .shift = true };
const ctrl = TerminalKeys.Modifiers{ .ctrl = true };
const alt = TerminalKeys.Modifiers{ .alt = true };

test "key table: editing and control keys in the default terminal mode" {
    const cases = [_]struct { event: Event, expected: []const u8 }{
        .{ .event = .{ .vk = vk_return }, .expected = "\r" },
        .{ .event = .{ .vk = vk_return, .extended = true }, .expected = "\r" },
        .{ .event = .{ .vk = vk_tab }, .expected = "\t" },
        .{ .event = .{ .vk = vk_tab, .mods = shift }, .expected = "\x1b[Z" },
        .{ .event = .{ .vk = vk_back }, .expected = "\x7f" },
        .{ .event = .{ .vk = vk_back, .mods = ctrl }, .expected = "\x08" },
        .{ .event = .{ .vk = vk_back, .mods = alt }, .expected = "\x1b\x7f" },
        .{ .event = .{ .vk = vk_escape }, .expected = "\x1b" },
        .{ .event = .{ .vk = vk_insert }, .expected = "\x1b[2~" },
        .{ .event = .{ .vk = vk_delete }, .expected = "\x1b[3~" },
        .{ .event = .{ .vk = vk_delete, .mods = ctrl }, .expected = "\x1b[3;5~" },
        .{ .event = .{ .vk = vk_prior }, .expected = "\x1b[5~" },
        .{ .event = .{ .vk = vk_next }, .expected = "\x1b[6~" },
        .{ .event = .{ .vk = vk_home }, .expected = "\x1b[H" },
        .{ .event = .{ .vk = vk_end }, .expected = "\x1b[F" },
        .{ .event = .{ .vk = vk_space, .mods = ctrl }, .expected = "\x00" },
        .{ .event = .{ .vk = vk_return, .mods = alt }, .expected = "\x1b\r" },
    };
    for (cases) |case| try expectEncoded(case.event, null, case.expected);
}

test "key table: cursor keys and their modifier parameters" {
    const cases = [_]struct { event: Event, expected: []const u8 }{
        .{ .event = .{ .vk = vk_up }, .expected = "\x1b[A" },
        .{ .event = .{ .vk = vk_down }, .expected = "\x1b[B" },
        .{ .event = .{ .vk = vk_right }, .expected = "\x1b[C" },
        .{ .event = .{ .vk = vk_left }, .expected = "\x1b[D" },
        .{ .event = .{ .vk = vk_right, .mods = shift }, .expected = "\x1b[1;2C" },
        .{ .event = .{ .vk = vk_left, .mods = alt }, .expected = "\x1b[1;3D" },
        .{ .event = .{ .vk = vk_left, .mods = ctrl }, .expected = "\x1b[1;5D" },
        .{ .event = .{ .vk = vk_right, .mods = .{ .ctrl = true, .shift = true } }, .expected = "\x1b[1;6C" },
        .{ .event = .{ .vk = vk_up, .action = .repeat }, .expected = "\x1b[A" },
    };
    for (cases) |case| try expectEncoded(case.event, null, case.expected);
}

test "key table: function keys" {
    const cases = [_]struct { index: u32, expected: []const u8 }{
        .{ .index = 0, .expected = "\x1bOP" },
        .{ .index = 1, .expected = "\x1bOQ" },
        .{ .index = 2, .expected = "\x1bOR" },
        .{ .index = 3, .expected = "\x1bOS" },
        .{ .index = 4, .expected = "\x1b[15~" },
        .{ .index = 5, .expected = "\x1b[17~" },
        .{ .index = 6, .expected = "\x1b[18~" },
        .{ .index = 7, .expected = "\x1b[19~" },
        .{ .index = 8, .expected = "\x1b[20~" },
        .{ .index = 9, .expected = "\x1b[21~" },
        .{ .index = 10, .expected = "\x1b[23~" },
        .{ .index = 11, .expected = "\x1b[24~" },
    };
    for (cases) |case| try expectEncoded(.{ .vk = vk_f1 + case.index }, null, case.expected);
    try expectEncoded(.{ .vk = vk_f1 + 4, .mods = shift }, null, "\x1b[15;2~");
}

test "key table: application cursor keys mode changes only the unmodified cursor and home/end keys" {
    const state = try TerminalVt.State.create(std.testing.allocator, 20, 3);
    defer state.destroy();
    try expectEncoded(.{ .vk = vk_up }, state.terminal, "\x1b[A");
    try state.feed("\x1b[?1h");
    try expectEncoded(.{ .vk = vk_up }, state.terminal, "\x1bOA");
    try expectEncoded(.{ .vk = vk_down }, state.terminal, "\x1bOB");
    try expectEncoded(.{ .vk = vk_right }, state.terminal, "\x1bOC");
    try expectEncoded(.{ .vk = vk_left }, state.terminal, "\x1bOD");
    try expectEncoded(.{ .vk = vk_home }, state.terminal, "\x1bOH");
    try expectEncoded(.{ .vk = vk_end }, state.terminal, "\x1bOF");
    try expectEncoded(.{ .vk = vk_left, .mods = ctrl }, state.terminal, "\x1b[1;5D");
    try expectEncoded(.{ .vk = vk_delete }, state.terminal, "\x1b[3~");
    try state.feed("\x1b[?1l");
    try expectEncoded(.{ .vk = vk_up }, state.terminal, "\x1b[A");
}

test "key table: Alt chords on printable keys send an ESC prefix" {
    const cases = [_]struct { event: Event, expected: []const u8 }{
        .{ .event = .{ .vk = 'B', .mods = alt, .text = "b" }, .expected = "\x1bb" },
        .{ .event = .{ .vk = 'B', .mods = .{ .alt = true, .shift = true }, .text = "B" }, .expected = "\x1bB" },
        .{ .event = .{ .vk = 'F', .mods = alt, .text = "f" }, .expected = "\x1bf" },
        .{ .event = .{ .vk = '1', .mods = alt, .text = "1" }, .expected = "\x1b1" },
        .{ .event = .{ .vk = 0xBE, .mods = alt, .text = "." }, .expected = "\x1b." },
        .{ .event = .{ .vk = '2', .mods = .{ .alt = true, .shift = true }, .text = "@" }, .expected = "\x1b@" },
    };
    for (cases) |case| try expectEncoded(case.event, null, case.expected);
}

test "key table: Ctrl+S, T, D, W and N stay plain control bytes left to WM_CHAR" {
    for ([_]u32{ 'S', 'T', 'D', 'W', 'N' }) |vk| try expectNotEncoded(.{ .vk = vk, .mods = ctrl });
    try expectNotEncoded(.{ .vk = 'S', .mods = .{ .ctrl = true, .shift = true } });
    try expectNotEncoded(.{ .vk = 'S', .mods = .{ .ctrl = true, .alt = true } });
    try expectNotEncoded(.{ .vk = 'S' });
    try expectNotEncoded(.{ .vk = 'S', .mods = alt });
}

test "key table: keys Windows already turns into text are left to WM_CHAR" {
    // Plain and shifted printable keys, Ctrl+letter control codes, AltGr (Ctrl+Alt), plain
    // Space, Alt+Space (the Windows system menu), Ctrl+Enter, and keys with no encoding.
    try expectNotEncoded(.{ .vk = 'A', .text = "a" });
    try expectNotEncoded(.{ .vk = 'A', .mods = shift, .text = "A" });
    try expectNotEncoded(.{ .vk = 'D', .mods = ctrl });
    try expectNotEncoded(.{ .vk = 'Q', .mods = .{ .ctrl = true, .alt = true }, .text = "@" });
    try expectNotEncoded(.{ .vk = vk_space });
    try expectNotEncoded(.{ .vk = vk_space, .mods = alt });
    try expectNotEncoded(.{ .vk = vk_return, .mods = ctrl });
    try expectNotEncoded(.{ .vk = 'B', .mods = alt });
    try expectNotEncoded(.{ .vk = 0x10 });
    try expectNotEncoded(.{ .vk = 0x11 });
    try expectNotEncoded(.{ .vk = 0x14 });
}

