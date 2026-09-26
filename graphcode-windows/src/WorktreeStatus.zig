const std = @import("std");

pub const Entry = struct {
    path: []u8,
    branch: []u8,
    size_bytes: u64 = 0,
    size_complete: bool = false,
    size_error: ?anyerror = null,
    primary: bool = false,
    locked: bool = false,
    prunable: bool = false,
    dirty: bool = false,
    untracked: bool = false,
    conflicted: bool = false,
    pushed: bool = false,
    landed: bool = false,
    bound_running: bool = false,

    pub fn sizeCoverage(self: Entry) SizeCoverage {
        return .{
            .bytes = self.size_bytes,
            .complete = self.size_complete and self.size_error == null,
            .first_error = self.size_error,
        };
    }

    fn setSize(self: *Entry, size: SizeCoverage) void {
        self.size_bytes = size.bytes;
        self.size_complete = size.complete;
        self.size_error = size.first_error;
    }
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

pub const PolicySource = enum { missing, legacy, configured };
pub const LoadedPolicy = struct { policy: Policy, source: PolicySource };
pub const PolicyOutcome = union(enum) {
    not_loaded,
    known: LoadedPolicy,
    failed: anyerror,

    pub fn value(self: PolicyOutcome) ?Policy {
        return switch (self) {
            .known => |loaded| loaded.policy,
            else => null,
        };
    }
};

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
    return (try decodePolicyWithSource(bytes)).policy;
}

fn decodePolicyWithSource(bytes: []const u8) PolicyParseError!LoadedPolicy {
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
    return .{ .policy = policy, .source = if (object.count() == 2) .legacy else .configured };
}

pub fn policyReadOutcome(bytes: anyerror![]const u8) PolicyOutcome {
    const content = bytes catch |err| return if (err == error.FileNotFound)
        .{ .known = .{ .policy = .{}, .source = .missing } }
    else
        .{ .failed = err };
    return .{ .known = decodePolicyWithSource(content) catch |err| return .{ .failed = err } };
}

pub fn loadPolicyOutcome(allocator: std.mem.Allocator, project_path: []const u8) PolicyOutcome {
    const path = policyPath(allocator, project_path) catch |err| return .{ .failed = err };
    defer allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 4096) catch |err| return policyReadOutcome(err);
    defer allocator.free(bytes);
    return policyReadOutcome(bytes);
}

pub fn loadPolicy(allocator: std.mem.Allocator, project_path: []const u8) Policy {
    return loadPolicyOutcome(allocator, project_path).value() orelse .{};
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

pub const SizeCoverage = struct {
    /// A lower bound when measurement is incomplete.
    bytes: u64 = 0,
    complete: bool = true,
    first_error: ?anyerror = null,

    fn recordFile(self: *SizeCoverage, outcome: anyerror!u64) void {
        const bytes = outcome catch |err| {
            self.recordFailure(err);
            return;
        };
        self.bytes = std.math.add(u64, self.bytes, bytes) catch |err| {
            self.recordFailure(err);
            self.bytes = std.math.maxInt(u64);
            return;
        };
    }

    fn recordFailure(self: *SizeCoverage, err: anyerror) void {
        self.complete = false;
        if (self.first_error == null) self.first_error = err;
    }

    fn include(self: *SizeCoverage, size: SizeCoverage) void {
        if (size.first_error) |err| self.recordFailure(err);
        self.complete = self.complete and size.complete;
        self.recordFile(size.bytes);
    }
};

fn directorySizeResult(outcome: anyerror!SizeCoverage) SizeCoverage {
    return outcome catch |err| {
        var size = SizeCoverage{};
        size.recordFailure(err);
        return size;
    };
}

pub fn totalSize(entries: []const Entry) SizeCoverage {
    var size = SizeCoverage{};
    for (entries) |entry| size.include(entry.sizeCoverage());
    return size;
}

pub const NoticeState = enum { below_threshold, notice, indeterminate };

pub fn noticeState(entries: []const Entry, policy: Policy) NoticeState {
    return evaluateNotice(summarize(entries), totalSize(entries), policy);
}

pub fn evaluateNotice(summary: Summary, size: SizeCoverage, policy: Policy) NoticeState {
    if (summary.total >= policy.notice_count or
        size.bytes >= @as(u64, policy.notice_size_gb) * 1024 * 1024 * 1024)
        return .notice;
    return if (size.complete and size.first_error == null) .below_threshold else .indeterminate;
}

pub const NoticeObservation = struct {
    summary: Summary,
    size: SizeCoverage,
};

pub const StaleReason = enum { bindings_changed, bindings_unavailable, connection_changed, worktrees_changed };

/// Advisory values for notices, not authority to reclaim worktrees.
pub const NoticeRecord = struct {
    observation: ?NoticeObservation = null,
    policy: PolicyOutcome = .not_loaded,
    stale: ?StaleReason = null,
    stale_error: ?anyerror = null,
    refresh_error: ?anyerror = null,

    pub fn inspected(inspection: *const Inspection, policy: PolicyOutcome) NoticeRecord {
        return .{
            .observation = .{
                .summary = summarize(inspection.entries.items),
                .size = totalSize(inspection.entries.items),
            },
            .policy = policy,
        };
    }

    pub fn state(self: NoticeRecord) NoticeState {
        if (self.stale != null or self.refresh_error != null) return .indeterminate;
        const observation = self.observation orelse return .indeterminate;
        const policy = self.policy.value() orelse return .indeterminate;
        return evaluateNotice(observation.summary, observation.size, policy);
    }
};

pub const NoticePhase = enum { uninspected, observed, incomplete_size, unknown_policy, stale, failed };

pub const NoticePresentation = struct {
    phase: NoticePhase,
    summary: ?Summary = null,
    state: NoticeState = .indeterminate,
    failure: ?anyerror = null,

    pub fn fromRecord(record: ?NoticeRecord) ?NoticePresentation {
        const current = record orelse return .{ .phase = .uninspected };
        const summary = if (current.observation) |value| value.summary else null;
        if (current.refresh_error) |err| return .{ .phase = .failed, .summary = summary, .failure = err };
        const policy_error: ?anyerror = switch (current.policy) {
            .failed => |err| err,
            else => null,
        };
        if (current.policy.value() == null and (summary != null or policy_error != null))
            return .{ .phase = .unknown_policy, .summary = summary, .failure = policy_error };
        if (current.stale != null) return .{ .phase = .stale, .summary = summary, .failure = current.stale_error };
        const observation = current.observation orelse return .{ .phase = .uninspected };
        if (!observation.size.complete or observation.size.first_error != null)
            return .{ .phase = .incomplete_size, .summary = summary, .state = current.state(), .failure = observation.size.first_error };
        if (observation.summary.total == 0) return null;
        return .{ .phase = .observed, .summary = summary, .state = current.state() };
    }

    pub fn label(self: NoticePresentation, allocator: std.mem.Allocator) ![]u8 {
        const prefix = switch (self.phase) {
            .uninspected => "Worktrees not inspected",
            .observed => "Last inspected",
            .incomplete_size => "Size incomplete",
            .unknown_policy => "Policy unavailable",
            .stale => "Stale inspection",
            .failed => "Inspection failed",
        };
        const counts = if (self.summary) |summary| blk: {
            const count = try std.fmt.allocPrint(allocator, "{d} worktree{s}", .{ summary.total, if (summary.total == 1) "" else "s" });
            defer allocator.free(count);
            break :blk if (summary.reclaimable != 0)
                try std.fmt.allocPrint(allocator, ": {s} - {d} reclaimable", .{ count, summary.reclaimable })
            else
                try std.fmt.allocPrint(allocator, ": {s}", .{count});
        } else try allocator.dupe(u8, "");
        defer allocator.free(counts);
        const detail = if (self.failure) |err|
            try std.fmt.allocPrint(allocator, " ({s})", .{@errorName(err)})
        else
            try allocator.dupe(u8, "");
        defer allocator.free(detail);
        return std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{
            prefix,
            counts,
            if (self.summary != null and self.phase != .observed) " (last inspected)" else "",
            detail,
        });
    }
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

pub fn sizeCoverageText(allocator: std.mem.Allocator, size: SizeCoverage) ![]u8 {
    if (size.complete and size.first_error == null) return sizeText(allocator, size.bytes);
    if (size.bytes == 0) {
        if (size.first_error) |err| return std.fmt.allocPrint(allocator, "size unavailable ({s})", .{@errorName(err)});
        return allocator.dupe(u8, "size not measured");
    }
    const measured = try sizeText(allocator, size.bytes);
    defer allocator.free(measured);
    if (size.first_error) |err|
        return std.fmt.allocPrint(allocator, "about {s} measured (size incomplete: {s})", .{ measured, @errorName(err) });
    return std.fmt.allocPrint(allocator, "about {s} measured (size incomplete)", .{measured});
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
        entry.setSize(directorySizeResult(directorySize(entry.path)));
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

fn directorySize(path: []const u8) !SizeCoverage {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(std.heap.page_allocator);
    defer walker.deinit();
    var total = SizeCoverage{};
    while (walker.next() catch |err| {
        total.recordFailure(err);
        return total;
    }) |item| {
        if (item.kind != .file) continue;
        total.recordFile(if (item.dir.statFile(item.basename)) |stat| stat.size else |err| err);
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
        _ = try runGit(allocator, &.{
            "git", "-C", entry.path, "worktree", "remove", entry.path,
        });
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
    defer {
        deinit(allocator, &inspection.entries);
        allocator.free(inspection.default_branch);
    }
    try validateSelectedMode(allocator, inspection.entries.items, selected, bindings, allow_forced);
    var removed: usize = 0;
    for (selected) |path| {
        const entry = selectedEntry(inspection.entries.items, path) orelse return error.UnsafeSelection;
        if (allow_forced and discardsFiles(entry)) {
            _ = try runGit(allocator, &.{ "git", "-C", project_path, "worktree", "remove", "--force", path });
        } else {
            _ = try runGit(allocator, &.{ "git", "-C", project_path, "worktree", "remove", path });
        }
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

test "worktree notice sizing failure is not a complete zero" {
    for ([_]anyerror{ error.FileNotFound, error.AccessDenied }) |failure| {
        const size = directorySizeResult(failure);
        try std.testing.expect(!size.complete);
        try std.testing.expectEqual(@as(u64, 0), size.bytes);
        try std.testing.expectEqual(@as(?anyerror, failure), size.first_error);
    }
}

test "worktree notice sizing stat failure preserves known bytes and original error" {
    var size = SizeCoverage{};
    size.recordFile(23);
    size.recordFile(error.AccessDenied);
    size.recordFile(19);
    size.recordFile(error.FileNotFound);
    try std.testing.expectEqual(@as(u64, 42), size.bytes);
    try std.testing.expect(!size.complete);
    try std.testing.expectEqual(@as(?anyerror, error.AccessDenied), size.first_error);
}

test "worktree notice sizing successful zero and nonzero are complete" {
    for ([_]u64{ 0, 42 }) |bytes| {
        var measured = SizeCoverage{};
        measured.recordFile(bytes);
        const size = directorySizeResult(measured);
        try std.testing.expect(size.complete);
        try std.testing.expectEqual(bytes, size.bytes);
        try std.testing.expectEqual(@as(?anyerror, null), size.first_error);
    }
}

test "worktree notice production inspection compiles without invoking IO" {
    std.mem.doNotOptimizeAway(&inspect);
}

test "worktree notice entry mapping retains incomplete coverage and known byte lower bounds" {
    var entries = [_]Entry{
        .{ .path = @constCast("measured"), .branch = @constCast("main") },
        .{ .path = @constCast("partial"), .branch = @constCast("topic") },
        .{ .path = @constCast("missing"), .branch = @constCast("stale"), .prunable = true },
    };
    entries[0].setSize(directorySizeResult(.{ .bytes = 1024 }));
    var partial = SizeCoverage{};
    partial.recordFile(2048);
    partial.recordFile(error.AccessDenied);
    partial.recordFile(1024);
    entries[1].setSize(directorySizeResult(partial));
    entries[2].setSize(directorySizeResult(error.FileNotFound));
    const size = totalSize(&entries);
    try std.testing.expectEqual(@as(u64, 4096), size.bytes);
    try std.testing.expect(!size.complete);
    try std.testing.expectEqual(@as(?anyerror, error.AccessDenied), size.first_error);
    try std.testing.expectEqual(@as(u64, 3072), entries[1].size_bytes);
    try std.testing.expectEqual(@as(?anyerror, error.FileNotFound), entries[2].size_error);
    try std.testing.expectEqual(NoticeState.indeterminate, noticeState(&entries, .{}));
}

test "worktree notice count boundaries preserve every Windows inspection row" {
    var entries = [_]Entry{.{
        .path = @constCast("worktree"),
        .branch = @constCast("topic"),
        .size_complete = true,
    }} ** 13;
    entries[0].primary = true;
    entries[1].prunable = true;
    entries[2].locked = true;
    entries[3].branch = @constCast("");
    const configured = try decodePolicy(
        \\{"allowReclaim":false,"confirmEachReclaim":true,"onResolveLanded":"keep","noticeSizeGB":4,"noticeCount":12}
    );
    const cases = [_]struct { policy: Policy, counts: [3]usize }{
        .{ .policy = .{}, .counts = .{ 7, 8, 9 } },
        .{ .policy = configured, .counts = .{ 11, 12, 13 } },
    };
    for (cases) |case| {
        for (case.counts, [_]NoticeState{ .below_threshold, .notice, .notice }) |count, expected| {
            try std.testing.expectEqual(count, summarize(entries[0..count]).total);
            try std.testing.expectEqual(expected, noticeState(entries[0..count], case.policy));
        }
    }
}

test "worktree notice exact byte boundaries use decoded binary GiB policy" {
    var entries = [_]Entry{
        .{ .path = @constCast("primary"), .branch = @constCast("main"), .primary = true, .size_complete = true },
        .{ .path = @constCast("linked"), .branch = @constCast("topic"), .size_complete = true },
    };
    const configured = try decodePolicy(
        \\{"allowReclaim":false,"confirmEachReclaim":true,"onResolveLanded":"keep","noticeSizeGB":4,"noticeCount":12}
    );
    const cases = [_]struct { policy: Policy, bytes: [3]u64 }{
        .{ .policy = .{}, .bytes = .{ 2147483647, 2147483648, 2147483649 } },
        .{ .policy = configured, .bytes = .{ 4294967295, 4294967296, 4294967297 } },
    };
    entries[0].size_bytes = 1024;
    for (cases) |case| {
        for (case.bytes, [_]NoticeState{ .below_threshold, .notice, .notice }) |bytes, expected| {
            entries[1].size_bytes = bytes - 1024;
            try std.testing.expectEqual(bytes, totalSize(&entries).bytes);
            try std.testing.expectEqual(expected, noticeState(&entries, case.policy));
        }
    }
}

test "worktree notice unknown coverage differs from zero and independent breaches still warn" {
    var entries = [_]Entry{.{
        .path = @constCast("unmeasured"),
        .branch = @constCast("topic"),
    }} ** 8;
    try std.testing.expectEqual(NoticeState.below_threshold, noticeState(&.{}, .{}));
    try std.testing.expectEqual(NoticeState.indeterminate, noticeState(entries[0..1], .{}));
    entries[0].setSize(.{});
    try std.testing.expectEqual(NoticeState.below_threshold, noticeState(entries[0..1], .{}));
    try std.testing.expectEqual(NoticeState.indeterminate, noticeState(entries[0..2], .{}));
    try std.testing.expectEqual(NoticeState.notice, noticeState(&entries, .{}));
    entries[0].setSize(.{ .bytes = 2147483647, .complete = false, .first_error = error.AccessDenied });
    try std.testing.expectEqual(NoticeState.indeterminate, noticeState(entries[0..2], .{}));
    entries[0].size_bytes = 2147483648;
    try std.testing.expectEqual(NoticeState.notice, noticeState(entries[0..2], .{}));
    try std.testing.expectEqual(@as(?anyerror, error.AccessDenied), totalSize(entries[0..2]).first_error);
}

test "worktree notice size accumulation saturates without claiming completeness" {
    var size = SizeCoverage{ .bytes = std.math.maxInt(u64) };
    size.recordFile(1);
    try std.testing.expectEqual(std.math.maxInt(u64), size.bytes);
    try std.testing.expect(!size.complete);
    try std.testing.expectEqual(@as(?anyerror, error.Overflow), size.first_error);
}

fn expectNoticeSizeFormatting(allocator: std.mem.Allocator) !void {
    const cases = [_]struct { size: SizeCoverage, text: []const u8 }{
        .{ .size = .{}, .text = "0 B" },
        .{ .size = .{ .bytes = 2048 }, .text = "2.0 KB" },
        .{ .size = .{ .complete = false }, .text = "size not measured" },
        .{ .size = .{ .complete = false, .first_error = error.AccessDenied }, .text = "size unavailable (AccessDenied)" },
        .{ .size = .{ .bytes = 2048, .complete = false }, .text = "about 2.0 KB measured (size incomplete)" },
        .{ .size = .{ .bytes = 2048, .complete = false, .first_error = error.AccessDenied }, .text = "about 2.0 KB measured (size incomplete: AccessDenied)" },
    };
    for (cases) |case| {
        const text = try sizeCoverageText(allocator, case.size);
        defer allocator.free(text);
        try std.testing.expectEqualStrings(case.text, text);
    }
}

test "worktree notice size formatting distinguishes zero unknown partial and failures without leaks" {
    try expectNoticeSizeFormatting(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, expectNoticeSizeFormatting, .{});
}

test "worktree notice incomplete display does not overstate rounded byte bounds" {
    const cases = [_]struct { bytes: u64, text: []const u8 }{
        .{ .bytes = 1535, .text = "about 1.5 KB measured (size incomplete)" },
        .{ .bytes = 2147483647, .text = "about 2.0 GB measured (size incomplete)" },
    };
    for (cases) |case| {
        var entry = Entry{ .path = @constCast("partial"), .branch = @constCast("topic") };
        entry.setSize(.{ .bytes = case.bytes, .complete = false });
        const text = try sizeCoverageText(std.testing.allocator, entry.sizeCoverage());
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(case.text, text);
        try std.testing.expectEqual(case.bytes, entry.size_bytes);
        try std.testing.expectEqual(NoticeState.indeterminate, noticeState(&.{entry}, .{}));
    }
}

test "worktree notice coverage never changes reclaim decisions" {
    var entry = Entry{
        .path = @constCast("safe"),
        .branch = @constCast("topic"),
        .pushed = true,
        .landed = true,
    };
    const policy = Policy{ .allow_reclaim = true, .confirm_each_reclaim = true };
    const cases = [_]SizeCoverage{
        .{},
        .{ .bytes = 2147483648 },
        .{ .complete = false },
        .{ .bytes = 1024, .complete = false, .first_error = error.AccessDenied },
    };
    for (cases) |size| {
        entry.setSize(size);
        try std.testing.expectEqual(ReclaimDecision.reclaimable, decision(entry));
        try std.testing.expect(canReclaim(entry, policy, true));
        try std.testing.expect(!canReclaim(entry, policy, false));
        try std.testing.expect(!canReclaim(entry, .{}, true));
        entry.primary = true;
        try std.testing.expectEqual(ReclaimDecision.keep, decision(entry));
        try std.testing.expect(!canReclaim(entry, policy, true));
        entry.primary = false;
    }
}

test "worktree notice policy outcomes distinguish missing legacy configured and unreadable" {
    const missing = policyReadOutcome(error.FileNotFound);
    try std.testing.expectEqual(PolicySource.missing, missing.known.source);
    try std.testing.expectEqual(@as(u32, 8), missing.value().?.notice_count);
    const legacy = policyReadOutcome("{\"allowReclaim\":true,\"confirmEachReclaim\":true}");
    try std.testing.expectEqual(PolicySource.legacy, legacy.known.source);
    try std.testing.expectEqual(@as(u32, 2), legacy.value().?.notice_size_gb);
    try std.testing.expect(legacy.value().?.allow_reclaim);
    const configured = policyReadOutcome(
        \\{"allowReclaim":false,"confirmEachReclaim":true,"onResolveLanded":"keep","noticeSizeGB":4,"noticeCount":12}
    );
    try std.testing.expectEqual(PolicySource.configured, configured.known.source);
    try std.testing.expectEqual(@as(u32, 12), configured.value().?.notice_count);
    try std.testing.expectEqual(@as(u32, 4), configured.value().?.notice_size_gb);
    const malformed = policyReadOutcome("{");
    try std.testing.expectEqual(error.MalformedPolicy, malformed.failed);
    const unreadable = policyReadOutcome(error.AccessDenied);
    try std.testing.expectEqual(error.AccessDenied, unreadable.failed);
    try std.testing.expect(malformed.value() == null);
    try std.testing.expect(unreadable.value() == null);
    try std.testing.expect(!((unreadable.value() orelse Policy{}).allow_reclaim));
}

fn expectNoticePresentation(allocator: std.mem.Allocator) !void {
    const uninspected = NoticePresentation.fromRecord(null).?;
    const unknown_text = try uninspected.label(allocator);
    defer allocator.free(unknown_text);
    try std.testing.expectEqualStrings("Worktrees not inspected", unknown_text);
    try std.testing.expectEqual(NoticeState.indeterminate, uninspected.state);

    var inspection = Inspection{
        .entries = std.array_list.Managed(Entry).init(allocator),
        .project_path = @constCast("C:\\owned"),
        .default_branch = @constCast("main"),
    };
    defer inspection.entries.deinit();
    try inspection.entries.append(.{ .path = @constCast("tree"), .branch = @constCast("topic"), .pushed = true, .landed = true });
    const policy = policyReadOutcome(
        \\{"allowReclaim":false,"confirmEachReclaim":true,"onResolveLanded":"keep","noticeSizeGB":2,"noticeCount":1}
    );
    var record = NoticeRecord.inspected(&inspection, policy);
    var presentation = NoticePresentation.fromRecord(record).?;
    try std.testing.expectEqual(NoticePhase.incomplete_size, presentation.phase);
    try std.testing.expectEqual(NoticeState.notice, presentation.state);
    const incomplete = try presentation.label(allocator);
    defer allocator.free(incomplete);
    try std.testing.expectEqualStrings("Size incomplete: 1 worktree - 1 reclaimable (last inspected)", incomplete);

    inspection.entries.items[0].setSize(.{ .bytes = 1024 });
    record = NoticeRecord.inspected(&inspection, policy);
    const observed = try NoticePresentation.fromRecord(record).?.label(allocator);
    defer allocator.free(observed);
    try std.testing.expectEqualStrings("Last inspected: 1 worktree - 1 reclaimable", observed);
    record.stale = .bindings_changed;
    presentation = NoticePresentation.fromRecord(record).?;
    try std.testing.expectEqual(NoticePhase.stale, presentation.phase);
    try std.testing.expectEqual(NoticeState.indeterminate, presentation.state);
    record.policy = policyReadOutcome(error.AccessDenied);
    presentation = NoticePresentation.fromRecord(record).?;
    try std.testing.expectEqual(NoticePhase.unknown_policy, presentation.phase);
    try std.testing.expectEqual(NoticeState.indeterminate, presentation.state);
    const unavailable = try presentation.label(allocator);
    defer allocator.free(unavailable);
    try std.testing.expectEqualStrings("Policy unavailable: 1 worktree - 1 reclaimable (last inspected) (AccessDenied)", unavailable);

    record.refresh_error = error.GitFailed;
    presentation = NoticePresentation.fromRecord(record).?;
    try std.testing.expectEqual(NoticePhase.failed, presentation.phase);
    try std.testing.expectEqual(@as(usize, 1), presentation.summary.?.total);
    const failed = try presentation.label(allocator);
    defer allocator.free(failed);
    try std.testing.expectEqualStrings("Inspection failed: 1 worktree - 1 reclaimable (last inspected) (GitFailed)", failed);

    const first_failure = NoticePresentation.fromRecord(.{ .refresh_error = error.GitFailed }).?;
    try std.testing.expect(first_failure.summary == null);
    const failed_empty = try first_failure.label(allocator);
    defer allocator.free(failed_empty);
    try std.testing.expectEqualStrings("Inspection failed (GitFailed)", failed_empty);
    inspection.entries.clearRetainingCapacity();
    try std.testing.expect(NoticePresentation.fromRecord(NoticeRecord.inspected(&inspection, policy)) == null);
}

test "worktree notice presentation owns values and labels unknown stale and failed observations" {
    try expectNoticePresentation(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, expectNoticePresentation, .{});
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
