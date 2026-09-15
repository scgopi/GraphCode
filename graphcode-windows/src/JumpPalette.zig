const std = @import("std");
const c = @import("Win32.zig").c;

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

const Dialog = struct {
    state: State,
    edit: c.HWND = null,
    list: c.HWND = null,
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
    var dialog = Dialog{ .state = State.init(allocator, entries) };
    defer dialog.state.deinit();
    try dialog.state.filter("");
    active = &dialog;
    defer active = null;

    const hwnd = c.CreateWindowExW(
        c.WS_EX_DLGMODALFRAME | c.WS_EX_CONTROLPARENT,
        class_name.ptr,
        std.unicode.utf8ToUtf16LeStringLiteral("Jump to loop").ptr,
        c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        640,
        430,
        parent,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.PaletteCreationFailed;
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
            break;
        }
        if (message.message == c.WM_KEYDOWN) {
            switch (message.wParam) {
                c.VK_DOWN => {
                    dialog.state.moveSelection(1);
                    syncListSelection(&dialog);
                    continue;
                },
                c.VK_UP => {
                    dialog.state.moveSelection(-1);
                    syncListSelection(&dialog);
                    continue;
                },
                c.VK_RETURN => {
                    accept(&dialog);
                    continue;
                },
                c.VK_ESCAPE => {
                    dialog.closed = true;
                    continue;
                },
                else => {},
            }
        }
        if (c.IsDialogMessageW(hwnd, &message) != 0) continue;
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }
    const selected = if (dialog.accepted) dialog.state.selectedEntry() else null;
    _ = c.DestroyWindow(hwnd);
    _ = c.EnableWindow(parent, 1);
    _ = c.SetActiveWindow(parent);
    if (quit_code) |value| c.PostQuitMessage(@intCast(value));
    const entry = selected orelse return null;
    return .{
        .project_path = try allocator.dupe(u8, entry.project_path),
        .node_id = try allocator.dupe(u8, entry.node_id),
    };
}

fn registerClass() !void {
    var window_class: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    window_class.lpfnWndProc = @ptrCast(&windowProc);
    window_class.hInstance = c.GetModuleHandleW(null);
    window_class.lpszClassName = class_name.ptr;
    window_class.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
    if (c.RegisterClassW(&window_class) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.PaletteClassRegistrationFailed;
}

fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const dialog = active orelse return c.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_CREATE => {
            _ = c.CreateWindowExW(
                0,
                std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr,
                std.unicode.utf8ToUtf16LeStringLiteral("Search loops").ptr,
                c.WS_CHILD | c.WS_VISIBLE | c.SS_LEFT,
                16, 14, 590, 20, hwnd, null, c.GetModuleHandleW(null), null,
            );
            dialog.edit = c.CreateWindowExW(
                c.WS_EX_CLIENTEDGE,
                std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr,
                null,
                c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_AUTOHSCROLL,
                16, 36, 590, 28, hwnd, childId(search_id), c.GetModuleHandleW(null), null,
            );
            dialog.list = c.CreateWindowExW(
                c.WS_EX_CLIENTEDGE,
                std.unicode.utf8ToUtf16LeStringLiteral("LISTBOX").ptr,
                null,
                c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.WS_VSCROLL |
                    c.LBS_NOTIFY | c.LBS_NOINTEGRALHEIGHT,
                16, 76, 590, 276, hwnd, childId(results_id), c.GetModuleHandleW(null), null,
            );
            refillList(dialog);
            return 0;
        },
        c.WM_SIZE => {
            var client: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &client);
            _ = c.MoveWindow(dialog.edit, 16, 36, client.right - 32, 28, 1);
            _ = c.MoveWindow(dialog.list, 16, 76, client.right - 32, client.bottom - 92, 1);
            return 0;
        },
        c.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            const notification: u16 = @truncate(wparam >> 16);
            if (command == search_id and notification == c.EN_CHANGE) {
                const query = readWindowText(dialog.state.allocator, dialog.edit) catch return 0;
                defer dialog.state.allocator.free(query);
                dialog.state.filter(query) catch return 0;
                refillList(dialog);
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
            dialog.state.filter("UIA loop B") catch return 0;
            refillList(dialog);
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

fn refillList(dialog: *Dialog) void {
    _ = c.SendMessageW(dialog.list, c.LB_RESETCONTENT, 0, 0);
    for (dialog.state.matches.items) |match| {
        const entry = dialog.state.entries[match.entry_index];
        const line = std.fmt.allocPrint(
            dialog.state.allocator,
            "{s}  —  {s} · {s} · {s}",
            .{ entry.title, entry.project_name, loopTypeLabel(entry.loop_type), stateLabel(entry.state) },
        ) catch continue;
        defer dialog.state.allocator.free(line);
        const wide = utf8ToWideZ(dialog.state.allocator, line) catch continue;
        defer dialog.state.allocator.free(wide);
        _ = c.SendMessageW(dialog.list, c.LB_ADDSTRING, 0, @intCast(@intFromPtr(wide.ptr)));
    }
    syncListSelection(dialog);
}

fn syncListSelection(dialog: *Dialog) void {
    if (dialog.state.matches.items.len == 0) return;
    _ = c.SendMessageW(dialog.list, c.LB_SETCURSEL, dialog.state.selection, 0);
}

fn accept(dialog: *Dialog) void {
    if (dialog.state.selectedEntry() == null) return;
    dialog.accepted = true;
    dialog.closed = true;
}

fn loopTypeLabel(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "goalBased")) return "Goal";
    if (std.mem.eql(u8, value, "timeBased")) return "Timed";
    if (std.mem.eql(u8, value, "proactive") or std.mem.eql(u8, value, "composite")) return "Proactive";
    return "Turn";
}

fn stateLabel(value: []const u8) []const u8 {
    if (value.len == 0) return "IDLE";
    return value;
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
