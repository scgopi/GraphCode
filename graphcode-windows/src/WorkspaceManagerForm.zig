const std = @import("std");
const Manager = @import("WorkspaceManager.zig");
const Lifecycle = @import("WorkspaceLifecycle.zig");
const NativeForms = @import("NativeForms.zig");
const Win32 = @import("Win32.zig");
const c = Win32.c;
const Dpi = @import("Dpi.zig");
const AppFont = @import("AppFont.zig");
const SheetFramework = @import("SheetFramework.zig");

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeWorkspaceManager");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("Manage Workspaces");
const list_id = 9721;
const open_id = 9722;
const rename_id = 9723;
const new_id = 9724;
const delete_id = 9725;
const detail_id = 9726;
const done_id = 1;
const cancel_id = 2;
const timer_id = 1;
const CachedRow = struct { text: ?[]u8 = null, summary: Manager.Summary = .loading };

pub fn actionForCommand(command: usize) ?Manager.ActionKind {
    return switch (command) {
        open_id => .open,
        rename_id => .rename,
        new_id => .new,
        delete_id => .delete,
        else => null,
    };
}

const Dialog = struct {
    model: *Manager.Model,
    work: *Manager.SummaryWork,
    handoff: Manager.Handoff = .{},
    selection: ?usize = null,
    cached: []CachedRow,
    extent: i32 = 0,
    list: c.HWND = null,
    detail: c.HWND = null,
    open: c.HWND = null,
    rename: c.HWND = null,
    new: c.HWND = null,
    delete: c.HWND = null,
    host: ?*SheetFramework.Host = null,
    content_root: c.HWND = null,
    title_label: c.HWND = null,
    note_label: c.HWND = null,
    dpi: u32 = Dpi.base_dpi,
    list_height: i32 = 220,
    detail_y: i32 = 276,
    reason_y: i32 = 396,
    content_extent: i32 = 468,
    closed: bool = false,
    failure: ?anyerror = null,

    fn cancel(self: *Dialog) void {
        self.handoff.cancel(self.model.allocator);
        self.work.cancel();
        self.closed = true;
        if (self.host) |host| host.requestClose();
    }
};

var active: ?*Dialog = null;

pub fn show(parent: c.HWND, model: *Manager.Model, work: *Manager.SummaryWork) !?Manager.Action {
    var lease = try NativeForms.ModalLease.acquire();
    defer lease.deinit();
    defer work.cancel();
    const cached = try model.allocator.alloc(CachedRow, model.rows.len);
    @memset(cached, .{});
    defer {
        for (cached) |entry| if (entry.text) |value| model.allocator.free(value);
        model.allocator.free(cached);
    }
    var dialog = Dialog{ .model = model, .work = work, .cached = cached };
    defer dialog.handoff.cancel(model.allocator);
    active = &dialog;
    defer active = null;
    try run(parent, &dialog);
    lease.deinit();
    if (dialog.failure) |err| return err;
    return dialog.handoff.take(work.reap(), NativeForms.isModalActive());
}

fn run(parent: c.HWND, dialog: *Dialog) !void {
    var klass: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    klass.lpfnWndProc = @ptrCast(&contentProc);
    klass.hInstance = c.GetModuleHandleW(null);
    klass.lpszClassName = class_name.ptr;
    klass.hCursor = c.LoadCursorW(null, Win32.resourceIdentifier(32512));
    klass.hbrBackground = null;
    if (c.RegisterClassW(&klass) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.WorkspaceManagerClassFailed;
    dialog.dpi = Dpi.normalize(Win32.dpiForWindow(parent));
    var host: SheetFramework.Host = .{};
    defer host.deinit();
    try createSheet(&host, parent, dialog);
    const hwnd = host.hwnd;
    _ = try syncRows(dialog);
    try syncDetails(dialog);
    if (c.SetTimer(hwnd, timer_id, 100, null) == 0) return error.WorkspaceManagerTimerFailed;
    defer _ = c.KillTimer(hwnd, timer_id);
    _ = c.SendMessageW(hwnd, c.DM_SETDEFID, done_id, 0);
    _ = c.SetFocus(dialog.host.?.hwnd);
    try host.runModal();
}

fn createSheet(host: *SheetFramework.Host, parent: c.HWND, dialog: *Dialog) !void {
    dialog.list_height = std.math.clamp(96 + @as(i32, @intCast(dialog.model.rows.len)) * 24, 144, 260);
    dialog.detail_y = 56 + dialog.list_height;
    dialog.reason_y = dialog.detail_y + 120;
    dialog.content_extent = dialog.reason_y + 72;
    try host.init(parent, .{
        .layout_input = .{
            .owner = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .dpi = dialog.dpi,
            .desired_width = 920,
            .minimum_width = 620,
            .heights = .{ .minimum = 440, .ideal = 560, .maximum = 760 },
            .content_extent = dialog.content_extent,
        },
        .context = dialog,
        .on_layout = &layoutSheet,
        .on_message = &sheetMessage,
    });
    if (c.SetWindowTextW(host.hwnd, window_title.ptr) == 0) return error.WorkspaceManagerCreationFailed;
    dialog.host = host;
    dialog.content_root = c.CreateWindowExW(
        c.WS_EX_CONTROLPARENT,
        class_name.ptr,
        null,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_CLIPCHILDREN,
        0,
        0,
        0,
        0,
        host.viewport,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.WorkspaceManagerCreationFailed;
    dialog.title_label = try control(dialog.content_root, dialog.dpi, "STATIC", "Workspaces - saved summaries are not live totals", 0, 0, 16, 12, 870, 24);
    dialog.list = try control(dialog.content_root, dialog.dpi, "LISTBOX", "", list_id, c.WS_TABSTOP | c.WS_VSCROLL | c.WS_HSCROLL | c.LBS_NOTIFY | c.LBS_NOINTEGRALHEIGHT, 16, 40, 870, dialog.list_height);
    dialog.detail = try control(dialog.content_root, dialog.dpi, "EDIT", "Select a workspace to see its full path and actions.", detail_id, c.WS_TABSTOP | c.ES_READONLY | c.ES_MULTILINE | c.ES_AUTOVSCROLL | c.WS_VSCROLL, 16, dialog.detail_y, 870, 104);
    dialog.note_label = try control(dialog.content_root, dialog.dpi, "STATIC", Manager.delete_note, 0, 0, 16, dialog.reason_y, 870, 52);
    const actions = workspaceFooterActions(host.hwnd, dialog.dpi);
    try host.configureFooter(&actions);
    dialog.open = try host.createFooterButton(open_id, std.unicode.utf8ToUtf16LeStringLiteral("Open").ptr);
    dialog.rename = try host.createFooterButton(rename_id, std.unicode.utf8ToUtf16LeStringLiteral("Rename...").ptr);
    dialog.new = try host.createFooterButton(new_id, std.unicode.utf8ToUtf16LeStringLiteral("New Workspace...").ptr);
    dialog.delete = try host.createFooterButton(delete_id, std.unicode.utf8ToUtf16LeStringLiteral("Delete...").ptr);
    const done = try host.createFooterButton(done_id, std.unicode.utf8ToUtf16LeStringLiteral("Done").ptr);
    for ([_]c.HWND{ dialog.open, dialog.rename, dialog.new, dialog.delete, done }) |button|
        AppFont.apply(button, AppFont.control_size, false);
    try host.relayout();
}

fn layoutSheet(context: ?*anyopaque, layout: SheetFramework.Layout) !void {
    const dialog: *Dialog = @ptrCast(@alignCast(context.?));
    if (dialog.host) |host| dialog.dpi = Dpi.normalize(host.options.layout_input.dpi);
    if (dialog.content_root == null) return;
    const font = AppFont.getForDpi(AppFont.control_size, false, dialog.dpi);
    for ([_]c.HWND{
        dialog.title_label,
        dialog.list,
        dialog.detail,
        dialog.note_label,
        dialog.open,
        dialog.rename,
        dialog.new,
        dialog.delete,
        c.GetDlgItem(dialog.host.?.hwnd, done_id),
    }) |control_handle| {
        if (control_handle != null)
            _ = c.SendMessageW(control_handle, c.WM_SETFONT, @intFromPtr(font), 1);
    }
    const scrollbar = if (layout.scroll.visible) SheetFramework.Metrics.forDpi(dialog.dpi).scrollbar_width else 0;
    const content_width = @max(0, layout.viewport.width - scrollbar);
    if (c.MoveWindow(dialog.content_root, 0, -layout.scroll.offset, content_width, @max(layout.scroll.extent, layout.viewport.height), 1) == 0)
        return error.WorkspaceManagerLayoutFailed;
    const inset = Dpi.scale(16, dialog.dpi);
    const width = @max(0, content_width - inset * 2);
    const positions = [_]struct { hwnd: c.HWND, y: i32, height: i32 }{
        .{ .hwnd = dialog.title_label, .y = 12, .height = 24 },
        .{ .hwnd = dialog.list, .y = 40, .height = dialog.list_height },
        .{ .hwnd = dialog.detail, .y = dialog.detail_y, .height = 104 },
        .{ .hwnd = dialog.note_label, .y = dialog.reason_y, .height = 52 },
    };
    for (positions) |entry| if (entry.hwnd != null) {
        if (c.MoveWindow(entry.hwnd, inset, Dpi.scale(entry.y, dialog.dpi), width, Dpi.scale(entry.height, dialog.dpi), 1) == 0)
            return error.WorkspaceManagerLayoutFailed;
    };
}

fn footerTextWidth(hwnd: c.HWND, dpi: u32, text: []const u16, fallback: i32) i32 {
    const hdc = c.GetDC(hwnd);
    if (hdc == null) return Dpi.scale(fallback, dpi);
    defer _ = c.ReleaseDC(hwnd, hdc);
    const old_font = AppFont.selectForDpi(hdc, AppFont.control_size, false);
    defer _ = c.SelectObject(hdc, old_font);
    var size: c.SIZE = undefined;
    if (c.GetTextExtentPoint32W(hdc, text.ptr, @intCast(text.len), &size) == 0)
        return Dpi.scale(fallback, dpi);
    return size.cx;
}

fn workspaceFooterActions(hwnd: c.HWND, dpi: u32) [5]SheetFramework.FooterAction {
    return .{
        .{ .id = open_id, .role = .secondary, .measured_text_width = footerTextWidth(hwnd, dpi, std.unicode.utf8ToUtf16LeStringLiteral("Open"), 36) },
        .{ .id = rename_id, .role = .secondary, .measured_text_width = footerTextWidth(hwnd, dpi, std.unicode.utf8ToUtf16LeStringLiteral("Rename..."), 68) },
        .{ .id = new_id, .role = .secondary, .measured_text_width = footerTextWidth(hwnd, dpi, std.unicode.utf8ToUtf16LeStringLiteral("New Workspace..."), 112) },
        .{ .id = delete_id, .role = .destructive, .measured_text_width = footerTextWidth(hwnd, dpi, std.unicode.utf8ToUtf16LeStringLiteral("Delete..."), 66) },
        .{ .id = done_id, .role = .primary, .measured_text_width = footerTextWidth(hwnd, dpi, std.unicode.utf8ToUtf16LeStringLiteral("Done"), 36), .return_hint = true },
    };
}

fn listHeight(client_height: i32, dpi: u32) i32 {
    return @max(80, Dpi.unscale(client_height, dpi) - 261);
}

fn control(parent: c.HWND, dpi: u32, kind: []const u8, text: []const u8, id: usize, style: c.DWORD, x: i32, y: i32, width: i32, height: i32) !c.HWND {
    const allocator = active.?.model.allocator;
    const wide_kind = try std.unicode.utf8ToUtf16LeAllocZ(allocator, kind);
    defer allocator.free(wide_kind);
    const wide_text = try std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
    defer allocator.free(wide_text);
    const hwnd = c.CreateWindowExW(
        0,
        wide_kind.ptr,
        wide_text.ptr,
        @as(c.DWORD, c.WS_CHILD | c.WS_VISIBLE) | style,
        Dpi.scale(x, dpi),
        Dpi.scale(y, dpi),
        Dpi.scale(width, dpi),
        Dpi.scale(height, dpi),
        parent,
        Win32.opaquePointerFromInt(c.HMENU, id),
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.WorkspaceManagerControlFailed;
    AppFont.apply(hwnd, AppFont.control_size, false);
    return hwnd;
}

fn syncRows(dialog: *Dialog) !bool {
    const allocator = dialog.model.allocator;
    const top = c.SendMessageW(dialog.list, c.LB_GETTOPINDEX, 0, 0);
    var changed = false;
    for (dialog.model.rows, dialog.cached, 0..) |row, *cached, index| {
        if (cached.text != null and std.meta.eql(cached.summary, row.summary)) continue;
        const text = try Manager.rowText(allocator, row);
        errdefer allocator.free(text);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
        defer allocator.free(wide);
        const dc = c.GetDC(dialog.list);
        if (dc != null) {
            const font = c.SendMessageW(dialog.list, c.WM_GETFONT, 0, 0);
            const old = c.SelectObject(dc, Win32.opaquePointerFromInt(c.HGDIOBJ, @bitCast(font)));
            var size: c.SIZE = undefined;
            if (c.GetTextExtentPoint32W(dc, wide.ptr, @intCast(wide.len), &size) != 0) dialog.extent = @max(dialog.extent, size.cx + 24);
            _ = c.SelectObject(dc, old);
            _ = c.ReleaseDC(dialog.list, dc);
        }
        if (cached.text == null or !std.mem.eql(u8, cached.text.?, text)) {
            if (cached.text != null) _ = c.SendMessageW(dialog.list, c.LB_DELETESTRING, index, 0);
            const result = c.SendMessageW(dialog.list, c.LB_INSERTSTRING, index, @bitCast(@intFromPtr(wide.ptr)));
            if (result == c.LB_ERR or result == c.LB_ERRSPACE) return error.WorkspaceManagerListFailed;
            if (cached.text) |previous| allocator.free(previous);
            cached.text = text;
            changed = true;
        } else allocator.free(text);
        cached.summary = row.summary;
    }
    _ = c.SendMessageW(dialog.list, c.LB_SETHORIZONTALEXTENT, @intCast(dialog.extent), 0);
    if (dialog.selection) |index| _ = c.SendMessageW(dialog.list, c.LB_SETCURSEL, index, 0);
    if (top >= 0) _ = c.SendMessageW(dialog.list, c.LB_SETTOPINDEX, @intCast(top), 0);
    return changed;
}

/// Delete is offered only for a row nothing else holds, and never while an action is waiting
/// on the saved-summary reader.
fn deleteEnabled(waiting: bool, refusal: ?Manager.Refusal) bool {
    if (waiting) return false;
    const value = refusal orelse return false;
    return value == .none;
}

fn syncDetails(dialog: *Dialog) !void {
    const waiting = dialog.handoff.pending != null;
    const row: ?Manager.Row = if (dialog.selection) |index| dialog.model.rows[index] else null;
    _ = c.EnableWindow(dialog.open, @intFromBool(!waiting and row != null and row.?.canOpen()));
    _ = c.EnableWindow(dialog.rename, @intFromBool(!waiting and row != null and row.?.refusal() == .none));
    _ = c.EnableWindow(dialog.delete, @intFromBool(deleteEnabled(waiting, if (row) |value| value.refusal() else null)));
    _ = c.EnableWindow(dialog.new, @intFromBool(!waiting));
    _ = c.EnableWindow(dialog.list, @intFromBool(!waiting));
    const allocator = dialog.model.allocator;
    const text = if (waiting)
        try allocator.dupe(u8, "Finishing the saved-summary read before the next action. Done or Escape cancels the action.")
    else if (row) |selected| blk: {
        const summary = try Manager.summaryText(allocator, selected.summary);
        defer allocator.free(summary);
        break :blk try std.fmt.allocPrint(allocator, "{s}\r\n{s}\r\n{s}\r\nSaved top-level counts can lag other windows; no live or descendant totals are implied.", .{
            selected.workspace.path, summary, Manager.refusalText(selected.refusal()),
        });
    } else try allocator.dupe(u8, "Select a workspace to see its full path and actions.");
    defer allocator.free(text);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
    defer allocator.free(wide);
    if (c.SetWindowTextW(dialog.detail, wide.ptr) == 0) return error.WorkspaceManagerTextFailed;
}

fn handleMessage(dialog: *Dialog, hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM) bool {
    switch (message) {
        c.WM_CLOSE => {
            dialog.cancel();
            return true;
        },
        c.WM_TIMER => {
            if (wparam != timer_id) return false;
            const drained = dialog.work.poll(dialog.model);
            if (drained) {
                _ = c.KillTimer(hwnd, timer_id);
                for (dialog.model.rows) |*row| {
                    if (row.summary == .failed and row.summary.failed == .previous_scan)
                        row.summary = .{ .failed = .cancelled };
                }
            }
            const changed = syncRows(dialog) catch |err| {
                dialog.failure = err;
                dialog.cancel();
                return true;
            };
            if (changed) syncDetails(dialog) catch |err| {
                dialog.failure = err;
                dialog.cancel();
                return true;
            };
            finishHandoffAfterDrain(dialog, drained);
            return true;
        },
        c.WM_COMMAND => {
            const id = wparam & 0xffff;
            if (id == done_id or id == cancel_id) {
                dialog.cancel();
                return true;
            }
            if (id == list_id and wparam >> 16 == c.LBN_SELCHANGE and dialog.handoff.pending == null) {
                const selected = c.SendMessageW(dialog.list, c.LB_GETCURSEL, 0, 0);
                dialog.selection = if (selected >= 0 and selected < dialog.model.rows.len) @intCast(selected) else null;
            } else if (id == list_id and wparam >> 16 == c.LBN_SETFOCUS) {
                dialog.host.?.reveal(Dpi.scale(36, dialog.dpi), Dpi.scale(48 + dialog.list_height, dialog.dpi)) catch {};
            } else if (id == detail_id and wparam >> 16 == c.EN_SETFOCUS) {
                dialog.host.?.reveal(Dpi.scale(dialog.detail_y - 4, dialog.dpi), Dpi.scale(dialog.detail_y + 112, dialog.dpi)) catch {};
            } else if (actionForCommand(id)) |kind| {
                if (dialog.handoff.pending != null) return true;
                dialog.handoff.pending = dialog.model.capture(kind, dialog.selection) catch |err| {
                    dialog.failure = err;
                    dialog.cancel();
                    return true;
                };
                dialog.work.cancel();
                if (dialog.work.poll(dialog.model)) {
                    dialog.closed = true;
                    dialog.host.?.requestClose();
                }
            }
            syncDetails(dialog) catch |err| {
                dialog.failure = err;
                dialog.cancel();
            };
            return true;
        },
        else => return false,
    }
}

fn finishHandoffAfterDrain(dialog: *Dialog, drained: bool) void {
    if (!drained or dialog.handoff.pending == null) return;
    dialog.closed = true;
    if (dialog.host) |host| host.requestClose();
}

fn sheetMessage(context: ?*anyopaque, hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM, result: *c.LRESULT) bool {
    const dialog: *Dialog = @ptrCast(@alignCast(context.?));
    if (message == c.WM_DRAWITEM) {
        result.* = drawFooterItem(dialog.host.?, lparam);
        return true;
    }
    if (message == c.DM_GETDEFID) {
        result.* = (c.DC_HASDEFID << 16) | done_id;
        return true;
    }

    if (handleMessage(dialog, hwnd, message, wparam)) {
        result.* = 0;
        return true;
    }
    return false;
}

fn drawFooterItem(host: *SheetFramework.Host, lparam: c.LPARAM) c.LRESULT {
    const item = Win32.messagePointer(*const c.DRAWITEMSTRUCT, lparam);
    var role = SheetFramework.ActionRole.secondary;
    var return_hint = false;
    for (host.footer_actions[0..host.footer_action_count]) |action| {
        if (action.id != item.CtlID) continue;
        role = action.role;
        return_hint = action.return_hint and action.role.isPrimary();
        break;
    }
    SheetFramework.drawButton(item.hDC, .{ .x = item.rcItem.left, .y = item.rcItem.top, .width = item.rcItem.right - item.rcItem.left, .height = item.rcItem.bottom - item.rcItem.top }, host.options.layout_input.dpi, role, item.itemState & c.ODS_DISABLED == 0, item.itemState & c.ODS_SELECTED != 0) catch return 0;
    var text: [128]u16 = [_]u16{0} ** 128;
    const count = c.GetWindowTextW(item.hwndItem, &text, text.len);
    const old_font = AppFont.selectForDpi(item.hDC, AppFont.control_size, false);
    defer _ = c.SelectObject(item.hDC, old_font);
    _ = c.SetBkMode(item.hDC, c.TRANSPARENT);
    _ = c.SetTextColor(item.hDC, SheetFramework.controlPaintStyle(.button, item.itemState & c.ODS_DISABLED == 0).foreground);
    var bounds = item.rcItem;
    if (return_hint) bounds.right -= SheetFramework.Metrics.forDpi(host.options.layout_input.dpi).return_hint_width;
    _ = c.DrawTextW(item.hDC, &text, count, &bounds, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE);
    if (return_hint) {
        var hint_bounds = item.rcItem;
        hint_bounds.left = bounds.right;
        _ = c.DrawTextW(item.hDC, std.unicode.utf8ToUtf16LeStringLiteral("\u{21b5}").ptr, 1, &hint_bounds, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE);
    }
    return 1;
}

fn contentProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const dialog = active orelse return c.DefWindowProcW(hwnd, message, wparam, lparam);
    if (handleMessage(dialog, dialog.host.?.hwnd, message, wparam)) return 0;
    switch (message) {
        c.WM_CTLCOLORSTATIC => return dialog.host.?.brushes.apply(Win32.opaquePointerFromInt(c.HDC, wparam), .static, true) catch 0,
        c.WM_CTLCOLOREDIT, c.WM_CTLCOLORLISTBOX => return dialog.host.?.brushes.apply(Win32.opaquePointerFromInt(c.HDC, wparam), .edit, true) catch 0,
        c.WM_ERASEBKGND => {
            var bounds: c.RECT = undefined;
            if (c.GetClientRect(hwnd, &bounds) != 0) _ = c.FillRect(Win32.opaquePointerFromInt(c.HDC, wparam), &bounds, dialog.host.?.brushes.panel);
            return 1;
        },
        c.WM_PAINT => {
            var paint: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(hwnd, &paint);
            if (hdc != null) {
                const focus = c.GetFocus();
                const fields = [_]c.HWND{ dialog.list, dialog.detail };
                for (fields) |field| if (field != null) {
                    var bounds: c.RECT = undefined;
                    if (c.GetWindowRect(field, &bounds) != 0) {
                        var origin = c.POINT{ .x = bounds.left, .y = bounds.top };
                        _ = c.ScreenToClient(hwnd, &origin);
                        SheetFramework.drawField(hdc, .{
                            .x = origin.x - Dpi.scale(4, dialog.dpi),
                            .y = origin.y - Dpi.scale(4, dialog.dpi),
                            .width = bounds.right - bounds.left + Dpi.scale(8, dialog.dpi),
                            .height = bounds.bottom - bounds.top + Dpi.scale(8, dialog.dpi),
                        }, dialog.dpi, focus == field) catch {};
                    }
                };
                _ = c.EndPaint(hwnd, &paint);
            }
            return 0;
        },
        else => return c.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

test "workspace manager controls route Delete to a delete action and never route Done" {
    try std.testing.expectEqual(Manager.ActionKind.open, actionForCommand(open_id).?);
    try std.testing.expectEqual(Manager.ActionKind.rename, actionForCommand(rename_id).?);
    try std.testing.expectEqual(Manager.ActionKind.new, actionForCommand(new_id).?);
    try std.testing.expectEqual(Manager.ActionKind.delete, actionForCommand(delete_id).?);
    for ([_]usize{ done_id, cancel_id, list_id, detail_id, 5116, 5119, 5152, 5154 }) |id|
        try std.testing.expect(actionForCommand(id) == null);
}

test "workspace manager Delete is enabled exactly where a deletable row is selected" {
    for ([_]Manager.Refusal{ .none, .default, .current, .open, .unidentified, .unavailable }) |refusal| {
        try std.testing.expectEqual(refusal == .none, deleteEnabled(false, refusal));
        try std.testing.expect(!deleteEnabled(true, refusal));
    }
    try std.testing.expect(!deleteEnabled(false, null));
}

test "workspace manager modal lease blocks reentry and releases before handoff" {
    var lease = try NativeForms.ModalLease.acquire();
    defer lease.deinit();
    try std.testing.expectError(error.FormAlreadyOpen, NativeForms.ModalLease.acquire());
    var handoff = Manager.Handoff{ .pending = .{ .kind = .new } };
    try std.testing.expect(handoff.take(true, NativeForms.isModalActive()) == null);
    lease.deinit();
    try std.testing.expectEqual(Manager.ActionKind.new, handoff.take(true, NativeForms.isModalActive()).?.kind);
    var next = try NativeForms.ModalLease.acquire();
    defer next.deinit();
}

test "workspace manager drained handoff closes its sheet host" {
    var cached: [0]CachedRow = .{};
    var host: SheetFramework.Host = .{};
    var dialog = Dialog{
        .model = undefined,
        .work = undefined,
        .handoff = .{ .pending = .{ .kind = .new } },
        .cached = &cached,
        .host = &host,
    };
    finishHandoffAfterDrain(&dialog, false);
    try std.testing.expect(!dialog.closed and !host.closed);
    finishHandoffAfterDrain(&dialog, true);
    try std.testing.expect(dialog.closed and host.closed);
}

test "workspace manager shorter screen layout preserves footer room at common DPI" {
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const height = listHeight(Dpi.scale(440, dpi), dpi);
        try std.testing.expectEqual(@as(i32, 179), height);
        try std.testing.expect(50 + height + 112 + 44 + 30 < 440);
    }
}

fn hiddenOwner() !c.HWND {
    return c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr, null, c.WS_POPUP, 20, 20, 1000, 760, null, null, c.GetModuleHandleW(null), null) orelse error.WorkspaceManagerCreationFailed;
}

test "dialog framework: workspace manager uses hidden sheet viewport and role footer" {
    const owner = try hiddenOwner();
    defer _ = c.DestroyWindow(owner);
    const unavailable = Lifecycle.Workspace{
        .name = "unavailable",
        .path = "C:\\fixture\\.graphcode-unavailable",
        .identity = "c:/fixture/.graphcode-unavailable",
        .is_default = false,
    };
    var model = try Manager.Model.init(std.testing.allocator, &.{unavailable}, "", &.{.unavailable});
    defer model.deinit();
    var work = Manager.SummaryWork{};
    const cached = try std.testing.allocator.alloc(CachedRow, model.rows.len);
    @memset(cached, .{});
    defer {
        for (cached) |entry| if (entry.text) |value| std.testing.allocator.free(value);
        std.testing.allocator.free(cached);
    }
    var dialog = Dialog{ .model = &model, .work = &work, .selection = 0, .cached = cached };
    active = &dialog;
    defer active = null;
    var klass: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    klass.lpfnWndProc = @ptrCast(&contentProc);
    klass.hInstance = c.GetModuleHandleW(null);
    klass.lpszClassName = class_name.ptr;
    _ = c.RegisterClassW(&klass);
    dialog.dpi = 144;
    var host: SheetFramework.Host = .{};
    defer host.deinit();
    try createSheet(&host, owner, &dialog);
    _ = try syncRows(&dialog);
    try syncDetails(&dialog);
    try std.testing.expect(c.IsWindowVisible(host.hwnd) == 0);
    try std.testing.expect(c.GetWindowLongPtrW(host.hwnd, c.GWL_STYLE) & c.WS_CAPTION == 0);
    var title: [64]u16 = [_]u16{0} ** 64;
    const title_length = c.GetWindowTextW(host.hwnd, &title, title.len);
    try std.testing.expectEqualSlices(u16, window_title[0..window_title.len], title[0..@intCast(title_length)]);
    try std.testing.expect(c.GetParent(dialog.content_root) == host.viewport);
    try std.testing.expect(c.GetWindowLongPtrW(dialog.content_root, c.GWL_EXSTYLE) & c.WS_EX_CONTROLPARENT != 0);
    host.options.layout_input.content_extent = Dpi.unscale(host.current_layout.viewport.height, dialog.dpi) + 100;
    try host.relayout();
    try std.testing.expect(host.current_layout.scroll.visible);
    var viewport: c.RECT = undefined;
    var content: c.RECT = undefined;
    try std.testing.expect(c.GetClientRect(host.viewport, &viewport) != 0);
    try std.testing.expect(c.GetClientRect(dialog.content_root, &content) != 0);
    try std.testing.expectEqual(
        SheetFramework.Metrics.forDpi(dialog.dpi).scrollbar_width,
        (viewport.right - viewport.left) - (content.right - content.left),
    );
    try std.testing.expect(host.footer_layout.?.slotFor(delete_id).?.role == .destructive);
    try std.testing.expect(host.footer_layout.?.slotFor(done_id).?.role == .primary);
    for ([_]u32{ 192, 96, 144 }) |dpi| {
        try host.refreshForDpi(dpi);
        try std.testing.expect(c.IsWindowEnabled(dialog.open) == 0);
        try std.testing.expect(c.IsWindowEnabled(dialog.rename) == 0);
        try std.testing.expect(c.IsWindowEnabled(dialog.delete) == 0);
        try std.testing.expect(c.IsWindowEnabled(dialog.new) != 0);
        for (host.footer_actions[0..host.footer_action_count]) |action| {
            if (action.id == open_id or action.id == rename_id or action.id == delete_id)
                try std.testing.expect(!action.enabled);
        }
        try std.testing.expect(!host.footer_layout.?.slotFor(open_id).?.enabled);
        try std.testing.expect(!host.footer_layout.?.slotFor(rename_id).?.enabled);
        try std.testing.expect(!host.footer_layout.?.slotFor(delete_id).?.enabled);
        try std.testing.expectEqual(dpi, dialog.dpi);
        try std.testing.expectEqual(
            AppFont.getForDpi(AppFont.control_size, false, dpi),
            Win32.opaquePointerFromInt(c.HFONT, @bitCast(c.SendMessageW(dialog.list, c.WM_GETFONT, 0, 0))),
        );
        var title_bounds: c.RECT = undefined;
        var content_bounds: c.RECT = undefined;
        try std.testing.expect(c.GetWindowRect(dialog.title_label, &title_bounds) != 0);
        try std.testing.expect(c.GetWindowRect(dialog.content_root, &content_bounds) != 0);
        try std.testing.expectEqual(Dpi.scale(16, dpi), title_bounds.left - content_bounds.left);
    }
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const actions = workspaceFooterActions(host.hwnd, dpi);
        const width = Dpi.scale(920, dpi);
        const footer = try SheetFramework.measureFooter(width, Dpi.scale(64, dpi), dpi, &actions);
        try std.testing.expect(footer.measured_minimum_width <= width);
        for (footer.slice()) |slot| try std.testing.expect(slot.bounds.x >= 0 and slot.bounds.right() <= width);
        try std.testing.expect(actions[4].return_hint);
        try std.testing.expect(footer.slotFor(done_id).?.bounds.width >=
            actions[4].measured_text_width + SheetFramework.Metrics.forDpi(dpi).return_hint_width);
    }
}
