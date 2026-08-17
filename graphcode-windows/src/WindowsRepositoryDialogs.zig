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

    pub fn start(allocator: std.mem.Allocator, fields: CloneFields) !CloneProcess {
        const args = try cloneCommand(allocator, fields);
        var child = std.process.Child.init(args, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        return .{ .allocator = allocator, .child = child, .args = args };
    }

    pub fn cancel(self: *CloneProcess) void {
        _ = self.child.kill() catch {};
    }

    pub fn finish(self: *CloneProcess) !CloneStatus {
        const term = try self.child.wait();
        for (self.args) |arg| self.allocator.free(arg);
        self.allocator.free(self.args);
        return switch (term) {
            .Exited => |code| if (code == 0) .finished else .failed,
            else => .failed,
        };
    }

    pub fn deinit(self: *CloneProcess) void {
        self.cancel();
        for (self.args) |arg| self.allocator.free(arg);
        self.allocator.free(self.args);
        self.* = undefined;
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
}

pub fn sshDestination(allocator: std.mem.Allocator, fields: RemoteFields) ![]u8 {
    try validateRemote(fields);
    return std.fmt.allocPrint(allocator, "{s}@{s}", .{ fields.user, fields.host });
}

pub fn reconnectCommand(allocator: std.mem.Allocator, fields: RemoteFields) ![]u8 {
    const destination = try sshDestination(allocator, fields);
    defer allocator.free(destination);
    return std.fmt.allocPrint(
        allocator,
        "ssh -o BatchMode=yes -o ConnectTimeout=10 -p {s} {s} -- zmx attach -- {s}",
        .{ fields.port, destination, fields.path },
    );
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
    const args = try cloneCommand(allocator, fields);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }
    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.env_map = null;
    try child.spawn();
    _ = child.stdout.?.readToEndAlloc(allocator, 1024 * 1024) catch &.{};
    const stderr = child.stderr.?.readToEndAlloc(allocator, 1024 * 1024) catch &.{};
    defer if (stderr.len != 0) allocator.free(stderr);
    return switch (try child.wait()) {
        .Exited => |code| if (code == 0) .finished else .failed,
        else => .failed,
    };
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
    try std.testing.expectEqualStrings("--", args[6]);
    try std.testing.expectEqualStrings(fields.destination, args[8]);
}

test "SSH validation and reconnect command reject injection-shaped identities" {
    try std.testing.expectError(error.InvalidSSHComponent, validateRemote(.{ .host = "-oProxyCommand=x", .user = "dev", .path = "/repo" }));
    const command = try reconnectCommand(std.testing.allocator, .{ .host = "build-box", .user = "dev", .path = "/srv/граф" });
    defer std.testing.allocator.free(command);
    try std.testing.expect(std.mem.indexOf(u8, command, "BatchMode=yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "/srv/граф") != null);
}
