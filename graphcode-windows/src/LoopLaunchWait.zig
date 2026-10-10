//! Waits for the daemon to start a graph loop's zmx session before a pane attaches.
//!
//! `zmx attach` creates a plain shell session when the named one is not reachable, so a
//! pane that attached first would win the race against the daemon's launch and the loop's
//! agent would never start. The pane instead probes `zmx ls` until the task is live,
//! then attaches. Pure state so it is testable without zmx.

const std = @import("std");
const ZmxSession = @import("ZmxSession.zig");

pub const probe_interval_ms: i64 = 250;
/// How long an explicit open waits for the daemon to start the loop's agent.
pub const open_timeout_ms: i64 = 30_000;
/// After a passive check found nothing, how long before another passive check.
pub const passive_retry_ms: i64 = 5_000;

/// `missing` is a definite answer (a clean listing without the session, an ended task, or a
/// dead daemon). `unknown` is not: the listing could not be taken, or zmx could not reach a
/// session that may be busy rather than gone.
pub const Probe = enum { running, live, missing, unknown };
pub const Step = enum { idle, start_probe, attach, give_up };

/// Longest pause between probes while the answer stays unknown. Every probe is a connection to
/// the session zmx already failed to reach in time, so these back off instead of polling.
pub const unknown_backoff_cap_ms: i64 = 4_000;

pub fn unknownBackoffMs(streak: u8) i64 {
    const shift: u6 = @intCast(@min(streak, 6));
    return @min(probe_interval_ms << shift, unknown_backoff_cap_ms);
}

pub const Liveness = enum { live, absent, unknown };

/// The one error name `zmx ls` prints for a daemon that is definitively gone (its pipe or
/// socket refuses the connection). Every other `err=` (Timeout, BrokenPipe, Unexpected...)
/// describes a probe that failed against a session that may well be running.
const dead_daemon_error = "ConnectionRefused";

/// Whether a persisted pane is restored: only while its session is still running (or when
/// the listing could not say). A shell tab's session ended with the machine, or was killed
/// with its loop, and `zmx attach` would create a bare shell under that name: a ghost the
/// user never asked for. A loop pane restored without its session would likewise make every
/// later open find the loop "running" and never launch its agent.
pub fn restoreKeepsPane(launches_agent: bool, session_live: ?bool) bool {
    _ = launches_agent;
    return session_live != false;
}

pub const Wait = struct {
    session: []u8 = &.{},
    deadline_ms: i64 = 0,
    next_probe_ms: i64 = 0,
    probing: bool = false,
    /// An explicit open reports a launch that never came; a passive check stays quiet.
    reports_timeout: bool = false,
    /// Consecutive probes that could not tell; nonzero when the wait gives up means the
    /// session's state was never learned rather than known to be missing.
    unknown_streak: u8 = 0,

    pub fn active(self: *const Wait) bool {
        return self.session.len != 0;
    }

    pub fn begin(self: *Wait, session: []u8, now_ms: i64, timeout_ms: i64, reports_timeout: bool) void {
        self.* = .{
            .session = session,
            .deadline_ms = now_ms + @max(timeout_ms, 0),
            .next_probe_ms = now_ms,
            .reports_timeout = reports_timeout,
        };
    }

    /// An explicit open of a loop already being waited on keeps the wait, but no longer
    /// gives up sooner than the open asks and reports if it does.
    pub fn extend(self: *Wait, now_ms: i64, timeout_ms: i64, reports_timeout: bool) void {
        self.deadline_ms = @max(self.deadline_ms, now_ms + @max(timeout_ms, 0));
        self.reports_timeout = self.reports_timeout or reports_timeout;
    }

    /// The caller owns `session` again once this returns.
    pub fn finish(self: *Wait) []u8 {
        const session = self.session;
        self.* = .{};
        return session;
    }

    /// `probe` is the outcome of the probe in flight, or null when none was started.
    pub fn step(self: *Wait, now_ms: i64, probe: ?Probe) Step {
        if (!self.active()) return .idle;
        if (self.probing) {
            const outcome = probe orelse .missing;
            switch (outcome) {
                .running => return .idle,
                .live => {
                    self.probing = false;
                    self.unknown_streak = 0;
                    return .attach;
                },
                .missing => {
                    self.probing = false;
                    self.unknown_streak = 0;
                    if (now_ms >= self.deadline_ms) return .give_up;
                    self.next_probe_ms = now_ms + probe_interval_ms;
                    return .idle;
                },
                .unknown => {
                    self.probing = false;
                    self.unknown_streak +|= 1;
                    if (now_ms >= self.deadline_ms) return .give_up;
                    self.next_probe_ms = now_ms + unknownBackoffMs(self.unknown_streak);
                    return .idle;
                },
            }
        }
        if (now_ms < self.next_probe_ms) return .idle;
        self.probing = true;
        return .start_probe;
    }
};

/// `zmx ls`, never `info` or `attach`: only the listing says whether a session's task has
/// ended, and attaching to such a husk exits at once.
pub fn probeArguments(program: []const u8, output: *[2][]const u8) []const []const u8 {
    output.* = .{ program, "ls" };
    return output;
}

/// What a clean listing says about `session`:
/// - `live`: a row whose task has not ended;
/// - `absent`: no row, an ended task, or `err=ConnectionRefused` (the daemon behind it is gone);
/// - `unknown`: an `err=` row of any other kind. zmx could not get an answer out of the session
///   (a 1 s connect or 5 s read timeout while the daemon was busy); that is not evidence the
///   session is gone, so nothing may be launched, killed, forgotten or pruned on it.
pub fn listingLiveness(listing: []const u8, session: []const u8) Liveness {
    var name_buffer: [ZmxSession.prefix.len + 128]u8 = undefined;
    const name = ZmxSession.nameBuffer(session, &name_buffer) catch return .absent;
    // Every row naming the session counts, whatever its order: unknown dominates, then live,
    // and only rows that are all definitively absent make the session absent.
    var found_live = false;
    var found_unknown = false;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const first = fields.next() orelse continue;
        if (!std.mem.startsWith(u8, first, "name=") or !std.mem.eql(u8, first["name=".len..], name)) continue;
        if (errorField(line)) |err_name| {
            if (!std.mem.eql(u8, err_name, dead_daemon_error)) found_unknown = true;
            continue;
        }
        if (std.mem.indexOf(u8, line, "\tended=") != null or
            std.mem.indexOf(u8, line, "\texit_code=") != null) continue;
        found_live = true;
    }
    if (found_unknown) return .unknown;
    return if (found_live) .live else .absent;
}

/// The value of the tab-preceded `err=` field of one row, if it has one.
fn errorField(line: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, line, '\t');
    _ = parts.next();
    while (parts.next()) |part| {
        if (std.mem.startsWith(u8, part, "err=")) return std.mem.trimRight(u8, part["err=".len..], " ");
    }
    return null;
}

/// The daemon's own test (`ZmxSessionLauncher.isSessionAlive`): the session is listed and
/// its task has neither ended nor become unreachable.
pub fn listingShowsLive(listing: []const u8, session: []const u8) bool {
    return listingLiveness(listing, session) == .live;
}

test "an explicit open probes until the daemon's session exists, then attaches" {
    var name = "11111111-1111-4111-8111-111111111111".*;
    var wait: Wait = .{};
    wait.begin(&name, 1_000, open_timeout_ms, true);
    try std.testing.expectEqual(Step.start_probe, wait.step(1_000, null));
    try std.testing.expectEqual(Step.idle, wait.step(1_010, .running));
    try std.testing.expectEqual(Step.idle, wait.step(1_100, .missing));
    try std.testing.expectEqual(Step.idle, wait.step(1_200, null));
    try std.testing.expectEqual(Step.start_probe, wait.step(1_350, null));
    try std.testing.expectEqual(Step.attach, wait.step(1_400, .live));
    try std.testing.expectEqualStrings(&name, wait.finish());
    try std.testing.expect(!wait.active());
}

test "an open whose launch never comes gives up at the deadline and says so" {
    var name = "loop".*;
    var wait: Wait = .{};
    wait.begin(&name, 0, 500, true);
    var now: i64 = 0;
    var outcome = Step.idle;
    while (now <= 10_000 and outcome != .give_up) : (now += 50) {
        outcome = wait.step(now, if (wait.probing) .missing else null);
        try std.testing.expect(outcome != .attach);
    }
    try std.testing.expectEqual(Step.give_up, outcome);
    try std.testing.expect(now - 50 >= 500);
    try std.testing.expect(wait.reports_timeout);
}

test "a passive check probes once and never creates or retries a missing session" {
    var name = "loop".*;
    var wait: Wait = .{};
    wait.begin(&name, 5, 0, false);
    try std.testing.expectEqual(Step.start_probe, wait.step(5, null));
    try std.testing.expectEqual(Step.give_up, wait.step(90, .missing));
    try std.testing.expect(!wait.reports_timeout);
}

test "a failed probe spawn counts as missing rather than wedging the wait" {
    var name = "loop".*;
    var wait: Wait = .{};
    wait.begin(&name, 0, 1_000, true);
    try std.testing.expectEqual(Step.start_probe, wait.step(0, null));
    try std.testing.expectEqual(Step.idle, wait.step(1, null));
    try std.testing.expectEqual(Step.start_probe, wait.step(251, null));
}

test "re-opening a loop being waited on extends the wait without shortening it" {
    var name = "loop".*;
    var wait: Wait = .{};
    wait.begin(&name, 0, 0, false);
    wait.extend(100, open_timeout_ms, true);
    try std.testing.expectEqual(@as(i64, 100 + open_timeout_ms), wait.deadline_ms);
    try std.testing.expect(wait.reports_timeout);
    wait.extend(200, 0, false);
    try std.testing.expectEqual(@as(i64, 100 + open_timeout_ms), wait.deadline_ms);
    try std.testing.expect(wait.reports_timeout);
}

test "a restored pane is kept only while its session runs, whether a loop's or a shell tab's" {
    try std.testing.expect(restoreKeepsPane(true, true));
    try std.testing.expect(!restoreKeepsPane(true, false));
    try std.testing.expect(!restoreKeepsPane(false, false));
    try std.testing.expect(restoreKeepsPane(false, true));
}

test "the probe lists sessions without attaching to or creating one" {
    var output: [2][]const u8 = undefined;
    const argv = probeArguments("zmx.exe", &output);
    try std.testing.expectEqual(@as(usize, 2), argv.len);
    try std.testing.expectEqualStrings("zmx.exe", argv[0]);
    try std.testing.expectEqualStrings("ls", argv[1]);
}

test "a listed session counts as live only while its task runs" {
    const listing =
        "name=graphcode-00000000-0000-4000-8000-0A6CC9277ED5\tpid=11048\tclients=0\tcreated=1791318218\tcwd=C:\\p\tended=1791318818\texit_code=0\r\n" ++
        "name=graphcode-00000000-0000-4000-8000-0B492B5F5249\tpid=23500\tclients=1\tcreated=1791319165\tcwd=C:\\p\tcmd=copilot --interactive x\r\n" ++
        "  name=graphcode-gone\terr=PipeBusy\tstatus=unreachable\n";
    try std.testing.expect(listingShowsLive(listing, "00000000-0000-4000-8000-0B492B5F5249"));
    try std.testing.expect(!listingShowsLive(listing, "00000000-0000-4000-8000-0A6CC9277ED5"));
    try std.testing.expect(!listingShowsLive(listing, "gone"));
    try std.testing.expect(!listingShowsLive(listing, "00000000-0000-4000-8000-0B492B5F524"));
    try std.testing.expect(!listingShowsLive("", "anything"));
}

test "a failed listing must not delete a saved pane" {
    try std.testing.expect(restoreKeepsPane(true, null));
    try std.testing.expect(restoreKeepsPane(false, null));
}

test "a session name mentioned in another task command is not a live session" {
    try std.testing.expect(!listingShowsLive(
        "name=graphcode-other\tpid=1\tcmd=echo name=graphcode-wanted\n",
        "wanted",
    ));
}

test "an err= row is absent only for a refused connection and unknown for every other error" {
    const listing =
        "  name=graphcode-refused\terr=ConnectionRefused\tstatus=unreachable\n" ++
        "  name=graphcode-busy\terr=Timeout\tstatus=unreachable\r\n" ++
        "  name=graphcode-odd\terr=Unexpected\tstatus=unreachable\n" ++
        "  name=graphcode-prefix\terr=ConnectionRefusedAgain\tstatus=unreachable\n" ++
        "name=graphcode-fine\tpid=1\tclients=0\tcreated=1\n";
    try std.testing.expectEqual(Liveness.absent, listingLiveness(listing, "refused"));
    try std.testing.expectEqual(Liveness.unknown, listingLiveness(listing, "busy"));
    try std.testing.expectEqual(Liveness.unknown, listingLiveness(listing, "odd"));
    try std.testing.expectEqual(Liveness.unknown, listingLiveness(listing, "prefix"));
    try std.testing.expectEqual(Liveness.live, listingLiveness(listing, "fine"));
    try std.testing.expectEqual(Liveness.absent, listingLiveness(listing, "nothing"));
    try std.testing.expectEqual(Liveness.absent, listingLiveness("", "nothing"));
    try std.testing.expect(!listingShowsLive(listing, "busy"));
}

test "an ended task stays absent and an err= word inside another field is not an error row" {
    try std.testing.expectEqual(Liveness.absent, listingLiveness(
        "name=graphcode-a\tpid=1\tended=5\texit_code=0\n",
        "a",
    ));
    try std.testing.expectEqual(Liveness.live, listingLiveness(
        "name=graphcode-a\tpid=1\tcmd=echo err=Timeout\n",
        "a",
    ));
}

test "an unknown probe backs off exponentially to a cap and a definite answer resets it" {
    try std.testing.expectEqual(@as(i64, 500), unknownBackoffMs(1));
    try std.testing.expectEqual(@as(i64, 1_000), unknownBackoffMs(2));
    try std.testing.expectEqual(@as(i64, 2_000), unknownBackoffMs(3));
    try std.testing.expectEqual(unknown_backoff_cap_ms, unknownBackoffMs(4));
    try std.testing.expectEqual(unknown_backoff_cap_ms, unknownBackoffMs(255));

    var name = "loop".*;
    var wait: Wait = .{};
    wait.begin(&name, 0, open_timeout_ms, true);
    var now: i64 = 0;
    try std.testing.expectEqual(Step.start_probe, wait.step(now, null));
    var previous_gap: i64 = 0;
    var starts: usize = 0;
    var last_start: i64 = 0;
    while (now <= open_timeout_ms) : (now += 10) {
        const step = wait.step(now, if (wait.probing) .unknown else null);
        try std.testing.expect(step != .attach);
        if (step == .start_probe) {
            starts += 1;
            const gap = now - last_start;
            try std.testing.expect(gap >= previous_gap);
            previous_gap = gap;
            last_start = now;
        }
        if (step == .give_up) break;
    }
    // A fixed 250 ms poll would have started about 120 probes in the 30 s open window.
    try std.testing.expect(starts < 15);
    try std.testing.expect(wait.unknown_streak != 0);

    var fresh: Wait = .{};
    fresh.begin(&name, 0, open_timeout_ms, true);
    fresh.unknown_streak = 3;
    fresh.probing = true;
    try std.testing.expectEqual(Step.idle, fresh.step(100, .missing));
    try std.testing.expectEqual(@as(u8, 0), fresh.unknown_streak);
    try std.testing.expectEqual(@as(i64, 100 + probe_interval_ms), fresh.next_probe_ms);
}

test "an unknown probe never attaches and gives up only at the deadline" {
    var name = "loop".*;
    var wait: Wait = .{};
    wait.begin(&name, 0, 100, true);
    try std.testing.expectEqual(Step.start_probe, wait.step(0, null));
    try std.testing.expectEqual(Step.idle, wait.step(10, .unknown));
    try std.testing.expectEqual(Step.idle, wait.step(400, null));
    try std.testing.expectEqual(Step.start_probe, wait.step(510, null));
    try std.testing.expectEqual(Step.give_up, wait.step(520, .unknown));
}

test "several rows naming one session aggregate conservatively whatever their order" {
    const refused = "  name=graphcode-x\terr=ConnectionRefused\tstatus=unreachable\n";
    const timeout = "  name=graphcode-x\terr=Timeout\tstatus=unreachable\n";
    const live = "name=graphcode-x\tpid=1\tclients=0\n";
    const ended = "name=graphcode-x\tpid=1\tended=5\texit_code=0\n";
    try std.testing.expectEqual(Liveness.live, listingLiveness(refused ++ live, "x"));
    try std.testing.expectEqual(Liveness.live, listingLiveness(live ++ refused, "x"));
    try std.testing.expectEqual(Liveness.live, listingLiveness(ended ++ live, "x"));
    try std.testing.expectEqual(Liveness.unknown, listingLiveness(timeout ++ live, "x"));
    try std.testing.expectEqual(Liveness.unknown, listingLiveness(live ++ timeout, "x"));
    try std.testing.expectEqual(Liveness.unknown, listingLiveness(timeout ++ refused, "x"));
    try std.testing.expectEqual(Liveness.unknown, listingLiveness(refused ++ timeout, "x"));
    try std.testing.expectEqual(Liveness.absent, listingLiveness(refused ++ refused, "x"));
    try std.testing.expectEqual(Liveness.absent, listingLiveness(refused ++ ended, "x"));
    try std.testing.expectEqual(Liveness.absent, listingLiveness(ended ++ refused, "x"));
}
