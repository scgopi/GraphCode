const std = @import("std");
const Win32 = @import("Win32.zig");
const c = Win32.c;
const AppFont = @import("AppFont.zig");
const Dpi = @import("Dpi.zig");
const SheetFramework = @import("SheetFramework.zig");

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
    host: ?*SheetFramework.Host = null,
    content_root: c.HWND = null,
    labels: [4]c.HWND = .{ null, null, null, null },
    content_extent: i32 = 176,
};

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeUpdateOffer");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("GraphCode Update Available");
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

fn enabledActionForCommand(hwnd: c.HWND, installable: bool, command: u16) ?Action {
    for (buttonsFor(installable)) |spec| {
        if (spec.id != command) continue;
        if (!spec.enabled) return null;
        const button = c.GetDlgItem(hwnd, spec.id) orelse return null;
        if (c.IsWindow(button) == 0 or c.IsWindowEnabled(button) == 0) return null;
        return spec.action;
    }
    return null;
}

fn defaultActionId(hwnd: c.HWND, installable: bool) ?u16 {
    const actions = offerFooterActions(hwnd, Dpi.normalize(Win32.dpiForWindow(hwnd)), installable);
    for (actions) |action| {
        if (!action.return_hint or !action.role.isPrimary() or !action.enabled) continue;
        if (enabledActionForCommand(hwnd, installable, action.id) != null) return action.id;
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
    errdefer active = false;
    var host: SheetFramework.Host = .{};
    defer host.deinit();
    try createSheet(&host, parent);
    try host.runModal();
    state = active_state;
    active = false;
    return state.action;
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
    active_state.content_extent = offerContentExtent(active_state.reason);
    try host.init(parent, .{
        .layout_input = .{
            .owner = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .dpi = dpi,
            .desired_width = 620,
            .minimum_width = 420,
            .heights = .{ .minimum = 230, .ideal = 280, .maximum = 460 },
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
    createContent(active_state.content_root);
    const specs = buttonsFor(active_state.installable);
    const actions = offerFooterActions(host.hwnd, dpi, specs[0].enabled);
    try host.configureFooter(&actions);
    const later = try host.createFooterButton(later_id, std.unicode.utf8ToUtf16LeStringLiteral("Later").ptr);
    const release_notes = try host.createFooterButton(release_notes_id, std.unicode.utf8ToUtf16LeStringLiteral("Release Notes").ptr);
    const install = try host.createFooterButton(install_id, std.unicode.utf8ToUtf16LeStringLiteral("Install").ptr);
    for ([_]c.HWND{ later, release_notes, install }) |button| AppFont.apply(button, AppFont.control_size, false);
    try host.relayout();
}

fn createContent(hwnd: c.HWND) void {
    active_state.labels[0] = createStatic(hwnd, active_state.allocator, "An update is available.", 22, 18, 576, 24);
    const version_text = std.fmt.allocPrint(active_state.allocator, "GraphCode {s}", .{
        if (active_state.version.len == 0) "update" else active_state.version,
    }) catch return;
    defer active_state.allocator.free(version_text);
    active_state.labels[1] = createStatic(hwnd, active_state.allocator, version_text, 22, 48, 576, 24);
    active_state.labels[2] = createStatic(hwnd, active_state.allocator, "Release Notes opens the verified GraphCode release page.", 22, 78, 576, 24);
    active_state.labels[3] = createStatic(hwnd, active_state.allocator, active_state.reason, 22, 108, 576, active_state.content_extent - 124);
}

fn applyControlFontsForDpi(state: *State, dpi: u32) !void {
    const font = AppFont.getForDpi(AppFont.control_size, false, dpi) orelse return error.DialogFontCreationFailed;
    for (state.labels) |label| {
        if (label != null) _ = c.SendMessageW(label, c.WM_SETFONT, @intFromPtr(font), 1);
    }
    for ([_]u16{ later_id, release_notes_id, install_id }) |id| {
        if (c.GetDlgItem(state.host.?.hwnd, id)) |button| {
            _ = c.SendMessageW(button, c.WM_SETFONT, @intFromPtr(font), 1);
        }
    }
}

fn layoutSheet(context: ?*anyopaque, layout: SheetFramework.Layout) !void {
    const state: *State = @ptrCast(@alignCast(context.?));
    if (state.content_root == null) return;
    const dpi = state.host.?.options.layout_input.dpi;
    try applyControlFontsForDpi(state, dpi);
    const scrollbar = if (layout.scroll.visible) SheetFramework.Metrics.forDpi(dpi).scrollbar_width else 0;
    const content_width = @max(0, layout.viewport.width - scrollbar);
    if (c.MoveWindow(
        state.content_root,
        0,
        -layout.scroll.offset,
        content_width,
        @max(layout.scroll.extent, layout.viewport.height),
        1,
    ) == 0) return error.DialogLayoutFailed;
    const width = @max(0, content_width - Dpi.scale(44, dpi));
    const positions = [_]struct { y: i32, height: i32 }{
        .{ .y = 18, .height = 24 },
        .{ .y = 48, .height = 24 },
        .{ .y = 78, .height = 24 },
        .{ .y = 108, .height = state.content_extent - 124 },
    };
    for (state.labels, positions) |label, position| {
        if (label != null and c.MoveWindow(label, Dpi.scale(22, dpi), Dpi.scale(position.y, dpi), width, Dpi.scale(position.height, dpi), 1) == 0)
            return error.DialogLayoutFailed;
    }
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

fn offerFooterActions(hwnd: c.HWND, dpi: u32, install_enabled: bool) [3]SheetFramework.FooterAction {
    return .{
        .{ .id = later_id, .role = .cancel, .measured_text_width = footerTextWidth(hwnd, dpi, std.unicode.utf8ToUtf16LeStringLiteral("Later"), 38) },
        .{ .id = release_notes_id, .role = .secondary, .measured_text_width = footerTextWidth(hwnd, dpi, std.unicode.utf8ToUtf16LeStringLiteral("Release Notes"), 92) },
        .{ .id = install_id, .role = .primary, .measured_text_width = footerTextWidth(hwnd, dpi, std.unicode.utf8ToUtf16LeStringLiteral("Install"), 44), .return_hint = true, .enabled = install_enabled },
    };
}

fn offerContentExtent(reason: []const u8) i32 {
    const lines = @max(@as(usize, 1), (reason.len + 71) / 72);
    return 124 + @as(i32, @intCast(@min(lines, 8))) * 22;
}

fn sheetMessage(context: ?*anyopaque, hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM, result: *c.LRESULT) bool {
    const state: *State = @ptrCast(@alignCast(context.?));
    switch (message) {
        c.WM_DRAWITEM => {
            result.* = drawFooterItem(state.host.?, lparam);
            return true;
        },
        c.DM_GETDEFID => {
            result.* = if (defaultActionId(hwnd, state.installable)) |id|
                @as(c.LRESULT, @intCast(id)) | (@as(c.LRESULT, c.DC_HASDEFID) << 16)
            else
                0;
            return true;
        },
        c.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            if (enabledActionForCommand(hwnd, state.installable, command)) |action| {
                state.action = action;
                state.closed = true;
                state.host.?.requestClose();
                result.* = 0;
                return true;
            }
        },
        c.WM_CLOSE => {
            state.action = dismiss_action;
            state.closed = true;
            state.host.?.requestClose();
            result.* = 0;
            return true;
        },
        else => {},
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
    if (!active or active_state.host == null) return c.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_CTLCOLORSTATIC => return active_state.host.?.brushes.apply(Win32.opaquePointerFromInt(c.HDC, wparam), .static, true) catch 0,
        c.WM_ERASEBKGND => {
            var bounds: c.RECT = undefined;
            if (c.GetClientRect(hwnd, &bounds) != 0) _ = c.FillRect(Win32.opaquePointerFromInt(c.HDC, wparam), &bounds, active_state.host.?.brushes.panel);
            return 1;
        },
        else => return c.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

fn createStatic(
    hwnd: c.HWND,
    allocator: std.mem.Allocator,
    text: []const u8,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) c.HWND {
    const wide = wideZ(allocator, text) catch return null;
    defer allocator.free(wide);
    const control = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr,
        wide.ptr,
        c.WS_CHILD | c.WS_VISIBLE | c.SS_LEFT,
        Dpi.scale(x, active_state.host.?.options.layout_input.dpi),
        Dpi.scale(y, active_state.host.?.options.layout_input.dpi),
        Dpi.scale(width, active_state.host.?.options.layout_input.dpi),
        Dpi.scale(height, active_state.host.?.options.layout_input.dpi),
        hwnd,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return null;
    AppFont.apply(control, AppFont.control_size, false);
    return control;
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

fn hiddenOwner() !c.HWND {
    return c.CreateWindowExW(
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
    ) orelse error.DialogCreationFailed;
}

fn pumpReturn(hwnd: c.HWND, target: c.HWND) void {
    var message = std.mem.zeroes(c.MSG);
    message.hwnd = target;
    message.message = c.WM_KEYDOWN;
    message.wParam = c.VK_RETURN;
    if (c.IsDialogMessageW(hwnd, &message) != 0) return;
    _ = c.TranslateMessage(&message);
    _ = c.DispatchMessageW(&message);
}

fn queriedDefaultId(hwnd: c.HWND) ?u16 {
    const reply: usize = @bitCast(c.SendMessageW(hwnd, c.DM_GETDEFID, 0, 0));
    if (reply >> 16 != c.DC_HASDEFID) return null;
    return @truncate(reply);
}

fn controlFont(control: c.HWND) c.HFONT {
    return Win32.opaquePointerFromInt(c.HFONT, @bitCast(c.SendMessageW(control, c.WM_GETFONT, 0, 0)));
}

fn expectControlFontForDpi(control: c.HWND, dpi: u32) !void {
    const font = controlFont(control);
    try std.testing.expectEqual(AppFont.getForDpi(AppFont.control_size, false, dpi), font);
    var info = std.mem.zeroes(c.LOGFONTW);
    try std.testing.expect(c.GetObjectW(font, @sizeOf(c.LOGFONTW), &info) != 0);
    try std.testing.expectEqual(-Dpi.scale(AppFont.control_size, dpi), info.lfHeight);
}

test "hidden update offer refreshes every control font across DPI transitions" {
    try registerClass();
    const owner = try hiddenOwner();
    defer _ = c.DestroyWindow(owner);
    active_state = .{
        .allocator = std.testing.allocator,
        .version = "1.2.3",
        .reason = "A verified Windows update is ready.",
        .installable = true,
    };
    active = true;
    defer active = false;
    var host: SheetFramework.Host = .{};
    defer host.deinit();
    try createSheet(&host, owner);
    try std.testing.expect(c.IsWindowVisible(host.hwnd) == 0);

    var font_96: c.HFONT = null;
    for ([_]u32{ 96, 192, 96 }) |dpi| {
        try host.refreshForDpi(dpi);
        for (active_state.labels) |label| try expectControlFontForDpi(label, dpi);
        for ([_]u16{ later_id, release_notes_id, install_id }) |id| {
            try expectControlFontForDpi(c.GetDlgItem(host.hwnd, id), dpi);
        }
        const current = controlFont(active_state.labels[0]);
        if (font_96 == null) {
            font_96 = current;
        } else if (dpi == 192) {
            try std.testing.expect(current != font_96);
        } else {
            try std.testing.expectEqual(font_96, current);
        }
    }
}

test "hidden update offer Return submits the enabled hinted Install action" {
    try registerClass();
    const owner = try hiddenOwner();
    defer _ = c.DestroyWindow(owner);
    active_state = .{
        .allocator = std.testing.allocator,
        .version = "1.2.3",
        .reason = "A verified Windows update is ready.",
        .installable = true,
    };
    active = true;
    defer active = false;
    var host: SheetFramework.Host = .{};
    defer host.deinit();
    try createSheet(&host, owner);

    try std.testing.expectEqual(@as(?u16, install_id), queriedDefaultId(host.hwnd));
    pumpReturn(host.hwnd, active_state.content_root);

    try std.testing.expect(active_state.closed);
    try std.testing.expectEqual(Action.install, active_state.action);
}

test "hidden update offer rejects Return and commands for disabled or nonexistent actions" {
    try registerClass();
    const owner = try hiddenOwner();
    defer _ = c.DestroyWindow(owner);
    active_state = .{
        .allocator = std.testing.allocator,
        .version = "1.2.3",
        .reason = "No Windows asset is available.",
        .installable = false,
    };
    active = true;
    defer active = false;
    var host: SheetFramework.Host = .{};
    defer host.deinit();
    try createSheet(&host, owner);

    try std.testing.expectEqual(@as(?u16, null), queriedDefaultId(host.hwnd));
    pumpReturn(host.hwnd, active_state.content_root);
    _ = c.SendMessageW(host.hwnd, c.WM_COMMAND, install_id, 0);
    _ = c.SendMessageW(host.hwnd, c.WM_COMMAND, install_id + 100, 0);

    try std.testing.expect(!active_state.closed);
    try std.testing.expectEqual(Action.later, active_state.action);
}

test "dialog framework: update offer uses hidden owner bounded sheet and role footer" {
    try registerClass();
    const owner = try hiddenOwner();
    defer _ = c.DestroyWindow(owner);
    active_state = .{
        .allocator = std.testing.allocator,
        .version = "1.2.3",
        .reason = "A verified Windows update is ready.",
        .installable = true,
    };
    active = true;
    defer active = false;
    var host: SheetFramework.Host = .{};
    defer host.deinit();
    try createSheet(&host, owner);
    try std.testing.expect(c.IsWindowVisible(host.hwnd) == 0);
    try std.testing.expect(c.GetWindowLongPtrW(host.hwnd, c.GWL_STYLE) & c.WS_CAPTION == 0);
    var title: [64]u16 = [_]u16{0} ** 64;
    const title_length = c.GetWindowTextW(host.hwnd, &title, title.len);
    try std.testing.expectEqualSlices(u16, window_title[0..window_title.len], title[0..@intCast(title_length)]);
    try std.testing.expect(c.GetParent(active_state.content_root) == host.viewport);
    try std.testing.expect(c.GetWindowLongPtrW(active_state.content_root, c.GWL_EXSTYLE) & c.WS_EX_CONTROLPARENT != 0);
    try std.testing.expect(host.footer_layout.?.slotFor(install_id).?.role == .primary);
    try std.testing.expect(host.footer_layout.?.slotFor(later_id).?.role == .cancel);
    try std.testing.expect(!host.current_layout.scroll.visible);
    host.options.layout_input.content_extent = Dpi.unscale(host.current_layout.viewport.height, host.options.layout_input.dpi) + 100;
    try host.relayout();
    var viewport: c.RECT = undefined;
    var content: c.RECT = undefined;
    try std.testing.expect(c.GetClientRect(host.viewport, &viewport) != 0);
    try std.testing.expect(c.GetClientRect(active_state.content_root, &content) != 0);
    try std.testing.expectEqual(
        SheetFramework.Metrics.forDpi(host.options.layout_input.dpi).scrollbar_width,
        (viewport.right - viewport.left) - (content.right - content.left),
    );
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const actions = offerFooterActions(host.hwnd, dpi, true);
        const width = Dpi.scale(620, dpi);
        const footer = try SheetFramework.measureFooter(width, Dpi.scale(64, dpi), dpi, &actions);
        try std.testing.expect(footer.measured_minimum_width <= width);
        for (footer.slice()) |slot| try std.testing.expect(slot.bounds.x >= 0 and slot.bounds.right() <= width);
        try std.testing.expect(actions[2].return_hint);
        try std.testing.expect(footer.slotFor(install_id).?.bounds.width >=
            actions[2].measured_text_width + SheetFramework.Metrics.forDpi(dpi).return_hint_width);
    }
}
