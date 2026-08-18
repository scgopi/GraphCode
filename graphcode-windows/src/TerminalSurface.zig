const std = @import("std");
const c = @import("Win32.zig").c;
const WorkspaceLayout = @import("WorkspaceLayout.zig");
const Tokens = @import("DesignTokens.zig");

const columns: usize = 120;
const rows: usize = 40;
const cell_count: usize = columns * rows;

const ParserState = enum { normal, escape, csi, osc };
const input_queue_capacity: usize = 64;
const input_queue_max_bytes: usize = 1024 * 1024;
const input_write_timeout_ms: c.DWORD = 50;
const max_surfaces: usize = 32;

pub const ChromeAction = enum { new_tab, split_right, split_down };
pub const LoopBarAction = enum { stop, show_graph };

pub fn loopBarActionAt(left: i32, top: i32, right: i32, x: i32, y: i32, resolved: bool) ?LoopBarAction {
    if (y < top or y >= top + Tokens.loop_bar_height) return null;
    if (x >= right - 104 and x < right - 12) return .show_graph;
    if (!resolved and x >= right - 196 and x < right - 112) return .stop;
    _ = left;
    return null;
}

fn chromeActionForBounds(origin_x: i32, origin_y: i32, width: i32, x: i32, y: i32) ?ChromeAction {
    if (y < origin_y + 3 or y >= origin_y + Tokens.tab_bar_height - 3) return null;
    const left = @max(origin_x, origin_x + width - 220);
    if (x < left or x >= origin_x + width - 4) return null;
    return switch (@divTrunc(x - left, 72)) {
        0 => .new_tab,
        1 => .split_right,
        2 => .split_down,
        else => null,
    };
}

pub const WorkspaceKeyCallback = *const fn (
    context: ?*anyopaque,
    key: usize,
    ctrl: bool,
    shift: bool,
) callconv(.c) void;

pub const InputQueue = struct {
    pub const max_bytes = input_queue_max_bytes;

    pub const Item = struct {
        surface: usize,
        bytes: []u8,
    };
    allocator: std.mem.Allocator,
    items: [input_queue_capacity]Item = undefined,
    head: usize = 0,
    count: usize = 0,
    bytes: usize = 0,

    pub fn enqueue(self: *InputQueue, surface: usize, bytes: []u8) !void {
        if (bytes.len > input_queue_max_bytes) return error.InputTooLarge;
        if (self.count == input_queue_capacity or self.bytes + bytes.len > input_queue_max_bytes) {
            return error.InputQueueFull;
        }
        const index = (self.head + self.count) % input_queue_capacity;
        self.items[index] = .{ .surface = surface, .bytes = bytes };
        self.count += 1;
        self.bytes += bytes.len;
    }

    pub fn dequeue(self: *InputQueue) ?Item {
        if (self.count == 0) return null;
        const item = self.items[self.head];
        self.head = (self.head + 1) % input_queue_capacity;
        self.count -= 1;
        self.bytes -= item.bytes.len;
        return item;
    }

    pub fn clear(self: *InputQueue) void {
        while (self.dequeue()) |item| self.allocator.free(item.bytes);
    }

    pub fn removeSurface(self: *InputQueue, surface: usize) void {
        var kept: [input_queue_capacity]Item = undefined;
        var kept_count: usize = 0;
        while (self.dequeue()) |item| {
            if (item.surface == surface) {
                self.allocator.free(item.bytes);
            } else {
                kept[kept_count] = item;
                kept_count += 1;
            }
        }
        for (kept[0..kept_count]) |item| {
            self.items[self.count] = item;
            self.count += 1;
            self.bytes += item.bytes.len;
        }
        self.head = 0;
    }
};

pub const Surface = struct {
    surface: ?*c.winghostty_surface = null,
    attach: ?std.process.Child = null,
    session_name: []u8 = &.{},
    project_path: []u8 = &.{},
    destroying: bool = false,
    destroyed: bool = false,
    input_bytes: usize = 0,
    output_events: usize = 0,
    terminal_buffer: [16 * 1024]u8 = undefined,
    terminal_buffer_len: usize = 0,
    cells: []c.winghostty_terminal_cell = &.{},
    terminal_x: usize = 0,
    terminal_y: usize = 0,
    parser: ParserState = .normal,
    csi_value: usize = 0,
    csi_have_value: bool = false,
};

pub fn surfaceIdentityMatches(surface: *const Surface, project_path: []const u8, session: []const u8) bool {
    return std.mem.eql(u8, surface.project_path, project_path) and
        std.mem.eql(u8, surface.session_name, session);
}

pub const Workspace = struct {
    parent: c.HWND,
    host: ?*c.winghostty_host = null,
    surfaces: [max_surfaces]Surface = [_]Surface{.{}} ** max_surfaces,
    active_surface: usize = 0,
    allocator: std.mem.Allocator,
    zmx_path: []u8,
    cwd: []u8,
    recreate_sessions: [max_surfaces][]u8 = [_][]u8{&.{}} ** max_surfaces,
    recreate_due_ms: [max_surfaces]i64 = [_]i64{0} ** max_surfaces,
    recreate_delay_ms: [max_surfaces]i64 = [_]i64{100} ** max_surfaces,
    restore_errors: [max_surfaces][]u8 = [_][]u8{&.{}} ** max_surfaces,
    fatal_error: bool = false,
    render_error: c.winghostty_result = c.WINGHOSTTY_OK,
    input_mutex: std.Thread.Mutex = .{},
    input_condition: std.Thread.Condition = .{},
    input_worker: ?std.Thread = null,
    input_stop: bool = false,
    input_busy: bool = false,
    input_worker_surface: ?usize = null,
    input_worker_handle: c.HANDLE = null,
    input_cancel_requested: bool = false,
    input_queue: InputQueue,
    input_error_message: []const u8 = "",
    layout: WorkspaceLayout.Layout,
    layout_path: []u8,
    project_key: []u8,
    key_callback: ?WorkspaceKeyCallback = null,
    key_callback_context: ?*anyopaque = null,
    layout_origin_x: i32 = 0,
    layout_origin_y: i32 = 0,
    layout_width: i32 = 960,
    layout_height: i32 = 250,
    project_path: []u8 = &.{},
    syncing_topology: bool = false,
    syncing_focus: bool = false,
    persisting_layout: bool = false,

    pub fn init(parent: c.HWND, allocator_: std.mem.Allocator) !*Workspace {
        const workspace = try allocator_.create(Workspace);
        workspace.* = .{
            .parent = parent,
            .allocator = allocator_,
            .zmx_path = try allocator_.dupe(u8, std.process.getEnvVarOwned(allocator_, "GRAPHCODE_ZMX") catch "zmx.exe"),
            .cwd = try allocator_.dupe(u8, std.process.getEnvVarOwned(allocator_, "GRAPHCODE_GATE_CWD") catch "."),
            .input_queue = .{ .allocator = allocator_ },
            .layout = try WorkspaceLayout.Layout.init(
                allocator_,
                std.process.getEnvVarOwned(allocator_, "GRAPHCODE_WORKSPACE_PROJECT")
                    catch "global",
            ),
            .layout_path = &.{},
            .project_key = try allocator_.dupe(
                u8,
                std.process.getEnvVarOwned(allocator_, "GRAPHCODE_WORKSPACE_PROJECT")
                    catch "global",
            ),
        };
        for (&workspace.surfaces) |*surface| {
            surface.cells = try allocator_.alloc(c.winghostty_terminal_cell, cell_count);
            for (surface.cells) |*cell| {
                cell.* = .{ .codepoint = 0, .foreground = 0xE6E6E6, .background = 0, .flags = 0 };
            }
        }
        errdefer {
            for (&workspace.surfaces) |*surface| {
                if (surface.cells.len != 0) allocator_.free(surface.cells);
            }
            allocator_.free(workspace.zmx_path);
            allocator_.free(workspace.cwd);
            workspace.layout.deinit();
            allocator_.free(workspace.layout_path);
            allocator_.free(workspace.project_key);
            allocator_.destroy(workspace);
        }
        workspace.layout_path = try workspace.layoutPathForProject(workspace.project_key);
        if (WorkspaceLayout.Layout.load(allocator_, workspace.layout_path, workspace.project_key)) |restored| {
            workspace.layout.deinit();
            workspace.layout = restored;
        } else |_| {}
        if (c.winghostty_host_initialize(&workspace.host) != c.WINGHOSTTY_OK) {
            return error.WinghosttyHostInitializeFailed;
        }
        workspace.restorePersistedSurfaces();
        return workspace;
    }

    pub fn startInputWorker(self: *Workspace) !void {
        self.input_worker = try std.Thread.spawn(.{}, inputWorkerMain, .{self});
    }

    pub fn deinit(self: *Workspace) void {
        self.stopInputWorker();
        for (self.surfaces, 0..) |_, index| self.destroySurface(index);
        for (&self.recreate_sessions) |*session| {
            if (session.*.len != 0) self.allocator.free(session.*);
            session.* = &.{};
        }
        for (&self.restore_errors) |*message| {
            if (message.*.len != 0) self.allocator.free(message.*);
            message.* = &.{};
        }
        for (&self.surfaces) |*surface| {
            if (surface.cells.len != 0) {
                self.allocator.free(surface.cells);
                surface.cells = &.{};
            }
        }
        if (self.project_path.len != 0) self.allocator.free(self.project_path);
        if (self.host) |host| {
            _ = c.winghostty_host_deinitialize(host);
            self.host = null;
        }

        self.allocator.free(self.zmx_path);
        self.allocator.free(self.cwd);
        self.layout.deinit();
        self.allocator.free(self.layout_path);
        self.allocator.free(self.project_key);
    }

    pub fn setKeyCallback(
        self: *Workspace,
        context: ?*anyopaque,
        callback: ?WorkspaceKeyCallback,
    ) void {
        self.key_callback_context = context;
        self.key_callback = callback;
    }

    pub fn setProject(self: *Workspace, project: []const u8) !void {
        if (project.len == 0 or std.mem.eql(u8, self.project_key, project)) return;
        const new_project_key = try self.allocator.dupe(u8, project);
        errdefer self.allocator.free(new_project_key);
        const new_layout_path = try self.layoutPathForProject(project);
        errdefer self.allocator.free(new_layout_path);
        var new_layout = try WorkspaceLayout.Layout.init(self.allocator, project);
        errdefer new_layout.deinit();
        if (WorkspaceLayout.Layout.load(self.allocator, new_layout_path, project)) |restored| {
            new_layout.deinit();
            new_layout = restored;
        } else |_| {}
        var old_layout = self.layout;
        const old_project_key = self.project_key;
        const old_layout_path = self.layout_path;
        self.layout = new_layout;
        self.project_key = new_project_key;
        self.layout_path = new_layout_path;
        for (self.surfaces, 0..) |_, index| self.destroySurface(index);
        self.clearAllRecreateState();
        old_layout.deinit();
        self.allocator.free(old_project_key);
        self.allocator.free(old_layout_path);
        for (&self.recreate_due_ms) |*due| due.* = 0;
        for (&self.recreate_delay_ms) |*delay| delay.* = 100;
        self.restorePersistedSurfaces();
    }

    pub fn rebindProject(self: *Workspace, project_path: []const u8) !bool {
        if (project_path.len == 0) return false;
        const key_changed = !std.mem.eql(u8, self.project_key, project_path);
        const path_changed = !std.mem.eql(u8, self.project_path, project_path);
        if (!key_changed and !path_changed) return false;

        const new_project_key = try self.allocator.dupe(u8, project_path);
        errdefer self.allocator.free(new_project_key);
        const new_project_path = try self.allocator.dupe(u8, project_path);
        errdefer self.allocator.free(new_project_path);
        const new_layout_path = try self.layoutPathForProject(project_path);
        errdefer self.allocator.free(new_layout_path);
        var new_layout: WorkspaceLayout.Layout = undefined;
        if (key_changed) {
            new_layout = try WorkspaceLayout.Layout.init(self.allocator, project_path);
            errdefer new_layout.deinit();
            if (WorkspaceLayout.Layout.load(self.allocator, new_layout_path, project_path)) |restored| {
                new_layout.deinit();
                new_layout = restored;
            } else |_| {}
        } else {
            new_layout = self.layout;
        }

        const old_key = self.project_key;
        const old_path = self.project_path;
        const old_layout_path = self.layout_path;
        var old_layout = self.layout;
        self.project_key = new_project_key;
        self.project_path = new_project_path;
        self.layout_path = new_layout_path;
        self.layout = new_layout;
        for (self.surfaces, 0..) |_, index| self.destroySurface(index);
        self.clearAllRecreateState();
        for (&self.recreate_due_ms) |*due| due.* = 0;
        for (&self.recreate_delay_ms) |*delay| delay.* = 100;
        if (key_changed) old_layout.deinit();
        self.allocator.free(old_key);
        self.allocator.free(old_path);
        self.allocator.free(old_layout_path);
        self.restorePersistedSurfaces();
        return true;
    }

    pub fn projectPath(self: *const Workspace) []const u8 {
        return self.project_path;
    }

    fn layoutPathForProject(self: *Workspace, project: []const u8) ![]u8 {
        const configured = std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_WORKSPACE_LAYOUT") catch
            try self.allocator.dupe(u8, "graphcode-workspace.json");
        defer self.allocator.free(configured);
        const suffix = projectLayoutSuffix(project);
        return std.fmt.allocPrint(self.allocator, "{s}.{s}.json", .{
            configured[0 .. if (std.mem.endsWith(u8, configured, ".json")) configured.len - 5 else configured.len],
            suffix,
        });

    }

    pub fn openNode(self: *Workspace, index: usize, node_id: []const u8) !void {
        if (index >= self.surfaces.len) return error.InvalidSurface;
        if (self.surfaces[index].surface != null or self.surfaces[index].attach != null) {
            const old_id = try self.allocator.dupe(u8, self.surfaces[index].session_name);
            defer self.allocator.free(old_id);
            const replacement_index = try self.createAttachedSurface(node_id);
            errdefer self.destroySurface(replacement_index);
            self.layout.replacePaneID(old_id, node_id) catch |err| {
                self.destroySurface(replacement_index);
                return err;
            };
            self.persistLayout() catch |err| {
                self.layout.replacePaneID(node_id, old_id) catch {};
                self.destroySurface(replacement_index);
                return err;
            };
            self.destroySurface(index);
            self.surfaces[index] = self.surfaces[replacement_index];
            self.surfaces[replacement_index] = .{};
            self.syncTopology();
            self.clearRecreateSession(index);
            return;
        }
        self.destroySurface(index);
        self.resetSessionState(index);
        self.recreate_due_ms[index] = 0;
        const session = try self.allocator.dupe(u8, node_id);
        errdefer self.allocator.free(session);
        try self.startSession(index, session);
        if (self.layout.tabs.items.len == 0) {
            try self.layout.addTab(node_id, true);
        } else if (index > 0 and self.layout.tabs.items.len == 1) {
            try self.layout.addTab(node_id, false);
        }
        try self.persistLayout();
        var options = self.surfaceOptions(index);
        const result = c.winghostty_host_create_surface_v2(
            self.host,
            self.parent,
            &options,
            &self.surfaces[index].surface,
        );
        if (result != c.WINGHOSTTY_OK or self.surfaces[index].surface == null) {
            self.waitAttach(index);
            return error.WinghosttySurfaceCreateFailed;
        }

        self.surfaces[index].session_name = session;
        self.surfaces[index].project_path = try self.allocator.dupe(u8, self.project_path);
        self.surfaces[index].destroyed = false;
        self.surfaces[index].destroying = false;
        clearCells(&self.surfaces[index]);
        self.resize(
            self.layout_origin_x,
            self.layout_origin_y,
            self.layout_width,
            self.layout_height,
        );
        self.clearRecreateSession(index);
    }

    pub fn newTab(self: *Workspace) !void {
        const surface_id = try self.layout.newSurfaceID();
        defer self.allocator.free(surface_id);
        const previous_selected = self.layout.selected_tab;
        const previous_next_id = self.layout.next_tab_id;
        const index = try self.createAttachedSurface(surface_id);
        errdefer self.destroySurface(index);
        self.layout.addTab(surface_id, false) catch |err| {
            self.destroySurface(index);
            return err;
        };
        self.persistLayout() catch |err| {
            _ = self.layout.removePane(surface_id);
            self.layout.selected_tab = previous_selected;
            self.layout.next_tab_id = previous_next_id;
            self.destroySurface(index);
            return err;
        };
        self.syncTopology();
    }

    fn createAttachedSurface(self: *Workspace, session: []const u8) !usize {
        for (self.surfaces, 0..) |slot, index| {
            if (slot.surface != null or slot.attach != null) continue;
            const owned_session = try self.allocator.dupe(u8, session);
            errdefer self.allocator.free(owned_session);
            try self.startSession(index, owned_session);
            var options = self.surfaceOptions(index);
            const result = c.winghostty_host_create_surface_v2(
                self.host,
                self.parent,
                &options,
                &self.surfaces[index].surface,
            );
            if (result != c.WINGHOSTTY_OK or self.surfaces[index].surface == null) {
                self.waitAttach(index);
                return error.WinghosttySurfaceCreateFailed;
            }

            self.surfaces[index].session_name = owned_session;
            self.surfaces[index].project_path = try self.allocator.dupe(u8, self.project_path);
            self.surfaces[index].destroyed = false;
            self.surfaces[index].destroying = false;
            clearCells(&self.surfaces[index]);
            self.resize(
                self.layout_origin_x,
                self.layout_origin_y,
                self.layout_width,
                self.layout_height,
            );
            return index;
        }
        return error.SurfaceCapacityExceeded;
    }

    fn restorePersistedSurfaces(self: *Workspace) void {
        var ids: [max_surfaces][]u8 = undefined;
        var count: usize = 0;
        for (self.layout.tabs.items) |tab| for (tab.panes.items) |pane| {
            if (count == ids.len) break;
            ids[count] = self.allocator.dupe(u8, pane.id) catch continue;
            count += 1;
        };
        defer for (ids[0..count]) |id| self.allocator.free(id);
        for (ids[0..count]) |id| {
            if (self.createAttachedSurface(id)) |index| {
                self.clearRestoreError(index);
            } else |err| {
                self.queueRestoreRetry(id, err);
            }
        }
        self.syncTopology();
    }

    fn queueRestoreRetry(self: *Workspace, session: []const u8, err: anyerror) void {
        for (self.surfaces, 0..) |slot, index| {
            if (slot.surface == null and slot.attach == null and self.recreate_sessions[index].len == 0) {
                self.recreate_sessions[index] = self.allocator.dupe(u8, session) catch &.{};
                self.recreate_due_ms[index] = nowMilliseconds() + self.recreate_delay_ms[index];
                const message = std.fmt.allocPrint(self.allocator, "workspace restore pending: {s}", .{@errorName(err)}) catch return;
                self.restore_errors[index] = message;
                return;
            }
        }
    }

    fn clearRestoreError(self: *Workspace, index: usize) void {
        if (self.restore_errors[index].len != 0) self.allocator.free(self.restore_errors[index]);
        self.restore_errors[index] = &.{};
    }

    fn clearRecreateSession(self: *Workspace, index: usize) void {
        if (self.recreate_sessions[index].len != 0) self.allocator.free(self.recreate_sessions[index]);
        self.recreate_sessions[index] = &.{};
    }

    fn clearAllRecreateState(self: *Workspace) void {
        for (&self.recreate_sessions, 0..) |*session, index| {
            if (session.*.len != 0) self.allocator.free(session.*);
            session.* = &.{};
            self.recreate_due_ms[index] = 0;
            self.recreate_delay_ms[index] = 100;
        }
        for (&self.restore_errors) |*message| {
            if (message.*.len != 0) self.allocator.free(message.*);
            message.* = &.{};
        }
    }

    fn cancelRecreateForID(self: *Workspace, id: []const u8) void {
        for (self.recreate_sessions, 0..) |session, index| {
            if (std.mem.eql(u8, session, id)) {
                self.clearRecreateSession(index);
                self.clearRestoreError(index);
            }
        }
    }

    fn closeSurfaceForID(self: *Workspace, id: []const u8) bool {
        for (self.surfaces, 0..) |slot, index| {
            if (std.mem.eql(u8, slot.session_name, id)) {
                self.destroySurface(index);
                return true;
            }
        }
        return false;
    }

    pub fn splitFocused(self: *Workspace, direction: WorkspaceLayout.Direction) !void {
        const surface_id = try self.layout.newSurfaceID();
        defer self.allocator.free(surface_id);
        const tab = self.layout.selected() orelse return error.NoTabs;
        const previous_focus = tab.focused_pane;
        const previous_direction = tab.split_direction;
        const index = try self.createAttachedSurface(surface_id);
        errdefer self.destroySurface(index);
        self.layout.splitFocused(direction, surface_id) catch |err| {
            self.destroySurface(index);
            return err;
        };
        self.persistLayout() catch |err| {
            _ = self.layout.removePane(surface_id);
            if (self.layout.selected()) |current| {
                current.focused_pane = previous_focus;
                current.split_direction = previous_direction;
            }
            self.destroySurface(index);
            return err;
        };
        self.syncTopology();
    }

    pub fn selectTab(self: *Workspace, index: usize) !void {
        try self.layout.selectTab(index);
        try self.persistLayout();
        self.syncTopology();
    }

    pub fn selectTabAt(self: *Workspace, x: i32, y: i32) bool {
        if (y < self.layout_origin_y or y >= self.layout_origin_y + Tokens.tab_bar_height) return false;
        if (x < self.layout_origin_x or x >= self.chromeControlsLeft()) return false;
        const index = @as(usize, @intCast(@divTrunc(x - self.layout_origin_x, 120)));
        if (index >= self.layout.tabs.items.len) return false;
        self.selectTab(index) catch return false;
        return true;
    }

    pub fn selectNextTab(self: *Workspace) void {
        self.layout.selectRelativeTab(1);
        self.persistLayout() catch {};
        self.syncTopology();
    }

    pub fn selectPreviousTab(self: *Workspace) void {
        self.layout.selectRelativeTab(-1);
        self.persistLayout() catch {};
        self.syncTopology();
    }

    pub fn focusNextPane(self: *Workspace) void {
        self.layout.focusPane(1) catch {};
        self.syncFocusedPane();
    }

    pub fn focusPreviousPane(self: *Workspace) void {
        self.layout.focusPane(-1) catch {};
        self.syncFocusedPane();
    }

    pub fn closeFocusedPane(self: *Workspace) !void {
        var record = try self.layout.closeFocusedPane();
        defer record.deinit(self.allocator);
        self.persistLayout() catch |err| {
            self.layout.restoreClosedPane(&record) catch {};
            return err;
        };
        self.cancelRecreateForID(record.id);
        _ = self.closeSurfaceForID(record.id);
        self.syncTopology();
    }

    pub fn persistLayout(self: *Workspace) !void {
        if (self.persisting_layout) return;
        self.persisting_layout = true;
        defer self.persisting_layout = false;
        try self.layout.save(self.layout_path);
    }

    pub fn recreate(self: *Workspace, index: usize) !void {
        const session = if (self.surfaces[index].session_name.len == 0) return else try self.allocator.dupe(u8, self.surfaces[index].session_name);
        defer self.allocator.free(session);
        self.destroySurface(index);
        try self.openNode(index, session);
    }

    pub fn resize(self: *Workspace, origin_x: i32, origin_y: i32, width: i32, height: i32) void {
        self.layout_origin_x = origin_x;
        self.layout_origin_y = origin_y;
        self.layout_width = width;
        self.layout_height = height;
        self.syncTopology();
    }

    pub fn chromeActionAt(self: *const Workspace, x: i32, y: i32) ?ChromeAction {
        return chromeActionForBounds(
            self.layout_origin_x,
            self.layout_origin_y,
            self.layout_width,
            x,
            y,
        );
    }

    fn chromeControlsLeft(self: *const Workspace) i32 {
        return @max(self.layout_origin_x, self.layout_origin_x + self.layout_width - 220);
    }

    /// Draws only product chrome. Winghostty remains responsible for terminal pixels;
    /// keeping this separate prevents renderer/provider lifetimes from leaking into the
    /// tab and pane model.
    pub fn paintChrome(self: *const Workspace, hdc: c.HDC) void {
        const tab_bar = c.RECT{
            .left = self.layout_origin_x,
            .top = self.layout_origin_y,
            .right = self.layout_origin_x + self.layout_width,
            .bottom = self.layout_origin_y + Tokens.tab_bar_height,
        };

        fillRect(hdc, tab_bar, Tokens.workspace_rail);
        const controls_left = self.chromeControlsLeft();
        for (self.layout.tabs.items, 0..) |tab, index| {
            const left = self.layout_origin_x + @as(i32, @intCast(index)) * 120;
            if (left + 112 > controls_left) break;
            const bounds = c.RECT{
                .left = left,
                .top = tab_bar.top + 4,
                .right = left + 112,
                .bottom = tab_bar.bottom - 4,
            };
            fillRect(hdc, bounds, if (index == self.layout.selected_tab) 0x00345D8C else 0x00262626);
            drawUtf8(hdc, tabLabel(tab, index), bounds.left + 8, bounds.top + 5, 11, 0x00E6E6E6);
        }

        const labels = [_][]const u8{ "New Tab", "Split R", "Split D" };
        for (labels, 0..) |label, index| {
            const left = controls_left + @as(i32, @intCast(index)) * 72;
            const bounds = c.RECT{
                .left = left,
                .top = tab_bar.top + 3,
                .right = left + 68,
                .bottom = tab_bar.bottom - 3,
            };
            fillRect(hdc, bounds, 0x00262626);
            drawUtf8(hdc, label, bounds.left + 7, bounds.top + 5, 10, 0x00D8D8D8);
        }
        for (self.surfaces, 0..) |slot, index| {
            if (slot.surface == null) continue;
            const left = self.layout_origin_x + if (index == 0) 0 else @divTrunc(self.layout_width, 2);
            const right = if (index == 0 and self.surfaces[1].surface != null)
                self.layout_origin_x + @divTrunc(self.layout_width, 2)
            else
                self.layout_origin_x + self.layout_width;
            const pane_top = self.layout_origin_y + Tokens.tab_bar_height;
            fillRect(hdc, .{ .left = left, .top = pane_top, .right = right, .bottom = pane_top + Tokens.pane_header_height }, 0x00212124);
            const launches_agent = if (self.layout.selectedConst()) |tab|
                if (self.paneIndex(slot.session_name)) |pane_index|
                    pane_index < tab.panes.items.len and tab.panes.items[pane_index].launches_agent
                else
                    false
            else
                false;
            drawUtf8(
                hdc,
                if (launches_agent) "agent" else "shell",
                left + 8,
                pane_top + 5,
                10,
                if (index == self.active_surface) 0x00E6E6E6 else 0x008A8A8A,
            );
            drawUtf8(hdc, "zmx session", left + 54, pane_top + 5, 9, 0x007A7A7A);
            if (index == self.active_surface) {
                fillRect(hdc, .{ .left = left, .top = pane_top + Tokens.pane_header_height - 2, .right = right, .bottom = pane_top + Tokens.pane_header_height }, Tokens.pane_focus_tint);
            }
        }
    }

    pub fn paintLoopBar(
        hdc: c.HDC,
        allocator: std.mem.Allocator,
        left: i32,
        right: i32,
        project_name: []const u8,
        title: []const u8,
        loop_type: []const u8,
        state: []const u8,
        activity: []const u8,
        resolved: bool,
    ) void {
        const top = Tokens.header_height;
        fillRect(hdc, .{ .left = left, .top = top, .right = right, .bottom = top + Tokens.loop_bar_height }, 0x00222226);
        fillRect(hdc, .{
            .left = left + 14,
            .top = top + 11,
            .right = left + 18,
            .bottom = top + 35,
        }, loopTypeAccent(loop_type));
        drawUtf8(hdc, title, left + 27, top + 7, 13, 0x00F2F2F7);
        drawUtf8(hdc, state, left + 190, top + 8, 10, stateAccent(state));
        const live_line = if (activity.len != 0) activity else project_name;
        drawUtf8(hdc, live_line, left + 27, top + 25, 10, 0x008E8E93);
        if (!resolved) {
            fillRect(hdc, .{ .left = right - 196, .top = top + 10, .right = right - 112, .bottom = top + 36 }, 0x00303035);
            drawUtf8(hdc, "Stop loop", right - 184, top + 17, 10, 0x00D8D8DC);
        }
        drawUtf8(hdc, "Show in graph", right - 100, top + 17, 10, 0x008E8E93);
        fillRect(hdc, .{ .left = left, .top = top + Tokens.loop_bar_height - 1, .right = right, .bottom = top + Tokens.loop_bar_height }, 0x00131315);
        _ = allocator;
    }

    pub fn poll(self: *Workspace) void {
        for (self.surfaces, 0..) |_, index| self.readAttachOutput(index);
        self.pollRecreates();
    }

    pub fn focus(self: *Workspace, index: usize) void {
        if (index >= self.surfaces.len) return;
        if (self.syncing_focus or self.syncing_topology) return;
        self.syncing_focus = true;
        defer self.syncing_focus = false;
        self.active_surface = index;
        for (&self.surfaces, 0..) |*slot, other_index| {
            if (slot.surface) |surface| {
                _ = c.winghostty_surface_set_focus(surface, if (index == other_index) 1 else 0);
            }

        }
        self.persistFocusedSurface(index);
    }

    fn persistFocusedSurface(self: *Workspace, index: usize) void {
        if (index >= self.surfaces.len) return;
        const id = self.surfaces[index].session_name;
        const tab = self.layout.selected() orelse return;
        for (tab.panes.items, 0..) |pane, pane_index| {
            if (std.mem.eql(u8, pane.id, id)) {
                tab.focused_pane = pane_index;
                self.active_surface = index;
                if (!self.syncing_topology) self.persistLayout() catch {};
                return;
            }
        }
    }

    fn syncTopology(self: *Workspace) void {
        if (self.syncing_topology) return;
        self.syncing_topology = true;
        defer self.syncing_topology = false;
        const selected = self.layout.selected() orelse return;
        const pane_count = selected.panes.items.len;
        const available_height = @max(1, self.layout_height - Tokens.tab_bar_height - Tokens.pane_header_height);
        const available_width = @max(1, self.layout_width);
        for (&self.surfaces, 0..) |*slot, index| {
            const pane_index = self.paneIndex(slot.session_name);
            if (slot.surface == null) continue;
            if (pane_index) |position| {
                const horizontal = selected.split_direction == .horizontal;
                const first = if (horizontal) @divTrunc(available_width * position, pane_count) else 0;
                const next = if (horizontal) @divTrunc(available_width * (position + 1), pane_count)
                    else available_width;
                const top = if (horizontal) 0 else @divTrunc(available_height * position, pane_count);
                const bottom = if (horizontal) available_height
                    else @divTrunc(available_height * (position + 1), pane_count);
                _ = c.winghostty_surface_set_visible(slot.surface, 1);
                const bounds = c.winghostty_rect{
                    .x = self.layout_origin_x + @as(i32, @intCast(first)),
                    .y = self.layout_origin_y + Tokens.tab_bar_height + Tokens.pane_header_height + @as(i32, @intCast(top)),
                    .width = @intCast(@max(1, next - first)),
                    .height = @intCast(@max(1, bottom - top)),
                };
                _ = c.winghostty_surface_set_bounds(slot.surface, &bounds);
                const focused = position == selected.focused_pane;
                _ = c.winghostty_surface_set_focus(slot.surface, if (focused) 1 else 0);
                if (focused) self.active_surface = index;
            } else {
                _ = c.winghostty_surface_set_visible(slot.surface, 0);
                _ = c.winghostty_surface_set_focus(slot.surface, 0);
            }
        }
    }

    fn syncFocusedPane(self: *Workspace) void {
        self.syncTopology();
        self.persistLayout() catch {};
    }

    fn paneIndex(self: *const Workspace, id: []const u8) ?usize {
        const selected = self.layout.selectedConst() orelse return null;
        for (selected.panes.items, 0..) |pane, index| {
            if (std.mem.eql(u8, pane.id, id)) return index;
        }
        return null;
    }

    pub fn send(self: *Workspace, text: []const u8) void {
        if (self.active_surface >= self.surfaces.len) return;
        self.enqueueInput(self.active_surface, text);
    }

    pub fn inputStatus(self: *const Workspace) ?[]const u8 {
        const workspace: *Workspace = @constCast(self);
        workspace.input_mutex.lock();
        defer workspace.input_mutex.unlock();
        if (workspace.input_error_message.len == 0) return null;
        return workspace.input_error_message;
    }

    pub fn hasSurface(self: *const Workspace, index: usize) bool {
        return index < self.surfaces.len and self.surfaces[index].surface != null;
    }

    pub fn hasAttach(self: *const Workspace, index: usize) bool {
        return index < self.surfaces.len and self.surfaces[index].attach != null;
    }

    pub fn firstLiveSurface(self: *const Workspace) ?usize {
        for (self.surfaces, 0..) |slot, index| {
            if (slot.surface != null or slot.attach != null) return index;
        }
        return null;
    }

    pub fn surfaceIdentityReady(self: *const Workspace, index: usize, session: []const u8, project: []const u8) bool {
        if (index >= self.surfaces.len) return false;
        const slot = &self.surfaces[index];
        return (slot.surface != null or slot.attach != null) and
            surfaceIdentityMatches(slot, project, session);
    }

    pub fn dispatchKeyForTest(self: *Workspace, key: usize, ctrl: bool, shift: bool) void {
        if (self.key_callback) |callback| callback(self.key_callback_context, key, ctrl, shift);
    }

    pub fn topologyHealthy(self: *const Workspace) bool {
        var pane_count: usize = 0;
        var occupied: usize = 0;
        for (self.layout.tabs.items) |tab| {
            if (tab.panes.items.len == 0 or tab.focused_pane >= tab.panes.items.len) return false;
            for (tab.panes.items) |pane| {
                pane_count += 1;
                var found = false;
                for (&self.surfaces) |slot| {
                    if (std.mem.eql(u8, slot.session_name, pane.id) and
                        (slot.surface != null or slot.attach != null))
                    {
                        if (found) return false;
                        found = true;
                    }
                }
                if (!found) return false;
            }
        }
        for (&self.surfaces) |slot| {
            if (slot.surface == null and slot.attach == null) continue;
            occupied += 1;
            if (slot.session_name.len == 0) return false;
            var mapped = false;
            for (self.layout.tabs.items) |tab| for (tab.panes.items) |pane| {
                if (std.mem.eql(u8, pane.id, slot.session_name)) {
                    if (mapped) return false;
                    mapped = true;
                }
            };
            if (!mapped) return false;
        }
        return pane_count > 0 and pane_count == occupied;
    }

    pub fn tabCount(self: *const Workspace) usize {
        return self.layout.tabs.items.len;
    }

    pub fn layoutMatches(self: *const Workspace, origin_x: i32, origin_y: i32, width: i32, height: i32) bool {
        return self.layout_origin_x == origin_x and
            self.layout_origin_y == origin_y and
            self.layout_width == width and
            self.layout_height == @max(1, height);
    }

    pub fn destroySurface(self: *Workspace, index: usize) void {
        if (index >= self.surfaces.len) return;
        const slot = &self.surfaces[index];
        slot.destroying = true;
        self.cancelSurfaceInput(index);
        self.waitInputIdle(index);
        self.waitAttach(index);
        if (slot.surface) |surface| {
            _ = c.winghostty_surface_destroy(surface);
            slot.surface = null;
            slot.destroyed = true;
        }
        slot.destroying = false;
        if (slot.session_name.len != 0) {
            self.allocator.free(slot.session_name);
            slot.session_name = &.{};
        }
        if (slot.project_path.len != 0) {
            self.allocator.free(slot.project_path);
            slot.project_path = &.{};
        }
        self.resetSessionState(index);
    }

    fn surfaceOptions(self: *Workspace, index: usize) c.winghostty_surface_options_v2 {
        var options: c.winghostty_surface_options_v2 = undefined;
        c.winghostty_surface_options_v2_init(&options);
        options.bounds.x = if (index == 0) 0 else 480;
        options.bounds.y = 0;
        options.bounds.width = 480;
        options.bounds.height = 240;
        options.visible = 1;
        options.focus = if (index == self.active_surface) 1 else 0;
        options.theme = c.WINGHOSTTY_THEME_DARK;
        options.font_scale = 1.0;
        options.user_data = @ptrCast(self);
        options.callbacks.on_exit = @ptrCast(&onExit);
        options.callbacks.on_title = @ptrCast(&onTitle);
        options.callbacks.on_cwd = @ptrCast(&onCwd);
        options.callbacks.on_bell = @ptrCast(&onBell);
        options.callbacks.on_notification = @ptrCast(&onNotification);
        options.callbacks.on_redraw = @ptrCast(&onRedraw);
        options.callbacks.on_focus = @ptrCast(&onFocus);
        options.callbacks.on_fatal_error = @ptrCast(&onFatalError);
        options.callbacks.on_dpi_changed = @ptrCast(&onDpiChanged);
        options.callbacks.on_metrics_changed = @ptrCast(&onMetricsChanged);
        options.callbacks.on_accessibility_selection = @ptrCast(&onAccessibilitySelection);
        options.input_callbacks.on_key = @ptrCast(&onKey);
        options.input_callbacks.on_text = @ptrCast(&onText);
        options.input_callbacks.on_ime_start = @ptrCast(&onImeStart);
        options.input_callbacks.on_ime_update = @ptrCast(&onImeUpdate);
        options.input_callbacks.on_ime_end = @ptrCast(&onImeEnd);
        options.input_callbacks.on_mouse = @ptrCast(&onMouse);
        options.input_callbacks.on_selection = @ptrCast(&onSelection);
        options.input_callbacks.on_link = @ptrCast(&onLink);
        options.input_callbacks.on_paste = @ptrCast(&onPaste);
        options.input_callbacks.on_clipboard_read = @ptrCast(&onClipboardRead);
        options.input_callbacks.on_clipboard_write = @ptrCast(&onClipboardWrite);
        options.input.cell_width = 8;
        options.input.cell_height = 16;
        options.input.selection_enabled = 1;
        options.input.links_enabled = 1;
        options.input.paste_protection = 1;
        options.input.bracketed_paste = 1;
        options.input.keyboard_layout = null;
        return options;
    }

    fn startSession(self: *Workspace, index: usize, session: []const u8) !void {
        const nonreading = std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_SHELL_NONREADING_ATTACH") catch null;
        defer if (nonreading) |value| self.allocator.free(value);
        var attach_args: [4][]const u8 = undefined;
        var attach_len: usize = 3;
        if (nonreading != null and std.mem.eql(u8, nonreading.?, "1")) {
            attach_args = .{ "pwsh", "-NoProfile", "-Command", "Start-Sleep -Seconds 60" };
            attach_len = 4;
        } else {
            attach_args[0] = self.zmx_path;
            attach_args[1] = "attach";
            attach_args[2] = session;
        }
        var child = std.process.Child.init(attach_args[0..attach_len], self.allocator);
        child.cwd = self.cwd;
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        if (child.stdin) |stdin| {
            var mode: c.DWORD = c.PIPE_NOWAIT;
            _ = c.SetNamedPipeHandleState(stdin.handle, &mode, null, null);
        }
        self.input_mutex.lock();
        self.surfaces[index].attach = child;
        self.input_mutex.unlock();
    }

    fn waitAttach(self: *Workspace, index: usize) void {
        self.cancelSurfaceInput(index);
        self.waitInputIdle(index);
        if (self.surfaces[index].attach) |*child| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            self.surfaces[index].attach = null;
        }
    }

    fn enqueueInput(self: *Workspace, index: usize, bytes: []const u8) void {
        if (bytes.len == 0) return;
        if (bytes.len > input_queue_max_bytes) {
            self.setInputError("terminal input queue overflow: paste is too large");
            return;
        }
        const copy = self.allocator.dupe(u8, bytes) catch {
            self.setInputError("terminal input queue allocation failed");
            return;
        };
        self.input_mutex.lock();
        if (self.input_stop) {
            self.input_mutex.unlock();
            self.allocator.free(copy);
            return;
        }
        self.input_queue.enqueue(index, copy) catch |err| {
            self.input_mutex.unlock();
            self.allocator.free(copy);
            self.setInputError(switch (err) {
                error.InputTooLarge => "terminal input queue overflow: paste is too large",
                error.InputQueueFull => "terminal input queue overflow",
            });
            return;
        };
        self.input_condition.signal();
        self.input_mutex.unlock();
    }

    fn stopInputWorker(self: *Workspace) void {
        self.input_mutex.lock();
        self.input_stop = true;
        self.input_condition.broadcast();
        self.input_mutex.unlock();
        self.cancelInputIo();
        if (self.input_worker) |worker| worker.join();
        self.input_worker = null;
        self.input_mutex.lock();
        self.input_queue.clear();
        self.input_busy = false;
        self.input_worker_surface = null;
        self.input_worker_handle = null;
        self.input_mutex.unlock();
    }

    fn inputWorkerMain(self: *Workspace) void {
        while (true) {
            self.input_mutex.lock();
            while (self.input_queue.count == 0 and !self.input_stop) {
                _ = self.input_condition.timedWait(&self.input_mutex, 25 * std.time.ns_per_ms) catch {};
            }
            if (self.input_stop) {
                self.input_mutex.unlock();
                break;
            }
            const item = self.input_queue.dequeue().?;
            self.input_busy = true;
            self.input_worker_surface = item.surface;
            self.input_worker_handle = if (self.surfaces[item.surface].attach) |child|
                if (child.stdin) |stdin| stdin.handle else null
            else
                null;
            self.input_cancel_requested = false;
            const handle = self.input_worker_handle;
            self.input_mutex.unlock();

            const result = if (handle) |value|
                writeInputBounded(value, item.bytes)
            else
                error.InputUnavailable;
            const cancelled = self.inputCancelled();
            if (result) |written| {
                self.input_mutex.lock();
                if (item.surface < self.surfaces.len) self.surfaces[item.surface].input_bytes += written;
                self.input_mutex.unlock();
            } else |err| {
                if (!cancelled) {
                    self.setInputError(switch (err) {
                        error.WriteTimeout => "terminal input write timed out",
                        error.InputUnavailable => "terminal attach input unavailable",
                        else => "terminal input write failed",
                    });
                }
            }
            self.allocator.free(item.bytes);
            self.input_mutex.lock();
            self.input_busy = false;
            self.input_worker_surface = null;
            self.input_worker_handle = null;
            self.input_cancel_requested = false;
            self.input_condition.broadcast();
            self.input_mutex.unlock();
        }
    }

    fn inputCancelled(self: *Workspace) bool {
        self.input_mutex.lock();
        defer self.input_mutex.unlock();
        return self.input_cancel_requested or self.input_stop;
    }

    fn setInputError(self: *Workspace, message: []const u8) void {
        self.input_mutex.lock();
        self.input_error_message = message;
        self.fatal_error = true;
        self.input_mutex.unlock();
    }

    fn cancelInputIo(self: *Workspace) void {
        var handle: c.HANDLE = null;
        var thread_handle: std.Thread.Handle = undefined;
        var have_thread = false;
        self.input_mutex.lock();
        self.input_cancel_requested = true;
        handle = self.input_worker_handle;
        if (self.input_worker) |worker| {
            thread_handle = worker.getHandle();
            have_thread = true;
        }
        self.input_mutex.unlock();
        if (handle != null and handle != c.INVALID_HANDLE_VALUE) {
            _ = c.CancelIoEx(handle, null);
        }
        if (have_thread) _ = c.CancelSynchronousIo(thread_handle);
    }

    fn cancelSurfaceInput(self: *Workspace, index: usize) void {
        self.input_mutex.lock();
        self.input_queue.removeSurface(index);
        const busy = self.input_busy and self.input_worker_surface == index;
        self.input_mutex.unlock();
        if (busy) self.cancelInputIo();
    }

    fn waitInputIdle(self: *Workspace, index: usize) void {
        const deadline = nowMilliseconds() + 500;
        while (true) {
            self.input_mutex.lock();
            const busy = self.input_busy and self.input_worker_surface == index;
            if (!busy) {
                self.input_mutex.unlock();
                return;
            }
            _ = self.input_condition.timedWait(&self.input_mutex, 25 * std.time.ns_per_ms) catch {};
            self.input_mutex.unlock();
            if (nowMilliseconds() >= deadline) {
                self.cancelInputIo();
                return;
            }
        }
    }

    fn readAttachOutput(self: *Workspace, index: usize) void {
        const slot = &self.surfaces[index];
        const child = slot.attach orelse return;
        const stdout = child.stdout orelse return;
        var available: c.DWORD = 0;
        if (c.PeekNamedPipe(@ptrCast(stdout.handle), null, 0, null, &available, null) == 0) {
            self.handleAttachExit(index);
            return;
        }
        var budget: usize = 64 * 1024;
        while (available > 0 and budget > 0) {
            var buffer: [4096]u8 = undefined;
            var read: c.DWORD = 0;
            const amount = @min(
                @min(available, @as(c.DWORD, @intCast(buffer.len))),
                @as(c.DWORD, @intCast(budget)),
            );
            if (c.ReadFile(@ptrCast(stdout.handle), &buffer, amount, &read, null) == 0 or read == 0) {
                self.handleAttachExit(index);
                return;
            }
            self.feedTerminalOutput(index, buffer[0..@intCast(read)]);
            budget -= @intCast(read);
            if (c.PeekNamedPipe(@ptrCast(stdout.handle), null, 0, null, &available, null) == 0) {
                self.handleAttachExit(index);
                return;
            }
        }
        if (c.GetExitCodeProcess(child.id, &available) != 0 and available != c.STILL_ACTIVE) {
            self.handleAttachExit(index);
        }
    }

    fn handleAttachExit(self: *Workspace, index: usize) void {
        if (index >= self.surfaces.len) return;
        const slot = &self.surfaces[index];
        if (slot.attach == null) return;
        const session = if (slot.session_name.len == 0)
            null
        else
            self.allocator.dupe(u8, slot.session_name) catch null;
        self.waitAttach(index);
        self.destroySurface(index);
        if (session) |value| {
            if (self.recreate_sessions[index].len != 0) self.allocator.free(self.recreate_sessions[index]);
            self.recreate_sessions[index] = value;
            self.recreate_due_ms[index] = nowMilliseconds() + self.recreate_delay_ms[index];
            self.recreate_delay_ms[index] = @min(self.recreate_delay_ms[index] * 2, 4_000);
        }
    }

    fn pollRecreates(self: *Workspace) void {
        const now = nowMilliseconds();
        for (self.recreate_sessions, 0..) |session, index| {
            if (session.len == 0 or self.surfaces[index].surface != null or now < self.recreate_due_ms[index]) {
                continue;
            }
            self.openNode(index, session) catch {
                self.recreate_due_ms[index] = now + self.recreate_delay_ms[index];
                self.recreate_delay_ms[index] = @min(self.recreate_delay_ms[index] * 2, 4_000);
                continue;
            };
            self.clearRestoreError(index);
            self.recreate_delay_ms[index] = 100;
        }
    }

    fn resetSessionState(self: *Workspace, index: usize) void {
        const slot = &self.surfaces[index];
        slot.terminal_buffer_len = 0;
        slot.parser = .normal;
        slot.csi_value = 0;
        slot.csi_have_value = false;
        clearCells(slot);
        slot.input_bytes = 0;
        slot.output_events = 0;
    }

    fn feedTerminalOutput(self: *Workspace, index: usize, bytes: []const u8) void {
        const slot = &self.surfaces[index];
        const surface = slot.surface orelse return;
        appendOutput(slot, bytes);
        feedCells(slot, bytes);
        self.render_error = c.winghostty_surface_set_terminal_cells(
            surface,
            columns,
            rows,
            slot.cells.ptr,
            cell_count,
        );
        _ = c.winghostty_surface_notify_accessibility_text(
            surface,
            slot.terminal_buffer[0..slot.terminal_buffer_len].ptr,
            slot.terminal_buffer_len,
            0,
            slot.terminal_buffer_len,
            0,
            0,
            slot.terminal_buffer_len,
        );
        _ = c.winghostty_surface_notify_redraw(surface);
        slot.output_events += 1;
    }
};

fn writeInputBounded(handle: c.HANDLE, bytes: []const u8) !usize {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const amount: c.DWORD = @intCast(@min(bytes.len - offset, 16 * 1024));
        var overlapped = std.mem.zeroes(c.OVERLAPPED);
        overlapped.hEvent = c.CreateEventW(null, 1, 0, null);
        if (overlapped.hEvent == null) return error.WriteFailed;
        defer _ = c.CloseHandle(overlapped.hEvent);
        var written: c.DWORD = 0;
        if (c.WriteFile(handle, bytes[offset..].ptr, amount, &written, &overlapped) == 0) {
            if (c.GetLastError() != c.ERROR_IO_PENDING) return error.WriteFailed;
            const wait_result = c.WaitForSingleObject(overlapped.hEvent, input_write_timeout_ms);
            if (wait_result == c.WAIT_TIMEOUT) {
                _ = c.CancelIoEx(handle, &overlapped);
                waitForCancelledWrite(handle, &overlapped, &written);
                return error.WriteTimeout;
            }
            if (wait_result != c.WAIT_OBJECT_0 or
                c.GetOverlappedResult(handle, &overlapped, &written, 0) == 0)
            {
                return error.WriteFailed;
            }
        }
        if (written == 0) return error.WriteFailed;
        offset += written;
    }
    return offset;
}

fn waitForCancelledWrite(
    handle: c.HANDLE,
    overlapped: *c.OVERLAPPED,
    written: *c.DWORD,
) void {
    if (c.GetOverlappedResult(handle, overlapped, written, 1) != 0) return;
    const completion_error = c.GetLastError();
    if (completion_error == c.ERROR_OPERATION_ABORTED or
        completion_error == c.ERROR_IO_INCOMPLETE)
    {
        return;
    }
}

fn nowMilliseconds() i64 {
    return @intCast(std.time.milliTimestamp());
}

fn projectLayoutSuffix(project: []const u8) [16]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(project, &digest, .{});
    var suffix: [16]u8 = undefined;
    const value = std.mem.readInt(u64, digest[0..8], .little);
    const hex = "0123456789abcdef";
    for (0..16) |index| {
        suffix[15 - index] = hex[(value >> @as(u6, @intCast(index * 4))) & 0x0f];
    }
    return suffix;
}

test "project layout suffix is fixed width and deterministic" {
    try std.testing.expectEqualStrings("763dc256de57db00", &projectLayoutSuffix("leading-zero-182"));
}

fn workspaceFromUserData(user_data: ?*anyopaque) ?*Workspace {
    return if (user_data) |value| @ptrCast(@alignCast(value)) else null;
}

fn slotForSurface(workspace: *Workspace, surface: *c.winghostty_surface) ?*Surface {
    for (&workspace.surfaces) |*slot| if (slot.surface == surface) return slot;
    return null;
}

fn callbackSlot(workspace: *Workspace, surface: *c.winghostty_surface) ?*Surface {
    const slot = slotForSurface(workspace, surface) orelse return null;
    if (slot.destroying or slot.destroyed) return null;
    return slot;
}

fn onExit(user_data: ?*anyopaque, surface: ?*c.winghostty_surface, status: i32) callconv(.c) void {
    const workspace = workspaceFromUserData(user_data) orelse return;
    if (surface) |value| _ = callbackSlot(workspace, value);
    _ = status;
}

fn onTitle(user_data: ?*anyopaque, surface: *c.winghostty_surface, title: [*:0]const u8) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = title;
}

fn onCwd(user_data: ?*anyopaque, surface: *c.winghostty_surface, cwd: [*:0]const u8) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = cwd;
}

fn onBell(user_data: ?*anyopaque, surface: *c.winghostty_surface) callconv(.c) void {
    _ = user_data;
    _ = surface;
}

fn onNotification(user_data: ?*anyopaque, surface: *c.winghostty_surface, notification: [*:0]const u8) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = notification;
}

fn onRedraw(user_data: ?*anyopaque, surface: *c.winghostty_surface) callconv(.c) void {
    const workspace = workspaceFromUserData(user_data) orelse return;
    _ = callbackSlot(workspace, surface) orelse return;
    if (c.winghostty_surface_make_current(surface) != c.WINGHOSTTY_OK) return;
    _ = c.winghostty_surface_render(surface);
    _ = c.winghostty_surface_present(surface);
    _ = c.winghostty_surface_clear_current(surface);
}

fn onFocus(user_data: ?*anyopaque, surface: *c.winghostty_surface, focused: u8) callconv(.c) void {
    const workspace = workspaceFromUserData(user_data) orelse return;
    _ = callbackSlot(workspace, surface) orelse return;
    if (focused == 0) return;
    if (workspace.syncing_topology or workspace.syncing_focus) return;
    for (&workspace.surfaces, 0..) |*slot, index| {
        if (slot.surface == surface) {
            workspace.active_surface = index;
            workspace.persistFocusedSurface(index);
        }
        if (slot.surface) |other| {
            if (other != surface) {
                _ = c.winghostty_surface_set_focus(other, 0);
            }
        }
    }
}

fn onFatalError(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    result: c.winghostty_result,
    message: [*:0]const u8,
) callconv(.c) void {
    const workspace = workspaceFromUserData(user_data) orelse return;
    _ = callbackSlot(workspace, surface) orelse return;
    _ = result;
    _ = message;
    workspace.fatal_error = true;
}

fn onDpiChanged(user_data: ?*anyopaque, surface: *c.winghostty_surface, dpi: u32, scale: f32) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = dpi;
    _ = scale;
}

fn onMetricsChanged(user_data: ?*anyopaque, surface: *c.winghostty_surface, metrics: *const c.winghostty_cell_metrics) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = metrics;
}

fn onAccessibilitySelection(user_data: ?*anyopaque, surface: *c.winghostty_surface, start: u64, end: u64) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = start;
    _ = end;
}

fn onKey(user_data: ?*anyopaque, surface: *c.winghostty_surface, event: *const c.winghostty_key_event) callconv(.c) void {
    const workspace = workspaceFromUserData(user_data) orelse return;
    _ = callbackSlot(workspace, surface) orelse return;
    if (event.action == c.WINGHOSTTY_KEY_RELEASE) return;
    const modifiers = callbackModifiers(event.modifiers);
    const ctrl = modifiers.ctrl;
    const shift = modifiers.shift;
    if (isApplicationShortcut(event.virtual_key, ctrl, shift))
    {
        if (workspace.key_callback) |callback|
            callback(workspace.key_callback_context, event.virtual_key, ctrl, shift);
        return;
    }

    const bytes: []const u8 = switch (event.virtual_key) {
        c.VK_RETURN => "\r",
        c.VK_BACK => "\x08",
        c.VK_TAB => "\t",
        c.VK_ESCAPE => "\x1b",
        c.VK_UP => "\x1b[A",
        c.VK_DOWN => "\x1b[B",
        c.VK_LEFT => "\x1b[D",
        c.VK_RIGHT => "\x1b[C",
        else => return,
    };
    const index = surfaceIndex(workspace, surface) orelse return;
    workspace.enqueueInput(index, bytes);
}

fn isApplicationShortcut(key: usize, ctrl: bool, shift: bool) bool {
    _ = shift;
    if (key == c.VK_TAB) return true;
    if (!ctrl) return false;
    return switch (key) {
        'O', 'J', 'N', 'S', 'T', 'W', 'D', c.VK_PRIOR, c.VK_NEXT, 0xDB, 0xDD, 0xBC => true,
        else => false,
    };
}

fn callbackModifiers(mask: u32) struct { ctrl: bool, shift: bool } {
    return .{ .ctrl = (mask & 0x02) != 0, .shift = (mask & 0x01) != 0 };
}

test "child key callback forwards advertised menu shortcuts only" {
    try std.testing.expect(isApplicationShortcut(c.VK_PRIOR, true, false));
    try std.testing.expect(isApplicationShortcut(c.VK_NEXT, true, false));
    try std.testing.expect(isApplicationShortcut(c.VK_TAB, true, false));
    try std.testing.expect(isApplicationShortcut(c.VK_TAB, false, true));
    try std.testing.expect(isApplicationShortcut(0xBC, true, false));
    try std.testing.expect(isApplicationShortcut('W', true, true));
    try std.testing.expect(!isApplicationShortcut(c.VK_UP, false, false));
    try std.testing.expect(!isApplicationShortcut(c.VK_DOWN, false, false));
    try std.testing.expect(!isApplicationShortcut('M', true, false));
}

test "child callback preserves actual modifier bits" {
    const plain = callbackModifiers(0);
    try std.testing.expect(!plain.ctrl);
    try std.testing.expect(!plain.shift);
    const shifted = callbackModifiers(0x01);
    try std.testing.expect(!shifted.ctrl);
    try std.testing.expect(shifted.shift);
    const controlled = callbackModifiers(0x02);
    try std.testing.expect(controlled.ctrl);
    try std.testing.expect(!controlled.shift);
    const both = callbackModifiers(0x03);
    try std.testing.expect(both.ctrl);
    try std.testing.expect(both.shift);
}

fn onText(user_data: ?*anyopaque, surface: *c.winghostty_surface, text: [*:0]const u8, length: u32) callconv(.c) void {
    const workspace = workspaceFromUserData(user_data) orelse return;
    _ = callbackSlot(workspace, surface) orelse return;
    const index = surfaceIndex(workspace, surface) orelse return;
    workspace.enqueueInput(index, text[0..length]);
}

fn onImeStart(user_data: ?*anyopaque, surface: *c.winghostty_surface) callconv(.c) void {
    _ = user_data;
    _ = surface;
}

fn onImeUpdate(user_data: ?*anyopaque, surface: *c.winghostty_surface, text: [*:0]const u8, length: u32, cursor: u32) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = text;
    _ = length;
    _ = cursor;
}

fn onImeEnd(user_data: ?*anyopaque, surface: *c.winghostty_surface) callconv(.c) void {
    _ = user_data;
    _ = surface;
}

fn onMouse(user_data: ?*anyopaque, surface: *c.winghostty_surface, event: *const c.winghostty_mouse_event) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = event;
}

fn onSelection(user_data: ?*anyopaque, surface: *c.winghostty_surface, event: *const c.winghostty_selection_event) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = event;
}

fn onLink(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    link: [*:0]const u8,
    hovered: u8,
    clicked: u8,
) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = link;
    _ = hovered;
    _ = clicked;
}

fn onPaste(user_data: ?*anyopaque, surface: *c.winghostty_surface, text: [*:0]const u8, length: u32, bracketed: u8) callconv(.c) void {
    const workspace = workspaceFromUserData(user_data) orelse return;
    _ = callbackSlot(workspace, surface) orelse return;
    const index = surfaceIndex(workspace, surface) orelse return;
    workspace.enqueueInput(index, text[0..length]);
    _ = bracketed;
}

fn onClipboardRead(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    format: u32,
    text: [*:0]const u8,
    length: u32,
) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = format;
    _ = text;
    _ = length;
}

fn onClipboardWrite(
    user_data: ?*anyopaque,
    surface: *c.winghostty_surface,
    format: u32,
    text: [*:0]const u8,
    length: u32,
) callconv(.c) void {
    _ = user_data;
    _ = surface;
    _ = format;
    _ = text;
    _ = length;
}

fn surfaceIndex(workspace: *Workspace, surface: *c.winghostty_surface) ?usize {
    for (workspace.surfaces, 0..) |slot, index| if (slot.surface == surface) return index;
    return null;
}

test "surface identity cannot leak a session across project paths" {
    const first = Surface{
        .project_path = @constCast("C:\\work\\first"),
        .session_name = @constCast("node-1"),
    };
    const second = Surface{
        .project_path = @constCast("C:\\work\\second"),
        .session_name = @constCast("node-1"),
    };
    try std.testing.expect(surfaceIdentityMatches(&first, "C:\\work\\first", "node-1"));
    try std.testing.expect(!surfaceIdentityMatches(&second, "C:\\work\\first", "node-1"));
}

fn fillRect(hdc: c.HDC, bounds: c.RECT, color: u32) void {
    const brush = c.CreateSolidBrush(color);
    if (brush == null) return;
    _ = c.FillRect(hdc, &bounds, brush);
    _ = c.DeleteObject(brush);
}

fn drawUtf8(hdc: c.HDC, text: []const u8, x: i32, y: i32, size: i32, color: u32) void {
    const wide = std.unicode.utf8ToUtf16LeAlloc(std.heap.page_allocator, text) catch return;
    defer std.heap.page_allocator.free(wide);
    _ = c.SetTextColor(hdc, color);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    var bounds = c.RECT{ .left = x, .top = y, .right = x + 220, .bottom = y + size + 8 };
    _ = c.DrawTextW(hdc, wide.ptr, @intCast(wide.len), &bounds, c.DT_LEFT | c.DT_SINGLELINE);
}

fn tabLabel(tab: WorkspaceLayout.Tab, index: usize) []const u8 {
    if (tab.panes.items.len > 1) return "split";
    if (index == 0) return "agent";
    return "shell";
}

fn loopTypeAccent(loop_type: []const u8) u32 {
    if (std.mem.eql(u8, loop_type, "goalBased")) return 0x0048C78E;
    if (std.mem.eql(u8, loop_type, "timeBased")) return 0x00D6A649;
    if (std.mem.eql(u8, loop_type, "composite")) return 0x00C77DFF;
    return 0x007AB8FF;
}

fn stateAccent(state: []const u8) u32 {
    if (std.mem.eql(u8, state, "failed") or std.mem.eql(u8, state, "stalled")) return 0x005F5FFF;
    if (std.mem.eql(u8, state, "succeeded")) return 0x006BD58D;
    if (std.mem.eql(u8, state, "blocked")) return 0x0049B8FF;
    return 0x00C8C8CC;
}

fn appendOutput(slot: *Surface, bytes: []const u8) void {
    if (bytes.len >= slot.terminal_buffer.len) {
        @memcpy(&slot.terminal_buffer, bytes[bytes.len - slot.terminal_buffer.len ..]);
        slot.terminal_buffer_len = slot.terminal_buffer.len;
        return;
    }
    if (slot.terminal_buffer_len + bytes.len > slot.terminal_buffer.len) {
        const overflow = slot.terminal_buffer_len + bytes.len - slot.terminal_buffer.len;
        std.mem.copyForwards(u8, slot.terminal_buffer[0 .. slot.terminal_buffer_len - overflow], slot.terminal_buffer[overflow..slot.terminal_buffer_len]);
        slot.terminal_buffer_len -= overflow;
    }
    @memcpy(slot.terminal_buffer[slot.terminal_buffer_len..][0..bytes.len], bytes);
    slot.terminal_buffer_len += bytes.len;
}

fn clearCells(slot: *Surface) void {
    for (slot.cells) |*cell| cell.* = .{ .codepoint = 0, .foreground = 0xE6E6E6, .background = 0, .flags = 0 };
    slot.terminal_x = 0;
    slot.terminal_y = 0;
}

fn advanceLine(slot: *Surface) void {
    slot.terminal_x = 0;
    if (slot.terminal_y + 1 < rows) {
        slot.terminal_y += 1;
        return;
    }
    std.mem.copyForwards(c.winghostty_terminal_cell, slot.cells[0 .. cell_count - columns], slot.cells[columns..]);
    for (slot.cells[cell_count - columns ..]) |*cell| cell.* = .{ .codepoint = 0, .foreground = 0xE6E6E6, .background = 0, .flags = 0 };
}

fn putCodepoint(slot: *Surface, codepoint: u32) void {
    if (slot.terminal_x >= columns) advanceLine(slot);
    slot.cells[slot.terminal_y * columns + slot.terminal_x] = .{ .codepoint = codepoint, .foreground = 0xE6E6E6, .background = 0, .flags = 0 };
    slot.terminal_x += 1;
}

fn finishCsi(slot: *Surface, final: u8) void {
    const value = if (slot.csi_have_value) slot.csi_value else 1;
    switch (final) {
        'A' => slot.terminal_y -|= value,
        'B' => slot.terminal_y = @min(rows - 1, slot.terminal_y + value),
        'C' => slot.terminal_x = @min(columns, slot.terminal_x + value),
        'D' => slot.terminal_x -|= value,
        'J' => if (slot.csi_have_value and slot.csi_value == 2) clearCells(slot),
        'K' => {
            const start = slot.terminal_y * columns + slot.terminal_x;
            for (slot.cells[start..][0 .. columns - slot.terminal_x]) |*cell| cell.* = .{ .codepoint = 0, .foreground = 0xE6E6E6, .background = 0, .flags = 0 };
        },
        else => {},
    }
    slot.csi_value = 0;
    slot.csi_have_value = false;
}

fn feedCells(slot: *Surface, bytes: []const u8) void {
    for (bytes) |byte| switch (slot.parser) {
        .normal => switch (byte) {
            0x1B => slot.parser = .escape,
            '\r' => slot.terminal_x = 0,
            '\n' => advanceLine(slot),
            '\x08' => slot.terminal_x -|= 1,
            '\t' => slot.terminal_x = @min(columns, (slot.terminal_x + 8) & ~@as(usize, 7)),
            0x20...0x7E => putCodepoint(slot, byte),
            else => {},
        },
        .escape => switch (byte) {
            '[' => {
                slot.parser = .csi;
                slot.csi_value = 0;
                slot.csi_have_value = false;
            },
            ']' => slot.parser = .osc,
            'c' => {
                clearCells(slot);
                slot.parser = .normal;
            },
            else => slot.parser = .normal,
        },
        .csi => switch (byte) {
            '0'...'9' => {
                slot.csi_have_value = true;
                slot.csi_value = @min(9999, slot.csi_value * 10 + (byte - '0'));
            },
            0x40...0x7E => {
                finishCsi(slot, byte);
                slot.parser = .normal;
            },
            else => {},
        },
        .osc => {
            if (byte == 0x07) {
                slot.parser = .normal;
            } else if (byte == 0x1B) {
                slot.parser = .escape;
            }
        },
    };
}

test "terminal input queue rejects large paste without waiting" {
    const allocator = std.testing.allocator;
    var queue = InputQueue{ .allocator = allocator };
    defer queue.clear();
    const paste = try allocator.alloc(u8, InputQueue.max_bytes + 1);
    try std.testing.expectError(error.InputTooLarge, queue.enqueue(0, paste));
    allocator.free(paste);
}

test "terminal input queue reports bounded overflow" {
    const allocator = std.testing.allocator;
    var queue = InputQueue{ .allocator = allocator };
    defer queue.clear();
    for (0..input_queue_capacity) |index| {
        const item = try allocator.dupe(u8, "x");
        try queue.enqueue(index % 2, item);
    }
    const overflow = try allocator.dupe(u8, "x");
    try std.testing.expectError(error.InputQueueFull, queue.enqueue(0, overflow));
    allocator.free(overflow);
}

test "bounded input write rejects an invalid attach without blocking" {
    try std.testing.expectError(error.WriteFailed, writeInputBounded(c.INVALID_HANDLE_VALUE, "paste"));
}

test "workspace chrome actions occupy distinct visible buttons" {
    try std.testing.expectEqual(ChromeAction.new_tab, chromeActionForBounds(220, 34, 800, 804, 44).?);
    try std.testing.expectEqual(ChromeAction.split_right, chromeActionForBounds(220, 34, 800, 876, 44).?);
    try std.testing.expectEqual(ChromeAction.split_down, chromeActionForBounds(220, 34, 800, 948, 44).?);
    try std.testing.expectEqual(@as(?ChromeAction, null), chromeActionForBounds(220, 34, 800, 700, 44));
}

test "loop bar actions expose stop only for active loops" {
    try std.testing.expectEqual(LoopBarAction.stop, loopBarActionAt(220, 34, 1200, 1010, 50, false).?);
    try std.testing.expect(loopBarActionAt(220, 34, 1200, 1010, 50, true) == null);
    try std.testing.expectEqual(LoopBarAction.show_graph, loopBarActionAt(220, 34, 1200, 1120, 50, false).?);
    try std.testing.expect(loopBarActionAt(220, 34, 1200, 1120, 90, false) == null);
}
