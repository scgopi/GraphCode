const std = @import("std");
const c = @import("Win32.zig").c;

/// Downloads the Windows release asset, verifies it, and hands off to the
/// package's own bundled setup script to do the actual install/rollback.
///
/// This module deliberately does **not** re-verify package contents (manifest
/// hashes, provider provenance) or re-implement rollback: `GraphCode-Setup.ps1`
/// embeds `Tools/windows/PackageRuntime.ps1` verbatim, and that already does
/// atomic stage/swap/rollback, covered by `Packaging.Rollback.Tests.ps1`. The
/// checksum verified here is transport integrity only (did the download
/// arrive intact) — a coarse, separate concern from that deeper verification.
pub const Phase = enum { downloading, verifying, extracting, installing };
pub const ProgressFn = *const fn (phase: Phase, fraction: f64) void;

pub const InstallOptions = struct {
    allocator: std.mem.Allocator,
    /// Direct download URL for `graphcode-windows-x86_64.zip`, from
    /// `WindowsUpdates.CheckResult.asset_url`.
    asset_url: []const u8,
    /// Lowercase hex SHA-256, when GitHub reported one on the asset itself.
    expected_sha256: ?[]const u8 = null,
    /// Download URL for the `.sha256` sidecar, used only when
    /// `expected_sha256` is null.
    checksum_url: ?[]const u8 = null,
    /// Passed through to the setup script as `-InstallRoot` when set;
    /// omitted (letting the script use its own default) otherwise.
    install_root: ?[]const u8 = null,
    cancelled: *std.atomic.Value(bool),
    progress: ?ProgressFn = null,
};

pub const InstallError = error{
    Cancelled,
    ChecksumUnavailable,
    ChecksumMismatch,
    DownloadFailed,
    ExtractionFailed,
    ExtractionTimedOut,
    SetupScriptMissing,
    UpgradeFailed,
    UpgradeTimedOut,
} || std.mem.Allocator.Error;

const powershell_timeout_extract_ms: u64 = 120_000;
const powershell_timeout_upgrade_ms: u64 = 600_000;
const powershell_max_output_bytes: usize = 64 * 1024;
const download_chunk_report_step: f64 = 0.01;

// ---------------------------------------------------------------------------
// Pure helpers — unit tested directly, no network or process involved.
// ---------------------------------------------------------------------------

/// Escapes a value for embedding inside a *single-quoted* PowerShell string
/// literal: doubling `'` is the whole rule (PowerShell has no backslash
/// escaping inside single-quoted strings, which is exactly why single quotes
/// are used here instead of double).
pub fn escapePowerShellLiteral(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    for (value) |byte| {
        if (byte == '\'') try out.append('\'');
        try out.append(byte);
    }
    return out.toOwnedSlice();
}

pub fn expandArchiveScript(allocator: std.mem.Allocator, zip_path: []const u8, destination_dir: []const u8) ![]u8 {
    const zip = try escapePowerShellLiteral(allocator, zip_path);
    defer allocator.free(zip);
    const dest = try escapePowerShellLiteral(allocator, destination_dir);
    defer allocator.free(dest);
    return std.fmt.allocPrint(allocator, "Expand-Archive -LiteralPath '{s}' -DestinationPath '{s}' -Force", .{ zip, dest });
}

/// The extracted package always contains exactly one `GraphCode` top-level
/// directory (see `PACKAGING.md`), so the setup script's path is derivable
/// rather than something that needs to be searched for.
pub fn setupScriptPath(allocator: std.mem.Allocator, extract_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ extract_dir, "GraphCode", "GraphCode-Setup.ps1" });
}

pub fn upgradeScript(allocator: std.mem.Allocator, setup_script_path: []const u8, install_root: ?[]const u8) ![]u8 {
    const setup = try escapePowerShellLiteral(allocator, setup_script_path);
    defer allocator.free(setup);
    if (install_root) |root| {
        const escaped_root = try escapePowerShellLiteral(allocator, root);
        defer allocator.free(escaped_root);
        return std.fmt.allocPrint(allocator, "& '{s}' -Command Upgrade -InstallRoot '{s}'", .{ setup, escaped_root });
    }
    return std.fmt.allocPrint(allocator, "& '{s}' -Command Upgrade", .{setup});
}

/// Parses the `<hex>  <name>` line `Tools/windows/release.ps1` writes to the
/// published `.sha256` sidecar. Returns a lowercase-hex slice borrowed from
/// `body`, or `null` if the body does not have the expected shape — callers
/// must treat that as "no usable checksum", never as a match.
pub fn parseChecksumSidecar(body: []const u8) ?[64]u8 {
    var lines = std.mem.tokenizeAny(u8, body, "\r\n");
    const first_line = lines.next() orelse return null;
    var fields = std.mem.tokenizeAny(u8, first_line, " \t");
    const hex = fields.next() orelse return null;
    if (hex.len != 64) return null;
    var result: [64]u8 = undefined;
    for (hex, 0..) |byte, index| {
        if (!std.ascii.isHex(byte)) return null;
        result[index] = std.ascii.toLower(byte);
    }
    return result;
}

pub fn checksumsEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Real I/O — WinHTTP download and PowerShell subprocess invocation. These are
// exercised by the live gate (real network, real extraction, real setup
// script), not by fixture-driven unit tests: there is nothing meaningful to
// fake here without simulating the exact thing that needs proving.
// ---------------------------------------------------------------------------

const RunResult = struct {
    exit_code: ?u32,
    timed_out: bool,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

fn watchdog(handle: c.HANDLE, timeout_ms: u64, done: *std.atomic.Value(bool), timed_out: *std.atomic.Value(bool)) void {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (!done.load(.acquire)) {
        if (std.time.milliTimestamp() >= deadline) {
            timed_out.store(true, .release);
            _ = c.TerminateProcess(handle, 1);
            return;
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

/// Runs `powershell.exe -Command <script>`, redirecting stdout/stderr through
/// pipes read concurrently via `Child.collectOutput` (not left unread until
/// exit) — the same class of pipe-full deadlock the macOS `UpdateInstallClient`
/// avoids by using temp files applies here too, and `collectOutput`'s poller
/// is Zig's answer to it. A separate watchdog thread terminates the process
/// (via the raw handle, not through `Child`'s own state, to avoid racing the
/// main thread's `wait`) if `timeout_ms` elapses first.
fn runPowerShell(allocator: std.mem.Allocator, script: []const u8, timeout_ms: u64) !RunResult {
    var child = std.process.Child.init(&.{ "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var done = std.atomic.Value(bool).init(false);
    var timed_out = std.atomic.Value(bool).init(false);
    const watcher = try std.Thread.spawn(.{}, watchdog, .{ child.id, timeout_ms, &done, &timed_out });

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);
    const collect_err = child.collectOutput(allocator, &stdout, &stderr, powershell_max_output_bytes);
    const term = child.wait() catch std.process.Child.Term{ .Unknown = 0 };
    done.store(true, .release);
    watcher.join();
    collect_err catch |err| return err;

    const exit_code: ?u32 = switch (term) {
        .Exited => |code| code,
        else => null,
    };
    return .{
        .exit_code = exit_code,
        .timed_out = timed_out.load(.acquire),
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
    };
}

fn utf16Z(allocator: std.mem.Allocator, value: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, value);
}

const OpenRequest = struct {
    session: c.HINTERNET,
    connection: c.HINTERNET,
    request: c.HINTERNET,

    fn close(self: *OpenRequest) void {
        _ = c.WinHttpCloseHandle(self.request);
        _ = c.WinHttpCloseHandle(self.connection);
        _ = c.WinHttpCloseHandle(self.session);
    }
};

/// Opens a GET request against an arbitrary HTTPS URL (unlike
/// `WindowsUpdates.fetchWinHttp`, which is pinned to the GitHub API host) and
/// leaves response headers read so the caller can stream the body. WinHTTP
/// follows redirects by default, which matters here: GitHub release asset
/// URLs 302 to `objects.githubusercontent.com`.
fn openGet(allocator: std.mem.Allocator, url: []const u8, cancelled: *std.atomic.Value(bool)) !OpenRequest {
    if (cancelled.load(.acquire)) return error.Cancelled;
    const uri = try std.Uri.parse(url);
    if (!std.mem.eql(u8, uri.scheme, "https")) return error.DownloadFailed;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const host_component = uri.host orelse return error.DownloadFailed;
    const host = try host_component.toRawMaybeAlloc(scratch);
    const path_component = try uri.path.toRawMaybeAlloc(scratch);
    const query = if (uri.query) |value| try value.toRawMaybeAlloc(scratch) else null;
    const path = if (query) |value| try std.fmt.allocPrint(scratch, "{s}?{s}", .{ path_component, value }) else path_component;
    const host16 = try utf16Z(scratch, host);
    const path16 = try utf16Z(scratch, path);
    const agent16 = try utf16Z(scratch, "GraphCode-Windows-Updater");

    const session = c.WinHttpOpen(agent16.ptr, c.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse return error.DownloadFailed;
    errdefer _ = c.WinHttpCloseHandle(session);
    if (c.WinHttpSetTimeouts(session, 5000, 5000, 15000, 15000) == 0) return error.DownloadFailed;
    const port: c.INTERNET_PORT = uri.port orelse 443;
    const connection = c.WinHttpConnect(session, host16.ptr, port, 0) orelse return error.DownloadFailed;
    errdefer _ = c.WinHttpCloseHandle(connection);
    const verb: [*:0]const u16 = &[_:0]u16{ 'G', 'E', 'T' };
    var accepts = [_]?[*:0]const u16{null};
    const request = c.WinHttpOpenRequest(connection, verb, path16.ptr, null, null, @ptrCast(&accepts), c.WINHTTP_FLAG_SECURE) orelse return error.DownloadFailed;
    errdefer _ = c.WinHttpCloseHandle(request);
    if (cancelled.load(.acquire)) return error.Cancelled;
    if (c.WinHttpSendRequest(request, @as([*c]const u16, null), 0, null, 0, 0, 0) == 0) return error.DownloadFailed;
    if (cancelled.load(.acquire)) return error.Cancelled;
    if (c.WinHttpReceiveResponse(request, null) == 0) return error.DownloadFailed;
    var status: c.DWORD = 0;
    var status_len: c.DWORD = @sizeOf(c.DWORD);
    if (c.WinHttpQueryHeaders(request, c.WINHTTP_QUERY_STATUS_CODE | c.WINHTTP_QUERY_FLAG_NUMBER, null, &status, &status_len, null) == 0 or status != 200)
        return error.DownloadFailed;
    return .{ .session = session, .connection = connection, .request = request };
}

fn queryContentLength(request: c.HINTERNET) ?u64 {
    var value: c.DWORD = 0;
    var value_len: c.DWORD = @sizeOf(c.DWORD);
    if (c.WinHttpQueryHeaders(request, c.WINHTTP_QUERY_CONTENT_LENGTH | c.WINHTTP_QUERY_FLAG_NUMBER, null, &value, &value_len, null) == 0)
        return null;
    return value;
}

/// Streams the response body to `destination_path`, computing a running
/// SHA-256 as bytes are written (no separate re-read pass) and reporting
/// download progress throttled to ~1% steps, matching the macOS client's
/// throttle for the same reason: a report per byte would flood the UI thread.
fn downloadToFile(
    allocator: std.mem.Allocator,
    url: []const u8,
    destination_path: []const u8,
    cancelled: *std.atomic.Value(bool),
    progress: ?ProgressFn,
) ![32]u8 {
    var opened = try openGet(allocator, url, cancelled);
    defer opened.close();
    const total = queryContentLength(opened.request);
    var file = try std.fs.createFileAbsolute(destination_path, .{ .truncate = true });
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var written: u64 = 0;
    var reported: f64 = 0;
    while (true) {
        if (cancelled.load(.acquire)) return error.Cancelled;
        var available: c.DWORD = 0;
        if (c.WinHttpQueryDataAvailable(opened.request, &available) == 0) return error.DownloadFailed;
        if (available == 0) break;
        const to_read = @min(available, buffer.len);
        var read: c.DWORD = 0;
        if (c.WinHttpReadData(opened.request, &buffer, to_read, &read) == 0) return error.DownloadFailed;
        if (read == 0) break;
        const chunk = buffer[0..read];
        try file.writeAll(chunk);
        hasher.update(chunk);
        written += read;
        if (progress) |report| {
            if (total) |denominator| {
                if (denominator > 0) {
                    const fraction = @as(f64, @floatFromInt(written)) / @as(f64, @floatFromInt(denominator));
                    if (fraction - reported >= download_chunk_report_step or fraction >= 1) {
                        reported = fraction;
                        report(.downloading, @min(fraction, 1));
                    }
                }
            }
        }
    }
    if (progress) |report| report(.downloading, 1);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn hexDigest(digest: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(digest, .lower);
}

/// Fetches a small text body (the `.sha256` sidecar) into memory. Capped
/// tightly — this is a one-line checksum file, not a package.
fn fetchSmall(allocator: std.mem.Allocator, url: []const u8, cancelled: *std.atomic.Value(bool)) ![]u8 {
    var opened = try openGet(allocator, url, cancelled);
    defer opened.close();
    var body = std.array_list.Managed(u8).init(allocator);
    defer body.deinit();
    while (true) {
        if (cancelled.load(.acquire)) return error.Cancelled;
        var available: c.DWORD = 0;
        if (c.WinHttpQueryDataAvailable(opened.request, &available) == 0) return error.DownloadFailed;
        if (available == 0) break;
        if (body.items.len + available > 8192) return error.DownloadFailed;
        const old_len = body.items.len;
        try body.resize(old_len + available);
        var read: c.DWORD = 0;
        if (c.WinHttpReadData(opened.request, body.items[old_len..].ptr, available, &read) == 0) return error.DownloadFailed;
        body.items.len = old_len + read;
    }
    return body.toOwnedSlice();
}

/// Downloads, verifies, extracts, and installs — orchestrating every step
/// above. Returns once `GraphCode-Setup.ps1 -Command Upgrade` has exited 0;
/// that script has already performed its own atomic swap by the time this
/// returns, so callers only need to present the relaunch prompt next.
pub fn install(options: InstallOptions) InstallError!void {
    const allocator = options.allocator;
    const work_dir = try tempDir(allocator);
    defer allocator.free(work_dir);
    const zip_path = try std.fs.path.join(allocator, &.{ work_dir, "graphcode-update.zip" });
    defer allocator.free(zip_path);
    const extract_dir = try std.fs.path.join(allocator, &.{ work_dir, "extracted" });
    defer allocator.free(extract_dir);
    defer std.fs.deleteTreeAbsolute(work_dir) catch {};

    std.fs.makeDirAbsolute(work_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.DownloadFailed,
    };

    if (options.progress) |report| report(.downloading, 0);
    const digest = downloadToFile(allocator, options.asset_url, zip_path, options.cancelled, options.progress) catch |err| switch (err) {
        error.Cancelled => return error.Cancelled,
        else => return error.DownloadFailed,
    };
    const hex = hexDigest(digest);

    if (options.progress) |report| report(.verifying, 0);
    var expected_buffer: [64]u8 = undefined;
    const expected: []const u8 = blk: {
        if (options.expected_sha256) |value| break :blk value;
        const checksum_url = options.checksum_url orelse return error.ChecksumUnavailable;
        const body = fetchSmall(allocator, checksum_url, options.cancelled) catch return error.ChecksumUnavailable;
        defer allocator.free(body);
        const parsed = parseChecksumSidecar(body) orelse return error.ChecksumUnavailable;
        expected_buffer = parsed;
        break :blk &expected_buffer;
    };
    if (!checksumsEqual(&hex, expected)) return error.ChecksumMismatch;

    if (options.progress) |report| report(.extracting, 0);
    const expand_script = try expandArchiveScript(allocator, zip_path, extract_dir);
    defer allocator.free(expand_script);
    var expand_result = runPowerShell(allocator, expand_script, powershell_timeout_extract_ms) catch return error.ExtractionFailed;
    defer expand_result.deinit(allocator);
    if (expand_result.timed_out) return error.ExtractionTimedOut;
    if (expand_result.exit_code != 0) return error.ExtractionFailed;

    const setup_path = try setupScriptPath(allocator, extract_dir);
    defer allocator.free(setup_path);
    std.fs.accessAbsolute(setup_path, .{}) catch return error.SetupScriptMissing;

    if (options.progress) |report| report(.installing, 0);
    const upgrade = try upgradeScript(allocator, setup_path, options.install_root);
    defer allocator.free(upgrade);
    var upgrade_result = runPowerShell(allocator, upgrade, powershell_timeout_upgrade_ms) catch return error.UpgradeFailed;
    defer upgrade_result.deinit(allocator);
    if (upgrade_result.timed_out) return error.UpgradeTimedOut;
    if (upgrade_result.exit_code != 0) return error.UpgradeFailed;
    if (options.progress) |report| report(.installing, 1);
}

fn tempDir(allocator: std.mem.Allocator) ![]u8 {
    const base = std.process.getEnvVarOwned(allocator, "TEMP") catch
        try allocator.dupe(u8, "C:\\Windows\\Temp");
    defer allocator.free(base);
    var random_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    const suffix = std.fmt.bytesToHex(random_bytes, .lower);
    return std.fs.path.join(allocator, &.{ base, "graphcode-update-" ++ suffix });
}

// ---------------------------------------------------------------------------
// Tests — pure functions only. Download/extraction/upgrade require a real
// network, a real ZIP, and real PowerShell, and are exercised by the live
// gate instead (see Tools/windows/Tests/WindowsUpdateInstall.Live.Tests.ps1,
// which drives graphcode-windows/src/UpdateInstallLiveRunner.zig).
// ---------------------------------------------------------------------------

test "single-quoted PowerShell literals double embedded quotes" {
    const escaped = try escapePowerShellLiteral(std.testing.allocator, "C:\\Users\\O'Brien\\update.zip");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("C:\\Users\\O''Brien\\update.zip", escaped);
}

test "Expand-Archive script embeds both paths as single-quoted literals" {
    const script = try expandArchiveScript(std.testing.allocator, "C:\\temp\\update.zip", "C:\\temp\\extracted");
    defer std.testing.allocator.free(script);
    try std.testing.expectEqualStrings(
        "Expand-Archive -LiteralPath 'C:\\temp\\update.zip' -DestinationPath 'C:\\temp\\extracted' -Force",
        script,
    );
}

test "setup script path always resolves under the extracted GraphCode directory" {
    const path = try setupScriptPath(std.testing.allocator, "C:\\temp\\extracted");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("C:\\temp\\extracted\\GraphCode\\GraphCode-Setup.ps1", path);
}

test "upgrade script omits -InstallRoot when none is given" {
    const script = try upgradeScript(std.testing.allocator, "C:\\extracted\\GraphCode\\GraphCode-Setup.ps1", null);
    defer std.testing.allocator.free(script);
    try std.testing.expectEqualStrings("& 'C:\\extracted\\GraphCode\\GraphCode-Setup.ps1' -Command Upgrade", script);
}

test "upgrade script passes a custom install root through as a quoted literal" {
    const script = try upgradeScript(std.testing.allocator, "C:\\extracted\\GraphCode\\GraphCode-Setup.ps1", "C:\\Users\\Test\\GraphCode");
    defer std.testing.allocator.free(script);
    try std.testing.expectEqualStrings(
        "& 'C:\\extracted\\GraphCode\\GraphCode-Setup.ps1' -Command Upgrade -InstallRoot 'C:\\Users\\Test\\GraphCode'",
        script,
    );
}

test "checksum sidecar parsing accepts the exact format release.ps1 writes" {
    const hash = "a" ** 64;
    const body = hash ++ "  graphcode-windows-x86_64.zip\n";
    const parsed = parseChecksumSidecar(body) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(hash, &parsed);
}

test "checksum sidecar parsing normalizes to lowercase" {
    const upper_hash = "AB" ** 32;
    const body = upper_hash ++ "  graphcode-windows-x86_64.zip";
    const parsed = parseChecksumSidecar(body) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ab" ** 32, &parsed);
}

test "checksum sidecar parsing rejects malformed or empty content" {
    try std.testing.expectEqual(@as(?[64]u8, null), parseChecksumSidecar(""));
    try std.testing.expectEqual(@as(?[64]u8, null), parseChecksumSidecar("not-a-hash graphcode-windows-x86_64.zip"));
    try std.testing.expectEqual(@as(?[64]u8, null), parseChecksumSidecar(("a" ** 63) ++ " graphcode-windows-x86_64.zip"));
}

test "checksum comparison is case-insensitive and length-strict" {
    try std.testing.expect(checksumsEqual("AbCd", "abcd"));
    try std.testing.expect(!checksumsEqual("abcd", "abcde"));
    try std.testing.expect(!checksumsEqual("abcd", "abce"));
}

test "hex digest formatting is lowercase and matches the running SHA-256 output shape" {
    // `install()`'s call to this is only reachable from a real download, so
    // Zig's lazy analysis never checks it via the tests above alone; this
    // caught a real `std.fmt.fmtSliceHexLower` removal that only surfaced
    // when the live runner actually called into `install()`.
    var digest: [32]u8 = undefined;
    for (&digest, 0..) |*byte, index| byte.* = @intCast(index);
    const hex = hexDigest(digest);
    try std.testing.expectEqualStrings(
        "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
        &hex,
    );
}
