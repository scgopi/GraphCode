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
    needs_human: bool = false,
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
        self.selection = 0;
        errdefer self.matches.clearRetainingCapacity();
        const trimmed = try trimQuery(raw_query);
        if (trimmed.len == 0) {
            // The rollup is a membership signal, not the sidebar's traversal order.
            for ([_]bool{ true, false }) |attention| {
                for (self.entries, 0..) |entry, index| {
                    if (entry.needs_human == attention) try self.matches.append(.{ .entry_index = index, .score = 0 });
                }
            }
            return;
        }
        const query = try lowercase(self.allocator, trimmed);
        defer self.allocator.free(query);
        const titles = try self.allocator.alloc(?[]u16, self.entries.len);
        @memset(titles, null);
        defer {
            for (titles) |title| if (title) |wide| self.allocator.free(wide);
            self.allocator.free(titles);
        }
        for (self.entries, 0..) |entry, index| {
            titles[index] = try std.unicode.utf8ToUtf16LeAlloc(self.allocator, entry.title);
            const title = try lowercase(self.allocator, entry.title);
            defer self.allocator.free(title);
            const score = (try rank(self.allocator, entry, title, query)) orelse continue;
            try self.matches.append(.{ .entry_index = index, .score = score });
        }
        var comparison_failed = false;
        const Context = struct {
            entries: []const Entry,
            titles: []const ?[]u16,
            failed: *bool,

            fn lessThan(context: @This(), lhs: Match, rhs: Match) bool {
                if (lhs.score != rhs.score) return lhs.score < rhs.score;
                const left = context.entries[lhs.entry_index];
                const right = context.entries[rhs.entry_index];
                if (left.needs_human != right.needs_human) return left.needs_human;
                const a = context.titles[lhs.entry_index].?;
                const b = context.titles[rhs.entry_index].?;
                if (a.len == 0 or b.len == 0) {
                    if (a.len != b.len) return a.len < b.len;
                } else {
                    const order = c.CompareStringEx(null, c.NORM_IGNORECASE, a.ptr, @intCast(a.len), b.ptr, @intCast(b.len), null, null, 0);
                    if (order == 0) context.failed.* = true;
                    if (order == c.CSTR_LESS_THAN) return true;
                    if (order == c.CSTR_GREATER_THAN) return false;
                }
                return lhs.entry_index < rhs.entry_index;
            }
        };
        std.mem.sort(Match, self.matches.items, Context{ .entries = self.entries, .titles = titles, .failed = &comparison_failed }, Context.lessThan);
        if (comparison_failed) return error.PaletteTitleComparisonFailed;
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

pub fn needsHuman(attention_entries: anytype, project_path: []const u8, node_id: []const u8) bool {
    for (attention_entries) |entry| {
        if (std.mem.eql(u8, entry.project_path, project_path) and std.mem.eql(u8, entry.node.id, node_id)) return true;
    }
    return false;
}

fn rank(allocator: std.mem.Allocator, entry: Entry, title: []const u16, query: []const u16) !?u8 {
    if (std.mem.startsWith(u16, title, query)) return 0;
    if (std.mem.indexOf(u16, title, query) != null) return 1;
    const kind = try lowercase(allocator, loopTypeLabel(entry.loop_type));
    defer allocator.free(kind);
    const word = try lowercase(allocator, displayState(entry));
    defer allocator.free(word);
    if (std.mem.indexOf(u16, kind, query) != null or std.mem.indexOf(u16, word, query) != null) return 2;
    const project = try lowercase(allocator, entry.project_name);
    defer allocator.free(project);
    if (std.mem.indexOf(u16, project, query) != null) return 3;
    return null;
}

fn trimQuery(value: []const u8) ![]const u8 {
    var iterator = (try std.unicode.Utf8View.init(value)).iterator();
    var first: ?usize = null;
    var last: usize = 0;
    while (iterator.nextCodepoint()) |scalar| {
        const whitespace = scalar == '\t' or scalar == ' ' or scalar == 0xA0 or scalar == 0x1680 or
            (scalar >= 0x2000 and scalar <= 0x200A) or scalar == 0x202F or scalar == 0x205F or scalar == 0x3000;
        if (!whitespace) {
            if (first == null) first = iterator.i - (std.unicode.utf8CodepointSequenceLength(scalar) catch unreachable);
            last = iterator.i;
        }
    }
    return if (first) |start| value[start..last] else value[0..0];
}

fn lowercase(allocator: std.mem.Allocator, value: []const u8) ![]u16 {
    const wide = try std.unicode.utf8ToUtf16LeAlloc(allocator, value);
    defer allocator.free(wide);
    if (wide.len == 0) return allocator.alloc(u16, 0);
    const invariant = std.unicode.utf8ToUtf16LeStringLiteral("");
    const count = c.LCMapStringEx(invariant.ptr, c.LCMAP_LOWERCASE, wide.ptr, @intCast(wide.len), null, 0, null, null, 0);
    if (count == 0) return error.PaletteCaseMappingFailed;
    const result = try allocator.alloc(u16, @intCast(count));
    errdefer allocator.free(result);
    if (c.LCMapStringEx(invariant.ptr, c.LCMAP_LOWERCASE, wide.ptr, @intCast(wide.len), result.ptr, count, null, null, 0) != count)
        return error.PaletteCaseMappingFailed;
    return result;
}

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeJumpPalette");
const backdrop_class = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeJumpBackdrop");
const scrollbar_class = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeJumpScrollbar");
const scrim_alpha = 102;
const scrollbar_timer = 1;
const scrollbar_thumb = 0x006D6D6D;
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
    list_proc: c.WNDPROC = null,
    scrollbar: c.HWND = null,
    scroll_info: c.SCROLLBARINFO = std.mem.zeroes(c.SCROLLBARINFO),
    scroll_origin: c.POINT = .{ .x = 0, .y = 0 },
    scrollbar_visible: bool = false,
    scrollbar_timer_armed: bool = false,
    scrollbar_disabled: bool = false,
    scrollbar_syncing: bool = false,
    wheel_forwarding: bool = false,
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
    var backdrop = try createBackdrop(parent);
    defer releaseOwnedWindowWith(OwnedWindowApi, &backdrop);
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
    _ = c.ShowWindow(backdrop, c.SW_SHOWNOACTIVATE);
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
    releaseOwnedWindowWith(OwnedWindowApi, &backdrop);
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

const OwnedWindowApi = struct {
    fn isWindow(hwnd: c.HWND) bool {
        return c.IsWindow(hwnd) != 0;
    }

    pub fn destroyWindow(hwnd: c.HWND) void {
        _ = c.DestroyWindow(hwnd);
    }
};

fn releaseOwnedWindowWith(comptime Api: type, owned: *c.HWND) void {
    const hwnd = owned.*;
    owned.* = null;
    if (hwnd != null and Api.isWindow(hwnd)) Api.destroyWindow(hwnd);
}

fn copyEntries(allocator: std.mem.Allocator, source: []const Entry) ![]Entry {
    const entries = try allocator.alloc(Entry, source.len);
    @memset(entries, .{ .project_path = &.{}, .project_name = &.{}, .node_id = &.{}, .title = &.{}, .loop_type = &.{}, .state = &.{} });
    errdefer freeEntries(allocator, entries);
    for (source, entries) |entry, *copy| {
        inline for (std.meta.fields(Entry)) |field| {
            if (field.type == []const u8) {
                @field(copy, field.name) = try allocator.dupe(u8, @field(entry, field.name));
            } else {
                @field(copy, field.name) = @field(entry, field.name);
            }
        }
    }
    return entries;
}

fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |entry| {
        inline for (std.meta.fields(Entry)) |field| {
            if (field.type == []const u8) allocator.free(@field(entry, field.name));
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
    const classes = [_]struct { name: [*:0]const u16, proc: c.WNDPROC }{
        .{ .name = class_name.ptr, .proc = @ptrCast(&windowProc) },
        .{ .name = backdrop_class.ptr, .proc = @ptrCast(&backdropProc) },
        .{ .name = scrollbar_class.ptr, .proc = @ptrCast(&scrollbarProc) },
    };
    for (classes) |class| {
        var window_class: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
        window_class.lpfnWndProc = class.proc;
        window_class.hInstance = c.GetModuleHandleW(null);
        window_class.lpszClassName = class.name;
        window_class.hCursor = c.LoadCursorW(null, Win32.resourceIdentifier(32512));
        if (c.RegisterClassW(&window_class) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS) {
            // Optional decoration creation below reports and latches its own failure.
            if (class.name != scrollbar_class.ptr) return error.PaletteClassRegistrationFailed;
        }
    }
}

fn createBackdrop(owner: c.HWND) !c.HWND {
    var client: c.RECT = undefined;
    if (c.GetClientRect(owner, &client) == 0) return error.PaletteOwnerBoundsUnavailable;
    var origin = c.POINT{ .x = client.left, .y = client.top };
    if (c.ClientToScreen(owner, &origin) == 0) return error.PaletteOwnerBoundsUnavailable;
    return c.CreateWindowExW(
        c.WS_EX_LAYERED | c.WS_EX_NOACTIVATE | c.WS_EX_TOOLWINDOW,
        backdrop_class.ptr,
        null,
        c.WS_POPUP,
        origin.x,
        origin.y,
        client.right - client.left,
        client.bottom - client.top,
        owner,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse error.PaletteBackdropCreationFailed;
}

fn backdropProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (message) {
        c.WM_CREATE => return if (c.SetLayeredWindowAttributes(hwnd, 0, scrim_alpha, c.LWA_ALPHA) != 0) 0 else -1,
        c.WM_MOUSEACTIVATE => return c.MA_NOACTIVATE,
        c.WM_ERASEBKGND => {
            var client: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &client);
            _ = c.FillRect(Win32.opaquePointerFromInt(c.HDC, wparam), &client, Win32.opaquePointerFromInt(c.HBRUSH, @intFromPtr(c.GetStockObject(c.BLACK_BRUSH))));
            return 1;
        },
        c.WM_PAINT => {
            var paint: c.PAINTSTRUCT = undefined;
            const dc = c.BeginPaint(hwnd, &paint);
            defer _ = c.EndPaint(hwnd, &paint);
            _ = c.FillRect(dc, &paint.rcPaint, Win32.opaquePointerFromInt(c.HBRUSH, @intFromPtr(c.GetStockObject(c.BLACK_BRUSH))));
            return 0;
        },
        else => return c.DefWindowProcW(hwnd, message, wparam, lparam),
    }
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
                c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.WS_VSCROLL | c.WS_CLIPSIBLINGS |
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
            // An opaque sibling above the LISTBOX is excluded from the clip of the
            // native nonclient scrollbar, so hover, drag and track painting cannot
            // reach it. WM_NCHITTEST passes input through; scroll state and UIA stay native.
            // WS_EX_TRANSPARENT must not be set: it exempts the sibling from that clip.
            dialog.scrollbar = c.CreateWindowExW(
                c.WS_EX_NOACTIVATE,
                scrollbar_class.ptr,
                null,
                c.WS_CHILD | c.WS_CLIPSIBLINGS,
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
            if (dialog.scrollbar == null) disableScrollbarWith(ScrollbarApi, dialog, error.PaletteScrollLayerCreationFailed);
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
            const previous_list = c.SetWindowLongPtrW(dialog.list, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&listProc)));
            if (previous_list == 0) {
                disableScrollbarWith(ScrollbarApi, dialog, error.PaletteListSubclassFailed);
            } else {
                dialog.list_proc = Win32.opaquePointerFromInt(c.WNDPROC, @bitCast(previous_list));
            }
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
            return @bitCast(@intFromPtr(dialog.background));
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
            // The region precedes every child move so the list and decoration are
            // never laid out beneath a stale clip.
            const radius = Dpi.scale(24, dialog.dpi);
            const region = c.CreateRoundRectRgn(0, 0, client.right + 1, client.bottom + 1, radius, radius);
            if (region != null and c.SetWindowRgn(hwnd, region, 1) == 0) _ = c.DeleteObject(region);
            const layout = fieldLayout(client.right, dialog.dpi);
            move(dialog.magnifier, layout.magnifier);
            move(dialog.edit, layout.edit);
            move(dialog.hint, layout.hint);
            move(dialog.list, .{ .left = 0, .top = Dpi.scale(field_height, dialog.dpi), .right = client.right, .bottom = client.bottom });
            // The list is filled while still zero-height, which leaves it scrolled by a row.
            _ = c.SendMessageW(dialog.list, c.LB_SETTOPINDEX, 0, 0);
            move(dialog.empty_label, .{ .left = Dpi.scale(14, dialog.dpi), .top = Dpi.scale(56, dialog.dpi), .right = client.right - Dpi.scale(14, dialog.dpi), .bottom = client.bottom - Dpi.scale(14, dialog.dpi) });
            return 0;
        },
        // The focused search field and every non-list child pass the wheel up to
        // here; scrolling belongs to the results list.
        c.WM_MOUSEWHEEL => {
            if (dialog.wheel_forwarding) return 0;
            dialog.wheel_forwarding = true;
            defer dialog.wheel_forwarding = false;
            return c.SendMessageW(dialog.list, message, wparam, lparam);
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
    syncScrollbar(dialog);
}

fn listProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const dialog = active orelse return c.DefWindowProcW(hwnd, message, wparam, lparam);
    const result = c.CallWindowProcW(dialog.list_proc, hwnd, message, wparam, lparam);
    if (!dialog.scrollbar_disabled and message == c.WM_PRINT and lparam & c.PRF_NONCLIENT != 0) {
        var info = std.mem.zeroes(c.SCROLLBARINFO);
        info.cbSize = @sizeOf(c.SCROLLBARINFO);
        var window: c.RECT = undefined;
        if (c.GetWindowLongPtrW(hwnd, c.GWL_STYLE) & c.WS_VSCROLL != 0 and
            c.GetScrollBarInfo(hwnd, c.OBJID_VSCROLL, &info) != 0 and c.GetWindowRect(hwnd, &window) != 0)
        {
            const bounds = c.RECT{
                .left = info.rcScrollBar.left - window.left,
                .top = info.rcScrollBar.top - window.top,
                .right = info.rcScrollBar.right - window.left,
                .bottom = info.rcScrollBar.bottom - window.top,
            };
            drawScrollbar(Win32.opaquePointerFromInt(c.HDC, wparam), bounds, info, dialog.dpi);
        }
    }
    switch (message) {
        c.WM_NCPAINT,
        c.WM_PAINT,
        c.WM_NCMOUSEMOVE,
        c.WM_NCLBUTTONDOWN,
        c.WM_NCLBUTTONUP,
        c.WM_NCMOUSELEAVE,
        => syncScrollbarWith(ScrollbarApi, dialog, true),
        c.WM_SIZE,
        c.WM_WINDOWPOSCHANGED,
        c.WM_VSCROLL,
        c.WM_MOUSEWHEEL,
        c.WM_KEYDOWN,
        c.LB_RESETCONTENT,
        c.LB_ADDSTRING,
        c.LB_DELETESTRING,
        c.LB_SETCURSEL,
        c.LB_SETTOPINDEX,
        => syncScrollbar(dialog),
        else => {},
    }
    return result;
}

const ScrollBounds = struct {
    info: c.SCROLLBARINFO,
    origin: c.POINT,
};

const ScrollbarApi = struct {
    fn bounds(list: c.HWND, scrollbar: c.HWND) !?ScrollBounds {
        if (c.IsWindow(list) == 0) return null;
        const style = c.GetWindowLongPtrW(list, c.GWL_STYLE);
        if (style & c.WS_VSCROLL == 0 or style & c.WS_VISIBLE == 0) return null;
        var info = std.mem.zeroes(c.SCROLLBARINFO);
        info.cbSize = @sizeOf(c.SCROLLBARINFO);
        if (c.GetScrollBarInfo(list, c.OBJID_VSCROLL, &info) == 0)
            return error.PaletteScrollBoundsUnavailable;
        var origin = c.POINT{ .x = info.rcScrollBar.left, .y = info.rcScrollBar.top };
        if (c.ScreenToClient(c.GetParent(scrollbar), &origin) == 0)
            return error.PaletteScrollBoundsUnavailable;
        return .{ .info = info, .origin = origin };
    }

    fn position(hwnd: c.HWND, bounds_value: ScrollBounds) !void {
        const rect = bounds_value.info.rcScrollBar;
        if (c.SetWindowPos(hwnd, c.HWND_TOP, bounds_value.origin.x, bounds_value.origin.y, rect.right - rect.left, rect.bottom - rect.top, c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW) == 0)
            return error.PaletteScrollLayerPositionFailed;
    }

    fn armTimer(hwnd: c.HWND) !void {
        if (c.SetTimer(hwnd, scrollbar_timer, 33, null) == 0) return error.PaletteScrollTimerFailed;
    }

    fn killTimer(hwnd: c.HWND) void {
        _ = c.KillTimer(hwnd, scrollbar_timer);
    }

    fn hide(hwnd: c.HWND) void {
        _ = c.ShowWindow(hwnd, c.SW_HIDE);
    }

    fn invalidate(hwnd: c.HWND) !void {
        if (c.InvalidateRect(hwnd, null, 0) == 0) return error.PaletteScrollInvalidationFailed;
    }

    fn update(hwnd: c.HWND) !void {
        if (c.UpdateWindow(hwnd) == 0) return error.PaletteScrollUpdateFailed;
    }

    fn warning(err: anyerror) void {
        std.log.warn("Jump palette dark decoration unavailable: {s}; native scrolling retained", .{@errorName(err)});
    }
};

fn syncScrollbar(dialog: *Dialog) void {
    syncScrollbarWith(ScrollbarApi, dialog, false);
}

fn syncScrollbarWith(comptime Api: type, dialog: *Dialog, force_repaint: bool) void {
    if (dialog.scrollbar == null or dialog.scrollbar_disabled or dialog.scrollbar_syncing) return;
    dialog.scrollbar_syncing = true;
    defer dialog.scrollbar_syncing = false;
    const bounds_value = (Api.bounds(dialog.list, dialog.scrollbar) catch |err| {
        disableScrollbarWith(Api, dialog, err);
        return;
    }) orelse {
        if (dialog.scrollbar_timer_armed) {
            dialog.scrollbar_timer_armed = false;
            Api.killTimer(dialog.scrollbar);
        }
        if (dialog.scrollbar_visible) {
            dialog.scrollbar_visible = false;
            Api.hide(dialog.scrollbar);
        }
        return;
    };
    const rect = bounds_value.info.rcScrollBar;
    const previous_rect = dialog.scroll_info.rcScrollBar;
    const moved = !dialog.scrollbar_visible or !std.meta.eql(dialog.scroll_origin, bounds_value.origin) or
        rect.right - rect.left != previous_rect.right - previous_rect.left or
        rect.bottom - rect.top != previous_rect.bottom - previous_rect.top;
    const changed = !std.meta.eql(dialog.scroll_info, bounds_value.info);
    dialog.scroll_info = bounds_value.info;
    dialog.scroll_origin = bounds_value.origin;
    if (moved) Api.position(dialog.scrollbar, bounds_value) catch |err| {
        disableScrollbarWith(Api, dialog, err);
        return;
    };
    dialog.scrollbar_visible = true;
    // Runs throughout each visible interval, including native scrollbar tracking.
    if (!dialog.scrollbar_timer_armed) {
        Api.armTimer(dialog.scrollbar) catch |err| {
            disableScrollbarWith(Api, dialog, err);
            return;
        };
        dialog.scrollbar_timer_armed = true;
    }
    if (changed or moved or force_repaint) {
        Api.invalidate(dialog.scrollbar) catch |err| {
            disableScrollbarWith(Api, dialog, err);
            return;
        };
        Api.update(dialog.scrollbar) catch |err| {
            disableScrollbarWith(Api, dialog, err);
            return;
        };
    }
}

fn disableScrollbarWith(comptime Api: type, dialog: *Dialog, err: anyerror) void {
    if (dialog.scrollbar_disabled) return;
    dialog.scrollbar_disabled = true;
    if (dialog.scrollbar_timer_armed) {
        dialog.scrollbar_timer_armed = false;
        Api.killTimer(dialog.scrollbar);
    }
    dialog.scrollbar_visible = false;
    if (dialog.scrollbar != null) Api.hide(dialog.scrollbar);
    Api.warning(err);
}

test "palette robustness backdrop releases once before modal teardown despite recycled handle" {
    const Api = struct {
        const Call = enum { backdrop, enable, palette, activate };
        var calls: std.array_list.Managed(Call) = undefined;
        var owned: *c.HWND = undefined;
        var cleared_at_destroy = false;

        fn isWindow(_: c.HWND) bool {
            return true;
        }
        pub fn destroyWindow(hwnd: c.HWND) void {
            if (@intFromPtr(hwnd) == 0x2000) {
                cleared_at_destroy = owned.* == null;
                calls.append(.backdrop) catch unreachable;
            } else calls.append(.palette) catch unreachable;
        }
        pub fn enableWindow(_: c.HWND, _: c_int) void {
            calls.append(.enable) catch unreachable;
        }
        pub fn setActiveWindow(_: c.HWND) void {
            calls.append(.activate) catch unreachable;
        }
    };
    Api.calls = std.array_list.Managed(Api.Call).init(std.testing.allocator);
    defer Api.calls.deinit();
    var owned = Win32.opaquePointerFromInt(c.HWND, 0x2000);
    Api.owned = &owned;
    releaseOwnedWindowWith(Api, &owned);
    ModalTeardown.dismissWith(Api, Win32.opaquePointerFromInt(c.HWND, 0x3000), Win32.opaquePointerFromInt(c.HWND, 0x1000));
    releaseOwnedWindowWith(Api, &owned);
    try std.testing.expectEqualSlices(Api.Call, &.{ .backdrop, .enable, .palette, .activate }, Api.calls.items);
    try std.testing.expect(Api.cleared_at_destroy);
    try std.testing.expect(owned == null);
}

const RecordingScrollbarApi = struct {
    const Failure = enum { bounds, position, timer, invalidate, update };
    var failure: ?Failure = null;
    var visible = true;
    var queries: usize = 0;
    var positions: usize = 0;
    var arms: usize = 0;
    var kills: usize = 0;
    var hides: usize = 0;
    var invalidations: usize = 0;
    var updates: usize = 0;
    var warnings: usize = 0;
    var reenter: ?*Dialog = null;

    fn reset() void {
        failure = null;
        visible = true;
        queries = 0;
        positions = 0;
        arms = 0;
        kills = 0;
        hides = 0;
        invalidations = 0;
        updates = 0;
        warnings = 0;
        reenter = null;
    }
    fn bounds(_: c.HWND, _: c.HWND) !?ScrollBounds {
        queries += 1;
        if (failure == .bounds) return error.InjectedDecorationFailure;
        if (!visible) return null;
        var info = std.mem.zeroes(c.SCROLLBARINFO);
        info.rcScrollBar = .{ .left = 443, .top = 42, .right = 460, .bottom = 378 };
        info.xyThumbTop = 17;
        info.xyThumbBottom = 100;
        return .{ .info = info, .origin = .{ .x = 443, .y = 42 } };
    }
    fn position(_: c.HWND, _: ScrollBounds) !void {
        positions += 1;
        if (failure == .position) return error.InjectedDecorationFailure;
    }
    fn armTimer(_: c.HWND) !void {
        arms += 1;
        if (failure == .timer) return error.InjectedDecorationFailure;
    }
    fn killTimer(_: c.HWND) void {
        kills += 1;
    }
    fn hide(_: c.HWND) void {
        hides += 1;
    }
    fn invalidate(_: c.HWND) !void {
        invalidations += 1;
        if (failure == .invalidate) return error.InjectedDecorationFailure;
    }
    fn update(_: c.HWND) !void {
        updates += 1;
        if (failure == .update) return error.InjectedDecorationFailure;
        if (reenter) |dialog| {
            reenter = null;
            syncScrollbarWith(@This(), dialog, true);
        }
    }
    fn warning(_: anyerror) void {
        warnings += 1;
    }
};

test "palette robustness scrollbar timer and placement follow visible transitions only" {
    const Api = RecordingScrollbarApi;
    Api.reset();
    var dialog = Dialog{ .state = State.init(std.testing.allocator, &.{}), .scrollbar = Win32.opaquePointerFromInt(c.HWND, 0x2000) };
    defer dialog.state.deinit();
    syncScrollbarWith(Api, &dialog, false);
    syncScrollbarWith(Api, &dialog, false);
    syncScrollbarWith(Api, &dialog, false);
    try std.testing.expectEqual(@as(usize, 1), Api.arms);
    try std.testing.expectEqual(@as(usize, 1), Api.positions);
    try std.testing.expect(dialog.scrollbar_timer_armed);
    Api.visible = false;
    syncScrollbarWith(Api, &dialog, false);
    syncScrollbarWith(Api, &dialog, false);
    try std.testing.expectEqual(@as(usize, 1), Api.kills);
    try std.testing.expectEqual(@as(usize, 1), Api.hides);
    try std.testing.expect(!dialog.scrollbar_timer_armed);
    Api.visible = true;
    syncScrollbarWith(Api, &dialog, false);
    try std.testing.expectEqual(@as(usize, 2), Api.arms);
    try std.testing.expectEqual(@as(usize, 2), Api.positions);
}

test "palette robustness unchanged nonclient geometry still repaints synchronously without recursion" {
    const Api = RecordingScrollbarApi;
    Api.reset();
    var dialog = Dialog{ .state = State.init(std.testing.allocator, &.{}), .scrollbar = Win32.opaquePointerFromInt(c.HWND, 0x2000) };
    defer dialog.state.deinit();
    syncScrollbarWith(Api, &dialog, false);
    const previous_invalidations = Api.invalidations;
    const previous_updates = Api.updates;
    const previous_queries = Api.queries;
    Api.reenter = &dialog;
    syncScrollbarWith(Api, &dialog, true);
    try std.testing.expectEqual(previous_invalidations + 1, Api.invalidations);
    try std.testing.expectEqual(previous_updates + 1, Api.updates);
    try std.testing.expectEqual(previous_queries + 1, Api.queries);
    try std.testing.expectEqual(@as(usize, 1), Api.positions);
    try std.testing.expectEqual(@as(usize, 1), Api.arms);
}

test "palette robustness cosmetic failures warn latch disable and retain functional selection" {
    const Api = RecordingScrollbarApi;
    for (std.enums.values(Api.Failure)) |failure| {
        Api.reset();
        Api.failure = failure;
        const entries = [_]Entry{.{ .project_path = "A", .project_name = "Alpha", .node_id = "one", .title = "One", .loop_type = "sketch", .state = "idle" }};
        var dialog = Dialog{ .state = State.init(std.testing.allocator, &entries), .scrollbar = Win32.opaquePointerFromInt(c.HWND, 0x2000) };
        defer dialog.state.deinit();
        try dialog.state.filter("");
        syncScrollbarWith(Api, &dialog, true);
        try std.testing.expect(!dialog.closed and dialog.failure == null);
        try std.testing.expect(dialog.scrollbar_disabled and !dialog.scrollbar_timer_armed and !dialog.scrollbar_visible);
        try std.testing.expectEqual(@as(usize, 1), Api.warnings);
        try std.testing.expectEqual(@as(usize, 1), Api.hides);
        try std.testing.expectEqual(@as(usize, if (failure == .invalidate or failure == .update) 1 else 0), Api.kills);
        const queries = Api.queries;
        syncScrollbarWith(Api, &dialog, true);
        try std.testing.expectEqual(queries, Api.queries);
        try std.testing.expectEqual(@as(usize, 1), Api.warnings);
        accept(&dialog);
        try std.testing.expect(dialog.accepted);
        try std.testing.expectEqualStrings("one", dialog.state.selectedEntry().?.node_id);
    }
}

test "palette robustness late decoration failure stops the existing visible timer once" {
    const Api = RecordingScrollbarApi;
    Api.reset();
    var dialog = Dialog{ .state = State.init(std.testing.allocator, &.{}), .scrollbar = Win32.opaquePointerFromInt(c.HWND, 0x2000) };
    defer dialog.state.deinit();
    syncScrollbarWith(Api, &dialog, false);
    try std.testing.expect(dialog.scrollbar_timer_armed);
    Api.failure = .bounds;
    syncScrollbarWith(Api, &dialog, false);
    const queries = Api.queries;
    Api.failure = null;
    syncScrollbarWith(Api, &dialog, true);
    try std.testing.expect(!dialog.closed and dialog.failure == null);
    try std.testing.expect(dialog.scrollbar_disabled and !dialog.scrollbar_visible and !dialog.scrollbar_timer_armed);
    try std.testing.expectEqual(@as(usize, 1), Api.arms);
    try std.testing.expectEqual(@as(usize, 1), Api.kills);
    try std.testing.expectEqual(@as(usize, 1), Api.hides);
    try std.testing.expectEqual(@as(usize, 1), Api.warnings);
    try std.testing.expectEqual(queries, Api.queries);
}

fn scrollbarProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (message) {
        c.WM_NCHITTEST => return c.HTTRANSPARENT,
        c.WM_MOUSEACTIVATE => return c.MA_NOACTIVATE,
        c.WM_ERASEBKGND => return 1,
        c.WM_TIMER => {
            if (active) |dialog| {
                if (wparam == scrollbar_timer and dialog.scrollbar_timer_armed) syncScrollbar(dialog);
            }
            return 0;
        },
        c.WM_NCDESTROY => {
            if (active) |dialog| {
                if (dialog.scrollbar == hwnd) {
                    dialog.scrollbar = null;
                    dialog.scrollbar_visible = false;
                    dialog.scrollbar_timer_armed = false;
                }
            }
            return c.DefWindowProcW(hwnd, message, wparam, lparam);
        },
        c.WM_PAINT => {
            var paint: c.PAINTSTRUCT = undefined;
            const dc = c.BeginPaint(hwnd, &paint);
            defer _ = c.EndPaint(hwnd, &paint);
            if (active) |dialog| {
                if (!dialog.scrollbar_disabled) {
                    var client: c.RECT = undefined;
                    _ = c.GetClientRect(hwnd, &client);
                    drawScrollbar(dc, client, dialog.scroll_info, dialog.dpi);
                }
            }
            return 0;
        },
        c.WM_PRINTCLIENT => {
            if (active) |dialog| {
                if (!dialog.scrollbar_disabled) {
                    var client: c.RECT = undefined;
                    _ = c.GetClientRect(hwnd, &client);
                    drawScrollbar(Win32.opaquePointerFromInt(c.HDC, wparam), client, dialog.scroll_info, dialog.dpi);
                }
            }
            return 0;
        },
        else => return c.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

fn scrollbarThumb(bounds: c.RECT, info: c.SCROLLBARINFO, dpi: u32) c.RECT {
    const width = @min(@max(0, bounds.right - bounds.left), Dpi.scale(6, dpi));
    const left = bounds.left + @divTrunc(bounds.right - bounds.left - width, 2);
    return .{
        .left = left,
        .top = std.math.clamp(bounds.top + info.xyThumbTop, bounds.top, bounds.bottom),
        .right = left + width,
        .bottom = std.math.clamp(bounds.top + info.xyThumbBottom, bounds.top, bounds.bottom),
    };
}

fn drawScrollbar(dc: c.HDC, bounds: c.RECT, info: c.SCROLLBARINFO, dpi: u32) void {
    fill(dc, bounds, Tokens.window_tone);
    const thumb = scrollbarThumb(bounds, info, dpi);
    if (thumb.bottom > thumb.top) {
        const brush = c.CreateSolidBrush(scrollbar_thumb);
        defer _ = c.DeleteObject(brush);
        const old_brush = c.SelectObject(dc, brush);
        defer _ = c.SelectObject(dc, old_brush);
        const old_pen = c.SelectObject(dc, c.GetStockObject(c.NULL_PEN));
        defer _ = c.SelectObject(dc, old_pen);
        const radius = @max(1, thumb.right - thumb.left);
        _ = c.RoundRect(dc, thumb.left, thumb.top, thumb.right, thumb.bottom, radius, radius);
    }
    const pen = c.CreatePen(c.PS_SOLID, @max(1, Dpi.scale(1, dpi)), scrollbar_thumb);
    defer _ = c.DeleteObject(pen);
    const old_pen = c.SelectObject(dc, pen);
    defer _ = c.SelectObject(dc, old_pen);
    const center = bounds.left + @divTrunc(bounds.right - bounds.left, 2);
    const half = @min(Dpi.scale(3, dpi), @divTrunc(bounds.right - bounds.left, 3));
    const top = bounds.top + @divTrunc(info.dxyLineButton, 2);
    const bottom = bounds.bottom - @divTrunc(info.dxyLineButton, 2);
    _ = c.MoveToEx(dc, center - half, top + half, null);
    _ = c.LineTo(dc, center, top);
    _ = c.LineTo(dc, center + half + 1, top + half + 1);
    _ = c.MoveToEx(dc, center - half, bottom - half, null);
    _ = c.LineTo(dc, center, bottom);
    _ = c.LineTo(dc, center + half + 1, bottom - half - 1);
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
    const available_top = Dpi.scale(Tokens.header_height, dpi) + margin;
    const available_bottom = @max(available_top, height - Dpi.scale(Tokens.activity_strip_height, dpi) - margin);
    const palette_width = @max(0, @min(Dpi.scale(460, dpi), width - 2 * margin));
    const desired_height = Dpi.scale(field_height + row_height * @as(i32, @intCast(@min(8, @max(1, count)))), dpi);
    const palette_height = @min(Dpi.scale(380, dpi), @min(desired_height, available_bottom - available_top));
    const left = @divTrunc(width - palette_width, 2);
    const top = std.math.clamp(@divTrunc(height - palette_height, 2), available_top, available_bottom - palette_height);
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

test "palette residual ranking follows macOS prefix substring attribute project without ID search" {
    const entries = [_]Entry{
        .{ .project_path = "A", .project_name = "Alpha", .node_id = "first", .title = "Authentication audit", .loop_type = "turnBased", .state = "idle" },
        .{ .project_path = "B", .project_name = "Beta", .node_id = "auth", .title = "Unrelated", .loop_type = "goalBased", .state = "running" },
        .{ .project_path = "B", .project_name = "Beta", .node_id = "third", .title = "Fix authentication", .loop_type = "proactive", .state = "failed" },
        .{ .project_path = "C", .project_name = "Authentication", .node_id = "fourth", .title = "Nothing", .loop_type = "timeBased", .state = "idle" },
    };
    var state = State.init(std.testing.allocator, &entries);
    defer state.deinit();

    try state.filter("AUTH");
    try std.testing.expectEqual(@as(usize, 3), state.matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.matches.items[0].entry_index);
    try std.testing.expectEqual(@as(usize, 2), state.matches.items[1].entry_index);
    try std.testing.expectEqual(@as(usize, 3), state.matches.items[2].entry_index);

    try state.filter("unrelated");
    try std.testing.expectEqual(@as(usize, 1), state.matches.items[0].entry_index);
    try std.testing.expectEqual(@as(u8, 0), state.matches.items[0].score);

    try state.filter("authentication");
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, &.{
        state.matches.items[0].entry_index,
        state.matches.items[1].entry_index,
    });
    try std.testing.expectEqual(@as(u8, 0), state.matches.items[0].score);
    try std.testing.expectEqual(@as(u8, 1), state.matches.items[1].score);

    try state.filter("FIX AUTH");
    try std.testing.expectEqual(@as(usize, 2), state.matches.items[0].entry_index);
    try std.testing.expectEqual(@as(u8, 0), state.matches.items[0].score);
    try state.filter("timed");
    try std.testing.expectEqual(@as(usize, 3), state.matches.items[0].entry_index);
    try state.filter("scheduled");
    try std.testing.expectEqual(@as(usize, 3), state.matches.items[0].entry_index);
    try state.filter("running");
    try std.testing.expectEqual(@as(usize, 1), state.matches.items[0].entry_index);
    try state.filter("third");
    try std.testing.expectEqual(@as(usize, 0), state.matches.items.len);
}

test "palette residual empty query stably partitions rollup attention across projects not raw states" {
    const entries = [_]Entry{
        .{ .project_path = "A", .project_name = "Alpha", .node_id = "quiet", .title = "ZZZ quiet", .loop_type = "sketch", .state = "awaitingInput" },
        .{ .project_path = "A", .project_name = "Alpha", .node_id = "done", .title = "ZZZ done", .loop_type = "goalBased", .state = "succeeded", .needs_human = true },
        .{ .project_path = "B", .project_name = "Beta", .node_id = "waiting", .title = "AAA waiting", .loop_type = "turnBased", .state = "waiting", .needs_human = true },
        .{ .project_path = "B", .project_name = "Beta", .node_id = "other", .title = "AAA quiet", .loop_type = "sketch", .state = "idle" },
    };
    var state = State.init(std.testing.allocator, &entries);
    defer state.deinit();
    try state.filter("  ");
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 0, 3 }, &.{
        state.matches.items[0].entry_index, state.matches.items[1].entry_index,
        state.matches.items[2].entry_index, state.matches.items[3].entry_index,
    });
}

test "palette residual query rank precedes attention then localized title ties" {
    const entries = [_]Entry{
        .{ .project_path = "A", .project_name = "Match folder", .node_id = "1", .title = "ZZZ match", .loop_type = "sketch", .state = "idle", .needs_human = true },
        .{ .project_path = "A", .project_name = "Match folder", .node_id = "2", .title = "Match exact", .loop_type = "sketch", .state = "idle" },
        .{ .project_path = "A", .project_name = "Match folder", .node_id = "3", .title = "delta match", .loop_type = "sketch", .state = "idle" },
        .{ .project_path = "A", .project_name = "Match folder", .node_id = "4", .title = "Alpha match", .loop_type = "sketch", .state = "idle" },
        .{ .project_path = "A", .project_name = "Match folder", .node_id = "5", .title = "Zulu match", .loop_type = "sketch", .state = "idle" },
        .{ .project_path = "A", .project_name = "Match folder", .node_id = "6", .title = "Éclair match", .loop_type = "sketch", .state = "idle" },
    };
    var state = State.init(std.testing.allocator, &entries);
    defer state.deinit();
    try state.filter("match");
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 3, 2, 5, 4 }, &.{
        state.matches.items[0].entry_index, state.matches.items[1].entry_index,
        state.matches.items[2].entry_index, state.matches.items[3].entry_index,
        state.matches.items[4].entry_index, state.matches.items[5].entry_index,
    });
    try state.filter("  éCLAIR  ");
    try std.testing.expectEqual(@as(usize, 1), state.matches.items.len);
    try std.testing.expectEqual(@as(usize, 5), state.matches.items[0].entry_index);
}

test "palette residual exact title shares prefix rank with attention and Unicode project matches" {
    const entries = [_]Entry{
        .{ .project_path = "A", .project_name = "Ångström", .node_id = "same", .title = "Match", .loop_type = "sketch", .state = "idle" },
        .{ .project_path = "B", .project_name = "Other", .node_id = "same", .title = "Match suffix", .loop_type = "turnBased", .state = "waiting", .needs_human = true },
    };
    var state = State.init(std.testing.allocator, &entries);
    defer state.deinit();
    try state.filter("\u{2003}MATCH\u{A0}");
    try std.testing.expectEqual(@as(usize, 2), state.matches.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.matches.items[0].entry_index);
    try std.testing.expectEqual(@as(u8, 0), state.matches.items[0].score);
    try std.testing.expectEqual(@as(u8, 0), state.matches.items[1].score);
    try state.filter("ÅNG");
    try std.testing.expectEqual(@as(usize, 1), state.matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.matches.items[0].entry_index);
    try std.testing.expectEqual(@as(u8, 3), state.matches.items[0].score);
}

test "palette residual waiting and DONE attention use exact project and node membership" {
    const Attention = struct { project_path: []const u8, node: struct { id: []const u8 } };
    const attention = [_]Attention{
        .{ .project_path = "B", .node = .{ .id = "shared" } },
        .{ .project_path = "A", .node = .{ .id = "done" } },
    };
    var entries = [_]Entry{
        .{ .project_path = "A", .project_name = "Alpha", .node_id = "shared", .title = "Quiet same ID", .loop_type = "sketch", .state = "awaitingInput" },
        .{ .project_path = "A", .project_name = "Alpha", .node_id = "done", .title = "Done needs human", .loop_type = "goalBased", .state = "succeeded" },
        .{ .project_path = "B", .project_name = "Beta", .node_id = "shared", .title = "Waiting needs human", .loop_type = "turnBased", .state = "waiting" },
    };
    for (&entries) |*entry| entry.needs_human = needsHuman(&attention, entry.project_path, entry.node_id);
    try std.testing.expect(!needsHuman(&attention, "b", "shared"));
    try std.testing.expect(!needsHuman(&attention, "B", "Shared"));
    var state = State.init(std.testing.allocator, &entries);
    defer state.deinit();
    try state.filter("");
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 0 }, &.{
        state.matches.items[0].entry_index, state.matches.items[1].entry_index, state.matches.items[2].entry_index,
    });
    try std.testing.expectEqualStrings("DONE", displayState(state.selectedEntry().?));
    try state.filter("waiting");
    try std.testing.expectEqual(@as(usize, 2), state.matches.items[0].entry_index);
}

fn filterAllocationCase(allocator: std.mem.Allocator) !void {
    const entries = [_]Entry{
        .{ .project_path = "A", .project_name = "Match", .node_id = "one", .title = "Éclair match", .loop_type = "sketch", .state = "idle" },
        .{ .project_path = "B", .project_name = "Match", .node_id = "two", .title = "Zulu match", .loop_type = "turnBased", .state = "waiting" },
        .{ .project_path = "C", .project_name = "Match", .node_id = "three", .title = "Other", .loop_type = "goalBased", .state = "succeeded" },
    };
    var state = State.init(allocator, &entries);
    defer state.deinit();
    try state.filter("match");
    try std.testing.expectEqual(@as(usize, 3), state.matches.items.len);
    try state.filter("");
    try std.testing.expectEqual(@as(usize, 3), state.matches.items.len);
}

test "palette residual Unicode filtering unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, filterAllocationCase, .{});
}

test "palette residual bounds match window centered 750 reference and clamp small owners" {
    for ([_]u32{ 96, 120, 144, 192 }) |dpi| {
        const bounds = paletteBounds(Dpi.scale(1440, dpi), Dpi.scale(900, dpi), dpi, 8);
        try std.testing.expect(@abs(bounds.left - Dpi.scale(490, dpi)) <= 1);
        try std.testing.expect(@abs(bounds.top - Dpi.scale(261, dpi)) <= 1);
        try std.testing.expect(@abs(bounds.right - Dpi.scale(950, dpi)) <= 1);
        try std.testing.expect(@abs(bounds.bottom - Dpi.scale(639, dpi)) <= 1);
        try std.testing.expect(@abs(bounds.top + bounds.bottom - Dpi.scale(900, dpi)) <= 1);
        try std.testing.expect(@abs(bounds.left + bounds.right - Dpi.scale(1440, dpi)) <= 1);
        const small = paletteBounds(Dpi.scale(452, dpi), Dpi.scale(300, dpi), dpi, 12);
        try std.testing.expect(small.top >= Dpi.scale(Tokens.header_height, dpi));
        try std.testing.expect(small.bottom <= Dpi.scale(300 - Tokens.activity_strip_height, dpi));
    }
}

test "palette residual overflow paints a dark native scroll track after scrolling" {
    try registerClass();
    var dialog = Dialog{ .state = State.init(std.testing.allocator, &.{}) };
    defer dialog.state.deinit();
    defer releaseDrawingResources(&dialog);
    try dialog.state.filter("");
    active = &dialog;
    defer active = null;
    const hwnd = c.CreateWindowExW(0, class_name.ptr, null, c.WS_POPUP, 0, 0, 460, 380, null, null, c.GetModuleHandleW(null), null) orelse return error.PaletteCreationFailed;
    defer _ = c.DestroyWindow(hwnd);
    try std.testing.expect(c.IsWindowVisible(hwnd) == 0);
    for (0..12) |_| {
        try std.testing.expect(c.SendMessageW(dialog.list, c.LB_ADDSTRING, 0, @intCast(@intFromPtr(std.unicode.utf8ToUtf16LeStringLiteral("Overflow row").ptr))) >= 0);
    }
    _ = c.MoveWindow(dialog.list, 0, field_height, 460, 8 * row_height, 0);
    _ = c.ShowWindow(dialog.list, c.SW_SHOW);
    syncScrollbar(&dialog);
    try std.testing.expect(c.IsWindowVisible(hwnd) == 0);
    try std.testing.expect(c.IsWindowVisible(dialog.scrollbar) == 0);
    try std.testing.expectEqual(@as(c.LRESULT, c.HTTRANSPARENT), c.SendMessageW(dialog.scrollbar, c.WM_NCHITTEST, 0, 0));
    try std.testing.expect(c.GetWindowLongPtrW(dialog.scrollbar, c.GWL_STYLE) & c.WS_TABSTOP == 0);
    try std.testing.expect(c.GetWindowLongPtrW(dialog.list, c.GWL_STYLE) & c.WS_CLIPSIBLINGS != 0);
    const dc = c.GetDC(hwnd);
    defer _ = c.ReleaseDC(hwnd, dc);
    const memory = c.CreateCompatibleDC(dc) orelse return error.TestDCUnavailable;
    defer _ = c.DeleteDC(memory);
    const bitmap = c.CreateCompatibleBitmap(dc, 460, 380) orelse return error.TestBitmapUnavailable;
    defer _ = c.DeleteObject(bitmap);
    const old_bitmap = c.SelectObject(memory, bitmap);
    defer _ = c.SelectObject(memory, old_bitmap);
    for ([_]c.WPARAM{ 0, 3, 4 }) |top| {
        _ = c.SendMessageW(dialog.list, c.LB_SETTOPINDEX, top, 0);
        var info = std.mem.zeroes(c.SCROLLBARINFO);
        info.cbSize = @sizeOf(c.SCROLLBARINFO);
        try std.testing.expect(c.GetScrollBarInfo(dialog.list, c.OBJID_VSCROLL, &info) != 0);
        var window: c.RECT = undefined;
        try std.testing.expect(c.GetWindowRect(dialog.list, &window) != 0);
        _ = c.SendMessageW(dialog.list, c.WM_PRINT, @intFromPtr(memory), c.PRF_NONCLIENT | c.PRF_CLIENT | c.PRF_ERASEBKGND);
        const x = info.rcScrollBar.left - window.left + 1;
        const y = info.rcScrollBar.top - window.top + info.dxyLineButton + 1;
        try std.testing.expectEqual(Tokens.window_tone, c.GetPixel(memory, x, y));
        for (@as(usize, @intCast(info.rcScrollBar.top - window.top))..@as(usize, @intCast(info.rcScrollBar.bottom - window.top))) |py| {
            for (@as(usize, @intCast(info.rcScrollBar.left - window.left))..@as(usize, @intCast(info.rcScrollBar.right - window.left))) |px| {
                const pixel = c.GetPixel(memory, @intCast(px), @intCast(py));
                try std.testing.expect(pixel == Tokens.window_tone or pixel == scrollbar_thumb);
            }
        }
        var cosmetic: c.RECT = undefined;
        try std.testing.expect(c.GetWindowRect(dialog.scrollbar, &cosmetic) != 0);
        try std.testing.expectEqualDeep(info.rcScrollBar, cosmetic);
        const thumb = scrollbarThumb(.{ .left = 0, .top = 0, .right = cosmetic.right - cosmetic.left, .bottom = cosmetic.bottom - cosmetic.top }, info, dialog.dpi);
        try std.testing.expect(thumb.top >= info.dxyLineButton);
        try std.testing.expect(thumb.bottom <= cosmetic.bottom - cosmetic.top - info.dxyLineButton);
        _ = c.SendMessageW(dialog.scrollbar, c.WM_PRINTCLIENT, @intFromPtr(memory), 0);
        try std.testing.expectEqual(Tokens.window_tone, c.GetPixel(memory, 1, info.dxyLineButton + 1));
        try std.testing.expectEqual(@as(c.COLORREF, scrollbar_thumb), c.GetPixel(memory, @divTrunc(thumb.left + thumb.right, 2), @divTrunc(thumb.top + thumb.bottom, 2)));
        var scroll = std.mem.zeroes(c.SCROLLINFO);
        scroll.cbSize = @sizeOf(c.SCROLLINFO);
        scroll.fMask = c.SIF_ALL;
        try std.testing.expect(c.GetScrollInfo(dialog.list, c.SB_VERT, &scroll) != 0);
        try std.testing.expectEqual(@as(c.INT, @intCast(top)), scroll.nPos);
        try std.testing.expectEqual(@as(c.UINT, 8), scroll.nPage);
        try std.testing.expect(c.GetWindowLongPtrW(dialog.list, c.GWL_STYLE) & c.WS_VSCROLL != 0);
    }
    try std.testing.expect(dialog.failure == null);
}

fn overflowTestEntries() [12]Entry {
    var entries: [12]Entry = undefined;
    for (&entries) |*entry| entry.* = .{ .project_path = "A", .project_name = "Alpha", .node_id = "row", .title = "Overflow row", .loop_type = "sketch", .state = "idle" };
    return entries;
}

test "palette residual overflow at creation decorates the production list without latching it off" {
    try registerClass();
    var entries = overflowTestEntries();
    var dialog = Dialog{ .state = State.init(std.testing.allocator, &entries) };
    defer dialog.state.deinit();
    defer releaseDrawingResources(&dialog);
    try dialog.state.filter("");
    active = &dialog;
    defer active = null;
    const hwnd = c.CreateWindowExW(0, class_name.ptr, null, c.WS_POPUP | c.WS_CLIPCHILDREN, 0, 0, 460, 380, null, null, c.GetModuleHandleW(null), null) orelse return error.PaletteCreationFailed;
    defer _ = c.DestroyWindow(hwnd);
    try std.testing.expect(c.IsWindowVisible(hwnd) == 0);
    try std.testing.expectEqual(@as(c.LRESULT, 12), c.SendMessageW(dialog.list, c.LB_GETCOUNT, 0, 0));
    try std.testing.expect(dialog.failure == null and !dialog.scrollbar_disabled);
    try std.testing.expect(dialog.scrollbar_visible and dialog.scrollbar_timer_armed);
    var info = std.mem.zeroes(c.SCROLLBARINFO);
    info.cbSize = @sizeOf(c.SCROLLBARINFO);
    try std.testing.expect(c.GetScrollBarInfo(dialog.list, c.OBJID_VSCROLL, &info) != 0);
    var strip: c.RECT = undefined;
    try std.testing.expect(c.GetWindowRect(dialog.scrollbar, &strip) != 0);
    try std.testing.expectEqualDeep(info.rcScrollBar, strip);
    try std.testing.expect(strip.right - strip.left > 0 and strip.bottom - strip.top > 0);
    try std.testing.expect(c.GetWindowLongPtrW(dialog.scrollbar, c.GWL_STYLE) & c.WS_VISIBLE != 0);
    // The strip reaches the palette's rounded bottom-right corner, so the owner region must clip it.
    const region = c.CreateRectRgn(0, 0, 0, 0) orelse return error.TestRegionUnavailable;
    defer _ = c.DeleteObject(region);
    try std.testing.expect(c.GetWindowRgn(hwnd, region) != c.ERROR);
    try std.testing.expect(strip.right >= 460 and strip.bottom >= 380);
    try std.testing.expect(c.PtInRegion(region, 459, 379) == 0);
    try std.testing.expect(c.PtInRegion(region, 450, 200) != 0);
}

test "palette residual native nonclient painting is clipped around an opaque sibling decoration" {
    try registerClass();
    var entries = overflowTestEntries();
    var dialog = Dialog{ .state = State.init(std.testing.allocator, &entries) };
    defer dialog.state.deinit();
    defer releaseDrawingResources(&dialog);
    try dialog.state.filter("");
    active = &dialog;
    defer active = null;
    const hwnd = c.CreateWindowExW(0, class_name.ptr, null, c.WS_POPUP | c.WS_CLIPCHILDREN, 0, 0, 460, 380, null, null, c.GetModuleHandleW(null), null) orelse return error.PaletteCreationFailed;
    defer _ = c.DestroyWindow(hwnd);
    // A WS_EX_TRANSPARENT sibling is excluded from the clip of the windows beneath it,
    // which lets native scrollbar hover and drag painting land on the dark strip.
    const strip_extended = c.GetWindowLongPtrW(dialog.scrollbar, c.GWL_EXSTYLE);
    try std.testing.expect(strip_extended & c.WS_EX_TRANSPARENT == 0);
    const strip_style = c.GetWindowLongPtrW(dialog.scrollbar, c.GWL_STYLE);
    try std.testing.expect(strip_style & c.WS_CHILD != 0 and strip_style & c.WS_CLIPSIBLINGS != 0 and strip_style & c.WS_TABSTOP == 0);
    try std.testing.expect(c.GetWindowLongPtrW(dialog.list, c.GWL_STYLE) & c.WS_CLIPSIBLINGS != 0);
    try std.testing.expectEqual(hwnd, c.GetParent(dialog.scrollbar));
    try std.testing.expectEqual(hwnd, c.GetParent(dialog.list));
    var below = c.GetWindow(dialog.scrollbar, c.GW_HWNDNEXT);
    var covers_list = false;
    while (below != null) : (below = c.GetWindow(below, c.GW_HWNDNEXT)) {
        if (below == dialog.list) covers_list = true;
    }
    try std.testing.expect(covers_list);
    // Input still reaches the native list because the decoration declines hit testing.
    try std.testing.expectEqual(@as(c.LRESULT, c.HTTRANSPARENT), c.SendMessageW(dialog.scrollbar, c.WM_NCHITTEST, 0, 0));
}

test "palette residual wheel over the decoration scrolls the native list" {
    try registerClass();
    var entries = overflowTestEntries();
    var dialog = Dialog{ .state = State.init(std.testing.allocator, &entries) };
    defer dialog.state.deinit();
    defer releaseDrawingResources(&dialog);
    try dialog.state.filter("");
    active = &dialog;
    defer active = null;
    const hwnd = c.CreateWindowExW(0, class_name.ptr, null, c.WS_POPUP | c.WS_CLIPCHILDREN, 0, 0, 460, 380, null, null, c.GetModuleHandleW(null), null) orelse return error.PaletteCreationFailed;
    defer _ = c.DestroyWindow(hwnd);
    _ = c.SendMessageW(dialog.list, c.LB_SETTOPINDEX, 0, 0);
    try std.testing.expectEqual(@as(c.LRESULT, 0), c.SendMessageW(dialog.list, c.LB_GETTOPINDEX, 0, 0));
    const delta: u16 = @bitCast(@as(i16, -120));
    _ = c.SendMessageW(dialog.scrollbar, c.WM_MOUSEWHEEL, @as(c.WPARAM, delta) << 16, 0);
    try std.testing.expect(c.SendMessageW(dialog.list, c.LB_GETTOPINDEX, 0, 0) > 0);
}

test "palette residual posted wheel reaches the native list through the message queue" {
    try registerClass();
    var entries = overflowTestEntries();
    var dialog = Dialog{ .state = State.init(std.testing.allocator, &entries) };
    defer dialog.state.deinit();
    defer releaseDrawingResources(&dialog);
    try dialog.state.filter("");
    active = &dialog;
    defer active = null;
    const hwnd = c.CreateWindowExW(0, class_name.ptr, null, c.WS_POPUP | c.WS_CLIPCHILDREN, 0, 0, 460, 380, null, null, c.GetModuleHandleW(null), null) orelse return error.PaletteCreationFailed;
    defer _ = c.DestroyWindow(hwnd);
    _ = c.SendMessageW(dialog.list, c.LB_SETTOPINDEX, 0, 0);
    try std.testing.expectEqual(@as(c.LRESULT, 0), c.SendMessageW(dialog.list, c.LB_GETTOPINDEX, 0, 0));
    const delta: u16 = @bitCast(@as(i16, -120));
    try std.testing.expect(c.PostMessageW(dialog.list, c.WM_MOUSEWHEEL, @as(c.WPARAM, delta) << 16, 0) != 0);
    var message: c.MSG = undefined;
    while (c.PeekMessageW(&message, dialog.list, 0, 0, c.PM_REMOVE) != 0) {
        if (c.IsDialogMessageW(hwnd, &message) != 0) continue;
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }
    try std.testing.expect(c.SendMessageW(dialog.list, c.LB_GETTOPINDEX, 0, 0) > 0);
}

test "palette residual wheel delivered to the focused search field scrolls the results" {
    try registerClass();
    var entries = overflowTestEntries();
    var dialog = Dialog{ .state = State.init(std.testing.allocator, &entries) };
    defer dialog.state.deinit();
    defer releaseDrawingResources(&dialog);
    try dialog.state.filter("");
    active = &dialog;
    defer active = null;
    const hwnd = c.CreateWindowExW(0, class_name.ptr, null, c.WS_POPUP | c.WS_CLIPCHILDREN, 0, 0, 460, 380, null, null, c.GetModuleHandleW(null), null) orelse return error.PaletteCreationFailed;
    defer _ = c.DestroyWindow(hwnd);
    _ = c.SendMessageW(dialog.list, c.LB_SETTOPINDEX, 0, 0);
    try std.testing.expectEqual(@as(c.LRESULT, 0), c.SendMessageW(dialog.list, c.LB_GETTOPINDEX, 0, 0));
    const delta: u16 = @bitCast(@as(i16, -120));
    _ = c.SendMessageW(dialog.edit, c.WM_MOUSEWHEEL, @as(c.WPARAM, delta) << 16, 0);
    try std.testing.expect(c.SendMessageW(dialog.list, c.LB_GETTOPINDEX, 0, 0) > 0);
}

test "palette residual wheel the list declines does not recurse through the palette" {
    try registerClass();
    var entries = [_]Entry{.{ .project_path = "A", .project_name = "Alpha", .node_id = "one", .title = "One", .loop_type = "sketch", .state = "idle" }};
    var dialog = Dialog{ .state = State.init(std.testing.allocator, &entries) };
    defer dialog.state.deinit();
    defer releaseDrawingResources(&dialog);
    try dialog.state.filter("");
    active = &dialog;
    defer active = null;
    const hwnd = c.CreateWindowExW(0, class_name.ptr, null, c.WS_POPUP | c.WS_CLIPCHILDREN, 0, 0, 460, 380, null, null, c.GetModuleHandleW(null), null) orelse return error.PaletteCreationFailed;
    defer _ = c.DestroyWindow(hwnd);
    const delta: u16 = @bitCast(@as(i16, -120));
    const wheel = @as(c.WPARAM, delta) << 16;
    _ = c.SendMessageW(dialog.list, c.WM_MOUSEWHEEL, wheel | c.MK_CONTROL, 0);
    _ = c.SendMessageW(dialog.list, c.WM_MOUSEWHEEL, wheel, 0);
    _ = c.SendMessageW(dialog.edit, c.WM_MOUSEWHEEL, wheel, 0);
    try std.testing.expect(!dialog.closed and dialog.failure == null);
}

test "palette residual overflow opens scrolled to the first result" {
    try registerClass();
    var entries = overflowTestEntries();
    var dialog = Dialog{ .state = State.init(std.testing.allocator, &entries) };
    defer dialog.state.deinit();
    defer releaseDrawingResources(&dialog);
    try dialog.state.filter("");
    active = &dialog;
    defer active = null;
    const hwnd = c.CreateWindowExW(0, class_name.ptr, null, c.WS_POPUP | c.WS_CLIPCHILDREN, 0, 0, 460, 380, null, null, c.GetModuleHandleW(null), null) orelse return error.PaletteCreationFailed;
    defer _ = c.DestroyWindow(hwnd);
    try std.testing.expectEqual(@as(c.LRESULT, 12), c.SendMessageW(dialog.list, c.LB_GETCOUNT, 0, 0));
    try std.testing.expectEqual(@as(c.LRESULT, 0), c.SendMessageW(dialog.list, c.LB_GETCURSEL, 0, 0));
    try std.testing.expectEqual(@as(c.LRESULT, 0), c.SendMessageW(dialog.list, c.LB_GETTOPINDEX, 0, 0));
}

test "palette residual owner region is installed before the overflow list moves and the decoration follows" {
    try registerClass();
    var entries = overflowTestEntries();
    var dialog = Dialog{ .state = State.init(std.testing.allocator, &entries) };
    defer dialog.state.deinit();
    defer releaseDrawingResources(&dialog);
    try dialog.state.filter("");
    active = &dialog;
    defer active = null;
    const hwnd = c.CreateWindowExW(0, class_name.ptr, null, c.WS_POPUP | c.WS_CLIPCHILDREN, 0, 0, 460, 380, null, null, c.GetModuleHandleW(null), null) orelse return error.PaletteCreationFailed;
    defer _ = c.DestroyWindow(hwnd);
    const Probe = struct {
        var previous: c.WNDPROC = null;
        var palette: c.HWND = null;
        var region_right: c.LONG = -1;
        var observations: usize = 0;
        fn proc(list: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
            if (message == c.WM_WINDOWPOSCHANGED) {
                const region = c.CreateRectRgn(0, 0, 0, 0);
                defer _ = c.DeleteObject(region);
                var box: c.RECT = undefined;
                region_right = if (c.GetWindowRgn(palette, region) != c.ERROR and c.GetRgnBox(region, &box) != 0) box.right else -1;
                observations += 1;
            }
            return c.CallWindowProcW(previous, list, message, wparam, lparam);
        }
    };
    Probe.palette = hwnd;
    Probe.observations = 0;
    const installed = c.SetWindowLongPtrW(dialog.list, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&Probe.proc)));
    try std.testing.expect(installed != 0);
    Probe.previous = Win32.opaquePointerFromInt(c.WNDPROC, @bitCast(installed));
    try std.testing.expect(c.SetWindowPos(hwnd, null, 0, 0, 500, 380, c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0);
    try std.testing.expect(Probe.observations > 0);
    try std.testing.expect(Probe.region_right >= 500);
    var info = std.mem.zeroes(c.SCROLLBARINFO);
    info.cbSize = @sizeOf(c.SCROLLBARINFO);
    try std.testing.expect(c.GetScrollBarInfo(dialog.list, c.OBJID_VSCROLL, &info) != 0);
    var strip: c.RECT = undefined;
    try std.testing.expect(c.GetWindowRect(dialog.scrollbar, &strip) != 0);
    try std.testing.expectEqualDeep(info.rcScrollBar, strip);
    try std.testing.expect(!dialog.scrollbar_disabled and dialog.failure == null);
}

test "palette residual registered backdrop is black layered nonactivating and bounded" {
    try registerClass();
    const hwnd = c.CreateWindowExW(
        c.WS_EX_LAYERED | c.WS_EX_NOACTIVATE | c.WS_EX_TOOLWINDOW,
        std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeJumpBackdrop").ptr,
        null,
        c.WS_POPUP,
        10,
        20,
        640,
        430,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.PaletteBackdropCreationFailed;
    defer _ = c.DestroyWindow(hwnd);
    try std.testing.expect(c.IsWindowVisible(hwnd) == 0);
    var alpha: c.BYTE = 0;
    var flags: c.DWORD = 0;
    try std.testing.expect(c.GetLayeredWindowAttributes(hwnd, null, &alpha, &flags) != 0);
    try std.testing.expectEqual(@as(c.BYTE, 102), alpha);
    try std.testing.expectEqual(@as(c.DWORD, c.LWA_ALPHA), flags);
    var bounds: c.RECT = undefined;
    try std.testing.expect(c.GetWindowRect(hwnd, &bounds) != 0);
    try std.testing.expectEqualDeep(c.RECT{ .left = 10, .top = 20, .right = 650, .bottom = 450 }, bounds);
}

test "palette residual backdrop covers only owner client and is destroyed with owner" {
    try registerClass();
    const owner = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr, null, c.WS_OVERLAPPEDWINDOW, 300, 250, 640, 430, null, null, c.GetModuleHandleW(null), null) orelse return error.TestOwnerCreationFailed;
    defer if (c.IsWindow(owner) != 0) {
        _ = c.DestroyWindow(owner);
    };
    const backdrop = try createBackdrop(owner);
    defer if (c.IsWindow(backdrop) != 0) {
        _ = c.DestroyWindow(backdrop);
    };
    try std.testing.expect(c.IsWindowVisible(owner) == 0 and c.IsWindowVisible(backdrop) == 0);
    try std.testing.expectEqual(owner, c.GetWindow(backdrop, c.GW_OWNER));
    var expected: c.RECT = undefined;
    try std.testing.expect(c.GetClientRect(owner, &expected) != 0);
    var origin = c.POINT{ .x = 0, .y = 0 };
    try std.testing.expect(c.ClientToScreen(owner, &origin) != 0);
    expected.left += origin.x;
    expected.top += origin.y;
    expected.right += origin.x;
    expected.bottom += origin.y;
    var actual: c.RECT = undefined;
    try std.testing.expect(c.GetWindowRect(backdrop, &actual) != 0);
    try std.testing.expectEqualDeep(expected, actual);
    const style = c.GetWindowLongPtrW(backdrop, c.GWL_EXSTYLE);
    try std.testing.expect(style & c.WS_EX_LAYERED != 0 and style & c.WS_EX_NOACTIVATE != 0);
    {
        const dc = c.GetDC(backdrop);
        defer _ = c.ReleaseDC(backdrop, dc);
        const memory = c.CreateCompatibleDC(dc) orelse return error.TestDCUnavailable;
        defer _ = c.DeleteDC(memory);
        const bitmap = c.CreateCompatibleBitmap(dc, 2, 2) orelse return error.TestBitmapUnavailable;
        defer _ = c.DeleteObject(bitmap);
        const old_bitmap = c.SelectObject(memory, bitmap);
        defer _ = c.SelectObject(memory, old_bitmap);
        try std.testing.expectEqual(@as(c.LRESULT, 1), c.SendMessageW(backdrop, c.WM_ERASEBKGND, @intFromPtr(memory), 0));
        try std.testing.expectEqual(@as(c.COLORREF, 0), c.GetPixel(memory, 1, 1));
    }
    try std.testing.expect(c.DestroyWindow(owner) != 0);
    try std.testing.expect(c.IsWindow(backdrop) == 0);
}

test "palette residual scrollbar thumb follows native geometry at each DPI" {
    for ([_]u32{ 96, 120, 144, 192 }) |dpi| {
        var info = std.mem.zeroes(c.SCROLLBARINFO);
        info.xyThumbTop = Dpi.scale(17, dpi);
        info.xyThumbBottom = Dpi.scale(100, dpi);
        const bounds = c.RECT{ .left = Dpi.scale(443, dpi), .top = Dpi.scale(42, dpi), .right = Dpi.scale(460, dpi), .bottom = Dpi.scale(378, dpi) };
        const thumb = scrollbarThumb(bounds, info, dpi);
        try std.testing.expectEqual(bounds.top + info.xyThumbTop, thumb.top);
        try std.testing.expectEqual(bounds.top + info.xyThumbBottom, thumb.bottom);
        try std.testing.expectEqual(Dpi.scale(6, dpi), thumb.right - thumb.left);
        try std.testing.expect(thumb.left > bounds.left and thumb.right < bounds.right);
    }
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
        .{ .project_path = "B", .project_name = "Other", .node_id = "two", .title = "Ref Composite", .loop_type = "composite", .state = "running", .needs_human = true },
    };
    const snapshot = try copyEntries(allocator, &source);
    defer freeEntries(allocator, snapshot);
    title[0] = 'X';
    try std.testing.expectEqualStrings("Ref Main", snapshot[0].title);
    for (source, snapshot) |entry, copy| {
        inline for (std.meta.fields(Entry)) |field| {
            if (field.type == []const u8) {
                try std.testing.expect(@field(entry, field.name).ptr != @field(copy, field.name).ptr);
            } else {
                try std.testing.expectEqual(@field(entry, field.name), @field(copy, field.name));
            }
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
