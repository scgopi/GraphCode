const std = @import("std");
const WindowsUpdates = @import("WindowsUpdates.zig");
const WindowsUpdateInstall = @import("WindowsUpdateInstall.zig");

/// Drives the real, compiled `WindowsUpdates`/`WindowsUpdateInstall` code
/// against real network endpoints, for
/// `Tools/windows/Tests/WindowsUpdateInstall.Live.Tests.ps1`. This file has
/// no `test "..."` blocks and is invoked with `zig run`, not `zig test`, so
/// it is not part of `WindowsShell.Tests.ps1`'s anti-drift-guarded fast
/// suite — a real HTTPS download does not belong in a suite meant to run
/// with no network, and does not need wiring there.
///
/// Modes (argv[1]):
///   feed-check           Real GitHub API call for the actual scgopi/GraphCode
///                        releases feed; prints `asset_url=<none|url>` and
///                        `state=<...>`.
///   download-checksum    Real HTTPS download + real running SHA-256 of
///                        argv[2], verified against argv[3]. Prints each
///                        phase transition and the final result.
pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const mode = args.next() orelse return errorOut("missing mode argument");

    if (std.mem.eql(u8, mode, "feed-check")) {
        return feedCheck(allocator);
    }
    if (std.mem.eql(u8, mode, "download-checksum")) {
        const url = args.next() orelse return errorOut("missing asset URL argument");
        const expected = args.next() orelse return errorOut("missing expected-checksum argument");
        return downloadChecksum(allocator, url, expected);
    }
    return errorOut("unknown mode");
}

fn errorOut(message: []const u8) u8 {
    std.debug.print("runner-error: {s}\n", .{message});
    return 2;
}

/// Exercises the exact production path an idle app takes: a real call to
/// GitHub's API for the real repository, through the same `CheckClient` the
/// shell uses. Prints whether a Windows asset was resolved for the current
/// real latest release — this is the live counterpart to the "no Windows
/// asset published" constraint the offer UI must handle honestly.
fn feedCheck(allocator: std.mem.Allocator) !u8 {
    var client = WindowsUpdates.CheckClient{ .allocator = allocator };
    var cancelled = std.atomic.Value(bool).init(false);
    var result = client.checkWithCancel(false, "0.0.0", &cancelled) catch |err| {
        std.debug.print("runner-error: feed check failed: {s}\n", .{@errorName(err)});
        return 2;
    };
    defer result.deinit(allocator);
    std.debug.print("state={s}\n", .{@tagName(result.state)});
    if (result.asset_url) |url| {
        std.debug.print("asset_url={s}\n", .{url});
    } else {
        std.debug.print("asset_url=none\n", .{});
    }
    return 0;
}

const ReportState = struct {
    var phase: WindowsUpdateInstall.Phase = .downloading;
    var reports: u32 = 0;
    var max_downloading_fraction: f64 = 0;
};

fn recordProgress(phase: WindowsUpdateInstall.Phase, fraction: f64) void {
    ReportState.phase = phase;
    ReportState.reports += 1;
    if (phase == .downloading and fraction > ReportState.max_downloading_fraction)
        ReportState.max_downloading_fraction = fraction;
    std.debug.print("phase={s} fraction={d:.4}\n", .{ @tagName(phase), fraction });
}

/// Runs the real `install()` entrypoint against a real HTTPS asset URL. A
/// non-ZIP real asset (any currently-published release asset) is expected to
/// fail at extraction, *after* download and checksum verification genuinely
/// succeed against real bytes — proving those two stages work without
/// depending on a Windows asset existing. Passing a deliberately wrong
/// `expected` proves the checksum gate is real: it must fail with
/// ChecksumMismatch specifically, before ever reaching extraction.
fn downloadChecksum(allocator: std.mem.Allocator, url: []const u8, expected: []const u8) !u8 {
    var cancelled = std.atomic.Value(bool).init(false);
    ReportState.phase = .downloading;
    ReportState.reports = 0;
    ReportState.max_downloading_fraction = 0;

    const outcome = WindowsUpdateInstall.install(.{
        .allocator = allocator,
        .asset_url = url,
        .expected_sha256 = expected,
        .cancelled = &cancelled,
        .progress = &recordProgress,
    });
    std.debug.print("reports={d} max_downloading_fraction={d:.4} last_phase={s}\n", .{
        ReportState.reports,
        ReportState.max_downloading_fraction,
        @tagName(ReportState.phase),
    });

    if (outcome) |_| {
        std.debug.print("result=success\n", .{});
    } else |err| {
        std.debug.print("result=error name={s}\n", .{@errorName(err)});
    }
    return 0;
}
