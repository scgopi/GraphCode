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

pub const Probe = enum { running, live, missing };
pub const Step = enum { idle, start_probe, attach, give_up };

/// Whether a persisted pane is restored. A shell tab is (its session is recreated if it
/// ended); a loop pane only while the daemon's session is still running. Restoring it
/// otherwise would create a bare shell under the loop's name, and every later open would
/// then find the loop "running" and never launch its agent.
pub fn restoreKeepsPane(launches_agent: bool, session_live: bool) bool {
    return !launches_agent or session_live;
}

pub const Wait = struct {
    session: []u8 = &.{},
    deadline_ms: i64 = 0,
    next_probe_ms: i64 = 0,
    probing: bool = false,
    /// An explicit open reports a launch that never came; a passive check stays quiet.
    reports_timeout: bool = false,

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
                    return .attach;
                },
                .missing => {
                    self.probing = false;
                    if (now_ms >= self.deadline_ms) return .give_up;
                    self.next_probe_ms = now_ms + probe_interval_ms;
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

/// The daemon's own test (`ZmxSessionLauncher.isSessionAlive`): the session is listed and
/// its task has neither ended nor become unreachable.
pub fn listingShowsLive(listing: []const u8, session: []const u8) bool {
    var name_buffer: [ZmxSession.prefix.len + 128]u8 = undefined;
    const name = ZmxSession.nameBuffer(session, &name_buffer) catch return false;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        if (std.mem.indexOf(u8, line, "\tended=") != null or
            std.mem.indexOf(u8, line, "\texit_code=") != null or
            std.mem.indexOf(u8, line, "\terr=") != null) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        while (fields.next()) |field| {
            if (std.mem.startsWith(u8, field, "name=") and std.mem.eql(u8, field["name=".len..], name)) return true;
        }
    }
    return false;
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

test "a restored loop pane is kept only while its session runs; a shell tab always is" {
    try std.testing.expect(restoreKeepsPane(true, true));
    try std.testing.expect(!restoreKeepsPane(true, false));
    try std.testing.expect(restoreKeepsPane(false, false));
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
