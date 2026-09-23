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
}

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
