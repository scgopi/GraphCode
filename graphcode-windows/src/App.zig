const std = @import("std");
const builtin = @import("builtin");
const build_options = if (builtin.is_test)
    struct {
        pub const version = "dev";
    }
else
    @import("build_options");
const DaemonClient = @import("DaemonClient.zig").DaemonClient;
const GraphCanvas = @import("GraphCanvas.zig");
const GdiplusAA = @import("GdiplusAA.zig");
const CanvasInput = @import("CanvasInput.zig");
const CanvasLayoutStore = @import("CanvasLayoutStore.zig");
const GraphContextMenu = @import("GraphContextMenu.zig");
const Forms = @import("Forms.zig");
const EdgeCreation = @import("EdgeCreation.zig");
const EdgeEditing = @import("EdgeEditing.zig");
const NativeForms = @import("NativeForms.zig");
const SketchPromotion = @import("SketchPromotion.zig");
const TemplateLibrary = @import("TemplateLibrary.zig");
const Diagnostics = @import("Diagnostics.zig");
const JumpPalette = @import("JumpPalette.zig");
const NativeDialogs = @import("WindowsNativeDialogs.zig");
const Sidebar = @import("Sidebar.zig");
const GraphModel = @import("GraphModel.zig");
const InputRouter = @import("InputRouter.zig");
const MainWindow = @import("MainWindow.zig");
const TerminalWorkspace = @import("TerminalWorkspace.zig");
const LoopBarLayout = @import("LoopBarLayout.zig");
const Clipboard = @import("Clipboard.zig");
const Tokens = @import("DesignTokens.zig");
const Dpi = @import("Dpi.zig");
const AppFont = @import("AppFont.zig");
const Wire = @import("Wire.zig");
const WorktreeStatus = @import("WorktreeStatus.zig");
const RemoteWorktrees = @import("RemoteWorktrees.zig");
const TrayModule = @import("Tray.zig");
const Tray = TrayModule.Tray;
const DaemonSupervisor = @import("DaemonSupervisor.zig").Supervisor;
const ProductSettings = @import("WindowsProductSettings.zig");
const RepositoryDialogs = @import("WindowsRepositoryDialogs.zig");
const CodespaceDialog = @import("WindowsCodespaceDialog.zig");
const Codespaces = @import("Codespaces.zig");
const Onboarding = @import("WindowsOnboarding.zig");
const WindowsUpdates = @import("WindowsUpdates.zig");
const UpdateOfferDialog = @import("UpdateOfferDialog.zig");
const UpdateOfferPresentation = @import("UpdateOfferPresentation.zig");
const UpdateInstallDialog = @import("UpdateInstallDialog.zig");
const WindowsUpdateInstall = @import("WindowsUpdateInstall.zig");
const WorktreeDialog = @import("WorktreeDialog.zig");
const Accessibility = @import("Accessibility.zig");
const Navigation = @import("Navigation.zig");
const WorkspaceControls = @import("WorkspaceControls.zig");
const WorkspaceLifecycle = @import("WorkspaceLifecycle.zig");
const WorkspaceManager = @import("WorkspaceManager.zig");
const WorkspaceManagerForm = @import("WorkspaceManagerForm.zig");
const WorkspaceTeardown = @import("WorkspaceTeardown.zig");
const Win32 = @import("Win32.zig");
const c = Win32.c;

const title = std.unicode.utf8ToUtf16LeStringLiteral("GraphCode Windows");
const workspace_restart_message = "Workspace identity changed or could not be verified. Restart GraphCode before managing workspaces.";
const WorktreeInspectRunner = *const fn (
    std.mem.Allocator,
    []const u8,
    []const WorktreeStatus.Binding,
    ?WorktreeStatus.Cancellation,
) anyerror!WorktreeStatus.Inspection;
const WorktreeSizeRunner = *const fn (
    std.mem.Allocator,
    []const u8,
    []const u8,
    ?WorktreeStatus.Cancellation,
) WorktreeStatus.SizeCoverage;
const WorktreeReclaimRunner = *const fn (
    std.mem.Allocator,
    []const u8,
    []const []const u8,
    []const WorktreeStatus.Binding,
    WorktreeStatus.Policy,
    bool,
    bool,
    ?WorktreeStatus.Cancellation,
) anyerror!WorktreeStatus.ReclaimReport;
const WorktreeReclaimKind = enum { sweep, selected, offer };
const WorktreeReclaimRequest = struct {
    generation: u64,
    project_path: []u8,
    selected: [][]const u8,
    bindings: []WorktreeStatus.Binding,
    policy: WorktreeStatus.Policy,
    confirmed: bool,
    allow_forced: bool,
    kind: WorktreeReclaimKind,
    runner: WorktreeReclaimRunner,

    fn deinit(self: *WorktreeReclaimRequest, allocator: std.mem.Allocator) void {
        if (self.project_path.len != 0) allocator.free(self.project_path);
        for (self.selected) |path| allocator.free(path);
        if (self.selected.len != 0) allocator.free(self.selected);
        for (self.bindings) |binding| allocator.free(binding.path);
        if (self.bindings.len != 0) allocator.free(self.bindings);
        allocator.destroy(self);
    }
};

fn runWorktreeInspection(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    bindings: []const WorktreeStatus.Binding,
    cancellation: ?WorktreeStatus.Cancellation,
) anyerror!WorktreeStatus.Inspection {
    return if (std.mem.startsWith(u8, project_path, "ssh://") or
        std.mem.startsWith(u8, project_path, "codespace://"))
        RemoteWorktrees.inspectFactsWithCancel(allocator, project_path, bindings, cancellation)
    else
        WorktreeStatus.inspectFactsWithCancel(allocator, project_path, bindings, cancellation);
}

fn runWorktreeSize(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    path: []const u8,
    cancellation: ?WorktreeStatus.Cancellation,
) WorktreeStatus.SizeCoverage {
    return if (std.mem.startsWith(u8, project_path, "ssh://") or
        std.mem.startsWith(u8, project_path, "codespace://"))
        RemoteWorktrees.measureSizeWithCancel(allocator, project_path, path, cancellation)
    else
        WorktreeStatus.measureSizeWithCancel(path, cancellation);
}

fn runWorktreeReclaim(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    selected: []const []const u8,
    bindings: []const WorktreeStatus.Binding,
    policy: WorktreeStatus.Policy,
    confirmed: bool,
    allow_forced: bool,
    cancellation: ?WorktreeStatus.Cancellation,
) anyerror!WorktreeStatus.ReclaimReport {
    return WorktreeStatus.reclaimSelectedDetailedWithCancel(
        allocator,
        project_path,
        selected,
        bindings,
        policy,
        confirmed,
        allow_forced,
        cancellation,
    );
}
const WorktreeReclaimResult = struct {
    project_path: []u8,
    kind: WorktreeReclaimKind,
    outcome: anyerror!WorktreeStatus.ReclaimReport,

    fn deinit(self: *WorktreeReclaimResult, allocator: std.mem.Allocator) void {
        if (self.outcome) |*report| report.deinit() else |_| {}
        allocator.free(self.project_path);
    }
};
const WorktreeInspectionRequest = struct {
    generation: u64,
    project_path: []u8,
    bindings: []WorktreeStatus.Binding,
    show_sweep: bool,
    runner: WorktreeInspectRunner,

    fn deinit(self: *WorktreeInspectionRequest, allocator: std.mem.Allocator) void {
        if (self.project_path.len != 0) allocator.free(self.project_path);
        for (self.bindings) |binding| allocator.free(binding.path);
        if (self.bindings.len != 0) allocator.free(self.bindings);
        allocator.destroy(self);
    }
};
const WorktreeInspectionResult = struct {
    generation: u64,
    project_path: []u8,
    show_sweep: bool,
    outcome: union(enum) {
        discovered: struct {
            inspection: WorktreeStatus.Inspection,
            policy: WorktreeStatus.PolicyOutcome,
        },
        sized: struct {
            path: []u8,
            size: WorktreeStatus.SizeCoverage,
        },
        failed: anyerror,
        finished,
    },

    fn deinit(self: *WorktreeInspectionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.project_path);
        switch (self.outcome) {
            .discovered => |*value| {
                if (value.inspection.project_path.len != 0)
                    WorktreeStatus.deinitInspection(allocator, &value.inspection);
            },
            .sized => |value| allocator.free(value.path),
            .failed, .finished => {},
        }
    }
};
const tray_test_hook_environment = "GRAPHCODE_TRAY_TEST_HOOK";
const daemon_supervisor_test_hook_environment = "GRAPHCODE_DAEMON_SUPERVISOR_TEST_HOOK";
const daemon_handoff_test_user_environment = "GRAPHCODE_DAEMON_HANDOFF_TEST_USER";
const daemon_supervisor_test_property =
    std.unicode.utf8ToUtf16LeStringLiteral("GraphCode.Windows.DaemonSupervisorState");

fn runFirstRunStartup(
    context: anytype,
    should_show: bool,
    comptime schedule_connection: fn (@TypeOf(context)) void,
    comptime show_modal: fn (@TypeOf(context)) void,
) bool {
    if (!should_show) return false;
    schedule_connection(context);
    show_modal(context);
    return true;
}

const FirstRunStartup = struct {
    const Context = struct {
        app: *App,
        store: Onboarding.Store,
        initial_backend: []const u8,
    };

    fn scheduleConnection(context: *Context) void {
        context.app.client.setCallback(&onDaemonFrame, context.app);
        context.app.client.connect();
    }

    fn showModal(context: *Context) void {
        if (Onboarding.showFirstRun(
            context.app.window.hwnd,
            context.app.allocator,
            context.store,
            context.initial_backend,
        ) catch null) |backend| {
            context.app.applyOnboardingBackend(backend);
        }
    }
};

const WorkspaceKeyRoute = union(enum) {
    action: InputRouter.Action,
    copy_terminal_selection,
    paste_clipboard_text,
};

fn terminalPasteFailureStatus(err: anyerror) []const u8 {
    if (err == error.TerminalPasteRequiresConfirmation) {
        return "Terminal blocked unsafe clipboard text; paste a single line to continue";
    }
    if (err == error.TerminalClipboardUnavailable) return "Terminal clipboard is unavailable";
    return "Unable to paste clipboard text";
}

extern fn graphcode_pick_folder(owner: c.HWND, buffer: [*]u16, capacity: c.DWORD) callconv(.c) c_int;

const folder_open_timer_id: usize = 44;
const folder_open_timer_interval_ms: c.UINT = 1;

const FolderOpenApi = struct {
    fn armTimer(hwnd: c.HWND, id: usize, interval_ms: c.UINT) bool {
        return c.SetTimer(hwnd, id, interval_ms, null) != 0;
    }

    fn cancelTimer(hwnd: c.HWND, id: usize) void {
        _ = c.KillTimer(hwnd, id);
    }

    fn openProject(app: *App, path: []const u8) void {
        app.openProject(path);
    }
};

const WorkspaceUserApi = struct {
    fn read(buffer: [*]u16, size: *c.DWORD) bool {
        return c.GetUserNameW(buffer, size) != 0;
    }
};

fn workspaceUserWith(allocator: std.mem.Allocator, comptime Api: type) ![]u8 {
    var wide: [257]u16 = [_]u16{0} ** 257;
    var size: c.DWORD = wide.len;
    if (!Api.read(&wide, &size) or size == 0 or size > wide.len)
        return error.WorkspaceUserUnavailable;
    const length = if (wide[size - 1] == 0) size - 1 else size;
    if (length == 0) return error.WorkspaceUserUnavailable;
    return std.unicode.utf16LeToUtf8Alloc(allocator, wide[0..length]);
}

fn workspaceUser(allocator: std.mem.Allocator) ![]u8 {
    if (envFlag(daemon_supervisor_test_hook_environment)) {
        const test_user = std.process.getEnvVarOwned(
            allocator,
            daemon_handoff_test_user_environment,
        ) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (test_user) |user| {
            if (user.len != 0) return user;
            allocator.free(user);
            return error.WorkspaceUserUnavailable;
        }
    }
    return workspaceUserWith(allocator, WorkspaceUserApi);
}

fn workspaceInstanceKey(allocator: std.mem.Allocator, path: []const u8) ![:0]u16 {
    const user = try workspaceUser(allocator);
    defer allocator.free(user);
    const name = try WorkspaceLifecycle.instanceName(allocator, user, path);
    defer allocator.free(name);
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
}

pub fn restoreCurrentWorkspace(allocator: std.mem.Allocator) !void {
    const path = try WorkspaceLifecycle.currentPath(allocator);
    defer allocator.free(path);
    const key = try workspaceInstanceKey(allocator, path);
    defer allocator.free(key);
    try MainWindow.restoreExistingInstance(key);
}

const WorkspaceReservation = struct {
    handles: [2]c.HANDLE = .{ null, null },

    fn acquire(allocator: std.mem.Allocator, path: []const u8) !WorkspaceReservation {
        const user = try workspaceUser(allocator);
        defer allocator.free(user);
        return acquireForUser(allocator, user, path);
    }

    fn acquireForUser(allocator: std.mem.Allocator, user: []const u8, path: []const u8) !WorkspaceReservation {
        const canonical = try WorkspaceLifecycle.instanceName(allocator, user, path);
        defer allocator.free(canonical);
        const legacy = try WorkspaceLifecycle.legacyInstanceName(allocator, user, path);
        defer allocator.free(legacy);
        var result = WorkspaceReservation{};
        errdefer result.deinit();
        const names = [_][]const u8{ canonical, legacy };
        for (names, 0..) |name, index| {
            if (index == 1 and std.mem.eql(u8, canonical, legacy)) break;
            const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
            defer allocator.free(wide);
            const handle = c.CreateMutexW(null, 1, wide.ptr) orelse return error.WorkspaceReservationFailed;
            const last_error = c.GetLastError();
            if (last_error == c.ERROR_ALREADY_EXISTS) {
                _ = c.CloseHandle(handle);
                return error.WorkspaceInUse;
            }
            result.handles[index] = handle;
        }
        return result;
    }

    fn deinit(self: *WorkspaceReservation) void {
        for (&self.handles) |*handle| {
            if (handle.* != null) {
                _ = c.ReleaseMutex(handle.*);
                _ = c.CloseHandle(handle.*);
                handle.* = null;
            }
        }
    }
};

const WorkspaceProcess = struct {
    fn windows(key: [:0]const u16) !MainWindow.WorkspaceWindows {
        return MainWindow.workspaceWindows(key);
    }

    fn restore(key: [:0]const u16) !void {
        try MainWindow.restoreExistingInstance(key);
    }

    fn launch(allocator: std.mem.Allocator, path: []const u8) !void {
        const block = try workspaceEnvironment(allocator, path);
        defer allocator.free(block);
        var executable: [32768]u16 = undefined;
        const length = c.GetModuleFileNameW(null, &executable, executable.len);
        if (length == 0 or length >= executable.len) return error.WorkspaceExecutablePathFailed;
        executable[length] = 0;
        var startup: c.STARTUPINFOW = std.mem.zeroes(c.STARTUPINFOW);
        startup.cb = @sizeOf(c.STARTUPINFOW);
        var process: c.PROCESS_INFORMATION = undefined;
        if (c.CreateProcessW(executable[0..length :0].ptr, null, null, null, 0, c.CREATE_UNICODE_ENVIRONMENT, block.ptr, null, &startup, &process) == 0)
            return error.WorkspaceLaunchFailed;
        _ = c.CloseHandle(process.hThread);
        _ = c.CloseHandle(process.hProcess);
    }
};

const WorkspaceCycleApi = struct {
    const instanceKey = workspaceInstanceKey;
    const windows = WorkspaceProcess.windows;
    const restore = MainWindow.restoreCycleInstance;

    fn list(allocator: std.mem.Allocator, current: []const u8) !WorkspaceLifecycle.List {
        const home = try std.process.getEnvVarOwned(allocator, "USERPROFILE");
        defer allocator.free(home);
        return WorkspaceLifecycle.managerListFromHome(allocator, home, current);
    }
};

fn workspaceEnvironment(allocator: std.mem.Allocator, path: []const u8) ![]u16 {
    var environment = try std.process.getEnvMap(allocator);
    defer environment.deinit();
    try environment.put("GRAPHCODE_SUPPORT_DIR", path);
    environment.remove("GRAPHCODE_DAEMON_PIPE");
    return std.process.createWindowsEnvBlock(allocator, &environment);
}

const WorkspaceOpenResult = enum { current, restored, launched };

fn openWorkspaceWith(comptime Api: type, allocator: std.mem.Allocator, current_identity: []const u8, path: []const u8) !WorkspaceOpenResult {
    const identity = try WorkspaceLifecycle.pathIdentity(allocator, path);
    defer allocator.free(identity);
    if (std.mem.eql(u8, current_identity, identity)) return .current;
    const key = try workspaceInstanceKey(allocator, path);
    defer allocator.free(key);
    const windows = try Api.windows(key);
    if (windows.target != null) {
        try Api.restore(key);
        return .restored;
    }
    if (windows.unidentified) return error.UnidentifiedWorkspaceWindow;
    try Api.launch(allocator, path);
    return .launched;
}

const WorkspaceMutation = union(enum) { rename: []const u8, delete };
const WorkspaceMutationResult = union(enum) {
    renamed,
    cancelled,
    /// Deletion ran; the report says how far it got and what, if anything, it put back.
    torn_down: WorkspaceTeardown.Report,
};
const workspace_delete_confirmation_flags = c.MB_YESNO | c.MB_ICONWARNING | c.MB_DEFBUTTON2;

/// Recovery ownership survives formatting failures and later transient statuses.
const WorkspaceRecoveryState = struct {
    report: ?WorkspaceTeardown.Report = null,
    message: ?[]u8 = null,
    active: bool = false,
    formatting_error: ?anyerror = null,
    secondary_refresh_error: ?anyerror = null,

    fn take(self: *WorkspaceRecoveryState, allocator: std.mem.Allocator, report: *WorkspaceTeardown.Report) void {
        self.deinit(allocator);
        self.report = report.*;
        report.staged_path = null;
        self.active = true;
    }

    fn text(self: *const WorkspaceRecoveryState) ?[]const u8 {
        if (!self.active) return null;
        if (self.message) |message| return message;
        const report = self.report.?;
        return switch (report.outcome) {
            .stranded => report.staged_path orelse "Workspace could not be restored; its recovery path is unavailable.",
            .deleted => "Workspace moved to the Recycle Bin; detailed session results are unavailable.",
            .refused => "Workspace not deleted; detailed failure information is unavailable.",
            .rolled_back => "Workspace restored after deletion failed; detailed failure information is unavailable.",
        };
    }

    fn deinit(self: *WorkspaceRecoveryState, allocator: std.mem.Allocator) void {
        if (self.message) |message| allocator.free(message);
        if (self.report) |*report| report.deinit(allocator);
        self.* = .{};
    }
};

fn consumeWorkspaceTeardownReportWith(
    comptime Api: type,
    context: anytype,
    allocator: std.mem.Allocator,
    recovery: *WorkspaceRecoveryState,
    report: *WorkspaceTeardown.Report,
) void {
    recovery.take(allocator, report);
    const retained = recovery.report.?;
    Api.logPrimary(context, retained);
    recovery.message = Api.describe(context, allocator, retained) catch |err| blk: {
        recovery.formatting_error = err;
        Api.logFormattingFailure(context, err, retained);
        break :blk null;
    };
    Api.publish(context, recovery);
    Api.refresh(context) catch |err| {
        recovery.secondary_refresh_error = err;
        Api.logRefreshFailure(context, err, retained);
    };
}

const WorkspaceTeardownPresentationApi = struct {
    fn refresh(app: *App) !void {
        try app.revalidateWorkspaceIdentity();
        try app.reloadWorkspaceList();
    }

    fn describe(_: *App, allocator: std.mem.Allocator, report: WorkspaceTeardown.Report) ![]u8 {
        return WorkspaceTeardown.statusMessage(allocator, report);
    }

    fn logPrimary(_: *App, report: WorkspaceTeardown.Report) void {
        const cause = if (report.cause) |err| @errorName(err) else "none";
        const path = report.staged_path orelse "not staged";
        if (report.outcome == .deleted) {
            std.log.info("Workspace deletion outcome={s}, cause={s}, recovery path={s}", .{ @tagName(report.outcome), cause, path });
        } else {
            std.log.err("Workspace deletion outcome={s}, cause={s}, recovery path={s}", .{ @tagName(report.outcome), cause, path });
        }
    }

    fn logFormattingFailure(_: *App, err: anyerror, report: WorkspaceTeardown.Report) void {
        std.log.err("Workspace deletion result formatting failed: {s}; outcome={s}, recovery path={s}", .{
            @errorName(err), @tagName(report.outcome), report.staged_path orelse "not staged",
        });
    }

    fn logRefreshFailure(_: *App, err: anyerror, report: WorkspaceTeardown.Report) void {
        std.log.err("Workspace list refresh failed after deletion: {s}; primary outcome={s}, recovery path={s}", .{
            @errorName(err), @tagName(report.outcome), report.staged_path orelse "not staged",
        });
    }

    fn publish(app: *App, recovery: *const WorkspaceRecoveryState) void {
        const message = recovery.text().?;
        Diagnostics.record(app.allocator, "status", message);
        app.syncAccessibility();
        if (app.accessibility) |*provider| {
            provider.announce(message, if (recovery.report.?.outcome == .deleted) .status else .@"error") catch |err|
                std.log.err("Workspace deletion result announcement failed: {s}", .{@errorName(err)});
        }
    }
};

const WorkspaceRecoveryStep = enum { primary, describe, publish, refresh, formatting_failure, refresh_failure };

const WorkspaceRecoveryFixture = struct {
    steps: [16]WorkspaceRecoveryStep = undefined,
    count: usize = 0,
    refresh_error: ?anyerror = null,
    description_error: ?anyerror = null,
    supplied_message: ?[]u8 = null,
    published_text: ?[]const u8 = null,
    logged_staged_path: ?[]const u8 = null,
    logged_cause: ?anyerror = null,
    logged_formatting_error: ?anyerror = null,
    logged_refresh_error: ?anyerror = null,

    fn record(self: *WorkspaceRecoveryFixture, step: WorkspaceRecoveryStep) void {
        std.debug.assert(self.count < self.steps.len);
        self.steps[self.count] = step;
        self.count += 1;
    }

    fn deinit(self: *WorkspaceRecoveryFixture) void {
        if (self.supplied_message) |message| std.testing.allocator.free(message);
    }

    fn refresh(self: *WorkspaceRecoveryFixture) !void {
        self.record(.refresh);
        if (self.refresh_error) |err| return err;
    }

    fn describe(self: *WorkspaceRecoveryFixture, allocator: std.mem.Allocator, report: WorkspaceTeardown.Report) ![]u8 {
        self.record(.describe);
        if (self.description_error) |err| return err;
        if (self.supplied_message) |message| {
            self.supplied_message = null;
            return message;
        }
        return WorkspaceTeardown.statusMessage(allocator, report);
    }

    fn logPrimary(self: *WorkspaceRecoveryFixture, report: WorkspaceTeardown.Report) void {
        self.record(.primary);
        self.logged_cause = report.cause;
        self.logged_staged_path = report.staged_path;
    }

    fn logFormattingFailure(self: *WorkspaceRecoveryFixture, err: anyerror, _: WorkspaceTeardown.Report) void {
        self.record(.formatting_failure);
        self.logged_formatting_error = err;
    }

    fn logRefreshFailure(self: *WorkspaceRecoveryFixture, err: anyerror, _: WorkspaceTeardown.Report) void {
        self.record(.refresh_failure);
        self.logged_refresh_error = err;
    }

    fn publish(self: *WorkspaceRecoveryFixture, recovery: *const WorkspaceRecoveryState) void {
        self.record(.publish);
        self.published_text = recovery.text();
    }
};

test "workspace recovery report survives refresh failure" {
    const allocator = std.testing.allocator;
    var recovery = WorkspaceRecoveryState{};
    defer recovery.deinit(allocator);
    var report = WorkspaceTeardown.Report{
        .outcome = .stranded,
        .cause = error.OutOfMemory,
        .staged_path = try allocator.dupe(u8, "C:\\fixture\\.gc-deleting-4242-.graphcode-alpha"),
        .sessions_known = false,
    };
    defer report.deinit(allocator);
    var fixture = WorkspaceRecoveryFixture{ .refresh_error = error.MetadataReadFailed };
    defer fixture.deinit();
    consumeWorkspaceTeardownReportWith(WorkspaceRecoveryFixture, &fixture, allocator, &recovery, &report);
    report.deinit(allocator);
    try std.testing.expect(recovery.report != null);
    try std.testing.expectEqual(WorkspaceTeardown.Outcome.stranded, recovery.report.?.outcome);
    try std.testing.expectEqualStrings(
        "C:\\fixture\\.gc-deleting-4242-.graphcode-alpha",
        recovery.report.?.staged_path.?,
    );
    try std.testing.expectEqual(@as(?anyerror, error.MetadataReadFailed), recovery.secondary_refresh_error);
    try std.testing.expectEqual(@as(?anyerror, error.MetadataReadFailed), fixture.logged_refresh_error);
    try std.testing.expectEqual(@as(?anyerror, error.OutOfMemory), fixture.logged_cause);
    try std.testing.expectEqualStrings(recovery.report.?.staged_path.?, fixture.logged_staged_path.?);
    try std.testing.expect(std.mem.indexOf(u8, fixture.published_text.?, recovery.report.?.staged_path.?) != null);
    try std.testing.expectEqual(@as(?anyerror, null), recovery.formatting_error);
    try std.testing.expect(recovery.active);
    try std.testing.expectEqualSlices(
        WorkspaceRecoveryStep,
        &.{ .primary, .describe, .publish, .refresh, .refresh_failure },
        fixture.steps[0..fixture.count],
    );
}

test "workspace recovery report survives persistent formatting failure" {
    const allocator = std.testing.allocator;
    var recovery = WorkspaceRecoveryState{};
    defer recovery.deinit(allocator);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var fixture = WorkspaceRecoveryFixture{ .refresh_error = error.AccessDenied };
    defer fixture.deinit();
    for (0..2) |_| {
        var report = WorkspaceTeardown.Report{
            .outcome = .stranded,
            .cause = error.OutOfMemory,
            .staged_path = try allocator.dupe(u8, "C:\\fixture\\.gc-deleting-4242-.graphcode-alpha"),
            .sessions_known = false,
        };
        defer report.deinit(allocator);
        consumeWorkspaceTeardownReportWith(WorkspaceRecoveryFixture, &fixture, failing.allocator(), &recovery, &report);
        report.deinit(allocator);
        try std.testing.expect(recovery.active);
        try std.testing.expect(recovery.message == null);
        try std.testing.expectEqualStrings(recovery.report.?.staged_path.?, recovery.text().?);
        try std.testing.expectEqualStrings(recovery.report.?.staged_path.?, fixture.published_text.?);
        try std.testing.expectEqual(@as(?anyerror, error.OutOfMemory), recovery.formatting_error);
        try std.testing.expectEqual(@as(?anyerror, error.OutOfMemory), fixture.logged_formatting_error);
        try std.testing.expectEqual(@as(?anyerror, error.AccessDenied), recovery.secondary_refresh_error);
        try std.testing.expectEqual(@as(?anyerror, error.AccessDenied), fixture.logged_refresh_error);
        for ([_][]const u8{ "deleted", "restored", "finished" }) |claim|
            try std.testing.expect(std.mem.indexOf(u8, recovery.text().?, claim) == null);
    }
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqualSlices(
        WorkspaceRecoveryStep,
        &.{ .primary, .describe, .formatting_failure, .publish, .refresh, .refresh_failure },
        fixture.steps[0..6],
    );
    try std.testing.expectEqualSlices(WorkspaceRecoveryStep, fixture.steps[0..6], fixture.steps[6..fixture.count]);
}

test "workspace recovery owned message needs no second status allocation" {
    const allocator = std.testing.allocator;
    var recovery = WorkspaceRecoveryState{};
    defer recovery.deinit(allocator);
    var report = WorkspaceTeardown.Report{
        .outcome = .stranded,
        .cause = error.WorkspaceRecycleFailed,
        .staged_path = try allocator.dupe(u8, "C:\\fixture\\.gc-deleting-4242-.graphcode-alpha"),
    };
    defer report.deinit(allocator);
    const message = try WorkspaceTeardown.statusMessage(allocator, report);
    var fixture = WorkspaceRecoveryFixture{ .supplied_message = message };
    defer fixture.deinit();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    consumeWorkspaceTeardownReportWith(WorkspaceRecoveryFixture, &fixture, failing.allocator(), &recovery, &report);
    report.deinit(allocator);
    try std.testing.expectEqual(message.ptr, recovery.message.?.ptr);
    try std.testing.expect(message.ptr == fixture.published_text.?.ptr);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(?anyerror, null), recovery.formatting_error);
    try std.testing.expectEqual(@as(?anyerror, null), recovery.secondary_refresh_error);
    try std.testing.expect(report.staged_path == null);
}

test "workspace recovery replacement and teardown free ownership once" {
    const allocator = std.testing.allocator;
    var recovery = WorkspaceRecoveryState{};
    defer recovery.deinit(allocator);
    var fixture = WorkspaceRecoveryFixture{};
    defer fixture.deinit();
    for ([_][]const u8{
        "C:\\fixture\\.gc-deleting-4242-.graphcode-alpha",
        "C:\\fixture\\.gc-deleting-4242-.graphcode-beta",
    }) |path| {
        var report = WorkspaceTeardown.Report{
            .outcome = .stranded,
            .cause = error.WorkspaceRecycleFailed,
            .staged_path = try allocator.dupe(u8, path),
        };
        defer report.deinit(allocator);
        consumeWorkspaceTeardownReportWith(WorkspaceRecoveryFixture, &fixture, allocator, &recovery, &report);
        report.deinit(allocator);
        try std.testing.expectEqualStrings(path, recovery.report.?.staged_path.?);
        try std.testing.expect(std.mem.indexOf(u8, recovery.text().?, path) != null);
    }
    recovery.active = false;
    try std.testing.expect(recovery.text() == null);
    try std.testing.expectEqualStrings("C:\\fixture\\.gc-deleting-4242-.graphcode-beta", recovery.report.?.staged_path.?);
    recovery.deinit(allocator);
    try std.testing.expect(recovery.report == null);
    try std.testing.expect(recovery.message == null);
    try std.testing.expect(!recovery.active);
    recovery.deinit(allocator);
}

test "workspace recovery retains actual nonstranded outcomes on refresh failure" {
    const allocator = std.testing.allocator;
    for ([_]WorkspaceTeardown.Outcome{ .deleted, .refused, .rolled_back }) |outcome| {
        for ([_]bool{ false, true }) |known| {
            for ([_]bool{ false, true }) |fail_description| {
                var recovery = WorkspaceRecoveryState{};
                defer recovery.deinit(allocator);
                const count: usize = if (outcome == .deleted and known) 9 else 0;
                const cause: ?anyerror = if (outcome == .deleted) null else error.WorkspaceRecycleFailed;
                var report = WorkspaceTeardown.Report{
                    .outcome = outcome,
                    .cause = cause,
                    .sessions_targeted = count,
                    .sessions_known = known,
                };
                defer report.deinit(allocator);
                const description_error: ?anyerror = if (fail_description) error.OutOfMemory else null;
                var fixture = WorkspaceRecoveryFixture{
                    .refresh_error = error.MetadataReadFailed,
                    .description_error = description_error,
                };
                defer fixture.deinit();
                consumeWorkspaceTeardownReportWith(WorkspaceRecoveryFixture, &fixture, allocator, &recovery, &report);
                try std.testing.expectEqual(outcome, recovery.report.?.outcome);
                try std.testing.expectEqual(cause, recovery.report.?.cause);
                try std.testing.expectEqual(count, recovery.report.?.sessions_targeted);
                try std.testing.expectEqual(known, recovery.report.?.sessions_known);
                try std.testing.expectEqual(description_error, recovery.formatting_error);
                try std.testing.expectEqual(@as(?anyerror, error.MetadataReadFailed), recovery.secondary_refresh_error);
                if (outcome == .deleted and !known and !fail_description) {
                    try std.testing.expect(std.mem.indexOf(u8, recovery.text().?, "may still be running") != null);
                    try std.testing.expect(std.mem.indexOf(u8, recovery.text().?, "0 saved terminal") == null);
                }
                if (fail_description and outcome != .deleted)
                    try std.testing.expect(std.mem.indexOf(u8, recovery.text().?, "moved to the Recycle Bin") == null);
            }
        }
    }
}

const WorkspaceMutationApi = struct {
    const reserve = WorkspaceReservation.acquire;
    const windows = WorkspaceProcess.windows;

    fn confirm(owner: c.HWND) c.INT {
        return c.MessageBoxW(
            owner,
            std.unicode.utf8ToUtf16LeStringLiteral(WorkspaceTeardown.confirmation_text).ptr,
            std.unicode.utf8ToUtf16LeStringLiteral(WorkspaceTeardown.delete_caption).ptr,
            workspace_delete_confirmation_flags,
        );
    }

    fn rename(allocator: std.mem.Allocator, source: []const u8, destination: []const u8) !void {
        const from = try std.unicode.utf8ToUtf16LeAllocZ(allocator, source);
        defer allocator.free(from);
        const to = try std.unicode.utf8ToUtf16LeAllocZ(allocator, destination);
        defer allocator.free(to);
        if (c.MoveFileW(from.ptr, to.ptr) == 0) return error.WorkspaceRenameFailed;
    }

    fn delete(
        allocator: std.mem.Allocator,
        path: []const u8,
        current_identity: []const u8,
    ) !WorkspaceTeardown.Report {
        return WorkspaceTeardown.deleteRecoverably(allocator, path, current_identity);
    }
};

fn requireIdentifiedClosedWorkspace(comptime Api: type, key: [:0]const u16) !void {
    const windows = try Api.windows(key);
    if (windows.unidentified) return error.UnidentifiedWorkspaceWindow;
    if (windows.target != null) return error.WorkspaceInUse;
}

fn workspaceManagerWindowState(comptime Api: type, key: [:0]const u16) WorkspaceManager.WindowState {
    const windows = Api.windows(key) catch return .unavailable;
    if (windows.unidentified) return .unidentified;
    return if (windows.target != null) .open else .closed;
}

fn mutateWorkspaceWith(
    comptime Api: type,
    allocator: std.mem.Allocator,
    owner: c.HWND,
    current_identity: []const u8,
    workspace: WorkspaceLifecycle.Workspace,
    mutation: WorkspaceMutation,
) !WorkspaceMutationResult {
    if (workspace.is_default) return error.DefaultWorkspace;
    // The confirmation pumps messages that can refresh and free workspace_list.
    const source = try allocator.dupe(u8, workspace.path);
    defer allocator.free(source);
    const identity = try WorkspaceLifecycle.pathIdentity(allocator, source);
    defer allocator.free(identity);
    if (std.mem.eql(u8, identity, current_identity)) return error.CurrentWorkspace;
    var reservation = try Api.reserve(allocator, source);
    defer reservation.deinit();
    const key = try workspaceInstanceKey(allocator, source);
    defer allocator.free(key);
    try requireIdentifiedClosedWorkspace(Api, key);
    switch (mutation) {
        .rename => |destination| {
            var destination_reservation = try Api.reserve(allocator, destination);
            defer destination_reservation.deinit();
            const destination_key = try workspaceInstanceKey(allocator, destination);
            defer allocator.free(destination_key);
            try requireIdentifiedClosedWorkspace(Api, destination_key);
            try Api.rename(allocator, source, destination);
            return .renamed;
        },
        .delete => {
            if (Api.confirm(owner) != c.IDYES) return .cancelled;
            try requireIdentifiedClosedWorkspace(Api, key);
            // The confirmation pumped messages, so the target is re-derived from the path
            // we captured and re-checked against Default and this window before any effect.
            const confirmed = try WorkspaceLifecycle.pathIdentity(allocator, source);
            defer allocator.free(confirmed);
            if (!std.mem.eql(u8, confirmed, identity)) return error.WorkspaceIdentityChanged;
            if (std.mem.eql(u8, confirmed, current_identity)) return error.CurrentWorkspace;
            var directory = try std.fs.openDirAbsolute(source, .{});
            directory.close();
            return .{ .torn_down = try Api.delete(allocator, source, current_identity) };
        },
    }
}

fn workspaceMutationFailure(err: anyerror) []const u8 {
    return switch (err) {
        error.DefaultWorkspace => "The default workspace cannot be renamed or deleted",
        error.CurrentWorkspace => "The current workspace cannot be renamed or deleted",
        error.WorkspaceInUse => "That workspace is open in another window; quit it first",
        error.UnidentifiedWorkspaceWindow => "Close older GraphCode windows before changing a workspace",
        else => "Workspace could not be changed safely",
    };
}

/// Deterministic targets and screen position used only by the live UIA gate's
/// context-menu hook (`MainWindow.wm_uia_context_menu`).
const uia_context_menu_remote_project_path = "ssh://builder/GraphCode";
const uia_context_menu_x: i32 = 160;
const uia_context_menu_y: i32 = 160;

fn normalizeUiaFixtureProject(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const identity = WorkspaceLifecycle.pathIdentity(allocator, path) catch |err| return switch (err) {
        error.OutOfMemory => err,
        else => error.InvalidUiaFixtureProject,
    };
    defer allocator.free(identity);
    const normalized = try std.fs.path.resolveWindows(allocator, &.{path});
    errdefer allocator.free(normalized);
    const parent = std.fs.path.dirnameWindows(normalized) orelse return error.InvalidUiaFixtureProject;
    if (parent.len == normalized.len or normalized.len <= 3) return error.InvalidUiaFixtureProject;
    return normalized;
}

const UiaFixturePath = enum { project, safe, unsafe, empty, jump, sweep_safe, sweep_unsafe };

fn uiaFixturePath(allocator: std.mem.Allocator, project: []const u8, kind: UiaFixturePath) ![]u8 {
    return switch (kind) {
        .project => allocator.dupe(u8, project),
        .safe => std.fs.path.join(allocator, &.{ project, "fixture-safe" }),
        .unsafe => std.fs.path.join(allocator, &.{ project, "fixture-unsafe" }),
        .empty => std.fs.path.join(allocator, &.{ project, "empty" }),
        .jump => std.fs.path.join(allocator, &.{ project, "jump-fixture" }),
        .sweep_safe => std.fs.path.join(allocator, &.{ project, "fixture-worktrees", "reclaimable" }),
        .sweep_unsafe => std.fs.path.join(allocator, &.{ project, "fixture-worktrees", "dirty" }),
    };
}

fn uiaFixtureGraphFrame(allocator: std.mem.Allocator, path: []const u8, name: []const u8, sequence: usize, nodes: []const u8, edges: []const u8) ![]u8 {
    const quoted_path = try std.json.Stringify.valueAlloc(allocator, path, .{});
    defer allocator.free(quoted_path);
    const quoted_name = try std.json.Stringify.valueAlloc(allocator, name, .{});
    defer allocator.free(quoted_name);
    return std.fmt.allocPrint(allocator, "{{\"version\":2,\"kind\":\"event\",\"sequence\":{d},\"event\":{{\"graphChanged\":{{\"project\":{{\"path\":{s},\"name\":{s}}},\"nodes\":{s},\"edges\":{s}}}}}}}", .{ sequence, quoted_path, quoted_name, nodes, edges });
}

const UiaFixtureData = struct {
    model_arena: *std.heap.ArenaAllocator,
    model: GraphModel.Model,
    inspection: WorktreeStatus.Inspection,
    dialog: WorktreeDialog.Dialog,

    fn init(allocator: std.mem.Allocator, project_path: []const u8) !UiaFixtureData {
        const project = try normalizeUiaFixtureProject(allocator, project_path);
        errdefer allocator.free(project);
        const safe_path = try uiaFixturePath(allocator, project, .safe);
        defer allocator.free(safe_path);
        const quoted_safe = try std.json.Stringify.valueAlloc(allocator, safe_path, .{});
        defer allocator.free(quoted_safe);
        const nodes = try std.mem.concat(allocator, u8, &.{
            "[{\"id\":\"11111111-1111-4111-8111-111111111111\",\"title\":\"UIA loop A\",\"loopType\":\"goalBased\",\"state\":\"succeeded\",\"activity\":\"checking tests\",\"presence\":{\"presence\":\"idle\",\"confidence\":\"reported\"},\"createdAt\":788918400,\"goal\":{\"summary\":\"All tests pass\",\"predicate\":\"swift test\",\"metric\":{\"command\":\"coverage\",\"direction\":\"maximize\"}},\"metricHistory\":[{\"value\":1},{\"value\":2},{\"value\":3}],\"usage\":{\"inputTokens\":1200,\"outputTokens\":345},\"modelTier\":\"capable\",\"worktreeBinding\":{\"path\":",
            quoted_safe,
            ",\"branch\":\"feature/parity\"}},{\"id\":\"22222222-2222-4222-8222-222222222222\",\"title\":\"UIA loop B\",\"loopType\":\"proactive\",\"state\":\"running\",\"activity\":\"needs response\",\"presence\":{\"presence\":\"awaitingInput\",\"confidence\":\"reported\"},\"createdAt\":788918400,\"usage\":{\"inputTokens\":12,\"outputTokens\":34},\"subGraph\":{\"nodes\":[{\"id\":\"55555555-5555-4555-8555-555555555555\",\"title\":\"UIA nested A\",\"loopType\":\"turnBased\",\"state\":\"idle\"},{\"id\":\"66666666-6666-4666-8666-666666666666\",\"title\":\"UIA nested B\",\"loopType\":\"goalBased\",\"state\":\"running\"}]}}]",
        });
        defer allocator.free(nodes);
        const graph_frame = try uiaFixtureGraphFrame(allocator, project, "UIA project", 1, nodes,
            \\[{"id":"88888888-8888-4888-8888-888888888888","from":"11111111-1111-4111-8111-111111111111","to":"22222222-2222-4222-8222-222222222222","kind":"handoff"}]
        );
        defer allocator.free(graph_frame);
        const model_arena = try allocator.create(std.heap.ArenaAllocator);
        model_arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            model_arena.deinit();
            allocator.destroy(model_arena);
        }
        var model = GraphModel.Model.init(model_arena.allocator());
        errdefer model.deinit();
        const chats_frame =
            \\{"version":2,"kind":"event","sequence":2,"event":{"quickChatsListed":[{"id":"33333333-3333-4333-8333-333333333333","title":"UIA chat A","backend":"claudeCode","createdAt":0,"activity":null},{"id":"44444444-4444-4444-8444-444444444444","title":"UIA chat B","backend":"copilot","createdAt":1,"activity":null}]}}
        ;
        const quoted_project = try std.json.Stringify.valueAlloc(allocator, project, .{});
        defer allocator.free(quoted_project);
        const projects_frame = try std.mem.concat(allocator, u8, &.{
            "{\"version\":2,\"kind\":\"event\",\"sequence\":3,\"event\":{\"recentProjectsListed\":[{\"path\":",
            quoted_project,
            ",\"name\":\"Fixture local\"},{\"path\":\"ssh://builder/GraphCode\",\"name\":\"Fixture remote\"}]}}",
        });
        defer allocator.free(projects_frame);
        _ = try model.updateFromFrame(graph_frame);
        _ = try model.updateFromFrame(chats_frame);
        _ = try model.updateFromFrame(projects_frame);
        const graph = model.graph orelse return error.InvalidUiaFixtureData;
        if (!std.mem.eql(u8, graph.project.path, project) or graph.nodes.items.len != 2 or model.quick_chats.items.len != 2 or model.recent_projects.items.len != 2)
            return error.InvalidUiaFixtureData;
        const default_branch = try allocator.dupe(u8, "main");
        errdefer allocator.free(default_branch);
        var entries = std.array_list.Managed(WorktreeStatus.Entry).init(allocator);
        errdefer WorktreeStatus.deinit(allocator, &entries);
        for ([_]bool{ false, true }) |dirty| {
            const path = try uiaFixturePath(allocator, project, if (dirty) .unsafe else .safe);
            errdefer allocator.free(path);
            const branch = try allocator.dupe(u8, if (dirty) "unsafe" else "safe");
            errdefer allocator.free(branch);
            try entries.append(.{ .path = path, .branch = branch, .dirty = dirty, .pushed = true, .landed = true });
        }
        const inspection = WorktreeStatus.Inspection{ .entries = entries, .default_branch = default_branch, .project_path = project };
        const dialog = try WorktreeDialog.Dialog.init(allocator, project, entries.items, .{ .allow_reclaim = true });
        return .{ .model_arena = model_arena, .model = model, .inspection = inspection, .dialog = dialog };
    }

    fn deinit(self: *UiaFixtureData, allocator: std.mem.Allocator) void {
        self.dialog.deinit();
        WorktreeStatus.deinitInspection(allocator, &self.inspection);
        self.model.deinit();
        self.model_arena.deinit();
        allocator.destroy(self.model_arena);
    }
};

const InputBounds = struct {
    rail_left: i32,
    workspace_top: i32,
    canvas: GraphCanvas.RenderBounds,
};

const WheelRegion = enum { sidebar, canvas, none };

const AccessibilityBounds = union(enum) {
    logical: c.RECT,
    physical: c.RECT,

    fn physicalRect(self: AccessibilityBounds, dpi: u32) c.RECT {
        return switch (self) {
            .logical => |bounds| .{
                .left = physicalCoordinate(bounds.left, dpi),
                .top = physicalCoordinate(bounds.top, dpi),
                .right = physicalCoordinate(bounds.right, dpi),
                .bottom = physicalCoordinate(bounds.bottom, dpi),
            },
            .physical => |bounds| bounds,
        };
    }
};

fn clipSidebarAccessibilityBounds(bounds: c.RECT, viewport_bottom: i32) c.RECT {
    const top = @max(bounds.top, Tokens.header_height);
    const bottom = @min(bounds.bottom, viewport_bottom);
    if (top >= bottom) return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    return .{ .left = bounds.left, .top = top, .right = bounds.right, .bottom = bottom };
}

fn inputBounds(client_right: i32, client_bottom: i32, controls: WorkspaceControls.State) InputBounds {
    return .{
        .rail_left = if (controls.rail_visible) Tokens.sidebar_width else 0,
        .workspace_top = client_bottom - (if (controls.panel_visible) Tokens.workspace_height else 0),
        .canvas = GraphCanvas.renderBounds(client_right, client_bottom, controls),
    };
}

fn logicalClientRect(hwnd: c.HWND, dpi: u32) c.RECT {
    var client: c.RECT = undefined;
    if (c.GetClientRect(hwnd, &client) == 0) return std.mem.zeroes(c.RECT);
    client.right = Dpi.unscale(client.right, dpi);
    client.bottom = Dpi.unscale(client.bottom, dpi);
    return client;
}

fn logicalCoordinate(value: i32, dpi: u32) i32 {
    return Dpi.unscale(value, dpi);
}

fn physicalCoordinate(value: i32, dpi: u32) i32 {
    return Dpi.scale(value, dpi);
}

fn gestureGeometry(point: ?c.POINT, client: c.RECT, dpi: u32, controls: WorkspaceControls.State) struct {
    point: ?c.POINT,
    bounds: InputBounds,
} {
    return .{
        .point = if (point) |value| .{
            .x = logicalCoordinate(value.x, dpi),
            .y = logicalCoordinate(value.y, dpi),
        } else null,
        .bounds = inputBounds(logicalCoordinate(client.right, dpi), logicalCoordinate(client.bottom, dpi), controls),
    };
}

fn wheelRegion(x: i32, y: i32, bounds: InputBounds, controls: WorkspaceControls.State) WheelRegion {
    if (controls.rail_visible and x < bounds.rail_left and
        y >= Tokens.header_height and y < bounds.canvas.bottom)
    {
        return .sidebar;
    }
    if (x >= bounds.canvas.left and x < bounds.canvas.right and
        y >= bounds.canvas.top and y < bounds.canvas.bottom)
    {
        return .canvas;
    }
    return .none;
}

/// Whether a WM_GESTURE point should be treated as landing on the graph
/// canvas. The `wheelRegion` rectangle test alone only says a point falls
/// over the canvas-*shaped* area of the window; it says nothing about
/// whether the surface actually showing there right now renders the graph
/// canvas at all -- the terminal workspace surface reuses the exact same
/// window chrome/rectangle. Both conditions are required: a graph-capable
/// surface (anything except the terminal workspace) AND the mapped point
/// actually falling inside the canvas rectangle.
fn gestureInCanvas(surface: GraphCanvas.Surface, mapped: ?c.POINT, bounds: InputBounds, controls: WorkspaceControls.State) bool {
    if (surface == .workspace) return false;
    const point = mapped orelse return false;
    return wheelRegion(point.x, point.y, bounds, controls) == .canvas;
}

/// Formats the gesture-registration failure diagnostic. Pulled out as a pure
/// function (rather than inlined at the one `std.log`/`setStatus` call site)
/// so the exact production message text is directly unit-testable without
/// needing to run `App.run()`'s full startup sequence or capture `std.log`
/// output.
fn formatGestureRegistrationFailure(buf: []u8, last_error: c.DWORD) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "Touch pinch-zoom unavailable (gesture config error {d})",
        .{last_error},
    ) catch "Touch pinch-zoom unavailable";
}

fn isResolvedLoopState(state: []const u8) bool {
    return std.mem.eql(u8, state, "succeeded") or
        std.mem.eql(u8, state, "failed") or
        std.mem.eql(u8, state, "stalled") or
        std.mem.eql(u8, state, "stopped");
}

fn loopBarRect(rect: LoopBarLayout.Rect) c.RECT {
    return .{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.bottom };
}

fn workspaceGraph(model: *const GraphModel.Model) ?*const GraphModel.GraphSummary {
    if (model.currentGraph()) |graph| if (graph.nodes.items.len != 0) return graph;
    if (model.selected_project_path) |path| {
        for (model.graphs.items) |*graph| {
            if (std.mem.eql(u8, graph.project.path, path) and graph.nodes.items.len != 0) return graph;
        }
    }
    for (model.graphs.items) |*graph| if (graph.nodes.items.len != 0) return graph;
    return model.currentGraph();
}

const JumpMatch = struct {
    project_index: usize,
    node_index: usize,
    score: u8,
};

fn findJumpMatch(model: *const GraphModel.Model, query: []const u8) ?JumpMatch {
    var best: ?JumpMatch = null;
    for (model.graphs.items, 0..) |graph, project_index| {
        for (graph.nodes.items, 0..) |node, node_index| {
            const score: u8 = if (std.ascii.eqlIgnoreCase(node.id, query))
                0
            else if (std.ascii.eqlIgnoreCase(node.title, query))
                1
            else if (asciiStartsWithIgnoreCase(node.title, query))
                2
            else if (asciiContainsIgnoreCase(node.title, query) or asciiContainsIgnoreCase(node.id, query))
                3
            else
                continue;
            if (best == null or score < best.?.score)
                best = .{ .project_index = project_index, .node_index = node_index, .score = score };
        }
    }
    return best;
}

fn asciiStartsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn asciiContainsIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > value.len) return false;
    var index: usize = 0;
    while (index + needle.len <= value.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(value[index .. index + needle.len], needle)) return true;
    }
    return false;
}

const UiaDynamicTarget = union(enum) {
    local_section,
    remote_section,
    quick_chats_header,
    quick_chats_disclosure,
    new_quick_chat,
    needs_you_header,
    needs_you: usize,
    needs_you_stop: usize,
    activity_header,
    activity_filter,
    activity_left,
    activity_right,
    activity: usize,
    recent_project: []const u8,
    open_project: []const u8,
    overview_worktree_notice: []const u8,
    project_worktree_chip: []const u8,
    project_new_loop: []const u8,
    project_disclosure: []const u8,
    loop: struct {
        project_path: []const u8,
        node_id: []const u8,
    },
    loop_disclosure: struct {
        project_path: []const u8,
        index: usize,
    },
    active_loop: usize,
    composite_back,
    reclaim_offer: struct {
        path: []const u8,
        action: GraphCanvas.ReclaimAction,
    },
    quick_chat: []const u8,
    workspace_show_graph,
    workspace_stop,
    workspace_new_tab,
    workspace_split_right,
    workspace_split_down,
    workspace_toggle_panel,
    workspace_tab: usize,
    workspace_tab_close: usize,
    workspace_switch: usize,
    header_attention,
    header_worktree,
    header_jump,
    header_toggle_panel,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    window: MainWindow.Window = .{},
    client: DaemonClient,
    daemon: DaemonSupervisor,
    tray: Tray = .{},
    tray_test_hook_enabled: bool = false,
    model: GraphModel.Model,
    canvas: GraphCanvas.CanvasState = .{},
    selected_node_id: []u8 = &.{},
    selected_edge_project_path: []u8 = &.{},
    selected_edge_id: []u8 = &.{},
    edge_drag_source_id: []u8 = &.{},
    selection_initialized: bool = false,
    worktree_inspection: ?WorktreeStatus.Inspection = null,
    worktree_inspection_attempt_count: usize = 0,
    worktree_inspect_runner: WorktreeInspectRunner = runWorktreeInspection,
    worktree_size_runner: WorktreeSizeRunner = runWorktreeSize,
    worktree_inspection_lock: std.Thread.Mutex = .{},
    worktree_inspection_thread: ?std.Thread = null,
    worktree_inspection_done: bool = false,
    worktree_inspection_generation: u64 = 0,
    worktree_inspection_cancellation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    worktree_inspection_pending: ?*WorktreeInspectionRequest = null,
    worktree_inspection_results: std.ArrayList(WorktreeInspectionResult) = .empty,
    worktree_loading_path: []u8 = &.{},
    worktree_state: []u8 = &.{},
    worktree_reclaim_receipts: []u8 = &.{},
    worktree_reclaim_runner: WorktreeReclaimRunner = runWorktreeReclaim,
    worktree_reclaim_generation: u64 = 0,
    worktree_reclaim_cancellation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    worktree_reclaim_lock: std.Thread.Mutex = .{},
    worktree_reclaim_thread: ?std.Thread = null,
    worktree_reclaim_done: bool = false,
    worktree_reclaim_result: ?WorktreeReclaimResult = null,
    selected_worktree_path: []u8 = &.{},
    reclaim_confirmation_armed: bool = false,
    worktree_dialog: ?WorktreeDialog.Dialog = null,
    uia_fixture_project_path: []u8 = &.{},
    uia_fixture_model_arena: ?*std.heap.ArenaAllocator = null,
    accessibility: ?Accessibility.Provider = null,
    sidebar_scroll: i32 = 0,
    sidebar_state: Sidebar.State,
    sidebar_store: ?Sidebar.Store = null,
    sidebar_hover_y: i32 = -1,
    sidebar_drag_project_path: []u8 = &.{},
    sidebar_drag_node_id: []u8 = &.{},
    sidebar_drag_origin_y: i32 = 0,
    sidebar_drag_active: bool = false,
    sidebar_drag_started: bool = false,
    canvas_press_project_path: []u8 = &.{},
    canvas_press_node_id: []u8 = &.{},
    workspace: ?*TerminalWorkspace.Workspace = null,
    navigation_cursor: Navigation.Cursor = .{},
    workspace_controls: WorkspaceControls.State = .{ .panel_visible = false },
    dpi: u32 = Dpi.base_dpi,
    surface: GraphCanvas.Surface = .project,
    workspace_is_quick_chat: bool = false,
    header_focus: ?GraphCanvas.HeaderAction = null,
    header_return_focus: c.HWND = null,
    header_focus_transition: bool = false,
    canvas_layout_store: ?CanvasLayoutStore.Store = null,
    quick_chats_requested: bool = false,
    selected_quick_chat: ?usize = null,
    workspace_reservation: WorkspaceReservation = .{},
    workspace_summary_work: WorkspaceManager.SummaryWork = .{},
    workspace_list: ?WorkspaceLifecycle.List = null,
    workspace_path: []u8 = &.{},
    workspace_identity: []u8 = &.{},
    workspace_identity_valid: bool = false,
    workspace_identity_blocked: bool = false,
    sync_requested: bool = false,
    restore_requested: bool = false,
    open_project_pending: bool = false,
    pending_rebind_path: []u8 = &.{},
    pending_previous_subscription: []u8 = &.{},
    open_generation: u64 = 0,
    pending_open_generation: u64 = 0,
    pending_open_request_id: ?[36]u8 = null,
    pending_open_sent: bool = false,
    pending_sent_path: []u8 = &.{},
    pending_folder_open_path: []u8 = &.{},
    last_connection_state: Wire.ConnectionState = .disconnected,
    last_project_opened: []const u8 = "",
    accepted_subscription: []const u8 = "",
    pending_project_path: []u8 = &.{},
    status_override: []u8 = &.{},
    workspace_recovery: WorkspaceRecoveryState = .{},
    ingress_error: []u8 = &.{},
    declared_entry_ids: std.array_list.Managed([]u8),
    kept_worktree_paths: std.array_list.Managed([]u8),
    running: bool = true,
    exit_requested: bool = false,
    smoke: bool = false,
    stress: bool = false,
    require_smoke_contract: bool = false,
    smoke_failure: bool = false,
    smoke_tick: usize = 0,
    smoke_action_requested: bool = false,
    smoke_input_requested: bool = false,
    smoke_idle_ticks: usize = 0,
    smoke_workspace_actions: []const u8 = "",
    smoke_workspace_action_index: usize = 0,
    smoke_workspace_actions_ran: bool = false,
    smoke_workspace_action_failed: bool = false,
    smoke_workspace_create_observed: bool = false,
    smoke_workspace_split_observed: bool = false,
    smoke_workspace_select_observed: bool = false,
    smoke_workspace_focus_observed: bool = false,
    smoke_workspace_close_observed: bool = false,
    smoke_workspace_restart_observed: bool = false,
    empty_open_folder_button: c.HWND = null,
    empty_global_overview_button: c.HWND = null,
    product_settings_store: ?ProductSettings.Store = null,
    product_settings: ?ProductSettings.Settings = null,
    onboarding_store: ?Onboarding.Store = null,
    clone_operation: ?*RepositoryDialogs.CloneOperation = null,
    activity_enabled: bool = false,
    update_state: WindowsUpdates.CheckState = .{},
    update_lock: std.Thread.Mutex = .{},
    update_thread: ?std.Thread = null,
    update_done: bool = false,
    update_cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    update_generation: u64 = 0,
    update_pending: bool = false,
    update_offer_pending: bool = false,
    update_user_initiated: bool = false,
    update_version: []u8 = &.{},
    update_release_url: []u8 = &.{},
    update_asset_url: []u8 = &.{},
    update_asset_sha256: []u8 = &.{},
    update_asset_checksum_url: []u8 = &.{},
    smoke_restart_index: ?usize = null,
    smoke_restart_session: []const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) !*App {
        var client = try DaemonClient.init(allocator);
        const app = allocator.create(App) catch |err| {
            client.deinit();
            return err;
        };
        const accessibility = Accessibility.defaultContract(allocator) catch |err| {
            client.deinit();
            allocator.destroy(app);
            return err;
        };
        app.* = .{
            .allocator = allocator,
            .client = client,
            .daemon = .{ .allocator = allocator },
            .model = GraphModel.Model.init(allocator),
            .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
            .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
            .tray_test_hook_enabled = envFlag(tray_test_hook_environment),
            .accessibility = accessibility,
            .sidebar_state = Sidebar.State.init(allocator),
        };
        errdefer app.deinit();
        try app.client.start();
        try app.acquireSingleInstance();
        return app;
    }

    /// The daemon answers an open with its canonical spelling of the project path
    /// (for example `C:/a` for a picker's `C:\a`). When the reply is provably for the
    /// shell's own in-flight open, adopt that spelling so the reply is not discarded.
    fn adoptCanonicalOpenPath(self: *App, frame: []const u8, canonical: []const u8) void {
        if (!self.pending_open_sent or self.pending_sent_path.len == 0) return;
        if (std.mem.eql(u8, canonical, self.pending_sent_path)) return;
        const owned = switch (self.client.protocolMode()) {
            .v2 => blk: {
                const request_id = self.pending_open_request_id orelse break :blk false;
                const response_id = Wire.responseRequestID(frame) orelse break :blk false;
                break :blk std.ascii.eqlIgnoreCase(response_id, &request_id);
            },
            .v1 => Wire.sameLocalProjectPath(canonical, self.pending_sent_path),
        };
        if (!owned) return;
        const rebind_is_sent = std.mem.eql(u8, self.pending_rebind_path, self.pending_sent_path);
        const sent = self.allocator.dupe(u8, canonical) catch return;
        const rebind: ?[]u8 = if (rebind_is_sent)
            (self.allocator.dupe(u8, canonical) catch {
                self.allocator.free(sent);
                return;
            })
        else
            null;
        self.allocator.free(self.pending_sent_path);
        self.pending_sent_path = sent;
        if (rebind) |value| {
            self.allocator.free(self.pending_rebind_path);
            self.pending_rebind_path = value;
        }
    }

    fn sendPendingOpen(self: *App) void {
        if (self.pending_rebind_path.len == 0 or
            self.client.connectionState() != .connected or
            (self.client.protocolMode() == .v1 and self.pending_open_sent))
            return;
        if (self.client.protocolMode() == .v1) {
            self.client.setSubscription(self.pending_rebind_path);
        }
        if (self.pending_sent_path.len != 0) self.allocator.free(self.pending_sent_path);
        self.pending_sent_path = self.allocator.dupe(u8, self.pending_rebind_path) catch {
            self.setStatus("Unable to retain sent project");
            return;
        };
        const token = self.client.sendOpenProject(self.pending_sent_path);
        if (token == null) {
            self.allocator.free(self.pending_sent_path);
            self.pending_sent_path = &.{};
            self.open_project_pending = true;
            return;
        }
        self.pending_open_request_id = token;
        self.pending_open_sent = true;
        self.open_project_pending = false;
    }

    pub fn deinit(self: *App) void {
        self.workspace_summary_work.drain();
        self.drainWorktreeInspection();
        self.drainWorktreeReclaim();
        if (self.workspace) |workspace| {
            workspace.deinit();
            self.allocator.destroy(workspace);
        }
        self.client.deinit();
        self.daemon.stop();
        self.tray.remove();
        self.model.deinit();
        if (self.accessibility) |*provider| provider.deinit();
        self.releaseUiaFixtureModelArena();
        if (self.worktree_dialog) |*dialog| dialog.deinit();
        if (self.worktree_inspection) |*inspection| {
            WorktreeStatus.deinitInspection(self.allocator, inspection);
        }
        if (self.uia_fixture_project_path.len != 0) self.allocator.free(self.uia_fixture_project_path);
        if (self.selected_worktree_path.len != 0) self.allocator.free(self.selected_worktree_path);
        if (self.worktree_state.len != 0) self.allocator.free(self.worktree_state);
        if (self.worktree_reclaim_receipts.len != 0) self.allocator.free(self.worktree_reclaim_receipts);
        if (self.selected_node_id.len != 0) self.allocator.free(self.selected_node_id);
        if (self.selected_edge_project_path.len != 0) self.allocator.free(self.selected_edge_project_path);
        if (self.selected_edge_id.len != 0) self.allocator.free(self.selected_edge_id);
        if (self.edge_drag_source_id.len != 0) self.allocator.free(self.edge_drag_source_id);
        if (self.canvas_press_project_path.len != 0) self.allocator.free(self.canvas_press_project_path);
        if (self.canvas_press_node_id.len != 0) self.allocator.free(self.canvas_press_node_id);
        self.workspace_reservation.deinit();
        if (self.workspace_list) |*list| list.deinit(self.allocator);
        if (self.workspace_path.len != 0) self.allocator.free(self.workspace_path);
        if (self.workspace_identity.len != 0) self.allocator.free(self.workspace_identity);
        if (self.last_project_opened.len != 0) self.allocator.free(self.last_project_opened);
        if (self.accepted_subscription.len != 0) self.allocator.free(self.accepted_subscription);
        if (self.pending_project_path.len != 0) self.allocator.free(self.pending_project_path);
        if (self.pending_rebind_path.len != 0) self.allocator.free(self.pending_rebind_path);
        if (self.pending_sent_path.len != 0) self.allocator.free(self.pending_sent_path);
        if (self.pending_folder_open_path.len != 0) self.allocator.free(self.pending_folder_open_path);
        if (self.pending_previous_subscription.len != 0) self.allocator.free(self.pending_previous_subscription);
        if (self.status_override.len != 0) self.allocator.free(self.status_override);
        self.workspace_recovery.deinit(self.allocator);
        if (self.ingress_error.len != 0) self.allocator.free(self.ingress_error);
        if (self.sidebar_drag_project_path.len != 0) self.allocator.free(self.sidebar_drag_project_path);
        if (self.sidebar_drag_node_id.len != 0) self.allocator.free(self.sidebar_drag_node_id);
        for (self.declared_entry_ids.items) |id| self.allocator.free(id);
        self.declared_entry_ids.deinit();
        for (self.kept_worktree_paths.items) |path| self.allocator.free(path);
        self.kept_worktree_paths.deinit();
        if (self.smoke_workspace_actions.len != 0) self.allocator.free(self.smoke_workspace_actions);
        if (self.smoke_restart_session.len != 0) self.allocator.free(self.smoke_restart_session);
        if (self.product_settings_store) |*store| store.deinit();
        if (self.canvas_layout_store) |*store| store.deinit();
        if (self.sidebar_store) |*store| store.deinit();
        self.sidebar_state.deinit();
        if (self.product_settings) |*settings| settings.deinit();
        if (self.onboarding_store) |*store| store.deinit();
        if (self.clone_operation) |operation| operation.deinit();
        self.update_cancel.store(true, .release);
        if (self.update_thread) |thread| thread.join();
        if (self.update_version.len != 0) self.allocator.free(self.update_version);
        if (self.update_release_url.len != 0) self.allocator.free(self.update_release_url);
        if (self.update_asset_url.len != 0) self.allocator.free(self.update_asset_url);
        if (self.update_asset_sha256.len != 0) self.allocator.free(self.update_asset_sha256);
        if (self.update_asset_checksum_url.len != 0) self.allocator.free(self.update_asset_checksum_url);
        self.allocator.destroy(self);
    }

    pub fn run(self: *App) !void {
        Diagnostics.record(self.allocator, "startup", "GraphCode Windows shell starting");
        const com_result = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);
        if (com_result < 0) return error.ComInitializationFailed;
        defer c.CoUninitialize();
        const daemon_supervisor_test_hook = envFlag(daemon_supervisor_test_hook_environment);
        const uia_gate_hook = envFlag("GRAPHCODE_UIA_GATE");
        var daemon_connection_scheduled = false;
        // GDI+ may create a process-owned helper window. The daemon handoff
        // and UIA live tests depend on deterministic top-level window and
        // foreground behavior, so keep that visual-only subsystem disabled
        // for both explicit automation hooks.
        const use_gdiplus = !daemon_supervisor_test_hook and !uia_gate_hook;
        if (use_gdiplus) GdiplusAA.init();
        defer if (use_gdiplus) GdiplusAA.deinit();
        try self.window.create(self, &onWindowMessage, title.ptr);
        self.window.key_callback = &onShellKey;
        try self.revalidateWorkspaceIdentity();
        if (!self.window.gesture_config_registered) {
            // Non-fatal: the canvas simply falls back to wheel-only zoom (no
            // pinch input) rather than the app failing to start. The
            // transient status/announcement line below is best-effort --
            // several later calls in this same startup sequence (daemon
            // status, accessibility attach, product-settings/canvas-layout/
            // sidebar-store load failures) call setStatus themselves and can
            // overwrite this message before the window is ever shown. Two
            // things make this observable regardless: `std.log.warn` below
            // writes the same message (with the captured Win32 error code)
            // to stderr, so support/CI logs retain it even if the on-screen
            // status line gets clobbered; and `window.gesture_config_registered`
            // / `window.gesture_config_last_error` are the durable, never-
            // overwritten record of the outcome for any caller (tests,
            // future diagnostics UI, support tooling) that reads the window
            // directly instead of the transient status text.
            var buf: [96]u8 = undefined;
            const message = formatGestureRegistrationFailure(&buf, self.window.gesture_config_last_error);
            std.log.warn("{s}", .{message});
            self.setStatus(message);
        }
        // Seed the real startup DPI now that a window handle exists, rather than
        // waiting on the first WM_DPICHANGED. Without this a per-monitor-aware
        // process that launches directly on a scaled (>100%) monitor would still
        // render its first frame -- including any terminal surfaces created below
        // -- assuming 96 DPI/100% until the user actually moves it.
        self.dpi = Win32.dpiForWindow(self.window.hwnd);
        self.tray.test_hook_enabled = self.tray_test_hook_enabled;
        self.tray.add(self.window.hwnd) catch self.setStatus("System tray unavailable; GraphCode remains open");
        // The startup probe does not require the daemon-created rendezvous
        // secret; connection retries replace it with the real endpoint.
        const endpoint = self.client.currentDaemonStartupEndpoint(self.allocator) catch &.{};
        const lock_name = self.client.currentDaemonLockName(self.allocator) catch &.{};
        defer if (endpoint.len != 0) self.allocator.free(endpoint);
        defer if (lock_name.len != 0) self.allocator.free(lock_name);
        if (endpoint.len != 0 and lock_name.len != 0) self.daemon.start(endpoint, lock_name);
        if (daemon_supervisor_test_hook) {
            const state: usize = if (self.daemon.owned) 1 else if (self.daemon.status().len == 0) 2 else 3;
            _ = c.SetPropW(
                self.window.hwnd,
                daemon_supervisor_test_property.ptr,
                Win32.opaquePointerFromInt(c.HANDLE, state),
            );
        }
        if (self.daemon.status().len != 0) self.setStatus(self.daemon.status());
        if (self.accessibility) |*provider| {
            if (!provider.attach(self.window.hwnd)) self.setStatus("Accessibility provider unavailable");
        }
        self.product_settings_store = ProductSettings.Store.init(self.allocator) catch null;
        if (self.product_settings_store) |*store| {
            self.product_settings = store.load() catch |err| blk: {
                self.setStatus(if (err == error.FileNotFound) "Product settings unavailable" else "Product settings could not be loaded");
                break :blk null;
            };
        }
        if (self.product_settings) |settings| {
            self.activity_enabled = settings.activity;
            self.workspace_controls.activity_enabled = settings.activity;
            self.update_state = WindowsUpdates.CheckState.configure(settings.beta);
        }
        self.canvas_layout_store = CanvasLayoutStore.Store.init(self.allocator) catch null;
        if (self.canvas_layout_store) |*store| {
            store.load(&self.canvas) catch self.setStatus("Saved canvas positions could not be loaded");
        }
        self.sidebar_store = Sidebar.Store.init(self.allocator) catch null;
        if (self.sidebar_store) |*store| {
            store.load(&self.sidebar_state) catch self.setStatus("Saved sidebar expansion could not be loaded");
        }
        self.onboarding_store = Onboarding.Store.init(self.allocator) catch null;
        if (self.onboarding_store) |store| {
            const shell_test = std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_SHELL_REQUIRE_DAEMON") catch null;
            defer if (shell_test) |value| self.allocator.free(value);
            if (!uia_gate_hook and
                !daemon_supervisor_test_hook and
                (shell_test == null or !std.mem.eql(u8, shell_test.?, "1")))
            {
                const initial_backend = if (self.product_settings) |settings| settings.default_backend else "claudeCode";
                var first_run = FirstRunStartup.Context{
                    .app = self,
                    .store = store,
                    .initial_backend = initial_backend,
                };
                daemon_connection_scheduled = runFirstRunStartup(
                    &first_run,
                    store.shouldShow(),
                    FirstRunStartup.scheduleConnection,
                    FirstRunStartup.showModal,
                );
            }
        }
        self.createEmptyStateControls();
        _ = self.refreshWorkspaceList();
        self.updateNativeChrome(.state_change);
        if (std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_UIA_FIXTURE_ROWS")) |fixture| {
            defer self.allocator.free(fixture);
            if (!self.installUiaFixture(true)) return error.InvalidUiaFixtureData;
            if (envFlag("GRAPHCODE_UIA_SHOW_SWEEP")) self.presentWorktreeSweep();
        } else |_| {}
        const uia_gate = std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_UIA_GATE") catch null;
        defer if (uia_gate) |value| self.allocator.free(value);
        const uia_gate_zmx = std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_ZMX") catch null;
        defer if (uia_gate_zmx) |value| self.allocator.free(value);
        // Outside the UIA gate, always build the real workspace. Inside the gate, only do so
        // when a real zmx executable was supplied (GRAPHCODE_ZMX) so the gate can validate live
        // workspace chrome (toolbar/tabs/split controls); otherwise keep the historical no-op
        // to avoid spinning up a workspace with no attach target during other gate scenarios.
        if (uia_gate == null or !std.mem.eql(u8, uia_gate.?, "1") or
            (uia_gate_zmx != null and uia_gate_zmx.?.len > 0))
        {
            self.workspace = TerminalWorkspace.Workspace.init(self.window.hwnd, self.allocator) catch |err| {
                std.log.err("Terminal workspace initialization failed: {s}", .{@errorName(err)});
                return err;
            };
            // Seed the workspace with the real startup DPI captured above so the
            // very first surfaceOptions() (used for the first pane in this
            // workspace) already requests the correct font_scale instead of always
            // starting at 96 DPI/100%.
            if (self.workspace) |workspace| workspace.dpi = Dpi.normalize(self.dpi);
            if (self.workspace) |workspace| workspace.setKeyCallback(self, &onWorkspaceKey);
            if (self.workspace) |workspace| try workspace.startInputWorker();
        }
        self.layoutWorkspace();
        if (envFlag("GRAPHCODE_UIA_SHOW_UPDATE")) self.showCurrentUpdateOffer();
        if (!envFlag("GRAPHCODE_UIA_UPDATE_AVAILABLE")) self.requestUpdateCheck(false);
        if (std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_SHELL_REQUIRE_DAEMON")) |value| {
            defer self.allocator.free(value);
            self.require_smoke_contract = std.mem.eql(u8, value, "1");
        } else |_| {}
        if (std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_SHELL_WORKSPACE_ACTIONS")) |value| {
            self.smoke_workspace_actions = value;
        } else |_| {}
        if (!daemon_connection_scheduled) {
            self.client.setCallback(&onDaemonFrame, self);
            self.client.connect();
        }
        try self.window.messageLoop();
        if (self.exit_requested) std.process.exit(0);
        if (self.smoke_failure) {
            if (std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_SHELL_EXPECT_TRANSPORT_ERROR")) |value| {
                defer self.allocator.free(value);
                if (std.mem.eql(u8, value, "1")) {
                    std.debug.print("Smoke daemon status: {s}\n", .{self.client.statusText()});
                }
            } else |_| {}
            return error.SmokeContractFailed;
        }
    }

    pub fn configureArgs(self: *App, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--smoke")) self.smoke = true;
            if (std.mem.eql(u8, arg, "--stress")) self.stress = true;
        }
    }

    fn onFrame(self: *App, frame: []const u8) void {
        self.onFrameWithAccessibilityPublish(frame, publishAccessibility);
    }

    fn publishAccessibility(app: *App) void {
        app.syncAccessibility();
    }

    fn onFrameWithAccessibilityPublish(self: *App, frame: []const u8, publish: anytype) void {
        self.onFrameWithEffects(frame, rebindWorkspace, refreshWorkspace, publish);
    }

    fn onFrameWithEffects(
        self: *App,
        frame: []const u8,
        comptime rebind: fn (*App, []const u8) void,
        comptime refresh: fn (*App) void,
        publish: anytype,
    ) void {
        var incoming_project_path: ?[]u8 = null;
        defer if (incoming_project_path) |path| self.allocator.free(path);
        if (self.pending_rebind_path.len != 0 and Wire.eventKind(frame) == .graph_changed) {
            const path = Wire.copyGraphChangedProjectPath(self.allocator, frame) catch null;
            if (path) |value| {
                incoming_project_path = value;
                self.adoptCanonicalOpenPath(frame, value);
                if (self.client.protocolMode() == .v1 and self.pending_open_sent) {
                    if (!std.mem.eql(u8, value, self.pending_sent_path) and
                        !std.mem.eql(u8, value, self.accepted_subscription)) return;
                } else if (!Wire.isCurrentGraphPath(
                    self.pending_rebind_path,
                    self.accepted_subscription,
                    value,
                )) return;
            }
        }
        const had_current_graph = self.model.currentGraph() != null;
        const event = self.model.updateFromFrame(frame) catch {
            self.setStatus("Malformed GraphcodeKit event");
            return;
        };
        switch (event) {
            .recent_projects => {
                self.clampSidebarScroll();
                if (self.model.graph == null and self.model.recent_projects.items.len != 0) {
                    self.queueProject(self.model.recent_projects.items[0].path);
                }
            },
            .graph_changed => {
                if (incoming_project_path) |path| {
                    if (self.pending_rebind_path.len != 0 and
                        (std.mem.eql(u8, path, self.pending_rebind_path) or
                            (self.client.protocolMode() == .v1 and
                                std.mem.eql(u8, path, self.pending_sent_path))))
                    {
                        if (self.selectProject(path) and
                            (self.selected_edge_project_path.len == 0 or
                                !std.mem.eql(u8, self.selected_edge_project_path, path)))
                        {
                            self.clearEdgeSelection();
                        }
                    }
                }
                if (self.model.graph) |graph| {
                    if (self.canvas.selected_edge) |edge| {
                        if (edge >= graph.edges.items.len) self.canvas.selected_edge = null;
                    }
                    const accepted = incoming_project_path != null and
                        self.pending_rebind_path.len != 0 and
                        std.mem.eql(u8, incoming_project_path.?, graph.project.path);
                    if (accepted) {
                        self.clearIngressError();
                        self.client.setSubscription(graph.project.path);
                        if (self.last_project_opened.len != 0) self.allocator.free(self.last_project_opened);
                        self.last_project_opened = self.allocator.dupe(u8, graph.project.path) catch {
                            self.setStatus("Unable to retain accepted project");
                            return;
                        };
                        if (self.accepted_subscription.len != 0) self.allocator.free(self.accepted_subscription);
                        self.accepted_subscription = self.allocator.dupe(u8, graph.project.path) catch {
                            self.setStatus("Unable to retain accepted subscription");
                            return;
                        };
                        const queued_v1 = self.client.protocolMode() == .v1 and
                            !std.mem.eql(u8, self.pending_rebind_path, graph.project.path);
                        if (self.pending_sent_path.len != 0) {
                            self.allocator.free(self.pending_sent_path);
                            self.pending_sent_path = &.{};
                        }
                        self.pending_open_sent = false;
                        self.pending_open_request_id = null;
                        if (!queued_v1) {
                            self.allocator.free(self.pending_rebind_path);
                            self.pending_rebind_path = &.{};
                            self.pending_open_generation = 0;
                            if (self.pending_previous_subscription.len != 0) {
                                self.allocator.free(self.pending_previous_subscription);
                                self.pending_previous_subscription = &.{};
                            }
                        }
                        self.open_project_pending = queued_v1;
                        if (queued_v1) {
                            if (self.pending_previous_subscription.len != 0) self.allocator.free(self.pending_previous_subscription);
                            self.pending_previous_subscription = self.allocator.dupe(u8, graph.project.path) catch &.{};
                        }
                        rebind(self, graph.project.path);
                        if (queued_v1) self.sendPendingOpen();
                    } else if (self.pending_rebind_path.len == 0) {
                        rebind(self, graph.project.path);
                    }
                    if (self.canvas.selected_edge) |edge| {
                        if (edge >= graph.edges.items.len) self.canvas.selected_edge = null;
                    }
                    self.remapSelection();
                    rebind(self, graph.project.path);
                    self.clampSidebarScroll();
                    if (self.worktree_inspection) |inspection| {
                        if (self.model.graph) |current_graph| {
                            if (!std.mem.eql(u8, inspection.project_path, current_graph.project.path)) {
                                WorktreeStatus.deinitInspection(self.allocator, &self.worktree_inspection.?);
                                self.worktree_inspection = null;
                                if (self.worktree_dialog) |*dialog| {
                                    dialog.deinit();
                                    self.worktree_dialog = null;
                                }
                                if (self.selected_worktree_path.len != 0) {
                                    self.allocator.free(self.selected_worktree_path);
                                    self.selected_worktree_path = &.{};
                                }
                                self.reclaim_confirmation_armed = false;
                            }
                        }
                    }
                    if (!had_current_graph and self.pending_rebind_path.len == 0) {
                        if (self.model.graph) |current_graph| self.queueProject(current_graph.project.path);
                    }
                    self.clampSidebarScroll();
                    refresh(self);
                    if (self.model.currentGraph()) |selected| {
                        if (!selected.project.isGlobal() and
                            selected.worktree_notice == null and
                            (self.worktree_loading_path.len == 0 or
                                !std.mem.eql(u8, self.worktree_loading_path, selected.project.path)) and
                            (selected.project.isRemote() or self.isLocalGitRepository(selected.project.path)))
                        {
                            self.inspectWorktreesImpl(false);
                        }
                    }
                }
            },
            .quick_chats, .quick_chat_changed, .quick_chat_deleted, .quick_chat_activity => {
                if (event == .quick_chat_changed) {
                    if (Wire.jsonString(frame, "id")) |id| self.openQuickChat(id);
                }
                _ = c.InvalidateRect(self.window.hwnd, null, 0);
            },
            .error_occurred => {
                const ingress_failure = self.pending_rebind_path.len != 0;
                if (self.pending_rebind_path.len != 0) {
                    if (self.client.protocolMode() == .v2) {
                        const request_id = self.pending_open_request_id orelse return;
                        const response_id = Wire.responseRequestID(frame) orelse return;
                        // The daemon echoes the UUID in uppercase.
                        if (!std.ascii.eqlIgnoreCase(response_id, &request_id)) return;
                    } else if (!self.pending_open_sent) {
                        return;
                    }
                    const queued_v1 = self.client.protocolMode() == .v1 and
                        !std.mem.eql(u8, self.pending_rebind_path, self.pending_sent_path);
                    self.client.setSubscription(self.pending_previous_subscription);
                    if (self.last_project_opened.len != 0) self.allocator.free(self.last_project_opened);
                    self.last_project_opened = self.allocator.dupe(u8, self.pending_previous_subscription) catch &.{};
                    if (self.accepted_subscription.len != 0) self.allocator.free(self.accepted_subscription);
                    self.accepted_subscription = self.allocator.dupe(u8, self.pending_previous_subscription) catch &.{};
                    if (self.pending_sent_path.len != 0) {
                        self.allocator.free(self.pending_sent_path);
                        self.pending_sent_path = &.{};
                    }
                    self.pending_open_sent = false;
                    self.pending_open_request_id = null;
                    if (!queued_v1) {
                        self.allocator.free(self.pending_rebind_path);
                        self.pending_rebind_path = &.{};
                        self.pending_open_generation = 0;
                        if (self.pending_previous_subscription.len != 0) {
                            self.allocator.free(self.pending_previous_subscription);
                            self.pending_previous_subscription = &.{};
                        }
                    }
                    self.open_project_pending = queued_v1;
                    if (queued_v1) self.sendPendingOpen();
                }
                if (Wire.copyErrorMessage(self.allocator, frame) catch null) |message| {
                    if (ingress_failure) self.setIngressError(message);
                    self.replaceStatus(message);
                } else {
                    if (ingress_failure) self.setIngressError("Daemon could not open the selected project");
                    self.setStatus("Daemon error");
                }
            },
            else => {},
        }
        if (event == .graph_changed) publish(self);
    }

    /// Runs after every graph change. It re-observes only the open loop's own pane, in the
    /// loop slot, and only once that loop is running: attaching here must never create a
    /// session, or a loop's agent loses the race to a bare shell (LoopLaunchWait). It must
    /// not bind other graph loops to slots by graph order either: after a reopen, that put
    /// another loop's session into a stray, selected tab over the reopened loop's pane.
    fn refreshWorkspace(self: *App) void {
        const workspace = if (self.workspace) |value| value else return;
        if (self.smoke) return self.refreshSmokeTerminals(workspace);
        if (self.workspace_is_quick_chat) return;
        const project = self.currentProject() orelse return;
        if (!std.mem.eql(u8, workspace.projectPath(), project)) return;
        if (workspace.hasSurface(0) or workspace.hasAttach(0) or workspace.isAwaitingLaunch(0)) return;
        if (!workspace.loopPaneDetached(self.selected_node_id)) return;
        workspace.openLaunchedNode(0, self.selected_node_id, 0) catch
            self.setStatus("Unable to attach selected loop");
    }

    /// The smoke gate's two-terminal contract: terminals A and B show the graph's first two
    /// loops once they run. Product windows never use it (see `refreshWorkspace`).
    fn refreshSmokeTerminals(self: *App, workspace: *TerminalWorkspace.Workspace) void {
        const graph = if (self.model.graph) |value| value else return;
        for (0..@min(graph.nodes.items.len, 2)) |pane| {
            if (workspace.hasSurface(pane) or workspace.isAwaitingLaunch(pane)) continue;
            workspace.openLaunchedNode(pane, graph.nodes.items[pane].id, 0) catch {
                self.setStatus(if (pane == 0) "Unable to attach terminal A" else "Unable to attach terminal B");
            };
        }
    }

    /// Asks the daemon to start an attended loop's agent — a no-op for a loop already
    /// running — and opens its pane once that session exists, never as a bare shell.
    fn openGraphLoop(self: *App, project_path: []const u8, node_id: []const u8) void {
        self.client.sendNodeAction(project_path, node_id, "resumeSession", null);
        const workspace = self.workspace orelse return;
        workspace.openLaunchedNode(0, node_id, TerminalWorkspace.Workspace.loop_open_timeout_ms) catch {
            self.setStatus("Unable to open selected loop");
            return;
        };
        if (workspace.isAwaitingLaunch(0)) self.setStatus("Starting loop");
    }

    fn reportLaunchOutcome(self: *App, workspace: *TerminalWorkspace.Workspace) void {
        const outcome = workspace.takeLaunchOutcome() orelse return;
        self.setStatus(switch (outcome) {
            .started => "Loop opened",
            .not_started => "Loop session did not start; check the loop's agent and try again",
            .attach_failed => "Unable to open selected loop",
        });
    }

    fn rebindWorkspace(self: *App, path: []const u8) void {
        if (self.workspace) |workspace| {
            _ = workspace.rebindProject(path) catch {
                self.setStatus("Unable to rebind workspace project");
                return;
            };
        }
    }

    pub fn openProject(self: *App, path: []const u8) void {
        self.openProjectWithLayout(path, layoutWorkspace);
    }

    fn openProjectWithLayout(self: *App, path: []const u8, comptime layout: fn (*App) void) void {
        if (path.len == 0) return;
        self.surface = .project;
        self.workspace_controls.panel_visible = false;
        layout(self);
        const previous = if (self.pending_rebind_path.len != 0)
            self.allocator.dupe(u8, self.pending_previous_subscription) catch {
                self.setStatus("Unable to retain previous project subscription");
                return;
            }
        else if (self.accepted_subscription.len != 0)
            self.allocator.dupe(u8, self.accepted_subscription) catch {
                self.setStatus("Unable to retain previous project subscription");
                return;
            }
        else
            self.client.subscriptionPath(self.allocator) catch {
                self.setStatus("Unable to retain previous project subscription");
                return;
            };
        const pending = self.allocator.dupe(u8, path) catch {
            self.allocator.free(previous);
            self.setStatus("Unable to retain pending project");
            return;
        };
        const opened = self.allocator.dupe(u8, path) catch {
            self.allocator.free(previous);
            self.allocator.free(pending);
            self.setStatus("Unable to retain project subscription");
            return;
        };
        if (self.pending_previous_subscription.len != 0) self.allocator.free(self.pending_previous_subscription);
        const v1_busy = self.client.protocolMode() == .v1 and self.pending_open_sent;
        self.pending_previous_subscription = previous;
        self.open_generation +%= 1;
        self.pending_open_generation = self.open_generation;
        self.pending_open_request_id = null;
        if (!v1_busy) self.client.setSubscription(path);
        if (self.last_project_opened.len != 0) self.allocator.free(self.last_project_opened);
        self.last_project_opened = opened;
        if (self.pending_rebind_path.len != 0) self.allocator.free(self.pending_rebind_path);
        self.pending_rebind_path = pending;
        self.open_project_pending = true;
        if (!v1_busy) self.sendPendingOpen();
    }

    pub fn openFolder(self: *App) void {
        self.clearIngressError();
        var path: [32768]u16 = [_]u16{0} ** 32768;
        const picked = graphcode_pick_folder(self.window.hwnd, &path, path.len);
        if (picked < 0) {
            self.setIngressError("Unable to open the folder picker");
            self.setStatus("Unable to open the folder picker");
            return;
        }
        if (picked == 0) return;
        var length: usize = 0;
        while (length < path.len and path[length] != 0) : (length += 1) {}
        const utf8 = std.unicode.utf16LeToUtf8Alloc(self.allocator, path[0..length]) catch {
            self.setIngressError("Unable to read the selected folder");
            self.setStatus("Unable to read the selected folder");
            return;
        };
        self.scheduleFolderOpenWith(utf8, FolderOpenApi) catch {
            self.setIngressError("Unable to finish opening the selected folder");
            self.setStatus("Unable to finish opening the selected folder");
        };
    }

    fn scheduleFolderOpenWith(self: *App, owned_path: []u8, comptime Api: type) !void {
        if (self.pending_folder_open_path.len != 0) {
            self.allocator.free(owned_path);
            return error.FolderOpenAlreadyPending;
        }
        self.pending_folder_open_path = owned_path;
        if (!Api.armTimer(
            self.window.hwnd,
            folder_open_timer_id,
            folder_open_timer_interval_ms,
        )) {
            self.pending_folder_open_path = &.{};
            self.allocator.free(owned_path);
            return error.FolderOpenDispatchFailed;
        }
    }

    fn dispatchPendingFolderOpenWith(self: *App, comptime Api: type) void {
        if (self.pending_folder_open_path.len == 0) return;
        const path = self.pending_folder_open_path;
        self.pending_folder_open_path = &.{};
        defer self.allocator.free(path);
        Api.openProject(self, path);
    }

    pub fn openGlobalOverview(self: *App) void {
        self.surface = .overview;
        self.workspace_controls.panel_visible = false;
        self.layoutWorkspace();
        self.layoutEmptyStateControls();
        self.syncAccessibility();
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
    }

    fn applyOverviewLaneAction(self: *App, x: i32, y: i32, bounds: c.RECT) bool {
        for (self.model.graphs.items, 0..) |_, graph_index| {
            if (GraphCanvas.overviewLaneActionAt(&self.model, graph_index, x, y, bounds, &self.canvas)) |action| {
                if (action == .inspect_worktrees) {
                    if (self.selectProject(self.model.graphs.items[graph_index].project.path)) self.inspectWorktrees();
                } else if (self.selectProject(self.model.graphs.items[graph_index].project.path)) {
                    self.surface = .project;
                    self.workspace_controls.panel_visible = false;
                    self.layoutWorkspace();
                    self.layoutEmptyStateControls();
                    self.rebindWorkspace(self.model.graphs.items[graph_index].project.path);
                }
                return true;
            }
        }
        return false;
    }

    fn queueProject(self: *App, path: []const u8) void {
        if (path.len == 0 or
            std.mem.eql(u8, self.last_project_opened, path) or
            std.mem.eql(u8, self.pending_project_path, path))
        {
            return;
        }
        const copy = self.allocator.dupe(u8, path) catch {
            self.setStatus("Unable to retain pending project subscription");
            return;
        };
        if (self.pending_project_path.len != 0) self.allocator.free(self.pending_project_path);
        self.pending_project_path = copy;
    }

    fn flushPendingProject(self: *App) void {
        self.flushPendingProjectWithLayout(layoutWorkspace);
    }

    fn flushPendingProjectWithLayout(self: *App, comptime layout: fn (*App) void) void {
        if (self.pending_project_path.len == 0 or self.client.connectionState() != .connected) return;
        const path = self.pending_project_path;
        self.pending_project_path = &.{};
        self.openProjectWithLayout(path, layout);
        self.allocator.free(path);
    }

    fn currentProject(self: *const App) ?[]const u8 {
        if (self.model.currentGraph()) |graph| return graph.project.path;
        if (self.model.recent_projects.items.len != 0) return self.model.recent_projects.items[0].path;
        if (self.worktree_inspection) |inspection| return inspection.project_path;
        return null;
    }

    /// A stable identity for "what an in-progress pinch gesture is currently
    /// applied to", used to detect a same-region destination change (surface
    /// switch, or project switch while the surface stays graph-capable) that
    /// the OS never brackets with GID_END. Deliberately hashes the surface
    /// tag and `currentProject()`'s path *content* (matching the existing
    /// `GraphCanvas.nodeKey` Wyhash-of-content precedent) rather than storing
    /// the path slice itself, since `currentProject()` returns data borrowed
    /// from model storage that can be freed or reallocated out from under a
    /// held pointer while a multi-message gesture is still in flight.
    fn pinchGestureContext(self: *const App) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const surface_tag = @intFromEnum(self.surface);
        hasher.update(std.mem.asBytes(&surface_tag));
        if (self.currentProject()) |path| hasher.update(path);
        return hasher.final();
    }

    fn selectProject(self: *App, path: []const u8) bool {
        const changed = if (self.model.currentGraph()) |graph|
            !std.mem.eql(u8, graph.project.path, path)
        else
            true;
        const selected = self.model.selectProject(path);
        if (selected) {
            self.client.setSubgraphAddress(null);
            if (changed) {
                const cancelled_inspection = self.worktree_inspection_thread != null or self.worktree_inspection_pending != null;
                self.worktree_inspection_generation += 1;
                self.worktree_inspection_cancellation.store(self.worktree_inspection_generation, .release);
                if (self.worktree_inspection_pending) |pending| {
                    pending.deinit(self.allocator);
                    self.worktree_inspection_pending = null;
                }
                if (self.worktree_loading_path.len != 0) {
                    self.allocator.free(self.worktree_loading_path);
                    self.worktree_loading_path = &.{};
                }
                if (self.worktree_state.len != 0) {
                    self.allocator.free(self.worktree_state);
                    self.worktree_state = &.{};
                }
                if (self.worktree_reclaim_receipts.len != 0) {
                    self.allocator.free(self.worktree_reclaim_receipts);
                    self.worktree_reclaim_receipts = &.{};
                }
                if (self.selected_worktree_path.len != 0) {
                    self.allocator.free(self.selected_worktree_path);
                    self.selected_worktree_path = &.{};
                }
                self.reclaim_confirmation_armed = false;
                if (cancelled_inspection) self.setStatus("Worktree inspection cancelled after project changed");
            }
        }
        return selected;
    }

    fn replaceSelectionID(self: *App, destination: *[]u8, value: []const u8) bool {
        const copy = self.allocator.dupe(u8, value) catch return false;
        if (destination.*.len != 0) self.allocator.free(destination.*);
        destination.* = copy;
        return true;
    }

    fn clearNodeSelection(self: *App) void {
        self.model.selected_index = null;
        if (self.selected_node_id.len != 0) {
            self.allocator.free(self.selected_node_id);
            self.selected_node_id = &.{};
        }
    }

    fn clearEdgeSelection(self: *App) void {
        self.canvas.selected_edge = null;
        self.canvas.selected_edge_id = "";
        if (self.selected_edge_project_path.len != 0) {
            self.allocator.free(self.selected_edge_project_path);
            self.selected_edge_project_path = &.{};
        }
        if (self.selected_edge_id.len != 0) {
            self.allocator.free(self.selected_edge_id);
            self.selected_edge_id = &.{};
        }
    }

    fn clearSelection(self: *App) void {
        self.selection_initialized = true;
        self.clearNodeSelection();
        self.clearEdgeSelection();
    }

    fn cancelCanvasInteraction(self: *App) void {
        self.canvas.cancelInteraction();
        self.clearCanvasNodePress();
        if (self.edge_drag_source_id.len != 0) {
            self.allocator.free(self.edge_drag_source_id);
            self.edge_drag_source_id = &.{};
        }
        _ = c.ReleaseCapture();
    }

    fn clearCanvasNodePress(self: *App) void {
        if (self.canvas_press_project_path.len != 0) self.allocator.free(self.canvas_press_project_path);
        if (self.canvas_press_node_id.len != 0) self.allocator.free(self.canvas_press_node_id);
        self.canvas_press_project_path = &.{};
        self.canvas_press_node_id = &.{};
    }

    fn beginCanvasNodePress(self: *App, project_path: []const u8, node_id: []const u8) bool {
        self.clearCanvasNodePress();
        self.canvas_press_project_path = self.allocator.dupe(u8, project_path) catch return false;
        self.canvas_press_node_id = self.allocator.dupe(u8, node_id) catch {
            self.allocator.free(self.canvas_press_project_path);
            self.canvas_press_project_path = &.{};
            return false;
        };
        return true;
    }

    fn clearSidebarRootDrag(self: *App) void {
        if (self.sidebar_drag_project_path.len != 0) self.allocator.free(self.sidebar_drag_project_path);
        if (self.sidebar_drag_node_id.len != 0) self.allocator.free(self.sidebar_drag_node_id);
        self.sidebar_drag_project_path = &.{};
        self.sidebar_drag_node_id = &.{};
        self.sidebar_drag_origin_y = 0;
        self.sidebar_drag_active = false;
        self.sidebar_drag_started = false;
    }

    fn beginSidebarRootDrag(self: *App, project_path: []const u8, node_id: []const u8, y: i32) void {
        self.clearSidebarRootDrag();
        self.sidebar_drag_project_path = self.allocator.dupe(u8, project_path) catch return;
        self.sidebar_drag_node_id = self.allocator.dupe(u8, node_id) catch {
            self.allocator.free(self.sidebar_drag_project_path);
            self.sidebar_drag_project_path = &.{};
            return;
        };
        self.sidebar_drag_origin_y = y;
        self.sidebar_drag_active = true;
    }

    fn updateSidebarRootDrag(self: *App, y: i32) void {
        if (!self.sidebar_drag_active or self.sidebar_drag_started) return;
        if (@abs(y - self.sidebar_drag_origin_y) < 6) return;
        self.sidebar_drag_started = true;
        _ = c.SetCapture(self.window.hwnd);
    }

    fn sidebarRootDropIndex(self: *App, project_path: []const u8, y: i32) ?usize {
        var rows = Sidebar.appendRows(
            self.allocator,
            &self.model,
            if (self.worktree_inspection) |*value| value else null,
            self.sidebar_scroll,
            &self.sidebar_state,
        ) catch return null;
        defer rows.deinit(self.allocator);
        var count: usize = 0;
        for (rows.items) |row| {
            if (row.kind != .loop or row.depth != 0) continue;
            if (row.project_path == null or !std.mem.eql(u8, row.project_path.?, project_path)) continue;
            if (y < row.top + 12) return count;
            count += 1;
        }
        return count;
    }

    fn completeSidebarRootDrag(self: *App, y: i32) bool {
        if (!self.sidebar_drag_active) return false;
        defer {
            if (self.sidebar_drag_started) _ = c.ReleaseCapture();
            self.clearSidebarRootDrag();
        }
        if (!self.sidebar_drag_started) return false;
        const graph = self.model.graphFor(self.sidebar_drag_project_path) orelse return true;
        const drop_index = self.sidebarRootDropIndex(self.sidebar_drag_project_path, y) orelse return true;
        const changed = Sidebar.reorderRootIDs(
            &self.sidebar_state,
            self.allocator,
            graph.nodes.items,
            graph.edges.items,
            self.sidebar_drag_node_id,
            drop_index,
        ) catch {
            self.setStatus("Sidebar root order could not be updated");
            return true;
        };
        if (!changed) return true;
        if (self.sidebar_store) |*store| store.save(&self.sidebar_state) catch self.setStatus("Sidebar root order could not be saved");
        var roots = Sidebar.rootIDs(self.allocator, graph.nodes.items, graph.edges.items, &self.sidebar_state) catch {
            self.setStatus("Sidebar root order could not be collected");
            return true;
        };
        defer roots.deinit(self.allocator);
        self.client.sendSidebarRootOrder(self.sidebar_drag_project_path, roots.items);
        self.setStatus("Sidebar root order updated");
        self.syncAccessibility();
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
        return true;
    }

    fn copyEdgeDragSourceForDrop(self: *App) ?[]u8 {
        const source_id = self.canvas.endEdgeDrag() orelse return null;
        return self.allocator.dupe(u8, source_id) catch {
            self.cancelCanvasInteraction();
            return null;
        };
    }

    fn selectNodeIndex(self: *App, index: usize) bool {
        const graph = self.model.graph orelse return false;
        if (index >= graph.nodes.items.len) return false;
        if (!self.replaceSelectionID(&self.selected_node_id, graph.nodes.items[index].id)) return false;
        if (!self.model.setSelectedIndex(index)) return false;
        self.selection_initialized = true;
        self.clearEdgeSelection();
        return true;
    }

    fn selectEdgeIndex(self: *App, index: usize) bool {
        const graph = self.model.graph orelse return false;
        if (index >= graph.edges.items.len) return false;
        if (graph.edges.items[index].id.len != 0) {
            if (!self.replaceSelectionID(&self.selected_edge_id, graph.edges.items[index].id)) return false;
            if (!self.replaceSelectionID(&self.selected_edge_project_path, graph.project.path)) return false;
        } else {
            if (self.selected_edge_id.len != 0) self.allocator.free(self.selected_edge_id);
            self.selected_edge_id = &.{};
        }
        self.canvas.selected_edge = index;
        self.canvas.selected_edge_id = self.selected_edge_id;
        self.selection_initialized = true;
        self.clearNodeSelection();
        return true;
    }

    fn remapSelection(self: *App) void {
        if (self.edge_drag_source_id.len != 0) {
            if (self.model.findNodeIndex(self.edge_drag_source_id) == null) {
                self.cancelCanvasInteraction();
            }
        }
        if (!self.selection_initialized) {
            if (self.model.graph) |graph| {
                if (graph.nodes.items.len != 0) {
                    _ = self.selectNodeIndex(0);
                    return;
                }
            }
        }
        if (self.selected_node_id.len != 0) {
            self.model.selected_index = self.model.findNodeIndex(self.selected_node_id);
            if (self.model.selected_index == null) {
                self.clearNodeSelection();
            }
        } else {
            self.model.selected_index = null;
        }
        if (self.selected_edge_id.len != 0 and
            self.selected_edge_project_path.len != 0 and
            self.model.currentGraph() != null and
            std.mem.eql(u8, self.model.currentGraph().?.project.path, self.selected_edge_project_path))
        {
            self.canvas.selected_edge = GraphModel.findEdgeIndexByID(
                self.model.graph.?.edges.items,
                self.selected_edge_id,
            );
            if (self.canvas.selected_edge == null) {
                self.clearEdgeSelection();
            } else {
                self.canvas.selected_edge_id = self.selected_edge_id;
            }
        } else {
            self.canvas.selected_edge = null;
            self.canvas.selected_edge_id = "";
        }
    }

    fn createQuickChat(self: *App) void {
        self.client.sendCreateQuickChat("Chat", "claudeCode");
        self.setStatus("Creating quick chat...");
    }

    fn renameSelectedQuickChat(self: *App) void {
        const index = self.selected_quick_chat orelse return;
        if (index >= self.model.quick_chats.items.len) return;
        const chat = self.model.quick_chats.items[index];
        var result = NativeDialogs.text(
            self.window.hwnd,
            self.allocator,
            "Rename Quick Chat",
            &.{"Title"},
            &.{chat.title},
        ) catch {
            self.setStatus("Unable to open quick chat rename form");
            return;
        } orelse return;
        defer result.deinit(self.allocator);
        const title_value = std.mem.trim(u8, result.values[0], " \t\r\n");
        if (title_value.len == 0) {
            self.setStatus("Invalid quick chat title");
            return;
        }
        self.client.sendRenameQuickChat(chat.id, title_value);
    }

    fn deleteSelectedQuickChat(self: *App) void {
        const index = self.selected_quick_chat orelse return;
        if (index >= self.model.quick_chats.items.len) return;
        const chat = self.model.quick_chats.items[index];
        const message = std.fmt.allocPrint(
            self.allocator,
            "Delete \"{s}\"?\n\nIts terminal session and scrollback will be removed. This cannot be undone.",
            .{chat.title},
        ) catch return;
        defer self.allocator.free(message);
        if (!GraphContextMenu.confirm(self.window.hwnd, "Delete Quick Chat", message)) return;
        self.client.sendDeleteQuickChat(chat.id);
    }

    fn openQuickChat(self: *App, id: []const u8) void {
        for (self.model.quick_chats.items, 0..) |chat, index| {
            if (!std.mem.eql(u8, chat.id, id)) continue;
            self.selected_quick_chat = index;
            self.workspace_is_quick_chat = true;
            self.surface = .workspace;
            self.workspace_controls.panel_visible = true;
            self.layoutWorkspace();
            self.layoutEmptyStateControls();
            if (self.workspace) |workspace| {
                if (std.process.getEnvVarOwned(self.allocator, "USERPROFILE")) |home| {
                    defer self.allocator.free(home);
                    _ = workspace.rebindProject(home) catch {};
                } else |_| {}
                workspace.openNode(0, chat.id) catch {
                    self.setStatus("Unable to open quick chat workspace");
                };
            }
            self.syncAccessibility();
            return;
        }
    }

    fn selectNextNode(self: *App) void {
        const graph = self.model.graph orelse return;
        if (graph.nodes.items.len == 0) {
            self.clearNodeSelection();
            return;
        }
        const next = if (self.model.selected_index) |index|
            (index + 1) % graph.nodes.items.len
        else
            0;
        _ = self.selectNodeIndex(next);
    }

    fn selectNextAttention(self: *App) void {
        self.model.selectNextAttention();
        if (!self.model.isCompositeOpen()) self.client.setSubgraphAddress(null);
        if (self.model.selected_index) |index| _ = self.selectNodeIndex(index);
    }

    // A loop workspace's bar names the selected loop. So with one open, a route that
    // moves the selection to another loop must open that loop through `activateLoop`, or
    // the bar and the visible pane name different loops. Graph surfaces only select.

    fn openNextAttention(self: *App) void {
        if (self.model.attention_entries.items.len == 0) return;
        const open_node_id = self.allocator.dupe(u8, self.selected_node_id) catch return;
        defer self.allocator.free(open_node_id);
        self.selectNextAttention();
        if (std.mem.eql(u8, open_node_id, self.selected_node_id)) return;
        self.openSelectedNode();
    }

    fn stepOpenLoop(self: *App, forward: bool) void {
        const graph = self.model.graph orelse return;
        const count = graph.nodes.items.len;
        if (count == 0) return;
        const target = if (self.model.selected_index) |current|
            (if (forward) (current + 1) % count else (current + count - 1) % count)
        else if (forward) 0 else count - 1;
        if (self.model.selected_index == target) return;
        _ = self.activateLoop(graph.project.path, graph.nodes.items[target].id);
    }

    /// The sidebar's Needs-you row, by pointer or UIA. Returns whether it only selected.
    fn chooseAttentionEntry(self: *App, index: usize) bool {
        if (index >= self.model.attention_entries.items.len) return false;
        const entry = self.model.attention_entries.items[index];
        if (self.surface == .workspace) {
            _ = self.activateLoop(entry.project_path, entry.node.id);
            return false;
        }
        if (!self.selectProject(entry.project_path)) return false;
        _ = self.model.setSelectedID(entry.node.id);
        return true;
    }

    fn stopAttentionEntry(self: *App, entry: GraphModel.AttentionEntry) void {
        self.client.sendNodeAction(entry.project_path, entry.node.id, "stopNode", null);
        const project_name = if (self.model.graphFor(entry.project_path)) |graph| graph.project.name else entry.project_path;
        const message = std.fmt.allocPrint(self.allocator, "Stopping {s} in {s}...", .{ entry.node.title, project_name }) catch return;
        self.replaceStatus(message);
    }

    fn navigateToActivityEvent(self: *App, event: GraphModel.ActivityEvent) void {
        const graph = self.model.graphFor(event.project_path) orelse return;
        const index = GraphModel.findNodeIndexByID(graph.nodes.items, event.node_id) orelse return;
        self.openLoopFromAccessibility(event.project_path, index);
    }

    fn selectedEdgeIndex(self: *const App) ?usize {
        if (self.selected_edge_id.len == 0 or self.selected_edge_project_path.len == 0) return null;
        const graph = self.model.graph orelse return null;
        if (!std.mem.eql(u8, graph.project.path, self.selected_edge_project_path)) return null;
        return GraphModel.findEdgeIndexByID(graph.edges.items, self.selected_edge_id);
    }

    pub const WorktreeChoice = NativeForms.WorktreeChoice;

    const NodeFormWorktreeChoices = struct {
        items: []WorktreeChoice = &.{},

        fn deinit(self: *NodeFormWorktreeChoices, allocator: std.mem.Allocator) void {
            for (self.items) |choice| {
                allocator.free(choice.path);
                allocator.free(choice.branch);
            }
            allocator.free(self.items);
            self.* = .{};
        }
    };

    /// The modal pumps graph events that can replace the cached inspection.
    /// Own its strings and admit only choices for the captured creation project.
    fn worktreeChoicesForNodeForm(
        self: *const App,
        allocator: std.mem.Allocator,
        project_path: []const u8,
    ) !NodeFormWorktreeChoices {
        const inspection = self.worktree_inspection orelse return .{};
        if (!std.mem.eql(u8, inspection.project_path, project_path)) return .{};
        var choices = NodeFormWorktreeChoices{
            .items = try allocator.alloc(WorktreeChoice, inspection.entries.items.len),
        };
        for (choices.items) |*choice| choice.* = .{ .path = &.{}, .branch = &.{}, .is_default = false };
        errdefer choices.deinit(allocator);
        for (inspection.entries.items, 0..) |entry, index| {
            choices.items[index].path = try allocator.dupe(u8, entry.path);
            choices.items[index].branch = try allocator.dupe(u8, entry.branch);
            choices.items[index].is_default = entry.branch.len != 0 and std.mem.eql(u8, entry.branch, inspection.default_branch);
        }
        return choices;
    }

    const NodeCreationParent = struct { id: []const u8, backend: []const u8, loop_type: []const u8, state: []const u8 };

    const NodeCreationContext = struct {
        project_path: []u8,
        composite_id: ?[]u8,
        origin: enum { loaded, recent, inspection, overview_global },
        // Child contexts and their parent strings belong to ChildNodeCreation's arena.
        parent: ?NodeCreationParent = null,

        fn deinit(self: *NodeCreationContext, allocator: std.mem.Allocator) void {
            allocator.free(self.project_path);
            if (self.composite_id) |id| allocator.free(id);
        }
    };

    const ChildNodeCreation = struct {
        arena: std.heap.ArenaAllocator,
        context: NodeCreationContext,
        popup_project: ?[]const u8,
        popup_composite: ?[]const u8,
        popup_client_composite: []const u8,
        popup_surface: GraphCanvas.Surface,
        initial: Forms.NodeDraft,
        choices: []const WorktreeChoice,

        fn deinit(self: *ChildNodeCreation) void {
            self.arena.deinit();
        }
    };

    fn sameOptionalID(left: ?[]const u8, right: ?[]const u8) bool {
        if (left) |value| return if (right) |other| std.mem.eql(u8, value, other) else false;
        return right == null;
    }

    fn childParentNode(self: *const App, path: []const u8, composite_id: ?[]const u8, parent_id: []const u8) !GraphModel.Node {
        const root = self.model.graphFor(path) orelse return error.NodeCreationProjectClosed;
        const nodes = if (composite_id) |id| blk: {
            if (!sameOptionalID(self.model.selected_project_path, path) or
                !sameOptionalID(self.model.open_composite_id, id))
                return error.NodeCreationCompositeChanged;
            const index = GraphModel.findNodeIndexByID(root.nodes.items, id) orelse return error.NodeCreationCompositeChanged;
            const composite = root.nodes.items[index];
            if ((!std.mem.eql(u8, composite.loop_type, "composite") and !std.mem.eql(u8, composite.loop_type, "proactive")) or
                composite.subgraph_json.len == 0)
                return error.NodeCreationCompositeChanged;
            break :blk (self.model.graph orelse return error.NodeCreationCompositeChanged).nodes.items;
        } else root.nodes.items;
        const index = GraphModel.findNodeIndexByID(nodes, parent_id) orelse return error.NodeCreationParentMissing;
        return nodes[index];
    }

    fn captureChildNodeCreation(self: *const App, path: []const u8, composite_id: ?[]const u8, parent_id: []const u8) !ChildNodeCreation {
        const parent = try self.childParentNode(path, composite_id, parent_id);
        const settings = self.product_settings orelse return error.NodeCreationSettingsUnavailable;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const parent_copy = NodeCreationParent{
            .id = try allocator.dupe(u8, parent.id),
            .backend = try allocator.dupe(u8, parent.backend),
            .loop_type = try allocator.dupe(u8, parent.loop_type),
            .state = try allocator.dupe(u8, parent.state),
        };
        var choices: []WorktreeChoice = &.{};
        if (self.worktree_inspection) |inspection| {
            if (std.mem.eql(u8, inspection.project_path, path)) {
                choices = try allocator.alloc(WorktreeChoice, inspection.entries.items.len);
                for (inspection.entries.items, choices) |entry, *choice| choice.* = .{
                    .path = try allocator.dupe(u8, entry.path),
                    .branch = try allocator.dupe(u8, entry.branch),
                    .is_default = entry.branch.len != 0 and std.mem.eql(u8, entry.branch, inspection.default_branch),
                };
            }
        }
        return .{
            .context = .{
                .project_path = try allocator.dupe(u8, path),
                .composite_id = if (composite_id) |id| try allocator.dupe(u8, id) else null,
                .origin = .loaded,
                .parent = parent_copy,
            },
            .popup_project = if (self.model.selected_project_path) |value| try allocator.dupe(u8, value) else null,
            .popup_composite = if (self.model.open_composite_id) |value| try allocator.dupe(u8, value) else null,
            .popup_client_composite = try allocator.dupe(u8, self.client.subgraph_node_id),
            .popup_surface = self.surface,
            .initial = .{
                .title = "",
                .backend = parent_copy.backend,
                .created_by = parent_copy.id,
                .model_tier = try allocator.dupe(u8, settings.default_model),
                .claude_permissions = try allocator.dupe(u8, settings.claude_permissions),
                .copilot_permissions = try allocator.dupe(u8, settings.copilot_permissions),
                .briefing_enabled = settings.briefing,
                .activity_enabled = settings.activity,
            },
            .choices = choices,
            .arena = arena,
        };
    }

    fn validateChildParent(self: *const App, context: *const NodeCreationContext) !void {
        const captured = context.parent orelse return;
        const parent = try self.childParentNode(context.project_path, context.composite_id, captured.id);
        if (isResolvedLoopState(captured.state) or isResolvedLoopState(parent.state)) return error.NodeCreationParentResolved;
        if (!std.mem.eql(u8, parent.loop_type, captured.loop_type)) return error.NodeCreationParentTypeChanged;
        if (!std.mem.eql(u8, parent.backend, captured.backend)) return error.NodeCreationParentBackendChanged;
        if (!Forms.isUuid(captured.id)) return error.InvalidCreatedBy;
        if (!Forms.isBackend(captured.backend)) return error.UnsupportedBackend;
    }

    fn prepareChildNodeCreation(self: *App, child: *const ChildNodeCreation) !void {
        if (!sameOptionalID(self.model.selected_project_path, child.popup_project) or
            !sameOptionalID(self.model.open_composite_id, child.popup_composite) or
            !std.mem.eql(u8, self.client.subgraph_node_id, child.popup_client_composite) or
            self.surface != child.popup_surface)
            return error.NodeCreationPopupChanged;
        try self.validateChildParent(&child.context);
        // A root sidebar target may belong to B while A (or B's composite) is showing.
        if (child.context.composite_id == null and
            (!sameOptionalID(self.model.selected_project_path, child.context.project_path) or self.model.open_composite_id != null))
        {
            if (!self.selectProject(child.context.project_path)) return error.NodeCreationSelectionFailed;
        }
        try self.validateNodeCreationContext(&child.context);
        const graph = self.model.graph orelse return error.NodeCreationProjectClosed;
        const index = GraphModel.findNodeIndexByID(graph.nodes.items, child.context.parent.?.id) orelse return error.NodeCreationParentMissing;
        if (!self.selectNodeIndex(index)) return error.NodeCreationSelectionFailed;
    }

    fn captureNodeCreationContext(self: *const App) !?NodeCreationContext {
        const current_path = self.currentProject() orelse if (self.surface == .overview)
            "graphcode://global"
        else
            return null;
        const path = try self.allocator.dupe(u8, current_path);
        errdefer self.allocator.free(path);
        return .{
            .project_path = path,
            .composite_id = if (self.model.open_composite_id) |id| try self.allocator.dupe(u8, id) else null,
            .origin = if (self.model.currentGraph() != null)
                .loaded
            else if (self.model.recent_projects.items.len != 0)
                .recent
            else if (self.worktree_inspection != null)
                .inspection
            else
                .overview_global,
        };
    }

    fn validateNodeCreationContext(self: *const App, context: *const NodeCreationContext) !void {
        if (context.origin == .loaded and self.model.graphFor(context.project_path) == null)
            return error.NodeCreationProjectClosed;
        const path = self.currentProject() orelse if (self.surface == .overview)
            "graphcode://global"
        else
            return error.NodeCreationProjectChanged;
        if (!std.mem.eql(u8, path, context.project_path)) return error.NodeCreationProjectChanged;
        if (context.composite_id) |id| {
            const current_id = self.model.open_composite_id orelse return error.NodeCreationCompositeChanged;
            if (id.len == 0 or !std.mem.eql(u8, current_id, id) or !std.mem.eql(u8, self.client.subgraph_node_id, id))
                return error.NodeCreationCompositeChanged;
            const graph = self.model.graphFor(context.project_path) orelse return error.NodeCreationCompositeChanged;
            const index = GraphModel.findNodeIndexByID(graph.nodes.items, id) orelse return error.NodeCreationCompositeChanged;
            const node = graph.nodes.items[index];
            if ((!std.mem.eql(u8, node.loop_type, "composite") and !std.mem.eql(u8, node.loop_type, "proactive")) or
                node.subgraph_json.len == 0)
                return error.NodeCreationCompositeChanged;
        } else if (self.model.open_composite_id != null or self.client.subgraph_node_id.len != 0) {
            return error.NodeCreationCompositeChanged;
        }
        try self.validateChildParent(context);
    }

    const NodeCreationValidation = struct {
        app: *const App,
        context: *const NodeCreationContext,

        fn check(raw: *const anyopaque) !void {
            const self: *const NodeCreationValidation = @ptrCast(@alignCast(raw));
            try self.app.validateNodeCreationContext(self.context);
        }
    };

    fn nodeCreationCleanupStatus(buffer: *[512]u8, primary_status: ?[]const u8, primary: ?anyerror, cleanup: anyerror) []const u8 {
        return std.fmt.bufPrint(buffer, "{s} ({s}); attachment cleanup failed ({s}). Staged files retained.", .{
            primary_status orelse if (primary) |err| nodeFormErrorStatus(err) else "Node creation cancelled",
            if (primary) |err| @errorName(err) else "cancelled",
            @errorName(cleanup),
        }) catch "Node creation did not complete; attachment cleanup also failed. Staged files retained.";
    }

    fn createNode(self: *App) void {
        var context = (self.captureNodeCreationContext() catch {
            self.setStatus("Unable to remember node creation context");
            return;
        }) orelse return;
        defer context.deinit(self.allocator);
        self.createNodeInContext(&context, null);
    }

    fn createNodeInContext(self: *App, context: *const NodeCreationContext, child: ?*const ChildNodeCreation) void {
        const path = context.project_path;
        Diagnostics.record(self.allocator, "action", "create-node");
        var continuation = NativeForms.NodeContinuation{};
        var primary_error: ?anyerror = null;
        var primary_status: ?[]const u8 = null;
        defer {
            if (continuation.abandon(self.allocator)) |cleanup_error| {
                var buffer: [512]u8 = undefined;
                self.setStatus(nodeCreationCleanupStatus(&buffer, primary_status, primary_error, cleanup_error));
                Diagnostics.record(self.allocator, "node-staging-retained", continuation.directory);
            }
            continuation.deinit(self.allocator);
        }
        const guard_context = NodeCreationValidation{ .app = self, .context = context };
        const validation = NativeForms.NodeValidation{ .context = &guard_context, .check = NodeCreationValidation.check };
        // Generated before the dialog opens (rather than at send time, as every other
        // draft field is) so a file picked mid-dialog can be copied straight into the
        // attachments directory this node will end up owning, instead of a temporary
        // location that would need a second copy once the real id is known.
        var draft_id_buffer: [36]u8 = undefined;
        Forms.generateDraftId(&draft_id_buffer);
        const initial = if (child) |captured| captured.initial else blk: {
            const settings = self.product_settings orelse return;
            break :blk Forms.NodeDraft{
                .title = "",
                .backend = settings.default_backend,
                .model_tier = settings.default_model,
                .claude_permissions = settings.claude_permissions,
                .copilot_permissions = settings.copilot_permissions,
                .briefing_enabled = settings.briefing,
                .activity_enabled = settings.activity,
            };
        };
        // Allocated once and shared by both the plain and templated forms below
        // so a project with no worktree inspection yet (or none at all, e.g.
        // graphcode://global) degrades to the same explicit empty picker either
        // form would otherwise have to special-case on its own.
        var owned_choices = if (child == null) self.worktreeChoicesForNodeForm(self.allocator, path) catch {
            self.setStatus("Unable to prepare worktree choices");
            return;
        } else NodeFormWorktreeChoices{};
        defer owned_choices.deinit(self.allocator);
        const choices = if (child) |captured| captured.choices else owned_choices.items;
        var templates = TemplateLibrary.load(self.allocator, path) catch |err| {
            const detail = std.fmt.allocPrint(
                self.allocator,
                "template-load path={s} error={s}",
                .{ path, @errorName(err) },
            ) catch null;
            if (detail) |message| {
                Diagnostics.record(self.allocator, "error", message);
                self.allocator.free(message);
            }
            self.setStatus("Unable to load saved templates");
            var draft = NativeForms.nodeGuarded(self.window.hwnd, self.allocator, path, &draft_id_buffer, choices, initial, validation, &continuation) catch |form_err| {
                primary_error = form_err;
                self.setStatus(nodeFormErrorStatus(form_err));
                return;
            } orelse return;
            defer draft.deinit(self.allocator);
            self.client.sendCreateNodeDraft(path, draft);
            return;
        };
        defer templates.deinit();
        if (templates.templates.items.len == 0) {
            var draft = NativeForms.nodeGuarded(self.window.hwnd, self.allocator, path, &draft_id_buffer, choices, initial, validation, &continuation) catch |err| {
                primary_error = err;
                self.setStatus(nodeFormErrorStatus(err));
                return;
            } orelse return;
            defer draft.deinit(self.allocator);
            self.client.sendCreateNodeDraft(path, draft);
            return;
        }

        var labels = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (labels.items) |label| self.allocator.free(label);
            labels.deinit();
        }
        for (templates.templates.items) |template| {
            const label = std.fmt.allocPrint(self.allocator, "{s} — {s}", .{ template.name, template.body }) catch {
                self.setStatus("Unable to prepare saved template list");
                return;
            };
            labels.append(label) catch {
                self.allocator.free(label);
                self.setStatus("Unable to prepare saved template list");
                return;
            };
        }

        var current = initial;
        var owns_current = false;
        defer if (owns_current) current.deinit(self.allocator);
        while (true) {
            const result = NativeForms.nodeWithTemplatesGuarded(self.window.hwnd, self.allocator, path, &draft_id_buffer, choices, current, true, validation, &continuation) catch |err| {
                primary_error = err;
                self.setStatus(nodeFormErrorStatus(err));
                return;
            };
            switch (result) {
                .cancelled => return,
                .draft => |draft| {
                    var submitted = draft;
                    defer submitted.deinit(self.allocator);
                    self.client.sendCreateNodeDraft(path, submitted);
                    return;
                },
                .templates => |draft| {
                    if (owns_current) current.deinit(self.allocator);
                    current = draft;
                    owns_current = true;
                    const selected = NativeForms.templatePicker(self.window.hwnd, self.allocator, labels.items) catch |err| {
                        primary_error = err;
                        primary_status = "Unable to open saved template picker";
                        self.setStatus("Unable to open saved template picker");
                        return;
                    };
                    self.validateNodeCreationContext(context) catch |err| {
                        primary_error = err;
                        self.setStatus(nodeFormErrorStatus(err));
                        return;
                    };
                    if (selected) |index| TemplateLibrary.applyOwned(&current, templates.templates.items[index], self.allocator) catch |err| {
                        primary_error = err;
                        primary_status = "Unable to apply selected template";
                        self.setStatus("Unable to apply selected template");
                        return;
                    };
                },
            }
        }
    }

    fn nodeFormErrorStatus(err: anyerror) []const u8 {
        return switch (err) {
            error.NodeCreationProjectClosed => "Project closed while creating node",
            error.NodeCreationProjectChanged => "Project changed while creating node",
            error.NodeCreationCompositeChanged => "Composite context changed while creating node",
            error.NodeCreationPopupChanged => "Context changed while the node menu was open",
            error.NodeCreationParentMissing => "Parent node no longer exists",
            error.NodeCreationParentResolved => "Parent node has resolved",
            error.NodeCreationParentTypeChanged => "Parent node type changed while creating child",
            error.NodeCreationParentBackendChanged => "Parent node backend changed while creating child",
            error.NodeCreationSelectionFailed => "Unable to select the child node's parent",
            error.NodeCreationSettingsUnavailable => "Node creation settings are unavailable",
            error.MissingNodeAttachmentOwnership => "Unable to restore node attachment ownership",
            error.NodeAttachmentCleanupFailed => "Unable to discard unused node attachments",
            error.EmptyTitle,
            error.MissingSource,
            error.MissingTarget,
            error.SameEndpoint,
            error.UnsupportedLoopType,
            error.UnsupportedEdgeKind,
            error.UnsupportedEdgeCondition,
            error.UnsupportedTransform,
            error.UnsupportedBackend,
            error.UnsupportedModelTier,
            error.UnsupportedMetricDirection,
            error.InvalidGoal,
            error.InvalidWorktree,
            error.InvalidSubgraph,
            error.InvalidCreatedBy,
            error.InvalidCycleGuard,
            error.InvalidNumericInput,
            error.MissingFirstInstruction,
            error.MissingTriggerPrompt,
            error.EmptyJumpQuery,
            error.TooManyAttachments,
            => "Invalid node form",
            else => "Unable to open node form",
        };
    }

    fn editSelectedNode(self: *App) void {
        const graph = self.model.graph orelse return;
        const index = self.model.selectedIndex() orelse return;
        if (index >= graph.nodes.items.len) return;
        const project_path = self.allocator.dupe(u8, graph.project.path) catch return;
        defer self.allocator.free(project_path);
        const node_id = self.allocator.dupe(u8, graph.nodes.items[index].id) catch return;
        defer self.allocator.free(node_id);
        var result = NativeDialogs.textWithDescription(
            self.window.hwnd,
            self.allocator,
            "Rename Loop",
            "Choose the title shown for this loop throughout the graph.",
            &.{"Title"},
            &.{graph.nodes.items[index].title},
        ) catch {
            self.setStatus("Unable to open loop rename form");
            return;
        } orelse return;
        defer result.deinit(self.allocator);
        const title_value = std.mem.trim(u8, result.values[0], " \t\r\n");
        if (title_value.len == 0) {
            self.setStatus("Loop title cannot be empty");
            return;
        }
        const updated_graph = self.model.graph orelse return;
        if (!std.mem.eql(u8, updated_graph.project.path, project_path)) return;
        const updated_index = GraphModel.findNodeIndexByID(updated_graph.nodes.items, node_id) orelse {
            self.setStatus("Loop changed while renaming");
            return;
        };
        self.client.sendRenameNode(project_path, updated_graph.nodes.items[updated_index].id, title_value);
    }

    fn editSelectedNodeDetails(self: *App) void {
        const graph = self.model.graph orelse return;
        const index = self.model.selectedIndex() orelse return;
        if (index >= graph.nodes.items.len) return;
        const node = graph.nodes.items[index];
        const project_path = self.allocator.dupe(u8, graph.project.path) catch {
            self.setStatus("Unable to remember the project while editing details");
            return;
        };
        defer self.allocator.free(project_path);
        const node_id = self.allocator.dupe(u8, node.id) catch {
            self.setStatus("Unable to remember the loop while editing details");
            return;
        };
        defer self.allocator.free(node_id);
        var update = NativeForms.update(self.window.hwnd, self.allocator, .{
            .goal_summary = if (node.goal_summary.len == 0) null else node.goal_summary,
            .goal_predicate = if (node.goal_predicate.len == 0) null else node.goal_predicate,
            .poll_interval_seconds = node.poll_interval_seconds,
            .stall_after_seconds = node.stall_after_seconds,
            .metric_command = if (node.metric_command.len == 0) null else node.metric_command,
            .metric_direction = if (node.metric_direction.len == 0) null else node.metric_direction,
            .trigger_prompt = if (node.trigger_prompt.len == 0) null else node.trigger_prompt,
            .check_description = if (node.check_description.len == 0) null else node.check_description,
            .model_tier = if (node.model_tier.len == 0) null else node.model_tier,
        }) catch {
            self.setStatus("Unable to open node details form");
            return;
        } orelse return;
        defer update.deinit(self.allocator);
        const current_graph = self.model.graph orelse {
            self.setStatus("Project closed while editing details");
            return;
        };
        if (!std.mem.eql(u8, current_graph.project.path, project_path)) {
            self.setStatus("Project changed while editing details");
            return;
        }
        const current_index = GraphModel.findNodeIndexByID(current_graph.nodes.items, node_id) orelse {
            self.setStatus("Loop changed while editing details");
            return;
        };
        self.client.sendUpdateNodeForm(current_graph.project.path, current_graph.nodes.items[current_index].id, update);
    }

    fn prepareSketchPromotion(self: *App, context: SketchPromotion.Context, target: ?SketchPromotion.Target) !bool {
        if (target == null) return false;
        const plan = try context.selectionPlan(&self.model, self.client.subgraph_node_id);
        if (plan == .root_project and !self.selectProject(context.project_path))
            return error.PromotionContextChanged;
        const graph = self.model.graph orelse return error.PromotionContextChanged;
        const index = GraphModel.findNodeIndexByID(graph.nodes.items, context.node_id) orelse return error.PromotionNodeMissing;
        if (!self.selectNodeIndex(index)) return error.OutOfMemory;
        try context.validateCurrent(&self.model, self.client.subgraph_node_id);
        return true;
    }

    fn promoteSketch(self: *App, stable: GraphContextMenu.NodeTarget, target: SketchPromotion.Target) void {
        const context = stable.promotion_context orelse {
            self.setStatus("Unable to retain sketch promotion context. Reopen the loop menu.");
            return;
        };
        if (!std.mem.eql(u8, stable.project_path, context.project_path) or !std.mem.eql(u8, stable.id, context.node_id)) {
            self.setStatus("Sketch promotion context changed. Reopen the loop menu.");
            return;
        }
        _ = self.prepareSketchPromotion(context.*, target) catch |err| {
            self.setPromotionError(err);
            return;
        };
        var draft = NativeForms.promotion(self.window.hwnd, self.allocator, target, context.*) catch |err| {
            self.setPromotionError(err);
            return;
        } orelse return;
        defer draft.deinit(self.allocator);
        _ = self.client.sendSketchPromotion(&self.model, context.*, draft) catch |err| {
            self.setPromotionError(err);
            return;
        };
        self.setStatus("Sketch promotion queued; waiting for the daemon.");
    }

    fn setPromotionError(self: *App, err: anyerror) void {
        self.setStatus(switch (err) {
            error.PromotionContextChanged => "Sketch promotion context changed. Nothing was submitted; reopen the loop menu.",
            error.PromotionNodeMissing => "The sketch was removed. Nothing was submitted.",
            error.NotSketch => "Only a sketch can be promoted. Nothing was submitted.",
            error.MissingGoal => "A goal promotion needs what done looks like.",
            error.PromotionQueueFull => "Unable to queue sketch promotion: daemon queue is full or closed.",
            error.OutOfMemory => "Unable to allocate sketch promotion fields. Nothing was submitted.",
            else => "Unable to prepare sketch promotion. Nothing was submitted.",
        });
    }

    fn createEdge(self: *App) void {
        const graph = self.model.graph orelse return;
        if (graph.nodes.items.len < 2) return;
        self.createEdgeForm(null);
    }

    fn createEdgeBetween(self: *App, source: usize, target: usize) void {
        const graph = self.model.graph orelse return;
        if (source >= graph.nodes.items.len or target >= graph.nodes.items.len or source == target) return;
        self.createEdgeBetweenIDs(graph.nodes.items[source].id, graph.nodes.items[target].id);
    }

    fn createEdgeBetweenIDs(self: *App, source_id: []const u8, target_id: []const u8) void {
        if (std.mem.eql(u8, source_id, target_id)) return;
        self.createEdgeForm(.{ .from = source_id, .to = target_id });
    }

    const EdgeCreationForm = struct {
        parent: c.HWND,

        pub fn show(
            self: EdgeCreationForm,
            allocator: std.mem.Allocator,
            initial: Forms.EdgeDraft,
            endpoints: []const NativeForms.EdgeEndpoint,
            locked: bool,
        ) !?Forms.EdgeDraft {
            if (locked) return NativeForms.edge(self.parent, allocator, initial);
            return NativeForms.edgeWithEndpoints(self.parent, allocator, initial, endpoints, false);
        }
    };

    fn createEdgeForm(self: *App, locked: ?EdgeCreation.LockedEndpoints) void {
        EdgeCreation.create(self.allocator, &self.model, &self.client, locked, EdgeCreationForm{
            .parent = self.window.hwnd,
        }) catch |err| {
            self.setStatus(EdgeCreation.errorStatus(err));
        };
    }

    fn openSettings(self: *App) void {
        const initial = self.client.effectiveSettings(self.allocator) catch {
            self.setStatus("Unable to load current settings");
            return;
        };
        defer self.allocator.free(initial.daemon_pipe);
        defer self.allocator.free(initial.support_directory);
        const draft = NativeForms.settings(self.window.hwnd, self.allocator, initial) catch {
            self.setStatus("Unable to open settings form");
            return;
        } orelse return;
        defer self.allocator.free(draft.daemon_pipe);
        defer self.allocator.free(draft.support_directory);
        self.applyWorkspaceConnectionSettings(draft.daemon_pipe, draft.support_directory) catch {
            self.setStatus("Invalid daemon settings");
            self.updateNativeChrome(.state_change);
            return;
        };
        self.syncAccessibility();
        self.updateNativeChrome(.state_change);
    }

    fn applyWorkspaceConnectionSettings(self: *App, pipe: []const u8, support: []const u8) !void {
        self.workspace_identity_valid = false;
        self.workspace_identity_blocked = true;
        try MainWindow.invalidateWorkspaceIdentity(self.window.hwnd);
        self.client.applySettings(pipe, support) catch |err| {
            try self.revalidateWorkspaceIdentity();
            return err;
        };
        try self.revalidateWorkspaceIdentity();
    }

    fn openProductSettings(self: *App) void {
        const store = if (self.product_settings_store) |*value| value else {
            self.setStatus("Product settings storage unavailable");
            return;
        };
        var current = store.load() catch {
            self.setStatus("Unable to load product settings");
            return;
        };
        defer current.deinit();
        const draft = ProductSettings.open(@intFromPtr(self.window.hwnd.?), self.allocator, current) catch {
            self.setStatus("Unable to open product settings");
            return;
        } orelse return;
        store.save(draft) catch {
            self.setStatus("Unable to save product settings");
            return;
        };
        if (self.product_settings) |*settings| settings.deinit();
        self.product_settings = draft;
        self.activity_enabled = draft.activity;
        self.workspace_controls.activity_enabled = draft.activity;
        self.update_lock.lock();
        self.update_state = WindowsUpdates.CheckState.configure(draft.beta);
        self.update_lock.unlock();
        self.setStatus("Checking for updates…");
        self.requestUpdateCheck(false);
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
    }

    fn applyOnboardingBackend(self: *App, backend: Onboarding.Backend) void {
        const store = if (self.product_settings_store) |*value| value else {
            self.setStatus("Onboarding choice could not be saved");
            return;
        };
        if (self.product_settings) |*settings| {
            const replacement = self.allocator.dupe(u8, backend.value()) catch {
                self.setStatus("Onboarding choice could not be saved");
                return;
            };
            self.allocator.free(settings.default_backend);
            settings.default_backend = replacement;
            store.save(settings.*) catch self.setStatus("Onboarding choice could not be saved");
            return;
        }
        var settings = ProductSettings.Settings.init(self.allocator) catch {
            self.setStatus("Onboarding choice could not be saved");
            return;
        };
        const replacement = self.allocator.dupe(u8, backend.value()) catch {
            settings.deinit();
            self.setStatus("Onboarding choice could not be saved");
            return;
        };
        self.allocator.free(settings.default_backend);
        settings.default_backend = replacement;
        store.save(settings) catch {
            settings.deinit();
            self.setStatus("Onboarding choice could not be saved");
            return;
        };
        self.product_settings = settings;
    }

    fn cloneRepository(self: *App) void {
        self.clearIngressError();
        const draft = RepositoryDialogs.openClone(self.window.hwnd, self.allocator, .{}) catch {
            self.setIngressError("Unable to open clone repository dialog");
            self.setStatus("Unable to open clone repository dialog");
            return;
        } orelse return;
        defer {
            self.allocator.free(draft.url);
            self.allocator.free(draft.destination);
            self.allocator.free(draft.branch);
            self.allocator.free(draft.depth);
        }
        RepositoryDialogs.validateClone(draft) catch |err| {
            self.setIngressError(@errorName(err));
            self.setStatus(@errorName(err));
            return;
        };
        if (self.clone_operation != null) {
            self.setIngressError("A clone is already running");
            self.setStatus("A clone is already running");
            return;
        }
        const operation = RepositoryDialogs.CloneOperation.start(self.allocator, draft) catch {
            self.setIngressError("Clone could not start");
            self.setStatus("Clone could not start");
            return;
        };
        defer operation.deinit();
        const clone_status = RepositoryDialogs.showCloneProgress(self.window.hwnd, self.allocator, operation) catch {
            operation.cancel();
            self.setIngressError("Clone progress sheet could not open");
            self.setStatus("Clone progress sheet could not open");
            return;
        };
        switch (clone_status) {
            .finished => self.setStatus("Repository cloned"),
            .cancelled => self.setStatus("Clone cancelled"),
            else => {
                self.setIngressError("Clone failed");
                self.setStatus("Clone failed");
            },
        }
    }

    fn cancelClone(self: *App) void {
        if (self.clone_operation) |operation| {
            operation.cancel();
            self.setStatus("Cancelling clone…");
        }
    }

    pub fn checkForUpdates(self: *App) void {
        self.setStatus("Checking for updates...");
        self.requestUpdateCheck(true);
        self.updateNativeChrome(.state_change);
    }

    fn requestUpdateCheck(self: *App, user_initiated: bool) void {
        self.update_lock.lock();
        self.update_generation += 1;
        self.update_user_initiated = user_initiated;
        self.update_pending = true;
        self.update_offer_pending = false;
        if (self.update_thread != null) {
            self.update_cancel.store(true, .release);
            self.update_lock.unlock();
            return;
        }
        self.update_pending = false;
        self.update_cancel.store(false, .release);
        self.update_lock.unlock();
        self.launchUpdateCheck();
    }

    fn launchUpdateCheck(self: *App) void {
        self.update_lock.lock();
        self.update_done = false;
        self.update_cancel.store(false, .release);
        self.update_lock.unlock();
        self.update_thread = std.Thread.spawn(.{}, updateWorker, .{self}) catch {
            self.update_lock.lock();
            self.update_done = true;
            self.update_lock.unlock();
            self.setStatus("Update check could not start");
            return;
        };
    }

    fn updateWorker(self: *App) void {
        self.update_lock.lock();
        const generation = self.update_generation;
        const beta = self.update_state.channel == .beta;
        self.update_lock.unlock();
        const version = WindowsUpdates.currentVersionFromMetadata(self.allocator, build_options.version) catch {
            self.update_lock.lock();
            if (generation == self.update_generation) self.update_state = .{ .channel = if (beta) .beta else .stable, .state = .failed };
            self.update_done = true;
            self.update_lock.unlock();
            return;
        };
        defer self.allocator.free(version);
        var client = WindowsUpdates.CheckClient{ .allocator = self.allocator };
        var result = client.checkWithCancel(beta, version, &self.update_cancel) catch {
            self.update_lock.lock();
            if (generation == self.update_generation and !self.update_cancel.load(.acquire))
                self.update_state = .{ .channel = if (beta) .beta else .stable, .state = .failed };
            self.update_done = true;
            self.update_lock.unlock();
            return;
        };
        defer result.deinit(self.allocator);
        self.update_lock.lock();
        if (generation == self.update_generation and !self.update_cancel.load(.acquire)) {
            self.update_state = .{ .channel = result.channel, .state = result.state };
            if (self.update_version.len != 0) self.allocator.free(self.update_version);
            if (self.update_release_url.len != 0) self.allocator.free(self.update_release_url);
            if (self.update_asset_url.len != 0) self.allocator.free(self.update_asset_url);
            if (self.update_asset_sha256.len != 0) self.allocator.free(self.update_asset_sha256);
            if (self.update_asset_checksum_url.len != 0) self.allocator.free(self.update_asset_checksum_url);
            self.update_version = result.version orelse &.{};
            self.update_release_url = result.release_url orelse &.{};
            self.update_asset_url = result.asset_url orelse &.{};
            self.update_asset_sha256 = result.asset_sha256 orelse &.{};
            self.update_asset_checksum_url = result.asset_checksum_url orelse &.{};
            result.version = null;
            result.release_url = null;
            result.asset_url = null;
            result.asset_sha256 = null;
            result.asset_checksum_url = null;
        }
        self.update_done = true;
        self.update_lock.unlock();
    }

    fn finishUpdateCheck(self: *App) void {
        self.update_lock.lock();
        const done = self.update_done;
        self.update_lock.unlock();
        var completed_offer = false;
        if (done) {
            if (self.update_thread) |thread| {
                thread.join();
                self.update_thread = null;
                self.update_lock.lock();
                const pending = self.update_pending;
                self.update_pending = false;
                const label = self.update_state.label();
                const present_offer = self.update_state.shouldPresentOffer(self.update_user_initiated);
                self.update_lock.unlock();
                if (pending) {
                    self.launchUpdateCheck();
                } else {
                    self.setStatus(label);
                    completed_offer = present_offer;
                    // Re-enable Check for Updates immediately: the general
                    // chrome refresh elsewhere in the timer tick is gated on
                    // daemon connectivity, but Check for Updates has nothing
                    // to do with the project daemon and must re-enable the
                    // moment the background thread is observed to have
                    // finished, whether or not a project connection exists.
                    // Use the single-item toggle rather than the full
                    // updateNativeChrome rebuild, since this can land
                    // mid-interaction (e.g. a context menu already tracking)
                    // and rebuilding the Recent Folders/Workspace submenus
                    // there is not safe. (Skipped on the `pending` branch
                    // above: a fresh check just launched, so it must stay
                    // disabled.)
                    MainWindow.setUpdateCheckEnabled(self.window.hwnd, true);
                }
            }
        }
        switch (UpdateOfferPresentation.decide(completed_offer, self.update_offer_pending, NativeForms.isModalActive())) {
            .none => {},
            .defer_until_modal_closes => self.update_offer_pending = true,
            .present => {
                self.update_offer_pending = false;
                self.showAvailableUpdate(self.update_version, self.update_release_url);
            },
        }
    }

    fn showAvailableUpdate(self: *App, version: []const u8, release_url: []const u8) void {
        const url = WindowsUpdates.releasePageUrl(release_url) catch {
            self.setStatus("Update release URL is not a trusted GraphCode release page");
            return;
        };
        const installable = self.update_asset_url.len != 0;
        const reason = if (installable)
            "Install downloads the Windows package, verifies it, and installs it in place."
        else
            "No Windows build is attached to this release yet. Download the Windows ZIP from the release page once one is published.";
        const action = UpdateOfferDialog.show(
            self.window.hwnd,
            self.allocator,
            version,
            reason,
            installable,
        ) catch {
            self.setStatus("Unable to prepare the update offer");
            return;
        };
        switch (action) {
            .later => self.setStatus("Update offer deferred"),
            .install_unavailable => self.setStatus("No Windows build is published for this release yet"),
            .install => self.runInstall(),
            .release_notes => {
                const url_wide = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, url) catch {
                    self.setStatus("Unable to encode the release URL");
                    return;
                };
                defer self.allocator.free(url_wide);
                const result = c.ShellExecuteW(
                    self.window.hwnd,
                    std.unicode.utf8ToUtf16LeStringLiteral("open").ptr,
                    url_wide.ptr,
                    null,
                    null,
                    c.SW_SHOWNORMAL,
                );
                self.setStatus(if (@intFromPtr(result) <= 32) "Unable to open the release page" else "Opened the GraphCode release page");
            },
        }
    }

    fn runInstall(self: *App) void {
        const sha256: ?[]const u8 = if (self.update_asset_sha256.len != 0) self.update_asset_sha256 else null;
        const checksum_url: ?[]const u8 = if (self.update_asset_checksum_url.len != 0) self.update_asset_checksum_url else null;
        const outcome = UpdateInstallDialog.run(
            self.window.hwnd,
            self.allocator,
            self.update_asset_url,
            sha256,
            checksum_url,
        ) catch {
            self.setStatus("Unable to start the update install");
            return;
        };
        switch (outcome) {
            .relaunch => |choice| switch (choice) {
                .relaunch_now => self.relaunchAfterUpdate(),
                .later => self.setStatus("Update installed. Relaunch GraphCode to use it."),
            },
            .cancelled => self.setStatus("Update install cancelled"),
            .failed => |message| self.setStatus(message.text()),
        }
    }

    /// Spawns a fresh instance of the (now-upgraded, atomically swapped-in)
    /// executable at the same path, then tears this process down. zmx-backed
    /// terminal sessions are held by the background daemon, not this GUI
    /// process, so they are unaffected by this relaunch.
    fn relaunchAfterUpdate(self: *App) void {
        var executable: [32768]u16 = undefined;
        const length = c.GetModuleFileNameW(null, &executable, executable.len);
        if (length == 0 or length >= executable.len) {
            self.setStatus("GraphCode executable path could not be resolved; relaunch it manually");
            return;
        }
        executable[length] = 0;
        var startup: c.STARTUPINFOW = std.mem.zeroes(c.STARTUPINFOW);
        startup.cb = @sizeOf(c.STARTUPINFOW);
        var process: c.PROCESS_INFORMATION = undefined;
        if (c.CreateProcessW(executable[0..length :0].ptr, null, null, null, 0, 0, null, null, &startup, &process) == 0) {
            self.setStatus("The update installed, but GraphCode could not relaunch itself automatically");
            return;
        }
        _ = c.CloseHandle(process.hThread);
        _ = c.CloseHandle(process.hProcess);
        _ = c.DestroyWindow(self.window.hwnd);
    }

    fn showCurrentUpdateOffer(self: *App) void {
        self.update_lock.lock();
        const available = self.update_state.state == .available;
        const version = if (available) self.allocator.dupe(u8, self.update_version) catch null else null;
        const release_url = if (available) self.allocator.dupe(u8, self.update_release_url) catch null else null;
        self.update_lock.unlock();
        defer if (version) |value| self.allocator.free(value);
        defer if (release_url) |value| self.allocator.free(value);
        if (!available) return;
        if (version == null or release_url == null) {
            self.setStatus("Unable to prepare the update offer");
            return;
        }
        self.showAvailableUpdate(version.?, release_url.?);
    }

    fn addRemoteRepository(self: *App) void {
        self.clearIngressError();
        const draft = RepositoryDialogs.openRemote(self.window.hwnd, self.allocator, .{}) catch {
            self.setIngressError("Unable to open SSH repository dialog");
            self.setStatus("Unable to open SSH repository dialog");
            return;
        } orelse return;
        defer {
            self.allocator.free(draft.host);
            self.allocator.free(draft.user);
            self.allocator.free(draft.port);
            self.allocator.free(draft.path);
        }
        RepositoryDialogs.validateRemote(draft) catch |err| {
            self.setIngressError(@errorName(err));
            self.setStatus(@errorName(err));
            return;
        };
        if (!(RepositoryDialogs.showRemoteValidation(self.window.hwnd, self.allocator, draft) catch {
            self.setIngressError("SSH validation could not start");
            self.setStatus("SSH validation could not start");
            return;
        })) {
            self.setIngressError("SSH connection validation failed");
            self.setStatus("SSH connection validation failed");
            return;
        }
        RepositoryDialogs.saveRemoteConfig(self.allocator, draft) catch {
            self.setIngressError("SSH validated but remote configuration could not be saved");
            self.setStatus("SSH validated but remote configuration could not be saved");
            return;
        };
        const remote_path = RepositoryDialogs.remoteProjectURI(self.allocator, draft) catch {
            self.setIngressError("Unable to encode remote repository");
            self.setStatus("Unable to encode remote repository");
            return;
        };
        defer self.allocator.free(remote_path);
        _ = self.client.sendOpenProject(remote_path);
        self.client.reconnect();
        self.setStatus("SSH repository connected; reconnect requested");
    }

    fn addCodespaceRepository(self: *App) void {
        self.clearIngressError();
        var paths = std.array_list.Managed([]const u8).init(self.allocator);
        defer paths.deinit();
        for (self.model.graphs.items) |graph| {
            if (graph.project.isLocalFilesystem()) {
                paths.append(graph.project.path) catch break;
            }
        }
        var accepted = CodespaceDialog.open(self.window.hwnd, self.allocator, paths.items) catch {
            self.setIngressError("Unable to open the codespace dialog");
            self.setStatus("Unable to open the codespace dialog");
            return;
        } orelse return;
        defer accepted.deinit(self.allocator);

        const fields = Codespaces.Fields{ .name = accepted.name, .path = accepted.path };
        Codespaces.saveConfig(self.allocator, fields) catch {
            self.setIngressError("Codespace validated but its configuration could not be saved");
            self.setStatus("Codespace validated but its configuration could not be saved");
            return;
        };
        const project_path = Codespaces.projectURI(self.allocator, fields) catch {
            self.setIngressError("Unable to encode the codespace repository");
            self.setStatus("Unable to encode the codespace repository");
            return;
        };
        defer self.allocator.free(project_path);
        _ = self.client.sendOpenProject(project_path);
        self.client.reconnect();
        self.setStatus("Codespace connected; reconnect requested");
    }

    fn jumpToNode(self: *App) void {
        var entries = std.array_list.Managed(JumpPalette.Entry).init(self.allocator);
        defer entries.deinit();
        for (self.model.graphs.items) |graph| {
            for (graph.nodes.items) |node| {
                entries.append(.{
                    .project_path = graph.project.path,
                    .project_name = graph.project.name,
                    .node_id = node.id,
                    .title = node.title,
                    .loop_type = node.loop_type,
                    .state = node.state,
                }) catch {
                    self.setStatus("Unable to collect jump results");
                    return;
                };
            }
        }
        const selection = JumpPalette.show(self.window.hwnd, self.allocator, entries.items) catch {
            self.setStatus("Unable to open jump palette");
            return;
        } orelse return;
        defer selection.deinit(self.allocator);
        const project_index = for (self.model.graphs.items, 0..) |graph, index| {
            if (std.mem.eql(u8, graph.project.path, selection.project_path)) break index;
        } else {
            self.setStatus("Matching loop is no longer available");
            return;
        };
        const node_index = for (self.model.graphs.items[project_index].nodes.items, 0..) |node, index| {
            if (std.mem.eql(u8, node.id, selection.node_id)) break index;
        } else {
            self.setStatus("Matching loop is no longer available");
            return;
        };
        if (!self.selectProject(selection.project_path) or !self.selectNodeIndex(node_index)) return;
        self.surface = .project;
        self.workspace_controls.panel_visible = false;
        self.layoutWorkspace();
        self.layoutEmptyStateControls();
        self.sidebar_scroll = Sidebar.clampScroll(
            Sidebar.loopRowTopForModel(&self.model, node_index) - 24,
            Sidebar.maxScroll(&self.model, if (self.worktree_inspection) |*value| value else null, 700, &self.sidebar_state),
        );
        self.syncAccessibility();
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
    }

    fn openSelectedNode(self: *App) void {
        const graph = if (self.model.graph) |value| value else return;
        const index = self.model.selectedIndex() orelse return;
        if (index >= graph.nodes.items.len) return;
        const project_path = self.currentProject() orelse return;
        _ = self.activateLoop(project_path, graph.nodes.items[index].id);
    }

    fn activateLoop(self: *App, project_path: []const u8, node_id: []const u8) bool {
        const owned_project_path = self.allocator.dupe(u8, project_path) catch {
            self.setStatus("Unable to select loop");
            return false;
        };
        defer self.allocator.free(owned_project_path);
        const owned_node_id = self.allocator.dupe(u8, node_id) catch {
            self.setStatus("Unable to select loop");
            return false;
        };
        defer self.allocator.free(owned_node_id);
        if (!self.selectProject(owned_project_path)) return false;
        const graph = self.model.graph orelse return false;
        const index = GraphModel.findNodeIndexByID(graph.nodes.items, owned_node_id) orelse {
            self.setStatus("Selected loop is no longer available");
            return false;
        };
        if (!self.selectNodeIndex(index)) {
            self.setStatus("Unable to select loop");
            return false;
        }
        if (!self.model.isCompositeOpen() and
            (std.mem.eql(u8, graph.nodes.items[index].loop_type, "composite") or
                std.mem.eql(u8, graph.nodes.items[index].loop_type, "proactive")))
        {
            self.surface = .project;
            self.workspace_controls.panel_visible = false;
            self.layoutWorkspace();
            self.layoutEmptyStateControls();
            self.showCompositeGroup(graph.nodes.items[index]);
            return true;
        }
        if (self.model.isCompositeOpen()) {
            self.setStatus("Composite templates have no terminal until the group is piloted");
            return false;
        }
        self.workspace_is_quick_chat = false;
        self.surface = .workspace;
        self.workspace_controls.panel_visible = true;
        self.layoutWorkspace();
        self.layoutEmptyStateControls();
        self.clearEdgeSelection();
        self.rebindWorkspace(owned_project_path);
        self.openGraphLoop(owned_project_path, owned_node_id);
        if (self.workspace) |workspace|
            workspace.focusRestoredPane() catch self.setStatus("Unable to restore selected terminal focus");
        self.syncAccessibility();
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
        return true;
    }

    fn stopSelectedNode(self: *App) void {
        const path = self.currentProject() orelse return;
        const node = self.model.selected() orelse return;
        self.client.sendNodeAction(path, node.id, "stopNode", null);
    }

    fn sendSelectedNode(self: *App) void {
        const path = self.currentProject() orelse return;
        const node = self.model.selected() orelse return;
        self.client.sendNodeAction(path, node.id, "messageNode", "GraphCode Windows shell message");
    }

    fn deleteSelectedNode(self: *App) void {
        const graph = self.model.graph orelse return;
        const index = self.model.selected_index orelse return;
        if (index >= graph.nodes.items.len) return;
        const path = self.allocator.dupe(u8, graph.project.path) catch return;
        defer self.allocator.free(path);
        const node_id = self.allocator.dupe(u8, graph.nodes.items[index].id) catch return;
        defer self.allocator.free(node_id);
        const message = std.fmt.allocPrint(
            self.allocator,
            "Delete \"{s}\"?\n\nThe loop and its graph connections will be removed. This cannot be undone.",
            .{graph.nodes.items[index].title},
        ) catch return;
        defer self.allocator.free(message);
        if (!GraphContextMenu.confirm(self.window.hwnd, "Delete Loop", message)) return;
        const updated_graph = self.model.graph orelse return;
        const updated_index = GraphModel.findNodeIndexByID(updated_graph.nodes.items, node_id) orelse return;
        self.client.sendDeleteNode(path, updated_graph.nodes.items[updated_index].id);
    }

    fn editSelectedEdge(self: *App, index: usize) void {
        const result = EdgeEditing.edit(self.allocator, &self.model, &self.client, index, .{ .context = self, .show = showEdgeEditor }) catch |err| {
            var message: [160]u8 = undefined;
            self.setStatus(std.fmt.bufPrint(&message, "Unable to edit edge: {s}", .{@errorName(err)}) catch "Unable to edit edge");
            return;
        };
        if (result == .queued) self.setStatus("Edge update queued; waiting for daemon");
    }

    fn showEdgeEditor(context: ?*anyopaque, allocator: std.mem.Allocator, initial: Forms.EdgeDraft) !?Forms.EdgeDraft {
        const self: *App = @ptrCast(@alignCast(context.?));
        return NativeForms.editEdge(self.window.hwnd, allocator, initial);
    }

    fn deleteEdge(self: *App, index: usize) void {
        const graph = self.model.graph orelse return;
        if (index >= graph.edges.items.len) return;
        const edge = graph.edges.items[index];
        if (!GraphContextMenu.canEditEdge(edge.id)) {
            self.setStatus("This graph edge has no stable delete identifier");
            return;
        }
        const project_path = self.allocator.dupe(u8, graph.project.path) catch return;
        defer self.allocator.free(project_path);
        const edge_id = self.allocator.dupe(u8, edge.id) catch return;
        defer self.allocator.free(edge_id);
        const source = if (GraphModel.findNodeIndexByID(graph.nodes.items, edge.from)) |node_index|
            graph.nodes.items[node_index].title
        else
            edge.from;
        const target = if (GraphModel.findNodeIndexByID(graph.nodes.items, edge.to)) |node_index|
            graph.nodes.items[node_index].title
        else
            edge.to;
        const message = std.fmt.allocPrint(
            self.allocator,
            "Delete the connection \"{s}\" -> \"{s}\"?\n\nThis removes the {s} graph connection. The loops themselves remain.",
            .{ source, target, edge.kind },
        ) catch return;
        defer self.allocator.free(message);
        if (!GraphContextMenu.confirm(self.window.hwnd, "Delete Edge", message)) return;
        const updated_graph = self.model.graph orelse return;
        const updated_index = GraphModel.findEdgeIndexByID(updated_graph.edges.items, edge_id) orelse return;
        self.client.sendDeleteEdge(project_path, updated_graph.edges.items[updated_index].id);
    }

    fn nodeIsDeclaredEntry(self: *const App, node_id: []const u8) bool {
        for (self.declared_entry_ids.items) |id| if (std.mem.eql(u8, id, node_id)) return true;
        return false;
    }

    fn nodeIsUnwired(self: *const App, node_id: []const u8) bool {
        const graph = self.model.graph orelse return false;
        for (graph.edges.items) |edge| {
            if (std.mem.eql(u8, edge.from, node_id) or std.mem.eql(u8, edge.to, node_id)) return false;
        }
        return !self.nodeIsDeclaredEntry(node_id);
    }

    fn markSelectedNodeAsEntry(self: *App, index: usize) void {
        const graph = self.model.graph orelse return;
        if (index >= graph.nodes.items.len) return;
        const id = graph.nodes.items[index].id;
        if (!self.nodeIsDeclaredEntry(id)) {
            const copy = self.allocator.dupe(u8, id) catch {
                self.setStatus("Unable to remember the entry loop");
                return;
            };
            self.declared_entry_ids.append(copy) catch {
                self.allocator.free(copy);
                self.setStatus("Unable to remember the entry loop");
                return;
            };
        }
        self.setStatus("Marked as an entry for this session");
    }

    fn beginWireSelectedNode(self: *App, index: usize) void {
        const graph = self.model.graph orelse return;
        if (index >= graph.nodes.items.len) return;
        if (self.edge_drag_source_id.len != 0) self.allocator.free(self.edge_drag_source_id);
        self.edge_drag_source_id = self.allocator.dupe(u8, graph.nodes.items[index].id) catch {
            self.setStatus("Unable to start edge wiring");
            return;
        };
        const bounds = GraphCanvas.nodeBounds(index, &self.canvas);
        self.canvas.beginEdgeDrag(
            self.edge_drag_source_id,
            bounds.right,
            @divTrunc(bounds.top + bounds.bottom, 2),
        );
        _ = c.SetCapture(self.window.hwnd);
        self.setStatus("Choose a target loop to wire this entry");
    }

    fn showNodeContextMenu(self: *App, index: usize, x: i32, y: i32) void {
        const graph = self.model.graph orelse return;
        if (index >= graph.nodes.items.len) return;
        self.showOwnedNodeContextMenu(graph.project.path, self.model.open_composite_id, graph.nodes.items[index].id, self.nodeIsUnwired(graph.nodes.items[index].id), x, y);
    }

    const NodeMenuContext = struct {
        app: *App,
        menu: *const NodeMenuPreparation,

        fn apply(raw: ?*anyopaque, action: GraphContextMenu.Action, target: GraphContextMenu.Target) void {
            const self: *@This() = @ptrCast(@alignCast(raw orelse return));
            if (action != .new_child_node) return self.app.handleContextAction(action, target);
            const child = self.menu.childForCreation() catch |err| {
                self.app.setStatus(nodeFormErrorStatus(err));
                return;
            };
            self.app.prepareChildNodeCreation(child) catch |err| {
                self.app.setStatus(nodeFormErrorStatus(err));
                return;
            };
            self.app.createNodeInContext(&child.context, child);
        }
    };

    const NodeMenuPreparation = struct {
        allocator: std.mem.Allocator,
        child: ?ChildNodeCreation,
        child_error: ?anyerror,
        promotion: ?SketchPromotion.Context,
        promotion_error: ?anyerror,
        target: GraphContextMenu.NodeTarget,

        fn deinit(self: *NodeMenuPreparation) void {
            if (self.child) |*child| child.deinit();
            if (self.promotion) |*promotion| promotion.deinit(self.allocator);
            self.allocator.free(self.target.project_path);
            self.allocator.free(self.target.id);
        }

        fn popupTarget(self: *const NodeMenuPreparation) GraphContextMenu.NodeTarget {
            var target = self.target;
            // Bind only after the owning preparation has moved into its caller's storage.
            if (self.promotion_error == null) {
                if (self.promotion) |*promotion| target.promotion_context = promotion;
            }
            return target;
        }

        fn promotionContextStatus(self: *const NodeMenuPreparation) ?[]const u8 {
            return if (self.promotion != null and self.promotion_error != null)
                "Sketch promotion is unavailable in this graph context."
            else
                null;
        }

        fn childForCreation(self: *const NodeMenuPreparation) !*const ChildNodeCreation {
            if (self.target.resolved) return error.NodeCreationParentResolved;
            if (self.child) |*child| return child;
            return self.child_error orelse error.NodeCreationSettingsUnavailable;
        }
    };

    fn prepareNodeMenu(self: *const App, path: []const u8, composite_id: ?[]const u8, id: []const u8, unwired: bool) !NodeMenuPreparation {
        const node = try self.childParentNode(path, composite_id, id);
        const project_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(project_path);
        const node_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(node_id);
        const resolved = isResolvedLoopState(node.state);
        var child_error: ?anyerror = null;
        const child: ?ChildNodeCreation = if (resolved) null else self.captureChildNodeCreation(path, composite_id, id) catch |err| blk: {
            child_error = err;
            break :blk null;
        };
        const sketch = std.mem.eql(u8, node.loop_type, "sketch");
        var promotion_error: ?anyerror = null;
        const promotion: ?SketchPromotion.Context = if (!sketch) null else SketchPromotion.Context.capture(
            self.allocator,
            &self.model,
            project_path,
            composite_id orelse "",
            node,
        ) catch |err| blk: {
            promotion_error = err;
            break :blk null;
        };
        if (promotion) |context| {
            if (context.selectionPlan(&self.model, self.client.subgraph_node_id)) |_| {} else |err| {
                promotion_error = err;
            }
        }
        return .{
            .allocator = self.allocator,
            .child = child,
            .child_error = child_error,
            .promotion = promotion,
            .promotion_error = promotion_error,
            .target = .{
                .project_path = project_path,
                .id = node_id,
                .composite = std.mem.eql(u8, node.loop_type, "proactive") or std.mem.eql(u8, node.loop_type, "composite"),
                .can_arm = std.mem.eql(u8, node.pilot_state, "piloted"),
                .unwired = unwired,
                .follows_template = node.follows_template,
                .resolved = resolved,
                .can_create_child = child != null,
                .sketch = sketch,
            },
        };
    }

    fn showOwnedNodeContextMenu(self: *App, path: []const u8, composite_id: ?[]const u8, id: []const u8, unwired: bool, x: i32, y: i32) void {
        var menu = self.prepareNodeMenu(path, composite_id, id, unwired) catch |err| {
            self.setStatus(if (err == error.OutOfMemory) "Unable to remember the node menu target" else nodeFormErrorStatus(err));
            return;
        };
        defer menu.deinit();
        if (menu.child_error) |err| self.setStatus(nodeFormErrorStatus(err));
        if (menu.promotion_error) |err| {
            if (menu.promotionContextStatus()) |message|
                self.setStatus(message)
            else
                self.setPromotionError(err);
        }
        var callback = NodeMenuContext{ .app = self, .menu = &menu };
        GraphContextMenu.show(
            self.window.hwnd,
            .{ .node = menu.popupTarget() },
            x,
            y,
            &callback,
            &NodeMenuContext.apply,
        );
    }

    fn showBackgroundContextMenu(self: *App, x: i32, y: i32) void {
        const graph = self.model.graph orelse return;
        const project_path = self.allocator.dupe(u8, graph.project.path) catch {
            self.setStatus("Unable to open the project canvas menu");
            return;
        };
        defer self.allocator.free(project_path);
        GraphContextMenu.show(
            self.window.hwnd,
            .{ .background = .{
                .project_path = project_path,
                .local_filesystem = graph.project.isLocalFilesystem(),
                .can_create_edge = graph.nodes.items.len >= 2,
                .worktrees_available = !self.worktreeProviderBusy(),
            } },
            x,
            y,
            self,
            &onContextAction,
        );
    }

    fn showEdgeContextMenu(self: *App, index: usize, x: i32, y: i32) void {
        const graph = self.model.graph orelse return;
        if (index >= graph.edges.items.len) return;
        const project_path = self.allocator.dupe(u8, graph.project.path) catch return;
        defer self.allocator.free(project_path);
        const edge_id = self.allocator.dupe(u8, graph.edges.items[index].id) catch return;
        defer self.allocator.free(edge_id);
        GraphContextMenu.show(
            self.window.hwnd,
            .{ .edge = .{ .project_path = project_path, .id = edge_id } },
            x,
            y,
            self,
            &onContextAction,
        );
    }

    fn showQuickChatContextMenu(self: *App, index: usize, x: i32, y: i32) void {
        if (index >= self.model.quick_chats.items.len) return;
        const id = self.allocator.dupe(u8, self.model.quick_chats.items[index].id) catch return;
        defer self.allocator.free(id);
        GraphContextMenu.show(
            self.window.hwnd,
            .{ .quick_chat = .{ .id = id } },
            x,
            y,
            self,
            &onContextAction,
        );
    }

    /// Gate-only hook that opens a real native context menu so the live UIA
    /// gate can inspect what `TrackPopupMenu` actually renders. It calls the
    /// same `GraphContextMenu.show()` the mouse path calls with the same
    /// target data; only hit-test routing is bypassed. A watchdog timer ends
    /// the menu if the harness never dismisses it, so a wedged popup can never
    /// block the shell thread for the life of the process.
    fn showUiaContextMenu(self: *App, target_kind: c.WPARAM) void {
        if (!envFlag("GRAPHCODE_UIA_GATE")) return;
        const hwnd = self.window.hwnd;
        _ = c.SetTimer(
            hwnd,
            MainWindow.menu_watchdog_timer_id,
            MainWindow.menu_watchdog_interval_ms,
            null,
        );
        defer _ = c.KillTimer(hwnd, MainWindow.menu_watchdog_timer_id);
        const target: GraphContextMenu.Target = switch (target_kind) {
            1 => .{ .project = .{ .path = self.requiredUiaFixtureProject() catch |err| {
                self.reportWorktreeError("UIA fixture owner unavailable", err);
                return;
            }, .remote = false, .worktrees_available = !self.worktreeProviderBusy() } },
            2 => .{ .project = .{ .path = uia_context_menu_remote_project_path, .remote = true, .worktrees_available = !self.worktreeProviderBusy() } },
            3 => return self.showNodeContextMenu(0, uia_context_menu_x, uia_context_menu_y),
            4 => return self.showBackgroundContextMenu(uia_context_menu_x, uia_context_menu_y),
            5 => .quick_chats,
            // Sidebar-parity-only targets: expose the composite and unwired
            // loop-menu variants that target 3 (the plain wired first node)
            // cannot reach, so the live gate can assert every menu shape
            // GraphContextMenu.show() renders for a `.node` target.
            6 => return self.showNodeContextMenu(1, uia_context_menu_x, uia_context_menu_y),
            7 => {
                const graph = self.model.graph orelse return;
                const index = GraphModel.findNodeIndexByID(
                    graph.nodes.items,
                    "77777777-7777-4777-8777-777777777777",
                ) orelse return;
                return self.showNodeContextMenu(index, uia_context_menu_x, uia_context_menu_y);
            },
            else => return,
        };
        GraphContextMenu.show(
            hwnd,
            target,
            uia_context_menu_x,
            uia_context_menu_y,
            self,
            &onContextAction,
        );
    }

    /// Gate-only hook that presents a real native modal form with deterministic
    /// fixture data, bypassing the preconditions and `GRAPHCODE_UIA_SHOW_DIALOGS`
    /// suppression that guard the equivalent real user flows. `form_kind`
    /// selects which form: 1 = edge creation, 2 = worktree policy/project
    /// settings, 3 = worktree sweep. Real user-facing behavior is unaffected
    /// because this path only runs under `GRAPHCODE_UIA_GATE`.
    ///
    /// A watchdog timer mirrors the one `showUiaContextMenu` sets around
    /// `TrackPopupMenu`: these forms run their own blocking message loop
    /// (`NativeForms.show`), so if the harness never dismisses one, the
    /// watchdog force-closes it (posting the same `WM_CLOSE` a Cancel/close-box
    /// click would send) rather than wedging the shell thread for the life of
    /// the process. It only closes a form that outlived the interval; it never
    /// fabricates or shortcuts a passing assertion, so the gate still fails
    /// honestly if the expected form never appeared at all.
    fn presentUiaForm(self: *App, form_kind: c.WPARAM) void {
        if (!envFlag("GRAPHCODE_UIA_GATE")) return;
        if (form_kind < 1 or form_kind > 3) return;
        _ = c.SetTimer(
            self.window.hwnd,
            MainWindow.menu_watchdog_timer_id,
            MainWindow.menu_watchdog_interval_ms,
            null,
        );
        switch (form_kind) {
            1 => self.presentUiaEdgeForm(),
            2 => self.presentUiaWorktreePolicyForm(),
            3 => self.presentUiaWorktreeSweepForm(),
            else => unreachable,
        }
        _ = c.KillTimer(self.window.hwnd, MainWindow.menu_watchdog_timer_id);
    }

    /// Force-dismisses a `NativeForms` window left open past the watchdog
    /// interval by posting `WM_CLOSE`, the same message its Cancel/close-box
    /// path sends; `NativeForms.zig`'s own `WM_CLOSE` handler treats that as a
    /// cancellation, so this cannot turn a missing form into a fabricated
    /// success. `"GraphCodeNativeForm"` is `NativeForms.zig`'s private window
    /// class name, mirrored here rather than exported since only the class
    /// identity (not any internal state) is needed to find the window.
    ///
    /// Scoped to the *current thread's* windows via `EnumThreadWindows` rather
    /// than the system-wide `FindWindowW`: the live gate runs multiple shell
    /// instances at once (workspace-lifecycle switch/create, fixture shells),
    /// and a system-wide search could post `WM_CLOSE` to a form belonging to a
    /// different process, cancelling work another part of the gate is mid-way
    /// through asserting against. `presentUiaForm` runs on this window's
    /// message-loop thread and `NativeForms.show` blocks that same thread, so
    /// the form is always created on the thread that armed the watchdog.
    fn dismissWedgedUiaForm() void {
        _ = c.EnumThreadWindows(c.GetCurrentThreadId(), dismissWedgedUiaFormCallback, 0);
    }

    fn dismissWedgedUiaFormCallback(hwnd: c.HWND, lparam: c.LPARAM) callconv(.winapi) c.BOOL {
        _ = lparam;
        var class_buffer: [64]u16 = undefined;
        const len: usize = @intCast(c.GetClassNameW(hwnd, &class_buffer, class_buffer.len));
        const form_class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeNativeForm");
        if (len == form_class_name.len and std.mem.eql(u16, class_buffer[0..len], form_class_name)) {
            _ = c.PostMessageW(hwnd, c.WM_CLOSE, 0, 0);
        }
        return 1;
    }

    fn ensureUiaFixtureProject(self: *App, min_nodes: usize) bool {
        const needs_project = self.model.graph == null;
        const needs_nodes = if (self.model.graph) |graph| graph.nodes.items.len < min_nodes else true;
        if (!needs_project and !needs_nodes) return true;
        self.applyUiaFixtureGraph(.project, "Fixture project", 63,
            \\[{"id":"uia-form-source","title":"Planner","state":"idle"},{"id":"uia-form-target","title":"Builder","state":"idle"}]
        , "[]") catch |err| {
            self.reportWorktreeError("Unable to prepare UIA fixture project", err);
            return false;
        };
        self.surface = .project;
        return true;
    }

    fn presentUiaEdgeForm(self: *App) void {
        if (!self.ensureUiaFixtureProject(2)) return;
        self.createEdge();
    }

    fn presentUiaWorktreePolicyForm(self: *App) void {
        if (!self.ensureUiaFixtureProject(0)) return;
        const project_path = self.currentProject() orelse return;
        const initial = if (self.worktree_dialog) |dialog|
            dialog.policy
        else
            WorktreeStatus.loadPolicy(self.allocator, project_path);
        const policy = NativeForms.worktreePolicy(self.window.hwnd, self.allocator, project_path, initial) catch {
            self.setStatus("Unable to open worktree policy editor");
            return;
        } orelse {
            self.setStatus("Worktree policy edit cancelled");
            return;
        };
        if (self.worktree_dialog) |*dialog| dialog.setPolicy(policy);
        self.setStatus("Project settings updated");
    }

    fn presentUiaWorktreeSweepForm(self: *App) void {
        if (!self.ensureUiaFixtureProject(0)) return;
        const graph = self.model.graph orelse return;
        if (self.worktree_inspection == null) {
            var entries = std.array_list.Managed(WorktreeStatus.Entry).init(self.allocator);
            entries.append(.{
                .path = self.ownedUiaFixturePath(.sweep_safe) catch |err| {
                    self.reportWorktreeError("UIA fixture owner unavailable", err);
                    return;
                },
                .branch = self.allocator.dupe(u8, "uia-fixture-reclaimable") catch return,
                .size_bytes = 1024,
                .size_complete = true,
                .pushed = true,
                .landed = true,
            }) catch return;
            entries.append(.{
                .path = self.ownedUiaFixturePath(.sweep_unsafe) catch |err| {
                    self.reportWorktreeError("UIA fixture owner unavailable", err);
                    return;
                },
                .branch = self.allocator.dupe(u8, "uia-fixture-dirty") catch return,
                .size_bytes = 2048,
                .size_complete = true,
                .dirty = true,
            }) catch return;
            self.worktree_inspection = .{
                .entries = entries,
                .default_branch = self.allocator.dupe(u8, "main") catch return,
                .project_path = self.allocator.dupe(u8, graph.project.path) catch return,
            };
        }
        self.presentWorktreeSweep();
    }

    fn handleContextAction(self: *App, action: GraphContextMenu.Action, target: GraphContextMenu.Target) void {
        switch (target) {
            .project => |stable| {
                const selected = self.selectProject(stable.path);
                if (selected) {
                    self.surface = .project;
                    self.workspace_controls.panel_visible = false;
                    self.layoutWorkspace();
                    self.layoutEmptyStateControls();
                }
                switch (action) {
                    .open_project => if (!selected) self.openProject(stable.path),
                    .new_project_loop => if (selected)
                        self.createNode()
                    else {
                        self.openProject(stable.path);
                        self.setStatus("Opening project; create a loop when loading completes");
                    },
                    .inspect_project_worktrees => if (selected) self.inspectWorktrees() else self.setStatus("Open the project before inspecting worktrees"),
                    .project_settings => if (selected) self.editWorktreePolicy() else self.setStatus("Open the project before changing project settings"),
                    .reveal_project => self.revealProjectPath(stable.path),
                    .remote_project_info => self.showRemoteProjectInfo(stable.path),
                    .close_project => {
                        self.client.sendCloseProject(stable.path);
                        self.setStatus("Closing project...");
                    },
                    .remove_project => {
                        if (!GraphContextMenu.confirm(
                            self.window.hwnd,
                            "Remove Project",
                            "Remove this project from GraphCode?\n\nThe folder and its files remain on disk. You can add it again later.",
                        )) return;
                        self.client.sendForgetProject(stable.path);
                        self.setStatus("Removing project from GraphCode...");
                    },
                    .move_project => self.setStatus(Wire.project_relocation_unavailable_reason),
                    .trash_project => {
                        if (stable.remote) return;
                        if (!GraphContextMenu.confirm(
                            self.window.hwnd,
                            "Move Project to Recycle Bin",
                            "Move this project folder to the Windows Recycle Bin?\n\nIts files will be removed from the filesystem but can be restored from the Recycle Bin. The project will also be removed from GraphCode.",
                        )) return;
                        self.trashProjectPath(stable.path);
                    },
                    .delete_project_loops => {
                        self.deleteProjectLoops(stable.path);
                    },
                    else => {},
                }
            },
            .node => |stable| {
                if (GraphContextMenu.promotionTarget(action)) |target_type| {
                    self.promoteSketch(stable, target_type);
                    return;
                }
                const already_active = if (self.model.graph) |active|
                    std.mem.eql(u8, active.project.path, stable.project_path)
                else
                    false;
                if (!already_active and !self.selectProject(stable.project_path)) return;
                const graph = self.model.graph orelse return;
                const index = GraphModel.findNodeIndexByID(graph.nodes.items, stable.id) orelse return;
                if (!self.selectNodeIndex(index)) return;
                switch (action) {
                    .edit_node => self.editSelectedNodeDetails(),
                    .rename_node => self.editSelectedNode(),
                    .stop_node => self.stopSelectedNode(),
                    .delete_node => self.deleteSelectedNode(),
                    .open_terminal => self.openSelectedNode(),
                    .message_node => self.sendSelectedNode(),
                    .memo_node => self.sendSelectedNode(),
                    .open_composite => self.showCompositeGroup(graph.nodes.items[index]),
                    .pilot_composite => {
                        self.client.sendPilotComposite(graph.project.path, graph.nodes.items[index].id);
                        self.setStatus("Piloting composite once...");
                    },
                    .arm_composite => {
                        if (std.mem.eql(u8, graph.nodes.items[index].pilot_state, "piloted")) {
                            self.client.sendArmComposite(graph.project.path, graph.nodes.items[index].id);
                            self.setStatus("Arming composite schedule...");
                        } else {
                            self.setStatus("Pilot this composite successfully before arming it");
                        }
                    },
                    .wire_node => self.beginWireSelectedNode(index),
                    .mark_entry => self.markSelectedNodeAsEntry(index),
                    .detach_template => {
                        self.client.sendDetachTemplate(graph.project.path, graph.nodes.items[index].id);
                        self.setStatus("Detached loop from its template");
                    },
                    .save_node_template => self.saveSelectedNodeAsTemplate(index),
                    else => {},
                }
            },
            .edge => |stable| {
                const graph = self.model.graph orelse return;
                if (!std.mem.eql(u8, graph.project.path, stable.project_path)) return;
                if (stable.id.len == 0) return;
                const index = GraphModel.findEdgeIndexByID(graph.edges.items, stable.id) orelse return;
                if (!self.selectEdgeIndex(index)) return;
                switch (action) {
                    .edit_edge => self.editSelectedEdge(index),
                    .delete_edge => self.deleteEdge(index),
                    else => {},
                }
            },
            .quick_chat => |stable| {
                var index: usize = 0;
                while (index < self.model.quick_chats.items.len and
                    !std.mem.eql(u8, self.model.quick_chats.items[index].id, stable.id)) : (index += 1)
                {}
                if (index >= self.model.quick_chats.items.len) return;
                self.selected_quick_chat = index;
                switch (action) {
                    .open_quick_chat => {
                        self.client.sendOpenQuickChat(stable.id);
                        self.setStatus("Opening quick chat...");
                    },
                    .rename_quick_chat => self.renameSelectedQuickChat(),
                    .delete_quick_chat => self.deleteSelectedQuickChat(),
                    else => {},
                }
            },
            .background => |stable| {
                const already_active = if (self.model.graph) |active|
                    std.mem.eql(u8, active.project.path, stable.project_path)
                else
                    false;
                if (!already_active and !self.selectProject(stable.project_path)) {
                    self.setStatus("Project changed while the canvas menu was open");
                    return;
                }
                const graph = self.model.graph orelse return;
                switch (action) {
                    .create_edge => if (graph.nodes.items.len >= 2) self.createEdge() else self.setStatus("Create Edge requires two loops"),
                    .inspect_project_worktrees => if (graph.project.isLocalFilesystem()) self.inspectWorktrees() else self.setStatus("Worktrees require a local filesystem project"),
                    .project_settings => if (graph.project.isLocalFilesystem()) self.editWorktreePolicy() else self.setStatus("Project settings require a local filesystem project"),
                    .reveal_project => if (graph.project.isLocalFilesystem()) self.revealProjectPath(stable.project_path) else self.setStatus("Explorer requires a local filesystem project"),
                    else => {},
                }
            },
            .quick_chats => if (action == .new_quick_chat) self.createQuickChat(),
        }
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
    }

    fn saveSelectedNodeAsTemplate(self: *App, index: usize) void {
        const graph = self.model.graph orelse return;
        if (index >= graph.nodes.items.len) return;
        var result = NativeDialogs.textWithDescription(
            self.window.hwnd,
            self.allocator,
            "Save as Template",
            "Name this reusable prompt template. It is stored in your per-user GraphCode library.",
            &.{"Template name"},
            &.{graph.nodes.items[index].title},
        ) catch {
            self.setStatus("Unable to open template save form");
            return;
        } orelse return;
        defer result.deinit(self.allocator);
        const node = graph.nodes.items[index];
        const draft = Forms.NodeDraft{
            .title = self.allocator.dupe(u8, node.title) catch return,
            .loop_type = self.allocator.dupe(u8, node.loop_type) catch return,
            .first_instruction = self.allocator.dupe(u8, if (node.trigger_prompt.len != 0) node.trigger_prompt else node.check_description) catch return,
            .goal_summary = self.allocator.dupe(u8, node.goal_summary) catch return,
            .trigger_prompt = self.allocator.dupe(u8, node.trigger_prompt) catch return,
            .claude_permissions = "",
            .copilot_permissions = "",
        };
        defer {
            self.allocator.free(draft.title);
            self.allocator.free(draft.loop_type);
            self.allocator.free(draft.first_instruction);
            self.allocator.free(draft.goal_summary);
            self.allocator.free(draft.trigger_prompt);
        }
        var template = TemplateLibrary.fromDraft(self.allocator, result.values[0], draft) catch {
            self.setStatus("A template needs a name and prompt");
            return;
        };
        defer template.deinit(self.allocator);
        TemplateLibrary.save(self.allocator, template) catch {
            self.setStatus("Unable to save template");
            return;
        };
        self.setStatus("Saved reusable template");
    }

    fn showCompositeGroup(self: *App, node: GraphModel.Node) void {
        const node_id = self.allocator.dupe(u8, node.id) catch return;
        defer self.allocator.free(node_id);
        if (!self.model.openComposite(node_id)) {
            self.setStatus("Unable to open composite group");
            return;
        }
        self.client.setSubgraphAddress(node_id);
        self.clearEdgeSelection();
        self.canvas.actualSize();
        self.setStatus("Composite group opened · use the breadcrumb to return");
        self.syncAccessibility();
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
    }

    fn closeCompositeGroup(self: *App) void {
        if (!self.model.isCompositeOpen()) return;
        self.model.closeComposite();
        self.client.setSubgraphAddress(null);
        self.clearEdgeSelection();
        self.canvas.actualSize();
        self.setStatus("Returned to project graph");
        self.syncAccessibility();
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
    }

    fn launchExplorer(self: *App, path: []const u8, success_status: []const u8) void {
        const parameters = WorktreeStatus.explorerParameters(self.allocator, path) catch {
            self.setStatus("Unable to prepare Explorer");
            return;
        };
        defer self.allocator.free(parameters);
        if (std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_UIA_SHELL_EXECUTE_LOG")) |log_path| {
            defer self.allocator.free(log_path);
            const payload = std.fmt.allocPrint(self.allocator, "verb=open\nfile=explorer.exe\nparameters={s}\n", .{parameters}) catch {
                self.setStatus("Unable to record Explorer request");
                return;
            };
            defer self.allocator.free(payload);
            var file = std.fs.createFileAbsolute(log_path, .{ .truncate = true }) catch {
                self.setStatus("Unable to record Explorer request");
                return;
            };
            defer file.close();
            file.writeAll(payload) catch {
                self.setStatus("Unable to record Explorer request");
                return;
            };
            self.setStatus(success_status);
            return;
        } else |_| {}
        const wide_raw = std.unicode.utf8ToUtf16LeAlloc(self.allocator, parameters) catch {
            self.setStatus("Unable to encode Explorer path");
            return;
        };
        defer self.allocator.free(wide_raw);
        const wide = self.allocator.alloc(u16, wide_raw.len + 1) catch return;
        defer self.allocator.free(wide);
        @memcpy(wide[0..wide_raw.len], wide_raw);
        wide[wide_raw.len] = 0;
        const result = c.ShellExecuteW(
            self.window.hwnd,
            std.unicode.utf8ToUtf16LeStringLiteral("open").ptr,
            std.unicode.utf8ToUtf16LeStringLiteral("explorer.exe").ptr,
            wide.ptr,
            null,
            c.SW_SHOWNORMAL,
        );
        self.setStatus(if (@intFromPtr(result) <= 32) "Unable to open Explorer" else success_status);
    }

    fn revealProjectPath(self: *App, path: []const u8) void {
        self.launchExplorer(path, "Opened project in Explorer");
    }

    fn trashProjectPath(self: *App, path: []const u8) void {
        const raw = std.unicode.utf8ToUtf16LeAlloc(self.allocator, path) catch {
            self.setStatus("Unable to encode project path");
            return;
        };
        defer self.allocator.free(raw);
        const from = self.allocator.alloc(u16, raw.len + 2) catch return;
        defer self.allocator.free(from);
        @memcpy(from[0..raw.len], raw);
        from[raw.len] = 0;
        from[raw.len + 1] = 0;
        var operation: c.SHFILEOPSTRUCTW = .{
            .hwnd = self.window.hwnd,
            .wFunc = c.FO_DELETE,
            .pFrom = from.ptr,
            .pTo = null,
            .fFlags = c.FOF_ALLOWUNDO | c.FOF_NOCONFIRMATION | c.FOF_SILENT,
            .fAnyOperationsAborted = 0,
            .hNameMappings = null,
            .lpszProgressTitle = null,
        };
        if (c.SHFileOperationW(&operation) != 0 or operation.fAnyOperationsAborted != 0) {
            self.setStatus("Project was not moved to the Recycle Bin");
            return;
        }
        self.client.sendForgetProject(path);
        self.setStatus("Project moved to the Recycle Bin");
    }

    fn showRemoteProjectInfo(self: *App, path: []const u8) void {
        const message = std.fmt.allocPrint(
            self.allocator,
            "Remote project\n\n{s}\n\nThe SSH connection is managed by GraphCode and can be changed by removing and adding the remote project again.",
            .{path},
        ) catch return;
        defer self.allocator.free(message);
        const message_wide = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, message) catch return;
        defer self.allocator.free(message_wide);
        _ = c.MessageBoxW(
            self.window.hwnd,
            message_wide.ptr,
            std.unicode.utf8ToUtf16LeStringLiteral("Remote Connection").ptr,
            c.MB_OK | c.MB_ICONINFORMATION,
        );
    }

    fn deleteProjectLoops(self: *App, path: []const u8) void {
        if (!GraphContextMenu.confirm(
            self.window.hwnd,
            "Delete All Loops",
            "Delete every loop and graph connection for this project?\n\nThe project files remain on disk. This graph action cannot be undone.",
        )) return;
        self.client.sendDeleteProjectGraph(path);
        self.setStatus("Deleting project loops...");
    }

    fn showAbout(self: *App) void {
        const message = std.fmt.allocPrint(
            self.allocator,
            "GraphCode for Windows\nVersion {s}\n\nVisualize and orchestrate parallel coding-agent work.",
            .{build_options.version},
        ) catch return;
        defer self.allocator.free(message);
        const message_wide = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, message) catch return;
        defer self.allocator.free(message_wide);
        _ = c.MessageBoxW(
            self.window.hwnd,
            message_wide.ptr,
            std.unicode.utf8ToUtf16LeStringLiteral("About GraphCode").ptr,
            c.MB_OK | c.MB_ICONINFORMATION,
        );
    }

    fn inspectWorktrees(self: *App) void {
        if (envFlag("GRAPHCODE_UIA_GATE") and envFlag("GRAPHCODE_UIA_SHOW_DIALOGS") and self.worktree_inspection != null) {
            self.presentWorktreeSweep();
            return;
        }
        self.inspectWorktreesImpl(true);
    }

    fn isLocalGitRepository(self: *const App, project_path: []const u8) bool {
        const marker = std.fs.path.join(self.allocator, &.{ project_path, ".git" }) catch return false;
        defer self.allocator.free(marker);
        const wide = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, marker) catch return false;
        defer self.allocator.free(wide);
        return c.GetFileAttributesW(wide.ptr) != c.INVALID_FILE_ATTRIBUTES;
    }

    fn acceptWorktreeInspection(self: *App, inspection: WorktreeStatus.Inspection, policy: WorktreeStatus.PolicyOutcome) !void {
        var dialog = try WorktreeDialog.Dialog.init(
            self.allocator,
            inspection.project_path,
            inspection.entries.items,
            policy.value() orelse .{},
        );
        errdefer dialog.deinit();
        try self.model.recordWorktreeInspection(&inspection, policy);
        if (self.worktree_dialog) |*old| old.deinit();
        if (self.worktree_inspection) |*old| WorktreeStatus.deinitInspection(self.allocator, old);
        if (self.selected_worktree_path.len != 0) self.allocator.free(self.selected_worktree_path);
        self.selected_worktree_path = &.{};
        self.reclaim_confirmation_armed = false;
        self.worktree_inspection = inspection;
        self.worktree_dialog = dialog;
    }

    fn reportWorktreeError(self: *App, context: []const u8, failure: anyerror) void {
        const message = std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ context, @errorName(failure) }) catch {
            self.setStatus(context);
            return;
        };
        defer self.allocator.free(message);
        self.setStatus(message);
    }

    fn recordWorktreeInspectionFailure(self: *App, project_path: []const u8, failure: anyerror) void {
        self.model.recordWorktreeFailure(project_path, failure) catch |err| {
            self.reportWorktreeError("Worktree inspection owner unavailable", err);
            return;
        };
        const state = std.fmt.allocPrint(
            self.allocator,
            "Worktree inspection failed: {s}. Check repository access and retry.",
            .{@errorName(failure)},
        ) catch null;
        if (state) |message| {
            defer self.allocator.free(message);
            self.setWorktreeStateWithReceipts(message);
        }
        self.reportWorktreeError("Worktree inspection failed", failure);
    }

    fn inspectWorktreesImpl(self: *App, show_sweep: bool) void {
        const current_graph = self.model.graph orelse {
            self.setStatus("Worktrees require a local filesystem project");
            return;
        };
        if (current_graph.project.isGlobal()) {
            self.setStatus("The global graph has no repository worktrees");
            return;
        }
        if (current_graph.project.path.len == 0) {
            self.setStatus("No project selected for worktree inspection");
            return;
        }
        var bindings = std.array_list.Managed(WorktreeStatus.Binding).init(self.allocator);
        defer bindings.deinit();
        if (self.model.graph) |graph| {
            for (graph.nodes.items) |node| {
                if (node.worktree_path.len != 0) bindings.append(.{ .path = node.worktree_path }) catch |err| {
                    self.recordWorktreeInspectionFailure(current_graph.project.path, err);
                    return;
                };
            }
        }
        self.queueWorktreeInspection(current_graph.project.path, bindings.items, show_sweep) catch |err| {
            self.recordWorktreeInspectionFailure(current_graph.project.path, err);
        };
    }

    fn createWorktreeInspectionRequest(
        self: *App,
        generation: u64,
        project_path: []const u8,
        bindings: []const WorktreeStatus.Binding,
        show_sweep: bool,
    ) !*WorktreeInspectionRequest {
        const request = try self.allocator.create(WorktreeInspectionRequest);
        errdefer self.allocator.destroy(request);
        request.* = .{
            .generation = generation,
            .project_path = try self.allocator.dupe(u8, project_path),
            .bindings = &.{},
            .show_sweep = show_sweep,
            .runner = self.worktree_inspect_runner,
        };
        errdefer self.allocator.free(request.project_path);
        request.bindings = try self.allocator.alloc(WorktreeStatus.Binding, bindings.len);
        errdefer self.allocator.free(request.bindings);
        var initialized: usize = 0;
        errdefer for (request.bindings[0..initialized]) |binding| self.allocator.free(binding.path);
        for (bindings, 0..) |binding, index| {
            request.bindings[index] = .{ .path = try self.allocator.dupe(u8, binding.path) };
            initialized += 1;
        }
        return request;
    }

    fn queueWorktreeInspection(
        self: *App,
        project_path: []const u8,
        bindings: []const WorktreeStatus.Binding,
        show_sweep: bool,
    ) !void {
        self.worktree_inspection_generation += 1;
        self.worktree_inspection_cancellation.store(self.worktree_inspection_generation, .release);
        const request = try self.createWorktreeInspectionRequest(
            self.worktree_inspection_generation,
            project_path,
            bindings,
            show_sweep,
        );
        if (self.worktree_inspection_pending) |pending| pending.deinit(self.allocator);
        self.worktree_inspection_pending = request;
        if (self.worktree_loading_path.len != 0) self.allocator.free(self.worktree_loading_path);
        self.worktree_loading_path = try self.allocator.dupe(u8, project_path);
        self.worktree_inspection_attempt_count += 1;
        self.setWorktreeState("Reading worktrees...");
        self.setStatus("Reading worktrees...");
        self.launchPendingWorktreeInspection();
    }

    fn launchPendingWorktreeInspection(self: *App) void {
        if (self.worktree_inspection_thread != null) return;
        const request = self.worktree_inspection_pending orelse return;
        self.worktree_inspection_pending = null;
        self.worktree_inspection_done = false;
        self.worktree_inspection_thread = std.Thread.spawn(
            .{},
            worktreeInspectionWorker,
            .{ self, request },
        ) catch {
            request.deinit(self.allocator);
            self.worktree_inspection_done = true;
            self.setStatus("Worktree inspection could not start");
            return;
        };
    }

    fn worktreeInspectionWorker(self: *App, request: *WorktreeInspectionRequest) void {
        const cancellation = WorktreeStatus.Cancellation{
            .generation = &self.worktree_inspection_cancellation,
            .expected = request.generation,
        };
        var inspection = request.runner(
            self.allocator,
            request.project_path,
            request.bindings,
            cancellation,
        ) catch |err| {
            self.publishWorktreeInspectionResult(.{
                .generation = request.generation,
                .project_path = self.allocator.dupe(u8, request.project_path) catch {
                    request.deinit(self.allocator);
                    return;
                },
                .show_sweep = false,
                .outcome = .{ .failed = err },
            });
            request.deinit(self.allocator);
            self.worktree_inspection_lock.lock();
            self.worktree_inspection_done = true;
            self.worktree_inspection_lock.unlock();
            return;
        };
        var size_paths: std.ArrayList([]u8) = .empty;
        defer {
            for (size_paths.items) |path| self.allocator.free(path);
            size_paths.deinit(self.allocator);
        }
        for (inspection.entries.items) |entry| {
            if (entry.opened_checkout or entry.prunable) continue;
            size_paths.append(self.allocator, self.allocator.dupe(u8, entry.path) catch continue) catch {};
        }
        const project_path = self.allocator.dupe(u8, request.project_path) catch {
            WorktreeStatus.deinitInspection(self.allocator, &inspection);
            request.deinit(self.allocator);
            return;
        };
        self.publishWorktreeInspectionResult(.{
            .generation = request.generation,
            .project_path = project_path,
            .show_sweep = request.show_sweep,
            .outcome = .{ .discovered = .{
                .inspection = inspection,
                .policy = if (std.mem.startsWith(u8, request.project_path, "ssh://") or
                    std.mem.startsWith(u8, request.project_path, "codespace://"))
                    .{ .known = .{ .policy = .{}, .source = .missing } }
                else
                    WorktreeStatus.loadPolicyOutcome(self.allocator, request.project_path),
            } },
        });
        for (size_paths.items) |path| {
            if (cancellation.cancelled()) break;
            const update_path = self.allocator.dupe(u8, path) catch continue;
            self.publishWorktreeInspectionResult(.{
                .generation = request.generation,
                .project_path = self.allocator.dupe(u8, request.project_path) catch {
                    self.allocator.free(update_path);
                    continue;
                },
                .show_sweep = request.show_sweep,
                .outcome = .{ .sized = .{
                    .path = update_path,
                    .size = self.worktree_size_runner(self.allocator, request.project_path, path, cancellation),
                } },
            });
        }
        if (self.allocator.dupe(u8, request.project_path)) |finished_path| {
            self.publishWorktreeInspectionResult(.{
                .generation = request.generation,
                .project_path = finished_path,
                .show_sweep = request.show_sweep,
                .outcome = .finished,
            });
        } else |_| {}
        request.deinit(self.allocator);
        self.worktree_inspection_lock.lock();
        self.worktree_inspection_done = true;
        self.worktree_inspection_lock.unlock();
    }

    fn publishWorktreeInspectionResult(self: *App, result: WorktreeInspectionResult) void {
        self.worktree_inspection_lock.lock();
        defer self.worktree_inspection_lock.unlock();
        self.worktree_inspection_results.append(self.allocator, result) catch {
            var discarded = result;
            discarded.deinit(self.allocator);
        };
    }

    fn finishWorktreeInspection(self: *App) void {
        self.worktree_inspection_lock.lock();
        const done = self.worktree_inspection_done;
        var results = self.worktree_inspection_results;
        self.worktree_inspection_results = .empty;
        self.worktree_inspection_lock.unlock();
        if (done) {
            if (self.worktree_inspection_thread) |thread| thread.join();
            self.worktree_inspection_thread = null;
        }
        defer results.deinit(self.allocator);
        var show_sweep = false;
        for (results.items) |*completed| {
            defer completed.deinit(self.allocator);
            if (completed.generation == self.worktree_inspection_generation) {
                show_sweep = show_sweep or completed.show_sweep;
                self.applyWorktreeInspectionResult(completed);
            }
        }
        if (!done) return;
        self.worktree_inspection_lock.lock();
        self.worktree_inspection_done = false;
        self.worktree_inspection_lock.unlock();
        if (self.worktree_inspection_pending == null and self.worktree_loading_path.len != 0) {
            self.allocator.free(self.worktree_loading_path);
            self.worktree_loading_path = &.{};
        }
        self.launchPendingWorktreeInspection();
        if (show_sweep and !envFlag("GRAPHCODE_UIA_GATE")) {
            if (self.worktree_inspection) |inspection| {
                if (inspection.entries.items.len != 0) self.presentWorktreeSweep();
            }
        }
    }

    fn applyWorktreeInspectionResult(self: *App, result: *WorktreeInspectionResult) void {
        const current = self.model.currentGraph() orelse return;
        if (!std.mem.eql(u8, current.project.path, result.project_path)) return;
        switch (result.outcome) {
            .failed => |err| {
                self.recordWorktreeInspectionFailure(result.project_path, err);
                return;
            },
            .discovered => |*value| {
                self.acceptWorktreeInspection(value.inspection, value.policy) catch |err| {
                    self.recordWorktreeInspectionFailure(result.project_path, err);
                    return;
                };
                value.inspection.entries = std.array_list.Managed(WorktreeStatus.Entry).init(self.allocator);
                value.inspection.default_branch = &.{};
                value.inspection.project_path = &.{};
                if (self.worktree_inspection) |inspection| {
                    if (inspection.entries.items.len == 0)
                        self.setWorktreeStateWithReceipts("No linked worktrees in this repository.")
                    else
                        self.setWorktreeState("Worktrees found. Calculating sizes...");
                }
            },
            .sized => |value| {
                self.applyWorktreeSize(result.project_path, value.path, value.size);
                return;
            },
            .finished => {
                self.finishWorktreeSizing(result.project_path);
                return;
            },
        }
        const record = self.model.graphFor(result.project_path) orelse {
            self.setStatus("Worktree inspection project closed before results arrived");
            return;
        };
        const notice = record.worktree_notice orelse {
            self.setStatus("Worktree inspection result could not be published");
            return;
        };
        self.clampSidebarScroll();
        const summary = notice.observation.?.summary;
        const message = if (summary.total == 0)
            self.allocator.dupe(u8, "No linked worktrees in this repository.") catch return
        else if (notice.policy.value() == null or !notice.observation.?.size.complete)
            WorktreeStatus.NoticePresentation.fromRecord(notice).?.label(self.allocator) catch {
                self.setStatus("Worktree inspection has unavailable size or policy");
                return;
            }
        else
            std.fmt.allocPrint(
                self.allocator,
                "Worktrees: {d} total · {d} reclaimable · {d} blocked",
                .{ summary.total, summary.reclaimable, summary.blocked },
            ) catch {
                self.setStatus("Unable to format worktree inspection");
                return;
            };
        self.replaceStatus(message);
    }

    fn applyWorktreeSize(
        self: *App,
        project_path: []const u8,
        worktree_path: []const u8,
        size: WorktreeStatus.SizeCoverage,
    ) void {
        const inspection = if (self.worktree_inspection) |*value| value else return;
        if (!std.mem.eql(u8, inspection.project_path, project_path)) return;
        for (inspection.entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.path, worktree_path)) continue;
            entry.size_bytes = size.bytes;
            entry.size_complete = size.complete;
            entry.size_error = size.first_error;
            break;
        } else return;
        if (self.worktree_dialog) |*dialog| {
            if (std.mem.eql(u8, dialog.project_path, project_path)) {
                for (dialog.rows.items) |*row| {
                    if (!std.mem.eql(u8, row.entry.path, worktree_path)) continue;
                    row.entry.size_bytes = size.bytes;
                    row.entry.size_complete = size.complete;
                    row.entry.size_error = size.first_error;
                    break;
                }
            }
        }
        const policy: WorktreeStatus.PolicyOutcome = if (self.worktree_dialog) |dialog|
            .{ .known = .{ .policy = dialog.policy, .source = .configured } }
        else
            WorktreeStatus.loadPolicyOutcome(self.allocator, project_path);
        self.model.recordWorktreeInspection(inspection, policy) catch return;
        const measured = WorktreeStatus.sizeCoverageText(self.allocator, size) catch return;
        defer self.allocator.free(measured);
        const message = std.fmt.allocPrint(self.allocator, "Worktree size updated: {s} - {s}", .{ worktree_path, measured }) catch return;
        self.replaceStatus(message);
        self.syncAccessibility();
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
    }

    fn finishWorktreeSizing(self: *App, project_path: []const u8) void {
        const inspection = if (self.worktree_inspection) |*value| value else return;
        if (!std.mem.eql(u8, inspection.project_path, project_path)) return;
        if (inspection.entries.items.len == 0) {
            self.setWorktreeStateWithReceipts("No linked worktrees in this repository.");
            self.setStatus("No linked worktrees in this repository.");
            return;
        }
        var failures: usize = 0;
        for (inspection.entries.items) |entry| {
            if (entry.opened_checkout or entry.prunable) continue;
            if (!entry.size_complete or entry.size_error != null) failures += 1;
        }
        const message = if (failures == 0)
            std.fmt.allocPrint(self.allocator, "{d} worktree{s}; sizes complete.", .{
                inspection.entries.items.len,
                if (inspection.entries.items.len == 1) "" else "s",
            })
        else
            std.fmt.allocPrint(self.allocator, "{d} worktree{s}; {d} size{s} unavailable. Rows remain available; use Reveal to inspect them.", .{
                inspection.entries.items.len,
                if (inspection.entries.items.len == 1) "" else "s",
                failures,
                if (failures == 1) "" else "s",
            });
        const owned = message catch return;
        self.setWorktreeStateWithReceipts(owned);
        self.allocator.free(owned);
        self.setStatus(self.worktree_state);
    }

    fn drainWorktreeInspection(self: *App) void {
        self.worktree_inspection_generation += 1;
        self.worktree_inspection_cancellation.store(self.worktree_inspection_generation, .release);
        if (self.worktree_inspection_pending) |pending| {
            pending.deinit(self.allocator);
            self.worktree_inspection_pending = null;
        }
        if (self.worktree_inspection_thread) |thread| {
            thread.join();
            self.worktree_inspection_thread = null;
        }
        self.worktree_inspection_lock.lock();
        for (self.worktree_inspection_results.items) |*result| result.deinit(self.allocator);
        self.worktree_inspection_results.deinit(self.allocator);
        self.worktree_inspection_results = .empty;
        self.worktree_inspection_done = false;
        self.worktree_inspection_lock.unlock();
        if (self.worktree_loading_path.len != 0) {
            self.allocator.free(self.worktree_loading_path);
            self.worktree_loading_path = &.{};
        }
        if (self.worktree_state.len != 0) {
            self.allocator.free(self.worktree_state);
            self.worktree_state = &.{};
        }
    }

    fn queueWorktreeReclaim(
        self: *App,
        project_path: []const u8,
        selected: []const []const u8,
        bindings: []const WorktreeStatus.Binding,
        policy: WorktreeStatus.Policy,
        confirmed: bool,
        allow_forced: bool,
        kind: WorktreeReclaimKind,
    ) !void {
        if (self.worktree_reclaim_thread != null) return error.WorktreeReclaimInProgress;
        self.worktree_reclaim_generation += 1;
        self.worktree_reclaim_cancellation.store(self.worktree_reclaim_generation, .release);
        const request = try self.allocator.create(WorktreeReclaimRequest);
        errdefer self.allocator.destroy(request);
        request.* = .{
            .generation = self.worktree_reclaim_generation,
            .project_path = try self.allocator.dupe(u8, project_path),
            .selected = &.{},
            .bindings = &.{},
            .policy = policy,
            .confirmed = confirmed,
            .allow_forced = allow_forced,
            .kind = kind,
            .runner = self.worktree_reclaim_runner,
        };
        errdefer self.allocator.free(request.project_path);
        request.selected = try self.allocator.alloc([]const u8, selected.len);
        errdefer self.allocator.free(request.selected);
        var selected_initialized: usize = 0;
        errdefer for (request.selected[0..selected_initialized]) |path| self.allocator.free(path);
        for (selected, 0..) |path, index| {
            request.selected[index] = try self.allocator.dupe(u8, path);
            selected_initialized += 1;
        }
        request.bindings = try self.allocator.alloc(WorktreeStatus.Binding, bindings.len);
        errdefer self.allocator.free(request.bindings);
        var bindings_initialized: usize = 0;
        errdefer for (request.bindings[0..bindings_initialized]) |binding| self.allocator.free(binding.path);
        for (bindings, 0..) |binding, index| {
            request.bindings[index] = .{ .path = try self.allocator.dupe(u8, binding.path) };
            bindings_initialized += 1;
        }
        self.worktree_reclaim_done = false;
        if (self.worktree_reclaim_receipts.len != 0) {
            self.allocator.free(self.worktree_reclaim_receipts);
            self.worktree_reclaim_receipts = &.{};
        }
        self.worktree_reclaim_thread = std.Thread.spawn(
            .{},
            worktreeReclaimWorker,
            .{ self, request },
        ) catch |err| {
            request.deinit(self.allocator);
            return err;
        };
        self.reclaim_confirmation_armed = false;
        self.setStatus("Removing worktrees...");
    }

    fn worktreeReclaimWorker(self: *App, request: *WorktreeReclaimRequest) void {
        const project_path = request.project_path;
        request.project_path = &.{};
        const outcome = request.runner(
            self.allocator,
            project_path,
            request.selected,
            request.bindings,
            request.policy,
            request.confirmed,
            request.allow_forced,
            .{
                .generation = &self.worktree_reclaim_cancellation,
                .expected = request.generation,
            },
        );
        const kind = request.kind;
        request.deinit(self.allocator);
        self.worktree_reclaim_lock.lock();
        if (self.worktree_reclaim_result) |*old| old.deinit(self.allocator);
        self.worktree_reclaim_result = .{
            .project_path = project_path,
            .kind = kind,
            .outcome = outcome,
        };
        self.worktree_reclaim_done = true;
        self.worktree_reclaim_lock.unlock();
    }

    fn finishWorktreeReclaim(self: *App) void {
        self.worktree_reclaim_lock.lock();
        const done = self.worktree_reclaim_done;
        self.worktree_reclaim_lock.unlock();
        if (!done) return;
        if (self.worktree_reclaim_thread) |thread| thread.join();
        self.worktree_reclaim_thread = null;
        self.worktree_reclaim_lock.lock();
        var result = self.worktree_reclaim_result;
        self.worktree_reclaim_result = null;
        self.worktree_reclaim_done = false;
        self.worktree_reclaim_lock.unlock();
        if (result) |*completed| {
            defer completed.deinit(self.allocator);
            var report = completed.outcome catch |err| {
                self.setStatus(switch (err) {
                    error.GitFailed => "Git refused to remove a selected worktree",
                    error.PolicyDisabled => "Reclaim disabled by project worktree policy",
                    error.ConfirmationRequired => "Reclaim confirmation required",
                    error.UnsafeSelection => "Reclaim blocked: selected worktree is unsafe",
                    else => "Worktree removal failed",
                });
                return;
            };
            defer report.deinit();
            completed.outcome = error.ResultConsumed;
            const failures = report.failureCount();
            const message = switch (completed.kind) {
                .sweep => if (failures == 0)
                    std.fmt.allocPrint(self.allocator, "Worktree Sweep removed {d} worktrees and {d} branches", .{ report.removed_worktrees, report.deleted_branches })
                else
                    std.fmt.allocPrint(self.allocator, "Worktree Sweep partial: {d} worktrees removed, {d} branches deleted, {d} rows need attention", .{ report.removed_worktrees, report.deleted_branches, failures }),
                .selected => if (failures == 0)
                    std.fmt.allocPrint(self.allocator, "Reclaimed {d} worktrees and deleted {d} branches", .{ report.removed_worktrees, report.deleted_branches })
                else
                    std.fmt.allocPrint(self.allocator, "Reclaim partial: {d} worktrees removed, {d} branches deleted, {d} rows need attention", .{ report.removed_worktrees, report.deleted_branches, failures }),
                .offer => if (failures == 0)
                    self.allocator.dupe(u8, "Resolved worktree and branch reclaimed")
                else
                    self.allocator.dupe(u8, "Resolved worktree reclaim needs attention"),
            } catch {
                self.setStatus("Worktree removal complete");
                return;
            };
            self.replaceStatus(message);
            self.worktree_reclaim_receipts = WorktreeStatus.reclaimReportPresentation(self.allocator, report) catch &.{};
            const current = self.currentProject() orelse return;
            if (std.mem.eql(u8, current, completed.project_path)) self.inspectWorktreesImpl(false);
        }
    }

    fn drainWorktreeReclaim(self: *App) void {
        self.worktree_reclaim_generation += 1;
        self.worktree_reclaim_cancellation.store(self.worktree_reclaim_generation, .release);
        if (self.worktree_reclaim_thread) |thread| {
            thread.join();
            self.worktree_reclaim_thread = null;
        }
        self.worktree_reclaim_lock.lock();
        if (self.worktree_reclaim_result) |*result| result.deinit(self.allocator);
        self.worktree_reclaim_result = null;
        self.worktree_reclaim_done = false;
        self.worktree_reclaim_lock.unlock();
    }

    fn presentWorktreeSweep(self: *App) void {
        const graph = self.model.graph orelse return;
        const inspection = self.worktree_inspection orelse return;
        const project_path = self.allocator.dupe(u8, graph.project.path) catch return;
        defer self.allocator.free(project_path);
        const project_name = self.allocator.dupe(u8, graph.project.name) catch return;
        defer self.allocator.free(project_name);
        const result = NativeForms.worktreeSweep(
            self.window.hwnd,
            self.allocator,
            project_name,
            inspection.entries.items,
        ) catch {
            self.setStatus("Unable to open Worktree Sweep");
            return;
        } orelse {
            self.setStatus("Worktree Sweep cancelled");
            return;
        };
        const current_graph = self.model.graph orelse {
            self.setStatus("Project closed while Worktree Sweep was open");
            return;
        };
        if (!std.mem.eql(u8, current_graph.project.path, project_path)) {
            self.setStatus("Project changed while Worktree Sweep was open");
            return;
        }
        const current_inspection = self.worktree_inspection orelse {
            self.setStatus("Worktree inspection expired");
            return;
        };
        if (!std.mem.eql(u8, current_inspection.project_path, project_path)) {
            self.setStatus("Worktree inspection no longer matches this project");
            return;
        }
        var selected = std.array_list.Managed([]const u8).init(self.allocator);
        defer selected.deinit();
        for (current_inspection.entries.items[0..@min(current_inspection.entries.items.len, result.count)], 0..) |entry, index| {
            if (result.selected[index] and WorktreeStatus.sweepSelectable(entry))
                selected.append(entry.path) catch {
                    self.setStatus("Unable to collect Worktree Sweep selection");
                    return;
                };
        }
        if (selected.items.len == 0) {
            self.setStatus("No safe worktrees selected");
            return;
        }
        var bindings = std.array_list.Managed(WorktreeStatus.Binding).init(self.allocator);
        defer bindings.deinit();
        for (current_graph.nodes.items) |node| if (node.worktree_path.len != 0) {
            bindings.append(.{ .path = node.worktree_path }) catch {};
        };
        var explicit_policy = WorktreeStatus.Policy{};
        explicit_policy.applyResolveAction(.remove);
        self.model.invalidateWorktreeNotices(.worktrees_changed);
        self.queueWorktreeReclaim(
            project_path,
            selected.items,
            bindings.items,
            explicit_policy,
            result.destructive_confirmed,
            result.destructive_confirmed,
            .sweep,
        ) catch |err| {
            self.reportWorktreeError("Worktree Sweep could not start", err);
            return;
        };
    }

    fn installUiaFixture(self: *App, reset_sidebar: bool) bool {
        const project = if (self.uia_fixture_project_path.len != 0)
            self.allocator.dupe(u8, self.uia_fixture_project_path) catch {
                self.setStatus("Unable to retain UIA fixture project");
                return false;
            }
        else
            std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_GATE_CWD") catch |err| {
                self.reportWorktreeError("UIA fixture requires an owned GRAPHCODE_GATE_CWD", err);
                return false;
            };
        defer self.allocator.free(project);
        const normalized = normalizeUiaFixtureProject(self.allocator, project) catch |err| {
            self.reportWorktreeError("Invalid UIA fixture project", err);
            return false;
        };
        defer self.allocator.free(normalized);
        var directory = std.fs.openDirAbsolute(normalized, .{}) catch |err| {
            self.reportWorktreeError("UIA fixture project directory is unavailable", err);
            return false;
        };
        directory.close();
        self.installUiaFixtureData(project) catch |err| {
            self.reportWorktreeError("Unable to install UIA fixture data", err);
            return false;
        };
        if (reset_sidebar and envFlag("GRAPHCODE_UIA_RESET_SIDEBAR")) self.sidebar_state.clearExpandedNodes();
        if (envFlag("GRAPHCODE_UIA_UPDATE_AVAILABLE")) {
            self.update_lock.lock();
            self.update_state.state = .available;
            if (self.update_version.len != 0) self.allocator.free(self.update_version);
            if (self.update_release_url.len != 0) self.allocator.free(self.update_release_url);
            self.update_version = self.allocator.dupe(u8, "9.9.9-test") catch &.{};
            self.update_release_url = self.allocator.dupe(u8, WindowsUpdates.releases_page_url ++ "/tag/v9.9.9-test") catch &.{};
            self.update_lock.unlock();
        }
        if (std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_UIA_INGRESS_ERROR")) |message| {
            defer self.allocator.free(message);
            self.setIngressError(message);
        } else |_| {}
        self.setStatus("UIA fixture inspection ready");
        return true;
    }

    fn installUiaFixtureData(self: *App, project_path: []const u8) !void {
        if (NativeForms.isModalActive()) return error.UiaFixtureModalActive;
        const captured = try normalizeUiaFixtureProject(self.allocator, project_path);
        errdefer self.allocator.free(captured);
        if (self.uia_fixture_project_path.len != 0 and !std.mem.eql(u8, captured, self.uia_fixture_project_path))
            return error.UiaFixtureProjectChanged;
        const data = try UiaFixtureData.init(self.allocator, project_path);
        if (self.worktree_dialog) |*dialog| dialog.deinit();
        if (self.worktree_inspection) |*inspection| WorktreeStatus.deinitInspection(self.allocator, inspection);
        self.model.deinit();
        self.releaseUiaFixtureModelArena();
        self.model = data.model;
        self.uia_fixture_model_arena = data.model_arena;
        self.worktree_inspection = data.inspection;
        self.worktree_dialog = data.dialog;
        if (self.uia_fixture_project_path.len != 0) self.allocator.free(self.uia_fixture_project_path);
        self.uia_fixture_project_path = captured;
        if (self.selected_worktree_path.len != 0) self.allocator.free(self.selected_worktree_path);
        self.selected_worktree_path = &.{};
        self.reclaim_confirmation_armed = false;
    }

    fn releaseUiaFixtureModelArena(self: *App) void {
        if (self.uia_fixture_model_arena) |arena| {
            arena.deinit();
            self.allocator.destroy(arena);
            self.uia_fixture_model_arena = null;
        }
    }

    fn resetUiaFixtureModel(self: *App) !void {
        if (NativeForms.isModalActive()) return error.UiaFixtureModalActive;
        self.model.deinit();
        self.releaseUiaFixtureModelArena();
        self.model = GraphModel.Model.init(self.allocator);
    }

    fn requiredUiaFixtureProject(self: *const App) ![]const u8 {
        if (self.uia_fixture_project_path.len == 0) return error.UiaFixtureProjectNotCaptured;
        return self.uia_fixture_project_path;
    }

    fn ownedUiaFixturePath(self: *const App, kind: UiaFixturePath) ![]u8 {
        return uiaFixturePath(self.allocator, try self.requiredUiaFixtureProject(), kind);
    }

    fn applyUiaFixtureGraph(self: *App, kind: UiaFixturePath, name: []const u8, sequence: usize, nodes: []const u8, edges: []const u8) !void {
        const path = try self.ownedUiaFixturePath(kind);
        defer self.allocator.free(path);
        const frame = try uiaFixtureGraphFrame(self.allocator, path, name, sequence, nodes, edges);
        defer self.allocator.free(frame);
        _ = try self.model.updateFromFrame(frame);
    }

    fn appendUiaFixtureLoop(self: *App) !void {
        const project = try self.requiredUiaFixtureProject();
        if (self.uia_fixture_model_arena == null) return error.InvalidUiaFixtureData;
        const summary = for (self.model.graphs.items) |*graph| {
            if (std.mem.eql(u8, graph.project.path, project)) break graph;
        } else return error.InvalidUiaFixtureData;
        if (GraphModel.findNodeIndexByID(summary.nodes.items, "77777777-7777-4777-8777-777777777777") != null) return;
        const current = if (self.model.graph) |*graph|
            if (std.mem.eql(u8, graph.project.path, project)) graph else null
        else
            null;
        const allocator = self.model.allocator;
        try summary.nodes.ensureUnusedCapacity(1);
        if (current) |graph| try graph.nodes.ensureUnusedCapacity(1);
        var additions: [2]GraphModel.Node = undefined;
        for (additions[0..if (current != null) @as(usize, 2) else 1]) |*extra| {
            extra.* = .{
                .id = try allocator.dupe(u8, "77777777-7777-4777-8777-777777777777"),
                .title = try allocator.dupe(u8, "UIA loop C"),
                .loop_type = try allocator.dupe(u8, "turnBased"),
                .state = try allocator.dupe(u8, "idle"),
                .activity = try allocator.dupe(u8, ""),
                .presence = try allocator.dupe(u8, "idle"),
            };
        }
        summary.nodes.appendAssumeCapacity(additions[0]);
        if (current) |graph| graph.nodes.appendAssumeCapacity(additions[1]);
    }

    /// True once there is a worktree row the reveal/reclaim commands could
    /// actually act on: either the sidebar's single-selection shortcut has a
    /// path, or the Worktrees dialog itself has a checked row. Mirrors the
    /// menu's contextual enablement in MainWindow.updateMenu so a command
    /// that is enabled can always make progress instead of only reporting
    /// "select a row first".
    fn worktreeRowSelected(self: *const App) bool {
        const project = self.currentProject() orelse return false;
        const inspection = self.worktree_inspection orelse return false;
        if (!std.mem.eql(u8, inspection.project_path, project)) return false;
        if (self.selected_worktree_path.len != 0) return true;
        if (self.worktree_dialog) |dialog| {
            if (!std.mem.eql(u8, dialog.project_path, project)) return false;
            return dialog.selectedCount() != 0;
        }
        return false;
    }

    fn worktreeProviderBusy(self: *const App) bool {
        return self.worktree_inspection_thread != null or self.worktree_reclaim_thread != null;
    }

    fn reclaimWorktrees(self: *App) void {
        const current_graph = self.model.graph orelse {
            self.setStatus("Worktrees require a local filesystem project");
            return;
        };
        if (current_graph.project.isGlobal()) {
            self.setStatus("The global graph has no repository worktrees");
            return;
        }
        const path = current_graph.project.path;
        if (path.len == 0) {
            self.setStatus("No project selected for worktree reclaim");
            return;
        }
        if (!self.worktreeRowSelected()) {
            self.setStatus("Select a worktree row before reclaiming");
            return;
        }
        const policy = WorktreeStatus.loadPolicy(self.allocator, path);
        if (!policy.allow_reclaim) {
            self.setStatus("Reclaim disabled by project worktree policy");
            return;
        }
        if (policy.confirm_each_reclaim and !self.reclaim_confirmation_armed) {
            self.reclaim_confirmation_armed = true;
            self.setStatus("Reclaim is destructive; press Ctrl+Shift+W again to confirm");
            return;
        }
        var selected_list = if (self.worktree_dialog) |*dialog|
            dialog.selectedPaths(self.allocator) catch {
                self.setStatus("Unable to collect selected worktrees");
                return;
            }
        else blk: {
            var single = std.array_list.Managed([]const u8).init(self.allocator);
            single.append(self.selected_worktree_path) catch {
                single.deinit();
                self.setStatus("Unable to collect selected worktrees");
                return;
            };
            break :blk single;
        };
        defer selected_list.deinit();
        var bindings = std.array_list.Managed(WorktreeStatus.Binding).init(self.allocator);
        defer bindings.deinit();
        if (self.model.graph) |graph| for (graph.nodes.items) |bound| {
            if (bound.worktree_path.len != 0) bindings.append(.{ .path = bound.worktree_path }) catch {};
        };
        self.model.invalidateWorktreeNotices(.worktrees_changed);
        self.queueWorktreeReclaim(
            path,
            selected_list.items,
            bindings.items,
            policy,
            true,
            false,
            .selected,
        ) catch |err| {
            self.reclaim_confirmation_armed = false;
            self.reportWorktreeError("Reclaim could not start", err);
            return;
        };
    }

    pub fn selectWorktreeRow(self: *App, path: []const u8) bool {
        const inspection = self.worktree_inspection orelse return false;
        if (!envFlag("GRAPHCODE_UIA_GATE")) {
            if (self.currentProject()) |project| {
                if (!std.mem.eql(u8, project, inspection.project_path)) return false;
            } else return false;
        }
        for (inspection.entries.items) |entry| {
            if (!std.mem.eql(u8, entry.path, path)) continue;
            if (!WorktreeStatus.actionSelectable(entry)) return false;
            if (self.worktree_dialog) |*dialog| {
                dialog.clearSelection();
                for (dialog.rows.items, 0..) |row, index| {
                    if (std.mem.eql(u8, row.entry.path, path)) {
                        _ = dialog.toggle(index);
                        break;
                    }
                }
            }
            if (self.selected_worktree_path.len != 0) self.allocator.free(self.selected_worktree_path);
            self.selected_worktree_path = self.allocator.dupe(u8, path) catch return false;
            self.reclaim_confirmation_armed = false;
            self.syncAccessibility();
            return true;
        }
        return false;
    }

    pub fn toggleWorktreeRow(self: *App, index: usize) bool {
        const dialog = if (self.worktree_dialog) |*value| value else return false;
        if (index >= dialog.rows.items.len or
            !WorktreeStatus.actionSelectable(dialog.rows.items[index].entry)) return false;
        _ = dialog.toggle(index);
        if (self.selected_worktree_path.len != 0) {
            self.allocator.free(self.selected_worktree_path);
            self.selected_worktree_path = &.{};
        }
        for (dialog.rows.items) |row| {
            if (!row.selected) continue;
            self.selected_worktree_path = self.allocator.dupe(u8, row.entry.path) catch &.{};
            break;
        }
        self.reclaim_confirmation_armed = false;
        self.syncAccessibility();
        return true;
    }

    fn applyUiaWorktreeSelection(self: *App, payload: usize, operation: usize) bool {
        const dialog = if (self.worktree_dialog) |*value| value else return false;
        var target: ?usize = null;
        for (dialog.rows.items, 0..) |row, index| {
            if (Accessibility.worktreeIdentityPayload(row.entry.path) == payload) {
                target = index;
                break;
            }
        }
        const index = target orelse return false;
        if (!WorktreeStatus.actionSelectable(dialog.rows.items[index].entry)) return false;
        switch (operation) {
            0 => {
                for (dialog.rows.items) |*row| row.selected = false;
                dialog.rows.items[index].selected = true;
            },
            1 => dialog.rows.items[index].selected = true,
            2 => dialog.rows.items[index].selected = false,
            else => return false,
        }
        if (self.selected_worktree_path.len != 0) {
            self.allocator.free(self.selected_worktree_path);
            self.selected_worktree_path = &.{};
        }
        for (dialog.rows.items) |row| {
            if (!row.selected) continue;
            self.selected_worktree_path = self.allocator.dupe(u8, row.entry.path) catch &.{};
            break;
        }
        self.reclaim_confirmation_armed = false;
        self.syncAccessibility();
        return true;
    }

    fn mutateUiaFixture(self: *App, mutation: usize) void {
        if (!envFlag("GRAPHCODE_UIA_GATE")) return;
        if (mutation == 6) {
            self.showAbout();
            return;
        }
        if (mutation == 7) {
            self.closeCompositeGroup();
            self.surface = .project;
            self.workspace_controls.panel_visible = false;
            self.layoutWorkspace();
            self.syncAccessibility();
            _ = self.model.setSelectedID("11111111-1111-4111-8111-111111111111");
            self.editSelectedNode();
            return;
        }
        if (mutation == 8) {
            self.setIngressError("Folder could not be opened");
            return;
        }
        if (mutation == 9) {
            self.clearIngressError();
            self.resetUiaFixtureModel() catch |err| {
                self.reportWorktreeError("Unable to reset UIA fixture model", err);
                return;
            };
            self.surface = .overview;
            self.layoutEmptyStateControls();
            self.syncAccessibility();
            _ = c.InvalidateRect(self.window.hwnd, null, 0);
            return;
        }
        if (mutation == 10) {
            self.applyUiaFixtureGraph(.empty, "Empty project", 50, "[]", "[]") catch |err| {
                self.reportWorktreeError("Unable to prepare empty UIA fixture", err);
                return;
            };
            self.surface = .project;
            self.layoutEmptyStateControls();
            self.syncAccessibility();
            _ = c.InvalidateRect(self.window.hwnd, null, 0);
            return;
        }
        if (mutation == 11) {
            self.showRemoteProjectInfo("ssh://builder/GraphCode");
            return;
        }
        if (mutation == 12) {
            const path = self.ownedUiaFixturePath(.empty) catch |err| {
                self.reportWorktreeError("UIA fixture owner unavailable", err);
                return;
            };
            defer self.allocator.free(path);
            self.deleteProjectLoops(path);
            return;
        }
        if (mutation == 13) {
            self.applyUiaFixtureGraph(.empty, "Empty project", 51,
                \\[{"id":"edge-source","title":"Planner","state":"idle"},{"id":"edge-target","title":"Builder","state":"idle"}]
            ,
                \\[{"id":"edge-delete","from":"edge-source","to":"edge-target","kind":"handoff"}]
            ) catch |err| {
                self.reportWorktreeError("Unable to prepare edge UIA fixture", err);
                return;
            };
            self.deleteEdge(0);
            return;
        }
        if (mutation == 14) {
            self.applyUiaFixtureGraph(.jump, "Jump fixture", 52,
                \\[{"id":"jump-cross-project","title":"UIA loop C","loopType":"timeBased","state":"awaitingInput"}]
            , "[]") catch |err| {
                self.reportWorktreeError("Unable to prepare jump UIA fixture", err);
                return;
            };
            _ = self.model.setSelectedID("11111111-1111-4111-8111-111111111111");
            self.jumpToNode();
            return;
        }
        if (mutation == 15) {
            self.openProductSettings();
            return;
        }
        if (mutation == 16) {
            const project_path = self.requiredUiaFixtureProject() catch |err| {
                self.reportWorktreeError("UIA fixture owner unavailable", err);
                return;
            };
            self.appendUiaFixtureLoop() catch |err| {
                self.reportWorktreeError("Unable to extend UIA fixture graph", err);
                return;
            };
            self.syncAccessibility();
            _ = c.InvalidateRect(self.window.hwnd, null, 0);
            var rows = Sidebar.appendRows(
                self.allocator,
                &self.model,
                if (self.worktree_inspection) |*value| value else null,
                self.sidebar_scroll,
                &self.sidebar_state,
            ) catch return;
            defer rows.deinit(self.allocator);
            var start_y: ?i32 = null;
            var drop_y: ?i32 = null;
            for (rows.items) |row| {
                if (row.kind != .loop or row.depth != 0 or row.project_path == null or !std.mem.eql(u8, row.project_path.?, project_path)) continue;
                if (row.index == 0) start_y = row.top + 8;
                if (row.index == 2) drop_y = row.top + 20;
            }
            if (start_y) |drag_start| {
                self.beginSidebarRootDrag(project_path, "11111111-1111-4111-8111-111111111111", drag_start);
                self.updateSidebarRootDrag(drop_y orelse (drag_start + 32));
                _ = self.completeSidebarRootDrag(drop_y orelse (drag_start + 32));
            }
            return;
        }
        if (mutation == 17) {
            const path = self.requiredUiaFixtureProject() catch |err| {
                self.reportWorktreeError("UIA fixture owner unavailable", err);
                return;
            };
            self.handleContextAction(.move_project, .{ .project = .{ .path = path, .remote = false } });
            return;
        }
        if (mutation == 18) {
            const baseline_nodes =
                \\[{"id":"act-1","title":"Activity A","loopType":"goalBased","state":"idle"},{"id":"act-2","title":"Activity B","loopType":"goalBased","state":"idle"},{"id":"act-3","title":"Activity C","loopType":"goalBased","state":"idle"},{"id":"act-4","title":"Activity D","loopType":"goalBased","state":"idle"},{"id":"act-5","title":"Activity E","loopType":"goalBased","state":"idle"}]
            ;
            const changed_nodes =
                \\[{"id":"act-1","title":"Activity A","loopType":"goalBased","state":"succeeded"},{"id":"act-2","title":"Activity B","loopType":"goalBased","state":"failed"},{"id":"act-3","title":"Activity C","loopType":"goalBased","state":"awaitingInput"},{"id":"act-4","title":"Activity D","loopType":"goalBased","state":"blocked"},{"id":"act-5","title":"Activity E","loopType":"goalBased","state":"running"}]
            ;
            self.applyUiaFixtureGraph(.project, "UIA project", 54, baseline_nodes, "[]") catch |err| {
                self.reportWorktreeError("Unable to prepare activity UIA fixture", err);
                return;
            };
            self.applyUiaFixtureGraph(.project, "UIA project", 55, changed_nodes, "[]") catch |err| {
                self.reportWorktreeError("Unable to update activity UIA fixture", err);
                return;
            };
            self.surface = .project;
            self.workspace_controls.panel_visible = false;
            self.layoutWorkspace();
            self.layoutEmptyStateControls();
            self.syncAccessibility();
            _ = c.InvalidateRect(self.window.hwnd, null, 0);
            return;
        }
        if (mutation == 19) {
            self.setIngressError("Folder could not be opened because the background service returned a detailed error that should wrap cleanly in the sidebar footer.");
            return;
        }
        if (mutation == 20) {
            if (!self.installUiaFixture(false)) return;
            self.surface = .project;
            self.workspace_controls.panel_visible = false;
            self.layoutWorkspace();
            self.layoutEmptyStateControls();
            self.syncAccessibility();
            _ = c.InvalidateRect(self.window.hwnd, null, 0);
            return;
        }
        if (mutation == 21) {
            _ = self.model.setSelectedID("11111111-1111-4111-8111-111111111111");
            self.editSelectedNodeDetails();
            return;
        }
        const dialog = if (self.worktree_dialog) |*value| value else return;
        const target_path = if (mutation == 2 or mutation == 3) self.ownedUiaFixturePath(if (mutation == 2) .safe else .unsafe) catch |err| {
            self.reportWorktreeError("UIA fixture owner unavailable", err);
            return;
        } else null;
        defer if (target_path) |path| self.allocator.free(path);
        switch (mutation) {
            1 => {
                if (dialog.rows.items.len > 1)
                    std.mem.swap(WorktreeDialog.Row, &dialog.rows.items[0], &dialog.rows.items[1]);
            },
            2 => {
                const target = for (dialog.rows.items, 0..) |row, index| {
                    if (std.mem.eql(u8, row.entry.path, target_path.?)) break index;
                } else return;
                _ = dialog.rows.orderedRemove(target);
                if (self.selected_worktree_path.len != 0) {
                    self.allocator.free(self.selected_worktree_path);
                    self.selected_worktree_path = &.{};
                }
            },
            3 => {
                const target = for (dialog.rows.items, 0..) |row, index| {
                    if (std.mem.eql(u8, row.entry.path, target_path.?)) break index;
                } else return;
                dialog.rows.items[target].entry.dirty = !dialog.rows.items[target].entry.dirty;
            },
            4 => {
                var policy = dialog.policy;
                policy.allow_reclaim = !policy.allow_reclaim;
                dialog.setPolicy(policy);
            },
            5 => {
                var policy = dialog.policy;
                policy.confirm_each_reclaim = !policy.confirm_each_reclaim;
                dialog.setPolicy(policy);
            },
            else => return,
        }
        self.syncAccessibility();
    }

    pub fn saveWorktreePolicy(self: *App, policy: WorktreeStatus.Policy) !void {
        const path = self.currentProject() orelse return error.EmptyProjectPath;
        try self.saveWorktreePolicyForProject(path, policy);
    }

    fn acceptWorktreePolicy(self: *App, project_path: []const u8, outcome: WorktreeStatus.PolicyOutcome) !void {
        try self.model.recordWorktreePolicy(project_path, outcome);
        if (self.worktree_dialog) |*dialog| {
            if (std.mem.eql(u8, dialog.project_path, project_path)) dialog.setPolicy(outcome.value() orelse .{});
        }
    }

    fn saveWorktreePolicyForProject(self: *App, project_path: []const u8, policy: WorktreeStatus.Policy) !void {
        try self.saveWorktreePolicyUsing(project_path, policy, WorktreeStatus);
        self.setStatus("Worktree policy saved");
    }

    fn saveWorktreePolicyUsing(self: *App, project_path: []const u8, policy: WorktreeStatus.Policy, storage: anytype) !void {
        const path = try self.allocator.dupe(u8, project_path);
        defer self.allocator.free(path);
        const owner = self.model.graphFor(path) orelse return error.WorktreeProjectClosed;
        if (!owner.project.isLocalFilesystem()) return error.UnsupportedWorktreeProject;
        const write_result = storage.savePolicy(self.allocator, path, policy);
        const outcome = storage.loadPolicyOutcome(self.allocator, path);
        const reconciliation = self.acceptWorktreePolicy(path, outcome);
        // A partial write may have changed the file; reconcile it without replacing the original write error.
        try write_result;
        try reconciliation;
        switch (outcome) {
            .failed => |err| return err,
            .known => {},
            .not_loaded => return error.WorktreePolicyNotRead,
        }
    }

    fn editWorktreePolicy(self: *App) void {
        const selected_path = self.currentProject() orelse {
            self.setStatus("Open a project before changing project settings");
            return;
        };
        const project_path = self.allocator.dupe(u8, selected_path) catch {
            self.setStatus("Unable to retain project settings target");
            return;
        };
        defer self.allocator.free(project_path);
        const owner = self.model.graphFor(project_path) orelse {
            self.setStatus("Open a project before changing project settings");
            return;
        };
        if (!owner.project.isLocalFilesystem()) {
            self.setStatus("Project settings require a local filesystem project");
            return;
        }
        if (envFlag("GRAPHCODE_UIA_GATE") and !envFlag("GRAPHCODE_UIA_SHOW_DIALOGS")) {
            self.setStatus("Project settings opened");
            return;
        }
        const initial = WorktreeStatus.loadPolicyOutcome(self.allocator, project_path);
        self.acceptWorktreePolicy(project_path, initial) catch |err| {
            self.reportWorktreeError("Project settings owner unavailable", err);
            return;
        };
        if (initial == .failed) self.reportWorktreeError("Worktree policy unavailable; editing fail-closed defaults", initial.failed);
        const result = NativeForms.worktreePolicy(self.window.hwnd, self.allocator, project_path, initial.value() orelse .{});
        // The editor persists valid edits immediately, including before Cancel.
        const outcome = WorktreeStatus.loadPolicyOutcome(self.allocator, project_path);
        self.acceptWorktreePolicy(project_path, outcome) catch |err| {
            self.reportWorktreeError("Project settings owner unavailable after editing", err);
            return;
        };
        const policy = result catch |err| {
            self.reportWorktreeError("Unable to open worktree policy editor", err);
            return;
        };
        if (outcome == .failed) {
            self.reportWorktreeError("Worktree policy unavailable after editing", outcome.failed);
            return;
        }
        self.setStatus(if (policy == null) "Worktree policy edit cancelled; saved policy reloaded" else "Project settings updated");
    }

    fn saveCurrentWorktreePolicy(self: *App) void {
        const dialog = self.worktree_dialog orelse {
            self.setStatus("Inspect worktrees before saving policy");
            return;
        };
        self.saveWorktreePolicyForProject(dialog.project_path, dialog.policy) catch |err| {
            self.reportWorktreeError("Unable to save worktree policy", err);
            return;
        };
    }

    fn toggleAllowReclaim(self: *App) void {
        if (self.worktree_dialog) |*dialog| {
            var policy = dialog.policy;
            policy.allow_reclaim = !policy.allow_reclaim;
            dialog.setPolicy(policy);
            self.setStatus(if (policy.allow_reclaim) "Policy: reclaim enabled" else "Policy: reclaim disabled");
        }
    }

    fn toggleConfirmReclaim(self: *App) void {
        if (self.worktree_dialog) |*dialog| {
            var policy = dialog.policy;
            policy.confirm_each_reclaim = !policy.confirm_each_reclaim;
            dialog.setPolicy(policy);
            self.setStatus(if (policy.confirm_each_reclaim) "Policy: confirmation required" else "Policy: confirmation disabled");
        }
    }

    fn revealSelectedWorktree(self: *App) void {
        const dialog = self.worktree_dialog orelse {
            self.setStatus("Inspect worktrees before revealing a row");
            return;
        };
        const args = dialog.revealSelected() catch {
            self.setStatus("Select a worktree row before revealing it");
            return;
        };
        const parameters = WorktreeStatus.explorerParameters(self.allocator, args.path) catch {
            self.setStatus("Unable to prepare Explorer");
            return;
        };
        defer self.allocator.free(parameters);
        const wide_params_raw = std.unicode.utf8ToUtf16LeAlloc(self.allocator, parameters) catch {
            self.setStatus("Unable to encode Explorer path");
            return;
        };
        defer self.allocator.free(wide_params_raw);
        const wide_params = self.allocator.alloc(u16, wide_params_raw.len + 1) catch {
            self.setStatus("Unable to encode Explorer path");
            return;
        };
        defer self.allocator.free(wide_params);
        @memcpy(wide_params[0..wide_params_raw.len], wide_params_raw);
        wide_params[wide_params_raw.len] = 0;
        const result = c.ShellExecuteW(
            self.window.hwnd,
            std.unicode.utf8ToUtf16LeStringLiteral("open").ptr,
            std.unicode.utf8ToUtf16LeStringLiteral("explorer.exe").ptr,
            wide_params.ptr,
            null,
            c.SW_SHOWNORMAL,
        );
        if (@intFromPtr(result) <= 32) self.setStatus("Unable to open Explorer") else self.setStatus("Opened selected worktree in Explorer");
    }

    fn keepWorktreeOffer(self: *App, path: []const u8) void {
        for (self.kept_worktree_paths.items) |kept| if (std.mem.eql(u8, kept, path)) return;
        const copy = self.allocator.dupe(u8, path) catch {
            self.setStatus("Unable to keep the worktree offer");
            return;
        };
        self.kept_worktree_paths.append(copy) catch {
            self.allocator.free(copy);
            self.setStatus("Unable to keep the worktree offer");
            return;
        };
        self.setStatus("Keeping the resolved worktree");
    }

    fn reclaimWorktreeOffer(self: *App, path: []const u8) void {
        const graph = self.model.graph orelse return;
        if (!graph.project.isLocalFilesystem()) return;
        const inspection = self.worktree_inspection orelse return;
        const entry = WorktreeStatus.selectedEntry(inspection.entries.items, path) orelse return;
        if (WorktreeStatus.decision(entry) != .reclaimable) {
            self.setStatus("This worktree is no longer safe to reclaim");
            return;
        }
        const message = std.fmt.allocPrint(
            self.allocator,
            "Remove this landed, clean worktree?\n\n{s}\n\nThe branch history remains in git.",
            .{path},
        ) catch return;
        defer self.allocator.free(message);
        if (!GraphContextMenu.confirm(self.window.hwnd, "Reclaim Worktree", message)) return;
        var bindings = std.array_list.Managed(WorktreeStatus.Binding).init(self.allocator);
        defer bindings.deinit();
        for (graph.nodes.items) |node| {
            if (node.worktree_path.len != 0 and !std.mem.eql(u8, node.worktree_path, path))
                bindings.append(.{ .path = node.worktree_path }) catch {};
        }
        const selected = [_][]const u8{path};
        self.model.invalidateWorktreeNotices(.worktrees_changed);
        self.queueWorktreeReclaim(
            graph.project.path,
            &selected,
            bindings.items,
            .{ .allow_reclaim = true, .confirm_each_reclaim = false },
            true,
            false,
            .offer,
        ) catch |err| {
            self.reportWorktreeError("Unable to start worktree reclaim", err);
            return;
        };
    }

    fn moveWorktreeSelection(self: *App, delta: i32) void {
        const inspection = self.worktree_inspection orelse return;
        if (inspection.entries.items.len == 0) return;
        var index: usize = 0;
        if (self.selected_worktree_path.len != 0) {
            for (inspection.entries.items, 0..) |entry, i| {
                if (std.mem.eql(u8, entry.path, self.selected_worktree_path)) {
                    index = i;
                    break;
                }
            }
        }
        const count = inspection.entries.items.len;
        var offset: usize = 0;
        while (offset < count) : (offset += 1) {
            const next = @mod(@as(i32, @intCast(index)) + delta * @as(i32, @intCast(offset + 1)) +
                @as(i32, @intCast(count)), @as(i32, @intCast(count)));
            if (WorktreeStatus.actionSelectable(inspection.entries.items[@intCast(next)])) {
                _ = self.selectWorktreeRow(inspection.entries.items[@intCast(next)].path);
                self.ensureWorktreeVisible(@intCast(next));
                return;
            }
        }
    }

    fn ensureWorktreeVisible(self: *App, index: usize) void {
        const client = logicalClientRect(self.window.hwnd, self.dpi);
        const loop_count = if (self.model.graph) |graph| graph.nodes.items.len else 0;
        const top = Sidebar.worktreeRowTopForModel(&self.model, loop_count, index) - self.sidebar_scroll;
        const bottom = top + 34;
        const viewport_top = Tokens.header_height;
        const viewport_bottom = GraphCanvas.sidebarBottom(client.bottom, self.workspace_controls, self.surface);
        if (top < viewport_top) self.sidebar_scroll -= viewport_top - top;
        if (bottom > viewport_bottom) self.sidebar_scroll += bottom - viewport_bottom;
        self.clampSidebarScroll();
    }

    fn clampSidebarScroll(self: *App) void {
        const client = logicalClientRect(self.window.hwnd, self.dpi);
        if (client.right == 0 or client.bottom == 0) {
            self.sidebar_scroll = 0;
            return;
        }
        const inspection = if (self.worktree_inspection) |*value| value else null;
        self.sidebar_scroll = Sidebar.clampScroll(
            self.sidebar_scroll,
            Sidebar.maxScroll(
                &self.model,
                inspection,
                GraphCanvas.sidebarBottom(client.bottom, self.workspace_controls, self.surface),
                &self.sidebar_state,
            ),
        );
    }

    fn handleAction(self: *App, action: InputRouter.Action) void {
        switch (action) {
            .reconnect => {
                self.client.reconnect();
            },
            .open_folder => self.openFolder(),
            .create_node => self.createNode(),
            .open_node => self.openSelectedNode(),
            .stop_node => self.stopSelectedNode(),
            .send_node => self.sendSelectedNode(),
            .edit_node => if (self.selectedEdgeIndex()) |edge| self.editSelectedEdge(edge) else self.editSelectedNode(),
            .rename_selected => self.editSelectedNode(),
            .delete_selected => if (self.selectedEdgeIndex()) |edge| self.deleteEdge(edge) else self.deleteSelectedNode(),
            .create_edge => self.createEdge(),
            .jump_next => self.jumpToNode(),
            .command_palette => self.jumpToNode(),
            .next_identity => self.navigateIdentity(1, false),
            .previous_identity => self.navigateIdentity(-1, false),
            .quick_chat => self.createQuickChat(),
            .rename_quick_chat => self.renameSelectedQuickChat(),
            .delete_quick_chat => self.deleteSelectedQuickChat(),
            .settings => self.openSettings(),
            .product_settings => self.openProductSettings(),
            .clone_repository => self.cloneRepository(),
            .cancel_clone => self.cancelClone(),
            .remote_repository => self.addRemoteRepository(),
            .codespace_repository => self.addCodespaceRepository(),
            .onboarding => {
                const initial_backend = if (self.product_settings) |settings| settings.default_backend else "claudeCode";
                const backend = Onboarding.show(self.window.hwnd, self.allocator, initial_backend) catch {
                    self.setStatus("Unable to show onboarding");
                    return;
                };
                self.applyOnboardingBackend(backend);
            },
            .cycle_attention => {
                if (self.surface == .workspace) self.openNextAttention() else self.selectNextAttention();
                self.syncAccessibility();
                _ = c.InvalidateRect(self.window.hwnd, null, 0);
            },
            .inspect_worktrees => self.inspectWorktrees(),
            .reclaim_worktrees => self.reclaimWorktrees(),
            .reveal_worktree => self.revealSelectedWorktree(),
            .edit_worktree_policy => self.editWorktreePolicy(),
            .save_worktree_policy => self.saveCurrentWorktreePolicy(),
            .worktree_next => self.moveWorktreeSelection(1),
            .worktree_previous => self.moveWorktreeSelection(-1),
            .focus_terminal_a => if (self.workspace) |workspace| workspace.focus(0),
            .focus_terminal_b => if (self.workspace) |workspace| workspace.focus(1),
            .select_next => {
                if (self.surface == .workspace) return self.stepOpenLoop(true);
                self.selectNextNode();
                _ = c.InvalidateRect(self.window.hwnd, null, 0);
            },
            .select_previous => {
                if (self.surface == .workspace) return self.stepOpenLoop(false);
                const graph = self.model.graph orelse return;
                if (graph.nodes.items.len == 0) return;
                const current = self.model.selected_index orelse 0;
                const previous = if (current == 0) graph.nodes.items.len - 1 else current - 1;
                if (!self.model.setSelectedIndex(previous)) return;
                _ = self.selectNodeIndex(previous);
                _ = c.InvalidateRect(self.window.hwnd, null, 0);
            },
            .new_tab => if (self.workspace) |workspace| workspace.newTab() catch {
                self.smoke_workspace_action_failed = true;
                self.setStatus("Unable to create tab");
            },
            .close_tab => if (self.workspace) |workspace| workspace.closeFocusedPane() catch {
                self.smoke_workspace_action_failed = true;
                self.setStatus("Unable to close tab");
            },
            .split_horizontal => if (self.workspace) |workspace| workspace.splitFocused(.horizontal) catch {
                self.smoke_workspace_action_failed = true;
                self.setStatus("Unable to split workspace");
            },
            .split_vertical => if (self.workspace) |workspace| workspace.splitFocused(.vertical) catch {
                self.smoke_workspace_action_failed = true;
                self.setStatus("Unable to split workspace");
            },
            .focus_next_pane => if (self.workspace) |workspace| workspace.focusNextPane(),
            .focus_previous_pane => if (self.workspace) |workspace| workspace.focusPreviousPane(),
            .select_previous_tab => if (self.workspace) |workspace| workspace.selectPreviousTab(),
            .select_next_tab => if (self.workspace) |workspace| workspace.selectNextTab(),
            .show_graph => self.showInGraph(finishShowGraphNative, syncAccessibility),
            .toggle_rail => {
                self.workspace_controls.apply(.toggle_rail);
                self.layoutWorkspace();
                _ = c.InvalidateRect(self.window.hwnd, null, 0);
                self.setStatus(if (self.workspace_controls.rail_visible) "Workspace rail shown" else "Workspace rail hidden");
            },
            .toggle_panel => {
                self.toggleWorkspacePanelState();
                self.layoutWorkspace();
                _ = c.InvalidateRect(self.window.hwnd, null, 0);
                self.setStatus(if (self.workspace_controls.panel_visible) "Workspace panel shown" else "Workspace panel hidden");
            },
            .toggle_activity => {
                self.workspace_controls.apply(.toggle_activity);
                _ = c.InvalidateRect(self.window.hwnd, null, 0);
                self.setStatus(if (self.workspace_controls.activity_enabled) "Activity enabled" else "Activity disabled");
            },
            .zoom_out, .zoom_in => {
                const client = logicalClientRect(self.window.hwnd, self.dpi);
                const bounds = inputBounds(client.right, client.bottom, self.workspace_controls).canvas;
                self.canvas.zoomBy(
                    @divTrunc(bounds.left + bounds.right, 2),
                    @divTrunc(bounds.top + bounds.bottom, 2),
                    if (action == .zoom_in) 1.1 else 0.9,
                );
                _ = c.InvalidateRect(self.window.hwnd, null, 0);
            },
            .actual_size => {
                self.canvas.actualSize();
                _ = c.InvalidateRect(self.window.hwnd, null, 0);
            },
            .fit_canvas => {
                const client = logicalClientRect(self.window.hwnd, self.dpi);
                const bounds = inputBounds(client.right, client.bottom, self.workspace_controls).canvas;
                const content = GraphCanvas.contentSize(&self.model, self.surface);
                self.canvas.fit(
                    .{ .left = bounds.left, .top = bounds.top, .right = bounds.right, .bottom = bounds.bottom },
                    content.width,
                    content.height,
                );
                _ = c.InvalidateRect(self.window.hwnd, null, 0);
            },
            .none => {},
        }
    }

    fn showInGraph(self: *App, comptime finish_native: fn (*App) void, comptime publish: fn (*App) void) void {
        self.surface = .project;
        self.workspace_controls.panel_visible = false;
        self.workspace_controls.apply(.show_graph);
        finish_native(self);
        publish(self);
    }

    fn finishShowGraphNative(self: *App) void {
        self.layoutWorkspace();
        self.layoutEmptyStateControls();
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
    }

    fn navigateIdentity(self: *App, offset: isize, attention_only: bool) void {
        const graph = self.model.graph orelse return;
        if (graph.nodes.items.len == 0) return;
        var items: [256]Navigation.Item = undefined;
        const count = @min(graph.nodes.items.len, items.len);
        for (graph.nodes.items[0..count], 0..) |node, index| {
            var attention = false;
            for (self.model.attention.items) |candidate| {
                if (std.mem.eql(u8, candidate.id, node.id)) {
                    attention = true;
                    break;
                }
            }
            items[index] = .{
                .identity = .{ .project_path = graph.project.path, .node_id = node.id },
                .title = node.title,
                .attention = attention,
            };
        }
        const selected = if (attention_only)
            self.navigation_cursor.nextAttention(items[0..count])
        else if (offset > 0)
            self.navigation_cursor.next(items[0..count])
        else
            self.navigation_cursor.previous(items[0..count]);
        const item = selected orelse return;
        for (graph.nodes.items, 0..) |node, index| {
            if (std.mem.eql(u8, node.id, item.identity.node_id)) {
                if (!self.selectNodeIndex(index)) return;
                self.openSelectedNode();
                _ = c.InvalidateRect(self.window.hwnd, null, 0);
                return;
            }
        }
    }

    fn onWorkspaceKey(context: ?*anyopaque, key: usize, ctrl: bool, shift: bool) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(context.?));
        app.handleWorkspaceKeyRoute(App.dispatchWorkspaceKey(key, ctrl, shift, true));
    }

    fn dispatchWorkspaceKey(key: usize, ctrl: bool, shift: bool, terminal_context_active: bool) WorkspaceKeyRoute {
        if (terminal_context_active and ctrl and shift) {
            if (key == 'C') return .copy_terminal_selection;
            if (key == 'V') return .paste_clipboard_text;
        }
        return .{ .action = InputRouter.keyAction(key, ctrl, shift) };
    }

    fn handleWorkspaceKeyRoute(self: *App, route: WorkspaceKeyRoute) void {
        switch (route) {
            .action => |action| self.handleAction(action),
            .copy_terminal_selection => self.copyTerminalSelection(),
            .paste_clipboard_text => self.pasteClipboardText(),
        }
    }

    fn copyTerminalSelection(self: *App) void {
        const workspace = self.workspace orelse return;
        const selection = workspace.copySelection(self.allocator) catch |err| {
            std.log.warn("Unable to read terminal selection for clipboard: {s}", .{@errorName(err)});
            self.setStatus("Unable to copy terminal selection");
            return;
        } orelse {
            self.setStatus("No terminal selection to copy");
            return;
        };
        defer self.allocator.free(selection);
        Clipboard.writeText(self.window.hwnd, self.allocator, selection) catch |err| {
            std.log.warn("Unable to write terminal selection to Windows clipboard: {s}", .{@errorName(err)});
            self.setStatus("Unable to copy terminal selection");
            return;
        };
        self.setStatus("Terminal selection copied");
    }

    fn pasteClipboardText(self: *App) void {
        const workspace = self.workspace orelse return;
        const text = Clipboard.readText(self.window.hwnd, self.allocator) catch |err| {
            std.log.warn("Unable to read Windows clipboard for terminal paste: {s}", .{@errorName(err)});
            self.setStatus("Unable to paste clipboard text");
            return;
        };
        defer self.allocator.free(text);
        workspace.pasteText(text) catch |err| {
            std.log.warn("Unable to paste clipboard text into terminal: {s}", .{@errorName(err)});
            self.setStatus(terminalPasteFailureStatus(err));
        };
    }

    fn toggleWorkspacePanelState(self: *App) void {
        self.workspace_controls.apply(.toggle_panel);
        if (self.workspace_controls.panel_visible) {
            self.workspace_is_quick_chat = false;
            self.surface = .workspace;
        } else if (self.surface == .workspace) {
            self.surface = .project;
        }
    }

    fn toggleWorkspaceDetailPanelState(self: *App) void {
        self.workspace_controls.panel_visible = !self.workspace_controls.panel_visible;
        if (self.workspace_controls.panel_visible) self.surface = .workspace;
    }

    fn toggleWorkspaceDetailPanel(self: *App) void {
        self.toggleWorkspaceDetailPanelState();
        self.layoutWorkspace();
        self.syncAccessibility();
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
        self.setStatus(if (self.workspace_controls.panel_visible) "Loop detail panel expanded" else "Loop detail panel collapsed");
    }

    fn layoutWorkspace(self: *App) void {
        var client: c.RECT = undefined;
        if (c.GetClientRect(self.window.hwnd, &client) == 0) return;
        const restore_header = self.header_focus != null and c.GetFocus() == self.window.hwnd;
        const previous_transition = self.header_focus_transition;
        self.header_focus_transition = previous_transition or restore_header;
        defer {
            if (restore_header) _ = c.SetFocus(self.window.hwnd);
            self.header_focus_transition = previous_transition;
        }
        if (self.workspace) |workspace| {
            const full_workspace = self.surface == .workspace;
            const activity_height = if (self.workspace_controls.activity_enabled) physicalCoordinate(Tokens.activity_strip_height, self.dpi) else 0;
            const panel_height = if (full_workspace)
                @max(0, client.bottom - physicalCoordinate(Tokens.header_height + Tokens.loop_bar_height, self.dpi) - activity_height)
            else if (self.workspace_controls.panel_visible)
                physicalCoordinate(Tokens.workspace_height, self.dpi)
            else
                0;
            // When the workspace has no visible presence at all (neither the full surface nor the
            // picture-in-picture panel), collapse it instead of resizing: Workspace.resize()
            // re-syncs pane topology, which unconditionally re-focuses the active pane's terminal
            // surface even at a degenerate (zero) size. Collapsing skips that re-focus entirely and
            // hands native Win32 keyboard focus back to the main window so a hidden terminal can't
            // keep holding OS focus/foreground away from the rest of the app's chrome.
            if (!full_workspace and panel_height == 0) {
                workspace.collapse();
                _ = c.SetForegroundWindow(self.window.hwnd);
                _ = c.SetFocus(self.window.hwnd);
                return;
            }
            workspace.resize(
                if (self.workspace_controls.rail_visible) physicalCoordinate(Tokens.sidebar_width, self.dpi) else 0,
                if (full_workspace) physicalCoordinate(Tokens.header_height + Tokens.loop_bar_height, self.dpi) else @max(0, client.bottom - panel_height),
                @max(0, client.right - (if (self.workspace_controls.rail_visible) physicalCoordinate(Tokens.sidebar_width, self.dpi) else 0) -
                    (if (full_workspace and self.workspace_controls.panel_visible) physicalCoordinate(Tokens.loop_detail_width, self.dpi) else 0)),
                panel_height,
            );
        }
    }

    fn status(self: *const App) []const u8 {
        if (self.workspace_recovery.text()) |message| return message;
        if (self.workspace_identity_blocked) return workspace_restart_message;
        if (self.status_override.len != 0) return self.status_override;
        return self.client.statusText();
    }

    fn connectionFailureVisible(self: *const App) bool {
        return self.client.connectionState() == .disconnected or
            (envFlag("GRAPHCODE_UIA_GATE") and envFlag("GRAPHCODE_UIA_CONNECTION_FAILURE"));
    }

    fn createEmptyStateControls(self: *App) void {
        self.empty_open_folder_button = createButton(
            self.window.hwnd,
            "Open Folder...",
            MainWindow.empty_open_folder_id,
        );
        self.empty_global_overview_button = createButton(
            self.window.hwnd,
            "New Loop",
            MainWindow.empty_new_loop_id,
        );
        self.layoutEmptyStateControls();
    }

    fn layoutEmptyStateControls(self: *App) void {
        const client = logicalClientRect(self.window.hwnd, self.dpi);
        if (client.right == 0 or client.bottom == 0) return;
        const graph = self.model.graph;
        const is_quick_chats = self.surface == .quick_chats;
        const is_overview = self.surface == .overview;
        const is_empty = if (is_quick_chats)
            self.model.quick_chats.items.len == 0
        else if (is_overview)
            self.model.graphs.items.len == 0
        else if (graph) |value|
            value.nodes.items.len == 0
        else
            true;
        const is_global = if (graph) |value| value.project.isGlobal() else false;
        const content_left = if (self.workspace_controls.rail_visible) Tokens.sidebar_width else 0;
        const content_right = client.right;
        const x = content_left + @divTrunc((content_right - content_left) - 220, 2);
        const bounds = GraphCanvas.renderBounds(client.right, client.bottom, self.workspace_controls);
        const center_offset: i32 = if (!is_quick_chats and !is_overview and graph == null) -70 else -60;
        const y = bounds.top + @divTrunc(bounds.bottom - bounds.top, 2) + center_offset + 106;
        if (self.empty_open_folder_button != null) {
            _ = c.ShowWindow(
                self.empty_open_folder_button,
                if (is_empty and !is_quick_chats and (is_overview or graph == null or is_global)) c.SW_SHOW else c.SW_HIDE,
            );
            _ = c.SetWindowPos(
                self.empty_open_folder_button,
                null,
                physicalCoordinate(x, self.dpi),
                physicalCoordinate(y, self.dpi),
                physicalCoordinate(220, self.dpi),
                physicalCoordinate(32, self.dpi),
                c.SWP_NOZORDER | c.SWP_NOACTIVATE,
            );
        }
        if (self.empty_global_overview_button != null) {
            setButtonText(self.empty_global_overview_button, if (is_quick_chats) "New Chat" else "New Loop");
            const show_primary = is_quick_chats or is_overview or
                (self.surface == .project and graph != null and !is_global);
            const primary_x = if (is_empty) x else content_right - 140;
            const primary_y = if (is_empty)
                y + (if (is_global or is_overview) @as(i32, 42) else @as(i32, 0))
            else
                Tokens.header_height + 14;
            _ = c.ShowWindow(
                self.empty_global_overview_button,
                if (show_primary) c.SW_SHOW else c.SW_HIDE,
            );
            _ = c.SetWindowPos(
                self.empty_global_overview_button,
                null,
                physicalCoordinate(primary_x, self.dpi),
                physicalCoordinate(primary_y, self.dpi),
                physicalCoordinate(if (is_empty) 220 else 120, self.dpi),
                physicalCoordinate(32, self.dpi),
                c.SWP_NOZORDER | c.SWP_NOACTIVATE,
            );
        }
    }

    fn createButton(parent: c.HWND, text: []const u8, id: usize) c.HWND {
        const raw = std.unicode.utf8ToUtf16LeAlloc(std.heap.c_allocator, text) catch return null;
        defer std.heap.c_allocator.free(raw);
        const wide = std.heap.c_allocator.allocSentinel(u16, raw.len, 0) catch return null;
        defer std.heap.c_allocator.free(wide);
        @memcpy(wide[0..raw.len], raw);
        const button = c.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("BUTTON").ptr,
            wide.ptr,
            c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_PUSHBUTTON,
            0,
            0,
            220,
            32,
            parent,
            controlId(id),
            c.GetModuleHandleW(null),
            null,
        );
        AppFont.apply(button, AppFont.control_size, false);
        return button;
    }

    fn setButtonText(button: c.HWND, text: []const u8) void {
        const raw = std.unicode.utf8ToUtf16LeAlloc(std.heap.c_allocator, text) catch return;
        defer std.heap.c_allocator.free(raw);
        const wide = std.heap.c_allocator.allocSentinel(u16, raw.len, 0) catch return;
        defer std.heap.c_allocator.free(wide);
        @memcpy(wide[0..raw.len], raw);
        _ = c.SetWindowTextW(button, wide.ptr);
    }

    fn controlId(value: usize) c.HMENU {
        @setRuntimeSafety(false);
        return @ptrFromInt(value);
    }

    fn updateNativeChrome(self: *App, refresh: MainWindow.MenuRefresh) void {
        self.update_lock.lock();
        const update_checking = self.update_thread != null and !self.update_done;
        self.update_lock.unlock();
        var recent_menu: []MainWindow.RecentFolderItem = &.{};
        if (self.model.recent_projects.items.len != 0) {
            recent_menu = self.allocator.alloc(MainWindow.RecentFolderItem, self.model.recent_projects.items.len) catch &.{};
        }
        defer if (recent_menu.len != 0) self.allocator.free(recent_menu);
        if (recent_menu.len != 0) {
            for (self.model.recent_projects.items, 0..) |project, index| {
                recent_menu[index] = .{ .path = project.path, .name = project.name };
            }
        }
        var workspace_items: []MainWindow.WorkspaceItem = &.{};
        if (self.workspace_list) |list| {
            workspace_items = self.allocator.alloc(MainWindow.WorkspaceItem, list.items.len) catch &.{};
            if (workspace_items.len != 0) {
                for (list.items, 0..) |workspace, index| {
                    workspace_items[index] = .{
                        .name = workspace.name,
                        .is_current = self.workspace_identity_valid and std.mem.eql(u8, workspace.identity, self.workspace_identity),
                    };
                }
            }
        }
        defer if (workspace_items.len != 0) self.allocator.free(workspace_items);
        const has_jump_target = for (self.model.graphs.items) |graph| {
            if (graph.nodes.items.len != 0) break true;
        } else false;
        const can_navigate_loops = if (self.model.graph) |graph|
            MainWindow.loopNavigationAvailable(graph.nodes.items.len, self.model.selectedIndex())
        else
            false;
        const can_create_edge = if (self.model.graph) |graph| graph.nodes.items.len >= 2 else false;
        const can_cycle_tabs = if (self.workspace) |workspace| workspace.tabCount() > 1 else false;
        const can_cycle_panes = if (self.workspace) |workspace| blk: {
            const tab = workspace.layout.selected() orelse break :blk false;
            break :blk tab.panes.items.len > 1;
        } else false;
        MainWindow.updateMenu(self.window.hwnd, .{
            .has_project = self.model.graph != null,
            .can_worktrees = if (self.model.graph) |graph| graph.project.isLocalFilesystem() and !self.worktreeProviderBusy() else false,
            .worktree_dialog_open = self.worktree_dialog != null,
            .worktree_row_selected = self.worktreeRowSelected(),
            .has_jump_target = has_jump_target,
            .can_navigate_loops = can_navigate_loops,
            .can_create_edge = can_create_edge,
            .has_selected_loop = self.model.selected() != null,
            .has_workspace = self.workspace != null and self.model.graph != null,
            .can_cycle_tabs = can_cycle_tabs,
            .can_cycle_panes = can_cycle_panes,
            .has_attention = self.model.attentionCount() != 0,
            .can_close_tab = if (self.workspace) |workspace| workspace.tabCount() > 1 else false,
            .sidebar_visible = self.workspace_controls.rail_visible,
            .workspace_visible = self.workspace_controls.panel_visible,
            .activity_visible = self.workspace_controls.activity_enabled,
            .update_checking = update_checking,
            .recent_folders = recent_menu,
            .workspaces = workspace_items,
        }, refresh);
        self.layoutEmptyStateControls();
    }

    fn setStatus(self: *App, value: []const u8) void {
        Diagnostics.record(self.allocator, "status", value);
        const copy = self.allocator.dupe(u8, value) catch return;
        self.replaceStatus(copy);
        if (self.accessibility) |*provider| {
            self.syncAccessibility();
            provider.announce(self.status_override, if (std.mem.indexOf(u8, value, "failed") != null or
                std.mem.indexOf(u8, value, "Unable") != null or
                std.mem.indexOf(u8, value, "blocked") != null) .@"error" else .status) catch {};
        }
    }

    fn setWorktreeState(self: *App, value: []const u8) void {
        const copy = self.allocator.dupe(u8, value) catch return;
        if (self.worktree_state.len != 0) self.allocator.free(self.worktree_state);
        self.worktree_state = copy;
        self.syncAccessibility();
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
    }

    fn setWorktreeStateWithReceipts(self: *App, value: []const u8) void {
        if (self.worktree_reclaim_receipts.len == 0) {
            self.setWorktreeState(value);
            return;
        }
        const combined = std.fmt.allocPrint(
            self.allocator,
            "{s}\n{s}",
            .{ value, self.worktree_reclaim_receipts },
        ) catch {
            self.setWorktreeState(value);
            return;
        };
        defer self.allocator.free(combined);
        self.setWorktreeState(combined);
    }

    fn replaceStatus(self: *App, value: []u8) void {
        self.workspace_recovery.active = false;
        if (self.status_override.len != 0) self.allocator.free(self.status_override);
        self.status_override = value;
        self.syncAccessibility();
    }

    fn setIngressError(self: *App, value: []const u8) void {
        const copy = self.allocator.dupe(u8, value) catch return;
        if (self.ingress_error.len != 0) self.allocator.free(self.ingress_error);
        self.ingress_error = copy;
        self.syncAccessibility();
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
    }

    fn clearIngressError(self: *App) void {
        if (self.ingress_error.len != 0) self.allocator.free(self.ingress_error);
        self.ingress_error = &.{};
        self.syncAccessibility();
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
    }

    fn headerPresentation(self: *const App) GraphCanvas.Header {
        var header = GraphCanvas.Header{ .attention_count = self.model.attentionCount() };
        if (self.surface == .workspace and self.workspace_is_quick_chat) {
            header.context = "Quick Chat workspace";
            if (self.selected_quick_chat) |index| if (index < self.model.quick_chats.items.len) {
                header.title = self.model.quick_chats.items[index].title;
            };
        } else if (self.surface == .overview) {
            header.title = "Graph";
            header.context = "All projects";
        } else if (self.surface == .quick_chats) {
            header.title = "Quick Chats";
        } else if (self.model.currentGraph()) |graph| {
            header.title = graph.project.name;
            header.context = if (self.surface == .workspace)
                (if (graph.project.isRemote()) "Workspace / Remote" else if (graph.project.isGlobal()) "Workspace / Global" else "Workspace / Local folder")
            else
                (if (graph.project.isRemote()) "Remote" else if (graph.project.isGlobal()) "Global" else "Local folder");
        }
        if (GraphCanvas.loopPanelHasContent(&self.model, self.surface, self.workspace_is_quick_chat)) {
            header.panel_visible = self.workspace_controls.panel_visible;
        }
        if (self.worktreeHeaderOwner()) |owner| {
            header.notice = owner.worktree_notice.?.observation.?.summary;
            header.notice_name = owner.project.name;
            for (self.model.graphs.items) |graph| {
                if (graph.worktree_notice) |record| {
                    if (record.state() == .notice and !std.mem.eql(u8, graph.project.path, owner.project.path))
                        header.notice_extra_folders += 1;
                }
            }
        }
        return header;
    }

    fn worktreeHeaderOwner(self: *const App) ?*const GraphModel.GraphSummary {
        var owner: ?*const GraphModel.GraphSummary = null;
        var owner_bytes: u64 = 0;
        for (self.model.graphs.items) |*graph| {
            const record = graph.worktree_notice orelse continue;
            if (record.state() != .notice) continue;
            const observation = record.observation orelse continue;
            if (owner == null or observation.size.bytes > owner_bytes) {
                owner = graph;
                owner_bytes = observation.size.bytes;
            }
        }
        return owner;
    }

    fn currentWorktreeInspection(self: *const App) ?*const WorktreeStatus.Inspection {
        const graph = self.model.graph orelse return null;
        const inspection = if (self.worktree_inspection) |*value| value else return null;
        if (graph.project.isGlobal() or !std.mem.eql(u8, graph.project.path, inspection.project_path)) return null;
        return inspection;
    }

    fn headerLayout(self: *const App) GraphCanvas.HeaderLayout {
        return self.headerPresentation().layout(logicalClientRect(self.window.hwnd, self.dpi).right);
    }

    fn headerOwnsFocus(self: *const App) bool {
        return self.header_focus != null and c.GetFocus() == self.window.hwnd and
            MainWindow.keyOwnerEligible(self.window.hwnd, self.window.hwnd);
    }

    fn syncHeaderFocus(self: *App) void {
        if (self.header_focus) |action| {
            if (self.headerLayout().bounds(action) == null) self.header_focus = self.headerLayout().step(action, false);
        }
        if (self.accessibility) |*provider| {
            provider.syncHeaderFocus(if (self.headerOwnsFocus()) GraphCanvas.headerIdentity(self.header_focus.?) else null);
        }
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
    }

    fn focusHeader(self: *App, action: GraphCanvas.HeaderAction) bool {
        const hwnd = self.window.hwnd;
        if (!MainWindow.keyOwnerEligible(hwnd, hwnd) or self.headerLayout().bounds(action) == null) return false;
        if (self.header_focus == null) self.header_return_focus = c.GetFocus();
        self.header_focus = action;
        _ = c.SetFocus(hwnd);
        if (c.GetFocus() != hwnd) {
            self.header_focus = null;
            self.setStatus("Unable to focus window toolbar");
            return false;
        }
        self.syncHeaderFocus();
        return true;
    }

    fn leaveHeader(self: *App, restore: bool) void {
        const target = self.header_return_focus;
        self.header_focus = null;
        self.header_return_focus = null;
        if (restore) {
            if (MainWindow.keyOwnerEligible(self.window.hwnd, target) and target != self.window.hwnd) {
                _ = c.SetFocus(target);
                if (c.GetFocus() != target) self.setStatus("Unable to restore keyboard focus");
            } else if (self.workspace) |workspace| {
                if (self.surface == .workspace or self.workspace_controls.panel_visible)
                    workspace.focusRestoredPane() catch self.setStatus("Unable to restore selected terminal focus");
            }
        }
        self.syncHeaderFocus();
    }

    fn onShellKey(context: ?*anyopaque, key: usize, ctrl: bool, shift: bool, alt: bool) bool {
        const self: *App = @ptrCast(@alignCast(context orelse return false));
        if (MainWindow.workspaceCycleDirection(key, ctrl, shift, alt)) |direction| {
            self.cycleWorkspace(direction);
            return true;
        }
        return onHeaderKey(context, key, ctrl, shift, alt);
    }

    fn onHeaderKey(context: ?*anyopaque, key: usize, ctrl: bool, shift: bool, alt: bool) bool {
        const self: *App = @ptrCast(@alignCast(context orelse return false));
        const focused = self.headerOwnsFocus();
        const command = InputRouter.headerKey(key, ctrl, shift, alt, focused);
        const layout = self.headerLayout();
        switch (command) {
            .none => return false,
            .enter => {
                const action = layout.step(null, shift) orelse return false;
                return self.focusHeader(action);
            },
            .exit => self.leaveHeader(true),
            .next, .previous, .first, .last => {
                const current = if (command == .first or command == .last) null else self.header_focus;
                const action = layout.step(current, command == .previous or command == .last) orelse return false;
                _ = self.focusHeader(action);
            },
            .activate => {
                const action = self.header_focus orelse return false;
                if (!self.invokeHeader(action)) self.setStatus("Toolbar action is no longer available");
                self.syncHeaderFocus();
            },
        }
        return true;
    }

    fn invokeHeader(self: *App, action: GraphCanvas.HeaderAction) bool {
        if (self.headerLayout().bounds(action) == null) {
            self.setStatus("Toolbar action is no longer available");
            return false;
        }
        switch (action) {
            .review_attention => {
                if (self.model.attention_entries.items.len == 0) return false;
                self.selectNextAttention();
                const graph = self.model.currentGraph() orelse return false;
                const index = self.model.selectedIndex() orelse return false;
                if (index >= graph.nodes.items.len) return false;
                const is_attention = for (self.model.attention_entries.items) |entry| {
                    if (std.mem.eql(u8, entry.project_path, graph.project.path) and
                        std.mem.eql(u8, entry.node.id, graph.nodes.items[index].id)) break true;
                } else false;
                if (!is_attention) return false;
                const path = self.allocator.dupe(u8, graph.project.path) catch {
                    self.setStatus("Unable to open attention loop");
                    return false;
                };
                defer self.allocator.free(path);
                self.openLoopFromAccessibility(path, index);
            },
            .inspect_worktrees => {
                if (self.worktreeHeaderOwner()) |owner| {
                    if (!self.model.selectProject(owner.project.path)) return false;
                }
                self.inspectWorktrees();
            },
            .jump => self.jumpToNode(),
            .toggle_panel => self.toggleWorkspaceDetailPanel(),
        }
        self.syncAccessibility();
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
        return true;
    }

    fn syncAccessibility(self: *App) void {
        const provider = if (self.accessibility) |*value| value else return;
        self.syncAccessibilityTo(provider, logicalClientRect(self.window.hwnd, self.dpi));
        self.syncHeaderFocus();
    }

    fn syncAccessibilityTo(self: *App, provider: anytype, client: c.RECT) void {
        var elements = std.array_list.Managed(Accessibility.DynamicElement).init(self.allocator);
        defer elements.deinit();
        var owned_identities = std.array_list.Managed([]u8).init(self.allocator);
        defer {
            for (owned_identities.items) |value| self.allocator.free(value);
            owned_identities.deinit();
        }
        const canvas_bounds = inputBounds(client.right, client.bottom, self.workspace_controls).canvas;
        const canvas_rect = c.RECT{
            .left = canvas_bounds.left,
            .top = canvas_bounds.top,
            .right = canvas_bounds.right,
            .bottom = canvas_bounds.bottom,
        };
        const sidebar_bottom = GraphCanvas.sidebarBottom(client.bottom, self.workspace_controls, self.surface);
        provider.syncCanvasBounds((AccessibilityBounds{ .logical = canvas_rect }).physicalRect(self.dpi));
        const current_inspection = self.currentWorktreeInspection();
        var sidebar_rows = Sidebar.appendRows(
            self.allocator,
            &self.model,
            current_inspection,
            self.sidebar_scroll,
            &self.sidebar_state,
        ) catch return;
        defer sidebar_rows.deinit(self.allocator);
        const header = self.headerPresentation();
        const header_layout = header.layout(client.right);
        for (GraphCanvas.header_actions) |action| {
            const logical_bounds = header_layout.bounds(action) orelse continue;
            const bounds = (AccessibilityBounds{ .logical = logical_bounds }).physicalRect(self.dpi);
            const name = header.label(self.allocator, action) catch return;
            owned_identities.append(name) catch {
                self.allocator.free(name);
                return;
            };
            elements.append(.{
                .identity = GraphCanvas.headerIdentity(action),
                .name = name,
                .parent = 1,
                .eligible = true,
                .left = bounds.left,
                .top = bounds.top,
                .right = bounds.right,
                .bottom = bounds.bottom,
            }) catch return;
        }
        if (self.surface == .project) if (GraphCanvas.projectWorktreeChip(&self.model)) |summary| {
            const graph = self.model.currentGraph() orelse return;
            const name = if (summary.reclaimable != 0)
                std.fmt.allocPrint(self.allocator, "{d} worktrees, {d} reclaimable", .{ summary.total, summary.reclaimable })
            else
                std.fmt.allocPrint(self.allocator, "{d} worktree{s}", .{ summary.total, if (summary.total == 1) "" else "s" });
            const owned_name = name catch return;
            self.appendAccessibilityElement(
                &elements,
                &owned_identities,
                "project-worktree-chip",
                graph.project.path,
                owned_name,
                4,
                .{ .logical = GraphCanvas.projectWorktreeChipBounds(canvas_rect) },
                false,
                true,
            ) catch {
                self.allocator.free(owned_name);
                return;
            };
            owned_identities.append(owned_name) catch {
                self.allocator.free(owned_name);
                return;
            };
        };

        for (sidebar_rows.items) |row| {
            const bounds = clipSidebarAccessibilityBounds(
                .{ .left = 12, .top = row.top - 3, .right = 232, .bottom = row.top + 23 },
                sidebar_bottom,
            );
            switch (row.kind) {
                .local_heading => self.appendAccessibilityElement(&elements, &owned_identities, "sidebar-section", "local", "Local Projects", 1, .{ .logical = bounds }, false, false) catch return,
                .remote_heading => self.appendAccessibilityElement(&elements, &owned_identities, "sidebar-section", "remote", "Remote Repositories", 1, .{ .logical = bounds }, false, false) catch return,
                .project => {
                    const project = self.model.recent_projects.items[row.index];
                    self.appendAccessibilityElement(&elements, &owned_identities, "project", project.path, project.name, 1, .{ .logical = bounds }, false, false) catch return;
                },
                .open_project => if (row.project_path) |path| if (self.model.graphFor(path)) |graph| {
                    self.appendAccessibilityElement(&elements, &owned_identities, "open-project", path, graph.project.name, 1, .{ .logical = bounds }, self.model.selected_project_path != null and std.mem.eql(u8, self.model.selected_project_path.?, path), false) catch return;
                    const new_bounds = clipSidebarAccessibilityBounds(
                        .{ .left = 174, .top = row.top, .right = 198, .bottom = row.top + 24 },
                        sidebar_bottom,
                    );
                    self.appendAccessibilityElement(&elements, &owned_identities, "project-new-loop", path, "New Loop", 1, .{ .logical = new_bounds }, false, false) catch return;
                    if (row.has_children) {
                        const disclosure_bounds = clipSidebarAccessibilityBounds(
                            .{ .left = 198, .top = row.top, .right = 220, .bottom = row.top + 24 },
                            sidebar_bottom,
                        );
                        self.appendAccessibilityElement(
                            &elements,
                            &owned_identities,
                            "project-disclosure",
                            path,
                            if (self.sidebar_state.isProjectCollapsed(path)) "Expand project" else "Collapse project",
                            1,
                            .{ .logical = disclosure_bounds },
                            false,
                            false,
                        ) catch return;
                    }
                },
                .loop => if (row.project_path) |path| if (self.model.graphFor(path)) |graph| {
                    if (row.index < graph.nodes.items.len) {
                        const node = graph.nodes.items[row.index];
                        const key = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ path, node.id }) catch return;
                        defer self.allocator.free(key);
                        self.appendAccessibilityElement(&elements, &owned_identities, "loop", key, node.title, 2, .{ .logical = bounds }, self.model.selected_node_id != null and std.mem.eql(u8, self.model.selected_node_id.?, node.id), false) catch return;
                        if (row.has_children) {
                            const disclosure_bounds = clipSidebarAccessibilityBounds(
                                .{ .left = 198, .top = row.top, .right = 220, .bottom = row.top + 24 },
                                sidebar_bottom,
                            );
                            self.appendAccessibilityElement(
                                &elements,
                                &owned_identities,
                                "loop-disclosure",
                                key,
                                if (self.sidebar_state.isNodeExpanded(node.id)) "Collapse loop children" else "Expand loop children",
                                2,
                                .{ .logical = disclosure_bounds },
                                false,
                                false,
                            ) catch return;
                        }
                    }
                },
                .worktree => if (self.worktree_dialog) |dialog| {
                    if (current_inspection == null or !std.mem.eql(u8, dialog.project_path, current_inspection.?.project_path)) continue;
                    if (row.index < dialog.rows.items.len) {
                        const worktree = dialog.rows.items[row.index];
                        const name = WorktreeStatus.rowPresentation(self.allocator, worktree.entry) catch return;
                        self.appendAccessibilityElement(&elements, &owned_identities, "worktree", worktree.entry.path, name, 3, .{ .logical = bounds }, worktree.selected, WorktreeStatus.actionSelectable(worktree.entry)) catch {
                            self.allocator.free(name);
                            return;
                        };
                        owned_identities.append(name) catch {
                            self.allocator.free(name);
                            return;
                        };
                    }
                },
                .quick_chat_overview => {
                    self.appendAccessibilityElement(&elements, &owned_identities, "quick-chats-header", "quick-chats", "Quick Chats", 1, .{ .logical = bounds }, self.surface == .quick_chats, false) catch return;
                    const new_bounds = clipSidebarAccessibilityBounds(
                        .{ .left = 174, .top = row.top, .right = 198, .bottom = row.top + 24 },
                        sidebar_bottom,
                    );
                    self.appendAccessibilityElement(&elements, &owned_identities, "quick-chat-new", "quick-chats", "New Chat", 1, .{ .logical = new_bounds }, false, false) catch return;
                    if (self.model.quick_chats.items.len != 0) {
                        const disclosure_bounds = clipSidebarAccessibilityBounds(
                            .{ .left = 198, .top = row.top, .right = 220, .bottom = row.top + 24 },
                            sidebar_bottom,
                        );
                        self.appendAccessibilityElement(
                            &elements,
                            &owned_identities,
                            "quick-chats-disclosure",
                            "quick-chats",
                            if (self.sidebar_state.chats_collapsed) "Expand Quick Chats" else "Collapse Quick Chats",
                            1,
                            .{ .logical = disclosure_bounds },
                            false,
                            false,
                        ) catch return;
                    }
                },
                .quick_chat => if (row.index < self.model.quick_chats.items.len) {
                    const chat = self.model.quick_chats.items[row.index];
                    self.appendAccessibilityElement(&elements, &owned_identities, "quick-chat-row", chat.id, chat.title, 1, .{ .logical = bounds }, false, false) catch return;
                },
                else => {},
            }
        }
        if (self.surface == .workspace and self.workspace_is_quick_chat) if (self.selected_quick_chat) |chat_index| {
            if (chat_index < self.model.quick_chats.items.len) {
                const chat = self.model.quick_chats.items[chat_index];
                const identity = std.fmt.allocPrint(self.allocator, "quick-chat-workspace:{s}", .{chat.id}) catch return;
                owned_identities.append(identity) catch {
                    self.allocator.free(identity);
                    return;
                };
                const workspace_bounds = (AccessibilityBounds{ .logical = .{
                    .left = canvas_rect.left,
                    .top = inputBounds(client.right, client.bottom, self.workspace_controls).workspace_top,
                    .right = canvas_rect.right,
                    .bottom = client.bottom,
                } }).physicalRect(self.dpi);
                elements.append(.{
                    .identity = identity,
                    .name = "Quick Chat terminal workspace",
                    .parent = 4,
                    .selected = true,
                    .eligible = false,
                    .invokable = false,
                    .left = workspace_bounds.left,
                    .top = workspace_bounds.top,
                    .right = workspace_bounds.right,
                    .bottom = workspace_bounds.bottom,
                }) catch return;
            }
        };
        if (self.model.attention_entries.items.len != 0) {
            const section = Sidebar.sidebarSectionBottom(&self.model, current_inspection, &self.sidebar_state);
            self.appendAccessibilityElement(&elements, &owned_identities, "needs-you-header", "needs-you", "Needs you", 1, .{ .logical = .{ .left = 12, .top = section + 4, .right = 232, .bottom = section + 28 } }, false, true) catch return;
            for (self.model.attention_entries.items[0..@min(self.model.attention_entries.items.len, 4)], 0..) |entry, index| {
                const row_offset = @as(i32, @intCast(index)) * 34;
                const identity = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entry.project_path, entry.node.id }) catch return;
                defer self.allocator.free(identity);
                const name = std.fmt.allocPrint(self.allocator, "{s} - {s}", .{ entry.node.title, Sidebar.attentionReason(entry.node) }) catch return;
                owned_identities.append(name) catch {
                    self.allocator.free(name);
                    return;
                };
                self.appendAccessibilityElement(&elements, &owned_identities, "needs-you-row", identity, name, 1, .{ .logical = .{ .left = 18, .top = section + 30 + row_offset, .right = 232, .bottom = section + 60 + row_offset } }, self.model.selected_node_id != null and std.mem.eql(u8, self.model.selected_node_id.?, entry.node.id), true) catch return;
                self.appendAccessibilityElement(
                    &elements,
                    &owned_identities,
                    "needs-you-stop",
                    identity,
                    "Stop loop",
                    1,
                    .{ .logical = Sidebar.needsYouStopBounds(&self.model, current_inspection, &self.sidebar_state, self.sidebar_scroll, index) },
                    false,
                    true,
                ) catch return;
            }
        }
        if (self.model.activity.items.len != 0) {
            const section = Sidebar.sidebarSectionBottom(&self.model, current_inspection, &self.sidebar_state);
            const attention_rows = @min(self.model.attentionCount(), 4);
            const activity_top = section + 30 + (@as(i32, @intCast(attention_rows)) * 34) + 18;
            self.appendAccessibilityElement(&elements, &owned_identities, "activity-header", "activity", "Activity", 1, .{ .logical = .{ .left = 12, .top = activity_top, .right = 232, .bottom = activity_top + 24 } }, false, true) catch return;
            self.appendAccessibilityElement(
                &elements,
                &owned_identities,
                "activity-filter",
                "attention",
                if (self.sidebar_state.activity_attention_only) "Show all activity" else "Show attention-only activity",
                1,
                .{ .logical = Sidebar.activityFilterBounds(&self.model, current_inspection, &self.sidebar_state, self.sidebar_scroll) },
                false,
                true,
            ) catch return;
            const viewport = Sidebar.activityViewport(&self.model, &self.sidebar_state);
            for (0..viewport.visible_count) |visible_index| {
                const activity_index = Sidebar.activityEventAtVisible(&self.model, &self.sidebar_state, visible_index) orelse break;
                const event = self.model.activity.items[activity_index];
                const identity = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ event.project_path, event.node_id }) catch return;
                defer self.allocator.free(identity);
                self.appendAccessibilityElement(
                    &elements,
                    &owned_identities,
                    "activity-row",
                    identity,
                    event.title,
                    1,
                    .{ .logical = Sidebar.activityCardBounds(&self.model, current_inspection, &self.sidebar_state, self.sidebar_scroll, visible_index) },
                    false,
                    true,
                ) catch return;
            }
            self.appendAccessibilityElement(&elements, &owned_identities, "activity-control", "scroll-left", "Scroll activity left", 1, .{ .logical = Sidebar.activityControlBounds(&self.model, current_inspection, &self.sidebar_state, self.sidebar_scroll, .left) }, false, true) catch return;
            self.appendAccessibilityElement(&elements, &owned_identities, "activity-control", "scroll-right", "Scroll activity right", 1, .{ .logical = Sidebar.activityControlBounds(&self.model, current_inspection, &self.sidebar_state, self.sidebar_scroll, .right) }, false, true) catch return;
        }
        if (self.ingress_error.len != 0) {
            const bounds = (AccessibilityBounds{ .logical = Sidebar.errorFooterRect(client.bottom) }).physicalRect(self.dpi);
            elements.append(.{
                .identity = "sidebar-error-footer:ingress",
                .name = self.ingress_error,
                .parent = 1,
                .selected = false,
                .eligible = false,
                .invokable = false,
                .left = bounds.left,
                .top = bounds.top,
                .right = bounds.right,
                .bottom = bounds.bottom,
            }) catch return;
        }
        if (self.worktree_state.len != 0) {
            self.appendAccessibilityElement(
                &elements,
                &owned_identities,
                "worktree-loading",
                "inspection",
                self.worktree_state,
                4,
                .{ .logical = GraphCanvas.worktreeActivityBounds(canvas_rect) },
                false,
                false,
            ) catch return;
            elements.items[elements.items.len - 1].invokable = false;
        }
        switch (self.surface) {
            .project, .workspace => if (self.model.graph) |graph| {
                if (self.model.open_composite_id) |parent_id| {
                    const back_name = std.fmt.allocPrint(self.allocator, "Back to {s}", .{graph.project.name}) catch return;
                    owned_identities.append(back_name) catch {
                        self.allocator.free(back_name);
                        return;
                    };
                    self.appendAccessibilityElement(
                        &elements,
                        &owned_identities,
                        "composite-back",
                        parent_id,
                        back_name,
                        4,
                        .{ .logical = GraphCanvas.compositeBreadcrumbBounds(canvas_rect) },
                        false,
                        false,
                    ) catch return;
                }
                for (graph.nodes.items, 0..) |node, index| {
                    const bounds = GraphCanvas.nodeBounds(index, &self.canvas);
                    const key = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph.project.path, node.id }) catch return;
                    defer self.allocator.free(key);
                    self.appendAccessibilityElement(&elements, &owned_identities, "project-card", key, node.title, 4, .{ .logical = bounds }, self.model.selected_index == index, false) catch return;
                    if (GraphCanvas.hitTestAttentionAction(graph.nodes.items, graph.edges.items, bounds.right - 20, bounds.bottom - 12, &self.canvas) != null) {
                        self.appendAccessibilityElement(&elements, &owned_identities, "attention-action", key, GraphCanvas.attentionActionLabel(node), 4, .{ .logical = GraphCanvas.attentionActionBounds(bounds, &self.canvas) }, false, false) catch return;
                    }
                    if (GraphCanvas.hasReclaimOffer(node, current_inspection, self.kept_worktree_paths.items)) {
                        const offer = GraphCanvas.reclaimOfferBounds(bounds);
                        self.appendAccessibilityElement(&elements, &owned_identities, "reclaim", key, "Reclaim", 4, .{ .logical = offer.reclaim }, false, false) catch return;
                        self.appendAccessibilityElement(&elements, &owned_identities, "keep", key, "Keep", 4, .{ .logical = offer.keep }, false, false) catch return;
                    }
                }
                if (self.surface == .workspace) {
                    if (self.workspace) |workspace| {
                        const workspace_left = if (self.workspace_controls.rail_visible) Tokens.sidebar_width else 0;
                        const workspace_right = client.right - (if (self.workspace_controls.panel_visible) Tokens.loop_detail_width else 0);
                        const selected_index = self.model.selectedIndex() orelse 0;
                        const loop_bar = TerminalWorkspace.loopBarLayout(
                            workspace_left,
                            workspace_right,
                            selected_index >= graph.nodes.items.len or isResolvedLoopState(graph.nodes.items[selected_index].state),
                        );
                        if (!self.workspace_is_quick_chat) {
                            self.appendAccessibilityElement(&elements, &owned_identities, "workspace-toolbar", graph.project.path, header.title, 4, .{ .logical = header_layout.identity }, false, false) catch return;
                            elements.items[elements.items.len - 1].invokable = false;
                        }
                        self.appendAccessibilityElement(&elements, &owned_identities, "workspace-loop-bar", if (selected_index < graph.nodes.items.len) graph.nodes.items[selected_index].id else "none", "Selected loop workspace", 4, .{ .logical = loopBarRect(loop_bar.bar) }, false, false) catch return;
                        self.appendAccessibilityElement(&elements, &owned_identities, "workspace-show-graph", "show-graph", "Show in Graph", 4, .{ .logical = loopBarRect(loop_bar.show_graph) }, false, false) catch return;
                        if (loop_bar.stop) |stop| {
                            self.appendAccessibilityElement(&elements, &owned_identities, "workspace-stop", graph.nodes.items[selected_index].id, "Stop loop", 4, .{ .logical = loopBarRect(stop) }, false, false) catch return;
                        }
                        const panel_toggle = if (self.workspace_controls.panel_visible)
                            GraphCanvas.loopDetailCollapseBounds(client.right)
                        else
                            GraphCanvas.loopDetailExpandBounds(client.right);
                        self.appendAccessibilityElement(&elements, &owned_identities, "workspace-toggle-panel", "control", if (self.workspace_controls.panel_visible) "Collapse loop panel" else "Expand loop panel", 4, .{ .logical = panel_toggle }, false, true) catch return;
                        if (self.workspace_controls.panel_visible and selected_index < graph.nodes.items.len) {
                            const detail_left = client.right - Tokens.loop_detail_width;
                            const selected_node = graph.nodes.items[selected_index];
                            self.appendAccessibilityElement(&elements, &owned_identities, "workspace-detail-sparkline", selected_node.id, "Metric sparkline", 4, .{ .logical = .{ .left = detail_left + 18, .top = client.bottom - 102, .right = client.right - 18, .bottom = client.bottom - 70 } }, false, false) catch return;
                            if (selected_node.created_at != null) {
                                self.appendAccessibilityElement(&elements, &owned_identities, "workspace-detail-start", selected_node.id, "Start time", 4, .{ .logical = .{ .left = detail_left + 18, .top = client.bottom - 64, .right = client.right - 18, .bottom = client.bottom - 44 } }, false, false) catch return;
                            }
                            if (selected_node.token_usage) |tokens| {
                                const usage_name = std.fmt.allocPrint(self.allocator, "{d} tokens", .{tokens}) catch return;
                                owned_identities.append(usage_name) catch {
                                    self.allocator.free(usage_name);
                                    return;
                                };
                                self.appendAccessibilityElement(&elements, &owned_identities, "workspace-detail-usage", selected_node.id, usage_name, 4, .{ .logical = .{ .left = detail_left + 18, .top = client.bottom - 44, .right = client.right - 18, .bottom = client.bottom - 24 } }, false, false) catch return;
                            }
                        }
                        for (workspace.layout.tabs.items, 0..) |tab, tab_index| {
                            const tab_key = std.fmt.allocPrint(self.allocator, "{d}", .{tab_index}) catch return;
                            defer self.allocator.free(tab_key);
                            const tab_bounds = TerminalWorkspace.tabBounds(workspace.layout_origin_x, workspace.layout_origin_y, tab_index);
                            self.appendAccessibilityElement(&elements, &owned_identities, "workspace-tab", tab_key, if (tab.panes.items.len > 1) "Split tab" else if (tab_index == 0) "Agent tab" else "Shell tab", 4, .{ .physical = tab_bounds }, tab_index == workspace.layout.selected_tab, true) catch return;
                            const close_key = std.fmt.allocPrint(self.allocator, "{d}", .{tab_index}) catch return;
                            defer self.allocator.free(close_key);
                            self.appendAccessibilityElement(&elements, &owned_identities, "workspace-tab-close", close_key, "Close tab", 4, .{ .physical = .{ .left = tab_bounds.right - 24, .top = tab_bounds.top, .right = tab_bounds.right, .bottom = tab_bounds.bottom } }, false, workspace.canCloseTab()) catch return;
                        }
                        for ([_][]const u8{ "New Tab", "Split Right", "Split Down" }, 0..) |label, control_index| {
                            const control_bounds = TerminalWorkspace.chromeControlBounds(workspace.layout_origin_x, workspace.layout_origin_y, workspace.layout_width, control_index);
                            const kind = if (control_index == 0) "workspace-new-tab" else if (control_index == 1) "workspace-split-right" else "workspace-split-down";
                            self.appendAccessibilityElement(&elements, &owned_identities, kind, "control", label, 4, .{ .physical = control_bounds }, false, true) catch return;
                        }
                    }
                }
            },
            .overview => for (self.model.graphs.items, 0..) |graph, graph_index| {
                if (GraphCanvas.overviewWorktreeNotice(&graph)) |presentation| {
                    const label = presentation.label(self.allocator) catch return;
                    owned_identities.append(label) catch {
                        self.allocator.free(label);
                        return;
                    };
                    const bounds = GraphCanvas.overviewLaneCaption(&self.model, graph_index, canvas_rect, &self.canvas).notice.?;
                    self.appendAccessibilityElement(&elements, &owned_identities, GraphCanvas.overview_worktree_notice_kind, graph.project.path, label, 4, .{ .logical = bounds }, false, true) catch return;
                }
                for (graph.nodes.items, 0..) |node, node_index| {
                    const bounds = GraphCanvas.overviewCardBounds(&self.model, graph_index, node_index, canvas_rect, &self.canvas);
                    const key = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph.project.path, node.id }) catch return;
                    defer self.allocator.free(key);
                    self.appendAccessibilityElement(&elements, &owned_identities, "overview-card", key, node.title, 4, .{ .logical = bounds }, false, false) catch return;
                }
            },
            .quick_chats => for (self.model.quick_chats.items, 0..) |chat, index| {
                self.appendAccessibilityElement(&elements, &owned_identities, "quick-chat-card", chat.id, chat.title, 4, .{ .logical = GraphCanvas.quickChatCardBounds(index, canvas_rect, &self.canvas) }, false, false) catch return;
            },
        }
        const canvas_alert = if (self.ingress_error.len != 0)
            self.ingress_error
        else if (self.connectionFailureVisible())
            GraphCanvas.connection_failure_message
        else
            "";
        if (canvas_alert.len != 0 and self.surface != .workspace) {
            const identity = self.allocator.dupe(
                u8,
                if (self.ingress_error.len != 0) "canvas-alert:ingress" else "canvas-alert:connection",
            ) catch return;
            owned_identities.append(identity) catch {
                self.allocator.free(identity);
                return;
            };
            const bounds = (AccessibilityBounds{ .logical = GraphCanvas.inlineAlertBounds(canvas_rect) }).physicalRect(self.dpi);
            elements.append(.{
                .identity = identity,
                .name = canvas_alert,
                .parent = 4,
                .selected = false,
                .eligible = false,
                .invokable = false,
                .left = bounds.left,
                .top = bounds.top,
                .right = bounds.right,
                .bottom = bounds.bottom,
            }) catch return;
        }
        if (self.workspace_list) |list| {
            for (list.items, 0..) |workspace, index| {
                const identity = std.fmt.allocPrint(self.allocator, "workspace-switch:{s}", .{workspace.path}) catch return;
                owned_identities.append(identity) catch {
                    self.allocator.free(identity);
                    return;
                };
                const row_top: i32 = 34 + @as(i32, @intCast(index * 30));
                const bounds = (AccessibilityBounds{ .logical = .{ .left = 250, .top = row_top, .right = 500, .bottom = row_top + 28 } }).physicalRect(self.dpi);
                elements.append(.{
                    .identity = identity,
                    .name = workspace.name,
                    .parent = 21,
                    .selected = self.workspace_identity_valid and std.mem.eql(u8, workspace.identity, self.workspace_identity),
                    .eligible = self.workspace_identity_valid,
                    .invokable = self.workspace_identity_valid,
                    .left = bounds.left,
                    .top = bounds.top,
                    .right = bounds.right,
                    .bottom = bounds.bottom,
                }) catch return;
            }
        }
        const policy = if (self.worktree_dialog) |dialog| dialog.policy else WorktreeStatus.Policy{};
        provider.syncElements(self.status(), elements.items, policy, .{
            .available = if (self.model.graph) |graph| graph.project.isLocalFilesystem() else false,
            .dialog_open = self.worktree_dialog != null,
            .row_selected = self.worktreeRowSelected(),
            .busy = self.worktree_inspection_thread != null or self.worktree_reclaim_thread != null,
        });
    }

    fn appendAccessibilityElement(
        self: *App,
        elements: *std.array_list.Managed(Accessibility.DynamicElement),
        owned_identities: *std.array_list.Managed([]u8),
        kind: []const u8,
        key: []const u8,
        name: []const u8,
        parent: c_int,
        coordinates: AccessibilityBounds,
        selected: bool,
        eligible: bool,
    ) !void {
        const bounds = coordinates.physicalRect(self.dpi);
        const identity = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ kind, key });
        errdefer self.allocator.free(identity);
        try owned_identities.append(identity);
        try elements.append(.{
            .identity = identity,
            .name = name,
            .parent = parent,
            .selected = selected,
            .eligible = eligible,
            .invokable = parent != 3,
            .left = bounds.left,
            .top = bounds.top,
            .right = bounds.right,
            .bottom = bounds.bottom,
        });
    }

    fn resolveOverviewWorktreeNotice(self: *const App, allocator: std.mem.Allocator, payload: usize) !?[]u8 {
        if (self.surface != .overview) return null;
        var project_path: ?[]const u8 = null;
        for (self.model.graphs.items) |graph| {
            if (GraphCanvas.overviewWorktreeNotice(&graph) == null) continue;
            const identity = try GraphCanvas.overviewWorktreeNoticeIdentity(allocator, graph.project.path);
            defer allocator.free(identity);
            if (Accessibility.worktreeIdentityPayload(identity) != payload) continue;
            if (project_path != null) return error.AmbiguousWorktreeNotice;
            project_path = graph.project.path;
        }
        return if (project_path) |path| try allocator.dupe(u8, path) else null;
    }

    fn applyUiaDynamicInvoke(self: *App, payload: usize) bool {
        var target: ?UiaDynamicTarget = null;
        const static_targets = [_]struct { identity: []const u8, target: UiaDynamicTarget }{
            .{ .identity = "sidebar-section:local", .target = .local_section },
            .{ .identity = "sidebar-section:remote", .target = .remote_section },
            .{ .identity = "quick-chats-header:quick-chats", .target = .quick_chats_header },
            .{ .identity = "quick-chats-disclosure:quick-chats", .target = .quick_chats_disclosure },
            .{ .identity = "quick-chat-new:quick-chats", .target = .new_quick_chat },
            .{ .identity = "needs-you-header:needs-you", .target = .needs_you_header },
            .{ .identity = "activity-header:activity", .target = .activity_header },
            .{ .identity = "activity-filter:attention", .target = .activity_filter },
            .{ .identity = "activity-control:scroll-left", .target = .activity_left },
            .{ .identity = "activity-control:scroll-right", .target = .activity_right },
            .{ .identity = "header-attention:needs-you", .target = .header_attention },
            .{ .identity = "header-worktree:worktrees", .target = .header_worktree },
            .{ .identity = "header-jump:jump", .target = .header_jump },
            .{ .identity = "header-toggle-panel:control", .target = .header_toggle_panel },
        };
        for (static_targets) |candidate| {
            if (Accessibility.worktreeIdentityPayload(candidate.identity) == payload) target = candidate.target;
        }
        const notice_project = self.resolveOverviewWorktreeNotice(self.allocator, payload) catch |err| {
            self.reportWorktreeError("Unable to resolve worktree notice", err);
            return false;
        };
        defer if (notice_project) |path| self.allocator.free(path);
        if (notice_project) |path| {
            if (target != null) return false;
            target = .{ .overview_worktree_notice = path };
        }
        if (self.surface == .project) if (self.model.currentGraph()) |graph| {
            if (GraphCanvas.projectWorktreeChip(&self.model) != null) {
                const identity = std.fmt.allocPrint(self.allocator, "project-worktree-chip:{s}", .{graph.project.path}) catch return false;
                defer self.allocator.free(identity);
                if (Accessibility.worktreeIdentityPayload(identity) == payload) {
                    if (target != null) return false;
                    target = .{ .project_worktree_chip = graph.project.path };
                }
            }
        };
        for (self.model.recent_projects.items) |project| {
            const identity = std.fmt.allocPrint(self.allocator, "project:{s}", .{project.path}) catch return false;
            defer self.allocator.free(identity);
            if (Accessibility.worktreeIdentityPayload(identity) == payload) {
                if (target != null) return false;
                target = .{ .recent_project = project.path };
            }
        }
        for (self.model.graphs.items) |graph| {
            const project_identity = std.fmt.allocPrint(self.allocator, "open-project:{s}", .{graph.project.path}) catch return false;
            defer self.allocator.free(project_identity);
            if (Accessibility.worktreeIdentityPayload(project_identity) == payload) {
                if (target != null) return false;
                target = .{ .open_project = graph.project.path };
            }
            const project_new_identity = std.fmt.allocPrint(self.allocator, "project-new-loop:{s}", .{graph.project.path}) catch return false;
            defer self.allocator.free(project_new_identity);
            if (Accessibility.worktreeIdentityPayload(project_new_identity) == payload) {
                if (target != null) return false;
                target = .{ .project_new_loop = graph.project.path };
            }
            const project_disclosure_identity = std.fmt.allocPrint(self.allocator, "project-disclosure:{s}", .{graph.project.path}) catch return false;
            defer self.allocator.free(project_disclosure_identity);
            if (Accessibility.worktreeIdentityPayload(project_disclosure_identity) == payload) {
                if (target != null) return false;
                target = .{ .project_disclosure = graph.project.path };
            }
            for (graph.nodes.items, 0..) |node, index| {
                const key = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph.project.path, node.id }) catch return false;
                defer self.allocator.free(key);
                const sidebar_identity = std.fmt.allocPrint(self.allocator, "loop:{s}", .{key}) catch return false;
                defer self.allocator.free(sidebar_identity);
                const overview_identity = std.fmt.allocPrint(self.allocator, "overview-card:{s}", .{key}) catch return false;
                defer self.allocator.free(overview_identity);
                const project_card_identity = std.fmt.allocPrint(self.allocator, "project-card:{s}", .{key}) catch return false;
                defer self.allocator.free(project_card_identity);
                const attention_identity = std.fmt.allocPrint(self.allocator, "attention-action:{s}", .{key}) catch return false;
                defer self.allocator.free(attention_identity);
                const reclaim_identity = std.fmt.allocPrint(self.allocator, "reclaim:{s}", .{key}) catch return false;
                defer self.allocator.free(reclaim_identity);
                const keep_identity = std.fmt.allocPrint(self.allocator, "keep:{s}", .{key}) catch return false;
                defer self.allocator.free(keep_identity);
                const loop_disclosure_identity = std.fmt.allocPrint(self.allocator, "loop-disclosure:{s}", .{key}) catch return false;
                defer self.allocator.free(loop_disclosure_identity);
                if (Accessibility.worktreeIdentityPayload(sidebar_identity) == payload or
                    Accessibility.worktreeIdentityPayload(overview_identity) == payload or
                    Accessibility.worktreeIdentityPayload(project_card_identity) == payload or
                    Accessibility.worktreeIdentityPayload(attention_identity) == payload)
                {
                    if (target != null) return false;
                    target = .{ .loop = .{ .project_path = graph.project.path, .node_id = node.id } };
                }
                if (Accessibility.worktreeIdentityPayload(reclaim_identity) == payload) {
                    if (target != null) return false;
                    target = .{ .reclaim_offer = .{ .path = node.worktree_path, .action = .reclaim } };
                }
                if (Accessibility.worktreeIdentityPayload(keep_identity) == payload) {
                    if (target != null) return false;
                    target = .{ .reclaim_offer = .{ .path = node.worktree_path, .action = .keep } };
                }
                if (Accessibility.worktreeIdentityPayload(loop_disclosure_identity) == payload) {
                    if (target != null) return false;
                    target = .{ .loop_disclosure = .{ .project_path = graph.project.path, .index = index } };
                }
            }
            if (self.model.isCompositeOpen()) if (self.model.graph) |active_graph| {
                if (self.model.open_composite_id) |parent_id| {
                    const identity = std.fmt.allocPrint(self.allocator, "composite-back:{s}", .{parent_id}) catch return false;
                    defer self.allocator.free(identity);
                    if (Accessibility.worktreeIdentityPayload(identity) == payload) {
                        if (target != null) return false;
                        target = .composite_back;
                    }
                }
                for (active_graph.nodes.items, 0..) |node, index| {
                    const key = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ active_graph.project.path, node.id }) catch return false;
                    defer self.allocator.free(key);
                    const identity = std.fmt.allocPrint(self.allocator, "project-card:{s}", .{key}) catch return false;
                    defer self.allocator.free(identity);
                    if (Accessibility.worktreeIdentityPayload(identity) == payload) {
                        if (target != null) return false;
                        target = .{ .active_loop = index };
                    }
                }
            };
        }
        for (self.model.quick_chats.items) |chat| {
            const identity = std.fmt.allocPrint(self.allocator, "quick-chat-card:{s}", .{chat.id}) catch return false;
            defer self.allocator.free(identity);
            if (Accessibility.worktreeIdentityPayload(identity) == payload) {
                if (target != null) return false;
                target = .{ .quick_chat = chat.id };
            }
            const row_identity = std.fmt.allocPrint(self.allocator, "quick-chat-row:{s}", .{chat.id}) catch return false;
            defer self.allocator.free(row_identity);
            if (Accessibility.worktreeIdentityPayload(row_identity) == payload) {
                if (target != null) return false;
                target = .{ .quick_chat = chat.id };
            }
        }
        const workspace_static = [_]struct { identity: []const u8, target: UiaDynamicTarget }{
            .{ .identity = "workspace-show-graph:show-graph", .target = .workspace_show_graph },
            .{ .identity = "workspace-new-tab:control", .target = .workspace_new_tab },
            .{ .identity = "workspace-split-right:control", .target = .workspace_split_right },
            .{ .identity = "workspace-split-down:control", .target = .workspace_split_down },
            .{ .identity = "workspace-toggle-panel:control", .target = .workspace_toggle_panel },
        };
        for (workspace_static) |candidate| {
            if (Accessibility.worktreeIdentityPayload(candidate.identity) == payload) {
                if (target != null) return false;
                target = candidate.target;
            }
        }
        if (self.surface == .workspace) {
            if (self.model.selectedNodeID()) |node_id| {
                const identity = std.fmt.allocPrint(self.allocator, "workspace-stop:{s}", .{node_id}) catch return false;
                defer self.allocator.free(identity);
                if (Accessibility.worktreeIdentityPayload(identity) == payload) {
                    if (target != null) return false;
                    target = .workspace_stop;
                }
            }
            if (self.workspace) |workspace| {
                for (workspace.layout.tabs.items, 0..) |_, tab_index| {
                    const key = std.fmt.allocPrint(self.allocator, "{d}", .{tab_index}) catch return false;
                    defer self.allocator.free(key);
                    const tab_identity = std.fmt.allocPrint(self.allocator, "workspace-tab:{s}", .{key}) catch return false;
                    defer self.allocator.free(tab_identity);
                    const close_identity = std.fmt.allocPrint(self.allocator, "workspace-tab-close:{s}", .{key}) catch return false;
                    defer self.allocator.free(close_identity);
                    if (Accessibility.worktreeIdentityPayload(tab_identity) == payload) {
                        if (target != null) return false;
                        target = .{ .workspace_tab = tab_index };
                    } else if (Accessibility.worktreeIdentityPayload(close_identity) == payload) {
                        if (target != null) return false;
                        target = .{ .workspace_tab_close = tab_index };
                    }
                }
            }
        }
        for (self.model.attention_entries.items, 0..) |entry, index| {
            const identity = std.fmt.allocPrint(self.allocator, "needs-you-row:{s}:{s}", .{ entry.project_path, entry.node.id }) catch return false;
            defer self.allocator.free(identity);
            if (Accessibility.worktreeIdentityPayload(identity) == payload) {
                if (target != null) return false;
                target = .{ .needs_you = index };
            }
            const stop_identity = std.fmt.allocPrint(self.allocator, "needs-you-stop:{s}:{s}", .{ entry.project_path, entry.node.id }) catch return false;
            defer self.allocator.free(stop_identity);
            if (Accessibility.worktreeIdentityPayload(stop_identity) == payload) {
                if (target != null) return false;
                target = .{ .needs_you_stop = index };
            }
        }
        for (self.model.activity.items, 0..) |event, index| {
            const identity = std.fmt.allocPrint(self.allocator, "activity-row:{s}:{s}", .{ event.project_path, event.node_id }) catch return false;
            defer self.allocator.free(identity);
            if (Accessibility.worktreeIdentityPayload(identity) == payload) {
                if (target != null) return false;
                target = .{ .activity = index };
            }
        }
        if (self.workspace_list) |list| {
            for (list.items, 0..) |workspace, workspace_index| {
                const workspace_identity = std.fmt.allocPrint(self.allocator, "workspace-switch:{s}", .{workspace.path}) catch return false;
                defer self.allocator.free(workspace_identity);
                if (Accessibility.worktreeIdentityPayload(workspace_identity) == payload) {
                    if (target != null) return false;
                    target = .{ .workspace_switch = workspace_index };
                }
            }
        }
        const resolved = target orelse return false;
        switch (resolved) {
            .overview_worktree_notice => |path| {
                const owner = self.model.graphFor(path) orelse {
                    self.setStatus("Worktree notice project is no longer open");
                    return false;
                };
                if (GraphCanvas.overviewWorktreeNotice(owner) == null or !self.selectProject(path)) {
                    self.setStatus("Worktree notice is no longer available");
                    return false;
                }
                const selected = self.model.graph orelse {
                    self.setStatus("Unable to select worktree notice project");
                    return false;
                };
                if (!std.mem.eql(u8, selected.project.path, path) or selected.project.isGlobal()) {
                    self.setStatus("Worktree notice project changed before inspection");
                    return false;
                }
                self.inspectWorktrees();
            },
            .project_worktree_chip => |path| {
                const graph = self.model.currentGraph() orelse return false;
                if (!std.mem.eql(u8, graph.project.path, path) or GraphCanvas.projectWorktreeChip(&self.model) == null)
                    return false;
                self.inspectWorktrees();
            },
            .local_section => self.sidebar_state.local_collapsed = !self.sidebar_state.local_collapsed,
            .remote_section => self.sidebar_state.remote_collapsed = !self.sidebar_state.remote_collapsed,
            .quick_chats_header => {
                self.surface = .quick_chats;
                self.workspace_controls.panel_visible = false;
                self.layoutWorkspace();
                self.layoutEmptyStateControls();
            },
            .quick_chats_disclosure => self.sidebar_state.chats_collapsed = !self.sidebar_state.chats_collapsed,
            .new_quick_chat => self.createQuickChat(),
            .needs_you_header => {},
            .needs_you => |index| {
                if (index >= self.model.attention_entries.items.len) return false;
                _ = self.chooseAttentionEntry(index);
            },
            .needs_you_stop => |index| {
                if (index >= self.model.attention_entries.items.len) return false;
                self.stopAttentionEntry(self.model.attention_entries.items[index]);
            },
            .activity_header => {},
            .activity_filter => Sidebar.toggleActivityAttentionOnly(&self.sidebar_state, &self.model),
            .activity_left => Sidebar.stepActivity(&self.sidebar_state, &self.model, .left),
            .activity_right => Sidebar.stepActivity(&self.sidebar_state, &self.model, .right),
            .activity => |index| if (index < self.model.activity.items.len) self.navigateToActivityEvent(self.model.activity.items[index]),
            .recent_project => |path| self.openProject(path),
            .open_project => |path| {
                if (self.selectProject(path)) {
                    self.surface = .project;
                    self.workspace_controls.panel_visible = false;
                    self.layoutWorkspace();
                    self.rebindWorkspace(path);
                    self.syncAccessibility();
                    _ = c.InvalidateRect(self.window.hwnd, null, 0);
                }
            },
            .project_new_loop => |path| {
                if (self.selectProject(path)) self.createNode();
            },
            .project_disclosure => |path| self.sidebar_state.toggleProject(path) catch return false,
            .loop => |loop| _ = self.activateLoop(loop.project_path, loop.node_id),
            .loop_disclosure => |loop| {
                const graph = self.model.graphFor(loop.project_path) orelse return false;
                if (loop.index >= graph.nodes.items.len) return false;
                self.sidebar_state.toggleNode(graph.nodes.items[loop.index].id) catch return false;
                if (self.sidebar_store) |*store| store.save(&self.sidebar_state) catch return false;
            },
            .active_loop => |index| {
                _ = self.selectNodeIndex(index);
                self.openSelectedNode();
            },
            .composite_back => self.closeCompositeGroup(),
            .reclaim_offer => |offer| switch (offer.action) {
                .reclaim => self.reclaimWorktreeOffer(offer.path),
                .keep => self.keepWorktreeOffer(offer.path),
            },
            .quick_chat => |id| {
                self.setStatus("Opening quick chat...");
                if (envFlag("GRAPHCODE_UIA_GATE")) {
                    for (self.model.quick_chats.items, 0..) |chat, index| {
                        if (!std.mem.eql(u8, chat.id, id)) continue;
                        self.selected_quick_chat = index;
                        self.workspace_is_quick_chat = true;
                        self.surface = .workspace;
                        self.workspace_controls.panel_visible = true;
                        self.layoutWorkspace();
                        self.layoutEmptyStateControls();
                        self.syncAccessibility();
                        break;
                    }
                } else {
                    self.client.sendOpenQuickChat(id);
                }
            },
            .workspace_show_graph => self.handleAction(.show_graph),
            .workspace_stop => self.stopSelectedNode(),
            .workspace_new_tab => self.handleAction(.new_tab),
            .workspace_split_right => self.handleAction(.split_horizontal),
            .workspace_split_down => self.handleAction(.split_vertical),
            .workspace_toggle_panel => self.toggleWorkspaceDetailPanel(),
            .workspace_tab => |index| if (self.workspace) |workspace| workspace.selectTab(index) catch return false,
            .workspace_tab_close => |index| if (self.workspace) |workspace| workspace.closeTab(index) catch return false,
            .workspace_switch => |index| {
                const list = self.workspace_list orelse return false;
                if (index >= list.items.len) return false;
                self.launchWorkspace(list.items[index].path);
            },
            .header_attention => return self.invokeHeader(.review_attention),
            .header_worktree => return self.invokeHeader(.inspect_worktrees),
            .header_jump => return self.invokeHeader(.jump),
            .header_toggle_panel => return self.invokeHeader(.toggle_panel),
        }
        self.clampSidebarScroll();
        self.syncAccessibility();
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
        return true;
    }

    fn openLoopFromAccessibility(self: *App, project_path: []const u8, index: usize) void {
        const graph = self.model.graphFor(project_path) orelse return;
        if (index >= graph.nodes.items.len) return;
        _ = self.activateLoop(project_path, graph.nodes.items[index].id);
    }

    fn acquireSingleInstance(self: *App) !void {
        const path = try WorkspaceLifecycle.currentPath(self.allocator);
        errdefer self.allocator.free(path);
        const identity = try WorkspaceLifecycle.pathIdentity(self.allocator, path);
        errdefer self.allocator.free(identity);
        const reservation = WorkspaceReservation.acquire(self.allocator, path) catch |err| switch (err) {
            error.WorkspaceInUse => return error.InstanceAlreadyRunning,
            else => return err,
        };
        self.workspace_reservation = reservation;
        self.workspace_path = path;
        self.workspace_identity = identity;
    }

    fn revalidateWorkspaceIdentity(self: *App) !void {
        self.workspace_identity_valid = false;
        self.workspace_identity_blocked = true;
        try MainWindow.invalidateWorkspaceIdentity(self.window.hwnd);
        if (self.workspace_reservation.handles[0] == null) return error.WorkspaceReservationMissing;
        const current = try WorkspaceLifecycle.currentPath(self.allocator);
        defer self.allocator.free(current);
        const identity = try WorkspaceLifecycle.pathIdentity(self.allocator, current);
        defer self.allocator.free(identity);
        if (!std.mem.eql(u8, self.workspace_identity, identity)) return error.WorkspaceRestartRequired;
        const key = try workspaceInstanceKey(self.allocator, self.workspace_path);
        defer self.allocator.free(key);
        try MainWindow.publishWorkspaceIdentity(self.window.hwnd, key);
        self.workspace_identity_valid = true;
        self.workspace_identity_blocked = false;
    }

    fn ensureWorkspaceIdentity(self: *App) bool {
        self.revalidateWorkspaceIdentity() catch {
            self.syncAccessibility();
            _ = c.InvalidateRect(self.window.hwnd, null, 0);
            return false;
        };
        return true;
    }

    fn refreshWorkspaceList(self: *App) bool {
        if (!self.ensureWorkspaceIdentity()) return false;
        self.reloadWorkspaceList() catch {
            self.setStatus("Workspace list could not be loaded");
            return false;
        };
        return true;
    }

    fn reloadWorkspaceList(self: *App) !void {
        const refreshed = try WorkspaceLifecycle.list(self.allocator);
        if (self.workspace_list) |*list| list.deinit(self.allocator);
        self.workspace_list = refreshed;
    }

    fn showWorkspaceText(self: *App, dialog_title: []const u8, labels: []const []const u8, initial: []const []const u8) ?NativeDialogs.Result {
        var lease = NativeForms.ModalLease.acquire() catch {
            self.setStatus("Close the current dialog before managing workspaces");
            return null;
        };
        defer lease.deinit();
        if (!self.ensureWorkspaceIdentity()) return null;
        return NativeDialogs.textWithDescription(
            self.window.hwnd,
            self.allocator,
            dialog_title,
            "Workspace names are normalized to lowercase letters, numbers, and hyphens.",
            labels,
            initial,
        ) catch {
            self.setStatus("Workspace dialog could not be completed");
            return null;
        };
    }

    fn createWorkspace(self: *App) void {
        const result = self.showWorkspaceText("New Workspace", &.{"Name"}, &.{""}) orelse return;
        defer {
            var owned = result;
            owned.deinit(self.allocator);
        }
        if (!self.ensureWorkspaceIdentity()) return;
        const home = std.process.getEnvVarOwned(self.allocator, "USERPROFILE") catch {
            self.setStatus("User profile could not be resolved");
            return;
        };
        defer self.allocator.free(home);
        var workspace = WorkspaceLifecycle.create(self.allocator, result.values[0], home) catch |err| {
            self.setStatus(switch (err) {
                error.EmptyName => "Workspace name is required",
                error.NameTooLong => "Workspace name is too long",
                error.NameTaken, error.PathAlreadyExists => "That workspace already exists",
                else => "Workspace could not be created",
            });
            return;
        };
        defer workspace.deinit(self.allocator);
        if (!self.refreshWorkspaceList()) return;
        self.launchWorkspace(workspace.path);
    }

    fn launchWorkspace(self: *App, path: []const u8) void {
        if (!self.ensureWorkspaceIdentity()) return;
        const opened = openWorkspaceWith(WorkspaceProcess, self.allocator, self.workspace_identity, path) catch |err| {
            self.setStatus(if (err == error.UnidentifiedWorkspaceWindow)
                "Close older GraphCode windows before opening another workspace"
            else
                "Workspace could not be opened or activated");
            return;
        };
        self.setStatus(switch (opened) {
            .current => "This workspace is already open",
            .restored => "Workspace activated",
            .launched => "Workspace launch requested",
        });
    }

    fn workspaceByName(self: *App, name: []const u8) ?WorkspaceLifecycle.Workspace {
        const list = self.workspace_list orelse return null;
        var found: ?WorkspaceLifecycle.Workspace = null;
        for (list.items) |workspace| {
            if (std.ascii.eqlIgnoreCase(workspace.name, name)) {
                if (found != null) return null;
                found = workspace;
            }
        }
        return found;
    }

    fn renameWorkspace(self: *App) void {
        const result = self.showWorkspaceText(
            "Rename Workspace",
            &.{ "Workspace", "New name" },
            &.{ "", "" },
        ) orelse return;
        defer {
            var owned = result;
            owned.deinit(self.allocator);
        }
        if (!self.refreshWorkspaceList()) return;
        const workspace = self.workspaceByName(result.values[0]) orelse {
            self.setStatus("Workspace was not found");
            return;
        };
        self.renameWorkspaceTo(workspace, result.values[1]);
    }

    fn renameWorkspaceTo(self: *App, workspace: WorkspaceLifecycle.Workspace, new_name: []const u8) void {
        const home = std.process.getEnvVarOwned(self.allocator, "USERPROFILE") catch {
            self.setStatus("User profile could not be resolved");
            return;
        };
        defer self.allocator.free(home);
        const name = WorkspaceLifecycle.validateName(self.allocator, new_name, home) catch {
            self.setStatus("Workspace name is invalid or already exists");
            return;
        };
        defer self.allocator.free(name);
        const destination = WorkspaceLifecycle.workspacePath(self.allocator, name, home) catch {
            self.setStatus("Workspace path could not be prepared");
            return;
        };
        defer self.allocator.free(destination);
        _ = mutateWorkspaceWith(WorkspaceMutationApi, self.allocator, self.window.hwnd, self.workspace_identity, workspace, .{ .rename = destination }) catch |err| {
            self.setStatus(workspaceMutationFailure(err));
            return;
        };
        if (!self.refreshWorkspaceList()) return;
        self.setStatus("Workspace renamed");
    }

    fn manageWorkspaces(self: *App) void {
        if (NativeForms.isModalActive()) {
            self.setStatus("Close the current dialog before managing workspaces");
            return;
        }
        if (!self.ensureWorkspaceIdentity()) return;
        const home = std.process.getEnvVarOwned(self.allocator, "USERPROFILE") catch {
            self.setStatus("User profile could not be resolved");
            return;
        };
        defer self.allocator.free(home);
        var known = WorkspaceLifecycle.managerListFromHome(self.allocator, home, self.workspace_path) catch {
            self.setStatus("Workspace manager list could not be loaded");
            return;
        };
        defer known.deinit(self.allocator);
        const windows = self.allocator.alloc(WorkspaceManager.WindowState, known.items.len) catch {
            self.setStatus("Workspace manager could not allocate window states");
            return;
        };
        defer self.allocator.free(windows);
        for (known.items, windows) |workspace, *state| {
            const key = workspaceInstanceKey(self.allocator, workspace.path) catch {
                state.* = .unavailable;
                continue;
            };
            defer self.allocator.free(key);
            state.* = workspaceManagerWindowState(WorkspaceProcess, key);
        }
        var model = WorkspaceManager.Model.init(self.allocator, known.items, self.workspace_identity, windows) catch {
            self.setStatus("Workspace manager could not capture the workspace list");
            return;
        };
        defer model.deinit();
        self.workspace_summary_work.start(&model) catch |err| {
            for (model.rows) |*row| if (!row.is_current) {
                row.summary = .{ .failed = if (err == error.OutOfMemory) .memory else .worker };
            };
        };
        var action = (WorkspaceManagerForm.show(self.window.hwnd, &model, &self.workspace_summary_work) catch {
            self.setStatus("Workspace manager could not be completed safely");
            return;
        }) orelse return;
        defer action.deinit(self.allocator);
        if (!self.validateManagerAction(action)) return;
        switch (action.kind) {
            .new => self.createWorkspace(),
            .open => {
                const target = action.target.?;
                if (std.mem.eql(u8, target.identity, self.workspace_identity)) {
                    self.launchWorkspace(target.path);
                    return;
                }
                // A closed target may still be reserved by a starting instance.
                const key = workspaceInstanceKey(self.allocator, target.path) catch {
                    self.setStatus("Workspace identity could not be resolved");
                    return;
                };
                defer self.allocator.free(key);
                const state = workspaceManagerWindowState(WorkspaceProcess, key);
                if (state == .unidentified or state == .unavailable) {
                    self.setStatus("Workspace window ownership could not be verified; close older windows before opening it");
                    return;
                }
                if (state == .closed) {
                    var reservation = WorkspaceReservation.acquire(self.allocator, target.path) catch |err| {
                        self.setStatus(workspaceMutationFailure(err));
                        return;
                    };
                    reservation.deinit();
                }
                self.launchWorkspace(target.path);
            },
            .rename => {
                const target = action.target.?;
                const dialog_title = std.fmt.allocPrint(self.allocator, "Rename Workspace - {s}", .{target.name}) catch {
                    self.setStatus("Workspace name could not be displayed");
                    return;
                };
                defer self.allocator.free(dialog_title);
                var result = self.showWorkspaceText(dialog_title, &.{"New name"}, &.{target.name}) orelse return;
                defer result.deinit(self.allocator);
                if (!self.validateManagerAction(action)) return;
                self.renameWorkspaceTo(target, result.values[0]);
            },
            .delete => {
                const target = action.target.?;
                // Revalidated once more here: the manager's own modal has closed since the
                // action was captured.
                if (!self.validateManagerAction(action)) return;
                self.deleteWorkspaceTarget(target);
            },
        }
    }

    fn validateManagerAction(self: *App, action: WorkspaceManager.Action) bool {
        if (NativeForms.isModalActive() or !self.workspace_summary_work.reap()) {
            self.setStatus("Workspace action is waiting for the manager to finish");
            return false;
        }
        if (!self.ensureWorkspaceIdentity()) return false;
        const default_path = WorkspaceLifecycle.defaultPath(self.allocator) catch {
            self.setStatus("Default workspace identity could not be resolved");
            return false;
        };
        defer self.allocator.free(default_path);
        const default_identity = WorkspaceLifecycle.pathIdentity(self.allocator, default_path) catch {
            self.setStatus("Default workspace identity could not be verified");
            return false;
        };
        defer self.allocator.free(default_identity);
        WorkspaceManager.validateTarget(self.allocator, action, self.workspace_identity, default_identity) catch |err| {
            self.setStatus(workspaceMutationFailure(err));
            return false;
        };
        if (action.target) |target| {
            var directory = std.fs.openDirAbsolute(target.path, .{}) catch {
                self.setStatus("The captured workspace directory is no longer available");
                return false;
            };
            directory.close();
        }
        return true;
    }

    fn deleteWorkspace(self: *App) void {
        const result = self.showWorkspaceText("Delete Workspace", &.{"Workspace"}, &.{""}) orelse return;
        defer {
            var owned = result;
            owned.deinit(self.allocator);
        }
        if (!self.refreshWorkspaceList()) return;
        const workspace = self.workspaceByName(result.values[0]) orelse {
            self.setStatus("Workspace was not found");
            return;
        };
        self.deleteWorkspaceTarget(workspace);
    }

    /// Shared by the menu path and the manager's Delete button so both get the same
    /// refusals, the same confirmation, and the same honest status.
    fn deleteWorkspaceTarget(self: *App, workspace: WorkspaceLifecycle.Workspace) void {
        const outcome = mutateWorkspaceWith(WorkspaceMutationApi, self.allocator, self.window.hwnd, self.workspace_identity, workspace, .delete) catch |err| {
            self.setStatus(workspaceMutationFailure(err));
            return;
        };
        switch (outcome) {
            .renamed => {},
            .cancelled => self.setStatus("Workspace deletion cancelled"),
            .torn_down => |value| {
                var report = value;
                defer report.deinit(self.allocator);
                consumeWorkspaceTeardownReportWith(WorkspaceTeardownPresentationApi, self, self.allocator, &self.workspace_recovery, &report);
            },
        }
    }

    fn cycleWorkspace(self: *App, direction: isize) void {
        if (NativeForms.isModalActive()) {
            self.setStatus("Close the current dialog before cycling workspaces");
            return;
        }
        if (!self.ensureWorkspaceIdentity()) return;
        const result = cycleWorkspaceWith(WorkspaceCycleApi, self.allocator, self.workspace_path, self.workspace_identity, direction) catch |err| {
            self.setStatus(workspaceCycleFailure(err));
            return;
        };
        self.setStatus(switch (result) {
            .no_other => "No other identified workspace is open",
            .current => "This workspace is already open",
            .restored => "Workspace activated",
        });
    }
};

const WorkspaceCycleResult = enum { no_other, current, restored };

fn cycleWorkspaceWith(comptime Api: type, allocator: std.mem.Allocator, current_path: []const u8, current_identity: []const u8, direction: isize) !WorkspaceCycleResult {
    const identity = try WorkspaceLifecycle.pathIdentity(allocator, current_path);
    defer allocator.free(identity);
    if (!std.mem.eql(u8, identity, current_identity)) return error.WorkspaceIdentityChanged;
    var list = try Api.list(allocator, current_path);
    defer list.deinit(allocator);
    for (list.items) |workspace| {
        if (std.mem.eql(u8, workspace.identity, current_identity)) break;
    } else return error.CurrentWorkspaceMissing;

    const running = try allocator.alloc(WorkspaceLifecycle.Workspace, list.items.len);
    defer allocator.free(running);
    var count: usize = 0;
    for (list.items) |workspace| {
        // The caller revalidates this instance's reservation and published identity.
        if (!std.mem.eql(u8, workspace.identity, current_identity)) {
            const key = try Api.instanceKey(allocator, workspace.path);
            defer allocator.free(key);
            const windows = try Api.windows(key);
            if (windows.unidentified) return error.UnidentifiedWorkspaceWindow;
            if (windows.target == null) continue;
        }
        running[count] = workspace;
        count += 1;
    }
    const next = workspaceCycleTarget(running[0..count], current_identity, direction) orelse return .no_other;
    const target = running[next];
    if (std.mem.eql(u8, target.identity, current_identity)) return .current;
    const key = try Api.instanceKey(allocator, target.path);
    defer allocator.free(key);
    const windows = try Api.windows(key);
    if (windows.unidentified) return error.UnidentifiedWorkspaceWindow;
    if (windows.target == null) return error.WorkspaceWindowNotFound;
    // Restore resolves the identity again; disappearance must never cold-open it.
    try Api.restore(key);
    return .restored;
}

fn workspaceCycleFailure(err: anyerror) []const u8 {
    return switch (err) {
        error.CurrentWorkspaceMissing => "The current workspace is not in the workspace list",
        error.WorkspaceIdentityChanged => workspace_restart_message,
        error.WorkspaceWindowNotFound => "The next workspace is no longer open",
        error.UnidentifiedWorkspaceWindow => "Close older or unidentified GraphCode windows before cycling workspaces",
        else => "Workspace cycling failed; the list or window identity could not be verified, or activation failed",
    };
}

fn workspaceCycleTarget(items: []const WorkspaceLifecycle.Workspace, current_identity: []const u8, direction: isize) ?usize {
    if (items.len < 2) return null;
    for (items, 0..) |workspace, index| {
        if (std.mem.eql(u8, workspace.identity, current_identity)) {
            const offset: usize = @intCast(@mod(direction, @as(isize, @intCast(items.len))));
            const remaining = items.len - index;
            return if (offset >= remaining) offset - remaining else index + offset;
        }
    }
    return null;
}

fn fallbackKeyAction(key: usize, ctrl: bool, shift: bool, alt: bool) InputRouter.Action {
    if (alt and (key == c.VK_PRIOR or key == c.VK_NEXT)) return .none;
    return switch (App.dispatchWorkspaceKey(key, ctrl, shift, false)) {
        .action => |action| action,
        .copy_terminal_selection, .paste_clipboard_text => InputRouter.keyAction(key, ctrl, shift),
    };
}

fn onDaemonFrame(
    context: ?*anyopaque,
    frame: [*]const u8,
    length: usize,
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(context.?));
    app.onFrame(frame[0..length]);
    _ = c.InvalidateRect(app.window.hwnd, null, 0);
}

fn onContextAction(context: ?*anyopaque, action: GraphContextMenu.Action, target: GraphContextMenu.Target) void {
    const app: *App = @ptrCast(@alignCast(context.?));
    app.handleContextAction(action, target);
}

fn onWindowMessage(
    context: ?*anyopaque,
    hwnd: c.HWND,
    message: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
    result: *c.LRESULT,
) callconv(.c) bool {
    const app: *App = @ptrCast(@alignCast(context.?));
    if (TrayModule.taskbar_created != 0 and message == TrayModule.taskbar_created) {
        app.tray.readd();
        if (!app.tray.added) app.setStatus("System tray unavailable; retrying");
        result.* = 0;
        return true;
    }
    if (MainWindow.restore_message != 0 and message == MainWindow.restore_message) {
        if (app.ensureWorkspaceIdentity()) restoreShellWindow(hwnd);
        result.* = 0;
        return true;
    }
    if (app.tray_test_hook_enabled and
        TrayModule.test_hook_message != 0 and
        message == TrayModule.test_hook_message)
    {
        if (wparam == TrayModule.test_hook_menu) {
            result.* = if (app.tray.menu) |menu| @intCast(@intFromPtr(menu)) else 0;
            return true;
        }
        const event: c.UINT = switch (wparam) {
            TrayModule.test_hook_open => @intCast(c.WM_LBUTTONDBLCLK),
            TrayModule.test_hook_context => @intCast(c.WM_CONTEXTMENU),
            else => {
                result.* = 0;
                return true;
            },
        };
        _ = c.PostMessageW(
            hwnd,
            TrayModule.notify_message,
            TrayModule.test_callback_wparam,
            TrayModule.testNotificationLParam(event),
        );
        result.* = 0;
        return true;
    }
    if (message == TrayModule.notify_message and TrayModule.callbackTargetsIcon(lparam)) {
        const event = TrayModule.notificationEvent(lparam);
        app.tray.observeTestCallback(
            event,
            app.tray_test_hook_enabled and wparam == TrayModule.test_callback_wparam,
        );
        if (event == c.WM_LBUTTONDBLCLK) {
            restoreShellWindow(hwnd);
        } else if (event == c.WM_RBUTTONUP or event == c.WM_CONTEXTMENU) {
            app.tray.showMenu();
        }
        result.* = 0;
        return true;
    }
    switch (message) {
        c.WM_GETOBJECT => if (app.accessibility) |*provider| {
            const object = provider.getObject(hwnd, wparam, lparam);
            if (object != 0) {
                result.* = object;
                return true;
            }
        },
        c.WM_INITMENUPOPUP => {
            if (@intFromPtr(c.GetSubMenu(c.GetMenu(hwnd), 3)) == wparam) {
                if (app.refreshWorkspaceList()) app.syncAccessibility();
            }
            app.updateNativeChrome(.popup_open);
            result.* = 0;
            return true;
        },
        c.WM_COMMAND => {
            if ((wparam & Accessibility.uia_dynamic_invoke_mask) == Accessibility.uia_dynamic_invoke_tag) {
                _ = app.applyUiaDynamicInvoke(wparam & Accessibility.uia_row_payload_mask);
                result.* = 0;
                return true;
            }
            if ((wparam & Accessibility.uia_selection_command_mask) == Accessibility.uia_selection_command_tag) {
                const operation = (wparam & Accessibility.uia_selection_operation_mask) >>
                    Accessibility.uia_selection_operation_shift;
                _ = app.applyUiaWorktreeSelection(
                    wparam & Accessibility.uia_row_payload_mask,
                    operation,
                );
                result.* = 0;
                return true;
            }
            const command_id: u16 = @truncate(wparam);
            if (command_id == @as(u16, @truncate(TrayModule.command_exit))) {
                app.exit_requested = true;
                app.update_cancel.store(true, .release);
                _ = c.EndMenu();
                app.tray.remove();
                c.ExitProcess(0);
            }
            if (command_id == @as(u16, @truncate(TrayModule.command_open))) {
                restoreShellWindow(hwnd);
                result.* = 0;
                return true;
            }
            const tray_command = @as(c.WPARAM, @intCast(@as(usize, @bitCast(wparam)) & 0xffff));
            if (tray_command == TrayModule.command_open) {
                restoreShellWindow(hwnd);
                result.* = 0;
                return true;
            }
            if (tray_command == TrayModule.command_exit) {
                app.exit_requested = true;
                app.update_cancel.store(true, .release);
                _ = c.EndMenu();
                app.tray.remove();
                c.ExitProcess(0);
            }
            switch (tray_command) {
                6 => app.inspectWorktrees(),
                7 => app.reclaimWorktrees(),
                8 => app.revealSelectedWorktree(),
                9 => app.editWorktreePolicy(),
                10 => app.saveCurrentWorktreePolicy(),
                12 => app.toggleAllowReclaim(),
                13 => app.toggleConfirmReclaim(),
                Accessibility.uia_open_overview_command => app.openGlobalOverview(),
                Accessibility.uia_open_quick_chats_command => {
                    app.surface = .quick_chats;
                    app.workspace_controls.panel_visible = false;
                    app.layoutWorkspace();
                    app.layoutEmptyStateControls();
                    app.syncAccessibility();
                    _ = c.InvalidateRect(hwnd, null, 0);
                },
                Accessibility.uia_primary_canvas_action_command => {
                    if (app.surface == .quick_chats) app.handleAction(.quick_chat) else app.handleAction(.create_node);
                },
                Accessibility.uia_zoom_out_command => {
                    const client = logicalClientRect(hwnd, app.dpi);
                    const bounds = inputBounds(client.right, client.bottom, app.workspace_controls).canvas;
                    app.canvas.zoomBy(@divTrunc(bounds.left + bounds.right, 2), @divTrunc(bounds.top + bounds.bottom, 2), 0.9);
                    app.syncAccessibility();
                    _ = c.InvalidateRect(hwnd, null, 0);
                },
                Accessibility.uia_actual_size_command => {
                    app.canvas.actualSize();
                    app.syncAccessibility();
                    _ = c.InvalidateRect(hwnd, null, 0);
                },
                Accessibility.uia_zoom_in_command => {
                    const client = logicalClientRect(hwnd, app.dpi);
                    const bounds = inputBounds(client.right, client.bottom, app.workspace_controls).canvas;
                    app.canvas.zoomBy(@divTrunc(bounds.left + bounds.right, 2), @divTrunc(bounds.top + bounds.bottom, 2), 1.1);
                    app.syncAccessibility();
                    _ = c.InvalidateRect(hwnd, null, 0);
                },
                Accessibility.uia_fit_command => {
                    const client = logicalClientRect(hwnd, app.dpi);
                    const bounds = inputBounds(client.right, client.bottom, app.workspace_controls).canvas;
                    const content = GraphCanvas.contentSize(&app.model, app.surface);
                    app.canvas.fit(
                        .{ .left = bounds.left, .top = bounds.top, .right = bounds.right, .bottom = bounds.bottom },
                        content.width,
                        content.height,
                    );
                    app.syncAccessibility();
                    _ = c.InvalidateRect(hwnd, null, 0);
                },
                Accessibility.uia_workspace_new_command => app.createWorkspace(),
                Accessibility.uia_workspace_rename_command => app.renameWorkspace(),
                Accessibility.uia_workspace_delete_command => app.deleteWorkspace(),
                else => if (wparam >= 1000 and wparam < 2000) {
                    _ = app.toggleWorktreeRow(@intCast(wparam - 1000));
                },
            }
            const id: usize = @intCast(@as(u16, @truncate(wparam)));
            if (id == MainWindow.empty_open_folder_id) {
                app.openFolder();
            } else if (id == MainWindow.empty_new_loop_id) {
                if (app.surface == .quick_chats) app.handleAction(.quick_chat) else app.handleAction(.create_node);
            } else if (MainWindow.isRecentFolderCommand(id)) {
                const recent_index = id - MainWindow.recent_folder_command_base;
                if (recent_index < app.model.recent_projects.items.len) {
                    app.openProject(app.model.recent_projects.items[recent_index].path);
                }
            } else if (id >= MainWindow.workspace_command_base and id <= MainWindow.workspace_command_limit) {
                const workspace_index = id - MainWindow.workspace_command_base;
                if (app.workspace_list) |list| {
                    if (workspace_index < list.items.len) app.launchWorkspace(list.items[workspace_index].path);
                }
            } else if (MainWindow.commandFromId(id)) |command| {
                switch (command) {
                    .open_folder => app.openFolder(),
                    .clone_repository => app.handleAction(.clone_repository),
                    .remote_repository => app.handleAction(.remote_repository),
                    .codespace_repository => app.handleAction(.codespace_repository),
                    .new_quick_chat => app.handleAction(.quick_chat),
                    .open_global_overview => app.openGlobalOverview(),
                    .worktrees => app.handleAction(.inspect_worktrees),
                    .reclaim_worktrees => app.handleAction(.reclaim_worktrees),
                    .reveal_worktree => app.handleAction(.reveal_worktree),
                    .edit_worktree_policy => app.handleAction(.edit_worktree_policy),
                    .save_worktree_policy => app.handleAction(.save_worktree_policy),
                    .exit => {
                        app.exit_requested = true;
                        app.update_cancel.store(true, .release);
                        app.tray.remove();
                        c.ExitProcess(0);
                    },
                    .jump_loop => app.handleAction(.jump_next),
                    .review_attention => app.handleAction(.cycle_attention),
                    .next_loop => app.handleAction(.select_next),
                    .previous_loop => app.handleAction(.select_previous),
                    .create_node => app.handleAction(.create_node),
                    .create_edge => app.handleAction(.create_edge),
                    .stop_loop => app.handleAction(.stop_node),
                    .show_graph => app.handleAction(.show_graph),
                    .new_tab => app.handleAction(.new_tab),
                    .close_tab => app.handleAction(.close_tab),
                    .split_right => app.handleAction(.split_horizontal),
                    .split_down => app.handleAction(.split_vertical),
                    .next_tab => app.handleAction(.select_next_tab),
                    .previous_tab => app.handleAction(.select_previous_tab),
                    .focus_next_pane => app.handleAction(.focus_next_pane),
                    .focus_previous_pane => app.handleAction(.focus_previous_pane),
                    .reconnect => app.handleAction(.reconnect),
                    .settings => app.handleAction(.settings),
                    .product_settings => app.handleAction(.product_settings),
                    .toggle_sidebar => app.handleAction(.toggle_rail),
                    .toggle_workspace => app.handleAction(.toggle_panel),
                    .focus_header => if (app.headerLayout().step(null, false)) |action| {
                        _ = app.focusHeader(action);
                    },
                    .toggle_activity => app.handleAction(.toggle_activity),
                    .zoom_out => app.handleAction(.zoom_out),
                    .actual_size => app.handleAction(.actual_size),
                    .zoom_in => app.handleAction(.zoom_in),
                    .fit_canvas => app.handleAction(.fit_canvas),
                    .onboarding => app.handleAction(.onboarding),
                    .check_updates => app.checkForUpdates(),
                    .about => app.showAbout(),
                    .workspace_new => app.createWorkspace(),
                    .workspace_manage => app.manageWorkspaces(),
                    .workspace_rename => app.renameWorkspace(),
                    .workspace_delete => app.deleteWorkspace(),
                    .workspace_next => app.cycleWorkspace(1),
                    .workspace_previous => app.cycleWorkspace(-1),
                }
            }
            app.updateNativeChrome(.state_change);
            result.* = 0;
            return true;
        },
        c.WM_ERASEBKGND => {
            // WM_PAINT presents a complete off-screen frame, so erasing first would
            // expose the background between GDI operations and cause visible flicker.
            result.* = 1;
            return true;
        },
        c.WM_PAINT => {
            var paint: c.PAINTSTRUCT = undefined;
            const target_hdc = c.BeginPaint(hwnd, &paint);
            var client: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &client);
            var buffer_dc: c.HDC = null;
            var buffer_bitmap: c.HBITMAP = null;
            var previous_bitmap: c.HGDIOBJ = null;
            var hdc = target_hdc;
            if (client.right > client.left and client.bottom > client.top) {
                buffer_dc = c.CreateCompatibleDC(target_hdc);
                if (buffer_dc != null) {
                    buffer_bitmap = c.CreateCompatibleBitmap(
                        target_hdc,
                        client.right - client.left,
                        client.bottom - client.top,
                    );
                    if (buffer_bitmap != null) {
                        previous_bitmap = c.SelectObject(buffer_dc, buffer_bitmap);
                        hdc = buffer_dc;
                    }
                }
            }
            const logical_right = Dpi.unscale(client.right, app.dpi);
            const logical_bottom = Dpi.unscale(client.bottom, app.dpi);
            if (logical_right > 0 and logical_bottom > 0) {
                _ = c.SetMapMode(hdc, c.MM_ANISOTROPIC);
                _ = c.SetWindowExtEx(hdc, logical_right, logical_bottom, null);
                _ = c.SetViewportExtEx(hdc, client.right, client.bottom, null);
            }
            const header = app.headerPresentation();
            const inspection = app.currentWorktreeInspection();
            app.update_lock.lock();
            if (app.model.currentGraph()) |graph| app.canvas.syncNodeOffsets(graph.nodes.items);
            const offered_version = if (app.update_state.state == .available) app.update_version else "";
            GraphCanvas.paint(hdc, logical_right, logical_bottom, &app.model, inspection, app.selected_worktree_path, app.sidebar_scroll, app.status(), offered_version, app.ingress_error, app.connectionFailureVisible(), app.worktree_state, app.declared_entry_ids.items, app.kept_worktree_paths.items, app.allocator, &app.canvas, &app.sidebar_state, app.sidebar_hover_y, app.workspace_controls, app.surface);
            app.update_lock.unlock();
            if (app.workspace_controls.panel_visible or app.surface == .workspace) {
                if (app.surface == .workspace) {
                    if (workspaceGraph(&app.model)) |graph| {
                        const workspace_right = logical_right - (if (app.workspace_controls.panel_visible) Tokens.loop_detail_width else 0);
                        const index = app.model.selectedIndex() orelse 0;
                        if (index < graph.nodes.items.len) {
                            const node = graph.nodes.items[index];
                            TerminalWorkspace.Workspace.paintLoopBar(
                                hdc,
                                app.allocator,
                                if (app.workspace_controls.rail_visible) Tokens.sidebar_width else 0,
                                workspace_right,
                                graph.project.name,
                                node.title,
                                node.loop_type,
                                node.state,
                                node.activity,
                                node.backend,
                                node.created_at,
                                node.metric_passes,
                                node.token_usage,
                                isResolvedLoopState(node.state),
                            );
                        }
                        if (!app.workspace_controls.panel_visible) GraphCanvas.paintLoopDetailExpandControl(hdc, app.allocator, logical_right);
                    }
                }
                if (app.workspace) |workspace| {
                    const saved_mapping = c.SaveDC(hdc);
                    _ = c.SetMapMode(hdc, c.MM_TEXT);
                    workspace.paintChrome(hdc);
                    _ = c.RestoreDC(hdc, saved_mapping);
                }
                if (app.surface == .workspace and app.workspace_controls.panel_visible) {
                    if (workspaceGraph(&app.model)) |graph| {
                        const index = app.model.selectedIndex() orelse graph.nodes.items.len;
                        GraphCanvas.paintLoopDetailRail(
                            hdc,
                            app.allocator,
                            graph,
                            index,
                            logical_right,
                            logical_bottom,
                        );
                    }
                }
            }
            GraphCanvas.paintHeader(hdc, app.allocator, logical_right, app.status(), header, if (app.headerOwnsFocus()) app.header_focus else null);
            _ = c.SetMapMode(hdc, c.MM_TEXT);
            if (hdc != target_hdc) {
                const dirty = paint.rcPaint;
                _ = c.BitBlt(
                    target_hdc,
                    dirty.left,
                    dirty.top,
                    dirty.right - dirty.left,
                    dirty.bottom - dirty.top,
                    hdc,
                    dirty.left,
                    dirty.top,
                    c.SRCCOPY,
                );
            }
            if (previous_bitmap != null and buffer_dc != null) {
                _ = c.SelectObject(buffer_dc, previous_bitmap);
            }
            if (buffer_bitmap != null) _ = c.DeleteObject(buffer_bitmap);
            if (buffer_dc != null) _ = c.DeleteDC(buffer_dc);
            _ = c.EndPaint(hwnd, &paint);
            result.* = 0;
            return true;
        },
        c.WM_SIZE => {
            app.layoutWorkspace();
            app.clampSidebarScroll();
            app.layoutEmptyStateControls();
            app.syncAccessibility();
            result.* = 0;
            return true;
        },
        c.WM_DPICHANGED => {
            const dpi = @as(u32, @intCast(wparam & 0xffff));
            app.dpi = Dpi.normalize(dpi);
            // Propagate the real per-monitor DPI down to every live terminal surface
            // (font_scale + winghostty_surface_notify_dpi_changed) using the runtime
            // value Windows just reported, rather than assuming a fixed scale.
            if (app.workspace) |workspace| workspace.setDpi(app.dpi);
            if (lparam != 0) {
                const suggested = Win32.messagePointer(*const c.RECT, lparam);
                _ = c.SetWindowPos(
                    hwnd,
                    null,
                    suggested.left,
                    suggested.top,
                    suggested.right - suggested.left,
                    suggested.bottom - suggested.top,
                    c.SWP_NOZORDER | c.SWP_NOACTIVATE,
                );
            }
            app.layoutWorkspace();
            app.clampSidebarScroll();
            app.layoutEmptyStateControls();
            app.syncAccessibility();
            _ = c.InvalidateRect(hwnd, null, 0);
            result.* = 0;
            return true;
        },
        c.WM_TIMER => if (wparam == folder_open_timer_id) {
            FolderOpenApi.cancelTimer(hwnd, folder_open_timer_id);
            app.dispatchPendingFolderOpenWith(FolderOpenApi);
            result.* = 0;
            return true;
        } else if (wparam == MainWindow.menu_watchdog_timer_id) {
            _ = c.KillTimer(hwnd, MainWindow.menu_watchdog_timer_id);
            _ = c.EndMenu();
            App.dismissWedgedUiaForm();
            result.* = 0;
            return true;
        } else if (wparam == MainWindow.timer_id) {
            app.smoke_tick += 1;
            if (!app.tray.added and app.smoke_tick % 10 == 0) {
                app.tray.add(hwnd) catch app.setStatus("System tray unavailable; retrying");
            }
            app.finishUpdateCheck();
            app.finishWorktreeInspection();
            app.finishWorktreeReclaim();
            if (app.clone_operation) |operation| {
                var progress: [256]u8 = undefined;
                var recent_stderr: [256]u8 = undefined;
                const output = operation.snapshot(&progress, &recent_stderr);
                if (output.progress_len != 0) {
                    app.setStatus(progress[0..output.progress_len]);
                } else if (output.stderr_len != 0) {
                    app.setStatus(recent_stderr[0..output.stderr_len]);
                }
                if (operation.poll()) |status| {
                    operation.deinit();
                    app.clone_operation = null;
                    app.setStatus(switch (status) {
                        .finished => "Clone complete",
                        .cancelled => "Clone cancelled; partial output removed",
                        else => "Clone failed; partial output removed",
                    });
                }
            }
            app.client.poll();
            const connection_state = app.client.connectionState();
            if (connection_state == .connected) app.flushPendingProject();
            if (app.client.connectionState() == .connected) {
                if (app.open_project_pending and
                    (app.pending_rebind_path.len != 0 or app.last_project_opened.len != 0))
                {
                    app.sendPendingOpen();
                } else if (!app.sync_requested) {
                    app.sync_requested = true;
                    app.client.sendListProjects();
                    if (!app.quick_chats_requested) {
                        app.quick_chats_requested = true;
                        app.client.sendListQuickChats();
                    }
                } else if (!app.restore_requested) {
                    app.restore_requested = true;
                    app.client.sendRestoreOpenProjects();
                }
            }
            const updated_connection_state = app.client.connectionState();
            if (updated_connection_state != app.last_connection_state) {
                if (updated_connection_state != .connected) {
                    app.model.invalidateWorktreeNotices(.connection_changed);
                    app.syncAccessibility();
                }
                app.last_connection_state = updated_connection_state;
                app.sync_requested = false;
                app.restore_requested = false;
                app.quick_chats_requested = false;
            }
            if (app.client.isIdle()) app.smoke_idle_ticks += 1 else app.smoke_idle_ticks = 0;
            if (app.workspace) |workspace| {
                workspace.poll();
                app.reportLaunchOutcome(workspace);
                if (!app.smoke_workspace_restart_observed) {
                    if (app.smoke_restart_index) |index| {
                        if (workspace.surfaceIdentityReady(index, app.smoke_restart_session, workspace.projectPath())) {
                            app.smoke_workspace_restart_observed = true;
                            app.allocator.free(app.smoke_restart_session);
                            app.smoke_restart_session = &.{};
                            app.smoke_restart_index = null;
                        }
                    }
                }
                if (workspace.inputStatus(app.status_override)) |input_message| app.setStatus(input_message);
            }
            if (app.smoke and app.smoke_tick == 8) {
                app.refreshWorkspace();
            }
            if (app.smoke and app.smoke_tick >= 12 and !app.smoke_workspace_actions_ran) {
                runSmokeWorkspaceActions(app);
            }
            if (app.smoke and app.smoke_tick >= 16 and
                app.client.connectionState() == .connected and
                app.currentProject() != null and app.model.selected() != null and
                !app.smoke_action_requested)
            {
                app.smoke_action_requested = true;
                app.smoke_idle_ticks = 0;
                app.sendSelectedNode();
            }
            if (app.smoke and app.smoke_tick >= 16 and !app.smoke_input_requested and
                envFlag("GRAPHCODE_SHELL_LARGE_PASTE"))
            {
                if (app.workspace) |workspace| {
                    app.smoke_input_requested = true;
                    app.smoke_idle_ticks = 0;
                    const paste = app.allocator.alloc(u8, 1024 * 1024) catch {
                        app.setStatus("Large paste allocation failed");
                        return true;
                    };
                    @memset(paste, 'x');
                    workspace.send(paste);
                    app.allocator.free(paste);
                }
            }
            if (app.smoke and app.smoke_tick >= 12 and
                ((app.stress and app.smoke_tick % 2 == 0) or
                    (!app.stress and app.smoke_tick == 12)) and
                !envFlag("GRAPHCODE_SHELL_WORKSPACE_ACTIONS"))
            {
                if (app.workspace) |workspace| {
                    if (workspace.hasSurface(0)) {
                        workspace.recreate(0) catch {
                            app.setStatus("Terminal recreate failed");
                        };
                    }
                }
            }
            const smoke_deadline: usize = if (app.stress) 96 else 52;
            if (app.smoke and
                ((app.stress and app.smoke_tick >= 56) or
                    (!app.stress and app.smoke_tick >= 32)) and
                (app.smoke_idle_ticks >= 5 or
                    app.smoke_tick >= smoke_deadline))
            {
                if (app.require_smoke_contract and !smokeContractPassed(app)) {
                    app.smoke_failure = true;
                }
                app.exit_requested = true;
                _ = c.DestroyWindow(hwnd);
            }
            _ = c.InvalidateRect(hwnd, null, 0);
            result.* = 0;
            return true;
        },
        MainWindow.wm_app_tick => {
            app.client.reconnect();
            result.* = 0;
            return true;
        },
        MainWindow.wm_uia_fixture_mutate => {
            app.mutateUiaFixture(wparam);
            result.* = 0;
            return true;
        },
        MainWindow.wm_uia_context_menu => {
            app.showUiaContextMenu(wparam);
            result.* = 0;
            return true;
        },
        MainWindow.wm_uia_present_form => {
            app.presentUiaForm(wparam);
            result.* = 0;
            return true;
        },
        Accessibility.wm_header_focus => {
            result.* = 0;
            for (GraphCanvas.header_actions) |action| {
                if (Accessibility.worktreeIdentityPayload(GraphCanvas.headerIdentity(action)) == wparam) {
                    result.* = if (app.focusHeader(action)) 1 else 0;
                    break;
                }
            }
            return true;
        },
        c.WM_KEYDOWN, c.WM_SYSKEYDOWN => {
            const ctrl = (@as(i32, c.GetKeyState(c.VK_CONTROL)) & 0x8000) != 0;
            const shift = (@as(i32, c.GetKeyState(c.VK_SHIFT)) & 0x8000) != 0;
            const alt = (@as(i32, c.GetKeyState(c.VK_MENU)) & 0x8000) != 0;
            if (message == c.WM_SYSKEYDOWN and MainWindow.workspaceCycleDirection(wparam, ctrl, shift, alt) == null)
                return false;
            if (MainWindow.keyOwnerEligible(hwnd, hwnd) and App.onShellKey(app, wparam, ctrl, shift, alt)) {
                result.* = 0;
                return true;
            }
            if (wparam == c.VK_ESCAPE) {
                app.cancelCanvasInteraction();
                result.* = 0;
                return true;
            }
            app.handleAction(fallbackKeyAction(wparam, ctrl, shift, alt));
            app.updateNativeChrome(.state_change);
            result.* = 0;
            return true;
        },
        c.WM_CAPTURECHANGED, c.WM_CANCELMODE => {
            app.cancelCanvasInteraction();
            result.* = 0;
            return true;
        },
        c.WM_ACTIVATEAPP => {
            if (wparam == 0) {
                app.cancelCanvasInteraction();
            } else {
                if (app.refreshWorkspaceList()) app.syncAccessibility();
            }
            result.* = 0;
            return true;
        },
        c.WM_LBUTTONDOWN => {
            const physical_x = mouseX(lparam);
            const physical_y = mouseY(lparam);
            const x = logicalCoordinate(physical_x, app.dpi);
            const y = logicalCoordinate(physical_y, app.dpi);
            if (envFlag("GRAPHCODE_UIA_GATE") and x == 0 and y == 0) {
                _ = app.toggleWorktreeRow(0);
                result.* = 0;
                return true;
            }
            const client = logicalClientRect(hwnd, app.dpi);
            if (app.headerLayout().actionAt(x, y)) |action| {
                _ = app.focusHeader(action);
                _ = app.invokeHeader(action);
                result.* = 0;
                return true;
            }
            if (app.header_focus != null) app.leaveHeader(false);
            if (GraphCanvas.attentionRailShown(&app.model, app.surface) and GraphCanvas.hitTestAttentionRail(x, y, client.right)) {
                app.handleAction(.cycle_attention);
                _ = c.InvalidateRect(hwnd, null, 0);
                result.* = 0;
                return true;
            }
            const routing = inputBounds(client.right, client.bottom, app.workspace_controls);
            const workspace_top = if (app.surface == .workspace and app.workspace_controls.panel_visible)
                Tokens.header_height
            else
                routing.workspace_top;
            const rail_left = routing.rail_left;
            const sidebar_bottom = GraphCanvas.sidebarBottom(client.bottom, app.workspace_controls, app.surface);
            if (app.workspace_controls.rail_visible and x < rail_left) {
                const inspection = if (app.worktree_inspection) |*value| value else null;
                if (Sidebar.rowAt(x, y, &app.model, inspection, app.sidebar_scroll, sidebar_bottom, &app.sidebar_state)) |row| {
                    if (row.kind == .loop and row.depth == 0 and x < 198) {
                        if (row.project_path) |path| if (app.model.graphFor(path)) |graph| {
                            if (row.index < graph.nodes.items.len) app.beginSidebarRootDrag(path, graph.nodes.items[row.index].id, y);
                        };
                    } else {
                        app.clearSidebarRootDrag();
                    }
                } else {
                    app.clearSidebarRootDrag();
                }
            } else {
                app.clearSidebarRootDrag();
            }
            if ((app.workspace_controls.panel_visible or app.surface == .workspace) and x >= rail_left and y >= workspace_top) {
                if (app.surface == .workspace) {
                    if (GraphCanvas.hitTestLoopDetailCollapse(x, y, client.right, app.workspace_controls.panel_visible)) {
                        app.toggleWorkspaceDetailPanel();
                        _ = c.InvalidateRect(hwnd, null, 0);
                        result.* = 0;
                        return true;
                    }
                    if (workspaceGraph(&app.model)) |graph| {
                        const index = app.model.selectedIndex() orelse graph.nodes.items.len;
                        if (index < graph.nodes.items.len) {
                            const node = graph.nodes.items[index];
                            if (TerminalWorkspace.loopBarActionAt(
                                rail_left,
                                Tokens.header_height,
                                client.right - Tokens.loop_detail_width,
                                x,
                                y,
                                isResolvedLoopState(node.state),
                            )) |action| {
                                switch (action) {
                                    .stop => app.stopSelectedNode(),
                                    .show_graph => app.handleAction(.show_graph),
                                }
                                _ = c.InvalidateRect(hwnd, null, 0);
                                result.* = 0;
                                return true;
                            }
                        }
                    }
                }
                if (app.workspace) |workspace| {
                    if (workspace.chromeActionAt(physical_x, physical_y)) |action| {
                        app.handleAction(switch (action) {
                            .new_tab => .new_tab,
                            .split_right => .split_horizontal,
                            .split_down => .split_vertical,
                        });
                        _ = c.InvalidateRect(hwnd, null, 0);
                        result.* = 0;
                        return true;
                    }
                    if (workspace.tabActionAt(physical_x, physical_y)) |tab_action| {
                        switch (tab_action.action) {
                            .select => workspace.selectTab(tab_action.index) catch {},
                            .close => workspace.closeTab(tab_action.index) catch {},
                        }
                        _ = c.InvalidateRect(hwnd, null, 0);
                        result.* = 0;
                        return true;
                    }
                }
            }
            if (x >= rail_left and y < workspace_top) {
                const bounds = c.RECT{ .left = rail_left, .top = Tokens.header_height, .right = client.right, .bottom = workspace_top };
                if (app.surface != .workspace) {
                    if (GraphCanvas.hitTestZoomControl(x, y, bounds)) |control| {
                        const center_x = @divTrunc(bounds.left + bounds.right, 2);
                        const center_y = @divTrunc(bounds.top + bounds.bottom, 2);
                        switch (control) {
                            .out => app.canvas.zoomBy(center_x, center_y, 0.9),
                            .actual => app.canvas.actualSize(),
                            .in => app.canvas.zoomBy(center_x, center_y, 1.1),
                            .fit => {
                                const content = GraphCanvas.contentSize(&app.model, app.surface);
                                app.canvas.fit(bounds, content.width, content.height);
                            },
                        }
                        app.syncAccessibility();
                        _ = c.InvalidateRect(hwnd, null, 0);
                        result.* = 0;
                        return true;
                    }
                }
                switch (app.surface) {
                    .overview => {
                        if (app.applyOverviewLaneAction(x, y, bounds)) {
                            _ = c.InvalidateRect(hwnd, null, 0);
                        } else if (GraphCanvas.hitTestOverview(&app.model, x, y, &app.canvas, bounds)) |hit| {
                            const graph = app.model.graphs.items[hit.graph_index];
                            _ = app.activateLoop(graph.project.path, graph.nodes.items[hit.node_index].id);
                        } else {
                            app.canvas.beginPan(x, y);
                            _ = c.SetCapture(hwnd);
                        }
                        app.syncAccessibility();
                        _ = c.InvalidateRect(hwnd, null, 0);
                    },
                    .quick_chats => {
                        if (GraphCanvas.hitTestQuickChat(app.model.quick_chats.items.len, x, y, &app.canvas, bounds)) |index| {
                            app.client.sendOpenQuickChat(app.model.quick_chats.items[index].id);
                            app.setStatus("Opening quick chat...");
                        } else {
                            app.canvas.beginPan(x, y);
                            _ = c.SetCapture(hwnd);
                        }
                        _ = c.InvalidateRect(hwnd, null, 0);
                    },
                    .project, .workspace => if (app.model.graph) |graph| {
                        if (app.surface == .project and GraphCanvas.hitTestProjectWorktreeChip(&app.model, x, y, bounds)) {
                            app.inspectWorktrees();
                        } else if (GraphCanvas.hitTestCompositeBack(&app.model, x, y, bounds)) {
                            app.closeCompositeGroup();
                        } else if (GraphCanvas.hitTestReclaimOffer(
                            graph.nodes.items,
                            app.currentWorktreeInspection(),
                            app.kept_worktree_paths.items,
                            x,
                            y,
                            &app.canvas,
                        )) |hit| {
                            const path = graph.nodes.items[hit.node_index].worktree_path;
                            switch (hit.action) {
                                .reclaim => app.reclaimWorktreeOffer(path),
                                .keep => app.keepWorktreeOffer(path),
                            }
                            _ = c.InvalidateRect(hwnd, null, 0);
                        } else if (GraphCanvas.hitTestAttentionAction(graph.nodes.items, graph.edges.items, x, y, &app.canvas)) |index| {
                            _ = app.activateLoop(graph.project.path, graph.nodes.items[index].id);
                        } else if (GraphCanvas.hitTestConnector(graph.nodes.items, x, y, &app.canvas, bounds)) |index| {
                            if (app.edge_drag_source_id.len != 0) app.allocator.free(app.edge_drag_source_id);
                            app.edge_drag_source_id = app.allocator.dupe(u8, graph.nodes.items[index].id) catch &.{};
                            if (app.edge_drag_source_id.len != 0) {
                                app.canvas.beginEdgeDrag(app.edge_drag_source_id, x, y);
                                _ = c.SetCapture(hwnd);
                            }
                        } else if (GraphCanvas.hitTest(graph.nodes.items, x, y, &app.canvas, bounds)) |index| {
                            _ = app.selectNodeIndex(index);
                            if (app.beginCanvasNodePress(graph.project.path, graph.nodes.items[index].id)) {
                                app.canvas.beginNodeDrag(graph.nodes.items[index].id, index, x, y);
                                _ = c.SetCapture(hwnd);
                            } else {
                                app.setStatus("Unable to prepare loop activation");
                            }
                            _ = c.InvalidateRect(hwnd, null, 0);
                        } else if (GraphCanvas.hitTestEdge(graph.nodes.items, graph.edges.items, x, y, &app.canvas, bounds)) |index| {
                            _ = app.selectEdgeIndex(index);
                            _ = c.InvalidateRect(hwnd, null, 0);
                        } else {
                            app.clearSelection();
                            app.canvas.beginPan(x, y);
                            _ = c.SetCapture(hwnd);
                        }
                    } else {
                        app.canvas.beginPan(x, y);
                        _ = c.SetCapture(hwnd);
                    },
                }
                result.* = 0;
                return true;
            }
            if (app.workspace_controls.rail_visible) {
                if (app.completeSidebarRootDrag(y)) {
                    result.* = 0;
                    return true;
                }
                app.update_lock.lock();
                const update_available = app.update_state.state == .available;
                app.update_lock.unlock();
                if (Sidebar.updateBannerAt(x, y, sidebar_bottom, update_available, app.ingress_error.len != 0)) {
                    app.showCurrentUpdateOffer();
                    result.* = 0;
                    return true;
                }
                if (Sidebar.needsYouStopAt(
                    x,
                    y,
                    &app.model,
                    if (app.worktree_inspection) |*value| value else null,
                    &app.sidebar_state,
                    app.sidebar_scroll,
                )) |attention_index| {
                    if (attention_index < app.model.attention_entries.items.len) {
                        app.stopAttentionEntry(app.model.attention_entries.items[attention_index]);
                    }
                    app.syncAccessibility();
                    _ = c.InvalidateRect(hwnd, null, 0);
                    result.* = 0;
                    return true;
                }
                if (Sidebar.attentionRowAt(
                    y,
                    &app.model,
                    if (app.worktree_inspection) |*value| value else null,
                    &app.sidebar_state,
                    app.sidebar_scroll,
                )) |attention_index| {
                    if (app.chooseAttentionEntry(attention_index)) app.setStatus("Needs-you loop selected");
                    app.syncAccessibility();
                    _ = c.InvalidateRect(hwnd, null, 0);
                    result.* = 0;
                    return true;
                }
                if (Sidebar.activityControlAt(
                    x,
                    y,
                    &app.model,
                    if (app.worktree_inspection) |*value| value else null,
                    &app.sidebar_state,
                    app.sidebar_scroll,
                )) |control| {
                    switch (control) {
                        .filter => Sidebar.toggleActivityAttentionOnly(&app.sidebar_state, &app.model),
                        .left => Sidebar.stepActivity(&app.sidebar_state, &app.model, .left),
                        .right => Sidebar.stepActivity(&app.sidebar_state, &app.model, .right),
                    }
                    app.syncAccessibility();
                    _ = c.InvalidateRect(hwnd, null, 0);
                    result.* = 0;
                    return true;
                }
                if (Sidebar.activityCardAt(
                    x,
                    y,
                    &app.model,
                    if (app.worktree_inspection) |*value| value else null,
                    &app.sidebar_state,
                    app.sidebar_scroll,
                )) |activity_index| {
                    if (activity_index < app.model.activity.items.len) {
                        app.navigateToActivityEvent(app.model.activity.items[activity_index]);
                    }
                    result.* = 0;
                    return true;
                }
                if (Sidebar.rowAt(
                    x,
                    y,
                    &app.model,
                    if (app.worktree_inspection) |*value| value else null,
                    app.sidebar_scroll,
                    sidebar_bottom,
                    &app.sidebar_state,
                )) |row| {
                    const ctrl = (@as(i32, c.GetKeyState(c.VK_CONTROL)) & 0x8000) != 0;
                    switch (row.kind) {
                        .local_heading => app.sidebar_state.local_collapsed = !app.sidebar_state.local_collapsed,
                        .remote_heading => app.sidebar_state.remote_collapsed = !app.sidebar_state.remote_collapsed,
                        .project => app.openProject(app.model.recent_projects.items[row.index].path),
                        .open_project => if (row.project_path) |path| {
                            if (x >= 198 and row.has_children) {
                                app.sidebar_state.toggleProject(path) catch app.setStatus("Sidebar state could not be updated");
                                app.clampSidebarScroll();
                                app.syncAccessibility();
                                _ = c.InvalidateRect(hwnd, null, 0);
                                result.* = 0;
                                return true;
                            }
                            if (x >= 174 and x < 198) {
                                if (app.selectProject(path)) app.createNode();
                                result.* = 0;
                                return true;
                            }
                            if (app.selectProject(path)) {
                                app.surface = .project;
                                app.workspace_controls.panel_visible = false;
                                app.layoutWorkspace();
                                app.clearEdgeSelection();
                                app.rebindWorkspace(path);
                            }
                        },
                        .overview => app.openGlobalOverview(),
                        .loop => if (row.project_path) |path| if (app.model.graphFor(path)) |graph| {
                            if (row.index < graph.nodes.items.len) {
                                if (x >= 198 and row.has_children) {
                                    app.sidebar_state.toggleNode(graph.nodes.items[row.index].id) catch app.setStatus("Sidebar state could not be updated");
                                    if (app.sidebar_store) |*store| store.save(&app.sidebar_state) catch app.setStatus("Sidebar expansion could not be saved");
                                    app.clampSidebarScroll();
                                    app.syncAccessibility();
                                    _ = c.InvalidateRect(hwnd, null, 0);
                                    result.* = 0;
                                    return true;
                                }
                                _ = app.activateLoop(path, graph.nodes.items[row.index].id);
                            }
                        },
                        .worktree => if (app.worktree_inspection) |inspection| {
                            if (ctrl) {
                                _ = app.toggleWorktreeRow(row.index);
                            } else {
                                _ = app.selectWorktreeRow(inspection.entries.items[row.index].path);
                            }
                            app.ensureWorktreeVisible(row.index);
                        },
                        .quick_chat_overview => {
                            if (x >= 198 and app.model.quick_chats.items.len != 0) {
                                app.sidebar_state.chats_collapsed = !app.sidebar_state.chats_collapsed;
                                app.clampSidebarScroll();
                                app.syncAccessibility();
                                _ = c.InvalidateRect(hwnd, null, 0);
                                result.* = 0;
                                return true;
                            }
                            if (x >= 174 and x < 198) {
                                app.createQuickChat();
                                result.* = 0;
                                return true;
                            }
                            app.surface = .quick_chats;
                            app.workspace_controls.panel_visible = false;
                            app.layoutWorkspace();
                            app.layoutEmptyStateControls();
                        },
                        .quick_chat => if (row.index < app.model.quick_chats.items.len) {
                            app.client.sendOpenQuickChat(app.model.quick_chats.items[row.index].id);
                            app.setStatus("Opening quick chat...");
                        },
                    }
                    app.clearSidebarRootDrag();
                    app.clampSidebarScroll();
                    app.syncAccessibility();
                    _ = c.InvalidateRect(hwnd, null, 0);
                    result.* = 0;
                    return true;
                }
            }
            app.clearSidebarRootDrag();
            result.* = 0;
            return true;
        },
        c.WM_RBUTTONUP => {
            const physical_point = CanvasInput.decodeMouseMessage(lparam);
            const point = c.POINT{
                .x = logicalCoordinate(physical_point.x, app.dpi),
                .y = logicalCoordinate(physical_point.y, app.dpi),
            };
            const client = logicalClientRect(hwnd, app.dpi);
            const routing = inputBounds(client.right, client.bottom, app.workspace_controls);
            if (app.workspace_controls.rail_visible and point.x < routing.rail_left) {
                const inspection = if (app.worktree_inspection) |*value| value else null;
                if (Sidebar.rowAt(
                    point.x,
                    point.y,
                    &app.model,
                    inspection,
                    app.sidebar_scroll,
                    GraphCanvas.sidebarBottom(client.bottom, app.workspace_controls, app.surface),
                    &app.sidebar_state,
                )) |row| {
                    var project_path: ?[]const u8 = null;
                    var remote = false;
                    switch (row.kind) {
                        .project => if (row.index < app.model.recent_projects.items.len) {
                            const project = app.model.recent_projects.items[row.index];
                            project_path = project.path;
                            remote = project.isRemote();
                        },
                        .open_project => if (row.index < app.model.graphs.items.len) {
                            const project = app.model.graphs.items[row.index].project;
                            project_path = project.path;
                            remote = project.isRemote();
                        },
                        else => {},
                    }
                    if (project_path) |path| {
                        var screen = c.POINT{ .x = physical_point.x, .y = physical_point.y };
                        _ = c.ClientToScreen(hwnd, &screen);
                        GraphContextMenu.show(
                            hwnd,
                            .{ .project = .{ .path = path, .remote = remote, .worktrees_available = !app.worktreeProviderBusy() } },
                            screen.x,
                            screen.y,
                            app,
                            &onContextAction,
                        );
                    } else switch (row.kind) {
                        .loop => if (row.project_path) |path| if (app.model.graphFor(path)) |graph| {
                            if (row.index < graph.nodes.items.len) {
                                var screen = c.POINT{ .x = physical_point.x, .y = physical_point.y };
                                _ = c.ClientToScreen(hwnd, &screen);
                                app.showOwnedNodeContextMenu(path, null, graph.nodes.items[row.index].id, false, screen.x, screen.y);
                            }
                        },
                        .quick_chat => if (row.index < app.model.quick_chats.items.len) {
                            var screen = c.POINT{ .x = physical_point.x, .y = physical_point.y };
                            _ = c.ClientToScreen(hwnd, &screen);
                            GraphContextMenu.show(
                                hwnd,
                                .{ .quick_chat = .{ .id = app.model.quick_chats.items[row.index].id } },
                                screen.x,
                                screen.y,
                                app,
                                &onContextAction,
                            );
                        },
                        .quick_chat_overview => {
                            var screen = c.POINT{ .x = physical_point.x, .y = physical_point.y };
                            _ = c.ClientToScreen(hwnd, &screen);
                            GraphContextMenu.show(hwnd, .quick_chats, screen.x, screen.y, app, &onContextAction);
                        },
                        else => {},
                    }
                }
                result.* = 0;
                return true;
            }
            if (point.x >= routing.canvas.left and point.y >= routing.canvas.top and point.y < routing.canvas.bottom) {
                const bounds = c.RECT{ .left = routing.canvas.left, .top = routing.canvas.top, .right = routing.canvas.right, .bottom = routing.canvas.bottom };
                if (app.surface == .quick_chats) {
                    if (GraphCanvas.hitTestQuickChat(app.model.quick_chats.items.len, point.x, point.y, &app.canvas, bounds)) |index| {
                        var screen = c.POINT{ .x = physical_point.x, .y = physical_point.y };
                        _ = c.ClientToScreen(hwnd, &screen);
                        app.showQuickChatContextMenu(index, screen.x, screen.y);
                    }
                    result.* = 0;
                    return true;
                }
                if (app.surface != .project) {
                    result.* = 0;
                    return true;
                }
                var target: enum { background, node, edge } = .background;
                var target_index: usize = 0;
                if (app.model.graph) |graph| {
                    if (GraphCanvas.hitTest(graph.nodes.items, point.x, point.y, &app.canvas, bounds)) |index| {
                        target = .node;
                        target_index = index;
                    } else if (GraphCanvas.hitTestEdge(graph.nodes.items, graph.edges.items, point.x, point.y, &app.canvas, bounds)) |index| {
                        target = .edge;
                        target_index = index;
                    }
                }
                var screen = c.POINT{ .x = physical_point.x, .y = physical_point.y };
                _ = c.ClientToScreen(hwnd, &screen);
                switch (target) {
                    .background => app.showBackgroundContextMenu(screen.x, screen.y),
                    .node => app.showNodeContextMenu(target_index, screen.x, screen.y),
                    .edge => app.showEdgeContextMenu(target_index, screen.x, screen.y),
                }
                result.* = 0;
                return true;
            }
            result.* = 0;
            return true;
        },
        c.WM_LBUTTONUP => {
            if (app.canvas.node_dragging) {
                const dragged = app.canvas.node_drag_started;
                const activation_index = app.canvas.completeNodeDrag();
                if (dragged) {
                    if (app.canvas_layout_store) |*store| {
                        store.save(&app.canvas) catch app.setStatus("Canvas position could not be saved");
                    }
                }
                if (activation_index != null and
                    app.canvas_press_project_path.len != 0 and
                    app.canvas_press_node_id.len != 0)
                {
                    _ = app.activateLoop(app.canvas_press_project_path, app.canvas_press_node_id);
                } else {
                    app.syncAccessibility();
                    _ = c.InvalidateRect(hwnd, null, 0);
                }
                app.clearCanvasNodePress();
                _ = c.ReleaseCapture();
                result.* = 0;
                return true;
            }
            if (app.canvas.edge_dragging) {
                const physical_point = CanvasInput.decodeMouseMessage(lparam);
                const point = c.POINT{
                    .x = logicalCoordinate(physical_point.x, app.dpi),
                    .y = logicalCoordinate(physical_point.y, app.dpi),
                };
                const source_id = app.copyEdgeDragSourceForDrop() orelse {
                    app.cancelCanvasInteraction();
                    result.* = 0;
                    return true;
                };
                defer app.allocator.free(source_id);
                _ = c.ReleaseCapture();
                if (app.model.graph) |graph| {
                    const client = logicalClientRect(hwnd, app.dpi);
                    const bounds = c.RECT{ .left = Tokens.sidebar_width, .top = Tokens.header_height, .right = client.right, .bottom = client.bottom - Tokens.workspace_height };
                    if (GraphModel.findNodeIndexByID(graph.nodes.items, source_id)) |source| {
                        if (GraphCanvas.hitTest(graph.nodes.items, point.x, point.y, &app.canvas, bounds)) |target| {
                            if (target != source) app.createEdgeBetweenIDs(source_id, graph.nodes.items[target].id);
                        }
                    }
                }
                if (app.edge_drag_source_id.len != 0) {
                    app.allocator.free(app.edge_drag_source_id);
                    app.edge_drag_source_id = &.{};
                }
                _ = c.InvalidateRect(hwnd, null, 0);
                result.* = 0;
                return true;
            }
            if (app.canvas.dragging) {
                app.canvas.endPan();
                _ = c.ReleaseCapture();
                app.syncAccessibility();
            }
            result.* = 0;
            return true;
        },
        c.WM_MOUSEMOVE => {
            const hover_y = logicalCoordinate(mouseY(lparam), app.dpi);
            const hover_x = logicalCoordinate(mouseX(lparam), app.dpi);
            app.updateSidebarRootDrag(hover_y);
            const next_hover = if (hover_x >= 0 and hover_x < Tokens.sidebar_width) hover_y else -1;
            if (next_hover != app.sidebar_hover_y) {
                app.sidebar_hover_y = next_hover;
                _ = c.InvalidateRect(hwnd, null, 0);
            }
            if (app.canvas.node_dragging) {
                app.canvas.updateNodeDrag(hover_x, hover_y);
                app.syncAccessibility();
                _ = c.InvalidateRect(hwnd, null, 0);
                result.* = 0;
                return true;
            } else if (app.canvas.edge_dragging) {
                app.canvas.updateEdgeDrag(hover_x, hover_y);
                _ = c.InvalidateRect(hwnd, null, 0);
                result.* = 0;
                return true;
            } else if (app.canvas.dragging) {
                app.canvas.updatePan(hover_x, hover_y);
                _ = c.InvalidateRect(hwnd, null, 0);
                result.* = 0;
                return true;
            }
            if (app.model.graph) |graph| {
                const client = logicalClientRect(hwnd, app.dpi);
                const canvas_render_bounds = inputBounds(client.right, client.bottom, app.workspace_controls).canvas;
                const canvas_bounds = c.RECT{
                    .left = canvas_render_bounds.left,
                    .top = canvas_render_bounds.top,
                    .right = canvas_render_bounds.right,
                    .bottom = canvas_render_bounds.bottom,
                };
                const next_connector = GraphCanvas.hitTestConnector(graph.nodes.items, hover_x, hover_y, &app.canvas, canvas_bounds);
                if (next_connector != app.canvas.hovered_connector) {
                    app.canvas.hovered_connector = next_connector;
                    _ = c.InvalidateRect(hwnd, null, 0);
                }
            }
        },
        c.WM_MOUSEWHEEL => {
            const wheel = CanvasInput.decodeWheelMessage(lparam, wparam);
            const screen_point = c.POINT{ .x = wheel.point.x, .y = wheel.point.y };
            const mapped = CanvasInput.screenToClient(hwnd, screen_point) orelse {
                result.* = 0;
                return true;
            };
            const x = logicalCoordinate(mapped.x, app.dpi);
            const y = logicalCoordinate(mapped.y, app.dpi);
            const delta = wheel.delta;
            const client = logicalClientRect(hwnd, app.dpi);
            const routing = inputBounds(client.right, client.bottom, app.workspace_controls);
            const sidebar_bottom = GraphCanvas.sidebarBottom(client.bottom, app.workspace_controls, app.surface);
            const region: WheelRegion = if (app.workspace_controls.rail_visible and
                x < routing.rail_left and
                y >= Tokens.header_height and
                y < sidebar_bottom)
                .sidebar
            else
                wheelRegion(x, y, routing, app.workspace_controls);
            switch (region) {
                .sidebar => {
                    app.sidebar_scroll = Sidebar.clampScroll(
                        app.sidebar_scroll - @divTrunc(@as(i32, delta), 4),
                        Sidebar.maxScroll(
                            &app.model,
                            if (app.worktree_inspection) |*value| value else null,
                            GraphCanvas.sidebarBottom(client.bottom, app.workspace_controls, app.surface),
                            &app.sidebar_state,
                        ),
                    );
                },
                .canvas => app.canvas.zoomAt(x, y, delta),
                .none => {},
            }
            app.syncAccessibility();
            _ = c.InvalidateRect(hwnd, null, 0);
            result.* = 0;
            return true;
        },
        c.WM_GESTURE => {
            // GESTUREINFO.ptsLocation is always screen-relative (per the
            // documented WM_GESTURE contract), so it must go through the
            // same ScreenToClient + region classification WM_MOUSEWHEEL uses
            // above before it can be compared against canvas bounds.
            const gesture_handle = Win32.messagePointer(c.HGESTUREINFO, lparam);
            var info: c.GESTUREINFO = std.mem.zeroes(c.GESTUREINFO);
            info.cbSize = @sizeOf(c.GESTUREINFO);
            if (c.GetGestureInfo(gesture_handle, &info) == 0) {
                // Could not even read the gesture; nothing to handle, and
                // per the handle-ownership contract an unhandled message
                // must be forwarded (not closed) so DefWindowProc still sees
                // it for any legacy fallback behavior.
                app.canvas.endPinchZoom();
                return false;
            }
            var gesture_client: c.RECT = undefined;
            if (c.GetClientRect(hwnd, &gesture_client) == 0) {
                // A failed GetClientRect leaves `gesture_client` undefined;
                // treating that as "in canvas" would classify against
                // garbage bounds. Reset any in-progress gesture and forward
                // unhandled -- this window cannot safely act on the message
                // without a valid client rect.
                app.canvas.endPinchZoom();
                return false;
            }
            const screen_point = c.POINT{ .x = info.ptsLocation.x, .y = info.ptsLocation.y };
            const geometry = gestureGeometry(CanvasInput.screenToClient(hwnd, screen_point), gesture_client, app.dpi, app.workspace_controls);
            const mapped = geometry.point;
            const in_canvas = gestureInCanvas(app.surface, mapped, geometry.bounds, app.workspace_controls);
            const distance: u32 = @truncate(info.ullArguments);
            const gesture_context = app.pinchGestureContext();
            switch (CanvasInput.classifyGesture(info.dwID, info.dwFlags, in_canvas)) {
                // GID_BEGIN/GID_END (the generic gesture-sequence brackets) and
                // any pan/zoom message located outside the canvas: this window
                // does not handle it, so per the documented handle-ownership
                // contract it must be forwarded to DefWindowProc rather than
                // closed here -- ownership of the handle transfers with the
                // message. Returning false relies on MainWindow.windowProc's
                // existing single DefWindowProcW forward; this case must
                // never call DefWindowProcW itself, or the handle would be
                // forwarded twice.
                .forward_unhandled, .forward_out_of_region => {
                    app.canvas.endPinchZoom();
                    return false;
                },
                .begin_zoom => {
                    app.canvas.beginPinchZoom(distance, gesture_context);
                    _ = c.CloseGestureInfoHandle(gesture_handle);
                    result.* = 0;
                    return true;
                },
                .begin_pan => {
                    if (mapped) |point| app.canvas.beginTouchPan(point.x, point.y, gesture_context);
                    _ = c.CloseGestureInfoHandle(gesture_handle);
                    result.* = 0;
                    return true;
                },
                .continue_zoom => {
                    if (mapped) |point| app.canvas.continuePinchZoom(point.x, point.y, distance, gesture_context);
                    // Release the owned handle before syncAccessibility()/
                    // InvalidateRect, which can pump messages -- this
                    // window's WM_GESTURE handling should never still be
                    // holding a handle open while other message handling
                    // runs.
                    _ = c.CloseGestureInfoHandle(gesture_handle);
                    app.syncAccessibility();
                    _ = c.InvalidateRect(hwnd, null, 0);
                    result.* = 0;
                    return true;
                },
                .end_zoom => {
                    if (mapped) |point| app.canvas.continuePinchZoom(point.x, point.y, distance, gesture_context);
                    app.canvas.endPinchZoom();
                    _ = c.CloseGestureInfoHandle(gesture_handle);
                    app.syncAccessibility();
                    _ = c.InvalidateRect(hwnd, null, 0);
                    result.* = 0;
                    return true;
                },
                .continue_pan => {
                    if (mapped) |point| app.canvas.continueTouchPan(point.x, point.y, gesture_context);
                    _ = c.CloseGestureInfoHandle(gesture_handle);
                    app.syncAccessibility();
                    _ = c.InvalidateRect(hwnd, null, 0);
                    result.* = 0;
                    return true;
                },
                .end_pan => {
                    if (mapped) |point| app.canvas.continueTouchPan(point.x, point.y, gesture_context);
                    app.canvas.endTouchPan();
                    _ = c.CloseGestureInfoHandle(gesture_handle);
                    app.syncAccessibility();
                    _ = c.InvalidateRect(hwnd, null, 0);
                    result.* = 0;
                    return true;
                },
                .begin_and_end_zoom => {
                    // A gesture short enough to arrive as a single message
                    // still begins a fresh baseline (recording this begin's
                    // context) and then immediately ends it, exactly as a
                    // real begin-then-end sequence would -- never treated as
                    // a continuation, which could otherwise apply whatever
                    // baseline a previous, unrelated gesture left behind.
                    app.canvas.beginPinchZoom(distance, gesture_context);
                    app.canvas.endPinchZoom();
                    _ = c.CloseGestureInfoHandle(gesture_handle);
                    result.* = 0;
                    return true;
                },
                .begin_and_end_pan => {
                    if (mapped) |point| app.canvas.beginTouchPan(point.x, point.y, gesture_context);
                    app.canvas.endTouchPan();
                    _ = c.CloseGestureInfoHandle(gesture_handle);
                    result.* = 0;
                    return true;
                },
            }
        },
        c.WM_SETFOCUS => {
            if (app.header_focus != null) {
                app.syncHeaderFocus();
                result.* = 0;
                return true;
            }
            if (app.workspace) |workspace| {
                if (app.surface == .workspace or app.workspace_controls.panel_visible) {
                    workspace.focusRestoredPane() catch app.setStatus("Unable to restore selected terminal focus");
                } else {
                    workspace.blurAll();
                }
            }
            result.* = 0;
            return true;
        },
        c.WM_KILLFOCUS => {
            if (app.header_focus != null and !app.header_focus_transition and c.IsWindowEnabled(hwnd) != 0) {
                app.leaveHeader(false);
            }
            result.* = 0;
            return true;
        },
        c.WM_ACTIVATE => {
            // DefWindowProc's default WM_ACTIVATE handling restores keyboard focus to whichever
            // child HWND last held it -- which can be a hidden terminal surface, since that child
            // (not this top-level window) is what actually receives OS focus when winghostty grabs
            // it. Run default processing first so unrelated activation bookkeeping still happens,
            // then reassert our own focus policy so a hidden workspace terminal can never win that
            // restoration race and keep stealing focus away from the rest of the app's chrome.
            const activated = (wparam & 0xffff) != c.WA_INACTIVE;
            const previous_transition = app.header_focus_transition;
            app.header_focus_transition = previous_transition or (activated and app.header_focus != null);
            defer app.header_focus_transition = previous_transition;
            result.* = c.DefWindowProcW(hwnd, message, wparam, lparam);
            if (!activated) {
                // Deactivation (e.g. Alt+Tab away, or another window taking
                // focus) can happen mid-pinch without ever delivering a
                // GID_END for it; clear the baseline so a later reactivation
                // cannot resume a stale gesture with a now-meaningless base
                // distance.
                app.canvas.endPinchZoom();
            }
            if (activated and app.header_focus != null) {
                _ = c.SetFocus(hwnd);
                app.syncHeaderFocus();
            } else if (activated) {
                if (app.workspace) |workspace| {
                    if (app.surface == .workspace or app.workspace_controls.panel_visible) {
                        workspace.focusRestoredPane() catch app.setStatus("Unable to restore selected terminal focus");
                    } else {
                        workspace.blurAll();
                        _ = c.SetFocus(hwnd);
                    }
                } else {
                    _ = c.SetFocus(hwnd);
                }
            }
            return true;
        },
        c.WM_CLOSE => {
            if (app.exit_requested) {
                _ = c.DestroyWindow(hwnd);
            } else {
                hideShellWindow(hwnd);
            }
            result.* = 0;
            return true;
        },
        c.WM_SYSCOMMAND => if ((wparam & 0xfff0) == c.SC_CLOSE) {
            if (app.exit_requested) {
                _ = c.DestroyWindow(hwnd);
            } else {
                hideShellWindow(hwnd);
            }
            result.* = 0;
            return true;
        },
        c.WM_DESTROY => {
            if (app.accessibility) |*provider| provider.detach();
            app.running = false;
            FolderOpenApi.cancelTimer(hwnd, folder_open_timer_id);
            _ = c.KillTimer(hwnd, MainWindow.timer_id);
            app.tray.remove();
            c.PostQuitMessage(0);
            result.* = 0;
            return true;
        },
        else => {},
    }

    return false;
}

fn hideShellWindow(hwnd: c.HWND) void {
    _ = c.ShowWindow(hwnd, c.SW_HIDE);
    _ = c.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        0,
        0,
        c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_HIDEWINDOW,
    );
}

fn restoreShellWindow(hwnd: c.HWND) void {
    _ = c.ShowWindow(hwnd, c.SW_RESTORE);
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.BringWindowToTop(hwnd);
    if (c.SetForegroundWindow(hwnd) == 0) {
        const foreground = c.GetForegroundWindow();
        if (foreground != null and foreground != hwnd) {
            const current_thread = c.GetCurrentThreadId();
            const foreground_thread = c.GetWindowThreadProcessId(foreground, null);
            if (foreground_thread != 0 and foreground_thread != current_thread and
                c.AttachThreadInput(current_thread, foreground_thread, 1) != 0)
            {
                defer _ = c.AttachThreadInput(current_thread, foreground_thread, 0);
                _ = c.BringWindowToTop(hwnd);
                _ = c.SetForegroundWindow(hwnd);
            }
        }
    }
    _ = c.SetFocus(hwnd);
}

fn setWorkspaceTestEnvironment(name: [*:0]const u16, value: ?[]const u8) !void {
    const wide = if (value) |text| try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, text) else null;
    defer if (wide) |text| std.testing.allocator.free(text);
    if (c.SetEnvironmentVariableW(name, if (wide) |text| text.ptr else null) == 0)
        return error.TestEnvironmentUpdateFailed;
}

test "connection settings invalidate lifecycle attribution until the reserved support is revalidated" {
    const allocator = std.testing.allocator;
    const support_key = std.unicode.utf8ToUtf16LeStringLiteral("GRAPHCODE_SUPPORT_DIR");
    const pipe_key = std.unicode.utf8ToUtf16LeStringLiteral("GRAPHCODE_DAEMON_PIPE");
    var original_environment = try std.process.getEnvMap(allocator);
    defer original_environment.deinit();
    defer setWorkspaceTestEnvironment(support_key, original_environment.get("GRAPHCODE_SUPPORT_DIR")) catch @panic("support environment restore failed");
    defer setWorkspaceTestEnvironment(pipe_key, original_environment.get("GRAPHCODE_DAEMON_PIPE")) catch @panic("pipe environment restore failed");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    for ([_][]const u8{ ".graphcode-alpha", ".graphcode-beta" }) |name| {
        var directory = try temporary.dir.makeOpenPath(name, .{});
        defer directory.close();
        try directory.writeFile(.{ .sub_path = ".graphcode-rendezvous.secret", .data = "workspace-fixture-not-a-secret!!" });
        try directory.writeFile(.{ .sub_path = "saved-state", .data = name });
    }
    const alpha = try temporary.dir.realpathAlloc(allocator, ".graphcode-alpha");
    defer allocator.free(alpha);
    const beta = try temporary.dir.realpathAlloc(allocator, ".graphcode-beta");
    defer allocator.free(beta);
    const pipe = try std.fmt.allocPrint(allocator, "\\\\.\\pipe\\graphcode-lifecycle-{x:0>32}", .{std.crypto.random.int(u128)});
    defer allocator.free(pipe);
    const second_pipe = try std.fmt.allocPrint(allocator, "{s}-changed", .{pipe});
    defer allocator.free(second_pipe);
    try setWorkspaceTestEnvironment(support_key, alpha);
    try setWorkspaceTestEnvironment(pipe_key, pipe);
    const hwnd = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC").ptr,
        std.unicode.utf8ToUtf16LeStringLiteral("Hidden workspace identity fixture").ptr,
        0,
        0,
        0,
        0,
        0,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.TestWindowCreationFailed;
    defer _ = c.DestroyWindow(hwnd);
    var app: App = .{
        .allocator = allocator,
        .window = .{ .hwnd = hwnd },
        .client = try DaemonClient.init(allocator),
        .daemon = undefined,
        .model = GraphModel.Model.init(allocator),
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
    };
    defer app.client.deinit();
    defer app.model.deinit();
    defer app.sidebar_state.deinit();
    defer app.declared_entry_ids.deinit();
    defer app.kept_worktree_paths.deinit();
    defer if (app.status_override.len != 0) allocator.free(app.status_override);
    try app.acquireSingleInstance();
    defer app.workspace_reservation.deinit();
    defer allocator.free(app.workspace_path);
    defer allocator.free(app.workspace_identity);
    const published_key = try workspaceInstanceKey(allocator, alpha);
    defer allocator.free(published_key);
    try app.revalidateWorkspaceIdentity();
    try std.testing.expect(MainWindow.workspaceIdentityMatches(hwnd, published_key));
    try app.applyWorkspaceConnectionSettings(second_pipe, alpha);
    try std.testing.expect(app.workspace_identity_valid);
    const alias = try std.fmt.allocPrint(allocator, "{s}\\ignored\\..\\", .{alpha});
    defer allocator.free(alias);
    try app.applyWorkspaceConnectionSettings(pipe, alias);
    try std.testing.expect(app.workspace_identity_valid);
    try std.testing.expectError(error.InvalidDaemonPipe, app.applyWorkspaceConnectionSettings("invalid-pipe", alpha));
    try std.testing.expect(app.workspace_identity_valid);
    try std.testing.expect(MainWindow.workspaceIdentityMatches(hwnd, published_key));

    try std.testing.expectError(error.WorkspaceRestartRequired, app.applyWorkspaceConnectionSettings(pipe, beta));
    try std.testing.expect(!app.workspace_identity_valid);
    try std.testing.expect(!MainWindow.workspaceIdentityMatches(hwnd, published_key));
    try std.testing.expectEqualStrings(workspace_restart_message, app.status());
    try std.testing.expectError(error.WorkspaceInUse, WorkspaceReservation.acquire(allocator, alpha));
    try std.testing.expectError(error.WorkspaceRestartRequired, app.applyWorkspaceConnectionSettings("invalid-pipe", alpha));
    app.createWorkspace();
    app.renameWorkspace();
    app.deleteWorkspace();
    app.launchWorkspace(beta);
    app.cycleWorkspace(1);
    try std.testing.expect(!app.workspace_identity_valid);
    try std.testing.expect(app.workspace_list == null);
    try std.testing.expectEqualStrings(alpha, app.workspace_path);
    for ([_][]const u8{ ".graphcode-alpha", ".graphcode-beta" }) |name| {
        var directory = try temporary.dir.openDir(name, .{});
        defer directory.close();
        const saved = try directory.readFileAlloc(allocator, "saved-state", 100);
        defer allocator.free(saved);
        try std.testing.expectEqualStrings(name, saved);
    }

    try app.applyWorkspaceConnectionSettings(pipe, alpha);
    try std.testing.expect(app.workspace_identity_valid);
    try std.testing.expect(!app.workspace_identity_blocked);
    try std.testing.expect(MainWindow.workspaceIdentityMatches(hwnd, published_key));
    try setWorkspaceTestEnvironment(support_key, "C:relative");
    try std.testing.expectError(error.InvalidWorkspacePath, app.revalidateWorkspaceIdentity());
    try std.testing.expect(!MainWindow.workspaceIdentityMatches(hwnd, published_key));
    try std.testing.expectEqualStrings(workspace_restart_message, app.status());
    try setWorkspaceTestEnvironment(support_key, alpha);

    const Probe = struct {
        fn run(failing: std.mem.Allocator, target: *App, key: [:0]const u16) !void {
            const previous = target.allocator;
            target.allocator = failing;
            defer target.allocator = previous;
            target.revalidateWorkspaceIdentity() catch |err| {
                try std.testing.expect(!target.workspace_identity_valid);
                try std.testing.expect(target.workspace_identity_blocked);
                try std.testing.expect(!MainWindow.workspaceIdentityMatches(target.window.hwnd, key));
                try std.testing.expectEqualStrings(workspace_restart_message, target.status());
                return err;
            };
            try std.testing.expect(target.workspace_identity_valid);
            try std.testing.expect(MainWindow.workspaceIdentityMatches(target.window.hwnd, key));
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Probe.run, .{ &app, published_key });
    try app.revalidateWorkspaceIdentity();
    try std.testing.expectError(error.WorkspaceInUse, WorkspaceReservation.acquire(allocator, alpha));
}

test "workspace manager window states use only injected identity lookup and fail closed" {
    const Probe = struct {
        var result: MainWindow.WorkspaceWindows = .{};
        var fail = false;
        fn windows(key: [:0]const u16) !MainWindow.WorkspaceWindows {
            try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("owned-test-key"), key);
            if (fail) return error.WorkspaceWindowOwnerUnknown;
            return result;
        }
    };
    const key = std.unicode.utf8ToUtf16LeStringLiteral("owned-test-key");
    Probe.fail = false;
    Probe.result = .{};
    try std.testing.expectEqual(WorkspaceManager.WindowState.closed, workspaceManagerWindowState(Probe, key));
    Probe.result.target = Win32.opaquePointerFromInt(c.HWND, 1);
    try std.testing.expectEqual(WorkspaceManager.WindowState.open, workspaceManagerWindowState(Probe, key));
    Probe.result.unidentified = true;
    try std.testing.expectEqual(WorkspaceManager.WindowState.unidentified, workspaceManagerWindowState(Probe, key));
    Probe.fail = true;
    try std.testing.expectEqual(WorkspaceManager.WindowState.unavailable, workspaceManagerWindowState(Probe, key));
}

test "workspace open routes current restore and cold launch exactly once" {
    const Probe = struct {
        var lookup: MainWindow.WorkspaceWindows = .{};
        var lookups: usize = 0;
        var restores: usize = 0;
        var launches: usize = 0;
        var fail_lookup = false;
        var fail_launch = false;
        var expected_key: [:0]const u16 = undefined;

        fn windows(key: [:0]const u16) !MainWindow.WorkspaceWindows {
            lookups += 1;
            try std.testing.expectEqualSlices(u16, expected_key, key);
            if (fail_lookup) return error.WorkspaceWindowLookupFailed;
            return lookup;
        }
        fn restore(key: [:0]const u16) !void {
            restores += 1;
            try std.testing.expectEqualSlices(u16, expected_key, key);
        }
        fn launch(_: std.mem.Allocator, path: []const u8) !void {
            launches += 1;
            try std.testing.expectEqualStrings("C:\\fixture\\.graphcode-beta", path);
            if (fail_launch) return error.WorkspaceLaunchFailed;
        }
    };
    const allocator = std.testing.allocator;
    const path = "C:\\fixture\\.graphcode-beta";
    const identity = try WorkspaceLifecycle.pathIdentity(allocator, path);
    defer allocator.free(identity);
    const key = try workspaceInstanceKey(allocator, path);
    defer allocator.free(key);
    Probe.expected_key = key;
    Probe.lookup = .{};
    Probe.lookups = 0;
    Probe.restores = 0;
    Probe.launches = 0;
    Probe.fail_lookup = false;
    Probe.fail_launch = false;
    try std.testing.expectEqual(WorkspaceOpenResult.current, try openWorkspaceWith(Probe, allocator, identity, "c:/FIXTURE/./.graphcode-beta/"));
    try std.testing.expectEqual(@as(usize, 0), Probe.lookups + Probe.restores + Probe.launches);
    try std.testing.expectEqual(WorkspaceOpenResult.launched, try openWorkspaceWith(Probe, allocator, "c:/fixture/.graphcode-alpha", path));
    try std.testing.expectEqual(@as(usize, 1), Probe.launches);
    Probe.lookup.target = Win32.opaquePointerFromInt(c.HWND, 1);
    try std.testing.expectEqual(WorkspaceOpenResult.restored, try openWorkspaceWith(Probe, allocator, "c:/fixture/.graphcode-alpha", path));
    try std.testing.expectEqual(@as(usize, 1), Probe.restores);
    try std.testing.expectEqual(@as(usize, 1), Probe.launches);
    Probe.lookup = .{ .unidentified = true };
    try std.testing.expectError(error.UnidentifiedWorkspaceWindow, openWorkspaceWith(Probe, allocator, "c:/fixture/.graphcode-alpha", path));
    Probe.fail_lookup = true;
    try std.testing.expectError(error.WorkspaceWindowLookupFailed, openWorkspaceWith(Probe, allocator, "c:/fixture/.graphcode-alpha", path));
    try std.testing.expectEqual(@as(usize, 1), Probe.launches);
    Probe.fail_lookup = false;
    Probe.lookup = .{};
    Probe.fail_launch = true;
    try std.testing.expectError(error.WorkspaceLaunchFailed, openWorkspaceWith(Probe, allocator, "c:/fixture/.graphcode-alpha", path));
    try std.testing.expectEqual(@as(usize, 2), Probe.launches);
}

test "workspace child environment isolates its endpoint and leaves parent and restore environments unchanged" {
    const allocator = std.testing.allocator;
    const support_key = std.unicode.utf8ToUtf16LeStringLiteral("GRAPHCODE_SUPPORT_DIR");
    const pipe_key = std.unicode.utf8ToUtf16LeStringLiteral("GRAPHCODE_DAEMON_PIPE");
    var original = try std.process.getEnvMap(allocator);
    defer original.deinit();
    defer setWorkspaceTestEnvironment(support_key, original.get("GRAPHCODE_SUPPORT_DIR")) catch @panic("support environment restore failed");
    defer setWorkspaceTestEnvironment(pipe_key, original.get("GRAPHCODE_DAEMON_PIPE")) catch @panic("pipe environment restore failed");
    const parent_support = "C:\\fixture\\.graphcode-parent";
    const child_support = "C:\\fixture\\.graphcode-child";
    const parent_pipe = try std.fmt.allocPrint(allocator, "\\\\.\\pipe\\graphcode-lifecycle-{x:0>32}", .{std.crypto.random.int(u128)});
    defer allocator.free(parent_pipe);
    try setWorkspaceTestEnvironment(support_key, parent_support);
    try setWorkspaceTestEnvironment(pipe_key, parent_pipe);
    var before = try std.process.getEnvMap(allocator);
    defer before.deinit();
    const block = try workspaceEnvironment(allocator, child_support);
    defer allocator.free(block);
    try std.testing.expect(block.len >= 2 and block[block.len - 1] == 0 and block[block.len - 2] == 0);
    var decoded = std.process.EnvMap.init(allocator);
    defer decoded.deinit();
    var entries = std.mem.splitScalar(u16, block, 0);
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        const text = try std.unicode.utf16LeToUtf8Alloc(allocator, entry);
        defer allocator.free(text);
        const separator = std.mem.indexOfScalarPos(u8, text, 1, '=') orelse return error.InvalidEnvironmentEntry;
        try decoded.put(text[0..separator], text[separator + 1 ..]);
    }
    try std.testing.expectEqualStrings(child_support, decoded.get("GRAPHCODE_SUPPORT_DIR") orelse return error.MissingChildSupport);
    try std.testing.expect(decoded.get("GRAPHCODE_DAEMON_PIPE") == null);
    var inherited = before.iterator();
    while (inherited.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "GRAPHCODE_SUPPORT_DIR") or
            std.ascii.eqlIgnoreCase(entry.key_ptr.*, "GRAPHCODE_DAEMON_PIPE")) continue;
        try std.testing.expectEqualStrings(entry.value_ptr.*, decoded.get(entry.key_ptr.*) orelse return error.MissingInheritedVariable);
    }

    const RestoreOnly = struct {
        var lookups: usize = 0;
        var restores: usize = 0;

        fn windows(_: [:0]const u16) !MainWindow.WorkspaceWindows {
            lookups += 1;
            return .{ .target = Win32.opaquePointerFromInt(c.HWND, 1) };
        }
        fn restore(_: [:0]const u16) !void {
            restores += 1;
        }
        fn launch(_: std.mem.Allocator, _: []const u8) !void {
            return error.UnexpectedWorkspaceLaunch;
        }
    };
    RestoreOnly.lookups = 0;
    RestoreOnly.restores = 0;
    const parent_identity = try WorkspaceLifecycle.pathIdentity(allocator, parent_support);
    defer allocator.free(parent_identity);
    try std.testing.expectEqual(WorkspaceOpenResult.current, try openWorkspaceWith(RestoreOnly, allocator, parent_identity, parent_support));
    try std.testing.expectEqual(@as(usize, 0), RestoreOnly.lookups + RestoreOnly.restores);
    try std.testing.expectEqual(WorkspaceOpenResult.restored, try openWorkspaceWith(RestoreOnly, allocator, parent_identity, child_support));
    try std.testing.expectEqual(@as(usize, 1), RestoreOnly.lookups);
    try std.testing.expectEqual(@as(usize, 1), RestoreOnly.restores);
    var after = try std.process.getEnvMap(allocator);
    defer after.deinit();
    try std.testing.expectEqualStrings(parent_support, after.get("GRAPHCODE_SUPPORT_DIR").?);
    try std.testing.expectEqualStrings(parent_pipe, after.get("GRAPHCODE_DAEMON_PIPE").?);
    var original_entries = before.iterator();
    while (original_entries.next()) |entry| {
        try std.testing.expectEqualStrings(entry.value_ptr.*, after.get(entry.key_ptr.*) orelse return error.ParentEnvironmentChanged);
    }
    var final_entries = after.iterator();
    while (final_entries.next()) |entry| {
        try std.testing.expect(before.get(entry.key_ptr.*) != null);
    }
}

test "workspace reservations exclude lexical aliases and old raw path mutexes" {
    const allocator = std.testing.allocator;
    const user = try std.fmt.allocPrint(allocator, "workspace-test-{d}-{d}", .{ c.GetCurrentProcessId(), std.crypto.random.int(u64) });
    defer allocator.free(user);
    const path = "C:\\fixture\\.graphcode-alpha";
    {
        var held = try WorkspaceReservation.acquireForUser(allocator, user, path);
        defer held.deinit();
        try std.testing.expectError(error.WorkspaceInUse, WorkspaceReservation.acquireForUser(allocator, user, "c:/FIXTURE/./.graphcode-alpha/"));
        var distinct = try WorkspaceReservation.acquireForUser(allocator, user, "C:\\fixture\\.graphcode-beta");
        defer distinct.deinit();
    }
    const legacy_name = try WorkspaceLifecycle.legacyInstanceName(allocator, user, path);
    defer allocator.free(legacy_name);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, legacy_name);
    defer allocator.free(wide);
    {
        const legacy = c.CreateMutexW(null, 1, wide.ptr) orelse return error.TestMutexCreationFailed;
        defer {
            _ = c.ReleaseMutex(legacy);
            _ = c.CloseHandle(legacy);
        }
        try std.testing.expect(c.GetLastError() != c.ERROR_ALREADY_EXISTS);
        try std.testing.expectError(error.WorkspaceInUse, WorkspaceReservation.acquireForUser(allocator, user, path));
    }
    var reacquired = try WorkspaceReservation.acquireForUser(allocator, user, path);
    defer reacquired.deinit();
}

test "workspace identity uses the Windows account instead of optional environment variables" {
    const Api = struct {
        fn read(buffer: [*]u16, size: *c.DWORD) bool {
            const value = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeUser");
            if (size.* < value.len) return false;
            @memcpy(buffer[0..value.len], value);
            size.* = value.len;
            return true;
        }
    };
    const user = try workspaceUserWith(std.testing.allocator, Api);
    defer std.testing.allocator.free(user);
    try std.testing.expectEqualStrings("GraphCodeUser", user);
}

test "workspace identity reports a bounded Windows account failure" {
    const Api = struct {
        fn read(_: [*]u16, _: *c.DWORD) bool {
            return false;
        }
    };
    try std.testing.expectError(
        error.WorkspaceUserUnavailable,
        workspaceUserWith(std.testing.allocator, Api),
    );
}

const WorkspaceMutationFixture = struct {
    const reserve = WorkspaceReservation.acquire;
    const rename = WorkspaceMutationApi.rename;
    var response: c.INT = c.IDNO;
    var confirmations: usize = 0;
    var deletions: usize = 0;
    var lookups: usize = 0;
    var unidentified = false;
    var unidentified_after_confirmation = false;
    var fail_lookup = false;
    var held_during_confirmation = false;
    var expected_path: []const u8 = "";
    var skip_delete = false;
    var list_to_release: ?*WorkspaceLifecycle.List = null;
    var list_released = false;

    fn reset(path: []const u8) void {
        response = c.IDNO;
        confirmations = 0;
        deletions = 0;
        lookups = 0;
        unidentified = false;
        unidentified_after_confirmation = false;
        fail_lookup = false;
        held_during_confirmation = false;
        expected_path = path;
        skip_delete = false;
        list_to_release = null;
        list_released = false;
    }
    fn windows(_: [:0]const u16) !MainWindow.WorkspaceWindows {
        lookups += 1;
        if (fail_lookup) return error.WorkspaceWindowLookupFailed;
        return .{ .unidentified = unidentified or (unidentified_after_confirmation and confirmations != 0) };
    }
    fn confirm(_: c.HWND) c.INT {
        confirmations += 1;
        if (WorkspaceReservation.acquire(std.testing.allocator, expected_path)) |value| {
            var unexpected = value;
            unexpected.deinit();
        } else |err| {
            held_during_confirmation = err == error.WorkspaceInUse;
        }
        if (list_to_release) |list| {
            list.deinit(std.testing.allocator);
            list_to_release = null;
            list_released = true;
        }
        return response;
    }
    /// Deletion is simulated here: App owns the refusals and the confirmation, while the
    /// recoverable teardown itself is proven in WorkspaceTeardown against its own seam. No
    /// test ever recycles a folder, signals a daemon, or kills a session.
    fn delete(
        allocator: std.mem.Allocator,
        path: []const u8,
        current_identity: []const u8,
    ) !WorkspaceTeardown.Report {
        _ = allocator;
        _ = current_identity;
        deletions += 1;
        try std.testing.expectEqualStrings(expected_path, path);
        if (!skip_delete) try std.fs.deleteTreeAbsolute(path);
        return .{ .outcome = .deleted, .sessions_targeted = 0, .sessions_known = true };
    }
};

fn namedWorkspaceFixture(list: WorkspaceLifecycle.List, name: []const u8) !WorkspaceLifecycle.Workspace {
    for (list.items) |workspace| {
        if (std.mem.eql(u8, name, workspace.name)) return workspace;
    }
    return error.MissingFixtureWorkspace;
}

test "workspace deletion guards default current open legacy and every non Yes response" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir(".graphcode-alpha");
    try temporary.dir.makeDir(".graphcode-beta");
    try temporary.dir.writeFile(.{ .sub_path = ".graphcode-alpha\\saved-state", .data = "alpha-state" });
    try temporary.dir.writeFile(.{ .sub_path = ".graphcode-beta\\saved-state", .data = "beta-state" });
    const home = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(home);
    var list = try WorkspaceLifecycle.listFromHome(allocator, home);
    defer if (!WorkspaceMutationFixture.list_released) list.deinit(allocator);
    const alpha = try namedWorkspaceFixture(list, "alpha");
    const default = try namedWorkspaceFixture(list, "Default");
    const saved_alpha_path = try allocator.dupe(u8, alpha.path);
    defer allocator.free(saved_alpha_path);
    WorkspaceMutationFixture.reset(alpha.path);
    try std.testing.expectError(error.DefaultWorkspace, mutateWorkspaceWith(WorkspaceMutationFixture, allocator, null, alpha.identity, default, .delete));
    try std.testing.expectError(error.CurrentWorkspace, mutateWorkspaceWith(WorkspaceMutationFixture, allocator, null, alpha.identity, alpha, .delete));
    {
        var open = try WorkspaceReservation.acquire(allocator, alpha.path);
        defer open.deinit();
        try std.testing.expectError(error.WorkspaceInUse, mutateWorkspaceWith(WorkspaceMutationFixture, allocator, null, default.identity, alpha, .delete));
    }
    WorkspaceMutationFixture.unidentified = true;
    try std.testing.expectError(error.UnidentifiedWorkspaceWindow, mutateWorkspaceWith(WorkspaceMutationFixture, allocator, null, default.identity, alpha, .delete));
    WorkspaceMutationFixture.unidentified = false;
    WorkspaceMutationFixture.fail_lookup = true;
    try std.testing.expectError(error.WorkspaceWindowLookupFailed, mutateWorkspaceWith(WorkspaceMutationFixture, allocator, null, default.identity, alpha, .delete));
    try std.testing.expectEqual(@as(usize, 0), WorkspaceMutationFixture.confirmations);
    try std.testing.expectEqual(@as(usize, 0), WorkspaceMutationFixture.deletions);
    for ([_]c.INT{ c.IDNO, c.IDCANCEL, c.IDCLOSE, c.IDOK, 0, -1 }) |response| {
        WorkspaceMutationFixture.reset(alpha.path);
        WorkspaceMutationFixture.response = response;
        try std.testing.expectEqual(WorkspaceMutationResult.cancelled, try mutateWorkspaceWith(WorkspaceMutationFixture, allocator, null, default.identity, alpha, .delete));
        try std.testing.expect(WorkspaceMutationFixture.held_during_confirmation);
        try std.testing.expectEqual(@as(usize, 1), WorkspaceMutationFixture.confirmations);
        try std.testing.expectEqual(@as(usize, 0), WorkspaceMutationFixture.deletions);
        const saved = try temporary.dir.readFileAlloc(allocator, ".graphcode-alpha\\saved-state", 100);
        defer allocator.free(saved);
        try std.testing.expectEqualStrings("alpha-state", saved);
    }
    WorkspaceMutationFixture.reset(alpha.path);
    WorkspaceMutationFixture.response = c.IDYES;
    WorkspaceMutationFixture.unidentified_after_confirmation = true;
    try std.testing.expectError(error.UnidentifiedWorkspaceWindow, mutateWorkspaceWith(WorkspaceMutationFixture, allocator, null, default.identity, alpha, .delete));
    try std.testing.expectEqual(@as(usize, 0), WorkspaceMutationFixture.deletions);
    WorkspaceMutationFixture.reset(alpha.path);
    WorkspaceMutationFixture.response = c.IDYES;
    WorkspaceMutationFixture.skip_delete = true;
    _ = try mutateWorkspaceWith(WorkspaceMutationFixture, allocator, null, default.identity, alpha, .delete);
    try std.testing.expectError(error.WorkspaceStillExists, requireDeletedWorkspace(alpha.path));
    WorkspaceMutationFixture.reset(saved_alpha_path);
    WorkspaceMutationFixture.response = c.IDYES;
    WorkspaceMutationFixture.list_to_release = &list;
    var torn_down = try mutateWorkspaceWith(WorkspaceMutationFixture, allocator, null, default.identity, alpha, .delete);
    defer torn_down.torn_down.deinit(allocator);
    try std.testing.expectEqual(WorkspaceTeardown.Outcome.deleted, torn_down.torn_down.outcome);
    try std.testing.expect(WorkspaceMutationFixture.held_during_confirmation);
    try std.testing.expectEqual(@as(usize, 1), WorkspaceMutationFixture.deletions);
    try requireDeletedWorkspace(saved_alpha_path);
    const untouched = try temporary.dir.readFileAlloc(allocator, ".graphcode-beta\\saved-state", 100);
    defer allocator.free(untouched);
    try std.testing.expectEqualStrings("beta-state", untouched);
}

test "workspace delete confirmation makes No the default and uses a warning" {
    try std.testing.expectEqual(c.MB_YESNO, workspace_delete_confirmation_flags & c.MB_TYPEMASK);
    try std.testing.expectEqual(c.MB_DEFBUTTON2, workspace_delete_confirmation_flags & c.MB_DEFMASK);
    try std.testing.expectEqual(c.MB_ICONWARNING, workspace_delete_confirmation_flags & c.MB_ICONMASK);
}

test "workspace cancelled mutation releases every partial allocation and reservation" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir(".graphcode-alpha");
    const home = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(home);
    var list = try WorkspaceLifecycle.listFromHome(allocator, home);
    defer list.deinit(allocator);
    const alpha = try namedWorkspaceFixture(list, "alpha");
    const default = try namedWorkspaceFixture(list, "Default");
    const Probe = struct {
        fn run(failing: std.mem.Allocator, current_identity: []const u8, workspace: WorkspaceLifecycle.Workspace) !void {
            WorkspaceMutationFixture.reset(workspace.path);
            try std.testing.expectEqual(WorkspaceMutationResult.cancelled, try mutateWorkspaceWith(
                WorkspaceMutationFixture,
                failing,
                null,
                current_identity,
                workspace,
                .delete,
            ));
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Probe.run, .{ default.identity, alpha });
    var reacquired = try WorkspaceReservation.acquire(allocator, alpha.path);
    defer reacquired.deinit();
}

fn requireDeletedWorkspace(path: []const u8) !void {
    var directory = std.fs.openDirAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    directory.close();
    return error.WorkspaceStillExists;
}

test "workspace rename preserves saved bytes and never replaces a colliding workspace" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir(".graphcode-alpha");
    try temporary.dir.makeDir(".graphcode-beta");
    try temporary.dir.writeFile(.{ .sub_path = ".graphcode-alpha\\saved-state", .data = "alpha-state" });
    try temporary.dir.writeFile(.{ .sub_path = ".graphcode-beta\\saved-state", .data = "beta-state" });
    const home = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(home);
    var list = try WorkspaceLifecycle.listFromHome(allocator, home);
    defer list.deinit(allocator);
    const alpha = try namedWorkspaceFixture(list, "alpha");
    const beta = try namedWorkspaceFixture(list, "beta");
    const default = try namedWorkspaceFixture(list, "Default");
    WorkspaceMutationFixture.reset(alpha.path);
    try std.testing.expectError(error.WorkspaceRenameFailed, mutateWorkspaceWith(WorkspaceMutationFixture, allocator, null, default.identity, alpha, .{ .rename = beta.path }));
    const destination = try WorkspaceLifecycle.workspacePath(allocator, "renamed", home);
    defer allocator.free(destination);
    try std.testing.expectEqual(WorkspaceMutationResult.renamed, try mutateWorkspaceWith(WorkspaceMutationFixture, allocator, null, default.identity, alpha, .{ .rename = destination }));
    try requireDeletedWorkspace(alpha.path);
    const saved = try temporary.dir.readFileAlloc(allocator, ".graphcode-renamed\\saved-state", 100);
    defer allocator.free(saved);
    const untouched = try temporary.dir.readFileAlloc(allocator, ".graphcode-beta\\saved-state", 100);
    defer allocator.free(untouched);
    try std.testing.expectEqualStrings("alpha-state", saved);
    try std.testing.expectEqualStrings("beta-state", untouched);
    try std.testing.expectEqual(@as(usize, 0), WorkspaceMutationFixture.confirmations + WorkspaceMutationFixture.deletions);
}

test "workspace running cycle never launches a closed workspace" {
    const Probe = struct {
        var launches: usize = 0;
        fn list(allocator: std.mem.Allocator, _: []const u8) !WorkspaceLifecycle.List {
            return WorkspaceLifecycle.managerList(allocator, &.{
                .{ .name = "alpha", .path = "C:\\fixture\\.graphcode-alpha", .identity = "c:/fixture/.graphcode-alpha", .is_default = false },
                .{ .name = "beta", .path = "C:\\fixture\\.graphcode-beta", .identity = "c:/fixture/.graphcode-beta", .is_default = false },
            }, "C:\\fixture", "C:\\fixture\\.graphcode-alpha");
        }
        fn instanceKey(allocator: std.mem.Allocator, path: []const u8) ![:0]u16 {
            return std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
        }
        fn windows(_: [:0]const u16) !struct { target: ?usize = null, unidentified: bool = false } {
            return .{};
        }
        fn restore(_: [:0]const u16) !void {
            return error.UnexpectedRestore;
        }
        fn launch(_: std.mem.Allocator, _: []const u8) !void {
            launches += 1;
        }
    };
    Probe.launches = 0;
    _ = try cycleWorkspaceWith(Probe, std.testing.allocator, "C:\\fixture\\.graphcode-alpha", "c:/fixture/.graphcode-alpha", 1);
    try std.testing.expectEqual(@as(usize, 0), Probe.launches);
}

test "App.dispatchWorkspaceKey routes clipboard shortcuts only with terminal context" {
    const copy_active = App.dispatchWorkspaceKey('C', true, true, true);
    try std.testing.expectEqual(
        std.meta.Tag(WorkspaceKeyRoute).copy_terminal_selection,
        std.meta.activeTag(copy_active),
    );
    const paste_active = App.dispatchWorkspaceKey('V', true, true, true);
    try std.testing.expectEqual(
        std.meta.Tag(WorkspaceKeyRoute).paste_clipboard_text,
        std.meta.activeTag(paste_active),
    );

    const copy_inactive = App.dispatchWorkspaceKey('C', true, true, false);
    try std.testing.expectEqual(
        std.meta.Tag(WorkspaceKeyRoute).action,
        std.meta.activeTag(copy_inactive),
    );
    try std.testing.expectEqual(InputRouter.Action.clone_repository, copy_inactive.action);
    const paste_inactive = App.dispatchWorkspaceKey('V', true, true, false);
    try std.testing.expectEqual(InputRouter.Action.none, paste_inactive.action);
    try std.testing.expectEqual(
        InputRouter.Action.clone_repository,
        fallbackKeyAction('C', true, true, false),
    );
}

test "terminalPasteFailureStatus exposes provider paste safety rejections" {
    try std.testing.expectEqualStrings(
        "Terminal blocked unsafe clipboard text; paste a single line to continue",
        terminalPasteFailureStatus(error.TerminalPasteRequiresConfirmation),
    );
    try std.testing.expectEqualStrings(
        "Terminal clipboard is unavailable",
        terminalPasteFailureStatus(error.TerminalClipboardUnavailable),
    );
}

test "workspace cycle keyboard fallback never turns Alt paging into terminal tabs" {
    try std.testing.expectEqual(InputRouter.Action.none, fallbackKeyAction(c.VK_NEXT, true, false, true));
    try std.testing.expectEqual(InputRouter.Action.none, fallbackKeyAction(c.VK_PRIOR, true, false, true));
    for ([_]bool{ false, true }) |ctrl| {
        for ([_]bool{ false, true }) |shift| {
            for ([_]usize{ c.VK_PRIOR, c.VK_NEXT }) |key| {
                try std.testing.expectEqual(InputRouter.Action.none, fallbackKeyAction(key, ctrl, shift, true));
                try std.testing.expectEqual(InputRouter.keyAction(key, ctrl, shift), fallbackKeyAction(key, ctrl, shift, false));
            }
        }
    }
    try std.testing.expectEqual(InputRouter.Action.select_next_tab, fallbackKeyAction(c.VK_NEXT, true, false, false));
    try std.testing.expectEqual(InputRouter.Action.select_previous_tab, fallbackKeyAction(c.VK_PRIOR, true, false, false));
    try std.testing.expectEqual(InputRouter.Action.none, fallbackKeyAction(c.VK_F6, false, false, false));
    try std.testing.expectEqual(InputRouter.Action.none, fallbackKeyAction(c.VK_F10, false, false, false));
    try std.testing.expectEqual(InputRouter.Action.cycle_attention, fallbackKeyAction(c.VK_TAB, true, false, false));
}

const WorkspaceCycleFixture = struct {
    const wide = std.unicode.utf8ToUtf16LeStringLiteral;
    const home = "C:\\fixture";
    const default_path = "C:\\fixture\\.graphcode";
    const outside = "D:\\Nonstandard\\Current";
    const rows = [_]WorkspaceLifecycle.Workspace{
        .{ .name = "beta", .path = "C:\\fixture\\.graphcode-beta", .identity = "c:/fixture/.graphcode-beta", .is_default = false, .created_at = 2 },
        .{ .name = "unknown", .path = "C:\\fixture\\.graphcode-unknown", .identity = "c:/fixture/.graphcode-unknown", .is_default = false },
        .{ .name = "alpha", .path = "C:\\fixture\\.graphcode-alpha", .identity = "c:/fixture/.graphcode-alpha", .is_default = false, .created_at = 2 },
        .{ .name = "Zulu", .path = "C:\\fixture\\.graphcode-Zulu", .identity = "c:/fixture/.graphcode-zulu", .is_default = false, .created_at = 2 },
        .{ .name = "old", .path = "C:\\fixture\\.graphcode-old", .identity = "c:/fixture/.graphcode-old", .is_default = false, .created_at = 1 },
        .{ .name = "Default", .path = default_path, .identity = "c:/fixture/.graphcode", .is_default = true },
        .{ .name = "alias", .path = "c:/FIXTURE/./.graphcode-alpha/", .identity = "c:/fixture/.graphcode-alpha", .is_default = false },
    };
    var known: []const WorkspaceLifecycle.Workspace = &rows;
    var open: []const []const u16 = &.{};
    var expected_restore: []const u16 = &.{};
    var lists: usize = 0;
    var lookups: usize = 0;
    var restores: usize = 0;
    var launches: usize = 0;
    var omit_current = false;
    var list_error: ?anyerror = null;
    var key_error: ?anyerror = null;
    var lookup_error: ?anyerror = null;
    var lookup_error_at: usize = 1;
    var unidentified_at: ?usize = null;
    var close_at: ?usize = null;
    var restore_error: ?anyerror = null;
    var release_source: ?*WorkspaceLifecycle.List = null;

    fn reset() void {
        known = &rows;
        open = &.{};
        expected_restore = &.{};
        lists = 0;
        lookups = 0;
        restores = 0;
        launches = 0;
        omit_current = false;
        list_error = null;
        key_error = null;
        lookup_error = null;
        lookup_error_at = 1;
        unidentified_at = null;
        close_at = null;
        restore_error = null;
        release_source = null;
    }

    fn list(allocator: std.mem.Allocator, current: []const u8) !WorkspaceLifecycle.List {
        lists += 1;
        if (list_error) |err| return err;
        if (omit_current) return .{ .items = try allocator.alloc(WorkspaceLifecycle.Workspace, 0) };
        const result = try WorkspaceLifecycle.managerList(allocator, known, home, current);
        if (release_source) |source| {
            source.deinit(allocator);
            release_source = null;
            known = &.{};
        }
        return result;
    }

    fn instanceKey(allocator: std.mem.Allocator, path: []const u8) ![:0]u16 {
        if (key_error) |err| return err;
        return std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
    }

    fn windows(key: [:0]const u16) !struct { target: ?usize = null, unidentified: bool = false } {
        lookups += 1;
        if (lookups == lookup_error_at) {
            if (lookup_error) |err| return err;
        }
        if (close_at == lookups) return .{};
        for (open) |path| {
            if (std.mem.eql(u16, path, key)) return .{ .target = 1, .unidentified = unidentified_at == lookups };
        }
        return .{ .unidentified = unidentified_at == lookups };
    }

    fn restore(key: [:0]const u16) !void {
        restores += 1;
        try std.testing.expectEqualSlices(u16, expected_restore, key);
        if (restore_error) |err| return err;
    }

    fn launch(_: std.mem.Allocator, _: []const u8) !void {
        launches += 1;
    }

    fn cycle(allocator: std.mem.Allocator, current: []const u8, direction: isize) !WorkspaceCycleResult {
        const identity = try WorkspaceLifecycle.pathIdentity(allocator, current);
        defer allocator.free(identity);
        return cycleWorkspaceWith(@This(), allocator, current, identity, direction);
    }
};

test "workspace running cycle keeps creation order ordinal ties unknown last dedup and both wraps" {
    const F = WorkspaceCycleFixture;
    F.reset();
    const ordered = [_][]const u8{
        F.default_path, F.rows[4].path, F.rows[3].path, F.rows[2].path, F.rows[0].path, F.rows[1].path,
    };
    F.open = &.{
        F.wide(F.default_path), F.wide(F.rows[4].path), F.wide(F.rows[3].path),
        F.wide(F.rows[2].path), F.wide(F.rows[0].path), F.wide(F.rows[1].path),
    };
    for (ordered, 0..) |current, index| {
        for ([_]isize{ -13, -7, -1, 1, 7, 13 }) |direction| {
            const expected: usize = @intCast(@mod(@as(isize, @intCast(index)) + direction, 6));
            F.expected_restore = F.open[expected];
            try std.testing.expectEqual(WorkspaceCycleResult.restored, try F.cycle(std.testing.allocator, current, direction));
        }
    }
    try std.testing.expectEqual(@as(usize, 36), F.restores);
    try std.testing.expectEqual(@as(usize, 0), F.launches);
}

test "workspace running cycle rereads candidates skips closed and includes nonstandard outside current" {
    const F = WorkspaceCycleFixture;
    F.reset();
    F.open = &.{ F.wide(F.default_path), F.wide(F.rows[0].path) };
    F.expected_restore = F.wide(F.default_path);
    try std.testing.expectEqual(WorkspaceCycleResult.restored, try F.cycle(std.testing.allocator, F.outside, 1));
    F.expected_restore = F.wide(F.rows[0].path);
    try std.testing.expectEqual(WorkspaceCycleResult.restored, try F.cycle(std.testing.allocator, F.outside, -1));
    F.open = &.{};
    try std.testing.expectEqual(WorkspaceCycleResult.no_other, try F.cycle(std.testing.allocator, F.outside, -1));
    F.open = &.{F.wide(F.rows[4].path)};
    F.expected_restore = F.open[0];
    try std.testing.expectEqual(WorkspaceCycleResult.restored, try F.cycle(std.testing.allocator, F.outside, 1));
    try std.testing.expectEqual(@as(usize, 4), F.lists);
    try std.testing.expectEqual(@as(usize, 3), F.restores);
    try std.testing.expectEqual(@as(usize, 0), F.launches);
}

test "workspace running cycle zero one missing current and self offsets do not restore or launch" {
    const F = WorkspaceCycleFixture;
    F.reset();
    F.known = &.{};
    try std.testing.expectEqual(WorkspaceCycleResult.no_other, try F.cycle(std.testing.allocator, F.default_path, 1));
    try std.testing.expectEqual(@as(usize, 0), F.lookups);
    F.known = &F.rows;
    try std.testing.expectEqual(WorkspaceCycleResult.no_other, try F.cycle(std.testing.allocator, F.default_path, -1));
    F.open = &.{F.wide(F.rows[0].path)};
    for ([_]isize{ 0, 2, -2, std.math.minInt(isize) }) |direction| {
        try std.testing.expectEqual(WorkspaceCycleResult.current, try F.cycle(std.testing.allocator, F.default_path, direction));
    }
    F.omit_current = true;
    try std.testing.expectError(error.CurrentWorkspaceMissing, F.cycle(std.testing.allocator, F.default_path, 1));
    try std.testing.expectError(error.WorkspaceIdentityChanged, cycleWorkspaceWith(F, std.testing.allocator, F.default_path, "c:/different", 1));
    try std.testing.expectEqual(@as(usize, 0), F.restores + F.launches);
}

test "workspace running cycle propagates owner session key lookup and unidentified failures" {
    const F = WorkspaceCycleFixture;
    for ([_]anyerror{
        error.WorkspaceWindowOwnerUnknown, error.WorkspaceWindowLookupFailed, error.AmbiguousWorkspaceWindow,
    }) |failure| {
        F.reset();
        F.lookup_error = failure;
        try std.testing.expectError(failure, F.cycle(std.testing.allocator, F.default_path, 1));
        try std.testing.expectEqual(@as(usize, 0), F.restores + F.launches);
    }
    for ([_]bool{ false, true }) |has_identified| {
        F.reset();
        if (has_identified) F.open = &.{F.wide(F.rows[4].path)};
        F.unidentified_at = 1;
        try std.testing.expectError(error.UnidentifiedWorkspaceWindow, F.cycle(std.testing.allocator, F.default_path, 1));
        try std.testing.expectEqual(@as(usize, 0), F.restores + F.launches);
    }
    F.reset();
    F.key_error = error.InvalidWorkspaceIdentity;
    try std.testing.expectError(error.InvalidWorkspaceIdentity, F.cycle(std.testing.allocator, F.default_path, 1));
    try std.testing.expectEqual(@as(usize, 0), F.lookups + F.restores + F.launches);
    F.reset();
    F.list_error = error.AccessDenied;
    try std.testing.expectError(error.AccessDenied, F.cycle(std.testing.allocator, F.default_path, 1));
    try std.testing.expectEqual(@as(usize, 0), F.lookups + F.restores + F.launches);
}

test "workspace running cycle rechecks disappearance and identity before restore without cold fallback" {
    const F = WorkspaceCycleFixture;
    for (0..4) |scenario| {
        F.reset();
        F.known = &.{F.rows[0]};
        F.open = &.{F.wide(F.rows[0].path)};
        F.expected_restore = F.open[0];
        switch (scenario) {
            0 => F.close_at = 2,
            1 => F.unidentified_at = 2,
            2 => {
                F.lookup_error_at = 2;
                F.lookup_error = error.WorkspaceWindowOwnerUnknown;
            },
            3 => F.restore_error = error.WorkspaceWindowNotFound,
            else => unreachable,
        }
        const failure = switch (scenario) {
            1 => error.UnidentifiedWorkspaceWindow,
            2 => error.WorkspaceWindowOwnerUnknown,
            else => error.WorkspaceWindowNotFound,
        };
        try std.testing.expectError(failure, F.cycle(std.testing.allocator, F.default_path, 1));
        try std.testing.expectEqual(@as(usize, if (scenario == 3) 1 else 0), F.restores);
        try std.testing.expectEqual(@as(usize, 0), F.launches);
    }
    for ([_]anyerror{ error.WorkspaceRestoreFailed, error.WorkspaceActivationFailed }) |failure| {
        F.reset();
        F.open = &.{F.wide(F.rows[0].path)};
        F.expected_restore = F.open[0];
        F.restore_error = failure;
        try std.testing.expectError(failure, F.cycle(std.testing.allocator, F.default_path, 1));
        try std.testing.expectEqual(@as(usize, 0), F.launches);
    }
    try std.testing.expectEqualStrings("The next workspace is no longer open", workspaceCycleFailure(error.WorkspaceWindowNotFound));
    try std.testing.expectEqualStrings(workspace_restart_message, workspaceCycleFailure(error.WorkspaceIdentityChanged));
}

test "workspace running cycle owns refreshed paths and releases every failing allocation without an arena" {
    const F = WorkspaceCycleFixture;
    const Case = struct {
        fn run(allocator: std.mem.Allocator) !void {
            F.reset();
            var source = try WorkspaceLifecycle.managerList(allocator, &F.rows, F.home, F.default_path);
            F.release_source = &source;
            defer if (F.release_source != null) {
                source.deinit(allocator);
                F.release_source = null;
            };
            F.known = source.items;
            F.open = &.{F.wide(F.rows[0].path)};
            F.expected_restore = F.open[0];
            try std.testing.expectEqual(WorkspaceCycleResult.restored, try F.cycle(allocator, F.default_path, 1));
            try std.testing.expect(F.release_source == null);
            try std.testing.expectEqual(@as(usize, 1), F.restores);
            try std.testing.expectEqual(@as(usize, 0), F.launches);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "workspace running cycle production helper compiles with no launch capability" {
    try std.testing.expect(!@hasDecl(WorkspaceCycleApi, "launch"));
    const F = WorkspaceCycleFixture;
    const RestoreOnly = struct {
        const list = F.list;
        const instanceKey = F.instanceKey;
        const windows = F.windows;
        const restore = F.restore;
    };
    F.reset();
    F.open = &.{F.wide(F.rows[0].path)};
    F.expected_restore = F.open[0];
    try std.testing.expectEqual(WorkspaceCycleResult.restored, try cycleWorkspaceWith(
        RestoreOnly,
        std.testing.allocator,
        F.default_path,
        "c:/fixture/.graphcode",
        1,
    ));
    try std.testing.expectEqual(@as(usize, 1), F.restores);
}

test "workspace cycling wraps from the current identity and never invents a current target" {
    const items = [_]WorkspaceLifecycle.Workspace{
        .{ .name = "alpha", .path = "C:\\fixture\\.graphcode-alpha", .identity = "c:/fixture/.graphcode-alpha", .is_default = false },
        .{ .name = "beta", .path = "C:\\fixture\\.graphcode-beta", .identity = "c:/fixture/.graphcode-beta", .is_default = false },
    };
    try std.testing.expectEqual(@as(?usize, 1), workspaceCycleTarget(&items, items[0].identity, 1));
    try std.testing.expectEqual(@as(?usize, 1), workspaceCycleTarget(&items, items[0].identity, -1));
    try std.testing.expectEqual(@as(?usize, 0), workspaceCycleTarget(&items, items[1].identity, 1));
    try std.testing.expect(workspaceCycleTarget(&items, "c:/missing", 1) == null);
    try std.testing.expect(workspaceCycleTarget(items[0..1], items[0].identity, 1) == null);
    try std.testing.expectEqual(@as(?usize, 0), workspaceCycleTarget(&items, items[0].identity, std.math.minInt(isize)));
    try std.testing.expectEqual(@as(?usize, 1), workspaceCycleTarget(&items, items[0].identity, std.math.maxInt(isize)));
}

test "input routing bounds follow hidden workspace panel and rail" {
    const shown = inputBounds(1200, 900, .{});
    try std.testing.expectEqual(@as(i32, Tokens.sidebar_width), shown.rail_left);
    try std.testing.expectEqual(@as(i32, 900 - Tokens.workspace_height), shown.workspace_top);
    try std.testing.expectEqual(shown.rail_left, shown.canvas.left);
    try std.testing.expectEqual(WheelRegion.sidebar, wheelRegion(20, 300, shown, .{}));
    try std.testing.expectEqual(WheelRegion.none, wheelRegion(20, 850, shown, .{}));

    const hidden_controls = WorkspaceControls.State{
        .rail_visible = false,
        .panel_visible = false,
        .activity_enabled = false,
    };
    const hidden = inputBounds(1200, 900, hidden_controls);
    try std.testing.expectEqual(@as(i32, 0), hidden.rail_left);
    try std.testing.expectEqual(@as(i32, 900), hidden.workspace_top);
    try std.testing.expectEqual(hidden.rail_left, hidden.canvas.left);
    try std.testing.expect(hidden.canvas.bottom > shown.canvas.bottom);
    try std.testing.expectEqual(WheelRegion.canvas, wheelRegion(20, 300, hidden, hidden_controls));
    try std.testing.expectEqual(WheelRegion.canvas, wheelRegion(600, 850, hidden, hidden_controls));
}

test "sidebar UIA bounds clip hidden rows instead of sharing visible hit rectangles" {
    try std.testing.expectEqualDeep(
        c.RECT{ .left = 12, .top = Tokens.header_height, .right = 232, .bottom = Tokens.header_height + 8 },
        clipSidebarAccessibilityBounds(
            .{ .left = 12, .top = Tokens.header_height - 8, .right = 232, .bottom = Tokens.header_height + 8 },
            400,
        ),
    );
    try std.testing.expectEqualDeep(
        c.RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        clipSidebarAccessibilityBounds(.{ .left = 12, .top = 420, .right = 232, .bottom = 444 }, 400),
    );
}

test "attended activation routes visible sidebar loop from an open stopped workspace with Worktrees and activity" {
    var app = try overviewTestApp(Dpi.base_dpi);
    defer deinitOverviewTestApp(&app);
    const path = "C:\\activation-fixture";
    try loadActivationTestFixture(&app);
    try std.testing.expect(app.selectProject(path));
    try std.testing.expect(app.selectNodeIndex(0));
    app.surface = .workspace;
    app.workspace_controls = .{ .rail_visible = true, .panel_visible = true, .activity_enabled = true };
    try installNoticeTestInspection(&app, path, 2, 4096);
    app.sidebar_scroll = 11;
    try std.testing.expect(c.MoveWindow(
        app.window.hwnd,
        0,
        0,
        physicalCoordinate(1200, app.dpi),
        physicalCoordinate(500, app.dpi),
        0,
    ) != 0);

    var rows = try Sidebar.appendRows(
        app.allocator,
        &app.model,
        app.currentWorktreeInspection(),
        app.sidebar_scroll,
        &app.sidebar_state,
    );
    defer rows.deinit(app.allocator);
    const target_row = for (rows.items) |row| {
        if (row.kind != .loop or row.project_path == null or !std.mem.eql(u8, row.project_path.?, path)) continue;
        const graph = app.model.graphFor(path) orelse return error.TestExpectedGraph;
        if (row.index < graph.nodes.items.len and std.mem.eql(u8, graph.nodes.items[row.index].id, "target-loop"))
            break row;
    } else return error.TestExpectedLoopRow;
    try std.testing.expect(target_row.top >= Tokens.header_height);
    const client = logicalClientRect(app.window.hwnd, app.dpi);
    const routing = inputBounds(client.right, client.bottom, app.workspace_controls);
    const sidebar_bottom = GraphCanvas.sidebarBottom(client.bottom, app.workspace_controls, app.surface);
    try std.testing.expect(target_row.top + 8 >= routing.canvas.bottom);
    try std.testing.expect(target_row.top + 8 < sidebar_bottom);
    const row_hit = Sidebar.rowAt(
        80,
        target_row.top + 8,
        &app.model,
        app.currentWorktreeInspection(),
        app.sidebar_scroll,
        sidebar_bottom,
        &app.sidebar_state,
    ) orelse return error.TestExpectedLoopRow;
    try std.testing.expectEqual(Sidebar.RowKind.loop, row_hit.kind);
    try std.testing.expect(Sidebar.attentionRowAt(
        target_row.top + 8,
        &app.model,
        app.currentWorktreeInspection(),
        &app.sidebar_state,
        app.sidebar_scroll,
    ) == null);
    try std.testing.expect(Sidebar.activityControlAt(
        80,
        target_row.top + 8,
        &app.model,
        app.currentWorktreeInspection(),
        &app.sidebar_state,
        app.sidebar_scroll,
    ) == null);
    try std.testing.expect(Sidebar.activityCardAt(
        80,
        target_row.top + 8,
        &app.model,
        app.currentWorktreeInspection(),
        &app.sidebar_state,
        app.sidebar_scroll,
    ) == null);

    var result: c.LRESULT = 0;
    const click_x: u32 = 80;
    const click_y: u32 = @intCast(target_row.top + 8);
    const lparam: c.LPARAM = @intCast(click_x | (click_y << 16));
    try std.testing.expect(onWindowMessage(&app, app.window.hwnd, c.WM_LBUTTONDOWN, 0, lparam, &result));

    try std.testing.expectEqualStrings(path, app.model.selected_project_path.?);
    try std.testing.expectEqualStrings("target-loop", app.model.selected().?.id);
    try std.testing.expectEqualStrings("target-loop", app.selected_node_id);
    try std.testing.expectEqual(@as(usize, 1), app.client.outbound_count);
    try std.testing.expect(std.mem.indexOf(u8, app.client.outbound[app.client.outbound_head], "\"resumeSession\":{\"_0\":\"target-loop\"}") != null);
    try std.testing.expectEqualStrings("stopped", app.model.graphFor(path).?.nodes.items[0].state);
    try std.testing.expectEqualStrings("stopped", app.model.graphFor(path).?.nodes.items[2].state);
}

test "attended activation routes canvas card click and command through one exact-node resume" {
    const path = "C:\\activation-fixture";
    var pointer_app = try overviewTestApp(Dpi.base_dpi);
    defer deinitOverviewTestApp(&pointer_app);
    try loadActivationTestFixture(&pointer_app);
    try std.testing.expect(pointer_app.selectProject(path));
    try std.testing.expect(pointer_app.selectNodeIndex(0));
    pointer_app.surface = .project;
    pointer_app.workspace_controls = .{ .rail_visible = true, .panel_visible = true, .activity_enabled = true };
    const card = GraphCanvas.nodeBounds(1, &pointer_app.canvas);
    const x: u32 = @intCast(card.left + 20);
    const y: u32 = @intCast(card.top + 20);
    const lparam: c.LPARAM = @intCast(x | (y << 16));
    var result: c.LRESULT = 0;
    try std.testing.expect(onWindowMessage(&pointer_app, pointer_app.window.hwnd, c.WM_LBUTTONDOWN, 0, lparam, &result));
    try std.testing.expectEqualStrings("target-loop", pointer_app.model.selected().?.id);
    try std.testing.expectEqual(@as(usize, 0), pointer_app.client.outbound_count);
    _ = try pointer_app.model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":3,"event":{"graphChanged":{"project":{"path":"C:\\activation-fixture","name":"Activation fixture"},"nodes":[{"id":"target-loop","title":"Visible idle loop","loopType":"sketch","state":{"idle":{}}},{"id":"stopped-loop","title":"Stopped loop","loopType":"turnBased","state":{"stopped":{}}},{"id":"other-loop","title":"Unrelated loop","loopType":"turnBased","state":{"stopped":{}}}],"edges":[]}}}
    );
    try std.testing.expect(onWindowMessage(&pointer_app, pointer_app.window.hwnd, c.WM_LBUTTONUP, 0, lparam, &result));
    try expectSingleActivation(&pointer_app, path, "target-loop");

    var command_app = try overviewTestApp(Dpi.base_dpi);
    defer deinitOverviewTestApp(&command_app);
    try loadActivationTestFixture(&command_app);
    try std.testing.expect(command_app.selectProject(path));
    try std.testing.expect(command_app.selectNodeIndex(1));
    command_app.handleAction(.open_node);
    try expectSingleActivation(&command_app, path, "target-loop");
}

test "attended activation routes UIA loop invoke by owned node identity exactly once" {
    const path = "C:\\activation-fixture";
    var app = try overviewTestApp(Dpi.base_dpi);
    defer deinitOverviewTestApp(&app);
    try loadActivationTestFixture(&app);
    try std.testing.expect(app.selectProject(path));
    try std.testing.expect(app.selectNodeIndex(0));
    const identity = "loop:C:\\activation-fixture:target-loop";
    try std.testing.expect(app.applyUiaDynamicInvoke(Accessibility.worktreeIdentityPayload(identity)));
    try expectSingleActivation(&app, path, "target-loop");
}

const ReopenProbe = struct {
    var drawn_tabs: usize = 0;
    var uia_tabs: usize = 0;
    var sink: @This() = .{};

    fn publish(app: *App) void {
        drawn_tabs = if (app.workspace) |workspace| workspace.tabCount() else 0;
        uia_tabs = 0;
        app.syncAccessibilityTo(&sink, .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 });
    }
    fn syncCanvasBounds(_: *@This(), _: c.RECT) void {}
    fn syncElements(_: *@This(), _: []const u8, elements: []const Accessibility.DynamicElement, _: WorktreeStatus.Policy, _: Accessibility.WorktreeCapabilities) void {
        uia_tabs = 0;
        for (elements) |element| {
            if (std.mem.startsWith(u8, element.identity, "workspace-tab:")) uia_tabs += 1;
        }
    }
};

const reopen_fixture_path = "C:\\reopen-fixture";

fn reopenFixtureFrame(app: *App, sequence: usize, a_state: []const u8, b_state: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        app.allocator,
        "{{\"version\":2,\"kind\":\"event\",\"sequence\":{d},\"event\":{{\"graphChanged\":{{\"project\":{{\"path\":\"C:\\\\reopen-fixture\",\"name\":\"Reopen fixture\"}},\"nodes\":[{{\"id\":\"loop-a\",\"title\":\"Loop A\",\"loopType\":\"turnBased\",\"state\":{{\"{s}\":{{}}}}}},{{\"id\":\"loop-b\",\"title\":\"Loop B\",\"loopType\":\"turnBased\",\"state\":{{\"{s}\":{{}}}}}}],\"edges\":[]}}}}}}",
        .{ sequence, a_state, b_state },
    );
}

/// Delivers a daemon graph change through the production frame path, including the
/// workspace refresh that runs after every graph change.
fn deliverReopenFrame(app: *App, sequence: usize, a_state: []const u8, b_state: []const u8) !void {
    const frame = try reopenFixtureFrame(app, sequence, a_state, b_state);
    defer app.allocator.free(frame);
    app.onFrameWithAccessibilityPublish(frame, ReopenProbe.publish);
}

/// A native left click (down and up) on a loop's visible sidebar row, through the same
/// hit test the window procedure uses.
fn clickSidebarLoopRow(app: *App, path: []const u8, node_id: []const u8) !void {
    var rows = try Sidebar.appendRows(
        app.allocator,
        &app.model,
        app.currentWorktreeInspection(),
        app.sidebar_scroll,
        &app.sidebar_state,
    );
    defer rows.deinit(app.allocator);
    const graph = app.model.graphFor(path) orelse return error.TestExpectedGraph;
    const row = for (rows.items) |row| {
        if (row.kind != .loop or row.project_path == null or !std.mem.eql(u8, row.project_path.?, path)) continue;
        if (row.index < graph.nodes.items.len and std.mem.eql(u8, graph.nodes.items[row.index].id, node_id))
            break row;
    } else return error.TestExpectedLoopRow;
    const client = logicalClientRect(app.window.hwnd, app.dpi);
    const sidebar_bottom = GraphCanvas.sidebarBottom(client.bottom, app.workspace_controls, app.surface);
    try std.testing.expect(row.top + 8 >= Tokens.header_height);
    try std.testing.expect(row.top + 8 < sidebar_bottom);
    const hit = Sidebar.rowAt(
        80,
        row.top + 8,
        &app.model,
        app.currentWorktreeInspection(),
        app.sidebar_scroll,
        sidebar_bottom,
        &app.sidebar_state,
    ) orelse return error.TestExpectedLoopRow;
    try std.testing.expectEqual(Sidebar.RowKind.loop, hit.kind);
    try std.testing.expectEqual(row.index, hit.index);
    var result: c.LRESULT = 0;
    const x: u32 = 80;
    const y: u32 = @intCast(row.top + 8);
    const lparam: c.LPARAM = @intCast(x | (y << 16));
    try std.testing.expect(onWindowMessage(app, app.window.hwnd, c.WM_LBUTTONDOWN, 0, lparam, &result));
    _ = onWindowMessage(app, app.window.hwnd, c.WM_LBUTTONUP, 0, lparam, &result);
}

fn expectOneResumePerClick(app: *App, before: usize, node_id: []const u8) !void {
    try std.testing.expectEqual(before + 1, app.client.outbound_count);
    const newest = app.client.outbound[(app.client.outbound_head + app.client.outbound_count - 1) % app.client.outbound.len];
    const expected = try std.fmt.allocPrint(app.allocator, "\"resumeSession\":{{\"_0\":\"{s}\"}}", .{node_id});
    defer app.allocator.free(expected);
    try std.testing.expect(std.mem.indexOf(u8, newest, expected) != null);
}

/// The open loop owns the workspace: one tab whose pane is `node_id`, the loop slot bound
/// (or binding) to it, no other slot binding any loop, and UIA exposing the drawn tabs.
fn expectWorkspaceBoundTo(workspace: *TerminalWorkspace.Workspace, node_id: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), workspace.tabCount());
    const tab = workspace.layout.selectedConst() orelse return error.TestExpectedTab;
    try std.testing.expectEqual(@as(usize, 1), tab.panes.items.len);
    try std.testing.expectEqualStrings(node_id, tab.panes.items[tab.focused_pane].id);
    try std.testing.expect(tab.panes.items[tab.focused_pane].launches_agent);
    try std.testing.expect(workspace.isAwaitingLaunch(0));
    try std.testing.expectEqualStrings(node_id, workspace.launch_waits[0].session);
    for (1..workspace.surfaces.len) |index| {
        try std.testing.expect(!workspace.isAwaitingLaunch(index));
        try std.testing.expect(!workspace.hasSurface(index));
        try std.testing.expect(!workspace.hasAttach(index));
    }
    try std.testing.expectEqual(ReopenProbe.drawn_tabs, ReopenProbe.uia_tabs);
    try std.testing.expectEqual(workspace.tabCount(), ReopenProbe.uia_tabs);
}

fn reopenTestWorkspace(allocator: std.mem.Allocator, layout_path: []const u8) !TerminalWorkspace.Workspace {
    const project_path = try allocator.dupe(u8, reopen_fixture_path);
    errdefer allocator.free(project_path);
    const project_key = try allocator.dupe(u8, reopen_fixture_path);
    errdefer allocator.free(project_key);
    const owned_layout_path = try allocator.dupe(u8, layout_path);
    errdefer allocator.free(owned_layout_path);
    // No winghostty host or zmx: attaches are never reached, so every launch wait stays
    // observable. The layout, launch-wait, activation, and refresh logic are production code.
    return .{
        .parent = null,
        .allocator = allocator,
        .zmx_path = &.{},
        .cwd = &.{},
        .input_queue = .{ .allocator = allocator },
        .layout = try @import("WorkspaceLayout.zig").Layout.init(allocator, reopen_fixture_path),
        .layout_path = owned_layout_path,
        .project_key = project_key,
        .project_path = project_path,
    };
}

test "attended activation reopening a stopped loop binds its own pane without another loop's stray tab" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(directory);
    const layout_path = try std.fs.path.join(allocator, &.{ directory, "layout.json" });
    defer allocator.free(layout_path);
    var workspace = try reopenTestWorkspace(allocator, layout_path);
    defer workspace.deinit();

    var app = try overviewTestApp(Dpi.base_dpi);
    defer deinitOverviewTestApp(&app);
    defer app.workspace = null;
    _ = try app.model.updateFromFrame(reopen_fixture_initial_frame);
    try std.testing.expect(app.selectProject(reopen_fixture_path));
    try std.testing.expect(app.selectNodeIndex(0));
    app.workspace_controls = .{ .rail_visible = true, .panel_visible = true, .activity_enabled = false };
    app.workspace = &workspace;
    try std.testing.expect(c.MoveWindow(app.window.hwnd, 0, 0, physicalCoordinate(1200, app.dpi), physicalCoordinate(700, app.dpi), 0) != 0);
    var sequence: usize = 2;

    // 1. Open A from its sidebar row; the daemon starts it, then A is stopped.
    var before = app.client.outbound_count;
    try clickSidebarLoopRow(&app, reopen_fixture_path, "loop-a");
    try expectOneResumePerClick(&app, before, "loop-a");
    try deliverReopenFrame(&app, sequence, "running", "idle");
    sequence += 1;
    try expectWorkspaceBoundTo(&workspace, "loop-a");
    try deliverReopenFrame(&app, sequence, "stopped", "idle");
    sequence += 1;
    try expectWorkspaceBoundTo(&workspace, "loop-a");
    try std.testing.expectEqual(GraphCanvas.Surface.workspace, app.surface);

    // 2. Sidebar row B with stopped A's workspace open.
    before = app.client.outbound_count;
    try clickSidebarLoopRow(&app, reopen_fixture_path, "loop-b");
    try expectOneResumePerClick(&app, before, "loop-b");
    try deliverReopenFrame(&app, sequence, "stopped", "running");
    sequence += 1;
    try expectWorkspaceBoundTo(&workspace, "loop-b");
    try std.testing.expectEqualStrings("loop-b", app.selected_node_id);

    // 3. Sidebar row A again. Graph changes keep arriving while B runs; none may bind B
    // back into the workspace beside the reopened loop.
    before = app.client.outbound_count;
    try clickSidebarLoopRow(&app, reopen_fixture_path, "loop-a");
    try expectOneResumePerClick(&app, before, "loop-a");
    try std.testing.expectEqualStrings("loop-a", app.selected_node_id);
    try std.testing.expectEqualStrings("loop-a", app.model.selected().?.id);
    for (0..3) |_| {
        try deliverReopenFrame(&app, sequence, "stopped", "running");
        sequence += 1;
        try expectWorkspaceBoundTo(&workspace, "loop-a");
    }
    try std.testing.expectEqual(before + 1, app.client.outbound_count);
}

const reopen_fixture_initial_frame =
    \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"C:\\reopen-fixture","name":"Reopen fixture"},"nodes":[{"id":"loop-a","title":"Loop A","loopType":"turnBased","state":{"idle":{}}},{"id":"loop-b","title":"Loop B","loopType":"turnBased","state":{"idle":{}}}],"edges":[]}}}
;

test "graph refresh re-observes only the open loop's detached pane in the loop slot" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(directory);
    const layout_path = try std.fs.path.join(allocator, &.{ directory, "layout.json" });
    defer allocator.free(layout_path);
    var workspace = try reopenTestWorkspace(allocator, layout_path);
    defer workspace.deinit();
    try workspace.layout.addTab("loop-a", true);

    var app = try overviewTestApp(Dpi.base_dpi);
    defer deinitOverviewTestApp(&app);
    defer app.workspace = null;
    _ = try app.model.updateFromFrame(reopen_fixture_initial_frame);
    try std.testing.expect(app.selectProject(reopen_fixture_path));
    app.workspace = &workspace;

    // Selecting a loop the workspace does not own never binds it.
    try std.testing.expect(app.selectNodeIndex(1));
    try deliverReopenFrame(&app, 2, "running", "running");
    for (0..workspace.surfaces.len) |index| try std.testing.expect(!workspace.isAwaitingLaunch(index));

    // The open loop's own detached pane is re-observed passively, in the loop slot only.
    try std.testing.expect(app.selectNodeIndex(0));
    try deliverReopenFrame(&app, 3, "running", "running");
    try std.testing.expect(workspace.isAwaitingLaunch(0));
    try std.testing.expectEqualStrings("loop-a", workspace.launch_waits[0].session);
    try std.testing.expect(!workspace.launch_waits[0].reports_timeout);
    for (1..workspace.surfaces.len) |index| try std.testing.expect(!workspace.isAwaitingLaunch(index));
    try std.testing.expectEqual(@as(usize, 1), workspace.tabCount());
}

/// Reads the loop workspace's UIA surface the way the Dev Box harness does: the
/// `workspace-loop-bar` identity names the loop the bar shows, and the published
/// `workspace-show-graph` bounds are where a native click on the button lands.
const LoopBarProbe = struct {
    var bar_loop: [64]u8 = undefined;
    var bar_loop_len: usize = 0;
    var has_bar = false;
    var show_graph: ?c.RECT = null;
    var sink: @This() = .{};

    fn publish(app: *App) void {
        has_bar = false;
        bar_loop_len = 0;
        show_graph = null;
        app.syncAccessibilityTo(&sink, logicalClientRect(app.window.hwnd, app.dpi));
    }
    fn barLoop() []const u8 {
        return bar_loop[0..bar_loop_len];
    }
    fn syncCanvasBounds(_: *@This(), _: c.RECT) void {}
    fn syncElements(_: *@This(), _: []const u8, elements: []const Accessibility.DynamicElement, _: WorktreeStatus.Policy, _: Accessibility.WorktreeCapabilities) void {
        const bar_prefix = "workspace-loop-bar:";
        for (elements) |element| {
            if (std.mem.startsWith(u8, element.identity, bar_prefix)) {
                const id = element.identity[bar_prefix.len..];
                bar_loop_len = @min(id.len, bar_loop.len);
                @memcpy(bar_loop[0..bar_loop_len], id[0..bar_loop_len]);
                has_bar = true;
            } else if (std.mem.eql(u8, element.identity, "workspace-show-graph:show-graph")) {
                show_graph = .{ .left = element.left, .top = element.top, .right = element.right, .bottom = element.bottom };
            }
        }
    }
};

fn showGraphFixtureFrame(app: *App, sequence: usize, a_state: []const u8, a_presence: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        app.allocator,
        "{{\"version\":2,\"kind\":\"event\",\"sequence\":{d},\"event\":{{\"graphChanged\":{{\"project\":{{\"path\":\"C:\\\\reopen-fixture\",\"name\":\"Reopen fixture\"}},\"nodes\":[" ++
            "{{\"id\":\"loop-a\",\"title\":\"Loop A\",\"loopType\":\"turnBased\",\"state\":{{\"{s}\":{{}}}},\"presence\":{{\"presence\":\"{s}\",\"confidence\":\"reported\"}}}}," ++
            "{{\"id\":\"loop-b\",\"title\":\"Loop B\",\"loopType\":\"turnBased\",\"state\":{{\"idle\":{{}}}}}}," ++
            "{{\"id\":\"loop-c\",\"title\":\"Loop C\",\"loopType\":\"turnBased\",\"state\":{{\"idle\":{{}}}}}}" ++
            "],\"edges\":[]}}}}}}",
        .{ sequence, a_state, a_presence },
    );
}

fn deliverShowGraphFrame(app: *App, sequence: usize, a_state: []const u8, a_presence: []const u8) !void {
    const frame = try showGraphFixtureFrame(app, sequence, a_state, a_presence);
    defer app.allocator.free(frame);
    app.onFrameWithAccessibilityPublish(frame, LoopBarProbe.publish);
}

fn nativeClick(app: *App, x: i32, y: i32) !void {
    var result: c.LRESULT = 0;
    const lparam: c.LPARAM = @intCast(@as(u32, @intCast(x)) | (@as(u32, @intCast(y)) << 16));
    try std.testing.expect(onWindowMessage(app, app.window.hwnd, c.WM_LBUTTONDOWN, 0, lparam, &result));
    _ = onWindowMessage(app, app.window.hwnd, c.WM_LBUTTONUP, 0, lparam, &result);
}

/// A short native drag on a canvas card: it moves the card and leaves it graph-selected
/// without opening it.
fn dragCanvasCard(app: *App, index: usize) !void {
    const card = GraphCanvas.nodeBounds(index, &app.canvas);
    var result: c.LRESULT = 0;
    const start_x: u32 = @intCast(card.left + 20);
    const start_y: u32 = @intCast(card.top + 20);
    const end_x: u32 = start_x + 40;
    const end_y: u32 = start_y + 30;
    try std.testing.expect(onWindowMessage(app, app.window.hwnd, c.WM_LBUTTONDOWN, 0, @intCast(start_x | (start_y << 16)), &result));
    try std.testing.expect(app.canvas.node_dragging);
    _ = onWindowMessage(app, app.window.hwnd, c.WM_MOUSEMOVE, c.MK_LBUTTON, @intCast(end_x | (end_y << 16)), &result);
    try std.testing.expect(app.canvas.node_drag_started);
    _ = onWindowMessage(app, app.window.hwnd, c.WM_LBUTTONUP, 0, @intCast(end_x | (end_y << 16)), &result);
}

/// The loop bar (UIA identity and the selection its title is drawn from) and the visible
/// pane both name `node_id`.
fn expectLoopBarAndPane(app: *App, workspace: *TerminalWorkspace.Workspace, node_id: []const u8) !void {
    try std.testing.expectEqual(GraphCanvas.Surface.workspace, app.surface);
    LoopBarProbe.publish(app);
    try std.testing.expect(LoopBarProbe.has_bar);
    try std.testing.expectEqualStrings(node_id, LoopBarProbe.barLoop());
    const graph = workspaceGraph(&app.model) orelse return error.TestExpectedGraph;
    const index = app.model.selectedIndex() orelse return error.TestExpectedSelection;
    try std.testing.expectEqualStrings(node_id, graph.nodes.items[index].id);
    try std.testing.expectEqualStrings(node_id, app.selected_node_id);
    try expectPaneBoundTo(workspace, node_id);
}

fn expectPaneBoundTo(workspace: *TerminalWorkspace.Workspace, node_id: []const u8) !void {
    const tab = workspace.layout.selectedConst() orelse return error.TestExpectedTab;
    try std.testing.expectEqualStrings(node_id, tab.panes.items[tab.focused_pane].id);
    try std.testing.expect(workspace.isAwaitingLaunch(0));
    try std.testing.expectEqualStrings(node_id, workspace.launch_waits[0].session);
}

fn needsYouRowY(app: *App) !i32 {
    var y: i32 = Tokens.header_height;
    while (y < 700) : (y += 1) {
        const index = Sidebar.attentionRowAt(y, &app.model, app.currentWorktreeInspection(), &app.sidebar_state, app.sidebar_scroll) orelse continue;
        if (index != 0) continue;
        if (Sidebar.needsYouStopAt(80, y, &app.model, app.currentWorktreeInspection(), &app.sidebar_state, app.sidebar_scroll) != null) continue;
        return y + 4;
    }
    return error.TestExpectedNeedsYouRow;
}

fn needsYouStopPoint(app: *App) !c.POINT {
    var y: i32 = Tokens.header_height;
    while (y < 700) : (y += 1) {
        var x: i32 = 0;
        while (x < Tokens.sidebar_width) : (x += 2) {
            const index = Sidebar.needsYouStopAt(x, y, &app.model, app.currentWorktreeInspection(), &app.sidebar_state, app.sidebar_scroll) orelse continue;
            if (index == 0) return .{ .x = x + 2, .y = y + 2 };
        }
    }
    return error.TestExpectedNeedsYouStop;
}

const ShowGraphFixture = struct {
    workspace: TerminalWorkspace.Workspace,
    app: App,
    directory: []u8,
    layout_path: []u8,
    tmp: std.testing.TmpDir,
    sequence: usize = 2,

    /// Core project with loops A, B, C; A stopped after spending a turn, so it is the
    /// one "Needs you" entry, and a short canvas drag left A graph-selected.
    fn init(self: *ShowGraphFixture) !void {
        const allocator = std.testing.allocator;
        self.sequence = 2;
        self.tmp = std.testing.tmpDir(.{});
        self.directory = try self.tmp.dir.realpathAlloc(allocator, ".");
        self.layout_path = try std.fs.path.join(allocator, &.{ self.directory, "layout.json" });
        self.workspace = try reopenTestWorkspace(allocator, self.layout_path);
        self.app = try overviewTestApp(Dpi.base_dpi);
        const app = &self.app;
        const initial = try showGraphFixtureFrame(app, 1, "idle", "idle");
        defer allocator.free(initial);
        _ = try app.model.updateFromFrame(initial);
        try std.testing.expect(app.selectProject(reopen_fixture_path));
        try std.testing.expect(app.selectNodeIndex(1));
        app.surface = .project;
        app.workspace_controls = .{ .rail_visible = true, .panel_visible = false, .activity_enabled = false };
        app.workspace = &self.workspace;
        try std.testing.expect(c.MoveWindow(app.window.hwnd, 0, 0, physicalCoordinate(1200, app.dpi), physicalCoordinate(700, app.dpi), 0) != 0);

        try deliverShowGraphFrame(app, self.sequence, "stopped", "awaitingInput");
        self.sequence += 1;
        try std.testing.expectEqual(@as(usize, 1), app.model.attentionCount());
        try std.testing.expectEqualStrings("loop-a", app.model.attention_entries.items[0].node.id);

        const before = app.client.outbound_count;
        try dragCanvasCard(app, 0);
        try std.testing.expectEqual(GraphCanvas.Surface.project, app.surface);
        try std.testing.expectEqualStrings("loop-a", app.model.selected().?.id);
        try std.testing.expectEqual(before, app.client.outbound_count);
    }

    fn deinit(self: *ShowGraphFixture) void {
        self.app.workspace = null;
        deinitOverviewTestApp(&self.app);
        self.workspace.deinit();
        std.testing.allocator.free(self.layout_path);
        std.testing.allocator.free(self.directory);
        self.tmp.cleanup();
    }

    fn openFromSidebar(self: *ShowGraphFixture, node_id: []const u8) !void {
        const before = self.app.client.outbound_count;
        try clickSidebarLoopRow(&self.app, reopen_fixture_path, node_id);
        try expectOneResumePerClick(&self.app, before, node_id);
        try expectLoopBarAndPane(&self.app, &self.workspace, node_id);
    }
};

test "Show in Graph from an open loop shows the graph and never moves the loop bar to the Needs-you loop" {
    var fixture: ShowGraphFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const app = &fixture.app;

    for ([_][]const u8{ "loop-b", "loop-c" }) |node_id| {
        try fixture.openFromSidebar(node_id);
        try std.testing.expect(app.workspace_controls.panel_visible);
        const button = LoopBarProbe.show_graph orelse return error.TestExpectedShowGraphButton;
        // The Dev Box geometry: the button sits inside the graph's hidden Needs-you rail.
        try std.testing.expect(GraphCanvas.hitTestAttentionRail(
            @divTrunc(button.left + button.right, 2),
            @divTrunc(button.top + button.bottom, 2),
            logicalClientRect(app.window.hwnd, app.dpi).right,
        ));
        const before = app.client.outbound_count;
        try nativeClick(app, @divTrunc(button.left + button.right, 2), @divTrunc(button.top + button.bottom, 2));

        // Whatever surface the click leaves, the bar must never name another loop.
        if (app.surface == .workspace) try expectLoopBarAndPane(app, &fixture.workspace, node_id);
        try std.testing.expectEqual(GraphCanvas.Surface.project, app.surface);
        try std.testing.expect(!app.workspace_controls.panel_visible);
        try std.testing.expectEqualStrings(node_id, app.model.selected().?.id);
        try std.testing.expectEqualStrings(node_id, app.selected_node_id);
        try std.testing.expectEqual(before, app.client.outbound_count);
        try expectPaneBoundTo(&fixture.workspace, node_id);
        LoopBarProbe.publish(app);
        try std.testing.expect(!LoopBarProbe.has_bar);
    }
}

test "selection routes with a loop workspace open: Ctrl+Tab review moves the loop bar and pane together" {
    var fixture: ShowGraphFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.openFromSidebar("loop-b");
    fixture.app.handleWorkspaceKeyRoute(App.dispatchWorkspaceKey(c.VK_TAB, true, false, true));
    try expectLoopBarAndPane(&fixture.app, &fixture.workspace, "loop-a");
}

test "selection routes with a loop workspace open: Review What Needs You menu moves the loop bar and pane together" {
    var fixture: ShowGraphFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const app = &fixture.app;
    try fixture.openFromSidebar("loop-b");
    var result: c.LRESULT = 0;
    try std.testing.expect(onWindowMessage(app, app.window.hwnd, c.WM_COMMAND, @intFromEnum(MainWindow.Command.review_attention), 0, &result));
    try expectLoopBarAndPane(app, &fixture.workspace, "loop-a");
}

test "selection routes with a loop workspace open: Needs-you row click moves the loop bar and pane together" {
    var fixture: ShowGraphFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const app = &fixture.app;
    try fixture.openFromSidebar("loop-b");
    try nativeClick(app, 80, try needsYouRowY(app));
    try expectLoopBarAndPane(app, &fixture.workspace, "loop-a");
}

test "selection routes with a loop workspace open: Needs-you row UIA invoke moves the loop bar and pane together" {
    var fixture: ShowGraphFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const app = &fixture.app;
    try fixture.openFromSidebar("loop-b");
    try std.testing.expect(app.applyUiaDynamicInvoke(Accessibility.worktreeIdentityPayload("needs-you-row:C:\\reopen-fixture:loop-a")));
    try expectLoopBarAndPane(app, &fixture.workspace, "loop-a");
}

test "selection routes with a loop workspace open: Next and Previous Loop move the loop bar and pane together" {
    var fixture: ShowGraphFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const app = &fixture.app;
    try fixture.openFromSidebar("loop-b");
    var result: c.LRESULT = 0;
    try std.testing.expect(onWindowMessage(app, app.window.hwnd, c.WM_COMMAND, @intFromEnum(MainWindow.Command.next_loop), 0, &result));
    try expectLoopBarAndPane(app, &fixture.workspace, "loop-c");
    try std.testing.expect(onWindowMessage(app, app.window.hwnd, c.WM_COMMAND, @intFromEnum(MainWindow.Command.previous_loop), 0, &result));
    try expectLoopBarAndPane(app, &fixture.workspace, "loop-b");
}

test "selection routes with a loop workspace open: Needs-you Stop leaves the open loop's bar and pane alone" {
    var fixture: ShowGraphFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const app = &fixture.app;
    try fixture.openFromSidebar("loop-b");
    const stop = try needsYouStopPoint(app);
    const before = app.client.outbound_count;
    try nativeClick(app, stop.x, stop.y);
    try std.testing.expectEqual(before + 1, app.client.outbound_count);
    const newest = app.client.outbound[(app.client.outbound_head + app.client.outbound_count - 1) % app.client.outbound.len];
    try std.testing.expect(std.mem.indexOf(u8, newest, "stopNode") != null);
    try std.testing.expect(std.mem.indexOf(u8, newest, "loop-a") != null);
    try expectLoopBarAndPane(app, &fixture.workspace, "loop-b");
}

test "gesture routing requires a graph-capable surface, not only the canvas rectangle" {
    // This is the exact helper the real WM_GESTURE handler calls -- proving
    // routing here is proving the production path, not a parallel reimplementation.
    const hidden_controls = WorkspaceControls.State{
        .rail_visible = false,
        .panel_visible = false,
        .activity_enabled = false,
    };
    const bounds = inputBounds(1200, 900, hidden_controls);
    const point_over_canvas_rect = c.POINT{ .x = 600, .y = 500 };

    // The terminal workspace surface reuses the exact same window chrome and
    // canvas-shaped rectangle, but does not render the graph canvas at all --
    // a pinch landing there must never be treated as a canvas gesture, even
    // though the rectangle test alone would say "canvas".
    try std.testing.expect(!gestureInCanvas(.workspace, point_over_canvas_rect, bounds, hidden_controls));

    // Every graph-capable surface (project/overview/quick_chats) is routed
    // when the point is genuinely over the canvas rectangle.
    try std.testing.expect(gestureInCanvas(.project, point_over_canvas_rect, bounds, hidden_controls));
    try std.testing.expect(gestureInCanvas(.overview, point_over_canvas_rect, bounds, hidden_controls));
    try std.testing.expect(gestureInCanvas(.quick_chats, point_over_canvas_rect, bounds, hidden_controls));

    // A graph-capable surface with a point outside the canvas rectangle (or
    // an unmapped/failed ScreenToClient) is still not routed to the canvas.
    try std.testing.expect(!gestureInCanvas(.project, null, bounds, hidden_controls));
    try std.testing.expect(!gestureInCanvas(.project, c.POINT{ .x = -50, .y = -50 }, bounds, hidden_controls));

    // A destination switch mid-gesture (surface flips from a graph surface to
    // the terminal workspace at the exact same screen point) flips routing
    // from in-canvas to not-in-canvas -- this is what lets the real handler's
    // forward_out_of_region branch reset any in-progress pinch instead of
    // continuing to scale a canvas that is no longer on screen.
    try std.testing.expect(gestureInCanvas(.overview, point_over_canvas_rect, bounds, hidden_controls));
    try std.testing.expect(!gestureInCanvas(.workspace, point_over_canvas_rect, bounds, hidden_controls));
}

test "native gesture context changes identity across project switches on the same surface" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .client = undefined,
        .daemon = undefined,
        .model = GraphModel.Model.init(allocator),
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
    };
    defer app.model.deinit();
    defer app.sidebar_state.deinit();
    defer app.declared_entry_ids.deinit();
    defer app.kept_worktree_paths.deinit();

    _ = try app.model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"a","project":{"path":"A","name":"Alpha"},"nodes":[],"edges":[]}}}
    );
    _ = try app.model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"id":"b","project":{"path":"B","name":"Beta"},"nodes":[],"edges":[]}}}
    );

    _ = app.model.selectProject("A");
    app.surface = .overview;
    const context_project_a = app.pinchGestureContext();

    _ = app.model.selectProject("B");
    const context_project_b = app.pinchGestureContext();

    // Same graph-capable surface, different project: WM_GESTURE uses this
    // identity for both pinch and pan, so a gesture begun on project A cannot
    // continue affecting project B after a mid-gesture switch.
    try std.testing.expect(context_project_a != context_project_b);

    // A surface switch away from the graph canvas (still on project B) is
    // also a distinct identity, covering the terminal-workspace case.
    app.surface = .workspace;
    const context_workspace = app.pinchGestureContext();
    try std.testing.expect(context_workspace != context_project_b);

    // Recomputing with no state change at all is stable (same inputs, same
    // hash), since App.zig recomputes this fresh on every WM_GESTURE message
    // rather than caching it.
    app.surface = .overview;
    try std.testing.expectEqual(context_project_b, app.pinchGestureContext());
}

test "main shell coordinates round trip across common Windows DPI steps" {
    for ([_]u32{ 96, 120, 144, 192 }) |dpi| {
        try std.testing.expectEqual(@as(i32, 220), logicalCoordinate(physicalCoordinate(220, dpi), dpi));
        try std.testing.expectEqual(@as(i32, 34), logicalCoordinate(physicalCoordinate(34, dpi), dpi));
    }
}

test "DPI header layout and pointer targets use the logical width of a hidden native client" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .client = undefined,
        .daemon = undefined,
        .model = GraphModel.Model.init(std.testing.allocator),
        .sidebar_state = undefined,
        .declared_entry_ids = undefined,
        .kept_worktree_paths = undefined,
    };
    defer app.model.deinit();
    for ([_]struct { dpi: u32, width: i32, height: i32, logical_right: i32, jump: [4]i32 }{
        .{ .dpi = 96, .width = 1200, .height = 900, .logical_right = 1200, .jump = .{ 288, 5, 452, 29 } },
        .{ .dpi = 144, .width = 1800, .height = 1350, .logical_right = 1200, .jump = .{ 432, 8, 678, 44 } },
        .{ .dpi = 192, .width = 2400, .height = 1800, .logical_right = 1200, .jump = .{ 576, 10, 904, 58 } },
        .{ .dpi = 96, .width = 640, .height = 900, .logical_right = 640, .jump = .{ 221, 5, 385, 29 } },
        .{ .dpi = 144, .width = 960, .height = 1350, .logical_right = 640, .jump = .{ 332, 8, 578, 44 } },
        .{ .dpi = 192, .width = 1280, .height = 1800, .logical_right = 640, .jump = .{ 442, 10, 770, 58 } },
    }) |case| {
        app.window.hwnd = c.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
            std.unicode.utf8ToUtf16LeStringLiteral("Hidden header DPI geometry"),
            c.WS_POPUP,
            0,
            0,
            case.width,
            case.height,
            null,
            null,
            c.GetModuleHandleW(null),
            null,
        ) orelse return error.WindowCreationFailed;
        defer _ = c.DestroyWindow(app.window.hwnd);
        app.dpi = case.dpi;
        try std.testing.expect(c.IsWindowVisible(app.window.hwnd) == 0);
        try std.testing.expectEqual(case.logical_right, logicalClientRect(app.window.hwnd, app.dpi).right);
        const layout = app.headerLayout();
        const physical = (AccessibilityBounds{ .logical = layout.bounds(.jump).? }).physicalRect(app.dpi);
        try std.testing.expectEqualDeep(case.jump, [4]i32{ physical.left, physical.top, physical.right, physical.bottom });
        const x = logicalCoordinate(case.jump[0] + 4, app.dpi);
        const y = logicalCoordinate(case.jump[1] + 4, app.dpi);
        try std.testing.expectEqual(GraphCanvas.HeaderAction.jump, layout.actionAt(x, y).?);
        try std.testing.expect(layout.actionAt(logicalCoordinate(case.jump[2] + 4, app.dpi), y) == null);
    }
}

const DpiExpectedElement = struct {
    identity: []const u8,
    bounds: ?[3][4]i32 = null,
    present: ?bool = null,
    name: ?[]const u8 = null,
    eligible: ?bool = null,
    invokable: ?bool = null,
};

const DpiAccessibilitySink = struct {
    expected: []const DpiExpectedElement,
    dpi_index: usize,
    canvas: ?c.RECT = null,
    checked: bool = false,
    failure: ?anyerror = null,

    fn syncCanvasBounds(self: *@This(), bounds: c.RECT) void {
        self.canvas = bounds;
    }

    fn syncElements(self: *@This(), _: []const u8, elements: []const Accessibility.DynamicElement, _: WorktreeStatus.Policy, _: Accessibility.WorktreeCapabilities) void {
        self.checked = true;
        self.checkElements(elements) catch |err| {
            self.failure = err;
        };
    }

    fn checkElements(self: *@This(), elements: []const Accessibility.DynamicElement) !void {
        for (self.expected) |expected| {
            var found = false;
            const required = expected.present orelse (expected.bounds != null);
            for (elements) |element| {
                if (!std.mem.eql(u8, expected.identity, element.identity)) continue;
                found = true;
                if (!required) {
                    std.debug.print("Unexpected UIA element: {s}\n", .{expected.identity});
                    return error.UnexpectedAccessibilityElement;
                }
                const actual = [4]i32{ element.left, element.top, element.right, element.bottom };
                if (expected.bounds) |bounds| {
                    std.testing.expectEqualDeep(bounds[self.dpi_index], actual) catch |err| {
                        std.debug.print("UIA bounds mismatch: {s}, DPI index {d}\n", .{ expected.identity, self.dpi_index });
                        return err;
                    };
                } else try std.testing.expect(element.left < element.right and element.top < element.bottom);
                if (expected.name) |name| try std.testing.expectEqualStrings(name, element.name);
                if (expected.eligible) |eligible| try std.testing.expectEqual(eligible, element.eligible);
                if (expected.invokable) |invokable| try std.testing.expectEqual(invokable, element.invokable);
            }
            if (!found and required) std.debug.print("Missing UIA element: {s}\n", .{expected.identity});
            try std.testing.expectEqual(required, found);
        }
    }
};

test "Show in Graph shared action publishes project UIA after native effects complete" {
    const Probe = struct {
        var native_finished: bool = false;
        var published_before_native: bool = false;
        var updates: usize = 0;
        var workspace_chrome: usize = 0;
        var selected_card: bool = false;
        var sink: @This() = .{};

        fn native(app: *App) void {
            native_finished = app.surface == .project and !app.workspace_controls.panel_visible;
        }
        fn publish(app: *App) void {
            published_before_native = !native_finished;
            app.syncAccessibilityTo(&sink, .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 });
        }
        fn syncCanvasBounds(_: *@This(), _: c.RECT) void {}
        fn syncElements(_: *@This(), _: []const u8, elements: []const Accessibility.DynamicElement, _: WorktreeStatus.Policy, _: Accessibility.WorktreeCapabilities) void {
            updates += 1;
            workspace_chrome = 0;
            selected_card = false;
            for (elements) |element| {
                if (std.mem.startsWith(u8, element.identity, "workspace-")) workspace_chrome += 1;
                if (std.mem.eql(u8, element.identity, "project-card:A:loop")) selected_card = element.selected;
            }
        }
    };
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .client = .{ .allocator = allocator, .frame_buffer = try @import("FrameBuffer.zig").FrameBuffer.init(allocator, .v2) },
        .daemon = undefined,
        .model = GraphModel.Model.init(allocator),
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
        .surface = .workspace,
        .workspace_controls = .{ .rail_visible = true, .panel_visible = true, .activity_enabled = false },
    };
    defer app.client.deinit();
    defer app.model.deinit();
    defer app.sidebar_state.deinit();
    defer app.declared_entry_ids.deinit();
    defer app.kept_worktree_paths.deinit();
    _ = try app.model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"g","project":{"path":"A","name":"Alpha"},"nodes":[{"id":"loop","title":"Loop","state":"running"}],"edges":[]}}}
    );
    try std.testing.expect(app.model.setSelectedID("loop"));
    var workspace: TerminalWorkspace.Workspace = .{
        .parent = null,
        .allocator = allocator,
        .zmx_path = &.{},
        .cwd = &.{},
        .input_queue = .{ .allocator = allocator },
        .layout = try @import("WorkspaceLayout.zig").Layout.init(allocator, "A"),
        .layout_path = &.{},
        .project_key = &.{},
    };
    defer workspace.layout.deinit();
    try workspace.layout.addTab("loop", true);
    app.workspace = &workspace;
    Probe.native_finished = false;
    Probe.published_before_native = false;
    Probe.updates = 0;
    app.syncAccessibilityTo(&Probe.sink, .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 });
    try std.testing.expect(Probe.workspace_chrome > 0);
    try std.testing.expect(Probe.selected_card);
    // Native layout/focus effects and sink storage are supplied; model/action/UIA row production are real.
    app.showInGraph(Probe.native, Probe.publish);
    try std.testing.expectEqual(GraphCanvas.Surface.project, app.surface);
    try std.testing.expect(!app.workspace_controls.panel_visible);
    try std.testing.expect(Probe.native_finished);
    try std.testing.expectEqual(@as(usize, 2), Probe.updates);
    try std.testing.expectEqual(@as(usize, 0), Probe.workspace_chrome);
    try std.testing.expect(Probe.selected_card);
    try std.testing.expect(!Probe.published_before_native);
    // The UIA route also has its common publication tail; a second publish is idempotent.
    Probe.publish(&app);
    try std.testing.expectEqual(@as(usize, 0), Probe.workspace_chrome);
    try std.testing.expect(Probe.selected_card);
}

test "graphChanged republishes renamed project card and sidebar accessibility names" {
    const Probe = struct {
        var sink: @This() = .{};
        var updates: usize = 0;
        var card_name: ?[]const u8 = null;
        var sidebar_name: ?[]const u8 = null;

        fn publish(app: *App) void {
            app.syncAccessibilityTo(&sink, .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 });
        }

        fn syncCanvasBounds(_: *@This(), _: c.RECT) void {}

        fn syncElements(_: *@This(), _: []const u8, elements: []const Accessibility.DynamicElement, _: WorktreeStatus.Policy, _: Accessibility.WorktreeCapabilities) void {
            updates += 1;
            for (elements) |element| {
                if (std.mem.eql(u8, element.identity, "project-card:A:loop")) card_name = element.name;
                if (std.mem.eql(u8, element.identity, "loop:A:loop")) sidebar_name = element.name;
            }
        }
    };
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .client = .{ .allocator = allocator, .frame_buffer = try @import("FrameBuffer.zig").FrameBuffer.init(allocator, .v2) },
        .daemon = undefined,
        .model = GraphModel.Model.init(allocator),
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
    };
    defer app.client.deinit();
    defer app.model.deinit();
    defer app.sidebar_state.deinit();
    defer app.declared_entry_ids.deinit();
    defer app.kept_worktree_paths.deinit();
    defer if (app.selected_node_id.len != 0) allocator.free(app.selected_node_id);
    _ = try app.model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"g","project":{"path":"A","name":"Alpha"},"nodes":[{"id":"loop","title":"Old title","state":"running"}],"edges":[]}}}
    );
    app.last_project_opened = "A";
    Probe.updates = 0;
    Probe.card_name = null;
    Probe.sidebar_name = null;

    const renamed_frame =
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"id":"g","project":{"path":"A","name":"Alpha"},"nodes":[{"id":"loop","title":"Renamed loop","state":"running"}],"edges":[]}}}
    ;
    app.onFrameWithAccessibilityPublish(renamed_frame, Probe.publish);

    try std.testing.expectEqual(@as(usize, 1), Probe.updates);
    try std.testing.expectEqualStrings("Renamed loop", Probe.card_name.?);
    try std.testing.expectEqualStrings("Renamed loop", Probe.sidebar_name.?);
    try std.testing.expectEqualStrings("Renamed loop", app.model.graph.?.nodes.items[0].title);
    try std.testing.expectEqualStrings("Renamed loop", app.model.graphFor("A").?.nodes.items[0].title);
}

test "folder picker completion waits for native callback unwind" {
    const Probe = struct {
        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeFolderOpenLifetimeTest");
        const select_command: c.WPARAM = 1;
        const cancel_command: c.WPARAM = 2;
        const restore_message: c.UINT = c.WM_APP + 91;

        var app: ?*App = null;
        var callback_active: bool = false;
        var posted_message: c.UINT = 0;
        var post_calls: usize = 0;
        var timer_calls: usize = 0;
        var timer_id: usize = 0;
        var timer_interval_ms: c.UINT = 0;
        var cancel_timer_calls: usize = 0;
        var owner_restored: bool = false;
        var open_calls: usize = 0;
        var opened_during_callback: bool = false;
        var opened_before_owner_restored: bool = false;
        var opened_expected_path: bool = false;
        var schedule_failed: bool = false;

        fn reset() void {
            app = null;
            callback_active = false;
            posted_message = 0;
            post_calls = 0;
            timer_calls = 0;
            timer_id = 0;
            timer_interval_ms = 0;
            cancel_timer_calls = 0;
            owner_restored = false;
            open_calls = 0;
            opened_during_callback = false;
            opened_before_owner_restored = false;
            opened_expected_path = false;
            schedule_failed = false;
        }

        fn postMessage(hwnd: c.HWND, message: c.UINT) bool {
            post_calls += 1;
            posted_message = message;
            return c.PostMessageW(hwnd, message, 0, 0) != 0;
        }

        fn armTimer(hwnd: c.HWND, id: usize, interval_ms: c.UINT) bool {
            timer_calls += 1;
            timer_id = id;
            timer_interval_ms = interval_ms;
            return c.SetTimer(hwnd, id, interval_ms, null) != 0;
        }

        fn cancelTimer(hwnd: c.HWND, id: usize) void {
            cancel_timer_calls += 1;
            _ = c.KillTimer(hwnd, id);
        }

        fn openProject(_: *App, path: []const u8) void {
            open_calls += 1;
            opened_during_callback = callback_active;
            opened_before_owner_restored = !owner_restored;
            opened_expected_path = std.mem.eql(u8, path, "C:\\fixtures\\caf\xc3\xa9");
        }

        fn windowProc(
            hwnd: c.HWND,
            message: c.UINT,
            wparam: c.WPARAM,
            lparam: c.LPARAM,
        ) callconv(.winapi) c.LRESULT {
            if (message == c.WM_COMMAND) {
                callback_active = true;
                defer callback_active = false;
                if (wparam == select_command) {
                    const value = app.?;
                    const path = value.allocator.dupe(u8, "C:\\fixtures\\caf\xc3\xa9") catch {
                        schedule_failed = true;
                        return 0;
                    };
                    value.scheduleFolderOpenWith(path, @This()) catch {
                        schedule_failed = true;
                    };
                }
                return 0;
            }
            if (message == restore_message) {
                owner_restored = true;
                return 0;
            }
            if (message == c.WM_TIMER and wparam == timer_id) {
                cancelTimer(hwnd, timer_id);
                app.?.dispatchPendingFolderOpenWith(@This());
                return 0;
            }
            return c.DefWindowProcW(hwnd, message, wparam, lparam);
        }

        fn dispatchOne(hwnd: c.HWND, message_min: c.UINT, message_max: c.UINT) !void {
            var message: c.MSG = undefined;
            var available = false;
            for (0..100) |_| {
                available = c.PeekMessageW(
                    &message,
                    hwnd,
                    message_min,
                    message_max,
                    c.PM_REMOVE,
                ) != 0;
                if (available) break;
                std.Thread.sleep(std.time.ns_per_ms);
            }
            try std.testing.expect(available);
            _ = c.DispatchMessageW(&message);
        }
    };

    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .client = try DaemonClient.initForTesting(allocator),
        .daemon = undefined,
        .model = GraphModel.Model.init(allocator),
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
    };
    Probe.reset();
    Probe.app = &app;
    var window_class = std.mem.zeroes(c.WNDCLASSW);
    window_class.hInstance = c.GetModuleHandleW(null);
    window_class.lpszClassName = Probe.class_name;
    window_class.lpfnWndProc = &Probe.windowProc;
    if (c.RegisterClassW(&window_class) == 0) return error.WindowClassRegistrationFailed;
    defer _ = c.UnregisterClassW(Probe.class_name, window_class.hInstance);
    var hwnd = c.CreateWindowExW(
        0,
        Probe.class_name,
        Probe.class_name,
        c.WS_OVERLAPPED,
        0,
        0,
        100,
        100,
        null,
        null,
        window_class.hInstance,
        null,
    ) orelse return error.WindowCreationFailed;
    app.window.hwnd = hwnd;
    defer {
        Probe.app = null;
        if (hwnd != null) _ = c.DestroyWindow(hwnd);
        if (app.pending_folder_open_path.len != 0) allocator.free(app.pending_folder_open_path);
        app.client.deinit();
        app.model.deinit();
        app.sidebar_state.deinit();
        app.declared_entry_ids.deinit();
        app.kept_worktree_paths.deinit();
    }

    _ = c.SendMessageW(hwnd, c.WM_COMMAND, Probe.select_command, 0);

    try std.testing.expect(!Probe.schedule_failed);
    try std.testing.expectEqual(@as(usize, 0), Probe.post_calls);
    try std.testing.expectEqual(@as(usize, 1), Probe.timer_calls);
    try std.testing.expect(Probe.timer_id != MainWindow.timer_id);
    try std.testing.expect(Probe.timer_id != MainWindow.menu_watchdog_timer_id);
    try std.testing.expect(Probe.timer_interval_ms > 0);
    try std.testing.expectEqual(@as(usize, 0), Probe.open_calls);
    try std.testing.expect(!Probe.opened_during_callback);

    try std.testing.expect(c.PostMessageW(hwnd, Probe.restore_message, 0, 0) != 0);
    try Probe.dispatchOne(hwnd, Probe.restore_message, Probe.restore_message);
    try std.testing.expect(Probe.owner_restored);
    try Probe.dispatchOne(hwnd, c.WM_TIMER, c.WM_TIMER);
    try std.testing.expectEqual(@as(usize, 1), Probe.open_calls);
    try std.testing.expect(!Probe.opened_during_callback);
    try std.testing.expect(!Probe.opened_before_owner_restored);
    try std.testing.expect(Probe.opened_expected_path);
    app.dispatchPendingFolderOpenWith(Probe);
    try std.testing.expectEqual(@as(usize, 1), Probe.open_calls);
    try std.testing.expectEqual(@as(usize, 1), Probe.cancel_timer_calls);

    _ = c.SendMessageW(hwnd, c.WM_COMMAND, Probe.cancel_command, 0);
    try std.testing.expectEqual(@as(usize, 1), Probe.open_calls);
    try std.testing.expectEqual(@as(usize, 1), Probe.timer_calls);

    Probe.owner_restored = false;
    _ = c.SendMessageW(hwnd, c.WM_COMMAND, Probe.select_command, 0);
    try std.testing.expect(c.PostMessageW(hwnd, Probe.restore_message, 0, 0) != 0);
    try Probe.dispatchOne(hwnd, Probe.restore_message, Probe.restore_message);
    try Probe.dispatchOne(hwnd, c.WM_TIMER, c.WM_TIMER);
    try std.testing.expectEqual(@as(usize, 2), Probe.open_calls);
    try std.testing.expectEqual(@as(usize, 2), Probe.timer_calls);
    try std.testing.expectEqual(@as(usize, 2), Probe.cancel_timer_calls);

    _ = c.SendMessageW(hwnd, c.WM_COMMAND, Probe.select_command, 0);
    try std.testing.expectEqual(@as(usize, 3), Probe.timer_calls);
    try std.testing.expectEqual(@as(usize, 2), Probe.open_calls);
    try std.testing.expect(app.pending_folder_open_path.len != 0);
    _ = c.DestroyWindow(hwnd);
    hwnd = null;
    app.window.hwnd = null;
}

const GraphPublicationTest = struct {
    var sink: DpiAccessibilitySink = .{ .expected = &.{}, .dpi_index = 0 };
    var publications: usize = 0;
    var layouts: usize = 0;
    var layout_saw_project: bool = false;
    var refreshes: usize = 0;
    var rebinds: usize = 0;
    var rebound_beta: bool = false;
    var loop_bars: usize = 0;
    var toolbars: usize = 0;
    var selected_beta_projects: usize = 0;
    var selected_beta_cards: usize = 0;

    fn init(mode: Wire.ProtocolMode) !App {
        const allocator = std.testing.allocator;
        var app: App = .{
            .allocator = allocator,
            .client = try DaemonClient.initForTesting(allocator),
            .daemon = undefined,
            .model = GraphModel.Model.init(allocator),
            .sidebar_state = Sidebar.State.init(allocator),
            .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
            .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
        };
        app.client.mode = mode;
        app.client.state = .connected;
        reset(&.{});
        return app;
    }

    fn deinit(app: *App) void {
        app.client.deinit();
        app.model.deinit();
        app.sidebar_state.deinit();
        app.declared_entry_ids.deinit();
        app.kept_worktree_paths.deinit();
        for ([_][]const u8{
            app.selected_node_id,              app.selected_edge_project_path, app.selected_edge_id,
            app.last_project_opened,           app.accepted_subscription,      app.pending_project_path,
            app.pending_rebind_path,           app.pending_sent_path,          app.pending_folder_open_path,
            app.pending_previous_subscription, app.status_override,            app.ingress_error,
        }) |value| if (value.len != 0) app.allocator.free(value);
    }

    fn frame(app: *App, path: []const u8, title_text: []const u8) ![]u8 {
        return std.fmt.allocPrint(app.allocator, "{{\"version\":{d},\"kind\":\"event\",\"sequence\":3,\"event\":{{\"graphChanged\":{{\"id\":\"{s}\",\"project\":{{\"path\":\"{s}\",\"name\":\"{s}\"}},\"nodes\":[{{\"id\":\"other\",\"title\":\"Other\",\"state\":\"idle\"}},{{\"id\":\"loop\",\"title\":\"{s}\",\"state\":\"running\",\"presence\":{{\"presence\":\"awaitingInput\",\"confidence\":\"reported\"}}}}],\"edges\":[]}}}}}}", .{ @as(u8, if (app.client.mode == .v1) 1 else 2), path, path, if (std.mem.eql(u8, path, "A")) "Alpha" else "Beta", title_text });
    }

    fn seed(app: *App) !void {
        for ([_][]const u8{ "A", "B" }) |path| {
            const initial = try frame(app, path, if (std.mem.eql(u8, path, "A")) "Alpha loop" else "Beta loop");
            defer app.allocator.free(initial);
            _ = try app.model.updateFromFrame(initial);
        }
        try std.testing.expect(app.selectProject("B"));
        try std.testing.expect(app.selectNodeIndex(1));
        app.last_project_opened = try app.allocator.dupe(u8, "A");
        app.accepted_subscription = try app.allocator.dupe(u8, "A");
        app.client.subscription_path = try app.allocator.dupe(u8, "A");
    }

    fn reset(expected: []const DpiExpectedElement) void {
        sink = .{ .expected = expected, .dpi_index = 0 };
        publications = 0;
        layouts = 0;
        layout_saw_project = false;
        refreshes = 0;
        rebinds = 0;
        rebound_beta = false;
        loop_bars = 0;
        toolbars = 0;
        selected_beta_projects = 0;
        selected_beta_cards = 0;
    }

    fn rebind(_: *App, path: []const u8) void {
        rebinds += 1;
        rebound_beta = std.mem.eql(u8, path, "B");
    }

    fn refresh(_: *App) void {
        refreshes += 1;
    }

    fn layout(app: *App) void {
        layouts += 1;
        layout_saw_project = app.surface == .project and !app.workspace_controls.panel_visible;
    }

    fn publish(app: *App) void {
        publications += 1;
        app.syncAccessibilityTo(@This(), .{ .left = 0, .top = 0, .right = 1200, .bottom = 780 });
    }

    fn syncCanvasBounds(bounds: c.RECT) void {
        sink.syncCanvasBounds(bounds);
    }

    fn syncElements(_: []const u8, elements: []const Accessibility.DynamicElement, policy: WorktreeStatus.Policy, capabilities: Accessibility.WorktreeCapabilities) void {
        loop_bars = 0;
        toolbars = 0;
        selected_beta_projects = 0;
        selected_beta_cards = 0;
        for (elements) |element| {
            if (std.mem.eql(u8, element.identity, "workspace-loop-bar:loop")) loop_bars += 1;
            if (std.mem.eql(u8, element.identity, "workspace-toolbar:B")) toolbars += 1;
            if (std.mem.eql(u8, element.identity, "open-project:B") and element.selected) selected_beta_projects += 1;
            if ((std.mem.eql(u8, element.identity, "project-card:B:loop") or
                std.mem.eql(u8, element.identity, "overview-card:B:loop")) and element.selected) selected_beta_cards += 1;
        }
        sink.syncElements("", elements, policy, capabilities);
    }

    fn receive(app: *App, path: []const u8, title_text: []const u8) !void {
        const publication = try frame(app, path, title_text);
        defer app.allocator.free(publication);
        app.onFrameWithEffects(publication, rebind, refresh, publish);
    }

    fn takeOpen(app: *App, path: []const u8) !void {
        try std.testing.expectEqual(@as(usize, 1), app.client.outbound_count);
        const expected = try Wire.commandOpenProject(app.allocator, path);
        defer app.allocator.free(expected);
        const index = app.client.outbound_head;
        try std.testing.expectEqualStrings(expected, app.client.outbound[index]);
        try std.testing.expectEqualDeep(app.pending_open_request_id, app.client.outbound_request_ids[index]);
        app.allocator.free(app.client.outbound[index]);
        app.client.outbound_request_ids[index] = null;
        app.client.outbound_head = (index + 1) % app.client.outbound.len;
        app.client.outbound_count = 0;
    }

    fn expectPublished() !void {
        try std.testing.expect(sink.checked);
        if (sink.failure) |err| return err;
    }
};

fn expectSettledGraphPublication(surface: GraphCanvas.Surface, owner: []const u8) !void {
    const F = GraphPublicationTest;
    var app = try F.init(.v2);
    defer F.deinit(&app);
    try F.seed(&app);
    app.surface = surface;
    app.workspace_controls.panel_visible = surface == .workspace;
    var workspace: TerminalWorkspace.Workspace = .{
        .parent = null,
        .allocator = app.allocator,
        .zmx_path = &.{},
        .cwd = &.{},
        .input_queue = .{ .allocator = app.allocator },
        .layout = try @import("WorkspaceLayout.zig").Layout.init(app.allocator, "B"),
        .layout_path = &.{},
        .project_key = &.{},
    };
    defer workspace.layout.deinit();
    try workspace.layout.addTab("loop", true);
    app.workspace = &workspace;
    F.publish(&app);
    try F.expectPublished();
    const original_canvas = F.sink.canvas.?;
    try std.testing.expectEqual(@as(usize, if (surface == .workspace) 1 else 0), F.loop_bars);
    try std.testing.expectEqual(@as(usize, if (surface == .workspace) 1 else 0), F.toolbars);

    const alpha_title = if (std.mem.eql(u8, owner, "A")) "Alpha interleaved" else "Alpha loop";
    const beta_title = if (std.mem.eql(u8, owner, "B")) "Beta refreshed" else "Beta loop";
    const expected = [_]DpiExpectedElement{
        .{ .identity = "loop:A:loop", .present = true, .name = alpha_title },
        .{ .identity = "loop:B:loop", .present = true, .name = beta_title },
        .{ .identity = if (surface == .overview) "overview-card:B:loop" else "project-card:B:loop", .present = true, .name = beta_title },
        .{ .identity = "workspace-toolbar:B", .present = surface == .workspace, .name = "Beta", .bounds = if (surface == .workspace) .{ .{ 8, 1, 280, 33 }, .{ 8, 1, 280, 33 }, .{ 8, 1, 280, 33 } } else null },
        .{ .identity = "workspace-loop-bar:loop", .present = surface == .workspace, .name = "Selected loop workspace", .bounds = if (surface == .workspace) .{ .{ 220, 34, 928, 80 }, .{ 220, 34, 928, 80 }, .{ 220, 34, 928, 80 } } else null },
    };
    F.reset(&expected);
    const requests = app.client.next_request;
    try F.receive(&app, owner, if (std.mem.eql(u8, owner, "A")) alpha_title else beta_title);
    const automatically_queued = app.pending_project_path.len;
    // Cross the real deferred-open boundary without mounting a window or terminal.
    app.flushPendingProjectWithLayout(F.layout);
    F.publish(&app);

    try std.testing.expectEqual(surface, app.surface);
    try std.testing.expectEqual(surface == .workspace, app.workspace_controls.panel_visible);
    try std.testing.expectEqualStrings("B", app.model.currentGraph().?.project.path);
    try std.testing.expectEqualStrings("B", app.model.selected_project_path.?);
    try std.testing.expectEqualStrings("loop", app.model.selected().?.id);
    try std.testing.expectEqualStrings("loop", app.selected_node_id);
    try std.testing.expectEqual(@as(?usize, 1), app.model.selectedIndex());
    try std.testing.expectEqualStrings(alpha_title, app.model.graphFor("A").?.nodes.items[1].title);
    try std.testing.expectEqualStrings(beta_title, app.model.graphFor("B").?.nodes.items[1].title);
    var updated_attention = false;
    for (app.model.attention_entries.items) |entry| {
        if (std.mem.eql(u8, entry.project_path, owner) and std.mem.eql(u8, entry.node.title, if (std.mem.eql(u8, owner, "A")) alpha_title else beta_title)) updated_attention = true;
    }
    try std.testing.expect(updated_attention);
    try std.testing.expectEqual(@as(usize, 0), automatically_queued);
    try std.testing.expectEqual(@as(usize, 0), app.pending_rebind_path.len);
    try std.testing.expectEqual(@as(u64, 0), app.open_generation);
    try std.testing.expectEqual(requests, app.client.next_request);
    try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
    try std.testing.expectEqualStrings("A", app.last_project_opened);
    try std.testing.expectEqualStrings("A", app.client.subscription_path);
    try std.testing.expectEqual(@as(usize, 0), F.layouts);
    try std.testing.expectEqual(@as(usize, 1), F.refreshes);
    try std.testing.expect(F.rebinds > 0 and F.rebound_beta);
    try std.testing.expectEqual(@as(usize, 2), F.publications);
    try F.expectPublished();
    try std.testing.expectEqualDeep(original_canvas, F.sink.canvas.?);
    try std.testing.expectEqual(@as(usize, if (surface == .workspace) 1 else 0), F.loop_bars);
    try std.testing.expectEqual(@as(usize, if (surface == .workspace) 1 else 0), F.toolbars);
    try std.testing.expectEqual(@as(usize, 1), F.selected_beta_projects);
    try std.testing.expectEqual(@as(usize, if (surface == .overview) 0 else 1), F.selected_beta_cards);
}

test "graph publication interleaved Alpha refresh preserves cached Beta workspace across flush" {
    try expectSettledGraphPublication(.workspace, "A");
}

test "graph publication same-owner refresh preserves workspace across flush" {
    try expectSettledGraphPublication(.workspace, "B");
}

test "graph publication settled refresh preserves overview across flush" {
    try expectSettledGraphPublication(.overview, "A");
}

test "graph publication first populated graph queues bootstrap once and flushes only when connected" {
    const F = GraphPublicationTest;
    var app = try F.init(.v2);
    defer F.deinit(&app);
    try F.receive(&app, "A", "Alpha loop");
    try std.testing.expectEqualStrings("A", app.pending_project_path);
    try std.testing.expectEqual(@as(u64, 0), app.open_generation);
    app.client.state = .disconnected;
    app.flushPendingProjectWithLayout(F.layout);
    try std.testing.expectEqualStrings("A", app.pending_project_path);
    try std.testing.expectEqual(@as(usize, 0), F.layouts);
    app.client.state = .connected;
    app.flushPendingProjectWithLayout(F.layout);
    try std.testing.expectEqualStrings("A", app.pending_rebind_path);
    try std.testing.expectEqual(@as(u64, 1), app.open_generation);
    try std.testing.expectEqual(@as(usize, 1), F.layouts);
    try std.testing.expect(F.layout_saw_project);
    app.client.state = .connected;
    app.sendPendingOpen();
    try std.testing.expect(app.pending_open_sent);
    try std.testing.expectEqual(@as(usize, 1), app.client.outbound_count);
    try F.receive(&app, "A", "Alpha accepted");
    try F.receive(&app, "A", "Alpha settled");
    app.flushPendingProjectWithLayout(F.layout);
    try std.testing.expectEqual(@as(usize, 0), app.pending_project_path.len);
    try std.testing.expectEqual(@as(usize, 0), app.pending_rebind_path.len);
    try std.testing.expectEqual(@as(u64, 1), app.open_generation);
    try std.testing.expectEqualStrings("A", app.accepted_subscription);
    try std.testing.expectEqual(@as(usize, 1), app.client.outbound_count);
    try F.expectPublished();
}

test "graph publication explicit open preserves v1 and v2 acceptance rejection and subscriptions" {
    const F = GraphPublicationTest;
    for ([_]Wire.ProtocolMode{ .v1, .v2 }) |mode| {
        var app = try F.init(mode);
        defer F.deinit(&app);
        try F.seed(&app);
        app.surface = .workspace;
        app.workspace_controls.panel_visible = true;
        app.openProjectWithLayout("B", F.layout);
        try std.testing.expectEqual(GraphCanvas.Surface.project, app.surface);
        try std.testing.expect(!app.workspace_controls.panel_visible);
        try std.testing.expectEqual(@as(usize, 1), F.layouts);
        try std.testing.expectEqualStrings("A", app.pending_previous_subscription);
        app.client.state = .connected;
        app.sendPendingOpen();
        try std.testing.expect(app.pending_open_sent);
        try std.testing.expectEqual(@as(usize, 1), app.client.outbound_count);
        const request = app.pending_open_request_id.?;
        try F.takeOpen(&app, "B");
        try F.receive(&app, "C", "Foreign");
        try std.testing.expect(app.model.graphFor("C") == null);
        try std.testing.expectEqual(@as(usize, 0), F.publications);
        try F.receive(&app, "A", "Alpha while opening");
        try std.testing.expectEqualStrings("B", app.pending_rebind_path);
        try std.testing.expectEqualStrings("Alpha while opening", app.model.graphFor("A").?.nodes.items[1].title);
        if (mode == .v2) {
            app.onFrameWithEffects(
                \\{"version":2,"kind":"response","requestID":"ffffffff-ffff-4fff-8fff-ffffffffffff","event":{"errorOccurred":"stale rejection"}}
            , F.rebind, F.refresh, F.publish);
            try std.testing.expectEqualStrings("B", app.pending_rebind_path);
            try std.testing.expectEqual(@as(usize, 0), app.ingress_error.len);
        }
        const rejection = if (mode == .v1)
            try app.allocator.dupe(u8,
                \\{"version":1,"kind":"event","event":{"errorOccurred":"B rejected"}}
            )
        else
            try std.fmt.allocPrint(app.allocator, "{{\"version\":2,\"kind\":\"response\",\"requestID\":\"{s}\",\"event\":{{\"errorOccurred\":\"B rejected\"}}}}", .{request});
        defer app.allocator.free(rejection);
        app.onFrameWithEffects(rejection, F.rebind, F.refresh, F.publish);
        try std.testing.expectEqual(@as(usize, 0), app.pending_rebind_path.len);
        try std.testing.expect(!app.pending_open_sent and !app.open_project_pending);
        try std.testing.expectEqualStrings("A", app.client.subscription_path);
        try std.testing.expectEqualStrings("A", app.last_project_opened);
        try std.testing.expectEqualStrings("A", app.accepted_subscription);
        try std.testing.expectEqualStrings("B rejected", app.ingress_error);

        app.openProjectWithLayout("B", F.layout);
        app.client.state = .connected;
        app.sendPendingOpen();
        try std.testing.expect(app.pending_open_sent);
        try F.takeOpen(&app, "B");
        try F.receive(&app, "B", "Beta accepted");
        try std.testing.expectEqualStrings("B", app.model.currentGraph().?.project.path);
        try std.testing.expectEqualStrings("B", app.client.subscription_path);
        try std.testing.expectEqualStrings("B", app.last_project_opened);
        try std.testing.expectEqualStrings("B", app.accepted_subscription);
        try std.testing.expectEqual(@as(usize, 0), app.pending_rebind_path.len);
        try std.testing.expectEqual(@as(usize, 0), app.pending_project_path.len);
        try std.testing.expectEqual(@as(usize, 0), app.ingress_error.len);
        try std.testing.expect(!app.pending_open_sent and !app.open_project_pending);
        try std.testing.expect(app.pending_open_request_id == null);
        try F.expectPublished();
    }
}

test "graph publication v1 queued opens accept the sent owner before the newest intent" {
    const F = GraphPublicationTest;
    var app = try F.init(.v1);
    defer F.deinit(&app);
    try F.seed(&app);
    app.openProjectWithLayout("B", F.layout);
    app.client.state = .connected;
    app.sendPendingOpen();
    try std.testing.expectEqualStrings("B", app.pending_sent_path);
    try F.takeOpen(&app, "B");
    app.openProjectWithLayout("C", F.layout);
    try std.testing.expectEqualStrings("B", app.pending_sent_path);
    try std.testing.expectEqualStrings("C", app.pending_rebind_path);
    try F.receive(&app, "C", "Too early");
    try std.testing.expect(app.model.graphFor("C") == null);
    try F.receive(&app, "B", "Beta accepted");
    try std.testing.expectEqualStrings("B", app.accepted_subscription);
    try std.testing.expectEqualStrings("B", app.pending_previous_subscription);
    try std.testing.expectEqualStrings("C", app.pending_rebind_path);
    try std.testing.expect(app.pending_open_sent and !app.open_project_pending);
    try std.testing.expectEqualStrings("C", app.pending_sent_path);
    try F.takeOpen(&app, "C");
    try F.receive(&app, "C", "Newest accepted");
    try std.testing.expectEqualStrings("C", app.model.currentGraph().?.project.path);
    try std.testing.expectEqualStrings("C", app.accepted_subscription);
    try std.testing.expectEqualStrings("C", app.client.subscription_path);
    try std.testing.expectEqual(@as(usize, 0), app.pending_rebind_path.len);
    try std.testing.expectEqual(@as(usize, 0), app.pending_project_path.len);
    try std.testing.expectEqual(@as(u64, 3), app.client.next_request);
    try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
    try F.expectPublished();
}

test "graph publication adopts the daemon canonical path for the shell's own folder open" {
    const F = GraphPublicationTest;
    for ([_]Wire.ProtocolMode{ .v1, .v2 }) |mode| {
        var app = try F.init(mode);
        defer F.deinit(&app);
        try F.seed(&app);
        // The native folder picker returns a backslash path; the production daemon
        // replies with its canonical forward-slash spelling of the same folder.
        app.openProjectWithLayout("C:\\Fixtures\\Core", F.layout);
        app.client.state = .connected;
        app.sendPendingOpen();
        try std.testing.expect(app.pending_open_sent);
        const request = app.pending_open_request_id;
        try F.takeOpen(&app, "C:\\Fixtures\\Core");
        if (mode == .v2) {
            // An uncorrelated publication for the canonical spelling is not adopted.
            app.onFrameWithEffects(
                \\{"version":2,"kind":"event","sequence":4,"event":{"graphChanged":{"_0":{"project":{"path":"C:/Fixtures/Core","name":"Core"},"nodes":[],"edges":[]}}}}
            , F.rebind, F.refresh, F.publish);
            try std.testing.expect(app.model.graphFor("C:/Fixtures/Core") == null);
            try std.testing.expectEqualStrings("C:\\Fixtures\\Core", app.pending_rebind_path);
        }
        const reply = if (mode == .v2)
            try std.fmt.allocPrint(app.allocator, "{{\"version\":2,\"kind\":\"response\",\"requestID\":\"{s}\",\"event\":{{\"graphChanged\":{{\"_0\":{{\"project\":{{\"path\":\"C:/Fixtures/Core\",\"name\":\"Core\"}},\"nodes\":[],\"edges\":[]}}}}}}}}", .{&upperRequestID(request.?)})
        else
            try app.allocator.dupe(u8,
                \\{"version":1,"kind":"event","event":{"graphChanged":{"_0":{"project":{"path":"C:/Fixtures/Core","name":"Core"},"nodes":[],"edges":[]}}}}
            );
        defer app.allocator.free(reply);
        app.onFrameWithEffects(reply, F.rebind, F.refresh, F.publish);
        const current = app.model.currentGraph() orelse return error.FolderOpenGraphDropped;
        try std.testing.expectEqualStrings("C:/Fixtures/Core", current.project.path);
        try std.testing.expectEqualStrings("Core", current.project.name);
        try std.testing.expectEqualStrings("C:/Fixtures/Core", app.accepted_subscription);
        try std.testing.expectEqualStrings("C:/Fixtures/Core", app.client.subscription_path);
        try std.testing.expectEqualStrings("C:/Fixtures/Core", app.last_project_opened);
        try std.testing.expectEqual(@as(usize, 0), app.pending_rebind_path.len);
        try std.testing.expectEqual(@as(usize, 0), app.pending_sent_path.len);
        try std.testing.expect(!app.pending_open_sent and !app.open_project_pending);
        try std.testing.expectEqual(@as(usize, 0), app.ingress_error.len);
    }
}

test "open workspace applies production stopped state and removes Stop control" {
    const F = GraphPublicationTest;
    var app = try F.init(.v2);
    defer F.deinit(&app);
    try F.seed(&app);
    app.surface = .workspace;

    app.onFrameWithEffects(
        \\{"version":2,"kind":"event","sequence":4,"event":{"graphChanged":{"_0":{"project":{"path":"B","name":"Beta"},"nodes":[{"id":"other","title":"Other","state":{"idle":{}}},{"id":"loop","title":"Beta loop","state":{"stopped":{}}}],"edges":[]}}}}
    , F.rebind, F.refresh, F.publish);

    const graph = workspaceGraph(&app.model) orelse return error.WorkspaceGraphMissing;
    const selected_index = app.model.selectedIndex() orelse return error.WorkspaceSelectionMissing;
    try std.testing.expectEqualStrings("loop", graph.nodes.items[selected_index].id);
    try std.testing.expectEqualStrings("stopped", graph.nodes.items[selected_index].state);
    const loop_bar = TerminalWorkspace.loopBarLayout(
        Tokens.sidebar_width,
        1200 - Tokens.loop_detail_width,
        isResolvedLoopState(graph.nodes.items[selected_index].state),
    );
    try std.testing.expect(loop_bar.stop == null);
    try std.testing.expectEqual(@as(usize, 1), F.publications);
}

/// Swift's `UUID.uuidString` echoes request IDs in uppercase.
fn upperRequestID(request: [36]u8) [36]u8 {
    var upper: [36]u8 = undefined;
    for (request, 0..) |byte, index| upper[index] = std.ascii.toUpper(byte);
    return upper;
}

test "graph publication v2 open rejection correlates the daemon's uppercase request ID" {
    const F = GraphPublicationTest;
    var app = try F.init(.v2);
    defer F.deinit(&app);
    try F.seed(&app);
    app.openProjectWithLayout("B", F.layout);
    app.client.state = .connected;
    app.sendPendingOpen();
    const request = app.pending_open_request_id.?;
    try F.takeOpen(&app, "B");
    try std.testing.expect(!std.mem.eql(u8, &request, &upperRequestID(request)));
    const rejection = try std.fmt.allocPrint(app.allocator, "{{\"version\":2,\"kind\":\"response\",\"requestID\":\"{s}\",\"event\":{{\"errorOccurred\":\"B rejected\"}}}}", .{&upperRequestID(request)});
    defer app.allocator.free(rejection);
    app.onFrameWithEffects(rejection, F.rebind, F.refresh, F.publish);
    try std.testing.expectEqual(@as(usize, 0), app.pending_rebind_path.len);
    try std.testing.expect(!app.pending_open_sent and !app.open_project_pending);
    try std.testing.expectEqualStrings("A", app.accepted_subscription);
    try std.testing.expectEqualStrings("B rejected", app.ingress_error);
}

test "graph publication v2 superseded opens reject stale graphs and errors without losing latest intent" {
    const F = GraphPublicationTest;
    var app = try F.init(.v2);
    defer F.deinit(&app);
    try F.seed(&app);
    app.openProjectWithLayout("B", F.layout);
    app.client.state = .connected;
    app.sendPendingOpen();
    const old_request = app.pending_open_request_id.?;
    try F.takeOpen(&app, "B");
    app.openProjectWithLayout("C", F.layout);
    app.client.state = .connected;
    app.sendPendingOpen();
    const latest_request = app.pending_open_request_id.?;
    try F.takeOpen(&app, "C");
    try F.receive(&app, "B", "Stale Beta");
    try std.testing.expectEqualStrings("Beta loop", app.model.graphFor("B").?.nodes.items[1].title);
    const stale_error = try std.fmt.allocPrint(app.allocator, "{{\"version\":2,\"kind\":\"response\",\"requestID\":\"{s}\",\"event\":{{\"errorOccurred\":\"old rejection\"}}}}", .{old_request});
    defer app.allocator.free(stale_error);
    app.onFrameWithEffects(stale_error, F.rebind, F.refresh, F.publish);
    try std.testing.expectEqualStrings("C", app.pending_rebind_path);
    try std.testing.expectEqualDeep(latest_request, app.pending_open_request_id.?);
    try std.testing.expectEqual(@as(usize, 0), F.publications);
    try std.testing.expectEqual(@as(usize, 0), app.ingress_error.len);
    try F.receive(&app, "C", "Latest accepted");
    try std.testing.expectEqualStrings("C", app.model.currentGraph().?.project.path);
    try std.testing.expectEqualStrings("C", app.accepted_subscription);
    try std.testing.expectEqual(@as(usize, 0), app.pending_rebind_path.len);
    try std.testing.expectEqual(@as(usize, 0), app.pending_project_path.len);
    try F.expectPublished();
}

test "graph publication null graph and recent-project bootstrap preserve existing queued intent" {
    const F = GraphPublicationTest;
    var app = try F.init(.v2);
    defer F.deinit(&app);
    app.onFrameWithEffects(
        \\{"version":2,"kind":"event","event":{"graphChanged":null}}
    , F.rebind, F.refresh, F.publish);
    try std.testing.expect(app.model.currentGraph() == null);
    try std.testing.expectEqual(@as(usize, 0), app.pending_project_path.len);
    app.onFrameWithEffects(
        \\{"version":2,"kind":"event","event":{"recentProjectsListed":[{"path":"A","name":"Alpha"}]}}
    , F.rebind, F.refresh, F.publish);
    try std.testing.expectEqualStrings("A", app.pending_project_path);
    try F.receive(&app, "A", "Alpha loop");
    try std.testing.expectEqualStrings("A", app.pending_project_path);
    app.flushPendingProjectWithLayout(F.layout);
    try std.testing.expectEqual(@as(u64, 1), app.open_generation);
    try std.testing.expectEqualStrings("A", app.pending_rebind_path);
    try F.expectPublished();
}
fn noticeTestApp() !App {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .client = .{ .allocator = allocator, .frame_buffer = try @import("FrameBuffer.zig").FrameBuffer.init(allocator, .v2) },
        .daemon = undefined,
        .model = GraphModel.Model.init(allocator),
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
        .surface = .overview,
        .workspace_controls = .{ .rail_visible = true, .panel_visible = false, .activity_enabled = false },
    };
    errdefer deinitNoticeTestApp(&app);
    const frames = [_][]const u8{
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"C:\\notice-a","name":"Same"},"nodes":[],"edges":[]}}}
        ,
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"project":{"path":"C:\\notice-b","name":"Same"},"nodes":[],"edges":[]}}}
        ,
        \\{"version":2,"kind":"event","sequence":3,"event":{"graphChanged":{"project":{"path":"C:\\notice-c","name":"Unknown"},"nodes":[],"edges":[]}}}
        ,
        \\{"version":2,"kind":"event","sequence":4,"event":{"graphChanged":{"project":{"path":"ssh://host/repo","name":"Remote"},"nodes":[],"edges":[]}}}
        ,
        \\{"version":2,"kind":"event","sequence":5,"event":{"graphChanged":{"project":{"path":"graphcode://global","name":"Global"},"nodes":[],"edges":[]}}}
        ,
    };
    for (frames) |frame| _ = try app.model.updateFromFrame(frame);
    return app;
}

fn deinitNoticeTestApp(app: *App) void {
    if (app.worktree_dialog) |*dialog| dialog.deinit();
    if (app.worktree_inspection) |*inspection| WorktreeStatus.deinitInspection(app.allocator, inspection);
    if (app.selected_worktree_path.len != 0) app.allocator.free(app.selected_worktree_path);
    if (app.uia_fixture_project_path.len != 0) app.allocator.free(app.uia_fixture_project_path);
    app.client.deinit();
    app.model.deinit();
    app.releaseUiaFixtureModelArena();
    app.sidebar_state.deinit();
    app.declared_entry_ids.deinit();
    app.kept_worktree_paths.deinit();
}

fn ownedNoticeTestInspection(project_path: []const u8, count: usize, bytes: u64) !WorktreeStatus.Inspection {
    const allocator = std.testing.allocator;
    const path = try allocator.dupe(u8, project_path);
    errdefer allocator.free(path);
    const branch = try allocator.dupe(u8, "main");
    errdefer allocator.free(branch);
    var entries = std.array_list.Managed(WorktreeStatus.Entry).init(allocator);
    errdefer WorktreeStatus.deinit(allocator, &entries);
    for (0..count) |index| {
        const entry_path = try std.fmt.allocPrint(allocator, "{s}\\tree-{d}", .{ project_path, index });
        errdefer allocator.free(entry_path);
        const entry_branch = try allocator.dupe(u8, "topic");
        errdefer allocator.free(entry_branch);
        try entries.append(.{
            .path = entry_path,
            .branch = entry_branch,
            .primary = index == 0,
            .size_bytes = if (index == 0) bytes else 0,
            .size_complete = true,
            .pushed = true,
            .landed = true,
        });
    }
    return .{ .entries = entries, .project_path = path, .default_branch = branch };
}

fn installNoticeTestInspection(app: *App, project_path: []const u8, count: usize, bytes: u64) !void {
    var inspection = try ownedNoticeTestInspection(project_path, count, bytes);
    errdefer WorktreeStatus.deinitInspection(std.testing.allocator, &inspection);
    try app.acceptWorktreeInspection(inspection, WorktreeStatus.policyReadOutcome(error.FileNotFound));
}

test "worktree notice App installation is atomic and retains independent value snapshots" {
    var app = try noticeTestApp();
    defer deinitNoticeTestApp(&app);
    try installNoticeTestInspection(&app, "C:\\notice-a", 8, 1024);
    try std.testing.expect(app.model.graphFor("C:\\notice-b").?.worktree_notice == null);
    const previous = app.model.graphFor("C:\\notice-a").?.worktree_notice.?;
    for (0..2) |fail_index| {
        var replacement = try ownedNoticeTestInspection("C:\\notice-b", 1, 2147483648);
        defer WorktreeStatus.deinitInspection(std.testing.allocator, &replacement);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        app.allocator = failing.allocator();
        defer app.allocator = std.testing.allocator;
        try std.testing.expectError(error.OutOfMemory, app.acceptWorktreeInspection(replacement, WorktreeStatus.policyReadOutcome(error.FileNotFound)));
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqualStrings("C:\\notice-a", app.worktree_inspection.?.project_path);
        try std.testing.expectEqualDeep(previous, app.model.graphFor("C:\\notice-a").?.worktree_notice.?);
        try std.testing.expect(app.model.graphFor("C:\\notice-b").?.worktree_notice == null);
    }
    try installNoticeTestInspection(&app, "C:\\notice-b", 1, 2147483648);
    try std.testing.expectEqualStrings("C:\\notice-b", app.worktree_dialog.?.project_path);
    try std.testing.expectEqualDeep(previous, app.model.graphFor("C:\\notice-a").?.worktree_notice.?);
    try std.testing.expectEqual(@as(u64, 2147483648), app.model.graphFor("C:\\notice-b").?.worktree_notice.?.observation.?.size.bytes);
}

test "worktree notice App policy application follows captured owner not selected project" {
    var app = try noticeTestApp();
    defer deinitNoticeTestApp(&app);
    try installNoticeTestInspection(&app, "C:\\notice-a", 8, 1024);
    const a = app.model.graphFor("C:\\notice-a").?.worktree_notice.?;
    try std.testing.expect(app.model.selectProject("C:\\notice-b"));
    const configured = WorktreeStatus.policyReadOutcome(
        \\{"allowReclaim":false,"confirmEachReclaim":true,"onResolveLanded":"keep","noticeSizeGB":4,"noticeCount":12}
    );
    try app.acceptWorktreePolicy("C:\\notice-b", configured);
    try std.testing.expectEqualDeep(a, app.model.graphFor("C:\\notice-a").?.worktree_notice.?);
    try std.testing.expectEqual(@as(u32, 8), app.worktree_dialog.?.policy.notice_count);
    try app.acceptWorktreePolicy("C:\\notice-a", configured);
    try std.testing.expectEqual(@as(u32, 12), app.worktree_dialog.?.policy.notice_count);
    try std.testing.expectEqual(WorktreeStatus.NoticeState.below_threshold, app.model.graphFor("C:\\notice-a").?.worktree_notice.?.state());
    try app.acceptWorktreePolicy("C:\\notice-a", WorktreeStatus.policyReadOutcome(error.AccessDenied));
    try std.testing.expectEqual(WorktreeStatus.NoticeState.indeterminate, app.model.graphFor("C:\\notice-a").?.worktree_notice.?.state());
    try std.testing.expect(!app.worktree_dialog.?.policy.allow_reclaim);
    try std.testing.expect(app.model.applyLifecycle(.close, "C:\\notice-a"));
    try std.testing.expectError(error.WorktreeProjectClosed, app.acceptWorktreePolicy("C:\\notice-a", configured));
    try std.testing.expectEqual(@as(u32, 12), app.model.graphFor("C:\\notice-b").?.worktree_notice.?.policy.value().?.notice_count);
}

const NoticePolicyStorageProbe = struct {
    app: *App,
    expected_path: []const u8 = "C:\\notice-a",
    contents: []const u8 = "",
    written_contents: []const u8 = "",
    write_error: ?anyerror = error.NoSpaceLeft,
    read_error: ?anyerror = null,
    read_unestablished: bool = false,
    write_count: usize = 0,
    read_count: usize = 0,
    paths_match: bool = true,
    select_after_write: bool = false,
    close_after_write: bool = false,

    fn savePolicy(self: *@This(), _: std.mem.Allocator, path: []const u8, _: WorktreeStatus.Policy) !void {
        self.paths_match = self.paths_match and std.mem.eql(u8, path, self.expected_path);
        self.write_count += 1;
        self.contents = self.written_contents;
        if (self.select_after_write) try std.testing.expect(self.app.model.selectProject("C:\\notice-b"));
        if (self.close_after_write) try std.testing.expect(self.app.model.applyLifecycle(.close, self.expected_path));
        if (self.write_error) |err| return err;
    }

    fn loadPolicyOutcome(self: *@This(), _: std.mem.Allocator, path: []const u8) WorktreeStatus.PolicyOutcome {
        self.paths_match = self.paths_match and std.mem.eql(u8, path, self.expected_path);
        self.read_count += 1;
        if (self.read_unestablished) return .not_loaded;
        if (self.read_error) |err| return WorktreeStatus.policyReadOutcome(err);
        return WorktreeStatus.policyReadOutcome(self.contents);
    }
};

test "worktree notice failed policy writes reconcile the captured owner's checked outcome" {
    var app = try noticeTestApp();
    defer deinitNoticeTestApp(&app);
    try installNoticeTestInspection(&app, "C:\\notice-a", 8, 1024);
    var storage = NoticePolicyStorageProbe{ .app = &app, .select_after_write = true };
    try std.testing.expectError(error.NoSpaceLeft, app.saveWorktreePolicyUsing("C:\\notice-a", .{ .notice_count = 12 }, &storage));
    try std.testing.expectEqual(@as(usize, 1), storage.read_count);
    try std.testing.expect(storage.paths_match);
    try std.testing.expectEqualStrings("", storage.contents);
    const record = app.model.graphFor("C:\\notice-a").?.worktree_notice.?;
    try std.testing.expectEqual(error.MalformedPolicy, record.policy.failed);
    try std.testing.expectEqual(WorktreeStatus.NoticeState.indeterminate, record.state());
    try std.testing.expect(app.model.graphFor("C:\\notice-b").?.worktree_notice == null);
}

test "worktree notice save reconciliation preserves write error and isolates foreign owners" {
    const configured =
        \\{"allowReclaim":false,"confirmEachReclaim":true,"onResolveLanded":"keep","noticeSizeGB":4,"noticeCount":12}
    ;
    const cases = [_]struct {
        contents: []const u8 = configured,
        write_error: ?anyerror = null,
        read_error: ?anyerror = null,
        unestablished: bool = false,
        close_owner: bool = false,
        expected_error: ?anyerror = null,
        expected_count: ?u32 = 12,
    }{
        .{},
        .{ .contents = "", .write_error = error.NoSpaceLeft, .expected_error = error.NoSpaceLeft, .expected_count = null },
        .{ .contents = "{", .write_error = error.NoSpaceLeft, .expected_error = error.NoSpaceLeft, .expected_count = null },
        .{ .write_error = error.NoSpaceLeft, .read_error = error.AccessDenied, .expected_error = error.NoSpaceLeft, .expected_count = null },
        .{ .read_error = error.AccessDenied, .expected_error = error.AccessDenied, .expected_count = null },
        .{ .write_error = error.NoSpaceLeft, .read_error = error.FileNotFound, .expected_error = error.NoSpaceLeft, .expected_count = 8 },
        .{ .write_error = error.NoSpaceLeft, .unestablished = true, .expected_error = error.NoSpaceLeft, .expected_count = null },
        .{ .unestablished = true, .expected_error = error.WorktreePolicyNotRead, .expected_count = null },
        .{ .write_error = error.NoSpaceLeft, .close_owner = true, .expected_error = error.NoSpaceLeft, .expected_count = null },
        .{ .close_owner = true, .expected_error = error.WorktreeProjectClosed, .expected_count = null },
    };
    for (cases) |case| {
        var app = try noticeTestApp();
        defer deinitNoticeTestApp(&app);
        try installNoticeTestInspection(&app, "C:\\notice-a", 8, 1024);
        try installNoticeTestInspection(&app, "C:\\notice-b", 1, 2147483648);
        try std.testing.expect(app.model.selectProject("C:\\notice-b"));
        const foreign = app.model.graphFor("C:\\notice-b").?.worktree_notice.?;
        const dialog_policy = app.worktree_dialog.?.policy;
        var storage = NoticePolicyStorageProbe{
            .app = &app,
            .written_contents = case.contents,
            .write_error = case.write_error,
            .read_error = case.read_error,
            .read_unestablished = case.unestablished,
            .close_after_write = case.close_owner,
        };
        const result = app.saveWorktreePolicyUsing("C:\\notice-a", .{ .notice_count = 12, .notice_size_gb = 4 }, &storage);
        if (case.expected_error) |err| try std.testing.expectError(err, result) else try result;
        try std.testing.expectEqual(@as(usize, 1), storage.write_count);
        try std.testing.expectEqual(@as(usize, 1), storage.read_count);
        try std.testing.expect(storage.paths_match);
        try std.testing.expectEqualDeep(foreign, app.model.graphFor("C:\\notice-b").?.worktree_notice.?);
        try std.testing.expectEqualStrings("C:\\notice-b", app.worktree_dialog.?.project_path);
        try std.testing.expectEqualDeep(dialog_policy, app.worktree_dialog.?.policy);
        if (case.close_owner) {
            try std.testing.expect(app.model.graphFor("C:\\notice-a") == null);
        } else {
            const record = app.model.graphFor("C:\\notice-a").?.worktree_notice.?;
            if (case.expected_count) |count| {
                try std.testing.expectEqual(count, record.policy.value().?.notice_count);
                if (case.read_error) |read_error| {
                    if (read_error == error.FileNotFound) try std.testing.expectEqual(WorktreeStatus.PolicySource.missing, record.policy.known.source);
                }
            } else {
                try std.testing.expect(record.policy.value() == null);
                try std.testing.expectEqual(WorktreeStatus.NoticeState.indeterminate, record.state());
                if (case.read_error) |err| try std.testing.expectEqual(err, record.policy.failed);
            }
        }
    }
}

test "worktree notice raw inspection presentation is independent of the header notice" {
    var app = try noticeTestApp();
    defer deinitNoticeTestApp(&app);
    try std.testing.expect(app.currentWorktreeInspection() == null);
    try std.testing.expect(app.model.selectProject("C:\\notice-a"));
    try installNoticeTestInspection(&app, "C:\\notice-a", 1, 1024);
    try std.testing.expect(app.headerPresentation().notice == null);
    try std.testing.expect(app.currentWorktreeInspection() != null);
    try std.testing.expectEqualStrings("C:\\notice-a", app.currentWorktreeInspection().?.project_path);
    app.model.invalidateWorktreeNotices(.bindings_changed);
    try std.testing.expect(app.currentWorktreeInspection() != null);
    try app.acceptWorktreePolicy("C:\\notice-a", WorktreeStatus.policyReadOutcome(error.AccessDenied));
    try std.testing.expect(app.currentWorktreeInspection() != null);
    try installNoticeTestInspection(&app, "C:\\notice-a", 8, 0);
    try std.testing.expect(app.headerPresentation().notice != null);
    try std.testing.expect(app.currentWorktreeInspection() != null);
    try std.testing.expect(app.model.selectProject("C:\\notice-b"));
    try app.model.recordWorktreeFailure("C:\\notice-b", error.GitFailed);
    try std.testing.expect(app.currentWorktreeInspection() == null);
    try std.testing.expectEqualStrings("C:\\notice-a", app.worktree_dialog.?.project_path);
}

test "worktree titlebar notice aggregates all projects and targets the worst owner" {
    var app = try noticeTestApp();
    defer deinitNoticeTestApp(&app);
    try installNoticeTestInspection(&app, "C:\\notice-a", 8, 1024);
    try installNoticeTestInspection(&app, "C:\\notice-b", 9, 4 * 1024 * 1024 * 1024);
    try std.testing.expect(app.model.selectProject("C:\\notice-a"));
    const owner = app.worktreeHeaderOwner() orelse return error.MissingWorktreeHeaderOwner;
    try std.testing.expectEqualStrings("C:\\notice-b", owner.project.path);
    const header = app.headerPresentation();
    try std.testing.expectEqual(@as(usize, 1), header.notice_extra_folders);
    const label = try header.label(std.testing.allocator, .inspect_worktrees);
    defer std.testing.allocator.free(label);
    try std.testing.expectEqualStrings("Same: 8 reclaimable +1", label);
}

test "worktree notice root row projection excludes foreign inspection without changing retained dialog" {
    var app = try noticeTestApp();
    defer deinitNoticeTestApp(&app);
    try std.testing.expect(app.model.selectProject("C:\\notice-a"));
    try installNoticeTestInspection(&app, "C:\\notice-a", 1, 1024);
    const owner_row = DpiExpectedElement{
        .identity = "worktree:C:\\notice-a\\tree-0",
        .present = true,
        .name = "C:\\notice-a\\tree-0 - primary checkout - 1.0 KB",
        .eligible = false,
        .invokable = false,
    };
    for (0..3) |phase| {
        if (phase == 1) app.model.invalidateWorktreeNotices(.bindings_changed);
        if (phase == 2) try app.acceptWorktreePolicy("C:\\notice-a", WorktreeStatus.policyReadOutcome(error.AccessDenied));
        var sink = DpiAccessibilitySink{ .expected = &.{owner_row}, .dpi_index = 0 };
        app.syncAccessibilityTo(&sink, .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 });
        try std.testing.expect(sink.checked);
        if (sink.failure) |err| return err;
    }
    try std.testing.expect(app.model.selectProject("C:\\notice-b"));
    try app.model.recordWorktreeFailure("C:\\notice-b", error.GitFailed);
    var sink = DpiAccessibilitySink{
        .expected = &.{
            .{ .identity = "worktree:C:\\notice-a\\tree-0" },
            .{ .identity = "worktree:C:\\notice-b\\tree-0" },
        },
        .dpi_index = 0,
    };
    app.syncAccessibilityTo(&sink, .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 });
    try std.testing.expect(sink.checked);
    if (sink.failure) |err| return err;
    try std.testing.expectEqualStrings("C:\\notice-a", app.worktree_dialog.?.project_path);
    try std.testing.expectEqual(@as(usize, 1), app.worktree_dialog.?.rows.items.len);
    try std.testing.expectEqualStrings("C:\\notice-a\\tree-0", app.worktree_dialog.?.rows.items[0].entry.path);
    try std.testing.expect(app.model.selectProject("C:\\notice-a"));
    try std.testing.expect(app.currentWorktreeInspection() != null);
}

test "worktree notice Reclaim and Keep hit targets require the same inspection owner as paint" {
    var app = try noticeTestApp();
    defer deinitNoticeTestApp(&app);
    const frames = [_][]const u8{
        \\{"version":2,"kind":"event","sequence":20,"event":{"graphChanged":{"project":{"path":"C:\\notice-a","name":"Same"},"nodes":[{"id":"resolved","title":"Resolved","state":"succeeded","worktreeBinding":{"path":"C:\\notice-a\\tree-1"}}],"edges":[]}}}
        ,
        \\{"version":2,"kind":"event","sequence":21,"event":{"graphChanged":{"project":{"path":"C:\\notice-b","name":"Same"},"nodes":[{"id":"resolved","title":"Resolved","state":"succeeded","worktreeBinding":{"path":"C:\\notice-a\\tree-1"}}],"edges":[]}}}
        ,
    };
    for (frames) |frame| _ = try app.model.updateFromFrame(frame);
    try installNoticeTestInspection(&app, "C:\\notice-a", 2, 1024);
    try std.testing.expect(app.model.selectProject("C:\\notice-a"));
    const geometry = GraphCanvas.reclaimOfferBounds(GraphCanvas.nodeBounds(0, &app.canvas));
    const targets = [_]struct { bounds: c.RECT, action: GraphCanvas.ReclaimAction }{
        .{ .bounds = geometry.reclaim, .action = .reclaim },
        .{ .bounds = geometry.keep, .action = .keep },
    };
    for (targets) |target| {
        const hit = GraphCanvas.hitTestReclaimOffer(
            app.model.graph.?.nodes.items,
            app.currentWorktreeInspection(),
            app.kept_worktree_paths.items,
            target.bounds.left + 1,
            target.bounds.top + 1,
            &app.canvas,
        ) orelse return error.MissingMatchedOwnerHit;
        try std.testing.expectEqual(target.action, hit.action);
        try std.testing.expectEqual(@as(usize, 0), hit.node_index);
    }
    try std.testing.expect(app.model.selectProject("C:\\notice-b"));
    try std.testing.expect(app.currentWorktreeInspection() == null);
    for (targets) |target| {
        try std.testing.expect(GraphCanvas.hitTestReclaimOffer(
            app.model.graph.?.nodes.items,
            app.currentWorktreeInspection(),
            app.kept_worktree_paths.items,
            target.bounds.left + 1,
            target.bounds.top + 1,
            &app.canvas,
        ) == null);
        // The raw foreign snapshot would create an invisible hotspot at the same location.
        try std.testing.expect(GraphCanvas.hitTestReclaimOffer(
            app.model.graph.?.nodes.items,
            &app.worktree_inspection.?,
            app.kept_worktree_paths.items,
            target.bounds.left + 1,
            target.bounds.top + 1,
            &app.canvas,
        ) != null);
    }
    try std.testing.expectEqualStrings("C:\\notice-a", app.worktree_dialog.?.project_path);
}

test "worktree notice actual UIA fixture data shares the supplied project identity" {
    var app = try noticeTestApp();
    defer deinitNoticeTestApp(&app);
    const project = "D:\\owned-ui-fixture\\project";
    try app.installUiaFixtureData(project);
    try std.testing.expectEqualStrings(project, app.model.graph.?.project.path);
    if (app.worktree_inspection == null) {
        std.debug.print("remote fixture inspection missing: {s}\n", .{app.status_override});
        return error.MissingRemoteWorktreeInspection;
    }
    try std.testing.expectEqualStrings(project, app.worktree_inspection.?.project_path);
    try std.testing.expectEqualStrings(project, app.worktree_dialog.?.project_path);
    try std.testing.expect(app.currentWorktreeInspection() != null);
    try std.testing.expect(!app.worktree_inspection.?.entries.items[0].size_complete);
}

test "worktree notice actual UIA fixture emits Reclaim and Keep through the production sink" {
    var app = try noticeTestApp();
    defer deinitNoticeTestApp(&app);
    try app.installUiaFixtureData("D:\\owned-ui-fixture\\project");
    app.surface = .project;
    var sink = DpiAccessibilitySink{
        .expected = &.{
            .{ .identity = "reclaim:D:\\owned-ui-fixture\\project:11111111-1111-4111-8111-111111111111", .present = true, .name = "Reclaim", .invokable = true },
            .{ .identity = "keep:D:\\owned-ui-fixture\\project:11111111-1111-4111-8111-111111111111", .present = true, .name = "Keep", .invokable = true },
        },
        .dpi_index = 0,
    };
    app.syncAccessibilityTo(&sink, .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 });
    try std.testing.expect(sink.checked);
    if (sink.failure) |err| return err;
    const original_owner = app.worktree_inspection.?.project_path;
    app.worktree_inspection.?.project_path = @constCast("D:\\genuinely-foreign\\project");
    defer app.worktree_inspection.?.project_path = original_owner;
    try std.testing.expect(app.currentWorktreeInspection() == null);
    var foreign = DpiAccessibilitySink{
        .expected = &.{
            .{ .identity = "reclaim:D:\\owned-ui-fixture\\project:11111111-1111-4111-8111-111111111111" },
            .{ .identity = "keep:D:\\owned-ui-fixture\\project:11111111-1111-4111-8111-111111111111" },
        },
        .dpi_index = 0,
    };
    app.syncAccessibilityTo(&foreign, .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 });
    try std.testing.expect(foreign.checked);
    if (foreign.failure) |err| return err;
}

fn expectOwnedUiaFixtureData(allocator: std.mem.Allocator) !void {
    var data = try UiaFixtureData.init(allocator, "D:\\owned-ui-fixture\\project");
    defer data.deinit(allocator);
    try std.testing.expectEqualStrings(data.model.graph.?.project.path, data.inspection.project_path);
    try std.testing.expectEqualStrings(data.inspection.project_path, data.dialog.project_path);
}

test "worktree notice owned UIA fixture staging handles allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, expectOwnedUiaFixtureData, .{});
}

test "worktree notice owned UIA fixture resets retain stable heap allocator ownership" {
    var app = try noticeTestApp();
    defer deinitNoticeTestApp(&app);
    const project = "D:\\owned-ui-fixture\\project";
    for (0..3) |_| {
        try app.installUiaFixtureData(project);
        const arena = app.uia_fixture_model_arena.?;
        try std.testing.expectEqual(@intFromPtr(arena), @intFromPtr(app.model.allocator.ptr));
        try std.testing.expectEqual(@intFromPtr(app.allocator.ptr), @intFromPtr(app.worktree_inspection.?.entries.allocator.ptr));
        try std.testing.expectEqualStrings(project, app.uia_fixture_project_path);
        try app.appendUiaFixtureLoop();
        try app.appendUiaFixtureLoop();
        try std.testing.expectEqual(@as(usize, 3), app.model.graph.?.nodes.items.len);
        try std.testing.expectEqual(@as(usize, 3), app.model.graphFor(project).?.nodes.items.len);
        try app.applyUiaFixtureGraph(.empty, "Empty project", 50, "[]", "[]");
        try std.testing.expectEqualStrings("D:\\owned-ui-fixture\\project\\empty", app.model.graphFor("D:\\owned-ui-fixture\\project\\empty").?.project.path);
        const inspection_path = app.worktree_inspection.?.entries.items[0].path;
        try app.resetUiaFixtureModel();
        try std.testing.expect(app.uia_fixture_model_arena == null);
        try std.testing.expectEqual(@intFromPtr(app.allocator.ptr), @intFromPtr(app.model.allocator.ptr));
        try std.testing.expectEqualStrings("D:\\owned-ui-fixture\\project\\fixture-safe", inspection_path);
        try std.testing.expectEqualStrings(project, app.worktree_dialog.?.project_path);
        try std.testing.expectEqualStrings(project, try app.requiredUiaFixtureProject());
    }
}

test "worktree notice owned UIA fixture rejects changed missing and invalid owners atomically" {
    var app = try noticeTestApp();
    defer deinitNoticeTestApp(&app);
    try std.testing.expectError(error.UiaFixtureProjectNotCaptured, app.requiredUiaFixtureProject());
    for ([_][]const u8{ "", "relative", "C:relative", "C:\\" }) |path| {
        try std.testing.expectError(error.InvalidUiaFixtureProject, app.installUiaFixtureData(path));
        try std.testing.expect(app.uia_fixture_model_arena == null);
    }
    try app.installUiaFixtureData("D:\\owned-ui-fixture\\project");
    const arena = app.uia_fixture_model_arena.?;
    try std.testing.expectError(error.UiaFixtureProjectChanged, app.installUiaFixtureData("D:\\different-owner\\project"));
    try std.testing.expectEqual(arena, app.uia_fixture_model_arena.?);
    try std.testing.expectEqualStrings("D:\\owned-ui-fixture\\project", app.model.graph.?.project.path);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    app.allocator = failing.allocator();
    const result = app.installUiaFixtureData("D:\\owned-ui-fixture\\project");
    app.allocator = std.testing.allocator;
    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqual(arena, app.uia_fixture_model_arena.?);
    try std.testing.expectEqualStrings("D:\\owned-ui-fixture\\project", app.worktree_dialog.?.project_path);
}

test "worktree notice owned UIA fixture paths encode and preserve exact data safety facts" {
    const allocator = std.testing.allocator;
    var data = try UiaFixtureData.init(allocator, "D:\\owned fixture\\project-\xc3\xa9");
    defer data.deinit(allocator);
    const project = data.inspection.project_path;
    const graph = data.model.graph.?;
    try std.testing.expectEqualStrings(project, graph.project.path);
    try std.testing.expectEqualStrings(project, data.model.recent_projects.items[0].path);
    try std.testing.expectEqualStrings("11111111-1111-4111-8111-111111111111", graph.nodes.items[0].id);
    try std.testing.expectEqualStrings("UIA loop A", graph.nodes.items[0].title);
    try std.testing.expectEqualStrings("succeeded", graph.nodes.items[0].state);
    try std.testing.expectEqualStrings(graph.nodes.items[0].worktree_path, data.inspection.entries.items[0].path);
    try std.testing.expectEqual(WorktreeStatus.ReclaimDecision.reclaimable, WorktreeStatus.decision(data.inspection.entries.items[0]));
    try std.testing.expectEqual(WorktreeStatus.ReclaimDecision.keep, WorktreeStatus.decision(data.inspection.entries.items[1]));
    for (data.inspection.entries.items) |entry| try std.testing.expect(!entry.size_complete);
    const size = try WorktreeStatus.sizeCoverageText(allocator, WorktreeStatus.totalSize(data.inspection.entries.items));
    defer allocator.free(size);
    try std.testing.expectEqualStrings("size not measured", size);
    const prefix = try std.mem.concat(allocator, u8, &.{ project, "\\" });
    defer allocator.free(prefix);
    inline for (.{ UiaFixturePath.safe, .unsafe, .empty, .jump, .sweep_safe, .sweep_unsafe }) |kind| {
        const path = try uiaFixturePath(allocator, project, kind);
        defer allocator.free(path);
        try std.testing.expect(std.mem.startsWith(u8, path, prefix));
    }
    const policy = try WorktreeStatus.policyPath(allocator, project);
    defer allocator.free(policy);
    try std.testing.expect(std.mem.startsWith(u8, policy, prefix));
}

test "worktree notice App resolver owns exact paths across reorder close and allocation failure" {
    var app = try noticeTestApp();
    defer deinitNoticeTestApp(&app);
    const payload = Accessibility.worktreeIdentityPayload("overview-worktree-notice:C:\\notice-a");
    const path = (try app.resolveOverviewWorktreeNotice(std.testing.allocator, payload)).?;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("C:\\notice-a", path);
    std.mem.swap(GraphModel.GraphSummary, &app.model.graphs.items[0], &app.model.graphs.items[1]);
    const reordered = (try app.resolveOverviewWorktreeNotice(std.testing.allocator, payload)).?;
    defer std.testing.allocator.free(reordered);
    try std.testing.expectEqualStrings(path, reordered);
    const remote = (try app.resolveOverviewWorktreeNotice(
        std.testing.allocator,
        Accessibility.worktreeIdentityPayload("overview-worktree-notice:ssh://host/repo"),
    )).?;
    defer std.testing.allocator.free(remote);
    try std.testing.expectEqualStrings("ssh://host/repo", remote);
    for (0..4) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, app.resolveOverviewWorktreeNotice(failing.allocator(), payload));
        try std.testing.expect(failing.has_induced_failure);
    }
    try std.testing.expect(app.model.applyLifecycle(.close, "C:\\notice-a"));
    try std.testing.expectEqualStrings("C:\\notice-a", path);
    try std.testing.expect((try app.resolveOverviewWorktreeNotice(std.testing.allocator, payload)) == null);
    app.surface = .project;
    try std.testing.expect((try app.resolveOverviewWorktreeNotice(std.testing.allocator, Accessibility.worktreeIdentityPayload("overview-worktree-notice:C:\\notice-b"))) == null);
}

test "worktree notice App UIA data shares per-lane labels geometry and once-only DPI" {
    var app = try noticeTestApp();
    defer deinitNoticeTestApp(&app);
    try installNoticeTestInspection(&app, "C:\\notice-a", 8, 1024);
    try installNoticeTestInspection(&app, "C:\\notice-b", 1, 2147483648);
    const expected = [_]DpiExpectedElement{
        .{
            .identity = "overview-worktree-notice:C:\\notice-a",
            .name = "Last inspected: 8 worktrees - 7 reclaimable",
            .bounds = .{ .{ 750, 82, 1036, 102 }, .{ 1125, 123, 1554, 153 }, .{ 1500, 164, 2072, 204 } },
            .eligible = true,
            .invokable = true,
        },
        .{
            .identity = "overview-worktree-notice:C:\\notice-b",
            .name = "Last inspected: 1 worktree",
            .bounds = .{ .{ 750, 198, 1036, 218 }, .{ 1125, 297, 1554, 327 }, .{ 1500, 396, 2072, 436 } },
            .eligible = true,
            .invokable = true,
        },
        .{
            .identity = "overview-worktree-notice:C:\\notice-c",
            .name = "Worktrees not inspected",
            .bounds = .{ .{ 750, 314, 1036, 334 }, .{ 1125, 471, 1554, 501 }, .{ 1500, 628, 2072, 668 } },
            .eligible = true,
            .invokable = true,
        },
        .{
            .identity = "overview-worktree-notice:ssh://host/repo",
            .name = "Worktrees not inspected",
            .bounds = .{ .{ 750, 430, 1036, 450 }, .{ 1125, 645, 1554, 675 }, .{ 1500, 860, 2072, 900 } },
            .eligible = true,
            .invokable = true,
        },
        .{ .identity = "overview-worktree-notice:graphcode://global" },
    };
    const previous = app.model.graphFor("C:\\notice-a").?.worktree_notice.?;
    for ([_]u32{ 96, 144, 192 }, 0..) |dpi, index| {
        app.dpi = dpi;
        var sink = DpiAccessibilitySink{ .expected = &expected, .dpi_index = index };
        app.syncAccessibilityTo(&sink, .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 });
        try std.testing.expect(sink.checked);
        if (sink.failure) |err| return err;
        try std.testing.expectEqualDeep(previous, app.model.graphFor("C:\\notice-a").?.worktree_notice.?);
    }
    try app.acceptWorktreePolicy("C:\\notice-a", WorktreeStatus.policyReadOutcome(error.AccessDenied));
    try app.model.recordWorktreeFailure("C:\\notice-b", error.GitFailed);
    var failures = [_]DpiExpectedElement{ expected[0], expected[1], expected[2] };
    failures[0].name = "Policy unavailable: 8 worktrees - 7 reclaimable (last inspected) (AccessDenied)";
    failures[1].name = "Inspection failed: 1 worktree (last inspected) (GitFailed)";
    app.dpi = 96;
    var sink = DpiAccessibilitySink{ .expected = &failures, .dpi_index = 0 };
    app.syncAccessibilityTo(&sink, .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 });
    if (sink.failure) |err| return err;
    try std.testing.expect(sink.checked);
    try std.testing.expectEqual(WorktreeStatus.NoticeState.indeterminate, GraphCanvas.overviewWorktreeNotice(app.model.graphFor("C:\\notice-a").?).?.state);
    try std.testing.expectEqual(WorktreeStatus.NoticeState.indeterminate, GraphCanvas.overviewWorktreeNotice(app.model.graphFor("C:\\notice-b").?).?.state);
}

fn expectDpiAccessibility(surface: GraphCanvas.Surface, canvas: ?[3][4]i32, expected: []const DpiExpectedElement, quick_chat: bool) !void {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .client = .{
            .allocator = allocator,
            .frame_buffer = try @import("FrameBuffer.zig").FrameBuffer.init(allocator, .v2),
        },
        .daemon = undefined,
        .model = GraphModel.Model.init(allocator),
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
        .surface = surface,
        .workspace_is_quick_chat = quick_chat,
        .workspace_controls = .{ .rail_visible = true, .panel_visible = true, .activity_enabled = false },
    };
    defer app.client.deinit();
    defer app.model.deinit();
    defer app.sidebar_state.deinit();
    defer app.declared_entry_ids.deinit();
    defer app.kept_worktree_paths.deinit();
    app.ingress_error = try allocator.dupe(u8, "Fixture alert");
    defer allocator.free(app.ingress_error);
    _ = try app.model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"g","project":{"path":"A","name":"Alpha"},"nodes":[{"id":"loop","title":"Loop","state":"running","createdAt":1,"inputTokens":100,"metricHistory":[{"value":1},{"value":2}],"presence":{"presence":"awaitingInput","confidence":"reported"}}],"edges":[]}}}
    );
    try app.model.recent_projects.append(.{ .path = try allocator.dupe(u8, "C"), .name = try allocator.dupe(u8, "Recent") });
    try app.model.quick_chats.append(.{
        .id = try allocator.dupe(u8, "chat"),
        .title = try allocator.dupe(u8, "Chat"),
        .backend = try allocator.dupe(u8, "claudeCode"),
    });
    app.selected_quick_chat = 0;
    app.worktree_inspection = .{
        .entries = std.array_list.Managed(WorktreeStatus.Entry).init(allocator),
        .default_branch = try allocator.dupe(u8, "main"),
        .project_path = try allocator.dupe(u8, "A"),
    };
    defer WorktreeStatus.deinitInspection(allocator, &app.worktree_inspection.?);
    // A notice needs a threshold breach; an empty inspection is not visible chrome.
    try app.worktree_inspection.?.entries.append(.{
        .path = try allocator.dupe(u8, "A-worktree"),
        .branch = try allocator.dupe(u8, "topic"),
        .size_bytes = 2 * 1024 * 1024 * 1024,
        .size_complete = true,
    });
    try app.model.recordWorktreeInspection(&app.worktree_inspection.?, WorktreeStatus.policyReadOutcome(error.FileNotFound));
    var workspaces = [_]WorkspaceLifecycle.Workspace{
        .{ .name = "Fixture", .path = "B", .identity = "b", .is_default = false },
    };
    app.workspace_list = .{ .items = &workspaces };
    var workspace: TerminalWorkspace.Workspace = .{
        .parent = null,
        .allocator = allocator,
        .zmx_path = &.{},
        .cwd = &.{},
        .input_queue = .{ .allocator = allocator },
        .layout = try @import("WorkspaceLayout.zig").Layout.init(allocator, "A"),
        .layout_path = &.{},
        .project_key = &.{},
    };
    defer workspace.layout.deinit();
    try workspace.layout.addTab("agent", true);
    try workspace.layout.addTab("shell", false);
    app.workspace = &workspace;
    const physical_layouts = [_][3]i32{ .{ 220, 80, 708 }, .{ 330, 120, 1062 }, .{ 440, 160, 1416 } };
    for ([_]u32{ 96, 144, 192 }, 0..) |dpi, index| {
        app.dpi = dpi;
        workspace.layout_origin_x = physical_layouts[index][0];
        workspace.layout_origin_y = physical_layouts[index][1];
        workspace.layout_width = physical_layouts[index][2];
        var sink: DpiAccessibilitySink = .{ .expected = expected, .dpi_index = index };
        app.syncAccessibilityTo(&sink, .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 });
        try std.testing.expect(sink.checked);
        if (sink.failure) |err| return err;
        if (canvas) |bounds| {
            const actual = sink.canvas orelse return error.MissingCanvasBounds;
            try std.testing.expectEqualDeep(bounds[index], [4]i32{ actual.left, actual.top, actual.right, actual.bottom });
        }
    }
}

test "DPI UIA fixed graph uses physical client bounds" {
    try expectDpiAccessibility(.project, .{ .{ 220, 34, 1200, 650 }, .{ 330, 51, 1800, 975 }, .{ 440, 68, 2400, 1300 } }, &.{}, false);
}

test "DPI UIA logical cards headers sidebar and direct inserts scale once" {
    const common = [_]DpiExpectedElement{
        .{ .identity = "header-attention:needs-you", .bounds = .{ .{ 288, 5, 400, 29 }, .{ 432, 8, 600, 44 }, .{ 576, 10, 800, 58 } } },
        .{ .identity = "header-worktree:worktrees", .bounds = .{ .{ 408, 5, 588, 29 }, .{ 612, 8, 882, 44 }, .{ 816, 10, 1176, 58 } } },
        .{ .identity = "header-jump:jump", .bounds = .{ .{ 596, 5, 760, 29 }, .{ 894, 8, 1140, 44 }, .{ 1192, 10, 1520, 58 } } },
        .{ .identity = "sidebar-section:local", .bounds = .{ .{ 12, 109, 232, 135 }, .{ 18, 164, 348, 203 }, .{ 24, 218, 464, 270 } } },
        .{ .identity = "sidebar-error-footer:ingress", .bounds = .{ .{ 8, 816, 212, 858 }, .{ 12, 1224, 318, 1287 }, .{ 16, 1632, 424, 1716 } } },
        .{ .identity = "workspace-switch:B", .bounds = .{ .{ 250, 34, 500, 62 }, .{ 375, 51, 750, 93 }, .{ 500, 68, 1000, 124 } } },
    };
    for ([_]GraphCanvas.Surface{ .project, .overview, .quick_chats, .workspace }) |surface| {
        try expectDpiAccessibility(surface, null, &common, false);
        if (surface != .workspace) try expectDpiAccessibility(surface, null, &.{
            .{ .identity = "header-toggle-panel:control" },
            .{ .identity = "workspace-toolbar:A" },
        }, false);
    }
    try expectDpiAccessibility(.project, null, &.{
        .{ .identity = "project-card:A:loop", .bounds = .{ .{ 252, 84, 502, 190 }, .{ 378, 126, 753, 285 }, .{ 504, 168, 1004, 380 } } },
        .{ .identity = "canvas-alert:ingress", .bounds = .{ .{ 244, 556, 1176, 612 }, .{ 366, 834, 1764, 918 }, .{ 488, 1112, 2352, 1224 } } },
    }, false);
    try expectDpiAccessibility(.overview, null, &.{
        .{ .identity = "overview-card:A:loop", .bounds = .{ .{ 262, 118, 482, 204 }, .{ 393, 177, 723, 306 }, .{ 524, 236, 964, 408 } } },
    }, false);
    try expectDpiAccessibility(.quick_chats, null, &.{
        .{ .identity = "quick-chat-card:chat", .bounds = .{ .{ 262, 88, 482, 152 }, .{ 393, 132, 723, 228 }, .{ 524, 176, 964, 304 } } },
    }, false);
    try expectDpiAccessibility(.workspace, null, &.{
        .{ .identity = "header-toggle-panel:control", .bounds = .{ .{ 768, 5, 904, 29 }, .{ 1152, 8, 1356, 44 }, .{ 1536, 10, 1808, 58 } } },
        .{ .identity = "workspace-toolbar:A", .bounds = .{ .{ 8, 1, 280, 33 }, .{ 12, 2, 420, 50 }, .{ 16, 2, 560, 66 } } },
        .{ .identity = "workspace-loop-bar:loop", .bounds = .{ .{ 220, 34, 928, 80 }, .{ 330, 51, 1392, 120 }, .{ 440, 68, 1856, 160 } } },
        .{ .identity = "workspace-show-graph:show-graph", .bounds = .{ .{ 824, 44, 916, 70 }, .{ 1236, 66, 1374, 105 }, .{ 1648, 88, 1832, 140 } } },
        .{ .identity = "workspace-stop:loop", .bounds = .{ .{ 732, 44, 816, 70 }, .{ 1098, 66, 1224, 105 }, .{ 1464, 88, 1632, 140 } } },
        .{ .identity = "workspace-toggle-panel:control", .bounds = .{ .{ 1100, 46, 1182, 68 }, .{ 1650, 69, 1773, 102 }, .{ 2200, 92, 2364, 136 } } },
        .{ .identity = "workspace-detail-sparkline:loop", .bounds = .{ .{ 946, 798, 1182, 830 }, .{ 1419, 1197, 1773, 1245 }, .{ 1892, 1596, 2364, 1660 } } },
        .{ .identity = "workspace-detail-start:loop", .bounds = .{ .{ 946, 836, 1182, 856 }, .{ 1419, 1254, 1773, 1284 }, .{ 1892, 1672, 2364, 1712 } } },
        .{ .identity = "workspace-detail-usage:loop", .bounds = .{ .{ 946, 856, 1182, 876 }, .{ 1419, 1284, 1773, 1314 }, .{ 1892, 1712, 2364, 1752 } } },
        .{ .identity = "quick-chat-workspace:chat" },
    }, false);
    try expectDpiAccessibility(.workspace, null, &.{
        .{ .identity = "quick-chat-workspace:chat", .bounds = .{ .{ 220, 650, 1200, 900 }, .{ 330, 975, 1800, 1350 }, .{ 440, 1300, 2400, 1800 } } },
        .{ .identity = "header-toggle-panel:control" },
        .{ .identity = "workspace-toolbar:A" },
    }, true);
}

test "DPI UIA terminal tab close and controls retain physical geometry" {
    try expectDpiAccessibility(.workspace, null, &.{
        .{ .identity = "workspace-tab:1", .bounds = .{ .{ 340, 84, 452, 106 }, .{ 450, 124, 562, 146 }, .{ 560, 164, 672, 186 } } },
        .{ .identity = "workspace-tab-close:1", .bounds = .{ .{ 428, 84, 452, 106 }, .{ 538, 124, 562, 146 }, .{ 648, 164, 672, 186 } } },
        .{ .identity = "workspace-new-tab:control", .bounds = .{ .{ 708, 83, 776, 107 }, .{ 1172, 123, 1240, 147 }, .{ 1636, 163, 1704, 187 } } },
        .{ .identity = "workspace-split-right:control", .bounds = .{ .{ 780, 83, 848, 107 }, .{ 1244, 123, 1312, 147 }, .{ 1708, 163, 1776, 187 } } },
        .{ .identity = "workspace-split-down:control", .bounds = .{ .{ 852, 83, 920, 107 }, .{ 1316, 123, 1384, 147 }, .{ 1780, 163, 1848, 187 } } },
    }, false);
}

const OverviewAccessibilitySink = struct {
    expected: []const struct {
        identity: []const u8,
        name: ?[]const u8 = null,
        selected: bool = false,
        bounds: ?[4]i32 = null,
    },
    card_count: usize,
    checked: bool = false,
    failure: ?anyerror = null,

    fn syncCanvasBounds(_: *@This(), _: c.RECT) void {}

    fn syncElements(self: *@This(), _: []const u8, elements: []const Accessibility.DynamicElement, _: WorktreeStatus.Policy, _: Accessibility.WorktreeCapabilities) void {
        self.checked = true;
        self.check(elements) catch |err| {
            self.failure = err;
        };
    }

    fn check(self: *@This(), elements: []const Accessibility.DynamicElement) !void {
        var cards: usize = 0;
        for (elements) |element| {
            if (std.mem.startsWith(u8, element.identity, "overview-card:") or
                std.mem.startsWith(u8, element.identity, "project-card:")) cards += 1;
        }
        try std.testing.expectEqual(self.card_count, cards);
        for (self.expected) |expected| {
            var matches: usize = 0;
            for (elements) |element| {
                if (!std.mem.eql(u8, expected.identity, element.identity)) continue;
                matches += 1;
                try std.testing.expectEqual(expected.selected, element.selected);
                if (expected.name) |name| try std.testing.expectEqualStrings(name, element.name);
                if (expected.bounds) |bounds|
                    try std.testing.expectEqualDeep(bounds, [4]i32{ element.left, element.top, element.right, element.bottom });
            }
            if (matches != 1) std.debug.print("Expected exactly one overview element: {s}; found {d}\n", .{ expected.identity, matches });
            try std.testing.expectEqual(@as(usize, 1), matches);
        }
    }

    fn expect(self: *@This(), app: *App) !void {
        self.checked = false;
        self.failure = null;
        app.syncAccessibilityTo(self, .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 });
        try std.testing.expect(self.checked);
        if (self.failure) |err| return err;
    }
};

fn overviewTestApp(dpi: u32) !App {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .client = .{ .allocator = allocator, .frame_buffer = try @import("FrameBuffer.zig").FrameBuffer.init(allocator, .v2) },
        .daemon = undefined,
        .model = GraphModel.Model.init(allocator),
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
        .workspace_controls = .{ .rail_visible = true, .panel_visible = false, .activity_enabled = false },
        .dpi = dpi,
    };
    errdefer deinitOverviewTestApp(&app);
    app.window.hwnd = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral("Never shown overview routing test"),
        c.WS_POPUP,
        0,
        0,
        physicalCoordinate(1200, dpi),
        physicalCoordinate(900, dpi),
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.TestWindowCreationFailed;
    return app;
}

fn loadActivationTestFixture(app: *App) !void {
    _ = try app.model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"C:\\activation-fixture","name":"Activation fixture"},"nodes":[{"id":"stopped-loop","title":"Stopped loop","loopType":"turnBased","state":{"running":{}}},{"id":"target-loop","title":"Visible idle loop","loopType":"sketch","state":{"idle":{}}},{"id":"other-loop","title":"Unrelated loop","loopType":"turnBased","state":{"stopped":{}}}],"edges":[]}}}
    );
    _ = try app.model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"project":{"path":"C:\\activation-fixture","name":"Activation fixture"},"nodes":[{"id":"stopped-loop","title":"Stopped loop","loopType":"turnBased","state":{"stopped":{}}},{"id":"target-loop","title":"Visible idle loop","loopType":"sketch","state":{"idle":{}}},{"id":"other-loop","title":"Unrelated loop","loopType":"turnBased","state":{"stopped":{}}}],"edges":[]}}}
    );
}

fn expectSingleActivation(app: *App, project_path: []const u8, node_id: []const u8) !void {
    try std.testing.expectEqualStrings(project_path, app.model.selected_project_path.?);
    try std.testing.expectEqualStrings(node_id, app.model.selected().?.id);
    try std.testing.expectEqualStrings(node_id, app.selected_node_id);
    try std.testing.expectEqual(@as(usize, 1), app.client.outbound_count);
    const expected = try std.fmt.allocPrint(app.allocator, "\"resumeSession\":{{\"_0\":\"{s}\"}}", .{node_id});
    defer app.allocator.free(expected);
    try std.testing.expect(std.mem.indexOf(u8, app.client.outbound[app.client.outbound_head], expected) != null);
    const graph = app.model.graphFor(project_path) orelse return error.TestExpectedGraph;
    const stopped = GraphModel.findNodeIndexByID(graph.nodes.items, "stopped-loop") orelse return error.TestExpectedLoop;
    const other = GraphModel.findNodeIndexByID(graph.nodes.items, "other-loop") orelse return error.TestExpectedLoop;
    try std.testing.expectEqualStrings("stopped", graph.nodes.items[stopped].state);
    try std.testing.expectEqualStrings("stopped", graph.nodes.items[other].state);
}

fn deinitOverviewTestApp(app: *App) void {
    app.drainWorktreeInspection();
    app.drainWorktreeReclaim();
    if (app.worktree_dialog) |*dialog| dialog.deinit();
    if (app.worktree_inspection) |*inspection| WorktreeStatus.deinitInspection(app.allocator, inspection);
    app.allocator.free(app.selected_node_id);
    app.allocator.free(app.selected_edge_project_path);
    app.allocator.free(app.selected_edge_id);
    app.allocator.free(app.selected_worktree_path);
    app.allocator.free(app.status_override);
    app.allocator.free(app.canvas_press_project_path);
    app.allocator.free(app.canvas_press_node_id);
    app.client.deinit();
    app.model.deinit();
    app.sidebar_state.deinit();
    app.declared_entry_ids.deinit();
    app.kept_worktree_paths.deinit();
    if (app.window.hwnd != null) _ = c.DestroyWindow(app.window.hwnd);
}

fn loadOverviewTestGraphs(app: *App, alpha: []const u8, beta: []const u8) !void {
    const alpha_nodes =
        \\[{"id":"a1","title":"Alpha 1","loopType":"turnBased","state":"idle"},{"id":"a2","title":"Alpha 2","loopType":"turnBased","state":"idle"},{"id":"a3","title":"Alpha 3","loopType":"turnBased","state":"idle"},{"id":"a4","title":"Alpha 4","loopType":"turnBased","state":"idle"}]
    ;
    const beta_nodes =
        \\[{"id":"b1","title":"Beta 1","loopType":"turnBased","state":"idle"},{"id":"b2","title":"Beta 2","loopType":"turnBased","state":"idle"}]
    ;
    for ([_]struct { path: []const u8, name: []const u8, nodes: []const u8 }{
        .{ .path = alpha, .name = "Overview Alpha", .nodes = alpha_nodes },
        .{ .path = beta, .name = "Overview Beta", .nodes = beta_nodes },
    }, 0..) |project, index| {
        const path = try std.json.Stringify.valueAlloc(app.allocator, project.path, .{});
        defer app.allocator.free(path);
        const frame = try std.fmt.allocPrint(
            app.allocator,
            "{{\"version\":2,\"kind\":\"event\",\"sequence\":{d},\"event\":{{\"graphChanged\":{{\"id\":\"{s}\",\"project\":{{\"path\":{s},\"name\":\"{s}\"}},\"nodes\":{s},\"edges\":[]}}}}}}",
            .{ index + 1, project.name, path, project.name, project.nodes },
        );
        defer app.allocator.free(frame);
        _ = try app.model.updateFromFrame(frame);
    }
    try std.testing.expectEqual(@as(usize, 2), app.model.graphs.items.len);
    try std.testing.expectEqual(@as(usize, 4), app.model.graphFor(alpha).?.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.model.graphFor(beta).?.nodes.items.len);
}

fn expectOverviewSelection(app: *App, surface: GraphCanvas.Surface, path: []const u8, node: []const u8) !void {
    try std.testing.expectEqual(surface, app.surface);
    try std.testing.expectEqualStrings(path, app.model.selected_project_path.?);
    try std.testing.expectEqualStrings(path, app.model.currentGraph().?.project.path);
    try std.testing.expectEqualStrings(path, app.model.graph.?.project.path);
    try std.testing.expectEqualStrings(node, app.model.selected_node_id.?);
    try std.testing.expectEqualStrings(node, app.model.selected().?.id);
}

const OverviewTestTarget = struct {
    project: []const u8,
    action: GraphCanvas.OverviewLaneAction,
};

fn overviewTestPreflight(app: *App, x: i32, y: i32, expected: OverviewTestTarget) !c.RECT {
    if (app.surface != .overview or app.workspace != null or app.header_focus != null or
        app.accessibility != null or app.empty_open_folder_button != null or
        app.empty_global_overview_button != null or app.update_thread != null or
        app.window.callback != null or app.window.key_callback != null or
        app.client.worker != null or app.client.callback != null or app.client.want_connected or
        app.client.pipe != c.INVALID_HANDLE_VALUE or
        app.tray.added or app.smoke or app.sidebar_drag_active or app.canvas.dragging or
        app.model.attentionCount() != 0 or app.workspace_controls.panel_visible or
        !app.workspace_controls.rail_visible or app.workspace_controls.activity_enabled or
        app.window.hwnd == null or c.IsWindowVisible(app.window.hwnd) != 0 or
        c.GetWindow(app.window.hwnd, c.GW_CHILD) != null)
        return error.UnsafeOverviewTestState;
    var process: c.DWORD = 0;
    if (c.GetWindowThreadProcessId(app.window.hwnd, &process) != c.GetCurrentThreadId() or
        process != c.GetCurrentProcessId()) return error.UnsafeOverviewTestState;
    const client = logicalClientRect(app.window.hwnd, app.dpi);
    const routing = inputBounds(client.right, client.bottom, app.workspace_controls);
    const bounds = c.RECT{
        .left = routing.canvas.left,
        .top = routing.canvas.top,
        .right = routing.canvas.right,
        .bottom = routing.canvas.bottom,
    };
    if (x < bounds.left or x >= bounds.right or y < bounds.top or y >= bounds.bottom or
        app.headerLayout().actionAt(x, y) != null or GraphCanvas.hitTestZoomControl(x, y, bounds) != null or
        logicalCoordinate(physicalCoordinate(x, app.dpi), app.dpi) != x or
        logicalCoordinate(physicalCoordinate(y, app.dpi), app.dpi) != y)
        return error.UnsafeOverviewTestPoint;
    var lane_hits: usize = 0;
    for (app.model.graphs.items, 0..) |graph, index| {
        if (GraphCanvas.overviewLaneActionAt(&app.model, index, x, y, bounds, &app.canvas)) |action| {
            lane_hits += 1;
            if (!std.mem.eql(u8, expected.project, graph.project.path) or expected.action != action)
                return error.UnexpectedOverviewTestTarget;
            if (action == .inspect_worktrees and
                (!envFlag("GRAPHCODE_UIA_GATE") or envFlag("GRAPHCODE_UIA_SHOW_DIALOGS") or
                    app.worktree_inspection != null or app.worktree_dialog != null or
                    !graph.project.isLocalFilesystem()))
                return error.UnsafeOverviewTestState;
        }
    }
    if (lane_hits != 1) return error.UnexpectedOverviewTestTarget;
    return bounds;
}

fn applyOverviewTestLaneAction(app: *App, x: i32, y: i32, expected: OverviewTestTarget) !void {
    const foreground = c.GetForegroundWindow();
    const focus = c.GetFocus();
    const capture = c.GetCapture();
    // This is the production lane action, not an OS input or mounted-terminal test.
    const bounds = try overviewTestPreflight(app, x, y, expected);
    try std.testing.expect(app.applyOverviewLaneAction(x, y, bounds));
    try std.testing.expectEqual(@as(c_int, 0), c.IsWindowVisible(app.window.hwnd));
    try std.testing.expectEqual(foreground, c.GetForegroundWindow());
    try std.testing.expectEqual(focus, c.GetFocus());
    try std.testing.expectEqual(capture, c.GetCapture());
    if (expected.action == .inspect_worktrees) {
        const deadline = std.time.milliTimestamp() + 30000;
        while (app.worktree_inspection_thread != null and std.time.milliTimestamp() < deadline) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            app.finishWorktreeInspection();
        }
        if (app.worktree_inspection_thread != null) return error.WorktreeInspectionTimeout;
    }
}

test "cross-project overview Open actions select exact projects and emit DPI scoped cards" {
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        var app = try overviewTestApp(dpi);
        defer deinitOverviewTestApp(&app);
        try loadOverviewTestGraphs(&app, "A", "B");
        try std.testing.expect(app.selectProject("A"));
        try std.testing.expect(app.selectNodeIndex(3));
        app.openGlobalOverview();
        try expectOverviewSelection(&app, .overview, "A", "a4");
        const beta_bounds: [4]i32 = switch (dpi) {
            96 => .{ 262, 442, 482, 528 },
            144 => .{ 393, 663, 723, 792 },
            else => .{ 524, 884, 964, 1056 },
        };
        var overview = OverviewAccessibilitySink{ .card_count = 6, .expected = &.{
            .{ .identity = "open-project:A", .selected = true },
            .{ .identity = "open-project:B" },
            .{ .identity = "overview-card:A:a1" },
            .{ .identity = "overview-card:A:a2" },
            .{ .identity = "overview-card:A:a3" },
            .{ .identity = "overview-card:A:a4" },
            .{ .identity = "overview-card:B:b1", .bounds = beta_bounds },
            .{ .identity = "overview-card:B:b2" },
        } };
        try overview.expect(&app);

        try applyOverviewTestLaneAction(&app, 1072, 416, .{ .project = "B", .action = .open_project });
        try expectOverviewSelection(&app, .project, "B", "b1");
        try std.testing.expect(!app.workspace_controls.panel_visible);
        var beta_canvas = OverviewAccessibilitySink{ .card_count = 2, .expected = &.{
            .{ .identity = "open-project:A" },
            .{ .identity = "open-project:B", .selected = true },
            .{ .identity = "project-card:B:b1", .selected = true },
            .{ .identity = "project-card:B:b2" },
        } };
        try beta_canvas.expect(&app);

        app.openGlobalOverview();
        try applyOverviewTestLaneAction(&app, 1072, 92, .{ .project = "A", .action = .open_project });
        try expectOverviewSelection(&app, .project, "A", "a1");
        var alpha_canvas = OverviewAccessibilitySink{ .card_count = 4, .expected = &.{
            .{ .identity = "open-project:A", .selected = true },
            .{ .identity = "open-project:B" },
            .{ .identity = "project-card:A:a1", .selected = true },
            .{ .identity = "project-card:A:a2" },
            .{ .identity = "project-card:A:a3" },
            .{ .identity = "project-card:A:a4" },
        } };
        try alpha_canvas.expect(&app);

        app.openGlobalOverview();
        try expectOverviewSelection(&app, .overview, "A", "a1");
        try overview.expect(&app);
        try std.testing.expect(app.workspace == null);
    }
}

test "cross-project overview preflight rejects wrong identities and geometry before dispatch" {
    var app = try overviewTestApp(96);
    defer deinitOverviewTestApp(&app);
    try loadOverviewTestGraphs(&app, "A", "B");
    app.openGlobalOverview();
    try expectOverviewSelection(&app, .overview, "A", "a1");
    try std.testing.expectError(error.UnexpectedOverviewTestTarget, overviewTestPreflight(&app, 1072, 416, .{
        .project = "A",
        .action = .open_project,
    }));
    try std.testing.expectError(error.UnexpectedOverviewTestTarget, overviewTestPreflight(&app, 1072, 416, .{
        .project = "B",
        .action = .inspect_worktrees,
    }));
    try std.testing.expectError(error.UnexpectedOverviewTestTarget, overviewTestPreflight(&app, 520, 450, .{
        .project = "B",
        .action = .open_project,
    }));
    try std.testing.expectError(error.UnsafeOverviewTestPoint, overviewTestPreflight(&app, 219, 450, .{
        .project = "B",
        .action = .open_project,
    }));
    try expectOverviewSelection(&app, .overview, "A", "a1");
    try std.testing.expect(!app.canvas.dragging);
}

test "cross-project overview refresh emits both projects without changing the selected loop" {
    var app = try overviewTestApp(96);
    defer deinitOverviewTestApp(&app);
    try loadOverviewTestGraphs(&app, "A", "B");
    try std.testing.expect(app.selectProject("B"));
    try std.testing.expect(app.selectNodeIndex(1));
    app.openGlobalOverview();
    _ = try app.model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":3,"event":{"graphChanged":{"id":"Overview Alpha","project":{"path":"A","name":"Overview Alpha"},"nodes":[{"id":"a4","title":"Alpha refreshed","loopType":"turnBased","state":"idle"},{"id":"a1","title":"Alpha 1","loopType":"turnBased","state":"idle"},{"id":"a2","title":"Alpha 2","loopType":"turnBased","state":"idle"},{"id":"a3","title":"Alpha 3","loopType":"turnBased","state":"idle"}],"edges":[]}}}
    );
    try expectOverviewSelection(&app, .overview, "B", "b2");
    var sink = OverviewAccessibilitySink{ .card_count = 6, .expected = &.{
        .{ .identity = "open-project:A" },
        .{ .identity = "open-project:B", .selected = true },
        .{ .identity = "overview-card:A:a4", .name = "Alpha refreshed", .bounds = .{ 262, 118, 482, 204 } },
        .{ .identity = "overview-card:A:a1", .name = "Alpha 1", .bounds = .{ 508, 118, 728, 204 } },
        .{ .identity = "overview-card:A:a2" },
        .{ .identity = "overview-card:A:a3" },
        .{ .identity = "overview-card:B:b1", .bounds = .{ 262, 442, 482, 528 } },
        .{ .identity = "overview-card:B:b2", .name = "Beta 2" },
    } };
    try sink.expect(&app);
}

fn setOverviewTestEnvironment(name: []const u8, value: ?[]const u8) !void {
    const key = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, name);
    defer std.testing.allocator.free(key);
    try setWorkspaceTestEnvironment(key.ptr, value);
}

const OverviewGitEnvironment = struct {
    previous: std.process.EnvMap,

    fn init(empty_config: []const u8) !@This() {
        var self = @This(){ .previous = try std.process.getEnvMap(std.testing.allocator) };
        errdefer self.deinit();
        var inherited = self.previous.iterator();
        while (inherited.next()) |entry| {
            if (std.ascii.startsWithIgnoreCase(entry.key_ptr.*, "GIT_"))
                try setOverviewTestEnvironment(entry.key_ptr.*, null);
        }
        try setOverviewTestEnvironment("GIT_CONFIG_SYSTEM", empty_config);
        try setOverviewTestEnvironment("GIT_CONFIG_GLOBAL", empty_config);
        try setOverviewTestEnvironment("GIT_CONFIG_NOSYSTEM", "1");
        try setOverviewTestEnvironment("GIT_TERMINAL_PROMPT", "0");
        return self;
    }

    fn deinit(self: *@This()) void {
        var current = std.process.getEnvMap(std.testing.allocator) catch @panic("Unable to read test Git environment");
        defer current.deinit();
        var installed = current.iterator();
        while (installed.next()) |entry| {
            if (std.ascii.startsWithIgnoreCase(entry.key_ptr.*, "GIT_"))
                setOverviewTestEnvironment(entry.key_ptr.*, null) catch @panic("Unable to clear test Git environment");
        }
        var previous = self.previous.iterator();
        while (previous.next()) |entry| {
            if (std.ascii.startsWithIgnoreCase(entry.key_ptr.*, "GIT_"))
                setOverviewTestEnvironment(entry.key_ptr.*, entry.value_ptr.*) catch @panic("Unable to restore Git environment");
        }
        self.previous.deinit();
    }
};

fn expectOverviewGitEnvironment(expected: *const std.process.EnvMap) !void {
    var actual = try std.process.getEnvMap(std.testing.allocator);
    defer actual.deinit();
    var count: usize = 0;
    var entries = actual.iterator();
    while (entries.next()) |entry| {
        if (!std.ascii.startsWithIgnoreCase(entry.key_ptr.*, "GIT_")) continue;
        count += 1;
        const value = expected.get(entry.key_ptr.*) orelse return error.UnexpectedGitEnvironmentKey;
        // Environment values can contain credentials; failed assertions must not print them.
        try std.testing.expect(std.mem.eql(u8, value, entry.value_ptr.*));
    }
    var expected_count: usize = 0;
    entries = expected.iterator();
    while (entries.next()) |entry| {
        if (std.ascii.startsWithIgnoreCase(entry.key_ptr.*, "GIT_")) expected_count += 1;
    }
    try std.testing.expectEqual(expected_count, count);
}

fn overviewGitEnvironmentErrorControl(empty_config: []const u8) !void {
    var isolated = try OverviewGitEnvironment.init(empty_config);
    defer isolated.deinit();
    return error.ExpectedOverviewFixtureFailure;
}

fn exerciseOverviewWorktreesFixture() !void {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    var directory_open = true;
    defer if (directory_open) temporary.dir.close();
    defer temporary.parent_dir.close();
    const root = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    errdefer std.debug.print("Failed overview Git fixture retained at: {s}\n", .{root});
    try temporary.dir.writeFile(.{ .sub_path = "empty-git.config", .data = "" });
    const empty_config = try std.fs.path.join(allocator, &.{ root, "empty-git.config" });
    defer allocator.free(empty_config);
    var git_environment = try OverviewGitEnvironment.init(empty_config);
    defer git_environment.deinit();
    const support_key = std.unicode.utf8ToUtf16LeStringLiteral("GRAPHCODE_SUPPORT_DIR");
    const gate_key = std.unicode.utf8ToUtf16LeStringLiteral("GRAPHCODE_UIA_GATE");
    const dialogs_key = std.unicode.utf8ToUtf16LeStringLiteral("GRAPHCODE_UIA_SHOW_DIALOGS");
    const prior_support = std.process.getEnvVarOwned(allocator, "GRAPHCODE_SUPPORT_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (prior_support) |value| allocator.free(value);
    const prior_gate = std.process.getEnvVarOwned(allocator, "GRAPHCODE_UIA_GATE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (prior_gate) |value| allocator.free(value);
    const prior_dialogs = std.process.getEnvVarOwned(allocator, "GRAPHCODE_UIA_SHOW_DIALOGS") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (prior_dialogs) |value| allocator.free(value);
    defer {
        setWorkspaceTestEnvironment(support_key, prior_support) catch @panic("Unable to restore test support directory");
        setWorkspaceTestEnvironment(gate_key, prior_gate) catch @panic("Unable to restore test UIA gate");
        setWorkspaceTestEnvironment(dialogs_key, prior_dialogs) catch @panic("Unable to restore test dialog setting");
    }
    try setWorkspaceTestEnvironment(support_key, root);
    try setWorkspaceTestEnvironment(gate_key, "1");
    try setWorkspaceTestEnvironment(dialogs_key, "0");
    const alpha = try std.fs.path.join(allocator, &.{ root, "alpha" });
    defer allocator.free(alpha);
    const beta = try std.fs.path.join(allocator, &.{ root, "beta" });
    defer allocator.free(beta);
    for ([_][]const u8{ alpha, beta }) |path| {
        const initialized = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "-c", "init.templateDir=", "init", "--quiet", "--initial-branch=main", path },
        });
        defer allocator.free(initialized.stdout);
        defer allocator.free(initialized.stderr);
        if (initialized.term != .Exited or initialized.term.Exited != 0) {
            std.debug.print("Git fixture initialization failed: {s}\n", .{initialized.stderr});
            return error.GitFixtureInitializationFailed;
        }
        const git_dir = try std.fs.path.join(allocator, &.{ path, ".git" });
        defer allocator.free(git_dir);
        var created = try std.fs.cwd().openDir(git_dir, .{});
        created.close();
        const resolved = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "-C", path, "rev-parse", "--absolute-git-dir", "--path-format=absolute", "--git-common-dir", "--show-toplevel" },
        });
        defer allocator.free(resolved.stdout);
        defer allocator.free(resolved.stderr);
        try std.testing.expect(resolved.term == .Exited and resolved.term.Exited == 0);
        const expected_roots = try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}\n", .{ git_dir, git_dir, path });
        defer allocator.free(expected_roots);
        for (expected_roots) |*byte| if (byte.* == '\\') {
            byte.* = '/';
        };
        try std.testing.expectEqualStrings(expected_roots, resolved.stdout);
    }
    try temporary.dir.writeFile(.{ .sub_path = "alpha\\sentinel.txt", .data = "alpha preserved" });
    try temporary.dir.writeFile(.{ .sub_path = "beta\\sentinel.txt", .data = "beta preserved" });
    for ([_]struct { path: []const u8, other: []const u8, y: i32, node: []const u8 }{
        .{ .path = beta, .other = alpha, .y = 416, .node = "b1" },
        .{ .path = alpha, .other = beta, .y = 92, .node = "a1" },
    }) |target| {
        var app = try overviewTestApp(96);
        defer deinitOverviewTestApp(&app);
        try loadOverviewTestGraphs(&app, alpha, beta);
        try std.testing.expect(app.selectProject(target.other));
        app.openGlobalOverview();
        try std.testing.expect(app.worktree_inspection == null and app.worktree_dialog == null);
        try applyOverviewTestLaneAction(&app, 1131, target.y, .{ .project = target.path, .action = .inspect_worktrees });
        try expectOverviewSelection(&app, .overview, target.path, target.node);
        const inspection = app.worktree_inspection orelse return error.MissingScopedInspection;
        const dialog = app.worktree_dialog orelse return error.MissingScopedWorktreeDialog;
        try std.testing.expectEqualStrings(target.path, inspection.project_path);
        try std.testing.expectEqualStrings(target.path, dialog.project_path);
        try std.testing.expectEqual(@as(usize, 1), inspection.entries.items.len);
        try std.testing.expectEqual(@as(usize, 1), dialog.rows.items.len);
        const expected_git_path = try allocator.dupe(u8, target.path);
        defer allocator.free(expected_git_path);
        for (expected_git_path) |*byte| if (byte.* == '\\') {
            byte.* = '/';
        };
        const entry = inspection.entries.items[0];
        try std.testing.expectEqualStrings(expected_git_path, entry.path);
        try std.testing.expectEqualStrings(expected_git_path, dialog.rows.items[0].entry.path);
        try std.testing.expect(entry.primary);
        try std.testing.expectEqual(WorktreeStatus.ReclaimDecision.keep, WorktreeStatus.decision(entry));
        try std.testing.expect(!WorktreeStatus.sweepSelectable(entry));
        const row_identity = try std.fmt.allocPrint(allocator, "worktree:{s}", .{expected_git_path});
        defer allocator.free(row_identity);
        const row_name = try WorktreeStatus.rowPresentation(allocator, entry);
        defer allocator.free(row_name);
        const project_identity = try std.fmt.allocPrint(allocator, "open-project:{s}", .{target.path});
        defer allocator.free(project_identity);
        const other_identity = try std.fmt.allocPrint(allocator, "open-project:{s}", .{target.other});
        defer allocator.free(other_identity);
        var sink = OverviewAccessibilitySink{ .card_count = 6, .expected = &.{
            .{ .identity = row_identity, .name = row_name },
            .{ .identity = project_identity, .selected = true },
            .{ .identity = other_identity },
        } };
        try sink.expect(&app);
    }
    const alpha_bytes = try temporary.dir.readFileAlloc(allocator, "alpha\\sentinel.txt", 100);
    defer allocator.free(alpha_bytes);
    const beta_bytes = try temporary.dir.readFileAlloc(allocator, "beta\\sentinel.txt", 100);
    defer allocator.free(beta_bytes);
    try std.testing.expectEqualStrings("alpha preserved", alpha_bytes);
    try std.testing.expectEqualStrings("beta preserved", beta_bytes);
    var alpha_hash: [32]u8 = undefined;
    var beta_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(alpha_bytes, &alpha_hash, .{});
    std.crypto.hash.sha2.Sha256.hash(beta_bytes, &beta_hash, .{});
    std.debug.print("Overview fixture verified before cleanup: {s} bytes=\"{s}\" sha256={s}; {s} bytes=\"{s}\" sha256={s}\n", .{
        alpha, alpha_bytes, std.fmt.bytesToHex(alpha_hash, .lower),
        beta,  beta_bytes,  std.fmt.bytesToHex(beta_hash, .lower),
    });
    temporary.dir.close();
    directory_open = false;
    try temporary.parent_dir.deleteTree(&temporary.sub_path);
    std.debug.print("Removed exact successful overview fixture: {s}\n", .{root});
}

test "cross-project overview Worktrees actions inspect the exact disposable Git project" {
    try exerciseOverviewWorktreesFixture();
}

test "cross-project overview Git redirection cannot escape owned fixture roots" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    var directory_open = true;
    defer if (directory_open) temporary.dir.close();
    defer temporary.parent_dir.close();
    const root = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    errdefer std.debug.print("Failed overview outside-control fixture retained at: {s}\n", .{root});
    try temporary.dir.writeFile(.{ .sub_path = "empty-git.config", .data = "" });
    const empty_config = try std.fs.path.join(allocator, &.{ root, "empty-git.config" });
    defer allocator.free(empty_config);
    var outer_environment = try OverviewGitEnvironment.init(empty_config);
    defer outer_environment.deinit();
    const outside = try std.fs.path.join(allocator, &.{ root, "outside" });
    defer allocator.free(outside);
    const outside_git = try std.fs.path.join(allocator, &.{ outside, ".git" });
    defer allocator.free(outside_git);
    const initialized = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "-c", "init.templateDir=", "init", "--quiet", "--initial-branch=outside-control", outside },
    });
    defer allocator.free(initialized.stdout);
    defer allocator.free(initialized.stderr);
    try std.testing.expect(initialized.term == .Exited and initialized.term.Exited == 0);
    try temporary.dir.writeFile(.{ .sub_path = "outside\\sentinel.txt", .data = "outside must stay untouched" });
    try temporary.dir.writeFile(.{ .sub_path = "outside\\trace.log", .data = "not a fixture trace channel" });
    const paths = [_][]const u8{ "outside\\.git\\HEAD", "outside\\.git\\config", "outside\\sentinel.txt", "outside\\trace.log" };
    var before: [paths.len][]u8 = @splat(&.{});
    defer for (before) |bytes| allocator.free(bytes);
    for (paths, 0..) |path, index| before[index] = try temporary.dir.readFileAlloc(allocator, path, 4096);

    for ([_]bool{ false, true }) |multiple_redirects| {
        try setOverviewTestEnvironment("GIT_DIR", outside_git);
        if (multiple_redirects) {
            for ([_][]const u8{
                "GIT_WORK_TREE",        "GIT_COMMON_DIR",                   "GIT_INDEX_FILE",
                "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE",
                "GIT_SHALLOW_FILE",     "GIT_CEILING_DIRECTORIES",          "GIT_EXEC_PATH",
                "GIT_TEMPLATE_DIR",     "GIT_FUTURE_REDIRECTION_CONTROL",
            }) |key| try setOverviewTestEnvironment(key, outside);
            const trace = try std.fs.path.join(allocator, &.{ outside, "trace.log" });
            defer allocator.free(trace);
            try setOverviewTestEnvironment("GIT_TRACE2_EVENT", trace);
            try setOverviewTestEnvironment("GIT_CONFIG_COUNT", "1");
            try setOverviewTestEnvironment("GIT_CONFIG_KEY_0", "init.defaultObjectFormat");
            try setOverviewTestEnvironment("GIT_CONFIG_VALUE_0", "invalid-overview-format");
        }
        var expected = try std.process.getEnvMap(allocator);
        defer expected.deinit();
        try std.testing.expectError(error.ExpectedOverviewFixtureFailure, overviewGitEnvironmentErrorControl(empty_config));
        try expectOverviewGitEnvironment(&expected);
        const fixture_result = exerciseOverviewWorktreesFixture();
        try expectOverviewGitEnvironment(&expected);
        for (paths, before) |path, original| {
            const after = try temporary.dir.readFileAlloc(allocator, path, 4096);
            defer allocator.free(after);
            try std.testing.expectEqualSlices(u8, original, after);
        }
        try fixture_result;
    }
    std.debug.print("Overview Git redirection controls preserved outside HEAD/config/sentinels and restored success/error environments\n", .{});
    temporary.dir.close();
    directory_open = false;
    try temporary.parent_dir.deleteTree(&temporary.sub_path);
    std.debug.print("Removed exact successful overview outside-control fixture: {s}\n", .{root});
}

test "DPI gesture mapper classifies scaled sidebar and graph boundaries" {
    const controls = WorkspaceControls.State{ .rail_visible = true, .panel_visible = true, .activity_enabled = false };
    const cases = [_]struct { dpi: u32, width: i32, height: i32, sidebar_x: i32, canvas_x: i32, top: i32, bottom: i32, y: i32 }{
        .{ .dpi = 96, .width = 1200, .height = 900, .sidebar_x = 200, .canvas_x = 600, .top = 34, .bottom = 650, .y = 300 },
        .{ .dpi = 144, .width = 1800, .height = 1350, .sidebar_x = 300, .canvas_x = 900, .top = 51, .bottom = 975, .y = 450 },
        .{ .dpi = 192, .width = 2400, .height = 1800, .sidebar_x = 400, .canvas_x = 1200, .top = 68, .bottom = 1300, .y = 600 },
    };
    for (cases) |case| {
        const client = c.RECT{ .left = 0, .top = 0, .right = case.width, .bottom = case.height };
        for ([_]struct { point: c.POINT, region: WheelRegion }{
            .{ .point = .{ .x = case.sidebar_x, .y = case.y }, .region = .sidebar },
            .{ .point = .{ .x = case.canvas_x, .y = case.y }, .region = .canvas },
            .{ .point = .{ .x = case.canvas_x, .y = case.top }, .region = .canvas },
            .{ .point = .{ .x = case.canvas_x, .y = case.top - 2 }, .region = .none },
            .{ .point = .{ .x = case.width, .y = case.y }, .region = .none },
            .{ .point = .{ .x = case.canvas_x, .y = case.bottom }, .region = .none },
        }) |sample| {
            const mapped = gestureGeometry(sample.point, client, case.dpi, controls);
            try std.testing.expectEqual(sample.region, wheelRegion(mapped.point.?.x, mapped.point.?.y, mapped.bounds, controls));
            try std.testing.expectEqual(sample.region == .canvas, gestureInCanvas(.project, mapped.point, mapped.bounds, controls));
            try std.testing.expect(!gestureInCanvas(.workspace, mapped.point, mapped.bounds, controls));
        }
        const failed = gestureGeometry(null, client, case.dpi, controls);
        try std.testing.expect(!gestureInCanvas(.project, failed.point, failed.bounds, controls));
    }
}

test "DPI gesture mapper preserves the logical world anchor through pinch updates" {
    for ([_]struct { dpi: u32, point: c.POINT, width: i32, height: i32 }{
        .{ .dpi = 96, .point = .{ .x = 600, .y = 300 }, .width = 1200, .height = 900 },
        .{ .dpi = 144, .point = .{ .x = 900, .y = 450 }, .width = 1800, .height = 1350 },
        .{ .dpi = 192, .point = .{ .x = 1200, .y = 600 }, .width = 2400, .height = 1800 },
    }) |case| {
        const mapped = gestureGeometry(case.point, .{ .left = 0, .top = 0, .right = case.width, .bottom = case.height }, case.dpi, .{});
        var state = GraphCanvas.CanvasState{ .zoom = 1.2, .pan_x = 24, .pan_y = -36 };
        state.beginPinchZoom(100, 7);
        for ([_]u32{ 125, 125, 10000, 50 }) |distance| {
            state.continuePinchZoom(mapped.point.?.x, mapped.point.?.y, distance, 7);
            try std.testing.expectApproxEqAbs(@as(f32, 480), (600 - state.pan_x) / state.zoom, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 280), (300 - state.pan_y) / state.zoom, 0.001);
        }
    }
}

test "jump matching ranks exact results across projects" {
    var model = GraphModel.Model.init(std.testing.allocator);
    defer model.deinit();
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"a","project":{"path":"A","name":"Alpha"},"nodes":[{"id":"loop-a","title":"Fix authentication","state":"running"}],"edges":[]}}}
    );
    _ = try model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"id":"b","project":{"path":"B","name":"Beta"},"nodes":[{"id":"loop-b","title":"Authentication audit","state":"idle"},{"id":"auth","title":"Unrelated","state":"idle"}],"edges":[]}}}
    );

    const exact_id = findJumpMatch(&model, "AUTH").?;
    try std.testing.expectEqual(@as(usize, 1), exact_id.project_index);
    try std.testing.expectEqual(@as(usize, 1), exact_id.node_index);
    try std.testing.expectEqual(@as(u8, 0), exact_id.score);

    const prefix = findJumpMatch(&model, "authentication").?;
    try std.testing.expectEqual(@as(usize, 1), prefix.project_index);
    try std.testing.expectEqual(@as(usize, 0), prefix.node_index);
    try std.testing.expectEqual(@as(u8, 2), prefix.score);
}

test "node form validation errors keep the validation status" {
    try std.testing.expectEqualStrings(
        "Invalid node form",
        App.nodeFormErrorStatus(error.MissingFirstInstruction),
    );
    try std.testing.expectEqualStrings(
        "Invalid node form",
        App.nodeFormErrorStatus(error.TooManyAttachments),
    );
    try std.testing.expectEqualStrings(
        "Unable to open node form",
        App.nodeFormErrorStatus(error.FormCreationFailed),
    );
}

fn nodeSubmissionTestApp(allocator: std.mem.Allocator) !App {
    return .{
        .allocator = allocator,
        .client = .{ .allocator = allocator, .frame_buffer = try @import("FrameBuffer.zig").FrameBuffer.init(allocator, .v2) },
        .daemon = undefined,
        .model = GraphModel.Model.init(allocator),
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
    };
}

const custody_parent_id = "11111111-1111-4111-8111-111111111111";
const custody_group_id = "22222222-2222-4222-8222-222222222222";
const custody_graph_a =
    \\{"event":{"graphChanged":{"project":{"path":"A","name":"Alpha"},"nodes":[{"id":"11111111-1111-4111-8111-111111111111","title":"Parent A","loopType":"turnBased","backend":"claudeCode","state":"running"}],"edges":[]}}}
;
const custody_graph_b =
    \\{"event":{"graphChanged":{"project":{"path":"B","name":"Beta"},"nodes":[{"id":"11111111-1111-4111-8111-111111111111","title":"Parent B","loopType":"sketch","backend":"copilotCLI","state":"idle"},{"id":"22222222-2222-4222-8222-222222222222","title":"Group","loopType":"composite","backend":"claudeCode","state":"idle","subGraph":{"nodes":[{"id":"11111111-1111-4111-8111-111111111111","title":"Nested parent","loopType":"goalBased","backend":"codex","state":"running"}],"edges":[]}}],"edges":[]}}}
;

fn custodyTestApp() !App {
    var app = try nodeSubmissionTestApp(std.testing.allocator);
    errdefer deinitNodeSubmissionTestApp(&app);
    _ = try app.model.updateFromFrame(custody_graph_a);
    _ = try app.model.updateFromFrame(custody_graph_b);
    app.product_settings = try ProductSettings.Settings.init(std.testing.allocator);
    return app;
}

fn deinitCustodyTestApp(app: *App) void {
    if (app.product_settings) |*settings| settings.deinit();
    app.clearSelection();
    deinitNodeSubmissionTestApp(app);
}

test "custody child capture owns clicked root B without selecting it or copying its type" {
    var app = try custodyTestApp();
    defer deinitCustodyTestApp(&app);
    try std.testing.expect(app.selectProject("A"));
    app.client.setSubscription("A");
    var child = try app.captureChildNodeCreation("B", null, custody_parent_id);
    defer child.deinit();
    try std.testing.expectEqualStrings("A", app.model.selected_project_path.?);
    try std.testing.expectEqualStrings("B", child.context.project_path);
    try std.testing.expect(child.context.origin == .loaded);
    try std.testing.expect(child.context.composite_id == null);
    try std.testing.expectEqualStrings(custody_parent_id, child.initial.created_by);
    try std.testing.expectEqualStrings("copilotCLI", child.initial.backend.?);
    try std.testing.expectEqualStrings("turnBased", child.initial.loop_type);
    try std.testing.expectEqualStrings("", child.initial.title);
    try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
    try app.prepareChildNodeCreation(&child);
    try app.validateNodeCreationContext(&child.context);
    try std.testing.expectEqualStrings("B", app.model.selected_project_path.?);
    try std.testing.expectEqualStrings(custody_parent_id, app.model.selected_node_id.?);
    try std.testing.expectEqualStrings("A", app.client.subscription_path);
    app.client.sendCreateNodeDraft(child.context.project_path, child.initial);
    try std.testing.expectEqual(@as(usize, 1), app.client.outbound_count);
    const command = app.client.outbound[app.client.outbound_head];
    try std.testing.expect(std.mem.indexOf(u8, command, "\"projectPath\":\"B\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "\"createdBy\":\"" ++ custody_parent_id ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "\"backend\":\"copilotCLI\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "\"subGraphCommand\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, command, "\"createEdge\"") == null);
}

fn custodyPopupWithoutSettingsCase(resolved: bool) !void {
    var app = try custodyTestApp();
    defer deinitCustodyTestApp(&app);
    app.product_settings.?.deinit();
    app.product_settings = null;
    if (resolved) try custodyReplaceParentField(&app, .state, "succeeded");
    var menu = try app.prepareNodeMenu("B", null, custody_parent_id, false);
    defer menu.deinit();
    try std.testing.expectEqualStrings("B", menu.target.project_path);
    try std.testing.expectEqualStrings(custody_parent_id, menu.target.id);
    try std.testing.expectEqual(resolved, menu.target.resolved);
    try std.testing.expect(menu.child == null);
    if (resolved)
        try std.testing.expect(menu.child_error == null)
    else
        try std.testing.expectEqual(error.NodeCreationSettingsUnavailable, menu.child_error.?);
    try std.testing.expectError(
        if (resolved) error.NodeCreationParentResolved else error.NodeCreationSettingsUnavailable,
        menu.childForCreation(),
    );
    try custodyExpectExistingMenuActions(menu.target);
    try std.testing.expectEqualStrings("A", app.model.selected_project_path.?);
    try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
}

fn custodyExpectExistingMenuActions(target: GraphContextMenu.NodeTarget) !void {
    const plan = GraphContextMenu.nodeMenuPlan(target);
    for ([_]usize{ 5104, 5101, 5103, 5102 }) |id| {
        var found = false;
        for (plan.items[0..plan.len]) |item| {
            if (item.id == id) {
                found = true;
                try std.testing.expect(item.enabled);
            }
        }
        try std.testing.expectEqual(id != 5102 or !target.resolved, found);
    }
    if (GraphContextMenu.newChildNodeMenuItem(target)) |item| {
        try std.testing.expect(!target.resolved);
        try std.testing.expectEqual(target.can_create_child, item.enabled);
    } else try std.testing.expect(target.resolved);
}

test "custody child popup existing actions survive missing settings for unresolved nodes" {
    try custodyPopupWithoutSettingsCase(false);
}

test "custody child popup existing actions survive missing settings for resolved nodes" {
    try custodyPopupWithoutSettingsCase(true);
}

test "custody child popup owns generic and optional child data through parent and settings loss" {
    for ([_]bool{ false, true }) |settings_available| {
        for ([_]bool{ false, true }) |resolved| {
            var app = try custodyTestApp();
            defer deinitCustodyTestApp(&app);
            if (resolved) try custodyReplaceParentField(&app, .state, "succeeded");
            if (!settings_available) {
                app.product_settings.?.deinit();
                app.product_settings = null;
            }
            var menu = try app.prepareNodeMenu("B", null, custody_parent_id, false);
            defer menu.deinit();
            const node = app.model.graphFor("B").?.nodes.items[0];
            try std.testing.expect(menu.target.id.ptr != node.id.ptr);
            try std.testing.expect(menu.target.project_path.ptr != app.model.graphFor("B").?.project.path.ptr);
            try std.testing.expectEqual(settings_available and !resolved, menu.child != null);
            try std.testing.expectEqual(settings_available and !resolved, menu.target.can_create_child);
            if (app.product_settings) |*settings| settings.deinit();
            app.product_settings = null;
            try std.testing.expect(app.model.applyLifecycle(.close, "B"));
            try std.testing.expectEqualStrings("B", menu.target.project_path);
            try std.testing.expectEqualStrings(custody_parent_id, menu.target.id);
            try custodyExpectExistingMenuActions(menu.target);
            if (menu.child) |*child| {
                try std.testing.expectEqualStrings("copilotCLI", child.initial.backend.?);
                try std.testing.expectEqualStrings("standard", child.initial.model_tier);
                try std.testing.expectError(error.NodeCreationProjectClosed, app.prepareChildNodeCreation(child));
            }
            try std.testing.expectEqualStrings("A", app.model.selected_project_path.?);
            try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
        }
    }
}

fn custodyPopupAllocationCase(allocator: std.mem.Allocator, settings_available: bool, resolved: bool) !void {
    var app = try custodyTestApp();
    defer deinitCustodyTestApp(&app);
    try custodyAddInspection(&app, "B");
    if (resolved) try custodyReplaceParentField(&app, .state, "succeeded");
    if (!settings_available) {
        app.product_settings.?.deinit();
        app.product_settings = null;
    }
    app.allocator = allocator;
    defer app.allocator = std.testing.allocator;
    var menu = app.prepareNodeMenu("B", null, custody_parent_id, false) catch |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqualStrings("A", app.model.selected_project_path.?);
        try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
        return err;
    };
    defer menu.deinit();
    try custodyExpectExistingMenuActions(menu.target);
    try std.testing.expectEqualStrings("B", menu.target.project_path);
    try std.testing.expectEqualStrings(custody_parent_id, menu.target.id);
    try std.testing.expectEqualStrings("A", app.model.selected_project_path.?);
    try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
    if (menu.child_error) |err| if (err == error.OutOfMemory) {
        try std.testing.expect(menu.child == null);
        try std.testing.expect(!menu.target.can_create_child);
        try std.testing.expectError(error.OutOfMemory, menu.childForCreation());
        return error.OutOfMemory;
    };
    if (menu.promotion_error) |err| if (err == error.OutOfMemory) {
        try std.testing.expect(menu.popupTarget().promotion_context == null);
        return error.OutOfMemory;
    };
    try std.testing.expectEqual(settings_available and !resolved, menu.child != null);
    if (resolved) try std.testing.expect(menu.child_error == null);
}

test "custody child popup optional snapshot allocation failures preserve generic actions" {
    for ([_]bool{ false, true }) |settings_available| {
        for ([_]bool{ false, true }) |resolved|
            try std.testing.checkAllAllocationFailures(std.testing.allocator, custodyPopupAllocationCase, .{ settings_available, resolved });
    }
}

test "custody child combined popup binds moved promotion storage and retains both owned captures" {
    const allocator = std.testing.allocator;
    for ([_][2]bool{ .{ false, false }, .{ true, false }, .{ false, true }, .{ true, true } }) |scenario| {
        const promote = scenario[0];
        const root_from_composite = scenario[1];
        var app = try custodyTestApp();
        defer deinitCustodyTestApp(&app);
        const noted = try std.mem.replaceOwned(u8, allocator, custody_graph_b, "\"title\":\"Parent B\"", "\"title\":\"Parent B\",\"firstInstruction\":\"Captured note\"");
        defer allocator.free(noted);
        _ = try app.model.updateFromFrame(noted);
        app.client.setSubscription("A");
        if (root_from_composite) {
            try std.testing.expect(app.selectProject("B"));
            try std.testing.expect(app.model.openComposite(custody_group_id));
            app.client.setSubgraphAddress(custody_group_id);
        }
        var source: ?App.NodeMenuPreparation = try app.prepareNodeMenu("B", null, custody_parent_id, false);
        const old_address = @intFromPtr(&source.?.promotion.?);
        var moved = source.?;
        source = null;
        defer moved.deinit();
        try std.testing.expect(moved.target.promotion_context == null);
        const target = moved.popupTarget();
        try std.testing.expect(@intFromPtr(target.promotion_context.?) != old_address);
        try std.testing.expectEqual(&moved.promotion.?, target.promotion_context.?);
        try std.testing.expect(target.can_create_child and GraphContextMenu.promotionEnabled(target));
        _ = try app.model.updateFromFrame(custody_graph_b);
        app.product_settings.?.deinit();
        app.product_settings = null;
        try std.testing.expectEqualStrings("Captured note", target.promotion_context.?.first_instruction);
        try std.testing.expectEqualStrings("copilotCLI", moved.child.?.initial.backend.?);
        try std.testing.expect(!try app.prepareSketchPromotion(target.promotion_context.?.*, null));
        try std.testing.expectEqualStrings(if (root_from_composite) "B" else "A", app.model.selected_project_path.?);
        try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
        if (promote) {
            try std.testing.expect(try app.prepareSketchPromotion(target.promotion_context.?.*, .goal));
            try std.testing.expect(try app.client.sendSketchPromotion(&app.model, target.promotion_context.?.*, .{ .goal = "Finished" }));
        } else {
            try app.prepareChildNodeCreation(try moved.childForCreation());
            try app.validateNodeCreationContext(&moved.child.?.context);
            app.client.sendCreateNodeDraft(moved.child.?.context.project_path, moved.child.?.initial);
        }
        try std.testing.expectEqual(@as(usize, 1), app.client.outbound_count);
        try std.testing.expectEqualStrings("", app.client.subgraph_node_id);
        const command = app.client.outbound[app.client.outbound_head];
        try std.testing.expect(std.mem.indexOf(u8, command, "\"projectPath\":\"B\"") != null);
        try std.testing.expectEqual(promote, std.mem.indexOf(u8, command, "\"promoteNode\"") != null);
        try std.testing.expectEqual(!promote, std.mem.indexOf(u8, command, "\"createNode\"") != null);
        try std.testing.expectEqualStrings("A", app.client.subscription_path);
    }
}

test "custody child combined popup preserves independent stale guards and unavailable status" {
    var app = try custodyTestApp();
    defer deinitCustodyTestApp(&app);
    try std.testing.expect(app.selectProject("B"));
    var menu = try app.prepareNodeMenu("B", null, custody_parent_id, false);
    defer menu.deinit();
    const target = menu.popupTarget();
    try std.testing.expect(app.model.setSelectedIndex(1));
    try std.testing.expectError(error.PromotionContextChanged, app.prepareSketchPromotion(target.promotion_context.?.*, .goal));
    try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
    try custodyReplaceParentField(&app, .state, "stopped");
    try std.testing.expectError(error.NodeCreationParentResolved, app.prepareChildNodeCreation(try menu.childForCreation()));
    app.client.setSubgraphAddress(custody_group_id);
    var unavailable = try app.prepareNodeMenu("B", null, custody_parent_id, false);
    defer unavailable.deinit();
    try std.testing.expectEqualStrings("Sketch promotion is unavailable in this graph context.", unavailable.promotionContextStatus().?);
    try std.testing.expect(!GraphContextMenu.promotionEnabled(unavailable.popupTarget()));
    try custodyExpectExistingMenuActions(unavailable.popupTarget());
    try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
}

const CustodyOneFailureAllocator = struct {
    failing: std.testing.FailingAllocator,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const result = self.failing.allocator().rawAlloc(len, alignment, ra);
        if (result == null and self.failing.has_induced_failure) self.failing.fail_index = std.math.maxInt(usize);
        return result;
    }

    fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return self.failing.allocator().rawResize(memory, alignment, len, ra);
    }

    fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return self.failing.allocator().rawRemap(memory, alignment, len, ra);
    }

    fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.failing.allocator().rawFree(memory, alignment, ra);
    }
};

test "custody child combined popup isolates each optional allocation failure from the other feature" {
    var child_only_failed = false;
    var promotion_only_failed = false;
    var generic_failed = false;
    var finished = false;
    for (0..128) |fail_index| {
        var app = try custodyTestApp();
        defer deinitCustodyTestApp(&app);
        var failing = CustodyOneFailureAllocator{ .failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index }) };
        app.allocator = failing.allocator();
        defer app.allocator = std.testing.allocator;
        const captured = app.prepareNodeMenu("B", null, custody_parent_id, false);
        if (captured) |value| {
            var menu = value;
            defer menu.deinit();
            const target = menu.popupTarget();
            try custodyExpectExistingMenuActions(target);
            if (menu.child_error) |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expect(menu.child == null);
                try std.testing.expect(GraphContextMenu.promotionEnabled(target));
                child_only_failed = true;
            }
            if (menu.promotion_error) |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expect(menu.promotion == null);
                try std.testing.expect(target.can_create_child);
                try std.testing.expectEqualStrings(custody_parent_id, (try menu.childForCreation()).initial.created_by);
                promotion_only_failed = true;
            }
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            generic_failed = true;
        }
        try std.testing.expectEqual(failing.failing.allocated_bytes, failing.failing.freed_bytes);
        try std.testing.expectEqualStrings("A", app.model.selected_project_path.?);
        try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
        if (!failing.failing.has_induced_failure) {
            finished = true;
            break;
        }
    }
    try std.testing.expect(finished and generic_failed and child_only_failed and promotion_only_failed);
}

test "custody child distinguishes nested and root parents with identical IDs" {
    for ([_]bool{ false, true }) |root_target| {
        var app = try custodyTestApp();
        defer deinitCustodyTestApp(&app);
        try std.testing.expect(app.selectProject("B"));
        try std.testing.expect(app.model.openComposite(custody_group_id));
        app.client.setSubgraphAddress(custody_group_id);
        var child = try app.captureChildNodeCreation("B", if (root_target) null else custody_group_id, custody_parent_id);
        defer child.deinit();
        try std.testing.expectEqualStrings(if (root_target) "copilotCLI" else "codex", child.initial.backend.?);
        try app.prepareChildNodeCreation(&child);
        try app.validateNodeCreationContext(&child.context);
        try std.testing.expectEqualStrings(if (root_target) "" else custody_group_id, app.client.subgraph_node_id);
        app.client.sendCreateNodeDraft(child.context.project_path, child.initial);
        try std.testing.expectEqual(@as(usize, 1), app.client.outbound_count);
        const command = app.client.outbound[app.client.outbound_head];
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, command, .{});
        defer parsed.deinit();
        const graph = parsed.value.object.get("graphCommand").?.object;
        try std.testing.expectEqualStrings("B", graph.get("projectPath").?.string);
        var node_command = graph.get("command").?.object;
        if (!root_target) {
            const addressed = node_command.get("subGraphCommand").?.object;
            try std.testing.expectEqualStrings(custody_group_id, addressed.get("nodeID").?.string);
            node_command = addressed.get("command").?.object;
        }
        try std.testing.expectEqual(@as(usize, 1), node_command.count());
        const draft = node_command.get("createNode").?.object.get("_0").?.object;
        try std.testing.expectEqualStrings(custody_parent_id, draft.get("createdBy").?.string);
        try std.testing.expectEqualStrings(if (root_target) "copilotCLI" else "codex", draft.get("backend").?.string);
        try std.testing.expect(Forms.isUuid(draft.get("id").?.string));
        try std.testing.expect(draft.get("subGraph").? == .null);
    }
}

test "custody child popup context changes fail before selection and never rescue the target" {
    const Change = enum { project, composite, client, surface };
    for (std.enums.values(Change)) |change| {
        var app = try custodyTestApp();
        defer deinitCustodyTestApp(&app);
        try std.testing.expect(app.selectProject("B"));
        var child = try app.captureChildNodeCreation("A", null, custody_parent_id);
        defer child.deinit();
        switch (change) {
            .project => try std.testing.expect(app.selectProject("A")),
            .composite => try std.testing.expect(app.model.openComposite(custody_group_id)),
            .client => app.client.setSubgraphAddress(custody_group_id),
            .surface => app.surface = .overview,
        }
        try std.testing.expectError(error.NodeCreationPopupChanged, app.prepareChildNodeCreation(&child));
        try std.testing.expectEqualStrings(if (change == .project) "A" else "B", app.model.selected_project_path.?);
        try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
    }
}

fn custodyReplaceParentField(app: *App, field: enum { backend, loop_type, state }, value: []const u8) !void {
    const graph = app.model.graphFor("B").?;
    const node = &app.model.graphs.items[1].nodes.items[GraphModel.findNodeIndexByID(graph.nodes.items, custody_parent_id).?];
    const destination = switch (field) {
        .backend => &node.backend,
        .loop_type => &node.loop_type,
        .state => &node.state,
    };
    const replacement = try app.allocator.dupe(u8, value);
    app.allocator.free(destination.*);
    destination.* = replacement;
}

test "custody child rejects parent changes both before selection and at the final guard" {
    const Change = enum { deleted, closed, resolved, backend, loop_type };
    for ([_]bool{ false, true }) |prepared| {
        for (std.enums.values(Change)) |change| {
            var app = try custodyTestApp();
            defer deinitCustodyTestApp(&app);
            try std.testing.expect(app.selectProject("A"));
            var child = try app.captureChildNodeCreation("B", null, custody_parent_id);
            defer child.deinit();
            if (prepared) try app.prepareChildNodeCreation(&child);
            switch (change) {
                .deleted => _ = try app.model.updateFromFrame(
                    \\{"event":{"graphChanged":{"project":{"path":"B","name":"Beta"},"nodes":[],"edges":[]}}}
                ),
                .closed => try std.testing.expect(app.model.applyLifecycle(.close, "B")),
                .resolved => try custodyReplaceParentField(&app, .state, "succeeded"),
                .backend => try custodyReplaceParentField(&app, .backend, "claudeCode"),
                .loop_type => try custodyReplaceParentField(&app, .loop_type, "turnBased"),
            }
            const expected: anyerror = switch (change) {
                .deleted => error.NodeCreationParentMissing,
                .closed => error.NodeCreationProjectClosed,
                .resolved => error.NodeCreationParentResolved,
                .backend => error.NodeCreationParentBackendChanged,
                .loop_type => error.NodeCreationParentTypeChanged,
            };
            if (prepared) {
                const guard = App.NodeCreationValidation{ .app = &app, .context = &child.context };
                try std.testing.expectError(expected, App.NodeCreationValidation.check(&guard));
            } else {
                try std.testing.expectError(expected, app.prepareChildNodeCreation(&child));
                try std.testing.expectEqualStrings("A", app.model.selected_project_path.?);
            }
            try std.testing.expectEqualStrings("B", child.context.project_path);
            try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
        }
    }
}

test "custody child resolved snapshots remain ineligible even if the live parent reopens" {
    for ([_][]const u8{ "succeeded", "failed", "stalled", "stopped" }) |state| {
        var app = try custodyTestApp();
        defer deinitCustodyTestApp(&app);
        try custodyReplaceParentField(&app, .state, state);
        var child = try app.captureChildNodeCreation("B", null, custody_parent_id);
        defer child.deinit();
        try custodyReplaceParentField(&app, .state, "running");
        try std.testing.expectError(error.NodeCreationParentResolved, app.prepareChildNodeCreation(&child));
        try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
    }
}

test "custody child permits rename reorder and unresolved progress without retargeting" {
    var app = try custodyTestApp();
    defer deinitCustodyTestApp(&app);
    try std.testing.expect(app.selectProject("A"));
    var child = try app.captureChildNodeCreation("B", null, custody_parent_id);
    defer child.deinit();
    const refresh =
        \\{"event":{"graphChanged":{"project":{"path":"B","name":"Renamed project"},"nodes":[{"id":"33333333-3333-4333-8333-333333333333","title":"New first","loopType":"turnBased","backend":"claudeCode","state":"running"},{"id":"11111111-1111-4111-8111-111111111111","title":"Renamed parent","loopType":"sketch","backend":"copilotCLI","state":"running"}],"edges":[]}}}
    ;
    _ = try app.model.updateFromFrame(refresh);
    try app.prepareChildNodeCreation(&child);
    try std.testing.expectEqual(@as(?usize, 1), app.model.selected_index);
    _ = try app.model.updateFromFrame(refresh);
    try app.validateNodeCreationContext(&child.context);
    try std.testing.expectEqualStrings(custody_parent_id, child.initial.created_by);
    try std.testing.expectEqualStrings("idle", child.context.parent.?.state);
}

test "custody child final guards reject foreign same IDs and actual command scope drift" {
    const Change = enum { project, client, composite, deleted_composite };
    for (std.enums.values(Change)) |change| {
        var app = try custodyTestApp();
        defer deinitCustodyTestApp(&app);
        try std.testing.expect(app.selectProject("B"));
        try std.testing.expect(app.model.openComposite(custody_group_id));
        app.client.setSubgraphAddress(custody_group_id);
        var child = try app.captureChildNodeCreation("B", custody_group_id, custody_parent_id);
        defer child.deinit();
        try app.prepareChildNodeCreation(&child);
        switch (change) {
            .project => try std.testing.expect(app.selectProject("A")),
            .client => app.client.setSubgraphAddress(null),
            .composite => app.model.closeComposite(),
            .deleted_composite => _ = try app.model.updateFromFrame(
                \\{"event":{"graphChanged":{"project":{"path":"B","name":"Beta"},"nodes":[{"id":"11111111-1111-4111-8111-111111111111","title":"Root decoy","loopType":"goalBased","backend":"codex","state":"running"}],"edges":[]}}}
            ),
        }
        try std.testing.expectError(
            if (change == .project) error.NodeCreationProjectChanged else error.NodeCreationCompositeChanged,
            app.validateNodeCreationContext(&child.context),
        );
        try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
        try std.testing.expectEqualStrings("B", child.context.project_path);
    }
}

fn custodyAddInspection(app: *App, path: []const u8) !void {
    app.worktree_inspection = .{
        .entries = std.array_list.Managed(WorktreeStatus.Entry).init(app.allocator),
        .default_branch = try app.allocator.dupe(u8, "main"),
        .project_path = try app.allocator.dupe(u8, path),
    };
    try app.worktree_inspection.?.entries.append(.{
        .path = try app.allocator.dupe(u8, "B\\worktree"),
        .branch = try app.allocator.dupe(u8, "main"),
    });
}

test "custody child owns exact-project worktree choices and settings across replacement" {
    var app = try custodyTestApp();
    defer deinitCustodyTestApp(&app);
    try custodyAddInspection(&app, "A");
    var foreign = try app.captureChildNodeCreation("B", null, custody_parent_id);
    defer foreign.deinit();
    try std.testing.expectEqual(@as(usize, 0), foreign.choices.len);
    WorktreeStatus.deinitInspection(app.allocator, &app.worktree_inspection.?);
    app.worktree_inspection = null;
    try custodyAddInspection(&app, "B");
    var child = try app.captureChildNodeCreation("B", null, custody_parent_id);
    defer child.deinit();
    WorktreeStatus.deinitInspection(app.allocator, &app.worktree_inspection.?);
    app.worktree_inspection = null;
    app.product_settings.?.deinit();
    app.product_settings = null;
    _ = try app.model.updateFromFrame(custody_graph_b);
    try std.testing.expectEqualStrings("B\\worktree", child.choices[0].path);
    try std.testing.expectEqualStrings("main", child.choices[0].branch);
    try std.testing.expect(child.choices[0].is_default);
    try std.testing.expectEqualStrings("standard", child.initial.model_tier);
    try std.testing.expectEqualStrings("auto", child.initial.claude_permissions);
    try std.testing.expectEqualStrings("allowEverything", child.initial.copilot_permissions);
    try app.prepareChildNodeCreation(&child);
}

test "custody child cannot capture a recent inspection or global fallback parent" {
    var app = try nodeSubmissionTestApp(std.testing.allocator);
    defer deinitNodeSubmissionTestApp(&app);
    app.surface = .overview;
    try custodyAddInspection(&app, "B");
    _ = try app.model.updateFromFrame(
        \\{"event":{"recentProjectsListed":[{"path":"B","name":"Beta"}]}}
    );
    try std.testing.expectError(error.NodeCreationProjectClosed, app.captureChildNodeCreation("B", null, custody_parent_id));
    try std.testing.expectError(error.NodeCreationProjectClosed, app.captureChildNodeCreation("graphcode://global", null, custody_parent_id));
    try std.testing.expect(app.model.selected_project_path == null);
    try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
}

fn custodyCaptureAllocationCase(allocator: std.mem.Allocator) !void {
    var app = try custodyTestApp();
    defer deinitCustodyTestApp(&app);
    try custodyAddInspection(&app, "B");
    try std.testing.expect(app.selectProject("B"));
    try std.testing.expect(app.model.openComposite(custody_group_id));
    app.client.setSubgraphAddress(custody_group_id);
    app.allocator = allocator;
    defer app.allocator = std.testing.allocator;
    var child = try app.captureChildNodeCreation("B", custody_group_id, custody_parent_id);
    defer child.deinit();
    try std.testing.expectEqualStrings("B", app.model.selected_project_path.?);
    try std.testing.expectEqualStrings(custody_group_id, app.model.open_composite_id.?);
    try std.testing.expectEqualStrings("codex", child.initial.backend.?);
    try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
}

test "custody child capture releases every partial owned snapshot allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, custodyCaptureAllocationCase, .{});
}

fn custodyLargeSnapshotAllocationCase(allocator: std.mem.Allocator) !void {
    var app = try custodyTestApp();
    defer deinitCustodyTestApp(&app);
    try custodyAddInspection(&app, "B");
    const large = try std.testing.allocator.alloc(u8, 32 * 1024);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    const node = &app.model.graphs.items[1].nodes.items[0];
    const long_id = try std.testing.allocator.dupe(u8, large);
    std.testing.allocator.free(node.id);
    node.id = long_id;
    const parent_title = try std.testing.allocator.dupe(u8, large);
    std.testing.allocator.free(node.title);
    node.title = parent_title;
    const model = try std.testing.allocator.dupe(u8, large);
    std.testing.allocator.free(app.product_settings.?.default_model);
    app.product_settings.?.default_model = model;
    for (0..12) |_| {
        try app.worktree_inspection.?.entries.append(.{
            .path = try std.testing.allocator.dupe(u8, large),
            .branch = try std.testing.allocator.dupe(u8, large),
        });
    }
    app.allocator = allocator;
    defer app.allocator = std.testing.allocator;
    var child = try app.captureChildNodeCreation("B", null, long_id);
    defer child.deinit();
    WorktreeStatus.deinitInspection(std.testing.allocator, &app.worktree_inspection.?);
    app.worktree_inspection = null;
    app.product_settings.?.deinit();
    app.product_settings = null;
    _ = try app.model.updateFromFrame(custody_graph_b);
    try std.testing.expectEqualStrings(large, child.context.parent.?.id);
    try std.testing.expectEqualStrings(large, child.initial.model_tier);
    try std.testing.expectEqual(@as(usize, 13), child.choices.len);
    try std.testing.expectEqualStrings(large, child.choices[12].path);
    try std.testing.expectEqualStrings(large, child.choices[12].branch);
}

test "custody child arena growth and repeated captures free every partial snapshot" {
    for (0..3) |_| try custodyLargeSnapshotAllocationCase(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, custodyLargeSnapshotAllocationCase, .{});
}

fn custodyQueueAllocationCase(allocator: std.mem.Allocator) !void {
    var app = try custodyTestApp();
    defer deinitCustodyTestApp(&app);
    var child = try app.captureChildNodeCreation("B", null, custody_parent_id);
    defer child.deinit();
    try app.prepareChildNodeCreation(&child);
    var draft = child.initial;
    draft.node_id = "44444444-4444-4444-8444-444444444444";
    app.client.allocator = allocator;
    defer app.client.allocator = std.testing.allocator;
    app.client.sendCreateNodeDraft(child.context.project_path, draft);
    if (app.client.outbound_count == 0) {
        try std.testing.expectEqualStrings("create node command encoding failed", app.client.last_error);
        return error.OutOfMemory;
    }
    try std.testing.expectEqual(@as(usize, 1), app.client.outbound_count);
}

test "custody child queue allocation failures remain explicit and never double enqueue" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, custodyQueueAllocationCase, .{});
}

test "custody child selected-ID allocation refusal does not open or enqueue" {
    var app = try custodyTestApp();
    defer deinitCustodyTestApp(&app);
    try std.testing.expect(app.selectProject("B"));
    try std.testing.expect(app.selectNodeIndex(1));
    var child = try app.captureChildNodeCreation("B", null, custody_parent_id);
    defer child.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    app.allocator = failing.allocator();
    defer app.allocator = std.testing.allocator;
    try std.testing.expectError(error.NodeCreationSelectionFailed, app.prepareChildNodeCreation(&child));
    try std.testing.expectEqualStrings(custody_group_id, app.selected_node_id);
    try std.testing.expectEqualStrings(custody_group_id, app.model.selected_node_id.?);
    try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
    try std.testing.expectEqualStrings("Unable to select the child node's parent", App.nodeFormErrorStatus(error.NodeCreationSelectionFailed));
}

test "custody child model selection preparation failure preserves popup and blocks transfer" {
    for (0..2) |fail_index| {
        var app = try custodyTestApp();
        defer deinitCustodyTestApp(&app);
        try std.testing.expect(app.selectProject("B"));
        try std.testing.expect(app.model.openComposite(custody_group_id));
        app.client.setSubgraphAddress(custody_group_id);
        var child = try app.captureChildNodeCreation("A", null, custody_parent_id);
        defer child.deinit();
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        app.model.allocator = failing.allocator();
        const prepared = app.prepareChildNodeCreation(&child);
        app.model.allocator = std.testing.allocator;
        try std.testing.expectError(error.NodeCreationSelectionFailed, prepared);
        try std.testing.expectEqualStrings("B", app.model.selected_project_path.?);
        try std.testing.expectEqualStrings(custody_group_id, app.model.open_composite_id.?);
        try std.testing.expectEqualStrings(custody_group_id, app.client.subgraph_node_id);
        const guard = App.NodeCreationValidation{ .app = &app, .context = &child.context };
        var owner = NativeForms.NodeContinuation{ .directory = try app.allocator.dupe(u8, "synthetic-owned-leaf") };
        defer owner.deinit(app.allocator);
        var transferred = false;
        try std.testing.expectError(error.NodeCreationProjectChanged, NativeForms.NodeFormTest.finish(
            app.allocator,
            custodyAttachedInitial(&child),
            .accept,
            .{ .context = &guard, .check = App.NodeCreationValidation.check },
            &owner,
            &transferred,
            CustodyDiscard.discard,
        ));
        try std.testing.expect(!transferred);
        try std.testing.expectEqual(@as(usize, 0), owner.directory.len);
        try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
    }
}

const CustodyDiscard = struct {
    var calls: usize = 0;
    fn discard(path: []const u8) !void {
        try std.testing.expectEqualStrings("synthetic-owned-leaf", path);
        calls += 1;
    }
};

fn custodyAttachedInitial(child: *const App.ChildNodeCreation) Forms.NodeDraft {
    var initial = child.initial;
    initial.node_id = "44444444-4444-4444-8444-444444444444";
    initial.attachment_count = 1;
    initial.attachment_ids[0] = "55555555-5555-4555-8555-555555555555";
    initial.attachment_paths[0] = "C:\\synthetic-only\\image.png";
    return initial;
}

test "custody child invalid parent cannot transfer attachments or queue at either form boundary" {
    const Change = enum { deleted, resolved, backend, loop_type, project, address };
    for ([_]NativeForms.NodeFormTest.Outcome{ .accept, .templates }) |outcome| {
        for (std.enums.values(Change)) |change| {
            var app = try custodyTestApp();
            defer deinitCustodyTestApp(&app);
            var child = try app.captureChildNodeCreation("B", null, custody_parent_id);
            defer child.deinit();
            try app.prepareChildNodeCreation(&child);
            const guard = App.NodeCreationValidation{ .app = &app, .context = &child.context };
            switch (change) {
                .deleted => _ = try app.model.updateFromFrame(
                    \\{"event":{"graphChanged":{"project":{"path":"B","name":"Beta"},"nodes":[],"edges":[]}}}
                ),
                .resolved => try custodyReplaceParentField(&app, .state, "stopped"),
                .backend => try custodyReplaceParentField(&app, .backend, "claudeCode"),
                .loop_type => try custodyReplaceParentField(&app, .loop_type, "goalBased"),
                .project => try std.testing.expect(app.selectProject("A")),
                .address => app.client.setSubgraphAddress(custody_group_id),
            }
            const expected: anyerror = switch (change) {
                .deleted => error.NodeCreationParentMissing,
                .resolved => error.NodeCreationParentResolved,
                .backend => error.NodeCreationParentBackendChanged,
                .loop_type => error.NodeCreationParentTypeChanged,
                .project => error.NodeCreationProjectChanged,
                .address => error.NodeCreationCompositeChanged,
            };
            var owner = NativeForms.NodeContinuation{ .directory = try app.allocator.dupe(u8, "synthetic-owned-leaf") };
            defer owner.deinit(app.allocator);
            var transferred = false;
            CustodyDiscard.calls = 0;
            try std.testing.expectError(expected, NativeForms.NodeFormTest.finish(
                app.allocator,
                custodyAttachedInitial(&child),
                outcome,
                .{ .context = &guard, .check = App.NodeCreationValidation.check },
                &owner,
                &transferred,
                CustodyDiscard.discard,
            ));
            try std.testing.expect(!transferred);
            try std.testing.expectEqual(@as(usize, 1), CustodyDiscard.calls);
            try std.testing.expectEqual(@as(usize, 0), owner.directory.len);
            try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
        }
    }
}

test "custody child template continuation retains custody and the edited backend" {
    var app = try custodyTestApp();
    defer deinitCustodyTestApp(&app);
    var child = try app.captureChildNodeCreation("B", null, custody_parent_id);
    defer child.deinit();
    try app.prepareChildNodeCreation(&child);
    const guard = App.NodeCreationValidation{ .app = &app, .context = &child.context };
    const validation = NativeForms.NodeValidation{ .context = &guard, .check = App.NodeCreationValidation.check };
    var owner = NativeForms.NodeContinuation{ .directory = try app.allocator.dupe(u8, "synthetic-owned-leaf") };
    defer owner.deinit(app.allocator);
    var transferred = false;
    CustodyDiscard.calls = 0;
    var edited = custodyAttachedInitial(&child);
    edited.backend = "codex";
    const picked = try NativeForms.NodeFormTest.finish(app.allocator, edited, .templates, validation, &owner, &transferred, CustodyDiscard.discard);
    var current = picked.templates;
    defer current.deinit(app.allocator);
    try std.testing.expect(transferred);
    try std.testing.expectEqualStrings("synthetic-owned-leaf", owner.directory);
    try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
    try app.validateNodeCreationContext(&child.context);
    var template = try TemplateLibrary.fromDraft(app.allocator, "A reusable task", .{
        .title = "",
        .backend = "codex",
        .first_instruction = "Use the edited backend",
    });
    defer template.deinit(app.allocator);
    try TemplateLibrary.applyOwned(&current, template, app.allocator);
    try std.testing.expectEqualStrings(custody_parent_id, current.created_by);
    transferred = false;
    const accepted = try NativeForms.NodeFormTest.finish(app.allocator, current, .accept, validation, &owner, &transferred, CustodyDiscard.discard);
    var draft = accepted.draft;
    defer draft.deinit(app.allocator);
    try std.testing.expect(transferred);
    try std.testing.expectEqual(@as(usize, 0), owner.directory.len);
    try std.testing.expectEqual(@as(usize, 0), CustodyDiscard.calls);
    try std.testing.expectEqualStrings("codex", draft.backend.?);
    try std.testing.expectEqualStrings(custody_parent_id, draft.created_by);
    try std.testing.expectEqualStrings(current.node_id, draft.node_id);
    app.client.sendCreateNodeDraft(child.context.project_path, draft);
    try std.testing.expectEqual(@as(usize, 1), app.client.outbound_count);
    var parsed = try std.json.parseFromSlice(std.json.Value, app.allocator, app.client.outbound[app.client.outbound_head], .{});
    defer parsed.deinit();
    const wire_draft = parsed.value.object.get("graphCommand").?.object.get("command").?.object.get("createNode").?.object.get("_0").?.object;
    try std.testing.expectEqualStrings(draft.node_id, wire_draft.get("id").?.string);
    try std.testing.expectEqualStrings(custody_parent_id, wire_draft.get("createdBy").?.string);
    try std.testing.expectEqualStrings("codex", wire_draft.get("backend").?.string);
    try std.testing.expectEqual(@as(usize, 1), wire_draft.get("attachments").?.array.items.len);
}

test "custody child cancellation and rejected template continuation discard once without sending" {
    for ([_]bool{ false, true }) |invalidate| {
        var app = try custodyTestApp();
        defer deinitCustodyTestApp(&app);
        var child = try app.captureChildNodeCreation("B", null, custody_parent_id);
        defer child.deinit();
        try app.prepareChildNodeCreation(&child);
        const guard = App.NodeCreationValidation{ .app = &app, .context = &child.context };
        const validation = NativeForms.NodeValidation{ .context = &guard, .check = App.NodeCreationValidation.check };
        var owner = NativeForms.NodeContinuation{ .directory = try app.allocator.dupe(u8, "synthetic-owned-leaf") };
        defer owner.deinit(app.allocator);
        var transferred = false;
        CustodyDiscard.calls = 0;
        const result = try NativeForms.NodeFormTest.finish(app.allocator, custodyAttachedInitial(&child), .templates, validation, &owner, &transferred, CustodyDiscard.discard);
        var draft = result.templates;
        defer draft.deinit(app.allocator);
        if (invalidate) {
            try custodyReplaceParentField(&app, .state, "failed");
            try std.testing.expectError(error.NodeCreationParentResolved, app.validateNodeCreationContext(&child.context));
        }
        transferred = false;
        const cancelled = try NativeForms.NodeFormTest.finish(app.allocator, draft, .cancel, validation, &owner, &transferred, CustodyDiscard.discard);
        try std.testing.expect(cancelled == .cancelled);
        try std.testing.expect(!transferred);
        try std.testing.expectEqual(@as(usize, 1), CustodyDiscard.calls);
        try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
    }
}

fn deinitNodeSubmissionTestApp(app: *App) void {
    app.client.deinit();
    app.model.deinit();
    app.sidebar_state.deinit();
    app.declared_entry_ids.deinit();
    app.kept_worktree_paths.deinit();
    if (app.worktree_inspection) |*inspection| WorktreeStatus.deinitInspection(app.allocator, inspection);
}

const node_submission_graph =
    \\{"version":2,"kind":"event","event":{"graphChanged":{"project":{"path":"A","name":"Alpha"},"nodes":[{"id":"parent","title":"Empty group","loopType":"proactive","subGraph":{"nodes":[],"edges":[]}}],"edges":[]}}}
;
const node_submission_refresh =
    \\{"version":2,"kind":"event","event":{"graphChanged":{"project":{"path":"A","name":"Refreshed"},"nodes":[{"id":"other","title":"Other"},{"id":"parent","title":"Still empty","loopType":"composite","subGraph":{}}],"edges":[]}}}
;
const node_submission_foreign =
    \\{"version":2,"kind":"event","event":{"graphChanged":{"project":{"path":"B","name":"Beta"},"nodes":[{"id":"parent","title":"Foreign","loopType":"proactive","subGraph":{}}],"edges":[]}}}
;

test "node submission owns identity and accepts refreshed empty composites" {
    const allocator = std.testing.allocator;
    var app = try nodeSubmissionTestApp(allocator);
    defer deinitNodeSubmissionTestApp(&app);
    _ = try app.model.updateFromFrame(node_submission_graph);
    try std.testing.expect(app.model.openComposite("parent"));
    try std.testing.expectEqual(@as(usize, 0), app.model.graph.?.nodes.items.len);
    app.client.setSubgraphAddress("parent");
    var context = (try app.captureNodeCreationContext()).?;
    defer context.deinit(allocator);
    try std.testing.expect(context.origin == .loaded);
    try std.testing.expect(context.project_path.ptr != app.model.currentGraph().?.project.path.ptr);
    try std.testing.expect(context.composite_id.?.ptr != app.model.open_composite_id.?.ptr);
    const guard = App.NodeCreationValidation{ .app = &app, .context = &context };
    try App.NodeCreationValidation.check(&guard);
    _ = try app.model.updateFromFrame(node_submission_refresh);
    try App.NodeCreationValidation.check(&guard);
    try std.testing.expectEqualStrings("A", context.project_path);
    try std.testing.expectEqualStrings("parent", context.composite_id.?);
    try std.testing.expectEqualStrings("A", app.model.selected_project_path.?);
    try std.testing.expectEqualStrings("parent", app.model.open_composite_id.?);
    try std.testing.expectEqualStrings("parent", app.client.subgraph_node_id);
}

test "node submission refuses project closure and independent composite scope drift" {
    const allocator = std.testing.allocator;
    const Change = enum { project, closed, client, composite, missing, wrong_type, missing_payload };
    for (std.enums.values(Change)) |change| {
        var app = try nodeSubmissionTestApp(allocator);
        defer deinitNodeSubmissionTestApp(&app);
        _ = try app.model.updateFromFrame(node_submission_graph);
        try std.testing.expect(app.model.openComposite("parent"));
        app.client.setSubgraphAddress("parent");
        var context = (try app.captureNodeCreationContext()).?;
        defer context.deinit(allocator);
        switch (change) {
            .project => {
                _ = try app.model.updateFromFrame(node_submission_foreign);
                try std.testing.expect(app.model.selectProject("B"));
            },
            .closed => {
                _ = try app.model.updateFromFrame(
                    \\{"kind":"event","event":{"recentProjectsListed":[{"path":"A","name":"Alpha"}]}}
                );
                try std.testing.expect(app.model.applyLifecycle(.close, "A"));
                try std.testing.expectEqualStrings("A", app.currentProject().?);
            },
            .client => app.client.setSubgraphAddress("different-parent"),
            .composite => app.model.closeComposite(),
            .missing => {
                _ = try app.model.updateFromFrame(
                    \\{"kind":"event","event":{"graphChanged":{"project":{"path":"A","name":"Alpha"},"nodes":[],"edges":[]}}}
                );
            },
            .wrong_type => {
                _ = try app.model.updateFromFrame(
                    \\{"kind":"event","event":{"graphChanged":{"project":{"path":"A","name":"Alpha"},"nodes":[{"id":"parent","title":"Not a group","loopType":"turnBased","subGraph":{}}],"edges":[]}}}
                );
            },
            .missing_payload => {
                _ = try app.model.updateFromFrame(
                    \\{"kind":"event","event":{"graphChanged":{"project":{"path":"A","name":"Alpha"},"nodes":[{"id":"parent","title":"Missing graph","loopType":"proactive"}],"edges":[]}}}
                );
            },
        }
        const expected: anyerror = switch (change) {
            .project => error.NodeCreationProjectChanged,
            .closed => error.NodeCreationProjectClosed,
            else => error.NodeCreationCompositeChanged,
        };
        try std.testing.expectError(expected, app.validateNodeCreationContext(&context));
        try std.testing.expectEqualStrings("A", context.project_path);
        try std.testing.expectEqualStrings("parent", context.composite_id.?);
        try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
    }
}

test "node submission top level requires both current scopes to remain empty" {
    const allocator = std.testing.allocator;
    var app = try nodeSubmissionTestApp(allocator);
    defer deinitNodeSubmissionTestApp(&app);
    _ = try app.model.updateFromFrame(node_submission_graph);
    var context = (try app.captureNodeCreationContext()).?;
    defer context.deinit(allocator);
    try app.validateNodeCreationContext(&context);
    _ = try app.model.updateFromFrame(node_submission_refresh);
    try app.validateNodeCreationContext(&context);
    app.client.setSubgraphAddress("parent");
    try std.testing.expectError(error.NodeCreationCompositeChanged, app.validateNodeCreationContext(&context));
    app.client.setSubgraphAddress(null);
    try std.testing.expect(app.model.openComposite("parent"));
    try std.testing.expectError(error.NodeCreationCompositeChanged, app.validateNodeCreationContext(&context));
    app.model.closeComposite();
    app.model.open_composite_id = try allocator.dupe(u8, "");
    try std.testing.expectError(error.NodeCreationCompositeChanged, app.validateNodeCreationContext(&context));
}

test "node submission preserves recent and inspection path-only starts and promotion" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |recent| {
        var app = try nodeSubmissionTestApp(allocator);
        defer deinitNodeSubmissionTestApp(&app);
        app.worktree_inspection = .{
            .entries = std.array_list.Managed(WorktreeStatus.Entry).init(allocator),
            .default_branch = try allocator.dupe(u8, ""),
            .project_path = try allocator.dupe(u8, "A"),
        };
        if (recent) {
            _ = try app.model.updateFromFrame(
                \\{"kind":"event","event":{"recentProjectsListed":[{"path":"A","name":"Alpha"}]}}
            );
        }
        var context = (try app.captureNodeCreationContext()).?;
        defer context.deinit(allocator);
        try std.testing.expect(if (recent) context.origin == .recent else context.origin == .inspection);
        try std.testing.expect(app.model.graph == null);
        try app.validateNodeCreationContext(&context);
        _ = try app.model.updateFromFrame(
            \\{"kind":"event","event":{"recentProjectsListed":[]}}
        );
        try app.validateNodeCreationContext(&context);
        _ = try app.model.updateFromFrame(node_submission_graph);
        try app.validateNodeCreationContext(&context);
        _ = try app.model.updateFromFrame(node_submission_foreign);
        try std.testing.expect(app.model.selectProject("B"));
        try std.testing.expectError(error.NodeCreationProjectChanged, app.validateNodeCreationContext(&context));
    }
}

test "node submission preserves overview global fallback without inventing availability" {
    const allocator = std.testing.allocator;
    var app = try nodeSubmissionTestApp(allocator);
    defer deinitNodeSubmissionTestApp(&app);
    try std.testing.expect((try app.captureNodeCreationContext()) == null);
    app.surface = .overview;
    var context = (try app.captureNodeCreationContext()).?;
    defer context.deinit(allocator);
    try std.testing.expect(context.origin == .overview_global);
    try std.testing.expectEqualStrings("graphcode://global", context.project_path);
    try app.validateNodeCreationContext(&context);
    app.surface = .project;
    try std.testing.expectError(error.NodeCreationProjectChanged, app.validateNodeCreationContext(&context));
    _ = try app.model.updateFromFrame(
        \\{"kind":"event","event":{"graphChanged":{"project":{"path":"graphcode://global","name":"Global"},"nodes":[],"edges":[]}}}
    );
    try app.validateNodeCreationContext(&context);
}

test "node submission path identity is exact and a recent-only target can disappear" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "C:\\Project", "ssh://host/project" }) |path| {
        var app = try nodeSubmissionTestApp(allocator);
        defer deinitNodeSubmissionTestApp(&app);
        try app.model.recent_projects.append(.{
            .path = try allocator.dupe(u8, path),
            .name = try allocator.dupe(u8, "Recent"),
        });
        var context = (try app.captureNodeCreationContext()).?;
        defer context.deinit(allocator);
        try app.validateNodeCreationContext(&context);
        app.model.recent_projects.items[0].path[0] = std.ascii.toLower(path[0]);
        if (path[0] == 'C')
            try std.testing.expectError(error.NodeCreationProjectChanged, app.validateNodeCreationContext(&context));
        _ = try app.model.updateFromFrame(
            \\{"kind":"event","event":{"recentProjectsListed":[]}}
        );
        try std.testing.expectError(error.NodeCreationProjectChanged, app.validateNodeCreationContext(&context));
        try std.testing.expectEqualStrings(path, context.project_path);
    }
}

fn nodeSubmissionCaptureAllocationCase(allocator: std.mem.Allocator) !void {
    var app = try nodeSubmissionTestApp(std.testing.allocator);
    defer deinitNodeSubmissionTestApp(&app);
    _ = try app.model.updateFromFrame(node_submission_graph);
    try std.testing.expect(app.model.openComposite("parent"));
    app.client.setSubgraphAddress("parent");
    app.allocator = allocator;
    var context = (try app.captureNodeCreationContext()).?;
    defer context.deinit(allocator);
    try app.validateNodeCreationContext(&context);
}

test "node submission capture allocation failure preserves original model identity" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, nodeSubmissionCaptureAllocationCase, .{});
}

test "node submission cleanup reporting retains the primary and cleanup failures" {
    var buffer: [512]u8 = undefined;
    const message = App.nodeCreationCleanupStatus(&buffer, null, error.NodeCreationProjectClosed, error.AccessDenied);
    try std.testing.expect(std.mem.indexOf(u8, message, "Project closed while creating node") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "NodeCreationProjectClosed") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "AccessDenied") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "Staged files retained") != null);
    const cancelled = App.nodeCreationCleanupStatus(&buffer, null, null, error.AccessDenied);
    try std.testing.expect(std.mem.indexOf(u8, cancelled, "Node creation cancelled") != null);
    const apply_failed = App.nodeCreationCleanupStatus(&buffer, "Unable to apply selected template", error.OutOfMemory, error.AccessDenied);
    try std.testing.expect(std.mem.indexOf(u8, apply_failed, "Unable to apply selected template (OutOfMemory)") != null);
    try std.testing.expect(std.mem.indexOf(u8, apply_failed, "AccessDenied") != null);
    const unused = App.nodeCreationCleanupStatus(&buffer, null, error.NodeAttachmentCleanupFailed, error.AccessDenied);
    try std.testing.expect(std.mem.indexOf(u8, unused, "Unable to discard unused node attachments") != null);
    try std.testing.expect(std.mem.indexOf(u8, unused, "context changed") == null);
}

test "worktree choices for node form degrade honestly when there is no inspection" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .client = undefined,
        .daemon = undefined,
        .model = undefined,
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
    };
    defer app.sidebar_state.deinit();
    defer app.declared_entry_ids.deinit();
    defer app.kept_worktree_paths.deinit();
    // No worktree inspection has run (e.g. creating a node for graphcode://global):
    // the picker must see an explicit empty list, never a fabricated entry.
    var snapshot = try app.worktreeChoicesForNodeForm(allocator, "graphcode://global");
    defer snapshot.deinit(allocator);
    const choices = snapshot.items;
    try std.testing.expectEqual(@as(usize, 0), choices.len);
}

test "worktree choices for node form project real entries and the default branch" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .client = undefined,
        .daemon = undefined,
        .model = undefined,
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
    };
    defer app.sidebar_state.deinit();
    defer app.declared_entry_ids.deinit();
    defer app.kept_worktree_paths.deinit();

    var entries = std.array_list.Managed(WorktreeStatus.Entry).init(allocator);
    try entries.append(.{ .path = try allocator.dupe(u8, "C:\\repo\\wt-main"), .branch = try allocator.dupe(u8, "main") });
    try entries.append(.{ .path = try allocator.dupe(u8, "C:\\repo\\wt-feature"), .branch = try allocator.dupe(u8, "feature/x") });
    app.worktree_inspection = .{
        .entries = entries,
        .default_branch = try allocator.dupe(u8, "main"),
        .project_path = try allocator.dupe(u8, "C:\\repo"),
    };
    defer WorktreeStatus.deinitInspection(allocator, &app.worktree_inspection.?);

    var snapshot = try app.worktreeChoicesForNodeForm(allocator, "C:\\repo");
    defer snapshot.deinit(allocator);
    const choices = snapshot.items;
    try std.testing.expectEqual(@as(usize, 2), choices.len);
    try std.testing.expectEqualStrings("main", choices[0].branch);
    try std.testing.expect(choices[0].is_default);
    try std.testing.expectEqualStrings("feature/x", choices[1].branch);
    try std.testing.expect(!choices[1].is_default);
}

fn nodeCreationTestInspection(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    worktree_path: []const u8,
    branch: []const u8,
) !WorktreeStatus.Inspection {
    var entries = std.array_list.Managed(WorktreeStatus.Entry).init(allocator);
    errdefer WorktreeStatus.deinit(allocator, &entries);
    {
        const path_copy = try allocator.dupe(u8, worktree_path);
        errdefer allocator.free(path_copy);
        const branch_copy = try allocator.dupe(u8, branch);
        errdefer allocator.free(branch_copy);
        try entries.append(.{ .path = path_copy, .branch = branch_copy });
    }
    const default_branch = try allocator.dupe(u8, "main");
    errdefer allocator.free(default_branch);
    return .{
        .entries = entries,
        .default_branch = default_branch,
        .project_path = try allocator.dupe(u8, project_path),
    };
}

test "node creation ownership snapshot survives inspection and model replacement" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .client = undefined,
        .daemon = undefined,
        .model = GraphModel.Model.init(allocator),
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
    };
    defer app.model.deinit();
    defer app.sidebar_state.deinit();
    defer app.declared_entry_ids.deinit();
    defer app.kept_worktree_paths.deinit();
    defer if (app.worktree_inspection) |*inspection| WorktreeStatus.deinitInspection(allocator, inspection);
    _ = try app.model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"a","project":{"path":"C:\\repo-a","name":"Alpha"},"nodes":[],"edges":[]}}}
    );
    const project_path = try allocator.dupe(u8, app.currentProject().?);
    defer allocator.free(project_path);
    app.worktree_inspection = try nodeCreationTestInspection(allocator, project_path, "C:\\repo-a-topic", "feature/exact-choice");
    var snapshot_arena = std.heap.ArenaAllocator.init(allocator);
    defer snapshot_arena.deinit();
    var snapshot = try app.worktreeChoicesForNodeForm(snapshot_arena.allocator(), project_path);
    defer snapshot.deinit(snapshot_arena.allocator());
    const choices = snapshot.items;
    try std.testing.expectEqual(@as(usize, 1), choices.len);
    try std.testing.expect(choices[0].path.ptr != app.worktree_inspection.?.entries.items[0].path.ptr);
    try std.testing.expect(choices[0].branch.ptr != app.worktree_inspection.?.entries.items[0].branch.ptr);
    @memset(app.worktree_inspection.?.entries.items[0].path, 'x');
    @memset(app.worktree_inspection.?.entries.items[0].branch, 'x');
    try std.testing.expectEqualStrings("C:\\repo-a-topic", choices[0].path);
    try std.testing.expectEqualStrings("feature/exact-choice", choices[0].branch);
    WorktreeStatus.deinitInspection(allocator, &app.worktree_inspection.?);
    app.worktree_inspection = null;
    app.worktree_inspection = try nodeCreationTestInspection(allocator, "C:\\repo-b", "C:\\repo-b-main", "main");
    _ = try app.model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"id":"a-new","project":{"path":"C:\\repo-a","name":"Alpha refreshed"},"nodes":[],"edges":[]}}}
    );
    _ = try app.model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":3,"event":{"graphChanged":{"id":"b","project":{"path":"C:\\repo-b","name":"Beta"},"nodes":[],"edges":[]}}}
    );
    try std.testing.expect(app.model.selectProject("C:\\repo-b"));
    try std.testing.expectEqualStrings("C:\\repo-a", project_path);
    try std.testing.expectEqualStrings("C:\\repo-a-topic", choices[0].path);
    try std.testing.expectEqualStrings("feature/exact-choice", choices[0].branch);
    try std.testing.expect(!choices[0].is_default);
    var original_project_choices = try app.worktreeChoicesForNodeForm(allocator, project_path);
    defer original_project_choices.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), original_project_choices.items.len);
    var current_project_choices = try app.worktreeChoicesForNodeForm(allocator, app.currentProject().?);
    defer current_project_choices.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), current_project_choices.items.len);
    try std.testing.expectEqualStrings("C:\\repo-b-main", current_project_choices.items[0].path);
    try std.testing.expectEqualStrings("main", current_project_choices.items[0].branch);
    try std.testing.expect(current_project_choices.items[0].is_default);
}

test "node creation ownership refuses a foreign project inspection" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .client = undefined,
        .daemon = undefined,
        .model = GraphModel.Model.init(allocator),
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
    };
    defer app.model.deinit();
    defer app.sidebar_state.deinit();
    defer app.declared_entry_ids.deinit();
    defer app.kept_worktree_paths.deinit();
    _ = try app.model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"a","project":{"path":"C:\\repo-a","name":"Alpha"},"nodes":[],"edges":[]}}}
    );
    app.worktree_inspection = try nodeCreationTestInspection(allocator, "C:\\repo-b", "C:\\repo-b-main", "main");
    defer WorktreeStatus.deinitInspection(allocator, &app.worktree_inspection.?);
    var snapshot_arena = std.heap.ArenaAllocator.init(allocator);
    defer snapshot_arena.deinit();
    var snapshot = try app.worktreeChoicesForNodeForm(snapshot_arena.allocator(), app.currentProject().?);
    defer snapshot.deinit(snapshot_arena.allocator());
    const choices = snapshot.items;
    try std.testing.expectEqual(@as(usize, 0), choices.len);
    var global_choices = try app.worktreeChoicesForNodeForm(allocator, "graphcode://global");
    defer global_choices.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), global_choices.items.len);
}

test "node creation ownership preserves path-only starts and exact project identity" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .client = undefined,
        .daemon = undefined,
        .model = GraphModel.Model.init(allocator),
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
    };
    defer app.model.deinit();
    defer app.sidebar_state.deinit();
    defer app.declared_entry_ids.deinit();
    defer app.kept_worktree_paths.deinit();
    app.worktree_inspection = try nodeCreationTestInspection(allocator, "C:\\repo", "C:\\repo-topic", "feature/path-only");
    defer WorktreeStatus.deinitInspection(allocator, &app.worktree_inspection.?);
    try std.testing.expect(app.model.currentGraph() == null);
    var snapshot = try app.worktreeChoicesForNodeForm(allocator, app.currentProject().?);
    defer snapshot.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), snapshot.items.len);
    try std.testing.expectEqualStrings("feature/path-only", snapshot.items[0].branch);
    for ([_][]const u8{ "C:\\repo-other", "C:\\Repo", "", "ssh://host/repo", "graphcode://global" }) |foreign_path| {
        var foreign = try app.worktreeChoicesForNodeForm(allocator, foreign_path);
        defer foreign.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 0), foreign.items.len);
    }
}

test "node creation ownership releases every partial choice allocation" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .client = undefined,
        .daemon = undefined,
        .model = undefined,
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
    };
    defer app.sidebar_state.deinit();
    defer app.declared_entry_ids.deinit();
    defer app.kept_worktree_paths.deinit();
    const Probe = struct {
        fn run(failing_allocator: std.mem.Allocator, source: *const App, expected_count: usize) !void {
            var choices = try source.worktreeChoicesForNodeForm(failing_allocator, "C:\\repo");
            defer choices.deinit(failing_allocator);
            try std.testing.expectEqual(expected_count, choices.items.len);
            if (expected_count != 0) {
                try std.testing.expectEqualStrings("C:\\repo-main", choices.items[0].path);
                try std.testing.expectEqualStrings("main", choices.items[0].branch);
                try std.testing.expect(choices.items[0].is_default);
                try std.testing.expectEqualStrings("C:\\repo-topic", choices.items[1].path);
                try std.testing.expectEqualStrings("feature/second", choices.items[1].branch);
                try std.testing.expect(!choices.items[1].is_default);
            }
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Probe.run, .{ &app, @as(usize, 0) });
    app.worktree_inspection = try nodeCreationTestInspection(allocator, "C:\\other", "C:\\repo-main", "main");
    defer WorktreeStatus.deinitInspection(allocator, &app.worktree_inspection.?);
    try std.testing.checkAllAllocationFailures(allocator, Probe.run, .{ &app, @as(usize, 0) });
    const project_path = try allocator.dupe(u8, "C:\\repo");
    allocator.free(app.worktree_inspection.?.project_path);
    app.worktree_inspection.?.project_path = project_path;
    {
        const path_copy = try allocator.dupe(u8, "C:\\repo-topic");
        errdefer allocator.free(path_copy);
        const branch_copy = try allocator.dupe(u8, "feature/second");
        errdefer allocator.free(branch_copy);
        try app.worktree_inspection.?.entries.append(.{ .path = path_copy, .branch = branch_copy });
    }
    try std.testing.checkAllAllocationFailures(allocator, Probe.run, .{ &app, @as(usize, 2) });
    WorktreeStatus.deinit(allocator, &app.worktree_inspection.?.entries);
    app.worktree_inspection.?.entries = std.array_list.Managed(WorktreeStatus.Entry).init(allocator);
    try std.testing.checkAllAllocationFailures(allocator, Probe.run, .{ &app, @as(usize, 0) });
}

test "worktree row selected reflects sidebar and dialog selection honestly" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .client = undefined,
        .daemon = undefined,
        .model = GraphModel.Model.init(allocator),
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
    };
    defer app.sidebar_state.deinit();
    defer app.declared_entry_ids.deinit();
    defer app.kept_worktree_paths.deinit();
    defer app.model.deinit();
    _ = try app.model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"C:\\repo","name":"Repo"},"nodes":[],"edges":[]}}}
    );
    app.worktree_inspection = .{
        .entries = std.array_list.Managed(WorktreeStatus.Entry).init(allocator),
        .default_branch = try allocator.dupe(u8, "main"),
        .project_path = try allocator.dupe(u8, "C:\\repo"),
    };
    defer WorktreeStatus.deinitInspection(allocator, &app.worktree_inspection.?);
    try app.worktree_inspection.?.entries.append(.{
        .path = try allocator.dupe(u8, "C:\\repo\\locked"),
        .branch = try allocator.dupe(u8, "topic"),
        .locked = true,
        .pushed = true,
        .landed = true,
    });
    try app.worktree_inspection.?.entries.append(.{
        .path = try allocator.dupe(u8, "C:\\repo\\dirty"),
        .branch = try allocator.dupe(u8, "dirty"),
        .dirty = true,
        .pushed = true,
        .landed = true,
    });
    defer if (app.selected_worktree_path.len != 0) allocator.free(app.selected_worktree_path);

    // Neither the sidebar shortcut nor a dialog has a selection.
    try std.testing.expect(!app.worktreeRowSelected());

    // The sidebar's single-selection shortcut has a path, with no dialog open.
    app.selected_worktree_path = try allocator.dupe(u8, "C:\\repo\\wt-main");
    try std.testing.expect(app.worktreeRowSelected());
    allocator.free(app.selected_worktree_path);
    app.selected_worktree_path = &.{};

    // A dialog is open but nothing is checked in it yet.
    var dialog = try WorktreeDialog.Dialog.init(allocator, "C:\\repo", &.{
        .{ .path = try allocator.dupe(u8, "C:\\repo\\wt-main"), .branch = try allocator.dupe(u8, "main") },
        .{ .path = try allocator.dupe(u8, "C:\\repo\\locked"), .branch = try allocator.dupe(u8, "topic"), .locked = true, .pushed = true, .landed = true },
        .{ .path = try allocator.dupe(u8, "C:\\repo\\dirty"), .branch = try allocator.dupe(u8, "dirty"), .dirty = true, .pushed = true, .landed = true },
    }, .{});
    defer {
        for (dialog.rows.items) |row| {
            allocator.free(row.entry.path);
            allocator.free(row.entry.branch);
        }
        dialog.deinit();
    }
    app.worktree_dialog = dialog;
    try std.testing.expect(!app.worktreeRowSelected());

    // Checking a row in the dialog makes it selected even with no sidebar path.
    _ = app.worktree_dialog.?.toggle(0);
    try std.testing.expect(app.worktreeRowSelected());
    app.worktree_dialog.?.clearSelection();
    try std.testing.expect(app.selectWorktreeRow("C:\\repo\\locked"));
    try std.testing.expect(app.worktree_dialog.?.rows.items[1].selected);
    try std.testing.expectEqualStrings("C:\\repo\\locked", app.selected_worktree_path);
    try std.testing.expect(!app.selectWorktreeRow("C:\\repo\\dirty"));
    try std.testing.expect(!app.worktree_dialog.?.rows.items[2].selected);
}

test "gesture registration outcome survives later startup setStatus calls" {
    // App.run() calls setStatus() repeatedly during synchronous startup
    // (tray, daemon status, accessibility attach, product-settings/canvas-
    // layout/sidebar-store load failures) immediately after the gesture-
    // registration diagnostic. Any of those can legitimately clobber the
    // transient status line before the window is ever shown; what must NOT
    // be lost is the durable record on `window` itself.
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .client = undefined,
        .daemon = undefined,
        .model = undefined,
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
    };
    defer app.sidebar_state.deinit();
    defer app.declared_entry_ids.deinit();
    defer app.kept_worktree_paths.deinit();
    defer if (app.status_override.len != 0) allocator.free(app.status_override);

    app.window.gesture_config_registered = false;
    app.window.gesture_config_last_error = 1223;

    var buf: [96]u8 = undefined;
    app.setStatus(formatGestureRegistrationFailure(&buf, app.window.gesture_config_last_error));
    // Simulate the later startup calls that are known to overwrite status.
    app.setStatus("Connecting to daemon...");
    app.setStatus("Accessibility provider unavailable");
    app.setStatus("Product settings failed to load");

    // The transient line is allowed to have been overwritten...
    try std.testing.expect(!std.mem.eql(u8, app.status(), "Touch pinch-zoom unavailable (gesture config error 1223)"));
    // ...but the durable record must be completely unaffected.
    try std.testing.expect(!app.window.gesture_config_registered);
    try std.testing.expectEqual(@as(c.DWORD, 1223), app.window.gesture_config_last_error);
}

test "first-run startup schedules daemon connection before the modal returns" {
    const Event = enum {
        connection_scheduled,
        modal_entered,
        modal_returned,
    };
    const Probe = struct {
        events: [3]Event = undefined,
        count: usize = 0,

        fn append(self: *@This(), event: Event) void {
            self.events[self.count] = event;
            self.count += 1;
        }

        fn scheduleConnection(self: *@This()) void {
            self.append(.connection_scheduled);
        }

        fn showModal(self: *@This()) void {
            self.append(.modal_entered);
            self.append(.modal_returned);
        }
    };
    var probe = Probe{};

    try std.testing.expect(runFirstRunStartup(&probe, true, Probe.scheduleConnection, Probe.showModal));

    try std.testing.expectEqual(@as(usize, 3), probe.count);
    try std.testing.expectEqual(Event.connection_scheduled, probe.events[0]);
    try std.testing.expectEqual(Event.modal_entered, probe.events[1]);
    try std.testing.expectEqual(Event.modal_returned, probe.events[2]);
}

test "ordinary startup defers daemon connection when no first-run modal is shown" {
    const Probe = struct {
        connection_scheduled: bool = false,
        modal_shown: bool = false,

        fn scheduleConnection(self: *@This()) void {
            self.connection_scheduled = true;
        }

        fn showModal(self: *@This()) void {
            self.modal_shown = true;
        }
    };
    var probe = Probe{};

    try std.testing.expect(!runFirstRunStartup(&probe, false, Probe.scheduleConnection, Probe.showModal));

    try std.testing.expect(!probe.connection_scheduled);
    try std.testing.expect(!probe.modal_shown);
}

test "gesture registration failure formats the exact production diagnostic text" {
    // This is the same formatter run() actually calls for both the
    // std.log.warn line and the transient setStatus() line, so this proves
    // the real observable failure output, not a hand-duplicated string.
    var buf: [96]u8 = undefined;
    const message = formatGestureRegistrationFailure(&buf, 1223);
    try std.testing.expectEqualStrings("Touch pinch-zoom unavailable (gesture config error 1223)", message);

    // A buffer too small to hold the formatted error code falls back to the
    // fixed, always-fitting message rather than silently truncating or
    // erroring.
    var tiny_buf: [4]u8 = undefined;
    const fallback = formatGestureRegistrationFailure(&tiny_buf, 1223);
    try std.testing.expectEqualStrings("Touch pinch-zoom unavailable", fallback);
}

test "header detail toggle preserves workspace instead of generic panel navigation" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .client = undefined,
        .daemon = undefined,
        .model = undefined,
        .sidebar_state = undefined,
        .declared_entry_ids = undefined,
        .kept_worktree_paths = undefined,
    };
    for ([_]bool{ false, true }) |sidebar_visible| {
        app.surface = .workspace;
        app.workspace_controls = .{ .rail_visible = sidebar_visible, .panel_visible = true };
        app.toggleWorkspaceDetailPanelState();
        try std.testing.expectEqual(GraphCanvas.Surface.workspace, app.surface);
        try std.testing.expect(!app.workspace_controls.panel_visible);
        try std.testing.expectEqual(sidebar_visible, app.workspace_controls.rail_visible);
        app.toggleWorkspaceDetailPanelState();
        try std.testing.expectEqual(GraphCanvas.Surface.workspace, app.surface);
        try std.testing.expect(app.workspace_controls.panel_visible);
        try std.testing.expectEqual(sidebar_visible, app.workspace_controls.rail_visible);

        app.toggleWorkspacePanelState();
        try std.testing.expectEqual(GraphCanvas.Surface.project, app.surface);
        try std.testing.expect(!app.workspace_controls.panel_visible);
        try std.testing.expectEqual(sidebar_visible, app.workspace_controls.rail_visible);
    }
}

test "sketch promotion popup adapter cancels and rejects races before one-time cached project selection" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .client = try DaemonClient.initUnstartedForTest(std.testing.allocator),
        .daemon = undefined,
        .model = GraphModel.Model.init(std.testing.allocator),
        .sidebar_state = undefined,
        .declared_entry_ids = undefined,
        .kept_worktree_paths = undefined,
    };
    defer app.client.deinit();
    defer app.model.deinit();
    defer app.allocator.free(app.selected_node_id);
    _ = try app.model.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"A","name":"A"},"nodes":[{"id":"same","title":"A sketch","loopType":"sketch","firstInstruction":"A note"},{"id":"other","title":"Other","loopType":"goalBased"}],"edges":[]}}
    );
    _ = try app.model.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"B","name":"B"},"nodes":[{"id":"same","title":"B sketch","loopType":"sketch","firstInstruction":"B note"}],"edges":[]}}
    );
    app.client.setSubscription("A");
    var context = try SketchPromotion.Context.capture(app.allocator, &app.model, "B", "", app.model.graphFor("B").?.nodes.items[0]);
    defer context.deinit(app.allocator);
    try std.testing.expect(!try app.prepareSketchPromotion(context, null));
    try std.testing.expectEqualStrings("A", app.model.graph.?.project.path);
    try std.testing.expectEqualStrings("", app.client.subgraph_node_id);
    try std.testing.expectEqual(@as(usize, 0), app.client.outbound_count);
    try std.testing.expect(app.model.setSelectedID("other"));
    try std.testing.expectError(error.PromotionContextChanged, app.prepareSketchPromotion(context, .goal));
    try std.testing.expectEqualStrings("other", app.model.selectedNodeID().?);
    try std.testing.expect(app.model.setSelectedID("same"));
    try std.testing.expect(app.selectProject("B"));
    try std.testing.expectError(error.PromotionContextChanged, app.prepareSketchPromotion(context, .goal));
    try std.testing.expectEqualStrings("B", app.model.graph.?.project.path);
    try std.testing.expect(app.selectProject("A"));
    try std.testing.expect(try app.prepareSketchPromotion(context, .goal));
    try std.testing.expectEqualStrings("B", app.model.graph.?.project.path);
    try std.testing.expectEqualStrings("A", app.client.subscription_path);
    try std.testing.expectError(error.PromotionContextChanged, app.prepareSketchPromotion(context, .goal));
    try std.testing.expect(!try app.client.sendSketchPromotion(&app.model, context, null));
    try std.testing.expect(try app.client.sendSketchPromotion(&app.model, context, .{ .goal = "done" }));
    const command = app.client.outbound[app.client.outbound_head];
    try std.testing.expect(std.mem.indexOf(u8, command, "\"projectPath\":\"B\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "\"promoteNode\"") != null);
    try std.testing.expectEqualStrings("same", app.model.selectedNodeID().?);
    try std.testing.expectEqualStrings("A", app.client.subscription_path);
}

test "sketch promotion sidebar root from composite establishes root once and refuses stale form" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .client = try DaemonClient.initUnstartedForTest(std.testing.allocator),
        .daemon = undefined,
        .model = GraphModel.Model.init(std.testing.allocator),
        .sidebar_state = undefined,
        .declared_entry_ids = undefined,
        .kept_worktree_paths = undefined,
    };
    defer app.client.deinit();
    defer app.model.deinit();
    defer app.allocator.free(app.selected_node_id);
    _ = try app.model.updateFromFrame(
        \\{"graphChanged":{"project":{"path":"A","name":"A"},"nodes":[{"id":"same","title":"Root","loopType":"sketch"},{"id":"group","title":"Group","loopType":"proactive","subGraph":{"project":{"path":"A","name":"A"},"nodes":[{"id":"same","title":"Child","loopType":"sketch"}],"edges":[]}}],"edges":[]}}
    );
    try std.testing.expect(app.model.openComposite("group"));
    app.client.setSubgraphAddress("group");
    var context = try SketchPromotion.Context.capture(app.allocator, &app.model, "A", "", app.model.graphFor("A").?.nodes.items[0]);
    defer context.deinit(app.allocator);
    try std.testing.expect(!try app.prepareSketchPromotion(context, null));
    try std.testing.expectEqualStrings("group", app.client.subgraph_node_id);
    try std.testing.expectEqualStrings("Child", app.model.graph.?.nodes.items[0].title);
    try std.testing.expect(try app.prepareSketchPromotion(context, .turn));
    try std.testing.expectEqualStrings("", app.client.subgraph_node_id);
    try std.testing.expectEqualStrings("Root", app.model.graph.?.nodes.items[0].title);
    try std.testing.expect(try app.client.sendSketchPromotion(&app.model, context, .{ .turn = false }));
    try std.testing.expect(std.mem.indexOf(u8, app.client.outbound[app.client.outbound_head], "subGraphCommand") == null);
    try std.testing.expect(app.model.openComposite("group"));
    app.client.setSubgraphAddress("group");
    try std.testing.expectError(error.PromotionContextChanged, app.client.sendSketchPromotion(&app.model, context, .{ .turn = true }));
    try std.testing.expectEqualStrings("group", app.client.subgraph_node_id);
    try std.testing.expectEqual(@as(usize, 1), app.client.outbound_count);
}

test "header presentation follows destinations and keeps sidebar independent" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .client = undefined,
        .daemon = undefined,
        .model = GraphModel.Model.init(allocator),
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
    };
    defer app.model.deinit();
    defer app.sidebar_state.deinit();
    defer app.declared_entry_ids.deinit();
    defer app.kept_worktree_paths.deinit();
    try std.testing.expectEqualStrings("GraphCode Windows", app.headerPresentation().title);
    try std.testing.expect(app.headerPresentation().contains(.jump));
    try std.testing.expect(!app.headerPresentation().contains(.toggle_panel));
    _ = try app.model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"C:\\test","name":"Test"},"nodes":[{"id":"a","title":"A","state":"idle","metricHistory":[{"value":1},{"value":2}]}],"edges":[]}}}
    );
    try std.testing.expect(app.model.setSelectedIndex(0));
    for ([_]GraphCanvas.Surface{ .project, .overview, .quick_chats, .workspace }) |surface| {
        app.surface = surface;
        for ([_]bool{ false, true }) |sidebar_visible| {
            app.workspace_controls.rail_visible = sidebar_visible;
            for ([_]bool{ false, true }) |panel_visible| {
                app.workspace_controls.panel_visible = panel_visible;
                const header = app.headerPresentation();
                try std.testing.expectEqual(surface == .workspace, header.contains(.toggle_panel));
                if (surface == .workspace) try std.testing.expectEqual(panel_visible, header.panel_visible.?);
                try std.testing.expectEqual(sidebar_visible, app.workspace_controls.rail_visible);
            }
        }
    }
    app.workspace_is_quick_chat = true;
    try std.testing.expect(!app.headerPresentation().contains(.toggle_panel));
    try std.testing.expectEqualStrings("Quick Chat workspace", app.headerPresentation().context);
}

test "header UIA identities hash to distinct payloads" {
    // The native header bar's four chips (attention, worktree notice, jump,
    // contextual loop-panel toggle) are dispatched by matching a hashed UIA
    // identity against applyUiaDynamicInvoke's static_targets table. A hash
    // collision here would silently route one chip's activation to another.
    const identities = [_][]const u8{
        "header-attention:needs-you",
        "header-worktree:worktrees",
        "header-jump:jump",
        "header-toggle-panel:control",
        "needs-you-header:needs-you",
        "activity-header:activity",
    };
    for (identities, 0..) |lhs, i| {
        for (identities[i + 1 ..]) |rhs| {
            try std.testing.expect(Accessibility.worktreeIdentityPayload(lhs) != Accessibility.worktreeIdentityPayload(rhs));
        }
    }
}

test "Worktrees inspection action does not block the UI thread on provider work" {
    const SlowInspection = struct {
        var calls = std.atomic.Value(usize).init(0);

        fn run(
            _: std.mem.Allocator,
            _: []const u8,
            _: []const WorktreeStatus.Binding,
            _: ?WorktreeStatus.Cancellation,
        ) anyerror!WorktreeStatus.Inspection {
            _ = calls.fetchAdd(1, .monotonic);
            std.Thread.sleep(300 * std.time.ns_per_ms);
            return error.OwnedFixtureInspectionFailed;
        }
    };
    const LoadingAccessibility = struct {
        found: bool = false,
        error_found: bool = false,
        non_invokable: bool = false,
        visible_bounds: bool = false,

        fn syncCanvasBounds(_: *@This(), _: c.RECT) void {}

        fn syncElements(
            self: *@This(),
            _: []const u8,
            elements: []const Accessibility.DynamicElement,
            _: WorktreeStatus.Policy,
            _: Accessibility.WorktreeCapabilities,
        ) void {
            for (elements) |element| {
                if (!std.mem.eql(u8, element.identity, "worktree-loading:inspection")) continue;
                self.found = std.mem.eql(u8, element.name, "Reading worktrees...");
                self.error_found = std.mem.indexOf(u8, element.name, "Check repository access and retry") != null;
                self.non_invokable = !element.invokable;
                self.visible_bounds = element.right > element.left and element.bottom > element.top;
            }
        }
    };
    const allocator = std.testing.allocator;
    var client = try DaemonClient.initUnstartedForTest(allocator);
    defer client.deinit();
    var app: App = .{
        .allocator = allocator,
        .client = client,
        .daemon = undefined,
        .model = GraphModel.Model.init(allocator),
        .worktree_inspect_runner = SlowInspection.run,
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
    };
    defer {
        app.drainWorktreeInspection();
        if (app.status_override.len != 0) allocator.free(app.status_override);
        app.model.deinit();
        app.sidebar_state.deinit();
        app.declared_entry_ids.deinit();
        app.kept_worktree_paths.deinit();
    }
    _ = try app.model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"C:\\owned-worktree-fixture","name":"Owned fixture"},"nodes":[],"edges":[]}}}
    );

    var timer = try std.time.Timer.start();
    app.inspectWorktrees();
    const elapsed = timer.read();

    try std.testing.expect(elapsed < 100 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), app.worktree_inspection_attempt_count);
    try std.testing.expectEqualStrings("Reading worktrees...", app.status_override);
    var accessibility = LoadingAccessibility{};
    app.syncAccessibilityTo(&accessibility, .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 });
    try std.testing.expect(accessibility.found);
    try std.testing.expect(accessibility.non_invokable);
    try std.testing.expect(accessibility.visible_bounds);

    const deadline = std.time.milliTimestamp() + 2000;
    while (app.worktree_inspection_thread != null and std.time.milliTimestamp() < deadline) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
        app.finishWorktreeInspection();
    }
    try std.testing.expect(app.worktree_inspection_thread == null);
    try std.testing.expectEqual(@as(usize, 1), SlowInspection.calls.load(.monotonic));
    try std.testing.expect(std.mem.indexOf(u8, app.status_override, "OwnedFixtureInspectionFailed") != null);
    try std.testing.expectEqual(@as(usize, 0), app.worktree_loading_path.len);
    var failure_accessibility = LoadingAccessibility{};
    app.syncAccessibilityTo(&failure_accessibility, .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 });
    try std.testing.expect(failure_accessibility.error_found);
}

test "Worktrees rows publish before blocked sizing and UIA moves from pending to final size" {
    const StreamedInspection = struct {
        var inspect_calls = std.atomic.Value(usize).init(0);
        var size_calls = std.atomic.Value(usize).init(0);

        fn inspect(
            allocator: std.mem.Allocator,
            project_path: []const u8,
            _: []const WorktreeStatus.Binding,
            _: ?WorktreeStatus.Cancellation,
        ) anyerror!WorktreeStatus.Inspection {
            _ = inspect_calls.fetchAdd(1, .monotonic);
            var entries = std.array_list.Managed(WorktreeStatus.Entry).init(allocator);
            try entries.append(.{
                .path = try allocator.dupe(u8, "C:\\owned-stream\\linked"),
                .branch = try allocator.dupe(u8, "feature/stream"),
                .pushed = true,
                .landed = true,
            });
            return .{
                .entries = entries,
                .default_branch = try allocator.dupe(u8, "main"),
                .project_path = try allocator.dupe(u8, project_path),
            };
        }

        fn size(_: std.mem.Allocator, _: []const u8, _: []const u8, _: ?WorktreeStatus.Cancellation) WorktreeStatus.SizeCoverage {
            _ = size_calls.fetchAdd(1, .monotonic);
            std.Thread.sleep(300 * std.time.ns_per_ms);
            return .{ .bytes = 4096 };
        }
    };
    const WorktreeAccessibility = struct {
        pending: bool = false,
        final: bool = false,
        partial: bool = false,
        empty: bool = false,

        fn syncCanvasBounds(_: *@This(), _: c.RECT) void {}

        fn syncElements(
            self: *@This(),
            _: []const u8,
            elements: []const Accessibility.DynamicElement,
            _: WorktreeStatus.Policy,
            _: Accessibility.WorktreeCapabilities,
        ) void {
            for (elements) |element| {
                if (std.mem.eql(u8, element.identity, "worktree-loading:inspection")) {
                    self.empty = self.empty or std.mem.eql(u8, element.name, "No linked worktrees in this repository.");
                }
                if (std.mem.indexOf(u8, element.name, "C:\\owned-stream\\linked") == null) continue;
                self.pending = self.pending or std.mem.indexOf(u8, element.name, "size pending") != null;
                self.final = self.final or std.mem.indexOf(u8, element.name, "4.0 KB") != null;
                self.partial = self.partial or std.mem.indexOf(u8, element.name, "AccessDenied") != null;
            }
        }
    };
    const allocator = std.testing.allocator;
    var client = try DaemonClient.initUnstartedForTest(allocator);
    defer client.deinit();
    var app: App = .{
        .allocator = allocator,
        .client = client,
        .daemon = undefined,
        .model = GraphModel.Model.init(allocator),
        .worktree_inspect_runner = StreamedInspection.inspect,
        .worktree_size_runner = StreamedInspection.size,
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
    };
    defer {
        app.drainWorktreeInspection();
        if (app.worktree_dialog) |*dialog| dialog.deinit();
        if (app.worktree_inspection) |*inspection| WorktreeStatus.deinitInspection(allocator, inspection);
        if (app.status_override.len != 0) allocator.free(app.status_override);
        app.model.deinit();
        app.sidebar_state.deinit();
        app.declared_entry_ids.deinit();
        app.kept_worktree_paths.deinit();
    }
    _ = try app.model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"project":{"path":"C:\\owned-stream","name":"Owned stream"},"nodes":[],"edges":[]}}}
    );

    var timer = try std.time.Timer.start();
    app.inspectWorktreesImpl(false);
    try std.testing.expect(timer.read() < 100 * std.time.ns_per_ms);
    const rows_deadline = std.time.milliTimestamp() + 200;
    while (app.worktree_inspection == null and std.time.milliTimestamp() < rows_deadline) {
        std.Thread.sleep(5 * std.time.ns_per_ms);
        app.finishWorktreeInspection();
    }
    try std.testing.expect(app.worktree_inspection != null);
    try std.testing.expect(app.worktree_inspection_thread != null);
    try std.testing.expectEqual(@as(usize, 1), app.worktree_inspection.?.entries.items.len);
    try std.testing.expect(!app.worktree_inspection.?.entries.items[0].size_complete);
    try std.testing.expect(app.currentWorktreeInspection() != null);
    try std.testing.expect(app.worktree_dialog != null);
    var pending = WorktreeAccessibility{};
    app.syncAccessibilityTo(&pending, .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 });
    try std.testing.expect(pending.pending);

    const final_deadline = std.time.milliTimestamp() + 2000;
    while (app.worktree_inspection_thread != null and std.time.milliTimestamp() < final_deadline) {
        std.Thread.sleep(5 * std.time.ns_per_ms);
        app.finishWorktreeInspection();
    }
    try std.testing.expect(app.worktree_inspection_thread == null);
    try std.testing.expectEqual(@as(u64, 4096), app.worktree_inspection.?.entries.items[0].size_bytes);
    try std.testing.expect(app.worktree_inspection.?.entries.items[0].size_complete);
    var final = WorktreeAccessibility{};
    app.syncAccessibilityTo(&final, .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 });
    try std.testing.expect(final.final);
    try std.testing.expectEqual(@as(usize, 1), StreamedInspection.inspect_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), StreamedInspection.size_calls.load(.monotonic));

    const PartialSize = struct {
        fn run(_: std.mem.Allocator, _: []const u8, _: []const u8, _: ?WorktreeStatus.Cancellation) WorktreeStatus.SizeCoverage {
            return .{ .complete = false, .first_error = error.AccessDenied };
        }
    };
    app.worktree_size_runner = PartialSize.run;
    app.inspectWorktreesImpl(false);
    const partial_deadline = std.time.milliTimestamp() + 2000;
    while (app.worktree_inspection_thread != null and std.time.milliTimestamp() < partial_deadline) {
        std.Thread.sleep(5 * std.time.ns_per_ms);
        app.finishWorktreeInspection();
    }
    try std.testing.expectEqual(@as(usize, 1), app.worktree_inspection.?.entries.items.len);
    try std.testing.expect(std.mem.indexOf(u8, app.worktree_state, "1 size unavailable") != null);
    var partial = WorktreeAccessibility{};
    app.syncAccessibilityTo(&partial, .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 });
    try std.testing.expect(partial.partial);

    const EmptyInspection = struct {
        fn run(
            allocator_arg: std.mem.Allocator,
            project_path: []const u8,
            _: []const WorktreeStatus.Binding,
            _: ?WorktreeStatus.Cancellation,
        ) anyerror!WorktreeStatus.Inspection {
            return .{
                .entries = std.array_list.Managed(WorktreeStatus.Entry).init(allocator_arg),
                .default_branch = try allocator_arg.dupe(u8, "main"),
                .project_path = try allocator_arg.dupe(u8, project_path),
            };
        }
    };
    app.worktree_inspect_runner = EmptyInspection.run;
    app.inspectWorktreesImpl(false);
    const empty_deadline = std.time.milliTimestamp() + 2000;
    while (app.worktree_inspection_thread != null and std.time.milliTimestamp() < empty_deadline) {
        std.Thread.sleep(5 * std.time.ns_per_ms);
        app.finishWorktreeInspection();
    }
    try std.testing.expectEqual(@as(usize, 0), app.worktree_inspection.?.entries.items.len);
    try std.testing.expectEqualStrings("No linked worktrees in this repository.", app.worktree_state);
    var empty = WorktreeAccessibility{};
    app.syncAccessibilityTo(&empty, .{ .left = 0, .top = 0, .right = 1200, .bottom = 900 });
    try std.testing.expect(empty.empty);
}

test "project switch cancels stale Worktrees UI application before the latest owner runs" {
    const ReplacedInspection = struct {
        var calls = std.atomic.Value(usize).init(0);

        fn run(
            _: std.mem.Allocator,
            project_path: []const u8,
            _: []const WorktreeStatus.Binding,
            _: ?WorktreeStatus.Cancellation,
        ) anyerror!WorktreeStatus.Inspection {
            _ = calls.fetchAdd(1, .monotonic);
            if (std.mem.endsWith(u8, project_path, "alpha")) {
                std.Thread.sleep(200 * std.time.ns_per_ms);
                return error.StaleAlphaInspection;
            }
            return error.CurrentBetaInspection;
        }
    };
    const allocator = std.testing.allocator;
    var client = try DaemonClient.initUnstartedForTest(allocator);
    defer client.deinit();
    var app: App = .{
        .allocator = allocator,
        .client = client,
        .daemon = undefined,
        .model = GraphModel.Model.init(allocator),
        .worktree_inspect_runner = ReplacedInspection.run,
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
    };
    defer {
        app.drainWorktreeInspection();
        if (app.status_override.len != 0) allocator.free(app.status_override);
        app.model.deinit();
        app.sidebar_state.deinit();
        app.declared_entry_ids.deinit();
        app.kept_worktree_paths.deinit();
    }
    _ = try app.model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"alpha","project":{"path":"C:\\owned\\alpha","name":"Alpha"},"nodes":[],"edges":[]}}}
    );
    _ = try app.model.updateFromFrame(
        \\{"version":2,"kind":"event","sequence":2,"event":{"graphChanged":{"id":"beta","project":{"path":"C:\\owned\\beta","name":"Beta"},"nodes":[],"edges":[]}}}
    );
    try std.testing.expect(app.selectProject("C:\\owned\\alpha"));
    app.inspectWorktrees();
    try std.testing.expect(app.selectProject("C:\\owned\\beta"));

    const deadline = std.time.milliTimestamp() + 2000;
    while (app.worktree_inspection_thread != null and std.time.milliTimestamp() < deadline) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
        app.finishWorktreeInspection();
    }
    try std.testing.expect(app.worktree_inspection_thread == null);
    try std.testing.expect(app.worktree_inspection == null);
    try std.testing.expectEqualStrings("Worktree inspection cancelled after project changed", app.status_override);
    try std.testing.expect(std.mem.indexOf(u8, app.status_override, "StaleAlphaInspection") == null);

    app.inspectWorktrees();
    while ((app.worktree_inspection_thread != null or app.worktree_inspection_pending != null) and
        std.time.milliTimestamp() < deadline)
    {
        std.Thread.sleep(10 * std.time.ns_per_ms);
        app.finishWorktreeInspection();
    }
    try std.testing.expect(app.worktree_inspection_thread == null);
    try std.testing.expect(app.worktree_inspection_pending == null);
    try std.testing.expectEqual(@as(usize, 2), ReplacedInspection.calls.load(.monotonic));
    try std.testing.expect(std.mem.indexOf(u8, app.status_override, "CurrentBetaInspection") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.status_override, "StaleAlphaInspection") == null);
}

test "remote and Codespace Worktrees discovery stays at the provider boundary" {
    try std.testing.expect(RemoteWorktrees.sameRemotePath("/workspaces/repo", "/workspaces/repo/"));
    try std.testing.expect(!RemoteWorktrees.sameRemotePath("/workspaces/repo", "/workspaces/repo-linked"));
    const RemoteFixture = struct {
        var ssh_calls = std.atomic.Value(usize).init(0);
        var codespace_calls = std.atomic.Value(usize).init(0);

        fn inspect(
            allocator_arg: std.mem.Allocator,
            project_path: []const u8,
            _: []const WorktreeStatus.Binding,
            _: ?WorktreeStatus.Cancellation,
        ) anyerror!WorktreeStatus.Inspection {
            if (std.mem.startsWith(u8, project_path, "ssh://")) {
                _ = ssh_calls.fetchAdd(1, .monotonic);
            } else if (std.mem.startsWith(u8, project_path, "codespace://")) {
                _ = codespace_calls.fetchAdd(1, .monotonic);
            } else return error.UnexpectedLocalProviderCall;
            var entries = std.array_list.Managed(WorktreeStatus.Entry).init(allocator_arg);
            try entries.append(.{
                .path = try allocator_arg.dupe(u8, "/workspaces/repo-linked"),
                .branch = try allocator_arg.dupe(u8, "feature/remote"),
                .pushed = true,
                .landed = true,
            });
            return .{
                .entries = entries,
                .default_branch = try allocator_arg.dupe(u8, "main"),
                .project_path = try allocator_arg.dupe(u8, project_path),
            };
        }

        fn size(
            _: std.mem.Allocator,
            project_path: []const u8,
            _: []const u8,
            _: ?WorktreeStatus.Cancellation,
        ) WorktreeStatus.SizeCoverage {
            if (!std.mem.startsWith(u8, project_path, "ssh://") and
                !std.mem.startsWith(u8, project_path, "codespace://"))
                return .{ .complete = false, .first_error = error.UnexpectedLocalProviderCall };
            return .{ .bytes = 2048 };
        }
    };
    const allocator = std.testing.allocator;
    var client = try DaemonClient.initUnstartedForTest(allocator);
    defer client.deinit();
    var app: App = .{
        .allocator = allocator,
        .client = client,
        .daemon = undefined,
        .model = GraphModel.Model.init(allocator),
        .worktree_inspect_runner = RemoteFixture.inspect,
        .worktree_size_runner = RemoteFixture.size,
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
    };
    defer {
        app.drainWorktreeInspection();
        if (app.worktree_dialog) |*dialog| dialog.deinit();
        if (app.worktree_inspection) |*inspection| WorktreeStatus.deinitInspection(allocator, inspection);
        if (app.status_override.len != 0) allocator.free(app.status_override);
        app.model.deinit();
        app.sidebar_state.deinit();
        app.declared_entry_ids.deinit();
        app.kept_worktree_paths.deinit();
    }
    const projects = [_][]const u8{
        "ssh://dev@fixture.invalid/workspaces/repo",
        "codespace://fixture-space/workspaces/repo",
    };
    for (projects, 0..) |project, index| {
        const quoted = try std.json.Stringify.valueAlloc(allocator, project, .{});
        defer allocator.free(quoted);
        const frame = try std.fmt.allocPrint(
            allocator,
            "{{\"version\":2,\"kind\":\"event\",\"sequence\":{d},\"event\":{{\"graphChanged\":{{\"project\":{{\"path\":{s},\"name\":\"Remote {d}\"}},\"nodes\":[],\"edges\":[]}}}}}}",
            .{ index + 1, quoted, index },
        );
        defer allocator.free(frame);
        _ = try app.model.updateFromFrame(frame);
        try std.testing.expect(app.model.selectProject(project));
        app.inspectWorktreesImpl(false);
        const deadline = std.time.milliTimestamp() + 2000;
        while (app.worktree_inspection_thread != null and std.time.milliTimestamp() < deadline) {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            app.finishWorktreeInspection();
        }
        if (app.worktree_inspection == null) {
            std.debug.print("remote fixture inspection missing: {s}\n", .{app.status_override});
            return error.MissingRemoteWorktreeInspection;
        }
        try std.testing.expectEqualStrings(project, app.worktree_inspection.?.project_path);
        try std.testing.expectEqual(@as(usize, 1), app.worktree_inspection.?.entries.items.len);
        try std.testing.expectEqual(@as(u64, 2048), app.worktree_inspection.?.entries.items[0].size_bytes);
    }
    try std.testing.expectEqual(@as(usize, 1), RemoteFixture.ssh_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), RemoteFixture.codespace_calls.load(.monotonic));
}

test "Worktrees reclaim action returns before owned provider removal completes" {
    const SlowReclaim = struct {
        var calls = std.atomic.Value(usize).init(0);
        var selected_count = std.atomic.Value(usize).init(0);

        fn run(
            allocator_arg: std.mem.Allocator,
            _: []const u8,
            selected: []const []const u8,
            _: []const WorktreeStatus.Binding,
            _: WorktreeStatus.Policy,
            _: bool,
            _: bool,
            _: ?WorktreeStatus.Cancellation,
        ) anyerror!WorktreeStatus.ReclaimReport {
            selected_count.store(selected.len, .monotonic);
            _ = calls.fetchAdd(1, .monotonic);
            std.Thread.sleep(300 * std.time.ns_per_ms);
            var report = WorktreeStatus.ReclaimReport.init(allocator_arg);
            report.removed_worktrees = selected.len;
            return report;
        }
    };
    const ImmediateInspectionFailure = struct {
        fn run(
            _: std.mem.Allocator,
            _: []const u8,
            _: []const WorktreeStatus.Binding,
            _: ?WorktreeStatus.Cancellation,
        ) anyerror!WorktreeStatus.Inspection {
            return error.OwnedFixtureRefreshStopped;
        }
    };
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const project_path = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(project_path);
    try WorktreeStatus.savePolicy(
        allocator,
        project_path,
        .{ .allow_reclaim = true, .confirm_each_reclaim = false },
    );
    const quoted_path = try std.json.Stringify.valueAlloc(allocator, project_path, .{});
    defer allocator.free(quoted_path);
    const frame = try std.fmt.allocPrint(
        allocator,
        "{{\"version\":2,\"kind\":\"event\",\"sequence\":1,\"event\":{{\"graphChanged\":{{\"project\":{{\"path\":{s},\"name\":\"Owned fixture\"}},\"nodes\":[],\"edges\":[]}}}}}}",
        .{quoted_path},
    );
    defer allocator.free(frame);
    var app: App = .{
        .allocator = allocator,
        .client = undefined,
        .daemon = undefined,
        .model = GraphModel.Model.init(allocator),
        .worktree_inspect_runner = ImmediateInspectionFailure.run,
        .worktree_reclaim_runner = SlowReclaim.run,
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
    };
    defer {
        app.drainWorktreeInspection();
        app.drainWorktreeReclaim();
        if (app.status_override.len != 0) allocator.free(app.status_override);
        if (app.selected_worktree_path.len != 0) allocator.free(app.selected_worktree_path);
        app.model.deinit();
        app.sidebar_state.deinit();
        app.declared_entry_ids.deinit();
        app.kept_worktree_paths.deinit();
    }
    _ = try app.model.updateFromFrame(frame);
    app.worktree_inspection = .{
        .entries = std.array_list.Managed(WorktreeStatus.Entry).init(allocator),
        .default_branch = try allocator.dupe(u8, "main"),
        .project_path = try allocator.dupe(u8, project_path),
    };
    defer WorktreeStatus.deinitInspection(allocator, &app.worktree_inspection.?);
    app.selected_worktree_path = try allocator.dupe(u8, "C:\\owned-worktree-fixture\\linked");

    var timer = try std.time.Timer.start();
    app.reclaimWorktrees();
    const elapsed = timer.read();

    try std.testing.expect(elapsed < 100 * std.time.ns_per_ms);
    try std.testing.expectEqualStrings("Removing worktrees...", app.status_override);
    const deadline = std.time.milliTimestamp() + 2000;
    while (app.worktree_reclaim_thread != null and std.time.milliTimestamp() < deadline) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
        app.finishWorktreeReclaim();
    }
    try std.testing.expect(app.worktree_reclaim_thread == null);
    try std.testing.expectEqual(@as(usize, 1), SlowReclaim.calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), SlowReclaim.selected_count.load(.monotonic));
    try std.testing.expectEqualStrings("Reading worktrees...", app.status_override);
}

fn runSmokeWorkspaceActions(self: *App) void {
    const script = self.smoke_workspace_actions;
    if (script.len == 0) return;
    const workspace = if (self.workspace) |value| value else return;
    if (workspace.firstLiveSurface() == null) return;
    const default_script = "create,split,select,focus,close,restart";
    const actions = if (std.mem.eql(u8, script, "1")) default_script else script;
    var iterator = std.mem.splitScalar(u8, actions, ',');
    self.smoke_workspace_action_failed = false;
    const initial_tabs = workspace.tabCount();
    const initial_panes = workspacePaneCount(workspace);
    while (iterator.next()) |raw| {
        const action = std.mem.trim(u8, raw, " \t\r\n");
        if (std.mem.eql(u8, action, "create") or std.mem.eql(u8, action, "tab") or std.mem.eql(u8, action, "new")) {
            const before = workspace.tabCount();
            self.handleAction(.new_tab);
            self.smoke_workspace_create_observed = !self.smoke_workspace_action_failed and
                workspace.tabCount() == before + 1;
        } else if (std.mem.eql(u8, action, "split") or std.mem.eql(u8, action, "split-horizontal")) {
            const before = workspacePaneCount(workspace);
            self.handleAction(.split_horizontal);
            self.smoke_workspace_split_observed = !self.smoke_workspace_action_failed and
                workspacePaneCount(workspace) == before + 1;
        } else if (std.mem.eql(u8, action, "split-vertical")) {
            const before = workspacePaneCount(workspace);
            self.handleAction(.split_vertical);
            self.smoke_workspace_split_observed = !self.smoke_workspace_action_failed and
                workspacePaneCount(workspace) == before + 1;
        } else if (std.mem.eql(u8, action, "select")) {
            const before = workspace.layout.selected_tab;
            workspace.dispatchKeyForTest(0x22, true, false);
            self.smoke_workspace_select_observed = workspace.layout.selected_tab != before;
        } else if (std.mem.eql(u8, action, "focus")) {
            if (workspace.layout.selected()) |tab| {
                if (tab.panes.items.len < 2 and workspace.tabCount() > 1)
                    self.handleAction(.select_previous_tab);
            }
            const before = workspace.active_surface;
            workspace.dispatchKeyForTest(0xDD, true, false);
            self.smoke_workspace_focus_observed = workspace.active_surface != before;
        } else if (std.mem.eql(u8, action, "close")) {
            const before = workspacePaneCount(workspace);
            self.handleAction(.close_tab);
            self.smoke_workspace_close_observed = workspacePaneCount(workspace) + 1 == before and
                !self.smoke_workspace_action_failed;
        } else if (std.mem.eql(u8, action, "restart")) {
            const index = workspace.firstLiveSurface() orelse {
                self.smoke_workspace_action_failed = true;
                self.setStatus("Smoke workspace restart has no live surface");
                continue;
            };
            const before_tabs = workspace.tabCount();
            const before_panes = workspacePaneCount(workspace);
            const before_selected = workspace.layout.selected_tab;
            const session = self.allocator.dupe(u8, workspace.surfaces[index].session_name) catch {
                self.smoke_workspace_action_failed = true;
                continue;
            };
            if (!workspace.hasSurface(index) and !workspace.hasAttach(index)) {
                self.smoke_workspace_action_failed = true;
                self.setStatus("Smoke workspace restart has no live slot");
            } else {
                workspace.recreate(index) catch {
                    self.smoke_workspace_action_failed = true;
                    self.setStatus("Smoke workspace restart failed");
                };
                self.smoke_workspace_restart_observed = false;
                self.smoke_restart_index = index;
                self.smoke_restart_session = session;
                if (workspace.tabCount() != before_tabs or
                    workspacePaneCount(workspace) != before_panes or
                    workspace.layout.selected_tab != before_selected)
                {
                    self.smoke_workspace_action_failed = true;
                }
            }
        }
    }
    if (workspace.tabCount() < initial_tabs or workspacePaneCount(workspace) < initial_panes)
        self.smoke_workspace_action_failed = true;
    self.refreshWorkspace();
    self.smoke_workspace_actions_ran = true;
}

fn workspacePaneCount(workspace: anytype) usize {
    var count: usize = 0;
    for (workspace.layout.tabs.items) |tab| count += tab.panes.items.len;
    return count;
}

fn smokeContractPassed(self: *const App) bool {
    const scripted_actions = self.smoke_workspace_actions_ran;
    if (!scripted_actions and self.client.connectionState() != .connected) return false;
    if (scripted_actions) {
        return !self.smoke_workspace_action_failed and
            self.smoke_workspace_create_observed and
            self.smoke_workspace_split_observed and
            self.smoke_workspace_select_observed and
            self.smoke_workspace_focus_observed and
            self.smoke_workspace_close_observed and
            self.smoke_workspace_restart_observed;
    }
    if (!scripted_actions) {
        const value = self.model.graph orelse return false;
        if (value.nodes.items.len < 2) return false;
    }
    const workspace = self.workspace orelse {
        if (scripted_actions) std.debug.print("smoke contract missing workspace\n", .{});
        return false;
    };
    var client: c.RECT = undefined;
    if (c.GetClientRect(self.window.hwnd, &client) == 0) return false;
    const sidebar_width = physicalCoordinate(Tokens.sidebar_width, self.dpi);
    const layout_width = @max(0, client.right - sidebar_width);
    const layout_height = physicalCoordinate(Tokens.workspace_height, self.dpi);
    const workspace_ready = if (scripted_actions)
        workspace.tabCount() > 0
    else
        workspace.hasSurface(0) and workspace.hasSurface(1) and
            workspace.hasAttach(0) and workspace.hasAttach(1);
    const layout_ok = workspace.layoutMatches(
        sidebar_width,
        @max(0, client.bottom - layout_height),
        layout_width,
        layout_height,
    );
    const actions_ok = self.smoke_workspace_actions_ran and
        !self.smoke_workspace_action_failed and
        self.smoke_workspace_create_observed and
        self.smoke_workspace_split_observed and
        self.smoke_workspace_select_observed and
        self.smoke_workspace_focus_observed and
        self.smoke_workspace_close_observed and
        self.smoke_workspace_restart_observed;
    const passed = if (scripted_actions) actions_ok else layout_ok and workspace_ready;
    return passed;
}

fn envFlag(name: []const u8) bool {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return false;
    defer std.heap.page_allocator.free(value);
    return std.mem.eql(u8, value, "1");
}

fn mouseX(lparam: c.LPARAM) i32 {
    return CanvasInput.decodeMouseMessage(lparam).x;
}

fn mouseY(lparam: c.LPARAM) i32 {
    return CanvasInput.decodeMouseMessage(lparam).y;
}

fn clientRight(hwnd: c.HWND) i32 {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    return client.right;
}

fn clientBottom(hwnd: c.HWND) i32 {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    return client.bottom;
}

test "edge drop source remains valid across synchronous capture cancellation" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .client = undefined,
        .daemon = undefined,
        .model = undefined,
        .sidebar_state = Sidebar.State.init(allocator),
        .declared_entry_ids = std.array_list.Managed([]u8).init(allocator),
        .kept_worktree_paths = std.array_list.Managed([]u8).init(allocator),
    };
    defer app.sidebar_state.deinit();
    defer app.declared_entry_ids.deinit();
    defer app.kept_worktree_paths.deinit();
    app.edge_drag_source_id = try allocator.dupe(u8, "source-node");
    app.canvas.beginEdgeDrag(app.edge_drag_source_id, 10, 10);

    const copied = app.copyEdgeDragSourceForDrop() orelse return error.MissingSource;
    defer allocator.free(copied);
    app.cancelCanvasInteraction();

    try std.testing.expectEqualStrings("source-node", copied);
    try std.testing.expectEqual(@as(usize, 0), app.edge_drag_source_id.len);
    try std.testing.expect(!app.canvas.edge_dragging);
}
