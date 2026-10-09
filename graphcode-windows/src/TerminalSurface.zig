const std = @import("std");
const c = @import("Win32.zig").c;
const WorkspaceLayout = @import("WorkspaceLayout.zig");
const Tokens = @import("DesignTokens.zig");
const LoopBarLayout = @import("LoopBarLayout.zig");
const AppFont = @import("AppFont.zig");
const GdiGradient = @import("GdiGradient.zig");
const Dpi = @import("Dpi.zig");
const TerminalVt = @import("TerminalVt.zig");
const TerminalKeys = @import("TerminalKeys.zig");
const TerminalKeyEncoding = @import("TerminalKeyEncoding.zig");
const ZmxSession = @import("ZmxSession.zig");
const LoopLaunchWait = @import("LoopLaunchWait.zig");

const columns: usize = 120;
const rows: usize = 40;
const cell_count: usize = columns * rows;
const max_terminal_grid_cells: u64 = 256 * 1024;

const default_grid = GridSize{ .cols = @intCast(columns), .rows = @intCast(rows) };

const GridSize = struct {
    cols: u16,
    rows: u16,

    fn eql(left: GridSize, right: GridSize) bool {
        return left.cols == right.cols and left.rows == right.rows;
    }
};

fn gridSizeForBounds(
    width: u32,
    height: u32,
    metrics: c.winghostty_cell_metrics,
) error{GridTooLarge}!GridSize {
    const cell_width = if (metrics.cell_width == 0) 8 else metrics.cell_width;
    const cell_height = if (metrics.cell_height == 0) 16 else metrics.cell_height;
    const cols = @max(@as(u64, width) / cell_width, 1);
    const row_count = @max(@as(u64, height) / cell_height, 1);
    if (cols > std.math.maxInt(u16) or row_count > std.math.maxInt(u16)) return error.GridTooLarge;
    const count = std.math.mul(u64, cols, row_count) catch return error.GridTooLarge;
    if (count > max_terminal_grid_cells) return error.GridTooLarge;
    return .{
        .cols = @intCast(cols),
        .rows = @intCast(row_count),
    };
}

fn resizedCellBuffer(
    allocator: std.mem.Allocator,
    old_cells: []const c.winghostty_terminal_cell,
    old_size: GridSize,
    new_size: GridSize,
    vt: ?*TerminalVt.State,
) ![]c.winghostty_terminal_cell {
    const old_count = std.math.mul(usize, old_size.cols, old_size.rows) catch return error.InvalidGridSize;
    if (old_count > max_terminal_grid_cells or old_cells.len != old_count) return error.InvalidGridSize;
    const count = std.math.mul(usize, new_size.cols, new_size.rows) catch return error.InvalidGridSize;
    if (count > max_terminal_grid_cells) return error.InvalidGridSize;
    const cells = try allocator.alloc(c.winghostty_terminal_cell, count);
    errdefer allocator.free(cells);
    for (cells) |*cell| cell.* = .{
        .codepoint = 0,
        .foreground = 0xE6E6E6,
        .background = 0,
        .flags = 0,
    };
    if (vt) |state| try state.resize(new_size.cols, new_size.rows);
    const copy_rows = @min(old_size.rows, new_size.rows);
    const copy_columns = @min(old_size.cols, new_size.cols);
    for (0..copy_rows) |row| {
        const old_start = row * old_size.cols;
        const new_start = row * new_size.cols;
        @memcpy(cells[new_start..][0..copy_columns], old_cells[old_start..][0..copy_columns]);
    }
    return cells;
}

fn formatGridSize(size: GridSize, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d}x{d}", .{ size.cols, size.rows });
}

fn attachArguments(
    program: []const u8,
    session: []const u8,
    size: GridSize,
    output: *[5][]const u8,
    size_buffer: []u8,
    session_buffer: []u8,
) ![]const []const u8 {
    output.* = .{
        program,
        "attach",
        try ZmxSession.nameBuffer(session, session_buffer),
        "--size",
        try formatGridSize(size, size_buffer),
    };
    return output;
}

fn resizeArguments(
    program: []const u8,
    session: []const u8,
    size: GridSize,
    output: *[4][]const u8,
    size_buffer: []u8,
    session_buffer: []u8,
) ![]const []const u8 {
    output.* = .{
        program,
        "resize",
        try ZmxSession.nameBuffer(session, session_buffer),
        try formatGridSize(size, size_buffer),
    };
    return output;
}

fn paneBounds(
    origin_x: i32,
    origin_y: i32,
    width: i32,
    height: i32,
    direction: WorkspaceLayout.Direction,
    position: usize,
    pane_count: usize,
) c.winghostty_rect {
    if (width <= 0 or height <= Tokens.tab_bar_height + Tokens.pane_header_height) {
        return .{ .x = origin_x, .y = origin_y, .width = 0, .height = 0 };
    }
    const available_height = height - Tokens.tab_bar_height - Tokens.pane_header_height;
    const safe_count = @max(pane_count, 1);
    const available_width = width;
    const horizontal = direction == .horizontal;
    const first = if (horizontal)
        @divTrunc(@as(i64, available_width) * @as(i64, @intCast(position)), @as(i64, @intCast(safe_count)))
    else
        0;
    const next = if (horizontal)
        @divTrunc(@as(i64, available_width) * @as(i64, @intCast(position + 1)), @as(i64, @intCast(safe_count)))
    else
        available_width;
    const top = if (horizontal)
        0
    else
        @divTrunc(@as(i64, available_height) * @as(i64, @intCast(position)), @as(i64, @intCast(safe_count)));
    const bottom = if (horizontal)
        available_height
    else
        @divTrunc(@as(i64, available_height) * @as(i64, @intCast(position + 1)), @as(i64, @intCast(safe_count)));
    return .{
        .x = origin_x + @as(i32, @intCast(first)),
        .y = origin_y + Tokens.tab_bar_height + Tokens.pane_header_height + @as(i32, @intCast(top)),
        .width = @intCast(@max(1, next - first)),
        .height = @intCast(@max(1, bottom - top)),
    };
}

const ParserState = enum { normal, escape, csi, osc };
const input_queue_capacity: usize = 64;
const input_queue_max_bytes: usize = 1024 * 1024;
const input_write_timeout_ms: c.DWORD = 50;
const max_surfaces: usize = 32;

pub const ChromeAction = enum { new_tab, split_right, split_down };
pub const TabAction = enum { select, close };
pub const LoopBarAction = LoopBarLayout.Action;

pub fn loopBarLayout(left: i32, right: i32, resolved: bool, panel_toggle: bool) LoopBarLayout.Layout {
    return LoopBarLayout.compute(left, Tokens.header_height, right, resolved, panel_toggle);
}

pub fn loopBarActionAt(left: i32, top: i32, right: i32, x: i32, y: i32, resolved: bool, panel_toggle: bool) ?LoopBarAction {
    return LoopBarLayout.compute(left, top, right, resolved, panel_toggle).actionAt(x, y);
}

fn chromeActionForBounds(origin_x: i32, origin_y: i32, width: i32, x: i32, y: i32) ?ChromeAction {
    for (0..3) |index| {
        const bounds = chromeControlBounds(origin_x, origin_y, width, index);
        if (x >= bounds.left and x < bounds.right and y >= bounds.top and y < bounds.bottom) {
            return switch (index) {
                0 => .new_tab,
                1 => .split_right,
                2 => .split_down,
                else => null,
            };
        }
    }
    return null;
}

pub fn chromeControlBounds(origin_x: i32, origin_y: i32, width: i32, index: usize) c.RECT {
    const left = @max(origin_x, origin_x + width - 220) + @as(i32, @intCast(index)) * 72;
    return .{ .left = left, .top = origin_y + 3, .right = left + 68, .bottom = origin_y + Tokens.tab_bar_height - 3 };
}

pub fn tabBounds(origin_x: i32, origin_y: i32, index: usize) c.RECT {
    const left = origin_x + @as(i32, @intCast(index)) * 120;
    return .{ .left = left, .top = origin_y + 4, .right = left + 112, .bottom = origin_y + Tokens.tab_bar_height - 4 };
}

fn tabActionForBounds(origin_x: i32, origin_y: i32, index: usize, x: i32, y: i32) ?TabAction {
    const bounds = tabBounds(origin_x, origin_y, index);
    if (x < bounds.left or x >= bounds.right or y < bounds.top or y >= bounds.bottom) return null;
    if (x >= bounds.right - 24) return .close;
    return .select;
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
    grid: GridSize = default_grid,
    last_resize_size: ?GridSize = null,
    attempted_resize_size: ?GridSize = null,
    pending_resize_size: ?GridSize = null,
    // Counts batches whose cell, accessibility, and redraw publication calls all succeeded.
    output_events: usize = 0,
    output_result: TerminalOutputResult = .{},
    cells: []c.winghostty_terminal_cell = &.{},
    vt: ?*TerminalVt.State = null,
    last_redraw_failure: ?struct {
        surface: *c.winghostty_surface,
        failure: RedrawFailure,
    } = null,
    terminal_x: usize = 0,
    terminal_y: usize = 0,
    parser: ParserState = .normal,
    csi_value: usize = 0,
    csi_have_value: bool = false,
    // Runtime DPI state reported back by winghostty for this specific surface (via
    // on_dpi_changed/on_metrics_changed), as opposed to Workspace.dpi, which is what
    // this app last told winghostty the monitor DPI is. Kept per-surface since each
    // pane can in principle straddle a per-monitor DPI boundary independently.
    dpi: u32 = Dpi.base_dpi,
    reported_font_scale: f32 = 1.0,
    cell_metrics: c.winghostty_cell_metrics = std.mem.zeroes(c.winghostty_cell_metrics),
    // The most recent text-selection range winghostty reported for this surface
    // (start/end are its own internal buffer offsets). Previously discarded entirely
    // by onAccessibilitySelection; kept here so a UIA text pattern for the embedded
    // terminal has real selection data to expose instead of none at all.
    accessibility_selection: ?struct { start: u64, end: u64 } = null,

    fn resetOutput(self: *Surface) void {
        if (self.vt) |state| state.destroy();
        self.vt = null;
        self.parser = .normal;
        self.csi_value = 0;
        self.csi_have_value = false;
        clearCells(self);
        self.input_bytes = 0;
        self.output_events = 0;
        self.output_result = .{};
    }
};

pub fn surfaceIdentityMatches(surface: *const Surface, project_path: []const u8, session: []const u8) bool {
    return std.mem.eql(u8, surface.project_path, project_path) and
        std.mem.eql(u8, surface.session_name, session);
}

fn moveReplacementSurface(
    surfaces: *[max_surfaces]Surface,
    target_index: usize,
    replacement_index: usize,
) void {
    std.debug.assert(target_index < surfaces.len);
    std.debug.assert(replacement_index < surfaces.len);
    std.debug.assert(target_index != replacement_index);
    std.debug.assert(surfaces[target_index].surface == null);
    std.debug.assert(surfaces[target_index].attach == null);
    std.debug.assert(surfaces[replacement_index].surface != null or
        surfaces[replacement_index].attach != null);
    std.mem.swap(Surface, &surfaces[target_index], &surfaces[replacement_index]);
}

/// One `zmx kill` ending shell sessions the user closed or whose loop was deleted. The
/// child runs beside the UI and is reaped by `Workspace.poll`, so a wedged zmx never holds a
/// window.
const KillJob = struct {
    child: std.process.Child,
    argv: [][]const u8,
    names: [][]u8,

    fn deinit(self: *KillJob, allocator: std.mem.Allocator) void {
        for (self.names) |name| allocator.free(name);
        allocator.free(self.names);
        allocator.free(self.argv);
    }
};

const kill_wait_ms: i64 = 3_000;

/// The project key under which a quick chat's layout is saved. It is no project's path, so
/// a chat's layout is never mistaken for a graph loop's when loops are reconciled.
pub const quick_chat_scope_project = "graphcode://quick-chats";

pub const Workspace = struct {
    pub const LaunchOutcome = enum { started, not_started, attach_failed };
    pub const loop_open_timeout_ms = LoopLaunchWait.open_timeout_ms;
    // A listing that outlives its wait's deadline by this much is treated as no answer.
    const launch_probe_grace_ms: i64 = 5_000;
    const restore_probe_timeout_ms: i64 = 2_000;
    const max_listing_bytes: usize = 1 << 20;

    parent: c.HWND,
    host: ?*c.winghostty_host = null,
    surfaces: [max_surfaces]Surface = [_]Surface{.{}} ** max_surfaces,
    active_surface: usize = 0,
    allocator: std.mem.Allocator,
    experimental_vt: bool = false,
    zmx_path: []u8,
    cwd: []u8,
    recreate_sessions: [max_surfaces][]u8 = [_][]u8{&.{}} ** max_surfaces,
    recreate_due_ms: [max_surfaces]i64 = [_]i64{0} ** max_surfaces,
    recreate_delay_ms: [max_surfaces]i64 = [_]i64{100} ** max_surfaces,
    restore_errors: [max_surfaces][]u8 = [_][]u8{&.{}} ** max_surfaces,
    // A graph loop's pane attaches only after the daemon's session exists (LoopLaunchWait).
    launch_waits: [max_surfaces]LoopLaunchWait.Wait = [_]LoopLaunchWait.Wait{.{}} ** max_surfaces,
    launch_probes: [max_surfaces]?std.process.Child = [_]?std.process.Child{null} ** max_surfaces,
    launch_probe_output: [max_surfaces]std.ArrayListUnmanaged(u8) = [_]std.ArrayListUnmanaged(u8){.empty} ** max_surfaces,
    daemon_sessions: [max_surfaces]bool = [_]bool{false} ** max_surfaces,
    passive_retry_due_ms: [max_surfaces]i64 = [_]i64{0} ** max_surfaces,
    launch_outcome: ?LaunchOutcome = null,
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
    resize_child: ?std.process.Child = null,
    resize_child_surface: ?usize = null,
    resize_child_size: ?GridSize = null,
    resize_child_session: []u8 = &.{},
    input_queue: InputQueue,
    input_error_message: []const u8 = "",
    layout: WorkspaceLayout.Layout,
    layout_path: []u8,
    project_key: []u8,
    /// The loop (or quick chat) the layout belongs to, once opened; see `scopeToLoop`.
    loop_id: []u8 = &.{},
    /// Directory where earlier shells saved a project-wide layout; empty is the process's
    /// working directory, which for the installed shell is its install `bin` folder.
    legacy_directory: []u8 = &.{},
    kill_jobs: std.ArrayListUnmanaged(KillJob) = .empty,
    key_callback: ?WorkspaceKeyCallback = null,
    key_callback_context: ?*anyopaque = null,
    layout_origin_x: i32 = 0,
    layout_origin_y: i32 = 0,
    layout_width: i32 = 960,
    layout_height: i32 = 250,
    collapsed: bool = false,
    project_path: []u8 = &.{},
    /// The open loop's directory, where new terminal sessions start (see `sessionDirectory`).
    shell_directory: []u8 = &.{},
    syncing_topology: bool = false,
    syncing_focus: bool = false,
    persisting_layout: bool = false,
    // The monitor DPI this workspace last propagated to its live terminal surfaces
    // (see setDpi()). Drives both the font_scale given to new surfaces created via
    // surfaceOptions() and the DPI/font-scale pushed to already-live surfaces when
    // the host window moves across a DPI boundary.
    dpi: u32 = Dpi.base_dpi,

    pub fn init(parent: c.HWND, allocator_: std.mem.Allocator) !*Workspace {
        const experimental_vt = try TerminalVt.startupEnabled(allocator_);
        const workspace = try allocator_.create(Workspace);
        workspace.* = .{
            .parent = parent,
            .allocator = allocator_,
            .experimental_vt = experimental_vt,
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
        if (workspace.layout_path.len != 0) {
            if (WorkspaceLayout.Layout.load(allocator_, workspace.layout_path, workspace.project_key)) |restored| {
                workspace.layout.deinit();
                workspace.layout = restored;
            } else |_| {}
        }
        if (c.winghostty_host_initialize(&workspace.host) != c.WINGHOSTTY_OK) {
            return error.WinghosttyHostInitializeFailed;
        }
        workspace.restorePersistedSurfaces("", 0);
        return workspace;
    }

    pub fn startInputWorker(self: *Workspace) !void {
        self.input_worker = try std.Thread.spawn(.{}, inputWorkerMain, .{self});
    }

    pub fn deinit(self: *Workspace) void {
        self.stopResizeChild();
        self.stopInputWorker();
        self.cancelAllLaunchWaits();
        self.finishKillJobs();
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
        if (self.shell_directory.len != 0) self.allocator.free(self.shell_directory);
        if (self.host) |host| {
            _ = c.winghostty_host_deinitialize(host);
            self.host = null;
        }

        self.allocator.free(self.zmx_path);
        self.allocator.free(self.cwd);
        self.layout.deinit();
        self.allocator.free(self.layout_path);
        self.allocator.free(self.project_key);
        if (self.loop_id.len != 0) self.allocator.free(self.loop_id);
        if (self.legacy_directory.len != 0) self.allocator.free(self.legacy_directory);
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
        self.clearLoopScope();
        self.clearShellDirectory();
        self.restorePersistedSurfaces("", 0);
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
        // A layout scoped to a loop of this project keeps its own file.
        const keeps_scope = !key_changed and self.loop_id.len != 0;
        const new_layout_path = if (keeps_scope)
            try self.allocator.dupe(u8, self.layout_path)
        else
            try self.layoutPathForProject(project_path);
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
        if (key_changed) self.clearLoopScope();
        self.clearShellDirectory();
        self.restoreScopedSurfaces();
        return true;
    }

    fn clearLoopScope(self: *Workspace) void {
        if (self.loop_id.len != 0) self.allocator.free(self.loop_id);
        self.loop_id = &.{};
    }

    /// Restores the layout's panes; a layout scoped to a loop leaves slot 0 and the loop's
    /// own pane to the loop's launch (see `scopeToLoop`).
    fn restoreScopedSurfaces(self: *Workspace) void {
        if (self.loop_id.len == 0) return self.restorePersistedSurfaces("", 0);
        self.restorePersistedSurfaces(self.loop_id, 1);
    }

    fn clearShellDirectory(self: *Workspace) void {
        if (self.shell_directory.len != 0) self.allocator.free(self.shell_directory);
        self.shell_directory = &.{};
    }

    pub fn projectPath(self: *const Workspace) []const u8 {
        return self.project_path;
    }

    /// Records where the open loop's plain-shell tabs and splits start, as on macOS: the
    /// loop's worktree, else its project folder. Empty leaves them in the shell's own
    /// working directory.
    pub fn setShellDirectory(self: *Workspace, directory: []const u8) !void {
        const copy = try self.allocator.dupe(u8, directory);
        if (self.shell_directory.len != 0) self.allocator.free(self.shell_directory);
        self.shell_directory = copy;
    }

    /// The directory a new terminal session starts in: the open loop's directory, else the
    /// workspace's project folder. One that does not exist locally (a reclaimed worktree,
    /// a remote or global project) falls back to the shell's own working directory.
    fn sessionDirectory(self: *const Workspace) []const u8 {
        for ([_][]const u8{ self.shell_directory, self.project_path }) |candidate| {
            if (candidate.len == 0 or !std.fs.path.isAbsolute(candidate)) continue;
            var directory = std.fs.cwd().openDir(candidate, .{}) catch continue;
            directory.close();
            return candidate;
        }
        return self.cwd;
    }

    /// The zmx program for a child started outside the shell's working directory. The
    /// installed shell names zmx bare (`zmx.exe`) and finds it beside itself through that
    /// directory, `...\GraphCode\current\bin`, which PATH need not name. A child resolves a
    /// relative program against its own working directory, then PATH, so an attach started
    /// in the loop's directory would not find it. Resolved once against the shell's
    /// directory, as every other zmx child (started there) already resolves it; a name not
    /// found there is left to PATH.
    fn zmxExecutable(self: *Workspace) []const u8 {
        if (self.zmx_path.len == 0 or std.fs.path.isAbsolute(self.zmx_path)) return self.zmx_path;
        const candidate = std.fs.path.join(self.allocator, &.{ if (self.cwd.len == 0) "." else self.cwd, self.zmx_path }) catch
            return self.zmx_path;
        defer self.allocator.free(candidate);
        const resolved = std.fs.cwd().realpathAlloc(self.allocator, candidate) catch return self.zmx_path;
        self.allocator.free(self.zmx_path);
        self.zmx_path = resolved;
        return self.zmx_path;
    }

    /// The project-level layout file. `GRAPHCODE_WORKSPACE_LAYOUT` names a base explicitly
    /// (the smoke and gate harnesses); otherwise it lives under the user's support
    /// directory, never next to the executable. Empty when no support directory resolves,
    /// which turns persistence off rather than writing into the install directory.
    fn layoutPathForProject(self: *Workspace, project: []const u8) ![]u8 {
        if (std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_WORKSPACE_LAYOUT")) |configured| {
            defer self.allocator.free(configured);
            const suffix = WorkspaceLayout.projectSuffix(project);
            return std.fmt.allocPrint(self.allocator, "{s}.{s}.json", .{
                configured[0 .. if (std.mem.endsWith(u8, configured, ".json")) configured.len - 5 else configured.len],
                suffix,
            });
        } else |_| {}
        const root = WorkspaceLayout.layoutsDirectory(self.allocator) catch return self.allocator.dupe(u8, "");
        defer self.allocator.free(root);
        return WorkspaceLayout.projectLayoutPath(self.allocator, root, project);
    }

    /// The directory holding this workspace's layout files, which a loop's own layout joins.
    fn layoutRoot(self: *const Workspace) ?[]const u8 {
        const directory = std.fs.path.dirname(self.layout_path) orelse return null;
        return if (directory.len == 0) null else directory;
    }

    /// Binds the workspace to one loop (or quick chat), as macOS keeps a layout per node.
    /// Its tabs and splits are saved under its own id, so a New Tab or Split made in one
    /// loop is never shown in another and a deleted loop's can be found and ended. The
    /// loop's agent pane is mounted as the first tab (`launches_agent`), and slot 0 and that
    /// pane are left to the loop's launch; every other saved pane whose session is still
    /// running is re-attached. A layout saved by an earlier shell for the whole project is
    /// adopted once, by the loop it names. A workspace without a layout directory is left
    /// as it is.
    pub fn scopeToLoop(self: *Workspace, loop: []const u8, layout_project: []const u8, launches_agent: bool) !void {
        if (loop.len == 0) return;
        if (std.mem.eql(u8, self.loop_id, loop) and std.mem.eql(u8, self.layout.project_key, layout_project)) return;
        const root = self.layoutRoot() orelse return;
        const new_path = try WorkspaceLayout.loopLayoutPath(self.allocator, root, loop);
        errdefer self.allocator.free(new_path);
        const new_loop = try self.allocator.dupe(u8, loop);
        errdefer self.allocator.free(new_loop);
        var new_layout = try self.loadLoopLayout(new_path, layout_project, loop);
        errdefer new_layout.deinit();
        if (launches_agent) try new_layout.ensureAgentFirst(loop);

        for (self.surfaces, 0..) |_, index| self.destroySurface(index);
        self.clearAllRecreateState();
        var old_layout = self.layout;
        const old_path = self.layout_path;
        self.layout = new_layout;
        self.layout_path = new_path;
        old_layout.deinit();
        self.allocator.free(old_path);
        self.clearLoopScope();
        self.loop_id = new_loop;
        self.persistLayout() catch {};
        self.restorePersistedSurfaces(loop, 1);
    }

    /// The saved layout of a loop, else one adopted from the legacy project-wide file, else
    /// an empty one.
    fn loadLoopLayout(self: *Workspace, path: []const u8, layout_project: []const u8, loop: []const u8) !WorkspaceLayout.Layout {
        if (WorkspaceLayout.Layout.loadFor(self.allocator, path, layout_project, loop)) |saved| {
            return saved;
        } else |err| if (err == error.FileNotFound) {
            if (try self.adoptLegacy(path, layout_project, loop)) |adopted| return adopted;
        }
        return WorkspaceLayout.Layout.initForLoop(self.allocator, layout_project, loop);
    }

    /// The project-wide layout earlier shells saved is handed to one loop only: the first
    /// that it names. Its shells then belong to that loop, and a marker beside the new
    /// layouts keeps every other loop of the project from claiming them again. The legacy
    /// file itself is only read.
    fn adoptLegacy(self: *Workspace, loop_path: []const u8, layout_project: []const u8, loop: []const u8) !?WorkspaceLayout.Layout {
        const root = std.fs.path.dirname(loop_path) orelse return null;
        const marker = try std.fmt.allocPrint(self.allocator, "{s}\\legacy-adopted.{s}.txt", .{
            root,
            WorkspaceLayout.projectSuffix(self.project_key),
        });
        defer self.allocator.free(marker);
        if (std.fs.cwd().access(marker, .{})) |_| return null else |_| {}
        const legacy_path = try WorkspaceLayout.legacyLayoutPath(self.allocator, self.legacy_directory, self.project_key);
        defer self.allocator.free(legacy_path);
        const adopted = (try WorkspaceLayout.adoptLegacyLayout(self.allocator, legacy_path, self.project_key, loop, layout_project)) orelse return null;
        std.fs.cwd().makePath(root) catch {};
        std.fs.cwd().writeFile(.{ .sub_path = marker, .data = loop }) catch {};
        return adopted;
    }

    /// Ends the shell sessions saved in a deleted loop's layout and forgets the layout. The
    /// sessions ended are exactly the plain-shell panes that layout names; the loop's own
    /// session belongs to the daemon and no other loop's is touched. A layout that cannot be
    /// read ends nothing. Returns how many sessions were ended.
    pub fn retireLoop(self: *Workspace, loop: []const u8, layout_project: []const u8) usize {
        const root = self.layoutRoot() orelse return 0;
        if (loop.len == 0) return 0;
        const path = WorkspaceLayout.loopLayoutPath(self.allocator, root, loop) catch return 0;
        defer self.allocator.free(path);
        const open = std.mem.eql(u8, self.loop_id, loop) and std.mem.eql(u8, self.layout.project_key, layout_project);
        var saved: ?WorkspaceLayout.Layout = null;
        defer if (saved) |*value| value.deinit();
        if (!open) {
            saved = WorkspaceLayout.Layout.loadFor(self.allocator, path, layout_project, loop) catch return 0;
        }
        const source = if (saved) |*value| value else &self.layout;
        var sessions: std.ArrayListUnmanaged([]const u8) = .empty;
        defer sessions.deinit(self.allocator);
        for (source.tabs.items) |tab| for (tab.panes.items) |pane| {
            if (pane.launches_agent or std.mem.eql(u8, pane.id, loop)) continue;
            sessions.append(self.allocator, pane.id) catch return 0;
        };
        const count = sessions.items.len;
        if (open) {
            // Detached first, so ending a shell never reads as an exit to re-create.
            for (self.surfaces, 0..) |_, index| self.destroySurface(index);
            self.clearAllRecreateState();
        }
        const started = self.endSessions(sessions.items);
        if (open) {
            if (WorkspaceLayout.Layout.init(self.allocator, self.layout.project_key)) |emptied| {
                var old_layout = self.layout;
                self.layout = emptied;
                old_layout.deinit();
                if (self.layoutPathForProject(self.project_key)) |project_path| {
                    self.allocator.free(self.layout_path);
                    self.layout_path = project_path;
                } else |_| {}
                self.clearLoopScope();
            } else |_| {}
        }
        std.fs.cwd().deleteFile(path) catch {};
        return if (started) count else 0;
    }

    /// The loop-scoped layouts saved beside this workspace's, for reconciling with the graph.
    pub fn savedLoopLayouts(self: *const Workspace) ![]WorkspaceLayout.LoopRecord {
        const root = self.layoutRoot() orelse return self.allocator.alloc(WorkspaceLayout.LoopRecord, 0);
        return WorkspaceLayout.scanLoopLayouts(self.allocator, root);
    }

    /// `zmx kill <sessions> --force`, run beside the UI and reaped by `poll`. Never the
    /// session of the open loop itself. False when nothing could be started.
    fn endSessions(self: *Workspace, sessions: []const []const u8) bool {
        if (sessions.len == 0) return true;
        const names = self.allocator.alloc([]u8, sessions.len) catch return false;
        var named: usize = 0;
        errdefer {
            for (names[0..named]) |name| self.allocator.free(name);
            self.allocator.free(names);
        }
        for (sessions) |session| {
            names[named] = ZmxSession.allocName(self.allocator, session) catch return false;
            named += 1;
        }
        const argv = self.allocator.alloc([]const u8, sessions.len + 3) catch return false;
        errdefer self.allocator.free(argv);
        argv[0] = self.zmxExecutable();
        argv[1] = "kill";
        for (names, 0..) |name, index| argv[index + 2] = name;
        argv[argv.len - 1] = "--force";
        var child = ZmxSession.child(self.allocator, argv, self.cwd, .control);
        child.spawn() catch return false;
        self.kill_jobs.append(self.allocator, .{ .child = child, .argv = argv, .names = names }) catch {
            _ = child.kill() catch {};
            return false;
        };
        return true;
    }

    fn pollKillJobs(self: *Workspace) void {
        var index: usize = 0;
        while (index < self.kill_jobs.items.len) {
            const job = &self.kill_jobs.items[index];
            var exit_code: c.DWORD = c.STILL_ACTIVE;
            if (c.GetExitCodeProcess(job.child.id, &exit_code) != 0 and exit_code == c.STILL_ACTIVE) {
                index += 1;
                continue;
            }
            _ = job.child.wait() catch {};
            var finished = self.kill_jobs.orderedRemove(index);
            finished.deinit(self.allocator);
        }
    }

    /// Lets running kills finish, bounded, so closing the shell does not strand a request.
    fn finishKillJobs(self: *Workspace) void {
        const deadline = nowMilliseconds() + kill_wait_ms;
        while (self.kill_jobs.items.len != 0 and nowMilliseconds() < deadline) {
            self.pollKillJobs();
            if (self.kill_jobs.items.len != 0) std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        for (self.kill_jobs.items) |*job| {
            _ = job.child.kill() catch {};
            job.deinit(self.allocator);
        }
        self.kill_jobs.deinit(self.allocator);
        self.kill_jobs = .empty;
    }

    /// Attaches a pane to a session, creating a plain shell session when none is running —
    /// right for a shell tab, wrong for a graph loop, whose pane uses `openLaunchedNode`.
    pub fn openNode(self: *Workspace, index: usize, node_id: []const u8) !void {
        if (index >= self.surfaces.len) return error.InvalidSurface;
        self.cancelLaunchWait(index);
        self.daemon_sessions[index] = false;
        try self.attachNode(index, node_id, false);
    }

    /// Opens a graph loop's pane once the daemon has started its session, never creating
    /// one itself. A `timeout_ms` of 0 is a passive check: attach if the loop is already
    /// running, otherwise leave the pane alone.
    pub fn openLaunchedNode(self: *Workspace, index: usize, node_id: []const u8, timeout_ms: i64) !void {
        if (index >= self.surfaces.len) return error.InvalidSurface;
        const slot = &self.surfaces[index];
        if ((slot.surface != null or slot.attach != null) and
            std.mem.eql(u8, slot.session_name, node_id))
        {
            self.cancelLaunchWait(index);
            if (timeout_ms > 0) self.launch_outcome = .started;
            return;
        }
        const now = nowMilliseconds();
        const explicit = timeout_ms > 0;
        const wait = &self.launch_waits[index];
        if (!explicit and now < self.passive_retry_due_ms[index]) return;
        // A passive re-observation (a graph refresh, or an ended session's recreate) never
        // displaces the loop the user just asked to open.
        if (!explicit and wait.active() and wait.reports_timeout and !std.mem.eql(u8, wait.session, node_id)) return;
        const session = try self.allocator.dupe(u8, node_id);
        errdefer self.allocator.free(session);
        // Mount the tab immediately, but not the terminal: pending/failed launches still
        // need navigable workspace chrome, without creating a session behind the daemon.
        if (explicit and slot.surface == null and slot.attach == null) {
            if (self.layout.tabs.items.len == 0) {
                const previous_next_id = self.layout.next_tab_id;
                try self.layout.addTab(node_id, true);
                self.persistLayout() catch |err| {
                    _ = self.layout.removePane(node_id);
                    self.layout.next_tab_id = previous_next_id;
                    return err;
                };
            } else if (wait.active() and wait.reports_timeout) {
                try self.layout.replacePaneID(wait.session, node_id);
                self.persistLayout() catch |err| {
                    self.layout.replacePaneID(node_id, wait.session) catch {};
                    return err;
                };
            } else {
                try self.bindLoopPane(node_id);
            }
        }
        if (wait.active() and std.mem.eql(u8, wait.session, node_id)) {
            self.allocator.free(session);
            wait.extend(now, timeout_ms, explicit);
            return;
        }
        self.cancelLaunchWait(index);
        self.clearRecreateSession(index);
        self.launch_waits[index].begin(session, now, timeout_ms, explicit);
    }

    pub fn isAwaitingLaunch(self: *const Workspace, index: usize) bool {
        return index < self.launch_waits.len and self.launch_waits[index].active();
    }

    /// Whether `node_id` is a loop pane of this workspace's layout that no slot shows or
    /// awaits — the only loop a graph refresh may re-observe.
    pub fn loopPaneDetached(self: *const Workspace, node_id: []const u8) bool {
        if (node_id.len == 0) return false;
        const owned = owned: {
            for (self.layout.tabs.items) |tab| for (tab.panes.items) |pane| {
                if (pane.launches_agent and std.mem.eql(u8, pane.id, node_id)) break :owned true;
            };
            break :owned false;
        };
        if (!owned) return false;
        for (self.surfaces, 0..) |slot, index| {
            if ((slot.surface != null or slot.attach != null) and std.mem.eql(u8, slot.session_name, node_id))
                return false;
            if (self.launch_waits[index].active() and std.mem.eql(u8, self.launch_waits[index].session, node_id))
                return false;
        }
        return true;
    }

    pub fn takeLaunchOutcome(self: *Workspace) ?LaunchOutcome {
        defer self.launch_outcome = null;
        return self.launch_outcome;
    }

    /// zmx's session listing, read without attaching or creating anything and bounded so a
    /// wedged zmx cannot hold the UI thread; null when it could not be read. The caller
    /// owns the bytes.
    fn sessionListing(self: *Workspace) ?std.ArrayListUnmanaged(u8) {
        var child = self.spawnListing() orelse return null;
        var output: std.ArrayListUnmanaged(u8) = .empty;
        const deadline = nowMilliseconds() + restore_probe_timeout_ms;
        var exit_code: c.DWORD = c.STILL_ACTIVE;
        while (true) {
            self.drainListing(&child, &output) catch {
                _ = child.kill() catch {};
                self.setInputError("Unable to read loop session listing");
                output.deinit(self.allocator);
                return null;
            };
            if (c.GetExitCodeProcess(child.id, &exit_code) == 0) {
                _ = child.kill() catch {};
                self.setInputError("Unable to query loop session listing process");
                output.deinit(self.allocator);
                return null;
            }
            if (exit_code != c.STILL_ACTIVE) break;
            if (nowMilliseconds() >= deadline) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        if (exit_code == c.STILL_ACTIVE) {
            _ = child.kill() catch {};
            self.setInputError("Loop session listing timed out");
            output.deinit(self.allocator);
            return null;
        }
        self.drainListing(&child, &output) catch {
            _ = child.wait() catch {};
            self.setInputError("Unable to read loop session listing");
            output.deinit(self.allocator);
            return null;
        };
        _ = child.wait() catch {
            self.setInputError("Unable to reap loop session listing process");
            output.deinit(self.allocator);
            return null;
        };
        if (exit_code != 0) {
            self.setInputError("Loop session listing failed");
            output.deinit(self.allocator);
            return null;
        }
        return output;
    }

    fn spawnListing(self: *Workspace) ?std.process.Child {
        var args: [2][]const u8 = undefined;
        var child = ZmxSession.child(
            self.allocator,
            LoopLaunchWait.probeArguments(self.zmx_path, &args),
            self.cwd,
            .capture,
        );
        child.spawn() catch {
            self.setInputError("Unable to start loop session listing");
            return null;
        };
        return child;
    }

    /// Reads whatever the listing has written so far, so a long one never blocks on a
    /// full pipe. Bounded: the listing is a few hundred bytes per session.
    fn drainListing(self: *Workspace, child: *std.process.Child, output: *std.ArrayListUnmanaged(u8)) !void {
        const stdout = child.stdout orelse return error.SessionListingPipeMissing;
        var buffer: [4096]u8 = undefined;
        while (output.items.len < max_listing_bytes) {
            var available: c.DWORD = 0;
            if (c.PeekNamedPipe(stdout.handle, null, 0, null, &available, null) == 0) {
                if (c.GetLastError() == c.ERROR_BROKEN_PIPE) return;
                return error.SessionListingReadFailed;
            }
            if (available == 0) return;
            var count: c.DWORD = 0;
            const want: c.DWORD = @intCast(@min(buffer.len, available, max_listing_bytes - output.items.len));
            if (c.ReadFile(stdout.handle, &buffer, want, &count, null) == 0) return error.SessionListingReadFailed;
            if (count == 0) return;
            try output.appendSlice(self.allocator, buffer[0..count]);
        }
        return error.SessionListingTooLarge;
    }

    fn pollLaunchWaits(self: *Workspace) void {
        const now = nowMilliseconds();
        for (&self.launch_waits, 0..) |*wait, index| {
            if (!wait.active()) continue;
            const outcome = self.launchProbeOutcome(index, now >= wait.deadline_ms + launch_probe_grace_ms);
            switch (wait.step(now, outcome)) {
                .idle => {},
                .start_probe => self.startLaunchProbe(index),
                .attach => {
                    const explicit = wait.reports_timeout;
                    const session = wait.finish();
                    defer self.allocator.free(session);
                    self.attachNode(index, session, true) catch {
                        if (explicit) self.launch_outcome = .attach_failed;
                        continue;
                    };
                    self.daemon_sessions[index] = true;
                    if (explicit) {
                        self.launch_outcome = .started;
                        self.focusRestoredPane() catch {};
                    }
                },
                .give_up => {
                    if (wait.reports_timeout) {
                        self.launch_outcome = .not_started;
                    } else {
                        self.passive_retry_due_ms[index] = now + LoopLaunchWait.passive_retry_ms;
                    }
                    self.allocator.free(wait.finish());
                },
            }
        }
    }

    fn startLaunchProbe(self: *Workspace, index: usize) void {
        self.launch_probe_output[index].clearRetainingCapacity();
        self.launch_probes[index] = self.spawnListing();
    }

    fn launchProbeOutcome(self: *Workspace, index: usize, overdue: bool) ?LoopLaunchWait.Probe {
        const child = if (self.launch_probes[index]) |*value| value else return null;
        const output = &self.launch_probe_output[index];
        self.drainListing(child, output) catch {
            _ = child.kill() catch {};
            self.launch_probes[index] = null;
            self.setInputError("Unable to read loop session listing");
            return .missing;
        };
        var exit_code: c.DWORD = 0;
        if (c.GetExitCodeProcess(child.id, &exit_code) == 0 or
            (exit_code == c.STILL_ACTIVE and overdue))
        {
            _ = child.kill() catch {};
            self.launch_probes[index] = null;
            return .missing;
        }
        if (exit_code == c.STILL_ACTIVE) return .running;
        self.drainListing(child, output) catch {
            _ = child.wait() catch {};
            self.launch_probes[index] = null;
            self.setInputError("Unable to read loop session listing");
            return .missing;
        };
        _ = child.wait() catch {};
        self.launch_probes[index] = null;
        const live = exit_code == 0 and
            LoopLaunchWait.listingShowsLive(output.items, self.launch_waits[index].session);
        return if (live) .live else .missing;
    }

    fn cancelLaunchWait(self: *Workspace, index: usize) void {
        if (self.launch_probes[index]) |*child| {
            _ = child.kill() catch {};
            self.launch_probes[index] = null;
        }
        self.launch_probe_output[index].clearAndFree(self.allocator);
        if (self.launch_waits[index].active()) self.allocator.free(self.launch_waits[index].finish());
    }

    fn cancelAllLaunchWaits(self: *Workspace) void {
        for (0..max_surfaces) |index| {
            self.cancelLaunchWait(index);
            self.daemon_sessions[index] = false;
            self.passive_retry_due_ms[index] = 0;
        }
        self.launch_outcome = null;
    }

    /// `loop_pane` marks a pane the daemon owns, so a restore never recreates its session.
    fn attachNode(self: *Workspace, index: usize, node_id: []const u8, loop_pane: bool) !void {
        if (index >= self.surfaces.len) return error.InvalidSurface;
        if (self.surfaces[index].surface != null or self.surfaces[index].attach != null) {
            const old_id = try self.allocator.dupe(u8, self.surfaces[index].session_name);
            defer self.allocator.free(old_id);
            const replacement_index = try self.createAttachedSurface(node_id, self.surfaces[index].grid);
            errdefer self.destroySurface(replacement_index);
            self.layout.replacePaneID(old_id, node_id) catch |err| {
                self.destroySurface(replacement_index);
                return err;
            };
            _ = self.layout.setLaunchesAgent(node_id, loop_pane);
            self.persistLayout() catch |err| {
                self.layout.replacePaneID(node_id, old_id) catch {};
                self.destroySurface(replacement_index);
                return err;
            };
            self.destroySurface(index);
            moveReplacementSurface(&self.surfaces, index, replacement_index);
            self.syncTopology();
            self.clearRecreateSession(index);
            return;
        }
        self.destroySurface(index);
        self.resetSessionState(index);
        self.recreate_due_ms[index] = 0;
        const slot = &self.surfaces[index];
        slot.session_name = try self.allocator.dupe(u8, node_id);
        errdefer self.destroySurface(index);
        slot.project_path = try self.allocator.dupe(u8, self.project_path);
        try self.startSession(index, slot.session_name, try self.gridForSession(node_id));
        if (self.layout.tabs.items.len == 0) {
            try self.layout.addTab(node_id, true);
        } else if (index > 0 and self.layout.tabs.items.len == 1) {
            try self.layout.addTab(node_id, loop_pane);
        } else if (loop_pane) {
            try self.bindLoopPane(node_id);
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

        self.surfaces[index].destroyed = false;
        self.surfaces[index].destroying = false;
        clearCells(&self.surfaces[index]);
        self.relayout();
        self.clearRecreateSession(index);
    }

    /// Whether any pane of the layout is `id`.
    fn layoutHasPane(self: *const Workspace, id: []const u8) bool {
        for (self.layout.tabs.items) |tab| for (tab.panes.items) |pane| {
            if (std.mem.eql(u8, pane.id, id)) return true;
        };
        return false;
    }

    /// Whether a slot shows or is attaching `id`.
    fn paneShown(self: *const Workspace, id: []const u8) bool {
        for (self.surfaces) |slot| {
            if ((slot.surface != null or slot.attach != null) and std.mem.eql(u8, slot.session_name, id)) return true;
        }
        return false;
    }

    /// Makes `node_id` the layout's loop pane when the layout does not name it yet. The loop
    /// pane that no slot shows any more (its session ended, or its loop was deleted) is
    /// renamed in place and selected; without one, the loop gets its own tab. Otherwise the
    /// loop's terminal would attach beside a stale pane that the tab strip and focus still
    /// draw, leaving it hidden and every later open failing to find its pane.
    fn bindLoopPane(self: *Workspace, node_id: []const u8) !void {
        if (self.layoutHasPane(node_id)) return;
        const previous_selected = self.layout.selected_tab;
        for (self.layout.tabs.items, 0..) |tab, tab_index| for (tab.panes.items, 0..) |pane, pane_index| {
            if (!pane.launches_agent or self.paneShown(pane.id)) continue;
            const old_id = try self.allocator.dupe(u8, pane.id);
            defer self.allocator.free(old_id);
            const previous_focus = tab.focused_pane;
            try self.layout.replacePaneID(old_id, node_id);
            self.layout.selected_tab = tab_index;
            self.layout.tabs.items[tab_index].focused_pane = pane_index;
            self.persistLayout() catch |err| {
                self.layout.replacePaneID(node_id, old_id) catch {};
                self.layout.selected_tab = previous_selected;
                self.layout.tabs.items[tab_index].focused_pane = previous_focus;
                return err;
            };
            return;
        };
        const previous_next_id = self.layout.next_tab_id;
        try self.layout.addTab(node_id, true);
        self.persistLayout() catch |err| {
            _ = self.layout.removePane(node_id);
            self.layout.selected_tab = previous_selected;
            self.layout.next_tab_id = previous_next_id;
            return err;
        };
    }

    /// Re-applies the current layout to the native surfaces without changing whether the
    /// workspace is collapsed: a surface created while the graph shows stays hidden.
    fn relayout(self: *Workspace) void {
        if (self.collapsed) return self.blurAll();
        self.syncTopology();
    }

    pub fn newTab(self: *Workspace) !void {
        const surface_id = try self.layout.newSurfaceID();
        defer self.allocator.free(surface_id);
        const previous_selected = self.layout.selected_tab;
        const previous_next_id = self.layout.next_tab_id;
        const index = try self.createAttachedSurface(surface_id, try self.workspaceGridSize());
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

    fn createAttachedSurface(self: *Workspace, session: []const u8, initial_grid: GridSize) !usize {
        return self.createAttachedSurfaceFrom(0, session, initial_grid);
    }

    fn createAttachedSurfaceFrom(self: *Workspace, first_slot: usize, session: []const u8, initial_grid: GridSize) !usize {
        for (&self.surfaces, 0..) |*slot, index| {
            if (index < first_slot) continue;
            if (slot.surface != null or slot.attach != null or self.launch_waits[index].active()) continue;
            slot.session_name = try self.allocator.dupe(u8, session);
            errdefer self.destroySurface(index);
            slot.project_path = try self.allocator.dupe(u8, self.project_path);
            try self.startSession(index, slot.session_name, initial_grid);
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

            self.surfaces[index].destroyed = false;
            self.surfaces[index].destroying = false;
            clearCells(&self.surfaces[index]);
            self.relayout();
            return index;
        }
        return error.SurfaceCapacityExceeded;
    }

    /// Re-attaches the layout's panes whose sessions are still running, from slot
    /// `first_slot` on. A pane whose session is gone is dropped from the layout rather than
    /// re-created: `zmx attach` would start a new shell under the old name, a ghost the user
    /// never asked for. `skip_id` is left to the caller (the open loop's own pane).
    fn restorePersistedSurfaces(self: *Workspace, skip_id: []const u8, first_slot: usize) void {
        var ids: [max_surfaces][]u8 = undefined;
        var agents: [max_surfaces]bool = undefined;
        var count: usize = 0;
        for (self.layout.tabs.items) |tab| for (tab.panes.items) |pane| {
            if (count == ids.len) break;
            if (skip_id.len != 0 and std.mem.eql(u8, pane.id, skip_id)) continue;
            ids[count] = self.allocator.dupe(u8, pane.id) catch continue;
            agents[count] = pane.launches_agent;
            count += 1;
        };
        defer for (ids[0..count]) |id| self.allocator.free(id);
        var listing = if (count != 0) self.sessionListing() else null;
        defer if (listing) |*value| value.deinit(self.allocator);
        var pruned = false;
        for (ids[0..count], agents[0..count]) |id, launches_agent| {
            const live: ?bool = if (listing) |value| LoopLaunchWait.listingShowsLive(value.items, id) else null;
            if (live == null) {
                // Unknown is not gone: the pane stays saved. A loop pane retries; a shell is
                // never attached blind, since attaching creates the session when it is missing.
                if (launches_agent) self.queueRestoreRetry(first_slot, id, error.SessionListingUnavailable, true);
                continue;
            }
            if (!LoopLaunchWait.restoreKeepsPane(launches_agent, live)) {
                pruned = self.layout.removePane(id) or pruned;
                continue;
            }
            const initial_grid = self.gridForSession(id) catch |err| {
                self.queueRestoreRetry(first_slot, id, err, launches_agent);
                continue;
            };
            if (self.createAttachedSurfaceFrom(first_slot, id, initial_grid)) |index| {
                self.daemon_sessions[index] = launches_agent;
                self.clearRestoreError(index);
            } else |err| {
                self.queueRestoreRetry(first_slot, id, err, launches_agent);
            }
        }
        if (pruned) self.persistLayout() catch {};
        self.syncTopology();
    }

    fn queueRestoreRetry(self: *Workspace, first_slot: usize, session: []const u8, err: anyerror, daemon_session: bool) void {
        for (self.surfaces, 0..) |slot, index| {
            if (index < first_slot) continue;
            if (slot.surface == null and slot.attach == null and self.recreate_sessions[index].len == 0) {
                self.daemon_sessions[index] = daemon_session;
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
        self.cancelAllLaunchWaits();
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
        const index = try self.createAttachedSurface(surface_id, try self.splitGridSize(direction));
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
        // A shell's session is the pane's reason for existing: closing the pane ends it, as
        // on macOS. The loop's own session belongs to the daemon and ends with the loop.
        if (!record.launches_agent and !std.mem.eql(u8, record.id, self.loop_id))
            _ = self.endSessions(&.{record.id});
        self.syncTopology();
    }

    pub fn canCloseTab(self: *const Workspace) bool {
        return self.layout.tabs.items.len > 1;
    }

    pub fn closeTab(self: *Workspace, index: usize) !void {
        if (!self.canCloseTab() or index >= self.layout.tabs.items.len) return error.CannotCloseLastTab;
        try self.layout.selectTab(index);
        const target_id = self.layout.tabs.items[index].id;
        while (self.layout.selected()) |tab| {
            if (tab.id != target_id or tab.panes.items.len == 0) break;
            try self.closeFocusedPane();
            if (self.layout.tabs.items.len <= 1 or index >= self.layout.tabs.items.len) break;
            if (self.layout.tabs.items[index].id != target_id) break;
            try self.layout.selectTab(index);
        }
    }

    pub fn persistLayout(self: *Workspace) !void {
        if (self.persisting_layout or self.layout_path.len == 0) return;
        self.persisting_layout = true;
        defer self.persisting_layout = false;
        try self.layout.save(self.layout_path);
    }

    pub fn recreate(self: *Workspace, index: usize) !void {
        const session = if (self.surfaces[index].session_name.len == 0) return else try self.allocator.dupe(u8, self.surfaces[index].session_name);
        defer self.allocator.free(session);
        self.destroySurface(index);
        if (self.daemon_sessions[index]) return self.openLaunchedNode(index, session, 0);
        try self.attachNode(index, session, false);
    }

    pub fn resize(self: *Workspace, origin_x: i32, origin_y: i32, width: i32, height: i32) void {
        self.collapsed = false;
        self.layout_origin_x = origin_x;
        self.layout_origin_y = origin_y;
        self.layout_width = width;
        self.layout_height = height;
        self.syncTopology();
    }

    /// Propagates a real, runtime monitor DPI (from the host window's WM_DPICHANGED)
    /// down to every live terminal surface, using the two operations winghostty
    /// actually exposes for this: `winghostty_surface_notify_dpi_changed` (so the
    /// surface's own DPI-aware internals, e.g. its own child-window DPI query,
    /// observe the new value) and `winghostty_surface_set_font_scale` (the officially
    /// supported knob for how large winghostty renders its own glyphs). Deliberately
    /// does not also scale `options.input.cell_width`/`cell_height` -- those stay at
    /// their 96-DPI logical baseline in surfaceOptions() so the DPI ratio is applied
    /// exactly once, through font_scale, rather than twice (once here and again by
    /// winghostty recomputing cell metrics from the scaled font).
    pub fn setDpi(self: *Workspace, dpi: u32) void {
        const normalized = Dpi.normalize(dpi);
        if (normalized == self.dpi) return;
        self.dpi = normalized;
        const font_scale = Dpi.fontScale(normalized);
        for (&self.surfaces) |*slot| {
            const surface = slot.surface orelse continue;
            _ = c.winghostty_surface_notify_dpi_changed(surface, normalized);
            _ = c.winghostty_surface_set_font_scale(surface, font_scale);
        }
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

    pub fn tabActionAt(self: *const Workspace, x: i32, y: i32) ?struct { index: usize, action: TabAction } {
        if (y < self.layout_origin_y or y >= self.layout_origin_y + Tokens.tab_bar_height) return null;
        const controls_left = self.chromeControlsLeft();
        if (x < self.layout_origin_x or x >= controls_left) return null;
        const index = @as(usize, @intCast(@divTrunc(x - self.layout_origin_x, 120)));
        if (index >= self.layout.tabs.items.len) return null;
        const action = tabActionForBounds(self.layout_origin_x, self.layout_origin_y, index, x, y) orelse return null;
        return .{ .index = index, .action = action };
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
        // Theme.tabBarGloss painted over the strip, lit from above; approximated as a
        // vertical GradientFill (see Tokens.tab_bar_gloss_top/_bottom).
        GdiGradient.fillVertical(hdc, tab_bar, Tokens.tab_bar_gloss_top, Tokens.tab_bar_gloss_bottom);
        // Theme.tabBarHighlight -- the one-point specular line along the strip's top edge.
        fillRect(hdc, .{ .left = tab_bar.left, .top = tab_bar.top, .right = tab_bar.right, .bottom = tab_bar.top + 1 }, Tokens.tab_bar_highlight);
        const controls_left = self.chromeControlsLeft();
        for (self.layout.tabs.items, 0..) |tab, index| {
            const left = self.layout_origin_x + @as(i32, @intCast(index)) * 120;
            if (left + 112 > controls_left) break;
            const bounds = tabBounds(self.layout_origin_x, self.layout_origin_y, index);
            // Selected: Theme.tabSelectedBackground. Was previously 0x00345D8C, an
            // unintentional blue that did not correspond to any Theme.swift value.
            fillRect(hdc, bounds, if (index == self.layout.selected_tab) Tokens.tab_selected_background else 0x00262626);
            fillRect(hdc, .{ .left = bounds.left + 8, .top = bounds.top + 9, .right = bounds.left + 14, .bottom = bounds.top + 15 }, tabIndicatorColor(self, tab));
            drawUtf8(hdc, tabLabel(tab, index), bounds.left + 19, bounds.top + 4, 10, 0x00E6E6E6);
            var shortcut: [16]u8 = undefined;
            const shortcut_text = std.fmt.bufPrint(&shortcut, "Ctrl+{d}", .{index + 1}) catch "";
            drawUtf8(hdc, shortcut_text, bounds.left + 19, bounds.top + 14, 8, 0x008A8A8A);
            drawUtf8(hdc, "x", bounds.right - 17, bounds.top + 7, 11, if (self.canCloseTab()) 0x00C8C8CC else 0x005A5A5A);
        }
        const labels = [_][]const u8{ "New Tab", "Split R", "Split D" };
        for (labels, 0..) |label, index| {
            const bounds = chromeControlBounds(self.layout_origin_x, self.layout_origin_y, self.layout_width, index);
            // Theme.controlGloss: a small control on the tab strip, lit a step
            // brighter than the strip itself so it reads as raised off it.
            GdiGradient.fillVertical(hdc, bounds, Tokens.control_gloss_top, Tokens.control_gloss_bottom);
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
            drawUtf8(hdc, if (launches_agent) "backend: agent" else "backend: shell", left + 142, pane_top + 5, 8, 0x007A7A7A);
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
        backend: []const u8,
        created_at: ?u64,
        metric_passes: u32,
        token_usage: ?u32,
        resolved: bool,
        panel_toggle: bool,
    ) void {
        const top = Tokens.header_height;
        const layout = loopBarLayout(left, right, resolved, panel_toggle);
        // Theme.loopBar: lit like the tab strip, one step lighter.
        GdiGradient.fillVertical(hdc, .{ .left = left, .top = top, .right = right, .bottom = top + Tokens.loop_bar_height }, Tokens.loop_bar_top, Tokens.loop_bar_bottom);
        if (layout.stripe) |stripe| {
            fillRect(hdc, .{ .left = stripe.left, .top = stripe.top, .right = stripe.right, .bottom = stripe.bottom }, loopTypeAccent(loop_type));
        }
        if (layout.title) |bounds| drawUtf8Bounded(hdc, title, bounds, 13, 0x00F2F2F7);
        if (layout.state) |bounds| drawUtf8Bounded(hdc, state, bounds, 10, stateAccent(state));
        const live_line = if (activity.len != 0) activity else project_name;
        if (layout.activity) |bounds| drawUtf8Bounded(hdc, live_line, bounds, 10, 0x008E8E93);
        var usage: [32]u8 = undefined;
        const usage_text = if (token_usage) |value| std.fmt.bufPrint(&usage, "{d} tokens", .{value}) catch "usage n/a" else "usage n/a";
        var detail: [256]u8 = undefined;
        const detail_text = std.fmt.bufPrint(&detail, "{s}  ·  {s}  ·  pass {d}  ·  {s}", .{
            if (backend.len != 0) backend else "backend n/a",
            if (created_at != null) elapsedLabel(created_at.?) else "elapsed n/a",
            metric_passes,
            usage_text,
        }) catch "workspace metadata unavailable";
        if (layout.detail) |bounds| drawUtf8Bounded(hdc, detail_text, bounds, 9, 0x008E8E93);
        if (layout.stop) |stop| {
            fillRect(hdc, .{ .left = stop.left, .top = stop.top, .right = stop.right, .bottom = stop.bottom }, 0x00303035);
            drawUtf8(hdc, "Stop loop", stop.left + 12, top + 17, 10, 0x00D8D8DC);
        }
        drawUtf8(hdc, "Show in graph", layout.show_graph.left + 4, top + 17, 10, 0x008E8E93);
        // Theme.tabBarShadowLine, blended flat over the loop bar's own bottom stop --
        // the edge where the strip's gloss meets the terminal below it.
        fillRect(hdc, .{ .left = left, .top = top + Tokens.loop_bar_height - 1, .right = right, .bottom = top + Tokens.loop_bar_height }, Tokens.tab_bar_shadow_line);
        _ = allocator;
    }

    pub fn paintWorkspaceToolbar(
        hdc: c.HDC,
        allocator: std.mem.Allocator,
        left: i32,
        right: i32,
        project_name: []const u8,
        project_path: []const u8,
    ) void {
        fillRect(hdc, .{ .left = left, .top = 0, .right = right, .bottom = Tokens.header_height }, Tokens.window_tone);
        drawUtf8(hdc, "Workspace", left + 16, 8, 11, 0x008E8E93);
        drawUtf8(hdc, project_name, left + 92, 7, 15, 0x00FFFFFF);
        drawUtf8(hdc, if (std.mem.startsWith(u8, project_path, "ssh://")) "Remote repository" else "Local folder", left + 260, 10, 10, 0x008E8E93);
        drawUtf8(hdc, "Selected loop", right - 210, 10, 10, 0x008E8E93);
        _ = allocator;
    }

    pub fn poll(self: *Workspace) void {
        // Launch waits run even while collapsed: attaching a loop whose session just came up
        // is what the old synchronous auto-attach did regardless of visibility, and the
        // probes are console-less `zmx ls` runs that never touch accessibility.
        self.pollLaunchWaits();
        self.pollKillJobs();
        // While the workspace is collapsed (not visible as either the full surface or the
        // picture-in-picture panel), skip draining terminal output entirely. Feeding output
        // notifies winghostty's own accessibility layer via
        // winghostty_surface_notify_accessibility_text() on every read, and that notification is
        // independent of our set_focus(0)/set_visible(0) calls -- it kept re-asserting the
        // terminal as the UIA-focused element even after every Win32-level focus fix, because a
        // live shell session simply never stops producing output. zmx buffers output for detached
        // sessions server-side, so it's safe to stop draining the local attach pipe while hidden.
        if (self.collapsed) return;
        for (self.surfaces, 0..) |_, index| self.readAttachOutput(index);
        self.pollRecreates();
        self.pollResizeControl();
    }

    /// Releases native Win32 keyboard focus from every live terminal surface and hides them.
    /// Callers must invoke this whenever the workspace stops being the visible surface (e.g.
    /// navigating back to the project overview) so a background terminal never keeps holding OS
    /// focus/foreground and starving unrelated chrome (sidebar rows, dialogs) of it.
    pub fn blurAll(self: *Workspace) void {
        for (&self.surfaces) |*slot| {
            if (slot.surface) |surface| {
                _ = c.winghostty_surface_set_focus(surface, 0);
                _ = c.winghostty_surface_set_visible(surface, 0);
            }
        }
    }

    /// Collapses the workspace to a zero-size, unfocused, hidden state without going through
    /// resize()/syncTopology() -- syncTopology() unconditionally re-focuses the active pane's
    /// terminal surface even at a degenerate size, which is exactly the behavior callers leaving
    /// the workspace surface need to avoid.
    pub fn collapse(self: *Workspace) void {
        self.collapsed = true;
        self.layout_origin_x = 0;
        self.layout_origin_y = 0;
        self.layout_width = 0;
        self.layout_height = 0;
        self.blurAll();
    }

    pub fn focus(self: *Workspace, index: usize) void {
        self.focusWith(index, c.winghostty_surface_set_focus);
    }

    fn focusWith(self: *Workspace, index: usize, comptime set_focus: anytype) void {
        if (index >= self.surfaces.len) return;
        if (self.syncing_focus or self.syncing_topology) return;
        self.syncing_focus = true;
        defer self.syncing_focus = false;
        self.active_surface = index;
        for (&self.surfaces, 0..) |*slot, other_index| {
            if (slot.surface) |surface| {
                _ = set_focus(surface, if (index == other_index) 1 else 0);
            }

        }
        self.persistFocusedSurface(index);
    }

    pub fn focusRestoredPane(self: *Workspace) !void {
        try self.focusRestoredPaneWith(c.winghostty_surface_set_focus);
    }

    fn focusRestoredPaneWith(self: *Workspace, comptime set_focus: anytype) !void {
        if (self.collapsed or self.layout.tabs.items.len == 0) return;
        const tab = self.layout.selectedConst() orelse return error.InvalidSelectedTab;
        if (tab.focused_pane >= tab.panes.items.len) return error.InvalidFocusedPane;
        const id = tab.panes.items[tab.focused_pane].id;
        var target: ?usize = null;
        var any_live_surface = false;
        for (&self.surfaces, 0..) |*slot, index| {
            if (slot.surface == null or slot.destroying or slot.destroyed) continue;
            any_live_surface = true;
            if (!surfaceIdentityMatches(slot, self.project_path, id)) continue;
            if (target != null) return error.AmbiguousFocusedSurface;
            target = index;
        }
        if (!any_live_surface) return;
        self.focusWith(target orelse return error.FocusedSurfaceUnavailable, set_focus);
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
        if (self.collapsed) return self.blurAll();
        self.syncing_topology = true;
        defer self.syncing_topology = false;
        const selected = self.layout.selected() orelse return;
        const pane_count = selected.panes.items.len;
        for (&self.surfaces, 0..) |*slot, index| {
            const pane_index = self.paneIndex(slot.session_name);
            if (slot.surface == null) continue;
            if (pane_index) |position| {
                const bounds = paneBounds(
                    self.layout_origin_x,
                    self.layout_origin_y,
                    self.layout_width,
                    self.layout_height,
                    selected.split_direction,
                    position,
                    pane_count,
                );
                // A pane with no area has nowhere to draw; showing it would leave the
                // surface at its previous or placeholder bounds.
                _ = c.winghostty_surface_set_visible(slot.surface, if (bounds.width != 0 and bounds.height != 0) 1 else 0);
                if (bounds.width != 0 and bounds.height != 0) {
                    _ = c.winghostty_surface_set_bounds(slot.surface, &bounds);
                    var metrics = slot.cell_metrics;
                    if (c.winghostty_surface_get_cell_metrics(slot.surface, &metrics) == c.WINGHOSTTY_OK) {
                        slot.cell_metrics = metrics;
                    }
                }
                self.syncPaneGrid(index, bounds, Workspace.resizeSurfaceGrid);
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

    fn fallbackCellMetrics(self: *const Workspace) c.winghostty_cell_metrics {
        for (self.surfaces) |slot| {
            if (slot.cell_metrics.cell_width != 0 and slot.cell_metrics.cell_height != 0)
                return slot.cell_metrics;
        }
        return .{
            .font_width = @intCast(@max(1, Dpi.scale(8, self.dpi))),
            .font_height = @intCast(@max(1, Dpi.scale(16, self.dpi))),
            .cell_width = @intCast(@max(1, Dpi.scale(8, self.dpi))),
            .cell_height = @intCast(@max(1, Dpi.scale(16, self.dpi))),
            .baseline = @intCast(@max(1, Dpi.scale(13, self.dpi))),
        };
    }

    fn gridForSession(self: *const Workspace, session: []const u8) !GridSize {
        const metrics = self.fallbackCellMetrics();
        const tab = self.layout.selectedConst() orelse return self.workspaceGridSize();
        for (tab.panes.items, 0..) |pane, position| {
            if (!std.mem.eql(u8, pane.id, session)) continue;
            const bounds = paneBounds(
                self.layout_origin_x,
                self.layout_origin_y,
                self.layout_width,
                self.layout_height,
                tab.split_direction,
                position,
                tab.panes.items.len,
            );
            return gridSizeForBounds(bounds.width, bounds.height, metrics);
        }
        return self.workspaceGridSize();
    }

    fn workspaceGridSize(self: *const Workspace) !GridSize {
        const bounds = paneBounds(
            self.layout_origin_x,
            self.layout_origin_y,
            self.layout_width,
            self.layout_height,
            .horizontal,
            0,
            1,
        );
        return gridSizeForBounds(bounds.width, bounds.height, self.fallbackCellMetrics());
    }

    fn splitGridSize(self: *const Workspace, direction: WorkspaceLayout.Direction) !GridSize {
        const tab = self.layout.selectedConst() orelse return error.NoTabs;
        const count = tab.panes.items.len + 1;
        const position = tab.focused_pane + 1;
        const bounds = paneBounds(
            self.layout_origin_x,
            self.layout_origin_y,
            self.layout_width,
            self.layout_height,
            direction,
            position,
            count,
        );
        return gridSizeForBounds(bounds.width, bounds.height, self.fallbackCellMetrics());
    }

    fn resizeSurfaceGrid(self: *Workspace, index: usize, size: GridSize) !void {
        try self.resizeSurfaceGridState(index, size);
        if (self.surfaces[index].surface != null) self.feedTerminalOutput(index, "");
    }

    fn resizeSurfaceGridState(self: *Workspace, index: usize, size: GridSize) !void {
        const slot = &self.surfaces[index];
        if (slot.grid.eql(size)) return;
        const cells = try resizedCellBuffer(self.allocator, slot.cells, slot.grid, size, slot.vt);
        errdefer self.allocator.free(cells);
        if (slot.cells.len != 0) self.allocator.free(slot.cells);
        slot.cells = cells;
        slot.grid = size;
        slot.terminal_x = @min(slot.terminal_x, @as(usize, size.cols));
        slot.terminal_y = @min(slot.terminal_y, @as(usize, size.rows - 1));
    }

    fn syncPaneGrid(self: *Workspace, index: usize, bounds: c.winghostty_rect, comptime resize_grid: anytype) void {
        if (bounds.width == 0 or bounds.height == 0) return;
        const slot = &self.surfaces[index];
        const requested_size = gridSizeForBounds(bounds.width, bounds.height, slot.cell_metrics) catch |err| {
            std.debug.print("Terminal grid bounds rejected pane={d} error={s}\n", .{
                index,
                @errorName(err),
            });
            self.setInputError("terminal grid exceeds the supported size");
            return;
        };
        if (!slot.grid.eql(requested_size)) {
            resize_grid(self, index, requested_size) catch |err| {
                std.debug.print("Terminal grid resize failed pane={d} error={s}\n", .{
                    index,
                    @errorName(err),
                });
                self.setInputError("terminal grid resize failed");
                return;
            };
        }
        self.queueResize(index, requested_size);
    }

    fn queueResize(self: *Workspace, index: usize, size: GridSize) void {
        const slot = &self.surfaces[index];
        if (self.resize_child_surface == index and self.resize_child_size != null and
            std.mem.eql(u8, self.resize_child_session, slot.session_name))
        {
            if (self.resize_child_size.?.eql(size)) {
                slot.pending_resize_size = null;
            } else {
                slot.pending_resize_size = size;
            }
            return;
        }
        if (slot.last_resize_size) |sent| {
            if (sent.eql(size)) {
                slot.pending_resize_size = null;
                return;
            }
        }
        if (slot.attempted_resize_size) |attempted| {
            if (attempted.eql(size)) {
                slot.pending_resize_size = null;
                return;
            }
        }
        slot.pending_resize_size = size;
    }

    pub fn send(self: *Workspace, text: []const u8) void {
        if (self.active_surface >= self.surfaces.len) return;
        self.enqueueInput(self.active_surface, text);
    }

    pub fn copySelection(self: *Workspace, allocator: std.mem.Allocator) !?[]u8 {
        if (self.active_surface >= self.surfaces.len) return null;
        const slot = &self.surfaces[self.active_surface];
        const surface = slot.surface orelse return null;
        const selection = slot.accessibility_selection orelse return null;
        if (selection.end <= selection.start) return null;

        const span = selection.end - selection.start;
        const capacity_u64 = std.math.mul(u64, span, 4) catch return error.SelectionTooLarge;
        if (capacity_u64 > std.math.maxInt(usize)) return error.SelectionTooLarge;
        const capacity: usize = @intCast(capacity_u64);
        const text = try allocator.alloc(u8, capacity);
        errdefer allocator.free(text);
        var length: u64 = 0;
        const result = c.winghostty_surface_copy_accessibility_range(
            surface,
            selection.start,
            selection.end,
            text.ptr,
            text.len,
            &length,
        );
        if (result == c.WINGHOSTTY_CLIPBOARD_UNAVAILABLE) return error.TerminalClipboardUnavailable;
        if (result != c.WINGHOSTTY_OK) return error.TerminalSelectionCopyFailed;
        if (length > text.len) return error.TerminalSelectionCopyOverflow;
        return try allocator.realloc(text, @intCast(length));
    }

    pub fn pasteText(self: *Workspace, text: []const u8, allow_unbracketed_multiline: bool) !void {
        if (text.len == 0) return;
        if (self.active_surface >= self.surfaces.len) return error.TerminalSurfaceUnavailable;
        const slot = &self.surfaces[self.active_surface];
        if (slot.surface == null) return error.TerminalSurfaceUnavailable;
        // The running program, not the shell, decides bracketing (DECSET 2004), so a program
        // that did not ask for it never receives the ESC[200~ markers as typed input.
        const bracketed = if (slot.vt) |state| state.bracketedPasteEnabled() else false;
        const payload = try TerminalVt.encodePaste(self.allocator, text, bracketed, allow_unbracketed_multiline);
        defer self.allocator.free(payload);
        if (!self.tryEnqueueInput(self.active_surface, payload)) return error.TerminalPasteFailed;
        slot.accessibility_selection = null;
    }

    /// Runs a terminal clipboard binding through the same route as the canonical
    /// Ctrl+Shift+C / Ctrl+Shift+V chords, whichever key or menu raised it.
    fn runClipboardCommand(self: *Workspace, command: TerminalKeys.ClipboardCommand) void {
        const callback = self.key_callback orelse return;
        callback(self.key_callback_context, switch (command) {
            .copy => 'C',
            .paste => 'V',
        }, true, true);
    }

    /// The right button and the Menu key share one route: the workspace sees the Menu key.
    fn runContextMenu(self: *Workspace) void {
        const callback = self.key_callback orelse return;
        callback(self.key_callback_context, TerminalKeys.vk_apps, false, false);
    }

    /// Whether `window` is one of this workspace's live terminal surface windows.
    pub fn ownsSurfaceWindow(self: *const Workspace, window: c.HWND) bool {
        if (window == null) return false;
        for (self.surfaces) |slot| {
            if (slot.destroying or slot.destroyed) continue;
            const surface = slot.surface orelse continue;
            if (c.winghostty_surface_get_hwnd(surface) == window) return true;
        }
        return false;
    }

    pub fn hasSelection(self: *const Workspace) bool {
        if (self.active_surface >= self.surfaces.len) return false;
        return slotHasSelection(&self.surfaces[self.active_surface]);
    }

    /// Forgets the selection once it has been copied, so the next Ctrl+C interrupts again.
    pub fn dismissSelection(self: *Workspace) void {
        if (self.active_surface >= self.surfaces.len) return;
        self.surfaces[self.active_surface].accessibility_selection = null;
    }

    /// Where the terminal context menu opens: under the pointer when it is over the
    /// active terminal, else near the terminal's top-left corner.
    pub fn contextMenuAnchor(self: *const Workspace) ?c.POINT {
        if (self.active_surface >= self.surfaces.len) return null;
        const surface = self.surfaces[self.active_surface].surface orelse return null;
        const window = c.winghostty_surface_get_hwnd(surface) orelse return null;
        var rect: c.RECT = undefined;
        if (c.GetWindowRect(window, &rect) == 0) return null;
        var point: c.POINT = undefined;
        if (c.GetCursorPos(&point) != 0 and c.PtInRect(&rect, point) != 0) return point;
        return .{ .x = rect.left + 24, .y = rect.top + 24 };
    }

    pub fn inputStatus(self: *const Workspace, current_status: []const u8) ?[]const u8 {
        const workspace: *Workspace = @constCast(self);
        workspace.input_mutex.lock();
        defer workspace.input_mutex.unlock();
        if (workspace.input_error_message.len != 0) return workspace.input_error_message;
        for (&self.surfaces) |*slot| {
            if (slot.output_result.message()) |message| return message;
        }
        for (TerminalOutputResult.error_messages) |message| {
            if (std.mem.eql(u8, current_status, message)) return "Terminal output error cleared";
        }
        return null;
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
        // A surface created while the workspace is collapsed (the graph shows) starts hidden
        // and unfocused; otherwise it would draw at these placeholder bounds, over the sidebar.
        options.visible = if (self.collapsed) 0 else 1;
        options.focus = if (!self.collapsed and index == self.active_surface) 1 else 0;
        options.theme = c.WINGHOSTTY_THEME_DARK;
        // Use the workspace's last-known runtime monitor DPI so a surface created
        // after a DPI change (e.g. a new split/tab opened post-move) starts scaled
        // correctly instead of always assuming 96 DPI/100%.
        options.font_scale = Dpi.fontScale(self.dpi);
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

    fn startSession(self: *Workspace, index: usize, session: []const u8, size: GridSize) !void {
        try self.resizeSurfaceGrid(index, size);
        const vt = if (self.experimental_vt) try TerminalVt.State.create(self.allocator, size.cols, size.rows) else null;
        errdefer if (vt) |state| state.destroy();
        const directory = self.sessionDirectory();
        const nonreading = std.process.getEnvVarOwned(self.allocator, "GRAPHCODE_SHELL_NONREADING_ATTACH") catch null;
        defer if (nonreading) |value| self.allocator.free(value);
        var attach_args: [5][]const u8 = undefined;
        var attach_len: usize = 3;
        var size_buffer: [16]u8 = undefined;
        var session_buffer: [ZmxSession.prefix.len + 128]u8 = undefined;
        if (nonreading != null and std.mem.eql(u8, nonreading.?, "1")) {
            attach_args[0] = "pwsh";
            attach_args[1] = "-NoProfile";
            attach_args[2] = "-Command";
            attach_args[3] = "Start-Sleep -Seconds 60";
            attach_len = 4;
        } else {
            attach_len = (try attachArguments(
                self.zmxExecutable(),
                session,
                size,
                &attach_args,
                &size_buffer,
                &session_buffer,
            )).len;
        }
        var child = ZmxSession.child(self.allocator, attach_args[0..attach_len], directory, .attach);
        try child.spawn();
        if (child.stdin) |stdin| {
            var mode: c.DWORD = c.PIPE_NOWAIT;
            _ = c.SetNamedPipeHandleState(stdin.handle, &mode, null, null);
        }
        self.input_mutex.lock();
        self.surfaces[index].attach = child;
        self.surfaces[index].vt = vt;
        self.surfaces[index].last_resize_size = size;
        self.surfaces[index].attempted_resize_size = null;
        self.surfaces[index].pending_resize_size = null;
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
        _ = self.tryEnqueueInput(index, bytes);
    }

    fn tryEnqueueInput(self: *Workspace, index: usize, bytes: []const u8) bool {
        if (bytes.len == 0) return true;
        if (bytes.len > input_queue_max_bytes) {
            self.setInputError("terminal input queue overflow: paste is too large");
            return false;
        }
        const copy = self.allocator.dupe(u8, bytes) catch {
            self.setInputError("terminal input queue allocation failed");
            return false;
        };
        self.input_mutex.lock();
        if (self.input_stop) {
            self.input_mutex.unlock();
            self.allocator.free(copy);
            return false;
        }
        self.input_queue.enqueue(index, copy) catch |err| {
            self.input_mutex.unlock();
            self.allocator.free(copy);
            self.setInputError(switch (err) {
                error.InputTooLarge => "terminal input queue overflow: paste is too large",
                error.InputQueueFull => "terminal input queue overflow",
            });
            return false;
        };
        self.input_condition.signal();
        self.input_mutex.unlock();
        return true;
    }

    fn routeVtResponses(self: *Workspace, index: usize) void {
        const state = self.surfaces[index].vt orelse return;
        if (state.response_delivery_failed or state.responses().len == 0) return;
        if (self.tryEnqueueInput(index, state.responses())) {
            state.consumeResponses();
        } else {
            state.response_delivery_failed = true;
            self.surfaces[index].output_result.vt_error = error.ResponseDeliveryFailed;
        }
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

    fn stopResizeChild(self: *Workspace) void {
        if (self.resize_child) |*child| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            self.resize_child = null;
        }
        if (self.resize_child_session.len != 0) self.allocator.free(self.resize_child_session);
        self.resize_child_session = &.{};
        self.resize_child_surface = null;
        self.resize_child_size = null;
    }

    fn pollResizeControl(self: *Workspace) void {
        if (self.resize_child) |*child| {
            var exit_code: c.DWORD = 0;
            if (c.GetExitCodeProcess(child.id, &exit_code) == 0) {
                _ = child.kill() catch {};
                _ = child.wait() catch {};
                self.finishResizeControl(false, "terminal PTY resize status unavailable");
            } else if (exit_code != c.STILL_ACTIVE) {
                _ = child.wait() catch {};
                self.finishResizeControl(exit_code == 0, "terminal PTY resize command failed");
            }
        }
        if (self.resize_child != null) return;
        for (&self.surfaces, 0..) |*slot, index| {
            const size = slot.pending_resize_size orelse continue;
            if (slot.attach == null or slot.surface == null) continue;
            var args: [4][]const u8 = undefined;
            var size_buffer: [16]u8 = undefined;
            var session_buffer: [ZmxSession.prefix.len + 128]u8 = undefined;
            const command = resizeArguments(
                self.zmx_path,
                slot.session_name,
                size,
                &args,
                &size_buffer,
                &session_buffer,
            ) catch {
                slot.attempted_resize_size = size;
                slot.pending_resize_size = null;
                self.setInputError("terminal PTY resize command could not be formatted");
                return;
            };
            const session = self.allocator.dupe(u8, slot.session_name) catch {
                slot.attempted_resize_size = size;
                slot.pending_resize_size = null;
                self.setInputError("terminal PTY resize tracking allocation failed");
                return;
            };
            var child = ZmxSession.child(self.allocator, command, self.cwd, .control);
            child.spawn() catch {
                self.allocator.free(session);
                slot.attempted_resize_size = size;
                slot.pending_resize_size = null;
                self.setInputError("terminal PTY resize command could not start");
                return;
            };
            slot.pending_resize_size = null;
            self.resize_child = child;
            self.resize_child_surface = index;
            self.resize_child_size = size;
            self.resize_child_session = session;
            return;
        }
    }

    fn finishResizeControl(self: *Workspace, succeeded: bool, failure_message: []const u8) void {
        const index = self.resize_child_surface orelse max_surfaces;
        const size = self.resize_child_size;
        if (index < self.surfaces.len and size != null and
            std.mem.eql(u8, self.surfaces[index].session_name, self.resize_child_session))
        {
            const slot = &self.surfaces[index];
            if (slot.pending_resize_size) |pending| {
                if (size.?.eql(pending)) slot.pending_resize_size = null;
            }
            if (succeeded) {
                slot.last_resize_size = size;
                slot.attempted_resize_size = null;
            } else {
                slot.attempted_resize_size = size;
                self.setInputError(failure_message);
            }
        } else if (!succeeded) {
            self.setInputError(failure_message);
        }
        self.resize_child = null;
        self.resize_child_surface = null;
        self.resize_child_size = null;
        if (self.resize_child_session.len != 0) self.allocator.free(self.resize_child_session);
        self.resize_child_session = &.{};
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
        if (pollAttachOutput(NativeAttachOutput{
            .workspace = self,
            .index = index,
            .pipe = @ptrCast(stdout.handle),
            .process = child.id,
        }) == .exited) {
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
            // A loop whose session ended is not re-created as a bare shell; it is re-attached
            // only if the daemon's session is still there.
            if (self.daemon_sessions[index]) {
                self.openLaunchedNode(index, session, 0) catch {};
                self.clearRecreateSession(index);
                continue;
            }
            self.attachNode(index, session, false) catch {
                self.recreate_due_ms[index] = now + self.recreate_delay_ms[index];
                self.recreate_delay_ms[index] = @min(self.recreate_delay_ms[index] * 2, 4_000);
                continue;
            };
            self.clearRestoreError(index);
            self.recreate_delay_ms[index] = 100;
        }
    }

    fn resetSessionState(self: *Workspace, index: usize) void {
        self.surfaces[index].resetOutput();
    }

    fn feedTerminalOutput(self: *Workspace, index: usize, bytes: []const u8) void {
        const slot = &self.surfaces[index];
        const surface = slot.surface orelse return;
        const previous = slot.output_result;
        const result = publishTerminalOutput(self.allocator, slot, bytes, NativeTerminalOutput{
            .surface = surface,
            .columns = slot.grid.cols,
            .rows = slot.grid.rows,
        });
        self.routeVtResponses(index);
        self.render_error = result.render_result;
        if (!std.meta.eql(previous, slot.output_result)) slot.output_result.logFailures(index);
    }
};

const AttachOutputPollResult = enum { keep_attached, exited };

fn pollAttachOutput(api: anytype) AttachOutputPollResult {
    var available = api.peek() orelse return .exited;
    var budget: usize = 64 * 1024;
    while (available > 0 and budget > 0) {
        var buffer: [4096]u8 = undefined;
        const amount = @min(@min(available, buffer.len), budget);
        const read = api.read(buffer[0..amount]) orelse return .exited;
        if (read == 0) return .exited;
        api.publish(buffer[0..read]);
        budget -= read;
        available = api.peek() orelse return .exited;
    }
    if (available > 0) return .keep_attached;
    return if (api.exited()) .exited else .keep_attached;
}

const NativeAttachOutput = struct {
    workspace: *Workspace,
    index: usize,
    pipe: c.HANDLE,
    process: c.HANDLE,

    fn peek(self: NativeAttachOutput) ?usize {
        var available: c.DWORD = 0;
        if (c.PeekNamedPipe(self.pipe, null, 0, null, &available, null) == 0) return null;
        return @intCast(available);
    }

    fn read(self: NativeAttachOutput, buffer: []u8) ?usize {
        var count: c.DWORD = 0;
        if (c.ReadFile(self.pipe, buffer.ptr, @intCast(buffer.len), &count, null) == 0) return null;
        return @intCast(count);
    }

    fn publish(self: NativeAttachOutput, bytes: []const u8) void {
        self.workspace.feedTerminalOutput(self.index, bytes);
    }

    fn exited(self: NativeAttachOutput) bool {
        var code: c.DWORD = 0;
        return c.GetExitCodeProcess(self.process, &code) != 0 and code != c.STILL_ACTIVE;
    }
};

const SnapshotError = error{ InvalidGrid, InvalidCell, OutOfMemory };

const AccessibilitySnapshot = struct {
    text: []u8,
    utf16_length: usize,
    caret: usize,
};

fn encodeAccessibilityCell(raw: u32, buffer: *[4]u8) SnapshotError!u3 {
    const codepoint = if (raw == 0) ' ' else raw;
    if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f) or
        codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff))
        return error.InvalidCell;
    return std.unicode.utf8Encode(@intCast(codepoint), buffer) catch error.InvalidCell;
}

fn accessibilitySnapshot(
    allocator: std.mem.Allocator,
    cells: []const c.winghostty_terminal_cell,
    grid_columns: usize,
    grid_rows: usize,
    cursor_x: usize,
    cursor_y: usize,
) SnapshotError!AccessibilitySnapshot {
    if (grid_columns == 0 or grid_rows == 0) return error.InvalidGrid;
    const expected = std.math.mul(usize, grid_columns, grid_rows) catch return error.InvalidGrid;
    if (cells.len != expected) return error.InvalidGrid;
    const x = @min(cursor_x, grid_columns);
    const y = @min(cursor_y, grid_rows - 1);
    var byte_length: usize = grid_rows - 1;
    var utf16_length: usize = 0;
    var caret: usize = 0;
    var encoded: [4]u8 = undefined;
    for (0..grid_rows) |row| {
        if (row != 0) utf16_length = std.math.add(usize, utf16_length, 1) catch return error.InvalidGrid;
        for (0..grid_columns) |column| {
            if (row == y and column == x) caret = utf16_length;
            const codepoint = cells[row * grid_columns + column].codepoint;
            const length = try encodeAccessibilityCell(codepoint, &encoded);
            byte_length = std.math.add(usize, byte_length, length) catch return error.InvalidGrid;
            utf16_length = std.math.add(usize, utf16_length, if (codepoint > 0xffff) 2 else 1) catch return error.InvalidGrid;
        }
        if (row == y and x == grid_columns) caret = utf16_length;
    }
    const text = try allocator.alloc(u8, byte_length);
    errdefer allocator.free(text);
    var offset: usize = 0;
    for (cells, 0..) |cell, index| {
        if (index != 0 and index % grid_columns == 0) {
            text[offset] = '\n';
            offset += 1;
        }
        const length = try encodeAccessibilityCell(cell.codepoint, &encoded);
        @memcpy(text[offset..][0..length], encoded[0..length]);
        offset += length;
    }
    return .{ .text = text, .utf16_length = utf16_length, .caret = caret };
}

const TerminalOutputResult = struct {
    const error_messages = [_][]const u8{
        "Terminal accessibility snapshot failed; accessible text is not current",
        "Terminal cell update failed; accessible text was not updated",
        "Terminal accessibility update failed; accessible text is not current",
        "Terminal redraw failed; displayed text is not confirmed",
        "Terminal VT state failed; rendered content is not confirmed",
        "Terminal glyph snapshot cannot represent these cells; rendered content is not confirmed",
        "Terminal glyph snapshot update failed; rendered content is not confirmed",
        "Terminal glyph snapshot staging failed; rendered content is not confirmed",
    };

    snapshot_error: ?SnapshotError = null,
    glyph_error: ?SnapshotError = null,
    vt_error: ?TerminalVt.Error = null,
    projection_error: ?error{ UnsupportedHostCell, InvalidGrid } = null,
    authoritative_vt: bool = false,
    render_result: c.winghostty_result = c.WINGHOSTTY_OK,
    text_result: ?c.winghostty_result = null,
    redraw_result: c.winghostty_result = c.WINGHOSTTY_OK,

    fn succeeded(self: TerminalOutputResult) bool {
        return self.vt_error == null and self.projection_error == null and
            self.snapshot_error == null and self.glyph_error == null and
            self.render_result == c.WINGHOSTTY_OK and self.text_result == c.WINGHOSTTY_OK and
            self.redraw_result == c.WINGHOSTTY_OK;
    }

    fn message(self: TerminalOutputResult) ?[]const u8 {
        if (self.vt_error != null) return error_messages[4];
        if (self.snapshot_error != null) return error_messages[0];
        if (self.glyph_error != null) return error_messages[7];
        if (self.render_result != c.WINGHOSTTY_OK) return error_messages[if (self.authoritative_vt) 6 else 1];
        if (self.text_result) |result| {
            if (result != c.WINGHOSTTY_OK) return error_messages[2];
        }
        if (self.redraw_result != c.WINGHOSTTY_OK) return error_messages[3];
        if (self.projection_error != null) return error_messages[5];
        return null;
    }

    fn logFailures(self: TerminalOutputResult, index: usize) void {
        if (self.vt_error) |err| std.debug.print("Terminal output pane={d} stage=vt error={s}\n", .{ index, @errorName(err) });
        if (self.projection_error) |err| std.debug.print("Terminal output pane={d} stage=projection error={s}\n", .{ index, @errorName(err) });
        if (self.snapshot_error) |err| std.debug.print("Terminal output pane={d} stage=snapshot error={s}\n", .{ index, @errorName(err) });
        if (self.glyph_error) |err| std.debug.print("Terminal output pane={d} stage=glyphs error={s}\n", .{ index, @errorName(err) });
        if (self.render_result != c.WINGHOSTTY_OK) std.debug.print("Terminal output pane={d} stage=glyphs result={d}\n", .{ index, self.render_result });
        if (self.text_result) |result| {
            if (result != c.WINGHOSTTY_OK) std.debug.print("Terminal output pane={d} stage=accessibility result={d}\n", .{ index, result });
        }
        if (self.redraw_result != c.WINGHOSTTY_OK) std.debug.print("Terminal output pane={d} stage=redraw result={d}\n", .{ index, self.redraw_result });
    }
};

const NativeTerminalOutput = struct {
    surface: *c.winghostty_surface,
    columns: u32,
    rows: u32,

    fn setSnapshot(
        self: NativeTerminalOutput,
        cells: []const c.winghostty_terminal_cell,
        glyphs: []const c.winghostty_terminal_glyph,
        text: []const u8,
    ) c.winghostty_result {
        var snapshot: c.winghostty_terminal_snapshot_v2 = undefined;
        c.winghostty_terminal_snapshot_v2_init(&snapshot);
        snapshot.columns = self.columns;
        snapshot.rows = self.rows;
        snapshot.cells = cells.ptr;
        snapshot.cell_count = cells.len;
        snapshot.glyphs = glyphs.ptr;
        snapshot.glyph_count = glyphs.len;
        snapshot.text = if (text.len == 0) null else text.ptr;
        snapshot.text_length = text.len;
        return c.winghostty_surface_set_terminal_snapshot_v2(self.surface, &snapshot);
    }

    fn setText(self: NativeTerminalOutput, text: []const u8, utf16_length: usize, caret: usize) c.winghostty_result {
        return c.winghostty_surface_notify_accessibility_text(self.surface, text.ptr, text.len, 0, utf16_length, 0, 0, caret);
    }

    fn redraw(self: NativeTerminalOutput) c.winghostty_result {
        return c.winghostty_surface_notify_redraw(self.surface);
    }
};

const NativeGlyphSnapshot = struct {
    cells: ?[]c.winghostty_terminal_cell = null,
    glyphs: []c.winghostty_terminal_glyph,
    text: []u8,

    fn deinit(self: NativeGlyphSnapshot, allocator: std.mem.Allocator) void {
        if (self.cells) |cells| allocator.free(cells);
        allocator.free(self.glyphs);
        allocator.free(self.text);
    }
};

fn appendGlyphCodepoints(
    allocator: std.mem.Allocator,
    text: *std.ArrayList(u8),
    codepoints: []const u32,
) !u16 {
    const start = text.items.len;
    for (codepoints) |codepoint| {
        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f) or
            codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff))
            return error.InvalidCell;
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch
            return error.InvalidCell;
        try text.appendSlice(allocator, encoded[0..length]);
    }
    return std.math.cast(u16, text.items.len - start) orelse error.InvalidCell;
}

fn glyphSnapshotFromCells(
    allocator: std.mem.Allocator,
    cells: []const c.winghostty_terminal_cell,
) !NativeGlyphSnapshot {
    const glyphs = try allocator.alloc(c.winghostty_terminal_glyph, cells.len);
    errdefer allocator.free(glyphs);
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    for (cells, glyphs) |cell, *glyph| {
        const offset = std.math.cast(u32, text.items.len) orelse return error.InvalidCell;
        const length = if (cell.codepoint == 0 or cell.codepoint == ' ')
            0
        else
            try appendGlyphCodepoints(allocator, &text, &.{cell.codepoint});
        glyph.* = .{
            .offset = offset,
            .length = length,
            .width = c.WINGHOSTTY_GLYPH_WIDTH_NARROW,
            .reserved = 0,
        };
    }
    return .{ .glyphs = glyphs, .text = try text.toOwnedSlice(allocator) };
}

fn glyphSnapshotFromVt(
    allocator: std.mem.Allocator,
    snapshot: *const TerminalVt.Snapshot,
    expected_cell_count: usize,
) !NativeGlyphSnapshot {
    if (expected_cell_count != snapshot.cells.len) return error.InvalidGrid;
    const cells = try allocator.alloc(c.winghostty_terminal_cell, expected_cell_count);
    errdefer allocator.free(cells);
    const glyphs = try allocator.alloc(c.winghostty_terminal_glyph, expected_cell_count);
    errdefer allocator.free(glyphs);
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    for (snapshot.cells, cells, glyphs) |cell, *out, *glyph| {
        var fg = cell.foreground orelse snapshot.colors.foreground;
        var bg = cell.background orelse snapshot.colors.background;
        if (cell.style.inverse) std.mem.swap(TerminalVt.c.GhosttyColorRgb, &fg, &bg);
        if (cell.style.invisible) fg = bg;
        const continuation = cell.wide == TerminalVt.c.GHOSTTY_CELL_WIDE_SPACER_TAIL;
        const codepoint: u32 = if (continuation or cell.codepoints.len == 0)
            0
        else
            cell.codepoints[0];
        out.* = .{
            .codepoint = codepoint,
            .foreground = (@as(u32, fg.r) << 16) | (@as(u32, fg.g) << 8) | fg.b,
            .background = (@as(u32, bg.r) << 16) | (@as(u32, bg.g) << 8) | bg.b,
            .flags = c.WINGHOSTTY_TERMINAL_CELL_FOREGROUND_SET |
                c.WINGHOSTTY_TERMINAL_CELL_BACKGROUND_SET,
        };
        const offset = std.math.cast(u32, text.items.len) orelse return error.InvalidCell;
        const length = if (continuation or codepoint == 0 or codepoint == ' ')
            0
        else
            try appendGlyphCodepoints(allocator, &text, cell.codepoints);
        glyph.* = .{
            .offset = offset,
            .length = length,
            .width = switch (cell.wide) {
                TerminalVt.c.GHOSTTY_CELL_WIDE_WIDE => c.WINGHOSTTY_GLYPH_WIDTH_WIDE,
                TerminalVt.c.GHOSTTY_CELL_WIDE_SPACER_TAIL => c.WINGHOSTTY_GLYPH_WIDTH_CONTINUATION,
                else => c.WINGHOSTTY_GLYPH_WIDTH_NARROW,
            },
            .reserved = 0,
        };
    }
    return .{ .cells = cells, .glyphs = glyphs, .text = try text.toOwnedSlice(allocator) };
}

fn publishTerminalOutput(allocator: std.mem.Allocator, slot: *Surface, bytes: []const u8, api: anytype) TerminalOutputResult {
    if (slot.vt) |state| return publishVtOutput(allocator, slot, state, bytes, api);
    feedCells(slot, bytes);
    var result = TerminalOutputResult{};
    const snapshot: ?AccessibilitySnapshot = accessibilitySnapshot(
        allocator,
        slot.cells,
        slot.grid.cols,
        slot.grid.rows,
        slot.terminal_x,
        slot.terminal_y,
    ) catch |err| blk: {
        result.snapshot_error = err;
        break :blk null;
    };
    defer if (snapshot) |value| allocator.free(value.text);
    const glyph_snapshot: ?NativeGlyphSnapshot = glyphSnapshotFromCells(allocator, slot.cells) catch |err| blk: {
        result.glyph_error = switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidCell,
        };
        break :blk null;
    };
    defer if (glyph_snapshot) |value| value.deinit(allocator);
    if (glyph_snapshot) |value| {
        result.render_result = api.setSnapshot(slot.cells, value.glyphs, value.text);
    }
    if (result.render_result == c.WINGHOSTTY_OK) {
        if (snapshot) |value| result.text_result = api.setText(value.text, value.utf16_length, value.caret);
    }
    if (glyph_snapshot != null and result.render_result == c.WINGHOSTTY_OK) {
        result.redraw_result = api.redraw();
    }
    slot.output_result = result;
    if (result.succeeded()) slot.output_events += 1;
    return result;
}

fn publishVtOutput(
    allocator: std.mem.Allocator,
    slot: *Surface,
    state: *TerminalVt.State,
    bytes: []const u8,
    api: anytype,
) TerminalOutputResult {
    var result = TerminalOutputResult{ .authoritative_vt = true };
    state.feed(bytes) catch |err| {
        result.vt_error = err;
    };
    if (state.snapshot_current) {
        const snapshot = &state.snapshot.?;
        if (snapshot.columns != slot.grid.cols or snapshot.rows != slot.grid.rows or slot.cells.len != @as(usize, slot.grid.cols) * slot.grid.rows) {
            result.projection_error = error.InvalidGrid;
        } else {
            const projected: ?NativeGlyphSnapshot = glyphSnapshotFromVt(allocator, snapshot, slot.cells.len) catch |err| blk: {
                switch (err) {
                    error.OutOfMemory => result.glyph_error = error.OutOfMemory,
                    else => result.projection_error = error.UnsupportedHostCell,
                }
                break :blk null;
            };
            defer if (projected) |value| value.deinit(allocator);
            if (projected) |value| {
                const staged_cells = value.cells.?;
                result.render_result = api.setSnapshot(staged_cells, value.glyphs, value.text);
                if (result.render_result == c.WINGHOSTTY_OK) {
                    @memcpy(slot.cells, staged_cells);
                }
            }
        }
        // This is authoritative VT text, not a claim about the host's glyphs.
        // A non-visible caret has no representable host offset.
        if (snapshot.caret) |caret| {
            result.text_result = api.setText(snapshot.text, snapshot.utf16.len, caret);
        } else {
            result.vt_error = error.InvalidSnapshot;
        }
        if (result.projection_error == null and result.glyph_error == null and
            result.vt_error == null)
        {
            result.redraw_result = api.redraw();
        }
    }
    slot.output_result = result;
    if (result.succeeded()) slot.output_events += 1;
    return result;
}

const TerminalOutputProbe = struct {
    text: [cell_count * 4 + rows - 1]u8 = undefined,
    text_length: usize = 0,
    glyphs: [cell_count]c.winghostty_terminal_glyph = undefined,
    glyph_text: [cell_count * 4]u8 = undefined,
    glyph_text_length: usize = 0,
    utf16_length: usize = 0,
    caret: usize = 0,
    calls: [3]enum { snapshot, text, redraw } = undefined,
    call_count: usize = 0,
    render_result: c.winghostty_result = c.WINGHOSTTY_OK,
    text_result: c.winghostty_result = c.WINGHOSTTY_OK,
    redraw_result: c.winghostty_result = c.WINGHOSTTY_OK,

    fn setSnapshot(
        self: *TerminalOutputProbe,
        cells: []const c.winghostty_terminal_cell,
        glyphs: []const c.winghostty_terminal_glyph,
        text: []const u8,
    ) c.winghostty_result {
        std.debug.assert(cells.len == cell_count);
        std.debug.assert(glyphs.len == cells.len);
        @memcpy(self.glyphs[0..glyphs.len], glyphs);
        @memcpy(self.glyph_text[0..text.len], text);
        self.glyph_text_length = text.len;
        self.calls[self.call_count] = .snapshot;
        self.call_count += 1;
        return self.render_result;
    }

    fn setText(self: *TerminalOutputProbe, text: []const u8, utf16_length: usize, caret: usize) c.winghostty_result {
        self.calls[self.call_count] = .text;
        self.call_count += 1;
        @memcpy(self.text[0..text.len], text);
        self.text_length = text.len;
        self.utf16_length = utf16_length;
        self.caret = caret;
        return self.text_result;
    }

    fn redraw(self: *TerminalOutputProbe) c.winghostty_result {
        self.calls[self.call_count] = .redraw;
        self.call_count += 1;
        return self.redraw_result;
    }
};

test "terminal VT vertical split UTF8 multiparameter CSI and SGR" {
    try std.testing.expectEqual(@as(u32, c.WINGHOSTTY_TERMINAL_CELL_FOREGROUND_SET), TerminalVt.HostCell.foreground_set);
    try std.testing.expectEqual(@as(u32, c.WINGHOSTTY_TERMINAL_CELL_BACKGROUND_SET), TerminalVt.HostCell.background_set);
    var slot = Surface{ .cells = try std.testing.allocator.alloc(c.winghostty_terminal_cell, cell_count) };
    defer std.testing.allocator.free(slot.cells);
    defer if (slot.vt) |state| state.destroy();
    clearCells(&slot);
    slot.vt = try TerminalVt.State.create(std.testing.allocator, columns, rows);
    var probe = TerminalOutputProbe{};
    _ = publishTerminalOutput(std.testing.allocator, &slot, "\xc3", &probe);
    probe.call_count = 0;
    _ = publishTerminalOutput(std.testing.allocator, &slot, "\xa9\x1b[2;3H\x1b[38;2;12;34;56mZ", &probe);
    try std.testing.expectEqual(@as(u32, 0xe9), slot.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 'Z'), slot.cells[columns + 2].codepoint);
    try std.testing.expectEqual(@as(u32, 0x0c2238), slot.cells[columns + 2].foreground);
    try std.testing.expect(slot.output_result.succeeded());
    try std.testing.expectEqual(@as(usize, 2), slot.output_events);
    try std.testing.expect(std.mem.startsWith(u8, probe.text[0..probe.text_length], "\xc3\xa9"));
}

test "terminal output publishes real glyph snapshots instead of pseudo-glyph cells" {
    var slot = Surface{ .cells = try std.testing.allocator.alloc(c.winghostty_terminal_cell, cell_count) };
    defer std.testing.allocator.free(slot.cells);
    clearCells(&slot);
    var probe = TerminalOutputProbe{};

    try std.testing.expect(publishTerminalOutput(
        std.testing.allocator,
        &slot,
        "BETA8-TURN-ONE",
        &probe,
    ).succeeded());
    try std.testing.expectEqual(.snapshot, probe.calls[0]);
    try std.testing.expectEqualStrings(
        "BETA8-TURN-ONE",
        probe.glyph_text[0..probe.glyph_text_length],
    );
    try std.testing.expectEqual(@as(u16, 1), probe.glyphs[0].length);
    try std.testing.expectEqual(c.WINGHOSTTY_GLYPH_WIDTH_NARROW, probe.glyphs[0].width);
}

test "terminal glyph snapshot staging releases every partial allocation" {
    const allocator = std.testing.allocator;
    var cells = [_]c.winghostty_terminal_cell{
        .{ .codepoint = 'A', .foreground = 0xffffff, .background = 0, .flags = 0 },
        .{ .codepoint = 0, .foreground = 0xffffff, .background = 0, .flags = 0 },
        .{ .codepoint = 0, .foreground = 0xffffff, .background = 0, .flags = 0 },
    };
    var vt_cells = [_]c.winghostty_terminal_cell{
        .{ .codepoint = 'X', .foreground = 0, .background = 0, .flags = 0 },
        .{ .codepoint = 'Y', .foreground = 0, .background = 0, .flags = 0 },
        .{ .codepoint = 'Z', .foreground = 0, .background = 0, .flags = 0 },
    };
    const state = try TerminalVt.State.create(allocator, 3, 1);
    defer state.destroy();
    try state.feed("A\xe7\x95\x8c");
    const snapshot = &state.snapshot.?;

    const Probe = struct {
        fn legacy(failing: std.mem.Allocator, input: []const c.winghostty_terminal_cell) !void {
            const staged = try glyphSnapshotFromCells(failing, input);
            defer staged.deinit(failing);
            try std.testing.expectEqualStrings("A", staged.text);
        }

        fn vt(
            failing: std.mem.Allocator,
            input: *const TerminalVt.Snapshot,
            output: []c.winghostty_terminal_cell,
        ) !void {
            const staged = try glyphSnapshotFromVt(failing, input, output.len);
            defer staged.deinit(failing);
            try std.testing.expectEqualStrings("A\xe7\x95\x8c", staged.text);
            try std.testing.expectEqual(@as(u32, 'A'), staged.cells.?[0].codepoint);
            try std.testing.expectEqual(@as(u32, 'X'), output[0].codepoint);
        }
    };

    try std.testing.checkAllAllocationFailures(allocator, Probe.legacy, .{&cells});
    try std.testing.checkAllAllocationFailures(allocator, Probe.vt, .{ snapshot, &vt_cells });
}

test "terminal VT explicit opt-out preserves the legacy feed path" {
    var slot = Surface{ .cells = try std.testing.allocator.alloc(c.winghostty_terminal_cell, cell_count) };
    defer std.testing.allocator.free(slot.cells);
    clearCells(&slot);
    var probe = TerminalOutputProbe{};
    try std.testing.expect(!try TerminalVt.parseFlag("0"));
    try std.testing.expect(slot.vt == null);
    try std.testing.expect(publishTerminalOutput(std.testing.allocator, &slot, "\xc3\xa9\x1b[2;3H\x1b[38;2;12;34;56mZ", &probe).succeeded());
    try std.testing.expectEqual(@as(u32, 'Z'), slot.cells[0].codepoint);
    try std.testing.expect(!slot.output_result.authoritative_vt);
}

test "terminal VT snapshot publishes clusters and routes replies to current pane" {
    const allocator = std.testing.allocator;
    var workspace = try minimalWorkspaceForOptionsTest(allocator);
    defer workspace.layout.deinit();
    defer workspace.input_queue.clear();
    const slot = &workspace.surfaces[5];
    slot.cells = try allocator.alloc(c.winghostty_terminal_cell, cell_count);
    defer allocator.free(slot.cells);
    slot.vt = try TerminalVt.State.create(allocator, columns, rows);
    defer slot.vt.?.destroy();
    clearCells(slot);
    var probe = TerminalOutputProbe{};
    const result = publishTerminalOutput(allocator, slot, "A\xe7\x95\x8ce\xcc\x81\xf0\x9f\x98\x80\x1b[6n", &probe);
    try std.testing.expect(result.projection_error == null);
    try std.testing.expect(result.vt_error == null);
    try std.testing.expect(result.succeeded());
    try std.testing.expectEqual(@as(usize, 1), slot.output_events);
    try std.testing.expectEqual(@as(usize, 3), probe.call_count);
    try std.testing.expectEqual(.snapshot, probe.calls[0]);
    try std.testing.expectEqual(.text, probe.calls[1]);
    try std.testing.expectEqualStrings(
        "A\xe7\x95\x8ce\xcc\x81\xf0\x9f\x98\x80",
        probe.glyph_text[0..probe.glyph_text_length],
    );
    try std.testing.expectEqual(c.WINGHOSTTY_GLYPH_WIDTH_NARROW, probe.glyphs[0].width);
    try std.testing.expectEqual(c.WINGHOSTTY_GLYPH_WIDTH_WIDE, probe.glyphs[1].width);
    try std.testing.expectEqual(c.WINGHOSTTY_GLYPH_WIDTH_CONTINUATION, probe.glyphs[2].width);
    try std.testing.expectEqual(@as(u16, 3), probe.glyphs[3].length);
    try std.testing.expect(std.mem.startsWith(u8, probe.text[0..probe.text_length], "A\xe7\x95\x8ce\xcc\x81\xf0\x9f\x98\x80"));
    try std.testing.expectEqual(@as(usize, 6), probe.caret);
    workspace.routeVtResponses(5);
    try std.testing.expectEqual(@as(usize, 0), slot.vt.?.responses().len);
    workspace.routeVtResponses(5);
    try std.testing.expectEqual(@as(usize, 1), workspace.input_queue.count);
    const item = workspace.input_queue.dequeue().?;
    defer allocator.free(item.bytes);
    try std.testing.expectEqual(@as(usize, 5), item.surface);
    try std.testing.expectEqualStrings("\x1b[1;7R", item.bytes);
    workspace.input_error_message = "terminal input write failed";
    try std.testing.expectEqualStrings("terminal input write failed", workspace.inputStatus("").?);
    workspace.input_error_message = "";
    probe.call_count = 0;
    const recovered = publishTerminalOutput(allocator, slot, "\x1b[2J\x1b[Hplain", &probe);
    try std.testing.expect(recovered.succeeded());
}

test "terminal VT queue rejection retains bounded responses and never replays" {
    const allocator = std.testing.allocator;
    var workspace = try minimalWorkspaceForOptionsTest(allocator);
    defer workspace.layout.deinit();
    defer workspace.input_queue.clear();
    const state = try TerminalVt.State.create(allocator, columns, rows);
    defer state.destroy();
    workspace.surfaces[3].vt = state;
    for (0..input_queue_capacity) |_| try workspace.input_queue.enqueue(1, try allocator.dupe(u8, "x"));
    try state.feed("\x1b[6n");
    workspace.routeVtResponses(3);
    try std.testing.expect(state.response_delivery_failed);
    try std.testing.expectEqualStrings("\x1b[1;1R", state.responses());
    try std.testing.expectEqual(error.ResponseDeliveryFailed, workspace.surfaces[3].output_result.vt_error.?);
    try std.testing.expectEqualStrings("terminal input queue overflow", workspace.inputStatus("").?);
    workspace.input_queue.clear();
    workspace.routeVtResponses(3);
    try std.testing.expectEqual(@as(usize, 0), workspace.input_queue.count);
    try std.testing.expectError(error.ResponseDeliveryFailed, state.feed("text remains authoritative"));
    try std.testing.expect(state.snapshot_current);
}

test "terminal VT swap routes stable owner and cancellation removes only that pane" {
    const allocator = std.testing.allocator;
    var workspace = try minimalWorkspaceForOptionsTest(allocator);
    defer workspace.layout.deinit();
    defer workspace.input_queue.clear();
    const state = try TerminalVt.State.create(allocator, columns, rows);
    defer state.destroy();
    workspace.surfaces[2].vt = state;
    workspace.surfaces[2].surface = @ptrFromInt(1);
    try state.feed("AB\x1b[6n");
    moveReplacementSurface(&workspace.surfaces, 0, 2);
    try std.testing.expect(workspace.surfaces[0].vt.? == state);
    try std.testing.expect(workspace.surfaces[2].vt == null);
    workspace.routeVtResponses(0);
    try workspace.input_queue.enqueue(1, try allocator.dupe(u8, "other pane"));
    try std.testing.expectEqual(@as(usize, 0), workspace.input_queue.items[0].surface);
    try std.testing.expectEqualStrings("\x1b[1;3R", workspace.input_queue.items[0].bytes);
    workspace.cancelSurfaceInput(0);
    try std.testing.expectEqual(@as(usize, 1), workspace.input_queue.count);
    const item = workspace.input_queue.dequeue().?;
    defer allocator.free(item.bytes);
    try std.testing.expectEqual(@as(usize, 1), item.surface);
    try std.testing.expectEqualStrings("other pane", item.bytes);
    try std.testing.expectEqual(@as(usize, 0), state.responses().len);
    workspace.input_stop = true;
    try state.feed("\x1b[6n");
    workspace.routeVtResponses(0);
    try std.testing.expect(state.response_delivery_failed);
    try std.testing.expectEqualStrings("\x1b[1;3R", state.responses());
}

test "terminal VT host publication errors remain explicit with authoritative text" {
    const allocator = std.testing.allocator;
    var slot = Surface{ .cells = try allocator.alloc(c.winghostty_terminal_cell, cell_count) };
    defer allocator.free(slot.cells);
    slot.vt = try TerminalVt.State.create(allocator, columns, rows);
    defer slot.vt.?.destroy();
    clearCells(&slot);
    var probe = TerminalOutputProbe{ .render_result = c.WINGHOSTTY_OUT_OF_MEMORY };
    const result = publishTerminalOutput(allocator, &slot, "A", &probe);
    try std.testing.expect(!result.succeeded());
    try std.testing.expectEqual(c.WINGHOSTTY_OK, result.text_result.?);
    try std.testing.expectEqualStrings(TerminalOutputResult.error_messages[6], result.message().?);
    try std.testing.expectEqual(@as(usize, 0), slot.output_events);
    probe = .{ .text_result = c.WINGHOSTTY_OUT_OF_MEMORY };
    try std.testing.expect(!publishTerminalOutput(allocator, &slot, "B", &probe).succeeded());
    probe = .{ .redraw_result = c.WINGHOSTTY_OUT_OF_MEMORY };
    try std.testing.expect(!publishTerminalOutput(allocator, &slot, "C", &probe).succeeded());
}

test "terminal accessibility feed publishes rendered cells instead of overwritten VT bytes" {
    var slot = Surface{ .cells = try std.testing.allocator.alloc(c.winghostty_terminal_cell, cell_count) };
    defer std.testing.allocator.free(slot.cells);
    clearCells(&slot);
    var probe = TerminalOutputProbe{};
    try std.testing.expect(publishTerminalOutput(std.testing.allocator, &slot, "AB\rZ\x1b[K", &probe).succeeded());
    try std.testing.expectEqual(@as(u32, 'Z'), slot.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 0), slot.cells[1].codepoint);
    try std.testing.expectEqual(@as(usize, cell_count + rows - 1), probe.text_length);
    for (probe.text[0..probe.text_length], 0..) |byte, index| {
        const expected: u8 = if (index == 0) 'Z' else if (index % (columns + 1) == columns) '\n' else ' ';
        try std.testing.expectEqual(expected, byte);
    }
    try std.testing.expectEqual(probe.text_length, probe.utf16_length);
    try std.testing.expectEqual(@as(usize, 1), probe.caret);
    try std.testing.expectEqual(@as(usize, 3), probe.call_count);
    try std.testing.expectEqual(.snapshot, probe.calls[0]);
    try std.testing.expectEqual(.text, probe.calls[1]);
    try std.testing.expectEqual(.redraw, probe.calls[2]);
}

test "terminal accessibility feed preserves parser results across every chunk boundary" {
    const allocator = std.testing.allocator;
    const input = "old\x1b[2JAB\rZ\x1b[K\tQ\x08R\nlast";
    var whole = Surface{ .cells = try allocator.alloc(c.winghostty_terminal_cell, cell_count) };
    defer allocator.free(whole.cells);
    whole.resetOutput();
    var expected = TerminalOutputProbe{};
    try std.testing.expect(publishTerminalOutput(allocator, &whole, input, &expected).succeeded());
    var split = Surface{ .cells = try allocator.alloc(c.winghostty_terminal_cell, cell_count) };
    defer allocator.free(split.cells);
    split.resetOutput();
    feedCells(&split, input);
    for (whole.cells, split.cells) |left, right| try std.testing.expect(std.meta.eql(left, right));
    try std.testing.expectEqual(whole.terminal_x, split.terminal_x);
    try std.testing.expectEqual(whole.terminal_y, split.terminal_y);
    try std.testing.expectEqual(whole.parser, split.parser);
    for (0..input.len + 1) |boundary| {
        split.resetOutput();
        var actual = TerminalOutputProbe{};
        try std.testing.expect(publishTerminalOutput(allocator, &split, input[0..boundary], &actual).succeeded());
        actual = .{};
        try std.testing.expect(publishTerminalOutput(allocator, &split, input[boundary..], &actual).succeeded());
        try std.testing.expectEqualSlices(u8, expected.text[0..expected.text_length], actual.text[0..actual.text_length]);
        try std.testing.expectEqual(expected.caret, actual.caret);
        try std.testing.expectEqual(whole.terminal_x, split.terminal_x);
        try std.testing.expectEqual(whole.terminal_y, split.terminal_y);
        try std.testing.expectEqual(whole.parser, split.parser);
        for (whole.cells, split.cells) |left, right| try std.testing.expect(std.meta.eql(left, right));
    }
}

test "terminal accessibility feed resets and discards rows rather than retaining raw history" {
    const allocator = std.testing.allocator;
    var slot = Surface{ .cells = try allocator.alloc(c.winghostty_terminal_cell, cell_count) };
    defer allocator.free(slot.cells);
    slot.resetOutput();
    var probe = TerminalOutputProbe{};
    try std.testing.expect(publishTerminalOutput(allocator, &slot, "old\n", &probe).succeeded());
    for (0..rows) |_| {
        probe = .{};
        try std.testing.expect(publishTerminalOutput(allocator, &slot, "new\n", &probe).succeeded());
    }
    try std.testing.expectEqualStrings("new", probe.text[0..3]);
    try std.testing.expect(std.mem.indexOf(u8, probe.text[0..probe.text_length], "old") == null);
    try std.testing.expectEqual(@as(usize, (rows - 1) * (columns + 1)), probe.caret);
    slot.resetOutput();
    probe = .{};
    try std.testing.expect(publishTerminalOutput(allocator, &slot, "", &probe).succeeded());
    try std.testing.expectEqual(@as(usize, cell_count + rows - 1), probe.text_length);
    try std.testing.expectEqual(@as(usize, rows - 1), std.mem.count(u8, probe.text[0..probe.text_length], "\n"));
    for (probe.text[0..probe.text_length]) |byte| try std.testing.expect(byte == ' ' or byte == '\n');
    try std.testing.expectEqual(@as(usize, 0), probe.caret);
    try std.testing.expectEqual(@as(usize, 1), slot.output_events);
}

test "terminal accessibility snapshot counts Unicode scalars at the cell representation boundary" {
    const allocator = std.testing.allocator;
    var cells = [_]c.winghostty_terminal_cell{std.mem.zeroes(c.winghostty_terminal_cell)} ** 6;
    const codepoints = [_]u32{ 'A', 0x1f525, 'B', 'e', 0x301, 0 };
    for (&cells, codepoints) |*cell, codepoint| cell.codepoint = codepoint;
    const original = cells;
    // These are serializer inputs; the unchanged ASCII parser does not produce this Unicode grid.
    const boundaries = [_]usize{ 0, 1, 3, 4, 5, 6, 7, 8 };
    for (boundaries, 0..) |expected, index| {
        const snapshot = try accessibilitySnapshot(allocator, &cells, 3, 2, index % 4, index / 4);
        defer allocator.free(snapshot.text);
        try std.testing.expectEqualStrings("A\u{1f525}B\ne\u{301} ", snapshot.text);
        try std.testing.expectEqual(@as(usize, 11), snapshot.text.len);
        try std.testing.expectEqual(@as(usize, 8), snapshot.utf16_length);
        try std.testing.expectEqual(expected, snapshot.caret);
    }
    const owned = try accessibilitySnapshot(allocator, &cells, 3, 2, std.math.maxInt(usize), std.math.maxInt(usize));
    defer allocator.free(owned.text);
    for (cells, original) |left, right| try std.testing.expect(std.meta.eql(left, right));
    cells[0].codepoint = 'Z';
    try std.testing.expectEqualStrings("A\u{1f525}B\ne\u{301} ", owned.text);
    try std.testing.expectEqual(@as(usize, 8), owned.caret);

    var slot = Surface{ .cells = try allocator.alloc(c.winghostty_terminal_cell, cell_count) };
    defer allocator.free(slot.cells);
    slot.resetOutput();
    for (slot.cells[0..3], codepoints[0..3]) |*cell, codepoint| cell.codepoint = codepoint;
    slot.terminal_x = 2;
    var probe = TerminalOutputProbe{};
    try std.testing.expect(publishTerminalOutput(allocator, &slot, "", &probe).succeeded());
    try std.testing.expectEqualStrings("A\u{1f525}B", probe.text[0..6]);
    try std.testing.expectEqual(@as(usize, cell_count + rows - 1 + 3), probe.text_length);
    try std.testing.expectEqual(@as(usize, cell_count + rows), probe.utf16_length);
    try std.testing.expectEqual(@as(usize, 3), probe.caret);
}

test "terminal accessibility snapshot validates shape scalars and allocation" {
    const allocator = std.testing.allocator;
    var cells = [_]c.winghostty_terminal_cell{std.mem.zeroes(c.winghostty_terminal_cell)} ** 2;
    try std.testing.expectError(error.InvalidGrid, accessibilitySnapshot(allocator, &cells, 0, 1, 0, 0));
    try std.testing.expectError(error.InvalidGrid, accessibilitySnapshot(allocator, &cells, 2, 0, 0, 0));
    try std.testing.expectError(error.InvalidGrid, accessibilitySnapshot(allocator, &cells, 2, 2, 0, 0));
    try std.testing.expectError(error.InvalidGrid, accessibilitySnapshot(allocator, &cells, std.math.maxInt(usize), 2, 0, 0));
    for ([_]u32{ '\n', '\r', 0x1b, 0x7f, 0x85, 0xd800, 0xdfff, 0x110000, std.math.maxInt(u32) }) |invalid| {
        cells[0].codepoint = invalid;
        try std.testing.expectError(error.InvalidCell, accessibilitySnapshot(allocator, &cells, 2, 1, 0, 0));
    }
    const Probe = struct {
        fn run(alloc: std.mem.Allocator) !void {
            const input = [_]c.winghostty_terminal_cell{std.mem.zeroes(c.winghostty_terminal_cell)} ** 2;
            const snapshot = try accessibilitySnapshot(alloc, &input, 2, 1, 2, 0);
            defer alloc.free(snapshot.text);
            try std.testing.expectEqualStrings("  ", snapshot.text);
            try std.testing.expectEqual(@as(usize, 2), snapshot.caret);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Probe.run, .{});
}

test "terminal accessibility feed reports staging and outbound failures without false publication" {
    const allocator = std.testing.allocator;
    var slot = Surface{ .cells = try allocator.alloc(c.winghostty_terminal_cell, cell_count) };
    defer allocator.free(slot.cells);
    slot.resetOutput();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var probe = TerminalOutputProbe{};
    const failed_snapshot = publishTerminalOutput(failing.allocator(), &slot, "A", &probe);
    try std.testing.expectEqual(error.OutOfMemory, failed_snapshot.snapshot_error.?);
    try std.testing.expectEqual(error.OutOfMemory, failed_snapshot.glyph_error.?);
    try std.testing.expect(failed_snapshot.message() != null);
    try std.testing.expect(!failed_snapshot.succeeded());
    try std.testing.expectEqual(@as(usize, 0), slot.output_events);
    try std.testing.expectEqual(@as(usize, 0), probe.text_length);
    try std.testing.expectEqual(@as(usize, 0), probe.call_count);
    try std.testing.expectEqual(@as(u32, 'A'), slot.cells[0].codepoint);

    for (0..3) |stage| {
        probe = .{};
        switch (stage) {
            0 => probe.render_result = c.WINGHOSTTY_RENDERER_ERROR,
            1 => probe.text_result = c.WINGHOSTTY_OUT_OF_MEMORY,
            2 => probe.redraw_result = c.WINGHOSTTY_SURFACE_INVALIDATED,
            else => unreachable,
        }
        const result = publishTerminalOutput(allocator, &slot, "\rB", &probe);
        try std.testing.expect(result.message() != null);
        try std.testing.expect(!result.succeeded());
        try std.testing.expectEqual(@as(usize, 0), slot.output_events);
        try std.testing.expectEqual(if (stage == 0) @as(usize, 1) else 3, probe.call_count);
        try std.testing.expectEqual(.snapshot, probe.calls[0]);
        if (stage == 0) {
            try std.testing.expectEqual(@as(usize, 0), probe.text_length);
            try std.testing.expectEqual(@as(?c.winghostty_result, null), result.text_result);
        } else {
            try std.testing.expectEqual(.redraw, probe.calls[probe.call_count - 1]);
            try std.testing.expectEqual(@as(usize, cell_count + rows - 1), probe.text_length);
            try std.testing.expectEqual(@as(u8, 'B'), probe.text[0]);
        }
    }
    probe = .{};
    try std.testing.expect(publishTerminalOutput(allocator, &slot, "\rC", &probe).succeeded());
    try std.testing.expectEqual(@as(usize, 1), slot.output_events);
    try std.testing.expect(slot.output_result.message() == null);
}

test "terminal accessibility feed status preserves input errors and other pane failures" {
    const allocator = std.testing.allocator;
    var workspace = try minimalWorkspaceForOptionsTest(allocator);
    defer workspace.layout.deinit();
    for (workspace.surfaces[0..2]) |*slot| {
        slot.cells = try allocator.alloc(c.winghostty_terminal_cell, cell_count);
        slot.resetOutput();
    }
    defer for (workspace.surfaces[0..2]) |*slot| allocator.free(slot.cells);
    var probe = TerminalOutputProbe{ .text_result = c.WINGHOSTTY_OUT_OF_MEMORY };
    const failed = publishTerminalOutput(allocator, &workspace.surfaces[0], "A", &probe);
    try std.testing.expectEqualStrings(failed.message().?, workspace.inputStatus("").?);
    probe = .{};
    try std.testing.expect(publishTerminalOutput(allocator, &workspace.surfaces[1], "B", &probe).succeeded());
    try std.testing.expectEqualStrings(failed.message().?, workspace.inputStatus(failed.message().?).?);
    workspace.input_error_message = "terminal input write failed";
    try std.testing.expectEqualStrings(workspace.input_error_message, workspace.inputStatus(failed.message().?).?);
    workspace.input_error_message = "";
    workspace.resetSessionState(0);
    try std.testing.expectEqualStrings("Terminal output error cleared", workspace.inputStatus(failed.message().?).?);
    try std.testing.expect(!workspace.fatal_error);
}

test "terminal accessibility feed recovery replaces only its own previous status once" {
    const allocator = std.testing.allocator;
    var workspace = try minimalWorkspaceForOptionsTest(allocator);
    defer workspace.layout.deinit();
    const slot = &workspace.surfaces[0];
    slot.cells = try allocator.alloc(c.winghostty_terminal_cell, cell_count);
    defer allocator.free(slot.cells);
    const failures = [_]TerminalOutputResult{
        .{ .snapshot_error = error.OutOfMemory },
        .{ .render_result = c.WINGHOSTTY_RENDERER_ERROR },
        .{ .text_result = c.WINGHOSTTY_OUT_OF_MEMORY },
        .{ .redraw_result = c.WINGHOSTTY_SURFACE_INVALIDATED },
    };
    for (failures) |failure| {
        slot.resetOutput();
        slot.output_result = failure;
        var displayed = workspace.inputStatus("User action complete").?;
        try std.testing.expectEqualStrings(failure.message().?, displayed);
        var probe = TerminalOutputProbe{};
        try std.testing.expect(publishTerminalOutput(allocator, slot, "A", &probe).succeeded());
        try std.testing.expect(workspace.inputStatus("User action complete") == null);
        const unrelated = try std.fmt.allocPrint(allocator, "Note: {s}", .{displayed});
        defer allocator.free(unrelated);
        try std.testing.expect(workspace.inputStatus(unrelated) == null);
        displayed = workspace.inputStatus(displayed).?;
        try std.testing.expectEqualStrings("Terminal output error cleared", displayed);
        try std.testing.expect(workspace.inputStatus(displayed) == null);
    }

    const previous_error = failures[0].message().?;
    workspace.surfaces[1].output_result = failures[1];
    try std.testing.expectEqualStrings(failures[1].message().?, workspace.inputStatus(previous_error).?);
    workspace.input_error_message = "terminal input write failed";
    const input_status = workspace.inputStatus(previous_error).?;
    try std.testing.expectEqualStrings(workspace.input_error_message, input_status);
    workspace.resetSessionState(1);
    try std.testing.expectEqualStrings(input_status, workspace.inputStatus(previous_error).?);
    workspace.input_error_message = "";
    try std.testing.expect(workspace.inputStatus(input_status) == null);

    slot.output_result = failures[0];
    const before_reset = workspace.inputStatus("").?;
    workspace.resetSessionState(0);
    try std.testing.expectEqual(@as(usize, 0), slot.output_events);
    try std.testing.expectEqualStrings("Terminal output error cleared", workspace.inputStatus(before_reset).?);
    try std.testing.expect(workspace.inputStatus("Terminal output error cleared") == null);
}

fn writeInputBounded(handle: c.HANDLE, bytes: []const u8) !usize {
    return writeInputChunks(bytes, NativeInputWriter{ .handle = handle });
}

fn writeInputChunks(bytes: []const u8, writer: anytype) !usize {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const amount = @min(bytes.len - offset, 16 * 1024);
        const written = try writer.write(bytes[offset..][0..amount]);
        if (written == 0 or written > amount) return error.WriteFailed;
        offset += written;
    }
    return offset;
}

const NativeInputWriter = struct {
    handle: c.HANDLE,

    fn write(self: NativeInputWriter, bytes: []const u8) !usize {
        var overlapped = std.mem.zeroes(c.OVERLAPPED);
        overlapped.hEvent = c.CreateEventW(null, 1, 0, null);
        if (overlapped.hEvent == null) return error.WriteFailed;
        defer _ = c.CloseHandle(overlapped.hEvent);
        var written: c.DWORD = 0;
        if (c.WriteFile(self.handle, bytes.ptr, @intCast(bytes.len), &written, &overlapped) == 0) {
            if (c.GetLastError() != c.ERROR_IO_PENDING) return error.WriteFailed;
            const wait_result = c.WaitForSingleObject(overlapped.hEvent, input_write_timeout_ms);
            if (wait_result == c.WAIT_TIMEOUT) {
                _ = c.CancelIoEx(self.handle, &overlapped);
                waitForCancelledWrite(self.handle, &overlapped, &written);
                return error.WriteTimeout;
            }
            if (wait_result != c.WAIT_OBJECT_0 or
                c.GetOverlappedResult(self.handle, &overlapped, &written, 0) == 0)
            {
                return error.WriteFailed;
            }
        }
        return written;
    }
};

test "terminal VT queued replies use production partial-write loop without replay after cancellation" {
    const Writer = struct {
        received: [64]u8 = undefined,
        length: usize = 0,
        calls: usize = 0,
        cancel_at: ?usize = null,

        fn write(self: *@This(), bytes: []const u8) !usize {
            self.calls += 1;
            if (self.cancel_at) |limit| if (self.length >= limit) return error.WriteFailed;
            const amount = @min(bytes.len, 2);
            @memcpy(self.received[self.length..][0..amount], bytes[0..amount]);
            self.length += amount;
            return amount;
        }
    };
    const allocator = std.testing.allocator;
    var workspace = try minimalWorkspaceForOptionsTest(allocator);
    defer workspace.layout.deinit();
    defer workspace.input_queue.clear();
    const state = try TerminalVt.State.create(allocator, columns, rows);
    defer state.destroy();
    workspace.surfaces[4].vt = state;
    try state.feed("\x1b[6n\x1b[6n");
    workspace.routeVtResponses(4);
    const item = workspace.input_queue.dequeue().?;
    defer allocator.free(item.bytes);
    var writer = Writer{};
    try std.testing.expectEqual(item.bytes.len, try writeInputChunks(item.bytes, &writer));
    try std.testing.expectEqualStrings(item.bytes, writer.received[0..writer.length]);
    try std.testing.expect(writer.calls > 1);
    var cancelled = Writer{ .cancel_at = 2 };
    try std.testing.expectError(error.WriteFailed, writeInputChunks(item.bytes, &cancelled));
    try std.testing.expectEqual(@as(usize, 2), cancelled.length);
    try std.testing.expectEqual(@as(usize, 2), cancelled.calls);
    workspace.routeVtResponses(4);
    try std.testing.expectEqual(@as(usize, 0), workspace.input_queue.count);
}

test "terminal VT production write loop enforces chunks and zero-progress failure" {
    const Writer = struct {
        expected: []const u8,
        offset: usize = 0,
        calls: usize = 0,
        zero: bool = false,

        fn write(self: *@This(), bytes: []const u8) !usize {
            self.calls += 1;
            try std.testing.expect(bytes.len <= 16 * 1024);
            try std.testing.expectEqualSlices(u8, self.expected[self.offset..][0..bytes.len], bytes);
            if (self.zero) return 0;
            self.offset += bytes.len;
            return bytes.len;
        }
    };
    const state = try TerminalVt.State.create(std.testing.allocator, columns, rows);
    defer state.destroy();
    try state.feed("\x1b[6n" ** 8000);
    var writer = Writer{ .expected = state.responses() };
    try std.testing.expectEqual(state.responses().len, try writeInputChunks(state.responses(), &writer));
    try std.testing.expectEqual(@as(usize, 3), writer.calls);
    var zero = Writer{ .expected = state.responses(), .zero = true };
    try std.testing.expectError(error.WriteFailed, writeInputChunks(state.responses(), &zero));
    try std.testing.expectEqual(@as(usize, 1), zero.calls);
    try std.testing.expectEqual(@as(usize, 0), zero.offset);
    var empty = Writer{ .expected = &.{} };
    try std.testing.expectEqual(@as(usize, 0), try writeInputChunks("", &empty));
    try std.testing.expectEqual(@as(usize, 0), empty.calls);
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
    return WorkspaceLayout.projectSuffix(project);
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
    redrawWith(NativeRedrawApi, user_data, surface);
}

const NativeRedrawApi = struct {
    const makeCurrent = c.winghostty_surface_make_current;
    const render = c.winghostty_surface_render;
    const clearCurrent = c.winghostty_surface_clear_current;

    fn reportFailure(index: usize, failure: RedrawFailure) void {
        std.log.warn("Terminal redraw failed: slot={d} stage={s} result={d} cleanup_result={d}", .{
            index, @tagName(failure.stage), failure.result, failure.cleanup_result,
        });
    }
};

const RedrawFailure = struct {
    stage: enum { make_current, render, clear_current },
    result: c.winghostty_result,
    cleanup_result: c.winghostty_result = c.WINGHOSTTY_OK,
};

fn redrawWith(comptime Api: type, user_data: ?*anyopaque, surface: *c.winghostty_surface) void {
    const workspace = workspaceFromUserData(user_data) orelse return;
    const slot = callbackSlot(workspace, surface) orelse return;
    const index = surfaceIndex(workspace, surface) orelse return;
    const failure = renderWith(Api, surface);
    const still_live = callbackSlot(workspace, surface) == slot;
    if (failure) |value| {
        if (still_live) {
            if (slot.last_redraw_failure) |previous| {
                if (previous.surface == surface and std.meta.eql(previous.failure, value)) return;
            }
            slot.last_redraw_failure = .{ .surface = surface, .failure = value };
        }
        Api.reportFailure(index, value);
    } else if (still_live) {
        slot.last_redraw_failure = null;
    }
}

fn renderWith(comptime Api: type, surface: *c.winghostty_surface) ?RedrawFailure {
    const binding = Api.makeCurrent(surface);
    if (binding != c.WINGHOSTTY_OK) return .{ .stage = .make_current, .result = binding };

    // Winghostty f5abc059 render already swaps; a separate present would swap again.
    const rendered = Api.render(surface);
    const cleared = Api.clearCurrent(surface);
    if (rendered != c.WINGHOSTTY_OK) return .{
        .stage = .render,
        .result = rendered,
        .cleanup_result = cleared,
    };
    if (cleared != c.WINGHOSTTY_OK) return .{ .stage = .clear_current, .result = cleared };
    return null;
}

const RedrawTestApi = struct {
    const Operation = enum { make_current, render, present, clear_current };
    var calls: [4]Operation = undefined;
    var call_count: usize = 0;
    var swap_requests: usize = 0;
    var target: *c.winghostty_surface = undefined;
    var bound: ?*c.winghostty_surface = null;
    var binding_result: c.winghostty_result = c.WINGHOSTTY_OK;
    var render_result: c.winghostty_result = c.WINGHOSTTY_OK;
    var clear_result: c.winghostty_result = c.WINGHOSTTY_OK;
    var reports: usize = 0;
    var reported_index: usize = 0;
    var reported_failure: ?RedrawFailure = null;
    var invalidate_on_render: ?*Surface = null;
    var replacement_on_render: ?*c.winghostty_surface = null;

    fn reset(surface: *c.winghostty_surface) void {
        call_count = 0;
        swap_requests = 0;
        target = surface;
        bound = null;
        binding_result = c.WINGHOSTTY_OK;
        render_result = c.WINGHOSTTY_OK;
        clear_result = c.WINGHOSTTY_OK;
        reports = 0;
        reported_index = 0;
        reported_failure = null;
        invalidate_on_render = null;
        replacement_on_render = null;
    }

    fn record(operation: Operation, surface: *c.winghostty_surface) void {
        std.debug.assert(surface == target);
        std.debug.assert(call_count < calls.len);
        calls[call_count] = operation;
        call_count += 1;
    }

    fn makeCurrent(surface: *c.winghostty_surface) c.winghostty_result {
        record(.make_current, surface);
        if (binding_result == c.WINGHOSTTY_OK) bound = surface;
        return binding_result;
    }

    fn render(surface: *c.winghostty_surface) c.winghostty_result {
        record(.render, surface);
        std.debug.assert(bound == surface);
        if (invalidate_on_render) |slot| {
            if (replacement_on_render) |replacement| {
                slot.surface = replacement;
            } else {
                slot.destroying = true;
            }
        }
        // The exact pinned provider's render already calls SwapBuffers.
        if (render_result == c.WINGHOSTTY_OK or render_result == c.WINGHOSTTY_PRESENT_ERROR) swap_requests += 1;
        return render_result;
    }

    fn present(surface: *c.winghostty_surface) c.winghostty_result {
        record(.present, surface);
        swap_requests += 1;
        return c.WINGHOSTTY_OK;
    }

    fn clearCurrent(surface: *c.winghostty_surface) c.winghostty_result {
        record(.clear_current, surface);
        std.debug.assert(bound == surface);
        if (clear_result == c.WINGHOSTTY_OK) bound = null;
        return clear_result;
    }

    fn reportFailure(index: usize, failure: RedrawFailure) void {
        reports += 1;
        reported_index = index;
        reported_failure = failure;
    }
};

test "terminal redraw requests exactly one presentation" {
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    const surface: *c.winghostty_surface = @ptrFromInt(0x1000);
    workspace.surfaces[0].surface = surface;
    RedrawTestApi.reset(surface);

    redrawWith(RedrawTestApi, @ptrCast(&workspace), surface);

    try std.testing.expectEqual(@as(usize, 1), RedrawTestApi.swap_requests);
    try std.testing.expectEqualSlices(RedrawTestApi.Operation, &.{
        .make_current, .render, .clear_current,
    }, RedrawTestApi.calls[0..RedrawTestApi.call_count]);
    try std.testing.expectEqual(@as(usize, 0), RedrawTestApi.reports);
    try std.testing.expect(workspace.surfaces[0].last_redraw_failure == null);
    try std.testing.expect(RedrawTestApi.bound == null);
}

test "terminal redraw retains operation and cleanup failure matrix" {
    const Case = struct {
        binding: c.winghostty_result = c.WINGHOSTTY_OK,
        render: c.winghostty_result = c.WINGHOSTTY_OK,
        clear: c.winghostty_result = c.WINGHOSTTY_OK,
        swaps: usize = 0,
        failure: RedrawFailure,
    };
    const cases = [_]Case{
        .{
            .binding = c.WINGHOSTTY_CONTEXT_ERROR,
            .failure = .{ .stage = .make_current, .result = c.WINGHOSTTY_CONTEXT_ERROR },
        },
        .{
            .binding = c.WINGHOSTTY_WRONG_THREAD,
            .failure = .{ .stage = .make_current, .result = c.WINGHOSTTY_WRONG_THREAD },
        },
        .{
            .render = c.WINGHOSTTY_RENDERER_ERROR,
            .failure = .{ .stage = .render, .result = c.WINGHOSTTY_RENDERER_ERROR },
        },
        .{
            .render = c.WINGHOSTTY_PRESENT_ERROR,
            .swaps = 1,
            .failure = .{ .stage = .render, .result = c.WINGHOSTTY_PRESENT_ERROR },
        },
        .{
            .clear = c.WINGHOSTTY_CONTEXT_ERROR,
            .swaps = 1,
            .failure = .{ .stage = .clear_current, .result = c.WINGHOSTTY_CONTEXT_ERROR },
        },
        .{
            .render = c.WINGHOSTTY_RENDERER_ERROR,
            .clear = c.WINGHOSTTY_WRONG_THREAD,
            .failure = .{
                .stage = .render,
                .result = c.WINGHOSTTY_RENDERER_ERROR,
                .cleanup_result = c.WINGHOSTTY_WRONG_THREAD,
            },
        },
        .{
            .render = c.WINGHOSTTY_SURFACE_INVALIDATED,
            .clear = c.WINGHOSTTY_SURFACE_INVALIDATED,
            .failure = .{
                .stage = .render,
                .result = c.WINGHOSTTY_SURFACE_INVALIDATED,
                .cleanup_result = c.WINGHOSTTY_SURFACE_INVALIDATED,
            },
        },
        .{
            .render = c.WINGHOSTTY_SHUTTING_DOWN,
            .failure = .{ .stage = .render, .result = c.WINGHOSTTY_SHUTTING_DOWN },
        },
    };
    for (cases) |case| {
        var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
        defer workspace.layout.deinit();
        const surface: *c.winghostty_surface = @ptrFromInt(0x1000);
        const other: *c.winghostty_surface = @ptrFromInt(0x2000);
        workspace.surfaces[3].surface = surface;
        RedrawTestApi.reset(surface);
        RedrawTestApi.bound = other;
        RedrawTestApi.binding_result = case.binding;
        RedrawTestApi.render_result = case.render;
        RedrawTestApi.clear_result = case.clear;

        redrawWith(RedrawTestApi, @ptrCast(&workspace), surface);

        try std.testing.expectEqual(case.swaps, RedrawTestApi.swap_requests);
        const expected: []const RedrawTestApi.Operation = if (case.binding != c.WINGHOSTTY_OK)
            &.{.make_current}
        else
            &.{ .make_current, .render, .clear_current };
        try std.testing.expectEqualSlices(RedrawTestApi.Operation, expected, RedrawTestApi.calls[0..RedrawTestApi.call_count]);
        try std.testing.expectEqualDeep(case.failure, RedrawTestApi.reported_failure.?);
        try std.testing.expectEqualDeep(case.failure, workspace.surfaces[3].last_redraw_failure.?.failure);
        try std.testing.expectEqual(@as(usize, 3), RedrawTestApi.reported_index);
        try std.testing.expectEqual(@as(usize, 1), RedrawTestApi.reports);
        if (case.binding != c.WINGHOSTTY_OK) {
            try std.testing.expectEqual(other, RedrawTestApi.bound.?);
        } else if (case.clear == c.WINGHOSTTY_OK) {
            try std.testing.expect(RedrawTestApi.bound == null);
        } else {
            try std.testing.expectEqual(surface, RedrawTestApi.bound.?);
        }
    }
}

test "terminal redraw lifetime guards reject without native operations" {
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    const surface: *c.winghostty_surface = @ptrFromInt(0x1000);
    RedrawTestApi.reset(surface);
    redrawWith(RedrawTestApi, null, surface);
    redrawWith(RedrawTestApi, @ptrCast(&workspace), surface);
    workspace.surfaces[0].surface = surface;
    workspace.surfaces[0].destroying = true;
    redrawWith(RedrawTestApi, @ptrCast(&workspace), surface);
    workspace.surfaces[0].destroying = false;
    workspace.surfaces[0].destroyed = true;
    redrawWith(RedrawTestApi, @ptrCast(&workspace), surface);
    try std.testing.expectEqual(@as(usize, 0), RedrawTestApi.call_count);
    try std.testing.expectEqual(@as(usize, 0), RedrawTestApi.reports);
}

test "terminal redraw still clears when the admitted surface starts teardown" {
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    const surface: *c.winghostty_surface = @ptrFromInt(0x1000);
    workspace.surfaces[0].surface = surface;
    RedrawTestApi.reset(surface);
    RedrawTestApi.invalidate_on_render = &workspace.surfaces[0];
    RedrawTestApi.render_result = c.WINGHOSTTY_SHUTTING_DOWN;

    redrawWith(RedrawTestApi, @ptrCast(&workspace), surface);

    try std.testing.expectEqualSlices(RedrawTestApi.Operation, &.{
        .make_current, .render, .clear_current,
    }, RedrawTestApi.calls[0..RedrawTestApi.call_count]);
    try std.testing.expect(RedrawTestApi.bound == null);
    try std.testing.expect(workspace.surfaces[0].last_redraw_failure == null);
    try std.testing.expectEqual(c.WINGHOSTTY_SHUTTING_DOWN, RedrawTestApi.reported_failure.?.result);
}

test "terminal redraw diagnostics are bounded per surface and recover independently" {
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    const first: *c.winghostty_surface = @ptrFromInt(0x1000);
    const second: *c.winghostty_surface = @ptrFromInt(0x2000);
    const replacement: *c.winghostty_surface = @ptrFromInt(0x3000);
    workspace.surfaces[0].surface = first;
    workspace.surfaces[1].surface = second;
    workspace.input_error_message = "retained input status";
    workspace.render_error = c.WINGHOSTTY_OUT_OF_MEMORY;
    workspace.surfaces[0].output_events = 7;
    const output_result = TerminalOutputResult{ .text_result = c.WINGHOSTTY_OUT_OF_MEMORY };
    workspace.surfaces[0].output_result = output_result;
    workspace.surfaces[0].parser = .csi;

    for (0..2) |iteration| {
        RedrawTestApi.reset(first);
        RedrawTestApi.render_result = c.WINGHOSTTY_RENDERER_ERROR;
        redrawWith(RedrawTestApi, @ptrCast(&workspace), first);
        try std.testing.expectEqual(@as(usize, if (iteration == 0) 1 else 0), RedrawTestApi.reports);
    }
    RedrawTestApi.reset(second);
    RedrawTestApi.render_result = c.WINGHOSTTY_RENDERER_ERROR;
    redrawWith(RedrawTestApi, @ptrCast(&workspace), second);
    try std.testing.expectEqual(@as(usize, 1), RedrawTestApi.reports);
    try std.testing.expectEqual(@as(usize, 1), RedrawTestApi.reported_index);

    RedrawTestApi.reset(first);
    RedrawTestApi.render_result = c.WINGHOSTTY_RENDERER_ERROR;
    RedrawTestApi.clear_result = c.WINGHOSTTY_WRONG_THREAD;
    redrawWith(RedrawTestApi, @ptrCast(&workspace), first);
    try std.testing.expectEqual(@as(usize, 1), RedrawTestApi.reports);

    RedrawTestApi.reset(first);
    redrawWith(RedrawTestApi, @ptrCast(&workspace), first);
    try std.testing.expect(workspace.surfaces[0].last_redraw_failure == null);
    try std.testing.expect(workspace.surfaces[1].last_redraw_failure != null);
    RedrawTestApi.reset(first);
    RedrawTestApi.render_result = c.WINGHOSTTY_RENDERER_ERROR;
    redrawWith(RedrawTestApi, @ptrCast(&workspace), first);
    try std.testing.expectEqual(@as(usize, 1), RedrawTestApi.reports);

    workspace.surfaces[0].surface = replacement;
    RedrawTestApi.reset(replacement);
    RedrawTestApi.render_result = c.WINGHOSTTY_RENDERER_ERROR;
    redrawWith(RedrawTestApi, @ptrCast(&workspace), replacement);
    try std.testing.expectEqual(@as(usize, 1), RedrawTestApi.reports);
    try std.testing.expectEqual(replacement, workspace.surfaces[0].last_redraw_failure.?.surface);
    try std.testing.expectEqualStrings("retained input status", workspace.input_error_message);
    try std.testing.expectEqual(c.WINGHOSTTY_OUT_OF_MEMORY, workspace.render_error);
    try std.testing.expectEqual(@as(usize, 7), workspace.surfaces[0].output_events);
    try std.testing.expectEqualDeep(output_result, workspace.surfaces[0].output_result);
    try std.testing.expectEqual(ParserState.csi, workspace.surfaces[0].parser);
}

test "terminal redraw does not overwrite a replacement surface diagnostic" {
    for ([_]c.winghostty_result{ c.WINGHOSTTY_OK, c.WINGHOSTTY_RENDERER_ERROR }) |result| {
        var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
        defer workspace.layout.deinit();
        const surface: *c.winghostty_surface = @ptrFromInt(0x1000);
        const replacement: *c.winghostty_surface = @ptrFromInt(0x2000);
        const replacement_failure = RedrawFailure{ .stage = .make_current, .result = c.WINGHOSTTY_CONTEXT_ERROR };
        workspace.surfaces[0].surface = surface;
        workspace.surfaces[0].last_redraw_failure = .{
            .surface = replacement,
            .failure = replacement_failure,
        };
        RedrawTestApi.reset(surface);
        RedrawTestApi.render_result = result;
        RedrawTestApi.invalidate_on_render = &workspace.surfaces[0];
        RedrawTestApi.replacement_on_render = replacement;

        redrawWith(RedrawTestApi, @ptrCast(&workspace), surface);

        try std.testing.expectEqualSlices(RedrawTestApi.Operation, &.{
            .make_current, .render, .clear_current,
        }, RedrawTestApi.calls[0..RedrawTestApi.call_count]);
        try std.testing.expectEqual(replacement, workspace.surfaces[0].surface.?);
        try std.testing.expectEqualDeep(replacement_failure, workspace.surfaces[0].last_redraw_failure.?.failure);
        try std.testing.expectEqual(replacement, workspace.surfaces[0].last_redraw_failure.?.surface);
        try std.testing.expect(RedrawTestApi.bound == null);
    }
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
    const workspace = workspaceFromUserData(user_data) orelse return;
    const slot = callbackSlot(workspace, surface) orelse return;
    // winghostty reports the DPI/scale it has already adopted internally for this
    // surface (e.g. after its own per-monitor DPI query or in response to
    // Workspace.setDpi()'s notify_dpi_changed call). Record it per-surface, rather
    // than discarding it, so callers (tests, future UIA/geometry consumers) can
    // observe what each live pane actually believes its DPI/scale is instead of only
    // ever seeing the workspace-wide value the app last pushed down.
    slot.dpi = Dpi.normalize(dpi);
    slot.reported_font_scale = scale;
}

fn onMetricsChanged(user_data: ?*anyopaque, surface: *c.winghostty_surface, metrics: *const c.winghostty_cell_metrics) callconv(.c) void {
    const workspace = workspaceFromUserData(user_data) orelse return;
    const slot = callbackSlot(workspace, surface) orelse return;
    // As with DPI above, keep the host's own recomputed cell metrics (font/cell
    // width/height, baseline) instead of discarding them, since they reflect the
    // actual glyph geometry winghostty is now rendering at the current font_scale.
    slot.cell_metrics = metrics.*;
}

fn onAccessibilitySelection(user_data: ?*anyopaque, surface: *c.winghostty_surface, start: u64, end: u64) callconv(.c) void {
    const workspace = workspaceFromUserData(user_data) orelse return;
    const slot = callbackSlot(workspace, surface) orelse return;
    slot.accessibility_selection = .{ .start = start, .end = end };
}

fn onKey(user_data: ?*anyopaque, surface: *c.winghostty_surface, event: *const c.winghostty_key_event) callconv(.c) void {
    const workspace = workspaceFromUserData(user_data) orelse return;
    const slot = callbackSlot(workspace, surface) orelse return;
    if (event.action == c.WINGHOSTTY_KEY_RELEASE) return;
    const modifiers = TerminalKeys.decodeProviderModifiers(event.modifiers);
    const ctrl = modifiers.ctrl;
    const shift = modifiers.shift;
    if (TerminalKeys.clipboardCommand(event.virtual_key, modifiers, slotHasSelection(slot))) |command| {
        // TranslateMessage already queued ^C/^V for these chords; they must not also reach the shell.
        discardTranslatedCharacters(c.GetFocus());
        if (event.action == c.WINGHOSTTY_KEY_PRESS) workspace.runClipboardCommand(command);
        return;
    }
    if (TerminalKeys.opensContextMenu(event.virtual_key, modifiers)) {
        if (event.action == c.WINGHOSTTY_KEY_PRESS) workspace.runContextMenu();
        return;
    }
    if (isApplicationShortcut(event.virtual_key, ctrl, shift) or
        (event.virtual_key == c.VK_TAB and
            (modifiers.alt or (event.modifiers & ~(TerminalKeys.provider_shift | TerminalKeys.provider_ctrl | TerminalKeys.provider_alt)) != 0)))
    {
        if (workspace.key_callback) |callback|
            callback(workspace.key_callback_context, event.virtual_key, ctrl, shift);
        return;
    }

    var text_buffer: [8]u8 = undefined;
    const key = TerminalKeyEncoding.Event{
        .vk = event.virtual_key,
        .action = if (event.action == c.WINGHOSTTY_KEY_REPEAT) .repeat else .press,
        .mods = modifiers,
        .extended = (event.flags & 1) != 0,
        .text = if (modifiers.alt and !modifiers.ctrl) altChordText(event, &text_buffer) else "",
    };
    var sequence_buffer: [TerminalKeyEncoding.max_sequence_bytes]u8 = undefined;
    const terminal: TerminalVt.c.GhosttyTerminal = if (slot.vt) |state| state.terminal else null;
    const bytes = switch (TerminalKeyEncoding.encode(&sequence_buffer, key, terminal)) {
        .not_encoded => return,
        .encoded => |sequence| sequence,
    };
    // Windows also turns Enter, Tab, Backspace, Escape, Ctrl+Space and Alt chords into WM_CHAR;
    // the encoded sequence replaces that text instead of arriving twice.
    discardTranslatedCharacters(c.GetFocus());
    const index = surfaceIndex(workspace, surface) orelse return;
    slot.accessibility_selection = null;
    workspace.enqueueInput(index, bytes);
}

/// What an Alt chord's key types on its own: Alt and Ctrl are cleared so ToUnicodeEx reports
/// the character (Shift and layout included), without disturbing dead-key state.
fn altChordText(event: *const c.winghostty_key_event, buffer: *[8]u8) []const u8 {
    var state: [256]u8 = undefined;
    if (c.GetKeyboardState(&state) == 0) return "";
    for ([_]usize{ c.VK_MENU, c.VK_LMENU, c.VK_RMENU, c.VK_CONTROL, c.VK_LCONTROL, c.VK_RCONTROL }) |key| state[key] = 0;
    var units: [8]u16 = undefined;
    const layout: c.HKL = if (event.keyboard_layout != 0)
        @import("Win32.zig").opaquePointerFromInt(c.HKL, event.keyboard_layout)
    else
        c.GetKeyboardLayout(0);
    const count = c.ToUnicodeEx(event.virtual_key, event.scan_code, &state, &units, units.len, 0x4, layout);
    if (count <= 0 or units[0] < 0x20) return "";
    const length = std.unicode.utf16LeToUtf8(buffer, units[0..@intCast(count)]) catch return "";
    return buffer[0..length];
}

fn slotHasSelection(slot: *const Surface) bool {
    const selection = slot.accessibility_selection orelse return false;
    return selection.end > selection.start;
}

/// Removes the WM_CHAR/WM_SYSCHAR messages TranslateMessage queued for the key being
/// dispatched. Only the character messages are filtered: key-up messages stay queued.
fn discardTranslatedCharacters(target: c.HWND) void {
    if (target == null) return;
    var message: c.MSG = undefined;
    while (c.PeekMessageW(&message, target, c.WM_CHAR, c.WM_DEADCHAR, c.PM_REMOVE) != 0) {}
    while (c.PeekMessageW(&message, target, c.WM_SYSCHAR, c.WM_SYSDEADCHAR, c.PM_REMOVE) != 0) {}
}

fn isApplicationShortcut(key: usize, ctrl: bool, shift: bool) bool {
    if (key == c.VK_TAB) return ctrl;
    if (!ctrl) return false;
    return switch (key) {
        'O', 'J', c.VK_PRIOR, c.VK_NEXT, 0xBC => true,
        // Ctrl+Shift+[ and ] move between panes; plain Ctrl+[ (ESC) and Ctrl+] belong to the shell.
        0xDB, 0xDD => shift,
        else => false,
    };
}

const OrdinaryTabKeyboardTest = struct {
    const registered: *c.winghostty_surface = @ptrFromInt(0x1000);
    const other: *c.winghostty_surface = @ptrFromInt(0x2000);
    const source_index: usize = 3;

    calls: usize = 0,
    action: @import("InputRouter.zig").Action = .none,

    fn applicationKey(context: ?*anyopaque, key: usize, ctrl: bool, shift: bool) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.action = @import("InputRouter.zig").keyAction(key, ctrl, shift);
    }

    fn bind(self: *@This(), workspace: *Workspace) void {
        workspace.surfaces[0].surface = other;
        workspace.surfaces[source_index].surface = registered;
        workspace.key_callback = &applicationKey;
        workspace.key_callback_context = self;
    }

    fn event(modifiers: u32, action: u32) c.winghostty_key_event {
        var key = std.mem.zeroes(c.winghostty_key_event);
        key.virtual_key = c.VK_TAB;
        key.modifiers = modifiers;
        key.action = action;
        return key;
    }

    fn expectInput(workspace: *Workspace, bytes: []const u8) !void {
        try std.testing.expectEqual(@as(usize, 1), workspace.input_queue.count);
        const item = workspace.input_queue.dequeue().?;
        defer workspace.allocator.free(item.bytes);
        try std.testing.expectEqual(source_index, item.surface);
        try std.testing.expectEqualStrings(bytes, item.bytes);
        try std.testing.expect(workspace.input_queue.dequeue() == null);
        try std.testing.expectEqual(@as(usize, 0), workspace.active_surface);
    }
};

test "ordinary Tab and backtab enter the exact registered surface queue once" {
    const Probe = OrdinaryTabKeyboardTest;
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    defer workspace.input_queue.clear();
    var probe = Probe{};
    probe.bind(&workspace);
    for ([_]u32{ 0, provider_shift }) |modifiers| {
        const event = Probe.event(modifiers, c.WINGHOSTTY_KEY_PRESS);
        onKey(@ptrCast(&workspace), Probe.registered, &event);
        try Probe.expectInput(&workspace, if (modifiers == 0) "\t" else "\x1b[Z");
        try std.testing.expectEqual(@as(usize, 0), probe.calls);
        try std.testing.expectEqual(@import("InputRouter.zig").Action.none, probe.action);
    }
}

test "ordinary Tab release and repeat preserve one item per accepted event" {
    const Probe = OrdinaryTabKeyboardTest;
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    defer workspace.input_queue.clear();
    var probe = Probe{};
    probe.bind(&workspace);
    for ([_]u32{ 0, provider_shift }) |modifiers| {
        var event = Probe.event(modifiers, c.WINGHOSTTY_KEY_RELEASE);
        onKey(@ptrCast(&workspace), Probe.registered, &event);
        try std.testing.expectEqual(@as(usize, 0), workspace.input_queue.count);
        for ([_]u32{ c.WINGHOSTTY_KEY_PRESS, c.WINGHOSTTY_KEY_REPEAT, c.WINGHOSTTY_KEY_REPEAT }) |action| {
            event.action = action;
            onKey(@ptrCast(&workspace), Probe.registered, &event);
            try Probe.expectInput(&workspace, if (modifiers == 0) "\t" else "\x1b[Z");
        }
    }
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
}

test "ordinary Tab changes preserve control and additional modifier shortcut routes" {
    const Probe = OrdinaryTabKeyboardTest;
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    defer workspace.input_queue.clear();
    var probe = Probe{};
    probe.bind(&workspace);
    for ([_]u32{ provider_ctrl, provider_ctrl | provider_shift, provider_alt, provider_shift | provider_alt, 0x80000000 }) |modifiers| {
        probe.calls = 0;
        const event = Probe.event(modifiers, c.WINGHOSTTY_KEY_PRESS);
        onKey(@ptrCast(&workspace), Probe.registered, &event);
        try std.testing.expectEqual(@as(usize, 1), probe.calls);
        try std.testing.expectEqual(@as(usize, 0), workspace.input_queue.count);
        const decoded = TerminalKeys.decodeProviderModifiers(modifiers);
        try std.testing.expectEqual(
            @import("InputRouter.zig").keyAction(c.VK_TAB, decoded.ctrl, decoded.shift),
            probe.action,
        );
    }
}

test "ordinary Tab rejects unregistered and retired surface callbacks" {
    const Probe = OrdinaryTabKeyboardTest;
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    defer workspace.input_queue.clear();
    var probe = Probe{};
    probe.bind(&workspace);
    const unknown: *c.winghostty_surface = @ptrFromInt(0x3000);
    for ([_]u32{ 0, provider_shift, provider_ctrl }) |modifiers| {
        const event = Probe.event(modifiers, c.WINGHOSTTY_KEY_PRESS);
        onKey(@ptrCast(&workspace), unknown, &event);
        workspace.surfaces[Probe.source_index].destroying = true;
        onKey(@ptrCast(&workspace), Probe.registered, &event);
        workspace.surfaces[Probe.source_index].destroying = false;
        workspace.surfaces[Probe.source_index].destroyed = true;
        onKey(@ptrCast(&workspace), Probe.registered, &event);
        workspace.surfaces[Probe.source_index].destroyed = false;
    }
    try std.testing.expectEqual(@as(usize, 0), workspace.input_queue.count);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
}

test "ordinary Tab production dispatch reaches the real terminal key callback" {
    const MainWindow = @import("MainWindow.zig");
    const Probe = OrdinaryTabKeyboardTest;
    const Api = struct {
        var workspace: *Workspace = undefined;
        var event: c.winghostty_key_event = undefined;
        var accelerator_calls: usize = 0;
        var translation_calls: usize = 0;
        var dispatch_calls: usize = 0;

        pub fn translateAccelerator(_: c.HWND, _: c.HACCEL, _: *c.MSG) c_int {
            accelerator_calls += 1;
            return 1;
        }

        pub fn translateMessage(_: *const c.MSG) c.BOOL {
            translation_calls += 1;
            return 1;
        }

        pub fn dispatchMessage(_: *const c.MSG) c.LRESULT {
            dispatch_calls += 1;
            onKey(@ptrCast(workspace), Probe.registered, &event);
            return 0;
        }
    };
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    defer workspace.input_queue.clear();
    var probe = Probe{};
    probe.bind(&workspace);
    Api.workspace = &workspace;
    const owner: c.HWND = @ptrFromInt(0x1000);
    const child: c.HWND = @ptrFromInt(0x2000);
    var window = MainWindow.Window{ .hwnd = owner, .accelerators = @ptrFromInt(0x3000) };
    var message = std.mem.zeroes(c.MSG);
    message.hwnd = child;
    message.message = c.WM_KEYDOWN;
    message.wParam = c.VK_TAB;
    for ([_]bool{ false, true }) |shift| {
        Api.accelerator_calls = 0;
        Api.translation_calls = 0;
        Api.dispatch_calls = 0;
        Api.event = Probe.event(if (shift) provider_shift else 0, c.WINGHOSTTY_KEY_PRESS);
        const keys = MainWindow.KeyContext{
            .active = true,
            .owner_enabled = true,
            .target_owned = true,
            .target_visible = true,
            .target_enabled = true,
            .shift = shift,
        };
        window.dispatchMessageWith(Api, &message, keys, child);
        try std.testing.expectEqual(@as(usize, 0), Api.accelerator_calls);
        try std.testing.expectEqual(@as(usize, 1), Api.translation_calls);
        try std.testing.expectEqual(@as(usize, 1), Api.dispatch_calls);
        try Probe.expectInput(&workspace, if (shift) "\x1b[Z" else "\t");
        try std.testing.expectEqual(@as(usize, 0), probe.calls);
    }
}

test "TerminalSurface.isApplicationShortcut forwards only the chords a terminal does not keep" {
    try std.testing.expect(isApplicationShortcut(c.VK_PRIOR, true, false));
    try std.testing.expect(isApplicationShortcut(c.VK_NEXT, true, false));
    try std.testing.expect(isApplicationShortcut(c.VK_TAB, true, false));
    try std.testing.expect(!isApplicationShortcut(c.VK_TAB, false, false));
    try std.testing.expect(isApplicationShortcut(0xBC, true, false));
    try std.testing.expect(isApplicationShortcut('O', true, false));
    try std.testing.expect(isApplicationShortcut('J', true, false));
    // Ctrl+D/W/S/T/N and Ctrl+[ / ] are terminal input: EOF, delete word, XOFF, transpose, next
    // history, ESC, and GS. Ctrl+Shift+[ / ] move between panes.
    for ([_]usize{ 'D', 'W', 'S', 'T', 'N', 0xDB, 0xDD }) |key| {
        try std.testing.expect(!isApplicationShortcut(key, true, false));
    }
    try std.testing.expect(isApplicationShortcut(0xDB, true, true));
    try std.testing.expect(isApplicationShortcut(0xDD, true, true));
    try std.testing.expect(!isApplicationShortcut('C', true, true));
    try std.testing.expect(!isApplicationShortcut('V', true, true));
    try std.testing.expect(!isApplicationShortcut(c.VK_UP, false, false));
    try std.testing.expect(!isApplicationShortcut(c.VK_DOWN, false, false));
    try std.testing.expect(!isApplicationShortcut('M', true, false));
}

// The pinned provider fills winghostty_key_event.modifiers from GetKeyState using the Win32
// MK_* masks (Shift 0x04, Control 0x08) plus 0x80 for Alt (win32_host.zig keyModifiers).
const provider_shift: u32 = 0x04;
const provider_ctrl: u32 = 0x08;
const provider_alt: u32 = 0x80;

fn providerKey(vk: usize, modifiers: u32, action: u32) c.winghostty_key_event {
    var key = std.mem.zeroes(c.winghostty_key_event);
    key.virtual_key = @intCast(vk);
    key.modifiers = modifiers;
    key.action = action;
    return key;
}

test "provider Shift modifier bit makes Tab a backtab instead of loop navigation" {
    const Probe = OrdinaryTabKeyboardTest;
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    defer workspace.input_queue.clear();
    var probe = Probe{};
    probe.bind(&workspace);
    const event = providerKey(c.VK_TAB, provider_shift, c.WINGHOSTTY_KEY_PRESS);
    onKey(@ptrCast(&workspace), Probe.registered, &event);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try Probe.expectInput(&workspace, "\x1b[Z");
}

const ClipboardProbe = struct {
    calls: usize = 0,
    key: usize = 0,
    ctrl: bool = false,
    shift: bool = false,

    fn callback(context: ?*anyopaque, key: usize, ctrl: bool, shift: bool) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.key = key;
        self.ctrl = ctrl;
        self.shift = shift;
    }

    fn bind(self: *@This(), workspace: *Workspace) void {
        workspace.surfaces[0].surface = OrdinaryTabKeyboardTest.registered;
        workspace.key_callback = &callback;
        workspace.key_callback_context = self;
    }
};

test "every terminal clipboard binding reaches the workspace as the canonical Ctrl+Shift chord" {
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    defer workspace.input_queue.clear();
    var probe = ClipboardProbe{};
    probe.bind(&workspace);
    workspace.surfaces[0].accessibility_selection = .{ .start = 2, .end = 9 };
    const cases = [_]struct { vk: usize, modifiers: u32, expected: usize }{
        .{ .vk = 'V', .modifiers = provider_ctrl | provider_shift, .expected = 'V' },
        .{ .vk = c.VK_INSERT, .modifiers = provider_shift, .expected = 'V' },
        .{ .vk = 'C', .modifiers = provider_ctrl | provider_shift, .expected = 'C' },
        .{ .vk = c.VK_INSERT, .modifiers = provider_ctrl, .expected = 'C' },
        .{ .vk = 'C', .modifiers = provider_ctrl, .expected = 'C' },
    };
    for (cases) |case| {
        probe = .{};
        probe.bind(&workspace);
        const event = providerKey(case.vk, case.modifiers, c.WINGHOSTTY_KEY_PRESS);
        onKey(@ptrCast(&workspace), OrdinaryTabKeyboardTest.registered, &event);
        try std.testing.expectEqual(@as(usize, 1), probe.calls);
        try std.testing.expectEqual(case.expected, probe.key);
        try std.testing.expect(probe.ctrl and probe.shift);
        try std.testing.expectEqual(@as(usize, 0), workspace.input_queue.count);
    }
}

test "terminal clipboard chords act once per press and never on repeat or release" {
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    defer workspace.input_queue.clear();
    var probe = ClipboardProbe{};
    probe.bind(&workspace);
    for ([_]u32{ c.WINGHOSTTY_KEY_RELEASE, c.WINGHOSTTY_KEY_REPEAT }) |action| {
        const event = providerKey('V', provider_ctrl | provider_shift, action);
        onKey(@ptrCast(&workspace), OrdinaryTabKeyboardTest.registered, &event);
    }
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
}

test "plain Ctrl+C and Ctrl+V stay terminal input without a selection" {
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    defer workspace.input_queue.clear();
    var probe = ClipboardProbe{};
    probe.bind(&workspace);
    for ([_]usize{ 'C', 'V' }) |vk| {
        const event = providerKey(vk, provider_ctrl, c.WINGHOSTTY_KEY_PRESS);
        onKey(@ptrCast(&workspace), OrdinaryTabKeyboardTest.registered, &event);
    }
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    workspace.surfaces[0].accessibility_selection = .{ .start = 4, .end = 4 };
    const event = providerKey('C', provider_ctrl, c.WINGHOSTTY_KEY_PRESS);
    onKey(@ptrCast(&workspace), OrdinaryTabKeyboardTest.registered, &event);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
}

test "discarding translated characters keeps key-up messages queued" {
    const parent = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral("translated character discard"),
        c.WS_OVERLAPPED,
        0,
        0,
        100,
        100,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return error.WindowCreationFailed;
    defer _ = c.DestroyWindow(parent);
    _ = c.PostMessageW(parent, c.WM_CHAR, 0x16, 0);
    _ = c.PostMessageW(parent, c.WM_SYSCHAR, 'x', 0);
    _ = c.PostMessageW(parent, c.WM_DEADCHAR, '`', 0);
    _ = c.PostMessageW(parent, c.WM_SYSKEYUP, 'X', 0);
    _ = c.PostMessageW(parent, c.WM_KEYUP, 'V', 0);
    discardTranslatedCharacters(parent);
    var message: c.MSG = undefined;
    var remaining: [4]c.UINT = undefined;
    var count: usize = 0;
    while (c.PeekMessageW(&message, parent, c.WM_KEYFIRST, c.WM_KEYLAST, c.PM_REMOVE) != 0) : (count += 1) {
        if (count < remaining.len) remaining[count] = message.message;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualSlices(c.UINT, &.{ c.WM_SYSKEYUP, c.WM_KEYUP }, remaining[0..2]);
}

test "terminal paste follows the program's bracketed-paste mode and clears a stale selection" {
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    defer workspace.input_queue.clear();
    const slot = &workspace.surfaces[0];
    slot.surface = OrdinaryTabKeyboardTest.registered;
    slot.vt = try TerminalVt.State.create(std.testing.allocator, 20, 3);
    defer slot.vt.?.destroy();
    slot.accessibility_selection = .{ .start = 1, .end = 5 };

    try workspace.pasteText("echo hi", false);
    var item = workspace.input_queue.dequeue().?;
    try std.testing.expectEqualStrings("echo hi", item.bytes);
    workspace.allocator.free(item.bytes);
    try std.testing.expect(slot.accessibility_selection == null);

    try std.testing.expectError(error.TerminalPasteRequiresConfirmation, workspace.pasteText("a\r\nb", false));
    try std.testing.expectEqual(@as(usize, 0), workspace.input_queue.count);
    try workspace.pasteText("a\r\nb", true);
    item = workspace.input_queue.dequeue().?;
    try std.testing.expectEqualStrings("a\rb", item.bytes);
    workspace.allocator.free(item.bytes);

    try slot.vt.?.feed("\x1b[?2004h");
    try workspace.pasteText("a\r\nb", false);
    item = workspace.input_queue.dequeue().?;
    try std.testing.expectEqualStrings("\x1b[200~a\nb\x1b[201~", item.bytes);
    workspace.allocator.free(item.bytes);
}

test "terminal paste has no target without a live surface" {
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    try std.testing.expectError(error.TerminalSurfaceUnavailable, workspace.pasteText("text", false));
    try workspace.pasteText("", false);
}

test "right button release, Menu key and Shift+F10 raise the terminal context menu route once" {
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    defer workspace.input_queue.clear();
    var probe = ClipboardProbe{};
    probe.bind(&workspace);
    var mouse = std.mem.zeroes(c.winghostty_mouse_event);
    mouse.button = 2;
    for ([_]u32{ c.WINGHOSTTY_MOUSE_BUTTON_DOWN, c.WINGHOSTTY_MOUSE_MOVE }) |kind| {
        mouse.kind = kind;
        onMouse(@ptrCast(&workspace), OrdinaryTabKeyboardTest.registered, &mouse);
    }
    mouse.kind = c.WINGHOSTTY_MOUSE_BUTTON_UP;
    mouse.button = 1;
    onMouse(@ptrCast(&workspace), OrdinaryTabKeyboardTest.registered, &mouse);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);

    mouse.button = 2;
    onMouse(@ptrCast(&workspace), OrdinaryTabKeyboardTest.registered, &mouse);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, c.VK_APPS), probe.key);

    probe = .{};
    probe.bind(&workspace);
    var event = providerKey(c.VK_APPS, 0, c.WINGHOSTTY_KEY_PRESS);
    onKey(@ptrCast(&workspace), OrdinaryTabKeyboardTest.registered, &event);
    event = providerKey(c.VK_F10, provider_shift, c.WINGHOSTTY_KEY_PRESS);
    onKey(@ptrCast(&workspace), OrdinaryTabKeyboardTest.registered, &event);
    event.action = c.WINGHOSTTY_KEY_REPEAT;
    onKey(@ptrCast(&workspace), OrdinaryTabKeyboardTest.registered, &event);
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), workspace.input_queue.count);
}

test "terminal selection state follows the surface's reported range" {
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    try std.testing.expect(!workspace.hasSelection());
    workspace.surfaces[0].accessibility_selection = .{ .start = 3, .end = 3 };
    try std.testing.expect(!workspace.hasSelection());
    workspace.surfaces[0].accessibility_selection = .{ .start = 3, .end = 8 };
    try std.testing.expect(workspace.hasSelection());
    workspace.dismissSelection();
    try std.testing.expect(!workspace.hasSelection());
}

test "provider Control+Shift bits route terminal clipboard chords to the workspace" {
    const Probe = OrdinaryTabKeyboardTest;
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    defer workspace.input_queue.clear();
    var probe = Probe{};
    probe.bind(&workspace);
    const event = providerKey('V', provider_ctrl | provider_shift, c.WINGHOSTTY_KEY_PRESS);
    onKey(@ptrCast(&workspace), Probe.registered, &event);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), workspace.input_queue.count);
}

fn onText(user_data: ?*anyopaque, surface: *c.winghostty_surface, text: [*:0]const u8, length: u32) callconv(.c) void {
    const workspace = workspaceFromUserData(user_data) orelse return;
    const slot = callbackSlot(workspace, surface) orelse return;
    const index = surfaceIndex(workspace, surface) orelse return;
    slot.accessibility_selection = null;
    workspace.enqueueInput(index, text[0..length]);
}

fn onImeStart(user_data: ?*anyopaque, surface: *c.winghostty_surface) callconv(.c) void {
    _ = user_data;
    _ = surface;
}

fn onImeUpdate(user_data: ?*anyopaque, surface: *c.winghostty_surface, text: [*:0]const u8, length: u32, committed: u8) callconv(.c) void {
    if (committed == 0) return;
    const workspace = workspaceFromUserData(user_data) orelse return;
    _ = callbackSlot(workspace, surface) orelse return;
    const index = surfaceIndex(workspace, surface) orelse return;
    workspace.enqueueInput(index, text[0..length]);
}

fn onImeEnd(user_data: ?*anyopaque, surface: *c.winghostty_surface) callconv(.c) void {
    _ = user_data;
    _ = surface;
}

test "committed IME composition enters the terminal input queue" {
    const allocator = std.testing.allocator;
    var workspace = try minimalWorkspaceForOptionsTest(allocator);
    defer workspace.layout.deinit();
    defer workspace.input_queue.clear();

    const fake_surface: *c.winghostty_surface = @ptrFromInt(0x1000);
    workspace.surfaces[3].surface = fake_surface;

    const preedit = "kana";
    onImeUpdate(@ptrCast(&workspace), fake_surface, preedit, preedit.len, 0);
    try std.testing.expectEqual(@as(usize, 0), workspace.input_queue.count);

    const committed = "日本";
    onImeUpdate(@ptrCast(&workspace), fake_surface, committed, committed.len, 1);
    try std.testing.expectEqual(@as(usize, 1), workspace.input_queue.count);
    const item = workspace.input_queue.dequeue().?;
    defer allocator.free(item.bytes);
    try std.testing.expectEqual(@as(usize, 3), item.surface);
    try std.testing.expectEqualStrings(committed, item.bytes);
}

fn onMouse(user_data: ?*anyopaque, surface: *c.winghostty_surface, event: *const c.winghostty_mouse_event) callconv(.c) void {
    const workspace = workspaceFromUserData(user_data) orelse return;
    _ = callbackSlot(workspace, surface) orelse return;
    // Winghostty numbers the buttons left 1, right 2, middle 3.
    if (event.kind == c.WINGHOSTTY_MOUSE_BUTTON_UP and event.button == 2) workspace.runContextMenu();
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

test "replacement preserves both surface cell buffers for donor reuse" {
    var surfaces = [_]Surface{.{}} ** max_surfaces;
    defer for (&surfaces) |*surface| {
        if (surface.session_name.len != 0) std.testing.allocator.free(surface.session_name);
        if (surface.cells.len != 0) std.testing.allocator.free(surface.cells);
    };
    surfaces[0].cells = try std.testing.allocator.alloc(c.winghostty_terminal_cell, cell_count);
    surfaces[1].cells = try std.testing.allocator.alloc(c.winghostty_terminal_cell, cell_count);

    const target_cells = surfaces[0].cells.ptr;
    const replacement_cells = surfaces[1].cells.ptr;
    const live_surface: *c.winghostty_surface = @ptrFromInt(1);
    surfaces[1].surface = live_surface;
    surfaces[1].session_name = try std.testing.allocator.dupe(u8, "replacement");

    moveReplacementSurface(&surfaces, 0, 1);

    try std.testing.expectEqual(live_surface, surfaces[0].surface.?);
    try std.testing.expectEqualStrings("replacement", surfaces[0].session_name);
    try std.testing.expectEqual(cell_count, surfaces[0].cells.len);
    try std.testing.expectEqual(replacement_cells, surfaces[0].cells.ptr);
    try std.testing.expectEqual(cell_count, surfaces[1].cells.len);
    try std.testing.expectEqual(target_cells, surfaces[1].cells.ptr);
    try std.testing.expect(surfaces[0].cells.ptr != surfaces[1].cells.ptr);

    feedCells(&surfaces[1], "A");
    try std.testing.expectEqual(@as(u32, 'A'), surfaces[1].cells[0].codepoint);

    surfaces[0].surface = null;
    std.testing.allocator.free(surfaces[0].session_name);
    surfaces[0].session_name = &.{};
    const second_surface: *c.winghostty_surface = @ptrFromInt(2);
    surfaces[1].surface = second_surface;
    surfaces[1].session_name = try std.testing.allocator.dupe(u8, "second replacement");

    moveReplacementSurface(&surfaces, 0, 1);

    try std.testing.expectEqual(second_surface, surfaces[0].surface.?);
    try std.testing.expectEqualStrings("second replacement", surfaces[0].session_name);
    try std.testing.expectEqual(target_cells, surfaces[0].cells.ptr);
    try std.testing.expectEqual(replacement_cells, surfaces[1].cells.ptr);
    feedCells(&surfaces[1], "B");
    try std.testing.expectEqual(@as(u32, 'B'), surfaces[1].cells[0].codepoint);
}

fn minimalWorkspaceForOptionsTest(allocator: std.mem.Allocator) !Workspace {
    return Workspace{
        .parent = null,
        .allocator = allocator,
        .zmx_path = @constCast(""),
        .cwd = @constCast(""),
        .input_queue = .{ .allocator = allocator },
        .layout = try WorkspaceLayout.Layout.init(allocator, "dpi-regression-test"),
        .layout_path = @constCast(""),
        .project_key = @constCast(""),
    };
}

test "opening a loop mounts its pending tab without spawning a terminal" {
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    defer workspace.cancelAllLaunchWaits();
    const path = "terminal-pending-loop-test.json";
    workspace.layout_path = @constCast(path);
    defer std.fs.cwd().deleteFile(path) catch {};
    try workspace.openLaunchedNode(0, "first-loop", LoopLaunchWait.open_timeout_ms);
    try std.testing.expectEqual(@as(usize, 1), workspace.tabCount());
    try std.testing.expect(workspace.isAwaitingLaunch(0));
    try std.testing.expect(workspace.surfaces[0].attach == null);
    try std.testing.expect(workspace.surfaces[0].surface == null);
    try std.testing.expectEqualStrings("first-loop", workspace.layout.tabs.items[0].panes.items[0].id);
    try workspace.openLaunchedNode(0, "second-loop", LoopLaunchWait.open_timeout_ms);
    try std.testing.expectEqual(@as(usize, 1), workspace.tabCount());
    try std.testing.expectEqualStrings("second-loop", workspace.layout.tabs.items[0].panes.items[0].id);
}

test "passive loop observation does not create a pending tab" {
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    defer workspace.cancelAllLaunchWaits();
    try workspace.openLaunchedNode(0, "idle-loop", 0);
    try std.testing.expectEqual(@as(usize, 0), workspace.tabCount());
    try std.testing.expect(workspace.surfaces[0].attach == null);
}

test "an explicit open rebinds a stale loop pane and survives a passive recreate of the ended loop" {
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    defer workspace.cancelAllLaunchWaits();
    const path = "terminal-stale-loop-pane-test.json";
    workspace.layout_path = @constCast(path);
    defer std.fs.cwd().deleteFile(path) catch {};
    // The deleted loop's pane outlived its session, beside a shell tab that is selected.
    try workspace.layout.addTab("deleted-loop", true);
    try workspace.layout.addTab("shell-tab", false);
    try workspace.openLaunchedNode(0, "next-loop", LoopLaunchWait.open_timeout_ms);
    try std.testing.expectEqual(@as(usize, 2), workspace.tabCount());
    try std.testing.expectEqual(@as(usize, 0), workspace.layout.selected_tab);
    try std.testing.expectEqualStrings("next-loop", workspace.layout.tabs.items[0].panes.items[0].id);
    try std.testing.expect(workspace.layout.tabs.items[0].panes.items[0].launches_agent);
    try std.testing.expectEqualStrings("shell-tab", workspace.layout.tabs.items[1].panes.items[0].id);
    // The ended loop's recreate is a passive check; it must not cancel the open.
    try workspace.openLaunchedNode(0, "deleted-loop", 0);
    try std.testing.expect(workspace.isAwaitingLaunch(0));
    try std.testing.expectEqualStrings("next-loop", workspace.launch_waits[0].session);
    try std.testing.expect(workspace.launch_waits[0].reports_timeout);
}

test "a bare zmx name resolves against the shell's directory, not the attaching child's" {
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("bin");
    try tmp.dir.writeFile(.{ .sub_path = "bin\\zmx.exe", .data = "" });
    const bin = try tmp.dir.realpathAlloc(std.testing.allocator, "bin");
    defer std.testing.allocator.free(bin);
    const expected = try std.fs.path.join(std.testing.allocator, &.{ bin, "zmx.exe" });
    defer std.testing.allocator.free(expected);
    workspace.cwd = bin;

    // As installed: zmx beside the shell, found through its working directory.
    workspace.zmx_path = try std.testing.allocator.dupe(u8, "zmx.exe");
    try std.testing.expectEqualStrings(expected, workspace.zmxExecutable());
    try std.testing.expectEqualStrings(expected, workspace.zmx_path);
    std.testing.allocator.free(workspace.zmx_path);

    // A name the shell's directory does not hold is left to PATH.
    workspace.zmx_path = try std.testing.allocator.dupe(u8, "zmx-elsewhere.exe");
    try std.testing.expectEqualStrings("zmx-elsewhere.exe", workspace.zmxExecutable());
    std.testing.allocator.free(workspace.zmx_path);

    // GRAPHCODE_ZMX's absolute path is used as given.
    workspace.zmx_path = try std.testing.allocator.dupe(u8, "C:\\provider\\zmx.exe");
    try std.testing.expectEqualStrings("C:\\provider\\zmx.exe", workspace.zmxExecutable());
    std.testing.allocator.free(workspace.zmx_path);
}

test "a loop pane is detached only when the layout owns it and no slot shows or awaits it" {
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    defer workspace.cancelAllLaunchWaits();
    const path = "terminal-detached-loop-test.json";
    workspace.layout_path = @constCast(path);
    defer std.fs.cwd().deleteFile(path) catch {};
    try std.testing.expect(!workspace.loopPaneDetached(""));
    try std.testing.expect(!workspace.loopPaneDetached("open-loop"));
    try workspace.layout.addTab("open-loop", true);
    try workspace.layout.addTab("shell-tab", false);
    try std.testing.expect(workspace.loopPaneDetached("open-loop"));
    // A shell tab and a loop the layout does not own are never graph-refresh targets.
    try std.testing.expect(!workspace.loopPaneDetached("shell-tab"));
    try std.testing.expect(!workspace.loopPaneDetached("other-loop"));
    try workspace.openLaunchedNode(3, "open-loop", LoopLaunchWait.open_timeout_ms);
    try std.testing.expect(!workspace.loopPaneDetached("open-loop"));
    workspace.cancelLaunchWait(3);
    try std.testing.expect(workspace.loopPaneDetached("open-loop"));
    workspace.surfaces[5] = .{
        .surface = @ptrFromInt(0x5000),
        .session_name = @constCast("open-loop"),
    };
    defer workspace.surfaces[5] = .{};
    try std.testing.expect(!workspace.loopPaneDetached("open-loop"));
}

fn paneResizeWorkspaceForTest(allocator: std.mem.Allocator) !Workspace {
    var workspace = try minimalWorkspaceForOptionsTest(allocator);
    errdefer workspace.layout.deinit();
    workspace.surfaces[0].cells = try allocator.alloc(c.winghostty_terminal_cell, cell_count);
    clearCells(&workspace.surfaces[0]);
    workspace.surfaces[0].cell_metrics = .{
        .font_width = 8,
        .font_height = 16,
        .cell_width = 8,
        .cell_height = 16,
        .baseline = 13,
    };
    workspace.surfaces[0].session_name = @constCast("session-a");
    workspace.surfaces[0].last_resize_size = default_grid;
    return workspace;
}

test "restored workspace focus follows selected tab and focused pane rather than slot zero" {
    const NativeFocus = struct {
        var focused: ?*c.winghostty_surface = null;
        fn set(surface: ?*c.winghostty_surface, focused_: u8) c.winghostty_result {
            if (focused_ != 0) focused = surface;
            return c.WINGHOSTTY_OK;
        }
    };
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(directory);
    const path = try std.fs.path.join(allocator, &.{ directory, "layout.json" });
    defer allocator.free(path);
    var workspace = try minimalWorkspaceForOptionsTest(allocator);
    defer workspace.layout.deinit();
    workspace.layout_path = path;
    workspace.project_path = @constCast("focus-project");
    try workspace.layout.addTab("loop", true);
    try workspace.layout.addTab("left", false);
    try workspace.layout.splitFocused(.horizontal, "right");
    try workspace.layout.save(path);
    const restored = try WorkspaceLayout.Layout.load(allocator, path, workspace.layout.project_key);
    workspace.layout.deinit();
    workspace.layout = restored;
    // Supplied native handles/focus callback: layout selection and restoration are real.
    for ([_]usize{ 0, 3, 7 }, [_][]const u8{ "loop", "left", "right" }) |index, id| {
        workspace.surfaces[index] = .{
            .surface = @ptrFromInt((index + 1) * 0x1000),
            .session_name = @constCast(id),
            .project_path = workspace.project_path,
        };
    }
    workspace.active_surface = 0;
    NativeFocus.focused = null;
    try workspace.focusRestoredPaneWith(NativeFocus.set);
    try std.testing.expectEqual(workspace.surfaces[7].surface, NativeFocus.focused);
    try std.testing.expectEqual(@as(usize, 7), workspace.active_surface);
    try std.testing.expectEqual(@as(usize, 1), workspace.layout.selected_tab);
    try std.testing.expectEqual(@as(usize, 1), workspace.layout.selected().?.focused_pane);
    try std.testing.expectEqual(@as(usize, 2), workspace.layout.tabs.items.len);
    try std.testing.expect(workspace.paneIndex("loop") == null);

    var persisted = try WorkspaceLayout.Layout.load(allocator, path, workspace.layout.project_key);
    defer persisted.deinit();
    try std.testing.expectEqual(@as(usize, 1), persisted.selected_tab);
    try std.testing.expectEqual(@as(usize, 1), persisted.selected().?.focused_pane);
    try std.testing.expectEqualStrings("right", persisted.selected().?.panes.items[1].id);
    workspace.active_surface = 3;
    try workspace.focusRestoredPaneWith(NativeFocus.set);
    try std.testing.expectEqual(workspace.surfaces[7].surface, NativeFocus.focused);
    try std.testing.expectEqual(@as(usize, 1), workspace.layout.selected().?.focused_pane);

    workspace.layout.selected().?.focused_pane = 0;
    workspace.active_surface = 7;
    try workspace.focusRestoredPaneWith(NativeFocus.set);
    try std.testing.expectEqual(workspace.surfaces[3].surface, NativeFocus.focused);
    try std.testing.expectEqual(@as(usize, 3), workspace.active_surface);
    try workspace.layout.selectTab(0);
    try workspace.focusRestoredPaneWith(NativeFocus.set);
    try std.testing.expectEqual(workspace.surfaces[0].surface, NativeFocus.focused);
    try std.testing.expectEqual(@as(usize, 0), workspace.active_surface);
    try workspace.layout.selectTab(1);
    workspace.focusWith(0, NativeFocus.set);
    try std.testing.expectEqual(workspace.surfaces[0].surface, NativeFocus.focused);
    try std.testing.expectEqual(@as(usize, 1), workspace.layout.selected_tab);
    try std.testing.expectEqual(@as(usize, 0), workspace.layout.selected().?.focused_pane);
    try workspace.focusRestoredPaneWith(NativeFocus.set);
    try std.testing.expectEqual(workspace.surfaces[3].surface, NativeFocus.focused);
}

test "restored workspace focus refuses unavailable foreign or ambiguous selected surfaces" {
    const NativeFocus = struct {
        var calls: usize = 0;
        fn set(_: ?*c.winghostty_surface, _: u8) c.winghostty_result {
            calls += 1;
            return c.WINGHOSTTY_OK;
        }
    };
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    workspace.project_path = @constCast("selected-project");
    workspace.persisting_layout = true;
    NativeFocus.calls = 0;
    try workspace.focusRestoredPaneWith(NativeFocus.set);
    try workspace.layout.addTab("first", true);
    try workspace.layout.addTab("selected", false);
    try workspace.focusRestoredPaneWith(NativeFocus.set);
    workspace.layout.selected_tab = 2;
    try std.testing.expectError(error.InvalidSelectedTab, workspace.focusRestoredPaneWith(NativeFocus.set));
    workspace.layout.selected_tab = 1;
    workspace.surfaces[0] = .{
        .surface = @ptrFromInt(0x1000),
        .session_name = @constCast("first"),
        .project_path = workspace.project_path,
    };
    try std.testing.expectError(error.FocusedSurfaceUnavailable, workspace.focusRestoredPaneWith(NativeFocus.set));
    workspace.surfaces[5] = .{
        .surface = @ptrFromInt(0x6000),
        .session_name = @constCast("selected"),
        .project_path = @constCast("foreign-project"),
    };
    try std.testing.expectError(error.FocusedSurfaceUnavailable, workspace.focusRestoredPaneWith(NativeFocus.set));
    workspace.surfaces[5].project_path = workspace.project_path;
    workspace.surfaces[5].destroying = true;
    try std.testing.expectError(error.FocusedSurfaceUnavailable, workspace.focusRestoredPaneWith(NativeFocus.set));
    workspace.surfaces[5].destroying = false;
    workspace.surfaces[5].destroyed = true;
    try std.testing.expectError(error.FocusedSurfaceUnavailable, workspace.focusRestoredPaneWith(NativeFocus.set));
    workspace.surfaces[5].destroyed = false;
    workspace.surfaces[6] = workspace.surfaces[5];
    try std.testing.expectError(error.AmbiguousFocusedSurface, workspace.focusRestoredPaneWith(NativeFocus.set));
    workspace.surfaces[6] = .{};
    workspace.layout.selected().?.focused_pane = 1;
    try std.testing.expectError(error.InvalidFocusedPane, workspace.focusRestoredPaneWith(NativeFocus.set));
    workspace.layout.selected().?.focused_pane = 0;
    workspace.collapsed = true;
    try workspace.focusRestoredPaneWith(NativeFocus.set);
    try std.testing.expectEqual(@as(usize, 0), NativeFocus.calls);
    try std.testing.expectEqual(@as(usize, 0), workspace.active_surface);
    try std.testing.expectEqual(@as(usize, 1), workspace.layout.selected_tab);
    try std.testing.expectEqual(@as(usize, 0), workspace.layout.selected().?.focused_pane);
}

test "onDpiChanged callback adopts the surface's real reported dpi and font scale" {
    // Regression coverage for the defect fixed in this change: onDpiChanged previously
    // discarded its dpi/scale parameters entirely (`_ = dpi; _ = scale;`), so a live
    // terminal surface never adopted winghostty's own post-DPI-change report and a
    // caller had no way to observe the surface's real per-surface DPI/scale.
    const allocator = std.testing.allocator;
    var workspace = try minimalWorkspaceForOptionsTest(allocator);
    defer workspace.layout.deinit();

    const fake_surface: *c.winghostty_surface = @ptrFromInt(0x1000);
    workspace.surfaces[0].surface = fake_surface;

    // Before any report, the slot still holds its construction-time baseline.
    try std.testing.expectEqual(@as(u32, Dpi.base_dpi), workspace.surfaces[0].dpi);
    try std.testing.expectEqual(@as(f32, 1.0), workspace.surfaces[0].reported_font_scale);

    onDpiChanged(@ptrCast(&workspace), fake_surface, 192, 2.0);

    try std.testing.expectEqual(@as(u32, 192), workspace.surfaces[0].dpi);
    try std.testing.expectEqual(@as(f32, 2.0), workspace.surfaces[0].reported_font_scale);
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
    if (wide.len == 0) return;
    const old_font = AppFont.select(hdc, size, false);
    _ = c.SetTextColor(hdc, color);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    var bounds = c.RECT{ .left = x, .top = y, .right = x + 220, .bottom = y + size + 8 };
    _ = c.DrawTextW(hdc, wide.ptr, @intCast(wide.len), &bounds, c.DT_LEFT | c.DT_SINGLELINE);
    _ = c.SelectObject(hdc, old_font);
}

// Clipped to `bounds`; a run squeezed narrower than its natural width ends in an
// ellipsis instead of being cut mid-glyph.
fn drawUtf8Bounded(hdc: c.HDC, text: []const u8, bounds: LoopBarLayout.Rect, size: i32, color: u32) void {
    const wide = std.unicode.utf8ToUtf16LeAlloc(std.heap.page_allocator, text) catch return;
    defer std.heap.page_allocator.free(wide);
    if (wide.len == 0) return;
    const old_font = AppFont.select(hdc, size, false);
    _ = c.SetTextColor(hdc, color);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    var rect = c.RECT{ .left = bounds.left, .top = bounds.top, .right = bounds.right, .bottom = bounds.bottom };
    const ellipsis: c_int = if (bounds.width() < LoopBarLayout.natural_text_width) c.DT_END_ELLIPSIS else 0;
    const format: c.UINT = @intCast(c.DT_LEFT | c.DT_SINGLELINE | ellipsis);
    _ = c.DrawTextW(hdc, wide.ptr, @intCast(wide.len), &rect, format);
    _ = c.SelectObject(hdc, old_font);
}

fn tabLabel(tab: WorkspaceLayout.Tab, index: usize) []const u8 {
    if (tab.panes.items.len > 1) return "split";
    if (index == 0) return "agent";
    return "shell";
}

fn tabIndicatorColor(workspace: *const Workspace, tab: WorkspaceLayout.Tab) u32 {
    for (tab.panes.items) |pane| {
        for (workspace.surfaces) |surface| {
            if (!std.mem.eql(u8, surface.session_name, pane.id)) continue;
            if (surface.destroying or surface.destroyed) return 0x005F5FFF;
            if (surface.surface != null) return 0x006BD58D;
        }
    }
    return 0x00C8C8CC;
}

fn elapsedLabel(created_at: u64) []const u8 {
    const normalized = if (created_at < 1_000_000_000_000) created_at *| 1000 else created_at;
    const now = std.time.milliTimestamp();
    const created: i64 = @intCast(@min(normalized, @as(u64, std.math.maxInt(i64))));
    const elapsed_ms: u64 = if (now > created) @intCast(now - created) else 0;
    const seconds = elapsed_ms / 1000;
    if (seconds < 60) return "elapsed <1m";
    if (seconds < 3600) return "elapsed <1h";
    return "elapsed >1h";
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

fn clearCells(slot: *Surface) void {
    for (slot.cells) |*cell| cell.* = .{ .codepoint = 0, .foreground = 0xE6E6E6, .background = 0, .flags = 0 };
    slot.terminal_x = 0;
    slot.terminal_y = 0;
}

fn advanceLine(slot: *Surface) void {
    const grid_columns = slot.grid.cols;
    const grid_rows = slot.grid.rows;
    const count = slot.cells.len;
    slot.terminal_x = 0;
    if (slot.terminal_y + 1 < grid_rows) {
        slot.terminal_y += 1;
        return;
    }
    std.mem.copyForwards(
        c.winghostty_terminal_cell,
        slot.cells[0 .. count - grid_columns],
        slot.cells[grid_columns..],
    );
    for (slot.cells[count - grid_columns ..]) |*cell| cell.* = .{
        .codepoint = 0,
        .foreground = 0xE6E6E6,
        .background = 0,
        .flags = 0,
    };
}

fn putCodepoint(slot: *Surface, codepoint: u32) void {
    if (slot.terminal_x >= slot.grid.cols) advanceLine(slot);
    slot.cells[slot.terminal_y * slot.grid.cols + slot.terminal_x] = .{
        .codepoint = codepoint,
        .foreground = 0xE6E6E6,
        .background = 0,
        .flags = 0,
    };
    slot.terminal_x += 1;
}

fn finishCsi(slot: *Surface, final: u8) void {
    const grid_columns = slot.grid.cols;
    const grid_rows = slot.grid.rows;
    const value = if (slot.csi_have_value) slot.csi_value else 1;
    switch (final) {
        'A' => slot.terminal_y -|= value,
        'B' => slot.terminal_y = @min(grid_rows - 1, slot.terminal_y + value),
        'C' => slot.terminal_x = @min(grid_columns, slot.terminal_x + value),
        'D' => slot.terminal_x -|= value,
        'J' => if (slot.csi_have_value and slot.csi_value == 2) clearCells(slot),
        'K' => {
            const start = slot.terminal_y * grid_columns + slot.terminal_x;
            for (slot.cells[start..][0 .. grid_columns - slot.terminal_x]) |*cell| cell.* = .{
                .codepoint = 0,
                .foreground = 0xE6E6E6,
                .background = 0,
                .flags = 0,
            };
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
            '\t' => slot.terminal_x = @min(slot.grid.cols, (slot.terminal_x + 8) & ~@as(usize, 7)),
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
    try std.testing.expect(chromeActionForBounds(220, 34, 800, 868, 44) == null);
    try std.testing.expectEqual(@as(?ChromeAction, null), chromeActionForBounds(220, 34, 800, 700, 44));
}

test "pane geometry derives a terminal grid from actual cell metrics" {
    const size = try gridSizeForBounds(480, 192, .{
        .font_width = 7,
        .font_height = 15,
        .cell_width = 8,
        .cell_height = 16,
        .baseline = 12,
    });
    try std.testing.expectEqual(GridSize{ .cols = 60, .rows = 12 }, size);
}

test "pane geometry clamps sub-cell bounds to one cell and ignores unset metrics" {
    try std.testing.expectEqual(
        GridSize{ .cols = 1, .rows = 1 },
        try gridSizeForBounds(3, 4, std.mem.zeroes(c.winghostty_cell_metrics)),
    );
    const one_pixel_cells = c.winghostty_cell_metrics{
        .font_width = 1,
        .font_height = 1,
        .cell_width = 1,
        .cell_height = 1,
        .baseline = 1,
    };
    try std.testing.expectEqual(
        GridSize{ .cols = 512, .rows = 512 },
        try gridSizeForBounds(512, 512, one_pixel_cells),
    );
    try std.testing.expectError(
        error.GridTooLarge,
        gridSizeForBounds(513, 512, one_pixel_cells),
    );
    try std.testing.expectError(
        error.GridTooLarge,
        gridSizeForBounds(std.math.maxInt(u32), 1, .{
            .font_width = 1,
            .font_height = 1,
            .cell_width = 1,
            .cell_height = 1,
            .baseline = 1,
        }),
    );
}

test "pane attach and resize commands carry geometry outside terminal input" {
    var attach_storage: [5][]const u8 = undefined;
    var attach_size: [16]u8 = undefined;
    var attach_session: [ZmxSession.prefix.len + 128]u8 = undefined;
    const attach = try attachArguments(
        "zmx.exe",
        "session-a",
        .{ .cols = 60, .rows = 12 },
        &attach_storage,
        &attach_size,
        &attach_session,
    );
    const expected_attach = [_][]const u8{ "zmx.exe", "attach", "graphcode-session-a", "--size", "60x12" };
    try std.testing.expectEqual(expected_attach.len, attach.len);
    for (expected_attach, attach) |expected, actual| try std.testing.expectEqualStrings(expected, actual);

    var resize_storage: [4][]const u8 = undefined;
    var resize_size: [16]u8 = undefined;
    var resize_session: [ZmxSession.prefix.len + 128]u8 = undefined;
    const resize = try resizeArguments(
        "zmx.exe",
        "session-a",
        .{ .cols = 80, .rows = 24 },
        &resize_storage,
        &resize_size,
        &resize_session,
    );
    const expected_resize = [_][]const u8{ "zmx.exe", "resize", "graphcode-session-a", "80x24" };
    try std.testing.expectEqual(expected_resize.len, resize.len);
    for (expected_resize, resize) |expected, actual| try std.testing.expectEqualStrings(expected, actual);

    var canonical_storage: [5][]const u8 = undefined;
    var canonical_size: [16]u8 = undefined;
    var canonical_session: [ZmxSession.prefix.len + 128]u8 = undefined;
    const canonical = try attachArguments(
        "zmx.exe",
        "graphcode-session-a",
        .{ .cols = 60, .rows = 12 },
        &canonical_storage,
        &canonical_size,
        &canonical_session,
    );
    try std.testing.expectEqualStrings("graphcode-session-a", canonical[2]);
}

test "pane bounds partition available area without losing remainder pixels" {
    const left = paneBounds(10, 20, 801, 400, .horizontal, 0, 2);
    const right = paneBounds(10, 20, 801, 400, .horizontal, 1, 2);
    try std.testing.expectEqual(@as(i32, 10), left.x);
    try std.testing.expectEqual(@as(u32, 400), left.width);
    try std.testing.expectEqual(@as(i32, 410), right.x);
    try std.testing.expectEqual(@as(u32, 401), right.width);
    try std.testing.expectEqual(@as(u32, 348), left.height);
    try std.testing.expectEqual(@as(u32, 348), right.height);
}

test "pane bounds ignore zero or unavailable client geometry" {
    const bounds = paneBounds(0, 0, 0, 0, .horizontal, 0, 1);
    try std.testing.expectEqual(@as(u32, 0), bounds.width);
    try std.testing.expectEqual(@as(u32, 0), bounds.height);
    const no_width = paneBounds(0, 0, 0, 400, .horizontal, 0, 1);
    try std.testing.expectEqual(@as(u32, 0), no_width.width);
    try std.testing.expectEqual(@as(u32, 0), no_width.height);
    const no_height = paneBounds(0, 0, 480, 0, .horizontal, 0, 1);
    try std.testing.expectEqual(@as(u32, 0), no_height.width);
    try std.testing.expectEqual(@as(u32, 0), no_height.height);
    const no_client_area = paneBounds(
        0,
        0,
        480,
        Tokens.tab_bar_height + Tokens.pane_header_height,
        .horizontal,
        0,
        1,
    );
    try std.testing.expectEqual(@as(u32, 0), no_client_area.width);
    try std.testing.expectEqual(@as(u32, 0), no_client_area.height);
}

test "zero pane geometry leaves the grid and backend resize queue unchanged" {
    var workspace = try paneResizeWorkspaceForTest(std.testing.allocator);
    defer workspace.layout.deinit();
    defer std.testing.allocator.free(workspace.surfaces[0].cells);

    const bounds = paneBounds(0, 0, 0, 0, .horizontal, 0, 1);
    workspace.syncPaneGrid(0, bounds, Workspace.resizeSurfaceGridState);

    try std.testing.expectEqual(default_grid, workspace.surfaces[0].grid);
    try std.testing.expect(workspace.surfaces[0].pending_resize_size == null);
}

test "minimize and restore to the same pane size does not queue a resize" {
    var workspace = try paneResizeWorkspaceForTest(std.testing.allocator);
    defer workspace.layout.deinit();
    defer std.testing.allocator.free(workspace.surfaces[0].cells);

    const minimized = paneBounds(0, 0, 0, 0, .horizontal, 0, 1);
    workspace.syncPaneGrid(0, minimized, Workspace.resizeSurfaceGridState);
    try std.testing.expectEqual(default_grid, workspace.surfaces[0].grid);
    try std.testing.expect(workspace.surfaces[0].pending_resize_size == null);

    const original = paneBounds(
        0,
        0,
        960,
        Tokens.tab_bar_height + Tokens.pane_header_height + 640,
        .horizontal,
        0,
        1,
    );
    workspace.syncPaneGrid(0, original, Workspace.resizeSurfaceGridState);

    try std.testing.expectEqual(default_grid, workspace.surfaces[0].grid);
    try std.testing.expect(workspace.surfaces[0].pending_resize_size == null);
}

test "minimize and restore to a new pane size queues one resize for the new grid" {
    var workspace = try paneResizeWorkspaceForTest(std.testing.allocator);
    defer workspace.layout.deinit();
    defer std.testing.allocator.free(workspace.surfaces[0].cells);

    const minimized = paneBounds(0, 0, 0, 0, .horizontal, 0, 1);
    workspace.syncPaneGrid(0, minimized, Workspace.resizeSurfaceGridState);
    try std.testing.expectEqual(default_grid, workspace.surfaces[0].grid);
    try std.testing.expect(workspace.surfaces[0].pending_resize_size == null);

    const restored = paneBounds(
        0,
        0,
        800,
        Tokens.tab_bar_height + Tokens.pane_header_height + 320,
        .horizontal,
        0,
        1,
    );
    workspace.syncPaneGrid(0, restored, Workspace.resizeSurfaceGridState);
    try std.testing.expectEqual(GridSize{ .cols = 100, .rows = 20 }, workspace.surfaces[0].grid);
    try std.testing.expectEqual(GridSize{ .cols = 100, .rows = 20 }, workspace.surfaces[0].pending_resize_size.?);

    workspace.syncPaneGrid(0, restored, Workspace.resizeSurfaceGridState);
    try std.testing.expectEqual(GridSize{ .cols = 100, .rows = 20 }, workspace.surfaces[0].pending_resize_size.?);
}

test "terminal grid resizing reallocates pane cells and keeps legacy output in bounds" {
    const allocator = std.testing.allocator;
    var slot = Surface{
        .cells = try allocator.alloc(c.winghostty_terminal_cell, cell_count),
    };
    defer allocator.free(slot.cells);
    clearCells(&slot);
    putCodepoint(&slot, 'A');

    const cells = try resizedCellBuffer(allocator, slot.cells, slot.grid, .{ .cols = 3, .rows = 2 }, null);
    allocator.free(slot.cells);
    slot.cells = cells;
    slot.grid = .{ .cols = 3, .rows = 2 };
    try std.testing.expectEqual(@as(usize, 6), slot.cells.len);
    try std.testing.expectEqual(@as(usize, 1), slot.terminal_x);
    try std.testing.expectEqual(@as(u32, 'A'), slot.cells[0].codepoint);
    feedCells(&slot, "BCDE");
    try std.testing.expectEqual(@as(u32, 'D'), slot.cells[3].codepoint);
    try std.testing.expectEqual(@as(usize, 1), slot.terminal_y);
    const snapshot = try accessibilitySnapshot(allocator, slot.cells, 3, 2, slot.terminal_x, slot.terminal_y);
    defer allocator.free(snapshot.text);
    try std.testing.expectEqualStrings("ABC\nDE ", snapshot.text);
}

test "terminal pane resize updates the experimental VT grid dimensions" {
    const allocator = std.testing.allocator;
    const old_cells = try allocator.alloc(c.winghostty_terminal_cell, cell_count);
    defer allocator.free(old_cells);
    const state = try TerminalVt.State.create(allocator, columns, rows);
    defer state.destroy();
    const cells = try resizedCellBuffer(allocator, old_cells, default_grid, .{ .cols = 60, .rows = 12 }, state);
    defer allocator.free(cells);
    try std.testing.expectEqual(@as(usize, 60), cells.len / 12);
    try std.testing.expectEqual(@as(usize, 720), cells.len);
    try std.testing.expectEqual(@as(u16, 60), state.snapshot.?.columns);
    try std.testing.expectEqual(@as(u16, 12), state.snapshot.?.rows);
}

test "pane resize requests coalesce, deduplicate and suppress failed retries" {
    var workspace = try minimalWorkspaceForOptionsTest(std.testing.allocator);
    defer workspace.layout.deinit();
    workspace.surfaces[0].last_resize_size = default_grid;
    workspace.surfaces[0].session_name = @constCast("session-a");

    workspace.queueResize(0, default_grid);
    try std.testing.expect(workspace.surfaces[0].pending_resize_size == null);
    workspace.queueResize(0, .{ .cols = 80, .rows = 24 });
    workspace.queueResize(0, .{ .cols = 72, .rows = 20 });
    try std.testing.expectEqual(GridSize{ .cols = 72, .rows = 20 }, workspace.surfaces[0].pending_resize_size.?);
    workspace.surfaces[0].attempted_resize_size = .{ .cols = 72, .rows = 20 };
    workspace.queueResize(0, .{ .cols = 72, .rows = 20 });
    try std.testing.expect(workspace.surfaces[0].pending_resize_size == null);

    workspace.surfaces[0].attempted_resize_size = null;
    workspace.resize_child_surface = 0;
    workspace.resize_child_session = @constCast("session-a");
    workspace.resize_child_size = .{ .cols = 80, .rows = 24 };
    workspace.queueResize(0, .{ .cols = 80, .rows = 24 });
    try std.testing.expect(workspace.surfaces[0].pending_resize_size == null);
    workspace.queueResize(0, default_grid);
    try std.testing.expectEqual(default_grid, workspace.surfaces[0].pending_resize_size.?);
    try std.testing.expectEqual(@as(usize, 0), workspace.input_queue.count);
}

test "workspace tab chrome separates selection and close affordances" {
    try std.testing.expectEqual(TabAction.select, tabActionForBounds(220, 34, 0, 228, 42).?);
    try std.testing.expectEqual(TabAction.close, tabActionForBounds(220, 34, 0, 320, 42).?);
    try std.testing.expect(tabActionForBounds(220, 34, 0, 340, 42) == null);
}

test "loop bar actions expose stop only for active loops" {
    try std.testing.expectEqual(LoopBarAction.stop, loopBarActionAt(220, 34, 1200, 1010, 50, false, false).?);
    try std.testing.expect(loopBarActionAt(220, 34, 1200, 1010, 50, true, false) == null);
    try std.testing.expectEqual(LoopBarAction.show_graph, loopBarActionAt(220, 34, 1200, 1120, 50, false, false).?);
    try std.testing.expect(loopBarActionAt(220, 34, 1200, 1120, 90, false, false) == null);
    // With the panel collapsed its expand control owns the trailing slot.
    try std.testing.expect(loopBarActionAt(220, 34, 1200, 1120, 50, false, true) == null);
    try std.testing.expectEqual(LoopBarAction.show_graph, loopBarActionAt(220, 34, 1200, 1050, 50, false, true).?);
}

const AttachOutputProbe = struct {
    input: []const u8,
    output: []u8,
    offset: usize = 0,
    delivered: usize = 0,
    publications: usize = 0,
    process_exited: bool = true,
    exit_queries: usize = 0,
    peek_calls: usize = 0,
    fail_peek_at: ?usize = null,
    fail_read: bool = false,
    zero_read: bool = false,
    read_limit: usize = 4096,
    largest_request: usize = 0,
    terminal: ?*Surface = null,
    publication: ?*TerminalOutputProbe = null,

    fn peek(self: *AttachOutputProbe) ?usize {
        self.peek_calls += 1;
        if (self.fail_peek_at == self.peek_calls) return null;
        return self.input.len - self.offset;
    }

    fn read(self: *AttachOutputProbe, buffer: []u8) ?usize {
        self.largest_request = @max(self.largest_request, buffer.len);
        if (self.fail_read) return null;
        if (self.zero_read) return 0;
        const count = @min(buffer.len, self.read_limit);
        @memcpy(buffer[0..count], self.input[self.offset..][0..count]);
        self.offset += count;
        return count;
    }

    fn publish(self: *AttachOutputProbe, bytes: []const u8) void {
        @memcpy(self.output[self.delivered..][0..bytes.len], bytes);
        self.delivered += bytes.len;
        self.publications += 1;
        if (self.terminal) |slot| {
            const probe = self.publication.?;
            probe.call_count = 0;
            _ = publishTerminalOutput(std.testing.allocator, slot, bytes, probe);
        }
    }

    fn exited(self: *AttachOutputProbe) bool {
        self.exit_queries += 1;
        return self.process_exited;
    }
};

test "terminal exit-tail drains buffered bytes through publication before retiring exited attach" {
    const allocator = std.testing.allocator;
    const tail = "\r\nEXIT-TAIL-DONE";
    const input = try allocator.alloc(u8, 65536 + tail.len);
    defer allocator.free(input);
    @memset(input[0..65536], 'A');
    @memcpy(input[65536..], tail);
    const output = try allocator.alloc(u8, input.len);
    defer allocator.free(output);
    var slot = Surface{ .cells = try allocator.alloc(c.winghostty_terminal_cell, cell_count) };
    defer allocator.free(slot.cells);
    slot.resetOutput();
    var publication = TerminalOutputProbe{};
    var probe = AttachOutputProbe{
        .input = input,
        .output = output,
        .terminal = &slot,
        .publication = &publication,
    };

    try std.testing.expectEqual(AttachOutputPollResult.keep_attached, pollAttachOutput(&probe));
    try std.testing.expectEqual(@as(usize, 65536), probe.delivered);
    try std.testing.expectEqual(@as(usize, 0), probe.exit_queries);
    try std.testing.expectEqual(AttachOutputPollResult.exited, pollAttachOutput(&probe));
    try std.testing.expectEqualStrings(input, output[0..probe.delivered]);
    try std.testing.expectEqual(@as(usize, 1), probe.exit_queries);
    try std.testing.expectEqual(@as(usize, 17), slot.output_events);
    try std.testing.expect(slot.output_result.succeeded());
    try std.testing.expectEqual(@as(usize, 4096), probe.largest_request);
    const sentinel = tail[2..];
    for (sentinel, 0..) |byte, index|
        try std.testing.expectEqual(@as(u32, byte), slot.cells[(rows - 1) * columns + index].codepoint);
    const text_start = (rows - 1) * (columns + 1);
    try std.testing.expectEqualStrings(sentinel, publication.text[text_start..][0..sentinel.len]);
}

test "terminal exit-tail preserves multiple polling budgets and partial reads without replay" {
    const allocator = std.testing.allocator;
    const input = try allocator.alloc(u8, 2 * 65536 + 37);
    defer allocator.free(input);
    for (input, 0..) |*byte, index| byte.* = @intCast(0x20 + index % 95);
    const output = try allocator.alloc(u8, input.len);
    defer allocator.free(output);
    var probe = AttachOutputProbe{ .input = input, .output = output, .read_limit = 31 };
    for (0..3) |poll| {
        const before = probe.delivered;
        const expected: AttachOutputPollResult = if (poll < 2) .keep_attached else .exited;
        try std.testing.expectEqual(expected, pollAttachOutput(&probe));
        try std.testing.expectEqual(if (poll < 2) @as(usize, 65536) else 37, probe.delivered - before);
    }
    try std.testing.expectEqualStrings(input, output[0..probe.delivered]);
    try std.testing.expectEqual(@as(usize, 1), probe.exit_queries);
    try std.testing.expect(probe.publications > 0);
    try std.testing.expectEqual(@as(usize, 4096), probe.largest_request);
}

test "terminal exit-tail retires drained zero short and exact-budget output without an extra poll" {
    const allocator = std.testing.allocator;
    const input = try allocator.alloc(u8, 65536);
    defer allocator.free(input);
    @memset(input, 'B');
    const output = try allocator.alloc(u8, input.len);
    defer allocator.free(output);
    for ([_]usize{ 0, 17, 65536 }) |length| {
        var probe = AttachOutputProbe{ .input = input[0..length], .output = output };
        try std.testing.expectEqual(AttachOutputPollResult.exited, pollAttachOutput(&probe));
        try std.testing.expectEqual(length, probe.delivered);
        try std.testing.expectEqualStrings(input[0..length], output[0..probe.delivered]);
        try std.testing.expectEqual(@as(usize, 1), probe.exit_queries);
        try std.testing.expect(probe.largest_request <= 4096);
    }
}

test "terminal exit-tail keeps running attaches live while output drains or stays idle" {
    const allocator = std.testing.allocator;
    const input = try allocator.alloc(u8, 65537);
    defer allocator.free(input);
    @memset(input, 'C');
    const output = try allocator.alloc(u8, input.len);
    defer allocator.free(output);
    var probe = AttachOutputProbe{ .input = input, .output = output, .process_exited = false };
    try std.testing.expectEqual(AttachOutputPollResult.keep_attached, pollAttachOutput(&probe));
    try std.testing.expectEqual(@as(usize, 65536), probe.delivered);
    try std.testing.expectEqual(@as(usize, 0), probe.exit_queries);
    try std.testing.expectEqual(AttachOutputPollResult.keep_attached, pollAttachOutput(&probe));
    try std.testing.expectEqualStrings(input, output[0..probe.delivered]);
    const publications = probe.publications;
    try std.testing.expectEqual(AttachOutputPollResult.keep_attached, pollAttachOutput(&probe));
    try std.testing.expectEqual(publications, probe.publications);
    try std.testing.expectEqual(@as(usize, 2), probe.exit_queries);
}

test "terminal exit-tail preserves fatal peek read and zero-progress outcomes" {
    const input: [5000]u8 = @splat('D');
    var output: [5000]u8 = undefined;
    for (0..4) |failure| {
        var probe = AttachOutputProbe{ .input = &input, .output = &output, .process_exited = false };
        switch (failure) {
            0 => probe.fail_peek_at = 1,
            1 => probe.fail_peek_at = 2,
            2 => probe.fail_read = true,
            3 => probe.zero_read = true,
            else => unreachable,
        }
        try std.testing.expectEqual(AttachOutputPollResult.exited, pollAttachOutput(&probe));
        const delivered: usize = if (failure == 1) 4096 else 0;
        try std.testing.expectEqual(delivered, probe.delivered);
        try std.testing.expectEqualStrings(input[0..delivered], output[0..probe.delivered]);
        try std.testing.expectEqual(@as(usize, 0), probe.exit_queries);
        try std.testing.expectEqual(if (failure == 1) @as(usize, 1) else 0, probe.publications);
    }
}
