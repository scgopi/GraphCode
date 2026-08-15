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

const SurfaceSlot = struct {
    surface: ?*c.winghostty_surface = null,
    session_name: []const u8 = "",
    attach: ?std.process.Child = null,
    destroying: bool = false,
    destroyed: bool = false,
    redraws: usize = 0,
    focus_events: usize = 0,
    ime_events: usize = 0,
    clipboard_events: usize = 0,
    output_events: usize = 0,
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
    sameSession: bool = false,
    active_surface: usize = 0,
    ready: bool = false,
};

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeTerminalGate");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("GraphCode Windows terminal gate");
const gate_environment = "TERM=xterm-256color";
// The attach client is deliberately the real provider command: `zmx attach <name>`.
// std.process.Child maps to CreateProcessW and owns the child handles.
const wm_gate_tick: UINT = c.WM_APP + 41;
const timer_id: usize = 41;
const gwlp_userdata: i32 = -21;
const swp_nozorder: UINT = 0x0004;
const swp_noactivate: UINT = 0x0010;

fn appFromWindow(hwnd: HWND) ?*App {
    const value = c.GetWindowLongPtrW(hwnd, gwlp_userdata);
    if (value == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(value)));
}

fn appFromUserData(user_data: ?*anyopaque) ?*App {
    return if (user_data) |value| @ptrCast(@alignCast(value)) else null;
}

fn slotForSurface(app: *App, surface: *c.winghostty_surface) ?*SurfaceSlot {
    for (&app.surfaces) |*slot| {
        if (slot.surface == surface) return slot;
    }
    return null;
}

fn onRedraw(user_data: ?*anyopaque, surface: *c.winghostty_surface) callconv(.c) void {
    const app = appFromUserData(user_data) orelse return;
    const slot = slotForSurface(app, surface) orelse return;
    if (slot.destroyed or slot.destroying) {
        app.callbacksAfterDestroy += 1;
        return;
    }
    slot.redraws += 1;
}

fn onFocus(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    focused: u8,
) callconv(.c) void {
    const app = appFromUserData(user_data) orelse return;
    const slot = slotForSurface(app, surface) orelse return;
    if (slot.destroyed or slot.destroying) {
        app.callbacksAfterDestroy += 1;
        return;
    }
    slot.focus_events += 1;
    if (focused != 0) {
        for (&app.surfaces) |*other| {
            if (other.surface) |other_surface| {
                if (other_surface != surface) {
                    _ = c.winghostty_surface_set_focus(other_surface, 0);
                }
            }
        }
    }
}

fn onImeUpdate(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    text: [*:0]const u8,
    length: u32,
    committed: u8,
) callconv(.c) void {
    _ = text;
    _ = length;
    _ = committed;
    const app = appFromUserData(user_data) orelse return;
    const slot = slotForSurface(app, surface) orelse return;
    if (slot.destroyed or slot.destroying) {
        app.callbacksAfterDestroy += 1;
        return;
    }
    slot.ime_events += 1;
}

fn onClipboardWrite(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    format: u32,
    text: [*:0]const u8,
    length: u32,
) callconv(.c) void {
    _ = format;
    _ = text;
    _ = length;
    const app = appFromUserData(user_data) orelse return;
    const slot = slotForSurface(app, surface) orelse return;
    if (slot.destroyed or slot.destroying) {
        app.callbacksAfterDestroy += 1;
        return;
    }
    slot.clipboard_events += 1;
}

fn onExit(
    user_data: ?*anyopaque,
    surface: ?*c.winghostty_surface,
    status: i32,
) callconv(.c) void {
    _ = status;
    const app = appFromUserData(user_data) orelse return;
    const slot = slotForSurface(app, surface orelse return) orelse return;
    if (slot.destroyed or slot.destroying) app.callbacksAfterDestroy += 1;
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

fn noOpKey(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    event: *const c.winghostty_key_event,
) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = event;
}

fn noOpText(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    text: [*:0]const u8,
    length: u32,
) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = text;
    _ = length;
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

fn noOpClipboardRead(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    format: u32,
    text: [*:0]const u8,
    length: u32,
) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = format;
    _ = text;
    _ = length;
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
    options.input_callbacks.on_key = @ptrCast(&noOpKey);
    options.input_callbacks.on_text = @ptrCast(&noOpText);
    options.input_callbacks.on_ime_start = @ptrCast(&noOpImeStart);
    options.input_callbacks.on_ime_update = @ptrCast(&onImeUpdate);
    options.input_callbacks.on_ime_end = @ptrCast(&noOpImeEnd);
    options.input_callbacks.on_mouse = @ptrCast(&noOpMouse);
    options.input_callbacks.on_selection = @ptrCast(&noOpSelection);
    options.input_callbacks.on_link = @ptrCast(&noOpLink);
    options.input_callbacks.on_paste = @ptrCast(&noOpPaste);
    options.input_callbacks.on_clipboard_read = @ptrCast(&noOpClipboardRead);
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
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    app.surfaces[index].attach = child;
}

fn stopSessionClient(slot: *SurfaceSlot) void {
    if (slot.attach) |*child| {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        slot.attach = null;
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
        stopSessionClient(&app.surfaces[index]);
        return error.WinghosttySurfaceCreateFailed;
    }
    app.surfaces[index].session_name = name;
    app.surfaces[index].destroyed = false;
    app.surfaces[index].destroying = false;
    app.surfaces[index].redraws = 0;
    app.surfaces[index].focus_events = 0;
    app.surfaces[index].ime_events = 0;
    app.surfaces[index].clipboard_events = 0;
    app.surfaces[index].output_events = 0;
}

// The gate creates two independent complete surfaces through
// winghostty_host_create_surface_v2: surface A and surface B.
fn destroySurface(app: *App, index: usize, keep_session: bool) void {
    const slot = &app.surfaces[index];
    if (slot.surface) |surface| {
        slot.destroying = true;
        _ = c.winghostty_surface_destroy(surface);
        slot.surface = null;
        slot.destroyed = true;
        slot.destroying = false;
    }
    if (!keep_session) stopSessionClient(slot);
}

fn recreateSurface(app: *App, index: usize) !void {
    destroySurface(app, index, true);
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

fn runInputContracts(app: *App) !void {
    for (&app.surfaces, 0..) |*slot, index| {
        const surface = slot.surface orelse return error.SurfaceMissing;
        _ = c.winghostty_surface_set_focus(surface, if (index == app.active_surface) 1 else 0);
        _ = c.winghostty_surface_notify_dpi_changed(surface, if (index == 0) 96 else 144);
        _ = c.winghostty_surface_notify_terminal_text(
            surface,
            if (index == 0) "GraphCode A\r\nsimultaneous output" else "GraphCode B\r\nsimultaneous output",
            if (index == 0) 35 else 35,
            0,
            35,
            0,
            35,
            35,
        );
        _ = c.winghostty_surface_notify_accessibility_name(
            surface,
            if (index == 0) "GraphCode terminal A" else "GraphCode terminal B",
        );
        _ = c.winghostty_surface_ime_update(surface, "IME", 3, 1);
        _ = c.winghostty_surface_paste_text(surface, "safe paste", 10, 0);
        _ = c.winghostty_surface_write_clipboard(surface, c.WINGHOSTTY_CLIPBOARD_TEXT, "clipboard", 9);
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
        _ = c.winghostty_surface_notify_redraw(surface);
        slot.output_events += 1;
    }
}

fn tick(app: *App) void {
    app.tick += 1;
    if (app.tick == 1) {
        _ = runInputContracts(app) catch {};
        app.active_surface = 1;
        if (app.surfaces[1].surface) |surface| {
            _ = c.winghostty_surface_set_focus(surface, 1);
            _ = c.winghostty_surface_notify_redraw(surface);
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
    destroySurface(app, 0, false);
    destroySurface(app, 1, false);
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
