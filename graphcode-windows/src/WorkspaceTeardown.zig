const std = @import("std");
const Lifecycle = @import("WorkspaceLifecycle.zig");
const Manager = @import("WorkspaceManager.zig");
const DaemonClient = @import("DaemonClient.zig");
const Win32 = @import("Win32.zig");
const ZmxSession = @import("ZmxSession.zig");
const c = Win32.c;

/// Recoverable workspace deletion, mirroring macOS `WorkspaceClient.delete`: the daemon
/// goes first, the folder goes to the Recycle Bin rather than being unlinked, and the
/// running sessions are ended.
///
/// The order differs from macOS in one deliberate way. There, sessions are killed before
/// `trashItem`; here the kill runs *after* the move. Killing a session cannot be undone
/// and `SHFileOperationW` can fail late, so the irreversible step must not precede the
/// fallible one. What makes that safe is the staging rename: the folder is moved aside
/// first, which is atomic, reversible, and proves exclusive access before anything else
/// happens. Later failures attempt to put the folder back; failed restoration retains
/// the staged path in the recovery report.
pub const staging_prefix = ".gc-deleting-";
pub const daemon_stop_timeout_ms: i64 = 5_000;
pub const recycle_flags: c.FILEOP_FLAGS =
    c.FOF_ALLOWUNDO | c.FOF_NOCONFIRMATION | c.FOF_SILENT | c.FOF_NOERRORUI;

pub const confirmation_text =
    "Delete this workspace? Its terminal sessions are ended and its daemon stopped; " ++
    "the folder moves to the Recycle Bin, where it stays recoverable.";
pub const delete_caption = "Delete Workspace";

pub const Outcome = enum { deleted, refused, rolled_back, stranded };

pub const Report = struct {
    outcome: Outcome,
    cause: ?anyerror = null,
    /// Owned, and only set for `.stranded`: the folder is on disk under this name.
    staged_path: ?[]u8 = null,
    sessions_targeted: usize = 0,
    sessions_known: bool = true,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        if (self.staged_path) |value| allocator.free(value);
        self.staged_path = null;
    }
};

/// A sibling name the workspace list can never pick up: it neither carries the workspace
/// directory prefix nor equals the Default directory name, so a staged folder is invisible
/// to `WorkspaceLifecycle.listFromHome` while it exists.
pub fn stagingPath(allocator: std.mem.Allocator, path: []const u8, pid: u32) ![]u8 {
    const trimmed = std.mem.trimRight(u8, path, "\\/");
    const parent = std.fs.path.dirnameWindows(trimmed) orelse return error.InvalidWorkspacePath;
    const name = std.fs.path.basenameWindows(trimmed);
    if (name.len == 0 or parent.len == 0) return error.InvalidWorkspacePath;
    if (std.mem.eql(u8, name, trimmed)) return error.InvalidWorkspacePath;
    return std.fmt.allocPrint(allocator, "{s}\\{s}{d}-{s}", .{ parent, staging_prefix, pid, name });
}

/// The daemon we are about to stop must not be this window's own daemon. Identity paths and
/// lock names normalize differently, so both are checked before anything is signalled.
pub fn requireDistinctDaemon(target_lock: []const u8, current_lock: []const u8) !void {
    if (std.mem.eql(u8, target_lock, current_lock)) return error.WorkspaceDaemonIdentityMatch;
}

/// Session ids saved by the workspace, read best-effort: an unreadable or malformed file
/// costs us its sessions, not the deletion. Mirrors the macOS union of graph node ids;
/// surfaces saved outside the workspace directory stay out of reach and are reported as
/// unknown rather than assumed absent.
pub fn collectSessionIds(allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
    var ids: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }
    const projects_path = try std.fs.path.join(allocator, &.{ path, "projects" });
    defer allocator.free(projects_path);
    var projects = std.fs.openDirAbsolute(projects_path, .{ .iterate = true }) catch
        return ids.toOwnedSlice(allocator);
    defer projects.close();
    var iterator = projects.iterate();
    var entries: usize = 0;
    var remaining: usize = Manager.max_workspace_bytes;
    while (iterator.next() catch null) |entry| {
        entries += 1;
        if (entries > Manager.max_entries) break;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const bytes = projects.readFileAlloc(
            allocator,
            entry.name,
            @min(Manager.max_file_bytes, remaining),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer allocator.free(bytes);
        remaining -= bytes.len;
        try appendSessionIds(allocator, &ids, bytes, entry.name);
    }
    return ids.toOwnedSlice(allocator);
}

fn appendSessionIds(
    allocator: std.mem.Allocator,
    ids: *std.ArrayListUnmanaged([]u8),
    bytes: []const u8,
    name: []const u8,
) !void {
    Manager.checkDepth(bytes) catch return;
    const scratch = try allocator.alloc(u8, Manager.parser_bytes);
    defer allocator.free(scratch);
    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    const parsed = std.json.parseFromSlice(std.json.Value, fixed.allocator(), bytes, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value == .array and std.mem.endsWith(u8, name, ".mailroom.json")) return;
    if (parsed.value != .object) return;
    const nodes = parsed.value.object.get("nodes") orelse return;
    if (nodes != .array) return;
    for (nodes.array.items) |node| {
        if (node != .object) continue;
        const id = node.object.get("id") orelse continue;
        if (id != .string or !isSessionId(id.string)) continue;
        try ids.append(allocator, try allocator.dupe(u8, id.string));
    }
}

/// Session ids are UUIDs on both platforms, so an id that is not one is not ours to end.
fn isSessionId(text: []const u8) bool {
    if (text.len != 36) return false;
    for (text, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
        } else if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

pub fn freeSessionIds(allocator: std.mem.Allocator, ids: [][]u8) void {
    for (ids) |id| allocator.free(id);
    allocator.free(ids);
}

/// One invocation, every id, `--force`: matching the macOS `endSessions` shape, where a
/// missing or unhappy zmx is not allowed to fail an otherwise completed deletion.
pub fn killArgv(allocator: std.mem.Allocator, zmx_path: []const u8, ids: []const []u8) ![][]const u8 {
    const argv = try allocator.alloc([]const u8, ids.len + 3);
    errdefer allocator.free(argv);
    argv[0] = zmx_path;
    argv[1] = "kill";
    var added: usize = 0;
    errdefer for (argv[2..][0..added]) |value| allocator.free(value);
    for (ids, 0..) |id, index| {
        argv[index + 2] = try ZmxSession.allocName(allocator, id);
        added += 1;
    }
    argv[argv.len - 1] = "--force";
    return argv;
}

fn freeKillArgv(allocator: std.mem.Allocator, argv: [][]const u8) void {
    for (argv[2 .. argv.len - 1]) |value| allocator.free(value);
    allocator.free(argv);
}

fn causeText(cause: ?anyerror) []const u8 {
    const err = cause orelse return "an unknown failure";
    return switch (err) {
        error.WorkspaceRenameFailed => "the folder could not be moved, so something is still using it",
        error.WorkspaceRecycleFailed => "the folder could not be moved to the Recycle Bin",
        error.WorkspaceDaemonStopTimedOut => "its background daemon did not stop in time",
        error.WorkspaceDaemonStopFailed => "its background daemon could not be signalled",
        error.WorkspaceDaemonUnreachable => "its background daemon is running but cannot be reached",
        error.WorkspaceDaemonIdentityMatch => "the daemon it uses belongs to this window",
        error.WorkspaceIsCurrent => "it is the workspace this window has open",
        error.WorkspaceStagingCollision => "a leftover folder from an earlier delete is in the way",
        error.InvalidWorkspacePath => "its location is not a workspace folder",
        error.OutOfMemory => "memory allocation failed",
        else => "an unexpected failure",
    };
}

pub fn statusMessage(allocator: std.mem.Allocator, report: Report) ![]u8 {
    return switch (report.outcome) {
        .deleted => if (report.sessions_known) std.fmt.allocPrint(
            allocator,
            "Workspace deleted: daemon stopped, {d} saved terminal session(s) ended, folder moved to the Recycle Bin.",
            .{report.sessions_targeted},
        ) else std.fmt.allocPrint(
            allocator,
            "Workspace deleted and moved to the Recycle Bin. Its saved sessions could not be read, so some may still be running.",
            .{},
        ),
        .refused => std.fmt.allocPrint(
            allocator,
            "Workspace not deleted: {s}. Nothing was changed.",
            .{causeText(report.cause)},
        ),
        .rolled_back => std.fmt.allocPrint(
            allocator,
            "Workspace restored because {s}. No sessions were ended; its daemon is stopped and starts again when the workspace is opened.",
            .{causeText(report.cause)},
        ),
        .stranded => std.fmt.allocPrint(
            allocator,
            "Workspace could not be restored after {s}. No sessions were ended; the folder is on disk as {s} and renaming it back restores the workspace.",
            .{ causeText(report.cause), report.staged_path orelse "an unknown path" },
        ),
    };
}

fn rollbackReport(
    comptime Api: type,
    allocator: std.mem.Allocator,
    staged: []u8,
    path: []const u8,
    cause: anyerror,
    outcome: Outcome,
) Report {
    Api.rename(allocator, staged, path) catch {
        return .{ .outcome = .stranded, .cause = cause, .staged_path = staged };
    };
    allocator.free(staged);
    return .{ .outcome = outcome, .cause = cause };
}

/// Recoverable deletion. The staging rename comes first because it is atomic, reversible,
/// and the only way to prove exclusive access before an irreversible step; killing sessions
/// comes last because it is the one step nothing can undo.
pub fn deleteRecoverablyWith(
    comptime Api: type,
    allocator: std.mem.Allocator,
    path: []const u8,
    current_identity: []const u8,
) !Report {
    const staged = try stagingPath(allocator, path, Api.pid());
    Api.rename(allocator, path, staged) catch |err| {
        allocator.free(staged);
        return .{ .outcome = .refused, .cause = err };
    };
    const sessions: ?[][]u8 = Api.collectSessions(allocator, staged) catch |err| blk: {
        if (err == error.OutOfMemory) {
            var report = rollbackReport(Api, allocator, staged, path, err, .refused);
            if (report.outcome == .stranded) {
                report.sessions_known = false;
                return report;
            }
            return error.OutOfMemory;
        }
        break :blk null;
    };
    defer if (sessions) |owned| freeSessionIds(allocator, owned);
    Api.stopDaemon(allocator, path, current_identity) catch |err|
        return rollbackReport(Api, allocator, staged, path, err, .refused);
    Api.recycle(allocator, staged) catch |err|
        return rollbackReport(Api, allocator, staged, path, err, .rolled_back);
    allocator.free(staged);
    const owned = sessions orelse
        return .{ .outcome = .deleted, .sessions_known = false };
    return .{
        .outcome = .deleted,
        .sessions_targeted = Api.killSessions(allocator, owned),
        .sessions_known = true,
    };
}

/// The real effects. Every one of them is injected through the same seam the tests use, so
/// no test ever signals a daemon, recycles a folder, or kills a session.
pub const Live = struct {
    pub fn pid() u32 {
        return @intCast(c.GetCurrentProcessId());
    }

    pub fn rename(allocator: std.mem.Allocator, source: []const u8, destination: []const u8) !void {
        const source_wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, source);
        defer allocator.free(source_wide);
        const destination_wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, destination);
        defer allocator.free(destination_wide);
        if (c.MoveFileW(source_wide.ptr, destination_wide.ptr) == 0) return error.WorkspaceRenameFailed;
    }

    pub fn collectSessions(allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
        return collectSessionIds(allocator, path);
    }

    pub fn stopDaemon(
        allocator: std.mem.Allocator,
        path: []const u8,
        current_identity: []const u8,
    ) !void {
        const identity = try Lifecycle.pathIdentity(allocator, path);
        defer allocator.free(identity);
        if (std.mem.eql(u8, identity, current_identity)) return error.WorkspaceIsCurrent;
        const trimmed = std.mem.trimRight(u8, path, "\\/");
        const lock = try DaemonClient.daemonLockNameFor(allocator, trimmed);
        defer allocator.free(lock);
        const current_lock = try DaemonClient.daemonLockName(allocator);
        defer allocator.free(current_lock);
        try requireDistinctDaemon(lock, current_lock);
        if (!lockPresent(allocator, lock)) return;
        const event_name = try std.fmt.allocPrint(allocator, "{s}-shutdown", .{lock});
        defer allocator.free(event_name);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, event_name);
        defer allocator.free(wide);
        const handle = c.OpenEventW(c.EVENT_MODIFY_STATE | c.SYNCHRONIZE, 0, wide.ptr);
        if (handle == null) return error.WorkspaceDaemonUnreachable;
        defer _ = c.CloseHandle(handle);
        if (c.SetEvent(handle) == 0) return error.WorkspaceDaemonStopFailed;
        var waited: i64 = 0;
        while (waited < daemon_stop_timeout_ms) : (waited += 100) {
            if (!lockPresent(allocator, lock)) return;
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
        if (lockPresent(allocator, lock)) return error.WorkspaceDaemonStopTimedOut;
    }

    pub fn recycle(allocator: std.mem.Allocator, path: []const u8) !void {
        const raw = try std.unicode.utf8ToUtf16LeAlloc(allocator, path);
        defer allocator.free(raw);
        const from = try allocator.alloc(u16, raw.len + 2);
        defer allocator.free(from);
        @memcpy(from[0..raw.len], raw);
        from[raw.len] = 0;
        from[raw.len + 1] = 0;
        var operation: c.SHFILEOPSTRUCTW = .{
            .hwnd = null,
            .wFunc = c.FO_DELETE,
            .pFrom = from.ptr,
            .pTo = null,
            .fFlags = recycle_flags,
            .fAnyOperationsAborted = 0,
            .hNameMappings = null,
            .lpszProgressTitle = null,
        };
        if (c.SHFileOperationW(&operation) != 0 or operation.fAnyOperationsAborted != 0)
            return error.WorkspaceRecycleFailed;
        if (Lifecycle.directoryExists(path)) return error.WorkspaceRecycleFailed;
    }

    pub fn killSessions(allocator: std.mem.Allocator, ids: []const []u8) usize {
        if (ids.len == 0) return 0;
        const zmx = std.process.getEnvVarOwned(allocator, "GRAPHCODE_ZMX") catch
            allocator.dupe(u8, "zmx.exe") catch return 0;
        defer allocator.free(zmx);
        const argv = killArgv(allocator, zmx, ids) catch return 0;
        defer freeKillArgv(allocator, argv);
        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        _ = child.spawnAndWait() catch return 0;
        return ids.len;
    }

    fn lockPresent(allocator: std.mem.Allocator, lock: []const u8) bool {
        const wide = std.unicode.utf8ToUtf16LeAllocZ(allocator, lock) catch return false;
        defer allocator.free(wide);
        const handle = c.OpenMutexW(c.SYNCHRONIZE, 0, wide.ptr);
        if (handle == null) return false;
        _ = c.CloseHandle(handle);
        return true;
    }
};

pub fn deleteRecoverably(
    allocator: std.mem.Allocator,
    path: []const u8,
    current_identity: []const u8,
) !Report {
    return deleteRecoverablyWith(Live, allocator, path, current_identity);
}

const Step = enum { stage, collect, daemon, recycle, kill, rollback };

const Fixture = struct {
    var steps: [16]Step = undefined;
    var count: usize = 0;
    var renames: usize = 0;
    var fail_stage = false;
    var fail_collect = false;
    var fail_collect_memory = false;
    var fail_daemon = false;
    var fail_recycle = false;
    var fail_rollback = false;
    var staged: [512]u8 = undefined;
    var staged_len: usize = 0;

    fn reset() void {
        count = 0;
        renames = 0;
        fail_stage = false;
        fail_collect = false;
        fail_collect_memory = false;
        fail_daemon = false;
        fail_recycle = false;
        fail_rollback = false;
        staged_len = 0;
    }

    fn record(step: Step) void {
        if (count < steps.len) steps[count] = step;
        count += 1;
    }

    fn taken() []const Step {
        return steps[0..@min(count, steps.len)];
    }

    fn pid() u32 {
        return 4242;
    }

    fn rename(allocator: std.mem.Allocator, source: []const u8, destination: []const u8) !void {
        _ = allocator;
        _ = source;
        renames += 1;
        if (renames == 1) {
            record(.stage);
            @memcpy(staged[0..destination.len], destination);
            staged_len = destination.len;
            if (fail_stage) return error.WorkspaceRenameFailed;
            return;
        }
        record(.rollback);
        if (fail_rollback) return error.WorkspaceRenameFailed;
    }

    fn collectSessions(allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
        _ = path;
        record(.collect);
        if (fail_collect_memory) return error.OutOfMemory;
        if (fail_collect) return error.MetadataReadFailed;
        const ids = try allocator.alloc([]u8, 2);
        var owned: usize = 0;
        errdefer {
            for (ids[0..owned]) |id| allocator.free(id);
            allocator.free(ids);
        }
        for (ids, [_][]const u8{
            "11111111-1111-4111-8111-111111111111",
            "22222222-2222-4222-8222-222222222222",
        }) |*slot, value| {
            slot.* = try allocator.dupe(u8, value);
            owned += 1;
        }
        return ids;
    }

    fn stopDaemon(allocator: std.mem.Allocator, path: []const u8, current_identity: []const u8) !void {
        _ = allocator;
        _ = path;
        _ = current_identity;
        record(.daemon);
        if (fail_daemon) return error.WorkspaceDaemonStopTimedOut;
    }

    fn recycle(allocator: std.mem.Allocator, path: []const u8) !void {
        _ = allocator;
        _ = path;
        record(.recycle);
        if (fail_recycle) return error.WorkspaceRecycleFailed;
    }

    fn killSessions(allocator: std.mem.Allocator, ids: []const []u8) usize {
        _ = allocator;
        record(.kill);
        return ids.len;
    }
};

const fixture_path = "C:\\fixture\\.graphcode-alpha";
const fixture_current = "c:/fixture/.graphcode";

test "workspace teardown stages before stopping the daemon and kills sessions only after the move" {
    const allocator = std.testing.allocator;
    Fixture.reset();
    var report = try deleteRecoverablyWith(Fixture, allocator, fixture_path, fixture_current);
    defer report.deinit(allocator);
    try std.testing.expectEqual(Outcome.deleted, report.outcome);
    try std.testing.expectEqual(@as(?anyerror, null), report.cause);
    try std.testing.expect(report.sessions_known);
    try std.testing.expectEqual(@as(usize, 2), report.sessions_targeted);
    try std.testing.expectEqualSlices(
        Step,
        &.{ .stage, .collect, .daemon, .recycle, .kill },
        Fixture.taken(),
    );
    try std.testing.expectEqual(@as(usize, 1), Fixture.renames);
}

test "workspace teardown refuses with no effect when the staging rename fails" {
    const allocator = std.testing.allocator;
    Fixture.reset();
    Fixture.fail_stage = true;
    var report = try deleteRecoverablyWith(Fixture, allocator, fixture_path, fixture_current);
    defer report.deinit(allocator);
    try std.testing.expectEqual(Outcome.refused, report.outcome);
    try std.testing.expectEqual(@as(?anyerror, error.WorkspaceRenameFailed), report.cause);
    try std.testing.expectEqual(@as(?[]u8, null), report.staged_path);
    try std.testing.expectEqualSlices(Step, &.{.stage}, Fixture.taken());
}

test "workspace teardown restores the workspace and kills nothing when the daemon does not stop" {
    const allocator = std.testing.allocator;
    Fixture.reset();
    Fixture.fail_daemon = true;
    var report = try deleteRecoverablyWith(Fixture, allocator, fixture_path, fixture_current);
    defer report.deinit(allocator);
    try std.testing.expectEqual(Outcome.refused, report.outcome);
    try std.testing.expectEqual(@as(?anyerror, error.WorkspaceDaemonStopTimedOut), report.cause);
    try std.testing.expectEqualSlices(
        Step,
        &.{ .stage, .collect, .daemon, .rollback },
        Fixture.taken(),
    );
    try std.testing.expectEqual(@as(usize, 2), Fixture.renames);
}

test "workspace teardown rolls back a failed recycle and reports the stopped daemon only" {
    const allocator = std.testing.allocator;
    Fixture.reset();
    Fixture.fail_recycle = true;
    var report = try deleteRecoverablyWith(Fixture, allocator, fixture_path, fixture_current);
    defer report.deinit(allocator);
    try std.testing.expectEqual(Outcome.rolled_back, report.outcome);
    try std.testing.expectEqual(@as(?anyerror, error.WorkspaceRecycleFailed), report.cause);
    try std.testing.expectEqual(@as(usize, 0), report.sessions_targeted);
    try std.testing.expectEqualSlices(
        Step,
        &.{ .stage, .collect, .daemon, .recycle, .rollback },
        Fixture.taken(),
    );
    const message = try statusMessage(allocator, report);
    defer allocator.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, "restored") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "daemon") != null);
}

test "workspace teardown names the staged folder when the rollback also fails" {
    const allocator = std.testing.allocator;
    Fixture.reset();
    Fixture.fail_recycle = true;
    Fixture.fail_rollback = true;
    var report = try deleteRecoverablyWith(Fixture, allocator, fixture_path, fixture_current);
    defer report.deinit(allocator);
    try std.testing.expectEqual(Outcome.stranded, report.outcome);
    try std.testing.expectEqual(@as(usize, 0), report.sessions_targeted);
    const staged = report.staged_path orelse return error.MissingStagedPath;
    try std.testing.expectEqualStrings(Fixture.staged[0..Fixture.staged_len], staged);
    const message = try statusMessage(allocator, report);
    defer allocator.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, staged) != null);
}

test "workspace teardown still deletes when the saved sessions cannot be read" {
    const allocator = std.testing.allocator;
    Fixture.reset();
    Fixture.fail_collect = true;
    var report = try deleteRecoverablyWith(Fixture, allocator, fixture_path, fixture_current);
    defer report.deinit(allocator);
    try std.testing.expectEqual(Outcome.deleted, report.outcome);
    try std.testing.expect(!report.sessions_known);
    try std.testing.expectEqual(@as(usize, 0), report.sessions_targeted);
    try std.testing.expectEqualSlices(
        Step,
        &.{ .stage, .collect, .daemon, .recycle },
        Fixture.taken(),
    );
    const message = try statusMessage(allocator, report);
    defer allocator.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, "may still be running") != null);
}

test "workspace teardown releases every partial allocation on failure" {
    const Probe = struct {
        fn run(failing: std.mem.Allocator) anyerror!void {
            Fixture.reset();
            var report = try deleteRecoverablyWith(Fixture, failing, fixture_path, fixture_current);
            defer report.deinit(failing);
            try std.testing.expectEqual(Outcome.deleted, report.outcome);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

test "workspace teardown retains recovery path after session allocation and rollback failure" {
    const allocator = std.testing.allocator;
    Fixture.reset();
    Fixture.fail_collect_memory = true;
    Fixture.fail_rollback = true;
    var report = try deleteRecoverablyWith(Fixture, allocator, fixture_path, fixture_current);
    defer report.deinit(allocator);
    try std.testing.expectEqual(Outcome.stranded, report.outcome);
    try std.testing.expectEqual(@as(?anyerror, error.OutOfMemory), report.cause);
    try std.testing.expect(!report.sessions_known);
    try std.testing.expectEqual(@as(usize, 0), report.sessions_targeted);
    try std.testing.expectEqualSlices(Step, &.{ .stage, .collect, .rollback }, Fixture.taken());
    const staged = report.staged_path orelse return error.MissingStagedPath;
    try std.testing.expectEqualStrings(Fixture.staged[0..Fixture.staged_len], staged);
    @memset(Fixture.staged[0..Fixture.staged_len], 'x');
    try std.testing.expectEqualStrings("C:\\fixture\\.gc-deleting-4242-.graphcode-alpha", staged);
    const message = try statusMessage(allocator, report);
    defer allocator.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, staged) != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "memory allocation failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "No sessions were ended") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "daemon is stopped") == null);
}

test "workspace teardown restores after session allocation failure" {
    Fixture.reset();
    Fixture.fail_collect_memory = true;
    try std.testing.expectError(
        error.OutOfMemory,
        deleteRecoverablyWith(Fixture, std.testing.allocator, fixture_path, fixture_current),
    );
    try std.testing.expectEqualSlices(Step, &.{ .stage, .collect, .rollback }, Fixture.taken());
}

test "workspace staging name is never itself a discoverable workspace" {
    const allocator = std.testing.allocator;
    const staged = try stagingPath(allocator, fixture_path, 4242);
    defer allocator.free(staged);
    const name = std.fs.path.basenameWindows(staged);
    try std.testing.expect(!std.mem.startsWith(u8, name, Lifecycle.directory_prefix));
    try std.testing.expect(!std.mem.eql(u8, name, Lifecycle.default_directory_name));
    try std.testing.expect(std.mem.startsWith(u8, name, staging_prefix));
    try std.testing.expect(std.mem.endsWith(u8, name, ".graphcode-alpha"));
    try std.testing.expectEqualStrings(
        "C:\\fixture",
        std.fs.path.dirnameWindows(staged).?,
    );
    try std.testing.expectError(error.InvalidWorkspacePath, stagingPath(allocator, "C:\\", 1));
}

test "workspace teardown refuses a daemon target that resolves to the current workspace" {
    try requireDistinctDaemon("Global\\graphcode-daemon-S-1-aaaa", "Global\\graphcode-daemon-S-1-bbbb");
    try std.testing.expectError(
        error.WorkspaceDaemonIdentityMatch,
        requireDistinctDaemon("Global\\graphcode-daemon-S-1-aaaa", "Global\\graphcode-daemon-S-1-aaaa"),
    );
}

test "workspace daemon names separate distinct support directories and join lexical aliases" {
    const allocator = std.testing.allocator;
    const alpha = try DaemonClient.daemonLockNameFor(allocator, "C:\\fixture\\.graphcode-alpha");
    defer allocator.free(alpha);
    const beta = try DaemonClient.daemonLockNameFor(allocator, "C:\\fixture\\.graphcode-beta");
    defer allocator.free(beta);
    const alias = try DaemonClient.daemonLockNameFor(allocator, "C:\\fixture\\.\\.graphcode-alpha");
    defer allocator.free(alias);
    const trailing = try DaemonClient.daemonLockNameFor(allocator, "C:\\fixture\\.graphcode-alpha\\");
    defer allocator.free(trailing);
    try std.testing.expect(!std.mem.eql(u8, alpha, beta));
    try std.testing.expectEqualStrings(alpha, alias);
    // GetFullPathNameW keeps a trailing separator, so the daemon name would differ; the
    // teardown trims one off before deriving rather than addressing a daemon nobody owns.
    try std.testing.expect(!std.mem.eql(u8, alpha, trailing));
    try std.testing.expect(std.mem.startsWith(u8, alpha, "Global\\graphcode-daemon-"));
}

test "workspace recycle always allows undo" {
    try std.testing.expect(recycle_flags & c.FOF_ALLOWUNDO != 0);
    try std.testing.expect(recycle_flags & c.FOF_NOCONFIRMATION != 0);
    try std.testing.expectEqual(@as(c.UINT, c.FO_DELETE), @as(c.UINT, c.FO_DELETE));
}

test "workspace session kill forces every saved id in one invocation" {
    const allocator = std.testing.allocator;
    var ids = [_][]u8{ @constCast("alpha-id"), @constCast("graphcode-beta-id") };
    const argv = try killArgv(allocator, "C:\\tools\\zmx.exe", &ids);
    defer freeKillArgv(allocator, argv);
    try std.testing.expectEqual(@as(usize, 5), argv.len);
    try std.testing.expectEqualStrings("C:\\tools\\zmx.exe", argv[0]);
    try std.testing.expectEqualStrings("kill", argv[1]);
    try std.testing.expectEqualStrings("graphcode-alpha-id", argv[2]);
    try std.testing.expectEqualStrings("graphcode-beta-id", argv[3]);
    try std.testing.expectEqualStrings("--force", argv[4]);

    const Probe = struct {
        fn run(failing: std.mem.Allocator, input: []const []u8) !void {
            const staged = try killArgv(failing, "zmx.exe", input);
            defer freeKillArgv(failing, staged);
            try std.testing.expectEqualStrings("graphcode-alpha-id", staged[2]);
            try std.testing.expectEqualStrings("graphcode-beta-id", staged[3]);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Probe.run, .{&ids});
}

test "workspace session ids come from saved graphs and skip sidecars and unreadable files" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir("projects");
    try temporary.dir.writeFile(.{
        .sub_path = "projects\\alpha.json",
        .data =
        \\{"id":"33333333-3333-4333-8333-333333333333","project":{"path":"C:\\work\\alpha","name":"Alpha","lastOpenedAt":1},"nodes":[{"id":"11111111-1111-4111-8111-111111111111","title":"One","loopType":"manual"},{"id":"22222222-2222-4222-8222-222222222222","title":"Two","loopType":"manual"}],"edges":[]}
        ,
    });
    try temporary.dir.writeFile(.{ .sub_path = "projects\\room.mailroom.json", .data = "[]" });
    try temporary.dir.writeFile(.{ .sub_path = "projects\\broken.json", .data = "{" });
    try temporary.dir.writeFile(.{ .sub_path = "projects\\notes.txt", .data = "ignored" });
    const path = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);
    const ids = try collectSessionIds(allocator, path);
    defer freeSessionIds(allocator, ids);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    var seen_first = false;
    var seen_second = false;
    for (ids) |id| {
        if (std.mem.eql(u8, id, "11111111-1111-4111-8111-111111111111")) seen_first = true;
        if (std.mem.eql(u8, id, "22222222-2222-4222-8222-222222222222")) seen_second = true;
    }
    try std.testing.expect(seen_first and seen_second);
}

test "workspace session ids are empty for a workspace that saved nothing" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);
    const ids = try collectSessionIds(allocator, path);
    defer freeSessionIds(allocator, ids);
    try std.testing.expectEqual(@as(usize, 0), ids.len);
}

test "workspace teardown confirmation says what is ended and that the folder is recoverable" {
    try std.testing.expect(std.mem.indexOf(u8, confirmation_text, "Recycle Bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, confirmation_text, "recoverable") != null);
    try std.testing.expect(std.mem.indexOf(u8, confirmation_text, "daemon") != null);
    try std.testing.expect(std.mem.indexOf(u8, confirmation_text, "sessions") != null);
    try std.testing.expect(std.mem.indexOf(u8, confirmation_text, "permanently") == null);
}
