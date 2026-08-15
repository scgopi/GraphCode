const std = @import("std");
const DaemonClient = @import("DaemonClient.zig").DaemonClient;
const GraphCanvas = @import("GraphCanvas.zig");
const Sidebar = @import("Sidebar.zig");
const GraphModel = @import("GraphModel.zig");
const InputRouter = @import("InputRouter.zig");
const MainWindow = @import("MainWindow.zig");
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
    selected_worktree_path: []u8 = &.{},
    sidebar_scroll: i32 = 0,
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
    smoke_idle_ticks: usize = 0,

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
            WorktreeStatus.deinitInspection(self.allocator, inspection);
        }
        if (self.selected_worktree_path.len != 0) self.allocator.free(self.selected_worktree_path);
        if (self.instance_mutex != null) _ = c.CloseHandle(self.instance_mutex);
        if (self.last_project_opened.len != 0) self.allocator.free(self.last_project_opened);
        if (self.pending_project_path.len != 0) self.allocator.free(self.pending_project_path);
        if (self.status_override.len != 0) self.allocator.free(self.status_override);
        self.allocator.destroy(self);
    }

    pub fn run(self: *App) !void {
        try self.window.create(self, &onWindowMessage, title.ptr);
        self.workspace = try TerminalWorkspace.Workspace.init(self.window.hwnd, self.allocator);
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
                self.clampSidebarScroll();
                if (self.model.graph == null and self.model.recent_projects.items.len != 0) {
                    self.queueProject(self.model.recent_projects.items[0].path);
                }
            },
            .graph_changed => {
                    self.clampSidebarScroll();
                    if (self.worktree_inspection) |inspection| {
                        if (self.model.graph) |graph| {
                            if (!std.mem.eql(u8, inspection.project_path, graph.project.path)) {
                                WorktreeStatus.deinitInspection(self.allocator, &self.worktree_inspection.?);
                                self.worktree_inspection = null;
                                if (self.selected_worktree_path.len != 0) {
                                    self.allocator.free(self.selected_worktree_path);
                                    self.selected_worktree_path = &.{};
                                }
                            }
                        }
                    }
                    if (self.model.graph) |graph| self.queueProject(graph.project.path);
                self.clampSidebarScroll();
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
        self.client.sendCreateNode(path, "Windows shell node");
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
        const path = self.currentProject() orelse {
            self.setStatus("No project selected for worktree reclaim");
            return;
        };
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
                error.UnsafeSelection => "Reclaim refused: selected worktree is no longer safe",
                error.EmptySelection => "Select a worktree before reclaiming",
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
        const top = Sidebar.worktreeRowTop(self.model.recent_projects.items.len, index) - self.sidebar_scroll;
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
            .create_node => self.createNode(),
            .open_node => self.openSelectedNode(),
            .stop_node => self.stopSelectedNode(),
            .send_node => self.sendSelectedNode(),
            .cycle_attention => {
                self.model.selectNextAttention();
                _ = c.InvalidateRect(self.window.hwnd, null, 0);
            },
            .inspect_worktrees => self.inspectWorktrees(),
            .reclaim_worktrees => self.reclaimWorktrees(),
            .worktree_next => self.moveWorktreeSelection(1),
            .worktree_previous => self.moveWorktreeSelection(-1),
            .focus_terminal_a => if (self.workspace) |*workspace| workspace.focus(0),
            .focus_terminal_b => if (self.workspace) |*workspace| workspace.focus(1),
            .select_next => {
                self.model.selectNext();
                _ = c.InvalidateRect(self.window.hwnd, null, 0);
            },
            .none => {},
            else => {},
        }
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
            const inspection = if (app.worktree_inspection) |*value| value else null;
            GraphCanvas.paint(hwnd, hdc, &app.model, inspection, app.selected_worktree_path, app.sidebar_scroll, app.status(), app.allocator, &app.canvas);
            _ = c.EndPaint(hwnd, &paint);
            result.* = 0;
            return true;
        },
        c.WM_SIZE => {
            app.layoutWorkspace();
            app.clampSidebarScroll();
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
            const x: i32 = @intCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)))));
            const y: i32 = @intCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16)));
            if (app.worktree_inspection) |inspection| {
                var client: c.RECT = undefined;
                _ = c.GetClientRect(hwnd, &client);
                if (Sidebar.hitTestWorktree(x, y, app.model.recent_projects.items.len, inspection.entries.items.len,
                    app.sidebar_scroll, client.bottom - Tokens.workspace_height)) |index| {
                    _ = app.selectWorktreeRow(inspection.entries.items[index].path);
                    app.ensureWorktreeVisible(index);
                    _ = c.InvalidateRect(hwnd, null, 0);
                }
            }
            result.* = 0;
            return true;
        },
        c.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(wparam)) >> 16)));
            app.sidebar_scroll = Sidebar.clampScroll(
                app.sidebar_scroll - @divTrunc(@as(i32, delta), 4),
                Sidebar.maxScroll(&app.model,
                    if (app.worktree_inspection) |*value| value else null,
                    blk: {
                        var client: c.RECT = undefined;
                        _ = c.GetClientRect(hwnd, &client);
                        break :blk client.bottom - Tokens.workspace_height;
                    }),
            );
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

fn smokeContractPassed(self: *const App) bool {
    if (self.client.connectionState() != .connected) return false;
    const value = self.model.graph orelse return false;
    if (value.nodes.items.len < 2) return false;
    const workspace = self.workspace orelse return false;
    var client: c.RECT = undefined;
    if (c.GetClientRect(self.window.hwnd, &client) == 0) return false;
    const layout_width = @max(0, client.right - Tokens.sidebar_width);
    const layout_height = Tokens.workspace_height;
    return workspace.layoutMatches(
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
