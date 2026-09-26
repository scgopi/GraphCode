const std = @import("std");

pub const Entry = struct {
    path: []u8,
    branch: []u8,
    size_bytes: u64 = 0,
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

pub fn explorerParameters(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return error.EmptyProjectPath;
    return std.fmt.allocPrint(allocator, "/select,\"{s}\"", .{path});
}

pub const FailureReason = enum {
    primary,
    locked,
    prunable,
    dirty,
    untracked,
    conflicted,
    unpushed,
    not_landed,
    bound_running,
    safe,
};

pub const ResolveAction = enum { legacy, remove, ask, keep };

pub const Policy = struct {
    /// Reclaim is opt-in; missing or malformed policy stays disabled.
    allow_reclaim: bool = false,
    confirm_each_reclaim: bool = true,
    resolve_action: ResolveAction = .legacy,
    notice_size_gb: u32 = 2,
    notice_count: u32 = 8,

    pub fn effectiveResolveAction(self: Policy) ResolveAction {
        if (self.resolve_action != .legacy) return self.resolve_action;
        if (!self.allow_reclaim) return .keep;
        return if (self.confirm_each_reclaim) .ask else .remove;
    }

    pub fn applyResolveAction(self: *Policy, action: ResolveAction) void {
        self.resolve_action = action;
        self.allow_reclaim = action != .keep;
        self.confirm_each_reclaim = action == .ask;
    }
};

pub const PolicyParseError = error{MalformedPolicy};

pub fn failureReason(entry: Entry) FailureReason {
    if (entry.primary) return .primary;
    if (entry.locked) return .locked;
    if (entry.prunable) return .prunable;
    if (entry.dirty) return .dirty;
    if (entry.untracked) return .untracked;
    if (entry.conflicted) return .conflicted;
    if (!entry.pushed) return .unpushed;
    if (!entry.landed) return .not_landed;
    if (entry.bound_running) return .bound_running;
    return .safe;
}

pub fn failureReasonText(entry: Entry) []const u8 {
    return switch (failureReason(entry)) {
        .primary => "primary checkout",
        .locked => "locked",
        .prunable => "prunable/stale",
        .dirty => "local changes",
        .untracked => "untracked files",
        .conflicted => "merge conflicts",
        .unpushed => "unpushed commits",
        .not_landed => "not landed on default",
        .bound_running => "bound to active loop",
        .safe => "safe to reclaim",
    };
}

pub fn policyPath(allocator: std.mem.Allocator, project_path: []const u8) ![]u8 {
    if (project_path.len == 0) return error.EmptyProjectPath;
    return std.fmt.allocPrint(allocator, "{s}\\.graphcode\\worktree-policy.json", .{project_path});
}

pub fn encodePolicy(allocator: std.mem.Allocator, policy: Policy) ![]u8 {
    const action = policy.effectiveResolveAction();
    return std.fmt.allocPrint(
        allocator,
        "{{\"allowReclaim\":{s},\"confirmEachReclaim\":{s},\"onResolveLanded\":\"{s}\",\"noticeSizeGB\":{d},\"noticeCount\":{d}}}",
        .{
            if (policy.allow_reclaim) "true" else "false",
            if (policy.confirm_each_reclaim) "true" else "false",
            @tagName(action),
            policy.notice_size_gb,
            policy.notice_count,
        },
    );
}

pub fn decodePolicy(bytes: []const u8) PolicyParseError!Policy {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, bytes, .{}) catch return error.MalformedPolicy;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.MalformedPolicy,
    };
    if (object.count() != 2 and object.count() != 5) return error.MalformedPolicy;
    const allow_value = object.get("allowReclaim") orelse return error.MalformedPolicy;
    const confirm_value = object.get("confirmEachReclaim") orelse return error.MalformedPolicy;
    const allow_reclaim = switch (allow_value) {
        .bool => |value| value,
        else => return error.MalformedPolicy,
    };
    const confirm_each_reclaim = switch (confirm_value) {
        .bool => |value| value,
        else => return error.MalformedPolicy,
    };
    var policy = Policy{ .allow_reclaim = allow_reclaim, .confirm_each_reclaim = confirm_each_reclaim };
    if (object.count() == 5) {
        const action_value = object.get("onResolveLanded") orelse return error.MalformedPolicy;
        const action_text = switch (action_value) {
            .string => |value| value,
            else => return error.MalformedPolicy,
        };
        policy.resolve_action = std.meta.stringToEnum(ResolveAction, action_text) orelse return error.MalformedPolicy;
        if (policy.resolve_action == .legacy) return error.MalformedPolicy;
        const size_value = object.get("noticeSizeGB") orelse return error.MalformedPolicy;
        const count_value = object.get("noticeCount") orelse return error.MalformedPolicy;
        policy.notice_size_gb = switch (size_value) {
            .integer => |value| if (value > 0 and value <= std.math.maxInt(u32)) @intCast(value) else return error.MalformedPolicy,
            else => return error.MalformedPolicy,
        };
        policy.notice_count = switch (count_value) {
            .integer => |value| if (value > 0 and value <= std.math.maxInt(u32)) @intCast(value) else return error.MalformedPolicy,
            else => return error.MalformedPolicy,
        };
        policy.applyResolveAction(policy.resolve_action);
    }
    return policy;
}

pub fn loadPolicy(allocator: std.mem.Allocator, project_path: []const u8) Policy {
    const path = policyPath(allocator, project_path) catch return .{};
    defer allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 4096) catch return .{};
    defer allocator.free(bytes);
    return decodePolicy(bytes) catch .{};
}

pub fn savePolicy(allocator: std.mem.Allocator, project_path: []const u8, policy: Policy) !void {
    const path = try policyPath(allocator, project_path);
    defer allocator.free(path);
    const directory = std.fmt.allocPrint(allocator, "{s}\\.graphcode", .{project_path}) catch return error.OutOfMemory;
    defer allocator.free(directory);
    try std.fs.cwd().makePath(directory);
    const bytes = try encodePolicy(allocator, policy);
    defer allocator.free(bytes);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

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
    project_path: []u8,
};

pub const Binding = struct {
    path: []const u8,
};

pub const ReclaimDecision = enum { reclaimable, keep };

pub fn decision(entry: Entry) ReclaimDecision {
    if (entry.primary or entry.locked or entry.prunable or entry.dirty or entry.untracked or
        entry.conflicted or !entry.pushed or !entry.landed or entry.bound_running)
    {
        return .keep;
    }
    return .reclaimable;
}

pub fn sweepSelectable(entry: Entry) bool {
    return !entry.primary and !entry.locked and !entry.bound_running;
}

pub fn discardsFiles(entry: Entry) bool {
    return !entry.prunable and (entry.dirty or entry.untracked or entry.conflicted);
}

pub fn sizeText(allocator: std.mem.Allocator, bytes: u64) ![]u8 {
    if (bytes < 1024) return std.fmt.allocPrint(allocator, "{d} B", .{bytes});
    if (bytes < 1024 * 1024) return std.fmt.allocPrint(allocator, "{d:.1} KB", .{@as(f64, @floatFromInt(bytes)) / 1024.0});
    if (bytes < 1024 * 1024 * 1024) return std.fmt.allocPrint(allocator, "{d:.1} MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)});
    return std.fmt.allocPrint(allocator, "{d:.1} GB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0)});
}

pub fn canReclaim(entry: Entry, policy: Policy, confirmed: bool) bool {
    return policy.allow_reclaim and (!policy.confirm_each_reclaim or confirmed) and
        decision(entry) == .reclaimable;
}

pub const ExplorerArgs = struct {
    executable: []const u8 = "explorer.exe",
    verb: []const u8,
    path: []const u8,
};

pub fn explorerArgs(path: []const u8) !ExplorerArgs {
    if (path.len == 0) return error.EmptyProjectPath;
    return .{ .verb = "explore", .path = path };
}

pub fn explorerCommandLine(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return error.EmptyProjectPath;
    return std.fmt.allocPrint(allocator, "explorer.exe /select,\"{s}\"", .{path});
}

pub fn selectedEntry(entries: []const Entry, path: []const u8) ?Entry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry;
    }
    return null;
}

pub fn inspect(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    bindings: []const Binding,
) !Inspection {
    if (project_path.len == 0) return error.EmptyProjectPath;
    const list = try runGit(allocator, &.{
        "git", "-C", project_path, "worktree", "list", "--porcelain",
    });
    defer allocator.free(list.output);
    var entries = try parse(allocator, list.output);
    errdefer deinit(allocator, &entries);
    const default_branch = try discoverDefault(allocator, project_path, entries.items);
    errdefer allocator.free(default_branch);
    for (entries.items, 0..) |*entry, index| {
        entry.primary = index == 0;
        entry.size_bytes = directorySize(entry.path) catch 0;
        for (bindings) |binding| {
            if (std.mem.eql(u8, entry.path, binding.path)) {
                entry.bound_running = true;
                break;
            }
        }
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
        }) and zeroCommitsAhead(allocator, entry.path);
        entry.landed = succeedsGit(allocator, &.{
            "git",        "-C",           project_path, "merge-base", "--is-ancestor",
            entry.branch, default_branch,
        });
    }
    return .{
        .entries = entries,
        .default_branch = default_branch,
        .project_path = try allocator.dupe(u8, project_path),
    };
}

fn directorySize(path: []const u8) !u64 {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(std.heap.page_allocator);
    defer walker.deinit();
    var total: u64 = 0;
    while (try walker.next()) |item| {
        if (item.kind != .file) continue;
        const stat = item.dir.statFile(item.basename) catch continue;
        total += stat.size;
    }
    return total;
}

pub fn deinitInspection(allocator: std.mem.Allocator, inspection: *Inspection) void {
    deinit(allocator, &inspection.entries);
    allocator.free(inspection.default_branch);
    allocator.free(inspection.project_path);
}

pub fn reclaim(allocator: std.mem.Allocator, entries: []const Entry) !usize {
    var removed: usize = 0;
    for (entries) |entry| {
        if (decision(entry) != .reclaimable) continue;
        const result = try runGit(allocator, &.{
            "git", "-C", entry.path, "worktree", "remove", entry.path,
        });
        allocator.free(result.output);
        removed += 1;
    }
    return removed;
}

pub fn reclaimSelected(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    selected: []const []const u8,
    bindings: []const Binding,
) !usize {
    return reclaimSelectedWithPolicy(allocator, project_path, selected, bindings, .{}, false);
}

pub fn reclaimSelectedWithPolicy(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    selected: []const []const u8,
    bindings: []const Binding,
    policy: Policy,
    confirmed: bool,
) !usize {
    return reclaimSelectedWithPolicyMode(allocator, project_path, selected, bindings, policy, confirmed, false);
}

pub fn reclaimSelectedWithPolicyMode(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    selected: []const []const u8,
    bindings: []const Binding,
    policy: Policy,
    confirmed: bool,
    allow_forced: bool,
) !usize {
    if (!policy.allow_reclaim) return error.PolicyDisabled;
    if (policy.confirm_each_reclaim and !confirmed) return error.ConfirmationRequired;
    if (selected.len == 0) return error.UnsafeSelection;
    var inspection = try inspect(allocator, project_path, bindings);
    defer deinitInspection(allocator, &inspection);
    try validateSelectedMode(allocator, inspection.entries.items, selected, bindings, allow_forced);
    var removed: usize = 0;
    for (selected) |path| {
        const entry = selectedEntry(inspection.entries.items, path) orelse return error.UnsafeSelection;
        const result = if (allow_forced and discardsFiles(entry))
            try runGit(allocator, &.{ "git", "-C", project_path, "worktree", "remove", "--force", path })
        else
            try runGit(allocator, &.{ "git", "-C", project_path, "worktree", "remove", path });
        allocator.free(result.output);
        removed += 1;
    }
    return removed;
}

pub fn validateSelected(
    allocator: std.mem.Allocator,
    entries: []const Entry,
    selected: []const []const u8,
    bindings: []const Binding,
) !void {
    return validateSelectedMode(allocator, entries, selected, bindings, false);
}

pub fn validateSelectedMode(
    allocator: std.mem.Allocator,
    entries: []const Entry,
    selected: []const []const u8,
    bindings: []const Binding,
    allow_forced: bool,
) !void {
    if (selected.len == 0) return error.UnsafeSelection;
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    for (selected) |path| {
        if (path.len == 0 or seen.contains(path)) return error.UnsafeSelection;
        try seen.put(path, {});
        for (bindings) |binding| {
            if (std.mem.eql(u8, path, binding.path)) return error.UnsafeSelection;
        }
        const entry = selectedEntry(entries, path) orelse return error.UnsafeSelection;
        if (!sweepSelectable(entry)) return error.UnsafeSelection;
        if (!allow_forced and decision(entry) != .reclaimable) return error.UnsafeSelection;
    }
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

const git_repository_environment = [_][]const u8{
    "GIT_DIR",        "GIT_WORK_TREE",             "GIT_COMMON_DIR",                   "GIT_IMPLICIT_WORK_TREE",
    "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",      "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_SHALLOW_FILE",
    "GIT_GRAFT_FILE", "GIT_REPLACE_REF_BASE",      "GIT_NO_REPLACE_OBJECTS",           "GIT_NAMESPACE",
    "GIT_PREFIX",     "GIT_INTERNAL_SUPER_PREFIX", "GIT_CEILING_DIRECTORIES",          "GIT_DISCOVERY_ACROSS_FILESYSTEM",
    "GIT_CONFIG",     "GIT_CONFIG_COUNT",          "GIT_CONFIG_PARAMETERS",
};

fn clearGitRepositoryEnvironment(environment: *std.process.EnvMap) void {
    // EnvMap matches Windows names case-insensitively. Keep config locations,
    // credentials and executable discovery; injected config can change scope.
    for (git_repository_environment) |key| environment.remove(key);
}

fn runGit(allocator: std.mem.Allocator, args: []const []const u8) !GitResult {
    var environment = try std.process.getEnvMap(allocator);
    defer environment.deinit();
    clearGitRepositoryEnvironment(&environment);
    var child = std.process.Child.init(args, allocator);
    child.env_map = &environment;
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
                // Windows kill can observe exit before it has closed the handles.
                _ = child.wait() catch |wait_error| {
                    std.log.err("Git failure {s}; child reap failed: {s}", .{ @errorName(primary_error), @errorName(wait_error) });
                };
            } else {
                std.log.err("Git failure {s}; child cleanup failed: {s}", .{ @errorName(primary_error), @errorName(cleanup_error) });
            }
        };
    };
    const output_limit = 1024 * 1024;
    try child.collectOutput(allocator, &stdout, &stderr, output_limit);
    if (stdout.items.len > output_limit) return error.StdoutStreamTooLong;
    if (stderr.items.len > output_limit) return error.StderrStreamTooLong;
    const term = try child.wait();
    waited = true;
    switch (term) {
        .Exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
    // Transfer stdout only after the last child operation; stderr always stays owned here.
    return .{ .output = try stdout.toOwnedSlice(allocator) };
}

pub const Action = enum { inspect, reclaim };

pub const CommandError = error{EmptyProjectPath};
pub const ReclaimError = error{ PolicyDisabled, ConfirmationRequired, UnsafeSelection };

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
        } else if (current != null and std.mem.startsWith(u8, line, "locked")) {
            current.?.locked = true;
        } else if (current != null and std.mem.startsWith(u8, line, "prunable")) {
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
        "primary",  "locked",          "dirty", "untracked", "conflicted", "unpushed",
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

test "policy decoding fails closed and round trips explicit settings" {
    try std.testing.expectError(error.MalformedPolicy, decodePolicy("{}"));
    try std.testing.expectError(error.MalformedPolicy, decodePolicy(
        "{\"allowReclaim\":true,\"confirmEachReclaim\":false,\"unknown\":true}",
    ));
    try std.testing.expectError(error.MalformedPolicy, decodePolicy(
        "{\"allowReclaim\":\"true\",\"confirmEachReclaim\":false}",
    ));
    try std.testing.expectError(error.MalformedPolicy, decodePolicy(
        "{\"allowReclaim\":true,\"confirmEachReclaim\":}",
    ));
    const encoded = try encodePolicy(std.testing.allocator, .{ .allow_reclaim = true, .confirm_each_reclaim = false });
    defer std.testing.allocator.free(encoded);
    const decoded = try decodePolicy(encoded);
    try std.testing.expect(decoded.allow_reclaim);
    try std.testing.expect(!decoded.confirm_each_reclaim);
    try std.testing.expectEqual(ResolveAction.remove, decoded.effectiveResolveAction());
    try std.testing.expectEqual(@as(u32, 2), decoded.notice_size_gb);
    try std.testing.expectEqual(@as(u32, 8), decoded.notice_count);

    var ask = Policy{};
    ask.applyResolveAction(.ask);
    ask.notice_size_gb = 4;
    ask.notice_count = 12;
    const ask_encoded = try encodePolicy(std.testing.allocator, ask);
    defer std.testing.allocator.free(ask_encoded);
    const ask_decoded = try decodePolicy(ask_encoded);
    try std.testing.expectEqual(ResolveAction.ask, ask_decoded.effectiveResolveAction());
    try std.testing.expectEqual(@as(u32, 4), ask_decoded.notice_size_gb);
    try std.testing.expectEqual(@as(u32, 12), ask_decoded.notice_count);
    try std.testing.expect(!canReclaim(.{ .path = @constCast("safe"), .branch = @constCast("main"), .pushed = true, .landed = true }, .{}, true));
}

test "Explorer command line preserves Windows Unicode arguments" {
    const command_line = try explorerCommandLine(std.testing.allocator, "C:\\工作 space\\review");
    defer std.testing.allocator.free(command_line);
    try std.testing.expectEqualStrings("explorer.exe /select,\"C:\\工作 space\\review\"", command_line);
}

test "selected batch validation rejects duplicate missing bound and unsafe rows before removal" {
    var entries = [_]Entry{
        .{ .path = @constCast("safe"), .branch = @constCast("safe"), .pushed = true, .landed = true },
        .{ .path = @constCast("dirty"), .branch = @constCast("dirty"), .dirty = true, .pushed = true, .landed = true },
    };
    try validateSelected(std.testing.allocator, &entries, &[_][]const u8{"safe"}, &.{});
    try std.testing.expectError(error.UnsafeSelection, validateSelected(
        std.testing.allocator,
        &entries,
        &[_][]const u8{ "safe", "safe" },
        &.{},
    ));
    try std.testing.expectError(error.UnsafeSelection, validateSelected(
        std.testing.allocator,
        &entries,
        &[_][]const u8{"missing"},
        &.{},
    ));
    try std.testing.expectError(error.UnsafeSelection, validateSelected(
        std.testing.allocator,
        &entries,
        &[_][]const u8{"safe"},
        &.{.{ .path = "safe" }},
    ));
    try std.testing.expectError(error.UnsafeSelection, validateSelected(
        std.testing.allocator,
        &entries,
        &[_][]const u8{"dirty"},
        &.{},
    ));
}

test "sweep selection allows human-confirmed dirty rows but rejects locked and bound rows" {
    try std.testing.expect(sweepSelectable(.{
        .path = @constCast("dirty"),
        .branch = @constCast("dirty"),
        .dirty = true,
    }));
    try std.testing.expect(!sweepSelectable(.{
        .path = @constCast("locked"),
        .branch = @constCast("locked"),
        .locked = true,
    }));
    try std.testing.expect(!sweepSelectable(.{
        .path = @constCast("running"),
        .branch = @constCast("running"),
        .bound_running = true,
    }));
    try std.testing.expect(discardsFiles(.{
        .path = @constCast("dirty"),
        .branch = @constCast("dirty"),
        .dirty = true,
    }));
}

test "scoped Git environment removes routing keys without clearing ordinary configuration" {
    var environment = std.process.EnvMap.init(std.testing.allocator);
    defer environment.deinit();
    for (git_repository_environment) |key| {
        const spelling = try std.testing.allocator.dupe(u8, key);
        defer std.testing.allocator.free(spelling);
        if (@import("builtin").os.tag == .windows) {
            for (spelling, 0..) |*byte, index| {
                if (index % 2 == 0) byte.* = std.ascii.toLower(byte.*);
            }
        }
        try environment.put(spelling, "synthetic-routing");
    }
    try environment.put("GIT_CONFIG_GLOBAL", "synthetic-config");
    try environment.put("GIT_CONFIG_SYSTEM", "synthetic-system-config");
    try environment.put("GIT_ASKPASS", "synthetic-askpass");
    try environment.put("PATH", "synthetic-path");
    clearGitRepositoryEnvironment(&environment);
    for (git_repository_environment) |key| try std.testing.expect(environment.get(key) == null);
    try std.testing.expectEqual(@as(usize, 4), environment.count());
}

test "subprocess fixtures accept only exact supported selectors" {
    try std.testing.expectEqual(@as(usize, 17), SubprocessTests.scenarios.len);
    for (SubprocessTests.scenarios) |scenario| try SubprocessTests.validateScenario(scenario);
    for ([_][]const u8{
        "",               "scope",                  "scope-config",             "scope-config-countt",    "Scope-config-count",
        "removal-output", "removal-output-directt", "removal-output-selectedt", "removal-output-forcedt",
    }) |scenario| {
        try std.testing.expectError(error.UnknownFixtureScenario, SubprocessTests.validateScenario(scenario));
    }
}

// Explicitly referenced only by the process harness's separate test root.
pub const SubprocessTests = if (@import("builtin").is_test) struct {
    const scenarios = [_][]const u8{
        "scope-dir",             "scope-mixed-case", "scope-config-count",    "scope-config-parameters",
        "index",                 "objects",          "preserve",              "streams",
        "stdout-cap",            "stderr-cap",       "errors",                "git-stderr",
        "allocations",           "removals",         "removal-output-direct", "removal-output-selected",
        "removal-output-forced",
    };

    fn validateScenario(scenario: []const u8) !void {
        for (scenarios) |supported| {
            if (std.mem.eql(u8, scenario, supported)) return;
        }
        return error.UnknownFixtureScenario;
    }

    pub fn run() !void {
        const allocator = std.testing.allocator;
        const scenario = try std.process.getEnvVarOwned(allocator, "GRAPHCODE_WORKTREE_TEST_CASE");
        defer allocator.free(scenario);
        var original_environment = try std.process.getEnvMap(allocator);
        defer original_environment.deinit();
        const root = try std.process.getEnvVarOwned(allocator, "GRAPHCODE_WORKTREE_TEST_ROOT");
        defer allocator.free(root);
        const gate = try std.fs.path.join(allocator, &.{ root, "start" });
        defer allocator.free(gate);
        const deadline = std.time.milliTimestamp() + 10_000;
        while (true) {
            std.fs.cwd().access(gate, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    if (std.time.milliTimestamp() >= deadline) return error.ProcessHarnessNotReady;
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };
            break;
        }
        try validateScenario(scenario);
        const emitter = try std.process.getEnvVarOwned(allocator, "GRAPHCODE_WORKTREE_TEST_CHILD");
        defer allocator.free(emitter);
        const target = try std.fs.path.join(allocator, &.{ root, "target" });
        defer allocator.free(target);
        const outside = try std.fs.path.join(allocator, &.{ root, "outside" });
        defer allocator.free(outside);
        try std.fs.cwd().makeDir(target);
        try std.fs.cwd().makeDir(outside);
        try fixtureGit(&.{ "git", "-C", target, "init", "-q", "-b", "main" });
        try fixtureGit(&.{ "git", "-C", outside, "init", "-q", "-b", "outside" });
        try fixtureGit(&.{ "git", "-C", target, "config", "graphcode.identity", "target" });
        try fixtureGit(&.{ "git", "-C", outside, "config", "graphcode.identity", "outside-control" });
        const outside_config = try std.fs.path.join(allocator, &.{ outside, ".git", "config" });
        defer allocator.free(outside_config);
        const before = try std.fs.cwd().readFileAlloc(allocator, outside_config, 4096);
        defer allocator.free(before);

        if (std.mem.eql(u8, scenario, "scope-dir") or std.mem.eql(u8, scenario, "scope-mixed-case") or
            std.mem.eql(u8, scenario, "scope-config-count") or std.mem.eql(u8, scenario, "scope-config-parameters"))
        {
            const identity = try runGit(allocator, &.{ "git", "-C", target, "rev-parse", "--show-toplevel" });
            defer allocator.free(identity.output);
            const normalized = try allocator.dupe(u8, target);
            defer allocator.free(normalized);
            std.mem.replaceScalar(u8, normalized, '\\', '/');
            std.debug.print("requested -C={s}; actual={s}; outside={s}\n", .{ normalized, std.mem.trim(u8, identity.output, "\r\n"), outside });
            const mutation = try runGit(allocator, &.{ "git", "-C", target, "config", "--local", "graphcode.identity", "target-after" });
            defer allocator.free(mutation.output);
            const after = try std.fs.cwd().readFileAlloc(allocator, outside_config, 4096);
            defer allocator.free(after);
            std.debug.print("outside config before={s}; after={s}\n", .{ before, after });
            try std.testing.expectEqualStrings(before, after);
            try std.testing.expectEqualStrings(normalized, std.mem.trim(u8, identity.output, "\r\n"));
            const target_identity = try runGit(allocator, &.{ "git", "-C", target, "config", "--local", "--get", "graphcode.identity" });
            defer allocator.free(target_identity.output);
            try std.testing.expectEqualStrings("target-after", std.mem.trim(u8, target_identity.output, "\r\n"));
            if (std.mem.eql(u8, scenario, "scope-config-count") or std.mem.eql(u8, scenario, "scope-config-parameters")) {
                try expectGitError(error.GitFailed, &.{ "git", "-C", target, "config", "--get", "graphcode.injected" });
            }
        } else if (std.mem.eql(u8, scenario, "index")) {
            const file = try std.fs.path.join(allocator, &.{ target, "target.txt" });
            defer allocator.free(file);
            try std.fs.cwd().writeFile(.{ .sub_path = file, .data = "owned-target\n" });
            const added = try runGit(allocator, &.{ "git", "-C", target, "add", "target.txt" });
            defer allocator.free(added.output);
            const index = try std.fs.path.join(allocator, &.{ target, ".git", "index" });
            defer allocator.free(index);
            try std.fs.cwd().access(index, .{});
            const outside_index = try std.fs.path.join(allocator, &.{ outside, ".git", "index" });
            defer allocator.free(outside_index);
            try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(outside_index, .{}));
        } else if (std.mem.eql(u8, scenario, "objects")) {
            const file = try std.fs.path.join(allocator, &.{ target, "target.txt" });
            defer allocator.free(file);
            try std.fs.cwd().writeFile(.{ .sub_path = file, .data = "owned-target-object\n" });
            const hashed = try runGit(allocator, &.{ "git", "-C", target, "hash-object", "-w", file });
            defer allocator.free(hashed.output);
            const hash = std.mem.trim(u8, hashed.output, "\r\n");
            try std.testing.expectEqual(@as(usize, 40), hash.len);
            const object = try std.fs.path.join(allocator, &.{ target, ".git", "objects", hash[0..2], hash[2..] });
            defer allocator.free(object);
            try std.fs.cwd().access(object, .{});
            const outside_object = try std.fs.path.join(allocator, &.{ outside, ".git", "objects", hash[0..2], hash[2..] });
            defer allocator.free(outside_object);
            try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(outside_object, .{}));
        } else if (std.mem.eql(u8, scenario, "preserve")) {
            const result = try runGit(allocator, &.{ emitter, "environment", root });
            defer allocator.free(result.output);
            try std.testing.expectEqualStrings("preserved\n", result.output);
            const config = try runGit(allocator, &.{ "git", "-C", target, "config", "--get", "graphcode.sentinel" });
            defer allocator.free(config.output);
            try std.testing.expectEqualStrings("synthetic-config", std.mem.trim(u8, config.output, "\r\n"));
        } else if (std.mem.eql(u8, scenario, "streams")) {
            for ([_][]const u8{ "empty", "stderr", "both", "boundary" }) |mode| {
                const result = try runGit(allocator, &.{ emitter, mode, root });
                defer allocator.free(result.output);
                const expected: usize = if (std.mem.eql(u8, mode, "both")) 256 * 1024 else if (std.mem.eql(u8, mode, "boundary")) 1024 * 1024 else 0;
                try std.testing.expectEqual(expected, result.output.len);
                for (result.output) |byte| try std.testing.expectEqual(@as(u8, 'o'), byte);
            }
        } else if (std.mem.eql(u8, scenario, "stdout-cap")) {
            try expectGitError(error.StdoutStreamTooLong, &.{ emitter, "stdout-cap", root });
            try expectFixtureChildExited(root);
        } else if (std.mem.eql(u8, scenario, "stderr-cap")) {
            try expectGitError(error.StderrStreamTooLong, &.{ emitter, "stderr-cap", root });
            try expectFixtureChildExited(root);
        } else if (std.mem.eql(u8, scenario, "errors")) {
            try expectGitError(error.GitFailed, &.{ emitter, "nonzero", root });
            const missing = try std.fs.path.join(allocator, &.{ root, "no-such-owned-executable.exe" });
            defer allocator.free(missing);
            try expectGitError(error.FileNotFound, &.{missing});
            try expectGitError(error.GitFailed, &.{ "git", "-C", target, "rev-parse", "--verify", "missing-owned-ref" });
        } else if (std.mem.eql(u8, scenario, "git-stderr")) {
            const arg = try allocator.alloc(u8, 12 * 1024);
            defer allocator.free(arg);
            @memset(arg, 'x');
            // A real Git diagnostic larger than its pipe capacity, not a mock runner.
            try expectGitError(error.GitFailed, &.{ "git", "-C", target, arg });
        } else if (std.mem.eql(u8, scenario, "allocations")) {
            try fixtureRunAllocation(allocator, emitter, root);
            const handles_before = try fixtureHandleCount();
            try std.testing.checkAllAllocationFailures(allocator, fixtureRunAllocation, .{ emitter, root });
            const handles_after = try fixtureHandleCount();
            try std.testing.expectEqual(handles_before, handles_after);
            std.debug.print("all allocation failures checked; process handles before={d}, after={d}\n", .{ handles_before, handles_after });
        } else if (std.mem.eql(u8, scenario, "removal-output-direct") or std.mem.eql(u8, scenario, "removal-output-selected") or
            std.mem.eql(u8, scenario, "removal-output-forced"))
        {
            const path = try std.fs.path.join(allocator, &.{ root, "selected" });
            defer allocator.free(path);
            try std.fs.cwd().makeDir(path);
            if (std.mem.eql(u8, scenario, "removal-output-direct")) {
                const entries = [_]Entry{.{ .path = path, .branch = @constCast("feature"), .pushed = true, .landed = true }};
                try std.testing.expectEqual(@as(usize, 1), try reclaim(allocator, &entries));
            } else {
                std.mem.replaceScalar(u8, path, '\\', '/');
                try std.testing.expectEqual(@as(usize, 1), try reclaimSelectedWithPolicyMode(
                    allocator,
                    target,
                    &.{path},
                    &.{},
                    .{ .allow_reclaim = true },
                    true,
                    std.mem.eql(u8, scenario, "removal-output-forced"),
                ));
            }
            // This fixture verifies allocated output ownership, not real Git deletion.
            try std.fs.cwd().access(path, .{});
        } else if (std.mem.eql(u8, scenario, "removals")) {
            try fixtureGit(&.{ "git", "-C", target, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "--allow-empty", "-m", "owned fixture" });
            try fixtureGit(&.{ "git", "-C", target, "update-ref", "refs/remotes/origin/main", "HEAD" });
            try fixtureGit(&.{ "git", "-C", target, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" });
            for ([_][]const u8{ "selected", "forced" }) |mode| {
                const path = try std.fs.path.join(allocator, &.{ root, mode });
                defer allocator.free(path);
                try fixtureGit(&.{ "git", "-C", target, "worktree", "add", "-q", "-b", mode, path });
                const remote_key = try std.fmt.allocPrint(allocator, "branch.{s}.remote", .{mode});
                defer allocator.free(remote_key);
                const merge_key = try std.fmt.allocPrint(allocator, "branch.{s}.merge", .{mode});
                defer allocator.free(merge_key);
                try fixtureGit(&.{ "git", "-C", path, "config", remote_key, "." });
                try fixtureGit(&.{ "git", "-C", path, "config", merge_key, "refs/heads/main" });
                {
                    const forced = std.mem.eql(u8, mode, "forced");
                    if (forced) {
                        const dirty = try std.fs.path.join(allocator, &.{ path, "untracked.txt" });
                        defer allocator.free(dirty);
                        try std.fs.cwd().writeFile(.{ .sub_path = dirty, .data = "owned dirty fixture" });
                    }
                    // Git porcelain uses forward slashes even on Windows.
                    std.mem.replaceScalar(u8, path, '\\', '/');
                    try std.testing.expectEqual(@as(usize, 1), try reclaimSelectedWithPolicyMode(
                        allocator,
                        target,
                        &.{path},
                        &.{},
                        .{ .allow_reclaim = true },
                        true,
                        forced,
                    ));
                }
                try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(path, .{}));
            }
        } else return error.UnknownFixtureScenario;
        var after_environment = try std.process.getEnvMap(allocator);
        defer after_environment.deinit();
        try std.testing.expectEqual(original_environment.count(), after_environment.count());
        var iterator = original_environment.iterator();
        while (iterator.next()) |entry| {
            const after = after_environment.get(entry.key_ptr.*) orelse return error.ParentEnvironmentChanged;
            try std.testing.expect(std.mem.eql(u8, entry.value_ptr.*, after));
        }
    }

    fn expectGitError(expected: anyerror, args: []const []const u8) !void {
        const result = runGit(std.testing.allocator, args) catch |err| {
            try std.testing.expectEqual(expected, err);
            return;
        };
        std.testing.allocator.free(result.output);
        return error.ExpectedGitError;
    }

    const ProcessApi = struct {
        extern "kernel32" fn OpenProcess(access: u32, inherit: i32, process_id: u32) callconv(.winapi) ?std.os.windows.HANDLE;
        extern "kernel32" fn GetProcessHandleCount(process: std.os.windows.HANDLE, count: *u32) callconv(.winapi) i32;
    };

    fn fixtureHandleCount() !u32 {
        var count: u32 = 0;
        if (ProcessApi.GetProcessHandleCount(std.os.windows.GetCurrentProcess(), &count) == 0) return error.HandleCountFailed;
        return count;
    }

    fn expectFixtureChildExited(root: []const u8) !void {
        const allocator = std.testing.allocator;
        const path = try std.fs.path.join(allocator, &.{ root, "child.pid" });
        defer allocator.free(path);
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 32);
        defer allocator.free(bytes);
        const pid = try std.fmt.parseInt(u32, bytes, 10);
        const windows = std.os.windows;
        const handle = ProcessApi.OpenProcess(windows.SYNCHRONIZE, windows.FALSE, pid) orelse {
            if (windows.GetLastError() == .INVALID_PARAMETER) return;
            return error.ChildExitCheckFailed;
        };
        defer windows.CloseHandle(handle);
        try windows.WaitForSingleObjectEx(handle, 0, false);
    }

    fn fixtureRunAllocation(allocator: std.mem.Allocator, emitter: []const u8, root: []const u8) !void {
        const result = try runGit(allocator, &.{ emitter, "both", root });
        defer allocator.free(result.output);
        try std.testing.expectEqual(@as(usize, 256 * 1024), result.output.len);
    }

    fn fixtureGit(args: []const []const u8) !void {
        const allocator = std.testing.allocator;
        var inherited = try std.process.getEnvMap(allocator);
        defer inherited.deinit();
        var environment = std.process.EnvMap.init(allocator);
        defer environment.deinit();
        var iterator = inherited.iterator();
        while (iterator.next()) |entry| {
            if (std.ascii.startsWithIgnoreCase(entry.key_ptr.*, "GIT_")) continue;
            try environment.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        try environment.put("GIT_CONFIG_NOSYSTEM", "1");
        try environment.put("GIT_CONFIG_GLOBAL", "NUL");
        const real_git = try std.process.getEnvVarOwned(allocator, "GRAPHCODE_WORKTREE_TEST_REAL_GIT");
        defer allocator.free(real_git);
        const fixture_args = try allocator.dupe([]const u8, args);
        defer allocator.free(fixture_args);
        fixture_args[0] = real_git;
        var child = std.process.Child.init(fixture_args, allocator);
        child.env_map = &environment;
        child.create_no_window = true;
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        const term = try child.spawnAndWait();
        try std.testing.expect(term == .Exited and term.Exited == 0);
    }
} else void;
