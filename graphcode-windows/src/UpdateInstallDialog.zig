const std = @import("std");
const Win32 = @import("Win32.zig");
const c = Win32.c;
const ModalTeardown = @import("ModalTeardown.zig");
const AppFont = @import("AppFont.zig");
const WindowsUpdateInstall = @import("WindowsUpdateInstall.zig");

/// The in-window install-progress indicator and the post-install relaunch
/// prompt, combined into one native window: the same window that showed
/// "Downloading update… 42%" a moment ago becomes "Update installed" with
/// Relaunch Now / Later once `GraphCode-Setup.ps1 -Command Upgrade` returns.
/// One window rather than two separate dialogs because there is exactly one
/// install in flight at a time and the transition between them is the whole
/// point of the row this satisfies (macOS shows the same two moments as
/// separate alerts; this is one window that changes what it says).
pub const RelaunchAction = enum { relaunch_now, later };
pub const Outcome = union(enum) {
    relaunch: RelaunchAction,
    /// The user cancelled before the install finished.
    cancelled,
    /// Installation failed; carries a human-readable reason.
    failed: []const u8,
};

// ---------------------------------------------------------------------------
// Pure presentation logic — unit tested without any window.
// ---------------------------------------------------------------------------

/// Formats the progress line shown while downloading/verifying/extracting/
/// installing. Percent is only meaningful during `.downloading` (the only
/// phase with a known denominator); the other phases are indeterminate, so
/// they say what's happening without implying a fake percentage.
pub fn formatProgressText(buffer: []u8, phase: WindowsUpdateInstall.Phase, fraction: f64) ![]u8 {
    return switch (phase) {
        .downloading => std.fmt.bufPrint(buffer, "Downloading update… {d}%", .{@as(u32, @intFromFloat(@min(@max(fraction, 0), 1) * 100))}),
        .verifying => std.fmt.bufPrint(buffer, "Verifying download…", .{}),
        .extracting => std.fmt.bufPrint(buffer, "Extracting update…", .{}),
        .installing => std.fmt.bufPrint(buffer, "Installing…", .{}),
    };
}

/// The exact wording an install failure surfaces, kept as a pure mapping so
/// it can be asserted without ever triggering a real failure.
pub fn failureMessage(err: WindowsUpdateInstall.InstallError) []const u8 {
    return switch (err) {
        error.Cancelled => "The update was cancelled.",
        error.ChecksumUnavailable => "GraphCode couldn't confirm the download's checksum.",
        error.ChecksumMismatch => "The downloaded file didn't match its published checksum.",
        error.DownloadFailed => "The download failed.",
        error.ExtractionFailed => "The downloaded package couldn't be extracted.",
        error.ExtractionTimedOut => "Extracting the update took too long and was stopped.",
        error.SetupScriptMissing => "The downloaded package is missing its setup script.",
        error.UpgradeFailed => "Installing the update failed. The previous installation was kept.",
        error.UpgradeTimedOut => "Installing the update took too long and was stopped.",
        error.OutOfMemory => "GraphCode ran out of memory while installing the update.",
    };
}

/// Session-continuity copy for the relaunch prompt, matching the macOS
/// wording's substance: the daemon and zmx-backed terminal sessions are
/// independent of the GUI process and survive a relaunch.
pub const relaunch_message =
    "GraphCode is installed and takes over on the next launch. Sessions keep " ++
    "running through a relaunch — the background daemon holds them, not this window.";

// ---------------------------------------------------------------------------
// Native window — exercised live, not by fixture-driven unit tests: there is
// nothing meaningful to fake about a real download/extract/install cycle.
// ---------------------------------------------------------------------------

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeUpdateInstall");
const cancel_id: u16 = 9711;
const relaunch_id: u16 = 9712;
const later_id: u16 = 9713;
const close_id: u16 = 9714;
const tick_message: c.UINT = c.WM_APP + 1;

const Stage = enum { progress, relaunch, failed };

const State = struct {
    allocator: std.mem.Allocator,
    stage: Stage = .progress,
    outcome: ?Outcome = null,
    closed: bool = false,
    cancel_requested: bool = false,
    status_hwnd: c.HWND = null,
    button_hwnd: [2]c.HWND = .{ null, null },
};

var active = false;
var active_state: State = undefined;
var active_hwnd: c.HWND = null;

var shared_phase = std.atomic.Value(u8).init(0);
var shared_fraction_bits = std.atomic.Value(u64).init(0);
var shared_done = std.atomic.Value(bool).init(false);
var shared_failed = std.atomic.Value(bool).init(false);
var shared_failure_buffer: [256]u8 = undefined;
var shared_failure_len = std.atomic.Value(usize).init(0);
var shared_cancelled = std.atomic.Value(bool).init(false);

fn reportProgress(phase: WindowsUpdateInstall.Phase, fraction: f64) void {
    shared_phase.store(@intFromEnum(phase), .release);
    shared_fraction_bits.store(@bitCast(fraction), .release);
    if (active_hwnd) |hwnd| _ = c.PostMessageW(hwnd, tick_message, 0, 0);
}

fn worker(options: WindowsUpdateInstall.InstallOptions) void {
    WindowsUpdateInstall.install(options) catch |err| {
        const message = failureMessage(err);
        const len = @min(message.len, shared_failure_buffer.len);
        @memcpy(shared_failure_buffer[0..len], message[0..len]);
        shared_failure_len.store(len, .release);
        shared_failed.store(true, .release);
        shared_done.store(true, .release);
        if (active_hwnd) |hwnd| _ = c.PostMessageW(hwnd, tick_message, 0, 0);
        return;
    };
    shared_done.store(true, .release);
    if (active_hwnd) |hwnd| _ = c.PostMessageW(hwnd, tick_message, 0, 0);
}

/// Runs the progress window, blocking until the install finishes (or is
/// cancelled), then presents Relaunch Now/Later on success or an error state
/// on failure, and blocks again until the user picks a next step. Returns
/// once the window has been dismissed.
pub fn run(
    parent: c.HWND,
    allocator: std.mem.Allocator,
    asset_url: []const u8,
    expected_sha256: ?[]const u8,
    checksum_url: ?[]const u8,
) !Outcome {
    registerClass() catch return error.DialogClassRegistrationFailed;
    active_state = .{ .allocator = allocator };
    active = true;
    shared_phase.store(0, .release);
    shared_fraction_bits.store(@bitCast(@as(f64, 0)), .release);
    shared_done.store(false, .release);
    shared_failed.store(false, .release);
    shared_cancelled.store(false, .release);

    const title = try wideZ(allocator, "GraphCode Update");
    defer allocator.free(title);
    const hwnd = c.CreateWindowExW(
        c.WS_EX_DLGMODALFRAME | c.WS_EX_CONTROLPARENT,
        class_name.ptr,
        title.ptr,
        c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        460,
        180,
        parent,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse {
        active = false;
        return error.DialogCreationFailed;
    };
    active_hwnd = hwnd;
    _ = c.EnableWindow(parent, 0);
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.SetForegroundWindow(hwnd);

    const options = WindowsUpdateInstall.InstallOptions{
        .allocator = allocator,
        .asset_url = asset_url,
        .expected_sha256 = expected_sha256,
        .checksum_url = checksum_url,
        .cancelled = &shared_cancelled,
        .progress = &reportProgress,
    };
    const thread = try std.Thread.spawn(.{}, worker, .{options});

    var message: c.MSG = undefined;
    while (!active_state.closed) {
        const code = c.GetMessageW(&message, null, 0, 0);
        if (code <= 0) {
            active_state.closed = true;
            break;
        }
        if (c.IsDialogMessageW(hwnd, &message) != 0) continue;
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }
    thread.join();
    ModalTeardown.dismiss(hwnd, parent);
    active_hwnd = null;
    active = false;
    return active_state.outcome orelse .{ .failed = "The update window closed unexpectedly." };
}

fn registerClass() !void {
    var klass: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    klass.lpfnWndProc = @ptrCast(&windowProc);
    klass.hInstance = c.GetModuleHandleW(null);
    klass.lpszClassName = class_name.ptr;
    klass.hCursor = c.LoadCursorW(null, Win32.resourceIdentifier(32512));
    if (c.RegisterClassW(&klass) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.DialogClassRegistrationFailed;
}

fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (!active) return c.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_CREATE => {
            active_state.status_hwnd = createStatic(hwnd, active_state.allocator, "Preparing…", 18, 20, 420, 24);
            active_state.button_hwnd[0] = createButton(hwnd, "Cancel", cancel_id, 320, 90);
            return 0;
        },
        tick_message => {
            onTick(hwnd);
            return 0;
        },
        c.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            switch (command) {
                cancel_id => {
                    active_state.cancel_requested = true;
                    shared_cancelled.store(true, .release);
                    setStatusText(active_state.status_hwnd, active_state.allocator, "Cancelling…");
                    if (active_state.button_hwnd[0]) |button| _ = c.EnableWindow(button, 0);
                },
                relaunch_id => {
                    active_state.outcome = .{ .relaunch = .relaunch_now };
                    requestClose(hwnd);
                },
                later_id => {
                    active_state.outcome = .{ .relaunch = .later };
                    requestClose(hwnd);
                },
                close_id => {
                    requestClose(hwnd);
                },
                else => {},
            }
            return 0;
        },
        c.WM_CLOSE => {
            if (active_state.stage == .progress) {
                active_state.cancel_requested = true;
                shared_cancelled.store(true, .release);
                return 0; // Wait for the worker to actually stop before closing.
            }
            requestClose(hwnd);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn onTick(hwnd: c.HWND) void {
    if (active_state.stage != .progress) return;
    if (shared_done.load(.acquire)) {
        if (shared_failed.load(.acquire)) {
            const len = shared_failure_len.load(.acquire);
            const message = active_state.allocator.dupe(u8, shared_failure_buffer[0..len]) catch shared_failure_buffer[0..len];
            active_state.stage = .failed;
            if (active_state.cancel_requested) {
                active_state.outcome = .cancelled;
                requestClose(hwnd);
                return;
            }
            active_state.outcome = .{ .failed = message };
            transitionToFailed(hwnd, message);
        } else {
            active_state.stage = .relaunch;
            transitionToRelaunch(hwnd);
        }
        return;
    }
    const phase: WindowsUpdateInstall.Phase = @enumFromInt(shared_phase.load(.acquire));
    const fraction: f64 = @bitCast(shared_fraction_bits.load(.acquire));
    var buffer: [64]u8 = undefined;
    const text = formatProgressText(&buffer, phase, fraction) catch "Working…";
    setStatusText(active_state.status_hwnd, active_state.allocator, text);
}

fn transitionToRelaunch(hwnd: c.HWND) void {
    if (active_state.button_hwnd[0]) |button| _ = c.DestroyWindow(button);
    setStatusText(active_state.status_hwnd, active_state.allocator, "Update installed. " ++ relaunch_message);
    active_state.button_hwnd[0] = createButton(hwnd, "Relaunch Now", relaunch_id, 220, 90);
    active_state.button_hwnd[1] = createButton(hwnd, "Later", later_id, 350, 90);
}

fn transitionToFailed(hwnd: c.HWND, message: []const u8) void {
    if (active_state.button_hwnd[0]) |button| _ = c.DestroyWindow(button);
    setStatusText(active_state.status_hwnd, active_state.allocator, message);
    active_state.button_hwnd[0] = createButton(hwnd, "Close", close_id, 350, 90);
}

fn requestClose(hwnd: c.HWND) void {
    active_state.closed = true;
    _ = c.PostMessageW(hwnd, c.WM_NULL, 0, 0);
}

fn setStatusText(hwnd: c.HWND, allocator: std.mem.Allocator, text: []const u8) void {
    if (hwnd == null) return;
    const wide = wideZ(allocator, text) catch return;
    defer allocator.free(wide);
    _ = c.SetWindowTextW(hwnd, wide.ptr);
}

fn createStatic(hwnd: c.HWND, allocator: std.mem.Allocator, text: []const u8, x: i32, y: i32, width: i32, height: i32) c.HWND {
    const wide = wideZ(allocator, text) catch return null;
    defer allocator.free(wide);
    const control = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr,
        wide.ptr,
        c.WS_CHILD | c.WS_VISIBLE | c.SS_LEFT,
        x,
        y,
        width,
        height,
        hwnd,
        null,
        c.GetModuleHandleW(null),
        null,
    );
    AppFont.apply(control, AppFont.control_size, false);
    return control;
}

fn createButton(hwnd: c.HWND, label: []const u8, id: u16, x: i32, y: i32) c.HWND {
    const wide = wideZ(std.heap.c_allocator, label) catch return null;
    defer std.heap.c_allocator.free(wide);
    const button = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON").ptr,
        wide.ptr,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_PUSHBUTTON,
        x,
        y,
        110,
        30,
        hwnd,
        controlId(id),
        c.GetModuleHandleW(null),
        null,
    ) orelse return null;
    AppFont.apply(button, AppFont.control_size, false);
    return button;
}

fn controlId(value: u16) c.HMENU {
    @setRuntimeSafety(false);
    return @ptrFromInt(@as(usize, value));
}

fn wideZ(allocator: std.mem.Allocator, value: []const u8) ![]u16 {
    const raw = try std.unicode.utf8ToUtf16LeAlloc(allocator, value);
    defer allocator.free(raw);
    const result = try allocator.alloc(u16, raw.len + 1);
    @memcpy(result[0..raw.len], raw);
    result[raw.len] = 0;
    return result;
}

// ---------------------------------------------------------------------------
// Tests — pure presentation logic only.
// ---------------------------------------------------------------------------

test "download progress text reports a real percentage" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Downloading update… 0%", try formatProgressText(&buffer, .downloading, 0));
    try std.testing.expectEqualStrings("Downloading update… 42%", try formatProgressText(&buffer, .downloading, 0.42));
    try std.testing.expectEqualStrings("Downloading update… 100%", try formatProgressText(&buffer, .downloading, 1));
}

test "download progress text clamps out-of-range fractions rather than showing garbage" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Downloading update… 0%", try formatProgressText(&buffer, .downloading, -0.5));
    try std.testing.expectEqualStrings("Downloading update… 100%", try formatProgressText(&buffer, .downloading, 1.5));
}

test "non-downloading phases are indeterminate rather than showing a fake percentage" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Verifying download…", try formatProgressText(&buffer, .verifying, 0.7));
    try std.testing.expectEqualStrings("Extracting update…", try formatProgressText(&buffer, .extracting, 0.7));
    try std.testing.expectEqualStrings("Installing…", try formatProgressText(&buffer, .installing, 0.7));
}

test "every InstallError maps to a distinct, human-readable failure message" {
    const errors = [_]WindowsUpdateInstall.InstallError{
        error.Cancelled,
        error.ChecksumUnavailable,
        error.ChecksumMismatch,
        error.DownloadFailed,
        error.ExtractionFailed,
        error.ExtractionTimedOut,
        error.SetupScriptMissing,
        error.UpgradeFailed,
        error.UpgradeTimedOut,
        error.OutOfMemory,
    };
    for (errors, 0..) |err, i| {
        const message = failureMessage(err);
        try std.testing.expect(message.len > 0);
        for (errors[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, message, failureMessage(other)));
        }
    }
}

test "the relaunch message explains session continuity, not just that install succeeded" {
    try std.testing.expect(std.mem.indexOf(u8, relaunch_message, "Sessions") != null);
    try std.testing.expect(std.mem.indexOf(u8, relaunch_message, "daemon") != null);
}
