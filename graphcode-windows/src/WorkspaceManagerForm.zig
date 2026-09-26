const std = @import("std");
const Manager = @import("WorkspaceManager.zig");
const NativeForms = @import("NativeForms.zig");
const Win32 = @import("Win32.zig");
const c = Win32.c;
const Dpi = @import("Dpi.zig");
const AppFont = @import("AppFont.zig");
const ModalTeardown = @import("ModalTeardown.zig");

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeWorkspaceManager");
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
    closed: bool = false,
    failure: ?anyerror = null,

    fn cancel(self: *Dialog) void {
        self.handoff.cancel(self.model.allocator);
        self.work.cancel();
        self.closed = true;
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
    klass.lpfnWndProc = @ptrCast(&windowProc);
    klass.hInstance = c.GetModuleHandleW(null);
    klass.lpszClassName = class_name.ptr;
    klass.hCursor = c.LoadCursorW(null, Win32.resourceIdentifier(32512));
    klass.hbrBackground = Win32.opaquePointerFromInt(c.HBRUSH, c.COLOR_WINDOW + 1);
    if (c.RegisterClassW(&klass) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.WorkspaceManagerClassFailed;
    const dpi = Dpi.normalize(Win32.dpiForWindow(parent));
    const hwnd = c.CreateWindowExW(
        c.WS_EX_DLGMODALFRAME | c.WS_EX_CONTROLPARENT,
        class_name.ptr,
        std.unicode.utf8ToUtf16LeStringLiteral("Manage Workspaces").ptr,
        c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        Dpi.scale(920, dpi),
        @min(Dpi.scale(560, dpi), c.GetSystemMetrics(c.SM_CYSCREEN) - Dpi.scale(64, dpi)),
        parent,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.WorkspaceManagerCreationFailed;
    _ = c.EnableWindow(parent, 0);
    defer ModalTeardown.dismiss(hwnd, parent);
    var client: c.RECT = undefined;
    if (c.GetClientRect(hwnd, &client) == 0) return error.WorkspaceManagerLayoutFailed;
    const list_height = listHeight(client.bottom, dpi);
    const detail_top = 50 + list_height;
    const reason_top = detail_top + 112;
    const buttons_top = reason_top + 44;
    _ = try control(hwnd, dpi, "STATIC", "Workspaces - saved summaries are not live totals", 0, 0, 16, 12, 870, 24);
    dialog.list = try control(hwnd, dpi, "LISTBOX", "", list_id, c.WS_TABSTOP | c.WS_VSCROLL | c.WS_HSCROLL | c.WS_BORDER | c.LBS_NOTIFY | c.LBS_NOINTEGRALHEIGHT, 16, 40, 870, list_height);
    dialog.detail = try control(hwnd, dpi, "EDIT", "Select a workspace to see its full path and actions.", detail_id, c.WS_TABSTOP | c.ES_READONLY | c.ES_MULTILINE | c.ES_AUTOVSCROLL | c.WS_VSCROLL, 16, detail_top, 870, 104);
    _ = try control(hwnd, dpi, "STATIC", Manager.delete_reason, 0, 0, 16, reason_top, 870, 36);
    dialog.open = try control(hwnd, dpi, "BUTTON", "Open", open_id, c.WS_TABSTOP, 16, buttons_top, 110, 30);
    dialog.rename = try control(hwnd, dpi, "BUTTON", "Rename...", rename_id, c.WS_TABSTOP, 138, buttons_top, 120, 30);
    dialog.new = try control(hwnd, dpi, "BUTTON", "New Workspace...", new_id, c.WS_TABSTOP, 270, buttons_top, 160, 30);
    const delete = try control(hwnd, dpi, "BUTTON", "Delete (unavailable)", delete_id, c.WS_DISABLED, 442, buttons_top, 180, 30);
    _ = delete;
    const done = try control(hwnd, dpi, "BUTTON", "Done", done_id, c.WS_TABSTOP | c.BS_DEFPUSHBUTTON, 776, buttons_top, 110, 30);
    _ = c.SendMessageW(hwnd, c.DM_SETDEFID, done_id, 0);
    _ = try syncRows(dialog);
    try syncDetails(dialog);
    if (c.SetTimer(hwnd, timer_id, 100, null) == 0) return error.WorkspaceManagerTimerFailed;
    defer _ = c.KillTimer(hwnd, timer_id);
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.SetForegroundWindow(hwnd);
    _ = c.SetFocus(done);
    var message: c.MSG = undefined;
    while (!dialog.closed) {
        const code = c.GetMessageW(&message, null, 0, 0);
        if (code <= 0) {
            dialog.cancel();
            if (code == 0) c.PostQuitMessage(@intCast(message.wParam));
            if (code < 0) return error.WorkspaceManagerMessageFailed;
            break;
        }
        if (message.message == c.WM_KEYDOWN and message.wParam == c.VK_ESCAPE) {
            dialog.cancel();
            continue;
        }
        if (c.IsDialogMessageW(hwnd, &message) != 0) continue;
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }
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

fn syncDetails(dialog: *Dialog) !void {
    const waiting = dialog.handoff.pending != null;
    const row: ?Manager.Row = if (dialog.selection) |index| dialog.model.rows[index] else null;
    _ = c.EnableWindow(dialog.open, @intFromBool(!waiting and row != null and row.?.canOpen()));
    _ = c.EnableWindow(dialog.rename, @intFromBool(!waiting and row != null and row.?.refusal() == .none));
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

fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const dialog = active orelse return c.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_DESTROY => {
            if (!dialog.closed) dialog.cancel();
            return 0;
        },
        c.DM_GETDEFID => return (c.DC_HASDEFID << 16) | done_id,
        c.WM_CLOSE => {
            dialog.cancel();
            return 0;
        },
        c.WM_TIMER => {
            if (wparam != timer_id) return 0;
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
                return 0;
            };
            if (changed) syncDetails(dialog) catch |err| {
                dialog.failure = err;
                dialog.cancel();
                return 0;
            };
            if (drained and dialog.handoff.pending != null) dialog.closed = true;
            return 0;
        },
        c.WM_COMMAND => {
            const id = wparam & 0xffff;
            if (id == done_id or id == cancel_id) {
                dialog.cancel();
                return 0;
            }
            if (id == list_id and wparam >> 16 == c.LBN_SELCHANGE and dialog.handoff.pending == null) {
                const selected = c.SendMessageW(dialog.list, c.LB_GETCURSEL, 0, 0);
                dialog.selection = if (selected >= 0 and selected < dialog.model.rows.len) @intCast(selected) else null;
            } else if (actionForCommand(id)) |kind| {
                if (dialog.handoff.pending != null) return 0;
                dialog.handoff.pending = dialog.model.capture(kind, dialog.selection) catch |err| {
                    dialog.failure = err;
                    dialog.cancel();
                    return 0;
                };
                dialog.work.cancel();
                if (dialog.work.poll(dialog.model)) dialog.closed = true;
            }
            syncDetails(dialog) catch |err| {
                dialog.failure = err;
                dialog.cancel();
            };
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

test "workspace manager controls never route Delete or Done to a mutation" {
    try std.testing.expectEqual(Manager.ActionKind.open, actionForCommand(open_id).?);
    try std.testing.expectEqual(Manager.ActionKind.rename, actionForCommand(rename_id).?);
    try std.testing.expectEqual(Manager.ActionKind.new, actionForCommand(new_id).?);
    for ([_]usize{ done_id, cancel_id, delete_id, list_id, detail_id, 5116, 5119, 5152, 5154 }) |id|
        try std.testing.expect(actionForCommand(id) == null);
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

test "workspace manager shorter screen layout preserves footer room at common DPI" {
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const height = listHeight(Dpi.scale(440, dpi), dpi);
        try std.testing.expectEqual(@as(i32, 179), height);
        try std.testing.expect(50 + height + 112 + 44 + 30 < 440);
    }
}
