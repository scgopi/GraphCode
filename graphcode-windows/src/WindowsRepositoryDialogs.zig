const std = @import("std");
const NativeDialogs = @import("WindowsNativeDialogs.zig");
const c = @import("Win32.zig").c;

pub const CloneFields = struct {
    url: []const u8 = "",
    destination: []const u8 = "",
    branch: []const u8 = "",
    depth: []const u8 = "",

    fn values(self: CloneFields) [4][]const u8 {
        return .{ self.url, self.destination, self.branch, self.depth };
    }
};

pub const RemoteFields = struct {
    host: []const u8 = "",
    user: []const u8 = "",
    port: []const u8 = "22",
    path: []const u8 = "",

    fn values(self: RemoteFields) [4][]const u8 {
        return .{ self.host, self.user, self.port, self.path };
    }
};

pub const CloneStatus = enum { ready, cloning, cancelled, finished, failed };
pub const OutputSnapshot = struct { progress_len: usize, stderr_len: usize };

pub const CloneProcess = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    args: []const []u8,
    destination: []u8,
    staging: []u8,
    recent_stderr: [4096]u8 = undefined,
    recent_stderr_len: usize = 0,
    progress: [256]u8 = undefined,
    progress_len: usize = 0,
    output_lock: std.Thread.Mutex = .{},
    finished: bool = false,
    cancelled: bool = false,

    pub fn start(allocator: std.mem.Allocator, fields: CloneFields) !CloneProcess {
        if (try inspectDestination(fields.destination)) return error.DestinationAlreadyExists;
        const staging = try makeStagingPath(allocator, fields.destination);
        errdefer allocator.free(staging);
        const staged_fields = CloneFields{ .url = fields.url, .destination = staging, .branch = fields.branch, .depth = fields.depth };
        const args = try cloneCommand(allocator, staged_fields);
        var child = std.process.Child.init(args, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        const destination = allocator.dupe(u8, fields.destination) catch |err| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            for (args) |arg| allocator.free(arg);
            allocator.free(args);
            return err;
        };

        return .{ .allocator = allocator, .child = child, .args = args, .destination = destination, .staging = staging };
    }

    pub fn cancel(self: *CloneProcess) void {
        self.cancelled = true;
        _ = self.child.kill() catch {};
    }

    pub fn finish(self: *CloneProcess) !CloneStatus {
        if (self.finished) return if (self.cancelled) .cancelled else .finished;
        const term = try self.child.wait();
        self.finished = true;
        const status: CloneStatus = if (self.cancelled) .cancelled else switch (term) {
            .Exited => |code| if (code == 0) .finished else .failed,
            else => .failed,
        };

        self.releaseArgs();
        if (status == .finished) {
            std.fs.cwd().rename(self.staging, self.destination) catch {
                std.fs.cwd().deleteTree(self.staging) catch {};
                return error.DestinationCommitFailed;
            };
        } else {
            std.fs.cwd().deleteTree(self.staging) catch {};
        }
        return status;
    }

    pub fn deinit(self: *CloneProcess) void {
        if (!self.finished) {
            self.cancel();
            _ = self.finish() catch {};
        }
        self.allocator.free(self.destination);
        self.allocator.free(self.staging);
        self.* = undefined;
    }

    fn releaseArgs(self: *CloneProcess) void {
        if (self.args.len == 0) return;
        for (self.args) |arg| self.allocator.free(arg);
        self.allocator.free(self.args);
        self.args = &.{};
    }

    pub fn snapshot(self: *CloneProcess, progress: []u8, stderr: []u8) OutputSnapshot {
        self.output_lock.lock();
        defer self.output_lock.unlock();
        const progress_len = @min(progress.len, self.progress_len);
        const stderr_len = @min(stderr.len, self.recent_stderr_len);
        @memcpy(progress[0..progress_len], self.progress[0..progress_len]);
        @memcpy(stderr[0..stderr_len], self.recent_stderr[0..stderr_len]);
        return .{ .progress_len = progress_len, .stderr_len = stderr_len };
    }

    fn recordOutput(self: *CloneProcess, bytes: []const u8, is_stderr: bool) void {
        self.output_lock.lock();
        defer self.output_lock.unlock();
        const target = if (is_stderr) &self.recent_stderr else &self.progress;
        const len = if (is_stderr) &self.recent_stderr_len else &self.progress_len;
        const capacity = target.len;
        const copy_len = @min(capacity, bytes.len);
        if (copy_len < capacity) {
            @memcpy(target[0..copy_len], bytes[bytes.len - copy_len ..]);
        } else {
            @memcpy(target[0..capacity], bytes[bytes.len - capacity ..]);
        }
        len.* = copy_len;
    }
};

fn inspectDestination(path: []const u8) !bool {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.NotDir => return error.DestinationNotDirectory,
        else => return err,
    };
    dir.close();
    return true;
}

fn makeStagingPath(allocator: std.mem.Allocator, destination: []const u8) ![]u8 {
    const parent = std.fs.path.dirname(destination) orelse ".";
    const base = std.fs.path.basename(destination);
    var attempt: usize = 0;
    while (attempt < 32) : (attempt += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{s}{c}{s}.graphcode-clone-{d}-{d}", .{
            parent, std.fs.path.sep, base, std.time.nanoTimestamp(), attempt,
        });
        if (!try inspectDestination(candidate)) return candidate;
        allocator.free(candidate);
    }
    return error.StagingPathUnavailable;
}

pub const CloneOperation = struct {
    allocator: std.mem.Allocator,
    process: *CloneProcess,
    thread: std.Thread,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    status: CloneStatus = .cloning,

    pub fn start(allocator: std.mem.Allocator, fields: CloneFields) !*CloneOperation {
        const operation = try allocator.create(CloneOperation);
        errdefer allocator.destroy(operation);
        const process = try allocator.create(CloneProcess);
        errdefer allocator.destroy(process);
        process.* = try CloneProcess.start(allocator, fields);
        operation.* = .{ .allocator = allocator, .process = process, .thread = undefined };
        operation.thread = std.Thread.spawn(.{}, worker, .{operation}) catch |err| {
            process.deinit();
            allocator.destroy(process);
            return err;
        };
        return operation;
    }

    pub fn cancel(self: *CloneOperation) void {
        self.process.cancel();
    }

    pub fn poll(self: *CloneOperation) ?CloneStatus {
        if (!self.done.load(.acquire)) return null;
        return self.status;
    }

    pub fn snapshot(self: *CloneOperation, progress: []u8, stderr: []u8) OutputSnapshot {
        return self.process.snapshot(progress, stderr);
    }

    pub fn deinit(self: *CloneOperation) void {
        if (!self.done.load(.acquire)) self.cancel();
        self.thread.join();
        self.process.deinit();
        self.allocator.destroy(self.process);
        self.allocator.destroy(self);
    }

    fn worker(self: *CloneOperation) void {
        var stdout_thread = std.Thread.spawn(.{}, drainPipe, .{ self.process, &self.process.child.stdout.?, false }) catch {
            self.process.cancel();
            self.status = .failed;
            self.done.store(true, .release);
            return;
        };
        var stderr_thread = std.Thread.spawn(.{}, drainPipe, .{ self.process, &self.process.child.stderr.?, true }) catch {
            self.process.cancel();
            stdout_thread.join();
            self.status = .failed;
            self.done.store(true, .release);
            return;
        };
        stdout_thread.join();
        stderr_thread.join();
        self.status = self.process.finish() catch .failed;
        self.done.store(true, .release);
    }
};

pub fn validateClone(fields: CloneFields) !void {
    if (std.mem.trim(u8, fields.url, " \t\r\n").len == 0) return error.MissingRepositoryURL;
    if (!std.mem.startsWith(u8, fields.url, "https://")) return error.HTTPSRequired;
    if (std.mem.trim(u8, fields.destination, " \t\r\n").len == 0) return error.MissingDestination;
    if (std.mem.indexOfScalar(u8, fields.destination, 0) != null) return error.InvalidDestination;
    if (fields.depth.len != 0 and std.fmt.parseInt(u32, fields.depth, 10) catch 0 == 0)
        return error.InvalidDepth;
}

pub fn validateRemote(fields: RemoteFields) !void {
    if (fields.host.len == 0 or fields.user.len == 0 or fields.path.len == 0)
        return error.MissingRemoteField;
    if (!std.mem.startsWith(u8, fields.path, "/")) return error.AbsolutePathRequired;
    const port = std.fmt.parseInt(u16, fields.port, 10) catch return error.InvalidPort;
    if (port == 0) return error.InvalidPort;
    if (std.mem.startsWith(u8, fields.host, "-") or std.mem.startsWith(u8, fields.user, "-"))
        return error.InvalidSSHComponent;
    for ([_][]const u8{ fields.host, fields.user, fields.path }) |value| {
        if (std.mem.indexOfAny(u8, value, "\x00\r\n") != null) return error.InvalidSSHComponent;
    }
}

pub fn sshDestination(allocator: std.mem.Allocator, fields: RemoteFields) ![]u8 {
    try validateRemote(fields);
    return std.fmt.allocPrint(allocator, "{s}@{s}", .{ fields.user, fields.host });
}

pub fn reconnectCommand(allocator: std.mem.Allocator, fields: RemoteFields) ![]u8 {
    const destination = try sshDestination(allocator, fields);
    defer allocator.free(destination);
    const quoted_destination = try shellQuote(allocator, destination);
    defer allocator.free(quoted_destination);
    const quoted_path = try shellQuote(allocator, fields.path);
    defer allocator.free(quoted_path);
    return std.fmt.allocPrint(
        allocator,
        "ssh -o BatchMode=yes -o ConnectTimeout=10 -p {s} {s} -- zmx attach -- {s}",
        .{ fields.port, quoted_destination, quoted_path },
    );
}

fn shellQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var size: usize = 2;
    for (value) |byte| size += if (byte == '\'') 4 else 1;
    var result = try allocator.alloc(u8, size);
    var index: usize = 0;
    result[index] = '\'';
    index += 1;
    for (value) |byte| {
        if (byte == '\'') {
            @memcpy(result[index .. index + 4], "'\\''");
            index += 4;
        } else {
            result[index] = byte;
            index += 1;
        }
    }
    result[index] = '\'';
    return result;
}

pub fn sshValidationArgs(allocator: std.mem.Allocator, fields: RemoteFields) ![][]u8 {
    try validateRemote(fields);
    var args = std.array_list.Managed([]u8).init(allocator);
    try args.append(try allocator.dupe(u8, "ssh"));
    try args.append(try allocator.dupe(u8, "-o"));
    try args.append(try allocator.dupe(u8, "BatchMode=yes"));
    try args.append(try allocator.dupe(u8, "-o"));
    try args.append(try allocator.dupe(u8, "ConnectTimeout=10"));
    try args.append(try allocator.dupe(u8, "-p"));
    try args.append(try allocator.dupe(u8, fields.port));
    const destination = try sshDestination(allocator, fields);
    defer allocator.free(destination);
    try args.append(try allocator.dupe(u8, destination));
    const quoted_path = try shellQuote(allocator, fields.path);
    defer allocator.free(quoted_path);
    const remote_command = try std.fmt.allocPrint(allocator, "git -C {s} rev-parse --show-toplevel", .{quoted_path});
    try args.append(remote_command);
    return args.toOwnedSlice();
}

pub fn validateRemoteConnection(allocator: std.mem.Allocator, fields: RemoteFields) !void {
    const args = try sshValidationArgs(allocator, fields);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }
    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var out_thread = try std.Thread.spawn(.{}, drainPipeDiscard, .{ &child.stdout.? });
    var err_thread = try std.Thread.spawn(.{}, drainPipeDiscard, .{ &child.stderr.? });
    out_thread.join();
    err_thread.join();
    switch (try child.wait()) {
        .Exited => |code| if (code != 0) return error.SSHValidationFailed,
        else => return error.SSHValidationFailed,
    }
}

pub fn saveRemoteConfig(allocator: std.mem.Allocator, fields: RemoteFields) !void {
    try validateRemote(fields);
    const base = std.process.getEnvVarOwned(allocator, "LOCALAPPDATA") catch
        try std.process.getEnvVarOwned(allocator, "USERPROFILE");
    defer allocator.free(base);
    const dir = try std.fs.path.join(allocator, &.{ base, "GraphCode" });
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "remote.ini" });
    defer allocator.free(path);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    const data = try std.fmt.allocPrint(allocator, "host={s}\nuser={s}\nport={s}\npath={s}\n", .{
        fields.host, fields.user, fields.port, fields.path,
    });
    defer allocator.free(data);
    try file.writeAll(data);
}

pub fn cloneCommand(allocator: std.mem.Allocator, fields: CloneFields) ![]const []u8 {
    try validateClone(fields);
    var args = std.array_list.Managed([]u8).init(allocator);
    try args.append(try allocator.dupe(u8, "git"));
    try args.append(try allocator.dupe(u8, "clone"));
    try args.append(try allocator.dupe(u8, "--progress"));
    if (fields.branch.len != 0) {
        try args.append(try allocator.dupe(u8, "--branch"));
        try args.append(try allocator.dupe(u8, fields.branch));
    }
    if (fields.depth.len != 0) {
        try args.append(try allocator.dupe(u8, "--depth"));
        try args.append(try allocator.dupe(u8, fields.depth));
    }
    try args.append(try allocator.dupe(u8, "--"));
    try args.append(try allocator.dupe(u8, fields.url));
    try args.append(try allocator.dupe(u8, fields.destination));
    return args.toOwnedSlice();
}

pub fn openClone(parent: c.HWND, allocator: std.mem.Allocator, initial: CloneFields) !?CloneFields {
    const values = initial.values();
    const result = try NativeDialogs.text(parent, allocator, "Clone HTTPS repository", &.{
        "HTTPS repository URL", "Destination (Unicode paths supported)",
        "Branch (optional)", "Depth (optional)",
    }, &values);
    var fields = result orelse return null;
    defer fields.deinit(allocator);
    return .{
        .url = try allocator.dupe(u8, fields.values[0]),
        .destination = try allocator.dupe(u8, fields.values[1]),
        .branch = try allocator.dupe(u8, fields.values[2]),
        .depth = try allocator.dupe(u8, fields.values[3]),
    };
}

pub fn openRemote(parent: c.HWND, allocator: std.mem.Allocator, initial: RemoteFields) !?RemoteFields {
    const values = initial.values();
    const result = try NativeDialogs.text(parent, allocator, "Add SSH repository", &.{
        "Host", "User", "Port", "Absolute remote repository path",
    }, &values);
    var fields = result orelse return null;
    defer fields.deinit(allocator);
    return .{
        .host = try allocator.dupe(u8, fields.values[0]),
        .user = try allocator.dupe(u8, fields.values[1]),
        .port = try allocator.dupe(u8, fields.values[2]),
        .path = try allocator.dupe(u8, fields.values[3]),
    };
}

pub fn runClone(allocator: std.mem.Allocator, fields: CloneFields) !CloneStatus {
    var process = try CloneProcess.start(allocator, fields);
    defer process.deinit();
    var stdout_thread = try std.Thread.spawn(.{}, drainPipe, .{ &process, &process.child.stdout.?, false });
    var stderr_thread = try std.Thread.spawn(.{}, drainPipe, .{ &process, &process.child.stderr.?, true });
    stdout_thread.join();
    stderr_thread.join();
    return process.finish();
}

fn drainPipe(process: *CloneProcess, file: *std.fs.File, is_stderr: bool) void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = file.read(&buffer) catch return;
        if (count == 0) return;
        process.recordOutput(buffer[0..count], is_stderr);
    }
}

fn drainPipeDiscard(file: *std.fs.File) void {
    var buffer: [4096]u8 = undefined;
    while ((file.read(&buffer) catch 0) != 0) {}
}

test "clone validation and argv preserve HTTPS, Unicode, and option boundaries" {
    const fields = CloneFields{
        .url = "https://example.test/repo.git",
        .destination = "C:\\Users\\dev\\Проекты\\repo",
        .branch = "main",
        .depth = "1",
    };
    const args = try cloneCommand(std.testing.allocator, fields);
    defer {
        for (args) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(args);
    }
    try std.testing.expectEqualStrings("--", args[7]);
    try std.testing.expectEqualStrings(fields.destination, args[9]);
}

test "SSH validation and reconnect command reject injection-shaped identities" {
    try std.testing.expectError(error.InvalidSSHComponent, validateRemote(.{ .host = "-oProxyCommand=x", .user = "dev", .path = "/repo" }));
    const command = try reconnectCommand(std.testing.allocator, .{ .host = "build-box", .user = "dev", .path = "/srv/граф" });
    defer std.testing.allocator.free(command);
    try std.testing.expect(std.mem.indexOf(u8, command, "BatchMode=yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "/srv/граф") != null);
}

test "SSH validation argv uses one quoted remote command" {
    const args = try sshValidationArgs(std.testing.allocator, .{
        .host = "build-box", .user = "dev", .port = "2222", .path = "/srv/граф",
    });
    defer {
        for (args) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(args);
    }
    try std.testing.expectEqualStrings("BatchMode=yes", args[2]);
    try std.testing.expectEqualStrings("dev@build-box", args[7]);
    try std.testing.expectEqualStrings("git -C '/srv/граф' rev-parse --show-toplevel", args[8]);
}

test "SSH reconnect command quotes shell metacharacters and rejects newlines" {
    const command = try reconnectCommand(std.testing.allocator, .{
        .host = "build-box", .user = "dev", .path = "/srv/a;$(touch p)'q",
    });
    defer std.testing.allocator.free(command);
    try std.testing.expect(std.mem.indexOf(u8, command, "'/srv/a;$(touch p)'\\''q'") != null);
    try std.testing.expectError(error.InvalidSSHComponent, validateRemote(.{
        .host = "build-box", .user = "dev\nwhoami", .path = "/repo",
    }));
}

test "clone refuses non-empty destinations without deleting sentinels" {
    const path = "graphcode-clone-sentinel-regression";
    std.fs.cwd().deleteTree(path) catch {};
    try std.fs.cwd().makePath(path);
    defer std.fs.cwd().deleteTree(path) catch {};
    var sentinel = try std.fs.cwd().createFile("graphcode-clone-sentinel-regression\\keep.txt", .{});
    try sentinel.writeAll("keep");
    sentinel.close();
    try std.testing.expectError(error.DestinationAlreadyExists, CloneProcess.start(std.testing.allocator, .{
        .url = "https://example.test/repo.git", .destination = path,
    }));
    var kept = try std.fs.cwd().openFile("graphcode-clone-sentinel-regression\\keep.txt", .{});
    defer kept.close();
    var bytes: [4]u8 = undefined;
    var reader = kept.reader(&.{});
    try reader.interface.readSliceAll(&bytes);
    try std.testing.expectEqualStrings("keep", &bytes);
}
