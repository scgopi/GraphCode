const std = @import("std");
const build_options = @import("build_options");
const DaemonClient = @import("DaemonClient.zig").DaemonClient;
const GraphCanvas = @import("GraphCanvas.zig");
const GdiplusAA = @import("GdiplusAA.zig");
const CanvasInput = @import("CanvasInput.zig");
const CanvasLayoutStore = @import("CanvasLayoutStore.zig");
const GraphContextMenu = @import("GraphContextMenu.zig");
const Forms = @import("Forms.zig");
const NativeForms = @import("NativeForms.zig");
const TemplateLibrary = @import("TemplateLibrary.zig");
const JumpPalette = @import("JumpPalette.zig");
const NativeDialogs = @import("WindowsNativeDialogs.zig");
const Sidebar = @import("Sidebar.zig");
const GraphModel = @import("GraphModel.zig");
const InputRouter = @import("InputRouter.zig");
const MainWindow = @import("MainWindow.zig");
const TerminalWorkspace = @import("TerminalWorkspace.zig");
const Tokens = @import("DesignTokens.zig");
const Dpi = @import("Dpi.zig");
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
const WorktreeDialog = @import("WorktreeDialog.zig");
const Accessibility = @import("Accessibility.zig");
const Navigation = @import("Navigation.zig");
const WorkspaceControls = @import("WorkspaceControls.zig");
const WorkspaceLifecycle = @import("WorkspaceLifecycle.zig");
const Win32 = @import("Win32.zig");
const c = Win32.c;

const title = std.unicode.utf8ToUtf16LeStringLiteral("GraphCode Windows");
const instance_prefix = "Local\\graphcode-windows-";
const tray_test_hook_environment = "GRAPHCODE_TRAY_TEST_HOOK";
const daemon_supervisor_test_hook_environment = "GRAPHCODE_DAEMON_SUPERVISOR_TEST_HOOK";
const daemon_supervisor_test_property =
    std.unicode.utf8ToUtf16LeStringLiteral("GraphCode.Windows.DaemonSupervisorState");
extern fn graphcode_pick_folder(owner: c.HWND, buffer: [*]u16, capacity: c.DWORD) callconv(.c) c_int;

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

fn inputBounds(client_right: i32, client_bottom: i32, controls: WorkspaceControls.State) InputBounds {
    return .{
        .rail_left = if (controls.rail_visible) Tokens.sidebar_width else 0,
        .workspace_top = client_bottom - (if (controls.panel_visible) Tokens.workspace_height else 0),
        .canvas = GraphCanvas.renderBounds(client_right, client_bottom, controls),
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
    canvas_layout_store: ?CanvasLayoutStore.Store = null,
    quick_chats_requested: bool = false,
    selected_quick_chat: ?usize = null,
    instance_mutex: c.HANDLE = null,
    workspace_list: ?WorkspaceLifecycle.List = null,
    workspace_path: []u8 = &.{},
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
        if (self.instance_mutex != null) _ = c.CloseHandle(self.instance_mutex);
        if (self.workspace_list) |*list| list.deinit(self.allocator);
        if (self.workspace_path.len != 0) self.allocator.free(self.workspace_path);
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
        self.allocator.destroy(self);
    }

    pub fn run(self: *App) !void {
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
        self.refreshWorkspaceList();
        self.updateNativeChrome();
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
        var client: c.RECT = undefined;
        if (c.GetClientRect(self.window.hwnd, &client) == 0) return null;
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
    /// prospective picker. Projected from `WorktreeStatus.Entry`; `is_default`
    /// marks the entry whose branch matches the inspection's default branch.
    pub const WorktreeChoice = struct {
        path: []const u8,
        branch: []const u8,
        is_default: bool,
    };

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
        var templates = TemplateLibrary.load(self.allocator, path) catch {
            self.setStatus("Unable to load saved templates");
            return;
        };
        defer templates.deinit();
        if (templates.templates.items.len == 0) {
            var draft = NativeForms.node(self.window.hwnd, self.allocator, path, &draft_id_buffer, initial) catch |err| {
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
            const result = NativeForms.nodeWithTemplates(self.window.hwnd, self.allocator, path, &draft_id_buffer, current, true) catch |err| {
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
        const current_graph = self.model.graph orelse return;
        if (!std.mem.eql(u8, current_graph.project.path, graph.project.path)) return;
        const current_index = GraphModel.findNodeIndexByID(current_graph.nodes.items, node.id) orelse {
            self.setStatus("Loop changed while editing details");
            return;
        };
        self.client.sendUpdateNodeForm(current_graph.project.path, current_graph.nodes.items[current_index].id, update);
    }

    fn createEdge(self: *App) void {
        const graph = self.model.graph orelse return;
        if (graph.nodes.items.len < 2) return;
        const path = self.currentProject() orelse return;
        const endpoints = self.allocator.alloc(NativeForms.EdgeEndpoint, graph.nodes.items.len) catch {
            self.setStatus("Unable to prepare edge endpoints");
            return;
        };
        defer self.allocator.free(endpoints);
        for (graph.nodes.items, endpoints) |node, *endpoint| endpoint.* = .{
            .id = node.id,
            .title = node.title,
        };
        var draft = NativeForms.edgeWithEndpoints(self.window.hwnd, self.allocator, .{
            .from = graph.nodes.items[0].id,
            .to = graph.nodes.items[1].id,
            .kind = "handoff",
        }, endpoints, false) catch {
            self.setStatus("Unable to open edge form");
            return;
        } orelse return;
        defer draft.deinit(self.allocator);
        Forms.validateEdge(draft) catch {
            self.setStatus("Invalid edge form");
            return;
        };
        self.client.sendCreateEdgeDraft(path, draft);
    }

    fn createEdgeBetween(self: *App, source: usize, target: usize) void {
        const graph = self.model.graph orelse return;
        if (source >= graph.nodes.items.len or target >= graph.nodes.items.len or source == target) return;
        self.createEdgeBetweenIDs(graph.nodes.items[source].id, graph.nodes.items[target].id);
    }

    fn createEdgeBetweenIDs(self: *App, source_id: []const u8, target_id: []const u8) void {
        const graph = self.model.graph orelse return;
        if (std.mem.eql(u8, source_id, target_id)) return;
        const project_path = self.allocator.dupe(u8, graph.project.path) catch return;
        defer self.allocator.free(project_path);
        const from_id = self.allocator.dupe(u8, source_id) catch return;
        defer self.allocator.free(from_id);
        const to_id = self.allocator.dupe(u8, target_id) catch return;
        defer self.allocator.free(to_id);
        const draft = NativeForms.edge(self.window.hwnd, self.allocator, .{
            .from = from_id,
            .to = to_id,
            .kind = "handoff",
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
        const from_index = GraphModel.findNodeIndexByID(updated_graph.nodes.items, draft.from) orelse {
            self.setStatus("Source loop changed while creating edge");
            return;
        };
        const to_index = GraphModel.findNodeIndexByID(updated_graph.nodes.items, draft.to) orelse {
            self.setStatus("Target loop changed while creating edge");
            return;
        };
        self.client.sendCreateEdge(project_path, updated_graph.nodes.items[from_index].id, updated_graph.nodes.items[to_index].id, draft.kind);
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
        self.client.applySettings(draft.daemon_pipe, draft.support_directory) catch {
            self.setStatus("Invalid daemon settings");
            return;
        };
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
        self.updateNativeChrome();
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
            self.update_version = result.version orelse &.{};
            self.update_release_url = result.release_url orelse &.{};
            result.version = null;
            result.release_url = null;
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
        const action = UpdateOfferDialog.show(
            self.window.hwnd,
            self.allocator,
            version,
            "In-app Windows installation is not implemented yet. Download the Windows ZIP from the release page.",
        ) catch {
            self.setStatus("Unable to prepare the update offer");
            return;
        };
        switch (action) {
            .later => self.setStatus("Update offer deferred"),
            .install_unavailable => self.setStatus("In-app installation is not implemented; download the Windows ZIP"),
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
        if (self.model.graphs.items.len == 0) {
            self.setStatus("No graph is open");
            return;
        }
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
                } };
            },
            4 => .background,
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
                } };
            },
            else => return,
        };
        _ = c.SetTimer(
            hwnd,
            MainWindow.menu_watchdog_timer_id,
            MainWindow.menu_watchdog_interval_ms,
            null,
        );
        GraphContextMenu.show(
            hwnd,
            target,
            uia_context_menu_x,
            uia_context_menu_y,
            self,
            &onContextAction,
        );
        _ = c.KillTimer(hwnd, MainWindow.menu_watchdog_timer_id);
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
    fn dismissWedgedUiaForm() void {
        const form_class_name = std.unicode.utf8ToUtf16LeStringLiteral("GraphCodeNativeForm");
        const hwnd = c.FindWindowW(form_class_name.ptr, null);
        if (hwnd != null) _ = c.PostMessageW(hwnd, c.WM_CLOSE, 0, 0);
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
            .background => if (action == .create_edge) self.createEdge(),
            .quick_chats => if (action == .new_quick_chat) self.createQuickChat(),
        }
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
    }

    fn saveSelectedNodeAsTemplate(self: *App, index: usize) void {
        const graph = self.model.graph orelse return;
        if (index >= graph.nodes.items.len) return;
        var result = NativeDialogs.textWithDescription(
            self.window.hwnd, self.allocator, "Save as Template",
            "Name this reusable prompt template. It is stored in your per-user GraphCode library.",
            &.{"Template name"}, &.{graph.nodes.items[index].title},
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
        if (self.selected_worktree_path.len == 0 and
            (self.worktree_dialog == null or self.worktree_dialog.?.selectedCount() == 0))
        {
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
        var client: c.RECT = undefined;
        if (c.GetClientRect(self.window.hwnd, &client) == 0) return;
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
        var client: c.RECT = undefined;
        if (c.GetClientRect(self.window.hwnd, &client) == 0) {
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
                self.workspace_controls.apply(.toggle_panel);
                if (self.workspace_controls.panel_visible) {
                    self.surface = .workspace;
                } else if (self.surface == .workspace) {
                    self.surface = .project;
                }
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
                var client: c.RECT = undefined;
                if (c.GetClientRect(self.window.hwnd, &client) == 0) return;
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
                var client: c.RECT = undefined;
                if (c.GetClientRect(self.window.hwnd, &client) == 0) return;
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

    fn toggleWorkspaceDetailPanel(self: *App) void {
        self.workspace_controls.panel_visible = !self.workspace_controls.panel_visible;
        if (self.workspace_controls.panel_visible) self.surface = .workspace;
        self.layoutWorkspace();
        self.syncAccessibility();
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
        self.setStatus(if (self.workspace_controls.panel_visible) "Loop detail panel expanded" else "Loop detail panel collapsed");
    }

    fn layoutWorkspace(self: *App) void {
        var client: c.RECT = undefined;
        if (c.GetClientRect(self.window.hwnd, &client) == 0) return;
        if (self.workspace) |workspace| {
            const full_workspace = self.surface == .workspace;
            const activity_height = if (self.workspace_controls.activity_enabled) Tokens.activity_strip_height else 0;
            const panel_height = if (full_workspace)
                @max(0, client.bottom - Tokens.header_height - Tokens.loop_bar_height - activity_height)
            else if (self.workspace_controls.panel_visible)
                Tokens.workspace_height
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
                if (self.workspace_controls.rail_visible) Tokens.sidebar_width else 0,
                if (full_workspace) Tokens.header_height + Tokens.loop_bar_height else @max(0, client.bottom - panel_height),
                @max(0, client.right - (if (self.workspace_controls.rail_visible) Tokens.sidebar_width else 0) -
                    (if (full_workspace and self.workspace_controls.panel_visible) Tokens.loop_detail_width else 0)),
                panel_height,
            );
        }
    }

    fn status(self: *const App) []const u8 {
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
        var client: c.RECT = undefined;
        if (c.GetClientRect(self.window.hwnd, &client) == 0) return;
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
            _ = c.SetWindowPos(self.empty_open_folder_button, null, x, y, 220, 32, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
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
                primary_x,
                primary_y,
                if (is_empty) 220 else 120,
                32,
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
        return c.CreateWindowExW(
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

    fn updateNativeChrome(self: *App) void {
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
                        .is_current = WorkspaceLifecycle.isSamePath(workspace.path, self.workspace_path),
                    };
                }
            }
        }
        defer if (workspace_items.len != 0) self.allocator.free(workspace_items);
        MainWindow.updateMenu(self.window.hwnd, .{
            .has_project = self.model.graph != null,
            .can_worktrees = if (self.model.graph) |graph| graph.project.isLocalFilesystem() else false,
            .has_workspace = self.workspace != null and self.model.graph != null,
            .has_attention = self.model.attentionCount() != 0,
            .can_close_tab = if (self.workspace) |workspace| workspace.tabCount() > 1 else false,
            .sidebar_visible = self.workspace_controls.rail_visible,
            .workspace_visible = self.workspace_controls.panel_visible,
            .activity_visible = self.workspace_controls.activity_enabled,
            .update_checking = update_checking,
            .recent_folders = recent_menu,
            .workspaces = workspace_items,
        });
        self.layoutEmptyStateControls();
    }

    fn setStatus(self: *App, value: []const u8) void {
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

    fn syncAccessibility(self: *App) void {
        const provider = if (self.accessibility) |*value| value else return;
        var elements = std.array_list.Managed(Accessibility.DynamicElement).init(self.allocator);
        defer elements.deinit();
        var owned_identities = std.array_list.Managed([]u8).init(self.allocator);
        defer {
            for (owned_identities.items) |value| self.allocator.free(value);
            owned_identities.deinit();
        }
        var client: c.RECT = undefined;
        _ = c.GetClientRect(self.window.hwnd, &client);
        const canvas_bounds = inputBounds(client.right, client.bottom, self.workspace_controls).canvas;
        const canvas_rect = c.RECT{
            .left = canvas_bounds.left,
            .top = canvas_bounds.top,
            .right = canvas_bounds.right,
            .bottom = canvas_bounds.bottom,
        };
        var sidebar_rows = Sidebar.appendRows(
            self.allocator,
            &self.model,
            if (self.worktree_inspection) |*value| value else null,
            self.sidebar_scroll,
            &self.sidebar_state,
        ) catch return;
        defer sidebar_rows.deinit(self.allocator);
        for (sidebar_rows.items) |row| {
            const bounds = c.RECT{ .left = 12, .top = row.top - 3, .right = 232, .bottom = row.top + 23 };
            switch (row.kind) {
                .local_heading => self.appendAccessibilityElement(&elements, &owned_identities, "sidebar-section", "local", "Local Projects", 1, bounds, false, false) catch return,
                .remote_heading => self.appendAccessibilityElement(&elements, &owned_identities, "sidebar-section", "remote", "Remote Repositories", 1, bounds, false, false) catch return,
                .project => {
                    const project = self.model.recent_projects.items[row.index];
                    self.appendAccessibilityElement(&elements, &owned_identities, "project", project.path, project.name, 1, bounds, false, false) catch return;
                },
                .open_project => if (row.project_path) |path| if (self.model.graphFor(path)) |graph| {
                    self.appendAccessibilityElement(&elements, &owned_identities, "open-project", path, graph.project.name, 1, bounds, self.model.selected_project_path != null and std.mem.eql(u8, self.model.selected_project_path.?, path), false) catch return;
                    const new_bounds = c.RECT{ .left = 174, .top = row.top, .right = 198, .bottom = row.top + 24 };
                    self.appendAccessibilityElement(&elements, &owned_identities, "project-new-loop", path, "New Loop", 1, new_bounds, false, false) catch return;
                    if (row.has_children) {
                        const disclosure_bounds = c.RECT{ .left = 198, .top = row.top, .right = 220, .bottom = row.top + 24 };
                        self.appendAccessibilityElement(
                            &elements,
                            &owned_identities,
                            "project-disclosure",
                            path,
                            if (self.sidebar_state.isProjectCollapsed(path)) "Expand project" else "Collapse project",
                            1,
                            disclosure_bounds,
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
                        self.appendAccessibilityElement(&elements, &owned_identities, "loop", key, node.title, 2, bounds, self.model.selected_node_id != null and std.mem.eql(u8, self.model.selected_node_id.?, node.id), false) catch return;
                        if (row.has_children) {
                            const disclosure_bounds = c.RECT{ .left = 198, .top = row.top, .right = 220, .bottom = row.top + 24 };
                            self.appendAccessibilityElement(
                                &elements,
                                &owned_identities,
                                "loop-disclosure",
                                key,
                                if (self.sidebar_state.isNodeExpanded(node.id)) "Collapse loop children" else "Expand loop children",
                                2,
                                disclosure_bounds,
                                false,
                                false,
                            ) catch return;
                        }
                    }
                },
                .worktree => if (self.worktree_dialog) |dialog| {
                    if (row.index < dialog.rows.items.len) {
                        const worktree = dialog.rows.items[row.index];
                        self.appendAccessibilityElement(&elements, &owned_identities, "worktree", worktree.entry.path, worktree.entry.path, 3, bounds, worktree.selected, WorktreeStatus.decision(worktree.entry) == .reclaimable) catch return;
                    }
                },
                .quick_chat_overview => {
                    self.appendAccessibilityElement(&elements, &owned_identities, "quick-chats-header", "quick-chats", "Quick Chats", 1, bounds, self.surface == .quick_chats, false) catch return;
                    const new_bounds = c.RECT{ .left = 174, .top = row.top, .right = 198, .bottom = row.top + 24 };
                    self.appendAccessibilityElement(&elements, &owned_identities, "quick-chat-new", "quick-chats", "New Chat", 1, new_bounds, false, false) catch return;
                    if (self.model.quick_chats.items.len != 0) {
                        const disclosure_bounds = c.RECT{ .left = 198, .top = row.top, .right = 220, .bottom = row.top + 24 };
                        self.appendAccessibilityElement(
                            &elements,
                            &owned_identities,
                            "quick-chats-disclosure",
                            "quick-chats",
                            if (self.sidebar_state.chats_collapsed) "Expand Quick Chats" else "Collapse Quick Chats",
                            1,
                            disclosure_bounds,
                            false,
                            false,
                        ) catch return;
                    }
                },
                .quick_chat => if (row.index < self.model.quick_chats.items.len) {
                    const chat = self.model.quick_chats.items[row.index];
                    self.appendAccessibilityElement(&elements, &owned_identities, "quick-chat-row", chat.id, chat.title, 1, bounds, false, false) catch return;
                },
                else => {},
            }
        }
        if (self.surface == .workspace) if (self.selected_quick_chat) |chat_index| {
            if (chat_index < self.model.quick_chats.items.len) {
                const chat = self.model.quick_chats.items[chat_index];
                const identity = std.fmt.allocPrint(self.allocator, "quick-chat-workspace:{s}", .{chat.id}) catch return;
                owned_identities.append(identity) catch {
                    self.allocator.free(identity);
                    return;
                };
                const workspace_bounds = c.RECT{
                    .left = canvas_rect.left,
                    .top = inputBounds(client.right, client.bottom, self.workspace_controls).workspace_top,
                    .right = canvas_rect.right,
                    .bottom = client.bottom,
                };
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
            self.appendAccessibilityElement(&elements, &owned_identities, "needs-you-header", "needs-you", "Needs you", 1, .{ .left = 12, .top = section + 4, .right = 232, .bottom = section + 28 }, false, true) catch return;
            for (self.model.attention_entries.items[0..@min(self.model.attention_entries.items.len, 4)], 0..) |entry, index| {
                const row_offset = @as(i32, @intCast(index)) * 34;
                const identity = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entry.project_path, entry.node.id }) catch return;
                defer self.allocator.free(identity);
                const name = std.fmt.allocPrint(self.allocator, "{s} - {s}", .{ entry.node.title, Sidebar.attentionReason(entry.node) }) catch return;
                owned_identities.append(name) catch {
                    self.allocator.free(name);
                    return;
                };
                self.appendAccessibilityElement(&elements, &owned_identities, "needs-you-row", identity, name, 1, .{ .left = 18, .top = section + 30 + row_offset, .right = 232, .bottom = section + 60 + row_offset }, self.model.selected_node_id != null and std.mem.eql(u8, self.model.selected_node_id.?, entry.node.id), true) catch return;
                self.appendAccessibilityElement(
                    &elements,
                    &owned_identities,
                    "needs-you-stop",
                    identity,
                    "Stop loop",
                    1,
                    Sidebar.needsYouStopBounds(&self.model, if (self.worktree_inspection) |*value| value else null, &self.sidebar_state, self.sidebar_scroll, index),
                    false,
                    true,
                ) catch return;
            }
        }
        if (self.model.activity.items.len != 0) {
            const section = Sidebar.sidebarSectionBottom(&self.model, if (self.worktree_inspection) |*value| value else null, &self.sidebar_state);
            const attention_rows = @min(self.model.attentionCount(), 4);
            const activity_top = section + 30 + (@as(i32, @intCast(attention_rows)) * 34) + 18;
            self.appendAccessibilityElement(&elements, &owned_identities, "activity-header", "activity", "Activity", 1, .{ .left = 12, .top = activity_top, .right = 232, .bottom = activity_top + 24 }, false, true) catch return;
            self.appendAccessibilityElement(
                &elements,
                &owned_identities,
                "activity-filter",
                "attention",
                if (self.sidebar_state.activity_attention_only) "Show all activity" else "Show attention-only activity",
                1,
                Sidebar.activityFilterBounds(&self.model, if (self.worktree_inspection) |*value| value else null, &self.sidebar_state, self.sidebar_scroll),
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
                    Sidebar.activityCardBounds(&self.model, if (self.worktree_inspection) |*value| value else null, &self.sidebar_state, self.sidebar_scroll, visible_index),
                    false,
                    true,
                ) catch return;
            }
            self.appendAccessibilityElement(&elements, &owned_identities, "activity-control", "scroll-left", "Scroll activity left", 1, Sidebar.activityControlBounds(&self.model, if (self.worktree_inspection) |*value| value else null, &self.sidebar_state, self.sidebar_scroll, .left), false, true) catch return;
            self.appendAccessibilityElement(&elements, &owned_identities, "activity-control", "scroll-right", "Scroll activity right", 1, Sidebar.activityControlBounds(&self.model, if (self.worktree_inspection) |*value| value else null, &self.sidebar_state, self.sidebar_scroll, .right), false, true) catch return;
        }
        if (self.ingress_error.len != 0) {
            elements.append(.{
                .identity = "sidebar-error-footer:ingress",
                .name = self.ingress_error,
                .parent = 1,
                .selected = false,
                .eligible = false,
                .invokable = false,
                .left = Sidebar.errorFooterRect(client.bottom).left,
                .top = Sidebar.errorFooterRect(client.bottom).top,
                .right = Sidebar.errorFooterRect(client.bottom).right,
                .bottom = Sidebar.errorFooterRect(client.bottom).bottom,
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
                        GraphCanvas.compositeBreadcrumbBounds(canvas_rect),
                        false,
                        false,
                    ) catch return;
                }
                for (graph.nodes.items, 0..) |node, index| {
                    const bounds = GraphCanvas.nodeBounds(index, &self.canvas);
                    const key = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph.project.path, node.id }) catch return;
                    defer self.allocator.free(key);
                    self.appendAccessibilityElement(&elements, &owned_identities, "project-card", key, node.title, 4, bounds, self.model.selected_index == index, false) catch return;
                    if (GraphCanvas.hitTestAttentionAction(graph.nodes.items, graph.edges.items, bounds.right - 20, bounds.bottom - 12, &self.canvas) != null) {
                        self.appendAccessibilityElement(&elements, &owned_identities, "attention-action", key, GraphCanvas.attentionActionLabel(node), 4, GraphCanvas.attentionActionBounds(bounds, &self.canvas), false, false) catch return;
                    }
                    if (GraphCanvas.hasReclaimOffer(node, if (self.worktree_inspection) |*value| value else null, self.kept_worktree_paths.items)) {
                        const offer = GraphCanvas.reclaimOfferBounds(bounds);
                        self.appendAccessibilityElement(&elements, &owned_identities, "reclaim", key, "Reclaim", 4, offer.reclaim, false, false) catch return;
                        self.appendAccessibilityElement(&elements, &owned_identities, "keep", key, "Keep", 4, offer.keep, false, false) catch return;
                    }
                }
                if (self.surface == .workspace) {
                    if (self.workspace) |workspace| {
                        const workspace_left = if (self.workspace_controls.rail_visible) Tokens.sidebar_width else 0;
                        const workspace_right = client.right - (if (self.workspace_controls.panel_visible) Tokens.loop_detail_width else 0);
                        const selected_index = self.model.selectedIndex() orelse 0;
                        self.appendAccessibilityElement(&elements, &owned_identities, "workspace-toolbar", graph.project.path, graph.project.name, 4, .{ .left = workspace_left, .top = 0, .right = workspace_right, .bottom = Tokens.header_height }, false, false) catch return;
                        self.appendAccessibilityElement(&elements, &owned_identities, "workspace-loop-bar", if (selected_index < graph.nodes.items.len) graph.nodes.items[selected_index].id else "none", "Selected loop workspace", 4, .{ .left = workspace_left, .top = Tokens.header_height, .right = workspace_right, .bottom = Tokens.header_height + Tokens.loop_bar_height }, false, false) catch return;
                        self.appendAccessibilityElement(&elements, &owned_identities, "workspace-show-graph", "show-graph", "Show in Graph", 4, .{ .left = workspace_right - 104, .top = Tokens.header_height + 10, .right = workspace_right - 12, .bottom = Tokens.header_height + 36 }, false, false) catch return;
                        if (selected_index < graph.nodes.items.len and !isResolvedLoopState(graph.nodes.items[selected_index].state)) {
                            self.appendAccessibilityElement(&elements, &owned_identities, "workspace-stop", graph.nodes.items[selected_index].id, "Stop loop", 4, .{ .left = workspace_right - 196, .top = Tokens.header_height + 10, .right = workspace_right - 112, .bottom = Tokens.header_height + 36 }, false, false) catch return;
                        }
                        const panel_toggle = if (self.workspace_controls.panel_visible)
                            GraphCanvas.loopDetailCollapseBounds(client.right)
                        else
                            GraphCanvas.loopDetailExpandBounds(client.right);
                        self.appendAccessibilityElement(&elements, &owned_identities, "workspace-toggle-panel", "control", if (self.workspace_controls.panel_visible) "Collapse loop panel" else "Expand loop panel", 4, panel_toggle, false, true) catch return;
                        if (self.workspace_controls.panel_visible and selected_index < graph.nodes.items.len) {
                            const detail_left = client.right - Tokens.loop_detail_width;
                            const selected_node = graph.nodes.items[selected_index];
                            self.appendAccessibilityElement(&elements, &owned_identities, "workspace-detail-sparkline", selected_node.id, "Metric sparkline", 4, .{ .left = detail_left + 18, .top = client.bottom - 102, .right = client.right - 18, .bottom = client.bottom - 70 }, false, false) catch return;
                            if (selected_node.created_at != null) {
                                self.appendAccessibilityElement(&elements, &owned_identities, "workspace-detail-start", selected_node.id, "Start time", 4, .{ .left = detail_left + 18, .top = client.bottom - 64, .right = client.right - 18, .bottom = client.bottom - 44 }, false, false) catch return;
                            }
                            if (selected_node.token_usage) |tokens| {
                                const usage_name = std.fmt.allocPrint(self.allocator, "{d} tokens", .{tokens}) catch return;
                                owned_identities.append(usage_name) catch {
                                    self.allocator.free(usage_name);
                                    return;
                                };
                                self.appendAccessibilityElement(&elements, &owned_identities, "workspace-detail-usage", selected_node.id, usage_name, 4, .{ .left = detail_left + 18, .top = client.bottom - 44, .right = client.right - 18, .bottom = client.bottom - 24 }, false, false) catch return;
                            }
                        }
                        for (workspace.layout.tabs.items, 0..) |tab, tab_index| {
                            const tab_key = std.fmt.allocPrint(self.allocator, "{d}", .{tab_index}) catch return;
                            defer self.allocator.free(tab_key);
                            const tab_left = workspace.layout_origin_x + @as(i32, @intCast(tab_index)) * 120;
                            const tab_bounds = c.RECT{ .left = tab_left, .top = workspace.layout_origin_y + 4, .right = tab_left + 112, .bottom = workspace.layout_origin_y + Tokens.tab_bar_height - 4 };
                            self.appendAccessibilityElement(&elements, &owned_identities, "workspace-tab", tab_key, if (tab.panes.items.len > 1) "Split tab" else if (tab_index == 0) "Agent tab" else "Shell tab", 4, tab_bounds, tab_index == workspace.layout.selected_tab, true) catch return;
                            const close_key = std.fmt.allocPrint(self.allocator, "{d}", .{tab_index}) catch return;
                            defer self.allocator.free(close_key);
                            self.appendAccessibilityElement(&elements, &owned_identities, "workspace-tab-close", close_key, "Close tab", 4, .{ .left = tab_bounds.right - 24, .top = tab_bounds.top, .right = tab_bounds.right, .bottom = tab_bounds.bottom }, false, workspace.canCloseTab()) catch return;
                        }
                        const controls_left = @max(workspace.layout_origin_x, workspace.layout_origin_x + workspace.layout_width - 220);
                        for ([_][]const u8{ "New Tab", "Split Right", "Split Down" }, 0..) |label, control_index| {
                            const control_left = controls_left + @as(i32, @intCast(control_index)) * 72;
                            const kind = if (control_index == 0) "workspace-new-tab" else if (control_index == 1) "workspace-split-right" else "workspace-split-down";
                            self.appendAccessibilityElement(&elements, &owned_identities, kind, "control", label, 4, .{ .left = control_left, .top = workspace.layout_origin_y + 3, .right = control_left + 68, .bottom = workspace.layout_origin_y + Tokens.tab_bar_height - 3 }, false, true) catch return;
                        }
                    }
                }
            },
            .overview => for (self.model.graphs.items, 0..) |graph, graph_index| {
                for (graph.nodes.items, 0..) |node, node_index| {
                    const bounds = GraphCanvas.overviewCardBounds(&self.model, graph_index, node_index, canvas_rect, &self.canvas);
                    const key = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph.project.path, node.id }) catch return;
                    defer self.allocator.free(key);
                    self.appendAccessibilityElement(&elements, &owned_identities, "overview-card", key, node.title, 4, bounds, false, false) catch return;
                }
            },
            .quick_chats => for (self.model.quick_chats.items, 0..) |chat, index| {
                self.appendAccessibilityElement(&elements, &owned_identities, "quick-chat-card", chat.id, chat.title, 4, GraphCanvas.quickChatCardBounds(index, canvas_rect, &self.canvas), false, false) catch return;
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
            const bounds = GraphCanvas.inlineAlertBounds(canvas_rect);
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
                elements.append(.{
                    .identity = identity,
                    .name = workspace.name,
                    .parent = 21,
                    .selected = WorkspaceLifecycle.isSamePath(workspace.path, self.workspace_path),
                    .eligible = true,
                    .invokable = true,
                    .left = 250,
                    .top = row_top,
                    .right = 500,
                    .bottom = row_top + 28,
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
        bounds: c.RECT,
        selected: bool,
        eligible: bool,
    ) !void {
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
        }
        self.clampSidebarScroll();
        self.syncAccessibility();
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
        return true;
    }

    fn openLoopFromAccessibility(self: *App, project_path: []const u8, index: usize) void {
        if (!self.selectProject(project_path)) return;
        const graph = self.model.graph orelse return;
        if (index >= graph.nodes.items.len) return;
        _ = self.selectNodeIndex(index);
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
        const user = std.process.getEnvVarOwned(self.allocator, "USERNAME") catch
            try std.process.getEnvVarOwned(self.allocator, "USER");
        defer self.allocator.free(user);
        const path = try WorkspaceLifecycle.currentPath(self.allocator);
        defer self.allocator.free(path);
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(path, &digest, .{});
        const digest_text = std.fmt.bytesToHex(digest, .lower);
        const name = try std.fmt.allocPrint(self.allocator, "{s}{s}-{s}", .{ instance_prefix, user, digest_text[0..20] });
        defer self.allocator.free(name);
        const raw_wide = try std.unicode.utf8ToUtf16LeAlloc(self.allocator, name);
        defer self.allocator.free(raw_wide);
        const wide = try self.allocator.alloc(u16, raw_wide.len + 1);
        defer self.allocator.free(wide);
        @memcpy(wide[0..raw_wide.len], raw_wide);
        wide[raw_wide.len] = 0;
        self.instance_mutex = c.CreateMutexW(null, 1, wide.ptr);
        if (self.instance_mutex == null) return error.SingleInstanceMutexFailed;
        if (c.GetLastError() == c.ERROR_ALREADY_EXISTS) {
            _ = c.CloseHandle(self.instance_mutex);
            self.instance_mutex = null;
            return error.InstanceAlreadyRunning;
        }
    }

    fn refreshWorkspaceList(self: *App) void {
        const current = WorkspaceLifecycle.currentPath(self.allocator) catch {
            self.setStatus("Workspace location could not be resolved");
            return;
        };
        if (self.workspace_path.len != 0) self.allocator.free(self.workspace_path);
        self.workspace_path = current;
        if (self.workspace_list) |*list| list.deinit(self.allocator);
        self.workspace_list = WorkspaceLifecycle.list(self.allocator) catch blk: {
            self.setStatus("Workspace list could not be loaded");
            break :blk null;
        };
    }

    fn showWorkspaceText(self: *App, dialog_title: []const u8, labels: []const []const u8, initial: []const []const u8) ?NativeDialogs.Result {
        return NativeDialogs.textWithDescription(
            self.window.hwnd,
            self.allocator,
            dialog_title,
            "Workspace names are normalized to lowercase letters, numbers, and hyphens.",
            labels,
            initial,
        ) catch {
            self.setStatus("Workspace dialog could not be opened");
            return null;
        };
    }

    fn createWorkspace(self: *App) void {
        const result = self.showWorkspaceText("New Workspace", &.{"Name"}, &.{""}) orelse return;
        defer {
            var owned = result;
            owned.deinit(self.allocator);
        }
        const home = std.process.getEnvVarOwned(self.allocator, "USERPROFILE") catch {
            self.setStatus("User profile could not be resolved");
            return;
        };
        defer self.allocator.free(home);
        const name = WorkspaceLifecycle.validateName(self.allocator, result.values[0], home) catch |err| {
            self.setStatus(switch (err) {
                error.EmptyName => "Workspace name is required",
                error.NameTooLong => "Workspace name is too long",
                error.NameTaken => "That workspace already exists",
                else => "Workspace name is invalid",
            });
            return;
        };
        defer self.allocator.free(name);
        const path = WorkspaceLifecycle.workspacePath(self.allocator, name, home) catch {
            self.setStatus("Workspace path could not be prepared");
            return;
        };
        defer self.allocator.free(path);
        std.fs.makeDirAbsolute(path) catch |err| {
            self.setStatus(if (err == error.PathAlreadyExists) "That workspace already exists" else "Workspace could not be created");
            return;
        };
        self.refreshWorkspaceList();
        self.launchWorkspace(path);
    }

    fn launchWorkspace(self: *App, path: []const u8) void {
        const old = std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_SUPPORT_DIR") catch null;
        defer if (old) |value| self.allocator.free(value);
        const key = std.unicode.utf8ToUtf16LeStringLiteral("GRAPHCODE_SUPPORT_DIR");
        const value = std.unicode.utf8ToUtf16LeAllocZ(self.allocator, path) catch {
            self.setStatus("Workspace path could not be encoded");
            return;
        };
        defer self.allocator.free(value);
        if (c.SetEnvironmentVariableW(key.ptr, value.ptr) == 0) {
            self.setStatus("Workspace launch environment could not be set");
            return;
        }
        defer {
            if (old) |previous| {
                if (std.unicode.utf8ToUtf16LeAllocZ(self.allocator, previous)) |previous_wide| {
                    defer self.allocator.free(previous_wide);
                    _ = c.SetEnvironmentVariableW(key.ptr, previous_wide.ptr);
                } else |_| {
                    _ = c.SetEnvironmentVariableW(key.ptr, null);
                }
            } else {
                _ = c.SetEnvironmentVariableW(key.ptr, null);
            }
        }
        var executable: [32768]u16 = undefined;
        const length = c.GetModuleFileNameW(null, &executable, executable.len);
        if (length == 0 or length >= executable.len) {
            self.setStatus("GraphCode executable path could not be resolved");
            return;
        }
        executable[length] = 0;
        var startup: c.STARTUPINFOW = std.mem.zeroes(c.STARTUPINFOW);
        startup.cb = @sizeOf(c.STARTUPINFOW);
        var process: c.PROCESS_INFORMATION = undefined;
        if (c.CreateProcessW(executable[0..length :0].ptr, null, null, null, 0, 0, null, null, &startup, &process) == 0) {
            self.setStatus("Workspace could not be opened");
            return;
        }
        _ = c.CloseHandle(process.hThread);
        _ = c.CloseHandle(process.hProcess);
        self.setStatus("Workspace opened");
    }

    fn workspaceByName(self: *App, name: []const u8) ?WorkspaceLifecycle.Workspace {
        const list = self.workspace_list orelse return null;
        for (list.items) |workspace| {
            if (std.ascii.eqlIgnoreCase(workspace.name, name)) return workspace;
        }
        return null;
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
        const workspace = self.workspaceByName(result.values[0]) orelse {
            self.setStatus("Workspace was not found");
            return;
        };
        if (workspace.is_default or WorkspaceLifecycle.isSamePath(workspace.path, self.workspace_path)) {
            self.setStatus("Switch to another workspace before renaming this one");
            return;
        }
        const home = std.process.getEnvVarOwned(self.allocator, "USERPROFILE") catch return;
        defer self.allocator.free(home);
        const name = WorkspaceLifecycle.validateName(self.allocator, result.values[1], home) catch {
            self.setStatus("Workspace name is invalid or already exists");
            return;
        };
        defer self.allocator.free(name);
        const destination = WorkspaceLifecycle.workspacePath(self.allocator, name, home) catch return;
        defer self.allocator.free(destination);
        std.fs.renameAbsolute(workspace.path, destination) catch {
            self.setStatus("Workspace could not be renamed");
            return;
        };
        self.refreshWorkspaceList();
        self.setStatus("Workspace renamed");
    }

    fn deleteWorkspace(self: *App) void {
        const result = self.showWorkspaceText("Delete Workspace", &.{"Workspace"}, &.{""}) orelse return;
        defer {
            var owned = result;
            owned.deinit(self.allocator);
        }
        const workspace = self.workspaceByName(result.values[0]) orelse {
            self.setStatus("Workspace was not found");
            return;
        };
        if (workspace.is_default or WorkspaceLifecycle.isSamePath(workspace.path, self.workspace_path)) {
            self.setStatus("The default or current workspace cannot be deleted");
            return;
        }
        const dialog_title = std.unicode.utf8ToUtf16LeStringLiteral("Delete Workspace");
        const message = std.unicode.utf8ToUtf16LeStringLiteral(
            "This permanently deletes the workspace folder and all of its projects and loops. Continue?",
        );
        if (c.MessageBoxW(self.window.hwnd, message.ptr, dialog_title.ptr, c.MB_YESNO | c.MB_ICONWARNING | c.MB_DEFBUTTON2) != c.IDYES) {
            self.setStatus("Workspace deletion cancelled");
            return;
        }
        std.fs.deleteTreeAbsolute(workspace.path) catch {
            self.setStatus("Workspace could not be deleted");
            return;
        };
        self.refreshWorkspaceList();
        self.setStatus("Workspace deleted");
    }

    fn cycleWorkspace(self: *App, direction: isize) void {
        const list = self.workspace_list orelse return;
        if (list.items.len < 2) return;
        var index: usize = 0;
        for (list.items, 0..) |workspace, i| {
            if (WorkspaceLifecycle.isSamePath(workspace.path, self.workspace_path)) {
                index = i;
                break;
            }
        }
        const count = @as(isize, @intCast(list.items.len));
        const next = @mod(@as(isize, @intCast(index)) + direction + count, count);
        self.launchWorkspace(list.items[@intCast(next)].path);
    }
};

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
        restoreShellWindow(hwnd);
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
            app.updateNativeChrome();
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
                    var client: c.RECT = undefined;
                    _ = c.GetClientRect(hwnd, &client);
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
                    var client: c.RECT = undefined;
                    _ = c.GetClientRect(hwnd, &client);
                    const bounds = inputBounds(client.right, client.bottom, app.workspace_controls).canvas;
                    app.canvas.zoomBy(@divTrunc(bounds.left + bounds.right, 2), @divTrunc(bounds.top + bounds.bottom, 2), 1.1);
                    app.syncAccessibility();
                    _ = c.InvalidateRect(hwnd, null, 0);
                },
                Accessibility.uia_fit_command => {
                    var client: c.RECT = undefined;
                    _ = c.GetClientRect(hwnd, &client);
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
            app.updateNativeChrome();
            result.* = 0;
            return true;
        },
        c.WM_PAINT => {
            var paint: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(hwnd, &paint);
            const inspection = if (app.worktree_inspection) |*value| blk: {
                const policy = WorktreeStatus.loadPolicy(app.allocator, value.project_path);
                const summary = WorktreeStatus.summarize(value.entries.items);
                var bytes: u64 = 0;
                for (value.entries.items) |entry| bytes += entry.size_bytes;
                const threshold_bytes = @as(u64, policy.notice_size_gb) * 1024 * 1024 * 1024;
                if (summary.total >= policy.notice_count or bytes >= threshold_bytes) break :blk value;
                break :blk null;
            } else null;
            app.update_lock.lock();
            if (app.model.currentGraph()) |graph| app.canvas.syncNodeOffsets(graph.nodes.items);
            const offered_version = if (app.update_state.state == .available) app.update_version else "";
            GraphCanvas.paint(hwnd, hdc, &app.model, inspection, app.selected_worktree_path, app.sidebar_scroll, app.status(), offered_version, app.ingress_error, app.connectionFailureVisible(), app.declared_entry_ids.items, app.kept_worktree_paths.items, app.allocator, &app.canvas, &app.sidebar_state, app.sidebar_hover_y, app.workspace_controls, app.surface);
            app.update_lock.unlock();
            if (app.workspace_controls.panel_visible or app.surface == .workspace) {
                if (app.surface == .workspace) {
                    if (workspaceGraph(&app.model)) |graph| {
                        const workspace_right = clientRight(hwnd) - (if (app.workspace_controls.panel_visible) Tokens.loop_detail_width else 0);
                        TerminalWorkspace.Workspace.paintWorkspaceToolbar(
                            hdc,
                            app.allocator,
                            if (app.workspace_controls.rail_visible) Tokens.sidebar_width else 0,
                            workspace_right,
                            graph.project.name,
                            graph.project.path,
                        );
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
                        if (!app.workspace_controls.panel_visible) GraphCanvas.paintLoopDetailExpandControl(hdc, app.allocator, clientRight(hwnd));
                    }
                }
                if (app.workspace) |workspace| workspace.paintChrome(hdc);
                if (app.surface == .workspace and app.workspace_controls.panel_visible) {
                    if (workspaceGraph(&app.model)) |graph| {
                        const index = app.model.selectedIndex() orelse graph.nodes.items.len;
                        GraphCanvas.paintLoopDetailRail(
                            hdc,
                            app.allocator,
                            graph,
                            index,
                            clientRight(hwnd),
                            clientBottom(hwnd),
                        );
                    }
                }
            }
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
            dismissWedgedUiaForm();
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
                app.updateNativeChrome();
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
        c.WM_KEYDOWN => {
            if (wparam == c.VK_ESCAPE) {
                app.cancelCanvasInteraction();
                result.* = 0;
                return true;
            }
            const ctrl = (@as(i32, c.GetKeyState(c.VK_CONTROL)) & 0x8000) != 0;
            const shift = (@as(i32, c.GetKeyState(c.VK_SHIFT)) & 0x8000) != 0;
            app.handleAction(InputRouter.keyAction(wparam, ctrl, shift));
            app.updateNativeChrome();
            result.* = 0;
            return true;
        },
        c.WM_CAPTURECHANGED, c.WM_CANCELMODE => {
            app.cancelCanvasInteraction();
            result.* = 0;
            return true;
        },
        c.WM_ACTIVATEAPP => {
            if (wparam == 0) app.cancelCanvasInteraction();
            result.* = 0;
            return true;
        },
        c.WM_LBUTTONDOWN => {
            const x = mouseX(lparam);
            const y = mouseY(lparam);
            if (envFlag("GRAPHCODE_UIA_GATE") and x == 0 and y == 0) {
                _ = app.toggleWorktreeRow(0);
                result.* = 0;
                return true;
            }
            var client: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &client);
            if (GraphCanvas.headerActionAt(
                x,
                y,
                client.right,
                app.model.attentionCount() != 0,
                app.worktree_inspection != null,
                app.model.currentGraph() != null,
            )) |action| {
                switch (action) {
                    .review_attention => app.handleAction(.cycle_attention),
                    .inspect_worktrees => app.inspectWorktrees(),
                    .jump => app.handleAction(.jump_next),
                    .toggle_panel => app.handleAction(.toggle_panel),
                }
                _ = c.InvalidateRect(hwnd, null, 0);
                result.* = 0;
                return true;
            }
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
                    if (workspace.chromeActionAt(x, y)) |action| {
                        app.handleAction(switch (action) {
                            .new_tab => .new_tab,
                            .split_right => .split_horizontal,
                            .split_down => .split_vertical,
                        });
                        _ = c.InvalidateRect(hwnd, null, 0);
                        result.* = 0;
                        return true;
                    }
                    if (workspace.tabActionAt(x, y)) |tab_action| {
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
            const point = CanvasInput.decodeMouseMessage(lparam);
            var client: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &client);
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
                        var screen = c.POINT{ .x = point.x, .y = point.y };
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
                                var screen = c.POINT{ .x = point.x, .y = point.y };
                                _ = c.ClientToScreen(hwnd, &screen);
                                GraphContextMenu.show(
                                    hwnd,
                                    .{ .node = .{
                                        .project_path = path,
                                        .id = graph.nodes.items[row.index].id,
                                        .composite = std.mem.eql(u8, graph.nodes.items[row.index].loop_type, "composite") or
                                            std.mem.eql(u8, graph.nodes.items[row.index].loop_type, "proactive"),
                                        .can_arm = std.mem.eql(u8, graph.nodes.items[row.index].pilot_state, "piloted"),
                                    } },
                                    screen.x,
                                    screen.y,
                                    app,
                                    &onContextAction,
                                );
                            }
                        },
                        .quick_chat => if (row.index < app.model.quick_chats.items.len) {
                            var screen = c.POINT{ .x = point.x, .y = point.y };
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
                            var screen = c.POINT{ .x = point.x, .y = point.y };
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
                        var screen = c.POINT{ .x = point.x, .y = point.y };
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
                var screen = c.POINT{ .x = point.x, .y = point.y };
                _ = c.ClientToScreen(hwnd, &screen);
                switch (target) {
                    .background => GraphContextMenu.show(hwnd, .background, screen.x, screen.y, app, &onContextAction),
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
                const point = CanvasInput.decodeMouseMessage(lparam);
                const source_id = app.copyEdgeDragSourceForDrop() orelse {
                    app.cancelCanvasInteraction();
                    result.* = 0;
                    return true;
                };
                defer app.allocator.free(source_id);
                _ = c.ReleaseCapture();
                if (app.model.graph) |graph| {
                    const bounds = c.RECT{ .left = Tokens.sidebar_width, .top = Tokens.header_height, .right = clientRight(hwnd), .bottom = clientBottom(hwnd) - Tokens.workspace_height };
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
            const hover_y = mouseY(lparam);
            const hover_x = mouseX(lparam);
            app.updateSidebarRootDrag(hover_y);
            const next_hover = if (mouseX(lparam) >= 0 and mouseX(lparam) < Tokens.sidebar_width) hover_y else -1;
            if (next_hover != app.sidebar_hover_y) {
                app.sidebar_hover_y = next_hover;
                _ = c.InvalidateRect(hwnd, null, 0);
            }
            if (app.canvas.node_dragging) {
                app.canvas.updateNodeDrag(mouseX(lparam), mouseY(lparam));
                app.syncAccessibility();
                _ = c.InvalidateRect(hwnd, null, 0);
                result.* = 0;
                return true;
            } else if (app.canvas.edge_dragging) {
                app.canvas.updateEdgeDrag(mouseX(lparam), mouseY(lparam));
                _ = c.InvalidateRect(hwnd, null, 0);
                result.* = 0;
                return true;
            } else if (app.canvas.dragging) {
                app.canvas.updatePan(mouseX(lparam), mouseY(lparam));
                _ = c.InvalidateRect(hwnd, null, 0);
                result.* = 0;
                return true;
            }
            if (app.model.graph) |graph| {
                var client: c.RECT = undefined;
                _ = c.GetClientRect(hwnd, &client);
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
            const x = mapped.x;
            const y = mapped.y;
            const delta = wheel.delta;
            var client: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &client);
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
        c.WM_SETFOCUS => {
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
        c.WM_ACTIVATE => {
            // DefWindowProc's default WM_ACTIVATE handling restores keyboard focus to whichever
            // child HWND last held it -- which can be a hidden terminal surface, since that child
            // (not this top-level window) is what actually receives OS focus when winghostty grabs
            // it. Run default processing first so unrelated activation bookkeeping still happens,
            // then reassert our own focus policy so a hidden workspace terminal can never win that
            // restoration race and keep stealing focus away from the rest of the app's chrome.
            const activated = (wparam & 0xffff) != c.WA_INACTIVE;
            result.* = c.DefWindowProcW(hwnd, message, wparam, lparam);
            if (activated) {
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
    const layout_width = @max(0, client.right - Tokens.sidebar_width);
    const layout_height = Tokens.workspace_height;
    const workspace_ready = if (scripted_actions)
        workspace.tabCount() > 0
    else
        workspace.hasSurface(0) and workspace.hasSurface(1) and
            workspace.hasAttach(0) and workspace.hasAttach(1);
    const layout_ok = workspace.layoutMatches(
        Tokens.sidebar_width,
        @max(0, client.bottom - Tokens.workspace_height),
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
