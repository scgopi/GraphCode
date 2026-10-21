const std = @import("std");
const Win32 = @import("Win32.zig");
const c = Win32.c;
const AppFont = @import("AppFont.zig");
const Dpi = @import("Dpi.zig");
const Tokens = @import("DesignTokens.zig");
const Sheet = @import("SheetFramework.zig");

const content_class = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeWindowsDialogContent");

const Layout = struct {
    width: i32 = 0,
    viewport_height: i32 = 0,
    footer_height: i32 = 0,
    extent: i32 = 0,
    inset: i32 = 0,
    text_width: i32 = 0,
    title_y: i32 = 0,
    title_height: i32 = 0,
    description_height: i32 = 0,
    description_y: i32 = 0,
    label_y: [16]i32 = [_]i32{0} ** 16,
    label_height: [16]i32 = [_]i32{0} ** 16,
    edit_y: [16]i32 = [_]i32{0} ** 16,
    edit_height: i32 = 0,

    fn maxOffset(self: Layout) i32 {
        return @max(0, self.extent - self.viewport_height);
    }
};

pub const ActionRole = Sheet.ActionRole;

pub const Action = struct {
    label: []const u8,
    role: ActionRole,
    is_default: bool = false,
};

pub const PromptSpec = struct {
    title: []const u8,
    body: []const u8 = "",
    labels: []const []const u8 = &.{},
    initial: []const []const u8 = &.{},
    cancel_action: Action = .{ .label = "Cancel", .role = .cancel },
    primary_action: Action = .{ .label = "OK", .role = .primary, .is_default = true },
};

pub const Result = struct {
    values: [16][]u8,
    count: usize,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.values[0..self.count]) |value| allocator.free(value);
        self.* = undefined;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    parent: c.HWND,
    owned_parent: c.HWND = null,
    title: []const u8 = "",
    labels: [16][]const u8 = [_][]const u8{""} ** 16,
    values: [16][]u8 = [_][]u8{&.{}} ** 16,
    label_windows: [16]c.HWND = [_]c.HWND{null} ** 16,
    edits: [16]c.HWND = [_]c.HWND{null} ** 16,
    description: []const u8 = "",
    title_window: c.HWND = null,
    description_window: c.HWND = null,
    viewport: c.HWND = null,
    cancel_action: Action = .{ .label = "Cancel", .role = .cancel },
    primary_action: Action = .{ .label = "OK", .role = .primary, .is_default = true },
    dpi: u32 = Dpi.base_dpi,
    forced_dpi: ?u32 = null,
    layout: Layout = .{},
    count: usize = 0,
    scroll_offset: i32 = 0,
    scrollbar_visible: bool = false,
    accepted: bool = false,
    closed: bool = false,
    failure: ?anyerror = null,
    /// The control that owns keyboard focus whenever the dialog is active: the first
    /// field on open, then whichever child the user left focused when it deactivated.
    focus: c.HWND = null,
};

const ok_id = 9800;
const cancel_id = 9808;
var active = false;
var active_state: State = undefined;
var active_host: Sheet.Host = .{};

pub fn text(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    title: []const u8,
    labels: []const []const u8,
    initial: []const []const u8,
) !?Result {
    if (labels.len == 0) return error.InvalidDialogFields;
    return custom(parent, allocator, .{
        .title = title,
        .labels = labels,
        .initial = initial,
    });
}

pub fn textWithDescription(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    title: []const u8,
    description: []const u8,
    labels: []const []const u8,
    initial: []const []const u8,
) !?Result {
    if (labels.len == 0) return error.InvalidDialogFields;
    return custom(parent, allocator, .{
        .title = title,
        .body = description,
        .labels = labels,
        .initial = initial,
    });
}

pub fn custom(parent: c.HWND, allocator: std.mem.Allocator, spec: PromptSpec) !?Result {
    if (active) return error.DialogAlreadyOpen;
    if (spec.labels.len > 16 or spec.labels.len != spec.initial.len) return error.InvalidDialogFields;
    if (spec.cancel_action.role.isPrimary() or !spec.primary_action.role.isPrimary())
        return error.InvalidDialogActions;
    var state = State{
        .allocator = allocator,
        .parent = parent,
        .title = spec.title,
        .count = spec.labels.len,
        .description = spec.body,
        .cancel_action = spec.cancel_action,
        .primary_action = spec.primary_action,
    };
    for (spec.labels, 0..) |label, index| {
        state.labels[index] = label;
        state.values[index] = allocator.dupe(u8, spec.initial[index]) catch |err| {
            freeStateValues(&state);
            return err;
        };
    }

    registerClass() catch |err| {
        freeStateValues(&state);
        return err;
    };
    const wide_title = wideZ(allocator, spec.title) catch |err| {
        freeStateValues(&state);
        return err;
    };
    defer allocator.free(wide_title);
    active_state = state;
    active_state.closed = false;
    active_state.accepted = false;
    active = true;
    const hwnd = createTextDialog(parent, wide_title) orelse {
        const failure = active_state.failure orelse error.DialogCreationFailed;
        deinitDialogHost();
        freeStateValues(&active_state);
        active = false;
        return failure;
    };
    _ = hwnd;
    active_host.runModal() catch |err| {
        if (active_state.failure == null) active_state.failure = err;
    };
    deinitDialogHost();
    active = false;
    return finishText(&active_state);
}

pub fn confirm(parent: c.HWND, allocator: std.mem.Allocator, spec: PromptSpec) !bool {
    if (spec.labels.len != 0 or spec.initial.len != 0) return error.InvalidDialogFields;
    var result = (try custom(parent, allocator, spec)) orelse return false;
    defer result.deinit(allocator);
    return true;
}

fn createTextDialog(parent: c.HWND, wide_title: []const u16) c.HWND {
    const owner = dialogOwner(parent) catch |err| {
        active_state.failure = err;
        return null;
    };
    active_state.parent = owner;
    active_state.dpi = Dpi.normalize(active_state.forced_dpi orelse Win32.dpiForWindow(owner));
    const initial_layout = measure(&active_state, Dpi.scale(560, active_state.dpi), 0) catch |err| {
        active_state.failure = err;
        return null;
    };
    active_host.init(owner, .{
        .layout_input = .{
            .owner = undefined,
            .dpi = active_state.dpi,
            .desired_width = 560,
            .minimum_width = 320,
            .heights = .{ .minimum = 180, .ideal = 620, .maximum = 620 },
            .content_extent = Dpi.unscale(initial_layout.extent, active_state.dpi),
        },
        .context = &active_state,
        .on_layout = onHostLayout,
        .on_message = onHostMessage,
    }) catch |err| {
        active_state.failure = err;
        return null;
    };
    if (c.SetWindowTextW(active_host.hwnd, wide_title.ptr) == 0) {
        active_state.failure = error.DialogTitleFailed;
        return null;
    }
    createControls(active_host.hwnd, &active_state) catch |err| {
        active_state.failure = err;
        return null;
    };
    return active_host.hwnd;
}

fn presentDialog(hwnd: c.HWND) void {
    _ = hwnd;
    active_host.show() catch |err| {
        failDialog(err);
        return;
    };
    if (active_state.focus) |target| _ = c.SetFocus(target);
}

fn finishText(state: *State) !?Result {
    if (state.failure) |err| {
        freeStateValues(state);
        return err;
    }
    if (!state.accepted) {
        freeStateValues(state);
        return null;
    }
    const result = Result{ .values = state.values, .count = state.count };
    state.values = [_][]u8{&.{}} ** 16;
    state.count = 0;
    return result;
}

const TextCommand = enum { submit, cancel, close };

fn applyTextCommand(state: *State, command: TextCommand) void {
    if (command == .submit) {
        readValues(state) catch |err| {
            if (state == &active_state) {
                failDialog(err);
            } else {
                state.failure = err;
                state.accepted = false;
                state.closed = true;
                if (active and active_host.hwnd != null) active_host.requestClose();
            }
            return;
        };
        state.accepted = true;
    } else {
        state.accepted = false;
    }
    state.closed = true;
    if (active and active_host.hwnd != null) active_host.requestClose();
}

fn freeStateValues(state: *State) void {
    for (state.values[0..state.count]) |value| state.allocator.free(value);
    state.values = [_][]u8{&.{}} ** 16;
    state.count = 0;
}

fn registerClass() !void {
    var klass: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    klass.lpfnWndProc = @ptrCast(&contentProc);
    klass.hInstance = c.GetModuleHandleW(null);
    klass.lpszClassName = content_class.ptr;
    klass.hCursor = c.LoadCursorW(null, Win32.resourceIdentifier(32512));
    if (c.RegisterClassW(&klass) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.DialogClassRegistrationFailed;
}

fn onHostMessage(
    context: ?*anyopaque,
    hwnd: c.HWND,
    message: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
    result: *c.LRESULT,
) bool {
    const state: *State = @ptrCast(@alignCast(context orelse return false));
    switch (message) {
        c.WM_DPICHANGED => {
            const dpi = Dpi.normalize(@intCast(@as(u16, @truncate(wparam))));
            state.dpi = dpi;
            active_host.refreshForDpi(dpi) catch |err| failDialog(err);
            result.* = 0;
            return true;
        },
        c.WM_SHOWWINDOW => {
            if (wparam != 0) if (state.focus) |target| {
                _ = c.SetFocus(target);
            };
        },
        c.WM_MOUSEWHEEL => {
            result.* = c.SendMessageW(active_host.viewport, message, wparam, lparam);
            return true;
        },
        c.WM_ACTIVATE => {
            if ((wparam & 0xffff) == c.WA_INACTIVE) {
                const current = c.GetFocus();
                if (current != null and c.IsChild(hwnd, current) != 0) state.focus = current;
            } else if (state.focus) |target| {
                _ = c.SetFocus(target);
            }
            result.* = 0;
            return true;
        },
        c.WM_SETFOCUS => {
            if (state.focus) |target| _ = c.SetFocus(target);
            result.* = 0;
            return true;
        },
        c.DM_GETDEFID => {
            var default_id: usize = if (state.cancel_action.is_default) cancel_id else ok_id;
            const focused = c.GetFocus();
            if (focused != null and c.IsChild(hwnd, focused) != 0) {
                if (std.math.cast(u16, c.GetDlgCtrlID(focused))) |focused_id| {
                    if (focused_id == cancel_id or focused_id == ok_id) default_id = focused_id;
                }
            }
            result.* = @as(c.LRESULT, @intCast(default_id)) | (@as(c.LRESULT, c.DC_HASDEFID) << 16);
            return true;
        },
        c.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            const notification: u16 = @truncate(wparam >> 16);
            if (notification == c.EN_SETFOCUS) {
                for (state.edits[0..state.count], 0..) |edit, index| {
                    if (edit == Win32.messagePointer(c.HWND, lparam)) {
                        revealField(index) catch |err| failDialog(err);
                        state.focus = edit;
                        break;
                    }
                }
                _ = c.InvalidateRect(state.viewport, null, 1);
            } else if (notification == c.EN_KILLFOCUS) {
                _ = c.InvalidateRect(state.viewport, null, 1);
            }
            if (command == ok_id or command == c.IDOK) {
                applyTextCommand(state, .submit);
                result.* = 0;
                return true;
            }
            if (command == cancel_id or command == c.IDCANCEL) {
                applyTextCommand(state, .cancel);
                result.* = 0;
                return true;
            }
        },
        c.WM_KEYDOWN => {
            if (wparam == c.VK_RETURN) {
                applyTextCommand(state, .submit);
                result.* = 0;
                return true;
            }
            if (wparam == c.VK_ESCAPE) {
                applyTextCommand(state, .cancel);
                result.* = 0;
                return true;
            }
        },
        c.WM_CLOSE => {
            applyTextCommand(state, .close);
            result.* = 0;
            return true;
        },
        c.WM_DRAWITEM => {
            const item = Win32.messagePointer(*const c.DRAWITEMSTRUCT, lparam);
            const control_id = std.math.cast(u16, item.CtlID) orelse return false;
            if (control_id != cancel_id and control_id != ok_id) return false;
            drawAction(state, item, control_id) catch |err| failDialog(err);
            result.* = 1;
            return true;
        },
        else => {},
    }
    return false;
}

fn onHostLayout(context: ?*anyopaque, framework_layout: Sheet.Layout) !void {
    const state: *State = @ptrCast(@alignCast(context orelse return));
    if (state.viewport == null) return;
    state.dpi = active_host.options.layout_input.dpi;
    state.layout = try measure(state, framework_layout.viewport.width, framework_layout.viewport.height);
    state.layout.viewport_height = framework_layout.viewport.height;
    state.layout.footer_height = framework_layout.footer.height;
    state.scroll_offset = framework_layout.scroll.offset;
    state.scrollbar_visible = framework_layout.scroll.visible;
    try layoutControls(state);
}

fn failDialog(err: anyerror) void {
    active_state.failure = err;
    active_state.accepted = false;
    active_state.closed = true;
    if (active_host.hwnd != null) active_host.requestClose();
}

fn textHeight(state: *State, dc: c.HDC, value: []const u8, width: i32) !i32 {
    const wide = try wideZ(state.allocator, value);
    defer state.allocator.free(wide);
    var rect = c.RECT{ .left = 0, .top = 0, .right = width, .bottom = 0 };
    if (c.DrawTextW(dc, wide.ptr, @intCast(wide.len - 1), &rect, c.DT_CALCRECT | c.DT_WORDBREAK | c.DT_NOPREFIX | c.DT_EDITCONTROL) == 0)
        return error.DialogTextMeasurementFailed;
    return rect.bottom;
}

fn measure(state: *State, width: i32, height: i32) !Layout {
    const dpi = state.dpi;
    const dc = c.CreateCompatibleDC(null) orelse return error.DialogTextMeasurementFailed;
    defer _ = c.DeleteDC(dc);
    const font = AppFont.getForDpi(AppFont.control_size, false, dpi) orelse return error.DialogFontCreationFailed;
    const previous = c.SelectObject(dc, font);
    defer _ = c.SelectObject(dc, previous);
    var layout = Layout{
        .width = width,
        .inset = Sheet.Metrics.forDpi(dpi).content_inset,
        .footer_height = Sheet.Metrics.forDpi(dpi).footer_height,
        .edit_height = Dpi.scale(36, dpi),
    };
    layout.viewport_height = @max(0, height - layout.footer_height);
    layout.text_width = @max(1, width - layout.inset * 2 - Sheet.Metrics.forDpi(dpi).scrollbar_width);
    var y = Dpi.scale(18, dpi);
    layout.title_y = y;
    layout.title_height = try textHeight(state, dc, state.title, layout.text_width);
    y += layout.title_height + Dpi.scale(10, dpi);
    if (state.description.len != 0) {
        layout.description_y = y;
        layout.description_height = try textHeight(state, dc, state.description, layout.text_width);
        y += layout.description_height + Dpi.scale(18, dpi);
    }
    for (state.labels[0..state.count], 0..) |label, index| {
        layout.label_y[index] = y;
        layout.label_height[index] = if (label.len == 0) Dpi.scale(18, dpi) else try textHeight(state, dc, label, layout.text_width);
        y += layout.label_height[index] + Dpi.scale(4, dpi);
        layout.edit_y[index] = y;
        y += layout.edit_height + Dpi.scale(12, dpi);
    }
    layout.extent = y;
    return layout;
}

fn control(state: *State, parent: c.HWND, class: [*:0]const u16, label: []const u8, ex_style: c.DWORD, style: c.DWORD, id: usize) !c.HWND {
    const wide = try wideZ(state.allocator, label);
    defer state.allocator.free(wide);
    return c.CreateWindowExW(ex_style, class, wide.ptr, @bitCast(@as(c.DWORD, c.WS_CHILD | c.WS_VISIBLE) | style), 0, 0, 0, 0, parent, Win32.opaquePointerFromInt(c.HMENU, id), c.GetModuleHandleW(null), null) orelse error.DialogControlCreationFailed;
}

fn createControls(hwnd: c.HWND, state: *State) !void {
    _ = hwnd;
    state.viewport = try control(state, active_host.viewport, content_class, "", c.WS_EX_CONTROLPARENT, c.WS_CLIPCHILDREN, 0);
    const static_class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    state.title_window = try control(state, state.viewport, static_class, state.title, 0, c.SS_NOPREFIX | c.SS_EDITCONTROL, 0);
    if (state.description.len != 0)
        state.description_window = try control(state, state.viewport, static_class, state.description, 0, c.SS_NOPREFIX | c.SS_EDITCONTROL, 0);
    for (state.labels[0..state.count], 0..) |label, index| {
        state.label_windows[index] = try control(state, state.viewport, static_class, label, 0, c.SS_NOPREFIX | c.SS_EDITCONTROL, 0);
        state.edits[index] = try control(state, state.viewport, std.unicode.utf8ToUtf16LeStringLiteral("EDIT"), state.values[index], 0, c.WS_TABSTOP | c.ES_AUTOHSCROLL, 9904 + index * 8);
    }
    try active_host.configureFooter(&.{
        .{ .id = cancel_id, .role = state.cancel_action.role, .measured_text_width = 0, .return_hint = state.cancel_action.is_default },
        .{ .id = ok_id, .role = state.primary_action.role, .measured_text_width = 0, .return_hint = state.primary_action.is_default },
    });
    const cancel_label = try wideZ(state.allocator, state.cancel_action.label);
    defer state.allocator.free(cancel_label);
    const primary_label = try wideZ(state.allocator, state.primary_action.label);
    defer state.allocator.free(primary_label);
    _ = try active_host.createFooterButton(cancel_id, @ptrCast(cancel_label.ptr));
    _ = try active_host.createFooterButton(ok_id, @ptrCast(primary_label.ptr));
    const measured = try measure(state, active_host.current_layout.viewport.width, active_host.current_layout.viewport.height);
    active_host.options.layout_input.content_extent = Dpi.unscale(measured.extent, state.dpi);
    try active_host.refreshOwnerGeometry();
    if (state.edits[0]) |first| {
        _ = c.SendMessageW(first, c.EM_SETSEL, 0, -1);
        state.focus = first;
    } else {
        state.focus = c.GetDlgItem(active_host.hwnd, if (state.cancel_action.is_default) cancel_id else ok_id);
    }
}

fn moveControl(state: *State, hwnd: c.HWND, x: i32, y: i32, width: i32, height: i32) !void {
    const font = AppFont.getForDpi(AppFont.control_size, false, state.dpi) orelse return error.DialogFontCreationFailed;
    _ = c.SendMessageW(hwnd, c.WM_SETFONT, @intFromPtr(font), 0);
    if (c.SetWindowPos(hwnd, null, x, y, width, height, c.SWP_NOZORDER | c.SWP_NOACTIVATE) == 0)
        return error.DialogLayoutFailed;
}

fn relayout(hwnd: c.HWND) !void {
    _ = hwnd;
    const state = &active_state;
    const measured = try measure(state, active_host.current_layout.viewport.width, active_host.current_layout.viewport.height);
    const extent = Dpi.unscale(measured.extent, state.dpi);
    if (extent != active_host.options.layout_input.content_extent) {
        try active_host.setContentExtent(extent);
    } else {
        state.layout = measured;
        state.layout.viewport_height = active_host.current_layout.viewport.height;
        state.layout.footer_height = active_host.current_layout.footer.height;
        try layoutControls(state);
    }
}

fn setScrollOffset(offset: i32) !void {
    try active_host.setScrollOffset(offset);
    active_state.scroll_offset = active_host.current_layout.scroll.offset;
    try layoutControls(&active_state);
}

fn revealField(index: usize) !void {
    const layout = active_state.layout;
    const top = layout.label_y[index];
    const bottom = layout.edit_y[index] + layout.edit_height;
    try active_host.reveal(if (bottom - top <= layout.viewport_height) top else layout.edit_y[index], bottom);
    active_state.scroll_offset = active_host.current_layout.scroll.offset;
    try layoutControls(&active_state);
}

fn contentProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (!active) return c.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_COMMAND, c.WM_DRAWITEM, c.WM_CTLCOLORSTATIC, c.WM_CTLCOLOREDIT, c.WM_CTLCOLORBTN => return c.SendMessageW(active_host.hwnd, message, wparam, lparam),
        c.WM_MOUSEWHEEL => return c.SendMessageW(active_host.viewport, message, wparam, lparam),
        c.WM_ERASEBKGND => {
            var client: c.RECT = undefined;
            if (c.GetClientRect(hwnd, &client) == 0 or c.FillRect(Win32.opaquePointerFromInt(c.HDC, wparam), &client, active_host.brushes.panel) == 0)
                failDialog(error.DialogBackgroundPaintFailed);
            return 1;
        },
        c.WM_PAINT => {
            var paint: c.PAINTSTRUCT = undefined;
            const dc = c.BeginPaint(hwnd, &paint);
            if (dc == null) {
                failDialog(error.DialogPaintFailed);
                return 0;
            }
            _ = c.FillRect(dc, &paint.rcPaint, active_host.brushes.panel);
            for (0..active_state.count) |index| {
                const bounds = Sheet.Rect{
                    .x = active_state.layout.inset,
                    .y = active_state.layout.edit_y[index],
                    .width = active_state.layout.text_width,
                    .height = active_state.layout.edit_height,
                };
                Sheet.drawField(dc, bounds, active_state.dpi, c.GetFocus() == active_state.edits[index]) catch |err| failDialog(err);
            }
            _ = c.EndPaint(hwnd, &paint);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn layoutControls(state: *State) !void {
    const layout = state.layout;
    const content_height = @max(layout.extent, layout.viewport_height);
    const scrollbar = if (state.scrollbar_visible) Sheet.Metrics.forDpi(state.dpi).scrollbar_width else 0;
    try moveControl(state, state.viewport, 0, -state.scroll_offset, @max(0, layout.width - scrollbar), content_height);
    try moveControlWithFont(state, state.title_window, layout.inset, layout.title_y, layout.text_width, layout.title_height, true);
    if (state.description_window != null)
        try moveControl(state, state.description_window, layout.inset, layout.description_y, layout.text_width, layout.description_height);
    const field_inset = Dpi.scale(6, state.dpi);
    const vertical_inset = Dpi.scale(5, state.dpi);
    for (0..state.count) |index| {
        try moveControl(state, state.label_windows[index], layout.inset, layout.label_y[index], layout.text_width, layout.label_height[index]);
        try moveControl(
            state,
            state.edits[index],
            layout.inset + field_inset,
            layout.edit_y[index] + vertical_inset,
            @max(1, layout.text_width - field_inset * 2),
            @max(1, layout.edit_height - vertical_inset * 2),
        );
    }
    if (c.RedrawWindow(state.viewport, null, null, c.RDW_INVALIDATE | c.RDW_ERASE | c.RDW_ALLCHILDREN) == 0)
        return error.DialogRedrawFailed;
}

fn moveControlWithFont(state: *State, hwnd: c.HWND, x: i32, y: i32, width: i32, height: i32, bold: bool) !void {
    const font = AppFont.getForDpi(AppFont.control_size, bold, state.dpi) orelse return error.DialogFontCreationFailed;
    _ = c.SendMessageW(hwnd, c.WM_SETFONT, @intFromPtr(font), 0);
    if (c.SetWindowPos(hwnd, null, x, y, width, height, c.SWP_NOZORDER | c.SWP_NOACTIVATE) == 0)
        return error.DialogLayoutFailed;
}

fn drawAction(state: *State, item: *const c.DRAWITEMSTRUCT, control_id: u16) !void {
    const action = if (control_id == cancel_id) state.cancel_action else state.primary_action;
    try Sheet.drawFooterAction(item, state.dpi, .{
        .id = control_id,
        .role = action.role,
        .measured_text_width = 0,
        .return_hint = action.is_default,
        .enabled = item.itemState & c.ODS_DISABLED == 0,
    });
}

fn dialogOwner(parent: c.HWND) !c.HWND {
    if (parent != null and c.IsWindow(parent) != 0) return parent;
    const owner = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr,
        null,
        c.WS_POPUP,
        40,
        50,
        1000,
        800,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.DialogOwnerCreationFailed;
    active_state.owned_parent = owner;
    return owner;
}

fn deinitDialogHost() void {
    active_host.deinit();
    if (active_state.owned_parent != null and c.IsWindow(active_state.owned_parent) != 0)
        _ = c.DestroyWindow(active_state.owned_parent);
    active_state.owned_parent = null;
}

fn readValues(state: *State) !void {
    var buffer: [4096]u16 = undefined;
    for (0..state.count) |index| {
        if (c.IsWindow(state.edits[index]) == 0) return error.DialogReadFailed;
        if (c.GetWindowTextLengthW(state.edits[index]) >= buffer.len) return error.DialogTextTooLong;
        c.SetLastError(0);
        const length = c.GetWindowTextW(state.edits[index], &buffer, @intCast(buffer.len));
        if (length == 0 and c.GetLastError() != 0) return error.DialogReadFailed;
        const value = try std.unicode.utf16LeToUtf8Alloc(state.allocator, buffer[0..@intCast(length)]);
        state.allocator.free(state.values[index]);
        state.values[index] = value;
    }
}

fn wideZ(allocator: std.mem.Allocator, value: []const u8) ![]u16 {
    const raw = try std.unicode.utf8ToUtf16LeAlloc(allocator, value);
    defer allocator.free(raw);
    const result = try allocator.alloc(u16, raw.len + 1);
    @memcpy(result[0..raw.len], raw);
    result[raw.len] = 0;
    return result;
}

test "native dialog field contract preserves Unicode and field count" {
    const labels = [_][]const u8{ "URL", "Destination" };
    try std.testing.expectEqual(labels.len, 2);
    try std.testing.expect(std.unicode.utf8ValidateSlice("Проекты\\über"));
}

fn hiddenPrompt(count: usize, description: []const u8) !c.HWND {
    return hiddenPromptForDpi(count, description, Dpi.base_dpi);
}

fn hiddenPromptForDpi(count: usize, description: []const u8, dpi: u32) !c.HWND {
    var labels: [16][]const u8 = [_][]const u8{""} ** 16;
    var initial: [16][]const u8 = [_][]const u8{""} ** 16;
    for (0..count) |index| {
        labels[index] = "Title";
        initial[index] = "fixture";
    }
    return hiddenPromptSpec(
        "Prompt fixture",
        description,
        labels[0..count],
        initial[0..count],
        dpi,
    );
}

fn hiddenPromptSpec(
    title: []const u8,
    description: []const u8,
    labels: []const []const u8,
    initial: []const []const u8,
    dpi: u32,
) !c.HWND {
    return hiddenCustomPrompt(.{
        .title = title,
        .body = description,
        .labels = labels,
        .initial = initial,
    }, dpi);
}

fn hiddenCustomPrompt(spec: PromptSpec, dpi: u32) !c.HWND {
    if (spec.labels.len > 16 or spec.labels.len != spec.initial.len) return error.InvalidDialogFields;
    active_state = State{
        .allocator = std.testing.allocator,
        .parent = null,
        .title = spec.title,
        .count = spec.labels.len,
        .description = spec.body,
        .cancel_action = spec.cancel_action,
        .primary_action = spec.primary_action,
        .forced_dpi = dpi,
    };
    errdefer freeStateValues(&active_state);
    for (spec.labels, spec.initial, 0..) |label, value, index| {
        active_state.labels[index] = label;
        active_state.values[index] = try std.testing.allocator.dupe(u8, value);
    }
    active = true;
    try registerClass();
    const wide_title = try wideZ(std.testing.allocator, spec.title);
    defer std.testing.allocator.free(wide_title);
    return createTextDialog(null, wide_title) orelse return active_state.failure orelse error.TestWindowCreationFailed;
}

fn cleanupHiddenPrompt() void {
    deinitDialogHost();
    freeStateValues(&active_state);
    active = false;
}

fn windowText(allocator: std.mem.Allocator, hwnd: c.HWND) ![]u8 {
    const length = c.GetWindowTextLengthW(hwnd);
    const buffer = try allocator.alloc(u16, @as(usize, @intCast(length)) + 1);
    defer allocator.free(buffer);
    const copied = c.GetWindowTextW(hwnd, buffer.ptr, @intCast(buffer.len));
    if (copied != length) return error.TestWindowTextReadFailed;
    return std.unicode.utf16LeToUtf8Alloc(allocator, buffer[0..@intCast(copied)]);
}

fn buttonText(allocator: std.mem.Allocator, hwnd: c.HWND, id: usize) ![]u8 {
    const button = c.GetDlgItem(hwnd, @intCast(id)) orelse return error.TestButtonMissing;
    return windowText(allocator, button);
}

test "dialog framework: rename spec carries exact title body and Rename action" {
    const hwnd = try hiddenCustomPrompt(.{
        .title = "Rename “Build graph”",
        .body = "Only the name changes — the loop keeps its session, its edges, and its work.",
        .labels = &.{"Title"},
        .initial = &.{"Build graph"},
        .primary_action = .{ .label = "Rename", .role = .primary, .is_default = true },
    }, Dpi.base_dpi);
    defer cleanupHiddenPrompt();
    const title = try windowText(std.testing.allocator, hwnd);
    defer std.testing.allocator.free(title);
    const body = try windowText(std.testing.allocator, active_state.description_window);
    defer std.testing.allocator.free(body);
    const primary = try buttonText(std.testing.allocator, hwnd, ok_id);
    defer std.testing.allocator.free(primary);
    const cancel = try buttonText(std.testing.allocator, hwnd, cancel_id);
    defer std.testing.allocator.free(cancel);

    try std.testing.expectEqualStrings("Rename “Build graph”", title);
    try std.testing.expectEqualStrings("Only the name changes — the loop keeps its session, its edges, and its work.", body);
    try std.testing.expectEqualStrings("Rename", primary);
    try std.testing.expectEqualStrings("Cancel", cancel);
}

test "dialog framework: destructive confirmation is custom and role tagged" {
    const hwnd = try hiddenCustomPrompt(.{
        .title = "Delete “Build graph”?",
        .body = "Its terminal session is ended and every edge touching it is removed. This can't be undone.",
        .primary_action = .{ .label = "Delete", .role = .destructive, .is_default = true },
    }, Dpi.base_dpi);
    defer cleanupHiddenPrompt();
    const primary = c.GetDlgItem(hwnd, ok_id) orelse return error.TestButtonMissing;
    const primary_text = try windowText(std.testing.allocator, primary);
    defer std.testing.allocator.free(primary_text);
    const cancel_text = try buttonText(std.testing.allocator, hwnd, cancel_id);
    defer std.testing.allocator.free(cancel_text);
    const style: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWL_STYLE));
    const button_style: usize = @bitCast(c.GetWindowLongPtrW(primary, c.GWL_STYLE));
    const default_result: usize = @bitCast(c.SendMessageW(hwnd, c.DM_GETDEFID, 0, 0));
    const default_id: u16 = @truncate(default_result);

    try std.testing.expect(
        style & c.WS_CAPTION == 0 and
            active_state.count == 0 and
            std.mem.eql(u8, primary_text, "Delete") and
            std.mem.eql(u8, cancel_text, "Cancel") and
            active_state.cancel_action.role == .cancel and
            active_state.primary_action.role == .destructive and
            button_style & c.BS_DEFPUSHBUTTON != 0 and
            default_id == ok_id,
    );
}

test "dialog framework: prompt footer measures labels and renders return hint at 96 144 192 DPI" {
    var previous_width: i32 = 0;
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const hwnd = try hiddenCustomPrompt(.{
            .title = "Delete selected worktree?",
            .body = "This can't be undone.",
            .primary_action = .{ .label = "Delete selected worktree", .role = .destructive, .is_default = true },
        }, dpi);
        defer cleanupHiddenPrompt();
        const button = c.GetDlgItem(hwnd, ok_id) orelse return error.TestButtonMissing;
        const measured = try Sheet.measureFooterActionLabel(button, dpi);
        try std.testing.expect(measured > previous_width);
        previous_width = measured;
        try std.testing.expectEqual(measured, active_host.footer_actions[1].measured_text_width);
        const slot = active_host.footer_layout.?.slotFor(ok_id).?;
        const metrics = Sheet.Metrics.forDpi(dpi);
        try std.testing.expectEqual(
            @max(metrics.button_min_width, measured + metrics.button_text_padding * 2 + metrics.return_hint_width),
            slot.bounds.width,
        );
        const action = active_host.footer_actions[1];
        try std.testing.expect(action.role == .destructive and action.return_hint);

        const screen = c.GetDC(null);
        if (screen == null) return error.TestScreenDcUnavailable;
        defer _ = c.ReleaseDC(null, screen);
        const dc = c.CreateCompatibleDC(screen) orelse return error.TestDcCreationFailed;
        defer _ = c.DeleteDC(dc);
        const bitmap = c.CreateCompatibleBitmap(screen, slot.bounds.width, slot.bounds.height) orelse
            return error.TestBitmapCreationFailed;
        defer _ = c.DeleteObject(bitmap);
        const previous = c.SelectObject(dc, bitmap);
        defer _ = c.SelectObject(dc, previous);
        const fill = c.CreateSolidBrush(Tokens.pane_focus_tint) orelse return error.TestBrushCreationFailed;
        defer _ = c.DeleteObject(fill);
        var bounds = c.RECT{ .left = 0, .top = 0, .right = slot.bounds.width, .bottom = slot.bounds.height };
        try std.testing.expect(c.FillRect(dc, &bounds, fill) != 0);
        var item = std.mem.zeroes(c.DRAWITEMSTRUCT);
        item.CtlID = ok_id;
        item.hwndItem = button;
        item.hDC = dc;
        item.rcItem = bounds;
        drawAction(&active_state, &item, ok_id) catch |err| return err;
        const content = Sheet.footerContentLayout(.{
            .x = 0,
            .y = 0,
            .width = slot.bounds.width,
            .height = slot.bounds.height,
        }, dpi, action);
        const hint = content.return_hint orelse return error.TestReturnHintMissing;
        var changed_pixels: usize = 0;
        var y = hint.y;
        while (y < hint.bottom()) : (y += 1) {
            var x = hint.x;
            while (x < hint.right()) : (x += 1) {
                if (c.GetPixel(dc, x, y) != Tokens.pane_focus_tint) changed_pixels += 1;
            }
        }
        try std.testing.expect(changed_pixels > 0);
    }
}

test "dialog framework: prompt callback defers unknown and wide draw-item IDs safely" {
    var state = State{ .allocator = std.testing.allocator, .parent = null };
    var result: c.LRESULT = -1;
    var item: c.DRAWITEMSTRUCT = std.mem.zeroes(c.DRAWITEMSTRUCT);
    item.CtlID = std.math.maxInt(c.UINT);
    try std.testing.expect(!onHostMessage(
        &state,
        null,
        c.WM_DRAWITEM,
        0,
        @bitCast(@intFromPtr(&item)),
        &result,
    ));
    try std.testing.expect(state.failure == null);

    item.CtlID = 99;
    try std.testing.expect(!onHostMessage(
        &state,
        null,
        c.WM_DRAWITEM,
        0,
        @bitCast(@intFromPtr(&item)),
        &result,
    ));
    try std.testing.expect(state.failure == null);
    try std.testing.expect(std.math.cast(u16, @as(c.INT, -1)) == null);
}

test "dialog framework: selected initial rename value survives the exact Rename contract" {
    const initial = "Build graph";
    const hwnd = try hiddenCustomPrompt(.{
        .title = "Rename “Build graph”",
        .body = "Only the name changes — the loop keeps its session, its edges, and its work.",
        .labels = &.{"Title"},
        .initial = &.{initial},
        .primary_action = .{ .label = "Rename", .role = .primary, .is_default = true },
    }, Dpi.base_dpi);
    defer cleanupHiddenPrompt();
    const edit = active_state.edits[0] orelse return error.TestEditMissing;
    const value = try windowText(std.testing.allocator, edit);
    defer std.testing.allocator.free(value);
    var selection_start: c.DWORD = 0;
    var selection_end: c.DWORD = 0;
    _ = c.SendMessageW(
        edit,
        c.EM_GETSEL,
        @intFromPtr(&selection_start),
        @bitCast(@intFromPtr(&selection_end)),
    );
    const primary = try buttonText(std.testing.allocator, hwnd, ok_id);
    defer std.testing.allocator.free(primary);

    try std.testing.expectEqualStrings(initial, value);
    try std.testing.expectEqual(@as(c.DWORD, 0), selection_start);
    try std.testing.expectEqual(@as(c.DWORD, initial.len), selection_end);
    try std.testing.expectEqualStrings("Rename", primary);
}

fn rectIn(window: c.HWND, parent: c.HWND) !c.RECT {
    var rect: c.RECT = undefined;
    if (c.GetWindowRect(window, &rect) == 0) return error.TestWindowRectFailed;
    _ = c.MapWindowPoints(null, parent, @ptrCast(&rect), 2);
    return rect;
}

test "sheet framework: no-description prompt footer fits actual client" {
    for ([_]usize{ 1, 4 }) |count| {
        const hwnd = try hiddenPrompt(count, "");
        defer cleanupHiddenPrompt();
        var client: c.RECT = undefined;
        try std.testing.expect(c.GetClientRect(hwnd, &client) != 0);
        for ([_]c.HWND{ c.GetDlgItem(hwnd, ok_id), c.GetDlgItem(hwnd, cancel_id) }) |button| {
            const rect = try rectIn(button, hwnd);
            try std.testing.expect(rect.bottom <= client.bottom);
        }
    }
}

test "sheet framework: description prompt footer fits actual client" {
    for ([_]usize{ 1, 4 }) |count| {
        const hwnd = try hiddenPrompt(count, "Only the name changes; the session and edges stay.");
        defer cleanupHiddenPrompt();
        var client: c.RECT = undefined;
        try std.testing.expect(c.GetClientRect(hwnd, &client) != 0);
        const button = try rectIn(c.GetDlgItem(hwnd, ok_id), hwnd);
        try std.testing.expect(button.bottom <= client.bottom);
        const edit = try rectIn(active_state.edits[count - 1], hwnd);
        try std.testing.expect(edit.bottom <= button.top);
    }
}

test "sheet framework: static labels paint an opaque panel background" {
    const hwnd = try hiddenPrompt(1, "Description");
    defer cleanupHiddenPrompt();
    _ = hwnd;
    const dc = c.CreateCompatibleDC(null) orelse return error.TestDcCreationFailed;
    defer _ = c.DeleteDC(dc);
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    const brush = c.SendMessageW(active_state.viewport, c.WM_CTLCOLORSTATIC, @intFromPtr(dc), @bitCast(@intFromPtr(active_state.label_windows[0])));
    try std.testing.expect(brush != 0);
    try std.testing.expectEqual(@as(c.INT, c.OPAQUE), c.GetBkMode(dc));
    var info: c.LOGBRUSH = undefined;
    try std.testing.expect(c.GetObjectW(Win32.opaquePointerFromInt(c.HBRUSH, @bitCast(brush)), @sizeOf(c.LOGBRUSH), &info) != 0);
    try std.testing.expectEqual(@as(c.UINT, c.BS_SOLID), info.lbStyle);
    try std.testing.expectEqual(Tokens.dialog_panel, c.GetBkColor(dc));
    try std.testing.expectEqual(Tokens.dialog_panel, info.lbColor);
}

test "sheet framework: 1 4 16 fields partition actual client at 96 144 192 DPI" {
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        for ([_]usize{ 1, 4, 16 }) |count| {
            const hwnd = try hiddenPromptForDpi(count, "Long description " ** 30, dpi);
            defer cleanupHiddenPrompt();
            try std.testing.expect(c.IsWindowVisible(hwnd) == 0);
            var client: c.RECT = undefined;
            try std.testing.expect(c.GetClientRect(hwnd, &client) != 0);
            const layout = active_state.layout;
            const viewport = try rectIn(active_host.viewport, hwnd);
            try std.testing.expectEqual(@as(i32, 0), viewport.top);
            try std.testing.expectEqual(layout.viewport_height, viewport.bottom);
            try std.testing.expectEqual(client.bottom, layout.viewport_height + layout.footer_height);
            for ([_]c.HWND{ c.GetDlgItem(hwnd, ok_id), c.GetDlgItem(hwnd, cancel_id) }) |button| {
                const rect = try rectIn(button, hwnd);
                try std.testing.expect(rect.left >= 0 and rect.right <= client.right);
                try std.testing.expect(rect.top >= viewport.bottom and rect.bottom <= client.bottom);
            }
            try std.testing.expectEqual(active_state.viewport, c.GetParent(active_state.edits[0]));
            try std.testing.expect(@as(usize, @bitCast(c.GetWindowLongPtrW(hwnd, c.GWL_STYLE))) & c.WS_VSCROLL == 0);
            try setScrollOffset(std.math.maxInt(i32));
            const last = try rectIn(active_state.edits[count - 1], active_host.viewport);
            try std.testing.expect(last.top >= 0 and last.bottom <= layout.viewport_height);
            try std.testing.expectEqual(layout.maxOffset(), active_state.scroll_offset);
            try std.testing.expectEqual(active_host.current_layout.scroll.max_offset, active_state.scroll_offset);
        }
    }
}

test "sheet framework: overflow scroll and focus notifications leave footer fixed" {
    const hwnd = try hiddenPrompt(16, "Description with enough words to wrap " ** 20);
    defer cleanupHiddenPrompt();
    var outer: c.RECT = undefined;
    try std.testing.expect(c.GetWindowRect(hwnd, &outer) != 0);
    try std.testing.expect(c.SetWindowPos(hwnd, null, 0, 0, outer.right - outer.left, 300, c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0);
    const before = try rectIn(c.GetDlgItem(hwnd, ok_id), hwnd);
    const layout = active_state.layout;
    try std.testing.expect(layout.maxOffset() > 0);
    try std.testing.expect(active_host.current_layout.scroll.visible);
    try std.testing.expectEqual(layout.extent, active_host.current_layout.scroll.extent);
    try std.testing.expectEqual(layout.viewport_height, active_host.current_layout.scroll.page);
    var viewport_client: c.RECT = undefined;
    var content_client: c.RECT = undefined;
    try std.testing.expect(c.GetClientRect(active_host.viewport, &viewport_client) != 0);
    try std.testing.expect(c.GetClientRect(active_state.viewport, &content_client) != 0);
    try std.testing.expectEqual(
        Sheet.Metrics.forDpi(active_state.dpi).scrollbar_width,
        viewport_client.right - content_client.right,
    );

    _ = c.SendMessageW(active_host.viewport, c.WM_VSCROLL, c.SB_BOTTOM, 0);
    active_state.scroll_offset = active_host.current_layout.scroll.offset;
    try std.testing.expectEqual(layout.maxOffset(), active_state.scroll_offset);
    var last = try rectIn(active_state.edits[15], active_host.viewport);
    try std.testing.expect(last.top >= 0 and last.bottom <= layout.viewport_height);
    try setScrollOffset(100);
    _ = c.SendMessageW(hwnd, c.WM_MOUSEWHEEL, @as(usize, 120) << 16, 0);
    active_state.scroll_offset = active_host.current_layout.scroll.offset;
    try std.testing.expect(active_state.scroll_offset < 100);
    _ = c.SendMessageW(hwnd, c.WM_MOUSEWHEEL, @as(usize, @as(u16, @bitCast(@as(i16, -120)))) << 16, 0);
    active_state.scroll_offset = active_host.current_layout.scroll.offset;
    try std.testing.expectEqual(@as(i32, 100), active_state.scroll_offset);
    _ = c.SendMessageW(active_host.viewport, c.WM_VSCROLL, c.SB_TOP, 0);
    active_state.scroll_offset = active_host.current_layout.scroll.offset;
    try std.testing.expectEqual(@as(i32, 0), active_state.scroll_offset);
    // Inject the native notification without taking desktop focus.
    _ = c.SendMessageW(active_state.viewport, c.WM_COMMAND, (c.EN_SETFOCUS << 16) | (9904 + 15 * 8), @bitCast(@intFromPtr(active_state.edits[15])));
    last = try rectIn(active_state.edits[15], active_host.viewport);
    try std.testing.expect(last.top >= 0 and last.bottom <= layout.viewport_height);
    try std.testing.expectEqualDeep(before, try rectIn(c.GetDlgItem(hwnd, ok_id), hwnd));
    try std.testing.expect(c.SetWindowPos(hwnd, null, 0, 0, outer.right - outer.left, 1000, c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0);
    try std.testing.expect(active_state.scroll_offset <= active_state.layout.maxOffset());
    try setScrollOffset(-1);
    try std.testing.expectEqual(@as(i32, 0), active_state.scroll_offset);
}

test "sheet framework: native viewport erase paints the panel into a memory bitmap" {
    const hwnd = try hiddenPrompt(1, "");
    defer cleanupHiddenPrompt();
    _ = hwnd;
    const dc = c.CreateCompatibleDC(null) orelse return error.TestDcCreationFailed;
    defer _ = c.DeleteDC(dc);
    var bitmap_info = std.mem.zeroes(c.BITMAPINFO);
    bitmap_info.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bitmap_info.bmiHeader.biWidth = active_state.layout.width;
    bitmap_info.bmiHeader.biHeight = -active_state.layout.viewport_height;
    bitmap_info.bmiHeader.biPlanes = 1;
    bitmap_info.bmiHeader.biBitCount = 32;
    var pixels: ?*anyopaque = null;
    const bitmap = c.CreateDIBSection(dc, &bitmap_info, c.DIB_RGB_COLORS, &pixels, null, 0) orelse return error.TestBitmapCreationFailed;
    defer _ = c.DeleteObject(bitmap);
    const previous = c.SelectObject(dc, bitmap);
    defer _ = c.SelectObject(dc, previous);
    _ = c.PatBlt(dc, 0, 0, active_state.layout.width, active_state.layout.viewport_height, c.WHITENESS);
    try std.testing.expect(c.SendMessageW(active_state.viewport, c.WM_ERASEBKGND, @intFromPtr(dc), 0) != 0);
    try std.testing.expectEqual(Tokens.dialog_panel, c.GetPixel(dc, 1, 1));
    try std.testing.expectEqual(Tokens.dialog_panel, c.GetPixel(dc, active_state.layout.width - 2, active_state.layout.viewport_height - 2));
}

test "sheet framework: DPI relayout reapplies measured font geometry without presenting" {
    const hwnd = try hiddenPrompt(4, "A description that wraps at the actual content width. " ** 10);
    defer cleanupHiddenPrompt();
    for ([_]u32{ 144, 192, 96 }) |dpi| {
        var suggested: c.RECT = undefined;
        try std.testing.expect(c.GetWindowRect(hwnd, &suggested) != 0);
        _ = c.SendMessageW(hwnd, c.WM_DPICHANGED, @as(usize, dpi) | (@as(usize, dpi) << 16), @bitCast(@intFromPtr(&suggested)));
        if (active_state.failure) |err| return err;
        try std.testing.expect(!active_state.closed);
        try std.testing.expectEqual(dpi, active_state.dpi);
        try std.testing.expect(c.IsWindowVisible(hwnd) == 0);
        const font = AppFont.getForDpi(AppFont.control_size, false, dpi);
        try std.testing.expectEqual(
            @as(u32, @truncate(@intFromPtr(font))),
            @as(u32, @truncate(@as(usize, @bitCast(c.SendMessageW(active_state.edits[0], c.WM_GETFONT, 0, 0))))),
        );
        var client: c.RECT = undefined;
        try std.testing.expect(c.GetClientRect(hwnd, &client) != 0);
        try std.testing.expectEqual(client.bottom, active_state.layout.viewport_height + Sheet.Metrics.forDpi(dpi).footer_height);
        const button = try rectIn(c.GetDlgItem(hwnd, ok_id), hwnd);
        try std.testing.expect(button.top >= active_state.layout.viewport_height and button.bottom <= client.bottom);
    }
}

test "sheet framework: short prompts hide scrollbar and wrapped labels use measured bounds" {
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const hwnd = try hiddenPromptForDpi(1, "", dpi);
        defer cleanupHiddenPrompt();
        try std.testing.expectEqual(@as(i32, 0), active_state.layout.maxOffset());
        try std.testing.expect(@as(usize, @bitCast(c.GetWindowLongPtrW(active_state.viewport, c.GWL_STYLE))) & c.WS_VSCROLL == 0);
        const short_height = active_state.layout.label_height[0];
        active_state.labels[0] = "Long field label with wrapping " ** 18;
        const wide_label = try wideZ(std.testing.allocator, active_state.labels[0]);
        defer std.testing.allocator.free(wide_label);
        try std.testing.expect(c.SetWindowTextW(active_state.label_windows[0], wide_label.ptr) != 0);
        try relayout(hwnd);
        try std.testing.expect(active_state.layout.label_height[0] > short_height);
        const label = try rectIn(active_state.label_windows[0], active_state.viewport);
        const edit = try rectIn(active_state.edits[0], active_state.viewport);
        try std.testing.expect(label.bottom < edit.top);
        try std.testing.expectEqual(active_state.layout.text_width, label.right - label.left);
        try std.testing.expect(active_state.layout.maxOffset() > 0);
    }
}

test "sheet framework: child command routing preserves owned Unicode and modal outcomes" {
    for ([_]usize{ ok_id, cancel_id, c.IDCANCEL }) |command| {
        const hwnd = try hiddenPrompt(1, "");
        defer cleanupHiddenPrompt();
        _ = hwnd;
        try std.testing.expect(c.SetWindowTextW(active_state.edits[0], std.unicode.utf8ToUtf16LeStringLiteral("Проекты über")) != 0);
        _ = c.SendMessageW(active_state.viewport, c.WM_COMMAND, command, 0);
        try std.testing.expect(active_state.closed);
        if (command == ok_id) {
            var result = (try finishText(&active_state)) orelse return error.ExpectedAcceptedText;
            defer result.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("Проекты über", result.values[0]);
        } else {
            try std.testing.expect((try finishText(&active_state)) == null);
        }
    }
}

test "sheet framework: prompt field read failure closes the hidden host" {
    const hwnd = try hiddenPrompt(1, "");
    defer cleanupHiddenPrompt();
    _ = hwnd;
    const edit = active_state.edits[0] orelse return error.TestWindowCreationFailed;
    try std.testing.expect(c.DestroyWindow(edit) != 0);
    applyTextCommand(&active_state, .submit);
    try std.testing.expectEqual(error.DialogReadFailed, active_state.failure.?);
    try std.testing.expect(active_state.closed);
    try std.testing.expect(active_host.closed);
}

test "sheet framework: focus reveals an edit above scroll even with a viewport-tall label" {
    const hwnd = try hiddenPrompt(16, "");
    defer cleanupHiddenPrompt();
    active_state.labels[0] = "Long wrapped first label " ** 500;
    try relayout(hwnd);
    try setScrollOffset(active_state.layout.maxOffset());
    const first = active_state.edits[0];
    _ = c.SendMessageW(active_state.viewport, c.WM_COMMAND, (c.EN_SETFOCUS << 16) | 9904, @bitCast(@intFromPtr(first)));
    const rect = try rectIn(first, active_host.viewport);
    try std.testing.expect(rect.top >= 0 and rect.bottom <= active_state.layout.viewport_height);
}

test "sheet framework: DPI change stays centered and clamped to owner instead of suggested position" {
    const hwnd = try hiddenPrompt(1, "");
    defer cleanupHiddenPrompt();
    for ([_]u32{ 144, 192, 96 }) |dpi| {
        var suggested = c.RECT{ .left = -4000, .top = -3000, .right = -3400, .bottom = -2600 };
        _ = c.SendMessageW(hwnd, c.WM_DPICHANGED, @as(usize, dpi) | (@as(usize, dpi) << 16), @bitCast(@intFromPtr(&suggested)));
        if (active_state.failure) |err| return err;
        var actual: c.RECT = undefined;
        try std.testing.expect(c.GetWindowRect(hwnd, &actual) != 0);
        const expected = active_host.current_layout.sheet;
        try std.testing.expectEqualDeep(expected, Sheet.Rect{
            .x = actual.left,
            .y = actual.top,
            .width = actual.right - actual.left,
            .height = actual.bottom - actual.top,
        });
        const owner = active_host.options.layout_input.owner;
        try std.testing.expect(actual.left >= owner.x and actual.right <= owner.right());
        try std.testing.expect(actual.top >= owner.y and actual.bottom <= owner.bottom());
        try std.testing.expect(actual.left != suggested.left and actual.top != suggested.top);
        var scrim: c.RECT = undefined;
        try std.testing.expect(c.GetWindowRect(active_host.scrim, &scrim) != 0);
        try std.testing.expectEqualDeep(owner, Sheet.Rect{
            .x = scrim.left,
            .y = scrim.top,
            .width = scrim.right - scrim.left,
            .height = scrim.bottom - scrim.top,
        });
    }
}

test "sheet framework: creation failures release partial values and controls" {
    try registerClass();
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            active_state = State{ .allocator = allocator, .parent = null, .title = "Allocation fixture", .count = 2, .description = "Description" };
            defer {
                deinitDialogHost();
                freeStateValues(&active_state);
                active = false;
            }
            active_state.labels[0] = "First";
            active_state.labels[1] = "Second";
            active_state.values[0] = try allocator.dupe(u8, "first");
            active_state.values[1] = try allocator.dupe(u8, "second");
            active = true;
            const hwnd = createTextDialog(null, std.unicode.utf8ToUtf16LeStringLiteral("Allocation fixture")) orelse return active_state.failure orelse error.TestWindowCreationFailed;
            _ = hwnd;
            if (active_state.failure) |err| return err;
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

test "accepted workspace text survives native edit teardown" {
    const allocator = std.testing.allocator;
    var state = State{ .allocator = allocator, .parent = null, .count = 2 };
    defer freeStateValues(&state);
    state.values[0] = try allocator.dupe(u8, "old workspace");
    state.values[1] = try allocator.dupe(u8, "old name");
    const first = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr,
        std.unicode.utf8ToUtf16LeStringLiteral("alpha").ptr,
        0,
        0,
        0,
        100,
        20,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.TestWindowCreationFailed;
    defer if (c.IsWindow(first) != 0) {
        _ = c.DestroyWindow(first);
    };
    const second = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr,
        std.unicode.utf8ToUtf16LeStringLiteral("Проекты über").ptr,
        0,
        0,
        0,
        100,
        20,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.TestWindowCreationFailed;
    defer if (c.IsWindow(second) != 0) {
        _ = c.DestroyWindow(second);
    };
    state.edits[0] = first;
    state.edits[1] = second;
    applyTextCommand(&state, .submit);
    try std.testing.expect(c.DestroyWindow(first) != 0);
    try std.testing.expect(c.DestroyWindow(second) != 0);
    var result = (try finishText(&state)) orelse return error.ExpectedAcceptedText;
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualStrings("alpha", result.values[0]);
    try std.testing.expectEqualStrings("Проекты über", result.values[1]);
    try std.testing.expectEqual(@as(usize, 0), state.count);
}

test "cancelled or closed workspace text has no accepted result" {
    for ([_]TextCommand{ .cancel, .close }) |command| {
        var state = State{
            .allocator = std.testing.allocator,
            .parent = null,
            .count = 1,
        };
        defer freeStateValues(&state);
        state.values[0] = try state.allocator.dupe(u8, "do-not-delete");
        applyTextCommand(&state, command);
        try std.testing.expect((try finishText(&state)) == null);
        try std.testing.expect(state.closed);
        try std.testing.expectEqual(@as(usize, 0), state.count);
    }
}

test "workspace text read failure never accepts stale values" {
    var state = State{
        .allocator = std.testing.allocator,
        .parent = null,
        .count = 1,
    };
    defer freeStateValues(&state);
    state.values[0] = try state.allocator.dupe(u8, "stale-name");
    applyTextCommand(&state, .submit);
    try std.testing.expect(!state.accepted);
    try std.testing.expect(state.closed);
    try std.testing.expectError(error.DialogReadFailed, finishText(&state));
    try std.testing.expectEqual(@as(usize, 0), state.count);
}

test "workspace text rejects reentrant presentation before creating any window" {
    const previous = active;
    active = true;
    defer active = previous;
    try std.testing.expectError(error.DialogAlreadyOpen, textWithDescription(
        null,
        std.testing.allocator,
        "New Workspace",
        "",
        &.{"Name"},
        &.{""},
    ));
}

test "workspace text capture and transfer release every partial allocation" {
    const edit = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr,
        std.unicode.utf8ToUtf16LeStringLiteral("new workspace").ptr,
        0,
        0,
        0,
        100,
        20,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.TestWindowCreationFailed;
    defer _ = c.DestroyWindow(edit);
    const Probe = struct {
        fn run(allocator: std.mem.Allocator, window: c.HWND) !void {
            var state = State{ .allocator = allocator, .parent = null, .count = 2 };
            defer freeStateValues(&state);
            state.values[0] = try allocator.dupe(u8, "old first");
            state.values[1] = try allocator.dupe(u8, "old second");
            state.edits[0] = window;
            state.edits[1] = window;
            applyTextCommand(&state, .submit);
            var result = (try finishText(&state)) orelse return error.ExpectedAcceptedText;
            defer result.deinit(allocator);
            try std.testing.expectEqualStrings("new workspace", result.values[0]);
            try std.testing.expectEqualStrings("new workspace", result.values[1]);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{edit});
}

test "text dialog opens with keyboard focus in its first field, text selected, and keeps it across activation" {
    // Dev Box beta17: Rename Loop opened with focus on the dialog frame, so typing did
    // nothing until the Title edit was clicked.
    const allocator = std.testing.allocator;
    const previous_active = active;
    active_state = State{ .allocator = allocator, .parent = null, .title = "Rename Loop", .count = 1, .description = "Shown on the loop card." };
    active_state.labels[0] = "Title";
    active_state.values[0] = try allocator.dupe(u8, "GCQCrud17");
    active = true;
    defer {
        deinitDialogHost();
        freeStateValues(&active_state);
        active = previous_active;
    }
    try registerClass();
    const wide_title = try wideZ(allocator, "Rename Loop");
    defer allocator.free(wide_title);
    const hwnd = createTextDialog(null, wide_title) orelse return error.TestWindowCreationFailed;
    const title_edit = active_state.edits[0] orelse return error.TestWindowCreationFailed;
    try std.testing.expectEqual(@as(isize, 9904), c.GetDlgCtrlID(title_edit));

    presentDialog(hwnd);
    try std.testing.expectEqual(title_edit, c.GetFocus());
    var start: c.DWORD = 0;
    var end: c.DWORD = 0;
    _ = c.SendMessageW(title_edit, c.EM_GETSEL, @intFromPtr(&start), @bitCast(@intFromPtr(&end)));
    try std.testing.expectEqual(@as(c.DWORD, 0), start);
    try std.testing.expectEqual(@as(c.DWORD, "GCQCrud17".len), end);

    // Activation hands focus to the frame (DefWindowProc's WM_ACTIVATE does exactly
    // that); the frame must pass it straight back to the field the user was in.
    _ = c.SendMessageW(hwnd, c.WM_ACTIVATE, c.WA_INACTIVE, 0);
    _ = c.SetFocus(hwnd);
    try std.testing.expectEqual(title_edit, c.GetFocus());
    _ = c.SendMessageW(hwnd, c.WM_ACTIVATE, c.WA_ACTIVE, 0);
    try std.testing.expectEqual(title_edit, c.GetFocus());
}

fn openProbeDialog(allocator: std.mem.Allocator, initial: []const u8) !c.HWND {
    active_state = State{ .allocator = allocator, .parent = null, .title = "Rename Loop", .count = 1 };
    active_state.labels[0] = "Title";
    active_state.values[0] = try allocator.dupe(u8, initial);
    active = true;
    try registerClass();
    const wide_title = try wideZ(allocator, "Rename Loop");
    defer allocator.free(wide_title);
    const hwnd = createTextDialog(null, wide_title) orelse return error.TestWindowCreationFailed;
    presentDialog(hwnd);
    return hwnd;
}

/// Delivers one key the way the modal loop does: through IsDialogMessageW to the
/// focused control, falling back to the ordinary translate/dispatch path.
fn pumpKey(hwnd: c.HWND, target: c.HWND, key: usize) void {
    var message = std.mem.zeroes(c.MSG);
    message.hwnd = target;
    message.message = c.WM_KEYDOWN;
    message.wParam = key;
    if (c.IsDialogMessageW(hwnd, &message) != 0) return;
    _ = c.TranslateMessage(&message);
    _ = c.DispatchMessageW(&message);
}

fn typeInto(edit: c.HWND, text_utf8: []const u8) !void {
    const wide = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, text_utf8);
    defer std.testing.allocator.free(wide);
    _ = c.SendMessageW(edit, c.EM_SETSEL, 0, -1);
    for (wide) |unit| _ = c.SendMessageW(edit, c.WM_CHAR, unit, 0);
}

test "Enter in a focused single-line field submits the dialog with the typed text" {
    // Dev Box beta18: Enter in Rename Loop's Title field did nothing, so the dialog
    // could only be accepted by clicking OK.
    const allocator = std.testing.allocator;
    const previous_active = active;
    defer active = previous_active;
    const hwnd = try openProbeDialog(allocator, "GCQCrud17");
    defer {
        deinitDialogHost();
        freeStateValues(&active_state);
    }
    const edit = active_state.edits[0] orelse return error.TestWindowCreationFailed;
    try std.testing.expectEqual(edit, c.GetFocus());
    try typeInto(edit, "Renamed loop");

    pumpKey(hwnd, edit, c.VK_RETURN);

    try std.testing.expect(active_state.closed);
    try std.testing.expect(active_state.accepted);
    var result = (try finishText(&active_state)) orelse return error.ExpectedAcceptedText;
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqualStrings("Renamed loop", result.values[0]);
}

test "Escape in a focused field cancels the dialog without a result" {
    const allocator = std.testing.allocator;
    const previous_active = active;
    defer active = previous_active;
    const hwnd = try openProbeDialog(allocator, "keep me");
    defer {
        deinitDialogHost();
        freeStateValues(&active_state);
    }
    const edit = active_state.edits[0] orelse return error.TestWindowCreationFailed;
    try typeInto(edit, "discarded");

    pumpKey(hwnd, edit, c.VK_ESCAPE);

    try std.testing.expect(active_state.closed);
    try std.testing.expect(!active_state.accepted);
    try std.testing.expect((try finishText(&active_state)) == null);
}

test "Enter on the Cancel button cancels rather than submitting" {
    const allocator = std.testing.allocator;
    const previous_active = active;
    defer active = previous_active;
    const hwnd = try openProbeDialog(allocator, "keep me");
    defer {
        deinitDialogHost();
        freeStateValues(&active_state);
    }
    const cancel = c.GetDlgItem(hwnd, cancel_id) orelse return error.TestWindowCreationFailed;
    _ = c.SetFocus(cancel);

    pumpKey(hwnd, cancel, c.VK_RETURN);

    try std.testing.expect(active_state.closed);
    try std.testing.expect(!active_state.accepted);
}

test "dialog exposes OK as its single default button" {
    const allocator = std.testing.allocator;
    const previous_active = active;
    defer active = previous_active;
    const hwnd = try openProbeDialog(allocator, "x");
    defer {
        deinitDialogHost();
        freeStateValues(&active_state);
    }
    const reply: usize = @bitCast(c.SendMessageW(hwnd, c.DM_GETDEFID, 0, 0));
    try std.testing.expectEqual(@as(usize, c.DC_HASDEFID), reply >> 16);
    try std.testing.expectEqual(@as(usize, ok_id), reply & 0xffff);
    const ok = c.GetDlgItem(hwnd, ok_id) orelse return error.TestWindowCreationFailed;
    const cancel = c.GetDlgItem(hwnd, cancel_id) orelse return error.TestWindowCreationFailed;
    try std.testing.expect(@as(usize, @bitCast(c.GetWindowLongPtrW(ok, c.GWL_STYLE))) & c.BS_OWNERDRAW != 0);
    try std.testing.expect(@as(usize, @bitCast(c.GetWindowLongPtrW(cancel, c.GWL_STYLE))) & c.BS_OWNERDRAW != 0);
    try std.testing.expect(active_state.primary_action.is_default);
    try std.testing.expect(!active_state.cancel_action.is_default);
}
