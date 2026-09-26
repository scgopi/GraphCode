const std = @import("std");
const Win32 = @import("Win32.zig");
const c = Win32.c;

pub const MessageCallback = *const fn (
    context: ?*anyopaque,
    hwnd: c.HWND,
    message: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
    result: *c.LRESULT,
) callconv(.c) bool;

pub const KeyCallback = *const fn (context: ?*anyopaque, key: usize, ctrl: bool, shift: bool, alt: bool) bool;

pub const Command = enum(u16) {
    open_folder = 4101,
    open_global_overview = 4102,
    worktrees = 4103,
    exit = 4104,
    reclaim_worktrees = 4105,
    clone_repository = 4106,
    remote_repository = 4107,
    new_quick_chat = 4108,
    codespace_repository = 4109,
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
    focus_header = 4411,
    about = 4501,
    onboarding = 4502,
    check_updates = 4503,
    reveal_worktree = 4504,
    edit_worktree_policy = 4505,
    save_worktree_policy = 4506,
    workspace_new = 4800,
    workspace_manage = 4801,
    workspace_rename = 4802,
    workspace_delete = 4803,
    workspace_next = 4804,
    workspace_previous = 4805,
};

pub const empty_open_folder_id: usize = 4601;
pub const empty_new_loop_id: usize = 4602;
pub const recent_folder_command_base: usize = 4700;
pub const recent_folder_command_limit: usize = 4799;
pub const workspace_command_base: usize = 4850;
pub const workspace_command_limit: usize = 4899;

pub const RecentFolderItem = struct {
    path: []const u8,
    name: []const u8,
};

pub const WorkspaceItem = struct {
    name: []const u8,
    is_current: bool,
};

pub const MenuRefresh = enum {
    state_change,
    popup_open,
};

fn redrawsMenuBar(refresh: MenuRefresh) bool {
    return refresh == .state_change;
}

pub const MenuState = struct {
    has_project: bool,
    can_worktrees: bool,
    /// A worktree inspection has been run (the Worktrees dialog is open), so
    /// commands that mutate its policy have somewhere to save to.
    worktree_dialog_open: bool,
    /// At least one reclaimable worktree row is currently selected, either in
    /// the Worktrees dialog or via the sidebar's single-selection shortcut.
    worktree_row_selected: bool,
    has_workspace: bool,
    has_attention: bool,
    can_close_tab: bool,
    sidebar_visible: bool,
    workspace_visible: bool,
    activity_visible: bool,
    update_checking: bool,
    recent_folders: []const RecentFolderItem = &.{},
    workspaces: []const WorkspaceItem = &.{},
};

pub fn commandFromId(id: usize) ?Command {
    return std.meta.intToEnum(Command, @as(u16, @intCast(id))) catch null;
}

pub const GestureConfigResult = struct {
    ok: bool,
    /// `GetLastError()` captured immediately after the `SetGestureConfig`
    /// call, before any other Win32 call can overwrite it. Only meaningful
    /// when `ok` is false.
    last_error: c.DWORD,
};

/// Registers this window's opt-in to native pinch-zoom (`GID_ZOOM`)
/// gestures only. Every other WM_GESTURE class is left at its existing
/// default (neither explicitly enabled nor blocked here) -- App.zig's
/// `WM_GESTURE` handler already forwards any non-`GID_ZOOM` message
/// unhandled via `CanvasInput.classifyGesture`, so there is no unimplemented
/// gesture class this app could silently start reacting to; configuring an
/// explicit block for gestures this app has no opinion on would only widen
/// the surface unnecessarily. `SetGestureConfig` documents that a single
/// call cannot mix a `dwID = 0` "all gestures" entry with specific-`dwID`
/// entries, so this uses one specific-`dwID` entry rather than `dwID = 0`.
pub fn registerCanvasGestureConfig(hwnd: c.HWND) GestureConfigResult {
    var configs = [_]c.GESTURECONFIG{
        .{ .dwID = c.GID_ZOOM, .dwWant = c.GC_ZOOM, .dwBlock = 0 },
    };
    if (c.SetGestureConfig(hwnd, 0, configs.len, &configs, @sizeOf(c.GESTURECONFIG)) != 0) {
        return .{ .ok = true, .last_error = 0 };
    }
    return .{ .ok = false, .last_error = c.GetLastError() };
}

pub const Window = struct {
    hwnd: c.HWND = null,
    instance: c.HINSTANCE = null,
    context: ?*anyopaque = null,
    callback: ?MessageCallback = null,
    key_callback: ?KeyCallback = null,
    accelerators: c.HACCEL = null,
    pending_native_f10: ?struct { down: c.MSG, owner: c.HWND, menu: c.HMENU } = null,
    class_name: [*:0]const u16 = class_name.ptr,
    /// Result of the one-time `SetGestureConfig` registration performed in
    /// `create`. Kept on the struct (rather than discarded) so a failure can
    /// be surfaced through the existing `setStatus` diagnostic path instead
    /// of failing silently.
    gesture_config_registered: bool = false,
    gesture_config_last_error: c.DWORD = 0,

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
        const gesture_result = registerCanvasGestureConfig(self.hwnd);
        self.gesture_config_registered = gesture_result.ok;
        self.gesture_config_last_error = gesture_result.last_error;
        try installMenu(self.hwnd);
        self.accelerators = createAccelerators();
        _ = c.ShowWindow(self.hwnd, c.SW_SHOW);
        _ = c.UpdateWindow(self.hwnd);
        _ = c.SetTimer(self.hwnd, timer_id, 100, null);
    }

    pub fn destroy(self: *Window) void {
        self.pending_native_f10 = null;
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
            self.dispatchMessage(&message, KeyContext.capture(self.hwnd, message.hwnd), c.GetFocus());
        }
    }

    pub fn dispatchMessage(self: *Window, message: *c.MSG, keys: KeyContext, focused: c.HWND) void {
        if (self.pretranslateKey(message, keys)) {
            self.pending_native_f10 = null;
            return;
        }
        if (self.accelerators != null and c.TranslateAcceleratorW(self.hwnd, self.accelerators, message) != 0) {
            self.pending_native_f10 = null;
            return;
        }
        if (self.dispatchNativeF10(message, keys, focused)) return;
        _ = c.TranslateMessage(message);
        _ = c.DispatchMessageW(message);
    }

    fn nativeF10TargetEligible(self: *const Window, target: c.HWND, keys: KeyContext, focused: c.HWND) bool {
        if (!keys.eligible() or keys.ctrl or keys.shift or keys.alt or self.hwnd == null or
            target == null or focused != target or c.GetMenu(self.hwnd) == null or
            c.IsWindowEnabled(self.hwnd) == 0 or c.IsWindowEnabled(target) == 0 or
            (target != self.hwnd and c.IsChild(self.hwnd, target) == 0)) return false;
        var owner_pid: c.DWORD = 0;
        var target_pid: c.DWORD = 0;
        const owner_thread = c.GetWindowThreadProcessId(self.hwnd, &owner_pid);
        const target_thread = c.GetWindowThreadProcessId(target, &target_pid);
        return owner_pid != 0 and owner_pid == target_pid and
            owner_thread == c.GetCurrentThreadId() and target_thread == owner_thread;
    }

    fn cancelNativeF10ForMessage(self: *Window, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) void {
        switch (message) {
            c.WM_CANCELMODE, c.WM_KILLFOCUS, c.WM_ACTIVATE, c.WM_ACTIVATEAPP,
            c.WM_ENABLE, c.WM_DESTROY, c.WM_NCDESTROY, c.WM_CONTEXTMENU,
            c.WM_LBUTTONDOWN, c.WM_RBUTTONDOWN,
            c.WM_MBUTTONDOWN, c.WM_XBUTTONDOWN,
            => self.pending_native_f10 = null,
            c.WM_KEYDOWN, c.WM_KEYUP, c.WM_SYSKEYDOWN, c.WM_SYSKEYUP => if (wparam != c.VK_F10 or
                (@as(usize, @bitCast(lparam)) & (1 << 29)) != 0)
            {
                self.pending_native_f10 = null;
            },
            else => {},
        }
    }

    fn dispatchNativeF10(self: *Window, message: *const c.MSG, keys: KeyContext, focused: c.HWND) bool {
        // Observe eligibility at dispatch boundaries and owner-window notifications;
        // this is not a global hook for otherwise unobserved focus history.
        self.cancelNativeF10ForMessage(message.message, message.wParam, message.lParam);
        if (self.pending_native_f10) |pending| {
            if (pending.owner != self.hwnd or c.GetMenu(self.hwnd) != pending.menu or
                !self.nativeF10TargetEligible(pending.down.hwnd, keys, focused))
                self.pending_native_f10 = null;
        }
        // Plain F10 can use the system-key family without Alt (context bit 29).
        const is_down = message.message == c.WM_KEYDOWN or message.message == c.WM_SYSKEYDOWN;
        const is_up = message.message == c.WM_KEYUP or message.message == c.WM_SYSKEYUP;
        if ((!is_down and !is_up) or
            message.wParam != c.VK_F10) return false;
        if ((@as(usize, @bitCast(message.lParam)) & (1 << 29)) != 0 or
            !self.nativeF10TargetEligible(message.hwnd, keys, focused))
        {
            self.pending_native_f10 = null;
            return false;
        }
        if (is_down) {
            if (self.pending_native_f10) |pending| {
                if (pending.down.message == message.message) return true;
                self.pending_native_f10 = null;
                return false;
            }
            if ((@as(usize, @bitCast(message.lParam)) & (1 << 30)) != 0) return false;
            self.pending_native_f10 = .{ .down = message.*, .owner = self.hwnd, .menu = c.GetMenu(self.hwnd) };
            return true;
        }
        const pending = self.pending_native_f10 orelse return false;
        self.pending_native_f10 = null;
        const expected_up: c.UINT = if (pending.down.message == c.WM_SYSKEYDOWN) c.WM_SYSKEYUP else c.WM_KEYUP;
        if (pending.down.hwnd != message.hwnd or message.message != expected_up) return false;
        // Delay native default processing until a complete eligible pair exists:
        // WM_CANCELMODE does not clear DefWindowProc's internal F10-down flag.
        _ = c.DefWindowProcW(pending.down.hwnd, pending.down.message, pending.down.wParam, pending.down.lParam);
        _ = c.DefWindowProcW(message.hwnd, message.message, message.wParam, message.lParam);
        return true;
    }

    pub fn pretranslateKey(self: *Window, message: *const c.MSG, keys: KeyContext) bool {
        if (message.message != c.WM_KEYDOWN or !keys.eligible()) return false;
        const callback = self.key_callback orelse return false;
        return callback(self.context, message.wParam, keys.ctrl, keys.shift, keys.alt);
    }
};

pub const KeyContext = struct {
    active: bool = false,
    owner_enabled: bool = false,
    target_owned: bool = false,
    target_visible: bool = false,
    target_enabled: bool = false,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,

    pub fn capture(owner: c.HWND, target: c.HWND) KeyContext {
        if (owner == null or target == null) return .{};
        return .{
            .active = c.GetActiveWindow() == owner and c.GetForegroundWindow() == owner,
            .owner_enabled = c.IsWindowEnabled(owner) != 0,
            .target_owned = target == owner or c.IsChild(owner, target) != 0,
            .target_visible = c.IsWindowVisible(target) != 0,
            .target_enabled = c.IsWindowEnabled(target) != 0,
            .ctrl = (@as(i32, c.GetKeyState(c.VK_CONTROL)) & 0x8000) != 0,
            .shift = (@as(i32, c.GetKeyState(c.VK_SHIFT)) & 0x8000) != 0,
            .alt = (@as(i32, c.GetKeyState(c.VK_MENU)) & 0x8000) != 0,
        };
    }

    pub fn eligible(self: KeyContext) bool {
        return self.active and self.owner_enabled and self.target_owned and self.target_visible and self.target_enabled;
    }
};

pub fn keyOwnerEligible(owner: c.HWND, target: c.HWND) bool {
    return KeyContext.capture(owner, target).eligible();
}

pub const timer_id: usize = 41;
pub const wm_app_tick: c.UINT = c.WM_APP + 41;
pub var restore_message: c.UINT = 0;
pub const wm_uia_fixture_mutate: c.UINT = c.WM_APP + 42;
pub const wm_uia_context_menu: c.UINT = c.WM_APP + 44;
/// Gate-only hook that presents one of a fixed set of native modal forms
/// (edge creation, worktree policy/project settings, worktree sweep) with
/// deterministic fixture data so the live UIA gate can reach forms that are
/// otherwise only invoked from real user flows. `wparam` selects the form:
/// 1 = edge creation, 2 = worktree policy, 3 = worktree sweep.
pub const wm_uia_present_form: c.UINT = c.WM_APP + 45;

/// Watchdog that ends a gate-opened popup menu if the harness never dismisses
/// it. `TrackPopupMenu` runs its own modal loop, so without this a wedged
/// popup would block the shell thread for the lifetime of the process.
pub const menu_watchdog_timer_id: usize = 43;
pub const menu_watchdog_interval_ms: c.UINT = 10000;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeWindowsShell");

const workspace_identity_property = std.unicode.utf8ToUtf16LeStringLiteral("GraphCode.Windows.WorkspaceIdentityV1");

pub const WorkspaceWindows = struct {
    target: c.HWND = null,
    unidentified: bool = false,
};

pub fn publishWorkspaceIdentity(hwnd: c.HWND, key: [:0]const u16) !void {
    if (key.len == 0) return error.InvalidWorkspaceIdentity;
    const marker = Win32.opaquePointerFromInt(c.HANDLE, 1);
    if (c.SetPropW(hwnd, key.ptr, marker) == 0) return error.WorkspaceIdentityPublishFailed;
    errdefer _ = c.RemovePropW(hwnd, key.ptr);
    if (c.SetPropW(hwnd, workspace_identity_property.ptr, marker) == 0)
        return error.WorkspaceIdentityPublishFailed;
}

pub fn invalidateWorkspaceIdentity(hwnd: c.HWND) !void {
    if (c.IsWindow(hwnd) == 0) return error.WorkspaceIdentityWindowMissing;
    _ = c.RemovePropW(hwnd, workspace_identity_property.ptr);
    if (c.GetPropW(hwnd, workspace_identity_property.ptr) != null)
        return error.WorkspaceIdentityInvalidationFailed;
}

pub fn workspaceIdentityMatches(hwnd: c.HWND, key: [:0]const u16) bool {
    return c.GetPropW(hwnd, workspace_identity_property.ptr) != null and c.GetPropW(hwnd, key.ptr) != null;
}

pub fn workspaceWindows(key: [:0]const u16) !WorkspaceWindows {
    return workspaceWindowsForClass(key, class_name);
}

fn workspaceWindowsForClass(key: [:0]const u16, window_class: []const u16) !WorkspaceWindows {
    if (key.len == 0) return error.InvalidWorkspaceIdentity;
    const Lookup = struct {
        key: [:0]const u16,
        window_class: []const u16,
        found: WorkspaceWindows = .{},
        failure: ?anyerror = null,

        fn visit(hwnd: c.HWND, parameter: c.LPARAM) callconv(.winapi) c.BOOL {
            const self = Win32.messagePointer(*@This(), parameter);
            var buffer: [256]u16 = undefined;
            const length = c.GetClassNameW(hwnd, &buffer, buffer.len);
            if (length <= 0 or !std.mem.eql(u16, self.window_class, buffer[0..@intCast(length)])) return 1;
            const same_user = sameWindowUser(hwnd) catch |err| {
                self.failure = err;
                return 0;
            };
            if (!same_user) return 1;
            if (c.GetPropW(hwnd, workspace_identity_property.ptr) == null) {
                self.found.unidentified = true;
            } else if (workspaceIdentityMatches(hwnd, self.key)) {
                if (self.found.target != null) {
                    self.failure = error.AmbiguousWorkspaceWindow;
                    return 0;
                }
                self.found.target = hwnd;
            }
            return 1;
        }
    };
    var lookup = Lookup{ .key = key, .window_class = window_class };
    const enumerated = c.EnumWindows(Lookup.visit, @bitCast(@intFromPtr(&lookup)));
    if (lookup.failure) |err| return err;
    if (enumerated == 0) return error.WorkspaceWindowLookupFailed;
    return lookup.found;
}

fn sameWindowUser(hwnd: c.HWND) !bool {
    var pid: c.DWORD = 0;
    if (c.GetWindowThreadProcessId(hwnd, &pid) == 0) return error.WorkspaceWindowOwnerUnknown;
    if (pid == c.GetCurrentProcessId()) return true;
    var own_session: c.DWORD = 0;
    var target_session: c.DWORD = 0;
    if (c.ProcessIdToSessionId(c.GetCurrentProcessId(), &own_session) == 0 or
        c.ProcessIdToSessionId(pid, &target_session) == 0) return error.WorkspaceWindowOwnerUnknown;
    if (own_session != target_session) return false;
    const process = c.OpenProcess(c.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse
        return error.WorkspaceWindowOwnerUnknown;
    defer _ = c.CloseHandle(process);
    var own_token: c.HANDLE = null;
    if (c.OpenProcessToken(c.GetCurrentProcess(), c.TOKEN_QUERY, &own_token) == 0)
        return error.WorkspaceWindowOwnerUnknown;
    defer _ = c.CloseHandle(own_token);
    var target_token: c.HANDLE = null;
    if (c.OpenProcessToken(process, c.TOKEN_QUERY, &target_token) == 0)
        return error.WorkspaceWindowOwnerUnknown;
    defer _ = c.CloseHandle(target_token);
    var own_info: [512]u8 align(@alignOf(c.TOKEN_USER)) = undefined;
    var target_info: [512]u8 align(@alignOf(c.TOKEN_USER)) = undefined;
    var required: c.DWORD = 0;
    if (c.GetTokenInformation(own_token, c.TokenUser, &own_info, own_info.len, &required) == 0 or
        c.GetTokenInformation(target_token, c.TokenUser, &target_info, target_info.len, &required) == 0)
        return error.WorkspaceWindowOwnerUnknown;
    const own_user: *const c.TOKEN_USER = @ptrCast(&own_info);
    const target_user: *const c.TOKEN_USER = @ptrCast(&target_info);
    return c.EqualSid(own_user.User.Sid, target_user.User.Sid) != 0;
}

pub fn restoreExistingInstance(key: [:0]const u16) !void {
    const hwnd = (try workspaceWindows(key)).target orelse return error.WorkspaceWindowNotFound;
    const message = c.RegisterWindowMessageW(std.unicode.utf8ToUtf16LeStringLiteral("GraphCode.Windows.Restore").ptr);
    if (message == 0) return error.WorkspaceRestoreFailed;
    var process_id: c.DWORD = 0;
    if (c.GetWindowThreadProcessId(hwnd, &process_id) == 0) return error.WorkspaceWindowOwnerUnknown;
    if (!workspaceIdentityMatches(hwnd, key)) return error.WorkspaceWindowNotFound;
    _ = c.AllowSetForegroundWindow(process_id);
    _ = c.ShowWindow(hwnd, c.SW_RESTORE);
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.BringWindowToTop(hwnd);
    if (c.PostMessageW(hwnd, message, 0, 0) == 0) return error.WorkspaceRestoreFailed;
    if (c.SetForegroundWindow(hwnd) == 0 and c.GetForegroundWindow() != hwnd)
        return error.WorkspaceActivationFailed;
}

pub fn installMenu(hwnd: c.HWND) !void {
    const menu = c.CreateMenu() orelse return error.MenuCreationFailed;
    const file = c.CreatePopupMenu() orelse return error.MenuCreationFailed;
    const add_folder = c.CreatePopupMenu() orelse return error.MenuCreationFailed;
    const recent_folders = c.CreatePopupMenu() orelse return error.MenuCreationFailed;
    const loop = c.CreatePopupMenu() orelse return error.MenuCreationFailed;
    const terminal = c.CreatePopupMenu() orelse return error.MenuCreationFailed;
    const view = c.CreatePopupMenu() orelse return error.MenuCreationFailed;
    const help = c.CreatePopupMenu() orelse return error.MenuCreationFailed;
    const workspace = c.CreatePopupMenu() orelse return error.MenuCreationFailed;

    append(add_folder, "Open Folder...\tCtrl+O", @intFromEnum(Command.open_folder));
    append(add_folder, "Clone Repository...\tCtrl+Shift+C", @intFromEnum(Command.clone_repository));
    append(add_folder, "Add Remote Repository...\tCtrl+Shift+R", @intFromEnum(Command.remote_repository));
    append(add_folder, "Add Codespace...\tCtrl+Shift+K", @intFromEnum(Command.codespace_repository));
    separator(add_folder);
    appendPopup(add_folder, "Recent Folders", recent_folders);
    appendPopup(file, "Add Folder", add_folder);
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
    append(view, "Focus Window Toolbar\tF6", @intFromEnum(Command.focus_header));
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
    append(help, "About GraphCode", @intFromEnum(Command.about));

    append(workspace, "New Workspace...", @intFromEnum(Command.workspace_new));
    append(workspace, "Manage Workspaces...", @intFromEnum(Command.workspace_manage));
    append(workspace, "Rename Workspace...", @intFromEnum(Command.workspace_rename));
    append(workspace, "Delete Workspace...", @intFromEnum(Command.workspace_delete));
    separator(workspace);
    append(workspace, "Next Workspace\tCtrl+Alt+PageDown", @intFromEnum(Command.workspace_next));
    append(workspace, "Previous Workspace\tCtrl+Alt+PageUp", @intFromEnum(Command.workspace_previous));

    appendPopup(menu, "File", file);
    appendPopup(menu, "Loop", loop);
    appendPopup(menu, "Terminal", terminal);
    appendPopup(menu, "Workspace", workspace);
    appendPopup(menu, "View", view);
    appendPopup(menu, "Help", help);
    if (c.SetMenu(hwnd, menu) == 0) return error.MenuInstallFailed;
    _ = c.DrawMenuBar(hwnd);
}

pub fn updateMenu(hwnd: c.HWND, state: MenuState, refresh: MenuRefresh) void {
    updateRecentFolderMenu(hwnd, state.recent_folders);
    updateWorkspaceMenu(hwnd, state.workspaces);
    setEnabled(hwnd, .open_global_overview, true);
    setEnabled(hwnd, .worktrees, state.can_worktrees);
    // Reclaim and reveal act on whichever row is currently selected, and save
    // writes to the dialog's in-memory policy: gray them out instead of
    // surfacing a "select a row first"/"open Worktrees first" status message
    // for a command that was reachable but could never have succeeded.
    setEnabled(hwnd, .reclaim_worktrees, state.can_worktrees and state.worktree_row_selected);
    setEnabled(hwnd, .reveal_worktree, state.can_worktrees and state.worktree_row_selected);
    setEnabled(hwnd, .edit_worktree_policy, state.can_worktrees);
    setEnabled(hwnd, .save_worktree_policy, state.can_worktrees and state.worktree_dialog_open);
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
    setEnabled(hwnd, .workspace_manage, state.workspaces.len > 1);
    setEnabled(hwnd, .workspace_next, state.workspaces.len > 1);
    setEnabled(hwnd, .workspace_previous, state.workspaces.len > 1);
    setChecked(hwnd, .toggle_sidebar, state.sidebar_visible);
    setChecked(hwnd, .toggle_workspace, state.workspace_visible);
    setChecked(hwnd, .toggle_activity, state.activity_visible);
    if (redrawsMenuBar(refresh)) _ = c.DrawMenuBar(hwnd);
}

fn updateWorkspaceMenu(hwnd: c.HWND, workspaces: []const WorkspaceItem) void {
    const root = c.GetMenu(hwnd);
    if (root == null) return;
    const menu = c.GetSubMenu(root, 3);
    if (menu == null) return;
    while (c.GetMenuItemCount(menu) > 0) {
        _ = c.DeleteMenu(menu, 0, c.MF_BYPOSITION);
    }
    append(menu, "New Workspace...", @intFromEnum(Command.workspace_new));
    appendEnabled(menu, "Manage Workspaces...", @intFromEnum(Command.workspace_manage), workspaces.len > 1);
    appendEnabled(menu, "Rename Workspace...", @intFromEnum(Command.workspace_rename), workspaces.len > 1);
    appendEnabled(menu, "Delete Workspace...", @intFromEnum(Command.workspace_delete), workspaces.len > 1);
    separator(menu);
    appendEnabled(menu, "Next Workspace\tCtrl+Alt+PageDown", @intFromEnum(Command.workspace_next), workspaces.len > 1);
    appendEnabled(menu, "Previous Workspace\tCtrl+Alt+PageUp", @intFromEnum(Command.workspace_previous), workspaces.len > 1);
    separator(menu);
    for (workspaces[0..@min(workspaces.len, workspace_command_limit - workspace_command_base + 1)], 0..) |item, index| {
        const command: c.UINT = @intCast(workspace_command_base + index);
        append(menu, item.name, command);
        const flags: c.UINT = if (item.is_current) c.MF_BYCOMMAND | c.MF_CHECKED else c.MF_BYCOMMAND | c.MF_UNCHECKED;
        _ = c.CheckMenuItem(menu, command, flags);
    }
}

pub fn isRecentFolderCommand(id: usize) bool {
    return id >= recent_folder_command_base and id <= recent_folder_command_limit;
}

fn updateRecentFolderMenu(hwnd: c.HWND, recent_folders: []const RecentFolderItem) void {
    const root = c.GetMenu(hwnd);
    if (root == null) return;
    const file = c.GetSubMenu(root, 0);
    if (file == null) return;
    const add_folder = c.GetSubMenu(file, 0);
    if (add_folder == null) return;
    // Located rather than indexed: the Add Folder popup grows an entry whenever a new
    // ingress lands, and a hard-coded position silently retargeted this rebuild at the
    // wrong item the last time it did.
    const recent = findSubMenu(add_folder) orelse return;
    var count = c.GetMenuItemCount(recent);
    while (count > 0) : (count -= 1) {
        _ = c.DeleteMenu(recent, @intCast(count - 1), c.MF_BYPOSITION);
    }
    if (recent_folders.len == 0) {
        appendEnabled(recent, "No recent folders", recent_folder_command_base, false);
        return;
    }
    for (recent_folders[0..@min(recent_folders.len, recent_folder_command_limit - recent_folder_command_base + 1)], 0..) |project, index| {
        append(recent, project.name, recent_folder_command_base + index);
    }
}

fn findSubMenu(menu: c.HMENU) c.HMENU {
    const count = c.GetMenuItemCount(menu);
    var index: i32 = 0;
    while (index < count) : (index += 1) {
        const child = c.GetSubMenu(menu, index);
        if (child != null) return child;
    }
    return null;
}

fn setEnabled(hwnd: c.HWND, command: Command, enabled: bool) void {
    const flags: c.UINT = @intCast(@as(i32, c.MF_BYCOMMAND) |
        if (enabled) @as(i32, c.MF_ENABLED) else @as(i32, c.MF_GRAYED));
    _ = c.EnableMenuItem(c.GetMenu(hwnd), @intFromEnum(command), flags);
}

/// Re-enables Check for Updates on its own, without touching any other menu
/// item or rebuilding the Recent Folders/Workspace submenus. The background
/// update check's completion is observed on a general-purpose timer tick that
/// can land while another menu/context-menu interaction is mid-flight, so a
/// full `updateMenu` (which appends/removes submenu items) is not safe to run
/// there; toggling this single command by id is.
pub fn setUpdateCheckEnabled(hwnd: c.HWND, enabled: bool) void {
    setEnabled(hwnd, .check_updates, enabled);
}

fn setChecked(hwnd: c.HWND, command: Command, checked: bool) void {
    const flags: c.UINT = @intCast(@as(i32, c.MF_BYCOMMAND) |
        if (checked) @as(i32, c.MF_CHECKED) else @as(i32, c.MF_UNCHECKED));
    _ = c.CheckMenuItem(c.GetMenu(hwnd), @intFromEnum(command), flags);
}

fn append(menu: c.HMENU, text: []const u8, id: usize) void {
    appendEnabled(menu, text, id, true);
}

fn appendEnabled(menu: c.HMENU, text: []const u8, id: usize, enabled: bool) void {
    const wide = toWideZ(std.heap.c_allocator, text) catch return;
    defer std.heap.c_allocator.free(wide);
    var flags: c.UINT = c.MF_STRING;
    if (!enabled) flags |= c.MF_GRAYED;
    _ = c.AppendMenuW(menu, flags, id, wide.ptr);
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
    const accelerators = c.CreateAcceleratorTableW(&entries, entries.len);
    if (accelerators == null) {
        const last_error = c.GetLastError();
        std.log.err("CreateAcceleratorTableW failed: error={d}, count={d}, ACCEL size={d}, alignment={d}", .{
            last_error, entries.len, @sizeOf(c.ACCEL), @alignOf(c.ACCEL),
        });
        for (entries, 0..) |entry, index| {
            std.log.err("ACCEL[{d}]: fVirt=0x{x}, key=0x{x}, cmd={d}", .{ index, entry.fVirt, entry.key, entry.cmd });
        }
    }
    return accelerators;
}

test "native menu exposes the parity command groups" {
    try std.testing.expectEqual(Command.open_folder, commandFromId(4101).?);
    try std.testing.expectEqual(Command.split_right, commandFromId(4303).?);
    try std.testing.expectEqual(Command.about, commandFromId(4501).?);
    try std.testing.expectEqual(@as(?Command, null), commandFromId(9999));
}

const NativeMenuDispatchTest = struct {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeNativeF10DispatchTest");
    var menu_commands: usize = 0;
    var keys_consumed: usize = 0;
    var command: usize = 0;
    var contexts: usize = 0;
    var last_menu_target: c.HWND = null;

    parent: c.HWND,
    child: c.HWND,

    fn proc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
        if (message == c.WM_COMMAND) {
            command = wparam & 0xffff;
            return 0;
        }
        if (message == c.WM_CONTEXTMENU) {
            contexts += 1;
            return 0;
        }
        if (message == c.WM_SYSCOMMAND and (wparam & 0xfff0) == c.SC_KEYMENU) {
            menu_commands += 1;
            last_menu_target = hwnd;
            return 0;
        }
        if (message == c.WM_KEYDOWN or message == c.WM_KEYUP or
            message == c.WM_SYSKEYDOWN or message == c.WM_SYSKEYUP)
        {
            keys_consumed += 1;
            return 0;
        }
        return c.DefWindowProcW(hwnd, message, wparam, lparam);
    }

    fn init() !NativeMenuDispatchTest {
        var wc = std.mem.zeroes(c.WNDCLASSW);
        wc.hInstance = c.GetModuleHandleW(null);
        wc.lpszClassName = name;
        wc.lpfnWndProc = &proc;
        if (c.RegisterClassW(&wc) == 0) return error.WindowClassRegistrationFailed;
        errdefer _ = c.UnregisterClassW(name, wc.hInstance);
        const parent = c.CreateWindowExW(0, name, name, c.WS_OVERLAPPEDWINDOW, 0, 0, 100, 100,
            null, null, wc.hInstance, null) orelse return error.WindowCreationFailed;
        errdefer _ = c.DestroyWindow(parent);
        try installMenu(parent);
        const child = c.CreateWindowExW(0, name, name, c.WS_CHILD, 0, 0, 20, 20,
            parent, null, wc.hInstance, null) orelse return error.WindowCreationFailed;
        return .{ .parent = parent, .child = child };
    }

    fn deinit(self: NativeMenuDispatchTest) void {
        _ = c.DestroyWindow(self.child);
        _ = c.DestroyWindow(self.parent);
        _ = c.UnregisterClassW(name, c.GetModuleHandleW(null));
    }

    fn reset() void {
        menu_commands = 0;
        keys_consumed = 0;
        command = 0;
        contexts = 0;
        last_menu_target = null;
    }

    fn key(target: c.HWND, message: c.UINT) c.MSG {
        var value = std.mem.zeroes(c.MSG);
        value.hwnd = target;
        value.message = message;
        value.wParam = c.VK_F10;
        value.lParam = if (message == c.WM_KEYUP or message == c.WM_SYSKEYUP) @as(c.LPARAM, 0xc0440001) else 0x00440001;
        return value;
    }

    // Active/visibility and focused HWND facts are supplied for this never-shown fixture.
    const eligible = KeyContext{
        .active = true, .owner_enabled = true, .target_owned = true,
        .target_visible = true, .target_enabled = true,
    };
};

test "hidden consuming child requires native F10 default processing" {
    const fixture = try NativeMenuDispatchTest.init();
    defer fixture.deinit();
    try std.testing.expect(c.IsWindowVisible(fixture.parent) == 0);
    try std.testing.expect(c.IsWindowVisible(fixture.child) == 0);
    var down = NativeMenuDispatchTest.key(fixture.child, c.WM_KEYDOWN);
    var up = NativeMenuDispatchTest.key(fixture.child, c.WM_KEYUP);
    NativeMenuDispatchTest.reset();
    _ = c.DispatchMessageW(&down);
    _ = c.DispatchMessageW(&up);
    try std.testing.expectEqual(@as(usize, 2), NativeMenuDispatchTest.keys_consumed);
    try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
    _ = c.DefWindowProcW(down.hwnd, down.message, down.wParam, down.lParam);
    _ = c.DefWindowProcW(up.hwnd, up.message, up.wParam, up.lParam);
    try std.testing.expectEqual(@as(usize, 1), NativeMenuDispatchTest.menu_commands);
    try std.testing.expectEqual(fixture.parent, NativeMenuDispatchTest.last_menu_target);
}

test "native F10 dispatch reaches the real menu from a consuming child" {
    const fixture = try NativeMenuDispatchTest.init();
    defer fixture.deinit();
    var window = Window{ .hwnd = fixture.parent };
    var down = NativeMenuDispatchTest.key(fixture.child, c.WM_KEYDOWN);
    var up = NativeMenuDispatchTest.key(fixture.child, c.WM_KEYUP);
    NativeMenuDispatchTest.reset();
    const original_down = down;
    const original_up = up;
    window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
    try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
    try std.testing.expect(std.meta.eql(original_down, window.pending_native_f10.?.down));
    window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, fixture.child);
    try std.testing.expectEqual(@as(usize, 1), NativeMenuDispatchTest.menu_commands);
    try std.testing.expectEqual(fixture.parent, NativeMenuDispatchTest.last_menu_target);
    try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.keys_consumed);
    try std.testing.expect(window.pending_native_f10 == null);
    try std.testing.expect(std.meta.eql(original_down, down));
    try std.testing.expect(std.meta.eql(original_up, up));
}

test "native F10 system messages with no Alt context reach the real menu" {
    const fixture = try NativeMenuDispatchTest.init();
    defer fixture.deinit();
    try std.testing.expect(c.IsWindowVisible(fixture.parent) == 0);
    try std.testing.expect(c.IsWindowVisible(fixture.child) == 0);
    var down = NativeMenuDispatchTest.key(fixture.child, c.WM_SYSKEYDOWN);
    var up = NativeMenuDispatchTest.key(fixture.child, c.WM_SYSKEYUP);
    up.lParam = 0xc0440001;
    const original_down = down;
    const original_up = up;
    try std.testing.expect((@as(usize, @bitCast(down.lParam)) & (1 << 29)) == 0);
    try std.testing.expect((@as(usize, @bitCast(up.lParam)) & (1 << 29)) == 0);

    NativeMenuDispatchTest.reset();
    _ = c.DispatchMessageW(&down);
    _ = c.DispatchMessageW(&up);
    try std.testing.expectEqual(@as(usize, 2), NativeMenuDispatchTest.keys_consumed);
    try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
    _ = c.DefWindowProcW(down.hwnd, down.message, down.wParam, down.lParam);
    _ = c.DefWindowProcW(up.hwnd, up.message, up.wParam, up.lParam);
    try std.testing.expectEqual(@as(usize, 1), NativeMenuDispatchTest.menu_commands);
    try std.testing.expectEqual(fixture.parent, NativeMenuDispatchTest.last_menu_target);

    NativeMenuDispatchTest.reset();
    var window = Window{ .hwnd = fixture.parent };
    window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
    try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
    window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, fixture.child);
    try std.testing.expectEqual(@as(usize, 1), NativeMenuDispatchTest.menu_commands);
    try std.testing.expectEqual(fixture.parent, NativeMenuDispatchTest.last_menu_target);
    try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.keys_consumed);
    try std.testing.expect(window.pending_native_f10 == null);
    try std.testing.expect(std.meta.eql(original_down, down));
    try std.testing.expect(std.meta.eql(original_up, up));
}

test "native F10 system pairs preserve repeats orphan and cancellation boundaries" {
    const fixture = try NativeMenuDispatchTest.init();
    defer fixture.deinit();
    var window = Window{ .hwnd = fixture.parent };
    for ([_]c.HWND{ fixture.parent, fixture.child }) |target| {
        var down = NativeMenuDispatchTest.key(target, c.WM_SYSKEYDOWN);
        down.time = 301;
        down.pt = .{ .x = 7, .y = 11 };
        var up = NativeMenuDispatchTest.key(target, c.WM_SYSKEYUP);
        up.time = 351;
        const original_down = down;
        const original_up = up;
        NativeMenuDispatchTest.reset();
        window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, target);
        try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
        window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, target);
        var repeat = down;
        repeat.lParam |= 1 << 30;
        repeat.time = 327;
        window.dispatchMessage(&repeat, NativeMenuDispatchTest.eligible, target);
        window.dispatchMessage(&repeat, NativeMenuDispatchTest.eligible, target);
        try std.testing.expect(window.pending_native_f10 != null);
        try std.testing.expect(std.meta.eql(original_down, window.pending_native_f10.?.down));
        try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
        window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, target);
        try std.testing.expectEqual(@as(usize, 1), NativeMenuDispatchTest.menu_commands);
        try std.testing.expectEqual(@as(usize, 1), NativeMenuDispatchTest.keys_consumed);
        try std.testing.expectEqual(fixture.parent, NativeMenuDispatchTest.last_menu_target);
        try std.testing.expect(std.meta.eql(original_down, down));
        try std.testing.expect(std.meta.eql(original_up, up));
        window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, target);
        try std.testing.expectEqual(@as(usize, 1), NativeMenuDispatchTest.menu_commands);
        window.dispatchMessage(&repeat, NativeMenuDispatchTest.eligible, target);
        try std.testing.expect(window.pending_native_f10 == null);
    }

    var down = NativeMenuDispatchTest.key(fixture.child, c.WM_SYSKEYDOWN);
    var up = NativeMenuDispatchTest.key(fixture.child, c.WM_SYSKEYUP);
    for ([_]c.UINT{
        c.WM_CANCELMODE, c.WM_KILLFOCUS, c.WM_ACTIVATE, c.WM_ACTIVATEAPP,
        c.WM_ENABLE, c.WM_CONTEXTMENU, c.WM_LBUTTONDOWN, c.WM_RBUTTONDOWN,
        c.WM_MBUTTONDOWN, c.WM_XBUTTONDOWN, c.WM_SYSKEYDOWN, c.WM_SYSKEYUP,
        c.WM_KEYDOWN, c.WM_KEYUP,
    }) |message_type| {
        NativeMenuDispatchTest.reset();
        window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
        var interruption = std.mem.zeroes(c.MSG);
        interruption.hwnd = fixture.child;
        interruption.message = message_type;
        window.dispatchMessage(&interruption, NativeMenuDispatchTest.eligible, fixture.child);
        try std.testing.expect(window.pending_native_f10 == null);
        window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, fixture.child);
        try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
    }
}

test "native F10 rejects Alt context bits even with a plain modifier snapshot" {
    const fixture = try NativeMenuDispatchTest.init();
    defer fixture.deinit();
    var window = Window{ .hwnd = fixture.parent };
    for ([_][2]c.UINT{
        .{ c.WM_KEYDOWN, c.WM_KEYUP },
        .{ c.WM_SYSKEYDOWN, c.WM_SYSKEYUP },
    }) |family| {
        var down = NativeMenuDispatchTest.key(fixture.child, family[0]);
        var up = NativeMenuDispatchTest.key(fixture.child, family[1]);
        var alt_down = down;
        var alt_up = up;
        alt_down.lParam |= 1 << 29;
        alt_up.lParam |= 1 << 29;
        NativeMenuDispatchTest.reset();
        window.dispatchMessage(&alt_down, NativeMenuDispatchTest.eligible, fixture.child);
        window.dispatchMessage(&alt_up, NativeMenuDispatchTest.eligible, fixture.child);
        try std.testing.expectEqual(@as(usize, 2), NativeMenuDispatchTest.keys_consumed);
        try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
        try std.testing.expect(window.pending_native_f10 == null);

        window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
        window.dispatchMessage(&alt_up, NativeMenuDispatchTest.eligible, fixture.child);
        try std.testing.expect(window.pending_native_f10 == null);
        window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, fixture.child);
        try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);

        window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
        window.dispatchMessage(&alt_down, NativeMenuDispatchTest.eligible, fixture.child);
        try std.testing.expect(window.pending_native_f10 == null);
        window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, fixture.child);
        try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);

        const other_up: c.UINT = if (family[1] == c.WM_KEYUP) c.WM_SYSKEYUP else c.WM_KEYUP;
        var mismatched_up = up;
        mismatched_up.message = other_up;
        window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
        window.dispatchMessage(&mismatched_up, NativeMenuDispatchTest.eligible, fixture.child);
        try std.testing.expect(window.pending_native_f10 == null);
        window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, fixture.child);
        try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
    }
}

test "native F10 system pairs retain ownership focus modifier and menu exclusions" {
    const fixture = try NativeMenuDispatchTest.init();
    defer fixture.deinit();
    var window = Window{ .hwnd = fixture.parent };
    var down = NativeMenuDispatchTest.key(fixture.child, c.WM_SYSKEYDOWN);
    var up = NativeMenuDispatchTest.key(fixture.child, c.WM_SYSKEYUP);
    inline for (.{ "ctrl", "shift", "alt", "active", "owner_enabled", "target_owned", "target_visible", "target_enabled" }) |field| {
        var excluded = NativeMenuDispatchTest.eligible;
        @field(excluded, field) = !@field(excluded, field);
        NativeMenuDispatchTest.reset();
        window.dispatchMessage(&down, excluded, fixture.child);
        window.dispatchMessage(&up, excluded, fixture.child);
        try std.testing.expectEqual(@as(usize, 2), NativeMenuDispatchTest.keys_consumed);
        try std.testing.expect(window.pending_native_f10 == null);
        window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
        window.dispatchMessage(&up, excluded, fixture.child);
        try std.testing.expect(window.pending_native_f10 == null);
        window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, fixture.child);
        try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
    }
    window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
    window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, fixture.parent);
    try std.testing.expect(window.pending_native_f10 == null);
    window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, fixture.child);
    try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
    window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
    var different_target = up;
    different_target.hwnd = fixture.parent;
    window.dispatchMessage(&different_target, NativeMenuDispatchTest.eligible, fixture.parent);
    try std.testing.expect(window.pending_native_f10 == null);
    try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);

    _ = c.EnableWindow(fixture.parent, 0);
    window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
    try std.testing.expect(window.pending_native_f10 == null);
    _ = c.EnableWindow(fixture.parent, 1);
    window.dispatchMessage(&down, KeyContext.capture(fixture.parent, fixture.child), fixture.child);
    try std.testing.expect(window.pending_native_f10 == null);
    const other = c.CreateWindowExW(0, NativeMenuDispatchTest.name, NativeMenuDispatchTest.name,
        c.WS_OVERLAPPED, 0, 0, 20, 20, null, null, c.GetModuleHandleW(null), null) orelse return error.WindowCreationFailed;
    defer _ = c.DestroyWindow(other);
    var foreign = down;
    foreign.hwnd = other;
    window.dispatchMessage(&foreign, NativeMenuDispatchTest.eligible, other);
    try std.testing.expect(window.pending_native_f10 == null);
    window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
    const menu = c.GetMenu(fixture.parent);
    try std.testing.expect(c.SetMenu(fixture.parent, null) != 0);
    window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, fixture.child);
    try std.testing.expect(window.pending_native_f10 == null);
    try std.testing.expect(c.SetMenu(fixture.parent, menu) != 0);
    try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
}

test "native F10 default flag survives WM_CANCELMODE" {
    const fixture = try NativeMenuDispatchTest.init();
    defer fixture.deinit();
    const down = NativeMenuDispatchTest.key(fixture.child, c.WM_KEYDOWN);
    const up = NativeMenuDispatchTest.key(fixture.child, c.WM_KEYUP);
    NativeMenuDispatchTest.reset();
    _ = c.DefWindowProcW(down.hwnd, down.message, down.wParam, down.lParam);
    _ = c.DefWindowProcW(fixture.child, c.WM_CANCELMODE, 0, 0);
    _ = c.DefWindowProcW(up.hwnd, up.message, up.wParam, up.lParam);
    try std.testing.expectEqual(@as(usize, 1), NativeMenuDispatchTest.menu_commands);
}

test "native F10 pair preserves original messages and ignores orphan or repeat activation" {
    const fixture = try NativeMenuDispatchTest.init();
    defer fixture.deinit();
    var window = Window{ .hwnd = fixture.parent };
    for ([_]c.HWND{ fixture.parent, fixture.child }) |target| {
        var down = NativeMenuDispatchTest.key(target, c.WM_KEYDOWN);
        down.time = 12345;
        down.pt = .{ .x = 17, .y = 29 };
        var up = NativeMenuDispatchTest.key(target, c.WM_KEYUP);
        up.time = 12388;
        const original_down = down;
        const original_up = up;
        NativeMenuDispatchTest.reset();
        window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, target);
        try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
        try std.testing.expectEqual(@as(usize, 1), NativeMenuDispatchTest.keys_consumed);
        window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, target);
        var repeated = down;
        repeated.lParam |= 1 << 30;
        repeated.time = 12366;
        window.dispatchMessage(&repeated, NativeMenuDispatchTest.eligible, target);
        window.dispatchMessage(&repeated, NativeMenuDispatchTest.eligible, target);
        try std.testing.expect(std.meta.eql(original_down, window.pending_native_f10.?.down));
        try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
        window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, target);
        try std.testing.expectEqual(@as(usize, 1), NativeMenuDispatchTest.menu_commands);
        try std.testing.expectEqual(@as(usize, 1), NativeMenuDispatchTest.keys_consumed);
        try std.testing.expectEqual(fixture.parent, NativeMenuDispatchTest.last_menu_target);
        try std.testing.expect(std.meta.eql(original_down, down));
        try std.testing.expect(std.meta.eql(original_up, up));
        window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, target);
        try std.testing.expectEqual(@as(usize, 1), NativeMenuDispatchTest.menu_commands);
        try std.testing.expectEqual(@as(usize, 2), NativeMenuDispatchTest.keys_consumed);
        window.dispatchMessage(&repeated, NativeMenuDispatchTest.eligible, target);
        try std.testing.expect(window.pending_native_f10 == null);
    }
}

test "native F10 interrupted pairs never set the native default flag" {
    const fixture = try NativeMenuDispatchTest.init();
    defer fixture.deinit();
    var window = Window{ .hwnd = fixture.parent };
    var down = NativeMenuDispatchTest.key(fixture.child, c.WM_KEYDOWN);
    var up = NativeMenuDispatchTest.key(fixture.child, c.WM_KEYUP);
    for ([_]c.UINT{
        c.WM_CANCELMODE, c.WM_KILLFOCUS, c.WM_ACTIVATE, c.WM_ACTIVATEAPP,
        c.WM_ENABLE, c.WM_CONTEXTMENU, c.WM_SYSKEYDOWN, c.WM_SYSKEYUP,
        c.WM_LBUTTONDOWN, c.WM_RBUTTONDOWN, c.WM_MBUTTONDOWN, c.WM_XBUTTONDOWN,
    }) |message_type| {
        NativeMenuDispatchTest.reset();
        window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
        var interruption = std.mem.zeroes(c.MSG);
        interruption.hwnd = fixture.child;
        interruption.message = message_type;
        window.dispatchMessage(&interruption, NativeMenuDispatchTest.eligible, fixture.child);
        try std.testing.expect(window.pending_native_f10 == null);
        window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, fixture.child);
        // A real native orphan release also must not find a flag left by our buffered down.
        _ = c.DefWindowProcW(up.hwnd, up.message, up.wParam, up.lParam);
        try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
    }
    for ([_]c.UINT{ c.WM_DESTROY, c.WM_NCDESTROY }) |message_type| {
        window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
        window.cancelNativeF10ForMessage(message_type, 0, 0);
        try std.testing.expect(window.pending_native_f10 == null);
    }
    for ([_]c.UINT{ c.WM_KEYDOWN, c.WM_KEYUP }) |message_type| {
        NativeMenuDispatchTest.reset();
        window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
        var ordinary = down;
        ordinary.message = message_type;
        ordinary.wParam = c.VK_LEFT;
        window.dispatchMessage(&ordinary, NativeMenuDispatchTest.eligible, fixture.child);
        window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, fixture.child);
        try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
        try std.testing.expectEqual(@as(usize, 2), NativeMenuDispatchTest.keys_consumed);
    }
}

test "native F10 eligibility changes reject modifiers focus modal and foreign targets" {
    const fixture = try NativeMenuDispatchTest.init();
    defer fixture.deinit();
    var window = Window{ .hwnd = fixture.parent };
    var down = NativeMenuDispatchTest.key(fixture.child, c.WM_KEYDOWN);
    var up = NativeMenuDispatchTest.key(fixture.child, c.WM_KEYUP);
    inline for (.{ "ctrl", "shift", "alt", "active", "owner_enabled", "target_owned", "target_visible", "target_enabled" }) |field| {
        var excluded = NativeMenuDispatchTest.eligible;
        @field(excluded, field) = !@field(excluded, field);
        NativeMenuDispatchTest.reset();
        window.dispatchMessage(&down, excluded, fixture.child);
        window.dispatchMessage(&up, excluded, fixture.child);
        try std.testing.expect(window.pending_native_f10 == null);
        try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
        try std.testing.expectEqual(@as(usize, 2), NativeMenuDispatchTest.keys_consumed);
        window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
        window.dispatchMessage(&up, excluded, fixture.child);
        try std.testing.expect(window.pending_native_f10 == null);
        _ = c.DefWindowProcW(up.hwnd, up.message, up.wParam, up.lParam);
        try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
    }
    // An ineligible intervening dispatch cancels even if eligibility is restored at release.
    window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
    var tick = std.mem.zeroes(c.MSG);
    tick.hwnd = fixture.parent;
    tick.message = c.WM_NULL;
    window.dispatchMessage(&tick, .{}, null);
    window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, fixture.child);
    try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);

    // Never acquire a pair when real owner/target native facts contradict supplied context.
    _ = c.EnableWindow(fixture.parent, 0);
    window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
    try std.testing.expect(window.pending_native_f10 == null);
    _ = c.EnableWindow(fixture.parent, 1);
    _ = c.EnableWindow(fixture.child, 0);
    window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
    try std.testing.expect(window.pending_native_f10 == null);
    _ = c.EnableWindow(fixture.child, 1);
    window.dispatchMessage(&down, KeyContext.capture(fixture.parent, fixture.child), fixture.child);
    try std.testing.expect(window.pending_native_f10 == null);
    window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, null);
    try std.testing.expect(window.pending_native_f10 == null);
    const other = c.CreateWindowExW(0, NativeMenuDispatchTest.name, NativeMenuDispatchTest.name, c.WS_OVERLAPPED,
        0, 0, 20, 20, null, null, c.GetModuleHandleW(null), null) orelse return error.WindowCreationFailed;
    defer _ = c.DestroyWindow(other);
    var foreign_down = down;
    foreign_down.hwnd = other;
    window.dispatchMessage(&foreign_down, NativeMenuDispatchTest.eligible, other);
    try std.testing.expect(window.pending_native_f10 == null);
    window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
    var changed_target_up = up;
    changed_target_up.hwnd = fixture.parent;
    window.dispatchMessage(&changed_target_up, NativeMenuDispatchTest.eligible, fixture.parent);
    try std.testing.expect(window.pending_native_f10 == null);
    try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
    window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
    const menu = c.GetMenu(fixture.parent);
    try std.testing.expect(c.SetMenu(fixture.parent, null) != 0);
    window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, fixture.child);
    try std.testing.expect(window.pending_native_f10 == null);
    try std.testing.expect(c.SetMenu(fixture.parent, menu) != 0);
    try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
}

test "native F10 dispatch preserves header pretranslation accelerator and context menu ordering" {
    const fixture = try NativeMenuDispatchTest.init();
    defer fixture.deinit();
    const Header = struct {
        var calls: usize = 0;
        var consume: bool = false;
        fn callback(_: ?*anyopaque, _: usize, _: bool, _: bool, _: bool) bool {
            calls += 1;
            return consume;
        }
    };
    var window = Window{ .hwnd = fixture.parent, .key_callback = &Header.callback };
    var entries = [_]c.ACCEL{
        .{ .fVirt = c.FVIRTKEY, .key = c.VK_F10, .cmd = @intFromEnum(Command.about) },
    };
    window.accelerators = c.CreateAcceleratorTableW(&entries, entries.len) orelse return error.AcceleratorCreationFailed;
    const test_accelerators = window.accelerators;
    defer _ = c.DestroyAcceleratorTable(test_accelerators);
    var down = NativeMenuDispatchTest.key(fixture.child, c.WM_KEYDOWN);
    var up = NativeMenuDispatchTest.key(fixture.child, c.WM_KEYUP);
    NativeMenuDispatchTest.reset();
    Header.calls = 0;
    Header.consume = true;
    window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
    try std.testing.expectEqual(@as(usize, 1), Header.calls);
    try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.command);
    try std.testing.expect(window.pending_native_f10 == null);
    Header.consume = false;
    window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
    try std.testing.expectEqual(@as(usize, 2), Header.calls);
    try std.testing.expectEqual(@as(usize, @intFromEnum(Command.about)), NativeMenuDispatchTest.command);
    try std.testing.expect(window.pending_native_f10 == null);
    window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, fixture.child);
    try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
    try std.testing.expectEqual(@as(usize, 1), NativeMenuDispatchTest.keys_consumed);

    NativeMenuDispatchTest.reset();
    var system_down = NativeMenuDispatchTest.key(fixture.child, c.WM_SYSKEYDOWN);
    var system_up = NativeMenuDispatchTest.key(fixture.child, c.WM_SYSKEYUP);
    window.dispatchMessage(&system_down, NativeMenuDispatchTest.eligible, fixture.child);
    try std.testing.expectEqual(@as(usize, 2), Header.calls);
    try std.testing.expectEqual(@as(usize, @intFromEnum(Command.about)), NativeMenuDispatchTest.command);
    try std.testing.expect(window.pending_native_f10 == null);
    window.dispatchMessage(&system_up, NativeMenuDispatchTest.eligible, fixture.child);
    try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
    try std.testing.expectEqual(@as(usize, 1), NativeMenuDispatchTest.keys_consumed);

    // Alt-context F10 and context-menu requests remain normal child dispatch.
    NativeMenuDispatchTest.reset();
    window.accelerators = null;
    down.message = c.WM_SYSKEYDOWN;
    up.message = c.WM_SYSKEYUP;
    down.lParam |= 1 << 29;
    up.lParam |= 1 << 29;
    window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, fixture.child);
    window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, fixture.child);
    var context = std.mem.zeroes(c.MSG);
    context.hwnd = fixture.child;
    context.message = c.WM_CONTEXTMENU;
    window.dispatchMessage(&context, NativeMenuDispatchTest.eligible, fixture.child);
    try std.testing.expectEqual(@as(usize, 2), NativeMenuDispatchTest.keys_consumed);
    try std.testing.expectEqual(@as(usize, 1), NativeMenuDispatchTest.contexts);
    try std.testing.expectEqual(@as(usize, 0), NativeMenuDispatchTest.menu_commands);
}

test "native F10 owner notifications cancel a buffered pair before native processing" {
    const Probe = struct {
        var menus: usize = 0;
        fn callback(_: ?*anyopaque, _: c.HWND, message: c.UINT, wparam: c.WPARAM, _: c.LPARAM, result: *c.LRESULT) callconv(.c) bool {
            if (message == c.WM_SYSCOMMAND and (wparam & 0xfff0) == c.SC_KEYMENU) {
                menus += 1;
                result.* = 0;
                return true;
            }
            return false;
        }
    };
    var window = Window{ .callback = &Probe.callback };
    const instance = c.GetModuleHandleW(null);
    try registerClass(instance);
    const hwnd = c.CreateWindowExW(0, class_name.ptr, class_name.ptr, c.WS_OVERLAPPEDWINDOW,
        0, 0, 100, 100, null, null, instance, &window) orelse return error.WindowCreationFailed;
    defer _ = c.DestroyWindow(hwnd);
    try installMenu(hwnd);
    try std.testing.expectEqual(hwnd, window.hwnd);
    try std.testing.expect(c.IsWindowVisible(hwnd) == 0);
    var down = NativeMenuDispatchTest.key(hwnd, c.WM_KEYDOWN);
    var up = NativeMenuDispatchTest.key(hwnd, c.WM_KEYUP);
    Probe.menus = 0;
    window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, hwnd);
    try std.testing.expect(window.pending_native_f10 != null);
    _ = c.SendMessageW(hwnd, c.WM_CANCELMODE, 0, 0);
    try std.testing.expect(window.pending_native_f10 == null);
    window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, hwnd);
    try std.testing.expectEqual(@as(usize, 0), Probe.menus);
    window.dispatchMessage(&down, NativeMenuDispatchTest.eligible, hwnd);
    _ = c.EnableWindow(hwnd, 0);
    try std.testing.expect(window.pending_native_f10 == null);
    _ = c.EnableWindow(hwnd, 1);
    window.dispatchMessage(&up, NativeMenuDispatchTest.eligible, hwnd);
    try std.testing.expectEqual(@as(usize, 0), Probe.menus);
    try std.testing.expect(c.IsWindowVisible(hwnd) == 0);
}

test "native F10 rejects a real owner on another GUI thread" {
    const fixture = try NativeMenuDispatchTest.init();
    defer fixture.deinit();
    const OtherThread = struct {
        ready: std.Thread.ResetEvent = .{},
        stop: std.Thread.ResetEvent = .{},
        hwnd: c.HWND = null,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.hwnd = c.CreateWindowExW(0, NativeMenuDispatchTest.name, NativeMenuDispatchTest.name,
                c.WS_OVERLAPPEDWINDOW, 0, 0, 50, 50, null, null,
                c.GetModuleHandleW(null), null);
            if (self.hwnd == null) {
                self.failure = error.WindowCreationFailed;
                self.ready.set();
                return;
            }
            defer _ = c.DestroyWindow(self.hwnd);
            installMenu(self.hwnd) catch |err| {
                self.failure = err;
                self.ready.set();
                return;
            };
            self.ready.set();
            self.stop.wait();
        }
    };
    var other = OtherThread{};
    const thread = try std.Thread.spawn(.{}, OtherThread.run, .{&other});
    defer {
        other.stop.set();
        thread.join();
    }
    try other.ready.timedWait(5 * std.time.ns_per_s);
    if (other.failure) |failure| return failure;
    const window = Window{ .hwnd = other.hwnd };
    try std.testing.expect(c.IsWindowVisible(other.hwnd) == 0);
    try std.testing.expect(!window.nativeF10TargetEligible(other.hwnd, NativeMenuDispatchTest.eligible, other.hwnd));
}

test "pretranslation invokes the real header key classifier only for eligible input" {
    const Probe = struct {
        focused: bool = false,
        calls: usize = 0,
        fn callback(context: ?*anyopaque, key: usize, ctrl: bool, shift: bool, alt: bool) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            const action = @import("InputRouter.zig").headerKey(key, ctrl, shift, alt, self.focused);
            if (action == .enter) self.focused = true;
            if (action == .exit) self.focused = false;
            return action != .none;
        }
    };
    var probe = Probe{};
    var window = Window{ .context = &probe, .key_callback = &Probe.callback };
    const eligible = KeyContext{ .active = true, .owner_enabled = true, .target_owned = true, .target_visible = true, .target_enabled = true };
    var message = std.mem.zeroes(c.MSG);
    message.message = c.WM_KEYDOWN;
    message.wParam = c.VK_TAB;
    try std.testing.expect(!window.pretranslateKey(&message, eligible));
    message.wParam = c.VK_F6;
    try std.testing.expect(window.pretranslateKey(&message, eligible));
    try std.testing.expect(probe.focused);
    message.wParam = c.VK_TAB;
    try std.testing.expect(window.pretranslateKey(&message, eligible));
    var modified = eligible;
    modified.ctrl = true;
    try std.testing.expect(!window.pretranslateKey(&message, modified));
    modified = eligible;
    modified.alt = true;
    try std.testing.expect(!window.pretranslateKey(&message, modified));
    message.wParam = c.VK_F6;
    try std.testing.expect(!window.pretranslateKey(&message, modified));
    for ([_][]const u8{ "active", "owner_enabled", "target_owned", "target_visible", "target_enabled" }) |field| {
        var excluded = eligible;
        inline for (.{ "active", "owner_enabled", "target_owned", "target_visible", "target_enabled" }) |name| {
            if (std.mem.eql(u8, field, name)) @field(excluded, name) = false;
        }
        const calls = probe.calls;
        try std.testing.expect(!window.pretranslateKey(&message, excluded));
        try std.testing.expectEqual(calls, probe.calls);
    }
    for ([_]c.UINT{ c.WM_SYSKEYDOWN, c.WM_KEYUP, c.WM_COMMAND }) |message_type| {
        message.message = message_type;
        const calls = probe.calls;
        try std.testing.expect(!window.pretranslateKey(&message, eligible));
        try std.testing.expectEqual(calls, probe.calls);
    }
    message.message = c.WM_KEYDOWN;
    try std.testing.expect(window.pretranslateKey(&message, eligible));
    try std.testing.expect(!probe.focused);
    message.wParam = c.VK_TAB;
    try std.testing.expect(!window.pretranslateKey(&message, eligible));
}

test "toolbar routing rejects hidden windows without changing accelerator contracts" {
    const DispatchProbe = struct {
        var command: usize = 0;
        fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
            if (message == c.WM_COMMAND) {
                command = wparam & 0xffff;
                return 0;
            }
            return c.DefWindowProcW(hwnd, message, wparam, lparam);
        }
    };
    const test_class = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeHiddenAcceleratorTest");
    var window_class = std.mem.zeroes(c.WNDCLASSW);
    window_class.hInstance = c.GetModuleHandleW(null);
    window_class.lpszClassName = test_class;
    window_class.lpfnWndProc = &DispatchProbe.windowProc;
    if (c.RegisterClassW(&window_class) == 0) return error.WindowClassRegistrationFailed;
    defer _ = c.UnregisterClassW(test_class, window_class.hInstance);
    const hwnd = c.CreateWindowExW(
        0,
        test_class,
        std.unicode.utf8ToUtf16LeStringLiteral("Hidden toolbar routing test"),
        c.WS_OVERLAPPED,
        0,
        0,
        100,
        100,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.WindowCreationFailed;
    defer _ = c.DestroyWindow(hwnd);
    const child = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral("Child"),
        c.WS_CHILD,
        0,
        0,
        20,
        20,
        hwnd,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.WindowCreationFailed;
    defer _ = c.DestroyWindow(child);
    try std.testing.expect(!keyOwnerEligible(hwnd, hwnd));
    try std.testing.expect(!keyOwnerEligible(hwnd, child));
    try std.testing.expect(!keyOwnerEligible(hwnd, null));
    const accelerators = createAccelerators() orelse return error.AcceleratorCreationFailed;
    defer _ = c.DestroyAcceleratorTable(accelerators);
    var entries: [32]c.ACCEL = undefined;
    const count = c.CopyAcceleratorTableW(accelerators, &entries, entries.len);
    try std.testing.expect(count > 0);
    var tab_count: usize = 0;
    for (entries[0..@intCast(count)]) |entry| {
        if (entry.key != c.VK_TAB) continue;
        tab_count += 1;
        const expected: Command = if ((entry.fVirt & c.FCONTROL) != 0)
            .review_attention
        else if ((entry.fVirt & c.FSHIFT) != 0)
            .previous_loop
        else
            .next_loop;
        try std.testing.expectEqual(@intFromEnum(expected), entry.cmd);
    }
    try std.testing.expectEqual(@as(usize, 3), tab_count);
    try installMenu(hwnd);
    try std.testing.expect(c.GetMenuState(c.GetMenu(hwnd), @intFromEnum(Command.focus_header), c.MF_BYCOMMAND) != 0xffffffff);
    var message = std.mem.zeroes(c.MSG);
    message.hwnd = hwnd;
    message.message = c.WM_KEYDOWN;
    message.wParam = c.VK_TAB;
    DispatchProbe.command = 0;
    try std.testing.expect(c.TranslateAcceleratorW(hwnd, accelerators, &message) != 0);
    try std.testing.expectEqual(@as(usize, @intFromEnum(Command.next_loop)), DispatchProbe.command);
}

fn testWindowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

const workspace_test_class = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeWorkspaceIdentityTest");

fn hiddenWorkspaceTestWindow() !c.HWND {
    var wc = std.mem.zeroes(c.WNDCLASSW);
    wc.lpfnWndProc = testWindowProc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.lpszClassName = workspace_test_class.ptr;
    if (c.RegisterClassW(&wc) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.TestWindowClassFailed;
    return c.CreateWindowExW(
        0,
        workspace_test_class.ptr,
        std.unicode.utf8ToUtf16LeStringLiteral("Hidden workspace fixture").ptr,
        c.WS_OVERLAPPEDWINDOW,
        0,
        0,
        0,
        0,
        null,
        null,
        wc.hInstance,
        null,
    ) orelse error.TestWindowCreationFailed;
}

test "workspace lookup selects only the exact identified window and flags legacy ambiguity" {
    const alpha = try hiddenWorkspaceTestWindow();
    defer _ = c.DestroyWindow(alpha);
    const beta = try hiddenWorkspaceTestWindow();
    defer _ = c.DestroyWindow(beta);
    const key_alpha = std.unicode.utf8ToUtf16LeStringLiteral("workspace-fixture-alpha");
    const key_beta = std.unicode.utf8ToUtf16LeStringLiteral("workspace-fixture-beta");
    const missing = std.unicode.utf8ToUtf16LeStringLiteral("workspace-fixture-missing");
    try publishWorkspaceIdentity(alpha, key_alpha);
    try publishWorkspaceIdentity(beta, key_beta);
    const found = try workspaceWindowsForClass(key_beta, workspace_test_class);
    try std.testing.expectEqual(beta, found.target);
    try std.testing.expect(!found.unidentified);
    try invalidateWorkspaceIdentity(beta);
    const invalidated = try workspaceWindowsForClass(key_beta, workspace_test_class);
    try std.testing.expect(invalidated.unidentified);
    try std.testing.expect(invalidated.target == null);
    try std.testing.expect(!workspaceIdentityMatches(beta, key_beta));
    try publishWorkspaceIdentity(beta, key_beta);
    try std.testing.expectEqual(beta, (try workspaceWindowsForClass(key_beta, workspace_test_class)).target);
    try std.testing.expect((try workspaceWindowsForClass(missing, workspace_test_class)).target == null);
    const legacy = try hiddenWorkspaceTestWindow();
    defer _ = c.DestroyWindow(legacy);
    const uncertain = try workspaceWindowsForClass(missing, workspace_test_class);
    try std.testing.expect(uncertain.unidentified);
    try std.testing.expect(uncertain.target == null);
    try publishWorkspaceIdentity(alpha, key_beta);
    try std.testing.expectError(error.AmbiguousWorkspaceWindow, workspaceWindowsForClass(key_beta, workspace_test_class));
}

fn expectDisabledWorkspaceCommand(menu: c.HMENU, command: Command) !void {
    const state = c.GetMenuState(menu, @intFromEnum(command), c.MF_BYCOMMAND);
    try std.testing.expect(state != std.math.maxInt(c.UINT));
    try std.testing.expect(state & c.MF_GRAYED != 0);
}

test "workspace menu checks the exact command and retains target labels and enablement" {
    const hwnd = try hiddenWorkspaceTestWindow();
    defer _ = c.DestroyWindow(hwnd);
    try installMenu(hwnd);
    const menu = c.GetSubMenu(c.GetMenu(hwnd), 3);
    var items = [_]WorkspaceItem{
        .{ .name = "Default", .is_current = false },
        .{ .name = "alpha", .is_current = true },
        .{ .name = "beta", .is_current = false },
    };
    for ([_]usize{ 1, 2 }) |selected| {
        for (&items, 0..) |*item, index| item.is_current = index == selected;
        updateWorkspaceMenu(hwnd, &items);
        for (items, 0..) |item, index| {
            const command: c.UINT = @intCast(workspace_command_base + index);
            const state = c.GetMenuState(menu, command, c.MF_BYCOMMAND);
            try std.testing.expect(state != std.math.maxInt(c.UINT));
            try std.testing.expectEqual(index == selected, state & c.MF_CHECKED != 0);
            var label: [128]u16 = undefined;
            const length = c.GetMenuStringW(menu, command, &label, label.len, c.MF_BYCOMMAND);
            const actual = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, label[0..@intCast(length)]);
            defer std.testing.allocator.free(actual);
            try std.testing.expectEqualStrings(item.name, actual);
        }
        try std.testing.expect(c.GetMenuState(menu, @intFromEnum(Command.workspace_next), c.MF_BYCOMMAND) & c.MF_GRAYED == 0);
    }
    updateWorkspaceMenu(hwnd, items[0..1]);
    try expectDisabledWorkspaceCommand(menu, .workspace_next);
    try std.testing.expect(c.DeleteMenu(menu, @intFromEnum(Command.workspace_next), c.MF_BYCOMMAND) != 0);
    try std.testing.expectError(error.TestUnexpectedResult, expectDisabledWorkspaceCommand(menu, .workspace_next));
    updateWorkspaceMenu(hwnd, &.{});
    try expectDisabledWorkspaceCommand(menu, .workspace_rename);
    try std.testing.expect(c.DeleteMenu(menu, @intFromEnum(Command.workspace_rename), c.MF_BYCOMMAND) != 0);
    try std.testing.expectError(error.TestUnexpectedResult, expectDisabledWorkspaceCommand(menu, .workspace_rename));
}

// Regression test for the Update-command re-enable bug: a real background
// update check completes almost instantly, but `finishUpdateCheck` only
// refreshed menu state through `updateNativeChrome`, which is gated on
// daemon connectivity and can leave "Check for Updates" permanently
// disabled. `setUpdateCheckEnabled` must flip the *actual* native menu bit
// for the command by itself, independent of any other menu state, using a
// real HMENU/HWND rather than an in-memory model, so this exercises the
// genuine Win32 EnableMenuItem/GetMenuState round trip the shell relies on.
test "setUpdateCheckEnabled toggles only the Check for Updates command's real menu bit" {
    const test_class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeMainWindowTestClass");
    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = testWindowProc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.lpszClassName = test_class_name;
    // Registration can already exist if this test runs more than once in the
    // same process; either outcome leaves the class name usable below.
    _ = c.RegisterClassExW(&wc);

    const hwnd = c.CreateWindowExW(
        0,
        test_class_name,
        std.unicode.utf8ToUtf16LeStringLiteral("GraphCode MainWindow test"),
        c.WS_OVERLAPPEDWINDOW,
        0,
        0,
        0,
        0,
        null,
        null,
        wc.hInstance,
        null,
    ) orelse return error.SkipZigTest;
    defer _ = c.DestroyWindow(hwnd);

    try installMenu(hwnd);

    const menu = c.GetMenu(hwnd);
    const command_id: c.UINT = @intFromEnum(Command.check_updates);

    setUpdateCheckEnabled(hwnd, false);
    const disabled_state = c.GetMenuState(menu, command_id, c.MF_BYCOMMAND);
    try std.testing.expect((disabled_state & c.MF_GRAYED) != 0);

    setUpdateCheckEnabled(hwnd, true);
    const enabled_state = c.GetMenuState(menu, command_id, c.MF_BYCOMMAND);
    try std.testing.expect((enabled_state & c.MF_GRAYED) == 0);

    // The toggle must be scoped to just this one command: an unrelated
    // command's enable state must be untouched by either call above.
    const worktrees_state = c.GetMenuState(menu, @intFromEnum(Command.worktrees), c.MF_BYCOMMAND);
    try std.testing.expect((worktrees_state & c.MF_GRAYED) == 0);
}

// Real (not faked) `SetGestureConfig` registration test. Positive control
// proves the exact array this code builds is accepted by the real Win32 API
// against a genuine, never-shown HWND (reusing the same non-activating test
// harness as `setUpdateCheckEnabled` above); negative control (a deliberately
// wrong `cbSize`) proves the failure branch actually fires and captures a
// nonzero `GetLastError()`, rather than the success path being trivially
// true regardless of what's passed.
test "registerCanvasGestureConfig succeeds with the real gesture array and captures errors on failure" {
    const test_class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeMainWindowGestureTestClass");
    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = testWindowProc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.lpszClassName = test_class_name;
    _ = c.RegisterClassExW(&wc);

    const hwnd = c.CreateWindowExW(
        0,
        test_class_name,
        std.unicode.utf8ToUtf16LeStringLiteral("GraphCode MainWindow gesture test"),
        c.WS_OVERLAPPEDWINDOW,
        0,
        0,
        0,
        0,
        null,
        null,
        wc.hInstance,
        null,
    ) orelse return error.SkipZigTest;
    defer _ = c.DestroyWindow(hwnd);

    const success = registerCanvasGestureConfig(hwnd);
    try std.testing.expect(success.ok);
    try std.testing.expectEqual(@as(c.DWORD, 0), success.last_error);

    // Negative control: call the real API directly with a corrupted cbSize
    // (rather than mocking anything) to prove SetGestureConfig genuinely
    // rejects a malformed array and that GetLastError reports a real,
    // nonzero code afterward.
    var bad_config = [_]c.GESTURECONFIG{
        .{ .dwID = c.GID_ZOOM, .dwWant = c.GC_ZOOM, .dwBlock = 0 },
    };
    const failed = c.SetGestureConfig(hwnd, 0, bad_config.len, &bad_config, 0);
    try std.testing.expectEqual(@as(c.BOOL, 0), failed);
    try std.testing.expect(c.GetLastError() != 0);
}

// The negative control above bypasses `registerCanvasGestureConfig` entirely
// (it calls the raw Win32 API with a malformed argument), so it only proves
// the OS API itself can fail -- it says nothing about whether this codebase's
// own helper actually surfaces that failure correctly. A `registerCanvasGestureConfig`
// that ignored `SetGestureConfig`'s return value and always reported success
// would still pass the test above. This exercises the production helper's
// own call with a genuinely invalid (never-created) HWND, so only a helper
// that truly captures and returns the real failure/GetLastError can pass it.
test "registerCanvasGestureConfig itself reports failure for a genuinely invalid HWND" {
    const bogus_hwnd = Win32.opaquePointerFromInt(c.HWND, 0xdeadbeef);
    const result = registerCanvasGestureConfig(bogus_hwnd);
    try std.testing.expect(!result.ok);
    try std.testing.expect(result.last_error != 0);
}

test "recent folder commands use a dedicated command range" {
    try std.testing.expect(isRecentFolderCommand(recent_folder_command_base));
    try std.testing.expect(isRecentFolderCommand(recent_folder_command_limit));
    try std.testing.expect(!isRecentFolderCommand(recent_folder_command_limit + 1));
}

test "workspace commands use a dedicated command range" {
    try std.testing.expect(workspace_command_base < workspace_command_limit);
    try std.testing.expectEqual(Command.workspace_new, commandFromId(4800).?);
}

test "popup initialization updates menu state without redrawing the active menu bar" {
    try std.testing.expect(redrawsMenuBar(.state_change));
    try std.testing.expect(!redrawsMenuBar(.popup_open));
}

test "gate fixture messages and timers never collide with shell traffic" {
    try std.testing.expect(wm_uia_context_menu != wm_app_tick);
    try std.testing.expect(wm_uia_context_menu != wm_uia_fixture_mutate);
    try std.testing.expect(wm_uia_context_menu > c.WM_APP);
    try std.testing.expect(wm_uia_present_form != wm_app_tick);
    try std.testing.expect(wm_uia_present_form != wm_uia_fixture_mutate);
    try std.testing.expect(wm_uia_present_form != wm_uia_context_menu);
    try std.testing.expect(wm_uia_present_form > c.WM_APP);
    try std.testing.expect(menu_watchdog_timer_id != timer_id);
    try std.testing.expect(menu_watchdog_interval_ms > 0);
}

test "native menu labels are NUL terminated UTF-16" {    const wide = try toWideZ(std.testing.allocator, "Clone Repository…");
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
    window_class.hCursor = c.LoadCursorW(null, Win32.resourceIdentifier(32512));
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
        const create = Win32.messagePointer(*const c.CREATESTRUCTW, lparam);
        window = @ptrCast(@alignCast(create.lpCreateParams));
        if (window) |value| {
            value.hwnd = hwnd;
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @intCast(@intFromPtr(value)));
        }
    }
    const value = window orelse return c.DefWindowProcW(hwnd, message, wparam, lparam);
    value.cancelNativeF10ForMessage(message, wparam, lparam);
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
