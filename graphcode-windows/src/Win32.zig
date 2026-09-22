pub const c = @cImport({
    @cDefine("_WIN32_WINNT", "0x0601");
    @cInclude("windows.h");
    @cInclude("shellapi.h");
    @cInclude("winhttp.h");
    @cInclude("sddl.h");
    @cInclude("winghostty/win32_host.h");
});

/// Win32 uses pointer-shaped types for opaque handles, integer resource IDs,
/// and addresses carried through message integers. Those values do not carry
/// Zig pointer-alignment guarantees.
pub fn opaquePointerFromInt(comptime Pointer: type, value: usize) Pointer {
    @setRuntimeSafety(false);
    return @ptrFromInt(value);
}

pub fn messagePointer(comptime Pointer: type, value: c.LPARAM) Pointer {
    return opaquePointerFromInt(Pointer, @as(usize, @bitCast(value)));
}

pub fn resourceIdentifier(value: usize) [*:0]const u16 {
    return opaquePointerFromInt([*:0]const u16, value);
}

// `_WIN32_WINNT` above is pinned to 0x0601 (Windows 7), which hides the per-monitor
// DPI v2 declarations (`SetProcessDpiAwarenessContext`, `GetDpiForWindow`,
// `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2`) from `windows.h`'s cImport even
// though `user32.dll` on any supported Windows 10+ host exports them. Bumping the
// global WINNT target would ripple into every other Win32 declaration this file
// cImports, so these two entry points are declared directly against `user32`
// instead, using ABI-equivalent pointer-sized integers for the opaque
// `DPI_AWARENESS_CONTEXT` handle.
extern "user32" fn SetProcessDpiAwarenessContext(value: usize) callconv(.winapi) c.BOOL;
extern "user32" fn GetDpiForWindow(hwnd: c.HWND) callconv(.winapi) c.UINT;

const dpi_awareness_context_per_monitor_aware_v2: usize = @bitCast(@as(isize, -4));

/// Opts this process into per-monitor-v2 DPI awareness. Must run before any window
/// (including a hidden single-instance-detection window) is created; without this,
/// Windows treats the process as system-DPI-aware and bitmap-stretches the whole UI
/// on a DPI change instead of delivering `WM_DPICHANGED` with real per-monitor data.
pub fn enablePerMonitorDpiAwareness() void {
    _ = SetProcessDpiAwarenessContext(dpi_awareness_context_per_monitor_aware_v2);
}

/// Queries the real, current DPI for a specific window from Windows itself (used at
/// startup to seed initial DPI state before any `WM_DPICHANGED` has been delivered).
pub fn dpiForWindow(hwnd: c.HWND) u32 {
    return @intCast(GetDpiForWindow(hwnd));
}

test "Win32 pointer-shaped integers tolerate unaligned values" {
    const std = @import("std");
    const unaligned: usize = 0x0002_0311;
    const odd: usize = 0x000b_0b0b;

    try std.testing.expectEqual(unaligned, @intFromPtr(opaquePointerFromInt(c.HANDLE, unaligned)));
    try std.testing.expectEqual(odd, @intFromPtr(opaquePointerFromInt(c.HMENU, odd)));
    try std.testing.expectEqual(
        unaligned,
        @intFromPtr(messagePointer(*const c.RECT, @as(c.LPARAM, @bitCast(unaligned)))),
    );
    try std.testing.expectEqual(
        odd,
        @intFromPtr(messagePointer(*const c.CREATESTRUCTW, @as(c.LPARAM, @bitCast(odd)))),
    );
    try std.testing.expectEqual(odd, @intFromPtr(resourceIdentifier(odd)));
}
