const std = @import("std");
const DaemonClient = @import("DaemonClient.zig").DaemonClient;
const GraphCanvas = @import("GraphCanvas.zig");
const CanvasInput = @import("CanvasInput.zig");
const GraphContextMenu = @import("GraphContextMenu.zig");
const Forms = @import("Forms.zig");
const NativeForms = @import("NativeForms.zig");
const Sidebar = @import("Sidebar.zig");
const GraphModel = @import("GraphModel.zig");
const InputRouter = @import("InputRouter.zig");
const MainWindow = @import("MainWindow.zig");
const TerminalWorkspace = @import("TerminalWorkspace.zig");
const Tokens = @import("DesignTokens.zig");
const Wire = @import("Wire.zig");
const WorktreeStatus = @import("WorktreeStatus.zig");
const TrayModule = @import("Tray.zig");
const Tray = TrayModule.Tray;
const DaemonSupervisor = @import("DaemonSupervisor.zig").Supervisor;
const ProductSettings = @import("WindowsProductSettings.zig");
const RepositoryDialogs = @import("WindowsRepositoryDialogs.zig");
const Onboarding = @import("WindowsOnboarding.zig");
const c = @import("Win32.zig").c;

const title = std.unicode.utf8ToUtf16LeStringLiteral("GraphCode Windows");
const instance_prefix = "Local\\graphcode-windows-";
const tray_test_hook_environment = "GRAPHCODE_TRAY_TEST_HOOK";
const daemon_supervisor_test_hook_environment = "GRAPHCODE_DAEMON_SUPERVISOR_TEST_HOOK";
const daemon_supervisor_test_property =
    std.unicode.utf8ToUtf16LeStringLiteral("GraphCode.Windows.DaemonSupervisorState");
extern fn graphcode_pick_folder(owner: c.HWND, buffer: [*]u16, capacity: c.DWORD) callconv(.c) c_int;

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
    sidebar_scroll: i32 = 0,
    workspace: ?*TerminalWorkspace.Workspace = null,
    instance_mutex: c.HANDLE = null,
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
    smoke_restart_index: ?usize = null,
    smoke_restart_session: []const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) !*App {
        var client = try DaemonClient.init(allocator);
        const app = allocator.create(App) catch |err| {
            client.deinit();
            return err;
        };
        app.* = .{
            .allocator = allocator,
            .client = client,
            .daemon = .{ .allocator = allocator },
            .model = GraphModel.Model.init(allocator),
            .tray_test_hook_enabled = envFlag(tray_test_hook_environment),
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
        if (self.worktree_inspection) |*inspection| {
            WorktreeStatus.deinitInspection(self.allocator, inspection);
        }
        if (self.selected_worktree_path.len != 0) self.allocator.free(self.selected_worktree_path);
        if (self.selected_node_id.len != 0) self.allocator.free(self.selected_node_id);
        if (self.selected_edge_project_path.len != 0) self.allocator.free(self.selected_edge_project_path);
        if (self.selected_edge_id.len != 0) self.allocator.free(self.selected_edge_id);
        if (self.edge_drag_source_id.len != 0) self.allocator.free(self.edge_drag_source_id);
        if (self.instance_mutex != null) _ = c.CloseHandle(self.instance_mutex);
        if (self.last_project_opened.len != 0) self.allocator.free(self.last_project_opened);
        if (self.accepted_subscription.len != 0) self.allocator.free(self.accepted_subscription);
        if (self.pending_project_path.len != 0) self.allocator.free(self.pending_project_path);
        if (self.pending_rebind_path.len != 0) self.allocator.free(self.pending_rebind_path);
        if (self.pending_sent_path.len != 0) self.allocator.free(self.pending_sent_path);
        if (self.pending_previous_subscription.len != 0) self.allocator.free(self.pending_previous_subscription);
        if (self.status_override.len != 0) self.allocator.free(self.status_override);
        if (self.smoke_workspace_actions.len != 0) self.allocator.free(self.smoke_workspace_actions);
        if (self.smoke_restart_session.len != 0) self.allocator.free(self.smoke_restart_session);
        if (self.product_settings_store) |*store| store.deinit();
        if (self.product_settings) |*settings| settings.deinit();
        if (self.onboarding_store) |*store| store.deinit();
        self.allocator.destroy(self);
    }

    pub fn run(self: *App) !void {
        try self.window.create(self, &onWindowMessage, title.ptr);
        self.tray.test_hook_enabled = self.tray_test_hook_enabled;
        self.tray.add(self.window.hwnd) catch self.setStatus("System tray unavailable; GraphCode remains open");
        const endpoint = self.client.currentEndpointName(self.allocator) catch &.{};
        const lock_name = self.client.currentDaemonLockName(self.allocator) catch &.{};
        defer if (endpoint.len != 0) self.allocator.free(endpoint);
        defer if (lock_name.len != 0) self.allocator.free(lock_name);
        if (endpoint.len != 0 and lock_name.len != 0) self.daemon.start(endpoint, lock_name);
        if (envFlag(daemon_supervisor_test_hook_environment)) {
            const state: usize = if (self.daemon.owned) 1 else if (self.daemon.status().len == 0) 2 else 3;
            _ = c.SetPropW(
                self.window.hwnd,
                daemon_supervisor_test_property.ptr,
                @ptrFromInt(state),
            );
        }
        if (self.daemon.status().len != 0) self.setStatus(self.daemon.status());
        self.workspace = try TerminalWorkspace.Workspace.init(self.window.hwnd, self.allocator);
        self.product_settings_store = ProductSettings.Store.init(self.allocator) catch null;
        if (self.product_settings_store) |store| {
            self.product_settings = store.load() catch ProductSettings.Settings.init(self.allocator) catch null;
        }
        self.onboarding_store = Onboarding.Store.init(self.allocator) catch null;
        if (self.onboarding_store) |store| {
            const shell_test = std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_SHELL_REQUIRE_DAEMON") catch null;
            defer if (shell_test) |value| self.allocator.free(value);
            if (shell_test == null or !std.mem.eql(u8, shell_test.?, "1")) {
                Onboarding.showFirstRun(self.window.hwnd, self.allocator, store) catch
                    self.setStatus("First-run onboarding could not be shown");
            }
        }
        self.createEmptyStateControls();
        self.updateNativeChrome();
        if (self.workspace) |workspace| workspace.setKeyCallback(self, &onWorkspaceKey);
        if (self.workspace) |workspace| try workspace.startInputWorker();
        self.layoutWorkspace();
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
                        if (self.model.selectProject(path) and
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
                                if (self.selected_worktree_path.len != 0) {
                                    self.allocator.free(self.selected_worktree_path);
                                    self.selected_worktree_path = &.{};
                                }
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
            .error_occurred => {
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
                    self.replaceStatus(message);
                } else {
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
        var path: [32768]u16 = undefined;
        const picked = graphcode_pick_folder(self.window.hwnd, &path, path.len);
        if (picked < 0) {
            self.setStatus("Unable to open the folder picker");
            return;
        }
        if (picked == 0) return;
        var length: usize = 0;
        while (length < path.len and path[length] != 0) : (length += 1) {}
        const utf8 = std.unicode.utf16LeToUtf8Alloc(self.allocator, path[0..length]) catch {
            self.setStatus("Unable to read the selected folder");
            return;
        };
        defer self.allocator.free(utf8);
        self.openProject(utf8);
    }

    pub fn openGlobalOverview(self: *App) void {
        self.client.sendOpenGlobalGraph();
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
        return null;
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
        self.model.selected_index = index;
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
        if (self.model.selected_index) |index| _ = self.selectNodeIndex(index);
    }

    fn selectedEdgeIndex(self: *const App) ?usize {
        if (self.selected_edge_id.len == 0 or self.selected_edge_project_path.len == 0) return null;
        const graph = self.model.graph orelse return null;
        if (!std.mem.eql(u8, graph.project.path, self.selected_edge_project_path)) return null;
        return GraphModel.findEdgeIndexByID(graph.edges.items, self.selected_edge_id);
    }

    fn createNode(self: *App) void {
        const current_path = self.currentProject() orelse return;
        const path = self.allocator.dupe(u8, current_path) catch return;
        defer self.allocator.free(path);
        const settings = self.product_settings orelse return;
        var draft = NativeForms.node(self.window.hwnd, self.allocator, .{
            .title = "",
            .backend = settings.default_backend,
            .model_tier = if (settings.auto_selects_model) settings.default_model else null,
            .claude_permissions = settings.claude_permissions,
            .copilot_permissions = settings.copilot_permissions,
            .briefing_enabled = settings.briefing,
            .activity_enabled = settings.activity,
        }) catch {
            self.setStatus("Unable to open node form");
            return;
        } orelse return;
        defer draft.deinit(self.allocator);
        Forms.validateNode(draft) catch {
            self.setStatus("Invalid node form");
            return;
        };
        self.client.sendCreateNodeDraft(path, draft);
    }

    fn editSelectedNode(self: *App) void {
        const graph = self.model.graph orelse return;
        const index = self.model.selectedIndex() orelse return;
        if (index >= graph.nodes.items.len) return;
        const project_path = self.allocator.dupe(u8, graph.project.path) catch return;
        defer self.allocator.free(project_path);
        const node_id = self.allocator.dupe(u8, graph.nodes.items[index].id) catch return;
        defer self.allocator.free(node_id);
        const node = graph.nodes.items[index];
        var initial = Forms.NodeUpdate{
            .goal_summary = if (node.goal_summary.len == 0) null else self.allocator.dupe(u8, node.goal_summary) catch null,
            .goal_predicate = if (node.goal_predicate.len == 0) null else self.allocator.dupe(u8, node.goal_predicate) catch null,
            .poll_interval_seconds = node.poll_interval_seconds,
            .stall_after_seconds = node.stall_after_seconds,
            .metric_command = if (node.metric_command.len == 0) null else self.allocator.dupe(u8, node.metric_command) catch null,
            .metric_direction = if (node.metric_direction.len == 0) null else self.allocator.dupe(u8, node.metric_direction) catch null,
            .trigger_prompt = if (node.trigger_prompt.len == 0) null else self.allocator.dupe(u8, node.trigger_prompt) catch null,
            .check_description = if (node.check_description.len == 0) null else self.allocator.dupe(u8, node.check_description) catch null,
            .model_tier = if (node.model_tier.len == 0) null else self.allocator.dupe(u8, node.model_tier) catch null,
        };
        defer initial.deinit(self.allocator);
        var update = NativeForms.update(self.window.hwnd, self.allocator, initial) catch {
            self.setStatus("Unable to open node form");
            return;
        } orelse return;
        defer update.deinit(self.allocator);
        const updated_graph = self.model.graph orelse return;
        if (!std.mem.eql(u8, updated_graph.project.path, project_path)) return;
        const updated_index = GraphModel.findNodeIndexByID(updated_graph.nodes.items, node_id) orelse {
            self.setStatus("Loop changed while editing");
            return;
        };
        self.client.sendUpdateNodeForm(project_path, updated_graph.nodes.items[updated_index].id, update);
    }

    fn createEdge(self: *App) void {
        const graph = self.model.graph orelse return;
        if (graph.nodes.items.len < 2) return;
        const path = self.currentProject() orelse return;
        var draft = NativeForms.edge(self.window.hwnd, self.allocator, .{
            .from = graph.nodes.items[0].id,
            .to = graph.nodes.items[1].id,
            .kind = "handoff",
        }) catch {
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
        const store = self.product_settings_store orelse {
            self.setStatus("Product settings storage unavailable");
            return;
        };
        var current = store.load() catch ProductSettings.Settings.init(self.allocator) catch {
            self.setStatus("Unable to load product settings");
            return;
        };
        defer current.deinit();
        const draft = ProductSettings.open(self.window.hwnd, self.allocator, current) catch {
            self.setStatus("Unable to open product settings");
            return;
        } orelse return;
        store.save(draft) catch {
            self.setStatus("Unable to save product settings");
            return;
        };
        if (self.product_settings) |*settings| settings.deinit();
        self.product_settings = draft;
    }

    fn cloneRepository(self: *App) void {
        const draft = RepositoryDialogs.openClone(self.window.hwnd, self.allocator, .{}) catch {
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
            self.setStatus(@errorName(err));
            return;
        };
        self.setStatus("Cloning repository…");
        const clone_status = RepositoryDialogs.runClone(self.allocator, draft) catch {
            self.setStatus("Clone failed");
            return;
        };
        self.setStatus(if (clone_status == .finished) "Clone complete" else "Clone failed");
    }

    fn addRemoteRepository(self: *App) void {
        const draft = RepositoryDialogs.openRemote(self.window.hwnd, self.allocator, .{}) catch {
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
            self.setStatus(@errorName(err));
            return;
        };
        RepositoryDialogs.validateRemoteConnection(self.allocator, draft) catch |err| {
            self.setStatus(@errorName(err));
            return;
        };
        RepositoryDialogs.saveRemoteConfig(self.allocator, draft) catch {
            self.setStatus("SSH validated but remote configuration could not be saved");
            return;
        };
        const remote_path = std.fmt.allocPrint(self.allocator, "ssh://{s}@{s}:{s}{s}", .{
            draft.user, draft.host, draft.port, draft.path,
        }) catch {
            self.setStatus("Unable to encode remote repository");
            return;
        };
        defer self.allocator.free(remote_path);
        self.client.sendOpenProject(remote_path);
        self.client.reconnect();
        self.setStatus("SSH repository connected; reconnect requested");
    }

    fn jumpToNode(self: *App) void {
        if (self.model.graph == null) {
            self.setStatus("No graph is open");
            return;
        }
        const current_id = self.allocator.dupe(u8, self.selected_node_id) catch return;
        defer self.allocator.free(current_id);
        const query = NativeForms.jump(self.window.hwnd, self.allocator, "") catch {
            self.setStatus("Unable to open jump form");
            return;
        } orelse return;
        defer self.allocator.free(query);
        const trimmed_query = Forms.validateJumpQuery(query) catch {
            self.setStatus("Enter a jump query");
            return;
        };
        const graph = self.model.graph orelse {
            self.setStatus("Graph closed while jumping");
            return;
        };
        const current_index = if (current_id.len == 0) null else GraphModel.findNodeIndexByID(graph.nodes.items, current_id);
        const next = Forms.jumpTo(graph.nodes.items, trimmed_query, current_index) orelse {
            self.setStatus("No matching loop");
            return;
        };
        _ = self.selectNodeIndex(next);
        self.sidebar_scroll = Sidebar.clampScroll(
            Sidebar.loopRowTop(self.model.recent_projects.items.len, next) - 24,
            Sidebar.maxScroll(&self.model, if (self.worktree_inspection) |*value| value else null, 700),
        );
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
    }

    fn openSelectedNode(self: *App) void {
        const graph = if (self.model.graph) |value| value else return;
        const index = self.model.selectedIndex() orelse return;
        if (index >= graph.nodes.items.len) return;
        const workspace = if (self.workspace) |value| value else return;
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
        if (!GraphContextMenu.confirm(self.window.hwnd, "Delete Loop", "Delete this loop? This cannot be undone.")) return;
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
        if (!GraphContextMenu.confirm(self.window.hwnd, "Delete Edge", "Delete this edge?")) return;
        const updated_graph = self.model.graph orelse return;
        const updated_index = GraphModel.findEdgeIndexByID(updated_graph.edges.items, edge_id) orelse return;
        self.client.sendDeleteEdge(project_path, updated_graph.edges.items[updated_index].id);
    }

    fn showNodeContextMenu(self: *App, index: usize, x: i32, y: i32) void {
        const graph = self.model.graph orelse return;
        if (index >= graph.nodes.items.len) return;
        const project_path = self.allocator.dupe(u8, graph.project.path) catch return;
        defer self.allocator.free(project_path);
        const node_id = self.allocator.dupe(u8, graph.nodes.items[index].id) catch return;
        defer self.allocator.free(node_id);
        GraphContextMenu.show(
            self.window.hwnd,
            .{ .node = .{ .project_path = project_path, .id = node_id } },
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

    fn handleContextAction(self: *App, action: GraphContextMenu.Action, target: GraphContextMenu.Target) void {
        switch (target) {
            .node => |stable| {
                const graph = self.model.graph orelse return;
                if (!std.mem.eql(u8, graph.project.path, stable.project_path)) return;
                const index = GraphModel.findNodeIndexByID(graph.nodes.items, stable.id) orelse return;
                if (!self.selectNodeIndex(index)) return;
                switch (action) {
                    .rename_node => self.editSelectedNode(),
                    .stop_node => self.stopSelectedNode(),
                    .delete_node => self.deleteSelectedNode(),
                    .open_terminal => self.openSelectedNode(),
                    .message_node => self.sendSelectedNode(),
                    .memo_node => self.sendSelectedNode(),
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
            .background => if (action == .create_edge) self.createEdge(),
        }
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
    }

    fn inspectWorktrees(self: *App) void {
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
        if (self.selected_worktree_path.len != 0) {
            self.allocator.free(self.selected_worktree_path);
            self.selected_worktree_path = &.{};
        }
        self.worktree_inspection = inspection;
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
        if (self.selected_worktree_path.len == 0) {
            self.setStatus("Select a worktree row before reclaiming");
            return;
        }
        var selected = [_][]const u8{self.selected_worktree_path};
        var bindings = std.array_list.Managed(WorktreeStatus.Binding).init(self.allocator);
        defer bindings.deinit();
        if (self.model.graph) |graph| for (graph.nodes.items) |bound| {
            if (bound.worktree_path.len != 0) bindings.append(.{ .path = bound.worktree_path }) catch {};
        };
        const removed = WorktreeStatus.reclaimSelected(self.allocator, path, &selected, bindings.items) catch |err| {
            self.setStatus(switch (err) {
                error.GitFailed => "Reclaim failed: git refused a selected worktree",
                else => "Reclaim failed",
            });
            return;
        };
        const message = std.fmt.allocPrint(
            self.allocator,
            "Reclaimed {d} selected worktrees",
            .{removed},
        ) catch {
            self.setStatus("Reclaim complete");
            return;
        };
        self.replaceStatus(message);
        self.inspectWorktrees();
    }

    pub fn selectWorktreeRow(self: *App, path: []const u8) bool {
        const inspection = self.worktree_inspection orelse return false;
        if (self.currentProject()) |project| {
            if (!std.mem.eql(u8, project, inspection.project_path)) return false;
        } else return false;
        for (inspection.entries.items) |entry| {
            if (!std.mem.eql(u8, entry.path, path)) continue;
            if (WorktreeStatus.decision(entry) != .reclaimable) return false;
            if (self.selected_worktree_path.len != 0) self.allocator.free(self.selected_worktree_path);
            self.selected_worktree_path = self.allocator.dupe(u8, path) catch return false;
            return true;
        }
        return false;
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
        const top = Sidebar.worktreeRowTop(self.model.recent_projects.items.len, loop_count, index) - self.sidebar_scroll;
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
            Sidebar.maxScroll(&self.model, inspection, client.bottom - Tokens.workspace_height),
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
            .settings => self.openSettings(),
            .product_settings => self.openProductSettings(),
            .clone_repository => self.cloneRepository(),
            .remote_repository => self.addRemoteRepository(),
            .onboarding => if (self.onboarding_store) |store|
                Onboarding.showFirstRun(self.window.hwnd, self.allocator, store) catch
                    self.setStatus("Unable to show onboarding"),
            .cycle_attention => {
                self.selectNextAttention();
                _ = c.InvalidateRect(self.window.hwnd, null, 0);
            },
            .inspect_worktrees => self.inspectWorktrees(),
            .reclaim_worktrees => self.reclaimWorktrees(),
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
            .none => {},
        }
    }

    fn onWorkspaceKey(context: ?*anyopaque, key: usize, ctrl: bool, shift: bool) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(context.?));
        app.dispatchWorkspaceKey(key, ctrl, shift);
    }

    fn dispatchWorkspaceKey(self: *App, key: usize, ctrl: bool, shift: bool) void {
        self.handleAction(InputRouter.keyAction(key, ctrl, shift));
    }

    fn layoutWorkspace(self: *App) void {
        var client: c.RECT = undefined;
        if (c.GetClientRect(self.window.hwnd, &client) == 0) return;
        if (self.workspace) |workspace| {
            workspace.resize(
                Tokens.sidebar_width,
                @max(0, client.bottom - Tokens.workspace_height),
                @max(0, client.right - Tokens.sidebar_width),
                Tokens.workspace_height,
            );
        }
    }

    fn status(self: *const App) []const u8 {
        if (self.status_override.len != 0) return self.status_override;
        return self.client.statusText();
    }

    fn createEmptyStateControls(self: *App) void {
        self.empty_open_folder_button = createButton(
            self.window.hwnd,
            "Open Folder...",
            MainWindow.empty_open_folder_id,
        );
        self.empty_global_overview_button = createButton(
            self.window.hwnd,
            "Open Global Overview",
            MainWindow.empty_global_overview_id,
        );
        self.layoutEmptyStateControls();
    }

    fn layoutEmptyStateControls(self: *App) void {
        var client: c.RECT = undefined;
        if (c.GetClientRect(self.window.hwnd, &client) == 0) return;
        const visible = self.model.graph == null;
        const x = Tokens.sidebar_width + 48;
        const y = Tokens.header_height + 160;
        for ([_]c.HWND{ self.empty_open_folder_button, self.empty_global_overview_button }, 0..) |button, index| {
            if (button == null) continue;
            _ = c.ShowWindow(button, if (visible) c.SW_SHOW else c.SW_HIDE);
            _ = c.SetWindowPos(button, null, x, y + @as(i32, @intCast(index * 42)), 220, 32, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
        }
    }

    fn createButton(parent: c.HWND, text: []const u8, id: usize) c.HWND {
        const wide = std.unicode.utf8ToUtf16LeAlloc(std.heap.c_allocator, text) catch return null;
        defer std.heap.c_allocator.free(wide);
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

    fn controlId(value: usize) c.HMENU {
        @setRuntimeSafety(false);
        return @ptrFromInt(value);
    }

    fn updateNativeChrome(self: *App) void {
        MainWindow.updateMenu(self.window.hwnd, .{
            .has_project = self.model.graph != null,
            .can_worktrees = if (self.model.graph) |graph| graph.project.isLocalFilesystem() else false,
            .has_workspace = self.workspace != null and self.model.graph != null,
            .has_attention = self.model.attentionCount() != 0,
            .can_close_tab = if (self.workspace) |workspace| workspace.tabCount() > 1 else false,
        });
        self.layoutEmptyStateControls();
    }

    fn setStatus(self: *App, value: []const u8) void {
        const copy = self.allocator.dupe(u8, value) catch return;
        self.replaceStatus(copy);
    }

    fn replaceStatus(self: *App, value: []u8) void {
        if (self.status_override.len != 0) self.allocator.free(self.status_override);
        self.status_override = value;
    }

    fn acquireSingleInstance(self: *App) !void {
        const user = std.process.getEnvVarOwned(self.allocator, "USERNAME") catch
            try std.process.getEnvVarOwned(self.allocator, "USER");
        defer self.allocator.free(user);
        const name = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ instance_prefix, user });
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
        c.WM_INITMENUPOPUP => {
            app.updateNativeChrome();
            result.* = 0;
            return true;
        },
        c.WM_COMMAND => {
            const tray_command = @as(c.WPARAM, @intCast(@as(usize, @bitCast(wparam)) & 0xffff));
            if (tray_command == TrayModule.command_open) {
                restoreShellWindow(hwnd);
                result.* = 0;
                return true;
            }
            if (tray_command == TrayModule.command_exit) {
                app.exit_requested = true;
                _ = c.DestroyWindow(hwnd);
                result.* = 0;
                return true;
            }
            const id: usize = @intCast(@as(u16, @truncate(wparam)));
            if (id == MainWindow.empty_open_folder_id) {
                app.openFolder();
            } else if (id == MainWindow.empty_global_overview_id) {
                app.openGlobalOverview();
            } else if (MainWindow.commandFromId(id)) |command| {
                switch (command) {
                    .open_folder => app.openFolder(),
                    .open_global_overview => app.openGlobalOverview(),
                    .worktrees => app.handleAction(.inspect_worktrees),
                    .reclaim_worktrees => app.handleAction(.reclaim_worktrees),
                    .exit => _ = c.DestroyWindow(hwnd),
                    .jump_loop => app.handleAction(.jump_next),
                    .review_attention => app.handleAction(.cycle_attention),
                    .next_loop => app.handleAction(.select_next),
                    .previous_loop => app.handleAction(.select_previous),
                    .create_node => app.handleAction(.create_node),
                    .create_edge => app.handleAction(.create_edge),
                    .stop_loop => app.handleAction(.stop_node),
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
                    .about => app.setStatus("GraphCode Windows — native Win32 shell"),
                }
            }
            app.updateNativeChrome();
            result.* = 0;
            return true;
        },
        c.WM_PAINT => {
            var paint: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(hwnd, &paint);
            const inspection = if (app.worktree_inspection) |*value| value else null;
            GraphCanvas.paint(hwnd, hdc, &app.model, inspection, app.selected_worktree_path, app.sidebar_scroll, app.status(), app.allocator, &app.canvas);
            if (app.workspace) |workspace| workspace.paintChrome(hdc);
            _ = c.EndPaint(hwnd, &paint);
            result.* = 0;
            return true;
        },
        c.WM_SIZE => {
            app.layoutWorkspace();
            app.clampSidebarScroll();
            app.layoutEmptyStateControls();
            result.* = 0;
            return true;
        },
        c.WM_TIMER => if (wparam == MainWindow.timer_id) {
            app.smoke_tick += 1;
            if (!app.tray.added and app.smoke_tick % 10 == 0) {
                app.tray.add(hwnd) catch app.setStatus("System tray unavailable; retrying");
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
            if (app.smoke and app.smoke_tick == 16 and
                app.client.connectionState() == .connected and !app.smoke_action_requested)
            {
                app.smoke_action_requested = true;
                app.sendSelectedNode();
            }
            if (app.smoke and app.smoke_tick == 16 and !app.smoke_input_requested and
                envFlag("GRAPHCODE_SHELL_LARGE_PASTE"))
            {
                app.smoke_input_requested = true;
                if (app.workspace) |workspace| {
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
            var client: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &client);
            const workspace_top = client.bottom - Tokens.workspace_height;
            if (x >= Tokens.sidebar_width and y >= workspace_top) {
                if (app.workspace) |workspace| {
                    if (workspace.selectTabAt(x, y)) {
                        result.* = 0;
                        return true;
                    }
                }
            }
            if (x >= Tokens.sidebar_width and y < workspace_top) {
                const bounds = c.RECT{ .left = Tokens.sidebar_width, .top = Tokens.header_height, .right = client.right, .bottom = workspace_top };
                if (app.model.graph) |graph| {
                    if (GraphCanvas.hitTestConnector(graph.nodes.items, x, y, &app.canvas, bounds)) |index| {
                        if (app.edge_drag_source_id.len != 0) app.allocator.free(app.edge_drag_source_id);
                        app.edge_drag_source_id = app.allocator.dupe(u8, graph.nodes.items[index].id) catch &.{};
                        if (app.edge_drag_source_id.len != 0) {
                            app.canvas.beginEdgeDrag(app.edge_drag_source_id, x, y);
                            _ = c.SetCapture(hwnd);
                        }
                    } else if (GraphCanvas.hitTest(graph.nodes.items, x, y, &app.canvas, bounds)) |index| {
                        _ = app.selectNodeIndex(index);
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
                }
                result.* = 0;
                return true;
            }
            if (Sidebar.rowAt(x, y, &app.model, if (app.worktree_inspection) |*value| value else null, app.sidebar_scroll, workspace_top)) |row| {
                switch (row.kind) {
                    .project => app.openProject(app.model.recent_projects.items[row.index].path),
                    .open_project => if (row.project_path) |path| {
                        if (app.model.selectProject(path)) {
                            app.clearEdgeSelection();
                            app.rebindWorkspace(path);
                        }
                    },
                    .overview => app.client.sendOpenGlobalGraph(),
                    .loop => if (row.project_path) |path| if (app.model.graphFor(path)) |graph| {
                        if (row.index < graph.nodes.items.len) {
                            if (!app.model.selectProject(path)) return true;
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
                        _ = app.selectWorktreeRow(inspection.entries.items[row.index].path);
                        app.ensureWorktreeVisible(row.index);
                    },
                }
                _ = c.InvalidateRect(hwnd, null, 0);
                result.* = 0;
                return true;
            }
            result.* = 0;
            return true;
        },
        c.WM_RBUTTONUP => {
            const point = CanvasInput.decodeMouseMessage(lparam);
            var client: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &client);
            const workspace_top = client.bottom - Tokens.workspace_height;
            if (point.x >= Tokens.sidebar_width and point.y >= Tokens.header_height and point.y < workspace_top) {
                const bounds = c.RECT{ .left = Tokens.sidebar_width, .top = Tokens.header_height, .right = client.right, .bottom = workspace_top };
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
            }
            result.* = 0;
            return true;
        },
        c.WM_MOUSEMOVE => {
            if (app.canvas.edge_dragging) {
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
            const workspace_top = client.bottom - Tokens.workspace_height;
            if (x < Tokens.sidebar_width) {
                app.sidebar_scroll = Sidebar.clampScroll(app.sidebar_scroll - @divTrunc(@as(i32, delta), 4), Sidebar.maxScroll(&app.model, if (app.worktree_inspection) |*value| value else null, workspace_top));
            } else if (y < workspace_top) {
                const bounds = c.RECT{ .left = Tokens.sidebar_width, .top = Tokens.header_height, .right = client.right, .bottom = workspace_top };
                if (x >= bounds.left and y >= bounds.top and y < bounds.bottom) {
                    app.canvas.zoomAt(x, y, delta);
                }
            }
            _ = c.InvalidateRect(hwnd, null, 0);
            result.* = 0;
            return true;
        },
        c.WM_SETFOCUS => {
            if (app.workspace) |workspace| workspace.focus(workspace.active_surface);
            result.* = 0;
            return true;
        },
        c.WM_CLOSE => {
            hideShellWindow(hwnd);
            result.* = 0;
            return true;
        },
        c.WM_DESTROY => {
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
        .model = undefined,
    };
    app.edge_drag_source_id = try allocator.dupe(u8, "source-node");
    app.canvas.beginEdgeDrag(app.edge_drag_source_id, 10, 10);

    const copied = app.copyEdgeDragSourceForDrop() orelse return error.MissingSource;
    defer allocator.free(copied);
    app.cancelCanvasInteraction();

    try std.testing.expectEqualStrings("source-node", copied);
    try std.testing.expectEqual(@as(usize, 0), app.edge_drag_source_id.len);
    try std.testing.expect(!app.canvas.edge_dragging);
}
