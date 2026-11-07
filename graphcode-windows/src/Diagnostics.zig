const std = @import("std");

const max_bytes = 2 * 1024 * 1024;
var mutex: std.Thread.Mutex = .{};

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
