const c = @import("Win32.zig").c;
const Wire = @import("Wire.zig");
const SketchPromotion = @import("SketchPromotion.zig");
const NativeDialogs = @import("WindowsNativeDialogs.zig");

pub const NodeTarget = struct {
    project_path: []const u8,
    id: []const u8,
    composite: bool = false,
    can_arm: bool = false,
    unwired: bool = false,
    follows_template: bool = false,
    resolved: bool = false,
    can_create_child: bool = true,
    sketch: bool = false,
    promotion_context: ?*const SketchPromotion.Context = null,
};

pub const BackgroundTarget = struct {
    project_path: []const u8,
    local_filesystem: bool,
    worktrees_available: bool = true,
    reclaimable_worktrees: ?usize = null,
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
    worktrees_available: bool = true,
    reclaimable_worktrees: ?usize = null,
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
    promote_goal,
    promote_turn,
    promote_timed,
    rename_node,
    stop_node,
    delete_node,
    open_terminal,
    new_child_node,
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
    const new_child_node = 5119;
    const promote_goal = 5116;
    const promote_turn = 5117;
    const promote_timed = 5118;
    const wire_node = 5109;
    const mark_entry = 5112;
    const edit_edge = 5110;
    const delete_edge = 5111;
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

pub const NodeMenuCommand = struct {
    id: usize = 0,
    text: []const u8 = "",
    enabled: bool = true,
};

pub const NodeMenuItem = union(enum) {
    command: NodeMenuCommand,
    separator,
    promotion_submenu,
};

pub fn newChildNodeMenuItem(node: NodeTarget) ?NodeMenuCommand {
    if (node.resolved) return null;
    return .{ .id = ids.new_child_node, .text = "New Child Node...", .enabled = node.can_create_child };
}

pub const NodeMenuPlan = struct {
    items: [15]NodeMenuItem = undefined,
    len: usize = 0,

    fn addCommand(self: *NodeMenuPlan, item: NodeMenuCommand) void {
        self.items[self.len] = .{ .command = item };
        self.len += 1;
    }

    fn addSeparator(self: *NodeMenuPlan) void {
        self.items[self.len] = .separator;
        self.len += 1;
    }

    fn addPromotionSubmenu(self: *NodeMenuPlan) void {
        self.items[self.len] = .promotion_submenu;
        self.len += 1;
    }
};

pub fn nodeMenuPlan(node: NodeTarget) NodeMenuPlan {
    var plan = NodeMenuPlan{};
    plan.addCommand(.{ .id = ids.open_terminal, .text = "Open Terminal" });
    if (newChildNodeMenuItem(node)) |item| plan.addCommand(item);
    if (node.composite) {
        plan.addCommand(.{ .id = ids.open_composite, .text = "Open Group" });
        plan.addCommand(.{ .id = ids.pilot_composite, .text = "Pilot Once…" });
        plan.addCommand(.{ .id = ids.arm_composite, .text = "Arm Schedule", .enabled = node.can_arm });
    } else if (node.sketch) {
        plan.addPromotionSubmenu();
    }
    plan.addCommand(.{ .id = ids.rename_node, .text = "Rename...\tF2" });
    plan.addCommand(.{ .id = ids.save_node_template, .text = "Save as Template..." });
    if (node.follows_template) plan.addCommand(.{ .id = ids.detach_template, .text = "Detach from Template" });
    if (!node.resolved) plan.addCommand(.{ .id = ids.stop_node, .text = "Stop Loop\tCtrl+S" });
    plan.addSeparator();
    plan.addCommand(.{ .id = ids.edit_node, .text = "Edit Details..." });
    if (node.unwired) {
        plan.addCommand(.{ .id = ids.wire_node, .text = "Wire it up" });
        plan.addCommand(.{ .id = ids.mark_entry, .text = "Mark as entry" });
    }
    plan.addSeparator();
    plan.addCommand(.{ .id = ids.delete_node, .text = "Delete Loop...\tDelete" });
    return plan;
}

pub const PromotionItem = struct { id: usize, text: []const u8, action: Action };
const promotion_items = [_]PromotionItem{
    .{ .id = ids.promote_goal, .text = "Goal — asks for a done check", .action = .promote_goal },
    .{ .id = ids.promote_turn, .text = "Turn — asks where to pause", .action = .promote_turn },
    .{ .id = ids.promote_timed, .text = "Timed — asks for a cadence", .action = .promote_timed },
};

pub fn promotionItems(node: NodeTarget) []const PromotionItem {
    return if (node.sketch) &promotion_items else &.{};
}

pub fn promotionTarget(action: Action) ?SketchPromotion.Target {
    return switch (action) {
        .promote_goal => .goal,
        .promote_turn => .turn,
        .promote_timed => .timed,
        else => null,
    };
}

pub fn promotionEnabled(node: NodeTarget) bool {
    return node.sketch and node.promotion_context != null;
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
                if (!appendWorktreesMenuItem(
                    menu,
                    background.reclaimable_worktrees,
                    background.local_filesystem and background.worktrees_available,
                )) {
                    _ = c.DestroyMenu(menu);
                    return null;
                }
                appendEnabled(menu, ids.project_settings, "Project Settings...", background.local_filesystem and background.worktrees_available);
                appendEnabled(menu, ids.reveal_project, "Show in Explorer", background.local_filesystem);
            }
        },
        .quick_chats => append(menu, ids.new_quick_chat, "New Chat"),
        .project => |project| {
            append(menu, ids.open_project, "Open Project");
            append(menu, ids.new_project_loop, "New Loop...\tCtrl+N");
            separator(menu);
            if (!appendWorktreesMenuItem(menu, project.reclaimable_worktrees, project.worktrees_available)) {
                _ = c.DestroyMenu(menu);
                return null;
            }
            appendEnabled(menu, ids.project_settings, "Project Settings...", project.worktrees_available);
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
            const plan = nodeMenuPlan(node);
            for (plan.items[0..plan.len]) |item| switch (item) {
                .command => |command_item| appendEnabled(menu, command_item.id, command_item.text, command_item.enabled),
                .separator => separator(menu),
                .promotion_submenu => {
                    const items = promotionItems(node);
                    const submenu = c.CreatePopupMenu() orelse {
                        _ = c.DestroyMenu(menu);
                        return null;
                    };
                    if (!appendDisabledHeading(submenu, "Keep the session, add a shape")) {
                        _ = c.DestroyMenu(submenu);
                        _ = c.DestroyMenu(menu);
                        return null;
                    }
                    for (items) |promotion_item| appendEnabled(submenu, promotion_item.id, promotion_item.text, promotionEnabled(node));
                    const title = toWide("Promote to…") orelse {
                        _ = c.DestroyMenu(submenu);
                        _ = c.DestroyMenu(menu);
                        return null;
                    };
                    defer std.heap.c_allocator.free(title);
                    if (c.AppendMenuW(menu, c.MF_POPUP | c.MF_STRING, @intFromPtr(submenu), title.ptr) == 0) {
                        _ = c.DestroyMenu(submenu);
                        _ = c.DestroyMenu(menu);
                        return null;
                    }
                },
            };
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
    if (c.GetMenuItemCount(menu) == 0) {
        _ = c.DestroyMenu(menu);
        return null;
    }
    return menu;
}

pub fn confirm(parent: c.HWND, title: []const u8, message: []const u8) bool {
    return NativeDialogs.confirm(parent, std.heap.c_allocator, confirmationSpec(title, message)) catch false;
}

fn confirmationSpec(title: []const u8, message: []const u8) NativeDialogs.PromptSpec {
    return .{
        .title = title,
        .body = message,
        .cancel_action = .{ .label = "No", .role = .cancel, .is_default = true },
        .primary_action = .{ .label = "Yes", .role = .primary },
    };
}

fn actionForCommand(command: c_int) Action {
    return switch (command) {
        ids.rename_node => .rename_node,
        ids.stop_node => .stop_node,
        ids.delete_node => .delete_node,
        ids.open_terminal => .open_terminal,
        ids.new_child_node => .new_child_node,
        ids.edit_node => .edit_node,
        ids.promote_goal => .promote_goal,
        ids.promote_turn => .promote_turn,
        ids.promote_timed => .promote_timed,
        ids.open_composite => .open_composite,
        ids.pilot_composite => .pilot_composite,
        ids.arm_composite => .arm_composite,
        ids.save_node_template => .save_node_template,
        ids.detach_template => .detach_template,
        ids.wire_node => .wire_node,
        ids.mark_entry => .mark_entry,
        ids.edit_edge => .edit_edge,
        ids.delete_edge => .delete_edge,
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

fn appendWorktreesMenuItem(menu: c.HMENU, reclaimable: ?usize, enabled: bool) bool {
    var buffer: [64]u8 = undefined;
    const text = if (reclaimable) |count| blk: {
        if (count == 0) break :blk "Worktrees...";
        break :blk std.fmt.bufPrint(&buffer, "Worktrees... {d}", .{count}) catch return false;
    } else "Worktrees...";
    const wide = toWide(text) orelse return false;
    defer std.heap.c_allocator.free(wide);
    var flags: c.UINT = @intCast(c.MF_STRING);
    if (!enabled) flags |= @intCast(c.MF_GRAYED);
    return c.AppendMenuW(menu, flags, ids.inspect_project_worktrees, wide.ptr) != 0;
}

fn appendDisabledHeading(menu: c.HMENU, text: []const u8) bool {
    const wide = toWide(text) orelse return false;
    defer std.heap.c_allocator.free(wide);
    return c.AppendMenuW(menu, c.MF_STRING | c.MF_GRAYED, 0, wide.ptr) != 0;
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

test "dialog framework: generic confirmation preserves caller copy and No default" {
    const spec = confirmationSpec("Delete Edge", "Remove this edge?");
    try std.testing.expectEqualStrings("Delete Edge", spec.title);
    try std.testing.expectEqualStrings("Remove this edge?", spec.body);
    try std.testing.expectEqual(@as(usize, 0), spec.labels.len);
    try std.testing.expectEqualStrings("No", spec.cancel_action.label);
    try std.testing.expectEqual(NativeDialogs.ActionRole.cancel, spec.cancel_action.role);
    try std.testing.expect(spec.cancel_action.is_default);
    try std.testing.expectEqualStrings("Yes", spec.primary_action.label);
    try std.testing.expectEqual(NativeDialogs.ActionRole.primary, spec.primary_action.role);
    try std.testing.expect(!spec.primary_action.is_default);
}

const ExpectedMenuItem = struct {
    id: ?c.UINT = null,
    text: []const u16 = &.{},
    enabled: bool = true,
    separator: bool = false,
    submenu: bool = false,
    record_raw_state: bool = false,
    record_submenu_id: bool = false,
};

const NativeMenuItemSnapshot = struct {
    id: c.UINT,
    text: []const u16,
    item_type: c.UINT,
    state: c.UINT,
    submenu: c.HMENU,
    storage: []u16,
};

const max_native_menu_caption = 256;

fn readNativeMenuItem(
    menu: c.HMENU,
    position: c.UINT,
    allocator: std.mem.Allocator,
) !NativeMenuItemSnapshot {
    var query = std.mem.zeroes(c.MENUITEMINFOW);
    query.cbSize = @intCast(@sizeOf(c.MENUITEMINFOW));
    query.fMask = c.MIIM_STRING;
    if (c.GetMenuItemInfoW(menu, position, c.TRUE, &query) == 0)
        return error.MenuItemStringQueryFailed;

    const text_len: usize = @intCast(query.cch);
    if (text_len > max_native_menu_caption) return error.MenuCaptionTooLong;
    const storage = try allocator.alloc(u16, text_len + 1);
    errdefer allocator.free(storage);
    @memset(storage, 0);

    var item = std.mem.zeroes(c.MENUITEMINFOW);
    item.cbSize = @intCast(@sizeOf(c.MENUITEMINFOW));
    item.fMask = c.MIIM_ID | c.MIIM_FTYPE | c.MIIM_STATE | c.MIIM_SUBMENU | c.MIIM_STRING;
    item.dwTypeData = storage.ptr;
    item.cch = @intCast(storage.len);
    if (c.GetMenuItemInfoW(menu, position, c.TRUE, &item) == 0)
        return error.MenuItemReadFailed;
    if (item.cch > text_len) return error.MenuCaptionTruncated;
    if (item.cch != text_len) return error.MenuCaptionChangedDuringRead;

    return .{
        .id = item.wID,
        .text = storage[0..text_len],
        .item_type = item.fType,
        .state = item.fState,
        .submenu = item.hSubMenu,
        .storage = storage,
    };
}

fn expectNativeMenu(menu: c.HMENU, expected: []const ExpectedMenuItem) !void {
    const count = c.GetMenuItemCount(menu);
    if (count < 0) return error.MenuCountQueryFailed;
    try std.testing.expectEqual(expected.len, @as(usize, @intCast(count)));
    for (expected, 0..) |item, index| {
        const native = try readNativeMenuItem(menu, @intCast(index), std.testing.allocator);
        defer std.testing.allocator.free(native.storage);
        const is_separator = native.item_type & c.MFT_SEPARATOR != 0;
        try std.testing.expectEqual(item.separator, is_separator);
        if (item.id) |expected_id| try std.testing.expectEqual(expected_id, native.id);
        try std.testing.expectEqualSlices(u16, item.text, native.text);
        const enabled = !is_separator and native.state & (c.MFS_GRAYED | c.MFS_DISABLED) == 0;
        try std.testing.expectEqual(if (item.separator) false else item.enabled, enabled);
        try std.testing.expectEqual(item.submenu, native.submenu != null);
        if (item.record_raw_state) {
            std.debug.print("semantic fallback separator position={d} raw-state=0x{x}\n", .{ index, native.state });
        }
        if (item.record_submenu_id) {
            std.debug.print("semantic fallback submenu position={d} observed-native-id={d}\n", .{ index, native.id });
        }
    }
}

fn expectNativeMenuCounted(menu: c.HMENU, expected: []const ExpectedMenuItem, observations: *usize) !void {
    try expectNativeMenu(menu, expected);
    observations.* += expected.len;
}

const AttachedTestMenu = struct {
    root: c.HMENU,
    popup: c.HMENU,
};

fn attachTestPopup(hwnd: c.HWND, popup: c.HMENU) !AttachedTestMenu {
    const root = c.CreateMenu() orelse {
        _ = c.DestroyMenu(popup);
        return error.MenuCreationFailed;
    };
    var root_owns_popup = false;
    var attached_to_window = false;
    errdefer {
        if (attached_to_window) _ = c.SetMenu(hwnd, null);
        if (root_owns_popup) {
            if (c.RemoveMenu(root, 0, c.MF_BYPOSITION) != 0) {
                _ = c.DestroyMenu(popup);
            }
            _ = c.DestroyMenu(root);
        } else {
            _ = c.DestroyMenu(root);
            _ = c.DestroyMenu(popup);
        }
    }
    if (c.AppendMenuW(root, c.MF_POPUP | c.MF_STRING, @intFromPtr(popup), std.unicode.utf8ToUtf16LeStringLiteral("Test").ptr) == 0)
        return error.MenuInstallFailed;
    root_owns_popup = true;
    if (c.SetMenu(hwnd, root) == 0) return error.MenuInstallFailed;
    attached_to_window = true;
    const installed_root = c.GetMenu(hwnd) orelse return error.MenuLookupFailed;
    const installed_popup = c.GetSubMenu(installed_root, 0) orelse return error.MenuLookupFailed;
    if (installed_popup != popup) return error.MenuInstallMismatch;
    return .{ .root = root, .popup = installed_popup };
}

fn detachTestPopup(hwnd: c.HWND, attached: AttachedTestMenu) bool {
    var succeeded = c.SetMenu(hwnd, null) != 0;
    if (c.RemoveMenu(attached.root, 0, c.MF_BYPOSITION) == 0) {
        _ = c.DestroyMenu(attached.root);
        return false;
    }
    if (c.DestroyMenu(attached.popup) == 0) succeeded = false;
    if (c.DestroyMenu(attached.root) == 0) succeeded = false;
    return succeeded;
}

fn expectBuiltMenuOnHiddenWindow(
    hwnd: c.HWND,
    target: Target,
    expected: []const ExpectedMenuItem,
    observations: *usize,
) !void {
    const popup = buildMenu(target) orelse return error.MenuCreationFailed;
    const attached = try attachTestPopup(hwnd, popup);
    defer std.debug.assert(detachTestPopup(hwnd, attached));
    try expectNativeMenuCounted(attached.popup, expected, observations);
}

const DisposableMenuItem = struct {
    id: c.UINT = 0,
    caption: []const u8 = "",
    enabled: bool = true,
    separator: bool = false,
};

fn appendDisposableMenuItem(menu: c.HMENU, item: DisposableMenuItem) !void {
    if (item.separator) {
        if (c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null) == 0) return error.MenuAppendFailed;
        return;
    }
    const wide = toWide(item.caption) orelse return error.CaptionConversionFailed;
    defer std.heap.c_allocator.free(wide);
    const flags: c.UINT = if (item.enabled) c.MF_STRING else c.MF_STRING | c.MF_GRAYED;
    if (c.AppendMenuW(menu, flags, item.id, wide.ptr) == 0) return error.MenuAppendFailed;
}

fn expectDisposableMenuRejected(
    hwnd: c.HWND,
    actual: []const DisposableMenuItem,
    expected: []const ExpectedMenuItem,
) !void {
    const popup = c.CreatePopupMenu() orelse return error.MenuCreationFailed;
    const attached = try attachTestPopup(hwnd, popup);
    defer std.debug.assert(detachTestPopup(hwnd, attached));
    for (actual) |item| try appendDisposableMenuItem(attached.popup, item);
    try std.testing.expectError(error.TestExpectedEqual, expectNativeMenu(attached.popup, expected));
}

fn expectBuiltMenuRejected(
    hwnd: c.HWND,
    target: Target,
    removed_command: c.UINT,
    expected: []const ExpectedMenuItem,
) !void {
    const popup = buildMenu(target) orelse return error.MenuCreationFailed;
    const attached = try attachTestPopup(hwnd, popup);
    defer std.debug.assert(detachTestPopup(hwnd, attached));
    if (c.RemoveMenu(attached.popup, removed_command, c.MF_BYCOMMAND) == 0)
        return error.MenuMutationFailed;
    try std.testing.expectError(error.TestExpectedEqual, expectNativeMenu(attached.popup, expected));
}

fn expectNativeMenuItem(menu: c.HMENU, id: c.UINT, text: []const u16, enabled: bool) !void {
    const state = c.GetMenuState(menu, id, c.MF_BYCOMMAND);
    try std.testing.expect(state != std.math.maxInt(c.UINT));
    try std.testing.expectEqual(enabled, state & (c.MF_GRAYED | c.MF_DISABLED) == 0);
    var caption: [128]u16 = undefined;
    const length = c.GetMenuStringW(menu, id, &caption, caption.len, c.MF_BYCOMMAND);
    try std.testing.expectEqualSlices(u16, text, caption[0..@intCast(length)]);
}

fn expectWorktreesMenuItem(menu: c.HMENU, count: usize, enabled: bool) !void {
    var buffer: [64]u8 = undefined;
    const caption = if (count == 0)
        "Worktrees..."
    else
        try std.fmt.bufPrint(&buffer, "Worktrees... {d}", .{count});
    const wide = toWide(caption) orelse return error.CaptionConversionFailed;
    defer std.heap.c_allocator.free(wide);
    try expectNativeMenuItem(menu, ids.inspect_project_worktrees, wide[0..caption.len], enabled);
}

test "custody child menu plan is unresolved-only and uses its reserved command" {
    const target = NodeTarget{ .project_path = "B", .id = "11111111-1111-4111-8111-111111111111" };
    const item = newChildNodeMenuItem(target).?;
    try std.testing.expectEqual(@as(usize, 5119), item.id);
    try std.testing.expectEqualStrings("New Child Node...", item.text);
    try std.testing.expect(item.enabled);
    try std.testing.expectEqual(Action.new_child_node, actionForCommand(@intCast(item.id)));
    var resolved = target;
    resolved.resolved = true;
    try std.testing.expect(newChildNodeMenuItem(resolved) == null);
    try std.testing.expectEqual(Action.none, actionForCommand(0));
}

test "custody child node menu plan preserves existing items when creation is unavailable" {
    const expected_unresolved = [_]usize{ 5104, 5119, 5113, 5107, 5108, 5101, 5114, 5115, 5102, 0, 5100, 5109, 5112, 0, 5103 };
    const expected_resolved = [_]usize{ 5104, 5113, 5107, 5108, 5101, 5114, 5115, 0, 5100, 5109, 5112, 0, 5103 };
    for ([_]bool{ false, true }) |resolved| {
        const plan = nodeMenuPlan(.{
            .project_path = "B",
            .id = "parent",
            .composite = true,
            .unwired = true,
            .follows_template = true,
            .resolved = resolved,
            .can_create_child = false,
        });
        const expected: []const usize = if (resolved) &expected_resolved else &expected_unresolved;
        try std.testing.expectEqual(expected.len, plan.len);
        for (plan.items[0..plan.len], expected) |item, id| {
            switch (item) {
                .command => |command_item| {
                    try std.testing.expectEqual(id, command_item.id);
                    try std.testing.expectEqual(id != 5119 and id != 5108, command_item.enabled);
                },
                .separator => try std.testing.expectEqual(@as(usize, 0), id),
                .promotion_submenu => return error.UnexpectedPromotionSubmenu,
            }
        }
        try std.testing.expectEqualStrings("Open Terminal", plan.items[0].command.text);
        try std.testing.expectEqualStrings("Delete Loop...\tDelete", plan.items[plan.len - 1].command.text);
    }
}

test "context parity node popup preserves supported macOS order and destructive boundary" {
    @setEvalBranchQuota(10000);
    const main = buildMenu(.{ .node = .{ .project_path = "C:\\fixture", .id = "main" } }) orelse return error.MenuCreationFailed;
    defer _ = c.DestroyMenu(main);
    try expectNativeMenu(main, &.{
        .{ .id = 5104, .text = std.unicode.utf8ToUtf16LeStringLiteral("Open Terminal") },
        .{ .id = 5119, .text = std.unicode.utf8ToUtf16LeStringLiteral("New Child Node...") },
        .{ .id = 5101, .text = std.unicode.utf8ToUtf16LeStringLiteral("Rename...\tF2") },
        .{ .id = 5114, .text = std.unicode.utf8ToUtf16LeStringLiteral("Save as Template...") },
        .{ .id = 5102, .text = std.unicode.utf8ToUtf16LeStringLiteral("Stop Loop\tCtrl+S") },
        .{ .separator = true },
        .{ .id = 5100, .text = std.unicode.utf8ToUtf16LeStringLiteral("Edit Details...") },
        .{ .separator = true },
        .{ .id = 5103, .text = std.unicode.utf8ToUtf16LeStringLiteral("Delete Loop...\tDelete") },
    });

    const resolved = buildMenu(.{ .node = .{ .project_path = "C:\\fixture", .id = "resolved", .resolved = true } }) orelse return error.MenuCreationFailed;
    defer _ = c.DestroyMenu(resolved);
    try expectNativeMenu(resolved, &.{
        .{ .id = 5104, .text = std.unicode.utf8ToUtf16LeStringLiteral("Open Terminal") },
        .{ .id = 5101, .text = std.unicode.utf8ToUtf16LeStringLiteral("Rename...\tF2") },
        .{ .id = 5114, .text = std.unicode.utf8ToUtf16LeStringLiteral("Save as Template...") },
        .{ .separator = true },
        .{ .id = 5100, .text = std.unicode.utf8ToUtf16LeStringLiteral("Edit Details...") },
        .{ .separator = true },
        .{ .id = 5103, .text = std.unicode.utf8ToUtf16LeStringLiteral("Delete Loop...\tDelete") },
    });

    const composite = buildMenu(.{ .node = .{
        .project_path = "C:\\fixture",
        .id = "composite",
        .composite = true,
        .unwired = true,
        .follows_template = true,
    } }) orelse return error.MenuCreationFailed;
    defer _ = c.DestroyMenu(composite);
    try expectNativeMenu(composite, &.{
        .{ .id = 5104, .text = std.unicode.utf8ToUtf16LeStringLiteral("Open Terminal") },
        .{ .id = 5119, .text = std.unicode.utf8ToUtf16LeStringLiteral("New Child Node...") },
        .{ .id = 5113, .text = std.unicode.utf8ToUtf16LeStringLiteral("Open Group") },
        .{ .id = 5107, .text = std.unicode.utf8ToUtf16LeStringLiteral("Pilot Once…") },
        .{ .id = 5108, .text = std.unicode.utf8ToUtf16LeStringLiteral("Arm Schedule"), .enabled = false },
        .{ .id = 5101, .text = std.unicode.utf8ToUtf16LeStringLiteral("Rename...\tF2") },
        .{ .id = 5114, .text = std.unicode.utf8ToUtf16LeStringLiteral("Save as Template...") },
        .{ .id = 5115, .text = std.unicode.utf8ToUtf16LeStringLiteral("Detach from Template") },
        .{ .id = 5102, .text = std.unicode.utf8ToUtf16LeStringLiteral("Stop Loop\tCtrl+S") },
        .{ .separator = true },
        .{ .id = 5100, .text = std.unicode.utf8ToUtf16LeStringLiteral("Edit Details...") },
        .{ .id = 5109, .text = std.unicode.utf8ToUtf16LeStringLiteral("Wire it up") },
        .{ .id = 5112, .text = std.unicode.utf8ToUtf16LeStringLiteral("Mark as entry") },
        .{ .separator = true },
        .{ .id = 5103, .text = std.unicode.utf8ToUtf16LeStringLiteral("Delete Loop...\tDelete") },
    });
}

test "sketch promotion real menu plan exposes only three eligible target actions" {
    var node = NodeTarget{ .project_path = "B", .id = "id" };
    try std.testing.expectEqual(@as(usize, 0), promotionItems(node).len);
    node.sketch = true;
    try std.testing.expectEqual(@as(usize, 3), promotionItems(node).len);
    try std.testing.expect(!promotionEnabled(node));
    const context = SketchPromotion.Context{};
    node.promotion_context = &context;
    try std.testing.expect(promotionEnabled(node));
    for (promotionItems(node), [_]SketchPromotion.Target{ .goal, .turn, .timed }) |item, target| {
        try std.testing.expectEqual(item.action, actionForCommand(@intCast(item.id)));
        try std.testing.expectEqual(target, promotionTarget(item.action).?);
    }
    for (std.enums.values(Action)) |action| {
        if (action != .promote_goal and action != .promote_turn and action != .promote_timed)
            try std.testing.expect(promotionTarget(action) == null);
    }
}

test "sketch promotion production popup installs native Goal Turn Timed submenu on hidden HWND" {
    @setEvalBranchQuota(10000);
    const hwnd = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral("Promotion menu test"),
        c.WS_OVERLAPPEDWINDOW,
        0,
        0,
        0,
        0,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.WindowCreationFailed;
    defer _ = c.DestroyWindow(hwnd);

    const context = SketchPromotion.Context{};
    const cases = [_]struct { sketch: bool, context: ?*const SketchPromotion.Context, enabled: bool }{
        .{ .sketch = false, .context = null, .enabled = false },
        .{ .sketch = true, .context = null, .enabled = false },
        .{ .sketch = true, .context = &context, .enabled = true },
    };
    for (cases) |case| {
        const popup = buildMenu(.{ .node = .{
            .project_path = "C:\\fixture",
            .id = "sketch-a",
            .sketch = case.sketch,
            .promotion_context = case.context,
        } }) orelse return error.MenuCreationFailed;
        const bar = c.CreateMenu() orelse {
            _ = c.DestroyMenu(popup);
            return error.MenuCreationFailed;
        };
        defer {
            _ = c.SetMenu(hwnd, null);
            _ = c.DestroyMenu(bar);
        }
        if (c.AppendMenuW(bar, c.MF_POPUP | c.MF_STRING, @intFromPtr(popup), std.unicode.utf8ToUtf16LeStringLiteral("Node").ptr) == 0) {
            _ = c.DestroyMenu(popup);
            return error.MenuInstallFailed;
        }
        if (c.SetMenu(hwnd, bar) == 0) return error.MenuInstallFailed;
        const menu = c.GetSubMenu(c.GetMenu(hwnd), 0);
        try std.testing.expect(menu != null);
        if (!case.sketch) {
            for (0..@intCast(c.GetMenuItemCount(menu))) |index| {
                try std.testing.expect(c.GetSubMenu(menu, @intCast(index)) == null);
            }
            for ([_]c.UINT{ 5116, 5117, 5118 }) |id|
                try std.testing.expectEqual(std.math.maxInt(c.UINT), c.GetMenuState(menu, id, c.MF_BYCOMMAND));
            continue;
        }
        try expectNativeMenu(menu, &.{
            .{ .id = 5104, .text = std.unicode.utf8ToUtf16LeStringLiteral("Open Terminal") },
            .{ .id = 5119, .text = std.unicode.utf8ToUtf16LeStringLiteral("New Child Node...") },
            .{ .text = std.unicode.utf8ToUtf16LeStringLiteral("Promote to…"), .submenu = true },
            .{ .id = 5101, .text = std.unicode.utf8ToUtf16LeStringLiteral("Rename...\tF2") },
            .{ .id = 5114, .text = std.unicode.utf8ToUtf16LeStringLiteral("Save as Template...") },
            .{ .id = 5102, .text = std.unicode.utf8ToUtf16LeStringLiteral("Stop Loop\tCtrl+S") },
            .{ .separator = true },
            .{ .id = 5100, .text = std.unicode.utf8ToUtf16LeStringLiteral("Edit Details...") },
            .{ .separator = true },
            .{ .id = 5103, .text = std.unicode.utf8ToUtf16LeStringLiteral("Delete Loop...\tDelete") },
        });
        const submenu = c.GetSubMenu(menu, 2);
        try std.testing.expect(submenu != null);
        try expectNativeMenu(submenu, &.{
            .{ .id = 0, .text = std.unicode.utf8ToUtf16LeStringLiteral("Keep the session, add a shape"), .enabled = false },
            .{ .id = 5116, .text = std.unicode.utf8ToUtf16LeStringLiteral("Goal — asks for a done check"), .enabled = case.enabled },
            .{ .id = 5117, .text = std.unicode.utf8ToUtf16LeStringLiteral("Turn — asks where to pause"), .enabled = case.enabled },
            .{ .id = 5118, .text = std.unicode.utf8ToUtf16LeStringLiteral("Timed — asks for a cadence"), .enabled = case.enabled },
        });
        for ([_]struct { id: c.UINT, action: Action }{
            .{ .id = 5116, .action = .promote_goal },
            .{ .id = 5117, .action = .promote_turn },
            .{ .id = 5118, .action = .promote_timed },
        }, 0..) |item, index| {
            try std.testing.expectEqual(item.id, c.GetMenuItemID(submenu, @intCast(index + 1)));
            try std.testing.expectEqual(item.action, actionForCommand(@intCast(item.id)));
        }
    }
}

test "semantic fallback six E menus expose exact native item info on hidden HWND" {
    @setEvalBranchQuota(10000);
    const hwnd = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral("Semantic menu test"),
        c.WS_OVERLAPPEDWINDOW,
        0,
        0,
        0,
        0,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.WindowCreationFailed;
    defer std.debug.assert(c.DestroyWindow(hwnd) != 0);

    const background_expected = [_]ExpectedMenuItem{
        .{ .id = 5142, .text = std.unicode.utf8ToUtf16LeStringLiteral("Worktrees...") },
        .{ .id = 5143, .text = std.unicode.utf8ToUtf16LeStringLiteral("Project Settings...") },
        .{ .id = 5144, .text = std.unicode.utf8ToUtf16LeStringLiteral("Show in Explorer") },
    };
    const resolved_expected = [_]ExpectedMenuItem{
        .{ .id = 5104, .text = std.unicode.utf8ToUtf16LeStringLiteral("Open Terminal") },
        .{ .id = 5101, .text = std.unicode.utf8ToUtf16LeStringLiteral("Rename...\tF2") },
        .{ .id = 5114, .text = std.unicode.utf8ToUtf16LeStringLiteral("Save as Template...") },
        .{ .id = 0, .text = &.{}, .enabled = false, .separator = true, .record_raw_state = true },
        .{ .id = 5100, .text = std.unicode.utf8ToUtf16LeStringLiteral("Edit Details...") },
        .{ .id = 0, .text = &.{}, .enabled = false, .separator = true, .record_raw_state = true },
        .{ .id = 5103, .text = std.unicode.utf8ToUtf16LeStringLiteral("Delete Loop...\tDelete") },
    };
    const sketch_expected = [_]ExpectedMenuItem{
        .{ .id = 5104, .text = std.unicode.utf8ToUtf16LeStringLiteral("Open Terminal") },
        .{ .id = 5119, .text = std.unicode.utf8ToUtf16LeStringLiteral("New Child Node...") },
        .{ .text = std.unicode.utf8ToUtf16LeStringLiteral("Promote to…"), .submenu = true, .record_submenu_id = true },
        .{ .id = 5101, .text = std.unicode.utf8ToUtf16LeStringLiteral("Rename...\tF2") },
        .{ .id = 5114, .text = std.unicode.utf8ToUtf16LeStringLiteral("Save as Template...") },
        .{ .id = 5102, .text = std.unicode.utf8ToUtf16LeStringLiteral("Stop Loop\tCtrl+S") },
        .{ .id = 0, .text = &.{}, .enabled = false, .separator = true, .record_raw_state = true },
        .{ .id = 5100, .text = std.unicode.utf8ToUtf16LeStringLiteral("Edit Details...") },
        .{ .id = 5109, .text = std.unicode.utf8ToUtf16LeStringLiteral("Wire it up") },
        .{ .id = 5112, .text = std.unicode.utf8ToUtf16LeStringLiteral("Mark as entry") },
        .{ .id = 0, .text = &.{}, .enabled = false, .separator = true, .record_raw_state = true },
        .{ .id = 5103, .text = std.unicode.utf8ToUtf16LeStringLiteral("Delete Loop...\tDelete") },
    };
    const promote_child_expected = [_]ExpectedMenuItem{
        .{ .id = 0, .text = std.unicode.utf8ToUtf16LeStringLiteral("Keep the session, add a shape"), .enabled = false },
        .{ .id = 5116, .text = std.unicode.utf8ToUtf16LeStringLiteral("Goal — asks for a done check") },
        .{ .id = 5117, .text = std.unicode.utf8ToUtf16LeStringLiteral("Turn — asks where to pause") },
        .{ .id = 5118, .text = std.unicode.utf8ToUtf16LeStringLiteral("Timed — asks for a cadence") },
    };
    const post_goal_expected = [_]ExpectedMenuItem{
        .{ .id = 5104, .text = std.unicode.utf8ToUtf16LeStringLiteral("Open Terminal") },
        .{ .id = 5119, .text = std.unicode.utf8ToUtf16LeStringLiteral("New Child Node...") },
        .{ .id = 5101, .text = std.unicode.utf8ToUtf16LeStringLiteral("Rename...\tF2") },
        .{ .id = 5114, .text = std.unicode.utf8ToUtf16LeStringLiteral("Save as Template...") },
        .{ .id = 5102, .text = std.unicode.utf8ToUtf16LeStringLiteral("Stop Loop\tCtrl+S") },
        .{ .id = 0, .text = &.{}, .enabled = false, .separator = true, .record_raw_state = true },
        .{ .id = 5100, .text = std.unicode.utf8ToUtf16LeStringLiteral("Edit Details...") },
        .{ .id = 5109, .text = std.unicode.utf8ToUtf16LeStringLiteral("Wire it up") },
        .{ .id = 5112, .text = std.unicode.utf8ToUtf16LeStringLiteral("Mark as entry") },
        .{ .id = 0, .text = &.{}, .enabled = false, .separator = true, .record_raw_state = true },
        .{ .id = 5103, .text = std.unicode.utf8ToUtf16LeStringLiteral("Delete Loop...\tDelete") },
    };
    const edge_expected = [_]ExpectedMenuItem{
        .{ .id = 5110, .text = std.unicode.utf8ToUtf16LeStringLiteral("Edit Edge...") },
        .{ .id = 5111, .text = std.unicode.utf8ToUtf16LeStringLiteral("Delete Edge") },
    };

    var observations: usize = 0;
    try expectBuiltMenuOnHiddenWindow(hwnd, .{ .background = .{
        .project_path = "C:\\fixture",
        .local_filesystem = true,
    } }, &background_expected, &observations);
    try expectBuiltMenuOnHiddenWindow(hwnd, .{ .node = .{
        .project_path = "C:\\fixture",
        .id = "resolved-wired",
        .resolved = true,
    } }, &resolved_expected, &observations);

    const promotion_context = SketchPromotion.Context{};
    const sketch_node = NodeTarget{
        .project_path = "C:\\fixture",
        .id = "sketch-unwired",
        .unwired = true,
        .sketch = true,
        .promotion_context = &promotion_context,
    };
    {
        const sketch_popup = buildMenu(.{ .node = sketch_node }) orelse return error.MenuCreationFailed;
        const sketch_attached = try attachTestPopup(hwnd, sketch_popup);
        defer std.debug.assert(detachTestPopup(hwnd, sketch_attached));
        try expectNativeMenuCounted(sketch_attached.popup, &sketch_expected, &observations);
        const promote_child = c.GetSubMenu(sketch_attached.popup, 2) orelse return error.PromoteSubmenuMissing;
        try expectNativeMenuCounted(promote_child, &promote_child_expected, &observations);
    }

    // This target checks post-Goal menu flags only; it does not run or persist a promotion.
    try expectBuiltMenuOnHiddenWindow(hwnd, .{ .node = .{
        .project_path = "C:\\fixture",
        .id = "post-goal-idle-unresolved-unwired",
        .unwired = true,
    } }, &post_goal_expected, &observations);
    try expectBuiltMenuOnHiddenWindow(hwnd, .{ .edge = .{
        .project_path = "C:\\fixture",
        .id = "edge-a",
    } }, &edge_expected, &observations);
    try std.testing.expectEqual(@as(usize, 39), observations);
    std.debug.print(
        "semantic fallback positive targets=6 observations={d} (background=3 resolved=7 sketch-unwired=12 promote-child=4 post-Goal=11 edge=2)\n",
        .{observations},
    );

    try expectDisposableMenuRejected(hwnd, &.{
        .{ .id = 5142, .caption = "Worktrees..." },
        .{ .id = 5143, .caption = "Project Settings..." },
        .{ .id = 5144, .caption = "Show in Explorer" },
        .{ .id = 5150, .caption = "Unexpected" },
    }, &background_expected);
    try expectDisposableMenuRejected(hwnd, &.{
        .{ .id = 5111, .caption = "Delete Edge" },
        .{ .id = 5110, .caption = "Edit Edge..." },
    }, &edge_expected);
    try expectDisposableMenuRejected(hwnd, &.{
        .{ .id = 0, .caption = "Keep the session, add a shape", .enabled = true },
        .{ .id = 5116, .caption = "Goal — asks for a done check" },
        .{ .id = 5117, .caption = "Turn — asks where to pause" },
        .{ .id = 5118, .caption = "Timed — asks for a cadence" },
    }, &promote_child_expected);
    try expectDisposableMenuRejected(hwnd, &.{
        .{ .separator = true, .enabled = false },
        .{ .id = 5116, .caption = "Goal — asks for a done check" },
        .{ .id = 5117, .caption = "Turn — asks where to pause" },
        .{ .id = 5118, .caption = "Timed — asks for a cadence" },
    }, &promote_child_expected);
    try expectDisposableMenuRejected(hwnd, &.{
        .{ .id = 0, .caption = "Keep the session, add a shape", .enabled = false },
        .{ .id = 5116, .caption = "Goal — asks for a done check", .enabled = false },
        .{ .id = 5117, .caption = "Turn — asks where to pause" },
        .{ .id = 5118, .caption = "Timed — asks for a cadence" },
    }, &promote_child_expected);
    try expectDisposableMenuRejected(hwnd, &.{
        .{ .id = 0, .caption = "Keep the session, add a shape", .enabled = false },
        .{ .id = 5116, .caption = "Wrong caption" },
        .{ .id = 5117, .caption = "Turn — asks where to pause" },
        .{ .id = 5118, .caption = "Timed — asks for a cadence" },
    }, &promote_child_expected);
    try expectBuiltMenuRejected(hwnd, .{ .node = sketch_node }, 5109, &sketch_expected);
    try expectBuiltMenuRejected(hwnd, .{ .node = sketch_node }, 5112, &sketch_expected);

    {
        const edge_popup = buildMenu(.{ .edge = .{ .project_path = "C:\\fixture", .id = "edge-extra-header" } }) orelse return error.MenuCreationFailed;
        const edge_attached = try attachTestPopup(hwnd, edge_popup);
        defer std.debug.assert(detachTestPopup(hwnd, edge_attached));
        const edge_header = toWide("Edge") orelse return error.CaptionConversionFailed;
        defer std.heap.c_allocator.free(edge_header);
        if (c.InsertMenuW(edge_attached.popup, 0, c.MF_BYPOSITION | c.MF_STRING, 0, edge_header.ptr) == 0)
            return error.MenuAppendFailed;
        try std.testing.expectError(error.TestExpectedEqual, expectNativeMenu(edge_attached.popup, &edge_expected));
    }

    try std.testing.expectError(
        error.MenuItemStringQueryFailed,
        readNativeMenuItem(null, 0, std.testing.allocator),
    );
    try std.testing.expectError(error.MenuCountQueryFailed, expectNativeMenu(null, &.{}));

    {
        const one_item_popup = c.CreatePopupMenu() orelse return error.MenuCreationFailed;
        const one_item_attached = try attachTestPopup(hwnd, one_item_popup);
        defer std.debug.assert(detachTestPopup(hwnd, one_item_attached));
        try appendDisposableMenuItem(one_item_attached.popup, .{ .id = 1, .caption = "One" });
        try std.testing.expectError(
            error.MenuItemStringQueryFailed,
            readNativeMenuItem(one_item_attached.popup, 1, std.testing.allocator),
        );
    }
    std.debug.print(
        "semantic fallback negative controls=12: extra-item,reordered-actions,enabled-heading,separator-heading,disabled-action,wrong-caption,missing-5109,missing-5112,extra-edge-header,invalid-HMENU-item-read,invalid-HMENU-count-read,out-of-range-item-read\n",
        .{},
    );
}

test "context parity background omits duplicate edge creation and empty groups" {
    const menu = buildMenu(.{ .background = .{
        .project_path = "C:\\fixture",
        .local_filesystem = true,
    } }) orelse return error.MenuCreationFailed;
    defer _ = c.DestroyMenu(menu);
    try expectNativeMenu(menu, &.{
        .{ .id = 5142, .text = std.unicode.utf8ToUtf16LeStringLiteral("Worktrees...") },
        .{ .id = 5143, .text = std.unicode.utf8ToUtf16LeStringLiteral("Project Settings...") },
        .{ .id = 5144, .text = std.unicode.utf8ToUtf16LeStringLiteral("Show in Explorer") },
    });
    try std.testing.expectEqual(Action.none, actionForCommand(5120));

    const remote = buildMenu(.{ .background = .{
        .project_path = "ssh://builder/fixture",
        .local_filesystem = false,
    } }) orelse return error.MenuCreationFailed;
    defer _ = c.DestroyMenu(remote);
    try expectNativeMenu(remote, &.{
        .{ .id = 5142, .text = std.unicode.utf8ToUtf16LeStringLiteral("Worktrees..."), .enabled = false },
        .{ .id = 5143, .text = std.unicode.utf8ToUtf16LeStringLiteral("Project Settings..."), .enabled = false },
        .{ .id = 5144, .text = std.unicode.utf8ToUtf16LeStringLiteral("Show in Explorer"), .enabled = false },
    });

    const global = buildMenu(.{ .background = .{
        .project_path = "graphcode://global",
        .local_filesystem = false,
    } });
    if (global) |handle| _ = c.DestroyMenu(handle);
    try std.testing.expect(global == null);
}

test "context parity project Worktrees count renders independently from enabled state" {
    const project = buildMenu(.{ .project = .{
        .path = "C:\\fixture",
        .remote = false,
        .worktrees_available = false,
        .reclaimable_worktrees = 3,
    } }) orelse return error.MenuCreationFailed;
    defer _ = c.DestroyMenu(project);
    try expectWorktreesMenuItem(project, 3, false);

    for ([_]usize{ 0, 1, 7, 8 }) |count| {
        const disabled_project = buildMenu(.{ .project = .{
            .path = "C:\\fixture",
            .remote = false,
            .worktrees_available = false,
            .reclaimable_worktrees = count,
        } }) orelse return error.MenuCreationFailed;
        defer _ = c.DestroyMenu(disabled_project);
        try expectWorktreesMenuItem(disabled_project, count, false);
    }

    const no_count = buildMenu(.{ .project = .{
        .path = "C:\\fixture",
        .remote = false,
        .reclaimable_worktrees = 0,
    } }) orelse return error.MenuCreationFailed;
    defer _ = c.DestroyMenu(no_count);
    try expectWorktreesMenuItem(no_count, 0, true);
}

test "context parity background Worktrees count renders independently from enabled state" {
    const menu = buildMenu(.{ .background = .{
        .project_path = "C:\\fixture",
        .local_filesystem = false,
        .worktrees_available = false,
        .reclaimable_worktrees = 2,
    } }) orelse return error.MenuCreationFailed;
    defer _ = c.DestroyMenu(menu);
    try expectWorktreesMenuItem(menu, 2, false);

    for ([_]usize{ 0, 1, 7, 8 }) |count| {
        const disabled_background = buildMenu(.{ .background = .{
            .project_path = "C:\\fixture",
            .local_filesystem = false,
            .worktrees_available = false,
            .reclaimable_worktrees = count,
        } }) orelse return error.MenuCreationFailed;
        defer _ = c.DestroyMenu(disabled_background);
        try expectWorktreesMenuItem(disabled_background, count, false);
    }
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

test "node shortcut captions keep Open Terminal without a standalone Enter binding" {
    const InputRouter = @import("InputRouter.zig");
    try std.testing.expectEqual(InputRouter.Action.none, InputRouter.keyAction(c.VK_RETURN, false, false));
    try std.testing.expectEqual(InputRouter.HeaderKey.none, InputRouter.headerKey(c.VK_RETURN, false, false, false, false));
    try std.testing.expectEqual(InputRouter.HeaderKey.activate, InputRouter.headerKey(c.VK_RETURN, false, false, false, true));
    try std.testing.expectEqual(Action.open_terminal, actionForCommand(ids.open_terminal));

    const targets = [_]NodeTarget{
        .{ .project_path = "C:\\fixture", .id = "ordinary" },
        .{ .project_path = "C:\\fixture", .id = "resolved", .resolved = true },
        .{ .project_path = "C:\\fixture", .id = "composite", .composite = true },
        .{ .project_path = "C:\\fixture", .id = "unwired", .unwired = true },
    };
    for (targets) |target| {
        const menu = buildMenu(.{ .node = target }) orelse return error.MenuCreationFailed;
        defer _ = c.DestroyMenu(menu);
        try std.testing.expectEqual(@as(c.UINT, ids.open_terminal), c.GetMenuItemID(menu, 0));
        try std.testing.expectEqual(@as(c.UINT, c.MF_ENABLED), c.GetMenuState(menu, ids.open_terminal, c.MF_BYCOMMAND));
        var caption: [128]u16 = undefined;
        const length = c.GetMenuStringW(menu, ids.open_terminal, &caption, caption.len, c.MF_BYCOMMAND);
        try std.testing.expect(length > 0 and length < caption.len - 1);
        try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("Open Terminal"), caption[0..@intCast(length)]);
    }
}

test "node shortcut captions keep Edit Details without the rename Ctrl E hint" {
    const InputRouter = @import("InputRouter.zig");
    try std.testing.expectEqual(InputRouter.Action.edit_node, InputRouter.keyAction('E', true, false));
    try std.testing.expectEqual(InputRouter.Action.rename_selected, InputRouter.keyAction(c.VK_F2, false, false));
    try std.testing.expectEqual(Action.edit_node, actionForCommand(ids.edit_node));
    try std.testing.expectEqual(Action.rename_node, actionForCommand(ids.rename_node));

    const targets = [_]struct { node: NodeTarget, edit_position: c_int }{
        .{ .node = .{ .project_path = "C:\\fixture", .id = "ordinary" }, .edit_position = 6 },
        .{ .node = .{ .project_path = "C:\\fixture", .id = "resolved", .resolved = true }, .edit_position = 4 },
        .{ .node = .{ .project_path = "C:\\fixture", .id = "composite", .composite = true }, .edit_position = 9 },
        .{ .node = .{ .project_path = "C:\\fixture", .id = "unwired", .unwired = true }, .edit_position = 6 },
    };
    for (targets) |target| {
        const menu = buildMenu(.{ .node = target.node }) orelse return error.MenuCreationFailed;
        defer _ = c.DestroyMenu(menu);
        try std.testing.expectEqual(@as(c.UINT, ids.edit_node), c.GetMenuItemID(menu, target.edit_position));
        try std.testing.expectEqual(@as(c.UINT, c.MF_ENABLED), c.GetMenuState(menu, ids.edit_node, c.MF_BYCOMMAND));
        var caption: [128]u16 = undefined;
        const length = c.GetMenuStringW(menu, ids.edit_node, &caption, caption.len, c.MF_BYCOMMAND);
        try std.testing.expect(length > 0 and length < caption.len - 1);
        try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("Edit Details..."), caption[0..@intCast(length)]);
    }
}

test "background menu disables unavailable folder actions and omits them for global scope" {
    const remote = buildMenu(.{ .background = .{
        .project_path = "ssh://builder/fixture",
        .local_filesystem = false,
    } }) orelse return error.MenuCreationFailed;
    defer _ = c.DestroyMenu(remote);
    for ([_]c.UINT{ ids.inspect_project_worktrees, ids.project_settings, ids.reveal_project }) |id|
        try std.testing.expectEqual(@as(c.UINT, c.MF_GRAYED), c.GetMenuState(remote, id, c.MF_BYCOMMAND));
    try std.testing.expectEqual(Action.none, actionForCommand(5120));

    const global = buildMenu(.{ .background = .{
        .project_path = "graphcode://global",
        .local_filesystem = false,
    } });
    if (global) |handle| _ = c.DestroyMenu(handle);
    try std.testing.expect(global == null);
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
    try expectNativeMenu(menu, &.{
        .{ .id = ids.edit_edge, .text = std.unicode.utf8ToUtf16LeStringLiteral("Edit Edge...") },
        .{ .id = ids.delete_edge, .text = std.unicode.utf8ToUtf16LeStringLiteral("Delete Edge") },
    });
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
