const std = @import("std");

pub const Channel = enum { stable, beta };
pub const State = enum { disabled, available, up_to_date, failed };

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
        const channel: Channel = if (beta_enabled) .beta else .stable;
        const uri = try std.Uri.parse(self.feed_url);
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();
        var request = try client.open(.GET, uri, .{ .server_header_buffer = &[_]u8{0} ** 4096 });
        defer request.deinit();
        try request.send();
        try request.finish();
        const body = try request.reader().readAllAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(body);
        return parseFeed(self.allocator, body, channel, current_version);
    }
};

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
