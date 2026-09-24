const std = @import("std");
const Win32 = @import("Win32.zig");
const c = Win32.c;
const ModalTeardown = @import("ModalTeardown.zig");
const AppFont = @import("AppFont.zig");

pub const Action = enum {
    later,
    release_notes,
    install,
    install_unavailable,
};

const State = struct {
    allocator: std.mem.Allocator,
    version: []const u8,
    reason: []const u8,
    installable: bool,
    action: Action = .later,
    closed: bool = false,
};

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeUpdateOffer");
const install_id: u16 = 9701;
const release_notes_id: u16 = 9702;
const later_id: u16 = 9703;

pub const ButtonSpec = struct {
    label: []const u8,
    id: u16,
    x: i32,
    width: i32,
    enabled: bool,
    action: Action,
};

const button_row_y: i32 = 190;

/// The dialog's button row. `windowProc` creates exactly these controls and
/// routes WM_COMMAND through `actionForCommand`, so these specs are the
/// presented behaviour rather than a parallel description of it.
///
/// `installable` reflects whether `WindowsUpdates.CheckResult.asset_url` was
/// resolved for this release: the last recorded release-asset check found
/// only macOS DMGs published, so a real release can genuinely lack a Windows
/// asset. Install stays honestly disabled in that case rather than promising
/// a download that will 404.
pub fn buttonsFor(installable: bool) [3]ButtonSpec {
    return .{
        .{ .label = "Install", .id = install_id, .x = 18, .width = 140, .enabled = installable, .action = if (installable) .install else .install_unavailable },
        .{ .label = "Release Notes", .id = release_notes_id, .x = 160, .width = 140, .enabled = true, .action = .release_notes },
        .{ .label = "Later", .id = later_id, .x = 470, .width = 110, .enabled = true, .action = .later },
    };
}

/// Action taken when the dialog is dismissed without pressing a button.
pub const dismiss_action: Action = .later;

pub fn actionForCommand(installable: bool, command: u16) ?Action {
    for (buttonsFor(installable)) |spec| {
        if (spec.id == command) return spec.action;
    }
    return null;
}

var active = false;
var active_state: State = undefined;

pub fn show(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    version: []const u8,
    reason: []const u8,
    installable: bool,
) !Action {
    registerClass() catch return error.DialogClassRegistrationFailed;
    var state = State{ .allocator = allocator, .version = version, .reason = reason, .installable = installable };
    active_state = state;
    active_state.closed = false;
    active = true;
    const title = try wideZ(allocator, "GraphCode Update Available");
    defer allocator.free(title);
    const hwnd = c.CreateWindowExW(
        c.WS_EX_DLGMODALFRAME | c.WS_EX_CONTROLPARENT,
        class_name.ptr,
        title.ptr,
        c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        620,
        280,
        parent,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse {
        active = false;
        return error.DialogCreationFailed;
    };
    _ = c.EnableWindow(parent, 0);
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.SetForegroundWindow(hwnd);
    var message: c.MSG = undefined;
    while (!active_state.closed) {
        const code = c.GetMessageW(&message, null, 0, 0);
        if (code <= 0) {
            active_state.closed = true;
            break;
        }
        if (c.IsDialogMessageW(hwnd, &message) != 0) continue;
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }
    ModalTeardown.dismiss(hwnd, parent);
    state = active_state;
    active = false;
    return state.action;
}

fn registerClass() !void {
    var klass: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    klass.lpfnWndProc = @ptrCast(&windowProc);
    klass.hInstance = c.GetModuleHandleW(null);
    klass.lpszClassName = class_name.ptr;
    klass.hCursor = c.LoadCursorW(null, Win32.resourceIdentifier(32512));
    if (c.RegisterClassW(&klass) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.DialogClassRegistrationFailed;
}

fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (!active) return c.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_CREATE => {
            createStatic(hwnd, active_state.allocator, "An update is available.", 18, 16, 560, 24);
            const version_text = std.fmt.allocPrint(active_state.allocator, "GraphCode {s}", .{
                if (active_state.version.len == 0) "update" else active_state.version,
            }) catch return 0;
            defer active_state.allocator.free(version_text);
            createStatic(hwnd, active_state.allocator, version_text, 18, 46, 560, 24);
            createStatic(hwnd, active_state.allocator, "Release Notes opens the verified GraphCode release page.", 18, 76, 560, 24);
            createStatic(hwnd, active_state.allocator, active_state.reason, 18, 106, 560, 44);
            for (buttonsFor(active_state.installable)) |spec| createButton(hwnd, spec);
            return 0;
        },
        c.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            if (actionForCommand(active_state.installable, command)) |action| {
                active_state.action = action;
                requestClose(hwnd);
                return 0;
            }
        },
        c.WM_CLOSE => {
            active_state.action = dismiss_action;
            requestClose(hwnd);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn requestClose(hwnd: c.HWND) void {
    active_state.closed = true;
    _ = c.PostMessageW(hwnd, c.WM_NULL, 0, 0);
}

fn createStatic(
    hwnd: c.HWND,
    allocator: std.mem.Allocator,
    text: []const u8,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) void {
    const wide = wideZ(allocator, text) catch return;
    defer allocator.free(wide);
    const control = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr,
        wide.ptr,
        c.WS_CHILD | c.WS_VISIBLE | c.SS_LEFT,
        x,
        y,
        width,
        height,
        hwnd,
        null,
        c.GetModuleHandleW(null),
        null,
    );
    AppFont.apply(control, AppFont.control_size, false);
}

fn createButton(hwnd: c.HWND, spec: ButtonSpec) void {
    const wide = wideZ(std.heap.c_allocator, spec.label) catch return;
    defer std.heap.c_allocator.free(wide);
    const disabled_style: c.DWORD = if (spec.enabled) 0 else @as(c.DWORD, @intCast(c.WS_DISABLED));
    const style: c.DWORD = @as(c.DWORD, @intCast(c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_PUSHBUTTON)) | disabled_style;
    const button = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON").ptr,
        wide.ptr,
        style,
        spec.x,
        button_row_y,
        spec.width,
        30,
        hwnd,
        controlId(spec.id),
        c.GetModuleHandleW(null),
        null,
    ) orelse return;
    AppFont.apply(button, AppFont.control_size, false);
    _ = c.EnableWindow(button, if (spec.enabled) 1 else 0);
}

fn controlId(value: u16) c.HMENU {
    @setRuntimeSafety(false);
    return @ptrFromInt(@as(usize, value));
}

fn wideZ(allocator: std.mem.Allocator, value: []const u8) ![]u16 {
    const raw = try std.unicode.utf8ToUtf16LeAlloc(allocator, value);
    defer allocator.free(raw);
    const result = try allocator.alloc(u16, raw.len + 1);
    @memcpy(result[0..raw.len], raw);
    result[raw.len] = 0;
    return result;
}

test "update offer disables install when no Windows asset was resolved" {
    // The last recorded release-asset check found only macOS DMGs published,
    // so a real release can genuinely lack a Windows asset. Install must stay
    // honestly disabled in that case rather than promising a doomed download.
    const install = buttonsFor(false)[0];
    try std.testing.expectEqualStrings("Install", install.label);
    try std.testing.expect(!install.enabled);
    try std.testing.expectEqual(Action.install_unavailable, install.action);

    // The two actions the app can always honour stay enabled regardless.
    for (buttonsFor(false)[1..]) |spec| {
        try std.testing.expect(spec.enabled);
        try std.testing.expect(spec.action != .install_unavailable);
    }

    var enabled_count: usize = 0;
    for (buttonsFor(false)) |spec| {
        if (spec.enabled) enabled_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), enabled_count);
}

test "update offer enables install once a Windows asset was resolved" {
    const install = buttonsFor(true)[0];
    try std.testing.expectEqualStrings("Install", install.label);
    try std.testing.expect(install.enabled);
    try std.testing.expectEqual(Action.install, install.action);

    // All three buttons are enabled once install is genuinely possible.
    var enabled_count: usize = 0;
    for (buttonsFor(true)) |spec| {
        if (spec.enabled) enabled_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), enabled_count);
}

test "update offer routes every button command to its declared action" {
    inline for (.{ true, false }) |installable| {
        for (buttonsFor(installable)) |spec| {
            try std.testing.expectEqual(spec.action, actionForCommand(installable, spec.id).?);
        }
        // Unrecognised commands must not resolve to an action; windowProc
        // relies on null to fall through to DefWindowProcW.
        try std.testing.expectEqual(@as(?Action, null), actionForCommand(installable, 0));
        try std.testing.expectEqual(@as(?Action, null), actionForCommand(installable, install_id + 100));
    }
}

test "update offer button command ids are distinct" {
    inline for (.{ true, false }) |installable| {
        const specs = buttonsFor(installable);
        for (specs, 0..) |spec, i| {
            for (specs[i + 1 ..]) |other| {
                try std.testing.expect(spec.id != other.id);
            }
        }
    }
}

test "dismissing the update offer defers rather than implying an install" {
    try std.testing.expectEqual(Action.later, dismiss_action);
}

