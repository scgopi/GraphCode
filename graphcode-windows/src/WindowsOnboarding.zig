const std = @import("std");
const NativeDialogs = @import("WindowsNativeDialogs.zig");
const c = @import("Win32.zig").c;

pub const Store = struct {
    allocator: std.mem.Allocator,
    marker: []u8,

    pub fn init(allocator: std.mem.Allocator) !Store {
        const base = std.process.getEnvVarOwned(allocator, "LOCALAPPDATA") catch
            try std.process.getEnvVarOwned(allocator, "USERPROFILE");
        defer allocator.free(base);
        const dir = try std.fs.path.join(allocator, &.{ base, "GraphCode" });
        errdefer allocator.free(dir);
        try std.fs.cwd().makePath(dir);
        const marker = try std.fs.path.join(allocator, &.{ dir, "onboarding-seen" });
        allocator.free(dir);
        return .{ .allocator = allocator, .marker = marker };
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.marker);
        self.* = undefined;
    }

    pub fn shouldShow(self: Store) bool {
        std.fs.cwd().access(self.marker, .{}) catch return true;
        return false;
    }

    pub fn markSeen(self: Store) !void {
        var file = try std.fs.cwd().createFile(self.marker, .{ .truncate = true });
        file.close();
    }
};

pub fn showFirstRun(parent: c.HWND, allocator: std.mem.Allocator, store: Store) !void {
    if (!store.shouldShow()) return;
    if (try NativeDialogs.text(parent, allocator, "Welcome to GraphCode", &.{"First run"}, &.{
        "GraphCode connects to graphcoded, runs agent loops, and keeps their state in your project. Use Ctrl+, for product settings, Ctrl+Shift+C to clone HTTPS repositories, and Ctrl+Shift+R to add an SSH repository. Bootstrap failures stay visible in the status bar and bootstrap.err.log.",
    })) |result| {
        var mutable = result;
        mutable.deinit(allocator);
        try store.markSeen();
    }
}

test "first-run marker is actionable and defaults to showing" {
    var store = Store{ .allocator = std.testing.allocator, .marker = @constCast("definitely-not-present") };
    try std.testing.expect(store.shouldShow());
}
