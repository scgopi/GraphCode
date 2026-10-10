const std = @import("std");
const Win32 = @import("Win32.zig");
const c = Win32.c;

// Tearing a modal down has an ordering contract that is easy to get wrong.
//
// While a modal is up its owner is disabled via EnableWindow(owner, 0). If the
// modal is destroyed while the owner is still disabled, the window manager
// looks for somewhere to hand activation, finds the owner ineligible, and picks
// an unrelated top-level window instead -- frequently one belonging to another
// process. Two user-visible symptoms follow: focus jumps to a foreign
// application, and the shell's own main window is momentarily left carrying
// WS_DISABLED, which makes Win32 treat it as unable to accept a caption close.
//
// Re-enabling the owner first makes the owner eligible to inherit activation at
// the moment the modal is destroyed, so neither symptom occurs.
//
// See "The correct order for disabling and enabling windows":
// https://devblogs.microsoft.com/oldnewthing/20040227-00/?p=40463

/// The Win32 surface used during teardown, injected so the ordering contract
/// can be asserted without creating real windows.
pub const RealApi = struct {
    pub fn enableWindow(window: c.HWND, enabled: c_int) void {
        _ = c.EnableWindow(window, enabled);
    }

    pub fn destroyWindow(window: c.HWND) void {
        _ = c.DestroyWindow(window);
    }

    pub fn setActiveWindow(window: c.HWND) void {
        _ = c.SetActiveWindow(window);
    }
};

pub fn dismissWith(comptime Api: type, dialog: c.HWND, owner: c.HWND) void {
    Api.enableWindow(owner, 1);
    Api.destroyWindow(dialog);
    Api.setActiveWindow(owner);
}

/// Dismiss a modal window and return activation to its owner.
pub fn dismiss(dialog: c.HWND, owner: c.HWND) void {
    dismissWith(RealApi, dialog, owner);
    if (after_dismiss) |hook| hook(after_dismiss_context, owner);
}

/// Told, after every real modal is gone and its owner is active again, which window that was.
/// The shell uses it to put keyboard focus back where the user was typing, because the owner
/// itself can be left holding the focus, which sends terminal keys to the wrong window.
pub var after_dismiss: ?*const fn (context: ?*anyopaque, owner: c.HWND) void = null;
pub var after_dismiss_context: ?*anyopaque = null;

const Call = enum { enable_owner, destroy_dialog, activate_owner };

var recorded: [8]Call = undefined;
var recorded_len: usize = 0;
var recorded_owner_enabled_at_destroy: ?bool = null;
var recorded_owner_enabled: bool = false;

fn record(call: Call) void {
    if (recorded_len >= recorded.len) unreachable;
    recorded[recorded_len] = call;
    recorded_len += 1;
}

fn resetRecording() void {
    recorded_len = 0;
    recorded_owner_enabled = false;
    recorded_owner_enabled_at_destroy = null;
}

const RecordingApi = struct {
    pub fn enableWindow(window: c.HWND, enabled: c_int) void {
        _ = window;
        recorded_owner_enabled = enabled != 0;
        record(.enable_owner);
    }

    pub fn destroyWindow(window: c.HWND) void {
        _ = window;
        recorded_owner_enabled_at_destroy = recorded_owner_enabled;
        record(.destroy_dialog);
    }

    pub fn setActiveWindow(window: c.HWND) void {
        _ = window;
        record(.activate_owner);
    }
};

fn fakeWindow(value: usize) c.HWND {
    @setRuntimeSafety(false);
    return @ptrFromInt(value);
}

test "modal teardown re-enables the owner before destroying the dialog" {
    resetRecording();

    dismissWith(RecordingApi, fakeWindow(0x2000), fakeWindow(0x1000));

    try std.testing.expectEqualSlices(
        Call,
        &.{ .enable_owner, .destroy_dialog, .activate_owner },
        recorded[0..recorded_len],
    );
}

test "owner is already enabled at the moment the modal is destroyed" {
    resetRecording();

    dismissWith(RecordingApi, fakeWindow(0x2000), fakeWindow(0x1000));

    // This is the property that actually matters: if the owner were still
    // disabled here, the window manager would hand activation to an unrelated
    // window and leave the shell's main window transiently WS_DISABLED.
    try std.testing.expect(recorded_owner_enabled_at_destroy != null);
    try std.testing.expect(recorded_owner_enabled_at_destroy.?);
}

test "the real teardown tells the shell which owner was reactivated, after the dialog is gone" {
    const Probe = struct {
        var owner: c.HWND = null;
        var dialog_alive_at_call = true;
        var calls: usize = 0;
        var dialog: c.HWND = null;

        fn hook(_: ?*anyopaque, window: c.HWND) void {
            owner = window;
            calls += 1;
            dialog_alive_at_call = c.IsWindow(dialog) != 0;
        }
    };
    const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const title = std.unicode.utf8ToUtf16LeStringLiteral("modal teardown hook");
    const instance = c.GetModuleHandleW(null);
    const owner = c.CreateWindowExW(0, class, title, c.WS_OVERLAPPED, 0, 0, 100, 100, null, null, instance, null) orelse
        return error.WindowCreationFailed;
    defer _ = c.DestroyWindow(owner);
    Probe.dialog = c.CreateWindowExW(0, class, title, c.WS_OVERLAPPED, 0, 0, 100, 100, owner, null, instance, null) orelse
        return error.WindowCreationFailed;
    after_dismiss = &Probe.hook;
    defer after_dismiss = null;
    Probe.calls = 0;
    dismiss(Probe.dialog, owner);
    try std.testing.expectEqual(@as(usize, 1), Probe.calls);
    try std.testing.expect(Probe.owner == owner);
    try std.testing.expect(!Probe.dialog_alive_at_call);
}