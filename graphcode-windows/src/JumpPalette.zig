const std = @import("std");
const Win32 = @import("Win32.zig");
const c = Win32.c;
const ModalTeardown = @import("ModalTeardown.zig");
const AppFont = @import("AppFont.zig");
const Dpi = @import("Dpi.zig");
const Tokens = @import("DesignTokens.zig");

pub const Entry = struct {
    project_path: []const u8,
    project_name: []const u8,
    node_id: []const u8,
    title: []const u8,
    loop_type: []const u8,
    state: []const u8,
};

pub const Match = struct {
    entry_index: usize,
    score: u8,
};

pub const Selection = struct {
    project_path: []u8,
    node_id: []u8,

    pub fn deinit(self: Selection, allocator: std.mem.Allocator) void {
        allocator.free(self.project_path);
        allocator.free(self.node_id);
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    entries: []const Entry,
    matches: std.array_list.Managed(Match),
    selection: usize = 0,

    pub fn init(allocator: std.mem.Allocator, entries: []const Entry) State {
        return .{
            .allocator = allocator,
            .entries = entries,
            .matches = std.array_list.Managed(Match).init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        self.matches.deinit();
    }

    pub fn filter(self: *State, raw_query: []const u8) !void {
        self.matches.clearRetainingCapacity();
        const query = std.mem.trim(u8, raw_query, " \t\r\n");
        for (self.entries, 0..) |entry, index| {
            const score = rank(entry, query) orelse continue;
            try self.matches.append(.{ .entry_index = index, .score = score });
        }
        std.mem.sort(Match, self.matches.items, {}, struct {
            fn lessThan(_: void, lhs: Match, rhs: Match) bool {
                if (lhs.score != rhs.score) return lhs.score < rhs.score;
                return lhs.entry_index < rhs.entry_index;
            }
        }.lessThan);
        self.selection = 0;
    }

    pub fn moveSelection(self: *State, delta: i32) void {
        if (self.matches.items.len == 0) {
            self.selection = 0;
            return;
        }
        const last = self.matches.items.len - 1;
        if (delta < 0) {
            self.selection = if (self.selection == 0) last else self.selection - 1;
        } else if (delta > 0) {
            self.selection = if (self.selection >= last) 0 else self.selection + 1;
        }
    }

    pub fn selectedEntry(self: *const State) ?Entry {
        if (self.selection >= self.matches.items.len) return null;
        return self.entries[self.matches.items[self.selection].entry_index];
    }
};

fn rank(entry: Entry, query: []const u8) ?u8 {
    if (query.len == 0) return 4;
    if (std.ascii.eqlIgnoreCase(entry.node_id, query)) return 0;
    if (std.ascii.eqlIgnoreCase(entry.title, query)) return 1;
    if (startsWithIgnoreCase(entry.title, query)) return 2;
    if (containsIgnoreCase(entry.title, query) or containsIgnoreCase(entry.node_id, query)) return 3;
    return null;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn containsIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > value.len) return false;
    var index: usize = 0;
    while (index + needle.len <= value.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(value[index .. index + needle.len], needle)) return true;
    }
    return false;
}

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeJumpPalette");
const search_id = 9401;
const results_id = 9402;
const ok_id = 1;
const cancel_id = 2;
const magnifier_id = 9403;
const field_height = 42;
const row_height = 42;
const selected_background = 0x004A341D;

const Dialog = struct {
    state: State,
    dpi: u32 = 96,
    magnifier: c.HWND = null,
    hint: c.HWND = null,
    edit: c.HWND = null,
    edit_proc: c.WNDPROC = null,
    pending_high_surrogate: ?u16 = null,
    list: c.HWND = null,
    empty_label: c.HWND = null,
    background: c.HBRUSH = null,
    mono_font: c.HFONT = null,
    failure: ?anyerror = null,
    accepted: bool = false,
    closed: bool = false,
};

var active: ?*Dialog = null;

pub fn show(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    entries: []const Entry,
) !?Selection {
    try registerClass();
    // The nested message loop can deliver daemon refreshes that replace App's graphs.
    const snapshot = try copyEntries(allocator, entries);
    defer freeEntries(allocator, snapshot);
    var dialog = Dialog{ .state = State.init(allocator, snapshot), .dpi = Dpi.normalize(Win32.dpiForWindow(parent)) };
    defer dialog.state.deinit();
    defer releaseDrawingResources(&dialog);
    try dialog.state.filter("");
    active = &dialog;
    defer active = null;

    var client: c.RECT = undefined;
    if (c.GetClientRect(parent, &client) == 0) return error.PaletteOwnerBoundsUnavailable;
    const bounds = paletteBounds(client.right, client.bottom, dialog.dpi, entries.len);
    if (bounds.right - bounds.left < Dpi.scale(120, dialog.dpi) or
        bounds.bottom - bounds.top < Dpi.scale(field_height + row_height, dialog.dpi)) return error.PaletteOwnerTooSmall;
    var origin = c.POINT{ .x = bounds.left, .y = bounds.top };
    if (c.ClientToScreen(parent, &origin) == 0) return error.PaletteOwnerBoundsUnavailable;
    const previous_focus = c.GetFocus();
    const hwnd = c.CreateWindowExW(
        c.WS_EX_CONTROLPARENT,
        class_name.ptr,
        std.unicode.utf8ToUtf16LeStringLiteral("Jump to loop").ptr,
        c.WS_POPUP | c.WS_CLIPCHILDREN,
        origin.x,
        origin.y,
        bounds.right - bounds.left,
        bounds.bottom - bounds.top,
        parent,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return (dialog.failure orelse error.PaletteCreationFailed);
    if (dialog.failure) |err| {
        _ = c.DestroyWindow(hwnd);
        return err;
    }
    _ = c.EnableWindow(parent, 0);
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.SetForegroundWindow(hwnd);
    _ = c.SetFocus(dialog.edit);

    var message: c.MSG = undefined;
    var quit_code: ?c.WPARAM = null;
    while (!dialog.closed) {
        const code = c.GetMessageW(&message, null, 0, 0);
        if (code <= 0) {
            dialog.closed = true;
            if (code == 0) quit_code = message.wParam;
            if (code < 0) fail(&dialog, error.PaletteMessageLoopFailed);
            break;
        }
        if (message.message == c.WM_KEYDOWN) {
            if (handleKey(&dialog, message.wParam)) continue;
        }
        if (c.IsDialogMessageW(hwnd, &message) != 0) continue;
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }
    const selected = if (dialog.accepted) dialog.state.selectedEntry() else null;
    ModalTeardown.dismiss(hwnd, parent);
    if (c.IsWindow(previous_focus) != 0) _ = c.SetFocus(previous_focus);
    if (quit_code) |value| c.PostQuitMessage(@intCast(value));
    if (dialog.failure) |err| return err;
    const entry = selected orelse return null;
    const project_path = try allocator.dupe(u8, entry.project_path);
    errdefer allocator.free(project_path);
    return .{
        .project_path = project_path,
        .node_id = try allocator.dupe(u8, entry.node_id),
    };
}

fn copyEntries(allocator: std.mem.Allocator, source: []const Entry) ![]Entry {
    const entries = try allocator.alloc(Entry, source.len);
    @memset(entries, .{ .project_path = &.{}, .project_name = &.{}, .node_id = &.{}, .title = &.{}, .loop_type = &.{}, .state = &.{} });
    errdefer freeEntries(allocator, entries);
    for (source, entries) |entry, *copy| {
        inline for (std.meta.fields(Entry)) |field| {
            @field(copy, field.name) = try allocator.dupe(u8, @field(entry, field.name));
        }
    }
    return entries;
}

fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |entry| {
        inline for (std.meta.fields(Entry)) |field| {
            allocator.free(@field(entry, field.name));
        }
    }
    allocator.free(entries);
}

test "empty palette creates native search controls and cancels without a selection" {
    try registerClass();
    var dialog = Dialog{ .state = State.init(std.testing.allocator, &.{}) };
    defer dialog.state.deinit();
    defer releaseDrawingResources(&dialog);
    try dialog.state.filter("");
    try std.testing.expect(active == null);
    active = &dialog;
    defer active = null;
    const hwnd = c.CreateWindowExW(
        c.WS_EX_DLGMODALFRAME | c.WS_EX_CONTROLPARENT,
        class_name.ptr,
        std.unicode.utf8ToUtf16LeStringLiteral("Hidden empty palette test").ptr,
        c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU,
        0,
        0,
        640,
        430,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.PaletteCreationFailed;
    defer _ = c.DestroyWindow(hwnd);
    try std.testing.expect(c.IsWindowVisible(hwnd) == 0);
    try std.testing.expect(dialog.edit != null and dialog.list != null);
    try std.testing.expectEqual(@as(c.LRESULT, 0), c.SendMessageW(dialog.list, c.LB_GETCOUNT, 0, 0));
    const empty_text = try readWindowText(std.testing.allocator, dialog.empty_label);
    defer std.testing.allocator.free(empty_text);
    try std.testing.expectEqualStrings("No loop matches “”", empty_text);
    accept(&dialog);
    try std.testing.expect(!dialog.accepted and !dialog.closed);
    _ = c.SendMessageW(hwnd, c.WM_COMMAND, cancel_id, 0);
    try std.testing.expect(dialog.closed and !dialog.accepted);
    try std.testing.expect(dialog.state.selectedEntry() == null);
}

fn registerClass() !void {
    var window_class: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    window_class.lpfnWndProc = @ptrCast(&windowProc);
    window_class.hInstance = c.GetModuleHandleW(null);
    window_class.lpszClassName = class_name.ptr;
    window_class.hCursor = c.LoadCursorW(null, Win32.resourceIdentifier(32512));
    if (c.RegisterClassW(&window_class) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.PaletteClassRegistrationFailed;
}

fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const dialog = active orelse return c.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_CREATE => {
            dialog.background = c.CreateSolidBrush(Tokens.window_tone);
            dialog.mono_font = c.CreateFontW(
                -Dpi.scale(11, dialog.dpi),
                0,
                0,
                0,
                c.FW_NORMAL,
                0,
                0,
                0,
                c.DEFAULT_CHARSET,
                c.OUT_DEFAULT_PRECIS,
                c.CLIP_DEFAULT_PRECIS,
                c.CLEARTYPE_QUALITY,
                c.FIXED_PITCH | c.FF_MODERN,
                std.unicode.utf8ToUtf16LeStringLiteral("Consolas").ptr,
            );
            if (dialog.background == null or dialog.mono_font == null) {
                fail(dialog, error.PaletteDrawingResourcesUnavailable);
                return -1;
            }
            // A native label precedes the edit so its UIA name stays meaningful.
            dialog.magnifier = c.CreateWindowExW(
                0,
                std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr,
                std.unicode.utf8ToUtf16LeStringLiteral("Jump to loop").ptr,
                c.WS_CHILD | c.WS_VISIBLE | c.SS_OWNERDRAW,
                0,
                0,
                0,
                0,
                hwnd,
                childId(magnifier_id),
                c.GetModuleHandleW(null),
                null,
            );
            dialog.edit = c.CreateWindowExW(
                0,
                std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr,
                null,
                c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_AUTOHSCROLL,
                0,
                0,
                0,
                0,
                hwnd,
                childId(search_id),
                c.GetModuleHandleW(null),
                null,
            );
            dialog.hint = c.CreateWindowExW(
                0,
                std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr,
                std.unicode.utf8ToUtf16LeStringLiteral("esc").ptr,
                c.WS_CHILD | c.WS_VISIBLE | c.SS_RIGHT,
                0,
                0,
                0,
                0,
                hwnd,
                null,
                c.GetModuleHandleW(null),
                null,
            );
            dialog.list = c.CreateWindowExW(
                0,
                std.unicode.utf8ToUtf16LeStringLiteral("LISTBOX").ptr,
                null,
                c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.WS_VSCROLL |
                    c.LBS_NOTIFY | c.LBS_NOINTEGRALHEIGHT | c.LBS_OWNERDRAWFIXED | c.LBS_HASSTRINGS,
                0,
                0,
                0,
                0,
                hwnd,
                childId(results_id),
                c.GetModuleHandleW(null),
                null,
            );
            dialog.empty_label = c.CreateWindowExW(
                0,
                std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr,
                null,
                c.WS_CHILD | c.SS_LEFT,
                0,
                0,
                0,
                0,
                hwnd,
                null,
                c.GetModuleHandleW(null),
                null,
            );
            if (dialog.magnifier == null or dialog.edit == null or dialog.hint == null or dialog.list == null or dialog.empty_label == null) {
                fail(dialog, error.PaletteControlCreationFailed);
                return -1;
            }
            _ = c.SendMessageW(dialog.edit, c.WM_SETFONT, @intFromPtr(AppFont.getForDpi(14, false, dialog.dpi)), 1);
            _ = c.SendMessageW(dialog.hint, c.WM_SETFONT, @intFromPtr(dialog.mono_font), 1);
            _ = c.SendMessageW(dialog.list, c.WM_SETFONT, @intFromPtr(AppFont.getForDpi(13, false, dialog.dpi)), 1);
            _ = c.SendMessageW(dialog.empty_label, c.WM_SETFONT, @intFromPtr(AppFont.getForDpi(12, false, dialog.dpi)), 1);
            const previous = c.SetWindowLongPtrW(dialog.edit, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&editProc)));
            if (previous == 0) {
                fail(dialog, error.PaletteEditSubclassFailed);
                return -1;
            }
            dialog.edit_proc = Win32.opaquePointerFromInt(c.WNDPROC, @bitCast(previous));
            _ = c.SendMessageW(dialog.list, c.LB_SETITEMHEIGHT, 0, Dpi.scale(row_height, dialog.dpi));
            refillList(dialog) catch |err| {
                fail(dialog, err);
                return -1;
            };
            return 0;
        },
        c.WM_MEASUREITEM => {
            const item = Win32.messagePointer(*c.MEASUREITEMSTRUCT, lparam);
            if (item.CtlID == results_id) {
                item.itemHeight = @intCast(Dpi.scale(row_height, dialog.dpi));
                return 1;
            }
        },
        c.WM_DRAWITEM => {
            const item = Win32.messagePointer(*const c.DRAWITEMSTRUCT, lparam);
            if (item.CtlID == magnifier_id) {
                drawMagnifier(item.hDC, item.rcItem, dialog);
                return 1;
            }
            if (item.CtlID == results_id) {
                drawRow(dialog, item) catch |err| fail(dialog, err);
                return 1;
            }
        },
        c.WM_CTLCOLOREDIT, c.WM_CTLCOLORSTATIC, c.WM_CTLCOLORLISTBOX => {
            const hdc = Win32.opaquePointerFromInt(c.HDC, wparam);
            _ = c.SetTextColor(hdc, if (message == c.WM_CTLCOLORSTATIC) Tokens.dialog_muted_text else Tokens.dialog_title_text);
            _ = c.SetBkColor(hdc, Tokens.window_tone);
            return @intCast(@intFromPtr(dialog.background));
        },
        c.WM_ERASEBKGND => {
            var client: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &client);
            _ = c.FillRect(Win32.opaquePointerFromInt(c.HDC, wparam), &client, dialog.background);
            return 1;
        },
        c.WM_PAINT => {
            var paint: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(hwnd, &paint);
            defer _ = c.EndPaint(hwnd, &paint);
            var client: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &client);
            _ = c.FillRect(hdc, &client, dialog.background);
            fill(hdc, .{ .left = 0, .top = Dpi.scale(field_height, dialog.dpi) - 1, .right = client.right, .bottom = Dpi.scale(field_height, dialog.dpi) }, 0x00333333);
            return 0;
        },
        c.WM_SIZE => {
            var client: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &client);
            const layout = fieldLayout(client.right, dialog.dpi);
            move(dialog.magnifier, layout.magnifier);
            move(dialog.edit, layout.edit);
            move(dialog.hint, layout.hint);
            move(dialog.list, .{ .left = 0, .top = Dpi.scale(field_height, dialog.dpi), .right = client.right, .bottom = client.bottom });
            move(dialog.empty_label, .{ .left = Dpi.scale(14, dialog.dpi), .top = Dpi.scale(56, dialog.dpi), .right = client.right - Dpi.scale(14, dialog.dpi), .bottom = client.bottom - Dpi.scale(14, dialog.dpi) });
            const radius = Dpi.scale(24, dialog.dpi);
            const region = c.CreateRoundRectRgn(0, 0, client.right + 1, client.bottom + 1, radius, radius);
            if (region != null and c.SetWindowRgn(hwnd, region, 1) == 0) _ = c.DeleteObject(region);
            return 0;
        },
        c.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            const notification: u16 = @truncate(wparam >> 16);
            if (command == search_id and notification == c.EN_CHANGE) {
                const query = readWindowText(dialog.state.allocator, dialog.edit) catch |err| {
                    fail(dialog, err);
                    return 0;
                };
                defer dialog.state.allocator.free(query);
                dialog.state.filter(query) catch |err| {
                    fail(dialog, err);
                    return 0;
                };
                refillList(dialog) catch |err| fail(dialog, err);
                _ = c.InvalidateRect(hwnd, null, 1);
                return 0;
            }
            if (command == results_id and notification == c.LBN_SELCHANGE) {
                const selected = c.SendMessageW(dialog.list, c.LB_GETCURSEL, 0, 0);
                if (selected >= 0) dialog.state.selection = @intCast(selected);
                return 0;
            }
            if (command == results_id and notification == c.LBN_DBLCLK) {
                accept(dialog);
                return 0;
            }
            if (command == ok_id) {
                accept(dialog);
                return 0;
            }
            if (command == cancel_id) {
                dialog.closed = true;
                return 0;
            }
        },
        c.WM_APP + 43 => {
            if (!envFlag("GRAPHCODE_UIA_GATE")) return 0;
            dialog.state.filter("UIA loop B") catch |err| {
                fail(dialog, err);
                return 0;
            };
            refillList(dialog) catch |err| fail(dialog, err);
            return 0;
        },
        c.WM_CLOSE => {
            dialog.closed = true;
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn refillList(dialog: *Dialog) !void {
    _ = c.SendMessageW(dialog.list, c.LB_RESETCONTENT, 0, 0);
    for (dialog.state.matches.items) |match| {
        const entry = dialog.state.entries[match.entry_index];
        const line = try resultText(dialog.state.allocator, entry);
        defer dialog.state.allocator.free(line);
        const wide = try utf8ToWideZ(dialog.state.allocator, line);
        defer dialog.state.allocator.free(wide);
        const added = c.SendMessageW(dialog.list, c.LB_ADDSTRING, 0, @intCast(@intFromPtr(wide.ptr)));
        if (added == c.LB_ERR or added == c.LB_ERRSPACE) return error.PaletteResultCreationFailed;
    }
    _ = c.ShowWindow(dialog.list, if (dialog.state.matches.items.len == 0) c.SW_HIDE else c.SW_SHOW);
    if (dialog.state.matches.items.len == 0) {
        const query = try readWindowText(dialog.state.allocator, dialog.edit);
        defer dialog.state.allocator.free(query);
        const text = try std.fmt.allocPrint(dialog.state.allocator, "No loop matches “{s}”", .{query});
        defer dialog.state.allocator.free(text);
        const wide = try utf8ToWideZ(dialog.state.allocator, text);
        defer dialog.state.allocator.free(wide);
        if (c.SetWindowTextW(dialog.empty_label, wide.ptr) == 0) return error.PaletteEmptyLabelUpdateFailed;
    }
    _ = c.ShowWindow(dialog.empty_label, if (dialog.state.matches.items.len == 0) c.SW_SHOW else c.SW_HIDE);
    syncListSelection(dialog);
}

fn editProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const dialog = active orelse return c.DefWindowProcW(hwnd, message, wparam, lparam);
    if (message == c.WM_CHAR) {
        if (wparam >= 0xD800 and wparam <= 0xDBFF) {
            if (dialog.pending_high_surrogate != null) std.log.warn("Jump palette discarded an incomplete UTF-16 character", .{});
            dialog.pending_high_surrogate = @intCast(wparam);
            return 0;
        }
        if (dialog.pending_high_surrogate) |high| {
            dialog.pending_high_surrogate = null;
            if (wparam >= 0xDC00 and wparam <= 0xDFFF) {
                // EN_CHANGE must observe the whole scalar, not a dangling high half.
                const text = [_:0]u16{ high, @intCast(wparam) };
                return c.CallWindowProcW(dialog.edit_proc, hwnd, c.EM_REPLACESEL, 1, @intCast(@intFromPtr(&text)));
            }
            std.log.warn("Jump palette discarded an incomplete UTF-16 character", .{});
        }
    }
    const result = c.CallWindowProcW(dialog.edit_proc, hwnd, message, wparam, lparam);
    // Plain EDIT controls do not render cue banners without a v6 controls manifest.
    if (message == c.WM_PAINT and c.GetWindowTextLengthW(hwnd) == 0) {
        const hdc = c.GetDC(hwnd);
        defer _ = c.ReleaseDC(hwnd, hdc);
        var bounds: c.RECT = undefined;
        _ = c.GetClientRect(hwnd, &bounds);
        const old_font = c.SelectObject(hdc, AppFont.getForDpi(14, false, dialog.dpi));
        defer _ = c.SelectObject(hdc, old_font);
        _ = c.SetBkMode(hdc, c.TRANSPARENT);
        _ = c.SetTextColor(hdc, Tokens.dialog_muted_text);
        _ = c.DrawTextW(hdc, std.unicode.utf8ToUtf16LeStringLiteral("Jump to loop").ptr, -1, &bounds, c.DT_LEFT | c.DT_SINGLELINE | c.DT_VCENTER | c.DT_NOPREFIX);
    }
    return result;
}

fn syncListSelection(dialog: *Dialog) void {
    if (dialog.state.matches.items.len == 0) return;
    _ = c.SendMessageW(dialog.list, c.LB_SETCURSEL, dialog.state.selection, 0);
}

fn accept(dialog: *Dialog) void {
    if (dialog.pending_high_surrogate != null) return;
    if (dialog.state.selectedEntry() == null) return;
    dialog.accepted = true;
    dialog.closed = true;
}

fn handleKey(dialog: *Dialog, key: c.WPARAM) bool {
    switch (key) {
        c.VK_DOWN, c.VK_UP => {
            dialog.state.moveSelection(if (key == c.VK_DOWN) 1 else -1);
            syncListSelection(dialog);
        },
        c.VK_RETURN => accept(dialog),
        c.VK_ESCAPE => dialog.closed = true,
        else => return false,
    }
    return true;
}

fn loopTypeLabel(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "sketch") or std.mem.eql(u8, value, "main")) return "Main";
    if (std.mem.eql(u8, value, "goalBased")) return "Goal";
    if (std.mem.eql(u8, value, "timeBased")) return "Timed";
    if (std.mem.eql(u8, value, "proactive") or std.mem.eql(u8, value, "composite")) return "Composite";
    if (std.mem.eql(u8, value, "turnBased")) return "Turn";
    return value;
}

fn stateLabel(value: []const u8) []const u8 {
    if (value.len == 0) return "IDLE";
    const raw = [_][]const u8{ "idle", "running", "waiting", "awaitingInput", "blocked", "succeeded", "failed", "stalled", "stopped" };
    const words = [_][]const u8{ "IDLE", "RUNNING", "WAITING", "NEEDS YOU", "BLOCKED", "DONE", "FAILED", "STALLED", "STOPPED" };
    for (raw, words) |key, word| {
        if (std.mem.eql(u8, value, key)) return word;
    }
    return value;
}

fn displayState(entry: Entry) []const u8 {
    if (std.mem.eql(u8, entry.loop_type, "timeBased") and std.mem.eql(u8, entry.state, "idle")) return "SCHEDULED";
    return stateLabel(entry.state);
}

fn resultText(allocator: std.mem.Allocator, entry: Entry) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}\n{s} · {s} · {s}", .{ entry.title, loopTypeLabel(entry.loop_type), displayState(entry), entry.project_name });
}

fn paletteBounds(width: i32, height: i32, dpi: u32, count: usize) c.RECT {
    const margin = Dpi.scale(8, dpi);
    const top = Dpi.scale(Tokens.header_height, dpi) + margin;
    const available_bottom = @max(top, height - Dpi.scale(Tokens.activity_strip_height, dpi) - margin);
    const palette_width = @max(0, @min(Dpi.scale(460, dpi), width - 2 * margin));
    const desired_height = Dpi.scale(field_height + row_height * @as(i32, @intCast(@min(8, @max(1, count)))), dpi);
    const palette_height = @min(Dpi.scale(380, dpi), @min(desired_height, available_bottom - top));
    const left = @divTrunc(width - palette_width, 2);
    return .{ .left = left, .top = top, .right = left + palette_width, .bottom = top + palette_height };
}

const FieldLayout = struct { magnifier: c.RECT, edit: c.RECT, hint: c.RECT };

fn fieldLayout(width: i32, dpi: u32) FieldLayout {
    return .{
        .magnifier = .{ .left = Dpi.scale(14, dpi), .top = Dpi.scale(15, dpi), .right = Dpi.scale(26, dpi), .bottom = Dpi.scale(27, dpi) },
        .edit = .{ .left = Dpi.scale(34, dpi), .top = Dpi.scale(11, dpi), .right = @max(Dpi.scale(34, dpi), width - Dpi.scale(46, dpi)), .bottom = Dpi.scale(31, dpi) },
        .hint = .{ .left = width - Dpi.scale(36, dpi), .top = Dpi.scale(14, dpi), .right = width - Dpi.scale(14, dpi), .bottom = Dpi.scale(28, dpi) },
    };
}

fn move(hwnd: c.HWND, bounds: c.RECT) void {
    _ = c.MoveWindow(hwnd, bounds.left, bounds.top, @max(0, bounds.right - bounds.left), @max(0, bounds.bottom - bounds.top), 1);
}

fn fail(dialog: *Dialog, err: anyerror) void {
    if (dialog.failure == null) dialog.failure = err;
    dialog.closed = true;
    std.log.err("Jump palette: {s}", .{@errorName(err)});
}

fn releaseDrawingResources(dialog: *Dialog) void {
    if (dialog.background != null) _ = c.DeleteObject(dialog.background);
    if (dialog.mono_font != null) _ = c.DeleteObject(dialog.mono_font);
}

fn fill(hdc: c.HDC, bounds: c.RECT, color: u32) void {
    const brush = c.CreateSolidBrush(color);
    defer _ = c.DeleteObject(brush);
    _ = c.FillRect(hdc, &bounds, brush);
}

fn drawText(dialog: *Dialog, hdc: c.HDC, text: []const u8, bounds: c.RECT, size: i32, mono: bool, color: u32) !void {
    const wide = try utf8ToWideZ(dialog.state.allocator, text);
    defer dialog.state.allocator.free(wide);
    const old_font = c.SelectObject(hdc, if (mono) dialog.mono_font else AppFont.getForDpi(size, false, dialog.dpi));
    defer _ = c.SelectObject(hdc, old_font);
    _ = c.SetTextColor(hdc, color);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    var rect = bounds;
    _ = c.DrawTextW(hdc, wide.ptr, @intCast(wide.len), &rect, c.DT_LEFT | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX);
}

fn drawMagnifier(hdc: c.HDC, bounds: c.RECT, dialog: *Dialog) void {
    _ = c.FillRect(hdc, &bounds, dialog.background);
    const pen = c.CreatePen(c.PS_SOLID, @max(1, Dpi.scale(1, dialog.dpi)), Tokens.dialog_muted_text);
    const old_pen = c.SelectObject(hdc, pen);
    const old_brush = c.SelectObject(hdc, c.GetStockObject(c.HOLLOW_BRUSH));
    _ = c.Ellipse(hdc, bounds.left, bounds.top, bounds.right - Dpi.scale(3, dialog.dpi), bounds.bottom - Dpi.scale(3, dialog.dpi));
    _ = c.MoveToEx(hdc, bounds.right - Dpi.scale(4, dialog.dpi), bounds.bottom - Dpi.scale(4, dialog.dpi), null);
    _ = c.LineTo(hdc, bounds.right, bounds.bottom);
    _ = c.SelectObject(hdc, old_brush);
    _ = c.SelectObject(hdc, old_pen);
    _ = c.DeleteObject(pen);
}

fn typeColor(value: []const u8) u32 {
    if (std.mem.eql(u8, value, "goalBased")) return 0x00709E19;
    if (std.mem.eql(u8, value, "timeBased")) return 0x000085C9;
    if (std.mem.eql(u8, value, "turnBased")) return 0x008151D5;
    if (std.mem.eql(u8, value, "composite") or std.mem.eql(u8, value, "proactive")) return 0x00E98590;
    return 0x00E3DAD3;
}

fn stateColor(value: []const u8) u32 {
    if (std.mem.eql(u8, value, "running") or std.mem.eql(u8, value, "waiting")) return 0x00FF840A;
    if (std.mem.eql(u8, value, "awaitingInput") or std.mem.eql(u8, value, "blocked")) return 0x000A9FFF;
    if (std.mem.eql(u8, value, "succeeded")) return 0x0058D130;
    if (std.mem.eql(u8, value, "failed")) return 0x003A45FF;
    if (std.mem.eql(u8, value, "stalled")) return 0x00F25ABF;
    return 0x006D6D6D;
}

const RowLayout = struct { title: c.RECT, subtitle: c.RECT, bar: c.RECT, dot: c.RECT };

fn rowLayout(bounds: c.RECT, dpi: u32) RowLayout {
    const dot_left = bounds.right - Dpi.scale(20, dpi);
    const text_left = bounds.left + Dpi.scale(26, dpi);
    const text_right = @max(text_left, dot_left - Dpi.scale(6, dpi));
    return .{
        .title = .{ .left = text_left, .top = bounds.top + Dpi.scale(6, dpi), .right = text_right, .bottom = bounds.top + Dpi.scale(22, dpi) },
        .subtitle = .{ .left = text_left, .top = bounds.top + Dpi.scale(22, dpi), .right = text_right, .bottom = bounds.top + Dpi.scale(36, dpi) },
        .bar = .{ .left = bounds.left + Dpi.scale(14, dpi), .top = bounds.top + Dpi.scale(10, dpi), .right = bounds.left + Dpi.scale(17, dpi), .bottom = bounds.top + Dpi.scale(32, dpi) },
        .dot = .{ .left = dot_left, .top = bounds.top + Dpi.scale(18, dpi), .right = dot_left + Dpi.scale(6, dpi), .bottom = bounds.top + Dpi.scale(24, dpi) },
    };
}

fn drawRow(dialog: *Dialog, item: *const c.DRAWITEMSTRUCT) !void {
    const selected = item.itemState & c.ODS_SELECTED != 0;
    fill(item.hDC, item.rcItem, if (selected) selected_background else Tokens.window_tone);
    if (item.itemID >= dialog.state.matches.items.len) return;
    const entry = dialog.state.entries[dialog.state.matches.items[item.itemID].entry_index];
    const layout = rowLayout(item.rcItem, dialog.dpi);
    fill(item.hDC, layout.bar, typeColor(entry.loop_type));
    try drawText(dialog, item.hDC, entry.title, layout.title, 13, false, Tokens.dialog_title_text);
    const subtitle = try std.fmt.allocPrint(dialog.state.allocator, "{s} · {s} · {s}", .{ loopTypeLabel(entry.loop_type), displayState(entry), entry.project_name });
    defer dialog.state.allocator.free(subtitle);
    try drawText(dialog, item.hDC, subtitle, layout.subtitle, 11, true, Tokens.dialog_muted_text);
    const pen = c.CreatePen(c.PS_SOLID, @max(1, Dpi.scale(1, dialog.dpi)), stateColor(entry.state));
    const hollow = std.mem.eql(u8, entry.state, "blocked") or std.mem.eql(u8, entry.state, "stopped") or std.mem.eql(u8, entry.state, "waiting");
    const brush = c.CreateSolidBrush(stateColor(entry.state));
    const old_pen = c.SelectObject(item.hDC, pen);
    const old_brush = c.SelectObject(item.hDC, if (hollow) c.GetStockObject(c.HOLLOW_BRUSH) else brush);
    _ = c.Ellipse(item.hDC, layout.dot.left, layout.dot.top, layout.dot.right, layout.dot.bottom);
    _ = c.SelectObject(item.hDC, old_brush);
    _ = c.SelectObject(item.hDC, old_pen);
    _ = c.DeleteObject(brush);
    _ = c.DeleteObject(pen);
}

fn childId(value: usize) c.HMENU {
    @setRuntimeSafety(false);
    return @ptrFromInt(value);
}

fn readWindowText(allocator: std.mem.Allocator, hwnd: c.HWND) ![]u8 {
    const length = c.GetWindowTextLengthW(hwnd);
    const wide = try allocator.alloc(u16, @as(usize, @intCast(length)) + 1);
    defer allocator.free(wide);
    const copied = c.GetWindowTextW(hwnd, wide.ptr, length + 1);
    return try std.unicode.utf16LeToUtf8Alloc(allocator, wide[0..@intCast(copied)]);
}

fn utf8ToWideZ(allocator: std.mem.Allocator, value: []const u8) ![:0]u16 {
    const converted = try std.unicode.utf8ToUtf16LeAlloc(allocator, value);
    defer allocator.free(converted);
    const result = try allocator.allocSentinel(u16, converted.len, 0);
    @memcpy(result[0..converted.len], converted);
    return result;
}

fn envFlag(name: []const u8) bool {
    const allocator = std.heap.c_allocator;
    const value = std.process.getEnvVarOwned(allocator, name) catch return false;
    defer allocator.free(value);
    return value.len != 0 and !std.mem.eql(u8, value, "0");
}

test "filter preserves exact ranking and deterministic cross-project order" {
    const entries = [_]Entry{
        .{ .project_path = "A", .project_name = "Alpha", .node_id = "first", .title = "Authentication audit", .loop_type = "turnBased", .state = "idle" },
        .{ .project_path = "B", .project_name = "Beta", .node_id = "auth", .title = "Unrelated", .loop_type = "goalBased", .state = "running" },
        .{ .project_path = "B", .project_name = "Beta", .node_id = "third", .title = "Fix authentication", .loop_type = "proactive", .state = "failed" },
    };
    var state = State.init(std.testing.allocator, &entries);
    defer state.deinit();

    try state.filter("AUTH");
    try std.testing.expectEqual(@as(usize, 1), state.matches.items[0].entry_index);
    try std.testing.expectEqual(@as(u8, 0), state.matches.items[0].score);

    try state.filter("unrelated");
    try std.testing.expectEqual(@as(usize, 1), state.matches.items[0].entry_index);
    try std.testing.expectEqual(@as(u8, 1), state.matches.items[0].score);

    try state.filter("authentication");
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, &.{
        state.matches.items[0].entry_index,
        state.matches.items[1].entry_index,
    });
    try std.testing.expectEqual(@as(u8, 2), state.matches.items[0].score);
    try std.testing.expectEqual(@as(u8, 3), state.matches.items[1].score);

    try state.filter("FIX AUTH");
    try std.testing.expectEqual(@as(usize, 2), state.matches.items[0].entry_index);
    try std.testing.expectEqual(@as(u8, 2), state.matches.items[0].score);
}

test "empty filtering and selection movement wrap safely" {
    const entries = [_]Entry{
        .{ .project_path = "A", .project_name = "Alpha", .node_id = "one", .title = "One", .loop_type = "turnBased", .state = "idle" },
        .{ .project_path = "B", .project_name = "Beta", .node_id = "two", .title = "Two", .loop_type = "goalBased", .state = "running" },
    };
    var state = State.init(std.testing.allocator, &entries);
    defer state.deinit();

    try state.filter(" ");
    try std.testing.expectEqual(@as(usize, 2), state.matches.items.len);
    state.moveSelection(-1);
    try std.testing.expectEqual(@as(usize, 1), state.selection);
    state.moveSelection(1);
    try std.testing.expectEqual(@as(usize, 0), state.selection);
    try state.filter("missing");
    state.moveSelection(1);
    try std.testing.expectEqual(@as(usize, 0), state.selection);
    try std.testing.expect(state.selectedEntry() == null);
}

test "palette parity labels match macOS Main Composite and display states" {
    try std.testing.expectEqualStrings("Main", loopTypeLabel("sketch"));
    try std.testing.expectEqualStrings("Composite", loopTypeLabel("composite"));
    try std.testing.expectEqualStrings("Goal", loopTypeLabel("goalBased"));
    try std.testing.expectEqualStrings("Timed", loopTypeLabel("timeBased"));
    try std.testing.expectEqualStrings("Turn", loopTypeLabel("turnBased"));
    try std.testing.expectEqualStrings("DONE", stateLabel("succeeded"));
    try std.testing.expectEqualStrings("NEEDS YOU", stateLabel("awaitingInput"));
    try std.testing.expectEqualStrings("STOPPED", stateLabel("stopped"));
}

test "palette parity native results retain strings and reserve two-line rows" {
    try registerClass();
    const entries = [_]Entry{
        .{ .project_path = "A", .project_name = "ParityRef", .node_id = "main", .title = "Ref Main", .loop_type = "sketch", .state = "idle" },
    };
    var dialog = Dialog{ .state = State.init(std.testing.allocator, &entries) };
    defer dialog.state.deinit();
    defer releaseDrawingResources(&dialog);
    try dialog.state.filter("");
    active = &dialog;
    defer active = null;
    const hwnd = c.CreateWindowExW(
        0,
        class_name.ptr,
        null,
        c.WS_POPUP,
        0,
        0,
        460,
        380,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.PaletteCreationFailed;
    defer _ = c.DestroyWindow(hwnd);
    try std.testing.expect(c.IsWindowVisible(hwnd) == 0);
    try std.testing.expectEqual(@as(c.LRESULT, 1), c.SendMessageW(dialog.list, c.LB_GETCOUNT, 0, 0));
    try std.testing.expectEqual(@as(c.LRESULT, 42), c.SendMessageW(dialog.list, c.LB_GETITEMHEIGHT, 0, 0));
    // Win32 hides the scrollbar (and its style bit) until the rows overflow.
    for (0..9) |_| {
        const added = c.SendMessageW(dialog.list, c.LB_ADDSTRING, 0, @intCast(@intFromPtr(std.unicode.utf8ToUtf16LeStringLiteral("Overflow test row").ptr)));
        try std.testing.expect(added >= 0);
    }
    _ = c.MoveWindow(dialog.list, 0, field_height, 460, row_height / 2, 0);
    const style = c.GetWindowLongPtrW(dialog.list, c.GWL_STYLE);
    try std.testing.expect(style & c.LBS_OWNERDRAWFIXED != 0);
    try std.testing.expect(style & c.LBS_HASSTRINGS != 0);
    try std.testing.expect(style & c.WS_VSCROLL != 0);
    var buffer: [256]u16 = undefined;
    const length = c.SendMessageW(dialog.list, c.LB_GETTEXT, 0, @intCast(@intFromPtr(&buffer)));
    try std.testing.expect(length > 0);
    const text = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, buffer[0..@intCast(length)]);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Ref Main\nMain · IDLE · ParityRef", text);
    try std.testing.expect(dialog.failure == null);
}

test "palette parity geometry stays below toolbar above footer and bounds every control at each DPI" {
    for ([_]u32{ 96, 120, 144, 192 }) |dpi| {
        for ([_]i32{ 452, 640, 1440 }) |width| {
            const client_width = Dpi.scale(width, dpi);
            const client_height = Dpi.scale(524, dpi);
            const bounds = paletteBounds(client_width, client_height, dpi, 20);
            try std.testing.expect(bounds.left >= 0 and bounds.right <= client_width);
            try std.testing.expect(bounds.top >= Dpi.scale(Tokens.header_height, dpi));
            try std.testing.expect(bounds.bottom <= client_height - Dpi.scale(Tokens.activity_strip_height, dpi));
            const field = fieldLayout(bounds.right - bounds.left, dpi);
            try std.testing.expect(field.magnifier.right <= field.edit.left);
            try std.testing.expect(field.edit.right <= field.hint.left);
            try std.testing.expect(field.hint.right <= bounds.right - bounds.left);
            const row = c.RECT{ .left = 0, .top = 0, .right = bounds.right - bounds.left, .bottom = Dpi.scale(row_height, dpi) };
            const layout = rowLayout(row, dpi);
            try std.testing.expect(layout.bar.right <= layout.title.left);
            try std.testing.expect(layout.title.bottom <= layout.subtitle.top);
            try std.testing.expect(layout.subtitle.right < layout.dot.left);
            try std.testing.expect(layout.dot.right <= row.right);
            try std.testing.expect(layout.subtitle.bottom <= row.bottom);
        }
    }
}

test "palette parity keyboard navigation accepts exact project identity and Escape cancels" {
    const entries = [_]Entry{
        .{ .project_path = "A", .project_name = "Alpha", .node_id = "one", .title = "Same title", .loop_type = "sketch", .state = "idle" },
        .{ .project_path = "B", .project_name = "Beta", .node_id = "two", .title = "Same title", .loop_type = "composite", .state = "running" },
    };
    var dialog = Dialog{ .state = State.init(std.testing.allocator, &entries) };
    defer dialog.state.deinit();
    try dialog.state.filter("");
    try std.testing.expect(handleKey(&dialog, c.VK_UP));
    try std.testing.expectEqual(@as(usize, 1), dialog.state.selection);
    try std.testing.expect(handleKey(&dialog, c.VK_DOWN));
    try std.testing.expectEqual(@as(usize, 0), dialog.state.selection);
    try std.testing.expect(handleKey(&dialog, c.VK_DOWN));
    try std.testing.expect(handleKey(&dialog, c.VK_RETURN));
    try std.testing.expect(dialog.accepted and dialog.closed);
    try std.testing.expectEqualStrings("B", dialog.state.selectedEntry().?.project_path);
    dialog.accepted = false;
    dialog.closed = false;
    try std.testing.expect(handleKey(&dialog, c.VK_ESCAPE));
    try std.testing.expect(dialog.closed and !dialog.accepted);
    dialog.closed = false;
    try dialog.state.filter("no match");
    try std.testing.expect(handleKey(&dialog, c.VK_RETURN));
    try std.testing.expect(!dialog.closed and !dialog.accepted);
    try std.testing.expect(!handleKey(&dialog, 'A'));
}

fn snapshotAllocationCase(allocator: std.mem.Allocator) !void {
    var title = "Ref Main".*;
    const source = [_]Entry{
        .{ .project_path = "A", .project_name = "ParityRef", .node_id = "one", .title = &title, .loop_type = "sketch", .state = "idle" },
        .{ .project_path = "B", .project_name = "Other", .node_id = "two", .title = "Ref Composite", .loop_type = "composite", .state = "running" },
    };
    const snapshot = try copyEntries(allocator, &source);
    defer freeEntries(allocator, snapshot);
    title[0] = 'X';
    try std.testing.expectEqualStrings("Ref Main", snapshot[0].title);
    for (source, snapshot) |entry, copy| {
        inline for (std.meta.fields(Entry)) |field| {
            try std.testing.expect(@field(entry, field.name).ptr != @field(copy, field.name).ptr);
        }
    }
}

test "palette parity owns result strings across daemon refresh and unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, snapshotAllocationCase, .{});
}

test "palette parity native Unicode query survives a UTF-16 surrogate pair" {
    try registerClass();
    const entries = [_]Entry{
        .{ .project_path = "A", .project_name = "ParityRef", .node_id = "unicode", .title = "Emoji 😀", .loop_type = "sketch", .state = "idle" },
    };
    var dialog = Dialog{ .state = State.init(std.testing.allocator, &entries) };
    defer dialog.state.deinit();
    defer releaseDrawingResources(&dialog);
    try dialog.state.filter("");
    active = &dialog;
    defer active = null;
    const hwnd = c.CreateWindowExW(
        0,
        class_name.ptr,
        null,
        c.WS_POPUP,
        0,
        0,
        460,
        380,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.PaletteCreationFailed;
    defer _ = c.DestroyWindow(hwnd);
    _ = c.SendMessageW(dialog.edit, c.WM_CHAR, 0xD83D, 0);
    try std.testing.expect(!dialog.closed);
    accept(&dialog);
    try std.testing.expect(!dialog.accepted and !dialog.closed);
    _ = c.SendMessageW(dialog.edit, c.WM_CHAR, 0xDE00, 0);
    try std.testing.expect(!dialog.closed and dialog.failure == null);
    const query = try readWindowText(std.testing.allocator, dialog.edit);
    defer std.testing.allocator.free(query);
    try std.testing.expectEqualStrings("😀", query);
    try std.testing.expectEqual(@as(usize, 1), dialog.state.matches.items.len);
}
