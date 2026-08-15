const std = @import("std");

pub const Entry = struct {
    path: []u8,
    branch: []u8,
    locked: bool = false,
    prunable: bool = false,
    dirty: bool = false,
};

pub const Summary = struct {
    total: usize = 0,
    reclaimable: usize = 0,
    blocked: usize = 0,
};

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
        if (entry.locked) {
            result.blocked += 1;
        } else if (entry.prunable or (!entry.dirty and entry.branch.len != 0)) {
            result.reclaimable += 1;
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
    try std.testing.expectEqual(@as(usize, 3), summary.reclaimable);
    try std.testing.expectEqual(@as(usize, 1), summary.blocked);
}
