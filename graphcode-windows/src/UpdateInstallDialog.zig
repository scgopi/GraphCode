const std = @import("std");
const builtin = @import("builtin");
const Win32 = @import("Win32.zig");
const c = Win32.c;
const ModalTeardown = @import("ModalTeardown.zig");
const AppFont = @import("AppFont.zig");
const Dpi = @import("Dpi.zig");
const SheetFramework = @import("SheetFramework.zig");
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
    /// Installation failed; carries a human-readable reason by value, so the
    /// caller never owns, frees, or borrows memory from the dialog.
    failed: FailureMessage,
};

/// A fixed-capacity copy of a failure reason. Capturing one cannot fail, so
/// every failure path surfaces its reason without an allocation to lose.
pub const FailureMessage = struct {
    pub const capacity = 256;

    bytes: [capacity]u8 = undefined,
    len: usize = 0,

    pub fn init(value: []const u8) FailureMessage {
        var len = @min(value.len, capacity);
        // Never cut a UTF-8 sequence in half when truncating.
        if (len < value.len) {
            while (len > 0 and (value[len] & 0xC0) == 0x80) len -= 1;
        }
        var message = FailureMessage{ .len = len };
        @memcpy(message.bytes[0..len], value[0..len]);
        return message;
    }

    pub fn text(self: *const FailureMessage) []const u8 {
        return self.bytes[0..self.len];
    }
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

/// What a terminal install failure offers. The in-app install cannot be
/// retried from this window, so the reason has to come with a way to still
/// get the build, not just a way to dismiss the message.
pub const FailureAction = enum { download_in_browser, close };

pub fn failureActions() []const FailureAction {
    return &.{ .download_in_browser, .close };
}

/// Whether Download in Browser actually handed the URL to the shell. A
/// refused hand-off must not look like a started download.
pub const DownloadOutcome = enum { opened, open_failed };

pub const ShellOpenError = error{ShellOpenFailed};

/// The shell hand-off used by Download in Browser, injected so the refusal
/// path can be asserted without launching a browser.
const ShellApi = struct {
    pub fn openUrl(owner: c.HWND, allocator: std.mem.Allocator, url: []const u8) ShellOpenError!void {
        if (builtin.is_test) return error.ShellOpenFailed;
        const wide = wideZ(allocator, url) catch return error.ShellOpenFailed;
        defer allocator.free(wide);
        const result = c.ShellExecuteW(
            owner,
            std.unicode.utf8ToUtf16LeStringLiteral("open").ptr,
            wide.ptr,
            null,
            null,
            c.SW_SHOWNORMAL,
        );
        // ShellExecuteW reports failure as a pseudo-instance handle of 32 or less.
        if (@intFromPtr(result) <= 32) return error.ShellOpenFailed;
    }
};

fn downloadInBrowserWith(comptime Api: type, owner: c.HWND, allocator: std.mem.Allocator, url: []const u8) DownloadOutcome {
    // No URL is as much a refusal as a shell that says no: neither started a
    // download, so neither may report one.
    if (url.len == 0) return .open_failed;
    Api.openUrl(owner, allocator, url) catch return .open_failed;
    return .opened;
}

const download_open_failed_message = "GraphCode couldn't open the download in your browser.";

/// Keeps the install failure on screen when the shell refuses the URL: the
/// window is still reporting a failed install, and the browser is a second,
/// separate problem.
fn downloadFailedText(buffer: []u8, reason: []const u8) []const u8 {
    if (reason.len == 0) return download_open_failed_message;
    return std.fmt.bufPrint(buffer, "{s} {s}", .{ reason, download_open_failed_message }) catch download_open_failed_message;
}

fn actionLabel(action: FailureAction) []const u8 {
    return switch (action) {
        .download_in_browser => "Download in Browser",
        .close => "Close",
    };
}

fn actionId(action: FailureAction) u16 {
    return switch (action) {
        .download_in_browser => download_id,
        .close => close_id,
    };
}

fn actionWidth(action: FailureAction) i32 {
    return switch (action) {
        .download_in_browser => 160,
        .close => 110,
    };
}

pub const relaunch_message =
    "GraphCode is installed and takes over on the next launch. Sessions keep " ++
    "running through a relaunch — the background daemon holds them, not this window.";

// ---------------------------------------------------------------------------
// Native window — the message pump is covered by a headless test, but a real
// download/extract/install cycle still needs live exercise.
// ---------------------------------------------------------------------------

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeUpdateInstall");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("GraphCode Update");
const cancel_id: u16 = 9711;
const relaunch_id: u16 = 9712;
const later_id: u16 = 9713;
const close_id: u16 = 9714;
const download_id: u16 = 9715;
const tick_message: c.UINT = c.WM_APP + 1;

const Stage = enum { progress, relaunch, failed };

const State = struct {
    allocator: std.mem.Allocator,
    /// The asset the install was working on, kept so a terminal failure can
    /// hand the same URL to a browser. Borrowed from the caller for the
    /// lifetime of `run`.
    asset_url: []const u8 = "",
    stage: Stage = .progress,
    outcome: ?Outcome = null,
    closed: bool = false,
    cancel_requested: bool = false,
    status_hwnd: c.HWND = null,
    button_hwnd: [2]c.HWND = .{ null, null },
    host: ?*SheetFramework.Host = null,
    content_root: c.HWND = null,
    content_extent: i32 = 112,
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
    active_state = .{ .allocator = allocator, .asset_url = asset_url };
    active = true;
    errdefer active = false;
    shared_phase.store(0, .release);
    shared_fraction_bits.store(@bitCast(@as(f64, 0)), .release);
    shared_done.store(false, .release);
    shared_failed.store(false, .release);
    shared_cancelled.store(false, .release);

    var host: SheetFramework.Host = .{};
    defer host.deinit();
    try createSheet(&host, parent);
    const hwnd = host.hwnd;
    const options = WindowsUpdateInstall.InstallOptions{
        .allocator = allocator,
        .asset_url = asset_url,
        .expected_sha256 = expected_sha256,
        .checksum_url = checksum_url,
        .cancelled = &shared_cancelled,
        .progress = &reportProgress,
    };
    const thread = try startInstall(StartupApi, hwnd, parent, options);

    return finishInstall(StartupApi, hwnd, parent, thread);
}

fn createSheet(host: *SheetFramework.Host, parent: c.HWND) !void {
    const dpi = Dpi.normalize(Win32.dpiForWindow(parent));
    try host.init(parent, .{
        .layout_input = .{
            .owner = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .dpi = dpi,
            .desired_width = 520,
            .minimum_width = 360,
            .heights = .{ .minimum = 170, .ideal = 220, .maximum = 420 },
            .content_extent = active_state.content_extent,
        },
        .context = &active_state,
        .on_layout = &layoutSheet,
        .on_message = &sheetMessage,
    });
    if (c.SetWindowTextW(host.hwnd, window_title.ptr) == 0) return error.DialogCreationFailed;
    active_state.host = host;
    active_state.content_root = c.CreateWindowExW(
        c.WS_EX_CONTROLPARENT,
        class_name.ptr,
        null,
        c.WS_CHILD | c.WS_VISIBLE,
        0,
        0,
        0,
        0,
        host.viewport,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.DialogCreationFailed;
    active_state.status_hwnd = createStatic(active_state.content_root, active_state.allocator, "Preparing…", 22, 22, 476, active_state.content_extent - 44);
    try configureStageFooter();
    try host.relayout();
}

fn configureStageFooter() !void {
    const host = active_state.host orelse return error.DialogCreationFailed;
    const dpi = host.options.layout_input.dpi;
    for (active_state.button_hwnd) |button| {
        if (button != null and c.IsWindow(button) != 0) _ = c.DestroyWindow(button);
    }
    active_state.button_hwnd = .{ null, null };
    switch (active_state.stage) {
        .progress => {
            const actions = [_]SheetFramework.FooterAction{
                .{ .id = cancel_id, .role = .cancel, .measured_text_width = footerTextWidth(host.hwnd, dpi, std.unicode.utf8ToUtf16LeStringLiteral("Cancel"), 48) },
            };
            try host.configureFooter(&actions);
            active_state.button_hwnd[0] = try host.createFooterButton(cancel_id, std.unicode.utf8ToUtf16LeStringLiteral("Cancel").ptr);
        },
        .relaunch => {
            const actions = [_]SheetFramework.FooterAction{
                .{ .id = later_id, .role = .cancel, .measured_text_width = footerTextWidth(host.hwnd, dpi, std.unicode.utf8ToUtf16LeStringLiteral("Later"), 38) },
                .{ .id = relaunch_id, .role = .primary, .measured_text_width = footerTextWidth(host.hwnd, dpi, std.unicode.utf8ToUtf16LeStringLiteral("Relaunch Now"), 92), .return_hint = true },
            };
            try host.configureFooter(&actions);
            active_state.button_hwnd[0] = try host.createFooterButton(later_id, std.unicode.utf8ToUtf16LeStringLiteral("Later").ptr);
            active_state.button_hwnd[1] = try host.createFooterButton(relaunch_id, std.unicode.utf8ToUtf16LeStringLiteral("Relaunch Now").ptr);
        },
        .failed => {
            const actions = [_]SheetFramework.FooterAction{
                .{ .id = close_id, .role = .cancel, .measured_text_width = footerTextWidth(host.hwnd, dpi, std.unicode.utf8ToUtf16LeStringLiteral("Close"), 38) },
                .{ .id = download_id, .role = .primary, .measured_text_width = footerTextWidth(host.hwnd, dpi, std.unicode.utf8ToUtf16LeStringLiteral("Download in Browser"), 132), .return_hint = true },
            };
            try host.configureFooter(&actions);
            active_state.button_hwnd[0] = try host.createFooterButton(close_id, std.unicode.utf8ToUtf16LeStringLiteral("Close").ptr);
            active_state.button_hwnd[1] = try host.createFooterButton(download_id, std.unicode.utf8ToUtf16LeStringLiteral("Download in Browser").ptr);
        },
    }

    for (active_state.button_hwnd) |button| {
        if (button != null) AppFont.apply(button, AppFont.control_size, false);
    }
}

fn footerTextWidth(hwnd: c.HWND, dpi: u32, text: []const u16, fallback: i32) i32 {
    const hdc = c.GetDC(hwnd);
    if (hdc == null) return Dpi.scale(fallback, dpi);
    defer _ = c.ReleaseDC(hwnd, hdc);
    const old_font = AppFont.selectForDpi(hdc, AppFont.control_size, false);
    defer _ = c.SelectObject(hdc, old_font);
    var size: c.SIZE = undefined;
    if (c.GetTextExtentPoint32W(hdc, text.ptr, @intCast(text.len), &size) == 0)
        return Dpi.scale(fallback, dpi);
    return size.cx;
}

fn relaunchFooterActions(hwnd: c.HWND, dpi: u32) [2]SheetFramework.FooterAction {
    return .{
        .{ .id = later_id, .role = .cancel, .measured_text_width = footerTextWidth(hwnd, dpi, std.unicode.utf8ToUtf16LeStringLiteral("Later"), 38) },
        .{ .id = relaunch_id, .role = .primary, .measured_text_width = footerTextWidth(hwnd, dpi, std.unicode.utf8ToUtf16LeStringLiteral("Relaunch Now"), 92), .return_hint = true },
    };
}

fn stageHasCommand(stage: Stage, command: u16) bool {
    return switch (stage) {
        .progress => command == cancel_id,
        .relaunch => command == later_id or command == relaunch_id,
        .failed => command == close_id or command == download_id,
    };
}

fn enabledStageCommand(hwnd: c.HWND, stage: Stage, command: u16) bool {
    if (!stageHasCommand(stage, command)) return false;
    const button = c.GetDlgItem(hwnd, command) orelse return false;
    return c.IsWindow(button) != 0 and c.IsWindowEnabled(button) != 0;
}

fn hintedActionForStage(stage: Stage) ?u16 {
    return switch (stage) {
        .progress => null,
        .relaunch => relaunch_id,
        .failed => download_id,
    };
}

fn defaultActionId(hwnd: c.HWND, stage: Stage) ?u16 {
    const command = hintedActionForStage(stage) orelse return null;
    return if (enabledStageCommand(hwnd, stage, command)) command else null;
}

fn applyControlFontsForDpi(state: *State, dpi: u32) !void {
    const font = AppFont.getForDpi(AppFont.control_size, false, dpi) orelse return error.DialogFontCreationFailed;
    if (state.status_hwnd != null) _ = c.SendMessageW(state.status_hwnd, c.WM_SETFONT, @intFromPtr(font), 1);
    for (state.button_hwnd) |button| {
        if (button != null) _ = c.SendMessageW(button, c.WM_SETFONT, @intFromPtr(font), 1);
    }
}

fn layoutSheet(context: ?*anyopaque, layout: SheetFramework.Layout) !void {
    const state: *State = @ptrCast(@alignCast(context.?));
    if (state.content_root == null) return;
    const dpi = state.host.?.options.layout_input.dpi;
    try applyControlFontsForDpi(state, dpi);
    const scrollbar = if (layout.scroll.visible) SheetFramework.Metrics.forDpi(dpi).scrollbar_width else 0;
    const content_width = @max(0, layout.viewport.width - scrollbar);
    if (c.MoveWindow(
        state.content_root,
        0,
        -layout.scroll.offset,
        content_width,
        @max(layout.scroll.extent, layout.viewport.height),
        1,
    ) == 0) return error.DialogLayoutFailed;
    if (state.status_hwnd != null and c.MoveWindow(
        state.status_hwnd,
        Dpi.scale(22, dpi),
        Dpi.scale(22, dpi),
        @max(0, content_width - Dpi.scale(44, dpi)),
        Dpi.scale(@max(52, state.content_extent - 44), dpi),
        1,
    ) == 0) return error.DialogLayoutFailed;
}

fn sheetMessage(context: ?*anyopaque, hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM, result: *c.LRESULT) bool {
    const state: *State = @ptrCast(@alignCast(context.?));
    switch (message) {
        c.WM_DRAWITEM => {
            result.* = drawFooterItem(state.host.?, lparam);
            return true;
        },
        tick_message => {
            onTick(hwnd);
            result.* = 0;
            return true;
        },
        c.DM_GETDEFID => {
            result.* = if (defaultActionId(hwnd, state.stage)) |id|
                @as(c.LRESULT, @intCast(id)) | (@as(c.LRESULT, c.DC_HASDEFID) << 16)
            else
                0;
            return true;
        },
        c.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            if (!enabledStageCommand(hwnd, state.stage, command)) return false;
            handleCommand(command, hwnd);
            result.* = 0;
            return true;
        },
        c.WM_CLOSE => {
            if (state.stage == .progress) {
                state.cancel_requested = true;
                shared_cancelled.store(true, .release);
            } else {
                requestClose(hwnd);
            }
            result.* = 0;
            return true;
        },
        else => return false,
    }
}

fn drawFooterItem(host: *SheetFramework.Host, lparam: c.LPARAM) c.LRESULT {
    const item = Win32.messagePointer(*const c.DRAWITEMSTRUCT, lparam);
    var role = SheetFramework.ActionRole.secondary;
    var return_hint = false;
    for (host.footer_actions[0..host.footer_action_count]) |action| {
        if (action.id != item.CtlID) continue;
        role = action.role;
        return_hint = action.return_hint and action.role.isPrimary();
        break;
    }
    SheetFramework.drawButton(item.hDC, .{ .x = item.rcItem.left, .y = item.rcItem.top, .width = item.rcItem.right - item.rcItem.left, .height = item.rcItem.bottom - item.rcItem.top }, host.options.layout_input.dpi, role, item.itemState & c.ODS_DISABLED == 0, item.itemState & c.ODS_SELECTED != 0) catch return 0;
    var text: [128]u16 = [_]u16{0} ** 128;
    const count = c.GetWindowTextW(item.hwndItem, &text, text.len);
    const old_font = AppFont.selectForDpi(item.hDC, AppFont.control_size, false);
    defer _ = c.SelectObject(item.hDC, old_font);
    _ = c.SetBkMode(item.hDC, c.TRANSPARENT);
    _ = c.SetTextColor(item.hDC, SheetFramework.controlPaintStyle(.button, item.itemState & c.ODS_DISABLED == 0).foreground);
    var bounds = item.rcItem;
    if (return_hint) bounds.right -= SheetFramework.Metrics.forDpi(host.options.layout_input.dpi).return_hint_width;
    _ = c.DrawTextW(item.hDC, &text, count, &bounds, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE);
    if (return_hint) {
        var hint_bounds = item.rcItem;
        hint_bounds.left = bounds.right;
        _ = c.DrawTextW(item.hDC, std.unicode.utf8ToUtf16LeStringLiteral("\u{21b5}").ptr, 1, &hint_bounds, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE);
    }
    return 1;
}

fn handleCommand(command: u16, hwnd: c.HWND) void {
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
        close_id => requestClose(hwnd),
        download_id => {
            switch (downloadInBrowserWith(ShellApi, hwnd, active_state.allocator, active_state.asset_url)) {
                .opened => requestClose(hwnd),
                .open_failed => {
                    var buffer: [FailureMessage.capacity + download_open_failed_message.len + 1]u8 = undefined;
                    const reason = if (active_state.outcome != null) failureTextOf(&active_state.outcome.?) orelse "" else "";
                    setStatusText(active_state.status_hwnd, active_state.allocator, downloadFailedText(&buffer, reason));
                },
            }
        },
        else => {},
    }
}

fn finishInstall(comptime Api: type, hwnd: c.HWND, parent: c.HWND, thread: std.Thread) Outcome {
    var message: c.MSG = undefined;
    var quit_code: ?c.WPARAM = null;
    while (!active_state.closed) {
        const code = c.GetMessageW(&message, null, 0, 0);
        if (code <= 0) {
            active_state.cancel_requested = true;
            shared_cancelled.store(true, .release);
            active_state.closed = true;
            if (code == 0) quit_code = message.wParam;
            break;
        }
        if (c.IsDialogMessageW(hwnd, &message) != 0) continue;
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }
    Api.join(thread);
    ModalTeardown.dismissWith(Api, hwnd, parent);
    active_hwnd = null;
    active = false;
    if (quit_code) |value| c.PostQuitMessage(@intCast(value));
    return closedOutcome(active_state.outcome);
}

const window_closed_message = "The update window closed unexpectedly.";

fn closedOutcome(outcome: ?Outcome) Outcome {
    return outcome orelse .{ .failed = FailureMessage.init(window_closed_message) };
}

/// The Win32 and thread surface used to present the window and start the
/// worker, injected so the startup failure path can be asserted without real
/// windows or threads.
const StartupApi = struct {
    pub fn enableWindow(window: c.HWND, enabled: c_int) void {
        _ = c.EnableWindow(window, enabled);
    }

    pub fn showWindow(window: c.HWND) void {
        if (active_state.host) |host| {
            host.show() catch return;
        } else {
            _ = c.ShowWindow(window, c.SW_SHOW);
            _ = c.SetForegroundWindow(window);
        }
    }

    pub fn destroyWindow(window: c.HWND) void {
        _ = c.DestroyWindow(window);
    }

    pub fn setActiveWindow(window: c.HWND) void {
        _ = c.SetActiveWindow(window);
    }

    pub fn spawn(options: WindowsUpdateInstall.InstallOptions) !std.Thread {
        return std.Thread.spawn(.{}, worker, .{options});
    }

    pub fn join(thread: std.Thread) void {
        thread.join();
    }
};

fn startInstall(comptime Api: type, hwnd: c.HWND, parent: c.HWND, options: WindowsUpdateInstall.InstallOptions) !std.Thread {
    active_hwnd = hwnd;
    Api.enableWindow(parent, 0);
    Api.showWindow(hwnd);
    errdefer {
        ModalTeardown.dismissWith(Api, hwnd, parent);
        active_hwnd = null;
        active = false;
    }
    return try Api.spawn(options);
}

fn registerClass() !void {
    var klass: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
    klass.lpfnWndProc = @ptrCast(&contentProc);
    klass.hInstance = c.GetModuleHandleW(null);
    klass.lpszClassName = class_name.ptr;
    klass.hCursor = c.LoadCursorW(null, Win32.resourceIdentifier(32512));
    if (c.RegisterClassW(&klass) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS)
        return error.DialogClassRegistrationFailed;
}

fn contentProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (!active or active_state.host == null) return c.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        c.WM_CTLCOLORSTATIC => return active_state.host.?.brushes.apply(Win32.opaquePointerFromInt(c.HDC, wparam), .static, true) catch 0,
        c.WM_ERASEBKGND => {
            var bounds: c.RECT = undefined;
            if (c.GetClientRect(hwnd, &bounds) != 0) _ = c.FillRect(Win32.opaquePointerFromInt(c.HDC, wparam), &bounds, active_state.host.?.brushes.panel);
            return 1;
        },
        else => return c.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

/// Decides the outcome of a worker that reported failure. `source` is the
/// worker's shared, reused buffer; the returned outcome holds its own copy.
fn failedCompletion(cancel_requested: bool, source: []const u8) Outcome {
    if (cancel_requested) return .cancelled;
    return .{ .failed = FailureMessage.init(source) };
}

fn failureTextOf(outcome: *const Outcome) ?[]const u8 {
    return switch (outcome.*) {
        .failed => |*message| message.text(),
        else => null,
    };
}

fn onTick(hwnd: c.HWND) void {
    if (active_state.stage != .progress) return;
    if (shared_done.load(.acquire)) {
        if (shared_failed.load(.acquire)) {
            const len = shared_failure_len.load(.acquire);
            active_state.stage = .failed;
            active_state.outcome = failedCompletion(active_state.cancel_requested, shared_failure_buffer[0..len]);
            if (failureTextOf(&active_state.outcome.?)) |message| {
                transitionToFailed(hwnd, message);
            } else {
                requestClose(hwnd);
            }
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
    active_state.content_extent = 156;
    active_state.host.?.setContentExtent(active_state.content_extent) catch {};
    setStatusText(active_state.status_hwnd, active_state.allocator, "Update installed. " ++ relaunch_message);
    configureStageFooter() catch {
        active_state.outcome = .{ .failed = FailureMessage.init("The update controls could not be displayed.") };
        requestClose(hwnd);
    };
}

fn transitionToFailed(hwnd: c.HWND, message: []const u8) void {
    active_state.content_extent = 132;
    active_state.host.?.setContentExtent(active_state.content_extent) catch {};
    setStatusText(active_state.status_hwnd, active_state.allocator, message);
    configureStageFooter() catch requestClose(hwnd);
}

fn requestClose(hwnd: c.HWND) void {
    active_state.closed = true;
    if (active_state.host) |host| host.requestClose();
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
// Tests — presentation logic and headless window lifecycle.
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

test "a worker failure outcome does not borrow the shared failure buffer and needs no allocation" {
    var source: [128]u8 = undefined;
    const reason = failureMessage(error.DownloadFailed);
    @memcpy(source[0..reason.len], reason);
    // Capturing takes no allocator, so there is no out-of-memory fallback
    // that could hand back a borrowed or static reason.
    const outcome = failedCompletion(false, source[0..reason.len]);
    // The worker reuses this buffer; the outcome must survive it being rewritten.
    @memset(&source, 'x');
    try std.testing.expectEqualStrings(reason, failureTextOf(&outcome).?);
}

test "a worker failure outcome survives being copied after its source is gone" {
    const outcome = blk: {
        var source: [128]u8 = undefined;
        const reason = failureMessage(error.UpgradeFailed);
        @memcpy(source[0..reason.len], reason);
        const captured = failedCompletion(false, source[0..reason.len]);
        @memset(&source, 0);
        break :blk captured;
    };
    try std.testing.expectEqualStrings(failureMessage(error.UpgradeFailed), failureTextOf(&outcome).?);
}

test "a failure reported after the user cancelled is surfaced as cancelled without leaking" {
    const outcome = failedCompletion(true, failureMessage(error.Cancelled));
    try std.testing.expect(outcome == .cancelled);
}

test "the window-closed fallback is a surfaced failure the caller never frees" {
    const outcome = closedOutcome(null);
    try std.testing.expectEqualStrings(window_closed_message, failureTextOf(&outcome).?);
    // The failure payload is a value, not a slice a caller could free.
    try std.testing.expect(std.meta.TagPayload(Outcome, .failed) == FailureMessage);
}

test "the window-closed fallback never replaces a decided outcome" {
    try std.testing.expect(closedOutcome(.cancelled) == .cancelled);
    try std.testing.expectEqual(RelaunchAction.later, closedOutcome(.{ .relaunch = .later }).relaunch);
}

test "a failure reason longer than the capacity is truncated on a UTF-8 boundary" {
    var long: [FailureMessage.capacity + 8]u8 = undefined;
    @memset(&long, 'a');
    // A three-byte character straddling the capacity must be dropped whole.
    const ellipsis = "…";
    @memcpy(long[FailureMessage.capacity - 1 ..][0..ellipsis.len], ellipsis);
    const message = FailureMessage.init(&long);
    try std.testing.expectEqual(FailureMessage.capacity - 1, message.text().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(message.text()));
}

var startup_calls: [8]StartupCall = undefined;
var startup_calls_len: usize = 0;
var startup_owner_enabled: bool = true;
var startup_dialog_alive: bool = false;

const StartupCall = enum { disable_owner, enable_owner, show_dialog, destroy_dialog, activate_owner, spawn, join_worker };

fn recordStartup(call: StartupCall) void {
    startup_calls[startup_calls_len] = call;
    startup_calls_len += 1;
}

const FailingSpawnApi = struct {
    pub fn enableWindow(window: c.HWND, enabled: c_int) void {
        _ = window;
        startup_owner_enabled = enabled != 0;
        recordStartup(if (enabled != 0) .enable_owner else .disable_owner);
    }

    pub fn showWindow(window: c.HWND) void {
        _ = window;
        recordStartup(.show_dialog);
    }

    pub fn destroyWindow(window: c.HWND) void {
        _ = window;
        startup_dialog_alive = false;
        recordStartup(.destroy_dialog);
    }

    pub fn setActiveWindow(window: c.HWND) void {
        _ = window;
        recordStartup(.activate_owner);
    }

    pub fn spawn(options: WindowsUpdateInstall.InstallOptions) !std.Thread {
        _ = options;
        recordStartup(.spawn);
        return error.SystemResources;
    }
};

fn fakeWindow(value: usize) c.HWND {
    @setRuntimeSafety(false);
    return @ptrFromInt(value);
}

test "a worker thread that cannot start restores the owner and tears the window down" {
    startup_calls_len = 0;
    startup_owner_enabled = true;
    startup_dialog_alive = true;
    active = true;
    defer active = false;
    defer active_hwnd = null;

    const options = WindowsUpdateInstall.InstallOptions{
        .allocator = std.testing.allocator,
        .asset_url = "https://example.invalid/GraphCode.zip",
        .cancelled = &shared_cancelled,
        .progress = &reportProgress,
    };
    try std.testing.expectError(error.SystemResources, startInstall(FailingSpawnApi, fakeWindow(0x2000), fakeWindow(0x1000), options));

    try std.testing.expect(startup_owner_enabled);
    try std.testing.expect(!startup_dialog_alive);
    try std.testing.expect(!active);
    try std.testing.expect(active_hwnd == null);
    try std.testing.expectEqualSlices(
        StartupCall,
        &.{ .disable_owner, .show_dialog, .spawn, .enable_owner, .destroy_dialog, .activate_owner },
        startup_calls[0..startup_calls_len],
    );
}

var shell_open_calls: usize = 0;
var shell_open_url: [512]u8 = undefined;
var shell_open_len: usize = 0;

/// A shell that accepts whatever URL it is handed, so the test can assert the
/// exact URL Download in Browser passes on without launching a browser.
const OpeningShellApi = struct {
    pub fn openUrl(owner: c.HWND, allocator: std.mem.Allocator, url: []const u8) !void {
        _ = owner;
        _ = allocator;
        shell_open_calls += 1;
        @memcpy(shell_open_url[0..url.len], url);
        shell_open_len = url.len;
    }
};

test "a terminal install failure offers a browser download of the asset that failed" {
    // ChecksumMismatch is terminal: nothing can be retried from this window,
    // so the reason has to come with a way to get the build anyway.
    try std.testing.expect(failureMessage(error.ChecksumMismatch).len > 0);
    try std.testing.expectEqualSlices(FailureAction, &.{ .download_in_browser, .close }, failureActions());

    shell_open_calls = 0;
    shell_open_len = 0;
    const asset = "https://example.invalid/GraphCode-windows-x86_64.zip";
    const result = downloadInBrowserWith(OpeningShellApi, fakeWindow(0x2000), std.testing.allocator, asset);
    try std.testing.expectEqual(DownloadOutcome.opened, result);
    try std.testing.expectEqual(@as(usize, 1), shell_open_calls);
    try std.testing.expectEqualStrings(asset, shell_open_url[0..shell_open_len]);
}

/// A shell that refuses the URL, so the refusal path can be asserted without
/// a machine that has no browser registered.
const RefusingShellApi = struct {
    pub fn openUrl(owner: c.HWND, allocator: std.mem.Allocator, url: []const u8) !void {
        _ = owner;
        _ = allocator;
        _ = url;
        shell_open_calls += 1;
        return error.ShellOpenFailed;
    }
};

test "a shell that refuses the download is surfaced instead of looking like a started download" {
    shell_open_calls = 0;
    const result = downloadInBrowserWith(RefusingShellApi, fakeWindow(0x2000), std.testing.allocator, "https://example.invalid/GraphCode.zip");
    try std.testing.expectEqual(DownloadOutcome.open_failed, result);
    try std.testing.expectEqual(@as(usize, 1), shell_open_calls);

    // The install failure stays on screen; the browser problem is added to it.
    var buffer: [FailureMessage.capacity + download_open_failed_message.len + 1]u8 = undefined;
    const reason = failureMessage(error.ChecksumMismatch);
    const text = downloadFailedText(&buffer, reason);
    try std.testing.expect(std.mem.startsWith(u8, text, reason));
    try std.testing.expect(std.mem.endsWith(u8, text, download_open_failed_message));
}

test "a failure with no asset URL reports a refusal rather than an opened download" {
    shell_open_calls = 0;
    const result = downloadInBrowserWith(OpeningShellApi, fakeWindow(0x2000), std.testing.allocator, "");
    try std.testing.expectEqual(DownloadOutcome.open_failed, result);
    try std.testing.expectEqual(@as(usize, 0), shell_open_calls);
}

test "the failure stage's actions each have a distinct label, id, and width" {
    for (failureActions(), 0..) |action, i| {
        try std.testing.expect(actionLabel(action).len > 0);
        try std.testing.expect(actionWidth(action) > 0);
        for (failureActions()[i + 1 ..]) |other| {
            try std.testing.expect(actionId(action) != actionId(other));
            try std.testing.expect(!std.mem.eql(u8, actionLabel(action), actionLabel(other)));
        }
    }
}

const QuitTestApi = struct {
    pub fn join(thread: std.Thread) void {
        _ = thread;
        recordStartup(.join_worker);
    }

    pub fn enableWindow(window: c.HWND, enabled: c_int) void {
        _ = window;
        std.debug.assert(enabled != 0);
        recordStartup(.enable_owner);
    }

    pub fn destroyWindow(window: c.HWND) void {
        _ = window;
        recordStartup(.destroy_dialog);
    }

    pub fn setActiveWindow(window: c.HWND) void {
        _ = window;
        recordStartup(.activate_owner);
    }
};

test "update install dialog preserves WM_QUIT exit code after teardown" {
    var pending: c.MSG = undefined;
    defer _ = c.PeekMessageW(&pending, null, c.WM_QUIT, c.WM_QUIT, c.PM_REMOVE);
    startup_calls_len = 0;
    active_state = .{ .allocator = std.testing.allocator };
    active_hwnd = fakeWindow(0x2000);
    active = true;
    c.PostQuitMessage(73);

    const outcome = finishInstall(QuitTestApi, fakeWindow(0x2000), fakeWindow(0x1000), undefined);
    try std.testing.expectEqualSlices(
        StartupCall,
        &.{ .join_worker, .enable_owner, .destroy_dialog, .activate_owner },
        startup_calls[0..startup_calls_len],
    );
    try std.testing.expect(outcome == .failed);
    try std.testing.expect(!active);
    try std.testing.expect(active_hwnd == null);
    try std.testing.expectEqual(@as(c.BOOL, 1), c.PeekMessageW(&pending, null, c.WM_QUIT, c.WM_QUIT, c.PM_REMOVE));
    try std.testing.expectEqual(@as(c.WPARAM, 73), pending.wParam);
}

/// Whether `shared_cancelled` had already been signalled the moment the
/// worker thread is joined. Captured inside `join` itself so the assertion
/// reflects the state the worker actually observed, not a value read after
/// the fact.
var quit_join_observed_cancel: bool = false;

const QuitCancelTestApi = struct {
    pub fn join(thread: std.Thread) void {
        _ = thread;
        quit_join_observed_cancel = shared_cancelled.load(.acquire);
        recordStartup(.join_worker);
    }

    pub fn enableWindow(window: c.HWND, enabled: c_int) void {
        _ = window;
        std.debug.assert(enabled != 0);
        recordStartup(.enable_owner);
    }

    pub fn destroyWindow(window: c.HWND) void {
        _ = window;
        recordStartup(.destroy_dialog);
    }

    pub fn setActiveWindow(window: c.HWND) void {
        _ = window;
        recordStartup(.activate_owner);
    }
};

test "update install dialog signals cancellation to the worker before joining on WM_QUIT" {
    var pending: c.MSG = undefined;
    defer _ = c.PeekMessageW(&pending, null, c.WM_QUIT, c.WM_QUIT, c.PM_REMOVE);
    startup_calls_len = 0;
    active_state = .{ .allocator = std.testing.allocator };
    active_hwnd = fakeWindow(0x2000);
    active = true;
    shared_cancelled.store(false, .release);
    defer shared_cancelled.store(false, .release);
    quit_join_observed_cancel = false;
    c.PostQuitMessage(0);

    const outcome = finishInstall(QuitCancelTestApi, fakeWindow(0x2000), fakeWindow(0x1000), undefined);

    // The worker polls `shared_cancelled`; if it is not set before `join` is
    // called, the join blocks for however long the install still has left
    // to run instead of returning as soon as the worker notices it should stop.
    try std.testing.expect(quit_join_observed_cancel);
    try std.testing.expect(active_state.cancel_requested);
    try std.testing.expect(outcome == .failed);
}

fn hiddenOwner() !c.HWND {
    return c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr,
        null,
        c.WS_POPUP,
        20,
        20,
        900,
        700,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse error.DialogCreationFailed;
}

fn pumpReturn(hwnd: c.HWND, target: c.HWND) void {
    var message = std.mem.zeroes(c.MSG);
    message.hwnd = target;
    message.message = c.WM_KEYDOWN;
    message.wParam = c.VK_RETURN;
    if (c.IsDialogMessageW(hwnd, &message) != 0) return;
    _ = c.TranslateMessage(&message);
    _ = c.DispatchMessageW(&message);
}

fn queriedDefaultId(hwnd: c.HWND) ?u16 {
    const reply: usize = @bitCast(c.SendMessageW(hwnd, c.DM_GETDEFID, 0, 0));
    if (reply >> 16 != c.DC_HASDEFID) return null;
    return @truncate(reply);
}

fn controlFont(control: c.HWND) c.HFONT {
    return Win32.opaquePointerFromInt(c.HFONT, @bitCast(c.SendMessageW(control, c.WM_GETFONT, 0, 0)));
}

fn expectControlFontForDpi(control: c.HWND, dpi: u32) !void {
    const font = controlFont(control);
    try std.testing.expectEqual(AppFont.getForDpi(AppFont.control_size, false, dpi), font);
    var info = std.mem.zeroes(c.LOGFONTW);
    try std.testing.expect(c.GetObjectW(font, @sizeOf(c.LOGFONTW), &info) != 0);
    try std.testing.expectEqual(-Dpi.scale(AppFont.control_size, dpi), info.lfHeight);
}

test "hidden update install refreshes status and action fonts across DPI transitions" {
    try registerClass();
    const owner = try hiddenOwner();
    defer _ = c.DestroyWindow(owner);
    active_state = .{ .allocator = std.testing.allocator, .stage = .relaunch };
    active = true;
    defer active = false;
    var host: SheetFramework.Host = .{};
    defer host.deinit();
    try createSheet(&host, owner);
    try configureStageFooter();
    try std.testing.expect(c.IsWindowVisible(host.hwnd) == 0);

    var font_96: c.HFONT = null;
    for ([_]u32{ 96, 192, 96 }) |dpi| {
        try host.refreshForDpi(dpi);
        try expectControlFontForDpi(active_state.status_hwnd, dpi);
        for (active_state.button_hwnd) |button| try expectControlFontForDpi(button, dpi);
        const current = controlFont(active_state.status_hwnd);
        if (font_96 == null) {
            font_96 = current;
        } else if (dpi == 192) {
            try std.testing.expect(current != font_96);
        } else {
            try std.testing.expectEqual(font_96, current);
        }
    }
}

test "hidden update install Return follows the hinted action as stages change" {
    try registerClass();
    const owner = try hiddenOwner();
    defer _ = c.DestroyWindow(owner);
    active_state = .{ .allocator = std.testing.allocator };
    active = true;
    defer active = false;
    var host: SheetFramework.Host = .{};
    defer host.deinit();
    try createSheet(&host, owner);

    try std.testing.expectEqual(@as(?u16, null), queriedDefaultId(host.hwnd));
    active_state.stage = .relaunch;
    try configureStageFooter();
    try std.testing.expectEqual(@as(?u16, relaunch_id), queriedDefaultId(host.hwnd));
    pumpReturn(host.hwnd, active_state.status_hwnd);

    try std.testing.expect(active_state.closed);
    try std.testing.expectEqual(RelaunchAction.relaunch_now, active_state.outcome.?.relaunch);
}

test "hidden update install rejects disabled nonexistent and out-of-stage default actions" {
    try registerClass();
    const owner = try hiddenOwner();
    defer _ = c.DestroyWindow(owner);
    active_state = .{
        .allocator = std.testing.allocator,
        .asset_url = "https://example.invalid/GraphCode.zip",
        .outcome = .{ .failed = FailureMessage.init(failureMessage(error.DownloadFailed)) },
    };
    active = true;
    defer active = false;
    var host: SheetFramework.Host = .{};
    defer host.deinit();
    try createSheet(&host, owner);

    _ = c.SendMessageW(host.hwnd, c.WM_COMMAND, relaunch_id, 0);
    try std.testing.expect(!active_state.closed);
    try std.testing.expect(active_state.outcome.? == .failed);

    active_state.stage = .failed;
    try configureStageFooter();
    try std.testing.expectEqual(@as(?u16, download_id), queriedDefaultId(host.hwnd));
    const download = c.GetDlgItem(host.hwnd, download_id) orelse return error.TestButtonMissing;
    _ = c.EnableWindow(download, 0);
    try std.testing.expectEqual(@as(?u16, null), queriedDefaultId(host.hwnd));
    pumpReturn(host.hwnd, active_state.status_hwnd);
    _ = c.SendMessageW(host.hwnd, c.WM_COMMAND, download_id, 0);
    try std.testing.expect(!active_state.closed);
    try std.testing.expect(active_state.outcome.? == .failed);

    _ = c.DestroyWindow(download);
    _ = c.SendMessageW(host.hwnd, c.WM_COMMAND, download_id, 0);
    _ = c.SendMessageW(host.hwnd, c.WM_COMMAND, download_id + 100, 0);
    try std.testing.expectEqual(@as(?u16, null), queriedDefaultId(host.hwnd));
    try std.testing.expect(!active_state.closed);
    try std.testing.expect(active_state.outcome.? == .failed);
}

test "dialog framework: update install uses hidden sheet and fixed stage footer" {
    try registerClass();
    const owner = try hiddenOwner();
    defer _ = c.DestroyWindow(owner);
    active_state = .{ .allocator = std.testing.allocator };
    active = true;
    defer active = false;
    var host: SheetFramework.Host = .{};
    defer host.deinit();
    try createSheet(&host, owner);
    try std.testing.expect(c.IsWindowVisible(host.hwnd) == 0);
    try std.testing.expect(c.GetWindowLongPtrW(host.hwnd, c.GWL_STYLE) & c.WS_CAPTION == 0);
    var title: [64]u16 = [_]u16{0} ** 64;
    const title_length = c.GetWindowTextW(host.hwnd, &title, title.len);
    try std.testing.expectEqualSlices(u16, window_title[0..window_title.len], title[0..@intCast(title_length)]);
    try std.testing.expect(c.GetParent(active_state.content_root) == host.viewport);
    try std.testing.expect(c.GetWindowLongPtrW(active_state.content_root, c.GWL_EXSTYLE) & c.WS_EX_CONTROLPARENT != 0);
    try std.testing.expect(host.footer_layout.?.slotFor(cancel_id).?.role == .cancel);
    try std.testing.expectEqual(host.current_layout.sheet.height, host.current_layout.viewport.height + host.current_layout.footer.height);
    host.options.layout_input.content_extent = Dpi.unscale(host.current_layout.viewport.height, host.options.layout_input.dpi) + 100;
    try host.relayout();
    var viewport: c.RECT = undefined;
    var content: c.RECT = undefined;
    try std.testing.expect(c.GetClientRect(host.viewport, &viewport) != 0);
    try std.testing.expect(c.GetClientRect(active_state.content_root, &content) != 0);
    try std.testing.expectEqual(
        SheetFramework.Metrics.forDpi(host.options.layout_input.dpi).scrollbar_width,
        (viewport.right - viewport.left) - (content.right - content.left),
    );
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const actions = relaunchFooterActions(host.hwnd, dpi);
        const width = Dpi.scale(520, dpi);
        const footer = try SheetFramework.measureFooter(width, Dpi.scale(64, dpi), dpi, &actions);
        try std.testing.expect(footer.measured_minimum_width <= width);
        for (footer.slice()) |slot| try std.testing.expect(slot.bounds.x >= 0 and slot.bounds.right() <= width);
        try std.testing.expect(actions[1].return_hint);
        try std.testing.expect(footer.slotFor(relaunch_id).?.bounds.width >=
            actions[1].measured_text_width + SheetFramework.Metrics.forDpi(dpi).return_hint_width);
    }
}
