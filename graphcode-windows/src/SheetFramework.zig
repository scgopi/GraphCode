const std = @import("std");
const Win32 = @import("Win32.zig");
const c = Win32.c;
const AppFont = @import("AppFont.zig");
const Dpi = @import("Dpi.zig");
const Tokens = @import("DesignTokens.zig");

const dialog_focus_tint: u32 = 0x005A4024;
const dialog_primary_button: u32 = Tokens.pane_focus_tint;
const dialog_primary_button_pressed: u32 = 0x00D16A08;
const dialog_secondary_button: u32 = 0x00413B3B;
const dialog_secondary_button_pressed: u32 = 0x004B4545;
const dialog_disabled_button: u32 = 0x00342F2F;
const dialog_scrollbar_thumb: u32 = 0x00645D5D;

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub fn right(self: Rect) i32 {
        return self.x + self.width;
    }

    pub fn bottom(self: Rect) i32 {
        return self.y + self.height;
    }

    pub fn toNative(self: Rect) c.RECT {
        return .{ .left = self.x, .top = self.y, .right = self.right(), .bottom = self.bottom() };
    }
};

pub const Metrics = struct {
    outer_margin: i32,
    content_inset: i32,
    footer_inset: i32,
    footer_gap: i32,
    footer_height: i32,
    button_height: i32,
    button_min_width: i32,
    button_text_padding: i32,
    return_hint_width: i32,
    panel_radius: i32,
    field_radius: i32,
    button_radius: i32,
    focus_ring_width: i32,
    focus_tint_width: i32,
    scrollbar_width: i32,
    scrollbar_min_thumb: i32,

    pub fn forDpi(dpi_value: u32) Metrics {
        const dpi = Dpi.normalize(dpi_value);
        return .{
            .outer_margin = Dpi.scale(18, dpi),
            .content_inset = Dpi.scale(22, dpi),
            .footer_inset = Dpi.scale(18, dpi),
            .footer_gap = Dpi.scale(10, dpi),
            .footer_height = Dpi.scale(64, dpi),
            .button_height = Dpi.scale(34, dpi),
            .button_min_width = Dpi.scale(84, dpi),
            .button_text_padding = Dpi.scale(18, dpi),
            .return_hint_width = Dpi.scale(22, dpi),
            .panel_radius = Dpi.scale(18, dpi),
            .field_radius = Dpi.scale(8, dpi),
            .button_radius = Dpi.scale(9, dpi),
            .focus_ring_width = @max(1, Dpi.scale(2, dpi)),
            .focus_tint_width = @max(1, Dpi.scale(3, dpi)),
            .scrollbar_width = Dpi.scale(10, dpi),
            .scrollbar_min_thumb = Dpi.scale(28, dpi),
        };
    }
};

pub const HeightRange = struct {
    minimum: i32,
    ideal: i32,
    maximum: i32,
};

pub const LayoutInput = struct {
    owner: Rect,
    dpi: u32 = Dpi.base_dpi,
    desired_width: i32,
    minimum_width: i32,
    /// Native-pixel constraints derived from measured footer controls.
    footer_minimum_width: i32 = 0,
    footer_minimum_height: i32 = 0,
    heights: HeightRange,
    content_extent: i32,
    footer_height: ?i32 = null,
    initial_offset: i32 = 0,
};

pub const ScrollModel = struct {
    extent: i32,
    page: i32,
    max_offset: i32,
    offset: i32,
    visible: bool,

    pub fn init(extent_value: i32, page_value: i32, requested_offset: i32) ScrollModel {
        const extent = @max(0, extent_value);
        const page = @max(0, page_value);
        const maximum = if (extent > page) extent - page else 0;
        return .{
            .extent = extent,
            .page = page,
            .max_offset = maximum,
            .offset = std.math.clamp(requested_offset, 0, maximum),
            .visible = extent > page,
        };
    }

    pub fn withOffset(self: ScrollModel, requested_offset: i32) ScrollModel {
        return init(self.extent, self.page, requested_offset);
    }

    pub fn reveal(self: ScrollModel, item_top: i32, item_bottom: i32) ScrollModel {
        var next = self.offset;
        if (item_top < next) next = item_top else if (item_bottom > next + self.page) next = item_bottom - self.page;
        return self.withOffset(next);
    }
};

pub const Layout = struct {
    sheet: Rect,
    viewport: Rect,
    footer: Rect,
    scroll: ScrollModel,
};

pub fn layout(input: LayoutInput) Layout {
    const metrics = Metrics.forDpi(input.dpi);
    const available_width = @max(0, input.owner.width - metrics.outer_margin * 2);
    const available_height = @max(0, input.owner.height - metrics.outer_margin * 2);
    const minimum_width = @min(
        @max(@max(0, Dpi.scale(input.minimum_width, input.dpi)), input.footer_minimum_width),
        available_width,
    );
    const desired_width = @max(Dpi.scale(input.desired_width, input.dpi), input.footer_minimum_width);
    const width = std.math.clamp(desired_width, minimum_width, available_width);

    const configured_footer = input.footer_height orelse Dpi.unscale(metrics.footer_height, input.dpi);
    const configured_footer_height = @max(0, Dpi.scale(configured_footer, input.dpi));
    const footer_target = @max(configured_footer_height, input.footer_minimum_height);
    const content_extent = @max(0, Dpi.scale(input.content_extent, input.dpi));
    const minimum_height = @min(@max(0, Dpi.scale(input.heights.minimum, input.dpi)), available_height);
    const maximum_height = @min(@max(minimum_height, Dpi.scale(input.heights.maximum, input.dpi)), available_height);
    const footer_growth = @max(0, footer_target - configured_footer_height);
    const ideal_height = std.math.clamp(
        Dpi.scale(input.heights.ideal, input.dpi) + footer_growth,
        minimum_height,
        maximum_height,
    );
    const natural_height = content_extent + footer_target;
    const height = std.math.clamp(@min(natural_height, ideal_height), minimum_height, maximum_height);
    const footer_height = @min(footer_target, height);
    const viewport_height = @max(0, height - footer_height);
    const x = input.owner.x + @divTrunc(input.owner.width - width, 2);
    const y = input.owner.y + @divTrunc(input.owner.height - height, 2);
    const scroll = ScrollModel.init(content_extent, viewport_height, Dpi.scale(input.initial_offset, input.dpi));
    return .{
        .sheet = .{ .x = x, .y = y, .width = width, .height = height },
        .viewport = .{ .x = 0, .y = 0, .width = width, .height = viewport_height },
        .footer = .{ .x = 0, .y = viewport_height, .width = width, .height = footer_height },
        .scroll = scroll,
    };
}

pub const ActionRole = enum {
    cancel,
    secondary,
    primary,
    destructive,

    pub fn isPrimary(self: ActionRole) bool {
        return self == .primary or self == .destructive;
    }
};

pub const FooterAction = struct {
    id: u16,
    role: ActionRole,
    measured_text_width: i32,
    return_hint: bool = false,
    enabled: bool = true,
};

pub const FooterSlot = struct {
    id: u16,
    role: ActionRole,
    bounds: Rect,
    enabled: bool,
};

pub const max_footer_actions = 8;

pub const FooterLayout = struct {
    slots: [max_footer_actions]FooterSlot = undefined,
    count: usize = 0,
    validation: Rect,
    measured_minimum_width: i32,
    required_height: i32,
    row_count: usize,

    pub fn slice(self: *const FooterLayout) []const FooterSlot {
        return self.slots[0..self.count];
    }

    pub fn slotFor(self: *const FooterLayout, id: u16) ?FooterSlot {
        for (self.slice()) |slot| if (slot.id == id) return slot;
        return null;
    }
};

fn actionWidth(action: FooterAction, metrics: Metrics) i32 {
    const hint = if (action.return_hint and action.role.isPrimary()) metrics.return_hint_width else 0;
    return @max(metrics.button_min_width, action.measured_text_width + metrics.button_text_padding * 2 + hint);
}

fn footerMinimumWidth(actions: []const FooterAction, metrics: Metrics) i32 {
    var width = metrics.footer_inset * 2;
    for (actions) |action| width += actionWidth(action, metrics);
    const gaps = if (actions.len == 0) 0 else actions.len - 1;
    return width + @as(i32, @intCast(gaps)) * metrics.footer_gap;
}

const max_footer_label_units = 512;
const return_hint_text = std.unicode.utf8ToUtf16LeStringLiteral("\u{21b5}");

pub const FooterContentLayout = struct {
    label: Rect,
    return_hint: ?Rect,
};

pub fn footerContentLayout(bounds: Rect, dpi: u32, action: FooterAction) FooterContentLayout {
    const hint_width = if (action.return_hint and action.role.isPrimary())
        @min(bounds.width, Metrics.forDpi(dpi).return_hint_width)
    else
        0;
    return .{
        .label = .{
            .x = bounds.x,
            .y = bounds.y,
            .width = @max(0, bounds.width - hint_width),
            .height = bounds.height,
        },
        .return_hint = if (hint_width == 0) null else .{
            .x = bounds.right() - hint_width,
            .y = bounds.y,
            .width = hint_width,
            .height = bounds.height,
        },
    };
}

fn footerWindowText(hwnd: c.HWND, buffer: *[max_footer_label_units]u16) ![]const u16 {
    const length = c.GetWindowTextLengthW(hwnd);
    if (length < 0 or @as(usize, @intCast(length)) >= buffer.len) return error.SheetFooterLabelTooLong;
    const copied = c.GetWindowTextW(hwnd, buffer, @intCast(buffer.len));
    if (copied != length) return error.SheetFooterLabelReadFailed;
    return buffer[0..@intCast(copied)];
}

pub fn measureFooterActionLabel(hwnd: c.HWND, dpi: u32) !i32 {
    if (hwnd == null or c.IsWindow(hwnd) == 0) return error.SheetFooterButtonUnavailable;
    var buffer: [max_footer_label_units]u16 = undefined;
    const text = try footerWindowText(hwnd, &buffer);
    const dc = c.CreateCompatibleDC(null) orelse return error.SheetFooterTextMeasurementFailed;
    defer _ = c.DeleteDC(dc);
    const font = AppFont.getForDpi(AppFont.control_size, true, dpi) orelse return error.SheetFooterFontCreationFailed;
    const previous = c.SelectObject(dc, font);
    defer _ = c.SelectObject(dc, previous);
    var size: c.SIZE = undefined;
    if (c.GetTextExtentPoint32W(dc, text.ptr, @intCast(text.len), &size) == 0)
        return error.SheetFooterTextMeasurementFailed;
    return size.cx;
}

pub fn measureFooter(width_value: i32, height_value: i32, dpi: u32, actions: []const FooterAction) !FooterLayout {
    if (actions.len > max_footer_actions) return error.TooManyFooterActions;
    const metrics = Metrics.forDpi(dpi);
    const width = @max(0, width_value);
    var widths = [_]i32{0} ** max_footer_actions;
    var rows = [_]usize{0} ** max_footer_actions;
    var widest: i32 = 0;
    for (actions, 0..) |action, index| {
        widths[index] = actionWidth(action, metrics);
        widest = @max(widest, widths[index]);
    }
    if (actions.len != 0 and widest > width) return error.SheetFooterActionTooWide;
    const horizontal_inset = @min(metrics.footer_inset, @divTrunc(@max(0, width - widest), 2));
    const usable_width = @max(0, width - horizontal_inset * 2);
    var row_count: usize = 1;
    var used_width: i32 = 0;
    for (actions, 0..) |_, index| {
        const next_width = if (used_width == 0)
            widths[index]
        else
            used_width + metrics.footer_gap + widths[index];
        if (used_width != 0 and next_width > usable_width) {
            row_count += 1;
            used_width = widths[index];
        } else {
            used_width = next_width;
        }
        rows[index] = row_count - 1;
    }
    const row_gap_height = @as(i32, @intCast(row_count - 1)) * metrics.footer_gap;
    const rows_height = @as(i32, @intCast(row_count)) * metrics.button_height + row_gap_height;
    const vertical_inset = @max(0, @divTrunc(metrics.footer_height - metrics.button_height, 2));
    const required_height = @max(metrics.footer_height, rows_height + vertical_inset * 2);
    const height = @max(@max(0, height_value), required_height);
    const first_row_y = @max(0, @divTrunc(height - rows_height, 2));
    var result = FooterLayout{
        .validation = .{ .x = horizontal_inset, .y = 0, .width = 0, .height = height },
        .measured_minimum_width = footerMinimumWidth(actions, metrics),
        .required_height = required_height,
        .row_count = row_count,
    };
    var best_validation_width: i32 = -1;
    for (0..row_count) |row| {
        var left = horizontal_inset;
        var right = width - horizontal_inset;
        var right_count: usize = 0;
        var reverse = actions.len;
        while (reverse > 0) {
            reverse -= 1;
            const action = actions[reverse];
            if (rows[reverse] != row or !action.role.isPrimary()) continue;
            if (right_count != 0) right -= metrics.footer_gap;
            right -= widths[reverse];
            result.slots[reverse] = .{
                .id = action.id,
                .role = action.role,
                .bounds = .{
                    .x = right,
                    .y = first_row_y + @as(i32, @intCast(row)) * (metrics.button_height + metrics.footer_gap),
                    .width = widths[reverse],
                    .height = metrics.button_height,
                },
                .enabled = action.enabled,
            };
            right_count += 1;
        }
        var left_count: usize = 0;
        for (actions, 0..) |action, index| {
            if (rows[index] != row or action.role.isPrimary()) continue;
            if (left_count != 0) left += metrics.footer_gap;
            result.slots[index] = .{
                .id = action.id,
                .role = action.role,
                .bounds = .{
                    .x = left,
                    .y = first_row_y + @as(i32, @intCast(row)) * (metrics.button_height + metrics.footer_gap),
                    .width = widths[index],
                    .height = metrics.button_height,
                },
                .enabled = action.enabled,
            };
            left += widths[index];
            left_count += 1;
        }
        const validation_width = @max(0, right - left);
        if (validation_width > best_validation_width) {
            best_validation_width = validation_width;
            result.validation = .{
                .x = left,
                .y = if (row_count == 1) 0 else first_row_y + @as(i32, @intCast(row)) * (metrics.button_height + metrics.footer_gap),
                .width = validation_width,
                .height = if (row_count == 1) height else metrics.button_height,
            };
        }
    }
    result.count = actions.len;
    return result;
}

pub const FieldGeometry = struct {
    fill: Rect,
    border: Rect,
    focus_ring: Rect,
    focus_tint: Rect,
    radius: i32,
};

fn insetRect(bounds: Rect, amount: i32) Rect {
    const inset = @max(0, amount);
    return .{
        .x = bounds.x + inset,
        .y = bounds.y + inset,
        .width = @max(0, bounds.width - inset * 2),
        .height = @max(0, bounds.height - inset * 2),
    };
}

pub fn fieldGeometry(bounds: Rect, dpi: u32) FieldGeometry {
    const metrics = Metrics.forDpi(dpi);
    return .{
        .fill = insetRect(bounds, metrics.focus_tint_width + metrics.focus_ring_width),
        .border = insetRect(bounds, metrics.focus_tint_width + metrics.focus_ring_width),
        .focus_ring = insetRect(bounds, metrics.focus_tint_width),
        .focus_tint = bounds,
        .radius = metrics.field_radius,
    };
}

pub const ScrollbarGeometry = struct {
    track: Rect,
    thumb: Rect,
};

pub fn scrollbarGeometry(viewport: Rect, scroll: ScrollModel, dpi: u32) ScrollbarGeometry {
    const metrics = Metrics.forDpi(dpi);
    const track = Rect{
        .x = @max(viewport.x, viewport.right() - metrics.scrollbar_width),
        .y = viewport.y,
        .width = @min(metrics.scrollbar_width, viewport.width),
        .height = viewport.height,
    };
    if (!scroll.visible or track.height <= 0) return .{ .track = track, .thumb = .{ .x = track.x, .y = track.y, .width = track.width, .height = track.height } };
    const proportional = @divTrunc(@as(i64, track.height) * scroll.page, @max(1, scroll.extent));
    const thumb_height = @min(track.height, @max(metrics.scrollbar_min_thumb, @as(i32, @intCast(proportional))));
    const travel = @max(0, track.height - thumb_height);
    const thumb_y = track.y + if (scroll.max_offset == 0) 0 else @as(i32, @intCast(@divTrunc(@as(i64, travel) * scroll.offset, scroll.max_offset)));
    return .{
        .track = track,
        .thumb = .{ .x = track.x, .y = thumb_y, .width = track.width, .height = thumb_height },
    };
}

pub const ControlKind = enum { panel, static, edit, button };

pub const PaintStyle = struct {
    background: u32,
    foreground: u32,
    is_opaque: bool,
};

fn handleResult(handle: anytype) c.LRESULT {
    return @bitCast(@intFromPtr(handle));
}

pub fn controlPaintStyle(kind: ControlKind, enabled: bool) PaintStyle {
    return switch (kind) {
        .panel => .{ .background = Tokens.dialog_panel, .foreground = Tokens.dialog_body_text, .is_opaque = true },
        .static => .{ .background = Tokens.dialog_panel, .foreground = Tokens.dialog_body_text, .is_opaque = true },
        .edit => .{ .background = Tokens.dialog_field_background, .foreground = if (enabled) Tokens.dialog_title_text else Tokens.dialog_muted_text, .is_opaque = true },
        .button => .{ .background = dialog_secondary_button, .foreground = if (enabled) Tokens.dialog_title_text else Tokens.dialog_muted_text, .is_opaque = true },
    };
}

pub const Brushes = struct {
    panel: c.HBRUSH = null,
    field: c.HBRUSH = null,
    button: c.HBRUSH = null,

    pub fn init() !Brushes {
        var brushes = Brushes{
            .panel = c.CreateSolidBrush(Tokens.dialog_panel),
            .field = c.CreateSolidBrush(Tokens.dialog_field_background),
            .button = c.CreateSolidBrush(dialog_secondary_button),
        };
        errdefer brushes.deinit();
        if (brushes.panel == null or brushes.field == null or brushes.button == null) return error.SheetBrushCreationFailed;
        return brushes;
    }

    pub fn deinit(self: *Brushes) void {
        if (self.button != null) _ = c.DeleteObject(self.button);
        if (self.field != null) _ = c.DeleteObject(self.field);
        if (self.panel != null) _ = c.DeleteObject(self.panel);
        self.* = .{};
    }

    pub fn apply(self: *const Brushes, hdc: c.HDC, kind: ControlKind, enabled: bool) !c.LRESULT {
        if (hdc == null) return error.SheetDeviceContextUnavailable;
        const style = controlPaintStyle(kind, enabled);
        if (c.SetTextColor(hdc, style.foreground) == c.CLR_INVALID) return error.SheetTextColorFailed;
        if (c.SetBkColor(hdc, style.background) == c.CLR_INVALID) return error.SheetBackgroundColorFailed;
        if (c.SetBkMode(hdc, if (style.is_opaque) c.OPAQUE else c.TRANSPARENT) == 0) return error.SheetBackgroundModeFailed;
        const brush = switch (kind) {
            .edit => self.field,
            .button => self.button,
            else => self.panel,
        };
        if (brush == null) return error.SheetBrushUnavailable;
        return handleResult(brush);
    }
};

fn drawRoundedRect(hdc: c.HDC, bounds: Rect, radius: i32, fill_color: u32, border_color: u32, border_width: i32) !void {
    if (hdc == null or bounds.width <= 0 or bounds.height <= 0) return error.SheetPaintBoundsInvalid;
    const brush = c.CreateSolidBrush(fill_color) orelse return error.SheetPaintBrushCreationFailed;
    defer _ = c.DeleteObject(brush);
    const pen = c.CreatePen(c.PS_SOLID, @max(1, border_width), border_color) orelse return error.SheetPaintPenCreationFailed;
    defer _ = c.DeleteObject(pen);
    const previous_brush = c.SelectObject(hdc, brush);
    const previous_pen = c.SelectObject(hdc, pen);
    defer {
        _ = c.SelectObject(hdc, previous_pen);
        _ = c.SelectObject(hdc, previous_brush);
    }
    if (c.RoundRect(hdc, bounds.x, bounds.y, bounds.right(), bounds.bottom(), radius * 2, radius * 2) == 0)
        return error.SheetRoundedPaintFailed;
}

pub fn drawField(hdc: c.HDC, bounds: Rect, dpi: u32, focused: bool) !void {
    const geometry = fieldGeometry(bounds, dpi);
    const metrics = Metrics.forDpi(dpi);
    if (focused) {
        try drawRoundedRect(hdc, geometry.focus_tint, geometry.radius + metrics.focus_tint_width, Tokens.dialog_panel, dialog_focus_tint, metrics.focus_tint_width);
        try drawRoundedRect(hdc, geometry.focus_ring, geometry.radius + metrics.focus_ring_width, Tokens.dialog_panel, Tokens.pane_focus_tint, metrics.focus_ring_width);
    }
    try drawRoundedRect(hdc, geometry.border, geometry.radius, Tokens.dialog_field_background, Tokens.dialog_field_border, 1);
}

fn buttonFillColor(role: ActionRole, enabled: bool, pressed: bool) u32 {
    return if (!enabled)
        dialog_disabled_button
    else if (role.isPrimary())
        (if (pressed) dialog_primary_button_pressed else dialog_primary_button)
    else
        (if (pressed) dialog_secondary_button_pressed else dialog_secondary_button);
}

pub fn drawButton(hdc: c.HDC, bounds: Rect, dpi: u32, role: ActionRole, enabled: bool, pressed: bool) !void {
    const metrics = Metrics.forDpi(dpi);
    const fill_color = buttonFillColor(role, enabled, pressed);
    const border = if (role.isPrimary()) fill_color else Tokens.dialog_field_border;
    try drawRoundedRect(hdc, bounds, metrics.button_radius, fill_color, border, 1);
}

pub fn drawFooterAction(item: *const c.DRAWITEMSTRUCT, dpi: u32, action: FooterAction) !void {
    const bounds = Rect{
        .x = item.rcItem.left,
        .y = item.rcItem.top,
        .width = item.rcItem.right - item.rcItem.left,
        .height = item.rcItem.bottom - item.rcItem.top,
    };
    const enabled = item.itemState & c.ODS_DISABLED == 0;
    try drawButton(item.hDC, bounds, dpi, action.role, enabled, item.itemState & c.ODS_SELECTED != 0);

    var buffer: [max_footer_label_units]u16 = undefined;
    const text = try footerWindowText(item.hwndItem, &buffer);
    const font = AppFont.getForDpi(AppFont.control_size, true, dpi) orelse return error.SheetFooterFontCreationFailed;
    const previous = c.SelectObject(item.hDC, font);
    defer _ = c.SelectObject(item.hDC, previous);
    if (c.SetBkMode(item.hDC, c.TRANSPARENT) == 0) return error.SheetFooterBackgroundModeFailed;
    if (c.SetTextColor(item.hDC, if (enabled) Tokens.dialog_title_text else Tokens.dialog_muted_text) == c.CLR_INVALID)
        return error.SheetFooterTextColorFailed;

    const content = footerContentLayout(bounds, dpi, action);
    var label_bounds = content.label.toNative();
    if (c.DrawTextW(
        item.hDC,
        text.ptr,
        @intCast(text.len),
        &label_bounds,
        c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_END_ELLIPSIS,
    ) == 0) return error.SheetFooterTextPaintFailed;
    if (content.return_hint) |hint| {
        var hint_bounds = hint.toNative();
        if (c.DrawTextW(
            item.hDC,
            return_hint_text.ptr,
            1,
            &hint_bounds,
            c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE,
        ) == 0) return error.SheetFooterHintPaintFailed;
    }
    if (item.itemState & c.ODS_FOCUS != 0) {
        var focus = item.rcItem;
        const inset = Metrics.forDpi(dpi).focus_ring_width + 1;
        _ = c.InflateRect(&focus, -inset, -inset);
        _ = c.DrawFocusRect(item.hDC, &focus);
    }
}

pub const HostStyle = struct {
    style: u32 = c.WS_POPUP | c.WS_CLIPCHILDREN,
    extended_style: u32 = c.WS_EX_CONTROLPARENT,
    scrim_style: u32 = c.WS_POPUP,
    scrim_extended_style: u32 = c.WS_EX_LAYERED | c.WS_EX_NOACTIVATE | c.WS_EX_TOOLWINDOW,
};

pub const host_style = HostStyle{};
pub const scrim_alpha: u8 = 102;

pub const LayoutCallback = *const fn (context: ?*anyopaque, layout_value: Layout) anyerror!void;
pub const MessageCallback = *const fn (context: ?*anyopaque, hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM, result: *c.LRESULT) bool;

pub const HostOptions = struct {
    layout_input: LayoutInput,
    context: ?*anyopaque = null,
    on_layout: ?LayoutCallback = null,
    on_message: ?MessageCallback = null,
};

pub const Host = struct {
    owner: c.HWND = null,
    hwnd: c.HWND = null,
    scrim: c.HWND = null,
    viewport: c.HWND = null,
    options: HostOptions = undefined,
    current_layout: Layout = undefined,
    brushes: Brushes = .{},
    failure: ?anyerror = null,
    previous_focus: c.HWND = null,
    owner_disabled: bool = false,
    dragging_thumb: bool = false,
    drag_origin_y: i32 = 0,
    drag_origin_offset: i32 = 0,
    footer_actions: [max_footer_actions]FooterAction = undefined,
    footer_action_count: usize = 0,
    footer_layout: ?FooterLayout = null,
    closed: bool = false,

    pub fn init(self: *Host, owner: c.HWND, options: HostOptions) !void {
        if (owner == null or c.IsWindow(owner) == 0) return error.SheetOwnerInvalid;
        self.* = .{ .owner = owner, .options = options, .previous_focus = c.GetFocus() };
        self.options.layout_input.owner = try ownerClientRect(owner);
        self.options.layout_input.dpi = Dpi.normalize(if (options.layout_input.dpi == 0) Win32.dpiForWindow(owner) else options.layout_input.dpi);
        self.current_layout = layout(self.options.layout_input);
        if (self.current_layout.sheet.width <= 0 or self.current_layout.sheet.height <= 0) return error.SheetOwnerTooSmall;
        self.brushes = try Brushes.init();
        errdefer self.brushes.deinit();
        try registerClasses();
        self.scrim = try createScrim(owner, self);
        errdefer releaseOwnedWindow(&self.scrim);
        self.hwnd = c.CreateWindowExW(
            host_style.extended_style,
            host_class.ptr,
            std.unicode.utf8ToUtf16LeStringLiteral("GraphCode sheet").ptr,
            host_style.style,
            self.current_layout.sheet.x,
            self.current_layout.sheet.y,
            self.current_layout.sheet.width,
            self.current_layout.sheet.height,
            owner,
            null,
            c.GetModuleHandleW(null),
            self,
        ) orelse return self.failure orelse error.SheetHostCreationFailed;
        if (self.failure) |failure| {
            releaseOwnedWindow(&self.hwnd);
            return failure;
        }
    }

    pub fn deinit(self: *Host) void {
        self.restoreOwner();
        releaseOwnedWindow(&self.hwnd);
        releaseOwnedWindow(&self.scrim);
        self.brushes.deinit();
        self.viewport = null;
    }

    pub fn show(self: *Host) !void {
        if (self.hwnd == null or self.scrim == null) return error.SheetHostUnavailable;
        _ = c.EnableWindow(self.owner, 0);
        self.owner_disabled = true;
        _ = c.ShowWindow(self.scrim, c.SW_SHOWNOACTIVATE);
        _ = c.ShowWindow(self.hwnd, c.SW_SHOW);
        _ = c.SetForegroundWindow(self.hwnd);
    }

    pub fn runModal(self: *Host) !void {
        try self.show();
        defer self.restoreOwner();
        var message: c.MSG = undefined;
        var quit_code: ?c.WPARAM = null;
        while (!self.closed and self.hwnd != null and c.IsWindow(self.hwnd) != 0) {
            const code = c.GetMessageW(&message, null, 0, 0);
            if (code == 0) {
                quit_code = message.wParam;
                break;
            }
            if (code < 0) return error.SheetMessageLoopFailed;
            if (c.IsDialogMessageW(self.hwnd, &message) != 0) continue;
            _ = c.TranslateMessage(&message);
            _ = c.DispatchMessageW(&message);
            if (self.failure) |failure| return failure;
        }
        if (quit_code) |value| c.PostQuitMessage(@intCast(value));
        if (self.failure) |failure| return failure;
    }

    pub fn requestClose(self: *Host) void {
        self.closed = true;
        if (self.hwnd != null) _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
        if (self.scrim != null) _ = c.ShowWindow(self.scrim, c.SW_HIDE);
    }

    pub fn configureFooter(self: *Host, actions: []const FooterAction) !void {
        if (actions.len > max_footer_actions) return error.TooManyFooterActions;
        @memcpy(self.footer_actions[0..actions.len], actions);
        self.footer_action_count = actions.len;
        if (self.hwnd != null and self.viewport != null) {
            for (actions) |action| {
                const button = c.GetDlgItem(self.hwnd, action.id);
                if (button != null) _ = c.EnableWindow(button, @intFromBool(action.enabled));
            }
            try self.refreshOwnerGeometry();
        }
    }

    pub fn createFooterButton(self: *Host, id: u16, label: [*:0]const u16) !c.HWND {
        if (self.hwnd == null) return error.SheetHostUnavailable;
        const action = self.footerAction(id) orelse return error.SheetFooterActionMissing;
        const button = c.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("BUTTON").ptr,
            label,
            c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_OWNERDRAW,
            0,
            0,
            0,
            0,
            self.hwnd,
            Win32.opaquePointerFromInt(c.HMENU, id),
            c.GetModuleHandleW(null),
            null,
        ) orelse return error.SheetFooterButtonCreationFailed;
        _ = c.EnableWindow(button, @intFromBool(action.enabled));
        try self.refreshOwnerGeometry();
        return button;
    }

    pub fn createEdit(self: *Host, id: u16, multiline: bool) !c.HWND {
        if (self.viewport == null) return error.SheetViewportUnavailable;
        const style: c.DWORD = @bitCast(c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP |
            (if (multiline) c.ES_MULTILINE | c.ES_AUTOVSCROLL else c.ES_AUTOHSCROLL));
        return c.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr,
            null,
            style,
            0,
            0,
            0,
            0,
            self.viewport,
            Win32.opaquePointerFromInt(c.HMENU, id),
            c.GetModuleHandleW(null),
            null,
        ) orelse error.SheetEditCreationFailed;
    }

    pub fn createComboBox(self: *Host, id: u16, editable: bool) !c.HWND {
        if (self.viewport == null) return error.SheetViewportUnavailable;
        const combo_style: c.DWORD = @bitCast(if (editable) c.CBS_DROPDOWN else c.CBS_DROPDOWNLIST);
        return c.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("COMBOBOX").ptr,
            null,
            @as(c.DWORD, @bitCast(c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.WS_VSCROLL)) | combo_style,
            0,
            0,
            0,
            0,
            self.viewport,
            Win32.opaquePointerFromInt(c.HMENU, id),
            c.GetModuleHandleW(null),
            null,
        ) orelse error.SheetComboBoxCreationFailed;
    }

    pub fn restoreOwner(self: *Host) void {
        if (self.owner_disabled and self.owner != null and c.IsWindow(self.owner) != 0) {
            _ = c.EnableWindow(self.owner, 1);
            self.owner_disabled = false;
            _ = c.SetForegroundWindow(self.owner);
            if (self.previous_focus != null and c.IsWindow(self.previous_focus) != 0) _ = c.SetFocus(self.previous_focus);
        }
    }

    pub fn refreshOwnerGeometry(self: *Host) !void {
        self.options.layout_input.owner = try ownerClientRect(self.owner);
        try self.syncFooterActions();
        self.options.layout_input.footer_minimum_width = footerMinimumWidth(
            self.footer_actions[0..self.footer_action_count],
            Metrics.forDpi(self.options.layout_input.dpi),
        );
        self.options.layout_input.footer_minimum_height = 0;
        const width_layout = layout(self.options.layout_input);
        const footer = try measureFooter(
            width_layout.footer.width,
            0,
            self.options.layout_input.dpi,
            self.footer_actions[0..self.footer_action_count],
        );
        self.options.layout_input.footer_minimum_height = footer.required_height;
        self.current_layout = layout(self.options.layout_input);
        if (self.footer_action_count != 0 and self.current_layout.footer.height < footer.required_height)
            return error.SheetOwnerTooSmall;
        const bounds = self.current_layout.sheet;
        if (c.SetWindowPos(self.hwnd, null, bounds.x, bounds.y, bounds.width, bounds.height, c.SWP_NOZORDER | c.SWP_NOACTIVATE) == 0)
            return error.SheetHostMoveFailed;
        try positionScrim(self.scrim, self.owner);
        try self.relayout();
    }

    pub fn refreshForDpi(self: *Host, dpi: u32) !void {
        self.options.layout_input.dpi = Dpi.normalize(dpi);
        try self.refreshOwnerGeometry();
    }

    pub fn setContentExtent(self: *Host, extent_design_units: i32) !void {
        self.options.layout_input.content_extent = extent_design_units;
        self.options.layout_input.initial_offset = Dpi.unscale(self.current_layout.scroll.offset, self.options.layout_input.dpi);
        self.current_layout = layout(self.options.layout_input);
        try self.relayout();
    }

    pub fn setScrollOffset(self: *Host, offset: i32) !void {
        self.current_layout.scroll = self.current_layout.scroll.withOffset(offset);
        self.options.layout_input.initial_offset = Dpi.unscale(self.current_layout.scroll.offset, self.options.layout_input.dpi);
        try self.notifyLayout();
        if (c.InvalidateRect(self.viewport, null, 1) == 0) return error.SheetViewportInvalidateFailed;
    }

    pub fn reveal(self: *Host, item_top: i32, item_bottom: i32) !void {
        const next = self.current_layout.scroll.reveal(item_top, item_bottom);
        if (next.offset != self.current_layout.scroll.offset) try self.setScrollOffset(next.offset);
    }

    pub fn relayout(self: *Host) !void {
        if (self.hwnd == null or self.viewport == null) return error.SheetHostUnavailable;
        var client: c.RECT = undefined;
        if (c.GetClientRect(self.hwnd, &client) == 0) return error.SheetClientBoundsUnavailable;
        const height = client.bottom - client.top;
        const footer_height = @min(self.current_layout.footer.height, height);
        self.current_layout.viewport = .{ .x = 0, .y = 0, .width = client.right, .height = @max(0, height - footer_height) };
        self.current_layout.footer = .{ .x = 0, .y = self.current_layout.viewport.height, .width = client.right, .height = footer_height };
        self.current_layout.scroll = ScrollModel.init(
            Dpi.scale(self.options.layout_input.content_extent, self.options.layout_input.dpi),
            self.current_layout.viewport.height,
            self.current_layout.scroll.offset,
        );
        try applyRoundedRegion(self.hwnd, client.right, height, self.options.layout_input.dpi);
        const viewport = self.current_layout.viewport;
        if (c.MoveWindow(self.viewport, viewport.x, viewport.y, viewport.width, viewport.height, 1) == 0)
            return error.SheetViewportMoveFailed;
        try self.layoutFooter();
        try self.notifyLayout();
        if (c.InvalidateRect(self.hwnd, null, 1) == 0) return error.SheetHostInvalidateFailed;
    }

    fn notifyLayout(self: *Host) !void {
        if (self.options.on_layout) |callback| try callback(self.options.context, self.current_layout);
    }

    fn footerAction(self: *const Host, id: u16) ?FooterAction {
        for (self.footer_actions[0..self.footer_action_count]) |action| {
            if (action.id == id) return action;
        }
        return null;
    }

    fn dialogManagerCancelAction(self: *const Host, wparam: c.WPARAM, lparam: c.LPARAM) ?u16 {
        if (wparam != c.IDCANCEL or lparam != 0) return null;
        for (self.footer_actions[0..self.footer_action_count]) |action| {
            if (action.role == .cancel and action.id != c.IDCANCEL) return action.id;
        }
        return null;
    }

    fn syncFooterActions(self: *Host) !void {
        for (self.footer_actions[0..self.footer_action_count]) |*action| {
            const button = c.GetDlgItem(self.hwnd, action.id);
            if (button == null) continue;
            const font = AppFont.getForDpi(AppFont.control_size, true, self.options.layout_input.dpi) orelse
                return error.SheetFooterFontCreationFailed;
            _ = c.SendMessageW(button, c.WM_SETFONT, @intFromPtr(font), 0);
            action.measured_text_width = try measureFooterActionLabel(button, self.options.layout_input.dpi);
            action.enabled = c.IsWindowEnabled(button) != 0;
        }
    }

    fn layoutFooter(self: *Host) !void {
        try self.syncFooterActions();
        const footer = try measureFooter(
            self.current_layout.footer.width,
            self.current_layout.footer.height,
            self.options.layout_input.dpi,
            self.footer_actions[0..self.footer_action_count],
        );
        if (self.footer_action_count != 0 and footer.required_height > self.current_layout.footer.height)
            return error.SheetOwnerTooSmall;
        self.footer_layout = footer;
        for (footer.slice()) |slot| {
            const button = c.GetDlgItem(self.hwnd, slot.id);
            if (button == null) continue;
            if (c.MoveWindow(
                button,
                slot.bounds.x,
                self.current_layout.footer.y + slot.bounds.y,
                slot.bounds.width,
                slot.bounds.height,
                1,
            ) == 0) return error.SheetFooterButtonMoveFailed;
        }
    }

    fn fail(self: *Host, failure: anyerror) void {
        if (self.failure == null) self.failure = failure;
    }
};

const host_class = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeSheetHost");
const scrim_class = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeSheetScrim");
const viewport_class = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeSheetViewport");

fn registerClasses() !void {
    const classes = [_]struct { name: [*:0]const u16, proc: c.WNDPROC }{
        .{ .name = host_class.ptr, .proc = @ptrCast(&hostProc) },
        .{ .name = scrim_class.ptr, .proc = @ptrCast(&scrimProc) },
        .{ .name = viewport_class.ptr, .proc = @ptrCast(&viewportProc) },
    };
    for (classes) |entry| {
        var window_class: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
        window_class.lpfnWndProc = entry.proc;
        window_class.hInstance = c.GetModuleHandleW(null);
        window_class.lpszClassName = entry.name;
        window_class.hCursor = c.LoadCursorW(null, Win32.resourceIdentifier(32512));
        if (c.RegisterClassW(&window_class) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
            return error.SheetClassRegistrationFailed;
    }
}

fn hostFrom(hwnd: c.HWND) ?*Host {
    const raw = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (raw == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(raw)));
}

fn attachHost(hwnd: c.HWND, lparam: c.LPARAM) ?*Host {
    const create = Win32.messagePointer(*const c.CREATESTRUCTW, lparam);
    const host: ?*Host = @ptrCast(@alignCast(create.lpCreateParams));
    if (host) |value| {
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(value)));
        return value;
    }
    return null;
}

fn hostProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    var host = hostFrom(hwnd);
    if (message == c.WM_NCCREATE) {
        host = attachHost(hwnd, lparam);
        if (host) |value| value.hwnd = hwnd;
    }
    const value = host orelse return c.DefWindowProcW(hwnd, message, wparam, lparam);
    if (message == c.WM_COMMAND) {
        if (value.dialogManagerCancelAction(wparam, lparam)) |command|
            return c.SendMessageW(hwnd, c.WM_COMMAND, command, 0);
    }
    if (value.options.on_message) |callback| {
        var result: c.LRESULT = 0;
        if (callback(value.options.context, hwnd, message, wparam, lparam, &result)) return result;
    }
    switch (message) {
        c.WM_CREATE => {
            value.viewport = c.CreateWindowExW(
                c.WS_EX_CONTROLPARENT,
                viewport_class.ptr,
                null,
                c.WS_CHILD | c.WS_VISIBLE | c.WS_CLIPCHILDREN | c.WS_CLIPSIBLINGS,
                0,
                0,
                0,
                0,
                hwnd,
                null,
                c.GetModuleHandleW(null),
                value,
            ) orelse {
                value.fail(error.SheetViewportCreationFailed);
                return -1;
            };
            value.relayout() catch |failure| {
                value.fail(failure);
                return -1;
            };
            return 0;
        },
        c.WM_SIZE => {
            value.relayout() catch |failure| value.fail(failure);
            return 0;
        },
        c.WM_DPICHANGED => {
            value.refreshForDpi(@truncate(wparam)) catch |failure| value.fail(failure);
            return 0;
        },
        c.WM_CTLCOLORSTATIC => return value.brushes.apply(Win32.opaquePointerFromInt(c.HDC, wparam), .static, true) catch |failure| {
            value.fail(failure);
            return 0;
        },
        c.WM_CTLCOLOREDIT, c.WM_CTLCOLORLISTBOX => return value.brushes.apply(Win32.opaquePointerFromInt(c.HDC, wparam), .edit, true) catch |failure| {
            value.fail(failure);
            return 0;
        },
        c.WM_CTLCOLORBTN => return value.brushes.apply(Win32.opaquePointerFromInt(c.HDC, wparam), .button, true) catch |failure| {
            value.fail(failure);
            return 0;
        },
        c.WM_DRAWITEM => {
            const item = Win32.messagePointer(*const c.DRAWITEMSTRUCT, lparam);
            const control_id = std.math.cast(u16, item.CtlID) orelse
                return c.DefWindowProcW(hwnd, message, wparam, lparam);
            const action = value.footerAction(control_id) orelse FooterAction{
                .id = control_id,
                .role = if (item.CtlID == c.IDOK) .primary else .secondary,
                .measured_text_width = 0,
            };
            drawFooterAction(item, value.options.layout_input.dpi, action) catch |failure| value.fail(failure);
            return 1;
        },
        c.WM_ERASEBKGND => {
            var client: c.RECT = undefined;
            if (c.GetClientRect(hwnd, &client) == 0 or c.FillRect(Win32.opaquePointerFromInt(c.HDC, wparam), &client, value.brushes.panel) == 0)
                value.fail(error.SheetBackgroundPaintFailed);
            return 1;
        },
        c.WM_PAINT => {
            var paint: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(hwnd, &paint);
            if (hdc == null) {
                value.fail(error.SheetPaintBeginFailed);
                return 0;
            }
            if (c.FillRect(hdc, &paint.rcPaint, value.brushes.panel) == 0) value.fail(error.SheetPanelPaintFailed);
            _ = c.EndPaint(hwnd, &paint);
            return 0;
        },
        c.WM_CLOSE => {
            value.requestClose();
            return 0;
        },
        c.WM_NCDESTROY => {
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            if (value.hwnd == hwnd) value.hwnd = null;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn viewportProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    var host = hostFrom(hwnd);
    if (message == c.WM_NCCREATE) host = attachHost(hwnd, lparam);
    const value = host orelse return c.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
            const step = Dpi.scale(44, value.options.layout_input.dpi);
            value.setScrollOffset(value.current_layout.scroll.offset - @divTrunc(@as(i32, delta) * step, c.WHEEL_DELTA)) catch |failure| value.fail(failure);
            return 0;
        },
        c.WM_VSCROLL => {
            const command: u16 = @truncate(wparam);
            const page = @max(1, value.current_layout.scroll.page);
            const line = Dpi.scale(32, value.options.layout_input.dpi);
            const requested = switch (command) {
                c.SB_LINEUP => value.current_layout.scroll.offset - line,
                c.SB_LINEDOWN => value.current_layout.scroll.offset + line,
                c.SB_PAGEUP => value.current_layout.scroll.offset - page,
                c.SB_PAGEDOWN => value.current_layout.scroll.offset + page,
                c.SB_TOP => 0,
                c.SB_BOTTOM => value.current_layout.scroll.max_offset,
                else => value.current_layout.scroll.offset,
            };
            value.setScrollOffset(requested) catch |failure| value.fail(failure);
            return 0;
        },
        c.WM_LBUTTONDOWN => {
            if (!value.current_layout.scroll.visible) return 0;
            const y: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16))));
            const geometry = scrollbarGeometry(value.current_layout.viewport, value.current_layout.scroll, value.options.layout_input.dpi);
            if (y >= geometry.thumb.y and y < geometry.thumb.bottom()) {
                value.dragging_thumb = true;
                value.drag_origin_y = y;
                value.drag_origin_offset = value.current_layout.scroll.offset;
                _ = c.SetCapture(hwnd);
            } else {
                const direction: i32 = if (y < geometry.thumb.y) -1 else 1;
                value.setScrollOffset(value.current_layout.scroll.offset + direction * value.current_layout.scroll.page) catch |failure| value.fail(failure);
            }
            return 0;
        },
        c.WM_MOUSEMOVE => {
            if (!value.dragging_thumb) return 0;
            const y: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16))));
            const geometry = scrollbarGeometry(value.current_layout.viewport, value.current_layout.scroll, value.options.layout_input.dpi);
            const travel = @max(1, geometry.track.height - geometry.thumb.height);
            const offset_delta = @as(i32, @intCast(@divTrunc(@as(i64, y - value.drag_origin_y) * value.current_layout.scroll.max_offset, travel)));
            value.setScrollOffset(value.drag_origin_offset + offset_delta) catch |failure| value.fail(failure);
            return 0;
        },
        c.WM_LBUTTONUP => {
            if (value.dragging_thumb) {
                value.dragging_thumb = false;
                _ = c.ReleaseCapture();
            }
            return 0;
        },
        c.WM_CAPTURECHANGED => {
            value.dragging_thumb = false;
            return 0;
        },
        c.WM_ERASEBKGND => {
            var client: c.RECT = undefined;
            if (c.GetClientRect(hwnd, &client) == 0 or c.FillRect(Win32.opaquePointerFromInt(c.HDC, wparam), &client, value.brushes.panel) == 0)
                value.fail(error.SheetViewportBackgroundPaintFailed);
            return 1;
        },
        c.WM_PAINT => {
            var paint: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(hwnd, &paint);
            if (hdc == null) {
                value.fail(error.SheetViewportPaintBeginFailed);
                return 0;
            }
            if (c.FillRect(hdc, &paint.rcPaint, value.brushes.panel) == 0) value.fail(error.SheetViewportPaintFailed);
            if (value.current_layout.scroll.visible) {
                const geometry = scrollbarGeometry(value.current_layout.viewport, value.current_layout.scroll, value.options.layout_input.dpi);
                drawRoundedRect(hdc, geometry.thumb, @divTrunc(geometry.thumb.width, 2), dialog_scrollbar_thumb, dialog_scrollbar_thumb, 1) catch |failure| value.fail(failure);
            }
            _ = c.EndPaint(hwnd, &paint);
            return 0;
        },
        c.WM_NCDESTROY => {
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            if (value.viewport == hwnd) value.viewport = null;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn scrimProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    var host = hostFrom(hwnd);
    if (message == c.WM_NCCREATE) host = attachHost(hwnd, lparam);
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
            const hdc = c.BeginPaint(hwnd, &paint);
            _ = c.FillRect(hdc, &paint.rcPaint, Win32.opaquePointerFromInt(c.HBRUSH, @intFromPtr(c.GetStockObject(c.BLACK_BRUSH))));
            _ = c.EndPaint(hwnd, &paint);
            return 0;
        },
        c.WM_NCDESTROY => {
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            if (host) |value| if (value.scrim == hwnd) {
                value.scrim = null;
            };
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn ownerClientRect(owner: c.HWND) !Rect {
    var client: c.RECT = undefined;
    if (c.GetClientRect(owner, &client) == 0) return error.SheetOwnerBoundsUnavailable;
    var origin = c.POINT{ .x = client.left, .y = client.top };
    if (c.ClientToScreen(owner, &origin) == 0) return error.SheetOwnerBoundsUnavailable;
    return .{
        .x = origin.x,
        .y = origin.y,
        .width = client.right - client.left,
        .height = client.bottom - client.top,
    };
}

fn createScrim(owner: c.HWND, host: *Host) !c.HWND {
    const hwnd = c.CreateWindowExW(
        host_style.scrim_extended_style,
        scrim_class.ptr,
        null,
        host_style.scrim_style,
        0,
        0,
        0,
        0,
        owner,
        null,
        c.GetModuleHandleW(null),
        host,
    ) orelse return error.SheetScrimCreationFailed;
    errdefer _ = c.DestroyWindow(hwnd);
    try positionScrim(hwnd, owner);
    return hwnd;
}

fn positionScrim(scrim: c.HWND, owner: c.HWND) !void {
    const bounds = try ownerClientRect(owner);
    if (c.SetWindowPos(scrim, null, bounds.x, bounds.y, bounds.width, bounds.height, c.SWP_NOZORDER | c.SWP_NOACTIVATE) == 0)
        return error.SheetScrimMoveFailed;
}

fn applyRoundedRegion(hwnd: c.HWND, width: i32, height: i32, dpi: u32) !void {
    const radius = Metrics.forDpi(dpi).panel_radius;
    const region = c.CreateRoundRectRgn(0, 0, width + 1, height + 1, radius * 2, radius * 2) orelse
        return error.SheetRegionCreationFailed;
    if (c.SetWindowRgn(hwnd, region, 1) == 0) {
        _ = c.DeleteObject(region);
        return error.SheetRegionApplyFailed;
    }
}

fn releaseOwnedWindow(owned: *c.HWND) void {
    const hwnd = owned.*;
    owned.* = null;
    if (hwnd != null and c.IsWindow(hwnd) != 0) _ = c.DestroyWindow(hwnd);
}

fn hiddenOwner(width: i32, height: i32) !c.HWND {
    return c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr,
        null,
        c.WS_POPUP,
        40,
        50,
        width,
        height,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse error.TestOwnerCreationFailed;
}

fn testInput(dpi: u32, owner: Rect, content_extent: i32) LayoutInput {
    return .{
        .owner = owner,
        .dpi = dpi,
        .desired_width = 520,
        .minimum_width = 320,
        .heights = .{ .minimum = 220, .ideal = 620, .maximum = 760 },
        .content_extent = content_extent,
    };
}

test "dialog framework: short content is centered and has no scrolling at 96 144 and 192 DPI" {
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const owner = Rect{ .x = 11, .y = 17, .width = Dpi.scale(1000, dpi), .height = Dpi.scale(800, dpi) };
        const result = layout(testInput(dpi, owner, 140));
        try std.testing.expectEqual(owner.x + @divTrunc(owner.width - result.sheet.width, 2), result.sheet.x);
        try std.testing.expectEqual(owner.y + @divTrunc(owner.height - result.sheet.height, 2), result.sheet.y);
        try std.testing.expect(!result.scroll.visible);
        try std.testing.expectEqual(result.sheet.height, result.viewport.height + result.footer.height);
    }
}

test "dialog framework: overflow uses one extent page maximum and clamped offset at every DPI" {
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        var input = testInput(dpi, .{ .x = 0, .y = 0, .width = Dpi.scale(900, dpi), .height = Dpi.scale(640, dpi) }, 1200);
        input.initial_offset = 5000;
        const result = layout(input);
        try std.testing.expect(result.scroll.visible);
        try std.testing.expectEqual(result.scroll.extent - result.scroll.page, result.scroll.max_offset);
        try std.testing.expectEqual(result.scroll.max_offset, result.scroll.offset);
    }
}

test "dialog framework: smaller than footer owner remains bounded without negative viewport" {
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const owner = Rect{ .x = 7, .y = 9, .width = Dpi.scale(180, dpi), .height = Dpi.scale(52, dpi) };
        const result = layout(testInput(dpi, owner, 400));
        try std.testing.expect(result.sheet.x >= owner.x and result.sheet.right() <= owner.right());
        try std.testing.expect(result.sheet.y >= owner.y and result.sheet.bottom() <= owner.bottom());
        try std.testing.expectEqual(@as(i32, 0), result.viewport.height);
        try std.testing.expectEqual(result.sheet.height, result.footer.height);
    }
}

test "dialog framework: focus reveal and direct offsets share the scroll clamp" {
    var scroll = ScrollModel.init(900, 300, -40);
    try std.testing.expectEqual(@as(i32, 0), scroll.offset);
    scroll = scroll.reveal(450, 500);
    try std.testing.expectEqual(@as(i32, 200), scroll.offset);
    scroll = scroll.reveal(850, 940);
    try std.testing.expectEqual(scroll.max_offset, scroll.offset);
    scroll = scroll.reveal(-50, 10);
    try std.testing.expectEqual(@as(i32, 0), scroll.offset);
}

test "dialog framework: footer measures roles long labels hints and validation remainder at every DPI" {
    const actions = [_]FooterAction{
        .{ .id = 2, .role = .cancel, .measured_text_width = 48 },
        .{ .id = 3, .role = .secondary, .measured_text_width = 148 },
        .{ .id = 1, .role = .primary, .measured_text_width = 74, .return_hint = true },
    };
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const footer = try measureFooter(Dpi.scale(760, dpi), Dpi.scale(64, dpi), dpi, &actions);
        try std.testing.expectEqual(@as(usize, actions.len), footer.count);
        try std.testing.expect(footer.measured_minimum_width > 0);
        try std.testing.expect(footer.slotFor(1).?.bounds.right() <= Dpi.scale(760, dpi));
        try std.testing.expect(footer.slotFor(3).?.bounds.width > footer.slotFor(2).?.bounds.width);
        try std.testing.expect(footer.validation.width > 0);
    }
}

test "dialog framework: narrow footer uses deterministic measured multi-row slots at every DPI" {
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const actions = [_]FooterAction{
            .{ .id = 2, .role = .cancel, .measured_text_width = Dpi.scale(60, dpi) },
            .{ .id = 3, .role = .secondary, .measured_text_width = Dpi.scale(150, dpi) },
            .{ .id = 1, .role = .destructive, .measured_text_width = Dpi.scale(100, dpi), .return_hint = true },
        };
        const width = Dpi.scale(300, dpi);
        const footer = try measureFooter(width, Metrics.forDpi(dpi).footer_height, dpi, &actions);
        const repeated = try measureFooter(width, Metrics.forDpi(dpi).footer_height, dpi, &actions);
        try std.testing.expect(footer.measured_minimum_width > width);
        try std.testing.expect(footer.row_count > 1);
        try std.testing.expect(footer.required_height > Metrics.forDpi(dpi).footer_height);
        try std.testing.expectEqual(footer.row_count, repeated.row_count);
        try std.testing.expectEqual(footer.required_height, repeated.required_height);
        try std.testing.expect(footer.validation.width >= 0 and footer.validation.height >= 0);
        for (footer.slice(), repeated.slice(), actions) |slot, repeated_slot, action| {
            try std.testing.expectEqualDeep(slot, repeated_slot);
            try std.testing.expectEqual(actionWidth(action, Metrics.forDpi(dpi)), slot.bounds.width);
            try std.testing.expect(slot.bounds.x >= 0 and slot.bounds.right() <= width);
            try std.testing.expect(slot.bounds.y >= 0 and slot.bounds.bottom() <= footer.required_height);
        }
    }
}

test "dialog framework: measured footer widens when possible and grows a bounded narrow sheet" {
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const actions = [_]FooterAction{
            .{ .id = 2, .role = .cancel, .measured_text_width = Dpi.scale(60, dpi) },
            .{ .id = 3, .role = .secondary, .measured_text_width = Dpi.scale(150, dpi) },
            .{ .id = 1, .role = .primary, .measured_text_width = Dpi.scale(100, dpi), .return_hint = true },
        };
        const wide_footer = try measureFooter(Dpi.scale(900, dpi), Metrics.forDpi(dpi).footer_height, dpi, &actions);
        var wide_input = testInput(dpi, .{
            .x = 13,
            .y = 17,
            .width = Dpi.scale(1000, dpi),
            .height = Dpi.scale(800, dpi),
        }, 360);
        wide_input.desired_width = 300;
        wide_input.footer_minimum_width = wide_footer.measured_minimum_width;
        const widened = layout(wide_input);
        try std.testing.expect(widened.sheet.width >= wide_footer.measured_minimum_width);

        var narrow_input = testInput(dpi, .{
            .x = 13,
            .y = 17,
            .width = Dpi.scale(340, dpi),
            .height = Dpi.scale(800, dpi),
        }, 360);
        narrow_input.desired_width = 300;
        const baseline = layout(narrow_input);
        const available_width = narrow_input.owner.width - Metrics.forDpi(dpi).outer_margin * 2;
        const narrow_footer = try measureFooter(available_width, Metrics.forDpi(dpi).footer_height, dpi, &actions);
        narrow_input.footer_minimum_width = narrow_footer.measured_minimum_width;
        narrow_input.footer_minimum_height = narrow_footer.required_height;
        const wrapped = layout(narrow_input);
        try std.testing.expectEqual(available_width, wrapped.sheet.width);
        try std.testing.expect(wrapped.footer.height >= narrow_footer.required_height);
        try std.testing.expect(wrapped.sheet.height > baseline.sheet.height);
        try std.testing.expect(wrapped.viewport.height >= 0);
        try std.testing.expect(wrapped.sheet.x >= narrow_input.owner.x and wrapped.sheet.right() <= narrow_input.owner.right());
        try std.testing.expect(wrapped.sheet.y >= narrow_input.owner.y and wrapped.sheet.bottom() <= narrow_input.owner.bottom());
    }
}

test "dialog framework: footer measures current DPI labels and paints configured return hints" {
    var previous_width: i32 = 0;
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const owner = try hiddenOwner(1200, 900);
        defer _ = c.DestroyWindow(owner);
        var host: Host = .{};
        try host.init(owner, .{ .layout_input = testInput(dpi, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, 400) });
        defer host.deinit();
        try host.configureFooter(&.{.{
            .id = 41,
            .role = .destructive,
            .measured_text_width = 0,
            .return_hint = true,
        }});
        const button = try host.createFooterButton(41, std.unicode.utf8ToUtf16LeStringLiteral("Delete selected worktree").ptr);
        const measured = try measureFooterActionLabel(button, dpi);
        try std.testing.expect(measured > previous_width);
        previous_width = measured;
        try std.testing.expectEqual(measured, host.footer_actions[0].measured_text_width);
        const slot = host.footer_layout.?.slotFor(41).?;
        const metrics = Metrics.forDpi(dpi);
        try std.testing.expectEqual(
            @max(metrics.button_min_width, measured + metrics.button_text_padding * 2 + metrics.return_hint_width),
            slot.bounds.width,
        );

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
        const fill = c.CreateSolidBrush(dialog_primary_button) orelse return error.TestBrushCreationFailed;
        defer _ = c.DeleteObject(fill);
        var bitmap_bounds = c.RECT{ .left = 0, .top = 0, .right = slot.bounds.width, .bottom = slot.bounds.height };
        try std.testing.expect(c.FillRect(dc, &bitmap_bounds, fill) != 0);
        var item = std.mem.zeroes(c.DRAWITEMSTRUCT);
        item.CtlID = 41;
        item.hwndItem = button;
        item.hDC = dc;
        item.rcItem = bitmap_bounds;
        try drawFooterAction(&item, dpi, host.footer_actions[0]);
        const content = footerContentLayout(.{
            .x = 0,
            .y = 0,
            .width = slot.bounds.width,
            .height = slot.bounds.height,
        }, dpi, host.footer_actions[0]);
        const hint = content.return_hint orelse return error.TestReturnHintMissing;
        var changed_pixels: usize = 0;
        var y = hint.y;
        while (y < hint.bottom()) : (y += 1) {
            var x = hint.x;
            while (x < hint.right()) : (x += 1) {
                if (c.GetPixel(dc, x, y) != dialog_primary_button) changed_pixels += 1;
            }
        }
        try std.testing.expect(changed_pixels > 0);
        try std.testing.expectEqual(dialog_primary_button, buttonFillColor(.destructive, true, false));
    }
}

test "dialog framework: host feeds measured footer width into sheet geometry" {
    const owner = try hiddenOwner(1200, 900);
    defer _ = c.DestroyWindow(owner);
    var input = testInput(96, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, 400);
    input.desired_width = 300;
    input.minimum_width = 240;
    var host: Host = .{};
    try host.init(owner, .{ .layout_input = input });
    defer host.deinit();
    const actions = [_]FooterAction{
        .{ .id = 2, .role = .cancel, .measured_text_width = 120 },
        .{ .id = 3, .role = .secondary, .measured_text_width = 240 },
        .{ .id = 1, .role = .primary, .measured_text_width = 180, .return_hint = true },
    };
    try host.configureFooter(&actions);
    _ = try host.createFooterButton(2, std.unicode.utf8ToUtf16LeStringLiteral("Cancel this operation").ptr);
    _ = try host.createFooterButton(3, std.unicode.utf8ToUtf16LeStringLiteral("Create another workspace").ptr);
    _ = try host.createFooterButton(1, std.unicode.utf8ToUtf16LeStringLiteral("Apply workspace changes").ptr);
    const footer = host.footer_layout.?;
    try std.testing.expect(host.current_layout.sheet.width >= footer.measured_minimum_width);
    try std.testing.expectEqual(@as(usize, 1), footer.row_count);
    for (footer.slice(), host.footer_actions[0..host.footer_action_count]) |slot, action|
        try std.testing.expectEqual(actionWidth(action, Metrics.forDpi(96)), slot.bounds.width);
}

test "dialog framework: narrow owner host grows deterministic footer rows at every DPI" {
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const owner = try hiddenOwner(Dpi.scale(340, dpi), Dpi.scale(800, dpi));
        defer _ = c.DestroyWindow(owner);
        var host: Host = .{};
        try host.init(owner, .{
            .layout_input = testInput(dpi, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, 360),
        });
        defer host.deinit();
        const baseline_height = host.current_layout.sheet.height;
        const actions = [_]FooterAction{
            .{ .id = 2, .role = .cancel, .measured_text_width = Dpi.scale(130, dpi) },
            .{ .id = 3, .role = .secondary, .measured_text_width = Dpi.scale(160, dpi) },
            .{ .id = 1, .role = .primary, .measured_text_width = Dpi.scale(160, dpi), .return_hint = true },
        };
        try host.configureFooter(&actions);
        _ = try host.createFooterButton(2, std.unicode.utf8ToUtf16LeStringLiteral("Cancel this operation").ptr);
        _ = try host.createFooterButton(3, std.unicode.utf8ToUtf16LeStringLiteral("Create another workspace").ptr);
        _ = try host.createFooterButton(1, std.unicode.utf8ToUtf16LeStringLiteral("Apply workspace changes").ptr);
        const footer = host.footer_layout.?;
        try std.testing.expect(footer.row_count > 1);
        try std.testing.expectEqual(footer.required_height, host.current_layout.footer.height);
        try std.testing.expect(host.current_layout.sheet.height > baseline_height);
        try std.testing.expect(footer.validation.width >= 0 and footer.validation.height >= 0);
        for (footer.slice(), host.footer_actions[0..host.footer_action_count]) |slot, action| {
            try std.testing.expectEqual(actionWidth(action, Metrics.forDpi(dpi)), slot.bounds.width);
            try std.testing.expect(slot.bounds.x >= 0 and slot.bounds.right() <= host.current_layout.footer.width);
            try std.testing.expect(slot.bounds.y >= 0 and slot.bounds.bottom() <= host.current_layout.footer.height);
        }
        const owner_bounds = try ownerClientRect(owner);
        try std.testing.expect(host.current_layout.sheet.x >= owner_bounds.x and host.current_layout.sheet.right() <= owner_bounds.right());
        try std.testing.expect(host.current_layout.sheet.y >= owner_bounds.y and host.current_layout.sheet.bottom() <= owner_bounds.bottom());
    }
}

test "dialog framework: rounded field geometry scales focus ring and tint at every DPI" {
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const geometry = fieldGeometry(.{ .x = 10, .y = 12, .width = Dpi.scale(300, dpi), .height = Dpi.scale(40, dpi) }, dpi);
        try std.testing.expect(geometry.focus_tint.width > geometry.focus_ring.width);
        try std.testing.expect(geometry.focus_ring.width > geometry.border.width);
        try std.testing.expect(geometry.radius == Dpi.scale(8, dpi));
    }
}

test "dialog framework: dark control paint helpers are opaque and preserve native edit semantics" {
    inline for ([_]ControlKind{ .panel, .static, .edit, .button }) |kind| {
        const style = controlPaintStyle(kind, true);
        try std.testing.expect(style.is_opaque);
        try std.testing.expect(style.background != 0 or kind == .panel);
    }
    try std.testing.expectEqual(Tokens.dialog_field_background, controlPaintStyle(.edit, true).background);
    try std.testing.expectEqual(Tokens.dialog_muted_text, controlPaintStyle(.edit, false).foreground);
}

test "dialog framework: pointer-shaped handle results preserve high bits without checked casts" {
    const raw = std.math.maxInt(usize) - 0x1234;
    const handle = Win32.opaquePointerFromInt(c.HBRUSH, raw);
    const result = handleResult(handle);
    try std.testing.expectEqual(raw, @as(usize, @bitCast(result)));
}

test "dialog framework: rounded field and role button painting succeeds on an offscreen bitmap" {
    const screen = c.GetDC(null);
    if (screen == null) return error.TestScreenDcUnavailable;
    defer _ = c.ReleaseDC(null, screen);
    const dc = c.CreateCompatibleDC(null) orelse return error.TestDcCreationFailed;
    defer _ = c.DeleteDC(dc);
    const bitmap = c.CreateCompatibleBitmap(screen, 420, 180) orelse return error.TestBitmapCreationFailed;
    defer _ = c.DeleteObject(bitmap);
    _ = c.SelectObject(dc, bitmap);
    try drawField(dc, .{ .x = 10, .y = 10, .width = 380, .height = 46 }, 144, true);
    try drawButton(dc, .{ .x = 210, .y = 80, .width = 180, .height = 48 }, 144, .primary, true, false);
    try drawButton(dc, .{ .x = 10, .y = 80, .width = 170, .height = 48 }, 144, .secondary, false, false);
}

test "dialog framework: unknown wide draw-item IDs defer without integer-cast panic" {
    const owner = try hiddenOwner(900, 700);
    defer _ = c.DestroyWindow(owner);
    var host: Host = .{};
    try host.init(owner, .{ .layout_input = testInput(96, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, 400) });
    defer host.deinit();
    var item: c.DRAWITEMSTRUCT = std.mem.zeroes(c.DRAWITEMSTRUCT);
    item.CtlID = std.math.maxInt(c.UINT);

    _ = c.SendMessageW(host.hwnd, c.WM_DRAWITEM, 0, @bitCast(@intFromPtr(&item)));
    try std.testing.expect(host.failure == null);
}

test "dialog framework: scrollbar thumb scales and follows the single offset model" {
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const viewport = Rect{ .x = 0, .y = 0, .width = Dpi.scale(500, dpi), .height = Dpi.scale(300, dpi) };
        const top = scrollbarGeometry(viewport, ScrollModel.init(Dpi.scale(900, dpi), viewport.height, 0), dpi);
        const bottom_scroll = ScrollModel.init(Dpi.scale(900, dpi), viewport.height, 100000);
        const bottom = scrollbarGeometry(viewport, bottom_scroll, dpi);
        try std.testing.expectEqual(top.track.y, top.thumb.y);
        try std.testing.expectEqual(bottom.track.bottom(), bottom.thumb.bottom());
        try std.testing.expect(bottom.thumb.height >= Metrics.forDpi(dpi).scrollbar_min_thumb);
    }
}

test "dialog framework: hidden rounded popup and owner client scrim use required native styles" {
    const owner = try hiddenOwner(900, 700);
    defer _ = c.DestroyWindow(owner);
    var host: Host = .{};
    try host.init(owner, .{ .layout_input = testInput(96, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, 900) });
    defer host.deinit();
    try std.testing.expect(c.IsWindowVisible(host.hwnd) == 0 and c.IsWindowVisible(host.scrim) == 0);
    const style = c.GetWindowLongPtrW(host.hwnd, c.GWL_STYLE);
    try std.testing.expect(style & c.WS_POPUP != 0);
    try std.testing.expect(style & c.WS_CAPTION == 0);
    try std.testing.expect(style & c.WS_CLIPCHILDREN != 0);
    const scrim_style = c.GetWindowLongPtrW(host.scrim, c.GWL_EXSTYLE);
    try std.testing.expect(scrim_style & c.WS_EX_LAYERED != 0);
    try std.testing.expect(scrim_style & c.WS_EX_NOACTIVATE != 0);
    const owner_client = try ownerClientRect(owner);
    var scrim_bounds: c.RECT = undefined;
    try std.testing.expect(c.GetWindowRect(host.scrim, &scrim_bounds) != 0);
    try std.testing.expectEqualDeep(owner_client, Rect{
        .x = scrim_bounds.left,
        .y = scrim_bounds.top,
        .width = scrim_bounds.right - scrim_bounds.left,
        .height = scrim_bounds.bottom - scrim_bounds.top,
    });
    const region = c.CreateRectRgn(0, 0, 0, 0) orelse return error.TestRegionCreationFailed;
    defer _ = c.DeleteObject(region);
    try std.testing.expect(c.GetWindowRgn(host.hwnd, region) != c.ERROR);
}

test "dialog framework: host captures owner focus before hidden sheet controls can take it" {
    const owner = try hiddenOwner(900, 700);
    defer _ = c.DestroyWindow(owner);
    const owner_edit = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr,
        null,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP,
        0,
        0,
        100,
        24,
        owner,
        Win32.opaquePointerFromInt(c.HMENU, 91),
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.TestControlCreationFailed;
    _ = c.SetFocus(owner_edit);
    try std.testing.expectEqual(owner_edit, c.GetFocus());

    var host: Host = .{};
    try host.init(owner, .{ .layout_input = testInput(96, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, 400) });
    defer host.deinit();
    const sheet_edit = try host.createEdit(92, false);
    _ = c.SetFocus(sheet_edit);

    try std.testing.expectEqual(owner_edit, host.previous_focus);
    try std.testing.expectEqual(sheet_edit, c.GetFocus());
}

test "dialog framework: hidden host DPI relayout keeps viewport above fixed footer" {
    const owner = try hiddenOwner(1100, 850);
    defer _ = c.DestroyWindow(owner);
    var host: Host = .{};
    try host.init(owner, .{ .layout_input = testInput(192, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, 1000) });
    defer host.deinit();
    try host.relayout();
    try std.testing.expectEqual(host.current_layout.sheet.height, host.current_layout.viewport.height + host.current_layout.footer.height);
    try std.testing.expect(host.current_layout.scroll.visible);
    try std.testing.expectEqual(@as(i32, 0), host.current_layout.footer.y - host.current_layout.viewport.bottom());
}

test "dialog framework: host DPI transition ignores off-owner suggestion and refreshes owner scrim" {
    const owner = try hiddenOwner(1200, 900);
    defer _ = c.DestroyWindow(owner);
    var host: Host = .{};
    try host.init(owner, .{ .layout_input = testInput(96, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, 600) });
    defer host.deinit();
    for ([_]u32{ 144, 192, 96 }) |dpi| {
        var suggested = c.RECT{ .left = -5000, .top = -4000, .right = -4200, .bottom = -3500 };
        _ = c.SendMessageW(host.hwnd, c.WM_DPICHANGED, @as(usize, dpi) | (@as(usize, dpi) << 16), @bitCast(@intFromPtr(&suggested)));
        if (host.failure) |failure| return failure;
        const owner_bounds = try ownerClientRect(owner);
        var actual: c.RECT = undefined;
        try std.testing.expect(c.GetWindowRect(host.hwnd, &actual) != 0);
        try std.testing.expectEqualDeep(host.current_layout.sheet, Rect{
            .x = actual.left,
            .y = actual.top,
            .width = actual.right - actual.left,
            .height = actual.bottom - actual.top,
        });
        try std.testing.expect(actual.left >= owner_bounds.x and actual.right <= owner_bounds.right());
        try std.testing.expect(actual.top >= owner_bounds.y and actual.bottom <= owner_bounds.bottom());
        try std.testing.expect(actual.left != suggested.left and actual.top != suggested.top);
        var scrim: c.RECT = undefined;
        try std.testing.expect(c.GetWindowRect(host.scrim, &scrim) != 0);
        try std.testing.expectEqualDeep(owner_bounds, Rect{
            .x = scrim.left,
            .y = scrim.top,
            .width = scrim.right - scrim.left,
            .height = scrim.bottom - scrim.top,
        });
    }
}

test "dialog framework: role footer keeps native button edit and combo controls" {
    const owner = try hiddenOwner(900, 700);
    defer _ = c.DestroyWindow(owner);
    var host: Host = .{};
    try host.init(owner, .{ .layout_input = testInput(96, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, 400) });
    defer host.deinit();
    const actions = [_]FooterAction{
        .{ .id = 2, .role = .cancel, .measured_text_width = 48 },
        .{ .id = 41, .role = .destructive, .measured_text_width = 72, .return_hint = true },
    };
    try host.configureFooter(&actions);
    const button = try host.createFooterButton(41, std.unicode.utf8ToUtf16LeStringLiteral("Delete").ptr);
    const edit = try host.createEdit(51, false);
    const combo = try host.createComboBox(52, false);
    try std.testing.expect(host.footerAction(41).?.role == .destructive);
    try std.testing.expect(c.GetDlgItem(host.hwnd, 41) == button);
    try std.testing.expect(c.GetParent(edit) == host.viewport and c.GetParent(combo) == host.viewport);
    try std.testing.expect(c.GetWindowLongPtrW(edit, c.GWL_EXSTYLE) & c.WS_EX_CLIENTEDGE == 0);
    try std.testing.expect(c.GetWindowLongPtrW(combo, c.GWL_EXSTYLE) & c.WS_EX_CLIENTEDGE == 0);
}

test "dialog framework: hidden host viewport and content recurse Tab through IsDialogMessage" {
    const owner = try hiddenOwner(900, 700);
    defer _ = c.DestroyWindow(owner);
    var host: Host = .{};
    try host.init(owner, .{ .layout_input = testInput(96, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, 400) });
    defer host.deinit();
    const content = c.CreateWindowExW(
        c.WS_EX_CONTROLPARENT,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr,
        null,
        c.WS_CHILD | c.WS_VISIBLE,
        0,
        0,
        300,
        200,
        host.viewport,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.TestContentCreationFailed;
    const first = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr,
        null,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP,
        0,
        0,
        100,
        24,
        content,
        Win32.opaquePointerFromInt(c.HMENU, 71),
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.TestControlCreationFailed;
    const second = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT").ptr,
        null,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP,
        0,
        30,
        100,
        24,
        content,
        Win32.opaquePointerFromInt(c.HMENU, 72),
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.TestControlCreationFailed;
    const previous_focus = c.GetFocus();
    const previous_active = c.GetActiveWindow();
    defer {
        if (previous_focus != null and c.IsWindow(previous_focus) != 0) _ = c.SetFocus(previous_focus);
    }
    try std.testing.expect(c.IsWindowVisible(host.hwnd) == 0);
    try std.testing.expect(c.IsWindowVisible(host.viewport) == 0);
    try std.testing.expect(c.IsWindowVisible(content) == 0);
    try std.testing.expect(c.GetWindowLongPtrW(host.viewport, c.GWL_EXSTYLE) & c.WS_EX_CONTROLPARENT != 0);
    try std.testing.expect(c.GetWindowLongPtrW(content, c.GWL_EXSTYLE) & c.WS_EX_CONTROLPARENT != 0);
    try std.testing.expectEqual(second, c.GetNextDlgTabItem(host.hwnd, first, 0));
    var message = std.mem.zeroes(c.MSG);
    message.hwnd = first;
    message.message = c.WM_KEYUP;
    message.wParam = c.VK_TAB;
    try std.testing.expect(c.IsDialogMessageW(host.hwnd, &message) != 0);
    try std.testing.expectEqual(previous_active, c.GetActiveWindow());
}

const DialogCommandProbe = struct {
    observed: ?u16 = null,

    fn onMessage(
        context: ?*anyopaque,
        _: c.HWND,
        message: c.UINT,
        wparam: c.WPARAM,
        _: c.LPARAM,
        result: *c.LRESULT,
    ) bool {
        if (message != c.WM_COMMAND) return false;
        const probe: *DialogCommandProbe = @ptrCast(@alignCast(context.?));
        probe.observed = @truncate(wparam);
        result.* = 0;
        return true;
    }
};

test "dialog framework: dialog-manager cancel dispatches the configured cancel action only" {
    const owner = try hiddenOwner(900, 700);
    defer _ = c.DestroyWindow(owner);
    var probe: DialogCommandProbe = .{};
    var host: Host = .{};
    try host.init(owner, .{
        .layout_input = testInput(96, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, 400),
        .context = &probe,
        .on_message = DialogCommandProbe.onMessage,
    });
    defer host.deinit();

    try host.configureFooter(&.{
        .{ .id = 6192, .role = .cancel, .measured_text_width = 48 },
        .{ .id = 6184, .role = .primary, .measured_text_width = 48 },
    });
    _ = c.SendMessageW(host.hwnd, c.WM_COMMAND, c.IDCANCEL, 0);
    try std.testing.expectEqual(@as(?u16, 6192), probe.observed);

    probe.observed = null;
    try host.configureFooter(&.{
        .{ .id = c.IDCANCEL, .role = .cancel, .measured_text_width = 48 },
        .{ .id = 6184, .role = .primary, .measured_text_width = 48 },
    });
    _ = c.SendMessageW(host.hwnd, c.WM_COMMAND, c.IDCANCEL, 0);
    try std.testing.expectEqual(@as(?u16, c.IDCANCEL), probe.observed);

    probe.observed = null;
    try host.configureFooter(&.{.{ .id = 6184, .role = .primary, .measured_text_width = 48 }});
    _ = c.SendMessageW(host.hwnd, c.WM_COMMAND, c.IDCANCEL, 0);
    try std.testing.expectEqual(@as(?u16, c.IDCANCEL), probe.observed);

    probe.observed = null;
    try host.configureFooter(&.{
        .{ .id = 6192, .role = .cancel, .measured_text_width = 48 },
        .{ .id = 6184, .role = .primary, .measured_text_width = 48 },
    });
    _ = c.SendMessageW(host.hwnd, c.WM_COMMAND, 6112, 0);
    try std.testing.expectEqual(@as(?u16, 6112), probe.observed);

    probe.observed = null;
    _ = c.SendMessageW(host.hwnd, c.WM_COMMAND, c.IDCANCEL, 1);
    try std.testing.expectEqual(@as(?u16, c.IDCANCEL), probe.observed);
}
