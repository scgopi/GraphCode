const std = @import("std");
const Win32 = @import("Win32.zig");
const c = Win32.c;
const AppFont = @import("AppFont.zig");
const Dpi = @import("Dpi.zig");
const MainWindow = @import("MainWindow.zig");
const SheetFramework = @import("SheetFramework.zig");
const WorkspaceLifecycle = @import("WorkspaceLifecycle.zig");

pub const Outcome = enum {
    cancel,
    install,
};

pub const Decision = enum {
    cancel,
    install_anyway,
    quit_and_install,
};

pub const Capture = struct {
    items: []WorkspaceLifecycle.Workspace,

    pub fn deinit(self: *Capture, allocator: std.mem.Allocator) void {
        for (self.items) |*workspace| workspace.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const QuitReport = struct {
    requested: usize = 0,
    exited: usize = 0,
    timed_out: usize = 0,
    failed: usize = 0,
};

const quit_wait_milliseconds: u64 = 10_000;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeUpdateWorkspaceGuard");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("Other workspaces are open");
const cancel_id: u16 = 9751;
const install_anyway_id: u16 = 9752;
const quit_and_install_id: u16 = 9753;
const footer_text_flags = c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX;

const DialogState = struct {
    allocator: std.mem.Allocator,
    message: []const u8,
    quit_label: []const u8,
    decision: Decision = .cancel,
    host: ?*SheetFramework.Host = null,
    content_root: c.HWND = null,
    message_label: c.HWND = null,
    content_extent: i32 = 144,
};

var active = false;
var active_state: DialogState = undefined;

pub fn confirm(parent: c.HWND, allocator: std.mem.Allocator) !Outcome {
    return runWith(ProductionApi, parent, allocator);
}

fn runWith(comptime Api: type, parent: c.HWND, allocator: std.mem.Allocator) !Outcome {
    var capture = try Api.capture(allocator);
    defer capture.deinit(allocator);
    if (capture.items.len == 0) return .install;
    return switch (try Api.ask(parent, allocator, capture.items)) {
        .cancel => .cancel,
        .install_anyway => .install,
        .quit_and_install => blk: {
            const report = try Api.quit(allocator, capture.items);
            if (report.failed != 0 or report.timed_out != 0) {
                std.log.warn(
                    "Update workspace quit completed with requested={d} exited={d} timed_out={d} failed={d}",
                    .{ report.requested, report.exited, report.timed_out, report.failed },
                );
            }
            break :blk .install;
        },
    };
}

const ProductionApi = struct {
    fn capture(allocator: std.mem.Allocator) !Capture {
        return captureOpenWorkspaces(allocator);
    }

    fn ask(
        parent: c.HWND,
        allocator: std.mem.Allocator,
        workspaces: []const WorkspaceLifecycle.Workspace,
    ) !Decision {
        return show(parent, allocator, workspaces);
    }

    fn quit(
        allocator: std.mem.Allocator,
        workspaces: []const WorkspaceLifecycle.Workspace,
    ) !QuitReport {
        return quitCaptured(allocator, workspaces);
    }
};

fn captureOpenWorkspaces(allocator: std.mem.Allocator) !Capture {
    const current_path = try WorkspaceLifecycle.currentPath(allocator);
    defer allocator.free(current_path);
    const current_identity = try WorkspaceLifecycle.pathIdentity(allocator, current_path);
    defer allocator.free(current_identity);
    const home = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.UserProfileMissing,
        else => return err,
    };
    defer allocator.free(home);
    var known = try WorkspaceLifecycle.managerListFromHome(allocator, home, current_path);
    defer known.deinit(allocator);
    const user = try workspaceUser(allocator);
    defer allocator.free(user);
    return captureKnownWith(WorkspaceLookupApi, allocator, known.items, current_identity, user);
}

const WorkspaceLookupApi = struct {
    fn instanceKey(
        allocator: std.mem.Allocator,
        user: []const u8,
        path: []const u8,
    ) ![:0]u16 {
        const name = try WorkspaceLifecycle.instanceName(allocator, user, path);
        defer allocator.free(name);
        return std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
    }

    fn windows(key: [:0]const u16) !MainWindow.WorkspaceWindows {
        return MainWindow.workspaceWindows(key);
    }
};

fn captureKnownWith(
    comptime Api: type,
    allocator: std.mem.Allocator,
    known: []const WorkspaceLifecycle.Workspace,
    current_identity: []const u8,
    user: []const u8,
) !Capture {
    var open = std.array_list.Managed(WorkspaceLifecycle.Workspace).init(allocator);
    errdefer {
        for (open.items) |*workspace| workspace.deinit(allocator);
        open.deinit();
    }
    for (known) |workspace| {
        const key = try Api.instanceKey(allocator, user, workspace.path);
        defer allocator.free(key);
        const windows = try Api.windows(key);
        if (windows.unidentified) return error.UnidentifiedWorkspaceWindow;
        if (windows.target == null or std.mem.eql(u8, workspace.identity, current_identity))
            continue;
        var owned = try WorkspaceLifecycle.copyWorkspace(allocator, workspace);
        open.append(owned) catch |err| {
            owned.deinit(allocator);
            return err;
        };
    }
    return .{ .items = try open.toOwnedSlice() };
}

const WorkspaceUserApi = struct {
    fn read(buffer: []u16, size: *c.DWORD) bool {
        return c.GetUserNameW(buffer.ptr, size) != 0;
    }
};

fn workspaceUser(allocator: std.mem.Allocator) ![]u8 {
    return workspaceUserWith(allocator, WorkspaceUserApi);
}

fn workspaceUserWith(allocator: std.mem.Allocator, comptime Api: type) ![]u8 {
    var wide: [257]u16 = [_]u16{0} ** 257;
    var size: c.DWORD = wide.len;
    if (!Api.read(&wide, &size) or size == 0 or size > wide.len)
        return error.WorkspaceUserUnavailable;
    const length = if (wide[size - 1] == 0) size - 1 else size;
    if (length == 0) return error.WorkspaceUserUnavailable;
    return std.unicode.utf16LeToUtf8Alloc(allocator, wide[0..length]);
}

fn show(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    workspaces: []const WorkspaceLifecycle.Workspace,
) !Decision {
    const names = try listNames(allocator, workspaces);
    defer allocator.free(names);
    const message = try dialogMessage(allocator, workspaces, names);
    defer allocator.free(message);
    const quit_label = quitLabel(workspaces.len);
    return showDialog(parent, allocator, message, quit_label);
}

fn quitLabel(count: usize) []const u8 {
    return if (count == 1) "Quit It & Install" else "Quit Them & Install";
}

pub fn listNames(
    allocator: std.mem.Allocator,
    workspaces: []const WorkspaceLifecycle.Workspace,
) ![]u8 {
    if (workspaces.len == 0) return allocator.dupe(u8, "");
    if (workspaces.len == 1) return allocator.dupe(u8, workspaces[0].name);
    var text = std.array_list.Managed(u8).init(allocator);
    errdefer text.deinit();
    for (workspaces, 0..) |workspace, index| {
        if (index != 0) {
            try text.appendSlice(if (index + 1 == workspaces.len) " and " else ", ");
        }
        try text.appendSlice(workspace.name);
    }
    return text.toOwnedSlice();
}

fn dialogMessage(
    allocator: std.mem.Allocator,
    workspaces: []const WorkspaceLifecycle.Workspace,
    names: []const u8,
) ![]u8 {
    const singular = workspaces.len == 1;
    return std.fmt.allocPrint(
        allocator,
        "{s} {s} open in {s}. Every workspace runs the same app, so installing replaces it for all of them. Quitting them first is the clean way — their loops keep running either way, since the daemon holds the sessions, not the window.",
        .{
            names,
            if (singular) "is" else "are",
            if (singular) "another window" else "other windows",
        },
    );
}

fn showDialog(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    message: []const u8,
    quit_label: []const u8,
) !Decision {
    try registerClass();
    active_state = .{
        .allocator = allocator,
        .message = message,
        .quit_label = quit_label,
        .content_extent = messageExtent(message),
    };
    active = true;
    errdefer active = false;
    var host: SheetFramework.Host = .{};
    defer host.deinit();
    try createSheet(&host, parent);
    try host.runModal();
    const decision = active_state.decision;
    active = false;
    return decision;
}

fn registerClass() !void {
    var klass: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    klass.lpfnWndProc = @ptrCast(&contentProc);
    klass.hInstance = c.GetModuleHandleW(null);
    klass.lpszClassName = class_name.ptr;
    klass.hCursor = c.LoadCursorW(null, Win32.resourceIdentifier(32512));
    if (c.RegisterClassW(&klass) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.DialogClassRegistrationFailed;
}

fn createSheet(host: *SheetFramework.Host, parent: c.HWND) !void {
    const dpi = Dpi.normalize(Win32.dpiForWindow(parent));
    try host.init(parent, .{
        .layout_input = .{
            .owner = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .dpi = dpi,
            .desired_width = 700,
            .minimum_width = 480,
            .heights = .{ .minimum = 230, .ideal = 310, .maximum = 500 },
            .content_extent = active_state.content_extent,
        },
        .context = &active_state,
        .on_layout = &layoutSheet,
        .on_message = &sheetMessage,
    });
    if (c.SetWindowTextW(host.hwnd, window_title.ptr) == 0) return error.DialogCreationFailed;
    active_state.host = host;
    active_state.content_root = c.CreateWindowExW(
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
    ) orelse return error.DialogCreationFailed;
    active_state.message_label = try createStatic(
        active_state.content_root,
        active_state.allocator,
        active_state.message,
    );
    const actions = guardFooterActions(host.hwnd, dpi, active_state.quit_label);
    try host.configureFooter(&actions);
    const cancel = try host.createFooterButton(
        cancel_id,
        std.unicode.utf8ToUtf16LeStringLiteral("Cancel").ptr,
    );
    const anyway = try host.createFooterButton(
        install_anyway_id,
        std.unicode.utf8ToUtf16LeStringLiteral("Install Anyway").ptr,
    );
    const quit_label = try wideZ(active_state.allocator, active_state.quit_label);
    defer active_state.allocator.free(quit_label);
    const quit = try host.createFooterButton(quit_and_install_id, quit_label.ptr);
    for ([_]c.HWND{ cancel, anyway, quit }) |button| {
        AppFont.apply(button, AppFont.control_size, false);
    }
    try host.relayout();
}

fn createStatic(hwnd: c.HWND, allocator: std.mem.Allocator, text: []const u8) !c.HWND {
    const wide = try wideZ(allocator, text);
    defer allocator.free(wide);
    const control = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr,
        wide.ptr,
        c.WS_CHILD | c.WS_VISIBLE | c.SS_LEFT,
        0,
        0,
        0,
        0,
        hwnd,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.DialogCreationFailed;
    AppFont.apply(control, AppFont.control_size, false);
    return control;
}

fn layoutSheet(context: ?*anyopaque, layout: SheetFramework.Layout) !void {
    const state: *DialogState = @ptrCast(@alignCast(context.?));
    if (state.content_root == null or state.message_label == null) return;
    const dpi = state.host.?.options.layout_input.dpi;
    const font = AppFont.getForDpi(AppFont.control_size, false, dpi) orelse
        return error.DialogFontCreationFailed;
    _ = c.SendMessageW(state.message_label, c.WM_SETFONT, @intFromPtr(font), 1);
    for ([_]u16{ cancel_id, install_anyway_id, quit_and_install_id }) |id| {
        if (c.GetDlgItem(state.host.?.hwnd, id)) |button| {
            _ = c.SendMessageW(button, c.WM_SETFONT, @intFromPtr(font), 1);
        }
    }
    const scrollbar = if (layout.scroll.visible)
        SheetFramework.Metrics.forDpi(dpi).scrollbar_width
    else
        0;
    const content_width = @max(0, layout.viewport.width - scrollbar);
    if (c.MoveWindow(
        state.content_root,
        0,
        -layout.scroll.offset,
        content_width,
        @max(layout.scroll.extent, layout.viewport.height),
        1,
    ) == 0) return error.DialogLayoutFailed;
    if (c.MoveWindow(
        state.message_label,
        Dpi.scale(22, dpi),
        Dpi.scale(22, dpi),
        @max(0, content_width - Dpi.scale(44, dpi)),
        Dpi.scale(state.content_extent - 44, dpi),
        1,
    ) == 0) return error.DialogLayoutFailed;
}

fn sheetMessage(
    context: ?*anyopaque,
    hwnd: c.HWND,
    message: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
    result: *c.LRESULT,
) bool {
    const state: *DialogState = @ptrCast(@alignCast(context.?));
    switch (message) {
        c.WM_DRAWITEM => {
            result.* = drawFooterItem(state.host.?, lparam);
            return true;
        },
        c.DM_GETDEFID => {
            result.* = @as(c.LRESULT, quit_and_install_id) |
                (@as(c.LRESULT, c.DC_HASDEFID) << 16);
            return true;
        },
        c.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            if (decisionForCommand(command)) |decision| {
                state.decision = decision;
                state.host.?.requestClose();
                result.* = 0;
                return true;
            }
        },
        c.WM_CLOSE => {
            state.decision = .cancel;
            state.host.?.requestClose();
            result.* = 0;
            return true;
        },
        else => {},
    }
    _ = hwnd;
    return false;
}

fn decisionForCommand(command: u16) ?Decision {
    return switch (command) {
        cancel_id => .cancel,
        install_anyway_id => .install_anyway,
        quit_and_install_id => .quit_and_install,
        else => null,
    };
}

fn guardFooterActions(
    hwnd: c.HWND,
    dpi: u32,
    quit_label: []const u8,
) [3]SheetFramework.FooterAction {
    return .{
        .{
            .id = cancel_id,
            .role = .cancel,
            .measured_text_width = footerTextWidth(
                hwnd,
                dpi,
                std.unicode.utf8ToUtf16LeStringLiteral("Cancel"),
                44,
            ),
        },
        .{
            .id = install_anyway_id,
            .role = .secondary,
            .measured_text_width = footerTextWidth(
                hwnd,
                dpi,
                std.unicode.utf8ToUtf16LeStringLiteral("Install Anyway"),
                92,
            ),
        },
        .{
            .id = quit_and_install_id,
            .role = .primary,
            .measured_text_width = footerTextWidthUtf8(hwnd, dpi, quit_label, 124),
            .return_hint = true,
        },
    };
}

fn footerTextWidth(
    hwnd: c.HWND,
    dpi: u32,
    text: []const u16,
    fallback: i32,
) i32 {
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

fn footerTextWidthUtf8(
    hwnd: c.HWND,
    dpi: u32,
    text: []const u8,
    fallback: i32,
) i32 {
    const wide = std.unicode.utf8ToUtf16LeAlloc(std.heap.c_allocator, text) catch
        return Dpi.scale(fallback, dpi);
    defer std.heap.c_allocator.free(wide);
    return footerTextWidth(hwnd, dpi, wide, fallback);
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
    SheetFramework.drawButton(
        item.hDC,
        .{
            .x = item.rcItem.left,
            .y = item.rcItem.top,
            .width = item.rcItem.right - item.rcItem.left,
            .height = item.rcItem.bottom - item.rcItem.top,
        },
        host.options.layout_input.dpi,
        role,
        item.itemState & c.ODS_DISABLED == 0,
        item.itemState & c.ODS_SELECTED != 0,
    ) catch return 0;
    var text: [128]u16 = [_]u16{0} ** 128;
    const count = c.GetWindowTextW(item.hwndItem, &text, text.len);
    const old_font = AppFont.selectForDpi(
        item.hDC,
        AppFont.control_size,
        false,
    );
    defer _ = c.SelectObject(item.hDC, old_font);
    _ = c.SetBkMode(item.hDC, c.TRANSPARENT);
    _ = c.SetTextColor(
        item.hDC,
        SheetFramework.controlPaintStyle(
            .button,
            item.itemState & c.ODS_DISABLED == 0,
        ).foreground,
    );
    var bounds = item.rcItem;
    if (return_hint) {
        bounds.right -= SheetFramework.Metrics.forDpi(
            host.options.layout_input.dpi,
        ).return_hint_width;
    }
    _ = c.DrawTextW(
        item.hDC,
        &text,
        count,
        &bounds,
        footer_text_flags,
    );
    if (return_hint) {
        var hint_bounds = item.rcItem;
        hint_bounds.left = bounds.right;
        _ = c.DrawTextW(
            item.hDC,
            std.unicode.utf8ToUtf16LeStringLiteral("\u{21b5}").ptr,
            1,
            &hint_bounds,
            footer_text_flags,
        );
    }
    return 1;
}

fn contentProc(
    hwnd: c.HWND,
    message: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    if (!active or active_state.host == null)
        return c.DefWindowProcW(hwnd, message, wparam, lparam);
    return switch (message) {
        c.WM_CTLCOLORSTATIC => active_state.host.?.brushes.apply(
            Win32.opaquePointerFromInt(c.HDC, wparam),
            .static,
            true,
        ) catch 0,
        c.WM_ERASEBKGND => blk: {
            var bounds: c.RECT = undefined;
            if (c.GetClientRect(hwnd, &bounds) != 0) {
                _ = c.FillRect(
                    Win32.opaquePointerFromInt(c.HDC, wparam),
                    &bounds,
                    active_state.host.?.brushes.panel,
                );
            }
            break :blk 1;
        },
        else => c.DefWindowProcW(hwnd, message, wparam, lparam),
    };
}

fn messageExtent(message: []const u8) i32 {
    const lines = @max(@as(usize, 4), (message.len + 73) / 74);
    return 44 + @as(i32, @intCast(@min(lines, 12))) * 22;
}

const QuitTarget = struct {
    window: usize,
    process: usize,
};

fn quitCaptured(
    allocator: std.mem.Allocator,
    workspaces: []const WorkspaceLifecycle.Workspace,
) !QuitReport {
    return quitCapturedWith(QuitApi, allocator, workspaces);
}

const QuitApi = struct {
    fn open(
        allocator: std.mem.Allocator,
        workspace: WorkspaceLifecycle.Workspace,
    ) !?QuitTarget {
        const user = try workspaceUser(allocator);
        defer allocator.free(user);
        const name = try WorkspaceLifecycle.instanceName(
            allocator,
            user,
            workspace.path,
        );
        defer allocator.free(name);
        const key = try std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
        defer allocator.free(key);
        const windows = try MainWindow.workspaceWindows(key);
        if (windows.unidentified) return error.UnidentifiedWorkspaceWindow;
        const hwnd = windows.target orelse return null;
        var process_id: c.DWORD = 0;
        if (c.GetWindowThreadProcessId(hwnd, &process_id) == 0)
            return error.WorkspaceWindowOwnerUnknown;
        const process = c.OpenProcess(
            c.SYNCHRONIZE | c.PROCESS_QUERY_LIMITED_INFORMATION,
            0,
            process_id,
        ) orelse return error.WorkspaceWindowOwnerUnknown;
        errdefer _ = c.CloseHandle(process);
        var confirmed_process_id: c.DWORD = 0;
        if (c.GetWindowThreadProcessId(hwnd, &confirmed_process_id) == 0 or
            confirmed_process_id != process_id or
            !MainWindow.workspaceIdentityMatches(hwnd, key))
        {
            return error.WorkspaceWindowChanged;
        }
        return .{
            .window = @intFromPtr(hwnd),
            .process = @intFromPtr(process),
        };
    }

    fn postExit(target: QuitTarget) bool {
        const hwnd = Win32.opaquePointerFromInt(c.HWND, target.window);
        return c.PostMessageW(
            hwnd,
            c.WM_COMMAND,
            @intFromEnum(MainWindow.Command.exit),
            0,
        ) != 0;
    }

    fn now() u64 {
        return c.GetTickCount64();
    }

    fn wait(target: QuitTarget, timeout: c.DWORD) c.DWORD {
        return c.WaitForSingleObject(
            Win32.opaquePointerFromInt(c.HANDLE, target.process),
            timeout,
        );
    }

    fn close(target: QuitTarget) void {
        _ = c.CloseHandle(
            Win32.opaquePointerFromInt(c.HANDLE, target.process),
        );
    }
};

fn quitCapturedWith(
    comptime Api: type,
    allocator: std.mem.Allocator,
    workspaces: []const WorkspaceLifecycle.Workspace,
) !QuitReport {
    const targets = try allocator.alloc(?QuitTarget, workspaces.len);
    defer allocator.free(targets);
    @memset(targets, null);
    var report = QuitReport{};
    for (workspaces, 0..) |workspace, index| {
        const target = Api.open(allocator, workspace) catch |err| {
            std.log.warn(
                "Could not resolve workspace '{s}' for update quit: {s}",
                .{ workspace.name, @errorName(err) },
            );
            report.failed += 1;
            continue;
        } orelse continue;
        if (!Api.postExit(target)) {
            Api.close(target);
            report.failed += 1;
            continue;
        }
        targets[index] = target;
        report.requested += 1;
    }
    const started = Api.now();
    const deadline = started +| quit_wait_milliseconds;
    for (targets) |maybe_target| {
        const target = maybe_target orelse continue;
        defer Api.close(target);
        const now = Api.now();
        const remaining: c.DWORD = @intCast(@min(
            if (now >= deadline) 0 else deadline - now,
            std.math.maxInt(c.DWORD),
        ));
        switch (Api.wait(target, remaining)) {
            c.WAIT_OBJECT_0 => report.exited += 1,
            c.WAIT_TIMEOUT => report.timed_out += 1,
            else => report.failed += 1,
        }
    }
    return report;
}

fn wideZ(allocator: std.mem.Allocator, value: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, value);
}

fn fixtureWorkspace(name: []const u8, path: []const u8) WorkspaceLifecycle.Workspace {
    return .{
        .name = name,
        .path = path,
        .identity = if (std.mem.eql(u8, path, "C:\\fixture\\.graphcode"))
            "c:/fixture/.graphcode"
        else if (std.mem.eql(u8, path, "C:\\fixture\\.graphcode-work"))
            "c:/fixture/.graphcode-work"
        else if (std.mem.eql(u8, path, "C:\\fixture\\.graphcode-closed"))
            "c:/fixture/.graphcode-closed"
        else if (std.mem.eql(u8, path, "C:\\work"))
            "c:/work"
        else if (std.mem.eql(u8, path, "C:\\oss"))
            "c:/oss"
        else if (std.mem.eql(u8, path, "C:\\side"))
            "c:/side"
        else
            path,
        .is_default = false,
    };
}

test "update workspace guard: identified workspaces prompt before install" {
    const Probe = struct {
        var prompted = false;

        fn capture(allocator: std.mem.Allocator) !Capture {
            const items = try allocator.alloc(WorkspaceLifecycle.Workspace, 1);
            items[0] = try WorkspaceLifecycle.copyWorkspace(
                allocator,
                fixtureWorkspace("work", "C:\\fixture\\.graphcode-work"),
            );
            return .{ .items = items };
        }

        fn ask(
            _: c.HWND,
            _: std.mem.Allocator,
            _: []const WorkspaceLifecycle.Workspace,
        ) !Decision {
            prompted = true;
            return .cancel;
        }

        fn quit(
            _: std.mem.Allocator,
            _: []const WorkspaceLifecycle.Workspace,
        ) !QuitReport {
            return error.UnexpectedQuit;
        }
    };

    Probe.prompted = false;
    try std.testing.expectEqual(
        Outcome.cancel,
        try runWith(Probe, null, std.testing.allocator),
    );
    try std.testing.expect(Probe.prompted);
}

test "update workspace guard: no other identified window starts install once" {
    const Probe = struct {
        var prompted = false;

        fn capture(allocator: std.mem.Allocator) !Capture {
            return .{ .items = try allocator.alloc(WorkspaceLifecycle.Workspace, 0) };
        }

        fn ask(
            _: c.HWND,
            _: std.mem.Allocator,
            _: []const WorkspaceLifecycle.Workspace,
        ) !Decision {
            prompted = true;
            return .cancel;
        }

        fn quit(
            _: std.mem.Allocator,
            _: []const WorkspaceLifecycle.Workspace,
        ) !QuitReport {
            return error.UnexpectedQuit;
        }
    };

    Probe.prompted = false;
    try std.testing.expectEqual(
        Outcome.install,
        try runWith(Probe, null, std.testing.allocator),
    );
    try std.testing.expect(!Probe.prompted);
}

test "update workspace guard: cancel preserves install and quit side effects" {
    const Probe = struct {
        var quit_called = false;

        fn capture(allocator: std.mem.Allocator) !Capture {
            const items = try allocator.alloc(WorkspaceLifecycle.Workspace, 1);
            items[0] = try WorkspaceLifecycle.copyWorkspace(
                allocator,
                fixtureWorkspace("work", "C:\\fixture\\.graphcode-work"),
            );
            return .{ .items = items };
        }

        fn ask(
            _: c.HWND,
            _: std.mem.Allocator,
            _: []const WorkspaceLifecycle.Workspace,
        ) !Decision {
            return .cancel;
        }

        fn quit(
            _: std.mem.Allocator,
            _: []const WorkspaceLifecycle.Workspace,
        ) !QuitReport {
            quit_called = true;
            return .{};
        }
    };

    Probe.quit_called = false;
    try std.testing.expectEqual(
        Outcome.cancel,
        try runWith(Probe, null, std.testing.allocator),
    );
    try std.testing.expect(!Probe.quit_called);
}

test "update workspace guard: install anyway skips quit and installs once" {
    const Probe = struct {
        var quit_called = false;

        fn capture(allocator: std.mem.Allocator) !Capture {
            const items = try allocator.alloc(WorkspaceLifecycle.Workspace, 1);
            items[0] = try WorkspaceLifecycle.copyWorkspace(
                allocator,
                fixtureWorkspace("work", "C:\\fixture\\.graphcode-work"),
            );
            return .{ .items = items };
        }

        fn ask(
            _: c.HWND,
            _: std.mem.Allocator,
            _: []const WorkspaceLifecycle.Workspace,
        ) !Decision {
            return .install_anyway;
        }

        fn quit(
            _: std.mem.Allocator,
            _: []const WorkspaceLifecycle.Workspace,
        ) !QuitReport {
            quit_called = true;
            return .{};
        }
    };

    Probe.quit_called = false;
    try std.testing.expectEqual(
        Outcome.install,
        try runWith(Probe, null, std.testing.allocator),
    );
    try std.testing.expect(!Probe.quit_called);
}

test "update workspace guard: quit waits before install" {
    const Probe = struct {
        var quit_called = false;

        fn capture(allocator: std.mem.Allocator) !Capture {
            const items = try allocator.alloc(WorkspaceLifecycle.Workspace, 1);
            items[0] = try WorkspaceLifecycle.copyWorkspace(
                allocator,
                fixtureWorkspace("work", "C:\\fixture\\.graphcode-work"),
            );
            return .{ .items = items };
        }

        fn ask(
            _: c.HWND,
            _: std.mem.Allocator,
            _: []const WorkspaceLifecycle.Workspace,
        ) !Decision {
            return .quit_and_install;
        }

        fn quit(
            _: std.mem.Allocator,
            _: []const WorkspaceLifecycle.Workspace,
        ) !QuitReport {
            quit_called = true;
            return .{ .requested = 1, .exited = 1 };
        }
    };

    Probe.quit_called = false;
    try std.testing.expectEqual(
        Outcome.install,
        try runWith(Probe, null, std.testing.allocator),
    );
    try std.testing.expect(Probe.quit_called);
}

test "update workspace guard: names and singular plural copy match macOS" {
    const one = [_]WorkspaceLifecycle.Workspace{
        fixtureWorkspace("work", "C:\\work"),
    };
    const two = [_]WorkspaceLifecycle.Workspace{
        fixtureWorkspace("work", "C:\\work"),
        fixtureWorkspace("oss", "C:\\oss"),
    };
    const three = [_]WorkspaceLifecycle.Workspace{
        fixtureWorkspace("work", "C:\\work"),
        fixtureWorkspace("oss", "C:\\oss"),
        fixtureWorkspace("side", "C:\\side"),
    };
    const one_names = try listNames(std.testing.allocator, &one);
    defer std.testing.allocator.free(one_names);
    const two_names = try listNames(std.testing.allocator, &two);
    defer std.testing.allocator.free(two_names);
    const three_names = try listNames(std.testing.allocator, &three);
    defer std.testing.allocator.free(three_names);
    try std.testing.expectEqualStrings("work", one_names);
    try std.testing.expectEqualStrings("work and oss", two_names);
    try std.testing.expectEqualStrings("work, oss and side", three_names);
    try std.testing.expectEqualStrings("Quit It & Install", quitLabel(one.len));
    try std.testing.expectEqualStrings("Quit Them & Install", quitLabel(three.len));
    try std.testing.expect(footer_text_flags & c.DT_NOPREFIX != 0);
    const singular = try dialogMessage(std.testing.allocator, &one, one_names);
    defer std.testing.allocator.free(singular);
    const plural = try dialogMessage(std.testing.allocator, &three, three_names);
    defer std.testing.allocator.free(plural);
    try std.testing.expect(std.mem.startsWith(
        u8,
        singular,
        "work is open in another window.",
    ));
    try std.testing.expect(std.mem.startsWith(
        u8,
        plural,
        "work, oss and side are open in other windows.",
    ));
    try std.testing.expect(std.mem.endsWith(
        u8,
        plural,
        "their loops keep running either way, since the daemon holds the sessions, not the window.",
    ));
}

test "update workspace guard: unidentified ownership blocks install" {
    const Probe = struct {
        var calls: usize = 0;

        fn instanceKey(
            allocator: std.mem.Allocator,
            _: []const u8,
            path: []const u8,
        ) ![:0]u16 {
            return std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
        }

        fn windows(_: [:0]const u16) !MainWindow.WorkspaceWindows {
            calls += 1;
            return .{ .unidentified = true };
        }
    };
    const known = [_]WorkspaceLifecycle.Workspace{
        fixtureWorkspace("Default", "C:\\fixture\\.graphcode"),
        fixtureWorkspace("work", "C:\\fixture\\.graphcode-work"),
    };
    Probe.calls = 0;
    try std.testing.expectError(
        error.UnidentifiedWorkspaceWindow,
        captureKnownWith(
            Probe,
            std.testing.allocator,
            &known,
            known[0].identity,
            "tester",
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), Probe.calls);
}

test "update workspace guard: capture owns only other identified workspaces" {
    const Probe = struct {
        fn instanceKey(
            allocator: std.mem.Allocator,
            _: []const u8,
            path: []const u8,
        ) ![:0]u16 {
            return std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
        }

        fn windows(key: [:0]const u16) !MainWindow.WorkspaceWindows {
            const text = try std.unicode.utf16LeToUtf8Alloc(
                std.testing.allocator,
                key,
            );
            defer std.testing.allocator.free(text);
            return .{
                .target = if (std.mem.endsWith(u8, text, "-closed"))
                    null
                else
                    Win32.opaquePointerFromInt(c.HWND, 1),
            };
        }
    };
    const known = [_]WorkspaceLifecycle.Workspace{
        fixtureWorkspace("Default", "C:\\fixture\\.graphcode"),
        fixtureWorkspace("work", "C:\\fixture\\.graphcode-work"),
        fixtureWorkspace("closed", "C:\\fixture\\.graphcode-closed"),
    };
    var captured = try captureKnownWith(
        Probe,
        std.testing.allocator,
        &known,
        known[0].identity,
        "tester",
    );
    defer captured.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), captured.items.len);
    try std.testing.expectEqualStrings("work", captured.items[0].name);
    try std.testing.expect(captured.items[0].name.ptr != known[1].name.ptr);
}

test "update workspace guard: capture releases partial ownership on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        captureAllocationCase,
        .{},
    );
}

fn captureAllocationCase(allocator: std.mem.Allocator) !void {
    const Probe = struct {
        fn instanceKey(
            inner_allocator: std.mem.Allocator,
            _: []const u8,
            path: []const u8,
        ) ![:0]u16 {
            return std.unicode.utf8ToUtf16LeAllocZ(inner_allocator, path);
        }

        fn windows(_: [:0]const u16) !MainWindow.WorkspaceWindows {
            return .{ .target = Win32.opaquePointerFromInt(c.HWND, 1) };
        }
    };
    const known = [_]WorkspaceLifecycle.Workspace{
        fixtureWorkspace("Default", "C:\\fixture\\.graphcode"),
        fixtureWorkspace("work", "C:\\fixture\\.graphcode-work"),
    };
    var captured = try captureKnownWith(
        Probe,
        allocator,
        &known,
        known[0].identity,
        "tester",
    );
    defer captured.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), captured.items.len);
}

test "update workspace guard: quit uses one shared ten second deadline" {
    const Probe = struct {
        var opened: usize = 0;
        var posted: usize = 0;
        var closed: usize = 0;
        var waits: [2]c.DWORD = .{ 0, 0 };
        var wait_count: usize = 0;
        var clocks: [3]u64 = .{ 1_000, 4_000, 11_500 };
        var clock_index: usize = 0;

        fn open(
            _: std.mem.Allocator,
            _: WorkspaceLifecycle.Workspace,
        ) !?QuitTarget {
            opened += 1;
            return .{ .window = opened, .process = opened + 10 };
        }

        fn postExit(_: QuitTarget) bool {
            posted += 1;
            return true;
        }

        fn now() u64 {
            const value = clocks[clock_index];
            clock_index += 1;
            return value;
        }

        fn wait(_: QuitTarget, timeout: c.DWORD) c.DWORD {
            waits[wait_count] = timeout;
            wait_count += 1;
            return if (wait_count == 1) c.WAIT_OBJECT_0 else c.WAIT_TIMEOUT;
        }

        fn close(_: QuitTarget) void {
            closed += 1;
        }
    };
    const workspaces = [_]WorkspaceLifecycle.Workspace{
        fixtureWorkspace("work", "C:\\work"),
        fixtureWorkspace("oss", "C:\\oss"),
    };
    Probe.opened = 0;
    Probe.posted = 0;
    Probe.closed = 0;
    Probe.wait_count = 0;
    Probe.clock_index = 0;
    const report = try quitCapturedWith(
        Probe,
        std.testing.allocator,
        &workspaces,
    );
    try std.testing.expectEqual(@as(usize, 2), Probe.opened);
    try std.testing.expectEqual(@as(usize, 2), Probe.posted);
    try std.testing.expectEqual(@as(usize, 2), Probe.closed);
    try std.testing.expectEqual(@as(c.DWORD, 7_000), Probe.waits[0]);
    try std.testing.expectEqual(@as(c.DWORD, 0), Probe.waits[1]);
    try std.testing.expectEqual(@as(usize, 2), report.requested);
    try std.testing.expectEqual(@as(usize, 1), report.exited);
    try std.testing.expectEqual(@as(usize, 1), report.timed_out);
}

test "update workspace guard: every opened process handle closes on post failure" {
    const Probe = struct {
        var closed = false;

        fn open(
            _: std.mem.Allocator,
            _: WorkspaceLifecycle.Workspace,
        ) !?QuitTarget {
            return .{ .window = 1, .process = 2 };
        }

        fn postExit(_: QuitTarget) bool {
            return false;
        }

        fn now() u64 {
            return 0;
        }

        fn wait(_: QuitTarget, _: c.DWORD) c.DWORD {
            return c.WAIT_FAILED;
        }

        fn close(_: QuitTarget) void {
            closed = true;
        }
    };
    const workspaces = [_]WorkspaceLifecycle.Workspace{
        fixtureWorkspace("work", "C:\\work"),
    };
    Probe.closed = false;
    const report = try quitCapturedWith(
        Probe,
        std.testing.allocator,
        &workspaces,
    );
    try std.testing.expect(Probe.closed);
    try std.testing.expectEqual(@as(usize, 1), report.failed);
    try std.testing.expectEqual(@as(usize, 0), report.requested);
}

test "update workspace guard: hidden sheet requires exact message and actions" {
    try registerClass();
    const owner = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr,
        null,
        c.WS_POPUP,
        20,
        20,
        900,
        700,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.DialogCreationFailed;
    defer _ = c.DestroyWindow(owner);
    const workspaces = [_]WorkspaceLifecycle.Workspace{
        fixtureWorkspace("work", "C:\\work"),
    };
    const names = try listNames(std.testing.allocator, &workspaces);
    defer std.testing.allocator.free(names);
    const message = try dialogMessage(std.testing.allocator, &workspaces, names);
    defer std.testing.allocator.free(message);
    active_state = .{
        .allocator = std.testing.allocator,
        .message = message,
        .quit_label = "Quit It & Install",
        .content_extent = messageExtent(message),
    };
    active = true;
    defer active = false;
    var host: SheetFramework.Host = .{};
    defer host.deinit();
    try createSheet(&host, owner);
    try std.testing.expect(active_state.message_label != null);
    var text: [512]u16 = [_]u16{0} ** 512;
    const length = c.GetWindowTextW(active_state.message_label, &text, text.len);
    const actual = try std.unicode.utf16LeToUtf8Alloc(
        std.testing.allocator,
        text[0..@intCast(length)],
    );
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(message, actual);
    const expected = [_]struct { id: u16, label: []const u8 }{
        .{ .id = cancel_id, .label = "Cancel" },
        .{ .id = install_anyway_id, .label = "Install Anyway" },
        .{ .id = quit_and_install_id, .label = "Quit It & Install" },
    };
    for (expected) |item| {
        const button = c.GetDlgItem(host.hwnd, item.id) orelse
            return error.DialogCreationFailed;
        const button_length = c.GetWindowTextW(button, &text, text.len);
        const label = try std.unicode.utf16LeToUtf8Alloc(
            std.testing.allocator,
            text[0..@intCast(button_length)],
        );
        defer std.testing.allocator.free(label);
        try std.testing.expectEqualStrings(item.label, label);
    }
}
