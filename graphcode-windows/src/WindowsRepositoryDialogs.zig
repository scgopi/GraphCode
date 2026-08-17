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

pub const CloneProcess = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    args: []const []u8,
    destination: []u8,
    destination_preexisted: bool,
    destination_owned: bool,
    finished: bool = false,
    cancelled: bool = false,

    pub fn start(allocator: std.mem.Allocator, fields: CloneFields) !CloneProcess {
        const destination_preexisted = try inspectDestination(fields.destination);
        if (destination_preexisted) {
            var dir = try std.fs.cwd().openDir(fields.destination, .{ .iterate = true });
            var iterator = dir.iterate();
            const non_empty = (try iterator.next()) != null;
            dir.close();
            if (non_empty) return error.DestinationNotEmpty;
        }
        const args = try cloneCommand(allocator, fields);
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

        return .{ .allocator = allocator, .child = child, .args = args, .destination = destination,
            .destination_preexisted = destination_preexisted, .destination_owned = !destination_preexisted };
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
        if (status != .finished and self.destination_owned and !self.destination_preexisted)
            std.fs.cwd().deleteTree(self.destination) catch {};
        return status;
    }

    pub fn deinit(self: *CloneProcess) void {
        if (!self.finished) {
            self.cancel();
            _ = self.finish() catch {};
        }
        self.allocator.free(self.destination);
        self.* = undefined;
    }

    fn releaseArgs(self: *CloneProcess) void {
        if (self.args.len == 0) return;
        for (self.args) |arg| self.allocator.free(arg);
        self.allocator.free(self.args);
        self.args = &.{};
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

    pub fn deinit(self: *CloneOperation) void {
        if (!self.done.load(.acquire)) self.cancel();
        self.thread.join();
        self.process.deinit();
        self.allocator.destroy(self.process);
        self.allocator.destroy(self);
    }

    fn worker(self: *CloneOperation) void {
        var stdout_thread = std.Thread.spawn(.{}, drainPipe, .{ &self.process.child.stdout.?, self.allocator }) catch {
            self.process.cancel();
            self.status = .failed;
            self.done.store(true, .release);
            return;
        };
        var stderr_thread = std.Thread.spawn(.{}, drainPipe, .{ &self.process.child.stderr.?, self.allocator }) catch {
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
    try args.append(try allocator.dupe(u8, "--"));
    try args.append(try allocator.dupe(u8, "git"));
    try args.append(try allocator.dupe(u8, "-C"));
    try args.append(try allocator.dupe(u8, fields.path));
    try args.append(try allocator.dupe(u8, "rev-parse"));
    try args.append(try allocator.dupe(u8, "--show-toplevel"));
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
    var out_thread = try std.Thread.spawn(.{}, drainPipe, .{ &child.stdout.?, allocator });
    var err_thread = try std.Thread.spawn(.{}, drainPipe, .{ &child.stderr.?, allocator });
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
    var stdout_thread = try std.Thread.spawn(.{}, drainPipe, .{ &process.child.stdout.?, allocator });
    var stderr_thread = try std.Thread.spawn(.{}, drainPipe, .{ &process.child.stderr.?, allocator });
    stdout_thread.join();
    stderr_thread.join();
    return process.finish();
}

fn drainPipe(file: *std.fs.File, allocator: std.mem.Allocator) void {
    const output = file.readToEndAlloc(allocator, 16 * 1024 * 1024) catch return;
    allocator.free(output);
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

test "SSH validation argv keeps destination and remote path separate" {
    const args = try sshValidationArgs(std.testing.allocator, .{
        .host = "build-box", .user = "dev", .port = "2222", .path = "/srv/граф",
    });
    defer {
        for (args) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(args);
    }
    try std.testing.expectEqualStrings("BatchMode=yes", args[2]);
    try std.testing.expectEqualStrings("dev@build-box", args[7]);
    try std.testing.expectEqualStrings("/srv/граф", args[11]);
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
    try std.testing.expectError(error.DestinationNotEmpty, CloneProcess.start(std.testing.allocator, .{
        .url = "https://example.test/repo.git", .destination = path,
    }));
    var kept = try std.fs.cwd().openFile("graphcode-clone-sentinel-regression\\keep.txt", .{});
    defer kept.close();
    var bytes: [4]u8 = undefined;
    var reader = kept.reader(&.{});
    try reader.interface.readSliceAll(&bytes);
    try std.testing.expectEqualStrings("keep", &bytes);
}
