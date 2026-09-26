const std = @import("std");
const build_options = @import("build_options");
const DaemonClient = @import("DaemonClient.zig").DaemonClient;
const GraphCanvas = @import("GraphCanvas.zig");
const GdiplusAA = @import("GdiplusAA.zig");
const CanvasInput = @import("CanvasInput.zig");
const CanvasLayoutStore = @import("CanvasLayoutStore.zig");
const GraphContextMenu = @import("GraphContextMenu.zig");
const Forms = @import("Forms.zig");
const EdgeCreation = @import("EdgeCreation.zig");
const NativeForms = @import("NativeForms.zig");
const TemplateLibrary = @import("TemplateLibrary.zig");
const Diagnostics = @import("Diagnostics.zig");
const JumpPalette = @import("JumpPalette.zig");
const NativeDialogs = @import("WindowsNativeDialogs.zig");
const Sidebar = @import("Sidebar.zig");
const GraphModel = @import("GraphModel.zig");
const InputRouter = @import("InputRouter.zig");
const MainWindow = @import("MainWindow.zig");
const TerminalWorkspace = @import("TerminalWorkspace.zig");
const Tokens = @import("DesignTokens.zig");
const Dpi = @import("Dpi.zig");
const AppFont = @import("AppFont.zig");
const Wire = @import("Wire.zig");
const WorktreeStatus = @import("WorktreeStatus.zig");
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
const Win32 = @import("Win32.zig");
const c = Win32.c;

const title = std.unicode.utf8ToUtf16LeStringLiteral("GraphCode Windows");
const workspace_restart_message = "Workspace identity changed or could not be verified. Restart GraphCode before managing workspaces.";
const tray_test_hook_environment = "GRAPHCODE_TRAY_TEST_HOOK";
const daemon_supervisor_test_hook_environment = "GRAPHCODE_DAEMON_SUPERVISOR_TEST_HOOK";
const daemon_supervisor_test_property =
    std.unicode.utf8ToUtf16LeStringLiteral("GraphCode.Windows.DaemonSupervisorState");
extern fn graphcode_pick_folder(owner: c.HWND, buffer: [*]u16, capacity: c.DWORD) callconv(.c) c_int;

fn workspaceUser(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "USERNAME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "USER"),
        else => err,
    };
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
const WorkspaceMutationResult = enum { renamed, deleted, cancelled };
const workspace_delete_confirmation_flags = c.MB_YESNO | c.MB_ICONWARNING | c.MB_DEFBUTTON2;

const WorkspaceMutationApi = struct {
    const reserve = WorkspaceReservation.acquire;
    const windows = WorkspaceProcess.windows;

    fn confirm(owner: c.HWND) c.INT {
        return c.MessageBoxW(
            owner,
            std.unicode.utf8ToUtf16LeStringLiteral("This permanently deletes the workspace folder and all of its projects and loops. Continue?").ptr,
            std.unicode.utf8ToUtf16LeStringLiteral("Delete Workspace").ptr,
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

    fn delete(path: []const u8) !void {
        try std.fs.deleteTreeAbsolute(path);
    }
};

fn requireIdentifiedClosedWorkspace(comptime Api: type, key: [:0]const u16) !void {
    const windows = try Api.windows(key);
    if (windows.unidentified) return error.UnidentifiedWorkspaceWindow;
    if (windows.target != null) return error.WorkspaceInUse;
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
            var directory = try std.fs.openDirAbsolute(source, .{});
            directory.close();
            try Api.delete(source);
            return .deleted;
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
const uia_context_menu_project_path = "C:\\GraphCode\\fixture";
const uia_context_menu_remote_project_path = "ssh://builder/GraphCode";
const uia_context_menu_x: i32 = 160;
const uia_context_menu_y: i32 = 160;

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
    project_new_loop: []const u8,
    project_disclosure: []const u8,
    loop: struct {
        project_path: []const u8,
        index: usize,
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
    selected_worktree_path: []u8 = &.{},
    reclaim_confirmation_armed: bool = false,
    worktree_dialog: ?WorktreeDialog.Dialog = null,
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
    last_connection_state: Wire.ConnectionState = .disconnected,
    last_project_opened: []const u8 = "",
    accepted_subscription: []const u8 = "",
    pending_project_path: []u8 = &.{},
    status_override: []u8 = &.{},
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
        if (self.workspace) |workspace| {
            workspace.deinit();
            self.allocator.destroy(workspace);
        }
        self.client.deinit();
        self.daemon.stop();
        self.tray.remove();
        self.model.deinit();
        if (self.accessibility) |*provider| provider.deinit();
        if (self.worktree_dialog) |*dialog| dialog.deinit();
        if (self.worktree_inspection) |*inspection| {
            WorktreeStatus.deinitInspection(self.allocator, inspection);
        }
        if (self.selected_worktree_path.len != 0) self.allocator.free(self.selected_worktree_path);
        if (self.selected_node_id.len != 0) self.allocator.free(self.selected_node_id);
        if (self.selected_edge_project_path.len != 0) self.allocator.free(self.selected_edge_project_path);
        if (self.selected_edge_id.len != 0) self.allocator.free(self.selected_edge_id);
        if (self.edge_drag_source_id.len != 0) self.allocator.free(self.edge_drag_source_id);
        self.workspace_reservation.deinit();
        if (self.workspace_list) |*list| list.deinit(self.allocator);
        if (self.workspace_path.len != 0) self.allocator.free(self.workspace_path);
        if (self.workspace_identity.len != 0) self.allocator.free(self.workspace_identity);
        if (self.last_project_opened.len != 0) self.allocator.free(self.last_project_opened);
        if (self.accepted_subscription.len != 0) self.allocator.free(self.accepted_subscription);
        if (self.pending_project_path.len != 0) self.allocator.free(self.pending_project_path);
        if (self.pending_rebind_path.len != 0) self.allocator.free(self.pending_rebind_path);
        if (self.pending_sent_path.len != 0) self.allocator.free(self.pending_sent_path);
        if (self.pending_previous_subscription.len != 0) self.allocator.free(self.pending_previous_subscription);
        if (self.status_override.len != 0) self.allocator.free(self.status_override);
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
        // GDI+ may create a process-owned helper window. The daemon handoff
        // and UIA live tests depend on deterministic top-level window and
        // foreground behavior, so keep that visual-only subsystem disabled
        // for both explicit automation hooks.
        if (!daemon_supervisor_test_hook and !uia_gate_hook) GdiplusAA.init();
        try self.window.create(self, &onWindowMessage, title.ptr);
        self.window.key_callback = &onHeaderKey;
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
        const endpoint = self.client.currentEndpointName(self.allocator) catch &.{};
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
                if (Onboarding.showFirstRun(self.window.hwnd, self.allocator, store, initial_backend) catch null) |backend| {
                    self.applyOnboardingBackend(backend);
                }
            }
        }
        self.createEmptyStateControls();
        _ = self.refreshWorkspaceList();
        self.updateNativeChrome(.state_change);
        if (std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_UIA_FIXTURE_ROWS")) |fixture| {
            defer self.allocator.free(fixture);
            self.installUiaFixture(true);
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
            self.workspace = try TerminalWorkspace.Workspace.init(self.window.hwnd, self.allocator);
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
        self.client.setCallback(&onDaemonFrame, self);
        self.client.connect();
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
        var incoming_project_path: ?[]u8 = null;
        defer if (incoming_project_path) |path| self.allocator.free(path);
        if (self.pending_rebind_path.len != 0 and Wire.eventKind(frame) == .graph_changed) {
            const path = Wire.copyGraphChangedProjectPath(self.allocator, frame) catch null;
            if (path) |value| {
                incoming_project_path = value;
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
                        self.rebindWorkspace(graph.project.path);
                        if (queued_v1) self.sendPendingOpen();
                    } else if (self.pending_rebind_path.len == 0) {
                        self.rebindWorkspace(graph.project.path);
                    }
                    if (self.canvas.selected_edge) |edge| {
                        if (edge >= graph.edges.items.len) self.canvas.selected_edge = null;
                    }
                    self.remapSelection();
                    self.rebindWorkspace(graph.project.path);
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
                    if (self.pending_rebind_path.len == 0) {
                        if (self.model.graph) |current_graph| self.queueProject(current_graph.project.path);
                    }
                    self.clampSidebarScroll();
                    self.refreshWorkspace();
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
                        if (!std.mem.eql(u8, response_id, &request_id)) return;
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
    }

    fn refreshWorkspace(self: *App) void {
        const workspace = if (self.workspace) |value| value else return;
        const graph = if (self.model.graph) |value| value else return;
        if (graph.nodes.items.len > 0 and !workspace.hasSurface(0)) {
            workspace.openNode(0, graph.nodes.items[0].id) catch {
                self.setStatus("Unable to attach terminal A");
            };
        }

        if (graph.nodes.items.len > 1 and !workspace.hasSurface(1)) {
            workspace.openNode(1, graph.nodes.items[1].id) catch {
                self.setStatus("Unable to attach terminal B");
            };
        }
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
        if (path.len == 0) return;
        self.surface = .project;
        self.workspace_controls.panel_visible = false;
        self.layoutWorkspace();
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
        var path: [32768]u16 = undefined;
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
        defer self.allocator.free(utf8);
        self.openProject(utf8);
    }

    pub fn openGlobalOverview(self: *App) void {
        self.surface = .overview;
        self.workspace_controls.panel_visible = false;
        self.layoutWorkspace();
        self.layoutEmptyStateControls();
        self.syncAccessibility();
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
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
        if (self.pending_project_path.len == 0 or self.client.connectionState() != .connected) return;
        const path = self.pending_project_path;
        self.pending_project_path = &.{};
        self.openProject(path);
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
        const selected = self.model.selectProject(path);
        if (selected) self.client.setSubgraphAddress(null);
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
        if (self.edge_drag_source_id.len != 0) {
            self.allocator.free(self.edge_drag_source_id);
            self.edge_drag_source_id = &.{};
        }
        _ = c.ReleaseCapture();
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

    /// A single selectable branch/worktree for the node-creation form's
    /// prospective picker. Reuses NativeForms.WorktreeChoice (rather than a
    /// duplicate type) so App can hand its projection straight to
    /// NativeForms.node/nodeWithTemplates without a conversion.
    pub const WorktreeChoice = NativeForms.WorktreeChoice;

    /// Projects `self.worktree_inspection` into the caller-owned list of
    /// existing worktree/branch choices a node-creation picker can offer.
    /// Returns an empty slice — never a fabricated entry — when there is no
    /// inspection to draw from (for example when creating a node for
    /// `graphcode://global`, or before any worktree inspection has run for the
    /// current project); callers must treat an empty slice as "no existing
    /// worktrees" rather than an error.
    fn worktreeChoicesForNodeForm(self: *const App, allocator: std.mem.Allocator) ![]WorktreeChoice {
        const inspection = self.worktree_inspection orelse return &.{};
        var choices = try allocator.alloc(WorktreeChoice, inspection.entries.items.len);
        errdefer allocator.free(choices);
        for (inspection.entries.items, 0..) |entry, index| {
            choices[index] = .{
                .path = entry.path,
                .branch = entry.branch,
                .is_default = entry.branch.len != 0 and std.mem.eql(u8, entry.branch, inspection.default_branch),
            };
        }
        return choices;
    }

    fn createNode(self: *App) void {
        const current_path = self.currentProject() orelse if (self.surface == .overview)
            "graphcode://global"
        else
            return;
        Diagnostics.record(self.allocator, "action", "create-node");
        const path = self.allocator.dupe(u8, current_path) catch return;
        defer self.allocator.free(path);
        const settings = self.product_settings orelse return;
        // Generated before the dialog opens (rather than at send time, as every other
        // draft field is) so a file picked mid-dialog can be copied straight into the
        // attachments directory this node will end up owning, instead of a temporary
        // location that would need a second copy once the real id is known.
        var draft_id_buffer: [36]u8 = undefined;
        Forms.generateDraftId(&draft_id_buffer);
        const initial = Forms.NodeDraft{
            .title = "",
            .backend = settings.default_backend,
            .model_tier = settings.default_model,
            .claude_permissions = settings.claude_permissions,
            .copilot_permissions = settings.copilot_permissions,
            .briefing_enabled = settings.briefing,
            .activity_enabled = settings.activity,
        };
        // Allocated once and shared by both the plain and templated forms below
        // so a project with no worktree inspection yet (or none at all, e.g.
        // graphcode://global) degrades to the same explicit empty picker either
        // form would otherwise have to special-case on its own.
        const choices = self.worktreeChoicesForNodeForm(self.allocator) catch {
            self.setStatus("Unable to prepare worktree choices");
            return;
        };
        defer self.allocator.free(choices);
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
            var draft = NativeForms.node(self.window.hwnd, self.allocator, path, &draft_id_buffer, choices, initial) catch |form_err| {
                self.setStatus(nodeFormErrorStatus(form_err));
                return;
            } orelse return;
            defer draft.deinit(self.allocator);
            self.client.sendCreateNodeDraft(path, draft);
            return;
        };
        defer templates.deinit();
        if (templates.templates.items.len == 0) {
            var draft = NativeForms.node(self.window.hwnd, self.allocator, path, &draft_id_buffer, choices, initial) catch |err| {
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
            const result = NativeForms.nodeWithTemplates(self.window.hwnd, self.allocator, path, &draft_id_buffer, choices, current, true) catch |err| {
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
                    const selected = NativeForms.templatePicker(self.window.hwnd, self.allocator, labels.items) catch {
                        self.setStatus("Unable to open saved template picker");
                        return;
                    };
                    if (selected) |index| TemplateLibrary.applyOwned(&current, templates.templates.items[index], self.allocator) catch {
                        self.setStatus("Unable to apply selected template");
                        return;
                    };
                },
            }
        }
    }

    fn nodeFormErrorStatus(err: anyerror) []const u8 {
        return switch (err) {
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
            .failed => |message| {
                self.setStatus(message);
                self.allocator.free(message);
            },
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
        if (!self.model.isCompositeOpen() and
            (std.mem.eql(u8, graph.nodes.items[index].loop_type, "composite") or
                std.mem.eql(u8, graph.nodes.items[index].loop_type, "proactive")))
        {
            self.showCompositeGroup(graph.nodes.items[index]);
            return;
        }
        if (self.model.isCompositeOpen()) {
            self.setStatus("Composite templates have no terminal until the group is piloted");
            return;
        }
        const workspace = if (self.workspace) |value| value else return;
        self.workspace_is_quick_chat = false;
        self.surface = .workspace;
        self.workspace_controls.panel_visible = true;
        self.layoutWorkspace();
        self.layoutEmptyStateControls();
        workspace.openNode(0, graph.nodes.items[index].id) catch {
            self.setStatus("Unable to open selected node");
        };
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
        const graph = self.model.graph orelse return;
        if (index >= graph.edges.items.len) return;
        const edge = graph.edges.items[index];
        if (!GraphContextMenu.canEditEdge(edge.id)) {
            self.setStatus("Cannot edit an edge without a stable identifier");
            return;
        }
        const project_path = self.allocator.dupe(u8, graph.project.path) catch return;
        defer self.allocator.free(project_path);
        const edge_id = self.allocator.dupe(u8, edge.id) catch return;
        defer self.allocator.free(edge_id);
        const initial_from = self.allocator.dupe(u8, edge.from) catch return;
        defer self.allocator.free(initial_from);
        const initial_to = self.allocator.dupe(u8, edge.to) catch return;
        defer self.allocator.free(initial_to);
        const initial_kind = self.allocator.dupe(u8, edge.kind) catch return;
        defer self.allocator.free(initial_kind);
        const draft = NativeForms.edge(self.window.hwnd, self.allocator, .{
            .from = initial_from,
            .to = initial_to,
            .kind = initial_kind,
        }) catch {
            self.setStatus("Unable to open edge form");
            return;
        } orelse return;
        defer self.allocator.free(draft.from);
        defer self.allocator.free(draft.to);
        defer self.allocator.free(draft.kind);
        Forms.validateEdge(draft) catch {
            self.setStatus("Invalid edge form");
            return;
        };
        const updated_graph = self.model.graph orelse return;
        const updated_index = GraphModel.findEdgeIndexByID(updated_graph.edges.items, edge_id) orelse {
            self.setStatus("Edge changed while editing");
            return;
        };
        const from_index = GraphModel.findNodeIndexByID(updated_graph.nodes.items, draft.from) orelse {
            self.setStatus("Source loop changed while editing edge");
            return;
        };
        const to_index = GraphModel.findNodeIndexByID(updated_graph.nodes.items, draft.to) orelse {
            self.setStatus("Target loop changed while editing edge");
            return;
        };
        self.client.sendDeleteEdge(project_path, updated_graph.edges.items[updated_index].id);
        self.client.sendCreateEdge(
            project_path,
            updated_graph.nodes.items[from_index].id,
            updated_graph.nodes.items[to_index].id,
            draft.kind,
        );
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
        const project_path = self.allocator.dupe(u8, graph.project.path) catch return;
        defer self.allocator.free(project_path);
        const node_id = self.allocator.dupe(u8, graph.nodes.items[index].id) catch return;
        defer self.allocator.free(node_id);
        const composite = std.mem.eql(u8, graph.nodes.items[index].loop_type, "proactive") or
            std.mem.eql(u8, graph.nodes.items[index].loop_type, "composite");
        const unwired = self.nodeIsUnwired(graph.nodes.items[index].id);
        GraphContextMenu.show(
            self.window.hwnd,
            .{ .node = .{
                .project_path = project_path,
                .id = node_id,
                .composite = composite,
                .can_arm = std.mem.eql(u8, graph.nodes.items[index].pilot_state, "piloted"),
                .unwired = unwired,
                .follows_template = graph.nodes.items[index].follows_template,
                .resolved = isResolvedLoopState(graph.nodes.items[index].state),
            } },
            x,
            y,
            self,
            &onContextAction,
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
            1 => .{ .project = .{ .path = uia_context_menu_project_path, .remote = false } },
            2 => .{ .project = .{ .path = uia_context_menu_remote_project_path, .remote = true } },
            3 => blk: {
                const graph = self.model.graph orelse return;
                if (graph.nodes.items.len == 0) return;
                break :blk .{ .node = .{
                    .project_path = graph.project.path,
                    .id = graph.nodes.items[0].id,
                    .composite = std.mem.eql(u8, graph.nodes.items[0].loop_type, "composite") or
                        std.mem.eql(u8, graph.nodes.items[0].loop_type, "proactive"),
                    .can_arm = std.mem.eql(u8, graph.nodes.items[0].pilot_state, "piloted"),
                    .unwired = self.nodeIsUnwired(graph.nodes.items[0].id),
                    .follows_template = graph.nodes.items[0].follows_template,
                    .resolved = isResolvedLoopState(graph.nodes.items[0].state),
                } };
            },
            4 => return self.showBackgroundContextMenu(uia_context_menu_x, uia_context_menu_y),
            5 => .quick_chats,
            // Sidebar-parity-only targets: expose the composite and unwired
            // loop-menu variants that target 3 (the plain wired first node)
            // cannot reach, so the live gate can assert every menu shape
            // GraphContextMenu.show() renders for a `.node` target.
            6 => blk: {
                const graph = self.model.graph orelse return;
                if (graph.nodes.items.len < 2) return;
                const node = graph.nodes.items[1];
                break :blk .{ .node = .{
                    .project_path = graph.project.path,
                    .id = node.id,
                    .composite = std.mem.eql(u8, node.loop_type, "composite") or
                        std.mem.eql(u8, node.loop_type, "proactive"),
                    .can_arm = std.mem.eql(u8, node.pilot_state, "piloted"),
                    .unwired = self.nodeIsUnwired(node.id),
                    .follows_template = node.follows_template,
                    .resolved = isResolvedLoopState(node.state),
                } };
            },
            7 => blk: {
                const graph = self.model.graph orelse return;
                const index = GraphModel.findNodeIndexByID(
                    graph.nodes.items,
                    "77777777-7777-4777-8777-777777777777",
                ) orelse return;
                const node = graph.nodes.items[index];
                break :blk .{ .node = .{
                    .project_path = graph.project.path,
                    .id = node.id,
                    .composite = std.mem.eql(u8, node.loop_type, "composite") or
                        std.mem.eql(u8, node.loop_type, "proactive"),
                    .can_arm = std.mem.eql(u8, node.pilot_state, "piloted"),
                    .unwired = self.nodeIsUnwired(node.id),
                    .follows_template = node.follows_template,
                    .resolved = isResolvedLoopState(node.state),
                } };
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

    fn ensureUiaFixtureProject(self: *App, min_nodes: usize) void {
        const needs_project = self.model.graph == null;
        const needs_nodes = if (self.model.graph) |graph| graph.nodes.items.len < min_nodes else true;
        if (!needs_project and !needs_nodes) return;
        const frame =
            \\{"version":2,"kind":"event","sequence":63,"event":{"graphChanged":{"project":{"path":"C:\\GraphCode\\fixture","name":"Fixture project"},"nodes":[{"id":"uia-form-source","title":"Planner","state":"idle"},{"id":"uia-form-target","title":"Builder","state":"idle"}],"edges":[]}}}
        ;
        _ = self.model.updateFromFrame(frame) catch return;
        self.surface = .project;
    }

    fn presentUiaEdgeForm(self: *App) void {
        self.ensureUiaFixtureProject(2);
        self.createEdge();
    }

    fn presentUiaWorktreePolicyForm(self: *App) void {
        self.ensureUiaFixtureProject(0);
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
        self.ensureUiaFixtureProject(0);
        const graph = self.model.graph orelse return;
        if (self.worktree_inspection == null) {
            var entries = std.array_list.Managed(WorktreeStatus.Entry).init(self.allocator);
            entries.append(.{
                .path = self.allocator.dupe(u8, "C:\\GraphCode\\fixture-worktrees\\reclaimable") catch return,
                .branch = self.allocator.dupe(u8, "uia-fixture-reclaimable") catch return,
                .size_bytes = 1024,
                .pushed = true,
                .landed = true,
            }) catch return;
            entries.append(.{
                .path = self.allocator.dupe(u8, "C:\\GraphCode\\fixture-worktrees\\dirty") catch return,
                .branch = self.allocator.dupe(u8, "uia-fixture-dirty") catch return,
                .size_bytes = 2048,
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

    fn inspectWorktreesImpl(self: *App, show_sweep: bool) void {
        const current_graph = self.model.graph orelse {
            self.setStatus("Worktrees require a local filesystem project");
            return;
        };
        if (!current_graph.project.isLocalFilesystem()) {
            self.setStatus("Worktrees require a local filesystem project");
            return;
        }
        const path = current_graph.project.path;
        if (path.len == 0) {
            self.setStatus("No project selected for worktree inspection");
            return;
        }
        var bindings = std.array_list.Managed(WorktreeStatus.Binding).init(self.allocator);
        defer bindings.deinit();
        if (self.model.graph) |graph| {
            for (graph.nodes.items) |node| {
                if (node.worktree_path.len != 0) bindings.append(.{ .path = node.worktree_path }) catch {};
            }
        }
        const inspection = WorktreeStatus.inspect(self.allocator, path, bindings.items) catch |err| {
            self.setStatus(switch (err) {
                error.EmptyProjectPath => "Worktree inspection needs a project path",
                error.GitFailed => "Worktree inspection failed: git returned an error",
                else => "Worktree inspection failed",
            });
            return;
        };
        if (self.worktree_inspection) |*old| {
            WorktreeStatus.deinitInspection(self.allocator, old);
        }
        if (self.worktree_dialog) |*dialog| {
            dialog.deinit();
            self.worktree_dialog = null;
        }
        if (self.selected_worktree_path.len != 0) {
            self.allocator.free(self.selected_worktree_path);
            self.selected_worktree_path = &.{};
        }
        self.worktree_inspection = inspection;
        self.worktree_dialog = WorktreeDialog.Dialog.init(
            self.allocator,
            path,
            inspection.entries.items,
            WorktreeStatus.loadPolicy(self.allocator, path),
        ) catch null;
        self.syncAccessibility();
        self.clampSidebarScroll();
        const summary = WorktreeStatus.summarize(inspection.entries.items);
        const message = std.fmt.allocPrint(
            self.allocator,
            "Worktrees: {d} total · {d} reclaimable · {d} blocked",
            .{ summary.total, summary.reclaimable, summary.blocked },
        ) catch {
            self.setStatus("Worktree inspection complete");
            return;
        };
        self.replaceStatus(message);
        if (show_sweep and !envFlag("GRAPHCODE_UIA_GATE")) self.presentWorktreeSweep();
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
        const removed = WorktreeStatus.reclaimSelectedWithPolicyMode(
            self.allocator,
            project_path,
            selected.items,
            bindings.items,
            explicit_policy,
            result.destructive_confirmed,
            result.destructive_confirmed,
        ) catch |err| {
            self.setStatus(switch (err) {
                error.UnsafeSelection => "Worktree Sweep blocked an unsafe selection",
                error.GitFailed => "Worktree Sweep failed: git refused removal",
                else => "Worktree Sweep failed",
            });
            return;
        };
        const message = std.fmt.allocPrint(self.allocator, "Worktree Sweep removed {d} worktrees", .{removed}) catch {
            self.setStatus("Worktree Sweep complete");
            return;
        };
        self.replaceStatus(message);
        self.inspectWorktreesImpl(false);
    }

    fn installUiaFixture(self: *App, reset_sidebar: bool) void {
        if (reset_sidebar and envFlag("GRAPHCODE_UIA_RESET_SIDEBAR")) self.sidebar_state.clearExpandedNodes();
        const graph_frame =
            \\{"version":2,"kind":"event","sequence":1,"event":{"graphChanged":{"id":"uia-graph","project":{"path":"C:\\GraphCode\\fixture","name":"UIA project","remote":false},"nodes":[{"id":"11111111-1111-4111-8111-111111111111","title":"UIA loop A","loopType":"goalBased","state":"succeeded","activity":"checking tests","presence":{"presence":"idle","confidence":"reported"},"createdAt":788918400,"goal":{"summary":"All tests pass","predicate":"swift test","metric":{"command":"coverage","direction":"maximize"}},"metricHistory":[{"value":1},{"value":2},{"value":3}],"usage":{"inputTokens":1200,"outputTokens":345},"modelTier":"capable","worktreeBinding":{"path":"C:\\fixture-safe","branch":"feature/parity"}},{"id":"22222222-2222-4222-8222-222222222222","title":"UIA loop B","loopType":"proactive","state":"running","activity":"needs response","presence":{"presence":"awaitingInput","confidence":"reported"},"createdAt":788918400,"usage":{"inputTokens":12,"outputTokens":34},"subGraph":{"nodes":[{"id":"55555555-5555-4555-8555-555555555555","title":"UIA nested A","loopType":"turnBased","state":"idle"},{"id":"66666666-6666-4666-8666-666666666666","title":"UIA nested B","loopType":"goalBased","state":"running"}]}}],"edges":[{"id":"88888888-8888-4888-8888-888888888888","from":"11111111-1111-4111-8111-111111111111","to":"22222222-2222-4222-8222-222222222222","kind":"handoff"}]}}}
        ;
        const chats_frame =
            \\{"version":2,"kind":"event","sequence":2,"event":{"quickChatsListed":[{"id":"33333333-3333-4333-8333-333333333333","title":"UIA chat A","backend":"claudeCode","createdAt":0,"activity":null},{"id":"44444444-4444-4444-8444-444444444444","title":"UIA chat B","backend":"copilot","createdAt":1,"activity":null}]}}
        ;
        const projects_frame =
            \\{"version":2,"kind":"event","sequence":3,"event":{"recentProjectsListed":[{"path":"C:\\GraphCode\\fixture","name":"Fixture local"},{"path":"ssh://builder/GraphCode","name":"Fixture remote"}]}}
        ;
        _ = self.model.updateFromFrame(graph_frame) catch {};
        _ = self.model.updateFromFrame(chats_frame) catch {};
        _ = self.model.updateFromFrame(projects_frame) catch {};
        if (self.model.quick_chats.items.len == 0) {
            self.model.quick_chats.append(.{
                .id = self.allocator.dupe(u8, "33333333-3333-4333-8333-333333333333") catch return,
                .title = self.allocator.dupe(u8, "UIA chat A") catch return,
                .backend = self.allocator.dupe(u8, "claudeCode") catch return,
            }) catch return;
            self.model.quick_chats.append(.{
                .id = self.allocator.dupe(u8, "44444444-4444-4444-8444-444444444444") catch return,
                .title = self.allocator.dupe(u8, "UIA chat B") catch return,
                .backend = self.allocator.dupe(u8, "copilot") catch return,
            }) catch return;
        }
        const project = std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_GATE_CWD") catch
            self.allocator.dupe(u8, "C:\\GraphCode\\fixture") catch return;
        var inspection = WorktreeStatus.Inspection{
            .entries = std.array_list.Managed(WorktreeStatus.Entry).init(self.allocator),
            .default_branch = self.allocator.dupe(u8, "main") catch {
                self.allocator.free(project);
                return;
            },
            .project_path = project,
        };
        inspection.entries.append(.{
            .path = self.allocator.dupe(u8, "C:\\fixture-safe") catch return,
            .branch = self.allocator.dupe(u8, "safe") catch return,
            .pushed = true,
            .landed = true,
        }) catch return;
        inspection.entries.append(.{
            .path = self.allocator.dupe(u8, "C:\\fixture-unsafe") catch return,
            .branch = self.allocator.dupe(u8, "unsafe") catch return,
            .dirty = true,
            .pushed = true,
            .landed = true,
        }) catch return;
        self.worktree_inspection = inspection;
        self.worktree_dialog = WorktreeDialog.Dialog.init(
            self.allocator,
            project,
            inspection.entries.items,
            .{ .allow_reclaim = true },
        ) catch null;
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
    }

    /// True once there is a worktree row the reveal/reclaim commands could
    /// actually act on: either the sidebar's single-selection shortcut has a
    /// path, or the Worktrees dialog itself has a checked row. Mirrors the
    /// menu's contextual enablement in MainWindow.updateMenu so a command
    /// that is enabled can always make progress instead of only reporting
    /// "select a row first".
    fn worktreeRowSelected(self: *const App) bool {
        if (self.selected_worktree_path.len != 0) return true;
        if (self.worktree_dialog) |dialog| return dialog.selectedCount() != 0;
        return false;
    }

    fn reclaimWorktrees(self: *App) void {
        const current_graph = self.model.graph orelse {
            self.setStatus("Worktrees require a local filesystem project");
            return;
        };
        if (!current_graph.project.isLocalFilesystem()) {
            self.setStatus("Worktrees require a local filesystem project");
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
        const removed = WorktreeStatus.reclaimSelectedWithPolicy(
            self.allocator,
            path,
            selected_list.items,
            bindings.items,
            policy,
            true,
        ) catch |err| {
            self.reclaim_confirmation_armed = false;
            self.setStatus(switch (err) {
                error.GitFailed => "Reclaim failed: git refused a selected worktree",
                error.PolicyDisabled => "Reclaim disabled by project worktree policy",
                error.ConfirmationRequired => "Reclaim confirmation required",
                error.UnsafeSelection => "Reclaim blocked: selected worktree is unsafe",
                else => "Reclaim failed",
            });
            return;
        };
        self.reclaim_confirmation_armed = false;
        const message = std.fmt.allocPrint(
            self.allocator,
            "Reclaimed {d} selected worktrees",
            .{removed},
        ) catch {
            self.setStatus("Reclaim complete");
            return;
        };
        self.replaceStatus(message);
        self.inspectWorktreesImpl(false);
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
            if (WorktreeStatus.decision(entry) != .reclaimable) return false;
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
            WorktreeStatus.decision(dialog.rows.items[index].entry) != .reclaimable) return false;
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
        if (WorktreeStatus.decision(dialog.rows.items[index].entry) != .reclaimable) return false;
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
            self.model.deinit();
            self.model = GraphModel.Model.init(self.allocator);
            self.surface = .overview;
            self.layoutEmptyStateControls();
            self.syncAccessibility();
            _ = c.InvalidateRect(self.window.hwnd, null, 0);
            return;
        }
        if (mutation == 10) {
            const frame =
                \\{"version":2,"kind":"event","sequence":50,"event":{"graphChanged":{"project":{"path":"C:\\GraphCode\\empty","name":"Empty project"},"nodes":[],"edges":[]}}}
            ;
            _ = self.model.updateFromFrame(frame) catch return;
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
            self.deleteProjectLoops("C:\\GraphCode\\empty");
            return;
        }
        if (mutation == 13) {
            const frame =
                \\{"version":2,"kind":"event","sequence":51,"event":{"graphChanged":{"project":{"path":"C:\\GraphCode\\empty","name":"Empty project"},"nodes":[{"id":"edge-source","title":"Planner","state":"idle"},{"id":"edge-target","title":"Builder","state":"idle"}],"edges":[{"id":"edge-delete","from":"edge-source","to":"edge-target","kind":"handoff"}]}}}
            ;
            _ = self.model.updateFromFrame(frame) catch return;
            self.deleteEdge(0);
            return;
        }
        if (mutation == 14) {
            const frame =
                \\{"version":2,"kind":"event","sequence":52,"event":{"graphChanged":{"id":"uia-jump-graph","project":{"path":"C:\\GraphCode\\jump-fixture","name":"Jump fixture","remote":false},"nodes":[{"id":"jump-cross-project","title":"UIA loop C","loopType":"timeBased","state":"awaitingInput"}],"edges":[]}}}
            ;
            _ = self.model.updateFromFrame(frame) catch return;
            _ = self.model.setSelectedID("11111111-1111-4111-8111-111111111111");
            self.jumpToNode();
            return;
        }
        if (mutation == 15) {
            self.openProductSettings();
            return;
        }
        if (mutation == 16) {
            const project_path = "C:\\GraphCode\\fixture";
            if (self.model.graphFor(project_path)) |graph| {
                if (GraphModel.findNodeIndexByID(graph.nodes.items, "77777777-7777-4777-8777-777777777777") == null) {
                    const extra = GraphModel.Node{
                        .id = self.allocator.dupe(u8, "77777777-7777-4777-8777-777777777777") catch return,
                        .title = self.allocator.dupe(u8, "UIA loop C") catch return,
                        .loop_type = self.allocator.dupe(u8, "turnBased") catch return,
                        .state = self.allocator.dupe(u8, "idle") catch return,
                        .activity = self.allocator.dupe(u8, "") catch return,
                        .presence = self.allocator.dupe(u8, "idle") catch return,
                    };
                    if (self.model.graph) |*current| if (std.mem.eql(u8, current.project.path, project_path)) {
                        current.nodes.append(extra) catch return;
                    };
                    for (self.model.graphs.items) |*summary| {
                        if (!std.mem.eql(u8, summary.project.path, project_path)) continue;
                        summary.nodes.append(.{
                            .id = self.allocator.dupe(u8, extra.id) catch return,
                            .title = self.allocator.dupe(u8, extra.title) catch return,
                            .loop_type = self.allocator.dupe(u8, extra.loop_type) catch return,
                            .state = self.allocator.dupe(u8, extra.state) catch return,
                            .activity = self.allocator.dupe(u8, extra.activity) catch return,
                            .presence = self.allocator.dupe(u8, extra.presence) catch return,
                        }) catch return;
                    }
                }
            } else return;
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
                if (row.kind != .loop or row.depth != 0 or row.project_path == null or !std.mem.eql(u8, row.project_path.?, "C:\\GraphCode\\fixture")) continue;
                if (row.index == 0) start_y = row.top + 8;
                if (row.index == 2) drop_y = row.top + 20;
            }
            if (start_y) |drag_start| {
                self.beginSidebarRootDrag("C:\\GraphCode\\fixture", "11111111-1111-4111-8111-111111111111", drag_start);
                self.updateSidebarRootDrag(drop_y orelse (drag_start + 32));
                _ = self.completeSidebarRootDrag(drop_y orelse (drag_start + 32));
            }
            return;
        }
        if (mutation == 17) {
            self.handleContextAction(.move_project, .{ .project = .{ .path = "C:\\GraphCode\\fixture", .remote = false } });
            return;
        }
        if (mutation == 18) {
            const baseline =
                \\{"version":2,"kind":"event","sequence":54,"event":{"graphChanged":{"id":"uia-activity","project":{"path":"C:\\GraphCode\\fixture","name":"UIA project","remote":false},"nodes":[{"id":"act-1","title":"Activity A","loopType":"goalBased","state":"idle"},{"id":"act-2","title":"Activity B","loopType":"goalBased","state":"idle"},{"id":"act-3","title":"Activity C","loopType":"goalBased","state":"idle"},{"id":"act-4","title":"Activity D","loopType":"goalBased","state":"idle"},{"id":"act-5","title":"Activity E","loopType":"goalBased","state":"idle"}],"edges":[]}}}
            ;
            const changed =
                \\{"version":2,"kind":"event","sequence":55,"event":{"graphChanged":{"id":"uia-activity","project":{"path":"C:\\GraphCode\\fixture","name":"UIA project","remote":false},"nodes":[{"id":"act-1","title":"Activity A","loopType":"goalBased","state":"succeeded"},{"id":"act-2","title":"Activity B","loopType":"goalBased","state":"failed"},{"id":"act-3","title":"Activity C","loopType":"goalBased","state":"awaitingInput"},{"id":"act-4","title":"Activity D","loopType":"goalBased","state":"blocked"},{"id":"act-5","title":"Activity E","loopType":"goalBased","state":"running"}],"edges":[]}}}
            ;
            _ = self.model.updateFromFrame(baseline) catch return;
            _ = self.model.updateFromFrame(changed) catch return;
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
            self.model.deinit();
            self.model = GraphModel.Model.init(self.allocator);
            self.installUiaFixture(false);
            self.surface = .project;
            self.workspace_controls.panel_visible = false;
            self.layoutWorkspace();
            self.layoutEmptyStateControls();
            self.syncAccessibility();
            _ = c.InvalidateRect(self.window.hwnd, null, 0);
            return;
        }
        const dialog = if (self.worktree_dialog) |*value| value else return;
        switch (mutation) {
            1 => {
                if (dialog.rows.items.len > 1)
                    std.mem.swap(WorktreeDialog.Row, &dialog.rows.items[0], &dialog.rows.items[1]);
            },
            2 => {
                const target = for (dialog.rows.items, 0..) |row, index| {
                    if (std.mem.eql(u8, row.entry.path, "C:\\fixture-safe")) break index;
                } else return;
                _ = dialog.rows.orderedRemove(target);
                if (self.selected_worktree_path.len != 0) {
                    self.allocator.free(self.selected_worktree_path);
                    self.selected_worktree_path = &.{};
                }
            },
            3 => {
                const target = for (dialog.rows.items, 0..) |row, index| {
                    if (std.mem.eql(u8, row.entry.path, "C:\\fixture-unsafe")) break index;
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
        try WorktreeStatus.savePolicy(self.allocator, path, policy);
        if (self.worktree_dialog) |*dialog| dialog.setPolicy(policy);
        self.setStatus("Worktree policy saved");
    }

    fn editWorktreePolicy(self: *App) void {
        const project_path = self.currentProject() orelse {
            self.setStatus("Open a project before changing project settings");
            return;
        };
        if (envFlag("GRAPHCODE_UIA_GATE") and !envFlag("GRAPHCODE_UIA_SHOW_DIALOGS")) {
            self.setStatus("Project settings opened");
            return;
        }
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

    fn saveCurrentWorktreePolicy(self: *App) void {
        const dialog = self.worktree_dialog orelse {
            self.setStatus("Inspect worktrees before saving policy");
            return;
        };
        self.saveWorktreePolicy(dialog.policy) catch {
            self.setStatus("Unable to save worktree policy");
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
        _ = WorktreeStatus.reclaimSelectedWithPolicy(
            self.allocator,
            graph.project.path,
            &selected,
            bindings.items,
            .{ .allow_reclaim = true, .confirm_each_reclaim = false },
            true,
        ) catch |err| {
            self.setStatus(switch (err) {
                error.UnsafeSelection => "This worktree is no longer safe to reclaim",
                error.GitFailed => "Git refused to remove the worktree",
                else => "Unable to reclaim the worktree",
            });
            return;
        };
        self.setStatus("Resolved worktree reclaimed");
        self.inspectWorktrees();
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
            if (WorktreeStatus.decision(inspection.entries.items[@intCast(next)]) == .reclaimable) {
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
        const viewport_bottom = client.bottom - Tokens.workspace_height;
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
            Sidebar.maxScroll(&self.model, inspection, client.bottom - Tokens.workspace_height, &self.sidebar_state),
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
                self.selectNextAttention();
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
                self.selectNextNode();
                _ = c.InvalidateRect(self.window.hwnd, null, 0);
            },
            .select_previous => {
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
            .show_graph => {
                self.surface = .project;
                self.workspace_controls.panel_visible = false;
                self.workspace_controls.apply(.show_graph);
                self.layoutWorkspace();
                self.layoutEmptyStateControls();
                _ = c.InvalidateRect(self.window.hwnd, null, 0);
            },
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
        app.dispatchWorkspaceKey(key, ctrl, shift);
    }

    fn dispatchWorkspaceKey(self: *App, key: usize, ctrl: bool, shift: bool) void {
        self.handleAction(InputRouter.keyAction(key, ctrl, shift));
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
        MainWindow.updateMenu(self.window.hwnd, .{
            .has_project = self.model.graph != null,
            .can_worktrees = if (self.model.graph) |graph| graph.project.isLocalFilesystem() else false,
            .worktree_dialog_open = self.worktree_dialog != null,
            .worktree_row_selected = self.worktreeRowSelected(),
            .has_workspace = self.workspace != null and self.model.graph != null,
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

    fn replaceStatus(self: *App, value: []u8) void {
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
        if (self.worktree_inspection) |*inspection| {
            const policy = if (self.worktree_dialog) |dialog| dialog.policy else WorktreeStatus.Policy{};
            if (GraphCanvas.headerWorktreeNotice(&self.model, inspection, policy)) {
                header.notice = WorktreeStatus.summarize(inspection.entries.items);
                header.notice_name = self.model.currentGraph().?.project.name;
            }
        }
        return header;
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
                if (self.surface == .workspace or self.workspace_controls.panel_visible) workspace.focus(workspace.active_surface);
            }
        }
        self.syncHeaderFocus();
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
            .inspect_worktrees => self.inspectWorktrees(),
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
        provider.syncCanvasBounds((AccessibilityBounds{ .logical = canvas_rect }).physicalRect(self.dpi));
        var sidebar_rows = Sidebar.appendRows(
            self.allocator,
            &self.model,
            if (self.worktree_inspection) |*value| value else null,
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

        for (sidebar_rows.items) |row| {
            const bounds = c.RECT{ .left = 12, .top = row.top - 3, .right = 232, .bottom = row.top + 23 };
            switch (row.kind) {
                .local_heading => self.appendAccessibilityElement(&elements, &owned_identities, "sidebar-section", "local", "Local Projects", 1, .{ .logical = bounds }, false, false) catch return,
                .remote_heading => self.appendAccessibilityElement(&elements, &owned_identities, "sidebar-section", "remote", "Remote Repositories", 1, .{ .logical = bounds }, false, false) catch return,
                .project => {
                    const project = self.model.recent_projects.items[row.index];
                    self.appendAccessibilityElement(&elements, &owned_identities, "project", project.path, project.name, 1, .{ .logical = bounds }, false, false) catch return;
                },
                .open_project => if (row.project_path) |path| if (self.model.graphFor(path)) |graph| {
                    self.appendAccessibilityElement(&elements, &owned_identities, "open-project", path, graph.project.name, 1, .{ .logical = bounds }, self.model.selected_project_path != null and std.mem.eql(u8, self.model.selected_project_path.?, path), false) catch return;
                    const new_bounds = c.RECT{ .left = 174, .top = row.top, .right = 198, .bottom = row.top + 24 };
                    self.appendAccessibilityElement(&elements, &owned_identities, "project-new-loop", path, "New Loop", 1, .{ .logical = new_bounds }, false, false) catch return;
                    if (row.has_children) {
                        const disclosure_bounds = c.RECT{ .left = 198, .top = row.top, .right = 220, .bottom = row.top + 24 };
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
                            const disclosure_bounds = c.RECT{ .left = 198, .top = row.top, .right = 220, .bottom = row.top + 24 };
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
                    if (row.index < dialog.rows.items.len) {
                        const worktree = dialog.rows.items[row.index];
                        self.appendAccessibilityElement(&elements, &owned_identities, "worktree", worktree.entry.path, worktree.entry.path, 3, .{ .logical = bounds }, worktree.selected, WorktreeStatus.decision(worktree.entry) == .reclaimable) catch return;
                    }
                },
                .quick_chat_overview => {
                    self.appendAccessibilityElement(&elements, &owned_identities, "quick-chats-header", "quick-chats", "Quick Chats", 1, .{ .logical = bounds }, self.surface == .quick_chats, false) catch return;
                    const new_bounds = c.RECT{ .left = 174, .top = row.top, .right = 198, .bottom = row.top + 24 };
                    self.appendAccessibilityElement(&elements, &owned_identities, "quick-chat-new", "quick-chats", "New Chat", 1, .{ .logical = new_bounds }, false, false) catch return;
                    if (self.model.quick_chats.items.len != 0) {
                        const disclosure_bounds = c.RECT{ .left = 198, .top = row.top, .right = 220, .bottom = row.top + 24 };
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
            const section = Sidebar.sidebarSectionBottom(&self.model, if (self.worktree_inspection) |*value| value else null, &self.sidebar_state);
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
                    .{ .logical = Sidebar.needsYouStopBounds(&self.model, if (self.worktree_inspection) |*value| value else null, &self.sidebar_state, self.sidebar_scroll, index) },
                    false,
                    true,
                ) catch return;
            }
        }
        if (self.model.activity.items.len != 0) {
            const section = Sidebar.sidebarSectionBottom(&self.model, if (self.worktree_inspection) |*value| value else null, &self.sidebar_state);
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
                .{ .logical = Sidebar.activityFilterBounds(&self.model, if (self.worktree_inspection) |*value| value else null, &self.sidebar_state, self.sidebar_scroll) },
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
                    .{ .logical = Sidebar.activityCardBounds(&self.model, if (self.worktree_inspection) |*value| value else null, &self.sidebar_state, self.sidebar_scroll, visible_index) },
                    false,
                    true,
                ) catch return;
            }
            self.appendAccessibilityElement(&elements, &owned_identities, "activity-control", "scroll-left", "Scroll activity left", 1, .{ .logical = Sidebar.activityControlBounds(&self.model, if (self.worktree_inspection) |*value| value else null, &self.sidebar_state, self.sidebar_scroll, .left) }, false, true) catch return;
            self.appendAccessibilityElement(&elements, &owned_identities, "activity-control", "scroll-right", "Scroll activity right", 1, .{ .logical = Sidebar.activityControlBounds(&self.model, if (self.worktree_inspection) |*value| value else null, &self.sidebar_state, self.sidebar_scroll, .right) }, false, true) catch return;
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
                    if (GraphCanvas.hasReclaimOffer(node, if (self.worktree_inspection) |*value| value else null, self.kept_worktree_paths.items)) {
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
                        if (!self.workspace_is_quick_chat) {
                            self.appendAccessibilityElement(&elements, &owned_identities, "workspace-toolbar", graph.project.path, header.title, 4, .{ .logical = header_layout.identity }, false, false) catch return;
                            elements.items[elements.items.len - 1].invokable = false;
                        }
                        self.appendAccessibilityElement(&elements, &owned_identities, "workspace-loop-bar", if (selected_index < graph.nodes.items.len) graph.nodes.items[selected_index].id else "none", "Selected loop workspace", 4, .{ .logical = .{ .left = workspace_left, .top = Tokens.header_height, .right = workspace_right, .bottom = Tokens.header_height + Tokens.loop_bar_height } }, false, false) catch return;
                        self.appendAccessibilityElement(&elements, &owned_identities, "workspace-show-graph", "show-graph", "Show in Graph", 4, .{ .logical = .{ .left = workspace_right - 104, .top = Tokens.header_height + 10, .right = workspace_right - 12, .bottom = Tokens.header_height + 36 } }, false, false) catch return;
                        if (selected_index < graph.nodes.items.len and !isResolvedLoopState(graph.nodes.items[selected_index].state)) {
                            self.appendAccessibilityElement(&elements, &owned_identities, "workspace-stop", graph.nodes.items[selected_index].id, "Stop loop", 4, .{ .logical = .{ .left = workspace_right - 196, .top = Tokens.header_height + 10, .right = workspace_right - 112, .bottom = Tokens.header_height + 36 } }, false, false) catch return;
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
        provider.syncElements(self.status(), elements.items, policy);
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
                    target = .{ .loop = .{ .project_path = graph.project.path, .index = index } };
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
                const entry = self.model.attention_entries.items[index];
                if (self.selectProject(entry.project_path)) _ = self.model.setSelectedID(entry.node.id);
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
            .loop => |loop| self.openLoopFromAccessibility(loop.project_path, loop.index),
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
        if (!self.selectProject(project_path)) return;
        self.workspace_is_quick_chat = false;
        const graph = self.model.graph orelse return;
        if (index >= graph.nodes.items.len) return;
        if (!self.selectNodeIndex(index)) {
            self.setStatus("Unable to select loop");
            return;
        }
        if (std.mem.eql(u8, graph.nodes.items[index].loop_type, "composite") or
            std.mem.eql(u8, graph.nodes.items[index].loop_type, "proactive"))
        {
            self.surface = .project;
            self.workspace_controls.panel_visible = false;
            self.layoutWorkspace();
            self.layoutEmptyStateControls();
            self.showCompositeGroup(graph.nodes.items[index]);
            return;
        }
        self.surface = .workspace;
        self.workspace_controls.panel_visible = true;
        self.layoutWorkspace();
        self.layoutEmptyStateControls();
        self.clearEdgeSelection();
        self.rebindWorkspace(project_path);
        if (self.workspace) |workspace| {
            workspace.openNode(0, graph.nodes.items[index].id) catch {
                self.setStatus("Unable to open selected loop");
            };
            workspace.focus(0);
        }
        self.syncAccessibility();
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
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
        const refreshed = WorkspaceLifecycle.list(self.allocator) catch {
            self.setStatus("Workspace list could not be loaded");
            return false;
        };
        if (self.workspace_list) |*list| list.deinit(self.allocator);
        self.workspace_list = refreshed;
        return true;
    }

    fn showWorkspaceText(self: *App, dialog_title: []const u8, labels: []const []const u8, initial: []const []const u8) ?NativeDialogs.Result {
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
        const home = std.process.getEnvVarOwned(self.allocator, "USERPROFILE") catch {
            self.setStatus("User profile could not be resolved");
            return;
        };
        defer self.allocator.free(home);
        const name = WorkspaceLifecycle.validateName(self.allocator, result.values[1], home) catch {
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
        const outcome = mutateWorkspaceWith(WorkspaceMutationApi, self.allocator, self.window.hwnd, self.workspace_identity, workspace, .delete) catch |err| {
            self.setStatus(workspaceMutationFailure(err));
            return;
        };
        if (!self.refreshWorkspaceList()) return;
        self.setStatus(if (outcome == .deleted) "Workspace deleted" else "Workspace deletion cancelled");
    }

    fn cycleWorkspace(self: *App, direction: isize) void {
        if (!self.refreshWorkspaceList()) return;
        const list = self.workspace_list orelse return;
        if (list.items.len < 2) return;
        const next = workspaceCycleTarget(list.items, self.workspace_identity, direction) orelse {
            self.setStatus("The current workspace is not in the workspace list");
            return;
        };
        self.launchWorkspace(list.items[next].path);
    }
};

fn workspaceCycleTarget(items: []const WorkspaceLifecycle.Workspace, current_identity: []const u8, direction: isize) ?usize {
    if (items.len < 2) return null;
    for (items, 0..) |workspace, index| {
        if (std.mem.eql(u8, workspace.identity, current_identity)) {
            const count: isize = @intCast(items.len);
            return @intCast(@mod(@as(isize, @intCast(index)) + @mod(direction, count), count));
        }
    }
    return null;
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
                    .workspace_manage => app.setStatus("Use Rename Workspace or Delete Workspace from the Workspace menu"),
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
            const inspection = if (header.notice != null) &app.worktree_inspection.? else null;
            app.update_lock.lock();
            if (app.model.currentGraph()) |graph| app.canvas.syncNodeOffsets(graph.nodes.items);
            const offered_version = if (app.update_state.state == .available) app.update_version else "";
            GraphCanvas.paint(hdc, logical_right, logical_bottom, &app.model, inspection, app.selected_worktree_path, app.sidebar_scroll, app.status(), offered_version, app.ingress_error, app.connectionFailureVisible(), app.declared_entry_ids.items, app.kept_worktree_paths.items, app.allocator, &app.canvas, &app.sidebar_state, app.sidebar_hover_y, app.workspace_controls, app.surface);
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
        c.WM_TIMER => if (wparam == MainWindow.menu_watchdog_timer_id) {
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
                app.last_connection_state = updated_connection_state;
                app.sync_requested = false;
                app.restore_requested = false;
                app.quick_chats_requested = false;
            }
            if (app.client.isIdle()) app.smoke_idle_ticks += 1 else app.smoke_idle_ticks = 0;
            if (app.workspace) |workspace| {
                workspace.poll();
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
                if (workspace.inputStatus()) |input_message| app.setStatus(input_message);
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
        c.WM_KEYDOWN => {
            const ctrl = (@as(i32, c.GetKeyState(c.VK_CONTROL)) & 0x8000) != 0;
            const shift = (@as(i32, c.GetKeyState(c.VK_SHIFT)) & 0x8000) != 0;
            const alt = (@as(i32, c.GetKeyState(c.VK_MENU)) & 0x8000) != 0;
            if (MainWindow.keyOwnerEligible(hwnd, hwnd) and App.onHeaderKey(app, wparam, ctrl, shift, alt)) {
                result.* = 0;
                return true;
            }
            if (wparam == c.VK_ESCAPE) {
                app.cancelCanvasInteraction();
                result.* = 0;
                return true;
            }
            app.handleAction(InputRouter.keyAction(wparam, ctrl, shift));
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
            if (app.model.attentionCount() != 0 and GraphCanvas.hitTestAttentionRail(x, y, client.right)) {
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
            if (app.workspace_controls.rail_visible and x < rail_left) {
                const inspection = if (app.worktree_inspection) |*value| value else null;
                if (Sidebar.rowAt(x, y, &app.model, inspection, app.sidebar_scroll, workspace_top, &app.sidebar_state)) |row| {
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
                        var lane_action: ?GraphCanvas.OverviewLaneAction = null;
                        for (app.model.graphs.items, 0..) |_, graph_index| {
                            if (GraphCanvas.overviewLaneActionAt(&app.model, graph_index, x, y, bounds, &app.canvas)) |action| {
                                lane_action = action;
                                if (action == .inspect_worktrees) {
                                    if (app.selectProject(app.model.graphs.items[graph_index].project.path)) app.inspectWorktrees();
                                } else if (app.selectProject(app.model.graphs.items[graph_index].project.path)) {
                                    app.surface = .project;
                                    app.workspace_controls.panel_visible = false;
                                    app.layoutWorkspace();
                                    app.layoutEmptyStateControls();
                                    app.rebindWorkspace(app.model.graphs.items[graph_index].project.path);
                                }
                                break;
                            }
                        }
                        if (lane_action != null) {
                            _ = c.InvalidateRect(hwnd, null, 0);
                        } else if (GraphCanvas.hitTestOverview(&app.model, x, y, &app.canvas, bounds)) |hit| {
                            const graph = app.model.graphs.items[hit.graph_index];
                            if (app.selectProject(graph.project.path)) {
                                app.workspace_is_quick_chat = false;
                                app.surface = .workspace;
                                app.workspace_controls.panel_visible = true;
                                app.layoutWorkspace();
                                app.layoutEmptyStateControls();
                                app.clearEdgeSelection();
                                app.rebindWorkspace(graph.project.path);
                                _ = app.selectNodeIndex(hit.node_index);
                                if (app.workspace) |workspace| {
                                    workspace.openNode(0, graph.nodes.items[hit.node_index].id) catch {
                                        app.setStatus("Unable to open selected loop");
                                    };
                                    workspace.focus(0);
                                }
                            }
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
                        if (GraphCanvas.hitTestCompositeBack(&app.model, x, y, bounds)) {
                            app.closeCompositeGroup();
                        } else if (GraphCanvas.hitTestReclaimOffer(
                            graph.nodes.items,
                            if (app.worktree_inspection) |*value| value else null,
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
                            _ = app.selectNodeIndex(index);
                            app.openSelectedNode();
                        } else if (GraphCanvas.hitTestConnector(graph.nodes.items, x, y, &app.canvas, bounds)) |index| {
                            if (app.edge_drag_source_id.len != 0) app.allocator.free(app.edge_drag_source_id);
                            app.edge_drag_source_id = app.allocator.dupe(u8, graph.nodes.items[index].id) catch &.{};
                            if (app.edge_drag_source_id.len != 0) {
                                app.canvas.beginEdgeDrag(app.edge_drag_source_id, x, y);
                                _ = c.SetCapture(hwnd);
                            }
                        } else if (GraphCanvas.hitTest(graph.nodes.items, x, y, &app.canvas, bounds)) |index| {
                            _ = app.selectNodeIndex(index);
                            app.canvas.beginNodeDrag(graph.nodes.items[index].id, index, x, y);
                            _ = c.SetCapture(hwnd);
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
                if (Sidebar.updateBannerAt(x, y, routing.canvas.bottom, update_available, app.ingress_error.len != 0)) {
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
                    if (attention_index < app.model.attention_entries.items.len) {
                        const entry = app.model.attention_entries.items[attention_index];
                        if (app.selectProject(entry.project_path)) {
                            _ = app.model.setSelectedID(entry.node.id);
                            app.setStatus("Needs-you loop selected");
                            app.syncAccessibility();
                            _ = c.InvalidateRect(hwnd, null, 0);
                        }
                    }
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
                    workspace_top,
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
                                if (!app.selectProject(path)) return true;
                                app.workspace_is_quick_chat = false;
                                app.surface = .workspace;
                                app.workspace_controls.panel_visible = true;
                                app.layoutWorkspace();
                                app.layoutEmptyStateControls();
                                app.clearEdgeSelection();
                                app.rebindWorkspace(path);
                                const selected_graph = app.model.graph orelse return true;
                                if (row.index >= selected_graph.nodes.items.len) return true;
                                _ = app.selectNodeIndex(row.index);
                                if (app.workspace) |workspace| {
                                    workspace.openNode(0, selected_graph.nodes.items[row.index].id) catch {
                                        app.setStatus("Unable to open selected loop");
                                    };
                                    workspace.focus(0);
                                }
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
                if (Sidebar.rowAt(point.x, point.y, &app.model, inspection, app.sidebar_scroll, routing.canvas.bottom, &app.sidebar_state)) |row| {
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
                            .{ .project = .{ .path = path, .remote = remote } },
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
                                GraphContextMenu.show(
                                    hwnd,
                                    .{ .node = .{
                                        .project_path = path,
                                        .id = graph.nodes.items[row.index].id,
                                        .composite = std.mem.eql(u8, graph.nodes.items[row.index].loop_type, "composite") or
                                            std.mem.eql(u8, graph.nodes.items[row.index].loop_type, "proactive"),
                                        .can_arm = std.mem.eql(u8, graph.nodes.items[row.index].pilot_state, "piloted"),
                                        .resolved = isResolvedLoopState(graph.nodes.items[row.index].state),
                                    } },
                                    screen.x,
                                    screen.y,
                                    app,
                                    &onContextAction,
                                );
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
                app.canvas.endNodeDrag();
                if (app.canvas_layout_store) |*store| {
                    store.save(&app.canvas) catch app.setStatus("Canvas position could not be saved");
                }
                _ = c.ReleaseCapture();
                app.syncAccessibility();
                _ = c.InvalidateRect(hwnd, null, 0);
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
            switch (wheelRegion(x, y, routing, app.workspace_controls)) {
                .sidebar => {
                    app.sidebar_scroll = Sidebar.clampScroll(app.sidebar_scroll - @divTrunc(@as(i32, delta), 4), Sidebar.maxScroll(&app.model, if (app.worktree_inspection) |*value| value else null, routing.canvas.bottom, &app.sidebar_state));
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
            const pinch_context = app.pinchGestureContext();
            switch (CanvasInput.classifyGesture(info.dwID, info.dwFlags, in_canvas)) {
                // GID_BEGIN/GID_END (the generic gesture-sequence brackets) and
                // any zoom message located outside the canvas: this window
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
                    app.canvas.beginPinchZoom(distance, pinch_context);
                    _ = c.CloseGestureInfoHandle(gesture_handle);
                    result.* = 0;
                    return true;
                },
                .continue_zoom => {
                    if (mapped) |point| app.canvas.continuePinchZoom(point.x, point.y, distance, pinch_context);
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
                    if (mapped) |point| app.canvas.continuePinchZoom(point.x, point.y, distance, pinch_context);
                    app.canvas.endPinchZoom();
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
                    app.canvas.beginPinchZoom(distance, pinch_context);
                    app.canvas.endPinchZoom();
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
                    workspace.focus(workspace.active_surface);
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
                        workspace.focus(workspace.active_surface);
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
    fn delete(path: []const u8) !void {
        deletions += 1;
        try std.testing.expectEqualStrings(expected_path, path);
        if (!skip_delete) try WorkspaceMutationApi.delete(path);
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
    try std.testing.expectEqual(WorkspaceMutationResult.deleted, try mutateWorkspaceWith(WorkspaceMutationFixture, allocator, null, default.identity, alpha, .delete));
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

test "pinchGestureContext changes identity across project switches on the same surface" {
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

    // Same graph-capable surface, different project: this identity is what
    // WM_GESTURE's routing uses to detect a same-region destination change
    // during an in-progress pinch. A gesture begun on project A must not be
    // able to keep scaling project B's canvas after a mid-gesture project
    // switch, so the two identities must differ.
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

    fn syncElements(self: *@This(), _: []const u8, elements: []const Accessibility.DynamicElement, _: WorktreeStatus.Policy) void {
        self.checked = true;
        self.checkElements(elements) catch |err| {
            self.failure = err;
        };
    }

    fn checkElements(self: *@This(), elements: []const Accessibility.DynamicElement) !void {
        for (self.expected) |expected| {
            var found = false;
            for (elements) |element| {
                if (!std.mem.eql(u8, expected.identity, element.identity)) continue;
                found = true;
                const bounds = expected.bounds orelse {
                    std.debug.print("Unexpected UIA element: {s}\n", .{expected.identity});
                    return error.UnexpectedAccessibilityElement;
                };
                const actual = [4]i32{ element.left, element.top, element.right, element.bottom };
                std.testing.expectEqualDeep(bounds[self.dpi_index], actual) catch |err| {
                    std.debug.print("UIA bounds mismatch: {s}, DPI index {d}\n", .{ expected.identity, self.dpi_index });
                    return err;
                };
            }
            if (!found and expected.bounds != null) std.debug.print("Missing UIA element: {s}\n", .{expected.identity});
            try std.testing.expectEqual(expected.bounds != null, found);
        }
    }
};

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
    });
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
    const choices = try app.worktreeChoicesForNodeForm(allocator);
    defer allocator.free(choices);
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

    const choices = try app.worktreeChoicesForNodeForm(allocator);
    defer allocator.free(choices);
    try std.testing.expectEqual(@as(usize, 2), choices.len);
    try std.testing.expectEqualStrings("main", choices[0].branch);
    try std.testing.expect(choices[0].is_default);
    try std.testing.expectEqualStrings("feature/x", choices[1].branch);
    try std.testing.expect(!choices[1].is_default);
}

test "worktree row selected reflects sidebar and dialog selection honestly" {
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
