const std = @import("std");
const Lifecycle = @import("WorkspaceLifecycle.zig");

pub const WindowState = enum { closed, open, unidentified, unavailable };
pub const Refusal = enum { none, default, current, open, unidentified, unavailable };
pub const SummaryFailure = enum { unreadable, invalid, duplicate, limit, location, cancelled, previous_scan, memory, worker };
pub const Counts = struct { projects: usize = 0, loops: usize = 0 };
pub const Summary = union(enum) {
    loading,
    missing,
    live_unavailable,
    saved: Counts,
    failed: SummaryFailure,
};
pub const delete_reason = "Delete is unavailable here until recoverable deletion with daemon/session teardown is implemented.";

pub const Row = struct {
    workspace: Lifecycle.Workspace,
    is_current: bool,
    window: WindowState,
    summary: Summary,

    pub fn refusal(self: Row) Refusal {
        if (self.workspace.is_default) return .default;
        if (self.is_current) return .current;
        return switch (self.window) {
            .closed => .none,
            .open => .open,
            .unidentified => .unidentified,
            .unavailable => .unavailable,
        };
    }

    pub fn canOpen(self: Row) bool {
        return self.is_current or self.window == .open or self.window == .closed;
    }
};

pub const ActionKind = enum { open, rename, new };
pub const Action = struct {
    kind: ActionKind,
    target: ?Lifecycle.Workspace = null,

    pub fn deinit(self: *Action, allocator: std.mem.Allocator) void {
        if (self.target) |*target| target.deinit(allocator);
        self.* = undefined;
    }
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    rows: []Row,

    pub fn init(allocator: std.mem.Allocator, workspaces: []const Lifecycle.Workspace, current: []const u8, windows: []const WindowState) !Model {
        if (workspaces.len != windows.len) return error.InvalidWorkspaceStates;
        const rows = try allocator.alloc(Row, workspaces.len);
        var count: usize = 0;
        errdefer {
            for (rows[0..count]) |*row| row.workspace.deinit(allocator);
            allocator.free(rows);
        }
        for (workspaces, windows, rows) |workspace, window, *row| {
            const owned = try Lifecycle.copyWorkspace(allocator, workspace);
            const is_current = std.mem.eql(u8, owned.identity, current);
            row.* = .{ .workspace = owned, .is_current = is_current, .window = window, .summary = if (is_current) .live_unavailable else .loading };
            count += 1;
        }
        return .{ .allocator = allocator, .rows = rows };
    }

    pub fn deinit(self: *Model) void {
        for (self.rows) |*row| row.workspace.deinit(self.allocator);
        self.allocator.free(self.rows);
        self.* = undefined;
    }

    pub fn capture(self: *const Model, kind: ActionKind, selection: ?usize) !Action {
        if (kind == .new) return .{ .kind = .new };
        const index = selection orelse return error.NoWorkspaceSelected;
        if (index >= self.rows.len) return error.NoWorkspaceSelected;
        const row = self.rows[index];
        if (kind == .rename) try requireRename(row.refusal());
        if (kind == .open and !row.canOpen()) return error.UnidentifiedWorkspaceWindow;
        return .{ .kind = kind, .target = try Lifecycle.copyWorkspace(self.allocator, row.workspace) };
    }
};

fn requireRename(refusal: Refusal) !void {
    return switch (refusal) {
        .none => {},
        .default => error.DefaultWorkspace,
        .current => error.CurrentWorkspace,
        .open => error.WorkspaceInUse,
        .unidentified, .unavailable => error.UnidentifiedWorkspaceWindow,
    };
}

pub fn validateTarget(allocator: std.mem.Allocator, action: Action, current_identity: []const u8, default_identity: []const u8) !void {
    if (action.kind == .new) {
        if (action.target != null) return error.WorkspaceIdentityChanged;
        return;
    }
    const target = action.target orelse return error.NoWorkspaceSelected;
    const identity = try Lifecycle.pathIdentity(allocator, target.path);
    defer allocator.free(identity);
    if (!std.mem.eql(u8, identity, target.identity)) return error.WorkspaceIdentityChanged;
    const is_default = std.mem.eql(u8, identity, default_identity);
    if (is_default != target.is_default) return error.WorkspaceIdentityChanged;
    if (action.kind == .rename) {
        if (is_default) return error.DefaultWorkspace;
        if (std.mem.eql(u8, identity, current_identity)) return error.CurrentWorkspace;
    }
}

pub fn refusalText(refusal: Refusal) []const u8 {
    return switch (refusal) {
        .none => "Closed",
        .default => "Default workspace - cannot rename",
        .current => "This window - cannot rename",
        .open => "Open elsewhere - cannot rename",
        .unidentified => "Older/unidentified window - close it before changing workspaces",
        .unavailable => "Window ownership unavailable - actions blocked",
    };
}

pub fn summaryText(allocator: std.mem.Allocator, summary: Summary) ![]u8 {
    return switch (summary) {
        .saved => |counts| std.fmt.allocPrint(allocator, "Saved: {d} projects / {d} top-level loops", .{ counts.projects, counts.loops }),
        else => allocator.dupe(u8, switch (summary) {
            .loading => "Reading saved summary...",
            .missing => "No saved summary available",
            .live_unavailable => "Live content unavailable",
            .failed => |reason| switch (reason) {
                .unreadable => "Saved summary unavailable: read failed",
                .invalid => "Saved summary unavailable: invalid metadata",
                .duplicate => "Saved summary unavailable: duplicate project records",
                .limit => "Saved summary unavailable: scan limit exceeded",
                .location => "Saved summary unavailable: unsupported location",
                .cancelled => "Saved summary cancelled",
                .previous_scan => "Previous summary read is finishing",
                .memory => "Saved summary unavailable: allocation failed",
                .worker => "Saved summary unavailable: worker could not start",
            },
            .saved => unreachable,
        }),
    };
}

pub fn rowText(allocator: std.mem.Allocator, row: Row) ![]u8 {
    const summary = try summaryText(allocator, row.summary);
    defer allocator.free(summary);
    return std.fmt.allocPrint(allocator, "{s} | {s} | {s}{s}{s}", .{
        row.workspace.name,
        summary,
        if (row.is_current) "This window; " else "",
        if (row.window == .open and !row.is_current) "Open elsewhere; " else "",
        refusalText(row.refusal()),
    });
}

pub const max_entries = 256;
pub const max_file_bytes = 1024 * 1024;
pub const max_workspace_bytes = 8 * 1024 * 1024;
pub const max_dialog_bytes = 32 * 1024 * 1024;
pub const parser_bytes = 8 * 1024 * 1024;
pub const max_depth = 128;

const Record = struct {
    project: []u8,
    loops: usize,
};

pub fn checkDepth(bytes: []const u8) !void {
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (bytes) |byte| {
        if (quoted) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                quoted = false;
            }
        } else switch (byte) {
            '"' => quoted = true,
            '{', '[' => {
                depth += 1;
                if (depth > max_depth) return error.LimitExceeded;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidMetadata;
                depth -= 1;
            },
            else => {},
        }
    }
}

fn string(value: ?std.json.Value) ![]const u8 {
    const item = value orelse return error.InvalidMetadata;
    if (item != .string or item.string.len == 0) return error.InvalidMetadata;
    return item.string;
}

fn uuid(value: ?std.json.Value) ![]const u8 {
    const text = try string(value);
    if (text.len != 36) return error.InvalidMetadata;
    for (text, 0..) |byte, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (byte != '-') return error.InvalidMetadata;
        } else if (!std.ascii.isHex(byte)) return error.InvalidMetadata;
    }
    return text;
}

/// Reads only the persisted graph projection needed for saved top-level counts.
/// This is not a LoopGraph decoder or a live workspace inventory.
fn parseRecord(allocator: std.mem.Allocator, bytes: []const u8, name: []const u8) !?Record {
    if (bytes.len > max_file_bytes) return error.LimitExceeded;
    try checkDepth(bytes);
    const scratch = try allocator.alloc(u8, parser_bytes);
    defer allocator.free(scratch);
    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    const parsed = std.json.parseFromSlice(std.json.Value, fixed.allocator(), bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.LimitExceeded,
        else => return error.InvalidMetadata,
    };
    defer parsed.deinit();
    if (parsed.value == .array and std.mem.endsWith(u8, name, ".mailroom.json")) return null;
    if (parsed.value != .object) return error.InvalidMetadata;
    const object = parsed.value.object;
    _ = try uuid(object.get("id"));
    const project = object.get("project") orelse return error.InvalidMetadata;
    if (project != .object) return error.InvalidMetadata;
    const path = try string(project.object.get("path"));
    _ = try string(project.object.get("name"));
    const date = project.object.get("lastOpenedAt") orelse return error.InvalidMetadata;
    if (date != .integer and date != .float) return error.InvalidMetadata;
    const nodes = object.get("nodes") orelse return error.InvalidMetadata;
    const edges = object.get("edges") orelse return error.InvalidMetadata;
    if (nodes != .array or edges != .array) return error.InvalidMetadata;
    var ids = std.StringHashMap(void).init(fixed.allocator());
    for (nodes.array.items) |node| {
        if (node != .object) return error.InvalidMetadata;
        const id = try uuid(node.object.get("id"));
        _ = try string(node.object.get("title"));
        _ = try string(node.object.get("loopType"));
        const entry = ids.getOrPut(id) catch return error.LimitExceeded;
        if (entry.found_existing) return error.InvalidMetadata;
    }
    for (edges.array.items) |edge| {
        if (edge != .object) return error.InvalidMetadata;
        _ = try uuid(edge.object.get("id"));
        _ = try uuid(edge.object.get("from"));
        _ = try uuid(edge.object.get("to"));
    }
    return .{ .project = try allocator.dupe(u8, path), .loops = nodes.array.items.len };
}

pub const Budget = struct {
    remaining: usize = max_dialog_bytes,

    pub fn take(self: *Budget, workspace_remaining: *usize, size: u64) !usize {
        if (size > max_file_bytes or size > workspace_remaining.* or size > self.remaining)
            return error.LimitExceeded;
        const count: usize = @intCast(size);
        self.remaining -= count;
        workspace_remaining.* -= count;
        return count;
    }
};

const w = std.os.windows;
extern "kernel32" fn GetDriveTypeW(root: [*:0]const u16) callconv(.winapi) u32;

pub fn localPathSupported(path: []const u8) bool {
    if (path.len < 3 or !std.ascii.isAlphabetic(path[0]) or path[1] != ':' or
        (path[2] != '\\' and path[2] != '/') or !std.unicode.utf8ValidateSlice(path)) return false;
    var parts = std.mem.tokenizeAny(u8, path[3..], "\\/");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or
            std.mem.indexOfAny(u8, part, ":\x00") != null) return false;
    }
    return true;
}

fn basicInformation(handle: w.HANDLE) !w.FILE_BASIC_INFORMATION {
    var info: w.FILE_BASIC_INFORMATION = undefined;
    var io: w.IO_STATUS_BLOCK = undefined;
    const status = w.ntdll.NtQueryInformationFile(handle, &io, &info, @sizeOf(@TypeOf(info)), .FileBasicInformation);
    if (status != .SUCCESS) return error.MetadataReadFailed;
    if (info.FileAttributes & w.FILE_ATTRIBUTE_REPARSE_POINT != 0) return error.UnsupportedLocation;
    return info;
}

fn openLocalRoot(allocator: std.mem.Allocator, path: []const u8) !std.fs.Dir {
    if (!localPathSupported(path)) return error.UnsupportedLocation;
    const drive = [_:0]u16{ path[0], ':', '\\' };
    if (GetDriveTypeW(&drive) != 3) return error.UnsupportedLocation; // DRIVE_FIXED only.
    var current = try std.fs.openDirAbsolute(path[0..3], .{ .no_follow = true });
    errdefer current.close();
    _ = try basicInformation(current.fd);
    var parts = std.mem.tokenizeAny(u8, path[3..], "\\/");
    while (parts.next()) |part| {
        const next = try openChild(allocator, current, part, true);
        current.close();
        current = .{ .fd = next };
    }
    return current;
}

fn openChild(allocator: std.mem.Allocator, directory: std.fs.Dir, name: []const u8, is_directory: bool) !w.HANDLE {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
    defer allocator.free(wide);
    if (wide.len > std.math.maxInt(u16) / 2) return error.UnsupportedLocation;
    var nt_name = w.UNICODE_STRING{
        .Length = @intCast(wide.len * 2),
        .MaximumLength = @intCast(wide.len * 2),
        .Buffer = wide.ptr,
    };
    var attributes = w.OBJECT_ATTRIBUTES{
        .Length = @sizeOf(w.OBJECT_ATTRIBUTES),
        .RootDirectory = directory.fd,
        .Attributes = 0,
        .ObjectName = &nt_name,
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };
    var handle: w.HANDLE = undefined;
    var io: w.IO_STATUS_BLOCK = undefined;
    const status = w.ntdll.NtCreateFile(
        &handle,
        w.GENERIC_READ | w.SYNCHRONIZE,
        &attributes,
        &io,
        null,
        0,
        w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
        w.FILE_OPEN,
        w.FILE_OPEN_REPARSE_POINT | w.FILE_SYNCHRONOUS_IO_NONALERT |
            @as(u32, if (is_directory) w.FILE_DIRECTORY_FILE else w.FILE_NON_DIRECTORY_FILE),
        null,
        0,
    );
    if (status != .SUCCESS) return switch (status) {
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => error.FileNotFound,
        else => error.MetadataReadFailed,
    };
    errdefer w.CloseHandle(handle);
    _ = try basicInformation(handle);
    return handle;
}

pub fn scanSummary(allocator: std.mem.Allocator, path: []const u8, budget: *Budget, cancelled: *const std.atomic.Value(bool)) !Summary {
    return scanSummaryInner(allocator, path, budget, cancelled) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.LimitExceeded => .{ .failed = .limit },
        error.InvalidMetadata => .{ .failed = .invalid },
        error.DuplicateProject => .{ .failed = .duplicate },
        error.UnsupportedLocation => .{ .failed = .location },
        error.Cancelled => .{ .failed = .cancelled },
        else => .{ .failed = .unreadable },
    };
}

fn scanSummaryInner(allocator: std.mem.Allocator, path: []const u8, budget: *Budget, cancelled: *const std.atomic.Value(bool)) !Summary {
    if (cancelled.load(.acquire)) return error.Cancelled;
    var root = try openLocalRoot(allocator, path);
    defer root.close();
    var projects = std.fs.Dir{ .fd = openChild(allocator, root, "projects", true) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    } };
    defer projects.close();
    var iterator = projects.iterate();
    var entries: usize = 0;
    var remaining: usize = max_workspace_bytes;
    var counts = Counts{};
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        seen.deinit();
    }
    while (try iterator.next()) |entry| {
        if (cancelled.load(.acquire)) return error.Cancelled;
        entries += 1;
        if (entries > max_entries) return error.LimitExceeded;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (entry.kind != .file) return error.UnsupportedLocation;
        const file = std.fs.File{ .handle = try openChild(allocator, projects, entry.name, false) };
        defer file.close();
        const before = try file.stat();
        if (before.kind != .file) return error.UnsupportedLocation;
        const size = try budget.take(&remaining, before.size);
        const bytes = try allocator.alloc(u8, size);
        defer allocator.free(bytes);
        if (try file.readAll(bytes) != size) return error.MetadataReadFailed;
        const after = try file.stat();
        if (before.size != after.size or before.mtime != after.mtime or before.ctime != after.ctime)
            return error.MetadataReadFailed;
        if (cancelled.load(.acquire)) return error.Cancelled;
        const record = try parseRecord(allocator, bytes, entry.name) orelse continue;
        const inserted = seen.getOrPut(record.project) catch |err| {
            allocator.free(record.project);
            return err;
        };
        if (inserted.found_existing) {
            allocator.free(record.project);
            return error.DuplicateProject;
        }
        counts.projects += 1;
        counts.loops += record.loops;
    }
    return .{ .saved = counts };
}

const DiskReader = struct {
    const read = scanSummary;
};

const SummaryJob = struct {
    allocator: std.mem.Allocator,
    snapshot: Model,
    thread: ?std.Thread = null,
    mutex: std.Thread.Mutex = .{},
    cancelled: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),

    fn run(comptime Reader: type, self: *SummaryJob) void {
        var budget = Budget{};
        for (self.snapshot.rows, 0..) |row, i| {
            if (row.is_current) continue;
            const summary: Summary = if (self.cancelled.load(.acquire))
                .{ .failed = .cancelled }
            else
                Reader.read(self.allocator, row.workspace.path, &budget, &self.cancelled) catch .{ .failed = .memory };
            self.mutex.lock();
            self.snapshot.rows[i].summary = summary;
            self.mutex.unlock();
        }
        self.finished.store(true, .release);
    }

    fn destroy(self: *SummaryJob) void {
        if (self.thread) |thread| thread.join();
        self.snapshot.deinit();
        self.allocator.destroy(self);
    }
};

/// Stored by App, not the form. Shutdown must drain before destroying App's allocator.
pub const SummaryWork = struct {
    job: ?*SummaryJob = null,

    pub fn start(self: *SummaryWork, model: *Model) !void {
        try self.startWith(DiskReader, model);
    }

    fn startWith(self: *SummaryWork, comptime Reader: type, model: *Model) !void {
        _ = self.reap();
        if (self.job != null) {
            for (model.rows) |*row| if (!row.is_current) {
                row.summary = .{ .failed = .previous_scan };
            };
            return;
        }
        const allocator = model.allocator;
        const job = try allocator.create(SummaryJob);
        errdefer allocator.destroy(job);
        const rows = try allocator.alloc(Row, model.rows.len);
        var count: usize = 0;
        errdefer {
            for (rows[0..count]) |*row| row.workspace.deinit(allocator);
            allocator.free(rows);
        }
        for (model.rows, rows) |row, *copy| {
            copy.* = row;
            copy.workspace = try Lifecycle.copyWorkspace(allocator, row.workspace);
            count += 1;
        }
        job.* = .{ .allocator = allocator, .snapshot = .{ .allocator = allocator, .rows = rows } };
        job.thread = try std.Thread.spawn(.{}, SummaryJob.run, .{ Reader, job });
        self.job = job;
    }

    pub fn cancel(self: *SummaryWork) void {
        if (self.job) |job| job.cancelled.store(true, .release);
    }

    fn copyResults(self: *SummaryWork, model: *Model) void {
        const job = self.job orelse return;
        job.mutex.lock();
        defer job.mutex.unlock();
        for (model.rows) |*row| {
            if (row.summary == .failed and row.summary.failed == .previous_scan) continue;
            for (job.snapshot.rows) |source| {
                if (std.mem.eql(u8, source.workspace.identity, row.workspace.identity)) {
                    row.summary = source.summary;
                    break;
                }
            }
        }
    }

    pub fn poll(self: *SummaryWork, model: *Model) bool {
        const job = self.job orelse return true;
        // Completion must precede the final copy. A later completion waits for
        // the next poll, so no newly published result is discarded by reaping.
        const finished = job.finished.load(.acquire);
        self.copyResults(model);
        if (!finished) return false;
        job.destroy();
        self.job = null;
        return true;
    }

    /// Discard completion only when the closed/replaced form no longer needs it.
    pub fn reap(self: *SummaryWork) bool {
        if (self.job) |job| {
            if (!job.finished.load(.acquire)) return false;
            job.destroy();
            self.job = null;
        }
        return true;
    }

    pub fn drain(self: *SummaryWork) void {
        self.cancel();
        if (self.job) |job| job.destroy();
        self.job = null;
    }
};

pub const Handoff = struct {
    pending: ?Action = null,

    pub fn cancel(self: *Handoff, allocator: std.mem.Allocator) void {
        if (self.pending) |*action| action.deinit(allocator);
        self.pending = null;
    }

    pub fn take(self: *Handoff, reader_drained: bool, modal_active: bool) ?Action {
        if (!reader_drained or modal_active) return null;
        const result = self.pending;
        self.pending = null;
        return result;
    }
};

test "workspace manager rows own captured identity and expose current refusal" {
    const allocator = std.testing.allocator;
    const workspace = Lifecycle.Workspace{
        .name = "outside",
        .path = "C:\\fixture\\outside",
        .identity = "c:/fixture/outside",
        .is_default = false,
    };
    var model = try Model.init(allocator, &.{workspace}, workspace.identity, &.{.closed});
    defer model.deinit();
    try std.testing.expect(model.rows[0].is_current);
    try std.testing.expectEqual(Refusal.current, model.rows[0].refusal());
    try std.testing.expectError(error.CurrentWorkspace, model.capture(.rename, 0));
    try std.testing.expectEqual(Summary.live_unavailable, model.rows[0].summary);
}

test "workspace manager New remains available for zero one and default plus outside current rows" {
    const allocator = std.testing.allocator;
    var empty = try Model.init(allocator, &.{}, "c:/fixture/.graphcode", &.{});
    defer empty.deinit();
    var new_action = try empty.capture(.new, null);
    defer new_action.deinit(allocator);
    try std.testing.expect(new_action.target == null);
    try std.testing.expectError(error.NoWorkspaceSelected, empty.capture(.open, null));
    const default = Lifecycle.Workspace{ .name = "Default", .path = "C:\\fixture\\.graphcode", .identity = "c:/fixture/.graphcode", .is_default = true };
    const closed = [_]WindowState{ .closed, .closed };
    for ([_][]const u8{ default.path, "D:\\Outside" }, 1..) |current, expected_count| {
        var known = try Lifecycle.managerList(allocator, &.{default}, "C:\\fixture", current);
        defer known.deinit(allocator);
        try std.testing.expectEqual(expected_count, known.items.len);
        const identity = try Lifecycle.pathIdentity(allocator, current);
        defer allocator.free(identity);
        var model = try Model.init(allocator, known.items, identity, closed[0..known.items.len]);
        defer model.deinit();
        try std.testing.expect(model.rows[known.items.len - 1].is_current);
        try std.testing.expect(model.rows[0].workspace.is_default);
        var create = try model.capture(.new, null);
        defer create.deinit(allocator);
        var open = try model.capture(.open, known.items.len - 1);
        defer open.deinit(allocator);
        try std.testing.expectEqualStrings(identity, open.target.?.identity);
    }
}

const alpha = Lifecycle.Workspace{ .name = "alpha", .path = "C:\\fixture\\.graphcode-alpha", .identity = "c:/fixture/.graphcode-alpha", .is_default = false };
const beta = Lifecycle.Workspace{ .name = "beta", .path = "C:\\fixture\\.graphcode-beta", .identity = "c:/fixture/.graphcode-beta", .is_default = false };

test "workspace manager captured action outlives source refresh and allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ownedActionCase, .{});
}

fn ownedActionCase(allocator: std.mem.Allocator) !void {
    var source = try Lifecycle.copyWorkspace(allocator, alpha);
    defer source.deinit(allocator);
    var model = try Model.init(allocator, &.{ source, beta }, "c:/elsewhere", &.{ .closed, .open });
    var active = true;
    defer if (active) model.deinit();
    var action = try model.capture(.rename, 0);
    defer action.deinit(allocator);
    @memset(@constCast(source.name), 'x');
    model.deinit();
    active = false;
    try std.testing.expectEqualStrings(alpha.name, action.target.?.name);
    try std.testing.expectEqualStrings(alpha.identity, action.target.?.identity);
    try validateTarget(allocator, action, "c:/elsewhere", "c:/fixture/.graphcode");
}

test "workspace manager fresh target checks reject path default and current drift" {
    var action = Action{ .kind = .rename, .target = alpha };
    try std.testing.expectError(error.CurrentWorkspace, validateTarget(std.testing.allocator, action, alpha.identity, "c:/fixture/.graphcode"));
    try std.testing.expectError(error.WorkspaceIdentityChanged, validateTarget(std.testing.allocator, action, "c:/elsewhere", alpha.identity));
    action.target.?.path = beta.path;
    try std.testing.expectError(error.WorkspaceIdentityChanged, validateTarget(std.testing.allocator, action, "c:/elsewhere", "c:/fixture/.graphcode"));
    try validateTarget(std.testing.allocator, .{ .kind = .new }, "c:/elsewhere", "c:/fixture/.graphcode");
}

test "workspace manager unknown error and refusal states never become zero counts" {
    var def = alpha;
    def.is_default = true;
    var model = try Model.init(std.testing.allocator, &.{ def, beta, alpha, beta }, "c:/elsewhere", &.{ .closed, .open, .unidentified, .unavailable });
    defer model.deinit();
    const refusals = [_]Refusal{ .default, .open, .unidentified, .unavailable };
    for (model.rows, refusals, 0..) |row, refusal, i| {
        try std.testing.expectEqual(refusal, row.refusal());
        try std.testing.expectError(if (i == 0) error.DefaultWorkspace else if (i == 1) error.WorkspaceInUse else error.UnidentifiedWorkspaceWindow, model.capture(.rename, i));
    }
    for ([_]Summary{ .loading, .missing, .live_unavailable, .{ .failed = .invalid }, .{ .failed = .unreadable }, .{ .failed = .limit } }) |summary| {
        const text = try summaryText(std.testing.allocator, summary);
        defer std.testing.allocator.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "0 projects") == null);
    }
    const zero = try summaryText(std.testing.allocator, .{ .saved = .{} });
    defer std.testing.allocator.free(zero);
    try std.testing.expectEqualStrings("Saved: 0 projects / 0 top-level loops", zero);
}

const graph_fixture =
    \\{"id":"11111111-1111-1111-1111-111111111111","project":{"path":"C:\\project","name":"Project","lastOpenedAt":0},"nodes":[{"id":"22222222-2222-2222-2222-222222222222","title":"Loop","loopType":"turnBased","subGraph":{"nodes":[{},{}]}}],"edges":[]}
;

test "workspace manager saved projection counts top level and distinguishes sidecars" {
    const allocator = std.testing.allocator;
    const record = (try parseRecord(allocator, graph_fixture, "legacy.mailroom.json")).?;
    defer allocator.free(record.project);
    try std.testing.expectEqual(@as(usize, 1), record.loops);
    try std.testing.expectEqualStrings("C:\\project", record.project);
    try std.testing.expect((try parseRecord(allocator, "[]", "project.mailroom.json")) == null);
    try std.testing.expectError(error.InvalidMetadata, parseRecord(allocator, "[]", "project.json"));
    for ([_][]const u8{ "not-json", "{}", "{\"id\":12}", "{\"nodes\":[]}", "{\"id\":\"bad\"}" }) |bytes|
        try std.testing.expectError(error.InvalidMetadata, parseRecord(allocator, bytes, "project.json"));
}

test "workspace manager metadata depth and byte budgets enforce exact boundaries" {
    var brackets: [2 * (max_depth + 1)]u8 = undefined;
    @memset(brackets[0..max_depth], '[');
    @memset(brackets[max_depth .. 2 * max_depth], ']');
    try checkDepth(brackets[0 .. 2 * max_depth]);
    @memset(brackets[0 .. max_depth + 1], '[');
    @memset(brackets[max_depth + 1 ..], ']');
    try std.testing.expectError(error.LimitExceeded, checkDepth(&brackets));
    try checkDepth("\"[\\\"{\"");
    var budget = Budget{};
    var workspace: usize = max_workspace_bytes;
    for (0..8) |_| _ = try budget.take(&workspace, max_file_bytes);
    try std.testing.expectEqual(@as(usize, 0), workspace);
    try std.testing.expectError(error.LimitExceeded, budget.take(&workspace, 1));
    workspace = max_workspace_bytes;
    try std.testing.expectError(error.LimitExceeded, budget.take(&workspace, max_file_bytes + 1));
    budget.remaining = 1;
    _ = try budget.take(&workspace, 1);
    try std.testing.expectError(error.LimitExceeded, budget.take(&workspace, 1));
}

test "workspace manager location policy rejects network device relative and dot paths" {
    for ([_][]const u8{ "\\\\server\\share", "\\\\?\\C:\\data", "C:relative", "relative", "C:\\a\\..\\b", "C:\\a\\file:stream", "C:\\a\x00b" }) |path|
        try std.testing.expect(!localPathSupported(path));
    try std.testing.expect(localPathSupported("C:\\fixture\\workspace"));
}

test "workspace manager explicit owned filesystem fixture distinguishes missing empty malformed duplicate and limits" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);
    var budget = Budget{};
    const cancelled = std.atomic.Value(bool).init(false);
    try std.testing.expectEqual(Summary.missing, try scanSummary(allocator, path, &budget, &cancelled));
    try temporary.dir.makeDir("projects");
    try std.testing.expectEqual(Counts{}, (try scanSummary(allocator, path, &budget, &cancelled)).saved);
    try temporary.dir.writeFile(.{ .sub_path = "projects\\valid.json", .data = graph_fixture });
    try temporary.dir.writeFile(.{ .sub_path = "projects\\valid.mailroom.json", .data = "[]" });
    try std.testing.expectEqual(Counts{ .projects = 1, .loops = 1 }, (try scanSummary(allocator, path, &budget, &cancelled)).saved);
    try temporary.dir.writeFile(.{ .sub_path = "projects\\bad.json", .data = "{}" });
    try std.testing.expectEqual(SummaryFailure.invalid, (try scanSummary(allocator, path, &budget, &cancelled)).failed);
    try temporary.dir.writeFile(.{ .sub_path = "projects\\bad.json", .data = graph_fixture });
    try std.testing.expectEqual(SummaryFailure.duplicate, (try scanSummary(allocator, path, &budget, &cancelled)).failed);
    try temporary.dir.deleteFile("projects\\bad.json");
    budget.remaining = graph_fixture.len - 1;
    try std.testing.expectEqual(SummaryFailure.limit, (try scanSummary(allocator, path, &budget, &cancelled)).failed);
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectEqual(SummaryFailure.cancelled, (try scanSummary(allocator, path, &budget, &cancel)).failed);
    const missing_root = try std.fs.path.join(allocator, &.{ path, "missing-workspace" });
    defer allocator.free(missing_root);
    try std.testing.expectEqual(SummaryFailure.unreadable, (try scanSummary(allocator, missing_root, &budget, &cancelled)).failed);
    try std.testing.checkAllAllocationFailures(allocator, summaryAllocationCase, .{path});
}

fn summaryAllocationCase(allocator: std.mem.Allocator, path: []const u8) !void {
    var budget = Budget{};
    const cancelled = std.atomic.Value(bool).init(false);
    try std.testing.expectEqual(Counts{ .projects = 1, .loops = 1 }, (try scanSummary(allocator, path, &budget, &cancelled)).saved);
}

test "workspace manager actual owned worker blocks reopen and handoff until cancel join completes" {
    const Reader = struct {
        var started: std.Thread.ResetEvent = .{};
        var release: std.Thread.ResetEvent = .{};
        var observed_cancel = std.atomic.Value(bool).init(false);

        fn read(_: std.mem.Allocator, path: []const u8, _: *Budget, cancelled: *const std.atomic.Value(bool)) !Summary {
            if (!std.mem.eql(u8, path, alpha.path)) return error.UnexpectedPath;
            started.set();
            try release.timedWait(5 * std.time.ns_per_s);
            observed_cancel.store(cancelled.load(.acquire), .release);
            return .{ .saved = .{ .projects = 1, .loops = 4 } };
        }
    };
    Reader.started.reset();
    Reader.release.reset();
    Reader.observed_cancel.store(false, .release);
    var work = SummaryWork{};
    defer work.drain();
    defer Reader.release.set();
    var model = try Model.init(std.testing.allocator, &.{alpha}, "c:/elsewhere", &.{.closed});
    var model_live = true;
    defer if (model_live) model.deinit();
    try work.startWith(Reader, &model);
    try Reader.started.timedWait(5 * std.time.ns_per_s);
    var handoff = Handoff{ .pending = try model.capture(.rename, 0) };
    defer handoff.cancel(std.testing.allocator);
    const original = work.job;
    model.deinit();
    model_live = false;
    work.cancel();
    try std.testing.expect(!work.reap());
    try std.testing.expect(handoff.take(false, false) == null);
    var reopened = try Model.init(std.testing.allocator, &.{beta}, "c:/elsewhere", &.{.closed});
    defer reopened.deinit();
    try work.startWith(Reader, &reopened);
    try std.testing.expectEqual(original, work.job);
    try std.testing.expectEqual(SummaryFailure.previous_scan, reopened.rows[0].summary.failed);
    Reader.release.set();
    work.drain();
    try std.testing.expect(work.job == null);
    try std.testing.expect(Reader.observed_cancel.load(.acquire));
    try std.testing.expect(handoff.take(true, true) == null);
    var action = handoff.take(true, false).?;
    defer action.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(alpha.path, action.target.?.path);
    try std.testing.expect(handoff.take(true, false) == null);
}

test "workspace manager completion after an earlier copy delivers final snapshot before reaping" {
    const Reader = struct {
        var started: std.Thread.ResetEvent = .{};
        var release: std.Thread.ResetEvent = .{};

        fn read(_: std.mem.Allocator, _: []const u8, _: *Budget, cancelled: *const std.atomic.Value(bool)) !Summary {
            started.set();
            try release.timedWait(5 * std.time.ns_per_s);
            return if (cancelled.load(.acquire))
                .{ .failed = .cancelled }
            else
                .{ .saved = .{ .projects = 1, .loops = 7 } };
        }
    };
    for ([_]bool{ false, true }) |cancel| {
        Reader.started.reset();
        Reader.release.reset();
        var model = try Model.init(std.testing.allocator, &.{alpha}, "c:/elsewhere", &.{.closed});
        defer model.deinit();
        var work = SummaryWork{};
        defer work.drain();
        defer Reader.release.set();
        try work.startWith(Reader, &model);
        try Reader.started.timedWait(5 * std.time.ns_per_s);
        var handoff = Handoff{ .pending = try model.capture(.rename, 0) };
        defer handoff.cancel(std.testing.allocator);
        if (cancel) work.cancel();
        const original = work.job;
        var reopened = try Model.init(std.testing.allocator, &.{alpha}, "c:/elsewhere", &.{.closed});
        defer reopened.deinit();
        try work.startWith(Reader, &reopened);
        try std.testing.expectEqual(original, work.job);
        try std.testing.expectEqual(SummaryFailure.previous_scan, reopened.rows[0].summary.failed);

        try std.testing.expect(!work.poll(&model));
        try std.testing.expect(model.rows[0].summary == .loading);
        try std.testing.expect(handoff.take(false, false) == null);
        Reader.release.set();
        var timer = try std.time.Timer.start();
        while (!work.job.?.finished.load(.acquire)) {
            if (timer.read() > 5 * std.time.ns_per_s) return error.WorkerDidNotFinish;
            std.Thread.sleep(std.time.ns_per_ms);
        }

        try std.testing.expect(work.poll(&model));
        try std.testing.expect(work.job == null);
        const expected: Summary = if (cancel) .{ .failed = .cancelled } else .{ .saved = .{ .projects = 1, .loops = 7 } };
        try std.testing.expectEqualDeep(expected, model.rows[0].summary);
        try std.testing.expectEqual(SummaryFailure.previous_scan, reopened.rows[0].summary.failed);
        try std.testing.expect(handoff.take(true, true) == null);
        if (cancel) {
            handoff.cancel(std.testing.allocator);
            try std.testing.expect(handoff.take(true, false) == null);
        } else {
            var action = handoff.take(true, false).?;
            defer action.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings(alpha.identity, action.target.?.identity);
        }
    }
}

test "workspace manager cancellation discards pending New and Rename without changing rows" {
    var model = try Model.init(std.testing.allocator, &.{alpha}, "c:/elsewhere", &.{.closed});
    defer model.deinit();
    for ([_]ActionKind{ .new, .rename }) |kind| {
        var handoff = Handoff{ .pending = try model.capture(kind, 0) };
        handoff.cancel(std.testing.allocator);
        try std.testing.expect(handoff.take(true, false) == null);
        try std.testing.expectEqualStrings(alpha.identity, model.rows[0].workspace.identity);
        try std.testing.expect(!model.rows[0].is_current);
    }
}

test "workspace manager saved file entry and parser limits cannot return partial counts" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir("projects");
    const path = try temporary.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);
    const cancelled = std.atomic.Value(bool).init(false);
    var budget = Budget{};
    for (0..max_entries) |i| {
        var buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "projects\\entry-{d}.txt", .{i});
        try temporary.dir.writeFile(.{ .sub_path = name, .data = "" });
    }
    try std.testing.expectEqual(Counts{}, (try scanSummary(allocator, path, &budget, &cancelled)).saved);
    try temporary.dir.writeFile(.{ .sub_path = "projects\\extra.txt", .data = "" });
    try std.testing.expectEqual(SummaryFailure.limit, (try scanSummary(allocator, path, &budget, &cancelled)).failed);
    const bytes = try allocator.alloc(u8, max_file_bytes + 1);
    defer allocator.free(bytes);
    @memset(bytes, ' ');
    @memcpy(bytes[0..graph_fixture.len], graph_fixture);
    const record = (try parseRecord(allocator, bytes[0..max_file_bytes], "graph.json")).?;
    defer allocator.free(record.project);
    try std.testing.expectEqual(@as(usize, 1), record.loops);
    try std.testing.expectError(error.LimitExceeded, parseRecord(allocator, bytes, "graph.json"));
    bytes[0] = '[';
    for (0..200_000) |i| @memcpy(bytes[1 + 2 * i ..][0..2], "0,");
    @memcpy(bytes[400_001..][0..2], "0]");
    try std.testing.expectError(error.LimitExceeded, parseRecord(allocator, bytes[0..400_003], "graph.mailroom.json"));
}

test "workspace manager job startup failures release owned snapshots and successful exit is joined" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, jobAllocationCase, .{});
}

fn jobAllocationCase(allocator: std.mem.Allocator) !void {
    const Reader = struct {
        fn read(_: std.mem.Allocator, _: []const u8, _: *Budget, _: *const std.atomic.Value(bool)) !Summary {
            return .{ .saved = .{ .projects = 2, .loops = 3 } };
        }
    };
    var model = try Model.init(allocator, &.{alpha}, "c:/elsewhere", &.{.closed});
    defer model.deinit();
    var work = SummaryWork{};
    defer work.drain();
    try work.startWith(Reader, &model);
    var timer = try std.time.Timer.start();
    while (!work.job.?.finished.load(.acquire)) {
        if (timer.read() > 5 * std.time.ns_per_s) return error.WorkerDidNotFinish;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(work.poll(&model));
    try std.testing.expect(work.job == null);
    try std.testing.expectEqual(Counts{ .projects = 2, .loops = 3 }, model.rows[0].summary.saved);
}
