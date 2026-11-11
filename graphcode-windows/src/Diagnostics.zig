const std = @import("std");

const max_bytes = 2 * 1024 * 1024;
var mutex: std.Thread.Mutex = .{};

pub const EdgeActionTrace = struct {
    pub const max_events = 128;
    pub const Identity = struct {
        hash: u64 = 0,
        bytes: usize = 0,

        pub fn from(value: []const u8) Identity {
            return .{ .hash = std.hash.Wyhash.hash(0, value), .bytes = value.len };
        }
    };
    pub const Stage = enum {
        popup_entry,
        popup_return,
        popup_dispatch,
        popup_message,
        callback_entry,
        target_entry,
        target_resolved,
        target_refused,
        selection_result,
        edit_entry,
        guard_entry,
        guard_refused,
        guards_passed,
        modal_show,
        modal_callback,
        modal_return,
        edit_return,
    };
    pub const Event = struct {
        stage: Stage,
        project: Identity = .{},
        edge: Identity = .{},
        action: []const u8 = "none",
        command: i64 = 0,
        hwnd: usize = 0,
        index: ?usize = null,
        guard: []const u8 = "none",
        outcome: []const u8 = "none",
        reason: []const u8 = "none",
        tick_ms: u64 = 0,
        thread_id: u32 = 0,
        gui_available: bool = false,
        gui_flags: u32 = 0,
        foreground: usize = 0,
        foreground_pid: u32 = 0,
        focus: usize = 0,
        capture: usize = 0,
        menu_owner: usize = 0,
        message: u32 = 0,
        wparam: usize = 0,
        lparam: isize = 0,
    };
    events: u32 = 0,

    pub fn enabled(gate: ?[]const u8, trace: ?[]const u8) bool {
        return gate != null and trace != null and
            std.mem.eql(u8, gate.?, "1") and std.mem.eql(u8, trace.?, "1");
    }

    pub fn project(self: *EdgeActionTrace, buffer: []u8, event: Event) !?[]const u8 {
        if (self.events >= max_events) return null;
        self.events += 1;
        return try std.fmt.bufPrint(buffer, "EDGE_ACTION seq={d} stage={s} action={s} command={d} hwnd=0x{x} project_hash={x} project_bytes={d} edge_hash={x} edge_bytes={d} has_index={} index={d} guard={s} outcome={s} reason={s} tick_ms={d} thread={d} gui={} gui_flags=0x{x} foreground=0x{x} foreground_pid={d} focus=0x{x} capture=0x{x} menu_owner=0x{x} message=0x{x} wp=0x{x} lp={d}", .{
            self.events,                                   @tagName(event.stage),                       event.action[0..@min(event.action.len, 32)],
            event.command,                                 event.hwnd,                                  event.project.hash,
            event.project.bytes,                           event.edge.hash,                             event.edge.bytes,
            event.index != null,                           event.index orelse 0,                        event.guard[0..@min(event.guard.len, 32)],
            event.outcome[0..@min(event.outcome.len, 24)], event.reason[0..@min(event.reason.len, 64)], event.tick_ms,
            event.thread_id,                               event.gui_available,                         event.gui_flags,
            event.foreground,                              event.foreground_pid,                        event.focus,
            event.capture,                                 event.menu_owner,                            event.message,
            event.wparam,                                  event.lparam,
        });
    }
};

var edge_action_trace: EdgeActionTrace = .{};
pub var edge_action_test_observer: ?*const fn (EdgeActionTrace.Event) void = null;

pub fn traceEdgeAction(event: EdgeActionTrace.Event) void {
    if (@import("builtin").is_test) {
        if (edge_action_test_observer) |observe| {
            observe(event);
            return;
        }
    }
    if (!edgeActionTraceEnabled()) return;
    mutex.lock();
    defer mutex.unlock();
    var buffer: [1280]u8 = undefined;
    const line = edge_action_trace.project(&buffer, event) catch |err| {
        std.log.err("Edge action diagnostic projection failed: {s}", .{@errorName(err)});
        return;
    };
    if (line) |value| std.log.info("{s}", .{value});
}

pub fn edgeActionTraceEnabled() bool {
    const gate = edgeTraceValue("GRAPHCODE_UIA_GATE") orelse return false;
    defer std.heap.page_allocator.free(gate);
    if (!std.mem.eql(u8, gate, "1")) return false;
    const trace = edgeTraceValue("GRAPHCODE_UIA_EDGE_ACTION_TRACE") orelse return false;
    defer std.heap.page_allocator.free(trace);
    return EdgeActionTrace.enabled(gate, trace);
}

fn edgeTraceValue(name: []const u8) ?[]u8 {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch |err| {
        if (err != error.EnvironmentVariableNotFound)
            std.log.err("Edge action diagnostic flag read failed: {s}", .{@errorName(err)});
        return null;
    };
    return value;
}

test "edge action diagnostic requires both exact acceptance flags" {
    try std.testing.expect(EdgeActionTrace.enabled("1", "1"));
    for ([_]?[]const u8{ null, "", "0", "true", "01", "1 " }) |value| {
        try std.testing.expect(!EdgeActionTrace.enabled(value, "1"));
        try std.testing.expect(!EdgeActionTrace.enabled("1", value));
    }
}

test "edge action diagnostic has bounded ordered receipts without private identity text" {
    var trace = EdgeActionTrace{};
    var buffer: [768]u8 = undefined;
    const identity = EdgeActionTrace.Identity.from("private\\project\nedge");
    const event = EdgeActionTrace.Event{
        .stage = .popup_return,
        .project = identity,
        .edge = EdgeActionTrace.Identity.from("edge-a"),
        .command = 5110,
        .action = "edit_edge",
        .hwnd = 123,
        .index = 4,
    };
    const first = (try trace.project(&buffer, event)) orelse return error.MissingEdgeDiagnostic;
    try std.testing.expect(std.mem.startsWith(u8, first, "EDGE_ACTION seq=1 stage=popup_return"));
    try std.testing.expect(std.mem.indexOf(u8, first, "command=5110") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "private") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, first, '\n') == null);
    try std.testing.expect(first.len < buffer.len);
    const second = (try trace.project(&buffer, .{ .stage = .guard_refused, .guard = "scope", .reason = "StaleScope" })) orelse
        return error.MissingEdgeDiagnostic;
    try std.testing.expect(std.mem.startsWith(u8, second, "EDGE_ACTION seq=2 stage=guard_refused"));
    try std.testing.expect(std.mem.indexOf(u8, second, "guard=scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "reason=StaleScope") != null);
    for (2..EdgeActionTrace.max_events) |_| _ = try trace.project(&buffer, event);
    try std.testing.expectEqual(@as(?[]const u8, null), try trace.project(&buffer, event));
}

test "edge popup diagnostic projects native context and cancellation scalars without claiming selection" {
    var trace = EdgeActionTrace{};
    var buffer: [1280]u8 = undefined;
    const line = (try trace.project(&buffer, .{
        .stage = .popup_message,
        .tick_ms = 345,
        .thread_id = 17,
        .gui_available = true,
        .gui_flags = 4,
        .foreground = 100,
        .foreground_pid = 200,
        .focus = 300,
        .capture = 400,
        .menu_owner = 500,
        .message = 0x001f,
        .wparam = 0,
        .lparam = -1,
        .outcome = "observed",
    })) orelse return error.MissingEdgeDiagnostic;
    for ([_][]const u8{ "tick_ms=345", "thread=17", "gui=true", "gui_flags=0x4", "foreground=0x64", "foreground_pid=200", "focus=0x12c", "capture=0x190", "menu_owner=0x1f4", "message=0x1f", "lp=-1", "outcome=observed" }) |field|
        try std.testing.expect(std.mem.indexOf(u8, line, field) != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "selected") == null);
}

pub const WireReceiverTrace = struct {
    pub const max_events = 64;
    events: u32 = 0,
    sequence: u32 = 0,

    pub const State = struct {
        x: i32,
        y: i32,
        buttons: usize,
        raw_lparam: i64 = 0,
        source: []const u8,
        edge_dragging: bool,
        node_dragging: bool,
        panning: bool,
        surface: []const u8,
    };

    pub fn relevant(message: u32) bool {
        return switch (message) {
            0x0200, 0x0201, 0x0202, 0x0215, 0x001f, 0x001c => true,
            else => false,
        };
    }

    pub fn begin(self: *WireReceiverTrace) ?u32 {
        if (self.events >= max_events) return null;
        self.events += 1;
        return self.events;
    }

    pub fn project(self: *WireReceiverTrace, buffer: []u8, event: u32, message: u32, after: bool, state: State) ![]const u8 {
        self.sequence += 1;
        const source = state.source[0..@min(state.source.len, 36)];
        return std.fmt.bufPrint(buffer, "WIRE_RECEIVER seq={d} event={d} phase={s} msg=0x{x} x={d} y={d} flags=0x{x} lp=0x{x} edge={} node={} pan={} surface={s} source_hex={x} source_bytes={d} truncated={}", .{ self.sequence, event, if (after) "after" else "before", message, state.x, state.y, state.buttons, state.raw_lparam, state.edge_dragging, state.node_dragging, state.panning, state.surface[0..@min(state.surface.len, 16)], source, state.source.len, state.source.len > source.len });
    }
};

pub fn record(allocator: std.mem.Allocator, event: []const u8, detail: []const u8) void {
    mutex.lock();
    defer mutex.unlock();

    const directory = supportDirectory(allocator) catch return;
    defer allocator.free(directory);
    std.fs.cwd().makePath(directory) catch return;
    const path = std.fs.path.join(allocator, &.{ directory, "graphcode-windows.log" }) catch return;
    defer allocator.free(path);

    var file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
    defer file.close();
    const size = file.getEndPos() catch 0;
    if (size >= max_bytes) {
        file.setEndPos(0) catch return;
        file.seekTo(0) catch return;
    } else {
        file.seekFromEnd(0) catch return;
    }

    const line = std.fmt.allocPrint(
        allocator,
        "{d} event={s} detail={s}\r\n",
        .{ std.time.timestamp(), event, detail },
    ) catch return;
    defer allocator.free(line);
    file.writeAll(line) catch {};
}

pub fn startupFatalDetail(err: anyerror) []const u8 {
    return switch (err) {
        error.UserProfileMissing => "operation=resolve_support_directory missing_environment=USERPROFILE",
        error.WorkspaceUserUnavailable => "operation=reserve_workspace windows_identity=GetUserNameW",
        error.EnvironmentVariableNotFound => "operation=startup_environment missing_environment=unexpected",
        else => @errorName(err),
    };
}

fn supportDirectory(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "GRAPHCODE_SUPPORT_DIR")) |value| {
        return value;
    } else |_| {}
    const profile = try std.process.getEnvVarOwned(allocator, "USERPROFILE");
    defer allocator.free(profile);
    return std.fs.path.join(allocator, &.{ profile, ".graphcode" });
}

test "diagnostic log has a bounded filename and size" {
    try std.testing.expectEqualStrings("graphcode-windows.log", std.fs.path.basename("x\\graphcode-windows.log"));
    try std.testing.expect(max_bytes >= 1024 * 1024);
}

test "startup fatal diagnostics name the bounded operation without environment values" {
    try std.testing.expectEqualStrings(
        "operation=resolve_support_directory missing_environment=USERPROFILE",
        startupFatalDetail(error.UserProfileMissing),
    );
    try std.testing.expectEqualStrings(
        "operation=reserve_workspace windows_identity=GetUserNameW",
        startupFatalDetail(error.WorkspaceUserUnavailable),
    );
    try std.testing.expectEqualStrings(
        "operation=startup_environment missing_environment=unexpected",
        startupFatalDetail(error.EnvironmentVariableNotFound),
    );
}

test "wire receiver trace is bounded scalar projection with monotonic nested event ordering" {
    var trace = WireReceiverTrace{};
    var buffer: [512]u8 = undefined;
    const state = WireReceiverTrace.State{ .x = 632, .y = -182, .buttons = 1, .source = "source\n\tid", .edge_dragging = true, .node_dragging = false, .panning = false, .surface = "project" };
    const drag = trace.begin().?;
    const before = try trace.project(&buffer, drag, 0x0202, false, state);
    try std.testing.expect(std.mem.startsWith(u8, before, "WIRE_RECEIVER seq=1 event=1 phase=before"));
    try std.testing.expect(std.mem.indexOf(u8, before, "\n") == null);
    const cancel = trace.begin().?;
    _ = try trace.project(&buffer, cancel, 0x0215, false, state);
    _ = try trace.project(&buffer, cancel, 0x0215, true, state);
    const after = try trace.project(&buffer, drag, 0x0202, true, state);
    try std.testing.expect(std.mem.startsWith(u8, after, "WIRE_RECEIVER seq=4 event=1 phase=after"));
    while (trace.events < WireReceiverTrace.max_events) _ = trace.begin();
    try std.testing.expect(trace.begin() == null);
    for ([_]u32{ 0x0200, 0x0201, 0x0202, 0x0215, 0x001f, 0x001c }) |message|
        try std.testing.expect(WireReceiverTrace.relevant(message));
    try std.testing.expect(!WireReceiverTrace.relevant(0x000f));
}

test "wire receiver trace truncates private source bytes without unbounded output" {
    var trace = WireReceiverTrace{};
    var buffer: [512]u8 = undefined;
    const line = try trace.project(&buffer, trace.begin().?, 0x0200, false, .{
        .x = 0,
        .y = 0,
        .buttons = 0,
        .source = &([_]u8{'x'} ** 2048),
        .edge_dragging = false,
        .node_dragging = false,
        .panning = false,
        .surface = "project",
    });
    try std.testing.expect(line.len < buffer.len);
    try std.testing.expect(std.mem.endsWith(u8, line, "source_bytes=2048 truncated=true"));
}
