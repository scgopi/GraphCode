const c = @import("Win32.zig").c;

pub const Target = union(enum) {
    background,
    node: usize,
    edge: usize,
};

pub const Action = enum {
    none,
    rename_node,
    stop_node,
    delete_node,
    open_terminal,
    message_node,
    memo_node,
    edit_edge,
    delete_edge,
    create_edge,
};

pub const Callback = *const fn (?*anyopaque, Action, Target) callconv(.c) void;

pub fn requiresConfirmation(action: Action) bool {
    return action == .delete_node or action == .delete_edge;
}

pub fn shouldApply(action: Action, confirmed: bool) bool {
    return !requiresConfirmation(action) or confirmed;
}

const ids = struct {
    const rename_node = 5101;
    const stop_node = 5102;
    const delete_node = 5103;
    const open_terminal = 5104;
    const message_node = 5105;
    const memo_node = 5106;
    const edit_edge = 5110;
    const delete_edge = 5111;
    const create_edge = 5120;
};

pub fn show(
    parent: c.HWND,
    target: Target,
    x: i32,
    y: i32,
    context: ?*anyopaque,
    callback: Callback,
) void {
    const menu = c.CreatePopupMenu() orelse return;
    defer _ = c.DestroyMenu(menu);
    switch (target) {
        .background => append(menu, ids.create_edge, "Create Edge"),
        .node => {
            append(menu, ids.open_terminal, "Open Terminal");
            append(menu, ids.message_node, "Message");
            append(menu, ids.memo_node, "Memo");
            append(menu, ids.rename_node, "Rename...");
            append(menu, ids.stop_node, "Stop");
            append(menu, ids.delete_node, "Delete Loop...");
        },
        .edge => {
            append(menu, ids.edit_edge, "Edit Edge...");
            append(menu, ids.delete_edge, "Delete Edge");
        },
    }
    const command = c.TrackPopupMenu(
        menu,
        c.TPM_RETURNCMD | c.TPM_NONOTIFY | c.TPM_RIGHTBUTTON,
        x,
        y,
        0,
        parent,
        null,
    );
    const action = actionForCommand(command);
    if (action != .none) callback(context, action, target);
}

pub fn confirm(parent: c.HWND, title: []const u8, message: []const u8) bool {
    const title_wide = toWide(title) orelse return false;
    defer std.heap.c_allocator.free(title_wide);
    const message_wide = toWide(message) orelse return false;
    defer std.heap.c_allocator.free(message_wide);
    return c.MessageBoxW(parent, message_wide.ptr, title_wide.ptr, c.MB_ICONWARNING | c.MB_YESNO | c.MB_DEFBUTTON2) == c.IDYES;
}

fn actionForCommand(command: c.UINT) Action {
    return switch (command) {
        ids.rename_node => .rename_node,
        ids.stop_node => .stop_node,
        ids.delete_node => .delete_node,
        ids.open_terminal => .open_terminal,
        ids.message_node => .message_node,
        ids.memo_node => .memo_node,
        ids.edit_edge => .edit_edge,
        ids.delete_edge => .delete_edge,
        ids.create_edge => .create_edge,
        else => .none,
    };
}

fn append(menu: c.HMENU, id: usize, text: []const u8) void {
    const wide = toWide(text) orelse return;
    defer std.heap.c_allocator.free(wide);
    _ = c.AppendMenuW(menu, c.MF_STRING, id, wide.ptr);
}

fn toWide(text: []const u8) ?[]u16 {
    const raw = std.unicode.utf8ToUtf16LeAlloc(std.heap.c_allocator, text) catch return null;
    const result = std.heap.c_allocator.alloc(u16, raw.len + 1) catch {
        std.heap.c_allocator.free(raw);
        return null;
    };
    @memcpy(result[0..raw.len], raw);
    result[raw.len] = 0;
    std.heap.c_allocator.free(raw);
    return result;
}

const std = @import("std");

test "context actions remain stable when graph IDs are reordered" {
    try std.testing.expectEqual(Action.rename_node, actionForCommand(ids.rename_node));
    try std.testing.expectEqual(Action.delete_edge, actionForCommand(ids.delete_edge));
    try std.testing.expectEqual(Action.none, actionForCommand(0));
}

test "destructive context actions cannot bypass a cancelled confirmation" {
    try std.testing.expect(!shouldApply(.delete_node, false));
    try std.testing.expect(!shouldApply(.delete_edge, false));
    try std.testing.expect(shouldApply(.rename_node, false));
}
