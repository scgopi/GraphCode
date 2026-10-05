const std = @import("std");
const GdiplusAA = @import("GdiplusAA.zig");
const c = @import("Win32.zig").c;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeGdiplusStartupTest");
const title = std.unicode.utf8ToUtf16LeStringLiteral("GraphCode GDI+ startup test");

const BlockingStartup = struct {
    pub fn run() ?usize {
        while (true) std.Thread.sleep(std.time.ns_per_s);
    }
};

fn windowProc(
    hwnd: c.HWND,
    message: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    if (message == c.WM_DESTROY) {
        c.PostQuitMessage(0);
        return 0;
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

pub fn main() !void {
    GdiplusAA.initWith(BlockingStartup);

    const instance = c.GetModuleHandleW(null);
    var klass: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    klass.lpfnWndProc = &windowProc;
    klass.hInstance = instance;
    klass.lpszClassName = class_name.ptr;
    if (c.RegisterClassW(&klass) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.WindowClassRegistrationFailed;

    const hwnd = c.CreateWindowExW(
        0,
        class_name.ptr,
        title.ptr,
        c.WS_OVERLAPPEDWINDOW,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        640,
        480,
        null,
        null,
        instance,
        null,
    ) orelse return error.WindowCreationFailed;
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.UpdateWindow(hwnd);

    var message: c.MSG = undefined;
    while (c.GetMessageW(&message, null, 0, 0) > 0) {
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }
}
