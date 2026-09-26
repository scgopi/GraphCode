const std = @import("std");

const max_bytes = 2 * 1024 * 1024;
var mutex: std.Thread.Mutex = .{};

pub fn record(allocator: std.mem.Allocator, event: []const u8, detail: []const u8) void {
    mutex.lock();
    defer mutex.unlock();

    const directory = supportDirectory(allocator) catch return;
    defer allocator.free(directory);
    std.fs.cwd().makePath(directory) catch return;
    const path = std.fs.path.join(allocator, &.{ directory, "graphcode-windows.log" }) catch return;
    defer allocator.free(path);

    var file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
    defer file.close();
    const size = file.getEndPos() catch 0;
    if (size >= max_bytes) {
        file.setEndPos(0) catch return;
        file.seekTo(0) catch return;
    } else {
        file.seekFromEnd(0) catch return;
    }
    const line = std.fmt.allocPrint(
        allocator,
        "{d} event={s} detail={s}\r\n",
        .{ std.time.timestamp(), event, detail },
    ) catch return;
    defer allocator.free(line);
    file.writeAll(line) catch {};
}

fn supportDirectory(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "GRAPHCODE_SUPPORT_DIR")) |value| {
        return value;
    } else |_| {}
    const profile = try std.process.getEnvVarOwned(allocator, "USERPROFILE");
    defer allocator.free(profile);
    return std.fs.path.join(allocator, &.{ profile, ".graphcode" });
}

test "diagnostic log has a bounded filename and size" {
    try std.testing.expectEqualStrings("graphcode-windows.log", std.fs.path.basename("x\\graphcode-windows.log"));
    try std.testing.expect(max_bytes >= 1024 * 1024);
}
