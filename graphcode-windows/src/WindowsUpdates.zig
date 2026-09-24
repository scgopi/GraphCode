const std = @import("std");
const c = @import("Win32.zig").c;

pub const Channel = enum { stable, beta };
pub const State = enum { disabled, available, up_to_date, failed };
pub const releases_page_url = "https://github.com/scgopi/GraphCode/releases";

/// The exact, versionless asset name `Tools/windows/release.ps1` publishes.
/// Matching on this name (rather than a per-version filename) is what lets a
/// release be found even though nothing else about the asset shape changes
/// between versions.
pub const windows_asset_name = "graphcode-windows-x86_64.zip";
const windows_checksum_suffix = ".sha256";

pub fn releasePageUrl(value: []const u8) ![]const u8 {
    if (value.len == 0) return releases_page_url;
    for (value) |byte| if (byte <= 0x20 or byte == 0x7f) return error.InvalidReleaseUrl;
    if (std.mem.eql(u8, value, releases_page_url)) return value;
    const tag_prefix = releases_page_url ++ "/tag/";
    if (!std.mem.startsWith(u8, value, tag_prefix)) return error.InvalidReleaseUrl;
    const tag = value[tag_prefix.len..];
    if (tag.len == 0 or std.mem.eql(u8, tag, ".") or std.mem.eql(u8, tag, ".."))
        return error.InvalidReleaseUrl;
    for (tag) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-' and byte != '_' and byte != '+')
            return error.InvalidReleaseUrl;
    }
    return value;
}

pub fn acceptsResult(current_generation: u64, result_generation: u64, cancelled: bool) bool {
    return !cancelled and current_generation == result_generation;
}

pub const CheckResult = struct {
    channel: Channel,
    state: State,
    version: ?[]u8 = null,
    release_url: ?[]u8 = null,
    message: ?[]u8 = null,
    /// The direct download URL for `windows_asset_name` on the offered
    /// release. Only populated when `state == .available`.
    asset_url: ?[]u8 = null,
    /// Lowercase hex SHA-256 of the asset, read straight from GitHub's own
    /// `digest` field on the asset. Populated only when GitHub reported one;
    /// callers must fall back to `asset_checksum_url` otherwise.
    asset_sha256: ?[]u8 = null,
    /// Download URL for the `<asset>.sha256` sidecar `release.ps1` publishes,
    /// used only when the release asset itself carries no `digest`.
    asset_checksum_url: ?[]u8 = null,

    pub fn deinit(self: *CheckResult, allocator: std.mem.Allocator) void {
        if (self.version) |value| allocator.free(value);
        if (self.release_url) |value| allocator.free(value);
        if (self.message) |value| allocator.free(value);
        if (self.asset_url) |value| allocator.free(value);
        if (self.asset_sha256) |value| allocator.free(value);
        if (self.asset_checksum_url) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const CheckState = struct {
    channel: Channel = .stable,
    state: State = .disabled,

    pub fn configure(beta_enabled: bool) CheckState {
        return .{ .channel = if (beta_enabled) .beta else .stable, .state = .up_to_date };
    }

    pub fn shouldPresentOffer(self: CheckState, user_initiated: bool) bool {
        return user_initiated and self.state == .available;
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
    feed_url: []const u8 = "https://api.github.com/repos/scgopi/GraphCode/releases?per_page=30",

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
    var parsed = try std.json.parseFromSlice([]const Release, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var installed = try SemVer.parse(allocator, current_version);
    defer installed.deinit(allocator);
    var greatest: ?struct { release: Release, version: SemVer } = null;
    defer if (greatest) |selected| selected.version.deinit(allocator);
    for (parsed.value) |release| {
        if (release.draft or (channel == .stable and release.prerelease)) continue;
        const candidate = SemVer.parse(allocator, release.tag_name) catch |err| switch (err) {
            error.InvalidVersion => continue,
            else => return err,
        };
        if (greatest == null or candidate.compare(greatest.?.version) == .greater) {
            if (greatest) |old| old.version.deinit(allocator);
            greatest = .{ .release = release, .version = candidate };
        } else {
            candidate.deinit(allocator);
        }
    }
    if (greatest) |selected| {
        const state: State = if (selected.version.compare(installed) == .greater) .available else .up_to_date;
        var result = CheckResult{ .channel = channel, .state = state, .version = try allocator.dupe(u8, selected.release.tag_name) };
        errdefer result.deinit(allocator);
        if (selected.release.html_url) |url| result.release_url = try allocator.dupe(u8, try releasePageUrl(url));
        if (state == .available) {
            // `asset_url` staying null here (release has no matching Windows
            // asset — e.g. the 2026-09-17 macOS-only publish) is itself a
            // meaningful, honest result: callers must present that as "no
            // Windows build attached to this release" rather than assuming
            // an asset exists and letting a download 404.
            if (try findWindowsAsset(allocator, selected.release.assets)) |found| {
                result.asset_url = found.url;
                result.asset_sha256 = found.sha256;
                result.asset_checksum_url = found.checksum_url;
            }
        }
        return result;
    }
    return .{ .channel = channel, .state = .failed, .message = try allocator.dupe(u8, "No release found for selected channel") };
}

const FoundAsset = struct {
    url: []u8,
    sha256: ?[]u8,
    checksum_url: ?[]u8,
};

/// Finds the Windows release asset among a release's reported assets. GitHub
/// reports a `sha256:<hex>` `digest` on most assets; when it is absent (older
/// uploads predate the field) this falls back to recording the `.sha256`
/// sidecar's own download URL so a caller can fetch and parse it instead.
fn findWindowsAsset(allocator: std.mem.Allocator, assets: []const Asset) !?FoundAsset {
    var url: ?[]const u8 = null;
    var digest: ?[]const u8 = null;
    var checksum_url: ?[]const u8 = null;
    for (assets) |asset| {
        if (std.mem.eql(u8, asset.name, windows_asset_name)) {
            url = asset.browser_download_url;
            digest = asset.digest;
        } else if (std.mem.eql(u8, asset.name, windows_asset_name ++ windows_checksum_suffix)) {
            checksum_url = asset.browser_download_url;
        }
    }
    const found_url = url orelse return null;
    var result = FoundAsset{ .url = try allocator.dupe(u8, found_url), .sha256 = null, .checksum_url = null };
    errdefer allocator.free(result.url);
    if (digest) |value| {
        const prefix = "sha256:";
        if (std.mem.startsWith(u8, value, prefix)) {
            const hex = value[prefix.len..];
            if (hex.len == 64 and isHex(hex)) {
                result.sha256 = try allocator.dupe(u8, hex);
                return result;
            }
        }
    }
    if (checksum_url) |value| {
        result.checksum_url = allocator.dupe(u8, value) catch |err| {
            return err;
        };
    }
    return result;
}

fn isHex(value: []const u8) bool {
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
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
                if (compareBetaIdentifiers(l, r)) |order| {
                    if (order != .equal) return order;
                    continue;
                }
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

fn compareBetaIdentifiers(left: []const u8, right: []const u8) ?SemVer.Order {
    const left_suffix = betaSuffix(left) orelse return null;
    const right_suffix = betaSuffix(right) orelse return null;
    if (left_suffix != right_suffix) return if (left_suffix < right_suffix) .less else .greater;
    return .equal;
}

fn betaSuffix(value: []const u8) ?u64 {
    if (value.len <= 4 or !std.ascii.eqlIgnoreCase(value[0..4], "beta")) return null;
    const suffix = value[4..];
    if (!isNumeric(suffix)) return null;
    return std.fmt.parseInt(u64, suffix, 10) catch null;
}

fn parseNumber(value: []const u8) !u64 {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return error.InvalidVersion;
    return std.fmt.parseInt(u64, value, 10) catch error.InvalidVersion;
}

const Release = struct {
    tag_name: []const u8,
    html_url: ?[]const u8 = null,
    prerelease: bool = false,
    draft: bool = false,
    assets: []const Asset = &.{},
};

const Asset = struct {
    name: []const u8,
    browser_download_url: ?[]const u8 = null,
    digest: ?[]const u8 = null,
};

test "default update feed uses the GraphCode release repository" {
    const client = CheckClient{ .allocator = std.testing.allocator };
    try std.testing.expectEqualStrings("https://api.github.com/repos/scgopi/GraphCode/releases?per_page=30", client.feed_url);
}

test "background update checks do not interrupt the workspace with a modal offer" {
    const available = CheckState{ .state = .available };
    try std.testing.expect(!available.shouldPresentOffer(false));
    try std.testing.expect(available.shouldPresentOffer(true));
    for ([_]State{ .disabled, .up_to_date, .failed }) |state| {
        const check = CheckState{ .state = state };
        try std.testing.expect(!check.shouldPresentOffer(true));
        try std.testing.expect(!check.shouldPresentOffer(false));
    }
}

test "GitHub release response accepts additive metadata without losing channel filtering" {
    const releases =
        \\[
        \\  {"id":100,"tag_name":"v2.0.0","html_url":"https://github.com/scgopi/GraphCode/releases/tag/v2.0.0",
        \\   "prerelease":false,"draft":false,"name":"GraphCode 2.0.0","body":"Release notes",
        \\   "author":{"login":"fixture","id":1},"published_at":"2026-09-17T00:00:00Z",
        \\   "assets":[{"name":"graphcode-macos-arm64.dmg","size":123,"digest":"sha256:fixture"}]},
        \\  {"id":101,"tag_name":"v3.0.0-beta1","prerelease":true,"draft":false,"assets":[]},
        \\  {"id":102,"tag_name":"v9.0.0","prerelease":false,"draft":true,"immutable":false}
        \\]
    ;
    var result = try parseFeed(std.testing.allocator, releases, .stable, "1.0.0");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.available, result.state);
    try std.testing.expectEqualStrings("v2.0.0", result.version.?);
    try std.testing.expectEqualStrings("https://github.com/scgopi/GraphCode/releases/tag/v2.0.0", result.release_url.?);
}

test "known update feed fields remain type checked" {
    try std.testing.expectError(error.UnexpectedToken, parseFeed(std.testing.allocator,
        \\[{"tag_name":"v2.0.0","prerelease":"false"}]
    , .stable, "1.0.0"));
}

test "update feed allocation failures propagate without leaking selected releases" {
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const releases =
                \\[{"tag_name":"v1.1.0"},{"tag_name":"not-a-version"},{"tag_name":"v2.0.0","html_url":"https://github.com/scgopi/GraphCode/releases/tag/v2.0.0"}]
            ;
            var result = try parseFeed(allocator, releases, .stable, "1.0.0");
            defer result.deinit(allocator);
            try std.testing.expectEqualStrings("v2.0.0", result.version.?);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

test "real update feed result follows stable and beta channels" {
    const stable =
        \\[{"tag_name":"v2.0.0","html_url":"https://github.com/scgopi/GraphCode/releases/tag/v2.0.0","prerelease":false,"draft":false},{"tag_name":"v3.0.0-beta","prerelease":true,"draft":false}]
    ;
    var stable_result = try parseFeed(std.testing.allocator, stable, .stable, "v1.0.0");
    defer stable_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.available, stable_result.state);
    try std.testing.expectEqual(Channel.stable, stable_result.channel);
    try std.testing.expectEqualStrings("https://github.com/scgopi/GraphCode/releases/tag/v2.0.0", stable_result.release_url.?);
    var beta_result = try parseFeed(std.testing.allocator, stable, .beta, "v3.0.0-beta");
    defer beta_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.up_to_date, beta_result.state);
    try std.testing.expectEqualStrings("v3.0.0-beta", beta_result.version.?);
}

test "release page handoff stays within the GraphCode release repository" {
    try std.testing.expectEqualStrings(releases_page_url, try releasePageUrl(""));
    try std.testing.expectEqualStrings(releases_page_url, try releasePageUrl(releases_page_url));
    const tag = releases_page_url ++ "/tag/v2.0.0-beta1";
    try std.testing.expectEqualStrings(tag, try releasePageUrl(tag));
    const build_tag = releases_page_url ++ "/tag/v2.0.0+build.1";
    try std.testing.expectEqualStrings(build_tag, try releasePageUrl(build_tag));
    for ([_][]const u8{
        "file:///C:/untrusted.exe",
        "http://github.com/scgopi/GraphCode/releases/tag/v2",
        "https://github.com/GraphCode/GraphCode/releases",
        "https://github.com.evil.test/scgopi/GraphCode/releases/tag/v2",
        releases_page_url ++ "/tag/",
        releases_page_url ++ "/tag/v2\r\n",
        releases_page_url ++ "/tag/../../../../other/project",
        releases_page_url ++ "/tag/%2e%2e",
        releases_page_url ++ "/tag/..\\..\\other",
        releases_page_url ++ "/tag/.",
        releases_page_url ++ "/tag/..",
        releases_page_url ++ "/tag/v2?other",
        releases_page_url ++ "/tag/v2#other",
    }) |invalid| try std.testing.expectError(error.InvalidReleaseUrl, releasePageUrl(invalid));
    try std.testing.expectError(error.InvalidReleaseUrl, parseFeed(std.testing.allocator,
        \\[{"tag_name":"v2.0.0","html_url":"file:///C:/untrusted.exe"}]
    , .stable, "1.0.0"));
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

test "GraphCode beta identifiers compare by numeric suffix" {
    const releases =
        \\[{"tag_name":"v1.0.0-beta9","prerelease":true,"draft":false},{"tag_name":"v1.0.0-beta1","prerelease":true,"draft":false},{"tag_name":"v1.0.0","prerelease":false,"draft":false},{"tag_name":"v1.0.0-beta10","prerelease":true,"draft":false}]
    ;
    var result = try parseFeed(std.testing.allocator, releases, .beta, "v1.0.0-beta9");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.available, result.state);
    try std.testing.expectEqualStrings("v1.0.0", result.version.?);

    const prereleases =
        \\[{"tag_name":"v1.0.0-beta9","prerelease":true,"draft":false},{"tag_name":"v1.0.0-beta1","prerelease":true,"draft":false},{"tag_name":"v1.0.0-beta10","prerelease":true,"draft":false}]
    ;
    var numeric = try parseFeed(std.testing.allocator, prereleases, .beta, "v1.0.0-beta9");
    defer numeric.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.available, numeric.state);
    try std.testing.expectEqualStrings("v1.0.0-beta10", numeric.version.?);
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

test "an available release records its Windows asset URL and GitHub-reported digest" {
    const releases =
        \\[{"tag_name":"v2.0.0","prerelease":false,"draft":false,"assets":[
        \\  {"name":"graphcode-macos-arm64.dmg","browser_download_url":"https://github.com/scgopi/GraphCode/releases/download/v2.0.0/graphcode-macos-arm64.dmg"},
        \\  {"name":"graphcode-windows-x86_64.zip","browser_download_url":"https://github.com/scgopi/GraphCode/releases/download/v2.0.0/graphcode-windows-x86_64.zip","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
        \\]}]
    ;
    var result = try parseFeed(std.testing.allocator, releases, .stable, "1.0.0");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.available, result.state);
    try std.testing.expectEqualStrings(
        "https://github.com/scgopi/GraphCode/releases/download/v2.0.0/graphcode-windows-x86_64.zip",
        result.asset_url.?,
    );
    try std.testing.expectEqualStrings(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        result.asset_sha256.?,
    );
    try std.testing.expectEqual(@as(?[]u8, null), result.asset_checksum_url);
}

test "a missing digest falls back to the published sha256 sidecar's own URL" {
    const releases =
        \\[{"tag_name":"v2.0.0","prerelease":false,"draft":false,"assets":[
        \\  {"name":"graphcode-windows-x86_64.zip","browser_download_url":"https://github.com/scgopi/GraphCode/releases/download/v2.0.0/graphcode-windows-x86_64.zip"},
        \\  {"name":"graphcode-windows-x86_64.zip.sha256","browser_download_url":"https://github.com/scgopi/GraphCode/releases/download/v2.0.0/graphcode-windows-x86_64.zip.sha256"}
        \\]}]
    ;
    var result = try parseFeed(std.testing.allocator, releases, .stable, "1.0.0");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.available, result.state);
    try std.testing.expect(result.asset_url != null);
    try std.testing.expectEqual(@as(?[]u8, null), result.asset_sha256);
    try std.testing.expectEqualStrings(
        "https://github.com/scgopi/GraphCode/releases/download/v2.0.0/graphcode-windows-x86_64.zip.sha256",
        result.asset_checksum_url.?,
    );
}

test "an available release with no Windows asset reports no asset rather than a guessed URL" {
    // This is the honest, real state the 2026-09-17 asset check actually found:
    // a release whose only published binaries are macOS DMGs. Present it as
    // 'no asset' plainly rather than assuming a Windows asset exists.
    const releases =
        \\[{"tag_name":"v2.0.0","prerelease":false,"draft":false,"assets":[
        \\  {"name":"graphcode-macos-arm64.dmg","browser_download_url":"https://github.com/scgopi/GraphCode/releases/download/v2.0.0/graphcode-macos-arm64.dmg"}
        \\]}]
    ;
    var result = try parseFeed(std.testing.allocator, releases, .stable, "1.0.0");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.available, result.state);
    try std.testing.expectEqual(@as(?[]u8, null), result.asset_url);
    try std.testing.expectEqual(@as(?[]u8, null), result.asset_sha256);
    try std.testing.expectEqual(@as(?[]u8, null), result.asset_checksum_url);
}

test "a release with no assets array at all still resolves without an asset" {
    var result = try parseFeed(std.testing.allocator, "[{\"tag_name\":\"v2.0.0\"}]", .stable, "1.0.0");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.available, result.state);
    try std.testing.expectEqual(@as(?[]u8, null), result.asset_url);
}

test "an up-to-date release never looks at assets" {
    // Confirms the asset lookup is gated on `state == .available`: an
    // already-installed version must never carry an asset_url even if the
    // release JSON has one, since there is nothing to offer installing.
    const releases =
        \\[{"tag_name":"v1.0.0","prerelease":false,"draft":false,"assets":[
        \\  {"name":"graphcode-windows-x86_64.zip","browser_download_url":"https://example.invalid/graphcode-windows-x86_64.zip","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
        \\]}]
    ;
    var result = try parseFeed(std.testing.allocator, releases, .stable, "v1.0.0");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(State.up_to_date, result.state);
    try std.testing.expectEqual(@as(?[]u8, null), result.asset_url);
}

test "a malformed digest is ignored in favor of the checksum sidecar fallback" {
    const releases =
        \\[{"tag_name":"v2.0.0","prerelease":false,"draft":false,"assets":[
        \\  {"name":"graphcode-windows-x86_64.zip","browser_download_url":"https://github.com/scgopi/GraphCode/releases/download/v2.0.0/graphcode-windows-x86_64.zip","digest":"sha256:not-hex"},
        \\  {"name":"graphcode-windows-x86_64.zip.sha256","browser_download_url":"https://github.com/scgopi/GraphCode/releases/download/v2.0.0/graphcode-windows-x86_64.zip.sha256"}
        \\]}]
    ;
    var result = try parseFeed(std.testing.allocator, releases, .stable, "1.0.0");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?[]u8, null), result.asset_sha256);
    try std.testing.expectEqualStrings(
        "https://github.com/scgopi/GraphCode/releases/download/v2.0.0/graphcode-windows-x86_64.zip.sha256",
        result.asset_checksum_url.?,
    );
}

test "asset resolution allocation failures propagate without leaking the found asset" {
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const releases =
                \\[{"tag_name":"v2.0.0","prerelease":false,"draft":false,"assets":[
                \\  {"name":"graphcode-windows-x86_64.zip","browser_download_url":"https://github.com/scgopi/GraphCode/releases/download/v2.0.0/graphcode-windows-x86_64.zip","digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}
                \\]}]
            ;
            var result = try parseFeed(allocator, releases, .stable, "1.0.0");
            defer result.deinit(allocator);
            try std.testing.expect(result.asset_url != null);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
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
