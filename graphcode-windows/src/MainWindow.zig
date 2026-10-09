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

pub const TerminalKeyRoute = @import("TerminalKeys.zig").Route;

/// Reports how a key aimed at `message.hwnd` is handled when that window is a terminal.
pub const TerminalRouteCallback = *const fn (
    context: ?*anyopaque,
    message: *const c.MSG,
    ctrl: bool,
    shift: bool,
    alt: bool,
) TerminalKeyRoute;

const MessageDispatchApi = struct {
    const translateAccelerator = c.TranslateAcceleratorW;
    const translateMessage = c.TranslateMessage;
    const dispatchMessage = c.DispatchMessageW;
    pub const postMessage = c.PostMessageW;
};

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
    terminal_copy = 4309,
    terminal_paste = 4310,
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
    has_jump_target: bool,
    can_navigate_loops: bool,
    can_create_edge: bool,
    has_selected_loop: bool,
    has_workspace: bool,
    can_cycle_tabs: bool,
    can_cycle_panes: bool,
    has_attention: bool,
    can_close_tab: bool,
    /// The focused terminal reports selected text to copy.
    can_copy_terminal: bool = false,
    /// A live terminal exists to receive pasted text.
    can_paste_terminal: bool = false,
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

/// Registers native pan (with OS inertia) and pinch-zoom gestures. Every
/// other WM_GESTURE class remains at its existing default (neither explicitly
/// enabled nor blocked). `SetGestureConfig` documents that a single call
/// cannot mix a `dwID = 0` "all gestures" entry with specific-`dwID` entries,
/// so this uses one specific-`dwID` entry per supported gesture.
fn canvasGestureConfigs() [2]c.GESTURECONFIG {
    return .{
        .{ .dwID = c.GID_PAN, .dwWant = c.GC_PAN | c.GC_PAN_WITH_INERTIA, .dwBlock = 0 },
        .{ .dwID = c.GID_ZOOM, .dwWant = c.GC_ZOOM, .dwBlock = 0 },
    };
}

pub fn registerCanvasGestureConfig(hwnd: c.HWND) GestureConfigResult {
    var configs = canvasGestureConfigs();
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
    terminal_route: ?TerminalRouteCallback = null,
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
        self.dispatchMessageWith(MessageDispatchApi, message, keys, focused);
    }

    pub fn dispatchMessageWith(self: *Window, comptime Api: type, message: *c.MSG, keys: KeyContext, focused: c.HWND) void {
        if (self.consumeRejectedCycleKey(message, keys)) return;
        if (self.pretranslateKey(message, keys)) {
            self.pending_native_f10 = null;
            return;
        }
        const route = self.terminalRouteFor(message, keys);
        switch (route) {
            .default, .terminal => {},
            .close_tab => {
                self.postWindowMessage(Api, c.WM_COMMAND, @intFromEnum(Command.close_tab), 0);
                return;
            },
            .system_close => {
                self.postWindowMessage(Api, c.WM_SYSCOMMAND, c.SC_CLOSE, 0);
                return;
            },
            .system_menu => {
                self.postWindowMessage(Api, c.WM_SYSCOMMAND, c.SC_KEYMENU, ' ');
                return;
            },
        }
        const ordinary_tab = message.message == c.WM_KEYDOWN and message.wParam == c.VK_TAB and !keys.ctrl and !keys.alt;
        const accelerator_eligible = route != .terminal and (!ordinary_tab or
            (self.hwnd != null and message.hwnd == self.hwnd and focused == self.hwnd and keys.eligible()));
        if (accelerator_eligible and self.accelerators != null and Api.translateAccelerator(self.hwnd, self.accelerators, message) != 0) {
            self.pending_native_f10 = null;
            return;
        }
        if (self.dispatchNativeF10(message, keys, focused)) return;
        _ = Api.translateMessage(message);
        _ = Api.dispatchMessage(message);
    }

    fn terminalRouteFor(self: *Window, message: *const c.MSG, keys: KeyContext) TerminalKeyRoute {
        if (message.message != c.WM_KEYDOWN and message.message != c.WM_SYSKEYDOWN) return .default;
        if (!keys.eligible()) return .default;
        const callback = self.terminal_route orelse return .default;
        return callback(self.context, message, keys.ctrl, keys.shift, keys.alt);
    }

    fn postWindowMessage(self: *Window, comptime Api: type, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) void {
        if (self.hwnd == null) return;
        if (@hasDecl(Api, "postMessage")) _ = Api.postMessage(self.hwnd, message, wparam, lparam);
    }

    fn consumeRejectedCycleKey(self: *Window, message: *const c.MSG, keys: KeyContext) bool {
        if (cycleKeyEligible(message, keys)) return false;
        // A rejected cycle chord must not reach a child that discards Alt.
        self.pending_native_f10 = null;
        return true;
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
        if ((message.message != c.WM_KEYDOWN and cycleKeyMessage(message, keys) == null) or !keys.eligible()) return false;
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
    try restoreWorkspaceWith(WorkspaceRestoreApi, key, .target_first);
}

pub fn restoreCycleInstance(key: [:0]const u16) !void {
    try restoreWorkspaceWith(WorkspaceRestoreApi, key, .identified_only);
}

const WorkspaceRestorePolicy = enum { target_first, identified_only };
const WorkspaceRestoreApi = struct {
    const windows = workspaceWindows;
    const activate = activateWorkspaceWindow;
};

fn restoreWorkspaceWith(comptime Api: type, key: [:0]const u16, policy: WorkspaceRestorePolicy) !void {
    const windows = try Api.windows(key);
    if (policy == .identified_only and windows.unidentified) return error.UnidentifiedWorkspaceWindow;
    const hwnd = windows.target orelse return error.WorkspaceWindowNotFound;
    try Api.activate(hwnd, key);
}

fn activateWorkspaceWindow(hwnd: c.HWND, key: [:0]const u16) !void {
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
    const discovery = c.CreatePopupMenu() orelse return error.MenuCreationFailed;
    const workspace = c.CreatePopupMenu() orelse return error.MenuCreationFailed;

    append(add_folder, "Open Folder...\tCtrl+O", @intFromEnum(Command.open_folder));
    append(add_folder, "Clone Repository...\tCtrl+Shift+C outside terminal", @intFromEnum(Command.clone_repository));
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
    append(file, "Project Worktree Policy...\tCtrl+Shift+P", @intFromEnum(Command.edit_worktree_policy));
    append(file, "Save Worktree Policy\tCtrl+Shift+S", @intFromEnum(Command.save_worktree_policy));
    separator(file);
    append(file, "Exit", @intFromEnum(Command.exit));

    append(loop, "Jump to Loop...\tCtrl+J", @intFromEnum(Command.jump_loop));
    append(loop, "Review What Needs You\tCtrl+Tab", @intFromEnum(Command.review_attention));
    separator(loop);
    append(loop, "Next Loop\tTab", @intFromEnum(Command.next_loop));
    append(loop, "Previous Loop\tShift+Tab", @intFromEnum(Command.previous_loop));
    separator(loop);
    append(loop, "New Loop...\tCtrl+Shift+N", @intFromEnum(Command.create_node));
    append(loop, "Create Edge...", @intFromEnum(Command.create_edge));
    append(loop, "Show in Graph\tCtrl+Shift+G", @intFromEnum(Command.show_graph));
    append(loop, "Stop Loop\tCtrl+S outside terminal", @intFromEnum(Command.stop_loop));

    append(terminal, "New Tab\tCtrl+Shift+T", @intFromEnum(Command.new_tab));
    append(terminal, "Close Tab\tCtrl+W (Ctrl+Shift+W in terminal)", @intFromEnum(Command.close_tab));
    separator(terminal);
    append(terminal, "Split Right\tAlt+Shift+D", @intFromEnum(Command.split_right));
    append(terminal, "Split Down\tCtrl+Shift+D", @intFromEnum(Command.split_down));
    separator(terminal);
    append(terminal, "Next Tab\tCtrl+PageDown", @intFromEnum(Command.next_tab));
    append(terminal, "Previous Tab\tCtrl+PageUp", @intFromEnum(Command.previous_tab));
    append(terminal, "Focus Next Pane\tCtrl+Shift+]", @intFromEnum(Command.focus_next_pane));
    append(terminal, "Focus Previous Pane\tCtrl+Shift+[", @intFromEnum(Command.focus_previous_pane));
    separator(terminal);
    append(terminal, "Copy\tCtrl+Shift+C", @intFromEnum(Command.terminal_copy));
    append(terminal, "Paste\tCtrl+Shift+V", @intFromEnum(Command.terminal_paste));

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
    append(view, "Reconnect\tCtrl+R", @intFromEnum(Command.reconnect));
    append(view, "Settings...\tCtrl+Shift+,", @intFromEnum(Command.product_settings));
    append(view, "Advanced Connection Settings...\tCtrl+,", @intFromEnum(Command.settings));
    append(help, "GraphCode Basics\tF1", @intFromEnum(Command.onboarding));
    append(help, "Check for Updates...", @intFromEnum(Command.check_updates));
    separator(help);
    append(help, "About GraphCode", @intFromEnum(Command.about));
    appendInfo(discovery, "Send selected loop\tCtrl+M");
    appendInfo(discovery, "Rename selected loop / edit selected edge\tCtrl+E");
    appendInfo(discovery, "Navigate by project or node\tCtrl+Up / Ctrl+Down");
    appendInfo(discovery, "Select a worktree row\tUp / Down");
    appendInfo(discovery, "Focus Terminal A\t1");
    appendInfo(discovery, "Focus Terminal B\t2");
    appendInfo(discovery, "Cancel clone\tCtrl+Shift+X");
    appendInfo(discovery, "Copy terminal text\tCtrl+Shift+C / Ctrl+Insert");
    appendInfo(discovery, "Paste terminal text\tCtrl+Shift+V / Shift+Insert");
    appendInfo(discovery, "Terminal context menu\tRight-click / Menu key / Shift+F10");
    appendInfo(discovery, "Terminal-focused Ctrl+D / W / S / T / N / [ / ]\tSent to the shell");
    appendInfo(discovery, "Focused toolbar: Tab / arrows / Home / End move; Enter / Space activate; Esc exits");
    appendInfo(discovery, "Jump palette: Up / Down navigate; Enter opens the selected loop");
    appendInfo(discovery, "Canvas: drag empty space to pan; wheel or pinch to zoom");
    appendInfo(discovery, "Sidebar: drag a root loop to reorder it");
    appendPopup(help, "Keyboard Shortcuts", discovery);

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
    setEnabled(hwnd, .jump_loop, state.has_jump_target);
    setEnabled(hwnd, .review_attention, state.has_attention);
    setEnabled(hwnd, .next_loop, state.can_navigate_loops);
    setEnabled(hwnd, .previous_loop, state.can_navigate_loops);
    setEnabled(hwnd, .create_node, state.has_project);
    setEnabled(hwnd, .create_edge, state.can_create_edge);
    setEnabled(hwnd, .stop_loop, state.has_selected_loop);
    setEnabled(hwnd, .show_graph, state.has_workspace);
    setEnabled(hwnd, .new_tab, state.has_workspace);
    setEnabled(hwnd, .close_tab, state.can_close_tab);
    setEnabled(hwnd, .split_right, state.has_workspace);
    setEnabled(hwnd, .split_down, state.has_workspace);
    setEnabled(hwnd, .next_tab, state.can_cycle_tabs);
    setEnabled(hwnd, .previous_tab, state.can_cycle_tabs);
    setEnabled(hwnd, .focus_next_pane, state.can_cycle_panes);
    setEnabled(hwnd, .focus_previous_pane, state.can_cycle_panes);
    setEnabled(hwnd, .terminal_copy, state.can_copy_terminal);
    setEnabled(hwnd, .terminal_paste, state.can_paste_terminal);
    setEnabled(hwnd, .settings, true);
    setEnabled(hwnd, .product_settings, true);
    setEnabled(hwnd, .reconnect, true);
    setEnabled(hwnd, .check_updates, !state.update_checking);
    setEnabled(hwnd, .workspace_manage, true);
    setEnabled(hwnd, .workspace_next, workspaceCycleAvailable(state.workspaces));
    setEnabled(hwnd, .workspace_previous, workspaceCycleAvailable(state.workspaces));
    setChecked(hwnd, .toggle_sidebar, state.sidebar_visible);
    setChecked(hwnd, .toggle_workspace, state.workspace_visible);
    setChecked(hwnd, .toggle_activity, state.activity_visible);
    if (redrawsMenuBar(refresh)) _ = c.DrawMenuBar(hwnd);
}

pub fn loopNavigationAvailable(loop_count: usize, selected_index: ?usize) bool {
    return loop_count > 1 or (loop_count == 1 and selected_index == null);
}

fn workspaceCycleAvailable(workspaces: []const WorkspaceItem) bool {
    // Like macOS, use known count, including this window outside the home listing.
    return workspaces.len > 1 or (workspaces.len == 1 and !workspaces[0].is_current);
}

test "workspace cycle capability counts an outside current without window queries" {
    const current = WorkspaceItem{ .name = "Default", .is_current = true };
    const other = WorkspaceItem{ .name = "Default", .is_current = false };
    try std.testing.expect(!workspaceCycleAvailable(&.{}));
    try std.testing.expect(!workspaceCycleAvailable(&.{current}));
    try std.testing.expect(workspaceCycleAvailable(&.{other}));
    try std.testing.expect(workspaceCycleAvailable(&.{ current, other }));
    try std.testing.expect(workspaceCycleAvailable(&.{ other, other }));
    var changed = [_]WorkspaceItem{other};
    try std.testing.expect(workspaceCycleAvailable(&changed));
    changed[0].is_current = true;
    try std.testing.expect(!workspaceCycleAvailable(&changed));
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
    appendEnabled(menu, "Manage Workspaces...", @intFromEnum(Command.workspace_manage), true);
    appendEnabled(menu, "Rename Workspace...", @intFromEnum(Command.workspace_rename), workspaces.len > 1);
    appendEnabled(menu, "Delete Workspace...", @intFromEnum(Command.workspace_delete), workspaces.len > 1);
    separator(menu);
    appendEnabled(menu, "Next Workspace\tCtrl+Alt+PageDown", @intFromEnum(Command.workspace_next), workspaceCycleAvailable(workspaces));
    appendEnabled(menu, "Previous Workspace\tCtrl+Alt+PageUp", @intFromEnum(Command.workspace_previous), workspaceCycleAvailable(workspaces));
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

fn appendInfo(menu: c.HMENU, text: []const u8) void {
    appendEnabled(menu, text, 0, false);
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

/// The terminal's right-click / Menu-key menu: the Terminal menu's Copy and Paste.
pub fn terminalContextMenu(can_copy: bool, can_paste: bool) c.HMENU {
    const menu = c.CreatePopupMenu() orelse return null;
    appendEnabled(menu, "Copy\tCtrl+Shift+C", @intFromEnum(Command.terminal_copy), can_copy);
    appendEnabled(menu, "Paste\tCtrl+Shift+V", @intFromEnum(Command.terminal_paste), can_paste);
    return menu;
}

/// Shows the terminal context menu at a screen point and returns the command the user chose.
pub fn showTerminalContextMenu(owner: c.HWND, can_copy: bool, can_paste: bool, x: i32, y: i32) ?Command {
    const menu = terminalContextMenu(can_copy, can_paste) orelse return null;
    defer _ = c.DestroyMenu(menu);
    const id = c.TrackPopupMenu(menu, c.TPM_RETURNCMD | c.TPM_NONOTIFY | c.TPM_RIGHTBUTTON, x, y, 0, owner, null);
    if (id <= 0) return null;
    return commandFromId(@intCast(id));
}

const accelerator_entries = [_]c.ACCEL{
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
        .{ .fVirt = c.FCONTROL | c.FSHIFT | c.FVIRTKEY, .key = c.VK_OEM_COMMA, .cmd = @intFromEnum(Command.product_settings) },
        .{ .fVirt = c.FCONTROL | c.FALT | c.FVIRTKEY, .key = c.VK_NEXT, .cmd = @intFromEnum(Command.workspace_next) },
        .{ .fVirt = c.FCONTROL | c.FALT | c.FVIRTKEY, .key = c.VK_PRIOR, .cmd = @intFromEnum(Command.workspace_previous) },
        // Terminal-safe alternatives for chords a focused terminal keeps for its program.
        .{ .fVirt = c.FCONTROL | c.FSHIFT | c.FVIRTKEY, .key = 'T', .cmd = @intFromEnum(Command.new_tab) },
        .{ .fVirt = c.FCONTROL | c.FSHIFT | c.FVIRTKEY, .key = 'N', .cmd = @intFromEnum(Command.create_node) },
        .{ .fVirt = c.FALT | c.FSHIFT | c.FVIRTKEY, .key = 'D', .cmd = @intFromEnum(Command.split_right) },
        .{ .fVirt = c.FCONTROL | c.FSHIFT | c.FVIRTKEY, .key = 0xDB, .cmd = @intFromEnum(Command.focus_previous_pane) },
        .{ .fVirt = c.FCONTROL | c.FSHIFT | c.FVIRTKEY, .key = 0xDD, .cmd = @intFromEnum(Command.focus_next_pane) },
};

pub fn workspaceCycleDirection(key: usize, ctrl: bool, shift: bool, alt: bool) ?isize {
    var flags: c.BYTE = c.FVIRTKEY;
    if (ctrl) flags |= c.FCONTROL;
    if (shift) flags |= c.FSHIFT;
    if (alt) flags |= c.FALT;
    for (accelerator_entries) |entry| {
        if (entry.key != key or entry.fVirt != flags) continue;
        return switch (entry.cmd) {
            @intFromEnum(Command.workspace_next) => 1,
            @intFromEnum(Command.workspace_previous) => -1,
            else => null,
        };
    }
    return null;
}

fn cycleKeyMessage(message: *const c.MSG, keys: KeyContext) ?isize {
    if (message.message != c.WM_KEYDOWN and message.message != c.WM_SYSKEYDOWN) return null;
    return workspaceCycleDirection(message.wParam, keys.ctrl, keys.shift, keys.alt);
}

fn cycleKeyEligible(message: *const c.MSG, keys: KeyContext) bool {
    return cycleKeyMessage(message, keys) == null or keys.eligible();
}

pub fn createAccelerators() c.HACCEL {
    var entries = accelerator_entries;
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

test "terminal routes decide accelerators, translation, and shell commands for a focused terminal" {
    const Api = struct {
        var accelerator_calls: usize = 0;
        var translation_calls: usize = 0;
        var dispatch_calls: usize = 0;
        var posts: usize = 0;
        var posted_message: c.UINT = 0;
        var posted_wparam: c.WPARAM = 0;

        pub fn translateAccelerator(_: c.HWND, _: c.HACCEL, _: *c.MSG) c_int {
            accelerator_calls += 1;
            return 1;
        }

        pub fn translateMessage(_: *const c.MSG) c.BOOL {
            translation_calls += 1;
            return 1;
        }

        pub fn dispatchMessage(_: *const c.MSG) c.LRESULT {
            dispatch_calls += 1;
            return 0;
        }

        pub fn postMessage(_: c.HWND, message: c.UINT, wparam: c.WPARAM, _: c.LPARAM) c.BOOL {
            posts += 1;
            posted_message = message;
            posted_wparam = wparam;
            return 1;
        }

        fn reset() void {
            accelerator_calls = 0;
            translation_calls = 0;
            dispatch_calls = 0;
            posts = 0;
        }
    };
    const Route = struct {
        var next: TerminalKeyRoute = .default;
        var calls: usize = 0;

        fn callback(_: ?*anyopaque, _: *const c.MSG, _: bool, _: bool, _: bool) TerminalKeyRoute {
            calls += 1;
            return next;
        }
    };
    const owner: c.HWND = @ptrFromInt(0x1000);
    const child: c.HWND = @ptrFromInt(0x2000);
    var window = Window{ .hwnd = owner, .accelerators = @ptrFromInt(0x3000), .terminal_route = &Route.callback };
    const keys = KeyContext{ .active = true, .owner_enabled = true, .target_owned = true, .target_visible = true, .target_enabled = true, .ctrl = true };
    var message = std.mem.zeroes(c.MSG);
    message.hwnd = child;
    message.message = c.WM_KEYDOWN;
    message.wParam = 'D';

    Api.reset();
    Route.next = .default;
    window.dispatchMessageWith(Api, &message, keys, child);
    try std.testing.expectEqual(@as(usize, 1), Api.accelerator_calls);
    try std.testing.expectEqual(@as(usize, 0), Api.dispatch_calls);

    // A terminal-owned chord skips the accelerator table and reaches the terminal window.
    Api.reset();
    Route.next = .terminal;
    window.dispatchMessageWith(Api, &message, keys, child);
    try std.testing.expectEqual(@as(usize, 0), Api.accelerator_calls);
    try std.testing.expectEqual(@as(usize, 1), Api.translation_calls);
    try std.testing.expectEqual(@as(usize, 1), Api.dispatch_calls);

    const commands = [_]struct { route: TerminalKeyRoute, message: c.UINT, wparam: c.WPARAM }{
        .{ .route = .close_tab, .message = c.WM_COMMAND, .wparam = @intFromEnum(Command.close_tab) },
        .{ .route = .system_close, .message = c.WM_SYSCOMMAND, .wparam = c.SC_CLOSE },
        .{ .route = .system_menu, .message = c.WM_SYSCOMMAND, .wparam = c.SC_KEYMENU },
    };
    for (commands) |case| {
        Api.reset();
        Route.next = case.route;
        window.dispatchMessageWith(Api, &message, keys, child);
        try std.testing.expectEqual(@as(usize, 1), Api.posts);
        try std.testing.expectEqual(case.message, Api.posted_message);
        try std.testing.expectEqual(case.wparam, Api.posted_wparam);
        try std.testing.expectEqual(@as(usize, 0), Api.accelerator_calls + Api.translation_calls + Api.dispatch_calls);
    }

    // The route is consulted only for key-down messages of an eligible, owned window.
    Api.reset();
    Route.calls = 0;
    Route.next = .close_tab;
    message.message = c.WM_KEYUP;
    window.dispatchMessageWith(Api, &message, keys, child);
    message.message = c.WM_KEYDOWN;
    window.dispatchMessageWith(Api, &message, .{}, child);
    try std.testing.expectEqual(@as(usize, 0), Route.calls);
    try std.testing.expectEqual(@as(usize, 0), Api.posts);
}

test "settings accelerator table preserves existing bindings and product destination" {
    const expected = [_]c.ACCEL{
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = 'O', .cmd = 4101 },
        .{ .fVirt = c.FCONTROL | c.FSHIFT | c.FVIRTKEY, .key = 'W', .cmd = 4103 },
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = 'J', .cmd = 4201 },
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = c.VK_TAB, .cmd = 4202 },
        .{ .fVirt = c.FVIRTKEY, .key = c.VK_TAB, .cmd = 4203 },
        .{ .fVirt = c.FSHIFT | c.FVIRTKEY, .key = c.VK_TAB, .cmd = 4204 },
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = 'N', .cmd = 4205 },
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = 'S', .cmd = 4207 },
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = 'T', .cmd = 4301 },
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = 'W', .cmd = 4302 },
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = 'D', .cmd = 4303 },
        .{ .fVirt = c.FCONTROL | c.FSHIFT | c.FVIRTKEY, .key = 'D', .cmd = 4304 },
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = c.VK_NEXT, .cmd = 4305 },
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = c.VK_PRIOR, .cmd = 4306 },
        .{ .fVirt = c.FCONTROL | c.FVIRTKEY, .key = c.VK_OEM_COMMA, .cmd = 4402 },
        .{ .fVirt = c.FCONTROL | c.FSHIFT | c.FVIRTKEY, .key = c.VK_OEM_COMMA, .cmd = 4403 },
        .{ .fVirt = c.FCONTROL | c.FALT | c.FVIRTKEY, .key = c.VK_NEXT, .cmd = 4804 },
        .{ .fVirt = c.FCONTROL | c.FALT | c.FVIRTKEY, .key = c.VK_PRIOR, .cmd = 4805 },
        .{ .fVirt = c.FCONTROL | c.FSHIFT | c.FVIRTKEY, .key = 'T', .cmd = 4301 },
        .{ .fVirt = c.FCONTROL | c.FSHIFT | c.FVIRTKEY, .key = 'N', .cmd = 4205 },
        .{ .fVirt = c.FALT | c.FSHIFT | c.FVIRTKEY, .key = 'D', .cmd = 4303 },
        .{ .fVirt = c.FCONTROL | c.FSHIFT | c.FVIRTKEY, .key = 0xDB, .cmd = 4308 },
        .{ .fVirt = c.FCONTROL | c.FSHIFT | c.FVIRTKEY, .key = 0xDD, .cmd = 4307 },
    };
    const accelerators = createAccelerators() orelse return error.AcceleratorCreationFailed;
    defer std.testing.expect(c.DestroyAcceleratorTable(accelerators) != 0) catch
        @panic("DestroyAcceleratorTable failed");
    try std.testing.expectEqual(@as(c_int, expected.len), c.CopyAcceleratorTableW(accelerators, null, 0));
    var entries: [expected.len]c.ACCEL = undefined;
    const count = c.CopyAcceleratorTableW(accelerators, &entries, entries.len);
    try std.testing.expectEqual(@as(c_int, expected.len), count);
    for (expected, entries) |binding, entry| {
        try std.testing.expectEqual(binding.fVirt, entry.fVirt);
        try std.testing.expectEqual(binding.key, entry.key);
        try std.testing.expectEqual(binding.cmd, entry.cmd);
    }
    const InputRouter = @import("InputRouter.zig");
    try std.testing.expectEqual(Command.settings, commandFromId(entries[14].cmd).?);
    try std.testing.expectEqual(Command.product_settings, commandFromId(entries[15].cmd).?);
    try std.testing.expectEqual(InputRouter.Action.settings, InputRouter.keyAction(entries[14].key, true, false));
    try std.testing.expectEqual(InputRouter.Action.product_settings, InputRouter.keyAction(entries[15].key, true, true));
}

test "native menu exposes the parity command groups" {
    try std.testing.expectEqual(Command.open_folder, commandFromId(4101).?);
    try std.testing.expectEqual(Command.split_right, commandFromId(4303).?);
    try std.testing.expectEqual(Command.about, commandFromId(4501).?);
    try std.testing.expectEqual(@as(?Command, null), commandFromId(9999));
}

test "main and help menus expose shortcuts and interaction guidance" {
    const hwnd = try hiddenWorkspaceTestWindow();
    defer _ = c.DestroyWindow(hwnd);
    try installMenu(hwnd);
    const root = c.GetMenu(hwnd);
    const file = c.GetSubMenu(root, 0);
    const loop = c.GetSubMenu(root, 1);
    const view = c.GetSubMenu(root, 4);
    const help = c.GetSubMenu(root, 5);

    const actual_labels = [_]struct { menu: c.HMENU, command: Command, expected: []const u8 }{
        .{ .menu = file, .command = .edit_worktree_policy, .expected = "Project Worktree Policy...\tCtrl+Shift+P" },
        .{ .menu = loop, .command = .show_graph, .expected = "Show in Graph\tCtrl+Shift+G" },
        .{ .menu = view, .command = .reconnect, .expected = "Reconnect\tCtrl+R" },
    };
    for (actual_labels) |item| {
        var label: [128]u16 = undefined;
        const length = c.GetMenuStringW(item.menu, @intFromEnum(item.command), &label, label.len, c.MF_BYCOMMAND);
        try std.testing.expect(length > 0 and length < label.len - 1);
        const actual = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, label[0..@intCast(length)]);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(item.expected, actual);
    }

    const guide = c.GetSubMenu(help, 4);
    try std.testing.expect(guide != null);
    const expected = [_][]const u8{
        "Send selected loop\tCtrl+M",
        "Rename selected loop / edit selected edge\tCtrl+E",
        "Navigate by project or node\tCtrl+Up / Ctrl+Down",
        "Select a worktree row\tUp / Down",
        "Focus Terminal A\t1",
        "Focus Terminal B\t2",
        "Cancel clone\tCtrl+Shift+X",
        "Copy terminal text\tCtrl+Shift+C / Ctrl+Insert",
        "Paste terminal text\tCtrl+Shift+V / Shift+Insert",
        "Terminal context menu\tRight-click / Menu key / Shift+F10",
        "Terminal-focused Ctrl+D / W / S / T / N / [ / ]\tSent to the shell",
        "Focused toolbar: Tab / arrows / Home / End move; Enter / Space activate; Esc exits",
        "Jump palette: Up / Down navigate; Enter opens the selected loop",
        "Canvas: drag empty space to pan; wheel or pinch to zoom",
        "Sidebar: drag a root loop to reorder it",
    };
    var guide_title: [128]u16 = undefined;
    const title_length = c.GetMenuStringW(help, 4, &guide_title, guide_title.len, c.MF_BYPOSITION);
    try std.testing.expect(title_length > 0 and title_length < guide_title.len - 1);
    const actual_title = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, guide_title[0..@intCast(title_length)]);
    defer std.testing.allocator.free(actual_title);
    try std.testing.expectEqualStrings("Keyboard Shortcuts", actual_title);
    for (expected, 0..) |expected_label, expected_index| {
        const index: c.UINT = @intCast(expected_index);
        var label: [128]u16 = undefined;
        const length = c.GetMenuStringW(guide, index, &label, label.len, c.MF_BYPOSITION);
        try std.testing.expect(length < label.len - 1);
        const actual = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, label[0..@intCast(length)]);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(expected_label, actual);
        try std.testing.expect(c.GetMenuState(guide, index, c.MF_BYPOSITION) & c.MF_GRAYED != 0);
    }
    const item_count = c.GetMenuItemCount(guide);
    try std.testing.expect(item_count > 0);
    try std.testing.expectEqual(@as(c_int, expected.len), item_count);
}

test "Ctrl+Shift+C discovery hints match terminal copy and outside-terminal clone routing" {
    const InputRouter = @import("InputRouter.zig");
    const accelerators = createAccelerators() orelse return error.AcceleratorCreationFailed;
    defer _ = c.DestroyAcceleratorTable(accelerators);
    var entries: [32]c.ACCEL = undefined;
    const count = c.CopyAcceleratorTableW(accelerators, &entries, entries.len);
    try std.testing.expect(count > 0);
    var ctrl_shift_c: usize = 0;
    for (entries[0..@intCast(count)]) |entry| {
        if (entry.key == 'C' and entry.fVirt == c.FCONTROL | c.FSHIFT | c.FVIRTKEY) ctrl_shift_c += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), ctrl_shift_c);
    try std.testing.expectEqual(InputRouter.Action.clone_repository, InputRouter.keyAction('C', true, true));

    const hwnd = try hiddenWorkspaceTestWindow();
    defer _ = c.DestroyWindow(hwnd);
    try installMenu(hwnd);
    const root = c.GetMenu(hwnd);
    const add_folder = c.GetSubMenu(c.GetSubMenu(root, 0), 0);
    try std.testing.expect(add_folder != null);
    var clone_label: [128]u16 = undefined;
    const clone_length = c.GetMenuStringW(add_folder, @intFromEnum(Command.clone_repository), &clone_label, clone_label.len, c.MF_BYCOMMAND);
    try std.testing.expect(clone_length > 0 and clone_length < clone_label.len - 1);
    const clone_actual = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, clone_label[0..@intCast(clone_length)]);
    defer std.testing.allocator.free(clone_actual);
    try std.testing.expectEqualStrings("Clone Repository...\tCtrl+Shift+C outside terminal", clone_actual);

    const guide = c.GetSubMenu(c.GetSubMenu(root, 5), 4);
    try std.testing.expect(guide != null);
    const guide_count = c.GetMenuItemCount(guide);
    try std.testing.expect(guide_count > 0);
    var copy_index: ?c.UINT = null;
    var paste_index: ?c.UINT = null;
    var index: c.UINT = 0;
    while (index < @as(c.UINT, @intCast(guide_count))) : (index += 1) {
        var label: [128]u16 = undefined;
        const length = c.GetMenuStringW(guide, index, &label, label.len, c.MF_BYPOSITION);
        if (length <= 0) continue;
        const actual = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, label[0..@intCast(length)]);
        defer std.testing.allocator.free(actual);
        if (std.mem.eql(u8, actual, "Copy terminal text\tCtrl+Shift+C / Ctrl+Insert")) {
            try std.testing.expectEqual(@as(?c.UINT, null), copy_index);
            copy_index = index;
        }
        if (std.mem.eql(u8, actual, "Paste terminal text\tCtrl+Shift+V / Shift+Insert")) paste_index = index;
    }
    const copy = copy_index orelse return error.TerminalCopyShortcutUndocumented;
    const paste = paste_index orelse return error.TerminalPasteShortcutUndocumented;
    try std.testing.expectEqual(copy + 1, paste);
    try std.testing.expect(c.GetMenuState(guide, copy, c.MF_BYPOSITION) & c.MF_GRAYED != 0);
    try std.testing.expectEqual(@as(c.UINT, 0), c.GetMenuItemID(guide, @intCast(copy)));
}

fn menuLabel(menu: c.HMENU, command: Command) ![]u8 {
    var label: [128]u16 = undefined;
    const length = c.GetMenuStringW(menu, @intFromEnum(command), &label, label.len, c.MF_BYCOMMAND);
    try std.testing.expect(length > 0 and length < label.len - 1);
    return std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, label[0..@intCast(length)]);
}

fn quietMenuState() MenuState {
    return .{
        .has_project = false,
        .can_worktrees = false,
        .worktree_dialog_open = false,
        .worktree_row_selected = false,
        .has_jump_target = false,
        .can_navigate_loops = false,
        .can_create_edge = false,
        .has_selected_loop = false,
        .has_workspace = false,
        .can_cycle_tabs = false,
        .can_cycle_panes = false,
        .has_attention = false,
        .can_close_tab = false,
        .sidebar_visible = false,
        .workspace_visible = false,
        .activity_visible = false,
        .update_checking = false,
    };
}

test "Terminal menu offers discoverable Copy and Paste that follow terminal state" {
    const hwnd = try hiddenWorkspaceTestWindow();
    defer _ = c.DestroyWindow(hwnd);
    try installMenu(hwnd);
    const terminal = c.GetSubMenu(c.GetMenu(hwnd), 2);
    try std.testing.expect(terminal != null);
    const copy = try menuLabel(terminal, .terminal_copy);
    defer std.testing.allocator.free(copy);
    const paste = try menuLabel(terminal, .terminal_paste);
    defer std.testing.allocator.free(paste);
    try std.testing.expectEqualStrings("Copy\tCtrl+Shift+C", copy);
    try std.testing.expectEqualStrings("Paste\tCtrl+Shift+V", paste);
    try std.testing.expect(c.GetMenuState(terminal, @intFromEnum(Command.terminal_copy), c.MF_BYCOMMAND) & c.MF_GRAYED == 0);

    var state = quietMenuState();
    updateMenu(hwnd, state, .state_change);
    try std.testing.expect(c.GetMenuState(terminal, @intFromEnum(Command.terminal_copy), c.MF_BYCOMMAND) & c.MF_GRAYED != 0);
    try std.testing.expect(c.GetMenuState(terminal, @intFromEnum(Command.terminal_paste), c.MF_BYCOMMAND) & c.MF_GRAYED != 0);
    state.can_paste_terminal = true;
    updateMenu(hwnd, state, .state_change);
    try std.testing.expect(c.GetMenuState(terminal, @intFromEnum(Command.terminal_copy), c.MF_BYCOMMAND) & c.MF_GRAYED != 0);
    try std.testing.expect(c.GetMenuState(terminal, @intFromEnum(Command.terminal_paste), c.MF_BYCOMMAND) & c.MF_GRAYED == 0);
    state.can_copy_terminal = true;
    updateMenu(hwnd, state, .state_change);
    try std.testing.expect(c.GetMenuState(terminal, @intFromEnum(Command.terminal_copy), c.MF_BYCOMMAND) & c.MF_GRAYED == 0);
}

test "terminal context menu carries the same Copy and Paste commands" {
    const menu = terminalContextMenu(false, true) orelse return error.MenuCreationFailed;
    defer _ = c.DestroyMenu(menu);
    try std.testing.expectEqual(@as(c_int, 2), c.GetMenuItemCount(menu));
    const copy = try menuLabel(menu, .terminal_copy);
    defer std.testing.allocator.free(copy);
    try std.testing.expectEqualStrings("Copy\tCtrl+Shift+C", copy);
    try std.testing.expect(c.GetMenuState(menu, @intFromEnum(Command.terminal_copy), c.MF_BYCOMMAND) & c.MF_GRAYED != 0);
    try std.testing.expect(c.GetMenuState(menu, @intFromEnum(Command.terminal_paste), c.MF_BYCOMMAND) & c.MF_GRAYED == 0);
    try std.testing.expectEqual(Command.terminal_paste, commandFromId(4310).?);
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
    window.accelerators = c.CreateAcceleratorTableW(&entries, entries.len) orelse {
        const last_error = c.GetLastError();
        std.log.err("F10 test stage=create-accelerator-table failed: error={d}, count={d}, ACCEL size={d}, alignment={d}", .{
            last_error, entries.len, @sizeOf(c.ACCEL), @alignOf(c.ACCEL),
        });
        for (entries, 0..) |entry, index| {
            std.log.err("F10 test ACCEL[{d}]: fVirt=0x{x}, key=0x{x}, cmd={d}", .{ index, entry.fVirt, entry.key, entry.cmd });
        }
        return error.AcceleratorCreationFailed;
    };
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

test "workspace running cycle final mixed lookup refuses without activation" {
    const Probe = struct {
        var activations: usize = 0;
        fn windows(_: [:0]const u16) !struct { target: ?usize, unidentified: bool } {
            return .{ .target = 7, .unidentified = true };
        }
        fn activate(_: usize, _: [:0]const u16) !void {
            activations += 1;
        }
    };
    Probe.activations = 0;
    const outcome = restoreWorkspaceWith(Probe, std.unicode.utf8ToUtf16LeStringLiteral("fixture-key"), .identified_only);
    try std.testing.expectEqual(@as(usize, 0), Probe.activations);
    try std.testing.expectError(error.UnidentifiedWorkspaceWindow, outcome);
}

test "workspace running cycle final lookup preserves ordinary restore and propagates failures" {
    const Probe = struct {
        const key = std.unicode.utf8ToUtf16LeStringLiteral("fixture-key");
        const Facts = struct { target: ?usize = 42, unidentified: bool = false };
        var facts: Facts = .{};
        var lookup_error: ?anyerror = null;
        var activation_error: ?anyerror = null;
        var lookups: usize = 0;
        var activations: usize = 0;
        fn windows(actual_key: [:0]const u16) !Facts {
            lookups += 1;
            try std.testing.expectEqualSlices(u16, key, actual_key);
            if (lookup_error) |err| return err;
            return facts;
        }
        fn activate(target: usize, actual_key: [:0]const u16) !void {
            activations += 1;
            try std.testing.expectEqual(@as(usize, 42), target);
            try std.testing.expectEqualSlices(u16, key, actual_key);
            if (activation_error) |err| return err;
        }
        fn reset() void {
            facts = .{};
            lookup_error = null;
            activation_error = null;
            lookups = 0;
            activations = 0;
        }
    };
    try std.testing.expect(!@hasDecl(WorkspaceRestoreApi, "launch"));
    Probe.reset();
    try restoreWorkspaceWith(Probe, Probe.key, .identified_only);
    try std.testing.expectEqual(@as(usize, 1), Probe.lookups);
    try std.testing.expectEqual(@as(usize, 1), Probe.activations);
    Probe.reset();
    Probe.facts.unidentified = true;
    try restoreWorkspaceWith(Probe, Probe.key, .target_first);
    try std.testing.expectEqual(@as(usize, 1), Probe.lookups);
    try std.testing.expectEqual(@as(usize, 1), Probe.activations);
    for ([_]bool{ false, true }) |unidentified| {
        Probe.reset();
        Probe.facts = .{ .target = null, .unidentified = unidentified };
        try std.testing.expectError(if (unidentified) error.UnidentifiedWorkspaceWindow else error.WorkspaceWindowNotFound, restoreWorkspaceWith(Probe, Probe.key, .identified_only));
        try std.testing.expectEqual(@as(usize, 1), Probe.lookups);
        try std.testing.expectEqual(@as(usize, 0), Probe.activations);
    }
    for ([_]anyerror{ error.WorkspaceWindowOwnerUnknown, error.WorkspaceWindowLookupFailed, error.AmbiguousWorkspaceWindow }) |failure| {
        Probe.reset();
        Probe.lookup_error = failure;
        try std.testing.expectError(failure, restoreWorkspaceWith(Probe, Probe.key, .identified_only));
        try std.testing.expectEqual(@as(usize, 1), Probe.lookups);
        try std.testing.expectEqual(@as(usize, 0), Probe.activations);
    }
    for ([_]anyerror{ error.WorkspaceWindowNotFound, error.WorkspaceWindowOwnerUnknown, error.WorkspaceRestoreFailed, error.WorkspaceActivationFailed }) |failure| {
        Probe.reset();
        Probe.activation_error = failure;
        try std.testing.expectError(failure, restoreWorkspaceWith(Probe, Probe.key, .identified_only));
        try std.testing.expectEqual(@as(usize, 1), Probe.lookups);
        try std.testing.expectEqual(@as(usize, 1), Probe.activations);
    }
}

test "workspace cycle keyboard actual accelerator descriptors provide both directions" {
    try std.testing.expectEqual(@as(?isize, 1), workspaceCycleDirection(c.VK_NEXT, true, false, true));
    try std.testing.expectEqual(@as(?isize, -1), workspaceCycleDirection(c.VK_PRIOR, true, false, true));
    for ([_]bool{ false, true }) |ctrl| {
        for ([_]bool{ false, true }) |shift| {
            for ([_]bool{ false, true }) |alt| {
                const enabled = ctrl and !shift and alt;
                try std.testing.expectEqual(@as(?isize, if (enabled) 1 else null), workspaceCycleDirection(c.VK_NEXT, ctrl, shift, alt));
                try std.testing.expectEqual(@as(?isize, if (enabled) -1 else null), workspaceCycleDirection(c.VK_PRIOR, ctrl, shift, alt));
                for ([_]usize{ c.VK_TAB, c.VK_F6, c.VK_F10 }) |key| {
                    try std.testing.expect(workspaceCycleDirection(key, ctrl, shift, alt) == null);
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 23), accelerator_entries.len);
    const previous_commands = [_]Command{
        .open_folder, .worktrees, .jump_loop, .review_attention, .next_loop,
        .previous_loop, .create_node, .stop_loop, .new_tab, .close_tab,
        .split_right, .split_down, .next_tab, .previous_tab, .settings, .product_settings,
    };
    for (previous_commands, accelerator_entries[0..16]) |command, entry| {
        try std.testing.expectEqual(@intFromEnum(command), entry.cmd);
    }
    try std.testing.expectEqual(c.VK_OEM_COMMA, accelerator_entries[15].key);
    try std.testing.expectEqual(@as(c.BYTE, c.FCONTROL | c.FSHIFT | c.FVIRTKEY), accelerator_entries[15].fVirt);
    try std.testing.expect(workspaceCycleDirection(c.VK_OEM_COMMA, true, true, false) == null);
    try std.testing.expectEqual(@import("InputRouter.zig").Action.product_settings, @import("InputRouter.zig").keyAction(c.VK_OEM_COMMA, true, true));
    try std.testing.expectEqual(c.VK_NEXT, accelerator_entries[12].key);
    try std.testing.expectEqual(c.VK_PRIOR, accelerator_entries[13].key);
    for (accelerator_entries[12..14]) |entry| {
        try std.testing.expectEqual(@as(c.BYTE, c.FCONTROL | c.FVIRTKEY), entry.fVirt);
    }
    for (accelerator_entries, 0..) |entry, index| {
        for (accelerator_entries[index + 1 ..]) |later| {
            try std.testing.expect(entry.key != later.key or entry.fVirt != later.fVirt);
        }
    }
}

test "production dispatch delivers IME composition lifecycle to a native EDIT control" {
    const Probe = struct {
        var original: c.WNDPROC = null;
        var messages: [3]c.UINT = undefined;
        var count: usize = 0;

        fn editProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
            if (message == c.WM_IME_STARTCOMPOSITION or
                message == c.WM_IME_COMPOSITION or
                message == c.WM_IME_ENDCOMPOSITION)
            {
                messages[count] = message;
                count += 1;
            }
            return c.CallWindowProcW(original, hwnd, message, wparam, lparam);
        }
    };
    Probe.count = 0;
    const parent = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral("IME dispatch test"),
        c.WS_OVERLAPPED,
        0,
        0,
        320,
        120,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.WindowCreationFailed;
    defer _ = c.DestroyWindow(parent);
    const edit = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        c.WS_CHILD | c.ES_AUTOHSCROLL,
        0,
        0,
        280,
        24,
        parent,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.EditCreationFailed;
    const previous = c.SetWindowLongPtrW(
        edit,
        c.GWLP_WNDPROC,
        @bitCast(@intFromPtr(&Probe.editProc)),
    );
    if (previous == 0) return error.EditSubclassFailed;
    Probe.original = @ptrFromInt(@as(usize, @bitCast(previous)));

    var window = Window{ .hwnd = parent };
    var message = std.mem.zeroes(c.MSG);
    message.hwnd = edit;
    for ([_]struct { kind: c.UINT, lparam: c.LPARAM }{
        .{ .kind = c.WM_IME_STARTCOMPOSITION, .lparam = 0 },
        .{ .kind = c.WM_IME_COMPOSITION, .lparam = 0x0008 },
        .{ .kind = c.WM_IME_ENDCOMPOSITION, .lparam = 0 },
    }) |expected| {
        message.message = expected.kind;
        message.lParam = expected.lparam;
        window.dispatchMessage(&message, .{}, edit);
    }
    try std.testing.expectEqualSlices(c.UINT, &.{
        c.WM_IME_STARTCOMPOSITION,
        c.WM_IME_COMPOSITION,
        c.WM_IME_ENDCOMPOSITION,
    }, Probe.messages[0..Probe.count]);
}

test "production dispatch preserves dead-key composition and non-US physical-key mapping" {
    const Probe = struct {
        var dead_chars: [4]u16 = undefined;
        var dead_count: usize = 0;
        var chars: [8]u16 = undefined;
        var char_count: usize = 0;

        fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
            switch (message) {
                c.WM_DEADCHAR => {
                    dead_chars[dead_count] = @truncate(wparam);
                    dead_count += 1;
                    return 0;
                },
                c.WM_CHAR => {
                    chars[char_count] = @truncate(wparam);
                    char_count += 1;
                    return 0;
                },
                else => return c.DefWindowProcW(hwnd, message, wparam, lparam),
            }
        }

        fn reset() void {
            dead_count = 0;
            char_count = 0;
        }
    };
    const test_class = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeKeyboardLayoutDispatchTest");
    var window_class = std.mem.zeroes(c.WNDCLASSW);
    window_class.hInstance = c.GetModuleHandleW(null);
    window_class.lpszClassName = test_class;
    window_class.lpfnWndProc = &Probe.windowProc;
    if (c.RegisterClassW(&window_class) == 0) return error.WindowClassRegistrationFailed;
    defer _ = c.UnregisterClassW(test_class, window_class.hInstance);
    const hwnd = c.CreateWindowExW(
        0,
        test_class,
        std.unicode.utf8ToUtf16LeStringLiteral("Keyboard layout dispatch test"),
        c.WS_OVERLAPPED,
        0,
        0,
        320,
        120,
        null,
        null,
        window_class.hInstance,
        null,
    ) orelse return error.WindowCreationFailed;
    defer _ = c.DestroyWindow(hwnd);

    const original_layout = c.GetKeyboardLayout(0);
    defer _ = c.ActivateKeyboardLayout(original_layout, 0);
    var original_keyboard_state: [256]u8 = undefined;
    if (c.GetKeyboardState(&original_keyboard_state) == 0) return error.KeyboardStateUnavailable;
    defer _ = c.SetKeyboardState(&original_keyboard_state);
    var clear_keyboard_state = [_]u8{0} ** 256;
    if (c.SetKeyboardState(&clear_keyboard_state) == 0) return error.KeyboardStateUnavailable;

    var window = Window{ .hwnd = hwnd };
    const Dispatch = struct {
        fn key(target: *Window, target_hwnd: c.HWND, layout: c.HKL, scan_code: u32) !void {
            const virtual_key = c.MapVirtualKeyExW(scan_code, c.MAPVK_VSC_TO_VK_EX, layout);
            if (virtual_key == 0) return error.VirtualKeyMappingUnavailable;
            var message = std.mem.zeroes(c.MSG);
            message.hwnd = target_hwnd;
            message.message = c.WM_KEYDOWN;
            message.wParam = virtual_key;
            message.lParam = @intCast(1 | (scan_code << 16));
            target.dispatchMessage(&message, .{}, target_hwnd);
            while (c.PeekMessageW(&message, target_hwnd, c.WM_KEYFIRST, c.WM_KEYLAST, c.PM_REMOVE) != 0) {
                target.dispatchMessage(&message, .{}, target_hwnd);
            }
        }
    };

    const international = c.LoadKeyboardLayoutW(
        std.unicode.utf8ToUtf16LeStringLiteral("00020409"),
        c.KLF_NOTELLSHELL,
    ) orelse {
        std.log.warn("skipping keyboard composition test: US-International layout is unavailable", .{});
        return error.SkipZigTest;
    };
    defer _ = c.UnloadKeyboardLayout(international);
    if (c.ActivateKeyboardLayout(international, 0) == null) return error.KeyboardLayoutActivationFailed;
    Probe.reset();
    try Dispatch.key(&window, hwnd, international, 0x28);
    try std.testing.expectEqual(@as(usize, 1), Probe.dead_count);
    try Dispatch.key(&window, hwnd, international, 0x12);
    try std.testing.expectEqualSlices(u16, &.{0x00e9}, Probe.chars[0..Probe.char_count]);

    const french = c.LoadKeyboardLayoutW(
        std.unicode.utf8ToUtf16LeStringLiteral("0000040c"),
        c.KLF_NOTELLSHELL,
    ) orelse {
        std.log.warn("skipping keyboard composition test: French layout is unavailable", .{});
        return error.SkipZigTest;
    };
    defer _ = c.UnloadKeyboardLayout(french);
    if (c.ActivateKeyboardLayout(french, 0) == null) return error.KeyboardLayoutActivationFailed;
    Probe.reset();
    try Dispatch.key(&window, hwnd, french, 0x10);
    try std.testing.expectEqualSlices(u16, &.{'a'}, Probe.chars[0..Probe.char_count]);
}

test "workspace cycle keyboard pretranslation consumes owned normal and system keys before child dispatch" {
    const Probe = struct {
        direction: ?isize = null,
        calls: usize = 0,
        fn callback(context: ?*anyopaque, key: usize, ctrl: bool, shift: bool, alt: bool) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.direction = workspaceCycleDirection(key, ctrl, shift, alt);
            return self.direction != null;
        }
    };
    var probe = Probe{};
    var window = Window{ .context = &probe, .key_callback = &Probe.callback };
    const eligible = KeyContext{
        .active = true, .owner_enabled = true, .target_owned = true, .target_visible = true,
        .target_enabled = true, .ctrl = true, .alt = true,
    };
    var message = std.mem.zeroes(c.MSG);
    for ([_]c.UINT{ c.WM_KEYDOWN, c.WM_SYSKEYDOWN }) |message_type| {
        message.message = message_type;
        for ([_]usize{ c.VK_PRIOR, c.VK_NEXT }) |key| {
            message.wParam = key;
            try std.testing.expect(window.pretranslateKey(&message, eligible));
            try std.testing.expectEqual(@as(?isize, if (key == c.VK_PRIOR) -1 else 1), probe.direction);
            try std.testing.expect(cycleKeyEligible(&message, eligible));
            inline for (.{ "active", "owner_enabled", "target_owned", "target_visible", "target_enabled" }) |field| {
                var excluded = eligible;
                @field(excluded, field) = false;
                const calls = probe.calls;
                try std.testing.expect(!window.pretranslateKey(&message, excluded));
                try std.testing.expectEqual(calls, probe.calls);
                try std.testing.expect(!cycleKeyEligible(&message, excluded));
            }
        }
    }
    for ([_]c.UINT{ c.WM_KEYUP, c.WM_SYSKEYUP, c.WM_CHAR, c.WM_COMMAND }) |message_type| {
        message.message = message_type;
        const calls = probe.calls;
        try std.testing.expect(!window.pretranslateKey(&message, eligible));
        try std.testing.expectEqual(calls, probe.calls);
    }
    message.message = c.WM_SYSKEYDOWN;
    message.wParam = c.VK_F10;
    const calls = probe.calls;
    try std.testing.expect(!window.pretranslateKey(&message, eligible));
    try std.testing.expectEqual(calls, probe.calls);
    message.message = c.WM_KEYDOWN;
    message.wParam = c.VK_NEXT;
    var ctrl_only = eligible;
    ctrl_only.alt = false;
    try std.testing.expect(!window.pretranslateKey(&message, ctrl_only));
    try std.testing.expect(cycleKeyEligible(&message, ctrl_only));
}

test "workspace cycle keyboard dispatch consumes rejected chords and clears pending F10 without native calls" {
    const Probe = struct {
        calls: usize = 0,
        fn callback(context: ?*anyopaque, key: usize, ctrl: bool, shift: bool, alt: bool) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return workspaceCycleDirection(key, ctrl, shift, alt) != null;
        }
    };
    var probe = Probe{};
    var window = Window{ .context = &probe, .key_callback = &Probe.callback };
    const eligible = KeyContext{
        .active = true, .owner_enabled = true, .target_owned = true, .target_visible = true,
        .target_enabled = true, .ctrl = true, .alt = true,
    };
    var message = std.mem.zeroes(c.MSG);
    for ([_]c.UINT{ c.WM_KEYDOWN, c.WM_SYSKEYDOWN }) |message_type| {
        message.message = message_type;
        for ([_]usize{ c.VK_PRIOR, c.VK_NEXT }) |key| {
            message.wParam = key;
            inline for (.{ "active", "owner_enabled", "target_owned", "target_visible", "target_enabled" }) |field| {
                var excluded = eligible;
                @field(excluded, field) = false;
                window.pending_native_f10 = .{ .down = std.mem.zeroes(c.MSG), .owner = null, .menu = null };
                const calls = probe.calls;
                window.dispatchMessage(&message, excluded, null);
                try std.testing.expectEqual(calls, probe.calls);
                try std.testing.expect(window.pending_native_f10 == null);
            }
            window.pending_native_f10 = .{ .down = std.mem.zeroes(c.MSG), .owner = null, .menu = null };
            const calls = probe.calls;
            window.dispatchMessage(&message, eligible, null);
            try std.testing.expectEqual(calls + 1, probe.calls);
            try std.testing.expect(window.pending_native_f10 == null);
        }
    }
}

test "workspace cycle keyboard gate leaves F10 pairing and cancellation to native dispatch" {
    var window = Window{};
    var message = std.mem.zeroes(c.MSG);
    message.wParam = c.VK_F10;
    window.pending_native_f10 = .{ .down = message, .owner = null, .menu = null };
    const pending = window.pending_native_f10.?;
    for ([_]c.UINT{ c.WM_KEYDOWN, c.WM_KEYUP, c.WM_SYSKEYDOWN, c.WM_SYSKEYUP, c.WM_CANCELMODE }) |message_type| {
        message.message = message_type;
        for ([_]c.LPARAM{ 0, 1 << 29, 1 << 30 }) |context| {
            message.lParam = context;
            for ([_]bool{ false, true }) |eligible| {
                window.pending_native_f10 = pending;
                const keys = KeyContext{
                    .active = eligible, .owner_enabled = eligible, .target_owned = eligible,
                    .target_visible = eligible, .target_enabled = eligible,
                };
                try std.testing.expect(!window.consumeRejectedCycleKey(&message, keys));
                try std.testing.expectEqualDeep(pending.down, window.pending_native_f10.?.down);
            }
        }
    }
    // Release messages also remain available to native dispatch, even after a cycle.
    for ([_]c.UINT{ c.WM_KEYUP, c.WM_SYSKEYUP }) |message_type| {
        message.message = message_type;
        message.wParam = c.VK_NEXT;
        window.pending_native_f10 = pending;
        try std.testing.expect(!window.consumeRejectedCycleKey(&message, .{ .ctrl = true, .alt = true }));
        try std.testing.expectEqualDeep(pending.down, window.pending_native_f10.?.down);
    }
    for ([_]c.UINT{ c.WM_KEYDOWN, c.WM_SYSKEYDOWN }) |message_type| {
        message.message = message_type;
        message.wParam = c.VK_OEM_COMMA;
        for ([_]bool{ false, true }) |shift| {
            window.pending_native_f10 = pending;
            try std.testing.expect(!window.consumeRejectedCycleKey(&message, .{ .ctrl = true, .shift = shift }));
            try std.testing.expectEqualDeep(pending.down, window.pending_native_f10.?.down);
        }
    }
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

const OrdinaryTabDispatchTest = struct {
    const owner = Win32.opaquePointerFromInt(c.HWND, 0x1000);
    const child = Win32.opaquePointerFromInt(c.HWND, 0x2000);
    const foreign = Win32.opaquePointerFromInt(c.HWND, 0x3000);
    const accelerators = Win32.opaquePointerFromInt(c.HACCEL, 0x4000);
    const eligible = KeyContext{
        .active = true,
        .owner_enabled = true,
        .target_owned = true,
        .target_visible = true,
        .target_enabled = true,
    };

    var keys: KeyContext = .{};
    var accelerator_calls: usize = 0;
    var command: ?Command = null;
    var translation_calls: usize = 0;
    var dispatch_calls: usize = 0;
    var dispatched: c.MSG = undefined;

    fn reset(context: KeyContext) void {
        keys = context;
        accelerator_calls = 0;
        command = null;
        translation_calls = 0;
        dispatch_calls = 0;
    }

    pub fn translateAccelerator(_: c.HWND, _: c.HACCEL, message: *c.MSG) c_int {
        accelerator_calls += 1;
        if (message.message != c.WM_KEYDOWN and message.message != c.WM_SYSKEYDOWN) return 0;
        var flags: c.BYTE = c.FVIRTKEY;
        if (keys.ctrl) flags |= c.FCONTROL;
        if (keys.shift) flags |= c.FSHIFT;
        if (keys.alt) flags |= c.FALT;
        for (accelerator_entries) |entry| {
            if (entry.key != message.wParam or entry.fVirt != flags) continue;
            command = commandFromId(entry.cmd).?;
            return 1;
        }
        return 0;
    }

    pub fn translateMessage(_: *const c.MSG) c.BOOL {
        translation_calls += 1;
        return 1;
    }

    pub fn dispatchMessage(message: *const c.MSG) c.LRESULT {
        dispatch_calls += 1;
        dispatched = message.*;
        return 0;
    }

    fn key(target: c.HWND, value: usize) c.MSG {
        var message = std.mem.zeroes(c.MSG);
        message.hwnd = target;
        message.message = c.WM_KEYDOWN;
        message.wParam = value;
        return message;
    }
};

test "ordinary Tab dispatch preserves focused child and nonterminal target messages" {
    const Api = OrdinaryTabDispatchTest;
    var window = Window{ .hwnd = Api.owner, .accelerators = Api.accelerators };
    for ([_]c.HWND{ Api.child, Api.foreign }) |target| {
        for ([_]bool{ false, true }) |shift| {
            var keys = Api.eligible;
            keys.shift = shift;
            keys.target_owned = target == Api.child;
            Api.reset(keys);
            var message = Api.key(target, c.VK_TAB);
            window.dispatchMessageWith(Api, &message, keys, target);
            try std.testing.expectEqual(@as(usize, 0), Api.accelerator_calls);
            try std.testing.expect(Api.command == null);
            try std.testing.expectEqual(@as(usize, 1), Api.translation_calls);
            try std.testing.expectEqual(@as(usize, 1), Api.dispatch_calls);
            try std.testing.expectEqualDeep(message, Api.dispatched);
        }
    }
}

test "ordinary Tab graph acceleration requires the eligible focused owner" {
    const Api = OrdinaryTabDispatchTest;
    var window = Window{ .hwnd = Api.owner, .accelerators = Api.accelerators };
    for ([_]bool{ false, true }) |shift| {
        var keys = Api.eligible;
        keys.shift = shift;
        var message = Api.key(Api.owner, c.VK_TAB);
        Api.reset(keys);
        window.dispatchMessageWith(Api, &message, keys, Api.owner);
        try std.testing.expectEqual(@as(?Command, if (shift) .previous_loop else .next_loop), Api.command);
        try std.testing.expectEqual(@as(usize, 1), Api.accelerator_calls);
        try std.testing.expectEqual(@as(usize, 0), Api.dispatch_calls);

        inline for (.{ "active", "owner_enabled", "target_owned", "target_visible", "target_enabled" }) |field| {
            var excluded = keys;
            @field(excluded, field) = false;
            Api.reset(excluded);
            window.dispatchMessageWith(Api, &message, excluded, Api.owner);
            try std.testing.expectEqual(@as(usize, 0), Api.accelerator_calls);
            try std.testing.expectEqual(@as(usize, 1), Api.dispatch_calls);
        }
        for ([_]c.HWND{ null, Api.child }) |focused| {
            Api.reset(keys);
            window.dispatchMessageWith(Api, &message, keys, focused);
            try std.testing.expectEqual(@as(usize, 0), Api.accelerator_calls);
            try std.testing.expectEqual(@as(usize, 1), Api.dispatch_calls);
        }
    }
}

test "ordinary Tab ownership preserves F6 header navigation and modified accelerators" {
    const Api = OrdinaryTabDispatchTest;
    const Probe = struct {
        header_focused: bool = false,
        action: @import("InputRouter.zig").HeaderKey = .none,

        fn callback(context: ?*anyopaque, key: usize, ctrl: bool, shift: bool, alt: bool) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.action = @import("InputRouter.zig").headerKey(key, ctrl, shift, alt, self.header_focused);
            if (self.action == .enter) self.header_focused = true;
            return self.action != .none;
        }
    };
    var probe = Probe{};
    var window = Window{
        .hwnd = Api.owner,
        .accelerators = Api.accelerators,
        .context = &probe,
        .key_callback = &Probe.callback,
    };
    Api.reset(Api.eligible);
    var message = Api.key(Api.child, c.VK_F6);
    window.dispatchMessageWith(Api, &message, Api.eligible, Api.child);
    try std.testing.expectEqual(@import("InputRouter.zig").HeaderKey.enter, probe.action);
    try std.testing.expectEqual(@as(usize, 0), Api.accelerator_calls);
    for ([_]bool{ false, true }) |shift| {
        var keys = Api.eligible;
        keys.shift = shift;
        Api.reset(keys);
        message = Api.key(Api.owner, c.VK_TAB);
        window.dispatchMessageWith(Api, &message, keys, Api.owner);
        try std.testing.expectEqual(
            @as(@import("InputRouter.zig").HeaderKey, if (shift) .previous else .next),
            probe.action,
        );
        try std.testing.expectEqual(@as(usize, 0), Api.accelerator_calls);
        try std.testing.expectEqual(@as(usize, 0), Api.dispatch_calls);
    }
    window.key_callback = null;
    for (accelerator_entries) |entry| {
        if (entry.key == c.VK_TAB and (entry.fVirt & c.FCONTROL) == 0) continue;
        var keys = Api.eligible;
        keys.ctrl = (entry.fVirt & c.FCONTROL) != 0;
        keys.shift = (entry.fVirt & c.FSHIFT) != 0;
        keys.alt = (entry.fVirt & c.FALT) != 0;
        Api.reset(keys);
        message = Api.key(Api.child, entry.key);
        window.dispatchMessageWith(Api, &message, keys, Api.child);
        try std.testing.expectEqual(commandFromId(entry.cmd), Api.command);
        try std.testing.expectEqual(@as(usize, 1), Api.accelerator_calls);
        try std.testing.expectEqual(@as(usize, 0), Api.dispatch_calls);
    }
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

fn expectEnabledNativeMenuCommand(menu: c.HMENU, command: Command) !void {
    const state = c.GetMenuState(menu, @intFromEnum(command), c.MF_BYCOMMAND);
    try std.testing.expect(state != std.math.maxInt(c.UINT));
    try std.testing.expect(state & c.MF_GRAYED == 0);
}

test "updateMenu applies loop and terminal capabilities to a real HMENU" {
    const hwnd = try hiddenWorkspaceTestWindow();
    defer _ = c.DestroyWindow(hwnd);
    try installMenu(hwnd);
    const menu = c.GetMenu(hwnd);
    var state = MenuState{
        .has_project = true,
        .can_worktrees = false,
        .worktree_dialog_open = false,
        .worktree_row_selected = false,
        .has_jump_target = false,
        .can_navigate_loops = false,
        .can_create_edge = false,
        .has_selected_loop = false,
        .has_workspace = true,
        .can_cycle_tabs = false,
        .can_cycle_panes = false,
        .has_attention = false,
        .can_close_tab = false,
        .sidebar_visible = false,
        .workspace_visible = false,
        .activity_visible = false,
        .update_checking = false,
    };

    updateMenu(hwnd, state, .state_change);
    for ([_]Command{
        .jump_loop,
        .next_loop,
        .previous_loop,
        .create_edge,
        .stop_loop,
        .next_tab,
        .previous_tab,
        .focus_next_pane,
        .focus_previous_pane,
    }) |command| try expectDisabledWorkspaceCommand(menu, command);

    state.has_jump_target = true;
    state.can_create_edge = true;
    state.has_selected_loop = true;
    state.can_cycle_tabs = true;
    state.can_cycle_panes = true;
    for ([_]Command{
        .jump_loop,
        .create_edge,
        .stop_loop,
        .next_tab,
        .previous_tab,
        .focus_next_pane,
        .focus_previous_pane,
    }) |command| {
        updateMenu(hwnd, state, .state_change);
        try expectEnabledNativeMenuCommand(menu, command);
    }

    const navigation_cases = [_]struct {
        loop_count: usize,
        selected_index: ?usize,
        enabled: bool,
    }{
        .{ .loop_count = 0, .selected_index = null, .enabled = false },
        .{ .loop_count = 1, .selected_index = null, .enabled = true },
        .{ .loop_count = 1, .selected_index = 0, .enabled = false },
        .{ .loop_count = 2, .selected_index = null, .enabled = true },
        .{ .loop_count = 2, .selected_index = 1, .enabled = true },
    };
    for (navigation_cases) |case| {
        state.can_navigate_loops = loopNavigationAvailable(case.loop_count, case.selected_index);
        updateMenu(hwnd, state, .state_change);
        for ([_]Command{ .next_loop, .previous_loop }) |command| {
            if (case.enabled) {
                try expectEnabledNativeMenuCommand(menu, command);
            } else {
                try expectDisabledWorkspaceCommand(menu, command);
            }
        }
    }
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
    try std.testing.expect(c.GetMenuState(menu, @intFromEnum(Command.workspace_next), c.MF_BYCOMMAND) & c.MF_GRAYED == 0);
    items[0].is_current = true;
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

test "canvas gesture configuration opts into only pan and zoom" {
    const configs = canvasGestureConfigs();
    try std.testing.expectEqual(@as(usize, 2), configs.len);
    try std.testing.expectEqual(@as(c.DWORD, @intCast(c.GID_PAN)), configs[0].dwID);
    try std.testing.expectEqual(@as(c.DWORD, @intCast(c.GC_PAN | c.GC_PAN_WITH_INERTIA)), configs[0].dwWant);
    try std.testing.expectEqual(@as(c.DWORD, 0), configs[0].dwBlock);
    try std.testing.expectEqual(@as(c.DWORD, @intCast(c.GID_ZOOM)), configs[1].dwID);
    try std.testing.expectEqual(@as(c.DWORD, @intCast(c.GC_ZOOM)), configs[1].dwWant);
    try std.testing.expectEqual(@as(c.DWORD, 0), configs[1].dwBlock);
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
