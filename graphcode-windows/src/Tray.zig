const std = @import("std");
const c = @import("Win32.zig").c;

pub const command_open: c.WPARAM = 0x5001;
pub const command_exit: c.WPARAM = 0x5002;
pub const icon_id: c.UINT = 1;
pub const notify_message: c.UINT = c.WM_APP + 77;
pub const test_hook_open: c.WPARAM = 1;
pub const test_hook_context: c.WPARAM = 2;
pub var taskbar_created: c.UINT = 0;
pub var test_hook_message: c.UINT = 0;
const test_callback_property = std.unicode.utf8ToUtf16LeStringLiteral("GraphCode.Windows.TrayCallback");

pub const Tray = struct {
    hwnd: c.HWND = null,
    menu: c.HMENU = null,
    added: bool = false,
    test_hook_enabled: bool = false,

    pub fn add(self: *Tray, hwnd: c.HWND) !void {
        self.hwnd = hwnd;
        registerMessages();
        self.menu = c.CreatePopupMenu();
        if (self.menu == null) return error.TrayMenuFailed;
        const open = std.unicode.utf8ToUtf16LeStringLiteral("Open GraphCode");
        const exit = std.unicode.utf8ToUtf16LeStringLiteral("Exit");
        if (c.AppendMenuW(self.menu, c.MF_STRING, command_open, open.ptr) == 0 or
            c.AppendMenuW(self.menu, c.MF_STRING, command_exit, exit.ptr) == 0)
        {
            self.remove();
            return error.TrayMenuFailed;
        }
        var data: c.NOTIFYICONDATAW = std.mem.zeroes(c.NOTIFYICONDATAW);
        data.cbSize = @sizeOf(c.NOTIFYICONDATAW);
        data.hWnd = hwnd;
        data.uID = icon_id;
        data.uFlags = c.NIF_MESSAGE | c.NIF_TIP | c.NIF_ICON;
        data.uCallbackMessage = notify_message;
        data.hIcon = c.LoadIconW(null, @ptrFromInt(32512));
        const tip = std.unicode.utf8ToUtf16LeStringLiteral("GraphCode");
        @memcpy(data.szTip[0..tip.len], tip);
        if (c.Shell_NotifyIconW(c.NIM_ADD, &data) == 0) {
            self.remove();
            return error.TrayIconFailed;
        }
        data.unnamed_0.uVersion = c.NOTIFYICON_VERSION_4;
        _ = c.Shell_NotifyIconW(c.NIM_SETVERSION, &data);
        self.added = true;
    }

    pub fn readd(self: *Tray) void {
        if (self.hwnd != null) {
            self.remove();
            _ = self.add(self.hwnd) catch {};
        }
    }

    pub fn remove(self: *Tray) void {
        if (self.added) {
            var data: c.NOTIFYICONDATAW = std.mem.zeroes(c.NOTIFYICONDATAW);
            data.cbSize = @sizeOf(c.NOTIFYICONDATAW);
            data.hWnd = self.hwnd;
            data.uID = icon_id;
            _ = c.Shell_NotifyIconW(c.NIM_DELETE, &data);
            self.added = false;
        }
        if (self.menu != null) _ = c.DestroyMenu(self.menu);
        self.menu = null;
        if (self.test_hook_enabled) {
            _ = c.RemovePropW(self.hwnd, test_callback_property.ptr);
        }
    }

    pub fn showMenu(self: *Tray) void {
        if (self.menu == null) return;
        var point: c.POINT = undefined;
        _ = c.GetCursorPos(&point);
        _ = c.SetForegroundWindow(self.hwnd);
        _ = c.TrackPopupMenu(self.menu, c.TPM_RIGHTALIGN | c.TPM_BOTTOMALIGN, point.x, point.y, 0, self.hwnd, null);
        _ = c.PostMessageW(self.hwnd, c.WM_NULL, 0, 0);
    }

    pub fn observeTestCallback(self: *Tray, event: c.UINT) void {
        if (self.test_hook_enabled) {
            _ = c.SetPropW(self.hwnd, test_callback_property.ptr, @ptrFromInt(@as(usize, event)));
        }
    }
};

pub fn notificationEvent(lparam: c.LPARAM) c.UINT {
    const raw: usize = @bitCast(lparam);
    return @intCast(raw & 0xffff);
}

pub fn callbackTargetsIcon(lparam: c.LPARAM) bool {
    const raw: usize = @bitCast(lparam);
    const callback_icon_id = (raw >> 16) & 0xffff;
    return callback_icon_id == 0 or callback_icon_id == icon_id;
}

pub fn testNotificationLParam(event: c.UINT) c.LPARAM {
    return @intCast((@as(usize, icon_id) << 16) | event);
}

fn registerMessages() void {
    if (taskbar_created == 0) {
        taskbar_created = c.RegisterWindowMessageW(
            std.unicode.utf8ToUtf16LeStringLiteral("TaskbarCreated").ptr,
        );
    }
    if (test_hook_message == 0) {
        test_hook_message = c.RegisterWindowMessageW(
            std.unicode.utf8ToUtf16LeStringLiteral("GraphCode.Windows.TrayTestHook").ptr,
        );
    }
}
