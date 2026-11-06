const std = @import("std");
const Lifecycle = @import("WorkspaceLifecycle.zig");
const Sheet = @import("SheetFramework.zig");
const Dpi = @import("Dpi.zig");
const Win32 = @import("Win32.zig");
const c = Win32.c;
const AppFont = @import("AppFont.zig");
const Tokens = @import("DesignTokens.zig");
const NativeForms = @import("NativeForms.zig");

pub const Validator = *const fn (std.mem.Allocator, []const u8, []const u8) anyerror![]u8;
pub const Result = struct {
    name: []u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    home: []const u8,
    current_name: []const u8,
    validator: Validator = &Lifecycle.validateName,
    draft: []u8 = &.{},
    path: []u8 = &.{},
    problem: ?[]const u8 = null,

    pub fn deinit(self: *State) void {
        self.allocator.free(self.draft);
        self.allocator.free(self.path);
    }

    pub fn update(self: *State, input: []const u8) !void {
        const draft = try self.allocator.dupe(u8, input);
        errdefer self.allocator.free(draft);
        var path: []u8 = &.{};
        errdefer self.allocator.free(path);
        var problem: ?[]const u8 = null;
        if (std.mem.trim(u8, input, " \t\r\n").len != 0) {
            if (self.validator(self.allocator, input, self.home)) |normalized| {
                defer self.allocator.free(normalized);
                path = try Lifecycle.workspacePath(self.allocator, normalized, self.home);
            } else |err| {
                problem = switch (err) {
                    error.EmptyName, error.InvalidName => "Use letters or numbers in the workspace name",
                    error.NameTooLong => "Workspace name is too long",
                    error.NameTaken, error.PathAlreadyExists => "That workspace already exists",
                    else => return err,
                };
            }
        }
        self.allocator.free(self.draft);
        self.allocator.free(self.path);
        self.draft = draft;
        self.path = path;
        self.problem = problem;
    }

    pub fn canCreate(self: *const State) bool {
        return self.path.len != 0 and self.problem == null;
    }

    pub fn previewName(self: *const State) []const u8 {
        const typed = std.mem.trim(u8, self.draft, " \t\r\n");
        return if (typed.len == 0) "Client Work" else typed;
    }

    pub fn submit(self: *State) !?Result {
        // Revalidate collisions immediately before handing the draft to App's lifecycle.
        try self.update(self.draft);
        if (!self.canCreate()) return null;
        return .{ .name = try self.allocator.dupe(u8, self.draft) };
    }
};

pub const ContentLayout = struct {
    title: Sheet.Rect,
    name: Sheet.Rect,
    detail: Sheet.Rect,
    bullets: [3]Sheet.Rect,
    preview: Sheet.Rect,
    extent: i32,

    pub fn withIsolationHeight(self: ContentLayout, height: i32, dpi: u32) ContentLayout {
        var result = self;
        result.bullets[2].height = @max(self.bullets[2].height, height);
        if (result.preview.x == result.name.x)
            result.preview.y = @max(result.preview.y, result.bullets[2].bottom() + Dpi.scale(14, dpi));
        result.extent = @max(result.extent, @max(result.bullets[2].bottom(), result.preview.bottom()) + Dpi.scale(24, dpi));
        return result;
    }
};

pub fn contentLayout(width: i32, dpi: u32) ContentLayout {
    const margin = Dpi.scale(24, dpi);
    const inner = @max(0, width - margin * 2);
    const stacked = width < Dpi.scale(430, dpi);
    const preview_width = @min(inner, Dpi.scale(150, dpi));
    const field_width = if (stacked) inner else @max(0, inner - preview_width - Dpi.scale(16, dpi));
    const preview_y = Dpi.scale(if (stacked) @as(i32, 214) else 62, dpi);
    return .{
        .title = .{ .x = margin, .y = margin, .width = inner, .height = Dpi.scale(24, dpi) },
        .name = .{ .x = margin, .y = Dpi.scale(62, dpi), .width = field_width, .height = Dpi.scale(32, dpi) },
        .detail = .{ .x = margin, .y = Dpi.scale(102, dpi), .width = field_width, .height = Dpi.scale(20, dpi) },
        .bullets = .{
            .{ .x = margin, .y = Dpi.scale(134, dpi), .width = field_width, .height = Dpi.scale(18, dpi) },
            .{ .x = margin, .y = Dpi.scale(157, dpi), .width = field_width, .height = Dpi.scale(18, dpi) },
            .{ .x = margin, .y = Dpi.scale(180, dpi), .width = field_width, .height = Dpi.scale(18, dpi) },
        },
        .preview = .{ .x = if (stacked) margin else width - margin - preview_width, .y = preview_y, .width = preview_width, .height = Dpi.scale(124, dpi) },
        .extent = if (stacked) preview_y + Dpi.scale(148, dpi) else Dpi.scale(222, dpi),
    };
}

pub const Options = struct {
    home: []const u8,
    current_name: []const u8,
};

const name_id: u16 = 9751;
const create_id: u16 = 1;
const cancel_id: u16 = 2;
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeNewWorkspace");

const CommandAction = enum { submit, cancel, change, reveal, blur, ignore };

fn commandAction(id: u16, notification: u16) CommandAction {
    if (id == create_id and notification == c.BN_CLICKED) return .submit;
    if (id == cancel_id and notification == c.BN_CLICKED) return .cancel;
    if (id == name_id and notification == c.EN_CHANGE) return .change;
    if (id == name_id and notification == c.EN_SETFOCUS) return .reveal;
    if (id == name_id and notification == c.EN_KILLFOCUS) return .blur;
    return .ignore;
}

const Dialog = struct {
    state: State,
    host: ?*Sheet.Host = null,
    root: c.HWND = null,
    title: c.HWND = null,
    name: c.HWND = null,
    name_binding: NameEditBinding = .{},
    detail: c.HWND = null,
    bullets: [3]c.HWND = .{null} ** 3,
    preview_title: c.HWND = null,
    preview_empty: c.HWND = null,
    caption: c.HWND = null,
    isolation: []const u8 = "",
    geometry: ContentLayout = undefined,
    result: ?Result = null,
    failure: ?anyerror = null,

    fn fail(self: *Dialog, err: anyerror) void {
        self.failure = err;
        if (self.host) |host| host.requestClose();
    }

    fn dpi(self: *const Dialog) u32 {
        return self.host.?.options.layout_input.dpi;
    }
};

var active: ?*Dialog = null;

const NameKeyAction = enum { forward, select_all, consume };

fn nameKeyAction(message: c.UINT, key: c.WPARAM, ctrl: bool, alt: bool, focused: bool) NameKeyAction {
    if (!focused or !ctrl or alt) return .forward;
    if (message == c.WM_KEYDOWN and key == 'A') return .select_all;
    if (message == c.WM_CHAR and key == 1) return .consume;
    return .forward;
}

const NameEditBinding = struct {
    hwnd: c.HWND = null,
    original: c.WNDPROC = null,

    fn owns(self: NameEditBinding, hwnd: c.HWND) bool {
        return hwnd != null and self.hwnd == hwnd and self.original != null;
    }

    fn destroyed(self: *NameEditBinding, hwnd: c.HWND) void {
        if (self.hwnd == hwnd) self.* = .{};
    }
};

fn nameEditProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const dialog = active orelse return c.DefWindowProcW(hwnd, message, wparam, lparam);
    if (!dialog.name_binding.owns(hwnd)) return c.DefWindowProcW(hwnd, message, wparam, lparam);
    const original = dialog.name_binding.original;
    if (message == c.WM_NCDESTROY) {
        // Host teardown runs before the stack-owned dialog and modal lease expire.
        dialog.name_binding.destroyed(hwnd);
        dialog.name = null;
        return c.CallWindowProcW(original, hwnd, message, wparam, lparam);
    }
    if (message == c.WM_KEYDOWN or message == c.WM_CHAR) {
        switch (nameKeyAction(message, wparam, c.GetKeyState(c.VK_CONTROL) < 0, c.GetKeyState(c.VK_MENU) < 0, c.GetFocus() == hwnd)) {
            .select_all => {
                _ = c.SendMessageW(hwnd, c.EM_SETSEL, 0, -1);
                return 0;
            },
            .consume => return 0,
            .forward => {},
        }
    }
    return c.CallWindowProcW(original, hwnd, message, wparam, lparam);
}

/// Returns an owned typed name only. App retains identity checks, creation and launch.
pub fn show(parent: c.HWND, allocator: std.mem.Allocator, options: Options) !?Result {
    var lease = try NativeForms.ModalLease.acquire();
    defer lease.deinit();
    const home = try allocator.dupe(u8, options.home);
    defer allocator.free(home);
    const current_name = try allocator.dupe(u8, options.current_name);
    defer allocator.free(current_name);
    var dialog = Dialog{ .state = .{ .allocator = allocator, .home = home, .current_name = current_name } };
    defer dialog.state.deinit();
    errdefer if (dialog.result) |*result| result.deinit(allocator);
    active = &dialog;
    defer active = null;
    var klass = std.mem.zeroes(c.WNDCLASSW);
    klass.lpfnWndProc = &contentProc;
    klass.hInstance = c.GetModuleHandleW(null);
    klass.lpszClassName = class_name.ptr;
    klass.hCursor = c.LoadCursorW(null, Win32.resourceIdentifier(32512));
    if (c.RegisterClassW(&klass) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.NewWorkspaceClassFailed;
    var host: Sheet.Host = .{};
    defer host.deinit();
    try host.init(parent, .{
        .layout_input = .{
            .owner = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .dpi = Win32.dpiForWindow(parent),
            .desired_width = 460,
            .minimum_width = 320,
            .heights = .{ .minimum = 240, .ideal = 440, .maximum = 600 },
            .content_extent = 222,
        },
        .context = &dialog,
        .on_layout = &layoutDialog,
        .on_message = &sheetMessage,
    });
    dialog.host = &host;
    try setText(allocator, host.hwnd, "New Workspace");
    dialog.root = c.CreateWindowExW(c.WS_EX_CONTROLPARENT, class_name.ptr, null, c.WS_CHILD | c.WS_VISIBLE, 0, 0, 0, 0, host.viewport, null, c.GetModuleHandleW(null), null) orelse return error.NewWorkspaceControlFailed;
    dialog.title = try control(&dialog, "STATIC", "New Workspace", 0, 0);
    dialog.name = try control(&dialog, "EDIT", "", name_id, c.WS_TABSTOP | c.ES_AUTOHSCROLL);
    const previous = c.SetWindowLongPtrW(dialog.name, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&nameEditProc)));
    if (previous == 0) return error.NewWorkspaceNameSubclassFailed;
    dialog.name_binding = .{
        .hwnd = dialog.name,
        .original = Win32.opaquePointerFromInt(c.WNDPROC, @bitCast(previous)),
    };
    _ = c.SendMessageW(dialog.name, 0x1501, 1, @bitCast(@intFromPtr(std.unicode.utf8ToUtf16LeStringLiteral("Client Work").ptr)));
    dialog.detail = try control(&dialog, "STATIC", "", 0, c.SS_PATHELLIPSIS);
    dialog.bullets[0] = try control(&dialog, "STATIC", "+  Its own projects and loops", 0, 0);
    dialog.bullets[1] = try control(&dialog, "STATIC", "+  Its own background daemon", 0, 0);
    const isolation = try std.fmt.allocPrint(allocator, "-  Nothing shared with {s}", .{current_name});
    defer allocator.free(isolation);
    dialog.isolation = isolation;
    dialog.bullets[2] = try control(&dialog, "STATIC", isolation, 0, 0);
    dialog.preview_title = try control(&dialog, "STATIC", "Client Work", 0, c.SS_ENDELLIPSIS);
    dialog.preview_empty = try control(&dialog, "STATIC", "empty", 0, c.SS_CENTER);
    dialog.caption = try control(&dialog, "STATIC", "A second window, starting empty", 0, c.SS_CENTER);
    try host.configureFooter(&.{
        .{ .id = cancel_id, .role = .cancel, .measured_text_width = 0 },
        .{ .id = create_id, .role = .primary, .measured_text_width = 0, .return_hint = true, .enabled = false },
    });
    _ = try host.createFooterButton(cancel_id, std.unicode.utf8ToUtf16LeStringLiteral("Cancel").ptr);
    _ = try host.createFooterButton(create_id, std.unicode.utf8ToUtf16LeStringLiteral("Create & Open").ptr);
    try host.relayout();
    try host.runModal();
    if (dialog.failure) |err| return err;
    return dialog.result;
}

fn setText(allocator: std.mem.Allocator, hwnd: c.HWND, text: []const u8) !void {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
    defer allocator.free(wide);
    if (c.SetWindowTextW(hwnd, wide.ptr) == 0) return error.NewWorkspaceTextFailed;
}

fn control(dialog: *Dialog, kind: []const u8, text: []const u8, id: u16, style: c.DWORD) !c.HWND {
    const allocator = dialog.state.allocator;
    const wide_kind = try std.unicode.utf8ToUtf16LeAllocZ(allocator, kind);
    defer allocator.free(wide_kind);
    const wide_text = try std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
    defer allocator.free(wide_text);
    const literal_text: c.DWORD = if (std.mem.eql(u8, kind, "STATIC")) c.SS_NOPREFIX else 0;
    return c.CreateWindowExW(0, wide_kind.ptr, wide_text.ptr, @as(c.DWORD, c.WS_CHILD | c.WS_VISIBLE) | style | literal_text, 0, 0, 0, 0, dialog.root, Win32.opaquePointerFromInt(c.HMENU, id), c.GetModuleHandleW(null), null) orelse error.NewWorkspaceControlFailed;
}

fn place(hwnd: c.HWND, bounds: Sheet.Rect, size: i32, bold: bool, dpi: u32) !void {
    const font = AppFont.getForDpi(size, bold, dpi) orelse return error.NewWorkspaceFontFailed;
    _ = c.SendMessageW(hwnd, c.WM_SETFONT, @intFromPtr(font), 1);
    if (c.MoveWindow(hwnd, bounds.x, bounds.y, bounds.width, bounds.height, 1) == 0)
        return error.NewWorkspaceLayoutFailed;
}

fn previewRect(dialog: *const Dialog, x: i32, y: i32, width: i32, height: i32) Sheet.Rect {
    return .{ .x = dialog.geometry.preview.x + Dpi.scale(x, dialog.dpi()), .y = dialog.geometry.preview.y + Dpi.scale(y, dialog.dpi()), .width = Dpi.scale(width, dialog.dpi()), .height = Dpi.scale(height, dialog.dpi()) };
}

fn layoutDialog(context: ?*anyopaque, layout: Sheet.Layout) !void {
    const dialog: *Dialog = @ptrCast(@alignCast(context.?));
    if (dialog.root == null or dialog.bullets[2] == null) return;
    const host = dialog.host.?;
    const dpi = dialog.dpi();
    const scrollbar = if (layout.scroll.visible) Sheet.Metrics.forDpi(dpi).scrollbar_width else 0;
    const width = @max(0, layout.viewport.width - scrollbar);
    dialog.geometry = contentLayout(width, dpi);
    dialog.geometry = dialog.geometry.withIsolationHeight(try isolationHeight(dialog), dpi);
    const extent = Dpi.unscale(dialog.geometry.extent, dpi);
    if (host.options.layout_input.content_extent != extent) {
        host.options.layout_input.content_extent = extent;
        try host.refreshOwnerGeometry();
        return;
    }
    if (c.MoveWindow(dialog.root, 0, -layout.scroll.offset, width, @max(layout.viewport.height, dialog.geometry.extent), 1) == 0)
        return error.NewWorkspaceLayoutFailed;
    try place(dialog.title, dialog.geometry.title, 15, true, dpi);
    const field_inset = Dpi.scale(4, dpi);
    var edit_bounds = dialog.geometry.name;
    edit_bounds.x += field_inset;
    edit_bounds.y += field_inset;
    edit_bounds.width = @max(0, edit_bounds.width - field_inset * 2);
    edit_bounds.height = @max(0, edit_bounds.height - field_inset * 2);
    try place(dialog.name, edit_bounds, 15, false, dpi);
    try place(dialog.detail, dialog.geometry.detail, 11, false, dpi);
    for (dialog.bullets, dialog.geometry.bullets) |hwnd, bounds| try place(hwnd, bounds, 11, false, dpi);
    try place(dialog.preview_title, previewRect(dialog, 55, 4, 84, 11), 7, false, dpi);
    try place(dialog.preview_empty, previewRect(dialog, 59, 41, 82, 14), 7, false, dpi);
    try place(dialog.caption, previewRect(dialog, 0, 96, 150, 28), 10, false, dpi);
}

fn isolationHeight(dialog: *const Dialog) !i32 {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(dialog.state.allocator, dialog.isolation);
    defer dialog.state.allocator.free(wide);
    const dc = c.GetDC(dialog.root) orelse return error.NewWorkspaceTextMeasurementFailed;
    defer _ = c.ReleaseDC(dialog.root, dc);
    const font = AppFont.getForDpi(11, false, dialog.dpi()) orelse return error.NewWorkspaceFontFailed;
    const old_font = c.SelectObject(dc, font);
    defer _ = c.SelectObject(dc, old_font);
    var bounds = c.RECT{ .left = 0, .top = 0, .right = dialog.geometry.bullets[2].width, .bottom = 0 };
    if (c.DrawTextW(dc, wide.ptr, @intCast(wide.len), &bounds, c.DT_CALCRECT | c.DT_WORDBREAK | c.DT_NOPREFIX) == 0)
        return error.NewWorkspaceTextMeasurementFailed;
    return bounds.bottom;
}

fn readName(dialog: *Dialog) ![]u8 {
    const length = c.GetWindowTextLengthW(dialog.name);
    if (length < 0) return error.NewWorkspaceNameReadFailed;
    const wide = try dialog.state.allocator.alloc(u16, @as(usize, @intCast(length)) + 1);
    defer dialog.state.allocator.free(wide);
    const copied = c.GetWindowTextW(dialog.name, wide.ptr, @intCast(wide.len));
    if (copied != length) return error.NewWorkspaceNameReadFailed;
    return std.unicode.utf16LeToUtf8Alloc(dialog.state.allocator, wide[0..@intCast(copied)]);
}

fn syncState(dialog: *Dialog) !void {
    try setText(dialog.state.allocator, dialog.detail, dialog.state.problem orelse dialog.state.path);
    try setText(dialog.state.allocator, dialog.preview_title, dialog.state.previewName());
    _ = c.EnableWindow(c.GetDlgItem(dialog.host.?.hwnd, create_id), @intFromBool(dialog.state.canCreate()));
    if (c.InvalidateRect(dialog.root, null, 1) == 0) return error.NewWorkspaceInvalidateFailed;
}

fn command(dialog: *Dialog, wparam: c.WPARAM) !bool {
    const id: u16 = @truncate(wparam);
    const notification: u16 = @truncate(wparam >> 16);
    switch (commandAction(id, notification)) {
        .cancel => {
            dialog.host.?.requestClose();
            return true;
        },
        .submit => {
            const input = try readName(dialog);
            defer dialog.state.allocator.free(input);
            try dialog.state.update(input);
            if (try dialog.state.submit()) |result| {
                dialog.result = result;
                dialog.host.?.requestClose();
            } else try syncState(dialog);
            return true;
        },
        .change => {
            const input = try readName(dialog);
            defer dialog.state.allocator.free(input);
            try dialog.state.update(input);
            try syncState(dialog);
            return true;
        },
        .reveal => {
            try dialog.host.?.reveal(dialog.geometry.name.y, dialog.geometry.detail.bottom());
            if (c.InvalidateRect(dialog.root, null, 1) == 0) return error.NewWorkspaceInvalidateFailed;
            return true;
        },
        .blur => {
            if (c.InvalidateRect(dialog.root, null, 1) == 0) return error.NewWorkspaceInvalidateFailed;
            return true;
        },
        .ignore => return false,
    }
}

fn sheetMessage(context: ?*anyopaque, _: c.HWND, message: c.UINT, wparam: c.WPARAM, _: c.LPARAM, result: *c.LRESULT) bool {
    const dialog: *Dialog = @ptrCast(@alignCast(context.?));
    if (message == c.WM_SHOWWINDOW and wparam != 0 and dialog.name != null) {
        _ = c.SetFocus(dialog.name);
        result.* = 0;
        return true;
    }
    if (message == c.DM_GETDEFID) {
        result.* = (c.DC_HASDEFID << 16) | create_id;
        return true;
    }
    if (message == c.WM_CLOSE) {
        dialog.host.?.requestClose();
        result.* = 0;
        return true;
    }
    if (message != c.WM_COMMAND) return false;
    const handled = command(dialog, wparam) catch |err| {
        dialog.fail(err);
        result.* = 0;
        return true;
    };
    result.* = 0;
    return handled;
}

fn diagramBox(hdc: c.HDC, bounds: Sheet.Rect, fill: u32, border: u32, dpi: u32) !void {
    const brush = c.CreateSolidBrush(fill) orelse return error.NewWorkspacePaintFailed;
    defer _ = c.DeleteObject(brush);
    const pen = c.CreatePen(c.PS_SOLID, @max(1, Dpi.scale(1, dpi)), border) orelse return error.NewWorkspacePaintFailed;
    defer _ = c.DeleteObject(pen);
    const old_brush = c.SelectObject(hdc, brush);
    defer _ = c.SelectObject(hdc, old_brush);
    const old_pen = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, old_pen);
    if (c.RoundRect(hdc, bounds.x, bounds.y, bounds.right(), bounds.bottom(), Dpi.scale(5, dpi), Dpi.scale(5, dpi)) == 0)
        return error.NewWorkspacePaintFailed;
}

fn paintContent(dialog: *Dialog, hdc: c.HDC) !void {
    const dpi = dialog.dpi();
    try Sheet.drawField(hdc, dialog.geometry.name, dpi, c.GetFocus() == dialog.name);
    try diagramBox(hdc, previewRect(dialog, 0, 10, 108, 74), Tokens.dialog_panel, Tokens.control_border, dpi);
    try diagramBox(hdc, previewRect(dialog, 26, 0, 118, 84), Tokens.sheet, Tokens.dialog_muted_text, dpi);
    try diagramBox(hdc, previewRect(dialog, 27, 1, 116, 15), Tokens.control_gloss_bottom, Tokens.control_gloss_bottom, dpi);
    try diagramBox(hdc, previewRect(dialog, 27, 17, 31, 66), Tokens.workspace_rail, Tokens.workspace_rail, dpi);
    for ([_]i32{ 32, 40, 48 }) |x| try diagramBox(hdc, previewRect(dialog, x, 5, 5, 5), Tokens.dialog_muted_text, Tokens.dialog_muted_text, dpi);
    try diagramBox(hdc, previewRect(dialog, 32, 23, 20, 3), Tokens.control_border, Tokens.control_border, dpi);
    try diagramBox(hdc, previewRect(dialog, 32, 29, 16, 3), Tokens.control_border, Tokens.control_border, dpi);
}

fn contentProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const dialog = active orelse return c.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_COMMAND => {
            const handled = command(dialog, wparam) catch |err| {
                dialog.fail(err);
                return 0;
            };
            if (handled) return 0;
        },
        c.WM_CTLCOLORSTATIC => {
            const hdc = Win32.opaquePointerFromInt(c.HDC, wparam);
            const child = Win32.messagePointer(c.HWND, lparam);
            _ = c.SetBkMode(hdc, c.TRANSPARENT);
            _ = c.SetTextColor(hdc, if (child == dialog.title) Tokens.dialog_title_text else if (child == dialog.detail and dialog.state.problem != null) Tokens.dialog_error_text else Tokens.dialog_muted_text);
            if (child == dialog.preview_title or child == dialog.preview_empty)
                return @bitCast(@intFromPtr(c.GetStockObject(c.HOLLOW_BRUSH)));
            return @bitCast(@intFromPtr(dialog.host.?.brushes.panel));
        },
        c.WM_CTLCOLOREDIT => return dialog.host.?.brushes.apply(Win32.opaquePointerFromInt(c.HDC, wparam), .edit, true) catch |err| {
            dialog.fail(err);
            return 0;
        },
        c.WM_ERASEBKGND => {
            var bounds: c.RECT = undefined;
            if (c.GetClientRect(hwnd, &bounds) == 0 or c.FillRect(Win32.opaquePointerFromInt(c.HDC, wparam), &bounds, dialog.host.?.brushes.panel) == 0)
                dialog.fail(error.NewWorkspacePaintFailed);
            return 1;
        },
        c.WM_PAINT => {
            var paint: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(hwnd, &paint) orelse {
                dialog.fail(error.NewWorkspacePaintFailed);
                return 0;
            };
            paintContent(dialog, hdc) catch |err| dialog.fail(err);
            _ = c.EndPaint(hwnd, &paint);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

const TestValidation = struct {
    var calls: usize = 0;
    var collision: bool = false;
    var failure: bool = false;

    fn validate(allocator: std.mem.Allocator, input: []const u8, _: []const u8) ![]u8 {
        calls += 1;
        if (failure) return error.AccessDenied;
        if (collision) return error.NameTaken;
        return Lifecycle.normalizeName(allocator, input);
    }

    fn state() State {
        calls = 0;
        collision = false;
        failure = false;
        return .{ .allocator = std.testing.allocator, .home = "C:\\OwnedHome", .current_name = "Default", .validator = &validate };
    }
};

test "new workspace empty draft is quiet and cannot submit" {
    var state = TestValidation.state();
    defer state.deinit();
    try state.update("   ");
    try std.testing.expect(state.problem == null);
    try std.testing.expect(!state.canCreate());
    try std.testing.expectEqualStrings("Client Work", state.previewName());
    try std.testing.expectEqualStrings("", state.path);
    try std.testing.expect((try state.submit()) == null);
    try std.testing.expectEqual(@as(usize, 0), TestValidation.calls);
}

test "new workspace typed title and resolved directory remain distinct" {
    var state = TestValidation.state();
    defer state.deinit();
    try state.update("  Client Work  ");
    try std.testing.expectEqualStrings("Client Work", state.previewName());
    try std.testing.expectEqualStrings("C:\\OwnedHome\\.graphcode-client-work", state.path);
    try std.testing.expect(state.canCreate());
    var result = (try state.submit()).?;
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("  Client Work  ", result.name);
    try std.testing.expectEqual(@as(usize, 2), TestValidation.calls);
}

test "new workspace invalid draft retains typed preview and clears prior path" {
    var state = TestValidation.state();
    defer state.deinit();
    try state.update("Valid");
    try state.update("!!!");
    try std.testing.expectEqualStrings("!!!", state.previewName());
    try std.testing.expectEqualStrings("", state.path);
    try std.testing.expect(state.problem != null);
    try std.testing.expect(!state.canCreate());
    try std.testing.expect((try state.submit()) == null);
}

test "new workspace collision at submit stays inline without a creation result" {
    var state = TestValidation.state();
    defer state.deinit();
    try state.update("Client Work");
    TestValidation.collision = true;
    try std.testing.expect((try state.submit()) == null);
    try std.testing.expect(state.problem != null);
    try std.testing.expectEqualStrings("That workspace already exists", state.problem.?);
    try std.testing.expect(!state.canCreate());
    TestValidation.collision = false;
    try state.update("Client Work 2");
    try std.testing.expect(state.problem == null);
    try std.testing.expect(state.canCreate());
}

test "new workspace validation operational failures propagate" {
    var state = TestValidation.state();
    defer state.deinit();
    TestValidation.failure = true;
    try std.testing.expectError(error.AccessDenied, state.update("Client Work"));
}

test "new workspace name limit follows existing lifecycle without truncation" {
    var state = TestValidation.state();
    defer state.deinit();
    try state.update(&(.{'a'} ** Lifecycle.max_name_length));
    try std.testing.expect(state.canCreate());
    try state.update(&(.{'a'} ** (Lifecycle.max_name_length + 1)));
    try std.testing.expect(state.problem != null);
    try std.testing.expectEqualStrings("Workspace name is too long", state.problem.?);
    try std.testing.expect(!state.canCreate());
}

test "new workspace layout keeps fields and diagram separate at supported DPIs" {
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const layout = contentLayout(Dpi.scale(460, dpi), dpi);
        try std.testing.expect(layout.name.width >= Dpi.scale(200, dpi));
        try std.testing.expect(layout.name.right() + Dpi.scale(16, dpi) <= layout.preview.x);
        try std.testing.expect(layout.title.bottom() < layout.name.y);
        try std.testing.expect(layout.detail.bottom() <= layout.bullets[0].y);
        try std.testing.expect(layout.preview.bottom() <= layout.extent);
        try std.testing.expect(layout.bullets[2].bottom() <= layout.extent);
    }
}

test "new workspace narrow layout stacks preview without overlapping controls" {
    const layout = contentLayout(340, 96);
    try std.testing.expect(layout.name.width > 0);
    try std.testing.expect(layout.preview.y >= layout.bullets[2].bottom() + 14);
    try std.testing.expect(layout.preview.right() <= 340 - 24);
    try std.testing.expect(layout.extent >= layout.preview.bottom() + 24);
}

test "new workspace native entrypoint links without opening a window" {
    std.mem.doNotOptimizeAway(&show);
}

test "new workspace create cancel and editing notifications route without accidental submission" {
    try std.testing.expectEqual(CommandAction.submit, commandAction(create_id, 0));
    try std.testing.expectEqual(CommandAction.cancel, commandAction(cancel_id, 0));
    try std.testing.expectEqual(CommandAction.change, commandAction(name_id, c.EN_CHANGE));
    try std.testing.expectEqual(CommandAction.reveal, commandAction(name_id, c.EN_SETFOCUS));
    try std.testing.expectEqual(CommandAction.blur, commandAction(name_id, c.EN_KILLFOCUS));
    try std.testing.expectEqual(CommandAction.ignore, commandAction(create_id, c.BN_SETFOCUS));
    try std.testing.expectEqual(CommandAction.ignore, commandAction(cancel_id, c.BN_SETFOCUS));
    try std.testing.expectEqual(CommandAction.ignore, commandAction(9999, 0));
}

test "new workspace presentation preserves Unicode and ampersands without changing directory rules" {
    var state = TestValidation.state();
    defer state.deinit();
    try state.update("Caf\xc3\xa9 R&D");
    try std.testing.expectEqualStrings("Caf\xc3\xa9 R&D", state.previewName());
    try std.testing.expectEqualStrings("C:\\OwnedHome\\.graphcode-caf-r-d", state.path);
    var result = (try state.submit()).?;
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Caf\xc3\xa9 R&D", result.name);
}

test "new workspace state and handoff release every allocation on failure" {
    const Exercise = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var state = State{ .allocator = allocator, .home = "C:\\OwnedHome", .current_name = "Default", .validator = &TestValidation.validate };
            defer state.deinit();
            try state.update("Client Work");
            try state.update("Client Work 2");
            var result = (try state.submit()) orelse return error.ExpectedWorkspaceResult;
            defer result.deinit(allocator);
        }
    };
    TestValidation.collision = false;
    TestValidation.failure = false;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Exercise.run, .{});
}

test "new workspace long isolation text grows content and keeps the stacked preview below it" {
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        for ([_]i32{ 340, 460 }) |width| {
            const base = contentLayout(Dpi.scale(width, dpi), dpi);
            const grown = base.withIsolationHeight(Dpi.scale(54, dpi), dpi);
            try std.testing.expectEqual(Dpi.scale(54, dpi), grown.bullets[2].height);
            try std.testing.expect(grown.extent >= grown.bullets[2].bottom() + Dpi.scale(24, dpi));
            if (width == 340)
                try std.testing.expect(grown.preview.y >= grown.bullets[2].bottom() + Dpi.scale(14, dpi));
            try std.testing.expect(grown.preview.bottom() + Dpi.scale(24, dpi) <= grown.extent);
        }
    }
}

test "new workspace Ctrl A policy selects all only in its focused name edit" {
    try std.testing.expectEqual(NameKeyAction.select_all, nameKeyAction(c.WM_KEYDOWN, 'A', true, false, true));
    try std.testing.expectEqual(NameKeyAction.consume, nameKeyAction(c.WM_CHAR, 1, true, false, true));
    for ([_]c.UINT{ c.WM_KEYDOWN, c.WM_SYSKEYDOWN, c.WM_KEYUP, c.WM_CHAR }) |message| {
        try std.testing.expectEqual(NameKeyAction.forward, nameKeyAction(message, 'A', false, false, true));
        try std.testing.expectEqual(NameKeyAction.forward, nameKeyAction(message, 'A', true, true, true));
        try std.testing.expectEqual(NameKeyAction.forward, nameKeyAction(message, 'A', true, false, false));
    }
    for ([_]c.WPARAM{ 'B', c.VK_DELETE, c.VK_BACK, c.VK_RETURN, c.VK_ESCAPE }) |key|
        try std.testing.expectEqual(NameKeyAction.forward, nameKeyAction(c.WM_KEYDOWN, key, true, false, true));
    try std.testing.expectEqual(NameKeyAction.forward, nameKeyAction(c.WM_CHAR, 'a', false, false, true));
    try std.testing.expectEqual(NameKeyAction.forward, nameKeyAction(c.WM_CHAR, 1, true, true, true));
    try std.testing.expectEqual(NameKeyAction.forward, nameKeyAction(c.WM_CHAR, 3, true, false, true));
    try std.testing.expectEqual(NameKeyAction.forward, nameKeyAction(c.WM_KEYUP, 'A', true, false, true));
    try std.testing.expectEqual(NameKeyAction.forward, nameKeyAction(c.WM_SYSKEYDOWN, 'A', true, false, true));
}

test "new workspace edit subclass binding ends with its exact control lifetime" {
    const Probe = struct {
        fn original(_: c.HWND, _: c.UINT, _: c.WPARAM, _: c.LPARAM) callconv(.winapi) c.LRESULT {
            return 0;
        }
    };
    const owned = Win32.opaquePointerFromInt(c.HWND, 9751);
    const foreign = Win32.opaquePointerFromInt(c.HWND, 9752);
    var binding = NameEditBinding{ .hwnd = owned, .original = &Probe.original };
    try std.testing.expect(binding.owns(owned));
    try std.testing.expect(!binding.owns(foreign));
    try std.testing.expect(!binding.owns(null));
    binding.destroyed(foreign);
    try std.testing.expect(binding.owns(owned));
    binding.destroyed(owned);
    try std.testing.expect(!binding.owns(owned));
    try std.testing.expect(binding.hwnd == null and binding.original == null);
    binding.destroyed(owned);
    try std.testing.expect(!binding.owns(owned));
    binding.hwnd = owned;
    try std.testing.expect(!binding.owns(owned));
}
