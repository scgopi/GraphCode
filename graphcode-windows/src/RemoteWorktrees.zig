const std = @import("std");
const WorktreeStatus = @import("WorktreeStatus.zig");

const Location = struct {
    allocator: std.mem.Allocator,
    kind: enum { ssh, codespace },
    destination: []u8,
    port: []u8,
    path: []u8,

    fn deinit(self: *Location) void {
        self.allocator.free(self.destination);
        self.allocator.free(self.port);
        self.allocator.free(self.path);
    }
};

pub fn sameRemotePath(left: []const u8, right: []const u8) bool {
    const normalized_left = if (left.len > 1) std.mem.trimRight(u8, left, "/") else left;
    const normalized_right = if (right.len > 1) std.mem.trimRight(u8, right, "/") else right;
    return std.mem.eql(u8, normalized_left, normalized_right);
}

pub fn inspectFactsWithCancel(
    allocator: std.mem.Allocator,
    project_uri: []const u8,
    bindings: []const WorktreeStatus.Binding,
    cancellation: ?WorktreeStatus.Cancellation,
) !WorktreeStatus.Inspection {
    if (cancellation) |value| try value.check();
    var location = try parseLocation(allocator, project_uri);
    defer location.deinit();
    const list = try runGit(allocator, location, &.{ "worktree", "list", "--porcelain" }, cancellation);
    defer allocator.free(list);
    var entries = try WorktreeStatus.parse(allocator, list);
    errdefer WorktreeStatus.deinit(allocator, &entries);
    const default_branch = try discoverDefault(allocator, location, entries.items, cancellation);
    errdefer allocator.free(default_branch);
    for (entries.items, 0..) |*entry, index| {
        if (cancellation) |value| try value.check();
        entry.primary = index == 0;
        entry.opened_checkout = sameRemotePath(location.path, entry.path);
        for (bindings) |binding| {
            if (std.mem.eql(u8, binding.path, entry.path)) {
                entry.bound_running = true;
                break;
            }
        }
        if (entry.primary or entry.prunable) continue;
        const status = try runGitAt(allocator, location, entry.path, &.{ "status", "--porcelain=v1", "--untracked-files=all" }, cancellation);
        defer allocator.free(status);
        var lines = std.mem.splitScalar(u8, status, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, "\r");
            if (line.len < 2) continue;
            entry.dirty = true;
            if (std.mem.startsWith(u8, line, "??")) entry.untracked = true;
            if (line[0] == 'U' or line[1] == 'U' or
                (line[0] == 'A' and line[1] == 'A') or
                (line[0] == 'D' and line[1] == 'D')) entry.conflicted = true;
        }
        entry.pushed = succeedsGitAt(allocator, location, entry.path, &.{ "rev-parse", "--verify", "@{u}" }, cancellation) and
            zeroCommitsAhead(allocator, location, entry.path, cancellation);
        entry.landed = succeedsGitAt(
            allocator,
            location,
            location.path,
            &.{ "merge-base", "--is-ancestor", entry.branch, default_branch },
            cancellation,
        );
    }
    return .{
        .entries = entries,
        .default_branch = default_branch,
        .project_path = try allocator.dupe(u8, project_uri),
    };
}

pub fn measureSizeWithCancel(
    allocator: std.mem.Allocator,
    project_uri: []const u8,
    worktree_path: []const u8,
    cancellation: ?WorktreeStatus.Cancellation,
) WorktreeStatus.SizeCoverage {
    var location = parseLocation(allocator, project_uri) catch |err| return .{ .complete = false, .first_error = err };
    defer location.deinit();
    const quoted = shellQuote(allocator, worktree_path) catch |err| return .{ .complete = false, .first_error = err };
    defer allocator.free(quoted);
    const command = std.fmt.allocPrint(allocator, "du -sk {s}", .{quoted}) catch |err| return .{ .complete = false, .first_error = err };
    defer allocator.free(command);
    const output = runRemote(allocator, location, command, cancellation) catch |err| return .{ .complete = false, .first_error = err };
    defer allocator.free(output);
    const field = std.mem.trim(u8, std.mem.sliceTo(std.mem.trim(u8, output, " \r\n"), '\t'), " ");
    const kib = std.fmt.parseInt(u64, field, 10) catch |err| return .{ .complete = false, .first_error = err };
    return .{ .bytes = std.math.mul(u64, kib, 1024) catch |err| return .{ .complete = false, .first_error = err } };
}

fn discoverDefault(
    allocator: std.mem.Allocator,
    location: Location,
    entries: []const WorktreeStatus.Entry,
    cancellation: ?WorktreeStatus.Cancellation,
) ![]u8 {
    if (runGit(allocator, location, &.{ "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, cancellation)) |output| {
        defer allocator.free(output);
        const value = std.mem.trim(u8, output, " \r\n");
        if (value.len != 0) return allocator.dupe(u8, value);
    } else |_| {}
    for ([_][]const u8{ "main", "master" }) |candidate| {
        if (succeedsGitAt(allocator, location, location.path, &.{ "rev-parse", "--verify", candidate }, cancellation))
            return allocator.dupe(u8, candidate);
    }
    if (entries.len != 0 and entries[0].branch.len != 0) return allocator.dupe(u8, entries[0].branch);
    return error.GitFailed;
}

fn zeroCommitsAhead(
    allocator: std.mem.Allocator,
    location: Location,
    path: []const u8,
    cancellation: ?WorktreeStatus.Cancellation,
) bool {
    const output = runGitAt(allocator, location, path, &.{ "rev-list", "--count", "@{upstream}..HEAD" }, cancellation) catch return false;
    defer allocator.free(output);
    return std.mem.eql(u8, std.mem.trim(u8, output, " \r\n"), "0");
}

fn succeedsGitAt(
    allocator: std.mem.Allocator,
    location: Location,
    path: []const u8,
    args: []const []const u8,
    cancellation: ?WorktreeStatus.Cancellation,
) bool {
    const output = runGitAt(allocator, location, path, args, cancellation) catch return false;
    allocator.free(output);
    return true;
}

fn runGit(
    allocator: std.mem.Allocator,
    location: Location,
    args: []const []const u8,
    cancellation: ?WorktreeStatus.Cancellation,
) ![]u8 {
    return runGitAt(allocator, location, location.path, args, cancellation);
}

fn runGitAt(
    allocator: std.mem.Allocator,
    location: Location,
    path: []const u8,
    args: []const []const u8,
    cancellation: ?WorktreeStatus.Cancellation,
) ![]u8 {
    const quoted_path = try shellQuote(allocator, path);
    defer allocator.free(quoted_path);
    var command = std.array_list.Managed(u8).init(allocator);
    defer command.deinit();
    try command.writer().print("git -C {s}", .{quoted_path});
    for (args) |arg| {
        const quoted = try shellQuote(allocator, arg);
        defer allocator.free(quoted);
        try command.writer().print(" {s}", .{quoted});
    }
    return runRemote(allocator, location, command.items, cancellation);
}

fn runRemote(
    allocator: std.mem.Allocator,
    location: Location,
    command: []const u8,
    cancellation: ?WorktreeStatus.Cancellation,
) ![]u8 {
    if (cancellation) |value| try value.check();
    var args = std.array_list.Managed([]const u8).init(allocator);
    defer args.deinit();
    switch (location.kind) {
        .ssh => {
            try args.appendSlice(&.{ "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-p", location.port, location.destination, command });
        },
        .codespace => {
            try args.appendSlice(&.{ "gh", "codespace", "ssh", "-c", location.destination, "--", command });
        },
    }
    var child = std.process.Child.init(args.items, allocator);
    child.create_no_window = true;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);
    try child.spawn();
    var waited = false;
    errdefer |primary_error| if (!waited) {
        _ = child.kill() catch |cleanup_error| {
            if (cleanup_error == error.AlreadyTerminated) {
                _ = child.wait() catch |wait_error| {
                    std.log.err("Remote worktree failure {s}; child reap failed: {s}", .{ @errorName(primary_error), @errorName(wait_error) });
                };
            } else {
                std.log.err("Remote worktree failure {s}; child cleanup failed: {s}", .{ @errorName(primary_error), @errorName(cleanup_error) });
            }
        };
    };
    const output_limit = 1024 * 1024;
    try child.collectOutput(allocator, &stdout, &stderr, output_limit);
    const term = try child.wait();
    waited = true;
    if (cancellation) |value| try value.check();
    switch (term) {
        .Exited => |code| if (code != 0) return error.RemoteCommandFailed,
        else => return error.RemoteCommandFailed,
    }
    return stdout.toOwnedSlice(allocator);
}

fn parseLocation(allocator: std.mem.Allocator, uri: []const u8) !Location {
    if (std.mem.startsWith(u8, uri, "codespace://")) {
        const value = uri["codespace://".len..];
        const slash = std.mem.indexOfScalar(u8, value, '/') orelse return error.InvalidRemoteProject;
        if (slash == 0) return error.InvalidRemoteProject;
        const destination = try percentDecode(allocator, value[0..slash]);
        errdefer allocator.free(destination);
        const port = try allocator.dupe(u8, "");
        errdefer allocator.free(port);
        const path = try percentDecode(allocator, value[slash..]);
        return .{
            .allocator = allocator,
            .kind = .codespace,
            .destination = destination,
            .port = port,
            .path = path,
        };
    }
    if (!std.mem.startsWith(u8, uri, "ssh://")) return error.InvalidRemoteProject;
    const value = uri["ssh://".len..];
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return error.InvalidRemoteProject;
    const authority = value[0..slash];
    var destination = authority;
    var port: []const u8 = "22";
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        const close_bracket = std.mem.lastIndexOfScalar(u8, authority, ']');
        if (close_bracket == null or colon > close_bracket.?) {
            destination = authority[0..colon];
            port = authority[colon + 1 ..];
        }
    }
    if (destination.len == 0 or port.len == 0) return error.InvalidRemoteProject;
    const owned_destination = try percentDecode(allocator, destination);
    errdefer allocator.free(owned_destination);
    const owned_port = try percentDecode(allocator, port);
    errdefer allocator.free(owned_port);
    const path = try percentDecode(allocator, value[slash..]);
    return .{
        .allocator = allocator,
        .kind = .ssh,
        .destination = owned_destination,
        .port = owned_port,
        .path = path,
    };
}

fn percentDecode(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] == '%') {
            if (index + 2 >= value.len) return error.InvalidRemoteProject;
            const byte = std.fmt.parseInt(u8, value[index + 1 .. index + 3], 16) catch return error.InvalidRemoteProject;
            if (byte == 0 or byte == '\r' or byte == '\n') return error.InvalidRemoteProject;
            try result.append(byte);
            index += 3;
        } else {
            if (value[index] == 0 or value[index] == '\r' or value[index] == '\n') return error.InvalidRemoteProject;
            try result.append(value[index]);
            index += 1;
        }
    }
    return result.toOwnedSlice();
}

fn shellQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    try result.append('\'');
    for (value) |byte| {
        if (byte == '\'') try result.appendSlice("'\"'\"'") else try result.append(byte);
    }
    try result.append('\'');
    return result.toOwnedSlice();
}
