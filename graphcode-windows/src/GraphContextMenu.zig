const c = @import("Win32.zig").c;

pub const NodeTarget = struct {
    project_path: []const u8,
    id: []const u8,
    composite: bool = false,
    can_arm: bool = false,
    unwired: bool = false,
};

pub const EdgeTarget = struct {
    project_path: []const u8,
    id: []const u8,
};

pub const QuickChatTarget = struct {
    id: []const u8,
};

pub const ProjectTarget = struct {
    path: []const u8,
    remote: bool,
};

pub const Target = union(enum) {
    background,
    quick_chats,
    project: ProjectTarget,
    node: NodeTarget,
    edge: EdgeTarget,
    quick_chat: QuickChatTarget,
};

pub const Action = enum {
    none,
    rename_node,
    stop_node,
    delete_node,
    open_terminal,
    message_node,
    memo_node,
    open_composite,
    pilot_composite,
    arm_composite,
    wire_node,
    mark_entry,
    edit_edge,
    delete_edge,
    create_edge,
    open_quick_chat,
    rename_quick_chat,
    delete_quick_chat,
    open_project,
    new_project_loop,
    inspect_project_worktrees,
    project_settings,
    reveal_project,
    remote_project_info,
    close_project,
    remove_project,
    delete_project_loops,
    new_quick_chat,
};

pub const Callback = *const fn (?*anyopaque, Action, Target) void;

pub fn requiresConfirmation(action: Action) bool {
    return action == .delete_node or action == .delete_edge or action == .delete_quick_chat or
        action == .remove_project or action == .delete_project_loops;
}

pub fn shouldApply(action: Action, confirmed: bool) bool {
    return !requiresConfirmation(action) or confirmed;
}

pub fn canEditEdge(edge_id: []const u8) bool {
    return edge_id.len != 0;
}

const ids = struct {
    const rename_node = 5101;
    const stop_node = 5102;
    const delete_node = 5103;
    const open_terminal = 5104;
    const message_node = 5105;
    const memo_node = 5106;
    const open_composite = 5113;
    const pilot_composite = 5107;
    const arm_composite = 5108;
    const wire_node = 5109;
    const mark_entry = 5112;
    const edit_edge = 5110;
    const delete_edge = 5111;
    const create_edge = 5120;
    const open_quick_chat = 5130;
    const rename_quick_chat = 5131;
    const delete_quick_chat = 5132;
    const open_project = 5140;
    const new_project_loop = 5141;
    const inspect_project_worktrees = 5142;
    const project_settings = 5143;
    const reveal_project = 5144;
    const remote_project_info = 5145;
    const close_project = 5146;
    const remove_project = 5147;
    const delete_project_loops = 5148;
    const new_quick_chat = 5150;
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
        .quick_chats => append(menu, ids.new_quick_chat, "New Chat"),
        .project => |project| {
            append(menu, ids.open_project, "Open Project");
            append(menu, ids.new_project_loop, "New Loop...");
            separator(menu);
            append(menu, ids.inspect_project_worktrees, "Worktrees...");
            append(menu, ids.project_settings, "Project Settings...");
            if (project.remote)
                append(menu, ids.remote_project_info, "Remote Connection Info")
            else
                append(menu, ids.reveal_project, "Show in Explorer");
            separator(menu);
            append(menu, ids.close_project, "Close Project");
            append(menu, ids.remove_project, "Remove from GraphCode...");
            append(menu, ids.delete_project_loops, "Delete All Loops...");
        },
        .node => |node| {
            append(menu, ids.open_terminal, "Open Terminal");
            if (node.unwired) {
                append(menu, ids.wire_node, "Wire it up");
                append(menu, ids.mark_entry, "Mark as entry");
                separator(menu);
            }
            if (node.composite) {
                append(menu, ids.open_composite, "Open Group");
                append(menu, ids.pilot_composite, "Pilot Once");
                appendEnabled(menu, ids.arm_composite, "Arm Schedule", node.can_arm);
                separator(menu);
            }
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
        .quick_chat => {
            append(menu, ids.open_quick_chat, "Open Chat");
            append(menu, ids.rename_quick_chat, "Rename...");
            append(menu, ids.delete_quick_chat, "Delete Chat...");
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

fn actionForCommand(command: c_int) Action {
    return switch (command) {
        ids.rename_node => .rename_node,
        ids.stop_node => .stop_node,
        ids.delete_node => .delete_node,
        ids.open_terminal => .open_terminal,
        ids.message_node => .message_node,
        ids.memo_node => .memo_node,
        ids.open_composite => .open_composite,
        ids.pilot_composite => .pilot_composite,
        ids.arm_composite => .arm_composite,
        ids.wire_node => .wire_node,
        ids.mark_entry => .mark_entry,
        ids.edit_edge => .edit_edge,
        ids.delete_edge => .delete_edge,
        ids.create_edge => .create_edge,
        ids.open_quick_chat => .open_quick_chat,
        ids.rename_quick_chat => .rename_quick_chat,
        ids.delete_quick_chat => .delete_quick_chat,
        ids.open_project => .open_project,
        ids.new_project_loop => .new_project_loop,
        ids.inspect_project_worktrees => .inspect_project_worktrees,
        ids.project_settings => .project_settings,
        ids.reveal_project => .reveal_project,
        ids.remote_project_info => .remote_project_info,
        ids.close_project => .close_project,
        ids.remove_project => .remove_project,
        ids.delete_project_loops => .delete_project_loops,
        ids.new_quick_chat => .new_quick_chat,
        else => .none,
    };
}

fn append(menu: c.HMENU, id: usize, text: []const u8) void {
    appendEnabled(menu, id, text, true);
}

fn appendEnabled(menu: c.HMENU, id: usize, text: []const u8, enabled: bool) void {
    const wide = toWide(text) orelse return;
    defer std.heap.c_allocator.free(wide);
    var flags: c.UINT = @intCast(c.MF_STRING);
    if (!enabled) flags |= @intCast(c.MF_GRAYED);
    _ = c.AppendMenuW(menu, flags, id, wide.ptr);
}

fn separator(menu: c.HMENU) void {
    _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
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
    try std.testing.expectEqual(Action.pilot_composite, actionForCommand(ids.pilot_composite));
    try std.testing.expectEqual(Action.open_composite, actionForCommand(ids.open_composite));
    try std.testing.expectEqual(Action.arm_composite, actionForCommand(ids.arm_composite));
    try std.testing.expectEqual(Action.wire_node, actionForCommand(ids.wire_node));
    try std.testing.expectEqual(Action.mark_entry, actionForCommand(ids.mark_entry));
}

test "destructive context actions cannot bypass a cancelled confirmation" {
    try std.testing.expect(!shouldApply(.delete_node, false));
    try std.testing.expect(!shouldApply(.delete_edge, false));
    try std.testing.expect(!shouldApply(.delete_quick_chat, false));
    try std.testing.expect(!shouldApply(.remove_project, false));
    try std.testing.expect(!shouldApply(.delete_project_loops, false));
    try std.testing.expect(shouldApply(.rename_node, false));
}

test "quick chat context targets preserve stable identity" {
    const target = QuickChatTarget{ .id = "chat-a" };
    try std.testing.expectEqualStrings("chat-a", target.id);
    try std.testing.expectEqual(Action.open_quick_chat, actionForCommand(ids.open_quick_chat));
    try std.testing.expectEqual(Action.rename_quick_chat, actionForCommand(ids.rename_quick_chat));
    try std.testing.expectEqual(Action.delete_quick_chat, actionForCommand(ids.delete_quick_chat));
}

test "edge editing requires a stable edge identifier" {
    try std.testing.expect(!canEditEdge(""));
    try std.testing.expect(canEditEdge("edge-1"));
}

test "context targets carry stable copied identity rather than collection indices" {
    const node = NodeTarget{ .project_path = "C:\\work\\graph", .id = "node-a" };
    const edge = EdgeTarget{ .project_path = "C:\\work\\graph", .id = "edge-a" };
    try std.testing.expectEqualStrings("node-a", node.id);
    try std.testing.expectEqualStrings("edge-a", edge.id);
    try std.testing.expectEqualStrings("C:\\work\\graph", edge.project_path);
}

test "project context commands expose ingress management and safe destructive actions" {
    const target = ProjectTarget{ .path = "C:\\work\\graph", .remote = false };
    try std.testing.expectEqualStrings("C:\\work\\graph", target.path);
    try std.testing.expectEqual(Action.open_project, actionForCommand(ids.open_project));
    try std.testing.expectEqual(Action.project_settings, actionForCommand(ids.project_settings));
    try std.testing.expectEqual(Action.remove_project, actionForCommand(ids.remove_project));
    try std.testing.expectEqual(Action.delete_project_loops, actionForCommand(ids.delete_project_loops));
}
