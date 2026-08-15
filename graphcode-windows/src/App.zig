const std = @import("std");
const DaemonClient = @import("DaemonClient.zig").DaemonClient;
const GraphCanvas = @import("GraphCanvas.zig");
const CanvasInput = @import("CanvasInput.zig");
const GraphModel = @import("GraphModel.zig");
const InputRouter = @import("InputRouter.zig");
const Forms = @import("Forms.zig");
const NativeForms = @import("NativeForms.zig");
const MainWindow = @import("MainWindow.zig");
const Sidebar = @import("Sidebar.zig");
const TerminalWorkspace = @import("TerminalWorkspace.zig");
const Tokens = @import("DesignTokens.zig");
const Wire = @import("Wire.zig");
const WorktreeStatus = @import("WorktreeStatus.zig");
const c = @import("Win32.zig").c;

const title = std.unicode.utf8ToUtf16LeStringLiteral("GraphCode Windows");
const instance_prefix = "Local\\graphcode-windows-";

pub const App = struct {
    allocator: std.mem.Allocator,
    window: MainWindow.Window = .{},
    client: DaemonClient,
    model: GraphModel.Model,
    canvas: GraphCanvas.CanvasState = .{},
    worktree_inspection: ?WorktreeStatus.Inspection = null,
    workspace: ?TerminalWorkspace.Workspace = null,
    instance_mutex: c.HANDLE = null,
    sync_requested: bool = false,
    restore_requested: bool = false,
    open_project_pending: bool = false,
    last_connection_state: Wire.ConnectionState = .disconnected,
    last_project_opened: []const u8 = "",
    pending_project_path: []u8 = &.{},
    status_override: []u8 = &.{},
    running: bool = true,
    smoke: bool = false,
    stress: bool = false,
    require_smoke_contract: bool = false,
    smoke_failure: bool = false,
    smoke_tick: usize = 0,
    smoke_action_requested: bool = false,
    smoke_input_requested: bool = false,
    smoke_workspace_stage: u8 = 0,
    smoke_workspace_actions_done: bool = false,
    smoke_idle_ticks: usize = 0,
    sidebar_scroll: i32 = 0,
    context_node: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) !*App {
        var client = try DaemonClient.init(allocator);
        const app = allocator.create(App) catch |err| {
            client.deinit();
            return err;
        };
        app.* = .{
            .allocator = allocator,
            .client = client,
            .model = GraphModel.Model.init(allocator),
        };
        errdefer app.deinit();
        try app.client.start();
        try app.acquireSingleInstance();
        return app;
    }

    pub fn deinit(self: *App) void {
        if (self.workspace) |*workspace| workspace.deinit();
        self.client.deinit();
        self.model.deinit();
        if (self.worktree_inspection) |*inspection| {
            WorktreeStatus.deinit(self.allocator, &inspection.entries);
            self.allocator.free(inspection.default_branch);
        }
        if (self.instance_mutex != null) _ = c.CloseHandle(self.instance_mutex);
        if (self.last_project_opened.len != 0) self.allocator.free(self.last_project_opened);
        if (self.pending_project_path.len != 0) self.allocator.free(self.pending_project_path);
        if (self.status_override.len != 0) self.allocator.free(self.status_override);
        self.allocator.destroy(self);
    }

    pub fn run(self: *App) !void {
        try self.window.create(self, &onWindowMessage, title.ptr);
        self.workspace = try TerminalWorkspace.Workspace.init(self.window.hwnd, self.allocator);
        if (self.workspace) |*workspace| workspace.setKeyCallback(self, &onWorkspaceKey);
        if (self.workspace) |*workspace| try workspace.startInputWorker();
        self.layoutWorkspace();
        if (std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_SHELL_REQUIRE_DAEMON")) |value| {
            defer self.allocator.free(value);
            self.require_smoke_contract = std.mem.eql(u8, value, "1");
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
        const event = self.model.updateFromFrame(frame) catch {
            self.setStatus("Malformed GraphcodeKit event");
            return;
        };
        switch (event) {
            .recent_projects => {
                if (self.model.graph == null and self.model.recent_projects.items.len != 0) {
                    self.queueProject(self.model.recent_projects.items[0].path);
                }
            },
            .graph_changed => {
                if (self.model.graph) |graph| {
                    self.rebindWorkspace(graph.project.path);
                    self.queueProject(graph.project.path);
                }
                self.refreshWorkspace();
            },
            .error_occurred => {
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
        const workspace = if (self.workspace) |*value| value else return;
        const graph = if (self.model.graph) |*value| value else return;
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

    fn openProject(self: *App, path: []const u8) void {
        if (path.len == 0) return;
        if (self.workspace) |*workspace| {
            workspace.setProject(path) catch self.setStatus("Unable to restore project terminal layout");
        }
        self.client.setSubscription(path);
        if (self.last_project_opened.len != 0) self.allocator.free(self.last_project_opened);
        self.last_project_opened = self.allocator.dupe(u8, path) catch {
            self.setStatus("Unable to retain project subscription");
            return;
        };
        self.open_project_pending = true;
        if (self.client.connectionState() == .connected) {
            self.client.sendOpenProject(path);
            self.open_project_pending = false;
        }
    }

    fn rebindWorkspace(self: *App, path: []const u8) void {
        const workspace = if (self.workspace) |*value| value else return;
        _ = workspace.rebindProject(path) catch {
            self.setStatus("Unable to rebind terminal workspace");
            return;
        };
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
        if (self.model.graph) |graph| return graph.project.path;
        if (self.model.recent_projects.items.len != 0) return self.model.recent_projects.items[0].path;
        return null;
    }

    fn createNode(self: *App) void {
        const path = self.currentProject() orelse return;
        if (self.smoke) {
            self.client.sendCreateNode(path, "Windows shell node");
            return;
        }
        const draft = NativeForms.node(self.window.hwnd, self.allocator, .{ .title = "Windows shell node" }) catch {
            self.setStatus("Unable to open node form");
            return;
        } orelse return;
        defer {
            self.allocator.free(draft.title);
            self.allocator.free(draft.loop_type);
        }
        Forms.validateNode(draft) catch {
            self.setStatus("Node title and loop type are required");
            return;
        };
        self.client.sendCreateNode(path, draft.title);
    }

    fn editSelectedNode(self: *App) void {
        const path = self.currentProject() orelse return;
        const node = self.model.selected() orelse return;
        const draft = NativeForms.node(self.window.hwnd, self.allocator, .{
            .title = node.title,
            .loop_type = node.loop_type,
        }) catch {
            self.setStatus("Unable to open node form");
            return;
        } orelse return;
        defer {
            self.allocator.free(draft.title);
            self.allocator.free(draft.loop_type);
        }
        Forms.validateNode(draft) catch {
            self.setStatus("Node title and loop type are required");
            return;
        };
        self.client.sendRenameNode(path, node.id, draft.title);
    }

    fn createEdge(self: *App) void {
        const path = self.currentProject() orelse return;
        const draft = NativeForms.edge(self.window.hwnd, self.allocator, .{ .from = "", .to = "" }) catch {
            self.setStatus("Unable to open edge form");
            return;
        } orelse return;
        defer {
            self.allocator.free(draft.from);
            self.allocator.free(draft.to);
            self.allocator.free(draft.kind);
        }
        Forms.validateEdge(draft) catch {
            self.setStatus("Edge requires distinct source and target nodes");
            return;
        };
        self.client.sendCreateEdge(path, draft.from, draft.to, draft.kind);
    }

    fn showSettings(self: *App) void {
        const pipe = std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_DAEMON_PIPE") catch
            (self.allocator.dupe(u8, "") catch {
                self.setStatus("Unable to read daemon settings");
                return;
            });
        const support = std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_SUPPORT_DIR") catch
            (self.allocator.dupe(u8, "") catch {
                self.allocator.free(pipe);
                self.setStatus("Unable to read daemon settings");
                return;
            });
        const maybe_settings = NativeForms.settings(self.window.hwnd, self.allocator, .{
            .daemon_pipe = pipe,
            .support_directory = support,
        }) catch {
            self.allocator.free(pipe);
            self.allocator.free(support);
            self.setStatus("Unable to open settings");
            return;
        };
        const settings = maybe_settings orelse {
            self.allocator.free(pipe);
            self.allocator.free(support);
            return;
        };
        defer {
            self.allocator.free(pipe);
            self.allocator.free(support);
        }
        defer {
            self.allocator.free(settings.daemon_pipe);
            self.allocator.free(settings.support_directory);
        }
        self.client.validateSettings(settings.daemon_pipe, settings.support_directory) catch |err| {
            self.setStatus(settingsErrorText(err));
            return;
        };
        if (!setEnvironmentVariable(self.allocator, "GRAPHCODE_DAEMON_PIPE", settings.daemon_pipe)) {
            self.setStatus("Unable to apply daemon pipe setting");
            return;
        }
        if (!setEnvironmentVariable(self.allocator, "GRAPHCODE_SUPPORT_DIR", settings.support_directory)) {
            _ = setEnvironmentVariable(self.allocator, "GRAPHCODE_DAEMON_PIPE", pipe);
            self.setStatus("Unable to apply support directory setting");
            return;
        }
        self.client.reconnect();
        self.setStatus("Daemon settings applied; reconnecting");
    }

    fn openSelectedNode(self: *App) void {
        const graph = if (self.model.graph) |*value| value else return;
        const index = self.model.selected_node orelse return;
        if (index >= graph.nodes.items.len) return;
        const workspace = if (self.workspace) |*value| value else return;
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

    fn inspectWorktrees(self: *App) void {
        const path = self.currentProject() orelse {
            self.setStatus("No project selected for worktree inspection");
            return;
        };
        const inspection = WorktreeStatus.inspect(self.allocator, path) catch |err| {
            self.setStatus(switch (err) {
                error.EmptyProjectPath => "Worktree inspection needs a project path",
                error.GitFailed => "Worktree inspection failed: git returned an error",
                else => "Worktree inspection failed",
            });
            return;
        };
        if (self.worktree_inspection) |*old| {
            WorktreeStatus.deinit(self.allocator, &old.entries);
            self.allocator.free(old.default_branch);
        }
        self.worktree_inspection = inspection;
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
        const inspection = self.worktree_inspection orelse {
            self.setStatus("Inspect worktrees first; nothing selected to reclaim");
            return;
        };
        const removed = WorktreeStatus.reclaim(self.allocator, inspection.entries.items) catch |err| {
            self.setStatus(switch (err) {
                error.GitFailed => "Reclaim failed: git refused a selected worktree",
                else => "Reclaim failed",
            });
            return;
        };
        const message = std.fmt.allocPrint(
            self.allocator, "Reclaimed {d} selected worktrees", .{removed},
        ) catch {
            self.setStatus("Reclaim complete");
            return;
        };
        self.replaceStatus(message);
        self.inspectWorktrees();
    }

    fn handleAction(self: *App, action: InputRouter.Action) void {
        switch (action) {
            .reconnect => {
                self.client.reconnect();
            },
            .create_node => self.createNode(),
            .open_node => self.openSelectedNode(),
            .stop_node => self.stopSelectedNode(),
            .send_node => self.sendSelectedNode(),
            .edit_node => self.editSelectedNode(),
            .create_edge => self.createEdge(),
            .jump_next => {
                if (self.model.graph != null) {
                    self.model.selectNext();
                    _ = c.InvalidateRect(self.window.hwnd, null, 0);
                }
            },
            .settings => self.showSettings(),
            .cycle_attention => {
                self.model.selectNextAttention();
                _ = c.InvalidateRect(self.window.hwnd, null, 0);
            },
            .inspect_worktrees => self.inspectWorktrees(),
            .reclaim_worktrees => self.reclaimWorktrees(),
            .focus_terminal_a => if (self.workspace) |*workspace| workspace.focus(0),
            .focus_terminal_b => if (self.workspace) |*workspace| workspace.focus(1),
            .select_next => {
                self.model.selectNext();
                _ = c.InvalidateRect(self.window.hwnd, null, 0);
            },
            .new_tab => if (self.workspace) |*workspace|
                workspace.newTab() catch self.setStatus("Unable to create terminal tab"),
            .close_tab => if (self.workspace) |*workspace| {
                workspace.closeFocusedPane() catch self.setStatus("Unable to close terminal pane");
            },
            .split_horizontal => if (self.workspace) |*workspace|
                workspace.splitFocused(.horizontal) catch self.setStatus("Unable to split terminal"),
            .split_vertical => if (self.workspace) |*workspace|
                workspace.splitFocused(.vertical) catch self.setStatus("Unable to split terminal"),
            .focus_next_pane => if (self.workspace) |*workspace| workspace.focusNextPane(),
            .focus_previous_pane => if (self.workspace) |*workspace| workspace.focusPreviousPane(),
            .select_previous_tab => if (self.workspace) |*workspace| workspace.selectPreviousTab(),
            .select_next_tab => if (self.workspace) |*workspace| workspace.selectNextTab(),
            .none => {},
        }
    }

    fn handleSidebarClick(self: *App, x: i32, y: i32) void {
        var client: c.RECT = undefined;
        if (c.GetClientRect(self.window.hwnd, &client) == 0) return;
        var rows = Sidebar.buildRows(&self.model, self.allocator, client.bottom) catch return;
        defer rows.deinit();
        _ = Sidebar.layoutRows(rows.items, Tokens.header_height, Sidebar.viewportBottom(client.bottom), self.sidebar_scroll);
        const row = Sidebar.hitTest(rows.items, x, y) orelse return;
        switch (row.kind) {
            .overview => {
                self.rebindWorkspace("graphcode://global");
                self.client.sendOpenGlobalGraph();
            },
            .quick_chats => self.setStatus("Quick Chats are not provided by the daemon"),
            .project => self.openProject(row.path),
            .loop => {
                self.model.selected_node = row.node_index;
                self.openSelectedNode();
            },
            .local_section, .remote_section => {},
        }
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
    }

    fn scrollSidebar(self: *App, delta: i32) void {
        var client: c.RECT = undefined;
        if (c.GetClientRect(self.window.hwnd, &client) == 0) return;
        var rows = Sidebar.buildRows(&self.model, self.allocator, client.bottom) catch return;
        defer rows.deinit();
        const viewport_bottom = Sidebar.viewportBottom(client.bottom);
        const content_height = Sidebar.layoutRows(rows.items, Tokens.header_height, viewport_bottom, 0);
        const max_scroll = @max(0, content_height - viewport_bottom);
        self.sidebar_scroll = @max(0, @min(max_scroll, self.sidebar_scroll + delta));
        _ = c.InvalidateRect(self.window.hwnd, null, 0);
    }

    fn layoutWorkspace(self: *App) void {
        var client: c.RECT = undefined;
        if (c.GetClientRect(self.window.hwnd, &client) == 0) return;
        if (self.workspace) |*workspace| {
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

fn onWorkspaceKey(context: ?*anyopaque, key: usize, ctrl: bool, shift: bool) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(context.?));
    app.handleAction(InputRouter.keyAction(key, ctrl, shift));
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

fn onWindowMessage(
    context: ?*anyopaque,
    hwnd: c.HWND,
    message: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
    result: *c.LRESULT,
) callconv(.c) bool {
    const app: *App = @ptrCast(@alignCast(context.?));
    switch (message) {
        c.WM_PAINT => {
            var paint: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(hwnd, &paint);
            GraphCanvas.paint(
                hwnd,
                hdc,
                &app.model,
                app.status(),
                app.allocator,
                app.sidebar_scroll,
                &app.canvas,
            );
            if (app.workspace) |*workspace| workspace.paintChrome(hdc);
            _ = c.EndPaint(hwnd, &paint);
            result.* = 0;
            return true;
        },
        c.WM_SIZE => {
            app.layoutWorkspace();
            result.* = 0;
            return true;
        },
        c.WM_TIMER => if (wparam == MainWindow.timer_id) {
            app.smoke_tick += 1;
            app.client.poll();
            const connection_state = app.client.connectionState();
            if (connection_state == .connected) app.flushPendingProject();
            if (app.client.connectionState() == .connected) {
                if (app.open_project_pending and app.last_project_opened.len != 0) {
                    app.client.sendOpenProject(app.last_project_opened);
                    app.open_project_pending = false;
                } else if (!app.sync_requested) {
                    app.sync_requested = true;
                    app.client.sendListProjects();
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
            }
            if (app.client.isIdle()) app.smoke_idle_ticks += 1 else app.smoke_idle_ticks = 0;
            if (app.workspace) |*workspace| {
                workspace.poll();
                if (workspace.inputStatus()) |input_message| app.setStatus(input_message);
            }
            if (app.smoke and app.smoke_tick == 8) {
                app.refreshWorkspace();
            }
            if (app.smoke and app.smoke_tick == 16 and
                app.client.connectionState() == .connected and !app.smoke_action_requested)
            {
                app.smoke_action_requested = true;
                app.createNode();
            }
            if (app.smoke and app.smoke_tick == 16 and !app.smoke_input_requested and
                envFlag("GRAPHCODE_SHELL_LARGE_PASTE"))
            {
                app.smoke_input_requested = true;
                if (app.workspace) |*workspace| {
                    const paste = app.allocator.alloc(u8, 1024 * 1024) catch {
                        app.setStatus("Large paste allocation failed");
                        return true;
                    };
                    @memset(paste, 'x');
                    workspace.send(paste);
                    app.allocator.free(paste);
                }
            }
            if (app.smoke and envFlag("GRAPHCODE_SHELL_WORKSPACE_ACTIONS") and
                !envFlag("GRAPHCODE_SHELL_EXPECT_TRANSPORT_ERROR"))
            {
                if (app.workspace) |*workspace| {
                    switch (app.smoke_workspace_stage) {
                        0 => if (app.smoke_tick >= 20) {
                            workspace.newTab() catch {
                                app.setStatus("Smoke workspace tab creation failed");
                                app.smoke_workspace_stage = 255;
                            };
                            if (app.smoke_workspace_stage != 255) app.smoke_workspace_stage = 1;
                        },
                        1 => if (app.smoke_tick >= 24) {
                            workspace.splitFocused(.vertical) catch {
                                app.setStatus("Smoke workspace split failed");
                                app.smoke_workspace_stage = 255;
                            };
                            if (app.smoke_workspace_stage != 255) app.smoke_workspace_stage = 2;
                        },
                        2 => if (app.smoke_tick >= 28) {
                            workspace.focusNextPane();
                            workspace.selectPreviousTab();
                            app.smoke_workspace_stage = 3;
                        },
                        3 => if (app.smoke_tick >= 32) {
                            workspace.selectNextTab();
                            workspace.closeFocusedPane() catch {
                                app.setStatus("Smoke workspace close failed");
                                app.smoke_workspace_stage = 255;
                            };
                            if (app.smoke_workspace_stage != 255) {
                                app.smoke_workspace_stage = 4;
                                app.smoke_workspace_actions_done = true;
                            }
                        },
                        else => {},
                    }
                }
            }
            if (app.smoke and app.smoke_tick >= 12 and
                ((app.stress and app.smoke_tick % 2 == 0) or
                    (!app.stress and app.smoke_tick == 12)))
            {
                if (app.workspace) |*workspace| {
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
            const ctrl = (@as(i32, c.GetKeyState(c.VK_CONTROL)) & 0x8000) != 0;
            const shift = (@as(i32, c.GetKeyState(c.VK_SHIFT)) & 0x8000) != 0;
            app.handleAction(InputRouter.keyAction(wparam, ctrl, shift));
            result.* = 0;
            return true;
        },
        c.WM_LBUTTONDOWN => {
            const x = mouseX(lparam);
            const y = mouseY(lparam);
            if (app.workspace) |*workspace| {
                if (workspace.selectTabAt(x, y)) {
                    result.* = 0;
                    return true;
                }
            }
            const graph_bounds = canvasBounds(hwnd);
            if (x < Tokens.sidebar_width) {
                result.* = 0;
                return true;
            }
            const hit = if (app.model.graph) |graph|
                GraphCanvas.hitTest(graph.nodes.items, x, y, &app.canvas, graph_bounds)
            else
                null;
            if (hit) |index| {
                app.model.selected_node = index;
                _ = c.InvalidateRect(hwnd, null, 0);
            } else {
                app.canvas.beginPan(x, y);
                _ = c.SetCapture(hwnd);
            }
            result.* = 0;
            return true;
        },
        c.WM_RBUTTONUP => {
            const x: i32 = @intCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)))));
            const y: i32 = @intCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16)));
            app.context_node = if (app.model.graph) |graph|
                GraphCanvas.hitTest(graph.nodes.items, x, y, &app.canvas, canvasBounds(hwnd))
            else
                null;
            if (app.context_node) |index| app.model.selected_node = index;
            showContextMenu(app, hwnd, x, y);
            result.* = 0;
            return true;
        },
        c.WM_COMMAND => {
            const command: usize = @as(u16, @truncate(wparam));
            switch (command) {
                7001 => app.handleAction(.create_node),
                7002 => app.handleAction(.edit_node),
                7003 => app.handleAction(.create_edge),
                7004 => app.handleAction(.open_node),
                7005 => app.handleAction(.stop_node),
                7006 => app.handleAction(.settings),
                else => {},
            }
            result.* = 0;
            return true;
        },
        c.WM_MOUSEMOVE => {
            if (app.canvas.dragging) {
                const x = mouseX(lparam);
                const y = mouseY(lparam);
                app.canvas.updatePan(x, y);
                _ = c.InvalidateRect(hwnd, null, 0);
            }
            result.* = 0;
            return true;
        },
        c.WM_LBUTTONUP => {
            const x = mouseX(lparam);
            const y = mouseY(lparam);
            if (app.canvas.dragging) {
                app.canvas.endPan();
                _ = c.ReleaseCapture();
            } else if (x < Tokens.sidebar_width) {
                app.handleSidebarClick(x, y);
            }
            result.* = 0;
            return true;
        },
        c.WM_MOUSEWHEEL => {
            const wheel = CanvasInput.decodeWheelMessage(lparam, wparam);
            const point = CanvasInput.screenToClient(hwnd, wheel.point) orelse {
                result.* = 0;
                return true;
            };
            if (point.x < Tokens.sidebar_width) {
                app.scrollSidebar(-@divTrunc(@as(i32, wheel.delta), 2));
            } else {
                app.canvas.zoomAt(point.x, point.y, wheel.delta);
            }
            _ = c.InvalidateRect(hwnd, null, 0);
            result.* = 0;
            return true;
        },
        c.WM_SETFOCUS => {
            if (app.workspace) |*workspace| workspace.focus(workspace.active_surface);
            result.* = 0;
            return true;
        },
        c.WM_CLOSE => {
            _ = c.DestroyWindow(hwnd);
            result.* = 0;
            return true;
        },
        c.WM_DESTROY => {
            app.running = false;
            _ = c.KillTimer(hwnd, MainWindow.timer_id);
            c.PostQuitMessage(0);
            result.* = 0;
            return true;
        },
        else => {},
    }

    return false;
}

fn canvasBounds(hwnd: c.HWND) c.RECT {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    return .{
        .left = Tokens.sidebar_width,
        .top = Tokens.header_height,
        .right = client.right,
        .bottom = @max(Tokens.header_height + 1, client.bottom - Tokens.workspace_height),
    };
}

fn mouseX(value: c.LPARAM) i32 {
    return @as(i32, @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(value)))))));
}

fn mouseY(value: c.LPARAM) i32 {
    return @as(i32, @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(value)) >> 16)))));
}

fn showContextMenu(app: *App, hwnd: c.HWND, x: i32, y: i32) void {
    const menu = c.CreatePopupMenu() orelse return;
    defer _ = c.DestroyMenu(menu);
    const node_selected = app.context_node != null;
    _ = c.AppendMenuW(menu, c.MF_STRING, 7001, std.unicode.utf8ToUtf16LeStringLiteral("Create node").ptr);
    if (node_selected) {
        _ = c.AppendMenuW(menu, c.MF_STRING, 7002, std.unicode.utf8ToUtf16LeStringLiteral("Edit node").ptr);
        _ = c.AppendMenuW(menu, c.MF_STRING, 7004, std.unicode.utf8ToUtf16LeStringLiteral("Open node").ptr);
        _ = c.AppendMenuW(menu, c.MF_STRING, 7005, std.unicode.utf8ToUtf16LeStringLiteral("Stop node").ptr);
    }
    _ = c.AppendMenuW(menu, c.MF_STRING, 7003, std.unicode.utf8ToUtf16LeStringLiteral("Create edge").ptr);
    _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
    _ = c.AppendMenuW(menu, c.MF_STRING, 7006, std.unicode.utf8ToUtf16LeStringLiteral("Settings").ptr);
    var point = c.POINT{ .x = x, .y = y };
    _ = c.ClientToScreen(hwnd, &point);
    _ = c.TrackPopupMenu(menu, c.TPM_LEFTALIGN | c.TPM_TOPALIGN, point.x, point.y, 0, hwnd, null);
}

fn smokeContractPassed(self: *const App) bool {
    if (self.client.connectionState() != .connected) return false;
    const value = self.model.graph orelse return false;
    if (value.nodes.items.len < 2) return false;
    const workspace = self.workspace orelse return false;
    var client: c.RECT = undefined;
    if (c.GetClientRect(self.window.hwnd, &client) == 0) return false;
    const layout_width = @max(0, client.right - Tokens.sidebar_width);
    const layout_height = Tokens.workspace_height;
    return (!envFlag("GRAPHCODE_SHELL_WORKSPACE_ACTIONS") or
        (self.smoke_workspace_actions_done and workspace.tabCount() >= 2 and workspace.topologyHealthy())) and
        workspace.layoutMatches(
            Tokens.sidebar_width,
            @max(0, client.bottom - Tokens.workspace_height),
            layout_width,
            layout_height,
        ) and
        workspace.hasSurface(0) and workspace.hasSurface(1) and
        workspace.hasAttach(0) and workspace.hasAttach(1);
}

fn envFlag(name: []const u8) bool {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return false;
    defer std.heap.page_allocator.free(value);
    return std.mem.eql(u8, value, "1");
}

fn setEnvironmentVariable(allocator: std.mem.Allocator, name: []const u8, value: []const u8) bool {
    const raw_name = std.unicode.utf8ToUtf16LeAlloc(allocator, name) catch return false;
    defer allocator.free(raw_name);
    const wide_name = allocator.alloc(u16, raw_name.len + 1) catch return false;
    defer allocator.free(wide_name);
    @memcpy(wide_name[0..raw_name.len], raw_name);
    wide_name[raw_name.len] = 0;
    const raw_value = std.unicode.utf8ToUtf16LeAlloc(allocator, value) catch return false;
    defer allocator.free(raw_value);
    const wide_value = allocator.alloc(u16, raw_value.len + 1) catch return false;
    defer allocator.free(wide_value);
    @memcpy(wide_value[0..raw_value.len], raw_value);
    wide_value[raw_value.len] = 0;
    return c.SetEnvironmentVariableW(wide_name.ptr, if (value.len == 0) null else wide_value.ptr) != 0;
}

fn settingsErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidDaemonPipe => "Invalid daemon pipe; settings unchanged",
        error.SupportDirectoryMissing => "Support directory is missing; settings unchanged",
        error.SupportSecretMissing => "Support directory has no rendezvous secret; settings unchanged",
        error.SupportSecretInvalid => "Support directory has an invalid rendezvous secret; settings unchanged",
        else => "Unable to validate daemon settings; settings unchanged",
    };
}
