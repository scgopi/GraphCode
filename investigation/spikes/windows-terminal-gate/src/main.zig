const std = @import("std");

const c = @cImport({
    @cDefine("_WIN32_WINNT", "0x0601");
    @cInclude("windows.h");
    @cInclude("winghostty/win32_host.h");
});

const allocator = std.heap.c_allocator;
const HWND = c.HWND;
const HINSTANCE = c.HINSTANCE;
const LPARAM = c.LPARAM;
const LRESULT = c.LRESULT;
const LONG_PTR = c.LONG_PTR;
const UINT = c.UINT;
const WPARAM = c.WPARAM;
const DWORD = c.DWORD;
const BOOL = c.BOOL;

const terminal_columns: usize = 120;
const terminal_rows: usize = 40;
const terminal_cell_count: usize = terminal_columns * terminal_rows;

const TerminalParserState = enum {
    normal,
    escape,
    csi,
    osc,
};

const SurfaceSlot = struct {
    surface: ?*c.winghostty_surface = null,
    last_surface: ?*c.winghostty_surface = null,
    session_name: []const u8 = "",
    attach: ?std.process.Child = null,
    destroying: bool = false,
    destroyed: bool = false,
    redraws: usize = 0,
    focus_events: usize = 0,
    ime_events: usize = 0,
    clipboard_events: usize = 0,
    output_events: usize = 0,
    input_bytes: usize = 0,
    input_seen: bool = false,
    output_seen: bool = false,
    terminal_buffer: [16 * 1024]u8 = undefined,
    terminal_buffer_len: usize = 0,
    terminal_cells: [terminal_cell_count]c.winghostty_terminal_cell = [_]c.winghostty_terminal_cell{
        .{
            .codepoint = 0,
            .foreground = 0xE6E6E6,
            .background = 0,
            .flags = 0,
        },
    } ** terminal_cell_count,
    terminal_x: usize = 0,
    terminal_y: usize = 0,
    terminal_parser: TerminalParserState = .normal,
    csi_value: usize = 0,
    csi_have_value: bool = false,
    csi_private: bool = false,
};

const App = struct {
    hwnd: HWND = null,
    instance: HINSTANCE = null,
    host: ?*c.winghostty_host = null,
    surfaces: [2]SurfaceSlot = .{ .{}, .{} },
    zmx_path: []const u8 = "zmx.exe",
    cwd: []const u8 = ".",
    smoke: bool = false,
    stress: bool = false,
    same_session: bool = false,
    tick: usize = 0,
    recreate_count: usize = 0,
    callbacksAfterDestroy: usize = 0,
    lastRenderError: c.winghostty_result = c.WINGHOSTTY_OK,
    renderFailures: usize = 0,
    transportFailures: usize = 0,
    lastTransportFailure: []const u8 = "",
    totalInputBytes: usize = 0,
    totalOutputEvents: usize = 0,
    sameSession: bool = false,
    active_surface: usize = 0,
    retired_surfaces: [16]?*c.winghostty_surface = [_]?*c.winghostty_surface{null} ** 16,
    retired_surface_count: usize = 0,
    ready: bool = false,
};

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeTerminalGate");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("GraphCode Windows terminal gate");
// The attach client is deliberately the real provider command: `zmx attach <name>`.
// std.process.Child maps to CreateProcessW and owns the child handles.
const wm_gate_tick: UINT = c.WM_APP + 41;
const timer_id: usize = 41;
const gwlp_userdata: i32 = -21;

fn appFromWindow(hwnd: HWND) ?*App {
    const value = c.GetWindowLongPtrW(hwnd, gwlp_userdata);
    if (value == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(value)));
}

fn appFromUserData(user_data: ?*anyopaque) ?*App {
    return if (user_data) |value| @ptrCast(@alignCast(value)) else null;
}

fn recordProviderError(app: *App, result: c.winghostty_result) void {
    if (result != c.WINGHOSTTY_OK) {
        app.renderFailures += 1;
        if (app.lastRenderError == c.WINGHOSTTY_OK) {
            app.lastRenderError = result;
        }
    }
}

fn slotForSurface(app: *App, surface: *c.winghostty_surface) ?*SurfaceSlot {
    for (&app.surfaces) |*slot| {
        if (slot.surface == surface) return slot;
    }
    return null;
}

fn surfaceIndex(app: *App, surface: *c.winghostty_surface) ?usize {
    for (&app.surfaces, 0..) |*slot, index| {
        if (slot.surface == surface) return index;
    }
    return null;
}

fn isRetiredSurface(app: *App, surface: *c.winghostty_surface) bool {
    for (app.retired_surfaces[0..app.retired_surface_count]) |retired| {
        if (retired == surface) return true;
    }
    return false;
}

fn callbackSlot(
    app: *App,
    surface: *c.winghostty_surface,
) ?*SurfaceSlot {
    const slot = slotForSurface(app, surface) orelse {
        if (isRetiredSurface(app, surface)) app.callbacksAfterDestroy += 1;
        return null;
    };
    if (slot.destroyed or slot.destroying) {
        app.callbacksAfterDestroy += 1;
        return null;
    }
    return slot;
}

fn rememberRetiredSurface(app: *App, surface: *c.winghostty_surface) void {
    if (app.retired_surface_count < app.retired_surfaces.len) {
        app.retired_surfaces[app.retired_surface_count] = surface;
        app.retired_surface_count += 1;
    }
}

fn renderSurface(app: *App, slot: *SurfaceSlot, surface: *c.winghostty_surface) void {
    const make_current = c.winghostty_surface_make_current(surface);
    recordProviderError(app, make_current);
    const render = c.winghostty_surface_render(surface);
    recordProviderError(app, render);
    const present = c.winghostty_surface_present(surface);
    recordProviderError(app, present);
    const clear_current = c.winghostty_surface_clear_current(surface);
    recordProviderError(app, clear_current);
    slot.redraws += 1;
}

fn onRedraw(user_data: ?*anyopaque, surface: *c.winghostty_surface) callconv(.c) void {
    const app = appFromUserData(user_data) orelse return;
    const slot = callbackSlot(app, surface) orelse return;
    renderSurface(app, slot, surface);
}

fn onFocus(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    focused: u8,
) callconv(.c) void {
    const app = appFromUserData(user_data) orelse return;
    const slot = callbackSlot(app, surface) orelse return;
    slot.focus_events += 1;
    if (focused != 0) {
        app.active_surface = surfaceIndex(app, surface) orelse app.active_surface;
        for (&app.surfaces) |*other| {
            if (other.surface) |other_surface| {
                if (other_surface != surface) {
                    _ = c.winghostty_surface_set_focus(other_surface, 0);
                }
            }
        }
    }
}

fn writeAttachInput(
    app: *App,
    surface: *c.winghostty_surface,
    bytes: []const u8,
) void {
    if (bytes.len == 0) return;
    const slot = callbackSlot(app, surface) orelse return;
    const child = &(slot.attach orelse {
        app.transportFailures += 1;
        app.lastTransportFailure = "no-attach";
        return;
    });
    const stdin = child.stdin orelse {
        app.transportFailures += 1;
        app.lastTransportFailure = "no-stdin";
        return;
    };
    stdin.writeAll(bytes) catch |err| {
        std.debug.print("terminal gate stdin write failed: {s}\n", .{@errorName(err)});
        app.transportFailures += 1;
        app.lastTransportFailure = "write";
        return;
    };
    slot.input_bytes += bytes.len;
    slot.input_seen = true;
    app.totalInputBytes += bytes.len;
}

fn onKey(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    event: *const c.winghostty_key_event,
) callconv(.c) void {
    const app = appFromUserData(user_data) orelse return;
    if (event.action == c.WINGHOSTTY_KEY_RELEASE) return;
    const bytes: []const u8 = switch (event.virtual_key) {
        c.VK_RETURN => "\r",
        c.VK_BACK => "\x08",
        c.VK_TAB => "\t",
        c.VK_ESCAPE => "\x1b",
        c.VK_UP => "\x1b[A",
        c.VK_DOWN => "\x1b[B",
        c.VK_RIGHT => "\x1b[C",
        c.VK_LEFT => "\x1b[D",
        else => return,
    };
    writeAttachInput(app, surface, bytes);
}

fn onText(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    text: [*:0]const u8,
    length: u32,
) callconv(.c) void {
    const app = appFromUserData(user_data) orelse return;
    writeAttachInput(app, surface, text[0..length]);
}

fn onImeUpdate(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    text: [*:0]const u8,
    length: u32,
    committed: u8,
) callconv(.c) void {
    const app = appFromUserData(user_data) orelse return;
    const slot = callbackSlot(app, surface) orelse return;
    slot.ime_events += 1;
    if (committed != 0) writeAttachInput(app, surface, text[0..length]);
}

fn onClipboardWrite(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    format: u32,
    text: [*:0]const u8,
    length: u32,
) callconv(.c) void {
    _ = format;
    const app = appFromUserData(user_data) orelse return;
    const slot = callbackSlot(app, surface) orelse return;
    slot.clipboard_events += 1;
    writeAttachInput(app, surface, text[0..length]);
}

fn onExit(
    user_data: ?*anyopaque,
    surface: ?*c.winghostty_surface,
    status: i32,
) callconv(.c) void {
    _ = status;
    const app = appFromUserData(user_data) orelse return;
    const value = surface orelse return;
    _ = callbackSlot(app, value);
}

fn noOpTitle(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    title: [*:0]const u8,
) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = title;
}

fn noOpCwd(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    cwd: [*:0]const u8,
) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = cwd;
}

fn noOpBell(user_data: ?*anyopaque, surface: *c.winghostty_surface) callconv(.c) void {
    _ = user_data;
    _ = surface;
}

fn noOpNotification(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    notification: [*:0]const u8,
) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = notification;
}

fn noOpFatal(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    error_code: c.winghostty_result,
    message: [*:0]const u8,
) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = error_code;
    _ = message;
}

fn noOpDpi(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    dpi: u32,
    scale: f32,
) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = dpi;
    _ = scale;
}

fn noOpMetrics(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    metrics: *const c.winghostty_cell_metrics,
) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = metrics;
}

fn noOpAccessibilitySelection(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    start: u64,
    end: u64,
) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = start;
    _ = end;
}

fn noOpImeStart(user_data: ?*anyopaque, surface: *c.winghostty_surface) callconv(.c) void {
    _ = user_data;
    _ = surface;
}

fn noOpImeEnd(user_data: ?*anyopaque, surface: *c.winghostty_surface) callconv(.c) void {
    _ = user_data;
    _ = surface;
}

fn noOpMouse(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    event: *const c.winghostty_mouse_event,
) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = event;
}

fn noOpSelection(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    event: *const c.winghostty_selection_event,
) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = event;
}

fn noOpLink(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    url: [*:0]const u8,
    hovered: u8,
    clicked: u8,
) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = url;
    _ = hovered;
    _ = clicked;
}

fn onPaste(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    text: [*:0]const u8,
    length: u32,
    bracketed: u8,
) callconv(.c) void {
    _ = bracketed;
    const app = appFromUserData(user_data) orelse return;
    writeAttachInput(app, surface, text[0..length]);
}

fn onClipboardRead(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    format: u32,
    text: [*:0]const u8,
    length: u32,
) callconv(.c) void {
    _ = format;
    const app = appFromUserData(user_data) orelse return;
    writeAttachInput(app, surface, text[0..length]);
}

fn noOpPaste(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    text: [*:0]const u8,
    length: u32,
    bracketed: u8,
) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = text;
    _ = length;
    _ = bracketed;
}

fn initializeOptions(app: *App, index: usize) c.winghostty_surface_options_v2 {
    var options: c.winghostty_surface_options_v2 = undefined;
    c.winghostty_surface_options_v2_init(&options);
    options.bounds.x = if (index == 0) 0 else 480;
    options.bounds.y = 0;
    options.bounds.width = 480;
    options.bounds.height = 560;
    options.visible = 1;
    options.focus = if (index == 0) 1 else 0;
    options.theme = c.WINGHOSTTY_THEME_DARK;
    options.font_scale = 1.0;
    options.user_data = @ptrCast(app);
    options.callbacks.on_exit = @ptrCast(&onExit);
    options.callbacks.on_title = @ptrCast(&noOpTitle);
    options.callbacks.on_cwd = @ptrCast(&noOpCwd);
    options.callbacks.on_bell = @ptrCast(&noOpBell);
    options.callbacks.on_notification = @ptrCast(&noOpNotification);
    options.callbacks.on_redraw = @ptrCast(&onRedraw);
    options.callbacks.on_focus = @ptrCast(&onFocus);
    options.callbacks.on_fatal_error = @ptrCast(&noOpFatal);
    options.callbacks.on_dpi_changed = @ptrCast(&noOpDpi);
    options.callbacks.on_metrics_changed = @ptrCast(&noOpMetrics);
    options.callbacks.on_accessibility_selection = @ptrCast(&noOpAccessibilitySelection);
    options.input_callbacks.on_key = @ptrCast(&onKey);
    options.input_callbacks.on_text = @ptrCast(&onText);
    options.input_callbacks.on_ime_start = @ptrCast(&noOpImeStart);
    options.input_callbacks.on_ime_update = @ptrCast(&onImeUpdate);
    options.input_callbacks.on_ime_end = @ptrCast(&noOpImeEnd);
    options.input_callbacks.on_mouse = @ptrCast(&noOpMouse);
    options.input_callbacks.on_selection = @ptrCast(&noOpSelection);
    options.input_callbacks.on_link = @ptrCast(&noOpLink);
    options.input_callbacks.on_paste = @ptrCast(&onPaste);
    options.input_callbacks.on_clipboard_read = @ptrCast(&onClipboardRead);
    options.input_callbacks.on_clipboard_write = @ptrCast(&onClipboardWrite);
    options.input.cell_width = 8;
    options.input.cell_height = 16;
    options.input.selection_enabled = 1;
    options.input.links_enabled = 1;
    options.input.paste_protection = 1;
    options.input.bracketed_paste = 1;
    options.input.keyboard_layout = null;
    return options;
}

fn sessionName(app: *App, index: usize) []const u8 {
    if (app.same_session) return "graphcode-terminal-gate-shared";
    return if (index == 0) "graphcode-terminal-gate-a" else "graphcode-terminal-gate-b";
}

fn zmxGet(app: *App, name: []const u8) !bool {
    var args = [_][]const u8{ app.zmx_path, "get", name };
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &args,
        .max_output_bytes = 16 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn startSession(app: *App, name: []const u8, index: usize) !void {
    // zmx attach starts the persistent daemon when the exact session name is
    // absent, and reconnects to it when it already exists.
    _ = try zmxGet(app, name);
    var attach_args = [_][]const u8{ app.zmx_path, "attach", name };
    var child = std.process.Child.init(&attach_args, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    app.surfaces[index].attach = child;
}

fn waitAttachClient(slot: *SurfaceSlot) void {
    if (slot.attach) |*child| {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        slot.attach = null;
    }
}

fn appendTerminalOutput(slot: *SurfaceSlot, bytes: []const u8) void {
    if (bytes.len >= slot.terminal_buffer.len) {
        const tail = bytes[bytes.len - slot.terminal_buffer.len ..];
        @memcpy(&slot.terminal_buffer, tail);
        slot.terminal_buffer_len = slot.terminal_buffer.len;
        return;
    }
    if (slot.terminal_buffer_len + bytes.len > slot.terminal_buffer.len) {
        const overflow =
            slot.terminal_buffer_len + bytes.len - slot.terminal_buffer.len;
        std.mem.copyForwards(
            u8,
            slot.terminal_buffer[0 .. slot.terminal_buffer_len - overflow],
            slot.terminal_buffer[overflow..slot.terminal_buffer_len],
        );
        slot.terminal_buffer_len -= overflow;
    }
    @memcpy(
        slot.terminal_buffer[slot.terminal_buffer_len..][0..bytes.len],
        bytes,
    );
    slot.terminal_buffer_len += bytes.len;
}

fn feedTerminalOutput(app: *App, index: usize, bytes: []const u8) void {
    const slot = &app.surfaces[index];
    const surface = slot.surface orelse return;
    appendTerminalOutput(slot, bytes);
    feedTerminalCells(slot, bytes);
    const cells_result = c.winghostty_surface_set_terminal_cells(
        surface,
        terminal_columns,
        terminal_rows,
        &slot.terminal_cells,
        terminal_cell_count,
    );
    recordProviderError(app, cells_result);
    const text = slot.terminal_buffer[0..slot.terminal_buffer_len];
    const text_result = c.winghostty_surface_notify_accessibility_text(
        surface,
        text.ptr,
        text.len,
        0,
        text.len,
        0,
        0,
        text.len,
    );
    recordProviderError(app, text_result);
    const redraw_result = c.winghostty_surface_notify_redraw(surface);
    recordProviderError(app, redraw_result);
    slot.output_events += 1;
    slot.output_seen = true;
    app.totalOutputEvents += 1;
}

fn clearTerminalCells(slot: *SurfaceSlot) void {
    for (&slot.terminal_cells) |*cell| {
        cell.* = .{
            .codepoint = 0,
            .foreground = 0xE6E6E6,
            .background = 0,
            .flags = 0,
        };
    }
    slot.terminal_x = 0;
    slot.terminal_y = 0;
}

fn terminalAdvanceLine(slot: *SurfaceSlot) void {
    slot.terminal_x = 0;
    if (slot.terminal_y + 1 < terminal_rows) {
        slot.terminal_y += 1;
        return;
    }
    std.mem.copyForwards(
        c.winghostty_terminal_cell,
        slot.terminal_cells[0 .. terminal_cell_count - terminal_columns],
        slot.terminal_cells[terminal_columns..],
    );
    for (slot.terminal_cells[terminal_cell_count - terminal_columns ..]) |*cell| {
        cell.* = .{
            .codepoint = 0,
            .foreground = 0xE6E6E6,
            .background = 0,
            .flags = 0,
        };
    }
}

fn putTerminalCodepoint(slot: *SurfaceSlot, codepoint: u32) void {
    if (slot.terminal_x >= terminal_columns) terminalAdvanceLine(slot);
    slot.terminal_cells[slot.terminal_y * terminal_columns + slot.terminal_x] = .{
        .codepoint = codepoint,
        .foreground = 0xE6E6E6,
        .background = 0,
        .flags = 0,
    };
    slot.terminal_x += 1;
}

fn finishCsi(slot: *SurfaceSlot, final: u8) void {
    const value = if (slot.csi_have_value) slot.csi_value else 1;
    switch (final) {
        'A' => slot.terminal_y -|= value,
        'B' => slot.terminal_y = @min(terminal_rows - 1, slot.terminal_y + value),
        'C' => slot.terminal_x = @min(terminal_columns, slot.terminal_x + value),
        'D' => slot.terminal_x -|= value,
        'G' => slot.terminal_x = @min(terminal_columns, if (slot.csi_have_value) slot.csi_value -| 1 else 0),
        'd' => slot.terminal_y = @min(terminal_rows - 1, if (slot.csi_have_value) slot.csi_value -| 1 else 0),
        'H', 'f' => {
            const row = if (slot.csi_have_value) slot.csi_value else 1;
            slot.terminal_y = @min(terminal_rows - 1, row -| 1);
            slot.terminal_x = 0;
        },
        'J' => if (slot.csi_have_value and slot.csi_value == 2) clearTerminalCells(slot),
        'K' => {
            const start = slot.terminal_y * terminal_columns + slot.terminal_x;
            for (slot.terminal_cells[start..][0..(terminal_columns - slot.terminal_x)]) |*cell| {
                cell.* = .{
                    .codepoint = 0,
                    .foreground = 0xE6E6E6,
                    .background = 0,
                    .flags = 0,
                };
            }
        },
        else => {},
    }
    slot.csi_value = 0;
    slot.csi_have_value = false;
    slot.csi_private = false;
}

fn feedTerminalCells(slot: *SurfaceSlot, bytes: []const u8) void {
    for (bytes) |byte| {
        switch (slot.terminal_parser) {
            .normal => switch (byte) {
                0x1B => slot.terminal_parser = .escape,
                '\r' => slot.terminal_x = 0,
                '\n' => terminalAdvanceLine(slot),
                '\x08' => slot.terminal_x -|= 1,
                '\t' => slot.terminal_x = @min(terminal_columns, (slot.terminal_x + 8) & ~@as(usize, 7)),
                0x20...0x7E => putTerminalCodepoint(slot, byte),
                else => {},
            },
            .escape => switch (byte) {
                '[' => {
                    slot.terminal_parser = .csi;
                    slot.csi_value = 0;
                    slot.csi_have_value = false;
                    slot.csi_private = false;
                },
                ']' => slot.terminal_parser = .osc,
                'c' => {
                    clearTerminalCells(slot);
                    slot.terminal_parser = .normal;
                },
                else => slot.terminal_parser = .normal,
            },
            .csi => switch (byte) {
                '?' => slot.csi_private = true,
                '0'...'9' => {
                    slot.csi_have_value = true;
                    slot.csi_value = @min(9999, slot.csi_value * 10 + (byte - '0'));
                },
                ';' => {},
                0x40...0x7E => {
                    finishCsi(slot, byte);
                    slot.terminal_parser = .normal;
                },
                else => {},
            },
            .osc => if (byte == 0x07) {
                slot.terminal_parser = .normal;
            } else if (byte == 0x1B) {
                slot.terminal_parser = .escape;
            },
        }
    }
}

fn readAttachOutput(app: *App, index: usize) void {
    const slot = &app.surfaces[index];
    const child = slot.attach orelse return;
    const stdout = child.stdout orelse return;
    var available: c.DWORD = 0;
    if (c.PeekNamedPipe(
        @ptrCast(stdout.handle),
        null,
        0,
        null,
        &available,
        null,
    ) == 0) {
        return;
    }
    while (available > 0) {
        var buffer: [4096]u8 = undefined;
        var read: c.DWORD = 0;
        const amount = @min(available, @as(c.DWORD, @intCast(buffer.len)));
        if (c.ReadFile(
            @ptrCast(stdout.handle),
            @ptrCast(&buffer),
            amount,
            &read,
            null,
        ) == 0 or
            read == 0)
        {
            break;
        }
        feedTerminalOutput(app, index, buffer[0..@intCast(read)]);
        if (c.PeekNamedPipe(
            @ptrCast(stdout.handle),
            null,
            0,
            null,
            &available,
            null,
        ) == 0) {
            break;
        }
    }
}

fn createSurface(app: *App, index: usize) !void {
    const name = sessionName(app, index);
    try startSession(app, name, index);

    var options = initializeOptions(app, index);
    const result = c.winghostty_host_create_surface_v2(
        app.host,
        app.hwnd,
        &options,
        &app.surfaces[index].surface,
    );
    if (result != c.WINGHOSTTY_OK or app.surfaces[index].surface == null) {
        waitAttachClient(&app.surfaces[index]);
        return error.WinghosttySurfaceCreateFailed;
    }
    const slot = &app.surfaces[index];
    slot.last_surface = slot.surface;
    slot.session_name = name;
    slot.destroyed = false;
    slot.destroying = false;
    slot.redraws = 0;
    slot.focus_events = 0;
    slot.ime_events = 0;
    slot.clipboard_events = 0;
    slot.output_events = 0;
    slot.input_bytes = 0;
    slot.terminal_buffer_len = 0;
    clearTerminalCells(slot);
    slot.terminal_parser = .normal;
    slot.csi_value = 0;
    slot.csi_have_value = false;
    slot.csi_private = false;
}

// The gate creates two independent complete surfaces through
// winghostty_host_create_surface_v2: surface A and surface B.
fn destroySurface(app: *App, index: usize) void {
    const slot = &app.surfaces[index];
    waitAttachClient(slot);
    if (slot.surface) |surface| {
        slot.destroying = true;
        rememberRetiredSurface(app, surface);
        _ = c.winghostty_surface_destroy(surface);
        slot.surface = null;
        slot.destroyed = true;
        slot.destroying = false;
    }
}

fn recreateSurface(app: *App, index: usize) !void {
    destroySurface(app, index);
    app.recreate_count += 1;
    return createSurface(app, index);
}

fn resizeSurfaces(app: *App, width: i32, height: i32) void {
    const half = @max(1, @divTrunc(width, 2));
    for (&app.surfaces, 0..) |*slot, index| {
        if (slot.surface) |surface| {
            var bounds = c.winghostty_rect{
                .x = if (index == 0) 0 else half,
                .y = 0,
                .width = @intCast(if (index == 0) half else width - half),
                .height = @intCast(@max(1, height)),
            };
            _ = c.winghostty_surface_set_bounds(surface, &bounds);
        }
    }
}

fn sendTypedCommand(app: *App, index: usize, command: []const u8) void {
    const surface = app.surfaces[index].surface orelse return;
    const hwnd = c.winghostty_surface_get_hwnd(surface) orelse return;
    for (command) |byte| {
        _ = c.SendMessageW(hwnd, c.WM_CHAR, @intCast(byte), 0);
    }
    _ = c.SendMessageW(hwnd, c.WM_KEYDOWN, @intCast(c.VK_RETURN), 0);
}

fn runInputContracts(app: *App) !void {
    for (&app.surfaces, 0..) |*slot, index| {
        const surface = slot.surface orelse return error.SurfaceMissing;
        const surface_hwnd =
            c.winghostty_surface_get_hwnd(surface) orelse return error.SurfaceMissing;
        _ = c.winghostty_surface_set_focus(surface, if (index == app.active_surface) 1 else 0);
        _ = c.winghostty_surface_notify_dpi_changed(surface, if (index == 0) 96 else 144);
        _ = c.winghostty_surface_notify_accessibility_name(
            surface,
            if (index == 0) "GraphCode terminal A" else "GraphCode terminal B",
        );
        sendTypedCommand(
            app,
            index,
            if (index == 0)
                "echo GraphCode typed output A"
            else
                "echo GraphCode typed output B",
        );
        _ = c.winghostty_surface_ime_update(surface, "IME", 3, 1);
        _ = c.winghostty_surface_paste_text(surface, "safe paste", 10, 0);
        _ = c.winghostty_surface_write_clipboard(surface, c.WINGHOSTTY_CLIPBOARD_TEXT, "clipboard", 9);
        _ = c.SendMessageW(
            surface_hwnd,
            c.WM_KEYDOWN,
            @intCast(c.VK_RETURN),
            0,
        );
        var copied: [64]u8 = undefined;
        var copied_length: u64 = 0;
        _ = c.winghostty_surface_copy_accessibility_range(
            surface,
            0,
            9,
            &copied,
            copied.len,
            &copied_length,
        );
        const redraw_result = c.winghostty_surface_notify_redraw(surface);
        recordProviderError(app, redraw_result);
    }
}

fn tick(app: *App) void {
    app.tick += 1;
    readAttachOutput(app, 0);
    readAttachOutput(app, 1);
    if (app.tick == 1) {
        _ = runInputContracts(app) catch {};
        if (app.surfaces[1].surface) |surface| {
            _ = c.winghostty_surface_set_focus(surface, 1);
            recordProviderError(app, c.winghostty_surface_notify_redraw(surface));
        }
    }
    if (app.smoke and app.tick == 4) {
        _ = recreateSurface(app, 0) catch {};
        _ = runInputContracts(app) catch {};
    }
    if (app.stress and app.tick >= 6 and app.tick < 6 + 16 * 2 and app.tick % 2 == 0) {
        _ = recreateSurface(app, 0) catch {};
    }
    if (app.smoke and app.tick == 16) {
        _ = c.DestroyWindow(app.hwnd);
    }
}

fn windowProc(hwnd: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    var app = appFromWindow(hwnd);
    if (message == c.WM_NCCREATE) {
        const create = @as(*const c.CREATESTRUCTW, @ptrFromInt(@as(usize, @bitCast(lparam))));
        app = @ptrCast(@alignCast(create.lpCreateParams));
        if (app) |value| {
            value.hwnd = hwnd;
            _ = c.SetWindowLongPtrW(hwnd, gwlp_userdata, @intCast(@intFromPtr(value)));
        }
    }
    const value = app orelse return c.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_SIZE => {
            const bits: usize = @bitCast(lparam);
            resizeSurfaces(
                value,
                @intCast(@as(u16, @truncate(bits))),
                @intCast(@as(u16, @truncate(bits >> 16))),
            );
        },
        c.WM_SETFOCUS => {
            if (value.surfaces[value.active_surface].surface) |surface| {
                _ = c.winghostty_surface_set_focus(surface, 1);
            }
        },
        c.WM_TIMER => if (wparam == timer_id) tick(value),
        c.WM_APP + 41 => tick(value),
        c.WM_CLOSE => {
            _ = c.DestroyWindow(hwnd);
        },
        c.WM_DESTROY => {
            _ = c.KillTimer(hwnd, timer_id);
            _ = c.SetWindowLongPtrW(hwnd, gwlp_userdata, 0);
            c.PostQuitMessage(0);
        },
        c.WM_NCDESTROY => _ = c.SetWindowLongPtrW(hwnd, gwlp_userdata, 0),
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn registerWindowClass(instance: HINSTANCE) !void {
    var window_class: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    window_class.lpfnWndProc = @ptrCast(&windowProc);
    window_class.hInstance = instance;
    window_class.lpszClassName = class_name.ptr;
    window_class.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
    if (c.RegisterClassW(&window_class) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS) {
        return error.WindowClassRegistrationFailed;
    }
}

fn createWindow(app: *App) !void {
    try registerWindowClass(app.instance);
    app.hwnd = c.CreateWindowExW(
        0,
        class_name.ptr,
        window_title.ptr,
        c.WS_OVERLAPPEDWINDOW | c.WS_CLIPCHILDREN,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        980,
        620,
        null,
        null,
        app.instance,
        @ptrCast(app),
    ) orelse return error.WindowCreationFailed;
    _ = c.ShowWindow(app.hwnd, c.SW_SHOW);
    _ = c.UpdateWindow(app.hwnd);
    _ = c.SetTimer(app.hwnd, timer_id, 100, null);
}

fn cleanup(app: *App) void {
    destroySurface(app, 0);
    destroySurface(app, 1);
    if (app.host) |host| {
        _ = c.winghostty_host_deinitialize(host);
        app.host = null;
    }
    if (app.hwnd) |hwnd| {
        if (c.IsWindow(hwnd) != 0) _ = c.DestroyWindow(hwnd);
        app.hwnd = null;
    }
}

fn messageLoop(app: *App) !void {
    var message: c.MSG = undefined;
    while (true) {
        const result = c.GetMessageW(&message, null, 0, 0);
        if (result == 0) break;
        if (result == -1) return error.MessageLoopFailed;
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }
    if (app.callbacksAfterDestroy != 0) return error.CallbackAfterDestroy;
    if (app.smoke and app.lastRenderError != c.WINGHOSTTY_OK) {
        return error.RendererContractFailed;
    }
    if (app.smoke and app.transportFailures != 0) {
        std.debug.print(
            "terminal gate transport failure: {s} count={d}\n",
            .{ app.lastTransportFailure, app.transportFailures },
        );
        return error.AttachTransportFailed;
    }
    if (app.smoke and
        (app.totalOutputEvents == 0 or
            app.totalInputBytes == 0 or
            !app.surfaces[0].input_seen or
            !app.surfaces[0].output_seen or
            !app.surfaces[1].input_seen or
            !app.surfaces[1].output_seen))
    {
        return error.SessionIoContractFailed;
    }
}

fn hasArg(args: []const []const u8, value: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, value)) return true;
    return false;
}

fn valueArg(args: []const []const u8, prefix: []const u8) ?[]const u8 {
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, prefix)) return arg[prefix.len..];
    }
    return null;
}

pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var app = try allocator.create(App);
    defer allocator.destroy(app);
    app.* = .{
        .instance = c.GetModuleHandleW(null),
        .smoke = hasArg(args, "--smoke"),
        .stress = hasArg(args, "--stress"),
        .same_session = hasArg(args, "--same-session"),
        .sameSession = hasArg(args, "--same-session"),
        .zmx_path = valueArg(args, "--zmx=") orelse
            std.process.getEnvVarOwned(allocator, "GRAPHCODE_ZMX") catch "zmx.exe",
        .cwd = std.process.getEnvVarOwned(allocator, "GRAPHCODE_GATE_CWD") catch ".",
    };

    try createWindow(app);
    defer cleanup(app);
    if (c.winghostty_host_initialize(&app.host) != c.WINGHOSTTY_OK) {
        return error.WinghosttyHostInitializeFailed;
    }
    try createSurface(app, 0);
    try createSurface(app, 1);
    app.ready = true;
    if (app.smoke) _ = c.PostMessageW(app.hwnd, wm_gate_tick, 0, 0);
    try messageLoop(app);
}
