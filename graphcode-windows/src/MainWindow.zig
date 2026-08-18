const std = @import("std");
const c = @import("Win32.zig").c;

pub const MessageCallback = *const fn (
    context: ?*anyopaque,
    hwnd: c.HWND,
    message: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
    result: *c.LRESULT,
) callconv(.c) bool;

pub const Command = enum(u16) {
    open_folder = 4101,
    open_global_overview = 4102,
    worktrees = 4103,
    exit = 4104,
    reclaim_worktrees = 4105,
    clone_repository = 4106,
    remote_repository = 4107,
    new_quick_chat = 4108,
    jump_loop = 4201,
    review_attention = 4202,
    next_loop = 4203,
    previous_loop = 4204,
    create_node = 4205,
    create_edge = 4206,
    stop_loop = 4207,
    show_graph = 4208,
    new_tab = 4301,
    close_tab = 4302,
    split_right = 4303,
    split_down = 4304,
    next_tab = 4305,
    previous_tab = 4306,
    focus_next_pane = 4307,
    focus_previous_pane = 4308,
    reconnect = 4401,
    settings = 4402,
    product_settings = 4403,
    toggle_sidebar = 4404,
    toggle_workspace = 4405,
    toggle_activity = 4406,
    zoom_out = 4407,
    actual_size = 4408,
    zoom_in = 4409,
    fit_canvas = 4410,
    about = 4501,
    onboarding = 4502,
    check_updates = 4503,
    reveal_worktree = 4504,
    edit_worktree_policy = 4505,
    save_worktree_policy = 4506,
};

pub const empty_open_folder_id: usize = 4601;
pub const empty_new_loop_id: usize = 4602;

pub const MenuState = struct {
    has_project: bool,
    can_worktrees: bool,
    has_workspace: bool,
    has_attention: bool,
    can_close_tab: bool,
    sidebar_visible: bool,
    workspace_visible: bool,
    activity_visible: bool,
    update_checking: bool,
};

pub fn commandFromId(id: usize) ?Command {
    return std.meta.intToEnum(Command, @as(u16, @intCast(id))) catch null;
}

pub const Window = struct {
    hwnd: c.HWND = null,
    instance: c.HINSTANCE = null,
    context: ?*anyopaque = null,
    callback: ?MessageCallback = null,
    accelerators: c.HACCEL = null,
    class_name: [*:0]const u16 = class_name.ptr,

    pub fn create(
        self: *Window,
        context: ?*anyopaque,
        callback: MessageCallback,
        title: [*:0]const u16,
    ) !void {
        self.instance = c.GetModuleHandleW(null);
        if (restore_message == 0) {
            restore_message = c.RegisterWindowMessageW(
                std.unicode.utf8ToUtf16LeStringLiteral("GraphCode.Windows.Restore").ptr,
            );
        }
        self.context = context;
        self.callback = callback;
        try registerClass(self.instance);
        self.hwnd = c.CreateWindowExW(
            0,
            class_name.ptr,
            title,
            c.WS_OVERLAPPEDWINDOW | c.WS_CLIPCHILDREN,
            c.CW_USEDEFAULT,
            c.CW_USEDEFAULT,
            1280,
            820,
            null,
            null,
            self.instance,
            @ptrCast(self),
        ) orelse return error.WindowCreationFailed;
        try installMenu(self.hwnd);
        self.accelerators = createAccelerators();
        _ = c.ShowWindow(self.hwnd, c.SW_SHOW);
        _ = c.UpdateWindow(self.hwnd);
        _ = c.SetTimer(self.hwnd, timer_id, 100, null);
    }

    pub fn destroy(self: *Window) void {
        if (self.accelerators != null) {
            _ = c.DestroyAcceleratorTable(self.accelerators);
            self.accelerators = null;
        }
        if (self.hwnd != null and c.IsWindow(self.hwnd) != 0) {
            _ = c.DestroyWindow(self.hwnd);
        }
        self.hwnd = null;
    }

    pub fn messageLoop(self: *Window) !void {
        var message: c.MSG = undefined;
        while (true) {
            const result = c.GetMessageW(&message, null, 0, 0);
            if (result == 0) break;
            if (result == -1) return error.MessageLoopFailed;
            if (self.accelerators != null and c.TranslateAcceleratorW(self.hwnd, self.accelerators, &message) != 0)
                continue;
            _ = c.TranslateMessage(&message);
            _ = c.DispatchMessageW(&message);
        }
    }
};

pub const timer_id: usize = 41;
pub const wm_app_tick: c.UINT = c.WM_APP + 41;
pub var restore_message: c.UINT = 0;
pub const wm_uia_fixture_mutate: c.UINT = c.WM_APP + 42;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeWindowsShell");

pub fn restoreExistingInstance() void {
    const hwnd = c.FindWindowW(class_name.ptr, null);
    const message = c.RegisterWindowMessageW(std.unicode.utf8ToUtf16LeStringLiteral("GraphCode.Windows.Restore").ptr);
    if (hwnd != null and message != 0) {
        var process_id: c.DWORD = 0;
        _ = c.GetWindowThreadProcessId(hwnd, &process_id);
        if (process_id != 0) _ = c.AllowSetForegroundWindow(process_id);
        _ = c.ShowWindow(hwnd, c.SW_RESTORE);
        _ = c.ShowWindow(hwnd, c.SW_SHOW);
        _ = c.BringWindowToTop(hwnd);
        _ = c.SetForegroundWindow(hwnd);
        _ = c.PostMessageW(hwnd, message, 0, 0);
    }
}

pub fn installMenu(hwnd: c.HWND) !void {
    const menu = c.CreateMenu() orelse return error.MenuCreationFailed;
    const file = c.CreatePopupMenu() orelse return error.MenuCreationFailed;
    const loop = c.CreatePopupMenu() orelse return error.MenuCreationFailed;
    const terminal = c.CreatePopupMenu() orelse return error.MenuCreationFailed;
    const view = c.CreatePopupMenu() orelse return error.MenuCreationFailed;
    const help = c.CreatePopupMenu() orelse return error.MenuCreationFailed;

    append(file, "Open Folder...\tCtrl+O", @intFromEnum(Command.open_folder));
    append(file, "Clone Repository...\tCtrl+Shift+C", @intFromEnum(Command.clone_repository));
    append(file, "Add Remote Repository...\tCtrl+Shift+R", @intFromEnum(Command.remote_repository));
    separator(file);
    append(file, "New Quick Chat\tCtrl+Q", @intFromEnum(Command.new_quick_chat));
    append(file, "Open Global Overview", @intFromEnum(Command.open_global_overview));
    separator(file);
    append(file, "Worktrees...\tCtrl+Shift+W", @intFromEnum(Command.worktrees));
    append(file, "Reclaim Selected Worktrees...", @intFromEnum(Command.reclaim_worktrees));
    append(file, "Reveal Selected Worktree in Explorer\tCtrl+Shift+E", @intFromEnum(Command.reveal_worktree));
    append(file, "Project Worktree Policy...", @intFromEnum(Command.edit_worktree_policy));
    append(file, "Save Worktree Policy\tCtrl+Shift+S", @intFromEnum(Command.save_worktree_policy));
    separator(file);
    append(file, "Exit", @intFromEnum(Command.exit));

    append(loop, "Jump to Loop...\tCtrl+J", @intFromEnum(Command.jump_loop));
    append(loop, "Review What Needs You\tCtrl+Tab", @intFromEnum(Command.review_attention));
    separator(loop);
    append(loop, "Next Loop\tTab", @intFromEnum(Command.next_loop));
    append(loop, "Previous Loop\tShift+Tab", @intFromEnum(Command.previous_loop));
    separator(loop);
    append(loop, "New Loop...\tCtrl+N", @intFromEnum(Command.create_node));
    append(loop, "Create Edge...", @intFromEnum(Command.create_edge));
    append(loop, "Show in Graph", @intFromEnum(Command.show_graph));
    append(loop, "Stop Loop\tCtrl+S", @intFromEnum(Command.stop_loop));

    append(terminal, "New Tab\tCtrl+T", @intFromEnum(Command.new_tab));
    append(terminal, "Close Tab\tCtrl+W", @intFromEnum(Command.close_tab));
    separator(terminal);
    append(terminal, "Split Right\tCtrl+D", @intFromEnum(Command.split_right));
    append(terminal, "Split Down\tCtrl+Shift+D", @intFromEnum(Command.split_down));
    separator(terminal);
    append(terminal, "Next Tab\tCtrl+PageDown", @intFromEnum(Command.next_tab));
    append(terminal, "Previous Tab\tCtrl+PageUp", @intFromEnum(Command.previous_tab));
    append(terminal, "Focus Next Pane\tCtrl+]", @intFromEnum(Command.focus_next_pane));
    append(terminal, "Focus Previous Pane\tCtrl+[", @intFromEnum(Command.focus_previous_pane));

    append(view, "Global Overview", @intFromEnum(Command.open_global_overview));
    append(view, "Show Application Sidebar\tCtrl+Shift+L", @intFromEnum(Command.toggle_sidebar));
    append(view, "Show Terminal Workspace\tCtrl+Shift+B", @intFromEnum(Command.toggle_workspace));
    append(view, "Show Activity Strip\tCtrl+Shift+A", @intFromEnum(Command.toggle_activity));
    separator(view);
    append(view, "Zoom Out\tCtrl+-", @intFromEnum(Command.zoom_out));
    append(view, "Actual Size\tCtrl+0", @intFromEnum(Command.actual_size));
    append(view, "Zoom In\tCtrl+=", @intFromEnum(Command.zoom_in));
    append(view, "Fit Canvas\tCtrl+9", @intFromEnum(Command.fit_canvas));
    separator(view);
    append(view, "Reconnect", @intFromEnum(Command.reconnect));
    append(view, "Settings...\tCtrl+Shift+,", @intFromEnum(Command.product_settings));
    append(view, "Advanced Connection Settings...\tCtrl+,", @intFromEnum(Command.settings));
    append(help, "GraphCode Basics\tF1", @intFromEnum(Command.onboarding));
    append(help, "Check for Updates...", @intFromEnum(Command.check_updates));
    separator(help);
    append(help, "About GraphCode Windows", @intFromEnum(Command.about));

    appendPopup(menu, "File", file);
    appendPopup(menu, "Loop", loop);
    appendPopup(menu, "Terminal", terminal);
    appendPopup(menu, "View", view);
    appendPopup(menu, "Help", help);
    if (c.SetMenu(hwnd, menu) == 0) return error.MenuInstallFailed;
    _ = c.DrawMenuBar(hwnd);
}

pub fn updateMenu(hwnd: c.HWND, state: MenuState) void {
    setEnabled(hwnd, .open_global_overview, true);
    setEnabled(hwnd, .worktrees, state.can_worktrees);
    setEnabled(hwnd, .reclaim_worktrees, state.can_worktrees);
    setEnabled(hwnd, .reveal_worktree, state.can_worktrees);
    setEnabled(hwnd, .edit_worktree_policy, state.can_worktrees);
    setEnabled(hwnd, .save_worktree_policy, state.can_worktrees);
    setEnabled(hwnd, .jump_loop, state.has_project);
    setEnabled(hwnd, .review_attention, state.has_attention);
    setEnabled(hwnd, .next_loop, state.has_project);
    setEnabled(hwnd, .previous_loop, state.has_project);
    setEnabled(hwnd, .create_node, state.has_project);
    setEnabled(hwnd, .create_edge, state.has_project);
    setEnabled(hwnd, .stop_loop, state.has_project);
    setEnabled(hwnd, .show_graph, state.has_workspace);
    setEnabled(hwnd, .new_tab, state.has_workspace);
    setEnabled(hwnd, .close_tab, state.can_close_tab);
    setEnabled(hwnd, .split_right, state.has_workspace);
    setEnabled(hwnd, .split_down, state.has_workspace);
    setEnabled(hwnd, .next_tab, state.has_workspace);
    setEnabled(hwnd, .previous_tab, state.has_workspace);
    setEnabled(hwnd, .focus_next_pane, state.has_workspace);
    setEnabled(hwnd, .focus_previous_pane, state.has_workspace);
    setEnabled(hwnd, .settings, true);
    setEnabled(hwnd, .product_settings, true);
    setEnabled(hwnd, .reconnect, true);
    setEnabled(hwnd, .check_updates, !state.update_checking);
    setChecked(hwnd, .toggle_sidebar, state.sidebar_visible);
    setChecked(hwnd, .toggle_workspace, state.workspace_visible);
    setChecked(hwnd, .toggle_activity, state.activity_visible);
    _ = c.DrawMenuBar(hwnd);
}

fn setEnabled(hwnd: c.HWND, command: Command, enabled: bool) void {
    const flags: c.UINT = @intCast(@as(i32, c.MF_BYCOMMAND) |
        if (enabled) @as(i32, c.MF_ENABLED) else @as(i32, c.MF_GRAYED));
    _ = c.EnableMenuItem(c.GetMenu(hwnd), @intFromEnum(command), flags);
}

fn setChecked(hwnd: c.HWND, command: Command, checked: bool) void {
    const flags: c.UINT = @intCast(@as(i32, c.MF_BYCOMMAND) |
        if (checked) @as(i32, c.MF_CHECKED) else @as(i32, c.MF_UNCHECKED));
    _ = c.CheckMenuItem(c.GetMenu(hwnd), @intFromEnum(command), flags);
}

fn append(menu: c.HMENU, text: []const u8, id: usize) void {
    const wide = toWideZ(std.heap.c_allocator, text) catch return;
    defer std.heap.c_allocator.free(wide);
    _ = c.AppendMenuW(menu, c.MF_STRING, id, wide.ptr);
}

fn appendPopup(menu: c.HMENU, text: []const u8, popup: c.HMENU) void {
    const wide = toWideZ(std.heap.c_allocator, text) catch return;
    defer std.heap.c_allocator.free(wide);
    _ = c.AppendMenuW(menu, c.MF_POPUP | c.MF_STRING, @intFromPtr(popup), wide.ptr);
}

fn toWideZ(allocator: std.mem.Allocator, text: []const u8) ![:0]u16 {
    const raw = try std.unicode.utf8ToUtf16LeAlloc(allocator, text);
    defer allocator.free(raw);
    const wide = try allocator.allocSentinel(u16, raw.len, 0);
    @memcpy(wide[0..raw.len], raw);
    return wide;
}

fn separator(menu: c.HMENU) void {
    _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
}

fn createAccelerators() c.HACCEL {
    var entries = [_]c.ACCEL{
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = 'O', .cmd = @intFromEnum(Command.open_folder) },
        .{ .fVirt = c.FCONTROL | c.FSHIFT | c.FVIRTKEY, .key = 'W', .cmd = @intFromEnum(Command.worktrees) },
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = 'J', .cmd = @intFromEnum(Command.jump_loop) },
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = c.VK_TAB, .cmd = @intFromEnum(Command.review_attention) },
        .{ .fVirt = c.FVIRTKEY, .key = c.VK_TAB, .cmd = @intFromEnum(Command.next_loop) },
        .{ .fVirt = c.FSHIFT | c.FVIRTKEY, .key = c.VK_TAB, .cmd = @intFromEnum(Command.previous_loop) },
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = 'N', .cmd = @intFromEnum(Command.create_node) },
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = 'S', .cmd = @intFromEnum(Command.stop_loop) },
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = 'T', .cmd = @intFromEnum(Command.new_tab) },
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = 'W', .cmd = @intFromEnum(Command.close_tab) },
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = 'D', .cmd = @intFromEnum(Command.split_right) },
        .{ .fVirt = c.FCONTROL | c.FSHIFT | c.FVIRTKEY, .key = 'D', .cmd = @intFromEnum(Command.split_down) },
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = c.VK_NEXT, .cmd = @intFromEnum(Command.next_tab) },
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = c.VK_PRIOR, .cmd = @intFromEnum(Command.previous_tab) },
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = 0xBC, .cmd = @intFromEnum(Command.settings) },
    };
    return c.CreateAcceleratorTableW(&entries, entries.len);
}

test "native menu exposes the parity command groups" {
    try std.testing.expectEqual(Command.open_folder, commandFromId(4101).?);
    try std.testing.expectEqual(Command.split_right, commandFromId(4303).?);
    try std.testing.expectEqual(@as(?Command, null), commandFromId(9999));
}

test "native menu labels are NUL terminated UTF-16" {
    const wide = try toWideZ(std.testing.allocator, "Clone Repository…");
    defer std.testing.allocator.free(wide);
    try std.testing.expectEqual(@as(u16, 0), wide[wide.len]);
    try std.testing.expect(wide.len > "Clone Repository".len);
}


fn windowFromHandle(hwnd: c.HWND) ?*Window {
    const raw = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (raw == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(raw)));
}

fn registerClass(instance: c.HINSTANCE) !void {
    var window_class: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    window_class.lpfnWndProc = @ptrCast(&windowProc);
    window_class.hInstance = instance;
    window_class.lpszClassName = class_name.ptr;
    window_class.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
    if (c.RegisterClassW(&window_class) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS) {
        return error.WindowClassRegistrationFailed;
    }
}

fn windowProc(
    hwnd: c.HWND,
    message: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    var window = windowFromHandle(hwnd);
    if (message == c.WM_NCCREATE) {
        const create = @as(*const c.CREATESTRUCTW, @ptrFromInt(@as(usize, @bitCast(lparam))));
        window = @ptrCast(@alignCast(create.lpCreateParams));
        if (window) |value| {
            value.hwnd = hwnd;
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @intCast(@intFromPtr(value)));
        }
    }
    const value = window orelse return c.DefWindowProcW(hwnd, message, wparam, lparam);
    var result: c.LRESULT = 0;
    if (value.callback) |callback| {
        if (callback(value.context, hwnd, message, wparam, lparam, &result)) {
            if (message == c.WM_NCDESTROY) _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            return result;
        }
    }
    result = c.DefWindowProcW(hwnd, message, wparam, lparam);
    if (message == c.WM_NCDESTROY) _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
    return result;
}
