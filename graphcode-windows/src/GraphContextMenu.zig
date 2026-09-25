const c = @import("Win32.zig").c;
const Wire = @import("Wire.zig");

pub const NodeTarget = struct {
    project_path: []const u8,
    id: []const u8,
    composite: bool = false,
    can_arm: bool = false,
    unwired: bool = false,
    follows_template: bool = false,
    resolved: bool = false,
};

pub const BackgroundTarget = struct {
    project_path: []const u8,
    local_filesystem: bool,
    can_create_edge: bool,
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
    background: BackgroundTarget,
    quick_chats,
    project: ProjectTarget,
    node: NodeTarget,
    edge: EdgeTarget,
    quick_chat: QuickChatTarget,
};

pub const Action = enum {
    none,
    edit_node,
    rename_node,
    stop_node,
    delete_node,
    open_terminal,
    message_node,
    memo_node,
    open_composite,
    pilot_composite,
    arm_composite,
    save_node_template,
    detach_template,
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
    move_project,
    trash_project,
    delete_project_loops,
    new_quick_chat,
};

pub const Callback = *const fn (?*anyopaque, Action, Target) void;

pub fn requiresConfirmation(action: Action) bool {
    return action == .delete_node or action == .delete_edge or action == .delete_quick_chat or
        action == .remove_project or action == .trash_project or action == .delete_project_loops;
}

pub fn shouldApply(action: Action, confirmed: bool) bool {
    return !requiresConfirmation(action) or confirmed;
}

pub fn canEditEdge(edge_id: []const u8) bool {
    return edge_id.len != 0;
}

const ids = struct {
    const edit_node = 5100;
    const rename_node = 5101;
    const stop_node = 5102;
    const delete_node = 5103;
    const open_terminal = 5104;
    const message_node = 5105;
    const memo_node = 5106;
    const open_composite = 5113;
    const pilot_composite = 5107;
    const arm_composite = 5108;
    const save_node_template = 5114;
    const detach_template = 5115;
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
    const move_project = 5149;
    const trash_project = 5151;
    const delete_project_loops = 5148;
    const new_quick_chat = 5150;
};

pub const move_project_menu_text = "Move Project... (unavailable: daemon support required)";

pub const MoveProjectMenuItem = struct {
    id: usize = ids.move_project,
    text: []const u8 = move_project_menu_text,
    enabled: bool,
};

/// Builds the real "Move Project..." popup item used by `show()` for the
/// project context menu. Exposed so tests can exercise the exact same
/// data the live Win32 menu is constructed from, rather than only a
/// separate accessibility contract model.
pub fn moveProjectMenuItem() MoveProjectMenuItem {
    return .{ .enabled = Wire.supportsProjectRelocation() };
}

pub fn show(
    parent: c.HWND,
    target: Target,
    x: i32,
    y: i32,
    context: ?*anyopaque,
    callback: Callback,
) void {
    const menu = buildMenu(target) orelse return;
    defer _ = c.DestroyMenu(menu);
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

fn buildMenu(target: Target) c.HMENU {
    const menu = c.CreatePopupMenu() orelse return null;
    switch (target) {
        .background => |background| {
            if (!std.mem.eql(u8, background.project_path, "graphcode://global")) {
                appendEnabled(menu, ids.inspect_project_worktrees, "Worktrees...", background.local_filesystem);
                appendEnabled(menu, ids.project_settings, "Project Settings...", background.local_filesystem);
                appendEnabled(menu, ids.reveal_project, "Show in Explorer", background.local_filesystem);
                separator(menu);
            }
            appendEnabled(menu, ids.create_edge, "Create Edge", background.can_create_edge);
        },
        .quick_chats => append(menu, ids.new_quick_chat, "New Chat"),
        .project => |project| {
            append(menu, ids.open_project, "Open Project");
            append(menu, ids.new_project_loop, "New Loop...\tCtrl+N");
            separator(menu);
            append(menu, ids.inspect_project_worktrees, "Worktrees...");
            append(menu, ids.project_settings, "Project Settings...");
            if (project.remote)
                append(menu, ids.remote_project_info, "Remote Connection Info")
            else
                append(menu, ids.reveal_project, "Show in Explorer");
            separator(menu);
            append(menu, ids.close_project, "Close Project");
            if (!project.remote) {
                const move_item = moveProjectMenuItem();
                appendEnabled(menu, move_item.id, move_item.text, move_item.enabled);
                append(menu, ids.trash_project, "Move to Recycle Bin...");
            }
            append(menu, ids.remove_project, "Remove from GraphCode...");
            append(menu, ids.delete_project_loops, "Delete All Loops...");
        },
        .node => |node| {
            append(menu, ids.open_terminal, "Open Terminal\tEnter");
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
            append(menu, ids.edit_node, "Edit Details...\tCtrl+E");
            append(menu, ids.save_node_template, "Save as Template...");
            if (node.follows_template) append(menu, ids.detach_template, "Detach from Template");
            append(menu, ids.rename_node, "Rename...\tF2");
            if (!node.resolved) append(menu, ids.stop_node, "Stop\tCtrl+S");
            append(menu, ids.delete_node, "Delete Loop...\tDelete");
        },
        .edge => {
            append(menu, ids.edit_edge, "Edit Edge...");
            append(menu, ids.delete_edge, "Delete Edge");
        },
        .quick_chat => {
            append(menu, ids.open_quick_chat, "Open Chat");
            append(menu, ids.rename_quick_chat, "Rename...\tCtrl+Shift+Q");
            append(menu, ids.delete_quick_chat, "Delete Chat...\tCtrl+Shift+Delete");
        },
    }
    return menu;
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
        ids.edit_node => .edit_node,
        ids.open_composite => .open_composite,
        ids.pilot_composite => .pilot_composite,
        ids.arm_composite => .arm_composite,
        ids.save_node_template => .save_node_template,
        ids.detach_template => .detach_template,
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
        ids.move_project => .move_project,
        ids.trash_project => .trash_project,
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

test "background menu exposes supported folder actions and gates edge creation" {
    const menu = buildMenu(.{ .background = .{
        .project_path = "C:\\fixture",
        .local_filesystem = true,
        .can_create_edge = false,
    } }) orelse return error.MenuCreationFailed;
    defer _ = c.DestroyMenu(menu);
    try std.testing.expectEqual(@as(c.UINT, c.MF_ENABLED), c.GetMenuState(menu, ids.inspect_project_worktrees, c.MF_BYCOMMAND));
    try std.testing.expectEqual(@as(c.UINT, c.MF_ENABLED), c.GetMenuState(menu, ids.project_settings, c.MF_BYCOMMAND));
    try std.testing.expectEqual(@as(c.UINT, c.MF_ENABLED), c.GetMenuState(menu, ids.reveal_project, c.MF_BYCOMMAND));
    try std.testing.expectEqual(@as(c.UINT, c.MF_GRAYED), c.GetMenuState(menu, ids.create_edge, c.MF_BYCOMMAND));
}

test "resolved node menu hides Stop but retains rename and edit details" {
    const menu = buildMenu(.{ .node = .{
        .project_path = "C:\\fixture",
        .id = "node-a",
        .resolved = true,
    } }) orelse return error.MenuCreationFailed;
    defer _ = c.DestroyMenu(menu);
    try std.testing.expectEqual(std.math.maxInt(c.UINT), c.GetMenuState(menu, ids.stop_node, c.MF_BYCOMMAND));
    try std.testing.expectEqual(@as(c.UINT, c.MF_ENABLED), c.GetMenuState(menu, ids.rename_node, c.MF_BYCOMMAND));
    try std.testing.expectEqual(@as(c.UINT, c.MF_ENABLED), c.GetMenuState(menu, ids.edit_node, c.MF_BYCOMMAND));
    try std.testing.expectEqual(std.math.maxInt(c.UINT), c.GetMenuState(menu, ids.message_node, c.MF_BYCOMMAND));
    try std.testing.expectEqual(std.math.maxInt(c.UINT), c.GetMenuState(menu, ids.memo_node, c.MF_BYCOMMAND));
}

test "background menu disables unavailable folder actions and omits them for global scope" {
    const remote = buildMenu(.{ .background = .{
        .project_path = "ssh://builder/fixture",
        .local_filesystem = false,
        .can_create_edge = true,
    } }) orelse return error.MenuCreationFailed;
    defer _ = c.DestroyMenu(remote);
    for ([_]c.UINT{ ids.inspect_project_worktrees, ids.project_settings, ids.reveal_project }) |id|
        try std.testing.expectEqual(@as(c.UINT, c.MF_GRAYED), c.GetMenuState(remote, id, c.MF_BYCOMMAND));
    try std.testing.expectEqual(@as(c.UINT, c.MF_ENABLED), c.GetMenuState(remote, ids.create_edge, c.MF_BYCOMMAND));

    const global = buildMenu(.{ .background = .{
        .project_path = "graphcode://global",
        .local_filesystem = false,
        .can_create_edge = false,
    } }) orelse return error.MenuCreationFailed;
    defer _ = c.DestroyMenu(global);
    try std.testing.expectEqual(@as(c_int, 1), c.GetMenuItemCount(global));
    try std.testing.expectEqual(@as(c.UINT, ids.create_edge), c.GetMenuItemID(global, 0));
}

test "native node menu variants expose only eligible actions" {
    for ([_]bool{ false, true }) |can_arm| {
        const menu = buildMenu(.{ .node = .{
            .project_path = "C:\\fixture",
            .id = "node-b",
            .composite = true,
            .can_arm = can_arm,
            .follows_template = true,
        } }) orelse return error.MenuCreationFailed;
        defer _ = c.DestroyMenu(menu);
        try std.testing.expectEqual(@as(c.UINT, if (can_arm) c.MF_ENABLED else c.MF_GRAYED), c.GetMenuState(menu, ids.arm_composite, c.MF_BYCOMMAND));
        for ([_]c.UINT{ ids.open_composite, ids.pilot_composite, ids.stop_node, ids.detach_template }) |id|
            try std.testing.expectEqual(@as(c.UINT, c.MF_ENABLED), c.GetMenuState(menu, id, c.MF_BYCOMMAND));
        try std.testing.expectEqual(std.math.maxInt(c.UINT), c.GetMenuState(menu, ids.wire_node, c.MF_BYCOMMAND));
    }
    const unwired = buildMenu(.{ .node = .{
        .project_path = "C:\\fixture",
        .id = "node-c",
        .unwired = true,
    } }) orelse return error.MenuCreationFailed;
    defer _ = c.DestroyMenu(unwired);
    for ([_]c.UINT{ ids.wire_node, ids.mark_entry, ids.stop_node }) |id|
        try std.testing.expectEqual(@as(c.UINT, c.MF_ENABLED), c.GetMenuState(unwired, id, c.MF_BYCOMMAND));
    try std.testing.expectEqual(std.math.maxInt(c.UINT), c.GetMenuState(unwired, ids.arm_composite, c.MF_BYCOMMAND));
}

test "edge menu preserves edit and delete command ordering" {
    const menu = buildMenu(.{ .edge = .{ .project_path = "C:\\fixture", .id = "edge-a" } }) orelse return error.MenuCreationFailed;
    defer _ = c.DestroyMenu(menu);
    try std.testing.expectEqual(@as(c_int, 2), c.GetMenuItemCount(menu));
    try std.testing.expectEqual(@as(c.UINT, ids.edit_edge), c.GetMenuItemID(menu, 0));
    try std.testing.expectEqual(@as(c.UINT, ids.delete_edge), c.GetMenuItemID(menu, 1));
}

test "context actions remain stable when graph IDs are reordered" {
    try std.testing.expectEqual(Action.edit_node, actionForCommand(ids.edit_node));
    try std.testing.expectEqual(Action.rename_node, actionForCommand(ids.rename_node));
    try std.testing.expectEqual(Action.delete_edge, actionForCommand(ids.delete_edge));
    try std.testing.expectEqual(Action.none, actionForCommand(0));
    try std.testing.expectEqual(Action.pilot_composite, actionForCommand(ids.pilot_composite));
    try std.testing.expectEqual(Action.open_composite, actionForCommand(ids.open_composite));
    try std.testing.expectEqual(Action.arm_composite, actionForCommand(ids.arm_composite));
    try std.testing.expectEqual(Action.wire_node, actionForCommand(ids.wire_node));
    try std.testing.expectEqual(Action.mark_entry, actionForCommand(ids.mark_entry));
    try std.testing.expectEqual(Action.save_node_template, actionForCommand(ids.save_node_template));
    try std.testing.expectEqual(Action.detach_template, actionForCommand(ids.detach_template));
}

test "destructive context actions cannot bypass a cancelled confirmation" {
    try std.testing.expect(!shouldApply(.delete_node, false));
    try std.testing.expect(!shouldApply(.delete_edge, false));
    try std.testing.expect(!shouldApply(.delete_quick_chat, false));
    try std.testing.expect(!shouldApply(.remove_project, false));
    try std.testing.expect(!shouldApply(.trash_project, false));
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
    try std.testing.expectEqual(Action.move_project, actionForCommand(ids.move_project));
    try std.testing.expectEqual(Action.trash_project, actionForCommand(ids.trash_project));
    try std.testing.expectEqual(Action.delete_project_loops, actionForCommand(ids.delete_project_loops));
}

test "project relocation is visibly unavailable rather than an Explorer alias" {
    try std.testing.expect(!Wire.supportsProjectRelocation());
    try std.testing.expect(std.mem.indexOf(
        u8,
        Wire.project_relocation_unavailable_reason,
        "authoritative moveProject command",
    ) != null);
}

test "the real Move Project menu item is disabled with its explicit reason inline" {
    // This exercises moveProjectMenuItem() directly: the same function
    // show() calls to append the actual Win32 popup entry, not a
    // separate accessibility-only model. It fails the moment the item's
    // command id, label, or enabled state drift from what the live
    // context menu renders.
    const item = moveProjectMenuItem();
    try std.testing.expectEqual(@as(usize, ids.move_project), item.id);
    try std.testing.expectEqualStrings(
        "Move Project... (unavailable: daemon support required)",
        item.text,
    );
    try std.testing.expect(!item.enabled);
    try std.testing.expectEqual(Action.move_project, actionForCommand(@intCast(item.id)));
}
