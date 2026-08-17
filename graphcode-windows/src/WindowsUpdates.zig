const std = @import("std");
const c = @import("Win32.zig").c;

pub const Channel = enum { stable, beta };
pub const State = enum { disabled, available, up_to_date, failed };

pub fn acceptsResult(current_generation: u64, result_generation: u64, cancelled: bool) bool {
    return !cancelled and current_generation == result_generation;
}

pub const CheckResult = struct {
    channel: Channel,
    state: State,
    version: ?[]u8 = null,
    message: ?[]u8 = null,

    pub fn deinit(self: *CheckResult, allocator: std.mem.Allocator) void {
        if (self.version) |value| allocator.free(value);
        if (self.message) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const CheckState = struct {
    channel: Channel = .stable,
    state: State = .disabled,

    pub fn configure(beta_enabled: bool) CheckState {
        return .{ .channel = if (beta_enabled) .beta else .stable, .state = .up_to_date };
    }

    pub fn label(self: CheckState) []const u8 {
        return switch (self.state) {
            .disabled => "Updates disabled",
            .available => if (self.channel == .beta) "Beta update available" else "Stable update available",
            .up_to_date => if (self.channel == .beta) "Beta updates up to date" else "Stable updates up to date",
            .failed => "Update check failed",
        };
    }
};

pub const CheckClient = struct {
    allocator: std.mem.Allocator,
    feed_url: []const u8 = "https://api.github.com/repos/GraphCode/GraphCode/releases",

    pub fn check(self: CheckClient, beta_enabled: bool, current_version: []const u8) !CheckResult {
        var cancelled = std.atomic.Value(bool).init(false);
        return self.checkWithCancel(beta_enabled, current_version, &cancelled);
    }

    pub fn checkWithCancel(
        self: CheckClient,
        beta_enabled: bool,
        current_version: []const u8,
        cancelled: *std.atomic.Value(bool),
    ) !CheckResult {
        const channel: Channel = if (beta_enabled) .beta else .stable;
        const body = try fetchWinHttp(self.allocator, self.feed_url, cancelled);
        defer self.allocator.free(body);
        return parseFeed(self.allocator, body, channel, current_version);
    }
};

fn fetchWinHttp(allocator: std.mem.Allocator, feed_url: []const u8, cancelled: *std.atomic.Value(bool)) ![]u8 {
    if (cancelled.load(.acquire)) return error.Cancelled;
    const uri = try std.Uri.parse(feed_url);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const host_component = uri.host orelse return error.InvalidUpdateFeed;
    const host = try host_component.toRawMaybeAlloc(scratch);
    const path_component = try uri.path.toRawMaybeAlloc(scratch);
    const query = if (uri.query) |value| try value.toRawMaybeAlloc(scratch) else null;
    const path = if (query) |value| try std.fmt.allocPrint(scratch, "{s}?{s}", .{ path_component, value }) else path_component;
    const host16 = try utf16Z(scratch, host);
    const path16 = try utf16Z(scratch, path);
    const agent16 = try utf16Z(scratch, "GraphCode-Windows-Updater");
    const accept_header16 = try utf16Z(scratch, "Accept: application/vnd.github+json");
    const user_agent_header16 = try utf16Z(scratch, "User-Agent: GraphCode-Windows-Updater");
    const session = c.WinHttpOpen(agent16.ptr, c.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse return error.UpdateConnectFailed;
    defer _ = c.WinHttpCloseHandle(session);
    if (c.WinHttpSetTimeouts(session, 2000, 2000, 2000, 2000) == 0) return error.UpdateConnectFailed;
    const port: c.INTERNET_PORT = uri.port orelse if (std.mem.eql(u8, uri.scheme, "https")) 443 else 80;
    const connection = c.WinHttpConnect(session, host16.ptr, port, 0) orelse return error.UpdateConnectFailed;
    defer _ = c.WinHttpCloseHandle(connection);
    const flags: c.DWORD = if (std.mem.eql(u8, uri.scheme, "https")) c.WINHTTP_FLAG_SECURE else 0;
    const verb: [*:0]const u16 = &[_:0]u16{ 'G', 'E', 'T' };
    var accepts = [_]?[*:0]const u16{null};
    const request = c.WinHttpOpenRequest(connection, verb, path16.ptr, null, null, @ptrCast(&accepts), flags) orelse return error.UpdateConnectFailed;
    defer _ = c.WinHttpCloseHandle(request);
    if (c.WinHttpAddRequestHeaders(request, accept_header16.ptr, @intCast(accept_header16.len), c.WINHTTP_ADDREQ_FLAG_ADD) == 0 or
        c.WinHttpAddRequestHeaders(request, user_agent_header16.ptr, @intCast(user_agent_header16.len), c.WINHTTP_ADDREQ_FLAG_ADD) == 0)
        return error.UpdateSendFailed;
    if (cancelled.load(.acquire)) return error.Cancelled;
    if (c.WinHttpSendRequest(request, @as([*c]const u16, null), 0, null, 0, 0, 0) == 0) return error.UpdateSendFailed;
    if (cancelled.load(.acquire)) return error.Cancelled;
    if (c.WinHttpReceiveResponse(request, null) == 0) return error.UpdateReceiveFailed;
    var status: c.DWORD = 0;
    var status_len: c.DWORD = @sizeOf(c.DWORD);
    if (c.WinHttpQueryHeaders(request, c.WINHTTP_QUERY_STATUS_CODE | c.WINHTTP_QUERY_FLAG_NUMBER, null, &status, &status_len, null) == 0 or status != 200)
        return error.UpdateFeedUnavailable;
    var body = std.array_list.Managed(u8).init(allocator);
    defer body.deinit();
    while (true) {
        if (cancelled.load(.acquire)) return error.Cancelled;
        var available: c.DWORD = 0;
        if (c.WinHttpQueryDataAvailable(request, &available) == 0) return error.UpdateReceiveFailed;
        if (available == 0) break;
        if (body.items.len + available > 1024 * 1024) return error.UpdateFeedTooLarge;
        const old_len = body.items.len;
        try body.resize(old_len + available);
        var read: c.DWORD = 0;
        if (c.WinHttpReadData(request, body.items[old_len..].ptr, available, &read) == 0) return error.UpdateReceiveFailed;
        body.items.len = old_len + read;
    }

    return body.toOwnedSlice();
}

fn utf16Z(allocator: std.mem.Allocator, value: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, value);
}

pub fn currentVersion(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "GRAPHCODE_VERSION")) |value| {
        if (value.len != 0) return value;
        allocator.free(value);
    } else |_| {}
    return currentVersionFromMetadata(allocator, null);
}

pub fn currentVersionFromMetadata(allocator: std.mem.Allocator, metadata: ?[]const u8) ![]u8 {
    if (metadata) |value| if (value.len != 0) return allocator.dupe(u8, value);
    return allocator.dupe(u8, "dev");
}

fn parseFeed(allocator: std.mem.Allocator, body: []const u8, channel: Channel, current_version: []const u8) !CheckResult {
    var parsed = try std.json.parseFromSlice([]const Release, allocator, body, .{});
    defer parsed.deinit();
    var installed = try SemVer.parse(allocator, current_version);
    defer installed.deinit(allocator);
    var greatest: ?struct { release: Release, version: SemVer } = null;
    for (parsed.value) |release| {
        if (release.draft or (channel == .stable and release.prerelease)) continue;
        const candidate = SemVer.parse(allocator, release.tag_name) catch continue;
        if (greatest == null or candidate.compare(greatest.?.version) == .greater) {
            if (greatest) |old| old.version.deinit(allocator);
            greatest = .{ .release = release, .version = candidate };
        } else {
            candidate.deinit(allocator);
        }
    }
    if (greatest) |selected| {
        defer selected.version.deinit(allocator);
        return .{
            .channel = channel,
            .state = if (selected.version.compare(installed) == .greater) .available else .up_to_date,
            .version = try allocator.dupe(u8, selected.release.tag_name),
        };
    }
    return .{ .channel = channel, .state = .failed, .message = try allocator.dupe(u8, "No release found for selected channel") };
}

const SemVer = struct {
    core: []u64,
    prerelease: ?[]const u8 = null,

    const Order = enum { less, equal, greater };

    fn parse(allocator: std.mem.Allocator, input: []const u8) !SemVer {
        var value = input;
        if (value.len > 0 and (value[0] == 'v' or value[0] == 'V')) value = value[1..];
        const build_start = std.mem.indexOfScalar(u8, value, '+') orelse value.len;
        value = value[0..build_start];
        const pre_start = std.mem.indexOfScalar(u8, value, '-') orelse value.len;
        const core = value[0..pre_start];
        var core_values = std.array_list.Managed(u64).init(allocator);
        defer core_values.deinit();
        var numbers = std.mem.splitScalar(u8, core, '.');
        while (numbers.next()) |number| try core_values.append(try parseNumber(number));
        if (core_values.items.len == 0) return error.InvalidVersion;
        const prerelease = if (pre_start < value.len) value[pre_start + 1 ..] else null;
        if (prerelease) |identifiers| {
            if (identifiers.len == 0) return error.InvalidVersion;
            var parts = std.mem.splitScalar(u8, identifiers, '.');
            while (parts.next()) |part| {
                if (part.len == 0) return error.InvalidVersion;
                if (isNumeric(part) and part.len > 1 and part[0] == '0') return error.InvalidVersion;
            }
        }
        return .{ .core = try core_values.toOwnedSlice(), .prerelease = prerelease };
    }

    fn deinit(self: *const SemVer, allocator: std.mem.Allocator) void {
        allocator.free(self.core);
    }

    fn compare(self: SemVer, other: SemVer) Order {
        const core_len = @max(self.core.len, other.core.len);
        for (0..core_len) |index| {
            const left = if (index < self.core.len) self.core[index] else 0;
            const right = if (index < other.core.len) other.core[index] else 0;
            if (left != right) return if (left < right) .less else .greater;
        }
        if (self.prerelease == null and other.prerelease == null) return .equal;
        if (self.prerelease == null) return .greater;
        if (other.prerelease == null) return .less;
        var left = std.mem.splitScalar(u8, self.prerelease.?, '.');
        var right = std.mem.splitScalar(u8, other.prerelease.?, '.');
        while (true) {
            const left_part = left.next();
            const right_part = right.next();
            if (left_part == null and right_part == null) return .equal;
            if (left_part == null) return .less;
            if (right_part == null) return .greater;
            const l = left_part.?;
            const r = right_part.?;
            if (isNumeric(l) and isNumeric(r)) {
                const ln = std.fmt.parseInt(u64, l, 10) catch return .less;
                const rn = std.fmt.parseInt(u64, r, 10) catch return .greater;
                if (ln != rn) return if (ln < rn) .less else .greater;
            } else if (isNumeric(l) != isNumeric(r)) {
                return if (isNumeric(l)) .less else .greater;
            } else if (!std.mem.eql(u8, l, r)) {
                return if (std.mem.lessThan(u8, l, r)) .less else .greater;
            }
        }
    }
};

fn isNumeric(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (byte < '0' or byte > '9') return false;
    return true;
}

fn parseNumber(value: []const u8) !u64 {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return error.InvalidVersion;
    return std.fmt.parseInt(u64, value, 10) catch error.InvalidVersion;
}

const Release = struct {
    tag_name: []const u8,
    prerelease: bool = false,
    draft: bool = false,
};

test "real update feed result follows stable and beta channels" {
    const stable =
        \\[{"tag_name":"v2.0.0","prerelease":false,"draft":false},{"tag_name":"v3.0.0-beta","prerelease":true,"draft":false}]
    ;
    var stable_result = try parseFeed(std.testing.allocator, stable, .stable, "v1.0.0");
    defer stable_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.available, stable_result.state);
    try std.testing.expectEqual(Channel.stable, stable_result.channel);
    var beta_result = try parseFeed(std.testing.allocator, stable, .beta, "v3.0.0-beta");
    defer beta_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.up_to_date, beta_result.state);
    try std.testing.expectEqualStrings("v3.0.0-beta", beta_result.version.?);
}

test "release tags and installed versions compare semantically" {
    const releases =
        \\[{"tag_name":"V1.2.3","prerelease":false,"draft":false}]
    ;
    var result = try parseFeed(std.testing.allocator, releases, .stable, "v1.2.3");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.up_to_date, result.state);
    try std.testing.expectEqualStrings("V1.2.3", result.version.?);

    const prereleases =
        \\[{"tag_name":"v2.0.0-beta.2","prerelease":true,"draft":false}]
    ;
    var beta = try parseFeed(std.testing.allocator, prereleases, .beta, "2.0.0-beta.1");
    defer beta.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.available, beta.state);
}

test "stable channel ignores prerelease tags" {
    const releases =
        \\[{"tag_name":"v3.0.0-beta.1","prerelease":true,"draft":false},{"tag_name":"v2.9.0","prerelease":false,"draft":false}]
    ;
    var result = try parseFeed(std.testing.allocator, releases, .stable, "v2.9.0");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.up_to_date, result.state);
    try std.testing.expectEqualStrings("v2.9.0", result.version.?);
}

test "feed selection uses greatest stable version regardless of order" {
    const releases =
        \\[{"tag_name":"v1.9.0","prerelease":false,"draft":false},{"tag_name":"v1.10.0","prerelease":false,"draft":false},{"tag_name":"v1.2.0","prerelease":false,"draft":false}]
    ;
    var result = try parseFeed(std.testing.allocator, releases, .stable, "v1.8.0");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.available, result.state);
    try std.testing.expectEqualStrings("v1.10.0", result.version.?);

    var no_update = try parseFeed(std.testing.allocator, releases, .stable, "2.0.0");
    defer no_update.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.up_to_date, no_update.state);
}

test "beta selection prefers a final stable release over a beta" {
    const releases =
        \\[{"tag_name":"v2.0.0-beta.2","prerelease":true,"draft":false},{"tag_name":"v1.9.0","prerelease":false,"draft":false},{"tag_name":"v2.0.0","prerelease":false,"draft":false}]
    ;
    var result = try parseFeed(std.testing.allocator, releases, .beta, "v2.0.0-beta.1");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.available, result.state);
    try std.testing.expectEqualStrings("v2.0.0", result.version.?);
}

test "variable length GraphCode version tuples normalize trailing zeroes" {
    const releases =
        \\[{"tag_name":"v0.1.26.1","prerelease":false,"draft":false}]
    ;
    var result = try parseFeed(std.testing.allocator, releases, .stable, "v0.1.26");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.available, result.state);

    var equal = try parseFeed(std.testing.allocator, releases, .stable, "0.1.26.1");
    defer equal.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.up_to_date, equal.state);
}

test "update feed errors are explicit" {
    var result = parseFeed(std.testing.allocator, "[]", .stable, "v1") catch unreachable;
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.failed, result.state);
    try std.testing.expect(result.message != null);
}

test "current version comes from package metadata override" {
    const version = try currentVersionFromMetadata(std.testing.allocator, "v7.2.1");
    defer std.testing.allocator.free(version);
    try std.testing.expectEqualStrings("v7.2.1", version);
}

test "WinHTTP UTF-16 arguments are sentinel terminated" {
    const value = try utf16Z(std.testing.allocator, "fixture/path/☃");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqual(@as(u16, 0), value[value.len]);
    const round_trip = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, value[0..value.len]);
    defer std.testing.allocator.free(round_trip);
    try std.testing.expectEqualStrings("fixture/path/☃", round_trip);
}

test "stale update results cannot overwrite a newer channel request" {
    try std.testing.expect(!acceptsResult(2, 1, false));
    try std.testing.expect(!acceptsResult(2, 2, true));
    try std.testing.expect(acceptsResult(2, 2, false));
}

test "cancelled update request exits before contacting a stalled server" {
    var cancelled = std.atomic.Value(bool).init(true);
    const client = CheckClient{ .allocator = std.testing.allocator, .feed_url = "https://127.0.0.1:9/releases" };
    try std.testing.expectError(error.Cancelled, client.checkWithCancel(false, "v1", &cancelled));
}
