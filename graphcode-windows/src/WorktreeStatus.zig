const std = @import("std");

pub const Entry = struct {
    path: []u8,
    branch: []u8,
    primary: bool = false,
    locked: bool = false,
    prunable: bool = false,
    dirty: bool = false,
    untracked: bool = false,
    conflicted: bool = false,
    pushed: bool = false,
    landed: bool = false,
    bound_running: bool = false,
};

pub const Summary = struct {
    total: usize = 0,
    reclaimable: usize = 0,
    blocked: usize = 0,
};

pub const InspectionError = error{
    EmptyProjectPath,
    GitFailed,
    MalformedStatus,
};

pub const Inspection = struct {
    entries: std.array_list.Managed(Entry),
    default_branch: []u8,
};

pub const ReclaimDecision = enum { reclaimable, keep };

pub fn decision(entry: Entry) ReclaimDecision {
    if (entry.primary or entry.locked or entry.dirty or entry.untracked or
        entry.conflicted or !entry.pushed or !entry.landed or entry.bound_running)
    {
        return .keep;
    }

    return .reclaimable;
}

pub fn inspect(allocator: std.mem.Allocator, project_path: []const u8) !Inspection {
pub fn selectedEntry(entries: []const Entry, path: []const u8) ?Entry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry;
    }
    return null;
}

pub fn inspect(allocator: std.mem.Allocator, project_path: []const u8, bindings: []const Binding) !Inspection {
        if (project_path.len == 0) return error.EmptyProjectPath;
        const list = try runGit(allocator, &.{
            "git", "-C", project_path, "worktree", "list", "--porcelain",
        });
        defer allocator.free(list.output);
        var entries = try parse(allocator, list.output);
        errdefer deinit(allocator, &entries);
        const default = try runGit(allocator, &.{
            "git", "-C", project_path, "symbolic-ref", "--short", "HEAD",
        });
        defer allocator.free(default.output);
        const default_branch = try allocator.dupe(u8, std.mem.trim(u8, default.output, " \r\n"));
        const default_branch = try discoverDefault(allocator, project_path, entries.items);
        errdefer allocator.free(default_branch);
        for (entries.items, 0..) |*entry, index| {
            entry.primary = index == 0;
            if (entry.primary or entry.prunable) continue;
            const status = try runGit(allocator, &.{
                "git", "-C", entry.path, "status", "--porcelain=v1", "--untracked-files=all",
            });
            defer allocator.free(status.output);
            var lines = std.mem.splitScalar(u8, status.output, '\n');
            while (lines.next()) |raw| {
                const line = std.mem.trim(u8, raw, "\r");
                if (line.len < 2) continue;
                entry.dirty = true;
                if (std.mem.startsWith(u8, line, "??")) entry.untracked = true;
                if (line[0] == 'U' or line[1] == 'U' or
                    (line[0] == 'A' and line[1] == 'A') or
                    (line[0] == 'D' and line[1] == 'D')) entry.conflicted = true;
            }
            entry.pushed = succeedsGit(allocator, &.{
                "git", "-C", entry.path, "rev-parse", "--verify", "@{u}",
            });
            entry.landed = succeedsGit(allocator, &.{
                "git", "-C", project_path, "merge-base", "--is-ancestor",
                entry.branch, default_branch,
            });
        }
        return .{ .entries = entries, .default_branch = default_branch };
    }

pub fn reclaim(allocator: std.mem.Allocator, entries: []const Entry) !usize {
        var removed: usize = 0;
        for (entries) |entry| {
            if (decision(entry) != .reclaimable) continue;
            _ = try runGit(allocator, &.{
                "git", "-C", entry.path, "worktree", "remove", entry.path,
            });
            removed += 1;
        }
        return removed;
    }

const GitResult = struct { output: []u8 };

fn succeedsGit(allocator: std.mem.Allocator, args: []const []const u8) bool {
        const result = runGit(allocator, args) catch return false;
        allocator.free(result.output);
        return true;
    }

    fn zeroCommitsAhead(allocator: std.mem.Allocator, path: []const u8) bool {
        const result = runGit(allocator, &.{ "git", "-C", path, "rev-list", "--count", "@{upstream}..HEAD" }) catch return false;
        defer allocator.free(result.output);
        return std.mem.eql(u8, std.mem.trim(u8, result.output, " \r\n"), "0");
    }

    fn landedOnDefault(allocator: std.mem.Allocator, project: []const u8, branch: []const u8, default_branch: []const u8) bool {
        if (branch.len == 0 or default_branch.len == 0) return false;
        const result = runGit(allocator, &.{ "git", "-C", project, "cherry", default_branch, branch }) catch return false;
        defer allocator.free(result.output);
        var lines = std.mem.splitScalar(u8, result.output, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \r"), "+")) return false;
        }

        return true;
    }

fn discoverDefault(allocator: std.mem.Allocator, project: []const u8, entries: []const Entry) ![]u8 {
    const origin = runGit(allocator, &.{ "git", "-C", project, "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }) catch null;
    if (origin) |result| {
        defer allocator.free(result.output);
        const value = std.mem.trim(u8, result.output, " \r\n");
        if (value.len != 0) return allocator.dupe(u8, value);
    }
    for ([_][]const u8{ "main", "master" }) |candidate| {
        if (succeedsGit(allocator, &.{ "git", "-C", project, "rev-parse", "--verify", candidate })) {
            return allocator.dupe(u8, candidate);
        }
    }
    if (entries.len != 0 and entries[0].branch.len != 0) {
        return allocator.dupe(u8, entries[0].branch);
    }
    return error.GitFailed;
}

fn runGit(allocator: std.mem.Allocator, args: []const []const u8) !GitResult {
        var child = std.process.Child.init(args, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        const output = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
        const term = try child.wait();
        switch (term) {
            .Exited => |code| if (code != 0) {
                allocator.free(output);
                return error.GitFailed;
            },
            else => {
                allocator.free(output);
                return error.GitFailed;
            },
        }
        return .{ .output = output };
}

pub const Action = enum { inspect, reclaim };

pub const CommandError = error{EmptyProjectPath};

pub fn command(
    allocator: std.mem.Allocator,
    action: Action,
    project_path: []const u8,
) (CommandError || std.mem.Allocator.Error)![]u8 {
    if (project_path.len == 0) return error.EmptyProjectPath;
    return switch (action) {
        .inspect => std.fmt.allocPrint(
            allocator,
            "git -C \"{s}\" worktree list --porcelain",
            .{project_path},
        ),
        .reclaim => std.fmt.allocPrint(
            allocator,
            "git -C \"{s}\" worktree prune --verbose",
            .{project_path},
        ),
    };
}

pub fn parse(allocator: std.mem.Allocator, porcelain: []const u8) !std.array_list.Managed(Entry) {
    var entries = std.array_list.Managed(Entry).init(allocator);
    errdefer deinit(allocator, &entries);
    var current: ?Entry = null;
    var lines = std.mem.splitScalar(u8, porcelain, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r ");
        if (line.len == 0) {
            if (current) |entry| try entries.append(entry);
            current = null;
            continue;
        }
        if (std.mem.startsWith(u8, line, "worktree ")) {
            if (current) |entry| try entries.append(entry);
            current = .{
                .path = try allocator.dupe(u8, line["worktree ".len..]),
                .branch = try allocator.dupe(u8, ""),
            };
        } else if (current != null and std.mem.startsWith(u8, line, "branch ")) {
            const branch = line["branch ".len..];
            const short = if (std.mem.startsWith(u8, branch, "refs/heads/"))
                branch["refs/heads/".len..]
            else
                branch;
            allocator.free(current.?.branch);
            current.?.branch = try allocator.dupe(u8, short);
        } else if (current != null and std.mem.eql(u8, line, "locked")) {
            current.?.locked = true;
        } else if (current != null and std.mem.eql(u8, line, "prunable")) {
            current.?.prunable = true;
        }
    }
    if (current) |entry| try entries.append(entry);
    return entries;
}

pub fn summarize(entries: []const Entry) Summary {
    var result = Summary{};
    result.total = entries.len;
    for (entries) |entry| {
        if (decision(entry) == .reclaimable) {
            result.reclaimable += 1;
        } else if (entry.locked) {
            result.blocked += 1;
        }
    }
    return result;
}

pub fn deinit(allocator: std.mem.Allocator, entries: *std.array_list.Managed(Entry)) void {
    for (entries.items) |entry| {
        allocator.free(entry.path);
        allocator.free(entry.branch);
    }
    entries.deinit();
}

test "parses real git worktree porcelain and summarizes safe rows" {
    const input =
        \\worktree C:\work\graph
        \\HEAD 1111111111111111111111111111111111111111
        \\branch refs/heads/main
        \\
        \\worktree C:\work\review
        \\HEAD 2222222222222222222222222222222222222222
        \\branch refs/heads/review
        \\
        \\worktree C:\work\stale
        \\HEAD 3333333333333333333333333333333333333333
        \\branch refs/heads/stale
        \\prunable
        \\
        \\worktree C:\work\locked
        \\HEAD 4444444444444444444444444444444444444444
        \\branch refs/heads/locked
        \\locked
    ;
    var entries = try parse(std.testing.allocator, input);
    defer deinit(std.testing.allocator, &entries);
    try std.testing.expectEqual(@as(usize, 4), entries.items.len);
    try std.testing.expectEqualStrings("review", entries.items[1].branch);
    const summary = summarize(entries.items);
    try std.testing.expectEqual(@as(usize, 4), summary.total);
    // Porcelain alone is not enough to prove pushed/landed; unknown facts stay
    // non-reclaimable until inspection fills them in.
    try std.testing.expectEqual(@as(usize, 0), summary.reclaimable);
    try std.testing.expectEqual(@as(usize, 1), summary.blocked);
}

test "porcelain edge cases preserve detached, locked, and prunable rows" {
    const input =
        \\worktree C:\work\detached
        \\HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        \\detached
        \\
        \\worktree C:\work\locked
        \\HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        \\branch refs/heads/locked
        \\locked reason
        \\
        \\worktree C:\work\prunable
        \\HEAD cccccccccccccccccccccccccccccccccccccccc
        \\branch refs/heads/prunable
        \\prunable stale admin
    ;
    var entries = try parse(std.testing.allocator, input);
    defer deinit(std.testing.allocator, &entries);
    try std.testing.expectEqual(@as(usize, 3), entries.items.len);
    try std.testing.expectEqualStrings("", entries.items[0].branch);
    try std.testing.expect(entries.items[1].locked);
    try std.testing.expect(entries.items[2].prunable);
}

test "hygiene commands reject empty paths and quote Windows paths" {
    try std.testing.expectError(error.EmptyProjectPath, command(std.testing.allocator, .inspect, ""));
    const inspect_command = try command(std.testing.allocator, .inspect, "C:\\work\\Graph Code");
    defer std.testing.allocator.free(inspect_command);
    try std.testing.expectEqualStrings(
        "git -C \"C:\\work\\Graph Code\" worktree list --porcelain",
        inspect_command,
    );
    const reclaim_command = try command(std.testing.allocator, .reclaim, "C:\\work\\Graph Code");
    defer std.testing.allocator.free(reclaim_command);
    try std.testing.expectEqualStrings(
        "git -C \"C:\\work\\Graph Code\" worktree prune --verbose",
        reclaim_command,
    );
}

test "reclaim classification fails closed for every unsafe signal" {
    const clean = Entry{
        .path = @constCast("clean"),
        .branch = @constCast("feature"),
        .pushed = true,
        .landed = true,
    };
    try std.testing.expectEqual(ReclaimDecision.reclaimable, decision(clean));
    inline for ([_][]const u8{
        "primary", "locked", "dirty", "untracked", "conflicted", "unpushed",
        "unlanded", "running binding",
    }) |label| {
        var candidate = clean;
        if (std.mem.eql(u8, label, "primary")) candidate.primary = true;
        if (std.mem.eql(u8, label, "locked")) candidate.locked = true;
        if (std.mem.eql(u8, label, "dirty")) candidate.dirty = true;
        if (std.mem.eql(u8, label, "untracked")) candidate.untracked = true;
        if (std.mem.eql(u8, label, "conflicted")) candidate.conflicted = true;
        if (std.mem.eql(u8, label, "unpushed")) candidate.pushed = false;
        if (std.mem.eql(u8, label, "unlanded")) candidate.landed = false;
        if (std.mem.eql(u8, label, "running binding")) candidate.bound_running = true;
        try std.testing.expectEqual(ReclaimDecision.keep, decision(candidate));
    }

}

test "explicit row selection is independent of graph binding safety" {
    var entries = [_]Entry{
        .{ .path = @constCast("C:\\safe"), .branch = @constCast("safe"), .pushed = true, .landed = true },
        .{ .path = @constCast("C:\\bound"), .branch = @constCast("bound"), .pushed = true, .landed = true, .bound_running = true },
    };
    try std.testing.expectEqual(ReclaimDecision.reclaimable, decision(selectedEntry(&entries, "C:\\safe").?));
    try std.testing.expectEqual(ReclaimDecision.keep, decision(selectedEntry(&entries, "C:\\bound").?));
}
