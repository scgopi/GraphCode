const std = @import("std");

pub fn stopWith(api: anytype, handle: anytype) !void {
    if (try api.signaled(handle, 0)) return;
    try api.terminate(handle);
    const remaining = api.remaining();
    if (remaining == 0 or !try api.signaled(handle, remaining)) return error.AttachExitTimeout;
}

pub fn cleanupWith(api: anytype) !void {
    try api.stop(0);
    try api.stop(1);
    try api.destroy(0);
    try api.destroy(1);
    try api.deinitialize();
}

pub fn restartWith(api: anytype) !void {
    try api.retire();
    try api.start();
}

const Fixture = struct {
    exited: bool = false,
    wait_failed: bool = false,
    terminate_failed: bool = false,
    timeout: bool = false,
    budget: u32 = 5000,
    terminated: usize = 0,
    waits: usize = 0,
    wait_failed_after_terminate: bool = false,

    fn signaled(self: *Fixture, handle: usize, milliseconds: u32) !bool {
        try std.testing.expectEqual(@as(usize, 42), handle);
        self.waits += 1;
        if (self.wait_failed or (self.wait_failed_after_terminate and self.terminated != 0)) return error.AttachWaitFailed;
        return self.exited or (milliseconds != 0 and !self.timeout);
    }
    fn terminate(self: *Fixture, handle: usize) !void {
        try std.testing.expectEqual(@as(usize, 42), handle);
        self.terminated += 1;
        if (self.terminate_failed) return error.AttachTerminateFailed;
    }
    fn remaining(self: *Fixture) u32 {
        return self.budget;
    }
};

test "held attach already exited is not terminated" {
    var api: Fixture = .{ .exited = true };
    try stopWith(&api, @as(usize, 42));
    try std.testing.expectEqual(@as(usize, 0), api.terminated);
}
test "held attach terminates and waits within finite budget" {
    var api: Fixture = .{};
    try stopWith(&api, @as(usize, 42));
    try std.testing.expectEqual(@as(usize, 1), api.terminated);
    try std.testing.expectEqual(@as(usize, 2), api.waits);
}
test "failed initial held wait refuses termination" {
    var api: Fixture = .{ .wait_failed = true };
    try std.testing.expectError(error.AttachWaitFailed, stopWith(&api, @as(usize, 42)));
    try std.testing.expectEqual(@as(usize, 0), api.terminated);
}
test "failed termination preserves concrete failure" {
    var api: Fixture = .{ .terminate_failed = true };
    try std.testing.expectError(error.AttachTerminateFailed, stopWith(&api, @as(usize, 42)));
    try std.testing.expectEqual(@as(usize, 1), api.waits);
}
test "unsignaled attach refuses finalization" {
    var api: Fixture = .{ .timeout = true };
    try std.testing.expectError(error.AttachExitTimeout, stopWith(&api, @as(usize, 42)));
}
test "expired original deadline never starts a new wait budget" {
    var api: Fixture = .{ .budget = 0 };
    try std.testing.expectError(error.AttachExitTimeout, stopWith(&api, @as(usize, 42)));
    try std.testing.expectEqual(@as(usize, 1), api.waits);
}
test "failed post-termination wait cannot finalize child" {
    var api: Fixture = .{ .wait_failed_after_terminate = true };
    try std.testing.expectError(error.AttachWaitFailed, stopWith(&api, @as(usize, 42)));
}

const CleanupFixture = struct {
    calls: usize = 0,
    failure_at: ?usize = null,
    pub fn stop(self: *CleanupFixture, index: usize) !void {
        try std.testing.expectEqual(index, self.calls);
        try self.advance();
    }
    pub fn destroy(self: *CleanupFixture, index: usize) !void {
        try std.testing.expectEqual(index + 2, self.calls);
        try self.advance();
    }
    pub fn deinitialize(self: *CleanupFixture) !void {
        try std.testing.expectEqual(@as(usize, 4), self.calls);
        try self.advance();
    }
    fn advance(self: *CleanupFixture) !void {
        if (self.failure_at == self.calls) return error.OriginalCleanupFailure;
        self.calls += 1;
    }
};

test "final cleanup proves both child exits before provider destruction and host deinit" {
    var fixture: CleanupFixture = .{};
    try cleanupWith(&fixture);
    try std.testing.expectEqual(@as(usize, 5), fixture.calls);
}
test "every final cleanup failure refuses success and keeps its first failure" {
    for (0..5) |failure_at| {
        var fixture: CleanupFixture = .{ .failure_at = failure_at };
        try std.testing.expectError(error.OriginalCleanupFailure, cleanupWith(&fixture));
        try std.testing.expectEqual(failure_at, fixture.calls);
    }
}

const RestartFixture = struct {
    retire_failed: bool = false,
    start_failed: bool = false,
    starts: usize = 0,
    pub fn retire(self: *RestartFixture) !void {
        if (self.retire_failed) return error.OriginalRetireFailure;
    }
    pub fn start(self: *RestartFixture) !void {
        self.starts += 1;
        if (self.start_failed) return error.OriginalStartFailure;
    }
};
test "restart never launches a replacement after failed owned retirement" {
    var fixture: RestartFixture = .{ .retire_failed = true };
    try std.testing.expectError(error.OriginalRetireFailure, restartWith(&fixture));
    try std.testing.expectEqual(@as(usize, 0), fixture.starts);
}
test "restart preserves start failure after proven retirement" {
    var fixture: RestartFixture = .{ .start_failed = true };
    try std.testing.expectError(error.OriginalStartFailure, restartWith(&fixture));
    try std.testing.expectEqual(@as(usize, 1), fixture.starts);
}
test "restart starts exactly one replacement after successful retirement" {
    var fixture: RestartFixture = .{};
    try restartWith(&fixture);
    try std.testing.expectEqual(@as(usize, 1), fixture.starts);
}
