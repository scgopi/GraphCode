const std = @import("std");
const c = @import("Win32.zig").c;

pub const MessageCallback = *const fn (
    context: ?*anyopaque,
    hwnd: c.HWND,
    message: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
    result: *c.LRESULT,
) callconv(.c) bool;

pub const Window = struct {
    hwnd: c.HWND = null,
    instance: c.HINSTANCE = null,
    context: ?*anyopaque = null,
    callback: ?MessageCallback = null,
    class_name: [*:0]const u16 = class_name.ptr,

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
        _ = c.ShowWindow(self.hwnd, c.SW_SHOW);
        _ = c.UpdateWindow(self.hwnd);
        _ = c.SetTimer(self.hwnd, timer_id, 100, null);
    }

    pub fn destroy(self: *Window) void {
        if (self.hwnd != null and c.IsWindow(self.hwnd) != 0) {
            _ = c.DestroyWindow(self.hwnd);
        }
        self.hwnd = null;
    }

    pub fn messageLoop(self: *Window) !void {
        _ = self;
        var message: c.MSG = undefined;
        while (true) {
            const result = c.GetMessageW(&message, null, 0, 0);
            if (result == 0) break;
            if (result == -1) return error.MessageLoopFailed;
            _ = c.TranslateMessage(&message);
            _ = c.DispatchMessageW(&message);
        }
    }
};

pub const timer_id: usize = 41;
pub const wm_app_tick: c.UINT = c.WM_APP + 41;
pub var restore_message: c.UINT = 0;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeWindowsShell");

pub fn restoreExistingInstance() void {
    const hwnd = c.FindWindowW(class_name.ptr, null);
    const message = c.RegisterWindowMessageW(std.unicode.utf8ToUtf16LeStringLiteral("GraphCode.Windows.Restore").ptr);
    if (hwnd != null and message != 0) {
        var process_id: c.DWORD = 0;
        _ = c.GetWindowThreadProcessId(hwnd, &process_id);
        if (process_id != 0) _ = c.AllowSetForegroundWindow(process_id);
        _ = c.PostMessageW(hwnd, message, 0, 0);
    }
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
    window_class.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
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
        const create = @as(*const c.CREATESTRUCTW, @ptrFromInt(@as(usize, @bitCast(lparam))));
        window = @ptrCast(@alignCast(create.lpCreateParams));
        if (window) |value| {
            value.hwnd = hwnd;
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @intCast(@intFromPtr(value)));
        }
    }
    const value = window orelse return c.DefWindowProcW(hwnd, message, wparam, lparam);
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
