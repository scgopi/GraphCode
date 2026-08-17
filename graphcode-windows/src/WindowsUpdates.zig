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
    for (parsed.value) |release| {
        if (release.draft or release.prerelease != (channel == .beta)) continue;
        const version = release.tag_name;
        return .{
            .channel = channel,
            .state = if (std.mem.eql(u8, version, current_version)) .up_to_date else .available,
            .version = try allocator.dupe(u8, version),
        };
    }
    return .{ .channel = channel, .state = .failed, .message = try allocator.dupe(u8, "No release found for selected channel") };
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
